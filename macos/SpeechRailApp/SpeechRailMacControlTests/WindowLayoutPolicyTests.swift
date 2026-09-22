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
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .expanded, width: 960),
            .medium
        )
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .expanded, width: 1_260),
            .expanded
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
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .medium, width: 1_120),
            .medium
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
        XCTAssertEqual(
            WindowLayoutPolicy.nextTier(from: .compact, width: 1_260),
            .medium
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

    func testMediumContractHidesSidebarButLeavesInspectorToPagePolicy() {
        let contract = WindowLayoutPolicy.contract(for: .medium)

        XCTAssertEqual(contract.sidebar, .collapsed)
        XCTAssertEqual(contract.inspector, .pageControlled)
        XCTAssertEqual(contract.minimumPrimaryContentWidth, 500)
    }

    func testCompactContractKeepsOnlyPrimaryWorkspace() {
        let contract = WindowLayoutPolicy.contract(for: .compact)

        XCTAssertEqual(contract.sidebar, .collapsed)
        XCTAssertEqual(contract.inspector, .collapsed)
        XCTAssertEqual(contract.minimumPrimaryContentWidth, 500)
    }

    func testExpandedContractKeepsSidebarAndLetsPagesChooseInspector() {
        let contract = WindowLayoutPolicy.contract(for: .expanded)

        XCTAssertEqual(contract.sidebar, .visible)
        XCTAssertEqual(contract.inspector, .pageControlled)
    }
}
