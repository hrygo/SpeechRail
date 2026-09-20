import Foundation

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

    public init(metadata: RealtimeEventMetadata, payload: Payload) {
        self.metadata = metadata
        self.payload = payload
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
