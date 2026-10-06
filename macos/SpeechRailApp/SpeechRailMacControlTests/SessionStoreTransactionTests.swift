import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// R05 (#242)：说话人显示名改名必须是原子业务事务。
///
/// RED 期望：`renameSpeaker` 的 SELECT → UPSERT → 修订 INSERT 是三次独立提交；
/// 第二步之后失败会留下“名已改、事件无”的半状态，同名重试也不补事件。
/// 本文件用测试自有 SQLite 与可控失败注入钉住该行为，不碰用户数据。
@MainActor
final class SessionStoreTransactionTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
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

    /// 第二次写入（修订事件 INSERT）失败时，名字 UPSERT 必须一起回滚：
    /// 旧名、事件数都不变，不留“新名已存、事件为 0”的半状态。
    func testRenameRollsBackNameWhenRevisionInsertFails() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try XCTUnwrap(sessionID)
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "旧名")
        let eventsBefore = try await store.speakerRevisions(sessionID: sessionID)

        await store.withFailingRevisionInsert {
            do {
                try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "新名")
                XCTFail("修订 INSERT 失败时改名必须抛错")
            } catch {
                // 期望失败：下面断言回滚完整性。
            }
        }
        let names = try await store.speakerNames(sessionID: sessionID)
        XCTAssertEqual(names["A"], "旧名", "修订失败时名字不得半提交")
        let eventsAfter = try await store.speakerRevisions(sessionID: sessionID)
        XCTAssertEqual(eventsAfter.count, eventsBefore.count)
    }

    /// 失败解除后同名重试成功，且恰好补一条修订事件，不多不漏。
    func testRetryAfterFailureInsertsExactlyOneRevision() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try XCTUnwrap(sessionID)
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "旧名")
        let eventsBefore = try await store.speakerRevisions(sessionID: sessionID)

        await store.withFailingRevisionInsert {
            try? await store.renameSpeaker(sessionID: sessionID, label: "A", name: "新名")
        }
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "新名")
        let names = try await store.speakerNames(sessionID: sessionID)
        XCTAssertEqual(names["A"], "新名")
        let eventsAfter = try await store.speakerRevisions(sessionID: sessionID)
        XCTAssertEqual(eventsAfter.count, eventsBefore.count + 1)
    }

    /// 成功命令重复执行不追加事件（同名幂等）。
    func testRepeatSameNameDoesNotAppendRevision() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try XCTUnwrap(sessionID)
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "同名")
        let eventsBefore = try await store.speakerRevisions(sessionID: sessionID)
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "同名")
        let eventsAfter = try await store.speakerRevisions(sessionID: sessionID)
        XCTAssertEqual(eventsAfter.count, eventsBefore.count)
    }

    /// A→B→A 保留两次真实变化，各一条修订事件。
    func testRenameBackAndForthRecordsTwoRevisions() async throws {
        let store = try XCTUnwrap(store)
        let sessionID = try XCTUnwrap(sessionID)
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "甲")
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "乙")
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "甲")
        let events = try await store.speakerRevisions(sessionID: sessionID)
        XCTAssertEqual(events.count, 3)
        let names = try await store.speakerNames(sessionID: sessionID)
        XCTAssertEqual(names["A"], "甲")
    }
}
