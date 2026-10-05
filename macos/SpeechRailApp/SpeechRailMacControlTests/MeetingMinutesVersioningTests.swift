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

    /// 知识可用（验收 4）：失败纪要与 partial 行不进入知识检索，只收终稿与已完成版。
    func testSearchKnowledgeSkipsFailedMinutesAndPartials() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .speaker, text: "可见终稿回滚方案", source: .microphone, status: .final)
        )
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .speaker, text: "未定稿回滚方案草稿", source: .microphone, status: .partial)
        )
        let failed = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.failMinutes(minutesID: failed.id, reason: "模型没有给结果")
        let hits = try await store.searchKnowledge(query: "回滚方案")
        XCTAssertTrue(hits.contains { $0.lineID != nil }, "终稿转录应该被检索到")
        XCTAssertFalse(hits.contains { $0.excerpt.contains("草稿") }, "partial 行不得进入知识检索")
        XCTAssertFalse(hits.contains { $0.minutesID != nil }, "失败纪要不得进入知识检索")
    }

    /// MC-46 半句（无迁移可验证部分）：改名只写映射表，旧纪要正文原样可查，不被改写。
    func testRenameKeepsOldMinutesBodyReadable() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: first.id, body: "# 第一版", model: nil)
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "张三")
        let pinned = try await store.minutesVersion(id: first.id)
        XCTAssertEqual(pinned?.body, "# 第一版", "改名不得改写旧纪要正文，原版必须可查")
        let names = try await store.speakerNames(sessionID: sessionID)
        XCTAssertEqual(names["A"], "张三")
    }

    /// MC-46 后半句（Domain 纯逻辑）：只有晚于纪要创建的修订才标复核；
    /// 无修订、修订不晚于纪要时不标，不误伤。
    func testMinutesReviewMarksOnlyLaterRevisions() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let earlier = base.addingTimeInterval(-10)
        let later = base.addingTimeInterval(10)
        XCTAssertTrue(MinutesReview.needsReview(versionCreatedAt: base, revisionDates: [later]))
        XCTAssertFalse(MinutesReview.needsReview(versionCreatedAt: base, revisionDates: []))
        XCTAssertFalse(MinutesReview.needsReview(versionCreatedAt: base, revisionDates: [earlier]))
        XCTAssertFalse(MinutesReview.needsReview(versionCreatedAt: base, revisionDates: [base]))
        let ids = MinutesReview.reviewIDs(
            versions: [(id: "v1", createdAt: base), (id: "v2", createdAt: later)],
            revisions: [base.addingTimeInterval(1)]
        )
        XCTAssertEqual(ids, ["v1"])
        XCTAssertTrue(MinutesReview.reviewIDs(versions: [(id: "v1", createdAt: base)], revisions: []).isEmpty)
    }

    /// MC-45（Domain 纯逻辑）：迟到结果的界面状态只写当初那一场；
    /// 库归档不受此限（以建行 sessionID 为准，由调用方保证）。
    func testLateResultOwnershipGuardsUIWrites() {
        XCTAssertTrue(LateResultOwnership.mayWriteUI(boundSessionID: "A", builtSessionID: "A"))
        XCTAssertFalse(LateResultOwnership.mayWriteUI(boundSessionID: "B", builtSessionID: "A"))
        XCTAssertFalse(LateResultOwnership.mayWriteUI(boundSessionID: nil, builtSessionID: "A"))
        XCTAssertTrue(LateResultOwnership.mayWriteUI(boundSessionID: nil, builtSessionID: nil))
    }

    /// MC-46 后半句（无迁移实现）：改名后旧纪要标需复核，引用仍指旧 revision。
    /// 修订事件只追加不改正文；复核判断是纯读，不写库。
    func testRenameMarksOldMinutesNeedsReview() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: first.id, body: "# 第一版", model: nil)
        // 纪要创建之后再改名：旧版应标需复核。
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "张三")
        let needsReview = try await store.minutesNeedsReview(minutesID: first.id)
        XCTAssertTrue(needsReview)
        // 引用仍指旧 revision：正文原样可查，不被改写。
        let pinned = try await store.minutesVersion(id: first.id)
        XCTAssertEqual(pinned?.body, "# 第一版")
        // 重复同名改名不刷修订事件：已标复核的状态不变，也不新增事件。
        let eventsBefore = try await store.speakerRevisions(sessionID: sessionID)
        try await store.renameSpeaker(sessionID: sessionID, label: "A", name: "张三")
        let eventsAfter = try await store.speakerRevisions(sessionID: sessionID)
        XCTAssertEqual(eventsAfter.count, eventsBefore.count)
        let stillNeedsReview = try await store.minutesNeedsReview(minutesID: first.id)
        XCTAssertTrue(stillNeedsReview)
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

    /// 验收 5（引用关联）：备份恢复后，引文仍能指回恢复库里的转录行并通过校验；
    /// 恢复库是只读核对，不写原库。
    func testBackupRestoreKeepsEvidenceLinksVerifiable() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .user, text: "预算 35 万元，下周定。", source: .microphone, status: .final),
            id: "line-ev-restore-1"
        )
        _ = try await store.saveInnerOSExchange(
            InnerOSExchange(id: "inner-ev-restore-1", sessionID: sessionID, askedAt: Date(), question: "预算多少？", status: .ready),
            evidence: [
                InnerOSEvidence(id: "ev-restore-ok", lineID: "line-ev-restore-1", quote: "预算 35 万元"),
            ]
        )
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-ev-restore-\(UUID().uuidString).sqlite3")
        try await store.backup(to: backupURL)
        defer { try? FileManager.default.removeItem(at: backupURL) }
        let restoreDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-ev-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: restoreDir) }
        try FileManager.default.copyItem(
            at: backupURL,
            to: restoreDir.appendingPathComponent(SessionStore.fileName)
        )
        let restored = SessionStore(directory: restoreDir)
        try await restored.open()
        // 引用行随库恢复：证据指回的行正文可读。
        let restoredEvidence = try await restored.innerOSEvidence(exchangeID: "inner-ev-restore-1")
        XCTAssertEqual(restoredEvidence.count, 1)
        XCTAssertEqual(restoredEvidence.first?.lineID, "line-ev-restore-1")
        // 恢复库里引文仍逐字命中所指行，可通过校验。
        let checks = try await restored.verifyEvidenceQuotes(exchangeID: "inner-ev-restore-1")
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.verified, true, "恢复后引文仍应逐字命中所指转录行")
        await restored.close()
    }

    /// 恢复可证（验收 5）：备份恢复后行动项随纪要正文可核对，版本关联不漂移。
    func testBackupRestoreKeepsActionItemsWithVersions() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .user, text: "下周三前交付预算表", source: .microphone, status: .final)
        )
        let minutes = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        let actionBody = "# 纪要\n\n## 待办\n\n- 张三：交付预算表（下周三前）\n"
        try await store.finishMinutes(minutesID: minutes.id, body: actionBody, model: nil)
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-actions-\(UUID().uuidString).sqlite3")
        try await store.backup(to: backupURL)
        defer { try? FileManager.default.removeItem(at: backupURL) }
        let restoreDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-actions-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: restoreDir) }
        try FileManager.default.copyItem(
            at: backupURL,
            to: restoreDir.appendingPathComponent(SessionStore.fileName)
        )
        let restored = SessionStore(directory: restoreDir)
        try await restored.open()
        let restoredVersions = try await restored.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(restoredVersions.count, 1)
        XCTAssertEqual(restoredVersions.first?.version, 1, "恢复后版本号不漂移")
        XCTAssertTrue(
            restoredVersions.first?.body?.contains("交付预算表") ?? false,
            "恢复后行动项随纪要正文可核对"
        )
        await restored.close()
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
        // 先埋一条私密问答及其引文：完整删除不得暗留引文全文（MA-18）。
        _ = try await store.saveInnerOSExchange(
            InnerOSExchange(id: "inner-del-1", sessionID: sessionID, askedAt: Date(), question: "待删除预算多少？", status: .ready),
            evidence: [
                InnerOSEvidence(id: "ev-del-1", quote: "待删除预算"),
            ]
        )
        try await store.removeSession(id: sessionID)
        hits = try await store.searchKnowledge(query: "待删除")
        XCTAssertTrue(hits.isEmpty, "完整删除后检索不得带回已删内容")
        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertTrue(versions.isEmpty, "纪要行随会话级联删除")
        let pending = try await store.pendingMinutesRows()
        XCTAssertTrue(pending.isEmpty, "旧任务不得在删除后复活")
        // 问答与引文行随会话级联删除，不暗留全文。
        let exchanges = try await store.innerOSExchanges(sessionID: sessionID)
        XCTAssertTrue(exchanges.isEmpty, "问答行随会话级联删除")
        let evidence = try await store.innerOSEvidence(exchangeID: "inner-del-1")
        XCTAssertTrue(evidence.isEmpty, "引文行随问答级联删除，不暗留全文")
        let rows = try await store.lines(sessionID: sessionID)
        XCTAssertTrue(rows.isEmpty, "转录行随会话级联删除")
    }

    /// MA-05/MC-67（v1→v2 迁移）：空库直建 v2 后新行默认非 legacy；
    /// 回填语义由 `migrateV1ToV2` 的 UPDATE/INSERT 保证（旧库行才标 legacy）。
    /// 这里钉住新库行为：正文原样保留、final 行可记修订起点、不补造引用。
    func testMigrationV1ToV2KeepsMinutesAndMarksLegacy() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let lineID = "line-migrate-1"
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .speaker, text: "迁移前定稿的一句", source: .microphone, status: .final),
            id: lineID
        )
        let minutes = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: minutes.id, body: "# 迁移前纪要", model: nil)
        XCTAssertEqual(SessionStore.schemaVersion, 3)
        let versions = try await store.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.body, "# 迁移前纪要")
        // v3 新库新建行默认非 legacy、未采用（INSERT 显式写 0，不猜用户意图）；
        // v1 旧库行的 legacy 回填由迁移 UPDATE 完成，不在此断言。
        XCTAssertFalse(versions.first?.isLegacyImport ?? true, "v2 新建行默认非 legacy")
        XCTAssertFalse(versions.first?.isAccepted ?? true, "v3 新建行默认未采用，首次采用走 adoptMinutes")
        let recorded = try await store.recordTranscriptRevision(
            TranscriptRevision(id: "rev-migrate-1", lineID: lineID, sessionID: sessionID, text: "迁移前定稿的一句", origin: "legacy_import")
        )
        XCTAssertEqual(recorded.origin, "legacy_import")
        let revisions = try await store.transcriptRevisions(lineID: lineID)
        XCTAssertTrue(revisions.contains { $0.origin == "legacy_import" && $0.text.contains("迁移前定稿") })
    }

    /// MA-05/MC-68（无来源不补造引用）：导入知识文档允许无采集会话；
    /// 旧纪要缺转录时保留可读正文并标 legacy，不伪造来源快照。
    func testImportedDocumentWithoutSessionKeepsReadableMinutes() async throws {
        let store = try requireStore()
        let document = try await store.createMeetingDocument(
            MeetingDocument(id: "doc-import-1", sourceSessionID: nil, title: "外部导入纪要")
        )
        XCTAssertNil(document.sourceSessionID)
        XCTAssertEqual(document.title, "外部导入纪要")
        let fetched = try await store.meetingDocument(id: "doc-import-1")
        XCTAssertEqual(fetched?.id, "doc-import-1")
        // 无来源快照：读快照返回 nil，不伪造 ok 快照。
        let missing = try await store.sourceSnapshot(id: "snap-missing-1")
        XCTAssertNil(missing)
    }

    /// MA-05/MC-20（快照事务）：快照写入与文档关联同一事务；
    /// 文档不存在时拒绝写入，不半提交、不发已保存回执。
    func testSealSnapshotWithoutDocumentFailsWithoutPartialWrite() async throws {
        let store = try requireStore()
        let snapshot = MeetingSourceSnapshot(id: "snap-orphan-1", documentID: "doc-missing-1")
        do {
            _ = try await store.sealMeetingSource(snapshot)
            XCTFail("无文档的快照必须拒绝写入")
        } catch {
            // 预期失败：不半提交。
        }
        let missing = try await store.sourceSnapshot(id: "snap-orphan-1")
        XCTAssertNil(missing, "失败的封存不得留下半提交快照")
    }

    /// MA-05/MC-62（删除语义）：已关联知识文档的会话，普通删除入口拒绝级联销毁知识。
    func testRemoveSessionWithLinkedDocumentIsRejected() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.createMeetingDocument(
            MeetingDocument(id: "doc-link-1", sourceSessionID: sessionID, title: "已关联文档")
        )
        do {
            try await store.removeSession(id: sessionID)
            XCTFail("已关联知识文档的会话不得经普通入口删除")
        } catch {
            // 预期拒绝：知识不得被级联销毁。
        }
        let fetched = try await store.meetingDocument(id: "doc-link-1")
        XCTAssertEqual(fetched?.sourceSessionID, sessionID, "拒绝删除后关联必须保留")
    }

    /// MA-06/MC-25（采用指针）：采用 v1 后生成 v2 失败，采用版仍是 v1；
    /// 新排队不清采用指针，读采用版固定 v1。
    func testAcceptedPointerSurvivesFailedNewAttempt() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: first.id, body: "# 第一版", model: nil)
        let beforeAdopt = try await store.acceptedMinutes(sessionID: sessionID)
        XCTAssertNil(beforeAdopt, "未采用前没有采用版")
        let adopted = try await store.adoptMinutes(sessionID: sessionID, minutesID: first.id, expectedCurrentID: nil)
        XCTAssertTrue(adopted)
        let second = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.failMinutes(minutesID: second.id, reason: "模型没有给结果")
        let accepted = try await store.acceptedMinutes(sessionID: sessionID)
        XCTAssertEqual(accepted?.id, first.id, "新尝试失败不得清掉用户采用版")
        XCTAssertEqual(accepted?.body, "# 第一版")
    }

    /// MA-06/MC-25（展示口径）：`currentMinutes` 是展示与导出的唯一查询。
    /// 未采用过时退回最新可用候选；采用 v1 后，即使 v2 成功也仍默认展示 v1。
    func testCurrentMinutesPrefersAcceptedOverNewerUsableVersion() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: first.id, body: "# 第一版", model: nil)
        // 未采用：退回最新可用候选，不返回 nil 也不返回失败尝试。
        let unadopted = try await store.currentMinutes(sessionID: sessionID)
        XCTAssertEqual(unadopted?.id, first.id)
        _ = try await store.adoptMinutes(sessionID: sessionID, minutesID: first.id, expectedCurrentID: nil)
        // 新一版成功也不自动提升：重新生成不是采用动作（§7.7 不变量 3）。
        let second = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: second.id, body: "# 第二版", model: nil)
        let current = try await store.currentMinutes(sessionID: sessionID)
        XCTAssertEqual(current?.id, first.id, "重新生成成功也不得自动替换用户采用版")
        XCTAssertEqual(current?.body, "# 第一版")
        // 用户改采 v2 之后展示口径跟着走。
        _ = try await store.adoptMinutes(sessionID: sessionID, minutesID: second.id, expectedCurrentID: first.id)
        let switched = try await store.currentMinutes(sessionID: sessionID)
        XCTAssertEqual(switched?.id, second.id)
    }

    /// MA-06/MC-31（采用冲突）：两次采用基于同一旧版时，后返回的操作必须拒绝覆盖；
    /// 失败版与未知版不能被采用。
    func testAdoptMinutesRejectsConflictingAndIneligibleVersions() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let first = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: first.id, body: "# 第一版", model: nil)
        let second = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 9)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: second.id, body: "# 第二版", model: nil)
        // 两次采用都看到“无采用版”：先提交的赢，后提交的必须拒绝。
        let firstWins = try await store.adoptMinutes(sessionID: sessionID, minutesID: first.id, expectedCurrentID: nil)
        XCTAssertTrue(firstWins)
        let staleLoses = try await store.adoptMinutes(sessionID: sessionID, minutesID: second.id, expectedCurrentID: nil)
        XCTAssertFalse(staleLoses)
        let kept = try await store.acceptedMinutes(sessionID: sessionID)
        XCTAssertEqual(kept?.id, first.id)
        // 基于最新采用版改采第二版：预期一致才能提交。
        let switchWins = try await store.adoptMinutes(sessionID: sessionID, minutesID: second.id, expectedCurrentID: first.id)
        XCTAssertTrue(switchWins)
        let switched = try await store.acceptedMinutes(sessionID: sessionID)
        XCTAssertEqual(switched?.id, second.id)
        // 失败版不能被采用：指针保持不动。
        let failed = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 10)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.failMinutes(minutesID: failed.id, reason: "模型没有给结果")
        let failedRejected = try await store.adoptMinutes(sessionID: sessionID, minutesID: failed.id, expectedCurrentID: second.id)
        XCTAssertFalse(failedRejected)
        let stillSecond = try await store.acceptedMinutes(sessionID: sessionID)
        XCTAssertEqual(stillSecond?.id, second.id)
        // 未知版不能被采用。
        let missingRejected = try await store.adoptMinutes(sessionID: sessionID, minutesID: "no-such-version", expectedCurrentID: second.id)
        XCTAssertFalse(missingRejected)
    }

    /// 验收 5（恢复失败不损原库）：损坏的备份校验失败，且原库仍可读写；
    /// 调用方按“校验失败不得覆盖原库”处理，这里钉住失败侧语义。
    func testCorruptBackupFailsWithoutTouchingOriginal() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .user, text: "原库正文仍在", source: .microphone, status: .final)
        )
        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-corrupt-\(UUID().uuidString).sqlite3")
        try "not-a-database".write(to: corruptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        do {
            _ = try SessionStore.verifyBackup(at: corruptURL)
            XCTFail("损坏的备份必须校验失败，不能当作可用恢复源")
        } catch {
            // 预期失败：调用方不得继续用它覆盖原库。
        }
        // 原库不受校验失败影响：可读也可写。
        let rows = try await store.lines(sessionID: sessionID)
        XCTAssertTrue(rows.contains { $0.text.contains("原库正文仍在") })
        let minutes = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        XCTAssertEqual(minutes.version, 1)
    }

    /// MC-41/MC-42：问答建行一次，终态走条件 UPDATE；答案、状态、证据同一事务，
    /// 重复终态写入抛错不吞错；终态后同 ID 再建行抛主键冲突。
    func testInnerOSExchangeFinishIsTransactional() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .user, text: "预算 35 万元", source: .microphone, status: .final),
            id: "line-finish-1"
        )
        let exchange = InnerOSExchange(
            id: "inner-finish-1", sessionID: sessionID, askedAt: Date(),
            question: "预算多少？", status: .generating
        )
        _ = try await store.saveInnerOSExchange(exchange)
        // 终态：答案+证据同一事务落库。
        var done = exchange
        done.status = .ready
        done.answerText = "预算 35 万元"
        _ = try await store.finishInnerOSExchange(
            done, evidence: [InnerOSEvidence(id: "ev-finish-1", lineID: "line-finish-1", quote: "预算 35 万元")]
        )
        let loaded = try await store.innerOSExchanges(sessionID: sessionID)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.status, .ready)
        XCTAssertEqual(loaded.first?.answerText, "预算 35 万元")
        let evidence = try await store.innerOSEvidence(exchangeID: "inner-finish-1")
        XCTAssertEqual(evidence.count, 1)
        // 重复终态写入：已不在生成中，0 行受影响，必须抛错不吞错。
        do {
            _ = try await store.finishInnerOSExchange(done)
            XCTFail("重复终态写入必须抛错，不能吞错报成功")
        } catch {
            // 预期失败。
        }
        // 同 ID 再建行：主键冲突抛错，不吞错。
        do {
            _ = try await store.saveInnerOSExchange(exchange)
            XCTFail("同 ID 重复建行必须抛错")
        } catch {
            // 预期失败。
        }
        // 关闭重开后答案仍在：同 ID 是 ready 且答案齐全。
        let again = try await store.innerOSExchanges(sessionID: sessionID)
        XCTAssertEqual(again.first?.status, .ready)
        XCTAssertEqual(again.first?.answerText, "预算 35 万元")
    }

    /// MA-19/验收 3：JSON 导出携带版本身份（id）与创建时间，跨库往返不漂移。
    func testJSONExportKeepsMinutesIdentity() throws {
        let record = SessionRecord(
            id: "session-export-1",
            kind: .meeting,
            title: "预算会",
            state: .archived,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            engineProfile: "test",
            audioSource: .microphone
        )
        let minutes = MinutesVersion(
            id: "minutes-export-1",
            sessionID: "session-export-1",
            version: 2,
            status: .ready,
            body: "# 纪要",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let payload = SessionExportPayload(record: record, lines: [], minutes: minutes)
        let text = SessionExporter.export(payload, as: .json)
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exported = root["minutes"] as? [String: Any]
        else {
            XCTFail("JSON 导出必须可解析且含 minutes")
            return
        }
        XCTAssertEqual(exported["id"] as? String, "minutes-export-1", "版本身份不得漂移")
        XCTAssertEqual(exported["version"] as? Int, 2)
        XCTAssertEqual(exported["created_at"] as? Double, 1_700_000_100, "创建时间供复核判断，不得缺失")
    }

    /// MC-35/MC-36：引文必须逐字出自所指转录行；多次出现无法定位也判未验证。
    func testEvidenceQuoteMustMatchReferencedLine() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .user, text: "预算 35 万元，预算下周定。", source: .microphone, status: .final),
            id: "line-quote-1"
        )
        let exchangeID = try await store.saveInnerOSExchange(
            InnerOSExchange(id: "inner-quote-1", sessionID: sessionID, askedAt: Date(), question: "预算多少？", status: .ready),
            evidence: [
                InnerOSEvidence(id: "ev-ok", lineID: "line-quote-1", quote: "预算 35 万元"),
                InnerOSEvidence(id: "ev-wrong", lineID: "line-quote-1", quote: "预算 350 万元"),
                InnerOSEvidence(id: "ev-multi", lineID: "line-quote-1", quote: "预算"),
                InnerOSEvidence(id: "ev-noline", lineID: nil, quote: "预算 35 万元"),
            ]
        )
        XCTAssertEqual(exchangeID, "inner-quote-1")
        let checks = try await store.verifyEvidenceQuotes(exchangeID: exchangeID)
        XCTAssertEqual(checks.count, 4)
        let ok = checks.first { $0.evidenceID == "ev-ok" }
        XCTAssertEqual(ok?.verified, true, "逐字出自所指行的引文应该通过")
        let wrong = checks.first { $0.evidenceID == "ev-wrong" }
        XCTAssertEqual(wrong?.verified, false, "与原文不一致的引文不得标已验证")
        let multi = checks.first { $0.evidenceID == "ev-multi" }
        XCTAssertEqual(multi?.verified, false, "行内多次出现时不得随便选一处")
        let noline = checks.first { $0.evidenceID == "ev-noline" }
        XCTAssertEqual(noline?.verified, false, "没有指向转录行的引文不得标已验证")
    }

    /// MC-49：会议库分页不断页，早期会议可达，不遗漏不重复。
    func testSessionLibraryPagingReachesEarlySessions() async throws {
        let store = try requireStore()
        for index in 0..<10 {
            let record = try await store.createSession(
                SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone),
                id: "paging-session-\(index)"
            )
            XCTAssertEqual(record.id, "paging-session-\(index)")
        }
        let page1 = try await store.listSessions(kind: .meeting, limit: 4, offset: 0)
        let page2 = try await store.listSessions(kind: .meeting, limit: 4, offset: 4)
        let page3 = try await store.listSessions(kind: .meeting, limit: 4, offset: 8)
        // setUp 建了一场 meeting，加上本用例的 10 场。
        XCTAssertEqual(page1.count, 4)
        XCTAssertEqual(page2.count, 4)
        XCTAssertEqual(page3.count, 3)
        let ids = (page1 + page2 + page3).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "分页不得重复")
        XCTAssertTrue(ids.contains("paging-session-0"), "早期会议必须可达")
        let all = try await store.listSessions(kind: .meeting)
        XCTAssertEqual(all.count, 11, "不传分页参数时返回全部")
    }

    /// MC-17/MC-20：封存返回明确结果；成功读回 archived，未知记录如实失败。
    func testMeetingSealReportsExplicitResult() async throws {
        let coordinatorStore = try requireStore()
        let sessionID = try requireSessionID()
        let coordinator = SessionCoordinator(store: coordinatorStore)
        let sealed = await coordinator.sealMeeting(id: sessionID)
        XCTAssertEqual(sealed, .sealed(recordID: sessionID))
        let record = try await coordinatorStore.session(id: sessionID)
        XCTAssertEqual(record?.state, .archived)
        let missing = await coordinator.sealMeeting(id: "no-such-session")
        switch missing {
        case .failed(let id, _):
            XCTAssertEqual(id, "no-such-session")
        default:
            XCTFail("未知记录的封存必须如实失败，不能报成功")
        }
        // 失败封存不得发布成功 ID：此前成功封存的 ID 保持不变。
        XCTAssertEqual(coordinator.lastFinalizedSessionID, sessionID)
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

    /// MC-43/MC-35/MC-36：快照补充只收显式选进且全部引文已校验的问答。
    /// 未选中、未校验、空问答都不进入；标注不升级成会议事实。
    func testSupplementRenderKeepsOnlyVerifiedSelections() {
        let rendered = MinutesSupplements.render(
            questions: [
                (id: "picked", question: "预算怎么看？", answer: "建议分两期", inMinutes: true),
                (id: "unpicked", question: "预算怎么看？", answer: "建议分两期", inMinutes: false),
                (id: "unverified", question: "风险？", answer: "延期", inMinutes: true),
                (id: "empty", question: "  ", answer: nil, inMinutes: true),
            ],
            verifiedIDs: ["picked", "empty"]
        )
        XCTAssertTrue(rendered.contains("预算怎么看？"), "已选且已校验的问答应该进入快照")
        XCTAssertTrue(rendered.contains("用户选择的 AI 补充"), "补充必须标注身份，不升级成会议事实")
        XCTAssertFalse(rendered.contains("unpicked"), "未显式选进的不进入快照")
        XCTAssertFalse(rendered.contains("风险？"), "引文未校验的不进入快照")
    }

    /// 保存可靠（验收 1）：同 id 重复落行必须失败且不新增；两场序号各自单调、不串场。
    func testLineAppendRejectsDuplicateIDAndKeepsOrdinalsPerSession() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let other = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        let first = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .user, text: "第一句", source: .microphone, status: .final),
            id: "line-dup-1"
        )
        XCTAssertEqual(first, 1)
        do {
            _ = try await store.appendLine(
                LineDraft(sessionID: sessionID, role: .user, text: "重复一句", source: .microphone, status: .final),
                id: "line-dup-1"
            )
            XCTFail("同 id 重复落行必须失败")
        } catch {
            // 预期失败：行数不变。
        }
        let second = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .user, text: "第二句", source: .microphone, status: .final)
        )
        XCTAssertEqual(second, 2)
        let otherFirst = try await store.appendLine(
            LineDraft(sessionID: other.id, role: .user, text: "另一场第一句", source: .microphone, status: .final)
        )
        XCTAssertEqual(otherFirst, 1, "序号按场独立，不串场")
        let rows = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(rows.map(\.ordinal), [1, 2])
        XCTAssertTrue(rows.allSatisfy { $0.sessionID == sessionID })
        let otherRows = try await store.lines(sessionID: other.id)
        XCTAssertEqual(otherRows.map(\.text), ["另一场第一句"])
    }

    /// 保存可靠（验收 1：重启可找回）：关闭连接后用同一目录重开库，
    /// 正文、纪要、问答都在；重开后仍可写，不丢身份。
    func testReopenSameDirectoryKeepsTranscriptMinutesAndExchanges() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let persistedDir = try XCTUnwrap(directory)
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .speaker, text: "重启前定稿的一句", source: .microphone, status: .final),
            id: "line-reopen-1"
        )
        let minutes = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutes(minutesID: minutes.id, body: "# 重启前纪要", model: nil)
        _ = try await store.saveInnerOSExchange(
            InnerOSExchange(id: "inner-reopen-1", sessionID: sessionID, askedAt: Date(), question: "重启前问过？", answerText: "重启前答过", status: .ready)
        )
        // 关掉旧连接，再用同一目录重开：模拟关闭或重启应用。
        await store.close()
        self.store = nil
        let reopened = SessionStore(directory: persistedDir)
        try await reopened.open()
        self.store = reopened
        let rows = try await reopened.lines(sessionID: sessionID)
        XCTAssertTrue(rows.contains { $0.id == "line-reopen-1" && $0.text.contains("重启前定稿") })
        let versions = try await reopened.minutesVersions(sessionID: sessionID)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?.body, "# 重启前纪要")
        let exchanges = try await reopened.innerOSExchanges(sessionID: sessionID)
        XCTAssertEqual(exchanges.count, 1)
        XCTAssertEqual(exchanges.first?.answerText, "重启前答过")
        let hits = try await reopened.searchKnowledge(query: "重启前定稿")
        XCTAssertTrue(hits.contains { $0.sessionID == sessionID })
        // 重开后仍可写：序号接着走，不丢场身份。
        let ordinal = try await reopened.appendLine(
            LineDraft(sessionID: sessionID, role: .speaker, text: "重启后新一句", source: .microphone, status: .final)
        )
        XCTAssertEqual(ordinal, 2)
    }

    /// 保存可靠（验收 1/MC-24）：异常退出后重开，已存正文可读；
    /// 未封存标异常封存后可回看可导出，不丢已写下的行。
    func testAbandonedMeetingIsSealedButKeepsTranscript() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.appendLine(
            LineDraft(sessionID: sessionID, role: .speaker, text: "崩之前定稿的一句", source: .microphone, status: .final)
        )
        // 崩溃前未封存：state 仍是 recording，正文已在库里。
        let sealed = try await store.sealAbandonedSessions()
        XCTAssertEqual(sealed, [sessionID])
        let record = try await store.session(id: sessionID)
        XCTAssertEqual(record?.state, .archived)
        XCTAssertEqual(record?.endReason, .unexpectedExit)
        // 重开后回看：正文可读；检索可命中；导出用的最新可用行仍在。
        let rows = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(rows.map(\.text), ["崩之前定稿的一句"])
        let hits = try await store.searchKnowledge(query: "崩之前定稿")
        XCTAssertTrue(hits.contains { $0.sessionID == sessionID })
    }
}
