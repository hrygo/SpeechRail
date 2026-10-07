import Foundation
import CryptoKit
import SpeechRailControlKit
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

@Suite
struct SessionReplayFixtureBudgetTests {
    @Test
    func keepsTheDefaultThirtySecondFixtureLimit() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        #expect(throws: (any Error).self) {
            _ = try ReplayPCM24K.load(from: fixture)
        }
    }

    @Test
    func explicitlyBoundedLongFixturePreservesAllSamples() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let pcm = try ReplayPCM24K.load(from: fixture, maximumAudioSeconds: 3_600)
        #expect(abs(pcm.bytes.count / MemoryLayout<Int16>.size - 31 * 24_000) <= 2)
    }

    @Test(arguments: [-1, 0, 3_601, Int.max])
    func rejectsInvalidDurationBeforeAllocation(maximumAudioSeconds: Int) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        #expect(throws: (any Error).self) {
            _ = try ReplayPCM24K.load(from: fixture, maximumAudioSeconds: maximumAudioSeconds)
        }
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-replay-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("silence.wav")
        let payloadBytes = UInt32(31 * 16_000 * MemoryLayout<Int16>.size)
        var wav = Data("RIFF".utf8)
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        append32(36 + payloadBytes)
        wav.append(Data("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(16_000)
        append32(32_000)
        append16(2)
        append16(16)
        wav.append(Data("data".utf8))
        append32(payloadBytes)
        wav.append(Data(repeating: 0, count: Int(payloadBytes)))
        guard FileManager.default.createFile(
            atPath: url.path, contents: wav, attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}

@Suite
struct SessionReplayTerminalIntegrityTests {
    private let boundary = SessionReplayBoundary(
        itemID: "speech",
        span: .init(startSample: 2_400, endSample: 9_600),
        reason: .vad,
        order: 2,
        connectionID: "connection-1"
    )

    @Test
    func rejectsBoundaryWithoutTerminal() {
        #expect(
            !SessionReplayTerminalIntegrity.validate(
                boundaries: [boundary],
                boundaryCounts: ["speech": 1],
                terminalCounts: [:],
                terminalOrder: [:],
                emptyTerminalItemIDs: [],
                configuredEventCount: 1,
                mirrorOverflowCount: 0
            )
        )
    }

    @Test
    func rejectsDuplicateTerminal() {
        #expect(
            !SessionReplayTerminalIntegrity.validate(
                boundaries: [boundary],
                boundaryCounts: ["speech": 1],
                terminalCounts: ["speech": 2],
                terminalOrder: ["speech": 4],
                emptyTerminalItemIDs: [],
                configuredEventCount: 1,
                mirrorOverflowCount: 0
            )
        )
    }

    @Test
    func rejectsTerminalBeforeBoundary() {
        #expect(
            !SessionReplayTerminalIntegrity.validate(
                boundaries: [boundary],
                boundaryCounts: ["speech": 1],
                terminalCounts: ["speech": 1],
                terminalOrder: ["speech": 1],
                emptyTerminalItemIDs: [],
                configuredEventCount: 1,
                mirrorOverflowCount: 0
            )
        )
    }

    @Test
    func allowsUnboundEmptyCommitAlongsideBoundSpeech() {
        #expect(
            SessionReplayTerminalIntegrity.validate(
                boundaries: [boundary],
                boundaryCounts: ["speech": 1],
                terminalCounts: ["speech": 1, "empty-commit": 1],
                terminalOrder: ["speech": 3, "empty-commit": 4],
                emptyTerminalItemIDs: ["empty-commit"],
                configuredEventCount: 1,
                mirrorOverflowCount: 0
            )
        )
    }
}

@Suite
struct SessionReplayRecognitionIntegrityTests {
    private let boundary = SessionReplayBoundary(
        itemID: "speech",
        span: .init(startSample: 2_400, endSample: 9_600),
        reason: .vad,
        order: 2,
        connectionID: "connection-1"
    )

    @Test
    func allowsUnboundEmptyCompletedAlongsideRecognizedSpeech() {
        #expect(
            SessionReplayRecognitionIntegrity.validate(
                boundaries: [boundary],
                terminalCounts: ["speech": 1, "empty-commit": 1],
                terminalTexts: ["speech": "recognized", "empty-commit": ""],
                failedTerminalCount: 0,
                serverErrorCount: 0
            )
        )
    }

    @Test
    func rejectsOnlyEmptySuccesses() {
        #expect(
            !SessionReplayRecognitionIntegrity.validate(
                boundaries: [boundary],
                terminalCounts: ["speech": 1, "empty-commit": 1],
                terminalTexts: ["speech": "  ", "empty-commit": ""],
                failedTerminalCount: 0,
                serverErrorCount: 0
            )
        )
    }

    @Test
    func rejectsFailedTerminal() {
        #expect(
            !SessionReplayRecognitionIntegrity.validate(
                boundaries: [boundary],
                terminalCounts: ["speech": 1],
                terminalTexts: ["speech": "recognized"],
                failedTerminalCount: 1,
                serverErrorCount: 0
            )
        )
    }

    @Test
    func rejectsServerError() {
        #expect(
            !SessionReplayRecognitionIntegrity.validate(
                boundaries: [boundary],
                terminalCounts: ["speech": 1],
                terminalTexts: ["speech": "recognized"],
                failedTerminalCount: 0,
                serverErrorCount: 1
            )
        )
    }
}

@Suite
struct SessionReplayLLMInputIntegrityTests {
    private var boundaries: [SessionReplayBoundary] {
        [
            SessionReplayBoundary(
                itemID: "tail",
                span: .init(startSample: 480_000, endSample: 528_000),
                reason: .vad, order: 3, connectionID: "same"
            ),
            SessionReplayBoundary(
                itemID: "head",
                span: .init(startSample: 0, endSample: 480_000),
                reason: .budgetRollover, order: 1, connectionID: "same"
            )
        ]
    }

    @Test
    func comparesAllFormalSegmentsInInputOrder() {
        #expect(SessionReplayLLMInputIntegrity.matches(
            messages: [.init(role: .user, text: "不要改成 12，保留 21。")],
            boundaries: boundaries,
            terminalTexts: ["head": "不要改成12，", "tail": "保留21。"]
        ))
    }

    @Test
    func rejectsLostNegationOrChangedDigits() {
        for input in ["改成12，保留21。", "不要改成12，保留12。", "不要改成12，"] {
            #expect(!SessionReplayLLMInputIntegrity.matches(
                messages: [.init(role: .user, text: input)],
                boundaries: boundaries,
                terminalTexts: ["head": "不要改成12，", "tail": "保留21。"]
            ))
        }
    }

    @Test
    func rejectsMissingTerminalOrMultipleUserMessages() {
        #expect(!SessionReplayLLMInputIntegrity.matches(
            messages: [.init(role: .user, text: "不要改成12，")],
            boundaries: boundaries,
            terminalTexts: ["head": "不要改成12，"]
        ))
        #expect(!SessionReplayLLMInputIntegrity.matches(
            messages: [.init(role: .user, text: "不要改成12，"), .init(role: .user, text: "保留21。")],
            boundaries: boundaries,
            terminalTexts: ["head": "不要改成12，", "tail": "保留21。"]
        ))
    }
}

@Suite
struct SessionReplayLLMResponseEvidenceTests {
    private struct Upstream: AssistantLLM {
        let chunks: [String]
        var fails = false

        func check(
            configuration: LLMConfiguration, apiKey: String?, operation: LLMOperation,
            allowThinkingControlFallback: Bool
        ) async -> LLMConnectionResult {
            .connected(milliseconds: 1, model: "fake")
        }

        func stream(
            configuration: LLMConfiguration, messages: [LLMMessage], apiKey: String?,
            maxOutputTokens: Int?, instructions: String?
        ) async -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                if fails {
                    continuation.finish(throwing: SessionReplayFailure.businessTurnDidNotArrive)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    private func stream(_ llm: SessionReplayAssistantLLM) async -> AsyncThrowingStream<String, Error> {
        await llm.stream(
            configuration: LLMConfiguration(baseURL: "http://127.0.0.1:1/v1", model: "fake"),
            messages: [.init(role: .user, text: "test")], apiKey: nil,
            maxOutputTokens: nil, instructions: nil
        )
    }

    @Test
    func whitespaceOnlyResponseDoesNotCountAsContent() async throws {
        let llm = SessionReplayAssistantLLM(
            recorder: SessionReplayRecorder(), provider: Upstream(chunks: [" \n", "\t"])
        )
        for try await _ in await stream(llm) {}
        #expect(await llm.completedStreamCount == 1)
        #expect(await llm.outputCharacters == 3)
        #expect(await llm.outputContentCharacters == 0)
        #expect(await llm.formalInputMatched == false)
    }

    @Test
    func forwardsContentAndDoesNotRecordFailureAsCompletion() async throws {
        let llm = SessionReplayAssistantLLM(
            recorder: SessionReplayRecorder(), provider: Upstream(chunks: ["已", "处理。"], fails: true)
        )
        var received = ""
        do {
            for try await delta in await stream(llm) { received += delta }
            Issue.record("The upstream failure must reach the consumer.")
        } catch SessionReplayFailure.businessTurnDidNotArrive {
            #expect(received == "已处理。")
        }
        #expect(await llm.completedStreamCount == 0)
        #expect(await llm.outputContentCharacters == 4)
    }
}

@Suite
struct SessionReplayRowIntegrityTests {
    private let recordStartedAt = Date(timeIntervalSince1970: 1_000)
    private let ledgerOrigin = Date(timeIntervalSince1970: 1_001)

    @Test
    func laterPersistenceObservationMustNotMoveReplayCaptureOrigin() async throws {
        let clock = SessionReplayMeetingClock()
        let origin = clock.now()
        try await Task.sleep(for: .milliseconds(10))
        let persistenceObservation = clock.now()
        #expect(persistenceObservation > origin)
        #expect(clock.captureOrigin == origin)
    }

    @Test
    func matchesRowsOneToOneAcrossReorderedSameTextAndDuration() {
        let boundaries = [
            boundary(itemID: "first", start: 2_400, end: 7_200),
            boundary(itemID: "second", start: 9_600, end: 14_400)
        ]
        let rows = [
            row(id: "row-2", ordinal: 2, start: 1.4, end: 1.6),
            row(id: "row-1", ordinal: 1, start: 1.1, end: 1.3)
        ]

        #expect(
            SessionReplayRowIntegrity.matches(
                boundaries: boundaries,
                boundaryCounts: ["first": 1, "second": 1],
                terminalCounts: ["first": 1, "second": 1],
                terminalConnectionIDs: ["first": "connection-1", "second": "connection-1"],
                terminalTexts: ["first": "same text", "second": "same text"],
                rows: rows,
                sessionID: "record-1",
                recordStartedAt: recordStartedAt,
                ledgerOrigin: ledgerOrigin
            )
        )
    }

    @Test
    func rejectsSameTextAndDurationAtWrongStartTime() {
        #expect(
            !SessionReplayRowIntegrity.matches(
                boundaries: [boundary(itemID: "item", start: 2_400, end: 12_000)],
                boundaryCounts: ["item": 1],
                terminalCounts: ["item": 1],
                terminalConnectionIDs: ["item": "connection-1"],
                terminalTexts: ["item": "same text"],
                rows: [row(id: "wrong-start", ordinal: 1, start: 1.2, end: 1.6)],
                sessionID: "record-1",
                recordStartedAt: recordStartedAt,
                ledgerOrigin: ledgerOrigin
            )
        )
    }

    @Test
    func rejectsTerminalFromDifferentRealtimeConnection() {
        #expect(
            !SessionReplayRowIntegrity.matches(
                boundaries: [boundary(itemID: "item", start: 2_400, end: 7_200)],
                boundaryCounts: ["item": 1],
                terminalCounts: ["item": 1],
                terminalConnectionIDs: ["item": "connection-2"],
                terminalTexts: ["item": "same text"],
                rows: [row(id: "row", ordinal: 1, start: 1.1, end: 1.3)],
                sessionID: "record-1",
                recordStartedAt: recordStartedAt,
                ledgerOrigin: ledgerOrigin
            )
        )
    }

    private func boundary(itemID: String, start: Int, end: Int) -> SessionReplayBoundary {
        SessionReplayBoundary(
            itemID: itemID,
            span: .init(startSample: start, endSample: end),
            reason: .vad,
            order: 1,
            connectionID: "connection-1"
        )
    }

    private func row(id: String, ordinal: Int, start: TimeInterval, end: TimeInterval) -> TranscriptLine {
        TranscriptLine(
            id: id,
            sessionID: "record-1",
            ordinal: ordinal,
            role: .speaker,
            text: "same text",
            tStart: start,
            tEnd: end,
            source: .microphone,
            status: .final
        )
    }
}

@Suite
struct SessionReplayAssistantTurnIntegrityTests {
    private let vadBoundary = SessionReplayBoundary(
        itemID: "vad-speech",
        span: .init(startSample: 2_400, endSample: 9_600),
        reason: .vad,
        order: 4,
        connectionID: "connection-1"
    )

    @Test
    func requiresTheSingleReplyAfterTheVADTerminal() {
        #expect(
            SessionReplayAssistantTurnIntegrity.validate(
                boundaries: [
                    SessionReplayBoundary(
                        itemID: "budget-speech",
                        span: .init(startSample: 0, endSample: 2_400),
                        reason: .budgetRollover,
                        order: 1,
                        connectionID: "connection-1"
                    ),
                    vadBoundary
                ],
                terminalCounts: ["budget-speech": 1, "vad-speech": 1],
                terminalOrder: ["budget-speech": 2, "vad-speech": 5],
                llmCallOrders: [6]
            )
        )
    }

    @Test
    func rejectsAReplyThatArrivesAfterBudgetButBeforeVADCompletion() {
        #expect(
            !SessionReplayAssistantTurnIntegrity.validate(
                boundaries: [vadBoundary],
                terminalCounts: ["vad-speech": 1],
                terminalOrder: ["vad-speech": 5],
                llmCallOrders: [4]
            )
        )
    }

    @Test
    func rejectsMoreThanOneReplyForTheInputTurn() {
        #expect(
            !SessionReplayAssistantTurnIntegrity.validate(
                boundaries: [vadBoundary],
                terminalCounts: ["vad-speech": 1],
                terminalOrder: ["vad-speech": 5],
                llmCallOrders: [6, 7]
            )
        )
    }

    @Test
    func rejectsAReplyWithoutExactlyOneCompletedVADItem() {
        #expect(
            !SessionReplayAssistantTurnIntegrity.validate(
                boundaries: [vadBoundary],
                terminalCounts: [:],
                terminalOrder: [:],
                llmCallOrders: [6]
            )
        )
    }
}

@Suite
struct SessionReplayTeleprompterManifestTests {
    @Test
    func requiresAndDecodesOfficialPrefixGoldForTeleprompter() throws {
        let expectedRange = SessionReplayExpectedPrefixRange(
            endSample24K: 960,
            minPrefixUTF16: 0,
            maxPrefixUTF16: 3
        )
        let configuration = try makeConfiguration(expectedRanges: [expectedRange])

        #expect(configuration.teleprompterExpectedPrefixRanges == [expectedRange])
        #expect(configuration.hasCompleteTeleprompterPrefixCoverage(fixtureSamples: 958))
        #expect(!configuration.hasCompleteTeleprompterPrefixCoverage(fixtureSamples: 959))
    }

    @Test
    func rejectsTeleprompterManifestWithoutPrefixGold() throws {
        var rejected = false
        do {
            _ = try makeConfiguration(expectedRanges: nil)
        } catch SessionReplayFailure.invalidConfiguration {
            rejected = true
        }

        #expect(rejected)
    }

    private func makeConfiguration(
        expectedRanges: [SessionReplayExpectedPrefixRange]?
    ) throws -> SessionReplayConfiguration {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechrail-session-prefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioURL = root.appendingPathComponent("fixture.wav")
        try Data().write(to: audioURL)
        let manifestURL = root.appendingPathComponent("manifest.json")
        var fixture: [String: Any] = [
            "id": "ami-meeting-01",
            "scene": "teleprompter",
            "path": audioURL.path,
            "language": "en",
            "reference_text": "one"
        ]
        if let expectedRanges {
            fixture["teleprompter_expected_prefix_ranges"] = expectedRanges.map {
                [
                    "end_sample_24k": $0.endSample24K,
                    "min_prefix_utf16": $0.minPrefixUTF16,
                    "max_prefix_utf16": $0.maxPrefixUTF16
                ]
            }
        }
        let manifest = try JSONSerialization.data(
            withJSONObject: ["fixtures": [fixture]],
            options: [.sortedKeys]
        )
        try manifest.write(to: manifestURL)

        return try SessionReplayConfiguration.load(environment: [
            "SPEECHRAIL_ASR_SESSION_MANIFEST": manifestURL.path,
            "SPEECHRAIL_ASR_SESSION_FIXTURE_ID": "ami-meeting-01",
            "SPEECHRAIL_ASR_SESSION_SCENE": "teleprompter",
            "SPEECHRAIL_ASR_SESSION_OUTPUT": root.appendingPathComponent("result.json").path
        ])
    }
}

@Suite
struct SessionReplayTeleprompterObservationLedgerTests {
    private let ranges = [
        SessionReplayExpectedPrefixRange(endSample24K: 960, minPrefixUTF16: 0, maxPrefixUTF16: 12),
        SessionReplayExpectedPrefixRange(endSample24K: 1_920, minPrefixUTF16: 0, maxPrefixUTF16: 30)
    ]

    @Test
    func laterRevisionAtALargerWatermarkCannotHideAnEarlierOvershoot() {
        var ledger = SessionReplayTeleprompterObservationLedger()
        record(&ledger, count: 1, item: "first", offset: 13, watermark: 960)
        record(&ledger, count: 2, item: "first", offset: 14, watermark: 1_920)
        record(&ledger, count: 3, item: "second", offset: 20, watermark: 1_920)

        #expect(ledger.observedAlignmentEvents == 3)
        #expect(ledger.feedEvidence(itemID: "first").observedSourcePrefixOffsetsUTF16 == [13, 14])
        #expect(ledger.latestPreviewItemID == "second")
        #expect(!ledger.feedEvidence(itemID: "second").allObservedPrefixesWithinGold)
    }

    @Test
    func finalPositionAndMissingIntermediateEventsAlsoCloseTheGate() {
        var finalizedOvershoot = SessionReplayTeleprompterObservationLedger()
        record(&finalizedOvershoot, count: 1, item: "first", offset: 12, watermark: 960)
        record(&finalizedOvershoot, count: 2, item: "first", offset: 13, watermark: 960, isPreview: false)
        record(&finalizedOvershoot, count: 3, item: "second", offset: 20, watermark: 1_920)
        #expect(!finalizedOvershoot.allObservedPrefixesWithinGold)

        var missingEvent = SessionReplayTeleprompterObservationLedger()
        record(&missingEvent, count: 2, item: "first", offset: 12, watermark: 960)
        #expect(missingEvent.observedAlignmentEvents == 0)
        #expect(!missingEvent.allObservedPrefixesWithinGold)
    }

    @Test
    func preservesMultipleProcessedPreviewsAtTheSameAudioWatermark() {
        var ledger = SessionReplayTeleprompterObservationLedger()
        record(&ledger, count: 1, item: "first", offset: 0, watermark: 960)
        record(&ledger, count: 2, item: "first", offset: 12, watermark: 960)
        let evidence = ledger.feedEvidence(itemID: "first")

        #expect(evidence.observedSourceSampleWatermarks == [960, 960])
        #expect(SessionReplayTeleprompterFeedIntegrity.validate(
            evidence,
            expectedDisplayScriptUTF16Length: 80,
            expectedSourceUTF16Length: 80,
            expectedPrefixRanges: ranges
        ))
        #expect(!SessionReplayExpectedPrefixRangeIntegrity.validateObservations(
            sourceOffsetsUTF16: [0, 12],
            sourceSampleWatermarks: [1_920, 960],
            ranges: ranges
        ))
    }

    private func record(
        _ ledger: inout SessionReplayTeleprompterObservationLedger,
        count: Int, item: String, offset: Int, watermark: Int, isPreview: Bool = true
    ) {
        ledger.record(
            expectedAlignmentEvents: count,
            itemID: item,
            isPreview: isPreview,
            position: .init(
                segmentIndex: 0, segmentOffsetUTF16: offset,
                displayPrefixOffsetUTF16: offset, sourcePrefixOffsetUTF16: offset,
                expectedDisplayScriptUTF16Length: 80
            ),
            sourceSampleWatermark: watermark,
            expectedPrefixRanges: ranges
        )
    }
}

@Suite
struct SessionReplayTeleprompterProcessingIntegrityTests {
    @Test
    func waitsForSessionProcessingAndFailsClosedWhenTheWindowSaturates() {
        #expect(SessionReplayTeleprompterProcessingIntegrity.caughtUp(
            receivedAlignmentEvents: 2, processedAlignmentSamples: 2
        ))
        #expect(!SessionReplayTeleprompterProcessingIntegrity.caughtUp(
            receivedAlignmentEvents: 2, processedAlignmentSamples: 1
        ))
        #expect(!SessionReplayTeleprompterProcessingIntegrity.caughtUp(
            receivedAlignmentEvents: 1, processedAlignmentSamples: 2
        ))
        #expect(!SessionReplayTeleprompterProcessingIntegrity.caughtUp(
            receivedAlignmentEvents: 128, processedAlignmentSamples: 128
        ))
        #expect(!SessionReplayTeleprompterProcessingIntegrity.caughtUp(
            receivedAlignmentEvents: 129, processedAlignmentSamples: 128
        ))
    }

    @Test
    func earlierTerminalDoesNotPreventTakeoverOfTheCurrentPreview() {
        #expect(SessionReplayTeleprompterProcessingIntegrity.hasUnfinalizedPreview(
            itemID: "current",
            firstPreviewOrders: ["earlier": 2, "current": 6],
            terminalCounts: ["earlier": 1]
        ))
        #expect(!SessionReplayTeleprompterProcessingIntegrity.hasUnfinalizedPreview(
            itemID: "current",
            firstPreviewOrders: ["earlier": 2, "current": 6],
            terminalCounts: ["earlier": 1, "current": 1]
        ))
    }

    @Test
    func cannotTakeOverAnItemWithoutItsOwnPreview() {
        #expect(!SessionReplayTeleprompterProcessingIntegrity.hasUnfinalizedPreview(
            itemID: "current",
            firstPreviewOrders: ["earlier": 2],
            terminalCounts: ["earlier": 1]
        ))
        #expect(!SessionReplayTeleprompterProcessingIntegrity.hasUnfinalizedPreview(
            itemID: nil,
            firstPreviewOrders: ["earlier": 2],
            terminalCounts: [:]
        ))
    }
}

@Suite
struct SessionReplayTeleprompterProgressIntegrityTests {
    private let expectedRanges = [
        SessionReplayExpectedPrefixRange(
            endSample24K: 960,
            minPrefixUTF16: 0,
            maxPrefixUTF16: 12
        ),
        SessionReplayExpectedPrefixRange(
            endSample24K: 1_920,
            minPrefixUTF16: 0,
            maxPrefixUTF16: 30
        )
    ]

    private let advancingEvidence = SessionReplayTeleprompterProgressEvidence(
        maximumSameItemRevisionCount: 2,
        observedDisplayPrefixOffsetsUTF16: [14, 32],
        observedSourcePrefixOffsetsUTF16: [12, 28],
        observedSourceSampleWatermarks: [960, 1_920],
        expectedDisplayScriptUTF16Length: 84,
        expectedSourceUTF16Length: 80,
        manualDisplayPrefixOffsetUTF16: 32,
        manualSourcePrefixOffsetUTF16: 28,
        manualSourceSampleWatermark: 1_920,
        expectedPrefixRanges: [
            SessionReplayExpectedPrefixRange(
                endSample24K: 960,
                minPrefixUTF16: 0,
                maxPrefixUTF16: 12
            ),
            SessionReplayExpectedPrefixRange(
                endSample24K: 1_920,
                minPrefixUTF16: 0,
                maxPrefixUTF16: 30
            )
        ],
        revisionsMonotonic: true,
        noFinalAtManualTakeover: true,
        previewBeforeFinal: true,
        manualPositionStable: true
    )

    @Test
    func acceptsRevisedPreviewProgressInsideTheExpectedScriptPrefixRange() {
        #expect(SessionReplayTeleprompterProgressIntegrity.validate(advancingEvidence))
    }

    @Test
    func validCurrentItemCannotMaskAnEarlierItemGoldViolation() {
        var evidence = advancingEvidence
        evidence.allObservedPrefixesWithinGold = false
        #expect(!SessionReplayTeleprompterProgressIntegrity.validate(evidence))
        #expect(!SessionReplayTeleprompterFeedIntegrity.validate(
            SessionReplayTeleprompterFeedEvidence(
                sameItemRevisionCount: 2,
                observedDisplayPrefixOffsetsUTF16: [14, 32],
                observedSourcePrefixOffsetsUTF16: [12, 28],
                observedSourceSampleWatermarks: [960, 1_920],
                itemID: "current",
                allObservedPrefixesWithinGold: false
            ),
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            expectedPrefixRanges: expectedRanges
        ))
    }

    @Test
    func acceptsProgressFromAnInitialZeroPosition() {
        let evidence = SessionReplayTeleprompterProgressEvidence(
            maximumSameItemRevisionCount: 2,
            observedDisplayPrefixOffsetsUTF16: [0, 14],
            observedSourcePrefixOffsetsUTF16: [0, 12],
            observedSourceSampleWatermarks: [960, 1_920],
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            manualDisplayPrefixOffsetUTF16: 14,
            manualSourcePrefixOffsetUTF16: 12,
            manualSourceSampleWatermark: 1_920,
            expectedPrefixRanges: expectedRanges,
            revisionsMonotonic: true,
            noFinalAtManualTakeover: true,
            previewBeforeFinal: true,
            manualPositionStable: true
        )

        #expect(SessionReplayTeleprompterProgressIntegrity.validate(evidence))
    }

    @Test
    func feedingContinuesUntilTheSameItemAdvancesWithinGold() {
        let ranges = expectedRanges + [
            SessionReplayExpectedPrefixRange(
                endSample24K: 2_880,
                minPrefixUTF16: 0,
                maxPrefixUTF16: 40
            )
        ]
        let waiting = SessionReplayTeleprompterFeedEvidence(
            sameItemRevisionCount: 2,
            observedDisplayPrefixOffsetsUTF16: [0, 0],
            observedSourcePrefixOffsetsUTF16: [0, 0],
            observedSourceSampleWatermarks: [960, 1_920]
        )
        let progressing = SessionReplayTeleprompterFeedEvidence(
            sameItemRevisionCount: 3,
            observedDisplayPrefixOffsetsUTF16: [0, 0, 14],
            observedSourcePrefixOffsetsUTF16: [0, 0, 12],
            observedSourceSampleWatermarks: [960, 1_920, 2_880]
        )
        let earlierOvershoot = SessionReplayTeleprompterFeedEvidence(
            sameItemRevisionCount: 3,
            observedDisplayPrefixOffsetsUTF16: [15, 16, 32],
            observedSourcePrefixOffsetsUTF16: [13, 14, 28],
            observedSourceSampleWatermarks: [960, 1_920, 2_880]
        )

        #expect(!SessionReplayTeleprompterFeedIntegrity.validate(
            waiting,
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            expectedPrefixRanges: ranges
        ))
        #expect(SessionReplayTeleprompterFeedIntegrity.validate(
            progressing,
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            expectedPrefixRanges: ranges
        ))
        #expect(!SessionReplayTeleprompterFeedIntegrity.validate(
            earlierOvershoot,
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            expectedPrefixRanges: ranges
        ))
    }

    @Test
    func requiresAtLeastTwoRevisionsOfTheSameItem() {
        let evidence = SessionReplayTeleprompterProgressEvidence(
            maximumSameItemRevisionCount: 1,
            observedDisplayPrefixOffsetsUTF16: [14, 32],
            observedSourcePrefixOffsetsUTF16: [12, 28],
            observedSourceSampleWatermarks: [960, 1_920],
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            manualDisplayPrefixOffsetUTF16: 32,
            manualSourcePrefixOffsetUTF16: 28,
            manualSourceSampleWatermark: 1_920,
            expectedPrefixRanges: expectedRanges,
            revisionsMonotonic: true,
            noFinalAtManualTakeover: true,
            previewBeforeFinal: true,
            manualPositionStable: true
        )

        #expect(!SessionReplayTeleprompterProgressIntegrity.validate(evidence))
    }

    @Test
    func rejectsAnOffsetBeyondTheOfficialWordTimedUpperBound() {
        let evidence = SessionReplayTeleprompterProgressEvidence(
            maximumSameItemRevisionCount: 2,
            observedDisplayPrefixOffsetsUTF16: [14, 35],
            observedSourcePrefixOffsetsUTF16: [12, 31],
            observedSourceSampleWatermarks: [960, 1_920],
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            manualDisplayPrefixOffsetUTF16: 32,
            manualSourcePrefixOffsetUTF16: 28,
            manualSourceSampleWatermark: 1_920,
            expectedPrefixRanges: expectedRanges,
            revisionsMonotonic: true,
            noFinalAtManualTakeover: true,
            previewBeforeFinal: true,
            manualPositionStable: true
        )

        #expect(!SessionReplayTeleprompterProgressIntegrity.validate(evidence))
    }

    @Test
    func rejectsAnObservationBelowTheManifestMinimum() {
        let ranges = [
            SessionReplayExpectedPrefixRange(
                endSample24K: 960,
                minPrefixUTF16: 0,
                maxPrefixUTF16: 12
            ),
            SessionReplayExpectedPrefixRange(
                endSample24K: 1_920,
                minPrefixUTF16: 29,
                maxPrefixUTF16: 30
            )
        ]
        let evidence = SessionReplayTeleprompterProgressEvidence(
            maximumSameItemRevisionCount: 2,
            observedDisplayPrefixOffsetsUTF16: [14, 32],
            observedSourcePrefixOffsetsUTF16: [12, 28],
            observedSourceSampleWatermarks: [960, 1_920],
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            manualDisplayPrefixOffsetUTF16: 32,
            manualSourcePrefixOffsetUTF16: 28,
            manualSourceSampleWatermark: 1_920,
            expectedPrefixRanges: ranges,
            revisionsMonotonic: true,
            noFinalAtManualTakeover: true,
            previewBeforeFinal: true,
            manualPositionStable: true
        )

        #expect(!SessionReplayTeleprompterProgressIntegrity.validate(evidence))
    }

    @Test
    func rejectsManualTakeoverBeyondGoldForItsFedAudioWatermark() {
        let evidence = SessionReplayTeleprompterProgressEvidence(
            maximumSameItemRevisionCount: 2,
            observedDisplayPrefixOffsetsUTF16: [14, 32],
            observedSourcePrefixOffsetsUTF16: [12, 28],
            observedSourceSampleWatermarks: [960, 1_920],
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            manualDisplayPrefixOffsetUTF16: 35,
            manualSourcePrefixOffsetUTF16: 31,
            manualSourceSampleWatermark: 1_920,
            expectedPrefixRanges: expectedRanges,
            revisionsMonotonic: true,
            noFinalAtManualTakeover: true,
            previewBeforeFinal: true,
            manualPositionStable: true
        )

        #expect(!SessionReplayTeleprompterProgressIntegrity.validate(evidence))
    }

    @Test
    func rejectsMissingGoldAndWatermarksBeyondTheLastBucket() {
        #expect(
            !SessionReplayExpectedPrefixRangeIntegrity.validateManifest(
                nil,
                sourceUTF16Length: 80
            )
        )
        #expect(
            !SessionReplayExpectedPrefixRangeIntegrity.validateObservations(
                sourceOffsetsUTF16: [12, 28],
                sourceSampleWatermarks: [960, 1_921],
                ranges: expectedRanges
            )
        )
    }

    @Test
    func requiresStrictlyIncreasingFortyMillisecondManifestBuckets() {
        let overlapping = [
            SessionReplayExpectedPrefixRange(endSample24K: 960, minPrefixUTF16: 0, maxPrefixUTF16: 12),
            SessionReplayExpectedPrefixRange(endSample24K: 960, minPrefixUTF16: 0, maxPrefixUTF16: 30)
        ]
        let oversizedBucket = [
            SessionReplayExpectedPrefixRange(endSample24K: 961, minPrefixUTF16: 0, maxPrefixUTF16: 12),
            SessionReplayExpectedPrefixRange(endSample24K: 1_922, minPrefixUTF16: 0, maxPrefixUTF16: 30)
        ]
        let invalidBounds = [
            SessionReplayExpectedPrefixRange(endSample24K: 960, minPrefixUTF16: 13, maxPrefixUTF16: 12),
            SessionReplayExpectedPrefixRange(endSample24K: 1_920, minPrefixUTF16: 0, maxPrefixUTF16: 30)
        ]

        #expect(!SessionReplayExpectedPrefixRangeIntegrity.validateManifest(overlapping, sourceUTF16Length: 80))
        #expect(!SessionReplayExpectedPrefixRangeIntegrity.validateManifest(oversizedBucket, sourceUTF16Length: 80))
        #expect(!SessionReplayExpectedPrefixRangeIntegrity.validateManifest(invalidBounds, sourceUTF16Length: 80))
        #expect(
            !SessionReplayExpectedPrefixRangeIntegrity.validateManifest(
                expectedRanges,
                sourceUTF16Length: 80,
                fixtureSamples: 1_919
            )
        )
        #expect(
            SessionReplayExpectedPrefixRangeIntegrity.validateManifest(
                expectedRanges,
                sourceUTF16Length: 80,
                fixtureSamples: 1_918
            )
        )
    }

    @Test
    func rejectsRevisionRegressionOrNonAdvancingOffsets() {
        let revisionRegression = SessionReplayTeleprompterProgressEvidence(
            maximumSameItemRevisionCount: 2,
            observedDisplayPrefixOffsetsUTF16: [14, 32],
            observedSourcePrefixOffsetsUTF16: [12, 28],
            observedSourceSampleWatermarks: [960, 1_920],
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            manualDisplayPrefixOffsetUTF16: 32,
            manualSourcePrefixOffsetUTF16: 28,
            manualSourceSampleWatermark: 1_920,
            expectedPrefixRanges: expectedRanges,
            revisionsMonotonic: false,
            noFinalAtManualTakeover: true,
            previewBeforeFinal: true,
            manualPositionStable: true
        )
        let repeatedOffset = SessionReplayTeleprompterProgressEvidence(
            maximumSameItemRevisionCount: 2,
            observedDisplayPrefixOffsetsUTF16: [32, 32],
            observedSourcePrefixOffsetsUTF16: [28, 28],
            observedSourceSampleWatermarks: [960, 1_920],
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            manualDisplayPrefixOffsetUTF16: 32,
            manualSourcePrefixOffsetUTF16: 28,
            manualSourceSampleWatermark: 1_920,
            expectedPrefixRanges: expectedRanges,
            revisionsMonotonic: true,
            noFinalAtManualTakeover: true,
            previewBeforeFinal: true,
            manualPositionStable: true
        )

        #expect(!SessionReplayTeleprompterProgressIntegrity.validate(revisionRegression))
        #expect(!SessionReplayTeleprompterProgressIntegrity.validate(repeatedOffset))
    }

    @Test
    func mapsDisplayOffsetsBackToOriginalAcrossASixtyCharacterSpaceBoundary() throws {
        let sourceText = String(repeating: "a", count: 55) + " " + "SECONDWORD"
        let segments = try TeleprompterSegmenter.segment(sourceText: sourceText)
        #expect(segments.count == 2)
        guard segments.count == 2 else {
            Issue.record("The test sentence must cross one 60-character segment boundary.")
            return
        }

        let secondSegment = segments[1]
        let segmentOffset = 3
        let sourceOffset = SessionReplayScriptSourcePosition.prefixOffset(
            sourceRange: secondSegment.sourceRange,
            segmentUTF16Length: secondSegment.text.utf16.count,
            segmentOffsetUTF16: segmentOffset,
            sourceUTF16Length: sourceText.utf16.count
        )
        let displayOffset = segments[0].text.utf16.count + 2 + segmentOffset
        #expect(sourceOffset == secondSegment.sourceRange.start + segmentOffset)
        #expect(sourceOffset != displayOffset)
        guard let sourceOffset else {
            Issue.record("A valid segment sourceRange must map back to the original script.")
            return
        }

        let ranges = [
            SessionReplayExpectedPrefixRange(endSample24K: 960, minPrefixUTF16: 0, maxPrefixUTF16: 58),
            SessionReplayExpectedPrefixRange(endSample24K: 1_920, minPrefixUTF16: 0, maxPrefixUTF16: 59)
        ]
        #expect(
            SessionReplayExpectedPrefixRangeIntegrity.validateObservations(
                sourceOffsetsUTF16: [sourceOffset],
                sourceSampleWatermarks: [1_920],
                ranges: ranges
            )
        )
        #expect(
            !SessionReplayExpectedPrefixRangeIntegrity.validateObservations(
                sourceOffsetsUTF16: [displayOffset],
                sourceSampleWatermarks: [1_920],
                ranges: ranges
            )
        )
        #expect(
            SessionReplayScriptSourcePosition.prefixOffset(
                sourceRange: .init(start: 0, end: sourceText.utf16.count + 1),
                segmentUTF16Length: secondSegment.text.utf16.count,
                segmentOffsetUTF16: segmentOffset,
                sourceUTF16Length: sourceText.utf16.count
            ) == nil
        )
    }

    @Test
    func requiresManualTakeoverBeforeFinalAndAnUnchangedPositionAfterward() {
        let finalizedBeforeTakeover = SessionReplayTeleprompterProgressEvidence(
            maximumSameItemRevisionCount: 2,
            observedDisplayPrefixOffsetsUTF16: [14, 32],
            observedSourcePrefixOffsetsUTF16: [12, 28],
            observedSourceSampleWatermarks: [960, 1_920],
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            manualDisplayPrefixOffsetUTF16: 32,
            manualSourcePrefixOffsetUTF16: 28,
            manualSourceSampleWatermark: 1_920,
            expectedPrefixRanges: expectedRanges,
            revisionsMonotonic: true,
            noFinalAtManualTakeover: false,
            previewBeforeFinal: true,
            manualPositionStable: true
        )
        let manualJump = SessionReplayTeleprompterProgressEvidence(
            maximumSameItemRevisionCount: 2,
            observedDisplayPrefixOffsetsUTF16: [14, 32],
            observedSourcePrefixOffsetsUTF16: [12, 28],
            observedSourceSampleWatermarks: [960, 1_920],
            expectedDisplayScriptUTF16Length: 84,
            expectedSourceUTF16Length: 80,
            manualDisplayPrefixOffsetUTF16: 32,
            manualSourcePrefixOffsetUTF16: 28,
            manualSourceSampleWatermark: 1_920,
            expectedPrefixRanges: expectedRanges,
            revisionsMonotonic: true,
            noFinalAtManualTakeover: true,
            previewBeforeFinal: true,
            manualPositionStable: false
        )

        #expect(!SessionReplayTeleprompterProgressIntegrity.validate(finalizedBeforeTakeover))
        #expect(!SessionReplayTeleprompterProgressIntegrity.validate(manualJump))
    }
}

@Suite
struct SessionReplayCaptureReleaseIntegrityTests {
    @Test
    func acceptsOnlyMeetingProcessingOccupancyAsCaptureReleased() {
        let meetingProcessing = SessionCoordinator.Occupancy(kind: .meeting, isProcessing: true)
        let activeMeetingCapture = SessionCoordinator.Occupancy(kind: .meeting, isProcessing: false)
        let unrelatedProcessing = SessionCoordinator.Occupancy(kind: .assistant, isProcessing: true)

        #expect(
            SessionReplayCaptureReleaseIntegrity.coordinatorCaptureReleased(
                scene: .meeting,
                occupancy: meetingProcessing
            )
        )
        #expect(
            !SessionReplayCaptureReleaseIntegrity.coordinatorCaptureReleased(
                scene: .meeting,
                occupancy: activeMeetingCapture
            )
        )
        #expect(
            !SessionReplayCaptureReleaseIntegrity.coordinatorCaptureReleased(
                scene: .assistant,
                occupancy: unrelatedProcessing
            )
        )
        #expect(
            SessionReplayCaptureReleaseIntegrity.coordinatorCaptureReleased(
                scene: .caption,
                occupancy: nil
            )
        )
    }

    @Test
    func requiresCoordinatorCaptureSourceClientAndMirrorRelease() {
        let released = SessionReplayCaptureReleaseEvidence(
            coordinatorCaptureReleased: true,
            captureSourceStopped: true,
            realtimeClientClosed: true,
            eventMirrorDrained: true
        )
        #expect(SessionReplayCaptureReleaseIntegrity.validate(released))
        #expect(
            !SessionReplayCaptureReleaseIntegrity.validate(
                SessionReplayCaptureReleaseEvidence(
                    coordinatorCaptureReleased: false,
                    captureSourceStopped: true,
                    realtimeClientClosed: true,
                    eventMirrorDrained: true
                )
            )
        )
        #expect(
            !SessionReplayCaptureReleaseIntegrity.validate(
                SessionReplayCaptureReleaseEvidence(
                    coordinatorCaptureReleased: true,
                    captureSourceStopped: false,
                    realtimeClientClosed: true,
                    eventMirrorDrained: true
                )
            )
        )
        #expect(
            !SessionReplayCaptureReleaseIntegrity.validate(
                SessionReplayCaptureReleaseEvidence(
                    coordinatorCaptureReleased: true,
                    captureSourceStopped: true,
                    realtimeClientClosed: false,
                    eventMirrorDrained: true
                )
            )
        )
        #expect(
            !SessionReplayCaptureReleaseIntegrity.validate(
                SessionReplayCaptureReleaseEvidence(
                    coordinatorCaptureReleased: true,
                    captureSourceStopped: true,
                    realtimeClientClosed: true,
                    eventMirrorDrained: false
                )
            )
        )
    }
}

@Suite
struct ASRSessionReplaySamplerHandshakeTests {
    @Test
    func ordinaryReplayDoesNotRequireASampler() throws {
        #expect(try SessionReplaySamplerHandshake.load(
            outputURL: URL(fileURLWithPath: "/tmp/result.json"),
            environment: [:]
        ) == nil)
    }

    @Test
    func partialConfigurationIsRejected() throws {
        #expect(throws: SessionReplaySamplerHandshakeFailure.invalidConfiguration) {
            _ = try SessionReplaySamplerHandshake.load(
                outputURL: URL(fileURLWithPath: "/tmp/result.json"),
                environment: ["SPEECHRAIL_ASR_SESSION_SAMPLER_RUN_ID": UUID().uuidString.lowercased()]
            )
        }
    }

    @Test(arguments: [
        "disabled", "relative", "same_path", "ready_output", "release_output",
        "other_directory", "bad_uuid", "uppercase_uuid", "repository_output",
    ])
    func unsafeConfigurationIsRejected(_ variant: String) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var environment = fixture.environment
        var repositoryRoot = fixture.root.appendingPathComponent("repository", isDirectory: true)
        switch variant {
        case "disabled": environment.removeValue(forKey: "SPEECHRAIL_ASR_SESSION_E2E")
        case "relative": environment["SPEECHRAIL_ASR_SESSION_SAMPLER_READY"] = "ready.json"
        case "same_path": environment["SPEECHRAIL_ASR_SESSION_SAMPLER_RELEASE"] = fixture.readyURL.path
        case "ready_output": environment["SPEECHRAIL_ASR_SESSION_SAMPLER_READY"] = fixture.outputURL.path
        case "release_output": environment["SPEECHRAIL_ASR_SESSION_SAMPLER_RELEASE"] = fixture.outputURL.path
        case "other_directory":
            environment["SPEECHRAIL_ASR_SESSION_SAMPLER_RELEASE"] = fixture.root
                .appendingPathComponent("other/release.json").path
        case "bad_uuid": environment["SPEECHRAIL_ASR_SESSION_SAMPLER_RUN_ID"] = "bad"
        case "uppercase_uuid":
            environment["SPEECHRAIL_ASR_SESSION_SAMPLER_RUN_ID"] = "ABCDEFAB-1234-4567-89AB-123456789ABC"
        case "repository_output": repositoryRoot = fixture.root
        default: Issue.record("Unknown configuration fixture")
        }
        #expect(throws: SessionReplaySamplerHandshakeFailure.invalidConfiguration) {
            _ = try SessionReplaySamplerHandshake.load(
                outputURL: fixture.outputURL, environment: environment,
                repositoryRootURL: repositoryRoot
            )
        }
    }

    @Test(arguments: ["ready.json", "release.json"])
    func existingMarkersCannotReleaseANewRun(_ name: String) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("old run".utf8).write(to: fixture.root.appendingPathComponent(name))
        #expect(throws: SessionReplaySamplerHandshakeFailure.markerAlreadyExists) {
            _ = try SessionReplaySamplerHandshake.load(
                outputURL: fixture.outputURL, environment: fixture.environment
            )
        }
    }

    @Test
    func readyIsNonceBoundAndConsumerWaitsUntilRelease() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let handshake = try #require(try SessionReplaySamplerHandshake.load(
            outputURL: fixture.outputURL, environment: fixture.environment
        ))
        let consumer = Task { try await handshake.waitForSamplerStop(timeout: .seconds(1)) }
        defer { consumer.cancel() }
        try await waitForReady(fixture.readyURL)
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.readyURL)) as? [String: Any]
        #expect(marker?["schema_version"] as? Int == 1)
        #expect(marker?["run_id"] as? String == fixture.runID)
        #expect(marker?["consumer_finished"] as? Bool == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.releaseURL.path))
        try publishRelease(fixture, runID: fixture.runID)
        try await consumer.value
    }

    @Test(arguments: [
        "wrong_run", "not_stopped", "malformed", "extra_key", "boolean_schema",
        "numeric_stopped", "oversized", "symlink", "directory",
    ])
    func invalidReleaseDoesNotCountAsSamplerStopped(_ variant: String) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let handshake = try #require(try SessionReplaySamplerHandshake.load(
            outputURL: fixture.outputURL, environment: fixture.environment
        ))
        let consumer = Task { try await handshake.waitForSamplerStop(timeout: .seconds(1)) }
        defer { consumer.cancel() }
        try await waitForReady(fixture.readyURL)
        if variant == "malformed" {
            try Data("{".utf8).write(to: fixture.releaseURL, options: .atomic)
        } else if variant == "oversized" {
            try Data(repeating: 0x20, count: 1_025).write(to: fixture.releaseURL)
        } else if variant == "symlink" {
            let target = fixture.root.appendingPathComponent("target.json")
            let bytes = try JSONSerialization.data(withJSONObject: [
                "schema_version": 1, "run_id": fixture.runID, "sampler_stopped": true,
            ])
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(at: fixture.releaseURL, withDestinationURL: target)
        } else if variant == "directory" {
            try FileManager.default.createDirectory(at: fixture.releaseURL, withIntermediateDirectories: false)
        } else if ["extra_key", "boolean_schema", "numeric_stopped"].contains(variant) {
            var marker: [String: Any] = [
                "schema_version": 1, "run_id": fixture.runID, "sampler_stopped": true,
            ]
            if variant == "extra_key" { marker["unexpected"] = true }
            if variant == "boolean_schema" { marker["schema_version"] = true }
            if variant == "numeric_stopped" { marker["sampler_stopped"] = 1 }
            try JSONSerialization.data(withJSONObject: marker).write(to: fixture.releaseURL, options: .atomic)
        } else {
            try publishRelease(
                fixture,
                runID: variant == "wrong_run" ? UUID().uuidString.lowercased() : fixture.runID,
                stopped: variant != "not_stopped"
            )
        }
        var rejected = false
        do {
            try await consumer.value
        } catch SessionReplaySamplerHandshakeFailure.invalidReleaseMarker {
            rejected = true
        }
        #expect(rejected)
    }

    @Test
    func readyPublicationCannotOverwriteAMarkerCreatedAfterLoad() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let handshake = try #require(try SessionReplaySamplerHandshake.load(
            outputURL: fixture.outputURL, environment: fixture.environment
        ))
        let oldBytes = Data("a different writer".utf8)
        try oldBytes.write(to: fixture.readyURL)
        var rejected = false
        do {
            try await handshake.waitForSamplerStop(timeout: .seconds(1))
        } catch SessionReplaySamplerHandshakeFailure.markerAlreadyExists {
            rejected = true
        }
        #expect(rejected)
        #expect(try Data(contentsOf: fixture.readyURL) == oldBytes)
        #expect(!FileManager.default.fileExists(atPath: fixture.releaseURL.path))
    }

    @Test
    func danglingExistingMarkerIsRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createSymbolicLink(
            at: fixture.readyURL, withDestinationURL: fixture.root.appendingPathComponent("missing.json")
        )
        #expect(throws: SessionReplaySamplerHandshakeFailure.markerAlreadyExists) {
            _ = try SessionReplaySamplerHandshake.load(
                outputURL: fixture.outputURL, environment: fixture.environment
            )
        }
    }

    @Test
    func missingReleaseTimesOutWithoutClaimingSuccess() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let handshake = try #require(try SessionReplaySamplerHandshake.load(
            outputURL: fixture.outputURL, environment: fixture.environment
        ))
        var timedOut = false
        do {
            try await handshake.waitForSamplerStop(timeout: .milliseconds(2))
        } catch SessionReplaySamplerHandshakeFailure.samplerReleaseTimedOut {
            timedOut = true
        }
        #expect(timedOut)
        #expect(FileManager.default.fileExists(atPath: fixture.readyURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.releaseURL.path))
    }

    @Test
    func cancellationDoesNotBecomeSuccess() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let handshake = try #require(try SessionReplaySamplerHandshake.load(
            outputURL: fixture.outputURL, environment: fixture.environment
        ))
        let consumer = Task { try await handshake.waitForSamplerStop(timeout: .seconds(1)) }
        try await waitForReady(fixture.readyURL)
        consumer.cancel()
        var cancelled = false
        do {
            try await consumer.value
        } catch is CancellationError {
            cancelled = true
        }
        #expect(cancelled)
        #expect(!FileManager.default.fileExists(atPath: fixture.releaseURL.path))
    }

    @Test
    func cancellationBeforePublicationDoesNotEmitReady() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let handshake = try #require(try SessionReplaySamplerHandshake.load(
            outputURL: fixture.outputURL, environment: fixture.environment
        ))
        let consumer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await handshake.waitForSamplerStop(timeout: .seconds(1))
        }
        var cancelled = false
        do {
            try await consumer.value
        } catch is CancellationError {
            cancelled = true
        }
        #expect(cancelled)
        #expect(!FileManager.default.fileExists(atPath: fixture.readyURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.releaseURL.path))
    }

    private struct Fixture {
        let root: URL
        let runID: String
        var outputURL: URL { root.appendingPathComponent("result.json") }
        var readyURL: URL { root.appendingPathComponent("ready.json") }
        var releaseURL: URL { root.appendingPathComponent("release.json") }
        var environment: [String: String] {
            [
                "SPEECHRAIL_ASR_SESSION_E2E": "1",
                "SPEECHRAIL_ASR_SESSION_SAMPLER_RUN_ID": runID,
                "SPEECHRAIL_ASR_SESSION_SAMPLER_READY": readyURL.path,
                "SPEECHRAIL_ASR_SESSION_SAMPLER_RELEASE": releaseURL.path,
            ]
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "speechrail-sampler-handshake-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return Fixture(root: root, runID: UUID().uuidString.lowercased())
    }

    private func publishRelease(_ fixture: Fixture, runID: String, stopped: Bool = true) throws {
        let bytes = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "run_id": runID, "sampler_stopped": stopped,
        ])
        try bytes.write(to: fixture.releaseURL, options: .atomic)
    }

    private func waitForReady(_ url: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard clock.now < deadline else {
                throw SessionReplaySamplerHandshakeFailure.samplerReleaseTimedOut
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
