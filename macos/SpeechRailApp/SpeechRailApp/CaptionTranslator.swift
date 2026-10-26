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

    private var partialTask: Task<Void, Never>?
    private var isPartialDebouncing = false
    private var pendingPartialSourceText: String = ""
    private var pendingPartialContextLines: [String] = []
    private var lastPartialSourceText: String = ""
    private var lastPartialTranslation: String?
    private var stabilizedDraftPrefix: String?
    private var finalTasks: [String: Task<Void, Never>] = [:]

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
        pendingPartialSourceText = ""
        pendingPartialContextLines = []
        lastPartialSourceText = ""
        lastPartialTranslation = nil
        stabilizedDraftPrefix = nil
    }

    public func cancelAll() {
        cancelPartial()
        for task in finalTasks.values { task.cancel() }
        finalTasks.removeAll()
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

        // 防抖睡眠期间到达的新增文本实时刷新待翻快照，确保防抖结束时发送最新完整前缀而非旧快照。
        pendingPartialSourceText = trimmed
        pendingPartialContextLines = Array(contextLines.suffix(2))

        let charDelta = abs(trimmed.count - lastPartialSourceText.count)
        let endsWithClauseBoundary = trimmed.last.map { ",.;?!，。；？！、".contains($0) } ?? false
        guard charDelta >= minimumPartialDeltaChars || endsWithClauseBoundary else { return }

        guard let client = makeClient() else { return }
        lastPartialSourceText = trimmed
        let debounce = partialDebounce
        // 软锚定：上一轮草稿（或已稳定前缀）随提示词下发，模型可重排但不该无理由换词。
        let priorDraft = stabilizedDraftPrefix ?? lastPartialTranslation
        let instructions = Self.systemInstructions(for: preferredLanguage)

        partialTask?.cancel()
        isPartialDebouncing = true
        partialTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
                guard let self else { return }
                self.isPartialDebouncing = false
                let latestSource = self.pendingPartialSourceText.isEmpty ? trimmed : self.pendingPartialSourceText
                let latestContext = self.pendingPartialContextLines
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
                        onUpdate(cleaned)
                    }
                }
                let finalPartial = Self.cleanSubtitleOutput(accumulated)
                guard !finalPartial.isEmpty else { return }
                if let previous = self.lastPartialTranslation {
                    self.stabilizedDraftPrefix = Self.localAgreementPrefix(previous, finalPartial)
                }
                self.lastPartialTranslation = finalPartial
            } catch {
                self?.isPartialDebouncing = false
                if !(error is CancellationError) {
                    self?.lastPartialSourceText = ""
                }
            }
        }
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
        onStreamingUpdate: @escaping @MainActor (String, String) -> Void,
        onFinished: @escaping @MainActor (String, String?, String) async -> Void
    ) {
        let fallbackDraft = lastPartialTranslation
        let draftForPrompt = stabilizedDraftPrefix ?? lastPartialTranslation
        cancelPartial()

        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            do {
                let stream = client.translateStream(
                    sourceText: trimmed,
                    contextLines: Array(contextLines.suffix(3)),
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
                await onFinished(
                    lineID,
                    finalCleaned.isEmpty ? fallbackDraft : finalCleaned,
                    detectedLanguageCode
                )
            } catch {
                // 网络抖动或超时时兜底保留已流式到达的前缀或 Stage 1 预览译文，绝不退回空白。
                let salvaged = Self.cleanSubtitleOutput(accumulated)
                await onFinished(
                    lineID,
                    salvaged.isEmpty ? fallbackDraft : salvaged,
                    detectedLanguageCode
                )
            }
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
        for prefix in ["【当前句】", "【译文】", "译文：", "翻译："] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}
