import SpeechRailAppSupport
import XCTest

final class WindowLayoutPolicyTests: XCTestCase {
    func testExpandedTierCollapsesToMediumBeforeCompact() {
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .expanded, width: 1_259),
            .medium
        )
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .expanded, width: 959),
            .compact
        )
    }

    func testMediumTierUsesHysteresisWhenRestoringExpanded() {
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .medium, width: 1_339),
            .medium
        )
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .medium, width: 1_340),
            .expanded
        )
    }

    func testCompactTierWaitsForComfortableWidthBeforeRestoringInspector() {
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .compact, width: 1_019),
            .compact
        )
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .compact, width: 1_020),
            .medium
        )
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .compact, width: 1_340),
            .expanded
        )
    }

    func testNonPositiveWidthDoesNotChangeTier() {
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .medium, width: 0),
            .medium
        )
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .compact, width: -1),
            .compact
        )
    }
}
