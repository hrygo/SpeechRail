import Foundation
import SQLite3
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 用户暂停（方案 MC-16）：暂停前后不拼句、停记区间可追溯。
///
/// 界面侧的三态分离（静音麦克风 / 暂停全部 / 结束）在 MA-10 已覆盖；这里钉的是
/// 此前**落库层完全没有**的两件事：
///
/// - 暂停要落一段 `user_paused` 区间、恢复时合上。不记的话，事后看这条记录的人
///   会把中间那几分钟当成安静，而那段时间一个字都没录上——这是**假的完整**。
/// - 暂停按 id 合区间，不按会话合。暂停期间又出故障时同一会话有两条未闭合区间，
///   按会话合会把暂停的那段一起算到故障恢复的时刻。
///
/// 断句本身（暂停切的那一刀只提交、不清缓冲、不结束分人）由 `RealtimeContractTests`
/// 从线路侧钉住——那是"不拼句"的物理前提，界面层再对也补不了。
@MainActor
final class MeetingPauseIntervalTests: XCTestCase {
    private var directory: URL?
    private var store: SessionStore?

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        self.directory = directory
        self.store = store
    }

    override func tearDown() async throws {
        if let store { await store.close() }
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func requireStore() throws -> SessionStore {
        try XCTUnwrap(store)
    }

    private func makeSession(_ store: SessionStore) async throws -> String {
        let record = try await store.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone, title: "暂停评审")
        )
        return record.id
    }

    // MARK: - 库层：区间可追溯

    /// 暂停落成一段能读回来的区间，且**明确不是故障**：用户主动为之不该混进
    /// 「设备掉了」那一堆里，那一堆是要追查的。
    func testPausedIntervalIsTraceableAndIsNotAFault() async throws {
        let store = try requireStore()
        let sessionID = try await makeSession(store)

        _ = try await store.markInterruption(sessionID: sessionID, atOrdinal: 7, reason: .userPaused)
        let rows = try await store.interruptions(sessionID: sessionID)

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.reason, .userPaused)
        XCTAssertEqual(row.atOrdinal, 7, "停记区间从暂停那一刻的水位起算")
        XCTAssertNil(row.resumedAt, "还没恢复就不该有恢复时刻")
        XCTAssertFalse(
            SessionInterruptionReason.userPaused.isFault,
            "用户自己按的暂停不是故障，混进故障那一堆会让排查口径失真"
        )
        XCTAssertEqual(SessionInterruptionReason.userPaused.title, "你暂停了记录")
    }

    /// 按 id 合只动那一条：暂停期间又出故障时，两条区间要各自算各自的时间。
    /// 这一条是 `closeInterruption(id:)` 存在的全部理由——按会话合的那个会把
    /// 暂停的那段错算到故障恢复的时刻，停记区间就不再是用户实际按下的那段时间。
    func testClosingByIDLeavesTheOtherOpenIntervalOpen() async throws {
        let store = try requireStore()
        let sessionID = try await makeSession(store)

        let pauseID = try await store.markInterruption(
            sessionID: sessionID, atOrdinal: 3, reason: .userPaused
        )
        _ = try await store.markInterruption(
            sessionID: sessionID, atOrdinal: 5, reason: .sourceLost
        )

        try await store.closeInterruption(id: pauseID)
        let rows = try await store.interruptions(sessionID: sessionID)

        let paused = try XCTUnwrap(rows.first { $0.reason == .userPaused })
        let fault = try XCTUnwrap(rows.first { $0.reason == .sourceLost })
        XCTAssertNotNil(paused.resumedAt, "恢复记录时合上的应该就是暂停那一条")
        XCTAssertNil(
            fault.resumedAt,
            "故障区间还没恢复，不能被暂停的恢复顺手合上"
        )
        XCTAssertTrue(SessionInterruptionReason.sourceLost.isFault, "设备掉了是要追查的")
    }

    /// 重复合只认第一次：第二次恢复不能把已经定下的结束时刻改掉，
    /// 否则停记区间的长度会随界面多点几下而变。
    func testClosingByIDTwiceKeepsTheFirstResumeTime() async throws {
        let store = try requireStore()
        let sessionID = try await makeSession(store)
        let pauseID = try await store.markInterruption(
            sessionID: sessionID, atOrdinal: 1, reason: .userPaused
        )

        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_009_999)
        try await store.closeInterruption(id: pauseID, resumedAt: first)
        try await store.closeInterruption(id: pauseID, resumedAt: later)

        let rows = try await store.interruptions(sessionID: sessionID)
        let row = try XCTUnwrap(rows.first)
        let resumedAt = try XCTUnwrap(row.resumedAt)
        XCTAssertEqual(
            resumedAt.timeIntervalSince1970, first.timeIntervalSince1970, accuracy: 0.001,
            "恢复时刻以第一次为准"
        )
    }

    // MARK: - 协调器：暂停不是中断

    /// 暂停**不得**走中断那条路：中断会切 `.interrupted` 并释放设备，
    /// 对应的是"设备真的掉了"。走那条路等于把"我先歇会儿"记成设备故障，
    /// 还会顺手把这一场的音频放掉。
    func testUserPauseKeepsRecordingAndDeviceLease() async throws {
        let store = try requireStore()
        let coordinator = SessionCoordinator(store: store, defaults: makeDefaults())
        await coordinator.openStore()
        try await beginMeeting(coordinator)

        let leaseBefore = coordinator.activeLeaseID
        await coordinator.markUserPaused()

        XCTAssertEqual(coordinator.phase, .recording, "暂停不是中断，相位必须还在录")
        XCTAssertEqual(coordinator.activeLeaseID, leaseBefore, "暂停不释放设备租约")
        XCTAssertNil(coordinator.lastInterruption, "暂停不该被记成一次故障")
        XCTAssertNotNil(coordinator.activeSessionID)

        let sessionID = try XCTUnwrap(coordinator.activeSessionID)
        let rows = try await store.interruptions(sessionID: sessionID)
        XCTAssertEqual(rows.map(\.reason), [.userPaused], "但停记区间必须落库")
    }

    /// 界面上按一次是一个动作。两段重叠的暂停区间会让恢复时合到错的那一条。
    func testRepeatedUserPauseRecordsOnlyOneInterval() async throws {
        let store = try requireStore()
        let coordinator = SessionCoordinator(store: store, defaults: makeDefaults())
        await coordinator.openStore()
        try await beginMeeting(coordinator)

        let first = await coordinator.markUserPaused()
        let second = await coordinator.markUserPaused()
        XCTAssertEqual(first, second, "重复暂停返回同一条区间")

        let sessionID = try XCTUnwrap(coordinator.activeSessionID)
        let rows = try await store.interruptions(sessionID: sessionID)
        XCTAssertEqual(rows.count, 1, "一次暂停只记一段")
    }

    /// 恢复记录 = 合上那一段。合完再恢复不会多出区间，区间长度就是用户实际停记的时间。
    func testResumeClosesThePauseInterval() async throws {
        let store = try requireStore()
        let coordinator = SessionCoordinator(store: store, defaults: makeDefaults())
        await coordinator.openStore()
        try await beginMeeting(coordinator)
        let sessionID = try XCTUnwrap(coordinator.activeSessionID)

        await coordinator.markUserPaused()
        await coordinator.resumeUserPaused()

        let rows = try await store.interruptions(sessionID: sessionID)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.reason, .userPaused)
        XCTAssertNotNil(row.resumedAt, "恢复之后这段停记就该有终点")

        await coordinator.resumeUserPaused()
        let again = try await store.interruptions(sessionID: sessionID)
        XCTAssertEqual(again.count, 1, "重复恢复不再多记区间")
    }

    /// 暂停中直接结束会议：区间必须在封存**之前**合上，否则归档包里会带一条
    /// `resumed_at` 为空的暂停记录，事后读出来像是「录到一半没恢复」。
    func testFinalizeWhilePausedClosesTheInterval() async throws {
        let store = try requireStore()
        let coordinator = SessionCoordinator(store: store, defaults: makeDefaults())
        await coordinator.openStore()
        try await beginMeeting(coordinator)
        let sessionID = try XCTUnwrap(coordinator.activeSessionID)
        await coordinator.markUserPaused()

        await coordinator.finalize(reason: .user)

        let rows = try await store.interruptions(sessionID: sessionID)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.reason, .userPaused)
        XCTAssertNotNil(row.resumedAt, "收尾就是这段停记的终点，不能留空")
    }

    // MARK: - 辅助

    // MARK: - 认不出的 reason

    /// 老程序打开新库（验收 1「不得跨会议写入」的同族问题：别把读不懂当成没有）。
    ///
    /// 这一版程序没写过的 `reason` 值，一定来自更新的程序。此前 `interruptions` 用
    /// `guard let … else { continue }` 把这样的行**整条丢掉**，界面上那段没录上的
    /// 时间就凭空消失，用户看到的是"全程都录上了"——恰好是在最不该含糊的地方含糊。
    func testUnknownReasonIsKeptAsUnknownInsteadOfDropped() async throws {
        let store = try requireStore()
        let sessionID = try await makeSession(store)
        try insertRawInterruption(
            sessionID: sessionID,
            atOrdinal: 3,
            reason: "audio_source_rotated"
        )

        let rows = try await store.interruptions(sessionID: sessionID)
        let row = try XCTUnwrap(
            rows.first,
            "认不出的 reason 也必须占一行；丢掉等于谎称这段录上了"
        )
        XCTAssertEqual(row.atOrdinal, 3)
        XCTAssertEqual(row.reason, .unknown)
        XCTAssertTrue(
            row.reason.isFault,
            "原因不明可能藏着真实故障，不能因为读不懂就当作不是问题"
        )
        XCTAssertFalse(
            row.reason.title.isEmpty,
            "界面得有话可说，不能把这一段显示成没有发生"
        )
    }

    /// 摘要里的 `openInterruption` 走的是另一条解码路径，同样不能把未知读成"没中断"。
    func testSummaryKeepsAnUnclosedUnknownReason() async throws {
        let store = try requireStore()
        let sessionID = try await makeSession(store)
        try insertRawInterruption(
            sessionID: sessionID,
            atOrdinal: 5,
            reason: "future_interruption_kind"
        )

        let summaries = try await store.listSessions(kind: .meeting)
        let summary = try XCTUnwrap(summaries.first { $0.record.id == sessionID })
        XCTAssertEqual(
            summary.openInterruption, .unknown,
            "未闭合的未知区间仍然是未闭合，不能显示成没中断"
        )
    }

    /// 认得的取值照旧按原义解析——新分支不能反过来改坏老数据。
    func testKnownReasonsStillDecodeToThemselves() {
        XCTAssertEqual(SessionInterruptionReason(reading: "service_lost"), .serviceLost)
        XCTAssertEqual(SessionInterruptionReason(reading: "sleep"), .sleep)
        XCTAssertEqual(SessionInterruptionReason(reading: "source_lost"), .sourceLost)
        XCTAssertEqual(SessionInterruptionReason(reading: "unexpected_exit"), .unexpectedExit)
        XCTAssertEqual(SessionInterruptionReason(reading: "user_paused"), .userPaused)
        XCTAssertEqual(
            SessionInterruptionReason(reading: nil), .unknown,
            "空 reason 也当原因不明，不能当作没有"
        )
    }

    private func insertRawInterruption(sessionID: String, atOrdinal: Int, reason: String) throws {
        let file = try XCTUnwrap(directory).appendingPathComponent(SessionStore.fileName)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw SessionStoreError.storageUnavailable
        }
        defer { sqlite3_close_v2(pointer) }
        // 直接写一个这一版程序不可能写出的 reason，模拟"更新的程序写了新值"。
        let sql = """
        INSERT INTO session_interruption (id, session_id, at_ordinal, reason, resumed_at, created_at)
        VALUES ('\(UUID().uuidString)', '\(sessionID)', \(atOrdinal), '\(reason)', NULL,
                \(Date().timeIntervalSince1970));
        """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(pointer, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(error)
            XCTFail("写入原始停记区间失败：\(detail)")
            return
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "meeting-pause-\(UUID().uuidString)"
        return UserDefaults(suiteName: name) ?? .standard
    }

    private func beginMeeting(_ coordinator: SessionCoordinator) async throws {
        try await coordinator.begin(.meeting)
        let record = try await coordinator.createSession(
            SessionDraft(kind: .meeting, engineProfile: "test", audioSource: .microphone)
        )
        coordinator.sessionDidStartRecording(id: record.id)
    }
}
