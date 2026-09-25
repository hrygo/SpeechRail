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

    func testCancelLetsLateAudioDieAndReportsCancellation() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 3, requestID: "req-3")
        coordinator.offer("你好。")
        await waitUntil({ coordinator.acceptedSequence == 0 })

        await coordinator.cancel()

        XCTAssertEqual(recorder.outcomes.map(\.outcome), [.cancelled])
        XCTAssertEqual(recorder.cancels, 1)
        await coordinator.handleAudio(
            requestID: "req-3",
            pcm: Data([9, 9, 9, 9])
        )
        XCTAssertTrue(recorder.played.isEmpty, "取消之后到的音频不许再进播放层")
        XCTAssertFalse(coordinator.isActive)
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

        coordinator.notePlaybackCompleted(samples: 2, epoch: 4)
        XCTAssertTrue(coordinator.isDrained)
        XCTAssertTrue(recorder.outcomes.isEmpty, "只是暂时排空，不能宣布整轮结束")

        await coordinator.handleTerminal(requestID: "req-4", status: "completed")
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

        await coordinator.handleTerminal(requestID: "req-5", status: "completed")
        XCTAssertTrue(coordinator.isAwaitingPlayback)
        XCTAssertTrue(recorder.outcomes.isEmpty)

        coordinator.notePlaybackCompleted(samples: 3, epoch: 5)
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
        XCTAssertEqual(recorder.played.count, 1)

        await coordinator.handleAudio(
            requestID: "req-10",
            pcm: Data([5, 6, 7, 8])
        )

        XCTAssertEqual(recorder.played.count, 1, "超预算的音频不能被无界积压")
        guard case .failed(let message)? = coordinator.outcome else {
            return XCTFail("播放跟不上时必须明确失败，而不是一直等")
        }
        XCTAssertTrue(message.contains("播放"))
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
        await cancel.value

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
        XCTAssertEqual(recorder.epochs, [30], "入队时就要把这一代的身份交给播放层")
        XCTAssertEqual(coordinator.queuedSamples, 2)

        // 新一轮开始，而上一轮的最后一块还在路上。
        try await coordinator.begin(generation: 31, requestID: "req-31")
        await coordinator.handleAudio(requestID: "req-31", pcm: Data([1, 2, 3, 4]))
        XCTAssertEqual(recorder.epochs, [30, 31])
        XCTAssertEqual(coordinator.queuedSamples, 2)

        coordinator.notePlaybackCompleted(samples: 2, epoch: 30)
        XCTAssertEqual(coordinator.queuedSamples, 2, "上一代迟到的 dataRendered 不许动新一代的账本")

        coordinator.notePlaybackCompleted(samples: 2, epoch: 31)
        XCTAssertEqual(coordinator.queuedSamples, 0, "本代的 dataRendered 才归还本代的预算")
    }

    func testCancelDoesNotRestoreAudioWhenTheServerCancelHangs() async throws {
        var configuration = AssistantTTSStreamCoordinator.Configuration.default
        configuration.cancellationTimeout = .milliseconds(30)
        let (coordinator, recorder) = makeHarness(configuration: configuration)
        coordinator.sendCancel = { try await Task.sleep(for: .seconds(30)) }
        try await coordinator.begin(generation: 40, requestID: "req-40")
        await coordinator.handleAudio(requestID: "req-40", pcm: Data([1, 2, 3, 4]))

        let startedAt = ContinuousClock().now
        await coordinator.cancel()

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
}
