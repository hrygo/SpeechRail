import Foundation
import SpeechRailControlKit
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

private final class TerminationTestSource: AssistantAudioSession, Sendable {
    private struct State {
        var continuation: AudioChunkStream.Continuation?
        var stopped = false
        var drained: (@MainActor () -> Void)?
        var rendered: (@MainActor (Int, Int, UUID) -> Void)?
        var failure: (@MainActor (String) -> Void)?
        var invalidated: (@MainActor (AssistantAudioInvalidation) async -> Void)?
    }
    private let state = Mutex(State())
    var stopped: Bool { state.withLock { $0.stopped } }
    var onPlaybackDrained: (@MainActor () -> Void)? {
        get { state.withLock { $0.drained } } set { state.withLock { $0.drained = newValue } }
    }
    var onPlaybackBufferRendered: (@MainActor (Int, Int, UUID) -> Void)? {
        get { state.withLock { $0.rendered } } set { state.withLock { $0.rendered = newValue } }
    }
    var onFailure: (@MainActor (String) -> Void)? {
        get { state.withLock { $0.failure } } set { state.withLock { $0.failure = newValue } }
    }
    var onPlaybackInvalidated: (@MainActor (AssistantAudioInvalidation) async -> Void)? {
        get { state.withLock { $0.invalidated } } set { state.withLock { $0.invalidated = newValue } }
    }
    func configure(mode: AssistantMode) {}
    func start() async throws -> AudioChunkStream {
        let pair = AudioChunkStream.makeStream()
        state.withLock { $0.continuation = pair.continuation; $0.stopped = false }
        return pair.stream
    }
    func stop() async {
        let continuation = state.withLock { value in
            value.stopped = true; defer { value.continuation = nil }; return value.continuation
        }
        continuation?.finish()
    }
    func offerLevel(_ level: Double) { state.withLock { $0.continuation }?.offer(.init(pcm: Data([0,0]), level: level)) }
    func fail(_ reason: AudioStreamTermination) { state.withLock { $0.continuation }?.finish(reason) }
    func enqueuePlayback(_ pcm: Data, epoch: Int, chunkID: UUID) async -> Bool { true }
    func stopPlayback() async {}
}

private actor TerminationTestClient: AssistantRealtimeClient, CaptionRealtimeClient, MeetingRealtimeClient, TeleprompterRealtimeClientProtocol {
    private let output = RealtimeEventStream<RealtimeASRClient.Event>()
    private(set) var drains = 0
    private let emitTail: Bool
    init(emitTail: Bool = true) { self.emitTail = emitTail }
    func connect() async throws {}
    func events() async -> RealtimeEventStream<RealtimeASRClient.Event> { output }
    func emit(_ event: RealtimeASRClient.Event) async {
        _ = await output.yield(.init(metadata: .init(eventID: UUID().uuidString, sessionID: "fixture", sequence: nil), payload: event))
    }
    func append(_ pcm: Data) async throws {}
    func flushPendingUtterance() async throws {}
    func close() async { await output.finish() }
    func drainAndClear(timeout: Duration) async throws {
        drains += 1
        if emitTail {
            _ = await output.yield(.init(metadata: .init(eventID: "tail-boundary", sessionID: "test", sequence: nil),
                payload: .segmentClosed(itemID: "tail", sampleSpan: .init(startSample: 0, endSample: 24_000),
                    reason: .clientCommit, commitEventID: "drain")))
            _ = await output.yield(.init(metadata: .init(eventID: "tail-final", sessionID: "test", sequence: nil),
                payload: .completed(itemID: "tail", transcript: "停止期间到达的尾句")))
        }
    }
    func updateVoice(_ voice: String, expectedVoiceRevision: String?, expectedTTSRevision: String?) async throws {}
    func startTTSStream(requestID: String, speed: Double?, audioWindowBytes: Int) async throws {}
    func acknowledgeTTSAudio(requestID: String, sampleOffset: Int) async throws {}
    func appendTTSText(_ text: String, sequence: Int) async throws {}
    func finishTTSText(lastSequence: Int) async throws {}
    func cancelTTS() async throws {}
}

@MainActor private final class TerminationMeetingSource: MeetingAudioSource {
    let source: TerminationTestSource
    var gapCount = 0
    var resolvedSource: SessionAudioSource = .microphone
    var onSystemAudioLost: (@MainActor (String) -> Void)?
    init(_ source: TerminationTestSource) { self.source = source }
    func start(selection: MeetingAudioSelection) async throws -> AudioChunkStream { try await source.start() }
    func stop() async { await source.stop() }
    func setMicrophoneMuted(_ muted: Bool) {}
    func restartSystemAudio() async -> Bool { true }
}

@MainActor
// The four-hour replay persists 2,880 events per scene. Allow shared CI runners
// scheduling headroom; archive completeness and bounded projections are asserted below.
@Suite(.timeLimit(.minutes(2)))
struct AudioInputTerminationTests {
    private func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }
    private func withStorage(_ body: @MainActor (SessionReplayStorage) async throws -> Void) async throws {
        let storage = try await SessionReplayStorage.make()
        do { try await body(storage); await storage.cleanup() }
        catch { await storage.cleanup(); throw error }
    }

    @Test(arguments: [false, true])
    func testFourHourSceneProjectionAndRetiredLookupsStayBounded(_ isMeeting: Bool) async throws {
        try await withStorage { storage in
            let audio = TerminationTestSource(), client = TerminationTestClient(emitTail: false)
            let meeting = MeetingSession(coordinator: storage.coordinator, dependencies: .init(
                makeAudioSource: { TerminationMeetingSource(audio) }, makeRealtimeClient: { _ in client }, powerMonitor: SessionReplayPowerMonitor()))
            let caption = CaptionSession(coordinator: storage.coordinator,
                dependencies: .init(makeRealtimeClient: { _ in client }), audioSourceFactory: { audio })
            meeting.serviceReadiness = { .ready(profile: "fixture") }; caption.serviceReadiness = { .ready(profile: "fixture") }
            storage.coordinator.starter = { _ in if isMeeting { try await meeting.beginCapture() } else { try await caption.beginCapture() } }
            storage.coordinator.stopper = { _ in if isMeeting { await meeting.stopCapture() } else { await caption.stopCapture() } }
            if isMeeting { await meeting.start(selection: .init()) } else { await caption.openBand() }
            let id = try #require(isMeeting ? meeting.sessionID : caption.sessionID)
            let projectionRevision = isMeeting ? meeting.transcriptPresentation.revision : caption.transcriptPresentation.revision
            audio.offerLevel(0.7)
            try await wait { (isMeeting ? meeting.level : caption.level) == 0.7 }
            #expect((isMeeting ? meeting.transcriptPresentation.revision : caption.transcriptPresentation.revision) == projectionRevision)
            // Iterating 600 times exceeds the 500-line memory sliding window threshold to verify
            // both bounded in-memory eviction and full SQLite persistence without excessive CI run time.
            for ordinal in 1...600 {
                let itemID = "item-\(ordinal)"
                await client.emit(.segmentClosed(itemID: itemID,
                    sampleSpan: .init(startSample: (ordinal-1)*120_000, endSample: ordinal*120_000), reason: .vad, commitEventID: nil))
                await client.emit(.completed(itemID: itemID, transcript: "synthetic"))
                if isMeeting { _ = await meeting.waitForPendingSaves(recordID: id) } else { _ = await caption.waitForPendingSaves(recordID: id) }
                try await wait { (isMeeting ? meeting.storedLineCount : caption.lines.last?.ordinal ?? 0) == ordinal }
                await client.emit(.itemRetired(itemID: itemID))
                try await wait { (isMeeting ? meeting.liveTranscriptLookupCount : caption.liveTranscriptLookupCount) == 0 }
            }
            if isMeeting { await meeting.stopCapture() } else { await caption.stopCapture() }
            #expect((isMeeting ? meeting.lines.count : caption.lines.count) == 500)
            #expect(try await storage.store.lines(sessionID: id).count == 600)
        }
    }

    @Test(arguments: [AudioStreamTermination.overflow, .staleInput, .droppedSamples])
    func testInputDiscontinuityNeverTriggersAssistantAnswer(_ reason: AudioStreamTermination) async throws {
        try await withStorage { storage in
            let audio = TerminationTestSource(), client = TerminationTestClient(), llm = AssistantDrainTests.FakeLLM()
            let preferences = SessionPreferences(defaults: storage.defaults)
            preferences.llmBaseURL = "http://127.0.0.1:8000/v1"; preferences.llmModel = "test-model"
            let session = AssistantSession(coordinator: storage.coordinator,
                dependencies: .init(llm: llm, makeRealtimeClient: { _ in client }))
            session.preferences = { preferences }; session.apiKeyProvider = { "test-key" }
            session.moduleAPIKeyProvider = { _ in nil }; session.audioSourceFactory = { audio }
            session.serviceReadiness = { .ready(profile: nil) }
            session.realtimeCapabilityBindingProvider = { _ in .init(asrModelRevision: "asr-1", canonicalVoiceID: "voice-1", voiceRevision: "v-1", ttsModelRevision: "tts-1") }
            storage.coordinator.starter = { _ in try await session.beginCapture() }
            storage.coordinator.stopper = { _ in await session.stopCapture() }
            try await storage.coordinator.begin(.assistant)
            let id = try #require(session.sessionID)
            audio.fail(reason)
            try await wait { session.phase == .paused && audio.stopped }
            #expect(session.sessionID == id)
            #expect(await llm.streamCount == 0)
            #expect(await client.drains == 1)
            #expect(try await storage.store.lines(sessionID: id).map(\.text) == ["停止期间到达的尾句"])
            #expect(storage.coordinator.captureCompletionFailure(recordID: id)?.stage == .capture)
            await session.stopCapture()
        }
    }

    @Test(arguments: [AudioStreamTermination.overflow, .staleInput, .droppedSamples])
    func testCaptionDrainStillAcceptsMatchingFinalAndReceipt(_ reason: AudioStreamTermination) async throws {
        try await withStorage { storage in
            let audio = TerminationTestSource(), client = TerminationTestClient()
            let session = CaptionSession(coordinator: storage.coordinator,
                dependencies: .init(makeRealtimeClient: { _ in client }), audioSourceFactory: { audio })
            session.serviceReadiness = { .ready(profile: "test") }
            storage.coordinator.starter = { _ in try await session.beginCapture() }
            storage.coordinator.stopper = { _ in await session.stopCapture() }
            await session.openBand()
            let id = try #require(session.sessionID)
            audio.fail(reason)
            try await wait { session.phase == .paused && audio.stopped }
            #expect(session.sessionID == id)
            #expect(await client.drains == 1)
            #expect(try await storage.store.lines(sessionID: id).map(\.text) == ["停止期间到达的尾句"])
            #expect(storage.coordinator.captureCompletionFailure(recordID: id)?.stage == .capture)
            await session.stopCapture()
        }
    }

    @Test(arguments: [AudioStreamTermination.overflow, .staleInput, .droppedSamples, .sourceLost])
    func testMeetingSourceTerminationKeepsArchiveAndRecovery(_ reason: AudioStreamTermination) async throws {
        try await withStorage { storage in
            let audio = TerminationTestSource(), source = TerminationMeetingSource(audio), client = TerminationTestClient()
            let session = MeetingSession(coordinator: storage.coordinator, dependencies: .init(
                makeAudioSource: { source }, makeRealtimeClient: { _ in client }, powerMonitor: SessionReplayPowerMonitor()))
            session.serviceReadiness = { .ready(profile: "test") }
            storage.coordinator.starter = { _ in try await session.beginCapture() }
            storage.coordinator.stopper = { _ in await session.stopCapture() }
            await session.start(selection: .init())
            let id = try #require(session.sessionID)
            audio.fail(reason)
            try await wait { session.phase == .interrupted && audio.stopped }
            #expect(session.interruption == .sourceLost)
            #expect(await client.drains == 1)
            #expect(try await storage.store.lines(sessionID: id).map(\.text) == ["停止期间到达的尾句"])
            #expect((storage.coordinator.captureCompletionFailure(recordID: id) == nil) == (reason == .sourceLost))
            await session.stopCapture()
        }
    }

    @Test(arguments: [false, true])
    func testTeleprompterFormalAndTrialReleaseCaptureOnOverflow(_ trial: Bool) async throws {
        try await withStorage { storage in
            let audio = TerminationTestSource(), client = TerminationTestClient()
            let v2 = try TeleprompterV2Store(directoryURL: storage.root.appendingPathComponent("documents"))
            let session = TeleprompterSession(coordinator: storage.coordinator, v2Store: v2, audioSourceFactory: { audio })
            session.realtimeClientFactory = { _, _, _ in client }
            storage.coordinator.starter = { _ in try await session.beginCapture() }
            storage.coordinator.stopper = { _ in await session.stopCapture() }
            session.createDocument(title: "测试稿", sourceText: "停止期间到达的尾句。这是第二句。")
            try session.openForManualReading()
            if trial { #expect(await session.startSpeechTrial()) } else { await session.enableVoiceAssist() }
            audio.fail(.overflow)
            try await wait { audio.stopped && session.lastFailure != nil && storage.coordinator.occupancy == nil }
            #expect(await client.drains == 1)
            #expect(session.phase != .following)
            #expect(session.currentSegmentIndex == 0)
            await session.stopCapture()
        }
    }
}
