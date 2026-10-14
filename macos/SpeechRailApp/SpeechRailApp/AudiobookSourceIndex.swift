import CryptoKit
import Foundation

public struct AudiobookSourceIndex: Sendable, Equatable {
    public let utf8Data: Data
    public let sourceSHA256: String
    /// Sorted UTF-8 byte offsets of every Unicode scalar start, plus `byteCount` at the end.
    public let scalarByteOffsets: [Int64]

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
        maxAtomScalars: Int = AudiobookLimits.maxAtomScalars
    ) throws -> [AudiobookTextAtom] {
        let effectiveMaxScalars = max(1, min(maxAtomScalars, AudiobookLimits.maxAtomScalars))
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
            var insideQuotes = false

            var cursorScalarIdx = startScalarIdx
            while cursorScalarIdx < endScalarIdx {
                let scalar = scalarAt(scalarIndex: cursorScalarIdx)
                let nextScalarIdx = cursorScalarIdx + 1
                let currentAtomLength = nextScalarIdx - atomStartScalarIdx

                let isOpeningQuote = Self.openingQuoteScalars.contains(scalar)
                let isClosingQuote = Self.closingQuoteScalars.contains(scalar)
                if isOpeningQuote {
                    if cursorScalarIdx > atomStartScalarIdx {
                        // Split before opening quote so narration and dialogue stay in distinct atoms.
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
                    insideQuotes = true
                } else if isClosingQuote {
                    insideQuotes = false
                }

                let isLineBreakEnd: Bool = {
                    if scalar == "\n" { return true }
                    if scalar == "\r" {
                        if nextScalarIdx < endScalarIdx && scalarAt(scalarIndex: nextScalarIdx) == "\n" {
                            return false
                        }
                        return true
                    }
                    return false
                }()

                let isSentenceBoundary = Self.sentenceTerminalScalars.contains(scalar) && !insideQuotes
                let isClosingQuoteBoundary = isClosingQuote
                let reachedMaxScalars = (nextScalarIdx - atomStartScalarIdx) >= effectiveMaxScalars

                if isLineBreakEnd || isClosingQuoteBoundary || isSentenceBoundary || reachedMaxScalars || nextScalarIdx == endScalarIdx {
                    // Absorb immediately following whitespace/closing punctuation on the same line if room permits
                    var finalEndScalarIdx = nextScalarIdx
                    if !isLineBreakEnd && !reachedMaxScalars {
                        while finalEndScalarIdx < endScalarIdx,
                              (finalEndScalarIdx - atomStartScalarIdx) < effectiveMaxScalars
                        {
                            let peek = scalarAt(scalarIndex: finalEndScalarIdx)
                            if peek == "\r" && finalEndScalarIdx + 1 < endScalarIdx && scalarAt(scalarIndex: finalEndScalarIdx + 1) == "\n" {
                                finalEndScalarIdx += 2
                                isFirstLineInChapter = false
                                break
                            } else if peek == "\n" || peek == "\r" {
                                finalEndScalarIdx += 1
                                isFirstLineInChapter = false
                                break
                            } else if Self.closingTrailScalars.contains(peek) {
                                finalEndScalarIdx += 1
                            } else {
                                break
                            }
                        }
                    }

                    if isLineBreakEnd {
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

                _ = currentAtomLength
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

    // MARK: - Private Helpers

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
        "”", "’", "」", "』", "）", ")", "】", "]",
    ]
}
