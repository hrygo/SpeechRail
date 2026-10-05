import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 跨会议复用（MA-14 / MC-57、MC-58）。
///
/// 这一段检验的是闭环的最后一环：**两场会说的话对不上时，系统该怎么办**。
/// 唯一被允许的答案是"把矛盾摆出来、说清缺什么限定、让用户定"——
/// 自己合成一句一致意见，就是把两场会的分歧用一句没人说过的话盖掉。
@MainActor
final class MeetingCrossMeetingTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var coordinator: SessionCoordinator?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-cross-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "meeting-cross-\(UUID().uuidString)"))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        self.directory = directory
        self.store = store
        self.coordinator = coordinator
    }

    override func tearDown() async throws {
        if let store { await store.close() }
        store = nil
        coordinator = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func requireStore() throws -> SessionStore { try XCTUnwrap(store) }
    private func requireCoordinator() throws -> SessionCoordinator { try XCTUnwrap(coordinator) }

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
        decisions: [String],
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
            sessionID: record.id, snapshotID: snapshotID, title: title, decisions: decisions
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

    private func decisionIDs(minutesID: String) async throws -> [String] {
        try await requireStore().minutesItems(minutesID: minutesID)
            .filter { $0.kind == "decision" }.map(\.id)
    }

    /// 两场会关于同一件事给了不同说法。
    private func makeConflictingPair(projectID: String = "p") async throws -> (first: Meeting, second: Meeting) {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await makeMeeting(
            title: "发布评审", projectID: projectID,
            decisions: ["发布窗口定在九月"], at: base
        )
        let second = try await makeMeeting(
            title: "发布复盘", projectID: projectID,
            decisions: ["发布窗口改到十月"], at: base.addingTimeInterval(86_400)
        )
        return (first, second)
    }

    // MARK: - MC-58：两边都留着，说清缺什么限定

    func testConflictingDecisionsShowBothSidesAndSayWhatIsMissing() async throws {
        let store = try requireStore()
        _ = try await makeConflictingPair()

        let conflicts = try await store.conflictingDecisions(
            scope: MeetingKnowledgeScope(projectID: "p")
        )
        let conflict = try XCTUnwrap(
            conflicts.first { $0.kind == .conflictAcrossMeetings },
            "两场会说法相反却不报出来，用户就永远不知道自己踩在分歧上"
        )
        XCTAssertEqual(conflict.previousText, "发布窗口定在九月", "前一场的说法要留着")
        XCTAssertEqual(conflict.proposedText, "发布窗口改到十月", "后一场的说法也要留着")
        let detail = try XCTUnwrap(conflict.detail)
        XCTAssertFalse(detail.isEmpty, "必须说清缺了什么限定，而不是替用户选一个")
        XCTAssertTrue(conflict.requiresUserConfirmation)
    }

    /// 说法一致的重复记录不是分歧，硬报出来只是噪声。
    func testSameDecisionInTwoMeetingsIsNotAConflict() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await makeMeeting(
            title: "发布评审", projectID: "p", decisions: ["发布窗口定在九月"], at: base
        )
        _ = try await makeMeeting(
            title: "发布复盘", projectID: "p", decisions: ["发布窗口定在九月"],
            at: base.addingTimeInterval(86_400)
        )
        let conflicts = try await store.conflictingDecisions(
            scope: MeetingKnowledgeScope(projectID: "p")
        )
        XCTAssertTrue(conflicts.isEmpty, "一致的重复记录不是冲突")
    }

    /// 范围跟着当前筛选走，否则标题写"3 处冲突"而用户只选了一个项目。
    func testConflictsFollowTheScope() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await makeMeeting(
            title: "A 场", projectID: "p1", decisions: ["发布窗口定在九月"], at: base
        )
        _ = try await makeMeeting(
            title: "B 场", projectID: "p1", decisions: ["发布窗口改到十月"],
            at: base.addingTimeInterval(86_400)
        )
        _ = try await makeMeeting(
            title: "C 场", projectID: "p2", decisions: ["发布窗口定在九月"], at: base
        )
        _ = try await makeMeeting(
            title: "D 场", projectID: "p2", decisions: ["发布窗口改到十月"],
            at: base.addingTimeInterval(86_400)
        )

        let all = try await store.conflictingDecisions()
        let onlyP1 = try await store.conflictingDecisions(scope: MeetingKnowledgeScope(projectID: "p1"))
        let onlyP2 = try await store.conflictingDecisions(scope: MeetingKnowledgeScope(projectID: "p2"))
        XCTAssertFalse(all.isEmpty)
        XCTAssertFalse(onlyP1.isEmpty)
        XCTAssertFalse(onlyP2.isEmpty)
        for conflict in all {
            XCTAssertTrue(
                conflict.summary.contains("发布") || conflict.summary.contains("窗口"),
                "冲突摘要要指向真正分歧的那个词"
            )
        }
    }

    // MARK: - MC-57：确认替代之后，不该再拿同一条来烦用户

    /// 用户点过「后一条取代前一条」，下一次打开还看到同一条候选，
    /// 只会让人怀疑上一步到底有没有生效。
    func testConfirmedSupersessionStopsBeingOfferedAgain() async throws {
        let store = try requireStore()
        let pair = try await makeConflictingPair()
        let before = try await store.conflictingDecisions(scope: MeetingKnowledgeScope(projectID: "p"))
        let candidate = try XCTUnwrap(before.first { $0.kind == .conflictAcrossMeetings })
        let previousID = try XCTUnwrap(candidate.previousItemID)
        let proposedID = try XCTUnwrap(candidate.proposedItemID)

        try await store.confirmSupersession(
            fromItemID: previousID, toItemID: proposedID, basis: .userConfirmed
        )

        let after = try await store.conflictingDecisions(scope: MeetingKnowledgeScope(projectID: "p"))
        XCTAssertTrue(
            after.allSatisfy { $0.previousItemID != previousID || $0.proposedItemID != proposedID },
            "已经确认过替代的两边不该再作为候选反复出现"
        )
    }

    /// 反过来也要成立：没确认过的另一对仍然照报，不能因为过滤过头把真分歧藏了。
    func testUnrelatedConflictIsStillReportedAfterResolvingAnother() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await makeMeeting(
            title: "A 场", projectID: "p", decisions: ["发布窗口定在九月"], at: base
        )
        let second = try await makeMeeting(
            title: "B 场", projectID: "p", decisions: ["发布窗口改到十月"],
            at: base.addingTimeInterval(86_400)
        )
        let third = try await makeMeeting(
            title: "C 场", projectID: "p", decisions: ["预算上限定在五十万"],
            at: base.addingTimeInterval(172_800)
        )
        let fourth = try await makeMeeting(
            title: "D 场", projectID: "p", decisions: ["预算上限改到八十万"],
            at: base.addingTimeInterval(259_200)
        )

        let allConflicts = try await store.conflictingDecisions(scope: MeetingKnowledgeScope(projectID: "p"))
        let windowConflict = try XCTUnwrap(
            allConflicts.first { $0.previousText?.contains("发布窗口") == true }
        )
        try await store.confirmSupersession(
            fromItemID: try XCTUnwrap(windowConflict.previousItemID),
            toItemID: try XCTUnwrap(windowConflict.proposedItemID),
            basis: .userConfirmed
        )

        let remaining = try await store.conflictingDecisions(scope: MeetingKnowledgeScope(projectID: "p"))
        XCTAssertTrue(
            remaining.contains {
                $0.previousText == "预算上限定在五十万" && $0.proposedText == "预算上限改到八十万"
            },
            "解决了一处冲突不该把另一处一起藏了"
        )
        XCTAssertFalse(
            remaining.contains {
                $0.previousText == "发布窗口定在九月" && $0.proposedText == "发布窗口改到十月"
            },
            "已确认替代的那对不该还在"
        )
        _ = (first, second, third, fourth)
    }

    /// 替代关系要真的落库，而且记的是稳定 key——纪要重新生成后仍然成立。
    func testSupersessionSurvivesMinutesRegeneration() async throws {
        let store = try requireStore()
        let pair = try await makeConflictingPair()
        let conflicts = try await store.conflictingDecisions(scope: MeetingKnowledgeScope(projectID: "p"))
        let candidate = try XCTUnwrap(conflicts.first)
        try await store.confirmSupersession(
            fromItemID: try XCTUnwrap(candidate.previousItemID),
            toItemID: try XCTUnwrap(candidate.proposedItemID),
            basis: .userConfirmed
        )

        // 第二场重新生成一版，条目 id 全变。
        _ = try await writeMinutesVersion(
            sessionID: pair.second.sessionID, snapshotID: pair.second.snapshotID,
            title: "发布复盘", decisions: ["发布窗口改到十月"]
        )
        let newID = try await decisionIDs(minutesID: try await latestMinutesID(for: pair.second)).first
        let key = KnowledgeIdentity.key(
            documentID: pair.second.documentID, kind: "decision", text: "发布窗口改到十月"
        )
        let supersessions = try await store.supersessions(itemKey: key)
        XCTAssertEqual(supersessions.count, 1, "按稳定 key 找得到，重新生成没有把关系弄丢")
        XCTAssertEqual(supersessions.first?.basis, .userConfirmed)
        _ = newID
    }

    private func latestMinutesID(for meeting: Meeting) async throws -> String {
        let rows = try await requireStore().minutesVersions(sessionID: meeting.sessionID)
            .filter { $0.status == .ready }
            .sorted { $0.version < $1.version }
        return try XCTUnwrap(rows.last?.id)
    }

    // MARK: - 界面上真的够得着

    func testCoordinatorAndModelExposeConflictsAndCanConfirm() async throws {
        let store = try requireStore()
        let pair = try await makeConflictingPair()
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())

        await model.filter(projectID: "p")
        await model.loadConflicts()
        let conflict = try XCTUnwrap(model.conflicts.first)
        XCTAssertEqual(conflict.kind, .conflictAcrossMeetings)
        XCTAssertEqual(conflict.previousText, "发布窗口定在九月")
        XCTAssertEqual(conflict.proposedText, "发布窗口改到十月")
        XCTAssertEqual(model.conflictsHeadline, "跨会议结论冲突（1 处）")

        let ok = await model.confirmSuperseding(conflict)
        XCTAssertTrue(ok)
        XCTAssertTrue(model.conflicts.isEmpty, "确认之后这一处不该还挂在面板上")

        // 真的落库了：按稳定 key 能查到这一条替代关系。
        let key = KnowledgeIdentity.key(
            documentID: pair.second.documentID, kind: "decision", text: "发布窗口改到十月"
        )
        let supersessions = try await store.supersessions(itemKey: key)
        XCTAssertEqual(supersessions.count, 1)
        XCTAssertEqual(supersessions.first?.basis, .userConfirmed)
    }

    /// 确认失败要有话，面板不能悄悄变样。
    func testConfirmFailureIsSurfaced() async throws {
        _ = try await makeConflictingPair()
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadConflicts()

        let broken = KnowledgeChangeProposal(
            kind: .conflictAcrossMeetings,
            summary: "不存在的两条",
            previousItemID: "根本没有这一条",
            proposedItemID: "也没有那一条"
        )
        let ok = await model.confirmSuperseding(broken)
        XCTAssertFalse(ok)
        XCTAssertNotNil(model.conflictWriteError)
        XCTAssertFalse(model.conflicts.isEmpty, "失败时冲突清单保持原样")
    }

    func testEmptyConflictListIsAnHonestZero() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(title: "只有一场", projectID: "p", decisions: ["单独一条结论"])
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadConflicts()
        XCTAssertTrue(model.conflicts.isEmpty)
        XCTAssertEqual(model.conflictsHeadline, "跨会议结论冲突")
        XCTAssertFalse(model.conflictsEmptyHint.isEmpty, "空态要说清为什么空")
    }
}
