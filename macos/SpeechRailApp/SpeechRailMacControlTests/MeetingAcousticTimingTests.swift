import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 声学时间回填的持久化（MA-02 / MC-15）。
///
/// 钉的是"标了 aligned 就必须真的有对齐值"：方案点名要修的那条路是
/// 只改标签、不验证值——那样等于把谎报盖了个"已校准"的章。
@MainActor
final class MeetingAcousticTimingTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-acoustic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        self.directory = directory
        self.store = store
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        store = nil
        directory = nil
        try await super.tearDown()
    }

    private func seedLine(
        text: String = "一句话",
        start: TimeInterval = 3,
        end: TimeInterval = 9,
        quality: SessionTimingQuality = .unavailable
    ) async throws -> (sessionID: String, lineID: String) {
        let store = try XCTUnwrap(store)
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        let lineID = UUID().uuidString
        try await store.appendLine(
            LineDraft(
                sessionID: record.id,
                role: .speaker,
                text: text,
                source: .microphone,
                speakerLabel: nil,
                tStart: start,
                tEnd: end,
                isDeviceSwitch: false,
                timingQuality: quality
            ),
            id: lineID
        )
        return (record.id, lineID)
    }

    /// 取回一行。`await` 不能出现在 `XCTUnwrap` 的自动闭包里，所以先取数组。
    private func fetchLine(sessionID: String, lineID: String) async throws -> TranscriptLine {
        let store = try XCTUnwrap(store)
        let rows = try await store.lines(sessionID: sessionID)
        return try XCTUnwrap(rows.first { $0.id == lineID })
    }

    func testAcousticTimingWritesValueAndQualityTogether() async throws {
        let store = try XCTUnwrap(store)
        let seeded = try await seedLine()
        try await store.attachAcousticTiming(
            lineID: seeded.lineID,
            start: 4.5,
            end: 8.25,
            quality: .aligned
        )
        let line = try await fetchLine(sessionID: seeded.sessionID, lineID: seeded.lineID)
        XCTAssertEqual(line.tStart, 4.5)
        XCTAssertEqual(line.tEnd, 8.25)
        XCTAssertEqual(line.timingQuality, .aligned)
    }

    func testAlignedLabelNeverLandsWithoutAnAcousticValue() async throws {
        let store = try XCTUnwrap(store)
        let seeded = try await seedLine(start: 3, end: 9)
        try await store.attachAcousticTiming(
            lineID: seeded.lineID,
            start: 4.5,
            end: 8.25,
            quality: .aligned
        )
        let line = try await fetchLine(sessionID: seeded.sessionID, lineID: seeded.lineID)
        // 标签与值必须同时变——不存在"只标了 aligned、值还是接收间隔"的行。
        XCTAssertNotEqual(line.tStart, 3)
        XCTAssertNotEqual(line.tEnd, 9)
    }

    func testAcousticBackfillLeavesTextAndOrdinalAlone() async throws {
        let store = try XCTUnwrap(store)
        let seeded = try await seedLine(text: "不许被改动的正文")
        let before = try await fetchLine(sessionID: seeded.sessionID, lineID: seeded.lineID)
        try await store.attachAcousticTiming(
            lineID: seeded.lineID, start: 1, end: 2, quality: .aligned
        )
        let after = try await fetchLine(sessionID: seeded.sessionID, lineID: seeded.lineID)
        XCTAssertEqual(after.text, "不许被改动的正文")
        XCTAssertEqual(after.ordinal, before.ordinal)
        XCTAssertEqual(after.createdAt, before.createdAt)
    }

    func testBackfillOfMissingLineIsANoOpNotACrash() async throws {
        let store = try XCTUnwrap(store)
        // 迟到的对齐结果打到一行已经被删掉的记录上：不能抛。
        try await store.attachAcousticTiming(
            lineID: UUID().uuidString, start: 1, end: 2, quality: .aligned
        )
    }

    func testBackfillSurvivesReopen() async throws {
        let store = try XCTUnwrap(store)
        let seeded = try await seedLine()
        try await store.attachAcousticTiming(
            lineID: seeded.lineID, start: 4.5, end: 8.25, quality: .aligned
        )
        try await store.close()
        try await store.open()
        let line = try await fetchLine(sessionID: seeded.sessionID, lineID: seeded.lineID)
        XCTAssertEqual(line.timingQuality, .aligned)
        XCTAssertEqual(line.tStart, 4.5)
    }
}
