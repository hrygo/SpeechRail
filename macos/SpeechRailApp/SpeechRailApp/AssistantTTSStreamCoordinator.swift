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
    /// `cancelServerBounded()` 里两个竞速任务的句柄，见该函数注释。
    private var serverCancelTasks: [Task<Void, Never>] = []
    /// 正在等"服务端确认这一轮终止"的闩,按 requestID 索引(D06)。
    /// 它们属于**已经作废**的 utterance,所以不参与 `isActive` 那套状态。
    private var retiredTerminals: [String: TerminalLatch] = [:]
    /// 终态先于等待到达时先记下来:取消命令与服务端终态可以赛跑,
    /// 谁先到都不能让这一轮被判成"没收到终态"。
    private var terminalSignals: Set<String> = []
    /// 已经作废、但 `awaitRemoteTerminal` 还没挂上闩的那一小段窗口。
    private var retiringRequests: Set<String> = []
    private var retiredTimeoutTasks: [String: Task<Void, Never>] = [:]

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
    ///
    /// 上一轮的**远端空闲屏障还没解除**时拒绝开新一轮（方案 S4 第 11 条）：
    /// 悄悄 `invalidate()` 掉旧的一轮，会让两个 `request_id` 在服务端并存，
    /// 账本、终态和「谁在说话」全部对不上。这种情况要显式失败，
    /// 由上层去关连接重连，而不是在这里假装没事。
    ///
    /// 判据是"屏障已经挂上闩"，不是"本地取消还没跑完"：后者只是本地顺序，
    /// 远端归属尚未被问，前一轮随时可以被本地顶替。
    func begin(generation: Int, requestID: String, speed: Double? = nil) async throws {
        guard retiredTerminals.isEmpty else {
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
    /// 顺序是有意的：`invalidate()` 先推进 epoch 并清空本地排队预算，然后 `await` 停播
    /// （返回即表示播放层已经丢下旧代缓冲），最后才发网络取消。后端取消超时或失败都
    /// 不回滚本地静音，也不把旧音放回来。
    /// - Returns: 服务端是否已经在有界时间内**确认**这一轮终止。
    ///   `false` 只表示"取消命令发出去了，但没等到匹配 requestID 的终态"。
    ///   调用方据此不得在同一条连接上直接开下一轮：要么关连接重连，
    ///   要么进入可重试的语音中断（方案 S4 第 12 条）。
    @discardableResult
    func cancel() async -> Bool {
        guard let retiring = requestID else { return true }
        let logicalGeneration = self.generation
        invalidate()
        // 记下作废后的 epoch：跨过下面的 await 之后只有它还是当前这一轮，
        // 才允许把结局写回去（旧取消完成得再晚也不能改写新一轮）。
        let epoch = self.utteranceEpoch
        // 登记必须在 invalidate 之后：invalidate 会清场。
        // 这中间的 await 里终态可能先到，`handleTerminal` 据此把它记进 terminalSignals。
        retiringRequests.insert(retiring)
        await stopPlayback()
        await cancelServerBounded()
        // `cancelTTS()` 返回只代表**发送完成**，不是服务端腾出了这一轮。
        // 真正的空闲屏障是匹配 requestID 的终态。
        let confirmed = await awaitRemoteTerminal(for: retiring)
        reportOutcome(
            .cancelled,
            generation: logicalGeneration,
            epoch: epoch,
            playbackAlreadyStopped: true
        )
        return confirmed
    }

    /// 只作废本地状态，不发网络命令（断线、设备重建时用）。
    func invalidate() {
        advanceEpoch()
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
        // 作废这一代时，已经发出去但还没收尾的活一并收掉，别让它们跨世代残留。
        for task in fireAndForgetTasks {
            task.cancel()
        }
        fireAndForgetTasks.removeAll()
        for task in serverCancelTasks {
            task.cancel()
        }
        serverCancelTasks.removeAll()
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
        guard await enqueuePlayback(pcm, utteranceEpoch) else {
            // 没进队列就别占着预算，否则这一轮会一直等一块永远播不完的音频。
            _ = ledger.complete(samples: samples, generation: utteranceEpoch)
            return
        }
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
        guard isActive, requestID == self.requestID else { return }
        releaseWaiters(.failed("服务端结束了这一轮。"))
        ledger.markServerTerminal(status: status, generation: utteranceEpoch)
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

    /// 播放器报"这一块真的播完了"（`dataRendered` 语义）。
    /// `epoch` 是入队时交给播放层的身份：**旧代的迟到回调必须整条丢掉**，
    /// 否则它会把新一轮的排队预算当成自己的还掉，让整轮提前宣布播完。
    func notePlaybackCompleted(samples: Int, epoch: Int) {
        guard ledger.complete(samples: samples, generation: epoch) else { return }
        resolve(WaitKey(epoch: epoch, target: .playback), .satisfied)
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

    // MARK: - 终态与等待

    private func fail(_ failure: Failure) {
        guard isActive else { return }
        let message = failure.errorDescription ?? "这一轮朗读失败了。"
        lastFailure = message
        let cancel = sendCancel
        trackFireAndForget { try? await cancel() }
        report(.failed(message))
    }

    private func report(_ outcome: Outcome) {
        guard isActive else { return }
        reportOutcome(outcome, generation: generation, epoch: utteranceEpoch)
    }

    private func reportOutcome(
        _ outcome: Outcome,
        generation: Int,
        epoch: Int,
        playbackAlreadyStopped: Bool = false
    ) {
        // 跨越 await 的旧操作回来时可能已经换了一轮：不许写进新一轮的结局。
        guard epoch == utteranceEpoch else { return }
        self.outcome = outcome
        pumpTask?.cancel()
        pumpTask = nil
        inputClosed = true
        releaseWaiters(outcome == .cancelled ? .cancelled : .failed("这一轮已经结束。"))
        prefetched.removeAll()
        if !playbackAlreadyStopped { stopPlaybackNow() }
        onOutcome(generation, outcome)
    }

    private func stopPlaybackNow() {
        let stop = stopPlayback
        trackFireAndForget { await stop() }
    }

    /// 启动一个不阻塞调用方的异步工作，但**保留句柄**，好让 `invalidate()` 能收掉它。
    private func trackFireAndForget(_ operation: @escaping @MainActor () async -> Void) {
        fireAndForgetTasks.removeAll { $0.isCancelled }
        fireAndForgetTasks.append(Task { @MainActor in await operation() })
    }

    /// 等后端确认取消，但**有上限**：后端不回话时不能把打断吊在这里。
    /// 超时只是不再等回执，本地静音与作废已经从 `invalidate()` 起生效。
    private func cancelServerBounded() async {
        let send = sendCancel
        let timeout = configuration.cancellationTimeout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let latch = CompletionLatch(continuation)
            serverCancelTasks = [
                Task { @MainActor in
                    try? await send()
                    latch.finish()
                },
                Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    latch.finish()
                },
            ]
        }
        // 闩只放行一次，所以两个竞速任务里**必定**还有一个没结束。这里立刻取消并清空
        // 句柄：以前它们是无句柄的 `Task { }`，每次取消都会漏一个（后端不回话时那个
        // 会一直挂到进程结束）。
        for task in serverCancelTasks {
            task.cancel()
        }
        serverCancelTasks.removeAll()
    }

    /// 只放行一次的等待闩：网络回执与超时谁先到都只 resume 一次。
    @MainActor
    private final class CompletionLatch {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func finish() {
            let pending = continuation
            continuation = nil
            pending?.resume()
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
            let id = UUID()
            let timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                // 超时按 ID 精确命中：同一目标可能已经注册了新的 waiter。
                self?.resolve(key, .timedOut, waiterID: id)
            }
            waiters[key] = Waiter(
                id: id,
                timeoutTask: timeoutTask,
                continuation: continuation
            )
            // 封闭"取消先于注册"的窗口：注册本身不让出执行权，
            // 所以再确认一次当前世代与取消状态就够了。
            if !isActive || key.epoch != utteranceEpoch || Task.isCancelled {
                resolve(key, .cancelled, waiterID: id)
            }
        }
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

    private func releaseWaiters(_ result: WaitResult) {
        // 先整体摘下再逐个唤醒：resume 之后对方可能同步改集合。
        let pending = waiters
        waiters.removeAll()
        prefetched.removeAll()
        for waiter in pending.values {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: result)
        }
    }
}
