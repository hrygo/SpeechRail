#if SWIFT_PACKAGE
import SpeechRailAppSupport
#endif
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

    func testAudiobookInlineCastColumnThresholdAndRouteShortcut() {
        XCTAssertFalse(WindowLayoutPolicy.audiobookShowsInlineCastColumn(forWidth: 1_119))
        XCTAssertTrue(WindowLayoutPolicy.audiobookShowsInlineCastColumn(forWidth: 1_120))
        XCTAssertEqual(AppRoute.audiobook.group, .creator)
        XCTAssertEqual(AppRoute.audiobook.title, "有声书工坊")
        XCTAssertEqual(
            AppRoute.audiobook.shortcutSpec,
            AppRouteShortcutSpec(key: "5", modifiers: .command)
        )
        XCTAssertEqual(AppRoute.allCases.count, 14)
    }
}

#if !SWIFT_PACKAGE
import AppKit
import SwiftUI

@MainActor
final class OperationFeedbackLayoutTests: XCTestCase {
    func testFeedbackDoesNotChangeWorkspaceSizeForShortOrLongErrors() {
        for message in ["导出失败，请重试。", String(repeating: "长错误详情需要可以完整阅读。\n", count: 500)] {
            let host = NSHostingView(rootView:
                Text("工作台正文")
                    .frame(width: 640, height: 480)
                    .operationFeedback([OperationFeedback(message)])
            )
            XCTAssertEqual(host.fittingSize.width, 640, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, 480, accuracy: 1)
        }
    }

    func testActualFeedbackCardRemainsWithinItsHostBounds() {
        for size in [CGSize(width: 420, height: 280), CGSize(width: 640, height: 480)] {
            let message = String(repeating: "完整错误详情不应溢出卡片。\n", count: 500)
            let host = NSHostingView(rootView: OperationFeedbackCard(
                feedback: OperationFeedback(message)!, availableSize: size, dismiss: {}
            ))
            XCTAssertLessThanOrEqual(host.fittingSize.width, size.width)
            XCTAssertLessThanOrEqual(host.fittingSize.height, size.height)
        }
    }

    func testEmptyFeedbackDoesNotReserveSpaceInSheet() {
        let host = NSHostingView(rootView:
            Text("弹窗正文")
                .frame(width: 420, height: 280)
                .operationFeedback([OperationFeedback(nil)])
        )
        XCTAssertEqual(host.fittingSize.width, 420, accuracy: 1)
        XCTAssertEqual(host.fittingSize.height, 280, accuracy: 1)
    }
}
#endif
