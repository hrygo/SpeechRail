import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// MA-10：sticky-to-bottom 不打断回看。
final class TranscriptFollowStateTests: XCTestCase {
    func testStartsPinnedToBottom() {
        let state = TranscriptFollowState()
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertNil(state.unseenBannerText)
    }

    func testFollowsWhenPinnedToBottom() {
        let state = TranscriptFollowState(pinnedAnchor: "line-7")
        let result = state.contentArrived(lineCount: 1)
        XCTAssertEqual(result.decision, .follow(anchor: "line-7"))
        XCTAssertNil(result.state.unseenBannerText)
    }

    func testScrolledAwayHoldsPositionInsteadOfYanking() {
        let state = TranscriptFollowState().userScrolled(toBottomWithin: 400)
        XCTAssertFalse(state.isPinnedToBottom)
        let result = state.contentArrived(lineCount: 1)
        XCTAssertEqual(result.decision, .hold)
    }

    func testLeavingBottomCountsUnseenWithoutMoving() {
        let state = TranscriptFollowState().userScrolled(toBottomWithin: 500)
        let one = state.contentArrived(lineCount: 1)
        XCTAssertEqual(one.state.unseenCount, 1)
        XCTAssertEqual(one.state.unseenBannerText, "下面有 1 条新的")
        let many = one.state.contentArrived(lineCount: 3)
        XCTAssertEqual(many.state.unseenCount, 4)
        XCTAssertEqual(many.state.unseenBannerText, "下面有 4 条新的")
        // 累积未读**不能**换来一次自动滚动。
        XCTAssertEqual(many.decision, .hold)
        XCTAssertFalse(many.state.isPinnedToBottom)
    }

    func testToleranceKeepsNearBottomPinned() {
        // 拖动条不可能精确停在 0；差一点还当贴底。
        let state = TranscriptFollowState().userScrolled(
            toBottomWithin: TranscriptFollowState.bottomTolerance
        )
        XCTAssertTrue(state.isPinnedToBottom)
    }

    func testShortContentStillCountsAsAtBottom() {
        // 内容底边早于视口底边表示内容放得下，不应被判成“离开底部”。
        let state = TranscriptFollowState().userScrolled(
            contentBottomY: 140,
            viewportBottomY: 500
        )
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertNil(state.unseenBannerText)
    }

    func testLongContentMeasuresDistanceFromVisibleBottomToContentBottom() {
        let away = TranscriptFollowState().userScrolled(
            contentBottomY: 900,
            viewportBottomY: 500
        )
        XCTAssertFalse(away.isPinnedToBottom)

        let nearBottom = away.userScrolled(
            contentBottomY: 508,
            viewportBottomY: 500
        )
        XCTAssertTrue(nearBottom.isPinnedToBottom)
    }

    func testThresholdAndUnreadBannerGeometryJitterDoesNotFlipFollowState() {
        var pinned = TranscriptFollowState()
        for distance in [23.0, 25.0, 24.0, 23.5, 25.5] {
            pinned = pinned.userScrolled(toBottomWithin: distance)
            XCTAssertTrue(pinned.isPinnedToBottom, "Pinned state changed at \(distance) pt")
            XCTAssertNil(pinned.unseenBannerText)
        }

        var readingEarlier = TranscriptFollowState()
            .userScrolled(toBottomWithin: 400)
            .contentArrived(lineCount: 3)
            .state
        for distance in [25.0, 23.0, 25.5, 23.5, 26.0] {
            readingEarlier = readingEarlier.userScrolled(toBottomWithin: distance)
            XCTAssertFalse(
                readingEarlier.isPinnedToBottom,
                "Unread-banner geometry changed follow state at \(distance) pt"
            )
            XCTAssertEqual(readingEarlier.unseenCount, 3)
            XCTAssertEqual(readingEarlier.unseenBannerText, "下面有 3 条新的")
        }

        let latest = readingEarlier.jumpToLatest(anchor: "line-9")
        XCTAssertTrue(latest.isPinnedToBottom)
        XCTAssertEqual(latest.unseenCount, 0)
        XCTAssertEqual(latest.pinnedAnchor, "line-9")
    }

    func testReturningToBottomClearsUnseenAndFollowsAgain() {
        let state = TranscriptFollowState()
            .userScrolled(toBottomWithin: 800)
            .contentArrived(lineCount: 2)
            .state
            .userScrolled(toBottomWithin: 0)
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertEqual(state.unseenCount, 0)
        XCTAssertNil(state.unseenBannerText)
        let result = state.anchoring("line-9").contentArrived(lineCount: 1)
        XCTAssertEqual(result.decision, .follow(anchor: "line-9"))
    }

    func testJumpToLatestIsUserIntentSoItResets() {
        let state = TranscriptFollowState()
            .userScrolled(toBottomWithin: 900)
            .contentArrived(lineCount: 5)
            .state
            .jumpToLatest(anchor: "line-12")
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertEqual(state.unseenCount, 0)
        XCTAssertEqual(state.pinnedAnchor, "line-12")
    }

    func testAnchoringOnlyMattersWhilePinned() {
        let away = TranscriptFollowState(isPinnedToBottom: false, unseenCount: 2)
        XCTAssertNil(away.anchoring("line-3").pinnedAnchor)
        let pinned = TranscriptFollowState().anchoring("line-3")
        XCTAssertEqual(pinned.pinnedAnchor, "line-3")
    }

    func testResetClearsEverythingForANewMeeting() {
        let state = TranscriptFollowState()
            .userScrolled(toBottomWithin: 900)
            .contentArrived(lineCount: 4)
            .state
            .reset()
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertEqual(state.unseenCount, 0)
        XCTAssertNil(state.pinnedAnchor)
        XCTAssertNil(state.unseenBannerText)
    }

    func testNegativeLineCountCannotDecreaseUnseen() {
        let state = TranscriptFollowState(isPinnedToBottom: false, unseenCount: 3)
        let result = state.contentArrived(lineCount: -5)
        XCTAssertEqual(result.state.unseenCount, 3)
    }

    func testContentGrowthDoesNotImpersonateUserScrolling() {
        let state = TranscriptFollowState().geometryChanged(
            to: .awayFromBottom, isUserInitiated: false
        )
        XCTAssertTrue(state.isPinnedToBottom)
        XCTAssertEqual(state.contentArrived(lineCount: 1).decision, .follow(anchor: nil))
    }

    func testJumpAnimationDoesNotCancelFollowingBeforeReachingBottom() {
        var state = TranscriptFollowState(isPinnedToBottom: false, unseenCount: 6)
            .jumpToLatest(anchor: "last-line")
        for proximity in [TranscriptFollowState.ScrollProximity.awayFromBottom, .thresholdBand, .atBottom] {
            state = state.geometryChanged(to: proximity, isUserInitiated: false)
            XCTAssertTrue(state.isPinnedToBottom)
            XCTAssertEqual(state.unseenCount, 0)
        }
        XCTAssertEqual(state.contentArrived(lineCount: 2).decision, .follow(anchor: "last-line"))
    }

    func testUserScrollCanInterruptFollowingAndReturnToBottom() {
        let state = TranscriptFollowState()
            .geometryChanged(to: .awayFromBottom, isUserInitiated: true)
            .contentArrived(lineCount: 2).state
        XCTAssertFalse(state.isPinnedToBottom)
        XCTAssertEqual(state.unseenCount, 2)
        XCTAssertEqual(state.geometryChanged(to: .atBottom, isUserInitiated: false), state)
        XCTAssertTrue(state.geometryChanged(to: .atBottom, isUserInitiated: true).isPinnedToBottom)
    }
}
