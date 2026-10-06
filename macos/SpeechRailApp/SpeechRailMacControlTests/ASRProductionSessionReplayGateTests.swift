import Foundation
import CryptoKit
import SpeechRailControlKit
import Testing
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif
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
struct SessionReplayRowIntegrityTests {
    private let recordStartedAt = Date(timeIntervalSince1970: 1_000)
    private let ledgerOrigin = Date(timeIntervalSince1970: 1_001)

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
