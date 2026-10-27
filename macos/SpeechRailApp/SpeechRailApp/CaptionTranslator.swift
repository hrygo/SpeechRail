import Foundation
import NaturalLanguage
import os

/// 实时字幕源语言检测器（纯本地计算，耗时 < 0.1ms，不改变 /v1/realtime 协议契约）。
public enum CaptionLanguageDetector: Sendable {
    public struct DetectionResult: Equatable, Sendable {
        public let languageCode: String
        public let isChinese: Bool

        public init(languageCode: String, isChinese: Bool) {
            self.languageCode = languageCode
            self.isChinese = isChinese
        }
    }

    /// 判定一段识别文本是否已经是中文（免翻译直通）。
    public static func detect(for text: String) -> DetectionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return DetectionResult(languageCode: "und", isChinese: true)
        }

        var cjkCount = 0
        var meaningfulCount = 0
        var latinWordCount = 0
        var inLatinWord = false

        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar) {
                inLatinWord = false
                continue
            }
            meaningfulCount += 1
            // CJK Unified Ideographs + Extension A
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                cjkCount += 1
                inLatinWord = false
            } else if CharacterSet.letters.contains(scalar) {
                if !inLatinWord {
                    latinWordCount += 1
                    inLatinWord = true
                }
            } else {
                inLatinWord = false
            }
        }

        guard meaningfulCount > 0 else {
            return DetectionResult(languageCode: "und", isChinese: true)
        }

        // 注意：日语假名（0x3040...0x30FF）与韩文谚文（0xAC00...0xD7AF 等）不计入 cjkCount。
        // 若存在平假名/片假名，直接识别为日语；若存在谚文，直接识别为韩语（均需翻译为中文）。
        let hasKana = trimmed.unicodeScalars.contains {
            (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
        }
        if hasKana {
            return DetectionResult(languageCode: "ja", isChinese: false)
        }

        let hasHangul = trimmed.unicodeScalars.contains {
            (0xAC00...0xD7AF).contains($0.value)
                || (0x1100...0x11FF).contains($0.value)
                || (0x3130...0x318F).contains($0.value)
        }
        if hasHangul {
            return DetectionResult(languageCode: "ko", isChinese: false)
        }

        let cjkCharRatio = Double(cjkCount) / Double(meaningfulCount)
        let tokenTotal = cjkCount + latinWordCount
        let cjkTokenRatio = tokenTotal > 0 ? Double(cjkCount) / Double(tokenTotal) : 0

        if cjkCharRatio >= 0.55 || (cjkCount > 0 && cjkTokenRatio >= 0.55) {
            return DetectionResult(languageCode: "zh", isChinese: true)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        if let dominant = recognizer.dominantLanguage {
            let raw = dominant.rawValue
            if raw.hasPrefix("zh") {
                return DetectionResult(languageCode: "zh", isChinese: true)
            }
            return DetectionResult(languageCode: raw, isChinese: false)
        }
        return DetectionResult(languageCode: "en", isChinese: false)
    }
}

/// 未定稿原文的稳定前缀 / 活跃识别尾部切分（`spec §11.1` 的 LocalAgreement-2 视觉分层）。
///
/// 服务端 `rollback_tokens=5` 只是省算力的启发式：相邻两次 `partial` 的前缀一致属于受控解码，
/// 不是两次无约束独立解码的声学共识。因此这里只做**显示分层**，不把稳定前缀当成不可改写，
/// 也绝不回传给服务端当 `stable_prefix_codepoints`。
public enum CaptionPartialStability: Sendable {
    /// 活跃尾部至少保留的字符数（`spec §11.1` 给的 4~6 个字符区间取中）。
    public static let volatileTailReserve = 5

    /// 相邻两次未定稿原文的稳定前缀长度（按 `Character` 计）。
    ///
    /// 先取公共前缀，再扣除末尾活跃区；尾部若还是拉丁词，则连同最多两个词一起划入活跃区，
    /// 避免把单词截成两半显示。返回 `0` 表示这次还看不出稳定区。
    public static func stablePrefixLength(previous: String, current: String) -> Int {
        guard !previous.isEmpty, !current.isEmpty, previous != current else { return 0 }
        let common = previous.commonPrefix(with: current)
        let commonCount = common.count
        guard commonCount > volatileTailReserve else { return 0 }

        var stable = Array(common.prefix(commonCount - volatileTailReserve))
        var removedWords = 0
        while removedWords < 2, let last = stable.last, last.isASCII, last.isLetter {
            while let last = stable.last, last.isASCII, last.isLetter { stable.removeLast() }
            while let last = stable.last, last == " " { stable.removeLast() }
            removedWords += 1
        }
        return stable.count
    }
}

/// 双语平行上下文回合（Conversational SimulMT：同时携带源语言与已定稿中文译文以锁定专名与指代）。
public struct CaptionContextTurn: Equatable, Sendable {
    public let sourceText: String
    public let translatedText: String?

    public init(sourceText: String, translatedText: String? = nil) {
        self.sourceText = sourceText
        self.translatedText = translatedText
    }

    public var formattedPromptLine: String {
        let src = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tgt = translatedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tgt.isEmpty, tgt != src {
            return "原文：\(src) → 译文：\(tgt)"
        }
        return "原文：\(src)"
    }
}

/// 字幕术语表：解析用户输入的「原文=译法」条目，同时供 ASR keywords 与翻译提示词使用。
///
/// 输入用逗号/分号/换行分隔；`=`、`→`、`->` 都可作为原文与译法的分隔符。
/// 只保留前 24 条、每段最多 40 个字符，避免把提示词或握手撑爆。
public struct CaptionGlossary: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public let source: String
        public let translation: String?

        public var id: String { source.lowercased() }

        public var promptLine: String {
            if let translation, !translation.isEmpty {
                return "\(source) → \(translation)"
            }
            return "\(source)（保持原文）"
        }
    }

    public static let empty = CaptionGlossary(entries: [])

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = Array(entries.prefix(24))
    }

    public init(text: String, maximumEntries: Int = 24) {
        let limit = Swift.max(1, Swift.min(maximumEntries, 24))
        let chunks = text.components(
            separatedBy: CharacterSet(charactersIn: ",，;；\n")
        )
        var seen = Set<String>()
        var parsed: [Entry] = []
        for chunk in chunks {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = trimmed
                .replacingOccurrences(of: "->", with: "→")
                .replacingOccurrences(of: "＝", with: "=")
            let sourcePart: String
            let translationPart: String?
            if let separator = normalized.firstIndex(where: { $0 == "=" || $0 == "→" }) {
                sourcePart = String(normalized[..<separator])
                let target = normalized[normalized.index(after: separator)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                translationPart = target.isEmpty ? nil : String(target.prefix(40))
            } else {
                sourcePart = normalized
                translationPart = nil
            }
            let source = sourcePart
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !source.isEmpty else { continue }
            let boundedSource = String(source.prefix(40))
            let key = boundedSource.lowercased()
            guard seen.insert(key).inserted else { continue }
            parsed.append(Entry(source: boundedSource, translation: translationPart))
            if parsed.count >= limit { break }
        }
        self.entries = parsed
    }

    /// 只把原文喂给 ASR 的 `keywords`，避免把中文译法当成识别词。
    public var asrKeywords: [String] {
        entries.map(\.source)
    }

    public var promptSuffix: String {
        guard !entries.isEmpty else { return "" }
        let lines = entries.map { "- \($0.promptLine)" }.joined(separator: "\n")
        return "\n\n【术语表（请优先采用下列专名与术语译法）】\n\(lines)"
    }
}

/// 翻译延迟直方图：只保存毫秒数与分桶计数，不保存原文、译文或任何可识别内容。
///
/// 分桶上界用于近似 p50/p95；超过最后一个上界的样本落入溢出桶，`percentile`
/// 返回真实最大值。指标是**每场会话**的轻量汇总，不落盘、不上报。
public struct CaptionTranslationLatency: Equatable, Sendable {
    public private(set) var count = 0
    public private(set) var totalMilliseconds = 0
    public private(set) var maximumMilliseconds = 0
    private var buckets = [Int](repeating: 0, count: Self.bounds.count + 1)

    static let bounds = [
        50, 100, 200, 300, 500, 750, 1_000, 1_500,
        2_000, 3_000, 5_000, 8_000, 12_000, 20_000,
    ]

    public init() {}

    public mutating func record(milliseconds: Int) {
        let value = max(0, milliseconds)
        count += 1
        totalMilliseconds += value
        maximumMilliseconds = max(maximumMilliseconds, value)
        let index = Self.bounds.firstIndex { value <= $0 } ?? Self.bounds.count
        buckets[index] += 1
    }

    public var averageMilliseconds: Int {
        count == 0 ? 0 : totalMilliseconds / count
    }

    /// 近似分位值（毫秒）。空直方图返回 0，溢出桶返回当前最大值。
    public func percentile(_ percentile: Double) -> Int {
        guard count > 0 else { return 0 }
        let ratio = Swift.min(Swift.max(percentile, 0), 1)
        let target = Swift.max(1, Int((Double(count) * ratio).rounded(.up)))
        var accumulated = 0
        for (index, bucket) in buckets.enumerated() {
            accumulated += bucket
            if accumulated >= target {
                return index < Self.bounds.count ? Self.bounds[index] : maximumMilliseconds
            }
        }
        return maximumMilliseconds
    }
}

/// 译文替换的稳定性汇总：用「字符擦除」衡量已显示内容被改写掉多少。
///
/// 定义与 2009.09016《Presenting Simultaneous Translation in Limited Space》一致：
/// 对相邻两次译文取最长公共前缀，`擦除 = 上次长度 - LCP`，`追加 = 本次长度 - LCP`。
/// 只记字符数，不记正文；按场累计，用来判断预览/定稿是否越改越碎。
public struct CaptionTranslationStability: Equatable, Sendable {
    public private(set) var updates = 0
    public private(set) var erasedCharacters = 0
    public private(set) var appendedCharacters = 0
    /// 与上一次完全没有公共前缀的次数（整句重写）。
    public private(set) var resets = 0

    public init() {}

    public var averageErasedCharacters: Double {
        updates == 0 ? 0 : Double(erasedCharacters) / Double(updates)
    }

    /// 新增字符占「新增 + 擦除」的比例；越接近 1 越像纯追加。
    public var appendRatio: Double {
        let total = appendedCharacters + erasedCharacters
        return total == 0 ? 1 : Double(appendedCharacters) / Double(total)
    }

    public mutating func record(previous: String?, current: String) {
        let currentText = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentText.isEmpty else { return }
        updates += 1
        let previousText = previous?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !previousText.isEmpty else {
            appendedCharacters += currentText.count
            return
        }
        let common = previousText.commonPrefix(with: currentText)
        let commonCount = common.count
        let erased = Swift.max(0, previousText.count - commonCount)
        let appended = Swift.max(0, currentText.count - commonCount)
        erasedCharacters += erased
        appendedCharacters += appended
        if commonCount == 0 { resets += 1 }
    }
}

/// 双阶段翻译的可观测汇总：请求数、成功/失败/取消、队列等待与首字/完成延迟。
public struct CaptionTranslationMetrics: Equatable, Sendable {
    public internal(set) var finalRequests = 0
    public internal(set) var finalCompleted = 0
    public internal(set) var finalFailed = 0
    public internal(set) var finalCancelled = 0
    public internal(set) var finalQueueWait = CaptionTranslationLatency()
    public internal(set) var finalFirstDelta = CaptionTranslationLatency()
    public internal(set) var finalCompletion = CaptionTranslationLatency()

    public internal(set) var previewRequests = 0
    public internal(set) var previewCompleted = 0
    public internal(set) var previewFailed = 0
    public internal(set) var previewFirstDelta = CaptionTranslationLatency()
    /// 预览译文跨请求的字符擦除；不含流内的自然追加。
    public internal(set) var previewStability = CaptionTranslationStability()

    /// 定稿相对已上屏草稿的字符擦除；越高说明定稿改写越多。
    public internal(set) var finalStability = CaptionTranslationStability()

    public init() {}
}

/// 翻译引擎抽象协议：生产环境注入 `LLMProvider`，单测注入确定性 Fake。
///
/// `priorDraftTranslation` 是已经上屏的预览译文（LocalAgreement-2 稳定前缀或上一轮草稿），
/// 只作为提示词软锚定，不是硬性前缀约束。
@MainActor
public protocol CaptionTranslationClient: Sendable {
    func translateStream(
        sourceText: String,
        contextLines: [String],
        priorDraftTranslation: String?,
        systemInstructions: String?
    ) -> AsyncThrowingStream<String, any Error>

    func translateStream(
        sourceText: String,
        contextLines: [String],
        priorDraftTranslation: String?
    ) -> AsyncThrowingStream<String, any Error>
}

extension CaptionTranslationClient {
    public func translateStream(
        sourceText: String,
        contextLines: [String],
        priorDraftTranslation: String?,
        systemInstructions: String?
    ) -> AsyncThrowingStream<String, any Error> {
        translateStream(
            sourceText: sourceText,
            contextLines: contextLines,
            priorDraftTranslation: priorDraftTranslation
        )
    }

    public func translateStream(
        sourceText: String,
        contextLines: [String],
        priorDraftTranslation: String?
    ) -> AsyncThrowingStream<String, any Error> {
        translateStream(
            sourceText: sourceText,
            contextLines: contextLines,
            priorDraftTranslation: priorDraftTranslation,
            systemInstructions: nil
        )
    }
}

/// 实时字幕双阶段流式翻译协调器（Stage 1: Partial 节流预览 + LCP 软前缀锚定；Stage 2: Completed 双语平行上下文精翻）。
@MainActor
public final class CaptionTranslationCoordinator {
    public static let systemInstructions = """
    你是一个专业的实时视频中文字幕翻译引擎。请将用户输入的【当前句】直接翻译为自然、简练、符合中文母语影视字幕习惯的简体中文。
    硬性规则：
    1. 只输出【当前句】对应的中文译文本身，严禁输出任何引号、前缀标签、解释说明、思考过程或多余空行。
    2. 严禁在译文中间插入换行符，全部译文必须作为单行连续文本输出（由客户端界面自适应折行）。
    3. 严格参考【前文背景】中的双语对照关系，保持专业术语、人名译法和人称代词（他/她/它）前后一致，但绝不要重复翻译【前文背景】中的句子。
    4. 若提供了【当前句已上屏草稿】，在核心语义与肯定/否定极性未反转的前提下，优先沿用草稿前半句措辞以减少屏幕闪烁；若后文出现倒装从句或语义反转，则以准确自然为先重排全句。
    5. 若原文已经是通顺的中文，原样输出即可。
    【实时切分】输入是实时字幕切开的片段，末尾可能停在一句话中间，标点也可能是识别补出的。若在连接词、介词、列表引导语处结束，不要补句号，也不要补全尚未出现的内容；只翻译已经出现的内容。
    """

    /// 所有语言共用的“片段不是完整句”约束。
    static let segmentRule = """
    【实时切分】输入是实时字幕切开的片段，末尾可能停在一句话中间，标点也可能是识别补出的。若在连接词、介词、列表引导语处结束，不要补句号，也不要补全尚未出现的内容；只翻译已经出现的内容。
    """

    /// 段落翻译才需要：多行可能是同一句话被切开。
    static let paragraphRule = """
    【同段片段】输入可能是同一段话被实时切成多行；请先合并为语义完整的段落，再翻译为中文。只在真正的句末使用句号，不要逐片段换行，也不要保留片段之间的生硬断句。
    """

    public static func systemInstructions(
        for preferredLanguage: CaptionSourceLanguage = .auto,
        glossary: CaptionGlossary = .empty,
        isParagraph: Bool = false
    ) -> String {
        let base: String
        switch preferredLanguage {
        case .english:
            base = """
            你是一个专业的实时视频中文字幕翻译引擎。源语言为英语。请将用户输入的【当前句】直接翻译为自然、简练、符合中文母语影视字幕习惯的简体中文。
            硬性规则：
            1. 只输出【当前句】对应的中文译文本身，严禁输出任何引号、前缀标签、解释说明、思考过程或多余空行。
            2. 严禁在译文中间插入换行符，必须将译文作为单行连续文本输出（由客户端界面自适应折行）。
            3. 重点重构长定语从句，语序自然流畅；精简口语口癖冗余（如 like, you know），措辞简明凝练。
            4. 严格参考【前文背景】中的双语对照关系，保持专业术语、人名译法和代词指代一致，但绝不要重复翻译【前文背景】中的句子。
            5. 若提供了【当前句已上屏草稿】，在核心语义与肯定/否定极性未反转的前提下，优先沿用草稿前半句措辞以减少屏幕闪烁；若后文出现倒装从句或语义反转，则以准确自然为先重排全句。
            6. 若原文已经是通顺的中文，原样输出即可。
            """
        case .japanese:
            base = """
            你是一个专业的实时视频中文字幕翻译引擎。源语言为日语（SOV结构）。请将用户输入的【当前句】直接翻译为自然、简练的简体中文。
            硬性规则：
            1. 只输出【当前句】对应的中文译文本身，严禁输出任何引号、前缀标签、解释说明、思考过程或多余空行。
            2. 严禁在译文中间插入换行符，必须将译文作为单行连续文本输出（由客户端界面自适应折行）。
            3. 注意句末谓语与否定形态；未闭合从句以名词短语或悬垂短语直译，切勿盲目脑补动作；严谨甄别日文借词异义（如「手紙」「大丈夫」「油断」切勿望文生义）。
            4. 严格参考【前文背景】中的双语对照关系，保持专业术语、人名译法和代词指代一致，但绝不要重复翻译【前文背景】中的句子。
            5. 若提供了【当前句已上屏草稿】，在核心语义与肯定/否定极性未反转的前提下，优先沿用草稿前半句措辞以减少屏幕闪烁；若后文出现倒装从句或语义反转，则以准确自然为先重排全句。
            6. 若原文已经是通顺的中文，原样输出即可。
            """
        case .korean:
            base = """
            你是一个专业的实时视频中文字幕翻译引擎。源语言为韩语（SOV结构）。请将用户输入的【当前句】直接翻译为自然、简练的简体中文。
            硬性规则：
            1. 只输出【当前句】对应的中文译文本身，严禁输出任何引号、前缀标签、解释说明、思考过程或多余空行。
            2. 严禁在译文中间插入换行符，必须将译文作为单行连续文本输出（由客户端界面自适应折行）。
            3. 注意韩语句末谓语、否定词尾与敬语语气；未闭合从句以名词短语或悬垂短语直译，切勿提前盲目脑补动作。
            4. 严格参考【前文背景】中的双语对照关系，保持专业术语、人名译法和代词指代一致，但绝不要重复翻译【前文背景】中的句子。
            5. 若提供了【当前句已上屏草稿】，在核心语义与肯定/否定极性未反转的前提下，优先沿用草稿前半句措辞以减少屏幕闪烁；若后文出现倒装从句或语义反转，则以准确自然为先重排全句。
            6. 若原文已经是通顺的中文，原样输出即可。
            """
        default:
            base = Self.systemInstructions
        }
        var result = base + glossary.promptSuffix
        if !result.contains("【实时切分】") {
            result += "\n\n" + Self.segmentRule
        }
        if isParagraph {
            result += "\n\n" + Self.paragraphRule
        }
        return result
    }

    private let makeClient: @MainActor () -> (any CaptionTranslationClient)?
    private let partialDebounce: Duration
    private let minimumPartialDeltaChars: Int
    /// 定稿翻译同时最多跑几条。慢模型时这是背压阀：定稿行会排队，而不是把
    /// 服务端塞满后所有请求一起变慢。按到达顺序完成，避免后句先于前句上屏。
    private let maximumConcurrentFinalTranslations: Int
    /// 定稿翻译等待队列的最大容量；超出时淘汰最旧的排队项，确保实时新段落不会被历史积压阻塞。
    private let maximumPendingFinalTranslations: Int
    private let signposter = OSSignposter(
        subsystem: "com.speechrail.desktop",
        category: "CaptionTranslation"
    )

    /// 只汇总延迟与计数，不记录原文/译文；每场会话独立。
    public private(set) var metrics = CaptionTranslationMetrics()

    public var onPartialTranslatingStateChange: (@MainActor (Bool) -> Void)?
    public private(set) var isTranslatingPartial = false {
        didSet {
            if oldValue != isTranslatingPartial {
                onPartialTranslatingStateChange?(isTranslatingPartial)
            }
        }
    }

    /// 当前已产出预览译文所对应的真实原文快照（优先返回流式在途译文的原文快照）。
    public var currentTranslatedSourceText: String? {
        if !inFlightPartialSourceText.isEmpty {
            return inFlightPartialSourceText
        }
        return lastPartialSourceText.isEmpty ? nil : lastPartialSourceText
    }

    private var partialTask: Task<Void, Never>?
    private var isPartialDebouncing = false
    private var isPartialRequestInFlight = false
    private var inFlightPartialSourceText: String = ""
    private var inFlightPartialTranslation: String?
    private var pendingPartialSourceText: String = ""
    private var pendingPartialContextLines: [String] = []
    private var pendingPartialDisplayMode: CaptionDisplayMode = .bilingual
    private var pendingPartialPreferredLanguage: CaptionSourceLanguage = .auto
    private var pendingPartialGlossary: CaptionGlossary = .empty
    private var latestPartialOnUpdate: (@MainActor (String?) -> Void)?
    private var lastPartialSourceText: String = ""
    private var lastPartialTranslation: String?
    /// 最近两次预览译文的 LocalAgreement 稳定前缀；只用于提示词软锚定和显示分层，
    /// 不承诺不可改写。
    public private(set) var stabilizedDraftPrefix: String?
    private var finalTasks: [String: Task<Void, Never>] = [:]
    private var recentCompletedTranslations: [String: String] = [:]
    private var recentCompletedOrder: [String] = []

    private struct FinalRequest {
        let lineID: String
        let sourceText: String
        let contextLines: [String]
        let client: any CaptionTranslationClient
        let instructions: String
        let draftForPrompt: String?
        let fallbackDraft: String?
        let detectedLanguageCode: String
        let requestedAt: Date
        let onStreamingUpdate: @MainActor (String, String) -> Void
        let onFinished: @MainActor (String, String?, String) async -> Void
    }

    private var finalQueue: [FinalRequest] = []
    public var pendingFinalTranslationCount: Int { finalQueue.count }
    private var runningFinalCount = 0
    /// 正在跑的行；同一行被重新请求时，新的排队项必须等旧任务真正退出再开跑。
    private var runningFinalLineIDs: Set<String> = []

    public init(
        partialDebounce: Duration = .milliseconds(450),
        minimumPartialDeltaChars: Int = 10,
        maximumConcurrentFinalTranslations: Int = 2,
        maximumPendingFinalTranslations: Int = 8,
        makeClient: @escaping @MainActor () -> (any CaptionTranslationClient)?
    ) {
        self.partialDebounce = partialDebounce
        self.minimumPartialDeltaChars = minimumPartialDeltaChars
        self.maximumConcurrentFinalTranslations = Swift.max(1, maximumConcurrentFinalTranslations)
        self.maximumPendingFinalTranslations = Swift.max(1, maximumPendingFinalTranslations)
        self.makeClient = makeClient
    }

    public func cancelPartial() {
        partialTask?.cancel()
        partialTask = nil
        isPartialDebouncing = false
        isPartialRequestInFlight = false
        isTranslatingPartial = false
        inFlightPartialSourceText = ""
        inFlightPartialTranslation = nil
        pendingPartialSourceText = ""
        pendingPartialContextLines = []
        pendingPartialGlossary = .empty
        latestPartialOnUpdate = nil
        lastPartialSourceText = ""
        lastPartialTranslation = nil
        stabilizedDraftPrefix = nil
    }

    public func cancelAll() {
        cancelPartial()
        for task in finalTasks.values { task.cancel() }
        finalTasks.removeAll()
        // 尚未开跑的排队请求不会自己走到 onFinished；补一次 nil 终态，
        // 把行上的「翻译中」清掉，但绝不把预览草稿当成定稿译文落库。
        let dropped = finalQueue
        finalQueue.removeAll()
        for request in dropped {
            Task { @MainActor in
                await request.onFinished(request.lineID, nil, request.detectedLanguageCode)
            }
        }
        recentCompletedTranslations.removeAll()
        recentCompletedOrder.removeAll()
    }

    /// 收尾时先给在途定稿一次完成机会，再取消；否则最后一段会在
    /// `flushOpenParagraph` 刚启动后被 `cancelAll` 立刻打断。
    public func drainFinalTranslations(timeout: Duration = .seconds(2)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !finalQueue.isEmpty || !finalTasks.isEmpty {
            if clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 新一场字幕开始时清空上一场的延迟样本；历史记录不参与。
    public func resetMetrics() {
        metrics = CaptionTranslationMetrics()
    }

    private func recordCompletedTranslation(sourceText: String, translatedText: String) {
        let key = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let val = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !val.isEmpty, key != val else { return }
        if recentCompletedTranslations[key] == nil {
            recentCompletedOrder.append(key)
            if recentCompletedOrder.count > 12 {
                let oldest = recentCompletedOrder.removeFirst()
                recentCompletedTranslations.removeValue(forKey: oldest)
            }
        }
        recentCompletedTranslations[key] = val
    }

    /// 若入参 `contextLines` 因前一句并发 Stage 2 尚未收口而只带了 `原文：xxx`，用已完成的译文缓存自动补全双语对照。
    private func enrichContextLines(_ lines: [String]) -> [String] {
        lines.map { line in
            guard line.hasPrefix("原文："), !line.contains(" → 译文：") else { return line }
            let src = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let tgt = recentCompletedTranslations[src], !tgt.isEmpty {
                return "原文：\(src) → 译文：\(tgt)"
            }
            return line
        }
    }

    /// 计算相邻两次译文的 LocalAgreement-2 稳定前缀。
    ///
    /// 回退末尾 `rollbackChars` 个字符，给句尾语法调整留余量；公共前缀太短时返回 `nil`。
    public static func localAgreementPrefix(
        _ previous: String,
        _ current: String,
        rollbackChars: Int = 2
    ) -> String? {
        let common = previous.commonPrefix(with: current).trimmingCharacters(in: .whitespacesAndNewlines)
        guard common.count > rollbackChars else { return nil }
        return String(common.dropLast(rollbackChars))
    }

    /// Stage 1：当外语 partial 增长时，节流触发单飞预览翻译。
    public func schedulePartialTranslation(
        sourceText: String,
        contextLines: [String],
        displayMode: CaptionDisplayMode,
        preferredLanguage: CaptionSourceLanguage = .auto,
        glossary: CaptionGlossary = .empty,
        onUpdate: @escaping @MainActor (String?) -> Void
    ) {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, displayMode != .originalOnly else {
            cancelPartial()
            onUpdate(nil)
            return
        }

        let isChinese: Bool
        switch preferredLanguage {
        case .chinese:
            isChinese = true
        case .english, .japanese, .korean:
            isChinese = false
        case .auto:
            isChinese = CaptionLanguageDetector.detect(for: trimmed).isChinese
        }

        if isChinese {
            cancelPartial()
            onUpdate(nil)
            return
        }

        // 实时刷新待翻快照与最新回调，确保防抖结束或当前在途流收口后直接消费最新完整句子。
        pendingPartialSourceText = trimmed
        pendingPartialContextLines = Array(contextLines.suffix(2))
        pendingPartialDisplayMode = displayMode
        pendingPartialPreferredLanguage = preferredLanguage
        pendingPartialGlossary = glossary
        latestPartialOnUpdate = onUpdate

        // 关键防饿死保护：若上一轮 Stage 1 已经结束防抖、正在接收/等待 LLM 流式增量，
        // 且当前新到达的 partial 仍是同一句话的順延增长（共享公共前缀），绝不中途 cancel 在途请求！
        // 否则连续语流每 0.5s 新增 10 个字符就会无限打断在途流，导致整句 10 秒内没有任何预览译文产出。
        if isPartialRequestInFlight, !inFlightPartialSourceText.isEmpty {
            let sharedPrefixCount = trimmed.commonPrefix(with: inFlightPartialSourceText).count
            let isContinuation = trimmed.hasPrefix(inFlightPartialSourceText)
                || sharedPrefixCount >= Swift.min(8, Swift.max(4, inFlightPartialSourceText.count - 3))
            if isContinuation {
                return
            }
        }

        let charDelta = abs(trimmed.count - lastPartialSourceText.count)
        let endsWithClauseBoundary = trimmed.last.map { ",.;?!，。；？！、".contains($0) } ?? false
        guard charDelta >= minimumPartialDeltaChars || endsWithClauseBoundary else { return }

        launchPartialTask(initialSourceSnapshot: trimmed)
    }

    private func launchPartialTask(initialSourceSnapshot: String) {
        guard let client = makeClient() else {
            isTranslatingPartial = false
            return
        }
        lastPartialSourceText = initialSourceSnapshot
        let debounce = partialDebounce
        let priorDraft = stabilizedDraftPrefix ?? lastPartialTranslation
        let preferredLanguage = pendingPartialPreferredLanguage
        let instructions = Self.systemInstructions(
            for: preferredLanguage,
            glossary: pendingPartialGlossary
        )

        partialTask?.cancel()
        isPartialDebouncing = true
        isPartialRequestInFlight = false
        isTranslatingPartial = (lastPartialTranslation == nil && inFlightPartialTranslation == nil)
        partialTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
                guard let self else { return }
                self.isPartialDebouncing = false
                self.isPartialRequestInFlight = true
                self.metrics.previewRequests += 1
                let previewStartedAt = Date()
                var previewFirstDeltaRecorded = false
                let latestSource = self.pendingPartialSourceText.isEmpty
                    ? initialSourceSnapshot
                    : self.pendingPartialSourceText
                let latestContext = self.enrichContextLines(self.pendingPartialContextLines)
                self.inFlightPartialSourceText = latestSource
                self.lastPartialSourceText = latestSource
                var accumulated = ""
                for try await delta in client.translateStream(
                    sourceText: latestSource,
                    contextLines: latestContext,
                    priorDraftTranslation: priorDraft,
                    systemInstructions: instructions
                ) {
                    try Task.checkCancellation()
                    accumulated += delta
                    let cleaned = Self.cleanSubtitleOutput(accumulated)
                    if !cleaned.isEmpty {
                        if !previewFirstDeltaRecorded {
                            previewFirstDeltaRecorded = true
                            self.metrics.previewFirstDelta.record(
                                milliseconds: Int(Date().timeIntervalSince(previewStartedAt) * 1_000)
                            )
                        }
                        self.isTranslatingPartial = false
                        self.inFlightPartialTranslation = cleaned
                        self.latestPartialOnUpdate?(cleaned)
                    }
                }
                self.isPartialRequestInFlight = false
                self.isTranslatingPartial = false
                // 被定稿提交或新预览取消时，流可能正常结束而不是抛错；此时不能记成完成/失败。
                guard !Task.isCancelled else { return }
                let finalPartial = Self.cleanSubtitleOutput(accumulated)
                if finalPartial.isEmpty {
                    self.metrics.previewFailed += 1
                } else {
                    self.metrics.previewCompleted += 1
                    self.metrics.previewStability.record(
                        previous: self.lastPartialTranslation,
                        current: finalPartial
                    )
                    if let previous = self.lastPartialTranslation {
                        self.stabilizedDraftPrefix = Self.localAgreementPrefix(previous, finalPartial)
                    }
                    self.lastPartialTranslation = finalPartial
                    self.inFlightPartialTranslation = finalPartial
                }
                // 若在流式请求期间，源文本又继续增长跨过了阈值，自动衔接下一轮 Stage 1 预览
                let newestPending = self.pendingPartialSourceText
                if !newestPending.isEmpty, newestPending != latestSource {
                    let followUpDelta = abs(newestPending.count - latestSource.count)
                    let endsWithClause = newestPending.last.map { ",.;?!，。；？！、".contains($0) } ?? false
                    if followUpDelta >= self.minimumPartialDeltaChars || endsWithClause {
                        self.launchPartialTask(initialSourceSnapshot: newestPending)
                    }
                }
            } catch {
                self?.isPartialDebouncing = false
                self?.isPartialRequestInFlight = false
                self?.isTranslatingPartial = false
                if !(error is CancellationError) {
                    self?.lastPartialSourceText = ""
                    self?.metrics.previewFailed += 1
                }
            }
        }
    }

    /// 校验未定稿草稿的原文是否确实是当前定稿句的前身，防止上一句残留草稿串入新句。
    private static func draftMatchesSource(partialSource: String, completedSource: String) -> Bool {
        let p = partialSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = completedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.count >= 4, c.count >= 4 else { return false }
        if p == c || c.hasPrefix(p) || p.hasPrefix(c) { return true }
        let shorter = Swift.min(p.count, c.count)
        let shared = p.commonPrefix(with: c).count
        if shared >= Swift.max(4, shorter - 2) { return true }
        if shorter >= 12, shared >= Swift.max(8, Int(Double(shorter) * 0.6)) { return true }
        return false
    }

    /// Stage 2：当句子定稿（completed / sealed）时，取消 partial 预览并携带前 3 句双语平行上下文精翻。
    ///
    /// 终态一定回调 `onFinished`：失败时用已到达前缀或 Stage 1 草稿兜底，绝不把行留在「翻译中」。
    public func translateCompletedLine(
        lineID: String,
        sourceText: String,
        contextLines: [String],
        displayMode: CaptionDisplayMode,
        preferredLanguage: CaptionSourceLanguage = .auto,
        priorDraftHint: String? = nil,
        /// 定稿文本到达的时间；用于把落库等待和队列等待一起算进首字延迟。
        requestedAt: Date = Date(),
        glossary: CaptionGlossary = .empty,
        /// 多行合并后的段落翻译；单行仍为 false。
        isParagraph: Bool = false,
        onStreamingUpdate: @escaping @MainActor (String, String) -> Void,
        onFinished: @escaping @MainActor (String, String?, String) async -> Void
    ) {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateSource = !inFlightPartialSourceText.isEmpty ? inFlightPartialSourceText : lastPartialSourceText
        let coordinatorDraft: String?
        let coordinatorStabilized: String?
        if candidateSource.isEmpty || Self.draftMatchesSource(partialSource: candidateSource, completedSource: trimmed) {
            coordinatorDraft = lastPartialTranslation ?? inFlightPartialTranslation
            coordinatorStabilized = stabilizedDraftPrefix
        } else {
            coordinatorDraft = nil
            coordinatorStabilized = nil
        }
        // 即使 Stage 1 在流式中途被定稿事件打断，也保留已流式产出的草稿或会话层传入的 `priorDraftHint` 作为保底
        let fallbackDraft = coordinatorDraft ?? priorDraftHint
        let draftForPrompt = coordinatorStabilized ?? fallbackDraft
        cancelPartial()
        let isChinese: Bool
        let detectedLanguageCode: String
        switch preferredLanguage {
        case .chinese:
            isChinese = true
            detectedLanguageCode = "zh"
        case .english:
            isChinese = false
            detectedLanguageCode = "en"
        case .japanese:
            isChinese = false
            detectedLanguageCode = "ja"
        case .korean:
            isChinese = false
            detectedLanguageCode = "ko"
        case .auto:
            let detection = CaptionLanguageDetector.detect(for: trimmed)
            isChinese = detection.isChinese
            detectedLanguageCode = detection.languageCode
        }

        // 中文音频或仅原文模式：0 延迟直通，只记录语种标签，不调大模型。
        guard !isChinese, displayMode != .originalOnly else {
            Task { @MainActor in
                await onFinished(lineID, nil, detectedLanguageCode)
            }
            return
        }

        guard let client = makeClient() else {
            Task { @MainActor in
                await onFinished(lineID, fallbackDraft, detectedLanguageCode)
            }
            return
        }

        let instructions = Self.systemInstructions(
            for: preferredLanguage,
            glossary: glossary,
            isParagraph: isParagraph
        )

        enqueueFinal(
            FinalRequest(
                lineID: lineID,
                sourceText: trimmed,
                contextLines: contextLines,
                client: client,
                instructions: instructions,
                draftForPrompt: draftForPrompt,
                fallbackDraft: fallbackDraft,
                detectedLanguageCode: detectedLanguageCode,
                requestedAt: requestedAt,
                onStreamingUpdate: onStreamingUpdate,
                onFinished: onFinished
            )
        )
    }

    /// 定稿翻译的有界队列：按到达顺序执行，最多 `maximumConcurrentFinalTranslations` 条在途。
    ///
    /// 慢模型（本地单 worker 或远端限流）下，无上限并发只会让每条请求都变慢，还会让
    /// 后句先于前句上屏。这里用有界队列做背压；同一行被重新请求时替换未开跑的旧请求。
    private func enqueueFinal(_ request: FinalRequest) {
        finalQueue.removeAll { $0.lineID == request.lineID }
        finalTasks[request.lineID]?.cancel()
        finalQueue.append(request)
        pumpFinalQueue()
        while finalQueue.count > maximumPendingFinalTranslations {
            let evicted = finalQueue.removeFirst()
            metrics.finalCancelled += 1
            Task { @MainActor in
                await evicted.onFinished(evicted.lineID, evicted.fallbackDraft, evicted.detectedLanguageCode)
            }
        }
    }

    private func pumpFinalQueue() {
        while runningFinalCount < maximumConcurrentFinalTranslations {
            guard let index = finalQueue.firstIndex(where: {
                !runningFinalLineIDs.contains($0.lineID)
            }) else { return }
            let request = finalQueue.remove(at: index)
            runningFinalCount += 1
            runningFinalLineIDs.insert(request.lineID)
            metrics.finalRequests += 1
            finalTasks[request.lineID] = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runFinal(request)
            }
        }
    }

    private func runFinal(_ request: FinalRequest) async {
        defer {
            runningFinalCount = Swift.max(0, runningFinalCount - 1)
            runningFinalLineIDs.remove(request.lineID)
            finalTasks[request.lineID] = nil
            pumpFinalQueue()
        }
        let queueWait = elapsedMilliseconds(since: request.requestedAt)
        metrics.finalQueueWait.record(milliseconds: queueWait)
        var firstDelta: Int?
        var accumulated = ""
        var attempts = 0

        for attempt in 0..<2 {
            attempts = attempt + 1
            do {
                try Task.checkCancellation()
                let enrichedContext = enrichContextLines(Array(request.contextLines.suffix(3)))
                let stream = request.client.translateStream(
                    sourceText: request.sourceText,
                    contextLines: enrichedContext,
                    priorDraftTranslation: request.draftForPrompt,
                    systemInstructions: request.instructions
                )
                for try await delta in stream {
                    try Task.checkCancellation()
                    accumulated += delta
                    let cleaned = Self.cleanSubtitleOutput(accumulated)
                    if !cleaned.isEmpty {
                        if firstDelta == nil {
                            let value = elapsedMilliseconds(since: request.requestedAt)
                            firstDelta = value
                            metrics.finalFirstDelta.record(milliseconds: value)
                        }
                        request.onStreamingUpdate(request.lineID, cleaned)
                    }
                }
                let finalCleaned = Self.cleanSubtitleOutput(accumulated)
                if !finalCleaned.isEmpty {
                    recordCompletedTranslation(sourceText: request.sourceText, translatedText: finalCleaned)
                    metrics.finalStability.record(
                        previous: request.draftForPrompt,
                        current: finalCleaned
                    )
                    let total = elapsedMilliseconds(since: request.requestedAt)
                    metrics.finalCompleted += 1
                    metrics.finalCompletion.record(milliseconds: total)
                    emitFinalSignpost(
                        outcome: "translated", queueWait: queueWait,
                        firstDelta: firstDelta, total: total, attempts: attempts
                    )
                    await request.onFinished(request.lineID, finalCleaned, request.detectedLanguageCode)
                    return
                }
                if attempt == 0 {
                    accumulated = ""
                    try await Task.sleep(for: .milliseconds(120))
                    continue
                }
            } catch {
                if error is CancellationError {
                    metrics.finalCancelled += 1
                    emitFinalSignpost(
                        outcome: "cancelled", queueWait: queueWait,
                        firstDelta: firstDelta,
                        total: elapsedMilliseconds(since: request.requestedAt),
                        attempts: attempts
                    )
                    let salvaged = Self.cleanSubtitleOutput(accumulated)
                    await request.onFinished(
                        request.lineID,
                        salvaged.isEmpty ? request.fallbackDraft : salvaged,
                        request.detectedLanguageCode
                    )
                    return
                }
                let salvaged = Self.cleanSubtitleOutput(accumulated)
                // 若一个字都还没吐出就遭遇网络瞬态抖动，自动快速重试一次
                if salvaged.isEmpty, attempt == 0 {
                    accumulated = ""
                    try? await Task.sleep(for: .milliseconds(120))
                    if !Task.isCancelled { continue }
                }
                let resolved = salvaged.isEmpty ? request.fallbackDraft : salvaged
                if let resolved, !resolved.isEmpty {
                    recordCompletedTranslation(sourceText: request.sourceText, translatedText: resolved)
                }
                let total = elapsedMilliseconds(since: request.requestedAt)
                metrics.finalFailed += 1
                metrics.finalCompletion.record(milliseconds: total)
                emitFinalSignpost(
                    outcome: "fallback", queueWait: queueWait,
                    firstDelta: firstDelta, total: total, attempts: attempts
                )
                await request.onFinished(request.lineID, resolved, request.detectedLanguageCode)
                return
            }
        }
        if let fallback = request.fallbackDraft, !fallback.isEmpty {
            recordCompletedTranslation(sourceText: request.sourceText, translatedText: fallback)
        }
        let total = elapsedMilliseconds(since: request.requestedAt)
        metrics.finalFailed += 1
        metrics.finalCompletion.record(milliseconds: total)
        emitFinalSignpost(
            outcome: "empty", queueWait: queueWait,
            firstDelta: firstDelta, total: total, attempts: attempts
        )
        await request.onFinished(request.lineID, request.fallbackDraft, request.detectedLanguageCode)
    }

    private func elapsedMilliseconds(since date: Date) -> Int {
        Swift.max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }

    private func emitFinalSignpost(
        outcome: String, queueWait: Int, firstDelta: Int?, total: Int, attempts: Int
    ) {
        guard signposter.isEnabled else { return }
        signposter.emitEvent(
            "FinalTranslation",
            "outcome=\(outcome) queue_ms=\(queueWait) first_delta_ms=\(firstDelta.map { String($0) } ?? "none") total_ms=\(total) attempts=\(attempts)"
        )
    }

    public static func buildUserPrompt(
        sourceText: String,
        contextLines: [String],
        priorDraftTranslation: String? = nil
    ) -> String {
        var sections: [String] = []
        if !contextLines.isEmpty {
            let contextJoined = contextLines.joined(separator: "\n")
            sections.append("【前文背景（仅供参考语境与专名译法，切勿重复翻译）】\n\(contextJoined)")
        }
        if let draft = priorDraftTranslation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !draft.isEmpty {
            sections.append("【当前句已上屏草稿（若核心语义未反转请尽量保持前半句稳定）】\n\(draft)")
        }
        sections.append("【当前句（请仅将此句译为简练中文字幕）】\n\(sourceText)")
        return sections.joined(separator: "\n\n")
    }

    nonisolated public static func cleanSubtitleOutput(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 剥离推理模型可能附带的 <think>...</think> 思考块；流式未闭合时暂不输出思考内容
        while let openRange = text.range(of: "<think>", options: .caseInsensitive) {
            if let closeRange = text.range(
                of: "</think>",
                options: .caseInsensitive,
                range: openRange.upperBound..<text.endIndex
            ) {
                text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = String(text[..<openRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        for prefix in [
            "【当前句（请仅将此句译为简练中文字幕）】",
            "【当前句】",
            "【译文】",
            "译文：",
            "翻译：",
            "译文:",
            "翻译:"
        ] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if text.count >= 2 {
            let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」")]
            for (openQuote, closeQuote) in pairs where text.first == openQuote && text.last == closeQuote {
                let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty, !inner.contains(openQuote), !inner.contains(closeQuote) {
                    text = inner
                    break
                }
            }
        }
        return mergeNewlines(text)
    }

    nonisolated private static func isCJKOrPunctuation(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) ||
               (0x3400...0x4DBF).contains(v) ||
               (0x20000...0x2A6DF).contains(v) ||
               (0x3000...0x303F).contains(v) ||
               (0xFF00...0xFFEF).contains(v) ||
               (0x3040...0x30FF).contains(v) ||
               (0xAC00...0xD7AF).contains(v) ||
               (0x1100...0x11FF).contains(v) {
                return true
            }
        }
        return false
    }

    nonisolated private static func mergeNewlines(_ text: String) -> String {
        guard text.contains("\n") || text.contains("\r") else { return text }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        var result = lines[0]
        for line in lines.dropFirst() {
            guard let prevChar = result.last, let nextChar = line.first else {
                result += line
                continue
            }
            if isCJKOrPunctuation(prevChar) || isCJKOrPunctuation(nextChar) {
                result += line
            } else {
                result += " " + line
            }
        }
        return result
    }
}
