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
    private actor SaveControl {
        var failing = true
        func allowWrites() { failing = false }
        func write(_ draft: LineDraft, id: String, store: SessionStore) async throws -> Int {
            if failing { throw AssistantSessionTests.FakeAssistantError.llm("测试保存失败") }
            return try await store.appendLine(draft, id: id)
        }
    }
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
        autoConfirmTTSCancel: Bool = true,
        inputSaveGate: AssistantSessionTests.Gate? = nil,
        typedSaveGate: AssistantSessionTests.Gate? = nil,
        saveControl: SaveControl? = nil,
        inputConfiguration: AssistantInputPersistenceQueue.Configuration = .init()
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
                },
                saveInputLine: { draft, id in
                    if let inputSaveGate { await inputSaveGate.enter() }
                    if draft.source == .keyboard, let typedSaveGate { await typedSaveGate.enter() }
                    if let saveControl { return try await saveControl.write(draft, id: id, store: store) }
                    return try await store.appendLine(draft, id: id)
                },
                inputPersistenceConfiguration: inputConfiguration
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

    func testSavingUserInputDoesNotBlockReceiverOrStartProviderEarly() async throws {
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["回答"])], inputSaveGate: gate)
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.completed(itemID: "saved-1", transcript: "问题"))
        await waitUntil({ gate.entered }, message: "输入保存 seam 没有被调用")
        await harness.clients()[0].emit(.partial(itemID: "next-1", delta: "下一句"))
        await waitUntil({ harness.session.partialText == "下一句" }, message: "保存未完成时 receiver 应继续处理控制事件")
        let before = await harness.llm.streamCount
        XCTAssertEqual(before, 0, "保存成功之前不得把问题发送给 provider")
        gate.release()
        await waitUntil({ harness.session.turns.contains { $0.role == .user && $0.text == "问题" } })
    }

    func testPartialDoesNotTakeTheFirstFormalUserTitle() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["回答"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let recordID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.partial(itemID: "unfinished", delta: "半句"))
        await harness.clients()[0].emit(.completed(itemID: "unfinished", transcript: ""))
        await waitUntil({ harness.session.turns.contains { $0.text == "半句" } })
        await harness.clients()[0].emit(.completed(itemID: "formal", transcript: "正式问题"))
        await waitUntil({ harness.session.turns.contains { $0.text == "正式问题" } })
        await waitUntil({ harness.session.turns.contains { $0.role == .assistant } })
        let snapshot = try await harness.store.reviewSnapshot(sessionID: recordID)
        XCTAssertEqual(snapshot?.record.title, "正式问题")
    }

    func testLatestVoiceBindingWinsWhenOlderSelectionReturnsLate() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["回答。"])])
        let gate = AssistantSessionTests.Gate()
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        harness.session.realtimeCapabilityBindingProvider = { voice in
            if voice == "B" { await gate.enter() }
            return RealtimeCapabilityBinding(
                asrModelRevision: "asr-1", canonicalVoiceID: voice ?? "A",
                voiceRevision: "revision-\(voice ?? "A")", ttsModelRevision: "tts-1"
            )
        }
        let first = Task { await harness.session.changeVoice(to: "B") }
        await waitUntil({ gate.entered })
        let latest = Task { await harness.session.changeVoice(to: "C") }
        // C 应在意图登记时立即可见；旧 binding 不该覆盖后来选择。
        await waitUntil({ harness.session.voiceID == "C" })
        gate.release()
        await first.value
        await latest.value
        XCTAssertEqual(harness.session.voiceID, "C")
        await harness.clients()[0].emit(.completed(itemID: "voice-next", transcript: "请朗读"))
        await waitUntil({ harness.session.turns.contains { $0.role == .assistant } })
        let voices = await harness.clients()[0].startedVoices
        let startedVoice = voices.last ?? nil
        XCTAssertEqual(startedVoice?.voice, "C", "必须观察 client 实际 start 参数")
        XCTAssertEqual(startedVoice?.voiceRevision, "revision-C")
    }

    func testAcceptedVoiceIsRecordedWhenInterruptedBeforeStartReturns() async throws {
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["开口后被打断。"])])
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let recordID = try XCTUnwrap(harness.session.sessionID)
        await harness.session.changeVoice(to: "voice-1", name: "测试音色")
        let client = harness.clients()[0]
        await client.setTTSStartReturnGate(gate)
        await client.emit(.completed(itemID: "start-race", transcript: "念一句"))
        await waitUntil({ gate.entered })
        // started 已发到 receiver，sendStart 仍卡住；marker 确保 started 已被归约。
        await client.emit(.failed(itemID: "marker", code: "marker", message: ""))
        await waitUntil({ harness.session.lastFailure?.contains("marker") == true })
        await harness.session.stopSpeaking()
        let lines = try await harness.store.lines(sessionID: recordID)
        let reply = try XCTUnwrap(lines.first { $0.role == .assistant })
        let changes = try await harness.store.voiceChanges(sessionID: recordID)
        XCTAssertEqual(changes.count, 1, "started 已接受的真实 request 不能漏掉音色登记")
        XCTAssertEqual(changes.first?.atOrdinal, reply.ordinal)
        gate.release()
    }

    func testClosingVoiceFinalizesPartialReplyBeforeContinuingWithText() async throws {
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(
            llmScripts: [.gatedDeltas(["已生成的原文"], gate), .deltas(["文字回答"])]
        )
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let recordID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.completed(itemID: "close-voice", transcript: "先说一句"))
        await waitUntil({ gate.entered && harness.session.streamingReply == "已生成的原文" })
        await harness.session.closeVoiceKeepingText()
        let lines = try await harness.store.lines(sessionID: recordID, includePartial: true)
        let reply = try XCTUnwrap(lines.first { $0.role == .assistant })
        XCTAssertEqual(reply.status, .final)
        XCTAssertTrue(reply.isInterrupted)
        _ = await harness.session.ask(typed: "继续打字")
        await waitUntil({ harness.session.turns.contains { $0.text == "文字回答" } })
        let requests = await harness.llm.requests
        XCTAssertTrue(requests.last?.messages.contains { $0.role == .assistant && $0.text == "已生成的原文" } == true)
        XCTAssertTrue(requests.last?.messages.contains { $0.role == .developer && $0.text.contains("生成被打断") } == true)
    }

    func testPlaybackEnqueueWaitDoesNotBlockRealReceiverControlEvents() async throws {
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["朗读正文。"])])
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        harness.audio.setPlaybackEnqueueGate(gate)
        let client = harness.clients()[0]
        await client.emit(.completed(itemID: "pcm-wait", transcript: "念一句"))
        await waitUntil({ harness.session.turns.contains { $0.role == .assistant } })
        let activeID = await client.currentTTSRequestID()
        let requestID = try XCTUnwrap(activeID)
        await client.emit(.ttsAudio(requestID: requestID, taskID: nil, pcm: Data(repeating: 0, count: 320)))
        await waitUntil({ gate.entered })
        await client.emit(.ttsEnded(requestID: requestID, taskID: nil, status: "completed", code: nil, message: nil))
        await client.emit(.failed(itemID: "marker", code: "marker", message: ""))
        await waitUntil({ harness.session.lastFailure?.contains("marker") == true },
                        message: "实际 receiver 不能等待音频入队后才处理控制事件")
        XCTAssertEqual(harness.session.phase, .speaking, "terminal 到达但在途音频未消费不能提前完成")
        gate.release()
        let epoch = try XCTUnwrap(harness.audio.enqueuedEpochs.first)
        harness.audio.render(samples: 160, epoch: epoch)
        await waitUntil({ harness.session.phase == .listening })
    }

    func testRetrySupersedingVoiceCloseRestoresUploadAndDisconnectHandling() async throws {
        let harness = try await makeVoiceHarness(
            llmScripts: [.deltas(["朗读正文。"])], autoConfirmTTSCancel: false
        )
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let oldClient = harness.clients()[0]
        await oldClient.emit(.completed(itemID: "close-retry", transcript: "念一句"))
        await waitUntil({ harness.session.turns.contains { $0.role == .assistant } })
        let close = Task { await harness.session.closeVoiceKeepingText() }
        for _ in 0..<600 {
            if await oldClient.snapshot().cancelTTS > 0 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let oldCounters = await oldClient.snapshot()
        XCTAssertGreaterThan(oldCounters.cancelTTS, 0, "关闭应已进入取消确认等待")
        await harness.session.retry()
        await close.value
        XCTAssertEqual(harness.clients().count, 2)
        guard let newClient = harness.clients().last else { return XCTFail("没有重连 client") }
        harness.audio.emitCapture(AudioChunk(pcm: Data([1, 2, 3, 4]), level: 0.5))
        for _ in 0..<600 {
            if await newClient.snapshot().append > 0 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let newCounters = await newClient.snapshot()
        XCTAssertGreaterThan(newCounters.append, 0, "旧关闭意图不能永久抑制新连接上传")
        await newClient.emit(.closed(code: 1006))
        await waitUntil({ harness.session.blocked != nil }, message: "新连接的真实断连不能被旧关闭意图吞掉")
    }

    func testActualProviderRequestUsesOutputBudgetAndCurrentQuestionOnce() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["回答"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.completed(itemID: "question-1", transcript: "当前问题"))
        await waitUntil({ harness.session.turns.contains { $0.role == .assistant } })
        let requests = await harness.llm.requests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.maxOutputTokens, 1_024)
        XCTAssertEqual(request.messages.filter { $0.role == .user && $0.text == "当前问题" }.count, 1)
        XCTAssertFalse(request.instructions?.isEmpty ?? true)
    }

    func testQueuedInputsSaveOnceInArrivalOrderAndEndWaitsForThem() async throws {
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(llmScripts: [], inputSaveGate: gate)
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let recordID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.completed(itemID: "q1", transcript: "一"))
        await waitUntil({ gate.entered })
        await harness.clients()[0].emit(.completed(itemID: "q1", transcript: "一"))
        await harness.clients()[0].emit(.completed(itemID: "q2", transcript: "二"))
        await harness.clients()[0].emit(.completed(itemID: "q3", transcript: "三"))
        await harness.clients()[0].emit(.failed(itemID: "marker", code: "marker", message: ""))
        await waitUntil({ harness.session.lastFailure?.contains("marker") == true })
        let ending = Task { await harness.session.endConversation() }
        await waitUntil({ harness.session.phase == .ending })
        let before = try await harness.store.session(id: recordID)
        XCTAssertNotEqual(before?.state, .archived, "保存还在飞时不得封存")
        gate.release()
        _ = await ending.value
        let lines = try await harness.store.lines(sessionID: recordID)
        XCTAssertEqual(lines.filter { $0.role == .user }.map(\.text), ["一", "二", "三"])
        let after = try await harness.store.session(id: recordID)
        XCTAssertEqual(after?.state, .archived)
        let calls = await harness.llm.streamCount
        XCTAssertEqual(calls, 0, "已进入 draining 的队列只能归档")
    }

    func testFailedInputStaysRecoverableAndCannotBeSealedAsSaved() async throws {
        let control = SaveControl()
        let harness = try await makeVoiceHarness(llmScripts: [], saveControl: control)
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let recordID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.completed(itemID: "retry-q", transcript: "保留问题"))
        await waitUntil({ harness.session.lastFailure?.contains("测试保存失败") == true })
        let result = await harness.session.endConversation()
        XCTAssertEqual(result, .noConversation)
        XCTAssertEqual(harness.session.pendingSealRecordID, recordID)
        XCTAssertTrue(harness.session.unsavedTranscriptText().contains("保留问题"))
        let unsaved = try await harness.store.session(id: recordID)
        XCTAssertNotEqual(unsaved?.state, .archived)
        await control.allowWrites()
        let recovered = await harness.session.retryPendingSeal()
        XCTAssertTrue(recovered)
        let lines = try await harness.store.lines(sessionID: recordID)
        XCTAssertEqual(lines.filter { $0.role == .user }.map(\.text), ["保留问题"])
        let calls = await harness.llm.streamCount
        XCTAssertEqual(calls, 0, "旧记录恢复不得发起新的回答")
    }

    func testFailedReplyKeepsOriginalTextAndGenerationStatusInNextActualRequest() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltasThenFailure(["原始片段"], "provider故障"), .deltas(["新的回答"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let first = await harness.session.ask(typed: "第一个问题")
        XCTAssertEqual(first, .accepted)
        await waitUntil({ harness.session.lastFailure?.contains("provider故障") == true })
        let original = try XCTUnwrap(harness.session.turns.first { $0.role == .assistant })
        _ = await harness.session.ask(typed: "第二个问题")
        await waitUntil({ harness.session.turns.filter { $0.role == .assistant }.count == 2 })
        let requests = await harness.llm.requests
        let next = try XCTUnwrap(requests.last)
        XCTAssertTrue(next.messages.contains { $0.role == .assistant && $0.text == "原始片段" })
        XCTAssertTrue(next.messages.contains { $0.role == .developer && $0.text.contains(original.id) && $0.text.contains("生成失败") })
        XCTAssertEqual(harness.session.turns.first { $0.id == original.id }?.text, "原始片段")
    }

    func testOversizedCurrentQuestionStaysSavedWithoutCallingProvider() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [])
        defer { cleanup(harness) }
        let question = String(repeating: "界", count: 24_001)
        _ = await harness.session.ask(typed: question)
        await waitUntil({ harness.session.lastFailure?.contains("超过") == true })
        let requests = await harness.llm.requests
        XCTAssertTrue(requests.isEmpty)
        let recordID = try XCTUnwrap(harness.session.sessionID)
        let lines = try await harness.store.lines(sessionID: recordID)
        XCTAssertEqual(lines.first?.text.unicodeScalars.count, 24_001)
    }

    func testActualRequestTrimsCompleteHistoryWhileStoreKeepsAllTurns() async throws {
        let harness = try await makeVoiceHarness(
            llmScripts: (1...14).map { .deltas(["回答\($0)"]) }
        )
        defer { cleanup(harness) }
        for index in 1...14 {
            let result = await harness.session.ask(typed: "问题\(index)")
            XCTAssertEqual(result, .accepted)
            await waitUntil({ harness.session.turns.filter { $0.role == .assistant }.count == index })
        }
        let requests = await harness.llm.requests
        let latest = try XCTUnwrap(requests.last)
        XCTAssertEqual(latest.messages.filter { $0.role == .user }.count, 13)
        XCTAssertEqual(latest.messages.filter { $0.role == .assistant }.count, 12)
        XCTAssertFalse(latest.messages.contains { $0.text == "问题1" || $0.text == "回答1" })
        XCTAssertEqual(latest.messages.filter { $0.role == .user && $0.text == "问题14" }.count, 1)
        let scalars = (latest.instructions?.unicodeScalars.count ?? 0)
            + latest.messages.reduce(0) { $0 + $1.text.unicodeScalars.count }
        XCTAssertLessThanOrEqual(scalars, 24_000)
        XCTAssertNotNil(harness.session.contextOmissionNote)
        let recordID = try XCTUnwrap(harness.session.sessionID)
        let lines = try await harness.store.lines(sessionID: recordID)
        XCTAssertEqual(lines.count, 28, "预算只裁请求投影，不改原始记录")
    }

    func testTypedAndMicrophoneInputsShareTheirAcceptanceOrder() async throws {
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(
            llmScripts: [.deltas(["回答一"]), .deltas(["回答二"])], typedSaveGate: gate
        )
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let recordID = try XCTUnwrap(harness.session.sessionID)
        let typed = Task { await harness.session.ask(typed: "先打字") }
        await waitUntil({ gate.entered })
        await harness.clients()[0].emit(.completed(itemID: "later-mic", transcript: "后说话"))
        await harness.clients()[0].emit(.failed(itemID: "marker", code: "marker", message: ""))
        await waitUntil({ harness.session.lastFailure?.contains("marker") == true })
        let before = await harness.llm.streamCount
        XCTAssertEqual(before, 0, "后来的语音不能越过先接纳的打字保存")
        gate.release()
        _ = await typed.value
        await waitUntil({ harness.session.turns.filter { $0.role == .user }.count == 2 })
        let lines = try await harness.store.lines(sessionID: recordID)
        XCTAssertEqual(lines.filter { $0.role == .user }.map(\.text), ["先打字", "后说话"])
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
        let requestID = await harness.clients()[0].currentTTSRequestID()
        XCTAssertFalse(requestID.isEmpty, "必须中断真实开过的 request")
        await harness.clients()[0].emit(
            .ttsAudio(requestID: requestID, taskID: nil, pcm: Data(repeating: 0, count: 320))
        )
        await waitUntil({ harness.session.phase == .speaking }, message: "没有进入朗读态")
        await harness.clients()[0].emit(.partial(itemID: "i2", delta: "插话"))
        await waitUntil(
            { harness.session.partialText == "插话" },
            message: "receiver 不应等待排在 partial 后面的取消终态"
        )
        await waitUntil(
            { harness.session.phase == .listening && harness.session.blocked == nil },
            message: "匹配 terminal 必须经 receiver 确认取消"
        )
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
            .ttsAudio(
                requestID: await harness.clients()[0].currentTTSRequestID(),
                taskID: nil, pcm: Data(repeating: 0, count: 320)
            )
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
