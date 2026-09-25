import Foundation
import SpeechRailControlKit

/// Bounded, in-memory latency evidence for one teleprompter run.
///
/// It deliberately stores only timings and counts: no item IDs, transcript text,
/// audio, or text-derived identifiers are retained.
public struct TeleprompterLatencyDiagnostics: Sendable, Equatable {
    public private(set) var alignmentSampleCount = 0
    public private(set) var captureSampleCount = 0

    private let maxSamples: Int
    private var queueAgeSamples: [Double] = []
    private var matchSamples: [Double] = []
    private var captureToSendSamples: [Double] = []

    public init(maxSamples: Int = 128) {
        self.maxSamples = max(1, maxSamples)
    }

    public var queueAgeP95Milliseconds: Double? {
        percentile(queueAgeSamples)
    }

    public var matchP95Milliseconds: Double? {
        percentile(matchSamples)
    }

    public var captureToSendP95Milliseconds: Double? {
        percentile(captureToSendSamples)
    }

    public mutating func recordAlignment(
        queueAgeMilliseconds: Double,
        matchMilliseconds: Double
    ) {
        guard valid(queueAgeMilliseconds), valid(matchMilliseconds) else { return }
        append(queueAgeMilliseconds, to: &queueAgeSamples)
        append(matchMilliseconds, to: &matchSamples)
        alignmentSampleCount = queueAgeSamples.count
    }

    public mutating func recordCaptureToSend(milliseconds: Double) {
        guard valid(milliseconds) else { return }
        append(milliseconds, to: &captureToSendSamples)
        captureSampleCount = captureToSendSamples.count
    }

    private func valid(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    private func append(_ value: Double, to samples: inout [Double]) {
        samples.append(value)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    private func percentile(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1))
        return sorted[index]
    }
}

public enum TeleprompterFollowState: Equatable, Sendable {
    case waitingForSpeech
    case listening
    case tracking
    case catchingUp
    case freePlaying
    case paused
    case manual
}

public enum TeleprompterFollowPresentation {
    public static func statusText(for state: TeleprompterFollowState) -> String {
        switch state {
        case .waitingForSpeech: "等待声音请开讲…"
        case .listening: "听见你了，正在跟上稿件…"
        case .tracking: "跟读咬合"
        case .catchingUp: "正在跟上稿件"
        case .freePlaying: "自由发挥中"
        case .paused: "已暂停"
        case .manual: "手动浏览中"
        }
    }
}

/// Injectable evidence thresholds for provisional movement and recovery.
public struct TeleprompterFollowPolicy: Equatable, Sendable {
    public let provisionalMinimumConfidence: Double
    public let provisionalMinimumMatches: Int
    public let freePlayAfterMisses: Int
    public let reanchorMargin: Double

    public init(
        provisionalMinimumConfidence: Double = 0.72,
        provisionalMinimumMatches: Int = 2,
        freePlayAfterMisses: Int = 2,
        reanchorMargin: Double = 0.12
    ) {
        self.provisionalMinimumConfidence = provisionalMinimumConfidence.isFinite
            ? min(1, max(0, provisionalMinimumConfidence)) : 0.72
        self.provisionalMinimumMatches = max(1, provisionalMinimumMatches)
        self.freePlayAfterMisses = max(1, freePlayAfterMisses)
        self.reanchorMargin = reanchorMargin.isFinite ? min(1, max(0, reanchorMargin)) : 0.12
    }
}

/// Pure event reducer. ASR text is bounded, in-memory only, and scoped to item IDs.
public struct TeleprompterFollowController: Sendable {
    public private(set) var position: TeleprompterAligner.Position
    public var currentIndex: Int { position.segmentIndex }
    public private(set) var candidatePosition: TeleprompterAligner.Position?
    public private(set) var mode: TeleprompterRunMode
    public private(set) var uncertainty: Double?
    public private(set) var partialPreview: String?
    public private(set) var followState: TeleprompterFollowState
    public private(set) var lastMatchConfidence: Double?
    public private(set) var lastMatchedCount = 0

    private struct Item: Sendable {
        var text: String
        let anchor: TeleprompterAligner.Position
        let sequence: Int
        var snapshotRevision = 0
    }
    private var items: [String: Item] = [:]
    private var retired: [String] = []
    private var eventIDs: [String] = []
    private var history: [String] = []
    private var script: TeleprompterAligner.Script?
    private var scriptSegments: [TeleprompterSegment] = []
    private let policy: TeleprompterFollowPolicy
    private let aligner: TeleprompterAligner
    private var lastConfirmedPosition: TeleprompterAligner.Position
    private var lowConfidenceStreak = 0
    private var nextSequence = 0
    private var finalizedSequence = -1
    private var provisionalItemID: String?

    public init(
        currentIndex: Int = 0,
        mode: TeleprompterRunMode = .following,
        policy: TeleprompterFollowPolicy = .init()
    ) {
        let initialPosition = TeleprompterAligner.Position(segmentIndex: max(0, currentIndex), utf16Offset: 0)
        position = initialPosition
        lastConfirmedPosition = initialPosition
        self.mode = mode
        self.policy = policy
        aligner = TeleprompterAligner(configuration: .init(advanceMargin: policy.reanchorMargin))
        switch mode {
        case .following: followState = .waitingForSpeech
        case .paused: followState = .paused
        case .manual: followState = .manual
        }
    }

    public mutating func noteSpeechStarted() {
        guard mode == .following, followState == .waitingForSpeech else { return }
        followState = .listening
    }

    public mutating func receivePartial(
        itemID: String,
        delta: String,
        segments: [TeleprompterSegment],
        eventID: String? = nil
    ) {
        guard acceptEvent(eventID) else { return }
        guard !itemID.isEmpty, !retired.contains(itemID) else { return }
        guard mode == .following else { retire(itemID); return }
        prepare(segments)
        guard let script else { return }
        var item = item(for: itemID)
        guard item.sequence > finalizedSequence else { retire(itemID); return }
        item.text = String((item.text + delta).suffix(2048))
        partialPreview = item.text
        if followState == .waitingForSpeech { followState = .listening }
        let match = locate(TeleprompterCanonicalizer.values(item.text), script: script, anchor: position)
        applyPreviewMatch(match, itemID: itemID)
        items[itemID] = item
        if items.count > 8, let oldest = items.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            retire(oldest)
        }
    }

    public mutating func receiveSnapshot(
        itemID: String,
        revision: Int,
        text: String,
        segments: [TeleprompterSegment],
        eventID: String? = nil
    ) {
        guard acceptEvent(eventID) else { return }
        guard revision > 0, !itemID.isEmpty, !retired.contains(itemID) else { return }
        guard mode == .following else { retire(itemID); return }
        prepare(segments)
        guard let script else { return }
        var item = item(for: itemID)
        guard item.sequence > finalizedSequence, revision > item.snapshotRevision else { return }
        item.snapshotRevision = revision
        item.text = String(text.suffix(2048))
        partialPreview = item.text
        if followState == .waitingForSpeech { followState = .listening }
        let match = locate(TeleprompterCanonicalizer.values(item.text), script: script, anchor: position)
        applyPreviewMatch(match, itemID: itemID)
        items[itemID] = item
        if items.count > 8, let oldest = items.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            retire(oldest)
        }
    }

    public mutating func receiveCompleted(
        itemID: String,
        transcript: String,
        segments: [TeleprompterSegment],
        eventID: String? = nil
    ) {
        guard acceptEvent(eventID) else { return }
        guard !itemID.isEmpty, !retired.contains(itemID) else { return }
        guard mode == .following else { retire(itemID); return }
        prepare(segments)
        guard let script else { return }
        let item = item(for: itemID)
        guard item.sequence > finalizedSequence else { retire(itemID); return }
        finalizedSequence = item.sequence
        let anchor = item.anchor
        let tokens = TeleprompterCanonicalizer.values(transcript)
        partialPreview = nil
        if followState == .waitingForSpeech { followState = .listening }

        guard !tokens.isEmpty else {
            if provisionalItemID != nil { position = lastConfirmedPosition }
            provisionalItemID = nil
            candidatePosition = nil
            retire(itemID)
            return
        }

        var match = locate(tokens, script: script, anchor: position)
        if match.position == nil, anchor != position {
            let anchoredMatch = locate(tokens, script: script, anchor: anchor)
            if anchoredMatch.position != nil { match = anchoredMatch }
        }
        candidatePosition = match.position
        lastMatchConfidence = match.confidence
        lastMatchedCount = match.matchedCount

        if let candidate = match.position {
            position = candidate
            lastConfirmedPosition = candidate
            provisionalItemID = nil
            uncertainty = nil
            lowConfidenceStreak = 0
            followState = .tracking
            history = Array((history + tokens).suffix(48))
        } else if tokens.count + history.count < 3 {
            history = Array((history + tokens).suffix(24))
            position = lastConfirmedPosition
            provisionalItemID = nil
            candidatePosition = nil
            uncertainty = nil
            if followState != .freePlaying { followState = .listening }
        } else {
            recordFinalMiss(match)
        }
        retire(itemID)
    }

    private func locate(
        _ tokens: [String],
        script: TeleprompterAligner.Script,
        anchor: TeleprompterAligner.Position
    ) -> TeleprompterAligner.Match {
        let current = aligner.locate(tokens: tokens, script: script, anchor: anchor)
        if current.position != nil { return current }
        guard !history.isEmpty, tokens.count < 3 || current.confidence > 0 else { return current }
        return aligner.locate(tokens: Array(history.suffix(24)) + tokens, script: script, anchor: anchor)
    }

    private mutating func applyPreviewMatch(
        _ match: TeleprompterAligner.Match,
        itemID: String
    ) {
        candidatePosition = match.position
        lastMatchConfidence = match.confidence
        lastMatchedCount = match.matchedCount

        guard let candidate = match.position else {
            uncertainty = match.confidence
            if followState != .freePlaying { followState = .catchingUp }
            return
        }

        let sufficientEvidence = match.isUniqueNearAnchor
            || (match.confidence >= policy.provisionalMinimumConfidence
                && match.matchedCount >= policy.provisionalMinimumMatches)
        guard sufficientEvidence else {
            uncertainty = match.confidence
            if followState != .freePlaying { followState = .catchingUp }
            return
        }

        uncertainty = nil
        if isForward(candidate, from: position) {
            position = candidate
            provisionalItemID = itemID
            if followState != .freePlaying { followState = .tracking }
        } else if candidate == position {
            if followState != .freePlaying { followState = .tracking }
        } else if followState != .freePlaying {
            followState = .catchingUp
        }
    }

    private mutating func recordFinalMiss(_ match: TeleprompterAligner.Match) {
        position = lastConfirmedPosition
        provisionalItemID = nil
        candidatePosition = nil
        history = []
        uncertainty = match.confidence
        lowConfidenceStreak += 1
        followState = lowConfidenceStreak >= policy.freePlayAfterMisses ? .freePlaying : .catchingUp
    }

    private func isForward(
        _ candidate: TeleprompterAligner.Position,
        from current: TeleprompterAligner.Position
    ) -> Bool {
        candidate.segmentIndex > current.segmentIndex
            || (candidate.segmentIndex == current.segmentIndex
                && candidate.utf16Offset > current.utf16Offset)
    }

    private mutating func item(for id: String) -> Item {
        if let item = items[id] { return item }
        let item = Item(text: "", anchor: position, sequence: nextSequence)
        nextSequence += 1
        return item
    }

    private mutating func prepare(_ segments: [TeleprompterSegment]) {
        guard script == nil || scriptSegments != segments else { return }
        scriptSegments = segments
        script = .init(segments: segments)
        history = []
    }

    private mutating func retire(_ id: String) {
        items.removeValue(forKey: id)
        if !retired.contains(id) { retired.append(id) }
        if retired.count > 128 { retired.removeFirst(retired.count - 128) }
    }

    private mutating func acceptEvent(_ id: String?) -> Bool {
        guard let id else { return true }
        guard !eventIDs.contains(id) else { return false }
        eventIDs.append(id)
        if eventIDs.count > 128 { eventIDs.removeFirst(eventIDs.count - 128) }
        return true
    }

    private mutating func invalidatePending() {
        for id in Array(items.keys) { retire(id) }
        history = []
        partialPreview = nil
        candidatePosition = nil
        provisionalItemID = nil
        uncertainty = nil
        lastConfirmedPosition = position
        lastMatchConfidence = nil
        lastMatchedCount = 0
        lowConfidenceStreak = 0
    }

    public mutating func pause() {
        invalidatePending()
        mode = .paused
        followState = .paused
    }

    public mutating func resume() {
        invalidatePending()
        mode = .following
        followState = .waitingForSpeech
    }

    public mutating func move(to index: Int, segmentCount: Int) {
        guard segmentCount > 0 else { return }
        invalidatePending()
        position = .init(segmentIndex: min(max(0, index), segmentCount - 1), utf16Offset: 0)
        lastConfirmedPosition = position
        mode = .manual
        followState = .manual
    }

    /// Manual movement requested by a reader. Moving within the same paragraph
    /// is a takeover, not a jump to its beginning; the current reading offset
    /// must survive boundary commands such as previous-at-first-segment.
    public mutating func manualMove(to index: Int, segmentCount: Int) {
        guard segmentCount > 0 else { return }
        let target = min(max(0, index), segmentCount - 1)
        if target == position.segmentIndex {
            enterManual()
            return
        }
        move(to: target, segmentCount: segmentCount)
    }

    /// Moves to an exact source offset chosen by the reader. Offsets are UTF-16
    /// based to match `TeleprompterAligner.Position` and are clamped to the
    /// corresponding displayed segment.
    public mutating func manualMove(
        to target: TeleprompterAligner.Position,
        segmentCount: Int,
        segmentUTF16Lengths: [Int]
    ) {
        guard segmentCount > 0, segmentUTF16Lengths.count >= segmentCount else { return }
        let index = min(max(target.segmentIndex, 0), segmentCount - 1)
        let offset = min(max(target.utf16Offset, 0), max(0, segmentUTF16Lengths[index]))
        let clamped = TeleprompterAligner.Position(segmentIndex: index, utf16Offset: offset)

        if clamped == position {
            enterManual()
            return
        }

        invalidatePending()
        position = clamped
        lastConfirmedPosition = clamped
        mode = .manual
        followState = .manual
    }

    public mutating func enterManual() {
        invalidatePending()
        mode = .manual
        followState = .manual
    }

    public mutating func resetFollowWindow() { resume() }
}


public enum TeleprompterRealtimeFollowOutcome: Equatable, Sendable {
    case aligned
    case previewed
    case ignored
    case terminalFailure
}

/// Maps Realtime ASR events into the same deterministic follow reducer used by tests.
/// Event IDs are bounded and retained only in memory for duplicate suppression.
public struct TeleprompterRealtimeFollowAdapter: Sendable {
    public init() {}

    public func apply(
        _ event: RealtimeASRClient.Event,
        metadata: RealtimeEventMetadata,
        segments: [TeleprompterSegment],
        to controller: inout TeleprompterFollowController
    ) -> TeleprompterRealtimeFollowOutcome {
        switch event {
        case .partial(let itemID, let delta):
            // 当前 wire 没有 `speech_started`：第一次收到识别结果就是"开始说话了"。
            controller.noteSpeechStarted()
            let previousPosition = controller.position
            let previousPreview = controller.partialPreview
            controller.receivePartial(
                itemID: itemID,
                delta: delta,
                segments: segments,
                eventID: metadata.eventID
            )
            return controller.position != previousPosition || controller.partialPreview != previousPreview
                ? .previewed : .ignored

        case .partialSnapshot(let itemID, let revision, let text):
            controller.noteSpeechStarted()
            let previousPosition = controller.position
            let previousPreview = controller.partialPreview
            controller.receiveSnapshot(
                itemID: itemID,
                revision: revision,
                text: text,
                segments: segments,
                eventID: metadata.eventID
            )
            return controller.position != previousPosition || controller.partialPreview != previousPreview
                ? .previewed : .ignored

        case .completed(let itemID, let transcript):
            let previousPosition = controller.position
            let previousState = controller.followState
            let previousConfidence = controller.lastMatchConfidence
            let previousMatchedCount = controller.lastMatchedCount
            controller.receiveCompleted(
                itemID: itemID,
                transcript: transcript,
                segments: segments,
                eventID: metadata.eventID
            )
            let didAlign = controller.position != previousPosition
                || (controller.followState == .tracking
                    && (previousState != .tracking
                        || controller.lastMatchConfidence != previousConfidence
                        || controller.lastMatchedCount != previousMatchedCount))
            return didAlign ? .aligned : .ignored

        case .failed(_, _, _), .closed(_):
            return .terminalFailure

        default:
            return .ignored
        }
    }

}
