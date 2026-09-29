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
        .init(expression: expression(#"百分之[零一二三四五六七八九十百千万点"# + digitClass + #"]+"#), kind: .percentage),
        .init(expression: expression(#"[零〇一二三四五六七八九]{4}年"#), kind: .year),
        // `两` belongs in the leading class for the same reason the server's
        // `_CN_NUM_RE` lists it first: it is the numeral `chineseDigits`
        // already knows. Without it `两点五` matched nothing, and the match
        // that did claim it was `.spokenUnit` reading `点` as a unit -- so a
        // decimal came out as "2 o'clock, five". The trailing class keeps the
        // server's membership: it has 零 but not 两, and 〇 stays out of both.
        // The unit group is the same `unitAlternation` the Arabic rule uses, and
        // deliberately not a second list: `三点五秒` used to canonicalise as
        // `3.5` + `秒` while `3.5秒` was one token, so the same quantity written
        // two ways never matched. All twelve unit shapes probed split, without
        // exception. Giving spoken decimals their own list would rebuild the
        // defect 第 70 条 just fixed one rule earlier.
        .init(expression: expression(#"[零一二两三四五六七八九十百千万"# + digitClass + #"]+点[零一二三四五六七八九"# + digitClass + #"]+\s*(?:"# + unitAlternation + #")?"#), kind: .spokenDecimal),
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
        //
        // Full-width digits and a full-width percent sign are the same number as
        // their half-width spellings. A script drafted with a Chinese IME, or
        // pasted out of a spreadsheet, carries `５０` and `％`; the recogniser
        // transcribes the spoken form in ASCII. `TeleprompterProtectedAtom` has
        // accepted both widths from the start, so the canonicalizer was the
        // only layer still disagreeing -- and it disagreed by cutting the
        // number into single characters, which put it past the numeric
        // fidelity gate entirely rather than merely reading it differently.
        // The `％` matters most: with it unmatched, no percentage rule claims
        // `百分之５０`, the bare-magnitude rule takes the `百`, and 50 percent
        // was read as "100 分" -- the same class of defect as 第 67 条, coming
        // back through the full-width seam.
        //
        // Width is normalised in the *value*, never in the source: matching a
        // pre-folded copy of the text would move every later UTF-16 offset,
        // and the token ranges anchor the follower's scroll position.
        .init(expression: expression(digitClass + #"+(?:\."# + digitClass + #"+)?(?:[万亿千百])?\s*(?:"# + unitAlternation + #"|%|％)?"#), kind: .arabic),
    ]

    /// Half-width and full-width digits, declared once. Every pattern that takes
    /// a digit reads this, so the three numeral rules cannot drift apart on
    /// width the way the two unit lists had drifted on membership.
    private static let digitClass = #"[0-9０-９]"#

    /// The one Chinese-digit table in the app. The aligner used to keep a
    /// second copy and it had already drifted: the copy there was missing
    /// `两`, so a transcript saying `2` never matched a script saying
    /// `这里是两` — the one numeral the table silently dropped. Bare digits
    /// do reach the aligner (`两难`, `第三季度` both survive canonicalisation),
    /// so the second table was not harmless duplication.
    static let chineseDigits: [Character: String] = [
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
    /// Module-internal rather than private: the fidelity gate's invariant test
    /// reads this list to prove every unit here is also a protected literal.
    /// Adding a unit here without teaching `TeleprompterProtectedAtom` about it
    /// would let a rewrite change that unit silently.
    ///
    /// `点` is deliberately **not** here, matching the server's `_UNIT_RE`.
    /// Of the 109 `X点` occurrences in this repository's documents, the
    /// overwhelming majority are ordinary words — `这一点`, `短一点`,
    /// `第二点`, `同一点` — and reading those as quantities invents numbers the
    /// author never wrote, straight into the numeric fingerprint. What the
    /// choice costs is recorded rather than glossed: a bare clock hour
    /// (`三点`, `十点`) stops being a number. Keeping `点` would not have
    /// recovered a time reading either — `七点半` canonicalised as `7点` + `半`,
    /// which is a quantity, not a clock. The same misreading is registered
    /// against the model in #95's certification (`synth-zh-number-10`), and the
    /// server reached this decision earlier; the reasoning is in §2.25 of the
    /// stage report.
    ///
    /// `点` still serves as the decimal separator inside `.spokenDecimal` and
    /// `.percentage`, which do not read this list. `三点五` is still `3.5`.
    static let unitSuffixes = [
        "公斤", "千克", "毫升", "厘米", "毫米", "毫秒", "小时", "美元", "公里",
        "年", "元", "米", "岁", "号", "楼", "月", "日", "倍", "个", "人", "次",
        "天", "分", "秒", "份", "吨",
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
            // The rule may carry a unit suffix, and `点` is in the unit list --
            // so the suffix has to come off before the decimal point is looked
            // for, or `三点五点` would find the wrong one: the trailing `点` is
            // the unit and the earlier one is the decimal point. Requiring a
            // `点` to survive that step rejects shapes like `三点四点` being
            // read as `3.4` instead of `3.40`.
            //
            // The space is layout, exactly as in `.arabic`: the rule admits at
            // most one optional space inside this token, so dropping it here
            // cannot merge two separate tokens.
            let collapsed = String(raw.filter { !$0.isWhitespace })
            var body = collapsed
            var suffix = ""
            if let unit = unitSuffixes.first(where: { collapsed.hasSuffix($0) }),
               collapsed.count > unit.count {
                body = String(collapsed.dropLast(unit.count))
                suffix = unit
            }
            guard body.contains("点"),
                  let point = body.firstIndex(of: "点"),
                  let integer = chineseInteger(String(body[..<point])) else { return nil }
            let decimal = asciiDigits(String(body[body.index(after: point)...]))
            guard !decimal.isEmpty else { return nil }
            return "\(integer).\(decimal)\(suffix)"

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
        guard let boundary = raw.firstIndex(where: { asciiDigit($0) == nil }) else {
            return fold(raw)
        }
        // `Decimal(string:)` reads ASCII only, so the width has to come off here
        // rather than being left to `fold` on the fallback path.
        let digits = String(raw[raw.startIndex..<boundary].map { asciiDigit($0)! })
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
        if text.allSatisfy({ asciiDigit($0) != nil }) {
            return Int(String(text.map { asciiDigit($0)! }))
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
        text.map { chineseDigits[$0] ?? asciiDigit($0).map(String.init) ?? String($0) }.joined()
    }

    /// The ASCII digit a character denotes, in either width. Full-width digits
    /// are U+FF10–FF19, ten codepoints above ASCII, so the offset is exact
    /// rather than a table.
    private static func asciiDigit(_ character: Character) -> Character? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1
        else { return nil }
        switch scalar.value {
        case 0x30...0x39:
            return character
        case 0xFF10...0xFF19:
            return Character(UnicodeScalar(0x30 + (scalar.value - 0xFF10))!)
        default:
            return nil
        }
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
