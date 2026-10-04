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

        coordinator.notePlaybackCompleted(samples: 2, epoch: try XCTUnwrap(recorder.epochs.first))
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

        coordinator.notePlaybackCompleted(samples: 3, epoch: try XCTUnwrap(recorder.epochs.first))
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
        XCTAssertEqual(recorder.epochs.count, 1, "入队时就要把这一代的身份交给播放层")
        let firstEpoch = try XCTUnwrap(recorder.epochs.first)
        XCTAssertEqual(coordinator.queuedSamples, 2)

        // 新一轮开始，而上一轮的最后一块还在路上。
        try await coordinator.begin(generation: 31, requestID: "req-31")
        await coordinator.handleAudio(requestID: "req-31", pcm: Data([1, 2, 3, 4]))
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

    // MARK: - D01：等待者必须按 (世代, 目标) 分槽

    /// ACK 等待与播放预算等待同时挂起时，两个 continuation 都必须被精确唤醒。
    /// 之前它们共用一个 `pendingWait` 槽：后注册的覆盖先注册的，
    /// 于是"等播放预算"永远挂着，文本泵再也等不到 ACK，`finish_text` 永远发不出去。
    func testAckWaitAndPlaybackWaitBothSurviveInterleaving() async throws {
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

        // 播放队列（上限 2 采样）被第一块占满。**必须放到独立 Task**：
        // `handleAudio` 会挂起等 `.playback`，直接 await 会把测试体自己也挂住。
        await coordinator.handleAudio(requestID: "req-50", pcm: Data([1, 2, 3, 4]))
        var secondAudioDone = false
        let secondAudio = Task { @MainActor in
            await coordinator.handleAudio(requestID: "req-50", pcm: Data([5, 6, 7, 8]))
            secondAudioDone = true
        }
        try await Task.sleep(for: .milliseconds(30))
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
            "等播放预算不能挡住 ACK 唤醒文本泵"
        )
        await waitUntil({ finished }, message: "ACK 到达后文本泵没有被唤醒")
        if finished { await finish.value }
        XCTAssertEqual(recorder.finishes, [0], "文本泵被唤醒后这一轮才能收尾")

        // 播放侧随后排空，挂起的第二块也必须真的进播放层。
        coordinator.notePlaybackCompleted(samples: 2, epoch: try XCTUnwrap(recorder.epochs.first))
        await waitUntil(
            { recorder.played.count == 2 },
            message: "播放预算归还后，等预算的音频没有被唤醒"
        )
        await waitUntil({ secondAudioDone }, message: "等预算的 handleAudio 没有返回")
        secondAudio.cancel()
    }

    func testInvalidateReleasesEveryPendingWaiter() async throws {
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
        var secondAudioDone = false
        let secondAudio = Task { @MainActor in
            await coordinator.handleAudio(requestID: "req-51", pcm: Data([5, 6, 7, 8]))
            secondAudioDone = true
        }
        try await Task.sleep(for: .milliseconds(30))

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
        await waitUntil({ secondAudioDone }, message: "invalidate 必须释放播放预算的等待者")
        secondAudio.cancel()
        XCTAssertEqual(recorder.finishes, [], "代已经作废，不许再发 finish")
    }

    /// 重播同一轮逻辑回复时，物理播放身份必须换新：否则上一轮迟到的
    /// `dataRendered` 会把这一轮的排队预算当成自己的还掉，提前宣布播完。
    func testReplayOfTheSameLogicalGenerationGetsAFreshPlaybackEpoch() async throws {
        let (coordinator, recorder) = makeHarness()
        try await coordinator.begin(generation: 60, requestID: "req-60a")
        await coordinator.handleAudio(requestID: "req-60a", pcm: Data([1, 2, 3, 4]))

        // 同一逻辑 generation 再次开嗓（重播）。
        try await coordinator.begin(generation: 60, requestID: "req-60b")
        await coordinator.handleAudio(requestID: "req-60b", pcm: Data([5, 6, 7, 8]))

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

    /// 旧一轮的 `cancel()` 跨越 await 落地时，不能把结局写进已经开起来的新一轮。
    func testLateCancelDoesNotReportIntoTheNextTurn() async throws {
        let (coordinator, recorder) = makeHarness()
        let gate = Gate()
        coordinator.stopPlayback = { await gate.enter() }
        try await coordinator.begin(generation: 70, requestID: "req-70a")

        let cancel = Task { @MainActor in await coordinator.cancel() }
        await waitUntil({ gate.entered }, message: "取消没有进入停播屏障")

        // 停播屏障还没落地时用户已经开始了新一轮。
        try await coordinator.begin(generation: 71, requestID: "req-71b")
        gate.release()
        await cancel.value

        XCTAssertTrue(
            recorder.outcomes.isEmpty,
            "旧一轮的取消完成得再晚，也不能改写新一轮的结局"
        )
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
        _ = confirmed
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
