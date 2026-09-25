import XCTest
@testable import SpeechRailControlKit
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 增量 TTS 的线上形状测试：DTO 字段与服务端 §3.3.1 对齐，
/// 客户端只把**身份匹配、序号连续、偶数字节**的音频块交给上层。
final class RealtimeTTSStreamTests: XCTestCase {
    func testStartAppendFinishUseTheContractFieldNames() {
        let start = SpeechRailTTSStart(
            requestID: "caller-turn-42",
            task: .conversation,
            voice: "serena",
            speed: 1.0,
            voiceRevision: "vr_1",
            expectedModelRevision: "deadbeef",
            eventID: "evt-tts-1"
        ).jsonObject
        XCTAssertEqual(start["type"] as? String, "speechrail.tts.start")
        XCTAssertEqual(start["event_id"] as? String, "evt-tts-1")
        XCTAssertEqual(start["request_id"] as? String, "caller-turn-42")
        XCTAssertEqual(start["task"] as? String, "conversation")
        XCTAssertEqual(start["voice"] as? String, "serena")
        XCTAssertEqual(start["voice_revision"] as? String, "vr_1")
        XCTAssertEqual(start["expected_model_revision"] as? String, "deadbeef")
        XCTAssertNil(start["limits"], "没要求收紧限额时不该带 limits")
        XCTAssertNil(start["response_id"], "旧 response 身份已移除")

        let append = SpeechRailTTSAppendText(
            requestID: "caller-turn-42",
            sequence: 3,
            text: "这是调用方已经稳定的一小段文本。",
            eventID: "evt-tts-2"
        ).jsonObject
        XCTAssertEqual(append["type"] as? String, "speechrail.tts.append_text")
        XCTAssertEqual(append["event_id"] as? String, "evt-tts-2")
        XCTAssertEqual(append["sequence"] as? Int, 3)
        XCTAssertNil(append["response_id"])

        let finish = SpeechRailTTSFinishText(
            requestID: "caller-turn-42",
            lastSequence: 3,
            eventID: "evt-tts-3"
        ).jsonObject
        XCTAssertEqual(finish["type"] as? String, "speechrail.tts.finish_text")
        XCTAssertEqual(finish["last_sequence"] as? Int, 3)
        XCTAssertEqual(finish["event_id"] as? String, "evt-tts-3")
        XCTAssertNil(finish["response_id"])
    }

    func testStartedDecodesLimitsAndOutputFormat() throws {
        let payload = try XCTUnwrap(
            jsonObject("""
            {
              "type": "speechrail.tts.started",
              "request_id": "req-1",
              "task_id": "task-1",
              "plan_id": "plan-1",
              "voice_revision": "vr_1",
              "limits": {
                "max_append_codepoints": 512,
                "max_total_codepoints": 4096,
                "max_pending_codepoints": 2048,
                "max_pending_audio_bytes": 48000,
                "input_wait_seconds": 15.0,
                "utterance_wall_clock_seconds": 120.0,
                "slow_consumer_seconds": 2.0
              },
              "output_format": {"type": "audio/pcm", "sample_rate": 24000, "channels": 1}
            }
            """)
        )

        let started = try XCTUnwrap(TTSSessionStarted(object: payload))
        XCTAssertEqual(started.requestID, "req-1")
        XCTAssertEqual(started.taskID, "task-1")
        XCTAssertEqual(started.planID, "plan-1")
        XCTAssertEqual(started.voiceRevision, "vr_1")
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
        let payload = try XCTUnwrap(
            jsonObject(#"{"type":"speechrail.tts.audio.delta","chunk_index":3,"sample_offset":4800}"#)
        )
        let position = try XCTUnwrap(TTSAudioPosition(object: payload))

        XCTAssertEqual(position.chunkIndex, 3)
        XCTAssertEqual(position.sampleOffset, 4_800)
        XCTAssertEqual(position.nextSampleOffset(pcmBytes: 960), 5_280)
        XCTAssertNil(TTSAudioPosition(object: jsonObject(#"{"chunk_index":0}"#) ?? [:]))
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
        let sentStart = await transport.lastSentPayload()
        let startPayload = try XCTUnwrap(jsonObject(sentStart))
        XCTAssertEqual(startPayload["type"] as? String, "speechrail.tts.start")
        XCTAssertEqual(startPayload["voice"] as? String, "serena")
        XCTAssertEqual(startPayload["task"] as? String, "conversation")
        XCTAssertNotNil(startPayload["event_id"])

        await transport.enqueue(.text(text(started(requestID: "req-1"))))

        let startedEvent = await events.next()
        guard case .ttsStarted(let startedRequest, let startedTask, let limits) = startedEvent?.payload else {
            return XCTFail("expected started, got \(String(describing: startedEvent?.payload))")
        }
        XCTAssertEqual(startedRequest, "req-1")
        XCTAssertEqual(startedTask, "task-1")
        XCTAssertEqual(limits?.maxAppendCodepoints, 512)

        try await client.appendTTSText("你好。", sequence: 0)
        let sentAppend = await transport.lastSentPayload()
        let appendPayload = try XCTUnwrap(jsonObject(sentAppend))
        XCTAssertEqual(appendPayload["type"] as? String, "speechrail.tts.append_text")
        XCTAssertEqual(appendPayload["sequence"] as? Int, 0)
        XCTAssertNotNil(appendPayload["event_id"])

        await transport.enqueue(
            .text(text(accepted(requestID: "req-1", appendSequence: 0, totalCodepoints: 3)))
        )
        let acceptedEvent = await events.next()
        guard case .ttsTextAccepted(_, _, let appendSequence, let totalCodepoints) = acceptedEvent?.payload else {
            return XCTFail("expected text_accepted, got \(String(describing: acceptedEvent?.payload))")
        }
        XCTAssertEqual(appendSequence, 0)
        XCTAssertEqual(totalCodepoints, 3)

        await transport.enqueue(
            .text(text(audioDelta(requestID: "req-1", pcm: Data([1, 2]), chunkIndex: 0, sampleOffset: 0)))
        )
        let audio = await events.next()
        guard case .ttsAudio(let audioRequest, let audioTask, let pcm) = audio?.payload else {
            return XCTFail("expected audio, got \(String(describing: audio?.payload))")
        }
        XCTAssertEqual(audioRequest, "req-1")
        XCTAssertEqual(audioTask, "task-1")
        XCTAssertEqual(pcm, Data([1, 2]))

        // 乱序块 + 奇数字节 + 旧 request：三种都必须被丢掉。
        await transport.enqueue(.text(text(audioDelta(requestID: "req-1", pcm: Data([3, 4]), chunkIndex: 5, sampleOffset: 99))))
        await transport.enqueue(.text(text(audioDelta(requestID: "req-1", pcm: Data([5, 6, 7]), chunkIndex: 1, sampleOffset: 1))))
        await transport.enqueue(.text(text(audioDelta(requestID: "req-old", pcm: Data([8, 9]), chunkIndex: 1, sampleOffset: 1))))
        await transport.enqueue(
            .text(text(accepted(requestID: "req-1", appendSequence: 1, totalCodepoints: 5)))
        )

        let marker = await events.next()
        guard case .ttsTextAccepted = marker?.payload else {
            return XCTFail("错位音频不该进播放层，got \(String(describing: marker?.payload))")
        }
        // 旧 request 的块属于"静默隔离"，不计入本轮的畸形计数；本轮真正畸形的有两块。
        let dropped = await client.droppedAudioChunks
        XCTAssertEqual(dropped, 2)

        // 补齐正确的下一块后，序号继续推进。
        await transport.enqueue(.text(text(audioDelta(requestID: "req-1", pcm: Data([10, 11]), chunkIndex: 1, sampleOffset: 1))))
        await transport.enqueue(.text(text(completed(requestID: "req-1"))))
        try await client.finishTTSText(lastSequence: 1)

        let followUp = await events.next()
        guard case .ttsAudio(_, _, let secondPCM) = followUp?.payload else {
            return XCTFail("expected audio, got \(String(describing: followUp?.payload))")
        }
        XCTAssertEqual(secondPCM, Data([10, 11]))

        let done = await events.next()
        guard case .ttsEnded(let requestID, let taskID, let status, _, _) = done?.payload else {
            return XCTFail("expected tts terminal, got \(String(describing: done?.payload))")
        }
        XCTAssertEqual(requestID, "req-1")
        XCTAssertEqual(taskID, "task-1")
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

    private func started(requestID: String) -> [String: Any] {
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

    private func accepted(
        requestID: String,
        appendSequence: Int,
        totalCodepoints: Int
    ) -> [String: Any] {
        [
            "type": "speechrail.tts.text_accepted",
            "task_id": "task-1",
            "request_id": requestID,
            "append_sequence": appendSequence,
            "accepted_codepoints": max(1, totalCodepoints),
            "total_codepoints": max(1, totalCodepoints)
        ]
    }

    private func audioDelta(
        requestID: String,
        pcm: Data,
        chunkIndex: Int,
        sampleOffset: Int
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

    private func completed(requestID: String) -> [String: Any] {
        [
            "type": "speechrail.tts.completed",
            "task_id": "task-1",
            "request_id": requestID,
            "generated_samples": 2
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
        if text.contains("\"type\":\"session.update\"") {
            enqueue(.text(#"{"type":"session.updated"}"#))
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
