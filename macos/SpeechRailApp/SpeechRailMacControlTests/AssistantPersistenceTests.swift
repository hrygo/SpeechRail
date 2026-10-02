import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 助手单轮回复的**持久终态**回归（D08 / 方案 S4）。
///
/// 这里钉的是库这一层的约束，不碰界面：
/// - 一次回复只有一行，行 id 由回复自己定，中途不换；
/// - 收尾只改正文/状态/打断标记，星标与建行时间不动；
/// - 重复收尾**不能**把已经写上的 `interrupted` 改回 false；
/// - 收尾必须校验 session 与 role，越权一律失败而不是静默成功；
/// - 异常退出封存时，助手残留的 partial 行要变成 final + interrupted，
///   而用户行与其他功能的 partial 规则不受影响。
@MainActor
final class AssistantPersistenceTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?
    private var sessionID: String?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-persistence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let record = try await store.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
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

    // MARK: - 夹具

    private func requireStore() throws -> SessionStore {
        try XCTUnwrap(store)
    }

    private func requireSessionID() throws -> String {
        try XCTUnwrap(sessionID)
    }

    private func appendAssistantPartial(id: String, text: String) async throws -> Int {
        let store = try requireStore()
        return try await store.appendLine(
            LineDraft(
                sessionID: try requireSessionID(),
                role: .assistant,
                text: text,
                source: .microphone,
                status: .partial
            ),
            id: id
        )
    }

    private func line(_ id: String, in target: String? = nil) async throws -> TranscriptLine {
        let store = try requireStore()
        let all = try await store.lines(sessionID: target ?? requireSessionID(), includePartial: true)
        return try XCTUnwrap(all.first { $0.id == id }, "库里没有 id=\(id) 这一行")
    }

    // MARK: - 收尾只动该动的列

    func testFinalizeUpdatesTextAndStatusAndKeepsIdentity() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let lineID = "reply-1"
        let ordinal = try await appendAssistantPartial(id: lineID, text: "开头")
        try await store.setLineStarred(lineID: lineID, starred: true)
        let createdBefore = try await line(lineID).createdAt

        let updated = try await store.finalizeAssistantLine(
            sessionID: sessionID,
            lineID: lineID,
            text: "开头，中间，结尾。",
            interrupted: false
        )

        let after = try await line(lineID)
        XCTAssertEqual(updated, ordinal, "收尾不重新分配序号")
        XCTAssertEqual(after.ordinal, ordinal)
        XCTAssertEqual(after.text, "开头，中间，结尾。")
        XCTAssertEqual(after.status, .final)
        XCTAssertFalse(after.isInterrupted)
        XCTAssertTrue(after.isStarred, "星标是用户写的，收尾不许抹掉")
        XCTAssertEqual(after.createdAt, createdBefore, "建行时间就是这一句开始的时刻，收尾不改")
    }

    /// D09 之后发言时间可能已经有真实值（历史记录、对齐过的行）。收尾只允许写
    /// `text` / `status` / `interrupted` 三列，**既有时间轴与来源不许被重算**。
    func testFinalizeNeverRewritesAnExistingTimeAxis() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let lineID = "reply-timed"
        _ = try await store.appendLine(
            LineDraft(
                sessionID: sessionID,
                role: .assistant,
                text: "有时间轴的一句",
                source: .microphone,
                tStart: 12.5,
                tEnd: 15.25,
                status: .partial
            ),
            id: lineID
        )
        let before = try await line(lineID)
        XCTAssertEqual(before.tStart, 12.5)
        XCTAssertEqual(before.tEnd, 15.25)

        try await store.finalizeAssistantLine(
            sessionID: sessionID,
            lineID: lineID,
            text: "有时间轴的一句，说完了。",
            interrupted: false
        )

        let after = try await line(lineID)
        XCTAssertEqual(after.tStart, 12.5, "收尾不许重算发言起点")
        XCTAssertEqual(after.tEnd, 15.25, "收尾不许重算发言终点")
        XCTAssertEqual(after.timingQuality, before.timingQuality, "时轴质量标记也不许被收尾改写")
        XCTAssertEqual(after.source, before.source, "来源是既有事实，收尾不许改")
    }

    // MARK: - 幂等与不可逆的打断标记

    func testRepeatedFinalizeNeverClearsInterrupted() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let lineID = "reply-2"
        try await appendAssistantPartial(id: lineID, text: "说到一半")

        try await store.finalizeAssistantLine(
            sessionID: sessionID,
            lineID: lineID,
            text: "说到一半",
            interrupted: true
        )
        // 迟到的"正常完成"路径：文本可以补全，但打断标记只能朝前走。
        try await store.finalizeAssistantLine(
            sessionID: sessionID,
            lineID: lineID,
            text: "说到一半，其实说完了",
            interrupted: false
        )

        let after = try await line(lineID)
        XCTAssertTrue(after.isInterrupted, "已经写上的打断标记不能被旧的成功路径改回 false")
        XCTAssertEqual(after.text, "说到一半，其实说完了")
        XCTAssertEqual(after.status, .final)
    }

    func testFinalizeOnMissingRowFailsInsteadOfSilentlySucceeding() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        var caught: Error?
        do {
            _ = try await store.finalizeAssistantLine(
                sessionID: sessionID,
                lineID: "never-inserted",
                text: "凭空出现的正文",
                interrupted: true
            )
        } catch {
            caught = error
        }
        XCTAssertEqual(
            caught as? SessionStoreError,
            .statementFailed("这一行不属于本记录"),
            "0 行受影响必须报错，不能当成保存成功"
        )
    }

    // MARK: - 越权保护

    func testFinalizeRefusesAnotherSession() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let otherID = try await store.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        ).id
        let lineID = "reply-3"
        let ordinal = try await store.appendLine(
            LineDraft(
                sessionID: otherID,
                role: .assistant,
                text: "别场的话",
                source: .microphone,
                status: .partial
            ),
            id: lineID
        )
        XCTAssertGreaterThan(ordinal, 0)

        var threw = false
        do {
            _ = try await store.finalizeAssistantLine(
                sessionID: sessionID,
                lineID: lineID,
                text: "被别的记录改掉了",
                interrupted: true
            )
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "跨记录的收尾必须失败")

        let untouched = try await line(lineID, in: otherID)
        XCTAssertEqual(untouched.text, "别场的话", "跨记录的收尾必须完全无效")
        XCTAssertEqual(untouched.status, .partial)
    }

    func testFinalizeRefusesUserLine() async throws {
        let store = try requireStore()
        let lineID = "user-1"
        try await store.appendLine(
            LineDraft(
                sessionID: try requireSessionID(),
                role: .user,
                text: "我说的",
                source: .microphone,
                status: .partial
            ),
            id: lineID
        )

        var threw = false
        do {
            _ = try await store.finalizeAssistantLine(
                sessionID: try requireSessionID(),
                lineID: lineID,
                text: "被当成助手回复收尾了",
                interrupted: true
            )
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "用户行不归助手收尾这条路管")

        let untouched = try await line(lineID)
        XCTAssertEqual(untouched.text, "我说的")
        XCTAssertEqual(untouched.status, .partial)
    }

    // MARK: - 异常退出封存

    func testSealAbandonedSessionsFinalizesOnlyAssistantPartials() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        let assistantPartial = "reply-4"
        let userPartial = "user-2"
        try await appendAssistantPartial(id: assistantPartial, text: "崩之前写到这")
        try await store.appendLine(
            LineDraft(
                sessionID: sessionID,
                role: .user,
                text: "崩之前的提问",
                source: .microphone,
                status: .partial
            ),
            id: userPartial
        )
        let count = try await store.sessionCount()
        XCTAssertEqual(count, 1)

        let sealed = try await store.sealAbandonedSessions()

        XCTAssertEqual(sealed, [sessionID])
        let assistantLine = try await line(assistantPartial)
        XCTAssertEqual(assistantLine.status, .final, "助手残留的 partial 必须被封成 final")
        XCTAssertTrue(assistantLine.isInterrupted, "没走完的助手回复按打断封存")
        XCTAssertEqual(assistantLine.text, "崩之前写到这", "已经写下的正文要留下来")
        let userLine = try await line(userPartial)
        XCTAssertEqual(userLine.status, .partial, "用户行的 partial 规则不归助手收尾管")
    }

    func testSealAbandonedSessionsLeavesFinalizedAssistantLinesAlone() async throws {
        let store = try requireStore()
        let lineID = "reply-5"
        try await appendAssistantPartial(id: lineID, text: "正常说完的")
        try await store.finalizeAssistantLine(
            sessionID: try requireSessionID(),
            lineID: lineID,
            text: "正常说完的。",
            interrupted: false
        )

        _ = try await store.sealAbandonedSessions()

        let after = try await line(lineID)
        XCTAssertEqual(after.status, .final)
        XCTAssertFalse(after.isInterrupted, "已经正常收尾的行不该被补上打断标记")
    }

    func testSealAbandonedSessionsDoesNotDisturbOtherKinds() async throws {
        let store = try requireStore()
        let meetingID = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "unknown", audioSource: .system)
        ).id
        let speakerLine = "speaker-1"
        try await store.appendLine(
            LineDraft(
                sessionID: meetingID,
                role: .speaker,
                text: "别人说的话",
                source: .microphone,
                status: .partial
            ),
            id: speakerLine
        )

        _ = try await store.sealAbandonedSessions()

        let after = try await line(speakerLine, in: meetingID)
        XCTAssertEqual(after.status, .partial, "会议的说话人 partial 不受助手封存影响")
    }

    // MARK: - 回看快照：一次读完，四份数据与分别读一致

    /// `reviewSnapshot` 是给"翻一条记录"用的一次性快照。它存在的理由是把
    /// 4 次串行 `await` 收成 1 次，所以它**必须**和分别读给出同一份结果——
    /// 否则界面一次到位显示的是一份和库里对不上的内容。
    func testReviewSnapshotMatchesFourSeparateReads() async throws {
        let store = try requireStore()
        let sessionID = try requireSessionID()
        try await store.updateSessionTitle(id: sessionID, title: "今天聊了天气")
        try await store.renameSpeaker(sessionID: sessionID, label: "S1", name: "我")
        try await store.noteVoiceChange(
            sessionID: sessionID,
            atOrdinal: 2,
            voice: VoiceSnapshot(id: "v2", name: "温柔讲解")
        )
        try await store.appendLine(
            LineDraft(
                sessionID: sessionID,
                role: .user,
                text: "今天天气怎么样",
                source: .microphone,
                speakerLabel: "S1"
            )
        )
        try await store.appendLine(
            LineDraft(
                sessionID: sessionID,
                role: .assistant,
                text: "今天晴，最高 28 度。",
                source: .microphone
            )
        )
        // 未定稿的行：回看与导出只认已定稿行，快照也不该把它带进来。
        try await store.appendLine(
            LineDraft(
                sessionID: sessionID,
                role: .user,
                text: "这句没能定稿",
                source: .microphone,
                status: .partial
            )
        )

        let loaded = try await store.reviewSnapshot(sessionID: sessionID)
        let snapshot = try XCTUnwrap(loaded, "记录明明在库里，快照却读不到")

        // 四个字段逐一与"分别读"比对：快照存在的理由是一次到位，
        // 不是可以读出不一样的内容。`XCTAssertEqual` 的参数是 autoclosure，
        // await 必须先落到局部值。
        let record = try await store.session(id: sessionID)
        let lines = try await store.lines(sessionID: sessionID)
        let speakerNames = try await store.speakerNames(sessionID: sessionID)
        let voiceChanges = try await store.voiceChanges(sessionID: sessionID)
        XCTAssertEqual(snapshot.record, record)
        XCTAssertEqual(snapshot.lines, lines)
        XCTAssertEqual(snapshot.speakerNames, speakerNames)
        XCTAssertEqual(snapshot.voiceChanges, voiceChanges)

        XCTAssertEqual(snapshot.record.title, "今天聊了天气")
        XCTAssertEqual(snapshot.lines.count, 2, "回看只认已定稿行")
        XCTAssertEqual(snapshot.speakerNames["S1"], "我")
        XCTAssertEqual(snapshot.voiceChanges.first?.value, "v2|温柔讲解")
    }

    func testReviewSnapshotOfAnUnknownSessionIsNil() async throws {
        let store = try requireStore()
        let snapshot = try await store.reviewSnapshot(sessionID: "不存在的记录")
        XCTAssertNil(snapshot, "读不到记录时与 `session(id:)` 一样返回 nil，不返回空快照")
    }
}
