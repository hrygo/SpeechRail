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

        return ranges.enumerated().map { ordinal, range in
            let text = String(sourceText[range])
            let pauseHint: TeleprompterPauseHint = switch text.count {
            case 0..<45: .short
            case 45..<100: .medium
            default: .long
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
            if isSentenceBoundary(sourceText[cursor]) {
                if let trimmed = trimmedRange(in: sourceText, range: start..<next) {
                    result.append(contentsOf: boundedRanges(in: sourceText, range: trimmed))
                }
                start = next
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

    private static func isSentenceBoundary(_ character: Character) -> Bool {
        ".。!?！？;；".contains(character)
    }
}
