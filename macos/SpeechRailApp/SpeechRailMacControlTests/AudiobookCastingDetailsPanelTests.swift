import SwiftUI
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 只离屏量测生产视图，不创建窗口或接管输入。
@MainActor
final class AudiobookCastingDetailsPanelTests: XCTestCase {
    func testLargeCastStaysWithinCompactViewport() throws {
        for count in [54, 500] {
            for sizeCategory in [ContentSizeCategory.large, .accessibilityExtraLarge] {
                let panel = AudiobookCastingDetailsPanel(onClose: {}) {
                    LazyVStack(alignment: .leading) {
                        ForEach(0..<count, id: \.self) { index in
                            Text("合成角色 \(index)：按同场关系分配共用声音；符合本书可用范围和制作条件。")
                                .font(.caption)
                        }
                    }
                } actions: {
                    VStack(alignment: .leading) {
                        Button("选择角色准备试听") {}
                        Button("使用基础推荐重新生成方案") {}
                    }
                }
                .environment(\.sizeCategory, sizeCategory)
                let image = try XCTUnwrap(ImageRenderer(content: panel).nsImage)
                // 最小 720pt 工作窗内仍留出顶栏、浮层锚点与外缘空间。
                XCTAssertLessThanOrEqual(image.size.height, 560, "\(count) roles, \(sizeCategory)")
                XCTAssertLessThanOrEqual(image.size.width, 460)
            }
        }
    }

    func testLongReasonDoesNotExpandPanelBeyondViewport() throws {
        let panel = AudiobookCastingDetailsPanel(onClose: {}) {
            Text(String(repeating: "合成角色的详细配声依据；", count: 1000))
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("选择角色准备试听") {}
        }
        let image = try XCTUnwrap(ImageRenderer(content: panel).nsImage)
        XCTAssertLessThanOrEqual(image.size.height, 560)
        XCTAssertLessThanOrEqual(image.size.width, 460)
    }
}
