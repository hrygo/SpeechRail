import CoreFoundation
import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookImportTests: XCTestCase {
    func testStrictEncodingPreview() throws {
        let sampleText = "第1章 雾港\n“你也看见灯了？”他问。合法替换符：\u{FFFD}。\n"

        // 1. Valid UTF-8 (including literal U+FFFD)
        let utf8Data = Data(sampleText.utf8)
        let utf8Preview = try AudiobookTXTImporter.prepare(rawData: utf8Data, suggestedTitle: "雾港来信")
        XCTAssertEqual(utf8Preview.detectedEncoding, .utf8)
        XCTAssertEqual(try utf8Preview.sourceIndex.text(in: utf8Preview.sourceIndex.wholeRange), sampleText)

        // 2. Valid UTF-16 LE with BOM
        var utf16LEData = Data([0xFF, 0xFE])
        utf16LEData.append(sampleText.data(using: .utf16LittleEndian)!)
        let utf16LEPreview = try AudiobookTXTImporter.prepare(rawData: utf16LEData, suggestedTitle: "雾港来信")
        XCTAssertEqual(utf16LEPreview.detectedEncoding, .utf16LE)
        XCTAssertEqual(try utf16LEPreview.sourceIndex.text(in: utf16LEPreview.sourceIndex.wholeRange), sampleText)

        // 3. Valid UTF-16 BE with BOM
        var utf16BEData = Data([0xFE, 0xFF])
        utf16BEData.append(sampleText.data(using: .utf16BigEndian)!)
        let utf16BEPreview = try AudiobookTXTImporter.prepare(rawData: utf16BEData, suggestedTitle: "雾港来信")
        XCTAssertEqual(utf16BEPreview.detectedEncoding, .utf16BE)
        XCTAssertEqual(try utf16BEPreview.sourceIndex.text(in: utf16BEPreview.sourceIndex.wholeRange), sampleText)

        // 4. Valid GB18030 requires explicit encoding confirmation when non-UTF8, and succeeds when selected
        let cfGB = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let nsGB = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfGB))
        let gbData = try XCTUnwrap(sampleText.data(using: nsGB))
        XCTAssertThrowsError(try AudiobookTXTImporter.prepare(rawData: gbData)) { error in
            guard case let AudiobookImportError.encodingSelectionRequired(candidates) = error else {
                XCTFail("Expected encodingSelectionRequired, got \(error)")
                return
            }
            XCTAssertTrue(candidates.contains(.gb18030))
        }
        let gbPreview = try AudiobookTXTImporter.prepare(
            rawData: gbData,
            suggestedTitle: "雾港来信",
            encoding: .gb18030
        )
        XCTAssertEqual(gbPreview.detectedEncoding, .gb18030)
        XCTAssertEqual(try gbPreview.sourceIndex.text(in: gbPreview.sourceIndex.wholeRange), sampleText)

        // 5. Reject bad UTF-8 bytes
        let badUTF8 = Data([0xE4, 0xB8, 0xFF, 0x41])
        XCTAssertThrowsError(try AudiobookTXTImporter.prepare(rawData: badUTF8, encoding: .utf8)) { error in
            XCTAssertEqual(error as? AudiobookImportError, .invalidEncoding(.utf8))
        }

        // 6. Reject unpaired UTF-16 surrogate
        let unpairedSurrogateLE = Data([0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00])
        XCTAssertThrowsError(try AudiobookTXTImporter.prepare(rawData: unpairedSurrogateLE, encoding: .utf16LE)) { error in
            XCTAssertEqual(error as? AudiobookImportError, .invalidEncoding(.utf16LE))
        }

        // 7. Reject odd UTF-16 byte count
        let oddUTF16LE = Data([0xFF, 0xFE, 0x41, 0x00, 0x42])
        XCTAssertThrowsError(try AudiobookTXTImporter.prepare(rawData: oddUTF16LE, encoding: .utf16LE)) { error in
            XCTAssertEqual(error as? AudiobookImportError, .oddUTF16ByteCount(3))
        }
    }

    func testSameFilenameNeverOverwritesSource() throws {
        let firstData = Data("第1章 初见\n第一本书的正文。".utf8)
        let secondData = Data("第1章 重逢\n第二本书的正文，虽然文件名相同。".utf8)

        let preview1 = try AudiobookTXTImporter.prepare(
            rawData: firstData,
            suggestedTitle: "同名小说",
            originalFileName: "novel.txt"
        )
        let preview2 = try AudiobookTXTImporter.prepare(
            rawData: secondData,
            suggestedTitle: "同名小说",
            originalFileName: "novel.txt"
        )

        XCTAssertNotEqual(preview1.bookID, preview2.bookID)
        XCTAssertNotEqual(preview1.sourceID, preview2.sourceID)
        XCTAssertNotEqual(preview1.sourceSHA256, preview2.sourceSHA256)

        // Reject oversized files before full read
        XCTAssertThrowsError(
            try AudiobookTXTImporter.prepare(
                rawData: Data(repeating: 0x41, count: 128),
                maxRawBytes: 64
            )
        ) { error in
            XCTAssertEqual(error as? AudiobookImportError, .fileTooLarge(byteCount: 128, maxBytes: 64))
        }
    }

    func testNoHeadingProducesWholeTextChapter() throws {
        let plainText = "这是一段没有任何章节标题的散文。\n它只有两行叙述，附言与广告默认全部保留。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(plainText.utf8), suggestedTitle: "散文")

        XCTAssertEqual(preview.chapters.count, 1)
        XCTAssertEqual(preview.chapters[0].title, "全文")
        XCTAssertEqual(preview.chapters[0].sourceRange, preview.sourceIndex.wholeRange)
        XCTAssertEqual(try preview.sourceIndex.text(in: preview.chapters[0].sourceRange), plainText)
    }

    func testChapterHeadingsWithoutWhitespaceBeforeTitleAreRecognized() throws {
        let text = "第一章风起\n晨雾中的海岸很安静。\n第二章夜雨\n港口的灯火摇曳。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8), suggestedTitle: "海岸")

        XCTAssertEqual(preview.chapters.map(\.title), ["第一章风起", "第二章夜雨"])
        XCTAssertNoThrow(
            try AudiobookChapterPlanner.validateChapterEdits(
                preview.chapters,
                source: preview.sourceIndex
            )
        )

        let narrative = "第二章开始时，港口还笼罩在雾里。\n灯塔照亮了海面。"
        let narrativePreview = try AudiobookTXTImporter.prepare(
            rawData: Data(narrative.utf8),
            suggestedTitle: "叙述"
        )
        XCTAssertEqual(narrativePreview.chapters.count, 1, "章标记后接普通句子时仍应保留为正文")
        XCTAssertEqual(narrativePreview.chapters[0].title, "全文")
    }

    func testChapterEditsAndExclusionsKeepCoverage() throws {
        let text = "序章 雾中灯塔\n海雾漫过栈桥。\n第1章 旧邮差\n他递来一封信。\n附言\n本书完。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8), suggestedTitle: "雾港")
        XCTAssertEqual(preview.chapters.count, 3)
        XCTAssertEqual(preview.chapters[0].title, "序章 雾中灯塔")
        XCTAssertEqual(preview.chapters[1].title, "第1章 旧邮差")
        XCTAssertEqual(preview.chapters[2].title, "附言")

        // Marking the postscript body as excluded keeps coverage valid
        var editedChapters = preview.chapters
        let postscriptRange = editedChapters[2].sourceRange
        editedChapters[2].excludedRanges = [postscriptRange]
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(editedChapters, source: preview.sourceIndex))

        // Introducing a 3-byte hole between chapters must fail validation
        var brokenChapters = preview.chapters
        brokenChapters[1].sourceRange = AudiobookSourceRange(
            lowerBound: brokenChapters[1].sourceRange.lowerBound + 3,
            upperBound: brokenChapters[1].sourceRange.upperBound
        )
        XCTAssertThrowsError(try AudiobookChapterPlanner.validateChapterEdits(brokenChapters, source: preview.sourceIndex))
    }

    func testSplitAndMergeChapterBoundariesPreserveCanonicalSource() throws {
        let text = "第一句。\n第二句。\n第三句。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8), suggestedTitle: "分章")
        let originalChapter = try XCTUnwrap(preview.chapters.first)
        let splitMarker = try XCTUnwrap(Data(text.utf8).range(of: Data("第二句".utf8)))

        let split = try AudiobookChapterPlanner.splitChapter(
            preview.chapters,
            chapterID: originalChapter.id,
            atByteOffset: Int64(splitMarker.lowerBound),
            secondTitle: "第二部分",
            source: preview.sourceIndex
        )
        XCTAssertEqual(split.count, 2)
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(split, source: preview.sourceIndex))

        let merged = try AudiobookChapterPlanner.mergeChapterWithPrevious(
            split,
            chapterID: try XCTUnwrap(split.last?.id),
            source: preview.sourceIndex
        )
        XCTAssertEqual(merged.count, 1, "合并相邻章节应得到一个目录项")
        XCTAssertEqual(merged.first?.id, originalChapter.id, "合并应稳定保留上一章身份")
        XCTAssertEqual(merged.first?.sourceRange, originalChapter.sourceRange)
        XCTAssertEqual(try preview.sourceIndex.text(in: preview.sourceIndex.wholeRange), text,
                       "拆分与合并只调整章节区间，不得改写规范化原文")
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(merged, source: preview.sourceIndex))
    }
}
