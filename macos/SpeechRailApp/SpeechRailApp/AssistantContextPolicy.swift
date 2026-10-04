import Foundation

/// VA-14 上下文预算、记忆审阅与作用域：纯策略。
///
/// 候选产品限额（不等于模型 token window）：
/// 最多 12 个完整历史 turn、历史正文 16,000 scalar、
/// 选中记忆 4,000 scalar、输出 maxOutputTokens=1,024。
enum AssistantContextPolicy {
    static var maxHistoryTurns: Int { 12 }
    static var maxHistoryScalars: Int { 16_000 }
    static var maxMemoryScalars: Int { 4_000 }
    static var maxOutputTokens: Int { 1_024 }

    /// 按预算裁剪历史：保留近期完整消息（user/assistant 配对尽量不拆），
    /// failed/interrupted 可连同交付说明保留；返回裁剪后的消息与省略范围说明。
    static func trimHistory(
        _ history: [LLMMessage],
        omittedPrefix: Int = 0
    ) -> (kept: [LLMMessage], omittedCount: Int, note: String?) {
        guard history.count > maxHistoryTurns else {
            return (history, omittedPrefix, omittedPrefix > 0 ? "已省略最早 \(omittedPrefix) 轮" : nil)
        }
        // 按配对裁剪：保留最近 maxHistoryTurns 轮，不拆半个配对。
        var kept = Array(history.suffix(maxHistoryTurns))
        // 配对对齐：若首条为 assistant（半个配对），再向前取一条 user。
        if kept.first?.role == .assistant, history.count > maxHistoryTurns {
            let extraIndex = history.count - maxHistoryTurns - 1
            if extraIndex >= 0, history[extraIndex].role == .user {
                kept.insert(history[extraIndex], at: 0)
            }
        }
        // scalar 上限：超限时从最早轮丢整轮，不截半轮。
        var scalars = kept.reduce(0) { $0 + $1.text.unicodeScalars.count }
        while scalars > maxHistoryScalars, kept.count > 2 {
            scalars -= kept[0].text.unicodeScalars.count
            kept.removeFirst()
        }
        let omitted = history.count - kept.count + omittedPrefix
        return (kept, omitted, "已省略最早 \(omitted) 轮（预算保护）")
    }

    /// 记忆按 scalar 上限裁剪：超限丢最早选中记忆，不截半条。
    static func trimMemories(_ memories: [String]) -> (kept: [String], omittedCount: Int) {
        var kept = memories
        var scalars = kept.reduce(0) { $0 + $1.unicodeScalars.count }
        var omitted = 0
        while scalars > maxMemoryScalars, !kept.isEmpty {
            scalars -= kept[0].unicodeScalars.count
            kept.removeFirst()
            omitted += 1
        }
        return (kept, omitted)
    }

    /// 记忆 draft：确认前不 upsert；取消不写。kind 限 fact/preference/summary。
    struct MemoryDraft: Equatable, Sendable {
        var body: String
        var kind: String
        var sourceSessionID: String?
        var scope: String
    }

    static func validatedDraft(body: String, kind: String, sourceSessionID: String?) -> MemoryDraft? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 拒绝明显秘密：不保存、不发诊断。
        let lower = trimmed.lowercased()
        if lower.contains("sk-") || lower.contains("api_key") || lower.contains("password") {
            return nil
        }
        guard ["fact", "preference", "summary"].contains(kind) else { return nil }
        return MemoryDraft(body: trimmed, kind: kind, sourceSessionID: sourceSessionID, scope: "下一新场生效")
    }
}
