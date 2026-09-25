import XCTest
@testable import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class RealtimeContractTests: XCTestCase {
    func testSharedCurrentRealtimeFixturesAreMechanicallyValid() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureRoot = repoRoot
            .appendingPathComponent("tests/fixtures/realtime-current", isDirectory: true)
        let manifest = try jsonObject(
            at: fixtureRoot.appendingPathComponent("manifest.json")
        )
        XCTAssertEqual(manifest["contract_version"] as? Int, 1)
        let cases = try XCTUnwrap(manifest["cases"] as? [[String: Any]])

        var names = Set<String>()
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            XCTAssertTrue(names.insert(name).inserted, "duplicate fixture: \(name)")
            let relative = try XCTUnwrap(fixtureCase["file"] as? String)
            let payload = try jsonObject(at: fixtureRoot.appendingPathComponent(relative))
            if fixtureCase["valid"] as? Bool == true {
                try assertCurrentClientShape(payload, name: name)
            } else {
                XCTAssertNotNil(fixtureCase["rejection"] as? String, name)
                if ["legacy_transcription_session_update", "legacy_tts_response_delta", "legacy_tts_response_done"].contains(name) {
                    let type = payload["type"] as? String
                    XCTAssertTrue(
                        ["transcription_session.update", "response.output_audio.delta", "response.done"].contains(type ?? ""),
                        name
                    )
                }
            }
        }

        XCTAssertTrue(names.contains("legacy_transcription_session_update"))
        XCTAssertTrue(names.contains("design_runtime_voice"))
    }

    /// 单栈的前提是"原生层归一到 wire 那一个采样率"：采集、上行与 TTS 播放不许各说各话。
    func testCaptureUplinkAndPlaybackShareTheSingleWireSampleRate() {
        let wireRate = Int(MicrophoneCapture.sampleRate)
        XCTAssertEqual(wireRate, 24_000, "采集出口必须就是契约声明的 wire 采样率")
        XCTAssertEqual(RealtimeASRClient.sampleRate, MicrophoneCapture.sampleRate)
        XCTAssertEqual(SpeechRailSessionUpdate.wireSampleRate, wireRate)
        XCTAssertEqual(TTSAudioPosition.canonicalSampleRate, wireRate)
    }

    private func assertCurrentClientShape(_ payload: [String: Any], name: String) throws {
        let type = try XCTUnwrap(payload["type"] as? String, name)
        if type == "session.update" {
            XCTAssertNotNil(payload["event_id"], name)
            let session = try XCTUnwrap(payload["session"] as? [String: Any], name)
            let audio = try XCTUnwrap(session["audio"] as? [String: Any], name)
            let input = try XCTUnwrap(audio["input"] as? [String: Any], name)
            let format = try XCTUnwrap(input["format"] as? [String: Any], name)
            XCTAssertEqual(format["type"] as? String, "audio/pcm", name)
            XCTAssertEqual(format["rate"] as? Int, 24_000, name)
            XCTAssertNil(input["turn_detection"] as? [String: Any], name)
            let speechrail = try XCTUnwrap(session["speechrail"] as? [String: Any], name)
            XCTAssertNotNil(speechrail["task"] as? String, name)
        } else if type.hasPrefix("speechrail.tts.") {
            XCTAssertNotNil(payload["event_id"], name)
            XCTAssertNotNil(payload["request_id"], name)
        } else if type == "input_audio_buffer.append" {
            XCTAssertNotNil(payload["event_id"], name)
            let audio = try XCTUnwrap(payload["audio"] as? String, name)
            XCTAssertFalse(audio.isEmpty, name)
        } else if type.hasPrefix("input_audio_buffer.") {
            XCTAssertNotNil(payload["event_id"], name)
        }
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            url.path
        )
    }
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
        barrier.expectItem()
        XCTAssertFalse(barrier.isReadyToClear)

        barrier.completed()
        XCTAssertTrue(barrier.isReadyToClear)
    }

    func testCloseBarrierAcceptsFailedTerminalItemsAndCountsDeclaredItems() {
        var barrier = RealtimeCloseBarrier()
        barrier.expectItem()
        barrier.expectItem()
        barrier.failed()

        XCTAssertEqual(barrier.pendingItems, 1)
        XCTAssertFalse(barrier.isReadyToClear)

        barrier.failed()
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

    func testCallerTTSStartCarriesTaskVoiceAndEventID() {
        let event = SpeechRailTTSStart(
            requestID: "tts_req_001",
            task: .conversation,
            voice: "serena",
            speed: 1.0,
            voiceRevision: "vr_abc"
        )

        XCTAssertEqual(event.type, "speechrail.tts.start")
        XCTAssertEqual(event.requestID, "tts_req_001")
        XCTAssertEqual(event.jsonObject["type"] as? String, "speechrail.tts.start")
        XCTAssertEqual(event.jsonObject["task"] as? String, "conversation")
        XCTAssertEqual(event.jsonObject["voice"] as? String, "serena")
        XCTAssertEqual(event.jsonObject["voice_revision"] as? String, "vr_abc")
        XCTAssertNotNil(event.jsonObject["event_id"], "schema 要求每个 client 事件都带 event_id")
        XCTAssertNil(event.jsonObject["limits"], "没要求收紧限额时不该带 limits")
        XCTAssertNil(event.jsonObject["response_id"], "旧 response 身份已移除")
    }

    func testCallerTTSCancelUsesExplicitRequestIDOnly() {
        let event = SpeechRailTTSCancel(requestID: "tts_req_001", eventID: "evt-cancel-1")

        XCTAssertEqual(event.type, "speechrail.tts.cancel")
        XCTAssertEqual(event.jsonObject["event_id"] as? String, "evt-cancel-1")
        XCTAssertEqual(event.jsonObject["request_id"] as? String, "tts_req_001")
        XCTAssertNil(event.jsonObject["response_id"])
    }

    func testSessionUpdateUsesCurrentOnlyFields() {
        let event = SpeechRailSessionUpdate(
            model: RealtimeASRClientModelFixture.canonical,
            ttsEnabled: true
        )
        let payload = event.jsonObject

        XCTAssertEqual(payload["type"] as? String, "session.update")
        XCTAssertNotNil(payload["event_id"])
        let session = payload["session"] as? [String: Any]
        XCTAssertEqual(session?["type"] as? String, "transcription")
        XCTAssertNil(session?["input_audio_format"], "旧的平铺格式字段已移除")
        XCTAssertNil(session?["modalities"])
        let input = (session?["audio"] as? [String: Any])?["input"] as? [String: Any]
        let format = input?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "audio/pcm")
        XCTAssertEqual(format?["rate"] as? Int, 24_000)
        XCTAssertNil(input?["turn_detection"] as? [String: Any], "SpeechRail endpointing 时官方 turn_detection 保持 null")
        let speechrail = session?["speechrail"] as? [String: Any]
        XCTAssertEqual(speechrail?["task"] as? String, "conversation")
        XCTAssertEqual((speechrail?["tts"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((speechrail?["diarization"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertNil(speechrail?["transcription"], "旧 partial_mode/chunk_duration_ms 不再出现")
    }

    func testSessionUpdateCarriesTaskAndEndpointing() {
        let event = SpeechRailSessionUpdate(
            model: RealtimeASRClientModelFixture.canonical,
            task: .caption,
            endpointing: SpeechRailSessionUpdate.Endpointing(
                threshold: 0.4,
                silenceDurationMilliseconds: 500
            )
        )
        let speechrail = (event.jsonObject["session"] as? [String: Any])?["speechrail"] as? [String: Any]
        let endpointing = speechrail?["endpointing"] as? [String: Any]

        XCTAssertEqual(speechrail?["task"] as? String, "caption")
        XCTAssertEqual(endpointing?["mode"] as? String, "server_vad")
        XCTAssertEqual(endpointing?["silence_duration_ms"] as? Int, 500)
        XCTAssertEqual(endpointing?["threshold"] as? Double, 0.4)
        XCTAssertNil(speechrail?["transcription"])
    }

    func testCallerTTSIgnoresStaleDoneAndSuppressesAudioAfterCancel() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(voice: "serena", apiKey: "", callerTTSEnabled: true)
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

        try await client.startTTSStream(requestID: "request-old")
        await transport.enqueue(.text(jsonText(ttsStarted(requestID: "request-old"))))
        guard let oldStarted = await events.next() else {
            XCTFail("Expected the old request's started event")
            await client.close()
            return
        }
        guard case .ttsStarted(let oldRequest, _, _) = oldStarted.payload else {
            XCTFail("Expected a TTS started event, got \(oldStarted.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(oldRequest, "request-old")

        await transport.enqueue(.text(jsonText(ttsCompleted(requestID: "request-old"))))
        guard let oldEnded = await events.next() else {
            XCTFail("Expected the old request's terminal event")
            await client.close()
            return
        }
        guard case .ttsEnded(let oldRequestID, _, let oldStatus, _, _) = oldEnded.payload else {
            XCTFail("Expected a TTS terminal event, got \(oldEnded.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(oldRequestID, "request-old")
        XCTAssertEqual(oldStatus, "completed")

        try await client.startTTSStream(requestID: "request-new")
        await transport.enqueue(.text(jsonText(ttsStarted(requestID: "request-new"))))
        guard let newStarted = await events.next(),
              case .ttsStarted(let newRequest, _, _) = newStarted.payload else {
            XCTFail("Expected the new request's started event")
            await client.close()
            return
        }
        XCTAssertEqual(newRequest, "request-new")

        // 旧 request 的迟到终态不许清掉新 request。
        await transport.enqueue(.text(jsonText(ttsCompleted(requestID: "request-old"))))
        await transport.enqueue(
            .text(jsonText(ttsAudioDelta(
                requestID: "request-old",
                chunkIndex: 0,
                sampleOffset: 0,
                pcm: Data([4, 5, 6, 7])
            )))
        )
        await transport.enqueue(
            .text(jsonText(ttsAudioDelta(
                requestID: "request-new",
                chunkIndex: 0,
                sampleOffset: 0,
                pcm: Data([1, 2, 3, 4])
            )))
        )
        await transport.enqueue(.text(jsonText(ttsTextAccepted(requestID: "request-new", appendSequence: 0))))

        guard let audio = await events.next() else {
            XCTFail("Expected audio from the active request")
            await client.close()
            return
        }
        guard case .ttsAudio(let requestID, _, let pcm) = audio.payload else {
            XCTFail("Expected active-request audio, got \(audio.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(requestID, "request-new")
        XCTAssertEqual(pcm, Data([1, 2, 3, 4]))
        guard let marker = await events.next() else {
            XCTFail("Expected the marker after active-request audio")
            await client.close()
            return
        }
        guard case .ttsTextAccepted(let markerRequest, _, let sequence, _) = marker.payload else {
            XCTFail("Expected the receive loop to continue after stale terminal, got \(marker.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(markerRequest, "request-new")
        XCTAssertEqual(sequence, 0)

        try await client.cancelTTS()
        let sentMessages = await transport.sentMessages()
        let sentObjects = sentMessages
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let startObjects = sentObjects.filter { $0["type"] as? String == "speechrail.tts.start" }
        XCTAssertEqual(
            startObjects.compactMap { $0["request_id"] as? String },
            ["request-old", "request-new"]
        )
        XCTAssertEqual(
            startObjects.compactMap { $0["voice"] as? String },
            ["serena", "serena"]
        )
        let cancelObject = sentObjects.first { $0["type"] as? String == "speechrail.tts.cancel" }
        XCTAssertEqual(cancelObject?["request_id"] as? String, "request-new")
        XCTAssertNotNil(cancelObject?["event_id"])
        XCTAssertNil(cancelObject?["response_id"], "旧 response 身份已移除")

        await transport.enqueue(
            .text(jsonText(ttsAudioDelta(
                requestID: "request-new",
                chunkIndex: 1,
                sampleOffset: 2,
                pcm: Data([9, 8, 7, 6])
            )))
        )
        await transport.enqueue(.text(jsonText(ttsTextAccepted(requestID: "request-new", appendSequence: 1))))
        guard let afterCancel = await events.next() else {
            XCTFail("Expected the post-cancel marker")
            await client.close()
            return
        }
        guard case .ttsTextAccepted = afterCancel.payload else {
            XCTFail("Late audio reached the client after cancellation: \(afterCancel.payload)")
            await client.close()
            return
        }

        await transport.enqueue(.text(jsonText(ttsCancelled(requestID: "request-new"))))
        guard let newDone = await events.next() else {
            XCTFail("Expected the active request's cancellation receipt")
            await client.close()
            return
        }
        guard case .ttsEnded(let requestID, _, let status, _, _) = newDone.payload else {
            XCTFail("Expected the active request's terminal event, got \(newDone.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(requestID, "request-new")
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
            payload["type"] as? String == "session.update"
        else {
            return
        }
        enqueue(.text(#"{"type":"session.updated"}"#))
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

private func ttsStarted(requestID: String) -> [String: Any] {
    [
        "type": "speechrail.tts.started",
        "task_id": "task-1",
        "plan_id": "plan-1",
        "request_id": requestID,
        "output_format": ["type": "audio/pcm", "sample_rate": 24_000, "channels": 1],
        "limits": [
            "max_append_codepoints": 512,
            "max_total_codepoints": 4096,
            "max_pending_codepoints": 2048,
            "max_pending_audio_bytes": 48_000,
            "input_wait_seconds": 15.0,
            "utterance_wall_clock_seconds": 120.0,
            "slow_consumer_seconds": 2.0
        ]
    ]
}

private func ttsTextAccepted(requestID: String, appendSequence: Int) -> [String: Any] {
    [
        "type": "speechrail.tts.text_accepted",
        "task_id": "task-1",
        "request_id": requestID,
        "append_sequence": appendSequence,
        "accepted_codepoints": 1,
        "total_codepoints": appendSequence + 1
    ]
}

private func ttsAudioDelta(
    requestID: String,
    chunkIndex: Int,
    sampleOffset: Int,
    pcm: Data
) -> [String: Any] {
    [
        "type": "speechrail.tts.audio.delta",
        "task_id": "task-1",
        "request_id": requestID,
        "chunk_index": chunkIndex,
        "sample_offset": sampleOffset,
        "delta": pcm.base64EncodedString()
    ]
}

private func ttsCompleted(requestID: String) -> [String: Any] {
    [
        "type": "speechrail.tts.completed",
        "task_id": "task-1",
        "request_id": requestID,
        "generated_samples": 2
    ]
}

private func ttsCancelled(requestID: String) -> [String: Any] {
    [
        "type": "speechrail.tts.cancelled",
        "task_id": "task-1",
        "request_id": requestID
    ]
}
