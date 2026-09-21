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
