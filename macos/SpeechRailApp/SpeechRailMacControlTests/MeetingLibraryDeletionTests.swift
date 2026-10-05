import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 知识库的归档与删除入口（方案 MA-18 / MC-43、MC-44、MC-62、MC-72；验收标准 4）。
///
/// 这一层此前**只有库、没有路**：`deleteMeetingKnowledge` 与 `markedForReview`
/// 都做在 `SessionStore` 里，而界面只依赖协调器、协调器又没有透传，
/// 所以用户根本删不掉任何东西——「删除内容不得被索引或旧任务恢复」在数据层成立，
/// 在产品上却无从触发。这轮补的就是从界面到它的那条路，以及路上的三件事：
///
/// - 三档后果不同，所以三档都摆出来，**只有不可撤销的那档要确认**；
/// - 归档默认从列表消失，但用户必须能把它摆回来撤销，否则「可撤销」是空话；
/// - 删除之后关掉正开着的那一场详情，并给一句**说清还剩什么**的回执。
@MainActor
final class MeetingLibraryDeletionTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var coordinator: SessionCoordinator?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-deletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "meeting-deletion-\(UUID().uuidString)"))
        self.directory = directory
        self.store = store
        self.coordinator = SessionCoordinator(store: store, defaults: defaults)
    }

    override func tearDown() async throws {
        if let store { await store.close() }
        store = nil
        coordinator = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func requireCoordinator() throws -> SessionCoordinator { try XCTUnwrap(coordinator) }

    private func requireStore() throws -> SessionStore { try XCTUnwrap(store) }

    /// 造一场带转录与纪要的会，产出可直接归档/删除的文档 id。
    @discardableResult
    private func makeMeeting(title: String) async throws -> String {
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
        let sealed = try await store.sealMeetingSource(sessionID: record.id)
        let snapshotID = try XCTUnwrap(sealed?.id)
        let existing = try await store.meetingDocument(forSessionID: record.id)
        let document = try XCTUnwrap(existing?.id)
        try await store.updateMeetingDocument(
            id: document, title: .some(title), projectID: .some(nil), occurredAt: .some(Date())
        )
        let units = [MinutesSourceUnit(
            id: "u1", lineID: "\(record.id)-line", ordinal: 1,
            speaker: "张三", text: "先确认这几点。", startSeconds: 0
        )]
        var candidate = MinutesCandidateV2(
            title: title, overview: [], decisions: [], actions: [],
            openQuestions: [], confidenceNotes: ""
        )
        candidate.actions.append(.init(
            localID: "a0", task: "整理发布清单", ownerText: nil,
            dueExpression: nil, commitment: .proposed, sourceUnitIDs: ["u1"]
        ))
        let encoded = try JSONEncoder().encode(candidate)
        guard case .prepared(let prepared) = MinutesCandidateCodec.prepare(
            text: String(data: encoded, encoding: .utf8) ?? "", units: units
        ) else {
            throw XCTSkip("候选构造失败")
        }
        _ = try await store.enqueueMinutes(sessionID: record.id, model: nil, promptChars: 20, snapshotID: snapshotID)
        let claimed = try await store.claimMinutes(sessionID: record.id, lease: 600)
        let row = try XCTUnwrap(claimed)
        let revisionIDs = try await store.latestRevisionIDsByLine(sessionID: record.id)
        let saved = try await store.saveMinutesCandidate(
            minutesID: row.id, expectedAttempts: row.attempts,
            body: prepared.body, model: nil,
            candidate: String(data: try JSONEncoder().encode(prepared.candidate), encoding: .utf8),
            review: String(data: try JSONEncoder().encode(prepared.report), encoding: .utf8),
            items: MinutesCandidateCodec.itemDrafts(
                for: prepared.candidate, report: prepared.report,
                unitsByID: ["u1": units[0]], revisionIDsByLine: revisionIDs
            ),
            snapshotID: snapshotID
        )
        XCTAssertTrue(saved)
        return document
    }

    // MARK: - 确认口径

    /// 判据是**可逆性**，不是"这一场还在不在列表里"。
    ///
    /// 移除转录之后这一场照样列得出来、详情也读得到，但它把完整转录永久删掉了——
    /// 单向门就该问一句。域模型已经用 `isRecoverable` 表达了这件事，
    /// 这里不该另立一套按可见性算的规矩。
    func testOnlyTheIrreversibleModeAsksForConfirmation() {
        XCTAssertFalse(MeetingLibraryModel.requiresConfirmation(.archive))
        XCTAssertTrue(
            MeetingLibraryModel.requiresConfirmation(.removeTranscript),
            "移除完整转录不可逆，该问一句"
        )
        XCTAssertTrue(MeetingLibraryModel.requiresConfirmation(.deleteEverything))
    }

    // MARK: - 归档与撤销

    /// 归档之后默认列表里看不到它，但用户能把它摆回来撤销——数据一行不少。
    func testArchiveHidesTheMeetingAndStaysRecoverable() async throws {
        let coordinator = try requireCoordinator()
        let document = try await makeMeeting(title: "发布评审")
        let model = MeetingLibraryModel(coordinator: coordinator)
        await model.loadPage(offset: 0)
        XCTAssertEqual(model.rows.count, 1)

        await model.delete(document, mode: .archive)
        XCTAssertNotNil(model.lastReport, "归档要给出回执")
        XCTAssertEqual(model.rows.count, 0, "归档件默认不列——归档的意义就是搜索与导出都看不见它")

        await model.setIncludesArchived(true)
        XCTAssertEqual(model.rows.count, 1, "但用户必须能把它摆回来，否则「可撤销」是空话")

        let restored = await model.restore(document)
        XCTAssertTrue(restored)
        await model.setIncludesArchived(false)
        XCTAssertEqual(model.rows.count, 1, "撤销之后它回到默认列表")
    }

    /// 撤一个不是归档态的文档要说清"撤不了"，不能假装成功。
    func testRestoringSomethingThatIsNotArchivedSaysSo() async throws {
        let coordinator = try requireCoordinator()
        let document = try await makeMeeting(title: "发布评审")
        let model = MeetingLibraryModel(coordinator: coordinator)

        let restored = await model.restore(document)
        XCTAssertFalse(restored)
        XCTAssertEqual(model.lastRestore, false)
        XCTAssertNil(model.archiveError, "这不是错误，是一个如实的否定回答")
    }

    // MARK: - 移除转录：结论留下但不再自称已核对

    /// 验收标准 4 的核心那条：移除来源后，依赖它的结论**不得继续自称逐字命中**，
    /// 而是要被标成需要用户再看一眼。
    func testRemovingTranscriptKeepsConclusionsButMarksThemForReview() async throws {
        let coordinator = try requireCoordinator()
        let document = try await makeMeeting(title: "发布评审")
        let model = MeetingLibraryModel(coordinator: coordinator)

        await model.delete(document, mode: .removeTranscript)
        let report = try XCTUnwrap(model.lastReport)
        XCTAssertGreaterThan(report.removedLines, 0, "完整转录确实被移除了")
        XCTAssertEqual(report.removedMinutes, 0, "纪要留着——这是这一档与完整删除的区别")
        XCTAssertGreaterThan(report.markedForReview, 0, "引用被删来源的结论必须降级为待复核")

        let summary = MeetingLibraryModel.summary(for: report)
        XCTAssertTrue(summary.contains("不再自称已核对"), "回执要说清哪些结论要用户自己再看一眼：\(summary)")
        XCTAssertTrue(summary.contains("读不到"), "回执要说清原句已经读不到了：\(summary)")
    }

    /// 完整删除：什么都别留，而且回执要**列出来**分别删了多少。
    func testDeletingEverythingReportsWhatItRemoved() async throws {
        let coordinator = try requireCoordinator()
        let document = try await makeMeeting(title: "发布评审")
        let model = MeetingLibraryModel(coordinator: coordinator)

        await model.delete(document, mode: .deleteEverything)
        let report = try XCTUnwrap(model.lastReport)
        XCTAssertGreaterThan(report.removedLines, 0)
        XCTAssertGreaterThan(report.removedMinutes, 0, "纪要也在这一档里被删")

        let summary = MeetingLibraryModel.summary(for: report)
        XCTAssertTrue(summary.contains("不能撤销"), "不可撤销这件事要在文案里说：\(summary)")
        XCTAssertTrue(summary.contains("纪要"), "要说清分别删了多少：\(summary)")
        XCTAssertFalse(
            MeetingLibraryModel.requiresConfirmation(.archive)
                && summary.contains("不能撤销"),
            "归档是可撤销的，回执不许出现「不能撤销」"
        )
    }

    // MARK: - 详情与失败

    /// 删掉正在看的那一场之后，详情必须关上：留着会让人对着一个已经不参与
    /// 检索与导出的会议读纪要。
    func testDeletingClosesTheDetailThatWasOpenOnThatMeeting() async throws {
        let coordinator = try requireCoordinator()
        let document = try await makeMeeting(title: "发布评审")
        let model = MeetingLibraryModel(coordinator: coordinator)
        await model.open(documentID: document)
        XCTAssertNotNil(model.snapshot)

        await model.delete(document, mode: .deleteEverything)
        XCTAssertNil(model.snapshot, "刚被删的那一场不该还开着详情")
        XCTAssertNil(model.selectedDocumentID)
    }

    /// 删一个不存在的文档：失败要**说出来**，库里其余内容照旧。
    /// 静默失败会让用户以为删掉了，而东西还在。
    func testFailingToDeleteSaysSoAndLeavesTheRestAlone() async throws {
        let coordinator = try requireCoordinator()
        _ = try await makeMeeting(title: "发布评审")
        let model = MeetingLibraryModel(coordinator: coordinator)
        await model.loadPage(offset: 0)
        XCTAssertEqual(model.rows.count, 1)

        await model.delete("根本没有这个文档", mode: .deleteEverything)
        XCTAssertNotNil(model.archiveError, "失败要有可读结论")
        XCTAssertNil(model.lastReport, "失败不得同时报成功")
        XCTAssertNil(model.pendingDocumentID, "失败之后不能卡在「执行中」")
        XCTAssertEqual(model.rows.count, 1, "失败的删除不得牵连其它会议")
    }
}
