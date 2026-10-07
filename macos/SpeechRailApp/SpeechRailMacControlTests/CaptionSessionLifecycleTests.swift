import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
final class CaptionSessionLifecycleTests: XCTestCase {
    private var harness: Harness?

    override func tearDown() async throws {
        if let harness {
            if harness.coordinator.occupancy != nil {
                await harness.coordinator.finalize(reason: .user)
            }
            await harness.store.close()
            harness.defaults.removePersistentDomain(forName: harness.defaultsName)
            try? FileManager.default.removeItem(at: harness.directory)
        }
        harness = nil
        try await super.tearDown()
    }

    private func makeHarness(
        saveLine: (@Sendable (LineDraft, String) async throws -> Int)? = nil,
        attachSpeakerLabel: (@Sendable (String, String?) async throws -> Void)? = nil,
        configuration: TranscriptPersistenceQueue.Configuration = .init(),
        makeRealtimeClient: (@Sendable (CaptionRealtimeClientConfiguration) -> any CaptionRealtimeClient)? = nil
    ) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("caption-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = SessionStore(directory: directory)
        try await store.open()

        let defaultsName = "caption-lifecycle-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()

        let audio = ControllableCaptionAudioSource()
        let clients = CaptionClientRegistry()
        let dependencies = CaptionSessionDependencies(
            makeRealtimeClient: { configuration in
                makeRealtimeClient?(configuration) ?? clients.make(configuration)
            },
            persistenceConfiguration: configuration,
            saveLine: saveLine,
            attachSpeakerLabel: attachSpeakerLabel
        )
        let session = CaptionSession(
            coordinator: coordinator,
            dependencies: dependencies,
            audioSourceFactory: { audio }
        )
        session.serviceReadiness = { .ready(profile: "test") }
        coordinator.starter = { kind in
            guard kind == .captions else {
                throw SessionCoordinator.CapabilityNotWired(kind: kind)
            }
            try await session.beginCapture()
        }
        coordinator.stopper = { kind in
            guard kind == .captions else { return }
            await session.stopCapture()
        }

        let harness = Harness(
            directory: directory,
            defaultsName: defaultsName,
            defaults: defaults,
            store: store,
            coordinator: coordinator,
            session: session,
            audio: audio,
            clients: clients
        )
        self.harness = harness
        return harness
    }

    private func start(_ harness: Harness) async throws -> String {
        await harness.session.openBand()
        try await harness.settle { $0.session.phase == .running }
        return try XCTUnwrap(
            harness.session.sessionID,
            harness.session.blocked?.detail ?? harness.session.lastFailure ?? "没有建立字幕记录"
        )
    }

    func testFinalSaveFailureRetainsOneFrozenCommandAndRetriesWithoutCompletedReplay() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "item", transcript: "字幕定稿只到一次。"))
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let command = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        XCTAssertEqual(command.text, "字幕定稿只到一次。")
        XCTAssertEqual(command.role, .speaker)
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered)
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, command.lineID)
        let attempts = await gate.attempts
        XCTAssertEqual(attempts.map(\.id), [command.lineID, command.lineID])
        XCTAssertEqual(try XCTUnwrap(rows.first?.createdAt).timeIntervalSince1970,
                       command.observedAt.timeIntervalSince1970, accuracy: 0.000001)
    }

    func testPendingCaptionSaveConsumesControlAndCachesEarlyAttribution() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "item", transcript: "缓存归属字幕"))
        try await h.settle { _ in await gate.entered }
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "unit", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.serverError(code: "test_control", message: "字幕控制事件已消费", requestID: nil))
        try await h.settle { $0.session.lastFailure == "字幕控制事件已消费" }
        await gate.release()
        let settled = await h.session.waitForPendingSaves(recordID: id)
        XCTAssertTrue(settled.isComplete)
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.text, "缓存归属字幕")
        XCTAssertEqual(rows.first?.timingQuality, .aligned)
    }

    func testSavedCaptionAttributionHonoursProjectionCapacity() async throws {
        let h = try await makeHarness(configuration: .init(maximumPendingProjections: 0))
        let id = try await start(h)
        try await h.emit(.completed(itemID: "item", transcript: "已保存字幕正文"))
        try await h.settle { $0.session.lines.count == 1 }
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "unit", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.serverError(code: "control", message: "容量后控制", requestID: nil))
        try await h.settle { $0.session.lastFailure == "容量后控制" }
        _ = await h.session.waitForPendingSaves(recordID: id)
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.map(\.text), ["已保存字幕正文"])
        XCTAssertEqual(rows.first?.timingQuality, .unavailable, "rejected auxiliary work must not run inline")
    }

    func testBlockedCaptionMetadataKeepsControlResponsiveAndSettlementPending() async throws {
        let gate = SpeakerAttributionWriteGate()
        let h = try await makeHarness(attachSpeakerLabel: { try await gate.write($0, label: $1) })
        await gate.attach(h.store)
        h.session.diarizationPreference = { true }
        let id = try await start(h)
        try await h.emit(.completed(itemID: "item", transcript: "metadata等待中的字幕正文"))
        try await h.settle { $0.session.lines.count == 1 }
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "unit", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.settle { _ in await gate.entered }
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "unit", speaker: "B", timingQuality: "aligned")
        ], isFinal: false))
        try await h.emit(.attribution(itemID: "item", units: [
            .init(segmentUID: "another-unit", speaker: nil, timingQuality: "unavailable")
        ], isFinal: true))
        try await h.emit(.serverError(code: "control", message: "metadata等待时控制", requestID: nil))
        var settled = false
        let waiter = Task {
            _ = await h.session.waitForPendingSaves(recordID: id)
            settled = true
        }
        for _ in 0..<200 {
            if h.session.lastFailure == "metadata等待时控制" { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(h.session.lastFailure, "metadata等待时控制")
        XCTAssertFalse(settled)
        XCTAssertTrue(h.session.pendingSaveRecordIDs.contains(id))
        await gate.release()
        await waiter.value
        let rows = try await h.store.lines(sessionID: id)
        XCTAssertEqual(rows.first?.speakerLabel, "B", "accepted unit revisions must survive a later partial batch")
        XCTAssertEqual(rows.first?.timingQuality, .aligned)
        XCTAssertEqual(h.session.lines.first?.speakerLabel, "B")
    }

    func testCaptionRecoveryPartialAlsoRetainsFixedIdentityAndStaysOutOfFormalRows() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.partialSnapshot(itemID: "partial", revision: 1, text: "只有恢复预览。"))
        try await h.emit(.completed(itemID: "partial", transcript: ""))
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let command = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        XCTAssertFalse(command.formal)
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered)
        let formal = try await h.store.lines(sessionID: id)
        XCTAssertTrue(formal.isEmpty)
        let all = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertEqual(all.map(\.id), [command.lineID])
        XCTAssertEqual(all.first?.status, .partial)
        XCTAssertTrue(h.session.lines.isEmpty)
    }

    func testFailedCaptionItemKeepsRecoverablePartialCommandAfterStoreFailure() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.partialSnapshot(itemID: "failed", revision: 1, text: "字幕失败前的预览"))
        try await h.emit(.failed(itemID: "failed", code: "asr_failed", message: "识别未完成"))
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let command = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        XCTAssertFalse(command.formal)
        XCTAssertEqual(command.text, "字幕失败前的预览")
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered)
        let formal = try await h.store.lines(sessionID: id)
        let all = try await h.store.lines(sessionID: id, includePartial: true)
        XCTAssertTrue(formal.isEmpty)
        XCTAssertEqual(all.map(\.id), [command.lineID])
        XCTAssertEqual(all.first?.status, .partial)
        XCTAssertTrue(h.session.lines.isEmpty)
    }

    func testCaptionCapacityRejectionRemainsIncompleteAfterAcceptedSaveDrains() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(
            saveLine: { try await gate.save($0, id: $1) },
            configuration: .init(maximumPendingCommands: 1)
        )
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "accepted", transcript: "接纳的字幕"))
        try await h.settle { _ in await gate.entered }
        try await h.emit(.completed(itemID: "refused", transcript: "未接纳的字幕"))
        try await h.emit(.serverError(code: "test_control", message: "容量拒绝后控制继续", requestID: nil))
        try await h.settle { $0.session.lastFailure == "容量拒绝后控制继续" }
        await gate.release()
        let report = await h.session.waitForPendingSaves(recordID: id)
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(h.session.unsavedTranscriptText(recordID: id), "未接纳的字幕")
        await h.session.finish()
        let record = try await h.store.session(id: id)
        XCTAssertNotEqual(record?.state, .archived)
        XCTAssertEqual(h.session.pendingSaveRecordIDs, [id])
    }

    func testProductionClientRetriesSaveBeforeAnySecondCompletedAndSuppressesDuplicateTerminal() async throws {
        let gate = TranscriptPersistenceGate()
        let transport = TranscriptRealtimeTestTransport()
        let h = try await makeHarness(
            saveLine: { try await gate.save($0, id: $1) },
            makeRealtimeClient: { configuration in
                TranscriptRealtimeTestClient(
                    client: RealtimeASRClient(scenePreset: configuration.scenePreset, apiKey: ""),
                    transport: transport
                )
            }
        )
        await gate.attach(h.store)
        let id = try await start(h)
        try await transport.completed(itemID: "real-item", text: "真实客户端唯一终稿")
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: id).isEmpty }
        let frozen = try XCTUnwrap(h.session.pendingSaveCommands(recordID: id).first)
        await gate.release()
        let recovered = await h.session.retryPendingSaves(recordID: id)
        XCTAssertTrue(recovered, "retry must finish before a second completed exists")
        let beforeDuplicate = try await h.store.lines(sessionID: id)
        XCTAssertEqual(beforeDuplicate.map(\.id), [frozen.lineID])
        XCTAssertEqual(beforeDuplicate.map(\.text), ["真实客户端唯一终稿"])
        try await transport.completed(itemID: "real-item", text: "重复终态不得覆盖")
        try await transport.control("重复终态之后的控制")
        try await h.settle { $0.session.lastFailure == "重复终态之后的控制" }
        let rows = try await h.store.lines(sessionID: id)
        let attempts = await gate.attempts
        XCTAssertEqual(rows.map(\.text), ["真实客户端唯一终稿"])
        XCTAssertEqual(attempts.map(\.id), [frozen.lineID, frozen.lineID])
    }

    func testFinishWaitsForSaveAndFailureCannotArchiveTheRecord() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        let id = try await start(h)
        try await h.emit(.completed(itemID: "tail", transcript: "尚未保存的最后一句"))
        try await h.settle { _ in await gate.entered }
        let finish = Task { await h.session.finish() }
        try await h.settle { $0.session.phase == .ending }
        let pendingRecord = try await h.store.session(id: id)
        XCTAssertNil(pendingRecord?.endedAt)
        XCTAssertEqual(h.coordinator.activeSessionID, id)
        await gate.release(failing: true)
        await finish.value
        let failedRecord = try await h.store.session(id: id)
        XCTAssertNil(failedRecord?.endedAt)
        XCTAssertNotEqual(failedRecord?.state, .archived)
        XCTAssertEqual(h.session.pendingSaveRecordIDs, [id])
        XCTAssertEqual(h.session.unsavedTranscriptText(recordID: id), "尚未保存的最后一句")
    }

    func testOldFailedRecordRetryDoesNotProjectIntoNewCaptionRecord() async throws {
        let gate = TranscriptPersistenceGate()
        let h = try await makeHarness(saveLine: { try await gate.save($0, id: $1) })
        await gate.attach(h.store)
        h.session.diarizationPreference = { true }
        let oldID = try await start(h)
        try await h.emit(.attribution(itemID: "same-item", units: [
            .init(segmentUID: "same-unit", speaker: "A", timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.completed(itemID: "same-item", transcript: "上一场未保存"))
        try await h.settle { _ in await gate.entered }
        await gate.release(failing: true)
        try await h.settle { !$0.session.saveFailures(recordID: oldID).isEmpty }
        await h.session.finish()
        let newID = try await start(h)
        XCTAssertNotEqual(oldID, newID)
        await gate.release()
        try await h.emit(.attribution(itemID: "same-item", units: [
            .init(segmentUID: "same-unit", speaker: "B", timingQuality: "aligned")
        ], isFinal: true))
        try await h.emit(.completed(itemID: "same-item", transcript: "新场正文"))
        let newSettled = await h.session.waitForPendingSaves(recordID: newID)
        XCTAssertTrue(newSettled.isComplete)
        try await h.settle { $0.session.lines.count == 1 }
        let recovered = await h.session.retryPendingSaves(recordID: oldID)
        XCTAssertTrue(recovered)
        let oldRows = try await h.store.lines(sessionID: oldID)
        let newRows = try await h.store.lines(sessionID: newID)
        XCTAssertEqual(oldRows.map(\.text), ["上一场未保存"])
        XCTAssertEqual(oldRows.first?.speakerLabel, "A")
        XCTAssertEqual(oldRows.first?.timingQuality, .aligned)
        XCTAssertEqual(newRows.map(\.text), ["新场正文"])
        XCTAssertEqual(newRows.first?.speakerLabel, "B")
        XCTAssertEqual(h.session.lines.map(\.text), ["新场正文"])
        XCTAssertEqual(h.session.labeling.labels, ["B"])
        XCTAssertEqual(h.session.sessionID, newID)
        XCTAssertEqual(h.coordinator.activeSessionID, newID)
    }

    /// The production session keeps previews and frozen input ranges per item.
    /// A later final for A must not replace or inherit B input ownership.
    func testInterleavedAndLateItemsKeepTheirOwnTextAndInputRanges() async throws {
        let harness = try await makeHarness()
        let sessionID = try await start(harness)
        let spanA = RealtimeASRClient.RealtimeSampleSpan(startSample: 0, endSample: 24_000)
        let spanB = RealtimeASRClient.RealtimeSampleSpan(startSample: 24_000, endSample: 48_000)

        try await harness.emit(.partial(itemID: "A", delta: "A 的预览"))
        try await harness.emit(.partialSnapshot(itemID: "B", revision: 1, text: "B 的预览"))
        try await harness.emit(
            .segmentClosed(
                itemID: "A",
                sampleSpan: spanA,
                reason: .vad,
                commitEventID: nil
            )
        )
        try await harness.emit(
            .segmentClosed(
                itemID: "B",
                sampleSpan: spanB,
                reason: .vad,
                commitEventID: nil
            )
        )

        try await harness.emit(.completed(itemID: "B", transcript: "B 的终稿"))
        try await harness.settle { $0.session.lines.count == 1 }
        try await harness.emit(.completed(itemID: "A", transcript: "A 的终稿"))
        try await harness.settle { $0.session.lines.count == 2 }

        let lines = try await harness.store.lines(sessionID: sessionID)
        let lineA = try XCTUnwrap(lines.first { $0.text == "A 的终稿" })
        let lineB = try XCTUnwrap(lines.first { $0.text == "B 的终稿" })
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try XCTUnwrap(lineA.tStart), 0, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(lineA.tEnd), 1, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(lineB.tStart), 1, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(lineB.tEnd), 2, accuracy: 0.02)
    }

    /// Ending is an owner barrier: the final produced by drain must be saved
    /// before the coordinator archives the caption session.
    func testFinishPersistsTheFinalProducedByDrainBeforeArchive() async throws {
        let harness = try await makeHarness()
        let sessionID = try await start(harness)
        let client = try XCTUnwrap(harness.clients.all.first)
        harness.audio.emit(AudioChunk(pcm: Data([0, 1]), level: 0.2))
        harness.audio.emit(AudioChunk(pcm: Data([2, 3]), level: 0.3))
        await client.setDrainEvents([
            .segmentClosed(
                itemID: "tail",
                sampleSpan: .init(startSample: 0, endSample: 24_000),
                reason: .clientCommit,
                commitEventID: "caption-drain-commit"
            ),
            .completed(itemID: "tail", transcript: "停录前最后一句")
        ])

        await harness.session.finish()

        let lines = try await harness.store.lines(sessionID: sessionID)
        XCTAssertEqual(lines.map(\.text), ["停录前最后一句"])
        let appendedAtDrain = await client.appendedByteCountAtDrain
        let appendedBytes = await client.appendedByteCount
        XCTAssertEqual(appendedAtDrain, 4, "提交 drain 前必须上传采集流里已缓冲的两块音频")
        XCTAssertEqual(appendedBytes, 4, "已缓冲音频只上传一次")
        let storedRecord = try await harness.store.session(id: sessionID)
        let record = try XCTUnwrap(storedRecord)
        XCTAssertEqual(record.state, .archived)
    }

    /// A failed terminal keeps the item preview available as recovery text.
    func testFailedItemKeepsItsPreviewVisibleForRecovery() async throws {
        let harness = try await makeHarness()
        _ = try await start(harness)

        try await harness.emit(
            .partialSnapshot(itemID: "recoverable", revision: 1, text: "失败前已经显示的句子")
        )
        try await harness.settle { $0.session.partialText == "失败前已经显示的句子" }
        try await harness.emit(
            .failed(itemID: "recoverable", code: "asr_failed", message: "未能识别")
        )
        try await harness.settle { $0.session.lastFailure?.contains("asr_failed") == true }

        XCTAssertEqual(harness.session.partialText, "失败前已经显示的句子")
        let sessionID = try XCTUnwrap(harness.session.sessionID)
        let persistedLines = try await harness.store.lines(sessionID: sessionID)
        XCTAssertTrue(persistedLines.isEmpty)
    }

    @MainActor
    private final class Harness {
        let directory: URL
        let defaultsName: String
        let defaults: UserDefaults
        let store: SessionStore
        let coordinator: SessionCoordinator
        let session: CaptionSession
        let audio: ControllableCaptionAudioSource
        let clients: CaptionClientRegistry

        init(
            directory: URL,
            defaultsName: String,
            defaults: UserDefaults,
            store: SessionStore,
            coordinator: SessionCoordinator,
            session: CaptionSession,
            audio: ControllableCaptionAudioSource,
            clients: CaptionClientRegistry
        ) {
            self.directory = directory
            self.defaultsName = defaultsName
            self.defaults = defaults
            self.store = store
            self.coordinator = coordinator
            self.session = session
            self.audio = audio
            self.clients = clients
        }

        func emit(_ payload: RealtimeASRClient.Event) async throws {
            let client = try XCTUnwrap(clients.all.last)
            await client.emit(payload)
        }

        func settle(
            until predicate: @MainActor (Harness) async -> Bool,
            timeout: Duration = .seconds(5)
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while clock.now < deadline {
            if await predicate(self) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(
            "等待超时：phase=\(session.phase.rawValue)，events=\(clients.all.count)，"
                + "blocked=\(session.blocked?.detail ?? session.lastFailure ?? "none")"
        )
        }
    }
}

private final class ControllableCaptionAudioSource: AudioChunkSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func start() async throws -> AsyncStream<AudioChunk> {
        let pair = AsyncStream<AudioChunk>.makeStream()
        setContinuation(pair.continuation)
        return pair.stream
    }

    private func setContinuation(_ value: AsyncStream<AudioChunk>.Continuation) {
        lock.lock()
        continuation = value
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.finish()
    }

    func emit(_ chunk: AudioChunk) {
        lock.lock()
        let current = continuation
        lock.unlock()
        current?.yield(chunk)
    }
}

private actor ControllableCaptionRealtimeClient: CaptionRealtimeClient {
    private let stream = RealtimeEventStream<RealtimeASRClient.Event>()
    private var drainEvents: [RealtimeASRClient.Event] = []
    private(set) var drainCount = 0
    private(set) var closeCount = 0
    private(set) var appendedByteCount = 0
    private(set) var appendedByteCountAtDrain = 0

    func events() async -> RealtimeEventStream<RealtimeASRClient.Event> { stream }
    func connect() async throws {}
    func append(_ pcm: Data) async throws { appendedByteCount += pcm.count }

    func setDrainEvents(_ events: [RealtimeASRClient.Event]) {
        drainEvents = events
    }

    func drainAndClear(timeout: Duration) async throws {
        drainCount += 1
        appendedByteCountAtDrain = appendedByteCount
        let events = drainEvents
        drainEvents = []
        for event in events {
            await emit(event)
        }
    }

    func close() async {
        closeCount += 1
        await stream.finish()
    }

    func emit(_ payload: RealtimeASRClient.Event) async {
        _ = await stream.yield(
            RealtimeEventEnvelope(
                metadata: RealtimeEventMetadata(),
                payload: payload
            )
        )
    }
}

private final class CaptionClientRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ControllableCaptionRealtimeClient] = []

    func make(_ configuration: CaptionRealtimeClientConfiguration) -> any CaptionRealtimeClient {
        let client = ControllableCaptionRealtimeClient()
        lock.lock()
        storage.append(client)
        lock.unlock()
        return client
    }

    var all: [ControllableCaptionRealtimeClient] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
