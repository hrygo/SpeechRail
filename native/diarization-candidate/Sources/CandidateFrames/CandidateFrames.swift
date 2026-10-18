/// Validate a whole SDK batch before advancing the causal sample cursor.
public struct CandidateFrames {
    public enum InvalidOutput: Error { case probability, coverage, capacity }
    public struct Frame {
        public let start: Int
        public let end: Int
        public let scores: [Float]
    }
    public private(set) var emitted = 0
    public init() {}

    public mutating func consume(chunks: [[Float]], accepted: Int, final: Bool) throws -> [Frame] {
        guard accepted >= 0, accepted <= 9_007_199_254_740_831 else { throw InvalidOutput.coverage }
        var cursor = emitted
        var frames: [Frame] = []
        for scores in chunks {
            guard scores.count.isMultiple(of: 8), scores.count / 8 <= 2048 - frames.count else {
                throw InvalidOutput.capacity
            }
            guard scores.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw InvalidOutput.probability
            }
            for index in stride(from: 0, to: scores.count, by: 8) {
                frames.append(Frame(start: cursor, end: cursor + 160,
                                    scores: Array(scores[index..<(index + 8)])))
                cursor += 160
            }
        }
        let padded = (accepted + 159) / 160 * 160
        guard final ? cursor == padded : cursor <= accepted else { throw InvalidOutput.coverage }
        emitted = cursor
        return frames
    }
}
