import Foundation
import SpeechRailControlKit

// `/v1/realtime` 的客户端（契约：`contracts/realtime-openai.md`）。
//
// 它只做四件事：**连、配、喂 PCM、收事件**。没有大模型、没有播放、没有业务状态——
// 那些属于助手 / 会议 / 字幕各自的会话层（`TECHNICAL-DESIGN` §5.3）。
//
// 三条从契约直接落下来的硬约束，写在这里免得以后被"顺手优化"掉：
//
//   1. **线上格式固定 16 kHz / 单声道 / PCM16**，而且**首个 PCM 之后不得改格式**。
//      换设备只能重建采集、不重开会话（`TECHNICAL-DESIGN` §5.2 第 5 条）。
//   2. **partial 只进内存**：`delta` 是"可直接追加的稳定前缀"，服务端不会发不可追加的切片，
//      但上游仍可能改写尾部——所以定稿只认 `completed` 的全量 `transcript`。
//   3. **`backend_busy` 是准入结果，不是异常**：它连的是会话占用守卫，不是错误弹窗
//      （`IMPLEMENTATION-READINESS` §3 的同一条结论）。

/// Realtime ASR 的客户端。一个实例对应一条 WebSocket、一次会话。
public actor RealtimeASRClient {
    /// 契约里的 canonical ASR profile。用别名（`gpt-4o-transcribe`）也能连上，
    /// 但那是给标准 OpenAI 客户端准备的；App 是我们自己的客户端，报 canonical 名。
    public static let canonicalASRModel = "speechrail/qwen3-asr-1.7b"

    /// 流式转写的线上格式。当前 SpeechRail transcription session 固定使用
    /// 16 kHz / 单声道 / PCM16；原生层归一到这个格式。
    public static let sampleRate: Double = 16_000

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

    /// 分人归属的一段。分人档位下由 `speechrail.diarization.updated` 修正，
    /// **只改归属，不改正文**（§15.3 第 2 条）。
    public struct Segment: Sendable, Equatable {
        public var id: String
        public var text: String
        public var start: TimeInterval
        public var end: TimeInterval
        public var speaker: String?

        public init(id: String, text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil) {
            self.id = id
            self.text = text
            self.start = start
            self.end = end
            self.speaker = speaker
        }
    }

    /// 分人扩展里的一个**归属单元**（`attribution_units`）。
    ///
    /// `segmentUID` 是服务端给的稳定标识：正文不可变，归属靠它原位修订。客户端因此必须
    /// 记住「这个 uid 落在库里哪一行」——否则后续的修订事件无处可写（`SpeakerLabeling`）。
    public struct AttributionUnit: Sendable, Equatable {
        public var segmentUID: String
        public var revision: Int
        /// `tentative` / `stable` / `unknown`。**只有 unknown 会把 speaker 清空**。
        public var status: String
        public var speaker: String?
        public var textStart: Int?
        public var textEnd: Int?
        public var audioStartSample: Int?
        public var audioEndSample: Int?
        public var timingQuality: String?

        public init(
            segmentUID: String,
            revision: Int = 0,
            status: String = "stable",
            speaker: String? = nil,
            textStart: Int? = nil,
            textEnd: Int? = nil,
            audioStartSample: Int? = nil,
            audioEndSample: Int? = nil,
            timingQuality: String? = nil
        ) {
            self.segmentUID = segmentUID
            self.revision = revision
            self.status = status
            self.speaker = speaker
            self.textStart = textStart
            self.textEnd = textEnd
            self.audioStartSample = audioStartSample
            self.audioEndSample = audioEndSample
            self.timingQuality = timingQuality
        }

        /// 修订是否已经"定下来"。`tentative` 中途可能被改掉，落库没有坏处（原位更新），
        /// 但界面上的chip要区分「暂定」与「已定」。
        public var isStable: Bool { status == "stable" || status == "unknown" }
    }

    /// 会话级声学建议：服务端认为这几个匿名标签可能是同一个人。
    /// **只是建议**：要不要合并由用户按（§14.3 的边界：不做声纹、不跨会话）。
    public struct SpeakerLink: Sendable, Equatable {
        public var from: String
        public var to: String
        public var confidence: Double?

        public init(from: String, to: String, confidence: Double? = nil) {
            self.from = from
            self.to = to
            self.confidence = confidence
        }
    }

    /// 服务端事件里**字幕会话真正需要的**那一部分。其余事件（TTS 的 response.*）不收进枚举：
    /// 这一层不做播放，收进来只会多一条没人处理的分支。
    public enum Event: Sendable {
        /// `session.created`：握手完成，服务端声明了实际能力。
        case ready(model: String)
        /// `transcription_session.updated`：配置生效，可以开始喂 PCM。
        case configured
        case speechStarted
        case speechStopped
        case committed(itemID: String)
        /// partial（内存态）。它是增量，调用点自己累加。
        case partial(itemID: String, delta: String)
        case segment(itemID: String, segment: Segment)
        /// 终态。分人会话额外带归属单元（未启用分人时为空数组）。
        case completed(itemID: String, transcript: String, units: [AttributionUnit])
        case failed(itemID: String, code: String, message: String)
        /// `speechrail.diarization.updated`：归属修订，**只改归属列**。
        case attribution(stableThroughSample: Int, units: [AttributionUnit], links: [SpeakerLink])
        /// `speechrail.diarization.status`：一次 active→degraded。正文继续，标签停更。
        case diarizationDegraded(code: String, message: String)
        /// `speechrail.diarization.done`：EOF 屏障到位，末段不会丢。
        case diarizationDone(throughSample: Int, status: String)
        /// TTS 音频块（24 kHz PCM16）。助手那一侧才用得上。
        case responseAudio(Data)
        /// TTS 一轮结束：`completed` / `cancelled` / `failed`。
        case responseDone(status: String, receipt: RenderReceipt?)
        case serverError(
            code: String,
            message: String,
            retryable: Bool?,
            busyReason: String?,
            retryHint: String?,
            requestID: String?
        )
        /// `input_audio_buffer.cleared`：清空屏障的服务端确认。
        case cleared
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
    private let expectedModelRevision: String?
    private let renderReceiptsEnabled: Bool
    private let callerTTSEnabled: Bool
    private let session: URLSession

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var didClose = false
    private var continuation: AsyncStream<RealtimeEventEnvelope<Event>>.Continuation?
    private var stream: AsyncStream<RealtimeEventEnvelope<Event>>?
    /// 下一次 caller-owned TTS request 使用的音色。
    private var voice: String?
    private var activeTTSRequestID: String?
    private var activeTTSResponseID: String?
    /// `finish` 的 event_id。契约要求同一个 id 重试幂等、不同 id 拒绝。
    private var finishEventID: String?
    private var finishSent = false
    private var clearSent = false
    private var clearAcknowledged = false
    private var committedEventCount = 0
    private var closeBarrier = RealtimeCloseBarrier()
    private var diarizationAcknowledged = false
    private var sequenceValidator = RealtimeSequenceValidator()
    /// Latest sequence diagnostic. The event envelope remains the source of
    /// truth; this property is only a non-sensitive convenience for session UI.
    public private(set) var sequenceStatus: RealtimeSequenceStatus = .missing
    /// Opaque server session identity and a bounded in-memory event ID window.
    /// Neither is persisted or logged.
    public private(set) var serverSessionID: String?
    public private(set) var recentEventIDs: [String] = []
    private var currentEventMetadata: RealtimeEventMetadata?
    private var closeCode: Int?

    public init(
        port: Int = 8201,
        model: String = RealtimeASRClient.canonicalASRModel,
        silenceDurationMilliseconds: Int = 400,
        threshold: Double = 0.5,
        diarizationEnabled: Bool = false,
        voice: String? = nil,
        apiKey: String? = nil,
        session: URLSession = .shared,
        expectedModelRevision: String? = nil,
        renderReceiptsEnabled: Bool = false,
        callerTTSEnabled: Bool = false
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
        self.expectedModelRevision = expectedModelRevision
        self.renderReceiptsEnabled = renderReceiptsEnabled
        self.callerTTSEnabled = callerTTSEnabled
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
        guard task == nil else { return }
        guard !didClose else { throw Failure.closed(closeCode) }
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        startReceiveLoop(on: task)

        // `transcription_session.update` 要在首个 PCM **之前**落地：格式、分人和
        // caller-owned TTS 都在这一刻协商。
        try await send(configurationEvent())
    }

    /// 关掉连接。调用点负责把它带来的中断写进账本（`service_lost`）。
    public func close() async {
        finish(code: nil)
    }

    // MARK: - 上行

    /// 追加一段 16 kHz / 单声道 / PCM16。
    public func append(_ pcm: Data) async throws {
        guard !pcm.isEmpty else { return }
        let payload: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm.base64EncodedString()
        ]
        try await send(payload)
    }

    /// 手动触发终态。`server_vad` 模式下服务端自己会提交，这一条是给"用户按了结束"用的：
    /// 它保证最后半句也走完 `committed` → `completed`，而不是留在缓冲区里丢掉。
    public func commit() async throws {
        try await send(["type": "input_audio_buffer.commit"])
    }

    /// Discards the uncommitted input buffer. Repeating the operation on one
    /// connection is intentionally idempotent, but a new connection gets a
    /// fresh clear barrier.
    public func clear() async throws {
        guard !clearSent else { return }
        try await send(["type": "input_audio_buffer.clear"])
        clearSent = true
    }

    /// Closes one logical recording without treating a socket close as an ASR
    /// receipt. The server must first acknowledge the commit and terminal
    /// state of every committed item, then acknowledge `clear`.
    public func drainAndClear(timeout: Duration = .seconds(8)) async throws {
        let committedCountBeforeCommit = committedEventCount
        try await withStageTimeout(stage: .commit, timeout: timeout) {
            try await self.commit()
        }
        try await waitForCommittedItems(
            timeout: timeout,
            afterCommittedEventCount: committedCountBeforeCommit
        )
        if diarizationEnabled {
            try await withStageTimeout(stage: .diarization, timeout: timeout) {
                try await self.finishDiarization()
            }
            try await waitForDiarizationAcknowledgement(timeout: timeout)
        }
        try await withStageTimeout(stage: .clear, timeout: timeout) {
            try await self.clear()
        }
        try await waitForClearAcknowledgement(timeout: timeout)
    }

    /// 换音色。**下一次 TTS request 生效**，只影响 TTS，不进 prompt。
    public func updateVoice(_ voice: String) async throws {
        self.voice = voice
    }

    /// 让服务端把调用方生成的一段文本念出来（助手用；字幕/会议不调）。
    /// LLM、历史、句子切分和排队都在调用方；这里仅提交一个无状态 render request。
    public func sendTTSCreate(text: String, requestID: String? = nil) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let requestID = requestID ?? "tts_req_\(UUID().uuidString.lowercased())"
        activeTTSRequestID = requestID
        do {
            try await send(
                SpeechRailTTSCreate(requestID: requestID, text: text, voice: voice).jsonObject
            )
        } catch {
            if activeTTSRequestID == requestID {
                activeTTSRequestID = nil
                activeTTSResponseID = nil
            }
            throw error
        }
    }

    /// 取消正在合成的 TTS（用户插话）。未发送的音频由服务端丢弃。
    public func cancelTTS() async throws {
        guard let requestID = activeTTSRequestID else { return }
        try await send(
            SpeechRailTTSCancel(requestID: requestID, responseID: activeTTSResponseID).jsonObject
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
        guard let task else { throw Failure.transport("连接还没建立") }
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else {
            throw Failure.transport("事件没能编码成 JSON")
        }
        do {
            try await task.send(.string(text))
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    /// 转写会话的配置。形状对着服务端的 current-only 解析写：
    /// `input_audio_format` 固定 `pcm16`，转写模型位于 `input_audio_transcription`。
    ///
    /// 分人按 `session.speechrail.diarization.enabled` opt-in，**只能在这里声明一次**：
    /// 首个 PCM 之后再协商，服务端按契约回 `invalid_state`（§14.3 的开关粒度）。
    private func configurationEvent() -> [String: Any] {
        TranscriptionSessionUpdate(
            model: model,
            threshold: threshold,
            silenceDurationMilliseconds: silenceDurationMilliseconds,
            callerTTSEnabled: callerTTSEnabled,
            diarizationEnabled: diarizationEnabled,
            expectedModelRevision: expectedModelRevision,
            renderReceiptsEnabled: renderReceiptsEnabled
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

    private func waitForCommittedItems(
        timeout: Duration,
        afterCommittedEventCount baseline: Int
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if didClose {
                throw Failure.closed(closeCode)
            }
            if committedEventCount > baseline, closeBarrier.isReadyToClear {
                return
            }
            guard clock.now < deadline else {
                throw Failure.drainTimedOut(.terminalItems)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForClearAcknowledgement(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if didClose {
                throw Failure.closed(closeCode)
            }
            if clearAcknowledged {
                return
            }
            guard clock.now < deadline else {
                throw Failure.drainTimedOut(.clear)
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

    private func startReceiveLoop(on task: URLSessionWebSocketTask) {
        receiveLoop?.cancel()
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await self?.handle(message)
                } catch {
                    await self?.finish(code: task.closeCode == .invalid ? nil : task.closeCode.rawValue)
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return
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
        defer { currentEventMetadata = nil }
        switch type {
        case "session.created":
            let model = (object["session"] as? [String: Any])?["model"] as? String ?? self.model
            emit(.ready(model: model))
        case "transcription_session.updated":
            emit(.configured)
        case "input_audio_buffer.speech_started":
            emit(.speechStarted)
        case "input_audio_buffer.speech_stopped":
            emit(.speechStopped)
        case "input_audio_buffer.committed":
            let itemID = object["item_id"] as? String ?? ""
            committedEventCount += 1
            closeBarrier.committed(itemID: itemID)
            emit(.committed(itemID: itemID))
        case "input_audio_buffer.cleared":
            clearAcknowledged = true
            emit(.cleared)
        case "conversation.item.input_audio_transcription.delta":
            emit(
                .partial(
                    itemID: object["item_id"] as? String ?? "",
                    delta: object["delta"] as? String ?? ""
                )
            )
        case "conversation.item.input_audio_transcription.segment":
            emit(
                .segment(
                    itemID: object["item_id"] as? String ?? "",
                    segment: Segment(
                        id: object["id"] as? String ?? UUID().uuidString,
                        text: object["text"] as? String ?? "",
                        // 契约里 segment 的时间单位是秒；分人模式下这些是词级对齐结果。
                        start: Self.seconds(object["start"]) ?? 0,
                        end: Self.seconds(object["end"]) ?? 0,
                        speaker: object["speaker"] as? String
                    )
                )
            )
        case "conversation.item.input_audio_transcription.completed":
            let itemID = object["item_id"] as? String ?? ""
            closeBarrier.completed(itemID: itemID)
            emit(
                .completed(
                    itemID: itemID,
                    transcript: object["transcript"] as? String ?? "",
                    units: Self.attributionUnits(object["attribution_units"])
                )
            )
        case "speechrail.diarization.updated":
            emit(
                .attribution(
                    stableThroughSample: Self.int(object["stable_through_sample"]) ?? 0,
                    units: Self.attributionUnits(object["updates"]),
                    links: Self.speakerLinks(object["speaker_links"])
                )
            )
        case "speechrail.diarization.status":
            emit(
                .diarizationDegraded(
                    code: object["code"] as? String ?? "diarization_degraded",
                    message: object["message"] as? String ?? "说话人编号停止更新了。"
                )
            )
        case "speechrail.diarization.done":
            diarizationAcknowledged = true
            emit(
                .diarizationDone(
                    throughSample: Self.int(object["through_sample"]) ?? 0,
                    status: object["status"] as? String ?? "complete"
                )
            )
        case "response.created":
            activeTTSResponseID = (object["response"] as? [String: Any])?["id"] as? String
        case "response.output_audio.delta":
            if let base64 = object["delta"] as? String, let data = Data(base64Encoded: base64) {
                emit(.responseAudio(data))
            }
        case "response.done":
            let response = object["response"] as? [String: Any]
            let status = response?["status"] as? String ?? "completed"
            emit(
                .responseDone(
                    status: status,
                    receipt: Self.renderReceipt(from: object)
                )
            )
            activeTTSRequestID = nil
            activeTTSResponseID = nil
        case "conversation.item.input_audio_transcription.failed":
            let itemID = object["item_id"] as? String ?? ""
            closeBarrier.failed(itemID: itemID)
            emit(
                .failed(
                    itemID: itemID,
                    code: object["code"] as? String ?? "backend_error",
                    message: object["message"] as? String ?? "流式转写失败"
                )
            )
        case "error":
            let error = object["error"] as? [String: Any]
            let speechrail = (error?["speechrail"] as? [String: Any])
                ?? (object["speechrail"] as? [String: Any])
            let requestID = error?["request_id"] as? String
            if requestID == activeTTSRequestID {
                activeTTSRequestID = nil
                activeTTSResponseID = nil
            }
            emit(
                .serverError(
                    code: error?["code"] as? String ?? error?["type"] as? String ?? "unknown",
                    message: error?["message"] as? String ?? "语音服务返回了一个错误",
                    retryable: speechrail?["retryable"] as? Bool ?? error?["retryable"] as? Bool,
                    busyReason: speechrail?["busy_reason"] as? String ?? error?["busy_reason"] as? String,
                    retryHint: speechrail?["retry_hint"] as? String ?? error?["retry_hint"] as? String,
                    requestID: requestID
                )
            )
        default:
            // 其余事件（TTS 的 response.*）不属于这一层：不报错，也不记日志——
            // 它们只是我们没订阅的那一半协议。
            break
        }
    }

    /// `attribution_units` 与 `updates` 的形状一致，共用一份解析（契约 §Diarization 扩展）。
    private static func attributionUnits(_ value: Any?) -> [AttributionUnit] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let uid = item["segment_uid"] as? String else { return nil }
            return AttributionUnit(
                segmentUID: uid,
                revision: int(item["revision"]) ?? 0,
                status: item["status"] as? String ?? "stable",
                speaker: item["speaker"] as? String,
                textStart: int(item["text_start"]),
                textEnd: int(item["text_end"]),
                audioStartSample: int(item["audio_start_sample"]),
                audioEndSample: int(item["audio_end_sample"]),
                timingQuality: item["timing_quality"] as? String
            )
        }
    }

    private static func speakerLinks(_ value: Any?) -> [SpeakerLink] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard
                let from = item["from"] as? String ?? item["speaker"] as? String,
                let to = item["to"] as? String ?? item["target"] as? String
            else { return nil }
            return SpeakerLink(from: from, to: to, confidence: seconds(item["confidence"]))
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return TimeInterval(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    /// Decode the current top-level `speechrail.render_receipt` shape.
    private static func renderReceipt(from object: [String: Any]) -> RenderReceipt? {
        var candidates: [[String: Any]] = []
        if let speechrail = object["speechrail"] as? [String: Any],
           let receipt = speechrail["render_receipt"] as? [String: Any] {
            candidates.append(receipt)
        }

        let decoder = JSONDecoder()
        for candidate in candidates {
            guard let data = try? JSONSerialization.data(withJSONObject: candidate),
                  let receipt = try? decoder.decode(RenderReceipt.self, from: data)
            else { continue }
            return receipt
        }
        return nil
    }

    private func emit(_ event: Event) {
        continuation?.yield(
            RealtimeEventEnvelope(
                metadata: currentEventMetadata ?? RealtimeEventMetadata(),
                payload: event
            )
        )
    }

    /// 只收尾一次：接收循环、显式 `close()`、以及流被取消这三条路都会走到这里。
    private func finish(code: Int?) {
        guard !didClose else { return }
        didClose = true
        closeCode = code
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
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
