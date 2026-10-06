import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 用户编辑纪要（方案 MA-11 / MC-46～MC-48）。
///
/// 这里钉的是**用户已经付出过成本的东西不能丢**：
/// - 改完还能看到 AI 原来写了什么（MC-48）；
/// - 撤销不是删历史，而是把上一版正文再存一版（MC-47）；
/// - 用户自己写的话**不得继承 AI 的引用**——那等于替用户伪造出处；
/// - 正文里删掉的句子，不能在条目里继续留着当"这一版的结论"。
@MainActor
final class MeetingMinutesEditTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-edit-\(UUID().uuidString)", isDirectory: true)
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

    private struct Fixture {
        var sessionID: String
        var documentID: String
        var minutesID: String
        var itemIDs: [String]
    }

    /// 造一场会，纪要里含 `decisions` 与 `actions`，全部有原句引用。
    private func makeMeeting(
        decisions: [String] = [],
        actions: [String] = []
    ) async throws -> Fixture {
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
        let existing = try await store.meetingDocument(forSessionID: record.id)
        let documentID = try XCTUnwrap(existing?.id)

        let units = [MinutesSourceUnit(
            id: "u1", lineID: "\(record.id)-line", ordinal: 1,
            speaker: "张三", text: "先确认这几点。", startSeconds: 0
        )]
        var candidate = MinutesCandidateV2(
            title: "发布评审", overview: [], decisions: [], actions: [], openQuestions: [], confidenceNotes: ""
        )
        for (index, text) in decisions.enumerated() {
            candidate.decisions.append(.init(
                localID: "d\(index)", text: text, modality: .decided, conditions: [], sourceUnitIDs: ["u1"]
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
            throw XCTSkip("候选构造失败")
        }
        _ = try await store.enqueueMinutes(sessionID: record.id, model: "test-model", promptChars: 20, snapshotID: snapshotID)
        let claimed = try await store.claimMinutes(sessionID: record.id, lease: 600)
        let row = try XCTUnwrap(claimed)
        let revisionIDs = try await store.latestRevisionIDsByLine(sessionID: record.id)
        let saved = try await store.saveMinutesCandidate(
            minutesID: row.id, expectedAttempts: row.attempts,
            body: prepared.body, model: "test-model",
            candidate: String(data: try JSONEncoder().encode(prepared.candidate), encoding: .utf8),
            review: String(data: try JSONEncoder().encode(prepared.report), encoding: .utf8),
            items: MinutesCandidateCodec.itemDrafts(
                for: prepared.candidate, report: prepared.report,
                unitsByID: ["u1": units[0]], revisionIDsByLine: revisionIDs
            ),
            snapshotID: snapshotID
        )
        XCTAssertTrue(saved)
        return Fixture(
            sessionID: record.id, documentID: documentID, minutesID: row.id,
            itemIDs: try await store.minutesItems(minutesID: row.id).map(\.id)
        )
    }

    // MARK: - MC-48：改完还能看到 AI 原来写了什么

    func testEditingCreatesANewVersionAndKeepsTheOriginal() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        let loaded = try await store.minutesVersion(id: fixture.minutesID)
        let original = try XCTUnwrap(loaded)

        let edited = try await store.saveUserMinutesEdit(
            sessionID: fixture.sessionID,
            editingMinutesID: fixture.minutesID,
            body: "# 发布评审\n\n发布窗口改到十月。\n"
        )
        XCTAssertNotEqual(edited.id, fixture.minutesID)
        XCTAssertGreaterThan(edited.version, original.version, "用户改动是新版本，不是覆盖")

        let stillLoaded = try await store.minutesVersion(id: fixture.minutesID)
        let stillThere = try XCTUnwrap(stillLoaded)
        XCTAssertEqual(stillThere.body, original.body, "AI 原来那一版一个字都没动（MC-48）")
        XCTAssertEqual(stillThere.bodyOrigin, .ai)

        let versions = try await store.minutesVersions(sessionID: fixture.sessionID)
        XCTAssertEqual(versions.count, 2, "两版都在，看得见改了什么")
    }

    func testEditedVersionIsMarkedAsUserAuthored() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        let edited = try await store.saveUserMinutesEdit(
            sessionID: fixture.sessionID,
            editingMinutesID: fixture.minutesID,
            body: "# 发布评审\n\n发布窗口改到十月。\n"
        )
        XCTAssertEqual(edited.bodyOrigin, .userEdited)
        XCTAssertTrue(edited.bodyOrigin.isUserAuthored)

        // 一个字没改，就仍然是 AI 整理——不因为走了一遍编辑路径就改口。
        let sourceVersion = try await store.minutesVersion(id: fixture.minutesID)
        let untouched = try await store.saveUserMinutesEdit(
            sessionID: fixture.sessionID,
            editingMinutesID: fixture.minutesID,
            body: try XCTUnwrap(sourceVersion).body ?? ""
        )
        XCTAssertEqual(untouched.bodyOrigin, .ai)
    }

    func testEditLineagePointsBackAtTheVersionItEdited() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        let first = try await store.saveUserMinutesEdit(
            sessionID: fixture.sessionID, editingMinutesID: fixture.minutesID,
            body: "# 评审\n\n第一次改。\n"
        )
        let second = try await store.saveUserMinutesEdit(
            sessionID: fixture.sessionID, editingMinutesID: first.id,
            body: "# 评审\n\n第二次改。\n"
        )
        XCTAssertEqual(second.parentMinutesID, first.id)

        let lineage = try await store.minutesEditLineage(minutesID: second.id)
        XCTAssertEqual(lineage.map(\.id), [fixture.minutesID, first.id, second.id], "从第一版一路到当前版")
    }

    // MARK: - 用户新写的句子不继承引用

    func testUserWrittenSentenceInheritsNoCitation() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        let edited = try await store.saveUserMinutesEdit(
            sessionID: fixture.sessionID,
            editingMinutesID: fixture.minutesID,
            body: "# 发布评审\n\n发布窗口定在九月。\n\n补充：客户已经口头同意顺延两周。\n"
        )
        let items = try await store.minutesItems(minutesID: edited.id)
        XCTAssertEqual(items.count, 1, "用户补的那句不该变成一条带引用的结论")
        XCTAssertEqual(items.first?.text, "发布窗口定在九月")

        XCTAssertEqual(items.first?.anchors.count, 1, "没动过的那句，引用照搬")
    }

    func testCarriedOverItemKeepsItsCitation() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(
            decisions: ["发布窗口定在九月"], actions: ["整理发布清单"]
        )
        let edited = try await store.saveUserMinutesEdit(
            sessionID: fixture.sessionID,
            editingMinutesID: fixture.minutesID,
            body: "# 发布评审\n\n这次先不谈窗口。\n\n- 整理发布清单\n"
        )
        let items = try await store.minutesItems(minutesID: edited.id)
        XCTAssertEqual(items.count, 1, "正文里删掉的那句不该继续当这一版的条目")
        XCTAssertEqual(items.first?.text, "整理发布清单")
        XCTAssertEqual(items.first?.kind, "action")

        XCTAssertFalse(items.first?.anchors.isEmpty ?? true, "一字未改的条目，对原句的引用仍然成立")
        XCTAssertEqual(items.first?.anchors.first?.lineID, "\(fixture.sessionID)-line")
    }

    func testRemovedSentenceLeavesNoOrphanItem() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        let edited = try await store.saveUserMinutesEdit(
            sessionID: fixture.sessionID,
            editingMinutesID: fixture.minutesID,
            body: "# 发布评审\n\n这段会没有结论。\n"
        )
        let emptied = try await store.minutesItems(minutesID: edited.id)
        XCTAssertTrue(
            emptied.isEmpty,
            "正文里已经没有的句子，不能在条目里留着当这一版的结论"
        )
        // 原版不受影响。
        let untouchedOriginal = try await store.minutesItems(minutesID: fixture.minutesID)
        XCTAssertEqual(untouchedOriginal.count, 1)
    }

    // MARK: - MC-47：撤销不是删历史

    func testUndoWritesANewVersionInsteadOfDeleting() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        let sourceVersion = try await store.minutesVersion(id: fixture.minutesID)
        let originalBody = try XCTUnwrap(sourceVersion).body

        let edited = try await store.saveUserMinutesEdit(
            sessionID: fixture.sessionID,
            editingMinutesID: fixture.minutesID,
            body: "# 发布评审\n\n发布窗口改到十月。\n"
        )
        let undoResult = try await store.undoMinutesEdit(minutesID: edited.id)
        let undone = try XCTUnwrap(undoResult)
        XCTAssertEqual(undone.body, originalBody, "撤销回到改动之前的内容")
        XCTAssertNotEqual(undone.id, edited.id, "撤销是新版本，不删掉改过的那一版")
        // `bodyOrigin` 说的是内容出处。撤销之后正文与 AI 原文逐字相同，
        // 标成"你改过"是假的；这一版是撤销产生的，由血缘链如实记录。
        XCTAssertEqual(undone.bodyOrigin, .ai)
        XCTAssertEqual(undone.parentMinutesID, fixture.minutesID, "血缘指回它撤掉的那一版")

        let versions = try await store.minutesVersions(sessionID: fixture.sessionID)
        XCTAssertEqual(versions.count, 3, "三版都还在，用户能看到自己改过什么")
        XCTAssertTrue(versions.contains { $0.body == "# 发布评审\n\n发布窗口改到十月。\n" })
    }

    func testUndoOnAFirstVersionDoesNothing() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        let undone = try await store.undoMinutesEdit(minutesID: fixture.minutesID)
        XCTAssertNil(undone, "第一版没有上一版可撤")
    }

    func testEditingAnUnreadyVersionIsRefused() async throws {
        let store = try requireStore()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone, title: "空会")
        )
        let queued = try await store.enqueueMinutes(
            sessionID: record.id, model: nil, promptChars: 10
        )
        do {
            _ = try await store.saveUserMinutesEdit(
                sessionID: record.id, editingMinutesID: queued.id, body: "随便写点"
            )
            XCTFail("还没整理出正文的版本不该能被改")
        } catch {}
    }

    func testEditingAVersionFromAnotherMeetingIsRefused() async throws {
        let store = try requireStore()
        let a = try await makeMeeting(decisions: ["A 的决定"])
        let b = try await makeMeeting(decisions: ["B 的决定"])
        do {
            _ = try await store.saveUserMinutesEdit(
                sessionID: b.sessionID, editingMinutesID: a.minutesID, body: "串场了"
            )
            XCTFail("不能改别的会议的版本")
        } catch {}
    }

    func testEditingAnArchivedMeetingDoesNotWriteBack() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        _ = try await store.deleteMeetingKnowledge(documentID: fixture.documentID, mode: .archive)
        do {
            _ = try await store.saveUserMinutesEdit(
                sessionID: fixture.sessionID, editingMinutesID: fixture.minutesID,
                body: "# 评审\n\n归档之后还想改。\n"
            )
            XCTFail("归档之后不该写得回去")
        } catch {}
        let survived = try await store.minutesVersion(id: fixture.minutesID)
        let original = try XCTUnwrap(survived)
        XCTAssertEqual(original.bodyOrigin, .ai, "原版没被动过")
    }

    // MARK: - 采用仍要走用户那一下

    func testEditingDoesNotSilentlyAdopt() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        let edited = try await store.saveUserMinutesEdit(
            sessionID: fixture.sessionID, editingMinutesID: fixture.minutesID,
            body: "# 发布评审\n\n发布窗口改到十月。\n"
        )
        XCTAssertFalse(edited.isAccepted, "改完不等于采用，采用要走用户明确那一下")
        let originalAfterEdit = try await store.minutesVersion(id: fixture.minutesID)
        XCTAssertFalse(
            originalAfterEdit?.isAccepted ?? true,
            "改之前那一版也没有被自动采用"
        )

        let adopted = try await store.adoptMinutes(
            sessionID: fixture.sessionID, minutesID: edited.id, expectedCurrentID: nil
        )
        XCTAssertTrue(adopted)
        let adoptedVersion = try await store.minutesVersion(id: edited.id)
        XCTAssertTrue(adoptedVersion?.isAccepted ?? false)
    }

    // MARK: - 用户补充（验收 2 的第四档来源）

    /// 验收 2 要求区分「原始转录、人工修订、AI 归纳、**用户补充**」四档。
    /// 第四档此前**产不出来**：`user_supplement` 这个字面量全仓不存在，
    /// 枚举有、标题有、复核界面还会渲染「这段是你补充的」，但没有代码路径写得进去。
    func testSupplementProducesTheFourthOrigin() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        let supplemented = try await store.saveUserSupplement(
            sessionID: fixture.sessionID,
            editingMinutesID: fixture.minutesID,
            supplement: "客户已经口头同意顺延两周。"
        )
        XCTAssertEqual(supplemented.bodyOrigin, .userSupplement, "补写的这一档必须能被标出来")
        XCTAssertTrue(supplemented.bodyOrigin.isUserAuthored)

        let body = try XCTUnwrap(supplemented.body)
        XCTAssertTrue(body.contains("发布窗口定在九月"), "AI 原来写的内容不能被补充冲掉")
        XCTAssertTrue(body.contains("客户已经口头同意顺延两周"), "补充内容要真的进正文")

        // 改过的那一版还在——补充也是另存一版，不是覆盖。
        let original = try await store.minutesVersion(id: fixture.minutesID)
        XCTAssertEqual(original?.bodyOrigin, .ai)
    }

    /// 补充的话**没有转录来源，就不许挂引用**（方案 §302）。
    /// 把邻句的引用挂到用户自己写的话上，等于替用户伪造出处。
    func testSupplementInheritsNoCitation() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        let supplemented = try await store.saveUserSupplement(
            sessionID: fixture.sessionID,
            editingMinutesID: fixture.minutesID,
            supplement: "客户已经口头同意顺延两周。"
        )
        let items = try await store.minutesItems(minutesID: supplemented.id)
        XCTAssertEqual(
            items.count, 1,
            "补充的那句不该变成一条带引用的结论——它不是会上说过的"
        )
        XCTAssertEqual(items.first?.text, "发布窗口定在九月")
        XCTAssertFalse(
            items.first?.anchors.isEmpty ?? true,
            "AI 原来那条一字未改，对原句的引用仍然成立"
        )
    }

    /// 空的补充不写进去——写一版空壳只会让版本链多一跳。
    func testEmptySupplementIsRefused() async throws {
        let store = try requireStore()
        let fixture = try await makeMeeting(decisions: ["发布窗口定在九月"])
        do {
            _ = try await store.saveUserSupplement(
                sessionID: fixture.sessionID,
                editingMinutesID: fixture.minutesID,
                supplement: "   \n  "
            )
            XCTFail("空补充必须拒绝")
        } catch {
            let versions = try await store.minutesVersions(sessionID: fixture.sessionID)
            XCTAssertEqual(versions.count, 1, "拒绝之后不该凭空多一版")
        }
    }
}
