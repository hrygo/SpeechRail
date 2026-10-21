import CryptoKit
import Foundation

/// A logical reading paragraph. Its byte range still addresses the unchanged source.
public struct AudiobookParagraph: Sendable, Equatable {
    public let sourceRange: AudiobookSourceRange
    public let text: String
    public let physicalLineCount: Int
    public let isIsolatedTitleCandidate: Bool
}

public struct AudiobookSourceIndex: Sendable, Equatable {
    public enum TextLayoutProfile: String, Codable, Sendable, Equatable {
        case hardWrapped
        case naturalParagraphs
    }

    public let utf8Data: Data
    public let sourceSHA256: String
    /// Sorted UTF-8 byte offsets of every Unicode scalar start, plus `byteCount` at the end.
    public let scalarByteOffsets: [UInt32]
    public let layoutProfile: TextLayoutProfile
    public let paragraphs: [AudiobookParagraph]
    public let joinedLineBreakCount: Int
    private let paragraphStartOffsets: Set<UInt32>

    public init(utf8: Data, titleEvidence: [Int64: Bool]? = nil) throws {
        var decoder = UTF8()
        var iterator = utf8.makeIterator()
        var offsets: [UInt32] = []
        offsets.reserveCapacity(utf8.count / 2 + 1)

        var currentByteOffset = 0
        offsets.append(0)

        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar):
                currentByteOffset += UTF8.width(scalar)
                guard currentByteOffset <= Int(UInt32.max) else {
                    throw AudiobookSourceError.sourceTooLarge
                }
                offsets.append(UInt32(currentByteOffset))
            case .emptyInput:
                break
            case .error:
                throw AudiobookSourceError.invalidUTF8
            }
            if currentByteOffset == utf8.count {
                break
            }
        }

        guard currentByteOffset == utf8.count else {
            throw AudiobookSourceError.invalidUTF8
        }

        self.utf8Data = utf8
        self.sourceSHA256 = AudiobookDigest.sha256Hex(utf8)
        self.scalarByteOffsets = offsets
        let profile = Self.detectLayoutProfile(utf8Data: utf8, scalarByteOffsets: offsets)
        self.layoutProfile = profile
        let paragraphs = Self.prepareParagraphs(utf8: utf8, profile: profile).map { paragraph in
            AudiobookParagraph(sourceRange: paragraph.sourceRange, text: paragraph.text,
                physicalLineCount: paragraph.physicalLineCount,
                isIsolatedTitleCandidate: titleEvidence?[paragraph.sourceRange.lowerBound] ?? paragraph.isIsolatedTitleCandidate)
        }
        self.paragraphs = paragraphs
        self.joinedLineBreakCount = paragraphs.reduce(0) { $0 + max(0, $1.physicalLineCount - 1) }
        self.paragraphStartOffsets = Set(paragraphs.dropFirst().map { UInt32($0.sourceRange.lowerBound) })
    }

    public var byteCount: Int64 {
        Int64(utf8Data.count)
    }

    public var scalarCount: Int {
        max(0, scalarByteOffsets.count - 1)
    }

    public var wholeRange: AudiobookSourceRange {
        AudiobookSourceRange(lowerBound: 0, upperBound: byteCount)
    }

    public func isScalarBoundary(_ byteOffset: Int64) -> Bool {
        scalarIndex(forByteOffset: byteOffset) != nil
    }

    public func scalarIndex(forByteOffset byteOffset: Int64) -> Int? {
        var low = 0
        var high = scalarByteOffsets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let value = Int64(scalarByteOffsets[mid])
            if value == byteOffset {
                return mid
            } else if value < byteOffset {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return nil
    }

    public func scalarCount(in range: AudiobookSourceRange) throws -> Int {
        try validateRangeBounds(range)
        guard
            let startIdx = scalarIndex(forByteOffset: range.lowerBound),
            let endIdx = scalarIndex(forByteOffset: range.upperBound)
        else {
            throw AudiobookSourceError.nonScalarBoundary(
                isScalarBoundary(range.lowerBound) ? range.upperBound : range.lowerBound
            )
        }
        return endIdx - startIdx
    }

    public func validateRangeBounds(_ range: AudiobookSourceRange) throws {
        if range.lowerBound > range.upperBound {
            throw AudiobookSourceError.invertedRange(range)
        }
        if range.lowerBound < 0 || range.upperBound > byteCount {
            throw AudiobookSourceError.rangeOutOfBounds(range, totalBytes: byteCount)
        }
        if !isScalarBoundary(range.lowerBound) {
            throw AudiobookSourceError.nonScalarBoundary(range.lowerBound)
        }
        if !isScalarBoundary(range.upperBound) {
            throw AudiobookSourceError.nonScalarBoundary(range.upperBound)
        }
    }

    public func text(in range: AudiobookSourceRange) throws -> String {
        try validateRangeBounds(range)
        if range.isEmpty {
            return ""
        }
        let start = utf8Data.startIndex + Int(range.lowerBound)
        let end = utf8Data.startIndex + Int(range.upperBound)
        return String(decoding: utf8Data[start..<end], as: UTF8.self)
    }

    /// Reading projection only: canonical bytes, hashes, ranges and atom IDs remain source based.
    public func normalizedText(in range: AudiobookSourceRange) throws -> String {
        try validateRangeBounds(range)
        // Binary search keeps fragment/atom projections independent of whole-book paragraph count.
        var lower = 0
        var upper = paragraphs.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if paragraphs[middle].sourceRange.upperBound <= range.lowerBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var parts: [String] = []
        for paragraph in paragraphs[lower...] {
            if paragraph.sourceRange.lowerBound >= range.upperBound { break }
            let intersection = AudiobookSourceRange(
                lowerBound: max(range.lowerBound, paragraph.sourceRange.lowerBound),
                upperBound: min(range.upperBound, paragraph.sourceRange.upperBound)
            )
            let normalized = Self.joinParagraphLines(try text(in: intersection))
            if !normalized.isEmpty { parts.append(normalized) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// 去除章节排除区间后的可读来源片段；区间仍指向 canonical UTF-8 字节。
    public func readableRanges(
        in range: AudiobookSourceRange,
        excluding exclusions: [AudiobookSourceRange]
    ) throws -> [AudiobookSourceRange] {
        try validateRangeBounds(range)
        return try nonExcludedSpans(in: range, exclusions: exclusions)
    }

    /// 阅读投影的排除版本：用于预览与目录页跳过，不改变 canonical 原文。
    public func normalizedText(
        in range: AudiobookSourceRange,
        excluding exclusions: [AudiobookSourceRange]
    ) throws -> String {
        try readableRanges(in: range, excluding: exclusions)
            .map { try normalizedText(in: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public func text(
        in range: AudiobookSourceRange,
        excluding exclusions: [AudiobookSourceRange]
    ) throws -> String {
        try readableRanges(in: range, excluding: exclusions)
            .map { try text(in: $0) }
            .joined()
    }

    public func validateCoverage(
        _ ranges: [AudiobookSourceRange],
        exclusions: [AudiobookSourceRange] = [],
        in targetRange: AudiobookSourceRange? = nil
    ) throws {
        let target = targetRange ?? wholeRange
        try validateRangeBounds(target)

        if target.isEmpty {
            for r in ranges + exclusions where !r.isEmpty {
                throw AudiobookSourceError.rangeOutOfBounds(r, totalBytes: target.upperBound)
            }
            return
        }

        var combined: [AudiobookSourceRange] = []
        combined.reserveCapacity(ranges.count + exclusions.count)

        for r in ranges {
            try validateRangeBounds(r)
            if r.lowerBound < target.lowerBound || r.upperBound > target.upperBound {
                throw AudiobookSourceError.rangeOutOfBounds(r, totalBytes: target.upperBound)
            }
            combined.append(r)
        }
        for ex in exclusions {
            try validateRangeBounds(ex)
            if ex.lowerBound < target.lowerBound || ex.upperBound > target.upperBound {
                throw AudiobookSourceError.rangeOutOfBounds(ex, totalBytes: target.upperBound)
            }
            combined.append(ex)
        }

        combined.sort()

        var previous: AudiobookSourceRange?
        var cursor = target.lowerBound

        for current in combined {
            if let prev = previous, prev == current {
                throw AudiobookSourceError.coverageDuplicate(current)
            }
            if current.isEmpty {
                continue
            }
            if current.lowerBound < cursor {
                throw AudiobookSourceError.coverageOverlap(
                    previousUpperBound: cursor,
                    nextLowerBound: current.lowerBound
                )
            }
            if current.lowerBound > cursor {
                throw AudiobookSourceError.coverageHole(
                    expectedLowerBound: cursor,
                    actualLowerBound: current.lowerBound
                )
            }
            cursor = current.upperBound
            previous = current
        }

        if cursor != target.upperBound {
            throw AudiobookSourceError.coverageIncomplete(
                coveredUntil: cursor,
                totalBytes: target.upperBound
            )
        }
    }

    /// Deterministically partitions `chapter.sourceRange` (minus `chapter.excludedRanges`) into bounded atoms.
    public func buildAtoms(
        for chapter: AudiobookChapter,
        maxAtomScalars: Int = AudiobookLimits.maxAtomScalars,
        layoutProfile overrideLayoutProfile: TextLayoutProfile? = nil
    ) throws -> [AudiobookTextAtom] {
        let effectiveMaxScalars = max(1, min(maxAtomScalars, AudiobookLimits.maxAtomScalars))
        let effectiveProfile = overrideLayoutProfile ?? self.layoutProfile
        try validateRangeBounds(chapter.sourceRange)

        let activeSpans = try nonExcludedSpans(
            in: chapter.sourceRange,
            exclusions: chapter.excludedRanges
        )

        var atoms: [AudiobookTextAtom] = []
        var ordinal = 0

        for (spanIndex, span) in activeSpans.enumerated() {
            guard
                let startScalarIdx = scalarIndex(forByteOffset: span.lowerBound),
                let endScalarIdx = scalarIndex(forByteOffset: span.upperBound)
            else {
                throw AudiobookSourceError.nonScalarBoundary(span.lowerBound)
            }

            if startScalarIdx == endScalarIdx {
                continue
            }

            var atomStartScalarIdx = startScalarIdx
            var isFirstLineInChapter = (spanIndex == 0)
            var insideDialogueQuote = false

            var cursorScalarIdx = startScalarIdx
            while cursorScalarIdx < endScalarIdx {
                let scalar = scalarAt(scalarIndex: cursorScalarIdx)
                let nextScalarIdx = cursorScalarIdx + 1
                let currentAtomLength = nextScalarIdx - atomStartScalarIdx

                let isOpeningQuote = Self.openingQuoteScalars.contains(scalar)
                let isClosingQuote = Self.closingQuoteScalars.contains(scalar)
                var isDialogueClosingQuoteBoundary = false

                if isOpeningQuote {
                    let isDialogue = shouldSplitBeforeOpeningQuote(
                        at: cursorScalarIdx,
                        atomStartScalarIdx: atomStartScalarIdx,
                        endScalarIdx: endScalarIdx
                    )
                    if isDialogue {
                        if cursorScalarIdx > atomStartScalarIdx {
                            let range = AudiobookSourceRange(
                                lowerBound: Int64(scalarByteOffsets[atomStartScalarIdx]),
                                upperBound: Int64(scalarByteOffsets[cursorScalarIdx])
                            )
                            let kind = try classifyAtomKind(
                                in: range,
                                chapter: chapter,
                                isFirstLineCandidate: isFirstLineInChapter
                            )
                            atoms.append(
                                AudiobookTextAtom(
                                    id: Self.deterministicAtomID(chapterID: chapter.id, range: range),
                                    chapterID: chapter.id,
                                    ordinal: ordinal,
                                    sourceRange: range,
                                    kind: kind
                                )
                            )
                            ordinal += 1
                            atomStartScalarIdx = cursorScalarIdx
                        }
                        insideDialogueQuote = true
                    }
                } else if isClosingQuote {
                    if insideDialogueQuote {
                        insideDialogueQuote = false
                        isDialogueClosingQuoteBoundary = true
                    }
                }

                let isHardLineBreakEnd: Bool = {
                    if scalar == "\n" {
                        return isHardLineBreak(
                            at: cursorScalarIdx,
                            atomStartScalarIdx: atomStartScalarIdx,
                            endScalarIdx: endScalarIdx,
                            layoutProfile: effectiveProfile
                        )
                    }
                    if scalar == "\r" {
                        if nextScalarIdx < endScalarIdx && scalarAt(scalarIndex: nextScalarIdx) == "\n" {
                            return false
                        }
                        return isHardLineBreak(
                            at: cursorScalarIdx,
                            atomStartScalarIdx: atomStartScalarIdx,
                            endScalarIdx: endScalarIdx,
                            layoutProfile: effectiveProfile
                        )
                    }
                    return false
                }()
                let isParagraphEnd = paragraphStartOffsets.contains(scalarByteOffsets[nextScalarIdx])

                let isSentenceBoundary = Self.sentenceTerminalScalars.contains(scalar) && !insideDialogueQuote
                let reachedMaxScalars = currentAtomLength >= effectiveMaxScalars

                if isHardLineBreakEnd || isParagraphEnd || isDialogueClosingQuoteBoundary || isSentenceBoundary || reachedMaxScalars || nextScalarIdx == endScalarIdx {
                    // Absorb immediately following whitespace/closing punctuation on the same line if room permits
                    var finalEndScalarIdx = nextScalarIdx
                    if !isHardLineBreakEnd && !isParagraphEnd && !reachedMaxScalars {
                        while finalEndScalarIdx < endScalarIdx,
                              (finalEndScalarIdx - atomStartScalarIdx) < effectiveMaxScalars
                        {
                            let peek = scalarAt(scalarIndex: finalEndScalarIdx)
                            if peek == "\r" && finalEndScalarIdx + 1 < endScalarIdx && scalarAt(scalarIndex: finalEndScalarIdx + 1) == "\n" {
                                guard finalEndScalarIdx + 2 - atomStartScalarIdx <= effectiveMaxScalars else { break }
                                if isHardLineBreak(at: finalEndScalarIdx, atomStartScalarIdx: atomStartScalarIdx, endScalarIdx: endScalarIdx, layoutProfile: effectiveProfile) {
                                    finalEndScalarIdx += 2
                                    isFirstLineInChapter = false
                                }
                                break
                            } else if peek == "\n" || peek == "\r" {
                                if isHardLineBreak(at: finalEndScalarIdx, atomStartScalarIdx: atomStartScalarIdx, endScalarIdx: endScalarIdx, layoutProfile: effectiveProfile) {
                                    finalEndScalarIdx += 1
                                    isFirstLineInChapter = false
                                }
                                break
                            } else if Self.closingTrailScalars.contains(peek) {
                                finalEndScalarIdx += 1
                            } else {
                                break
                            }
                        }
                    }

                    if isHardLineBreakEnd {
                        isFirstLineInChapter = false
                    }

                    let range = AudiobookSourceRange(
                        lowerBound: Int64(scalarByteOffsets[atomStartScalarIdx]),
                        upperBound: Int64(scalarByteOffsets[finalEndScalarIdx])
                    )
                    let kind = try classifyAtomKind(
                        in: range,
                        chapter: chapter,
                        isFirstLineCandidate: ordinal == 0
                    )
                    atoms.append(
                        AudiobookTextAtom(
                            id: Self.deterministicAtomID(chapterID: chapter.id, range: range),
                            chapterID: chapter.id,
                            ordinal: ordinal,
                            sourceRange: range,
                            kind: kind
                        )
                    )
                    ordinal += 1
                    atomStartScalarIdx = finalEndScalarIdx
                    cursorScalarIdx = finalEndScalarIdx
                    continue
                }

                cursorScalarIdx = nextScalarIdx
            }
        }

        try validateCoverage(
            atoms.map(\.sourceRange),
            exclusions: chapter.excludedRanges,
            in: chapter.sourceRange
        )
        return atoms
    }

    public func resolveRanges(
        forAtomIDs atomIDs: [UUID],
        in ledger: [UUID: AudiobookTextAtom]
    ) throws -> [AudiobookSourceRange] {
        try atomIDs.map { id in
            guard let atom = ledger[id] else {
                throw AudiobookSourceError.unknownAtomID(id)
            }
            return atom.sourceRange
        }
    }

    /// Normalizes soft line breaks within a sentence for comfortable reading display,
    /// without mutating the underlying canonical byte range or source index.
    public static func displayNormalizedText(_ text: String) -> String {
        prepareParagraphs(utf8: Data(text.utf8), profile: .hardWrapped)
            .map(\.text).joined(separator: "\n\n")
    }

    private struct PhysicalLine {
        let start: Int64
        let text: String
        let indentationCount: Int
        let indented: Bool
        let continuesOnNextLine: Bool
    }

    private static func prepareParagraphs(utf8: Data, profile: TextLayoutProfile) -> [AudiobookParagraph] {
        var lines: [PhysicalLine] = []
        var start = 0
        var cursor = 0
        while cursor < utf8.count {
            if utf8[cursor] != 0x0A && utf8[cursor] != 0x0D {
                cursor += 1
                continue
            }
            let end = cursor
            if utf8[cursor] == 0x0D && cursor + 1 < utf8.count && utf8[cursor + 1] == 0x0A {
                cursor += 1
            }
            lines.append(contentsOf: splitPhysicalLine(utf8: utf8, start: start, end: end))
            cursor += 1
            start = cursor
        }
        if start < utf8.count { lines.append(contentsOf: splitPhysicalLine(utf8: utf8, start: start, end: utf8.count)) }

        var paragraphs: [AudiobookParagraph] = []
        var group: [PhysicalLine] = []
        var groupStart: Int64 = 0
        var firstLineIndex = 0
        var previousLineIndex: Int?

        func appendParagraph(end: Int64) {
            guard let first = group.first else { return }
            let nextIndex = firstLineIndex + 1
            let centeredAboveBody = nextIndex < lines.count
                && first.indentationCount >= lines[nextIndex].indentationCount + 16
                && lines[nextIndex].text.unicodeScalars.count >= 22
            let isolated = group.count == 1
                && (firstLineIndex == 0 || lines[firstLineIndex - 1].text.isEmpty)
                && (nextIndex == lines.count || lines[nextIndex].text.isEmpty || centeredAboveBody)
            paragraphs.append(AudiobookParagraph(
                sourceRange: AudiobookSourceRange(lowerBound: groupStart, upperBound: end),
                text: joinParagraphLines(group.map(\.text).joined(separator: "\n")),
                physicalLineCount: group.count,
                isIsolatedTitleCandidate: isolated
            ))
        }

        for (index, line) in lines.enumerated() where !line.text.isEmpty {
            if let previousLineIndex, let previous = group.last {
                let blankSeparated = index > previousLineIndex + 1
                let interruptedLongLine = previous.text.unicodeScalars.count >= 22
                    && previous.text.unicodeScalars.last.map {
                        !sentenceTerminalScalars.contains($0) && !closingQuoteScalars.contains($0)
                    } == true
                let hangingPunctuation = line.text.unicodeScalars.first.map { hangingPunctuationScalars.contains($0) } == true
                let mayContinue = previous.continuesOnNextLine || profile == .hardWrapped || interruptedLongLine || hangingPunctuation
                let centeredLineEnds = previous.indentationCount >= line.indentationCount + 16
                    && previous.text.unicodeScalars.count <= 48
                let startsParagraph = blankSeparated || !mayContinue || line.indented
                    || centeredLineEnds
                    || isChapterHeading(previous.text)
                    || isChapterHeading(line.text)
                    || isIndependentDialogue(previous: previous.text, next: line.text)
                    || isVersePair(previous.text, line.text)
                if startsParagraph {
                    appendParagraph(end: line.start)
                    group.removeAll(keepingCapacity: true)
                    groupStart = line.start
                }
            }
            if group.isEmpty { firstLineIndex = index }
            group.append(line)
            previousLineIndex = index
        }
        appendParagraph(end: Int64(utf8.count))
        return paragraphs
    }

    private static func physicalLine(
        utf8: Data, start: Int, end: Int, continuesOnNextLine: Bool = false
    ) -> PhysicalLine {
        let raw = String(decoding: utf8[start..<end], as: UTF8.self)
        let indentation = raw.unicodeScalars.prefix { CharacterSet.whitespaces.contains($0) }
        return PhysicalLine(
            start: Int64(start),
            text: raw.trimmingCharacters(in: .whitespaces),
            indentationCount: indentation.count,
            indented: indentation.count >= 2 || indentation.contains("\t") || indentation.contains("\u{3000}"),
            continuesOnNextLine: continuesOnNextLine
        )
    }

    private static let numberedHeadingPrefix = try! NSRegularExpression(
        pattern: #"第[零〇○一二三四五六七八九十百千万0-9]+[章节節回卷集部篇]"#
    )
    private static let proseOpening = try! NSRegularExpression(
        pattern: #"話說|话说|卻說|却说|且說|且说|話表|话表"#
    )
    private static let wrappedProseOpening = try! NSRegularExpression(pattern: #"\s+([話话卻却且])\s*$"#)

    /// Virtual line boundaries address the original bytes, including when a
    /// printed chapter heading was glued to the preceding or following prose.
    private static func splitPhysicalLine(utf8: Data, start: Int, end: Int) -> [PhysicalLine] {
        let raw = String(decoding: utf8[start..<end], as: UTF8.self)
        guard raw.contains("第") else { return [physicalLine(utf8: utf8, start: start, end: end)] }
        var cuts: Set<Int> = [start, end]
        var continuationStart: Int?
        for match in numberedHeadingPrefix.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let prefix = Range(match.range, in: raw) else { continue }
            let before = raw[..<prefix.lowerBound].trimmingCharacters(in: .whitespaces)
            let atStart = before.isEmpty
            guard atStart || before.last.map({ "。！？!?".contains($0) }) == true else { continue }
            let afterPrefix = raw[prefix.upperBound...]
            // Embedded numbered references need the typography of a round title.
            if !atStart && (raw[prefix].last != "回" || afterPrefix.first?.isWhitespace != true) { continue }
            var headingEnd = raw.endIndex
            let tailRange = NSRange(prefix.upperBound..<raw.endIndex, in: raw)
            if let opening = proseOpening.firstMatch(in: raw, range: tailRange),
               let body = Range(opening.range, in: raw),
               raw[prefix.upperBound..<body.lowerBound].trimmingCharacters(in: .whitespaces).count >= 2 {
                headingEnd = body.lowerBound
            } else if let opening = wrappedProseOpening.firstMatch(in: raw, range: tailRange),
                      let body = Range(opening.range(at: 1), in: raw),
                      raw[prefix.upperBound..<body.lowerBound].trimmingCharacters(in: .whitespaces).count >= 2 {
                var nextLineStart = end
                if nextLineStart < utf8.count && utf8[nextLineStart] == 0x0D { nextLineStart += 1 }
                if nextLineStart < utf8.count && utf8[nextLineStart] == 0x0A { nextLineStart += 1 }
                let next = String(decoding: utf8[nextLineStart..<min(utf8.count, nextLineStart + 24)], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                if next.first == "說" || next.first == "说" {
                    headingEnd = body.lowerBound
                    continuationStart = start + raw[..<headingEnd].utf8.count
                }
            }
            let title = String(raw[prefix.lowerBound..<headingEnd]).trimmingCharacters(in: .whitespaces)
            guard isChapterHeading(title) else { continue }
            cuts.insert(start + raw[..<prefix.lowerBound].utf8.count)
            if headingEnd < raw.endIndex { cuts.insert(start + raw[..<headingEnd].utf8.count) }
        }
        let ordered = cuts.sorted()
        return zip(ordered, ordered.dropFirst()).map {
            physicalLine(utf8: utf8, start: $0, end: $1, continuesOnNextLine: $0 == continuationStart)
        }
    }

    private static func isIndependentDialogue(previous: String, next: String) -> Bool {
        guard let first = next.unicodeScalars.first, openingQuoteScalars.contains(first),
              let last = previous.unicodeScalars.last else { return false }
        return sentenceTerminalScalars.contains(last) || closingQuoteScalars.contains(last)
            || last == "，" || last == ","
    }

    private static func isVersePair(_ previous: String, _ next: String) -> Bool {
        let left = previous.unicodeScalars
        let right = next.unicodeScalars
        guard [5, 7, 14].contains(left.count), left.count == right.count,
              left.allSatisfy({ (0x3400...0x9FFF).contains($0.value) }),
              right.allSatisfy({ (0x3400...0x9FFF).contains($0.value) })
        else { return false }
        return true
    }

    static func joinParagraphLines(_ text: String) -> String {
        let standard = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = standard.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var result = ""
        for line in lines {
            if let last = result.unicodeScalars.last, let first = line.unicodeScalars.first,
               !isCJK(last), !isCJK(first),
               !closingTrailScalars.contains(first), !openingQuoteScalars.contains(last) {
                result.append(" ")
            }
            result.append(line)
        }
        return result
    }

    static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v)
            || (0x3000...0x303F).contains(v)
            || (0xFF00...0xFFEF).contains(v)
    }

    // MARK: - Private Helpers

    static func isChapterHeading(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 48 else { return false }
        if let match = numberedHeadingPrefix.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.range.location == 0, let range = Range(match.range, in: trimmed),
           let next = trimmed[range.upperBound...].first, !next.isWhitespace,
           "中里裏内內的是".contains(next) { return false }
        let patterns = [
            #"^第[零〇○一二三四五六七八九十百千万0-9]+[章节節回卷集部篇](\s+.*|[^\s，。！？；：,.!?;:]{1,40}|$)$"#,
            #"^(序章|序言|楔子|引子|尾声|终章|后记|番外|附言)(\s+.*|$)"#,
            #"^(Chapter|CHAPTER)\s+[0-9IVXLCDM]+(\s+.*|:.*|$)"#,
        ]
        return patterns.contains { trimmed.range(of: $0, options: .regularExpression) != nil }
    }

    private static func detectLayoutProfile(
        utf8Data: Data,
        scalarByteOffsets: [UInt32]
    ) -> TextLayoutProfile {
        let totalScalars = max(0, scalarByteOffsets.count - 1)
        if totalScalars < 40 {
            return .naturalParagraphs
        }

        var sampleLengths: [Int] = []
        var nonTerminalLineCount = 0
        var hangingPunctuationCount = 0
        var totalNonEmptyLines = 0

        var lineStartScalar = 0
        var cursor = 0
        let sampleLimit = min(totalScalars, 40_000)

        while cursor < sampleLimit && totalNonEmptyLines < 200 {
            let startByte = Int(scalarByteOffsets[cursor])
            let endByte = Int(scalarByteOffsets[cursor + 1])
            var it = utf8Data[startByte..<endByte].makeIterator()
            var dec = UTF8()
            let scalar: UnicodeScalar
            if case let .scalarValue(s) = dec.decode(&it) {
                scalar = s
            } else {
                scalar = "\u{FFFD}"
            }

            let isLineBreak = (scalar == "\n" || scalar == "\r")
            if isLineBreak || cursor + 1 == sampleLimit {
                let lineLength = cursor - lineStartScalar
                if lineLength > 0 {
                    var hasNonWhitespace = false
                    var lastNonWhitespaceScalar: UnicodeScalar?
                    for sIdx in lineStartScalar..<cursor {
                        let sb = Int(scalarByteOffsets[sIdx])
                        let se = Int(scalarByteOffsets[sIdx + 1])
                        var sit = utf8Data[sb..<se].makeIterator()
                        var sdec = UTF8()
                        if case let .scalarValue(sc) = sdec.decode(&sit), !CharacterSet.whitespacesAndNewlines.contains(sc) {
                            hasNonWhitespace = true
                            lastNonWhitespaceScalar = sc
                        }
                    }
                    if hasNonWhitespace {
                        totalNonEmptyLines += 1
                        sampleLengths.append(lineLength)
                        if let last = lastNonWhitespaceScalar,
                           !sentenceTerminalScalars.contains(last) && !closingQuoteScalars.contains(last) {
                            nonTerminalLineCount += 1
                        }
                    }
                }

                if scalar == "\r" && cursor + 1 < sampleLimit {
                    let nb = Int(scalarByteOffsets[cursor + 1])
                    let ne = Int(scalarByteOffsets[cursor + 2])
                    var nit = utf8Data[nb..<ne].makeIterator()
                    var ndec = UTF8()
                    if case let .scalarValue(ns) = ndec.decode(&nit), ns == "\n" {
                        cursor += 1
                    }
                }
                cursor += 1
                lineStartScalar = cursor

                if cursor < sampleLimit {
                    let pb = Int(scalarByteOffsets[cursor])
                    let pe = Int(scalarByteOffsets[cursor + 1])
                    var pit = utf8Data[pb..<pe].makeIterator()
                    var pdec = UTF8()
                    if case let .scalarValue(ps) = pdec.decode(&pit), hangingPunctuationScalars.contains(ps) {
                        hangingPunctuationCount += 1
                    }
                }
                continue
            }
            cursor += 1
        }

        guard sampleLengths.count >= 8 else {
            return .naturalParagraphs
        }

        let sorted = sampleLengths.sorted()
        let median = sorted[sorted.count / 2]

        if (22...55).contains(median) {
            let closeToMedian = sampleLengths.filter { abs($0 - median) <= 4 }.count
            let ratio = Double(closeToMedian) / Double(sampleLengths.count)
            let nonTerminalRatio = Double(nonTerminalLineCount) / Double(sampleLengths.count)
            if ratio >= 0.50 && (nonTerminalRatio >= 0.30 || hangingPunctuationCount >= 2) {
                return .hardWrapped
            }
        }

        return .naturalParagraphs
    }

    private func shouldSplitBeforeOpeningQuote(
        at cursorScalarIdx: Int,
        atomStartScalarIdx: Int,
        endScalarIdx: Int
    ) -> Bool {
        if cursorScalarIdx == atomStartScalarIdx {
            return true
        }

        var checkIdx = cursorScalarIdx - 1
        while checkIdx >= atomStartScalarIdx && CharacterSet.whitespaces.contains(scalarAt(scalarIndex: checkIdx)) {
            checkIdx -= 1
        }
        if checkIdx >= atomStartScalarIdx {
            let prevScalar = scalarAt(scalarIndex: checkIdx)
            if prevScalar == ":" || prevScalar == "：" {
                return true
            }
            if Self.speechVerbs.contains(prevScalar) {
                return true
            }
            if prevScalar == "\n" || prevScalar == "\r" {
                return true
            }
            if checkIdx - 1 >= atomStartScalarIdx {
                let prevPrevScalar = scalarAt(scalarIndex: checkIdx - 1)
                if prevScalar == "道" && Self.speechVerbs.contains(prevPrevScalar) {
                    return true
                }
            }
        } else {
            return true
        }

        var peekIdx = cursorScalarIdx + 1
        var quoteLength = 0
        var hasTerminalPunct = false
        var closingQuoteFound = false
        var closingQuoteScalarIdx = -1

        while peekIdx < endScalarIdx && quoteLength < 160 {
            let peekScalar = scalarAt(scalarIndex: peekIdx)
            if Self.closingQuoteScalars.contains(peekScalar) {
                closingQuoteFound = true
                closingQuoteScalarIdx = peekIdx
                break
            }
            if Self.sentenceTerminalScalars.contains(peekScalar) {
                hasTerminalPunct = true
            }
            if peekScalar == "\n" || peekScalar == "\r" {
                break
            }
            quoteLength += 1
            peekIdx += 1
        }

        if closingQuoteFound {
            if hasTerminalPunct && quoteLength >= 4 {
                return true
            }
            if quoteLength <= 4 && !hasTerminalPunct {
                if closingQuoteScalarIdx + 1 < endScalarIdx {
                    let afterScalar = scalarAt(scalarIndex: closingQuoteScalarIdx + 1)
                    if !Self.sentenceTerminalScalars.contains(afterScalar) && afterScalar != "\n" && afterScalar != "\r" {
                        return false
                    }
                }
            }
            if quoteLength >= 10 {
                return true
            }
        }

        return false
    }

    private func isHardLineBreak(
        at lineBreakScalarIdx: Int,
        atomStartScalarIdx: Int,
        endScalarIdx: Int,
        layoutProfile: TextLayoutProfile
    ) -> Bool {
        let scalar = scalarAt(scalarIndex: lineBreakScalarIdx)
        let nextScalarIdx: Int
        if scalar == "\r" && lineBreakScalarIdx + 1 < endScalarIdx && scalarAt(scalarIndex: lineBreakScalarIdx + 1) == "\n" {
            nextScalarIdx = lineBreakScalarIdx + 2
        } else {
            nextScalarIdx = lineBreakScalarIdx + 1
        }

        if nextScalarIdx >= endScalarIdx {
            return true
        }

        if layoutProfile == self.layoutProfile {
            return paragraphStartOffsets.contains(scalarByteOffsets[nextScalarIdx])
                || scalarAt(scalarIndex: nextScalarIdx) == "\n"
                || scalarAt(scalarIndex: nextScalarIdx) == "\r"
        }

        var peekIdx = nextScalarIdx
        while peekIdx < endScalarIdx {
            let peek = scalarAt(scalarIndex: peekIdx)
            if peek == "\n" || peek == "\r" {
                return true // Empty line -> Hard break!
            }
            if !CharacterSet.whitespaces.contains(peek) {
                break
            }
            peekIdx += 1
        }

        let firstNonSpaceScalarIdx = peekIdx
        let leadingSpaces = firstNonSpaceScalarIdx - nextScalarIdx
        if firstNonSpaceScalarIdx < endScalarIdx {
            let firstScalar = scalarAt(scalarIndex: firstNonSpaceScalarIdx)
            if firstScalar == "\u{3000}" || firstScalar == "\t" || leadingSpaces >= 2 {
                return true // Paragraph indent -> Hard break!
            }
            if Self.openingQuoteScalars.contains(firstScalar) {
                var prevNonSpaceIdx = lineBreakScalarIdx - 1
                while prevNonSpaceIdx >= atomStartScalarIdx && CharacterSet.whitespaces.contains(scalarAt(scalarIndex: prevNonSpaceIdx)) {
                    prevNonSpaceIdx -= 1
                }
                if prevNonSpaceIdx >= atomStartScalarIdx {
                    let prevScalar = scalarAt(scalarIndex: prevNonSpaceIdx)
                    if Self.sentenceTerminalScalars.contains(prevScalar) || Self.closingQuoteScalars.contains(prevScalar) {
                        return true // Dialogue turn -> Hard break!
                    }
                }
            }
            if Self.hangingPunctuationScalars.contains(firstScalar) {
                return false // Soft break!
            }
        }

        if layoutProfile == .hardWrapped {
            var prevNonSpaceIdx = lineBreakScalarIdx - 1
            while prevNonSpaceIdx >= atomStartScalarIdx && CharacterSet.whitespaces.contains(scalarAt(scalarIndex: prevNonSpaceIdx)) {
                prevNonSpaceIdx -= 1
            }
            if prevNonSpaceIdx >= atomStartScalarIdx {
                let prevScalar = scalarAt(scalarIndex: prevNonSpaceIdx)
                if !Self.sentenceTerminalScalars.contains(prevScalar) {
                    return false // Soft break!
                }
            }
        }

        return true
    }

    private func scalarAt(scalarIndex: Int) -> UnicodeScalar {
        let start = Int(scalarByteOffsets[scalarIndex])
        let end = Int(scalarByteOffsets[scalarIndex + 1])
        var iterator = utf8Data[start..<end].makeIterator()
        var decoder = UTF8()
        if case let .scalarValue(scalar) = decoder.decode(&iterator) {
            return scalar
        }
        return "\u{FFFD}"
    }

    private func nonExcludedSpans(
        in chapterRange: AudiobookSourceRange,
        exclusions: [AudiobookSourceRange]
    ) throws -> [AudiobookSourceRange] {
        if exclusions.isEmpty {
            return [chapterRange]
        }
        let sorted = exclusions.sorted()
        var cursor = chapterRange.lowerBound
        var spans: [AudiobookSourceRange] = []

        for ex in sorted {
            try validateRangeBounds(ex)
            if ex.lowerBound < chapterRange.lowerBound || ex.upperBound > chapterRange.upperBound {
                throw AudiobookSourceError.rangeOutOfBounds(ex, totalBytes: chapterRange.upperBound)
            }
            if ex.lowerBound < cursor {
                throw AudiobookSourceError.coverageOverlap(
                    previousUpperBound: cursor,
                    nextLowerBound: ex.lowerBound
                )
            }
            if ex.lowerBound > cursor {
                spans.append(AudiobookSourceRange(lowerBound: cursor, upperBound: ex.lowerBound))
            }
            cursor = ex.upperBound
        }

        if cursor < chapterRange.upperBound {
            spans.append(AudiobookSourceRange(lowerBound: cursor, upperBound: chapterRange.upperBound))
        }
        return spans
    }

    private func classifyAtomKind(
        in range: AudiobookSourceRange,
        chapter: AudiobookChapter,
        isFirstLineCandidate: Bool
    ) throws -> AudiobookTextAtomKind {
        let sliceText = try text(in: range)
        let trimmed = sliceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .formatting
        }
        if isFirstLineCandidate && !chapter.title.isEmpty && trimmed.hasPrefix(chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .heading
        }
        let isOnlySeparators = trimmed.unicodeScalars.allSatisfy { scalar in
            CharacterSet.punctuationCharacters.union(.symbols).contains(scalar)
        }
        if isOnlySeparators {
            return .formatting
        }
        return .body
    }

    private static func deterministicAtomID(chapterID: UUID, range: AudiobookSourceRange) -> UUID {
        let seed = "\(chapterID.uuidString):\(range.lowerBound):\(range.upperBound)"
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5],
            (digest[6] & 0x0F) | 0x50,
            (digest[7] & 0x3F) | 0x80,
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    private static let openingQuoteScalars: Set<UnicodeScalar> = [
        "“", "‘", "「", "『", "\"",
    ]

    private static let closingQuoteScalars: Set<UnicodeScalar> = [
        "”", "’", "」", "』",
    ]

    private static let sentenceTerminalScalars: Set<UnicodeScalar> = [
        "。", "！", "？", "；", ".", "!", "?", ";",
    ]

    private static let closingTrailScalars: Set<UnicodeScalar> = [
        "”", "’", "」", "』", "）", ")", "】", "]", "》", "\"",
    ]

    private static let speechVerbs: Set<UnicodeScalar> = [
        "道", "说", "曰", "问", "叫", "喊", "喝", "笑", "叹", "答", "云", "奏", "语",
    ]

    private static let hangingPunctuationScalars: Set<UnicodeScalar> = [
        "、", "，", "。", "；", "！", "？", "：", "”", "’", "」", "』", "）", "】", "]", "》",
    ]
}

/// Both coordinates address decoded UTF-8, never the original file encoding.
public struct AudiobookWorkingSourceSpan: Codable, Equatable, Sendable {
    public let workingRange: AudiobookSourceRange
    public let referenceRange: AudiobookSourceRange
    /// Nonliteral content maps to a reference interval/anchor, never fabricated 1:1 offsets.
    public let isGenerated: Bool
    /// Nil for existing import maps; true distinguishes manual text from generated layout.
    public var isUserEdited: Bool? = nil
    /// Original layout evidence, recorded only on the first retained span of a paragraph.
    public var isIsolatedTitleCandidate: Bool? = nil
}

public struct AudiobookPreparedText: Equatable, Sendable {
    public let workingUTF8: Data
    public let workingSHA256: String
    public let preparationVersion: String
    public let sourceMap: [AudiobookWorkingSourceSpan]

    public func sourceIndex() throws -> AudiobookSourceIndex {
        try AudiobookSourceIndex(utf8: workingUTF8, titleEvidence: Dictionary(uniqueKeysWithValues:
            sourceMap.compactMap { span in span.isIsolatedTitleCandidate.map { (span.workingRange.lowerBound, $0) } }))
    }
}

public enum AudiobookChapterTextEditError: Error, Equatable, Sendable, LocalizedError {
    case notEditable, staleDraft, emptyTitle, emptyBody

    public var errorDescription: String? {
        switch self {
        case .notEditable: "正文只能在开始分析前编辑。请先完成正在进行的操作。"
        case .staleDraft: "章节内容或目录已变化，未覆盖新版本。请保留草稿并重新打开章节核对。"
        case .emptyTitle: "章节标题不能为空。"
        case .emptyBody: "章节正文不能为空；如需略过本章，请使用跳过章节。"
        }
    }
}

public struct AudiobookChapterEditDraft: Identifiable, Equatable, Sendable {
    public var id: UUID { chapterID }
    public let bookID: UUID
    public let sourceID: UUID
    public let sourceSHA256: String
    public let chapterID: UUID
    public let layoutDigest: String
    public let title: String
    public let body: String

    /// String equality is canonically equivalent; persisted text identity is byte-exact.
    public func hasChanges(title: String, body: String) -> Bool {
        !self.title.utf8.elementsEqual(title.utf8) || !self.body.utf8.elementsEqual(body.utf8)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bookID == rhs.bookID && lhs.sourceID == rhs.sourceID && lhs.sourceSHA256 == rhs.sourceSHA256
            && lhs.chapterID == rhs.chapterID && lhs.layoutDigest == rhs.layoutDigest
            && !lhs.hasChanges(title: rhs.title, body: rhs.body)
    }
}

public struct AudiobookChapterEditResult: Equatable, Sendable {
    public let sourceID: UUID
    public let chapterID: UUID
}

/// Pure byte replacement. No importing, automatic chapter planning or normalization.
public enum AudiobookChapterTextEditing {
    public static func replacing(
        source: AudiobookSourceIndex, map: [AudiobookWorkingSourceSpan], chapters: [AudiobookChapter],
        chapterID: UUID, title: String, body: String, newSourceID: UUID,
        maxBytes: Int = AudiobookLimits.maxRawFileBytes, maxScalars: Int = AudiobookLimits.maxTotalScalars
    ) throws -> (text: AudiobookPreparedText, chapters: [AudiobookChapter], selectedID: UUID) {
        guard let target = chapters.first(where: { $0.id == chapterID }) else { throw AudiobookChapterTextEditError.staleDraft }
        let range = target.sourceRange
        try source.validateCoverage(chapters.map(\.sourceRange))
        let replacement = Data(body.utf8)
        let delta = Int64(replacement.count) - (range.upperBound - range.lowerBound)
        let count = source.byteCount + delta
        guard count <= maxBytes else { throw AudiobookImportError.fileTooLarge(byteCount: count, maxBytes: maxBytes) }
        var bytes = Data(source.utf8Data.prefix(Int(range.lowerBound)))
        bytes.append(replacement)
        bytes.append(source.utf8Data.suffix(from: Int(range.upperBound)))

        // An interior cut through a generated interval assigns all reference evidence
        // to its left side. The right side uses its end anchor, not a proportional offset.
        func referenceOffset(_ offset: Int64, in span: AudiobookWorkingSourceSpan) -> Int64 {
            if offset == span.workingRange.lowerBound { return span.referenceRange.lowerBound }
            return span.isGenerated ? span.referenceRange.upperBound : span.referenceRange.lowerBound + offset - span.workingRange.lowerBound
        }
        var outputMap: [AudiobookWorkingSourceSpan] = []
        func retain(_ retained: AudiobookSourceRange, shift: Int64) {
            for span in map {
                let start = max(retained.lowerBound, span.workingRange.lowerBound)
                let end = min(retained.upperBound, span.workingRange.upperBound)
                guard start < end else { continue }
                var clipped = AudiobookWorkingSourceSpan(
                    workingRange: .init(lowerBound: start + shift, upperBound: end + shift),
                    referenceRange: .init(lowerBound: referenceOffset(start, in: span), upperBound: referenceOffset(end, in: span)),
                    isGenerated: span.isGenerated)
                clipped.isUserEdited = span.isUserEdited
                clipped.isIsolatedTitleCandidate = start == span.workingRange.lowerBound ? span.isIsolatedTitleCandidate : nil
                outputMap.append(clipped)
            }
        }
        retain(.init(lowerBound: 0, upperBound: range.lowerBound), shift: 0)
        let touched = map.filter { $0.workingRange.lowerBound < range.upperBound && $0.workingRange.upperBound > range.lowerBound }
        guard let first = touched.first, let last = touched.last else { throw AudiobookStoreError.workingSourceChanged }
        var edited = AudiobookWorkingSourceSpan(
            workingRange: .init(lowerBound: range.lowerBound, upperBound: range.lowerBound + Int64(replacement.count)),
            referenceRange: .init(lowerBound: referenceOffset(range.lowerBound, in: first), upperBound: referenceOffset(range.upperBound, in: last)),
            isGenerated: true)
        edited.isUserEdited = true
        outputMap.append(edited)
        retain(.init(lowerBound: range.upperBound, upperBound: source.byteCount), shift: delta)
        let prepared = AudiobookPreparedText(workingUTF8: bytes, workingSHA256: AudiobookDigest.sha256Hex(bytes),
            preparationVersion: AudiobookTextPreparation.version, sourceMap: outputMap)
        let updatedSource = try prepared.sourceIndex()
        guard updatedSource.scalarCount <= maxScalars else {
            throw AudiobookImportError.tooManyScalars(scalarCount: updatedSource.scalarCount, maxScalars: maxScalars)
        }
        func shifted(_ value: AudiobookSourceRange) -> AudiobookSourceRange {
            .init(lowerBound: value.lowerBound + delta, upperBound: value.upperBound + delta)
        }
        var selectedID = UUID()
        let updatedChapters = chapters.map { chapter -> AudiobookChapter in
            let id = UUID()
            var newRange = chapter.sourceRange
            var exclusions = chapter.excludedRanges
            if chapter.id == chapterID {
                selectedID = id
                newRange = .init(lowerBound: range.lowerBound, upperBound: range.upperBound + delta)
                exclusions = []
            } else if chapter.sourceRange.lowerBound >= range.upperBound {
                newRange = shifted(newRange)
                exclusions = exclusions.map(shifted)
            }
            return AudiobookChapter(id: id, bookID: chapter.bookID, sourceID: newSourceID, ordinal: chapter.ordinal,
                title: chapter.id == chapterID ? title : chapter.title, sourceRange: newRange,
                excludedRanges: exclusions, isSkipped: chapter.isSkipped)
        }
        try updatedSource.validateCoverage(updatedChapters.map(\.sourceRange))
        return (prepared, updatedChapters, selectedID)
    }

    public static func validateMap(_ map: [AudiobookWorkingSourceSpan], working: AudiobookSourceIndex, reference: AudiobookSourceIndex) throws {
        var end: Int64 = 0, referenceEnd: Int64 = 0
        for span in map {
            try working.validateRangeBounds(span.workingRange)
            try reference.validateRangeBounds(span.referenceRange)
            guard span.workingRange.lowerBound == end, !span.workingRange.isEmpty,
                  span.referenceRange.lowerBound >= referenceEnd,
                  span.isUserEdited != true || span.isGenerated else { throw AudiobookStoreError.workingSourceChanged }
            if !span.isGenerated {
                guard working.utf8Data[Int(span.workingRange.lowerBound)..<Int(span.workingRange.upperBound)]
                    == reference.utf8Data[Int(span.referenceRange.lowerBound)..<Int(span.referenceRange.upperBound)] else {
                    throw AudiobookStoreError.workingSourceChanged
                }
            }
            end = span.workingRange.upperBound; referenceEnd = span.referenceRange.upperBound
        }
        guard end == working.byteCount else { throw AudiobookStoreError.workingSourceChanged }
    }
}

public enum AudiobookTextPreparation {
    public static let version = "audiobook_text_preparation_v1"

    public static func prepare(referenceUTF8: Data) throws -> AudiobookPreparedText {
        let reference = try AudiobookSourceIndex(utf8: referenceUTF8)
        var output = Data()
        var mapping: [AudiobookWorkingSourceSpan] = []
        var previousReferenceEnd: Int64 = 0
        func append(_ data: Data, referenceRange: AudiobookSourceRange, generated: Bool, isolatedTitle: Bool? = nil) {
            guard !data.isEmpty else { return }
            let start = Int64(output.count)
            output.append(data)
            mapping.append(.init(workingRange: .init(lowerBound: start, upperBound: Int64(output.count)),
                                 referenceRange: referenceRange, isGenerated: generated, isIsolatedTitleCandidate: isolatedTitle))
            previousReferenceEnd = referenceRange.upperBound
        }
        for paragraph in reference.paragraphs {
            let raw = try reference.text(in: paragraph.sourceRange)
            // Keep exact retained byte ranges; only trim physical-line layout whitespace.
            var lineStart = paragraph.sourceRange.lowerBound
            var pieces: [(Data, AudiobookSourceRange)] = []
            var current = ""
            func flushLine() {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let range = current.range(of: trimmed) {
                    let start = lineStart + Int64(current[..<range.lowerBound].utf8.count)
                    pieces.append((Data(trimmed.utf8), .init(lowerBound: start, upperBound: start + Int64(trimmed.utf8.count))))
                }
                current = ""
            }
            var offset = lineStart
            for scalar in raw.unicodeScalars {
                if scalar == "\r" || scalar == "\n" {
                    flushLine()
                    lineStart = offset + Int64(scalar.utf8.count)
                } else { current.unicodeScalars.append(scalar) }
                offset += Int64(scalar.utf8.count)
            }
            flushLine()
            guard let first = pieces.first else { continue }
            if !output.isEmpty {
                append(Data("\n\n".utf8), referenceRange: .init(lowerBound: previousReferenceEnd, upperBound: first.1.lowerBound), generated: true)
            }
            var joined = ""
            for (pieceIndex, piece) in pieces.enumerated() {
                let (bytes, range) = piece
                let text = String(decoding: bytes, as: UTF8.self)
                // Use the same joining policy as paragraph classification/display.
                if !joined.isEmpty {
                    let combined = AudiobookSourceIndex.joinParagraphLines(joined + "\n" + text)
                    if combined.utf8.count > joined.utf8.count + bytes.count {
                        append(Data(" ".utf8), referenceRange: .init(lowerBound: previousReferenceEnd, upperBound: range.lowerBound), generated: true)
                    }
                }
                append(bytes, referenceRange: range, generated: false, isolatedTitle: pieceIndex == 0 ? paragraph.isIsolatedTitleCandidate : nil)
                joined = text
            }
        }
        guard !output.isEmpty else { throw AudiobookImportError.emptyFile }
        return .init(workingUTF8: output, workingSHA256: AudiobookDigest.sha256Hex(output),
                     preparationVersion: version, sourceMap: mapping)
    }
}
