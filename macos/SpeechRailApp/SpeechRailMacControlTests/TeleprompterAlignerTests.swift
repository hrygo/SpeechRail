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
}
