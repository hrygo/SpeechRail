import Foundation

public enum TeleprompterTextError: Error, Equatable, LocalizedError, Sendable {
    case emptySource
    case invalidSourceRange
    case invalidAnalysis

    public var errorDescription: String? {
        switch self {
        case .emptySource:
            "提词稿不能为空"
        case .invalidSourceRange:
            "提词稿段落无法追溯到原文"
        case .invalidAnalysis:
            "AI 提词分析结果无效"
        }
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

public enum TeleprompterPauseHint: String, Codable, Sendable {
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
