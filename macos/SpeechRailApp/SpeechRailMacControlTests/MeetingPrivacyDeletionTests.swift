import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 隐私范围、三档删除与旧任务重检（方案 MA-18 / MC-43、MC-62、MC-63、MC-72）。
///
/// 这里钉的是：
/// - 归档之后立刻从两条检索路径里消失，且**可以被撤销**；
/// - 只移除完整转录时，纪要与结论留着，锚点变成"来源已不可读"而不是断裂；
/// - 完整删除之后本机查不到任何东西，且文案不出现"可撤销"；
/// - 迟到的整理结果不会把已经归档的会议写回来；
/// - 用户勾选的那一句私密问答以 AI 补充身份进快照，别的几句不进。
@MainActor
final class MeetingPrivacyDeletionTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-privacy-\(UUID().uuidString)", isDirectory: true)
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

    private func requireStore() throws -> SessionStore { try XCTUnwrap(store) }
    private func requireSessionID() throws -> String { try XCTUnwrap(sessionID) }

    private func requireDocumentID() async throws -> String {
        let store = try requireStore()
        let document = try await store.meetingDocument(forSessionID: requireSessionID())
        return try XCTUnwrap(document?.id, "有转录的会议应当已经封出知识文档")
    }

    /// 造一场有转录、已封存、带结构化结论与锚点的会议。
    @discardableResult
    private func prepareMeetingWithCitations() async throws -> (minutesID: String, snapshotID: String, documentID: String) {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let texts = ["line-1": "下周三上线灰度。", "line-2": "预算按 3 万元算。"]
        for id in ["line-1", "line-2"] {
            _ = try await store.appendLine(
                LineDraft(
                    sessionID: sessionID, role: .speaker, text: texts[id]!, source: .microphone,
                    tStart: id == "line-1" ? 0 : 10, status: .final
                ),
                id: id
            )
        }
        let snapshot = try await store.sealMeetingSource(sessionID: sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id)

        let units = [
            MinutesSourceUnit(id: "u1", lineID: "line-1", ordinal: 1, speaker: "张三", text: texts["line-1"]!, startSeconds: 0),
            MinutesSourceUnit(id: "u2", lineID: "line-2", ordinal: 2, speaker: "李四", text: texts["line-2"]!, startSeconds: 10),
        ]
        let candidate = MinutesCandidateV2(
            title: "发布评审",
            overview: [],
            decisions: [.init(localID: "d1", text: "下周三上线灰度", modality: .decided, conditions: [], sourceUnitIDs: ["u1"])],
            actions: [.init(localID: "a1", task: "整理发布清单", ownerText: nil, dueExpression: nil, commitment: .proposed, sourceUnitIDs: ["u2"])],
            openQuestions: [],
            confidenceNotes: ""
        )
        let encoded = try JSONEncoder().encode(candidate)
        guard case .prepared(let prepared) = MinutesCandidateCodec.prepare(
            text: String(data: encoded, encoding: .utf8) ?? "", units: units
        ) else {
            XCTFail("结构合法的候选应当解析成功")
            throw XCTSkip("候选构造失败")
        }

        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 24, snapshotID: snapshotID)
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
        let documentID = try await requireDocumentID()
        return (row.id, snapshotID, documentID)
    }

    // MARK: - MC-62：归档后立刻不可检索，且可以被撤销

    func testArchivedMeetingDisappearsFromBothSearchPaths() async throws {
        let store = try requireStore()
        let prepared = try await prepareMeetingWithCitations()
        let beforeArchive = try await store.searchKnowledge(query: "灰度")
        XCTAssertFalse(beforeArchive.isEmpty, "先确认能搜到")

        let report = try await store.deleteMeetingKnowledge(documentID: prepared.documentID, mode: .archive)
        XCTAssertEqual(report.mode, .archive)
        XCTAssertTrue(report.mode.isRecoverable, "归档必须可以撤销")

        let lexAfter = try await store.searchKnowledge(query: "灰度")
        XCTAssertTrue(lexAfter.isEmpty, "归档后词法检索不该再命中")
        let fullTextAfter = try await store.searchKnowledgeFullText(query: "灰度")
        XCTAssertTrue(fullTextAfter.hits.isEmpty, "归档后全文检索不该再命中")
        // 显式要求包含归档时才看得到——这是给"撤销归档"用的口子，不是默认。
        let withArchived = try await store.searchKnowledgeFullText(
            query: "灰度", scope: MeetingKnowledgeScope(includesArchived: true)
        )
        XCTAssertFalse(withArchived.hits.isEmpty, "显式包含归档时应当能搜回来")

        let restored = try await store.restoreMeetingKnowledge(documentID: prepared.documentID)
        XCTAssertTrue(restored)
        let afterRestore = try await store.searchKnowledgeFullText(query: "灰度")
        XCTAssertFalse(afterRestore.hits.isEmpty, "撤销后要能搜回来")
        let sessionID = try requireSessionID()
        let stillDeleted = try await store.isMeetingDeleted(sessionID: sessionID)
        XCTAssertFalse(stillDeleted)
    }

    // MARK: - 只移除完整转录：结论留着，来源变成不可读

    func testRemoveTranscriptKeepsConclusionsAndMarksSourceUnreadable() async throws {
        let store = try requireStore()
        let prepared = try await prepareMeetingWithCitations()

        let report = try await store.deleteMeetingKnowledge(documentID: prepared.documentID, mode: .removeTranscript)
        XCTAssertEqual(report.removedLines, 2, "两行转录都该删掉")
        XCTAssertFalse(report.mode.isRecoverable, "移除转录不可撤销")
        XCTAssertFalse(report.externalCopyWarning.contains("撤销"), "文案不许暗示能撤销：\(report.externalCopyWarning)")

        let minutes = try await store.minutesVersion(id: prepared.minutesID)
        XCTAssertEqual(minutes?.status, .ready, "纪要本身要留下")
        XCTAssertNotNil(minutes?.body, "纪要正文要留下")

        let items = try await store.minutesItems(minutesID: prepared.minutesID)
        XCTAssertFalse(items.isEmpty, "结论条目要留下")
        let anchor = try XCTUnwrap(items.flatMap(\.anchors).first)
        XCTAssertNil(anchor.quote, "原句没了，锚点必须如实变成来源不可读")
        let snapshot = try await store.sourceSnapshot(id: prepared.snapshotID)
        XCTAssertNil(snapshot, "快照随原句一起失效")

        let references = try await store.verifyReferences()
        XCTAssertTrue(references.isClean, "锚点指向已删修订是合法状态，不算断裂：\(references.problems)")
    }

    /// 来源被删之后，锚点不能还自称"逐字命中"。
    ///
    /// 验收标准 3 要求"修改来源后相关结论提示复核"：原句都没了，
    /// `exact_source_match` 就是**假话**——它会让这条结论在界面上
    /// 显示成"已核对"，而它根本无从核对。
    func testAnchorStopsClaimingExactMatchAfterItsSourceIsRemoved() async throws {
        let store = try requireStore()
        let prepared = try await prepareMeetingWithCitations()
        try await store.deleteMeetingKnowledge(documentID: prepared.documentID, mode: .removeTranscript)

        let items = try await store.minutesItems(minutesID: prepared.minutesID)
        let anchors = items.flatMap(\.anchors)
        XCTAssertFalse(anchors.isEmpty, "结论条目应当还在，锚点也应当还在")
        for anchor in anchors {
            XCTAssertNotEqual(
                anchor.verification, "exact_source_match",
                "来源已被删除，锚点不许继续自称逐字命中"
            )
        }
    }

    /// 已删会议不允许再写新版本：否则一次迟到的编辑会把刚删掉的内容
    /// 又变出一个可被检索的版本——验收标准 4「删除内容不得被旧任务恢复」。
    ///
    /// （因此"降级要沿版本沿用传下去"这条路径在删除之后是**不可达**的，
    /// 不需要额外断言；降级只需在删除那一刻做对。）
    func testDeletedMeetingRefusesToProduceANewMinutesVersion() async throws {
        let store = try requireStore()
        let prepared = try await prepareMeetingWithCitations()
        try await store.deleteMeetingKnowledge(documentID: prepared.documentID, mode: .removeTranscript)

        let version = try await store.minutesVersion(id: prepared.minutesID)
        let body = try XCTUnwrap(version?.body)
        do {
            _ = try await store.saveUserMinutesEdit(
                sessionID: try requireSessionID(),
                editingMinutesID: prepared.minutesID,
                body: body + "\n\n偷偷加一句。"
            )
            XCTFail("已删会议不该还能写出新版本")
        } catch {
            // 预期路径：写入被拒。
        }

        let unchanged = try await store.minutesVersion(id: prepared.minutesID)
        XCTAssertEqual(unchanged?.body, body, "正文一个字都不该变")
    }

    /// 同一条结论的**判定**也要跟着降级，否则审阅轴看不到这件事。
    func testConclusionIsMarkedForReviewWhenItsSourceDisappears() async throws {
        let store = try requireStore()
        let prepared = try await prepareMeetingWithCitations()
        try await store.deleteMeetingKnowledge(documentID: prepared.documentID, mode: .removeTranscript)

        let items = try await store.minutesItems(minutesID: prepared.minutesID)
        let cited = items.filter { !$0.anchors.isEmpty }
        XCTAssertFalse(cited.isEmpty, "被测样本要有带引用的结论")
        for item in cited {
            XCTAssertNotEqual(
                item.verdict, .supported,
                "来源没了就不能还是『已核对』：\(item.localID)"
            )
        }
    }

    // MARK: - MC-72：完整删除

    func testFullDeleteRemovesEverythingAndDoesNotPromiseUndo() async throws {
        let store = try requireStore()
        let prepared = try await prepareMeetingWithCitations()

        let report = try await store.deleteMeetingKnowledge(documentID: prepared.documentID, mode: .deleteEverything)
        XCTAssertGreaterThanOrEqual(report.removedMinutes, 1)
        XCTAssertGreaterThanOrEqual(report.removedItems, 1)
        XCTAssertGreaterThanOrEqual(report.removedAnchors, 1)
        XCTAssertFalse(report.mode.isRecoverable)
        XCTAssertFalse(
            report.externalCopyWarning.contains("可以撤销"),
            "完整删除不假装可撤销：\(report.externalCopyWarning)"
        )
        XCTAssertTrue(
            report.externalCopyWarning.contains("备份"),
            "外部副本边界必须说出来：\(report.externalCopyWarning)"
        )

        let document = try await store.meetingDocument(id: prepared.documentID)
        XCTAssertNil(document, "文档不该还在")
        let sessionID = try requireSessionID()
        let record = try await store.session(id: sessionID)
        XCTAssertNil(record, "会话不该还在")
        let minutes = try await store.minutesVersion(id: prepared.minutesID)
        XCTAssertNil(minutes, "纪要版本不该还在")
        let fullText = try await store.searchKnowledgeFullText(query: "灰度")
        XCTAssertTrue(fullText.hits.isEmpty, "删干净之后不该搜得到")
        let text = try await store.searchKnowledge(query: "灰度")
        XCTAssertTrue(text.isEmpty, "词法检索同样不该命中")
    }

    func testDeletingOneMeetingLeavesOtherMeetingsIntact() async throws {
        let store = try requireStore()
        let prepared = try await prepareMeetingWithCitations()

        // 同一库里再开一场会，确保删除的范围是"这一场"而不是"这一库"。
        let other = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone, title: "另一场会")
        )
        _ = try await store.appendLine(
            LineDraft(
                sessionID: other.id, role: .speaker,
                text: "这份不该被牵连：保留原始预算口径。", source: .microphone, status: .final
            ),
            id: "other-line"
        )

        _ = try await store.deleteMeetingKnowledge(documentID: prepared.documentID, mode: .deleteEverything)

        let otherLines = try await store.lines(sessionID: other.id)
        XCTAssertEqual(otherLines.count, 1, "另一场会的转录不该被动过")
        let survivors = try await store.searchKnowledge(query: "保留原始预算口径")
        XCTAssertEqual(survivors.count, 1, "另一场会仍然可检索")
        let deleted = try await store.searchKnowledge(query: "下周三上线灰度")
        XCTAssertTrue(deleted.isEmpty, "被删那一场不该还搜得到")
        let references = try await store.verifyReferences()
        XCTAssertTrue(references.isClean, "删除不该在别处留下断裂引用：\(references.problems)")
    }

    // MARK: - MC-63：迟到的结果不写回

    func testLateMinutesResultIsRejectedAfterArchive() async throws {
        let store = try requireStore()
        let prepared = try await prepareMeetingWithCitations()
        // 再排一版并认领，模拟"用户归档时还有一个任务在跑"。
        _ = try await store.enqueueMinutes(sessionID: try requireSessionID(), model: nil, promptChars: 20)
        let claimed = try await store.claimMinutes(sessionID: try requireSessionID(), lease: 600)
        let running = try XCTUnwrap(claimed)

        _ = try await store.deleteMeetingKnowledge(documentID: prepared.documentID, mode: .archive)
        let committed = try await store.finishMinutesIfOwner(
            minutesID: running.id, expectedAttempts: running.attempts, body: "# 迟到的正文", model: nil
        )
        XCTAssertFalse(committed, "已经归档的会议不能被迟到的结果写回来")

        let row = try await store.minutesVersion(id: running.id)
        XCTAssertEqual(row?.status, .cancelled, "这一版要标成用户停止，而不是整理好了")
        XCTAssertNil(row?.body, "正文不能落库")
        XCTAssertEqual(
            row?.failureReason, "会议已归档或删除，这次整理结果没有写入",
            "原因要说清楚是会议没了，不是模型没整理出来"
        )
    }

    /// 测试夹具走的 `finishMinutesForTestOnly` 同样过归档守卫。
    /// 它复刻旧 `finishMinutes` 的"直接写"形态（不限代际），
    /// 区别是多了一道删除/归档检查——少了这道，归档后的完成会悄悄写回来。
    func testTestOnlyFinishIsRejectedAfterArchive() async throws {
        let store = try requireStore()
        let prepared = try await prepareMeetingWithCitations()
        _ = try await store.enqueueMinutes(sessionID: try requireSessionID(), model: nil, promptChars: 20)
        let queued = try await store.minutesVersions(sessionID: try requireSessionID())
        let target = try XCTUnwrap(queued.first(where: { $0.status == .queued }))

        _ = try await store.deleteMeetingKnowledge(documentID: prepared.documentID, mode: .archive)
        let committed = try await store.finishMinutesForTestOnly(
            minutesID: target.id, body: "# 迟到的正文", model: nil
        )
        XCTAssertFalse(committed, "已经归档的会议不能被迟到的结果写回来")

        let row = try await store.minutesVersion(id: target.id)
        XCTAssertEqual(row?.status, .cancelled, "这一版要标成用户停止，而不是整理好了")
        XCTAssertNil(row?.body, "正文不能落库")
    }

    // MARK: - MC-43：只有用户勾选的那一句进快照

    func testOnlySelectedPrivateAnswerEntersSnapshotAsSupplement() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        for id in ["line-1"] {
            _ = try await store.appendLine(
                LineDraft(sessionID: sessionID, role: .speaker, text: "先记一下这两件事。", source: .microphone, status: .final),
                id: id
            )
        }
        let qa1 = InnerOSExchange(id: "qa-1", sessionID: sessionID, question: "灰度什么时候？")
        _ = try await store.saveInnerOSExchange(qa1, evidence: [])
        var answered1 = qa1
        answered1.answerText = "模型整理出来的说法：下周三灰度。"
        answered1.status = .ready
        _ = try await store.finishInnerOSExchange(answered1)

        let qa2 = InnerOSExchange(id: "qa-2", sessionID: sessionID, question: "预算是多少？")
        _ = try await store.saveInnerOSExchange(qa2, evidence: [])
        var answered2 = qa2
        answered2.answerText = "模型整理出来的说法：3 万元。"
        answered2.status = .ready
        _ = try await store.finishInnerOSExchange(answered2)
        // 私密问答默认不进范围：用户勾选哪句，就只有哪句跟快照走。
        try await store.setInnerOSInMinutes(exchangeID: qa1.id, included: true)

        let snapshot = try await store.sealMeetingSource(sessionID: sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id)
        let supplements = try await store.meetingSupplements(snapshotID: snapshotID)
        XCTAssertEqual(supplements.map(\.exchangeID), [qa1.id], "只有勾选的那一句进快照")

        // 关键：它不能混进转录行修订——混进去就是把模型的话升级成会议事实。
        let revisions = try await store.transcriptRevisions(lineID: "line-1")
        XCTAssertFalse(
            revisions.contains { $0.text.contains("模型整理出来的说法") },
            "AI 补充不得写进行修订"
        )
    }
}
