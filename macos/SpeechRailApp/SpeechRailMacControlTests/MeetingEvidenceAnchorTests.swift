import Foundation
import SQLite3
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 结论条目与证据锚点（方案 MA-08 / §7.4）。
///
/// 钉的是"重要结论可定位到正确来源"这件事在**数据层**成立：
/// - 锚点指不可变的行修订，不是会变的 `line`——用户改转录后旧纪要仍指旧原文（MC-46）；
/// - 修订被删时锚点明确变成"来源不可读"，不拿当前 `line` 顶替；
/// - 正文、条目、锚点同生共死：迟到的旧执行者一条都不写。
@MainActor
final class MeetingEvidenceAnchorTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-evidence-anchor-\(UUID().uuidString)", isDirectory: true)
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

    private func unit(_ id: String, lineID: String, ordinal: Int, text: String) -> MinutesSourceUnit {
        MinutesSourceUnit(
            id: id,
            lineID: lineID,
            ordinal: ordinal,
            speaker: "张三",
            text: text,
            startSeconds: 0
        )
    }

    private func candidate(
        decisions: [MinutesCandidateV2.DecisionItem] = [],
        actions: [MinutesCandidateV2.ActionItem] = []
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

    private func decision(
        _ localID: String,
        _ text: String,
        units: [String],
        modality: MinutesDecisionModality = .decided
    ) -> MinutesCandidateV2.DecisionItem {
        .init(localID: localID, text: text, modality: modality, conditions: [], sourceUnitIDs: units)
    }

    /// 造一场有两句定稿、已封存的会议。
    private func prepareSealedMeeting() async throws -> (
        store: SessionStore,
        sessionID: String,
        snapshotID: String,
        units: [MinutesSourceUnit],
        revisionIDs: [String: String]
    ) {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let texts = ["line-1": "先完成灰度验证。", "line-2": "预算按 3 万元算。"]
        for id in ["line-1", "line-2"] {
            let text = texts[id]!
            _ = try await store.appendLine(
                LineDraft(sessionID: sessionID, role: .speaker, text: text, source: .microphone, status: .final),
                id: id
            )
        }
        let snapshot = try await store.sealMeetingSource(sessionID: sessionID)
        let snapshotID = try XCTUnwrap(snapshot?.id, "有定稿正文就该封出快照")
        let units = [
            unit("u1", lineID: "line-1", ordinal: 1, text: texts["line-1"]!),
            unit("u2", lineID: "line-2", ordinal: 2, text: texts["line-2"]!),
        ]
        let revisionIDs = try await store.latestRevisionIDsByLine(sessionID: sessionID)
        return (store, sessionID, snapshotID, units, revisionIDs)
    }

    /// 保存一版候选（含条目与锚点）。
    private func saveCandidate(
        store: SessionStore,
        minutesID: String,
        attempts: Int,
        candidate: MinutesCandidateV2,
        units: [MinutesSourceUnit],
        revisionIDs: [String: String],
        snapshotID: String?
    ) async throws -> Bool {
        let encoded = try JSONEncoder().encode(candidate)
        let prepared = MinutesCandidateCodec.prepare(
            text: String(data: encoded, encoding: .utf8) ?? "",
            units: units
        )
        guard case .prepared(let value) = prepared else {
            XCTFail("结构合法的候选应当解析成功")
            return false
        }
        let unitsByID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try await store.saveMinutesCandidate(
            minutesID: minutesID,
            expectedAttempts: attempts,
            body: value.body,
            model: nil,
            candidate: String(data: try JSONEncoder().encode(value.candidate), encoding: .utf8),
            review: String(data: try JSONEncoder().encode(value.report), encoding: .utf8),
            items: MinutesCandidateCodec.itemDrafts(
                for: value.candidate,
                report: value.report,
                unitsByID: unitsByID,
                revisionIDsByLine: revisionIDs
            ),
            snapshotID: snapshotID
        )
    }

    private func enqueueAndClaim(
        _ store: SessionStore,
        _ sessionID: String,
        snapshotID: String?
    ) async throws -> MinutesVersion {
        _ = try await store.enqueueMinutes(
            sessionID: sessionID,
            model: nil,
            promptChars: 32,
            snapshotID: snapshotID
        )
        let claimed = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        return try XCTUnwrap(claimed, "刚排队的这一版必须能认领")
    }

    // MARK: - 锚点落在不可变修订上

    /// 结论能定位到**封存那一刻**的原文：锚点指 revision，quote 读自修订。
    func testAnchorPointsAtSealedRevision() async throws {
        let context = try await prepareSealedMeeting()
        let claimed = try await enqueueAndClaim(context.store, context.sessionID, snapshotID: context.snapshotID)
        let saved = try await saveCandidate(
            store: context.store,
            minutesID: claimed.id,
            attempts: claimed.attempts,
            candidate: candidate(decisions: [decision("d1", "先做灰度验证。", units: ["u1"])]),
            units: context.units,
            revisionIDs: context.revisionIDs,
            snapshotID: context.snapshotID
        )
        XCTAssertTrue(saved)

        let items = try await context.store.minutesItems(minutesID: claimed.id)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.localID, "d1")
        XCTAssertEqual(item.kind, "decision")
        XCTAssertEqual(item.verdict, .supported)
        XCTAssertEqual(item.anchors.count, 1)

        let anchor = try XCTUnwrap(item.anchors.first)
        XCTAssertEqual(anchor.unitID, "u1")
        XCTAssertEqual(anchor.lineID, "line-1")
        XCTAssertEqual(anchor.snapshotID, context.snapshotID)
        XCTAssertEqual(anchor.quote, "先完成灰度验证。", "引文来自锚定的那一版原文")
        XCTAssertEqual(anchor.verification, "exact_source_match")
        XCTAssertEqual(
            anchor.revisionID,
            context.revisionIDs["line-1"],
            "锚点必须指不可变修订，而不是会变的 line"
        )
    }

    /// MC-46：用户改了转录，旧纪要的锚点仍然显示它当时依据的那一版原文。
    func testAnchorQuoteSurvivesTranscriptEdit() async throws {
        let context = try await prepareSealedMeeting()
        let claimed = try await enqueueAndClaim(context.store, context.sessionID, snapshotID: context.snapshotID)
        _ = try await saveCandidate(
            store: context.store,
            minutesID: claimed.id,
            attempts: claimed.attempts,
            candidate: candidate(decisions: [decision("d1", "先做灰度验证。", units: ["u1"])]),
            units: context.units,
            revisionIDs: context.revisionIDs,
            snapshotID: context.snapshotID
        )

        // 用户改了转录并重新封存（当前没有正文编辑入口，直接改库模拟）。
        try Self.runSQL(
            on: try XCTUnwrap(directory).appendingPathComponent(SessionStore.fileName),
            statements: ["UPDATE line SET text = '先做灰度，再看数据。' WHERE id = 'line-1';"]
        )
        _ = try await context.store.sealMeetingSource(sessionID: context.sessionID)

        let items = try await context.store.minutesItems(minutesID: claimed.id)
        let anchor = try XCTUnwrap(items.first?.anchors.first)
        XCTAssertEqual(anchor.quote, "先完成灰度验证。", "旧纪要的依据不能被后来的修改换掉")
    }

    /// 修订被删时锚点明确变成"来源不可读"，不拿当前 `line` 顶替。
    func testMissingRevisionLeavesAnchorWithoutQuote() async throws {
        let context = try await prepareSealedMeeting()
        let claimed = try await enqueueAndClaim(context.store, context.sessionID, snapshotID: context.snapshotID)
        _ = try await saveCandidate(
            store: context.store,
            minutesID: claimed.id,
            attempts: claimed.attempts,
            candidate: candidate(decisions: [decision("d1", "先做灰度验证。", units: ["u1"])]),
            units: context.units,
            revisionIDs: context.revisionIDs,
            snapshotID: context.snapshotID
        )

        try Self.runSQL(
            on: try XCTUnwrap(directory).appendingPathComponent(SessionStore.fileName),
            statements: ["DELETE FROM transcript_revision WHERE line_id = 'line-1';"]
        )

        let items = try await context.store.minutesItems(minutesID: claimed.id)
        let anchor = try XCTUnwrap(items.first?.anchors.first)
        XCTAssertNil(anchor.quote, "修订没了就说来源不可读，不拿当前行顶替")
        XCTAssertNil(anchor.revisionID)
    }

    // MARK: - 核对结论落库

    /// 被拒的条目：锚点为空、verdict 是 rejected——查得出"这条没通过引用核对"。
    func testRejectedItemIsStoredWithVerdictAndNoAnchor() async throws {
        let context = try await prepareSealedMeeting()
        let claimed = try await enqueueAndClaim(context.store, context.sessionID, snapshotID: context.snapshotID)
        _ = try await saveCandidate(
            store: context.store,
            minutesID: claimed.id,
            attempts: claimed.attempts,
            candidate: candidate(
                decisions: [decision("d1", "决定下周发布。", units: ["u9"])],
                actions: [
                    .init(localID: "a1", task: "补充文档", ownerText: nil, dueExpression: nil,
                          commitment: .proposed, sourceUnitIDs: ["u2"]),
                ]
            ),
            units: context.units,
            revisionIDs: context.revisionIDs,
            snapshotID: context.snapshotID
        )

        let items = try await context.store.minutesItems(minutesID: claimed.id)
        XCTAssertEqual(items.count, 2)
        let rejected = try XCTUnwrap(items.first { $0.localID == "d1" })
        XCTAssertEqual(rejected.verdict, .rejected)
        XCTAssertTrue(rejected.anchors.isEmpty, "引用不存在的来源单元就没有锚点")
        let action = try XCTUnwrap(items.first { $0.localID == "a1" })
        XCTAssertEqual(action.kind, "action")
        XCTAssertEqual(action.anchors.count, 1)
    }

    /// 一条上既有"引用不成立"又有"语气待核对"时，取最严重的那个。
    func testWorstVerdictWins() {
        let units = [unit("u1", lineID: "line-1", ordinal: 1, text: "我建议先做灰度看看效果。")]
        let subject = candidate(decisions: [decision("d1", "决定先做灰度。", units: ["u1", "u9"])])
        let report = MinutesEvidenceValidator.validate(candidate: subject, units: units)
        let drafts = MinutesCandidateCodec.itemDrafts(
            for: subject,
            report: report,
            unitsByID: ["u1": units[0]],
            revisionIDsByLine: [:]
        )
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.verdict, .rejected, "有引用不成立就不能算通过")
        XCTAssertEqual(drafts.first?.anchors.count, 1, "只给真实存在的来源单元建锚点")
    }

    // MARK: - 原子性

    /// 旧执行者迟到：条目与锚点一条都不写，正文也不改（MC-29）。
    func testLateOwnerWritesNoItems() async throws {
        let context = try await prepareSealedMeeting()
        let old = try await enqueueAndClaim(context.store, context.sessionID, snapshotID: context.snapshotID)
        // 先让租约到期，新 owner 才认领得到（否则行还在 running 且租约未过期）。
        let expired = try await context.store.renewMinutesLease(
            minutesID: old.id, expectedAttempts: old.attempts, lease: -1
        )
        XCTAssertTrue(expired)
        let reclaimed = try await context.store.claimMinutes(sessionID: context.sessionID, lease: -1)
        let new = try XCTUnwrap(reclaimed)
        XCTAssertNotEqual(old.attempts, new.attempts)

        let saved = try await saveCandidate(
            store: context.store,
            minutesID: old.id,
            attempts: old.attempts,
            candidate: candidate(decisions: [decision("d1", "迟到的结论。", units: ["u1"])]),
            units: context.units,
            revisionIDs: context.revisionIDs,
            snapshotID: context.snapshotID
        )
        XCTAssertFalse(saved, "旧代际不得发布")
        let items = try await context.store.minutesItems(minutesID: old.id)
        XCTAssertTrue(items.isEmpty, "旧执行者一条条目都不许留下")
        let stale = try await context.store.minutesVersion(id: old.id)
        XCTAssertNil(stale?.body)
    }

    /// 旧版本（没有结构化候选）读回来是空条目，不是"有条目但没来源"。
    func testLegacyMarkdownVersionHasNoItems() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let legacy = try await store.enqueueMinutes(sessionID: sessionID, model: nil, promptChars: 8)
        _ = try await store.claimMinutes(sessionID: sessionID, lease: 600)
        try await store.finishMinutesForTestOnly(minutesID: legacy.id, body: "# 旧版 Markdown 纪要", model: nil)

        let items = try await store.minutesItems(minutesID: legacy.id)
        XCTAssertTrue(items.isEmpty)
        let loaded = try await store.minutesVersion(id: legacy.id)
        let version = try XCTUnwrap(loaded)
        XCTAssertNil(version.candidateJSON, "旧纪要没有结构化候选，不补造")
        XCTAssertNil(version.review, "没有报告不等于核对通过")
    }

    // MARK: - 工具

    private static func runSQL(on file: URL, statements: [String]) {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let pointer else {
            return
        }
        defer { sqlite3_close_v2(pointer) }
        // 必须和 store 的连接一样开外键：`ON DELETE SET NULL` 只在**执行写操作的那个
        // 连接**开了外键时才生效。测试连接不开，就测不到生产里真实会发生的事。
        sqlite3_exec(pointer, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        for statement in statements {
            sqlite3_exec(pointer, statement, nil, nil, nil)
        }
    }
}
