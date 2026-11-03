import Foundation

/// 段落边界统一证据：供合并评分、是否合并与收口等待时长共用，避免多处词表和优先级漂移。
struct CaptionBoundaryEvidence: Equatable, Sendable {
    var strongIncomplete: Bool
    var correlativePair: Bool
    var continuation: Bool
    var standaloneReply: Bool

    init(
        strongIncomplete: Bool = false,
        correlativePair: Bool = false,
        continuation: Bool = false,
        standaloneReply: Bool = false
    ) {
        self.strongIncomplete = strongIncomplete
        self.correlativePair = correlativePair
        self.continuation = continuation
        self.standaloneReply = standaloneReply
    }
}

/// 语义段落：把相邻的 ASR final 行合成一个翻译/显示单元。
///
/// 正式 `Line` 仍是记录单位；段落只是行之上的投影，不改变行号、落库或对齐。
struct CaptionParagraph: Identifiable, Equatable, Sendable {
    let id: String
    var lineIDs: [String]
    var sourceText: String
    /// 非持久化的最后一条原行正文，供边界证据与关联词窗口分析使用，避免扫描整个历史段落。
    var lastLineSourceText: String
    /// 显示用源文：段内 ASR 边界处的句号/逗号是切分伪影，上屏时去掉。
    /// 正式 `Line` 和翻译输入仍保留原始标点。
    var displaySourceText: String
    var translatedText: String?
    var isTranslating: Bool
    var start: TimeInterval?
    var end: TimeInterval?
    var speakerLabel: String?
    var sourceLanguage: String?
    var lastLineCloseReason: TranscriptPreviewLedger.SegmentCloseReason?
    var lastObservedAt: Date
    var startedAt: Date
    /// 第一行从 Stage 1 继承的草稿；段落翻译失败时至少不要闪回外语。
    var initialDraftTranslation: String?
    /// 第一行定稿时归档的 Stage 1 稳定前缀（仅单行段落可用）。
    var initialStabilizedPrefix: String?
    /// 第一行之前的前文，供段落翻译使用；组内后续行不重复取。
    var contextLines: [String] = []

    init(
        line: CaptionSession.Line,
        observedAt: Date,
        isTranslating: Bool,
        contextLines: [String] = [],
        initialStabilizedPrefix: String? = nil
    ) {
        self.id = line.id
        self.lineIDs = [line.id]
        self.sourceText = line.text
        self.lastLineSourceText = line.text
        self.displaySourceText = line.text
        self.translatedText = line.translatedText
        self.isTranslating = isTranslating
        self.start = line.start
        self.end = line.end
        self.speakerLabel = line.speakerLabel
        self.sourceLanguage = line.sourceLanguage
        self.lastLineCloseReason = line.closeReason
        self.lastObservedAt = observedAt
        self.startedAt = observedAt
        self.initialDraftTranslation = line.translatedText
        self.initialStabilizedPrefix = initialStabilizedPrefix
        self.contextLines = contextLines
    }

    /// 构造候选追加后的段落展示文本；软预算计数与实际 `append` 共用同一函数。
    func candidateDisplaySourceText(appending lineText: String) -> String {
        let displayHead = CaptionParagraphAssembler
            .trimTrailingPunctuation(displaySourceText)
        let displayTail = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.joinedSource(displayHead, displayTail)
    }

    mutating func append(_ line: CaptionSession.Line, observedAt: Date) {
        lineIDs.append(line.id)
        translatedText = nil
        initialStabilizedPrefix = nil
        let head = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceText = [head, tail].filter { !$0.isEmpty }.joined(separator: " ")
        lastLineSourceText = line.text
        displaySourceText = candidateDisplaySourceText(appending: tail)
        if start == nil { start = line.start }
        if let end = line.end { self.end = end }
        if speakerLabel == nil { speakerLabel = line.speakerLabel }
        if sourceLanguage == nil { sourceLanguage = line.sourceLanguage }
        lastLineCloseReason = line.closeReason
        lastObservedAt = observedAt
    }

    static func joinedSource(_ head: String, _ tail: String) -> String {
        let left = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if joinsWithoutSpace(left.last!), joinsWithoutSpace(right.first!) {
            return left + right
        }
        return left + " " + right
    }

    /// 中文、日文可以在段内直接续写；韩语和拉丁文字需要词间空格。
    private static func joinsWithoutSpace(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }
}

/// 段边界判定：只做可解释的启发式，不引入模型。
///
/// 目标不是“合并所有相邻行”，而是优先合并四类：
/// 1. 上一行因服务端 `budget_rollover` 被动截断（句末句号属于截断伪影）；
/// 2. 上一行在连接词/介词/助词/列表引导语处断开，或上下两行构成成对关联复句；
/// 3. 上一行以逗号/冒号等分句标点结束，或下一行以明确的后置词尾（如“之旅”“中心之一”）续接；
/// 4. 两行间隔极短，后一行很可能是同一句的补充。
enum CaptionParagraphAssembler {
    static let maximumGap: TimeInterval = 1.2
    static let maximumLines = 3
    static let maximumDuration: TimeInterval = 28
    static let softMaxCharacterCount = 38
    static let correlativeLeftWindowCharacters = 128
    static let correlativeRightWindowCharacters = 24
    static let standaloneReplies: Set<String> = ["好的", "是的", "走吧", "行了"]
    /// Display-only conversation state stays bounded even if the session runs for hours.
    static let maximumRetainedParagraphs = 500

    /// Pure retention policy, shared with the long-session regression test.
    static func retained(
        _ paragraphs: [CaptionParagraph],
        visibleLineIDs: Set<String>,
        openParagraphID: String?,
        limit: Int
    ) -> [CaptionParagraph] {
        var kept = paragraphs.filter { paragraph in
            paragraph.id == openParagraphID
                || paragraph.isTranslating
                || paragraph.lineIDs.contains(where: visibleLineIDs.contains)
        }
        let excess = kept.count - max(1, limit)
        if excess > 0 { kept.removeFirst(excess) }
        return kept
    }
    static let completeSentenceGraceMilliseconds = 200
    static let closeGraceMilliseconds = 320
    static let incompleteHoldMilliseconds = 750
    static let mergeScoreThreshold = 2

    /// 统一计算边界证据：合并判定传入 `lastLineSourceText` 与新行，收口计时传入 `lastLineSourceText` 与 `nil`。
    static func boundaryEvidence(
        previous: String,
        next: String? = nil
    ) -> CaptionBoundaryEvidence {
        let standalone = isStandaloneReply(previous)
        let strongIncomplete = !standalone && strongIncompleteEnding(previous)
        let correlative = next.map { hasCorrelativePair(previous: previous, next: $0) } ?? false
        let continuation = next.map { continuationStart($0) } ?? false
        return CaptionBoundaryEvidence(
            strongIncomplete: strongIncomplete,
            correlativePair: correlative,
            continuation: continuation,
            standaloneReply: standalone
        )
    }

    /// 独立短回答：去末端标点后等于明确集合且原行带终结标点。
    static func isStandaloneReply(_ text: String) -> Bool {
        guard endsWithTerminalPunctuation(text) else { return false }
        let stripped = trimTrailingPunctuation(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return standaloneReplies.contains(stripped)
    }

    /// 判断一段文本是否是短碎片（去除句末标点后中文/CJK <= 6字，或西文 <= 2个词）。
    /// 诸如“我们国内观众。”、“审美上, 可。”等短句，
    /// 即使末尾带句号，在实际连续语音中也绝非独立语义大段，往往是 ASR 截断伪影或句首状语/引子。
    static func isShortFragment(_ text: String) -> Bool {
        if isStandaloneReply(text) { return false }
        let stripped = trimTrailingPunctuation(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return true }
        let cjkCount = stripped.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }.count
        if cjkCount > 0 {
            return cjkCount <= 6
        }
        let words = stripped.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        return words.count <= 2
    }

    /// 根据当前段落完整性与合并开关计算收口等待时长（毫秒）。
    /// - 关闭段落合并或已满 `maximumLines` 行时，后续绝无可能继续并入，返回 `0` 立即收口并启动精翻；
    /// - 被动截断（`budgetRollover`）、短碎片或强未完成结尾等待 `incompleteHoldMilliseconds`；
    /// - 独立短回答（如“好的。”“是的。”“走吧。”“行了。”）非 rollover 时优先按完整句等待 `completeSentenceGraceMilliseconds`；
    /// - 已带句末终结标点的完整句缩短为 `completeSentenceGraceMilliseconds`，兼顾极短跨句拼接与首字响应；
    /// - 其余常规分句等待 `closeGraceMilliseconds`。
    static func flushDelayMilliseconds(
        for paragraph: CaptionParagraph,
        assemblyEnabled: Bool
    ) -> Int {
        guard assemblyEnabled, paragraph.lineIDs.count < maximumLines else {
            return 0
        }
        let text = paragraph.lastLineSourceText
        let evidence = boundaryEvidence(previous: text, next: nil)
        if paragraph.lastLineCloseReason == .budgetRollover {
            return incompleteHoldMilliseconds
        }
        if evidence.standaloneReply {
            return completeSentenceGraceMilliseconds
        }
        if evidence.strongIncomplete || isShortFragment(text) {
            return incompleteHoldMilliseconds
        }
        if endsWithTerminalPunctuation(text) {
            return completeSentenceGraceMilliseconds
        }
        return closeGraceMilliseconds
    }

    static func shouldMerge(
        _ paragraph: CaptionParagraph,
        _ line: CaptionSession.Line,
        observedAt: Date
    ) -> Bool {
        guard paragraph.lineIDs.count < maximumLines else { return false }
        if let left = paragraph.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           let right = line.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !left.isEmpty, !right.isEmpty, left != right {
            return false
        }
        if let leftLang = normalizedLanguageCode(paragraph.sourceLanguage),
           let rightLang = normalizedLanguageCode(line.sourceLanguage),
           leftLang != rightLang {
            return false
        }
        let previousText = paragraph.lastLineSourceText
        let leftIsChinese = CaptionLanguageDetector.detect(for: previousText).isChinese
        let rightIsChinese = CaptionLanguageDetector.detect(for: line.text).isChinese
        if leftIsChinese != rightIsChinese {
            return false
        }
        let gap = gapBetween(paragraph, line, observedAt: observedAt)
        guard gap <= maximumGap else { return false }
        if let start = paragraph.start, let end = line.end,
           end - start > maximumDuration {
            return false
        }
        if observedAt.timeIntervalSince(paragraph.startedAt) > maximumDuration {
            return false
        }
        let isRollover = paragraph.lastLineCloseReason == .budgetRollover
        let evidence = boundaryEvidence(previous: previousText, next: line.text)
        if !isRollover, evidence.standaloneReply {
            return false
        }
        let mergeScore = score(
            previous: previousText,
            next: line.text,
            gap: gap,
            previousCloseReason: paragraph.lastLineCloseReason,
            evidence: evidence
        )
        let candidateDisplay = paragraph.candidateDisplaySourceText(appending: line.text)
        if candidateDisplay.count > softMaxCharacterCount,
           endsWithTerminalPunctuation(previousText),
           !isRollover,
           !isShortFragment(previousText),
           !evidence.strongIncomplete,
           !evidence.correlativePair,
           !evidence.continuation {
            return false
        }
        return mergeScore >= mergeScoreThreshold
    }

    private static func normalizedLanguageCode(_ code: String?) -> String? {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty,
              raw != "auto",
              raw != "und",
              raw != "unknown"
        else {
            return nil
        }
        let normalized = raw.replacingOccurrences(of: "_", with: "-")
        return normalized.split(separator: "-").first.map(String.init) ?? normalized
    }

    static func gapBetween(
        _ paragraph: CaptionParagraph,
        _ line: CaptionSession.Line,
        observedAt: Date
    ) -> TimeInterval {
        if let end = paragraph.end, let start = line.start {
            return Swift.max(0, start - end)
        }
        if paragraph.lastLineCloseReason == .budgetRollover {
            return 0
        }
        return Swift.max(0, observedAt.timeIntervalSince(paragraph.lastObservedAt))
    }

    static func score(
        previous: String,
        next: String,
        gap: TimeInterval,
        previousCloseReason: TranscriptPreviewLedger.SegmentCloseReason? = nil,
        evidence: CaptionBoundaryEvidence? = nil
    ) -> Int {
        let resolvedEvidence = evidence ?? boundaryEvidence(previous: previous, next: next)
        let isRollover = previousCloseReason == .budgetRollover
        if !isRollover, resolvedEvidence.standaloneReply {
            return 0
        }
        var score = 0
        let incompletePrevious = resolvedEvidence.strongIncomplete
        let shortPrevious = !resolvedEvidence.standaloneReply && isShortFragment(previous)
        let continuationNext = resolvedEvidence.continuation
        let correlative = resolvedEvidence.correlativePair
        if isRollover {
            score += 4
        }
        if correlative {
            score += 4
        }
        if incompletePrevious {
            score += 4
        } else if endsWithClausePunctuation(previous) {
            score += 2
        } else if !endsWithTerminalPunctuation(previous) {
            score += 1
        }
        if continuationNext {
            score += 3
        }
        // 紧邻本身不是语义证据：两个都带句末标点的完整句，即使挨得很近也不合并。
        // 但“PS5。” + “必备游戏（没有句号）”仍应合并，因为后一行明显是残句；
        // 若上一行是 budget_rollover 被动截断、去标点后仍为悬空未完成词尾（如“而在河谷镇的。”）、
        // 或上下两行构成未闭合的关联词配对（如“虽然…。/但是…。”）、
        // 或下一行以明确的后置续接成分开头（如“之旅…”、“对于…”、“沉闷而…”），
        // 或上一行是超短碎片且后一行也是残句，则上一行句末句号属于截断伪影。
        let hasTruncationArtifact = isRollover
            || incompletePrevious
            || correlative
            || continuationNext
            || (shortPrevious && !endsWithTerminalPunctuation(next))
        let bothTerminal = !hasTruncationArtifact
            && endsWithTerminalPunctuation(previous)
            && endsWithTerminalPunctuation(next)
        if gap <= 0.45, !bothTerminal {
            score += 3
        }
        if bothTerminal, gap > 0.8 {
            score -= 3
        }
        return score
    }

    /// 检查上一条原行最后 128 个 Character 与下一条句首前 24 个 Character 是否构成未闭合的关联词配对。
    static func hasCorrelativePair(previous: String, next: String) -> Bool {
        let leftWindow = String(previous.suffix(correlativeLeftWindowCharacters))
        let strippedLeft = trimTrailingPunctuationAndQuotes(leftWindow)
        guard !strippedLeft.isEmpty else { return false }

        let internalTerminals: Set<Character> = ["。", "！", "？", "!", "?"]
        let leftClause: String
        if let lastTermIdx = strippedLeft.lastIndex(where: { internalTerminals.contains($0) }) {
            leftClause = String(strippedLeft[strippedLeft.index(after: lastTermIdx)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            leftClause = strippedLeft
        }
        guard !leftClause.isEmpty else { return false }

        var trimmedRight = next.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = trimmedRight.first,
              first.isWhitespace || "“‘「『（《【(［[{\"'".contains(first) {
            trimmedRight.removeFirst()
        }
        let rightWindow = String(trimmedRight.prefix(correlativeRightWindowCharacters))
        guard !rightWindow.isEmpty else { return false }

        // 1. 一边 -> 一边（左侧恰有一个“一边”待配对，若已成双则不再配对）
        if rightWindow.hasPrefix("一边") {
            let count = occurrences(of: "一边", in: leftClause)
            if count == 1 { return true }
        }

        // 2. 一方面 -> 另一方面（排除“另一方面”自身包含的“一方面”子串）
        if rightWindow.hasPrefix("另一方面") {
            let masked = leftClause.replacingOccurrences(of: "另一方面", with: "\u{FFFC}")
            if let openerRange = masked.range(of: "一方面", options: .backwards),
               !masked[openerRange.upperBound...].contains("\u{FFFC}") {
                return true
            }
        }

        // 3. 不仅/不但 -> 而且/还
        if rightWindow.hasPrefix("而且") || rightWindow.hasPrefix("还") {
            if hasUnclosedOpener(
                openers: ["不仅", "不但"],
                closers: ["而且", "还"],
                in: leftClause
            ) {
                return true
            }
        }

        // 4. 虽然/尽管 -> 但是/但/却
        if rightWindow.hasPrefix("但是") || rightWindow.hasPrefix("但") || rightWindow.hasPrefix("却") {
            if hasUnclosedOpener(
                openers: ["虽然", "尽管"],
                closers: ["但是", "但", "却"],
                in: leftClause
            ) {
                return true
            }
        }

        return false
    }

    private static func occurrences(of target: String, in text: String) -> Int {
        guard !target.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: target, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    private static func hasUnclosedOpener(
        openers: [String],
        closers: [String],
        in clause: String
    ) -> Bool {
        var latestOpenerUpperBound: String.Index?
        for opener in openers {
            if let range = clause.range(of: opener, options: .backwards) {
                if let current = latestOpenerUpperBound {
                    if range.upperBound > current {
                        latestOpenerUpperBound = range.upperBound
                    }
                } else {
                    latestOpenerUpperBound = range.upperBound
                }
            }
        }
        guard let afterStart = latestOpenerUpperBound else { return false }
        let trailing = clause[afterStart...]
        return !closers.contains(where: { trailing.contains($0) })
    }

    /// 强未完成结尾：去掉句末标点后，仍以连接词/介词/结构助词/列表引导语或书名号后孤立数词收束。
    static func strongIncompleteEnding(_ text: String) -> Bool {
        if isStandaloneReply(text) { return false }
        let stripped = trimTrailingPunctuation(text).lowercased()
        guard !stripped.isEmpty else { return false }

        let suffixes = [
            "但", "但是", "可是", "然而", "而且", "并且", "因为", "所以", "如果",
            "虽然", "尽管", "无论", "只要", "只有", "以及", "还有", "或者", "还是",
            "而是", "就是", "包括", "例如", "比如", "有的说", "有的认为", "有人说",
            "他说", "她说", "同时", "随后", "然后", "于是", "因此", "不过", "却",
            "的", "地", "得", "之", "在", "从", "向", "往", "把", "被", "对",
            "于", "由", "给", "与", "和", "跟", "同", "比", "为", "着", "名为",
            "が", "を", "に", "は", "と", "で", "も", "から", "まで", "より",
            "ので", "けれど", "けど", "고", "서", "며", "지만", "는데", "를", "을",
        ]
        if suffixes.contains(where: { stripped.hasSuffix($0) }) { return true }

        // 书名号或引号闭合后紧跟孤立数词/破折号/短词被硬切（如“《霍比特人》一”、“《霍比特人》一意外”）
        if let range = stripped.range(
            of: #"[》」』”’][一二三四五六七八九十0-9—\-]{1,2}[\u4e00-\u9fa5]{0,2}$"#,
            options: .regularExpression
        ), !range.isEmpty {
            return true
        }

        let english = [
            "and", "but", "or", "because", "so", "if", "when", "which", "that",
            "who", "whom", "whose", "to", "of", "in", "on", "for", "with",
            "as", "than", "then", "while", "although", "though", "unless",
            "until", "since", "including", "like", "such", "some", "others",
        ]
        let lastToken = stripped.split(whereSeparator: {
            !$0.isLetter && $0 != "'"
        }).last.map(String.init) ?? ""
        if english.contains(lastToken) { return true }

        return stripped.hasSuffix("such as") || stripped.hasSuffix("some say")
            || stripped.hasSuffix("others say")
    }

    /// 后一行以连接词、介词短语、连词结构（如“沉闷而无感”中的“而”）、后置复合词尾（如“之旅”“中心之一”）或小写英文开头，提示它仍在上一句里。
    static func continuationStart(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if first.isASCII, first.isLowercase, first.isLetter { return true }

        let lower = trimmed.lowercased()
        // 注意：单字/转折/让步关联词（如“但”“但是”“却”“不过”“也”“又”“再”“还”“而且”）
        // 只在存在未闭合 opener 时由 hasCorrelativePair 配对加分，不在此处无条件触发跨句强合并。
        let prefixes = [
            "而", "并且", "还有", "以及", "或者", "还是", "同时", "随后",
            "然后", "于是", "因此", "所以",
            "对于", "关于", "至于", "对", "在", "从", "向", "往", "由", "跟",
            "同", "随着", "为了", "因为", "由于", "正如", "比如", "例如",
            "也就是说", "换句话说", "包括", "特别是", "尤其是",
            "之旅", "之一", "之中", "之上", "之下", "之间", "之后", "之前",
            "之际", "之初", "中心之一", "必备",
            "and ", "or ", "because ", "so ", "if ", "when ", "which ",
            "that ", "who ", "whom ", "whose ", "to ", "of ", "in ", "on ",
            "for ", "with ", "as ", "than ", "then ", "unless ",
            "until ", "since ", "including ", "such as ",
            "some say ", "others say ",
        ]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }

        // 句首修饰/并列短语中包含连词“而”（如“沉闷而无感”、“华丽而空洞”、“贫穷而落后”），但排除“而且/而是/而言”
        let prefixSlice = String(trimmed.prefix(6))
        if prefixSlice.contains("并且") {
            return true
        }
        if prefixSlice.contains("而"),
           !prefixSlice.hasPrefix("而且"),
           !prefixSlice.hasPrefix("而是"),
           !prefixSlice.contains("而言") {
            return true
        }

        return false
    }

    static func endsWithTerminalPunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return "。！？.!?…".contains(last)
    }

    static func endsWithClausePunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ",，;；:：、".contains(last)
    }

    static func trimTrailingPunctuation(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, "。！？.!?;；,，:：、…".contains(last) {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func trimTrailingPunctuationAndQuotes(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last,
              last.isWhitespace || "。！？.!?;；,，:：、…”’」』）》】)］]}\"'".contains(last) {
            value.removeLast()
        }
        return value
    }
}
