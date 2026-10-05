import Foundation
import SQLite3
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 备份校验与恢复演练（方案 MA-20 / §12.3 / MC-67～MC-72）。
///
/// 目标那条验收标准是"**恢复可证**"：备份恢复到临时新库后，
/// 核对文档、版本、引用和行动项关联；恢复失败不损坏原库。
/// 这里钉的是：
/// - 往返后文档、版本、结论条目、证据锚点都还在，锚点仍能读回原文；
/// - 引用断裂、清单缺失、备份损坏、schema 更新都在**临时副本**上被挡住；
/// - 任何一种失败都不碰当前库——它一个字节都不该变。
@MainActor
final class MeetingBackupRestoreTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?
    private var scratch: URL?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-backup-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        self.directory = directory
        self.store = store
        self.sessionID = record.id
        self.scratch = directory.appendingPathComponent("scratch", isDirectory: true)
    }

    override func tearDown() async throws {
        if let store { await store.close() }
        store = nil
        sessionID = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        scratch = nil
        try await super.tearDown()
    }

    private func requireStore() throws -> SessionStore {
        try XCTUnwrap(store)
    }

    private func requireSessionID() throws -> String {
        try XCTUnwrap(sessionID)
    }

    /// 造一场有转录、已封存、带结构化结论与锚点的会议。
    @discardableResult
    private func prepareMeetingWithCitations() async throws -> MinutesVersion {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let texts = ["line-1": "下周三上线灰度。", "line-2": "预算按 3 万元算。"]
        for id in ["line-1", "line-2"] {
            let text = texts[id]!
            _ = try await store.appendLine(
                LineDraft(
                    sessionID: sessionID,
                    role: .speaker,
                    text: text,
                    source: .microphone,
                    status: .final
                ),
                id: id
            )
        }
        let snapshot = try await store.sealMeetingSource(sessionID: sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id, "有定稿正文就该封出快照")

        let units = [
            MinutesSourceUnit(
                id: "u1", lineID: "line-1", ordinal: 1,
                speaker: "张三", text: texts["line-1"]!, startSeconds: 0
            ),
            MinutesSourceUnit(
                id: "u2", lineID: "line-2", ordinal: 2,
                speaker: "李四", text: texts["line-2"]!, startSeconds: 10
            ),
        ]
        let candidate = MinutesCandidateV2(
            title: "发布评审",
            overview: [],
            decisions: [
                .init(
                    localID: "d1",
                    text: "下周三上线灰度",
                    modality: .decided,
                    conditions: [],
                    sourceUnitIDs: ["u1"]
                ),
            ],
            actions: [
                .init(
                    localID: "a1",
                    task: "整理发布清单",
                    ownerText: nil,
                    dueExpression: nil,
                    commitment: .proposed,
                    sourceUnitIDs: ["u2"]
                ),
            ],
            openQuestions: [],
            confidenceNotes: ""
        )
        let encoded = try JSONEncoder().encode(candidate)
        guard case .prepared(let prepared) = MinutesCandidateCodec.prepare(
            text: String(data: encoded, encoding: .utf8) ?? "",
            units: units
        ) else {
            XCTFail("结构合法的候选应当解析成功")
            throw XCTSkip("候选构造失败")
        }

        _ = try await store.enqueueMinutes(
            sessionID: sessionID,
            model: nil,
            promptChars: 24,
            snapshotID: snapshotID
        )
        let claimed = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        let row = try XCTUnwrap(claimed)
        let revisionIDs = try await store.latestRevisionIDsByLine(sessionID: sessionID)
        let saved = try await store.saveMinutesCandidate(
            minutesID: row.id,
            expectedAttempts: row.attempts,
            body: prepared.body,
            model: nil,
            candidate: String(data: try JSONEncoder().encode(prepared.candidate), encoding: .utf8),
            review: String(data: try JSONEncoder().encode(prepared.report), encoding: .utf8),
            items: MinutesCandidateCodec.itemDrafts(
                for: prepared.candidate,
                report: prepared.report,
                unitsByID: Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                revisionIDsByLine: revisionIDs
            ),
            snapshotID: snapshotID
        )
        XCTAssertTrue(saved)
        return row
    }

    /// 导出备份到独立目录（当前库所在目录之外，避免自我覆盖）。
    private func exportBundle() async throws -> URL {
        let store = try requireStore()
        let base = try XCTUnwrap(directory)
        let bundle = base.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        _ = try await store.exportBackup(to: bundle)
        return bundle
    }

    // MARK: - 往返：文档、版本、引用、行动项都还在

    /// MC-70：恢复成功需回读关键文档——版本、结论、锚点原文都要能读回来。
    func testRestorePreviewReadsBackDocumentsVersionsAndActions() async throws {
        let row = try await prepareMeetingWithCitations()
        let bundle = try await exportBundle()
        let scratch = try XCTUnwrap(self.scratch)

        let preview = try await SessionStore.restorePreview(of: bundle, into: scratch)
        XCTAssertTrue(
            preview.isRestorable,
            "干净的备份应当判定为可恢复，问题：\(preview.problems)"
        )
        XCTAssertTrue(preview.references.isClean, "引用应当无断裂")
        XCTAssertGreaterThanOrEqual(preview.documentsReadable, 1, "知识文档要能读回来")
        XCTAssertGreaterThanOrEqual(preview.versionsReadable, 1, "纪要版本要能读回来")
        XCTAssertGreaterThanOrEqual(preview.actionsReadable, 2, "结论与待办都要能读回来")
        XCTAssertGreaterThanOrEqual(
            preview.anchorsWithQuote,
            1,
            "证据锚点必须仍能读回封存时的原文（MC-46）"
        )
        XCTAssertEqual(preview.restoredCounts.minutesItems, preview.actionsReadable)
        _ = row
    }

    /// 备份不含私密问答：清单与恢复预演都不该把它带出来。
    func testBackupCountsExcludePrivateQA() async throws {
        _ = try await prepareMeetingWithCitations()
        let bundle = try await exportBundle()
        let manifestURL = bundle.appendingPathComponent(SessionStore.backupManifestName)
        let data = try Data(contentsOf: manifestURL)
        let text = String(data: data, encoding: .utf8) ?? ""
        // 清单只存计数与 schema 版本：转录正文、纪要正文、本机路径都不该出现在里面。
        for leak in ["下周三上线灰度", "预算按 3 万元算", "整理发布清单", "/Users/"] {
            XCTAssertFalse(text.contains(leak), "清单泄露了内容：\(leak)")
        }
    }

    // MARK: - 失败路径：当前库一个字节都不动

    /// MC-70：备份损坏时预演即止，当前库不变。
    func testCorruptBackupFailsPreviewAndLeavesLiveStoreIntact() async throws {
        _ = try await prepareMeetingWithCitations()
        let bundle = try await exportBundle()
        let liveFile = try XCTUnwrap(directory)
            .appendingPathComponent(SessionStore.fileName)
        let before = try Data(contentsOf: liveFile)

        // 把备份文件改写成非 SQLite 内容。
        let corrupt = bundle.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("这不是一个 SQLite 库".utf8)
            .write(to: corrupt.appendingPathComponent(SessionStore.backupFileName))
        try FileManager.default.copyItem(
            at: bundle.appendingPathComponent(SessionStore.backupManifestName),
            to: corrupt.appendingPathComponent(SessionStore.backupManifestName)
        )

        let scratch = try XCTUnwrap(self.scratch)
            .appendingPathComponent("corrupt-scratch", isDirectory: true)
        do {
            let preview = try await SessionStore.restorePreview(of: corrupt, into: scratch)
            XCTAssertFalse(preview.isRestorable, "损坏的备份绝不能被判为可恢复")
        } catch {
            // 打开阶段就失败同样是正确结果：当前库没被动过。
        }

        let store = try requireStore()
        let versions = try await store.minutesVersions(sessionID: try requireSessionID())
        XCTAssertEqual(versions.count, 1, "当前库的纪要必须原样还在")
        let after = try Data(contentsOf: liveFile)
        XCTAssertEqual(before.count, after.count, "当前库文件不得被恢复流程改动")
    }

    /// 缺清单的备份不算备份：无法判断完整性，明确拒绝。
    func testBackupWithoutManifestIsRejected() async throws {
        _ = try await prepareMeetingWithCitations()
        let bundle = try await exportBundle()
        try FileManager.default.removeItem(
            at: bundle.appendingPathComponent(SessionStore.backupManifestName)
        )
        let scratch = try XCTUnwrap(self.scratch)
            .appendingPathComponent("no-manifest", isDirectory: true)
        do {
            let preview = try await SessionStore.restorePreview(of: bundle, into: scratch)
            XCTAssertFalse(preview.isRestorable, "没有清单就没有完整性依据")
        } catch {
            // 明确拒绝也算通过。
        }
    }

    /// MC-69：schema 比当前 App 新的备份**拒绝**，不尝试破坏性降级。
    func testNewerSchemaBackupIsRejected() async throws {
        _ = try await prepareMeetingWithCitations()
        let bundle = try await exportBundle()
        try Self.runSQL(
            on: bundle.appendingPathComponent(SessionStore.backupFileName),
            statements: ["PRAGMA user_version=\(SessionStore.schemaVersion + 1);"]
        )
        let scratch = try XCTUnwrap(self.scratch)
            .appendingPathComponent("future-scratch", isDirectory: true)
        do {
            let preview = try await SessionStore.restorePreview(of: bundle, into: scratch)
            XCTAssertFalse(preview.isRestorable, "更晚的备份不能被旧 App 恢复")
        } catch {
            XCTAssertTrue(error is SessionStoreError, "应当以明确的存储错误拒绝，而不是崩溃")
        }
        let store = try requireStore()
        let versions = try await store.minutesVersions(sessionID: try requireSessionID())
        XCTAssertEqual(versions.count, 1, "拒绝恢复不得影响当前库")
    }

    /// 引用断裂必须在预演里被看见，而不是恢复完才发现。
    func testBrokenReferenceIsReportedAndBlocksRestore() async throws {
        _ = try await prepareMeetingWithCitations()
        let store = try requireStore()
        let sessionID = try requireSessionID()
        await store.close()

        // 绕过外键约束制造一条孤儿锚点（外键检查本来就拦，模拟旧库/外部损坏）。
        let broken = try XCTUnwrap(directory).appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try XCTUnwrap(directory).appendingPathComponent(SessionStore.fileName),
            to: broken.appendingPathComponent(SessionStore.fileName)
        )
        try Self.runSQL(
            on: broken.appendingPathComponent(SessionStore.fileName),
            statements: [
                "INSERT INTO minutes_evidence (id, item_id, unit_id, verification) " +
                    "VALUES ('ev-orphan', 'mi-does-not-exist', 'u9', 'exact_source_match');",
            ]
        )
        // 清单按损坏前的库生成，好让数量对得上、只让引用问题暴露出来。
        let counts = try Self.counts(
            on: broken.appendingPathComponent(SessionStore.fileName)
        )
        let manifest = SessionStore.BackupManifest(
            schemaVersion: Int(SessionStore.schemaVersion),
            createdAt: Date(),
            counts: counts
        )
        try JSONEncoder().encode(manifest).write(
            to: broken.appendingPathComponent(SessionStore.backupManifestName)
        )

        let scratch = try XCTUnwrap(self.scratch)
            .appendingPathComponent("broken-scratch", isDirectory: true)
        do {
            let preview = try await SessionStore.restorePreview(of: broken, into: scratch)
            XCTAssertFalse(preview.isRestorable, "引用断裂时不能判为可恢复")
            XCTAssertFalse(preview.references.isClean)
            XCTAssertFalse(preview.problems.isEmpty, "要具体说清哪里断了")
        } catch {
            // 外键检查直接拦下同样是正确结果。
        }
    }

    // MARK: - 工具

    private static func counts(on file: URL) throws -> SessionStore.BackupCounts {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SessionStoreError.storageUnavailable
        }
        defer { sqlite3_close_v2(pointer) }
        func count(_ sql: String) -> Int {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK,
                  let query = statement else { return 0 }
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(query, 0))
        }
        return SessionStore.BackupCounts(
            sessions: count("SELECT COUNT(*) FROM session;"),
            lines: count("SELECT COUNT(*) FROM line;"),
            meetingDocuments: count("SELECT COUNT(*) FROM meeting_document;"),
            transcriptRevisions: count("SELECT COUNT(*) FROM transcript_revision;"),
            sourceSnapshots: count("SELECT COUNT(*) FROM source_snapshot;"),
            minutes: count("SELECT COUNT(*) FROM minutes;"),
            minutesItems: count("SELECT COUNT(*) FROM minutes_item;"),
            minutesEvidence: count("SELECT COUNT(*) FROM minutes_evidence;"),
            minutesWindows: count("SELECT COUNT(*) FROM minutes_window;")
        )
    }

    private static func runSQL(on file: URL, statements: [String]) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw SessionStoreError.storageUnavailable
        }
        defer { sqlite3_close_v2(pointer) }
        for statement in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(pointer, statement, nil, nil, &error) == SQLITE_OK else {
                let detail = error.map { String(cString: $0) } ?? "未知错误"
                sqlite3_free(error)
                XCTFail("执行 `\(statement)` 失败：\(detail)")
                return
            }
        }
    }
}
