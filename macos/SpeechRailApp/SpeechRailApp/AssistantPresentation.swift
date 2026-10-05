import Foundation

/// 对话展示与存储分开：已接纳输入和保存后的行使用同一个 lineID。
enum AssistantConversationRow: Identifiable, Equatable, Sendable {
    case saved(AssistantSession.Turn)
    case accepted(AssistantInputPersistenceQueue.Command, failure: String?)

    var id: String {
        switch self {
        case .saved(let turn): turn.id
        case .accepted(let command, _): command.lineID
        }
    }

    var text: String {
        switch self {
        case .saved(let turn): turn.text
        case .accepted(let command, _): command.text
        }
    }
}

/// VA-08 可信首屏、模式与数据去向：十二态纯 presentation。
///
/// 纯函数：输入事实来自 AssistantSession 与其 lease，
/// 不直接借全局 coordinator.elapsed/level。
/// “已配置”不是“已连接”：检查未执行时仅显示已配置。
struct AssistantPresentation: Equatable, Sendable {
    /// 十二态（§3.2）：未开始/受阻/实时/回看 × 细分。
    enum State: String, Equatable, Sendable, CaseIterable {
        case readyIdle
        case readyConfigured
        case blockedLLM
        case blockedStore
        case blockedVoice
        case liveListening
        case liveThinking
        case liveSpeaking
        case liveMuted
        case liveFailed
        case reviewArchived
        case reviewReadable
    }

    var state: State
    /// 标题：不虚报“语音已就绪”“说话即录”“模型已连接”。
    var title: String
    /// 事实行：模式、模型（仅已配置/已检查）、录音状态。
    var facts: [String]
    /// 数据去向说明固定文案。
    static var dataFlowNotice: String {
        "本机 SpeechRail 处理语音；文本和启用记忆发给配置的模型服务；记录保存在此 Mac。"
    }

    /// 纯推导：检查未执行时仅“已配置”，不写“已连接”。
    static func make(
        hasRecord: Bool,
        isLive: Bool,
        blocked: Bool,
        blockTitle: String?,
        phase: String,
        isMuted: Bool,
        modelConfigured: Bool,
        modelChecked: Bool,
        modelName: String?,
        modeTitle: String,
        isArchived: Bool
    ) -> AssistantPresentation {
        if isLive {
            let state: State
            let title: String
            switch phase {
            case "thinking":
                state = .liveThinking; title = "正在思考"
            case "speaking":
                state = .liveSpeaking; title = "正在说话"
            default:
                if isMuted { state = .liveMuted; title = "麦克风已静音" }
                else { state = .liveListening; title = "正在聆听" }
            }
            var facts = [modeTitle]
            if let model = modelName, modelConfigured {
                // 检查执行过才写“已连接”，否则仅“已配置”。
                facts.insert("大模型 \(model) · \(modelChecked ? "已连接" : "已配置")", at: 0)
            }
            return AssistantPresentation(state: state, title: title, facts: facts)
        }
        if blocked {
            let state: State = blockTitle?.contains("记录库") == true ? .blockedStore
                : blockTitle?.contains("模型") == true ? .blockedLLM : .blockedVoice
            return AssistantPresentation(
                state: state,
                title: blockTitle ?? "这次对话没有开始",
                facts: [modeTitle]
            )
        }
        if hasRecord, isArchived {
            return AssistantPresentation(
                state: .reviewArchived,
                title: "这一段对话已经结束",
                facts: [modeTitle]
            )
        }
        if hasRecord {
            return AssistantPresentation(
                state: .reviewReadable,
                title: "这一段对话已经结束",
                facts: [modeTitle]
            )
        }
        if modelConfigured {
            return AssistantPresentation(
                state: .readyConfigured,
                title: "还没有开始对话",
                facts: [modeTitle]
            )
        }
        return AssistantPresentation(
            state: .readyIdle,
            title: "还没有开始对话",
            facts: [modeTitle]
        )
    }
}
