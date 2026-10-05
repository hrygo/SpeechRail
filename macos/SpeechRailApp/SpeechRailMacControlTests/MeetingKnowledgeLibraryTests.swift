import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 会议知识库列表与详情（方案 MA-12 / MC-48～MC-52、MC-75）。
///
/// 这一页出问题时用户**看不出来**：会议少了、计数和列表对不上、
/// 或者切了场之后看到的是上一场的正文——都得靠测试钉住。
@MainActor
final class MeetingKnowledgeLibraryTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var coordinator: SessionCoordinator?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "meeting-library-\(UUID().uuidString)"))
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

    private func requireCoordinator() throws -> SessionCoordinator { try XCTUnwrap(coordinator) }

    private func requireStore() throws -> SessionStore { try XCTUnwrap(store) }

    /// 造一场会并整理出一版纪要。时间显式错开，排序才可复现。
    @discardableResult
    private func makeMeeting(
        title: String,
        projectID: String? = nil,
        at occurredAt: Date,
        actions: [String] = ["整理发布清单"],
        withMinutes: Bool = true
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
        // 先封存：meeting_document 行是封存时建的，先改文档会找不到行。
        let sealed = try await store.sealMeetingSource(sessionID: record.id)
        let snapshotID = try XCTUnwrap(sealed?.id)
        let existing = try await store.meetingDocument(forSessionID: record.id)
        let document = try XCTUnwrap(existing?.id)
        try await store.updateMeetingDocument(
            id: document, title: .some(title), projectID: .some(projectID), occurredAt: .some(occurredAt)
        )
        guard withMinutes else { return document }
        let units = [MinutesSourceUnit(
            id: "u1", lineID: "\(record.id)-line", ordinal: 1,
            speaker: "张三", text: "先确认这几点。", startSeconds: 0
        )]
        var candidate = MinutesCandidateV2(
            title: title, overview: [], decisions: [], actions: [], openQuestions: [], confidenceNotes: ""
        )
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

    private func seedMeetings(_ count: Int) async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            _ = try await makeMeeting(
                title: "第 \(index + 1) 场会",
                projectID: index % 2 == 0 ? "p-a" : "p-b",
                at: base.addingTimeInterval(Double(index) * 86_400)
            )
        }
    }

    // MARK: - MC-52：列表完整，不只显示最近几场

    func testLibraryPagesThroughEveryMeeting() async throws {
        let store = try requireStore()
        try await seedMeetings(25)

        var seen: [String] = []
        var offset = 0
        var total = 0
        repeat {
            let page = try await store.meetingLibraryPage(limit: 10, offset: offset)
            total = page.counts.total
            seen.append(contentsOf: page.rows.map(\.id))
            if !page.hasMore { break }
            offset += 10
        } while true

        XCTAssertEqual(total, 25, "25 场就该是 25 场")
        XCTAssertEqual(seen.count, 25, "翻页取全不漏")
        XCTAssertEqual(Set(seen).count, 25, "翻页不重复")
    }

    func testCountsStayTheSameOnEveryPage() async throws {
        let store = try requireStore()
        try await seedMeetings(12)
        let first = try await store.meetingLibraryPage(limit: 5, offset: 0)
        let last = try await store.meetingLibraryPage(limit: 5, offset: 10)
        XCTAssertEqual(first.counts.total, 12)
        XCTAssertEqual(last.counts.total, 12, "翻到最后一页，总数还是 12")
        XCTAssertEqual(first.counts.needsReview, last.counts.needsReview, "待核对数不随翻页跳")
        XCTAssertEqual(first.counts.byStatus, last.counts.byStatus)
        XCTAssertEqual(last.rows.count, 2)
    }

    func testMeetingsWithoutMinutesAreStillListed() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(
            title: "整理过的一场", at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        _ = try await makeMeeting(
            title: "还没整理的一场", at: Date(timeIntervalSince1970: 1_700_086_400), withMinutes: false
        )
        let page = try await store.meetingLibraryPage()
        XCTAssertEqual(page.counts.total, 2, "没整理过的会议也要列出来，否则用户以为它不存在")
        let unorganized = try XCTUnwrap(page.rows.first { $0.title == "还没整理的一场" })
        XCTAssertFalse(unorganized.hasMinutes)
        let organized = try XCTUnwrap(page.rows.first { $0.title == "整理过的一场" })
        XCTAssertTrue(organized.hasMinutes)
    }

    func testSearchMatchesTitleAndProjectName() async throws {
        let store = try requireStore()
        let project = try await store.createProject(name: "季度规划", id: "p-q")
        _ = try await makeMeeting(
            title: "发布评审", projectID: project.id, at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        _ = try await makeMeeting(
            title: "招聘评审", projectID: "p-other", at: Date(timeIntervalSince1970: 1_700_086_400)
        )
        let byTitle = try await store.meetingLibraryPage(query: "发布")
        XCTAssertEqual(byTitle.counts.total, 1)
        XCTAssertEqual(byTitle.rows.first?.title, "发布评审")

        let byProject = try await store.meetingLibraryPage(query: "季度规划")
        XCTAssertEqual(byProject.counts.total, 1, "项目名也要能搜到")
        XCTAssertEqual(byProject.rows.first?.projectName, "季度规划")

        let none = try await store.meetingLibraryPage(query: "查无此会")
        XCTAssertEqual(none.counts.total, 0)
    }

    func testSearchTreatsWildcardsAsLiteralText() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(title: "预算 100% 达成", at: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await makeMeeting(title: "预算八成", at: Date(timeIntervalSince1970: 1_700_086_400))
        let page = try await store.meetingLibraryPage(query: "100%")
        XCTAssertEqual(page.counts.total, 1, "「%」是普通字符，不是通配符")
        let underscore = try await store.meetingLibraryPage(query: "_")
        XCTAssertEqual(underscore.counts.total, 0)
    }

    func testProjectFilterNarrowsTheList() async throws {
        let store = try requireStore()
        try await seedMeetings(6)
        let onlyA = try await store.meetingLibraryPage(projectID: "p-a")
        XCTAssertEqual(onlyA.counts.total, 3)
        XCTAssertTrue(onlyA.rows.allSatisfy { $0.projectID == "p-a" })
    }

    // MARK: - MC-50：详情一次读取、整体提交

    func testSnapshotReadsMinutesTranscriptAndItemsTogether() async throws {
        let store = try requireStore()
        let documentID = try await makeMeeting(
            title: "发布评审", at: Date(timeIntervalSince1970: 1_700_000_000),
            actions: ["整理发布清单", "同步给客户"]
        )
        let loaded = try await store.meetingReviewSnapshot(documentID: documentID)
        let snapshot = try XCTUnwrap(loaded)
        XCTAssertEqual(snapshot.documentID, documentID)
        XCTAssertEqual(snapshot.title, "发布评审")
        XCTAssertNotNil(snapshot.minutesBody, "纪要和条目必须来自同一次读取")
        XCTAssertEqual(snapshot.transcriptLines, ["先确认这几点。"])
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testSnapshotIsOptionalForUnknownDocument() async throws {
        let store = try requireStore()
        let snapshot = try await store.meetingReviewSnapshot(documentID: "没有这个文档")
        XCTAssertNil(snapshot)
    }

    // MARK: - MC-50：代次守卫

    func testLateResultFromPreviousSelectionIsDiscarded() async throws {
        let store = try requireStore()
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        let first = try await makeMeeting(
            title: "A 场", at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = try await makeMeeting(
            title: "B 场", at: Date(timeIntervalSince1970: 1_700_086_400)
        )

        // 模拟：A 先发起，用户马上切到 B，然后 A 的结果才回来。
        let generationA = model.beginSelection(first)
        let generationB = model.beginSelection(second)
        XCTAssertGreaterThan(generationB, generationA)

        let loadedB = try await store.meetingReviewSnapshot(documentID: second)
        let snapshotB = try XCTUnwrap(loadedB)
        model.commitDetail(snapshotB, generation: generationB)
        XCTAssertEqual(model.snapshot?.title, "B 场")

        let loadedA = try await store.meetingReviewSnapshot(documentID: first)
        let snapshotA = try XCTUnwrap(loadedA)
        model.commitDetail(snapshotA, generation: generationA)
        XCTAssertEqual(
            model.snapshot?.title, "B 场",
            "A 的迟到结果不能覆盖已经切过去的 B（MC-50）"
        )
        XCTAssertEqual(model.selectedDocumentID, second)
    }

    func testLateErrorFromPreviousSelectionIsDiscarded() async throws {
        let store = try requireStore()
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        let first = try await makeMeeting(
            title: "A 场", at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = try await makeMeeting(
            title: "B 场", at: Date(timeIntervalSince1970: 1_700_086_400)
        )
        let generationA = model.beginSelection(first)
        let generationB = model.beginSelection(second)
        let loadedB = try await store.meetingReviewSnapshot(documentID: second)
        model.commitDetail(try XCTUnwrap(loadedB), generation: generationB)
        model.commitDetailError("A 读失败了", generation: generationA)
        XCTAssertNil(model.detailError, "上一场的报错也不该盖到当前场次上")
        XCTAssertEqual(model.snapshot?.title, "B 场")
    }

    func testClearingSelectionEmptiesTheDetail() async throws {
        let store = try requireStore()
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        let document = try await makeMeeting(
            title: "A 场", at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await model.open(documentID: document)
        XCTAssertNotNil(model.snapshot)
        await model.select(nil)
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.selectedDocumentID)
    }

    // MARK: - 列表模型

    func testModelLoadsAndSearches() async throws {
        let store = try requireStore()
        try await seedMeetings(4)
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadPage(offset: 0)
        XCTAssertEqual(model.rows.count, 4)
        XCTAssertEqual(model.counts.total, 4)
        XCTAssertFalse(model.hasMore)

        await model.search("第 2 场")
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.title, "第 2 场会")
        XCTAssertTrue(model.emptyStateHint.contains("第 2 场"), "空态要说清正在搜什么")

        await model.search("查无此会")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.emptyStateHint.contains("换个词"), "没结果要说下一步做什么")
    }

    func testEmptyLibrarySuggestsWhatToDo() async throws {
        let store = try requireStore()
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadPage(offset: 0)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.emptyStateHint.contains("录一场"), "空库要说下一步，而不是「暂无数据」")
    }
}
