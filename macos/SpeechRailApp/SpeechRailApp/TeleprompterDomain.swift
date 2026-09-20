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
            "提词稿不能为空"
        case .invalidSourceRange:
            "提词稿段落无法追溯到原文"
        case .invalidAnalysis:
            "AI 提词分析结果无效"
        case .promptConstructionFailed:
            "AI 提词请求构建失败"
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
    public static let title = "AI 整理会发送原稿"
    public static let inlineMessage =
        "AI 整理只在你主动点击时发生；原稿和偏好会发送到当前配置的 Responses-compatible endpoint。"
    public static let message = """
        点击继续后，当前原稿正文和语言/表达偏好会发送到你配置的 Responses-compatible endpoint；它可能是本机服务，也可能是网络服务。SpeechRail 使用 store=false，不使用 Responses 会话状态，但 endpoint 自身的传输、日志和保留策略仍由其服务方决定。

        跟读和直播过程中不会调用大模型，也不会发送麦克风、摄像头或直播画面。
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
