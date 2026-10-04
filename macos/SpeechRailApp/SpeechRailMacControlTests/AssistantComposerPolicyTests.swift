import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-09 草稿、阅读位置、输入法与恢复（A28～A30 纯函数部分；A31/A32 记 U）。
@MainActor
final class AssistantComposerPolicyTests: XCTestCase {
    /// A28：非空草稿点示例不自动覆盖，替换可 Undo（纯策略：返回选项而非覆盖）。
    func testA28TemplateCannotSilentlyReplaceDraft() {
        XCTAssertEqual(
            AssistantComposerPolicy.promptFill(template: "例", draft: ""),
            .fill("例")
        )
        XCTAssertEqual(
            AssistantComposerPolicy.promptFill(template: "例", draft: "草稿"),
            .chooseInsertReplace(template: "例", draft: "草稿")
        )
    }

    /// A29：发送等待期间的新输入不被晚到的成功抹掉。
    func testA29SendCompletionPreservesNewDraft() {
        XCTAssertTrue(AssistantComposerPolicy.shouldClearDraft(sentText: "问", currentDraft: "问"))
        XCTAssertTrue(AssistantComposerPolicy.shouldClearDraft(sentText: "问", currentDraft: "  问  "))
        XCTAssertFalse(AssistantComposerPolicy.shouldClearDraft(sentText: "问", currentDraft: "问新字"))
    }

    /// A30：向上阅读关闭跟随，回到底部恢复。
    func testA30ReadingPositionControlsFollowLatest() {
        XCTAssertTrue(AssistantComposerPolicy.followLatest(isNearBottom: true, userScrolledUp: false))
        XCTAssertFalse(AssistantComposerPolicy.followLatest(isNearBottom: true, userScrolledUp: true))
        XCTAssertFalse(AssistantComposerPolicy.followLatest(isNearBottom: false, userScrolledUp: false))
    }

    /// IME marked text 期间 Return 不发送；⌘Return 发送。
    func testIMEReturnRouting() {
        XCTAssertFalse(AssistantComposerPolicy.shouldSendOnReturn(hasMarkedText: true, modifiers: .command))
        XCTAssertFalse(AssistantComposerPolicy.shouldSendOnReturn(hasMarkedText: false, modifiers: .plain))
        XCTAssertTrue(AssistantComposerPolicy.shouldSendOnReturn(hasMarkedText: false, modifiers: .command))
    }
}
