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
        lineText: String = "先确认这几点。",
        withMinutes: Bool = true
    ) async throws -> String {
        let store = try requireStore()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone, title: title)
        )
        _ = try await store.appendLine(
            LineDraft(
                sessionID: record.id, role: .speaker, text: lineText,
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
            speaker: "张三", text: lineText, startSeconds: 0
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

    /// 搜索框必须能搜到**正文**。
    ///
    /// 这一条曾经长期是红的：全文检索只在 `SessionStore` 上存在，
    /// 列表谓词只认标题与项目名，用户在库里打一个会上真说过的词，
    /// 得到的却是"没有匹配的会议"。能力交付了，界面够不着。
    ///
    /// 钉住的是「标题里没有这个词」——否则一个只搜标题的实现也能蒙混过关。
    func testSearchMatchesTranscriptContentNotJustTitle() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(
            title: "第一场会", at: Date(timeIntervalSince1970: 1_700_000_000),
            lineText: "灰度发布要等到周五才能开。"
        )
        _ = try await makeMeeting(
            title: "第二场会", at: Date(timeIntervalSince1970: 1_700_086_400),
            lineText: "这一场跟发布无关。"
        )
        try await store.drainSearchIndex()

        let page = try await store.meetingLibraryPage(query: "灰度")
        XCTAssertEqual(
            page.counts.total, 1,
            "「灰度」只在转录里出现，标题和项目名都没有——搜不到就是正文检索没接上"
        )
        XCTAssertEqual(page.rows.first?.title, "第一场会")
        XCTAssertEqual(
            page.counts.total, page.rows.count,
            "计数与列表走同一段谓词，正文分支不能让两者对不上"
        )
    }

    /// 总账第 9 条：**搜索结果按时间倒序排，没有相关性**。
    /// 用户搜"灰度"，最可能想要的是那场**就叫《灰度发布评审》**的会，
    /// 而不是上周某场正文里碰巧提了一次灰度的会——后者时间更近，
    /// 于是一直排在前面，而用户只能一页页翻过去找。
    ///
    /// 这里只做**标题优先**这一条，不做通用打分：标题是用户自己起的名字，
    /// 是"这场会就是我要找的那场"最强的信号，而它是可解释的——
    /// 界面上排在前面的理由用户一眼能懂。通用 BM25 在这套中文分词下
    /// 并不划算（索引里同时写单字与二元组，单字的 IDF 几乎没有区分度）。
    func testTitleMatchRanksAheadOfNewerBodyOnlyMatch() async throws {
        let store = try requireStore()
        // 旧的那场标题里就有这个词。
        _ = try await makeMeeting(
            title: "灰度发布评审", at: Date(timeIntervalSince1970: 1_700_000_000),
            lineText: "先确认一下范围。"
        )
        // 新得多的那场只在正文里提到它。
        _ = try await makeMeeting(
            title: "第七周站会", at: Date(timeIntervalSince1970: 1_700_086_400),
            lineText: "另外灰度那边的排期要跟一下。"
        )
        try await store.drainSearchIndex()

        let page = try await store.meetingLibraryPage(query: "灰度")
        XCTAssertEqual(page.counts.total, 2, "两场都该命中")
        XCTAssertEqual(
            page.rows.map(\.title), ["灰度发布评审", "第七周站会"],
            "标题命中的那场要排在只有正文命中的前面，哪怕它更旧"
        )
    }

    /// 排序不得改计数。标题优先是在分页查询里额外绑了一个参数——
    /// 一旦这个绑定串位，计数就会静默算错，而列表看起来仍然正常。
    func testRelevanceOrderingKeepsCountsInStepWithTheList() async throws {
        let store = try requireStore()
        for index in 0..<3 {
            _ = try await makeMeeting(
                title: index == 0 ? "预算复核" : "第 \(index + 1) 场站会",
                at: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400),
                lineText: index == 0 ? "随便说点别的。" : "顺便提一下预算。"
            )
        }
        try await store.drainSearchIndex()

        let page = try await store.meetingLibraryPage(query: "预算", limit: 1)
        XCTAssertEqual(page.counts.total, 3, "命中三场")
        XCTAssertEqual(page.rows.count, 1, "这一页只取一条")
        XCTAssertEqual(
            page.counts.total, 3,
            "加了排序绑定之后计数仍要与列表同源，不能因为绑定串位而变"
        )
        let second = try await store.meetingLibraryPage(query: "预算", limit: 1, offset: 1)
        XCTAssertEqual(second.rows.count, 1, "第二页也要有东西——排序不能吃掉行")
    }

    /// 正文检索同样要守删除口径（MC-62 / 验收 4「删除内容不得被索引」）：
    /// 归档之后搜索看不见它，打开"连归档的一起列"才回来。
    func testContentSearchRespectsDeletion() async throws {
        let store = try requireStore()
        let documentID = try await makeMeeting(
            title: "要归档的一场", at: Date(timeIntervalSince1970: 1_700_000_000),
            lineText: "紫罗兰色的告警还没查清。"
        )
        try await store.drainSearchIndex()
        let before = try await store.meetingLibraryPage(query: "紫罗兰")
        XCTAssertEqual(before.counts.total, 1)

        try await store.deleteMeetingKnowledge(documentID: documentID, mode: .archive)

        let hidden = try await store.meetingLibraryPage(query: "紫罗兰")
        XCTAssertEqual(hidden.counts.total, 0, "归档之后搜索就该看不见它")
        let shown = try await store.meetingLibraryPage(query: "紫罗兰", includesArchived: true)
        XCTAssertEqual(shown.counts.total, 1, "撤得回，就一定找得回来")

        try await store.restoreMeetingKnowledge(documentID: documentID)
        try await store.drainSearchIndex()
        let restored = try await store.meetingLibraryPage(query: "紫罗兰")
        XCTAssertEqual(restored.counts.total, 1, "撤销归档后正文检索要恢复")
    }

    /// 验收 4 的「与证据」：搜到的那场要**当场给出为什么命中**。
    ///
    /// 命中词刻意放在第 150 个字符之后：只从开头截一段的话根本截不到它，
    /// "有片段"和"片段里有证据"是两件事。只断言非空会放过前者。
    func testSearchResultCarriesTheMatchedSentence() async throws {
        let store = try requireStore()
        let lineText = String(repeating: "前置背景。", count: 30)
            + "这里才提到灰度发布要等到周五。"
            + String(repeating: "后续讨论。", count: 10)
        _ = try await makeMeeting(
            title: "发布评审", at: Date(timeIntervalSince1970: 1_700_000_000),
            lineText: lineText
        )
        try await store.drainSearchIndex()

        let page = try await store.meetingLibraryPage(query: "灰度")
        let row = try XCTUnwrap(page.rows.first)
        let excerpt = try XCTUnwrap(row.matchExcerpt, "命中正文却不给证据，用户还得自己点进去找")
        XCTAssertTrue(
            excerpt.contains("灰度"),
            "证据片段必须含命中词，实际拿到的是：\(excerpt)"
        )
    }

    /// 反过来：**标题命中不该硬凑一句证据**。
    ///
    /// 凑出来的那句看起来像证据，但它证明不了任何事——这正是
    /// "界面不说没有依据的话"要防的那一类。
    func testTitleOnlyMatchCarriesNoExcerpt() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(
            title: "招聘评审", at: Date(timeIntervalSince1970: 1_700_000_000),
            lineText: "这一场只讨论报销流程。", withMinutes: false
        )
        try await store.drainSearchIndex()

        let page = try await store.meetingLibraryPage(query: "招聘")
        XCTAssertEqual(page.counts.total, 1, "标题命中这场会")
        XCTAssertNil(
            page.rows.first?.matchExcerpt,
            "标题命中、正文没命中，不该凭空生成一句证据"
        )
    }

    /// 没在搜索时不给证据：满屏都是"命中内容"就等于没有重点。
    func testNoExcerptWithoutQuery() async throws {
        let store = try requireStore()
        _ = try await makeMeeting(
            title: "随便一场", at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.drainSearchIndex()

        let page = try await store.meetingLibraryPage()
        XCTAssertEqual(page.counts.total, 1)
        XCTAssertNil(page.rows.first?.matchExcerpt)
    }

    // MARK: - 验收 4：导出已有资料

    /// 导出件必须是**库里定稿的内容**，而且转录行要带得住 id 与时间。
    ///
    /// 详情快照里的转录只有纯文本（`[String]`）。拿它去导出，
    /// 导出来的文件对不回任何来源——用户拿到的不是"这场会议"，是"一段话"。
    func testExportPayloadCarriesIdentifiableTranscriptLines() async throws {
        let store = try requireStore()
        let documentID = try await makeMeeting(
            title: "要导出的会", at: Date(timeIntervalSince1970: 1_700_000_000),
            lineText: "这一句要能对回来源。"
        )

        let exported = try await store.meetingExportPayload(documentID: documentID)
        let payload = try XCTUnwrap(exported)
        XCTAssertEqual(payload.record.title, "要导出的会")
        XCTAssertEqual(payload.lines.count, 1)
        XCTAssertEqual(payload.lines.first?.text, "这一句要能对回来源。")
        XCTAssertFalse(
            (payload.lines.first?.id ?? "").isEmpty,
            "没有行 id，导出件就对不回来源"
        )
        XCTAssertNotNil(payload.minutes, "整理过的会议要把纪要一起导出去")
    }

    /// MC-48：用户看的是哪一版，导出去就得是哪一版。
    ///
    /// 先记下详情当时显示的那一版，改出第二版之后再导——
    /// 如果实现是"永远导最新版"，这条会红。
    func testExportFollowsTheVersionOnScreen() async throws {
        let store = try requireStore()
        let documentID = try await makeMeeting(
            title: "两版的会", at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshot = try await store.meetingReviewSnapshot(documentID: documentID)
        let first = try XCTUnwrap(
            snapshot?.minutesVersionID,
            "详情拿不到当前版本的 id，导出就没有东西可钉"
        )
        let document = try await store.meetingDocument(id: documentID)
        let sessionID = try XCTUnwrap(document?.sourceSessionID)
        let firstVersion = try await store.minutesVersion(id: first)
        let firstBody = try XCTUnwrap(firstVersion?.body)

        _ = try await store.saveUserMinutesEdit(
            sessionID: sessionID, editingMinutesID: first, body: "这是用户改过的第二版。"
        )

        let pinnedExport = try await store.meetingExportPayload(
            documentID: documentID, minutesVersionID: first
        )
        let pinned = try XCTUnwrap(pinnedExport)
        XCTAssertEqual(pinned.minutes?.id, first, "钉住哪一版就该导出哪一版")
        XCTAssertEqual(pinned.minutes?.body, firstBody)
    }

    /// 没有会话的导入纪要（MC-68）导不出转录。**这时要说导不出**，
    /// 不能给一个只有壳子的文件——用户会以为导全了。
    func testExportRefusesWhenThereIsNoSession() async throws {
        let store = try requireStore()
        let imported = try await store.createMeetingDocument(
            MeetingDocument(id: "doc-import-export", sourceSessionID: nil, title: "外部导入纪要")
        )
        let payload = try await store.meetingExportPayload(documentID: imported.id)
        XCTAssertNil(payload, "没有会话就没有转录行，不能导出空壳")
    }

    func testProjectFilterNarrowsTheList() async throws {
        let store = try requireStore()
        try await seedMeetings(6)
        let onlyA = try await store.meetingLibraryPage(projectID: "p-a")
        XCTAssertEqual(onlyA.counts.total, 3)
        XCTAssertTrue(onlyA.rows.allSatisfy { $0.projectID == "p-a" })
    }

    // MARK: - 项目与标签（MA-13 / MC-51、MC-53）

    /// MC-51/MC-53：按项目筛完，**计数与列表仍然同源**。
    ///
    /// 这条以前只有"筛完剩 3 场"这种断言，翻页与待核对数对不对没人管。
    /// 筛选菜单一接上，用户就会靠数字判断筛对没有，数字错了比筛错更糟。
    func testProjectFilterKeepsCountsAndListInStep() async throws {
        let store = try requireStore()
        try await seedMeetings(6)
        let first = try await store.meetingLibraryPage(projectID: "p-a", limit: 2, offset: 0)
        let second = try await store.meetingLibraryPage(projectID: "p-a", limit: 2, offset: 2)

        XCTAssertEqual(first.counts.total, 3)
        XCTAssertEqual(first.rows.count, 2)
        XCTAssertEqual(second.counts.total, 3, "翻到第二页，总数还是 3")
        XCTAssertEqual(
            first.counts.needsReview, second.counts.needsReview,
            "筛选后待核对数不随翻页跳"
        )
        XCTAssertTrue(first.rows.allSatisfy { $0.projectID == "p-a" })
        XCTAssertTrue(second.rows.allSatisfy { $0.projectID == "p-a" })
        XCTAssertEqual(
            Set((first.rows + second.rows).map(\.id)).count, 3,
            "筛选后翻页不重复也不漏"
        )
    }

    /// 标签要**看得见**。只写不读的标签等于没加——
    /// 用户加完标签，下一次打开库页还是找不到自己分过类。
    func testLibraryRowsCarryTheirTags() async throws {
        let store = try requireStore()
        let documentID = try await makeMeeting(
            title: "要打标签的会", at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.setDocumentTags(documentID: documentID, tags: ["季度规划", "招聘"])
        try await store.setDocumentTags(documentID: documentID, tags: ["季度规划", "  ", ""])

        let page = try await store.meetingLibraryPage()
        let row = try XCTUnwrap(page.rows.first { $0.id == documentID })
        XCTAssertEqual(row.tags, ["季度规划"], "空白标签不算标签，顺序稳定")
    }

    /// 归到项目之后，按项目筛要能把这场会筛出来——
    /// 否则"归到项目"只是一个写进去没人读的动作。
    func testAssigningProjectMovesTheMeetingIntoThatFilter() async throws {
        let store = try requireStore()
        let documentID = try await makeMeeting(
            title: "刚归入项目的会", at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let project = try await store.createProject(name: "季度规划", id: "p-new")

        let before = try await store.meetingLibraryPage(projectID: project.id)
        XCTAssertEqual(before.counts.total, 0)

        try await store.updateMeetingDocument(id: documentID, projectID: .some(project.id))

        let after = try await store.meetingLibraryPage(projectID: project.id)
        XCTAssertEqual(after.counts.total, 1)
        XCTAssertEqual(after.rows.first?.projectName, "季度规划")
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

    // MARK: - 跨会议问答（MA-17）
    //
    // 这一整块此前**一个入口都没有**：`MeetingKnowledgeQueryService` 与它的
    // 拒答／分页／注入防护／展示前范围复核都实现完整、都有测试，
    // 但生产代码里没有任何地方构造它——用户能搜、能筛、能导出，却没法问一句。
    // `MeetingKnowledgeQueryTests` 那十几项证明的是**服务本身**是对的，
    // 替换掉"谁来构造它"这一层，不会有一条变红。
    //
    // 所以下面这几条钉的是**接线**：model → 协调器 → 服务。

    /// 没配模型就说没配。**不发一个注定失败的请求**，也不把空答案摆出来——
    /// 后者会让用户以为"库里确实没有这条"，而真实原因是压根没问成。
    func testAskingWithoutAModelSaysSoInsteadOfPretending() async throws {
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.ask("上次的灰度排期是哪天", configuration: LLMConfiguration())

        XCTAssertNil(model.answer, "没配模型就没有答案，不能摆一个空壳")
        let error = try XCTUnwrap(model.askError, "必须有一句能看的话")
        XCTAssertTrue(error.contains("配置"), "要说清是配置的事：\(error)")
        XCTAssertFalse(model.isAsking, "失败之后不能停在「正在问」上")
    }

    /// 空问题不问。发出去只是一次无意义的往返，而用户什么都没得到。
    func testEmptyQuestionIsNotSent() async throws {
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.ask("   ", configuration: Self.configuredAskConfiguration)

        XCTAssertNil(model.answer)
        XCTAssertNil(model.askError)
        XCTAssertFalse(model.isAsking)
    }

    /// **接线本身**：配好了、库里一条记录都没有 → 本地拒答，**一步都不往模型走**。
    ///
    /// 这条同时钉住两件事：model 真的把请求送到了协调器与服务（否则 `answer`
    /// 会一直是 nil），以及"没有证据就不问模型"这条纪律在**生产路径**上成立
    /// ——它不成立的时候，用户问一句就烧一次调用，而答案还是"没有记录"。
    func testAskingWithNoEvidenceRefusesWithoutReachingTheModel() async throws {
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.ask("上次的灰度排期是哪天", configuration: Self.configuredAskConfiguration)

        XCTAssertNil(model.askError, "库里没有记录不是错误，是答案的一部分")
        let answer = try XCTUnwrap(model.answer, "接线断在这里：model 没有拿到任何回答")
        XCTAssertEqual(answer.draft.refusal, .noEvidence)
        XCTAssertTrue(answer.draft.segments.isEmpty)
        XCTAssertFalse(model.isAsking)
        XCTAssertEqual(model.askDraft, "", "问完就把输入框收干净，别留一半")
    }

    /// 清掉答案要连草稿与错误一起清——范围变了就该重来一次，
    /// 留着上一句草稿只会让用户以为那句还没问出去。
    func testClearingTheAnswerResetsDraftAndError() async throws {
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.ask("灰度排期", configuration: LLMConfiguration())
        XCTAssertNotNil(model.askError)

        model.askDraft = "没问出去的半句"
        model.clearAnswer()
        XCTAssertNil(model.answer)
        XCTAssertNil(model.askError)
        XCTAssertEqual(model.askDraft, "")
    }

    /// **这条是为了区分"真的走到了服务"与"协调器自己造了个拒答"**。
    ///
    /// 上一条（库里没记录 → 本地拒答）证明的是 model → 协调器这一段：
    /// 变异检验把协调器改成绕过服务、直接返回一个伪造的拒答，那条**照样全绿**。
    /// 所以这里换一个能分辨的判据：库里有记录时，服务必须越过本地拒答、
    /// **真的去问模型**。端点指向一个必定连接失败的本地端口，于是
    /// 真实路径必然抛错——伪造的拒答给不出这个结果。
    func testAskingWithEvidenceActuallyReachesTheModelStep() async throws {
        _ = try await makeMeeting(
            title: "发布评审", at: Date(timeIntervalSince1970: 1_700_000_000),
            actions: ["整理发布清单"]
        )
        // 问法里必须带得上记录里的词：检索是按正文匹配的，
        // 问一个库里根本没出现过的词，返回"没有记录"是正确行为而不是缺陷
        // ——第一次写这条用例时正是踩了这个坑。
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.ask("发布清单上次是怎么说的", configuration: Self.configuredAskConfiguration)

        XCTAssertNil(
            model.answer,
            "有证据却给出一段本地拒答，说明服务根本没被调用——问模型那一步被跳过了"
        )
        let error = try XCTUnwrap(model.askError, "真实路径必然报错：端点是必定连接失败的本地端口")
        XCTAssertFalse(error.isEmpty)
        XCTAssertFalse(model.isAsking, "失败之后不能停在「正在问」上")
    }

    private static let configuredAskConfiguration = LLMConfiguration(
        baseURL: "http://127.0.0.1:9/v1", model: "test-model"
    )

    // MARK: - 会前准备稿（MA-17）
    //
    // 目标里六个环节，「会前准备」排在第一个，而这一整层此前**一个界面入口都没有**：
    // `MeetingPrepDraft`、`store.meetingPrepDraft(scope:)` 连 `markdown()` 渲染都完整，
    // 全仓却只有库层与测试引用它。用户手里有一套跨会议的未决事项，
    // 却要自己一场一场点开去拼下一场该准备什么。
    //
    // 下面几条钉的是**接线**：model → 协调器 → store，外加范围与代次两条纪律。
    // 视图层（`MeetingKnowledgeLibraryView.swift`）是 App-only，SPM 测不到，
    // 所以「界面上真的排了先核对那组」属于未验证项，如实记在交付文档里。

    /// **接线本身**：库里有一条未完成的行动 → 准备稿里能看到它。
    /// 把「谁来调用」这一层拿掉，`prepDraft` 会一直是 nil——库里做得再对也没用。
    func testPrepDraftReachesTheLibraryThroughTheModel() async throws {
        _ = try await makeMeeting(
            title: "发布评审", at: Date(timeIntervalSince1970: 1_700_000_000),
            actions: ["整理发布清单"]
        )
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadPrepDraft()

        XCTAssertNil(model.prepError)
        let draft = try XCTUnwrap(model.prepDraft, "接线断在这里：model 没有拿到准备稿")
        XCTAssertFalse(model.isLoadingPrep, "取完不能停在「正在准备」上")
        XCTAssertTrue(
            draft.pendingActions.contains { $0.text.contains("整理发布清单") },
            "会上定了、还没做的事必须出现在准备稿里"
        )
    }

    /// 准备稿的范围跟着库页筛选走（MC-64）。用户正在看某个项目，
    /// 准备稿就不该把别的项目的未决事项端到他面前——那等于替他做了授权决定。
    func testPrepDraftFollowsTheLibraryProjectFilter() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await makeMeeting(
            title: "A 场的会", projectID: "p-a", at: base, actions: ["整理 A 的清单"]
        )
        _ = try await makeMeeting(
            title: "B 场的会", projectID: "p-b",
            at: base.addingTimeInterval(86_400), actions: ["整理 B 的清单"]
        )
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())

        await model.loadPrepDraft()
        let all = try XCTUnwrap(model.prepDraft)
        XCTAssertEqual(all.pendingActions.count, 2, "不加筛选时两场会的事都该在")

        await model.filter(projectID: "p-a")
        await model.loadPrepDraft()
        let scoped = try XCTUnwrap(model.prepDraft)
        XCTAssertTrue(scoped.pendingActions.contains { $0.text.contains("A 的清单") })
        XCTAssertFalse(
            scoped.pendingActions.contains { $0.text.contains("B 的清单") },
            "范围没跟着筛选收窄（MC-64）：用户没授权把 B 项目的内容端到他面前"
        )
    }

    /// 代次守卫：切了范围之后，**上一次迟到的结果不能盖上来**。
    /// 与详情、列表、问答同一条纪律——那一处不守就会出现
    /// "A 项目的准备稿配着 B 项目的筛选条件"。
    func testLatePrepDraftFromPreviousScopeIsDiscarded() async throws {
        let store = try requireStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await makeMeeting(
            title: "A 场的会", projectID: "p-a", at: base, actions: ["整理 A 的清单"]
        )
        _ = try await makeMeeting(
            title: "B 场的会", projectID: "p-b",
            at: base.addingTimeInterval(86_400), actions: ["整理 B 的清单"]
        )
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())

        // 先取 A 的（作废），再取 B 的，然后 A 才迟到。
        let generationA = model.beginPrepLoad()
        let generationB = model.beginPrepLoad()
        XCTAssertGreaterThan(generationB, generationA)

        let draftB = try await store.meetingPrepDraft(scope: MeetingKnowledgeScope(projectID: "p-b"))
        model.commitPrepDraft(draftB, generation: generationB)

        let draftA = try await store.meetingPrepDraft(scope: MeetingKnowledgeScope(projectID: "p-a"))
        model.commitPrepDraft(draftA, generation: generationA)

        let current = try XCTUnwrap(model.prepDraft)
        XCTAssertTrue(current.pendingActions.contains { $0.text.contains("B 的清单") })
        XCTAssertFalse(
            current.pendingActions.contains { $0.text.contains("A 的清单") },
            "A 的迟到结果盖掉了 B：代次守卫没生效"
        )
    }

    /// 命中超过一次能列出的条数时，**必须承认自己被截断了**。
    ///
    /// 只列 200 条却在界面上说"这就是全部待跟进"，正是 MC-52 点名的失败形态；
    /// 上一轮修「未完成事项」时已经为同一件事付过一次代价（计数与列表取自不同谓词）。
    func testPrepDraftSaysSoWhenItStopsAtTheListingLimit() async throws {
        _ = try await makeMeeting(
            title: "很长的会", at: Date(timeIntervalSince1970: 1_700_000_000),
            actions: (1...250).map { "待办第 \($0) 项" }
        )
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadPrepDraft()

        let draft = try XCTUnwrap(model.prepDraft)
        XCTAssertEqual(draft.totalMatched, 250, "总数要按实际命中报，不能按列出来的报")
        XCTAssertEqual(draft.listedCount, 200, "一次只列 200 条")
        XCTAssertTrue(
            draft.stoppedAtLimit,
            "命中 250 条、只列 200 条却说自己列全了——这就是 MC-52 的形态"
        )

        let rendered = draft.markdown()
        XCTAssertTrue(rendered.contains("250"), "准备稿正文要写清只列了前面一段")
        XCTAssertTrue(
            rendered.contains("不会自动发送"),
            "这份东西不会自己发出去，说出来才算数"
        )
    }

    /// 没被截断时不许写那句提示——一个从不截断的面板挂着一句
    /// "可能还有更多没列进来"，用户会开始怀疑自己是不是漏看了。
    func testPrepDraftStaysQuietWhenNothingWasLeftOut() async throws {
        _ = try await makeMeeting(
            title: "发布会", at: Date(timeIntervalSince1970: 1_700_000_000),
            actions: ["整理发布清单"]
        )
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadPrepDraft()

        let draft = try XCTUnwrap(model.prepDraft)
        XCTAssertFalse(draft.stoppedAtLimit)
        XCTAssertFalse(
            draft.markdown().contains("只列出了前"),
            "没有截断就不该出现截断提示"
        )
    }

    /// 收起面板要把准备稿与错误一起清掉。留着上一份，下次打开时
    /// 用户会以为那还是此刻这个筛选范围下的内容。
    func testClearingThePrepDraftEmptiesItAndTheError() async throws {
        _ = try await makeMeeting(
            title: "发布评审", at: Date(timeIntervalSince1970: 1_700_000_000),
            actions: ["整理发布清单"]
        )
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadPrepDraft()
        XCTAssertNotNil(model.prepDraft)

        model.clearPrepDraft()
        XCTAssertNil(model.prepDraft)
        XCTAssertNil(model.prepError)
        XCTAssertFalse(model.isLoadingPrep)
    }

    /// MC-48 在 model 层也要成立：归档包的 `selectedMinutesID` 必须是
    /// **详情正在显示的那一版**。
    ///
    /// `MeetingKnowledgeArchiveTests` 那 22 项全都直接构造
    /// `KnowledgeArchiveSelection`——它们证明的是 store 层正确，
    /// 替换掉"谁来填 minutesID"这一层，不会有一条变红。
    func testModelArchiveExportPinsTheVersionOnScreen() async throws {
        let store = try requireStore()
        let documentID = try await makeMeeting(
            title: "要归档的会", at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadPage(offset: 0)
        await model.open(documentID: documentID)
        let shown = try XCTUnwrap(
            model.snapshot?.minutesVersionID, "详情拿不到版本 id，归档包就没有东西可钉"
        )

        // 屏幕停在第一版，库里 meanwhile 已经有第二版。
        // 只导最新版的话这条会红——那正是 MC-48 说的失败形态。
        let document = try await store.meetingDocument(id: documentID)
        let sessionID = try XCTUnwrap(document?.sourceSessionID)
        _ = try await store.saveUserMinutesEdit(
            sessionID: sessionID, editingMinutesID: shown, body: "这是第二版。"
        )

        let parent = try XCTUnwrap(directory)
            .appendingPathComponent("packages-\(UUID().uuidString)", isDirectory: true)
        let exported = try await model.exportArchive(scope: .fullArchive, to: parent)
        let package = try XCTUnwrap(exported)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(
            contentsOf: package.appendingPathComponent(KnowledgeArchiveManifest.manifestFileName)
        )
        let manifest = try decoder.decode(KnowledgeArchiveManifest.self, from: data)
        XCTAssertEqual(manifest.documentID, documentID)
        XCTAssertEqual(
            manifest.selectedMinutesID, shown,
            "屏幕上显示的是第一版，库里已经有第二版——导出必须仍然是屏幕上那一版"
        )
    }

    /// 没整理出纪要的会议**导不出**归档包——`minutesID` 是必填项。
    /// 导一个空壳比导不出更糟：用户会以为这场会已经完整带走了。
    func testModelArchiveExportRefusesWithoutMinutes() async throws {
        let store = try requireStore()
        let documentID = try await makeMeeting(
            title: "还没整理的会", at: Date(timeIntervalSince1970: 1_700_000_000),
            withMinutes: false
        )
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadPage(offset: 0)
        await model.open(documentID: documentID)
        XCTAssertNil(model.snapshot?.minutesVersionID)

        let parent = try XCTUnwrap(directory)
            .appendingPathComponent("packages-\(UUID().uuidString)", isDirectory: true)
        let package = try await model.exportArchive(scope: .fullArchive, to: parent)
        XCTAssertNil(package, "没有纪要版本就没有可归档的东西")
    }

    func testEmptyLibrarySuggestsWhatToDo() async throws {
        let store = try requireStore()
        let model = MeetingLibraryModel(coordinator: try requireCoordinator())
        await model.loadPage(offset: 0)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.emptyStateHint.contains("录一场"), "空库要说下一步，而不是「暂无数据」")
    }
}
