import Testing
@testable import CandidateFrames

@Test func preservesShortTurnsAndPaddedTail() throws {
    var timeline = CandidateFrames()
    let scores: [Float] = [0.5, 0.5001, 0, 0, 0, 0, 0, 0]
    let first = try timeline.consume(chunks: [scores], accepted: 161, final: false)
    #expect(first.count == 1)
    #expect(first[0].start == 0 && first[0].end == 160)
    #expect(first[0].scores == scores)
    let tail = try timeline.consume(chunks: [scores], accepted: 161, final: true)
    #expect(tail.count == 1 && tail[0].start == 160 && tail[0].end == 320)
    // Wire time is padded; Python clips only the final frame to sample 161.
    #expect(try timeline.consume(chunks: [], accepted: 161, final: true).isEmpty)
}

@Test func rejectsInvalidProbabilityCoverageWithoutPartialMutation() throws {
    let scores = [Float](repeating: 0.1, count: 8)
    for chunks in [[Array(scores.dropLast())], [[Float.nan] + Array(scores.dropLast())],
                   [[Float.infinity] + Array(scores.dropLast())], [[Float](repeating: 1.1, count: 8)]] {
        var timeline = CandidateFrames()
        #expect(throws: (any Error).self) {
            try timeline.consume(chunks: chunks, accepted: 160, final: true)
        }
        #expect(timeline.emitted == 0)
    }
    var timeline = CandidateFrames()
    #expect(throws: (any Error).self) {
        try timeline.consume(chunks: [scores], accepted: 159, final: false)
    }
    #expect(timeline.emitted == 0)
    #expect(throws: (any Error).self) {
        try timeline.consume(chunks: [], accepted: 1, final: true)
    }
    #expect(throws: (any Error).self) {
        try timeline.consume(chunks: [[Float](repeating: 0, count: 2049 * 8)],
                             accepted: 2049 * 160, final: true)
    }
    #expect(timeline.emitted == 0)
}

@Test func fast128BatchIsBoundedAndContinuous() throws {
    var timeline = CandidateFrames()
    let frames = try timeline.consume(chunks: [[Float](repeating: 0.75, count: 1024 * 8)],
                                      accepted: 163_840, final: false)
    #expect(frames.count == 1024)
    #expect(frames.last?.end == 163_840)
    #expect(try timeline.consume(chunks: [], accepted: 163_841, final: false).isEmpty)
}
