import Foundation
import SpeechRailControlKit

enum RealtimeASRSocketFrame: Sendable {
    case text(String)
    case data(Data)
    case unsupported
}

protocol RealtimeASRTransport: Sendable {
    func resume() async
    func send(_ text: String) async throws
    func receive() async throws -> RealtimeASRSocketFrame
    func closeCode() async -> Int?
    func cancel() async
}

private actor URLSessionRealtimeASRTransport: RealtimeASRTransport {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() async {
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> RealtimeASRSocketFrame {
        switch try await task.receive() {
        case .string(let text): .text(text)
        case .data(let data): .data(data)
        @unknown default: .unsupported
        }
    }

    func closeCode() async -> Int? {
        task.closeCode == .invalid ? nil : task.closeCode.rawValue
    }

    func cancel() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// `/v1/realtime` 的客户端（契约：`contracts/realtime-openai.md`）。
//
// 它只做四件事：**连、配、喂 PCM、收事件**。没有大模型、没有播放、没有业务状态——
// 那些属于助手 / 会议 / 字幕各自的会话层（`TECHNICAL-DESIGN` §5.3）。
//
// 三条从契约直接落下来的硬约束，写在这里免得以后被"顺手优化"掉：
//
//   1. **线上格式固定 24 kHz / 单声道 / PCM16**，而且**首个 PCM 之后不得改格式**。
//      换设备只能重建采集、不重开会话（`TECHNICAL-DESIGN` §5.2 第 5 条）。
//   2. **partial 只进内存**：官方 `delta` 是可追加的稳定前缀，
//      `speechrail.transcription.hypothesis` 是**可改写全文**（必须整段替换）——
//      所以定稿只认 `completed` 的全量 `transcript`。
//   3. **`backend_busy` 是准入结果，不是异常**：它连的是会话占用守卫，不是错误弹窗
//      （`IMPLEMENTATION-READINESS` §3 的同一条结论）。

/// Realtime ASR 的客户端。一个实例对应一条 WebSocket、一次会话。
public actor RealtimeASRClient {
    /// 契约里的 canonical ASR profile。用别名（`gpt-4o-transcribe`）也能连上，
    /// 但那是给标准 OpenAI 客户端准备的；App 是我们自己的客户端，报 canonical 名。
    public static let canonicalASRModel = "speechrail/qwen3-asr-1.7b"

    /// 流式转写的线上格式。当前 SpeechRail transcription session 固定使用
    /// 24 kHz / 单声道 / PCM16；原生层归一到这个格式，服务端再重采样到 16 kHz 内核。
    public static let sampleRate: Double = 24_000

    public enum Failure: LocalizedError, Equatable, Sendable {
        case unsupportedModel(String)
        case transport(String)
        case closed(Int?)
        case drainTimedOut(RealtimeDrainStage)

        public var errorDescription: String? {
            switch self {
            case .unsupportedModel(let model):
                "这个档位不支持流式模型 \(model)。"
            case .transport(let message):
                "连不上语音服务：\(message)"
            case .closed(let code):
                code.map { "语音服务断开了连接（\($0)）。" } ?? "语音服务断开了连接。"
            case .drainTimedOut(let stage):
                switch stage {
                case .commit:
                    "语音服务没有在关闭期限内确认提交。"
                case .terminalItems:
                    "最后一段语音没有在关闭期限内完成转写。"
                case .diarization:
                    "说话人归属没有在关闭期限内完成收口。"
                case .clear:
                    "语音服务没有在关闭期限内确认清空缓冲区。"
                case .close:
                    "语音服务没有在关闭期限内完成关闭。"
                }
            }
        }
    }

    /// 一个**归属单元**：对齐器给的可冻结文本片段，加上分人给出的匿名标签。
    ///
    /// 当前 wire 把两件事分开：`speechrail.alignment.done` 给 `segment_uid` 与
    /// 文本/采样区间，`speechrail.diarization.*` 只给「采样区间 → 匿名说话人」。
    /// 客户端按采样区间重叠把两者合起来，`segmentUID` 仍是正文不可变、归属原位
    /// 修订的稳定坐标（`SpeakerLabeling`）。
    public struct AttributionUnit: Sendable, Equatable {
        public var segmentUID: String
        public var speaker: String?
        public var textStart: Int?
        public var textEnd: Int?
        public var audioStartSample: Int?
        public var audioEndSample: Int?
        public var timingQuality: String?
        public var granularity: String?

        public init(
            segmentUID: String,
            speaker: String? = nil,
            textStart: Int? = nil,
            textEnd: Int? = nil,
            audioStartSample: Int? = nil,
            audioEndSample: Int? = nil,
            timingQuality: String? = nil,
            granularity: String? = nil
        ) {
            self.segmentUID = segmentUID
            self.speaker = speaker
            self.textStart = textStart
            self.textEnd = textEnd
            self.audioStartSample = audioStartSample
            self.audioEndSample = audioEndSample
            self.timingQuality = timingQuality
            self.granularity = granularity
        }
    }

    /// `speechrail.diarization.*` 的一条分人区间：采样区间 → 匿名说话人。
    ///
    /// 说话人为 `nil` 表示这一段没有可用的归属（服务端明确给了 unknown）。
    public struct DiarizationSpan: Sendable, Equatable {
        public var speaker: String?
        public var startSample: Int
        public var endSample: Int

        public init(speaker: String?, startSample: Int, endSample: Int) {
            self.speaker = speaker
            self.startSample = startSample
            self.endSample = endSample
        }
    }

    /// 服务端事件里**会话层真正需要的那一部分**。
    public enum Event: Sendable {
        /// `session.created`：握手完成，服务端声明了实际能力。
        case ready(model: String)
        /// `session.updated`：配置生效，可以开始喂 PCM。
        case configured
        /// 官方 append-only partial（内存态）。它是增量，调用点自己累加。
        case partial(itemID: String, delta: String)
        /// 可修订 partial 的最新全文（`speechrail.transcription.hypothesis`）。
        /// 调用点必须替换 item 文本，不得追加。
        case partialSnapshot(itemID: String, revision: Int, text: String)
        /// 文本终态。当前 wire 的 final 只承载正文；对齐与匿名声归属**随后独立到达**，
        /// 不得等待它们、也不得用它们改写正文。
        case completed(itemID: String, transcript: String)
        case failed(itemID: String, code: String, message: String)
        /// 归属（对齐 + 分人）修订，**只改归属列**。
        ///
        /// `isFinal` 为 true 表示这是分人收口后的最后一份（`speechrail.diarization.done`）。
        case attribution(itemID: String, units: [AttributionUnit], isFinal: Bool)
        /// `speechrail.alignment.failed`：对齐拿不到证据。正文仍成功，只是没有时间码。
        case alignmentFailed(itemID: String, code: String, message: String)
        /// `speechrail.diarization.failed`：一次 active→degraded。正文继续，标签停更。
        case diarizationDegraded(code: String, message: String)
        /// TTS 音频块（24 kHz PCM16）。助手那一侧才用得上。
        case ttsAudio(requestID: String, taskID: String?, pcm: Data)
        /// 增量 utterance 已取得准入（`speechrail.tts.started`）。
        /// **收到它之前不得 append，服务端在此之前也不会发 PCM。**
        case ttsStarted(requestID: String, taskID: String?, limits: TTSStreamLimits?)
        /// 一次 append 的 ACK（`speechrail.tts.text_accepted`）。
        /// ACK 失败不推进 `appendSequence`——调用方只认这些回执推进序号。
        case ttsTextAccepted(
            requestID: String,
            taskID: String?,
            appendSequence: Int,
            totalCodepoints: Int
        )
        /// TTS 一轮结束：`speechrail.tts.completed` / `.cancelled` / `.failed`。
        /// 每次 utterance **恰好一个** terminal；失败带稳定错误码与消息。
        case ttsEnded(
            requestID: String,
            taskID: String?,
            status: String,
            code: String?,
            message: String?
        )
        /// 顶层 `error`。请求级错误带 `request_id`；会话级错误没有。
        case serverError(code: String, message: String, requestID: String?)
        case closed(code: Int?)
    }

    private let url: URL
    private let apiKey: String?
    private let model: String
    /// 静音窗口。**字幕 400 ms / 会议 900 ms**（`SCOPE-DECISIONS` 的口径，也是
    /// 服务端既有策略）：字幕要快，会议要整句。
    private let silenceDurationMilliseconds: Int
    private let threshold: Double
    /// 分人开关（每场一次，**首个 PCM 之前**协商，之后改不了）。
    private let diarizationEnabled: Bool
    /// `session.speechrail.task`（会话层语义标签）。
    private let sessionTask: SpeechRailSessionUpdate.Task
    private let expectedModelRevision: String?
    /// 当前 caller-owned TTS voice 的 revision。随 voice 一起在连接内更新。
    private var expectedVoiceRevision: String?
    private let callerTTSEnabled: Bool
    /// `speechrail.tts.start` 的 task：助手会话固定 `conversation`。
    private let ttsTask: SpeechRailSessionUpdate.Task
    private let session: URLSession

    private var transport: (any RealtimeASRTransport)?
    private var receiveLoop: Task<Void, Never>?
    private var didClose = false
    private var configurationAcknowledged = false
    private var configurationFailure: Failure?
    private var continuation: AsyncStream<RealtimeEventEnvelope<Event>>.Continuation?
    private var stream: AsyncStream<RealtimeEventEnvelope<Event>>?
    /// 下一次 caller-owned TTS request 使用的音色。
    private var voice: String?
    private var activeTTSRequestID: String?
    private var activeTTSTaskID: String?
    private var activeTTSAudioSuppressed = false
    /// 当前 request 是否已经进入增量模式（收到过 `speechrail.tts.started`）。
    private var activeTTSStreaming = false
    /// 最后一个被 ACK 的 append 序号；从 -1 起，与契约的"空输入为 -1"一致。
    private var activeTTSConsumedSequence = -1
    private var expectedAudioChunkIndex = 0
    private var expectedAudioSampleOffset = 0
    /// 因请求不匹配/序号不连续/奇数字节而被丢掉的音频块计数（诊断用）。
    public private(set) var droppedAudioChunks = 0
    /// `finish` 的 event_id。契约要求同一个 id 重试幂等、不同 id 拒绝。
    private var finishEventID: String?
    private var finishSent = false
    private var clearSent = false
    /// 自最后一次文本终态以来上行过的 PCM 字节：决定关闭时是否真的还有一个
    /// 待终结的输入 item（当前 wire 没有 `input_audio_buffer.committed` 回执）。
    private var appendedBytesSinceTerminal = 0
    private var closeBarrier = RealtimeCloseBarrier()
    private var diarizationAcknowledged = false
    /// 当前 item 的对齐单元（`speechrail.alignment.done`），按 `item_id` 暂存，
    /// 与分人采样区间合并后交给会话层。全部只存内存，且按 item 有界。
    private var alignmentUnitsByItem: [String: [AttributionUnit]] = [:]
    private var alignmentOrder: [String] = []
    /// 当前 item 的分人区间（`speechrail.diarization.*`）。
    private var diarizationSpansByItem: [String: [DiarizationSpan]] = [:]
    private var sequenceValidator = RealtimeSequenceValidator()
    /// Latest sequence diagnostic. The event envelope remains the source of
    /// truth; this property is only a non-sensitive convenience for session UI.
    public private(set) var sequenceStatus: RealtimeSequenceStatus = .missing
    /// Opaque server session identity and a bounded in-memory event ID window.
    /// Neither is persisted or logged.
    public private(set) var serverSessionID: String?
    public private(set) var recentEventIDs: [String] = []
    private var currentEventMetadata: RealtimeEventMetadata?
    private var currentEventReceivedAt: ContinuousClock.Instant?
    private var closeCode: Int?

    public init(
        port: Int = 8201,
        model: String = RealtimeASRClient.canonicalASRModel,
        silenceDurationMilliseconds: Int = 400,
        threshold: Double = 0.5,
        diarizationEnabled: Bool = false,
        sessionTask: SpeechRailSessionUpdate.Task = .conversation,
        voice: String? = nil,
        apiKey: String? = nil,
        session: URLSession = .shared,
        expectedModelRevision: String? = nil,
        expectedVoiceRevision: String? = nil,
        callerTTSEnabled: Bool = false,
        ttsTask: SpeechRailSessionUpdate.Task = .conversation
    ) {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        self.url = components.url!
        // 与 REST 走**同一处**凭据解析：服务配了 key 时，握手缺 `Authorization` 会被
        // 以 1008 关掉（契约「连接与认证」）。这里不自己读环境变量。
        self.apiKey = apiKey ?? SpeechRailAPICredentialProvider.resolve()
        self.model = model
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.threshold = threshold
        self.diarizationEnabled = diarizationEnabled
        self.sessionTask = sessionTask
        self.expectedModelRevision = expectedModelRevision
        self.expectedVoiceRevision = expectedVoiceRevision
        self.callerTTSEnabled = callerTTSEnabled
        self.ttsTask = ttsTask
        self.voice = voice
        self.session = session
    }

    /// 事件流。**只能取一次**：这条流与这条连接一一对应，多个消费者会让"谁负责写库"变得不确定。
    public func events() -> AsyncStream<RealtimeEventEnvelope<Event>> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream<RealtimeEventEnvelope<Event>>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.stream = stream
        self.continuation = continuation
        return stream
    }

    // MARK: - 连接

    /// 建连、声明转写会话、发送 current-only 配置。返回即表示可以开始喂 PCM。
    public func connect() async throws {
        guard transport == nil else { return }
        guard !didClose else { throw Failure.closed(closeCode) }
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        try await connect(using: URLSessionRealtimeASRTransport(task: task))
    }

    func connect(using transport: any RealtimeASRTransport) async throws {
        guard self.transport == nil else { return }
        guard !didClose else { throw Failure.closed(closeCode) }
        configurationAcknowledged = false
        configurationFailure = nil
        self.transport = transport
        await transport.resume()
        startReceiveLoop(using: transport)

        // `session.update` 要在首个 PCM **之前**落地：24 kHz 格式、任务、
        // 分人与 caller-owned TTS 都在这一刻协商。
        do {
            try await send(configurationEvent())
            try await waitForConfigurationAcknowledgement()
        } catch {
            await finish(code: nil)
            throw error
        }
    }

    /// 关掉连接。调用点负责把它带来的中断写进账本（`service_lost`）。
    public func close() async {
        await finish(code: nil)
    }

    // MARK: - 上行

    /// 追加一段 24 kHz / 单声道 / PCM16。
    public func append(_ pcm: Data) async throws {
        guard !pcm.isEmpty else { return }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "event_id": UUID().uuidString,
            "audio": pcm.base64EncodedString()
        ]
        appendedBytesSinceTerminal += pcm.count
        try await send(payload)
    }

    /// 手动触发终态。`endpointing` 打开时服务端自己会在静音处提交，这一条是给
    /// "用户按了结束"用的：它保证最后半句也走完一次提交，而不是留在缓冲区里丢掉。
    public func commit() async throws {
        try await send(["type": "input_audio_buffer.commit", "event_id": UUID().uuidString])
    }

    /// Discards the uncommitted input buffer. Repeating the operation on one
    /// connection is intentionally idempotent, but a new connection gets a
    /// fresh clear barrier.
    public func clear() async throws {
        guard !clearSent else { return }
        try await send(["type": "input_audio_buffer.clear", "event_id": UUID().uuidString])
        clearSent = true
    }

    /// Closes one logical recording without treating a socket close as an ASR
    /// receipt.
    ///
    /// The single current wire has no `input_audio_buffer.committed` or
    /// `cleared` acknowledgement: an item becomes observable only through its
    /// transcription terminal, and `clear` is a local discard. When PCM has
    /// been uploaded since the last terminal the caller declares one input item
    /// and waits for **its** terminal (whichever commit owner produced it);
    /// otherwise the server has already finalized the last turn.
    public func drainAndClear(timeout: Duration = .seconds(8)) async throws {
        let hasOutstandingInput = appendedBytesSinceTerminal > 0
        if hasOutstandingInput {
            closeBarrier.expectItem()
        }
        try await withStageTimeout(stage: .commit, timeout: timeout) {
            try await self.commit()
        }
        if hasOutstandingInput {
            try await waitForDeclaredItems(timeout: timeout)
        }
        if diarizationEnabled {
            try await withStageTimeout(stage: .diarization, timeout: timeout) {
                try await self.finishDiarization()
            }
            try await waitForDiarizationAcknowledgement(timeout: timeout)
        }
        try await withStageTimeout(stage: .clear, timeout: timeout) {
            try await self.clear()
        }
    }

    /// 换音色。**下一次 TTS request 生效**，只影响 TTS，不进 prompt。
    /// voice 没有可验证 revision 时必须传 nil，以免沿用旧音色的 pin。
    public func updateVoice(_ voice: String, expectedVoiceRevision: String? = nil) async throws {
        self.voice = voice
        self.expectedVoiceRevision = expectedVoiceRevision
    }

    /// 开始一次增量 utterance（契约 §3.3.1）。
    ///
    /// 返回只表示 `speechrail.tts.start` 已发出；必须等到 `.ttsStarted` 才能 append。
    /// 文本、序列号、ACK 等待和打断都归调用方（`AssistantTTSStreamCoordinator`）。
    public func startTTSStream(requestID: String, speed: Double? = nil) async throws {
        activeTTSRequestID = requestID
        activeTTSTaskID = nil
        activeTTSAudioSuppressed = false
        activeTTSStreaming = false
        activeTTSConsumedSequence = -1
        expectedAudioChunkIndex = 0
        expectedAudioSampleOffset = 0
        guard let voice, !voice.isEmpty else {
            clearActiveTTS()
            throw Failure.transport("没有可用的朗读音色")
        }
        do {
            try await send(
                SpeechRailTTSStart(
                    requestID: requestID,
                    task: ttsTask,
                    voice: voice,
                    speed: speed,
                    voiceRevision: expectedVoiceRevision,
                    expectedModelRevision: expectedModelRevision
                ).jsonObject
            )
        } catch {
            if activeTTSRequestID == requestID { clearActiveTTS() }
            throw error
        }
    }

    /// 往当前 utterance 追加一段已经稳定的文本。
    public func appendTTSText(_ text: String, sequence: Int) async throws {
        guard let requestID = activeTTSRequestID else {
            throw Failure.transport("没有活动的 TTS utterance")
        }
        try await send(
            SpeechRailTTSAppendText(
                requestID: requestID,
                sequence: sequence,
                text: text
            ).jsonObject
        )
    }

    /// 关闭文本输入。`lastSequence` 必须是最后一次 ACK 的序号；空输入为 `-1`。
    public func finishTTSText(lastSequence: Int) async throws {
        guard let requestID = activeTTSRequestID else {
            throw Failure.transport("没有活动的 TTS utterance")
        }
        try await send(
            SpeechRailTTSFinishText(
                requestID: requestID,
                lastSequence: lastSequence
            ).jsonObject
        )
    }

    /// 取消正在合成的 TTS（用户插话）。未发送的音频由服务端丢弃。
    public func cancelTTS() async throws {
        guard let requestID = activeTTSRequestID else { return }
        // 用户侧停止优先：取消确认在途期间即使服务端再发 delta，也不能进入播放层。
        activeTTSAudioSuppressed = true
        try await send(
            SpeechRailTTSCancel(requestID: requestID).jsonObject
        )
    }

    /// 推流结束时的分人 EOF 屏障：等水位对齐再封存，末段不丢（§14.3）。
    ///
    /// 只在协商过分人的会话上调用。同一个 `event_id` 重试是幂等的——所以重试安全。
    public func finishDiarization() async throws {
        guard diarizationEnabled, !finishSent else { return }
        let id = finishEventID ?? UUID().uuidString
        finishEventID = id
        try await send(["type": "speechrail.diarization.finish", "event_id": id])
        finishSent = true
    }

    private func send(_ payload: [String: Any]) async throws {
        guard let transport else { throw Failure.transport("连接还没建立") }
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else {
            throw Failure.transport("事件没能编码成 JSON")
        }
        do {
            try await transport.send(text)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    /// 转写会话的配置。形状对着服务端的 current-only 解析写：
    /// `session.audio.input.format` 固定 24 kHz `audio/pcm`，转写模型位于
    /// `session.audio.input.transcription`，SpeechRail 扩展位于 `session.speechrail`。
    ///
    /// 分人按 `session.speechrail.diarization.enabled` opt-in，**只能在这里声明一次**：
    /// 首个 PCM 之后再协商，服务端按契约回 `invalid_state`（§14.3 的开关粒度）。
    /// 分人需要「采样区间 → 说话人」与「文本 → 采样区间」两半，所以同批打开
    /// `speechrail.alignment`（服务端的对齐器是分人的既有前置条件）。
    private func configurationEvent() -> [String: Any] {
        SpeechRailSessionUpdate(
            model: model,
            task: sessionTask,
            endpointing: SpeechRailSessionUpdate.Endpointing(
                threshold: threshold,
                silenceDurationMilliseconds: silenceDurationMilliseconds
            ),
            ttsEnabled: callerTTSEnabled,
            alignment: SpeechRailSessionUpdate.Alignment(
                enabled: diarizationEnabled,
                granularity: diarizationEnabled ? "segment" : nil
            ),
            diarizationEnabled: diarizationEnabled,
            expectedASRRevision: nil,
            expectedTTSRevision: expectedModelRevision
        ).jsonObject
    }

    private func withStageTimeout<T: Sendable>(
        stage: RealtimeDrainStage,
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.drainTimedOut(stage)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func waitForConfigurationAcknowledgement(
        timeout: Duration = .seconds(8)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if configurationAcknowledged {
                return
            }
            if let configurationFailure {
                throw configurationFailure
            }
            if didClose {
                throw Failure.closed(closeCode)
            }
            guard clock.now < deadline else {
                throw Failure.transport("语音服务没有在期限内确认转写配置。")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Wait until every declared input item has reached a terminal.
    private func waitForDeclaredItems(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if didClose {
                throw Failure.closed(closeCode)
            }
            if closeBarrier.isReadyToClear {
                return
            }
            guard clock.now < deadline else {
                throw Failure.drainTimedOut(.terminalItems)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForDiarizationAcknowledgement(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if didClose {
                throw Failure.closed(closeCode)
            }
            if diarizationAcknowledged {
                return
            }
            guard clock.now < deadline else {
                throw Failure.drainTimedOut(.diarization)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - 下行

    private func startReceiveLoop(using transport: any RealtimeASRTransport) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await transport.receive()
                    await self?.handle(message)
                } catch {
                    await self?.finish(code: await transport.closeCode())
                    return
                }
            }
        }
    }

    private func handle(_ message: RealtimeASRSocketFrame) async {
        let data: Data
        switch message {
        case .text(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        case .unsupported: return
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else {
            return
        }
        let metadata = RealtimeEventMetadata(
            eventID: object["event_id"] as? String,
            sessionID: object["session_id"] as? String,
            sequence: Self.int(object["sequence"])
        )
        if let sessionID = metadata.sessionID {
            serverSessionID = sessionID
        }
        if let eventID = metadata.eventID {
            recentEventIDs.append(eventID)
            if recentEventIDs.count > 64 {
                recentEventIDs.removeFirst(recentEventIDs.count - 64)
            }
        }
        sequenceStatus = sequenceValidator.accept(metadata)
        currentEventMetadata = metadata
        currentEventReceivedAt = ContinuousClock().now
        defer {
            currentEventMetadata = nil
            currentEventReceivedAt = nil
        }
        switch type {
        case "session.created":
            let model = (object["session"] as? [String: Any])?["model"] as? String ?? self.model
            emit(.ready(model: model))
        case "session.updated":
            configurationAcknowledged = true
            emit(.configured)
        case "conversation.item.input_audio_transcription.delta":
            emit(
                .partial(
                    itemID: object["item_id"] as? String ?? "",
                    delta: object["delta"] as? String ?? ""
                )
            )
        case "speechrail.transcription.hypothesis":
            // 官方 `delta` 是可证明的稳定前缀；hypothesis 是**可改写全文**。两者分开解码，
            // 调用点用整段替换而不是追加（契约 §5.1）。
            let itemID = object["utterance_id"] as? String ?? ""
            guard let revision = Self.int(object["revision"]), revision > 0,
                  let text = object["text"] as? String else {
                emit(.failed(itemID: itemID, code: "invalid_hypothesis", message: "流式转写快照格式无效"))
                return
            }
            emit(.partialSnapshot(itemID: itemID, revision: revision, text: text))
        case "conversation.item.input_audio_transcription.completed":
            let itemID = object["item_id"] as? String ?? ""
            settleDeclaredItem(failed: false)
            emit(.completed(itemID: itemID, transcript: object["transcript"] as? String ?? ""))
        case "conversation.item.input_audio_transcription.failed":
            let itemID = object["item_id"] as? String ?? ""
            let error = object["error"] as? [String: Any]
            settleDeclaredItem(failed: true)
            emit(
                .failed(
                    itemID: itemID,
                    code: error?["code"] as? String ?? object["code"] as? String ?? "backend_error",
                    message: error?["message"] as? String ?? object["message"] as? String ?? "流式转写失败"
                )
            )
        case "speechrail.alignment.done":
            guard let itemID = object["utterance_id"] as? String else { break }
            alignmentUnitsByItem[itemID] = Self.alignmentUnits(object["units"])
            emit(attribution(itemID: itemID, isFinal: false))
        case "speechrail.alignment.failed":
            let itemID = object["utterance_id"] as? String ?? ""
            let error = object["error"] as? [String: Any]
            emit(
                .alignmentFailed(
                    itemID: itemID,
                    code: error?["code"] as? String ?? "alignment_failed",
                    message: error?["message"] as? String ?? "对齐没有拿到时间证据。"
                )
            )
        case "speechrail.diarization.updated":
            guard let itemID = object["utterance_id"] as? String else { break }
            diarizationSpansByItem[itemID] = Self.diarizationSpans(object["units"])
            emit(attribution(itemID: itemID, isFinal: false))
        case "speechrail.diarization.done":
            guard let itemID = object["utterance_id"] as? String else { break }
            diarizationSpansByItem[itemID] = Self.diarizationSpans(object["units"])
            diarizationAcknowledged = true
            emit(attribution(itemID: itemID, isFinal: true))
        case "speechrail.diarization.failed":
            let error = object["error"] as? [String: Any]
            emit(
                .diarizationDegraded(
                    code: error?["code"] as? String ?? "diarization_degraded",
                    message: error?["message"] as? String ?? "说话人编号停止更新了。"
                )
            )
        case "speechrail.tts.started":
            guard
                let started = TTSSessionStarted(object: object),
                started.requestID == activeTTSRequestID
            else { break }
            // 播放层只认 canonical 24 kHz / mono PCM16。服务端协商出别的格式时明确失败，
            // 不把未协商的字节当 24k 喂给播放器（§6 第 3 条）。
            guard started.sampleRate == TTSAudioPosition.canonicalSampleRate,
                  started.channels == 1 else {
                emit(
                    .ttsEnded(
                        requestID: started.requestID,
                        taskID: started.taskID,
                        status: "failed",
                        code: "unsupported_output_format",
                        message: "语音服务给出的输出格式不是 24 kHz 单声道。"
                    )
                )
                clearActiveTTS()
                break
            }
            activeTTSTaskID = started.taskID
            activeTTSStreaming = true
            expectedAudioChunkIndex = 0
            expectedAudioSampleOffset = 0
            emit(
                .ttsStarted(
                    requestID: started.requestID,
                    taskID: started.taskID,
                    limits: started.limits
                )
            )
        case "speechrail.tts.text_accepted":
            guard
                let accepted = TTSTextAccepted(object: object),
                accepted.requestID == activeTTSRequestID,
                accepted.appendSequence == activeTTSConsumedSequence + 1
            else { break }
            activeTTSConsumedSequence = accepted.appendSequence
            emit(
                .ttsTextAccepted(
                    requestID: accepted.requestID,
                    taskID: accepted.taskID,
                    appendSequence: accepted.appendSequence,
                    totalCodepoints: accepted.totalCodepoints
                )
            )
        case "speechrail.tts.audio.delta":
            // 旧 request、取消后的迟到块、身份不符的块：静默隔离，不进播放层。
            guard
                let requestID = activeTTSRequestID,
                object["request_id"] as? String == requestID,
                !activeTTSAudioSuppressed
            else { break }
            guard
                let base64 = object["delta"] as? String,
                let data = Data(base64Encoded: base64),
                !data.isEmpty,
                data.count.isMultiple(of: MemoryLayout<Int16>.size)
            else {
                droppedAudioChunks += 1
                break
            }
            if activeTTSStreaming, !acceptAudioPosition(object: object, pcmBytes: data.count) {
                droppedAudioChunks += 1
                break
            }
            emit(.ttsAudio(requestID: requestID, taskID: activeTTSTaskID, pcm: data))
        case "speechrail.tts.completed", "speechrail.tts.cancelled", "speechrail.tts.failed":
            guard
                let requestID = object["request_id"] as? String,
                requestID == activeTTSRequestID
            else { break }
            let status: String
            var code: String?
            var message: String?
            switch type {
            case "speechrail.tts.completed":
                status = "completed"
            case "speechrail.tts.cancelled":
                status = "cancelled"
            default:
                status = "failed"
                let error = object["error"] as? [String: Any]
                code = error?["code"] as? String ?? "tts_failed"
                message = error?["message"] as? String ?? "这一轮朗读失败了。"
            }
            emit(
                .ttsEnded(
                    requestID: requestID,
                    taskID: activeTTSTaskID ?? object["task_id"] as? String,
                    status: status,
                    code: code,
                    message: message
                )
            )
            clearActiveTTS()
        case "error":
            let error = object["error"] as? [String: Any]
            let errorMessage = error?["message"] as? String ?? "语音服务返回了一个错误"
            if !configurationAcknowledged {
                configurationFailure = .transport(errorMessage)
            }
            let requestID = error?["request_id"] as? String ?? object["request_id"] as? String
            if let requestID, requestID == activeTTSRequestID {
                clearActiveTTS()
            }
            emit(
                .serverError(
                    code: error?["code"] as? String ?? error?["type"] as? String ?? "unknown",
                    message: errorMessage,
                    requestID: requestID
                )
            )
        default:
            // 其余事件不属于这一层：不报错，也不记日志。
            break
        }
    }

    /// 一个转写终态把"自上次终态以来上行过 PCM"的计数归零，并让**已声明**的
    /// 输入 item 到达终态。服务端自己按静音提交时我们没有声明过 item，
    /// 那就只清计数、不动屏障。
    private func settleDeclaredItem(failed: Bool) {
        appendedBytesSinceTerminal = 0
        guard closeBarrier.pendingItems > 0 else { return }
        if failed {
            closeBarrier.failed()
        } else {
            closeBarrier.completed()
        }
    }

    /// 把对齐单元与分人区间按采样重叠合起来，交给会话层（§5.2）。
    private func attribution(itemID: String, isFinal: Bool) -> Event {
        let units = alignmentUnitsByItem[itemID] ?? []
        guard !units.isEmpty else {
            return .attribution(itemID: itemID, units: [], isFinal: isFinal)
        }
        let spans = diarizationSpansByItem[itemID] ?? []
        let merged = units.map { unit -> AttributionUnit in
            var updated = unit
            if let start = unit.audioStartSample, let end = unit.audioEndSample, end > start {
                updated.speaker = Self.speaker(forStart: start, end: end, spans: spans)
            }
            return updated
        }
        return .attribution(itemID: itemID, units: merged, isFinal: isFinal)
    }

    /// 取与 `[start, end)` 重叠最多的分人区间的说话人（没有重叠就是 `nil`）。
    private static func speaker(forStart start: Int, end: Int, spans: [DiarizationSpan]) -> String? {
        var best: (overlap: Int, speaker: String?)?
        for span in spans {
            let overlap = min(end, span.endSample) - max(start, span.startSample)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap {
                best = (overlap, span.speaker)
            }
        }
        return best?.speaker
    }

    /// `speechrail.alignment.done.units`：文本片段 → 采样区间（`segment_uid` 是修订坐标）。
    private static func alignmentUnits(_ value: Any?) -> [AttributionUnit] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let uid = item["segment_uid"] as? String else { return nil }
            return AttributionUnit(
                segmentUID: uid,
                speaker: nil,
                textStart: int(item["text_start"]),
                textEnd: int(item["text_end"]),
                audioStartSample: int(item["audio_start_sample"]),
                audioEndSample: int(item["audio_end_sample"]),
                timingQuality: item["timing_quality"] as? String,
                granularity: item["granularity"] as? String
            )
        }
    }

    /// `speechrail.diarization.updated/done.units`：采样区间 → 匿名说话人（可空）。
    private static func diarizationSpans(_ value: Any?) -> [DiarizationSpan] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let span = item["sample_span"] as? [String: Any],
                  let start = int(span["start"]),
                  let end = int(span["end"]),
                  end > start
            else { return nil }
            let speaker = item["speaker"] as? String
            return DiarizationSpan(
                speaker: (speaker?.isEmpty ?? true) ? nil : speaker,
                startSample: start,
                endSample: end
            )
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// 增量 PCM 的块序号与 sample offset 必须严格连续。输出格式由 `started.output_format`
    /// 协商（只接受 canonical 24 kHz / mono PCM16）；不合格的块宁可丢掉，
    /// 也不能把错位音频拼进同一轮播放缓冲。
    private func acceptAudioPosition(object: [String: Any], pcmBytes: Int) -> Bool {
        guard let position = TTSAudioPosition(object: object) else { return false }
        guard
            position.chunkIndex == expectedAudioChunkIndex,
            position.sampleOffset == expectedAudioSampleOffset
        else { return false }
        expectedAudioChunkIndex += 1
        expectedAudioSampleOffset = position.nextSampleOffset(pcmBytes: pcmBytes)
        return true
    }

    /// 清空当前 TTS 关联。**只有身份匹配的调用方才该调用它**，
    /// 否则旧 response 的迟到终态会抹掉新一轮的状态。
    private func clearActiveTTS() {
        activeTTSRequestID = nil
        activeTTSTaskID = nil
        activeTTSAudioSuppressed = false
        activeTTSStreaming = false
        activeTTSConsumedSequence = -1
        expectedAudioChunkIndex = 0
        expectedAudioSampleOffset = 0
    }

    private func emit(_ event: Event) {
        continuation?.yield(
            RealtimeEventEnvelope(
                metadata: currentEventMetadata ?? RealtimeEventMetadata(),
                payload: event,
                receivedAt: currentEventReceivedAt ?? ContinuousClock().now
            )
        )
    }

    /// 只收尾一次：接收循环、显式 `close()`、以及流被取消这三条路都会走到这里。
    private func finish(code: Int?) async {
        guard !didClose else { return }
        didClose = true
        closeCode = code
        receiveLoop?.cancel()
        receiveLoop = nil
        let transport = self.transport
        self.transport = nil
        activeTTSRequestID = nil
        activeTTSTaskID = nil
        activeTTSAudioSuppressed = true
        await transport?.cancel()
        continuation?.yield(
            RealtimeEventEnvelope(
                metadata: RealtimeEventMetadata(),
                payload: .closed(code: code)
            )
        )
        continuation?.finish()
        continuation = nil
    }
}
