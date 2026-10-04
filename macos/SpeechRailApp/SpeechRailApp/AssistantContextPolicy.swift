import Foundation

/// 与正文分离的上下文 entry。状态说明用 `id` 绑定到原记录，不改写 `text`。
struct AssistantContextEntry: Equatable, Sendable {
    enum GenerationStatus: Equatable, Sendable {
        case completed
        case failed
        case interrupted
        case unknown
    }

    enum PlaybackStatus: Equatable, Sendable {
        case notRequested
        case completed
        case incomplete
        case unknown
    }

    let id: String
    let text: String
    let generationStatus: GenerationStatus?
    let playbackStatus: PlaybackStatus?

    init(
        id: String,
        text: String,
        generationStatus: GenerationStatus? = nil,
        playbackStatus: PlaybackStatus? = nil
    ) {
        self.id = id
        self.text = text
        self.generationStatus = generationStatus
        self.playbackStatus = playbackStatus
    }
}

/// 一轮历史以显式 user/reply 关系组成。缺失回复保留为 `nil`，不猜测相邻消息配对。
struct AssistantContextTurn: Equatable, Sendable {
    let user: AssistantContextEntry
    let reply: AssistantContextEntry?

    init(user: AssistantContextEntry, reply: AssistantContextEntry? = nil) {
        self.user = user
        self.reply = reply
    }
}

/// 预算后的请求输入；`requestScalars` 包含顶层 instructions 与全部 message 正文。
struct AssistantContextRequestContext: Equatable, Sendable {
    let instructions: String
    let messages: [LLMMessage]
    let maxOutputTokens: Int
    let omittedHistoryTurns: Int
    let omittedMemories: Int
    let omissionNote: String?
    let requestScalars: Int
}

/// VA-14 上下文预算、记忆审阅与作用域：纯策略。
///
/// 候选产品限额（不等于模型 token window）：
/// 最多 12 个完整历史 turn、历史正文 16,000 scalar、
/// 选中记忆 4,000 scalar、总请求正文 24,000 scalar、
/// 输出 maxOutputTokens=1,024。
enum AssistantContextPolicy {
    static let maxHistoryTurns = 12
    static let maxHistoryScalars = 16_000
    static let maxMemoryScalars = 4_000
    static let maxRequestScalars = 24_000
    static let maxOutputTokens = 1_024

    enum ContextBuildError: Error, Equatable, Sendable, LocalizedError {
        case requiredContentExceedsRequestBudget(requiredScalars: Int, maximumScalars: Int)

        var errorDescription: String? {
            switch self {
            case .requiredContentExceedsRequestBudget(let requiredScalars, let maximumScalars):
                "当前问题、人设与固定指令共 \(requiredScalars) 个 Unicode scalar，超过 \(maximumScalars) 上限。请缩短当前内容后重试。"
            }
        }
    }

    /// 旧消息入口按相邻 user/reply 形成完整 turn 后裁剪；新调用应优先使用显式 ID turn 的 builder。
    static func trimHistory(
        _ history: [LLMMessage],
        omittedPrefix: Int = 0
    ) -> (kept: [LLMMessage], omittedCount: Int, note: String?) {
        let turns = groupLegacyMessagesIntoTurns(history)
        let selection = selectHistoryTurns(turns)
        let omitted = selection.omittedCount + max(0, omittedPrefix)
        let kept = selection.kept.flatMap { $0 }
        let note = omitted == 0 ? nil : "已省略 \(omitted) 个历史 turn（预算保护）"
        return (kept, omitted, note)
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

    /// 构造受统一 scalar 预算约束的 LLM 请求。
    ///
    /// instructions、人设和当前问题为必需内容；超限时返回明确错误。
    /// 可选历史按完整 turn 优先保留近期内容，记忆按完整条目优先保留近期内容。
    static func buildRequestContext(
        instructions: String,
        persona: String?,
        memories: [String],
        history: [AssistantContextTurn],
        currentQuestion: AssistantContextEntry
    ) throws -> AssistantContextRequestContext {
        let personaMessage: LLMMessage? = persona.flatMap { text in
            text.isEmpty ? nil : LLMMessage(role: .developer, text: text, cacheBreakpoint: true)
        }
        let requiredScalars = instructions.unicodeScalars.count
            + (personaMessage?.text.unicodeScalars.count ?? 0)
            + currentQuestion.text.unicodeScalars.count
        guard requiredScalars <= maxRequestScalars else {
            throw ContextBuildError.requiredContentExceedsRequestBudget(
                requiredScalars: requiredScalars,
                maximumScalars: maxRequestScalars
            )
        }

        // 当前问题独立追加；同 ID 若也出现在传入历史里，只保留 currentQuestion 这一份。
        let priorHistory = history.filter { $0.user.id != currentQuestion.id }
        let historySelection = selectHistoryTurns(priorHistory)
        var includedHistory = historySelection.kept
        var omittedHistoryTurns = historySelection.omittedCount + history.count - priorHistory.count

        let memorySelection = trimMemories(memories)
        var includedMemories = memorySelection.kept
        var omittedMemories = memorySelection.omittedCount

        func memoryMessage(_ entries: [String]) -> LLMMessage? {
            guard !entries.isEmpty else { return nil }
            let block = "以下是用户确认过、可以长期记住的事：\n"
                + entries.map { "- \($0)" }.joined(separator: "\n")
            return LLMMessage(role: .developer, text: block, cacheBreakpoint: true)
        }

        func composeMessages() -> [LLMMessage] {
            var messages: [LLMMessage] = []
            if let personaMessage {
                messages.append(personaMessage)
            }
            if let message = memoryMessage(includedMemories) {
                messages.append(message)
            }
            for turn in includedHistory {
                messages.append(contentsOf: render(turn))
            }
            messages.append(LLMMessage(role: .user, text: currentQuestion.text))
            return messages
        }

        var messages = composeMessages()
        var requestScalars = instructions.unicodeScalars.count + scalarCount(in: messages)
        while requestScalars > maxRequestScalars {
            if !includedHistory.isEmpty {
                includedHistory.removeFirst()
                omittedHistoryTurns += 1
            } else if !includedMemories.isEmpty {
                includedMemories.removeFirst()
                omittedMemories += 1
            } else {
                // requiredScalars 已检查；只有消息渲染本身发生变化才可能到达此分支。
                throw ContextBuildError.requiredContentExceedsRequestBudget(
                    requiredScalars: requestScalars,
                    maximumScalars: maxRequestScalars
                )
            }
            messages = composeMessages()
            requestScalars = instructions.unicodeScalars.count + scalarCount(in: messages)
        }

        var omissionParts: [String] = []
        if omittedHistoryTurns > 0 {
            omissionParts.append("已省略 \(omittedHistoryTurns) 个历史 turn")
        }
        if omittedMemories > 0 {
            omissionParts.append("已省略 \(omittedMemories) 条记忆")
        }

        return AssistantContextRequestContext(
            instructions: instructions,
            messages: messages,
            maxOutputTokens: maxOutputTokens,
            omittedHistoryTurns: omittedHistoryTurns,
            omittedMemories: omittedMemories,
            omissionNote: omissionParts.isEmpty ? nil : omissionParts.joined(separator: "；"),
            requestScalars: requestScalars
        )
    }

    private static func groupLegacyMessagesIntoTurns(_ messages: [LLMMessage]) -> [[LLMMessage]] {
        var turns: [[LLMMessage]] = []
        var pendingUserTurn: [LLMMessage]?

        for message in messages {
            switch message.role {
            case .user:
                if let pendingUserTurn {
                    turns.append(pendingUserTurn)
                }
                pendingUserTurn = [message]
            case .assistant:
                if var turn = pendingUserTurn {
                    turn.append(message)
                    turns.append(turn)
                    pendingUserTurn = nil
                } else {
                    // 无所属 user 的 assistant 保持独立，不与更早或更晚的 user 强配。
                    turns.append([message])
                }
            case .developer:
                if var turn = pendingUserTurn {
                    turn.append(message)
                    pendingUserTurn = turn
                } else {
                    turns.append([message])
                }
            }
        }

        if let pendingUserTurn {
            turns.append(pendingUserTurn)
        }
        return turns
    }

    private static func selectHistoryTurns(
        _ turns: [[LLMMessage]]
    ) -> (kept: [[LLMMessage]], omittedCount: Int) {
        let recentTurns = Array(turns.suffix(maxHistoryTurns))
        var keptReversed: [[LLMMessage]] = []
        var usedScalars = 0

        for turn in recentTurns.reversed() {
            let turnScalars = scalarCount(in: turn)
            guard turnScalars <= maxHistoryScalars,
                  usedScalars + turnScalars <= maxHistoryScalars
            else {
                continue
            }
            keptReversed.append(turn)
            usedScalars += turnScalars
        }

        return (Array(keptReversed.reversed()), turns.count - keptReversed.count)
    }

    private static func selectHistoryTurns(
        _ turns: [AssistantContextTurn]
    ) -> (kept: [AssistantContextTurn], omittedCount: Int) {
        let recentTurns = Array(turns.suffix(maxHistoryTurns))
        var keptReversed: [AssistantContextTurn] = []
        var usedScalars = 0

        for turn in recentTurns.reversed() {
            let turnMessages = render(turn)
            let turnScalars = scalarCount(in: turnMessages)
            guard turnScalars <= maxHistoryScalars,
                  usedScalars + turnScalars <= maxHistoryScalars
            else {
                continue
            }
            keptReversed.append(turn)
            usedScalars += turnScalars
        }

        return (Array(keptReversed.reversed()), turns.count - keptReversed.count)
    }

    private static func render(_ turn: AssistantContextTurn) -> [LLMMessage] {
        var messages = [LLMMessage(role: .user, text: turn.user.text)]
        guard let reply = turn.reply else { return messages }

        if let note = statusNote(for: reply) {
            messages.append(LLMMessage(role: .developer, text: note))
        }
        if !reply.text.isEmpty {
            messages.append(LLMMessage(role: .assistant, text: reply.text))
        }
        return messages
    }

    private static func statusNote(for entry: AssistantContextEntry) -> String? {
        var facts: [String] = []
        switch entry.generationStatus {
        case .some(.completed), .none:
            break
        case .some(.failed):
            facts.append("生成失败；以下仅保留已收到的原文，不代表完整回答")
        case .some(.interrupted):
            facts.append("生成被打断；以下仅保留已知原文，未生成部分未知")
        case .some(.unknown):
            facts.append("生成状态未知；无法判断这段回答是否完整")
        }

        switch entry.playbackStatus {
        case .some(.notRequested), .some(.completed), .none:
            break
        case .some(.incomplete):
            facts.append("朗读未完成，已生成原文保留")
        case .some(.unknown):
            facts.append("朗读状态未知，不能推断是否完整播放或已被听到")
        }

        guard !facts.isEmpty else { return nil }
        return "应用状态（绑定条目 ID：\(entry.id)，不是用户正文）：\(facts.joined(separator: "；"))。"
    }

    private static func scalarCount(in messages: [LLMMessage]) -> Int {
        messages.reduce(0) { $0 + $1.text.unicodeScalars.count }
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
