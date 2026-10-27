import Foundation

/// 语义段落：把相邻的 ASR final 行合成一个翻译/显示单元。
///
/// 正式 `Line` 仍是记录单位；段落只是行之上的投影，不改变行号、落库或对齐。
struct CaptionParagraph: Identifiable, Equatable, Sendable {
    let id: String
    var lineIDs: [String]
    var sourceText: String
    /// 显示用源文：段内 ASR 边界处的句号/逗号是切分伪影，上屏时去掉。
    /// 正式 `Line` 和翻译输入仍保留原始标点。
    var displaySourceText: String
    var translatedText: String?
    var isTranslating: Bool
    var start: TimeInterval?
    var end: TimeInterval?
    var speakerLabel: String?
    var lastObservedAt: Date
    var startedAt: Date
    /// 第一行从 Stage 1 继承的草稿；段落翻译失败时至少不要闪回外语。
    var initialDraftTranslation: String?
    /// 第一行之前的前文，供段落翻译使用；组内后续行不重复取。
    var contextLines: [String] = []

    init(
        line: CaptionSession.Line,
        observedAt: Date,
        isTranslating: Bool,
        contextLines: [String] = []
    ) {
        self.id = line.id
        self.lineIDs = [line.id]
        self.sourceText = line.text
        self.displaySourceText = line.text
        self.translatedText = line.translatedText
        self.isTranslating = isTranslating
        self.start = line.start
        self.end = line.end
        self.speakerLabel = line.speakerLabel
        self.lastObservedAt = observedAt
        self.startedAt = observedAt
        self.initialDraftTranslation = line.translatedText
        self.contextLines = contextLines
    }

    mutating func append(_ line: CaptionSession.Line, observedAt: Date) {
        lineIDs.append(line.id)
        let head = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        sourceText = [head, tail].filter { !$0.isEmpty }.joined(separator: " ")

        let displayHead = CaptionParagraphAssembler
            .trimTrailingPunctuation(displaySourceText)
        let displayTail = tail
        displaySourceText = Self.joinedSource(displayHead, displayTail)
        if start == nil { start = line.start }
        if let end = line.end { self.end = end }
        if speakerLabel == nil { speakerLabel = line.speakerLabel }
        lastObservedAt = observedAt
    }

    private static func joinedSource(_ head: String, _ tail: String) -> String {
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
/// 目标不是“合并所有相邻行”，而是优先合并三类：
/// 1. 上一行在连接词/介词/列表引导语处断开；
/// 2. 上一行以逗号/冒号等分句标点结束；
/// 3. 两行间隔极短，后一行很可能是同一句的补充。
enum CaptionParagraphAssembler {
    static let maximumGap: TimeInterval = 1.2
    static let maximumLines = 3
    static let maximumDuration: TimeInterval = 12
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
    static let closeGraceMilliseconds = 500
    static let incompleteHoldMilliseconds = 900
    static let mergeScoreThreshold = 2

    static func shouldMerge(
        _ paragraph: CaptionParagraph,
        _ line: CaptionSession.Line,
        observedAt: Date
    ) -> Bool {
        guard paragraph.lineIDs.count < maximumLines else { return false }
        if let left = paragraph.speakerLabel, let right = line.speakerLabel, left != right {
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
        return score(previous: paragraph.sourceText, next: line.text, gap: gap)
            >= mergeScoreThreshold
    }

    static func gapBetween(
        _ paragraph: CaptionParagraph,
        _ line: CaptionSession.Line,
        observedAt: Date
    ) -> TimeInterval {
        if let end = paragraph.end, let start = line.start {
            return Swift.max(0, start - end)
        }
        return Swift.max(0, observedAt.timeIntervalSince(paragraph.lastObservedAt))
    }

    static func score(previous: String, next: String, gap: TimeInterval) -> Int {
        var score = 0
        if strongIncompleteEnding(previous) {
            score += 4
        } else if endsWithClausePunctuation(previous) {
            score += 2
        } else if !endsWithTerminalPunctuation(previous) {
            score += 1
        }
        if continuationStart(next) {
            score += 2
        }
        // 紧邻本身不是语义证据：两个都带句末标点的完整句，即使挨得很近也不合并。
        // 但“PS5。” + “必备游戏（没有句号）”仍应合并，因为后一行明显是残句。
        let bothTerminal = endsWithTerminalPunctuation(previous)
            && endsWithTerminalPunctuation(next)
        if gap <= 0.45, !bothTerminal {
            score += 3
        }
        if bothTerminal, gap > 0.8 {
            score -= 3
        }
        return score
    }

    /// 强未完成结尾：去掉句末标点后，仍以连接词/介词/列表引导语收束。
    static func strongIncompleteEnding(_ text: String) -> Bool {
        let stripped = trimTrailingPunctuation(text).lowercased()
        guard !stripped.isEmpty else { return false }

        let suffixes = [
            "但", "但是", "可是", "然而", "而且", "并且", "因为", "所以", "如果",
            "虽然", "尽管", "无论", "只要", "只有", "以及", "还有", "或者", "还是",
            "而是", "就是", "包括", "例如", "比如", "有的说", "有的认为", "有人说",
            "他说", "她说", "同时", "随后", "然后", "于是", "因此", "不过", "却",
            "が", "を", "に", "は", "と", "で", "も", "から", "まで", "より",
            "ので", "けれど", "けど", "고", "서", "며", "지만", "는데", "를", "을",
        ]
        if suffixes.contains(where: { stripped.hasSuffix($0) }) { return true }

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

    /// 后一行以连接词、列表词或小写英文开头，提示它仍在上一句里。
    static func continuationStart(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if first.isASCII, first.isLowercase, first.isLetter { return true }

        let lower = trimmed.lowercased()
        let prefixes = [
            "而", "但", "并且", "还有", "以及", "或者", "还是", "同时", "随后",
            "然后", "于是", "因此", "所以", "不过", "却", "也", "又", "再",
            "and ", "but ", "or ", "because ", "so ", "if ", "when ", "which ",
            "that ", "who ", "whom ", "whose ", "to ", "of ", "in ", "on ",
            "for ", "with ", "as ", "than ", "then ", "while ", "although ",
            "though ", "unless ", "until ", "since ", "including ", "such as ",
            "some say ", "others say ",
        ]
        return prefixes.contains(where: { lower.hasPrefix($0) })
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
}
