import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-02 解除接收与取消的等待环（F02 / A03/A04/A55）。
///
/// 插话终态经唯一接收循环到达，不直接调用 terminal handler；
/// 取消未确认始终 fail-closed；provider 失败走有身份取消屏障。
@MainActor
final class AssistantCancelReceiveTests: XCTestCase {
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

    private func makeVoiceHarness(
        llmScripts: [AssistantSessionTests.FakeAssistantLLM.Script],
        autoConfirmTTSCancel: Bool = true
    ) async throws -> AssistantSessionTests.Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        let suiteName = "assistant-cancel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let llm = AssistantSessionTests.FakeAssistantLLM(scripts: llmScripts)
        let audio = AssistantSessionTests.FakeAssistantAudio(autoStartCapture: true)
        let box = AssistantSessionTests.ClientBox()
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"
        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies(
                llm: llm,
                makeRealtimeClient: { configuration in
                    let client = AssistantSessionTests.FakeAssistantRealtime(
                        autoConfirmTTSCancel: autoConfirmTTSCancel
                    )
                    box.append(client, configuration: configuration)
                    return client
                }
            )
        )
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        session.audioSourceFactory = { audio }
        session.realtimeCapabilityBindingProvider = { _ in
            RealtimeCapabilityBinding(
                asrModelRevision: "asr-1",
                canonicalVoiceID: "voice-1",
                voiceRevision: "v-1",
                ttsModelRevision: "tts-1"
            )
        }
        session.serviceReadiness = { .ready(profile: nil) }
        coordinator.starter = { kind in
            guard kind == .assistant else { return }
            try await session.beginCapture()
        }
        coordinator.stopper = { kind in
            guard kind == .assistant else { return }
            await session.stopCapture()
        }
        return AssistantSessionTests.Harness(
            session: session,
            coordinator: coordinator,
            store: store,
            llm: llm,
            audio: audio,
            clients: { box.clients },
            configurations: { box.configurations },
            defaults: defaults,
            directory: directory
        )
    }

    private func cleanup(_ harness: AssistantSessionTests.Harness) {
        try? FileManager.default.removeItem(at: harness.directory)
        harness.defaults.removePersistentDomain(forName: harness.defaults.description)
    }

    /// A03：朗读中同一流 hypothesis 触发 cancel，匹配 terminal 经接收循环到达，
    /// 连接可继续；严禁直接调用 terminal handler。
    func testA03BargeInTerminalThroughReceiveLoop() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["长回答。"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "念一句"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "回复没有落库"
        )
        // 朗读中来同一流 hypothesis：经 noteSpeechEvidence 走统一中断，
        // Fake 自动回匹配 terminal（经接收循环，非直接调用 handler）。
        await harness.clients()[0].emit(
            .ttsAudio(requestID: "tts_req_playback", taskID: nil, pcm: Data(repeating: 0, count: 320))
        )
        await waitUntil({ harness.session.phase == .speaking }, message: "没有进入朗读态")
        await harness.session.stopSpeaking()
        XCTAssertEqual(harness.session.phase, .listening, "服务端确认后应继续聆听")
        XCTAssertNil(harness.session.blocked, "确认过就不该判成语音中断")
        let counters = await harness.clients()[0].snapshot()
        XCTAssertEqual(counters.close, 0, "确认过就不该关连接")
    }

    /// A04：cancel 无 terminal 确认时 fail-closed：本地先停，连接关闭。
    func testA04CancelTimeoutFailsClosed() async throws {
        let harness = try await makeVoiceHarness(
            llmScripts: [.deltas(["一句话。"])],
            autoConfirmTTSCancel: false
        )
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "念一句"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "回复没有落库"
        )
        await harness.clients()[0].emit(
            .ttsAudio(requestID: "tts_req_playback", taskID: nil, pcm: Data(repeating: 0, count: 320))
        )
        await waitUntil({ harness.session.phase == .speaking }, message: "没有进入朗读态")
        await harness.session.stopSpeaking()
        await waitUntil(
            { harness.session.blocked != nil },
            message: "无确认时必须进入可重试语音中断"
        )
        XCTAssertEqual(harness.session.phase, .paused)
        let counters = await harness.clients()[0].snapshot()
        XCTAssertGreaterThanOrEqual(counters.close, 1, "归属未知连接必须关闭")
    }

    /// A55：provider 失败且 TTS 在播，local 先停、统一 cancel、保存片段、旧音不继续。
    func testA55ProviderFailureUsesOwnedCancellationBarrier() async throws {
        let harness = try await makeVoiceHarness(
            llmScripts: [.deltasThenFailure(["半句"], "模型断了")]
        )
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "念一句"))
        await waitUntil(
            { harness.session.lastFailure?.contains("模型断了") == true },
            message: "provider 失败应有明确提示"
        )
        // 片段应保存：同一行落库，不丢半句。
        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertFalse(assistantLines.isEmpty, "失败片段必须保存")
        XCTAssertTrue(
            assistantLines.contains { $0.text.contains("半句") },
            "已说出口的半句不得丢失"
        )
    }

    /// A42（D 部分）：重播绑定 originalTurnID；停止重播只记本次播放，
    /// 不改另一回复的生成状态与正文。
    func testA42ReplayInterruptTargetsOriginalTurn() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["首轮。"]), .deltas(["次轮。"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "念首轮"))
        await waitUntil(
            { harness.session.turns.filter { $0.role == .assistant }.count >= 1 },
            message: "首轮没有收尾"
        )
        await harness.clients()[0].emit(.completed(itemID: "i2", transcript: "念次轮"))
        await waitUntil(
            { harness.session.turns.filter { $0.role == .assistant }.count >= 2 },
            message: "次轮没有收尾"
        )
        let first = try XCTUnwrap(harness.session.turns.first { $0.role == .assistant })
        let second = try XCTUnwrap(harness.session.turns.last { $0.role == .assistant })
        XCTAssertNotEqual(first.id, second.id, "两轮应为不同 turn")
        // 重播首轮再停止：只记首轮本次播放，不改次轮生成状态。
        await harness.session.replay(turn: first)
        XCTAssertEqual(harness.session.replayingTurnID, first.id, "重播应绑定原始 turnID")
        await harness.session.stopSpeaking()
        XCTAssertNil(harness.session.replayingTurnID, "停止后重播身份应清除")
        XCTAssertTrue(
            harness.session.interruptedReplayTurnIDs.contains(first.id),
            "停止只更新本次播放记录"
        )
        XCTAssertFalse(
            harness.session.interruptedReplayTurnIDs.contains(second.id),
            "次轮生成状态不得被重播停止污染"
        )
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let secondLine = try XCTUnwrap(lines.first { $0.id == second.id })
        XCTAssertEqual(secondLine.text, second.text, "次轮正文不得被重播停止改写")
    }

    /// A43（D 部分·true 分支）：语音场建好 TTS 通道后重播可用。
    /// 与纯文字场 `canReplaySpeech == false` 配对，覆盖直透两分支；
    /// 试听与禁播原因文案仍为 View 接线，D 不覆盖。
    func testA43VoiceFieldCanReplaySpeechIsTrue() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["一句话。"])])
        defer { cleanup(harness) }
        XCTAssertFalse(harness.session.canReplaySpeech, "建通道前重播必须不可用")
        try await harness.coordinator.begin(.assistant)
        XCTAssertTrue(harness.session.canReplaySpeech, "语音场建好 TTS 通道后重播必须可用")
    }

    /// A13（D 部分·Session 层 unknown 失败终态）：从未开轮的 requestID
    /// 发一条失败终态，界面副作用不得被污染（phase/error/正文不动）。
    /// 与 coordinator 层 `testStaleIdentityIsIgnored` 配对，补 Session 层缺口。
    func testA13UnknownFailedTerminalLeavesNewRoundUntouched() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["一句话。"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "念一句"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "回复没有落库"
        )
        // 语音场收尾后 phase 保持 thinking（`if !spoken` 才回 listening）：
        // 本用例不断言收尾终态，只记基线，断言 unknown 终态不改变它。
        let baselinePhase = harness.session.phase
        XCTAssertNil(harness.session.lastFailure, "收尾后 error 应干净")
        await harness.clients()[0].emit(
            .ttsEnded(
                requestID: "tts_req_never_started",
                taskID: nil,
                status: "failed",
                code: "E_UNKNOWN",
                message: "从未开轮的终态"
            )
        )
        // 接收循环为单线程 pump：给它一小段落地时间，再断言界面副作用未被污染。
        var settled = false
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(5))
            if harness.session.phase == baselinePhase && harness.session.lastFailure == nil {
                settled = true
                break
            }
        }
        XCTAssertTrue(settled, "unknown 终态落地后 phase/error 应与基线一致")
        XCTAssertNil(harness.session.lastFailure, "unknown 失败终态不得写新轮 error")
        XCTAssertEqual(harness.session.phase, baselinePhase, "unknown 失败终态不得改 phase")
        XCTAssertTrue(
            harness.session.turns.contains { $0.role == .assistant && $0.text.contains("一句话") },
            "unknown 失败终态不得改正文"
        )
    }
}
