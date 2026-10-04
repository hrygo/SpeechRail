import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// 协调器的纯状态测试：假服务端 + 假播放器，不碰 WebSocket、麦克风或音频设备。
/// 这里证明的是**状态机接线**（一轮一次 start/finish、旧代隔离、暂时排空不等于结束），
/// 不是真实可听延迟，也不是 AVAudioEngine 的验收。
@MainActor
final class AssistantTTSStreamCoordinatorTests: XCTestCase {
    private final class Recorder {
        var requestID = ""
        var started: [String] = []
        var appends: [(sequence: Int, text: String)] = []
        var finishes: [Int] = []
        var cancels = 0
        var epochs: [Int] = []
        var events: [String] = []
        var played: [Data] = []
        var outcomes: [(generation: Int, outcome: AssistantTTSStreamCoordinator.Outcome)] = []
    }

    private func makeHarness(
        configuration: AssistantTTSStreamCoordinator.Configuration = .default,
        acknowledgeStart: Bool = true,
        acknowledgeAppend: Bool = true
    ) -> (AssistantTTSStreamCoordinator, Recorder) {
        let recorder = Recorder()
        let coordinator = AssistantTTSStreamCoordinator(configuration: configuration)
        coordinator.sendStart = { [weak coordinator] requestID in
            recorder.requestID = requestID
            recorder.started.append(requestID)
            if acknowledgeStart {
                _ = coordinator?.handleStarted(
                    requestID: requestID,
                    taskID: nil,
                    limits: nil
                )
            }
        }
        coordinator.sendAppend = { [weak coordinator] sequence, text in
            recorder.appends.append((sequence: sequence, text: text))
            if acknowledgeAppend {
                _ = coordinator?.handleTextAccepted(
                    requestID: recorder.requestID,
                    appendSequence: sequence,
                    totalCodepoints: text.unicodeScalars.count
                )
            }
        }
        coordinator.sendFinish = { lastSequence in
            recorder.finishes.append(lastSequence)
        }
        coordinator.sendCancel = { recorder.cancels += 1 }
        coordinator.enqueuePlayback = { pcm, epoch in
            recorder.played.append(pcm)
            recorder.epochs.append(epoch)
            return true
        }
        coordinator.stopPlayback = {}
        coordinator.onOutcome = { generation, outcome in
            recorder.outcomes.append((generation: generation, outcome: outcome))
        }
        return (coordinator, recorder)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        iterations: Int = 400,
        message: String = "condition was not met"
    ) async {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(message)
    }

    func testAudioReachesPlaybackBeforeTheLLMFinishes() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 7, requestID: "req-7")

        coordinator.offer("你好。")
        await waitUntil({ coordinator.acceptedSequence == 0 }, message: "第一段文本没有发出去")

        await coordinator.handleAudio(
            requestID: "req-7",
            pcm: Data([1, 2, 3, 4])
        )
        await waitUntil({ recorder.played.count == 1 }, message: "PCM 没有进入播放层")

        XCTAssertEqual(recorder.played.count, 1, "LLM 还在生成时 PCM 就必须已经进播放器")
        XCTAssertFalse(coordinator.inputClosed)
        XCTAssertNil(coordinator.outcome)
        XCTAssertTrue(coordinator.isActive)
    }

    func testOneStartAndOneFinishPerTurn() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 1, requestID: "req-1")

        coordinator.offer("你好。")
        await waitUntil({ coordinator.acceptedSequence == 0 }, message: "第一段文本没有发出去")
        coordinator.offer("再见。")
        await coordinator.finishInput()

        XCTAssertEqual(recorder.started, ["req-1"])
        XCTAssertEqual(recorder.appends.map(\.sequence), [0, 1])
        XCTAssertEqual(recorder.appends.map(\.text), ["你好。", "再见。"])
        XCTAssertEqual(recorder.finishes, [1], "整轮只有一次 finish，序号等于最后一次 ACK")
        XCTAssertTrue(coordinator.inputClosed)
    }

    func testFinishWaitsForUnacknowledgedText() async throws {
        let (coordinator, recorder) = makeHarness(acknowledgeAppend: false)
        try await coordinator.begin(generation: 8, requestID: "req-8")

        coordinator.offer("你好。")
        await waitUntil({ recorder.appends.count == 1 }, message: "第一段文本没有发出去")

        let finish = Task { @MainActor in await coordinator.finishInput() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(recorder.finishes.isEmpty, "ACK 没回来之前不许 finish，否则会丢掉这一段")

        XCTAssertTrue(
            coordinator.handleTextAccepted(
                requestID: "req-8",
                appendSequence: 0,
                totalCodepoints: 3
            )
        )
        await finish.value
        XCTAssertEqual(recorder.finishes, [0])
    }

    func testAcknowledgementTimeoutDoesNotResendAppend() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.acknowledgementTimeout = .milliseconds(20)
        let (coordinator, recorder) = makeHarness(
            configuration: configuration,
            acknowledgeAppend: false
        )
        coordinator.sendCancel = { [weak coordinator] in
            recorder.cancels += 1
            await coordinator?.handleTerminal(requestID: "req-ack-timeout", status: "cancelled")
        }
        try await coordinator.begin(generation: 81, requestID: "req-ack-timeout")

        coordinator.offer("你好。")
        await waitUntil({ recorder.appends.count == 1 }, message: "文本没有发送")
        try await Task.sleep(for: .milliseconds(60))

        guard case .failed(_)? = coordinator.outcome else {
            return XCTFail("ACK 超时后这一轮必须失败")
        }
        XCTAssertEqual(
            recorder.appends.map(\.sequence),
            [0],
            "ACK 超时必须失败收尾，不能自动重发同一 append"
        )
        await waitUntil({ recorder.cancels == 1 }, message: "ACK 超时后没有发起取消")
        await waitUntil(
            { !coordinator.hasUnconfirmedRemoteOwnership },
            message: "匹配终态后取消任务没有收尾"
        )
    }

    func testCancelLetsLateAudioDieAndReportsCancellation() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 3, requestID: "req-3")
        coordinator.offer("你好。")
        await waitUntil({ coordinator.acceptedSequence == 0 })

        _ = await coordinator.cancel()

        XCTAssertEqual(recorder.outcomes.map(\.outcome), [.cancelled])
        XCTAssertEqual(recorder.cancels, 1)
        await coordinator.handleAudio(
            requestID: "req-3",
            pcm: Data([9, 9, 9, 9])
        )
        XCTAssertTrue(recorder.played.isEmpty, "取消之后到的音频不许再进播放层")
        XCTAssertFalse(coordinator.isActive)
    }

    func testCancellationTaskSchedulingCannotLeaveTheCurrentRequestActive() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.cancellationTimeout = .milliseconds(10)
        let (coordinator, _) = makeHarness(configuration: configuration)
        try await coordinator.begin(generation: 13, requestID: "req-13")

        // The synchronous preparation must revoke local ownership before the
        // effect Task is created, without relying on task scheduling.
        let preparation = try XCTUnwrap(coordinator.prepareCancellation())
        XCTAssertFalse(
            coordinator.isActive,
            "preparation must revoke the old request synchronously"
        )
        XCTAssertTrue(
            coordinator.isKnownRetiredRequest("req-13"),
            "preparation must register retired ownership before the effect is scheduled"
        )
        XCTAssertTrue(
            coordinator.prepareCancellation() === preparation,
            "repeated preparation must merge into the same retired request"
        )
        do {
            try await coordinator.begin(generation: 14, requestID: "req-14")
            XCTFail("a new request must not start while remote ownership is unknown")
        } catch is AssistantTTSStreamCoordinator.RemoteOwnershipUnknown {
            // Expected until the matching remote terminal is consumed.
        }

        let cancellation = Task { @MainActor in
            await coordinator.performCancellation(preparation)
        }
        let confirmed = await cancellation.value
        XCTAssertFalse(confirmed, "no terminal means remote idle remains unconfirmed")
        XCTAssertTrue(
            coordinator.hasUnconfirmedRemoteOwnership,
            "timed-out cancellation must retain unknown remote ownership"
        )

        let repeatedCancelConfirmed = await coordinator.cancel()
        XCTAssertFalse(
            repeatedCancelConfirmed,
            "a repeated cancel must not treat unknown remote ownership as confirmed"
        )

        await coordinator.handleTerminal(requestID: "req-13", status: "cancelled")
        XCTAssertFalse(
            coordinator.hasUnconfirmedRemoteOwnership,
            "the matching late terminal must release unknown remote ownership"
        )
    }

    func testCancelCannotConfirmOrRestartWhileCancelledAppendIsInFlight() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.cancellationTimeout = .milliseconds(20)
        let (coordinator, _) = makeHarness(configuration: configuration)
        let appendGate = Gate()
        coordinator.sendAppend = { _, _ in await appendGate.enter() }
        try await coordinator.begin(generation: 83, requestID: "req-outbound")

        coordinator.offer("这是一段文本。")
        await waitUntil({ appendGate.entered }, message: "sendAppend 没有进入受控挂起")

        let preparation = try XCTUnwrap(coordinator.prepareCancellation())
        // Simulate the matching remote terminal winning the race with the
        // cancellation effect while the old outbound append is still blocked.
        await coordinator.handleTerminal(requestID: "req-outbound", status: "cancelled")
        let cancellation = Task { @MainActor in
            await coordinator.performCancellation(preparation)
        }
        let confirmed = await cancellation.value
        XCTAssertFalse(
            confirmed,
            "a remote terminal cannot confirm the barrier while the cancelled append is still in flight"
        )

        do {
            try await coordinator.begin(generation: 84, requestID: "req-next")
            XCTFail("a new request must stay blocked until the old outbound task exits")
        } catch is AssistantTTSStreamCoordinator.RemoteOwnershipUnknown {
            // Expected while the old sendAppend call has not returned.
        }

        appendGate.release()
        var nextRequestStarted = false
        for _ in 0..<400 {
            do {
                try await coordinator.begin(generation: 84, requestID: "req-next")
                nextRequestStarted = true
                break
            } catch is AssistantTTSStreamCoordinator.RemoteOwnershipUnknown {
                await Task.yield()
            }
        }
        XCTAssertTrue(
            nextRequestStarted,
            "the matching terminal plus old outbound task exit must release the gate"
        )
        XCTAssertTrue(coordinator.isActive)
    }

    func testCancelSendTimeoutRetainsOutboundOwnerUntilSendTaskExits() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.cancellationTimeout = .milliseconds(20)
        let (coordinator, _) = makeHarness(configuration: configuration)
        let cancelGate = Gate()
        coordinator.sendCancel = { await cancelGate.enter() }
        try await coordinator.begin(generation: 85, requestID: "req-cancel-send")

        let preparation = try XCTUnwrap(coordinator.prepareCancellation())
        // The matching terminal may arrive while the cancel send is still blocked.
        await coordinator.handleTerminal(requestID: "req-cancel-send", status: "cancelled")
        let cancellation = Task { @MainActor in
            await coordinator.performCancellation(preparation)
        }
        await waitUntil({ cancelGate.entered }, message: "sendCancel 没有进入受控挂起")

        let confirmed = await cancellation.value
        XCTAssertFalse(
            confirmed,
            "a matching terminal cannot confirm cancellation while sendCancel is still in flight"
        )
        do {
            try await coordinator.begin(generation: 86, requestID: "req-cancel-next")
            XCTFail("a new request must wait for the timed-out sendCancel task to exit")
        } catch is AssistantTTSStreamCoordinator.RemoteOwnershipUnknown {
            // Expected while the uncooperative cancel send remains owned.
        }

        cancelGate.release()
        var nextRequestStarted = false
        for _ in 0..<400 {
            do {
                try await coordinator.begin(generation: 86, requestID: "req-cancel-next")
                nextRequestStarted = true
                break
            } catch is AssistantTTSStreamCoordinator.RemoteOwnershipUnknown {
                await Task.yield()
            }
        }
        XCTAssertTrue(
            nextRequestStarted,
            "the cancel-send completion must release only its own ownership gate"
        )
        XCTAssertTrue(coordinator.isActive)
    }

    func testTemporaryDrainDoesNotAnnounceCompletion() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 4, requestID: "req-4")
        coordinator.offer("你好。")
        await waitUntil({ coordinator.acceptedSequence == 0 })
        await coordinator.handleAudio(
            requestID: "req-4",
            pcm: Data([1, 2, 3, 4])
        )
        await waitUntil({ recorder.played.count == 1 }, message: "PCM 没有进入播放层")

        coordinator.notePlaybackCompleted(samples: 2, epoch: try XCTUnwrap(recorder.epochs.first))
        await waitUntil({ coordinator.isDrained }, message: "播放器排空后队列消费任务仍未收尾")
        XCTAssertTrue(coordinator.isDrained)
        XCTAssertTrue(recorder.outcomes.isEmpty, "只是暂时排空，不能宣布整轮结束")

        await coordinator.handleTerminal(requestID: "req-4", status: "completed")
        await waitUntil({ recorder.outcomes.count == 1 }, message: "终态与空队列同时满足后没有完成")
        XCTAssertEqual(recorder.outcomes.count, 1)
        XCTAssertEqual(recorder.outcomes.first?.outcome, .completed)
        XCTAssertEqual(recorder.outcomes.first?.generation, 4)
    }

    func testTerminalBeforeDrainWaitsForTheLastSamples() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 5, requestID: "req-5")
        coordinator.offer("你好。")
        await waitUntil({ coordinator.acceptedSequence == 0 })
        await coordinator.handleAudio(
            requestID: "req-5",
            pcm: Data([1, 2, 3, 4, 5, 6])
        )
        await waitUntil({ recorder.played.count == 1 }, message: "PCM 没有进入播放层")

        await coordinator.handleTerminal(requestID: "req-5", status: "completed")
        XCTAssertTrue(coordinator.isAwaitingPlayback)
        XCTAssertTrue(recorder.outcomes.isEmpty)

        coordinator.notePlaybackCompleted(samples: 3, epoch: try XCTUnwrap(recorder.epochs.first))
        await waitUntil({ recorder.outcomes.count == 1 }, message: "最后一块音频完成后没有收束")
        XCTAssertEqual(recorder.outcomes.count, 1, "整轮只在音频真的播完之后收束一次")
        XCTAssertEqual(recorder.outcomes.first?.outcome, .completed)
    }

    func testStaleIdentityIsIgnored() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 6, requestID: "req-6")

        XCTAssertFalse(
            coordinator.handleTextAccepted(
                requestID: "req-6",
                appendSequence: 3,
                totalCodepoints: 0
            ),
            "跳号的 ACK 不能推进序号"
        )
        XCTAssertFalse(
            coordinator.handleStarted(requestID: "req-old", taskID: "task-old", limits: nil)
        )
        await coordinator.handleTerminal(requestID: "req-old", status: "completed")
        await coordinator.handleServerError(requestID: "req-old", code: "tts_not_active", message: "旧请求")
        await coordinator.handleAudio(
            requestID: "req-old",
            pcm: Data([1, 2])
        )

        XCTAssertTrue(coordinator.isActive, "旧 request 的 started/done/error/audio 都不能动新一轮")
        XCTAssertTrue(recorder.played.isEmpty)
        XCTAssertTrue(recorder.outcomes.isEmpty)
    }

    func testServerErrorForTheActiveRequestFailsTheUtteranceOnce() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 9, requestID: "req-9")

        await coordinator.handleServerError(
            requestID: "req-9",
            code: "tts_stream_limit_exceeded",
            message: "超出上限"
        )
        await coordinator.handleServerError(requestID: "req-9", code: "tts_not_active", message: "重复")

        XCTAssertEqual(recorder.outcomes.count, 1, "终态只允许一次")
        guard case .failed(let message)? = coordinator.outcome else {
            return XCTFail("预期 failed，实际 \(String(describing: coordinator.outcome))")
        }
        XCTAssertTrue(message.contains("tts_stream_limit_exceeded"))
        XCTAssertFalse(coordinator.isActive)
    }

    func testFailureKeepsRemoteOwnershipUnknownUntilMatchingTerminal() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.cancellationTimeout = .milliseconds(10)
        let (coordinator, _) = makeHarness(configuration: configuration)
        try await coordinator.begin(generation: 17, requestID: "req-17")

        await coordinator.handleServerError(
            requestID: "req-17",
            code: "tts_sequence_invalid",
            message: "sequence rejected"
        )
        guard case .failed(_)? = coordinator.outcome else {
            return XCTFail("the current request failure must remain visible")
        }

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(
            coordinator.isKnownRetiredRequest("req-17"),
            "a cancel timeout must retain remote ownership as unknown"
        )
        do {
            try await coordinator.begin(generation: 18, requestID: "req-18")
            XCTFail("a new request must be rejected while failed request ownership is unknown")
            coordinator.invalidate()
        } catch is AssistantTTSStreamCoordinator.RemoteOwnershipUnknown {
            // Expected until the matching late terminal confirms the old request is gone.
        }

        await coordinator.handleTerminal(requestID: "req-17", status: "failed")
        try await coordinator.begin(generation: 18, requestID: "req-18")
        XCTAssertTrue(coordinator.isActive)
    }

    func testPlaybackBackpressureFailsInsteadOfQueueingForever() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.playbackLedger.maximumQueuedSamples = 2
        configuration.playbackWaitTimeout = .milliseconds(30)
        let (coordinator, recorder) = makeHarness(configuration: configuration)
        try await coordinator.begin(generation: 10, requestID: "req-10")

        await coordinator.handleAudio(
            requestID: "req-10",
            pcm: Data([1, 2, 3, 4])
        )
        await waitUntil({ recorder.played.count == 1 }, message: "首块音频没有进入播放")
        XCTAssertEqual(recorder.played.count, 1)

        await coordinator.handleAudio(
            requestID: "req-10",
            pcm: Data([5, 6, 7, 8])
        )
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recorder.played.count, 1, "超预算的音频不能被无界积压")
        guard case .failed(let message)? = coordinator.outcome else {
            return XCTFail("播放跟不上时必须明确失败，而不是一直等")
        }
        XCTAssertTrue(message.contains("播放"))
    }

    func testReceiverContinuesWhileAudioWaitsForPlaybackBudgetAndDrainsFIFO() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.playbackLedger.maximumQueuedSamples = 2
        configuration.playbackWaitTimeout = .seconds(5)
        let (coordinator, recorder) = makeHarness(configuration: configuration)
        try await coordinator.begin(generation: 14, requestID: "req-14")

        let first = Data([1, 1, 1, 1])
        let second = Data([2, 2, 2, 2])
        let third = Data([3, 3, 3, 3])
        await coordinator.handleAudio(requestID: "req-14", pcm: first)
        await waitUntil({ recorder.played.count == 1 }, message: "首块音频没有进入播放")
        XCTAssertEqual(recorder.played, [first])

        var acknowledgementAccepted = false
        var terminalConsumed = false
        let receiver = Task { @MainActor in
            await coordinator.handleAudio(requestID: "req-14", pcm: second)
            await coordinator.handleAudio(requestID: "req-14", pcm: third)
            acknowledgementAccepted = coordinator.handleTextAccepted(
                requestID: "req-14",
                appendSequence: 0,
                totalCodepoints: 3
            )
            await coordinator.handleTerminal(requestID: "req-14", status: "completed")
            terminalConsumed = true
        }

        await waitUntil({ terminalConsumed }, message: "audio admission blocked the receiver")
        XCTAssertTrue(
            acknowledgementAccepted,
            "audio waiting for playback capacity must not block an ACK on the receiver"
        )
        XCTAssertTrue(
            terminalConsumed,
            "audio waiting for playback capacity must not block a terminal on the receiver"
        )
        XCTAssertTrue(
            recorder.outcomes.isEmpty,
            "a terminal cannot complete the turn while FIFO audio remains pending"
        )
        XCTAssertEqual(coordinator.queuedAudioBytes, 8, "FIFO/in-flight PCM must count against its byte cap")

        let epoch = try XCTUnwrap(recorder.epochs.first)
        coordinator.notePlaybackCompleted(samples: 2, epoch: epoch)
        await waitUntil({ recorder.played.count == 2 }, message: "第二块 FIFO 音频没有进入播放")
        coordinator.notePlaybackCompleted(samples: 2, epoch: epoch)
        await waitUntil({ recorder.played.count == 3 }, message: "第三块 FIFO 音频没有进入播放")
        coordinator.notePlaybackCompleted(samples: 2, epoch: epoch)
        await receiver.value

        XCTAssertEqual(recorder.played, [first, second, third], "音频必须按 receiver 接纳顺序入队")
        XCTAssertEqual(recorder.outcomes.map(\.outcome), [.completed])
    }

    func testAggregateAudioCapIncludesChunkAwaitingPlaybackEnqueue() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.maximumPendingAudioBytes = 8
        configuration.playbackLedger.maximumQueuedSamples = 32
        let (coordinator, recorder) = makeHarness(configuration: configuration)
        let gate = Gate()
        coordinator.enqueuePlayback = { pcm, epoch in
            await gate.enter()
            recorder.played.append(pcm)
            recorder.epochs.append(epoch)
            return true
        }
        coordinator.sendCancel = { [weak coordinator] in
            recorder.cancels += 1
            await coordinator?.handleTerminal(requestID: "req-audio-cap", status: "cancelled")
        }
        try await coordinator.begin(generation: 82, requestID: "req-audio-cap")

        let first = Data([1, 1, 1, 1])
        let second = Data([2, 2, 2, 2])
        let third = Data([3, 3])
        XCTAssertEqual(
            coordinator.admitAudio(requestID: "req-audio-cap", pcm: first),
            .accepted
        )
        await waitUntil({ gate.entered }, message: "首块没有进入异步 enqueue")
        XCTAssertEqual(coordinator.queuedAudioBytes, first.count)

        XCTAssertEqual(
            coordinator.admitAudio(requestID: "req-audio-cap", pcm: second),
            .accepted
        )
        XCTAssertEqual(
            coordinator.queuedAudioBytes,
            first.count + second.count,
            "await enqueue 的音频与 FIFO 中的音频都计入上限"
        )

        XCTAssertEqual(
            coordinator.admitAudio(requestID: "req-audio-cap", pcm: third),
            .rejected,
            "多个单块都未超限，但 FIFO 加 in-flight 总量超限时必须拒绝"
        )
        XCTAssertEqual(coordinator.queuedAudioBytes, 0, "失败应立即丢弃本地待播 PCM")
        guard case .failed(_)? = coordinator.outcome else {
            return XCTFail("聚合 PCM 超限必须显式失败")
        }

        gate.release()
        await waitUntil({ recorder.cancels == 1 }, message: "超限后没有收尾取消")
        await waitUntil(
            { !coordinator.hasUnconfirmedRemoteOwnership },
            message: "匹配终态后取消任务没有收尾"
        )
    }

    func testOversizedAudioFailsBeforeEnteringPlayback() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.playbackLedger.maximumQueuedSamples = 30_000
        let (coordinator, recorder) = makeHarness(configuration: configuration)
        try await coordinator.begin(generation: 15, requestID: "req-15")
        _ = coordinator.handleStarted(
            requestID: "req-15",
            taskID: nil,
            limits: TTSStreamLimits(
                maxAppendCodepoints: 4_096,
                maxTotalCodepoints: 16_000,
                maxPendingCodepoints: 8_000,
                maxPendingAudioBytes: 96_000,
                inputWaitSeconds: 15,
                utteranceWallClockSeconds: 120,
                slowConsumerSeconds: 2
            )
        )

        await coordinator.handleAudio(
            requestID: "req-15",
            pcm: Data(repeating: 1, count: 48_002)
        )

        XCTAssertTrue(
            recorder.played.isEmpty,
            "a chunk larger than the local 48,000-byte admission budget must not reach playback"
        )
        guard case .failed(_)? = coordinator.outcome else {
            return XCTFail("audio overflow must fail explicitly before reserving playback samples")
        }
        XCTAssertEqual(coordinator.queuedSamples, 0, "rejected PCM must leave no ledger reservation")
    }

    func testNegotiatedAudioLimitTightensAdmission() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.playbackLedger.maximumQueuedSamples = 100
        let (coordinator, recorder) = makeHarness(configuration: configuration)
        try await coordinator.begin(generation: 16, requestID: "req-16")
        _ = coordinator.handleStarted(
            requestID: "req-16",
            taskID: nil,
            limits: TTSStreamLimits(
                maxAppendCodepoints: 4_096,
                maxTotalCodepoints: 16_000,
                maxPendingCodepoints: 8_000,
                maxPendingAudioBytes: 4,
                inputWaitSeconds: 15,
                utteranceWallClockSeconds: 120,
                slowConsumerSeconds: 2
            )
        )

        await coordinator.handleAudio(requestID: "req-16", pcm: Data([1, 2, 3, 4, 5, 6]))

        XCTAssertTrue(
            recorder.played.isEmpty,
            "a chunk larger than the negotiated pending-audio limit must not reach playback"
        )
        guard case .failed(_)? = coordinator.outcome else {
            return XCTFail("the negotiated audio limit must reject an oversized chunk")
        }
        XCTAssertEqual(coordinator.queuedSamples, 0, "rejected PCM must not leave a reservation")
    }

    func testPlaybackFailureSurfacesInsteadOfPretendingCompletion() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 11, requestID: "req-11")

        coordinator.notePlaybackFailure("音频设备切换后无法恢复")

        guard case .failed(let message)? = coordinator.outcome else {
            return XCTFail("播放通道失败不能当成播完")
        }
        XCTAssertTrue(message.contains("音频设备"))
        XCTAssertEqual(recorder.outcomes.count, 1)
    }

    func testInvalidateDropsStateWithoutClosingTheServer() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 12, requestID: "req-12")
        coordinator.offer("你好。")
        await waitUntil({ coordinator.acceptedSequence == 0 })

        coordinator.invalidate()

        XCTAssertFalse(coordinator.isActive)
        XCTAssertEqual(coordinator.acceptedSequence, -1)
        XCTAssertEqual(coordinator.queuedSamples, 0)
        XCTAssertTrue(recorder.outcomes.isEmpty)
        XCTAssertEqual(recorder.cancels, 0, "断线/设备重建只作废本地状态，不发网络命令")
    }

    /// 一个可以卡住/放行的屏障：用来观察"停播"与"网络取消"的先后，不碰真实音频设备。
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        private var released = false

        func enter() async {
            entered = true
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    func testCancelWaitsForThePlaybackStopBarrierBeforeCancellingTheServer() async throws {
        let (coordinator, recorder) = makeHarness()
        let gate = Gate()
        coordinator.stopPlayback = {
            recorder.events.append("stop-entered")
            await gate.enter()
            recorder.events.append("stop-finished")
        }
        coordinator.sendCancel = {
            recorder.cancels += 1
            recorder.events.append("server-cancel")
        }
        try await coordinator.begin(generation: 20, requestID: "req-20")

        let cancel = Task { @MainActor in await coordinator.cancel() }
        await waitUntil({ gate.entered }, message: "取消没有先进入停播屏障")

        XCTAssertEqual(recorder.cancels, 0, "停播屏障没落地之前不许发网络取消")
        gate.release()
        _ = await cancel.value

        let stopped = try XCTUnwrap(recorder.events.firstIndex(of: "stop-finished"))
        let cancelled = try XCTUnwrap(recorder.events.firstIndex(of: "server-cancel"))
        XCTAssertLessThan(stopped, cancelled, "停播屏障必须先于网络取消")
        XCTAssertEqual(recorder.outcomes.map(\.outcome), [.cancelled])
        XCTAssertFalse(coordinator.isActive)
    }

    func testLatePlaybackCompletionFromAnEarlierEpochCannotTouchTheNewLedger() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 30, requestID: "req-30")
        await coordinator.handleAudio(requestID: "req-30", pcm: Data([1, 2, 3, 4]))
        await waitUntil({ recorder.epochs.count == 1 }, message: "第一代 PCM 没有入队")
        XCTAssertEqual(recorder.epochs.count, 1, "入队时就要把这一代的身份交给播放层")
        let firstEpoch = try XCTUnwrap(recorder.epochs.first)
        XCTAssertEqual(coordinator.queuedSamples, 2)

        // 新一轮开始，而上一轮的最后一块还在路上。
        try await coordinator.begin(generation: 31, requestID: "req-31")
        await coordinator.handleAudio(requestID: "req-31", pcm: Data([1, 2, 3, 4]))
        await waitUntil({ recorder.epochs.count == 2 }, message: "第二代 PCM 没有入队")
        let secondEpoch = try XCTUnwrap(recorder.epochs.last)
        XCTAssertNotEqual(firstEpoch, secondEpoch, "每一代播放都要有自己的身份")
        XCTAssertEqual(coordinator.queuedSamples, 2)

        coordinator.notePlaybackCompleted(samples: 2, epoch: firstEpoch)
        XCTAssertEqual(coordinator.queuedSamples, 2, "上一代迟到的 dataRendered 不许动新一代的账本")

        coordinator.notePlaybackCompleted(samples: 2, epoch: secondEpoch)
        XCTAssertEqual(coordinator.queuedSamples, 0, "本代的 dataRendered 才归还本代的预算")
    }

    func testCancelDoesNotRestoreAudioWhenTheServerCancelHangs() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.cancellationTimeout = .milliseconds(30)
        let (coordinator, recorder) = makeHarness(configuration: configuration)
        coordinator.sendCancel = { try await Task.sleep(for: .seconds(30)) }
        try await coordinator.begin(generation: 40, requestID: "req-40")
        await coordinator.handleAudio(requestID: "req-40", pcm: Data([1, 2, 3, 4]))
        await waitUntil({ recorder.played.count == 1 }, message: "旧 PCM 没有进入播放层")

        let startedAt = ContinuousClock().now
        _ = await coordinator.cancel()

        XCTAssertLessThan(
            startedAt.duration(to: ContinuousClock().now),
            .seconds(1),
            "后端取消不回话时，本地取消不能一直吊着"
        )
        XCTAssertEqual(recorder.outcomes.map(\.outcome), [.cancelled])
        XCTAssertFalse(coordinator.isActive)

        await coordinator.handleAudio(requestID: "req-40", pcm: Data([5, 6, 7, 8]))
        XCTAssertEqual(recorder.played.count, 1, "取消失败或超时都不许把旧音放回来")
    }

    // MARK: - D01：等待者必须按 (世代, 目标) 分槽

    /// ACK 与播放预算等待并行时，receiver 继续处理 ACK，FIFO 在预算恢复后保序消费。
    func testAckProgressesWhileAudioConsumerWaitsForPlaybackBudget() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.playbackLedger.maximumQueuedSamples = 2
        let (coordinator, recorder) = makeHarness(
            configuration: configuration,
            acknowledgeAppend: false
        )
        try await coordinator.begin(generation: 50, requestID: "req-50")

        // 文本泵挂住等 ack(0)（sendAppend 不自动回 ACK）。
        coordinator.offer("你好。")
        await waitUntil({ recorder.appends.count == 1 }, message: "第一段文本没有发出去")

        // 首块占满 2 样本 ledger；后续块只能留在 bounded FIFO 等预算。
        await coordinator.handleAudio(requestID: "req-50", pcm: Data([1, 2, 3, 4]))
        await waitUntil({ recorder.played.count == 1 }, message: "首块音频没有进入播放")
        let firstEpoch = try XCTUnwrap(recorder.epochs.first)

        var secondAudioDone = false
        let secondAudio = Task { @MainActor in
            await coordinator.handleAudio(requestID: "req-50", pcm: Data([5, 6, 7, 8]))
            secondAudioDone = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(secondAudioDone, "receiver admission 不等待播放预算")
        XCTAssertEqual(coordinator.queuedAudioBytes, 4, "等待播放预算的 PCM 仍受 FIFO 字节上限约束")
        XCTAssertEqual(coordinator.queuedSamples, 2)
        XCTAssertTrue(coordinator.isActive, "挂起等待不等于失败")

        // 此刻 ACK 等待与播放预算等待同时挂着，任何一个被覆盖都会让另一个永远醒不过来。
        var finished = false
        let finish = Task { @MainActor in
            await coordinator.finishInput()
            finished = true
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finished, "ACK 未回来之前不许 finish")

        XCTAssertTrue(
            coordinator.handleTextAccepted(
                requestID: "req-50",
                appendSequence: 0,
                totalCodepoints: 3
            ),
            "等播放预算不能挡住 receiver 接收 ACK"
        )
        await waitUntil({ finished }, message: "ACK 到达后文本泵没有被唤醒")
        if finished { await finish.value }
        XCTAssertEqual(recorder.finishes, [0], "文本泵被唤醒后这一轮才能收尾")

        // 播放侧随后排空，后台 consumer 才能把第二块送进播放器。
        coordinator.notePlaybackCompleted(samples: 2, epoch: firstEpoch)
        await waitUntil(
            { recorder.played.count == 2 },
            message: "播放预算归还后，FIFO 音频没有进入播放"
        )
        coordinator.notePlaybackCompleted(samples: 2, epoch: firstEpoch)
        secondAudio.cancel()
    }

    func testInvalidateReleasesAckWaitAndDropsPendingAudio() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.playbackLedger.maximumQueuedSamples = 2
        let (coordinator, recorder) = makeHarness(
            configuration: configuration,
            acknowledgeAppend: false
        )
        try await coordinator.begin(generation: 51, requestID: "req-51")

        coordinator.offer("你好。")
        await waitUntil({ recorder.appends.count == 1 })
        await coordinator.handleAudio(requestID: "req-51", pcm: Data([1, 2, 3, 4]))
        await waitUntil({ recorder.played.count == 1 })
        var secondAudioDone = false
        let secondAudio = Task { @MainActor in
            await coordinator.handleAudio(requestID: "req-51", pcm: Data([5, 6, 7, 8]))
            secondAudioDone = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(secondAudioDone, "同步 admission 不等 ledger 预算")
        XCTAssertEqual(coordinator.queuedAudioBytes, 4)

        var finished = false
        let finish = Task { @MainActor in
            await coordinator.finishInput()
            finished = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(finished)

        coordinator.invalidate()

        await waitUntil({ finished }, message: "invalidate 必须释放全部等待者")
        if finished { await finish.value }
        XCTAssertEqual(coordinator.queuedAudioBytes, 0, "invalidate 必须清空未消费 PCM")
        secondAudio.cancel()
        XCTAssertEqual(recorder.finishes, [], "代已经作废，不许再发 finish")
    }

    /// 重播同一轮逻辑回复时，物理播放身份必须换新：否则上一轮迟到的
    /// `dataRendered` 会把这一轮的排队预算当成自己的还掉，提前宣布播完。
    func testReplayOfTheSameLogicalGenerationGetsAFreshPlaybackEpoch() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 60, requestID: "req-60a")
        await coordinator.handleAudio(requestID: "req-60a", pcm: Data([1, 2, 3, 4]))
        await waitUntil({ recorder.epochs.count == 1 }, message: "第一次重播音频没有入队")

        // 同一逻辑 generation 再次开嗓（重播）。
        try await coordinator.begin(generation: 60, requestID: "req-60b")
        await coordinator.handleAudio(requestID: "req-60b", pcm: Data([5, 6, 7, 8]))
        await waitUntil({ recorder.epochs.count == 2 }, message: "第二次重播音频没有入队")

        let epochs = recorder.epochs
        XCTAssertEqual(epochs.count, 2)
        XCTAssertNotEqual(
            epochs[0],
            epochs[1],
            "重播必须分配新的播放 epoch，不能复用逻辑 generation"
        )
        XCTAssertEqual(coordinator.queuedSamples, 2)

        coordinator.notePlaybackCompleted(samples: 2, epoch: epochs[0])
        XCTAssertEqual(
            coordinator.queuedSamples,
            2,
            "上一轮迟到的 dataRendered 不许动重播这一轮的账本"
        )
        coordinator.notePlaybackCompleted(samples: 2, epoch: epochs[1])
        XCTAssertEqual(coordinator.queuedSamples, 0)
    }

    /// 本地撤权后、匹配远端终态到达前，不允许在同一 coordinator 开新轮。
    func testRetiredRequestBlocksNewStartUntilRemoteTerminal() async throws {
        let (coordinator, recorder) = makeHarness()
        let gate = Gate()
        coordinator.stopPlayback = { await gate.enter() }
        coordinator.sendCancel = {
            recorder.cancels += 1
            await coordinator.handleTerminal(requestID: "req-70a", status: "cancelled")
        }
        try await coordinator.begin(generation: 70, requestID: "req-70a")

        let preparation = try XCTUnwrap(coordinator.prepareCancellation())
        let cancel = Task { @MainActor in await coordinator.performCancellation(preparation) }
        await waitUntil({ gate.entered }, message: "取消没有进入停播屏障")

        do {
            try await coordinator.begin(generation: 71, requestID: "req-71b")
            XCTFail("远端归属未确认时不允许在同一连接开新一轮")
        } catch is AssistantTTSStreamCoordinator.RemoteOwnershipUnknown {
            // Expected while request 70 is retired.
        }
        gate.release()
        let confirmed = await cancel.value
        XCTAssertTrue(confirmed, "sendCancel 中收到的匹配终态必须确认 ownership")
        try await coordinator.begin(generation: 71, requestID: "req-71b")

        XCTAssertEqual(recorder.outcomes.map(\.generation), [70])
        XCTAssertNil(coordinator.outcome)
        XCTAssertTrue(coordinator.isActive)
    }

    /// §7.3 交叉边界（A03/A04）：terminal 在闩登记前到达。
    /// 终态比等待先到时记进 terminalSignals，随后开始的等待直接命中，
    /// 不白等一个完整超时。反例：去掉 prefetch，直接等到超时才判未确认。
    func testTerminalArrivingBeforeWaitStillConfirmsCancel() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.cancellationTimeout = .seconds(2)
        let (coordinator, _) = makeHarness(configuration: configuration)
        let gate = Gate()
        coordinator.stopPlayback = { await gate.enter() }
        try await coordinator.begin(generation: 80, requestID: "req-80")

        let cancel = Task { @MainActor in await coordinator.cancel() }
        // cancel() 已过 retiring 登记、正停在停播屏障里：
        // 此时到的终态记进 terminalSignals，随后挂上的等待直接命中，不走超时。
        await waitUntil({ gate.entered }, message: "取消没有进入停播屏障")
        await coordinator.handleTerminal(requestID: "req-80", status: "cancelled")
        gate.release()
        let confirmed = await cancel.value
        XCTAssertTrue(confirmed, "终态先到也必须确认取消，不能等到超时")
    }

    /// §7.3 交叉边界（A03/A04）：旧 terminal 之后新 start。
    /// 旧轮终态已确认（闩已回收）后开新轮，新轮不受旧终态影响；
    /// 随后旧轮的迟到重复终态不得改写新轮状态。
    func testOldTerminalDoesNotLeakIntoNewStart() async throws {
        // coordinator 层 harness 默认不自动回终态（sendCancel 只计数）：
        // 旧轮 cancel 发出后无确认，旧终态随后经接收层到达并确认。
        // 超时只压短等待，不改语义：sendCancel 默认不回执，
        // cancel 内的有界等待走该超时，无确认分支照常覆盖。
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.cancellationTimeout = .milliseconds(200)
        let (coordinator, _) = makeHarness(configuration: configuration)
        try await coordinator.begin(generation: 90, requestID: "req-90")
        let confirmed = await coordinator.cancel()
        XCTAssertFalse(confirmed, "没有 matching terminal 时取消必须报告未确认")
        do {
            try await coordinator.begin(generation: 91, requestID: "req-91")
            XCTFail("远端 ownership 未知时不能在同一 coordinator 开新轮")
        } catch is AssistantTTSStreamCoordinator.RemoteOwnershipUnknown {
            // Expected until the late terminal confirms req-90 is gone.
        }
        // 旧轮终态经接收层到达并确认后，新 start 必须可开。
        await coordinator.handleTerminal(requestID: "req-90", status: "cancelled")
        try await coordinator.begin(generation: 91, requestID: "req-91")
        XCTAssertTrue(coordinator.isActive)
        // 旧轮迟到重复终态：新轮身份不同，不得改写新轮结局。
        await coordinator.handleTerminal(requestID: "req-90", status: "cancelled")
        XCTAssertTrue(coordinator.isActive, "旧轮迟到终态不得结束新轮")
        XCTAssertNil(coordinator.outcome, "旧轮迟到终态不得写新轮结局")
    }

    /// §7.3 交叉边界（A35/A39）：服务端限额小于默认时，清洗后输出超限有界失败。
    /// started 带小限额 maxAppendCodepoints=4；offer 6 scalar 清洗后仍 6，
    /// sendChunk 按服务端限额判超限并 fail，不丢已收文本、不崩。
    func testSmallerServerLimitsFailBounded() async throws {
        let (coordinator, recorder) = makeHarness(acknowledgeStart: false)
        // 首轮只为拿到 coordinator：started 不自动回，手动带小限额回。
        let first = Task { @MainActor in try await coordinator.begin(generation: 110, requestID: "req-110") }
        await waitUntil({ !recorder.started.isEmpty }, message: "start 没有发出去")
        _ = coordinator.handleStarted(
            requestID: "req-110",
            taskID: nil,
            limits: TTSStreamLimits(
                maxAppendCodepoints: 4,
                maxTotalCodepoints: 4_096,
                maxPendingCodepoints: 2_048,
                maxPendingAudioBytes: 48_000,
                inputWaitSeconds: 15,
                utteranceWallClockSeconds: 120,
                slowConsumerSeconds: 2
            )
        )
        try await first.value
        XCTAssertEqual(coordinator.serverLimits?.maxAppendCodepoints, 4)
        // 6 scalar 一次 offer：buffer 准入（客户端 total 4096 未超，pending 不足
        // 512 不提前切）；finishInput 经 flush 交出 6 scalar 片，
        // 服务端片长 4 → sendChunk 有界失败，不无限重发。
        coordinator.offer(String(repeating: "啊", count: 6))
        await coordinator.finishInput()
        await waitUntil({ recorder.outcomes.count >= 1 }, message: "超限应有明确结局")
        XCTAssertEqual(recorder.appends.count, 0, "超限片不得发出去")
    }
}
