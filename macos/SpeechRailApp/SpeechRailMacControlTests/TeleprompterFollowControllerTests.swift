import XCTest

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class TeleprompterFollowControllerTests: XCTestCase {
    private let aligner = TeleprompterAligner(
        configuration: .init(minimumConfidence: 0.55, advanceMargin: 0.08, lookahead: 2)
    )

    private let segments = [
        TeleprompterSegment(
            id: "segment-1",
            ordinal: 0,
            sourceRange: .init(start: 0, end: 8),
            text: "欢迎来到直播。",
            keywords: ["欢迎", "直播"],
            matchPhrases: ["欢迎来到直播"],
            pauseHint: .short
        ),
        TeleprompterSegment(
            id: "segment-2",
            ordinal: 1,
            sourceRange: .init(start: 8, end: 17),
            text: "今天介绍三个重点。",
            keywords: ["三个", "重点"],
            matchPhrases: ["今天介绍三个重点"],
            pauseHint: .medium
        ),
    ]

    func testPartialOnlyUpdatesPreview() {
        var controller = TeleprompterFollowController()

        controller.receivePartial("今天介绍")

        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertEqual(controller.partialPreview, "今天介绍")
        XCTAssertEqual(controller.mode, .following)
    }

    func testCompletedTranscriptAdvancesOneSegment() {
        var controller = TeleprompterFollowController()

        controller.receiveCompleted("今天介绍三个重点", segments: segments, aligner: aligner)

        XCTAssertEqual(controller.currentIndex, 1)
        XCTAssertNil(controller.uncertainty)
    }

    func testPauseAndManualMoveIgnoreOldCompletedTranscript() {
        var controller = TeleprompterFollowController()

        controller.pause()
        controller.receiveCompleted("今天介绍三个重点", segments: segments, aligner: aligner)
        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertEqual(controller.mode, .paused)

        controller.move(to: 1, segmentCount: segments.count)
        controller.receiveCompleted("欢迎来到直播", segments: segments, aligner: aligner)
        XCTAssertEqual(controller.currentIndex, 1)
        XCTAssertEqual(controller.mode, .manual)
    }

    func testResetFollowWindowReturnsToFollowing() {
        var controller = TeleprompterFollowController()
        controller.move(to: 1, segmentCount: segments.count)

        controller.resetFollowWindow()

        XCTAssertEqual(controller.mode, .following)
        XCTAssertNil(controller.partialPreview)
        XCTAssertNil(controller.uncertainty)
    }

    func testUncertainMatchDoesNotMove() {
        var controller = TeleprompterFollowController()

        controller.receiveCompleted("完全无关的话", segments: segments, aligner: aligner)

        XCTAssertEqual(controller.currentIndex, 0)
        XCTAssertEqual(controller.mode, .following)
        XCTAssertNotNil(controller.uncertainty)
    }
}
