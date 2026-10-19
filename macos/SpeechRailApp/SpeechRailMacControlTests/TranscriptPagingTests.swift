import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct TranscriptPagingTests {
    @Test func testLibraryCountsWordSpeakersAndRespectsManualCorrectionAndSessionScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try await store.open()
        let first = try await store.createSession(.init(kind: .meeting, engineProfile: "fixture", audioSource: .microphone))
        let second = try await store.createSession(.init(kind: .meeting, engineProfile: "fixture", audioSource: .microphone))
        _ = try await store.appendLine(.init(sessionID: first.id, role: .speaker, text: "甲乙丙", source: .microphone), id: "mixed-count")
        _ = try await store.attachTranscriptAttribution(lineID: "mixed-count", units: [
            .init(id: "a", textStart: 0, textEnd: 1, speakerLabel: "A"),
            .init(id: "b", textStart: 1, textEnd: 2, speakerLabel: "B"),
            .init(id: "unknown", textStart: 2, textEnd: 3, speakerLabel: nil)
        ])
        _ = try await store.appendLine(.init(sessionID: first.id, role: .speaker, text: "甲", source: .microphone, speakerLabel: "A"), id: "same-count")
        _ = try await store.appendLine(.init(sessionID: second.id, role: .speaker, text: "丁", source: .microphone, speakerLabel: "C"), id: "other-count")
        let before = try await store.listSessions(kind: .meeting)
        #expect(before.first(where: { $0.record.id == first.id })?.speakerCount == 2)
        #expect(before.first(where: { $0.record.id == second.id })?.speakerCount == 1)
        #expect(try await store.lines(sessionID: first.id).first(where: { $0.id == "mixed-count" })?.speakerLabels == ["A", "B"])
        _ = try await store.attachSpeakerLabel(lineID: "mixed-count", label: "D")
        #expect(try await store.listSessions().first(where: { $0.record.id == first.id })?.speakerCount == 2)
        #expect(try await store.lines(sessionID: first.id).first(where: { $0.id == "mixed-count" })?.speakerLabels == ["D"])
        _ = try await store.attachSpeakerLabel(lineID: "mixed-count", label: nil)
        #expect(try await store.listSessions().first(where: { $0.record.id == first.id })?.speakerCount == 1)
        #expect(try await store.lines(sessionID: first.id).map(\.text) == ["甲乙丙", "甲"])
        await store.close()
    }

    @Test func testFourHourArchiveRemainsCompleteAndKeysetPagesAndCopyIncludeOffscreenRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        try await store.open()
        let session = try await store.createSession(.init(kind: .meeting, engineProfile: "fixture", audioSource: .microphone))
        for ordinal in 1...2_880 {
            _ = try await store.appendLine(.init(sessionID: session.id, role: .speaker, text: "synthetic-\(ordinal)", source: .microphone), id: "line-\(ordinal)")
        }
        let latest = try await store.linesPage(sessionID: session.id, beforeOrdinal: nil)
        #expect(latest.rows.count == 200 && latest.rows.last?.ordinal == 2_880)
        let older = try await store.linesPage(sessionID: session.id, beforeOrdinal: latest.nextBeforeOrdinal)
        #expect(older.rows.last?.ordinal == 2_680)
        #expect(Set(latest.rows.map(\.id)).isDisjoint(with: older.rows.map(\.id)))
        try await store.attachSpeakerLabel(lineID: "line-1", label: "A")
        #expect(try await store.linesPage(sessionID: session.id, beforeOrdinal: 201).rows.first?.speakerLabel == "A")
        #expect(try await store.lines(sessionID: session.id).count == 2_880)
        #expect(try await store.linesRange(sessionID: session.id, ordinals: 1...2_880).count == 2_880)
        let plan = try await store.transcriptPageQueryPlan()
        #expect(plan.contains("line_by_session") && !plan.contains("TEMP B-TREE"))
        await store.close()
    }
}
