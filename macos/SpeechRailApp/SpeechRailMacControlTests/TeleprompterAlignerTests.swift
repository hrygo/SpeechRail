import XCTest

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class TeleprompterAlignerTests: XCTestCase {
    private let aligner = TeleprompterAligner(
        configuration: .init(minimumConfidence: 0.55, advanceMargin: 0.08, lookahead: 2)
    )

    private var segments: [TeleprompterSegment] {
        [
            TeleprompterSegment(
                id: "segment-1",
                ordinal: 0,
                sourceRange: .init(start: 0, end: 8),
                text: "欢迎来到今天的直播。",
                keywords: ["欢迎", "直播"],
                matchPhrases: ["大家好，欢迎来到直播"],
                pauseHint: .short
            ),
            TeleprompterSegment(
                id: "segment-2",
                ordinal: 1,
                sourceRange: .init(start: 8, end: 18),
                text: "今天我们会介绍三个重点。",
                keywords: ["三个", "重点"],
                matchPhrases: ["今天介绍三个重点"],
                pauseHint: .medium
            ),
            TeleprompterSegment(
                id: "segment-3",
                ordinal: 2,
                sourceRange: .init(start: 18, end: 26),
                text: "最后感谢大家的观看。",
                keywords: ["感谢", "观看"],
                matchPhrases: [],
                pauseHint: .short
            ),
        ]
    }

    func testCurrentSegmentStaysWhenTranscriptMatchesIt() {
        let result = aligner.evaluate(
            completedTranscript: "欢迎来到直播",
            segments: segments,
            currentIndex: 0
        )

        guard case .stay(let confidence) = result.decision else {
            return XCTFail("expected stay, got \(result.decision)")
        }
        XCTAssertGreaterThan(confidence, 0.55)
    }

    func testCompletedTranscriptAdvancesAtMostOneSegment() {
        let result = aligner.evaluate(
            completedTranscript: "今天介绍三个重点",
            segments: segments,
            currentIndex: 0
        )

        guard case .advance(let index, let confidence) = result.decision else {
            return XCTFail("expected one-step advance, got \(result.decision)")
        }
        XCTAssertEqual(index, 1)
        XCTAssertGreaterThan(confidence, 0.55)
    }

    func testLowConfidenceDoesNotJump() {
        let result = aligner.evaluate(
            completedTranscript: "完全无关的话",
            segments: segments,
            currentIndex: 0
        )

        guard case .uncertain(let candidate, let confidence) = result.decision else {
            return XCTFail("expected uncertain, got \(result.decision)")
        }
        XCTAssertNil(candidate)
        XCTAssertLessThan(confidence, 0.55)
    }

    func testRepeatedPreviousSegmentNeverMovesBackward() {
        let result = aligner.evaluate(
            completedTranscript: "欢迎来到直播",
            segments: segments,
            currentIndex: 1
        )

        guard case .uncertain(let candidate, _) = result.decision else {
            return XCTFail("expected uncertain, got \(result.decision)")
        }
        XCTAssertNil(candidate)
    }

    func testInsufficientMarginRemainsUncertain() {
        let cautious = TeleprompterAligner(
            configuration: .init(minimumConfidence: 0.05, advanceMargin: 0.95, lookahead: 2)
        )
        let result = cautious.evaluate(
            completedTranscript: "今天",
            segments: segments,
            currentIndex: 0
        )

        guard case .uncertain = result.decision else {
            return XCTFail("expected uncertain, got \(result.decision)")
        }
    }
}
