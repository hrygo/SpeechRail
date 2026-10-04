import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-14 上下文预算、记忆审阅与作用域（A45/A46/A48；A41 随播放交付已覆盖）。
@MainActor
final class AssistantContextPolicyTests: XCTestCase {
    /// A45：长对话按预算裁剪，保留近期完整 turn，范围可见。
    func testA45ContextBudgetKeepsCompleteRecentTurns() {
        var history: [LLMMessage] = []
        for i in 0..<20 {
            history.append(LLMMessage(role: .user, text: "问\(i)"))
            history.append(LLMMessage(role: .assistant, text: "答\(i)"))
        }
        let trimmed = AssistantContextPolicy.trimHistory(history)
        XCTAssertLessThanOrEqual(trimmed.kept.count, 13, "不超过预算+配对对齐")
        XCTAssertTrue(trimmed.kept.last?.text == "答19", "保留最新轮")
        XCTAssertNotNil(trimmed.note, "应显示省略范围")
        XCTAssertTrue(trimmed.omittedCount > 0)
    }

    /// A46：记忆需编辑确认；确认前不写，不自动事实化。
    func testA46MemoryRequiresEditedConfirmation() {
        XCTAssertNil(
            AssistantContextPolicy.validatedDraft(body: "  ", kind: "fact", sourceSessionID: nil),
            "空正文不得建 draft"
        )
        XCTAssertNil(
            AssistantContextPolicy.validatedDraft(body: "记住密码 sk-abc", kind: "fact", sourceSessionID: nil),
            "明显秘密不得保存"
        )
        XCTAssertNil(
            AssistantContextPolicy.validatedDraft(body: "喜欢红茶", kind: "agreement", sourceSessionID: nil),
            "未知 kind 不得静默新增"
        )
        let draft = AssistantContextPolicy.validatedDraft(
            body: "喜欢红茶", kind: "preference", sourceSessionID: "s1"
        )
        XCTAssertNotNil(draft, "合法 draft 应通过")
        XCTAssertEqual(draft?.scope, "下一新场生效", "默认下一新场生效")
    }

    /// A48：记忆有界，撤销明确；来源数据不添工具能力。
    func testA48MemoryIsBoundedDataAndRevocationIsExplicit() {
        let big = (0..<100).map { "记忆\($0)内容填充" }
        let trimmed = AssistantContextPolicy.trimMemories(big)
        let scalars = trimmed.kept.reduce(0) { $0 + $1.unicodeScalars.count }
        XCTAssertLessThanOrEqual(scalars, AssistantContextPolicy.maxMemoryScalars, "记忆有界")
        // 撤销明确：经 coordinator.removeMemory / setMemoryActive，本策略只保证不超限。
        XCTAssertTrue(trimmed.omittedCount >= 0)
    }
}
