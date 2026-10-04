import Foundation

/// VA-09 草稿、阅读位置、输入法与恢复：纯策略。
///
/// 纯函数，可确定性测试；真实 IME/焦点/无障碍记 U。
enum AssistantComposerPolicy {
    /// 模板填入：空稿直接填入；非空返回插入/替换/取消三选项，替换可 Undo。
    enum PromptFill: Equatable, Sendable {
        case fill(String)
        case chooseInsertReplace(template: String, draft: String)
    }

    static func promptFill(template: String, draft: String) -> PromptFill {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .fill(template)
        }
        return .chooseInsertReplace(template: template, draft: draft)
    }

    /// 发送成功后清稿：snapshot 一致才清，等待期间的新输入不抹。
    static func shouldClearDraft(sentText: String, currentDraft: String) -> Bool {
        currentDraft.trimmingCharacters(in: .whitespacesAndNewlines) == sentText
    }

    /// 跟随最新：向上阅读关闭跟随，显示“回到最新”；回到底部恢复。
    static func followLatest(isNearBottom: Bool, userScrolledUp: Bool) -> Bool {
        if userScrolledUp { return false }
        return isNearBottom
    }

    /// IME marked text 期间 Return 交给系统组合，不发送。
    static func shouldSendOnReturn(hasMarkedText: Bool, modifiers: ReturnModifiers) -> Bool {
        if hasMarkedText { return false }
        switch modifiers {
        case .plain: return false
        case .command: return true
        }
    }

    enum ReturnModifiers: Equatable, Sendable {
        case plain
        case command
    }
}
