import Foundation
import SQLite3
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

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
