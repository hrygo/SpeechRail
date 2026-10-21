import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AudiobookSourceTests: XCTestCase {
    func testLiteralSourceMappingRequiresIdenticalUTF8RatherThanCanonicalEquivalence() throws {
        let working = try AudiobookSourceIndex(utf8: Data("café".utf8))
        let reference = try AudiobookSourceIndex(utf8: Data("cafe\u{0301}".utf8))
        let map: [AudiobookWorkingSourceSpan] = [.init(workingRange: working.wholeRange, referenceRange: reference.wholeRange, isGenerated: false)]
        XCTAssertThrowsError(try AudiobookChapterTextEditing.validateMap(map, working: working, reference: reference))
    }

    func testManualChapterReplacementClipsGeneratedMapAndKeepsLayout() throws {
        let reference = try AudiobookSourceIndex(utf8: Data("甲\r\n\r\n乙".utf8))
        let prepared = try AudiobookTextPreparation.prepare(referenceUTF8: reference.utf8Data)
        let source = try prepared.sourceIndex()
        XCTAssertEqual(String(decoding: source.utf8Data, as: UTF8.self), "甲\n\n乙")
        let bookID = UUID(), oldID = UUID(), newID = UUID()
        let chapters = [
            AudiobookChapter(bookID: bookID, sourceID: oldID, ordinal: 0, title: "自定甲", sourceRange: .init(lowerBound: 0, upperBound: 4), isSkipped: true),
            AudiobookChapter(bookID: bookID, sourceID: oldID, ordinal: 1, title: "自定乙", sourceRange: .init(lowerBound: 4, upperBound: source.byteCount))
        ]
        let result = try AudiobookChapterTextEditing.replacing(source: source, map: prepared.sourceMap, chapters: chapters,
            chapterID: chapters[1].id, title: "新乙", body: "用户👋e\u{0301}\n\n正文。", newSourceID: newID)
        let updated = try result.text.sourceIndex()
        try AudiobookChapterTextEditing.validateMap(result.text.sourceMap, working: updated, reference: reference)
        XCTAssertEqual(try updated.text(in: result.chapters[0].sourceRange), "甲\n")
        XCTAssertTrue(result.chapters[0].isSkipped)
        XCTAssertEqual(result.chapters.map(\.title), ["自定甲", "新乙"])
        XCTAssertTrue(result.text.sourceMap.contains { $0.isUserEdited == true })
        let twice = try AudiobookChapterTextEditing.replacing(source: updated, map: result.text.sourceMap, chapters: result.chapters,
            chapterID: result.chapters[0].id, title: "再甲", body: "短。", newSourceID: UUID())
        try AudiobookChapterTextEditing.validateMap(twice.text.sourceMap, working: twice.text.sourceIndex(), reference: reference)
        XCTAssertThrowsError(try AudiobookChapterTextEditing.replacing(source: source, map: prepared.sourceMap, chapters: chapters,
            chapterID: chapters[0].id, title: "甲", body: "超预算。", newSourceID: UUID(), maxBytes: 2))
        XCTAssertThrowsError(try AudiobookChapterTextEditing.replacing(source: source, map: prepared.sourceMap, chapters: chapters,
            chapterID: chapters[0].id, title: "甲", body: "超预算。", newSourceID: UUID(), maxScalars: 1))
    }

    func testScalarBoundariesAndLiteralReplacementCharacter() throws {
        let originalText = "第1章 雾港\r\n“你也看见灯了？”👩‍👩‍👧‍👦 café e\u{0301} 原文含\u{FFFD}符号。\n第二行。"
        let utf8 = Data(originalText.utf8)
        let index = try AudiobookSourceIndex(utf8: utf8)
        let wholeRange = AudiobookSourceRange(lowerBound: 0, upperBound: Int64(utf8.count))

        XCTAssertEqual(try index.text(in: wholeRange), originalText)

        // Slicing inside a multi-byte UTF-8 scalar ("第" is 3 bytes at 0..<3) must throw.
        let midScalarRange = AudiobookSourceRange(lowerBound: 1, upperBound: Int64(utf8.count))
        XCTAssertThrowsError(try index.text(in: midScalarRange)) { error in
            XCTAssertEqual(error as? AudiobookSourceError, .nonScalarBoundary(1))
        }

        // Building atoms must preserve exact coverage and never slice inside a scalar.
        let chapter = AudiobookChapter(
            bookID: UUID(),
            sourceID: UUID(),
            ordinal: 0,
            title: "第1章 雾港",
            sourceRange: wholeRange
        )
        let atoms = try index.buildAtoms(for: chapter, maxAtomScalars: 12)
        XCTAssertFalse(atoms.isEmpty)
        try index.validateCoverage(atoms.map(\.sourceRange), exclusions: [])

        let reconstructed = try atoms.map { try index.text(in: $0.sourceRange) }.joined()
        XCTAssertEqual(reconstructed, originalText)
    }

    func testCoverageRejectsHoleOverlapAndDuplicate() throws {
        let originalText = "甲乙丙丁戊己庚辛壬癸"
        let utf8 = Data(originalText.utf8)
        let index = try AudiobookSourceIndex(utf8: utf8)
        let total = Int64(utf8.count) // 10 CJK chars = 30 bytes

        let first = AudiobookSourceRange(lowerBound: 0, upperBound: 12)
        let secondWithHole = AudiobookSourceRange(lowerBound: 15, upperBound: total)
        XCTAssertThrowsError(try index.validateCoverage([first, secondWithHole], exclusions: []))

        let overlappingRanges = [
            AudiobookSourceRange(lowerBound: 0, upperBound: 15),
            AudiobookSourceRange(lowerBound: 12, upperBound: total),
        ]
        XCTAssertThrowsError(try index.validateCoverage(overlappingRanges, exclusions: []))

        let duplicateRanges = [
            AudiobookSourceRange(lowerBound: 0, upperBound: 15),
            AudiobookSourceRange(lowerBound: 0, upperBound: 15),
            AudiobookSourceRange(lowerBound: 15, upperBound: total),
        ]
        XCTAssertThrowsError(try index.validateCoverage(duplicateRanges, exclusions: []))

        // Explicit exclusion covers the gap [12, 15), making coverage valid.
        let explicitExclusion = AudiobookSourceRange(lowerBound: 12, upperBound: 15)
        XCTAssertNoThrow(try index.validateCoverage([first, secondWithHole], exclusions: [explicitExclusion]))
    }

    func testHardWrappedNovelTextSegmentation() throws {
        let sample = """
話表齊天大聖到底是個妖猴，更不知官銜品從，也不較俸祿高低，但只註名便
了。那齊天府下二司仙吏，早晚伏侍，只知日食三餐，夜眠一榻，無事牽縈，
自由自在。
"""
        let utf8 = Data(sample.utf8)
        let index = try AudiobookSourceIndex(utf8: utf8)
        let chapter = AudiobookChapter(
            bookID: UUID(),
            sourceID: UUID(),
            ordinal: 0,
            title: "第五回",
            sourceRange: index.wholeRange
        )

        let atoms = try index.buildAtoms(for: chapter, layoutProfile: .hardWrapped)
        try index.validateCoverage(atoms.map(\.sourceRange), exclusions: [])

        let nonFormattingAtoms = atoms.filter { $0.kind != .formatting }
        XCTAssertEqual(nonFormattingAtoms.count, 2)

        let text1 = try index.text(in: nonFormattingAtoms[0].sourceRange)
        XCTAssertTrue(text1.contains("但只註名便\n了。"))
        XCTAssertEqual(AudiobookSourceIndex.displayNormalizedText(text1), "話表齊天大聖到底是個妖猴，更不知官銜品從，也不較俸祿高低，但只註名便了。")

        let text2 = try index.text(in: nonFormattingAtoms[1].sourceRange)
        XCTAssertTrue(text2.contains("無事牽縈，\n自由自在。"))
    }

    func testInlineQuoteDoesNotSplitNonDialogue() throws {
        let sample = "見三清稱個「老」字，逢四帝道個「陛下」。"
        let utf8 = Data(sample.utf8)
        let index = try AudiobookSourceIndex(utf8: utf8)
        let chapter = AudiobookChapter(
            bookID: UUID(),
            sourceID: UUID(),
            ordinal: 0,
            title: "第五回",
            sourceRange: index.wholeRange
        )
        let atoms = try index.buildAtoms(for: chapter)
        try index.validateCoverage(atoms.map(\.sourceRange), exclusions: [])

        let nonFormatting = atoms.filter { $0.kind != .formatting }
        XCTAssertEqual(nonFormatting.count, 1)
        XCTAssertEqual(try index.text(in: nonFormatting[0].sourceRange), sample)
    }

    func testRapidFireDialogueDoesNotMerge() throws {
        let sample = """
“你去？”
“我去。”
“何时走？”
“现在。”
"""
        let utf8 = Data(sample.utf8)
        let index = try AudiobookSourceIndex(utf8: utf8)
        let chapter = AudiobookChapter(
            bookID: UUID(),
            sourceID: UUID(),
            ordinal: 0,
            title: "对白",
            sourceRange: index.wholeRange
        )
        let atoms = try index.buildAtoms(for: chapter)
        try index.validateCoverage(atoms.map(\.sourceRange), exclusions: [])

        let nonFormatting = atoms.filter { $0.kind != .formatting }
        XCTAssertEqual(nonFormatting.count, 4)
        let texts = try nonFormatting.map { try index.text(in: $0.sourceRange).trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(texts, ["“你去？”", "“我去。”", "“何时走？”", "“现在。”"])
    }

    func testDialogueIntroducedBySpeechVerbSplitsCleanly() throws {
        let sample = "猴王道：「你知那三等人？」猿猴道：「乃是佛與仙。」"
        let utf8 = Data(sample.utf8)
        let index = try AudiobookSourceIndex(utf8: utf8)
        let chapter = AudiobookChapter(
            bookID: UUID(),
            sourceID: UUID(),
            ordinal: 0,
            title: "第一回",
            sourceRange: index.wholeRange
        )
        let atoms = try index.buildAtoms(for: chapter)
        try index.validateCoverage(atoms.map(\.sourceRange), exclusions: [])

        let nonFormatting = atoms.filter { $0.kind != .formatting }
        XCTAssertEqual(nonFormatting.count, 4)
        let texts = try nonFormatting.map { try index.text(in: $0.sourceRange) }
        XCTAssertEqual(texts[0], "猴王道：")
        XCTAssertEqual(texts[1], "「你知那三等人？」")
        XCTAssertEqual(texts[2], "猿猴道：")
        XCTAssertEqual(texts[3], "「乃是佛與仙。」")
    }

    func testNaturalLongParagraphSegmentation() throws {
        let sample = "他推开门，冷风吹了进来。房间里空无一人，桌上留着一张纸条。他拿起来看了一眼，脸色微变。"
        let utf8 = Data(sample.utf8)
        let index = try AudiobookSourceIndex(utf8: utf8)
        let chapter = AudiobookChapter(
            bookID: UUID(),
            sourceID: UUID(),
            ordinal: 0,
            title: "第1章",
            sourceRange: index.wholeRange
        )
        let atoms = try index.buildAtoms(for: chapter)
        try index.validateCoverage(atoms.map(\.sourceRange), exclusions: [])

        let nonFormatting = atoms.filter { $0.kind != .formatting }
        XCTAssertEqual(nonFormatting.count, 3)
    }

    func testDisplayNormalizedTextRemovesSoftLineBreaksBetweenCJK() throws {
        let text1 = "但只註名便\n了。"
        XCTAssertEqual(AudiobookSourceIndex.displayNormalizedText(text1), "但只註名便了。")

        let text2 = "五方五老\r\n、普天星相"
        XCTAssertEqual(AudiobookSourceIndex.displayNormalizedText(text2), "五方五老、普天星相")

        let text3 = "Hello\nWorld"
        XCTAssertEqual(AudiobookSourceIndex.displayNormalizedText(text3), "Hello World")
    }

    func testPreparedParagraphRangesCoverCRLFAndPreserveSpeakerBoundaries() throws {
        let text = "\r\n    他站在門邊，聽見了一陣腳步聲，便順著窗外的微弱燈光望\r\n向遠方。\r\n\r\n    “誰在那裡？”\r\n    “是我。”\r\n\r\n"
        let source = try AudiobookSourceIndex(utf8: Data(text.utf8))
        XCTAssertEqual(source.paragraphs.count, 3)
        XCTAssertEqual(source.joinedLineBreakCount, 1)
        try source.validateCoverage(source.paragraphs.map(\.sourceRange), exclusions: [])
        XCTAssertEqual(try source.normalizedText(in: source.wholeRange), "他站在門邊，聽見了一陣腳步聲，便順著窗外的微弱燈光望向遠方。\n\n“誰在那裡？”\n\n“是我。”")
        let marker = try XCTUnwrap(source.utf8Data.range(of: Data("望".utf8)))
        let end = try XCTUnwrap(source.utf8Data.range(of: Data("向遠方。".utf8)))
        XCTAssertEqual(try source.normalizedText(in: .init(lowerBound: Int64(marker.lowerBound), upperBound: Int64(end.upperBound))), "望向遠方。")
        let chapter = AudiobookChapter(bookID: UUID(), sourceID: UUID(), ordinal: 0, title: "全文", sourceRange: source.wholeRange)
        let atoms = try source.buildAtoms(for: chapter)
        try source.validateCoverage(atoms.map(\.sourceRange), exclusions: [])
        XCTAssertFalse(try atoms.contains { try source.text(in: $0.sourceRange).trimmingCharacters(in: .whitespacesAndNewlines) == "向遠方。" })
    }

    func testCRLFAfterSentenceBoundaryKeepsEveryAtomWithinScalarBudget() throws {
        let cases: [(text: String, budget: Int)] = [
            (String(repeating: "甲", count: 158) + "。\r\n乙", 160),
            ("甲乙。\r\n丙", 4),
        ]

        for (text, budget) in cases {
            let source = try AudiobookSourceIndex(utf8: Data(text.utf8))
            let chapter = AudiobookChapter(
                bookID: UUID(),
                sourceID: UUID(),
                ordinal: 0,
                title: "全文",
                sourceRange: source.wholeRange
            )
            let atoms = try source.buildAtoms(for: chapter, maxAtomScalars: budget)

            try source.validateCoverage(atoms.map(\.sourceRange), exclusions: [])
            for atom in atoms {
                let start = try XCTUnwrap(source.scalarIndex(forByteOffset: atom.sourceRange.lowerBound))
                let end = try XCTUnwrap(source.scalarIndex(forByteOffset: atom.sourceRange.upperBound))
                XCTAssertLessThanOrEqual(end - start, budget, "预算 \(budget) 不应被 CRLF 越过")
            }
            XCTAssertEqual(try atoms.map { try source.text(in: $0.sourceRange) }.joined(), text)
        }
    }

    func testNormalizedTextPreservesLiteralReplacementCharacter() throws {
        let rawText = "三叔叹了口气：\u{FFFD}“这水底下的东西，怕是不简单。”\r\n潘子握紧了刀。"
        let utf8 = Data(rawText.utf8)
        let source = try AudiobookSourceIndex(utf8: utf8)

        // Raw slice preserves exact UTF-8 bytes and literal replacement character
        XCTAssertEqual(try source.text(in: source.wholeRange), rawText)

        // Literal U+FFFD is content, not a decode error or an instruction to delete it.
        let normalized = try source.normalizedText(in: source.wholeRange)
        XCTAssertTrue(normalized.contains("\u{FFFD}"))
        XCTAssertTrue(normalized.contains("三叔叹了口气：\u{FFFD}“这水底下的东西，怕是不简单。”"))
        XCTAssertEqual(
            AudiobookSourceIndex.displayNormalizedText("第2章\u{FFFD} 七星鲁王宫"),
            "第2章\u{FFFD} 七星鲁王宫"
        )
    }
}
