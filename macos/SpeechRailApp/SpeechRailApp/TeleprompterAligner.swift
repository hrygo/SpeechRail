import Foundation

public struct TeleprompterAligner: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var minimumConfidence: Double
        public var advanceMargin: Double
        public var lookBehindTokens: Int
        public var lookAheadTokens: Int

        public init(
            minimumConfidence: Double = 0.72,
            advanceMargin: Double = 0.12,
            lookBehindTokens: Int = 80,
            lookAheadTokens: Int = 320
        ) {
            self.minimumConfidence = minimumConfidence
            self.advanceMargin = advanceMargin
            self.lookBehindTokens = max(0, min(320, lookBehindTokens))
            self.lookAheadTokens = max(1, min(640, lookAheadTokens))
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// End-exclusive UTF-16 position in the displayed (possibly user-edited) segment.
    public struct Position: Equatable, Sendable {
        public var segmentIndex: Int
        public var utf16Offset: Int
        public init(segmentIndex: Int, utf16Offset: Int) {
            self.segmentIndex = segmentIndex
            self.utf16Offset = utf16Offset
        }
    }

    public struct Match: Sendable {
        public let position: Position?
        public let startPosition: Position?
        public let confidence: Double
        public let matchedCount: Int
        public let isUniqueExactContinuation: Bool
        public let isUniqueNearAnchor: Bool

        public init(
            position: Position?,
            startPosition: Position? = nil,
            confidence: Double,
            matchedCount: Int,
            isUniqueExactContinuation: Bool = false,
            isUniqueNearAnchor: Bool = false
        ) {
            self.position = position
            self.startPosition = startPosition
            self.confidence = confidence
            self.matchedCount = matchedCount
            self.isUniqueExactContinuation = isUniqueExactContinuation
            self.isUniqueNearAnchor = isUniqueNearAnchor
        }
    }

    public struct Script: Sendable {
        struct Token: Sendable {
            let value: String
            let start: Position
            let end: Position

            var position: Position { end }
        }
        let tokens: [Token]
        public init(segments: [TeleprompterSegment]) {
            tokens = segments.enumerated().flatMap { index, segment in
                TeleprompterCanonicalizer.units(segment.text).map {
                    Token(
                        value: $0.value,
                        start: .init(segmentIndex: index, utf16Offset: $0.range.start),
                        end: .init(segmentIndex: index, utf16Offset: $0.range.end)
                    )
                }
            }
        }
    }

    public func locate(transcript: String, segments: [TeleprompterSegment], anchor: Position) -> Match {
        locate(tokens: TeleprompterCanonicalizer.values(transcript), script: Script(segments: segments), anchor: anchor)
    }

    /// Semi-global edit distance: free start in a bounded script window, but every
    /// observed token pays for an insertion/substitution. No AI annotations required.
    public func locate(tokens input: [String], script: Script, anchor: Position) -> Match {
        let input = Array(input.suffix(72))
        let none = Match(position: nil, confidence: 0, matchedCount: 0)
        guard !input.isEmpty, !script.tokens.isEmpty else { return none }
        let anchorIndex = script.tokens.firstIndex {
            $0.position.segmentIndex > anchor.segmentIndex ||
            ($0.position.segmentIndex == anchor.segmentIndex && $0.position.utf16Offset >= anchor.utf16Offset)
        } ?? script.tokens.count - 1
        let lower = max(0, anchorIndex - configuration.lookBehindTokens)
        let upper = min(script.tokens.count, anchorIndex + configuration.lookAheadTokens)
        let window = Array(script.tokens[lower..<upper])
        guard !window.isEmpty else { return none }
        let minimumMatches = max(1, min(3, input.count - 1))
        struct Cell {
            var cost: Double
            var matches: Int
            var start: Int
        }
        var previous = (0...window.count).map { Cell(cost: 0, matches: 0, start: $0) }
        for (i, token) in input.enumerated() {
            var row = [Cell(cost: Double(i + 1), matches: 0, start: 0)]
            for j in 1...window.count {
                let equal = equivalent(token, window[j - 1].value)
                let diagonal = Cell(cost: previous[j - 1].cost + (equal ? 0 : 1),
                                    matches: previous[j - 1].matches + (equal ? 1 : 0),
                                    start: previous[j - 1].start)
                let inserted = Cell(cost: previous[j].cost + 1, matches: previous[j].matches, start: previous[j].start)
                let deleted = Cell(cost: row[j - 1].cost + 1, matches: row[j - 1].matches, start: row[j - 1].start)
                var best = diagonal
                if inserted.cost < best.cost || (inserted.cost == best.cost && inserted.matches > best.matches) { best = inserted }
                if deleted.cost < best.cost || (deleted.cost == best.cost && deleted.matches > best.matches) { best = deleted }
                row.append(best)
            }
            previous = row
        }
        struct Candidate {
            let end: Int
            let start: Int
            let confidence: Double
            let matches: Int
        }
        let candidates = (1...window.count).compactMap { end -> Candidate? in
            let cell = previous[end]
            guard cell.matches >= minimumMatches else { return nil }
            return Candidate(end: end, start: cell.start,
                             confidence: max(0, 1 - cell.cost / Double(input.count)), matches: cell.matches)
        }.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return abs(lower + $0.end - anchorIndex) < abs(lower + $1.end - anchorIndex)
        }
        guard let best = candidates.first, best.confidence >= configuration.minimumConfidence else { return none }
        // Nearby endings on the same alignment path are not competing locations.
        let competitor = candidates.first {
            abs($0.start - best.start) >= max(3, input.count / 2)
                && abs($0.end - best.end) >= max(3, input.count / 2)
        }
        // A long unique exact span crossing the existing anchor is continuity
        // evidence, even in numbered lists whose neighbouring sentences differ
        // by only one token. Equal exact copies remain ambiguous.
        let continuesAnchor = lower + best.start <= anchorIndex + 4
            && lower + best.end >= anchorIndex
        let startsNearAnchor = abs((lower + best.start) - anchorIndex) <= 4
        let uniqueExactContinuation = best.confidence == 1 && best.matches >= 8 && continuesAnchor
            && (competitor?.confidence ?? 0) < 1
        let uniqueNearAnchor = startsNearAnchor
            && (competitor == nil || best.confidence - competitor!.confidence >= configuration.advanceMargin)
        if let competitor, best.confidence - competitor.confidence < configuration.advanceMargin,
           !uniqueExactContinuation {
            return Match(
                position: nil,
                startPosition: window[best.start].start,
                confidence: best.confidence,
                matchedCount: best.matches
            )
        }
        return Match(
            position: window[best.end - 1].position,
            startPosition: window[best.start].start,
            confidence: best.confidence,
            matchedCount: best.matches,
            isUniqueExactContinuation: uniqueExactContinuation,
            isUniqueNearAnchor: uniqueNearAnchor
        )
    }

    private static let digits = ["零": "0", "〇": "0", "一": "1", "二": "2", "三": "3", "四": "4",
                      "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]
    private func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        (Self.digits[lhs] ?? lhs) == (Self.digits[rhs] ?? rhs)
    }
}
