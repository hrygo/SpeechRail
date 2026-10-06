import Foundation

/// Collects closed ASR items into one caller-owned assistant input turn.
///
/// A budget rollover closes an ASR item but keeps the business turn open.
/// Only a VAD or explicit client-commit boundary can make the turn eligible
/// for persistence and a single LLM submission.
public struct AssistantInputTurnAssembler: Sendable {
    public struct Identity: Hashable, Sendable {
        public let connection: Int
        public let generation: Int

        public init(connection: Int, generation: Int) {
            self.connection = connection
            self.generation = generation
        }
    }

    public enum CloseReason: String, Equatable, Sendable {
        case vad
        case clientCommit = "client_commit"
        case budgetRollover = "budget_rollover"
    }

    public enum Terminal: Equatable, Sendable {
        case completed(String)
        case failed
    }

    public struct InputTurn: Sendable, Equatable {
        public let identity: Identity
        public let boundaryItemID: String
        public let itemIDs: [String]
        public let transcript: String
        public let recoveryText: String
        public let isFormal: Bool
        public let sampleSpan: RealtimeASRClient.RealtimeSampleSpan?
        public let closeReason: CloseReason?
        public let commitEventID: String?
    }

    private struct Boundary: Sendable {
        var sampleSpan: RealtimeASRClient.RealtimeSampleSpan
        var reason: CloseReason
        var commitEventID: String?
    }

    private struct Segment: Sendable {
        var previewText = ""
        var snapshotRevision = 0
        var boundary: Boundary?
        var terminal: Terminal?
    }

    private static let maximumPendingSegments = 128
    private static let maximumRememberedEventIDs = 512

    private var identity: Identity?
    private var segments: [String: Segment] = [:]
    private var eventIDOrder: [String] = []
    private var eventIDs: Set<String> = []

    public init() {}

    public var pendingSegmentCount: Int { segments.count }

    public mutating func begin(identity: Identity) {
        self.identity = identity
        segments.removeAll(keepingCapacity: true)
        eventIDOrder.removeAll(keepingCapacity: true)
        eventIDs.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func acceptDelta(
        identity: Identity,
        itemID: String,
        delta: String,
        eventID: String?
    ) -> Bool {
        guard accepts(identity), !itemID.isEmpty, !delta.isEmpty,
              acceptEventID(eventID)
        else {
            return false
        }
        guard var segment = segmentForUpdate(itemID) else { return false }
        guard segment.terminal == nil else { return false }
        segment.previewText = String((segment.previewText + delta).suffix(4_096))
        segments[itemID] = segment
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
              acceptEventID(eventID)
        else {
            return false
        }
        guard var segment = segmentForUpdate(itemID),
              segment.terminal == nil,
              revision > segment.snapshotRevision
        else {
            return false
        }
        segment.snapshotRevision = revision
        segment.previewText = String(text.suffix(4_096))
        segments[itemID] = segment
        return true
    }

    @discardableResult
    public mutating func closeSegment(
        identity: Identity,
        itemID: String,
        sampleSpan: RealtimeASRClient.RealtimeSampleSpan,
        reason: CloseReason,
        commitEventID: String?,
        eventID: String?
    ) -> Bool {
        guard accepts(identity), !itemID.isEmpty,
              sampleSpan.startSample >= 0,
              sampleSpan.endSample > sampleSpan.startSample,
              acceptEventID(eventID)
        else {
            return false
        }
        guard var segment = segmentForUpdate(itemID),
              segment.boundary == nil,
              segment.terminal == nil
        else {
            return false
        }
        segment.boundary = Boundary(
            sampleSpan: sampleSpan,
            reason: reason,
            commitEventID: commitEventID
        )
        segments[itemID] = segment
        return true
    }

    /// Returns any business turns made ready by this item terminal.
    public mutating func resolveTerminal(
        identity: Identity,
        itemID: String,
        terminal: Terminal,
        eventID: String?
    ) -> [InputTurn] {
        guard accepts(identity), !itemID.isEmpty,
              acceptEventID(eventID),
              var segment = segmentForUpdate(itemID),
              segment.terminal == nil
        else {
            return []
        }
        segment.terminal = terminal
        guard segment.boundary != nil else {
            segments.removeValue(forKey: itemID)
            let finalText: String
            if case .completed(let text) = terminal {
                finalText = Self.trimmed(text)
            } else {
                finalText = ""
            }
            let recoveryText = finalText.isEmpty
                ? Self.trimmed(segment.previewText)
                : finalText
            return [
                InputTurn(
                    identity: identity,
                    boundaryItemID: itemID,
                    itemIDs: [itemID],
                    transcript: finalText,
                    recoveryText: recoveryText,
                    isFormal: false,
                    sampleSpan: nil,
                    closeReason: nil,
                    commitEventID: nil
                )
            ]
        }
        segments[itemID] = segment
        return takeReadyTurns(identity: identity)
    }

    private func accepts(_ candidate: Identity) -> Bool {
        identity == candidate
    }

    private mutating func segmentForUpdate(_ itemID: String) -> Segment? {
        if let segment = segments[itemID] { return segment }
        guard segments.count < Self.maximumPendingSegments else { return nil }
        let segment = Segment()
        segments[itemID] = segment
        return segment
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

    private mutating func takeReadyTurns(identity: Identity) -> [InputTurn] {
        var result: [InputTurn] = []

        while let boundaryItemID = segments.keys
            .filter({ itemID in
                guard let boundary = segments[itemID]?.boundary else { return false }
                return boundary.reason != .budgetRollover
            })
            .min(by: { lhs, rhs in
                (segments[lhs]?.boundary?.sampleSpan.endSample ?? .max)
                    < (segments[rhs]?.boundary?.sampleSpan.endSample ?? .max)
            }),
              let boundary = segments[boundaryItemID]?.boundary {
            let throughBoundary = segments.compactMap { itemID, segment -> (String, Segment)? in
                guard let itemBoundary = segment.boundary,
                      itemBoundary.sampleSpan.endSample <= boundary.sampleSpan.endSample
                else {
                    return nil
                }
                return (itemID, segment)
            }.sorted {
                let left = $0.1.boundary?.sampleSpan.startSample ?? .max
                let right = $1.1.boundary?.sampleSpan.startSample ?? .max
                return left == right ? $0.0 < $1.0 : left < right
            }

            guard throughBoundary.contains(where: { $0.0 == boundaryItemID }),
                  throughBoundary.allSatisfy({ $0.1.terminal != nil })
            else {
                break
            }

            let itemIDs = throughBoundary.map(\.0)
            let finalTexts = throughBoundary.compactMap { _, segment -> String? in
                guard case .completed(let text) = segment.terminal else { return nil }
                return Self.trimmed(text)
            }
            let transcript = Self.join(finalTexts)
            let hasFailure = throughBoundary.contains { _, segment in
                if case .failed = segment.terminal { return true }
                return false
            }
            let hasUnconfirmedPreview = throughBoundary.contains { _, segment in
                guard case .completed(let text) = segment.terminal else { return false }
                return Self.trimmed(text).isEmpty && !Self.trimmed(segment.previewText).isEmpty
            }
            let recoveryTexts = throughBoundary.map { _, segment -> String in
                if case .completed(let text) = segment.terminal, !Self.trimmed(text).isEmpty {
                    return Self.trimmed(text)
                }
                return Self.trimmed(segment.previewText)
            }.filter { !$0.isEmpty }
            let recoveryText = Self.join(recoveryTexts)
            let firstSample = throughBoundary.first?.1.boundary?.sampleSpan.startSample
                ?? boundary.sampleSpan.startSample
            let combinedSpan = RealtimeASRClient.RealtimeSampleSpan(
                startSample: firstSample,
                endSample: boundary.sampleSpan.endSample
            )

            result.append(
                InputTurn(
                    identity: identity,
                    boundaryItemID: boundaryItemID,
                    itemIDs: itemIDs,
                    transcript: transcript,
                    recoveryText: recoveryText,
                    isFormal: !hasFailure && !hasUnconfirmedPreview && !transcript.isEmpty,
                    sampleSpan: combinedSpan,
                    closeReason: boundary.reason,
                    commitEventID: boundary.commitEventID
                )
            )
            for itemID in itemIDs {
                segments.removeValue(forKey: itemID)
            }
        }

        return result
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins English/digit boundaries with one space and leaves CJK boundaries
    /// untouched, so budget splitting does not damage either writing system.
    private static func join(_ pieces: [String]) -> String {
        var output = ""
        for piece in pieces where !piece.isEmpty {
            guard !output.isEmpty else {
                output = piece
                continue
            }
            let needsSpace = output.unicodeScalars.last.map(isASCIIWordScalar) == true
                && piece.unicodeScalars.first.map(isASCIIWordScalar) == true
            if needsSpace { output.append(" ") }
            output.append(piece)
        }
        return output
    }

    private static func isASCIIWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }
}
