import XCTest
@testable import SpeechRailControlKit

final class RealtimeContractTests: XCTestCase {
    func testSequenceValidatorReportsGapAndRegression() {
        var validator = RealtimeSequenceValidator()

        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e1", sessionID: "s1", sequence: 1)),
            .first
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e2", sessionID: "s1", sequence: 3)),
            .gap(expected: 2, received: 3)
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e3", sessionID: "s1", sequence: 2)),
            .regression(last: 3, received: 2)
        )
    }

    func testSequenceValidatorReportsMissingAndSessionChange() {
        var validator = RealtimeSequenceValidator()

        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(sessionID: "s1", sequence: 1)),
            .first
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(sessionID: "s1")),
            .missing
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(sessionID: "s2", sequence: 1)),
            .sessionChanged(expected: "s1", received: "s2")
        )
    }

    func testCloseBarrierOnlyAllowsClearAfterEveryCommittedItemIsTerminal() {
        var barrier = RealtimeCloseBarrier()
        barrier.committed(itemID: "item-1")
        XCTAssertFalse(barrier.isReadyToClear)

        barrier.completed(itemID: "item-1")
        XCTAssertTrue(barrier.isReadyToClear)
    }

    func testCloseBarrierAcceptsFailedTerminalItemsAndDeduplicatesCommit() {
        var barrier = RealtimeCloseBarrier()
        barrier.committed(itemID: "item-1")
        barrier.committed(itemID: "item-1")
        barrier.committed(itemID: "item-2")
        barrier.failed(itemID: "item-1")

        XCTAssertEqual(barrier.pendingItemIDs, ["item-2"])
        XCTAssertFalse(barrier.isReadyToClear)

        barrier.failed(itemID: "item-2")
        XCTAssertTrue(barrier.isReadyToClear)
    }

    func testDrainPlanOrdersCommitCompletionClearAndClose() {
        XCTAssertEqual(
            RealtimeClosePlan.steps,
            [.commit, .waitForTerminalItems, .clear, .close]
        )
    }

    func testRealtimeMetadataUsesWireFieldNames() throws {
        let metadata = try JSONDecoder().decode(
            RealtimeEventMetadata.self,
            from: Data(#"{"event_id":"evt-1","session_id":"sess-1","sequence":7}"#.utf8)
        )

        XCTAssertEqual(metadata.eventID, "evt-1")
        XCTAssertEqual(metadata.sessionID, "sess-1")
        XCTAssertEqual(metadata.sequence, 7)
    }

    func testCallerTTSCreateUsesSpeechRailNamespace() {
        let event = SpeechRailTTSCreate(
            requestID: "tts_req_001",
            text: "你好",
            voice: "serena",
            speed: 1.0,
            expectedVoiceRevision: "vr_abc"
        )

        XCTAssertEqual(event.type, "speechrail.tts.create")
        XCTAssertEqual(event.requestID, "tts_req_001")
        XCTAssertEqual(event.jsonObject["type"] as? String, "speechrail.tts.create")
        XCTAssertEqual(event.jsonObject["expected_voice_revision"] as? String, "vr_abc")
        XCTAssertNil(SpeechRailTTSCreate(requestID: "r", text: "hi").jsonObject["voice"])
        XCTAssertNil(SpeechRailTTSCreate(requestID: "r", text: "hi").jsonObject["expected_voice_revision"])
    }

    func testCallerTTSCancelUsesExplicitRequestAndOptionalResponseID() {
        let event = SpeechRailTTSCancel(requestID: "tts_req_001", responseID: "resp_001")

        XCTAssertEqual(event.type, "speechrail.tts.cancel")
        XCTAssertEqual(event.jsonObject["request_id"] as? String, "tts_req_001")
        XCTAssertEqual(event.jsonObject["response_id"] as? String, "resp_001")
    }

    func testTranscriptionSessionUpdateUsesCurrentOnlyFields() {
        let event = TranscriptionSessionUpdate(
            model: RealtimeASRClientModelFixture.canonical,
            callerTTSEnabled: true
        )

        XCTAssertEqual(event.type, "transcription_session.update")
        XCTAssertEqual(
            (event.jsonObject["session"] as? [String: Any])?["input_audio_format"] as? String,
            "pcm16"
        )
        let speechrail = (event.jsonObject["session"] as? [String: Any])?["speechrail"] as? [String: Any]
        let transcription = speechrail?["transcription"] as? [String: Any]
        XCTAssertEqual(transcription?["partial_mode"] as? String, "delta")
        XCTAssertEqual(transcription?["chunk_duration_ms"] as? Int, 2_000)
        XCTAssertNil((event.jsonObject["session"] as? [String: Any])?["modalities"])
    }

    func testTeleprompterTranscriptionUsesSnapshotAndLowLatencyChunk() {
        let event = TranscriptionSessionUpdate(
            model: RealtimeASRClientModelFixture.canonical,
            partialMode: .snapshot,
            chunkDurationMilliseconds: 500
        )
        let speechrail = (event.jsonObject["session"] as? [String: Any])?["speechrail"] as? [String: Any]
        let transcription = speechrail?["transcription"] as? [String: Any]
        XCTAssertEqual(transcription?["partial_mode"] as? String, "snapshot")
        XCTAssertEqual(transcription?["chunk_duration_ms"] as? Int, 500)
    }
}

private enum RealtimeASRClientModelFixture {
    static let canonical = "speechrail/qwen3-asr-1.7b"
}
