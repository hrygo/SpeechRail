import XCTest
@testable import SpeechRailControlKit
@testable import SpeechRailAppSupport

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

    func testCaptionTranscriptionUsesTheCaptionChunk() {
        XCTAssertEqual(TranscriptionSessionUpdate.captionChunkDurationMilliseconds, 500)

        let event = TranscriptionSessionUpdate(
            model: RealtimeASRClientModelFixture.canonical,
            chunkDurationMilliseconds: TranscriptionSessionUpdate.captionChunkDurationMilliseconds
        )
        let speechrail = (event.jsonObject["session"] as? [String: Any])?["speechrail"] as? [String: Any]
        let transcription = speechrail?["transcription"] as? [String: Any]
        XCTAssertEqual(
            transcription?["chunk_duration_ms"] as? Int,
            TranscriptionSessionUpdate.captionChunkDurationMilliseconds
        )
    }

    func testCallerTTSIgnoresStaleDoneAndSuppressesAudioAfterCancel() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(apiKey: "", callerTTSEnabled: true)
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        guard let configured = await events.next() else {
            XCTFail("Realtime client did not acknowledge its test configuration")
            await client.close()
            return
        }
        guard case .configured = configured.payload else {
            XCTFail("Expected configuration acknowledgement, got \(configured.payload)")
            await client.close()
            return
        }

        try await client.sendTTSCreate(text: "旧请求", requestID: "request-old")
        await transport.enqueue(.text(jsonText(responseCreated(responseID: "response-old"))))
        await transport.enqueue(.text(jsonText(responseDone(
            requestID: "request-old",
            responseID: "response-old",
            status: "completed"
        ))))
        guard let oldDone = await events.next() else {
            XCTFail("Expected the old request's terminal event")
            await client.close()
            return
        }
        guard case .responseDone(let oldRequestID, let oldResponseID, let oldStatus, _) = oldDone.payload
        else {
            XCTFail("Expected a TTS terminal event, got \(oldDone.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(oldRequestID, "request-old")
        XCTAssertEqual(oldResponseID, "response-old")
        XCTAssertEqual(oldStatus, "completed")

        try await client.sendTTSCreate(text: "新请求", requestID: "request-new")
        await transport.enqueue(.text(jsonText(responseCreated(responseID: "response-new"))))
        // A duplicated/late terminal for the old response must not clear the new request.
        await transport.enqueue(.text(jsonText(responseDone(
            requestID: "request-old",
            responseID: "response-old",
            status: "completed"
        ))))
        await transport.enqueue(.text(jsonText(responseDone(
            requestID: "request-new",
            responseID: "response-old",
            status: "completed"
        ))))
        await transport.enqueue(
            .text(jsonText(responseAudioDelta(responseID: "response-old", pcm: Data([4, 5, 6, 7]))))
        )
        await transport.enqueue(
            .text(jsonText(responseAudioDelta(responseID: "response-new", pcm: Data([1, 2, 3, 4]))))
        )
        await transport.enqueue(.text(jsonText(["type": "input_audio_buffer.speech_started"])))

        guard let audio = await events.next() else {
            XCTFail("Expected audio from the active request")
            await client.close()
            return
        }
        guard case .responseAudio(let requestID, let responseID, let pcm) = audio.payload else {
            XCTFail("Expected active-request audio, got \(audio.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(requestID, "request-new")
        XCTAssertEqual(responseID, "response-new")
        XCTAssertEqual(pcm, Data([1, 2, 3, 4]))
        guard let marker = await events.next() else {
            XCTFail("Expected the marker after active-request audio")
            await client.close()
            return
        }
        guard case .speechStarted = marker.payload else {
            XCTFail("Expected the receive loop to continue after stale terminal, got \(marker.payload)")
            await client.close()
            return
        }

        try await client.cancelTTS()
        let sentMessages = await transport.sentMessages()
        let sentObjects = sentMessages
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let createObjects = sentObjects.filter { $0["type"] as? String == "speechrail.tts.create" }
        XCTAssertEqual(
            createObjects.compactMap { $0["request_id"] as? String },
            ["request-old", "request-new"]
        )
        XCTAssertEqual(
            createObjects.compactMap { $0["text"] as? String },
            ["旧请求", "新请求"]
        )
        let cancelObject = sentObjects.first { $0["type"] as? String == "speechrail.tts.cancel" }
        XCTAssertEqual(cancelObject?["request_id"] as? String, "request-new")
        XCTAssertEqual(cancelObject?["response_id"] as? String, "response-new")

        await transport.enqueue(
            .text(jsonText(responseAudioDelta(responseID: "response-new", pcm: Data([9, 8, 7, 6]))))
        )
        await transport.enqueue(.text(jsonText(["type": "input_audio_buffer.speech_started"])))
        guard let afterCancel = await events.next() else {
            XCTFail("Expected the post-cancel marker")
            await client.close()
            return
        }
        guard case .speechStarted = afterCancel.payload else {
            XCTFail("Late audio reached the client after cancellation: \(afterCancel.payload)")
            await client.close()
            return
        }

        await transport.enqueue(.text(jsonText(responseDone(
            requestID: "request-new",
            responseID: "response-new",
            status: "cancelled"
        ))))
        guard let newDone = await events.next() else {
            XCTFail("Expected the active request's cancellation receipt")
            await client.close()
            return
        }
        guard case .responseDone(let requestID, let responseID, let status, _) = newDone.payload else {
            XCTFail("Expected the active request's terminal event, got \(newDone.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(requestID, "request-new")
        XCTAssertEqual(responseID, "response-new")
        XCTAssertEqual(status, "cancelled")
        await client.close()
    }
}

private enum RealtimeASRClientModelFixture {
    static let canonical = "speechrail/qwen3-asr-1.7b"
}

private actor TestRealtimeASRTransport: RealtimeASRTransport {
    private enum TestError: Error {
        case closed
    }

    private var frames: [RealtimeASRSocketFrame] = []
    private var receiver: CheckedContinuation<RealtimeASRSocketFrame, Error>?
    private var sent: [String] = []
    private var closed = false

    func resume() async {}

    func send(_ text: String) async throws {
        sent.append(text)
        guard
            let data = text.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            payload["type"] as? String == "transcription_session.update"
        else {
            return
        }
        enqueue(.text(#"{"type":"transcription_session.updated"}"#))
    }

    func receive() async throws -> RealtimeASRSocketFrame {
        if !frames.isEmpty { return frames.removeFirst() }
        if closed { throw TestError.closed }
        return try await withCheckedThrowingContinuation { continuation in
            receiver = continuation
        }
    }

    func closeCode() async -> Int? { nil }

    func cancel() async {
        closed = true
        receiver?.resume(throwing: TestError.closed)
        receiver = nil
    }

    func enqueue(_ frame: RealtimeASRSocketFrame) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: frame)
        } else {
            frames.append(frame)
        }
    }

    func sentMessages() -> [String] { sent }
}

private func jsonText(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

private func responseDone(requestID: String, responseID: String, status: String) -> [String: Any] {
    let itemID = "item-\(responseID)"
    return [
        "type": "response.done",
        "response": [
            "id": responseID,
            "object": "realtime.response",
            "status": status,
            "status_details": NSNull(),
            "output": [[
                "id": itemID,
                "object": "realtime.item",
                "type": "message",
                "role": "assistant",
                "content": [[
                    "type": "audio",
                    "transcript": "测试语句",
                    "audio": NSNull()
                ]]
            ]],
            "usage": NSNull()
        ],
        "speechrail": [
            "kind": "tts",
            "orchestration": "caller",
            "request_id": requestID,
            "voice_revision": NSNull()
        ]
    ]
}

private func responseCreated(responseID: String) -> [String: Any] {
    [
        "type": "response.created",
        "response": [
            "id": responseID,
            "object": "realtime.response",
            "status": "in_progress",
            "status_details": NSNull(),
            "output": [Any](),
            "usage": NSNull()
        ]
    ]
}

private func responseAudioDelta(responseID: String, pcm: Data) -> [String: Any] {
    [
        "type": "response.output_audio.delta",
        "response_id": responseID,
        "output_index": 0,
        "item_id": "item-\(responseID)",
        "content_index": 0,
        "delta": pcm.base64EncodedString()
    ]
}
