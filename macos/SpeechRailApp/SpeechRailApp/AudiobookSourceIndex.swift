import CryptoKit
import Foundation

public struct AudiobookSourceIndex: Sendable, Equatable {
    public enum TextLayoutProfile: String, Codable, Sendable, Equatable {
        case hardWrapped
        case naturalParagraphs
    }

    public let utf8Data: Data
    public let sourceSHA256: String
    /// Sorted UTF-8 byte offsets of every Unicode scalar start, plus `byteCount` at the end.
    public let scalarByteOffsets: [Int64]
    public let layoutProfile: TextLayoutProfile

    public init(utf8: Data) throws {
        var decoder = UTF8()
        var iterator = utf8.makeIterator()
        var offsets: [Int64] = []
        offsets.reserveCapacity(utf8.count / 2 + 1)

        var currentByteOffset: Int64 = 0
        offsets.append(0)

        while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar):
                let scalarByteLength = Int64(UTF8.width(scalar))
                currentByteOffset += scalarByteLength
                offsets.append(currentByteOffset)
            case .emptyInput:
                break
            case .error:
                throw AudiobookSourceError.invalidUTF8
            }
            if currentByteOffset == Int64(utf8.count) {
                break
            }
        }

        guard currentByteOffset == Int64(utf8.count) else {
            throw AudiobookSourceError.invalidUTF8
        }

        self.utf8Data = utf8
        self.sourceSHA256 = AudiobookDigest.sha256Hex(utf8)
        self.scalarByteOffsets = offsets
        self.layoutProfile = Self.detectLayoutProfile(utf8Data: utf8, scalarByteOffsets: offsets)
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
            let value = scalarByteOffsets[mid]
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
                                lowerBound: scalarByteOffsets[atomStartScalarIdx],
                                upperBound: scalarByteOffsets[cursorScalarIdx]
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

                let isSentenceBoundary = Self.sentenceTerminalScalars.contains(scalar) && !insideDialogueQuote
                let reachedMaxScalars = currentAtomLength >= effectiveMaxScalars

                if isHardLineBreakEnd || isDialogueClosingQuoteBoundary || isSentenceBoundary || reachedMaxScalars || nextScalarIdx == endScalarIdx {
                    // Absorb immediately following whitespace/closing punctuation on the same line if room permits
                    var finalEndScalarIdx = nextScalarIdx
                    if !isHardLineBreakEnd && !reachedMaxScalars {
                        while finalEndScalarIdx < endScalarIdx,
                              (finalEndScalarIdx - atomStartScalarIdx) < effectiveMaxScalars
                        {
                            let peek = scalarAt(scalarIndex: finalEndScalarIdx)
                            if peek == "\r" && finalEndScalarIdx + 1 < endScalarIdx && scalarAt(scalarIndex: finalEndScalarIdx + 1) == "\n" {
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
                        lowerBound: scalarByteOffsets[atomStartScalarIdx],
                        upperBound: scalarByteOffsets[finalEndScalarIdx]
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
        guard text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return text
        }
        let standard = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result = ""
        result.reserveCapacity(standard.count)
        let scalars = Array(standard.unicodeScalars)
        for i in 0..<scalars.count {
            let sc = scalars[i]
            if sc == "\n" {
                let prev = i > 0 ? scalars[i - 1] : nil
                let next = i + 1 < scalars.count ? scalars[i + 1] : nil
                if let p = prev, let n = next {
                    let isPrevCJK = isCJK(p)
                    let isNextCJK = isCJK(n)
                    if isPrevCJK && isNextCJK {
                        continue
                    } else if CharacterSet.whitespaces.contains(p) || CharacterSet.whitespaces.contains(n) {
                        continue
                    } else {
                        result.append(" ")
                        continue
                    }
                }
                continue
            }
            result.append(String(sc))
        }
        return result
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v)
            || (0x3000...0x303F).contains(v)
            || (0xFF00...0xFFEF).contains(v)
    }

    // MARK: - Private Helpers

    private static func detectLayoutProfile(
        utf8Data: Data,
        scalarByteOffsets: [Int64]
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
