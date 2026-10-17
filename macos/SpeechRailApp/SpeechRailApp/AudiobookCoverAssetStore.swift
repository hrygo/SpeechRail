import Foundation

/// F3: a validated, book-owned cover image. The reported `relativePath` is the exact
/// lowercase-UUID form the manifest validator accepts (`books/<book_id>/cover/cover.<ext>`),
/// even though the on-disk book directory keeps the store's uppercase UUID spelling.
public struct AudiobookCoverAsset: Codable, Equatable, Sendable {
    public let bookID: UUID
    public let relativePath: String
    public let fileSHA256: String
    public let byteCount: Int64

    public init(bookID: UUID, relativePath: String, fileSHA256: String, byteCount: Int64) {
        self.bookID = bookID
        self.relativePath = relativePath
        self.fileSHA256 = fileSHA256
        self.byteCount = byteCount
    }
}

public enum AudiobookCoverAssetError: LocalizedError, Equatable, Sendable {
    case unsupportedType
    case tooLarge(Int64)
    case unreadable
    case notRegularFile

    public var errorDescription: String? {
        switch self {
        case .unsupportedType:
            "请选择 JPG 或 PNG 格式的封面图片。"
        case let .tooLarge(limit):
            "封面图片过大：需小于 \(limit / (1024 * 1024)) MB，请换一张更小的图片。"
        case .unreadable:
            "无法读取所选封面图片；文件可能已损坏或为空，请重新选择。"
        case .notRegularFile:
            "所选封面不是普通图片文件；请重新选择本机上的图片。"
        }
    }
}

public enum AudiobookCoverLimits {
    public static let maxBytes: Int64 = 8 * 1024 * 1024
    public static let allowedExtensions: Set<String> = ["jpg", "jpeg", "png"]
}

public actor AudiobookCoverAssetStore {
    private let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
    }

    public func install(bookID: UUID, sourceURL: URL) throws -> AudiobookCoverAsset {
        let source = sourceURL.standardizedFileURL
        let sourceValues = try source.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw AudiobookCoverAssetError.notRegularFile
        }

        let ext = source.pathExtension.lowercased()
        guard AudiobookCoverLimits.allowedExtensions.contains(ext) else {
            throw AudiobookCoverAssetError.unsupportedType
        }

        let byteCount = Int64(sourceValues.fileSize ?? 0)
        guard byteCount > 0 else {
            throw AudiobookCoverAssetError.unreadable
        }
        guard byteCount <= AudiobookCoverLimits.maxBytes else {
            throw AudiobookCoverAssetError.tooLarge(AudiobookCoverLimits.maxBytes)
        }

        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw AudiobookCoverAssetError.unreadable
        }
        guard !data.isEmpty else {
            throw AudiobookCoverAssetError.unreadable
        }

        let coverDir = bookCoverDirectory(bookID: bookID)
        try fileManager.createDirectory(at: coverDir, withIntermediateDirectories: true)
        let dirValues = try coverDir.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard dirValues.isSymbolicLink != true else {
            throw AudiobookCoverAssetError.notRegularFile
        }

        let existingFiles = try fileManager.contentsOfDirectory(at: coverDir, includingPropertiesForKeys: nil)
        for existingFile in existingFiles {
            try? fileManager.removeItem(at: existingFile)
        }

        let destination = coverDir.appendingPathComponent("cover.\(ext)", isDirectory: false)
        let temporary = coverDir.appendingPathComponent(".cover.\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }

        return AudiobookCoverAsset(
            bookID: bookID,
            relativePath: Self.relativePath(bookID: bookID, ext: ext),
            fileSHA256: AudiobookDigest.sha256Hex(data),
            byteCount: byteCount
        )
    }

    public func existing(bookID: UUID) throws -> AudiobookCoverAsset? {
        let coverDir = bookCoverDirectory(bookID: bookID)
        guard fileManager.fileExists(atPath: coverDir.path) else { return nil }
        let contents = try fileManager.contentsOfDirectory(
            at: coverDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard let file = contents.first(where: { storedCoverExtension(of: $0) != nil }),
              let ext = storedCoverExtension(of: file)
        else {
            return nil
        }
        let values = try file.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw AudiobookCoverAssetError.unreadable
        }
        guard !data.isEmpty else { return nil }
        return AudiobookCoverAsset(
            bookID: bookID,
            relativePath: Self.relativePath(bookID: bookID, ext: ext),
            fileSHA256: AudiobookDigest.sha256Hex(data),
            byteCount: Int64(values.fileSize ?? data.count)
        )
    }

    public func coverFileURL(bookID: UUID) -> URL? {
        let coverDir = bookCoverDirectory(bookID: bookID)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: coverDir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        return contents.first(where: { storedCoverExtension(of: $0) != nil })
    }

    public func remove(bookID: UUID) throws {
        let coverDir = bookCoverDirectory(bookID: bookID)
        guard fileManager.fileExists(atPath: coverDir.path) else { return }
        try fileManager.removeItem(at: coverDir)
    }

    private func storedCoverExtension(of url: URL) -> String? {
        guard url.deletingPathExtension().lastPathComponent == "cover" else { return nil }
        let ext = url.pathExtension.lowercased()
        return AudiobookCoverLimits.allowedExtensions.contains(ext) ? ext : nil
    }

    private func bookCoverDirectory(bookID: UUID) -> URL {
        root
            .appendingPathComponent("books", isDirectory: true)
            .appendingPathComponent(bookID.uuidString, isDirectory: true)
            .appendingPathComponent("cover", isDirectory: true)
    }

    private static func relativePath(bookID: UUID, ext: String) -> String {
        "books/\(bookID.uuidString.lowercased())/cover/cover.\(ext)"
    }
}