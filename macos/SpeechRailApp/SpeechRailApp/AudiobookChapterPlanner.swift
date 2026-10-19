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
        try plan(source: source, bookID: bookID, sourceID: sourceID).chapters
    }

    /// 章节规划结果：目录页来源区间随结果返回，供导入预览与测试核对。
    /// 目录区间仍包含在章节覆盖范围内，只是从可读正文与原子中排除，不会成为独立章节。
    public struct PlanningResult: Equatable, Sendable {
        public let chapters: [AudiobookChapter]
        public let tableOfContentsRanges: [AudiobookSourceRange]

        public init(chapters: [AudiobookChapter], tableOfContentsRanges: [AudiobookSourceRange]) {
            self.chapters = chapters
            self.tableOfContentsRanges = tableOfContentsRanges
        }
    }

    public static func plan(
        source: AudiobookSourceIndex,
        bookID: UUID = UUID(),
        sourceID: UUID = UUID()
    ) throws -> PlanningResult {
        if source.byteCount == 0 {
            return PlanningResult(chapters: [], tableOfContentsRanges: [])
        }

        let lines = source.paragraphs
        let proposed = headingIndices(in: source)
        let toc = detectTableOfContents(lines: lines, proposed: proposed)
        var headingLineIndices: [Int] = []
        for index in proposed where !toc.droppedHeadingIndices.contains(index) {
            if let previous = headingLineIndices.last,
               titleKey(lines[previous].text) == titleKey(lines[index].text) {
                let gap = AudiobookSourceRange(
                    lowerBound: lines[previous].sourceRange.upperBound,
                    upperBound: lines[index].sourceRange.lowerBound
                )
                let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-─—_=*·•"))
                // 三行以上同名标题时，中间只隔着分隔符和重复标题本身，也应合并为一个目录入口。
                let gapText = try source.text(in: gap)
                    .replacingOccurrences(of: lines[previous].text, with: "")
                if gapText.unicodeScalars.allSatisfy({ separators.contains($0) }) {
                    continue
                }
            }
            headingLineIndices.append(index)
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
            return PlanningResult(chapters: [whole], tableOfContentsRanges: [])
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

        chapters = attachTableOfContentsExclusions(chapters, ranges: toc.ranges)
        chapters = mergeFullyExcludedSyntheticOpening(chapters)
        for index in chapters.indices {
            chapters[index].ordinal = index
        }
        try validateChapterEdits(chapters, source: source)
        return PlanningResult(chapters: chapters, tableOfContentsRanges: toc.ranges)
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

    // MARK: - Table of Contents Detection

    private struct TableOfContentsDetection {
        var droppedHeadingIndices: Set<Int> = []
        var ranges: [AudiobookSourceRange] = []
    }

    /// 目录页的章名行本身符合章标题规则；若按标题切章，目录会变成一串只有标题的空章节，
    /// 真正的正文则被挤进最后一章。这里识别“连续多个标题、间隔内容极短、且有目录标记或后文同名标题”
    /// 的区段，将其认定为目录页并从标题候选中移除，来源字节仍由章节覆盖。
    private static func detectTableOfContents(
        lines: [AudiobookParagraph],
        proposed: [Int]
    ) -> TableOfContentsDetection {
        guard proposed.count >= 3 else { return TableOfContentsDetection() }
        var detection = TableOfContentsDetection()
        let keys = proposed.map { tableOfContentsTitleKey(lines[$0].text) }
        var index = 0
        while index + 2 < proposed.count {
            var end = index
            while end + 1 < proposed.count,
                  isTableOfContentsGap(lines: lines, lower: proposed[end], upper: proposed[end + 1]),
                  !keys[index...end].contains(keys[end + 1]) {
                end += 1
            }
            if end - index + 1 >= 3,
               isConfirmedTableOfContentsRun(lines: lines, proposed: proposed, keys: keys, start: index, end: end),
               end + 1 < proposed.count {
                var start = lines[proposed[index]].sourceRange.lowerBound
                let markerIndex = proposed[index] - 1
                if markerIndex >= 0,
                   isTableOfContentsMarker(lines[markerIndex].text),
                   lines[markerIndex].sourceRange.upperBound <= start {
                    start = lines[markerIndex].sourceRange.lowerBound
                }
                let endOffset = lines[proposed[end + 1]].sourceRange.lowerBound
                if endOffset > start {
                    detection.ranges.append(AudiobookSourceRange(lowerBound: start, upperBound: endOffset))
                    detection.droppedHeadingIndices.formUnion(proposed[index...end])
                }
                index = end + 1
                continue
            }
            index += 1
        }
        return detection
    }

    /// 目录条目之间只允许空白、页码或点引线；真实章节的正文段落会立刻中止目录区段。
    private static func isTableOfContentsGap(
        lines: [AudiobookParagraph],
        lower: Int,
        upper: Int
    ) -> Bool {
        guard upper > lower else { return false }
        let between = lines[(lower + 1)..<upper]
        if between.isEmpty { return true }
        guard between.count == 1, let only = between.first else { return false }
        let trimmed = only.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count <= 24 else { return false }
        if trimmed.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return true
        }
        return trimmed.contains("…") || trimmed.contains("···") || trimmed.contains("..")
    }

    private static func isConfirmedTableOfContentsRun(
        lines: [AudiobookParagraph],
        proposed: [Int],
        keys: [String],
        start: Int,
        end: Int
    ) -> Bool {
        let markerIndex = proposed[start] - 1
        if markerIndex >= 0,
           isTableOfContentsMarker(lines[markerIndex].text),
           lines[markerIndex].sourceRange.upperBound <= lines[proposed[start]].sourceRange.lowerBound {
            return true
        }
        let runKeys = Set(keys[start...end])
        guard !runKeys.isEmpty else { return false }
        return runKeys.isSubset(of: Set(keys[(end + 1)...]))
    }

    /// 目录行常带行尾页码或点引线（`第一章 风起……12`）；匹配后文真实章名时去掉这些尾巴，
    /// 但保留标题本身的数字（如「1984」）。
    private static func tableOfContentsTitleKey(_ text: String) -> String {
        let key = titleKey(text)
        var scalars = Array(key.unicodeScalars)
        guard !scalars.isEmpty else { return key }
        let leaders: Set<Unicode.Scalar> = [".", "．", "·", "…"]
        var end = scalars.count
        var cursor = end - 1
        var sawDigit = false
        while cursor >= 0, CharacterSet.decimalDigits.contains(scalars[cursor]) {
            sawDigit = true
            cursor -= 1
        }
        if sawDigit {
            var before = cursor
            while before >= 0, scalars[before] == " " { before -= 1 }
            let separatedFromTitle = before < cursor
            var leaderCursor = before
            var sawLeader = false
            while leaderCursor >= 0, leaders.contains(scalars[leaderCursor]) {
                sawLeader = true
                leaderCursor -= 1
            }
            if separatedFromTitle || sawLeader {
                end = leaderCursor + 1
            }
        }
        while end > 0, leaders.contains(scalars[end - 1]) {
            end -= 1
        }
        return String(String.UnicodeScalarView(scalars[0..<end]))
    }

    private static func isTableOfContentsMarker(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        if ["目录", "目錄", "目次", "contents", "content", "tableofcontents", "toc", "catalog"].contains(normalized) {
            return true
        }
        guard normalized.unicodeScalars.count <= 12 else { return false }
        return normalized.contains("目录") || normalized.contains("目錄") || normalized.contains("contents")
    }

    private static func attachTableOfContentsExclusions(
        _ chapters: [AudiobookChapter],
        ranges: [AudiobookSourceRange]
    ) -> [AudiobookChapter] {
        guard !ranges.isEmpty else { return chapters }
        var updated = chapters
        for range in ranges {
            guard let index = updated.firstIndex(where: { chapter in
                chapter.sourceRange.lowerBound < range.upperBound
                    && range.lowerBound < chapter.sourceRange.upperBound
            }) else { continue }
            let chapter = updated[index]
            let clipped = AudiobookSourceRange(
                lowerBound: max(range.lowerBound, chapter.sourceRange.lowerBound),
                upperBound: min(range.upperBound, chapter.sourceRange.upperBound)
            )
            guard !clipped.isEmpty else { continue }
            updated[index].excludedRanges = (chapter.excludedRanges + [clipped])
                .sorted()
                .reduce(into: [AudiobookSourceRange]()) { result, candidate in
                    if let last = result.last, candidate.lowerBound <= last.upperBound {
                        result[result.count - 1] = AudiobookSourceRange(
                            lowerBound: last.lowerBound,
                            upperBound: max(last.upperBound, candidate.upperBound)
                        )
                    } else {
                        result.append(candidate)
                    }
                }
        }
        return updated
    }

    /// 只有目录的“开篇”不应作为空章节留下；把整段排除区间并入下一章，目录就不进入正文与原子。
    private static func mergeFullyExcludedSyntheticOpening(
        _ chapters: [AudiobookChapter]
    ) -> [AudiobookChapter] {
        guard chapters.count >= 2 else { return chapters }
        let opening = chapters[0]
        guard opening.title == "开篇",
              opening.excludedRanges.contains(where: { range in
                  range.lowerBound <= opening.sourceRange.lowerBound
                      && range.upperBound >= opening.sourceRange.upperBound
              })
        else { return chapters }
        var second = chapters[1]
        guard opening.sourceRange.upperBound == second.sourceRange.lowerBound else { return chapters }
        second.sourceRange = AudiobookSourceRange(
            lowerBound: opening.sourceRange.lowerBound,
            upperBound: second.sourceRange.upperBound
        )
        second.excludedRanges = (opening.excludedRanges + second.excludedRanges).sorted()
        var merged = chapters
        merged.remove(at: 0)
        merged[0] = second
        return merged
    }

    // MARK: - Private Helpers

    private static func headingIndices(in source: AudiobookSourceIndex) -> [Int] {
        let paragraphs = source.paragraphs
        let explicit = paragraphs.indices.filter { AudiobookSourceIndex.isChapterHeading(paragraphs[$0].text) }

        // Unnumbered anthology titles need both isolated typography and following prose.
        // Several matching titles establish a document convention; a short prose line alone does not.
        let named = paragraphs.indices.filter { index in
            let paragraph = paragraphs[index]
            guard paragraph.isIsolatedTitleCandidate, isStandaloneTitle(paragraph.text) else { return false }
            var bodyIndex = index + 1
            if bodyIndex < paragraphs.count,
               sectionNumber(paragraphs[bodyIndex].text) != nil || AudiobookSourceIndex.isChapterHeading(paragraphs[bodyIndex].text) {
                bodyIndex += 1
            }
            guard bodyIndex < paragraphs.count else { return false }
            let following = paragraphs[bodyIndex]
            if following.isIsolatedTitleCandidate && isStandaloneTitle(following.text) { return false }
            return following.text.unicodeScalars.count >= 16
                || (following.text.unicodeScalars.count >= 4 && following.text.first.map { "“「『\"".contains($0) } == true)
        }
        // Round-numbered novels keep their explicit structure. In anthologies,
        // story titles are parents of the numbered chapters inside each story.
        let hasRoundStructure = explicit.contains { paragraphs[$0].text.range(of: #"^第[^\s]+回"#, options: .regularExpression) != nil }
        if named.count >= 2 && !hasRoundStructure { return named }
        if !explicit.isEmpty { return explicit }

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
        let primary = text.components(separatedBy: "──")[0]
            .replacingOccurrences(of: #"[〔【\[][0-9０-９]+[〕】\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard (1...16).contains(primary.unicodeScalars.count), text.unicodeScalars.count <= 48,
              let first = text.unicodeScalars.first, (0x3400...0x9FFF).contains(first.value),
              text.rangeOfCharacter(from: CharacterSet(charactersIn: "。！？；：，,.!?;:")) == nil,
              !primary.unicodeScalars.contains(where: { CharacterSet.punctuationCharacters.contains($0) }),
              !AudiobookSourceIndex.isChapterHeading(text),
              !["作者", "著者", "译者", "譯者", "出版", "版权所有", "版權所有", "注释", "注釋"].contains(where: text.hasPrefix),
              text.range(of: #"^[零〇○一二三四五六七八九十百千万年月日0-9\s]+$"#, options: .regularExpression) == nil
        else { return false }
        return true
    }

    private static func titleKey(_ title: String) -> String {
        title.filter { !$0.isWhitespace }
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
