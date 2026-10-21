import CoreFoundation
import Foundation

public enum AudiobookTextEncoding: String, Codable, Equatable, Hashable, CaseIterable, Sendable, Identifiable {
    case utf8 = "utf-8"
    case utf16LE = "utf-16le"
    case utf16BE = "utf-16be"
    case gb18030 = "gb18030"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .gb18030: "GB18030"
        }
    }
}

public enum AudiobookImportError: Error, Equatable, Sendable, LocalizedError {
    case fileNotFound(String)
    case fileTooLarge(byteCount: Int64, maxBytes: Int)
    case tooManyScalars(scalarCount: Int, maxScalars: Int)
    case emptyFile
    case missingUTF16BOM(AudiobookTextEncoding)
    case oddUTF16ByteCount(Int)
    case invalidEncoding(AudiobookTextEncoding)
    case encodingSelectionRequired(candidates: [AudiobookTextEncoding])
    case chapterCoverageInvalid(AudiobookSourceError)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            "找不到所选的 TXT 文件。"
        case let .fileTooLarge(byteCount, maxBytes):
            "文件大小（\(byteCount) 字节）超过上限（\(maxBytes) 字节）。"
        case let .tooManyScalars(scalarCount, maxScalars):
            "全书字数（\(scalarCount) 字符）超过上限（\(maxScalars) 字符）。"
        case .emptyFile:
            "所选 TXT 文件内容为空。"
        case let .missingUTF16BOM(encoding):
            "\(encoding.displayName) 解码需要对应的字节序标记（BOM）。"
        case .oddUTF16ByteCount:
            "UTF-16 文件字节数不是偶数，文件可能已损坏。"
        case let .invalidEncoding(encoding):
            "文件内容包含无法按 \(encoding.displayName) 严格解码的字节，已拒绝有损替换。"
        case .encodingSelectionRequired:
            "自动检测发现文字编码存在多字节歧义，请手动选择编码并核对正文预览后再导入。"
        case let .chapterCoverageInvalid(sourceError):
            sourceError.errorDescription ?? "章节划分未能完整覆盖正文。"
        }
    }
}

public struct AudiobookRepeatedContentWarning: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let chapterIDs: [UUID]
}

public struct AudiobookImportPreview: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let bookID: UUID
    public let sourceID: UUID
    public var title: String
    public var author: String?
    public let originalFileName: String
    public let originalBytes: Data
    public let canonicalUTF8: Data
    public let referenceUTF8: Data
    public let preparedText: AudiobookPreparedText
    public let sourceIndex: AudiobookSourceIndex
    public let detectedEncoding: AudiobookTextEncoding
    public let candidateEncodings: [AudiobookTextEncoding]
    public let requiresEncodingConfirmation: Bool
    public let previewText: String
    public var chapters: [AudiobookChapter]
    /// 自动识别出的目录页来源区间；已并入章节排除区间，不参与正文与原子。
    public let tableOfContentsRanges: [AudiobookSourceRange]
    public let repeatedContentWarnings: [AudiobookRepeatedContentWarning]
    public var hasConfirmedRepeatedContent: Bool

    public var canConfirmImport: Bool {
        repeatedContentWarnings.isEmpty || hasConfirmedRepeatedContent
    }

    /// EPUB 导入会转成规范纯文本；原始压缩包不进入作品库，也不显示编码切换。
    public var isEPUB: Bool {
        originalFileName.lowercased().hasSuffix(".epub")
    }

    public init(
        id: UUID = UUID(),
        bookID: UUID = UUID(),
        sourceID: UUID = UUID(),
        title: String,
        author: String? = nil,
        originalFileName: String,
        originalBytes: Data,
        canonicalUTF8: Data,
        sourceIndex: AudiobookSourceIndex,
        referenceUTF8: Data,
        preparedText: AudiobookPreparedText,
        detectedEncoding: AudiobookTextEncoding,
        candidateEncodings: [AudiobookTextEncoding],
        requiresEncodingConfirmation: Bool = false,
        previewText: String,
        chapters: [AudiobookChapter],
        tableOfContentsRanges: [AudiobookSourceRange] = [],
        repeatedContentWarnings: [AudiobookRepeatedContentWarning] = [],
        hasConfirmedRepeatedContent: Bool = false
    ) {
        self.id = id
        self.bookID = bookID
        self.sourceID = sourceID
        self.title = title
        self.author = author
        self.originalFileName = originalFileName
        self.originalBytes = originalBytes
        self.canonicalUTF8 = canonicalUTF8
        self.referenceUTF8 = referenceUTF8
        self.preparedText = preparedText
        self.sourceIndex = sourceIndex
        self.detectedEncoding = detectedEncoding
        self.candidateEncodings = candidateEncodings
        self.requiresEncodingConfirmation = requiresEncodingConfirmation
        self.previewText = previewText
        self.chapters = chapters
        self.tableOfContentsRanges = tableOfContentsRanges
        self.repeatedContentWarnings = repeatedContentWarnings
        self.hasConfirmedRepeatedContent = hasConfirmedRepeatedContent
    }

    public var sourceSHA256: String {
        sourceIndex.sourceSHA256
    }

    public var scalarCount: Int {
        sourceIndex.scalarCount
    }

    public var canonicalByteCount: Int64 {
        sourceIndex.byteCount
    }

    public func textPreview(for chapterID: UUID?, originalLayout: Bool = false) throws -> String {
        let chapter = chapters.first(where: { $0.id == chapterID })
        if originalLayout {
            let workRange = chapter?.sourceRange ?? sourceIndex.wholeRange
            let spans = preparedText.sourceMap.filter { $0.workingRange.lowerBound < workRange.upperBound && workRange.lowerBound < $0.workingRange.upperBound }
            let start = spans.first?.referenceRange.lowerBound ?? 0
            let end = spans.last?.referenceRange.upperBound ?? Int64(referenceUTF8.count)
            let reference = try AudiobookSourceIndex(utf8: referenceUTF8)
            let text = try reference.text(in: .init(lowerBound: start, upperBound: end))
            return String(text.unicodeScalars.prefix(AudiobookLimits.maxPreviewScalars))
        }
        let range = chapter?.sourceRange ?? sourceIndex.wholeRange
        try sourceIndex.validateRangeBounds(range)
        let exclusions = (chapter?.excludedRanges ?? []).compactMap { excluded -> AudiobookSourceRange? in
            let lower = max(excluded.lowerBound, range.lowerBound)
            let upper = min(excluded.upperBound, range.upperBound)
            return lower < upper ? AudiobookSourceRange(lowerBound: lower, upperBound: upper) : nil
        }
        var remaining = AudiobookLimits.maxPreviewScalars
        var pieces: [String] = []
        let spans = try sourceIndex.readableRanges(in: range, excluding: exclusions)
        for span in spans where remaining > 0 {
            let startScalar = sourceIndex.scalarIndex(forByteOffset: span.lowerBound) ?? 0
            let endScalar = sourceIndex.scalarIndex(forByteOffset: span.upperBound) ?? startScalar
            let take = min(max(0, endScalar - startScalar), remaining)
            guard take > 0 else { continue }
            let bounded = AudiobookSourceRange(
                lowerBound: span.lowerBound,
                upperBound: Int64(sourceIndex.scalarByteOffsets[startScalar + take])
            )
            let piece = try originalLayout
                ? sourceIndex.text(in: bounded)
                : sourceIndex.text(in: bounded)
            if !piece.isEmpty { pieces.append(piece) }
            remaining -= take
        }
        return pieces.joined(separator: originalLayout ? "" : "\n\n")
    }
}

public enum AudiobookTXTImporter {
    /// Reads a local TXT file with strict size guard and no network/AI side effects.
    public static func prepare(
        fileURL: URL,
        encoding: AudiobookTextEncoding? = nil,
        maxRawBytes: Int = AudiobookLimits.maxRawFileBytes,
        maxScalars: Int = AudiobookLimits.maxTotalScalars
    ) async throws -> AudiobookImportPreview {
        let standardized = fileURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw AudiobookImportError.fileNotFound(standardized.lastPathComponent)
        }

        let values = try standardized.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if let fileSize = values.fileSize, Int64(fileSize) > Int64(maxRawBytes) {
            throw AudiobookImportError.fileTooLarge(byteCount: Int64(fileSize), maxBytes: maxRawBytes)
        }

        let handle = try FileHandle(forReadingFrom: standardized)
        defer { try? handle.close() }
        let readLimit = maxRawBytes + 1
        let rawData = try handle.read(upToCount: readLimit) ?? Data()
        if rawData.count > maxRawBytes {
            throw AudiobookImportError.fileTooLarge(byteCount: Int64(rawData.count), maxBytes: maxRawBytes)
        }

        let baseTitle = standardized.deletingPathExtension().lastPathComponent
        return try prepare(
            rawData: rawData,
            suggestedTitle: baseTitle.isEmpty ? "未命名书籍" : baseTitle,
            originalFileName: standardized.lastPathComponent,
            encoding: encoding,
            maxRawBytes: maxRawBytes,
            maxScalars: maxScalars
        )
    }

    /// Synchronous pure preparation for in-memory bytes and deterministic tests.
    /// 只读解析 EPUB（spine 顺序的 XHTML）并复用 TXT 导入的规范化、分章和重复内容检查。
    public static func prepareEPUB(fileURL: URL) async throws -> AudiobookImportPreview {
        try await Task.detached(priority: .userInitiated) {
            let content = try AudiobookEPUBImporter.extractText(from: fileURL)
            var preview = try prepare(
                rawData: Data(content.text.utf8),
                suggestedTitle: content.title ?? fileURL.deletingPathExtension().lastPathComponent,
                originalFileName: fileURL.lastPathComponent
            )
            preview.author = content.author
            return preview
        }.value
    }

    public static func prepare(
        rawData: Data,
        suggestedTitle: String = "未命名书籍",
        originalFileName: String = "book.txt",
        encoding: AudiobookTextEncoding? = nil,
        maxRawBytes: Int = AudiobookLimits.maxRawFileBytes,
        maxScalars: Int = AudiobookLimits.maxTotalScalars
    ) throws -> AudiobookImportPreview {
        if rawData.count > maxRawBytes {
            throw AudiobookImportError.fileTooLarge(byteCount: Int64(rawData.count), maxBytes: maxRawBytes)
        }
        guard !rawData.isEmpty else {
            throw AudiobookImportError.emptyFile
        }

        let resolvedEncoding: AudiobookTextEncoding
        let candidates: [AudiobookTextEncoding]
        let canonicalString: String
        let requiresEncodingConfirmation: Bool

        if let explicit = encoding {
            canonicalString = try strictDecode(rawData, as: explicit)
            resolvedEncoding = explicit
            candidates = detectCandidateEncodings(for: rawData, preferred: explicit)
            requiresEncodingConfirmation = false
        } else {
            let detection = try detectEncoding(for: rawData)
            resolvedEncoding = detection.selected
            candidates = detection.candidates
            canonicalString = detection.decodedText
            requiresEncodingConfirmation = detection.requiresConfirmation
        }

        guard canonicalString.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw AudiobookImportError.emptyFile
        }

        let referenceUTF8 = Data(canonicalString.utf8)
        let referenceScalarCount = canonicalString.unicodeScalars.count
        guard referenceScalarCount <= maxScalars else {
            throw AudiobookImportError.tooManyScalars(scalarCount: referenceScalarCount, maxScalars: maxScalars)
        }
        let prepared = try AudiobookTextPreparation.prepare(referenceUTF8: referenceUTF8)
        let canonicalUTF8 = prepared.workingUTF8
        guard canonicalUTF8.count <= maxRawBytes else {
            throw AudiobookImportError.fileTooLarge(byteCount: Int64(canonicalUTF8.count), maxBytes: maxRawBytes)
        }
        let sourceIndex = try prepared.sourceIndex()
        if sourceIndex.scalarCount > maxScalars {
            throw AudiobookImportError.tooManyScalars(
                scalarCount: sourceIndex.scalarCount,
                maxScalars: maxScalars
            )
        }

        let bookID = UUID()
        let sourceID = UUID()
        let planning = try AudiobookChapterPlanner.plan(
            source: sourceIndex,
            bookID: bookID,
            sourceID: sourceID
        )
        let plannedChapters = planning.chapters
        let previewScalars = min(sourceIndex.scalarCount, AudiobookLimits.maxPreviewScalars)
        let previewEndByte = Int64(sourceIndex.scalarByteOffsets[previewScalars])
        let previewRange = AudiobookSourceRange(lowerBound: 0, upperBound: previewEndByte)
        let previewExclusions = planning.tableOfContentsRanges.compactMap { range -> AudiobookSourceRange? in
            let lower = max(range.lowerBound, previewRange.lowerBound)
            let upper = min(range.upperBound, previewRange.upperBound)
            return lower < upper ? AudiobookSourceRange(lowerBound: lower, upperBound: upper) : nil
        }
        let previewText = try sourceIndex.text(
            in: previewRange,
            excluding: previewExclusions
        )

        return AudiobookImportPreview(
            bookID: bookID,
            sourceID: sourceID,
            title: suggestedTitle,
            author: nil,
            originalFileName: originalFileName,
            originalBytes: rawData,
            canonicalUTF8: canonicalUTF8,
            sourceIndex: sourceIndex,
            referenceUTF8: referenceUTF8,
            preparedText: prepared,
            detectedEncoding: resolvedEncoding,
            candidateEncodings: candidates,
            requiresEncodingConfirmation: requiresEncodingConfirmation,
            previewText: previewText,
            chapters: plannedChapters,
            tableOfContentsRanges: planning.tableOfContentsRanges,
            repeatedContentWarnings: try repeatedContentWarnings(in: plannedChapters, source: sourceIndex)
        )
    }

    private static func repeatedContentWarnings(
        in chapters: [AudiobookChapter], source: AudiobookSourceIndex
    ) throws -> [AudiobookRepeatedContentWarning] {
        var groups: [String: [AudiobookChapter]] = [:]
        for chapter in chapters {
            let text = try source.text(in: chapter.sourceRange).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.unicodeScalars.count > chapter.title.unicodeScalars.count + 8 else { continue }
            let key = AudiobookDigest.sha256Hex(Data(text.utf8))
            groups[key, default: []].append(chapter)
        }
        return groups.values.filter { $0.count > 1 }.sorted { $0[0].ordinal < $1[0].ordinal }.map {
            AudiobookRepeatedContentWarning(id: $0[0].id, title: $0[0].title, chapterIDs: $0.map(\.id))
        }
    }

    // MARK: - Strict Decoding

    public static func strictDecode(_ data: Data, as encoding: AudiobookTextEncoding) throws -> String {
        switch encoding {
        case .utf8:
            let payload: Data
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                payload = Data(data.dropFirst(3))
            } else {
                // Reject UTF-16 BOMs masquerading as UTF-8
                if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                    throw AudiobookImportError.invalidEncoding(.utf8)
                }
                payload = data
            }
            return try strictDecodeUTF8(payload)

        case .utf16LE:
            guard data.count >= 2, data.starts(with: [0xFF, 0xFE]) else {
                throw AudiobookImportError.missingUTF16BOM(.utf16LE)
            }
            let payload = Data(data.dropFirst(2))
            return try strictDecodeUTF16(payload, littleEndian: true, encoding: .utf16LE)

        case .utf16BE:
            guard data.count >= 2, data.starts(with: [0xFE, 0xFF]) else {
                throw AudiobookImportError.missingUTF16BOM(.utf16BE)
            }
            let payload = Data(data.dropFirst(2))
            return try strictDecodeUTF16(payload, littleEndian: false, encoding: .utf16BE)

        case .gb18030:
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                throw AudiobookImportError.invalidEncoding(.gb18030)
            }
            return try strictDecodeGB18030(data)
        }
    }

    private static func strictDecodeUTF8(_ data: Data) throws -> String {
        var decoder = UTF8()
        var iterator = data.makeIterator()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(data.count)

        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar):
                scalars.append(scalar)
            case .emptyInput:
                return String(scalars)
            case .error:
                throw AudiobookImportError.invalidEncoding(.utf8)
            }
        }
    }

    private static func strictDecodeUTF16(
        _ payload: Data,
        littleEndian: Bool,
        encoding: AudiobookTextEncoding
    ) throws -> String {
        if payload.count % 2 != 0 {
            throw AudiobookImportError.oddUTF16ByteCount(payload.count)
        }
        var codeUnits: [UInt16] = []
        codeUnits.reserveCapacity(payload.count / 2)
        var index = payload.startIndex
        while index < payload.endIndex {
            let b0 = UInt16(payload[index])
            let b1 = UInt16(payload[payload.index(after: index)])
            let unit = littleEndian ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
            codeUnits.append(unit)
            index = payload.index(index, offsetBy: 2)
        }

        var decoder = UTF16()
        var iterator = codeUnits.makeIterator()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(codeUnits.count)

        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar):
                scalars.append(scalar)
            case .emptyInput:
                return String(scalars)
            case .error:
                throw AudiobookImportError.invalidEncoding(encoding)
            }
        }
    }

    private static func strictDecodeGB18030(_ data: Data) throws -> String {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let nsEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        )
        guard let decoded = String(data: data, encoding: nsEncoding) else {
            throw AudiobookImportError.invalidEncoding(.gb18030)
        }
        // Verify strict lossless round-trip so silent replacement bytes are rejected.
        guard let reencoded = decoded.data(using: nsEncoding), reencoded == data else {
            throw AudiobookImportError.invalidEncoding(.gb18030)
        }
        return decoded
    }

    private static func detectEncoding(
        for data: Data
    ) throws -> (
        selected: AudiobookTextEncoding,
        candidates: [AudiobookTextEncoding],
        decodedText: String,
        requiresConfirmation: Bool
    ) {
        if data.starts(with: [0xFF, 0xFE]) {
            let decoded = try strictDecode(data, as: .utf16LE)
            return (.utf16LE, [.utf16LE], decoded, false)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            let decoded = try strictDecode(data, as: .utf16BE)
            return (.utf16BE, [.utf16BE], decoded, false)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let decoded = try strictDecode(data, as: .utf8)
            return (.utf8, [.utf8], decoded, false)
        }

        let isPureASCII = data.allSatisfy { $0 < 0x80 }
        if isPureASCII {
            let decoded = try strictDecode(data, as: .utf8)
            return (.utf8, [.utf8, .gb18030], decoded, false)
        }

        let utf8Text = try? strictDecode(data, as: .utf8)
        let gbText = try? strictDecode(data, as: .gb18030)

        switch (utf8Text, gbText) {
        case let (.some(uText), .some):
            // Both encodings decode: prefer UTF-8 but ask the user to confirm when the bytes
            // could plausibly be GB18030 as well (C1 controls usually mean mojibake).
            if looksLikeAmbiguousShortNonASCII(data: data, utf8Text: uText) {
                return (.utf8, [.utf8, .gb18030], uText, true)
            }
            return (.utf8, [.utf8, .gb18030], uText, false)
        case let (.some(uText), .none):
            return (.utf8, [.utf8], uText, false)
        case let (.none, .some(gbDecoded)):
            // A non-UTF-8 byte stream that is valid GB18030: surface the preview with GB18030
            // provisionally selected instead of failing before the import sheet can offer a choice.
            return (.gb18030, [.gb18030, .utf8], gbDecoded, true)
        case (.none, .none):
            throw AudiobookImportError.invalidEncoding(.utf8)
        }
    }

    private static func looksLikeAmbiguousShortNonASCII(data: Data, utf8Text: String) -> Bool {
        // Any non-ASCII stream without BOM where the caller tests ambiguity can also be detected
        // if it contains C1 control characters (U+0080...U+009F) or private-use/uncommon blocks.
        for scalar in utf8Text.unicodeScalars {
            if (0x0080...0x009F).contains(scalar.value) {
                return true
            }
        }
        _ = data
        return false
    }

    private static func detectCandidateEncodings(
        for data: Data,
        preferred: AudiobookTextEncoding
    ) -> [AudiobookTextEncoding] {
        var result: [AudiobookTextEncoding] = [preferred]
        for candidate in AudiobookTextEncoding.allCases where candidate != preferred {
            if (try? strictDecode(data, as: candidate)) != nil {
                result.append(candidate)
            }
        }
        return result
    }
}
