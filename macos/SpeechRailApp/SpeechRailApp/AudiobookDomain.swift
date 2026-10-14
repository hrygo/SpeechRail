import CryptoKit
import Foundation

// MARK: - Centralized Default Budgets & Limits

public enum AudiobookLimits {
    public static let maxRawFileBytes: Int = 64 * 1024 * 1024
    public static let maxTotalScalars: Int = 10_000_000
    public static let maxPreviewScalars: Int = 6_000
    public static let maxAtomScalars: Int = 160

    public static let maxWindowPrimaryScalars: Int = 4_000
    public static let maxWindowPrimaryAtoms: Int = 256
    public static let maxWindowContextScalarsPerSide: Int = 500
    public static let maxCastSummaryScalars: Int = 4_000
    public static let maxTotalPromptScalars: Int = 16_000
    public static let minSplitWindowScalars: Int = 64

    public static let maxExtractionOutputTokens: Int = 4_000
    public static let maxConsolidationOutputTokens: Int = 4_000
    public static let maxAnnotationOutputTokens: Int = 6_000
    public static let analysisCallTimeoutSeconds: TimeInterval = 90
    public static let maxCastMergeBatchSize: Int = 32
    public static let maxCompleteJSONCallsPerRootWindow: Int = 4

    public static let targetFragmentScalars: Int = 180
    public static let maxFragmentScalars: Int = 240
    public static let maxInFlightRenderRequests: Int = 1
    public static let maxWAVResponseBytes: Int = 8 * 1024 * 1024
    public static let maxRenderTransientRetries: Int = 3
    public static let defaultRenderSpeed: Double = 1.0

    public static let maxStorePageSize: Int = 100
    public static let minPlaybackRate: Float = 0.5
    public static let maxPlaybackRate: Float = 2.0
    public static let bookmarkAutosaveIntervalSeconds: TimeInterval = 5.0

    public static let maxExportManifestBytes: Int = 64 * 1024 * 1024
    public static let exportIOChunkBytes: Int = 64 * 1024
    public static let exportNoProgressTimeoutSeconds: TimeInterval = 90
    public static let exportMaxDurationSeconds: TimeInterval = 2 * 3600
    public static let intermediateSampleRate: Int = 48_000
    public static let intermediateChannels: Int = 1
    public static let exportAudioBitrateKbps: Int = 128
}

// MARK: - Core Source & Identity Types

public enum AudiobookSourceError: Error, Equatable, Sendable, LocalizedError {
    case invalidUTF8
    case rangeOutOfBounds(AudiobookSourceRange, totalBytes: Int64)
    case invertedRange(AudiobookSourceRange)
    case nonScalarBoundary(Int64)
    case coverageHole(expectedLowerBound: Int64, actualLowerBound: Int64)
    case coverageOverlap(previousUpperBound: Int64, nextLowerBound: Int64)
    case coverageDuplicate(AudiobookSourceRange)
    case coverageIncomplete(coveredUntil: Int64, totalBytes: Int64)
    case unknownAtomID(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            "正文字节不是有效的 UTF-8 编码。"
        case let .rangeOutOfBounds(range, totalBytes):
            "来源区间 [\(range.lowerBound), \(range.upperBound)) 超出正文长度 \(totalBytes)。"
        case let .invertedRange(range):
            "来源区间下界 \(range.lowerBound) 大于上界 \(range.upperBound)。"
        case let .nonScalarBoundary(offset):
            "字节偏移 \(offset) 未落在 Unicode 字符边界上。"
        case let .coverageHole(expected, actual):
            "正文区间存在遗漏：期望从 \(expected) 继续，实际从 \(actual) 开始。"
        case let .coverageOverlap(previous, next):
            "正文区间存在重叠：前一段结束于 \(previous)，下一段开始于 \(next)。"
        case let .coverageDuplicate(range):
            "正文区间重复覆盖：[\(range.lowerBound), \(range.upperBound))。"
        case let .coverageIncomplete(coveredUntil, totalBytes):
            "正文末尾未完整覆盖：仅覆盖至 \(coveredUntil) / \(totalBytes)。"
        case let .unknownAtomID(id):
            "未知的正文单元标识：\(id.uuidString)。"
        }
    }
}

/// Half-open UTF-8 byte interval `[lowerBound, upperBound)` on canonical source text.
public struct AudiobookSourceRange: Codable, Equatable, Hashable, Sendable, Comparable {
    public let lowerBound: Int64
    public let upperBound: Int64

    public init(lowerBound: Int64, upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var byteCount: Int64 {
        upperBound - lowerBound
    }

    public var isEmpty: Bool {
        lowerBound == upperBound
    }

    public static func < (lhs: AudiobookSourceRange, rhs: AudiobookSourceRange) -> Bool {
        if lhs.lowerBound != rhs.lowerBound {
            return lhs.lowerBound < rhs.lowerBound
        }
        return lhs.upperBound < rhs.upperBound
    }
}

public enum AudiobookTextAtomKind: String, Codable, Equatable, Hashable, Sendable {
    case body
    case heading
    case formatting
}

public struct AudiobookTextAtom: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let chapterID: UUID
    public let ordinal: Int
    public let sourceRange: AudiobookSourceRange
    public let kind: AudiobookTextAtomKind

    public init(
        id: UUID = UUID(),
        chapterID: UUID,
        ordinal: Int,
        sourceRange: AudiobookSourceRange,
        kind: AudiobookTextAtomKind
    ) {
        self.id = id
        self.chapterID = chapterID
        self.ordinal = ordinal
        self.sourceRange = sourceRange
        self.kind = kind
    }
}

// MARK: - Distinct Status Enums (Never Sharing a Generic `.completed`)

public enum AudiobookAnalysisState: String, Codable, Equatable, Hashable, Sendable {
    case notStarted
    case running
    case paused
    case failed
    case allWindowsValidated
}

public enum AudiobookChapterReadinessState: String, Codable, Equatable, Hashable, Sendable {
    case awaitingGlobalAnalysis
    case awaitingCastConfirmation
    case blockedByUnknownSpeakers
    case readyForProduction
    case producing
    case paused
    case needsUpdate
    case chapterAudioReady
    case failed
}

public enum AudiobookProductionState: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case running
    case pausing
    case paused
    case blockedByConditions
    case partialChaptersReady
    case allConfirmedChaptersProduced
    case fullBookProduced
    case failed
}

public enum AudiobookListenableState: String, Codable, Equatable, Hashable, Sendable {
    case noneAvailable
    case previousRevisionAvailable
    case partialChaptersListenable
    case fullBookListenable
}

// MARK: - Book & Chapter Models

public struct AudiobookBook: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sourceID: UUID
    public var title: String
    public var author: String?
    public let sourceSHA256: String
    public let canonicalByteCount: Int64
    public let scalarCount: Int
    public let originalEncoding: String
    public var analysisState: AudiobookAnalysisState
    public var productionState: AudiobookProductionState
    public var listenableState: AudiobookListenableState
    public var confirmedCastRevisionID: UUID?
    public var confirmedAuditionVoiceSetDigest: String?
    public var currentProductionRevisionID: UUID?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sourceID: UUID = UUID(),
        title: String,
        author: String? = nil,
        sourceSHA256: String,
        canonicalByteCount: Int64,
        scalarCount: Int,
        originalEncoding: String,
        analysisState: AudiobookAnalysisState = .notStarted,
        productionState: AudiobookProductionState = .idle,
        listenableState: AudiobookListenableState = .noneAvailable,
        confirmedCastRevisionID: UUID? = nil,
        confirmedAuditionVoiceSetDigest: String? = nil,
        currentProductionRevisionID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.author = author
        self.sourceSHA256 = sourceSHA256
        self.canonicalByteCount = canonicalByteCount
        self.scalarCount = scalarCount
        self.originalEncoding = originalEncoding
        self.analysisState = analysisState
        self.productionState = productionState
        self.listenableState = listenableState
        self.confirmedCastRevisionID = confirmedCastRevisionID
        self.confirmedAuditionVoiceSetDigest = confirmedAuditionVoiceSetDigest
        self.currentProductionRevisionID = currentProductionRevisionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AudiobookChapter: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let sourceID: UUID
    public var ordinal: Int
    public var title: String
    public var sourceRange: AudiobookSourceRange
    public var excludedRanges: [AudiobookSourceRange]
    public var currentChapterRevisionID: UUID?
    public var previousChapterRevisionID: UUID?

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        sourceID: UUID,
        ordinal: Int,
        title: String,
        sourceRange: AudiobookSourceRange,
        excludedRanges: [AudiobookSourceRange] = [],
        currentChapterRevisionID: UUID? = nil,
        previousChapterRevisionID: UUID? = nil
    ) {
        self.id = id
        self.bookID = bookID
        self.sourceID = sourceID
        self.ordinal = ordinal
        self.title = title
        self.sourceRange = sourceRange
        self.excludedRanges = excludedRanges
        self.currentChapterRevisionID = currentChapterRevisionID
        self.previousChapterRevisionID = previousChapterRevisionID
    }
}

// MARK: - Character, Voice Binding & Analysis Annotation

public struct AudiobookCharacterEvidence: Codable, Equatable, Hashable, Sendable {
    public let chapterID: UUID
    public let sourceRange: AudiobookSourceRange
    public let quoteExcerpt: String

    public init(chapterID: UUID, sourceRange: AudiobookSourceRange, quoteExcerpt: String) {
        self.chapterID = chapterID
        self.sourceRange = sourceRange
        self.quoteExcerpt = quoteExcerpt
    }
}

public struct AudiobookCharacter: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public var displayName: String
    public var aliases: [String]
    public let isNarrator: Bool
    public var isMajor: Bool
    public var allowSharedMinorVoice: Bool
    public var evidences: [AudiobookCharacterEvidence]
    public var firstAppearanceRange: AudiobookSourceRange?
    public var chapterIDs: [UUID]

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        displayName: String,
        aliases: [String] = [],
        isNarrator: Bool = false,
        isMajor: Bool = true,
        allowSharedMinorVoice: Bool = false,
        evidences: [AudiobookCharacterEvidence] = [],
        firstAppearanceRange: AudiobookSourceRange? = nil,
        chapterIDs: [UUID] = []
    ) {
        self.id = id
        self.bookID = bookID
        self.displayName = displayName
        self.aliases = aliases
        self.isNarrator = isNarrator
        self.isMajor = isMajor
        self.allowSharedMinorVoice = allowSharedMinorVoice
        self.evidences = evidences
        self.firstAppearanceRange = firstAppearanceRange
        self.chapterIDs = chapterIDs
    }
}

public struct AudiobookVoiceBinding: Codable, Equatable, Hashable, Sendable {
    public let roleID: UUID
    public let voiceID: String
    public let voiceRevision: String
    public let modelRevision: String
    public let isSynthesisReady: Bool
    public let allowedSpeed: Double
    public let callerSeed: Int?

    public init(
        roleID: UUID,
        voiceID: String,
        voiceRevision: String,
        modelRevision: String,
        isSynthesisReady: Bool = true,
        allowedSpeed: Double = AudiobookLimits.defaultRenderSpeed,
        callerSeed: Int? = nil
    ) {
        self.roleID = roleID
        self.voiceID = voiceID
        self.voiceRevision = voiceRevision
        self.modelRevision = modelRevision
        self.isSynthesisReady = isSynthesisReady
        self.allowedSpeed = allowedSpeed
        self.callerSeed = callerSeed
    }

    public var bindingDigest: String {
        let seedPart = callerSeed.map(String.init) ?? "nil"
        let canonical = "\(roleID.uuidString)|\(voiceID)|\(voiceRevision)|\(modelRevision)|\(isSynthesisReady)|\(String(format: "%.3f", allowedSpeed))|\(seedPart)"
        return AudiobookDigest.sha256Hex(Data(canonical.utf8))
    }
}

public enum AudiobookSpeakerAssignment: Codable, Equatable, Hashable, Sendable {
    case assigned(roleID: UUID)
    case unknown(reason: String, candidateRoleIDs: [UUID])

    public var roleID: UUID? {
        if case let .assigned(id) = self { return id }
        return nil
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

public struct AudiobookAnalysisWindow: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let rootWindowID: UUID
    public let bookID: UUID
    public let chapterID: UUID
    public let ordinal: Int
    public let primaryAtomIDs: [UUID]
    public let leadingContextAtomIDs: [UUID]
    public let trailingContextAtomIDs: [UUID]
    public let policyFingerprint: String
    public let configurationDigest: String
    public let generation: Int
    public var isCompleted: Bool

    public init(
        id: UUID = UUID(),
        rootWindowID: UUID? = nil,
        bookID: UUID,
        chapterID: UUID,
        ordinal: Int,
        primaryAtomIDs: [UUID],
        leadingContextAtomIDs: [UUID] = [],
        trailingContextAtomIDs: [UUID] = [],
        policyFingerprint: String,
        configurationDigest: String,
        generation: Int = 1,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.rootWindowID = rootWindowID ?? id
        self.bookID = bookID
        self.chapterID = chapterID
        self.ordinal = ordinal
        self.primaryAtomIDs = primaryAtomIDs
        self.leadingContextAtomIDs = leadingContextAtomIDs
        self.trailingContextAtomIDs = trailingContextAtomIDs
        self.policyFingerprint = policyFingerprint
        self.configurationDigest = configurationDigest
        self.generation = generation
        self.isCompleted = isCompleted
    }
}

public struct AudiobookAnnotation: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let chapterID: UUID
    public let windowID: UUID
    public let atomID: UUID
    public let sourceRange: AudiobookSourceRange
    public var assignment: AudiobookSpeakerAssignment
    public var evidence: String?
    public var userConfirmed: Bool
    public var annotationRevision: Int

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        windowID: UUID,
        atomID: UUID,
        sourceRange: AudiobookSourceRange,
        assignment: AudiobookSpeakerAssignment,
        evidence: String? = nil,
        userConfirmed: Bool = false,
        annotationRevision: Int = 1
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.windowID = windowID
        self.atomID = atomID
        self.sourceRange = sourceRange
        self.assignment = assignment
        self.evidence = evidence
        self.userConfirmed = userConfirmed
        self.annotationRevision = annotationRevision
    }
}

// MARK: - Fragment, Render Candidate, Revision, Bookmark & Export

public struct AudiobookFragment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let chapterID: UUID
    public let ordinal: Int
    public let roleID: UUID
    public let sourceRange: AudiobookSourceRange
    public let atomIDs: [UUID]
    public let localAssignmentDigest: String
    public let voiceBindingDigest: String
    public let policyDigest: String
    public let dependencyDigest: String

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        ordinal: Int,
        roleID: UUID,
        sourceRange: AudiobookSourceRange,
        atomIDs: [UUID],
        localAssignmentDigest: String,
        voiceBindingDigest: String,
        policyDigest: String,
        dependencyDigest: String
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.ordinal = ordinal
        self.roleID = roleID
        self.sourceRange = sourceRange
        self.atomIDs = atomIDs
        self.localAssignmentDigest = localAssignmentDigest
        self.voiceBindingDigest = voiceBindingDigest
        self.policyDigest = policyDigest
        self.dependencyDigest = dependencyDigest
    }
}

public struct AudiobookRenderCandidate: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let chapterID: UUID
    public let fragmentID: UUID
    public let taskID: UUID
    public let generation: Int
    public let relativeAssetPath: String
    public let fileSHA256: String
    public let pcmSHA256: String
    public let frameCount: Int64
    public let sampleRate: Int
    public let dependencyDigest: String
    public let requestID: String?
    public let receiptDigest: String?
    public let recipeSummary: String?
    public let isReceiptVerified: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        fragmentID: UUID,
        taskID: UUID = UUID(),
        generation: Int,
        relativeAssetPath: String,
        fileSHA256: String,
        pcmSHA256: String,
        frameCount: Int64,
        sampleRate: Int = AudiobookLimits.intermediateSampleRate,
        dependencyDigest: String,
        requestID: String? = nil,
        receiptDigest: String? = nil,
        recipeSummary: String? = nil,
        isReceiptVerified: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.fragmentID = fragmentID
        self.taskID = taskID
        self.generation = generation
        self.relativeAssetPath = relativeAssetPath
        self.fileSHA256 = fileSHA256
        self.pcmSHA256 = pcmSHA256
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.dependencyDigest = dependencyDigest
        self.requestID = requestID
        self.receiptDigest = receiptDigest
        self.recipeSummary = recipeSummary
        self.isReceiptVerified = isReceiptVerified
        self.createdAt = createdAt
    }

    public var durationSeconds: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / Double(sampleRate)
    }
}

public struct AudiobookFragmentCandidateBinding: Codable, Equatable, Hashable, Sendable {
    public let fragmentID: UUID
    public let candidateID: UUID
    public let sourceRange: AudiobookSourceRange
    public let dependencyDigest: String

    public init(
        fragmentID: UUID,
        candidateID: UUID,
        sourceRange: AudiobookSourceRange,
        dependencyDigest: String
    ) {
        self.fragmentID = fragmentID
        self.candidateID = candidateID
        self.sourceRange = sourceRange
        self.dependencyDigest = dependencyDigest
    }
}

public struct AudiobookChapterRevision: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let chapterID: UUID
    public let sourceID: UUID
    public let revisionNumber: Int
    public let orderedBindings: [AudiobookFragmentCandidateBinding]
    public let totalFrameCount: Int64
    public let sampleRate: Int
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        chapterID: UUID,
        sourceID: UUID,
        revisionNumber: Int,
        orderedBindings: [AudiobookFragmentCandidateBinding],
        totalFrameCount: Int64,
        sampleRate: Int = AudiobookLimits.intermediateSampleRate,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.chapterID = chapterID
        self.sourceID = sourceID
        self.revisionNumber = revisionNumber
        self.orderedBindings = orderedBindings
        self.totalFrameCount = totalFrameCount
        self.sampleRate = sampleRate
        self.createdAt = createdAt
    }
}

public struct AudiobookProductionRevision: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let sourceID: UUID
    public let chapterRevisionIDsByChapter: [UUID: UUID]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        sourceID: UUID,
        chapterRevisionIDsByChapter: [UUID: UUID],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.sourceID = sourceID
        self.chapterRevisionIDsByChapter = chapterRevisionIDsByChapter
        self.createdAt = createdAt
    }
}

public struct AudiobookBookmark: Codable, Equatable, Hashable, Sendable {
    public let bookID: UUID
    public let chapterID: UUID
    public let chapterRevisionID: UUID
    public let fragmentID: UUID
    public let sourceAnchorRange: AudiobookSourceRange
    public let fragmentOffsetSeconds: TimeInterval
    public let playbackRate: Float
    public let updatedAt: Date

    public init(
        bookID: UUID,
        chapterID: UUID,
        chapterRevisionID: UUID,
        fragmentID: UUID,
        sourceAnchorRange: AudiobookSourceRange,
        fragmentOffsetSeconds: TimeInterval,
        playbackRate: Float = 1.0,
        updatedAt: Date = Date()
    ) {
        self.bookID = bookID
        self.chapterID = chapterID
        self.chapterRevisionID = chapterRevisionID
        self.fragmentID = fragmentID
        self.sourceAnchorRange = sourceAnchorRange
        self.fragmentOffsetSeconds = fragmentOffsetSeconds
        self.playbackRate = playbackRate
        self.updatedAt = updatedAt
    }
}

public struct AudiobookOmittedChapterRecord: Codable, Equatable, Hashable, Sendable {
    public let chapterID: UUID
    public let chapterTitle: String
    public let reason: String

    public init(chapterID: UUID, chapterTitle: String, reason: String) {
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.reason = reason
    }
}

public struct AudiobookExportRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let productionRevisionID: UUID
    public let profileRawValue: String
    public let exportedChapterIDs: [UUID]
    public let omittedChapters: [AudiobookOmittedChapterRecord]
    public let finalFileSHA256: String
    public let totalFrameCount: Int64
    public let durationSeconds: TimeInterval
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        bookID: UUID,
        productionRevisionID: UUID,
        profileRawValue: String,
        exportedChapterIDs: [UUID],
        omittedChapters: [AudiobookOmittedChapterRecord] = [],
        finalFileSHA256: String,
        totalFrameCount: Int64,
        durationSeconds: TimeInterval,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bookID = bookID
        self.productionRevisionID = productionRevisionID
        self.profileRawValue = profileRawValue
        self.exportedChapterIDs = exportedChapterIDs
        self.omittedChapters = omittedChapters
        self.finalFileSHA256 = finalFileSHA256
        self.totalFrameCount = totalFrameCount
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}

public enum AudiobookDigest {
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
