import CryptoKit
import Foundation

public enum TeleprompterV2StoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidDocumentID
    case notFound
    case corruptBundle
    case invalidBundle
    case unsupportedVersion(Int)
    case immutableSourceRevision
    case atomicWriteFailed
    case unsupportedImport

    public var errorDescription: String? {
        switch self {
        case .invalidDocumentID: "这份稿子无法打开"
        case .notFound: "找不到这份稿子"
        case .corruptBundle: "这份稿子已损坏"
        case .invalidBundle: "这份稿子无法使用"
        case let .unsupportedVersion(version): "这份稿子需要更新版本的 SpeechRail（格式 \(version)）"
        case .immutableSourceRevision: "原稿历史版本不可修改，请创建新的来源版本"
        case .atomicWriteFailed: "稿件保存失败，原版本仍然保留"
        case .unsupportedImport: "请选择文本文件（TXT 或 Markdown）"
        }
    }
}

public enum TeleprompterV2Hash {
    public static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct TeleprompterV2Document: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var currentSourceRevisionID: String
    public var activeVersionID: String?
    /// 这份稿自己的目标时长。它属于稿件而不是一次运行：目标时长决定整理时
    /// 往哪个时长靠，跨相位、跨启动都得跟着这份稿走。旧文档没有这个字段，
    /// 载入时按原稿重新估算补一个。
    public var targetMinutes: Int?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        currentSourceRevisionID: String,
        activeVersionID: String? = nil,
        targetMinutes: Int? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.currentSourceRevisionID = currentSourceRevisionID
        self.activeVersionID = activeVersionID
        self.targetMinutes = targetMinutes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case currentSourceRevisionID = "current_source_revision_id"
        case activeVersionID = "active_version_id"
        case targetMinutes = "target_minutes"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct TeleprompterV2SourceRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var sourceText: String
    public var utf8SHA256: String
    public let encoding: String
    public let hasBOM: Bool
    public let formatHint: TeleprompterSourceFormatHint
    public let builderVersion: String
    public let sourceUnits: [TeleprompterSourceUnit]
    public let createdAt: Date

    public init(
        id: String,
        sourceText: String,
        utf8SHA256: String,
        encoding: String = "utf8",
        hasBOM: Bool = false,
        formatHint: TeleprompterSourceFormatHint = .unknown,
        builderVersion: String = TeleprompterSourceUnitBuilder.version,
        sourceUnits: [TeleprompterSourceUnit] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceText = sourceText
        self.utf8SHA256 = utf8SHA256
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.formatHint = formatHint
        self.builderVersion = builderVersion
        self.sourceUnits = sourceUnits
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceText = "source_text"
        case utf8SHA256 = "utf8_sha256"
        case encoding
        case hasBOM = "has_bom"
        case formatHint = "format_hint"
        case builderVersion = "builder_version"
        case sourceUnits = "source_units"
        case createdAt = "created_at"
    }
}

public struct TeleprompterV2DurationGoal: Codable, Equatable, Sendable {
    public let targetSeconds: TimeInterval
    public let goalRevision: Int

    public init(targetSeconds: TimeInterval, goalRevision: Int) {
        self.targetSeconds = targetSeconds
        self.goalRevision = goalRevision
    }

    private enum CodingKeys: String, CodingKey {
        case targetSeconds = "target_seconds"
        case goalRevision = "goal_revision"
    }
}

public struct TeleprompterV2TimingAllocationSnapshot: Codable, Equatable, Sendable {
    public let allocationRevision: Int
    public let plan: TeleprompterTimingPlan

    public init(allocationRevision: Int, plan: TeleprompterTimingPlan) {
        self.allocationRevision = allocationRevision
        self.plan = plan
    }

    private enum CodingKeys: String, CodingKey {
        case allocationRevision = "allocation_revision"
        case plan
    }
}

public struct TeleprompterV2ReadingBlock: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var revision: Int
    public let sourceUnitIDs: [Int]
    public var text: String
    public var disposition: TeleprompterBlockDisposition
    public var origin: TeleprompterBlockOrigin
    public var budgetShare: TimeInterval

    public init(
        id: String,
        revision: Int,
        sourceUnitIDs: [Int],
        text: String,
        disposition: TeleprompterBlockDisposition,
        origin: TeleprompterBlockOrigin,
        budgetShare: TimeInterval
    ) {
        self.id = id
        self.revision = revision
        self.sourceUnitIDs = sourceUnitIDs
        self.text = text
        self.disposition = disposition
        self.origin = origin
        self.budgetShare = budgetShare
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case revision
        case sourceUnitIDs = "source_unit_ids"
        case text
        case disposition
        case origin
        case budgetShare = "budget_share"
    }
}

public struct TeleprompterV2ReadingSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let ordinal: Int
    public let readingRange: TeleprompterSourceRange
    public var text: String
    public var keywords: [String]
    public var matchPhrases: [String]
    public var acceptedReadings: [TeleprompterAcceptedReading]
    public var pauseHint: TeleprompterPauseHint

    public init(
        id: String,
        ordinal: Int,
        readingRange: TeleprompterSourceRange,
        text: String,
        keywords: [String] = [],
        matchPhrases: [String] = [],
        acceptedReadings: [TeleprompterAcceptedReading] = [],
        pauseHint: TeleprompterPauseHint = .short
    ) {
        self.id = id
        self.ordinal = ordinal
        self.readingRange = readingRange
        self.text = text
        self.keywords = keywords
        self.matchPhrases = matchPhrases
        self.acceptedReadings = acceptedReadings
        self.pauseHint = pauseHint
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ordinal
        case readingRange = "reading_range"
        case text
        case keywords
        case matchPhrases = "match_phrases"
        case acceptedReadings = "accepted_readings"
        case pauseHint = "pause_hint"
    }

    /// Bundles written before the alias channel existed simply have no
    /// `accepted_readings` key, and must keep loading (M-01).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ordinal = try container.decode(Int.self, forKey: .ordinal)
        readingRange = try container.decode(TeleprompterSourceRange.self, forKey: .readingRange)
        text = try container.decode(String.self, forKey: .text)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        matchPhrases = try container.decodeIfPresent([String].self, forKey: .matchPhrases) ?? []
        acceptedReadings = try container.decodeIfPresent(
            [TeleprompterAcceptedReading].self, forKey: .acceptedReadings
        ) ?? []
        pauseHint = try container.decodeIfPresent(TeleprompterPauseHint.self, forKey: .pauseHint) ?? .short
    }
}

public struct TeleprompterV2ReadingVersion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let documentID: String
    public let sourceRevisionID: String
    public let readingText: String
    public let readingHash: String
    public let blocks: [TeleprompterV2ReadingBlock]
    public let segments: [TeleprompterV2ReadingSegment]
    public let goalSnapshot: TeleprompterV2DurationGoal
    public let paceSnapshot: TeleprompterPace
    public let estimate: TeleprompterDurationEstimate
    public let analysisSource: TeleprompterAnalysisSource
    public let createdAt: Date

    public init(
        id: String,
        documentID: String,
        sourceRevisionID: String,
        readingText: String,
        readingHash: String? = nil,
        blocks: [TeleprompterV2ReadingBlock],
        segments: [TeleprompterV2ReadingSegment],
        goalSnapshot: TeleprompterV2DurationGoal,
        paceSnapshot: TeleprompterPace,
        estimate: TeleprompterDurationEstimate,
        analysisSource: TeleprompterAnalysisSource,
        createdAt: Date = .now
    ) {
        self.id = id
        self.documentID = documentID
        self.sourceRevisionID = sourceRevisionID
        self.readingText = readingText
        self.readingHash = readingHash ?? TeleprompterV2Hash.sha256(readingText)
        self.blocks = blocks
        self.segments = segments
        self.goalSnapshot = goalSnapshot
        self.paceSnapshot = paceSnapshot
        self.estimate = estimate
        self.analysisSource = analysisSource
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case documentID = "document_id"
        case sourceRevisionID = "source_revision_id"
        case readingText = "reading_text"
        case readingHash = "reading_hash"
        case blocks
        case segments
        case goalSnapshot = "goal_snapshot"
        case paceSnapshot = "pace_snapshot"
        case estimate
        case analysisSource = "analysis_source"
        case createdAt = "created_at"
    }
}

public struct TeleprompterV2ReadingDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let draftRevision: Int
    public let sourceRevisionID: String
    public var blocks: [TeleprompterV2ReadingBlock]
    public let goal: TeleprompterV2DurationGoal
    public let pace: TeleprompterPace
    public let timingAllocation: TeleprompterV2TimingAllocationSnapshot

    public init(
        id: String,
        draftRevision: Int,
        sourceRevisionID: String,
        blocks: [TeleprompterV2ReadingBlock],
        goal: TeleprompterV2DurationGoal,
        pace: TeleprompterPace,
        timingAllocation: TeleprompterV2TimingAllocationSnapshot
    ) {
        self.id = id
        self.draftRevision = draftRevision
        self.sourceRevisionID = sourceRevisionID
        self.blocks = blocks
        self.goal = goal
        self.pace = pace
        self.timingAllocation = timingAllocation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case draftRevision = "draft_revision"
        case sourceRevisionID = "source_revision_id"
        case blocks
        case goal
        case pace
        case timingAllocation = "timing_allocation"
    }
}

public struct TeleprompterV2RunSummary: Codable, Equatable, Sendable {
    public let versionID: String
    public let targetSeconds: TimeInterval
    public let elapsedSeconds: TimeInterval
    public let lastSegmentID: String?
    /// UTF-16 offset inside `lastSegmentID`'s text. Absent in bundles written
    /// before intra-segment progress existed; decoding yields `nil`.
    public let lastSegmentOffset: Int?
    public let endedReason: String
    public let completedReading: Bool

    public init(
        versionID: String,
        targetSeconds: TimeInterval,
        elapsedSeconds: TimeInterval,
        lastSegmentID: String?,
        lastSegmentOffset: Int? = nil,
        endedReason: String,
        completedReading: Bool
    ) {
        self.versionID = versionID
        self.targetSeconds = targetSeconds
        self.elapsedSeconds = elapsedSeconds
        self.lastSegmentID = lastSegmentID
        self.lastSegmentOffset = lastSegmentOffset
        self.endedReason = endedReason
        self.completedReading = completedReading
    }

    private enum CodingKeys: String, CodingKey {
        case versionID = "version_id"
        case targetSeconds = "target_seconds"
        case elapsedSeconds = "elapsed_seconds"
        case lastSegmentID = "last_segment_id"
        case lastSegmentOffset = "last_segment_offset"
        case endedReason = "ended_reason"
        case completedReading = "completed_reading"
    }
}

public struct TeleprompterV2DocumentBundle: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var document: TeleprompterV2Document
    public var sourceRevisions: [TeleprompterV2SourceRevision]
    public var draft: TeleprompterV2ReadingDraft?
    public var versions: [TeleprompterV2ReadingVersion]
    public var lastRun: TeleprompterV2RunSummary?

    public init(
        formatVersion: Int = 3,
        document: TeleprompterV2Document,
        sourceRevisions: [TeleprompterV2SourceRevision],
        draft: TeleprompterV2ReadingDraft?,
        versions: [TeleprompterV2ReadingVersion],
        lastRun: TeleprompterV2RunSummary?
    ) {
        self.formatVersion = formatVersion
        self.document = document
        self.sourceRevisions = sourceRevisions
        self.draft = draft
        self.versions = versions
        self.lastRun = lastRun
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case document
        case sourceRevisions = "source_revisions"
        case draft
        case versions
        case lastRun = "last_run"
    }
}

public struct TeleprompterV2DocumentListItem: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let updatedAt: Date?
    public let isAvailable: Bool
    public let error: TeleprompterV2StoreError?

    public init(
        id: String,
        title: String?,
        updatedAt: Date?,
        isAvailable: Bool,
        error: TeleprompterV2StoreError? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.isAvailable = isAvailable
        self.error = error
    }
}

@MainActor
public final class TeleprompterV2Store {
    nonisolated public static let formatVersion = 3

    nonisolated private let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.directoryURL = applicationSupport
                .appendingPathComponent("SpeechRail", isDirectory: true)
                .appendingPathComponent("Teleprompter", isDirectory: true)
                .appendingPathComponent("documents", isDirectory: true)
        }
        try fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    nonisolated public func load(documentID: String) throws -> TeleprompterV2DocumentBundle {
        let url = try fileURL(documentID: documentID)
        guard FileManager.default.fileExists(atPath: url.path) else { throw TeleprompterV2StoreError.notFound }
        do {
            return try decode(Data(contentsOf: url))
        } catch let error as TeleprompterV2StoreError {
            throw error
        } catch {
            throw TeleprompterV2StoreError.corruptBundle
        }
    }

    public func listDocuments() throws -> [TeleprompterV2DocumentListItem] {
        try readDocuments().map(\.item)
    }

    /// A directory read decodes each bundle once. The list projection and the
    /// editor share that snapshot instead of reopening every document.
    func readDocuments() throws -> [(item: TeleprompterV2DocumentListItem, bundle: TeleprompterV2DocumentBundle?)] {
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        return urls.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            do {
                let bundle = try decode(Data(contentsOf: url))
                let item = TeleprompterV2DocumentListItem(
                    id: id, title: bundle.document.title,
                    updatedAt: bundle.document.updatedAt, isAvailable: true
                )
                return (item: item, bundle: Optional(bundle))
            } catch {
                let item = TeleprompterV2DocumentListItem(
                    id: id, title: nil, updatedAt: nil, isAvailable: false,
                    error: error as? TeleprompterV2StoreError ?? .corruptBundle
                )
                return (item: item, bundle: nil)
            }
        }.sorted { ($0.item.updatedAt ?? .distantPast) > ($1.item.updatedAt ?? .distantPast) }
    }

    public func save(_ bundle: TeleprompterV2DocumentBundle) throws {
        let destination = try fileURL(documentID: bundle.document.id)

        if fileManager.fileExists(atPath: destination.path) {
            do {
                let existing = try decodeExisting(Data(contentsOf: destination))
                switch existing {
                case let .v2(existingBundle):
                    try validateImmutableSourceRevisions(old: existingBundle, new: bundle)
                case let .future(version):
                    throw TeleprompterV2StoreError.unsupportedVersion(version)
                }
            } catch let error as TeleprompterV2StoreError {
                throw error
            } catch {
                throw TeleprompterV2StoreError.corruptBundle
            }
        }

        try validate(bundle)
        let data = try encode(bundle)
        try atomicWrite(data, to: destination)
    }

    public func duplicate(documentID: String) throws -> TeleprompterV2DocumentBundle {
        let original = try load(documentID: documentID)
        let newDocumentID = UUID().uuidString
        var sourceMap: [String: String] = [:]
        let sources = original.sourceRevisions.map { source -> TeleprompterV2SourceRevision in
            let newID = UUID().uuidString
            sourceMap[source.id] = newID
            let units = source.sourceUnits.map { unit in
                TeleprompterSourceUnit(
                    id: unit.id,
                    ordinal: unit.ordinal,
                    sourceRevisionID: newID,
                    sourceRange: unit.sourceRange,
                    rawText: unit.rawText,
                    continuation: unit.continuation,
                    budgetUnits: unit.budgetUnits
                )
            }
            return .init(
                id: newID,
                sourceText: source.sourceText,
                utf8SHA256: source.utf8SHA256,
                encoding: source.encoding,
                hasBOM: source.hasBOM,
                formatHint: source.formatHint,
                builderVersion: source.builderVersion,
                sourceUnits: units,
                createdAt: .now
            )
        }
        let versionMap = Dictionary(uniqueKeysWithValues: original.versions.map { ($0.id, UUID().uuidString) })
        let versions = original.versions.map { version -> TeleprompterV2ReadingVersion in
            let blocks = version.blocks.map { block in
                TeleprompterV2ReadingBlock(
                    id: UUID().uuidString,
                    revision: block.revision,
                    sourceUnitIDs: block.sourceUnitIDs,
                    text: block.text,
                    disposition: block.disposition,
                    origin: block.origin,
                    budgetShare: block.budgetShare
                )
            }
            let segments = version.segments.map { segment in
                TeleprompterV2ReadingSegment(
                    id: UUID().uuidString,
                    ordinal: segment.ordinal,
                    readingRange: segment.readingRange,
                    text: segment.text,
                    keywords: segment.keywords,
                    matchPhrases: segment.matchPhrases,
                    acceptedReadings: segment.acceptedReadings,
                    pauseHint: segment.pauseHint
                )
            }
            return .init(
                id: versionMap[version.id]!,
                documentID: newDocumentID,
                sourceRevisionID: sourceMap[version.sourceRevisionID]!,
                readingText: version.readingText,
                readingHash: version.readingHash,
                blocks: blocks,
                segments: segments,
                goalSnapshot: version.goalSnapshot,
                paceSnapshot: version.paceSnapshot,
                estimate: version.estimate,
                analysisSource: version.analysisSource,
                createdAt: .now
            )
        }
        let draft = original.draft.map { draft in
            TeleprompterV2ReadingDraft(
                id: UUID().uuidString,
                draftRevision: draft.draftRevision,
                sourceRevisionID: sourceMap[draft.sourceRevisionID]!,
                blocks: draft.blocks.map { block in
                    .init(
                        id: UUID().uuidString,
                        revision: block.revision,
                        sourceUnitIDs: block.sourceUnitIDs,
                        text: block.text,
                        disposition: block.disposition,
                        origin: block.origin,
                        budgetShare: block.budgetShare
                    )
                },
                goal: draft.goal,
                pace: draft.pace,
                timingAllocation: .init(
                    allocationRevision: draft.timingAllocation.allocationRevision,
                    plan: draft.timingAllocation.plan
                )
            )
        }
        let document = TeleprompterV2Document(
            id: newDocumentID,
            title: "\(original.document.title) 副本",
            currentSourceRevisionID: sourceMap[original.document.currentSourceRevisionID]!,
            activeVersionID: original.document.activeVersionID.flatMap { versionMap[$0] },
            createdAt: .now,
            updatedAt: .now
        )
        let copied = TeleprompterV2DocumentBundle(
            document: document,
            sourceRevisions: sources,
            draft: draft,
            versions: versions,
            lastRun: nil
        )
        try save(copied)
        return copied
    }

    public func delete(documentID: String) throws {
        let url = try fileURL(documentID: documentID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw TeleprompterV2StoreError.notFound
        }
        try fileManager.removeItem(at: url)
    }

    public func exportSource(_ bundle: TeleprompterV2DocumentBundle) throws -> Data {
        try validate(bundle)
        guard let source = bundle.sourceRevisions.first(where: { $0.id == bundle.document.currentSourceRevisionID }) else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        let body = Data(source.sourceText.utf8)
        return source.hasBOM ? Data([0xEF, 0xBB, 0xBF]) + body : body
    }

    public func exportReading(_ bundle: TeleprompterV2DocumentBundle) throws -> String {
        try validate(bundle)
        guard let version = bundle.versions.first(where: { $0.id == bundle.document.activeVersionID })
                ?? bundle.versions.first else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        return version.readingText.isEmpty ? "" : version.readingText + "\n"
    }

}

private extension TeleprompterV2Store {
    enum ExistingBundle {
        case v2(TeleprompterV2DocumentBundle)
        case future(Int)
    }

    nonisolated func fileURL(documentID: String) throws -> URL {
        guard !documentID.isEmpty,
              documentID.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil,
              documentID != ".",
              documentID != ".." else {
            throw TeleprompterV2StoreError.invalidDocumentID
        }
        return directoryURL.appendingPathComponent("\(documentID).json", isDirectory: false)
    }

    func encode(_ bundle: TeleprompterV2DocumentBundle) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            return try encoder.encode(bundle)
        } catch {
            throw TeleprompterV2StoreError.invalidBundle
        }
    }

    nonisolated func decode(_ data: Data) throws -> TeleprompterV2DocumentBundle {
        switch try decodeExisting(data) {
        case let .v2(bundle):
            try validate(bundle)
            return bundle
        case let .future(version):
            throw TeleprompterV2StoreError.unsupportedVersion(version)
        }
    }

    nonisolated func decodeExisting(_ data: Data) throws -> ExistingBundle {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["format_version"] as? NSNumber else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        let version = number.intValue
        if version > Self.formatVersion { return .future(version) }
        guard version == Self.formatVersion else { throw TeleprompterV2StoreError.invalidBundle }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return .v2(try decoder.decode(TeleprompterV2DocumentBundle.self, from: data))
        } catch {
            throw TeleprompterV2StoreError.corruptBundle
        }
    }

    nonisolated func validate(_ bundle: TeleprompterV2DocumentBundle) throws {
        guard bundle.formatVersion == Self.formatVersion,
              !bundle.document.id.isEmpty,
              !bundle.document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !bundle.sourceRevisions.isEmpty else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        let sourceIDs = bundle.sourceRevisions.map(\.id)
        guard sourceIDs.count == Set(sourceIDs).count,
              sourceIDs.contains(bundle.document.currentSourceRevisionID),
              bundle.document.activeVersionID == nil
                || bundle.versions.contains(where: { $0.id == bundle.document.activeVersionID }) else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        for source in bundle.sourceRevisions {
            guard !source.id.isEmpty,
                  source.encoding.lowercased() == "utf8",
                  !source.builderVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  TeleprompterV2Hash.sha256(source.sourceText) == source.utf8SHA256 else {
                throw TeleprompterV2StoreError.invalidBundle
            }
            let unitIDs = source.sourceUnits.map(\.id)
            guard unitIDs == Array(source.sourceUnits.indices),
                  source.sourceUnits.map(\.ordinal) == Array(source.sourceUnits.indices),
                  source.sourceUnits.allSatisfy({ $0.sourceRevisionID == source.id }),
                  source.sourceUnits.map(\.rawText).joined().data(using: .utf8)
                    == source.sourceText.data(using: .utf8) else {
                throw TeleprompterV2StoreError.invalidBundle
            }
            var expectedStart = 0
            for unit in source.sourceUnits {
                guard unit.sourceRange.isValid(in: source.sourceText),
                      unit.sourceRange.start == expectedStart,
                      let range = Range(
                          NSRange(
                              location: unit.sourceRange.start,
                              length: unit.sourceRange.end - unit.sourceRange.start
                          ),
                          in: source.sourceText
                      ),
                      String(source.sourceText[range]) == unit.rawText,
                      unit.budgetUnits > 0 else {
                    throw TeleprompterV2StoreError.invalidBundle
                }
                expectedStart = unit.sourceRange.end
            }
            guard expectedStart == source.sourceText.utf16.count else {
                throw TeleprompterV2StoreError.invalidBundle
            }
        }
        for version in bundle.versions {
            try validate(version, in: bundle)
        }
        if let draft = bundle.draft {
            guard sourceIDs.contains(draft.sourceRevisionID), draft.draftRevision >= 0 else {
                throw TeleprompterV2StoreError.invalidBundle
            }
            let source = bundle.sourceRevisions.first { $0.id == draft.sourceRevisionID }
            try validate(blocks: draft.blocks, source: source)
            try validate(timing: draft.timingAllocation.plan, source: source)
        }
        if let run = bundle.lastRun {
            guard bundle.versions.contains(where: { $0.id == run.versionID }),
                  run.targetSeconds.isFinite, run.targetSeconds >= 0,
                  run.elapsedSeconds.isFinite, run.elapsedSeconds >= 0 else {
                throw TeleprompterV2StoreError.invalidBundle
            }
        }
    }

    nonisolated func validate(_ version: TeleprompterV2ReadingVersion, in bundle: TeleprompterV2DocumentBundle) throws {
        guard version.documentID == bundle.document.id,
              bundle.sourceRevisions.contains(where: { $0.id == version.sourceRevisionID }),
              (try? TeleprompterTimingPlanner.validateTargetMinutes(version.goalSnapshot.targetSeconds / 60.0)) != nil,
              version.readingHash == TeleprompterV2Hash.sha256(version.readingText) else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        let source = bundle.sourceRevisions.first { $0.id == version.sourceRevisionID }
        guard let source else { throw TeleprompterV2StoreError.invalidBundle }
        try validate(blocks: version.blocks, source: source)
        let speakingText = version.blocks
            .filter { $0.disposition == .speak }
            .map(\.text)
            .joined(separator: "\n\n")
        guard speakingText == version.readingText else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        let segmentIDs = version.segments.map(\.id)
        guard !version.segments.isEmpty,
              segmentIDs.count == Set(segmentIDs).count,
              version.segments.enumerated().allSatisfy({ index, segment in
            segment.ordinal == index
                && segment.keywords.count <= 5
                && segment.matchPhrases.isEmpty
                && Self.acceptedReadingsAreValid(segment)
                && segment.readingRange.isValid(in: version.readingText)
                && Range(NSRange(location: segment.readingRange.start, length: segment.readingRange.end - segment.readingRange.start), in: version.readingText).map { String(version.readingText[$0]) == segment.text } ?? false
        }),
        version.segments.enumerated().reduce(0, { expectedStart, item in
            let segment = item.element
            guard segment.readingRange.start == expectedStart else { return Int.min }
            return segment.readingRange.end + (item.offset + 1 < version.segments.count ? 2 : 0)
        }) == version.readingText.utf16.count else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        guard version.goalSnapshot.targetSeconds.isFinite,
              version.goalSnapshot.targetSeconds > 0,
              version.estimate.pointSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              version.estimate.knownPartSeconds.isFinite,
              version.estimate.knownPartSeconds >= 0,
              version.estimate.rangeSeconds.map({ $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.lowerBound >= 0 && $0.upperBound >= $0.lowerBound }) ?? true else {
            throw TeleprompterV2StoreError.invalidBundle
        }
    }

    /// Aliases are written inside the same atomic save as the segment they belong
    /// to, so one that no longer describes its segment means the caller built the
    /// bundle wrong. Rejecting the save is safer than storing an alias that would
    /// later be silently dropped — or worse, honoured against the wrong words.
    nonisolated static func acceptedReadingsAreValid(_ segment: TeleprompterV2ReadingSegment) -> Bool {
        var previousEnd: Int?
        for alias in segment.acceptedReadings.sorted(by: { $0.displayRange.start < $1.displayRange.start }) {
            if let previousEnd, previousEnd > alias.displayRange.start { return false }
            if alias.rejection(inSegmentText: segment.text) != nil { return false }
            previousEnd = alias.displayRange.end
        }
        return true
    }

    nonisolated func validate(
        blocks: [TeleprompterV2ReadingBlock],
        source: TeleprompterV2SourceRevision?
    ) throws {
        let blockIDs = blocks.map(\.id)
        guard blockIDs.count == Set(blockIDs).count else { throw TeleprompterV2StoreError.invalidBundle }
        let sourceUnitIDs = Set(source?.sourceUnits.map(\.id) ?? [])
        for block in blocks {
            guard !block.id.isEmpty,
                  block.revision >= 0,
                  block.budgetShare.isFinite, block.budgetShare >= 0,
                  block.sourceUnitIDs == Array(Set(block.sourceUnitIDs)).sorted(),
                  block.sourceUnitIDs.allSatisfy({ sourceUnitIDs.contains($0) }) else {
                throw TeleprompterV2StoreError.invalidBundle
            }
            if block.disposition == .speak {
                guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TeleprompterV2StoreError.invalidBundle
                }
            }
        }
    }

    nonisolated func validate(
        timing: TeleprompterTimingPlan,
        source: TeleprompterV2SourceRevision?
    ) throws {
        guard let source,
              (try? TeleprompterTimingPlanner.validateTargetMinutes(timing.targetMinutes)) != nil,
              timing.targetSeconds.isFinite,
              abs(timing.targetSeconds - Double(timing.targetMinutes * 60)) <= 0.001,
              timing.budgetSeconds.isFinite,
              abs(timing.budgetSeconds - timing.targetSeconds * TeleprompterTimingPolicy.budgetRatio) <= 0.001 else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        let sourceIDs = source.sourceUnits.map(\.id)
        let allocationIDs = timing.allocations.map(\.sourceUnitID)
            guard allocationIDs == sourceIDs,
                  timing.allocations.allSatisfy({
                  $0.weight.isFinite && $0.weight >= 0
                      && $0.budgetSeconds.isFinite && $0.budgetSeconds >= 0
              }),
              abs(timing.allocations.reduce(0) { $0 + $1.budgetSeconds } - timing.budgetSeconds) <= 0.001 else {
            throw TeleprompterV2StoreError.invalidBundle
        }
        // 整篇都在跟读范围内，所以每个分配都必须有正权重。
        guard timing.allocations.allSatisfy({ $0.weight > 0 }) else {
            throw TeleprompterV2StoreError.invalidBundle
        }
    }

    nonisolated func overlaps(_ lhs: TeleprompterSourceRange, _ rhs: TeleprompterSourceRange) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    func validateImmutableSourceRevisions(
        old: TeleprompterV2DocumentBundle,
        new: TeleprompterV2DocumentBundle
    ) throws {
        for oldSource in old.sourceRevisions {
            guard let newSource = new.sourceRevisions.first(where: { $0.id == oldSource.id }) else {
                throw TeleprompterV2StoreError.immutableSourceRevision
            }
            guard oldSource.sourceText == newSource.sourceText,
                  oldSource.utf8SHA256 == newSource.utf8SHA256,
                  oldSource.sourceUnits == newSource.sourceUnits else {
                throw TeleprompterV2StoreError.immutableSourceRevision
            }
        }
    }

    func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = directoryURL.appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw TeleprompterV2StoreError.atomicWriteFailed
        }
    }
}
