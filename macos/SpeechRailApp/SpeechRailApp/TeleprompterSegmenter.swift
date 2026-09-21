import Foundation

public enum TeleprompterSegmenter {
    private static let maxCharactersPerSegment = 60

    public static func segment(sourceText: String) throws -> [TeleprompterSegment] {
        guard !TeleprompterNormalizer.tokens(sourceText).isEmpty else {
            throw TeleprompterTextError.emptySource
        }

        var paragraphRanges: [Range<String.Index>] = []
        var paragraphStart = sourceText.startIndex
        var cursor = paragraphStart
        while cursor < sourceText.endIndex {
            if sourceText[cursor].isNewline {
                if let trimmed = trimmedRange(in: sourceText, range: paragraphStart..<cursor) {
                    paragraphRanges.append(trimmed)
                }
                paragraphStart = sourceText.index(after: cursor)
            }
            cursor = sourceText.index(after: cursor)
        }
        if let trimmed = trimmedRange(in: sourceText, range: paragraphStart..<sourceText.endIndex) {
            paragraphRanges.append(trimmed)
        }

        var ranges: [Range<String.Index>] = []
        for paragraph in paragraphRanges {
            ranges.append(contentsOf: sentenceRanges(in: sourceText, paragraph: paragraph))
        }
        let sectionEnds = Set(paragraphRanges.map(\.upperBound))

        return ranges.enumerated().map { ordinal, range in
            let text = String(sourceText[range])
            let pauseHint: TeleprompterPauseHint
            if sectionEnds.contains(range.upperBound) {
                pauseHint = .long
            } else if text.last.map({ ".。!?！？;；".contains($0) }) == true {
                pauseHint = .medium
            } else {
                pauseHint = .short
            }
            return TeleprompterSegment(
                id: "segment-\(ordinal + 1)",
                ordinal: ordinal,
                sourceRange: TeleprompterSourceRange(
                    start: range.lowerBound.utf16Offset(in: sourceText),
                    end: range.upperBound.utf16Offset(in: sourceText)
                ),
                text: text,
                keywords: [],
                matchPhrases: [],
                pauseHint: pauseHint
            )
        }
    }

    private static func sentenceRanges(
        in sourceText: String,
        paragraph: Range<String.Index>
    ) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = paragraph.lowerBound
        var cursor = start

        while cursor < paragraph.upperBound {
            let next = sourceText.index(after: cursor)
            if isSentenceBoundary(in: sourceText, at: cursor) {
                let end = sentenceEnd(in: sourceText, boundary: cursor, upperBound: paragraph.upperBound)
                if let trimmed = trimmedRange(in: sourceText, range: start..<end) {
                    result.append(contentsOf: boundedRanges(in: sourceText, range: trimmed))
                }
                start = end
                while start < paragraph.upperBound && sourceText[start].isWhitespace {
                    start = sourceText.index(after: start)
                }
            }
            cursor = next
        }
        if let trimmed = trimmedRange(in: sourceText, range: start..<paragraph.upperBound) {
            result.append(contentsOf: boundedRanges(in: sourceText, range: trimmed))
        }
        return result
    }

    private static func boundedRanges(
        in sourceText: String,
        range: Range<String.Index>
    ) -> [Range<String.Index>] {
        guard sourceText.distance(from: range.lowerBound, to: range.upperBound) > maxCharactersPerSegment else {
            return [range]
        }

        var result: [Range<String.Index>] = []
        var start = range.lowerBound
        while start < range.upperBound {
            var end = sourceText.index(
                start,
                offsetBy: maxCharactersPerSegment,
                limitedBy: range.upperBound
            ) ?? range.upperBound
            // Do not cut an English word. Prefer a nearby whitespace/comma boundary.
            if end < range.upperBound {
                let candidates = sourceText[start..<end].indices.filter {
                    sourceText[$0].isWhitespace || ",，、:：".contains(sourceText[$0])
                }
                if let boundary = candidates.last,
                   sourceText.distance(from: start, to: boundary) >= maxCharactersPerSegment / 2 {
                    end = sourceText.index(after: boundary)
                }
            }

            // Never split a long Latin word or identifier merely because it
            // crossed the soft 60-grapheme target. The resulting unit may be
            // longer than the target, but remains pronounceable and traceable.
            while end < range.upperBound,
                  let previous = end > start ? sourceText.index(before: end) : nil,
                  isWordCharacter(sourceText[previous]),
                  isWordCharacter(sourceText[end]) {
                end = sourceText.index(after: end)
            }
            result.append(start..<end)
            start = end
            while start < range.upperBound && sourceText[start].isWhitespace {
                start = sourceText.index(after: start)
            }
        }
        return result
    }

    private static func trimmedRange(
        in sourceText: String,
        range: Range<String.Index>
    ) -> Range<String.Index>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper && sourceText[lower].isWhitespace {
            lower = sourceText.index(after: lower)
        }
        while upper > lower {
            let previous = sourceText.index(before: upper)
            guard sourceText[previous].isWhitespace else { break }
            upper = previous
        }
        return lower < upper ? lower..<upper : nil
    }

    private static func isSentenceBoundary(in sourceText: String, at index: String.Index) -> Bool {
        let character = sourceText[index]
        guard ".。!?！？;；".contains(character) else { return false }
        guard character == "." else { return true }

        let previous = index > sourceText.startIndex ? sourceText[sourceText.index(before: index)] : nil
        let nextIndex = sourceText.index(after: index)
        let next = nextIndex < sourceText.endIndex ? sourceText[nextIndex] : nil

        // Keep decimals, versions, domain names and abbreviations inside one
        // reading unit. A period at the end of a sentence remains a boundary.
        if let previous, let next,
           isDigit(previous), isDigit(next) {
            return false
        }
        if let previous, let next,
           isWordCharacter(previous), isWordCharacter(next) {
            return false
        }
        if abbreviationBeforePeriod(in: sourceText, at: index) {
            return false
        }
        return true
    }

    private static func abbreviationBeforePeriod(in sourceText: String, at index: String.Index) -> Bool {
        var start = index
        while start > sourceText.startIndex {
            let previous = sourceText.index(before: start)
            guard isWordCharacter(sourceText[previous]) || sourceText[previous] == "." else { break }
            start = previous
        }
        let token = String(sourceText[start..<index]).lowercased()
        return ["dr", "mr", "mrs", "ms", "prof", "sr", "jr", "e.g", "i.e"].contains(token)
    }

    private static func sentenceEnd(
        in sourceText: String,
        boundary: String.Index,
        upperBound: String.Index
    ) -> String.Index {
        var end = sourceText.index(after: boundary)
        while end < upperBound && isClosingCharacter(sourceText[end]) {
            end = sourceText.index(after: end)
        }
        return end
    }

    private static func isClosingCharacter(_ character: Character) -> Bool {
        ["\"", "'", "”", "’", "》", "」", "』", "）", ")", "]", "}", "〉", "〕", "】"]
            .contains(character)
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                || $0.value == 0x5F || $0.value == 0x23
        }
    }
}
