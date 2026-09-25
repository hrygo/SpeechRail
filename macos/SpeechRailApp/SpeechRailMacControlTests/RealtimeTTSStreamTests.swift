import XCTest
@testable import SpeechRailControlKit
@testable import SpeechRailAppSupport

/// 增量 TTS 的线上形状测试：DTO 字段与服务端 §3.3.1 对齐，
/// 客户端只把**身份匹配、序号连续、偶数字节**的音频块交给上层。
final class RealtimeTTSStreamTests: XCTestCase {
    func testStartAppendFinishUseTheContractFieldNames() {
        let start = SpeechRailTTSStart(
            requestID: "caller-turn-42",
            voice: "serena",
            speed: 1.0,
            expectedVoiceRevision: "vr_1",
            expectedModelRevision: "deadbeef"
        ).jsonObject
        XCTAssertEqual(start["type"] as? String, "speechrail.tts.start")
        XCTAssertEqual(start["request_id"] as? String, "caller-turn-42")
        XCTAssertEqual(start["voice"] as? String, "serena")
        XCTAssertEqual(start["expected_voice_revision"] as? String, "vr_1")
        XCTAssertEqual(start["expected_model_revision"] as? String, "deadbeef")
        XCTAssertNil(start["limits"], "没要求收紧限额时不该带 limits")

        let append = SpeechRailTTSAppendText(
            requestID: "caller-turn-42",
            sequence: 3,
            text: "这是调用方已经稳定的一小段文本。",
            responseID: "resp_1"
        ).jsonObject
        XCTAssertEqual(append["type"] as? String, "speechrail.tts.append_text")
        XCTAssertEqual(append["sequence"] as? Int, 3)
        XCTAssertEqual(append["response_id"] as? String, "resp_1")

        let finish = SpeechRailTTSFinishText(requestID: "caller-turn-42", lastSequence: -1).jsonObject
        XCTAssertEqual(finish["type"] as? String, "speechrail.tts.finish_text")
        XCTAssertEqual(finish["last_sequence"] as? Int, -1)
        XCTAssertNil(finish["response_id"])
    }

    func testStartedDecodesLimitsAndOutputFormat() throws {
        let payload = try XCTUnwrap(
            jsonObject("""
            {
              "type": "speechrail.tts.started",
              "request_id": "req-1",
              "response_id": "resp-1",
              "protocol_version": 1,
              "implementation_version": "tts-stream-v1",
              "voice": "serena",
              "voice_variant": "custom_voice",
              "voice_mode": "builtin",
              "limits": {
                "max_append_codepoints": 512,
                "max_total_codepoints": 4096,
                "max_pending_codepoints": 2048,
                "max_pending_audio_bytes": 48000,
                "input_wait_seconds": 15.0,
                "utterance_wall_clock_seconds": 120.0,
                "slow_consumer_seconds": 2.0
              },
              "output_format": {"type": "pcm16", "sample_rate": 24000, "channels": 1}
            }
            """)
        )

        let started = try XCTUnwrap(TTSSessionStarted(object: payload))
        XCTAssertEqual(started.requestID, "req-1")
        XCTAssertEqual(started.responseID, "resp-1")
        XCTAssertEqual(started.protocolVersion, 1)
        XCTAssertEqual(started.voiceVariant, "custom_voice")
        XCTAssertEqual(started.sampleRate, 24_000)
        XCTAssertEqual(started.channels, 1)
        XCTAssertEqual(started.limits?.maxAppendCodepoints, 512)
        XCTAssertEqual(started.limits?.maxPendingAudioBytes, 48_000)
        XCTAssertEqual(started.limits?.slowConsumerSeconds, 2.0)
    }

    func testTextAcceptedUsesAppendSequenceNotTransportSequence() throws {
        let payload = try XCTUnwrap(
            jsonObject("""
            {
              "type": "speechrail.tts.text_accepted",
              "request_id": "req-1",
              "response_id": "resp-1",
              "append_sequence": 2,
              "accepted_codepoints": 7,
              "total_codepoints": 19,
              "sequence": 41
            }
            """)
        )

        let accepted = try XCTUnwrap(TTSTextAccepted(object: payload))
        XCTAssertEqual(accepted.appendSequence, 2)
        XCTAssertEqual(accepted.acceptedCodepoints, 7)
        XCTAssertEqual(accepted.totalCodepoints, 19)
        XCTAssertEqual(payload["sequence"] as? Int, 41, "传输层序号是另一个字段，不许混用")
    }

    func testAudioPositionNamespacesChunkIndexAndSampleOffset() throws {
        let speechrail = try XCTUnwrap(
            jsonObject(#"{"kind":"tts","chunk_index":3,"sample_offset":4800,"sample_rate":24000,"channels":1}"#)
        )
        let position = try XCTUnwrap(TTSAudioPosition(speechrail: speechrail))

        XCTAssertEqual(position.chunkIndex, 3)
        XCTAssertEqual(position.sampleOffset, 4_800)
        XCTAssertEqual(position.nextSampleOffset(pcmBytes: 960), 5_280)
        XCTAssertNil(TTSAudioPosition(speechrail: jsonObject(#"{"kind":"tts","chunk_index":0}"#)))
    }

    func testClientStreamsTextAndDropsMisplacedAudio() async throws {
        let transport = TTSStreamTransport()
        let client = RealtimeASRClient(voice: "serena", apiKey: "", callerTTSEnabled: true)
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        let configured = await events.next()
        guard case .configured = configured?.payload else {
            return XCTFail("expected configured, got \(String(describing: configured?.payload))")
        }

        try await client.startTTSStream(requestID: "req-1")
        let startText = await transport.lastSentPayload()
        let startPayload = try XCTUnwrap(jsonObject(startText))
        XCTAssertEqual(startPayload["type"] as? String, "speechrail.tts.start")
        XCTAssertEqual(startPayload["voice"] as? String, "serena")

        await transport.enqueue(.text(text(jsonObject("""
        {
          "type": "speechrail.tts.started",
          "request_id": "req-1",
          "response_id": "resp-1",
          "protocol_version": 1,
          "limits": {
            "max_append_codepoints": 512, "max_total_codepoints": 4096,
            "max_pending_codepoints": 2048, "max_pending_audio_bytes": 48000,
            "input_wait_seconds": 15.0, "utterance_wall_clock_seconds": 120.0,
            "slow_consumer_seconds": 2.0
          },
          "output_format": {"type": "pcm16", "sample_rate": 24000, "channels": 1}
        }
        """))))

        let started = await events.next()
        guard case .ttsStarted(let startedRequest, let startedResponse, let limits) = started?.payload else {
            return XCTFail("expected started, got \(String(describing: started?.payload))")
        }
        XCTAssertEqual(startedRequest, "req-1")
        XCTAssertEqual(startedResponse, "resp-1")
        XCTAssertEqual(limits?.maxAppendCodepoints, 512)

        try await client.appendTTSText("你好。", sequence: 0)
        let appendText = await transport.lastSentPayload()
        let appendPayload = try XCTUnwrap(jsonObject(appendText))
        XCTAssertEqual(appendPayload["type"] as? String, "speechrail.tts.append_text")
        XCTAssertEqual(appendPayload["sequence"] as? Int, 0)
        XCTAssertEqual(appendPayload["response_id"] as? String, "resp-1")

        await transport.enqueue(.text(text(jsonObject("""
        {
          "type": "speechrail.tts.text_accepted",
          "request_id": "req-1",
          "response_id": "resp-1",
          "append_sequence": 0,
          "accepted_codepoints": 3,
          "total_codepoints": 3
        }
        """))))
        let accepted = await events.next()
        guard case .ttsTextAccepted(_, _, let appendSequence, let totalCodepoints) = accepted?.payload else {
            return XCTFail("expected text_accepted, got \(String(describing: accepted?.payload))")
        }
        XCTAssertEqual(appendSequence, 0)
        XCTAssertEqual(totalCodepoints, 3)

        await transport.enqueue(.text(text(audioDelta(responseID: "resp-1", pcm: Data([1, 2]), chunkIndex: 0, sampleOffset: 0))))
        let audio = await events.next()
        guard case .responseAudio(let audioRequest, let audioResponse, let pcm) = audio?.payload else {
            return XCTFail("expected audio, got \(String(describing: audio?.payload))")
        }
        XCTAssertEqual(audioRequest, "req-1")
        XCTAssertEqual(audioResponse, "resp-1")
        XCTAssertEqual(pcm, Data([1, 2]))

        // 乱序块 + 奇数字节 + 旧 response：三种都必须被丢掉。
        await transport.enqueue(.text(text(audioDelta(responseID: "resp-1", pcm: Data([3, 4]), chunkIndex: 5, sampleOffset: 99))))
        await transport.enqueue(.text(text(audioDelta(responseID: "resp-1", pcm: Data([5, 6, 7]), chunkIndex: 1, sampleOffset: 1))))
        await transport.enqueue(.text(text(audioDelta(responseID: "resp-old", pcm: Data([8, 9]), chunkIndex: 1, sampleOffset: 1))))
        await transport.enqueue(.text(#"{"type":"input_audio_buffer.speech_started"}"#))

        let marker = await events.next()
        guard case .speechStarted = marker?.payload else {
            return XCTFail("错位音频不该进播放层，got \(String(describing: marker?.payload))")
        }
        // 旧 response 的块属于"静默隔离"，不计入本轮的畸形计数；本轮真正畸形的有两块。
        let dropped = await client.droppedAudioChunks
        XCTAssertEqual(dropped, 2)

        // 补齐正确的下一块后，序号继续推进。
        await transport.enqueue(.text(text(audioDelta(responseID: "resp-1", pcm: Data([10, 11]), chunkIndex: 1, sampleOffset: 1))))
        await transport.enqueue(.text(text(finishedDone(requestID: "req-1", responseID: "resp-1"))))
        try await client.finishTTSText(lastSequence: 0)

        let followUp = await events.next()
        guard case .responseAudio(_, _, let secondPCM) = followUp?.payload else {
            return XCTFail("expected audio, got \(String(describing: followUp?.payload))")
        }
        XCTAssertEqual(secondPCM, Data([10, 11]))

        let done = await events.next()
        guard case .responseDone(let requestID, let responseID, let status, _) = done?.payload else {
            return XCTFail("expected response.done, got \(String(describing: done?.payload))")
        }
        XCTAssertEqual(requestID, "req-1")
        XCTAssertEqual(responseID, "resp-1")
        XCTAssertEqual(status, "completed")
        await client.close()
    }

    // MARK: - helpers

    private func jsonObject(_ source: String?) -> [String: Any]? {
        guard let source else { return nil }
        guard let data = source.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func text(_ object: [String: Any]?) -> String {
        guard let object, let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func audioDelta(responseID: String, pcm: Data, chunkIndex: Int, sampleOffset: Int) -> [String: Any] {
        [
            "type": "response.output_audio.delta",
            "response_id": responseID,
            "delta": pcm.base64EncodedString(),
            "speechrail": [
                "kind": "tts",
                "chunk_index": chunkIndex,
                "sample_offset": sampleOffset,
                "sample_rate": 24_000,
                "channels": 1
            ]
        ]
    }

    private func finishedDone(requestID: String, responseID: String) -> [String: Any] {
        [
            "type": "response.done",
            "response": ["id": responseID, "status": "completed"],
            "speechrail": [
                "kind": "tts",
                "orchestration": "caller",
                "request_id": requestID
            ]
        ]
    }
}

private actor TTSStreamTransport: RealtimeASRTransport {
    private enum TestError: Error { case closed }

    private var frames: [RealtimeASRSocketFrame] = []
    private var receiver: CheckedContinuation<RealtimeASRSocketFrame, Error>?
    private var sent: [String] = []
    private var closed = false

    func resume() async {}

    func send(_ text: String) async throws {
        sent.append(text)
        if text.contains("transcription_session.update") {
            enqueue(.text(#"{"type":"transcription_session.updated"}"#))
        }
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

    func lastSentPayload() -> String? { sent.last }
}
