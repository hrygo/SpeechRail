import Foundation

public enum TeleprompterNormalizer {
    public struct IndexedToken: Equatable, Sendable {
        public let value: String
        public let range: TeleprompterSourceRange
    }

    public struct ReadingSlice: Identifiable, Equatable, Sendable {
        public let id: String
        public let segmentIndex: Int
        public let start: Int
        public let end: Int
        public let text: String
    }

    public static func readingSlices(segments: [TeleprompterSegment], tokensPerSlice: Int) -> [ReadingSlice] {
        var result: [ReadingSlice] = []
        for (index, segment) in segments.enumerated() {
            let tokens = indexedTokens(segment.text)
            var start = 0
            let limit = max(1, tokensPerSlice)
            var boundaries = stride(from: limit, to: tokens.count, by: limit).map { tokens[$0].range.start }
            boundaries.append(segment.text.utf16.count)
            for end in boundaries where end > start {
                if let range = Range(NSRange(location: start, length: end - start), in: segment.text) {
                    result.append(.init(id: "\(segment.id):\(start)", segmentIndex: index, start: start,
                                        end: end, text: String(segment.text[range])))
                }
                start = end
            }
        }
        return result
    }

    public static func normalize(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    public static func tokens(_ text: String) -> [String] {
        indexedTokens(text).map(\.value)
    }

    /// Fold individual graphemes while retaining their original UTF-16 range.
    /// Fillers are removed only as whole tokens, never inside English words.
    public static func indexedTokens(_ text: String) -> [IndexedToken] {
        var result: [IndexedToken] = []
        var buffer = ""
        var bufferStart = 0
        var bufferEnd = 0
        var offset = 0
        func flush() {
            if !buffer.isEmpty, !["uh", "um", "er", "嗯", "呃", "额"].contains(buffer) {
                result.append(.init(value: buffer, range: .init(start: bufferStart, end: bufferEnd)))
            }
            buffer = ""
        }
        for character in text {
            let raw = String(character)
            let end = offset + raw.utf16.count
            let folded = raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
            for scalar in folded.unicodeScalars {
                if isCJK(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                    flush()
                    let value = String(scalar)
                    if !["嗯", "呃", "额"].contains(value) {
                        result.append(.init(value: value, range: .init(start: offset, end: end)))
                    }
                } else if CharacterSet.letters.contains(scalar) {
                    if buffer.isEmpty { bufferStart = offset }
                    buffer.append(contentsOf: String(scalar))
                    bufferEnd = end
                } else {
                    flush()
                }
            }
            offset = end
        }
        flush()
        return result
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || value == 0x3007
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }
}


/// Deterministic text equivalence shared by authored scripts and Realtime ASR output.
/// Numeric matches retain the original UTF-16 source span so cursor positions remain
/// anchored to the displayed script rather than the canonicalized value.
public enum TeleprompterCanonicalizer {
    public struct Unit: Equatable, Sendable {
        public let value: String
        public let range: TeleprompterSourceRange
        public let isNumeric: Bool

        public init(value: String, range: TeleprompterSourceRange, isNumeric: Bool) {
            self.value = value
            self.range = range
            self.isNumeric = isNumeric
        }
    }

    private enum NumericKind: Sendable {
        case percentage
        case year
        case spokenDecimal
        case spokenUnit
        case arabic
    }

    private struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        let kind: NumericKind
    }

    private static let rules: [Rule] = [
        .init(expression: expression(#"百分之[零一二三四五六七八九十百千万点0-9]+"#), kind: .percentage),
        .init(expression: expression(#"[零〇一二三四五六七八九]{4}年"#), kind: .year),
        .init(expression: expression(#"[零一二三四五六七八九十百千万0-9]+点[零一二三四五六七八九0-9]+"#), kind: .spokenDecimal),
        .init(expression: expression(#"[零一二两三四五六七八九十百千万亿]+(?:公里|美元|元|米|岁|号|楼|月|日|倍|个|人|次|天|分|秒|点)"#), kind: .spokenUnit),
        .init(expression: expression(#"[0-9]+(?:\.[0-9]+)?(?:年|美元|公里|元|米|岁|号|楼|月|日|倍|个|人|次|天|分|秒|点|%)?"#), kind: .arabic),
    ]

    private static let chineseDigits: [Character: String] = [
        "零": "0", "〇": "0", "一": "1", "二": "2", "两": "2", "三": "3", "四": "4",
        "五": "5", "六": "6", "七": "7", "八": "8", "九": "9",
    ]
    private static let smallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1_000]
    private static let largeUnits: [Character: Int] = ["万": 10_000, "亿": 100_000_000]
    private static let unitSuffixes = ["公里", "美元", "元", "米", "岁", "号", "楼", "月", "日", "倍", "个", "人", "次", "天", "分", "秒", "点"]

    public static func values(_ text: String) -> [String] {
        units(text).map(\.value)
    }

    public static func units(_ text: String) -> [Unit] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard fullRange.length > 0 else { return [] }

        var result: [Unit] = []
        var cursor = 0
        while cursor < fullRange.length {
            let searchRange = NSRange(location: cursor, length: fullRange.length - cursor)
            var earliest: (rule: Rule, range: NSRange)?
            for rule in rules {
                guard let match = rule.expression.firstMatch(in: text, range: searchRange) else { continue }
                if earliest == nil
                    || match.range.location < earliest!.range.location
                    || (match.range.location == earliest!.range.location && match.range.length > earliest!.range.length) {
                    earliest = (rule, match.range)
                }
            }

            guard let match = earliest else {
                appendNormalized(text, range: NSRange(location: cursor, length: fullRange.length - cursor), to: &result)
                break
            }

            if match.range.location > cursor {
                appendNormalized(
                    text,
                    range: NSRange(location: cursor, length: match.range.location - cursor),
                    to: &result
                )
            }

            if let sourceRange = Range(match.range, in: text) {
                let raw = String(text[sourceRange])
                if let value = canonicalValue(raw, kind: match.rule.kind) {
                    result.append(.init(
                        value: value,
                        range: .init(start: match.range.location, end: match.range.location + match.range.length),
                        isNumeric: true
                    ))
                } else {
                    appendNormalized(text, range: match.range, to: &result)
                }
            }
            cursor = match.range.location + match.range.length
        }
        return result
    }

    private static func appendNormalized(_ text: String, range: NSRange, to result: inout [Unit]) {
        guard range.length > 0, let sourceRange = Range(range, in: text) else { return }
        let fragment = String(text[sourceRange])
        for token in TeleprompterNormalizer.indexedTokens(fragment) {
            result.append(.init(
                value: fold(token.value),
                range: .init(start: range.location + token.range.start, end: range.location + token.range.end),
                isNumeric: false
            ))
        }
    }

    private static func canonicalValue(_ raw: String, kind: NumericKind) -> String? {
        switch kind {
        case .percentage:
            let body = String(raw.dropFirst("百分之".count))
            if let point = body.firstIndex(of: "点") {
                guard let integer = chineseInteger(String(body[..<point])) else { return nil }
                let decimal = asciiDigits(String(body[body.index(after: point)...]))
                guard !decimal.isEmpty else { return nil }
                return "\(integer).\(decimal)%"
            }
            guard let integer = chineseInteger(body) else { return nil }
            return "\(integer)%"

        case .year:
            let digits = asciiDigits(String(raw.dropLast()))
            guard digits.count == 4 else { return nil }
            return "\(digits)年"

        case .spokenDecimal:
            guard let point = raw.firstIndex(of: "点"),
                  let integer = chineseInteger(String(raw[..<point])) else { return nil }
            let decimal = asciiDigits(String(raw[raw.index(after: point)...]))
            guard !decimal.isEmpty else { return nil }
            return "\(integer).\(decimal)"

        case .spokenUnit:
            guard let suffix = unitSuffixes.first(where: raw.hasSuffix) else { return nil }
            let number = String(raw.dropLast(suffix.count))
            guard let integer = chineseInteger(number) else { return nil }
            return "\(integer)\(suffix)"

        case .arabic:
            return fold(raw)
        }
    }

    private static func chineseInteger(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        if text.utf8.allSatisfy({ (48...57).contains($0) }) {
            return Int(text)
        }

        var total = 0
        var section = 0
        var number = 0
        for character in text {
            if let digit = chineseDigits[character], let value = Int(digit) {
                number = value
            } else if let unit = smallUnits[character] {
                if character == "十", number == 0 { number = 1 }
                section += number * unit
                number = 0
            } else if let unit = largeUnits[character] {
                section = (section + number) * unit
                total += section
                section = 0
                number = 0
            } else {
                return nil
            }
        }
        return total + section + number
    }

    private static func asciiDigits(_ text: String) -> String {
        text.map { chineseDigits[$0] ?? String($0) }.joined()
    }

    private static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func expression(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid built-in teleprompter numeric pattern: \(error)")
        }
    }
}
