import Foundation

public enum TeleprompterStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidDocumentID
    case notFound
    case corruptBundle
    case invalidBundle
    case unsupportedImport

    public var errorDescription: String? {
        switch self {
        case .invalidDocumentID: "这份稿子无法打开"
        case .notFound: "找不到这份稿子"
        case .corruptBundle: "这份稿子已损坏"
        case .invalidBundle: "这份稿子无法使用"
        case .unsupportedImport: "请选择文本文件（TXT 或 Markdown）"
        }
    }
}

public enum TeleprompterTextImporter {
    public static func load(from url: URL) throws -> String {
        let extensionName = url.pathExtension.lowercased()
        guard extensionName == "txt" || extensionName == "md" || extensionName == "markdown" else {
            throw TeleprompterStoreError.unsupportedImport
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@MainActor
public final class TeleprompterStore {
    private let directoryURL: URL
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
    }

    public func listDocuments() throws -> [TeleprompterDocument] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .map { try loadBundle(at: $0).document }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func loadBundle(documentID: String) throws -> TeleprompterDocumentBundle {
        let url = try fileURL(documentID: documentID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw TeleprompterStoreError.notFound
        }
        return try loadBundle(at: url)
    }

    public func saveBundle(_ bundle: TeleprompterDocumentBundle) throws {
        try validate(bundle)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data: Data
        do {
            data = try encoder.encode(bundle)
        } catch {
            throw TeleprompterStoreError.invalidBundle
        }

        let destination = try fileURL(documentID: bundle.document.id)
        let temporary = directoryURL.appendingPathComponent(".\(bundle.document.id).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public func updateRunState(_ state: TeleprompterRunState) throws {
        var bundle = try loadBundle(documentID: state.documentID)
        guard bundle.versions.contains(where: { $0.id == state.versionID }) else {
            throw TeleprompterStoreError.invalidBundle
        }
        bundle.runState = state
        bundle.document.updatedAt = state.lastUpdatedAt
        try saveBundle(bundle)
    }

    public func deleteDocument(documentID: String) throws {
        let url = try fileURL(documentID: documentID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw TeleprompterStoreError.notFound
        }
        try fileManager.removeItem(at: url)
    }

    public func duplicateDocument(documentID: String) throws -> TeleprompterDocumentBundle {
        let original = try loadBundle(documentID: documentID)
        let newDocID = UUID().uuidString
        let now = Date()
        let newTitle = "\(original.document.title) 副本"

        var idMap: [String: String] = [:]
        let newVersions = original.versions.map { v in
            let newVID = UUID().uuidString
            idMap[v.id] = newVID
            let newSegments = v.segments.map { s in
                TeleprompterSegment(
                    id: UUID().uuidString,
                    ordinal: s.ordinal,
                    sourceRange: s.sourceRange,
                    text: s.text,
                    keywords: s.keywords,
                    matchPhrases: s.matchPhrases,
                    pauseHint: s.pauseHint
                )
            }
            return TeleprompterVersion(
                id: newVID,
                documentID: newDocID,
                sourceText: v.sourceText,
                segments: newSegments,
                analysisSource: v.analysisSource,
                createdAt: now
            )
        }
        let newActiveVID = original.document.activeVersionID.flatMap { idMap[$0] }
        let newDoc = TeleprompterDocument(
            id: newDocID,
            title: newTitle,
            sourceText: original.document.sourceText,
            activeVersionID: newActiveVID,
            createdAt: now,
            updatedAt: now
        )
        let newBundle = TeleprompterDocumentBundle(
            document: newDoc,
            versions: newVersions,
            runState: nil
        )
        try saveBundle(newBundle)
        return newBundle
    }

    public func exportMarkdown(_ bundle: TeleprompterDocumentBundle) -> String {
        let version = bundle.versions.first { $0.id == bundle.document.activeVersionID }
            ?? bundle.versions.first
        let body = version?.segments.map(\.text).joined(separator: "\n\n") ?? bundle.document.sourceText
        return "# \(bundle.document.title)\n\n\(body)\n"
    }

    private func loadBundle(at url: URL) throws -> TeleprompterDocumentBundle {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(TeleprompterDocumentBundle.self, from: data)
        } catch {
            throw TeleprompterStoreError.corruptBundle
        }
    }

    private func fileURL(documentID: String) throws -> URL {
        guard !documentID.isEmpty,
              documentID.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil,
              documentID != ".",
              documentID != ".." else {
            throw TeleprompterStoreError.invalidDocumentID
        }
        return directoryURL.appendingPathComponent("\(documentID).json", isDirectory: false)
    }

    private func validate(_ bundle: TeleprompterDocumentBundle) throws {
        guard !bundle.document.id.isEmpty,
              !bundle.document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bundle.versions.allSatisfy({ $0.documentID == bundle.document.id }),
              bundle.document.activeVersionID == nil
                  || bundle.versions.contains(where: { $0.id == bundle.document.activeVersionID }) else {
            throw TeleprompterStoreError.invalidBundle
        }
        for version in bundle.versions {
            guard !version.segments.isEmpty,
                  version.segments.enumerated().allSatisfy({ $0.element.ordinal == $0.offset }) else {
                throw TeleprompterStoreError.invalidBundle
            }
        }
    }
}
