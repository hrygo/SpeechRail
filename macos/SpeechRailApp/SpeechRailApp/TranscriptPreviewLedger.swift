import Foundation

/// Owns revisioned ASR previews and frozen input boundaries for one connection.
///
/// The ledger is deliberately independent of persistence and database timing.
/// A boundary is derived from the server's 24 kHz input sample span when the
/// boundary event arrives; a later final event cannot move that interval.
public struct TranscriptPreviewLedger: Sendable {
    public struct Identity: Hashable, Sendable {
        public let connection: Int
        public let generation: Int

        public init(connection: Int, generation: Int) {
            self.connection = connection
            self.generation = generation
        }
    }

    public struct ItemIdentity: Hashable, Sendable {
        public let connection: Int
        public let generation: Int
        public let itemID: String

        public init(identity: Identity, itemID: String) {
            self.connection = identity.connection
            self.generation = identity.generation
            self.itemID = itemID
        }
    }

    public enum SegmentCloseReason: String, Sendable, Equatable {
        case vad
        case clientCommit = "client_commit"
        case budgetRollover = "budget_rollover"
    }

    public struct InputRange: Sendable, Equatable {
        public let sampleSpan: RealtimeASRClient.RealtimeSampleSpan
        /// Connection-relative seconds mapped onto the session timeline.
        /// These are segment input bounds, not word-level acoustic alignment.
        public let startSeconds: TimeInterval?
        public let endSeconds: TimeInterval?
        public let isApproximate: Bool
    }

    public struct Boundary: Sendable, Equatable {
        public let itemID: String
        public let inputRange: InputRange
        public let reason: SegmentCloseReason
        public let commitEventID: String?
        public let eventID: String?
    }

    public struct RecoveryNote: Sendable, Equatable {
        public let itemID: String
        public let text: String
    }

    public struct CommittedItem: Sendable, Equatable {
        public let identity: Identity
        public let itemID: String
        public let finalText: String
        public let boundary: Boundary?
        public let recoveryNote: RecoveryNote?
    }

    public enum CommitOutcome: Sendable, Equatable {
        case duplicate
        case discarded
        case commit(CommittedItem)
    }

    private struct Item: Sendable {
        var previewText = ""
        var latestRevision = 0
        var boundary: Boundary?
    }

    private static let sampleRate = 24_000.0
    private static let maximumActiveItems = 128
    private static let maximumRememberedEventIDs = 512
    private static let maximumRememberedFinals = 512

    private var identity: Identity?
    private var captureTimelineOffsetSeconds: TimeInterval?
    private var items: [String: Item] = [:]
    private var visibleItemID: String?
    private var eventIDOrder: [String] = []
    private var eventIDs: Set<String> = []
    private var finalizedItemOrder: [String] = []
    private var finalizedItemIDs: Set<String> = []

    public init() {}

    public var visiblePartial: String? {
        guard let visibleItemID,
              let text = items[visibleItemID]?.previewText,
              !text.isEmpty
        else {
            return nil
        }
        return text
    }

    public func recoveryNote(identity: Identity, itemID: String) -> RecoveryNote? {
        guard accepts(identity),
              let text = items[itemID]?.previewText,
              !text.isEmpty
        else {
            return nil
        }
        return RecoveryNote(itemID: itemID, text: text)
    }

    public func boundary(identity: Identity, itemID: String) -> Boundary? {
        guard accepts(identity) else { return nil }
        return items[itemID]?.boundary
    }

    public mutating func beginGeneration(
        identity: Identity,
        captureTimelineOffsetSeconds: TimeInterval? = nil
    ) {
        self.identity = identity
        if let captureTimelineOffsetSeconds,
           captureTimelineOffsetSeconds.isFinite,
           captureTimelineOffsetSeconds >= 0 {
            self.captureTimelineOffsetSeconds = captureTimelineOffsetSeconds
        } else {
            self.captureTimelineOffsetSeconds = nil
        }
        items.removeAll(keepingCapacity: true)
        visibleItemID = nil
        eventIDOrder.removeAll(keepingCapacity: true)
        eventIDs.removeAll(keepingCapacity: true)
        finalizedItemOrder.removeAll(keepingCapacity: true)
        finalizedItemIDs.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func acceptDelta(
        identity: Identity,
        itemID: String,
        delta: String,
        eventID: String?
    ) -> Bool {
        guard accepts(identity), !itemID.isEmpty, !delta.isEmpty,
              acceptEventID(eventID),
              var item = itemForUpdate(itemID)
        else {
            return false
        }
        item.previewText = String((item.previewText + delta).suffix(4_096))
        items[itemID] = item
        visibleItemID = itemID
        return true
    }

    @discardableResult
    public mutating func acceptSnapshot(
        identity: Identity,
        itemID: String,
        revision: Int,
        text: String,
        eventID: String?
    ) -> Bool {
        guard accepts(identity), !itemID.isEmpty, revision > 0,
              acceptEventID(eventID),
              var item = itemForUpdate(itemID),
              revision > item.latestRevision
        else {
            return false
        }
        item.latestRevision = revision
        item.previewText = String(text.suffix(4_096))
        items[itemID] = item
        if !text.isEmpty { visibleItemID = itemID }
        return true
    }

    @discardableResult
    public mutating func closeSegment(
        identity: Identity,
        itemID: String,
        sampleSpan: RealtimeASRClient.RealtimeSampleSpan,
        reason: SegmentCloseReason,
        commitEventID: String?,
        eventID: String?
    ) -> Bool {
        guard accepts(identity), !itemID.isEmpty,
              sampleSpan.startSample >= 0,
              sampleSpan.endSample > sampleSpan.startSample,
              acceptEventID(eventID),
              var item = itemForUpdate(itemID),
              item.boundary == nil
        else {
            return false
        }
        let startSeconds = captureTimelineOffsetSeconds.map {
            $0 + Double(sampleSpan.startSample) / Self.sampleRate
        }
        let endSeconds = captureTimelineOffsetSeconds.map {
            $0 + Double(sampleSpan.endSample) / Self.sampleRate
        }
        item.boundary = Boundary(
            itemID: itemID,
            inputRange: InputRange(
                sampleSpan: sampleSpan,
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                isApproximate: startSeconds != nil && endSeconds != nil
            ),
            reason: reason,
            commitEventID: commitEventID,
            eventID: eventID
        )
        items[itemID] = item
        return true
    }

    public mutating func resolveCommit(
        identity: Identity,
        itemID: String,
        transcript: String
    ) -> CommitOutcome {
        guard accepts(identity), !itemID.isEmpty else { return .discarded }
        guard !finalizedItemIDs.contains(itemID) else { return .duplicate }
        guard var item = itemForUpdate(itemID) else { return .discarded }

        rememberFinal(itemID)
        let finalText = Self.trimmed(transcript)
        let recoveryNote: RecoveryNote?
        if finalText.isEmpty, !item.previewText.isEmpty {
            recoveryNote = RecoveryNote(itemID: itemID, text: item.previewText)
        } else {
            recoveryNote = nil
        }
        let boundary = item.boundary
        item.previewText = ""
        items.removeValue(forKey: itemID)
        if visibleItemID == itemID { visibleItemID = nil }

        guard !finalText.isEmpty || recoveryNote != nil else { return .discarded }
        return .commit(
            CommittedItem(
                identity: identity,
                itemID: itemID,
                finalText: finalText,
                boundary: boundary,
                recoveryNote: recoveryNote
            )
        )
    }

    /// Marks a failed item terminal and clears only its own preview slot.
    @discardableResult
    public mutating func resolveFailure(identity: Identity, itemID: String) -> Bool {
        guard accepts(identity), !itemID.isEmpty,
              !finalizedItemIDs.contains(itemID)
        else {
            return false
        }
        rememberFinal(itemID)
        items.removeValue(forKey: itemID)
        if visibleItemID == itemID { visibleItemID = nil }
        return true
    }

    public mutating func clearPartial(identity: Identity, itemID: String) {
        guard accepts(identity), !itemID.isEmpty else { return }
        guard var item = items[itemID] else { return }
        item.previewText = ""
        items[itemID] = item
        if visibleItemID == itemID { visibleItemID = nil }
    }

    private func accepts(_ candidate: Identity) -> Bool {
        identity == candidate
    }

    private mutating func itemForUpdate(_ itemID: String) -> Item? {
        guard !finalizedItemIDs.contains(itemID) else { return nil }
        if let item = items[itemID] { return item }
        guard items.count < Self.maximumActiveItems else { return nil }
        let item = Item()
        items[itemID] = item
        return item
    }

    private mutating func acceptEventID(_ eventID: String?) -> Bool {
        guard let eventID, !eventID.isEmpty else { return true }
        guard eventIDs.insert(eventID).inserted else { return false }
        eventIDOrder.append(eventID)
        if eventIDOrder.count > Self.maximumRememberedEventIDs {
            eventIDs.remove(eventIDOrder.removeFirst())
        }
        return true
    }

    private mutating func rememberFinal(_ itemID: String) {
        guard finalizedItemIDs.insert(itemID).inserted else { return }
        finalizedItemOrder.append(itemID)
        if finalizedItemOrder.count > Self.maximumRememberedFinals {
            finalizedItemIDs.remove(finalizedItemOrder.removeFirst())
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
