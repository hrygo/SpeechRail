import Foundation

/// Canonical current-only transcription session configuration (`session.update`).
///
/// The factory intentionally exposes only the fields SpeechRail implements; it
/// cannot emit the removed `transcription_session.update`, flat
/// `input_audio_format`, or conversation/response orchestration fields.
public struct SpeechRailSessionUpdate: Sendable {
    /// The one wire audio contract: 24 kHz mono PCM16 little-endian.
    public static let wireSampleRate = 24_000

    public enum Task: String, Sendable {
        case conversation
        case caption
        case transcription
        case render
        case voiceDesign = "voice_design"
    }

    /// Server-side endpointing lives in the SpeechRail namespace; the official
    /// `audio.input.turn_detection` field stays `null` when it is set.
    public struct Endpointing: Sendable, Equatable {
        public var threshold: Double
        public var prefixPaddingMilliseconds: Int
        public var silenceDurationMilliseconds: Int

        public init(
            threshold: Double = 0.5,
            prefixPaddingMilliseconds: Int = 300,
            silenceDurationMilliseconds: Int = 400
        ) {
            self.threshold = threshold
            self.prefixPaddingMilliseconds = prefixPaddingMilliseconds
            self.silenceDurationMilliseconds = silenceDurationMilliseconds
        }

        var jsonObject: [String: Any] {
            [
                "mode": "server_vad",
                "threshold": threshold,
                "prefix_padding_ms": prefixPaddingMilliseconds,
                "silence_duration_ms": silenceDurationMilliseconds
            ]
        }
    }

    public struct Alignment: Sendable, Equatable {
        public var enabled: Bool
        /// `segment` / `word` / `character`; `nil` lets the server choose.
        public var granularity: String?
        /// `q8` / `bf16`; `nil` lets the server choose.
        public var precision: String?

        public init(enabled: Bool, granularity: String? = nil, precision: String? = nil) {
            self.enabled = enabled
            self.granularity = granularity
            self.precision = precision
        }

        var jsonObject: [String: Any] {
            var object: [String: Any] = ["enabled": enabled]
            if let granularity { object["granularity"] = granularity }
            if let precision { object["precision"] = precision }
            return object
        }
    }

    public let eventID: String
    public let model: String
    public let task: Task
    public let language: String?
    public let prompt: String?
    public let keywords: [String]?
    public let timestampGranularities: [String]?
    public let endpointing: Endpointing?
    public let ttsEnabled: Bool
    public let alignment: Alignment
    public let diarizationEnabled: Bool
    public let expectedASRRevision: String?
    public let expectedTTSRevision: String?

    public init(
        model: String,
        task: Task = .conversation,
        language: String? = nil,
        prompt: String? = nil,
        keywords: [String]? = nil,
        timestampGranularities: [String]? = nil,
        endpointing: Endpointing? = nil,
        ttsEnabled: Bool = false,
        alignment: Alignment = Alignment(enabled: false),
        diarizationEnabled: Bool = false,
        expectedASRRevision: String? = nil,
        expectedTTSRevision: String? = nil,
        eventID: String = "evt_session_update"
    ) {
        self.eventID = eventID
        self.model = model
        self.task = task
        self.language = language
        self.prompt = prompt
        self.keywords = keywords
        self.timestampGranularities = timestampGranularities
        self.endpointing = endpointing
        self.ttsEnabled = ttsEnabled
        self.alignment = alignment
        self.diarizationEnabled = diarizationEnabled
        self.expectedASRRevision = expectedASRRevision
        self.expectedTTSRevision = expectedTTSRevision
    }

    public var jsonObject: [String: Any] {
        var transcription: [String: Any] = ["model": model]
        if let language { transcription["language"] = language }
        if let prompt, !prompt.isEmpty { transcription["prompt"] = prompt }
        if let keywords { transcription["keywords"] = keywords }
        if let timestampGranularities {
            transcription["timestamp_granularities"] = timestampGranularities
        }
        var speechrail: [String: Any] = [
            "task": task.rawValue,
            "tts": ["enabled": ttsEnabled],
            "alignment": alignment.jsonObject,
            "diarization": ["enabled": diarizationEnabled]
        ]
        if let endpointing { speechrail["endpointing"] = endpointing.jsonObject }
        if let expectedASRRevision { speechrail["expected_asr_revision"] = expectedASRRevision }
        if let expectedTTSRevision { speechrail["expected_tts_revision"] = expectedTTSRevision }
        return [
            "type": "session.update",
            "event_id": eventID,
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Self.wireSampleRate],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ],
                "speechrail": speechrail
            ]
        ]
    }
}

/// Explicit caller-owned TTS cancellation command.
public struct SpeechRailTTSCancel: Sendable {
    public let type = "speechrail.tts.cancel"
    public let requestID: String
    public let eventID: String

    public init(requestID: String, eventID: String = UUID().uuidString) {
        self.requestID = requestID
        self.eventID = eventID
    }

    public var jsonObject: [String: Any] {
        [
            "type": type,
            "event_id": eventID,
            "request_id": requestID
        ]
    }
}

/// Common metadata carried by every SpeechRail Realtime server event.
public struct RealtimeEventMetadata: Codable, Equatable, Sendable {
    public let eventID: String?
    public let sessionID: String?
    public let sequence: Int?

    public init(
        eventID: String? = nil,
        sessionID: String? = nil,
        sequence: Int? = nil
    ) {
        self.eventID = eventID
        self.sessionID = sessionID
        self.sequence = sequence
    }

    private enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case sessionID = "session_id"
        case sequence
    }
}

/// A decoded Realtime event. The payload remains transport-specific while its
/// ordering/session metadata is shared by all consumers.
public struct RealtimeEventEnvelope<Payload: Sendable>: Sendable {
    public let metadata: RealtimeEventMetadata
    public let payload: Payload
    /// Local monotonic receive time; never serialized or sent over the wire.
    public let receivedAt: ContinuousClock.Instant

    public init(
        metadata: RealtimeEventMetadata,
        payload: Payload,
        receivedAt: ContinuousClock.Instant = ContinuousClock().now
    ) {
        self.metadata = metadata
        self.payload = payload
        self.receivedAt = receivedAt
    }
}

public enum RealtimeSequenceStatus: Equatable, Sendable {
    case first
    case contiguous
    case gap(expected: Int, received: Int)
    case regression(last: Int, received: Int)
    case sessionChanged(expected: String?, received: String?)
    case missing
}

/// Stateful sequence/session validation for one WebSocket connection.
public struct RealtimeSequenceValidator: Sendable {
    public private(set) var sessionID: String?
    public private(set) var lastSequence: Int?

    public init(sessionID: String? = nil, lastSequence: Int? = nil) {
        self.sessionID = sessionID
        self.lastSequence = lastSequence
    }

    public mutating func accept(_ metadata: RealtimeEventMetadata) -> RealtimeSequenceStatus {
        if let expectedSession = sessionID, expectedSession != metadata.sessionID {
            let status = RealtimeSequenceStatus.sessionChanged(
                expected: expectedSession,
                received: metadata.sessionID
            )
            sessionID = metadata.sessionID
            lastSequence = metadata.sequence
            return status
        }

        if sessionID == nil {
            sessionID = metadata.sessionID
        }

        guard let sequence = metadata.sequence else {
            return .missing
        }

        guard let lastSequence else {
            self.lastSequence = sequence
            return .first
        }

        if sequence == lastSequence + 1 {
            self.lastSequence = sequence
            return .contiguous
        }

        if sequence <= lastSequence {
            return .regression(last: lastSequence, received: sequence)
        }

        // Keep the received high-water mark so a later lower value is still
        // reported as a regression instead of masking the original gap.
        self.lastSequence = sequence
        return .gap(expected: lastSequence + 1, received: sequence)
    }

    public mutating func reset() {
        sessionID = nil
        lastSequence = nil
    }
}

/// The ASR close barrier for the current wire.
///
/// The single current wire has no per-item `input_audio_buffer.committed`
/// acknowledgement: an input item becomes observable only through its
/// transcription terminal. The caller therefore declares every item it is
/// about to commit with `expectItem()`, and the barrier is satisfied by the
/// matching number of terminal events rather than by inferring a count from
/// removed server events.
public struct RealtimeCloseBarrier: Equatable, Sendable {
    private var expectedItems = 0
    private var settledItems = 0

    public init() {}

    public var isReadyToClear: Bool { settledItems >= expectedItems }

    /// Items that were declared but have not reached a terminal yet.
    public var pendingItems: Int { max(0, expectedItems - settledItems) }

    /// Declare one input item the caller is about to commit.
    public mutating func expectItem() {
        expectedItems += 1
    }

    /// One declared item reached `completed`.
    public mutating func completed() {
        settledItems += 1
    }

    /// One declared item reached `failed`; a failed terminal still settles it.
    public mutating func failed() {
        settledItems += 1
    }
}

public enum RealtimeDrainStage: String, Equatable, Sendable {
    case commit
    case terminalItems = "terminal_items"
    case diarization
    case clear
    case close
}

public enum RealtimeClosePlan {
    public enum Step: Equatable, Sendable {
        case commit
        case waitForTerminalItems
        case clear
        case close
    }

    public static let steps: [Step] = [
        .commit,
        .waitForTerminalItems,
        .clear,
        .close,
    ]
}

// MARK: - 增量 TTS utterance（契约 §3.3.1）

/// `speechrail.tts.start`：把一个 utterance 绑到**同一次**生成状态上。
///
/// `task` 与 `voice` 都是**必填**：服务端据此为这一轮选唯一角色与音色身份。
/// 文本不再随 start 一次给完，而是通过 `speechrail.tts.append_text` 持续追加。
public struct SpeechRailTTSStart: Sendable {
    public let type = "speechrail.tts.start"
    public let requestID: String
    public let task: SpeechRailSessionUpdate.Task
    public let voice: String
    public let speed: Double?
    public let voiceRevision: String?
    public let expectedModelRevision: String?
    /// 只能**收紧**服务端默认值；放宽会被 `tts_stream_limit_exceeded` 拒绝。
    public let limits: [String: Double]?
    public let eventID: String

    public init(
        requestID: String,
        task: SpeechRailSessionUpdate.Task,
        voice: String,
        speed: Double? = nil,
        voiceRevision: String? = nil,
        expectedModelRevision: String? = nil,
        limits: [String: Double]? = nil,
        eventID: String = UUID().uuidString
    ) {
        self.requestID = requestID
        self.task = task
        self.voice = voice
        self.speed = speed
        self.voiceRevision = voiceRevision
        self.expectedModelRevision = expectedModelRevision
        self.limits = limits
        self.eventID = eventID
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "type": type,
            "event_id": eventID,
            "request_id": requestID,
            "task": task.rawValue,
            "voice": voice
        ]
        if let speed { object["speed"] = speed }
        if let voiceRevision { object["voice_revision"] = voiceRevision }
        if let expectedModelRevision { object["expected_model_revision"] = expectedModelRevision }
        if let limits { object["limits"] = limits }
        return object
    }
}

/// `speechrail.tts.append_text`：追加一段**不可修改**文本。
///
/// `sequence` 从 `0` 起严格连续递增；重复或跳号会被拒绝且不消费文本。
public struct SpeechRailTTSAppendText: Sendable {
    public let type = "speechrail.tts.append_text"
    public let requestID: String
    public let sequence: Int
    public let text: String
    public let eventID: String

    public init(
        requestID: String,
        sequence: Int,
        text: String,
        eventID: String = UUID().uuidString
    ) {
        self.requestID = requestID
        self.sequence = sequence
        self.text = text
        self.eventID = eventID
    }

    public var jsonObject: [String: Any] {
        [
            "type": type,
            "event_id": eventID,
            "request_id": requestID,
            "sequence": sequence,
            "text": text
        ]
    }
}

/// `speechrail.tts.finish_text`：关闭文本输入并继续生成尾音。
///
/// `last_sequence` 必须等于最后一次 ACK 的 `append_sequence`（非负）。没有任何
/// ACK 的空输入没有可用的屏障，调用方应当取消这一轮而不是发 `finish_text`。
public struct SpeechRailTTSFinishText: Sendable {
    public let type = "speechrail.tts.finish_text"
    public let requestID: String
    public let lastSequence: Int
    public let eventID: String

    public init(
        requestID: String,
        lastSequence: Int,
        eventID: String = UUID().uuidString
    ) {
        self.requestID = requestID
        self.lastSequence = lastSequence
        self.eventID = eventID
    }

    public var jsonObject: [String: Any] {
        [
            "type": type,
            "event_id": eventID,
            "request_id": requestID,
            "last_sequence": lastSequence
        ]
    }
}

/// 一次增量 utterance 的生效限额（`speechrail.tts.started.limits`）。
///
/// 文本限额按 Unicode codepoint 计，音频限额按字节计——两个预算不能互相折算。
public struct TTSStreamLimits: Equatable, Sendable {
    /// 服务端当前默认值；客户端只用来做本地预检，不用它替代服务端校验。
    public static let serverDefaults = TTSStreamLimits(
        maxAppendCodepoints: 512,
        maxTotalCodepoints: 4_096,
        maxPendingCodepoints: 2_048,
        maxPendingAudioBytes: 48_000,
        inputWaitSeconds: 15,
        utteranceWallClockSeconds: 120,
        slowConsumerSeconds: 2
    )

    public let maxAppendCodepoints: Int
    public let maxTotalCodepoints: Int
    public let maxPendingCodepoints: Int
    public let maxPendingAudioBytes: Int
    public let inputWaitSeconds: Double
    public let utteranceWallClockSeconds: Double
    public let slowConsumerSeconds: Double

    public init(
        maxAppendCodepoints: Int,
        maxTotalCodepoints: Int,
        maxPendingCodepoints: Int,
        maxPendingAudioBytes: Int,
        inputWaitSeconds: Double,
        utteranceWallClockSeconds: Double,
        slowConsumerSeconds: Double
    ) {
        self.maxAppendCodepoints = maxAppendCodepoints
        self.maxTotalCodepoints = maxTotalCodepoints
        self.maxPendingCodepoints = maxPendingCodepoints
        self.maxPendingAudioBytes = maxPendingAudioBytes
        self.inputWaitSeconds = inputWaitSeconds
        self.utteranceWallClockSeconds = utteranceWallClockSeconds
        self.slowConsumerSeconds = slowConsumerSeconds
    }

    /// 解析 `speechrail.tts.started.limits`；字段缺失或类型不符返回 `nil`
    /// （调用方回落到 `serverDefaults`，不用半份限额做判断）。
    public init?(object: [String: Any]) {
        guard
            let maxAppendCodepoints = object["max_append_codepoints"] as? Int,
            let maxTotalCodepoints = object["max_total_codepoints"] as? Int,
            let maxPendingCodepoints = object["max_pending_codepoints"] as? Int,
            let maxPendingAudioBytes = object["max_pending_audio_bytes"] as? Int,
            let inputWaitSeconds = Self.seconds(object["input_wait_seconds"]),
            let utteranceWallClockSeconds = Self.seconds(object["utterance_wall_clock_seconds"]),
            let slowConsumerSeconds = Self.seconds(object["slow_consumer_seconds"])
        else { return nil }
        self.init(
            maxAppendCodepoints: maxAppendCodepoints,
            maxTotalCodepoints: maxTotalCodepoints,
            maxPendingCodepoints: maxPendingCodepoints,
            maxPendingAudioBytes: maxPendingAudioBytes,
            inputWaitSeconds: inputWaitSeconds,
            utteranceWallClockSeconds: utteranceWallClockSeconds,
            slowConsumerSeconds: slowConsumerSeconds
        )
    }

    private static func seconds(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

/// `speechrail.tts.started`：utterance 已取得准入。客户端在此之前不得 append。
public struct TTSSessionStarted: Equatable, Sendable {
    public let requestID: String
    public let taskID: String?
    public let planID: String?
    public let voiceRevision: String?
    public let limits: TTSStreamLimits?
    public let sampleRate: Int
    public let channels: Int

    public init?(object: [String: Any]) {
        guard let requestID = object["request_id"] as? String else { return nil }
        self.requestID = requestID
        self.taskID = object["task_id"] as? String
        self.planID = object["plan_id"] as? String
        self.voiceRevision = object["voice_revision"] as? String
        let limitObject = object["limits"] as? [String: Any]
        self.limits = limitObject.flatMap(TTSStreamLimits.init(object:))
        let format = object["output_format"] as? [String: Any]
        self.sampleRate = format?["sample_rate"] as? Int ?? 24_000
        self.channels = format?["channels"] as? Int ?? 1
    }
}

/// `speechrail.tts.text_accepted`：一次 append 的 ACK。
///
/// `appendSequence` 是调用方的追加序号，**不是**传输层给每个事件打的
/// 连接级 `sequence`——两者同名会被静默覆盖，所以线上字段叫 `append_sequence`。
public struct TTSTextAccepted: Equatable, Sendable {
    public let requestID: String
    public let taskID: String?
    public let appendSequence: Int
    public let acceptedCodepoints: Int
    public let totalCodepoints: Int

    public init?(object: [String: Any]) {
        guard
            let requestID = object["request_id"] as? String,
            let appendSequence = object["append_sequence"] as? Int
        else { return nil }
        self.requestID = requestID
        self.taskID = object["task_id"] as? String
        self.appendSequence = appendSequence
        self.acceptedCodepoints = object["accepted_codepoints"] as? Int ?? 0
        self.totalCodepoints = object["total_codepoints"] as? Int ?? 0
    }
}

/// `speechrail.tts.audio.delta`：一块增量 PCM 的字节精确位置。
///
/// `chunk_index` / `sample_offset` 是**顶层**字段；输出格式固定 24 kHz / mono
/// PCM16，由 `speechrail.tts.started.output_format` 协商，块里不重复声明。
public struct TTSAudioPosition: Equatable, Sendable {
    public static let canonicalSampleRate = 24_000

    public let chunkIndex: Int
    public let sampleOffset: Int

    public init?(object: [String: Any]) {
        guard
            let chunkIndex = object["chunk_index"] as? Int,
            let sampleOffset = object["sample_offset"] as? Int
        else { return nil }
        self.chunkIndex = chunkIndex
        self.sampleOffset = sampleOffset
    }

    /// 这一块之后的下一个 sample offset（mono PCM16：一个样本两个字节）。
    public func nextSampleOffset(pcmBytes: Int) -> Int {
        sampleOffset + pcmBytes / MemoryLayout<Int16>.size
    }
}
