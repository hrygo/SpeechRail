import Foundation
import Observation
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
    private final class ObservationSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var signaled = false
        var didChange: Bool { lock.withLock { signaled } }
        func signal() { lock.withLock { signaled = true } }
    }

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
        inputConfiguration: TranscriptPersistenceQueue.Configuration = .init()
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

    func testFirstFinalKeepsAVisibleRowWhileSavingThenPreservesItsIdentity() async throws {
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["回答"])], inputSaveGate: gate)
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let recordID = try XCTUnwrap(harness.session.sessionID)
        let client = harness.clients()[0]
        await client.emit(.partial(itemID: "first", delta: "临时字幕"))
        await waitUntil({ harness.session.partialText == "临时字幕" })
        await client.emit(.completed(itemID: "first", transcript: "正式问题"))
        await waitUntil({ gate.entered })

        XCTAssertNil(harness.session.partialText)
        XCTAssertTrue(harness.session.turns.isEmpty, "未保存输入不能冒充库里的行")
        let pending = try XCTUnwrap(harness.session.conversationRows.first, "首轮保存期间对话不得回到空态")
        XCTAssertEqual(pending.text, "正式问题")
        let storedBefore = try await harness.store.lines(sessionID: recordID)
        XCTAssertTrue(storedBefore.isEmpty)
        let callsBefore = await harness.llm.streamCount
        XCTAssertEqual(callsBefore, 0)

        let invalidation = ObservationSignal()
        withObservationTracking {
            _ = harness.session.conversationRows
        } onChange: {
            invalidation.signal()
        }
        await client.emit(.partial(itemID: "second", delta: "下一句"))
        await waitUntil({ harness.session.partialText == "下一句" })
        gate.release()
        await waitUntil({ harness.session.turns.contains { $0.id == pending.id } })
        XCTAssertEqual(harness.session.conversationRows.filter { $0.id == pending.id }.count, 1)
        XCTAssertEqual(harness.session.turns.first?.id, pending.id)
        XCTAssertEqual(harness.session.partialText, "下一句", "保存上一句不得清掉下一句字幕")
        XCTAssertTrue(invalidation.didChange, "保存完成必须通知观察展示列表的界面")
    }

    func testAcceptedRowsRemainInOrderAndDeduplicateWhileSaving() async throws {
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(llmScripts: [], inputSaveGate: gate)
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let client = harness.clients()[0]
        await client.emit(.completed(itemID: "first", transcript: "第一句"))
        await waitUntil({ gate.entered })
        await client.emit(.completed(itemID: "first", transcript: "第一句"))
        await client.emit(.completed(itemID: "second", transcript: "第二句"))
        await client.emit(.failed(itemID: "", code: "marker", message: ""))
        await waitUntil({ harness.session.lastFailure?.contains("marker") == true })
        XCTAssertEqual(harness.session.conversationRows.map(\.text), ["第一句", "第二句"])
        let ids = harness.session.conversationRows.map(\.id)
        let ending = Task { await harness.session.endConversation() }
        await waitUntil({ harness.session.phase == .ending })
        gate.release()
        _ = await ending.value
        XCTAssertEqual(harness.session.conversationRows.map(\.id), ids)
    }

    /// V14 fake 可测部分：空 final 不进 LLM（#256 真机声学对照的前置行为门）。
    func testEmptyFinalKeepsRecognizedTextVisibleDuringSaveWithoutCallingProvider() async throws {
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(llmScripts: [], inputSaveGate: gate)
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let client = harness.clients()[0]
        await client.emit(.partial(itemID: "first", delta: "未定稿内容"))
        await waitUntil({ harness.session.partialText == "未定稿内容" })
        await client.emit(.completed(itemID: "first", transcript: ""))
        await waitUntil({ gate.entered })
        let pending = try XCTUnwrap(harness.session.conversationRows.first)
        XCTAssertEqual(pending.text, "未定稿内容")
        gate.release()
        await waitUntil({ harness.session.turns.contains { $0.id == pending.id } })
        XCTAssertTrue(harness.session.turns.first?.isInterrupted == true)
        let calls = await harness.llm.streamCount
        XCTAssertEqual(calls, 0)
    }

    func testFirstTypedInputIsVisibleWhileAwaitingSave() async throws {
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["文字回答"])], typedSaveGate: gate)
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let invalidation = ObservationSignal()
        withObservationTracking {
            _ = harness.session.conversationRows
        } onChange: {
            invalidation.signal()
        }
        let sending = Task { await harness.session.ask(typed: "首个文字问题") }
        await waitUntil({ gate.entered })
        let pending = try XCTUnwrap(harness.session.conversationRows.first)
        XCTAssertEqual(pending.text, "首个文字问题")
        XCTAssertTrue(harness.session.turns.isEmpty)
        XCTAssertTrue(invalidation.didChange, "接纳输入必须立即通知界面，无需等保存完成")
        let callsBefore = await harness.llm.streamCount
        XCTAssertEqual(callsBefore, 0)
        gate.release()
        let result = await sending.value
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(harness.session.turns.first?.id, pending.id)
        XCTAssertEqual(harness.session.conversationRows.filter { $0.id == pending.id }.count, 1)
    }

    /// V14 fake 可测部分：拒收保留字幕，不建 accepted 行、不进 LLM。
    func testRejectedFinalRetainsItsVisiblePartialWithoutCreatingAnAcceptedRow() async throws {
        let harness = try await makeVoiceHarness(
            llmScripts: [], inputConfiguration: .init(maximumPendingCommands: 0)
        )
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let client = harness.clients()[0]
        await client.emit(.partial(itemID: "rejected", delta: "尚未接纳"))
        await waitUntil({ harness.session.partialText == "尚未接纳" })
        await client.emit(.completed(itemID: "rejected", transcript: "尚未接纳"))
        await waitUntil({ harness.session.lastFailure?.contains("无法接纳") == true })
        XCTAssertEqual(harness.session.partialText, "尚未接纳")
        XCTAssertTrue(harness.session.conversationRows.isEmpty)
        XCTAssertTrue(harness.session.turns.isEmpty)
        let calls = await harness.llm.streamCount
        XCTAssertEqual(calls, 0)
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
        let gate = AssistantSessionTests.Gate()
        let harness = try await makeVoiceHarness(llmScripts: [], inputSaveGate: gate, saveControl: control)
        defer { gate.release(); cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let recordID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.completed(itemID: "retry-q", transcript: "保留问题"))
        await waitUntil({ gate.entered })
        let accepted = try XCTUnwrap(harness.session.conversationRows.first)
        let invalidation = ObservationSignal()
        withObservationTracking {
            _ = harness.session.conversationRows
        } onChange: {
            invalidation.signal()
        }
        gate.release()
        await waitUntil({ harness.session.lastFailure?.contains("测试保存失败") == true })
        let failedRow = try XCTUnwrap(harness.session.conversationRows.first)
        XCTAssertEqual(failedRow.id, accepted.id)
        XCTAssertTrue(invalidation.didChange, "失败必须通知界面更新同一行的保存状态")
        XCTAssertEqual(failedRow.text, "保留问题")
        guard case .accepted(_, let failure) = failedRow else {
            return XCTFail("保存失败的输入不能被标为已保存")
        }
        XCTAssertTrue(failure?.contains("测试保存失败") == true)
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
        XCTAssertEqual(lines.first?.id, failedRow.id, "重试必须保存同一条输入，不制造新身份")
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

    /// V01：活跃朗读（speaking）中注入空/空白 hypothesis 与空白 delta。
    /// 三者零打断、零字幕污染；随后首个有效证据恰好触发一次中断，重复证据不再触发。
    func testV01BlankEvidenceNeverInterruptsActiveSpeech() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["长回答。"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "念一句"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "回复没有落库"
        )
        let requestID = await harness.clients()[0].currentTTSRequestID()
        XCTAssertFalse(requestID.isEmpty, "必须中断真实开过的 request")
        await harness.clients()[0].emit(
            .ttsAudio(requestID: requestID, taskID: nil, pcm: Data(repeating: 0, count: 320))
        )
        await waitUntil({ harness.session.phase == .speaking }, message: "没有进入朗读态")
        let cancelsBefore = await harness.clients()[0].snapshot().cancelTTS

        // 空快照 / 纯空白快照 / 纯空白 delta：零打断、零字幕污染。
        await harness.clients()[0].emit(.partialSnapshot(itemID: "i2", revision: 1, text: "", evidence: .init()))
        await harness.clients()[0].emit(.partialSnapshot(itemID: "i2", revision: 2, text: "   ", evidence: .init()))
        await harness.clients()[0].emit(.partial(itemID: "i2", delta: "   "))
        // 给 receiver 落地时间：空白证据若误触发，打断会改 phase/partialText。
        try? await Task.sleep(for: .milliseconds(50))
        let cancelsAfterBlank = await harness.clients()[0].snapshot().cancelTTS
        XCTAssertEqual(cancelsAfterBlank, cancelsBefore, "空白证据不得打断")
        XCTAssertNil(harness.session.partialText, "空白证据不得污染字幕槽")
        XCTAssertEqual(harness.session.phase, .speaking, "空白证据不得改朗读态")

        // 首个有效证据恰好触发一次中断；同一键重复不再触发。
        await harness.clients()[0].emit(.partialSnapshot(itemID: "i3", revision: 5, text: "插话", evidence: .init()))
        await waitUntil(
            { harness.session.partialText == "插话" },
            message: "首个有效证据应正常显示字幕"
        )
        await waitUntil(
            { harness.session.phase == .listening && harness.session.blocked == nil },
            message: "匹配 terminal 必须经 receiver 确认取消"
        )
        let cancelsAfterFirst = await harness.clients()[0].snapshot().cancelTTS
        XCTAssertEqual(cancelsAfterFirst - cancelsBefore, 1, "首个有效证据应恰好触发一次中断")
        // 中断后已回 listening：重复旧证据不得重新打断新状态。
        await harness.clients()[0].emit(.partialSnapshot(itemID: "i3", revision: 5, text: "插话", evidence: .init()))
        try? await Task.sleep(for: .milliseconds(50))
        let cancelsAfterRepeat = await harness.clients()[0].snapshot().cancelTTS
        XCTAssertEqual(cancelsAfterRepeat, cancelsAfterFirst, "重复证据不得重新打断")
    }

    /// V02：同 revision 跨 item 独立去重、新 final-only 正常接管。
    /// 中断意图只取消一次，合法新输入保存后回答。
    func testV02EvidenceOwnershipAcrossItemsAndFinals() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["首答。"]), .deltas(["次答。"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "念首句"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "首轮回复没有落库"
        )
        let requestID = await harness.clients()[0].currentTTSRequestID()
        XCTAssertFalse(requestID.isEmpty, "必须中断真实开过的 request")
        await harness.clients()[0].emit(
            .ttsAudio(requestID: requestID, taskID: nil, pcm: Data(repeating: 0, count: 320))
        )
        await waitUntil({ harness.session.phase == .speaking }, message: "没有进入朗读态")
        let cancelsBefore = await harness.clients()[0].snapshot().cancelTTS

        // 同 revision 跨 item：首个证据触发中断，另一个 item 的同 revision
        // 是独立归属键，但同一中断意图只取消一次（中断后已回 listening，
        // 后续证据不再满足 isSpeakingOrGenerating）。
        await harness.clients()[0].emit(.partialSnapshot(itemID: "a", revision: 7, text: "甲", evidence: .init()))
        await waitUntil(
            { harness.session.phase == .listening && harness.session.blocked == nil },
            message: "匹配 terminal 必须经 receiver 确认取消"
        )
        await harness.clients()[0].emit(.partialSnapshot(itemID: "b", revision: 7, text: "乙", evidence: .init()))
        await harness.clients()[0].emit(.partialSnapshot(itemID: "a", revision: 7, text: "甲", evidence: .init()))
        try? await Task.sleep(for: .milliseconds(50))
        let cancelsAfter = await harness.clients()[0].snapshot().cancelTTS
        XCTAssertEqual(cancelsAfter - cancelsBefore, 1, "同一中断意图只应取消一次")
        // 新 final-only 合法输入：保存成功后正常回答。
        await harness.clients()[0].emit(.completed(itemID: "i2", transcript: "念次句"))
        await waitUntil(
            { harness.session.turns.filter { $0.role == .assistant }.count >= 2 },
            message: "合法新输入应在保存后回答"
        )
    }

    // MARK: - M0e/V11：未定稿不开口

    /// V11a：LLM 先给可误解前缀、随后才否定/更正——流式中途零 start/零音频，
    /// 定稿后恰好一次 start，且朗读的是含否定/更正的完整计划文本。
    func testV11MisleadingPrefixNeverSpeaksUntilFinal() async throws {
        let harness = try await makeVoiceHarness(
            llmScripts: [.deltas(["3.5kg 肯定没问题", "，不对，其实不行。"])]
        )
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "q1", transcript: "问一句"))
        // 定稿前快照：只要还没落库，转 streamingReply 读正文、startTTS 计数。
        // 流式两段是同一 Task 内连续 yield，中间不停顿——这里只断言定稿后行为：
        // 恰好一次 start，且开嗓前零 start 由门禁语义保证（offer 拒绝未确认增量）。
        let turnsBefore = harness.session.turns.filter { $0.role == .assistant }.count
        XCTAssertEqual(turnsBefore, 0, "定稿前不得有 assistant 落库")
        // 定稿后：恰好一次 start（确认计划开嗓）；朗读态由首个音频到达确认，
        // Fake 不回音频包时保持 thinking——零音频是 Fake 形状，不伪造 speaking。
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "定稿回复没有落库"
        )
        await waitUntil(
            { harness.session.phase == .thinking },
            message: "确认计划开嗓后应保持 thinking 等音频"
        )
        let finalStarts = await harness.clients()[0].snapshot().startTTS
        XCTAssertEqual(finalStarts, 1, "定稿后恰好一次 start")
        // 首个音频到达即进入朗读态：确认计划的文本确实在播。
        let requestID = await harness.clients()[0].currentTTSRequestID()
        XCTAssertFalse(requestID.isEmpty, "确认计划必须开过真实 request")
        await harness.clients()[0].emit(
            .ttsAudio(requestID: requestID, taskID: nil, pcm: Data(repeating: 0, count: 320))
        )
        await waitUntil({ harness.session.phase == .speaking }, message: "音频到达后应进入朗读态")
    }

    /// V11b：provider 中途失败（incomplete 形状）——零 start/零音频，
    /// 只保留明确未完成的预览，不自动朗读残缺答案。
    func testV11ProviderFailureNeverSpeaksPartialAnswer() async throws {
        let harness = try await makeVoiceHarness(
            llmScripts: [.deltasThenFailure(["半句"], "模型断了")]
        )
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "q1", transcript: "问一句"))
        // Fake 的 deltasThenFailure 在同一 Task 内连续 yield：中途不停顿，
        // 预览断言改用"失败收尾落库 + 零 start"，不赌流式中间态。
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "失败片段应收尾落库"
        )
        try? await Task.sleep(for: .milliseconds(50))
        let starts = await harness.clients()[0].snapshot().startTTS
        XCTAssertEqual(starts, 0, "失败残缺答案不得 start")
    }

    /// V11c：provider EOF 无终态（空脚本 = 零 delta 即结束）——零 start，
    /// 不留伪造正文行。
    func testV11EmptyReplyNeverSpeaks() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas([])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "q1", transcript: "问一句"))
        await waitUntil(
            { harness.session.lastFailure == "模型这次没有给出内容。" },
            message: "空回复应明确失败"
        )
        let starts = await harness.clients()[0].snapshot().startTTS
        XCTAssertEqual(starts, 0, "空回复不得 start")
        XCTAssertFalse(
            harness.session.turns.contains { $0.role == .assistant },
            "空回复不留伪造正文行"
        )
    }

    // MARK: - M3/V08b:上行丢块证据可计数

    /// V08b:块序号跳跃（bufferingNewest 替换）必须累计为跳过块数；
    /// 无序号的旧来源不产生证据，也不伪造连续结论。
    func testUploadSkippedChunksAreCounted() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [])
        defer { cleanup(harness) }
        // pump 启动后 uploader 才消费 capture 流（与 V01 等用例同一驱动方式）。
        try await harness.coordinator.begin(.assistant)
        let session = harness.session
        XCTAssertEqual(session.uploadedChunksSkipped, 0)
        XCTAssertEqual(session.uploadedSamplesDropped, 0)
        // 序号 0,1,2 连续 → 无跳过。
        for seq in [0, 1, 2] {
            harness.audio.emitCapture(
                AudioChunk(
                    pcm: Data([1, 2, 3, 4]),
                    level: 0.5,
                    sequenceNumber: seq,
                    droppedSamplesBefore: 0
                )
            )
        }
        // uploader 是异步 Task：等三块全部落地再断言序号，避免竞态。
        await waitUntil(
            { session.lastUploadedChunkSequenceForTest == 2 },
            message: "三块连续序号应全部被 uploader 消费"
        )
        XCTAssertEqual(session.uploadedChunksSkipped, 0, "连续序号不得累计跳过")
        // 序号跳到 5 → 跳过 3,4 两块。
        harness.audio.emitCapture(
            AudioChunk(
                pcm: Data([1, 2, 3, 4]),
                level: 0.5,
                sequenceNumber: 5,
                droppedSamplesBefore: 0
            )
        )
        await waitUntil(
            { session.uploadedChunksSkipped == 2 },
            message: "序号 2→5 应累计跳过 2 块"
        )
        XCTAssertEqual(session.uploadedSamplesDropped, 0, "无 ring 丢样时丢样计数必须为零")
    }

    /// V08c:语音 final 落库时若自上次回答以来丢证据超阈值，不回答，转请重说；
    /// 键盘来源不受此门影响；水位推进后后续轮次不受同一批证据阻挡。
    func testBrokenVoiceInputAsksForRepeatInsteadOfAnswering() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["回答"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        // 先制造断裂证据：序号跳跃 3 块（超 1 块阈值）。
        for seq in [0, 10, 11] {
            harness.audio.emitCapture(
                AudioChunk(
                    pcm: Data([1, 2, 3, 4]),
                    level: 0.5,
                    sequenceNumber: seq,
                    droppedSamplesBefore: 0
                )
            )
        }
        await waitUntil(
            { harness.session.uploadedChunksSkipped >= 9 },
            message: "序号 0→10 应累计跳过 9 块"
        )
        await harness.clients()[0].emit(.completed(itemID: "q-broken", transcript: "断裂的问题"))
        await waitUntil(
            { harness.session.lastFailure?.contains("没能完整收录") == true },
            message: "断裂语音 final 应转请重说，不回答"
        )
        let streamCountAfterBroken = await harness.llm.streamCount
        XCTAssertEqual(streamCountAfterBroken, 0, "断裂输入不得把问题发送给 provider")
        // 同一批证据水位已推进：下一句完整语音应正常回答。
        await harness.clients()[0].emit(.completed(itemID: "q-whole", transcript: "完整的问题"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "水位推进后完整语音应正常回答"
        )
    }

    /// V08c:键盘来源无采集链路，不受完整性门影响——即使有丢证据也正常回答。
    func testKeyboardInputBypassesIntegrityGate() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["键盘回答"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        for seq in [0, 10, 11] {
            harness.audio.emitCapture(
                AudioChunk(
                    pcm: Data([1, 2, 3, 4]),
                    level: 0.5,
                    sequenceNumber: seq,
                    droppedSamplesBefore: 0
                )
            )
        }
        await waitUntil(
            { harness.session.uploadedChunksSkipped >= 9 },
            message: "序号 0→10 应累计跳过 9 块"
        )
        _ = await harness.session.ask(typed: "键盘问题")
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant && $0.text.contains("键盘回答") } },
            message: "键盘问题不受语音完整性门影响，应正常回答"
        )
    }

    // MARK: - M1/V16-V17:完整文本 adapter 未评审启用前保持关闭

    /// V16-V17:助手生产链不得静默启用完整文本合成路径——语音回答仍走
    /// Realtime 增量 TTS（`startTTSStream/appendTTSText`），不得在未评审
    /// 的情况下调用 `/v1/audio/speech` 完整文本接口。
    /// 该 adapter 的边界（§6.0：固定 voice/revision、interactive purpose、
    /// integrity receipt、有界接收、取消/设备/结束屏障）尚未评审通过，
    /// 默认关闭是产品行为，不是缺测试。
    func testFullTextAdapterStaysDisabledUntilReviewed() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [.deltas(["完整回答。"])])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "q1", transcript: "念一句"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "回复没有落库"
        )
        let client = harness.clients()[0]
        let started = await client.snapshot().startTTS
        XCTAssertGreaterThanOrEqual(started, 1, "语音回答仍走 Realtime 增量 TTS")
        XCTAssertFalse(
            harness.session.usesFullTextSpeechForTest,
            "完整文本 adapter 未评审启用前必须保持关闭"
        )
    }

    // MARK: - M3/V09:活动内存有界，SQLite 全记录保留

    /// V09:30 轮问答后场内窗口有界（contextTurns ≤ 24 轮、turns ≤ 48 行），
    /// SQLite 全 30 轮保留；附属映射无已出窗口残留。
    func testInMemoryWindowsAreBoundedWhileStoreKeepsEverything() async throws {
        var scripts: [AssistantSessionTests.FakeAssistantLLM.Script] = []
        for i in 0..<30 {
            scripts.append(.deltas(["回答\(i)"]))
        }
        let harness = try await makeVoiceHarness(llmScripts: scripts)
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        for i in 0..<30 {
            _ = await harness.session.ask(typed: "问题\(i)")
            await waitUntil(
                { harness.session.turns.contains { $0.role == .assistant && $0.text.contains("回答\(i)") } },
                message: "第 \(i) 轮应收尾落库"
            )
        }
        let window = AssistantSession.inMemoryTurnWindow
        XCTAssertLessThanOrEqual(
            harness.session.turns.count, window * 2,
            "场内 turns（user+assistant 双行）必须按轮有界"
        )
        XCTAssertLessThanOrEqual(
            harness.session.contextTurnCountForTest, window, "场内 contextTurns 必须有界"
        )
        // 权威在库里：30 轮用户问 + 30 轮助手答全部保留。
        let recordID = try XCTUnwrap(harness.session.sessionID)
        let lines = try await harness.store.lines(sessionID: recordID)
        let userLines = lines.filter { $0.role == .user }.count
        let assistantLines = lines.filter { $0.role == .assistant }.count
        XCTAssertEqual(userLines, 30, "SQLite 用户问必须全保留")
        XCTAssertEqual(assistantLines, 30, "SQLite 助手答必须全保留")
    }

    /// V08b:ring 丢样快照差必须累计；快照回退（新采集期）不倒扣。
    func testUploadDroppedSamplesAreCounted() async throws {
        let harness = try await makeVoiceHarness(llmScripts: [])
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let session = harness.session
        harness.audio.emitCapture(
            AudioChunk(pcm: Data([1, 2, 3, 4]), level: 0.5, sequenceNumber: 0, droppedSamplesBefore: 100)
        )
        harness.audio.emitCapture(
            AudioChunk(pcm: Data([1, 2, 3, 4]), level: 0.5, sequenceNumber: 1, droppedSamplesBefore: 160)
        )
        await waitUntil(
            { session.uploadedSamplesDropped == 60 },
            message: "丢样快照 100→160 应累计 60 样本"
        )
        // 新采集期快照归零：不倒扣，只更新基线。
        harness.audio.emitCapture(
            AudioChunk(pcm: Data([1, 2, 3, 4]), level: 0.5, sequenceNumber: 0, droppedSamplesBefore: 0)
        )
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.uploadedSamplesDropped, 60, "快照回退不得倒扣已累计的丢样数")
    }
}
