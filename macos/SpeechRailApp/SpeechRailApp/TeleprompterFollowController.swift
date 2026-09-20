import Foundation

/// Pure event reducer. ASR text is bounded, in-memory only, and scoped to item IDs.
public struct TeleprompterFollowController: Sendable {
    public private(set) var position: TeleprompterAligner.Position
    public var currentIndex: Int { position.segmentIndex }
    public private(set) var candidatePosition: TeleprompterAligner.Position?
    public private(set) var mode: TeleprompterRunMode
    public private(set) var uncertainty: Double?
    public private(set) var partialPreview: String?

    private struct Item: Sendable {
        var text: String
        let anchor: TeleprompterAligner.Position
        let sequence: Int
        var previousEvidence = 0
    }
    private var items: [String: Item] = [:]
    private var retired: [String] = []
    private var eventIDs: [String] = []
    private var history: [String] = []
    private var script: TeleprompterAligner.Script?
    private var scriptSegments: [TeleprompterSegment] = []
    private let aligner = TeleprompterAligner()
    private var nextSequence = 0
    private var finalizedSequence = -1
    private var provisionalItemID: String?

    public init(currentIndex: Int = 0, mode: TeleprompterRunMode = .following) {
        position = .init(segmentIndex: max(0, currentIndex), utf16Offset: 0)
        self.mode = mode
    }

    public mutating func receivePartial(itemID: String, delta: String, segments: [TeleprompterSegment], eventID: String? = nil) {
        guard acceptEvent(eventID) else { return }
        guard !itemID.isEmpty, !retired.contains(itemID) else { return }
        guard mode == .following else { retire(itemID); return }
        prepare(segments)
        guard let script else { return }
        var item = item(for: itemID)
        guard item.sequence > finalizedSequence else { retire(itemID); return }
        item.text = String((item.text + delta).suffix(2048))
        partialPreview = item.text
        let tokens = TeleprompterNormalizer.tokens(item.text)
        let match = locate(tokens, script: script, anchor: position)
        candidatePosition = match.position
        // Two genuinely growing hypotheses are required before provisional scrolling.
        if let candidate = match.position, match.confidence >= 0.88,
           match.matchedCount >= 5, item.previousEvidence >= 3,
           !TeleprompterNormalizer.tokens(delta).isEmpty,
           candidate.segmentIndex >= position.segmentIndex {
            position = candidate
            provisionalItemID = itemID
            uncertainty = nil
        }
        item.previousEvidence = match.position == nil ? 0 : match.matchedCount
        items[itemID] = item
        if items.count > 8, let oldest = items.min(by: { $0.value.sequence < $1.value.sequence })?.key { retire(oldest) }
    }

    public mutating func receiveCompleted(itemID: String, transcript: String, segments: [TeleprompterSegment], eventID: String? = nil) {
        guard acceptEvent(eventID) else { return }
        guard !itemID.isEmpty, !retired.contains(itemID) else { return }
        guard mode == .following else { retire(itemID); return }
        prepare(segments)
        guard let script else { return }
        let item = item(for: itemID)
        guard item.sequence > finalizedSequence else { retire(itemID); return }
        finalizedSequence = item.sequence
        let anchor = item.anchor
        let tokens = TeleprompterNormalizer.tokens(transcript)
        if tokens.count + history.count < 3 {
            history += tokens
            partialPreview = nil
            if provisionalItemID == itemID { position = anchor; provisionalItemID = nil }
            retire(itemID)
            return
        }
        if !tokens.isEmpty {
            var match = locate(tokens, script: script, anchor: position)
            if match.position == nil, anchor != position {
                match = locate(tokens, script: script, anchor: anchor)
            }
            candidatePosition = match.position
            if let candidate = match.position {
                position = candidate
                uncertainty = nil
                history = Array((history + tokens).suffix(48))
            } else {
                if provisionalItemID == itemID { position = anchor }
                // Do not carry an off-script answer into the next return-to-script attempt.
                history = []
                uncertainty = match.confidence
            }
        } else if provisionalItemID == itemID {
            position = anchor
        }
        if provisionalItemID == itemID { provisionalItemID = nil }
        partialPreview = nil
        retire(itemID)
    }

    private func locate(_ tokens: [String], script: TeleprompterAligner.Script,
                        anchor: TeleprompterAligner.Position) -> TeleprompterAligner.Match {
        // Try the current utterance first so a detour/repeat cannot be pinned by old text.
        let current = aligner.locate(tokens: tokens, script: script, anchor: anchor)
        if current.position != nil { return current }
        guard tokens.count < 3 || current.confidence > 0 else { return current }
        return aligner.locate(tokens: Array(history.suffix(24)) + tokens, script: script, anchor: anchor)
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
    }

    public mutating func pause() {
        invalidatePending()
        mode = .paused
    }

    public mutating func resume() {
        invalidatePending()
        mode = .following
    }

    public mutating func move(to index: Int, segmentCount: Int) {
        guard segmentCount > 0 else { return }
        invalidatePending()
        position = .init(segmentIndex: min(max(0, index), segmentCount - 1), utf16Offset: 0)
        mode = .manual
    }

    public mutating func enterManual() {
        invalidatePending()
        mode = .manual
    }

    public mutating func resetFollowWindow() { resume() }
}
