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
            validator.accept(RealtimeEventMetadata(eventID: "e1", sessionID: "s1", sequence: 0)),
            .first
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e2", sessionID: "s1", sequence: 2)),
            .gap(expected: 1, received: 2)
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e3", sessionID: "s1", sequence: 1)),
            .regression(last: 2, received: 1)
        )
    }

    func testSequenceValidatorReportsMissingAndSessionChange() {
        var validator = RealtimeSequenceValidator()

        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e1", sessionID: "s1", sequence: 0)),
            .first
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e2", sessionID: "s1")),
            .missing
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e3", sessionID: "s2", sequence: 1)),
            .sessionChanged(expected: "s1", received: "s2")
        )
        XCTAssertEqual(validator.sessionID, "s1", "被拒绝的新 session 不得覆盖连接身份")
    }

    func testSequenceValidatorRejectsMissingIdentityAndNonzeroInitialSequence() {
        var validator = RealtimeSequenceValidator()

        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(sessionID: "s1", sequence: 0)),
            .missing,
            "基础事件缺 event_id 时必须拒绝"
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e1", sequence: 0)),
            .missing,
            "基础事件缺 session_id 时必须拒绝"
        )
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e2", sessionID: "s1", sequence: 1)),
            .gap(expected: 0, received: 1),
            "首个服务事件必须使用 sequence 0"
        )
        XCTAssertNil(validator.sessionID, "无效首个事件不得绑定 session")
        XCTAssertNil(validator.lastSequence, "无效首个事件不得推进 sequence")
    }

    func testSequenceValidatorRejectsDuplicateEventID() {
        var validator = RealtimeSequenceValidator()
        XCTAssertEqual(
            validator.accept(RealtimeEventMetadata(eventID: "e1", sessionID: "s1", sequence: 0)),
            .first
        )

        let duplicate = validator.accept(
            RealtimeEventMetadata(eventID: "e1", sessionID: "s1", sequence: 1)
        )
        XCTAssertFalse(
            duplicate == .first || duplicate == .contiguous,
            "重复 event_id 不能进入业务事件流"
        )
        XCTAssertEqual(validator.lastSequence, 0, "重复事件不得推进 sequence")
    }

    func testRealtimeEventStreamDiscardsOverflowedQueueAndPreservesTerminal() async {
        let stream = RealtimeEventStream<Int>(
            limits: .init(maxBufferedEvents: 1, maxBufferedAudioBytes: 4)
        )
        let first = RealtimeEventEnvelope(metadata: RealtimeEventMetadata(), payload: 1)
        let overflow = RealtimeEventEnvelope(metadata: RealtimeEventMetadata(), payload: 2)

        let firstResult = await stream.yield(first)
        let overflowResult = await stream.yield(overflow)
        XCTAssertEqual(firstResult, .enqueued)
        XCTAssertEqual(overflowResult, .overflow)

        let terminal = RealtimeEventEnvelope(metadata: RealtimeEventMetadata(), payload: 99)
        await stream.finish(terminalEvents: [terminal], discardPending: true)
        var iterator = stream.makeAsyncIterator()
        let delivered = await iterator.next()
        let ended = await iterator.next()
        XCTAssertEqual(delivered?.payload, 99)
        XCTAssertNil(ended)
    }

    func testRealtimeEventStreamReleasesDecodedAudioBudgetWhenConsumed() async {
        let stream = RealtimeEventStream<Int>(
            limits: .init(maxBufferedEvents: 3, maxBufferedAudioBytes: 4)
        )
        let first = RealtimeEventEnvelope(metadata: RealtimeEventMetadata(), payload: 1)
        let blocked = RealtimeEventEnvelope(metadata: RealtimeEventMetadata(), payload: 2)
        let next = RealtimeEventEnvelope(metadata: RealtimeEventMetadata(), payload: 3)

        let firstResult = await stream.yield(first, decodedAudioBytes: 3)
        let blockedResult = await stream.yield(blocked, decodedAudioBytes: 2)
        XCTAssertEqual(firstResult, .enqueued)
        XCTAssertEqual(blockedResult, .overflow)

        var iterator = stream.makeAsyncIterator()
        let consumed = await iterator.next()
        XCTAssertEqual(consumed?.payload, 1)
        let nextResult = await stream.yield(next, decodedAudioBytes: 2)
        XCTAssertEqual(nextResult, .enqueued)

        await stream.finish()
        let buffered = await iterator.next()
        let ended = await iterator.next()
        XCTAssertEqual(buffered?.payload, 3)
        XCTAssertNil(ended)
    }

    #if SWIFT_PACKAGE
    func testRealtimeItemStateValidatesUnicodeSpansAndMergesSameRevisionShards() {
        let clock = ContinuousClock()
        let now = clock.now
        let generation = UUID()
        var state = RealtimeEventState()
        state.reset(generation: generation, auxiliaryExpected: true)
        let transcript = "A🦜e\u{301}"
        XCTAssertEqual(transcript.unicodeScalars.count, 4)
        XCTAssertTrue(
            state.complete(
                itemID: "item-1",
                transcript: transcript,
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )

        let invalidSpan = RealtimeEventState.Range(start: 0, end: 5)
        let firstUnit = RealtimeASRClient.AttributionUnit(
            segmentUID: "segment-1",
            textStart: 1,
            textEnd: 3,
            audioStartSample: 0,
            audioEndSample: 4,
            timingQuality: "aligned",
            granularity: "word"
        )
        XCTAssertFalse(
            state.applyAlignment(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 17,
                metadataRevision: 1,
                sampleSpan: .init(start: 0, end: 8),
                codepointSpan: invalidSpan,
                units: [firstUnit],
                sessionID: "session-1",
                generation: generation,
                now: now
            ),
            "UTF-16/Character lengths must not admit an out-of-range codepoint span"
        )

        let fullSpan = RealtimeEventState.Range(start: 0, end: 4)
        XCTAssertTrue(
            state.applyAlignment(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 17,
                metadataRevision: 1,
                sampleSpan: .init(start: 0, end: 8),
                codepointSpan: fullSpan,
                units: [firstUnit],
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        let secondUnit = RealtimeASRClient.AttributionUnit(
            segmentUID: "segment-2",
            textStart: 3,
            textEnd: 4,
            audioStartSample: 4,
            audioEndSample: 8,
            timingQuality: "aligned",
            granularity: "character"
        )
        XCTAssertTrue(
            state.applyAlignment(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 17,
                metadataRevision: 1,
                sampleSpan: .init(start: 0, end: 8),
                codepointSpan: fullSpan,
                units: [secondUnit],
                sessionID: "session-1",
                generation: generation,
                now: now
            ),
            "multiple chunks sharing one metadata revision must accumulate"
        )
        XCTAssertEqual(state.snapshot(itemID: "item-1")?.alignmentUnits.map(\.segmentUID), [
            "segment-1", "segment-2"
        ])
        XCTAssertFalse(
            state.applyAlignment(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 16,
                metadataRevision: 2,
                sampleSpan: .init(start: 0, end: 8),
                codepointSpan: fullSpan,
                units: [secondUnit],
                sessionID: "session-1",
                generation: generation,
                now: now
            ),
            "stale transcript revision must not replace current alignment"
        )
        XCTAssertFalse(
            state.applyAlignment(
                itemID: "item-1",
                taskID: "old-task",
                epoch: 0,
                transcriptRevision: 17,
                metadataRevision: 2,
                sampleSpan: .init(start: 0, end: 8),
                codepointSpan: fullSpan,
                units: [secondUnit],
                sessionID: "session-1",
                generation: generation,
                now: now
            ),
            "a stale task must not alter the current item"
        )
        let firstSpeakerSpan = RealtimeASRClient.DiarizationSpan(
            speaker: "speaker_1",
            startSample: 0,
            endSample: 4
        )
        let secondSpeakerSpan = RealtimeASRClient.DiarizationSpan(
            speaker: "speaker_2",
            startSample: 4,
            endSample: 8
        )
        XCTAssertFalse(
            state.applyDiarization(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 16,
                metadataRevision: 3,
                spans: [firstSpeakerSpan],
                sessionID: "session-1",
                generation: generation,
                now: now
            ),
            "diarization from a different transcript revision must not mix with alignment"
        )
        XCTAssertTrue(
            state.applyDiarization(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 17,
                metadataRevision: 3,
                spans: [firstSpeakerSpan],
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertTrue(
            state.applyDiarization(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 17,
                metadataRevision: 3,
                spans: [secondSpeakerSpan],
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertEqual(state.snapshot(itemID: "item-1")?.diarizationSpans.count, 2)
        XCTAssertFalse(
            state.applyDiarization(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 17,
                metadataRevision: 2,
                spans: [firstSpeakerSpan],
                sessionID: "session-1",
                generation: generation,
                now: now
            ),
            "older diarization metadata revisions must be ignored independently"
        )

        var reverse = RealtimeEventState()
        reverse.reset(generation: generation, auxiliaryExpected: true)
        XCTAssertTrue(
            reverse.complete(
                itemID: "item-2",
                transcript: transcript,
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertTrue(
            reverse.applyDiarization(
                itemID: "item-2",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 17,
                metadataRevision: 1,
                spans: [firstSpeakerSpan],
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertFalse(
            reverse.applyAlignment(
                itemID: "item-2",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 16,
                metadataRevision: 1,
                sampleSpan: .init(start: 0, end: 8),
                codepointSpan: fullSpan,
                units: [firstUnit],
                sessionID: "session-1",
                generation: generation,
                now: now
            ),
            "alignment from a different transcript revision must not mix with diarization"
        )
        XCTAssertTrue(
            state.acceptSessionEvent(
                taskID: "task-1",
                epoch: 1,
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertFalse(
            state.applyDiarization(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 17,
                metadataRevision: 4,
                spans: [],
                sessionID: "session-1",
                generation: generation,
                now: now
            ),
            "late results from an earlier epoch must not modify retained items"
        )
    }

    func testRealtimeItemStateBoundsTranscriptBytesAndRejectsOversizedUpdates() {
        let clock = ContinuousClock()
        let now = clock.now
        let generation = UUID()
        let maximumTranscriptBytes = 64 * 1024
        var state = RealtimeEventState()
        state.reset(generation: generation, auxiliaryExpected: true)
        let oversizedTranscript = String(repeating: "x", count: maximumTranscriptBytes + 1)

        XCTAssertFalse(
            state.complete(
                itemID: "oversized-final",
                transcript: oversizedTranscript,
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertEqual(state.takeLimitViolation(), .transcript)
        XCTAssertNil(state.snapshot(itemID: "oversized-final"))

        XCTAssertTrue(
            state.observeDelta(
                itemID: "delta-overflow",
                delta: String(repeating: "x", count: maximumTranscriptBytes),
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertFalse(
            state.observeDelta(
                itemID: "delta-overflow",
                delta: "5",
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertEqual(state.takeLimitViolation(), .transcript)
        XCTAssertEqual(
            state.snapshot(itemID: "delta-overflow")?.transcript?.utf8.count,
            maximumTranscriptBytes
        )

        XCTAssertFalse(
            state.acceptHypothesis(
                itemID: "oversized-hypothesis",
                taskID: "task-1",
                epoch: 0,
                revision: 1,
                text: oversizedTranscript,
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertEqual(state.takeLimitViolation(), .transcript)
        XCTAssertNil(state.snapshot(itemID: "oversized-hypothesis"))
    }

    func testRealtimeItemStateBoundsCumulativeAlignmentCountAndBytes() {
        let clock = ContinuousClock()
        let now = clock.now
        let generation = UUID()
        let maximumUnits = 1_024
        var state = RealtimeEventState()
        state.reset(generation: generation, auxiliaryExpected: true)
        XCTAssertTrue(
            state.complete(
                itemID: "alignment-count",
                transcript: "x",
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )

        func unitWithID(_ id: String) -> RealtimeASRClient.AttributionUnit {
            RealtimeASRClient.AttributionUnit(
                segmentUID: id,
                textStart: 0,
                textEnd: 1,
                audioStartSample: 0,
                audioEndSample: 1,
                timingQuality: "aligned",
                granularity: "character"
            )
        }
        func unit(_ index: Int) -> RealtimeASRClient.AttributionUnit {
            unitWithID("segment-\(index)")
        }
        func applyAlignment(
            _ units: [RealtimeASRClient.AttributionUnit],
            state: inout RealtimeEventState
        ) -> Bool {
            state.applyAlignment(
                itemID: "alignment-count",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 1,
                metadataRevision: 1,
                sampleSpan: .init(start: 0, end: 1),
                codepointSpan: .init(start: 0, end: 1),
                units: units,
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        }

        XCTAssertTrue(applyAlignment((0..<512).map(unit), state: &state))
        XCTAssertFalse(
            applyAlignment((512..<(maximumUnits + 1)).map(unit), state: &state)
        )
        XCTAssertEqual(state.takeLimitViolation(), .alignment)
        XCTAssertEqual(
            state.snapshot(itemID: "alignment-count")?.alignmentUnits.count,
            512,
            "an over-budget shard must be rejected atomically"
        )

        var byteBounded = RealtimeEventState()
        byteBounded.reset(generation: generation, auxiliaryExpected: true)
        XCTAssertTrue(
            byteBounded.complete(
                itemID: "alignment-bytes",
                transcript: "x",
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        let oversizedSegmentID = String(repeating: "u", count: 300 * 1024)
        XCTAssertFalse(
            byteBounded.applyAlignment(
                itemID: "alignment-bytes",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 1,
                metadataRevision: 1,
                sampleSpan: .init(start: 0, end: 1),
                codepointSpan: .init(start: 0, end: 1),
                units: [unitWithID(oversizedSegmentID)],
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertEqual(byteBounded.takeLimitViolation(), .alignment)
        XCTAssertTrue(byteBounded.snapshot(itemID: "alignment-bytes")?.alignmentUnits.isEmpty == true)
    }

    func testRealtimeItemStateBoundsCumulativeDiarizationCountAndBytes() {
        let clock = ContinuousClock()
        let now = clock.now
        let generation = UUID()
        let maximumSpans = 1_024
        var state = RealtimeEventState()
        state.reset(generation: generation, auxiliaryExpected: true)
        XCTAssertTrue(
            state.complete(
                itemID: "diarization-count",
                transcript: "x",
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )

        func applyDiarization(
            _ spans: [RealtimeASRClient.DiarizationSpan],
            state: inout RealtimeEventState
        ) -> Bool {
            state.applyDiarization(
                itemID: "diarization-count",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 1,
                metadataRevision: 1,
                spans: spans,
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        }

        let firstShard = (0..<512).map {
            RealtimeASRClient.DiarizationSpan(
                speaker: "speaker-\($0)",
                startSample: $0,
                endSample: $0 + 1
            )
        }
        let secondShard = (512..<(maximumSpans + 1)).map {
            RealtimeASRClient.DiarizationSpan(
                speaker: "speaker-\($0)",
                startSample: $0,
                endSample: $0 + 1
            )
        }
        XCTAssertTrue(applyDiarization(firstShard, state: &state))
        XCTAssertFalse(applyDiarization(secondShard, state: &state))
        XCTAssertEqual(state.takeLimitViolation(), .diarization)
        XCTAssertEqual(
            state.snapshot(itemID: "diarization-count")?.diarizationSpans.count,
            512,
            "an over-budget shard must be rejected atomically"
        )

        var byteBounded = RealtimeEventState()
        byteBounded.reset(generation: generation, auxiliaryExpected: true)
        XCTAssertTrue(
            byteBounded.complete(
                itemID: "diarization-bytes",
                transcript: "x",
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        let oversizedSpeaker = String(repeating: "s", count: 300 * 1024)
        XCTAssertFalse(
            byteBounded.applyDiarization(
                itemID: "diarization-bytes",
                taskID: "task-1",
                epoch: 0,
                transcriptRevision: 1,
                metadataRevision: 1,
                spans: [.init(speaker: oversizedSpeaker, startSample: 0, endSample: 1)],
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )
        XCTAssertEqual(byteBounded.takeLimitViolation(), .diarization)
        XCTAssertTrue(byteBounded.snapshot(itemID: "diarization-bytes")?.diarizationSpans.isEmpty == true)
    }

    func testRealtimeItemStateExpiresAfterThirtySecondsAndCapsAt128Items() {
        let clock = ContinuousClock()
        let now = clock.now
        let generation = UUID()
        var timed = RealtimeEventState()
        timed.reset(generation: generation, auxiliaryExpected: true)
        XCTAssertTrue(
            timed.complete(
                itemID: "expired-item",
                transcript: "保留正文",
                sessionID: "session-1",
                generation: generation,
                now: now
            )
        )

        timed.prune(now: now.advanced(by: .seconds(31)))
        let expired = timed.takeExpired()
        XCTAssertEqual(expired.map(\.itemID), ["expired-item"])
        XCTAssertEqual(expired.first?.snapshot.transcript, "保留正文")
        XCTAssertFalse(
            timed.observeDelta(
                itemID: "expired-item",
                delta: "迟到",
                sessionID: "session-1",
                generation: generation,
                now: now.advanced(by: .seconds(32))
            ),
            "retired item IDs must not recreate an expired metadata entry"
        )

        var bounded = RealtimeEventState()
        bounded.reset(generation: generation, auxiliaryExpected: true)
        for index in 0...RealtimeEventState.maxItems {
            XCTAssertTrue(
                bounded.complete(
                    itemID: "item-\(index)",
                    transcript: "text",
                    sessionID: "session-1",
                    generation: generation,
                    now: now
                )
            )
        }
        XCTAssertNil(bounded.snapshot(itemID: "item-0"))
        XCTAssertNotNil(bounded.snapshot(itemID: "item-\(RealtimeEventState.maxItems)"))
        XCTAssertEqual(bounded.takeExpired().first?.itemID, "item-0")
    }
    #endif

    func testClientClosesBeforeDeliveringEventAfterSequenceGap() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(apiKey: "")
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        guard let configured = await events.next() else {
            XCTFail("Expected the fake server configuration acknowledgement")
            return
        }
        guard case .configured = configured.payload else {
            XCTFail("Expected configured before sending the gap event")
            return
        }

        await transport.enqueueRaw(
            .text(
                #"{"type":"conversation.item.input_audio_transcription.delta","event_id":"gap-event","session_id":"test-session","sequence":2,"item_id":"utt-1","delta":"must not be delivered"}"#
            )
        )

        guard let failure = await events.next() else {
            XCTFail("Expected a client protocol error")
            await client.close()
            return
        }
        guard case .serverError(let code, _, _) = failure.payload else {
            XCTFail("Gap event reached the business stream: \(failure.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(code, "realtime_protocol_violation")
        let acceptedSessionID = await client.serverSessionID
        XCTAssertEqual(acceptedSessionID, "test-session")

        guard let closed = await events.next() else {
            XCTFail("Expected an independent close notification")
            return
        }
        guard case .closed = closed.payload else {
            XCTFail("Expected closed after protocol failure, got \(closed.payload)")
            return
        }
    }

    func testClientClosesWithExplicitErrorForOversizedTranscript() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(apiKey: "")
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        guard let configured = await events.next() else {
            XCTFail("Expected the fake server configuration acknowledgement")
            return
        }
        guard case .configured = configured.payload else {
            XCTFail("Expected configured before sending the oversized transcript")
            return
        }

        await transport.enqueue(
            .text(
                jsonText([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "utt-1",
                    "transcript": String(
                        repeating: "x",
                        count: RealtimeEventState.maxTranscriptUTF8Bytes + 1
                    ),
                ])
            )
        )

        guard let failure = await events.next() else {
            XCTFail("Expected an explicit local item-state limit error")
            await client.close()
            return
        }
        guard case .serverError(let code, _, _) = failure.payload else {
            XCTFail("Oversized transcript reached the business stream: \(failure.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(code, "realtime_item_state_overflow")

        guard let closed = await events.next() else {
            XCTFail("Expected an independent close notification")
            return
        }
        guard case .closed = closed.payload else {
            XCTFail("Expected closed after item-state overflow, got \(closed.payload)")
            return
        }
    }

    func testClientClosesAndReportsOverflowOutsideTheBoundedQueue() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(
            voice: "serena",
            apiKey: "",
            callerTTSEnabled: true,
            eventStreamLimits: .init(maxBufferedEvents: 4, maxBufferedAudioBytes: 1)
        )
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        guard let configured = await events.next(),
              case .configured = configured.payload else {
            XCTFail("Expected the fake server configuration acknowledgement")
            return
        }

        try await client.startTTSStream(requestID: "overflow-request")
        await transport.enqueue(.text(jsonText(ttsStarted(requestID: "overflow-request"))))
        guard let started = await events.next(),
              case .ttsStarted(let requestID, _, _) = started.payload else {
            XCTFail("Expected the active TTS request before sending audio")
            await client.close()
            return
        }
        XCTAssertEqual(requestID, "overflow-request")

        await transport.enqueue(
            .text(
                jsonText(
                    ttsAudioDelta(
                        requestID: "overflow-request",
                        chunkIndex: 0,
                        sampleOffset: 0,
                        pcm: Data([1, 2])
                    )
                )
            )
        )

        guard let failure = await events.next() else {
            XCTFail("Expected an out-of-band overflow terminal")
            return
        }
        guard case .serverError(let code, _, _) = failure.payload else {
            XCTFail("Expected overflow error, got \(failure.payload)")
            return
        }
        XCTAssertEqual(code, "realtime_event_stream_overflow")

        guard let closed = await events.next(),
              case .closed = closed.payload else {
            XCTFail("Expected close notification after overflow")
            return
        }
        let transportClosed = await transport.isClosed()
        XCTAssertTrue(transportClosed, "overflow must cancel the WebSocket transport")
    }

    func testClientDropsStaleAndOutOfRangeAlignmentButMergesCurrentShards() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(diarizationEnabled: true, apiKey: "")
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        guard let configured = await events.next(),
              case .configured = configured.payload else {
            XCTFail("Expected the fake server configuration acknowledgement")
            return
        }

        let transcript = "A🦜e\u{301}"
        await transport.enqueue(
            .text(
                jsonText([
                    "type": "speechrail.transcription.hypothesis",
                    "task_id": "task-1",
                    "epoch": 0,
                    "utterance_id": "utterance-1",
                    "revision": 1,
                    "text": transcript,
                    "sample_span": ["start": 0, "end": 8]
                ])
            )
        )
        guard let hypothesis = await events.next(),
              case .partialSnapshot(let hypothesisItemID, _, _, _) = hypothesis.payload else {
            XCTFail("Expected the current task to establish item identity")
            return
        }
        XCTAssertEqual(hypothesisItemID, "utterance-1")

        await transport.enqueue(
            .text(jsonText([
                "type": "conversation.item.input_audio_transcription.completed",
                "item_id": "utterance-1",
                "transcript": transcript
            ]))
        )
        guard let completed = await events.next(),
              case .completed(let itemID, let deliveredText) = completed.payload else {
            XCTFail("Expected the completed Unicode transcript")
            return
        }
        XCTAssertEqual(itemID, "utterance-1")
        XCTAssertEqual(deliveredText, transcript)

        let unitOne: [String: Any] = [
            "segment_uid": "segment-1",
            "text_start": 1,
            "text_end": 3,
            "audio_start_sample": 0,
            "audio_end_sample": 4,
            "timing_quality": "aligned",
            "granularity": "word"
        ]
        let unitTwo: [String: Any] = [
            "segment_uid": "segment-2",
            "text_start": 3,
            "text_end": 4,
            "audio_start_sample": 4,
            "audio_end_sample": 8,
            "timing_quality": "aligned",
            "granularity": "character"
        ]

        await transport.enqueue(
            .text(
                jsonText(
                    alignmentDoneEvent(
                        taskID: "task-1",
                        transcriptRevision: 17,
                        metadataRevision: 2,
                        itemID: "utterance-1",
                        codepointEnd: 5,
                        units: [unitOne]
                    )
                )
            )
        )
        await transport.enqueue(
            .text(
                jsonText(
                    alignmentDoneEvent(
                        taskID: "old-task",
                        transcriptRevision: 17,
                        metadataRevision: 2,
                        itemID: "utterance-1",
                        codepointEnd: 4,
                        units: [unitOne]
                    )
                )
            )
        )
        await transport.enqueue(
            .text(
                jsonText(
                    alignmentDoneEvent(
                        taskID: "task-1",
                        transcriptRevision: 17,
                        metadataRevision: 2,
                        itemID: "utterance-1",
                        codepointEnd: 4,
                        units: [unitOne]
                    )
                )
            )
        )

        guard let firstAlignment = await events.next(),
              case .attribution(_, let firstUnits, _) = firstAlignment.payload else {
            XCTFail("Expected the valid current alignment shard")
            return
        }
        XCTAssertEqual(firstUnits.map { $0.segmentUID }, ["segment-1"])

        await transport.enqueue(
            .text(
                jsonText(
                    alignmentDoneEvent(
                        taskID: "task-1",
                        transcriptRevision: 17,
                        metadataRevision: 2,
                        itemID: "utterance-1",
                        codepointEnd: 4,
                        units: [unitTwo]
                    )
                )
            )
        )
        guard let secondAlignment = await events.next(),
              case .attribution(_, let mergedUnits, _) = secondAlignment.payload else {
            XCTFail("Expected the second shard at the same metadata revision")
            return
        }
        XCTAssertEqual(mergedUnits.map { $0.segmentUID }, ["segment-1", "segment-2"])
        await client.close()
    }

    func testDiarizationDoneEmitsSessionBarrierWithoutCreatingUnknownItem() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(diarizationEnabled: true, apiKey: "")
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        guard let configured = await events.next(),
              case .configured = configured.payload else {
            XCTFail("Expected the fake server configuration acknowledgement")
            return
        }
        try await client.finishDiarization()

        await transport.enqueue(
            .text(
                jsonText([
                    "type": "speechrail.diarization.done",
                    "task_id": "task-1",
                    "epoch": 0,
                    "utterance_id": "unknown-item",
                    "transcript_revision": 0,
                    "metadata_revision": 0,
                    "units": []
                ])
            )
        )

        guard let barrier = await events.next(),
              case .diarizationFinished = barrier.payload else {
            XCTFail("Expected the session finish barrier independently of item state")
            await client.close()
            return
        }
        await client.close()
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

    func testSessionUpdateCarriesLanguageAndKeywordsOnlyWhenConfigured() {
        let configured = SpeechRailSessionUpdate(
            model: RealtimeASRClientModelFixture.canonical,
            language: "zh",
            keywords: ["SpeechRail", "提词器"]
        )
        let transcription = ((configured.jsonObject["session"] as? [String: Any])?["audio"]
            as? [String: Any])?["input"]
            as? [String: Any]
        let configuredTranscription = transcription?["transcription"] as? [String: Any]
        XCTAssertEqual(configuredTranscription?["language"] as? String, "zh")
        XCTAssertEqual(
            configuredTranscription?["keywords"] as? [String],
            ["SpeechRail", "提词器"]
        )

        let bare = SpeechRailSessionUpdate(model: RealtimeASRClientModelFixture.canonical)
        let bareInput = ((bare.jsonObject["session"] as? [String: Any])?["audio"]
            as? [String: Any])?["input"] as? [String: Any]
        let bareTranscription = bareInput?["transcription"] as? [String: Any]
        XCTAssertNil(bareTranscription?["language"], "未配置时不覆盖服务端默认语言")
        XCTAssertNil(bareTranscription?["keywords"], "未配置时不发送空关键词")
    }

    func testClientSendsConfiguredLanguageAndKeywordsBeforeAnyAudio() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(
            language: "zh",
            keywords: ["SpeechRail"],
            apiKey: ""
        )
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        _ = await events.next()

        let sent = await transport.sentMessages()
        let update = try XCTUnwrap(
            sent.compactMap { message -> [String: Any]? in
                guard let data = message.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      payload["type"] as? String == "session.update"
                else { return nil }
                return payload
            }.first
        )
        let transcription = (((update["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"]
            as? [String: Any])?["transcription"] as? [String: Any]
        XCTAssertEqual(transcription?["language"] as? String, "zh")
        XCTAssertEqual(transcription?["keywords"] as? [String], ["SpeechRail"])
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

    func testDrainWaitsForTheTerminalCorrelatedWithItsCommit() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(apiKey: "")
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        _ = await events.next()  // .configured
        try await client.append(Data([0, 0]))

        let drain = Task { try await client.drainAndClear(timeout: .seconds(2)) }
        var commitEventID: String?
        for _ in 0..<100 {
            let sent = await transport.sentMessages()
            if let commit = sent.compactMap({ message -> [String: Any]? in
                let data = Data(message.utf8)
                guard
                    let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                    object["type"] as? String == "input_audio_buffer.commit"
                else { return nil }
                return object
            }).first {
                commitEventID = commit["event_id"] as? String
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let expectedCommitEventID = try XCTUnwrap(commitEventID)

        await transport.enqueue(
            .text(
                jsonText([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "older-item",
                    "transcript": "上一句",
                    "commit_event_id": "unrelated-commit",
                ])
            )
        )
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let afterStale = await sentEventTypes(transport)
        XCTAssertFalse(
            afterStale.contains("input_audio_buffer.clear"),
            "A stale terminal must not satisfy the drain barrier"
        )

        await transport.enqueue(
            .text(
                jsonText([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "tail-item",
                    "transcript": "最后一句",
                    "commit_event_id": expectedCommitEventID,
                ])
            )
        )
        try await drain.value
        let finalTypes = await sentEventTypes(transport)
        XCTAssertTrue(finalTypes.contains("input_audio_buffer.clear"))
        await client.close()
    }

    func testHypothesisSnapshotSuppressesTheSameItemsDelta() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(apiKey: "")
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        _ = await events.next()  // .configured
        await transport.enqueue(
            .text(
                jsonText([
                    "type": "speechrail.transcription.hypothesis",
                    "task_id": "task-1",
                    "epoch": 0,
                    "utterance_id": "item-1",
                    "revision": 1,
                    "text": "你好",
                    "sample_span": ["start": 0, "end": 2400],
                    "stable_prefix_codepoints": 0,
                ])
            )
        )
        await transport.enqueue(
            .text(
                jsonText([
                    "type": "conversation.item.input_audio_transcription.delta",
                    "item_id": "item-1",
                    "delta": "你好",
                ])
            )
        )
        await transport.enqueue(
            .text(
                jsonText([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "item-1",
                    "transcript": "你好",
                ])
            )
        )

        guard let snapshot = await events.next() else {
            XCTFail("Expected a hypothesis snapshot")
            await client.close()
            return
        }
        guard case .partialSnapshot("item-1", 1, "你好", _) = snapshot.payload else {
            XCTFail("Expected a hypothesis snapshot, got \(snapshot.payload)")
            await client.close()
            return
        }
        guard let terminal = await events.next() else {
            XCTFail("Expected the transcription terminal")
            await client.close()
            return
        }
        guard case .completed("item-1", "你好") = terminal.payload else {
            XCTFail("Delta was displayed twice for a snapshot-backed item: \(terminal.payload)")
            await client.close()
            return
        }
        await client.close()
    }

    func testHypothesisProjectsStablePrefixAndSampleSpanWithoutInventingMissingValues() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(apiKey: "")
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        _ = await events.next()  // .configured

        await transport.enqueue(
            .text(
                jsonText([
                    "type": "speechrail.transcription.hypothesis",
                    "task_id": "task-1",
                    "epoch": 0,
                    "utterance_id": "item-1",
                    "revision": 1,
                    "text": "A🦜",
                    "sample_span": ["start": 0, "end": 2400],
                    "stable_prefix_codepoints": 1,
                ])
            )
        )
        await transport.enqueue(
            .text(
                jsonText([
                    "type": "speechrail.transcription.hypothesis",
                    "task_id": "task-1",
                    "epoch": 0,
                    "utterance_id": "item-1",
                    "revision": 2,
                    "text": "A🦜e",
                ])
            )
        )

        guard let first = await events.next() else {
            XCTFail("Expected the first hypothesis snapshot")
            await client.close()
            return
        }
        guard case .partialSnapshot("item-1", 1, "A🦜", let firstEvidence) = first.payload else {
            XCTFail("Expected typed hypothesis evidence, got \(first.payload)")
            await client.close()
            return
        }
        XCTAssertEqual(firstEvidence.stablePrefixCodepoints, 1)
        XCTAssertEqual(firstEvidence.sampleSpan, .init(startSample: 0, endSample: 2400))

        guard let second = await events.next() else {
            XCTFail("Expected the second hypothesis snapshot")
            await client.close()
            return
        }
        guard case .partialSnapshot("item-1", 2, "A🦜e", let secondEvidence) = second.payload else {
            XCTFail("Expected the replaced hypothesis snapshot, got \(second.payload)")
            await client.close()
            return
        }
        XCTAssertNil(secondEvidence.stablePrefixCodepoints)
        XCTAssertNil(secondEvidence.sampleSpan)
        await client.close()
    }

    func testHypothesisRejectsStablePrefixBeyondCurrentUnicodeScalars() async throws {
        let transport = TestRealtimeASRTransport()
        let client = RealtimeASRClient(apiKey: "")
        var events = await client.events().makeAsyncIterator()

        try await client.connect(using: transport)
        _ = await events.next()  // .configured
        await transport.enqueue(
            .text(
                jsonText([
                    "type": "speechrail.transcription.hypothesis",
                    "task_id": "task-1",
                    "epoch": 0,
                    "utterance_id": "item-1",
                    "revision": 1,
                    "text": "你好",
                    "stable_prefix_codepoints": 3,
                ])
            )
        )

        guard let failure = await events.next() else {
            XCTFail("Expected invalid hypothesis evidence to be rejected")
            await client.close()
            return
        }
        guard case .failed("item-1", "invalid_hypothesis", _) = failure.payload else {
            XCTFail("Expected invalid_hypothesis, got \(failure.payload)")
            await client.close()
            return
        }
        await client.close()
    }

    func testRealtimeItemStateRejectsLateHypothesisForARetiredItem() {
        let clock = ContinuousClock()
        let generation = UUID()
        let start = clock.now
        var state = RealtimeEventState()
        state.reset(generation: generation, auxiliaryExpected: true)

        XCTAssertTrue(
            state.acceptHypothesis(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                revision: 1,
                text: "你好",
                sessionID: "session-1",
                generation: generation,
                now: start
            )
        )

        // 让 item 走完生命周期并进入退役窗口。
        let afterExpiry = start.advanced(by: .seconds(3600))
        state.prune(now: afterExpiry)

        XCTAssertFalse(
            state.acceptHypothesis(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 1,
                revision: 2,
                text: "你好啊",
                sessionID: "session-1",
                generation: generation,
                now: afterExpiry
            ),
            "已退役 item 在退役窗口内不得被迟到的 hypothesis 复活"
        )
    }

    func testRealtimeItemStateRejectsAForeignTaskIDWithinOneConnection() {
        let clock = ContinuousClock()
        let generation = UUID()
        let now = clock.now
        var state = RealtimeEventState()
        state.reset(generation: generation, auxiliaryExpected: true)

        XCTAssertTrue(
            state.acceptHypothesis(
                itemID: "item-1",
                taskID: "task-1",
                epoch: 0,
                revision: 1,
                text: "你好",
                sessionID: "session-1",
                generation: generation,
                now: now
            ),
            "首个事件必须绑定 task 与 session"
        )

        XCTAssertFalse(
            state.acceptHypothesis(
                itemID: "item-2",
                taskID: "task-2",
                epoch: 0,
                revision: 1,
                text: "今天讲相机",
                sessionID: "session-1",
                generation: generation,
                now: now
            ),
            "同一条连接内不得跨 task_id 复用 item 状态；换任务必须先重建连接"
        )
        XCTAssertNil(
            state.snapshot(itemID: "item-2"),
            "被拒绝的跨 task 事件不得留下任何 item 状态"
        )
    }

    private func sentEventTypes(_ transport: TestRealtimeASRTransport) async -> [String] {
        await transport.sentMessages().compactMap { message in
            let data = Data(message.utf8)
            guard
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["type"] as? String
        }
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
    private var nextSequence = 0

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
        let stamped = stampServerEvent(
            frame,
            defaultSessionID: "test-session",
            defaultEventID: "server-event-\(nextSequence)",
            defaultSequence: nextSequence
        )
        nextSequence += 1
        deliver(stamped)
    }

    func enqueueRaw(_ frame: RealtimeASRSocketFrame) {
        deliver(frame)
    }

    private func deliver(_ frame: RealtimeASRSocketFrame) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: frame)
        } else {
            frames.append(frame)
        }
    }

    func sentMessages() -> [String] { sent }

    func isClosed() -> Bool { closed }
}

func stampServerEvent(
    _ frame: RealtimeASRSocketFrame,
    defaultSessionID: String,
    defaultEventID: String,
    defaultSequence: Int
) -> RealtimeASRSocketFrame {
    let data: Data
    switch frame {
    case .text(let text):
        data = Data(text.utf8)
    case .data(let raw):
        data = raw
    case .unsupported:
        return frame
    }
    guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return frame
    }
    if object["event_id"] == nil { object["event_id"] = defaultEventID }
    if object["session_id"] == nil { object["session_id"] = defaultSessionID }
    if object["sequence"] == nil { object["sequence"] = defaultSequence }
    guard let stamped = try? JSONSerialization.data(withJSONObject: object) else {
        return frame
    }
    return .text(String(decoding: stamped, as: UTF8.self))
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

private func alignmentDoneEvent(
    taskID: String,
    transcriptRevision: Int,
    metadataRevision: Int,
    itemID: String,
    codepointEnd: Int,
    units: [[String: Any]]
) -> [String: Any] {
    [
        "type": "speechrail.alignment.done",
        "task_id": taskID,
        "epoch": 0,
        "utterance_id": itemID,
        "transcript_revision": transcriptRevision,
        "metadata_revision": metadataRevision,
        "sample_span": ["start": 0, "end": 8],
        "codepoint_span": ["start": 0, "end": codepointEnd],
        "units": units
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
