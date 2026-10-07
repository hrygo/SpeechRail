import Foundation
import SQLite3
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// VA-01 助手专属结束与租约隔离（F01 / A01/A02/A18）。
///
/// 打的是生产 `AssistantSession` + `SessionCoordinator`：
/// 文字结束按自己的 recordID 封存，不碰全局占用；
/// 语音结束核对 kind + leaseID + recordID，旧目标不得清新会话。
@MainActor
final class AssistantEndRoutingTests: XCTestCase {
    private func waitUntil(
        _ condition: () -> Bool,
        iterations: Int = 600,
        message: String = "condition was not met"
    ) async {
        for _ in 0..<iterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail(message)
    }

    private func makeStore() async throws -> (SessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assistant-end-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        try await store.open()
        return (store, directory)
    }

    private func makePreferences(defaults: UserDefaults) -> SessionPreferences {
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"
        return preferences
    }

    /// A01：纯文字场结束只封自己的记录，无占用、无设备、无连接。
    func testA01TextEndWithoutOccupancy() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-end-a01-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let preferences = makePreferences(defaults: defaults)
        let session = AssistantSession(coordinator: coordinator)
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        // 不注入 audio/realtime：纯文字路径若误触设备会直接崩或计数，避免假阳性。
        var micStartCount = 0
        session.audioSourceFactory = {
            micStartCount += 1
            return FakeTextOnlyAudio()
        }

        // 用 ask 经过统一文字建档：需要一个成功返回文字的 LLM。
        // 为避免依赖 AssistantSessionTests 的内部 Fake，这里直接走 Store 建一条文字记录
        // 再验证 endConversation 的目标封存语义（占用隔离是本用例核心）。
        let record = try await coordinator.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        )
        // 模拟已存在一场纯文字助手：无 occupancy、无 activeSessionID。
        XCTAssertNil(coordinator.occupancy)
        XCTAssertNil(coordinator.activeSessionID)

        // 旧路径复现：直接调全局 stopCapture 在无 occupancy 时是 no-op。
        await coordinator.stopCapture(endingWith: .user)
        let stillOpen = try await store.session(id: record.id)
        XCTAssertEqual(stillOpen?.state, .recording, "旧全局结束在无占用时是 no-op，应复现 F01")

        // 新路径：按 recordID 目标结束，必须封存自己的记录。
        let result = await coordinator.endAssistant(
            SessionCoordinator.AssistantEndTarget(recordID: record.id, leaseID: nil)
        )
        guard case .ended(let endedID) = result else {
            XCTFail("纯文字目标结束应返回 ended，实际 \(result)")
            return
        }
        XCTAssertEqual(endedID, record.id)
        let sealed = try await store.session(id: record.id)
        XCTAssertEqual(sealed?.state, .archived, "纯文字记录必须有终态")
        XCTAssertNil(coordinator.occupancy)
        XCTAssertNil(coordinator.activeSessionID)
        XCTAssertEqual(micStartCount, 0, "纯文字结束不该去拿麦克风")
    }

    /// A02：会议占用设备时，文字助手的结束不得改会议的占用/phase/记录/stopper。
    func testA02TextEndWhileMeetingOwnsLease() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-end-a02-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()

        var stopperCalls = 0
        coordinator.starter = { _ in }
        coordinator.stopper = { _ in stopperCalls += 1 }
        // 会议占用设备。
        try await coordinator.begin(.meeting)
        let leaseBefore = coordinator.activeLeaseID
        XCTAssertNotNil(leaseBefore)
        let meetingRecord = try await coordinator.createSession(
            SessionDraft(kind: .meeting, engineProfile: "unknown", audioSource: .microphone)
        )
        coordinator.sessionDidStartRecording(id: meetingRecord.id)
        let occupancyBefore = coordinator.occupancy
        let phaseBefore = coordinator.phase

        // 另一场纯文字助手的记录（不在 occupancy 里）。
        let textRecord = try await coordinator.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        )

        let result = await coordinator.endAssistant(
            SessionCoordinator.AssistantEndTarget(recordID: textRecord.id, leaseID: nil)
        )
        guard case .ended(let endedID) = result else {
            XCTFail("文字目标结束应返回 ended，实际 \(result)")
            return
        }
        XCTAssertEqual(endedID, textRecord.id)
        // 会议侧逐项不变。
        XCTAssertEqual(coordinator.occupancy, occupancyBefore, "会议占用不得被文字结束改变")
        XCTAssertEqual(coordinator.phase, phaseBefore)
        XCTAssertEqual(coordinator.activeSessionID, meetingRecord.id)
        XCTAssertEqual(coordinator.activeLeaseID, leaseBefore)
        XCTAssertEqual(stopperCalls, 0, "文字结束不得调会议的 stopper")
        let meetingAfter = try await store.session(id: meetingRecord.id)
        XCTAssertEqual(meetingAfter?.state, .recording, "会议记录不得被文字结束封存")
        let textAfter = try await store.session(id: textRecord.id)
        XCTAssertEqual(textAfter?.state, .archived, "文字自己的记录必须封存")
    }

    /// A18：重复结束共用同一任务；旧 lease 目标不得结束新会话。
    func testA18RepeatedAndReviewedEndTargets() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-end-a18-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        coordinator.starter = { _ in }
        coordinator.stopper = { _ in }

        // 第一场语音助手占用。
        try await coordinator.begin(.assistant)
        let leaseA = try XCTUnwrap(coordinator.activeLeaseID)
        let recordA = try await coordinator.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        )
        coordinator.sessionDidStartRecording(id: recordA.id)

        // 旧目标（leaseA + recordA）在新会话开始后仍被调用：先结束 A 再开始 B。
        await coordinator.finalize(reason: .user)
        try await coordinator.begin(.assistant)
        let leaseB = try XCTUnwrap(coordinator.activeLeaseID)
        XCTAssertNotEqual(leaseA, leaseB, "两场必须有不同租约身份")
        let recordB = try await coordinator.createSession(
            SessionDraft(kind: .assistant, engineProfile: "unknown", audioSource: .microphone)
        )
        coordinator.sessionDidStartRecording(id: recordB.id)

        let stale = await coordinator.endAssistant(
            SessionCoordinator.AssistantEndTarget(recordID: recordA.id, leaseID: leaseA)
        )
        XCTAssertEqual(stale, .superseded, "旧助手的迟到结束不得清掉新会话")
        XCTAssertEqual(coordinator.activeSessionID, recordB.id, "新会话的记录必须保留")
        XCTAssertEqual(coordinator.occupancy?.kind, .assistant)
        let recordBAfter = try await store.session(id: recordB.id)
        XCTAssertEqual(recordBAfter?.state, .recording)
    }

    /// A47（Session 层）：纯文字结束遇封存失败时不冒充 ended。
    ///
    /// 不存在的记录 → `sealSessionReporting` 返回 `.failed`：
    /// end 不发布虚假的已封存 ID，保留 pendingSeal 与失败原因，
    /// 界面走重试/复制出口。变异验证：改回 `sealSession` fire-and-forget
    /// 后本用例按预期失败（返回 ended 且无 pendingSeal）。
    func testA47TextEndSealFailureKeepsRecovery() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "assistant-end-a47-\(UUID().uuidString)"))
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        let preferences = makePreferences(defaults: defaults)
        let llm = AssistantSessionTests.FakeAssistantLLM(scripts: [.deltas(["回答。"])])
        let session = AssistantSession(
            coordinator: coordinator,
            dependencies: AssistantSessionDependencies(llm: llm)
        )
        session.preferences = { preferences }
        session.apiKeyProvider = { "test-key" }
        session.moduleAPIKeyProvider = { _ in nil }
        session.serviceReadiness = { .ready(profile: nil) }
        // 先 ask 建出纯文字场（isTextOnlyConversation=true），再删库记录
        // 伪造“封存时记录已丢失”：sealSessionReporting 必返回 .failed。
        _ = await session.ask(typed: "封存失败也不丢恢复出口")
        let recordID = try XCTUnwrap(session.sessionID)
        try await coordinator.removeSession(id: recordID)
        let result = await session.endConversation()
        guard case .noConversation = result else {
            XCTFail("封存失败不得冒充 ended，实际 \(result)")
            return
        }
        XCTAssertNil(session.lastFinalizedSessionID, "失败不得发布虚假的已封存 ID")
        XCTAssertEqual(session.pendingSealRecordID, recordID, "失败保留 pendingSeal 供重试")
        XCTAssertNotNil(session.pendingSealReason, "失败原因须保留供界面展示")
        XCTAssertNotNil(session.lastFailure, "失败须有用户可见提示")
        // 复制出口以内存 turns 为准：问题行仍在内存，可复制。
        XCTAssertTrue(
            session.unsavedTranscriptText().contains("封存失败也不丢恢复出口"),
            "未保存文本须可复制"
        )
        // 重试已删记录仍失败，不伪造成功。
        let retried = await session.retryPendingSeal()
        XCTAssertFalse(retried, "重试不存在的记录不得返回成功")
    }
}

/// 纯文字路径的占位音频源：若被误用会立刻计数，测试据此断言“没碰设备”。
private final class FakeTextOnlyAudio: AudioChunkSource, @unchecked Sendable {
    func start() async throws -> AsyncStream<AudioChunk> {
        throw NSError(domain: "AssistantEndRoutingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "纯文字不应启动采集"])
    }

    func stop() {}
}

@MainActor
final class SessionSealContractTests: XCTestCase {
    private var directory: URL!
    private var store: SessionStore!
    private var coordinator: SessionCoordinator!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-seal-\(UUID().uuidString)", isDirectory: true)
        store = SessionStore(directory: directory)
        try await store.open()
        coordinator = SessionCoordinator(store: store)
        coordinator.starter = { _ in }
    }

    override func tearDown() async throws {
        await store.close()
        coordinator = nil
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ kind: SessionKind = .assistant) async throws -> SessionRecord {
        try await store.createSession(
            SessionDraft(kind: kind, engineProfile: "test", audioSource: .microphone)
        )
    }

    private func sql(_ text: String) throws {
        var db: OpaquePointer?
        let file = directory.appendingPathComponent(SessionStore.fileName)
        XCTAssertEqual(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let pointer = try XCTUnwrap(db)
        defer { sqlite3_close_v2(pointer) }
        XCTAssertEqual(sqlite3_exec(pointer, text, nil, nil, nil), SQLITE_OK)
    }

    func testMissingRecordCannotReportEnded() async throws {
        let result = await coordinator.endAssistant(.init(recordID: "missing"))
        XCTAssertNotEqual(result, .ended(recordID: "missing"))
        XCTAssertNil(coordinator.lastFinalizedSessionID)
        do {
            try await store.finalizeSession(id: "missing")
            XCTFail("zero-row archive must fail")
        } catch {}
    }

    func testArchiveRetryPreservesFirstEndTimeAndReason() async throws {
        let original = try await record()
        let firstTime = Date(timeIntervalSince1970: 100)
        try await store.finalizeSession(id: original.id, endReason: .user, endedAt: firstTime)
        try sql("""
            CREATE TRIGGER no_second_archive BEFORE UPDATE OF state ON session
            WHEN OLD.state = 'archived' BEGIN SELECT RAISE(ABORT, 'archive repeated'); END;
            """)
        do {
            try await store.finalizeSession(
                id: original.id, endReason: .unexpectedExit, endedAt: firstTime.addingTimeInterval(90)
            )
        } catch {
            XCTFail("retry must read the first commit without a second UPDATE: \(error)")
        }
        let archived = try await store.session(id: original.id)
        XCTAssertEqual(archived?.endedAt, firstTime)
        XCTAssertEqual(archived?.endReason, .user)
    }

    func testArchiveWriteFailureReleasesDevicesWithoutSuccess() async throws {
        try await coordinator.begin(.captions)
        let original = try await record(.captions)
        coordinator.sessionDidStartRecording(id: original.id)
        try sql("""
            CREATE TRIGGER fail_archive BEFORE UPDATE OF state ON session
            BEGIN SELECT RAISE(ABORT, 'archive unavailable'); END;
            """)
        await coordinator.finalize(reason: .user)
        XCTAssertNil(coordinator.lastFinalizedSessionID)
        XCTAssertFalse(coordinator.holdsDeviceLease)
        XCTAssertNil(coordinator.occupancy)
        let stored = try await store.session(id: original.id)
        XCTAssertEqual(stored?.state, .recording)
        let pending = try XCTUnwrap(coordinator.pendingSeals[original.id])
        XCTAssertEqual(pending.stage, .archive)
        try sql("DROP TRIGGER fail_archive;")
        let retried = await coordinator.retryPendingSeal(id: original.id)
        XCTAssertEqual(retried, .sealed(recordID: original.id))
        XCTAssertNil(coordinator.pendingSeals[original.id])
        XCTAssertEqual(coordinator.lastFinalizedSessionID, original.id)
        let restored = try await store.session(id: original.id)
        XCTAssertEqual(
            try XCTUnwrap(restored?.endedAt).timeIntervalSince1970,
            pending.endedAt.timeIntervalSince1970, accuracy: 0.000001
        )
    }

    func testTextFailureDoesNotReleaseMeetingLease() async throws {
        try await coordinator.begin(.meeting)
        let meeting = try await record(.meeting)
        coordinator.sessionDidStartRecording(id: meeting.id)
        let text = try await record()
        let lease = coordinator.activeLeaseID
        try sql("""
            CREATE TRIGGER fail_archive BEFORE UPDATE OF state ON session
            BEGIN SELECT RAISE(ABORT, 'archive unavailable'); END;
            """)
        let result = await coordinator.endAssistant(.init(recordID: text.id))
        XCTAssertNotEqual(result, .ended(recordID: text.id))
        XCTAssertNil(coordinator.lastFinalizedSessionID)
        XCTAssertEqual(coordinator.activeLeaseID, lease)
        XCTAssertEqual(coordinator.activeSessionID, meeting.id)
        XCTAssertTrue(coordinator.holdsDeviceLease)
    }

    func testLateStopperCannotArchiveOrClearNewLease() async throws {
        try await coordinator.begin(.assistant)
        let old = try await record()
        coordinator.sessionDidStartRecording(id: old.id)
        let gate = Gate()
        coordinator.stopper = { _ in await gate.wait() }
        let finishing = Task { await coordinator.finalize(reason: .user) }
        await waitUntil { gate.entered }
        coordinator.abandonOccupancy()
        try await coordinator.begin(.captions)
        let current = try await record(.captions)
        coordinator.sessionDidStartRecording(id: current.id)
        let lease = coordinator.activeLeaseID
        gate.release()
        await finishing.value
        XCTAssertEqual(coordinator.activeLeaseID, lease)
        XCTAssertEqual(coordinator.activeSessionID, current.id)
        XCTAssertEqual(coordinator.occupancy?.kind, .captions)
        XCTAssertEqual(coordinator.phase, .recording)
        XCTAssertTrue(coordinator.holdsDeviceLease)
        let oldStored = try await store.session(id: old.id)
        let currentStored = try await store.session(id: current.id)
        // abandonOccupancy 撤销旧采集的保存证明；迟到的 stopper 不能越过这次撤销归档。
        XCTAssertEqual(oldStored?.state, .recording)
        XCTAssertEqual(currentStored?.state, .recording)
    }

    func testCommitThenConfirmationFailureRetriesSameRecordAndEndMetadata() async throws {
        let original = try await record()
        let writer = ArchiveWriter(store: store, failsAfterFirstCommit: true)
        coordinator = SessionCoordinator(store: store, archiveWriter: writer)
        let failed = await coordinator.sealSessionReporting(id: original.id, reason: .user)
        guard case .failed(let id, _) = failed else { return XCTFail("confirmation must fail") }
        XCTAssertEqual(id, original.id)
        XCTAssertNil(coordinator.lastFinalizedSessionID)
        let committed = try await store.session(id: original.id)
        XCTAssertEqual(committed?.state, .archived)
        XCTAssertNotNil(coordinator.pendingSeals[original.id])
        let retried = await coordinator.sealSessionReporting(id: original.id, reason: .unexpectedExit)
        XCTAssertEqual(retried, .sealed(recordID: original.id))
        let confirmed = try await store.session(id: original.id)
        XCTAssertEqual(confirmed?.endedAt, committed?.endedAt)
        XCTAssertEqual(confirmed?.endReason, .user)
        XCTAssertNil(coordinator.pendingSeals[original.id])
        let count = try await store.sessionCount()
        XCTAssertEqual(count, 1)
    }

    func testMeetingSnapshotFailureRetriesOnlySnapshotAndReleasesOwnership() async throws {
        let original = try await record(.meeting)
        _ = try await store.appendLine(
            LineDraft(sessionID: original.id, role: .speaker, text: "计划已确认。", source: .microphone)
        )
        let writer = ArchiveWriter(store: store)
        coordinator = SessionCoordinator(store: store, archiveWriter: writer)
        coordinator.starter = { _ in }
        try await coordinator.begin(.meeting)
        coordinator.sessionDidStartRecording(id: original.id)
        try sql("""
            CREATE TRIGGER fail_source BEFORE INSERT ON source_snapshot
            BEGIN SELECT RAISE(ABORT, 'snapshot unavailable'); END;
            """)
        let failed = await coordinator.sealMeeting(id: original.id)
        guard case .failed(_, let reason) = failed else { return XCTFail("snapshot must fail") }
        XCTAssertTrue(reason.contains("文字记录已经归档"))
        XCTAssertNil(coordinator.lastFinalizedSessionID)
        XCTAssertNil(coordinator.occupancy)
        XCTAssertFalse(coordinator.holdsDeviceLease)
        XCTAssertEqual(coordinator.pendingSeals[original.id]?.stage, .sourceSnapshot)
        let committed = try await store.session(id: original.id)
        XCTAssertEqual(committed?.state, .archived)
        try sql("DROP TRIGGER fail_source;")
        let retried = await coordinator.retryPendingSeal(id: original.id)
        XCTAssertEqual(retried, .sealed(recordID: original.id))
        let attempts = await writer.calls
        XCTAssertEqual(attempts, 1, "confirmed archive is not executed again")
        let snapshot = try await store.latestSourceSnapshot(sessionID: original.id)
        XCTAssertNotNil(snapshot)
    }

    func testPauseFailureBlocksArchiveAndKeepsExactRecoveryInterval() async throws {
        try await coordinator.begin(.captions)
        let original = try await record(.captions)
        coordinator.sessionDidStartRecording(id: original.id)
        _ = await coordinator.markUserPaused()
        try sql("""
            CREATE TRIGGER fail_pause BEFORE UPDATE ON session_interruption
            BEGIN SELECT RAISE(ABORT, 'pause close unavailable'); END;
            """)
        let failed = await coordinator.finalize(reason: .user)
        guard case .failed = failed else { return XCTFail("pause close must block archive") }
        XCTAssertEqual(coordinator.pendingSeals[original.id]?.stage, .pauseClosure)
        XCTAssertNotNil(coordinator.pauseClosureFailure)
        XCTAssertNil(coordinator.lastFinalizedSessionID)
        XCTAssertFalse(coordinator.holdsDeviceLease)
        let before = try await store.session(id: original.id)
        XCTAssertEqual(before?.state, .recording)
        try sql("DROP TRIGGER fail_pause;")
        let retried = await coordinator.retryPendingSeal(id: original.id)
        XCTAssertEqual(retried, .sealed(recordID: original.id))
        let intervals = try await store.interruptions(sessionID: original.id)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertNotNil(intervals.first?.resumedAt)
    }

    func testLateArchiveConfirmationDoesNotReleaseNewLease() async throws {
        let writer = ArchiveWriter(store: store, blocksConfirmation: true)
        coordinator = SessionCoordinator(store: store, archiveWriter: writer)
        coordinator.starter = { _ in }
        try await coordinator.begin(.assistant)
        let original = try await record()
        coordinator.sessionDidStartRecording(id: original.id)
        let finishing = Task { await coordinator.endAssistant(.init(
            recordID: original.id, leaseID: coordinator.activeLeaseID
        )) }
        await waitForArchive(writer)
        coordinator.abandonOccupancy()
        try await coordinator.begin(.captions)
        let current = try await record(.captions)
        coordinator.sessionDidStartRecording(id: current.id)
        let lease = coordinator.activeLeaseID
        await writer.release()
        let result = await finishing.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(coordinator.activeLeaseID, lease)
        XCTAssertEqual(coordinator.activeSessionID, current.id)
        XCTAssertTrue(coordinator.holdsDeviceLease)
        let currentStored = try await store.session(id: current.id)
        XCTAssertEqual(currentStored?.state, .recording)
        let oldStored = try await store.session(id: original.id)
        XCTAssertEqual(oldStored?.state, .archived)
    }

    func testRepeatedFinalizeSharesStopAndCommit() async throws {
        let writer = ArchiveWriter(store: store)
        coordinator = SessionCoordinator(store: store, archiveWriter: writer)
        coordinator.starter = { _ in }
        try await coordinator.begin(.assistant)
        let original = try await record()
        coordinator.sessionDidStartRecording(id: original.id)
        let gate = Gate()
        var stops = 0
        coordinator.stopper = { _ in stops += 1; await gate.wait() }
        let first = Task { await coordinator.finalize(reason: .user) }
        await waitUntil { gate.entered }
        let second = Task { await coordinator.finalize(reason: .unexpectedExit) }
        await Task.yield()
        gate.release()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .sealed(recordID: original.id))
        XCTAssertEqual(secondResult, firstResult)
        XCTAssertEqual(stops, 1)
        let attempts = await writer.calls
        XCTAssertEqual(attempts, 1)
    }

    func testNoRecordReleasesLeaseWithoutPublishingArchive() async throws {
        try await coordinator.begin(.teleprompter)
        coordinator.sessionDidStartRecording()
        let result = await coordinator.finalize(reason: .user)
        XCTAssertEqual(result, .skipped(recordID: nil))
        XCTAssertNil(coordinator.lastFinalizedSessionID)
        XCTAssertNil(coordinator.occupancy)
        XCTAssertFalse(coordinator.holdsDeviceLease)
    }

    func testTextStopFailureDoesNotPublishAssistantSuccess() async throws {
        let assistant = makeTextAssistant()
        _ = await assistant.ask(typed: "保留这条测试输入。")
        let id = try XCTUnwrap(assistant.sessionID)
        try sql("""
            CREATE TRIGGER fail_archive BEFORE UPDATE OF state ON session
            BEGIN SELECT RAISE(ABORT, 'archive unavailable'); END;
            """)
        await assistant.stopCapture()
        XCTAssertNil(assistant.lastFinalizedSessionID)
        XCTAssertEqual(assistant.pendingSealRecordID, id)
        XCTAssertNotNil(assistant.lastFailure)
    }

    func testSkippedAssistantRetryKeepsRecoveryAndDoesNotReportSuccess() async throws {
        let assistant = makeTextAssistant()
        _ = await assistant.ask(typed: "重试必须确认归档。")
        let id = try XCTUnwrap(assistant.sessionID)
        try sql("""
            CREATE TRIGGER fail_archive BEFORE UPDATE OF state ON session
            BEGIN SELECT RAISE(ABORT, 'archive unavailable'); END;
            """)
        await assistant.endConversation()
        XCTAssertEqual(assistant.pendingSealRecordID, id)
        try sql("DROP TRIGGER fail_archive;")
        try await coordinator.begin(.assistant)
        coordinator.sessionDidStartRecording(id: id)
        let retried = await assistant.retryPendingSeal()
        XCTAssertFalse(retried, "skipping an occupied record is not confirmation")
        XCTAssertEqual(assistant.pendingSealRecordID, id)
        XCTAssertNil(assistant.lastFinalizedSessionID)
    }

    func testMeetingRequestJoiningBasicArchiveStillRequiresSnapshot() async throws {
        let original = try await record(.meeting)
        _ = try await store.appendLine(
            LineDraft(sessionID: original.id, role: .speaker, text: "共享封存测试。", source: .microphone)
        )
        let writer = ArchiveWriter(store: store, blocksConfirmation: true)
        coordinator = SessionCoordinator(store: store, archiveWriter: writer)
        let basic = Task { await coordinator.sealSessionReporting(id: original.id) }
        await waitForArchive(writer)
        let meeting = Task { await coordinator.sealMeeting(id: original.id) }
        await Task.yield()
        await writer.release()
        _ = await basic.value
        let result = await meeting.value
        XCTAssertEqual(result, .sealed(recordID: original.id))
        let snapshot = try await store.latestSourceSnapshot(sessionID: original.id)
        XCTAssertNotNil(snapshot, "joining a basic archive must not lower the meeting success condition")
    }

    func testGenericMeetingSealCannotPublishSuccessBeforeSourceConfirmation() async throws {
        let original = try await record(.meeting)
        _ = try await store.appendLine(
            LineDraft(sessionID: original.id, role: .speaker, text: "来源封存测试。", source: .microphone)
        )
        try sql("""
            CREATE TRIGGER fail_source BEFORE INSERT ON source_snapshot
            BEGIN SELECT RAISE(ABORT, 'snapshot unavailable'); END;
            """)
        let result = await coordinator.sealSessionReporting(id: original.id)
        guard case .failed = result else { return XCTFail("meeting source is part of confirmation") }
        XCTAssertNil(coordinator.lastFinalizedSessionID)
        XCTAssertEqual(coordinator.pendingSeals[original.id]?.stage, .sourceSnapshot)
    }

    private func makeTextAssistant() -> AssistantSession {
        let defaults = UserDefaults(suiteName: "session-seal-text-\(UUID().uuidString)")!
        let preferences = SessionPreferences(defaults: defaults)
        preferences.llmBaseURL = "http://127.0.0.1:8000/v1"
        preferences.llmModel = "test-model"
        let assistant = AssistantSession(
            coordinator: coordinator,
            dependencies: .init(llm: AssistantSessionTests.FakeAssistantLLM(scripts: [.deltas(["测试回复。"])]))
        )
        assistant.preferences = { preferences }
        assistant.apiKeyProvider = { "test-key" }
        assistant.moduleAPIKeyProvider = { _ in nil }
        assistant.serviceReadiness = { .ready(profile: nil) }
        return assistant
    }

    private func waitForArchive(_ writer: ArchiveWriter) async {
        for _ in 0..<800 {
            if await writer.waiting { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("archive gate was not entered")
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<800 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("gate was not entered")
    }

    @MainActor
    private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor ArchiveWriter: SessionArchiveWriting {
        let store: SessionStore
        var calls = 0
        var waiting = false
        var failsAfterFirstCommit: Bool
        var blocksConfirmation: Bool
        private var continuation: CheckedContinuation<Void, Never>?

        init(
            store: SessionStore, failsAfterFirstCommit: Bool = false,
            blocksConfirmation: Bool = false
        ) {
            self.store = store
            self.failsAfterFirstCommit = failsAfterFirstCommit
            self.blocksConfirmation = blocksConfirmation
        }

        func finalizeSession(
            id: String, endReason: SessionEndReason, endedAt: Date
        ) async throws -> SessionRecord {
            calls += 1
            let record = try await store.finalizeSession(id: id, endReason: endReason, endedAt: endedAt)
            if blocksConfirmation {
                waiting = true
                await withCheckedContinuation { continuation = $0 }
            }
            if failsAfterFirstCommit {
                failsAfterFirstCommit = false
                throw SessionStoreError.statementFailed("confirmation unavailable")
            }
            return record
        }

        func release() {
            blocksConfirmation = false
            continuation?.resume()
            continuation = nil
        }
    }
}
