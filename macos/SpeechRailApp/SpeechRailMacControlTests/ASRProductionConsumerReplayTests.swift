import AVFoundation
import CryptoKit
import Foundation
import SpeechRailControlKit
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

// Opt-in live wire contract:
// - enable with SPEECHRAIL_ASR_CONSUMER_E2E=1;
// - pass an external manifest, opaque fixture ID, scene (assistant/meeting/caption/teleprompter),
//   and a new external output path through SPEECHRAIL_ASR_CONSUMER_* variables below;
// - the selected WAV must be 16 kHz mono PCM16; SpeechRailAPICredentialProvider resolves auth.
// The report contains only aggregate gates, counts, admitted spans, and latency.
private enum ASRProductionConsumerReplayConfiguration {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["SPEECHRAIL_ASR_CONSUMER_E2E"] == "1"
    }
}

@Suite(.serialized)
struct ASRProductionConsumerReplayTests {
    @Test(
        .enabled(
            if: ASRProductionConsumerReplayConfiguration.enabled,
            "Set SPEECHRAIL_ASR_CONSUMER_E2E=1 and provide the external replay inputs to run this live-service test."
        )
    )
    func productionRealtimeClientPreservesBoundariesAndTerminals() async throws {
        let configuration = try ReplayConfiguration.load()
        let pcm = try ReplayPCM24K.load(from: configuration.audioURL)
        let client = RealtimeASRClient(
            port: configuration.port,
            language: configuration.language,
            scenePreset: configuration.preset,
            expectedASRRevision: configuration.expectedASRRevision
        )
        let recorder = ReplayEventRecorder()
        let eventStream = await client.events()
        let collector = Task {
            for await envelope in eventStream {
                await recorder.consume(envelope)
            }
            return await recorder.snapshot()
        }

        var runSucceeded = false
        let clock = ContinuousClock()
        do {
            try await client.connect()
            await recorder.markAudioStarted(at: clock.now)
            try await replay(pcm.bytes, into: client, recorder: recorder, clock: clock)
            try await client.drainAndClear(timeout: .seconds(120))
            runSucceeded = true
        } catch {
            // XCTest output can include an error's localized description. Keep the
            // failure useful without leaking remote text, headers, keys, or paths.
            await client.close()
            collector.cancel()
        }

        await client.close()
        let snapshot = await collector.value
        #expect(runSucceeded, "The production Realtime client must complete a live replay.")

        let inputSamples = pcm.bytes.count / MemoryLayout<Int16>.size
        let exactTerminalCoverage = ReplayTerminalIntegrity.validate(snapshot)
        let sortedBoundaries = ReplaySpanIntegrity.sorted(snapshot.boundaries)
        let maximumSegmentSamples = Int(
            Double(RealtimeASRClient.sampleRate)
                * Double(configuration.preset.policy.maxSegmentMilliseconds)
                / 1_000
        )
        let spanIntegrityPassed = ReplaySpanIntegrity.validate(
            sortedBoundaries,
            uploadedSampleWatermark: snapshot.uploadedSampleWatermark,
            maximumSegmentSamples: maximumSegmentSamples
        )
        let uploadPassed = snapshot.uploadedSampleWatermark == inputSamples
        let pcmIntegrityPassed = await recorder.uploadedPCMMatches(pcm.bytes)
        // A successful drainAndClear internally validates accepted_samples against
        // the client's uploaded sample watermark. Its public API does not expose the
        // raw receipt, so report only the barrier result and this local watermark.
        let receiptBarrierPassed = runSucceeded
        let recognitionPassed = ReplayRecognitionIntegrity.validate(
            boundaries: snapshot.boundaries,
            nonEmptyTerminalItemIDs: snapshot.nonEmptyTerminalItemIDs,
            failedTerminalCount: snapshot.failedTerminalCount,
            protocolErrorCount: snapshot.protocolErrorCount,
            runSucceeded: runSucceeded
        )

        #expect(!sortedBoundaries.isEmpty, "The live replay must produce at least one frozen segment.")
        #expect(exactTerminalCoverage, "Each frozen segment must have exactly one later text terminal.")
        #expect(spanIntegrityPassed, "Admitted spans must be valid, non-overlapping, within the upload watermark, and within the scene budget.")
        #expect(uploadPassed, "The production client must accept every uploaded replay chunk.")
        #expect(pcmIntegrityPassed, "The PCM bytes accepted by append must match the original fixture.")
        #expect(receiptBarrierPassed, "The final drain receipt barrier must complete successfully.")
        #expect(recognitionPassed, "The valid speech fixture must not fail at the protocol or recognition layer.")

        let summary = ReplaySummary(
            fixtureID: configuration.fixtureID,
            preset: configuration.preset.rawValue,
            inputSamples: inputSamples,
            uploadedSampleWatermark: snapshot.uploadedSampleWatermark,
            maximumSegmentSamples: maximumSegmentSamples,
            segmentCount: snapshot.boundaries.count,
            terminalCount: snapshot.terminalCounts.values.reduce(0, +),
            failedTerminalCount: snapshot.failedTerminalCount,
            protocolErrorCount: snapshot.protocolErrorCount,
            emptySuccessCount: snapshot.emptySuccessCount,
            nonEmptySuccessCount: snapshot.nonEmptySuccessCount,
            previewEventCount: snapshot.previewEventCount,
            firstPreviewMilliseconds: snapshot.firstPreviewAt.map {
                milliseconds(from: snapshot.audioStartedAt, to: $0)
            },
            finalAfterLastAudioMilliseconds: snapshot.lastTerminalAt.map {
                milliseconds(from: snapshot.lastAudioSentAt, to: $0)
            },
            spanIntegrityGate: spanIntegrityPassed ? "pass" : "fail",
            uploadGate: uploadPassed ? "pass" : "fail",
            pcmIntegrityGate: pcmIntegrityPassed ? "pass" : "fail",
            receiptBarrierGate: receiptBarrierPassed ? "pass" : "fail",
            terminalGate: exactTerminalCoverage ? "pass" : "fail",
            recognitionGate: recognitionPassed ? "pass" : "fail",
            executionGate: runSucceeded ? "pass" : "fail",
            spans: sortedBoundaries.map {
                ReplaySummary.Span(
                    startSample: $0.span.startSample,
                    endSample: $0.span.endSample,
                    reason: $0.reason.rawValue
                )
            }
        )
        do {
            try configuration.write(summary)
        } catch {
            Issue.record("The aggregate replay report could not be written to the requested external path.")
        }
    }
}

private struct ReplayConfiguration {
    let fixtureID: String
    let audioURL: URL
    let language: String?
    let preset: ASRScenePreset
    let port: Int
    let expectedASRRevision: String?
    let outputURL: URL

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        guard let manifestPath = environment["SPEECHRAIL_ASR_CONSUMER_MANIFEST"],
              let fixtureID = environment["SPEECHRAIL_ASR_CONSUMER_FIXTURE_ID"],
              let scene = environment["SPEECHRAIL_ASR_CONSUMER_SCENE"],
              let outputPath = environment["SPEECHRAIL_ASR_CONSUMER_OUTPUT"] else {
            throw ReplayInputError.missingConfiguration
        }
        guard isSafeFixtureID(fixtureID) else {
            throw ReplayInputError.invalidFixtureID
        }
        guard let preset = preset(for: scene) else {
            throw ReplayInputError.invalidScene
        }
        let port = Int(environment["SPEECHRAIL_ASR_CONSUMER_PORT"] ?? "8201")
        guard let port, (1_024...65_535).contains(port) else {
            throw ReplayInputError.invalidPort
        }

        let repositoryRoot = repositoryRootURL
        let expandedManifestPath = (manifestPath as NSString).expandingTildeInPath
        guard expandedManifestPath.hasPrefix("/") else {
            throw ReplayInputError.invalidManifestLocation
        }
        let manifestURL = URL(fileURLWithPath: expandedManifestPath).standardizedFileURL
            .resolvingSymlinksInPath()
        guard isExternal(manifestURL, from: repositoryRoot),
              FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ReplayInputError.invalidManifestLocation
        }
        let manifest: ReplayManifest
        do {
            manifest = try JSONDecoder().decode(ReplayManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw ReplayInputError.invalidManifest
        }
        guard let fixture = manifest.fixtures.first(where: { $0.id == fixtureID }) else {
            throw ReplayInputError.fixtureNotFound
        }
        let rawAudioURL = URL(fileURLWithPath: (fixture.path as NSString).expandingTildeInPath)
        let audioURL = rawAudioURL.standardizedFileURL.resolvingSymlinksInPath()
        guard rawAudioURL.path.hasPrefix("/"),
              isExternal(audioURL, from: repositoryRoot),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ReplayInputError.invalidAudioLocation
        }

        let expandedOutputPath = (outputPath as NSString).expandingTildeInPath
        guard expandedOutputPath.hasPrefix("/") else {
            throw ReplayInputError.invalidOutputLocation
        }
        let outputURL = URL(fileURLWithPath: expandedOutputPath).standardizedFileURL
            .resolvingSymlinksInPath()
        guard outputURL.path.hasPrefix("/"),
              isExternal(outputURL, from: repositoryRoot),
              !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ReplayInputError.invalidOutputLocation
        }

        let language = fixture.language.flatMap { $0 == "auto" ? nil : $0 }
        return Self(
            fixtureID: fixtureID,
            audioURL: audioURL,
            language: language,
            preset: preset,
            port: port,
            expectedASRRevision: environment["SPEECHRAIL_ASR_CONSUMER_EXPECTED_REVISION"],
            outputURL: outputURL
        )
    }

    func write(_ summary: ReplaySummary) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(summary)
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ReplayInputError.outputAlreadyExists
        }
    }

    private static var repositoryRootURL: URL {
        var url = URL(fileURLWithPath: #filePath).standardizedFileURL
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url.resolvingSymlinksInPath()
    }

    private static func isExternal(_ url: URL, from repositoryRoot: URL) -> Bool {
        let rootPath = repositoryRoot.path.hasSuffix("/")
            ? repositoryRoot.path
            : repositoryRoot.path + "/"
        return url.path != repositoryRoot.path && !url.path.hasPrefix(rootPath)
    }

    private static func isSafeFixtureID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
                    .contains($0)
            }
    }

    private static func preset(for scene: String) -> ASRScenePreset? {
        switch scene {
        case "assistant": .assistantTurnTaking
        case "meeting": .meeting
        case "caption": .caption
        case "teleprompter": .teleprompter
        default: nil
        }
    }
}

private struct ReplayManifest: Decodable {
    let fixtures: [ReplayFixture]

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let fixtures = try? singleValue.decode([ReplayFixture].self) {
            self.fixtures = fixtures
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fixtures = try container.decode([ReplayFixture].self, forKey: .fixtures)
    }

    private enum CodingKeys: String, CodingKey {
        case fixtures
    }
}

private struct ReplayFixture: Decodable {
    let id: String
    let path: String
    let language: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case audioPath = "audio_path"
        case audio
        case language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let value = try container.decodeIfPresent(String.self, forKey: .path) {
            path = value
        } else if let value = try container.decodeIfPresent(String.self, forKey: .audioPath) {
            path = value
        } else {
            path = try container.decode(String.self, forKey: .audio)
        }
        language = try container.decodeIfPresent(String.self, forKey: .language)
    }
}

private enum ReplayInputError: Error {
    case missingConfiguration
    case invalidFixtureID
    case invalidScene
    case invalidPort
    case invalidManifestLocation
    case invalidManifest
    case fixtureNotFound
    case invalidAudioLocation
    case invalidOutputLocation
    case outputAlreadyExists
    case unsupportedAudio
    case conversionFailed
}

struct ReplayPCM24K {
    let bytes: Data

    static func load(from url: URL) throws -> Self {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ReplayInputError.unsupportedAudio
        }
        let sourceFormat = file.processingFormat
        let sourceFrames = file.length
        guard sourceFormat.sampleRate == 16_000,
              sourceFormat.channelCount == 1,
              sourceFrames > 0,
              sourceFrames <= 480_000,
              file.fileFormat.streamDescription.pointee.mBitsPerChannel == 16 else {
            throw ReplayInputError.unsupportedAudio
        }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sourceFrames)
        ),
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: RealtimeASRClient.sampleRate,
            channels: 1,
            interleaved: true
        ),
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw ReplayInputError.conversionFailed
        }
        do {
            try file.read(into: sourceBuffer, frameCount: AVAudioFrameCount(sourceFrames))
        } catch {
            throw ReplayInputError.unsupportedAudio
        }

        let capacity = AVAudioFrameCount(ceil(Double(sourceFrames) * 1.5) + 128)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            throw ReplayInputError.conversionFailed
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error,
              conversionError == nil,
              outputBuffer.frameLength > 0,
              let samples = outputBuffer.int16ChannelData?[0] else {
            throw ReplayInputError.conversionFailed
        }
        let outputSamples = Int(outputBuffer.frameLength)
        guard abs(outputSamples - Int(sourceFrames) * 3 / 2) <= 2 else {
            throw ReplayInputError.conversionFailed
        }
        return Self(bytes: Data(
            bytes: samples,
            count: outputSamples * MemoryLayout<Int16>.size
        ))
    }
}

private struct ReplayBoundary: Sendable {
    let itemID: String
    let span: RealtimeASRClient.RealtimeSampleSpan
    let reason: ASRSegmentCloseReason
    let order: Int
}

private enum ReplaySpanIntegrity {
    static func sorted(_ boundaries: [ReplayBoundary]) -> [ReplayBoundary] {
        boundaries.sorted {
            if $0.span.startSample == $1.span.startSample {
                return $0.span.endSample < $1.span.endSample
            }
            return $0.span.startSample < $1.span.startSample
        }
    }

    static func validate(
        _ sortedBoundaries: [ReplayBoundary],
        uploadedSampleWatermark: Int,
        maximumSegmentSamples: Int
    ) -> Bool {
        guard !sortedBoundaries.isEmpty, uploadedSampleWatermark >= 0, maximumSegmentSamples > 0,
              sortedBoundaries.allSatisfy({
                  $0.span.startSample >= 0
                      && $0.span.endSample > $0.span.startSample
                      && $0.span.endSample <= uploadedSampleWatermark
                      && $0.span.endSample - $0.span.startSample <= maximumSegmentSamples
              }) else {
            return false
        }
        return zip(sortedBoundaries, sortedBoundaries.dropFirst())
            .allSatisfy { pair in pair.0.span.endSample <= pair.1.span.startSample }
    }
}

private struct ReplaySnapshot: Sendable {
    let uploadedSampleWatermark: Int
    let boundaryCounts: [String: Int]
    let boundaries: [ReplayBoundary]
    let terminalCounts: [String: Int]
    let terminalOrder: [String: Int]
    let emptyTerminalItemIDs: Set<String>
    let nonEmptyTerminalItemIDs: Set<String>
    let failedTerminalCount: Int
    let protocolErrorCount: Int
    let emptySuccessCount: Int
    let nonEmptySuccessCount: Int
    let previewEventCount: Int
    let audioStartedAt: ContinuousClock.Instant
    let lastAudioSentAt: ContinuousClock.Instant
    let firstPreviewAt: ContinuousClock.Instant?
    let lastTerminalAt: ContinuousClock.Instant?
}

private enum ReplayRecognitionIntegrity {
    static func validate(
        boundaries: [ReplayBoundary],
        nonEmptyTerminalItemIDs: Set<String>,
        failedTerminalCount: Int,
        protocolErrorCount: Int,
        runSucceeded: Bool
    ) -> Bool {
        runSucceeded
            && failedTerminalCount == 0
            && protocolErrorCount == 0
            && boundaries.contains { nonEmptyTerminalItemIDs.contains($0.itemID) }
    }
}

@Suite
struct ReplaySpanIntegrityTests {
    @Test
    func allowsServerVADSilenceGapsBetweenAdmittedSpans() {
        let boundaries = [
            ReplayBoundary(
                itemID: "first",
                span: .init(startSample: 1_200, endSample: 9_600),
                reason: .vad,
                order: 1
            ),
            ReplayBoundary(
                itemID: "second",
                span: .init(startSample: 15_000, endSample: 24_000),
                reason: .clientCommit,
                order: 2
            )
        ]

        #expect(
            ReplaySpanIntegrity.validate(
                ReplaySpanIntegrity.sorted(boundaries),
                uploadedSampleWatermark: 30_000,
                maximumSegmentSamples: 480_000
            )
        )
        #expect(
            !ReplaySpanIntegrity.validate(
                ReplaySpanIntegrity.sorted(boundaries),
                uploadedSampleWatermark: 23_999,
                maximumSegmentSamples: 480_000
            )
        )
        #expect(
            !ReplaySpanIntegrity.validate(
                ReplaySpanIntegrity.sorted([
                    boundaries[0],
                    ReplayBoundary(
                        itemID: "overlap",
                        span: .init(startSample: 9_500, endSample: 12_000),
                        reason: .vad,
                        order: 3
                    )
                ]),
                uploadedSampleWatermark: 30_000,
                maximumSegmentSamples: 480_000
            )
        )
    }
}

@Suite
struct ReplayRecognitionIntegrityTests {
    private let boundary = ReplayBoundary(
        itemID: "speech",
        span: .init(startSample: 1_200, endSample: 9_600),
        reason: .vad,
        order: 1
    )

    @Test
    func allowsUnboundEmptyCommitWhenBoundSpeechWasRecognized() {
        #expect(
            ReplayRecognitionIntegrity.validate(
                boundaries: [boundary],
                nonEmptyTerminalItemIDs: ["speech", "unbound-empty"],
                failedTerminalCount: 0,
                protocolErrorCount: 0,
                runSucceeded: true
            )
        )
    }

    @Test
    func rejectsAllEmptyCompletions() {
        #expect(
            !ReplayRecognitionIntegrity.validate(
                boundaries: [boundary],
                nonEmptyTerminalItemIDs: [],
                failedTerminalCount: 0,
                protocolErrorCount: 0,
                runSucceeded: true
            )
        )
    }

    @Test
    func rejectsFailedTerminalAndProtocolError() {
        #expect(
            !ReplayRecognitionIntegrity.validate(
                boundaries: [boundary],
                nonEmptyTerminalItemIDs: ["speech"],
                failedTerminalCount: 1,
                protocolErrorCount: 0,
                runSucceeded: true
            )
        )
        #expect(
            !ReplayRecognitionIntegrity.validate(
                boundaries: [boundary],
                nonEmptyTerminalItemIDs: ["speech"],
                failedTerminalCount: 0,
                protocolErrorCount: 1,
                runSucceeded: true
            )
        )
    }
}

@Suite
struct ReplayTerminalIntegrityTests {
    private let boundary = ReplayBoundary(
        itemID: "item",
        span: .init(startSample: 1_200, endSample: 9_600),
        reason: .vad,
        order: 2
    )

    @Test
    func rejectsBoundaryWithoutTerminal() {
        #expect(
            !ReplayTerminalIntegrity.validate(
                boundaries: [boundary],
                boundaryCounts: ["item": 1],
                terminalCounts: [:],
                terminalOrder: [:],
                emptyTerminalItemIDs: []
            )
        )
    }

    @Test
    func rejectsDuplicateTerminal() {
        #expect(
            !ReplayTerminalIntegrity.validate(
                boundaries: [boundary],
                boundaryCounts: ["item": 1],
                terminalCounts: ["item": 2],
                terminalOrder: ["item": 4],
                emptyTerminalItemIDs: []
            )
        )
    }

    @Test
    func rejectsTerminalBeforeBoundary() {
        #expect(
            !ReplayTerminalIntegrity.validate(
                boundaries: [boundary],
                boundaryCounts: ["item": 1],
                terminalCounts: ["item": 1],
                terminalOrder: ["item": 1],
                emptyTerminalItemIDs: []
            )
        )
    }

    @Test
    func allowsUnboundEmptyCommitAlongsideBoundTerminal() {
        #expect(
            ReplayTerminalIntegrity.validate(
                boundaries: [boundary],
                boundaryCounts: ["item": 1],
                terminalCounts: ["item": 1, "empty-commit": 1],
                terminalOrder: ["item": 3, "empty-commit": 4],
                emptyTerminalItemIDs: ["empty-commit"]
            )
        )
    }
}

private enum ReplayTerminalIntegrity {
    static func validate(_ snapshot: ReplaySnapshot) -> Bool {
        validate(
            boundaries: snapshot.boundaries,
            boundaryCounts: snapshot.boundaryCounts,
            terminalCounts: snapshot.terminalCounts,
            terminalOrder: snapshot.terminalOrder,
            emptyTerminalItemIDs: snapshot.emptyTerminalItemIDs
        )
    }

    static func validate(
        boundaries: [ReplayBoundary],
        boundaryCounts: [String: Int],
        terminalCounts: [String: Int],
        terminalOrder: [String: Int],
        emptyTerminalItemIDs: Set<String>
    ) -> Bool {
        guard !boundaries.isEmpty,
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

private actor ReplayEventRecorder {
    private var order = 0
    private var uploadedSampleWatermark = 0
    private var uploadedPCMHasher = SHA256()
    private var boundaryCounts: [String: Int] = [:]
    private var boundaries: [ReplayBoundary] = []
    private var terminalCounts: [String: Int] = [:]
    private var terminalOrder: [String: Int] = [:]
    private var emptyTerminalItemIDs: Set<String> = []
    private var nonEmptyTerminalItemIDs: Set<String> = []
    private var failedTerminalCount = 0
    private var protocolErrorCount = 0
    private var emptySuccessCount = 0
    private var nonEmptySuccessCount = 0
    private var previewEventCount = 0
    private var firstPreviewAt: ContinuousClock.Instant?
    private var lastTerminalAt: ContinuousClock.Instant?
    private var audioStartedAt = ContinuousClock().now
    private var lastAudioSentAt = ContinuousClock().now

    func markAudioStarted(at instant: ContinuousClock.Instant) {
        audioStartedAt = instant
    }

    func markAudioSent(at instant: ContinuousClock.Instant, pcm: Data) {
        lastAudioSentAt = instant
        uploadedSampleWatermark += pcm.count / MemoryLayout<Int16>.size
        uploadedPCMHasher.update(data: pcm)
    }

    func uploadedPCMMatches(_ sourcePCM: Data) -> Bool {
        var expectedHasher = SHA256()
        expectedHasher.update(data: sourcePCM)
        let uploadedHasher = uploadedPCMHasher
        return Data(expectedHasher.finalize()) == Data(uploadedHasher.finalize())
    }

    func consume(_ envelope: RealtimeEventEnvelope<RealtimeASRClient.Event>) {
        order += 1
        switch envelope.payload {
        case .segmentClosed(let itemID, let span, let reason, _):
            boundaryCounts[itemID, default: 0] += 1
            boundaries.append(
                ReplayBoundary(itemID: itemID, span: span, reason: reason, order: order)
            )
        case .completed(let itemID, let transcript):
            terminalCounts[itemID, default: 0] += 1
            terminalOrder[itemID] = order
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptySuccessCount += 1
                emptyTerminalItemIDs.insert(itemID)
            } else {
                nonEmptyTerminalItemIDs.insert(itemID)
                nonEmptySuccessCount += 1
            }
            lastTerminalAt = envelope.receivedAt
        case .failed(let itemID, _, _):
            terminalCounts[itemID, default: 0] += 1
            terminalOrder[itemID] = order
            failedTerminalCount += 1
            lastTerminalAt = envelope.receivedAt
        case .partial, .partialSnapshot:
            previewEventCount += 1
            if firstPreviewAt == nil { firstPreviewAt = envelope.receivedAt }
        case .serverError:
            protocolErrorCount += 1
        default:
            break
        }
    }

    func snapshot() -> ReplaySnapshot {
        ReplaySnapshot(
            uploadedSampleWatermark: uploadedSampleWatermark,
            boundaryCounts: boundaryCounts,
            boundaries: boundaries,
            terminalCounts: terminalCounts,
            terminalOrder: terminalOrder,
            emptyTerminalItemIDs: emptyTerminalItemIDs,
            nonEmptyTerminalItemIDs: nonEmptyTerminalItemIDs,
            failedTerminalCount: failedTerminalCount,
            protocolErrorCount: protocolErrorCount,
            emptySuccessCount: emptySuccessCount,
            nonEmptySuccessCount: nonEmptySuccessCount,
            previewEventCount: previewEventCount,
            audioStartedAt: audioStartedAt,
            lastAudioSentAt: lastAudioSentAt,
            firstPreviewAt: firstPreviewAt,
            lastTerminalAt: lastTerminalAt
        )
    }
}

private struct ReplaySummary: Encodable {
    let schemaVersion = 1
    let fixtureID: String
    let preset: String
    let inputSampleRate = Int(RealtimeASRClient.sampleRate)
    let inputSamples: Int
    let uploadedSampleWatermark: Int
    let maximumSegmentSamples: Int
    let segmentCount: Int
    let terminalCount: Int
    let failedTerminalCount: Int
    let protocolErrorCount: Int
    let emptySuccessCount: Int
    let nonEmptySuccessCount: Int
    let previewEventCount: Int
    let firstPreviewMilliseconds: Double?
    let finalAfterLastAudioMilliseconds: Double?
    let spanIntegrityGate: String
    let uploadGate: String
    let pcmIntegrityGate: String
    let receiptBarrierGate: String
    let terminalGate: String
    let recognitionGate: String
    let executionGate: String
    let spans: [Span]

    struct Span: Encodable {
        let startSample: Int
        let endSample: Int
        let reason: String
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fixtureID = "fixture_id"
        case preset
        case inputSampleRate = "input_sample_rate"
        case inputSamples = "input_samples"
        case uploadedSampleWatermark = "uploaded_sample_watermark"
        case maximumSegmentSamples = "maximum_segment_samples"
        case segmentCount = "segment_count"
        case terminalCount = "terminal_count"
        case failedTerminalCount = "failed_terminal_count"
        case protocolErrorCount = "protocol_error_count"
        case emptySuccessCount = "empty_success_count"
        case nonEmptySuccessCount = "non_empty_success_count"
        case previewEventCount = "preview_event_count"
        case firstPreviewMilliseconds = "first_preview_ms"
        case finalAfterLastAudioMilliseconds = "final_after_last_audio_ms"
        case spanIntegrityGate = "span_integrity_gate"
        case uploadGate = "upload_gate"
        case pcmIntegrityGate = "pcm_integrity_gate"
        case receiptBarrierGate = "receipt_barrier_gate"
        case terminalGate = "terminal_gate"
        case recognitionGate = "recognition_gate"
        case executionGate = "execution_gate"
        case spans
    }
}

private func replay(
    _ pcm: Data,
    into client: RealtimeASRClient,
    recorder: ReplayEventRecorder,
    clock: ContinuousClock
) async throws {
    let chunkByteCount = 960 * MemoryLayout<Int16>.size
    var deadline = clock.now
    for offset in stride(from: 0, to: pcm.count, by: chunkByteCount) {
        let end = min(offset + chunkByteCount, pcm.count)
        let chunk = pcm.subdata(in: offset..<end)
        try await client.append(chunk)
        await recorder.markAudioSent(at: clock.now, pcm: chunk)
        deadline = deadline.advanced(by: .milliseconds(40))
        try await clock.sleep(until: deadline, tolerance: .milliseconds(8))
    }
}

private func milliseconds(
    from start: ContinuousClock.Instant,
    to end: ContinuousClock.Instant
) -> Double {
    let duration = start.duration(to: end).components
    return max(
        0,
        (Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000) * 1_000
    )
}
