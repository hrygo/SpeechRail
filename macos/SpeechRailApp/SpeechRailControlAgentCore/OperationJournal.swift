import Foundation
import SpeechRailControlKit

public struct OperationJournalEntry: Codable, Equatable, Sendable {
    public let operation: OperationSnapshot
    public let updatedAt: Date

    public init(operation: OperationSnapshot, updatedAt: Date = Date()) {
        self.operation = operation
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case operation
        case updatedAt = "updated_at"
    }
}

public struct OperationJournal: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public init(appHome: URL) {
        self.init(
            fileURL: appHome.standardizedFileURL
                .appendingPathComponent("control", isDirectory: true)
                .appendingPathComponent("active-operation.json", isDirectory: false)
        )
    }

    public func save(_ operation: OperationSnapshot, updatedAt: Date = Date()) throws {
        let entry = OperationJournalEntry(
            operation: Self.sanitized(operation),
            updatedAt: updatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let fileManager = FileManager.default
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directoryURL.path
        )

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: temporaryURL.path
        )

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(
                fileURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    public func load() throws -> OperationJournalEntry? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            OperationJournalEntry.self,
            from: Data(contentsOf: fileURL)
        )
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    static func sanitized(_ operation: OperationSnapshot) -> OperationSnapshot {
        let progress = operation.progress.map {
            OperationProgressSnapshot(
                phase: sanitizedText($0.phase),
                artifactKey: sanitizedIdentifier($0.artifactKey),
                file: sanitizedFileIdentifier($0.file),
                completedBytes: $0.completedBytes,
                expectedBytes: $0.expectedBytes
            )
        }
        return OperationSnapshot(
            operationID: sanitizedIdentifier(operation.operationID) ?? "operation",
            command: operation.command,
            profile: operation.profile,
            state: operation.state,
            phase: sanitizedText(operation.phase),
            progress: progress,
            errorCode: operation.errorCode,
            message: sanitizedMessage(operation.message)
        )
    }

    private static func sanitizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let characters = value.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        guard !characters.isEmpty else { return "[redacted]" }
        return String(characters.prefix(128))
    }

    private static func sanitizedFileIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let basename = value.split(separator: "/").last.map(String.init) ?? value
        return sanitizedIdentifier(basename)
    }

    private static func sanitizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        return String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
    }

    private static func sanitizedMessage(_ value: String?) -> String? {
        guard let value else { return nil }
        let redactedSecrets = replacingMatches(
            in: value,
            pattern: #"(?i)\b(api[_-]?key|authorization|token|secret|password)\b\s*[:=]\s*\S+"#,
            template: "$1=[redacted]"
        )
        let redactedPaths = replacingMatches(
            in: redactedSecrets,
            pattern: #"(?<![:\w])/[^\s"']+"#,
            template: "[path]"
        )
        return String(redactedPaths.prefix(240))
    }

    private static func replacingMatches(in value: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
