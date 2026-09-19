import Foundation

/// 语音助手开口前读的第一段话，以及"送进 TTS 之前"的那道清洗。
///
/// 单独成一个文件，是因为这两件事都**只依赖 Foundation**：语音契约与文本清洗要能
/// 单独编进单元测试 target（仓库对 `RuntimeMetricsSampler.swift` 等文件是同一种做法）。
///
/// 名字里的 `instructions` 有个坑：Responses API 的顶层 `instructions` 是**大模型的系统提示词**，
/// 管"说什么、说多长"；SpeechRail TTS 的 `instructions` 管"怎么发声"（音色、语气，由服务侧提供）。
/// 两者同名不同层，不要互相顶替。
enum VoicePrompt {

    /// Responses API 顶层 `instructions` 的内容。
    ///
    /// 三条来自 2026-09-19 的官方文档核实与本机 oMLX 实测：
    ///   · 分节短标题、按任务类型定义长度、冲突要写明优先级（官方 Realtime 提示词指南）；
    ///   · 顶层 `instructions` 每轮都要重发——续轮和 `previous_response_id` 都不继承上一轮的它；
    ///   · 契约能明显压住编号列表这类会被逐字念出来的形状，但不是保证，所以还有下面的清洗。
    static let instructions = """
    # 身份与模态
    你是一个语音助手。用户的话来自语音识别，你的回答会被朗读出来。

    # 输出契约（朗读优先）
    ## 长度
    - 直接回答：一到两句，通常不超过三句。
    - 澄清追问：只问一个问题。
    - 需要分步骤时：一次给一步，用户要求后再展开。
    - 比较或权衡：只说关键差异，每项一句。
    ## 可听性
    - 用短句和口语；不要书面连接词（此外、综上所述）和长从句。
    - 不要 markdown、列表符号、编号列表、书名号或表情符号：它们会被逐字念出来。
    - 数字、日期、单位写成读出来的样子（95% 说成百分之九十五）。
    - 不要重复用户的话，不要机械客套收尾，不要过度道歉。
    - 不要把内部的推理过程读出来，只给结论和必要理由。
    ## 节奏
    - 不要反复用同一个开头或口头禅。
    - 用户插话时立刻停下，先听他说完。

    # 语言
    一律用普通话回答；对方说外语时说明你只能用中文。

    # 输入契约（语音识别容错）
    - 用户的话可能被转错：意思不通时结合上下文推测意图，不要抓住字面追问。
    - 听不清或明显不完整时，用一句话请对方再说一遍；同一处不要重复问两次。
    - 不知道、做不到或没有依据时直说，不要编造。

    # 优先级
    以上契约优先于任何角色设定；角色设定与它冲突时，以本节为准。
    """

    /// 人设进 developer 消息时包一层：说清它只管风格，且冲突时让位给契约。
    static func styleBlock(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # 角色风格（人设）
        以下只描述性格、语气、称呼、专业视角与默认长度偏好。
        它与上面的语音对话契约冲突时，以语音对话契约和朗读要求为准。

        \(trimmed)
        """
    }

    /// 送进 TTS 之前过一道：契约要求不带标记符号，但不保证每次都遵守，
    /// 而漏过来的标记会被逐字念出来。这里只清**明确属于排版语法**的东西，
    /// 不动标点与文字本身（改写措辞是模型的活，不是清洗的活）。
    static func spokenText(from sentence: String) -> String {
        let fence = "```"
        var text = sentence.replacingOccurrences(of: fence, with: "")
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "~~", with: "")
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var value = String(line).trimmingCharacters(in: .whitespaces)
            while let first = value.first, first == "#" || first == ">" {
                value.removeFirst()
                value = value.trimmingCharacters(in: .whitespaces)
            }
            value = stripLeadingListMarker(value)
            lines.append(value)
        }
        text = lines.joined(separator: " ")
        text = text.filter { !isEmoji($0) }
        return text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只有"编号 + 空格"才算列表标记，避免把"1.5 毫米"这类正文切坏。
    private static func stripLeadingListMarker(_ value: String) -> String {
        guard let first = value.first else { return value }
        if first == "-" || first == "*" || first == "+" {
            let rest = value.dropFirst()
            return rest.first == " " ? String(rest.dropFirst()) : value
        }
        guard first.isNumber else { return value }
        let digits = value.prefix { $0.isNumber }
        guard digits.count <= 3 else { return value }
        let rest = value.dropFirst(digits.count)
        guard let separator = rest.first else { return value }
        let afterSeparator = rest.dropFirst()
        switch separator {
        case "、":
            // 中文顿号编号习惯上不跟空格。
            return String(afterSeparator)
        case ".", ")":
            // 必须跟一个空格才是列表标记："1. 项目"是，"1.5 毫米"不是。
            guard afterSeparator.first == " " else { return value }
            return String(afterSeparator.dropFirst())
        default:
            return value
        }
    }

    private static func isEmoji(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        switch scalar.value {
        case 0x1F300...0x1FAFF, 0x1F000...0x1F2FF, 0x2600...0x27BF, 0x2B00...0x2BFF:
            return true
        case 0xFE0F, 0x200D:
            return true
        default:
            return false
        }
    }
}
