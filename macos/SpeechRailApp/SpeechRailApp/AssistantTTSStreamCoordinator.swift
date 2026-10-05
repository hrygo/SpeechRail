import Foundation
import SpeechRailControlKit

/// 一轮增量 utterance 的状态机：**文本进、PCM 出、打断即作废**。
///
/// 它拥有 `requestID`、append 序号、`inputClosed`、终态、播放排空和 `generation`；
/// `AssistantSession` 只负责 LLM、history 与落库，不再自己切句、排队、逐句提交。
///
/// 四条不许打折的规则：
///
///   1. **一轮一次 start、一次 finish**：LLM 结束事件不能越过还没 ACK 的文本提前 finish；
///   2. **旧代一律隔离**：`started` / ACK / audio / done 都带身份，不匹配就整条丢弃，
///      旧 `done` 不许清掉新一轮的状态；
///   3. **暂时排空 ≠ 整轮结束**：只有"服务端终态 + 本代音频排空"才回报 `.completed`。
///   4. **打断先停播、再取消网络**：本地作废 epoch 并清空排队预算 → await 停播屏障 →
///      才发 `cancel`；后端取消超时/失败都不恢复旧音，迟到的 `dataRendered` 由 epoch 丢弃。
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
        /// 停播屏障落地之后，等后端确认取消的上限；超时也不回滚本地静音。
        var cancellationTimeout: Duration = .seconds(2)
        /// 本轮收到但尚未消费的 PCM 总上限，包含 FIFO、在途 enqueue 和播放器。
        /// 通过 start.audio_window_bytes 声明，由消费回调归还额度。
        var maximumPendingAudioBytes = SpeechRailTTSStart.maximumAudioWindowBytes

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
        case audioBackpressure(pendingBytes: Int, incomingBytes: Int, maximumBytes: Int)
        case playbackEnqueueFailed
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
            case .audioBackpressure(let pendingBytes, let incomingBytes, let maximumBytes):
                "音频缓冲超出上限（\(pendingBytes) + \(incomingBytes) > \(maximumBytes) bytes），这一轮已经停下。"
            case .playbackEnqueueFailed:
                "音频没有进入播放队列，这一轮已经停下。"
            case .textLimitExceeded:
                "这一轮要朗读的文本超出了服务端允许的上限。"
            }
        }
    }

    enum AudioAdmissionResult: Equatable {
        case accepted
        case ignored
        case rejected
    }

    /// 一个已同步撤销本地输出权、等待远端取消确认的 request。
    /// Session 可先调用 `prepareCancellation()`，再把该对象交给异步 effect Task。
    @MainActor
    final class CancellationPreparation {
        fileprivate let requestID: String
        fileprivate let generation: Int
        fileprivate let epoch: Int
        fileprivate let finalOutcome: Outcome
        fileprivate let audioConsumerAtPreparation: Task<Void, Never>?
        fileprivate let outboundTaskID: UUID?
        fileprivate var effectTask: Task<Bool, Never>?
        fileprivate var result: Bool?
        fileprivate var outcomeReported = false

        fileprivate init(
            requestID: String,
            generation: Int,
            epoch: Int,
            finalOutcome: Outcome,
            audioConsumerAtPreparation: Task<Void, Never>?,
            outboundTaskID: UUID?
        ) {
            self.requestID = requestID
            self.generation = generation
            self.epoch = epoch
            self.finalOutcome = finalOutcome
            self.audioConsumerAtPreparation = audioConsumerAtPreparation
            self.outboundTaskID = outboundTaskID
        }
    }

    private struct RetiredOutboundTask {
        let requestID: String
        let task: Task<Void, Never>
    }

    private struct PendingAudio {
        let id: UUID
        let requestID: String
        let epoch: Int
        let pcm: Data
        let samples: Int
    }

    // MARK: - 注入

    var sendStart: @MainActor (String) async throws -> Void = { _ in }
    var sendAppend: @MainActor (Int, String) async throws -> Void = { _, _ in }
    var sendFinish: @MainActor (Int) async throws -> Void = { _ in }
    var sendCancel: @MainActor () async throws -> Void = {}
    var sendAudioAcknowledgement: @MainActor (String, Int) async throws -> Void = { _, _ in }
    /// 入队一块音频，第二个参数是**这一块所属的账本 epoch**：播放层必须在"真的播完"
    /// 的回调里把它原样带回，迟到块才可能被识别出来。
    /// 返回 `false` 表示这一块没有真的进播放队列，预算必须原样还回去。
    var enqueuePlayback: @MainActor (Data, Int) async -> Bool = { _, _ in true }
    var stopPlayback: @MainActor () async -> Void = {}
    /// 朗读前的清洗（去掉 Markdown、把符号念成词）。返回空串表示这一段不用发声，
    /// 既不占序号也不占预算。
    var cleanForSpeech: @MainActor (String) -> String = { $0 }
    /// 终态只回报一次：`(generation, outcome)`。
    var onOutcome: @MainActor (Int, Outcome) -> Void = { _, _ in }
    var clock: @MainActor () -> ContinuousClock.Instant = { ContinuousClock().now }
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Deadline timing is separate from the text pump's pacing.
    var timeoutSleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    // MARK: - 状态

    private let configuration: Configuration
    private var buffer: AssistantSpeechTextBuffer
    private var ledger: AssistantPlaybackLedger
    private var pendingAudio: [PendingAudio] = []
    /// Includes both FIFO entries and the head currently awaiting playback budget/enqueue.
    private var pendingAudioBytes = 0
    private var audioConsumerTask: Task<Void, Never>?
    private var audioConsumerID: UUID?
    private var audioAcknowledgementTaskID: UUID?
    private var consumedSampleOffset = 0
    private var sentConsumptionOffset = 0
    private(set) var unconsumedAudioBytes = 0

    private(set) var generation = -1
    private(set) var requestID: String?
    /// `speechrail.tts.started.task_id`：服务端为这一轮分配的稳定身份，只用于诊断。
    private(set) var taskID: String?
    /// VA-05：当前 request 身份的可读投影。编排层用它先校验
    /// connection/request 再改 speaking/闭麦与 phase。
    var currentRequestID: String? { requestID }
    /// VA-05：是否为已作废、正在等终态的 request（retired）。
    /// retired 只解自己的闩；unknown 不改 phase/error。
    func isKnownRetiredRequest(_ id: String) -> Bool {
        retiredTerminals[id] != nil
            || retiringRequests.contains(id)
            || unknownRemoteOwnership.contains(id)
            || retiredOutboundTasks.values.contains { $0.requestID == id }
    }
    /// 是否仍有一个取消中的 request，或远端 ownership 尚未确认。
    var hasUnconfirmedRemoteOwnership: Bool {
        !retiringRequests.isEmpty
            || !retiredTerminals.isEmpty
            || !unknownRemoteOwnership.isEmpty
            || !retiredOutboundTasks.isEmpty
    }
    private(set) var acceptedSequence = -1
    private(set) var acceptedCodepoints = 0
    private(set) var inputClosed = false
    private(set) var outcome: Outcome?
    private(set) var serverLimits: TTSStreamLimits?
    private(set) var lastFailure: String?

    private var finishRequested = false
    private var finishSent = false
    private var pumpTask: Task<Void, Never>?
    private var pumpTaskID: UUID?
    /// Cancellation timeout cannot discard an outbound task that may still send later.
    /// Its completion removes only its own ID, never a newer pump's ownership.
    private var retiredOutboundTasks: [UUID: RetiredOutboundTask] = [:]
    private var outboundExitWaiters: [UUID: OutboundExitLatch] = [:]
    /// 单调递增的**物理**播放身份。`generation` 是"第几轮回复"的逻辑身份（重播会重复），
    /// epoch 是"第几次真正开嗓"：迟到回调只认 epoch，所以重播不会被上一轮的
    /// `dataRendered` 误清账。
    private var utteranceEpoch = 0
    /// 等待者按 `(epoch, target)` 分槽。共用单个槽位时，ACK 等待与播放预算等待会互相覆盖，
    /// 被覆盖的 continuation 永远没人唤醒（`SWIFT TASK CONTINUATION MISUSE`）。
    private var waiters: [WaitKey: Waiter] = [:]
    private var prefetched: [WaitKey: WaitResult] = [:]
    /// 「发出去就不管」的异步工作的句柄。`invalidate()` 负责把它们收掉：
    /// 没有句柄的 `Task { }` 一旦遇上不返回的依赖（挂死的网络取消、停不下的播放层）
    /// 就会永远留在进程里，既回收不了内存也挡不住后续世代。
    private var fireAndForgetTasks: [Task<Void, Never>] = []
    /// 正在等"服务端确认这一轮终止"的闩,按 requestID 索引(D06)。
    /// 它们属于**已经作废**的 utterance,所以不参与 `isActive` 那套状态。
    private var retiredTerminals: [String: TerminalLatch] = [:]
    /// 终态先于等待到达时先记下来:取消命令与服务端终态可以赛跑,
    /// 谁先到都不能让这一轮被判成"没收到终态"。
    private var terminalSignals: Set<String> = []
    /// 已经作废、但 `awaitRemoteTerminal` 还没挂上闩的那一小段窗口。
    private var retiringRequests: Set<String> = []
    /// 超时后远端是否仍持有 request 未知；只由该 request 的迟到终态清除。
    private var unknownRemoteOwnership: Set<String> = []
    private var retiredTimeoutTasks: [String: Task<Void, Never>] = [:]
    /// 保留正在执行或已准备、尚未收尾的取消意图；重复调用返回同一对象。
    private var cancellationPreparations: [String: CancellationPreparation] = [:]

    init(configuration: Configuration = .default) {
        self.configuration = configuration
        self.buffer = AssistantSpeechTextBuffer(configuration: configuration.textBuffer)
        self.ledger = AssistantPlaybackLedger(configuration: configuration.playbackLedger)
    }

    var isActive: Bool { requestID != nil && outcome == nil }
    var isDrained: Bool {
        pendingAudio.isEmpty && audioConsumerTask == nil && ledger.isDrained
    }
    var queuedSamples: Int { ledger.queuedSamples }
    var queuedAudioBytes: Int { pendingAudioBytes }
    /// Client consumption capacity, independent of the worker's transport budget.
    var audioWindowBytes: Int {
        min(SpeechRailTTSStart.maximumAudioWindowBytes, max(0, configuration.maximumPendingAudioBytes))
    }
    var pendingTextScalars: Int { buffer.pendingScalars }
    /// 服务端终态到了、但本代音频可能还在播。
    var isAwaitingPlayback: Bool { ledger.serverTerminal && !isDrained }
    var terminalStatus: String? { ledger.terminalStatus }
    var offeredScalars: Int { buffer.offeredScalars }

    // MARK: - 上行

    /// 开始一轮。返回即表示服务端已确认 `speechrail.tts.started`。
    ///
    /// 上一轮的**远端空闲屏障还没解除**时拒绝开新一轮（方案 S4 第 11 条）：
    /// 悄悄 `invalidate()` 掉旧的一轮，会让两个 `request_id` 在服务端并存，
    /// 账本、终态和「谁在说话」全部对不上。这种情况要显式失败，
    /// 由上层去关连接重连，而不是在这里假装没事。
    ///
    /// 准备取消后直到匹配终态或超时，旧 request 都保持 retired，禁止在同连接开新轮。
    func begin(generation: Int, requestID: String, speed: Double? = nil) async throws {
        guard retiredTerminals.isEmpty,
              retiringRequests.isEmpty,
              unknownRemoteOwnership.isEmpty,
              retiredOutboundTasks.isEmpty,
              pumpTaskID == nil
        else {
            throw RemoteOwnershipUnknown()
        }
        invalidate()
        self.generation = generation
        self.utteranceEpoch = advanceEpoch()
        self.requestID = requestID
        self.outcome = nil
        self.serverLimits = nil
        self.acceptedSequence = -1
        self.acceptedCodepoints = 0
        self.inputClosed = false
        self.finishRequested = false
        self.finishSent = false
        self.buffer.reset()
        self.ledger.begin(generation: utteranceEpoch)
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

    /// 打断/收尾：本地立刻作废这一代（旧包不再进播放），**等停播屏障落地**，再取消服务端。
    ///
    /// 同步完成本地撤权并登记旧 request 的 retired ownership，不等待停播、网络或终态。
    /// 同一退役 request 的重复调用返回同一个 preparation，便于上层合并等待。
    func prepareCancellation() -> CancellationPreparation? {
        prepareCancellation(finalOutcome: .cancelled)
    }

    private func prepareCancellation(finalOutcome: Outcome) -> CancellationPreparation? {
        if let retiring = requestID {
            if let existing = cancellationPreparations[retiring] {
                return existing
            }
            let logicalGeneration = generation
            let pendingConsumer = audioConsumerTask
            let pendingOutboundID = retainCurrentPump(for: retiring)
            // 必须在控制权交给 effect Task 之前登记 retired，再清掉当前 request。
            retiringRequests.insert(retiring)
            invalidate()
            let preparation = CancellationPreparation(
                requestID: retiring,
                generation: logicalGeneration,
                epoch: utteranceEpoch,
                finalOutcome: finalOutcome,
                audioConsumerAtPreparation: pendingConsumer,
                outboundTaskID: pendingOutboundID
            )
            cancellationPreparations[retiring] = preparation
            return preparation
        }
        if let retiring = retiringRequests.first,
           let existing = cancellationPreparations[retiring] {
            return existing
        }
        return cancellationPreparations.values.first
    }

    /// 执行 preparation 对应的停播、网络取消与远端确认 effect。
    /// 重复执行会等待同一 effect，Bool 仅表示匹配 requestID 的终态是否已确认。
    @discardableResult
    func performCancellation(_ preparation: CancellationPreparation) async -> Bool {
        if let result = preparation.result { return result }
        if let effectTask = preparation.effectTask { return await effectTask.value }
        guard cancellationPreparations[preparation.requestID] === preparation else {
            return false
        }
        let effectTask = Task { @MainActor [weak self, preparation] in
            guard let self else { return false }
            return await self.runCancellation(preparation)
        }
        preparation.effectTask = effectTask
        let confirmed = await effectTask.value
        preparation.result = confirmed
        preparation.effectTask = nil
        if cancellationPreparations[preparation.requestID] === preparation {
            cancellationPreparations.removeValue(forKey: preparation.requestID)
        }
        return confirmed
    }

    /// 兼容直接异步调用的入口；新调用方应先同步 prepare，再安排异步 effect。
    @discardableResult
    func cancel() async -> Bool {
        guard let preparation = prepareCancellation() else {
            return !hasUnconfirmedRemoteOwnership
        }
        return await performCancellation(preparation)
    }

    private func runCancellation(_ preparation: CancellationPreparation) async -> Bool {
        // 先让已撤权的音频消费者退出，确保 stop barrier 之后不会再有旧 PCM 入播放器。
        await preparation.audioConsumerAtPreparation?.value
        await stopPlayback()
        let outboundExited: Bool
        if let outboundTaskID = preparation.outboundTaskID {
            outboundExited = await awaitOutboundExit(taskID: outboundTaskID)
        } else {
            outboundExited = true
        }
        // Do not let an in-flight append overtake cancel on the same connection.
        // If it misses the bounded exit deadline, the caller must retire the connection.
        let cancelExited = outboundExited
            ? await cancelServerBounded(requestID: preparation.requestID)
            : false
        // `cancelTTS()` 返回只代表**发送完成**，不是服务端腾出了这一轮。
        // 真正的空闲屏障是匹配 requestID 的终态。
        let remoteConfirmed = await awaitRemoteTerminal(for: preparation.requestID)
        if !preparation.outcomeReported {
            reportOutcome(
                preparation.finalOutcome,
                generation: preparation.generation,
                epoch: preparation.epoch,
                playbackStopOwnedByEffect: true
            )
            preparation.outcomeReported = true
        }
        return outboundExited && cancelExited && remoteConfirmed
    }

    /// 只作废本地状态，不发网络命令（断线、设备重建时用）。
    func invalidate() {
        if let requestID {
            _ = retainCurrentPump(for: requestID)
        }
        _ = advanceEpoch()
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
        _ = discardPendingAudio()
        unconsumedAudioBytes = 0
        consumedSampleOffset = 0
        sentConsumptionOffset = 0
        audioAcknowledgementTaskID = nil
        ledger.invalidate()
        pumpTask?.cancel()
        pumpTask = nil
        pumpTaskID = nil
        // 作废这一代时，已经发出去但还没收尾的活一并收掉，别让它们跨世代残留。
        for task in fireAndForgetTasks {
            task.cancel()
        }
        fireAndForgetTasks.removeAll()
        for outbound in retiredOutboundTasks.values {
            outbound.task.cancel()
        }
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

    @discardableResult
    func admitAudio(requestID: String, pcm: Data) -> AudioAdmissionResult {
        guard isActive, requestID == self.requestID else { return .ignored }
        let samples = pcm.count / MemoryLayout<Int16>.size
        guard samples > 0 else { return .ignored }
        guard samples <= ledger.maximumQueuedSamples else {
            fail(Failure.playbackBackpressure(queuedSamples: ledger.queuedSamples))
            return .rejected
        }
        let maximumBytes = audioWindowBytes
        let chunkLimit = min(
            serverLimits?.maxPendingAudioBytes ?? TTSStreamLimits.serverDefaults.maxPendingAudioBytes,
            TTSStreamLimits.serverDefaults.maxPendingAudioBytes
        )
        guard pcm.count <= maximumBytes,
              pcm.count <= chunkLimit,
              unconsumedAudioBytes <= maximumBytes - pcm.count
        else {
            fail(
                Failure.audioBackpressure(
                    pendingBytes: unconsumedAudioBytes,
                    incomingBytes: pcm.count,
                    maximumBytes: min(maximumBytes, chunkLimit)
                )
            )
            return .rejected
        }
        pendingAudio.append(
            PendingAudio(
                id: UUID(),
                requestID: requestID,
                epoch: utteranceEpoch,
                pcm: pcm,
                samples: samples
            )
        )
        pendingAudioBytes += pcm.count
        unconsumedAudioBytes += pcm.count
        ensureAudioConsumer()
        return .accepted
    }

    /// 旧调用入口保留 async 形态，但只做同步准入，不等播放预算或实际入队。
    func handleAudio(requestID: String, pcm: Data) async {
        _ = admitAudio(requestID: requestID, pcm: pcm)
    }

    func handleTerminal(requestID: String, status: String) async {
        // 已经被作废、正在等空闲屏障的那一轮:这里就是它等的那个终态。
        // 放在 `isActive` 判断之前——作废之后 `self.requestID` 已经是 nil,
        // 但这一轮的终态仍然必须把等待放行,否则打断会一直吊到超时。
        if let latch = retiredTerminals[requestID] {
            retiredTerminals.removeValue(forKey: requestID)
            retiredTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            retiringRequests.remove(requestID)
            latch.continuation.resume(returning: true)
            return
        }
        // 终态比等待先到：记下来，随后开始的等待直接命中，
        // 否则会白等一个完整超时，把"服务端其实早就确认了"误判成没确认。
        if retiringRequests.contains(requestID) {
            terminalSignals.insert(requestID)
            return
        }
        if unknownRemoteOwnership.remove(requestID) != nil {
            return
        }
        guard isActive, requestID == self.requestID else { return }
        releaseWaiters(.failed("服务端结束了这一轮。"), keepingPlayback: status == "completed")
        ledger.markServerTerminal(status: status, generation: utteranceEpoch)
        switch status {
        case "cancelled":
            report(.cancelled)
        case "completed":
            // 音频可能仍在 FIFO、等待入队或播放：三者全部排空才算整轮结束。
            reportCompletedIfDrained()
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

    /// 播放器报"这一块真的播完了"（`dataRendered` 语义）。
    /// `epoch` 是入队时交给播放层的身份：**旧代的迟到回调必须整条丢掉**，
    /// 否则它会把新一轮的排队预算当成自己的还掉，让整轮提前宣布播完。
    func notePlaybackCompleted(samples: Int, epoch: Int) {
        guard isActive, samples > 0, samples <= ledger.queuedSamples else { return }
        guard ledger.complete(samples: samples, generation: epoch) else { return }
        unconsumedAudioBytes -= samples * MemoryLayout<Int16>.size
        consumedSampleOffset += samples
        ensureAudioAcknowledgement()
        renewTextAcknowledgementDeadline(epoch: epoch)
        resolve(WaitKey(epoch: epoch, target: .playback), .satisfied)
        reportCompletedIfDrained()
    }

    /// 播放通道自己失败了（路由重建、引擎起不来）：这一轮不能假装播完。
    func notePlaybackFailure(_ message: String) {
        guard isActive else { return }
        fail(Failure.server(message))
    }

    // MARK: - 文本泵

    private func ensurePump() {
        guard pumpTask == nil, isActive else { return }
        let taskID = UUID()
        pumpTaskID = taskID
        pumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runPump()
            self.finishPump(taskID: taskID)
        }
    }

    private func finishPump(taskID: UUID) {
        finishRetiredOutboundTask(taskID: taskID)
        if pumpTaskID == taskID {
            pumpTaskID = nil
        }
    }

    private func retainCurrentPump(for requestID: String) -> UUID? {
        guard let taskID = pumpTaskID, let task = pumpTask else { return nil }
        retiredOutboundTasks[taskID] = RetiredOutboundTask(
            requestID: requestID,
            task: task
        )
        return taskID
    }

    private func startRetiredOutboundTask(
        requestID: String,
        taskID: UUID = UUID(),
        operation: @escaping @MainActor () async -> Void
    ) -> UUID {
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else {
                self?.finishRetiredOutboundTask(taskID: taskID)
                return
            }
            await operation()
            self?.finishRetiredOutboundTask(taskID: taskID)
        }
        retiredOutboundTasks[taskID] = RetiredOutboundTask(
            requestID: requestID,
            task: task
        )
        return taskID
    }

    private func finishRetiredOutboundTask(taskID: UUID) {
        retiredOutboundTasks.removeValue(forKey: taskID)
        if let waiter = outboundExitWaiters.removeValue(forKey: taskID) {
            waiter.finish(exited: true)
        }
    }

    private func awaitOutboundExit(taskID: UUID) async -> Bool {
        guard retiredOutboundTasks[taskID] != nil else { return true }
        let timeout = configuration.cancellationTimeout
        return await withCheckedContinuation { continuation in
            let waiterID = UUID()
            let waiter = OutboundExitLatch(id: waiterID, continuation: continuation)
            outboundExitWaiters[taskID] = waiter
            waiter.timeoutTask = Task { @MainActor [weak self, waiter] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard let self else {
                    waiter.finish(exited: false)
                    return
                }
                guard self.outboundExitWaiters[taskID]?.id == waiterID else { return }
                self.outboundExitWaiters.removeValue(forKey: taskID)
                waiter.finish(exited: false)
            }
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
        let epoch = self.utteranceEpoch
        let startedAt = clock()
        while isActive, self.utteranceEpoch == epoch, !ledger.canReserve(samples: samples) {
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
        guard isActive, self.utteranceEpoch == epoch else { return false }
        if startedAt.duration(to: clock()) >= configuration.playbackWaitTimeout,
           !ledger.canReserve(samples: samples) {
            fail(Failure.playbackBackpressure(queuedSamples: ledger.queuedSamples))
            return false
        }
        return true
    }

    /// One owned sender coalesces cumulative watermarks. It never blocks the
    /// receiver or creates a task per audio chunk, and retains request/epoch identity.
    private func ensureAudioAcknowledgement() {
        guard audioAcknowledgementTaskID == nil,
              isActive, !ledger.serverTerminal,
              let requestID, consumedSampleOffset > sentConsumptionOffset
        else { return }
        let epoch = utteranceEpoch
        let taskID = UUID()
        audioAcknowledgementTaskID = taskID
        _ = startRetiredOutboundTask(requestID: requestID, taskID: taskID) { [weak self] in
            guard let self else { return }
            defer {
                if self.audioAcknowledgementTaskID == taskID {
                    self.audioAcknowledgementTaskID = nil
                }
            }
            while !Task.isCancelled,
                  self.isActive, self.utteranceEpoch == epoch,
                  self.requestID == requestID, !self.ledger.serverTerminal {
                let offset = self.consumedSampleOffset
                guard offset > self.sentConsumptionOffset else { return }
                do {
                    try await self.sendAudioAcknowledgement(requestID, offset)
                } catch {
                    if self.isActive, self.utteranceEpoch == epoch {
                        self.fail(.server(error.localizedDescription))
                    }
                    return
                }
                guard self.utteranceEpoch == epoch else { return }
                self.sentConsumptionOffset = offset
            }
        }
    }

    /// Receiver admission only appends to a byte-bounded FIFO. One owned consumer
    /// waits for playback budget and performs enqueues in receiver order.
    private func ensureAudioConsumer() {
        guard audioConsumerTask == nil, isActive, !pendingAudio.isEmpty else { return }
        let consumerID = UUID()
        let epoch = utteranceEpoch
        audioConsumerID = consumerID
        audioConsumerTask = Task { @MainActor [weak self] in
            await self?.consumeAudio(consumerID: consumerID, epoch: epoch)
        }
    }

    private func consumeAudio(consumerID: UUID, epoch: Int) async {
        defer { finishAudioConsumer(consumerID: consumerID) }
        while !Task.isCancelled {
            guard audioConsumerID == consumerID,
                  isActive,
                  utteranceEpoch == epoch,
                  let chunk = pendingAudio.first
            else { return }
            guard chunk.requestID == requestID, chunk.epoch == epoch else {
                discardPendingAudioHead(id: chunk.id)
                continue
            }

            if !ledger.canReserve(samples: chunk.samples) {
                guard await awaitPlaybackBudget(samples: chunk.samples) else { return }
                continue
            }
            guard ledger.reserve(samples: chunk.samples) else { continue }

            let enqueued = await enqueuePlayback(chunk.pcm, chunk.epoch)
            // Cancellation can run while enqueuePlayback is suspended. The
            // cancellation effect joins this consumer before crossing stopPlayback.
            guard audioConsumerID == consumerID,
                  isActive,
                  utteranceEpoch == epoch,
                  requestID == chunk.requestID
            else { return }
            guard pendingAudio.first?.id == chunk.id else { return }

            discardPendingAudioHead(id: chunk.id)
            guard enqueued else {
                _ = ledger.complete(samples: chunk.samples, generation: chunk.epoch)
                fail(Failure.playbackEnqueueFailed)
                return
            }
        }
    }

    private func finishAudioConsumer(consumerID: UUID) {
        guard audioConsumerID == consumerID else { return }
        audioConsumerID = nil
        audioConsumerTask = nil
        reportCompletedIfDrained()
        if isActive, !pendingAudio.isEmpty {
            ensureAudioConsumer()
        }
    }

    private func discardPendingAudioHead(id: UUID) {
        guard pendingAudio.first?.id == id else { return }
        let removed = pendingAudio.removeFirst()
        pendingAudioBytes = max(0, pendingAudioBytes - removed.pcm.count)
    }

    /// Drops queued PCM and cancels the consumer; the returned task can be joined
    /// before the playback stop barrier so a late enqueue cannot follow that barrier.
    @discardableResult
    private func discardPendingAudio() -> Task<Void, Never>? {
        let task = audioConsumerTask
        task?.cancel()
        audioConsumerTask = nil
        audioConsumerID = nil
        pendingAudio.removeAll(keepingCapacity: false)
        pendingAudioBytes = 0
        return task
    }

    // MARK: - 终态与等待

    private func fail(_ failure: Failure) {
        guard isActive else { return }
        let message = failure.errorDescription ?? "这一轮朗读失败了。"
        lastFailure = message
        guard let preparation = prepareCancellation(finalOutcome: .failed(message)) else {
            report(.failed(message))
            return
        }
        // Surface the local failure now; the owned effect still performs
        // stop -> cancel -> matching-terminal confirmation before new TTS is allowed.
        preparation.outcomeReported = true
        reportOutcome(
            .failed(message),
            generation: preparation.generation,
            epoch: preparation.epoch,
            playbackStopOwnedByEffect: true
        )
        trackFireAndForget { [weak self] in
            guard let self else { return }
            _ = await self.performCancellation(preparation)
        }
    }

    private func report(_ outcome: Outcome) {
        guard isActive else { return }
        reportOutcome(outcome, generation: generation, epoch: utteranceEpoch)
    }

    private func reportCompletedIfDrained() {
        guard isActive,
              ledger.terminalStatus == "completed",
              isDrained
        else { return }
        report(.completed)
    }

    private func reportOutcome(
        _ outcome: Outcome,
        generation: Int,
        epoch: Int,
        playbackStopOwnedByEffect: Bool = false
    ) {
        // 跨越 await 的旧操作回来时可能已经换了一轮：不许写进新一轮的结局。
        guard epoch == utteranceEpoch else { return }
        if let requestID {
            _ = retainCurrentPump(for: requestID)
        }
        self.outcome = outcome
        unconsumedAudioBytes = 0
        pumpTask?.cancel()
        pumpTask = nil
        pumpTaskID = nil
        inputClosed = true
        releaseWaiters(outcome == .cancelled ? .cancelled : .failed("这一轮已经结束。"))
        prefetched.removeAll()
        let audioConsumer = discardPendingAudio()
        if case .failed = outcome {
            // No future callback from a failed playback generation may release
            // samples into a later request's ledger.
            ledger.invalidate()
        }
        if !playbackStopOwnedByEffect { stopPlaybackNow(after: audioConsumer) }
        onOutcome(generation, outcome)
    }

    private func stopPlaybackNow(after audioConsumer: Task<Void, Never>? = nil) {
        let stop = stopPlayback
        trackFireAndForget {
            await audioConsumer?.value
            await stop()
        }
    }

    /// 启动一个不阻塞调用方的异步工作，但**保留句柄**，好让 `invalidate()` 能收掉它。
    private func trackFireAndForget(_ operation: @escaping @MainActor () async -> Void) {
        fireAndForgetTasks.removeAll { $0.isCancelled }
        fireAndForgetTasks.append(Task { @MainActor in await operation() })
    }

    /// 等取消发送任务退出，但**有上限**：无响应的任务继续由 ownership map 保持。
    private func cancelServerBounded(requestID: String) async -> Bool {
        let send = sendCancel
        let taskID = startRetiredOutboundTask(requestID: requestID) {
            // The task may be cancelled before its MainActor job starts. Never let
            // such a stale cancellation reach a client that may now own a new TTS.
            guard !Task.isCancelled else { return }
            try? await send()
        }
        let exited = await awaitOutboundExit(taskID: taskID)
        if !exited {
            retiredOutboundTasks[taskID]?.task.cancel()
        }
        return exited
    }

    @MainActor
    private final class OutboundExitLatch {
        let id: UUID
        private var continuation: CheckedContinuation<Bool, Never>?
        var timeoutTask: Task<Void, Never>?

        init(id: UUID, continuation: CheckedContinuation<Bool, Never>) {
            self.id = id
            self.continuation = continuation
        }

        func finish(exited: Bool) {
            let pending = continuation
            continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            pending?.resume(returning: exited)
        }
    }

    // MARK: - 远端空闲屏障（D06 / S4 第 12 条）

    /// 等匹配 `requestID` 的**服务端终态**，而不是等"取消命令发出去"。
    ///
    /// 闩在 `handleTerminal`（Realtime 接收层）解锁，不在业务收尾这一侧：
    /// 业务等的是"服务端承认这一轮结束了",而这条终态本身必须由接收循环派发。
    /// 两者要是同一条任务,就是自己等自己——所以这里只挂一个 continuation,
    /// 解锁动作留在接收层。
    private func awaitRemoteTerminal(for requestID: String) async -> Bool {
        if terminalSignals.remove(requestID) != nil {
            retiringRequests.remove(requestID)
            return true
        }
        return await withCheckedContinuation { continuation in
            let id = UUID()
            retiredTerminals[requestID] = TerminalLatch(id: id, continuation: continuation)
            let timeout = configuration.cancellationTimeout
            retiredTimeoutTasks[requestID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveRemoteTerminal(requestID, id: id, confirmed: false)
            }
        }
    }

    /// 终态到了,或者等待超时。**先按 requestID + latch id 比对**:
    /// 迟到的超时不能把已经确认过的那一次等待改写成失败。
    private func resolveRemoteTerminal(_ requestID: String, id: UUID, confirmed: Bool) {
        guard let latch = retiredTerminals[requestID], latch.id == id else { return }
        retiredTerminals.removeValue(forKey: requestID)
        retiredTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        if !confirmed {
            unknownRemoteOwnership.insert(requestID)
        }
        retiringRequests.remove(requestID)
        latch.continuation.resume(returning: confirmed)
    }

    @MainActor
    private struct TerminalLatch {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// 上一轮在服务端的归属还没确认（取消已发出但没等到终态）。
    /// 调用方应把它当成"这条连接不能再开新一轮"的信号。
    struct RemoteOwnershipUnknown: Error, Equatable {}

    private enum WaitTarget: Hashable {
        case started
        case acknowledgement(Int)
        case playback
    }

    private struct WaitKey: Hashable {
        let epoch: Int
        let target: WaitTarget
    }

    private enum WaitResult: Equatable {
        case satisfied
        case cancelled
        case timedOut
        case failed(String)
    }

    private struct Waiter {
        let id: UUID
        let timeoutTask: Task<Void, Never>
        let continuation: CheckedContinuation<WaitResult, Never>
    }

    private func advanceEpoch() -> Int {
        utteranceEpoch += 1
        return utteranceEpoch
    }

    private func wait(for target: WaitTarget, timeout: Duration) async -> WaitResult {
        let key = WaitKey(epoch: utteranceEpoch, target: target)
        if let prefetched = prefetched.removeValue(forKey: key) { return prefetched }
        return await withCheckedContinuation { continuation in
            // 注册之前先看一眼：取消可能已经发生，别把 continuation 挂到作废的世代上。
            guard isActive, key.epoch == utteranceEpoch, !Task.isCancelled else {
                continuation.resume(returning: .cancelled)
                return
            }
            guard waiters[key] == nil else {
                // 同一世代的同一目标已经在等。覆盖它会让先来那个永远醒不过来，
                // 所以这里明确失败，而不是静默泄漏。
                assertionFailure("duplicate waiter for \(key)")
                continuation.resume(returning: .failed("这一轮已经在等同一个事件了。"))
                return
            }
            registerWaiter(key, timeout: timeout, continuation: continuation)
            // 封闭"取消先于注册"的窗口：注册本身不让出执行权，
            // 所以再确认一次当前世代与取消状态就够了。
            if !isActive || key.epoch != utteranceEpoch || Task.isCancelled {
                resolve(key, .cancelled)
            }
        }
    }

    private func registerWaiter(
        _ key: WaitKey, timeout: Duration,
        continuation: CheckedContinuation<WaitResult, Never>
    ) {
        let id = UUID()
        let sleep = timeoutSleep
        let timeoutTask = Task { @MainActor [weak self] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.waiters[key]?.id == id else { return }
            self.resolve(key, .timedOut, waiterID: id)
        }
        waiters[key] = Waiter(id: id, timeoutTask: timeoutTask, continuation: continuation)
    }

    /// Backend control frames may be behind already-produced audio on the vendor
    /// transport. Only genuine current playback progress renews the inactivity
    /// deadline; the real text ACK remains the sole sequence/finish barrier.
    private func renewTextAcknowledgementDeadline(epoch: Int) {
        let key = WaitKey(epoch: epoch, target: .acknowledgement(acceptedSequence + 1))
        guard epoch == utteranceEpoch, let waiter = waiters[key] else { return }
        waiter.timeoutTask.cancel()
        registerWaiter(
            key, timeout: configuration.acknowledgementTimeout, continuation: waiter.continuation
        )
    }

    private func resolve(_ target: WaitTarget, _ result: WaitResult) {
        resolve(WaitKey(epoch: utteranceEpoch, target: target), result)
    }

    private func resolve(
        _ key: WaitKey,
        _ result: WaitResult,
        waiterID: UUID? = nil
    ) {
        if let waiter = waiters[key] {
            if let waiterID, waiter.id != waiterID { return }
            waiters.removeValue(forKey: key)
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: result)
            return
        }
        // 事件比等待先到：只有幂等的目标值得预存，playback 进度不预存
        // （否则会被下一个人当成"已经等到过"，空转一圈），过期的 epoch 也不预存。
        guard key.epoch == utteranceEpoch, key.target != .playback else { return }
        prefetched[key] = result
    }

    private func releaseWaiters(_ result: WaitResult, keepingPlayback: Bool = false) {
        // 先整体摘下再逐个唤醒：resume 之后对方可能同步改集合。
        let pending = waiters.filter { !keepingPlayback || $0.key.target != .playback }
        for key in pending.keys { waiters.removeValue(forKey: key) }
        prefetched.removeAll()
        for waiter in pending.values {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: result)
        }
    }
}
