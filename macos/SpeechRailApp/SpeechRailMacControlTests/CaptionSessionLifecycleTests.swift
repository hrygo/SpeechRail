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

    private func makeHarness() async throws -> Harness {
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
                clients.make(configuration)
            }
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
        return try XCTUnwrap(harness.session.sessionID)
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
            "等待超时：phase=\(session.phase.rawValue)，events=\(clients.all.count)"
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
