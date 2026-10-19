import Foundation

/// 只读 EPUB 导入：把 spine 顺序的 XHTML 转成规范纯文本，再交给既有 TXT 导入与分章流程。
/// 应用不保留原始 EPUB，也不执行其中的脚本、样式或外部资源。
public enum AudiobookEPUBError: LocalizedError, Equatable, Sendable {
    case notEPUB
    case fileTooLarge
    case archiveUnreadable
    case encryptedArchive
    case unsafeArchivePath
    case extractionFailed
    case missingContainer
    case missingPackage
    case emptyContent

    public var errorDescription: String? {
        switch self {
        case .notEPUB: return "这不是可读取的 EPUB 文件。"
        case .fileTooLarge: return "EPUB 文件或解压后的内容超过导入上限。"
        case .archiveUnreadable: return "EPUB 压缩包已损坏或格式不受支持。"
        case .encryptedArchive: return "EPUB 受 DRM/加密保护，无法导入。"
        case .unsafeArchivePath: return "EPUB 包含不安全的路径或符号链接，已拒绝导入。"
        case .extractionFailed: return "EPUB 解压失败，文件可能已损坏。"
        case .missingContainer: return "EPUB 缺少 META-INF/container.xml，无法定位正文。"
        case .missingPackage: return "EPUB 缺少可读取的 OPF 包文件或 spine 目录。"
        case .emptyContent: return "EPUB 中没有可导入的正文。"
        }
    }
}

public struct AudiobookEPUBContent: Equatable, Sendable {
    public let title: String?
    public let author: String?
    public let text: String
}

public enum AudiobookEPUBImporter {
    public static let maxArchiveBytes: Int64 = 256 * 1024 * 1024
    public static let maxUncompressedBytes: Int64 = 256 * 1024 * 1024
    public static let maxEntries = 20_000

    public static func extractText(from fileURL: URL) throws -> AudiobookEPUBContent {
        let standardized = fileURL.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "epub" else { throw AudiobookEPUBError.notEPUB }
        let values = try standardized.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw AudiobookEPUBError.archiveUnreadable }
        guard Int64(values.fileSize ?? 0) <= maxArchiveBytes else { throw AudiobookEPUBError.fileTooLarge }
        try validateArchive(at: standardized)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try extract(archive: standardized, to: root)
        try validateExtractedTree(root)

        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw AudiobookEPUBError.missingContainer
        }
        let packagePath = try parseContainer(at: containerURL)
        let packageURL = try resolve(relativePath: packagePath, under: root)
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw AudiobookEPUBError.missingPackage
        }
        let package = try parsePackage(at: packageURL)

        var pieces: [String] = []
        for href in package.spineHrefs {
            let fileURL = try resolve(relativePath: href, under: packageURL.deletingLastPathComponent())
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 8 * 1024 * 1024 else { continue }
            let html = String(decoding: data, as: UTF8.self)
            let text = plainText(fromXHTML: html)
            if !text.isEmpty { pieces.append(text) }
        }
        let body = pieces.joined(separator: "\n\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudiobookEPUBError.emptyContent
        }
        return AudiobookEPUBContent(title: package.title, author: package.author, text: body)
    }

    // MARK: - ZIP preflight

    private static func validateArchive(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AudiobookEPUBError.archiveUnreadable
        }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw AudiobookEPUBError.archiveUnreadable }
        let tailLength = Int(min(size, 65_557))
        try handle.seek(toOffset: size - UInt64(tailLength))
        guard let tail = try handle.read(upToCount: tailLength) else {
            throw AudiobookEPUBError.archiveUnreadable
        }
        guard let eocd = findEOCD(in: tail) else { throw AudiobookEPUBError.archiveUnreadable }
        let entryCount = Int(u16(tail, eocd + 10))
        let directorySize = Int(u32(tail, eocd + 12))
        let directoryOffset = Int(u32(tail, eocd + 16))
        guard entryCount > 0, entryCount <= maxEntries,
              directorySize > 0, directoryOffset >= 0,
              UInt64(directoryOffset + directorySize) <= size
        else { throw AudiobookEPUBError.archiveUnreadable }

        try handle.seek(toOffset: UInt64(directoryOffset))
        guard let directory = try handle.read(upToCount: directorySize) else {
            throw AudiobookEPUBError.archiveUnreadable
        }
        var index = 0
        var total: Int64 = 0
        var seen = 0
        while index + 46 <= directory.count {
            guard u32(directory, index) == 0x02014b50 else { throw AudiobookEPUBError.archiveUnreadable }
            let flags = u16(directory, index + 8)
            let method = u16(directory, index + 10)
            let compressed = Int64(u32(directory, index + 20))
            let uncompressed = Int64(u32(directory, index + 24))
            let nameLength = Int(u16(directory, index + 28))
            let extraLength = Int(u16(directory, index + 30))
            let commentLength = Int(u16(directory, index + 32))
            // ZIP 外部属性高 16 位是 Unix mode；提前拒绝符号链接，避免解压阶段跟随链接写出临时目录。
            let unixMode = UInt16((u32(directory, index + 38) >> 16) & 0xFFFF)
            if unixMode & 0xF000 == 0xA000 { throw AudiobookEPUBError.unsafeArchivePath }
            guard index + 46 + nameLength + extraLength + commentLength <= directory.count else {
                throw AudiobookEPUBError.archiveUnreadable
            }
            let nameStart = index + 46
            let name = String(decoding: directory[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            if flags & 0x1 != 0 { throw AudiobookEPUBError.encryptedArchive }
            guard method == 0 || method == 8 else { throw AudiobookEPUBError.archiveUnreadable }
            guard !name.hasPrefix("/"),
                  !name.hasPrefix("\\"),
                  !name.contains("\0"),
                  !name.split(separator: "/").contains("..")
            else {
                throw AudiobookEPUBError.unsafeArchivePath
            }
            guard compressed >= 0, uncompressed >= 0, uncompressed <= maxUncompressedBytes else {
                throw AudiobookEPUBError.fileTooLarge
            }
            total += uncompressed
            guard total <= maxUncompressedBytes else { throw AudiobookEPUBError.fileTooLarge }
            seen += 1
            index += 46 + nameLength + extraLength + commentLength
        }
        guard seen == entryCount else { throw AudiobookEPUBError.archiveUnreadable }
    }

    private static func findEOCD(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var index = data.count - 22
        while index >= 0 {
            if u32(data, index) == 0x06054b50 {
                let commentLength = Int(u16(data, index + 20))
                if index + 22 + commentLength == data.count { return index }
            }
            index -= 1
        }
        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - Extraction

    private static func extract(archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw AudiobookEPUBError.extractionFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AudiobookEPUBError.extractionFailed }
    }

    private static func validateExtractedTree(_ root: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []
        ) else { throw AudiobookEPUBError.extractionFailed }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw AudiobookEPUBError.unsafeArchivePath }
            let standardized = url.standardizedFileURL.path
            guard standardized.hasPrefix(root.standardizedFileURL.path + "/") else {
                throw AudiobookEPUBError.unsafeArchivePath
            }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
                guard total <= maxUncompressedBytes else { throw AudiobookEPUBError.fileTooLarge }
            }
        }
    }

    private static func resolve(relativePath: String, under base: URL) throws -> URL {
        let decoded = relativePath.removingPercentEncoding ?? relativePath
        guard !decoded.hasPrefix("/"), !decoded.split(separator: "/").contains("..") else {
            throw AudiobookEPUBError.unsafeArchivePath
        }
        let url = base.appendingPathComponent(decoded).standardizedFileURL
        guard url.path.hasPrefix(base.standardizedFileURL.path + "/") else {
            throw AudiobookEPUBError.unsafeArchivePath
        }
        return url
    }

    // MARK: - Package parsing

    private static func parseContainer(at url: URL) throws -> String {
        let delegate = ContainerDelegate()
        let parser = XMLParser(data: try Data(contentsOf: url))
        parser.delegate = delegate
        guard parser.parse(), let path = delegate.rootfilePath else {
            throw AudiobookEPUBError.missingContainer
        }
        return path
    }

    private static func parsePackage(at url: URL) throws -> PackageInfo {
        let delegate = PackageDelegate()
        let parser = XMLParser(data: try Data(contentsOf: url))
        parser.delegate = delegate
        guard parser.parse(), !delegate.spineIDs.isEmpty else {
            throw AudiobookEPUBError.missingPackage
        }
        let spineHrefs = delegate.spineIDs.compactMap { delegate.manifest[$0] }.compactMap { raw -> String? in
            let href = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? raw
            let lower = href.lowercased()
            return lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm")
                ? href : nil
        }
        guard !spineHrefs.isEmpty else { throw AudiobookEPUBError.missingPackage }
        return PackageInfo(
            title: delegate.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            author: delegate.author?.trimmingCharacters(in: .whitespacesAndNewlines),
            spineHrefs: spineHrefs
        )
    }

    private struct PackageInfo {
        let title: String?
        let author: String?
        let spineHrefs: [String]
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
    }

    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        var rootfilePath: String?
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if localName(elementName) == "rootfile", rootfilePath == nil {
                rootfilePath = attributeDict["full-path"]
            }
        }
    }

    private final class PackageDelegate: NSObject, XMLParserDelegate {
        var title: String?
        var author: String?
        var manifest: [String: String] = [:]
        var spineIDs: [String] = []
        private var collecting: String?
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch localName(elementName) {
            case "item":
                if let id = attributeDict["id"], let href = attributeDict["href"] {
                    manifest[id] = href
                }
            case "itemref":
                if attributeDict["linear"]?.lowercased() != "no", let idref = attributeDict["idref"] {
                    spineIDs.append(idref)
                }
            case "title" where title == nil:
                collecting = "title"; buffer = ""
            case "creator" where author == nil:
                collecting = "creator"; buffer = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collecting != nil { buffer += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let kind = collecting, localName(elementName) == kind else { return }
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == "title" { title = value } else { author = value }
            collecting = nil
            buffer = ""
        }
    }

    // MARK: - XHTML to text

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "footer", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "tr", "ul"
    ]

    private static func plainText(fromXHTML html: String) -> String {
        let normalized = normalizeHTMLEntities(html)
        let delegate = XHTMLTextDelegate()
        if let data = normalized.data(using: .utf8) {
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldResolveExternalEntities = false
            if parser.parse() {
                return clean(delegate.output)
            }
        }
        // 非严格 XHTML 的兜底：去掉标签，保留段落边界。
        let stripped = normalized.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        return clean(decodeNumericEntities(stripped))
    }

    private final class XHTMLTextDelegate: NSObject, XMLParserDelegate {
        var output = ""
        private var skipDepth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = localName(elementName)
            if name == "script" || name == "style" || name == "head" {
                skipDepth += 1
                return
            }
            guard skipDepth == 0 else { return }
            if blockTags.contains(name) { output += "\n" }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = localName(elementName)
            if name == "script" || name == "style" || name == "head" {
                skipDepth = max(0, skipDepth - 1)
                return
            }
            guard skipDepth == 0 else { return }
            if blockTags.contains(name) { output += "\n" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skipDepth == 0 else { return }
            output += string
        }
    }

    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .newlines)
            .map {
                $0.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static let entityMap: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "copy": "©"
    ]

    private static func normalizeHTMLEntities(_ html: String) -> String {
        let pattern = "&([a-zA-Z][a-zA-Z0-9]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let ns = html as NSString
        var result = html
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            // XML 预定义实体交给 XMLParser，提前替换会把 & 变成非法裸字符并触发兜底解析。
            guard !["amp", "lt", "gt", "quot", "apos"].contains(name),
                  let replacement = entityMap[name]
            else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        text.replacingOccurrences(
            of: "&#(x?[0-9A-Fa-f]+);",
            with: " ",
            options: .regularExpression
        )
    }
}
