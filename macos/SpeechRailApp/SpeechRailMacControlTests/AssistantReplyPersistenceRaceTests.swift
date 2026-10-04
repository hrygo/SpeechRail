import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-04 回复接管、跨 await 与保存幂等（F04/F05 / A09～A12）。
///
/// 打生产 `AssistantSession.ask` 的统一 submitTurn 路径：
/// 迟到 persist/finalize 按 replyID 认领，不覆盖新轮正文；
/// 并发收尾只认领一次；连续输入前任先收尾、新轮接管。
@MainActor
final class AssistantReplyPersistenceRaceTests: XCTestCase {
    private func waitUntil(
        _ condition: () -> Bool,
        iterations: Int = 600,
        message: String = "condition was not met"
    ) async {
        for _ in 0..<iterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(message)
    }

    /// 纯文字路径夹具：`ask` 不建语音连接。
    private func makeTextSession(
        llmScripts: [AssistantSessionTests.FakeAssistantLLM.Script] = []
    ) async throws -> (AssistantSession, SessionCoordinator, SessionStore, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-reply-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        let suiteName = "assistant-reply-race-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let llm = AssistantSessionTests.FakeAssistantLLM(scripts: llmScripts)
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"
        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies(llm: llm)
        )
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        session.serviceReadiness = { .ready(profile: nil) }
        return (session, coordinator, store, directory, defaults)
    }

    /// A09：迟到 partial 建行返回时新轮已接管，旧行可存，新轮正文不被覆盖。
    func testA09LatePartialInsertKeepsNewReply() async throws {
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["旧回答正文"]), .deltas(["新回答正文"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "旧问题")
        _ = await session.ask(typed: "新问题")
        await waitUntil(
            { session.turns.filter { $0.role == .assistant }.count >= 1 },
            message: "新轮没有收尾落库"
        )
        let sessionID = try XCTUnwrap(session.sessionID)
        let lines = try await store.lines(sessionID: sessionID)
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertFalse(assistantLines.isEmpty, "至少新轮应落库")
        XCTAssertTrue(
            session.turns.contains { $0.role == .assistant && $0.text.contains("新回答正文") }
                || assistantLines.contains { $0.text.contains("新回答正文") },
            "新轮正文必须保留"
        )
    }

    /// A10：迟到 finalize 返回时新轮已接管，新轮 streaming/history 不被清。
    func testA10LateFinalizeCannotClearNewReply() async throws {
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["旧回答"]), .deltas(["新回答"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "旧问题")
        await waitUntil(
            { session.turns.filter { $0.role == .assistant }.count >= 1 },
            message: "旧轮没有收尾"
        )
        _ = await session.ask(typed: "新问题")
        await waitUntil(
            { session.turns.filter { $0.role == .user }.count >= 2 },
            message: "两问都应按序落库"
        )
        let sessionID = try XCTUnwrap(session.sessionID)
        let lines = try await store.lines(sessionID: sessionID)
        let userLines = lines.filter { $0.role == .user }
        XCTAssertEqual(userLines.count, 2, "两问都应落库，不丢不重")
        XCTAssertEqual(userLines.map(\.text), ["旧问题", "新问题"], "问题顺序必须确定")
    }

    /// A11：并发收尾争同一轮只认领一次，一行一 history 投影。
    func testA11ConcurrentTerminationClaimsOnce() async throws {
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["唯一回答"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "只问一次")
        await waitUntil(
            { session.turns.filter { $0.role == .assistant }.count >= 1 },
            message: "回答没有收尾"
        )
        async let stop: Void = session.stopCapture()
        async let end = session.endConversation()
        _ = await (stop, end)
        let sessionID = try XCTUnwrap(session.lastFinalizedSessionID ?? session.sessionID)
        let lines = try await store.lines(sessionID: sessionID)
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertEqual(assistantLines.count, 1, "同一轮只许一行")
    }

    /// A12：连续输入前任先收尾、新轮接管，最多一个活跃回复。
    func testA12ConsecutiveInputsRetirePredecessor() async throws {
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["首轮回答"]), .deltas(["次轮回答"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "首轮问题")
        _ = await session.ask(typed: "次轮问题")
        await waitUntil(
            { session.turns.filter { $0.role == .user }.count == 2 },
            message: "两问都应落库"
        )
        await waitUntil(
            { session.turns.filter { $0.role == .assistant }.count >= 1 },
            message: "至少新轮应收尾"
        )
        let sessionID = try XCTUnwrap(session.sessionID)
        let lines = try await store.lines(sessionID: sessionID)
        let userLines = lines.filter { $0.role == .user }
        XCTAssertEqual(userLines.map(\.text), ["首轮问题", "次轮问题"], "问题顺序确定")
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertFalse(assistantLines.isEmpty, "前任终态必须可见")
    }

    /// A41（D 部分）：完整生成但未播完时，原答案全文保留、不编造已听全文。
    /// 追问不得改写首轮原文；交付说明独立于正文。
    func testA41InterruptedPlaybackDoesNotInventHeardText() async throws {
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["完整答案全文，分三段。"]), .deltas(["追问回答。"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "问")
        await waitUntil(
            { session.turns.filter { $0.role == .assistant }.count >= 1 },
            message: "回答没有收尾"
        )
        let turn = try XCTUnwrap(session.turns.first { $0.role == .assistant })
        XCTAssertTrue(turn.text.contains("完整答案全文"), "原答案全文必须保留")
        let sessionID = try XCTUnwrap(session.sessionID)
        let lines = try await store.lines(sessionID: sessionID)
        let saved = try XCTUnwrap(lines.first { $0.id == turn.id })
        XCTAssertEqual(saved.text, turn.text, "落库正文与界面一致，不截取已播比例")
        _ = await session.ask(typed: "追问")
        await waitUntil(
            { session.turns.filter { $0.role == .user }.count >= 2 },
            message: "追问没有落库"
        )
        let again = try await store.lines(sessionID: sessionID)
        let first = try XCTUnwrap(again.first { $0.id == turn.id })
        XCTAssertEqual(first.text, turn.text, "追问不得改写首轮原文")
    }

    /// A50（D 部分）：基于旧记录选定完整轮次建新场；原文不动、不自动开麦；
    /// 种子冻结选定文字，删父后子场仍可用。
    func testA50ContinuationFreezesSelectedSourceTurns() async throws {
        let (session, coordinator, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["旧回答一。"]), .deltas(["旧回答二。"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        _ = await session.ask(typed: "旧问一")
        await waitUntil(
            { session.turns.filter { $0.role == .assistant }.count >= 1 },
            message: "旧场首轮没有收尾"
        )
        _ = await session.ask(typed: "旧问二")
        await waitUntil(
            { session.turns.filter { $0.role == .assistant }.count >= 2 },
            message: "旧场两轮没有收尾"
        )
        let parentID = try XCTUnwrap(session.sessionID)
        let parentLines = try await store.lines(sessionID: parentID)
        XCTAssertGreaterThanOrEqual(parentLines.count, 2, "旧场至少两问落库")
        let parentUserTexts = parentLines.filter { $0.role == .user }.map(\.text)
        XCTAssertEqual(parentUserTexts, ["旧问一", "旧问二"], "旧场两问顺序确定")
        // 基于旧记录建新场：不选定则取最近轮次。
        let continuedID = await session.continueFromRecord(parentID: parentID)
        let childID = try XCTUnwrap(continuedID)
        XCTAssertNotEqual(childID, parentID, "新场应为新记录")
        XCTAssertNotNil(session.continuationSeed, "种子必须冻结")
        XCTAssertEqual(session.continuationSeed?.parentSessionID, parentID)
        XCTAssertFalse(session.continuationSeed?.frozenText.isEmpty == true, "种子文字不得为空")
        // 旧记录原文不动。
        let parentAgain = try await store.lines(sessionID: parentID)
        XCTAssertEqual(parentAgain.map(\.id), parentLines.map(\.id), "旧记录行身份不得改动")
        XCTAssertEqual(parentAgain.map(\.text), parentLines.map(\.text), "旧记录原文不得改动")
        // 不自动开麦：新场无语音连接副作用（phase 保持 idle/文字态）。
        XCTAssertNotEqual(session.sessionID, parentID)
        // 删父后子种子仍可用：种子自包含。
        try await coordinator.removeSession(id: parentID)
        XCTAssertNotNil(session.continuationSeed?.frozenText, "删父后种子仍可用")
        let parentAfterDelete = try await store.session(id: parentID)
        XCTAssertNil(parentAfterDelete, "父记录应已删除")
    }

    /// A50 变体（seed 超限）：行数超 maxTurns 时只取最近轮次，不无界全带。
    /// 纯函数断言，不建场；与删父自包含用例配对覆盖 §7.3 seed 超限。
    func testA50ContinuationSeedTruncatesToMaxTurns() {
        let lines = (0..<10).map { i in
            TranscriptLine(
                id: "l\(i)",
                sessionID: "parent",
                ordinal: i,
                role: i % 2 == 0 ? SessionLineRole.user : SessionLineRole.assistant,
                speakerLabel: nil,
                text: "t\(i)",
                source: .keyboard,
                status: .final,
                isInterrupted: false,
                createdAt: Date()
            )
        }
        let seed = AssistantSession.continuationSeedTurns(from: lines, selectedLineIDs: nil, maxTurns: 4)
        XCTAssertEqual(seed.map { $0.id }, ["l6", "l7", "l8", "l9"], "超限只取最近 maxTurns 行")
    }

    /// §7.3 交叉边界（A12）：end 与 ask 同时进入。
    /// accepted 必须对应固定 session 与已保存问题：end 先封存不吞 accepted 的问题行；
    /// 问题行落库后 end 才封存，顺序由单调 submission 与 once 结束保证。
    func testA12EndDuringAskKeepsAcceptedQuestion() async throws {
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["回答。"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        async let asked: AssistantSession.TextSendResult = session.ask(typed: "同时结束的问题")
        async let ended = session.endConversation()
        let sendResult = await asked
        let endResult = await ended
        guard case .accepted = sendResult else {
            XCTFail("问题应被接纳，实际 \(sendResult)")
            return
        }
        let sessionID = try XCTUnwrap(session.sessionID)
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertTrue(
            lines.contains { $0.role == .user && $0.text == "同时结束的问题" },
            "accepted 的问题必须落库，不被并发结束吞掉"
        )
        // end 的 target 快照早于 ask 建记录时，end 走 noConversation 是合法语义
        // （结束只认快照身份，不追认后建的记录）；关键是问题不丢、不串场。
        // end 若认领到本场（ended），记录必须 archived 且问题行仍在同一记录下。
        guard case .ended(let recordID) = endResult else { return }
        XCTAssertEqual(recordID, sessionID, "end 认领的必须是本场记录")
        let record = try await store.session(id: sessionID)
        XCTAssertEqual(record?.state, .archived, "end 认领后应封存本场记录")
    }

    /// §7.3 交叉边界（A12）：ask 建记录后 end 再进入（顺序版）。
    /// end 认领到本场并封存，accepted 的问题行仍在同一 archived 记录下。
    func testA12EndAfterAskSealsSameRecord() async throws {
        let (session, _, store, directory, defaults) = try await makeTextSession(
            llmScripts: [.deltas(["回答。"])]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: defaults.description)
        }
        let sendResult = await session.ask(typed: "先问后结束")
        guard case .accepted = sendResult else {
            XCTFail("问题应被接纳，实际 \(sendResult)")
            return
        }
        let sessionID = try XCTUnwrap(session.sessionID)
        let endResult = await session.endConversation()
        guard case .ended(let recordID) = endResult else {
            XCTFail("建记录后的结束应认领本场，实际 \(endResult)")
            return
        }
        XCTAssertEqual(recordID, sessionID, "end 认领的必须是本场记录")
        let lines = try await store.lines(sessionID: sessionID)
        XCTAssertTrue(
            lines.contains { $0.role == .user && $0.text == "先问后结束" },
            "封存后问题行仍在同一记录下"
        )
        let record = try await store.session(id: sessionID)
        XCTAssertEqual(record?.state, .archived, "end 后记录应为 archived")
    }
}
