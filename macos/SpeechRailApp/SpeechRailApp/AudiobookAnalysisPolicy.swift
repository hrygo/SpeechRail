import CryptoKit
import Foundation

public enum AudiobookAnalysisStage: String, Codable, Equatable, Hashable, Sendable {
    case extraction
    case castMerge
    case annotation
}

/// T04：有声书工坊的全书分析限额、策略与非秘密配置快照。
public struct AudiobookAnalysisPolicy: Codable, Equatable, Sendable {
    public var version: String
    public var maxPrimaryScalars: Int
    public var maxPrimaryAtoms: Int
    public var minWindowScalars: Int
    public var maxContextScalarsPerSide: Int
    public var maxCharacterSummaryScalars: Int
    public var maxFullRequestScalars: Int
    public var extractionMaxOutputTokens: Int
    public var mergeMaxOutputTokens: Int
    public var annotationMaxOutputTokens: Int
    public var requestTimeoutSeconds: TimeInterval
    public var maxMergeCandidatesPerBatch: Int
    public var maxCallsPerRootWindow: Int

    // v2 changes omitted direct-dialogue handling to unknown, so v1 annotation checkpoints must be rerun.
    public static let standard = AudiobookAnalysisPolicy()

    public init(
        version: String = "audiobook_analysis_policy_v2",
        maxPrimaryScalars: Int = AudiobookLimits.maxWindowPrimaryScalars,
        maxPrimaryAtoms: Int = AudiobookLimits.maxWindowPrimaryAtoms,
        minWindowScalars: Int = AudiobookLimits.minSplitWindowScalars,
        maxContextScalarsPerSide: Int = AudiobookLimits.maxWindowContextScalarsPerSide,
        maxCharacterSummaryScalars: Int = AudiobookLimits.maxCastSummaryScalars,
        maxFullRequestScalars: Int = AudiobookLimits.maxTotalPromptScalars,
        extractionMaxOutputTokens: Int = AudiobookLimits.maxExtractionOutputTokens,
        mergeMaxOutputTokens: Int = AudiobookLimits.maxConsolidationOutputTokens,
        annotationMaxOutputTokens: Int = AudiobookLimits.maxAnnotationOutputTokens,
        requestTimeoutSeconds: TimeInterval = AudiobookLimits.analysisCallTimeoutSeconds,
        maxMergeCandidatesPerBatch: Int = AudiobookLimits.maxCastMergeBatchSize,
        maxCallsPerRootWindow: Int = AudiobookLimits.maxCompleteJSONCallsPerRootWindow
    ) {
        self.version = version
        self.maxPrimaryScalars = maxPrimaryScalars
        self.maxPrimaryAtoms = maxPrimaryAtoms
        self.minWindowScalars = minWindowScalars
        self.maxContextScalarsPerSide = maxContextScalarsPerSide
        self.maxCharacterSummaryScalars = maxCharacterSummaryScalars
        self.maxFullRequestScalars = maxFullRequestScalars
        self.extractionMaxOutputTokens = extractionMaxOutputTokens
        self.mergeMaxOutputTokens = mergeMaxOutputTokens
        self.annotationMaxOutputTokens = annotationMaxOutputTokens
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maxMergeCandidatesPerBatch = maxMergeCandidatesPerBatch
        self.maxCallsPerRootWindow = maxCallsPerRootWindow
    }

    public var policyDigest: String {
        let raw = [
            version,
            "primary:\(maxPrimaryScalars)",
            "atoms:\(maxPrimaryAtoms)",
            "min:\(minWindowScalars)",
            "ctx:\(maxContextScalarsPerSide)",
            "summary:\(maxCharacterSummaryScalars)",
            "req:\(maxFullRequestScalars)",
            "out:\(extractionMaxOutputTokens)-\(mergeMaxOutputTokens)-\(annotationMaxOutputTokens)",
            "batch:\(maxMergeCandidatesPerBatch)",
            "calls:\(maxCallsPerRootWindow)"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 冻结一次分析的配置身份，绝不包含 API Key。
public struct AudiobookAnalysisConfigSnapshot: Codable, Equatable, Sendable {
    public var normalizedBaseURL: String
    public var model: String
    public var compatibilityMode: LLMCompatibilityMode
    public var origin: LLMConfigurationOrigin
    public var generation: Int
    public var configurationDigest: String

    public init(
        configuration: LLMConfiguration,
        origin: LLMConfigurationOrigin = .global,
        generation: Int = 1
    ) {
        self.normalizedBaseURL = configuration.normalizedBaseURL
        self.model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.compatibilityMode = configuration.compatibilityMode
        self.origin = origin
        self.generation = max(1, generation)
        self.configurationDigest = Self.computeDigest(
            normalizedBaseURL: self.normalizedBaseURL,
            model: self.model,
            compatibilityMode: self.compatibilityMode,
            origin: self.origin
        )
    }

    public init(
        resolved: ResolvedLLMConfiguration,
        generation: Int = 1
    ) {
        self.init(
            configuration: resolved.configuration,
            origin: resolved.origin,
            generation: generation
        )
    }

    public var isConfigured: Bool {
        !normalizedBaseURL.isEmpty && !model.isEmpty
    }

    public static func computeDigest(
        normalizedBaseURL: String,
        model: String,
        compatibilityMode: LLMCompatibilityMode,
        origin: LLMConfigurationOrigin
    ) -> String {
        let raw = "audiobook_llm_cfg_v1|\(normalizedBaseURL)|\(model)|\(compatibilityMode.rawValue)|\(origin.rawValue)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum AudiobookAnalysisError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case badConfiguration(String)
    case inputBudgetExceeded(actualScalars: Int, maximumScalars: Int)
    case primaryWindowTooLarge(actualScalars: Int, actualAtoms: Int)
    case invalidStructuredOutput(String)
    case atomCoverageViolation(String)
    case rootCallBudgetExhausted(rootWindowID: UUID)
    case configurationChangedDuringRun
    case cancelled
    case windowFailed(windowID: UUID, reason: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置有声书分析所需的 AI 服务地址与模型。"
        case .badConfiguration(let detail):
            return detail
        case .inputBudgetExceeded(let actual, let maximum):
            return "单次分析输入内容（\(actual) 字符）超过上限（\(maximum) 字符）。"
        case .primaryWindowTooLarge(let scalars, let atoms):
            return "分析主窗口（\(scalars) 字符 / \(atoms) 切分块）超出单窗预算。"
        case .invalidStructuredOutput(let reason):
            return "AI 返回的分析结构无效：\(reason)"
        case .atomCoverageViolation(let reason):
            return "AI 返回的段落标注未能完整覆盖原文：\(reason)"
        case .rootCallBudgetExhausted:
            return "当前正文窗口的分析重试次数已达上限，已暂停等待人工处理。"
        case .configurationChangedDuringRun:
            return "AI 配置已在分析途中变更，分析已安全暂停以保护检查点一致性。"
        case .cancelled:
            return "全书分析已暂停。"
        case .windowFailed(_, let reason):
            return "部分章节窗口分析未完成：\(reason)"
        }
    }
}
