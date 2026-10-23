import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 章节时间表回归：只覆盖纯格式化、投影与写盘边界，不启动编码器也不接触真实音频。
/// 真实媒体章节与时间表的一致性由 `AudiobookExportTests` 的隔离 M4B 夹具负责。
final class AudiobookChapterTimelineTests: XCTestCase {
    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookChapterTimelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private let sampleRate = 48_000

    private func makeTimeline(
        _ chapters: [(String, Int64)]
    ) throws -> AudiobookChapterTimeline {
        try AudiobookChapterTimeline(
            chapters: chapters.map { (title: $0.0, frameCount: $0.1) },
            sampleRate: sampleRate
        )
    }

    // MARK: - 时间轴

    func testTimelineStartsAtZeroAndAccumulatesActualFrames() throws {
        let timeline = try makeTimeline([
            ("第一章 启航", 48_000),
            ("第二章 远洋", 96_000),
            ("第三章 归途", 72_000)
        ])

        XCTAssertEqual(
            timeline.text,
            """
            00:00:00\t第一章 启航
            00:00:01\t第二章 远洋
            00:00:03\t第三章 归途
            """
        )
        XCTAssertEqual(timeline.entries.map(\.startFrame), [0, 48_000, 144_000])
        XCTAssertEqual(timeline.entries.first?.startSeconds, 0, "首章必须从零开始")
    }

    func testTimelineDoesNotAccumulatePerChapterRoundingError() throws {
        // 每章 47999 帧（0.99998s）：逐章四舍五入会把第三章推到 00:00:03；
        // 按累计帧一次换算应停在 00:00:02。
        let timeline = try makeTimeline([
            ("甲", 47_999),
            ("乙", 47_999),
            ("丙", 47_999),
            ("丁", 47_999)
        ])

        XCTAssertEqual(timeline.entries.map(\.timecode), [
            "00:00:00", "00:00:00", "00:00:01", "00:00:02"
        ])
    }

    func testTimelineFloorsSubSecondBoundary() throws {
        let justUnderOneSecond = try makeTimeline([("甲", 47_999), ("乙", 1)])
        XCTAssertEqual(justUnderOneSecond.entries.map(\.timecode), ["00:00:00", "00:00:00"])

        let exactOneSecond = try makeTimeline([("甲", 48_000), ("乙", 48_000)])
        XCTAssertEqual(exactOneSecond.entries.map(\.timecode), ["00:00:00", "00:00:01"])
    }

    func testTimelineSupportsMoreThan24HoursWithoutWrapping() throws {
        let oneHour = Int64(sampleRate) * 3_600
        let timeline = try makeTimeline([
            ("第一天", oneHour * 23),
            ("第二天", oneHour * 1),
            ("第二天末", oneHour * 2)
        ])

        XCTAssertEqual(timeline.entries.map(\.timecode), ["00:00:00", "23:00:00", "24:00:00"])
        XCTAssertEqual(timeline.entries.last?.timecode, "24:00:00", "超过 24 小时不回绕成 00:00:00")
    }

    func testTimelineFlattensTabsAndNewlinesInTitles() throws {
        let timeline = try makeTimeline([
            ("第一章\t启航\r\n续行", 48_000),
            ("  两端留白  ", 48_000),
            ("\n\t", 48_000)
        ])

        XCTAssertEqual(timeline.entries.map(\.title), ["第一章 启航 续行", "两端留白", "第 3 章"])
        for line in timeline.text.split(separator: "\n") {
            XCTAssertEqual(line.split(separator: "\t").count, 2, "每行必须是时间码加单行标题")
        }
    }

    func testTimelineRejectsInvalidSampleRateOrFrames() {
        XCTAssertThrowsError(try AudiobookChapterTimeline(chapters: [("甲", 48_000)], sampleRate: 0))
        XCTAssertThrowsError(try AudiobookChapterTimeline(chapters: [], sampleRate: 48_000))
        XCTAssertThrowsError(try AudiobookChapterTimeline(chapters: [("甲", 0)], sampleRate: 48_000))
        XCTAssertThrowsError(
            try AudiobookChapterTimeline(chapters: [("甲", 48_000), ("乙", -1)], sampleRate: 48_000)
        )
    }

    func testTimecodeKeepsHoursUnbounded() {
        XCTAssertEqual(AudiobookChapterTimeline.timecode(seconds: 0), "00:00:00")
        XCTAssertEqual(AudiobookChapterTimeline.timecode(seconds: 3_599), "00:59:59")
        XCTAssertEqual(AudiobookChapterTimeline.timecode(seconds: 3_600), "01:00:00")
        XCTAssertEqual(AudiobookChapterTimeline.timecode(seconds: 360_000), "100:00:00")
    }

    // MARK: - 从导出结果投影

    func testPreparedExportProjectsOnlyExportedChaptersInOrder() throws {
        let bookID = UUID()
        let sourceID = UUID()
        let first = AudiobookChapter(
            bookID: bookID, sourceID: sourceID, ordinal: 0, title: "第一章",
            sourceRange: AudiobookSourceRange(lowerBound: 0, upperBound: 1)
        )
        let skipped = AudiobookChapter(
            bookID: bookID, sourceID: sourceID, ordinal: 1, title: "被跳过的章",
            sourceRange: AudiobookSourceRange(lowerBound: 1, upperBound: 2)
        )
        let third = AudiobookChapter(
            bookID: bookID, sourceID: sourceID, ordinal: 2, title: "第三章",
            sourceRange: AudiobookSourceRange(lowerBound: 2, upperBound: 3)
        )
        let prepared = AudiobookPreparedExport(
            requestID: UUID(),
            bookID: bookID,
            productionRevisionID: UUID(),
            profile: .m4b,
            bookTitle: "测试书",
            author: nil,
            exportedChapters: [third, first],
            omittedChapters: [
                AudiobookOmittedChapterRecord(
                    chapterID: skipped.id, chapterTitle: skipped.title, reason: "已按你的设置跳过"
                )
            ],
            stageURL: tempRoot.appendingPathComponent("stage.m4b"),
            expectedFrameCount: 144_000,
            expectedSampleRate: sampleRate,
            expectedChapterFrameCounts: [first.id: 48_000, third.id: 96_000]
        )

        let timeline = try prepared.makeChapterTimeline()
        XCTAssertEqual(
            timeline.text,
            """
            00:00:00\t第一章
            00:00:01\t第三章
            """
        )
        XCTAssertFalse(timeline.text.contains("被跳过的章"), "跳过的章节不得进入时间表")
    }

    func testPreparedExportWithoutFrameCountsFailsClosed() {
        let bookID = UUID()
        let chapter = AudiobookChapter(
            bookID: bookID, sourceID: UUID(), ordinal: 0, title: "第一章",
            sourceRange: AudiobookSourceRange(lowerBound: 0, upperBound: 1)
        )
        let prepared = AudiobookPreparedExport(
            requestID: UUID(),
            bookID: bookID,
            productionRevisionID: UUID(),
            profile: .m4b,
            bookTitle: "测试书",
            author: nil,
            exportedChapters: [chapter],
            omittedChapters: [],
            stageURL: tempRoot.appendingPathComponent("stage.m4b"),
            expectedFrameCount: 48_000,
            expectedSampleRate: sampleRate,
            expectedChapterFrameCounts: [:]
        )

        XCTAssertThrowsError(try prepared.makeChapterTimeline()) { error in
            guard case .verificationFailed = error as? AudiobookExportError else {
                return XCTFail("缺少章节时长时必须 fail closed，实际为：\(error)")
            }
        }
    }

    func testChapterMP3ProfileDoesNotOfferSingleFileTimeline() {
        let bookID = UUID()
        let chapter = AudiobookChapter(
            bookID: bookID, sourceID: UUID(), ordinal: 0, title: "第一章",
            sourceRange: AudiobookSourceRange(lowerBound: 0, upperBound: 1)
        )
        let prepared = AudiobookPreparedExport(
            requestID: UUID(),
            bookID: bookID,
            productionRevisionID: UUID(),
            profile: .chapterMP3,
            bookTitle: "测试书",
            author: nil,
            exportedChapters: [chapter],
            omittedChapters: [],
            stageURL: tempRoot.appendingPathComponent("stage", isDirectory: true),
            expectedFrameCount: 48_000,
            expectedSampleRate: sampleRate,
            expectedChapterFrameCounts: [chapter.id: 48_000]
        )

        XCTAssertThrowsError(try prepared.makeChapterTimeline()) { error in
            XCTAssertEqual(error as? AudiobookExportError, .timelineUnsupportedForProfile)
        }
    }

    // MARK: - 写盘

    func testWriterSavesExactlyTheCopiedText() throws {
        let timeline = try makeTimeline([("第一章", 48_000), ("第二章", 96_000)])
        let destination = tempRoot.appendingPathComponent("book-timeline.txt")

        try AudiobookChapterTimelineWriter.write(timeline, to: destination)

        let saved = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(saved, timeline.text)
        XCTAssertFalse(saved.hasSuffix("\n"), "复制与保存必须逐字一致，不额外附加空行")
    }

    func testWriterRequiresConsentBeforeReplacingAnExistingFile() throws {
        let timeline = try makeTimeline([("第一章", 48_000)])
        let destination = tempRoot.appendingPathComponent("book-timeline.txt")
        try Data("旧内容".utf8).write(to: destination)

        XCTAssertThrowsError(try AudiobookChapterTimelineWriter.write(timeline, to: destination)) { error in
            guard case .overwriteConsentRequired = error as? AudiobookExportError else {
                return XCTFail("已有同名文件时必须先取得覆盖确认，实际为：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "旧内容")

        let consent = try AudiobookOverwriteConsent.capture(at: destination)
        try AudiobookChapterTimelineWriter.write(timeline, to: destination, overwriteConsent: consent)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), timeline.text)
    }

    func testWriterRefusesToOverwriteAFileChangedAfterConsent() throws {
        let timeline = try makeTimeline([("第一章", 48_000)])
        let destination = tempRoot.appendingPathComponent("book-timeline.txt")
        try Data("旧内容".utf8).write(to: destination)
        let consent = try AudiobookOverwriteConsent.capture(at: destination)

        try Data("别人刚写的内容".utf8).write(to: destination)

        XCTAssertThrowsError(
            try AudiobookChapterTimelineWriter.write(timeline, to: destination, overwriteConsent: consent)
        ) { error in
            guard case .destinationModifiedAfterConsent = error as? AudiobookExportError else {
                return XCTFail("确认后被改动必须中止覆盖，实际为：\(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "别人刚写的内容")
    }

    func testWriterFailureLeavesExistingFileUntouched() throws {
        let timeline = try makeTimeline([("第一章", 48_000)])
        let destination = tempRoot.appendingPathComponent("missing-dir/book-timeline.txt")

        XCTAssertNoThrow(try AudiobookChapterTimelineWriter.write(timeline, to: destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "缺失父目录应被创建")
    }
}
