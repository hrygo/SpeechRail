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
        case spokenMagnitude
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
        // 十分钟 is untouched by the 分 guard: 钟 is not in the set, so
        // 四十分钟 still canonicalises to 40分 + 钟.
        .init(expression: expression(#"[零一二两三四五六七八九十百千万亿]+(?:"# + unitAlternation + #"#)"#), kind: .spokenUnit),
        // A numeral that carries its own magnitude needs no unit suffix to be a
        // number. Without this rule `三万` fell through to per-character tokens
        // and fingerprinted as *no number at all*, while `3万` fingerprinted as a
        // bare `3` -- so the alias gate could not tell 30000 from 3.
        .init(expression: expression(#"[零一二两三四五六七八九十百千万亿]*[十百千万亿][零一二两三四五六七八九十百千万亿]*"#), kind: .spokenMagnitude),
        // The arabic rule has to know the Chinese magnitude words for the same
        // reason: `2万元` used to stop at the digits, and the leftover `万元` was
        // then parsed on its own into `0元`.
        // The space between digits and a CJK unit is layout, not content.
        // 98% of the digit + unit occurrences in this repository's own
        // documents carry one (6650 against 138 without), so a script drafted
        // from them has a space at nearly every number while the recogniser
        // transcribes the spoken form without any -- and the two sides landed
        // on different token streams, so the follower never matched there.
        // The fidelity gate already treated the two as equivalent; the
        // canonicalizer did not. Fixed here rather than in the aligner so that
        // every consumer of the canonical form benefits at once.
        .init(expression: expression(#"[0-9]+(?:\.[0-9]+)?(?:[万亿千百])?\s*(?:"# + unitAlternation + #"|%)?"#), kind: .arabic),
    ]

    private static let chineseDigits: [Character: String] = [
        "零": "0", "〇": "0", "一": "1", "二": "2", "两": "2", "三": "3", "四": "4",
        "五": "5", "六": "6", "七": "7", "八": "8", "九": "9",
    ]
    private static let smallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1_000]
    private static let largeUnits: [Character: Int] = ["万": 10_000, "亿": 100_000_000]
    /// One unit list for both numeral rules, **longest alternative first**.
    ///
    /// They used to be two separately kept lists and had already drifted: the
    /// Arabic rule had 年 while the spoken rule had none of 条/项/字, and the
    /// spoken rule had 台 which the Arabic rule did not. So `三年` matched
    /// nothing at all and `5 台` disagreed with `五台` — one list removes the
    /// possibility of the two drifting again.
    ///
    /// The order matters for the `hasSuffix` lookup below: given `5厘米`, a
    /// `米` that came first would win and leave `5厘`, which is not a numeral
    /// run, so the token would silently stop being a number. Longest first
    /// also makes the same string safe as a regex alternation.
    ///
    /// Membership is measured, not chosen. Units that would swallow the next
    /// word are left out even when they are common: 条→件 (条件, 500),
    /// 字→段 (字段, 883), 页→面 (页面, 807), 版→本 (版本, 1072),
    /// 项→目 (项目, 330), 周→期 (周期, 350), 段→落 (段落, 131),
    /// 克→风/隆 (克服/克隆, 620), 台→账/窗 (台账, 56), 根→因/据,
    /// 章→节 (章节, 33), 张→卡/表. `五台` therefore still canonicalises apart
    /// from `5 台`; that gap is recorded rather than papered over.
    private static let unitSuffixes = [
        "公斤", "千克", "毫升", "厘米", "毫米", "毫秒", "小时", "美元", "公里",
        "年", "元", "米", "岁", "号", "楼", "月", "日", "倍", "个", "人", "次",
        "天", "分", "秒", "点", "份", "吨",
    ]

    /// The same list as a regex alternation. `分` is the one member that needs
    /// a guard: 百分之、百分比、个百分点、百分号 and 百分位 each own that
    /// character, and without the lookahead 百分比 was read as `100分` -- 69
    /// times in this repository's own documents before the guard. The set is
    /// measured, not exhaustive by construction, and 一百分 (100 points) must
    /// stay readable as a number.
    private static let unitAlternation = unitSuffixes
        .map { $0 == "分" ? "分(?![之比点号位])" : $0 }
        .joined(separator: "|")
    private static let largeUnitCharacters = Set("万亿")
    private static let arabicMagnitudes: [Character: Decimal] = [
        "百": 100, "千": 1_000, "万": 10_000, "亿": 100_000_000,
    ]

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
            guard isNumeralRun(number) else { return nil }
            guard let integer = chineseInteger(number) else { return nil }
            return "\(integer)\(suffix)"

        case .arabic:
            // `fold` keeps interior whitespace, so `50 元` and `50元` would
            // still be two different canonical values. The rule shape admits at
            // most one optional space, inside this token, so dropping
            // whitespace here cannot merge two separate tokens.
            return arabicValue(
                String(raw.filter { !$0.isWhitespace })
            )

        case .spokenMagnitude:
            guard isNumeralRun(raw) else { return nil }
            guard let integer = chineseInteger(raw) else { return nil }
            return String(integer)
        }
    }

    /// 万亿 and 亿万 are words, not numerals, and 万亿元 is a unit rather than a
    /// number. Two *large* magnitudes in a row are the one case the positional
    /// algorithm cannot honour: it has already folded the first into `total`, so
    /// the second starts from zero and invents a quantity nobody wrote -- 万亿
    /// became 10000 and 万亿元 became 10000元, which is a trillion. 十万 is fine
    /// and must stay that way: 十 is a small magnitude, and the tens are still
    /// sitting in `section` when 万 scales them.
    private static func isNumeralRun(_ text: String) -> Bool {
        var previousWasLarge = false
        for character in text {
            let isLarge = largeUnitCharacters.contains(character)
            if isLarge && previousWasLarge { return false }
            previousWasLarge = isLarge
        }
        return true
    }

    /// Folds a Chinese magnitude word written after Arabic digits into the number
    /// it belongs to, so `2万元` and `两万元` reach the same canonical form. Text
    /// with no magnitude word is returned folded exactly as before.
    private static func arabicValue(_ raw: String) -> String {
        guard let boundary = raw.firstIndex(where: { !("0"..."9").contains($0) }) else {
            return fold(raw)
        }
        let digits = String(raw[raw.startIndex..<boundary])
        let rest = String(raw[boundary...])
        guard let magnitude = rest.first.flatMap({ arabicMagnitudes[$0] }),
              let number = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX"))
        else {
            return fold(raw)
        }
        return integralString(number * magnitude) + String(rest.dropFirst())
    }

    /// `Decimal` keeps a scale it was never handed: 2 x 10000 has to print
    /// `20000`, not `20000.0`, or one quantity written two ways stops matching.
    private static func integralString(_ value: Decimal) -> String {
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        return rounded == source ? "\(rounded)" : "\(value)"
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
                // A magnitude with no digit in front of it is the number itself:
                // 百 is 100, not zero. Only 十 used to get this, which is why
                // `万元` canonicalised to `0元`. It may only stand in when the run
                // has produced nothing yet -- imputing a 1 in the middle of a run
                // turns 九十百 into 190 and reads a character class as a number.
                if number == 0, section == 0, total == 0 { number = 1 }
                section += number * unit
                number = 0
            } else if let unit = largeUnits[character] {
                // Same rule for 万: in 十万 the tens already sit in `section`.
                if number == 0, section == 0, total == 0 { number = 1 }
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
