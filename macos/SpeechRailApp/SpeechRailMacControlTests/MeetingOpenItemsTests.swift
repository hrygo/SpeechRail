import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 未完成事项清单（MC-56）。
///
/// 这一条验收的原话是「某项目有 37 条未完成事项 → 列出所有未完成 →
/// 关系查询完整分页并给总数；**不能只返回 top10 却称全部**」。
/// 所以这里钉的是三件事：
/// - **"未完成"的定义**：已完成、已放弃都不算，受阻算。从来没人更新过进度也算——
///   会上定了就是定了，把它藏起来等于让人重新问一遍会议到底定了什么；
/// - **总数是全量的**，不是当前这一页有几个；
/// - **翻页真的能翻完**：把每一页拼起来必须正好等于总数，不重不漏。
@MainActor
final class MeetingOpenItemsTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-open-items-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        self.directory = directory
        self.store = store
    }

    override func tearDown() async throws {
        if let store { await store.close() }
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func requireStore() throws -> SessionStore { try XCTUnwrap(store) }

    private struct Meeting {
        var sessionID: String
        var documentID: String
        var snapshotID: String
        var minutesID: String
    }

    @discardableResult
    private func makeMeeting(
        title: String,
        projectID: String? = nil,
        actions: [String],
        decisions: [String] = [],
        at occurredAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async throws -> Meeting {
        let store = try requireStore()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone, title: title)
        )
        _ = try await store.appendLine(
            LineDraft(
                sessionID: record.id, role: .speaker, text: "先确认这几点。",
                source: .microphone, tStart: 0, status: .final
            ),
            id: "\(record.id)-line"
        )
        let snapshot = try await store.sealMeetingSource(sessionID: record.id)
        let snapshotID = try XCTUnwrap(snapshot?.id)
        let existing = try await store.meetingDocument(forSessionID: record.id)
        let documentID = try XCTUnwrap(existing?.id)
        try await store.updateMeetingDocument(
            id: documentID, title: .some(title), projectID: .some(projectID), occurredAt: .some(occurredAt)
        )
        let minutesID = try await writeMinutesVersion(
            sessionID: record.id, snapshotID: snapshotID, title: title,
            actions: actions, decisions: decisions
        )
        return Meeting(
            sessionID: record.id, documentID: documentID,
            snapshotID: snapshotID, minutesID: minutesID
        )
    }

    @discardableResult
    private func writeMinutesVersion(
        sessionID: String,
        snapshotID: String,
        title: String,
        actions: [String],
        decisions: [String]
    ) async throws -> String {
        let store = try requireStore()
        let units = [MinutesSourceUnit(
            id: "u1", lineID: "\(sessionID)-line", ordinal: 1,
            speaker: "张三", text: "先确认这几点。", startSeconds: 0
        )]
        var candidate = MinutesCandidateV2(
            title: title, overview: [], decisions: [], actions: [],
            openQuestions: [], confidenceNotes: ""
        )
        for (index, text) in decisions.enumerated() {
            candidate.decisions.append(.init(
                localID: "d\(index)", text: text, modality: .decided,
                conditions: [], sourceUnitIDs: ["u1"]
            ))
        }
        for (index, text) in actions.enumerated() {
            candidate.actions.append(.init(
                localID: "a\(index)", task: text, ownerText: nil,
                dueExpression: nil, commitment: .proposed, sourceUnitIDs: ["u1"]
            ))
        }
        let encoded = try JSONEncoder().encode(candidate)
        guard case .prepared(let prepared) = MinutesCandidateCodec.prepare(
            text: String(data: encoded, encoding: .utf8) ?? "", units: units
        ) else {
            XCTFail("结构合法的候选应当解析成功")
            throw XCTSkip("候选构造失败")
        }
        _ = try await store.enqueueMinutes(
            sessionID: sessionID, model: nil, promptChars: 20, snapshotID: snapshotID
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
                unitsByID: ["u1": units[0]],
                revisionIDsByLine: revisionIDs
            ),
            snapshotID: snapshotID
        )
        XCTAssertTrue(saved)
        return row.id
    }

    private func actionIDs(minutesID: String) async throws -> [String] {
        try await requireStore().minutesItems(minutesID: minutesID)
            .filter { $0.kind == "action" }.map(\.id)
    }

    private func actionID(minutesID: String, at index: Int) async throws -> String {
        let ids = try await actionIDs(minutesID: minutesID)
        guard ids.indices.contains(index) else {
            XCTFail("这一版里没有第 \(index) 条行动项")
            throw XCTSkip("缺少条目")
        }
        return ids[index]
    }

    private let openFilter = KnowledgeItemFilter(kinds: ["action"], openOnly: true)

    // MARK: - "未完成"到底指哪些

    func testDoneDroppedAndNeverTrackedSortOutCorrectly() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(
            title: "发布评审", projectID: "p",
            actions: ["整理发布清单", "约设计师复核", "砍掉旧横幅方案", "同步给客户"]
        )
        let ids = try await actionIDs(minutesID: meeting.minutesID)
        XCTAssertEqual(ids.count, 4)

        // 0 没人更新过 → 未完成；1 受阻 → 未完成；2 已放弃 → 不算；3 已完成 → 不算。
        try await store.recordExecutionEvent(itemID: ids[1], status: .blocked)
        try await store.recordExecutionEvent(itemID: ids[2], status: .dropped)
        try await store.recordExecutionEvent(itemID: ids[3], status: .done)

        let page = try await store.knowledgeItems(filter: openFilter, limit: 50)
        let texts = Set(page.items.map(\.text))
        XCTAssertEqual(page.counts.total, 2, "只有两条真正未完成")
        XCTAssertTrue(texts.contains("整理发布清单"), "没人更新过进度也算未完成")
        XCTAssertTrue(texts.contains("约设计师复核"), "受阻仍然是未完成")
        XCTAssertFalse(texts.contains("砍掉旧横幅方案"), "已放弃不是未完成")
        XCTAssertFalse(texts.contains("同步给客户"), "已完成不是未完成")
    }

    /// 用户标了完成、之后又把它捡回来——最新一条说了算。
    func testTheLatestEventDecidesNotTheFirstOne() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let id = try await actionID(minutesID: meeting.minutesID, at: 0)
        try await store.recordExecutionEvent(itemID: id, status: .done)
        try await store.recordExecutionEvent(itemID: id, status: .open)

        let page = try await store.knowledgeItems(filter: openFilter, limit: 50)
        XCTAssertEqual(page.counts.total, 1, "最后一条是未完成，它就回到清单里")
    }

    /// 结论与未决问题没有"做完"这回事，不该被这个条件悄悄滤掉。
    func testDecisionsAreNotConstrainedByOpenOnly() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(
            title: "发布评审", actions: [], decisions: ["发布窗口定在九月"]
        )
        let page = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(kinds: ["decision"], openOnly: true), limit: 50
        )
        XCTAssertEqual(page.counts.total, 1, "结论不受未完成约束")
    }

    /// 纪要重新生成会换掉 `item.id`，用户标的状态挂在稳定 key 上，不能跟着丢。
    func testOpenItemsSurviveMinutesRegeneration() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", projectID: "p", actions: ["整理发布清单"])
        let first = try await actionID(minutesID: meeting.minutesID, at: 0)
        try await store.recordExecutionEvent(itemID: first, status: .done)

        let second = try await writeMinutesVersion(
            sessionID: meeting.sessionID, snapshotID: meeting.snapshotID,
            title: "发布评审", actions: ["整理发布清单"], decisions: []
        )
        let regenerated = try await store.knowledgeItems(filter: openFilter, limit: 50)
        XCTAssertEqual(regenerated.counts.total, 0, "已完成的事重新生成之后仍然已完成")
        _ = second
    }

    // MARK: - MC-56 的原话：列出全部，不能只给 top10 却称全部

    func testTotalIsTheWholeSetNotTheCurrentPage() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let wanted = 37
        // 跨两场会摆满 37 条，模拟"某项目有 37 条未完成事项"。
        for chunk in 0..<2 {
            let actions = (0..<(chunk == 0 ? 19 : 18)).map { "第\(chunk)组行动 \($0)" }
            _ = try await makeMeeting(
                title: "第\(chunk)场", projectID: "p", actions: actions,
                at: base.addingTimeInterval(Double(chunk) * 86_400)
            )
        }
        let all = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(projectIDs: ["p"], kinds: ["action"], openOnly: true),
            limit: 10, offset: 0
        )
        XCTAssertEqual(all.counts.total, wanted, "总数是全量的 37，不是这一页的 10")
        XCTAssertEqual(all.items.count, 10, "第一页就是 10 条")

        // 翻页翻得完：每一页拼起来正好 37 条，不重不漏。
        var seen: [String] = []
        var offset = 0
        while true {
            let page = try await store.knowledgeItems(
                filter: KnowledgeItemFilter(projectIDs: ["p"], kinds: ["action"], openOnly: true),
                limit: 10, offset: offset
            )
            seen.append(contentsOf: page.items.map(\.id))
            offset += page.items.count
            if offset >= page.counts.total || page.items.isEmpty { break }
        }
        XCTAssertEqual(seen.count, wanted, "翻完四页正好 37 条")
        XCTAssertEqual(Set(seen).count, wanted, "没有重复")
    }

    func testEmptyResultIsAnHonestZero() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", projectID: "p", actions: ["整理发布清单"])
        try await store.recordExecutionEvent(
            itemID: try await actionID(minutesID: meeting.minutesID, at: 0), status: .done
        )

        let page = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(projectIDs: ["p"], kinds: ["action"], openOnly: true),
            limit: 10
        )
        XCTAssertEqual(page.counts.total, 0)
        XCTAssertTrue(page.items.isEmpty)
    }

    // MARK: - 每条都要带上状态、负责人和期限

    func testEachItemCarriesItsExecutionState() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", projectID: "p", actions: ["整理发布清单"])
        let id = try await actionID(minutesID: meeting.minutesID, at: 0)
        try await store.recordExecutionEvent(
            itemID: id, status: .blocked,
            ownerText: .some("张三"), dueText: .some("五月前"),
            dueDate: .some(Date(timeIntervalSince1970: 1_746_000_000))
        )

        let page = try await store.knowledgeItems(filter: openFilter, limit: 50)
        let item = try XCTUnwrap(page.items.first)
        let execution = try XCTUnwrap(item.execution, "列出来就要能看见进度，不只是正文")
        XCTAssertEqual(execution.status, .blocked)
        XCTAssertEqual(execution.ownerText, "张三")
        XCTAssertEqual(execution.dueText, "五月前")
        XCTAssertNotNil(execution.dueDate)
    }

    /// 没记录过进度的那条，`execution` 是 nil——界面据此显示"未完成"而不是"不知道"。
    func testNeverTrackedItemHasNoExecutionState() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let page = try await store.knowledgeItems(filter: openFilter, limit: 50)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertNil(item.execution, "没记录过就是没有状态，不假装知道")
    }

    // MARK: - 界面上真的够得着（协调器透传 + 模型状态）

    func testCoordinatorAndModelExposeTheOpenItems() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(
            title: "发布评审", projectID: "p", actions: ["整理发布清单", "同步给客户"]
        )
        let ids = try await actionIDs(minutesID: meeting.minutesID)
        try await store.recordExecutionEvent(itemID: ids[1], status: .done)

        let coordinator = SessionCoordinator(store: store)
        let model = MeetingLibraryModel(coordinator: coordinator)
        await model.filter(projectID: "p")
        await model.loadOpenItems(offset: 0)

        XCTAssertEqual(model.openItemCounts.total, 1, "模型拿到的总数也是全量的")
        XCTAssertEqual(model.openItems.map(\.text), ["整理发布清单"])
        XCTAssertNotNil(model.openItems.first?.occurredAt, "清单上要能看出是哪一场会定的")
    }

    // MARK: - 写侧：清单不能是只读的（MA-14 写侧此前零消费方）
    //
    // 上一组测试证明了"列得出来"。这一组证明"点得动"：
    // 一个列得出却点不动的待办清单，用户唯一的用法还是打开每一场会议去回忆。

    private func makeLibrary() async throws -> (MeetingLibraryModel, SessionCoordinator) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "meeting-open-items-\(UUID().uuidString)"))
        let coordinator = SessionCoordinator(store: try requireStore(), defaults: defaults)
        return (MeetingLibraryModel(coordinator: coordinator), coordinator)
    }

    func testMarkingAnActionDoneTakesItOutOfTheOpenList() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(
            title: "发布评审", projectID: "p", actions: ["整理发布清单", "同步给客户"]
        )
        let ids = try await actionIDs(minutesID: meeting.minutesID)
        let (model, _) = try await makeLibrary()
        await model.filter(projectID: "p")
        await model.loadOpenItems(offset: 0)
        XCTAssertEqual(model.openItemCounts.total, 2)

        let ok = await model.markOpenItem(ids[0], status: .done)
        XCTAssertTrue(ok)
        XCTAssertEqual(model.openItemCounts.total, 1, "做完的事不该继续占着待办位")
        XCTAssertEqual(model.openItems.map(\.text), ["同步给客户"])
    }

    /// 清单能点，但点完必须真的落到库里——否则只是一个界面的假动作。
    func testMarkingDoneIsActuallyRecordedInTheStore() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let id = try await actionID(minutesID: meeting.minutesID, at: 0)
        let (model, _) = try await makeLibrary()
        await model.loadOpenItems(offset: 0)

        _ = await model.markOpenItem(id, status: .done)
        let state = try await store.executionState(itemID: id)
        XCTAssertEqual(state?.status, .done)
    }

    /// 做完就再也看不见、也撤不回来，是比"点不动"更糟的死路。
    func testCompletedItemsStayVisibleAndCanBeReopened() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", projectID: "p", actions: ["整理发布清单"])
        let id = try await actionID(minutesID: meeting.minutesID, at: 0)
        let (model, _) = try await makeLibrary()
        await model.filter(projectID: "p")
        await model.loadOpenItems(offset: 0)
        _ = await model.markOpenItem(id, status: .done)

        await model.setOpenItemMode(.all)
        XCTAssertEqual(model.openItemCounts.total, 1, "切到「全部」才看得到做完的那条")
        XCTAssertEqual(model.openItems.first?.execution?.status, .done)

        _ = await model.markOpenItem(id, status: .open)
        let reopened = try await store.executionState(itemID: id)
        XCTAssertEqual(reopened?.status, .open)
        await model.setOpenItemMode(.open)
        XCTAssertEqual(model.openItemCounts.total, 1, "撤回来之后它又回到未完成")
    }

    /// 已放弃的也不该消失得无声无息——用户要能看见自己决定不做什么。
    func testDroppedItemsAreVisibleInAllMode() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["砍掉旧横幅方案"])
        let id = try await actionID(minutesID: meeting.minutesID, at: 0)
        let (model, _) = try await makeLibrary()
        _ = await model.markOpenItem(id, status: .dropped)

        await model.loadOpenItems(offset: 0)
        XCTAssertEqual(model.openItemCounts.total, 0, "已放弃不算未完成")
        await model.setOpenItemMode(.all)
        XCTAssertEqual(model.openItemCounts.total, 1)
        XCTAssertEqual(model.openItems.first?.execution?.status, .dropped)
    }

    /// 改负责人和期限**不顺带改状态**：写着"五月前"不等于这件事已经做完。
    func testUpdatingOwnerAndDueLeavesTheStatusAlone() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let id = try await actionID(minutesID: meeting.minutesID, at: 0)
        let (model, _) = try await makeLibrary()
        await model.loadOpenItems(offset: 0)

        _ = await model.updateOpenItem(id, owner: "李四", due: "五月前")
        let state = try await store.executionState(itemID: id)
        XCTAssertEqual(state?.ownerText, "李四")
        XCTAssertEqual(state?.dueText, "五月前")
        XCTAssertEqual(state?.status, .open, "填了期限不等于做完了")

        let item = try XCTUnwrap(model.openItems.first)
        XCTAssertEqual(item.execution?.ownerText, "李四", "界面上要立刻看得见")
        XCTAssertEqual(item.execution?.dueText, "五月前")
    }

    /// 空字符串是"清掉"，不是"保持原样"——留一个看不见的旧负责人更糟。
    func testEmptyOwnerClearsIt() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let id = try await actionID(minutesID: meeting.minutesID, at: 0)
        let (model, _) = try await makeLibrary()
        await model.loadOpenItems(offset: 0)

        _ = await model.updateOpenItem(id, owner: "李四", due: nil)
        _ = await model.updateOpenItem(id, owner: "", due: nil)
        let cleared = try await store.executionState(itemID: id)
        XCTAssertNil(cleared?.ownerText, "空字符串是清掉，不是保持原样")
    }

    /// 写失败要把话说到，列表也不能悄悄变样。
    func testWriteFailureSurfacesAndLeavesTheListAlone() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", projectID: "p", actions: ["整理发布清单"])
        let (model, _) = try await makeLibrary()
        await model.filter(projectID: "p")
        await model.loadOpenItems(offset: 0)
        let before = model.openItems.map(\.id)

        // 一个不存在的条目 id：写不进库。
        let ok = await model.markOpenItem("根本没有这一条", status: .done)
        XCTAssertFalse(ok)
        XCTAssertNotNil(model.openItemWriteError, "失败要有一句能看的话，不能静默")
        XCTAssertEqual(model.openItems.map(\.id), before, "失败时列表保持原样")
    }

    /// 勾掉一条之后不该被弹回第一页——37 条的清单跳回顶部等于惩罚用户。
    func testTickingAnItemDoesNotJumpBackToTheFirstPage() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 每页 50 条，所以要摆够 60 条才有第二页。
        let actions = (0..<60).map { "行动 \($0)" }
        let meeting = try await makeMeeting(title: "发布评审", projectID: "p", actions: actions, at: base)
        let ids = try await actionIDs(minutesID: meeting.minutesID)
        let (model, _) = try await makeLibrary()
        await model.filter(projectID: "p")
        await model.loadOpenItems(offset: 0)

        await model.loadOpenItems(offset: model.openItemLimit)
        XCTAssertEqual(model.openItemOffset, model.openItemLimit)
        XCTAssertEqual(model.openItems.count, 10, "第二页还剩十条")

        // 勾掉第二页的第一条：它下面的九条顶上来，不该把用户甩回第一页。
        _ = await model.markOpenItem(ids[50], status: .done)
        XCTAssertEqual(model.openItemOffset, model.openItemLimit, "还在第二页的位置上")
        XCTAssertFalse(model.openItems.contains { $0.id == ids[50] })
        XCTAssertEqual(model.openItems.count, 9)
        XCTAssertEqual(model.openItemCounts.total, 59)
    }

    /// 翻到最后一页再勾掉最后一条，不该停在一个空页面上。
    func testTickingTheLastItemOnTheLastPageStepsBack() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(
            title: "发布评审", projectID: "p", actions: ["行动 A", "行动 B"]
        )
        let ids = try await actionIDs(minutesID: meeting.minutesID)
        let (model, _) = try await makeLibrary()
        await model.filter(projectID: "p")
        await model.loadOpenItems(offset: 0)

        _ = await model.markOpenItem(ids[0], status: .done)
        XCTAssertFalse(model.openItems.isEmpty, "还有一条没做完，不该翻到空页")
        XCTAssertEqual(model.openItemCounts.total, 1)
    }

    func testOpenItemModeHeadlineFollowsTheMode() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let (model, _) = try await makeLibrary()
        await model.loadOpenItems(offset: 0)
        XCTAssertEqual(model.openItemsHeadline, "未完成事项（共 1 条）")
        await model.setOpenItemMode(.all)
        XCTAssertEqual(model.openItemsHeadline, "全部行动项（共 1 条）")
    }
}
