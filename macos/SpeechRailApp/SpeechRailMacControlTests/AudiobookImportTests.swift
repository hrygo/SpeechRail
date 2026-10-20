import CoreFoundation
import AppKit
import Darwin
import Foundation
import Testing
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookImportTests: XCTestCase {
    func testWrappedAnthologyIsPreparedBeforeChapterPlanning() throws {
        let body = "        河岸上的行人踏著晨霧前行，遠處的燈火還未熄滅，街道仍然十分\r\n安靜。他停下腳步，望向河面。\r\n\r\n"
        let text = "著者：某人\r\n\r\n" + String(repeating: body, count: 10)
            + "              江岸【1】     ──一個人的手記\r\n\r\n" + body
            + "                                        夜行\r\n" + body
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))

        XCTAssertEqual(preview.chapters.map(\.title), ["开篇", "江岸【1】     ──一個人的手記", "夜行"])
        XCTAssertTrue(preview.previewText.contains("十分安靜。"), "预览必须先连接段内的排版折行")
        XCTAssertTrue(preview.previewText.contains("\n\n"), "自然段落边界必须保留")
        XCTAssertFalse(preview.previewText.contains("\r"))
        XCTAssertEqual(preview.originalBytes, Data(text.utf8))
        XCTAssertEqual(preview.canonicalUTF8, Data(text.utf8))
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex))
    }

    func testIsolatedNumberedSectionsArePlannedWithoutInventingMissingTitles() throws {
        let text = "一\r\n\r\n第一部分的敘述，保留原有文字。\r\n\r\n二\r\n\r\n第二部分的敘述，也保留原有文字。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))
        XCTAssertEqual(preview.chapters.map(\.title), ["一", "二"])
        XCTAssertEqual(try preview.sourceIndex.text(in: preview.sourceIndex.wholeRange), text)
    }

    func testPreparedPreviewPreservesDialoguePoetryAndParagraphs() throws {
        let text = "第一章 晨行\r\n“你去？”\r\n“我去。”\r\n\r\n    山風吹古木\r\n    月色照長河\r\n\r\n下一段保留原本的段落。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))
        XCTAssertTrue(preview.previewText.contains("“你去？”\n\n“我去。”"))
        XCTAssertTrue(preview.previewText.contains("山風吹古木\n\n月色照長河"))
        XCTAssertTrue(preview.previewText.hasSuffix("下一段保留原本的段落。"))
        XCTAssertEqual(preview.chapters.count, 1)
    }

    func testCoverTitleDoesNotBorrowBodyFromFollowingChapterTitle() throws {
        let body = "        他推開門，走進晨霧中，街道盡頭的行人正向河岸走去。\r\n\r\n"
        let text = "                        遠行集\r\n\r\n"
            + "                        江岸\r\n\r\n" + body
            + "                        夜行\r\n\r\n" + body
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))
        XCTAssertEqual(preview.chapters.map(\.title), ["开篇", "江岸", "夜行"])
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex))
    }

    func testWhitespaceOnlyTextIsRejectedBeforeImport() throws {
        for text in [" ", "\r\n\t  \r\n", "　　\n\n"] {
            XCTAssertThrowsError(try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))) {
                XCTAssertEqual($0 as? AudiobookImportError, .emptyFile)
            }
        }
    }

    func testChapterPreviewSwitchesBetweenPreparedAndOriginalLayout() throws {
        let text = "第一章 晨行\r\n前一章的內容。\r\n\r\n第二章 夜行\r\n\r\n        他走在河邊，望著遠處的燈火，靜靜地等候著遠方傳來的消\r\n息。\r\n"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))
        let chapter = try XCTUnwrap(preview.chapters.last)
        let prepared = try preview.textPreview(for: chapter.id)
        let original = try preview.textPreview(for: chapter.id, originalLayout: true)
        XCTAssertTrue(prepared.hasPrefix("第二章 夜行\n\n"))
        XCTAssertTrue(prepared.contains("消息。"))
        XCTAssertFalse(prepared.contains("前一章"))
        XCTAssertTrue(original.contains("消\r\n息。"))
        XCTAssertEqual(Data(original.utf8), preview.sourceIndex.utf8Data.subdata(in: Int(chapter.sourceRange.lowerBound)..<Int(chapter.sourceRange.upperBound)))
    }

    func testStrictEncodingPreview() throws {
        let sampleText = "第1章 雾港\n“你也看见灯了？”他问。合法替换符：\u{FFFD}。\n"

        // 1. Valid UTF-8 (including literal U+FFFD)
        let utf8Data = Data(sampleText.utf8)
        let utf8Preview = try AudiobookTXTImporter.prepare(rawData: utf8Data, suggestedTitle: "雾港来信")
        XCTAssertEqual(utf8Preview.detectedEncoding, .utf8)
        XCTAssertEqual(try utf8Preview.sourceIndex.text(in: utf8Preview.sourceIndex.wholeRange), sampleText)
        XCTAssertFalse(try utf8Preview.sourceIndex.normalizedText(in: utf8Preview.sourceIndex.wholeRange).contains("\u{FFFD}"))
        XCTAssertEqual(utf8Preview.originalBytes, utf8Data, "显示投影净化不能改动原始输入字节")
        XCTAssertEqual(utf8Preview.canonicalUTF8, utf8Data, "显示投影净化不能改动规范原文")

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
        // 非 UTF-8 的合法 GB18030 字节流先给出可核对的预览，并标明需要确认编码；
        // 不能在校验阶段直接失败，否则导入面板没有机会让用户切换编码。
        let provisional = try AudiobookTXTImporter.prepare(rawData: gbData)
        XCTAssertEqual(provisional.detectedEncoding, .gb18030)
        XCTAssertTrue(provisional.requiresEncodingConfirmation)
        XCTAssertTrue(provisional.candidateEncodings.contains(.gb18030))
        XCTAssertTrue(provisional.candidateEncodings.contains(.utf8))
        XCTAssertEqual(provisional.chapters.count, 1)
        XCTAssertTrue(provisional.previewText.contains("雾港"))
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

    func testCircleZeroRoundHeadingsAreRecognizedIndividually() throws {
        let body = "這是一段足夠長的虛構正文，用來確認獨立回目會成為目錄標題並保留正文。"
        for title in ["第一○回", "第二○回", "第一○○回"] {
            let text = "\(title)\r\n\r\n\(body)"
            let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))

            XCTAssertEqual(preview.chapters.map(\.title), [title], "应识别回目 \(title)")
            XCTAssertTrue(try preview.sourceIndex.normalizedText(in: preview.chapters[0].sourceRange).contains(body))
            XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex))
        }
    }

    func testAnthologyTitlesStayTopLevelAroundInternalChapters() throws {
        let text = "雨\r\n\r\n第一章 雨夜\r\n河岸上的燈火映著長街，行人沿著石橋慢慢走去。\r\n\r\n"
            + "第二章 轉晴\r\n清晨的雨停了，屋簷下仍有水珠落下。\r\n\r\n"
            + "風\r\n\r\n第一章 遠行\r\n山路盡頭傳來車聲，旅人回頭望了一眼。\r\n\r\n"
            + "第二章 歸來\r\n天色漸暗，他終於看見熟悉的窗燈。"
        let raw = Data(text.utf8)
        let preview = try AudiobookTXTImporter.prepare(rawData: raw)

        XCTAssertEqual(preview.chapters.map(\.title), ["雨", "風"])
        XCTAssertEqual(preview.originalBytes, raw)
        XCTAssertEqual(try preview.sourceIndex.text(in: preview.sourceIndex.wholeRange), text)
        XCTAssertTrue(preview.previewText.contains("河岸上的燈火"))
        XCTAssertTrue(preview.previewText.contains("熟悉的窗燈"))
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex))
    }

    func testAnthologyStoryCanStartWithShortDialogue() throws {
        let text = "雨\n\n“橋那邊有人嗎？”\n\n她沿著河岸尋找，遠處的燈光仍在濃霧中閃爍。\n\n風\n\n旅人走過石橋，看見遠處的燈火依舊明亮。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))
        XCTAssertEqual(preview.chapters.map(\.title), ["雨", "風"])
        XCTAssertEqual(preview.canonicalUTF8, Data(text.utf8))
    }

    func testNarrativeWithDashesIsNotAnAnthologySubtitle() throws {
        let text = "雨\n\n她沿著河岸尋找，遠處的燈光仍在濃霧中閃爍。\n\n旅人──遠方歸客──點了點頭，但是沒有開口。\n\n另一位行人慢慢走近，手中的燈光映著石橋。\n\n風\n\n旅人走過石橋，看見遠處的燈火依舊明亮。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))
        XCTAssertEqual(preview.chapters.map(\.title), ["雨", "風"])
        XCTAssertEqual(preview.canonicalUTF8, Data(text.utf8))
    }

    func testRoundHeadingEmbeddedAfterPreviousTextSplitsWithoutAbsorbingBody() throws {
        let firstTitle = "第十二回　前回對仗標題"
        let secondTitle = "第十三回　虛構對仗標題　另一標題"
        let body = "話說今夜江岸起了薄霧，遠處的燈火照著石橋，行人沿河慢慢走去。"
        let text = "\(firstTitle)\r\n前回正文仍留在原章。\r\n\r\n下回分解。\(secondTitle)　\(body)"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))

        guard preview.chapters.count == 2, let secondChapter = preview.chapters.last else {
            XCTFail("应从粘连正文中切出第二回，实际目录：\(preview.chapters.map(\.title))")
            return
        }
        XCTAssertEqual(preview.chapters.map(\.title), [firstTitle, secondTitle])
        XCTAssertTrue(preview.previewText.contains(body))
        XCTAssertFalse(secondChapter.title.contains("話說"))
        XCTAssertTrue(try preview.sourceIndex.normalizedText(in: secondChapter.sourceRange).contains(body))
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex))
    }

    func testProseOpeningSplitAcrossPhysicalLinesStaysOutOfRoundTitle() throws {
        for newline in ["\n", "\r\n", "\r"] {
            for (opening, remainder) in [("話", "說"), ("卻", "說"), ("话", "说")] {
                let title = "第三十一回　山窗夜話　遠客歸舟"
                let body = "\(opening)\(remainder)旅人走過石橋，看見遠處的燈火依舊明亮。"
                let text = "\(title)　\(opening)\(newline)\(remainder)旅人走過石橋，看見遠處的燈火依舊明亮。"
                let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))

                XCTAssertEqual(preview.chapters.map(\.title), [title])
                XCTAssertTrue(preview.previewText.contains(body))
                XCTAssertEqual(preview.canonicalUTF8, Data(text.utf8))
                XCTAssertNoThrow(try preview.sourceIndex.validateCoverage(preview.chapters.map(\.sourceRange), exclusions: []))
            }
        }
    }

    func testNarrativeReferenceBeginningWithRoundNumberDoesNotCreateChapter() throws {
        let text = "第四回中主人公繼續趕路隨後走進一座燈火昏暗的城門"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))

        XCTAssertEqual(preview.chapters.map(\.title), ["全文"])
        XCTAssertEqual(try preview.sourceIndex.text(in: preview.sourceIndex.wholeRange), text)
    }

    func testRepeatedRoundTitleSeparatedOnlyByDashHasOneDirectoryEntryAndFullCoverage() throws {
        let title = "第十四回　虛構回目"
        let text = "\(title)\r\n—\r\n\(title)\r\n山路上的旅人走過長橋，遠處的燈火仍然明亮。"
        let raw = Data(text.utf8)
        let preview = try AudiobookTXTImporter.prepare(rawData: raw)

        XCTAssertEqual(preview.chapters.map(\.title), [title])
        XCTAssertEqual(preview.originalBytes, raw)
        XCTAssertEqual(try preview.sourceIndex.text(in: preview.sourceIndex.wholeRange), text)
        XCTAssertNoThrow(try preview.sourceIndex.validateCoverage(preview.chapters.map(\.sourceRange), exclusions: []))
    }

    func testThreeRepeatedRoundTitlesCollapseToOneDirectoryEntry() throws {
        let title = "第十六回　三重虛構回目"
        let body = "山路上的旅人走過長橋，遠處的燈火仍然明亮。"
        let text = "\(title)\n—\n\(title)\n—\n\(title)\n\(body)"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))

        XCTAssertEqual(preview.chapters.map(\.title), [title])
        XCTAssertEqual(try preview.sourceIndex.text(in: preview.sourceIndex.wholeRange), text)
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex))
    }

    func testRepeatedWholeChapterTextRemainsFullyCoveredAndReadable() throws {
        let chapter = "第十五回　完整虛構回目\r\n山路上的旅人走過長橋，遠處的燈火仍然明亮。"
        let text = "\(chapter)\r\n\r\n\(chapter)"
        let raw = Data(text.utf8)
        let preview = try AudiobookTXTImporter.prepare(rawData: raw)
        let normalized = try preview.sourceIndex.normalizedText(in: preview.sourceIndex.wholeRange)

        XCTAssertEqual(preview.originalBytes, raw)
        XCTAssertEqual(preview.canonicalUTF8, raw)
        XCTAssertEqual(try preview.sourceIndex.text(in: preview.sourceIndex.wholeRange), text)
        XCTAssertEqual(normalized.components(separatedBy: "山路上的旅人").count - 1, 2)
        XCTAssertNoThrow(try preview.sourceIndex.validateCoverage(preview.chapters.map(\.sourceRange), exclusions: []))
    }

    func testRepeatedContentRequiresExplicitConfirmationWithoutRemovingEitherCopy() throws {
        let chapter = "第十五回　雨夜歸舟\r\n山路上的旅人走過長橋，遠處的燈火仍然明亮。"
        let raw = Data("\(chapter)\r\n\r\n\(chapter)".utf8)
        var preview = try AudiobookTXTImporter.prepare(rawData: raw)

        XCTAssertEqual(preview.chapters.count, 2)
        XCTAssertEqual(preview.repeatedContentWarnings.count, 1)
        XCTAssertEqual(preview.repeatedContentWarnings.first?.chapterIDs, preview.chapters.map(\.id))
        XCTAssertFalse(preview.canConfirmImport)
        preview.hasConfirmedRepeatedContent = true
        XCTAssertTrue(preview.canConfirmImport)
        XCTAssertEqual(preview.originalBytes, raw)
        XCTAssertEqual(preview.canonicalUTF8, raw)
        XCTAssertEqual(preview.chapters.count, 2)
    }

    func testTableOfContentsIsExcludedInsteadOfBecomingChapters() throws {
        let body1 = "    風從山谷吹來，捲起滿地落葉，遠處傳來隱約的鐘聲。他抬頭望去，天空陰沉。"
        let body2 = "    烏雲壓過山脊，雨點敲打窗欞，屋內的燈芯輕輕搖晃，映出人影。"
        let body3 = "    雷聲滾過天邊，震得窗紙嗡嗡作響，他握緊手中的書卷，等待雨停。"
        let text = "目錄\n\n第一章 風起\n第二章 雲湧\n第三章 雷鳴\n\n第一章 風起\n\n\(body1)\n\n第二章 雲湧\n\n\(body2)\n\n第三章 雷鳴\n\n\(body3)"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))

        XCTAssertEqual(preview.chapters.map(\.title), ["第一章 風起", "第二章 雲湧", "第三章 雷鳴"])
        XCTAssertEqual(preview.tableOfContentsRanges.count, 1)
        let first = try XCTUnwrap(preview.chapters.first)
        XCTAssertFalse(first.excludedRanges.isEmpty, "目录页应作为章节排除区间，而不是独立章节")
        XCTAssertFalse(try preview.textPreview(for: first.id).contains("目錄"))
        XCTAssertTrue(try preview.textPreview(for: first.id).contains("風從山谷"))
        let atoms = try preview.sourceIndex.buildAtoms(for: first)
        XCTAssertFalse(
            atoms.contains { (try? preview.sourceIndex.text(in: $0.sourceRange))?.contains("目錄") == true },
            "目录文字不能进入正文原子"
        )
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex))
    }

    func testTableOfContentsWithDotLeadersAndPageNumbersIsExcluded() throws {
        let body1 = "    風從山谷吹來，捲起滿地落葉，遠處傳來隱約的鐘聲。他抬頭望去，天空陰沉。"
        let body2 = "    烏雲壓過山脊，雨點敲打窗欞，屋內的燈芯輕輕搖晃，映出人影。"
        let body3 = "    雷聲滾過天邊，震得窗紙嗡嗡作響，他握緊手中的書卷，等待雨停。"
        let text = "目次\n第一章 風起……1\n第二章 雲湧……12\n第三章 雷鳴……25\n\n第一章 風起\n\n\(body1)\n\n第二章 雲湧\n\n\(body2)\n\n第三章 雷鳴\n\n\(body3)"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))

        XCTAssertEqual(preview.chapters.map(\.title), ["第一章 風起", "第二章 雲湧", "第三章 雷鳴"])
        XCTAssertEqual(preview.tableOfContentsRanges.count, 1)
        XCTAssertFalse(try preview.textPreview(for: preview.chapters[0].id).contains("……25"))
        XCTAssertTrue(try preview.textPreview(for: preview.chapters[0].id).contains("風從山谷"))
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex))
    }

    func testTableOfContentsWithoutMarkerIsDetectedByRepeatedLaterHeadings() throws {
        let body1 = "    風從山谷吹來，捲起滿地落葉，遠處傳來隱約的鐘聲。他抬頭望去，天空陰沉。"
        let body2 = "    烏雲壓過山脊，雨點敲打窗欞，屋內的燈芯輕輕搖晃，映出人影。"
        let body3 = "    雷聲滾過天邊，震得窗紙嗡嗡作響，他握緊手中的書卷，等待雨停。"
        let text = "第一章 風起\n第二章 雲湧\n第三章 雷鳴\n\n第一章 風起\n\n\(body1)\n\n第二章 雲湧\n\n\(body2)\n\n第三章 雷鳴\n\n\(body3)"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))

        XCTAssertEqual(preview.chapters.map(\.title), ["第一章 風起", "第二章 雲湧", "第三章 雷鳴"])
        XCTAssertEqual(preview.tableOfContentsRanges.count, 1)
        XCTAssertTrue(try preview.textPreview(for: preview.chapters[0].id).contains("風從山谷"))
        XCTAssertNoThrow(try AudiobookChapterPlanner.validateChapterEdits(preview.chapters, source: preview.sourceIndex))
    }

    func testShortNumberedSectionsAreNotMistakenForTableOfContents() throws {
        let text = "一\n\n第一部分短句。\n\n二\n\n第二部分短句。\n\n三\n\n第三部分短句。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))

        XCTAssertEqual(preview.chapters.map(\.title), ["一", "二", "三"])
        XCTAssertTrue(preview.chapters.allSatisfy(\.excludedRanges.isEmpty))
        XCTAssertTrue(preview.tableOfContentsRanges.isEmpty)
    }

    func testLargeSourceIndexBenchmarkWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["SPEECHRAIL_AUDIOBOOK_INDEX_BENCHMARK"] == "1" else {
            throw XCTSkip("仅在显式设置 SPEECHRAIL_AUDIOBOOK_INDEX_BENCHMARK=1 时运行大样本基准")
        }
        let scalarTarget = Int(ProcessInfo.processInfo.environment["SPEECHRAIL_AUDIOBOOK_INDEX_SCALARS"] ?? "2000000") ?? 2_000_000
        let unit = "天地玄黄，宇宙洪荒。\n"
        let unitScalars = unit.unicodeScalars.count
        let text = String(repeating: unit, count: max(1, scalarTarget / unitScalars))
        let data = Data(text.utf8)
        let before = Self.residentBytes()
        let started = Date()
        let index = try AudiobookSourceIndex(utf8: data)
        let elapsed = Date().timeIntervalSince(started) * 1_000
        let after = Self.residentBytes()
        print("audiobook-index-benchmark scalars=\(index.scalarCount) bytes=\(data.count) elapsed_ms=\(String(format: "%.1f", elapsed)) resident_delta_bytes=\(Int64(after) - Int64(before))")
        XCTAssertGreaterThan(index.scalarCount, scalarTarget / 2)
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    func testRealCorpusImportBenchmarkWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["SPEECHRAIL_AUDIOBOOK_REAL_CORPUS"] else {
            throw XCTSkip("仅在设置 SPEECHRAIL_AUDIOBOOK_REAL_CORPUS 时运行真实书稿基线")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let before = Self.residentBytes()
        let started = Date()
        let preview = try AudiobookTXTImporter.prepare(rawData: data)
        let elapsed = Date().timeIntervalSince(started) * 1_000
        let after = Self.residentBytes()
        print("audiobook-real-corpus-benchmark bytes=\(data.count) chapters=\(preview.chapters.count) elapsed_ms=\(String(format: "%.1f", elapsed)) resident_delta_bytes=\(Int64(after) - Int64(before))")
        XCTAssertFalse(preview.chapters.isEmpty)
    }

    func testRealEPUBImportWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SPEECHRAIL_AUDIOBOOK_REAL_EPUB_DIR"] else {
            throw XCTSkip("仅在设置 SPEECHRAIL_AUDIOBOOK_REAL_EPUB_DIR 时运行真实 EPUB 基线")
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "epub" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(urls.count, 3)
        for url in urls {
            let started = Date()
            let preview = try await AudiobookTXTImporter.prepareEPUB(fileURL: url)
            let elapsed = Date().timeIntervalSince(started) * 1_000
            print("audiobook-real-epub-benchmark file=\(url.lastPathComponent) chapters=\(preview.chapters.count) elapsed_ms=\(String(format: "%.1f", elapsed))")
            XCTAssertFalse(preview.chapters.isEmpty, url.lastPathComponent)
        }
    }

    func testEPUBExtractsSpineTextMetadataAndEntities() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-fixture-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8).write(to: source.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>测试之书</dc:title><dc:creator>测试作者</dc:creator>
          </metadata>
          <manifest>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """.utf8).write(to: source.appendingPathComponent("OEBPS/content.opf"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>
        <body><h1>第一章 出发</h1><p>山路&nbsp;漫长 &amp; 安静。</p><script>alert("x")</script></body></html>
        """.utf8).write(to: source.appendingPathComponent("OEBPS/ch1.xhtml"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>第二章</title></head>
        <body><h1>第二章 归来</h1><p>钟声响起。</p></body></html>
        """.utf8).write(to: source.appendingPathComponent("OEBPS/ch2.xhtml"))
        let epubURL = root.appendingPathComponent("book.epub")
        try makeZip(from: source, to: epubURL)

        let preview = try await AudiobookTXTImporter.prepareEPUB(fileURL: epubURL)
        XCTAssertTrue(preview.isEPUB)
        XCTAssertEqual(preview.title, "测试之书")
        XCTAssertEqual(preview.author, "测试作者")
        XCTAssertEqual(preview.chapters.map(\.title), ["第一章 出发", "第二章 归来"])
        XCTAssertTrue(preview.previewText.contains("山路 漫长 & 安静。"))
        XCTAssertFalse(preview.previewText.contains("script"))
        XCTAssertFalse(preview.previewText.contains("alert"))
    }

    func testEPUBRespectsLinearNoEncodedHrefsAndFragments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-spine-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("OEBPS/Text"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8).write(to: source.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>结构测试</dc:title></metadata>
          <manifest>
            <item id="c1" href="Text/ch%201.xhtml#start" media-type="application/xhtml+xml"/>
            <item id="c2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="c3" href="Text/ch3.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1" linear="no"/>
            <itemref idref="c2"/>
            <itemref idref="c3"/>
          </spine>
        </package>
        """.utf8).write(to: source.appendingPathComponent("OEBPS/content.opf"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><h1>附录</h1><p>不应出现在正文。</p></body></html>
        """.utf8).write(to: source.appendingPathComponent("OEBPS/Text/ch 1.xhtml"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><h1>第二章</h1><p>钟声响起。</p></body></html>
        """.utf8).write(to: source.appendingPathComponent("OEBPS/Text/ch2.xhtml"))
        try Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><h1>第三章</h1><p>旅人归来。</p></body></html>
        """.utf8).write(to: source.appendingPathComponent("OEBPS/Text/ch3.xhtml"))
        let epubURL = root.appendingPathComponent("book.epub")
        try makeZip(from: source, to: epubURL)

        let preview = try await AudiobookTXTImporter.prepareEPUB(fileURL: epubURL)
        XCTAssertEqual(preview.chapters.map(\.title), ["第二章", "第三章"])
        XCTAssertFalse(preview.previewText.contains("不应出现在正文"))
    }

    func testEPUBWithoutContainerIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-bad-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a container".utf8).write(to: source.appendingPathComponent("readme.txt"))
        let epubURL = root.appendingPathComponent("bad.epub")
        try makeZip(from: source, to: epubURL)
        XCTAssertThrowsError(try AudiobookEPUBImporter.extractText(from: epubURL)) { error in
            XCTAssertEqual(error as? AudiobookEPUBError, .missingContainer)
        }
    }

    private func makeZip(from directory: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-r", destination.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "测试夹具 ZIP 创建失败")
    }

    func testSameTitleWithDifferentBodyIsNotReportedAsRepeatedContent() throws {
        let text = "第十五回　雨夜歸舟\n山路上的旅人走過長橋，遠處的燈火仍然明亮。\n\n"
            + "第十五回　雨夜歸舟\n翌日村人打開門窗，河面上的霧氣已經漸漸散去。"
        let preview = try AudiobookTXTImporter.prepare(rawData: Data(text.utf8))
        XCTAssertEqual(preview.chapters.count, 2)
        XCTAssertTrue(preview.repeatedContentWarnings.isEmpty)
        XCTAssertTrue(preview.canConfirmImport)
    }
}

/// Exercises the production AppKit view without a window, focus changes or pasteboard access.
@MainActor
struct AudiobookImportTextViewTests {
    @Test func layoutSwitchesKeepOneReadOnlySelectableDocument() throws {
        let body = String(repeating: "        河岸上的行人踏著晨霧前行，遠處的燈火還未熄滅，街道仍然十分\r\n安靜。他停下腳步，望向河面。\r\n\r\n", count: 140)
        let bytes = Data(("第一章 晨行\r\n\r\n" + body + "第二章 夜行\r\n另一章的內容。").utf8)
        let preview = try AudiobookTXTImporter.prepare(rawData: bytes)
        let chapter = try #require(preview.chapters.first)
        let prepared = try preview.textPreview(for: chapter.id)
        let original = try preview.textPreview(for: chapter.id, originalLayout: true)
        #expect(prepared != original)
        #expect(original.unicodeScalars.count == AudiobookLimits.maxPreviewScalars)
        let scrollView = AudiobookImportTextView(text: prepared).makeScrollView()
        let viewport = NSSize(width: 420, height: SpeechRailDesignTokens.Layout.audiobookImportPreviewHeight)
        scrollView.setFrameSize(viewport)
        let document = try #require(scrollView.documentView as? NSTextView)
        let layoutManager = try #require(document.textLayoutManager)
        let contentManager = try #require(layoutManager.textContentManager)

        for _ in 0..<20 {
            for text in [original, prepared] {
                AudiobookImportTextView(text: text).updateText(in: scrollView)
                scrollView.layoutSubtreeIfNeeded()
                layoutManager.ensureLayout(for: contentManager.documentRange)
                #expect(scrollView.documentView === document)
                #expect(scrollView.frame.size == viewport)
                #expect(document.frame.width > 0)
                #expect(document.frame.width <= scrollView.contentSize.width)
                #expect(document.string == text)
                #expect(document.isEditable == false)
                #expect(document.isSelectable)
                #expect(document.isHorizontallyResizable == false)
                #expect(document.textContainer?.widthTracksTextView == true)
            }
        }
        let lastChapter = try #require(preview.chapters.last)
        let lastText = try preview.textPreview(for: lastChapter.id, originalLayout: true)
        AudiobookImportTextView(text: lastText).updateText(in: scrollView)
        #expect(document.string == lastText)
        #expect(document.selectedRange() == NSRange(location: 0, length: 0))
        #expect(preview.originalBytes == bytes)
        #expect(preview.canonicalUTF8 == bytes)
    }

    @Test func unrelatedUpdatesPreserveSelectionAndEmptyContentClearsIt() throws {
        let text = "可以选择和复制的正文。"
        let preview = AudiobookImportTextView(text: text)
        let scrollView = preview.makeScrollView()
        let document = try #require(scrollView.documentView as? NSTextView)
        let selection = NSRange(location: 2, length: 4)
        document.setSelectedRange(selection)
        preview.updateText(in: scrollView)
        #expect(document.selectedRange() == selection)
        AudiobookImportTextView(text: "").updateText(in: scrollView)
        #expect(document.string.isEmpty)
        #expect(document.selectedRange() == NSRange(location: 0, length: 0))
    }
}
