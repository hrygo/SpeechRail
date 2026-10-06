import AVFoundation
import Foundation
import SpeechRailControlKit
import XCTest
#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

/// V17 真机对照（#268，不关闭 issue）：真实 `PCMStreamPlayer` + 生产 `AssistantTTSStreamCoordinator`。
///
/// fake 门已覆盖状态机（`testReceiverContinuesWhileAudioWaitsForPlaybackBudgetAndDrainsFIFO`、
/// `testPlaybackBackpressureFailsInsteadOfQueueingForever`、取消后旧音频隔离），
/// 本文件只补 fake 证明不了的一段：**真实播放器的 `dataPlayedBack` 回调
/// 经生产通道（epoch + chunkID 原样带回）驱动协调器完成整轮**——
/// 有界积压保序播完、terminal 在 played 前到不提前 completed、
/// 取消后旧播放器的迟到回调不污染新轮。
///
/// 需要真实音频输出设备（本机扬声器）；CI 无设备时整类跳过，
/// 不阻碍门禁（`XCTSkip("本机无音频输出设备")`）。
@MainActor
final class AssistantV17BacklogPlaybackTests: XCTestCase {
    /// 真实 24kHz PCM16 正弦块：durationMs 毫秒，440Hz。
    private func sineChunk(durationMs: Int, phase: inout Double) -> Data {
        let sampleRate = 24_000.0
        let frames = Int(sampleRate * Double(durationMs) / 1000.0)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = Int16(sin(phase) * 8_000)
            phase += 2.0 * .pi * 440.0 / sampleRate
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func makeProductionCoordinator(
        player: PCMStreamPlayer,
        outcomes: @MainActor @escaping (AssistantTTSStreamCoordinator.Outcome) -> Void
    ) -> AssistantTTSStreamCoordinator {
        let coordinator = AssistantTTSStreamCoordinator()
        coordinator.sendStart = { [weak coordinator] requestID in
            _ = coordinator?.handleStarted(requestID: requestID, taskID: nil, limits: nil)
        }
        coordinator.enqueuePlayback = { pcm, epoch, chunkID in
            await player.enqueue(pcm, epoch: epoch, chunkID: chunkID)
        }
        coordinator.stopPlayback = { await player.stop() }
        coordinator.onOutcome = { _, outcome in outcomes(outcome) }
        return coordinator
    }

    private func waitFor(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(15),
        message: String
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message)
    }

    /// V17 主项：3 块各约 400ms（合计 ~1.2s >> 300ms 旧候选阈值）的完整音频，
    /// 经真实播放器保序播完；terminal 先到不提前 completed，
    /// played 覆盖全部提交样本后才 completed。
    func testV17BoundedBacklogDrainsInOrderThroughRealPlayback() async throws {
        let player = PCMStreamPlayer()
        do {
            try await player.start()
        } catch {
            throw XCTSkip("本机无音频输出设备：\(error.localizedDescription)")
        }
        var outcomes: [AssistantTTSStreamCoordinator.Outcome] = []
        let coordinator = makeProductionCoordinator(player: player) { outcomes.append($0) }
        // 生产通道：played 回调带 epoch + chunkID 原样带回（AssistantSession 建连语义）。
        player.onBufferRendered = { [weak coordinator] epoch, frames, chunkID in
            coordinator?.notePlaybackCompleted(samples: frames, epoch: epoch, chunkID: chunkID)
        }
        var drained = false
        player.onDrained = { drained = true }

        try await coordinator.begin(generation: 1, requestID: "v17-req-1")
        var phase: Double = 0
        let chunks = (0..<3).map { _ in sineChunk(durationMs: 400, phase: &phase) }
        let totalSamples = chunks.reduce(0) { $0 + $1.count / MemoryLayout<Int16>.size }
        XCTAssertGreaterThan(totalSamples, 7_200, "3x400ms @24kHz 应远超 300ms（7200 samples）旧候选阈值")
        for chunk in chunks {
            await coordinator.handleAudio(requestID: "v17-req-1", pcm: chunk)
        }
        // terminal 在 played 之前到：不得提前 completed（V05 played 门控）。
        await coordinator.handleTerminal(requestID: "v17-req-1", status: "completed")
        XCTAssertTrue(outcomes.isEmpty, "played 未覆盖全部提交样本前不得 completed")
        XCTAssertTrue(coordinator.isAwaitingPlayback, "终态已到、音频未排空应在 awaiting-playback")
        // 真实播放器按入队顺序播完：played 回调逐块归还，播完才 completed。
        try await waitFor({ outcomes.count == 1 }, message: "真实播放器播完 3 块后应 completed")
        XCTAssertEqual(outcomes, [.completed])
        try await waitFor({ drained }, message: "真实播放器应回调排空")
        await player.stop()
    }

    /// V17 取消项：取消后旧播放器的迟到 played 回调不得记入新轮；
    /// 新轮 terminal + played 到齐才 completed。
    func testV17CancelInvalidatesStalePlaybackCallbacks() async throws {
        let player = PCMStreamPlayer()
        do {
            try await player.start()
        } catch {
            throw XCTSkip("本机无音频输出设备：\(error.localizedDescription)")
        }
        var outcomes: [AssistantTTSStreamCoordinator.Outcome] = []
        let coordinator = makeProductionCoordinator(player: player) { outcomes.append($0) }
        player.onBufferRendered = { [weak coordinator] epoch, frames, chunkID in
            coordinator?.notePlaybackCompleted(samples: frames, epoch: epoch, chunkID: chunkID)
        }
        try await coordinator.begin(generation: 1, requestID: "v17-req-1")
        var phase: Double = 0
        await coordinator.handleAudio(requestID: "v17-req-1", pcm: sineChunk(durationMs: 400, phase: &phase))
        _ = await coordinator.cancel()
        XCTAssertEqual(outcomes, [.cancelled])
        // 生产语义：取消后远端 ownership 未确认前不得开新轮——
        // 旧轮 matching terminal 经接收层到达才放行（V03 旧远端收尾确认）。
        await coordinator.handleTerminal(requestID: "v17-req-1", status: "cancelled")
        // 取消后旧轮音频不再进播放（旧 epoch 已撤销）。
        await coordinator.handleAudio(requestID: "v17-req-1", pcm: sineChunk(durationMs: 200, phase: &phase))
        // 新轮：迟到的旧 played（若有）不得提前完成新轮。
        // cancel 已停播旧 player（stopped 后 enqueue 返回 false）——
        // 生产里设备重建会换新播放通道，测试同样换新 player 接线。
        let player2 = PCMStreamPlayer()
        try await player2.start()
        coordinator.enqueuePlayback = { pcm, epoch, chunkID in
            await player2.enqueue(pcm, epoch: epoch, chunkID: chunkID)
        }
        coordinator.stopPlayback = { await player2.stop() }
        player2.onBufferRendered = { [weak coordinator] epoch, frames, chunkID in
            coordinator?.notePlaybackCompleted(samples: frames, epoch: epoch, chunkID: chunkID)
        }
        try await coordinator.begin(generation: 2, requestID: "v17-req-2")
        await coordinator.handleAudio(requestID: "v17-req-2", pcm: sineChunk(durationMs: 200, phase: &phase))
        await coordinator.handleTerminal(requestID: "v17-req-2", status: "completed")
        try await waitFor({ outcomes.count == 2 }, message: "新轮 played 到齐后应 completed")
        XCTAssertEqual(outcomes, [.cancelled, .completed])
        await player.stop()
        await player2.stop()
    }
}
