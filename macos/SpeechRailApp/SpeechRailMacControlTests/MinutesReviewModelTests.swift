import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 纪要核对的编辑状态（方案 MA-11 / MC-47、MC-73）。
///
/// 这里钉的是两件用户会**直接损失内容**或**误触破坏性动作**的事：
/// - 存不上的时候草稿一个字都不能丢（MC-47）；
/// - 中文输入法组字时按回车是**选词**，不是保存、不是采用（MC-73）。
@MainActor
final class MinutesReviewModelTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var coordinator: SessionCoordinator?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "review-model-\(UUID().uuidString)"))
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

    private func requireStore() throws -> SessionStore { try XCTUnwrap(store) }
    private func requireCoordinator() throws -> SessionCoordinator { try XCTUnwrap(coordinator) }

    /// 造一场会并整理出一版纪要。
    private func makeVersion(body: String = "# 发布评审\n\n发布窗口定在九月。\n") async throws -> (sessionID: String, minutesID: String) {
        let store = try requireStore()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone, title: "发布评审")
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
        let units = [MinutesSourceUnit(
            id: "u1", lineID: "\(record.id)-line", ordinal: 1,
            speaker: "张三", text: "先确认这几点。", startSeconds: 0
        )]
        var candidate = MinutesCandidateV2(
            title: "发布评审", overview: [], decisions: [], actions: [], openQuestions: [], confidenceNotes: ""
        )
        candidate.decisions.append(.init(
            localID: "d0", text: "发布窗口定在九月", modality: .decided, conditions: [], sourceUnitIDs: ["u1"]
        ))
        let encoded = try JSONEncoder().encode(candidate)
        guard case .prepared(let prepared) = MinutesCandidateCodec.prepare(
            text: String(data: encoded, encoding: .utf8) ?? "", units: units
        ) else {
            throw XCTSkip("候选构造失败")
        }
        _ = try await store.enqueueMinutes(sessionID: record.id, model: "test-model", promptChars: 20, snapshotID: snapshotID)
        let claimed = try await store.claimMinutes(sessionID: record.id, lease: 600)
        let row = try XCTUnwrap(claimed)
        let revisionIDs = try await store.latestRevisionIDsByLine(sessionID: record.id)
        let saved = try await store.saveMinutesCandidate(
            minutesID: row.id, expectedAttempts: row.attempts,
            body: body, model: "test-model",
            candidate: String(data: try JSONEncoder().encode(prepared.candidate), encoding: .utf8),
            review: String(data: try JSONEncoder().encode(prepared.report), encoding: .utf8),
            items: MinutesCandidateCodec.itemDrafts(
                for: prepared.candidate, report: prepared.report,
                unitsByID: ["u1": units[0]], revisionIDsByLine: revisionIDs
            ),
            snapshotID: snapshotID
        )
        XCTAssertTrue(saved)
        return (record.id, row.id)
    }

    /// 造一个核对模型。`XCTUnwrap` 的自动闭包里不能 await，所以在这里面做断言。
    private func makeModel(sessionID: String, minutesID: String) async throws -> MinutesReviewModel {
        let loaded = try await requireStore().minutesVersion(id: minutesID)
        let version = try XCTUnwrap(loaded)
        return MinutesReviewModel(
            coordinator: try requireCoordinator(), sessionID: sessionID, version: version
        )
    }

    // MARK: - MC-47：存不上也要留住草稿

    func testSavingSucceedsAndClearsTheFailureState() async throws {
        let store = try requireStore()
        let made = try await makeVersion()
        let model = try await makeModel(sessionID: made.sessionID, minutesID: made.minutesID)

        model.update("# 发布评审\n\n发布窗口改到十月。\n")
        XCTAssertTrue(model.hasUnsavedChanges)

        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertNil(model.saveFailure)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(model.draft, "# 发布评审\n\n发布窗口改到十月。\n", "成功后草稿原样保留，不被刷新成别的内容")
        XCTAssertEqual(model.bodyOrigin, .userEdited)
        XCTAssertTrue(model.originChanged, "出处变了要告诉界面")
        XCTAssertTrue(model.originSummary.contains("你改过"))
    }

    func testDraftSurvivesAFailedSave() async throws {
        let store = try requireStore()
        let made = try await makeVersion()
        // 归档之后再改：写入会被拒绝，这正是"磁盘写不进去"的等价情形。
        let existing = try await store.meetingDocument(forSessionID: made.sessionID)
        let documentID = try XCTUnwrap(existing?.id)
        _ = try await store.deleteMeetingKnowledge(documentID: documentID, mode: .archive)

        let model = try await makeModel(sessionID: made.sessionID, minutesID: made.minutesID)
        let typed = "# 发布评审\n\n用户写了很长一段，没存上。\n"
        model.update(typed)

        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.draft, typed, "存不上的时候草稿一个字都不能丢（MC-47）")
        XCTAssertNotNil(model.saveFailure, "要告诉用户没存上")
        XCTAssertTrue(model.hasUnsavedChanges, "还有改动没存，界面不能显示成已保存")
        XCTAssertFalse(model.isSaving)
    }

    func testFailedSaveDoesNotCorruptTheSuccessfulBaseline() async throws {
        let store = try requireStore()
        let made = try await makeVersion()
        let model = try await makeModel(sessionID: made.sessionID, minutesID: made.minutesID)
        let sourceVersion = try await store.minutesVersion(id: made.minutesID)
        let original = try XCTUnwrap(sourceVersion).body ?? ""

        model.update("改了一次")
        let savedFirst = await model.save()
        XCTAssertTrue(savedFirst)

        let existing = try await store.meetingDocument(forSessionID: made.sessionID)
        let documentID = try XCTUnwrap(existing?.id)
        _ = try await store.deleteMeetingKnowledge(documentID: documentID, mode: .archive)

        model.update("改第二次")
        let savedSecond = await model.save()
        XCTAssertFalse(savedSecond, "第二次存不进去")

        // 撤销要回到**上一次成功存进去的**内容，不是回到 AI 原文，更不是回到空。
        model.revertToLastSaved()
        XCTAssertEqual(model.draft, "改了一次")
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.saveFailure)
        XCTAssertEqual(model.lastSavedBody, "改了一次")
        XCTAssertNotEqual(model.lastSavedBody, original)
    }

    func testRevertRestoresTheModeledTextBeforeAnySave() async throws {
        let store = try requireStore()
        let made = try await makeVersion()
        let model = try await makeModel(sessionID: made.sessionID, minutesID: made.minutesID)
        model.update("写了又删")
        model.revertToLastSaved()
        let sourceVersion = try await store.minutesVersion(id: made.minutesID)
        XCTAssertEqual(model.draft, sourceVersion?.body)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testSavingAnUnchangedDraftIsANoOp() async throws {
        let store = try requireStore()
        let made = try await makeVersion()
        let model = try await makeModel(sessionID: made.sessionID, minutesID: made.minutesID)

        let versionsBefore = try await store.minutesVersions(sessionID: made.sessionID)
        let saved = await model.save()
        XCTAssertTrue(saved, "没改过就不必再写一版")
        let versionsAfter = try await store.minutesVersions(sessionID: made.sessionID)
        XCTAssertEqual(versionsBefore.count, versionsAfter.count, "没改就不产生新版本")
    }

    func testSecondSaveEditsTheVersionTheFirstSaveProduced() async throws {
        let store = try requireStore()
        let made = try await makeVersion()
        let model = try await makeModel(sessionID: made.sessionID, minutesID: made.minutesID)

        model.update("第一次改")
        let savedFirst = await model.save()
        XCTAssertTrue(savedFirst)
        let afterFirst = model.minutesID

        model.update("第二次改")
        let savedAgain = await model.save()
        XCTAssertTrue(savedAgain)
        XCTAssertNotEqual(model.minutesID, afterFirst)

        let lineage = try await store.minutesEditLineage(minutesID: model.minutesID)
        XCTAssertEqual(lineage.count, 3, "第一版 + 两次改动，血缘连得上")
        XCTAssertEqual(lineage.last?.body, "第二次改")
    }

    // MARK: - MC-73：快捷键不穿透输入

    func testSessionShortcutsAreSuppressedWhileTyping() {
        XCTAssertTrue(ReviewShortcutPolicy.suppressesSessionShortcuts(isTextInputFocused: true))
        XCTAssertFalse(ReviewShortcutPolicy.suppressesSessionShortcuts(isTextInputFocused: false))
    }

    func testEnterDuringCompositionIsWordSelectionNotSubmit() {
        // 中文输入法组字中：这一下回车是选词，既不提交也不弹确认。
        XCTAssertFalse(ReviewShortcutPolicy.shouldSubmit(isComposing: true))
        XCTAssertFalse(ReviewShortcutPolicy.shouldPresentConfirm(isComposing: true))
        XCTAssertTrue(ReviewShortcutPolicy.shouldSubmit(isComposing: false))
        XCTAssertTrue(ReviewShortcutPolicy.shouldPresentConfirm(isComposing: false))
    }
}
