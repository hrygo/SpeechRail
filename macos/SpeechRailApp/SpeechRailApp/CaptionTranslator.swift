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

        // 注意：日语假名（0x3040...0x30FF）不计入 cjkCount。
        // 若存在平假名/片假名，直接识别为日语（需翻译为中文）。
        let hasKana = trimmed.unicodeScalars.contains {
            (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
        }
        if hasKana {
            return DetectionResult(languageCode: "ja", isChinese: false)
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

/// 翻译引擎抽象协议：生产环境注入 `LLMProvider`，单测注入确定性 Fake。
@MainActor
public protocol CaptionTranslationClient: Sendable {
    func translateStream(
        sourceText: String,
        contextLines: [String]
    ) -> AsyncThrowingStream<String, any Error>
}

/// 实时字幕双阶段流式翻译协调器（Stage 1: Partial 节流预览 + Stage 2: Completed 上下文精翻）。
@MainActor
public final class CaptionTranslationCoordinator {
    public static let systemInstructions = """
    你是一个专业的实时视频中文字幕翻译引擎。请将用户输入的【当前句】直接翻译为自然、简练、符合中文母语影视字幕习惯的简体中文。
    硬性规则：
    1. 只输出【当前句】对应的中文译文本身，严禁输出任何引号、前缀标签、解释说明或思考过程。
    2. 参考【前文背景】保持专业术语、人名和代词指代一致，但绝不要重复翻译【前文背景】中的句子。
    3. 若原文已经是通顺的中文，原样输出即可。
    """

    private let makeClient: @MainActor () -> (any CaptionTranslationClient)?
    private let partialDebounce: Duration
    private let minimumPartialDeltaChars: Int

    private var partialTask: Task<Void, Never>?
    private var lastPartialSourceText: String = ""
    private var lastPartialTriggeredAt: ContinuousClock.Instant?
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

    public func cancelAll() {
        partialTask?.cancel()
        partialTask = nil
        lastPartialSourceText = ""
        lastPartialTriggeredAt = nil
        for task in finalTasks.values { task.cancel() }
        finalTasks.removeAll()
    }

    /// Stage 1：当外语 partial 增长时，节流触发单飞预览翻译。
    public func schedulePartialTranslation(
        sourceText: String,
        contextLines: [String],
        displayMode: CaptionDisplayMode,
        onUpdate: @escaping @MainActor (String?) -> Void
    ) {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, displayMode != .originalOnly else {
            partialTask?.cancel()
            partialTask = nil
            onUpdate(nil)
            return
        }

        let detection = CaptionLanguageDetector.detect(for: trimmed)
        if detection.isChinese {
            partialTask?.cancel()
            partialTask = nil
            onUpdate(nil)
            return
        }

        let charDelta = abs(trimmed.count - lastPartialSourceText.count)
        let endsWithClauseBoundary = trimmed.last.map { ",.;?!，。；？！、".contains($0) } ?? false
        guard charDelta >= minimumPartialDeltaChars || endsWithClauseBoundary else { return }

        guard let client = makeClient() else { return }
        lastPartialSourceText = trimmed
        let debounce = partialDebounce

        partialTask?.cancel()
        partialTask = Task { @MainActor in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
                var accumulated = ""
                for try await delta in client.translateStream(sourceText: trimmed, contextLines: Array(contextLines.suffix(2))) {
                    try Task.checkCancellation()
                    accumulated += delta
                    let cleaned = Self.cleanSubtitleOutput(accumulated)
                    if !cleaned.isEmpty {
                        onUpdate(cleaned)
                    }
                }
            } catch {
                // Partial 预览取消或失败静默忽略，不影响定稿翻译。
            }
        }
    }

    /// Stage 2：当句子定稿（completed / sealed）时，取消 partial 预览并携带前 3 句上下文精翻。
    public func translateCompletedLine(
        lineID: String,
        sourceText: String,
        contextLines: [String],
        displayMode: CaptionDisplayMode,
        onStreamingUpdate: @escaping @MainActor (String, String) -> Void,
        onFinished: @escaping @MainActor (String, String?, String) async -> Void
    ) {
        partialTask?.cancel()
        partialTask = nil
        lastPartialSourceText = ""

        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let detection = CaptionLanguageDetector.detect(for: trimmed)

        // 中文音频或仅原文模式：0 延迟直通，只记录语种标签，不调大模型。
        guard !detection.isChinese, displayMode != .originalOnly else {
            Task { @MainActor in
                await onFinished(lineID, nil, detection.languageCode)
            }
            return
        }

        guard let client = makeClient() else {
            Task { @MainActor in
                await onFinished(lineID, nil, detection.languageCode)
            }
            return
        }

        finalTasks[lineID]?.cancel()
        finalTasks[lineID] = Task { @MainActor [weak self] in
            defer { self?.finalTasks[lineID] = nil }
            do {
                var accumulated = ""
                let stream = client.translateStream(
                    sourceText: trimmed,
                    contextLines: Array(contextLines.suffix(3))
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
                    finalCleaned.isEmpty ? nil : finalCleaned,
                    detection.languageCode
                )
            } catch {
                // 取消或网络错误时保留已有前缀或原文，不抛溃会话。
            }
        }
    }

    public static func buildUserPrompt(sourceText: String, contextLines: [String]) -> String {
        if contextLines.isEmpty {
            return "【当前句】\n\(sourceText)"
        }
        let contextJoined = contextLines.joined(separator: "\n")
        return "【前文背景（仅供参考语境，切勿翻译）】\n\(contextJoined)\n\n【当前句（请仅将此句译为简练中文字幕）】\n\(sourceText)"
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
