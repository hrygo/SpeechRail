import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 结构化知识投影：项目、标签、筛选与分页（方案 MA-13 / MC-51、MC-52、MC-56）。
///
/// 这里钉的是三件最容易出错、而且出错之后用户**看不出来**的事：
/// - 两个同名项目混成一份（MC-51）：身份是 id，不是名字；
/// - 只有待核对候选的那场会从库里消失（MC-52）：默认档必须留着它并标出来；
/// - 计数和列表对不上、分页漏项或重复（MC-56）：同一段谓词出两处结果。
@MainActor
final class MeetingProjectProjectionTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-projection-\(UUID().uuidString)", isDirectory: true)
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

    /// 造一场已整理好的会。`occurredAt` 显式给不同值：分页排序稳定，测试才可复现。
    @discardableResult
    private func makeMeeting(
        title: String,
        projectID: String?,
        occurredAt: Date,
        actions: [String],
        decisions: [String] = [],
        unbackedText: String? = nil
    ) async throws -> String {
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
            id: documentID,
            title: .some(title),
            projectID: .some(projectID),
            occurredAt: .some(occurredAt)
        )

        let units = [MinutesSourceUnit(
            id: "u1", lineID: "\(record.id)-line", ordinal: 1,
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
        if let unbackedText {
            candidate.actions.append(.init(
                localID: "a-unbacked", task: unbackedText, ownerText: nil,
                dueExpression: nil, commitment: .proposed, sourceUnitIDs: ["u-does-not-exist"]
            ))
        }

        let encoded = try JSONEncoder().encode(candidate)
        guard case .prepared(let prepared) = MinutesCandidateCodec.prepare(
            text: String(data: encoded, encoding: .utf8) ?? "", units: units
        ) else {
            XCTFail("结构合法的候选应当解析成功")
            throw XCTSkip("候选构造失败")
        }
        _ = try await store.enqueueMinutes(sessionID: record.id, model: nil, promptChars: 20, snapshotID: snapshotID)
        let claimed = try await store.claimMinutes(sessionID: record.id, lease: 600)
        let row = try XCTUnwrap(claimed)
        let revisionIDs = try await store.latestRevisionIDsByLine(sessionID: record.id)
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
        return documentID
    }

    // MARK: - MC-51：同名项目各成一份

    func testSameNamedProjectsAreNotMixedTogether() async throws {
        let store = try requireStore()
        let old = try await store.createProject(name: "发布", id: "p-2024")
        let recent = try await store.createProject(name: "发布", id: "p-2025")
        XCTAssertEqual(old.name, recent.name, "两个项目确实同名")
        XCTAssertNotEqual(old.id, recent.id)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await makeMeeting(title: "2024 发布评审", projectID: old.id, occurredAt: base, actions: ["2024 的待办"])
        _ = try await makeMeeting(title: "2025 发布评审", projectID: recent.id, occurredAt: base.addingTimeInterval(86_400), actions: ["2025 的待办", "2025 的第二项"])

        let oldPage = try await store.knowledgeItems(filter: KnowledgeItemFilter(projectIDs: [old.id]))
        XCTAssertEqual(oldPage.counts.total, 1, "同名不等于同一份：按 id 只取到 2024 那一场")
        XCTAssertEqual(oldPage.items.map(\.text), ["2024 的待办"])

        let recentPage = try await store.knowledgeItems(filter: KnowledgeItemFilter(projectIDs: [recent.id]))
        XCTAssertEqual(recentPage.counts.total, 2)
        XCTAssertEqual(Set(recentPage.items.map(\.text)), ["2025 的待办", "2025 的第二项"])

        let everything = try await store.knowledgeItems()
        XCTAssertEqual(everything.counts.total, 3, "不加筛选时两场合计，不重不漏")

        // 改名不改变身份，也不影响归属。
        try await store.renameProject(id: recent.id, name: "发布（2025）")
        let afterRename = try await store.knowledgeItems(filter: KnowledgeItemFilter(projectIDs: [recent.id]))
        XCTAssertEqual(afterRename.counts.total, 2, "项目改名不影响内容归属")
        let byName = try await store.knowledgeItems(filter: KnowledgeItemFilter(projectIDs: ["发布"]))
        XCTAssertEqual(byName.counts.total, 0, "按名字筛不到任何东西：名字不是身份")
    }

    func testProjectListKeepsBothSameNamedProjects() async throws {
        let store = try requireStore()
        _ = try await store.createProject(name: "季度规划", id: "q1")
        _ = try await store.createProject(name: "季度规划", id: "q2")
        let all = try await store.projects()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map(\.name)), ["季度规划"])
        XCTAssertEqual(Set(all.map(\.id)), ["q1", "q2"])
    }

    // MARK: - MC-52：只有待核对候选的那场会不能消失

    func testMeetingWithOnlyUnverifiedItemsStaysVisible() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 这场会**只有**一条待核对候选：对不上任何原句。
        // 默认档必须仍然看得见它——否则用户以为这场会的内容丢了（MC-52）。
        _ = try await makeMeeting(
            title: "火星发射场评审",
            projectID: "p-mars",
            occurredAt: base,
            actions: [],
            unbackedText: "明年在火星建一座发射场"
        )

        let byDefault = try await store.knowledgeItems(filter: KnowledgeItemFilter(projectIDs: ["p-mars"]))
        XCTAssertEqual(byDefault.counts.total, 1, "默认档必须留着这场会，不能因为没有已确认结论就当它不存在")
        XCTAssertEqual(byDefault.counts.needsReview, 1)
        XCTAssertTrue(
            byDefault.items.allSatisfy { $0.status.needsReview },
            "待核对的条目要标出来，而不是混在已确认里"
        )

        let strict = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(projectIDs: ["p-mars"], verification: .strictlyVerified)
        )
        XCTAssertEqual(strict.counts.total, 0, "严格档就是「只看已确认」，用户显式选的")
        XCTAssertTrue(strict.items.allSatisfy { !$0.status.needsReview })
    }

    func testStrictlyVerifiedKeepsTheBackedItemsOnly() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(
            title: "发布评审",
            projectID: "p",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            actions: ["整理发布清单"],
            unbackedText: "顺便买台服务器"
        )
        let loose = try await store.knowledgeItems(filter: KnowledgeItemFilter(projectIDs: ["p"]))
        let strict = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(projectIDs: ["p"], verification: .strictlyVerified)
        )
        XCTAssertEqual(strict.counts.total, 1)
        XCTAssertEqual(strict.items.map(\.text), ["整理发布清单"])
        XCTAssertEqual(loose.counts.total, 2, "默认档两条都在")
        XCTAssertEqual(loose.counts.byKind["action"], 2)
    }

    // MARK: - MC-56：计数与列表同源，分页不重不漏

    func testCountsMatchWhatPagingActuallyReturns() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var expected = 0
        for round in 0..<3 {
            _ = try await makeMeeting(
                title: "第 \(round) 场",
                projectID: "p",
                occurredAt: base.addingTimeInterval(Double(round) * 3_600),
                actions: (0..<2).map { "待办 \(round)-\($0)" }
            )
            expected += 2
        }

        let full = try await store.knowledgeItems(filter: KnowledgeItemFilter(projectIDs: ["p"]), limit: 100)
        XCTAssertEqual(full.counts.total, expected)
        XCTAssertEqual(full.counts.total, full.items.count)
        XCTAssertFalse(full.hasMore)
        XCTAssertEqual(full.counts.byKind["action"], expected)

        var collected: [String] = []
        var offset = 0
        var reported = 0
        while true {
            let page = try await store.knowledgeItems(
                filter: KnowledgeItemFilter(projectIDs: ["p"]), limit: 2, offset: offset
            )
            reported = page.counts.total
            collected.append(contentsOf: page.items.map(\.text))
            if !page.hasMore { break }
            offset += 2
        }
        XCTAssertEqual(reported, expected, "每页报的总数是同一份计数")
        XCTAssertEqual(collected.count, expected, "翻页取全不漏项")
        XCTAssertEqual(Set(collected).count, expected, "翻页不重复")
        XCTAssertEqual(Set(collected), Set(full.items.map(\.text)), "分页结果与一次取全一致")
    }

    func testPagingBeyondEndReturnsEmptyButKeepsCounts() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(
            title: "一场会", projectID: "p",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            actions: ["只有一条"]
        )
        let page = try await store.knowledgeItems(filter: KnowledgeItemFilter(projectIDs: ["p"]), limit: 10, offset: 50)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.counts.total, 1, "翻过头了，总数仍然如实")
        XCTAssertFalse(page.hasMore)
    }

    // MARK: - 标签：只由用户写，取交集

    func testTagFilterRequiresEveryTagToMatch() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let both = try await makeMeeting(title: "发布评审", projectID: "p", occurredAt: base, actions: ["待办甲"])
        let onlyOne = try await makeMeeting(
            title: "招聘评审", projectID: "p",
            occurredAt: base.addingTimeInterval(3_600), actions: ["待办乙"]
        )
        try await store.setDocumentTags(documentID: both, tags: ["发布", "2024", "  发布  "])
        try await store.setDocumentTags(documentID: onlyOne, tags: ["发布"])

        let bothTags = try await store.documentTags(documentID: both)
        XCTAssertEqual(bothTags, ["2024", "发布"], "标签去重去空白")
        let projectTags = try await store.documentTagsInProject(projectID: "p")
        XCTAssertEqual(projectTags, ["2024", "发布"])

        let both2 = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(projectIDs: ["p"], tags: ["发布", "2024"])
        )
        XCTAssertEqual(both2.counts.total, 1, "两个标签都打上才算命中交集")
        XCTAssertEqual(both2.items.first?.documentID, both)

        let either = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(projectIDs: ["p"], tags: ["发布"])
        )
        XCTAssertEqual(either.counts.total, 2, "只按一个标签筛，两场都算")

        let none = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(projectIDs: ["p"], tags: ["不存在"])
        )
        XCTAssertEqual(none.counts.total, 0)
    }

    func testTagsAreClearedWhenRewritten() async throws {
        let store = try requireStore()
        let documentID = try await makeMeeting(
            title: "一场会", projectID: "p",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            actions: ["待办"]
        )
        try await store.setDocumentTags(documentID: documentID, tags: ["旧标签"])
        try await store.setDocumentTags(documentID: documentID, tags: ["新标签"])
        let rewritten = try await store.documentTags(documentID: documentID)
        XCTAssertEqual(rewritten, ["新标签"])
        try await store.setDocumentTags(documentID: documentID, tags: [])
        let cleared = try await store.documentTags(documentID: documentID)
        XCTAssertEqual(cleared, [])
    }

    func testTagsGoAwayWithTheDocumentTheyBelongTo() async throws {
        let store = try requireStore()
        let documentID = try await makeMeeting(
            title: "一场会", projectID: "p",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            actions: ["待办"]
        )
        try await store.setDocumentTags(documentID: documentID, tags: ["发布"])
        _ = try await store.deleteMeetingKnowledge(documentID: documentID, mode: .deleteEverything)
        // 标签挂在文档上：文档没了，标签不能变成查不到也删不掉的孤儿行。
        let orphan = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(tags: ["发布"])
        )
        XCTAssertEqual(orphan.counts.total, 0)
        let survivors = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(tags: ["发布"]), scope: MeetingKnowledgeScope(includesArchived: true)
        )
        XCTAssertEqual(survivors.counts.total, 0, "彻底删除后连归档范围里也不该有残留")
    }

    // MARK: - 筛选维度组合

    func testKindAndDocumentFiltersCombine() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await makeMeeting(
            title: "A", projectID: "p1", occurredAt: base,
            actions: ["A 的待办"], decisions: ["A 的决定"]
        )
        _ = try await makeMeeting(
            title: "B", projectID: "p2", occurredAt: base.addingTimeInterval(3_600),
            actions: ["B 的待办"]
        )

        let decisionsOnly = try await store.knowledgeItems(filter: KnowledgeItemFilter(kinds: ["decision"]))
        XCTAssertEqual(decisionsOnly.counts.total, 1)
        XCTAssertEqual(decisionsOnly.items.map(\.text), ["A 的决定"])

        let byDocument = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(projectIDs: ["p1", "p2"], documentIDs: [first])
        )
        XCTAssertEqual(byDocument.counts.total, 2, "点名文档后只看这一场，与项目条件同时生效")

        let contradictory = try await store.knowledgeItems(
            filter: KnowledgeItemFilter(documentIDs: [first], kinds: ["open_question"])
        )
        XCTAssertEqual(contradictory.counts.total, 0, "条件之间是 AND，不是命中一个就算")
    }

    func testProjectRejectsBlankNameAndUnknownDocumentTagging() async throws {
        let store = try requireStore()
        do {
            _ = try await store.createProject(name: "   ")
            XCTFail("空项目名应当被拒绝")
        } catch {}
        do {
            try await store.setDocumentTags(documentID: "没有这个文档", tags: ["x"])
            XCTFail("给不存在的文档打标签应当被拒绝")
        } catch {}
    }
}
