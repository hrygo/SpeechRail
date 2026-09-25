import Foundation
import SpeechRailControlKit

/// 一轮增量 utterance 的状态机：**文本进、PCM 出、打断即作废**。
///
/// 它拥有 `requestID`、append 序号、`inputClosed`、终态、播放排空和 `generation`；
/// `AssistantSession` 只负责 LLM、history 与落库，不再自己切句、排队、逐句提交。
///
/// 三条不许打折的规则：
///
///   1. **一轮一次 start、一次 finish**：LLM 结束事件不能越过还没 ACK 的文本提前 finish；
///   2. **旧代一律隔离**：`started` / ACK / audio / done 都带身份，不匹配就整条丢弃，
///      旧 `done` 不许清掉新一轮的状态；
///   3. **暂时排空 ≠ 整轮结束**：只有"服务端终态 + 本代音频排空"才回报 `.completed`。
///
/// 所有外部依赖（发送、停播、入队、时钟、休眠）都是注入的，纯测试里不碰硬件。
@MainActor
final class AssistantTTSStreamCoordinator {
    struct Configuration {
        var textBuffer = AssistantSpeechTextBuffer.Configuration()
        var playbackLedger = AssistantPlaybackLedger.Configuration()
        /// 文本泵的轮询间隔：等 deadline 的粒度，不是音频延迟。
        var tickInterval: Duration = .milliseconds(30)
        /// 连续多少轮取不到可切前缀就强制切（防止永不闭合的 Markdown 卡住整轮）。
        var maximumIdleTicks = 20
        /// 等 `started` / 等 ACK 的上限。
        var acknowledgementTimeout: Duration = .seconds(5)
        /// 播放队列满时的等待上限，超过就明确失败，不无限积压。
        var playbackWaitTimeout: Duration = .seconds(2)

        static let `default` = Configuration()
    }

    enum Outcome: Equatable, Sendable {
        case completed
        case cancelled
        case failed(String)
    }

    enum Failure: LocalizedError, Equatable {
        case startTimedOut
        case acknowledgementTimedOut(Int)
        case server(String)
        case playbackBackpressure(queuedSamples: Int)
        case textLimitExceeded

        var errorDescription: String? {
            switch self {
            case .startTimedOut:
                "语音服务没有在期限内确认开始这一轮朗读。"
            case .acknowledgementTimedOut(let sequence):
                "语音服务没有确认第 \(sequence) 段文本。"
            case .server(let message):
                message
            case .playbackBackpressure(let queuedSamples):
                "播放跟不上（还有 \(queuedSamples) 个采样没播），这一轮已经停下。"
            case .textLimitExceeded:
                "这一轮要朗读的文本超出了服务端允许的上限。"
            }
        }
    }

    // MARK: - 注入

    var sendStart: @MainActor (String) async throws -> Void = { _ in }
    var sendAppend: @MainActor (Int, String) async throws -> Void = { _, _ in }
    var sendFinish: @MainActor (Int) async throws -> Void = { _ in }
    var sendCancel: @MainActor () async throws -> Void = {}
    /// 返回 `false` 表示这一块没有真的进播放队列，预算必须原样还回去。
    var enqueuePlayback: @MainActor (Data) async -> Bool = { _ in true }
    var stopPlayback: @MainActor () async -> Void = {}
    /// 朗读前的清洗（去掉 Markdown、把符号念成词）。返回空串表示这一段不用发声，
    /// 既不占序号也不占预算。
    var cleanForSpeech: @MainActor (String) -> String = { $0 }
    /// 终态只回报一次：`(generation, outcome)`。
    var onOutcome: @MainActor (Int, Outcome) -> Void = { _, _ in }
    var clock: @MainActor () -> ContinuousClock.Instant = { ContinuousClock().now }
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    // MARK: - 状态

    private let configuration: Configuration
    private var buffer: AssistantSpeechTextBuffer
    private var ledger: AssistantPlaybackLedger

    private(set) var generation = -1
    private(set) var requestID: String?
    /// `speechrail.tts.started.task_id`：服务端为这一轮分配的稳定身份，只用于诊断。
    private(set) var taskID: String?
    private(set) var acceptedSequence = -1
    private(set) var acceptedCodepoints = 0
    private(set) var inputClosed = false
    private(set) var outcome: Outcome?
    private(set) var serverLimits: TTSStreamLimits?
    private(set) var lastFailure: String?

    private var finishRequested = false
    private var finishSent = false
    private var pumpTask: Task<Void, Never>?
    private var pendingWait: PendingWait?
    private var prefetched: [WaitTarget: WaitResult] = [:]

    init(configuration: Configuration = .default) {
        self.configuration = configuration
        self.buffer = AssistantSpeechTextBuffer(configuration: configuration.textBuffer)
        self.ledger = AssistantPlaybackLedger(configuration: configuration.playbackLedger)
    }

    var isActive: Bool { requestID != nil && outcome == nil }
    var isDrained: Bool { ledger.isDrained }
    var queuedSamples: Int { ledger.queuedSamples }
    var pendingTextScalars: Int { buffer.pendingScalars }
    /// 服务端终态到了、但本代音频可能还在播。
    var isAwaitingPlayback: Bool { ledger.serverTerminal && !ledger.isDrained }
    var terminalStatus: String? { ledger.terminalStatus }
    var offeredScalars: Int { buffer.offeredScalars }

    // MARK: - 上行

    /// 开始一轮。返回即表示服务端已确认 `speechrail.tts.started`。
    func begin(generation: Int, requestID: String, speed: Double? = nil) async throws {
        invalidate()
        self.generation = generation
        self.requestID = requestID
        self.outcome = nil
        self.serverLimits = nil
        self.acceptedSequence = -1
        self.acceptedCodepoints = 0
        self.inputClosed = false
        self.finishRequested = false
        self.finishSent = false
        self.buffer.reset()
        self.ledger.begin(generation: generation)
        do {
            try await sendStart(requestID)
        } catch {
            let message = error.localizedDescription
            invalidate()
            throw Failure.server(message)
        }
        let result = await wait(for: .started, timeout: configuration.acknowledgementTimeout)
        switch result {
        case .satisfied:
            return
        case .timedOut:
            fail(Failure.startTimedOut)
            throw Failure.startTimedOut
        case .cancelled:
            throw Failure.server("这一轮已经被打断。")
        case .failed(let message):
            fail(Failure.server(message))
            throw Failure.server(message)
        }
    }

    /// LLM 又给了一段增量文本。**同步返回**：文本泵自己异步发送，不阻塞 LLM 流。
    func offer(_ delta: String) {
        guard isActive else { return }
        if let limit = buffer.append(delta) {
            switch limit {
            case .append(let offered, let max), .total(let offered, let max):
                fail(Failure.server("这一轮要朗读的文本超出上限（\(offered) > \(max)）。"))
                return
            }
        }
        ensurePump()
    }

    /// LLM 结束：冲刷剩余文本、发 `finish_text`，并等文本泵收工。
    /// **不会越过还没 ACK 的文本**——泵把每一段都等到 ACK 才继续。
    func finishInput() async {
        guard isActive else { return }
        finishRequested = true
        ensurePump()
        let task = pumpTask
        await task?.value
    }

    /// 打断/收尾：本地立刻作废这一代（旧包不再进播放），再取消服务端。
    func cancel() async {
        guard requestID != nil else { return }
        let generation = self.generation
        invalidate()
        stopPlaybackNow()
        do {
            try await sendCancel()
        } catch {
            // 取消失败不回滚本地状态：用户侧静音已经生效。
        }
        reportOutcome(.cancelled, generation: generation)
    }

    /// 只作废本地状态，不发网络命令（断线、设备重建时用）。
    func invalidate() {
        requestID = nil
        taskID = nil
        outcome = nil
        serverLimits = nil
        acceptedSequence = -1
        acceptedCodepoints = 0
        inputClosed = false
        finishRequested = false
        finishSent = false
        buffer.reset()
        ledger.invalidate()
        pumpTask?.cancel()
        pumpTask = nil
        releaseWaiters(.cancelled)
        prefetched.removeAll()
    }

    // MARK: - 下行（由唯一的 receive loop 转发）

    @discardableResult
    func handleStarted(requestID: String, taskID: String?, limits: TTSStreamLimits?) -> Bool {
        guard isActive, requestID == self.requestID else { return false }
        self.taskID = taskID
        self.serverLimits = limits
        resolve(.started, .satisfied)
        return true
    }

    @discardableResult
    func handleTextAccepted(
        requestID: String,
        appendSequence: Int,
        totalCodepoints: Int
    ) -> Bool {
        guard isActive,
              requestID == self.requestID,
              appendSequence == acceptedSequence + 1
        else { return false }
        acceptedSequence = appendSequence
        acceptedCodepoints = totalCodepoints
        resolve(.acknowledgement(appendSequence), .satisfied)
        return true
    }

    func handleAudio(requestID: String, pcm: Data) async {
        guard isActive, requestID == self.requestID else { return }
        let samples = pcm.count / MemoryLayout<Int16>.size
        guard samples > 0 else { return }
        guard await awaitPlaybackBudget(samples: samples) else { return }
        guard ledger.reserve(samples: samples) else { return }
        guard await enqueuePlayback(pcm) else {
            // 没进队列就别占着预算，否则这一轮会一直等一块永远播不完的音频。
            _ = ledger.complete(samples: samples, generation: ledger.generation)
            return
        }
    }

    func handleTerminal(requestID: String, status: String) async {
        guard isActive, requestID == self.requestID else { return }
        releaseWaiters(.failed("服务端结束了这一轮。"))
        ledger.markServerTerminal(status: status, generation: generation)
        switch status {
        case "cancelled":
            report(.cancelled)
        case "completed":
            // 音频可能还在播：只有本代排空才算整轮结束。
            if ledger.isDrained { report(.completed) }
        default:
            report(.failed(lastFailure ?? "服务端返回 \(status)。"))
        }
    }

    func handleServerError(requestID: String?, code: String, message: String) async {
        guard isActive else { return }
        if let requestID, requestID != self.requestID { return }
        let text = "\(code)：\(message)"
        lastFailure = text
        releaseWaiters(.failed(text))
        fail(Failure.server(text))
    }

    /// 播放器报"这一块真的播完了"（`dataRendered` 语义）。旧代 completion 不污染新状态。
    func notePlaybackCompleted(samples: Int) {
        guard ledger.complete(samples: samples, generation: ledger.generation) else { return }
        resolve(.playback, .satisfied)
        if ledger.isUtteranceFinished {
            report(.completed)
        }
    }

    /// 播放通道自己失败了（路由重建、引擎起不来）：这一轮不能假装播完。
    func notePlaybackFailure(_ message: String) {
        guard isActive else { return }
        fail(Failure.server(message))
    }

    // MARK: - 文本泵

    private func ensurePump() {
        guard pumpTask == nil, isActive else { return }
        pumpTask = Task { @MainActor [weak self] in
            await self?.runPump()
        }
    }

    private func runPump() async {
        var idleTicks = 0
        while !Task.isCancelled, isActive {
            if finishRequested {
                for chunk in buffer.flush(now: clock()) {
                    guard isActive, !Task.isCancelled else { return }
                    guard await sendChunk(chunk) else { return }
                }
                await sendFinishIfNeeded()
                return
            }
            let chunks = buffer.readyChunks(
                now: clock(),
                force: idleTicks >= configuration.maximumIdleTicks
            )
            if chunks.isEmpty {
                idleTicks += 1
                do {
                    try await sleep(configuration.tickInterval)
                } catch {
                    return
                }
                continue
            }
            idleTicks = 0
            for chunk in chunks {
                guard isActive, !Task.isCancelled else { return }
                guard await sendChunk(chunk) else { return }
            }
        }
    }

    private func sendChunk(_ rawChunk: String) async -> Bool {
        guard isActive else { return false }
        let text = cleanForSpeech(rawChunk)
        guard !text.isEmpty else { return true }
        let sequence = acceptedSequence + 1
        let limit = serverLimits?.maxAppendCodepoints ?? TTSStreamLimits.serverDefaults.maxAppendCodepoints
        guard text.unicodeScalars.count <= limit else {
            fail(Failure.textLimitExceeded)
            return false
        }
        do {
            try await sendAppend(sequence, text)
        } catch {
            fail(Failure.server(error.localizedDescription))
            return false
        }
        let result = await wait(for: .acknowledgement(sequence), timeout: configuration.acknowledgementTimeout)
        switch result {
        case .satisfied:
            return true
        case .timedOut:
            fail(Failure.acknowledgementTimedOut(sequence))
            return false
        case .cancelled:
            return false
        case .failed(let message):
            fail(Failure.server(message))
            return false
        }
    }

    private func sendFinishIfNeeded() async {
        guard isActive, !finishSent else { return }
        finishSent = true
        inputClosed = true
        ledger.markInputClosed()
        guard acceptedSequence >= 0 else {
            // 没有任何文本被 ACK：服务端要求 `last_sequence` 非负且等于最后一次 ACK，
            // 空输入没有可用的屏障，所以这一轮明确取消，而不是发一个必然被拒的 finish。
            fail(Failure.server("这一轮没有可朗读的文本，已经取消。"))
            return
        }
        do {
            try await sendFinish(acceptedSequence)
        } catch {
            fail(Failure.server(error.localizedDescription))
        }
    }

    private func awaitPlaybackBudget(samples: Int) async -> Bool {
        if ledger.canReserve(samples: samples) { return true }
        let generation = self.generation
        let startedAt = clock()
        while isActive, self.generation == generation, !ledger.canReserve(samples: samples) {
            let result = await wait(for: .playback, timeout: configuration.playbackWaitTimeout)
            switch result {
            case .satisfied:
                continue
            case .timedOut:
                fail(Failure.playbackBackpressure(queuedSamples: ledger.queuedSamples))
                return false
            case .cancelled:
                return false
            case .failed(let message):
                fail(Failure.server(message))
                return false
            }
        }
        guard isActive, self.generation == generation else { return false }
        if startedAt.duration(to: clock()) >= configuration.playbackWaitTimeout,
           !ledger.canReserve(samples: samples) {
            fail(Failure.playbackBackpressure(queuedSamples: ledger.queuedSamples))
            return false
        }
        return true
    }

    // MARK: - 终态与等待

    private func fail(_ failure: Failure) {
        guard isActive else { return }
        let message = failure.errorDescription ?? "这一轮朗读失败了。"
        lastFailure = message
        let cancel = sendCancel
        Task { @MainActor in try? await cancel() }
        report(.failed(message))
    }

    private func report(_ outcome: Outcome) {
        guard isActive else { return }
        reportOutcome(outcome, generation: generation)
    }

    private func reportOutcome(_ outcome: Outcome, generation: Int) {
        self.outcome = outcome
        pumpTask?.cancel()
        pumpTask = nil
        inputClosed = true
        releaseWaiters(outcome == .cancelled ? .cancelled : .failed("这一轮已经结束。"))
        prefetched.removeAll()
        stopPlaybackNow()
        onOutcome(generation, outcome)
    }

    private func stopPlaybackNow() {
        let stop = stopPlayback
        Task { @MainActor in await stop() }
    }

    private enum WaitTarget: Hashable {
        case started
        case acknowledgement(Int)
        case playback
    }

    private enum WaitResult: Equatable {
        case satisfied
        case cancelled
        case timedOut
        case failed(String)
    }

    private struct PendingWait {
        let target: WaitTarget
        let generation: Int
        let timeoutTask: Task<Void, Never>
        let continuation: CheckedContinuation<WaitResult, Never>
    }

    private func wait(for target: WaitTarget, timeout: Duration) async -> WaitResult {
        if let prefetched = prefetched.removeValue(forKey: target) { return prefetched }
        let generation = self.generation
        return await withCheckedContinuation { continuation in
            let timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.resolve(target, .timedOut, generation: generation)
            }
            pendingWait = PendingWait(
                target: target,
                generation: generation,
                timeoutTask: timeoutTask,
                continuation: continuation
            )
        }
    }

    private func resolve(_ target: WaitTarget, _ result: WaitResult) {
        resolve(target, result, generation: generation)
    }

    private func resolve(_ target: WaitTarget, _ result: WaitResult, generation: Int) {
        guard generation == self.generation else { return }
        if let pending = pendingWait, pending.target == target, pending.generation == generation {
            pendingWait = nil
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: result)
            return
        }
        // 事件比等待先到：只有幂等的目标值得预存，playback 进度不预存
        // （否则会被下一个人当成"已经等到过"，空转一圈）。
        if target != .playback {
            prefetched[target] = result
        }
    }

    private func releaseWaiters(_ result: WaitResult) {
        guard let pending = pendingWait else {
            prefetched.removeAll()
            return
        }
        pendingWait = nil
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: result)
        prefetched.removeAll()
    }
}
