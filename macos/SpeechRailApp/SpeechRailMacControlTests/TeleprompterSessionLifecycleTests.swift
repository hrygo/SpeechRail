import Foundation
import SpeechRailControlKit
import Testing

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@MainActor
private final class FakeTeleprompterSourceFactory {
    private(set) var sources: [FakeTeleprompterAudioSource] = []

    func make() -> any AudioChunkSource {
        let source = FakeTeleprompterAudioSource()
        sources.append(source)
        return source
    }
}

private final class FakeTeleprompterAudioSource: AudioChunkSource, @unchecked Sendable {
    private let lock = NSLock()
    private var startCountStorage = 0
    private var stopCountStorage = 0
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func start() async throws -> AsyncStream<AudioChunk> {
        withLock {
            startCountStorage += 1
            var capturedContinuation: AsyncStream<AudioChunk>.Continuation?
            let stream = AsyncStream<AudioChunk> { continuation in
                capturedContinuation = continuation
            }
            continuation = capturedContinuation
            return stream
        }
    }

    func stop() {
        let continuation = withLock {
            stopCountStorage += 1
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.finish()
    }

    var startCount: Int {
        withLock { startCountStorage }
    }

    var stopCount: Int {
        withLock { stopCountStorage }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.isWaiting = true
        }
    }

    func waitUntilWaiting() async {
        while !isWaiting {
            await Task.yield()
        }
    }

    func open() {
        isWaiting = false
        continuation?.resume()
        continuation = nil
    }
}

private actor FakeTeleprompterRealtimeClient: TeleprompterRealtimeClientProtocol {
    struct Counters: Sendable, Equatable {
        var connectCount = 0
        var appendCount = 0
        var drainCount = 0
        var closeCount = 0
    }

    private let stream: AsyncStream<RealtimeEventEnvelope<RealtimeASRClient.Event>>
    private let continuation: AsyncStream<RealtimeEventEnvelope<RealtimeASRClient.Event>>.Continuation
    private let connectGate: TestGate?
    private let drainGate: TestGate?
    private let drainFails: Bool
    private var counters = Counters()

    init(connectGate: TestGate? = nil, drainGate: TestGate? = nil, drainFails: Bool = false) {
        var capturedContinuation: AsyncStream<RealtimeEventEnvelope<RealtimeASRClient.Event>>.Continuation?
        self.stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
        self.connectGate = connectGate
        self.drainGate = drainGate
        self.drainFails = drainFails
    }

    func connect() async throws {
        counters.connectCount += 1
        await connectGate?.wait()
    }

    func events() async -> AsyncStream<RealtimeEventEnvelope<RealtimeASRClient.Event>> {
        stream
    }

    func append(_ pcm: Data) async throws {
        counters.appendCount += 1
    }

    func drainAndClear(timeout: Duration) async throws {
        counters.drainCount += 1
        await drainGate?.wait()
        if drainFails {
            throw FakeFailure.drainFailed
        }
    }

    func close() async {
        counters.closeCount += 1
        continuation.finish()
    }

    func emit(_ payload: RealtimeASRClient.Event, eventID: String = UUID().uuidString) {
        continuation.yield(
            RealtimeEventEnvelope(
                metadata: RealtimeEventMetadata(eventID: eventID, sessionID: "test", sequence: nil),
                payload: payload
            )
        )
    }

    func currentCounters() -> Counters {
        counters
    }

    private enum FakeFailure: Error {
        case drainFailed
    }
}

@MainActor
private final class FakeTeleprompterClientFactory {
    private(set) var clients: [FakeTeleprompterRealtimeClient] = []
    let connectGate: TestGate?
    let drainGate: TestGate?
    let drainFails: Bool

    init(connectGate: TestGate? = nil, drainGate: TestGate? = nil, drainFails: Bool = false) {
        self.connectGate = connectGate
        self.drainGate = drainGate
        self.drainFails = drainFails
    }

    func make() -> any TeleprompterRealtimeClientProtocol {
        let client = FakeTeleprompterRealtimeClient(
            connectGate: connectGate,
            drainGate: drainGate,
            drainFails: drainFails
        )
        clients.append(client)
        return client
    }
}

@MainActor
private final class TeleprompterSessionHarness {
    let session: TeleprompterSession
    let coordinator: SessionCoordinator
    let sourceFactory: FakeTeleprompterSourceFactory
    let clientFactory: FakeTeleprompterClientFactory
    let directory: URL

    init(
        sourceFactory: FakeTeleprompterSourceFactory = .init(),
        clientFactory: FakeTeleprompterClientFactory = .init()
    ) throws {
        self.sourceFactory = sourceFactory
        self.clientFactory = clientFactory
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechRail-Teleprompter-Session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sessionStore = SessionStore(directory: directory.appendingPathComponent("sessions", isDirectory: true))
        let coordinator = SessionCoordinator(store: sessionStore)
        let v2Store = try TeleprompterV2Store(directoryURL: directory.appendingPathComponent("documents", isDirectory: true))
        let session = TeleprompterSession(
            coordinator: coordinator,
            v2Store: v2Store,
            audioSourceFactory: { sourceFactory.make() }
        )
        session.realtimeClientFactory = { _, _ in clientFactory.make() }
        coordinator.starter = { kind in
            guard kind == .teleprompter else { return }
            try await session.beginCapture()
        }
        coordinator.stopper = { kind in
            guard kind == .teleprompter else { return }
            await session.stopCapture()
        }
        self.coordinator = coordinator
        self.session = session
    }

    func makeThreeSegmentDocument() {
        session.createDocument(
            title: "测试稿",
            sourceText: "第一段内容。第二段内容。第三段内容。"
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
struct TeleprompterSessionLifecycleTests {
    @Test("manual open is readable without microphone, transport, or model work")
    func manualOpenHasNoAudioSideEffects() throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()

        try harness.session.openForManualReading()

        #expect(harness.session.activeVersion != nil)
        #expect(harness.session.phase == .manual)
        #expect(harness.session.voiceAssistState == .off)
        #expect(!harness.session.isMicrophoneCapturing)
        #expect(harness.session.isStageOpen)
        #expect(harness.sourceFactory.sources.isEmpty)
        #expect(harness.clientFactory.clients.isEmpty)
        #expect(harness.coordinator.occupancy == nil)

        harness.session.moveToPrevious()
        #expect(harness.session.currentSegmentIndex == 0)
        harness.session.moveToNext()
        #expect(harness.session.currentSegmentIndex == 1)
    }

    @Test("manual open rejects while another session operation owns the transition")
    func manualOpenRejectsWhileSessionIsPreparing() async throws {
        let connectGate = TestGate()
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(connectGate: connectGate)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        let startTask = Task { await harness.session.enableVoiceAssist() }
        await connectGate.waitUntilWaiting()
        #expect(harness.session.phase == .preparing)

        #expect(throws: TeleprompterStageOpenError.busy) {
            try harness.session.openForManualReading()
        }

        await connectGate.open()
        await startTask.value
        await harness.session.closeStage()
    }

    @Test("manual open rejects during close and succeeds after cleanup")
    func manualOpenRejectsDuringClose() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        #expect(harness.session.beginStageClose())
        #expect(harness.session.isClosingStage)
        #expect(throws: TeleprompterStageOpenError.closing) {
            try harness.session.openForManualReading()
        }

        await harness.session.finishStageClose()

        #expect(!harness.session.isClosingStage)
        #expect(!harness.session.isStageOpen)
        try harness.session.openForManualReading()
        #expect(harness.session.phase == .manual)
        #expect(harness.session.isStageOpen)
        await harness.session.closeStage()
    }

    @Test("disabling voice assist keeps an open stage in manual mode")
    func disablingVoiceAssistKeepsStageManual() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()

        await harness.session.disableVoiceAssist()

        #expect(harness.session.isStageOpen)
        #expect(harness.session.phase == .manual)
        #expect(harness.session.voiceAssistState == .off)
        #expect(harness.coordinator.occupancy == nil)
        await harness.session.closeStage()
    }

    @Test("manual open never adopts an unconfirmed AI draft")
    func manualOpenKeepsAcceptedVersion() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.useDeterministicFallback()
        let acceptedVersionID = try #require(harness.session.activeVersion?.id)
        let acceptedText = try #require(harness.session.activeVersion?.segments.first?.text)

        harness.session.preparationClient = TeleprompterPreparationClient { prompt in
            try TestPreparationResponse.response(for: prompt)
        }
        await harness.session.analyzeDraft()
        #expect(harness.session.pendingVersion != nil)
        #expect(harness.session.phase == .review)

        try harness.session.openForManualReading()

        #expect(harness.session.activeVersion?.id == acceptedVersionID)
        #expect(harness.session.activeVersion?.segments.first?.text == acceptedText)
        #expect(harness.session.pendingVersion != nil)
        #expect(harness.session.phase == .manual)
        #expect(harness.sourceFactory.sources.isEmpty)
        #expect(harness.clientFactory.clients.isEmpty)
    }

    @Test("explicit voice start uses the current segment and old failures cannot move it")
    func manualTakeoverInvalidatesOldPipeline() async throws {
        let drainGate = TestGate()
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(drainGate: drainGate)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        harness.session.moveToSegment(1)

        await harness.session.enableVoiceAssist()

        #expect(harness.session.currentSegmentIndex == 1)
        #expect(harness.session.phase == .following)
        #expect(harness.session.voiceAssistState == .following)
        #expect(harness.coordinator.occupancy?.kind == .teleprompter)
        #expect(harness.sourceFactory.sources.first?.startCount == 1)
        let client = try #require(harness.clientFactory.clients.first)
        #expect(await client.currentCounters().connectCount == 1)

        harness.session.moveToSegment(2)
        #expect(harness.session.currentSegmentIndex == 2)
        #expect(harness.session.voiceAssistState == .stopping)

        await client.emit(
            .failed(itemID: "old", code: "backend_busy", message: "旧连接失败"),
            eventID: "old-failure"
        )
        await settleTasks()
        #expect(harness.session.currentSegmentIndex == 2)
        #expect(harness.session.blocked == nil)
        #expect(harness.session.phase == .manual)

        await drainGate.open()
        await harness.session.disableVoiceAssist()
        #expect(harness.session.voiceAssistState == .pausedByUser)
        #expect(harness.sourceFactory.sources.first?.stopCount == 1)
        #expect(await client.currentCounters().closeCount == 1)
    }

    @Test("manual takeover during a delayed connect closes the late client")
    func lateConnectAfterManualTakeoverIsReleased() async throws {
        let connectGate = TestGate()
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(connectGate: connectGate)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        let startTask = Task { await harness.session.enableVoiceAssist() }
        await connectGate.waitUntilWaiting()
        harness.session.moveToSegment(2)
        await connectGate.open()
        await startTask.value
        await waitFor { await harness.clientFactory.clients.first?.currentCounters().closeCount == 1 }

        #expect(harness.session.currentSegmentIndex == 2)
        #expect(harness.session.voiceAssistState == .pausedByUser)
        #expect(harness.coordinator.occupancy == nil)
        #expect(harness.sourceFactory.sources.isEmpty)
        let client = try #require(harness.clientFactory.clients.first)
        #expect(await client.currentCounters().closeCount == 1)
    }

    @Test("repeated manual navigation keeps the last position and starts one stop only")
    func repeatedManualNavigationIsIdempotent() async throws {
        let drainGate = TestGate()
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(drainGate: drainGate)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()
        let client = try #require(harness.clientFactory.clients.first)

        for _ in 0..<20 {
            harness.session.moveToSegment(2)
            harness.session.moveToSegment(1)
            harness.session.moveToSegment(2)
        }

        #expect(harness.session.currentSegmentIndex == 2)
        #expect(harness.session.voiceAssistState == .stopping)
        await waitFor { await client.currentCounters().drainCount == 1 }
        #expect(await client.currentCounters().drainCount == 1)

        await drainGate.open()
        await harness.session.disableVoiceAssist()
        #expect(await client.currentCounters().drainCount == 1)
        #expect(await client.currentCounters().closeCount == 1)
        #expect(harness.sourceFactory.sources.first?.stopCount == 1)
    }

    @Test("stop failure remains fail-closed until an explicit stop retry")
    func stopFailureBlocksASecondPipeline() async throws {
        let harness = try TeleprompterSessionHarness(
            clientFactory: FakeTeleprompterClientFactory(drainFails: true)
        )
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        await harness.session.enableVoiceAssist()
        await harness.session.disableVoiceAssist()

        guard case .stopFailed = harness.session.voiceAssistState else {
            Issue.record("expected stopFailed, got \(harness.session.voiceAssistState)")
            return
        }
        #expect(!harness.session.voiceAssistState.canStart)
        #expect(harness.clientFactory.clients.count == 1)

        await harness.session.retryStopVoiceAssist()
        #expect(harness.session.voiceAssistState == .off)

        await harness.session.enableVoiceAssist()
        #expect(harness.clientFactory.clients.count == 2)
        await harness.session.closeStage()
    }

    @Test("close releases resources and reopening keeps position but resets voice")
    func closeAndReopenPreservesPosition() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        harness.session.moveToSegment(2)
        await harness.session.enableVoiceAssist()
        let client = try #require(harness.clientFactory.clients.first)

        await harness.session.closeStage()

        #expect(!harness.session.isStageOpen)
        #expect(harness.session.voiceAssistState == .off)
        #expect(!harness.session.isMicrophoneCapturing)
        #expect(harness.coordinator.occupancy == nil)
        #expect(harness.sourceFactory.sources.first?.stopCount == 1)
        #expect(await client.currentCounters().closeCount == 1)

        try harness.session.openForManualReading()
        #expect(harness.session.currentSegmentIndex == 2)
        #expect(harness.session.voiceAssistState == .off)
        #expect(harness.session.isStageOpen)
        #expect(harness.clientFactory.clients.count == 1)
    }

    @Test("repeated close is idempotent")
    func repeatedCloseDoesNotDuplicateRelease() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()
        await harness.session.enableVoiceAssist()
        let client = try #require(harness.clientFactory.clients.first)

        await harness.session.closeStage()
        await harness.session.closeStage()

        #expect(await client.currentCounters().closeCount == 1)
        #expect(await client.currentCounters().drainCount == 1)
        #expect(harness.sourceFactory.sources.first?.stopCount == 1)
        #expect(harness.coordinator.occupancy == nil)
        #expect(!harness.session.isStageOpen)
    }

    @Test("run clock is continuous across voice transitions and resets only on reopen")
    func runClockSurvivesVoiceTransitions() async throws {
        let harness = try TeleprompterSessionHarness()
        defer { harness.cleanup() }
        harness.makeThreeSegmentDocument()
        try harness.session.openForManualReading()

        try await Task.sleep(for: .milliseconds(350))
        let beforeVoice = harness.session.runClock.elapsedSeconds
        #expect(beforeVoice > 0)

        await harness.session.enableVoiceAssist()
        try await Task.sleep(for: .milliseconds(350))
        let afterVoice = harness.session.runClock.elapsedSeconds
        #expect(afterVoice > beforeVoice)

        await harness.session.closeStage()
        #expect(!harness.session.isStageOpen)

        try harness.session.openForManualReading()
        #expect(harness.session.runClock.elapsedSeconds == 0)
    }
}

private enum TestPreparationResponse {
    enum Failure: Error {
        case unavailable
    }

    static func response(for prompt: TeleprompterPreparationPrompt) throws -> String {
        if prompt.schemaVersion == "teleprompter.reduction.v1" {
            return #"{"schema_version":"teleprompter.reduction.v1","patches":[],"review_block_ids":[]}"#
        }
        if prompt.schemaVersion == "teleprompter.grouping.v1" {
            let input = try JSONDecoder().decode(
                TeleprompterPreparationMapInput.self,
                from: Data(prompt.input.utf8)
            )
            guard !input.targets.isEmpty else { throw Failure.unavailable }
            let groups = stride(from: 0, to: input.targets.count, by: 8).map { start in
                TeleprompterGroupingBlock(
                    startUnit: start,
                    endUnit: min(start + 8, input.targets.count)
                )
            }
            return String(decoding: try JSONEncoder().encode(
                TeleprompterGroupingOutput(groups: groups)
            ), as: UTF8.self)
        }
        if prompt.schemaVersion == "teleprompter.rewrite.v1" {
            let input = try JSONDecoder().decode(
                TeleprompterRewriteInput.self,
                from: Data(prompt.input.utf8)
            )
            guard !input.groups.isEmpty else { throw Failure.unavailable }
            let blocks = input.groups.map { group in
                TeleprompterRewriteBlock(
                    blockID: group.id,
                    mode: .speak,
                    text: group.sourceUnits.map(\.rawText).joined(),
                    issues: []
                )
            }
            return String(decoding: try JSONEncoder().encode(
                TeleprompterRewriteOutput(blocks: blocks)
            ), as: UTF8.self)
        }
        throw Failure.unavailable
    }
}

@MainActor
private func settleTasks() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

@MainActor
private func waitFor(
    timeoutIterations: Int = 200,
    _ condition: @MainActor () async -> Bool
) async {
    for _ in 0..<timeoutIterations {
        if await condition() { return }
        await Task.yield()
    }
}
