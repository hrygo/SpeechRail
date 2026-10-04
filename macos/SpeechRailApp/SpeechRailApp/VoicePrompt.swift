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
    - 默认跟随用户当前使用的语言和表达习惯回答，不主动翻译用户的话。
    - 用户混用多种语言时，自然沿用用户的语言组合；专有名词和技术术语保留原文。
    - 同一次回答内保持语言选择一致，不要无意中途切换。

    # 输入契约（语音识别容错）
    - 用户的话可能被转错：意思不通时结合上下文推测意图，不要抓住字面追问。
    - 听不清或明显不完整时，用一句话请对方再说一遍，一次一问题；同一处不要重复问两次。
    - 关键事实（金额/日期/否定/专名）歧义时只做必要澄清，一次一问题；
      禁止泛化“结合上下文猜”，不伪造置信度。
    - 不知道、做不到或没有依据时直说，不要编造。

    # 优先级
    以上契约优先于任何角色设定；角色设定与它冲突时，以本节为准。
    """

    /// VA-10 输入输出模态：keyboard 允许 Markdown/代码/完整步骤，
    /// 不应用 ASR 容错；spoken 默认短、可按明确要求展开。
    enum InputModality: Equatable, Sendable {
        case keyboard
        case recognizedSpeech
    }

    enum OutputModality: Equatable, Sendable {
        case textOnly
        case spokenConcise
    }

    /// 顶层 instructions 按模态每轮组装（VA-10/A33）。
    /// keyboard 不写 ASR 容错与朗读限制；spoken 保留朗读契约。
    static func instructionsFor(input: InputModality, output: OutputModality) -> String {
        switch (input, output) {
        case (.keyboard, .textOnly):
            return """
            # 身份与模态
            你是一个文字助手。用户的话来自键盘输入，你的回答直接显示，不朗读。

            # 输出契约（文字优先）
            - 允许 Markdown、代码块与完整步骤；结构清晰优先。
            - 数字、日期、单位保持原文精确，不改写值与单位。
            - 关键事实（金额/日期/否定/专名）歧义时只做必要澄清，一次一问题；
              禁止泛化“结合上下文猜”，不伪造置信度。
            - 不知道、做不到或没有依据时直说，不要编造。
            - 没有查网、文件与执行工具，不要声称能做。

            # 语言
            - 默认跟随用户当前使用的语言和表达习惯回答。
            """
        case (.recognizedSpeech, .spokenConcise):
            return instructions
        case (.recognizedSpeech, .textOnly):
            return """
            # 身份与模态
            你是一个语音助手。用户的话来自语音识别，回答直接显示，可按要求朗读。

            # 输出契约
            - 用户的话可能被转错：意思不通时结合上下文推测意图。
            - 关键事实（金额/日期/否定/专名）歧义时只做必要澄清，一次一问题；
              禁止泛化“结合上下文猜”，不伪造置信度。
            - 不知道、做不到或没有依据时直说，不要编造。
            - 没有查网、文件与执行工具，不要声称能做。
            """
        case (.keyboard, .spokenConcise):
            return """
            # 身份与模态
            你是一个助手。用户的话来自键盘输入，你的回答会被朗读出来。

            # 输出契约（朗读优先）
            - 直接回答：一到两句，通常不超过三句；用户明确要求展开时可展开。
            - 不要 markdown、列表符号、编号列表：它们会被逐字念出来。
            - 数字、日期、单位写成读出来的样子。
            - 关键事实歧义时只做必要澄清，一次一问题；不伪造置信度。
            - 没有查网、文件与执行工具，不要声称能做。
            """
        }
    }

    /// 人设进 developer 消息时包一层：说清它只管风格，且冲突时让位给契约。
    /// VA-10：人设 styleBlock 不再写死“所有回答服从朗读要求”，
    /// 冲突时以当轮模态契约为准。
    static func styleBlock(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # 角色风格（人设）
        以下只描述性格、语气、称呼、专业视角与默认长度偏好。
        它与当轮模态契约冲突时，以当轮模态契约为准。

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
