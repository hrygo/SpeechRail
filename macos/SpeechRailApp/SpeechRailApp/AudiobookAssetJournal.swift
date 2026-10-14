import Foundation

public enum AudiobookCommitCrashStage: String, Codable, Equatable, Sendable, CaseIterable {
    case afterJournalStarted
    case afterTempAssetWritten
    case afterAssetRenamed
    case afterDatabaseCommitted
    case afterJournalCompleted
}

public enum AudiobookAssetTransactionState: String, Codable, Equatable, Sendable {
    case journalStarted
    case tempWritten
    case assetMoved
    case dbCommitted
    case completed
    case quarantined
}

public struct AudiobookAssetJournalEntry: Codable, Equatable, Sendable {
    public let candidate: AudiobookRenderCandidate
    public let tempRelativePath: String
    public var state: AudiobookAssetTransactionState
    public var updatedAt: Date

    public init(
        candidate: AudiobookRenderCandidate,
        tempRelativePath: String,
        state: AudiobookAssetTransactionState,
        updatedAt: Date = Date()
    ) {
        self.candidate = candidate
        self.tempRelativePath = tempRelativePath
        self.state = state
        self.updatedAt = updatedAt
    }
}

public struct AudiobookRecoveryReport: Codable, Equatable, Sendable {
    public let verifiedCandidateIDs: [UUID]
    public let recoveredCandidateIDs: [UUID]
    public let quarantinedRelativePaths: [String]
    public let preservedUnknownRelativePaths: [String]
    public let damagedCandidateIDs: [UUID]

    public init(
        verifiedCandidateIDs: [UUID] = [],
        recoveredCandidateIDs: [UUID] = [],
        quarantinedRelativePaths: [String] = [],
        preservedUnknownRelativePaths: [String] = [],
        damagedCandidateIDs: [UUID] = []
    ) {
        self.verifiedCandidateIDs = verifiedCandidateIDs
        self.recoveredCandidateIDs = recoveredCandidateIDs
        self.quarantinedRelativePaths = quarantinedRelativePaths
        self.preservedUnknownRelativePaths = preservedUnknownRelativePaths
        self.damagedCandidateIDs = damagedCandidateIDs
    }
}

public struct AudiobookTrashedBookEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let author: String?
    public let trashedAt: Date
    public let trashDirectoryName: String
    public let byteSize: Int64

    public init(
        id: UUID,
        title: String,
        author: String?,
        trashedAt: Date,
        trashDirectoryName: String,
        byteSize: Int64
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.trashedAt = trashedAt
        self.trashDirectoryName = trashDirectoryName
        self.byteSize = byteSize
    }
}

/// Manages sidecar transaction journal files in `books/<bookID>/journal/` to bridge
/// filesystem asset writes and SQLite commits across process crashes.
public struct AudiobookAssetJournal: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func journalFileURL(bookID: UUID, candidateID: UUID) -> URL {
        rootURL
            .appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("\(candidateID.uuidString).json", isDirectory: false)
    }

    public func write(_ entry: AudiobookAssetJournalEntry) throws {
        let url = journalFileURL(bookID: entry.candidate.bookID, candidateID: entry.candidate.id)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        try data.write(to: url, options: .atomic)
    }

    public func remove(bookID: UUID, candidateID: UUID) {
        let url = journalFileURL(bookID: bookID, candidateID: candidateID)
        try? FileManager.default.removeItem(at: url)
    }

    public func pendingEntries(bookID: UUID) -> [AudiobookAssetJournalEntry] {
        let dir = rootURL
            .appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent("journal", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(AudiobookAssetJournalEntry.self, from: $0) }
    }
}
