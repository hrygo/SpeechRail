import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// **生产 `AssistantSession`** 的端到端编排回归。
///
/// 这里不另写一份仿制状态机：`AssistantSession` 本体被编译进测试目标，
/// 外部依赖经 `AssistantSessionDependencies` 换成假实现，所以 start / ask / end
/// 走的是与 App 完全相同的那条代码。假实现不读钥匙串、不连 loopback、
/// 不构造 `AVAudioEngine`。
@MainActor
final class AssistantSessionTests: XCTestCase {
    // MARK: - 可暂停的闸门

    /// 把某个 await 卡在"已经进来、还没返回"，用来把竞态按到确定的顺序上。
    /// 不靠 `sleep` 碰运气。
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private var armed: Bool
        private var enteredCount = 0

        var entered: Bool { lock.withLock { enteredCount > 0 } }
        var entryCount: Int { lock.withLock { enteredCount } }

        /// `armed: false` 时闸门是开的：用来只拦住**后面**某一次调用
        /// （例如"只拦重连那一次建连"），而不是把首次启动也卡住。
        init(armed: Bool = true) {
            self.armed = armed
        }

        /// 开始拦截后续的 `enter()`。
        func arm() {
            lock.withLock {
                armed = true
                released = false
            }
        }

        func enter() async {
            let shouldBlock = lock.withLock { () -> Bool in
                enteredCount += 1
                return armed && !released
            }
            guard shouldBlock else { return }
            // 响应取消：被顶替的那一轮必须能真的离开 await，
            // 否则测试会以"旧任务永远挂着"的形式挂死，而不是给出断言。
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let shouldResume = lock.withLock { () -> Bool in
                        guard !released else { return true }
                        self.continuation = continuation
                        return false
                    }
                    if shouldResume { continuation.resume() }
                }
            } onCancel: {
                release()
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

    // MARK: - 假 LLM

    actor FakeAssistantLLM: AssistantLLM {
        enum Script: Sendable {
            case deltas([String])
            case failure(String)
            /// 先吐几段，再失败——D06 的真实形状：首段已经说出口了，provider 才断。
            case deltasThenFailure([String], String)
            /// 吐完给定的几段之后**卡住**，让测试可以在回复仍在生成时按下 ESC / 插话。
            case gatedDeltas([String], Gate)
        }

        private(set) var checkCount = 0
        private(set) var streamCount = 0
        private var scripts: [Script]
        private var isReady: LLMConnectionResult

        init(
            scripts: [Script] = [],
            isReady: LLMConnectionResult = .connected(milliseconds: 1, model: "test-model")
        ) {
            self.scripts = scripts
            self.isReady = isReady
        }

        func check(
            configuration: LLMConfiguration,
            apiKey: String?,
            operation: LLMOperation,
            allowThinkingControlFallback: Bool
        ) async -> LLMConnectionResult {
            checkCount += 1
            return isReady
        }

        func stream(
            configuration: LLMConfiguration,
            messages: [LLMMessage],
            apiKey: String?,
            maxOutputTokens: Int?,
            instructions: String?
        ) async -> AsyncThrowingStream<String, Error> {
            streamCount += 1
            let script = scripts.isEmpty ? Script.deltas([]) : scripts.removeFirst()
            return AsyncThrowingStream { continuation in
                switch script {
                case .deltas(let pieces):
                    for piece in pieces { continuation.yield(piece) }
                    continuation.finish()
                case .failure(let message):
                    continuation.finish(throwing: FakeAssistantError.llm(message))
                case .deltasThenFailure(let pieces, let message):
                    for piece in pieces { continuation.yield(piece) }
                    continuation.finish(throwing: FakeAssistantError.llm(message))
                case .gatedDeltas(let pieces, let gate):
                    for piece in pieces { continuation.yield(piece) }
                    // `AsyncThrowingStream` 的 build 闭包是同步的，不能直接 await。
                    Task {
                        await gate.enter()
                        continuation.finish()
                    }
                }
            }
        }
    }

    enum FakeAssistantError: LocalizedError, Equatable {
        case llm(String)
        case connect
        case drain

        var errorDescription: String? {
            switch self {
            case .llm(let message): message
            case .connect: "连接失败"
            case .drain: "收尾失败"
            }
        }
    }

    // MARK: - 假 Realtime 连接

    actor FakeAssistantRealtime: AssistantRealtimeClient {
        struct Counters: Sendable, Equatable {
            var connect = 0
            var close = 0
            var append = 0
            var drain = 0
            var startTTS = 0
            var cancelTTS = 0
            var updateVoice = 0
        }

        private let stream: RealtimeEventStream<RealtimeASRClient.Event>
        private let connectGate: Gate?
        private let drainGate: Gate?
        private let appendGate: Gate?
        private let connectFailure: Error?
        private let drainFailure: Error?
        private var counters = Counters()
        private(set) var receivedAudioBytes = 0
        private(set) var configurations: [AssistantRealtimeClientConfiguration] = []
        private var ttsRequestID = ""
        private let autoConfirmTTSCancel: Bool
        private var ttsAcceptedCodepoints = 0

        init(
            connectGate: Gate? = nil,
            drainGate: Gate? = nil,
            appendGate: Gate? = nil,
            connectFailure: Error? = nil,
            drainFailure: Error? = nil,
            autoConfirmTTSCancel: Bool = true
        ) {
            self.stream = RealtimeEventStream()
            self.connectGate = connectGate
            self.drainGate = drainGate
            self.appendGate = appendGate
            self.connectFailure = connectFailure
            self.drainFailure = drainFailure
            self.autoConfirmTTSCancel = autoConfirmTTSCancel
        }

        func events() async -> RealtimeEventStream<RealtimeASRClient.Event> { stream }

        func connect() async throws {
            counters.connect += 1
            if let connectGate { await connectGate.enter() }
            if let connectFailure { throw connectFailure }
        }

        func close() async {
            counters.close += 1
            await stream.finish()
        }

        func append(_ pcm: Data) async throws {
            counters.append += 1
            receivedAudioBytes += pcm.count
            if let appendGate { await appendGate.enter() }
        }

        func drainAndClear(timeout: Duration) async throws {
            counters.drain += 1
            if let drainGate { await drainGate.enter() }
            if let drainFailure { throw drainFailure }
        }

        func updateVoice(
            _ voice: String,
            expectedVoiceRevision: String?,
            expectedTTSRevision: String?
        ) async throws {
            counters.updateVoice += 1
        }

        func startTTSStream(requestID: String, speed: Double?) async throws {
            counters.startTTS += 1
            ttsRequestID = requestID
            ttsAcceptedCodepoints = 0
            // 真服务会立刻回 started；不回的话 `AssistantTTSStreamCoordinator`
            // 会一直等，测试就会挂在一个跟被测行为无关的地方。
            await emit(
                .ttsStarted(requestID: requestID, taskID: "task_\(requestID)", limits: nil)
            )
        }

        func appendTTSText(_ text: String, sequence: Int) async throws {
            // ACK 表示"文本已被接受"，`totalCodepoints` 是累计值——语义同真服务。
            ttsAcceptedCodepoints += text.count
            await emit(
                .ttsTextAccepted(
                    requestID: ttsRequestID,
                    taskID: nil,
                    appendSequence: sequence,
                    totalCodepoints: ttsAcceptedCodepoints
                )
            )
        }

        func finishTTSText(lastSequence: Int) async throws {}

        func cancelTTS() async throws {
            counters.cancelTTS += 1
            // 真服务在取消之后会回一个匹配 requestID 的终态。默认模拟它，
            // 关掉它就能验证"服务端一直没确认"的那条分支。
            if autoConfirmTTSCancel, !ttsRequestID.isEmpty {
                await emit(
                    .ttsEnded(
                        requestID: ttsRequestID,
                        taskID: nil,
                        status: "cancelled",
                        code: nil,
                        message: nil
                    )
                )
            }
        }

        func emit(_ payload: RealtimeASRClient.Event) async {
            _ = await stream.yield(
                RealtimeEventEnvelope(
                    metadata: RealtimeEventMetadata(
                        eventID: UUID().uuidString,
                        sessionID: "assistant-test",
                        sequence: nil
                    ),
                    payload: payload
                )
            )
        }

        func snapshot() -> Counters { counters }
    }

    // MARK: - 假音频

    /// 同时充当采集来源与播放端。计数用来证明"设备有没有真的被交出去/收回"。
    final class FakeAssistantAudio: AssistantAudioSession, @unchecked Sendable {
        private let lock = NSLock()
        private var _startCount = 0
        private var _stopCount = 0
        private var _playbackStopCount = 0
        private var _enqueuedBytes = 0
        private var _enqueuedEpochs: [Int] = []
        private let startFailure: Error?
        private let captureContinuation: AsyncStream<AudioChunk>.Continuation?
        private let captureStream: AsyncStream<AudioChunk>?

        var onPlaybackDrained: (@MainActor () -> Void)?
        var onPlaybackBufferRendered: (@MainActor (Int, Int) -> Void)?
        var onFailure: (@MainActor (String) -> Void)?
        var onPlaybackInvalidated: (@MainActor (AssistantAudioInvalidation) async -> Void)?

        /// 模拟"切换输出设备/耳机，引擎重建并丢掉了这一轮还没播完的缓冲"（D05）。
        func emitPlaybackInvalidated(recovered: Bool, message: String? = nil) async {
            await onPlaybackInvalidated?(
                AssistantAudioInvalidation(
                    deviceGeneration: Int.random(in: 1...9999),
                    recovered: recovered,
                    message: message
                )
            )
        }

        init(startFailure: Error? = nil, autoStartCapture: Bool = false) {
            self.startFailure = startFailure
            if autoStartCapture {
                var continuation: AsyncStream<AudioChunk>.Continuation?
                self.captureStream = AsyncStream { continuation = $0 }
                self.captureContinuation = continuation
            } else {
                self.captureStream = nil
                self.captureContinuation = nil
            }
        }

        var startCount: Int { lock.withLock { _startCount } }
        var stopCount: Int { lock.withLock { _stopCount } }
        var playbackStopCount: Int { lock.withLock { _playbackStopCount } }
        var enqueuedBytes: Int { lock.withLock { _enqueuedBytes } }
        var enqueuedEpochs: [Int] { lock.withLock { _enqueuedEpochs } }

        func configure(mode: AssistantMode) {}

        func start() async throws -> AsyncStream<AudioChunk> {
            lock.withLock { _startCount += 1 }
            if let startFailure { throw startFailure }
            if let captureStream { return captureStream }
            return AsyncStream { _ in }
        }

        func stop() { lock.withLock { _stopCount += 1 } }

        /// 往采集流里塞一块音频，验证上行确实发生了。
        func emitCapture(_ chunk: AudioChunk) {
            captureContinuation?.yield(chunk)
        }

        @discardableResult
        func enqueuePlayback(_ pcm: Data, epoch: Int) async -> Bool {
            lock.withLock {
                _enqueuedBytes += pcm.count
                _enqueuedEpochs.append(epoch)
            }
            return true
        }

        func stopPlayback() async {
            lock.withLock { _playbackStopCount += 1 }
        }

        /// 模拟"这一块真的播完了"。
        func render(samples: Int, epoch: Int) {
            let rendered = onPlaybackBufferRendered
            Task { @MainActor in rendered?(epoch, samples) }
        }
    }

    // MARK: - 夹具

    /// 测试夹具。成员各自已经是 MainActor / actor / `@unchecked Sendable`，
    /// 并且只在这份测试的 MainActor 上下文里传递；`@unchecked` 只是为了让
    /// `addTeardownBlock` 的 `@Sendable` 收尾闭包能捕获它。
    struct Harness: @unchecked Sendable {
        let session: AssistantSession
        let coordinator: SessionCoordinator
        let store: SessionStore
        let llm: FakeAssistantLLM
        let audio: FakeAssistantAudio
        let clients: () -> [FakeAssistantRealtime]
        let configurations: () -> [AssistantRealtimeClientConfiguration]
        let defaults: UserDefaults
        let directory: URL
    }

    private func makeHarness(
        llmScripts: [FakeAssistantLLM.Script] = [],
        llmIsReady: LLMConnectionResult = .connected(milliseconds: 1, model: "test-model"),
        audioStartFailure: Error? = nil,
        autoStartCapture: Bool = true,
        connectGate: Gate? = nil,
        drainGate: Gate? = nil,
        appendGate: Gate? = nil,
        connectFailure: Error? = nil,
        drainFailure: Error? = nil,
        autoConfirmTTSCancel: Bool = true,
        capability: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        let suiteName = "assistant-session-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()

        let llm = FakeAssistantLLM(scripts: llmScripts, isReady: llmIsReady)
        let audio = FakeAssistantAudio(
            startFailure: audioStartFailure,
            autoStartCapture: autoStartCapture
        )
        let box = ClientBox()
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"

        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies(
                llm: llm,
                makeRealtimeClient: { configuration in
                    let client = FakeAssistantRealtime(
                        connectGate: connectGate,
                        drainGate: drainGate,
                        appendGate: appendGate,
                        connectFailure: connectFailure,
                        drainFailure: drainFailure,
                        autoConfirmTTSCancel: autoConfirmTTSCancel
                    )
                    box.append(client, configuration: configuration)
                    return client
                },
                now: now
            )
        )
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        session.audioSourceFactory = { audio }
        session.realtimeCapabilityBindingProvider = { _ in
            capability
                ? RealtimeCapabilityBinding(
                    asrModelRevision: "asr-1",
                    canonicalVoiceID: "voice-1",
                    voiceRevision: "v-1",
                    ttsModelRevision: "tts-1"
                )
                : RealtimeCapabilityBinding(asrModelRevision: "asr-1")
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

    /// `makeRealtimeClient` 是 `@Sendable` 闭包，不能直接碰 MainActor 状态；
    /// 这里用锁把建连记录收下来，测试在 MainActor 上读。
    final class ClientBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedClients: [FakeAssistantRealtime] = []
        private var storedConfigurations: [AssistantRealtimeClientConfiguration] = []

        var clients: [FakeAssistantRealtime] { lock.withLock { storedClients } }
        var configurations: [AssistantRealtimeClientConfiguration] {
            lock.withLock { storedConfigurations }
        }

        func append(
            _ client: FakeAssistantRealtime,
            configuration: AssistantRealtimeClientConfiguration
        ) {
            lock.withLock {
                storedClients.append(client)
                storedConfigurations.append(configuration)
            }
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("unused")
        )
    }

    private func waitUntil(
        _ condition: () -> Bool,
        iterations: Int = 600,
        message: String = "condition was not met"
    ) async {
        for _ in 0..<iterations {
            if condition() { return }
            // 只 `Task.yield()` 的话 600 次会在微秒级跑完，条件还没来得及成立就判失败。
            // 1ms × 600 = 最多 600ms 的有界等待：不靠它同步，只是不至于慢十倍。
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(message)
    }

    private func cleanup(_ harness: Harness) {
        try? FileManager.default.removeItem(at: harness.directory)
        harness.defaults.removePersistentDomain(forName: harness.defaults.description)
    }

    /// 收尾必须**真的结束这一场**：`AssistantTTSStreamCoordinator` 的文本泵是
    /// `Task { @MainActor … }`，测试不结束会话它就继续按 `tickInterval` 空转。
    /// SwiftPM 跑完直接退进程，看不见；Xcode test bundle 会等它，于是整轮
    /// `--test-unit` 挂住。删除临时目录不会停它，所以顺序是「先 stopCapture，
    /// 再清目录」。
    ///
    /// 刻意不捕获 `self`：`addTeardownBlock` 的闭包是 `@Sendable`。
    private static func stopAndCleanUp(_ harness: Harness) async {
        await harness.session.stopCapture()
        try? FileManager.default.removeItem(at: harness.directory)
        harness.defaults.removePersistentDomain(forName: harness.defaults.description)
    }


    // MARK: - §7.2 跨层 fixture：App 侧消费服务端同一份事件序列

    private struct LifecycleFixture: Decodable {
        struct Scenario: Decodable {
            let id: String
            let covers: [String]
            struct ServerEvent: Decodable {
                let type: String
                let requestID: String?
                let appendSequence: Int?
                let totalCodepoints: Int?
                let acceptedCodepoints: Int?
                let itemRef: String?
                let contentIndex: Int?
                let transcript: String?
                let commitEventID: String?
                let sequence: Int?
                let limits: Limits?
                let error: WireError?

                enum CodingKeys: String, CodingKey {
                    case type
                    case requestID = "request_id"
                    case appendSequence = "append_sequence"
                    case totalCodepoints = "total_codepoints"
                    case acceptedCodepoints = "accepted_codepoints"
                    case itemRef = "item_ref"
                    case contentIndex = "content_index"
                    case transcript
                    case commitEventID = "commit_event_id"
                    case sequence
                    case limits
                    case error
                }
            }

            struct Limits: Decodable {
                let maxAppendCodepoints: Int
                let maxTotalCodepoints: Int
                let maxPendingCodepoints: Int
                let maxPendingAudioBytes: Int

                enum CodingKeys: String, CodingKey {
                    case maxAppendCodepoints = "max_append_codepoints"
                    case maxTotalCodepoints = "max_total_codepoints"
                    case maxPendingCodepoints = "max_pending_codepoints"
                    case maxPendingAudioBytes = "max_pending_audio_bytes"
                }
            }

            struct WireError: Decodable {
                let type: String
                let code: String
                let message: String
            }

            struct AppExpectation: Decodable {
                struct Row: Decodable {
                    let text: String
                    let interrupted: Bool?
                    let hasCreatedAt: Bool?
                    let tStartIsNull: Bool?
                    let tEndIsNull: Bool?

                    enum CodingKeys: String, CodingKey {
                        case text
                        case interrupted
                        case hasCreatedAt = "has_created_at"
                        case tStartIsNull = "t_start_is_null"
                        case tEndIsNull = "t_end_is_null"
                    }
                }

                let ttsAppendedText: String?
                let rawReplyText: String?
                let assistantRows: [Row]?
                let userRows: [Row]?
                let sameRecordAfterRetry: Bool?
                let recordCountAfterRetry: Int?
                let historyPreserved: Bool?

                enum CodingKeys: String, CodingKey {
                    case ttsAppendedText = "tts_appended_text"
                    case rawReplyText = "raw_reply_text"
                    case assistantRows = "assistant_rows"
                    case userRows = "user_rows"
                    case sameRecordAfterRetry = "same_record_after_retry"
                    case recordCountAfterRetry = "record_count_after_retry"
                    case historyPreserved = "history_preserved"
                }
            }

            let summary: String
            let serverEvents: [ServerEvent]
            let appExpectation: AppExpectation
            let appInputs: AppInputs

            enum CodingKeys: String, CodingKey {
                case id
                case covers
                case summary
                case serverEvents = "server_events"
                case appExpectation = "app_expectation"
                case appInputs = "app_inputs"
            }

            /// App 侧驱动生产会话要用的输入。与 `client_script` 同源，避免
            /// Swift 侧自己另写一份"看起来一样"的文本。
            struct AppInputs: Decodable {
                let replyDeltas: [String]?
                let userTranscripts: [String]?
                let rejectedUpdateCode: String?

                enum CodingKeys: String, CodingKey {
                    case replyDeltas = "reply_deltas"
                    case userTranscripts = "user_transcripts"
                    case rejectedUpdateCode = "rejected_update_code"
                }
            }
        }

        let version: Int
        let scenarios: [Scenario]

        enum CodingKeys: String, CodingKey {
            case version
            case scenarios
        }

        init() throws {
            let data = try Data(contentsOf: Self.url())
            self = try JSONDecoder().decode(Self.self, from: data)
        }

        static func url() -> URL {
            // 用 `#filePath` 从**源文件**定位，不依赖当前工作目录，所以 SwiftPM
            // 与 Xcode test bundle 读到的是同一份文件。
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<3 { root.deleteLastPathComponent() }
            root.deleteLastPathComponent()
            return root
                .appendingPathComponent("tests/fixtures/assistant_realtime_lifecycle.json")
        }

        func scenario(_ id: String) throws -> Scenario {
            try XCTUnwrap(
                scenarios.first { $0.id == id },
                "共享 fixture 里没有场景 \(id)"
            )
        }
    }

    /// 按 fixture 的 `server_events` 应答的 Realtime 客户端。
    ///
    /// 它**不是**另写的模拟协议：每一个下行事件都取自服务端实际录下的那一份
    /// `server_events`（`tts.started` / `text_accepted` / terminal 全部来自
    /// fixture），上行调用则被记录下来供断言。服务端时序变了，Python 侧先红；
    /// 这里消费的是同一份文件，所以两侧不会各自通过。
    private final class FixtureRealtime: AssistantRealtimeClient, @unchecked Sendable {
        private let stream: RealtimeEventStream<RealtimeASRClient.Event>
        private let events: [LifecycleFixture.Scenario.ServerEvent]
        private let lock = NSLock()
        private var state = State()

        private struct State {
            var appended: [(requestID: String, sequence: Int, text: String)] = []
            var startedRequestIDs: [String] = []
            var cancelledFixtureRequestIDs: [String] = []
            var terminalCounts: [String: Int] = [:]
            var closeCount = 0
            /// fixture 中已被本轮 ``start`` 选中的那一轮 utterance 的身份。
            var activeFixtureRequestID: String?
            var servedStarts = 0
            var servedFinals = 0
        }

        init(events: [LifecycleFixture.Scenario.ServerEvent]) {
            self.events = events
            self.stream = RealtimeEventStream()
        }

        // MARK: 断言入口

        var ttsAppendRecords: [(requestID: String, sequence: Int, text: String)] {
            lock.withLock { state.appended }
        }

        var ttsAppendedText: String { lock.withLock { state.appended.map(\.text).joined() } }
        var startedCount: Int { lock.withLock { state.startedRequestIDs.count } }
        var cancelledFixtureRequestIDs: [String] { lock.withLock { state.cancelledFixtureRequestIDs } }
        var terminalCounts: [String: Int] { lock.withLock { state.terminalCounts } }
        var closeCount: Int { lock.withLock { state.closeCount } }

        // MARK: AssistantRealtimeClient

        func events() async -> RealtimeEventStream<RealtimeASRClient.Event> { stream }
        func connect() async throws {}

        func close() async {
            lock.withLock { state.closeCount += 1 }
            await stream.finish()
        }

        func append(_ pcm: Data) async throws {}
        func drainAndClear(timeout: Duration) async throws {}

        func updateVoice(
            _ voice: String,
            expectedVoiceRevision: String?,
            expectedTTSRevision: String?
        ) async throws {}

        /// App 自选 ``request_id``，fixture 记录的是服务端那一轮的身份。这里把
        /// 两者映射起来：**内容**（准入、ACK 计数、终态）取自 fixture，**身份**
        /// 用 App 自己的，与真服务一致。
        func startTTSStream(requestID: String, speed: Double?) async throws {
            let started = lock.withLock { () -> LifecycleFixture.Scenario.ServerEvent? in
                let starts = events.filter {
                    $0.type == "speechrail.tts.started" && $0.requestID != nil
                }
                guard state.servedStarts < starts.count else { return nil }
                let event = starts[state.servedStarts]
                state.servedStarts += 1
                state.startedRequestIDs.append(requestID)
                state.activeFixtureRequestID = event.requestID
                return event
            }
            guard let started else { return }
            await emit(
                .ttsStarted(
                    requestID: requestID,
                    taskID: "task_fixture",
                    limits: started.limits.map(Self.limits(from:))
                )
            )
        }

        func appendTTSText(_ text: String, sequence: Int) async throws {
            let matched = lock.withLock { () -> (String, LifecycleFixture.Scenario.ServerEvent)? in
                let requestID = state.startedRequestIDs.last ?? ""
                state.appended.append((requestID, sequence, text))
                let accepted = events.first {
                    $0.type == "speechrail.tts.text_accepted"
                        && $0.requestID == state.activeFixtureRequestID
                        && $0.appendSequence == sequence
                }
                return accepted.map { (requestID, $0) }
            }
            guard let (requestID, accepted) = matched else { return }
            await emit(
                .ttsTextAccepted(
                    requestID: requestID,
                    taskID: "task_fixture",
                    appendSequence: sequence,
                    totalCodepoints: accepted.totalCodepoints ?? 0
                )
            )
        }

        func finishTTSText(lastSequence: Int) async throws {
            let target: (app: String, fixture: String?) = lock.withLock {
                let fixture = state.activeFixtureRequestID
                state.activeFixtureRequestID = nil
                return (state.startedRequestIDs.last ?? "", fixture)
            }
            await emitTerminal(app: target.app, fixture: target.fixture, status: "completed")
        }

        func cancelTTS() async throws {
            let target: (app: String, fixture: String?) = lock.withLock {
                let fixture = state.activeFixtureRequestID
                state.activeFixtureRequestID = nil
                if let fixture {
                    state.cancelledFixtureRequestIDs.append(fixture)
                }
                return (state.startedRequestIDs.last ?? "", fixture)
            }
            await emitTerminal(app: target.app, fixture: target.fixture, status: "cancelled")
        }

        // MARK: fixture 驱动的下行

        func emitConfigured() async {
            await emit(.ready(model: "speechrail/qwen3-asr-1.7b"))
            await emit(.configured)
        }

        /// ASR 终态不是请求/响应，由测试按 fixture 顺序推进。item_id 在 wire 上
        /// 每句都不同，fixture 用 `<item:N>` 占位，这里按序号生成可区分的身份。
        func emitNextASRFinal() async -> Bool {
            let finals = events.filter {
                $0.type == "conversation.item.input_audio_transcription.completed"
            }
            let sent = lock.withLock { state.servedFinals }
            guard sent < finals.count else { return false }
            lock.withLock { state.servedFinals += 1 }
            await emit(
                .completed(
                    itemID: "item_fixture_\(sent)",
                    transcript: finals[sent].transcript ?? ""
                )
            )
            return true
        }

        func emitRejectedUpdate() async {
            guard let event = events.first(where: { $0.type == "error" }) else { return }
            await emit(
                .serverError(
                    code: event.error?.code ?? "",
                    message: event.error?.message ?? "",
                    requestID: "evt-bad-update"
                )
            )
        }

        func emit(_ payload: RealtimeASRClient.Event) async {
            _ = await stream.yield(
                RealtimeEventEnvelope(
                    metadata: RealtimeEventMetadata(
                        eventID: UUID().uuidString,
                        sessionID: "assistant-fixture",
                        sequence: nil
                    ),
                    payload: payload
                )
            )
        }

        // MARK: 私有

        private static func limits(
            from value: LifecycleFixture.Scenario.Limits
        ) -> TTSStreamLimits {
            let fallback = TTSStreamLimits.serverDefaults
            return TTSStreamLimits(
                maxAppendCodepoints: value.maxAppendCodepoints,
                maxTotalCodepoints: value.maxTotalCodepoints,
                maxPendingCodepoints: value.maxPendingCodepoints,
                maxPendingAudioBytes: value.maxPendingAudioBytes,
                inputWaitSeconds: fallback.inputWaitSeconds,
                utteranceWallClockSeconds: fallback.utteranceWallClockSeconds,
                slowConsumerSeconds: fallback.slowConsumerSeconds
            )
        }

        /// 终态只在 fixture 为**这一轮**记录过时才发；fixture 里没有就保持沉默，
        /// 让「服务端一直没确认」那条分支仍然可测。
        private func emitTerminal(app: String, fixture: String?, status: String) async {
            let type = "speechrail.tts.\(status)"
            guard let fixture,
                  events.contains(where: { $0.type == type && $0.requestID == fixture })
            else { return }
            lock.withLock { state.terminalCounts[type, default: 0] += 1 }
            await emit(
                .ttsEnded(
                    requestID: app,
                    taskID: "task_fixture",
                    status: status,
                    code: nil,
                    message: nil
                )
            )
        }
    }

    // MARK: - §7.2 跨层 fixture：四组闭环

    /// 与 `makeHarness` 同一套生产编排，只把 Realtime 客户端换成 fixture 驱动版。
    private func makeFixtureHarness(
        _ scenario: LifecycleFixture.Scenario,
        llmScripts: [FakeAssistantLLM.Script],
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> (Harness, FixtureRealtime) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-fixture-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        let suiteName = "assistant-fixture-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()

        let client = FixtureRealtime(events: scenario.serverEvents)
        let llm = FakeAssistantLLM(scripts: llmScripts, isReady: .connected(milliseconds: 1, model: "test-model"))
        let audio = FakeAssistantAudio()
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"

        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies(
                llm: llm,
                makeRealtimeClient: { _ in client },
                now: now
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
        let harness = Harness(
            session: session,
            coordinator: coordinator,
            store: store,
            llm: llm,
            audio: audio,
            clients: { [] },
            configurations: { [] },
            defaults: defaults,
            directory: directory
        )
        return (harness, client)
    }

    /// 1. 打断闭环（D01/D06/D08 + B02/B05）：App 消费服务端录下的
    /// started/ACK/cancelled，确认远端空闲后连接仍然可用，回复按打断收成一行。
    func testFixtureBargeInClosure() async throws {
        let scenario = try LifecycleFixture().scenario("barge_in_closure")
        let deltas = try XCTUnwrap(scenario.appInputs.replyDeltas)
        let gate = Gate()
        let (harness, client) = try await makeFixtureHarness(
            scenario,
            llmScripts: [.gatedDeltas(deltas, gate)]
        )
        addTeardownBlock { await Self.stopAndCleanUp(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await client.emitConfigured()
        await client.emit(.completed(itemID: "i1", transcript: "念一句"))
        await waitUntil(
            { !client.ttsAppendRecords.isEmpty },
            message: "App 没有消费 fixture 里的 tts.started 与 ACK"
        )

        // 打断：App 停本地播放并向服务端发 cancel，服务端回 fixture 记录的终态。
        await harness.session.stopSpeaking()
        gate.release()
        await waitUntil(
            { client.cancelledFixtureRequestIDs == ["req_barge"] },
            message: "App 没有为这一轮发出 cancel"
        )
        await waitUntil(
            { harness.session.phase == .listening },
            message: "服务端确认终态之后应当回到聆听态"
        )

        let expected = try XCTUnwrap(try XCTUnwrap(scenario.appExpectation.assistantRows).first)
        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertEqual(assistantLines.count, 1, "一轮回复只能留下一行")
        let reply = try XCTUnwrap(assistantLines.first)
        XCTAssertEqual(reply.text, expected.text)
        XCTAssertEqual(reply.isInterrupted, expected.interrupted)
        XCTAssertEqual(client.ttsAppendedText, deltas.joined(), "空白与标点必须原样送进 TTS")
        XCTAssertEqual(client.closeCount, 0, "已确认的终态不该关连接")
        XCTAssertEqual(client.terminalCounts["speechrail.tts.cancelled"], 1)
        XCTAssertEqual(client.startedCount, 1, "被打断的这一轮只准入了一次")
    }

    /// 2. 长回复（D11 + B04/B07）：fixture 里的五个增量包含单独空格、换行与
    /// 连续空白。**落库正文**必须等于五个增量的原样拼接；送进 TTS 的是同一条
    /// 文本经 `VoicePrompt.spokenText` 清洗后的结果，那是产品有意保留的朗读
    /// 清洗层，不是空白丢失。
    func testFixtureLongReplyPreservesEveryWhitespaceDelta() async throws {
        let scenario = try LifecycleFixture().scenario("long_reply")
        let deltas = try XCTUnwrap(scenario.appInputs.replyDeltas)
        let (harness, client) = try await makeFixtureHarness(
            scenario,
            llmScripts: [.deltas(deltas)]
        )
        addTeardownBlock { await Self.stopAndCleanUp(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await client.emitConfigured()
        await client.emit(.completed(itemID: "i1", transcript: "念一句"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "回复没有落库"
        )

        let rawWant = try XCTUnwrap(scenario.appExpectation.rawReplyText)
        XCTAssertEqual(
            rawWant,
            deltas.joined(),
            "fixture 的 raw_reply_text 必须等于五个增量的原样拼接"
        )
        let spokenWant = try XCTUnwrap(scenario.appExpectation.ttsAppendedText)
        XCTAssertEqual(
            client.ttsAppendedText,
            spokenWant,
            "朗读文本应是原样正文经 spokenText 清洗的结果"
        )
        XCTAssertEqual(
            client.ttsAppendRecords.map(\.sequence),
            Array(0..<client.ttsAppendRecords.count),
            "append 序号必须从 0 连续递增，不跳号不倒退"
        )
        XCTAssertEqual(client.terminalCounts["speechrail.tts.completed"], 1)

        let expected = try XCTUnwrap(try XCTUnwrap(scenario.appExpectation.assistantRows).first)
        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let reply = try XCTUnwrap(lines.first { $0.role == .assistant })
        XCTAssertEqual(reply.text, expected.text, "落库正文必须保留原始空白（D11）")
        XCTAssertEqual(reply.text, rawWant)
        XCTAssertEqual(reply.isInterrupted, expected.interrupted)
    }

    /// 3. 输入分包（D09 + B01/B03/B06）：两个 item 各自落一行、各有观测时刻，
    /// 精确时轴缺失时存 NULL 而不是拿会话起点冒充（D09）。
    func testFixturePacketizationBecomesTwoDatedUserRows() async throws {
        let scenario = try LifecycleFixture().scenario("input_packetization")
        let transcripts = try XCTUnwrap(scenario.appInputs.userTranscripts)
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let (harness, client) = try await makeFixtureHarness(
            scenario,
            llmScripts: [],
            now: { clock.now }
        )
        addTeardownBlock { await Self.stopAndCleanUp(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await client.emitConfigured()
        for transcript in transcripts {
            clock.advance(by: 5)
            let emitted = await client.emitNextASRFinal()
            XCTAssertTrue(emitted, "fixture 里的 ASR 终态比预期少")
            await waitUntil(
                { harness.session.turns.contains { $0.text == transcript } },
                message: "「\(transcript)」没有落库"
            )
        }

        let expected = try XCTUnwrap(scenario.appExpectation.userRows)
        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let userLines = lines.filter { $0.role == .user }
        XCTAssertEqual(userLines.count, transcripts.count, "每个 item 一行，不能多也不能少")
        for (line, want) in zip(userLines, expected) {
            XCTAssertEqual(line.text, want.text)
            XCTAssertEqual(want.hasCreatedAt, true)
            XCTAssertEqual(line.timingQuality, .unavailable, "没有精确时轴就标 unavailable")
            XCTAssertNil(line.tStart, "不能拿会话起点冒充发言起点")
            XCTAssertNil(line.tEnd)
        }
        XCTAssertEqual(
            userLines.map(\.createdAt),
            userLines.map(\.createdAt).sorted(),
            "观测时刻必须随证据顺序单调推进"
        )
    }

    /// 4. 断线恢复（D02/D03/D04 + B06/B08）：被拒的 session.update 不改变
    /// 运行态；断线后重连仍是同一条记录，不新建、不重置。
    ///
    /// 这一场用**纯文字**提问：fixture 里没有 TTS 事件，若驱动语音回复，App 会
    /// 一直等一个服务端从未录下的 `tts.started`——那测的是超时，不是本场景。
    func testFixtureRejectedUpdateAndReconnectKeepTheSameRecord() async throws {
        let scenario = try LifecycleFixture().scenario("reconnect_recovery")
        let (harness, client) = try await makeFixtureHarness(
            scenario,
            llmScripts: [.deltas(["一句话。"])]
        )
        addTeardownBlock { await Self.stopAndCleanUp(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await client.emitConfigured()
        await harness.session.ask(typed: "断线之前问的一句")
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "回复没有落库"
        )

        // 服务端拒绝一次配置更新（B08）：App 不能因此新建记录或丢掉已有内容。
        await client.emitRejectedUpdate()
        await waitUntil({ harness.session.lastFailure != nil }, message: "被拒的更新没有变成可见失败")
        XCTAssertEqual(harness.session.sessionID, sessionID, "被拒的更新不允许换记录")
        let countAfterRejection = try await harness.store.sessionCount()
        XCTAssertEqual(countAfterRejection, 1, "被拒的更新不允许新建记录")

        // 断线后重连：仍是同一条记录（D02/D03）。
        await client.emit(.closed(code: 1006))
        await waitUntil({ harness.session.blocked != nil }, message: "断线没有被处理")
        await harness.session.retry()
        await waitUntil({ harness.session.sessionID == sessionID }, message: "重连没有落回同一条记录")

        let expectation = scenario.appExpectation
        XCTAssertEqual(
            harness.session.sessionID,
            sessionID,
            "重连必须落在同一条记录上（fixture: \(String(describing: expectation.sameRecordAfterRetry))）"
        )
        let countAfterRetry = try await harness.store.sessionCount()
        XCTAssertEqual(
            countAfterRetry,
            try XCTUnwrap(expectation.recordCountAfterRetry),
            "重连不得新建记录"
        )
        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        XCTAssertEqual(
            lines.filter { $0.role == .user }.map(\.text),
            ["断线之前问的一句"],
            "重连之后历史不许丢（fixture: \(String(describing: expectation.historyPreserved))）"
        )
        XCTAssertEqual(lines.filter { $0.role == .assistant }.count, 1, "回复行也不许丢")
    }

    /// 假时钟：让"观测时刻随证据推进"成为可重现的断言，而不是靠 sleep 碰运气。
    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(start: Date) { self.current = start }

        var now: Date { lock.withLock { current } }

        func advance(by seconds: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }
    }

    // MARK: - 基线：这份夹具本身能跑通 start → ask → end

    func testDuplexUsesItsPauseWindowOnStartAndReconnect() async throws {
        let harness = try await makeHarness()
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        XCTAssertEqual(harness.configurations().map(\.silenceDurationMilliseconds), [900])

        await harness.clients()[0].emit(.closed(code: 1006))
        await waitUntil({ harness.session.blocked != nil }, message: "断线没有进入受阻态")
        await harness.session.retry()
        XCTAssertEqual(harness.configurations().map(\.silenceDurationMilliseconds), [900, 900])
    }

    func testTurnTakingWaitsLongerForQuestionCompletion() async throws {
        let harness = try await makeHarness()
        defer { cleanup(harness) }

        await harness.session.start(
            persona: SessionPreferences.catalog[0],
            voiceID: nil,
            mode: .turnTaking
        )
        await waitUntil({ harness.configurations().count == 1 }, message: "一问一答没有建连")
        XCTAssertEqual(harness.configurations()[0].silenceDurationMilliseconds, 1_200)
    }

    func testHarnessStartsAndStopsThroughTheProductionSession() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["你好", "。"])])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        XCTAssertEqual(harness.session.phase, .listening)
        XCTAssertNotNil(harness.session.sessionID, "开始之后必须真的建了记录")
        XCTAssertEqual(harness.audio.startCount, 1, "设备只被取一次")
        XCTAssertEqual(harness.clients().count, 1)
        await harness.clients()[0].emit(.configured)

        await harness.session.ask(typed: "今天天气怎么样")
        await waitUntil({ harness.session.turns.count == 1 }, message: "打字提问没有落库")
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "助手回复没有落库"
        )

        await harness.session.stopCapture()
        XCTAssertEqual(harness.audio.stopCount, 1, "结束时设备必须被收回")
        await waitUntil({ harness.audio.playbackStopCount >= 0 })
        let counters = await harness.clients()[0].snapshot()
        XCTAssertEqual(counters.drain, 1, "结束要走一次 drain")
        XCTAssertEqual(counters.close, 1, "连接必须关闭")
    }

    // MARK: - D02：启动没有所有权屏障

    /// 建连卡住时用户结束会话：晚到的 connect 不能再把这一轮复活，
    /// 也不能让设备留在会话手里。
    func testStoppingWhileConnectingDoesNotReviveTheSession() async throws {
        let connectGate = Gate()
        let harness = try await makeHarness(connectGate: connectGate)
        defer { cleanup(harness) }

        let start = Task { @MainActor in
            try await harness.coordinator.begin(.assistant)
        }
        await waitUntil({ connectGate.entered }, message: "启动没有停在建连上")

        await harness.session.stopCapture()
        connectGate.release()
        _ = await start.result

        XCTAssertNotEqual(
            harness.session.phase,
            .listening,
            "被取消的启动不允许把会话拉回聆听态"
        )
        XCTAssertNil(harness.session.sessionID, "被取消的启动不允许建记录")
        let counters = await harness.clients()[0].snapshot()
        XCTAssertEqual(counters.close, 1, "晚到的连接必须立刻关掉")
    }

    /// 麦克风起不来时，不能留下连接或设备占用。
    func testMicrophoneFailureReleasesEverythingItTook() async throws {
        let harness = try await makeHarness(audioStartFailure: FakeAssistantError.connect)
        defer { cleanup(harness) }

        do {
            try await harness.coordinator.begin(.assistant)
            XCTFail("麦克风失败必须抛出")
        } catch {
            XCTAssertNotNil(harness.session.blocked, "受阻必须给可读结论")
        }

        XCTAssertEqual(harness.clients().count, 0, "麦克风失败时还不该建连")
        XCTAssertEqual(harness.session.phase, .idle)
    }

    /// 连不上时不能留下设备。
    func testConnectFailureStopsCapture() async throws {
        let harness = try await makeHarness(connectFailure: FakeAssistantError.connect)
        defer { cleanup(harness) }

        do {
            try await harness.coordinator.begin(.assistant)
            XCTFail("建连失败必须抛出")
        } catch {
            XCTAssertNotNil(harness.session.blocked)
        }
        XCTAssertEqual(harness.audio.stopCount, 1, "建连失败必须把设备还回去")
        XCTAssertEqual(harness.session.phase, .idle)
    }

    // MARK: - D03：恢复和新建共享破坏性初始化

    /// 断线重连之后必须是**同一条记录**：记录数、sessionID、历史与序号都不变。
    /// 以前 `retry()` 走的是完整的 `startPipeline`，于是又建了一条记录、
    /// 又把 turns/history/ordinal 清零。
    func testReconnectKeepsTheSameRecordAndHistory() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltas(["第一句回答"]), .deltas(["第二句回答"])]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)

        await harness.session.ask(typed: "第一个问题")
        await waitUntil({ harness.session.turns.count == 2 }, message: "第一轮没有落库")
        let ordinalBefore = harness.session.turns.map(\.ordinal)

        // 断线
        await harness.clients()[0].emit(.closed(code: 1006))
        await waitUntil({ harness.session.blocked != nil }, message: "断线没有进入受阻态")
        XCTAssertEqual(harness.session.sessionID, sessionID, "断线不许换记录")

        await harness.session.retry()

        XCTAssertEqual(harness.session.sessionID, sessionID, "重连必须续用同一条记录")
        XCTAssertEqual(harness.session.turns.count, 2, "重连不许清空已落的对话")
        XCTAssertEqual(harness.session.turns.map(\.ordinal), ordinalBefore, "序号不许重排")
        XCTAssertEqual(harness.clients().count, 2, "重连应该建一条新连接")

        // 库里的记录数不许增加：仍然只有这一条助手记录。
        let recordCount = try await harness.store.sessionCount()
        XCTAssertEqual(recordCount, 1, "重连不许留下第二条记录")

        // 重连之后还能接着问，并且写进同一条记录。
        await harness.clients()[1].emit(.configured)
        await harness.session.ask(typed: "第二个问题")
        await waitUntil({ harness.session.turns.count == 4 }, message: "重连后的新一轮没有落进同一条记录")
        let lines = try await harness.store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.count, 4, "四行都必须在同一条记录里")
        XCTAssertEqual(
            lines.map(\.ordinal),
            [1, 2, 3, 4],
            "序号必须连续，不许因为重连而重排或跳号"
        )
    }

    /// 两次重试只能建一条连接（single-flight）。
    func testSecondRetryDoesNotOpenASecondConnection() async throws {
        // 只拦重连那一次建连，首次启动必须放行。
        let retryGate = Gate(armed: false)
        let harness = try await makeHarness(
            llmScripts: [.deltas(["回答"])],
            connectGate: retryGate
        )
        defer { cleanup(harness) }
        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.closed(code: 1006))
        await waitUntil({ harness.session.blocked != nil })

        // 第一次重试卡在新建连接上；第二次必须让它失效，而不是并行再开一条。
        retryGate.arm()
        let entriesBeforeRetry = retryGate.entryCount
        var firstDone = false
        var secondDone = false
        let first = Task { @MainActor in
            await harness.session.retry()
            firstDone = true
        }
        await waitUntil(
            { retryGate.entryCount > entriesBeforeRetry },
            message: "重试没有停在建连上"
        )
        let second = Task { @MainActor in
            await harness.session.retry()
            secondDone = true
        }
        // 有界等待：万一起销没被顶替，这里是**断言失败**，而不是整套挂死。
        await waitUntil({ secondDone }, message: "第二次重试没有收束")
        await waitUntil({ firstDone }, message: "第一次重试没有被顶替收束")
        if firstDone { await first.value }
        if secondDone { await second.value }

        var live = 0
        for client in harness.clients() {
            if await client.snapshot().close == 0 { live += 1 }
        }
        XCTAssertEqual(live, 1, "同一时刻只允许有一条连接活着：被顶替的那次必须关掉自己那一条")
        XCTAssertNotNil(harness.session.sessionID, "重试之后仍然是记录中")
    }

    /// 重连失败时中断必须仍然是打开的，可以再试；记录不变。
    func testFailedReconnectKeepsTheInterruptionOpen() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["回答"])])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.closed(code: 1006))
        await waitUntil({ harness.session.blocked != nil })
        XCTAssertEqual(harness.coordinator.phase, .interrupted)

        // 这一次重连会失败：麦克风起不来。
        harness.session.audioSourceFactory = {
            FakeAssistantAudio(startFailure: FakeAssistantError.connect, autoStartCapture: true)
        }
        await harness.session.retry()

        XCTAssertEqual(
            harness.coordinator.phase,
            .interrupted,
            "重连失败不许把中断闭合掉，也不许假装还在录"
        )
        XCTAssertEqual(harness.session.sessionID, sessionID, "重连失败不许换记录")
        XCTAssertNotNil(harness.session.blocked, "重连失败必须给可读结论")
    }

    // MARK: - D04：静音与语音中断共用 paused

    /// 静音只是"不上行"：会话、记录、设备、结束按钮都必须还在，
    /// 而且麦克风里进来的音频一个字节都不许上行。
    func testMutingKeepsTheConversationAndSendsNothingUpstream() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["回答"])])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)

        harness.session.toggleMute()

        XCTAssertTrue(harness.session.isMuted)
        XCTAssertEqual(harness.session.sessionID, sessionID, "静音不许换记录")
        XCTAssertEqual(harness.audio.stopCount, 0, "静音不许释放设备")
        XCTAssertTrue(harness.session.hasActiveConversation, "静音之后界面仍然是 active")
        XCTAssertTrue(harness.session.canEndConversation, "静音之后必须还能结束对话")
        XCTAssertEqual(harness.session.statusTitle, "麦克风已静音")

        harness.audio.emitCapture(AudioChunk(pcm: Data([1, 2, 3, 4]), level: 0.5))
        await waitUntil({ true }, iterations: 20, message: "")
        let counters = await harness.clients()[0].snapshot()
        XCTAssertEqual(counters.append, 0, "静音期间一个字节都不许上行")

        // 静音期间照样能打字问。
        await harness.session.ask(typed: "还在吗")
        await waitUntil({ harness.session.turns.count == 1 }, message: "静音不该挡住打字")
    }

    /// 静音之后断线，清理必须照做：以前 `phase.isLive` 为假就被整段跳过，
    /// 设备、连接与占用留在原地。
    func testDisconnectWhileMutedStillReleasesTheDevice() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["回答"])])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        harness.session.toggleMute()
        XCTAssertTrue(harness.session.isMuted)

        await harness.clients()[0].emit(.closed(code: 1006))
        await waitUntil({ harness.session.blocked != nil }, message: "静音状态下的断线没有被处理")

        XCTAssertEqual(harness.audio.stopCount, 1, "静音状态下的断线也必须释放设备")
        XCTAssertTrue(harness.session.hasActiveConversation, "断线之后这一场还在，只是语音掉了")
        XCTAssertTrue(harness.session.canRetryVoice, "断线之后必须能重试语音")
        XCTAssertEqual(harness.coordinator.phase, .interrupted)
    }

    /// 同一场重连保留静音；新一场恢复默认可上行。
    func testMuteSurvivesReconnectButResetsOnANewSession() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["回答"])])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        harness.session.toggleMute()
        await harness.clients()[0].emit(.closed(code: 1006))
        await waitUntil({ harness.session.blocked != nil })

        await harness.session.retry()
        XCTAssertTrue(harness.session.isMuted, "同一场重连必须保留静音")
        XCTAssertEqual(harness.session.sessionID, sessionID)

        await harness.coordinator.stopCapture(endingWith: .user)
        try await harness.coordinator.begin(.assistant)
        XCTAssertFalse(harness.session.isMuted, "新一场必须恢复默认可上行")
    }

    // MARK: - D06：LLM 异常没有回复级收尾

    /// provider 在首段之后失败：必须走**同一个回复收尾**——停本地播放、取消服务端
    /// 这一轮、把已经说出口的那半句按打断存下来。
    /// 以前的 catch 只改文案就返回，于是 TTS 接着往下播，半句话永远不落库。
    func testProviderFailureAfterFirstChunkFinalizesThePartialReply() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltasThenFailure(["今天", "很热"], "上游断了")]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "天气怎么样"))

        // 收尾完成的信号是助手那一行落库（`finalizeReply` 追加它），
        // 不是 `phase`——回复还没开始时 phase 本来就是 .listening。
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "provider 失败之后这一轮没有被收尾"
        )
        XCTAssertNotNil(harness.session.lastFailure, "失败必须给出可读原因")
        XCTAssertEqual(harness.session.phase, .listening, "失败之后要回到聆听态")

        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertEqual(assistantLines.count, 1, "失败的一轮也要留下那一行")
        let reply = try XCTUnwrap(assistantLines.first)
        XCTAssertEqual(reply.text, "今天很热", "已经说出口的部分要留下来")
        XCTAssertEqual(reply.status, .final, "收尾之后不该还挂着 partial")
        XCTAssertTrue(reply.isInterrupted, "没说完的一轮按打断封存")

        let turn = try XCTUnwrap(harness.session.turns.last)
        XCTAssertEqual(turn.role, .assistant)
        XCTAssertEqual(turn.id, reply.id, "Turn.id 必须就是库里那一行的 id")
        XCTAssertTrue(turn.isInterrupted)

        let counters = await harness.clients()[0].snapshot()
        XCTAssertGreaterThanOrEqual(
            counters.cancelTTS,
            1,
            "失败之后必须取消服务端这一轮，不能让它继续往下说"
        )
    }

    // MARK: - D08：打断没有稳定的行身份与持久终态

    /// 生成途中按 ESC：库里**只有一行**，正文是已经说出口的那部分，标记为打断。
    func testInterruptingDuringGenerationFinalizesExactlyOnce() async throws {
        let gate = Gate()
        let harness = try await makeHarness(llmScripts: [.gatedDeltas(["说到一半"], gate)])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "讲个故事"))
        await waitUntil(
            { harness.session.streamingReply == "说到一半" },
            message: "回复没有开始生成"
        )

        await harness.session.stopSpeaking()
        // 再按一次：收尾是幂等的，不该插出第二行。
        await harness.session.stopSpeaking()
        gate.release()

        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertEqual(assistantLines.count, 1, "一次回复只对应一行")
        let reply = try XCTUnwrap(assistantLines.first)
        XCTAssertEqual(reply.text, "说到一半")
        XCTAssertEqual(reply.status, .final)
        XCTAssertTrue(reply.isInterrupted)

        let assistantTurns = harness.session.turns.filter { $0.role == .assistant }
        XCTAssertEqual(assistantTurns.count, 1, "重复打断不能插出第二行")
        XCTAssertEqual(assistantTurns.first?.id, reply.id, "Turn.id 必须与库里那一行一致")
        XCTAssertEqual(assistantTurns.first?.isInterrupted, true)
    }

    /// 正文已经完整生成并定稿，只是朗读还没放完这时按停止：
    /// **同一行**保留完整正文，只补一个打断标记（不能再插一行"半句"）。
    func testStoppingDuringPlaybackKeepsTheFullTextOnTheSameLine() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["完整的一句话。"])])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "念一句"))

        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "回复没有落库"
        )
        let lineIDBefore = try XCTUnwrap(
            harness.session.turns.first { $0.role == .assistant }?.id
        )

        // 朗读进行中：服务端正放着一段音频。
        await harness.clients()[0].emit(
            .ttsAudio(requestID: "tts_req_playback", taskID: nil, pcm: Data(repeating: 0, count: 320))
        )
        await waitUntil({ harness.session.phase == .speaking }, message: "没有进入朗读态")

        await harness.session.stopSpeaking()

        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertEqual(assistantLines.count, 1, "不能因为停止朗读再插一行")
        let reply = try XCTUnwrap(assistantLines.first)
        XCTAssertEqual(reply.id, lineIDBefore, "必须是同一行")
        XCTAssertEqual(reply.text, "完整的一句话。", "已经生成完的正文不许被截短")
        XCTAssertTrue(reply.isInterrupted, "没听完要标出来")
    }

    /// 结束对话时正在生成：最后那半句也要按打断存下来，不能随连接一起消失。
    func testEndingDuringGenerationKeepsThePartialLine() async throws {
        let gate = Gate()
        let harness = try await makeHarness(llmScripts: [.gatedDeltas(["没说完"], gate)])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "说点什么"))
        await waitUntil({ harness.session.streamingReply == "没说完" }, message: "回复没有开始生成")

        await harness.session.stopCapture()
        gate.release()

        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertEqual(assistantLines.count, 1, "结束对话也要把这一轮收尾")
        let reply = try XCTUnwrap(assistantLines.first)
        XCTAssertEqual(reply.text, "没说完")
        XCTAssertEqual(reply.status, .final)
        XCTAssertTrue(reply.isInterrupted)
    }

    /// 语音连接在生成途中断掉：正在跑的那一轮要先收尾再释放资源（D06）。
    func testDisconnectDuringGenerationFinalizesThePartialReply() async throws {
        let gate = Gate()
        let harness = try await makeHarness(llmScripts: [.gatedDeltas(["断了之前"], gate)])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "喂"))
        await waitUntil({ harness.session.streamingReply == "断了之前" }, message: "回复没有开始生成")

        await harness.clients()[0].emit(.closed(code: 1006))
        // 先等断线真的被处理完，再放开 LLM：反过来的话回复会先按"正常完成"收尾，
        // 测到的就不是"断线打断了正在生成的那一轮"这件事了。
        await waitUntil({ harness.session.blocked != nil }, message: "断线没有被处理")
        gate.release()

        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertEqual(assistantLines.count, 1, "断线也要把这一轮收尾")
        let reply = try XCTUnwrap(assistantLines.first)
        XCTAssertEqual(reply.text, "断了之前")
        XCTAssertTrue(reply.isInterrupted)
    }

    // MARK: - S4 第 12 条：取消之后要有真正的远端空闲屏障

    /// 服务端确认了终态：这条连接仍然可用，打断后回到聆听态。
    func testConfirmedRemoteIdleKeepsTheConnectionUsable() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["一句话。"])])
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

        XCTAssertEqual(harness.session.phase, .listening, "服务端确认后应当继续聆听")
        XCTAssertNil(harness.session.blocked, "确认过就不该判成语音中断")
        let counters = await harness.clients()[0].snapshot()
        XCTAssertEqual(counters.close, 0, "确认过就不该关连接")
    }

    /// 服务端**没有**确认终态：不能把这条连接当成空出来了继续用。
    /// 必须断开、记一次可重试的语音中断，而不是靠等待或自动重发把竞态盖过去。
    func testUnconfirmedRemoteIdleClosesTheConnectionAndBlocksTheVoice() async throws {
        let harness = try await makeHarness(
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

        // 服务端从此不再回终态：屏障有界超时之后必须落到语音中断。
        await harness.session.stopSpeaking()
        await waitUntil(
            { harness.session.blocked != nil },
            message: "服务端没有确认终止时，必须进入可重试的语音中断"
        )

        XCTAssertEqual(harness.session.phase, .paused)
        XCTAssertFalse(harness.session.isActivelyRunning, "中断态不算正在跑")
        let counters = await harness.clients()[0].snapshot()
        XCTAssertGreaterThanOrEqual(counters.close, 1, "归属未知的连接必须关掉，不能留着开下一轮")
    }

    // MARK: - D05：设备重建通知与恢复

    /// 切换设备丢掉了这一轮还没播完的缓冲：**不是**"播完了"。
    /// 旧 epoch 的 rendered 回调被代次过滤掉了，所以账本必须靠这条通知归零，
    /// 回复要按打断收尾，而且要明确告诉用户这次朗读停了。
    func testDeviceRebuildStopsTheUtteranceAndMarksItInterrupted() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["还没播完的一句话。"])])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
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

        await harness.audio.emitPlaybackInvalidated(recovered: true)

        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let assistantLines = lines.filter { $0.role == .assistant }
        XCTAssertEqual(assistantLines.count, 1, "设备切换不能插出第二行")
        let reply = try XCTUnwrap(assistantLines.first)
        XCTAssertEqual(reply.text, "还没播完的一句话。", "已经生成完的正文不许被截短")
        XCTAssertTrue(reply.isInterrupted, "被设备切换丢掉的那一轮按打断封存")
        XCTAssertEqual(harness.session.phase, .listening, "重建成功之后还能继续说")
        let failure = try XCTUnwrap(harness.session.lastFailure)
        XCTAssertTrue(failure.contains("设备"), "要明确告诉用户朗读停了，而不是假装播完了")
    }

    /// 重建失败：这一场语音已经没法继续，要落到可重试的语音中断，
    /// 但记录、sessionID 与「重试语音」都留着——不能只改一句错误文案。
    func testDeviceRebuildFailureEntersRetriableInterruption() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["一句话。"])])
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "念一句"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "回复没有落库"
        )

        await harness.audio.emitPlaybackInvalidated(recovered: false, message: "输出设备不可用")

        await waitUntil({ harness.session.blocked != nil }, message: "重建失败没有落到可重试的中断")
        XCTAssertEqual(harness.session.phase, .paused)
        XCTAssertEqual(harness.session.sessionID, sessionID, "记录要留着，重试语音还在同一场里")
        XCTAssertTrue(harness.session.canRetryVoice, "重建失败之后必须还能重试语音")
        let counters = await harness.clients()[0].snapshot()
        XCTAssertGreaterThanOrEqual(counters.close, 1, "语音已经不可用，连接必须收掉")
    }

    // MARK: - D07：真正可用的文字降级

    /// 没开麦克风、也没建语音连接时，打字依然要能问出答案并落库。
    /// 以前 `ask(typed:)` 要求先有语音会话的 sessionID，于是这条路上什么都不发生。
    func testTypingWorksWithoutStartingTheMicrophone() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["文字回答。"])])
        defer { cleanup(harness) }

        let result = await harness.session.ask(typed: "不靠麦克风也能问")
        XCTAssertEqual(result, .accepted)

        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "文字回复没有落库"
        )
        XCTAssertEqual(harness.audio.startCount, 0, "纯文字对话不该去拿麦克风")
        XCTAssertEqual(harness.clients().count, 0, "纯文字对话不该建语音连接")

        let sessionID = try XCTUnwrap(harness.session.sessionID)
        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        XCTAssertEqual(lines.filter { $0.role == .user }.count, 1, "问题恰好落一行")
        XCTAssertEqual(lines.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(harness.session.statusTitle, "文字对话", "界面不能说成'正在聆听'")
    }

    /// 纯文字对话**不占用设备**：不能抢走 `SessionCoordinator` 的 activeSessionID，
    /// 也不能覆盖别的功能正在用的占用（§4.2）。
    func testTextConversationDoesNotTakeDeviceOccupancy() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["回答。"])])
        defer { cleanup(harness) }

        let result = await harness.session.ask(typed: "只打字")
        XCTAssertEqual(result, .accepted)
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "文字回复没有落库"
        )

        XCTAssertNil(harness.coordinator.activeSessionID, "纯文字不该改写全局的 activeSessionID")
        XCTAssertNil(harness.coordinator.occupancy, "纯文字不该占用设备")
    }

    /// 文字模式的回复不自动朗读：没有语音通道就不该偷偷去开 TTS。
    func testTextReplyIsNotSpoken() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["只读给你看的回答。"])])
        defer { cleanup(harness) }

        _ = await harness.session.ask(typed: "别念")
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "文字回复没有落库"
        )

        XCTAssertFalse(harness.session.canReplaySpeech, "没有语音通道时不能提供重播")
        XCTAssertEqual(harness.clients().count, 0, "文字回复不该建连接去朗读")
    }

    /// 结束纯文字对话要按它自己的 sessionID 封存记录，
    /// 而且结束时要把结果告诉界面（语音与文字共用同一个结果，§4.2）。
    func testEndingTextConversationSealsItsOwnRecord() async throws {
        let harness = try await makeHarness(llmScripts: [.deltas(["回答。"])])
        defer { cleanup(harness) }

        _ = await harness.session.ask(typed: "记下来")
        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "文字回复没有落库"
        )
        let sessionID = try XCTUnwrap(harness.session.sessionID)

        await harness.session.stopCapture()

        let record = try await harness.store.session(id: sessionID)
        XCTAssertEqual(record?.state, .archived, "结束的纯文字记录要有终态")
        XCTAssertEqual(harness.session.lastFinalizedSessionID, sessionID)
        XCTAssertNil(harness.session.sessionID, "结束之后这一场就交出去了")
    }

    // MARK: - D09：时间游标未推进

    /// 每一条 item 保留**自己**的第一个证据时刻；没有 sample span 就把精确时轴
    /// 存成 NULL 并标 `unavailable`，不再拿会话起点冒充（D09）。
    func testEachUtteranceKeepsItsOwnObservedTimeAndNoFakeTimeAxis() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltas(["回答一"]), .deltas(["回答二"])]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)

        // 第一句：先有一段非空 partial，再来 final——观测时刻应取**partial** 那次。
        await harness.clients()[0].emit(.partial(itemID: "i1", delta: "你好"))
        try? await Task.sleep(for: .milliseconds(30))
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "你好啊"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .user } },
            message: "第一句没有落库"
        )

        // 第二句：final-only，没有 partial——用 final 自己那次接收时刻。
        try? await Task.sleep(for: .milliseconds(30))
        await harness.clients()[0].emit(.completed(itemID: "i2", transcript: "第二个问题"))
        await waitUntil(
            { harness.session.turns.filter { $0.role == .user }.count == 2 },
            message: "第二句没有落库"
        )

        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let userLines = lines.filter { $0.role == .user }
        XCTAssertEqual(userLines.count, 2)
        let first = try XCTUnwrap(userLines.first)
        let second = try XCTUnwrap(userLines.last)

        XCTAssertNotEqual(
            first.createdAt,
            second.createdAt,
            "两条 item 必须各有自己的观测时刻，而不是都回退到会话起点"
        )
        XCTAssertLessThan(first.createdAt, second.createdAt, "观测顺序要跟着证据顺序走")

        for line in userLines {
            XCTAssertNil(line.tStart, "没有 sample span 就不能编一个声学起点")
            XCTAssertNil(line.tEnd)
            XCTAssertEqual(line.timingQuality, .unavailable, "精确时轴缺失必须可识别")
        }

        // 实时对话流与回看显示同一个时间。
        let liveFirst = try XCTUnwrap(harness.session.turns.first { $0.role == .user })
        XCTAssertEqual(
            liveFirst.createdAt.timeIntervalSince1970,
            first.createdAt.timeIntervalSince1970,
            accuracy: 0.0005,
            "实时那一行与库里那一行必须是同一个时刻（live=\(liveFirst.createdAt.timeIntervalSince1970) store=\(first.createdAt.timeIntervalSince1970)）"
        )
    }

    /// 重连换连接锚点之后，旧 item 的观测时刻不能被沿用（D09 第 3 条）。
    func testReconnectClearsItemObservationTimes() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltas(["回答一"]), .deltas(["回答二"])]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "第一个问题"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .user } },
            message: "第一句没有落库"
        )

        await harness.clients()[0].emit(.closed(code: 1006))
        await waitUntil({ harness.session.blocked != nil }, message: "断线没有被处理")
        await harness.session.retry()

        // 同一个 itemID 在新连接上是**新的一句**：观测时刻要重新取。
        try? await Task.sleep(for: .milliseconds(30))
        let reconnected = try XCTUnwrap(harness.clients().last)
        await waitUntil({ harness.clients().count == 2 }, message: "重连没有建出新连接")
        await reconnected.emit(.completed(itemID: "i1", transcript: "又问了同一个 item"))
        await waitUntil(
            { harness.session.turns.filter { $0.role == .user }.count == 2 },
            message: "重连之后那一句没有落库"
        )
        XCTAssertEqual(
            harness.session.turns.filter { $0.role == .user }.count,
            2,
            "重连不该把同一句合并掉"
        )
    }

    // MARK: - 空 final 不得吞掉已经识别出来的那一句

    /// 用户说过话、界面已经显示识别文字，服务端却给回一个空 final 时，
    /// 那一句话**不许无声消失**：它要留在对话流与库里，并明确告诉用户没定稿。
    ///
    /// 修复前：先清 `partialText` 再 `guard !text.isEmpty` 返回——文字被清掉，
    /// 不落库、不进 LLM/TTS、不报错，界面表现就是"说话→字没了→什么都不发生"。
    func testEmptyFinalKeepsTheRecognizedUtteranceInsteadOfSwallowingIt() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltas(["这一句不该被问到模型"])]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)

        await harness.clients()[0].emit(
            .partialSnapshot(itemID: "i1", revision: 1, text: "今天天气")
        )
        try? await Task.sleep(for: .milliseconds(30))
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: ""))

        await waitUntil(
            { harness.session.lastFailure != nil },
            message: "空 final 之后没有给出任何可读结论"
        )

        // 界面上那一半不再显示（没有权威文本就不该继续显示半句），但话本身没丢。
        XCTAssertNil(harness.session.partialText)
        let turn = try XCTUnwrap(harness.session.turns.last, "用户说过的话被静默丢掉了")
        XCTAssertEqual(turn.role, .user)
        XCTAssertEqual(turn.text, "今天天气")
        XCTAssertTrue(turn.isInterrupted, "没能定稿的这一句要标成未完成")
        XCTAssertEqual(turn.source, .microphone)
        XCTAssertNotNil(turn.createdAt, "观测时刻不能因为没定稿就丢掉")

        // 库里有这一行，但**不是** final：记录库句数与导出仍只认已定稿行。
        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        let stored = lines.filter { $0.role == .user }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.text, "今天天气")
        XCTAssertEqual(stored.first?.status, .partial)
        XCTAssertEqual(
            turn.ordinal,
            1,
            "ordinal 必须取 appendLine 的返回值，不能自行 +1"
        )

        // 没有权威文本就不进 LLM/TTS：hypothesis 是可改写全文，不是事实。
        XCTAssertFalse(
            harness.session.turns.contains { $0.role == .assistant },
            "空 final 之后不该拿未定稿文字去问模型"
        )
    }

    /// 没说话时的空 final 是正常路径（`clear` 之后 commit、纯静音），
    /// 不该凭空造出一句"没能识别完整"。
    func testEmptyFinalWithoutAnyRecognizedTextIsSkippedSilently() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltas(["不该被问到模型"])]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: ""))

        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(harness.session.turns.isEmpty, "没说话不该产生任何一轮对话")
        XCTAssertNil(
            harness.session.lastFailure,
            "没说话的空 final 是正常路径，不该报失败"
        )
        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        XCTAssertTrue(lines.isEmpty, "没说话不该落库")
    }

    /// 跨 item：一个还在进行的 item 的可见文字，不能被另一个 item 的事件清掉。
    ///
    /// 服务端一条连接上可以有多个并发 item（rollover commit），客户端
    /// `RealtimeEventState` 也按最多 128 个 item 追踪；`partialText` 曾经是
    /// 一个不带身份的单槽位，于是迟到事件会把当前句抹掉。
    func testLateEventFromAnotherItemDoesNotClearTheCurrentPartial() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltas(["回答一"]), .deltas(["回答二"])]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)

        await harness.clients()[0].emit(
            .partialSnapshot(itemID: "i1", revision: 1, text: "今天天气")
        )
        try? await Task.sleep(for: .milliseconds(20))
        await harness.clients()[0].emit(
            .partialSnapshot(itemID: "i2", revision: 1, text: "")
        )
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(
            harness.session.partialText,
            "今天天气",
            "另一个 item 的空快照不该清掉当前这句"
        )

        // 反向：另一个 item 的非空快照同样不该顶掉当前句。
        await harness.clients()[0].emit(
            .partialSnapshot(itemID: "i2", revision: 2, text: "别的内容")
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(
            harness.session.partialText,
            "今天天气",
            "另一个 item 的正文不该顶掉当前这句"
        )

        // 当前 item 自己的事件照旧生效。
        await harness.clients()[0].emit(
            .partialSnapshot(itemID: "i1", revision: 2, text: "今天天气不错")
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(harness.session.partialText, "今天天气不错")

        // 它的终态照旧定稿。
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: "今天天气不错"))
        await waitUntil(
            { harness.session.turns.contains { $0.role == .user } },
            message: "当前 item 的终态没有落库"
        )
        XCTAssertNil(harness.session.partialText)
    }

    /// 空 itemID 的失败事件拿不到身份：它只报告失败，不得留下半残的可见文字。
    func testFailedWithoutItemIDReportsTheFailureWithoutTouchingThePartial() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltas(["回答一"])]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)

        await harness.clients()[0].emit(
            .partialSnapshot(itemID: "i1", revision: 1, text: "今天天气")
        )
        try? await Task.sleep(for: .milliseconds(20))
        await harness.clients()[0].emit(
            .failed(itemID: "", code: "invalid_hypothesis", message: "流式转写快照格式无效")
        )
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertNotNil(harness.session.lastFailure, "失败必须可见")
        XCTAssertEqual(
            harness.session.partialText,
            "今天天气",
            "空 itemID 的失败认不出身份，不该动当前可见文字"
        )

        // 认得出身份的失败才清自己那一句。
        await harness.clients()[0].emit(
            .failed(itemID: "i1", code: "backend_error", message: "流式转写失败")
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(harness.session.partialText, "同一 item 的失败要清掉它自己的半句")
        XCTAssertNotNil(harness.session.lastFailure)
    }

    /// 没定稿的那半句**不许**去问模型。
    ///
    /// `speechrail.transcription.hypothesis` 是可改写的全文，不是权威文本。
    /// 拿它驱动模型与朗读等于把未确认内容当事实，而且用户无法分辨哪句是真的。
    /// 所以"保留并提示"是对的，"回退用 partial 送 LLM"是错的——这一条钉住取舍。
    func testUnfinalizedUtteranceNeverReachesTheModel() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltas(["这一句不该被问到模型"])]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(
            .partialSnapshot(itemID: "i1", revision: 1, text: "今天天气")
        )
        try? await Task.sleep(for: .milliseconds(30))
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: ""))

        await waitUntil(
            { harness.session.lastFailure != nil },
            message: "空 final 之后没有给出任何可读结论"
        )
        let streams = await harness.llm.streamCount
        XCTAssertEqual(streams, 0, "未定稿的文字不许驱动模型与朗读")
    }

    /// 同一个 item 的终态重放（重连、重复 commit）不该在库里留下两行。
    func testRepeatedEmptyFinalForTheSameItemDoesNotDuplicateThePreservedLine() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltas(["不该被问到模型"])]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(
            .partialSnapshot(itemID: "i1", revision: 1, text: "今天天气")
        )
        try? await Task.sleep(for: .milliseconds(30))
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: ""))

        await waitUntil(
            { harness.session.lastFailure != nil },
            message: "第一次空 final 没有保留那句话"
        )
        // 同一个 item 的终态再来一次（重连或重复 commit）。
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: ""))
        try? await Task.sleep(for: .milliseconds(50))

        let lines = try await harness.store.lines(sessionID: sessionID, includePartial: true)
        XCTAssertEqual(
            lines.filter { $0.role == .user }.count,
            1,
            "同一个 item 不该被保留两次"
        )
        XCTAssertEqual(
            harness.session.turns.filter { $0.role == .user }.count,
            1,
            "对话流里也不该出现两行同一句"
        )
    }

    /// 成功定稿一句之后，上一次留下的"没能识别完整"提示必须自己退场——
    /// 否则用户已经说清楚了，界面上还挂着一句过期警告。
    func testASuccessfulTurnClearsTheStaleFailureNotice() async throws {
        let harness = try await makeHarness(
            llmScripts: [.deltas(["今天晴，最高 28 度。"])]
        )
        defer { cleanup(harness) }

        try await harness.coordinator.begin(.assistant)
        await harness.clients()[0].emit(.configured)
        await harness.clients()[0].emit(
            .partialSnapshot(itemID: "i1", revision: 1, text: "今天天气")
        )
        try? await Task.sleep(for: .milliseconds(30))
        await harness.clients()[0].emit(.completed(itemID: "i1", transcript: ""))

        await waitUntil(
            { harness.session.lastFailure != nil },
            message: "空 final 之后没有给出任何可读结论"
        )

        await harness.clients()[0].emit(
            .partialSnapshot(itemID: "i2", revision: 1, text: "那明天呢")
        )
        try? await Task.sleep(for: .milliseconds(30))
        await harness.clients()[0].emit(.completed(itemID: "i2", transcript: "那明天呢"))

        await waitUntil(
            { harness.session.turns.contains { $0.role == .assistant } },
            message: "这一次定稿没有走到模型回复"
        )
        XCTAssertNil(
            harness.session.lastFailure,
            "这一句已经成功定稿，上一次的软提示就该退场"
        )
    }
}
