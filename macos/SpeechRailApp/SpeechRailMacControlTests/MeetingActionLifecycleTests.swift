import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 行动生命周期与决策演进（方案 MA-14 / MC-53、MC-57～MC-59）。
///
/// 这里钉的都是**用户已经付出过成本**的东西不能被系统弄丢：
/// - 手动标完成、改负责人之后重新生成本场纪要，状态必须还在（MC-53）；
/// - 重新生成**不能复活**已完成的任务，也不能因为"新一版没提到"就当成已完成；
/// - 期限改了不等于过去的承诺被改写了（MC-59）；
/// - 跨会议判定"新结论取代旧结论"必须要有证据或用户确认，字面像不算（MC-57）；
/// - 两场会结论相反时两边都要留着，并说清缺什么限定，不合成一致意见（MC-58）。
@MainActor
final class MeetingActionLifecycleTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-lifecycle-\(UUID().uuidString)", isDirectory: true)
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
        var actionItemIDs: [String]
        var decisionItemIDs: [String]
    }

    /// 造一场会并整理出一版纪要。
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
            sessionID: record.id, documentID: documentID, snapshotID: snapshotID,
            minutesID: minutesID,
            actionItemIDs: [], decisionItemIDs: []
        )
    }

    /// 写一版纪要（首次整理和重新生成走的是同一条路）。
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
        var candidate = MinutesCandidateV2(title: title, overview: [], decisions: [], actions: [], openQuestions: [], confidenceNotes: "")
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
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 20, snapshotID: snapshotID)
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

    private func itemIDs(minutesID: String, kind: String) async throws -> [String] {
        try await requireStore().minutesItems(minutesID: minutesID).filter { $0.kind == kind }.map(\.id)
    }

    /// `XCTUnwrap` 的自动闭包里不能 await，所以在这里面做断言。
    private func itemID(minutesID: String, kind: String, at index: Int = 0) async throws -> String {
        let ids = try await itemIDs(minutesID: minutesID, kind: kind)
        guard ids.indices.contains(index) else {
            XCTFail("这一版里没有第 \(index) 条 \(kind)")
            throw XCTSkip("缺少条目")
        }
        return ids[index]
    }

    // MARK: - MC-53：重新生成不重置用户状态，也不复活已完成任务

    func testRegeneratingKeepsTheDoneState() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let firstItem = try await itemID(minutesID: meeting.minutesID, kind: "action")

        try await store.recordExecutionEvent(
            itemID: firstItem, status: .done, validFrom: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let beforeRegeneration = try await store.executionState(itemID: firstItem)
        XCTAssertEqual(beforeRegeneration?.status, .done)

        // 同一场会、同样的一条行动，重新生成一版。
        let second = try await writeMinutesVersion(
            sessionID: meeting.sessionID, snapshotID: meeting.snapshotID,
            title: "发布评审", actions: ["整理发布清单"], decisions: []
        )
        XCTAssertNotEqual(second, meeting.minutesID, "确实写出了新的一版")
        let secondItem = try await itemID(minutesID: second, kind: "action")
        XCTAssertNotEqual(secondItem, firstItem, "新一版的条目 id 必然不同")

        let afterRegeneration = try await store.executionState(itemID: secondItem)
        XCTAssertEqual(
            afterRegeneration?.status, .done,
            "重新生成不能把用户已经做完的事变回未完成（MC-53）"
        )
    }

    func testRewordedActionDoesNotResurrectTheDoneOne() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let firstItem = try await itemID(minutesID: meeting.minutesID, kind: "action")
        try await store.recordExecutionEvent(itemID: firstItem, status: .done)

        // 重新生成时模型换了说法，还悄悄加了期限。
        let second = try await writeMinutesVersion(
            sessionID: meeting.sessionID, snapshotID: meeting.snapshotID,
            title: "发布评审",
            actions: ["整理并归档发布清单（五月前）"], decisions: []
        )
        let secondItem = try await itemID(minutesID: second, kind: "action")

        let newItemState = try await store.executionState(itemID: secondItem)
        XCTAssertNil(
            newItemState,
            "换了说法就当成新任务，等于把已完成的活儿又发回待办"
        )
        let oldState = try await store.executionState(itemID: firstItem)
        XCTAssertEqual(oldState?.status, .done, "原来的完成状态原样保留")

        let proposals = try await store.knowledgeChangeProposals(documentID: meeting.documentID)
        let reworded = try XCTUnwrap(proposals.first { $0.kind == .reworded })
        XCTAssertEqual(reworded.previousItemID, firstItem)
        XCTAssertEqual(reworded.proposedItemID, secondItem)
        XCTAssertTrue(reworded.requiresUserConfirmation, "建议只是建议，要不要算同一条由用户定")

        // 建议本身**不改任何状态**。
        let stateAfterProposals = try await store.executionState(itemID: secondItem)
        let oldStateAfterProposals = try await store.executionState(itemID: firstItem)
        XCTAssertNil(stateAfterProposals)
        XCTAssertEqual(oldStateAfterProposals?.status, .done)
    }

    func testMissingFromNewVersionIsNotTreatedAsDone() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单", "同步给客户"])
        let kept = try await itemID(minutesID: meeting.minutesID, kind: "action", at: 0)
        let dropped = try await itemID(minutesID: meeting.minutesID, kind: "action", at: 1)
        try await store.recordExecutionEvent(itemID: kept, status: .done)

        _ = try await writeMinutesVersion(
            sessionID: meeting.sessionID, snapshotID: meeting.snapshotID,
            title: "发布评审", actions: ["整理发布清单"], decisions: []
        )

        let proposals = try await store.knowledgeChangeProposals(documentID: meeting.documentID)
        let missing = try XCTUnwrap(proposals.first { $0.kind == .missingFromNewVersion })
        XCTAssertEqual(missing.previousItemID, dropped)
        let droppedState = try await store.executionState(itemID: dropped)
        let keptState = try await store.executionState(itemID: kept)
        XCTAssertNil(
            droppedState,
            "新一版没提到，不等于做完了，也不等于放弃了——不推断"
        )
        XCTAssertEqual(keptState?.status, .done)
    }

    // MARK: - 未知负责人/期限不推断

    func testUnknownOwnerAndDueStayUnknown() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let item = try await itemID(minutesID: meeting.minutesID, kind: "action")

        let event = try await store.recordExecutionEvent(itemID: item, status: .open)
        XCTAssertNil(event.ownerText, "会上没说是谁，就是不知道")
        XCTAssertNil(event.dueText)
        XCTAssertNil(event.dueDate)

        let state = try await store.executionState(itemID: item)
        XCTAssertNil(state?.ownerText)
        XCTAssertNil(state?.dueDate)
    }

    func testSilenceNeverMarksSomethingDone() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let item = try await itemID(minutesID: meeting.minutesID, kind: "action")
        _ = try await store.recordExecutionEvent(itemID: item, status: .open)

        // 过了很久没有任何新消息。
        let later = try await store.executionState(
            itemKey: KnowledgeIdentity.key(
                documentID: meeting.documentID, kind: "action", text: "整理发布清单"
            )
        )
        XCTAssertEqual(later?.status, .open, "没有消息就是没有消息，不因沉默变已完成（MC-59）")
    }

    // MARK: - MC-59：日期更新不改变历史承诺

    func testDueDateChangeDoesNotRewriteTheEarlierCommitment() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let item = try await itemID(minutesID: meeting.minutesID, kind: "action")
        let key = KnowledgeIdentity.key(documentID: meeting.documentID, kind: "action", text: "整理发布清单")

        let march = Date(timeIntervalSince1970: 1_700_000_000)
        let april = Date(timeIntervalSince1970: 1_700_086_400)
        _ = try await store.recordExecutionEvent(
            itemID: item, status: .open, dueText: "三月前", dueDate: march, validFrom: march
        )
        _ = try await store.recordExecutionEvent(
            itemID: item, status: .open, dueText: "五月前", validFrom: april
        )

        let now = try await store.executionState(itemKey: key)
        XCTAssertEqual(now?.dueText, "五月前", "当前状态取最新")

        let then = try await store.executionState(itemKey: key, asOfValidTime: march)
        XCTAssertEqual(
            then?.dueText, "三月前",
            "期限改了不等于过去的承诺被改写（MC-59）"
        )

        let timeline = try await store.executionEvents(itemKey: key)
        XCTAssertEqual(timeline.count, 2, "旧事件一直在日志里，没有被覆盖")
        XCTAssertEqual(timeline[0].dueText, "三月前", "三月那条仍能读出来")
        XCTAssertNotNil(timeline[0].validTo, "被后一条取代的时刻要记下来")
        XCTAssertNil(timeline[1].validTo, "最新一条仍然有效")
    }

    func testBackdatedEntryDoesNotOverrideTheCurrentState() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单"])
        let item = try await itemID(minutesID: meeting.minutesID, kind: "action")
        let key = KnowledgeIdentity.key(documentID: meeting.documentID, kind: "action", text: "整理发布清单")

        let march = Date(timeIntervalSince1970: 1_700_000_000)
        let may = Date(timeIntervalSince1970: 1_700_200_000)
        _ = try await store.recordExecutionEvent(itemID: item, status: .open, validFrom: may)
        _ = try await store.recordExecutionEvent(
            itemID: item, status: .blocked, validFrom: march,
            note: "补记：当时就说做不了"
        )

        let current = try await store.executionState(itemKey: key)
        let thenState = try await store.executionState(itemKey: key, asOfValidTime: march)
        XCTAssertEqual(
            current?.status, .open,
            "补记一条更早的事，不该把现在的状态改掉"
        )
        XCTAssertEqual(
            thenState?.status, .blocked,
            "按有效时间读，三月那一刻确实是受阻的"
        )
    }

    // MARK: - MC-57：跨会议替代要有依据

    func testSupersessionNeedsEvidenceOrUserConfirmation() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = try await makeMeeting(
            title: "发布评审", projectID: "p",
            actions: ["整理发布清单", "同步给客户"], at: base
        )
        let newer = try await makeMeeting(
            title: "发布复盘", projectID: "p",
            actions: ["整理发布清单", "同步给客户"], at: base.addingTimeInterval(86_400)
        )
        let from = try await itemID(minutesID: older.minutesID, kind: "action")
        let to = try await itemID(minutesID: newer.minutesID, kind: "action")
        let otherFrom = try await itemID(minutesID: older.minutesID, kind: "action", at: 1)
        let otherTo = try await itemID(minutesID: newer.minutesID, kind: "action", at: 1)

        // 按证据：必须真的挂得上证据。
        do {
            _ = try await store.confirmSupersession(
                fromItemID: from, toItemID: to, basis: .evidence, evidenceItemIDs: []
            )
            XCTFail("没有证据就不能说「有证据」")
        } catch {}
        do {
            _ = try await store.confirmSupersession(
                fromItemID: from, toItemID: to, basis: .evidence, evidenceItemIDs: ["查无此条"]
            )
            XCTFail("证据 id 对不上任何条目，不算数")
        } catch {}

        let confirmed = try await store.confirmSupersession(
            fromItemID: from, toItemID: to, basis: .evidence, evidenceItemIDs: [to]
        )
        XCTAssertEqual(confirmed.basis, .evidence)
        XCTAssertEqual(confirmed.evidenceItemIDs, [to])

        // 按用户确认：不需要证据。
        let byUser = try await store.confirmSupersession(
            fromItemID: otherFrom, toItemID: otherTo, basis: .userConfirmed
        )
        XCTAssertEqual(byUser.basis, .userConfirmed)
        XCTAssertTrue(byUser.evidenceItemIDs.isEmpty)

        let firstKey = KnowledgeIdentity.key(
            documentID: newer.documentID, kind: "action", text: "整理发布清单"
        )
        let secondKey = KnowledgeIdentity.key(
            documentID: newer.documentID, kind: "action", text: "同步给客户"
        )
        let related = try await store.supersessions(itemKey: firstKey)
        let alsoRelated = try await store.supersessions(itemKey: secondKey)
        XCTAssertEqual(related.count, 1)
        XCTAssertEqual(alsoRelated.count, 1)
        XCTAssertEqual(related.first?.basis, .evidence)
        XCTAssertEqual(alsoRelated.first?.basis, .userConfirmed)
    }

    func testSupersessionRefusesWithinTheSameMeeting() async throws {
        let store = try requireStore()
        let meeting = try await makeMeeting(title: "发布评审", actions: ["整理发布清单", "整理归档清单"])
        let first = try await itemID(minutesID: meeting.minutesID, kind: "action", at: 0)
        let second = try await itemID(minutesID: meeting.minutesID, kind: "action", at: 1)
        do {
            _ = try await store.confirmSupersession(
                fromItemID: first, toItemID: second, basis: .userConfirmed
            )
            XCTFail("同一场会内重新生成不靠替代关系表达")
        } catch {}
    }

    func testSupersessionRefusesAcrossDifferentKinds() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = try await makeMeeting(title: "A", projectID: "p", actions: ["结论"], at: base)
        let newer = try await makeMeeting(
            title: "B", projectID: "p", actions: [],
            decisions: ["结论"], at: base.addingTimeInterval(86_400)
        )
        let action = try await itemID(minutesID: older.minutesID, kind: "action")
        let decision = try await itemID(minutesID: newer.minutesID, kind: "decision")
        do {
            _ = try await store.confirmSupersession(
                fromItemID: action, toItemID: decision, basis: .userConfirmed
            )
            XCTFail("行动不能被一条结论替代")
        } catch {}
    }

    // MARK: - MC-58：结论相反时两边都留着

    func testOppositeDecisionsAreBothKeptAndQualifiersAreNamed() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await makeMeeting(
            title: "发布评审", projectID: "p",
            actions: [], decisions: ["发布窗口定在九月"], at: base
        )
        _ = try await makeMeeting(
            title: "发布复盘", projectID: "p",
            actions: [], decisions: ["发布窗口改到十月"], at: base.addingTimeInterval(86_400)
        )

        let conflicts = try await store.conflictingDecisions(
            scope: MeetingKnowledgeScope(projectID: "p")
        )
        let conflict = try XCTUnwrap(conflicts.first { $0.kind == .conflictAcrossMeetings })
        XCTAssertTrue(conflict.requiresUserConfirmation)
        XCTAssertNotNil(conflict.previousItemID)
        XCTAssertNotNil(conflict.proposedItemID)
        XCTAssertNotNil(conflict.previousText, "前一场的说法要留着")
        XCTAssertNotNil(conflict.proposedText, "后一场的说法也要留着")
        XCTAssertNotNil(conflict.detail)

        // 两条都还在库里，谁也没被合掉。
        let decisions = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(projectIDs: ["p"], kinds: ["decision"])
        )
        XCTAssertEqual(decisions.counts.total, 2, "两条结论都在，不合成一条")
    }

    func testSameDecisionInTwoMeetingsIsNotAConflict() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await makeMeeting(
            title: "发布评审", projectID: "p", actions: [], decisions: ["发布窗口定在九月"], at: base
        )
        _ = try await makeMeeting(
            title: "发布复盘", projectID: "p", actions: [], decisions: ["发布窗口定在九月"],
            at: base.addingTimeInterval(86_400)
        )
        let conflicts = try await store.conflictingDecisions(
            scope: MeetingKnowledgeScope(projectID: "p")
        )
        XCTAssertTrue(conflicts.isEmpty, "说法一致的重复记录不是冲突")
    }
}
