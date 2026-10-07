import Foundation
import CoreFoundation
import CryptoKit
import SpeechRailControlKit
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif
enum SessionReplayScene: String {
    case assistant
    case meeting
    case caption
    case teleprompter

    var preset: ASRScenePreset {
        switch self {
        case .assistant: .assistantTurnTaking
        case .meeting: .meeting
        case .caption: .caption
        case .teleprompter: .teleprompter
        }
    }
}

struct SessionReplayConfiguration {
    let fixtureID: String
    let scene: SessionReplayScene
    let audioURL: URL
    let language: String?
    let referenceText: String?
    let teleprompterExpectedPrefixRanges: [SessionReplayExpectedPrefixRange]?
    let port: Int
    let expectedASRRevision: String?
    let outputURL: URL

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard let manifestPath = environment["SPEECHRAIL_ASR_SESSION_MANIFEST"],
              let fixtureID = environment["SPEECHRAIL_ASR_SESSION_FIXTURE_ID"],
              let sceneRaw = environment["SPEECHRAIL_ASR_SESSION_SCENE"],
              let outputPath = environment["SPEECHRAIL_ASR_SESSION_OUTPUT"],
              let scene = SessionReplayScene(rawValue: sceneRaw),
              isSafeFixtureID(fixtureID) else {
            throw SessionReplayFailure.missingConfiguration
        }
        guard let port = Int(environment["SPEECHRAIL_ASR_SESSION_PORT"] ?? "8201"),
              (1_024...65_535).contains(port) else {
            throw SessionReplayFailure.invalidConfiguration
        }

        let repositoryRoot = repositoryRootURL
        let manifestPathExpanded = (manifestPath as NSString).expandingTildeInPath
        guard manifestPathExpanded.hasPrefix("/") else {
            throw SessionReplayFailure.invalidConfiguration
        }
        let manifestURL = URL(fileURLWithPath: manifestPathExpanded).standardizedFileURL.resolvingSymlinksInPath()
        guard isExternal(manifestURL, from: repositoryRoot),
              FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SessionReplayFailure.invalidConfiguration
        }
        let manifest: SessionReplayManifest
        do {
            manifest = try JSONDecoder().decode(
                SessionReplayManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw SessionReplayFailure.invalidConfiguration
        }
        guard let fixture = manifest.fixtures.first(where: {
            $0.id == fixtureID && $0.scene == scene.rawValue
        }) else {
            throw SessionReplayFailure.fixtureNotFound
        }
        let audioPath = (fixture.path as NSString).expandingTildeInPath
        guard audioPath.hasPrefix("/") else { throw SessionReplayFailure.invalidConfiguration }
        let audioURL = URL(fileURLWithPath: audioPath).standardizedFileURL.resolvingSymlinksInPath()
        guard isExternal(audioURL, from: repositoryRoot),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SessionReplayFailure.invalidConfiguration
        }
        let outputPathExpanded = (outputPath as NSString).expandingTildeInPath
        guard outputPathExpanded.hasPrefix("/") else { throw SessionReplayFailure.invalidConfiguration }
        let outputURL = URL(fileURLWithPath: outputPathExpanded).standardizedFileURL.resolvingSymlinksInPath()
        guard isExternal(outputURL, from: repositoryRoot),
              !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SessionReplayFailure.invalidConfiguration
        }
        let referenceText = fixture.referenceText
        guard scene != .teleprompter || !(referenceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            throw SessionReplayFailure.missingTeleprompterReference
        }
        let expectedPrefixRanges = fixture.teleprompterExpectedPrefixRanges
        if scene == .teleprompter || expectedPrefixRanges != nil {
            guard let referenceText,
                  SessionReplayExpectedPrefixRangeIntegrity.validateManifest(
                    expectedPrefixRanges,
                    sourceUTF16Length: referenceText.utf16.count
                  ) else {
                throw SessionReplayFailure.invalidConfiguration
            }
        }
        return Self(
            fixtureID: fixtureID,
            scene: scene,
            audioURL: audioURL,
            language: fixture.language.flatMap { $0 == "auto" ? nil : $0 },
            referenceText: referenceText,
            teleprompterExpectedPrefixRanges: expectedPrefixRanges,
            port: port,
            expectedASRRevision: environment["SPEECHRAIL_ASR_SESSION_EXPECTED_REVISION"],
            outputURL: outputURL
        )
    }

    func hasCompleteTeleprompterPrefixCoverage(fixtureSamples: Int) -> Bool {
        guard scene == .teleprompter else { return true }
        guard let referenceText else { return false }
        return SessionReplayExpectedPrefixRangeIntegrity.validateManifest(
            teleprompterExpectedPrefixRanges,
            sourceUTF16Length: referenceText.utf16.count,
            fixtureSamples: fixtureSamples
        )
    }

    func write(_ summary: SessionReplaySummary) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: try encoder.encode(summary),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SessionReplayFailure.outputAlreadyExists
        }
    }

    private static var repositoryRootURL: URL {
        var url = URL(fileURLWithPath: #filePath).standardizedFileURL
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.resolvingSymlinksInPath()
    }

    private static func isExternal(_ url: URL, from root: URL) -> Bool {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path != root.path && !url.path.hasPrefix(rootPrefix)
    }

    private static func isSafeFixtureID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
                    .contains($0)
            }
    }
}

private struct SessionReplayManifest: Decodable {
    let fixtures: [SessionReplayFixture]
}

private struct SessionReplayFixture: Decodable {
    let id: String
    let scene: String
    let path: String
    let language: String?
    let referenceText: String?
    let teleprompterExpectedPrefixRanges: [SessionReplayExpectedPrefixRange]?

    enum CodingKeys: String, CodingKey {
        case id
        case scene
        case path
        case audioPath = "audio_path"
        case audio
        case language
        case referenceText = "reference_text"
        case teleprompterExpectedPrefixRanges = "teleprompter_expected_prefix_ranges"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        scene = try values.decode(String.self, forKey: .scene)
        if let value = try values.decodeIfPresent(String.self, forKey: .path) {
            path = value
        } else if let value = try values.decodeIfPresent(String.self, forKey: .audioPath) {
            path = value
        } else {
            path = try values.decode(String.self, forKey: .audio)
        }
        language = try values.decodeIfPresent(String.self, forKey: .language)
        referenceText = try values.decodeIfPresent(String.self, forKey: .referenceText)
        teleprompterExpectedPrefixRanges = try values.decodeIfPresent(
            [SessionReplayExpectedPrefixRange].self,
            forKey: .teleprompterExpectedPrefixRanges
        )
    }
}

struct SessionReplayExpectedPrefixRange: Decodable, Equatable, Sendable {
    let endSample24K: Int
    let minPrefixUTF16: Int
    let maxPrefixUTF16: Int

    enum CodingKeys: String, CodingKey {
        case endSample24K = "end_sample_24k"
        case minPrefixUTF16 = "min_prefix_utf16"
        case maxPrefixUTF16 = "max_prefix_utf16"
    }
}

enum SessionReplayExpectedPrefixRangeIntegrity {
    static let samplesPerBucket = 960

    static func validateManifest(
        _ ranges: [SessionReplayExpectedPrefixRange]?,
        sourceUTF16Length: Int,
        fixtureSamples: Int? = nil
    ) -> Bool {
        guard let ranges,
              !ranges.isEmpty,
              sourceUTF16Length > 0 else {
            return false
        }

        var previousEndSample = 0
        for range in ranges {
            guard range.endSample24K > previousEndSample,
                  range.endSample24K - previousEndSample <= samplesPerBucket,
              range.minPrefixUTF16 >= 0,
              range.maxPrefixUTF16 >= range.minPrefixUTF16,
              range.maxPrefixUTF16 <= sourceUTF16Length else {
                return false
            }
            previousEndSample = range.endSample24K
        }

        if let fixtureSamples {
            guard fixtureSamples > 0,
                  let lastRange = ranges.last,
                  fixtureSamples <= Int.max - 2,
                  lastRange.endSample24K == fixtureSamples + 2 else {
                return false
            }
        }
        return true
    }

    static func validateObservations(
        sourceOffsetsUTF16: [Int],
        sourceSampleWatermarks: [Int],
        ranges: [SessionReplayExpectedPrefixRange]
    ) -> Bool {
        guard !sourceOffsetsUTF16.isEmpty,
              !ranges.isEmpty,
              sourceOffsetsUTF16.count == sourceSampleWatermarks.count,
              ranges.allSatisfy({
                  $0.endSample24K > 0
                      && $0.minPrefixUTF16 >= 0
                      && $0.maxPrefixUTF16 >= $0.minPrefixUTF16
              }),
              zip(ranges, ranges.dropFirst()).allSatisfy({ pair in
                  pair.0.endSample24K < pair.1.endSample24K
                      && pair.1.endSample24K - pair.0.endSample24K <= samplesPerBucket
              }),
              sourceSampleWatermarks.allSatisfy({ $0 > 0 }),
              zip(sourceSampleWatermarks, sourceSampleWatermarks.dropFirst())
                  .allSatisfy({ pair in pair.0 <= pair.1 }) else {
            return false
        }

        return zip(sourceOffsetsUTF16, sourceSampleWatermarks).allSatisfy { offset, watermark in
            allows(offsetUTF16: offset, atSourceSampleWatermark: watermark, in: ranges)
        }
    }

    static func allows(
        offsetUTF16: Int,
        atSourceSampleWatermark watermark: Int,
        in ranges: [SessionReplayExpectedPrefixRange]
    ) -> Bool {
        guard watermark > 0,
              let range = ranges.first(where: { $0.endSample24K >= watermark }) else {
            return false
        }
        return (range.minPrefixUTF16...range.maxPrefixUTF16).contains(offsetUTF16)
    }
}

struct SessionReplayStorage {
    let root: URL
    let defaultsName: String
    let defaults: UserDefaults
    let store: SessionStore
    let coordinator: SessionCoordinator

    @MainActor
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-asr-session-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = "speechrail-asr-session-replay-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw SessionReplayFailure.storageUnavailable
        }
        let store = SessionStore(directory: root.appendingPathComponent("session-library", isDirectory: true))
        let coordinator = SessionCoordinator(store: store, defaults: defaults)
        await coordinator.openStore()
        return Self(root: root, defaultsName: defaultsName, defaults: defaults, store: store, coordinator: coordinator)
    }

    @MainActor
    func cleanup() async {
        await store.close()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

final class SessionReplayCaptureSource: AudioChunkSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var hasStarted = false
    private var hasStopped = false

    func start() async throws -> AsyncStream<AudioChunk> {
        AsyncStream(bufferingPolicy: .bufferingOldest(128)) { continuation in
            lock.withLock {
                self.continuation = continuation
                hasStarted = true
                hasStopped = false
            }
        }
    }

    func stop() {
        let active = lock.withLock { () -> AsyncStream<AudioChunk>.Continuation? in
            let active = continuation
            continuation = nil
            hasStopped = true
            return active
        }
        active?.finish()
    }

    var isReleased: Bool {
        lock.withLock { hasStarted && hasStopped && continuation == nil }
    }

    func yield(_ chunk: AudioChunk) -> Bool {
        guard let active = lock.withLock({ continuation }) else { return false }
        if case .enqueued = active.yield(chunk) { return true }
        return false
    }
}

@MainActor
final class SessionReplayMeetingSource: MeetingAudioSource {
    private let capture: SessionReplayCaptureSource
    var gapCount = 0
    var resolvedSource: SessionAudioSource = .microphone
    var onSystemAudioLost: (@MainActor (String) -> Void)?

    init(capture: SessionReplayCaptureSource) {
        self.capture = capture
    }

    func start(selection: MeetingAudioSelection) async throws -> AsyncStream<AudioChunk> {
        try await capture.start()
    }

    func stop() async { capture.stop() }
    func setMicrophoneMuted(_ muted: Bool) {}
    func restartSystemAudio() async -> Bool { false }
}

@MainActor
final class SessionReplayPowerMonitor: MeetingPowerMonitor {
    func startObservingSleep(_ onSleep: @escaping @MainActor () -> Void) -> AnyObject {
        NSObject()
    }
}

final class SessionReplayMeetingClock: MeetingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var captureOriginDate: Date?

    func now() -> Date {
        let current = Date()
        // The first call anchors this fresh capture generation. Later calls
        // timestamp persistence observations and must not move that anchor.
        lock.withLock {
            if captureOriginDate == nil { captureOriginDate = current }
        }
        return current
    }

    var captureOrigin: Date? {
        lock.withLock { captureOriginDate }
    }
}

final class SessionReplayClientHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SessionReplayClient?

    var client: SessionReplayClient? { lock.withLock { stored } }

    func install(_ client: SessionReplayClient) {
        lock.withLock { stored = client }
    }
}

actor SessionReplayClient: AssistantRealtimeClient, MeetingRealtimeClient,
    CaptionRealtimeClient, TeleprompterRealtimeClientProtocol
{
    typealias AlignmentObserver = @Sendable (
        RealtimeEventEnvelope<RealtimeASRClient.Event>, Int, Int
    ) async -> Void

    private let realtime: RealtimeASRClient
    private let recorder: SessionReplayRecorder
    private let alignmentObserver: AlignmentObserver?
    private var mirroredEvents: RealtimeEventStream<RealtimeASRClient.Event>?
    private var mirrorTask: Task<Void, Never>?
    private var mirrorWasStarted = false
    private var mirrorWasDrained = false
    private var closeCompleted = false
    private var uploadedSamples = 0
    private var drainSucceeded = false
    private var activeTTSRequestID: String?
    private var acceptedTTSTextCodepoints = 0

    init(
        realtime: RealtimeASRClient,
        recorder: SessionReplayRecorder,
        alignmentObserver: AlignmentObserver? = nil
    ) {
        self.realtime = realtime
        self.recorder = recorder
        self.alignmentObserver = alignmentObserver
    }

    func events() async -> RealtimeEventStream<RealtimeASRClient.Event> {
        if let mirroredEvents { return mirroredEvents }
        let mirrored = RealtimeEventStream<RealtimeASRClient.Event>()
        mirroredEvents = mirrored
        mirrorWasStarted = true
        let upstream = await realtime.events()
        mirrorTask = Task {
            for await envelope in upstream {
                await recorder.record(envelope)
                var snapshot: SessionReplaySnapshot?
                if alignmentObserver != nil {
                    snapshot = await recorder.snapshot()
                }
                if await mirrored.yield(envelope) != .enqueued {
                    await recorder.recordMirrorOverflow()
                } else if let alignmentObserver, let snapshot {
                    switch envelope.payload {
                    case .partial, .partialSnapshot, .completed:
                        // Deliver one alignment event at a time. The observer
                        // acknowledges Session processing before the next yield,
                        // so intermediate revisions cannot escape observation.
                        await alignmentObserver(
                            envelope, snapshot.recordedAlignmentEventCount,
                            snapshot.sourceSamplesYielded
                        )
                    default:
                        break
                    }
                }
            }
            await mirrored.finish()
        }
        return mirrored
    }

    func connect() async throws { try await realtime.connect() }

    func close() async {
        await realtime.close()
        let task = mirrorTask
        await task?.value
        mirrorWasDrained = !mirrorWasStarted || task != nil
        mirrorTask = nil
        closeCompleted = true
    }

    func releaseSnapshot() -> SessionReplayClientReleaseSnapshot {
        SessionReplayClientReleaseSnapshot(
            closed: closeCompleted,
            mirrorStarted: mirrorWasStarted,
            mirrorDrained: mirrorWasDrained && mirrorTask == nil
        )
    }

    func append(_ pcm: Data) async throws {
        try await realtime.append(pcm)
        uploadedSamples += pcm.count / MemoryLayout<Int16>.size
        await recorder.recordUploadedPCM(pcm)
    }

    func flushPendingUtterance() async throws {
        try await realtime.flushPendingUtterance()
    }

    func drainAndClear(timeout: Duration) async throws {
        try await realtime.drainAndClear(timeout: timeout)
        drainSucceeded = true
    }

    func updateVoice(
        _ voice: String,
        expectedVoiceRevision: String?,
        expectedTTSRevision: String?
    ) async throws {
        try await realtime.updateVoice(
            voice,
            expectedVoiceRevision: expectedVoiceRevision,
            expectedTTSRevision: expectedTTSRevision
        )
    }

    func startTTSStream(requestID: String, speed: Double?, audioWindowBytes: Int) async throws {
        activeTTSRequestID = requestID
        acceptedTTSTextCodepoints = 0
        await emit(.ttsStarted(requestID: requestID, taskID: "fake-session-tts", limits: nil))
    }

    func acknowledgeTTSAudio(requestID: String, sampleOffset: Int) async throws {
        // This harness synthesizes TTS text/lifecycle events but never receives
        // TTS audio, so there is no server-side audio window to acknowledge.
    }

    func appendTTSText(_ text: String, sequence: Int) async throws {
        guard let requestID = activeTTSRequestID else { throw SessionReplayFailure.syntheticTTSUnavailable }
        acceptedTTSTextCodepoints += text.unicodeScalars.count
        await emit(
            .ttsTextAccepted(
                requestID: requestID,
                taskID: "fake-session-tts",
                appendSequence: sequence,
                totalCodepoints: acceptedTTSTextCodepoints
            )
        )
    }

    func finishTTSText(lastSequence: Int) async throws {
        guard let requestID = activeTTSRequestID else { throw SessionReplayFailure.syntheticTTSUnavailable }
        await emit(
            .ttsEnded(
                requestID: requestID,
                taskID: "fake-session-tts",
                status: "completed",
                code: nil,
                message: nil
            )
        )
        activeTTSRequestID = nil
    }

    func cancelTTS() async throws {
        guard let requestID = activeTTSRequestID else { return }
        await emit(
            .ttsEnded(
                requestID: requestID,
                taskID: "fake-session-tts",
                status: "cancelled",
                code: nil,
                message: nil
            )
        )
        activeTTSRequestID = nil
    }

    func uploadSnapshot() -> SessionReplayUploadSnapshot {
        SessionReplayUploadSnapshot(uploadedSamples: uploadedSamples, drainSucceeded: drainSucceeded)
    }

    private func emit(_ payload: RealtimeASRClient.Event) async {
        guard let mirroredEvents else { return }
        let envelope = RealtimeEventEnvelope(
            metadata: RealtimeEventMetadata(eventID: UUID().uuidString, sessionID: "session-replay"),
            payload: payload
        )
        await recorder.record(envelope)
        if await mirroredEvents.yield(envelope) != .enqueued {
            await recorder.recordMirrorOverflow()
        }
    }
}

final class SessionReplayDiscardingPlayback: AssistantPlaybackChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var drainedCallback: (@MainActor () -> Void)?
    private var renderedCallback: (@MainActor (Int, Int, UUID) -> Void)?

    var onDrained: (@MainActor () -> Void)? {
        get { lock.withLock { drainedCallback } }
        set { lock.withLock { drainedCallback = newValue } }
    }

    var onBufferRendered: (@MainActor (Int, Int, UUID) -> Void)? {
        get { lock.withLock { renderedCallback } }
        set { lock.withLock { renderedCallback = newValue } }
    }

    func start() async throws {}

    func enqueue(_ pcm: Data, epoch: Int, chunkID: UUID) async -> Bool {
        let callback = lock.withLock { renderedCallback }
        await callback?(epoch, pcm.count / MemoryLayout<Int16>.size, chunkID)
        return true
    }

    func stop() async {
        let callback = lock.withLock { drainedCallback }
        await callback?()
    }
}

actor SessionReplayAssistantLLM: AssistantLLM {
    private let recorder: SessionReplayRecorder
    private let provider: (any AssistantLLM)?
    private(set) var streamCount = 0
    private(set) var completedStreamCount = 0
    private(set) var outputCharacters = 0
    private(set) var outputContentCharacters = 0
    private(set) var formalInputMatched = true
    private(set) var finalToLLMSeconds: Double?

    init(recorder: SessionReplayRecorder, provider: (any AssistantLLM)? = nil) {
        self.recorder = recorder
        self.provider = provider
    }

    func check(
        configuration: LLMConfiguration,
        apiKey: String?,
        operation: LLMOperation,
        allowThinkingControlFallback: Bool
    ) async -> LLMConnectionResult {
        if let provider {
            return await provider.check(
                configuration: configuration, apiKey: apiKey, operation: operation,
                allowThinkingControlFallback: allowThinkingControlFallback
            )
        }
        return .connected(milliseconds: 1, model: "session-replay-fake")
    }

    func stream(
        configuration: LLMConfiguration,
        messages: [LLMMessage],
        apiKey: String?,
        maxOutputTokens: Int?,
        instructions: String?
    ) async -> AsyncThrowingStream<String, Error> {
        let calledAt = ContinuousClock().now
        await recorder.recordAssistantLLMStreamCall()
        streamCount += 1
        if let provider {
            let snapshot = await recorder.snapshot()
            if let finalAt = snapshot.lastTerminalAt {
                let duration = finalAt.duration(to: calledAt).components
                finalToLLMSeconds = Double(duration.seconds)
                    + Double(duration.attoseconds) / 1e18
            }
            formalInputMatched = formalInputMatched && SessionReplayLLMInputIntegrity.matches(
                messages: messages,
                boundaries: snapshot.boundaries,
                terminalTexts: snapshot.terminalTexts
            )
            let upstream = await provider.stream(
                configuration: configuration, messages: messages, apiKey: apiKey,
                maxOutputTokens: maxOutputTokens, instructions: instructions
            )
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await delta in upstream {
                            try Task.checkCancellation()
                            self.outputCharacters += delta.count
                            self.outputContentCharacters += delta.filter { !$0.isWhitespace }.count
                            continuation.yield(delta)
                        }
                        self.completedStreamCount += 1
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("已处理。")
            continuation.finish()
        }
    }
}

enum SessionReplayLLMInputIntegrity {
    static func matches(
        messages: [LLMMessage],
        boundaries: [SessionReplayBoundary],
        terminalTexts: [String: String]
    ) -> Bool {
        let users = messages.filter { $0.role == .user }
        let ordered = boundaries.sorted { $0.span.startSample < $1.span.startSample }
        guard users.count == 1, !ordered.isEmpty,
              ordered.allSatisfy({ terminalTexts[$0.itemID] != nil }) else { return false }
        let expected = ordered.map { terminalTexts[$0.itemID] ?? "" }.joined()
        // The production assembler supplies CJK/Latin boundary whitespace.
        // Compare every other character, including punctuation and digits.
        let actual = users[0].text.filter { !$0.isWhitespace }
        return !actual.isEmpty && actual == expected.filter { !$0.isWhitespace }
    }
}

actor SessionReplayRecorder {
    private var eventOrder = 0
    private var boundaries: [SessionReplayBoundary] = []
    private var boundaryCounts: [String: Int] = [:]
    private var terminalCounts: [String: Int] = [:]
    private var terminalOrder: [String: Int] = [:]
    private var terminalConnectionIDs: [String: String] = [:]
    private var emptyTerminalItemIDs: Set<String> = []
    private var terminalTexts: [String: String] = [:]
    private var failedTerminalCount = 0
    private var serverErrorCount = 0
    private var emptySuccessCount = 0
    private var nonEmptySuccessCount = 0
    private var previewEventCount = 0
    private var previewRevisionCount = 0
    private var previewRevisionRegressionCount = 0
    private var previewRevisionCountByItem: [String: Int] = [:]
    private var lastRevisionByItem: [String: Int] = [:]
    private var assistantLLMCallOrders: [Int] = []
    private var teleprompterProgressEvidence: SessionReplayTeleprompterProgressEvidence?
    private var firstPreviewOrder: Int?
    private var firstPreviewOrderByItem: [String: Int] = [:]
    private var latestPreviewItemID: String?
    private var teleprompterProcessingDiagnostics: SessionReplayTeleprompterProcessingDiagnostics?
    private var firstTerminalOrder: Int?
    private var firstPreviewAt: ContinuousClock.Instant?
    private var lastTerminalAt: ContinuousClock.Instant?
    private var audioStartedAt = ContinuousClock().now
    private var lastAudioSentAt = ContinuousClock().now
    private var sourceSamplesYielded = 0
    private var uploadedSamples = 0
    private var sourcePCMHasher = SHA256()
    private var uploadedPCMHasher = SHA256()
    private var mirrorOverflowCount = 0
    private var configuredEventCount = 0

    func markAudioStarted(at instant: ContinuousClock.Instant) {
        audioStartedAt = instant
    }

    func recordSourcePCM(_ pcm: Data, sentAt instant: ContinuousClock.Instant) {
        sourceSamplesYielded += pcm.count / MemoryLayout<Int16>.size
        sourcePCMHasher.update(data: pcm)
        lastAudioSentAt = instant
    }

    func recordUploadedPCM(_ pcm: Data) {
        uploadedSamples += pcm.count / MemoryLayout<Int16>.size
        uploadedPCMHasher.update(data: pcm)
    }

    func pcmStreamsMatch() -> Bool {
        let sourceHasher = sourcePCMHasher
        let uploadedHasher = uploadedPCMHasher
        return Data(sourceHasher.finalize()) == Data(uploadedHasher.finalize())
    }

    func recordMirrorOverflow() {
        mirrorOverflowCount += 1
    }

    func recordAssistantLLMStreamCall() {
        eventOrder += 1
        assistantLLMCallOrders.append(eventOrder)
    }

    func recordTeleprompterProgressEvidence(_ evidence: SessionReplayTeleprompterProgressEvidence) {
        teleprompterProgressEvidence = evidence
    }

    func recordTeleprompterProcessingDiagnostics(_ diagnostics: SessionReplayTeleprompterProcessingDiagnostics) {
        teleprompterProcessingDiagnostics = diagnostics
    }

    func record(_ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>) {
        eventOrder += 1
        switch envelope.payload {
        case .configured:
            configuredEventCount += 1
        case .segmentClosed(let itemID, let span, let reason, _):
            boundaryCounts[itemID, default: 0] += 1
            boundaries.append(
                SessionReplayBoundary(
                    itemID: itemID,
                    span: span,
                    reason: reason,
                    order: eventOrder,
                    connectionID: envelope.metadata.sessionID
                )
            )
        case .completed(let itemID, let transcript):
            terminalCounts[itemID, default: 0] += 1
            terminalOrder[itemID] = eventOrder
            if let sessionID = envelope.metadata.sessionID {
                terminalConnectionIDs[itemID] = sessionID
            }
            terminalTexts[itemID] = transcript
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptySuccessCount += 1
                emptyTerminalItemIDs.insert(itemID)
            } else {
                nonEmptySuccessCount += 1
            }
            if firstTerminalOrder == nil { firstTerminalOrder = eventOrder }
            lastTerminalAt = envelope.receivedAt
        case .failed(let itemID, _, _):
            terminalCounts[itemID, default: 0] += 1
            terminalOrder[itemID] = eventOrder
            if let sessionID = envelope.metadata.sessionID {
                terminalConnectionIDs[itemID] = sessionID
            }
            failedTerminalCount += 1
            if firstTerminalOrder == nil { firstTerminalOrder = eventOrder }
            lastTerminalAt = envelope.receivedAt
        case .partial:
            previewEventCount += 1
            if firstPreviewOrder == nil { firstPreviewOrder = eventOrder }
            if firstPreviewAt == nil { firstPreviewAt = envelope.receivedAt }
        case .partialSnapshot(let itemID, let revision, _, _):
            previewEventCount += 1
            if firstPreviewOrder == nil { firstPreviewOrder = eventOrder }
            if firstPreviewAt == nil { firstPreviewAt = envelope.receivedAt }
            previewRevisionCount += 1
            previewRevisionCountByItem[itemID, default: 0] += 1
            if firstPreviewOrderByItem[itemID] == nil {
                firstPreviewOrderByItem[itemID] = eventOrder
            }
            latestPreviewItemID = itemID
            if revision <= lastRevisionByItem[itemID, default: 0] {
                previewRevisionRegressionCount += 1
            }
            lastRevisionByItem[itemID] = revision
        case .serverError:
            serverErrorCount += 1
        default:
            break
        }
    }

    var hasCompletedBudgetRollover: Bool {
        boundaries.contains {
            $0.reason == .budgetRollover
                && terminalCounts[$0.itemID] == 1
                && (terminalOrder[$0.itemID] ?? 0) > $0.order
        }
    }

    func snapshot() -> SessionReplaySnapshot {
        SessionReplaySnapshot(
            boundaries: boundaries,
            boundaryCounts: boundaryCounts,
            terminalCounts: terminalCounts,
            terminalOrder: terminalOrder,
            terminalConnectionIDs: terminalConnectionIDs,
            emptyTerminalItemIDs: emptyTerminalItemIDs,
            terminalTexts: terminalTexts,
            failedTerminalCount: failedTerminalCount,
            serverErrorCount: serverErrorCount,
            emptySuccessCount: emptySuccessCount,
            nonEmptySuccessCount: nonEmptySuccessCount,
            previewEventCount: previewEventCount,
            previewRevisionCount: previewRevisionCount,
            previewRevisionRegressionCount: previewRevisionRegressionCount,
            previewRevisionCountByItem: previewRevisionCountByItem,
            assistantLLMCallOrders: assistantLLMCallOrders,
            teleprompterProgressEvidence: teleprompterProgressEvidence,
            firstPreviewOrder: firstPreviewOrder,
            firstTerminalOrder: firstTerminalOrder,
            firstPreviewAt: firstPreviewAt,
            lastTerminalAt: lastTerminalAt,
            audioStartedAt: audioStartedAt,
            lastAudioSentAt: lastAudioSentAt,
            sourceSamplesYielded: sourceSamplesYielded,
            uploadedSamples: uploadedSamples,
            configuredEventCount: configuredEventCount,
            mirrorOverflowCount: mirrorOverflowCount,
            firstPreviewOrderByItem: firstPreviewOrderByItem,
            latestPreviewItemID: latestPreviewItemID,
            teleprompterProcessingDiagnostics: teleprompterProcessingDiagnostics
        )
    }
}

struct SessionReplayBoundary: Sendable {
    let itemID: String
    let span: RealtimeASRClient.RealtimeSampleSpan
    let reason: ASRSegmentCloseReason
    let order: Int
    let connectionID: String?
}

struct SessionReplaySnapshot: Sendable {
    let boundaries: [SessionReplayBoundary]
    let boundaryCounts: [String: Int]
    let terminalCounts: [String: Int]
    let terminalOrder: [String: Int]
    let terminalConnectionIDs: [String: String]
    let emptyTerminalItemIDs: Set<String>
    let terminalTexts: [String: String]
    let failedTerminalCount: Int
    let serverErrorCount: Int
    let emptySuccessCount: Int
    let nonEmptySuccessCount: Int
    let previewEventCount: Int
    let previewRevisionCount: Int
    let previewRevisionRegressionCount: Int
    let previewRevisionCountByItem: [String: Int]
    let assistantLLMCallOrders: [Int]
    let teleprompterProgressEvidence: SessionReplayTeleprompterProgressEvidence?
    let firstPreviewOrder: Int?
    let firstTerminalOrder: Int?
    let firstPreviewAt: ContinuousClock.Instant?
    let lastTerminalAt: ContinuousClock.Instant?
    let audioStartedAt: ContinuousClock.Instant
    let lastAudioSentAt: ContinuousClock.Instant
    let sourceSamplesYielded: Int
    let uploadedSamples: Int
    let configuredEventCount: Int
    let mirrorOverflowCount: Int
    var firstPreviewOrderByItem: [String: Int] = [:]
    var latestPreviewItemID: String?
    var teleprompterProcessingDiagnostics: SessionReplayTeleprompterProcessingDiagnostics?

    var recordedAlignmentEventCount: Int {
        previewEventCount + emptySuccessCount + nonEmptySuccessCount
    }
}

struct SessionReplayUploadSnapshot: Sendable {
    let uploadedSamples: Int
    let drainSucceeded: Bool
}

struct SessionReplayClientReleaseSnapshot: Sendable {
    let closed: Bool
    let mirrorStarted: Bool
    let mirrorDrained: Bool
}

enum SessionReplaySpanIntegrity {
    static func validate(
        _ boundaries: [SessionReplayBoundary],
        uploadedSampleWatermark: Int,
        maximumSegmentSamples: Int
    ) -> Bool {
        guard !boundaries.isEmpty,
              uploadedSampleWatermark >= 0,
              maximumSegmentSamples > 0,
              boundaries.allSatisfy({
                  $0.span.startSample >= 0
                      && $0.span.endSample > $0.span.startSample
                      && $0.span.endSample <= uploadedSampleWatermark
                      && $0.span.endSample - $0.span.startSample <= maximumSegmentSamples
              }) else {
            return false
        }
        return zip(boundaries, boundaries.dropFirst())
            .allSatisfy { pair in pair.0.span.endSample <= pair.1.span.startSample }
    }
}

enum SessionReplayTerminalIntegrity {
    static func validate(_ snapshot: SessionReplaySnapshot) -> Bool {
        validate(
            boundaries: snapshot.boundaries,
            boundaryCounts: snapshot.boundaryCounts,
            terminalCounts: snapshot.terminalCounts,
            terminalOrder: snapshot.terminalOrder,
            emptyTerminalItemIDs: snapshot.emptyTerminalItemIDs,
            configuredEventCount: snapshot.configuredEventCount,
            mirrorOverflowCount: snapshot.mirrorOverflowCount
        )
    }

    static func validate(
        boundaries: [SessionReplayBoundary],
        boundaryCounts: [String: Int],
        terminalCounts: [String: Int],
        terminalOrder: [String: Int],
        emptyTerminalItemIDs: Set<String>,
        configuredEventCount: Int,
        mirrorOverflowCount: Int
    ) -> Bool {
        guard !boundaries.isEmpty,
              configuredEventCount > 0,
              mirrorOverflowCount == 0,
              boundaryCounts.values.allSatisfy({ $0 == 1 }),
              terminalCounts.values.allSatisfy({ $0 == 1 }),
              boundaries.allSatisfy({ boundary in
                  guard boundaryCounts[boundary.itemID] == 1,
                        terminalCounts[boundary.itemID] == 1,
                        let terminalOrder = terminalOrder[boundary.itemID]
                  else { return false }
                  return terminalOrder > boundary.order
              }) else {
            return false
        }
        let boundaryIDs = Set(boundaryCounts.keys)
        let unboundTerminalIDs = Set(terminalCounts.keys).subtracting(boundaryIDs)
        return unboundTerminalIDs.isSubset(of: emptyTerminalItemIDs)
    }
}

enum SessionReplayRecognitionIntegrity {
    static func validate(_ snapshot: SessionReplaySnapshot) -> Bool {
        validate(
            boundaries: snapshot.boundaries,
            terminalCounts: snapshot.terminalCounts,
            terminalTexts: snapshot.terminalTexts,
            failedTerminalCount: snapshot.failedTerminalCount,
            serverErrorCount: snapshot.serverErrorCount
        )
    }

    static func validate(
        boundaries: [SessionReplayBoundary],
        terminalCounts: [String: Int],
        terminalTexts: [String: String],
        failedTerminalCount: Int,
        serverErrorCount: Int
    ) -> Bool {
        guard failedTerminalCount == 0, serverErrorCount == 0 else { return false }
        return boundaries.contains { boundary in
            guard terminalCounts[boundary.itemID] == 1,
                  let transcript = terminalTexts[boundary.itemID]
            else { return false }
            return !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

enum SessionReplayRowIntegrity {
    private struct ExpectedRow {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private static let timestampToleranceSeconds = 0.000005

    static func matches(
        snapshot: SessionReplaySnapshot,
        rows: [TranscriptLine],
        sessionID: String,
        recordStartedAt: Date,
        ledgerOrigin: Date
    ) -> Bool {
        matches(
            boundaries: snapshot.boundaries,
            boundaryCounts: snapshot.boundaryCounts,
            terminalCounts: snapshot.terminalCounts,
            terminalConnectionIDs: snapshot.terminalConnectionIDs,
            terminalTexts: snapshot.terminalTexts,
            rows: rows,
            sessionID: sessionID,
            recordStartedAt: recordStartedAt,
            ledgerOrigin: ledgerOrigin
        )
    }

    static func matches(
        boundaries: [SessionReplayBoundary],
        boundaryCounts: [String: Int],
        terminalCounts: [String: Int],
        terminalConnectionIDs: [String: String],
        terminalTexts: [String: String],
        rows: [TranscriptLine],
        sessionID: String,
        recordStartedAt: Date,
        ledgerOrigin: Date
    ) -> Bool {
        let ledgerOffset = ledgerOrigin.timeIntervalSince(recordStartedAt)
        guard ledgerOffset.isFinite else { return false }
        let finalizedItems = boundaries.compactMap { boundary -> ExpectedRow? in
            guard let rawTranscript = terminalTexts[boundary.itemID],
                  boundaryCounts[boundary.itemID] == 1,
                  terminalCounts[boundary.itemID] == 1,
                  let connectionID = boundary.connectionID,
                  !connectionID.isEmpty,
                  terminalConnectionIDs[boundary.itemID] == connectionID else {
                return nil
            }
            let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return nil }
            let start = ledgerOffset
                + Double(boundary.span.startSample) / Double(RealtimeASRClient.sampleRate)
            let end = ledgerOffset
                + Double(boundary.span.endSample) / Double(RealtimeASRClient.sampleRate)
            guard start.isFinite, end.isFinite, end > start else { return nil }
            return ExpectedRow(text: transcript, start: start, end: end)
        }
        let stored = rows.filter { $0.role == .speaker && $0.status == .final }
        guard !finalizedItems.isEmpty, finalizedItems.count == stored.count else { return false }
        var unmatched = stored
        for expected in finalizedItems {
            guard let index = unmatched.firstIndex(where: { line in
                guard line.sessionID == sessionID,
                      line.text == expected.text,
                      let start = line.tStart,
                      let end = line.tEnd
                else { return false }
                return abs(start - expected.start) <= timestampToleranceSeconds
                    && abs(end - expected.end) <= timestampToleranceSeconds
            }) else {
                return false
            }
            unmatched.remove(at: index)
        }
        return unmatched.isEmpty
    }
}

enum SessionReplayAssistantTurnIntegrity {
    static func validate(_ snapshot: SessionReplaySnapshot) -> Bool {
        validate(
            boundaries: snapshot.boundaries,
            terminalCounts: snapshot.terminalCounts,
            terminalOrder: snapshot.terminalOrder,
            llmCallOrders: snapshot.assistantLLMCallOrders
        )
    }

    static func validate(
        boundaries: [SessionReplayBoundary],
        terminalCounts: [String: Int],
        terminalOrder: [String: Int],
        llmCallOrders: [Int]
    ) -> Bool {
        guard llmCallOrders.count == 1,
              let llmCallOrder = llmCallOrders.first else {
            return false
        }

        let budgetBoundaries = boundaries.filter { $0.reason == .budgetRollover }
        let vadBoundaries = boundaries.filter { $0.reason == .vad }
        guard !budgetBoundaries.isEmpty,
              vadBoundaries.count == 1,
              let vadBoundary = vadBoundaries.first,
              terminalCounts[vadBoundary.itemID] == 1,
              let vadTerminalOrder = terminalOrder[vadBoundary.itemID],
              vadTerminalOrder > vadBoundary.order,
              llmCallOrder > vadTerminalOrder else {
            return false
        }

        return budgetBoundaries.allSatisfy { boundary in
            guard terminalCounts[boundary.itemID] == 1,
                  let order = terminalOrder[boundary.itemID] else {
                return false
            }
            return order > boundary.order && order < llmCallOrder
        }
    }
}

struct SessionReplayTeleprompterProgressEvidence: Sendable {
    let maximumSameItemRevisionCount: Int
    let observedDisplayPrefixOffsetsUTF16: [Int]
    let observedSourcePrefixOffsetsUTF16: [Int]
    let observedSourceSampleWatermarks: [Int]
    let expectedDisplayScriptUTF16Length: Int
    let expectedSourceUTF16Length: Int
    let manualDisplayPrefixOffsetUTF16: Int?
    let manualSourcePrefixOffsetUTF16: Int?
    let manualSourceSampleWatermark: Int?
    let expectedPrefixRanges: [SessionReplayExpectedPrefixRange]?
    let revisionsMonotonic: Bool
    let noFinalAtManualTakeover: Bool
    let previewBeforeFinal: Bool
    let manualPositionStable: Bool
    var allObservedPrefixesWithinGold = true

    var firstObservedDisplayOffsetUTF16: Int? { observedDisplayPrefixOffsetsUTF16.first }
    var lastObservedDisplayOffsetUTF16: Int? { observedDisplayPrefixOffsetsUTF16.last }
    var firstObservedSourceOffsetUTF16: Int? { observedSourcePrefixOffsetsUTF16.first }
    var lastObservedSourceOffsetUTF16: Int? { observedSourcePrefixOffsetsUTF16.last }
}

struct SessionReplayScriptPosition: Equatable, Sendable {
    let segmentIndex: Int
    let segmentOffsetUTF16: Int
    let displayPrefixOffsetUTF16: Int
    let sourcePrefixOffsetUTF16: Int
    let expectedDisplayScriptUTF16Length: Int
}

enum SessionReplayScriptSourcePosition {
    static func prefixOffset(
        sourceRange: TeleprompterSourceRange,
        segmentUTF16Length: Int,
        segmentOffsetUTF16: Int,
        sourceUTF16Length: Int
    ) -> Int? {
        guard sourceRange.start >= 0,
              sourceRange.end > sourceRange.start,
              sourceRange.end <= sourceUTF16Length,
              sourceRange.end - sourceRange.start == segmentUTF16Length,
              (0...segmentUTF16Length).contains(segmentOffsetUTF16) else {
            return nil
        }
        return sourceRange.start + segmentOffsetUTF16
    }
}

struct SessionReplayTeleprompterFeedEvidence: Sendable {
    let sameItemRevisionCount: Int
    let observedDisplayPrefixOffsetsUTF16: [Int]
    let observedSourcePrefixOffsetsUTF16: [Int]
    let observedSourceSampleWatermarks: [Int]
    let itemID: String?
    let allObservedPrefixesWithinGold: Bool

    init(
        sameItemRevisionCount: Int,
        observedDisplayPrefixOffsetsUTF16: [Int],
        observedSourcePrefixOffsetsUTF16: [Int],
        observedSourceSampleWatermarks: [Int],
        itemID: String? = nil,
        allObservedPrefixesWithinGold: Bool = true
    ) {
        self.sameItemRevisionCount = sameItemRevisionCount
        self.observedDisplayPrefixOffsetsUTF16 = observedDisplayPrefixOffsetsUTF16
        self.observedSourcePrefixOffsetsUTF16 = observedSourcePrefixOffsetsUTF16
        self.observedSourceSampleWatermarks = observedSourceSampleWatermarks
        self.itemID = itemID
        self.allObservedPrefixesWithinGold = allObservedPrefixesWithinGold
    }
}

struct SessionReplayTeleprompterProcessingDiagnostics: Encodable, Sendable {
    let receivedAlignmentEvents: Int
    let processedAlignmentSamples: Int
    let partialTextCodepoints: Int
    let uncertainty: Double?
    let earlierTerminalCount: Int
    let allObservedPrefixesWithinGold: Bool
    let observedAlignmentEvents: Int

    enum CodingKeys: String, CodingKey {
        case receivedAlignmentEvents = "received_alignment_events"
        case processedAlignmentSamples = "processed_alignment_samples"
        case partialTextCodepoints = "partial_text_codepoints"
        case uncertainty
        case earlierTerminalCount = "earlier_terminal_count"
        case allObservedPrefixesWithinGold = "all_observed_prefixes_within_gold"
        case observedAlignmentEvents = "observed_alignment_events"
    }
}

/// Records every processed event, including finalized items, before a subsequent
/// event can revise the global position. The observer's bound matches the
/// production diagnostics window; incomplete observations fail closed.
struct SessionReplayTeleprompterObservationLedger {
    private(set) var observedAlignmentEvents = 0
    private(set) var allObservedPrefixesWithinGold = true
    private(set) var latestPreviewItemID: String?
    private var displayOffsetsByItem: [String: [Int]] = [:]
    private var sourceOffsetsByItem: [String: [Int]] = [:]
    private var watermarksByItem: [String: [Int]] = [:]

    mutating func record(
        expectedAlignmentEvents: Int,
        itemID: String,
        isPreview: Bool,
        position: SessionReplayScriptPosition?,
        sourceSampleWatermark: Int,
        expectedPrefixRanges: [SessionReplayExpectedPrefixRange]?
    ) {
        guard expectedAlignmentEvents == observedAlignmentEvents + 1,
              expectedAlignmentEvents < 128,
              let position,
              let expectedPrefixRanges else {
            allObservedPrefixesWithinGold = false
            return
        }
        observedAlignmentEvents += 1
        allObservedPrefixesWithinGold = allObservedPrefixesWithinGold
            && SessionReplayExpectedPrefixRangeIntegrity.allows(
                offsetUTF16: position.sourcePrefixOffsetUTF16,
                atSourceSampleWatermark: sourceSampleWatermark,
                in: expectedPrefixRanges
            )
        if isPreview {
            latestPreviewItemID = itemID
            displayOffsetsByItem[itemID, default: []].append(position.displayPrefixOffsetUTF16)
            sourceOffsetsByItem[itemID, default: []].append(position.sourcePrefixOffsetUTF16)
            watermarksByItem[itemID, default: []].append(sourceSampleWatermark)
        }
    }

    mutating func recordMissingObservation() {
        allObservedPrefixesWithinGold = false
    }

    func feedEvidence(itemID: String?) -> SessionReplayTeleprompterFeedEvidence {
        SessionReplayTeleprompterFeedEvidence(
            sameItemRevisionCount: itemID.flatMap { sourceOffsetsByItem[$0]?.count } ?? 0,
            observedDisplayPrefixOffsetsUTF16: itemID.flatMap { displayOffsetsByItem[$0] } ?? [],
            observedSourcePrefixOffsetsUTF16: itemID.flatMap { sourceOffsetsByItem[$0] } ?? [],
            observedSourceSampleWatermarks: itemID.flatMap { watermarksByItem[$0] } ?? [],
            itemID: itemID,
            allObservedPrefixesWithinGold: allObservedPrefixesWithinGold
        )
    }
}

@MainActor
final class SessionReplayTeleprompterObservationState {
    var ledger = SessionReplayTeleprompterObservationLedger()
    var isEnabled = true
}

enum SessionReplayTeleprompterProcessingIntegrity {
    // The production diagnostics use a bounded 128-sample window. Once it
    // saturates, it cannot prove which subsequent event has been consumed.
    static func caughtUp(receivedAlignmentEvents: Int, processedAlignmentSamples: Int) -> Bool {
        (0..<128).contains(receivedAlignmentEvents)
            && processedAlignmentSamples == receivedAlignmentEvents
    }

    static func hasUnfinalizedPreview(
        itemID: String?,
        firstPreviewOrders: [String: Int],
        terminalCounts: [String: Int]
    ) -> Bool {
        guard let itemID, let order = firstPreviewOrders[itemID], order > 0 else { return false }
        return terminalCounts[itemID, default: 0] == 0
    }
}

enum SessionReplayTeleprompterFeedIntegrity {
    static func validate(
        _ evidence: SessionReplayTeleprompterFeedEvidence,
        expectedDisplayScriptUTF16Length: Int,
        expectedSourceUTF16Length: Int,
        expectedPrefixRanges: [SessionReplayExpectedPrefixRange]?
    ) -> Bool {
        let displayOffsets = evidence.observedDisplayPrefixOffsetsUTF16
        let sourceOffsets = evidence.observedSourcePrefixOffsetsUTF16
        guard evidence.allObservedPrefixesWithinGold,
              evidence.sameItemRevisionCount >= 2,
              displayOffsets.count >= 2,
              displayOffsets.count == sourceOffsets.count,
              expectedDisplayScriptUTF16Length > 0,
              expectedSourceUTF16Length > 0,
              let firstDisplayOffset = displayOffsets.first,
              let lastDisplayOffset = displayOffsets.last,
              let firstSourceOffset = sourceOffsets.first,
              let lastSourceOffset = sourceOffsets.last,
              lastDisplayOffset > firstDisplayOffset,
              lastSourceOffset > firstSourceOffset,
              displayOffsets.allSatisfy({
                  (0...expectedDisplayScriptUTF16Length).contains($0)
              }),
              sourceOffsets.allSatisfy({
                  (0...expectedSourceUTF16Length).contains($0)
              }),
              zip(displayOffsets, displayOffsets.dropFirst()).allSatisfy({ $0.0 <= $0.1 }),
              zip(sourceOffsets, sourceOffsets.dropFirst()).allSatisfy({ $0.0 <= $0.1 }),
              let expectedPrefixRanges,
              SessionReplayExpectedPrefixRangeIntegrity.validateManifest(
                  expectedPrefixRanges,
                  sourceUTF16Length: expectedSourceUTF16Length
              ),
              SessionReplayExpectedPrefixRangeIntegrity.validateObservations(
                  sourceOffsetsUTF16: sourceOffsets,
                  sourceSampleWatermarks: evidence.observedSourceSampleWatermarks,
                  ranges: expectedPrefixRanges
              ) else {
            return false
        }
        return true
    }
}

enum SessionReplayTeleprompterProgressIntegrity {
    static func validate(_ evidence: SessionReplayTeleprompterProgressEvidence) -> Bool {
        guard SessionReplayTeleprompterFeedIntegrity.validate(
                  SessionReplayTeleprompterFeedEvidence(
                      sameItemRevisionCount: evidence.maximumSameItemRevisionCount,
                      observedDisplayPrefixOffsetsUTF16: evidence.observedDisplayPrefixOffsetsUTF16,
                      observedSourcePrefixOffsetsUTF16: evidence.observedSourcePrefixOffsetsUTF16,
                      observedSourceSampleWatermarks: evidence.observedSourceSampleWatermarks,
                      allObservedPrefixesWithinGold: evidence.allObservedPrefixesWithinGold
                  ),
                  expectedDisplayScriptUTF16Length: evidence.expectedDisplayScriptUTF16Length,
                  expectedSourceUTF16Length: evidence.expectedSourceUTF16Length,
                  expectedPrefixRanges: evidence.expectedPrefixRanges
              ),
              evidence.revisionsMonotonic,
              evidence.noFinalAtManualTakeover,
              evidence.previewBeforeFinal,
              evidence.manualPositionStable,
              let manualDisplayOffset = evidence.manualDisplayPrefixOffsetUTF16,
              let manualSourceOffset = evidence.manualSourcePrefixOffsetUTF16,
              let manualSourceSampleWatermark = evidence.manualSourceSampleWatermark,
              (0...evidence.expectedDisplayScriptUTF16Length).contains(manualDisplayOffset),
              (0...evidence.expectedSourceUTF16Length).contains(manualSourceOffset),
              let expectedPrefixRanges = evidence.expectedPrefixRanges,
              SessionReplayExpectedPrefixRangeIntegrity.allows(
                  offsetUTF16: manualSourceOffset,
                  atSourceSampleWatermark: manualSourceSampleWatermark,
                  in: expectedPrefixRanges
              ) else {
            return false
        }
        return true
    }
}

struct SessionReplayCaptureReleaseEvidence: Sendable {
    let coordinatorCaptureReleased: Bool
    let captureSourceStopped: Bool
    let realtimeClientClosed: Bool
    let eventMirrorDrained: Bool
}

enum SessionReplayCaptureReleaseIntegrity {
    static func coordinatorCaptureReleased(
        scene: SessionReplayScene,
        occupancy: SessionCoordinator.Occupancy?
    ) -> Bool {
        guard let occupancy else { return true }
        return scene == .meeting
            && occupancy.kind == .meeting
            && occupancy.isProcessing
    }

    static func validate(_ evidence: SessionReplayCaptureReleaseEvidence) -> Bool {
        evidence.coordinatorCaptureReleased
            && evidence.captureSourceStopped
            && evidence.realtimeClientClosed
            && evidence.eventMirrorDrained
    }
}

struct SessionReplaySummary: Encodable {
    let schemaVersion = 5
    let fixtureID: String
    let scene: String
    let preset: String
    let fixtureSamples: Int
    let inputSamples: Int
    let sourceSamplesYielded: Int
    let syntheticTrailingSilenceSamples: Int
    let uploadedSampleWatermark: Int
    let requestedMaxSegmentSamples: Int
    let effectiveBudgetObservation: String
    let segmentCount: Int
    let terminalCount: Int
    let failedTerminalCount: Int
    let serverErrorCount: Int
    let emptySuccessCount: Int
    let nonEmptySuccessCount: Int
    let previewEventCount: Int
    let previewRevisionCount: Int
    let previewRevisionRegressionCount: Int
    let firstPreviewMilliseconds: Double?
    let finalAfterLastAudioMilliseconds: Double?
    let uploadGate: String
    let pcmIntegrityGate: String
    let receiptBarrierGate: String
    let configuredEchoGate: String
    let spanIntegrityGate: String
    let terminalGate: String
    let recognitionGate: String
    let businessGate: String
    let assistantTurnGate: String
    let assistantLLMStreamCallCount: Int
    let assistantLLMStreamCallOrder: Int?
    let assistantVADTerminalOrder: Int?
    let teleprompterProgressGate: String
    let teleprompterSameItemRevisionCount: Int
    let teleprompterPositionObservationCount: Int
    let teleprompterObservedDisplayPrefixOffsetsUTF16: [Int]
    let teleprompterObservedSourcePrefixOffsetsUTF16: [Int]
    let teleprompterObservedSourceSampleWatermarks: [Int]
    let teleprompterStartDisplayPrefixUTF16: Int?
    let teleprompterEndDisplayPrefixUTF16: Int?
    let teleprompterStartSourcePrefixUTF16: Int?
    let teleprompterEndSourcePrefixUTF16: Int?
    let teleprompterManualDisplayPrefixUTF16: Int?
    let teleprompterManualSourcePrefixUTF16: Int?
    let teleprompterManualSourceSampleWatermark: Int?
    let teleprompterExpectedDisplayScriptUTF16Length: Int?
    let teleprompterExpectedSourceUTF16Length: Int?
    let teleprompterProcessingDiagnostics: SessionReplayTeleprompterProcessingDiagnostics?
    let captureReleaseGate: String
    let coordinatorCaptureReleased: Bool
    let captureSourceStopped: Bool
    let realtimeClientClosed: Bool
    let eventMirrorDrained: Bool
    let executionGate: String
    let captureStopReason: String
    let spans: [Span]

    struct Span: Encodable {
        let ordinal: Int
        let startSample: Int
        let endSample: Int
        let reason: String
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fixtureID = "fixture_id"
        case scene
        case preset
        case fixtureSamples = "fixture_samples"
        case inputSamples = "input_samples"
        case sourceSamplesYielded = "source_samples_yielded"
        case syntheticTrailingSilenceSamples = "synthetic_trailing_silence_samples"
        case uploadedSampleWatermark = "uploaded_sample_watermark"
        case requestedMaxSegmentSamples = "requested_max_segment_samples"
        case effectiveBudgetObservation = "effective_budget_observation"
        case segmentCount = "segment_count"
        case terminalCount = "terminal_count"
        case failedTerminalCount = "failed_terminal_count"
        case serverErrorCount = "server_error_count"
        case emptySuccessCount = "empty_success_count"
        case nonEmptySuccessCount = "non_empty_success_count"
        case previewEventCount = "preview_event_count"
        case previewRevisionCount = "preview_revision_count"
        case previewRevisionRegressionCount = "preview_revision_regression_count"
        case firstPreviewMilliseconds = "first_preview_ms"
        case finalAfterLastAudioMilliseconds = "final_after_last_audio_ms"
        case uploadGate = "upload_gate"
        case pcmIntegrityGate = "pcm_integrity_gate"
        case receiptBarrierGate = "receipt_barrier_gate"
        case configuredEchoGate = "configured_echo_gate"
        case spanIntegrityGate = "span_integrity_gate"
        case terminalGate = "terminal_gate"
        case recognitionGate = "recognition_gate"
        case businessGate = "business_gate"
        case assistantTurnGate = "assistant_turn_gate"
        case assistantLLMStreamCallCount = "assistant_llm_stream_call_count"
        case assistantLLMStreamCallOrder = "assistant_llm_stream_call_order"
        case assistantVADTerminalOrder = "assistant_vad_terminal_order"
        case teleprompterProgressGate = "teleprompter_progress_gate"
        case teleprompterSameItemRevisionCount = "teleprompter_same_item_revision_count"
        case teleprompterPositionObservationCount = "teleprompter_position_observation_count"
        case teleprompterObservedDisplayPrefixOffsetsUTF16 = "teleprompter_observed_display_prefix_offsets_utf16"
        case teleprompterObservedSourcePrefixOffsetsUTF16 = "teleprompter_observed_source_prefix_offsets_utf16"
        case teleprompterObservedSourceSampleWatermarks = "teleprompter_observed_source_sample_watermarks"
        case teleprompterStartDisplayPrefixUTF16 = "teleprompter_start_display_prefix_utf16"
        case teleprompterEndDisplayPrefixUTF16 = "teleprompter_end_display_prefix_utf16"
        case teleprompterStartSourcePrefixUTF16 = "teleprompter_start_source_prefix_utf16"
        case teleprompterEndSourcePrefixUTF16 = "teleprompter_end_source_prefix_utf16"
        case teleprompterManualDisplayPrefixUTF16 = "teleprompter_manual_display_prefix_utf16"
        case teleprompterManualSourcePrefixUTF16 = "teleprompter_manual_source_prefix_utf16"
        case teleprompterManualSourceSampleWatermark = "teleprompter_manual_source_sample_watermark"
        case teleprompterExpectedDisplayScriptUTF16Length = "teleprompter_expected_display_script_utf16_length"
        case teleprompterExpectedSourceUTF16Length = "teleprompter_expected_source_utf16_length"
        case teleprompterProcessingDiagnostics = "teleprompter_processing_diagnostics"
        case captureReleaseGate = "capture_release_gate"
        case coordinatorCaptureReleased = "coordinator_capture_released"
        case captureSourceStopped = "capture_source_stopped"
        case realtimeClientClosed = "realtime_client_closed"
        case eventMirrorDrained = "event_mirror_drained"
        case executionGate = "execution_gate"
        case captureStopReason = "capture_stop_reason"
        case spans
    }
}

struct SessionReplayRun {
    let summary: SessionReplaySummary
}

enum SessionReplayClock {
    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end).components
        return max(
            0,
            (Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000) * 1_000
        )
    }
}

enum SessionReplayFailure: Error {
    case missingConfiguration
    case invalidConfiguration
    case fixtureNotFound
    case missingTeleprompterReference
    case outputAlreadyExists
    case storageUnavailable
    case sessionRunFailed
    case sessionDidNotStart
    case businessTurnDidNotArrive
    case captureBufferOverflow
    case syntheticTTSUnavailable
}

@MainActor
func requireClient(_ handle: SessionReplayClientHandle) throws -> SessionReplayClient {
    guard let client = handle.client else { throw SessionReplayFailure.sessionRunFailed }
    return client
}

@MainActor
func requireSessionID(_ value: String?) throws -> String {
    guard let value else { throw SessionReplayFailure.sessionRunFailed }
    return value
}

enum SessionReplaySamplerHandshakeFailure: Error, Equatable {
    case invalidConfiguration
    case markerAlreadyExists
    case invalidReleaseMarker
    case samplerReleaseTimedOut
}

struct SessionReplaySamplerHandshake: Sendable {
    let runID: String
    let readyURL: URL
    let releaseURL: URL

    private init(runID: String, readyURL: URL, releaseURL: URL) {
        self.runID = runID
        self.readyURL = readyURL
        self.releaseURL = releaseURL
    }

    static func load(
        outputURL: URL,
        environment: [String: String],
        repositoryRootURL: URL = inferredRepositoryRoot
    ) throws -> Self? {
        let runID = environment["SPEECHRAIL_ASR_SESSION_SAMPLER_RUN_ID"] ?? ""
        let readyPath = environment["SPEECHRAIL_ASR_SESSION_SAMPLER_READY"] ?? ""
        let releasePath = environment["SPEECHRAIL_ASR_SESSION_SAMPLER_RELEASE"] ?? ""
        if runID.isEmpty && readyPath.isEmpty && releasePath.isEmpty { return nil }
        guard environment["SPEECHRAIL_ASR_SESSION_E2E"] == "1",
              let uuid = UUID(uuidString: runID),
              uuid.uuidString.lowercased() == runID,
              readyPath.hasPrefix("/"), releasePath.hasPrefix("/"),
              outputURL.isFileURL, outputURL.path.hasPrefix("/") else {
            throw SessionReplaySamplerHandshakeFailure.invalidConfiguration
        }

        let rawReadyURL = URL(fileURLWithPath: readyPath)
        let rawReleaseURL = URL(fileURLWithPath: releasePath)
        guard !markerExists(rawReadyURL), !markerExists(rawReleaseURL) else {
            throw SessionReplaySamplerHandshakeFailure.markerAlreadyExists
        }
        let readyURL = canonical(rawReadyURL)
        let releaseURL = canonical(rawReleaseURL)
        let outputURL = canonical(outputURL)
        let root = canonical(repositoryRootURL)
        let directory = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard readyURL != releaseURL, readyURL != outputURL, releaseURL != outputURL,
              readyURL.deletingLastPathComponent() == directory,
              releaseURL.deletingLastPathComponent() == directory,
              isExternal(directory, from: root),
              FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SessionReplaySamplerHandshakeFailure.invalidConfiguration
        }
        return Self(runID: runID, readyURL: readyURL, releaseURL: releaseURL)
    }

    func waitForSamplerStop(timeout: Duration) async throws {
        guard timeout > .zero && timeout <= .seconds(30) else {
            throw SessionReplaySamplerHandshakeFailure.invalidConfiguration
        }
        try Task.checkCancellation()
        let ready = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "run_id": runID,
            "consumer_finished": true,
        ], options: [.sortedKeys])
        try publishReady(ready)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw SessionReplaySamplerHandshakeFailure.samplerReleaseTimedOut
            }
            if Self.markerExists(releaseURL) {
                try validateRelease()
                try Task.checkCancellation()
                return
            }
            try await Task.sleep(for: min(.milliseconds(10), remaining))
        }
    }

    private func publishReady(_ data: Data) throws {
        let temporary = readyURL.deletingLastPathComponent().appendingPathComponent(
            ".sampler-ready-\(UUID().uuidString.lowercased()).tmp"
        )
        // Both files live on one filesystem. Hard-link publication is atomic
        // and refuses an existing destination, including a dangling symlink.
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SessionReplaySamplerHandshakeFailure.invalidConfiguration
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.linkItem(at: temporary, to: readyURL)
        } catch {
            if Self.markerExists(readyURL) {
                throw SessionReplaySamplerHandshakeFailure.markerAlreadyExists
            }
            throw error
        }
    }

    private func validateRelease() throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: releaseURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.intValue > 0, size.intValue <= 1_024 else {
                throw SessionReplaySamplerHandshakeFailure.invalidReleaseMarker
            }
            let data = try Data(contentsOf: releaseURL)
            guard data.count <= 1_024,
                  let marker = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(marker.keys) == Set(["schema_version", "run_id", "sampler_stopped"]),
                  let schema = marker["schema_version"] as? NSNumber,
                  CFGetTypeID(schema) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: schema.objCType)),
                  schema.intValue == 1,
                  marker["run_id"] as? String == runID,
                  let stopped = marker["sampler_stopped"] as? NSNumber,
                  CFGetTypeID(stopped) == CFBooleanGetTypeID(),
                  stopped.boolValue else {
                throw SessionReplaySamplerHandshakeFailure.invalidReleaseMarker
            }
        } catch {
            throw SessionReplaySamplerHandshakeFailure.invalidReleaseMarker
        }
    }

    private static func markerExists(_ url: URL) -> Bool {
        // attributesOfItem observes the directory entry, including a broken
        // symlink, rather than accepting only an existing symlink destination.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isExternal(_ url: URL, from root: URL) -> Bool {
        url.path != root.path && !url.path.hasPrefix(root.path + "/")
    }

    static var inferredRepositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return canonical(url)
    }
}
