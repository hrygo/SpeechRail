import Foundation

/// Canonical current-only transcription session configuration.
///
/// The factory intentionally exposes only the fields SpeechRail implements;
/// it cannot emit the removed `session.update` or conversation/response
/// orchestration fields.
public struct TranscriptionSessionUpdate: Sendable {
    public enum PartialMode: String, Sendable {
        case delta
        case snapshot
    }

    /// Supported cadence for live subtitle partial updates.
    ///
    /// The service accepts 500 ms as its lowest low-latency transcription chunk;
    /// callers still choose it explicitly so the general session default remains
    /// suitable for clients that prefer fewer model refreshes.
    public static let captionChunkDurationMilliseconds = 500

    public let type = "transcription_session.update"
    public let model: String
    public let threshold: Double
    public let prefixPaddingMilliseconds: Int
    public let silenceDurationMilliseconds: Int
    public let callerTTSEnabled: Bool
    public let diarizationEnabled: Bool
    public let expectedModelRevision: String?
    public let renderReceiptsEnabled: Bool
    public let partialMode: PartialMode
    public let chunkDurationMilliseconds: Int

    public init(
        model: String,
        threshold: Double = 0.5,
        prefixPaddingMilliseconds: Int = 300,
        silenceDurationMilliseconds: Int = 400,
        callerTTSEnabled: Bool = false,
        diarizationEnabled: Bool = false,
        expectedModelRevision: String? = nil,
        renderReceiptsEnabled: Bool = false,
        partialMode: PartialMode = .delta,
        chunkDurationMilliseconds: Int = 2_000
    ) {
        self.model = model
        self.threshold = threshold
        self.prefixPaddingMilliseconds = prefixPaddingMilliseconds
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.callerTTSEnabled = callerTTSEnabled
        self.diarizationEnabled = diarizationEnabled
        self.expectedModelRevision = expectedModelRevision
        self.renderReceiptsEnabled = renderReceiptsEnabled
        self.partialMode = partialMode
        self.chunkDurationMilliseconds = chunkDurationMilliseconds
    }

    public var jsonObject: [String: Any] {
        var speechrail: [String: Any] = [
            "tts": ["enabled": callerTTSEnabled]
        ]
        if diarizationEnabled {
            speechrail["diarization"] = ["enabled": true]
        }
        if let expectedModelRevision {
            speechrail["model_revision"] = ["expected": expectedModelRevision]
        }
        if renderReceiptsEnabled {
            speechrail["render_receipts"] = ["enabled": true]
        }
        speechrail["transcription"] = [
            "partial_mode": partialMode.rawValue,
            "chunk_duration_ms": chunkDurationMilliseconds
        ]
        return [
            "type": type,
            "session": [
                "input_audio_format": "pcm16",
                "input_audio_transcription": ["model": model],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": threshold,
                    "prefix_padding_ms": prefixPaddingMilliseconds,
                    "silence_duration_ms": silenceDurationMilliseconds
                ],
                "speechrail": speechrail
            ]
        ]
    }
}

/// Stateless caller-owned TTS render command.
public struct SpeechRailTTSCreate: Sendable {
    public let type = "speechrail.tts.create"
    public let requestID: String
    public let text: String
    public let voice: String?
    public let speed: Double?
    public let expectedVoiceRevision: String?

    public init(
        requestID: String,
        text: String,
        voice: String? = nil,
        speed: Double? = nil,
        expectedVoiceRevision: String? = nil
    ) {
        self.requestID = requestID
        self.text = text
        self.voice = voice
        self.speed = speed
        self.expectedVoiceRevision = expectedVoiceRevision
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "type": type,
            "request_id": requestID,
            "text": text
        ]
        if let voice { object["voice"] = voice }
        if let speed { object["speed"] = speed }
        if let expectedVoiceRevision { object["expected_voice_revision"] = expectedVoiceRevision }
        return object
    }
}

/// Explicit caller-owned TTS cancellation command.
public struct SpeechRailTTSCancel: Sendable {
    public let type = "speechrail.tts.cancel"
    public let requestID: String
    public let responseID: String?

    public init(requestID: String, responseID: String? = nil) {
        self.requestID = requestID
        self.responseID = responseID
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "type": type,
            "request_id": requestID
        ]
        if let responseID { object["response_id"] = responseID }
        return object
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

/// The ASR close barrier. A clear is safe only after every committed item has
/// reached a terminal completed/failed state.
public struct RealtimeCloseBarrier: Equatable, Sendable {
    private var committedItemIDs: Set<String> = []
    private var terminalItemIDs: Set<String> = []

    public init() {}

    public var isReadyToClear: Bool {
        committedItemIDs.subtracting(terminalItemIDs).isEmpty
    }

    public var pendingItemIDs: Set<String> {
        committedItemIDs.subtracting(terminalItemIDs)
    }

    public mutating func committed(itemID: String) {
        committedItemIDs.insert(itemID)
    }

    public mutating func completed(itemID: String) {
        terminalItemIDs.insert(itemID)
    }

    public mutating func failed(itemID: String) {
        terminalItemIDs.insert(itemID)
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
/// 与 `speechrail.tts.create` 互斥：两者共享同一个「连接内只允许一个活动 TTS」
/// 判定，差别只在于文本是一次给完还是持续追加。
public struct SpeechRailTTSStart: Sendable {
    public let type = "speechrail.tts.start"
    public let requestID: String
    public let voice: String?
    public let speed: Double?
    public let expectedVoiceRevision: String?
    public let expectedModelRevision: String?
    /// 只能**收紧**服务端默认值；放宽会被 `tts_stream_limit_exceeded` 拒绝。
    public let limits: [String: Double]?

    public init(
        requestID: String,
        voice: String? = nil,
        speed: Double? = nil,
        expectedVoiceRevision: String? = nil,
        expectedModelRevision: String? = nil,
        limits: [String: Double]? = nil
    ) {
        self.requestID = requestID
        self.voice = voice
        self.speed = speed
        self.expectedVoiceRevision = expectedVoiceRevision
        self.expectedModelRevision = expectedModelRevision
        self.limits = limits
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "type": type,
            "request_id": requestID
        ]
        if let voice { object["voice"] = voice }
        if let speed { object["speed"] = speed }
        if let expectedVoiceRevision { object["expected_voice_revision"] = expectedVoiceRevision }
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
    public let responseID: String?
    public let sequence: Int
    public let text: String

    public init(requestID: String, sequence: Int, text: String, responseID: String? = nil) {
        self.requestID = requestID
        self.responseID = responseID
        self.sequence = sequence
        self.text = text
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "type": type,
            "request_id": requestID,
            "sequence": sequence,
            "text": text
        ]
        if let responseID { object["response_id"] = responseID }
        return object
    }
}

/// `speechrail.tts.finish_text`：关闭文本输入并继续生成尾音。
///
/// `last_sequence` 必须等于最后一次 ACK 的 `append_sequence`；空输入为 `-1`。
public struct SpeechRailTTSFinishText: Sendable {
    public let type = "speechrail.tts.finish_text"
    public let requestID: String
    public let responseID: String?
    public let lastSequence: Int

    public init(requestID: String, lastSequence: Int, responseID: String? = nil) {
        self.requestID = requestID
        self.lastSequence = lastSequence
        self.responseID = responseID
    }

    public var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "type": type,
            "request_id": requestID,
            "last_sequence": lastSequence
        ]
        if let responseID { object["response_id"] = responseID }
        return object
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
    public let responseID: String
    public let protocolVersion: Int?
    public let implementationVersion: String?
    public let voice: String?
    public let voiceVariant: String?
    public let voiceMode: String?
    public let limits: TTSStreamLimits?
    public let sampleRate: Int
    public let channels: Int

    public init?(object: [String: Any]) {
        guard
            let requestID = object["request_id"] as? String,
            let responseID = object["response_id"] as? String
        else { return nil }
        self.requestID = requestID
        self.responseID = responseID
        self.protocolVersion = object["protocol_version"] as? Int
        self.implementationVersion = object["implementation_version"] as? String
        self.voice = object["voice"] as? String
        self.voiceVariant = object["voice_variant"] as? String
        self.voiceMode = object["voice_mode"] as? String
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
    public let responseID: String
    public let appendSequence: Int
    public let acceptedCodepoints: Int
    public let totalCodepoints: Int

    public init?(object: [String: Any]) {
        guard
            let requestID = object["request_id"] as? String,
            let responseID = object["response_id"] as? String,
            let appendSequence = object["append_sequence"] as? Int
        else { return nil }
        self.requestID = requestID
        self.responseID = responseID
        self.appendSequence = appendSequence
        self.acceptedCodepoints = object["accepted_codepoints"] as? Int ?? 0
        self.totalCodepoints = object["total_codepoints"] as? Int ?? 0
    }
}

/// `response.output_audio.delta.speechrail`：一块增量 PCM 的字节精确位置。
public struct TTSAudioPosition: Equatable, Sendable {
    public static let canonicalSampleRate = 24_000

    public let chunkIndex: Int
    public let sampleOffset: Int
    public let sampleRate: Int
    public let channels: Int

    public init?(speechrail: Any?) {
        guard
            let speechrail = speechrail as? [String: Any],
            speechrail["kind"] as? String == "tts",
            let chunkIndex = speechrail["chunk_index"] as? Int,
            let sampleOffset = speechrail["sample_offset"] as? Int
        else { return nil }
        self.chunkIndex = chunkIndex
        self.sampleOffset = sampleOffset
        self.sampleRate = speechrail["sample_rate"] as? Int ?? Self.canonicalSampleRate
        self.channels = speechrail["channels"] as? Int ?? 1
    }

    /// 这一块之后的下一个 sample offset（mono PCM16：一个样本两个字节）。
    public func nextSampleOffset(pcmBytes: Int) -> Int {
        sampleOffset + pcmBytes / MemoryLayout<Int16>.size
    }
}
