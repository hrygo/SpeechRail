import Foundation

public struct TeleprompterAligner: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var minimumConfidence: Double
        public var advanceMargin: Double
        public var lookahead: Int

        public init(
            minimumConfidence: Double = 0.72,
            advanceMargin: Double = 0.12,
            lookahead: Int = 2
        ) {
            self.minimumConfidence = minimumConfidence
            self.advanceMargin = advanceMargin
            self.lookahead = max(1, lookahead)
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
        public let confidence: Double
        public let matchedCount: Int
    }

    public struct Script: Sendable {
        struct Token: Sendable {
            let value: String
            let position: Position
        }
        let tokens: [Token]
        public init(segments: [TeleprompterSegment]) {
            tokens = segments.enumerated().flatMap { index, segment in
                TeleprompterNormalizer.indexedTokens(segment.text).map {
                    Token(value: $0.value, position: .init(segmentIndex: index, utf16Offset: $0.range.end))
                }
            }
        }
    }

    public func locate(transcript: String, segments: [TeleprompterSegment], anchor: Position) -> Match {
        locate(tokens: TeleprompterNormalizer.tokens(transcript), script: Script(segments: segments), anchor: anchor)
    }

    /// Semi-global edit distance: free start in a bounded script window, but every
    /// observed token pays for an insertion/substitution. No AI annotations required.
    public func locate(tokens input: [String], script: Script, anchor: Position) -> Match {
        let input = Array(input.suffix(72))
        let none = Match(position: nil, confidence: 0, matchedCount: 0)
        guard input.count >= 3, !script.tokens.isEmpty else { return none }
        let anchorIndex = script.tokens.firstIndex {
            $0.position.segmentIndex > anchor.segmentIndex ||
            ($0.position.segmentIndex == anchor.segmentIndex && $0.position.utf16Offset >= anchor.utf16Offset)
        } ?? script.tokens.count - 1
        let lower = max(0, anchorIndex - 80)
        let upper = min(script.tokens.count, anchorIndex + 320)
        let window = Array(script.tokens[lower..<upper])
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
                row.append([diagonal, inserted, deleted].min {
                    $0.cost == $1.cost ? $0.matches > $1.matches : $0.cost < $1.cost
                }!)
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
            // Trailing skipped script tokens never count as spoken progress.
            guard equivalent(input.last!, window[end - 1].value) else { return nil }
            let cell = previous[end]
            guard cell.matches >= min(4, input.count) else { return nil }
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
        if let competitor, best.confidence - competitor.confidence < configuration.advanceMargin {
            return Match(position: nil, confidence: best.confidence, matchedCount: best.matches)
        }
        return Match(position: window[best.end - 1].position, confidence: best.confidence, matchedCount: best.matches)
    }

    private func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        let digits = ["零": "0", "〇": "0", "一": "1", "二": "2", "三": "3", "四": "4",
                      "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"]
        return (digits[lhs] ?? lhs) == (digits[rhs] ?? rhs)
    }
}
