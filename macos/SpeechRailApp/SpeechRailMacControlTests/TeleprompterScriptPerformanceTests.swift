import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct TeleprompterScriptPerformanceTests {
    @Test func testHundredTrialPreviewsPrepareScriptOnce() throws {
        let segments = try TeleprompterSegmenter.segment(sourceText: "欢迎来到今天的测试。这里是第二段中文和 English 123。")
        var cache = TeleprompterScriptCache()
        for _ in 0..<100 {
            let prepared = try cache.prepare(versionID: "version-a", segments: segments)
            _ = TeleprompterAligner().locate(tokens: TeleprompterCanonicalizer.values("这里是第二段中文"), script: prepared.script, anchor: .init(segmentIndex: 0, utf16Offset: 0))
        }
        #expect(cache.prepareCount == 1)
        let next = try cache.prepare(versionID: "version-b", segments: segments)
        #expect(cache.prepareCount == 2 && next.versionID == "version-b")
        cache.clear()
        #expect(cache.current == nil)
    }
    @Test func testMatchOperationReportsInputTokenCount() throws {
        let segments = try TeleprompterSegmenter.segment(sourceText: "欢迎来到今天的测试。这里是第二段中文。")
        let script = TeleprompterAligner.Script(segments: segments)
        let tokens = TeleprompterCanonicalizer.values("这里是第二段中文")
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        let aligner = TeleprompterAligner(metrics: metrics)

        _ = aligner.locate(tokens: tokens, script: script, anchor: .init(segmentIndex: 0, utf16Offset: 0))

        let summary = metrics.snapshot(for: .teleprompterMatch)
        #expect(summary.samples == 1 && summary.count == UInt64(tokens.count))
        #expect(summary.failed == 0 && summary.cancelled == 0)
    }
    @Test func testIndexedAnchorMatchesLinearReferenceAndComparisonsAreLogarithmic() throws {
        let segments = try TeleprompterSegmenter.segment(sourceText: String(repeating: "重复词 English 😀 二零二六。", count: 600))
        let script = TeleprompterAligner.Script(segments: segments)
        for segment in stride(from: -1, through: segments.count + 1, by: 7) {
            for offset in [-1, 0, 1, 6, 100_000] {
                let anchor = TeleprompterAligner.Position(segmentIndex: segment, utf16Offset: offset)
                let expected = script.tokens.firstIndex { token in
                    token.position.segmentIndex > segment || (token.position.segmentIndex == segment && token.position.utf16Offset >= offset)
                } ?? max(0, script.tokens.count - 1)
                let result = script.anchorSearch(anchor)
                #expect(result.index == expected)
                #expect(result.comparisons <= Int(ceil(log2(Double(max(1, script.tokens.count))))) + 1)
            }
        }
        #expect(TeleprompterAligner.Script(segments: []).anchorSearch(.init(segmentIndex: 0, utf16Offset: 0)).index == 0)
    }
    @Test func testIndexedMatchingEqualsFrozenLinearAlgorithm() throws {
        let segments = try TeleprompterSegmenter.segment(sourceText: "重复词 English 😀 二零二六。欢迎来到今天的测试。重复词 English 😀 二零二六。最后介绍导出与停止。")
        let aligner = TeleprompterAligner(), linear = LinearTeleprompterAlignerReference()
        let script = TeleprompterAligner.Script(segments: segments)
        let old = LinearTeleprompterAlignerReference.Script(segments: segments)
        for index in -1...segments.count {
            for offset in [-5, 0, 1, 6, 16, 1_000] {
                for text in ["重复词 English", "二零二六", "欢迎来到今天的测试", "最后介绍导出", "没有匹配", ""] {
                    let tokens = TeleprompterCanonicalizer.values(text)
                    let actual = aligner.locate(tokens: tokens, script: script, anchor: .init(segmentIndex: index, utf16Offset: offset))
                    let expected = linear.locate(tokens: tokens, script: old, anchor: .init(segmentIndex: index, utf16Offset: offset))
                    #expect(actual.position?.segmentIndex == expected.position?.segmentIndex)
                    #expect(actual.position?.utf16Offset == expected.position?.utf16Offset)
                    #expect(actual.startPosition?.segmentIndex == expected.startPosition?.segmentIndex)
                    #expect(actual.startPosition?.utf16Offset == expected.startPosition?.utf16Offset)
                    #expect(actual.confidence == expected.confidence && actual.matchedCount == expected.matchedCount)
                    #expect(actual.isUniqueExactContinuation == expected.isUniqueExactContinuation)
                    #expect(actual.isUniqueNearAnchor == expected.isUniqueNearAnchor)
                    #expect(actual.tokenDistanceFromAnchor == expected.tokenDistanceFromAnchor)
                }
            }
        }
    }
    @Test func testDuplicateAliasPositionsChooseFirstSatisfyingToken() throws {
        var segments = try TeleprompterSegmenter.segment(sourceText: "今天使用 API 测试定位。")
        let range = (segments[0].text as NSString).range(of: "API")
        segments[0].acceptedReadings = [.init(displayRange: .init(start: range.location, end: NSMaxRange(range)), displayText: "API", spokenText: "应用程序接口")]
        let script = TeleprompterAligner.Script(segments: segments)
        for token in script.tokens {
            let anchor = token.position
            let first = try #require(script.tokens.firstIndex { $0.position.segmentIndex > anchor.segmentIndex || ($0.position.segmentIndex == anchor.segmentIndex && $0.position.utf16Offset >= anchor.utf16Offset) })
            #expect(script.anchorSearch(anchor).index == first)
        }
    }
}

// Frozen pre-change algorithm, used only for exact deterministic comparison.

private struct LinearTeleprompterAlignerReference: Sendable {
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
        public let tokenDistanceFromAnchor: Int

        public init(
            position: Position?,
            startPosition: Position? = nil,
            confidence: Double,
            matchedCount: Int,
            isUniqueExactContinuation: Bool = false,
            isUniqueNearAnchor: Bool = false,
            tokenDistanceFromAnchor: Int = 0
        ) {
            self.position = position
            self.startPosition = startPosition
            self.confidence = confidence
            self.matchedCount = matchedCount
            self.isUniqueExactContinuation = isUniqueExactContinuation
            self.isUniqueNearAnchor = isUniqueNearAnchor
            self.tokenDistanceFromAnchor = max(0, tokenDistanceFromAnchor)
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
                Script.tokens(
                    forSegmentAt: index,
                    segment: segment
                )
            }
        }

        /// Builds the matchable token stream for one segment.
        ///
        /// A confirmed alias contributes the tokens of what the reader will *say*,
        /// but keeps the UTF-16 span of the text it stands in for. That is the whole
        /// point of the type: matching gets the spoken form, while the position the
        /// stage scrolls to stays anchored to the displayed text.
        static func tokens(forSegmentAt index: Int, segment: TeleprompterSegment) -> [Token] {
            let units = TeleprompterCanonicalizer.units(segment.text)
            let aliases = Script.usableAliases(in: segment)
            guard !aliases.isEmpty else {
                return units.map { Script.token(for: $0, at: index) }
            }

            var result: [Token] = []
            var unitIndex = 0
            for alias in aliases {
                // Units that end before the alias starts stay as they are.
                while unitIndex < units.count, units[unitIndex].range.end <= alias.displayRange.start {
                    result.append(Script.token(for: units[unitIndex], at: index))
                    unitIndex += 1
                }
                // A unit straddling the alias boundary would leave the span ambiguous,
                // so the alias is skipped rather than half-applied.
                guard unitIndex >= units.count || units[unitIndex].range.start >= alias.displayRange.start else {
                    continue
                }
                // The display tokens under this span are replaced, not appended to.
                // Carrying both variants was measured and is worse: the duplicated
                // tokens inflate the window the scorer divides by, dropping a match
                // that used to be exact (confidence 1.0 -> 0.75) for *both* readings.
                // Rewriting the incoming transcript instead would need a global
                // substitution, which the design explicitly forbids — an alias is
                // bound to one source range, never applied everywhere.
                while unitIndex < units.count, units[unitIndex].range.end <= alias.displayRange.end {
                    unitIndex += 1
                }
                let start = Position(segmentIndex: index, utf16Offset: alias.displayRange.start)
                let end = Position(segmentIndex: index, utf16Offset: alias.displayRange.end)
                for spoken in TeleprompterCanonicalizer.units(alias.spokenText) {
                    result.append(Token(value: spoken.value, start: start, end: end))
                }
            }
            while unitIndex < units.count {
                result.append(Script.token(for: units[unitIndex], at: index))
                unitIndex += 1
            }
            return result
        }

        private static func token(for unit: TeleprompterCanonicalizer.Unit, at index: Int) -> Token {
            Token(
                value: unit.value,
                start: .init(segmentIndex: index, utf16Offset: unit.range.start),
                end: .init(segmentIndex: index, utf16Offset: unit.range.end)
            )
        }

        /// Keeps only the aliases that still describe the segment as it stands.
        ///
        /// When two of them overlap, the earlier one wins and the later one is
        /// dropped: the reader confirmed them in some order, and honouring the
        /// first is both deterministic and the only choice that leaves the other
        /// words in the segment still matchable. The store rejects an overlapping
        /// pair outright, so this only decides what happens to a bundle that
        /// reached the matcher another way.
        static func usableAliases(in segment: TeleprompterSegment) -> [TeleprompterAcceptedReading] {
            var accepted: [TeleprompterAcceptedReading] = []
            for alias in segment.acceptedReadings.sorted(by: { $0.displayRange.start < $1.displayRange.start }) {
                guard alias.rejection(inSegmentText: segment.text) == nil else { continue }
                if let last = accepted.last, last.displayRange.end > alias.displayRange.start { continue }
                accepted.append(alias)
            }
            return accepted
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
                matchedCount: best.matches,
                tokenDistanceFromAnchor: abs(lower + best.start - anchorIndex)
            )
        }
        let tokenDistanceFromAnchor = abs(lower + best.start - anchorIndex)
        return Match(
            position: window[best.end - 1].position,
            startPosition: window[best.start].start,
            confidence: best.confidence,
            matchedCount: best.matches,
            isUniqueExactContinuation: uniqueExactContinuation,
            isUniqueNearAnchor: uniqueNearAnchor,
            tokenDistanceFromAnchor: tokenDistanceFromAnchor
        )
    }

    /// Shares the canonicalizer's table rather than keeping a second copy. The
    /// copy that used to live here had already drifted — it was missing `两` —
    /// and a bare numeral does reach this code (`两难`, `第三季度` both survive
    /// canonicalisation), so the drift was reachable and not cosmetic.
    private static let digits = Dictionary(
        uniqueKeysWithValues: TeleprompterCanonicalizer.chineseDigits
            .map { (String($0.key), $0.value) }
    )

    private func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        (Self.digits[lhs] ?? lhs) == (Self.digits[rhs] ?? rhs)
    }
}
