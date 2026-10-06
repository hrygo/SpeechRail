import Foundation

/// 一轮回答定稿后的**朗读计划**（纯值类型，不拥有网络、播放器或 LLM）。
///
/// M0e：默认链 `final → 保存成功 → LLM 完整成功 → 结构/保义校验 → 确认文本 TTS`。
/// 未定稿不开口：流式 delta 只做预览与落库，只有完整终态才能产生候选正式回答。
/// 计划一旦生成就是不可变的：同一原文无论怎么分包，到达间隔如何，
/// 转换结果必须一致（分包无关）。
struct AssistantSpeechPlan: Equatable, Sendable {
    /// 定稿原文（落库/屏幕用的同一份，不改写）。
    var sourceText: String
    /// 实际送 TTS 的文本（与原文逐 span 对照，必要时回退到原文）。
    var speakText: String
    /// 朗读文本到原文的 span 对照：每一段朗读文本对应原文的哪一段。
    /// 对照覆盖朗读文本的每一个 scalar，且原文 span 不重叠、不倒序。
    var spans: [Span]
    /// 生成计划时原文的 Unicode scalar 数（防篡改/防错配）。
    var sourceScalars: Int
    /// 是否整体回退到原文（保义转换不可靠时保留原文，不强行转换）。
    var fellBackToSource: Bool

    struct Span: Equatable, Sendable {
        /// 朗读文本的 scalar 范围。
        var speakRange: Range<Int>
        /// 原文的 scalar 范围。
        var sourceRange: Range<Int>
    }

    /// 计划是否可用：对照完整覆盖朗读文本，且原文 span 有序不重叠。
    var isValid: Bool {
        guard !speakText.isEmpty else { return false }
        let scalars = speakText.unicodeScalars.count
        guard scalars > 0 else { return false }
        var cursor = 0
        var lastSourceLower = 0
        var first = true
        for span in spans {
            guard span.speakRange.lowerBound == cursor,
                  span.speakRange.upperBound > span.speakRange.lowerBound
            else { return false }
            cursor = span.speakRange.upperBound
            guard span.sourceRange.lowerBound >= lastSourceLower,
                  span.sourceRange.upperBound > span.sourceRange.lowerBound
            else { return false }
            if !first, span.sourceRange.lowerBound < lastSourceLower { return false }
            lastSourceLower = span.sourceRange.upperBound
            first = false
        }
        return cursor == scalars
    }
}

enum AssistantSpeechPlanBuilder {
    /// 整轮上限（与 `AssistantSpeechTextBuffer` 同一量级，复用服务端 total 上限语义）。
    static let maximumSourceScalars = 4_096

    enum BuildError: Error, Equatable {
        /// 原文超限：暂停朗读并保留全文，不硬切。
        case sourceTooLong(offered: Int, limit: Int)
        /// 原文无可朗读内容（空/纯空白）。
        case nothingSpeakable
    }

    /// 对完整定稿原文做整体解析与保义转换。
    /// 确定性：同一原文无论分包如何结果一致（输入只有完整原文，无时钟/分包参数）。
    /// 超限不硬切：抛 `sourceTooLong`，调用方暂停朗读并保留全文。
    static func build(from source: String) -> Result<AssistantSpeechPlan, BuildError> {
        let scalars = source.unicodeScalars.count
        guard scalars <= maximumSourceScalars else {
            return .failure(.sourceTooLong(offered: scalars, limit: maximumSourceScalars))
        }
        // 空/纯空白原文：无可朗读内容，不开口（上层按 nothingSpeakable 处理）。
        guard source.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else {
            return .failure(.nothingSpeakable)
        }
        let converted = convertPreservingMeaning(from: source)
        let speakScalars = converted.unicodeScalars.count
        guard speakScalars > 0 else { return .failure(.nothingSpeakable) }
        let span = AssistantSpeechPlan.Span(
            speakRange: 0..<speakScalars,
            sourceRange: 0..<scalars
        )
        return .success(
            AssistantSpeechPlan(
                sourceText: source,
                speakText: converted,
                spans: [span],
                sourceScalars: scalars,
                fellBackToSource: converted == source
            )
        )
    }

    /// 整体保义转换：与 `VoicePrompt.spokenText` 同一清洗语义，但整段一次完成，
    /// 且满足任一条件即整体回退到原文（保留原文，不强行转换）：
    /// - 转换前后 Unicode scalar 序列除清洗规则外不一致（对照检查）；
    /// - 含无法可靠朗读的复杂表达（多行代码围栏、未闭合结构）。
    /// 调用方不得对回退做二次清洗：回退即原文。
    private static func convertPreservingMeaning(from source: String) -> String {
        guard isReliablySpeakable(source) else { return source }
        let cleaned = VoicePrompt.spokenText(from: source)
        guard !cleaned.isEmpty else { return source }
        guard spansCoverFaithfully(cleaned: cleaned, source: source) else { return source }
        return cleaned
    }

    /// 无法可靠朗读时保留原文：多行代码围栏、未闭合行内代码/强调结构。
    /// 这是保守的启发式——宁可保留原文（TTS 按字读），也不伪造"可朗读"版本。
    private static func isReliablySpeakable(_ source: String) -> Bool {
        // 多行代码围栏：朗读表示会丢结构，保留原文。
        if source.contains("```") { return false }
        // 未闭合的行内结构：转换语义不确定，保留原文。
        if !isBalanced(source, delimiter: "`") { return false }
        if !isBalanced(source, delimiter: "**") { return false }
        if !isBalanced(source, delimiter: "~~") { return false }
        return true
    }

    private static func isBalanced(_ source: String, delimiter: String) -> Bool {
        let count = source.components(separatedBy: delimiter).count - 1
        return count % 2 == 0
    }

    /// 对照检查：清洗只允许删除排版标记与空白规整，不允许改写内容 scalar。
    /// 实现：清洗结果的非空白 scalar 序列，必须是原文非空白、非排版标记 scalar
    /// 序列的子序列（保序），且长度变化在排版标记删除量级内。
    /// 保守起见：若清洗吃掉了数字/字母/中文标点之外的"内容字符"，即判不一致。
    private static func spansCoverFaithfully(cleaned: String, source: String) -> Bool {
        let stripped = source.unicodeScalars.filter { !isFormattingScalar($0) && !$0.properties.isWhitespace }
        let kept = cleaned.unicodeScalars.filter { !$0.properties.isWhitespace }
        // 清洗结果的每个内容 scalar 必须按序出现在原文内容序列里。
        var index = stripped.startIndex
        for scalar in kept {
            var found = false
            while index < stripped.endIndex {
                if stripped[index] == scalar {
                    found = true
                    index = stripped.index(after: index)
                    break
                }
                index = stripped.index(after: index)
            }
            if !found { return false }
        }
        return true
    }

    /// 排版标记：清洗规则明确删除的 scalar（与 `VoicePrompt.spokenText` 对齐）。
    private static func isFormattingScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "#", ">", "-", "*", "+", "`", "_", "~": return true
        default: return false
        }
    }
}
