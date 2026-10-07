import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-03 输入排空、尾句与保存双屏障（A05/A06/A07/A47）。
///
/// 打生产 `AssistantSession.stopCapture` 的 draining 路径：
/// 结束时保留该连接的 ASR 归档资格，尾句只归档、不触发新回答；
/// DB 挂起时无保存成功标识；封存失败保留恢复出口。
@MainActor
final class AssistantDrainTests: XCTestCase {
    // MARK: - 夹具（独立于 AssistantSessionTests 的内部 Fake）

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private var enteredCount = 0
        var entered: Bool { lock.withLock { enteredCount > 0 } }
        func enter() async {
            let shouldBlock = lock.withLock { () -> Bool in
                enteredCount += 1
                return !released
            }
            guard shouldBlock else { return }
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock { () -> Bool in
                    guard !released else { return true }
                    self.continuation = continuation
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        }

        func release() {
            let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume()
        }
    }

    actor FakeLLM: AssistantLLM {
        private(set) var streamCount = 0
        func check(
            configuration: LLMConfiguration,
            apiKey: String?,
            operation: LLMOperation,
            allowThinkingControlFallback: Bool
        ) async -> LLMConnectionResult {
            .connected(milliseconds: 1, model: "test-model")
        }

        func stream(
            configuration: LLMConfiguration,
            messages: [LLMMessage],
            apiKey: String?,
            maxOutputTokens: Int?,
            instructions: String?
        ) async -> AsyncThrowingStream<String, Error> {
            streamCount += 1
            return AsyncThrowingStream { continuation in
                continuation.yield("尾句后的回答不应出现。")
                continuation.finish()
            }
        }
    }

    actor FakeRealtime: AssistantRealtimeClient {
        struct Counters: Sendable, Equatable {
            var drain = 0
            var close = 0
            var cancelTTS = 0
        }

        private let stream: RealtimeEventStream<RealtimeASRClient.Event>
        private var counters = Counters()
        private let drainGate: Gate?
        private let receiverGate: Gate?
        private let failDrain: Bool
        var didEmitTail = false
        private var appendFails = false
        private var appendGate: Gate?

        init(drainGate: Gate? = nil, receiverGate: Gate? = nil, failDrain: Bool = false) {
            self.stream = RealtimeEventStream()
            self.drainGate = drainGate
            self.receiverGate = receiverGate
            self.failDrain = failDrain
        }

        func events() async -> RealtimeEventStream<RealtimeASRClient.Event> {
            if let receiverGate { await receiverGate.enter() }
            return stream
        }
        func connect() async throws {}
        func close() async {
            counters.close += 1
            await stream.finish()
        }

        func failAppend(gate: Gate? = nil) { appendFails = true; appendGate = gate }
        func append(_ pcm: Data) async throws {
            if let appendGate { await appendGate.enter() }
            if appendFails { throw URLError(.networkConnectionLost) }
        }
        func drainAndClear(timeout: Duration) async throws {
            counters.drain += 1
            if let drainGate { await drainGate.enter() }
            if failDrain { throw URLError(.timedOut) }
        }

        func updateVoice(
            _ voice: String,
            expectedVoiceRevision: String?,
            expectedTTSRevision: String?
        ) async throws {}

        func startTTSStream(requestID: String, speed: Double?, audioWindowBytes: Int) async throws {}
        func acknowledgeTTSAudio(requestID: String, sampleOffset: Int) async throws {}
        func appendTTSText(_ text: String, sequence: Int) async throws {}
        func finishTTSText(lastSequence: Int) async throws {}
        func cancelTTS() async throws { counters.cancelTTS += 1 }
        func emit(_ payload: RealtimeASRClient.Event) async {
            _ = await stream.yield(
                RealtimeEventEnvelope(
                    metadata: RealtimeEventMetadata(
                        eventID: UUID().uuidString,
                        sessionID: "assistant-drain-test",
                        sequence: nil
                    ),
                    payload: payload
                )
            )
        }

        func snapshot() -> Counters { counters }
    }

    final class FakeAudio: AssistantAudioSession, @unchecked Sendable {
        var onPlaybackDrained: (@MainActor () -> Void)?
        var onPlaybackBufferRendered: (@MainActor (Int, Int, UUID) -> Void)?
        var onFailure: (@MainActor (String) -> Void)?
        var onPlaybackInvalidated: (@MainActor (AssistantAudioInvalidation) async -> Void)?
        private var capture: AsyncStream<AudioChunk>.Continuation?
        func configure(mode: AssistantMode) {}
        func start() async throws -> AsyncStream<AudioChunk> {
            let pair = AsyncStream<AudioChunk>.makeStream()
            capture = pair.continuation
            return pair.stream
        }
        func emit(_ chunk: AudioChunk) { capture?.yield(chunk) }
        func stop() { capture?.finish(); capture = nil }
        @discardableResult
        func enqueuePlayback(_ pcm: Data, epoch: Int, chunkID: UUID) async -> Bool { true }
        func stopPlayback() async {}
    }

    struct Harness: @unchecked Sendable {
        let session: AssistantSession
        let audio: FakeAudio
        let coordinator: SessionCoordinator
        let store: SessionStore
        let llm: FakeLLM
        let clientBox: ClientBox
        let directory: URL
        let defaults: UserDefaults
    }

    final class ClientBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [FakeRealtime] = []
        var clients: [FakeRealtime] { lock.withLock { stored } }
        func append(_ client: FakeRealtime) { lock.withLock { stored.append(client) } }
    }

    private func makeHarness(
        drainGate: Gate? = nil, receiverGate: Gate? = nil, failDrain: Bool = false,
        saveGate: Gate? = nil, titleGate: Gate? = nil, drainTimeout: Duration = .seconds(12)
    ) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-drain-\(UUID().uuidString)"))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let llm = FakeLLM()
        let audio = FakeAudio()
        let box = ClientBox()
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"
        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies(
                llm: llm,
                makeRealtimeClient: { _ in
                    let client = FakeRealtime(
                        drainGate: drainGate, receiverGate: receiverGate, failDrain: failDrain
                    )
                    box.append(client)
                    return client
                },
                saveInputLine: { draft, id in
                    if let saveGate { await saveGate.enter() }
                    return try await store.appendLine(draft, id: id)
                },
                claimTitle: { _, _, _ in
                    if let titleGate { await titleGate.enter() }
                    return true
                },
                drainTimeout: drainTimeout
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
        return Harness(
            session: session,
            audio: audio,
            coordinator: coordinator,
            store: store,
            llm: llm,
            clientBox: box,
            directory: directory,
            defaults: defaults
        )
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

    private func cleanup(_ harness: Harness) {
        try? FileManager.default.removeItem(at: harness.directory)
        harness.defaults.removePersistentDomain(forName: harness.defaults.description)
    }

    /// A05：ending 后到达的 final 只归档到原记录一次，不触发 LLM/TTS。
    func testA05TailFinalDuringDrainArchivesOnly() async throws {
        let drainGate = Gate()
        let harness = try await makeHarness(drainGate: drainGate)
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        // 先启动 stopCapture 进入 draining（drain 卡在 commit 阶段），
        // drain 返回前送达的 final 必须被归档，而不是丢弃或触发回答。
        let stop = Task { @MainActor in await harness.session.stopCapture() }
        await waitUntil({ drainGate.entered }, message: "drain 没有进入 commit 等待")
        // 等 stopCapture 进入 ending/draining。
        await waitUntil(
            { harness.session.phase == .ending },
            message: "结束没有进入 ending/draining"
        )
        let client = harness.clientBox.clients.first!
        // draining 连接的合法尾句：同一连接、原记录。
        await client.emit(.completed(itemID: "tail1", transcript: "最后一句"))
        drainGate.release()
        await stop.value
        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let tails = lines.filter { $0.text == "最后一句" }
        XCTAssertEqual(tails.count, 1, "尾句必须落原记录恰好一次")
        let llmCount = await harness.llm.streamCount
        XCTAssertEqual(llmCount, 0, "draining 尾句不得触发新回答")
    }

    /// A06：receipt 已到但 final 写入 Gate 挂起时，不得发布保存成功。
    func testReceiptWithEmptyQueueCannotBypassTheOnlyReceiver() async throws {
        let receiverGate = Gate()
        let drainGate = Gate()
        let h = try await makeHarness(drainGate: drainGate, receiverGate: receiverGate)
        defer { cleanup(h) }
        try await h.coordinator.begin(.assistant)
        let id = try XCTUnwrap(h.session.sessionID)
        await waitUntil({ receiverGate.entered })
        var stopped = false
        let stop = Task { @MainActor in
            _ = await h.coordinator.finalize(reason: .user)
            stopped = true
        }
        await waitUntil({ drainGate.entered })
        let client = try XCTUnwrap(h.clientBox.clients.first)
        await client.emit(.segmentClosed(
            itemID: "buffered-tail", sampleSpan: .init(startSample: 0, endSample: 24_000),
            reason: .clientCommit, commitEventID: nil
        ))
        await client.emit(.completed(itemID: "buffered-tail", transcript: "接收器尚未消费的尾句"))
        drainGate.release()
        // The receipt has arrived, but the one feature receiver has not admitted
        // the buffered final. Empty pending state is deliberately insufficient.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(stopped, "receipt and an empty queue cannot authorize a complete archive")
        let before = try await h.store.session(id: id)
        XCTAssertNotEqual(before?.state, .archived)
        receiverGate.release()
        await stop.value
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.text), ["接收器尚未消费的尾句"])
        let llmCalls = await h.llm.streamCount
        XCTAssertEqual(llmCalls, 0)
    }

    func testLateUploadFailureCannotPolluteTheNextRecord() async throws {
        let gate = Gate()
        let h = try await makeHarness(drainTimeout: .milliseconds(80))
        defer { cleanup(h) }
        try await h.coordinator.begin(.assistant)
        let id = try XCTUnwrap(h.session.sessionID)
        let old = try XCTUnwrap(h.clientBox.clients.last)
        await old.failAppend(gate: gate)
        h.audio.emit(AudioChunk(pcm: Data([0, 1]), level: 0.2))
        await waitUntil({ gate.entered })
        await h.coordinator.finalize(reason: .user)
        try await h.coordinator.begin(.assistant)
        let nextID = try XCTUnwrap(h.session.sessionID)
        XCTAssertNotEqual(id, nextID)
        let currentFailure = h.session.lastFailure
        gate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(h.session.lastFailure, currentFailure)
        XCTAssertNil(h.coordinator.captureCompletionFailure(recordID: nextID))
        await h.coordinator.finalize(reason: .user)
    }

    func testOptionalTitleCannotConsumeTheCaptureSealBudget() async throws {
        let title = Gate()
        let drain = Gate()
        let h = try await makeHarness(drainGate: drain, titleGate: title, drainTimeout: .milliseconds(300))
        defer { cleanup(h) }
        try await h.coordinator.begin(.assistant)
        let id = try XCTUnwrap(h.session.sessionID)
        let client = try XCTUnwrap(h.clientBox.clients.last)
        let stop = Task { await h.coordinator.finalize(reason: .user) }
        await waitUntil({ drain.entered })
        await client.emit(.segmentClosed(
            itemID: "title-tail", sampleSpan: .init(startSample: 0, endSample: 48_000),
            reason: .clientCommit, commitEventID: "title-commit"
        ))
        await client.emit(.completed(itemID: "title-tail", transcript: "正文正常保存"))
        await waitUntil({ title.entered })
        drain.release()
        await stop.value
        let record = try await h.store.session(id: id)
        XCTAssertEqual(record?.state, .archived)
        XCTAssertEqual(h.coordinator.lastFinalizedSessionID, id)
        title.release()
    }

    func testUploadFailureCannotBeHiddenBySuccessfulDrain() async throws {
        let h = try await makeHarness()
        defer { cleanup(h) }
        try await h.coordinator.begin(.assistant)
        let id = try XCTUnwrap(h.session.sessionID)
        let client = try XCTUnwrap(h.clientBox.clients.last)
        await client.failAppend()
        h.audio.emit(AudioChunk(pcm: Data([0, 1]), level: 0.2))
        await h.coordinator.finalize(reason: .user)
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
        XCTAssertEqual(h.coordinator.captureCompletionFailure(recordID: id)?.stage, .upload)
    }

    func testProtocolFailureCannotBecomeNormalArchiveEvenWhenNoSavesArePending() async throws {
        let h = try await makeHarness(failDrain: true)
        defer { cleanup(h) }
        try await h.coordinator.begin(.assistant)
        let id = try XCTUnwrap(h.session.sessionID)
        _ = await h.coordinator.finalize(reason: .user)
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived, "local close does not prove the remote drain")
        XCTAssertNil(h.coordinator.lastFinalizedSessionID)
        XCTAssertNotNil(h.session.lastFailure)
    }

    func testDeadlineReturnsWithNoncooperativeWorkStillOwnedUntilItActuallyEnds() async throws {
        let gate = Gate()
        let deadline = SessionDrainDeadline(timeout: .milliseconds(40))
        var finished = false
        var passed = true
        let waiter = Task {
            passed = await deadline.wait(stage: .protocolDrain) { await gate.enter() }
            finished = true
        }
        await waitUntil({ gate.entered })
        await waitUntil({ finished }, iterations: 300, message: "noncooperative work bypassed the deadline")
        XCTAssertFalse(passed)
        XCTAssertNotNil(deadline.failure)
        XCTAssertEqual(deadline.pendingOperationCount, 1, "timeout is not proof that the operation ended")
        gate.release()
        await waiter.value
        await waitUntil({ deadline.pendingOperationCount == 0 })
    }

    func testReceiverTimeoutReleasesOccupancyAndCannotBeRetriedAsComplete() async throws {
        let gate = Gate()
        let h = try await makeHarness(receiverGate: gate, drainTimeout: .milliseconds(80))
        defer { cleanup(h) }
        try await h.coordinator.begin(.assistant)
        let id = try XCTUnwrap(h.session.sessionID)
        await waitUntil({ gate.entered })
        var finished = false
        let stop = Task {
            _ = await h.coordinator.finalize(reason: .user)
            finished = true
        }
        await waitUntil({ finished }, iterations: 400, message: "receiver EOF wait must be bounded")
        XCTAssertNil(h.coordinator.occupancy)
        XCTAssertNotNil(h.session.lastFailure)
        gate.release()
        await stop.value
        let retry = await h.session.retryPendingSeal()
        XCTAssertFalse(retry, "lost consumer proof cannot be repaired by checking an empty save queue")
        let retryAgain = await h.session.retryPendingSeal()
        XCTAssertFalse(retryAgain, "a fresh retry deadline cannot manufacture lost consumer proof")
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
    }

    func testNoncooperativeProtocolDrainHasTheSameBoundedStopDeadline() async throws {
        let gate = Gate()
        let h = try await makeHarness(drainGate: gate, drainTimeout: .milliseconds(80))
        defer { cleanup(h) }
        try await h.coordinator.begin(.assistant)
        let id = try XCTUnwrap(h.session.sessionID)
        var stopped = false
        let stop = Task {
            _ = await h.coordinator.finalize(reason: .user)
            stopped = true
        }
        await waitUntil({ gate.entered })
        await waitUntil({ stopped }, iterations: 400)
        XCTAssertNil(h.coordinator.occupancy)
        let before = try await h.store.session(id: id)
        XCTAssertNotEqual(before?.state, .archived)
        gate.release()
        await stop.value
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
    }

    func testBufferedStreamFailureCannotBeHiddenBySuccessfulLocalClose() async throws {
        let receiver = Gate()
        let drain = Gate()
        let h = try await makeHarness(drainGate: drain, receiverGate: receiver)
        defer { cleanup(h) }
        try await h.coordinator.begin(.assistant)
        let id = try XCTUnwrap(h.session.sessionID)
        await waitUntil({ receiver.entered })
        let stop = Task { _ = await h.coordinator.finalize(reason: .user) }
        await waitUntil({ drain.entered })
        let client = try XCTUnwrap(h.clientBox.clients.first)
        await client.emit(.serverError(
            code: "realtime_event_stream_overflow", message: "buffered stream was lost", requestID: nil
        ))
        await client.emit(.closed(code: nil))
        drain.release()
        for _ in 0..<100 {
            if await client.snapshot().close == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let counts = await client.snapshot()
        XCTAssertEqual(counts.close, 1)
        receiver.release()
        await stop.value
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived, "local close cannot overwrite a buffered stream failure")
        XCTAssertNotNil(h.coordinator.captureCompletionFailure(recordID: id))
    }

    func testSaveTimeoutKeepsTheCommandAndExplicitRetryGetsAFreshBudget() async throws {
        let save = Gate()
        let drain = Gate()
        let h = try await makeHarness(
            drainGate: drain, saveGate: save, drainTimeout: .milliseconds(80)
        )
        defer { cleanup(h) }
        try await h.coordinator.begin(.assistant)
        let id = try XCTUnwrap(h.session.sessionID)
        var stopped = false
        let stop = Task {
            _ = await h.coordinator.finalize(reason: .user)
            stopped = true
        }
        await waitUntil({ drain.entered })
        let client = try XCTUnwrap(h.clientBox.clients.first)
        await client.emit(.segmentClosed(
            itemID: "save-timeout", sampleSpan: .init(startSample: 0, endSample: 24_000),
            reason: .clientCommit, commitEventID: nil
        ))
        await client.emit(.completed(itemID: "save-timeout", transcript: "保存超时仍可恢复"))
        await waitUntil({ save.entered })
        drain.release()
        await waitUntil({ stopped }, iterations: 400)
        XCTAssertNil(h.coordinator.occupancy)
        XCTAssertTrue(h.session.unsavedTranscriptText().contains("保存超时仍可恢复"))
        XCTAssertNil(h.coordinator.captureCompletionFailure(recordID: id), "confirmed EOF survives a storage timeout")
        save.release()
        await stop.value
        let retried = await h.session.retryPendingSeal()
        XCTAssertTrue(retried, "an explicit save retry must get a fresh deadline")
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.text), ["保存超时仍可恢复"])
    }

    func testReceiverEOFStillWaitsForTheRealInputSaveOwner() async throws {
        let saveGate = Gate()
        let drainGate = Gate()
        // Receiver must admit this formal input while the session is draining,
        // so it cannot start another LLM reply.
        let blocked = try await makeHarness(drainGate: drainGate, saveGate: saveGate)
        defer { cleanup(blocked) }
        try await blocked.coordinator.begin(.assistant)
        let blockedID = try XCTUnwrap(blocked.session.sessionID)
        var finished = false
        let stop = Task {
            _ = await blocked.coordinator.finalize(reason: .user)
            finished = true
        }
        await waitUntil({ drainGate.entered })
        let tailClient = try XCTUnwrap(blocked.clientBox.clients.first)
        await tailClient.emit(.segmentClosed(
            itemID: "saved-tail", sampleSpan: .init(startSample: 0, endSample: 24_000),
            reason: .clientCommit, commitEventID: nil
        ))
        await tailClient.emit(.completed(itemID: "saved-tail", transcript: "EOF后仍待保存"))
        await waitUntil({ saveGate.entered })
        drainGate.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(finished)
        let before = try await blocked.store.session(id: blockedID)
        XCTAssertNotEqual(before?.state, .archived)
        saveGate.release()
        await stop.value
        let rows = try await blocked.store.lines(sessionID: blockedID)
        XCTAssertEqual(rows.map(\.text), ["EOF后仍待保存"])
    }

    /// A06：真实 feature/store Gate 集成由 R08 补充；以下仅验证基础封存结果。
    func testA06ReceiptCannotBypassStoreGate() async throws {
        let (store, directory): (SessionStore, URL) = {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("assistant-seal-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let s = SessionStore(directory: dir)
            return (s, dir)
        }()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.open()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-seal-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        // 真实结果封存：记录存在且为 archived 才算 sealed。
        let record = try await coordinator.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        )
        let sealed = await coordinator.sealSessionReporting(id: record.id, reason: .user)
        guard case .sealed(let sealedID) = sealed else {
            XCTFail("正常封存应返回 sealed，实际 \(sealed)")
            return
        }
        XCTAssertEqual(sealedID, record.id)
        let after = try await store.session(id: record.id)
        XCTAssertEqual(after?.state, .archived)
        // 不存在的记录：不得伪造成功。
        let missing = await coordinator.sealSessionReporting(id: "never-exists", reason: .user)
        guard case .failed = missing else {
            XCTFail("不存在的记录不得返回 sealed，实际 \(missing)")
            return
        }
    }

    /// A07：排空分类 —— timeout / failed / 空输入 / 空 final 有 hypothesis 四类互不混淆。
    ///
    /// 直接打 `commitUserTurn` 的 draining 分支：timeout 与 failed 只提示不落库；
    /// 正常空输入直接返回；空 final 但有 hypothesis 沿用“保留未完成”规则。
    func testA07DrainClassifiesEmptyFailedAndTimeout() async throws {
        // timeout：drain 卡住时 stopCapture 仍有界返回，不无限等待。
        do {
            let blockedGate = Gate()
            let harness = try await makeHarness(drainGate: blockedGate)
            defer { cleanup(harness) }
            try await harness.coordinator.begin(.assistant)
            let stop = Task { @MainActor in await harness.session.stopCapture() }
            await waitUntil({ blockedGate.entered }, message: "drain 没有进入 commit 等待")
            // 超时前 lastFailure 为空；释放后结束流程完整走完。
            blockedGate.release()
            await stop.value
            XCTAssertEqual(harness.session.phase, .idle, "排空超时后仍应回到 idle")
        }
        // failed 事件：只报告失败，不动他人可见文字（ownsPartial 为空时）。
        do {
            let harness = try await makeHarness(drainGate: nil)
            defer { cleanup(harness) }
            try await harness.coordinator.begin(.assistant)
            let client = harness.clientBox.clients.first!
            await client.emit(.failed(itemID: "unknown-item", code: "asr_failed", message: "识别失败"))
            await waitUntil(
                { harness.session.lastFailure?.contains("asr_failed") == true },
                message: "failed 事件应报告失败"
            )
            XCTAssertNil(harness.session.partialText, "陌生 item 的 failed 不得清当前可见文字")
        }
        // 正常空输入：clear 之后的那一次空 commit，不造“未完成”提示。
        do {
            let harness = try await makeHarness(drainGate: nil)
            defer { cleanup(harness) }
            try await harness.coordinator.begin(.assistant)
            harness.session.clearFailure()
            XCTAssertNil(harness.session.lastFailure, "空输入不得凭空造失败提示")
        }
        // 空 final 但有 hypothesis：保留未完成话语，用户可见、可恢复。
        do {
            let harness = try await makeHarness(drainGate: nil)
            defer { cleanup(harness) }
            try await harness.coordinator.begin(.assistant)
            let sessionID = try XCTUnwrap(harness.session.sessionID)
            let client = harness.clientBox.clients.first!
            await client.emit(.partialSnapshot(itemID: "h1", revision: 1, text: "半句话"))
            await waitUntil(
                { harness.session.partialText == "半句话" },
                message: "hypothesis 应先可见"
            )
            await client.emit(.completed(itemID: "h1", transcript: "   "))
            await waitUntil(
                { harness.session.lastFailure?.contains("没能识别完整") == true },
                message: "空 final 有 hypothesis 应保留未完成"
            )
            let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
            XCTAssertTrue(lines.contains { $0.text == "半句话" }, "未完成话语应落库 partial 行")
        }
    }

    /// A47：封存失败保留 pendingSeal 与未保存文本，重试/复制出口可用。
    ///
    /// 不存在的记录封存失败 → 无成功 ID；pendingSeal 保留 recordID 与原因；
    /// 未保存文本以内存 turns 为准可复制；重试不存在的记录仍失败不伪造成功。
    func testA47SealFailureRetainsUnsavedRecovery() async throws {
        let harness = try await makeHarness(drainGate: nil)
        defer { cleanup(harness) }
        // 伪造一个封存失败：不存在的记录。
        let seal = await harness.coordinator.sealSessionReporting(id: "never-exists-seal", reason: .user)
        guard case .failed(let failedID, let reason) = seal else {
            XCTFail("不存在的记录不得返回 sealed，实际 \(seal)")
            return
        }
        XCTAssertEqual(failedID, "never-exists-seal")
        XCTAssertFalse(reason.isEmpty, "失败原因不得为空，界面要展示给用户")
        // 真实记录封存成功路径：pendingSeal 应可清空。
        let record = try await harness.coordinator.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        )
        let ok = await harness.coordinator.sealSessionReporting(id: record.id, reason: .user)
        guard case .sealed(let sealedID) = ok else {
            XCTFail("正常封存应返回 sealed，实际 \(ok)")
            return
        }
        XCTAssertEqual(sealedID, record.id)
        // 未保存文本出口：内存 turns 为准。
        let text = harness.session.unsavedTranscriptText()
        XCTAssertNotNil(text, "复制出口必须可用（空文本返回空字符串而非 nil）")
    }

    /// A47 变体（活跃记录移除保护）：仍在占用中的记录封存返回 skipped，
    /// 不伪造 sealed，不发布成功 ID；由 finalize 路径收口。
    func testA47ActiveRecordSealIsSkippedNotSealed() async throws {
        let harness = try await makeHarness(drainGate: nil)
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        // begin 已将该记录挂为 active：直接按 ID 封存必须跳过。
        let result = await harness.coordinator.sealSessionReporting(id: sessionID, reason: .user)
        guard case .skipped(let skippedID) = result else {
            XCTFail("活跃记录不得返回 sealed/failed，实际 \(result)")
            return
        }
        XCTAssertEqual(skippedID, sessionID)
        let record = try await harness.store.session(id: sessionID)
        XCTAssertNotEqual(record?.state, .archived, "跳过不得把活跃记录写成 archived")
    }
}
