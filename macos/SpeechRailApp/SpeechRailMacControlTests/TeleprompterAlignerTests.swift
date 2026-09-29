import XCTest
import Testing

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

struct TeleprompterPositionTests {
    private func script() throws -> [TeleprompterSegment] {
        try TeleprompterSegmenter.segment(sourceText: "欢迎来到今天的直播。今天我们介绍相机设置。最后演示照片导出。")
    }

    @Test func bodyAloneMatchesWithProductionDefaults() throws {
        let segments = try script()
        let result = TeleprompterAligner().locate(
            transcript: "今天我们介绍相机设置", segments: segments,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )
        #expect(result.position?.segmentIndex == 1)
    }

    @Test func uniqueExactContinuationReportsItsStartAndAnchorEvidence() throws {
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "开场。今天我们介绍相机设置。下一段。"
        )
        let result = TeleprompterAligner().locate(
            transcript: "今天我们介绍相机设置",
            segments: segments,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )
        #expect(result.position?.segmentIndex == 1)
        #expect(result.startPosition?.segmentIndex == 1)
        #expect(result.isUniqueExactContinuation)
        #expect(result.isUniqueNearAnchor)
    }

    @Test func tracksInsideSentenceAndAcrossSegments() throws {
        let segments = try script()
        let aligner = TeleprompterAligner()
        let first = aligner.locate(transcript: "欢迎来到", segments: segments,
                                   anchor: .init(segmentIndex: 0, utf16Offset: 0))
        #expect(first.position?.utf16Offset == 4)
        let last = aligner.locate(transcript: "今天我们介绍相机设置最后演示照片导出", segments: segments,
                                  anchor: .init(segmentIndex: 0, utf16Offset: 0))
        #expect(last.position?.segmentIndex == 2)
    }

    @Test func localRepeatCanReturnToPreviousSentence() throws {
        let result = TeleprompterAligner().locate(
            transcript: "今天我们介绍相机设置", segments: try script(),
            anchor: .init(segmentIndex: 2, utf16Offset: 4))
        #expect(result.position?.segmentIndex == 1)
    }

    @Test func aCandidateBelowTheConfidenceFloorIsNotOfferedAtAll() throws {
        // 三个 token 里错一个，置信度是 1 - 1/3 ≈ 0.667，落在对齐器 0.72 的
        // 门槛之下，因此**连候选都不该出现**。此前没有任何用例落在 (0.5, 0.72)
        // 这一档——门槛从 0.72 降到 0.5 时全量 716 项无人变红。
        let segments = try TeleprompterSegmenter.segment(sourceText: "春眠晓")
        let result = TeleprompterAligner().locate(
            transcript: "春眠觉", segments: segments,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )
        #expect(result.position == nil)
        #expect(result.confidence == 0)
        #expect(result.matchedCount == 0)
    }

    @Test func aShortExactContinuationIsNotContinuityEvidence() throws {
        // `isUniqueExactContinuation` 的匹配数下限是 8。这条用例给出的是一个
        // 置信 1.0、跨过锚点、长度 6 的精确续接——它**不**算续接证据，只算
        // 锚点附近的普通匹配。下限从 8 降到 3 时这一条会翻红。
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "开场。今天我们介绍相机设置。下一段。"
        )
        let result = TeleprompterAligner().locate(
            transcript: "今天我们介绍", segments: segments,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )
        #expect(result.confidence == 1.0)
        #expect(result.matchedCount == 6)
        #expect(result.isUniqueNearAnchor)
        #expect(
            !result.isUniqueExactContinuation,
            "6 个 token 的精确续接不构成跨锚点的续接证据"
        )
    }

    // MARK: - 裸中文数字（第 82 条）

    @Test func aBareChineseNumeralMatchesItsArabicForm() throws {
        // 归一化只把「数字 + 已登记单位」转成阿拉伯数字，裸数字会原样留下来：
        // `第三季度` → ["第","三","季","度"]，`这里是两` → ["这","里","是","两"]。
        // 它们与阿拉伯数字等价靠的是对齐器自己那张数字表——而那张表此前没有任何
        // 断言：把「七」映成 8 时全量 713 项无人变红。
        let segments = try TeleprompterSegmenter.segment(sourceText: "这里是七成")
        let result = TeleprompterAligner().locate(
            transcript: "这里是7成", segments: segments,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )
        // 断言的是**精确匹配**：conf 1.0 表示五个 token 全部对上。若「七」不再
        // 等价于 7，这里会掉到 0.8。
        #expect(result.confidence == 1.0)
        #expect(result.matchedCount == 5)
    }

    @Test func aBareLiangMatchesTwo() throws {
        // `两` 是这张表此前唯一漏掉的字。表一多映射一个数字，「两」就会被读成别的
        // 数，或者干脆与 2 不再等价——而「两难」「这里是两」在真实口语里并不罕见。
        // 这条与上一条同源：两处各维护一张表，已经分叉（第 70 条在单位表上重演）。
        let segments = try TeleprompterSegmenter.segment(sourceText: "这里是两难")
        let result = TeleprompterAligner().locate(
            transcript: "这里是2难", segments: segments,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )
        #expect(result.confidence == 1.0)
        #expect(result.matchedCount == 5)
    }

    @Test func aChineseNumeralDoesNotMatchADifferentArabicDigit() throws {
        // 反向一侧：表只能让同一个数字对上，不能让邻近的数字互相等价。
        // 少了这条，把「七」映成 8 这种变异仍然会显得「无害」。
        // 断言的是**不是精确匹配**而不是「无位置」——单个 token 对不上时对齐器
        // 仍会给出一个低置信度的候选（0.8），那正是跟随控制器该拒掉的东西。
        let segments = try TeleprompterSegmenter.segment(sourceText: "这里是七成")
        let result = TeleprompterAligner().locate(
            transcript: "这里是8成", segments: segments,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )
        #expect(result.confidence < 1.0)
        #expect(result.matchedCount == 4)
    }

    // MARK: - 用户确认的读法（#110）

    private func aliasedSegment(
        _ text: String,
        _ display: String,
        _ spoken: String
    ) -> TeleprompterSegment {
        let ns = text as NSString
        let found = ns.range(of: display)
        return TeleprompterSegment(
            id: "segment-0",
            ordinal: 0,
            sourceRange: .init(start: 0, end: text.utf16.count),
            text: text,
            acceptedReadings: [
                TeleprompterAcceptedReading(
                    displayRange: .init(start: found.location, end: found.location + found.length),
                    displayText: display,
                    spokenText: spoken
                )
            ]
        )
    }

    @Test func aConfirmedReadingMatchesExactlyAndKeepsThePositionOnTheDisplayedText() throws {
        let text = "今天讲鲲鹏一体机。"
        let plain = try TeleprompterSegmenter.segment(sourceText: text)
        let aliased = [aliasedSegment(text, "鲲鹏", "昆鹏")]
        let anchor = TeleprompterAligner.Position(segmentIndex: 0, utf16Offset: 0)

        let withoutAlias = TeleprompterAligner().locate(
            transcript: "今天讲昆鹏一体机", segments: plain, anchor: anchor)
        let withAlias = TeleprompterAligner().locate(
            transcript: "今天讲昆鹏一体机", segments: aliased, anchor: anchor)

        #expect(
            withAlias.confidence > withoutAlias.confidence,
            "确认读法后，识别器实际听到的那个词应当变成精确匹配"
        )
        #expect(withAlias.isUniqueExactContinuation)
        #expect(
            withAlias.position == withoutAlias.position,
            "别名只改变怎么匹配，不改变阅读位置落在显示文本的哪一段"
        )
        #expect(withAlias.position?.utf16Offset == 8, "位置仍按显示文本的 UTF-16 计算")
    }

    @Test func aConfirmedReadingStillLocatesTheDisplayedWords() throws {
        let text = "今天讲鲲鹏一体机。"
        let aliased = [aliasedSegment(text, "鲲鹏", "昆鹏")]
        let match = TeleprompterAligner().locate(
            transcript: "今天讲鲲鹏一体机",
            segments: aliased,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )
        // 确认别名不是承诺不再念屏幕上的字。念显示文本仍要能定位，只是分数低于
 // 念确认读法时的精确匹配——这正是「替换而非追加」这一选择的已知代价。
        #expect(match.position?.utf16Offset == 8)
        #expect(match.confidence >= 0.72, "低于前进门槛会让读者以为没跟上")
    }

    @Test func aReadingThatChangesTheNumberIsRefused() {
        let text = "转化率 50%。"
        let ns = text as NSString
        let found = ns.range(of: "50%")
        func alias(_ spoken: String) -> TeleprompterAcceptedReading {
            TeleprompterAcceptedReading(
                displayRange: .init(start: found.location, end: found.location + found.length),
                displayText: "50%",
                spokenText: spoken
            )
        }

        #expect(alias("百分之五十").rejection(inSegmentText: text) == nil,
                "同值换算读法应当允许")
        #expect(alias("大约一半").rejection(inSegmentText: text) == .numericValuesDiffer,
                "「大约一半」不是 50% 的无损等价，必须拒绝")
        #expect(alias("百分之六十").rejection(inSegmentText: text) == .numericValuesDiffer,
                "别名不得把 50% 变成 60%")
    }

    /// The sheet tells the reader 读法只能改发音，不能改数值. That promise is
    /// kept by comparing numeric fingerprints, so its strength is exactly the
    /// canonicalizer's number recognition: a magnitude nobody recognises is a
    /// quantity the gate cannot see. `3万` and `三万` both fingerprinted as
    /// "3" and "nothing", which let `3万` → `3` and `三万` → `三千` through
    /// while refusing the two spellings of the same number.
    @Test func aliasGateSeesMagnitudeOnBothSides() {
        func alias(_ display: String, _ spoken: String) -> TeleprompterAcceptedReading {
            TeleprompterAcceptedReading(
                displayRange: .init(start: 0, end: (display as NSString).length),
                displayText: display,
                spokenText: spoken
            )
        }

        for (display, spoken) in [
            ("3万", "三万"),
            ("5千", "五千"),
            ("2亿", "两亿"),
            ("2万元", "两万元"),
            ("1亿元", "一亿元"),
            ("50", "五十"),
        ] {
            #expect(
                alias(display, spoken).rejection(inSegmentText: display) == nil,
                "\(display) 与 \(spoken) 是同一个数，读法必须被接受"
            )
        }

        for (display, spoken) in [
            ("3万", "3"),
            ("5千", "5"),
            ("2亿", "2"),
            ("2万元", "2元"),
            ("三万", "三千"),
            ("三万", "三"),
        ] {
            #expect(
                alias(display, spoken).rejection(inSegmentText: display)
                    == .numericValuesDiffer,
                "\(display) → \(spoken) 改了数值，必须拒绝"
            )
        }
    }

    @Test func anAliasStopsApplyingOnceTheSegmentTextMoves() {
        let alias = TeleprompterAcceptedReading(
            displayRange: .init(start: 3, end: 5),
            displayText: "鲲鹏",
            spokenText: "昆鹏"
        )
        #expect(alias.rejection(inSegmentText: "今天讲鲲鹏一体机。") == nil)
        #expect(
            alias.rejection(inSegmentText: "今天讲昆鹏一体机。") == .displayTextChanged,
            "正文被改过之后，别名必须停止生效，而不是指向别的词"
        )
        #expect(
            alias.rejection(inSegmentText: "今天讲。") == .rangeOutOfBounds
        )
    }

    @Test func aliasBoundariesNeverSplitEmojiOrCombiningMarks() throws {
        // 代理对与组合记号都不在别名范围内：别名两侧的偏移必须仍然落在合法边界上。
        let text = "🐦今天讲鲲鹏😀机。"
        let aliased = [aliasedSegment(text, "鲲鹏", "昆鹏")]
        let match = TeleprompterAligner().locate(
            transcript: "今天讲昆鹏机",
            segments: aliased,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )
        #expect(match.position != nil, "别名跨越 emoji 边界时仍要能定位")
        let offset = try #require(match.position?.utf16Offset)
        #expect(offset > 0 && offset <= text.utf16.count)
        // 偏移不得落在代理对（emoji）中间：0xD800–0xDFFF 是高低温代理。
        let units = Array(text.utf16)
        let splitsSurrogatePair = offset > 0 && offset < units.count
            && (0xD800...0xDFFF).contains(units[offset - 1])
            && (0xD800...0xDFFF).contains(units[offset])
        #expect(!splitsSurrogatePair, "阅读位置不得落在代理对中间")
    }

    @Test func whenTwoReadingsOverlapTheEarlierOneWinsAndTheOtherIsDropped() {
        let text = "今天讲鲲鹏一体机。"
        let first = TeleprompterAcceptedReading(
            displayRange: .init(start: 3, end: 5), displayText: "鲲鹏", spokenText: "昆鹏")
        let second = TeleprompterAcceptedReading(
            displayRange: .init(start: 4, end: 6), displayText: "鹏一", spokenText: "鹏壹")
        let segment = TeleprompterSegment(
            id: "segment-0", ordinal: 0,
            sourceRange: .init(start: 0, end: text.utf16.count),
            text: text, acceptedReadings: [first, second]
        )
        let usable = TeleprompterAligner.Script.usableAliases(in: segment)
        #expect(usable.map(\.displayRange) == [.init(start: 3, end: 5)],
                "重叠时保留最早确认的那个，后一个被丢弃；不靠猜")
    }

    @Test func aReadingFromANewerRuleRevisionIsDropped() {
        let text = "今天讲鲲鹏一体机。"
        let alias = TeleprompterAcceptedReading(
            displayRange: .init(start: 3, end: 5),
            displayText: "鲲鹏",
            spokenText: "昆鹏",
            ruleRevision: TeleprompterAcceptedReading.currentRuleRevision + 1
        )
        #expect(
            alias.rejection(inSegmentText: text) == .unknownRuleRevision,
            "读不懂的规则版本不能声称自己通过了没读过的校验"
        )
    }

    @Test func thePositionOfTheAliasedWordsThemselvesStaysOnTheDisplayedSpan() throws {
        // 只断言「整句念完停在哪」是不够的：那个位置来自别名之后的词，
        // 把别名的 span 改成什么都不会被发现。所以这里让转写正好停在别名上。
        let text = "今天讲鲲鹏一体机。"
        let aliased = [aliasedSegment(text, "鲲鹏", "昆鹏")]

        let match = TeleprompterAligner().locate(
            transcript: "今天讲昆鹏",
            segments: aliased,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )

        #expect(
            match.position?.utf16Offset == 5,
            "别名的 token 用读法的值匹配，但位置必须落在显示文本那一段的末尾"
        )
    }

    @Test func anAliasThatWouldCutANumberInHalfIsSkippedRatherThanHalfApplied() {
        // "50%" 被规范器当成一个整体数值单元。别名从它中间开始就会把这个单元
        // 切成两半，位置归属说不清——宁可整条作废。读法写成同值的 "0%" 才能走到
        // 这条守卫：换成别的读法会先被数值一致性挡在门外，根本到不了这里。
        let text = "转化率50%。"
        let ns = text as NSString
        let number = ns.range(of: "50%")
        #expect(number.location != NSNotFound)
        let inner = NSRange(location: number.location + 1, length: number.length - 1)
        let alias = TeleprompterAcceptedReading(
            displayRange: .init(start: inner.location, end: inner.location + inner.length),
            displayText: ns.substring(with: inner),
            spokenText: ns.substring(with: inner)
        )
        #expect(alias.rejection(inSegmentText: text) == nil, "前提：这条别名本身是合法的")
        let range = TeleprompterSourceRange(start: 0, end: text.utf16.count)
        let withAlias = TeleprompterAligner.Script(segments: [
            TeleprompterSegment(
                id: "s", ordinal: 0, sourceRange: range, text: text, acceptedReadings: [alias]
            )
        ])
        let withoutAlias = TeleprompterAligner.Script(segments: [
            TeleprompterSegment(id: "s", ordinal: 0, sourceRange: range, text: text)
        ])

        #expect(
            withAlias.tokens.map(\.value) == withoutAlias.tokens.map(\.value),
            "跨着数值边界的别名整条作废，不得只应用一半"
        )
    }

    @Test func aStaleAliasNeverReachesTheTokenStream() {
        // 存盘和读盘都会校验，所以这条守卫理论上够不着；它一旦失效，
        // 代价是把阅读位置挪到读者根本没念过的词上，所以仍要有兜底断言。
        let text = "今天讲凤凰一体机。"
        let stale = TeleprompterAcceptedReading(
            displayRange: .init(start: 3, end: 5),
            displayText: "鲲鹏",
            spokenText: "昆鹏"
        )
        let range = TeleprompterSourceRange(start: 0, end: text.utf16.count)
        let edited = TeleprompterAligner.Script(segments: [
            TeleprompterSegment(
                id: "s", ordinal: 0, sourceRange: range,
                text: text, acceptedReadings: [stale]
            )
        ])
        let plain = TeleprompterAligner.Script(segments: [
            TeleprompterSegment(id: "s", ordinal: 0, sourceRange: range, text: text)
        ])
        #expect(stale.rejection(inSegmentText: text) == .displayTextChanged)

        #expect(
            edited.tokens.map(\.value) == plain.tokens.map(\.value),
            "失效的别名不得再影响匹配"
        )
    }

    @Test func anEmptyOrOversizedReadingIsRefused() {
        let text = "今天讲鲲鹏一体机。"
        func alias(_ spoken: String) -> TeleprompterAcceptedReading {
            TeleprompterAcceptedReading(
                displayRange: .init(start: 3, end: 5),
                displayText: "鲲鹏",
                spokenText: spoken
            )
        }
        #expect(alias("   ").rejection(inSegmentText: text) == .emptySpokenText)
        #expect(
            alias(String(repeating: "啊", count: TeleprompterAcceptedReading.maximumSpokenTextLength + 1))
                .rejection(inSegmentText: text) == .spokenTextTooLong
        )
    }
    @Test func unrelatedSpeechAndRepeatedShortPhrasesDoNotMove() throws {
        let repeated = try TeleprompterSegmenter.segment(sourceText: "谢谢大家。今天讲相机。谢谢大家。现在讲手机。")
        let aligner = TeleprompterAligner()
        #expect(aligner.locate(transcript: "谢谢大家", segments: repeated,
                              anchor: .init(segmentIndex: 1, utf16Offset: 0)).position == nil)
        #expect(aligner.locate(transcript: "外面的天气非常晴朗", segments: try script(),
                              anchor: .init(segmentIndex: 0, utf16Offset: 0)).position == nil)
    }

    @Test func normalizationPreservesWordsAndSourceCoordinates() {
        #expect(TeleprompterNormalizer.tokens("number summer") == ["number", "summer"])
        let tokens = TeleprompterNormalizer.indexedTokens("😀今天 number")
        #expect(tokens.first?.range.start == 2)
        #expect(tokens.last?.range.end == 11)
    }

    @Test func readingSlicesPreserveUnicodeAndPunctuation() throws {
        let segments = try TeleprompterSegmenter.segment(sourceText: "😀今天讲解 number 的使用方法，接着继续。")
        let slices = TeleprompterNormalizer.readingSlices(segments: segments, tokensPerSlice: 3)
        #expect(slices.map(\.text).joined() == segments.map(\.text).joined())
        #expect(slices.first?.start == 0)
        #expect(slices.last?.end == segments.last?.text.utf16.count)
        #expect(Set(slices.map(\.id)).count == slices.count)
    }

    @Test func toleratesOmissionAndDigitReading() throws {
        let segments = try TeleprompterSegmenter.segment(sourceText: "欢迎来到今天的直播。现在讲解2026年的相机设置。")
        let result = TeleprompterAligner().locate(transcript: "现在讲二零二六年的相机设置", segments: segments,
                                                anchor: .init(segmentIndex: 0, utf16Offset: 0))
        #expect(result.position?.segmentIndex == 1)
    }

    @Test func toleratesSubstitutedTailAndShortInput() throws {
        let aligner = TeleprompterAligner()
        let segments = try TeleprompterSegmenter.segment(sourceText: "现在介绍相机设置。最后导出照片。")
        let substituted = aligner.locate(
            transcript: "现在介绍相机参数",
            segments: segments,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )
        #expect(substituted.position?.segmentIndex == 0)
        #expect(substituted.confidence >= 0.72)

        let shortSegments = try TeleprompterSegmenter.segment(sourceText: "欢迎。继续。")
        let short = aligner.locate(
            transcript: "继续",
            segments: shortSegments,
            anchor: .init(segmentIndex: 0, utf16Offset: 2)
        )
        #expect(short.position?.segmentIndex == 1)
        #expect(short.isUniqueNearAnchor)

        let repeated = try TeleprompterSegmenter.segment(sourceText: "开场。继续。中间内容。继续。")
        let ambiguous = aligner.locate(
            transcript: "继续",
            segments: repeated,
            anchor: .init(segmentIndex: 2, utf16Offset: 0)
        )
        #expect(ambiguous.position == nil)
    }

    @Test func circleZeroYearSharesTheSamePositionAsItsArabicForm() throws {
        let segments = try TeleprompterSegmenter.segment(sourceText: "我们从二〇二六年开始。")
        let result = TeleprompterAligner().locate(
            transcript: "我们从2026年开始",
            segments: segments,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )

        #expect(result.position?.segmentIndex == 0)
        #expect(result.confidence == 1)
    }

    @Test func itnVariantsShareTheSameScriptPosition() throws {
        let segments = try TeleprompterSegmenter.segment(
            sourceText: "我们在二零二六年把成功率提高到百分之五十。"
        )
        let result = TeleprompterAligner().locate(
            transcript: "我们在2026年把成功率提高到50%",
            segments: segments,
            anchor: .init(segmentIndex: 0, utf16Offset: 0)
        )

        #expect(result.position?.segmentIndex == 0)
        #expect(result.confidence >= 0.72)
    }

}
