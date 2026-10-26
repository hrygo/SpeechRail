import Foundation
import NaturalLanguage

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
    1. 只输出【当前句】对应的中文译文本身，严禁输出任何引号、前缀标签、解释说明或思考过程。
    2. 严格参考【前文背景】中的双语对照关系，保持专业术语、人名译法和人称代词（他/她/它）前后一致，但绝不要重复翻译【前文背景】中的句子。
    3. 若提供了【当前句已上屏草稿】，在核心语义与肯定/否定极性未反转的前提下，优先沿用草稿前半句措辞以减少屏幕闪烁；若后文出现倒装从句或语义反转，则以准确自然为先重排全句。
    4. 若原文已经是通顺的中文，原样输出即可。
    """

    public static func systemInstructions(for preferredLanguage: CaptionSourceLanguage = .auto) -> String {
        switch preferredLanguage {
        case .english:
            return """
            你是一个专业的实时视频中文字幕翻译引擎。源语言为英语。请将用户输入的【当前句】直接翻译为自然、简练、符合中文母语影视字幕习惯的简体中文。
            硬性规则：
            1. 只输出【当前句】对应的中文译文本身，严禁输出任何引号、前缀标签、解释说明或思考过程。
            2. 重点重构长定语从句，语序自然流畅；精简口语口癖冗余（如 like, you know）；保持单行不超过 15 汉字的紧凑影视字幕节奏。
            3. 严格参考【前文背景】中的双语对照关系，保持专业术语、人名译法和代词指代一致，但绝不要重复翻译【前文背景】中的句子。
            4. 若提供了【当前句已上屏草稿】，在核心语义与肯定/否定极性未反转的前提下，优先沿用草稿前半句措辞以减少屏幕闪烁；若后文出现倒装从句或语义反转，则以准确自然为先重排全句。
            5. 若原文已经是通顺的中文，原样输出即可。
            """
        case .japanese:
            return """
            你是一个专业的实时视频中文字幕翻译引擎。源语言为日语（SOV结构）。请将用户输入的【当前句】直接翻译为自然、简练的简体中文。
            硬性规则：
            1. 只输出【当前句】对应的中文译文本身，严禁输出任何引号、前缀标签、解释说明或思考过程。
            2. 注意句末谓语与否定形态；未闭合从句以名词短语或悬垂短语直译，切勿盲目脑补动作；严谨甄别日文借词异义（如「手紙」「大丈夫」「油断」切勿望文生义）。
            3. 严格参考【前文背景】中的双语对照关系，保持专业术语、人名译法和代词指代一致，但绝不要重复翻译【前文背景】中的句子。
            4. 若提供了【当前句已上屏草稿】，在核心语义与肯定/否定极性未反转的前提下，优先沿用草稿前半句措辞以减少屏幕闪烁；若后文出现倒装从句或语义反转，则以准确自然为先重排全句。
            5. 若原文已经是通顺的中文，原样输出即可。
            """
        case .korean:
            return """
            你是一个专业的实时视频中文字幕翻译引擎。源语言为韩语（SOV结构）。请将用户输入的【当前句】直接翻译为自然、简练的简体中文。
            硬性规则：
            1. 只输出【当前句】对应的中文译文本身，严禁输出任何引号、前缀标签、解释说明或思考过程。
            2. 注意韩语句末谓语、否定词尾与敬语语气；未闭合从句以名词短语或悬垂短语直译，切勿提前盲目脑补动作。
            3. 严格参考【前文背景】中的双语对照关系，保持专业术语、人名译法和代词指代一致，但绝不要重复翻译【前文背景】中的句子。
            4. 若提供了【当前句已上屏草稿】，在核心语义与肯定/否定极性未反转的前提下，优先沿用草稿前半句措辞以减少屏幕闪烁；若后文出现倒装从句或语义反转，则以准确自然为先重排全句。
            5. 若原文已经是通顺的中文，原样输出即可。
            """
        default:
            return Self.systemInstructions
        }
    }

    private let makeClient: @MainActor () -> (any CaptionTranslationClient)?
    private let partialDebounce: Duration
    private let minimumPartialDeltaChars: Int

    public var onPartialTranslatingStateChange: (@MainActor (Bool) -> Void)?
    public private(set) var isTranslatingPartial = false {
        didSet {
            if oldValue != isTranslatingPartial {
                onPartialTranslatingStateChange?(isTranslatingPartial)
            }
        }
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
    private var latestPartialOnUpdate: (@MainActor (String?) -> Void)?
    private var lastPartialSourceText: String = ""
    private var lastPartialTranslation: String?
    private var stabilizedDraftPrefix: String?
    private var finalTasks: [String: Task<Void, Never>] = [:]
    private var recentCompletedTranslations: [String: String] = [:]
    private var recentCompletedOrder: [String] = []

    public init(
        partialDebounce: Duration = .milliseconds(450),
        minimumPartialDeltaChars: Int = 10,
        makeClient: @escaping @MainActor () -> (any CaptionTranslationClient)?
    ) {
        self.partialDebounce = partialDebounce
        self.minimumPartialDeltaChars = minimumPartialDeltaChars
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
        latestPartialOnUpdate = nil
        lastPartialSourceText = ""
        lastPartialTranslation = nil
        stabilizedDraftPrefix = nil
    }

    public func cancelAll() {
        cancelPartial()
        for task in finalTasks.values { task.cancel() }
        finalTasks.removeAll()
        recentCompletedTranslations.removeAll()
        recentCompletedOrder.removeAll()
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
        let instructions = Self.systemInstructions(for: preferredLanguage)

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
                        self.isTranslatingPartial = false
                        self.inFlightPartialTranslation = cleaned
                        self.latestPartialOnUpdate?(cleaned)
                    }
                }
                self.isPartialRequestInFlight = false
                self.isTranslatingPartial = false
                let finalPartial = Self.cleanSubtitleOutput(accumulated)
                if !finalPartial.isEmpty {
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
                }
            }
        }
    }

    /// 校验未定稿草稿的原文是否确实是当前定稿句的前身，防止上一句残留草稿串入新句。
    private static func draftMatchesSource(partialSource: String, completedSource: String) -> Bool {
        let p = partialSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = completedSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !c.isEmpty else { return false }
        if p == c || c.hasPrefix(p) || p.hasPrefix(c) { return true }
        let shared = p.commonPrefix(with: c).count
        return shared >= Swift.max(4, Swift.min(p.count, c.count) - 2)
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

        let instructions = Self.systemInstructions(for: preferredLanguage)

        finalTasks[lineID]?.cancel()
        finalTasks[lineID] = Task { @MainActor [weak self] in
            defer { self?.finalTasks[lineID] = nil }
            var accumulated = ""
            for attempt in 0..<2 {
                do {
                    try Task.checkCancellation()
                    let enrichedContext = self?.enrichContextLines(Array(contextLines.suffix(3)))
                        ?? Array(contextLines.suffix(3))
                    let stream = client.translateStream(
                        sourceText: trimmed,
                        contextLines: enrichedContext,
                        priorDraftTranslation: draftForPrompt,
                        systemInstructions: instructions
                    )
                    for try await delta in stream {
                        try Task.checkCancellation()
                        accumulated += delta
                        let cleaned = Self.cleanSubtitleOutput(accumulated)
                        if !cleaned.isEmpty {
                            onStreamingUpdate(lineID, cleaned)
                        }
                    }
                    let finalCleaned = Self.cleanSubtitleOutput(accumulated)
                    if !finalCleaned.isEmpty {
                        self?.recordCompletedTranslation(sourceText: trimmed, translatedText: finalCleaned)
                        await onFinished(lineID, finalCleaned, detectedLanguageCode)
                        return
                    }
                    if attempt == 0 {
                        accumulated = ""
                        try await Task.sleep(for: .milliseconds(120))
                        continue
                    }
                } catch {
                    if error is CancellationError {
                        let salvaged = Self.cleanSubtitleOutput(accumulated)
                        await onFinished(
                            lineID,
                            salvaged.isEmpty ? fallbackDraft : salvaged,
                            detectedLanguageCode
                        )
                        return
                    }
                    let salvaged = Self.cleanSubtitleOutput(accumulated)
                    // 若一个字都还没吐出就遭遇网络瞬态抖动，自动快速重试一次
                    if salvaged.isEmpty, attempt == 0 {
                        accumulated = ""
                        try? await Task.sleep(for: .milliseconds(120))
                        if !Task.isCancelled {
                            continue
                        }
                    }
                    let resolved = salvaged.isEmpty ? fallbackDraft : salvaged
                    if let resolved, !resolved.isEmpty {
                        self?.recordCompletedTranslation(sourceText: trimmed, translatedText: resolved)
                    }
                    await onFinished(
                        lineID,
                        resolved,
                        detectedLanguageCode
                    )
                    return
                }
            }
            if let fallbackDraft, !fallbackDraft.isEmpty {
                self?.recordCompletedTranslation(sourceText: trimmed, translatedText: fallbackDraft)
            }
            await onFinished(lineID, fallbackDraft, detectedLanguageCode)
        }
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

    public static func cleanSubtitleOutput(_ raw: String) -> String {
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
        return text
    }
}
