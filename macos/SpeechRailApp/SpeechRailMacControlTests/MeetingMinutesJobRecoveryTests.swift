import Foundation
import SQLite3
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 会议纪要任务的身份、恢复、取消与配置冻结（方案 MA-07 / 场景 MC-27～MC-32）。
///
/// 这里钉的是库这一层的约束，不碰界面，也不发真实请求：
/// - 租约过期后认领的是**原任务**：不新建版本，代际推进；
/// - 远端响应 id 落库后，重启查原请求；提交结果未知时不自动重发；
/// - 心跳、取消、终态都带 fencing：旧执行者迟到改不动新 owner 的行；
/// - 配置在排队那一刻冻结，指纹里没有密钥。
@MainActor
final class MeetingMinutesJobRecoveryTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-minutes-job-\(UUID().uuidString)", isDirectory: true)
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

    private func requireStore() throws -> SessionStore {
        try XCTUnwrap(store)
    }

    private func requireSessionID() throws -> String {
        try XCTUnwrap(sessionID)
    }

    /// 认领并解包。`XCTUnwrap` 的自动闭包里不能 `await`，所以先取出来再解。
    private func claim(
        _ store: SessionStore,
        _ sessionID: String,
        lease: TimeInterval = 600
    ) async throws -> MinutesVersion {
        let claimed = try await store.claimMinutes(sessionID: sessionID, lease: lease)
        return try XCTUnwrap(claimed, "这一版必须能认领")
    }

    /// 取一行并解包。`XCTUnwrap` 的自动闭包里不能 `await`，所以先取出来再解。
    private func version(_ store: SessionStore, _ id: String) async throws -> MinutesVersion {
        let row = try await store.minutesVersion(id: id)
        return try XCTUnwrap(row, "纪要行必须读得到")
    }

    // MARK: - MC-27 租约过期后认领原任务

    /// MC-27：租约过期后重启，认领的是**同一条** job —— 版本号不变、代际推进，
    /// 不新建纪要版本，也不新起一个会议。
    func testExpiredLeaseReclaimsSameJobWithoutNewVersion() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 12)
        let first = try await claim(store, sessionID, lease: -1)
        XCTAssertEqual(first.id, queued.id)
        XCTAssertEqual(first.attempts, 1)

        // 租约已过期：pending 扫描必须把这一条原样交回去。
        let pending = try await store.pendingMinutesRows()
        XCTAssertEqual(pending.map(\.id), [queued.id], "恢复必须认领原 job，不是新版本")

        let second = try await claim(store, sessionID)
        XCTAssertEqual(second.id, queued.id)
        XCTAssertEqual(second.version, queued.version, "恢复不推进纪要版本号")
        XCTAssertEqual(second.attempts, 2, "代际必须推进 fencing")
        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.count, 1, "恢复不得无意义地新建版本")
    }

    // MARK: - MC-28 持久远端响应 id / 提交结果未知

    /// MC-28 前半句：response id 一拿到就落库；重开库读得回同一个 id。
    func testRemoteResponseIDSurvivesReopenAndIsNotResent() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 20)
        let claimed = try await claim(store, sessionID)
        XCTAssertFalse(claimed.hasRemoteResponse, "刚认领时还没有远端响应")

        let recorded = try await store.recordMinutesRemoteResponse(
            minutesID: claimed.id,
            expectedAttempts: claimed.attempts,
            responseID: "resp-abc-123"
        )
        XCTAssertTrue(recorded)

        // 模拟执行者消失：租约到期。恢复扫描要把它连同远端 id 一起交回来。
        let expired = try await store.renewMinutesLease(
            minutesID: claimed.id, expectedAttempts: claimed.attempts, lease: -1
        )
        XCTAssertTrue(expired)

        let directory = try XCTUnwrap(directory)
        await store.close()
        let reopened = SessionStore(directory: directory)
        try await reopened.open()
        let pending = try await reopened.pendingMinutesRows()
        await reopened.close()

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.remoteResponseID, "resp-abc-123", "远端响应 id 必须落库")
        XCTAssertTrue(
            pending.first?.hasRemoteResponse ?? false,
            "恢复时应当查询原请求而不是把整场重新发一遍"
        )
    }

    /// MC-28 后半句（§8.5）：远端可能已受理但没拿到回执 —— 落成明确状态，
    /// 且**不进待恢复扫描**，下一次启动不会把它当待办自动重发。
    func testSubmissionUnknownIsNotAutomaticallyResent() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 20)
        let claimed = try await claim(store, sessionID)
        let marked = try await store.markMinutesSubmissionUnknown(
            minutesID: claimed.id,
            expectedAttempts: claimed.attempts
        )
        XCTAssertTrue(marked)

        let pending = try await store.pendingMinutesRows()
        XCTAssertTrue(pending.isEmpty, "提交结果未知不得进入自动恢复队列（会重复执行、重复计费）")
        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.first?.status, .submissionUnknown)
        XCTAssertNil(versions.first?.body, "未知提交不得留下正文")
    }

    /// 只有传输层失败才算"远端收没收到查不出来"；服务明确回了状态的不算。
    func testOnlyTransportFailureCountsAsSubmissionUnknown() {
        XCTAssertEqual(MinutesSubmissionCertainty.classify(LLMError.transport("连接断了")), .unknown)
        XCTAssertEqual(MinutesSubmissionCertainty.classify(LLMError.http(status: 500, body: "")), .known)
        XCTAssertEqual(MinutesSubmissionCertainty.classify(LLMError.notResponsesAPI), .known)
        XCTAssertEqual(MinutesSubmissionCertainty.classify(LLMError.refused("拒答")), .known)
        XCTAssertEqual(MinutesSubmissionCertainty.classify(LLMError.outputTruncated), .known)
    }

    // MARK: - MC-29 fencing

    /// MC-29：租约被新 owner 接管之后，旧 owner 的心跳、响应 id 与终态全部失效。
    func testLateOwnerCannotRenewRecordOrFinishAfterTakeover() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 20)
        let old = try await claim(store, sessionID, lease: -1)
        let new = try await claim(store, sessionID)
        XCTAssertEqual(old.id, new.id)
        XCTAssertNotEqual(old.attempts, new.attempts)

        let renewedByOldOwner = try await store.renewMinutesLease(
            minutesID: old.id, expectedAttempts: old.attempts, lease: 600
        )
        XCTAssertFalse(renewedByOldOwner, "旧代际不得续租约")
        let recordedByOldOwner = try await store.recordMinutesRemoteResponse(
            minutesID: old.id, expectedAttempts: old.attempts, responseID: "resp-late"
        )
        XCTAssertFalse(recordedByOldOwner, "旧代际不得写远端响应 id")
        let finishedByOldOwner = try await store.finishMinutesIfOwner(
            minutesID: old.id, expectedAttempts: old.attempts, body: "# 迟到的正文", model: nil
        )
        XCTAssertFalse(finishedByOldOwner, "旧代际不得发布候选")

        let current = try await version(store, new.id)
        XCTAssertEqual(current.status, .running)
        XCTAssertNil(current.body, "迟到的正文一个字都不能落库")
        XCTAssertNil(current.remoteResponseID)
    }

    // MARK: - MC-30 取消

    /// MC-30：停止只停**指定任务**，落成"已停止"而不是"没整理出来"；
    /// 另一场正在跑的整理与已经存好的旧纪要都不受影响。
    func testCancelStopsOnlyTheTargetJobAndKeepsOlderMinutes() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let other = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )

        let kept = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await claim(store, sessionID)
        try await store.finishMinutesForTestOnly(minutesID: kept.id, body: "# 旧版纪要", model: nil)
        let running = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        let claimed = try await claim(store, sessionID)
        let otherQueued = try await store.enqueueMinutes(sessionID: other.id, model: nil, promptChars: 9)
        let otherClaimed = try await claim(store, other.id)

        let requested = try await store.requestCancelMinutes(minutesID: claimed.id)
        XCTAssertTrue(requested)
        let cancelled = try await store.cancelMinutesIfOwner(
            minutesID: claimed.id, expectedAttempts: claimed.attempts
        )
        XCTAssertTrue(cancelled)

        let stopped = try await version(store, running.id)
        XCTAssertEqual(stopped.status, .cancelled, "取消不是失败")
        XCTAssertNotNil(stopped.cancelRequestedAt, "取消请求要留痕，不能只停内存任务")

        let otherRunning = try await version(store, otherQueued.id)
        XCTAssertEqual(otherRunning.status, .running, "取消另一场不得影响这一场")
        XCTAssertNil(otherRunning.cancelRequestedAt)
        XCTAssertNotEqual(otherClaimed.id, claimed.id)

        // 旧纪要原文与展示口径都不动。
        let keptVersion = try await version(store, kept.id)
        XCTAssertEqual(keptVersion.body, "# 旧版纪要")
        let current = try await store.currentMinutes(sessionID: sessionID)
        XCTAssertEqual(current?.id, kept.id)

        let pending = try await store.pendingMinutesRows()
        XCTAssertFalse(pending.contains { $0.id == running.id }, "已停止的任务不再自动恢复")
    }

    /// 没写过取消请求就不许落成"已停止"——那会把别人接管的行说成用户不要了。
    func testCancelRequiresRequestAndMatchingGeneration() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        let claimed = try await claim(store, sessionID)

        let withoutRequest = try await store.cancelMinutesIfOwner(
            minutesID: claimed.id, expectedAttempts: claimed.attempts
        )
        XCTAssertFalse(withoutRequest, "没有取消请求就不能落成已停止")

        let requested = try await store.requestCancelMinutes(minutesID: claimed.id)
        XCTAssertTrue(requested)
        let again = try await store.requestCancelMinutes(minutesID: claimed.id)
        XCTAssertFalse(again, "取消请求只记一次")
        let wrongGeneration = try await store.cancelMinutesIfOwner(
            minutesID: claimed.id, expectedAttempts: claimed.attempts + 1
        )
        XCTAssertFalse(wrongGeneration, "代际不符不得改写")
        let unchanged = try await store.minutesVersion(id: claimed.id)
        XCTAssertEqual(unchanged?.status, .running)
    }

    /// 已落终态的行不再接受取消：终态结论不能被后来的动作改写。
    func testCancelDoesNotOverwriteTerminalRow() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await claim(store, sessionID)
        try await store.finishMinutesForTestOnly(minutesID: queued.id, body: "# 已完成", model: nil)

        let requested = try await store.requestCancelMinutes(minutesID: queued.id)
        XCTAssertFalse(requested)
        let version = try await version(store, queued.id)
        XCTAssertEqual(version.status, .ready)
        XCTAssertEqual(version.body, "# 已完成")
        XCTAssertNil(version.cancelRequestedAt)
    }

    // MARK: - MC-32 配置冻结

    /// MC-32：排队那一刻冻结配置；指纹可还原，且**不含密钥**。
    func testJobConfigIsFrozenAtEnqueueAndCarriesNoSecret() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let configuration = LLMConfiguration(
            baseURL: "https://example.invalid/v1",
            model: "model-a",
            compatibilityMode: .openAICompatible
        )
        let fingerprint = MinutesJobConfig(configuration).fingerprint
        XCTAssertFalse(fingerprint.contains("sk-"), "指纹里不得出现密钥")

        let queued = try await store.enqueueMinutes(
            sessionID: sessionID,
            model: "model-a",
            promptChars: 11,
            configSnapshot: fingerprint,
            snapshotID: "snap-1"
        )
        XCTAssertEqual(queued.configSnapshot, fingerprint)
        XCTAssertEqual(queued.snapshotID, "snap-1", "任务绑定来源快照")

        let reread = try await version(store, queued.id)
        XCTAssertEqual(reread.configSnapshot, fingerprint, "冻结的配置要能读回来")
        XCTAssertEqual(reread.snapshotID, "snap-1")

        // 还原出来的是**任务答应过**的那套，不是当前设置。
        let restored = try XCTUnwrap(MinutesJobConfig.parse(reread.configSnapshot))
        XCTAssertEqual(restored.configuration.baseURL, "https://example.invalid/v1")
        XCTAssertEqual(restored.configuration.model, "model-a")
        XCTAssertNotEqual(
            restored,
            MinutesJobConfig(LLMConfiguration(baseURL: "https://other.invalid/v1", model: "model-b")),
            "换了设置就该看得出来：新配置从下一次任务生效"
        )
        XCTAssertNil(MinutesJobConfig.parse("只有|两段"), "形状不合法就读不出，不猜也不填默认值")
        XCTAssertNil(MinutesJobConfig.parse(nil))
    }

    // MARK: - schema v4 迁移

    /// v3 库升到 v4：四列补齐、既有行不写回值（老任务本来就没存过远端响应 id）。
    func testMigrationV3ToV4AddsTaskIdentityColumnsWithoutBackfill() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        let directory = try XCTUnwrap(directory)
        await store.close()

        // 把库按 v3 形状摆回去：去掉四列、把 user_version 置 3。
        try Self.runSQL(
            on: directory.appendingPathComponent(SessionStore.fileName),
            statements: [
                "ALTER TABLE minutes DROP COLUMN remote_response_id;",
                "ALTER TABLE minutes DROP COLUMN config_snapshot;",
                "ALTER TABLE minutes DROP COLUMN snapshot_id;",
                "ALTER TABLE minutes DROP COLUMN cancel_requested_at;",
                "PRAGMA user_version=3;",
            ]
        )

        let migrated = SessionStore(directory: directory)
        try await migrated.open()
        let version = try await version(migrated, queued.id)
        await migrated.close()

        XCTAssertEqual(version.status, .queued, "迁移不动既有行的语义")
        XCTAssertNil(version.remoteResponseID, "老任务没存过远端响应 id，不补造")
        XCTAssertNil(version.configSnapshot)
        XCTAssertNil(version.snapshotID)
        XCTAssertNil(version.cancelRequestedAt)
    }

    // MARK: - 工具

    /// 直接对库文件执行 SQL（模拟"库已经是旧形状"）。测试内用，sqlite3 系统库已链。
    private static func runSQL(on file: URL, statements: [String]) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let pointer else {
            XCTFail("打不开临时库文件：\(file.lastPathComponent)")
            return
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
