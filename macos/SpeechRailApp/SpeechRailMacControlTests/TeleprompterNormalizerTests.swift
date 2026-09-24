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
        let source = "请检查 super_long_identifier_that_should_stay_together_then继续说明。"

        let segments = try TeleprompterSegmenter.segment(sourceText: source)

        let identifier = "super_long_identifier_that_should_stay_together"
        XCTAssertEqual(segments.filter { $0.text.contains(identifier) }.count, 1)
        XCTAssertTrue(segments.map(\.text).joined().contains(identifier))
    }
}


struct TeleprompterCanonicalizerTests {
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
}
