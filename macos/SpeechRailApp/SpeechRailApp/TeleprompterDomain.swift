import CryptoKit
import Foundation

public enum TeleprompterTextError: Error, Equatable, LocalizedError, Sendable {
    case emptySource
    case invalidSourceRange
    case invalidAnalysis
    case promptConstructionFailed

    public var errorDescription: String? {
        switch self {
        case .emptySource:
            "请先输入稿件内容"
        case .invalidSourceRange:
            "整理结果和原稿对不上"
        case .invalidAnalysis:
            "AI 返回的整理结果无法使用"
        case .promptConstructionFailed:
            "没能准备好 AI 整理请求"
        }
    }
}

/// AI 整理前向用户说明的数据流边界。
///
/// 文案不包含 endpoint、密钥或 provider 的实现细节，避免把敏感配置带入界面或持久化稿件。
public enum TeleprompterAIDataFlowDisclosure {
    /// 旧版本的全局确认键保留但不复用；新确认按实际 endpoint/model 作用域保存。
    public static let acknowledgementDefaultsKey =
        "speechrail.teleprompter.aiDataFlowAcknowledged.v1"
    public static let title = "整理稿件前请确认"
    public static let inlineMessage =
        "只有点击 AI 朗读标注时，原稿才会发给 AI 服务；跟读时不会调用 AI。"
    public static let message = """
        点击「允许发送并整理」后，SpeechRail 会把当前原稿文字，以及你选择的语言和表达方式，发送给设置中的 AI 服务，用来分段、提取关键词和建议停顿。

        不会发送麦克风、摄像头或直播画面。跟读和直播时也不会调用 AI。

        这个服务可能在本机，也可能在网络上；它是否记录或保存内容，由服务方的规则决定。
        """

    /// 不把 endpoint 原文写进 UserDefaults key；配置变化后必须重新确认数据流。
    public static func acknowledgementDefaultsKey(for configuration: LLMConfiguration) -> String {
        let material = configuration.normalizedBaseURL
            + "\u{0}"
            + configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(material.utf8))
        let fingerprint = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "speechrail.teleprompter.aiDataFlowAcknowledged.v2.\(fingerprint)"
    }
}

public struct TeleprompterSourceRange: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public func isValid(in sourceText: String) -> Bool {
        start >= 0 && end > start && end <= sourceText.utf16.count
    }
}

public typealias TeleprompterPace = TeleprompterTimingPolicy.Pace

public enum TeleprompterReviewIssue: String, Codable, Sendable, CaseIterable {
    case missingContext = "missing_context"
    case formatAmbiguity = "format_ambiguity"
    case readingChoice = "reading_choice"
    case uncertainMeaning = "uncertain_meaning"
    case nonspokenContent = "nonspoken_content"

    public var title: String {
        switch self {
        case .missingContext: "指代缺失"
        case .formatAmbiguity: "格式歧义"
        case .readingChoice: "读法选择"
        case .uncertainMeaning: "含义存疑"
        case .nonspokenContent: "建议略过"
        }
    }

    public var detail: String {
        switch self {
        case .missingContext: "原文存在未指明的代词或前文依赖，请核对是否需要补足主语。"
        case .formatAmbiguity: "原文包含代码、表格或特殊符号，AI 提出了转述建议，请确认表达方式。"
        case .readingChoice: "存在多种读法（如按字读或按意译读），请选择你希望的读法。"
        case .uncertainMeaning: "原文含义模糊或存在歧义，未做臆测，请确认正文。"
        case .nonspokenContent: "模型建议不朗读此项（如版权声明、未闭合标记或纯排版内容），由你决定是否跳过。"
        }
    }
}

public enum TeleprompterReviewAction: String, Codable, Sendable {
    case accept      // 采用建议
    case edit        // 修改
    case keepSource  // 保留原文
    case convertToCue // 仅作提示
    case skip        // 跳过
}

public struct TeleprompterReviewItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let blockID: String
    public let issue: TeleprompterReviewIssue
    public var suggestedText: String
    public var sourceSnippet: String
    public var resolvedAction: TeleprompterReviewAction?

    public init(
        id: String = UUID().uuidString,
        blockID: String,
        issue: TeleprompterReviewIssue,
        suggestedText: String,
        sourceSnippet: String,
        resolvedAction: TeleprompterReviewAction? = nil
    ) {
        self.id = id
        self.blockID = blockID
        self.issue = issue
        self.suggestedText = suggestedText
        self.sourceSnippet = sourceSnippet
        self.resolvedAction = resolvedAction
    }

    public var isResolved: Bool {
        resolvedAction != nil
    }
}

public enum TeleprompterBlockDisposition: String, Codable, Sendable {
    case speak
    case cue
    case skip
    case unresolved
}

public enum TeleprompterBlockOrigin: String, Codable, Sendable {
    case ai
    case deterministic
    case user
}

public struct TeleprompterReadingBlock: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var ordinal: Int
    public var sourceRange: TeleprompterSourceRange
    public var text: String
    public var rawSourceText: String
    public var disposition: TeleprompterBlockDisposition
    public var origin: TeleprompterBlockOrigin
    public var reviewIssues: [TeleprompterReviewIssue]
    public var budgetSeconds: Double

    public init(
        id: String,
        ordinal: Int,
        sourceRange: TeleprompterSourceRange,
        text: String,
        rawSourceText: String = "",
        disposition: TeleprompterBlockDisposition = .speak,
        origin: TeleprompterBlockOrigin = .ai,
        reviewIssues: [TeleprompterReviewIssue] = [],
        budgetSeconds: Double = 0
    ) {
        self.id = id
        self.ordinal = ordinal
        self.sourceRange = sourceRange
        self.text = text
        self.rawSourceText = rawSourceText
        self.disposition = disposition
        self.origin = origin
        self.reviewIssues = reviewIssues
        self.budgetSeconds = budgetSeconds
    }
}

public struct TeleprompterContentSelection: Codable, Equatable, Sendable {
    public var totalParagraphCount: Int
    public var selectedParagraphIndices: Set<Int>

    public init(totalParagraphCount: Int = 0, selectedParagraphIndices: Set<Int> = []) {
        self.totalParagraphCount = totalParagraphCount
        self.selectedParagraphIndices = selectedParagraphIndices
    }

    public var isAllSelected: Bool {
        totalParagraphCount > 0 && selectedParagraphIndices.count == totalParagraphCount
    }

    public var hasExclusions: Bool {
        !isAllSelected && !selectedParagraphIndices.isEmpty
    }

    public var selectedCount: Int {
        selectedParagraphIndices.count
    }
}

public struct TeleprompterTrialReadingResult: Codable, Equatable, Sendable {
    public let durationSeconds: TimeInterval
    public let baseEstimateSeconds: TimeInterval
    public let calibrationFactor: Double
    public let isAdopted: Bool

    public init(
        durationSeconds: TimeInterval,
        baseEstimateSeconds: TimeInterval,
        calibrationFactor: Double,
        isAdopted: Bool = false
    ) {
        self.durationSeconds = durationSeconds
        self.baseEstimateSeconds = baseEstimateSeconds
        self.calibrationFactor = calibrationFactor
        self.isAdopted = isAdopted
    }

    public var isWithinValidRange: Bool {
        (TeleprompterTimingPolicy.minimumCalibrationFactor...TeleprompterTimingPolicy.maximumCalibrationFactor)
            .contains(calibrationFactor)
    }
}

public struct TeleprompterRunClockState: Codable, Equatable, Sendable {
    public var elapsedSeconds: TimeInterval
    public var targetSeconds: TimeInterval
    public var estimatedRemainingSeconds: TimeInterval
    public var isPaused: Bool

    public init(
        elapsedSeconds: TimeInterval = 0,
        targetSeconds: TimeInterval = 1200,
        estimatedRemainingSeconds: TimeInterval = 1200,
        isPaused: Bool = false
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.targetSeconds = targetSeconds
        self.estimatedRemainingSeconds = estimatedRemainingSeconds
        self.isPaused = isPaused
    }

    public var targetRemainingSeconds: TimeInterval {
        max(0, targetSeconds - elapsedSeconds)
    }

    public var isOverTarget: Bool {
        elapsedSeconds > targetSeconds
    }

    public var overTargetSeconds: TimeInterval {
        max(0, elapsedSeconds - targetSeconds)
    }
}

public enum TeleprompterAnalysisSource: String, Codable, Sendable {
    case ai
    case deterministic
    case user
}

public enum TeleprompterPauseHint: String, Codable, Sendable, CaseIterable {
    case short
    case medium
    case long
}

public struct TeleprompterSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let ordinal: Int
    public let sourceRange: TeleprompterSourceRange
    public var text: String
    public var keywords: [String]
    public var matchPhrases: [String]
    public var pauseHint: TeleprompterPauseHint

    public init(
        id: String,
        ordinal: Int,
        sourceRange: TeleprompterSourceRange,
        text: String,
        keywords: [String] = [],
        matchPhrases: [String] = [],
        pauseHint: TeleprompterPauseHint = .short
    ) {
        self.id = id
        self.ordinal = ordinal
        self.sourceRange = sourceRange
        self.text = text
        self.keywords = keywords
        self.matchPhrases = matchPhrases
        self.pauseHint = pauseHint
    }
}

public struct TeleprompterVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let documentID: String
    public let sourceText: String
    public let segments: [TeleprompterSegment]
    public let analysisSource: TeleprompterAnalysisSource
    public let createdAt: Date

    public init(
        id: String,
        documentID: String,
        sourceText: String,
        segments: [TeleprompterSegment],
        analysisSource: TeleprompterAnalysisSource,
        createdAt: Date = .now
    ) {
        self.id = id
        self.documentID = documentID
        self.sourceText = sourceText
        self.segments = segments
        self.analysisSource = analysisSource
        self.createdAt = createdAt
    }
}

public struct TeleprompterDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var sourceText: String
    public var activeVersionID: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        sourceText: String,
        activeVersionID: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.sourceText = sourceText
        self.activeVersionID = activeVersionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TeleprompterRunMode: String, Codable, Sendable {
    case following
    case paused
    case manual
}

public struct TeleprompterRunState: Codable, Equatable, Sendable {
    public let documentID: String
    public let versionID: String
    public var currentSegmentID: String?
    public var mode: TeleprompterRunMode
    public var lastUpdatedAt: Date

    public init(
        documentID: String,
        versionID: String,
        currentSegmentID: String?,
        mode: TeleprompterRunMode,
        lastUpdatedAt: Date = .now
    ) {
        self.documentID = documentID
        self.versionID = versionID
        self.currentSegmentID = currentSegmentID
        self.mode = mode
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public struct TeleprompterDocumentBundle: Codable, Equatable, Sendable {
    public var document: TeleprompterDocument
    public var versions: [TeleprompterVersion]
    public var runState: TeleprompterRunState?

    public init(
        document: TeleprompterDocument,
        versions: [TeleprompterVersion],
        runState: TeleprompterRunState?
    ) {
        self.document = document
        self.versions = versions
        self.runState = runState
    }
}

public enum TeleprompterAlignmentDecision: Equatable, Sendable {
    case stay(confidence: Double)
    case advance(to: Int, confidence: Double)
    case uncertain(candidate: Int?, confidence: Double)
}

public struct TeleprompterAlignmentResult: Equatable, Sendable {
    public let decision: TeleprompterAlignmentDecision
    public let matchedTokens: [String]

    public init(decision: TeleprompterAlignmentDecision, matchedTokens: [String] = []) {
        self.decision = decision
        self.matchedTokens = matchedTokens
    }

    public var confidence: Double {
        switch decision {
        case let .stay(confidence), let .advance(_, confidence), let .uncertain(_, confidence):
            confidence
        }
    }
}
