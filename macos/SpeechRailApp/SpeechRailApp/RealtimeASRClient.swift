import Foundation

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

    /// 流式转写的线上格式。契约只接受 16 kHz 与 24 kHz 两种 PCM16；
    /// 原生层归一到 16 kHz，把"不得改格式"这条硬约束变成结构上碰不到的情况。
    public static let sampleRate: Double = 16_000

    public enum Failure: LocalizedError, Equatable {
        case unsupportedModel(String)
        case transport(String)
        case closed(Int?)

        public var errorDescription: String? {
            switch self {
            case .unsupportedModel(let model):
                "这个档位不支持流式模型 \(model)。"
            case .transport(let message):
                "连不上语音服务：\(message)"
            case .closed(let code):
                code.map { "语音服务断开了连接（\($0)）。" } ?? "语音服务断开了连接。"
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

    /// 服务端事件里**字幕会话真正需要的**那一部分。其余事件（TTS 的 response.*）不收进枚举：
    /// 这一层不做播放，收进来只会多一条没人处理的分支。
    public enum Event: Sendable {
        /// `session.created`：握手完成，服务端声明了实际能力。
        case ready(model: String)
        /// `session.updated`：我们那次 `session.update` 生效了，可以开始喂 PCM。
        case configured
        case speechStarted
        case speechStopped
        case committed(itemID: String)
        /// partial（内存态）。它是增量，调用点自己累加。
        case partial(itemID: String, delta: String)
        case segment(itemID: String, segment: Segment)
        case completed(itemID: String, transcript: String)
        case failed(itemID: String, code: String, message: String)
        case serverError(code: String, message: String)
        case closed(code: Int?)
    }

    private let url: URL
    private let apiKey: String?
    private let model: String
    /// 静音窗口。**字幕 400 ms / 会议 900 ms**（`SCOPE-DECISIONS` 的口径，也是
    /// 服务端既有策略）：字幕要快，会议要整句。
    private let silenceDurationMilliseconds: Int
    private let threshold: Double
    private let session: URLSession

    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var didClose = false
    private var continuation: AsyncStream<Event>.Continuation?
    private var stream: AsyncStream<Event>?

    public init(
        port: Int = 8201,
        model: String = RealtimeASRClient.canonicalASRModel,
        silenceDurationMilliseconds: Int = 400,
        threshold: Double = 0.5,
        apiKey: String? = nil,
        session: URLSession = .shared
    ) {
        self.url = URL(string: "ws://127.0.0.1:\(port)/v1/realtime")!
        // 与 REST 走**同一处**凭据解析：服务配了 key 时，握手缺 `Authorization` 会被
        // 以 1008 关掉（契约「连接与认证」）。这里不自己读环境变量。
        self.apiKey = apiKey ?? SpeechRailAPICredentialProvider.resolve()
        self.model = model
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.threshold = threshold
        self.session = session
    }

    /// 事件流。**只能取一次**：这条流与这条连接一一对应，多个消费者会让"谁负责写库"变得不确定。
    public func events() -> AsyncStream<Event> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        self.stream = stream
        self.continuation = continuation
        return stream
    }

    // MARK: - 连接

    /// 建连、声明转写会话、等 `session.updated`。返回即表示可以开始喂 PCM。
    public func connect() async throws {
        guard task == nil else { return }
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        startReceiveLoop(on: task)

        // `session.update` 要在首个 PCM **之前**落地：契约里格式与分人都只在那一刻协商一次。
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

    /// 转写会话的配置。形状对着服务端的解析写（`compatibility/openai_realtime.py` 的
    /// `apply_session_update`）：`audio.input.format` 收 `{type: "audio/pcm", rate: 16000}`，
    /// `turn_detection` 收 `server_vad` + 静音窗口，`transcription.language` 可省。
    private func configurationEvent() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "model": model,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Int(Self.sampleRate)],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": threshold,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": silenceDurationMilliseconds
                        ],
                        "transcription": ["model": model]
                    ]
                ]
            ]
        ]
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
        switch type {
        case "session.created":
            let model = (object["session"] as? [String: Any])?["model"] as? String ?? self.model
            emit(.ready(model: model))
        case "session.updated":
            emit(.configured)
        case "input_audio_buffer.speech_started":
            emit(.speechStarted)
        case "input_audio_buffer.speech_stopped":
            emit(.speechStopped)
        case "input_audio_buffer.committed":
            emit(.committed(itemID: object["item_id"] as? String ?? ""))
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
            emit(
                .completed(
                    itemID: object["item_id"] as? String ?? "",
                    transcript: object["transcript"] as? String ?? ""
                )
            )
        case "conversation.item.input_audio_transcription.failed":
            emit(
                .failed(
                    itemID: object["item_id"] as? String ?? "",
                    code: object["code"] as? String ?? "backend_error",
                    message: object["message"] as? String ?? "流式转写失败"
                )
            )
        case "error":
            let error = object["error"] as? [String: Any]
            emit(
                .serverError(
                    code: error?["code"] as? String ?? "unknown",
                    message: error?["message"] as? String ?? "语音服务返回了一个错误"
                )
            )
        default:
            // 其余事件（TTS 的 response.*）不属于这一层：不报错，也不记日志——
            // 它们只是我们没订阅的那一半协议。
            break
        }
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return TimeInterval(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private func emit(_ event: Event) {
        continuation?.yield(event)
    }

    /// 只收尾一次：接收循环、显式 `close()`、以及流被取消这三条路都会走到这里。
    private func finish(code: Int?) {
        guard !didClose else { return }
        didClose = true
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        continuation?.yield(.closed(code: code))
        continuation?.finish()
        continuation = nil
    }
}
