import Foundation
import SQLite3
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 会议来源封存（方案 MA-03 收尾 / MA-05 落地，场景 MC-20、MC-46）。
///
/// 这一层之前只有表和 API，没有生产路径——所以 `snapshot_id` 一直是空的，
/// "这一版依据哪几句话"始终悬空。这里钉的是接线之后的三件事：
/// - 封存把这一场变成知识文档 + 固定快照，并把定稿行物化成不可变修订；
/// - 重复封存不重复写（幂等），只有文字真的变了才长出新修订并挂上 parent；
/// - 没有定稿正文时**不写空快照**——"没有快照"和"没有依据"是两件事。
@MainActor
final class MeetingSourceSealTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-source-seal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone, title: "发布评审")
        )
        self.directory = directory
        self.store = store
        self.sessionID = record.id
    }

    override func tearDown() async throws {
        if let store { await store.close() }
        store = nil
        sessionID = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func requireStore() throws -> SessionStore {
        try XCTUnwrap(store)
    }

    private func requireSessionID() throws -> String {
        try XCTUnwrap(sessionID)
    }

    /// 封存并解包。`XCTUnwrap` 的自动闭包里不能 `await`，所以先取出来再解。
    private func seal(_ store: SessionStore, _ sessionID: String) async throws -> MeetingSourceSnapshot {
        let snapshot = try await store.sealMeetingSource(sessionID: sessionID)
        return try XCTUnwrap(snapshot, "有定稿正文就应该封出快照")
    }

    private func appendLine(
        _ id: String,
        _ text: String,
        status: SessionLineStatus = .final
    ) async throws {
        let store = try requireStore()
        _ = try await store.appendLine(
            LineDraft(
                sessionID: try requireSessionID(),
                role: .speaker,
                text: text,
                source: .microphone,
                status: status
            ),
            id: id
        )
    }

    /// 封存后这一场有文档、有快照，快照锚定的每一句都能读回当时的原文。
    func testSealCreatesDocumentSnapshotAndLineRevisions() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        try await appendLine("line-1", "先完成灰度验证。")
        try await appendLine("line-2", "预算按 3 万元算。")

        let snapshot = try await seal(store, sessionID)
        XCTAssertEqual(snapshot.documentID, "doc-\(sessionID)")
        XCTAssertEqual(snapshot.sealResult, "ok")
        XCTAssertEqual(snapshot.lineRevisionIDs.count, 2, "两句定稿都要有固定修订")
        XCTAssertEqual(snapshot.coverage, "final_lines=2")

        let loadedDocument = try await store.meetingDocument(forSessionID: sessionID)
        let document = try XCTUnwrap(loadedDocument)
        XCTAssertEqual(document.title, "发布评审", "文档标题跟会话同源，不另开一个可改的标题源")

        // 快照锚定的每一句都读得到原文，且原文就是封存那一刻的版本。
        let expected = ["先完成灰度验证。", "预算按 3 万元算。"]
        for (index, text) in expected.enumerated() {
            let revisions = try await store.transcriptRevisions(lineID: "line-\(index + 1)")
            let anchored = try XCTUnwrap(revisions.first { $0.id == snapshot.lineRevisionIDs[index] })
            XCTAssertEqual(anchored.text, text)
            XCTAssertEqual(anchored.origin, "asr", "ASR 原文与人工修订要分得开")
        }
    }

    /// 重复封存不重复写：同一场不会长出第二份文档，也不会给同一段话再插一条修订。
    func testRepeatedSealIsIdempotent() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        try await appendLine("line-1", "先完成灰度验证。")

        let first = try await seal(store, sessionID)
        let second = try await seal(store, sessionID)
        XCTAssertEqual(first.id, second.id, "内容没变就是同一份快照")

        let revisions = try await store.transcriptRevisions(lineID: "line-1")
        XCTAssertEqual(revisions.count, 1, "同一段话不该被反复封存插出多条修订")
        let count = try await snapshotCount()
        XCTAssertEqual(count, 1)
    }

    /// MC-46：改了转录再封存会长出新修订并挂上 parent，而**旧快照原样保留**——
    /// 旧纪要依据的仍然是它当时那几段话。
    func testEditedTranscriptGetsNewRevisionAndKeepsOldSnapshot() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        try await appendLine("line-1", "先做灰度。")
        let first = try await seal(store, sessionID)

        // 用户改了这句话（当前还没有正文编辑入口，这里直接改库模拟修订）。
        Self.runSQL(
            on: try XCTUnwrap(directory).appendingPathComponent(SessionStore.fileName),
            statements: ["UPDATE line SET text = '先做灰度，再看数据。' WHERE id = 'line-1';"]
        )
        let second = try await seal(store, sessionID)

        XCTAssertNotEqual(first.id, second.id, "内容变了就该是另一份快照")
        let revisions = try await store.transcriptRevisions(lineID: "line-1")
        XCTAssertEqual(revisions.count, 2)
        let latest = try XCTUnwrap(revisions.last)
        XCTAssertEqual(latest.text, "先做灰度，再看数据。")
        XCTAssertEqual(latest.parentRevisionID, first.lineRevisionIDs.first, "新修订挂在旧修订后面")

        // 旧快照仍指向旧文本：旧纪要不受用户后来的修改影响。
        let loadedOld = try await store.sourceSnapshot(id: first.id)
        let oldSnapshot = try XCTUnwrap(loadedOld)
        let allRevisions = try await store.transcriptRevisions(lineID: "line-1")
        let oldRevision = try XCTUnwrap(allRevisions.first { $0.id == oldSnapshot.lineRevisionIDs.first })
        XCTAssertEqual(oldRevision.text, "先做灰度。")
        let latestSnapshot = try await store.latestSourceSnapshot(sessionID: sessionID)
        XCTAssertEqual(latestSnapshot?.id, second.id, "新任务绑定最新那份来源")
    }

    /// 没有定稿正文时不写空快照：库里"没有快照"就是"还没有可锚定的来源"，
    /// 造一条空的等于宣称"这一场没有任何依据"。
    func testNoFinalLinesWritesNoEmptySnapshot() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        try await appendLine("line-pending", "还在说。", status: .partial)

        let snapshot = try await store.sealMeetingSource(sessionID: sessionID)
        XCTAssertNil(snapshot, "没有定稿正文就没有可封存的来源")
        let latest = try await store.latestSourceSnapshot(sessionID: sessionID)
        XCTAssertNil(latest)
        let count = try await snapshotCount()
        XCTAssertEqual(count, 0, "不得留下空快照")
    }

    /// 端到端接上：封存之后排的纪要任务绑定的是这份快照，而不是空。
    func testMinutesJobBindsSealedSnapshot() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        try await appendLine("line-1", "先完成灰度验证。")
        let snapshot = try await seal(store, sessionID)

        let latest = try await store.latestSourceSnapshot(sessionID: sessionID)
        let queued = try await store.enqueueMinutes(
            sessionID: sessionID,
            model: nil,
            promptChars: 16,
            configSnapshot: "https://example.invalid/v1|model-a|openai_compatible",
            snapshotID: latest?.id
        )
        XCTAssertEqual(queued.snapshotID, snapshot.id, "任务必须绑定封存下来的那份来源")
    }

    // MARK: - 工具

    /// 直接数库里的快照行数（验证写入的原始结果，不走业务接口）。
    private func snapshotCount() async throws -> Int {
        var pointer: OpaquePointer?
        let file = try XCTUnwrap(directory).appendingPathComponent(SessionStore.fileName)
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let pointer else {
            throw XCTSkip("打不开临时库文件")
        }
        defer { sqlite3_close_v2(pointer) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, "SELECT COUNT(*) FROM source_snapshot;", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw XCTSkip("准备语句失败") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func runSQL(on file: URL, statements: [String]) {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let pointer else {
            return
        }
        defer { sqlite3_close_v2(pointer) }
        for statement in statements {
            sqlite3_exec(pointer, statement, nil, nil, nil)
        }
    }
}
