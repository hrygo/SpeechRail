import XCTest
import Testing

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class TeleprompterNormalizerTests: XCTestCase {
    func testNormalizesPunctuationWhitespaceCaseAndFillerWords() {
        let tokens = TeleprompterNormalizer.tokens("  嗯，你好，Hello  WORLD！  然后 继续。 ")

        XCTAssertEqual(tokens, ["你", "好", "hello", "world", "然", "后", "继", "续"])
    }

    func testKeepsLatinWordsTogetherAndChineseCharactersOrder() {
        let tokens = TeleprompterNormalizer.tokens("AI 直播 MacBook Pro")

        XCTAssertEqual(tokens, ["ai", "直", "播", "macbook", "pro"])
    }

    func testDeterministicSegmenterPreservesSourceRanges() throws {
        let source = "第一段内容。\n\n第二段内容。"

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        XCTAssertEqual(segments.map(\.text), ["第一段内容。", "第二段内容。"])
        let firstStart = String.Index(
            utf16Offset: segments[0].sourceRange.start,
            in: source
        )
        let firstEnd = String.Index(
            utf16Offset: segments[0].sourceRange.end,
            in: source
        )
        let firstText = String(source[firstStart..<firstEnd])
        XCTAssertEqual(firstText, "第一段内容。")
    }

    func testEmptySourceIsRejected() {
        XCTAssertThrowsError(try TeleprompterSegmenter.segment(sourceText: "  \n ")) { error in
            XCTAssertEqual(error as? TeleprompterTextError, .emptySource)
        }
    }

    func testSegmenterDoesNotSplitVersionsURLsOrAbbreviations() throws {
        let source = "版本 2.0 已发布。请访问 https://example.com。由 Dr. Wang 介绍。"

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        XCTAssertEqual(
            segments.map(\.text),
            ["版本 2.0 已发布。", "请访问 https://example.com。", "由 Dr. Wang 介绍。"]
        )
    }

    func testSentenceClosingQuoteStaysWithTheSentence() throws {
        let source = "他说：‘现在开始。’然后继续。"

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        XCTAssertEqual(segments.map(\.text), ["他说：‘现在开始。’", "然后继续。"])
    }

    func testLongLatinIdentifierIsNotSplitAtTheSoftTarget() throws {
        // 61 characters, the previous fixture, produced one 60-character
        // segment plus a stranded "。" -- the same output with and without the
        // word-internal protection, so the assertion never reached the code it
        // names. This one puts the identifier well past the soft target.
        let source = "请检查 super_long_identifier_that_should_stay_together_then_keep_going_继续说明。"

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        let identifier = "super_long_identifier_that_should_stay_together_then_keep_going"
        XCTAssertGreaterThan(source.count, 70)
        XCTAssertEqual(segments.filter { $0.text.contains(identifier) }.count, 1)
        XCTAssertTrue(segments.map(\.text).joined().contains(identifier))
    }

    func testLongChineseSentenceIsSplitInsteadOfKeptWhole() throws {
        let clause = "首先我们检查相机的曝光设置然后确认白平衡"
        let source = String(repeating: clause + "，", count: 5)

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        XCTAssertGreaterThan(
            segments.count, 1,
            "A \(source.count)-character Chinese clause chain must not stay in one reading unit"
        )
        XCTAssertTrue(
            segments.allSatisfy { $0.text.count <= 60 },
            "Every unit must respect the soft target, got \(segments.map(\.text.count))"
        )
    }

    func testChineseSentenceWithoutPunctuationFallsBackToTheHardTarget() throws {
        let source = String(repeating: "一", count: 200)

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(
            segments.allSatisfy { $0.text.count <= 60 },
            "With no boundary to prefer, the 60-character cap must still apply"
        )
    }

    func testChineseClausesAreCutJustAfterAPunctuation() throws {
        let source = String(repeating: "甲乙丙丁戊己庚辛壬癸，", count: 4)

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        XCTAssertTrue(
            segments.allSatisfy { $0.text.hasSuffix("，") },
            "Each cut should land just after a comma, got \(segments.map(\.text))"
        )
    }

    func testLongLatinIdentifierInsideChineseTextStillSurvivesTheSoftTarget() throws {
        let identifier = "super_long_identifier_that_should_stay_together_then_keep_going"
        let source = identifier + String(repeating: "内容", count: 40) + "。"

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        let identifierSegments = segments.filter { $0.text.contains(identifier) }
        XCTAssertEqual(identifierSegments.count, 1, "The identifier itself must stay whole")
        XCTAssertEqual(
            identifierSegments.first?.text, identifier,
            "The unit holding the identifier must end with it, not run on into the Chinese after it"
        )
        XCTAssertTrue(
            segments.dropFirst().allSatisfy { $0.text.count <= 60 },
            "Only the identifier unit may exceed the soft target, got \(segments.map(\.text.count))"
        )
    }

    func testSentenceEndingJustOverTheSoftTargetDoesNotStrandItsPunctuation() throws {
        // Every sentence longer than the soft target used to be cut at exactly
        // the target, which left the sentence-final full stop as a segment of
        // its own -- a stage line holding nothing but "。", once per over-long
        // sentence. The existing long-identifier fixture is 61 characters, so
        // it produced exactly that and asserted only that the identifier
        // survived, walking straight past it.
        for length in [61, 62, 63, 70, 121] {
            let source = String(repeating: "字", count: length - 1) + "。"

            let segments = try TeleprompterSegmenter.segment(sourceText: source)

            XCTAssertFalse(
                segments.contains { $0.text.allSatisfy { !$0.isLetter && !$0.isNumber } },
                "a punctuation-only segment survived for a \(length)-character sentence"
            )
            XCTAssertTrue(segments.last?.text.hasSuffix("。") == true)
        }
    }

    func testALongSentenceIsCutAtItsLastNaturalBoundaryRatherThanMidWord() throws {
        // Two commas, so "last" and "first" are different answers. Cutting at
        // the soft target instead leaves the reader on a line that stops in the
        // middle of a clause.
        let source = String(repeating: "字", count: 20) + "，"
            + String(repeating: "字", count: 24) + "，"
            + String(repeating: "字", count: 30) + "。"

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text.count, 46)
        XCTAssertTrue(segments[0].text.hasSuffix("，"))
    }

    func testANaturalBoundaryTooEarlyToReachHalfTheTargetIsNotUsed() throws {
        // The only comma sits at 10, well short of the half-target. Honouring it
        // would produce an 11-character leading segment followed by a page of
        // very short ones, so the boundary is declined. The invariant is on
        // every segment but the last: the remainder of a sentence is allowed to
        // be short, a leading one is not.
        let source = String(repeating: "字", count: 10) + "，"
            + String(repeating: "字", count: 80) + "。"
        XCTAssertGreaterThan(source.count, 60)

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        for segment in segments.dropLast() {
            XCTAssertGreaterThanOrEqual(segment.text.count, 30)
        }
    }

    func testParagraphEndGetsALongPauseAndSentenceEndOnlyAMediumOne() throws {
        // `pauseHint` is what the stage renders as 「长停顿」/「句间停顿」, so the
        // paragraph split is user-visible and not merely structural.
        let source = "第一段第一句。第一段第二句。\n第二段第一句。"

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        XCTAssertEqual(
            segments.map(\.pauseHint),
            [.medium, .long, .long]
        )
    }

    func testTrailingSpacesBeforeALineBreakChangeNothing() throws {
        // Trailing spaces used to survive the paragraph range, pushing the
        // paragraph's real end past its last sentence. The end of a paragraph
        // is what earns 「长停顿」, so every space-padded paragraph had its
        // closing sentence demoted to 「句间停顿」 -- the padding, not the
        // writing, changed what the reader is told.
        let plain = try TeleprompterSegmenter.segment(sourceText: "第一段第一句。\n第二段第一句。")
        let padded = try TeleprompterSegmenter.segment(sourceText: "第一段第一句。   \n第二段第一句。")

        XCTAssertEqual(padded.map(\.text), plain.map(\.text))
        XCTAssertEqual(padded.map(\.pauseHint), plain.map(\.pauseHint))
        XCTAssertEqual(padded.map(\.pauseHint), [.long, .long])
    }
}


struct TeleprompterCanonicalizerTests {

    @Test func aSpaceBetweenDigitsAndAUnitIsLayoutNotContent() {
        // 98% of the digit + CJK unit occurrences in this repository's own
        // documents carry a space (6650 against 138 without). A script drafted
        // from those documents therefore has a space at nearly every number,
        // while the recogniser transcribes the spoken form without one -- and
        // the two sides landed on different token streams, so the follower
        // never matched at that number. The fidelity gate already treats the
        // two as equivalent (`gateAcceptsWhitespaceOnlyChangesAroundAUnit`);
        // the canonicalizer did not.
        for (spaced, tight) in [
            ("50 元", "五十元"),
            ("3 米", "三米"),
            ("10 点", "十点"),
            ("30 秒", "三十秒"),
            ("2 小时", "两小时"),
            ("2026 年", "二〇二六年"),
            ("5 份", "五份"),
        ] {
            #expect(
                TeleprompterCanonicalizer.units(spaced).map(\.value)
                    == TeleprompterCanonicalizer.units(tight).map(\.value),
                "空白导致不匹配: \(spaced) vs \(tight)"
            )
        }
    }

    @Test func bothNumeralRulesReadTheSameUnitList() {
        // The Arabic and the spoken rule used to carry two separately kept
        // lists, and they had already drifted: the Arabic one had 年 and the
        // spoken one had 台/条/项/字, so `三年` matched nothing while `5 台` and
        // `五台` disagreed. One list, used by both.
        #expect(
            TeleprompterCanonicalizer.units("3 年").map(\.value)
                == TeleprompterCanonicalizer.units("三年").map(\.value)
        )
        #expect(
            TeleprompterCanonicalizer.units("5 份").map(\.value)
                == TeleprompterCanonicalizer.units("五份").map(\.value)
        )
    }

    @Test func unitsThatWouldSwallowTheNextWordAreLeftOut() {
        // Measured on the corpus: every one of these is followed far more often
        // by a character that forms a different word than by a boundary, so
        // binding it would rewrite the neighbouring word. 条→件 (条件, 500),
        // 字→段 (字段, 883), 页→面 (页面, 807), 版→本 (版本, 1072),
        // 项→目 (项目, 330), 周→期 (周期, 350), 段→落 (段落, 131),
        // 克→风/隆 (克服/克隆, 620), 台→账/窗 (台账, 56), 根→因/据,
        // 章→节 (章节, 33), 张→卡/表. `五台` therefore still canonicalises
        // apart from `5 台`; that gap is measured and recorded, not an
        // oversight, and it is the reason the fix was a shared list rather than
        // a longer one.
        // Asserting only that the two sides *differ* is not enough: adding 台
        // to the list keeps them different but flips the failure into a worse
        // one, where the Arabic side binds the unit and the spoken side does
        // not. Pin the exact token streams instead, so "left out" means both
        // sides stay unbound.
        #expect(TeleprompterCanonicalizer.units("5 台").map(\.value) == ["5", "台"])
        #expect(TeleprompterCanonicalizer.units("五台").map(\.value) == ["五", "台"])
        #expect(TeleprompterCanonicalizer.units("3 项").map(\.value) == ["3", "项"])
        #expect(TeleprompterCanonicalizer.units("4 页").map(\.value) == ["4", "页"])
    }

    @Test func aLongerUnitWinsOverTheCharacterItEndsWith() {
        // `unitSuffixes` is consumed by a `hasSuffix` lookup that takes the
        // first hit, so the order is load bearing: with 米 ahead of 厘米, `五厘米`
        // would match 米, leave `五厘` as the number, fail the numeral-run check
        // and silently stop being a number at all.
        #expect(TeleprompterCanonicalizer.units("五厘米").map(\.value) == ["5厘米"])
        #expect(TeleprompterCanonicalizer.units("5厘米").map(\.value) == ["5厘米"])
        #expect(TeleprompterCanonicalizer.units("三毫升").map(\.value) == ["3毫升"])
        #expect(TeleprompterCanonicalizer.units("2 毫秒").map(\.value) == ["2毫秒"])
    }

    @Test func aUnitOnItsOwnIsStillSeparateFromTheNumber() {
        // Reverse control: the optional space belongs to the numeric token, so
        // it must not let a number swallow a following CJK character that is
        // not one of the shared units.
        #expect(
            TeleprompterCanonicalizer.units("3 米").map(\.value).count == 1
        )
        #expect(
            TeleprompterCanonicalizer.units("3 斤").map(\.value).count == 2
        )
    }

    @Test func mirrorsServerITNEquivalences() {
        let pairs = [
            ("二零二六年", "2026年"),
            ("二〇二六年", "2026年"),
            ("百分之五十", "50%"),
            ("百分之九十九点九", "99.9%"),
            ("三点一四一五九", "3.14159"),
            ("零点八五度", "0.85度"),
            ("一百二十五元", "125元"),
            ("五百美元", "500美元"),
            ("三万米", "30000米"),
            ("二十八岁", "28岁"),
            ("十个人", "10个人"),
        ]

        for (spoken, written) in pairs {
            #expect(
                TeleprompterCanonicalizer.values(spoken)
                    == TeleprompterCanonicalizer.values(written),
                "Expected equivalent canonical units for \(spoken) and \(written)"
            )
        }
    }

    @Test func preservesUTF16SourceRangesAcrossSupplementaryCharactersAndFillers() {
        let units = TeleprompterCanonicalizer.units("😀嗯，今天 number")
        let today = units.first { $0.value == "今" }
        let number = units.first { $0.value == "number" }

        #expect(today?.range == TeleprompterSourceRange(start: 4, end: 5))
        #expect(number?.range == TeleprompterSourceRange(start: 7, end: 13))
        #expect(!units.contains { $0.value == "嗯" })
        #expect(units.allSatisfy { $0.range.end > $0.range.start })
    }

    @Test func leavesDistinctWordsDistinct() {
        #expect(
            TeleprompterCanonicalizer.values("相机参数")
                != TeleprompterCanonicalizer.values("相机设置")
        )
    }

    /// A Chinese numeral only reached a rule when a unit suffix followed it, so
    /// `三万` produced no numeric unit at all while `3万` produced a bare `3` and
    /// dropped the magnitude. Two failures came out of the same gap: the same
    /// quantity written two ways compared unequal, and an alias could drop the
    /// magnitude outright (`三万` → `三千`) because the gate had nothing to
    /// compare and two empty fingerprints look equal.
    @Test func recognisesMagnitudeCarriedByTheNumeralItself() {
        for (spoken, written) in [
            ("三万", "30000"),
            ("五千", "5000"),
            ("两亿", "200000000"),
            ("十万", "100000"),
            ("五十", "50"),
            ("一百二十", "120"),
            ("三万零五百", "30500"),
        ] {
            #expect(
                TeleprompterCanonicalizer.values(spoken)
                    == TeleprompterCanonicalizer.values(written),
                "\(spoken) 与 \(written) 是同一个数，归一结果必须相同"
            )
        }
    }

    /// `2万元` used to be split into `2` plus a leftover `万元` that the spoken
    /// rule then parsed on its own, and a bare magnitude word evaluates to zero —
    /// so the canonical form of "两万元" claimed the text said `0元`.
    @Test func arabicMagnitudeWordsFoldIntoTheNumber() {
        #expect(TeleprompterCanonicalizer.values("2万元") == ["20000元"])
        #expect(TeleprompterCanonicalizer.values("20万元") == ["200000元"])
        #expect(TeleprompterCanonicalizer.values("1亿元") == ["100000000元"])
        #expect(TeleprompterCanonicalizer.values("3万") == ["30000"])
        #expect(TeleprompterCanonicalizer.values("2元") == ["2元"], "无量级词时行为不变")
        #expect(TeleprompterCanonicalizer.values("50%") == ["50%"], "无量级词时行为不变")
        #expect(TeleprompterCanonicalizer.values("2026年") == ["2026年"], "无量级词时行为不变")
    }

    /// 百分之、百分比、个百分点、百分号 and 百分位 each own the 分 character.
    /// When no digits follow 百分之 the percentage rule never fires, and these
    /// words were read as "100分" -- 69 times in this repository's own documents
    /// before the guard. 四十分钟 is the other side of the same coin and must
    /// stay readable, so the guard cannot simply be "分 is never a unit here".
    @Test func wordsThatOwnTheFractionCharacterAreNotReadAsQuantities() {
        for word in ["百分比", "百分点", "百分号", "百分位"] {
            #expect(
                !TeleprompterCanonicalizer.values(word).contains("100分"),
                "\(word) 是一个词，不是 100 分"
            )
        }
        #expect(TeleprompterCanonicalizer.values("四十分钟") == ["40分", "钟"])
        #expect(TeleprompterCanonicalizer.values("一百分") == ["100分"], "一百分确实是 100 分")
    }

    /// A bare magnitude stands for its own power — 万 alone is 10000, which is
    /// what makes 「融资额以亿元为单位」 readable at all. The same two large
    /// magnitudes in a row are a word, not a numeral: 万亿 is a word and 万亿元
    /// is a unit, and the positional algorithm has already folded the first into
    /// `total` by the time it reaches the second.
    @Test func aBareMagnitudeIsItsOwnPowerAndTwoInARowAreAWord() {
        #expect(TeleprompterCanonicalizer.values("万元") == ["10000元"])
        #expect(TeleprompterCanonicalizer.values("亿元") == ["100000000元"])
        #expect(
            TeleprompterAcceptedReading.numericFingerprint(of: "融资额以亿元为单位")
                == ["100000000元"]
        )
        #expect(
            TeleprompterAcceptedReading.numericFingerprint(of: "万亿").isEmpty,
            "万亿是一个词，不该被读成任何数量"
        )
        #expect(!TeleprompterCanonicalizer.values("万亿元").contains("10000元"),
                "万亿元是单位而不是数字，不能读成 10000 元")
        #expect(TeleprompterCanonicalizer.values("十万") == ["100000"], "小量级相邻不受影响")
    }

    /// 验收标准第 1 条要求数值变化不得静默通过，而全角数字是从旁边绕过去的：
    /// `.arabic` 只写 `[0-9]`，`５０` 匹配不上就被 `indexedTokens` 切成 5 / 0 两个
    /// 单字，数值指纹里**一个数都没有**——提词器不会误跳，但数值保真闸也再也
    /// 看不见它。`TeleprompterProtectedAtom` 从一开始就同时收 `0-9０-９` 与
    /// `%|％`，所以这不是排版偏好问题，是同一层里两处规则对「什么算一个数字」
    /// 已经不一致。
    ///
    /// 语料上本仓库只有 22 个全角数字、文档里 0 处，所以量不大；`百分之５０`
    /// 那一条才是要紧的：百分号一不匹配，规则表里就没有百分比规则接住它，
    /// 裸量级规则接手把 `百` 读成 100，于是「百分之五十」被读成「100 分」——
    /// 和第 67 条修掉的量级缺陷是同一类，只是从全角这条缝里又钻进来一次。
    @Test func fullWidthDigitsAndPercentSignAreTheSameNumber() {
        for (full, half) in [
            ("延迟５０毫秒。", "延迟50毫秒。"),
            ("准确率 99％。", "准确率 99%。"),
            ("准确率５０％。", "准确率50%。"),
            // 配对的两侧只差宽度。`三点１４秒` 与 `3.14秒` 不能拿来配对：
            // 口语小数规则不带单位组，那条差异半角下同样存在，是另一处缺陷。
            ("三点１４秒。", "三点14秒。"),
            ("百分之５０。", "百分之50%。"),
            ("２０２６年。", "2026年。"),
            ("５万元。", "5万元。"),
        ] {
            #expect(
                TeleprompterCanonicalizer.units(full).map(\.value)
                    == TeleprompterCanonicalizer.units(half).map(\.value),
                "全角与半角不是同一个数: \(full) vs \(half)"
            )
        }

        #expect(
            TeleprompterAcceptedReading.numericFingerprint(of: "准确率５０％") == ["50%"],
            "全角数字必须仍然进得了数值闸"
        )
        #expect(
            TeleprompterAcceptedReading.numericFingerprint(of: "百分之５０。") == ["50%"],
            "百分之五十不能被读成 100 分"
        )
    }

    /// 值可以折，区间不可以。`Script.tokens(forSegmentAt:)` 把每个 token 锚在
    /// 显示区间上，对齐器返回的位置直接驱动舞台滚动，所以 canonical 值的长度
    /// 永远不能拿去当源区间的长度——两个方向都会错：全角折半角时值变短
    /// （`５０毫秒` 值 4 字、源 4 字，恰好相同，所以这一条曾侥幸通过变异），
    /// 量级词折进数字时值变长（`2万元` → `20000元`，6 字对 3 字，区间会越过
    /// 数字本身锚到后面的文字上）。两条都由变异 M8 暴露：把区间长度改成
    /// `value.count`，314 条既有测试没有一条会红。
    @Test func canonicalValuesFoldButRangesStayOnTheSourceText() {
        let units = TeleprompterCanonicalizer.units("延迟５０毫秒。")
        let numeric = units.filter(\.isNumeric)
        #expect(numeric.count == 1, "全角数字仍是一个数值 token，而不是 5 和 0")
        #expect(numeric.first?.value == "50毫秒")
        #expect(numeric.first?.range.start == 2, "区间指向原稿里的 ５")
        #expect(numeric.first?.range.end == 6, "区间在 秒 之后结束")

        // 归一也不能把两处数字并成一个：句号仍然断得开。
        let separate = TeleprompterCanonicalizer.units("５０毫秒。５秒")
        #expect(separate.filter(\.isNumeric).map(\.value) == ["50毫秒", "5秒"])

        // 量级词折进数字后值比源串长，区间仍按源串算。
        let magnitude = TeleprompterCanonicalizer.units("延迟2万元。").filter(\.isNumeric)
        #expect(magnitude.first?.value == "20000元")
        #expect(magnitude.first?.range.start == 2)
        #expect(magnitude.first?.range.end == 5, "`2万元` 在原稿里只占 3 个 UTF-16 单位")
    }

    /// `两` 是 `chineseDigits` 认得的数词，服务端 `_CN_NUM_RE` 也把它列在首位，
    /// 唯独口语小数的点前字符类漏了它。规则匹配不上就落到 `.spokenUnit`——而
    /// `点` 在单位表里，于是 `两点五` 被读成「2 点」加一个孤零零的「五」，也就是
    /// 「两点钟」。与第 67 条同形：看起来是完备规则，实际是枚举式的，而漏掉的那
    /// 一个恰好让整条规则失效、交给另一条规则按错的读法接手。
    @Test func spokenDecimalsAcceptTwoTheSameWayTheRestOfTheNumeralRulesDo() {
        for (spoken, written) in [
            ("两点五", "2.5"),
            ("二点五", "2.5"),
            ("一点五", "1.5"),
        ] {
            #expect(
                TeleprompterCanonicalizer.values(spoken).joined(separator: "|") == written,
                "\(spoken) 应读成 \(written)，实际 \(TeleprompterCanonicalizer.values(spoken))"
            )
        }
        // 反向对照：点前点后的数词都还认，`点` 作为单位表成员的判断本条不碰。
        #expect(TeleprompterCanonicalizer.values("三点五") == ["3.5"])
        #expect(TeleprompterCanonicalizer.values("零点八五") == ["0.85"])
        // 口语小数不带单位组是第 73 条修掉的缺陷；这里留一条把它钉住，
        // 免得将来有人为了别的目的把单位组拿掉。
        #expect(TeleprompterCanonicalizer.values("两点五秒") == ["2.5秒"])

        // 点前点后的成员是**量出来的边界**，不是完备规则：语料上点前用 `〇` 0 处、
        // 点后用 `〇` 0 处、点后用 `两` 仅 1 处且是假阳性（`落点两块`）。当前成员
        // 点前类里的 `两` 是本仓比服务端 `_DECIMAL_RE` 多出来的一处（服务端
        // 点前类没有 `两`，所以 `两点五` 在服务端原样不动）—— 理由见 §2.30。
        // 变异 N2（把 `两` 也放进点后类）与
        // N3（把 `〇` 放进点前类）在 1170 条小数矩阵上各改变 72 条行为，
        // 两者都能让本套件全绿——所以边界必须写死，否则它是意外而不是决定。
        #expect(TeleprompterCanonicalizer.values("〇点五") == ["〇", "点", "五"],
                "点前不认 `〇`，与服务端一致")
        // `点` 移出单位表后这条仍然咬得住：若 `两` 进了点后类，它会变成 `3.2`。
        #expect(TeleprompterCanonicalizer.values("三点两") == ["三", "点", "两"],
                "点后不认 `两`：语料上唯一一处是假阳性")
    }

    /// `点` 同时是十进制点、钟点和普通词，本仓语料 109 处 `X点` 里压倒性是
    /// 普通词（`这一点`／`短一点`／`第二点`／`同一点`）。留着它就把这些词读成
    /// 数量——**凭空造出作者没写下的数**，还会进数值指纹。
    ///
    /// 服务端 `itn.py` 早已把 `点` 整个排除出单位表，理由写在它自己的注释里：
    /// 「丢掉一个单位只是少转，保留它会改坏句子」。两侧对同一个字符的判断相反，
    /// 这一条把 Swift 侧对齐到服务端。
    ///
    /// **代价是明确写下来的**，不是「顺手修好」：裸钟点 `三点`／`十点` 从此
    /// 不再是数字。留着它也换不来时间读法——`七点半` 得到的是 `7点`+`半`，
    /// 仍然不是钟点。
    @Test func dianIsNotAUnitSoOrdinaryWordsAreNotReadAsQuantities() {
        // 主体：普通词不再被读成数量。
        for word in ["这一点", "短一点", "有一点", "同一点", "新词一点"] {
            #expect(
                !TeleprompterCanonicalizer.values(word).contains("1点"),
                "\(word) 是一个词，不是「1 点」"
            )
            #expect(
                TeleprompterAcceptedReading.numericFingerprint(of: word).isEmpty,
                "\(word) 不该产生任何数值"
            )
        }
        #expect(TeleprompterCanonicalizer.values("第二点") == ["第", "二", "点"])
        // `7点40分` 仍被读成小数 `7.40分`——但**这不是本条能修的**：错读来自
        // `.spokenDecimal` 把 `点` 当十进制点，与单位表无关；服务端
        // `apply_light_itn("7点40分")` 同样返回 `7.40分`，#95 认证里模型 ASR 也
        // 独立犯过同一个错（`synth-zh-number-10`）。两侧一致，且这是已登记的
        // 共享边界，不在缺陷范围内擅自改。钉在这里是为了让下一个人知道
        // 「移出 `点`」没有、也不应该顺带修掉它。
        #expect(TeleprompterCanonicalizer.values("7点40分") == ["7.40分"])

        // 保留：十进制点由 `.spokenDecimal` 自己处理，与单位表无关。
        #expect(TeleprompterCanonicalizer.values("三点五") == ["3.5"])
        #expect(TeleprompterCanonicalizer.values("两点五") == ["2.5"])
        #expect(TeleprompterCanonicalizer.values("百分之三点五") == ["3.5%"])
        #expect(TeleprompterCanonicalizer.values("3.5") == ["3.5"])

        // 写下来的代价：裸钟点不再是数字。两侧一致，只是都不再当数字。
        #expect(TeleprompterCanonicalizer.values("三点") == ["三", "点"])
        // `十` 是量级，所以 `十点` 仍产生 10——服务端则整词不动。这一处两侧
        // 仍不一致，且方向是 Swift 更接近量词本义，记录而不抹平。
        #expect(TeleprompterCanonicalizer.values("十点") == ["10", "点"])
        #expect(TeleprompterCanonicalizer.values("两点") == ["两", "点"])
        #expect(TeleprompterCanonicalizer.values("七点半") == ["七", "点", "半"])
        #expect(
            TeleprompterCanonicalizer.units("10 点").map(\.value)
                == TeleprompterCanonicalizer.units("十点").map(\.value),
            "两侧仍然一致，只是不再当数字"
        )
    }

    /// `.arabic` 带单位组、`.spokenDecimal` 不带，于是同一个数量写成阿拉伯数字
    /// 是一个 token、写成中文口语数字是两个——**与第 70 条那两张分叉的单位表同一
    /// 形状，只是这次分叉的是「规则带不带单位组」而不是「表里有哪些成员」**。
    /// 探针上 12 个单位形状**无一例外**全部拆开。
    ///
    /// 修法不是给口语小数单配一张表，是复用第 70 条已经合成的那一张
    /// `unitAlternation`——**再配一张就是把这个缺陷重新造一遍**。
    @Test func spokenDecimalsCarryTheSameUnitSuffixesArabicOnesDo() {
        for (spoken, written) in [
            ("三点五秒", "3.5秒"),
            ("三点一四秒", "3.14秒"),
            ("零点八五秒", "0.85秒"),
            ("十点五秒", "10.5秒"),
            ("九点九分", "9.9分"),
            ("三点五 元", "3.5元"),
            ("三点五个月", "3.5个|月"),
            ("三点五个人", "3.5个|人"),
        ] {
            #expect(
                TeleprompterCanonicalizer.values(spoken).joined(separator: "|") == written,
                "\(spoken) 应读成 \(written)，实际 \(TeleprompterCanonicalizer.values(spoken))"
            )
        }
        // 量级词仍然接不上：`三点五万元` 的 `万` 不在单位表里（`万` 由 .arabic 的
        // 量级分支处理），与 `五台`／`5 台` 属于同一族已记录缺口，本条不碰。
        #expect(TeleprompterCanonicalizer.values("三点五万元") == ["3.5", "10000元"])
        // 不带单位的小数不受影响。
        #expect(TeleprompterCanonicalizer.values("三点五") == ["3.5"])
        #expect(TeleprompterCanonicalizer.values("两点五。") == ["2.5"])
    }
}
