import Foundation
import SQLite3
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 长会议分窗、覆盖账本与局部重试（方案 MA-09 / §6.3 / MC-39 / MC-40）。
///
/// 钉的是四件事：
/// - **每个来源单元恰好 owned 一次**，重叠只进只读上下文，不能当依据；
/// - 首、中、尾的重要事实都进得了候选，长会不被悄悄截成开头一段；
/// - 重叠区里的同一条待办归并后**只有一条**；
/// - 中间某窗失败时报覆盖缺口、只标部分结果，局部重试不重复造事项。
@MainActor
final class MeetingWindowCoverageTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-window-coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        self.directory = directory
        self.store = store
        self.sessionID = record.id
    }

    override func tearDown() async throws {
        if let store { await store.close() }
        store = nil
        sessionID = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func requireStore() throws -> SessionStore {
        try XCTUnwrap(store)
    }

    private func requireSessionID() throws -> String {
        try XCTUnwrap(sessionID)
    }

    // MARK: - 造数据

    /// 造一场长会议：`count` 句，每句 `text`，说话人交替（模拟真实发言轮次）。
    private func makeUnits(
        count: Int,
        text: (Int) -> String,
        speakers: [String] = ["张三", "李四"]
    ) -> [MinutesSourceUnit] {
        (0..<count).map { index in
            MinutesSourceUnit(
                id: "u\(index + 1)",
                lineID: "line-\(index + 1)",
                ordinal: index + 1,
                speaker: speakers[index % speakers.count],
                text: text(index),
                startSeconds: Double(index * 10)
            )
        }
    }

    /// 一句很长的发言，用来触发超长单句切分。
    private func longText(sentence: String, repeat count: Int) -> String {
        Array(repeating: sentence, count: count).joined(separator: "，")
    }

    private func budget(windowTokens: Int, overlap: Int = 2) -> MinutesWindowBudget {
        MinutesWindowBudget(
            windowTokens: windowTokens,
            reserveTokens: 0,
            overlapUnits: overlap,
            segmentTokens: 200
        )
    }

    // MARK: - 分窗：拥有区唯一，重叠只读

    /// 每个来源单元恰好被一个窗口拥有；重叠区不进拥有区。
    func testEveryUnitIsOwnedExactlyOnce() {
        let units = makeUnits(count: 40) { "第 \($0 + 1) 句转录内容，用来把窗口撑开。" }
        let windows = MinutesWindowPlanner.plan(units: units, budget: budget(windowTokens: 200))

        XCTAssertGreaterThan(windows.count, 1, "40 句按 200 token 一窗应该切出多窗")

        let owned = windows.flatMap { $0.owned.map(\.id) }
        XCTAssertEqual(Set(owned).count, owned.count, "同一个来源单元不能被两个窗口同时拥有")
        XCTAssertEqual(Set(owned), Set(units.map(\.id)), "每个来源单元都要被拥有，不许漏")

        // 重叠区里的单元属于别的窗口，不能出现在本窗的可引用集合里。
        for window in windows {
            let overlap = (window.contextBefore + window.contextAfter).map(\.id)
            for unitID in overlap {
                XCTAssertFalse(
                    window.citableUnitIDs.contains(unitID),
                    "重叠单元 \(unitID) 只能读，不能当依据"
                )
            }
        }
    }

    /// 短会是一个窗口，且走的是同一条切窗入口（回退口径）。
    func testShortMeetingIsSingleWindow() {
        let units = makeUnits(count: 3) { "第 \($0 + 1) 句。" }
        let windows = MinutesWindowPlanner.plan(units: units, budget: budget(windowTokens: 3_000))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.owned.count, 3)
    }

    /// 首、中、尾都有重要事实时，三处都必须落在某个窗口的拥有区里。
    func testHeadMiddleAndTailAllOwned() {
        let units = makeUnits(count: 60) { "第 \($0 + 1) 句。" }
        let windows = MinutesWindowPlanner.plan(units: units, budget: budget(windowTokens: 120))
        let owned = Set(windows.flatMap { $0.owned.map(\.id) })
        for milestone in ["u1", "u30", "u60"] {
            XCTAssertTrue(owned.contains(milestone), "\(milestone) 必须被某个窗口拥有")
        }
    }

    /// 超长单句要明确切分并留下范围映射，而不是被截断。
    func testOversizedUtteranceIsSplitWithRangeMapping() {
        let text = longText(sentence: "这是一句很长的发言内容需要被切分", repeat: 40)
        let unit = MinutesSourceUnit(
            id: "u1",
            lineID: "line-1",
            ordinal: 1,
            speaker: "张三",
            text: text,
            startSeconds: 0
        )
        let windows = MinutesWindowPlanner.plan(
            units: [unit],
            budget: budget(windowTokens: 200, overlap: 0)
        )
        let segments = windows.flatMap { $0.owned }
        XCTAssertGreaterThan(segments.count, 1, "超长单句必须切分，不能整句塞进一窗")

        // 段 id 带序号，且范围映射回同一句原文。
        XCTAssertTrue(segments.allSatisfy { $0.lineID == "line-1" }, "切分后的段仍指向同一句")
        XCTAssertTrue(segments.allSatisfy { $0.rootUnitID == "u1" }, "段要能映射回原始来源单元")
        let rebuilt = segments.map(\.text).joined()
        XCTAssertEqual(rebuilt, text, "切分不能丢字，也不能改字")
    }

    /// token 预算是保守估计：中文一句不会被当成"很少 token"。
    func testTokenEstimateIsConservativeForChinese() {
        let estimate = MinutesTokenEstimate.tokens(in: String(repeating: "会议纪要窗口预算", count: 40))
        XCTAssertGreaterThan(estimate, 100, "中文按字符估，应该给出明显偏大的值")
    }

    // MARK: - 归并：以来源身份去重

    private func action(
        _ localID: String,
        _ task: String,
        units: [String],
        commitment: MinutesCommitment = .committed
    ) -> MinutesCandidateV2.ActionItem {
        .init(
            localID: localID,
            task: task,
            ownerText: nil,
            dueExpression: nil,
            commitment: commitment,
            sourceUnitIDs: units
        )
    }

    private func candidate(
        actions: [MinutesCandidateV2.ActionItem] = [],
        decisions: [MinutesCandidateV2.DecisionItem] = []
    ) -> MinutesCandidateV2 {
        MinutesCandidateV2(
            title: "发布评审",
            overview: [],
            decisions: decisions,
            actions: actions,
            openQuestions: [],
            confidenceNotes: ""
        )
    }

    /// MC-39：重叠窗口看到同一条待办时，归并后只有一条。
    func testMergerDeduplicatesActionAcrossWindows() {
        let units = makeUnits(count: 4) { "第 \($0 + 1) 句。" }
        let merged = MinutesCandidateMerger.merge(
            windowCandidates: [
                candidate(actions: [action("a1", "整理发布清单", units: ["u1", "u2"])]),
                candidate(actions: [action("a1", "整理发布清单", units: ["u2", "u3"])]),
            ],
            units: units
        )
        XCTAssertEqual(
            merged.candidate.actions.count,
            1,
            "同一条待办在重叠区被两个窗口各写一次，归并后只能留一条"
        )
        XCTAssertEqual(
            Set(merged.candidate.actions[0].sourceUnitIDs),
            ["u1", "u2", "u3"],
            "合并后引用取并集，依据不能因为去重丢掉"
        )
    }

    /// MC-39：跨窗的撤回不能被"最新一句"吞掉——两个事件都留，标成未确认。
    func testCrossWindowRetractionKeepsBothEventsAndMarksUnconfirmed() {
        let units = makeUnits(count: 4) { "第 \($0 + 1) 句。" }
        let merged = MinutesCandidateMerger.merge(
            windowCandidates: [
                candidate(decisions: [
                    .init(
                        localID: "d1",
                        text: "按原计划上线",
                        modality: .decided,
                        conditions: [],
                        sourceUnitIDs: ["u1"]
                    ),
                ]),
                candidate(decisions: [
                    .init(
                        localID: "d1",
                        text: "按原计划上线",
                        modality: .retracted,
                        conditions: [],
                        sourceUnitIDs: ["u3"]
                    ),
                ]),
            ],
            units: units
        )
        XCTAssertEqual(
            merged.candidate.decisions.count,
            2,
            "提出与撤回是两个事件，不能因为后一句出现就自动作废前一句"
        )
        XCTAssertTrue(
            merged.candidate.decisions.contains { $0.conditions.contains("存在分歧/未确认") },
            "依据不足时要写明存在分歧，不能自动选最新一句"
        )
    }

    // MARK: - 覆盖账本

    /// MC-40：中间一窗失败时报缺口，不许假称整场完整。
    func testCoverageLedgerReportsGapWhenMiddleWindowFails() {
        let units = makeUnits(count: 40) { "第 \($0 + 1) 句转录内容。" }
        let windows = MinutesWindowPlanner.plan(units: units, budget: budget(windowTokens: 200))
        let failedIndex = windows[1].index
        let ledger = MinutesCoverageLedger.planned(
            units: units,
            windows: windows,
            outcomes: [failedIndex: .failed],
            failureReasons: [failedIndex: "结构不合法"]
        )

        XCTAssertFalse(ledger.isComplete, "有窗口失败就不许说整场完整")
        XCTAssertFalse(ledger.gapUnitIDs.isEmpty, "失败窗口拥有的单元是缺口")
        XCTAssertEqual(ledger.failedWindowIndexes, [failedIndex])
        XCTAssertTrue(ledger.summary().contains("部分结果"), "摘要要说清这是部分结果")
    }

    /// 输出截断单独记，不当成整理成功。
    func testTruncatedWindowIsNotCountedAsComplete() {
        let units = makeUnits(count: 10) { "第 \($0 + 1) 句。" }
        let windows = MinutesWindowPlanner.plan(units: units, budget: budget(windowTokens: 3_000))
        let ledger = MinutesCoverageLedger.planned(
            units: units,
            windows: windows,
            outcomes: [windows[0].index: .truncated]
        )
        XCTAssertEqual(ledger.truncatedWindowIndexes, [windows[0].index])
        XCTAssertFalse(ledger.isComplete)
        // 截断意味着这一窗的**尾部没拿全**，所以它的单元是真实缺口，
        // 不能因为"窗口跑过了"就算覆盖（§6.3）。
        XCTAssertFalse(ledger.gapUnitIDs.isEmpty, "被截断的窗口要留下覆盖缺口")
        XCTAssertTrue(
            ledger.summary().contains("截断"),
            "摘要要如实说是被截断，不是整理失败"
        )
    }

    /// 全部窗口成功才算完整。
    func testCoverageLedgerCompleteWhenAllWindowsProcessed() {
        let units = makeUnits(count: 10) { "第 \($0 + 1) 句。" }
        let windows = MinutesWindowPlanner.plan(units: units, budget: budget(windowTokens: 200))
        let ledger = MinutesCoverageLedger.planned(units: units, windows: windows)
        XCTAssertTrue(ledger.isComplete)
        XCTAssertEqual(ledger.coveredUnitIDs.count, units.count)
    }

    // MARK: - 落库与局部重试

    /// 覆盖账本随版本一起落库，重开仍然知道"哪里没整理到"。
    func testCoverageLedgerSurvivesReopen() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let units = makeUnits(count: 6) { "第 \($0 + 1) 句。" }
        let windows = MinutesWindowPlanner.plan(units: units, budget: budget(windowTokens: 3_000))
        let ledger = MinutesCoverageLedger.planned(
            units: units,
            windows: windows,
            outcomes: [windows[0].index: .failed],
            failureReasons: [windows[0].index: "网络中断"]
        )
        let coverageText = String(data: try JSONEncoder().encode(ledger), encoding: .utf8)
        let candidateJSON = String(
            data: try JSONEncoder().encode(candidate(actions: [action("a1", "整理清单", units: ["u1"])])),
            encoding: .utf8
        )

        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 10)
        let claimed = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        let row = try XCTUnwrap(claimed)
        let saved = try await store.saveMinutesCandidate(
            minutesID: row.id,
            expectedAttempts: row.attempts,
            body: "# 正文",
            model: nil,
            candidate: candidateJSON,
            review: nil,
            coverage: coverageText,
            windows: [
                MinutesWindowRecord(
                    index: windows[0].index,
                    ownedUnitIDs: windows[0].owned.map(\.id),
                    outcome: .failed,
                    failureReason: "网络中断"
                ),
            ]
        )
        XCTAssertTrue(saved)

        let reread = try await store.minutesVersion(id: row.id)
        let version = try XCTUnwrap(reread)
        XCTAssertEqual(version.coverage?.failedWindowIndexes, [windows[0].index])
        XCTAssertFalse(version.coverage?.isComplete ?? true)
        XCTAssertNotNil(
            version.coverageJSON,
            "没有分窗账本的版本读出来应该是 nil，不该被当成全部覆盖"
        )
    }

    /// MC-40：局部重试只重跑失败窗口，已成功的候选被复用、不重复生成。
    func testLocalRetryOnlyRerunsFailedWindows() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let units = makeUnits(count: 40) { "第 \($0 + 1) 句，这句话要够长才能把窗口撑开一些。" }
        let windows = MinutesWindowPlanner.plan(units: units, budget: budget(windowTokens: 200))
        XCTAssertGreaterThan(windows.count, 2, "这一场要切出多窗才谈得上局部重试")
        let failedIndex = windows[1].index
        let goodCandidate = candidate(actions: [action("a1", "整理清单", units: ["u1"])])
        let goodJSON = String(data: try JSONEncoder().encode(goodCandidate), encoding: .utf8)

        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 10)
        let claimed = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        let row = try XCTUnwrap(claimed)

        // 第一窗成功、第二窗失败，其余窗口还没有结果。
        let records: [MinutesWindowRecord] = windows.enumerated().map { offset, window in
            offset == 0
                ? MinutesWindowRecord(
                    index: window.index,
                    ownedUnitIDs: window.owned.map(\.id),
                    outcome: .processed,
                    candidateJSON: goodJSON
                )
                : offset == 1
                ? MinutesWindowRecord(
                    index: window.index,
                    ownedUnitIDs: window.owned.map(\.id),
                    outcome: .failed,
                    failureReason: "结构不合法"
                )
                : MinutesWindowRecord(
                    index: window.index,
                    ownedUnitIDs: window.owned.map(\.id),
                    outcome: .processed
                )
        }
        for record in records {
            let ok = try await store.recordMinutesWindow(
                minutesID: row.id,
                expectedAttempts: row.attempts,
                record: record
            )
            XCTAssertTrue(ok)
        }
        let saved = try await store.saveMinutesCandidate(
            minutesID: row.id,
            expectedAttempts: row.attempts,
            body: "# 正文",
            model: nil,
            candidate: goodJSON,
            review: nil,
            windows: records
        )
        XCTAssertTrue(saved)

        // 需要重试的只有失败那一窗。
        let retryable = try await store.retryableMinutesWindows(minutesID: row.id)
        XCTAssertEqual(retryable.map(\.index), [failedIndex])

        // 重新开成 running 时代际推进，带 fencing。
        // `XCTUnwrap` 的自动闭包里不能 await，所以先取出来再解。
        let stored = try await store.minutesVersion(id: row.id)
        let version = try XCTUnwrap(stored)
        let reopened = try await store.reopenMinutesForWindowRetry(
            minutesID: version.id,
            expectedAttempts: version.attempts,
            lease: 600
        )
        XCTAssertTrue(reopened, "未采用的失败版本应当能重开")
        let reopenedRow = try await store.minutesVersion(id: version.id)
        let afterReopen = try XCTUnwrap(reopenedRow)
        XCTAssertEqual(afterReopen.attempts, version.attempts + 1)
        XCTAssertEqual(afterReopen.status, .running)

        // 成功窗口的候选还在：重试不需要重新生成它，也不会多造一条待办。
        let stillThere = try await store.minutesWindows(minutesID: version.id)
        let kept = try XCTUnwrap(stillThere.first { $0.index != failedIndex && $0.candidateJSON != nil })
        XCTAssertEqual(kept.candidate?.actions.count, 1)

        // 旧代际的迟到写入被 fencing 挡住。
        let stale = try await store.recordMinutesWindow(
            minutesID: version.id,
            expectedAttempts: version.attempts,
            record: MinutesWindowRecord(
                index: failedIndex,
                ownedUnitIDs: ["u1"],
                outcome: .processed
            )
        )
        XCTAssertFalse(stale, "凭旧代际提交的窗口结果不得写回")
    }

    /// v6 → v7 迁移：既有纪要原样留下，覆盖账本**不补造**。
    ///
    /// 老版本是单窗生成的，从来没有分窗账本。补一份"全部覆盖"等于替用户
    /// 断言"当时整场都整理到了"——那是伪造，所以这里必须是 nil（MC-68 同一条口径）。
    func testMigrationV6ToV7KeepsRowsWithoutBackfillingCoverage() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let queued = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        let directory = try XCTUnwrap(directory)
        await store.close()

        // 把库按 v6 形状摆回去：删掉覆盖账本的两样东西。
        try Self.runSQL(
            on: directory.appendingPathComponent(SessionStore.fileName),
            statements: [
                "DROP TABLE IF EXISTS minutes_window;",
                "ALTER TABLE minutes DROP COLUMN coverage_json;",
                "PRAGMA user_version=6;",
            ]
        )

        let migrated = SessionStore(directory: directory)
        try await migrated.open()
        let stored = try await migrated.minutesVersion(id: queued.id)
        let version = try XCTUnwrap(stored, "迁移不能把既有纪要行弄丢")
        let windows = try await migrated.minutesWindows(minutesID: queued.id)
        await migrated.close()

        XCTAssertEqual(version.id, queued.id)
        XCTAssertNil(
            version.coverage,
            "v6 之前没有分窗账本，读出来应当是 nil，不能当成全部覆盖"
        )
        XCTAssertTrue(windows.isEmpty, "迁移不补造窗口行")
    }

    /// 已采用的版本不允许被局部重试改写。
    func testAcceptedVersionRefusesLocalRetry() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        _ = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 10)
        let claimed = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        let row = try XCTUnwrap(claimed)
        let candidateJSON = String(
            data: try JSONEncoder().encode(candidate(actions: [action("a1", "整理清单", units: ["u1"])])),
            encoding: .utf8
        )
        _ = try await store.saveMinutesCandidate(
            minutesID: row.id,
            expectedAttempts: row.attempts,
            body: "# 正文",
            model: nil,
            candidate: candidateJSON,
            review: nil
        )
        let adopted = try await store.adoptMinutes(
            sessionID: sessionID,
            minutesID: row.id,
            expectedCurrentID: nil
        )
        XCTAssertTrue(adopted)

        let stored = try await store.minutesVersion(id: row.id)
        let version = try XCTUnwrap(stored)
        let reopened = try await store.reopenMinutesForWindowRetry(
            minutesID: version.id,
            expectedAttempts: version.attempts,
            lease: 600
        )
        XCTAssertFalse(reopened, "用户核对过的版本不能被一次重试换掉")
    }

    /// 直接对库文件执行 SQL（模拟"库已经是旧形状"）。测试内用，sqlite3 系统库已链。
    private static func runSQL(on file: URL, statements: [String]) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let pointer else {
            XCTFail("打不开临时库文件：\(file.lastPathComponent)")
            return
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
