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

    public func evaluate(
        completedTranscript: String,
        segments: [TeleprompterSegment],
        currentIndex: Int
    ) -> TeleprompterAlignmentResult {
        guard !segments.isEmpty, segments.indices.contains(currentIndex) else {
            return TeleprompterAlignmentResult(
                decision: .uncertain(candidate: nil, confidence: 0)
            )
        }

        let transcriptTokens = TeleprompterNormalizer.tokens(completedTranscript)
        guard !transcriptTokens.isEmpty else {
            return TeleprompterAlignmentResult(
                decision: .uncertain(candidate: nil, confidence: 0)
            )
        }

        let upperBound = min(segments.count - 1, currentIndex + configuration.lookahead)
        let candidates = (currentIndex...upperBound).map { index in
            (index, score(transcriptTokens: transcriptTokens, segment: segments[index]))
        }
        let best: (Int, Score) = candidates.max { lhs, rhs in lhs.1.score < rhs.1.score }
            ?? (currentIndex, Score(score: 0, matchedTokens: []))
        let current = candidates.first?.1.score ?? 0
        let next = candidates.dropFirst().first

        if let next, next.1.score >= configuration.minimumConfidence,
           next.1.score - current >= configuration.advanceMargin,
           next.0 == currentIndex + 1 {
            return TeleprompterAlignmentResult(
                decision: .advance(to: next.0, confidence: next.1.score),
                matchedTokens: next.1.matchedTokens
            )
        }

        if best.0 > currentIndex + 1, best.1.score >= configuration.minimumConfidence {
            return TeleprompterAlignmentResult(
                decision: .uncertain(candidate: currentIndex + 1, confidence: best.1.score),
                matchedTokens: best.1.matchedTokens
            )
        }

        if let next, next.1.score >= configuration.minimumConfidence,
           next.1.score - current < configuration.advanceMargin {
            return TeleprompterAlignmentResult(
                decision: .uncertain(candidate: next.0, confidence: next.1.score),
                matchedTokens: next.1.matchedTokens
            )
        }

        if current >= configuration.minimumConfidence {
            return TeleprompterAlignmentResult(
                decision: .stay(confidence: current),
                matchedTokens: candidates[0].1.matchedTokens
            )
        }

        return TeleprompterAlignmentResult(
            decision: .uncertain(candidate: nil, confidence: best.1.score),
            matchedTokens: best.1.matchedTokens
        )
    }

    private struct Score: Sendable {
        let score: Double
        let matchedTokens: [String]
    }

    private func score(
        transcriptTokens: [String],
        segment: TeleprompterSegment
    ) -> Score {
        let segmentTokens = TeleprompterNormalizer.tokens(segment.text)
        guard !segmentTokens.isEmpty else { return Score(score: 0, matchedTokens: []) }

        let sequenceCoverage = orderedCoverage(transcriptTokens, against: segmentTokens)
        let keywordTokens = TeleprompterNormalizer.tokens(segment.keywords.joined(separator: " "))
        let keywordCoverage = keywordTokens.isEmpty
            ? 0
            : orderedCoverage(transcriptTokens, against: keywordTokens)
        let phraseCoverage = segment.matchPhrases.map { phrase in
            orderedCoverage(transcriptTokens, against: TeleprompterNormalizer.tokens(phrase))
        }.max() ?? 0
        let matched = transcriptTokens.filter { segmentTokens.contains($0) }
        let combined = min(1, sequenceCoverage * 0.60 + keywordCoverage * 0.20 + phraseCoverage * 0.20)
        return Score(score: combined, matchedTokens: matched)
    }

    private func orderedCoverage(_ input: [String], against target: [String]) -> Double {
        guard !input.isEmpty, !target.isEmpty else { return 0 }
        var matched = 0
        var targetIndex = 0
        for token in input {
            guard let index = target[targetIndex...].firstIndex(of: token) else { continue }
            matched += 1
            targetIndex = index + 1
            if targetIndex == target.count { break }
        }
        return Double(matched) / Double(max(input.count, target.count))
    }
}
