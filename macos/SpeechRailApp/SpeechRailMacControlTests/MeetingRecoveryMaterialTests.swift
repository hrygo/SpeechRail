import Foundation
import SQLite3
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 空 final 的恢复材料（MA-02 / MC-11）。
///
/// 三条都要成立，缺一条就等于"无声消失"：
/// **存得下来、取得回来、不进正式纪要**。
@MainActor
final class MeetingRecoveryMaterialTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        self.directory = directory
        self.store = store
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        store = nil
        directory = nil
        try await super.tearDown()
    }

    private func seedSession() async throws -> String {
        let store = try XCTUnwrap(store)
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        return record.id
    }

    private func append(
        _ text: String,
        status: SessionLineStatus,
        sessionID: String
    ) async throws -> Int {
        let store = try XCTUnwrap(store)
        return try await store.appendLine(
            LineDraft(
                sessionID: sessionID,
                role: .speaker,
                text: text,
                source: .microphone,
                tStart: 1,
                tEnd: 2,
                status: status,
                timingQuality: .unavailable
            ),
            id: UUID().uuidString
        )
    }

    func testMixedSpeakerExportsKeepWordsUnknownsAndOriginalCue() async throws {
        let store = try XCTUnwrap(store)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "甲😀，乙？丙。", source: .microphone, tStart: 1, tEnd: 4), id: "export-mixed")
        let row = try await store.attachTranscriptAttribution(lineID: "export-mixed", units: [
            .init(id: "first", textStart: 0, textEnd: 2, speakerLabel: "A"),
            .init(id: "second", textStart: 3, textEnd: 4, speakerLabel: "B"),
            .init(id: "unknown", textStart: 5, textEnd: 6, speakerLabel: nil)
        ])
        let records = try await store.listSessions()
        let record = try XCTUnwrap(records.first)
        let payload = SessionExportPayload(record: record.record, lines: [row], speakerNames: ["A": "主讲"])
        let plain = SessionExporter.export(payload, as: .plainText)
        XCTAssertTrue(plain.contains("主讲：甲😀，\n说话人 B：乙？\n未确认说话人：丙。"))
        let markdown = SessionExporter.export(payload, as: .markdown)
        XCTAssertTrue(markdown.contains("**主讲**：甲😀，"))
        XCTAssertTrue(markdown.contains("**说话人 B**：乙？"))
        XCTAssertTrue(markdown.contains("**未确认说话人**：丙。"))
        let srt = SessionExporter.export(payload, as: .srt)
        XCTAssertEqual(srt.components(separatedBy: " --> ").count - 1, 1)
        XCTAssertTrue(srt.contains("00:00:01,000 --> 00:00:04,000"))
        XCTAssertTrue(srt.contains("主讲：甲😀，\n说话人 B：乙？\n未确认说话人：丙。"))
        let json = SessionExporter.export(payload, as: .json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let lines = try XCTUnwrap(root["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.first?["text"] as? String, row.text)
        let units = try XCTUnwrap(lines.first?["attribution_units"] as? [[String: Any]])
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units[1]["text_start"] as? Int, 3)
        XCTAssertEqual(units[1]["speaker_label"] as? String, "B")
        XCTAssertTrue(units[2]["speaker_label"] is NSNull)
        XCTAssertEqual(lines.first?["speaker_label_is_manual"] as? Bool, false)
    }

    /// 实时字幕的导出按显示模式投影：双语对照、仅中文、仅原文三种都走同一份 SRT 时间轴。
    func testCaptionSRTProjectionFollowsCaptionDisplayMode() async throws {
        let store = try XCTUnwrap(store)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "The budget is approved", source: .microphone, tStart: 0, tEnd: 3), id: "caption-en")
        _ = try await store.attachLineTranslation(
            lineID: "caption-en", translatedText: "预算已批准", sourceLanguage: "en"
        )
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "这句本来就是中文", source: .microphone, tStart: 3, tEnd: 6), id: "caption-zh")

        let sessions = try await store.listSessions()
        let record = try XCTUnwrap(sessions.first)
        let lines = try await store.lines(sessionID: id)

        let bilingual = SessionExporter.export(
            SessionExportPayload(record: record.record, lines: lines, captionDisplayMode: .bilingual),
            as: .srt
        )
        XCTAssertTrue(bilingual.contains("预算已批准\nThe budget is approved"))
        XCTAssertTrue(bilingual.contains("这句本来就是中文"), "中文行没有译文时原样导出")

        let chineseOnly = SessionExporter.export(
            SessionExportPayload(record: record.record, lines: lines, captionDisplayMode: .chineseOnly),
            as: .srt
        )
        XCTAssertTrue(chineseOnly.contains("预算已批准"))
        XCTAssertFalse(chineseOnly.contains("The budget is approved"), "仅中文模式不带原文")

        let originalOnly = SessionExporter.export(
            SessionExportPayload(record: record.record, lines: lines, captionDisplayMode: .originalOnly),
            as: .srt
        )
        XCTAssertTrue(originalOnly.contains("The budget is approved"))
        XCTAssertFalse(originalOnly.contains("预算已批准"), "仅原文模式不带译文")

        let markdown = SessionExporter.export(
            SessionExportPayload(record: record.record, lines: lines, captionDisplayMode: .bilingual),
            as: .markdown
        )
        XCTAssertTrue(markdown.contains("The budget is approved"))
        XCTAssertTrue(markdown.contains("> 预算已批准"))

        let plainText = SessionExporter.export(
            SessionExportPayload(record: record.record, lines: lines, captionDisplayMode: .bilingual),
            as: .plainText
        )
        XCTAssertTrue(plainText.contains("预算已批准"))
        XCTAssertTrue(plainText.contains("The budget is approved"))

        let jsonString = SessionExporter.export(
            SessionExportPayload(record: record.record, lines: lines, captionDisplayMode: .bilingual),
            as: .json
        )
        let jsonObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any]
        )
        let jsonLines = try XCTUnwrap(jsonObject["lines"] as? [[String: Any]])
        XCTAssertEqual(jsonLines.first?["translated_text"] as? String, "预算已批准")
        XCTAssertEqual(jsonLines.first?["source_language"] as? String, "en")
    }

    func testSingleLineParagraphKeepsItsSpeakerAttributionOnExport() {
        let line = TranscriptLine(
            id: "single", sessionID: "session", ordinal: 1, role: .speaker,
            text: "同一句", source: .microphone,
            attributionUnits: [
                .init(id: "a", textStart: 0, textEnd: 1, speakerLabel: "A")
            ],
            paragraphID: "single"
        )
        let projected = SessionExporter.paragraphLines([line])
        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected.first?.attributionUnits.count, 1)
        XCTAssertFalse(projected.first?.speakerLabelIsManual ?? true)
    }

    func testCaptionExportGroupsPersistedParagraphAndUsesFirstLineTranslation() async throws {
        let store = try XCTUnwrap(store)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "但。", source: .system, tStart: 0, tEnd: 1), id: "paragraph-first")
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "看完幕后资料以后，外媒开得更猛。", source: .system, tStart: 1, tEnd: 4), id: "paragraph-second")
        _ = try await store.attachLineParagraphID(lineID: "paragraph-first", paragraphID: "paragraph-first")
        _ = try await store.attachLineParagraphID(lineID: "paragraph-second", paragraphID: "paragraph-first")
        _ = try await store.attachLineTranslation(
            lineID: "paragraph-first", translatedText: "但看完幕后资料以后，外媒开得更猛。", sourceLanguage: "zh"
        )
        let sessions = try await store.listSessions()
        let record = try XCTUnwrap(sessions.first)
        let lines = try await store.lines(sessionID: id)
        let payload = SessionExportPayload(record: record.record, lines: lines, captionDisplayMode: .bilingual)

        let plain = SessionExporter.export(payload, as: .plainText)
        XCTAssertTrue(plain.contains("但看完幕后资料以后，外媒开得更猛。"))
        XCTAssertFalse(plain.contains("但。 看完"))

        let markdown = SessionExporter.export(payload, as: .markdown)
        XCTAssertTrue(markdown.contains("但看完幕后资料以后，外媒开得更猛。"))
        XCTAssertFalse(markdown.contains("但。 看完"))

        let srt = SessionExporter.export(payload, as: .srt)
        let srtCues = srt.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        XCTAssertEqual(srtCues.count, 1, "同一段落的多条 ASR 行在 SRT 中应合并为 1 条字幕块")
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:04,000"), "SRT 应跨越整段的起止时间码")
        XCTAssertTrue(srt.contains("但看完幕后资料以后，外媒开得更猛。"))

        let jsonString = SessionExporter.export(payload, as: .json)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any])
        let jsonLines = try XCTUnwrap(root["lines"] as? [[String: Any]])
        XCTAssertEqual(jsonLines.count, 1)
        XCTAssertEqual(jsonLines.first?["paragraph_id"] as? String, "paragraph-first")
        XCTAssertEqual(jsonLines.first?["translated_text"] as? String, "但看完幕后资料以后，外媒开得更猛。")
    }

    func testCaptionExportGroupsKoreanWithWordSpaces() async throws {
        let store = try XCTUnwrap(store)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "오늘", source: .system, tStart: 0, tEnd: 1), id: "korean-first")
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "회의", source: .system, tStart: 1, tEnd: 2), id: "korean-second")
        _ = try await store.attachLineParagraphID(lineID: "korean-first", paragraphID: "korean-first")
        _ = try await store.attachLineParagraphID(lineID: "korean-second", paragraphID: "korean-first")
        let sessions = try await store.listSessions()
        let record = try XCTUnwrap(sessions.first)
        let lines = try await store.lines(sessionID: id)
        let plain = SessionExporter.export(
            SessionExportPayload(record: record.record, lines: lines), as: .plainText
        )
        XCTAssertTrue(plain.contains("오늘 회의"))
    }

    func testLiveAndStoredPresentationKeepMixedSpeakersUnicodeAndUnknownWords() {
        let units: [TranscriptAttributionUnit] = [
            .init(id: "a", textStart: 1, textEnd: 3, speakerLabel: "A"),
            .init(id: "b", textStart: 4, textEnd: 5, speakerLabel: "B"),
            .init(id: "unknown", textStart: 6, textEnd: 7, speakerLabel: nil)
        ]
        let stored = TranscriptLine(id: "display", sessionID: "session", ordinal: 1,
            role: .speaker, text: "（甲😀，乙？丙。）", source: .microphone, attributionUnits: units)
        let live = MeetingSession.Line(id: "display", ordinal: 1, text: stored.text, start: 1, end: 3,
            speakerLabel: nil, attributionUnits: units, source: .microphone, isDeviceSwitch: false, timingQuality: .aligned)
        XCTAssertEqual(stored.displaySpeakerRuns, live.displaySpeakerRuns)
        XCTAssertEqual(stored.displaySpeakerRuns.map(\.text), ["（甲😀，", "乙？", "丙。）"])
        XCTAssertEqual(stored.displaySpeakerRuns.map(\.speakerLabel), ["A", "B", nil])
        XCTAssertEqual(stored.displaySpeakerRuns.map(\.textStart), [0, 4, 6])
        XCTAssertEqual(stored.displaySpeakerRuns.map(\.textEnd), [4, 6, 9])
        XCTAssertEqual(stored.displaySpeakerRuns.map(\.text).joined(), stored.text)
        XCTAssertEqual(stored.speakerLabels, ["A", "B"])
        XCTAssertEqual(TranscriptSpeakerRun.formattedText(live.displaySpeakerRuns, names: ["B": "主讲"], showUnknown: true),
                       "说话人 A：（甲😀，\n主讲：乙？\n未确认说话人：丙。）")
        XCTAssertEqual(stored.attributionUnits, units, "presentation cannot rewrite the acoustic evidence")
    }

    func testManualDisplayAndLegacyCopyPreserveWholeLineSemantics() {
        var line = TranscriptLine(id: "manual", sessionID: "session", ordinal: 1, role: .speaker,
            speakerLabel: "C", text: "甲乙", source: .microphone,
            attributionUnits: [.init(id: "stale", textStart: 0, textEnd: 1, speakerLabel: "A")],
            speakerLabelIsManual: true)
        XCTAssertEqual(line.displaySpeakerRuns.map(\.speakerLabel), ["C"])
        XCTAssertEqual(line.speakerLabels, ["C"])
        line.attributionUnits = []
        line.speakerLabel = nil
        line.speakerLabelIsManual = false
        XCTAssertEqual(TranscriptSpeakerRun.formattedText(line.displaySpeakerRuns, names: [:], showUnknown: false), "甲乙")
    }

    func testUnalignedPunctuationDoesNotCreateRepeatedSpeakerHeaders() async throws {
        let store = try XCTUnwrap(store)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "（甲，乙。）", source: .microphone), id: "export-punctuation")
        let row = try await store.attachTranscriptAttribution(lineID: "export-punctuation", units: [
            .init(id: "a", textStart: 1, textEnd: 2, speakerLabel: "A"),
            .init(id: "b", textStart: 3, textEnd: 4, speakerLabel: "A")
        ])
        let records = try await store.listSessions()
        let record = try XCTUnwrap(records.first)
        let payload = SessionExportPayload(record: record.record, lines: [row])
        XCTAssertEqual(payload.transcriptText(for: row), "说话人 A：（甲，乙。）")
        XCTAssertEqual(row.speakerRuns.map(\.text).joined(), row.text)
    }

    func testManualAndLegacyExportsKeepWholeLineBehavior() async throws {
        let store = try XCTUnwrap(store)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "甲乙", source: .microphone), id: "export-manual")
        _ = try await store.attachTranscriptAttribution(lineID: "export-manual", units: [
            .init(id: "a", textStart: 0, textEnd: 1, speakerLabel: "A"),
            .init(id: "b", textStart: 1, textEnd: 2, speakerLabel: "B")
        ])
        let manual = try await store.attachSpeakerLabel(lineID: "export-manual", label: "C")
        let records = try await store.listSessions()
        let record = try XCTUnwrap(records.first)
        let payload = SessionExportPayload(record: record.record, lines: [manual])
        XCTAssertTrue(SessionExporter.export(payload, as: .plainText).contains("说话人 C：甲乙"))
        XCTAssertFalse(SessionExporter.export(payload, as: .plainText).contains("说话人 A"))
        var legacy = manual
        legacy.speakerLabelIsManual = false
        legacy.speakerLabel = nil
        XCTAssertFalse(SessionExporter.export(.init(record: record.record, lines: [legacy]), as: .plainText)
            .contains("未确认说话人"))
    }

    func testWordAttributionSurvivesAllReadsAndReopenWithoutChangingText() async throws {
        let store = try XCTUnwrap(store)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "甲😀，乙。", source: .microphone), id: "mixed-words")
        let units: [TranscriptAttributionUnit] = [
            .init(id: "first", textStart: 0, textEnd: 2, speakerLabel: "A"),
            .init(id: "second", textStart: 3, textEnd: 4, speakerLabel: "B")
        ]
        let row = try await store.attachTranscriptAttribution(lineID: "mixed-words", units: units)
        XCTAssertNil(row.speakerLabel, "a mixed line cannot claim one speaker")
        XCTAssertEqual(row.text, "甲😀，乙。")
        XCTAssertEqual(row.attributionUnits, units)
        XCTAssertEqual(row.speakerRuns.map(\.text).joined(), row.text)
        XCTAssertEqual(row.speakerRuns.compactMap(\.speakerLabel), ["A", "B"])
        let page = try await store.linesPage(sessionID: id, beforeOrdinal: nil)
        let range = try await store.linesRange(sessionID: id, ordinals: 1...1)
        let search = try await store.searchLines(query: "甲")
        for fetched in [page.rows.first, range.first, search.first] {
            XCTAssertEqual(fetched?.attributionUnits, units)
        }
        await store.close()
        try await store.open()
        let reopened = try await store.lines(sessionID: id)
        XCTAssertEqual(reopened.first?.attributionUnits, units)
        XCTAssertNil(reopened.first?.speakerLabel)
        XCTAssertEqual(reopened.first?.id, "mixed-words")
        let backup = try await store.exportBackup(to: try XCTUnwrap(directory).appendingPathComponent("word-backup"))
        let scratch = try XCTUnwrap(directory).appendingPathComponent("word-restored")
        _ = try await SessionStore.restorePreview(of: backup, into: scratch)
        let restored = SessionStore(directory: scratch)
        try await restored.open()
        let restoredRows = try await restored.lines(sessionID: id)
        XCTAssertEqual(restoredRows.first?.attributionUnits, units)
        XCTAssertEqual(restoredRows.first?.text, row.text)
        await restored.close()
    }

    func testAttributionSchemaUpgradePreservesLegacyRows() async throws {
        let store = try XCTUnwrap(store)
        let directory = try XCTUnwrap(directory)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "原记录", source: .microphone, speakerLabel: "A"), id: "legacy-attribution")
        await store.close()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent(SessionStore.fileName).path,
            &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE line DROP COLUMN attribution_json; ALTER TABLE line DROP COLUMN speaker_label_is_manual; PRAGMA user_version=13;", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(db)
        try await store.open()
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.id, "legacy-attribution")
        XCTAssertEqual(rows.first?.text, "原记录")
        XCTAssertEqual(rows.first?.speakerLabel, "A")
        XCTAssertEqual(rows.first?.attributionUnits, [])
        XCTAssertEqual(rows.first?.speakerLabelIsManual, false, "migration cannot infer historical manual actions")
        await store.close()
        try await store.open()
        let reopened = try await store.lines(sessionID: id)
        XCTAssertEqual(reopened, rows)
    }

    func testSchemaV15ToV16UpgradeAddsParagraphIDAndPreservesLegacyRows() async throws {
        let store = try XCTUnwrap(store)
        let directory = try XCTUnwrap(directory)
        let id = try await seedSession()
        _ = try await store.appendLine(
            .init(sessionID: id, role: .speaker, text: "v15 旧行", source: .microphone),
            id: "legacy-v15-line"
        )
        await store.close()

        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(directory.appendingPathComponent(SessionStore.fileName).path, &db, SQLITE_OPEN_READWRITE, nil),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(db, "ALTER TABLE line DROP COLUMN paragraph_id; PRAGMA user_version=15;", nil, nil, nil),
            SQLITE_OK
        )
        sqlite3_close_v2(db)

        try await store.open()
        let upgradedRows = try await store.lines(sessionID: id)
        XCTAssertEqual(upgradedRows.count, 1)
        XCTAssertEqual(upgradedRows.first?.id, "legacy-v15-line")
        XCTAssertEqual(upgradedRows.first?.text, "v15 旧行")
        XCTAssertNil(upgradedRows.first?.paragraphID, "v15 旧记录升级到 v16 后 paragraph_id 应保持为 nil")

        try await store.attachLineParagraphID(lineID: "legacy-v15-line", paragraphID: "para-v16")
        let attachedRows = try await store.lines(sessionID: id)
        XCTAssertEqual(attachedRows.first?.paragraphID, "para-v16")
    }

    func testEmptyAutomaticSnapshotClearsPriorSummary() async throws {
        let store = try XCTUnwrap(store)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "甲", source: .microphone), id: "clear-evidence")
        _ = try await store.attachTranscriptAttribution(lineID: "clear-evidence",
            units: [.init(id: "one", textStart: 0, textEnd: 1, speakerLabel: "A")])
        let cleared = try await store.attachTranscriptAttribution(lineID: "clear-evidence", units: [])
        XCTAssertNil(cleared.speakerLabel)
        XCTAssertEqual(cleared.speakerRuns.map(\.speakerLabel), [nil])
    }

    func testInvalidAttributionDoesNotPartiallyOverwritePriorEvidence() async throws {
        let store = try XCTUnwrap(store)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "甲乙", source: .microphone), id: "validated-words")
        let original = [TranscriptAttributionUnit(id: "one", textStart: 0, textEnd: 2, speakerLabel: "A")]
        _ = try await store.attachTranscriptAttribution(lineID: "validated-words", units: original)
        let invalid: [[TranscriptAttributionUnit]] = [
            [.init(id: "one", textStart: 0, textEnd: 3, speakerLabel: "B")],
            [.init(id: "one", textStart: 0, textEnd: 1, speakerLabel: "B", audioStartSample: 2, audioEndSample: 1)],
            [.init(id: "one", textStart: 0, textEnd: 2, speakerLabel: "B"),
             .init(id: "two", textStart: 1, textEnd: 2, speakerLabel: "A")],
            [.init(id: "one", textStart: 0, textEnd: 1, speakerLabel: "B"),
             .init(id: "one", textStart: 1, textEnd: 2, speakerLabel: "A")]
        ]
        for units in invalid {
            do {
                _ = try await store.attachTranscriptAttribution(lineID: "validated-words", units: units)
                XCTFail("invalid complete snapshots must fail before writing")
            } catch {}
            let saved = try await store.lines(sessionID: id)
            XCTAssertEqual(saved.first?.attributionUnits, original)
            XCTAssertEqual(saved.first?.speakerLabel, "A")
            XCTAssertEqual(saved.first?.text, "甲乙")
        }
    }

    func testUnknownAndLateCorrectionsRemainWordScopedAndManualChoiceWins() async throws {
        let store = try XCTUnwrap(store)
        let id = try await seedSession()
        _ = try await store.appendLine(.init(sessionID: id, role: .speaker,
            text: "甲乙", source: .microphone), id: "late-words")
        let first: [TranscriptAttributionUnit] = [
            .init(id: "one", textStart: 0, textEnd: 1, speakerLabel: "A"),
            .init(id: "two", textStart: 1, textEnd: 2, speakerLabel: nil)
        ]
        let unknown = try await store.attachTranscriptAttribution(lineID: "late-words", units: first)
        XCTAssertNil(unknown.speakerLabel)
        XCTAssertEqual(unknown.speakerRuns.map(\.speakerLabel), ["A", nil])
        var corrected = first
        corrected[1].speakerLabel = "B"
        let changed = try await store.attachTranscriptAttribution(lineID: "late-words", units: corrected)
        XCTAssertEqual(changed.attributionUnits.map(\.speakerLabel), ["A", "B"])
        try await store.attachSpeakerLabel(lineID: "late-words", label: "C")
        let manual = try await store.attachTranscriptAttribution(lineID: "late-words", units: first)
        XCTAssertEqual(manual.speakerLabel, "C", "late automatic evidence cannot erase a manual choice")
        XCTAssertTrue(manual.speakerLabelIsManual)
        XCTAssertTrue(manual.attributionUnits.isEmpty)
        XCTAssertEqual(manual.speakerRuns.map(\.speakerLabel), ["C"])
        try await store.attachSpeakerLabel(lineID: "late-words", label: nil)
        let manuallyCleared = try await store.attachTranscriptAttribution(lineID: "late-words", units: corrected)
        XCTAssertNil(manuallyCleared.speakerLabel)
        XCTAssertTrue(manuallyCleared.speakerLabelIsManual)
    }

    func testRecoveryMaterialIsRetrievableByDefault() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("已经显示过的半句", status: .partial, sessionID: sessionID)
        // 默认读回（记录库、导出、纪要的口径）**不包含**它。
        let final = try await store.lines(sessionID: sessionID)
        XCTAssertTrue(final.isEmpty)
    }

    func testRecoveryMaterialIsRetrievableWhenAskedFor() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("已经显示过的半句", status: .partial, sessionID: sessionID)
        let all = try await store.lines(sessionID: sessionID, includePartial: true)
        let recovered = try XCTUnwrap(all.first { $0.status == .partial })
        XCTAssertEqual(recovered.text, "已经显示过的半句")
    }

    /// 纪要不收恢复材料，靠的是**纪要读库时用的就是默认口径**
    /// （`MinutesGenerator` 三处都调 `coordinator.lines(sessionID:)`，
    /// 签名默认 `includePartial: false`）。
    ///
    /// `MinutesGenerator` 是 App-only 文件、不在 SPM 目标内，所以这里断言的是
    /// 它依赖的那条库层契约；调用点本身是**代码审查确认**的，不是本测试证明的。
    func testDefaultReadIsTheContractMinutesReliesOn() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("定稿的那句", status: .final, sessionID: sessionID)
        try await append("只有半句的那句", status: .partial, sessionID: sessionID)

        let finalLines = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(finalLines.map(\.text), ["定稿的那句"])
    }

    func testCoordinatorDefaultReadAlsoExcludesRecoveryMaterial() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("半句", status: .partial, sessionID: sessionID)
        // 协调器是纪要的取数入口，它的默认值必须与 store 一致。
        let coordinator = SessionCoordinator(store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let viaCoordinator = try await coordinator.lines(sessionID: sessionID)
        XCTAssertTrue(viaCoordinator.isEmpty)
    }

    func testRecoveryMaterialSurvivesReopen() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("重启也要还在", status: .partial, sessionID: sessionID)
        try await store.close()
        try await store.open()
        let all = try await store.lines(sessionID: sessionID, includePartial: true)
        XCTAssertTrue(all.contains { $0.text == "重启也要还在" })
    }

    func testRecoveryMaterialKeepsItsOwnOrdinalAmongFinals() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        let a = try await append("第一句", status: .final, sessionID: sessionID)
        let b = try await append("只剩半句", status: .partial, sessionID: sessionID)
        let c = try await append("第三句", status: .final, sessionID: sessionID)
        // 序号单调，中间不留洞——否则引用会指错行。
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }

    func testRecoveryMaterialIsMarkedAsUntimedRatherThanSpoken() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try await seedSession()
        try await append("半句", status: .partial, sessionID: sessionID)
        let all = try await store.lines(sessionID: sessionID, includePartial: true)
        let recovered = try XCTUnwrap(all.first)
        // 恢复材料同样不许把记录时刻说成说话时刻。
        XCTAssertEqual(recovered.timingQuality, .unavailable)
    }
}

@MainActor
final class SpeakerLabelingPersistenceTests: XCTestCase {
    private var directory: URL!
    private var store: SessionStore!
    private var coordinator: SessionCoordinator!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SessionStore(directory: directory)
        try await store.open()
        defaultsName = "speaker-persistence-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        coordinator = SessionCoordinator(store: store, defaults: defaults)
    }

    override func tearDown() async throws {
        await store.close()
        defaults.removePersistentDomain(forName: defaultsName)
        try FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func record(with ids: [String], text: String = "词") async throws -> String {
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        for id in ids {
            _ = try await store.appendLine(
                LineDraft(sessionID: record.id, role: .speaker, text: text, source: .microphone), id: id
            )
        }
        return record.id
    }

    func testMixedWordsPersistWithoutCollapsingTheirSpeakers() async throws {
        let id = try await record(with: ["甲乙"], text: "甲乙")
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [
            .init(segmentUID: "one", speaker: "A", textStart: 0, textEnd: 1),
            .init(segmentUID: "two", speaker: "B", textStart: 1, textEnd: 2)
        ]
        owner.register(units: units, lineID: "甲乙", ordinal: 1)
        await owner.apply(units: units)
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.attributionUnits.map(\.speakerLabel), ["A", "B"])
        XCTAssertNil(rows.first?.speakerLabel)
        XCTAssertNil(owner.attributedLabel(forLineID: "甲乙"))
        XCTAssertEqual(rows.first?.speakerRuns.map(\.text).joined(), "甲乙")
    }

    func testPartialUnknownRevisionKeepsOtherWordsKnown() async throws {
        let id = try await record(with: ["甲乙"], text: "甲乙")
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [
            .init(segmentUID: "one", speaker: "A", textStart: 0, textEnd: 1),
            .init(segmentUID: "two", speaker: "B", textStart: 1, textEnd: 2)
        ]
        owner.register(units: units, lineID: "甲乙", ordinal: 1)
        await owner.apply(units: units)
        await owner.apply(units: [.init(segmentUID: "two", speaker: nil, textStart: 1, textEnd: 2)])
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.attributionUnits.map(\.speakerLabel), ["A", nil])
        XCTAssertNil(owner.attributedLabel(forLineID: "甲乙"))
        XCTAssertEqual(rows.first?.text, "甲乙")
    }

    func testAutomaticLabelsRespectManualRowChoice() async throws {
        let id = try await record(with: ["甲乙"], text: "甲乙")
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        let initial: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "one", speaker: "A", textStart: 0, textEnd: 2)]
        owner.register(units: initial, lineID: "甲乙", ordinal: 1)
        await owner.apply(units: initial)
        XCTAssertEqual(owner.liveUnitCount, 1)
        await owner.split(lineIDs: ["甲乙"], to: "B")
        XCTAssertEqual(owner.liveUnitCount, 0)
        await owner.apply(units: [.init(segmentUID: "one", speaker: "C", textStart: 0, textEnd: 2)])
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.speakerLabel, "B")
        XCTAssertEqual(owner.attributedLabel(forLineID: "甲乙"), "B")
    }

    func testManualChoiceIsReflectedAfterRepeatedIdenticalAutomaticSnapshot() async throws {
        let id = try await record(with: ["甲乙"], text: "甲乙")
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "one", speaker: "A", textStart: 0, textEnd: 2)]
        owner.register(units: units, lineID: "甲乙", ordinal: 1)
        await owner.apply(units: units)
        await owner.split(lineIDs: ["甲乙"], to: "B")
        XCTAssertEqual(owner.liveUnitCount, 0)
        await owner.apply(units: units)
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.speakerLabel, "B")
        XCTAssertEqual(owner.attributedLabel(forLineID: "甲乙"), "B")
    }

    func testMissingTextRangeCannotReplaceSavedWordEvidence() async throws {
        let id = try await record(with: ["甲乙"], text: "甲乙")
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "one", speaker: "A", textStart: 0, textEnd: 2)]
        owner.register(units: units, lineID: "甲乙", ordinal: 1)
        await owner.apply(units: units)
        await owner.apply(units: [.init(segmentUID: "one", speaker: "B")])
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.attributionUnits.map(\.speakerLabel), ["A"])
        XCTAssertEqual(owner.attributedLabel(forLineID: "甲乙"), "A")
        XCTAssertNotNil(owner.note)
    }

    func testFailedWholeSnapshotIsRetryableAndSuccessDeduplicates() async throws {
        let id = try await record(with: ["甲乙"], text: "甲乙")
        var attempts = 0
        let owner = SpeakerLabeling(coordinator: coordinator, attachAttribution: { [store] lineID, units in
            attempts += 1
            if attempts == 1 { throw SessionStoreError.storageUnavailable }
            return try await store!.attachTranscriptAttribution(lineID: lineID, units: units)
        })
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [
            .init(segmentUID: "one", speaker: "A", textStart: 0, textEnd: 1),
            .init(segmentUID: "two", speaker: "B", textStart: 1, textEnd: 2)
        ]
        owner.register(units: units, lineID: "甲乙", ordinal: 1)
        await owner.apply(units: units)
        XCTAssertNil(owner.attributedLine(forLineID: "甲乙"))
        await owner.apply(units: units)
        await owner.apply(units: units)
        XCTAssertEqual(attempts, 2)
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.attributionUnits.map(\.speakerLabel), ["A", "B"])
        XCTAssertEqual(owner.attributedLine(forLineID: "甲乙"), rows.first)
    }

    private func waitUntilEntered(_ gate: SpeakerAttributionWriteGate) async throws {
        for _ in 0..<1_000 {
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("speaker write never entered the gate")
        await gate.release()
    }

    func testWholeBatchKeepsOldTargetsAcrossNewSessionDuringWrite() async throws {
        let old = try await record(with: ["old-one", "old-two"])
        let new = try await record(with: ["new-two"])
        let gate = SpeakerAttributionWriteGate(store: store)
        let owner = SpeakerLabeling(coordinator: coordinator, attachAttribution: { try await gate.write($0, units: $1) })
        owner.begin(sessionID: old, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [
            .init(segmentUID: "one", speaker: "A", textStart: 0, textEnd: 1), .init(segmentUID: "two", speaker: "B", textStart: 0, textEnd: 1)
        ]
        owner.register(units: [units[0]], lineID: "old-one", ordinal: 1)
        owner.register(units: [units[1]], lineID: "old-two", ordinal: 2)
        let task = Task { await owner.apply(units: units) }
        try await waitUntilEntered(gate)
        owner.begin(sessionID: new, enabled: true)
        owner.register(units: [.init(segmentUID: "two", speaker: nil, textStart: 0, textEnd: 1)], lineID: "new-two", ordinal: 1)
        await gate.release()
        await task.value
        let oldRows = try await store.lines(sessionID: old)
        let newRows = try await store.lines(sessionID: new)
        XCTAssertEqual(oldRows.map(\.speakerLabel), ["A", "B"])
        XCTAssertNil(newRows.first?.speakerLabel)
        XCTAssertTrue(owner.labels.isEmpty, "old completions must not populate new-session labels")
    }

    func testHistoryLoadInvalidatesLateLiveProjection() async throws {
        let old = try await record(with: ["old"])
        let new = try await record(with: ["history"])
        let gate = SpeakerAttributionWriteGate(store: store)
        let owner = SpeakerLabeling(coordinator: coordinator, attachAttribution: { try await gate.write($0, units: $1) })
        owner.begin(sessionID: old, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit", speaker: "A", textStart: 0, textEnd: 1)]
        owner.register(units: units, lineID: "old", ordinal: 1)
        let task = Task { await owner.apply(units: units) }
        try await waitUntilEntered(gate)
        owner.load(sessionID: new, labels: ["C"], displayNames: ["C": "历史说话人"])
        await gate.release()
        await task.value
        XCTAssertEqual(owner.labels, ["C"])
        XCTAssertNil(owner.attributedLabel(forLineID: "old"))
        let rows = try await store.lines(sessionID: old)
        XCTAssertEqual(rows.first?.speakerLabel, "A", "accepted old work still writes its frozen target")
    }

    func testRebindingUnitDoesNotReusePriorLinesPersistenceProof() async throws {
        let id = try await record(with: ["one", "two"])
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit", speaker: "A", textStart: 0, textEnd: 1)]
        owner.register(units: units, lineID: "one", ordinal: 1)
        await owner.apply(units: units)
        owner.register(units: units, lineID: "two", ordinal: 2)
        await owner.apply(units: units)
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.speakerLabel), ["A", "A"])
    }

    func testRebindingDuringWriteDoesNotMarkNewLineAsAlreadyPersisted() async throws {
        let id = try await record(with: ["one", "two"])
        let gate = SpeakerAttributionWriteGate(store: store)
        let owner = SpeakerLabeling(coordinator: coordinator, attachAttribution: { try await gate.write($0, units: $1) })
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit", speaker: "A", textStart: 0, textEnd: 1)]
        owner.register(units: units, lineID: "one", ordinal: 1)
        let task = Task { await owner.apply(units: units) }
        try await waitUntilEntered(gate)
        owner.register(units: units, lineID: "two", ordinal: 2)
        await gate.release()
        await task.value
        await owner.apply(units: units)
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.speakerLabel), ["A", "A"])
    }

    func testQueuedCommandKeepsItsTargetAcrossSameRecordGenerationReset() async throws {
        let id = try await record(with: ["old-generation", "new-generation"])
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit", speaker: "A", textStart: 0, textEnd: 1)]
        owner.register(units: units, lineID: "old-generation", ordinal: 1)
        let command = owner.freezeAttribution(units: units)
        owner.begin(sessionID: id, enabled: true)
        owner.register(
            units: [.init(segmentUID: "unit", speaker: nil, textStart: 0, textEnd: 1)], lineID: "new-generation", ordinal: 2
        )
        await owner.apply(command)
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.speakerLabel), ["A", nil])
        XCTAssertTrue(owner.labels.isEmpty)
        XCTAssertNil(owner.attributedLabel(forLineID: "new-generation"))
    }

    func testQueuedNilRevisionClearsPriorWriteInsteadOfBeingDiscardedAtAcceptance() async throws {
        let id = try await record(with: ["line"])
        let gate = SpeakerAttributionWriteGate(store: store)
        let owner = SpeakerLabeling(coordinator: coordinator, attachAttribution: { try await gate.write($0, units: $1) })
        owner.begin(sessionID: id, enabled: true)
        let units: [RealtimeASRClient.AttributionUnit] = [.init(segmentUID: "unit", speaker: "A", textStart: 0, textEnd: 1)]
        owner.register(units: units, lineID: "line", ordinal: 1)
        let first = Task { await owner.apply(units: units) }
        try await waitUntilEntered(gate)
        let clear = owner.freezeAttribution(units: [.init(segmentUID: "unit", speaker: nil, textStart: 0, textEnd: 1)])
        await gate.release()
        await first.value
        await owner.apply(clear)
        let rows = try await store.lines(sessionID: id)
        XCTAssertNil(rows.first?.speakerLabel)
        XCTAssertNil(owner.attributedLabel(forLineID: "line"))
    }

    /// Gap3（账本级）：`beginNewConnection` 只重置 uid 坐标系，不碰面板。
    ///
    /// 两个方向都要钉住：面板（标签/改名/计数/状态）保留是修"续接失忆"；
    /// uid 表清空是防"旧坐标串写"——若只保留面板而不清空，
    /// 旧 uid 的迟到修订会把旧行改写成新说话人。
    func testBeginNewConnectionKeepsPanelButResetsUnitCoordinates() async throws {
        let id = try await record(with: ["old", "new"])
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        owner.register(
            units: [.init(segmentUID: "unit", speaker: "A", textStart: 0, textEnd: 1)], lineID: "old", ordinal: 1
        )
        await owner.apply(units: [.init(segmentUID: "unit", speaker: "A", textStart: 0, textEnd: 1)])
        await owner.rename(label: "A", to: "张三")
        XCTAssertEqual(owner.labels, ["A"])
        XCTAssertEqual(owner.displayNames["A"], "张三")

        owner.beginNewConnection(sessionID: id)

        // 面板保留：标签、改名、计数、状态都在。
        XCTAssertEqual(owner.labels, ["A"])
        XCTAssertEqual(owner.displayNames["A"], "张三")
        XCTAssertEqual(owner.lineCounts["A"], 1)
        XCTAssertEqual(owner.firstOrdinal["A"], 1)
        XCTAssertEqual(owner.state, .active)
        // uid 坐标系已清空：旧 uid 的迟到修订无处可写，旧行保持原值。
        XCTAssertNil(owner.attributedLabel(forLineID: "old"))
        await owner.apply(units: [.init(segmentUID: "unit", speaker: "B", textStart: 0, textEnd: 1)])
        let rows = try await store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.speakerLabel), ["A", nil])
        // 新 uid 照常写入：重置不断新写。
        owner.register(
            units: [.init(segmentUID: "unit-2", speaker: "B", textStart: 0, textEnd: 1)], lineID: "new", ordinal: 2
        )
        await owner.apply(units: [.init(segmentUID: "unit-2", speaker: "B", textStart: 0, textEnd: 1)])
        let rowsAfter = try await store.lines(sessionID: id)
        XCTAssertEqual(rowsAfter.map(\.speakerLabel), ["A", "B"])
        XCTAssertEqual(owner.labels, ["A", "B"])
    }

    /// Gap3（账本级）：续接不治愈降级态，只是不擦除显示。
    func testBeginNewConnectionDoesNotHealDegradedState() async throws {
        let id = try await record(with: ["old"])
        let owner = SpeakerLabeling(coordinator: coordinator)
        owner.begin(sessionID: id, enabled: true)
        owner.markDegraded(code: "diarization_overloaded", message: "过载停更")
        owner.beginNewConnection(sessionID: id)
        XCTAssertEqual(owner.state, .degraded)
        XCTAssertEqual(owner.note, "过载停更")
        XCTAssertTrue(owner.isEnabled)
    }
}

actor SpeakerAttributionWriteGate {
    private var store: SessionStore?
    private var continuation: CheckedContinuation<Void, Never>?
    private var blocked = true
    private(set) var entered = false

    init(store: SessionStore? = nil) { self.store = store }

    func attach(_ store: SessionStore) { self.store = store }

    func write(_ lineID: String, units: [TranscriptAttributionUnit]) async throws -> TranscriptLine {
        if blocked {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        guard let store else { throw TranscriptPersistenceGate.Failure.unavailable }
        return try await store.attachTranscriptAttribution(lineID: lineID, units: units)
    }

    func release() {
        blocked = false
        continuation?.resume()
        continuation = nil
    }
}

/// 真实 Store 边界前的确定性 Gate；不接设备或网络。
actor TranscriptPersistenceGate {
    enum Failure: Error { case unavailable }
    private var store: SessionStore?
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var blocked = true
    private var failing = false
    private(set) var entered = false
    private(set) var attempts: [(draft: LineDraft, id: String)] = []

    func attach(_ store: SessionStore) { self.store = store }

    func save(_ draft: LineDraft, id: String) async throws -> Int {
        attempts.append((draft, id))
        if blocked {
            entered = true
            await withCheckedContinuation { continuations.append($0) }
        }
        if failing { throw Failure.unavailable }
        guard let store else { throw Failure.unavailable }
        return try await store.appendLine(draft, id: id)
    }

    func release(failing: Bool = false) {
        blocked = false
        self.failing = failing
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

/// 故障仅注入测试自建数据库，不给生产 Store 添加测试开关。
func executeTranscriptRecoverySQL(directory: URL, statement: String) throws {
    var db: OpaquePointer?
    XCTAssertEqual(
        sqlite3_open_v2(
            directory.appendingPathComponent(SessionStore.fileName).path,
            &db, SQLITE_OPEN_READWRITE, nil
        ),
        SQLITE_OK
    )
    let pointer = try XCTUnwrap(db)
    defer { sqlite3_close_v2(pointer) }
    XCTAssertEqual(sqlite3_busy_timeout(pointer, 10_000), SQLITE_OK)
    XCTAssertEqual(sqlite3_exec(pointer, statement, nil, nil, nil), SQLITE_OK)
}

/// 只替换网络 transport；解析、终态去重和结束协议使用生产客户端。
struct TranscriptRealtimeTestClient: MeetingRealtimeClient, CaptionRealtimeClient {
    let client: RealtimeASRClient
    let transport: TranscriptRealtimeTestTransport

    func events() async -> RealtimeEventStream<RealtimeASRClient.Event> { await client.events() }
    func connect() async throws { try await client.connect(using: transport) }
    func append(_ pcm: Data) async throws { try await client.append(pcm) }
    func flushPendingUtterance() async throws { try await client.flushPendingUtterance() }
    func drainAndClear(timeout: Duration) async throws { try await client.drainAndClear(timeout: timeout) }
    func close() async { await client.close() }
}

actor TranscriptRealtimeTestTransport: RealtimeASRTransport {
    private enum Failure: Error { case closed }
    private var frames: [RealtimeASRSocketFrame] = []
    private var receiver: CheckedContinuation<RealtimeASRSocketFrame, Error>?
    private var sequence = 0
    private var closed = false

    func resume() async {}
    func closeCode() async -> Int? { nil }

    func send(_ text: String) async throws {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "session.update":
            let session = object["session"] as? [String: Any] ?? [:]
            let speechrail = session["speechrail"] as? [String: Any] ?? [:]
            var policy = speechrail["asr"] as? [String: Any] ?? [:]
            policy["effective_max_segment_ms"] = policy["max_segment_ms"]
            policy["final_deadline_ms"] = policy["final_deadline_ms"] ?? 120_000
            try deliver(["type": "session.updated", "session": ["speechrail": ["asr": policy]]])
        case "input_audio_buffer.commit":
            try deliver([
                "type": "speechrail.input_audio_buffer.committed",
                "commit_event_id": object["event_id"] ?? "",
                "accepted_samples": 0
            ])
        default: break
        }
    }

    func completed(itemID: String, text: String) throws {
        try deliver([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": itemID, "transcript": text
        ])
    }

    func control(_ message: String) throws {
        try deliver(["type": "error", "error": ["code": "test_control", "message": message]])
    }

    private func deliver(_ object: [String: Any]) throws {
        var stamped = object
        stamped["event_id"] = "persistence-event-\(sequence)"
        stamped["session_id"] = "persistence-test-session"
        stamped["sequence"] = sequence
        sequence += 1
        let data = try JSONSerialization.data(withJSONObject: stamped)
        let frame = RealtimeASRSocketFrame.text(String(decoding: data, as: UTF8.self))
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: frame)
        } else {
            frames.append(frame)
        }
    }

    func receive() async throws -> RealtimeASRSocketFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { throw Failure.closed }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func cancel() async {
        closed = true
        receiver?.resume(throwing: Failure.closed)
        receiver = nil
    }
}
