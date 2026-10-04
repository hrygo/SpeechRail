import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 会议纪要版本指针回归（方案 MA-06 / 场景 MC-25、MC-26、MC-48）。
/// 这里钉的是库这一层的约束，不碰界面：
/// - 排队新版本是原子动作：INSERT 失败不能留下“旧版已被清掉指针”的半提交；
/// - 最新尝试失败后，最新可用版仍可查；查询不到已完成版本时也不伪造成功；
/// - 展示、搜索与导出只认调用方选定的版本，不把“版本号最大”等同于“用户采用版”。
@MainActor
final class MeetingMinutesVersioningTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-minutes-versioning-\(UUID().uuidString)", isDirectory: true)
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

    /// MC-26：新候选 INSERT 失败时，旧版的最新指针保持不变。
    func testEnqueueFailureKeepsPreviousLatestPointer() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        try await store.finishMinutes(minutesID: first.id, body: "# 采用版", model: nil)

        do {
            _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9, id: first.id)
            XCTFail("重复 id 的排队必须失败")
        } catch {
            // 预期失败：旧版指针必须保持。
        }

        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.count, 1, "失败的排队不能新增版本行")
        XCTAssertEqual(versions.first?.id, first.id)
        XCTAssertTrue(versions.first?.isLatest ?? false, "旧版的最新指针不能被失败的排队清掉")
    }

    /// MC-25：一版可用之后再来一版失败，最新可用版仍是上一版。
    func testLatestUsableStaysAfterFailedAttempt() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: first.id, body: "# 采用版", model: nil)
        let failed = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.failMinutes(minutesID: failed.id, reason: "模型没有给结果")

        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.count, 2)
        let usable = versions.filter { $0.status == .ready }
        XCTAssertEqual(usable.count, 1)
        XCTAssertEqual(usable.first?.id, first.id, "失败尝试不能取代已完成版本")
    }

    /// MC-25：Store 直接给出最新可用版；没有可用版时返回 nil，不伪造成功。
    func testLatestUsableMinutesReturnsNewestReady() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let empty = try await store.latestUsableMinutes(sessionID: sessionID)
        XCTAssertNil(empty)
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: first.id, body: "# 采用版", model: nil)
        let failed = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.failMinutes(minutesID: failed.id, reason: "模型没有给结果")
        let usable = try await store.latestUsableMinutes(sessionID: sessionID)
        XCTAssertEqual(usable?.id, first.id)
        XCTAssertEqual(usable?.body, "# 采用版")
    }

    /// MC-33/MC-34：空输出与非结构输出都不是成功，不能标成 ready。
    /// 用 Domain 层的纯解析覆盖，不依赖生成器目标。
    func testOutcomeRejectsEmptyAndUnstructuredText() {
        switch MinutesOutcome.parsing(text: "   \n  ", markdown: { _ in nil }) {
        case .failed(let reason):
            XCTAssertFalse(reason.isEmpty)
        case .ready:
            XCTFail("空输出不能解析成可用纪要")
        }
        switch MinutesOutcome.parsing(text: "今天讨论了预算，没有结论。", markdown: { _ in nil }) {
        case .failed(let reason):
            XCTAssertTrue(reason.contains("今天讨论了预算"))
            XCTAssertTrue(reason.contains("尚未按结构校验"))
        case .ready:
            XCTFail("非结构输出不能直接标成可用纪要")
        }
        switch MinutesOutcome.parsing(text: "{\"ok\":true}", markdown: { _ in "# 结构化正文" }) {
        case .ready(let body):
            XCTAssertEqual(body, "# 结构化正文")
        case .failed:
            XCTFail("合法结构输出应该解析成功")
        }
    }

    /// MC-29：旧执行者迟到不得改写已被新认领的行；非 running 行的完成/失败不生效。
    func testStaleOwnerCannotOverwriteReclaimedRow() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        // 首次认领用已过期的租约，模拟崩溃后重启回收：第二次认领必须推进代际。
        let stale = try await store.claimMinutes(sessionID: sessionID, lease: -1)
        XCTAssertEqual(stale?.id, first.id)
        let staleAttempts = stale?.attempts ?? 0
        let fresh = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        XCTAssertEqual(fresh?.attempts, staleAttempts + 1)
        let staleCommitted = try await store.finishMinutesIfOwner(
            minutesID: first.id, expectedAttempts: staleAttempts, body: "# 旧结果", model: nil
        )
        XCTAssertFalse(staleCommitted, "旧代际的完成不得覆盖新认领")
        let freshCommitted = try await store.finishMinutesIfOwner(
            minutesID: first.id, expectedAttempts: fresh?.attempts ?? -1, body: "# 新结果", model: nil
        )
        XCTAssertTrue(freshCommitted)
        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.first?.body, "# 新结果")
        XCTAssertEqual(versions.first?.status, .ready)
        // 非 running 行的失败不改写已完成正文。
        try await store.failMinutes(minutesID: first.id, reason: "迟到的失败")
        let afterFail = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(afterFail.first?.status, .ready)
        XCTAssertEqual(afterFail.first?.body, "# 新结果")
    }

    /// MC-27：恢复认领原 job，不新建版本；attempts 推进但版本号不变。
    func testRecoveryClaimsOriginalJobWithoutNewVersion() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        // 用已过期的租约认领，模拟崩溃后重启：行仍是 running，但租约已过期。
        let claimed = try await store.claimMinutes(sessionID: sessionID, lease: -1)
        XCTAssertEqual(claimed?.id, first.id)
        let pending = try await store.pendingMinutesRows()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, first.id)
        // 恢复认领同一行：版本号不变，代际推进，不新增版本行。
        let resumed = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        XCTAssertEqual(resumed?.id, first.id)
        XCTAssertEqual(resumed?.version, first.version)
        XCTAssertEqual(resumed?.attempts, (claimed?.attempts ?? 0) + 1)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        let committed = try await store.finishMinutesIfOwner(
            minutesID: first.id, expectedAttempts: resumed?.attempts ?? -1, body: "# 恢复完成", model: nil
        )
        XCTAssertTrue(committed)
        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.count, 1, "恢复不得新建版本")
        XCTAssertEqual(versions.first?.body, "# 恢复完成")
    }

    /// MC-44/MC-49/MC-52：知识检索命中转录与已完成纪要，不含私密问答；空查询不扫库。
    func testSearchKnowledgeExcludesPrivateExchanges() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .user, text: "预算 35 万元", source: .microphone, status: .final)
        )
        let minutes = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: minutes.id, body: "# 纪要\n\n预算 35 万元", model: nil)
        _ = try await store.saveInnerOSExchange(
            InnerOSExchange(id: "inner-1", sessionID: sessionID, askedAt: Date(), question: "预算 35 万元怎么看？", answerText: "私密分析", status: .ready)
        )
        let hits = try await store.searchKnowledge(query: "预算")
        XCTAssertFalse(hits.isEmpty, "转录与纪要应该被检索到")
        XCTAssertTrue(hits.allSatisfy { $0.excerpt.contains("预算") })
        XCTAssertTrue(hits.contains { $0.lineID != nil })
        XCTAssertTrue(hits.contains { $0.minutesID != nil })
        XCTAssertFalse(hits.contains { $0.excerpt.contains("私密分析") }, "私密问答不得进入知识检索")
        let empty = try await store.searchKnowledge(query: "   ")
        XCTAssertTrue(empty.isEmpty, "空查询不得全库扫描")
    }

    /// 恢复可证：备份到临时新库后可核对文档与版本；校验失败不损坏原库。
    func testBackupRestoreKeepsDocumentsAndVersions() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .user, text: "预算 35 万元", source: .microphone, status: .final)
        )
        let minutes = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: minutes.id, body: "# 纪要\n\n预算 35 万元", model: nil)
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-backup-\(UUID().uuidString).sqlite3")
        try await store.backup(to: backupURL)
        defer { try? FileManager.default.removeItem(at: backupURL) }
        let verification = try SessionStore.verifyBackup(at: backupURL)
        XCTAssertEqual(verification.integrity.lowercased(), "ok")
        XCTAssertEqual(verification.minutesCount, 1)
        // 用备份文件另开一个库核对：文档、版本、正文可读。
        let restoreDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: restoreDir) }
        let restoreURL = restoreDir.appendingPathComponent(SessionStore.fileName)
        try FileManager.default.copyItem(at: backupURL, to: restoreURL)
        let restored = SessionStore(directory: restoreDir)
        try await restored.open()
        let restoredVersions = try await restored.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(restoredVersions.count, 1)
        XCTAssertEqual(restoredVersions.first?.body, "# 纪要\n\n预算 35 万元")
        let restoredLines = try await restored.lines(sessionID: sessionID)
        XCTAssertTrue(restoredLines.contains { $0.text.contains("预算") })
        await restored.close()
        // 原库在备份后仍可写：备份失败/成功都不损坏原库。
        let second = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        XCTAssertEqual(second.version, 2)
    }

    /// MC-62/删除语义：完整删除后检索不再带回，旧任务行随级联消失。
    func testRemovedSessionDisappearsFromKnowledge() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .user, text: "待删除预算", source: .microphone, status: .final)
        )
        let minutes = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: minutes.id, body: "# 待删除纪要", model: nil)
        var hits = try await store.searchKnowledge(query: "待删除")
        XCTAssertFalse(hits.isEmpty)
        try await store.removeSession(id: sessionID)
        hits = try await store.searchKnowledge(query: "待删除")
        XCTAssertTrue(hits.isEmpty, "完整删除后检索不得带回已删内容")
        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertTrue(versions.isEmpty, "纪要行随会话级联删除")
        let pending = try await store.pendingMinutesRows()
        XCTAssertTrue(pending.isEmpty, "旧任务不得在删除后复活")
    }

    /// MC-48：按 id 读版；未知 id 返回 nil，调用方不得回退成最新版冒充。
    func testMinutesVersionReadByIDPinsSelection() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: first.id, body: "# 第一版", model: nil)
        let pinned = try await store.minutesVersion(id: first.id)
        XCTAssertEqual(pinned?.body, "# 第一版")
        XCTAssertEqual(pinned?.version, 1)
        let missing = try await store.minutesVersion(id: "no-such-version")
        XCTAssertNil(missing, "未知版本必须返回 nil，不能回退成最新版")
    }

    /// MC-48：选定版本导出只认调用方传入的版本，不认“最新/最大版本”。
    func testSelectedVersionIsReturnedAsSelected() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: first.id, body: "# 第一版", model: nil)
        let second = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: second.id, body: "# 第二版", model: nil)

        let versions = try await store.minutesVersions(sessionID: sessionID)
        let selected = versions.first { $0.id == first.id }
        XCTAssertEqual(selected?.body, "# 第一版", "调用方选定旧版时必须原样返回旧版正文")
        XCTAssertEqual(selected?.version, 1)
    }
}
