import Foundation

public enum AudiobookChapterPlanner {
    /// Plans initial chapters from canonical UTF-8 source index.
    /// Falls back to a single `"全文"` chapter when no reliable headings are detected.
    public static func chapters(
        source: AudiobookSourceIndex,
        bookID: UUID = UUID(),
        sourceID: UUID = UUID()
    ) throws -> [AudiobookChapter] {
        if source.byteCount == 0 {
            return []
        }

        let lines = try scanLines(in: source)
        var headingLineIndices: [Int] = []

        for (index, line) in lines.enumerated() {
            if isChapterHeading(line.trimmedText) {
                headingLineIndices.append(index)
            }
        }

        guard !headingLineIndices.isEmpty else {
            let whole = AudiobookChapter(
                id: deterministicChapterID(bookID: bookID, sourceID: sourceID, range: source.wholeRange, ordinal: 0),
                bookID: bookID,
                sourceID: sourceID,
                ordinal: 0,
                title: "全文",
                sourceRange: source.wholeRange,
                excludedRanges: []
            )
            try validateChapterEdits([whole], source: source)
            return [whole]
        }

        var chapters: [AudiobookChapter] = []
        var ordinal = 0

        // If there is non-whitespace text before the first heading (e.g. preface/metadata), preserve it as its own leading chapter.
        let firstHeadingStart = lines[headingLineIndices[0]].range.lowerBound
        if firstHeadingStart > 0 {
            let leadingRange = AudiobookSourceRange(lowerBound: 0, upperBound: firstHeadingStart)
            let leadingSlice = try source.text(in: leadingRange)
            if !leadingSlice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let firstNonEmptyTitle = lines[0..<headingLineIndices[0]]
                    .map(\.trimmedText)
                    .first(where: { !$0.isEmpty }) ?? "前言"
                let title = String(firstNonEmptyTitle.prefix(48))
                chapters.append(
                    AudiobookChapter(
                        id: deterministicChapterID(bookID: bookID, sourceID: sourceID, range: leadingRange, ordinal: ordinal),
                        bookID: bookID,
                        sourceID: sourceID,
                        ordinal: ordinal,
                        title: title,
                        sourceRange: leadingRange,
                        excludedRanges: []
                    )
                )
                ordinal += 1
            }
        }

        for (pos, lineIdx) in headingLineIndices.enumerated() {
            let startOffset: Int64
            if pos == 0 && chapters.isEmpty {
                startOffset = 0
            } else {
                startOffset = lines[lineIdx].range.lowerBound
            }
            let endOffset: Int64
            if pos + 1 < headingLineIndices.count {
                endOffset = lines[headingLineIndices[pos + 1]].range.lowerBound
            } else {
                endOffset = source.byteCount
            }

            let range = AudiobookSourceRange(lowerBound: startOffset, upperBound: endOffset)
            let headingTitle = lines[lineIdx].trimmedText
            chapters.append(
                AudiobookChapter(
                    id: deterministicChapterID(bookID: bookID, sourceID: sourceID, range: range, ordinal: ordinal),
                    bookID: bookID,
                    sourceID: sourceID,
                    ordinal: ordinal,
                    title: headingTitle.isEmpty ? "第 \(ordinal + 1) 章" : headingTitle,
                    sourceRange: range,
                    excludedRanges: []
                )
            )
            ordinal += 1
        }

        try validateChapterEdits(chapters, source: source)
        return chapters
    }

    /// Validates that chapters and their explicit `excludedRanges` partition the entire `AudiobookSourceIndex`
    /// in strict ascending order without holes, overlaps, or out-of-bounds scalar slicing.
    public static func validateChapterEdits(
        _ chapters: [AudiobookChapter],
        source: AudiobookSourceIndex
    ) throws {
        do {
            try source.validateCoverage(
                chapters.map(\.sourceRange),
                exclusions: [],
                in: source.wholeRange
            )
            for chapter in chapters {
                // Verify each chapter's excluded ranges lie strictly within the chapter and don't overlap.
                if !chapter.excludedRanges.isEmpty {
                    let activeSpans = try computeNonExcludedSpans(
                        in: chapter.sourceRange,
                        exclusions: chapter.excludedRanges,
                        source: source
                    )
                    try source.validateCoverage(
                        activeSpans,
                        exclusions: chapter.excludedRanges,
                        in: chapter.sourceRange
                    )
                }
            }
        } catch let error as AudiobookSourceError {
            throw AudiobookImportError.chapterCoverageInvalid(error)
        }
    }

    /// Splits a chapter at `splitByteOffset` on a scalar boundary, preserving coverage and exclusions.
    public static func splitChapter(
        _ chapters: [AudiobookChapter],
        chapterID: UUID,
        atByteOffset splitByteOffset: Int64,
        secondTitle: String,
        source: AudiobookSourceIndex
    ) throws -> [AudiobookChapter] {
        guard let idx = chapters.firstIndex(where: { $0.id == chapterID }) else {
            return chapters
        }
        let target = chapters[idx]
        try source.validateRangeBounds(
            AudiobookSourceRange(lowerBound: target.sourceRange.lowerBound, upperBound: splitByteOffset)
        )
        guard splitByteOffset > target.sourceRange.lowerBound,
              splitByteOffset < target.sourceRange.upperBound
        else {
            throw AudiobookImportError.chapterCoverageInvalid(
                .rangeOutOfBounds(
                    AudiobookSourceRange(lowerBound: splitByteOffset, upperBound: splitByteOffset),
                    totalBytes: target.sourceRange.upperBound
                )
            )
        }

        let firstRange = AudiobookSourceRange(lowerBound: target.sourceRange.lowerBound, upperBound: splitByteOffset)
        let secondRange = AudiobookSourceRange(lowerBound: splitByteOffset, upperBound: target.sourceRange.upperBound)

        let firstExclusions = target.excludedRanges.compactMap { ex -> AudiobookSourceRange? in
            let lower = max(ex.lowerBound, firstRange.lowerBound)
            let upper = min(ex.upperBound, firstRange.upperBound)
            return lower < upper ? AudiobookSourceRange(lowerBound: lower, upperBound: upper) : nil
        }
        let secondExclusions = target.excludedRanges.compactMap { ex -> AudiobookSourceRange? in
            let lower = max(ex.lowerBound, secondRange.lowerBound)
            let upper = min(ex.upperBound, secondRange.upperBound)
            return lower < upper ? AudiobookSourceRange(lowerBound: lower, upperBound: upper) : nil
        }

        var updated = chapters
        let firstChapter = AudiobookChapter(
            id: target.id,
            bookID: target.bookID,
            sourceID: target.sourceID,
            ordinal: target.ordinal,
            title: target.title,
            sourceRange: firstRange,
            excludedRanges: firstExclusions
        )
        let secondChapter = AudiobookChapter(
            id: UUID(),
            bookID: target.bookID,
            sourceID: target.sourceID,
            ordinal: target.ordinal + 1,
            title: secondTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新章节" : secondTitle,
            sourceRange: secondRange,
            excludedRanges: secondExclusions
        )
        updated.replaceSubrange(idx...idx, with: [firstChapter, secondChapter])
        for i in updated.indices {
            updated[i].ordinal = i
        }
        try validateChapterEdits(updated, source: source)
        return updated
    }

    // MARK: - Private Helpers

    private struct LineSpan {
        let range: AudiobookSourceRange
        let trimmedText: String
    }

    private static func scanLines(in source: AudiobookSourceIndex) throws -> [LineSpan] {
        var lines: [LineSpan] = []
        let data = source.utf8Data
        var lineStart: Int64 = 0
        var i = 0
        let count = data.count

        while i < count {
            let byte = data[data.startIndex + i]
            if byte == 0x0A {
                let lineEnd = Int64(i + 1)
                let range = AudiobookSourceRange(lowerBound: lineStart, upperBound: lineEnd)
                let text = try source.text(in: range)
                lines.append(LineSpan(range: range, trimmedText: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                lineStart = lineEnd
                i += 1
            } else if byte == 0x0D {
                if i + 1 < count, data[data.startIndex + i + 1] == 0x0A {
                    let lineEnd = Int64(i + 2)
                    let range = AudiobookSourceRange(lowerBound: lineStart, upperBound: lineEnd)
                    let text = try source.text(in: range)
                    lines.append(LineSpan(range: range, trimmedText: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    lineStart = lineEnd
                    i += 2
                } else {
                    let lineEnd = Int64(i + 1)
                    let range = AudiobookSourceRange(lowerBound: lineStart, upperBound: lineEnd)
                    let text = try source.text(in: range)
                    lines.append(LineSpan(range: range, trimmedText: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    lineStart = lineEnd
                    i += 1
                }
            } else {
                i += 1
            }
        }

        if lineStart < source.byteCount {
            let range = AudiobookSourceRange(lowerBound: lineStart, upperBound: source.byteCount)
            let text = try source.text(in: range)
            lines.append(LineSpan(range: range, trimmedText: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return lines
    }

    private static func isChapterHeading(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 48 else {
            return false
        }
        let patterns = [
            #"^第[零一二三四五六七八九十百千万0-9]+[章节回卷集部篇](\s+.*|$)"#,
            #"^(序章|序言|楔子|引子|尾声|终章|后记|番外|附言)(\s+.*|$)"#,
            #"^(Chapter|CHAPTER)\s+[0-9IVXLCDM]+(\s+.*|:.*|$)"#,
        ]
        for pattern in patterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    private static func computeNonExcludedSpans(
        in chapterRange: AudiobookSourceRange,
        exclusions: [AudiobookSourceRange],
        source: AudiobookSourceIndex
    ) throws -> [AudiobookSourceRange] {
        let sorted = exclusions.sorted()
        var cursor = chapterRange.lowerBound
        var spans: [AudiobookSourceRange] = []

        for ex in sorted {
            try source.validateRangeBounds(ex)
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

    private static func deterministicChapterID(
        bookID: UUID,
        sourceID: UUID,
        range: AudiobookSourceRange,
        ordinal: Int
    ) -> UUID {
        let seed = "chapter:\(bookID.uuidString):\(sourceID.uuidString):\(ordinal):\(range.lowerBound):\(range.upperBound)"
        let digest = Array(AudiobookDigest.sha256Hex(Data(seed.utf8)).utf8)
        guard digest.count >= 16 else { return UUID() }
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5],
            (digest[6] & 0x0F) | 0x50,
            (digest[7] & 0x3F) | 0x80,
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
