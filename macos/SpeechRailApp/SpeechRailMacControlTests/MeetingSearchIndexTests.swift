import Foundation
import SQLite3
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 可离线的中文全文检索（方案 MA-15 / §6.5 / MC-49 / MC-54～MC-56 / MC-62）。
///
/// 钉的是四条最容易悄悄错的：
/// - **两个汉字的查询必须有明确通路**（MC-54）。trigram 会让「预算」「回滚」
///   因为不足 3 字而零命中——那不是"没有"，是漏检。
/// - **分词与规范化文档/查询同源**（MC-55）：`3.5万元` 与 `35万元` 不是同一个值，
///   `v3.5.6` 与 `v3.5.7` 也是；全角与半角要能互相命中。
/// - **删除在检索前后都有效**（MC-62）：索引里还留着不代表还能被搜出来。
/// - **索引坏了不丢内容**：索引是派生数据，重建即可。
@MainActor
final class MeetingSearchIndexTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipIf(!SessionStore.fts5Available, "这个 SQLite 没有 FTS5")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-search-\(UUID().uuidString)", isDirectory: true)
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

    private func requireStore() throws -> SessionStore {
        try XCTUnwrap(store)
    }

    /// 造一场会议并写入若干终稿行。`XCTAssert*` 的自动闭包里不能 await，
    /// 所以调用方一律先取局部变量再断言。
    @discardableResult
    private func makeSession(kind: SessionKind = .meeting, texts: [String]) async throws -> String {
        let store = try requireStore()
        let record = try await store.createSession(
            SessionDraft(kind: kind, engineProfile: "test", audioSource: .microphone)
        )
        for (offset, text) in texts.enumerated() {
            _ = try await store.appendLine(
                LineDraft(
                    sessionID: record.id,
                    role: .speaker,
                    text: text,
                    source: .microphone,
                    status: .final
                ),
                id: "line-\(record.id)-\(offset)"
            )
        }
        return record.id
    }

    private func search(_ query: String) async throws -> SessionStore.KnowledgeSearchResults {
        let store = try requireStore()
        return try await store.searchKnowledgeFullText(query: query)
    }

    // MARK: - MC-54 短词通路

    /// MC-54：两个汉字的查询必须命中。这是 trigram 方案会静默漏掉的那一类。
    func testTwoCharacterChineseQueryFindsContent() async throws {
        let store = try requireStore()
        _ = try await makeSession(texts: ["这个季度的预算已经确认了。", "发布失败时先回滚。"])
        try await store.drainSearchIndex()

        for query in ["预算", "回滚"] {
            let results = try await search(query)
            XCTAssertTrue(
                results.usedFullText,
                "\(query) 应当走全文索引，实际：\(results.degradedReason ?? "")"
            )
            XCTAssertFalse(
                results.hits.isEmpty,
                "两字查询「\(query)」零命中——这正是 trigram 的漏检，不能当成「确实没有」"
            )
        }
    }

    /// 三字及以上查询按相邻二元组 AND，顺序必须保持。
    func testMultiCharacterQueryKeepsOrder() async throws {
        let store = try requireStore()
        _ = try await makeSession(texts: ["会议室已经订好了。", "预算和排期都确认了。"])
        try await store.drainSearchIndex()

        let hit = try await search("会议室")
        XCTAssertEqual(hit.hits.count, 1, "只有「会议室」这一条含该词")
        let reversed = try await search("室会议")
        XCTAssertTrue(reversed.hits.isEmpty, "倒序的词不该命中：二元组是有序的")
    }

    // MARK: - MC-55 分词与规范化

    /// 金额不同的两句话不能互相命中（`3.5万元` ≠ `35万元`）。
    func testDifferentAmountsAreNotTheSameValue() async throws {
        let store = try requireStore()
        _ = try await makeSession(texts: ["这次预算按 3.5万元 算。"])
        try await store.drainSearchIndex()

        let hit = try await search("3.5万元")
        XCTAssertEqual(hit.hits.count, 1)
        let wrong = try await search("35万元")
        XCTAssertTrue(
            wrong.hits.isEmpty,
            "35万元 不该命中 3.5万元：数字段必须整体进 token，不能只留「万元」"
        )
    }

    /// 版本号不同就是不同内容。
    func testVersionNumbersAreDistinct() async throws {
        let store = try requireStore()
        _ = try await makeSession(texts: ["当前跑的是 v3.5.6。"])
        try await store.drainSearchIndex()
        let hit = try await search("v3.5.6")
        XCTAssertEqual(hit.hits.count, 1)
        let wrong = try await search("v3.5.7")
        XCTAssertTrue(wrong.hits.isEmpty, "不存在的版本号不该被模糊命中")
    }

    /// 产品名大小写不敏感，但不做前缀模糊匹配。
    func testProductNameIsCaseInsensitiveButNotFuzzy() async throws {
        let store = try requireStore()
        _ = try await makeSession(texts: ["SpeechRail 的会议纪要。"])
        try await store.drainSearchIndex()
        let lower = try await search("speechrail")
        XCTAssertEqual(lower.hits.count, 1)
        let prefix = try await search("speech")
        XCTAssertTrue(
            prefix.hits.isEmpty,
            "不该做前缀模糊匹配：SpeechRail 与 Speech 不是同一件事"
        )
    }

    /// 全角与半角必须互相命中——否则同一份内容换个输入方式就搜不到。
    func testFullWidthAndHalfWidthNormalizeTogether() async throws {
        let store = try requireStore()
        _ = try await makeSession(texts: ["预算是３.５万元。"])
        try await store.drainSearchIndex()
        let results = try await search("3.5")
        XCTAssertFalse(results.hits.isEmpty, "全角数字应当能被半角查询命中（NFKC 规范化）")
    }

    /// 分词器的不变量：查询词项必须是索引词项的子集。
    func testQueryTermsAreSubsetOfIndexTerms() {
        for text in ["预算按 3.5万元 算", "v3.5.6 发布", "会议室", "SpeechRail"] {
            let index = Set(KnowledgeSearchTokenizer.indexTerms(for: text))
            for term in KnowledgeSearchTokenizer.queryTerms(for: text) {
                XCTAssertTrue(
                    index.contains(term),
                    "查询词项 \(term) 不在索引词项里，文档与查询就不是同一套分词：\(text)"
                )
            }
        }
    }

    // MARK: - 删除与状态过滤（MC-62）

    /// 会议删除后不得再被搜出来，即使索引里还留着那一行。
    func testDeletedSessionDoesNotResurrectInResults() async throws {
        let store = try requireStore()
        let keep = try await makeSession(texts: ["预算已经确认。"])
        let drop = try await makeSession(texts: ["预算还在调整。"])
        try await store.drainSearchIndex()
        let before = try await search("预算")
        XCTAssertEqual(before.hits.count, 2)

        try await store.removeSession(id: drop)
        try await store.drainSearchIndex()

        let after = try await search("预算")
        XCTAssertEqual(
            after.hits.map(\.sessionID),
            [keep],
            "删掉的会议不该因为索引里还有行而被搜出来（MC-62）"
        )
    }

    // MARK: - 采用版优先去重

    /// 同一场会议多版纪要时只出一条，且优先当前采用版。
    func testAdoptedVersionWinsAndDedupesPerSession() async throws {
        let store = try requireStore()
        let sessionID = try await makeSession(texts: [])
        var ids: [String] = []
        for body in ["旧版提到预算。", "新版也提到预算。"] {
            _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
            let claimed = try await store.claimMinutes(sessionID: sessionID, lease: 600)
            let row = try XCTUnwrap(claimed)
            let saved = try await store.saveMinutesCandidate(
                minutesID: row.id,
                expectedAttempts: row.attempts,
                body: body,
                model: nil,
                candidate: nil,
                review: nil
            )
            XCTAssertTrue(saved)
            ids.append(row.id)
        }
        try await store.drainSearchIndex()
        let beforeAdopt = try await search("预算")
        let minutesBefore = beforeAdopt.hits.filter { $0.minutesID != nil }
        XCTAssertEqual(
            minutesBefore.count,
            1,
            "同一场会议不该因为有多版纪要而刷出多条"
        )

        try await store.adoptMinutes(sessionID: sessionID, minutesID: ids[0], expectedCurrentID: nil)
        try await store.drainSearchIndex()
        let afterAdopt = try await search("预算")
        let minutesHit = afterAdopt.hits.first { $0.minutesID != nil }
        XCTAssertEqual(
            minutesHit?.minutesID,
            ids[0],
            "采用版优先：用户核对过的那一版应当是搜出来的那一版"
        )
    }

    // MARK: - 索引状态与重建

    /// 保存与索引更新分开报状态：内容写成功但索引还没跟上时必须看得出来。
    func testIndexStatusReportsPendingSeparatelyFromSave() async throws {
        let store = try requireStore()
        _ = try await makeSession(texts: ["预算确认。"])
        let pending = try await store.searchIndexStatus()
        XCTAssertTrue(pending.isFullTextAvailable)
        XCTAssertFalse(
            pending.isCaughtUp,
            "刚保存完还没 drain，索引必须显示有待处理项，而不是假装已经同步"
        )
        XCTAssertEqual(pending.indexedCount, 0)

        try await store.drainSearchIndex()
        let caughtUp = try await store.searchIndexStatus()
        XCTAssertTrue(caughtUp.isCaughtUp, "drain 之后索引应当与内容一致")
        XCTAssertEqual(caughtUp.indexedCount, 1)
    }

    /// 索引损坏不丢内容：清空索引后重建即可，内容一行不少。
    func testIndexIsDerivedAndCanBeRebuilt() async throws {
        let store = try requireStore()
        let sessionID = try await makeSession(texts: ["预算是 3.5万元。"])
        try await store.drainSearchIndex()
        let before = try await search("预算")
        XCTAssertEqual(before.hits.count, 1)

        // 模拟索引损坏/丢失：只清索引，不动内容。
        try Self.runSQL(
            on: try XCTUnwrap(directory).appendingPathComponent(SessionStore.fileName),
            statements: ["DELETE FROM knowledge_fts;"]
        )
        let broken = try await search("预算")
        XCTAssertTrue(
            broken.hits.isEmpty,
            "索引被清掉后确实搜不到——这正是为什么不能只靠索引"
        )
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.count, 1, "内容没有丢，只有索引丢了")

        try await store.rebuildSearchIndex()
        let rebuilt = try await search("预算")
        XCTAssertEqual(
            rebuilt.hits.count,
            1,
            "重建后应当恢复；索引是派生数据，不需要从索引反推内容"
        )
    }

    /// 私密问答默认不进索引（MC-44）。
    func testPrivateExchangeIsNotIndexed() async throws {
        let store = try requireStore()
        let sessionID = try await makeSession(texts: [])
        _ = try await store.saveInnerOSExchange(
            InnerOSExchange(
                id: "q-1",
                sessionID: sessionID,
                askedAt: Date(),
                atOrdinal: 1,
                question: "预算的口径是什么",
                intent: nil,
                answerText: "私密补充答案",
                model: "test"
            )
        )
        try await store.drainSearchIndex()
        let results = try await search("私密补充答案")
        XCTAssertTrue(results.hits.isEmpty, "私密问答不得进入检索结果")
    }

    /// 空查询与纯标点查询不得退化成全库扫描。
    func testEmptyAndPunctuationOnlyQueriesReturnNothing() async throws {
        let store = try requireStore()
        _ = try await makeSession(texts: ["预算确认。"])
        try await store.drainSearchIndex()
        let blank = try await search("   ")
        XCTAssertTrue(blank.hits.isEmpty)
        let punctuation = try await search("，。！")
        XCTAssertTrue(
            punctuation.hits.isEmpty,
            "纯标点没有可检索词项，结果必须为空而不是全库"
        )
        XCTAssertFalse(punctuation.usedFullText, "这种查询应明确标为回退")
    }

    // MARK: - 工具

    private static func runSQL(on file: URL, statements: [String]) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw SessionStoreError.storageUnavailable
        }
        defer { sqlite3_close_v2(pointer) }
        for statement in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(pointer, statement, nil, nil, &error) == SQLITE_OK else {
                let detail = error.map { String(cString: $0) } ?? "未知错误"
                sqlite3_free(error)
                XCTFail("执行 `\(statement)` 失败：\(detail)")
                return
            }
        }
    }
}
