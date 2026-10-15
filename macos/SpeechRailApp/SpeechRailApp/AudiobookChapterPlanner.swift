import Foundation

public enum AudiobookChapterEditError: LocalizedError, Equatable, Sendable {
    case chapterNotFound(UUID)
    case firstChapterCannotMerge
    case chapterIdentityMismatch
    case chaptersAreNotContiguous

    public var errorDescription: String? {
        switch self {
        case .chapterNotFound:
            return "找不到要整理的章节，请刷新后重试。"
        case .firstChapterCannotMerge:
            return "第一章前面没有章节可合并。"
        case .chapterIdentityMismatch:
            return "只有同一本书、同一份原文中的相邻章节才能合并。"
        case .chaptersAreNotContiguous:
            return "所选章节与上一章之间存在正文间隔，无法合并。"
        }
    }
}

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

        let lines = source.paragraphs
        let headingLineIndices = headingIndices(in: source)

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
        let firstHeadingStart = lines[headingLineIndices[0]].sourceRange.lowerBound
        if firstHeadingStart > 0 {
            let leadingRange = AudiobookSourceRange(lowerBound: 0, upperBound: firstHeadingStart)
            let leadingSlice = try source.text(in: leadingRange)
            if !leadingSlice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapters.append(
                    AudiobookChapter(
                        id: deterministicChapterID(bookID: bookID, sourceID: sourceID, range: leadingRange, ordinal: ordinal),
                        bookID: bookID,
                        sourceID: sourceID,
                        ordinal: ordinal,
                        title: "开篇",
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
                startOffset = lines[lineIdx].sourceRange.lowerBound
            }
            let endOffset: Int64
            if pos + 1 < headingLineIndices.count {
                endOffset = lines[headingLineIndices[pos + 1]].sourceRange.lowerBound
            } else {
                endOffset = source.byteCount
            }

            let range = AudiobookSourceRange(lowerBound: startOffset, upperBound: endOffset)
            let headingTitle = lines[lineIdx].text
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

    /// Merges `chapterID` with its immediately preceding chapter while preserving source coverage.
    public static func mergeChapterWithPrevious(
        _ chapters: [AudiobookChapter],
        chapterID: UUID,
        source: AudiobookSourceIndex
    ) throws -> [AudiobookChapter] {
        guard let index = chapters.firstIndex(where: { $0.id == chapterID }) else {
            throw AudiobookChapterEditError.chapterNotFound(chapterID)
        }
        guard index > chapters.startIndex else {
            throw AudiobookChapterEditError.firstChapterCannotMerge
        }

        let previous = chapters[index - 1]
        let selected = chapters[index]
        guard previous.bookID == selected.bookID,
              previous.sourceID == selected.sourceID
        else {
            throw AudiobookChapterEditError.chapterIdentityMismatch
        }
        guard previous.sourceRange.upperBound == selected.sourceRange.lowerBound else {
            throw AudiobookChapterEditError.chaptersAreNotContiguous
        }

        let merged = AudiobookChapter(
            id: previous.id,
            bookID: previous.bookID,
            sourceID: previous.sourceID,
            ordinal: previous.ordinal,
            title: previous.title,
            sourceRange: AudiobookSourceRange(
                lowerBound: previous.sourceRange.lowerBound,
                upperBound: selected.sourceRange.upperBound
            ),
            excludedRanges: (previous.excludedRanges + selected.excludedRanges).sorted()
        )
        var updated = chapters
        updated.replaceSubrange((index - 1)...index, with: [merged])
        for position in updated.indices {
            updated[position].ordinal = position
        }
        try validateChapterEdits(updated, source: source)
        return updated
    }

    // MARK: - Private Helpers

    private static func headingIndices(in source: AudiobookSourceIndex) -> [Int] {
        let paragraphs = source.paragraphs
        let explicit = paragraphs.indices.filter { AudiobookSourceIndex.isChapterHeading(paragraphs[$0].text) }
        if !explicit.isEmpty { return explicit }

        // Unnumbered anthology titles need both isolated typography and following prose.
        // Several matching titles establish a document convention; a short prose line alone does not.
        let named = paragraphs.indices.filter { index in
            let paragraph = paragraphs[index]
            guard paragraph.isIsolatedTitleCandidate, isStandaloneTitle(paragraph.text) else { return false }
            let following = paragraphs.dropFirst(index + 1).prefix(2)
            return following.contains { $0.text.unicodeScalars.count >= 16 }
        }
        if named.count >= 2 { return named }

        // Bare section numbers are chapters only without a parent title convention.
        let numbered = paragraphs.indices.filter {
            paragraphs[$0].isIsolatedTitleCandidate && sectionNumber(paragraphs[$0].text) != nil
        }
        if numbered.count >= 2,
           sectionNumber(paragraphs[numbered[0]].text) == 1,
           zip(numbered, numbered.dropFirst()).allSatisfy({
               sectionNumber(paragraphs[$0.1].text) == sectionNumber(paragraphs[$0.0].text).map { $0 + 1 }
           }) { return numbered }
        return []
    }

    private static func isStandaloneTitle(_ text: String) -> Bool {
        guard (2...48).contains(text.unicodeScalars.count),
              let first = text.unicodeScalars.first, (0x3400...0x9FFF).contains(first.value),
              !text.unicodeScalars.contains(where: { "，。！？；：、,.!?;:\"“”‘’「」『』《》".unicodeScalars.contains($0) }),
              !["作者", "著者", "译者", "譯者", "出版", "版权所有", "版權所有"].contains(where: text.hasPrefix),
              text.range(of: #"^[零〇一二三四五六七八九十百千万年月日0-9\s]+$"#, options: .regularExpression) == nil
        else { return false }
        return true
    }

    private static func sectionNumber(_ text: String) -> Int? {
        if let number = Int(text), (1...999).contains(number) { return number }
        return ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10][text]
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
