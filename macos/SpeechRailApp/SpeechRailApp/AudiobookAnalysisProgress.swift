import Foundation

/// 分析进度观测：闭式事件、快照投影与有界诊断缓冲。
///
/// 全书分析是分钟级的串行 LLM 长任务。管线在规划、提取、归并、标注与拆窗重试处
/// 发射 `AudiobookAnalysisEvent`；`AudiobookWorkflowModel` 把事件流收敛为
/// `AudiobookAnalysisProgress` 供界面渲染。事件字段是封闭集合：只带序号、计数、
/// 耗时、token 数与低基数错误码，不带原文、prompt、转写、密钥、绝对路径或实名。
public struct AudiobookAnalysisProgressSink: Sendable {
    public let emit: @Sendable (AudiobookAnalysisEvent) -> Void

    public init(emit: @escaping @Sendable (AudiobookAnalysisEvent) -> Void) {
        self.emit = emit
    }

    /// 默认丢弃全部事件：调用方不关心进度时管线行为与此前完全一致。
    public static var ignored: AudiobookAnalysisProgressSink {
        AudiobookAnalysisProgressSink { _ in }
    }
}

/// 进度观测的可调阈值（集中声明，避免散落魔法数）。
public enum AudiobookAnalysisProgressLimits {
    /// 开发者详情保留的最近事件数（内存环形缓冲，不落盘）。
    public static let eventBufferCapacity: Int = 200
    /// 无任何事件超过该秒数即判定为"等得比平时久"，界面弹 attention 横条。
    public static let stallWarningSeconds: TimeInterval = 60
    /// 单次 LLM 等待超过该秒数，界面把"正在等待"改成"仍在等待…"。
    public static let awaitingCallNoticeSeconds: TimeInterval = 20
}

public enum AudiobookAnalysisEventKind: String, Codable, Equatable, Hashable, Sendable {
    /// 本地规划与检查点比对完成，总窗口数与复用数已知，可切确定性轨道。
    case planned
    /// 正在等待一次 LLM 返回（提取 / 归并 / 标注）。
    case awaitingLLM
    /// 一个窗口的人物提取完成（含缓存命中，未必发生 LLM 调用）。
    case windowExtracted
    /// 一个归并 batch 完成。
    case castBatchMerged
    /// 一个窗口的标注落盘为检查点。
    case windowAnnotated
    /// 当前窗口解码或覆盖校验失败，已拆小重试。
    case retryingSplit
    /// 一次 LLM 调用的诊断回执（耗时 / token / 错误码），仅 live 链路发射。
    case llmCallFinished
    /// 本次 run 终态（完成 / 失败 / 取消）。
    case runEnded
}

public enum AudiobookAnalysisRunOutcome: String, Codable, Equatable, Hashable, Sendable {
    case completed
    case failed
    case cancelled
}

/// 单次进度事件。计数器每次带全量，投影侧只增不减；
/// `sequence` 是本 run 内的发射序号，投影侧用它丢弃乱序到达的过期事件。
public struct AudiobookAnalysisEvent: Codable, Equatable, Hashable, Sendable {
    /// 本次 run 的关联 ID（同时用作 LLM 观测的 sessionID，一串到底）。
    public var runID: String
    public var bookID: UUID
    public var sequence: Int
    public var kind: AudiobookAnalysisEventKind
    public var occurredAt: Date
    public var totalWindows: Int
    public var extractedWindows: Int
    public var mergeBatchesDone: Int
    public var mergeBatchesTotal: Int
    public var annotatedWindows: Int
    public var reusedCheckpointWindows: Int
    /// 当前章节序号（1-based 展示用）。
    public var currentChapterOrdinal: Int?
    /// 当前窗口序号（1-based 展示用）。
    public var currentWindowOrdinal: Int?
    /// 本窗累计 LLM 调用次数（缓存命中为 0）。
    public var attempt: Int
    public var maxAttempts: Int
    public var elapsedMilliseconds: Int?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var reasoningTokens: Int?
    /// 低基数错误码（见 `AudiobookAnalysisErrorCode`），无原文。
    public var errorCode: String?
    public var outcome: AudiobookAnalysisRunOutcome?

    public init(
        runID: String,
        bookID: UUID,
        sequence: Int = 0,
        kind: AudiobookAnalysisEventKind,
        occurredAt: Date = Date(),
        totalWindows: Int = 0,
        extractedWindows: Int = 0,
        mergeBatchesDone: Int = 0,
        mergeBatchesTotal: Int = 0,
        annotatedWindows: Int = 0,
        reusedCheckpointWindows: Int = 0,
        currentChapterOrdinal: Int? = nil,
        currentWindowOrdinal: Int? = nil,
        attempt: Int = 0,
        maxAttempts: Int = 0,
        elapsedMilliseconds: Int? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        errorCode: String? = nil,
        outcome: AudiobookAnalysisRunOutcome? = nil
    ) {
        self.runID = runID
        self.bookID = bookID
        self.sequence = sequence
        self.kind = kind
        self.occurredAt = occurredAt
        self.totalWindows = totalWindows
        self.extractedWindows = extractedWindows
        self.mergeBatchesDone = mergeBatchesDone
        self.mergeBatchesTotal = mergeBatchesTotal
        self.annotatedWindows = annotatedWindows
        self.reusedCheckpointWindows = reusedCheckpointWindows
        self.currentChapterOrdinal = currentChapterOrdinal
        self.currentWindowOrdinal = currentWindowOrdinal
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.elapsedMilliseconds = elapsedMilliseconds
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.errorCode = errorCode
        self.outcome = outcome
    }
}

/// 界面渲染的用户阶段（用户语言，不暴露 window / attempt 等内部术语）。
public enum AudiobookAnalysisPhase: String, Codable, Equatable, Hashable, Sendable {
    case preparing
    case extracting
    case merging
    case annotating
    case finished

    fileprivate var order: Int {
        switch self {
        case .preparing: 0
        case .extracting: 1
        case .merging: 2
        case .annotating: 3
        case .finished: 4
        }
    }

    /// 事件建议的阶段；`nil` 表示该事件不直接决定阶段（提取类事件另行推进，
    /// 诊断回执不推进）。
    fileprivate static func suggestedPhase(for kind: AudiobookAnalysisEventKind) -> AudiobookAnalysisPhase? {
        switch kind {
        case .planned:
            return .preparing
        case .awaitingLLM, .windowExtracted, .retryingSplit:
            return nil
        case .castBatchMerged:
            return .merging
        case .windowAnnotated:
            return .annotating
        case .llmCallFinished:
            return nil
        case .runEnded:
            return .finished
        }
    }

    public var stepTitle: String {
        switch self {
        case .preparing:
            return "正在准备分析"
        case .extracting:
            return "正在找出书中人物"
        case .merging:
            return "正在把同一个人认到一起"
        case .annotating:
            return "正在确认每段话是谁说的"
        case .finished:
            return "分析已结束"
        }
    }

    public var stepCounter: String? {
        switch self {
        case .preparing, .finished:
            return nil
        case .extracting:
            return "第 1/3 步"
        case .merging:
            return "第 2/3 步"
        case .annotating:
            return "第 3/3 步"
        }
    }
}

/// 界面绑定的进度快照：事件流的收敛结果，百分比单调不回退。
public struct AudiobookAnalysisProgress: Codable, Equatable, Sendable {
    public var runID: String
    public var bookID: UUID
    public var phase: AudiobookAnalysisPhase
    public var totalWindows: Int
    public var extractedWindows: Int
    public var mergeBatchesDone: Int
    public var mergeBatchesTotal: Int
    public var annotatedWindows: Int
    public var reusedCheckpointWindows: Int
    public var currentChapterOrdinal: Int?
    public var currentWindowOrdinal: Int?
    public var attempt: Int
    public var maxAttempts: Int
    /// 当前窗口是否正处在拆窗重试中（窗口完成或新窗口开始即复位）。
    public var isRetrying: Bool
    public var startedAt: Date
    public var lastEventAt: Date
    public var lastSequence: Int
    public var llmCallCount: Int
    public var promptTokensTotal: Int
    public var completionTokensTotal: Int
    public var lastCallMilliseconds: Int?
    public var lastErrorCode: String?
    public var outcome: AudiobookAnalysisRunOutcome?

    public init(firstEvent event: AudiobookAnalysisEvent) {
        self.runID = event.runID
        self.bookID = event.bookID
        self.phase = .preparing
        self.totalWindows = 0
        self.extractedWindows = 0
        self.mergeBatchesDone = 0
        self.mergeBatchesTotal = 0
        self.annotatedWindows = 0
        self.reusedCheckpointWindows = 0
        self.currentChapterOrdinal = nil
        self.currentWindowOrdinal = nil
        self.attempt = 0
        self.maxAttempts = 0
        self.isRetrying = false
        self.startedAt = event.occurredAt
        self.lastEventAt = event.occurredAt
        self.lastSequence = -1
        self.llmCallCount = 0
        self.promptTokensTotal = 0
        self.completionTokensTotal = 0
        self.lastCallMilliseconds = nil
        self.lastErrorCode = nil
        self.outcome = nil
        apply(event)
    }

    /// 收敛一个事件：序号过期直接丢弃；计数器只增不减；阶段只允许前进；
    /// 重试标记随重试事件置位、随窗口完成或新窗口复位；
    /// 诊断字段只在诊断回执与终态事件到达时合并。
    public mutating func apply(_ event: AudiobookAnalysisEvent) {
        guard event.runID == runID, event.sequence > lastSequence else { return }
        lastSequence = event.sequence
        lastEventAt = max(lastEventAt, event.occurredAt)

        switch event.kind {
        case .planned, .awaitingLLM, .windowExtracted, .castBatchMerged, .windowAnnotated, .retryingSplit:
            totalWindows = max(totalWindows, event.totalWindows)
            extractedWindows = max(extractedWindows, event.extractedWindows)
            mergeBatchesDone = max(mergeBatchesDone, event.mergeBatchesDone)
            mergeBatchesTotal = max(mergeBatchesTotal, event.mergeBatchesTotal)
            annotatedWindows = max(annotatedWindows, event.annotatedWindows)
            reusedCheckpointWindows = max(reusedCheckpointWindows, event.reusedCheckpointWindows)
            currentChapterOrdinal = event.currentChapterOrdinal ?? currentChapterOrdinal
            currentWindowOrdinal = event.currentWindowOrdinal ?? currentWindowOrdinal
            attempt = event.attempt
            maxAttempts = max(maxAttempts, event.maxAttempts)
        case .llmCallFinished, .runEnded:
            break
        }

        switch event.kind {
        case .planned:
            isRetrying = false
        case .awaitingLLM:
            // 新窗口第一次等待复位重试标记；第 2+ 次等待说明重试调用已在途。
            if event.attempt <= 1 {
                isRetrying = false
            }
        case .windowExtracted, .castBatchMerged, .windowAnnotated:
            isRetrying = false
        case .retryingSplit:
            isRetrying = true
            if phase.order < AudiobookAnalysisPhase.extracting.order {
                phase = .extracting
            }
        case .llmCallFinished, .runEnded:
            break
        }

        // 提取阶段没有专属的"完成"事件：只要出现过提取类事件且阶段仍在准备中，
        // 就推进到提取中。归并/标注/终态由专属事件推进。
        switch event.kind {
        case .awaitingLLM, .windowExtracted:
            if phase.order < AudiobookAnalysisPhase.extracting.order {
                phase = .extracting
            }
        default:
            if let suggested = AudiobookAnalysisPhase.suggestedPhase(for: event.kind),
               suggested.order > phase.order
            {
                phase = suggested
            }
        }

        if event.kind == .llmCallFinished {
            llmCallCount += 1
            promptTokensTotal += event.promptTokens ?? 0
            completionTokensTotal += event.completionTokens ?? 0
            lastCallMilliseconds = event.elapsedMilliseconds ?? lastCallMilliseconds
            if let code = event.errorCode {
                lastErrorCode = code
            }
        }
        if event.kind == .runEnded {
            outcome = event.outcome
            if let code = event.errorCode {
                lastErrorCode = code
            }
            lastCallMilliseconds = event.elapsedMilliseconds ?? lastCallMilliseconds
        }
    }

    /// 确定性百分比：提取与标注各占一半，归并阶段不推进（用步骤文案表达）。
    /// 复用检查点的窗口在规划后即计入，起点可能高于 0。单调不回退。
    public var fraction: Double {
        guard totalWindows > 0 else {
            return outcome == .completed ? 1.0 : 0.0
        }
        let done = Double(2 * reusedCheckpointWindows + extractedWindows + annotatedWindows)
        let total = Double(2 * totalWindows)
        return min(1.0, max(0.0, done / total))
    }

    /// 当前步骤的窗口计数文案，如"第 7/42 窗"；归并阶段返回 batch 计数。
    public var windowCounterText: String? {
        switch phase {
        case .extracting:
            guard totalWindows > 0 else { return nil }
            return "第 \(min(totalWindows, extractedWindows + 1))/\(totalWindows) 窗"
        case .annotating:
            guard totalWindows > 0 else { return nil }
            return "第 \(min(totalWindows, annotatedWindows + 1))/\(totalWindows) 窗"
        case .merging:
            guard mergeBatchesTotal > 0 else { return "正在归并人物" }
            return "第 \(min(mergeBatchesTotal, mergeBatchesDone + 1))/\(mergeBatchesTotal) 组"
        case .preparing, .finished:
            return nil
        }
    }

    public var isRetryNoticeVisible: Bool {
        isRetrying && outcome == nil
    }

    /// 终态之前无事件超过阈值即判定为"等得比平时久"。
    public func isStalled(at now: Date) -> Bool {
        outcome == nil && now.timeIntervalSince(lastEventAt) > AudiobookAnalysisProgressLimits.stallWarningSeconds
    }

    public func secondsSinceLastEvent(at now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(lastEventAt)))
    }

    public func elapsedSeconds(at now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt)))
    }
}

/// 管线侧的事件发射器：持有本 run 的全量计数器，每次发射自动编号。
///
/// 只允许从管线 actor 的串行执行上下文调用（`@unchecked Sendable` 的安全性
/// 完全依赖这一约束）；调用方不得跨 actor 共享同一个发射器。
public final class AudiobookAnalysisEventEmitter: @unchecked Sendable {
    private let sink: AudiobookAnalysisProgressSink
    /// 本次 run 的关联 ID（管线写进 prompt，供 live 链路做 LLM 观测 sessionID）。
    public let runID: String
    private let bookID: UUID
    private var sequence: Int = 0
    private var totalWindows: Int = 0
    private var extractedWindows: Int = 0
    private var mergeBatchesDone: Int = 0
    private var mergeBatchesTotal: Int = 0
    private var annotatedWindows: Int = 0
    private var reusedCheckpointWindows: Int = 0
    private var currentChapterOrdinal: Int?
    private var currentWindowOrdinal: Int?
    private var maxAttempts: Int = 0

    public init(runID: String, bookID: UUID, sink: AudiobookAnalysisProgressSink) {
        self.runID = runID
        self.bookID = bookID
        self.sink = sink
    }

    public func setPlan(totalWindows: Int, reusedCheckpointWindows: Int, maxAttempts: Int) {
        self.totalWindows = totalWindows
        self.reusedCheckpointWindows = reusedCheckpointWindows
        self.maxAttempts = maxAttempts
    }

    public func setCurrentWindow(chapterOrdinal: Int, windowOrdinal: Int) {
        currentChapterOrdinal = chapterOrdinal
        currentWindowOrdinal = windowOrdinal
    }

    public func setMergeBatches(total: Int) {
        mergeBatchesTotal = total
    }

    public func noteExtracted() {
        extractedWindows += 1
    }

    public func noteBatchMerged() {
        mergeBatchesDone += 1
    }

    public func noteAnnotated() {
        annotatedWindows += 1
    }

    public func emit(_ kind: AudiobookAnalysisEventKind, attempt: Int = 0, maxAttempts: Int? = nil) {
        sink.emit(AudiobookAnalysisEvent(
            runID: runID,
            bookID: bookID,
            sequence: nextSequence(),
            kind: kind,
            totalWindows: totalWindows,
            extractedWindows: extractedWindows,
            mergeBatchesDone: mergeBatchesDone,
            mergeBatchesTotal: mergeBatchesTotal,
            annotatedWindows: annotatedWindows,
            reusedCheckpointWindows: reusedCheckpointWindows,
            currentChapterOrdinal: currentChapterOrdinal,
            currentWindowOrdinal: currentWindowOrdinal,
            attempt: attempt,
            maxAttempts: maxAttempts ?? self.maxAttempts
        ))
    }

    public func emitLLMCalls(_ calls: [AudiobookAnalysisCallDiagnosticsCollector.Call]?) {
        guard let calls, !calls.isEmpty else { return }
        for call in calls {
            sink.emit(AudiobookAnalysisEvent(
                runID: runID,
                bookID: bookID,
                sequence: nextSequence(),
                kind: .llmCallFinished,
                totalWindows: totalWindows,
                extractedWindows: extractedWindows,
                mergeBatchesDone: mergeBatchesDone,
                mergeBatchesTotal: mergeBatchesTotal,
                annotatedWindows: annotatedWindows,
                reusedCheckpointWindows: reusedCheckpointWindows,
                currentChapterOrdinal: currentChapterOrdinal,
                currentWindowOrdinal: currentWindowOrdinal,
                elapsedMilliseconds: call.elapsedMilliseconds,
                promptTokens: call.promptTokens,
                completionTokens: call.completionTokens,
                reasoningTokens: call.reasoningTokens,
                errorCode: call.errorCode
            ))
        }
    }

    public func emitRunEnded(outcome: AudiobookAnalysisRunOutcome, errorCode: String? = nil) {
        sink.emit(AudiobookAnalysisEvent(
            runID: runID,
            bookID: bookID,
            sequence: nextSequence(),
            kind: .runEnded,
            totalWindows: totalWindows,
            extractedWindows: extractedWindows,
            mergeBatchesDone: mergeBatchesDone,
            mergeBatchesTotal: mergeBatchesTotal,
            annotatedWindows: annotatedWindows,
            reusedCheckpointWindows: reusedCheckpointWindows,
            currentChapterOrdinal: currentChapterOrdinal,
            currentWindowOrdinal: currentWindowOrdinal,
            errorCode: errorCode,
            outcome: outcome
        ))
    }

    private func nextSequence() -> Int {
        defer { sequence += 1 }
        return sequence
    }
}

/// 内存环形事件缓冲：供开发者详情与测试断言，不落盘。
public struct AudiobookAnalysisEventBuffer: Sendable, Equatable {
    public private(set) var events: [AudiobookAnalysisEvent] = []
    public var capacity: Int

    public init(capacity: Int = AudiobookAnalysisProgressLimits.eventBufferCapacity) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ event: AudiobookAnalysisEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    public mutating func reset() {
        events.removeAll(keepingCapacity: true)
    }
}

/// 单次 LLM 调用的诊断回执收集器：client 在 `complete()` 内记录，
/// 管线在同一次调用返回后取走并转为 `llmCallFinished` 事件。
/// 只带耗时 / token / 错误码，不带任何请求与响应正文。
public final class AudiobookAnalysisCallDiagnosticsCollector: @unchecked Sendable {
    public struct Call: Sendable, Equatable {
        public var elapsedMilliseconds: Int
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var reasoningTokens: Int?
        public var errorCode: String?

        public init(
            elapsedMilliseconds: Int,
            promptTokens: Int? = nil,
            completionTokens: Int? = nil,
            reasoningTokens: Int? = nil,
            errorCode: String? = nil
        ) {
            self.elapsedMilliseconds = elapsedMilliseconds
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.reasoningTokens = reasoningTokens
            self.errorCode = errorCode
        }
    }

    private let lock = NSLock()
    private var pending: [Call] = []

    public init() {}

    public func record(_ call: Call) {
        lock.withLock {
            pending.append(call)
        }
    }

    /// 是否有尚未取走的回执（只读，不清空；供失败兜底判断，避免 `takeAll` 误丢已记录的回执）。
    public var hasPendingCalls: Bool {
        lock.withLock { !pending.isEmpty }
    }

    /// 取走并清空全部待处理回执（拆窗重试一次窗口可能产生多次调用）。
    public func takeAll() -> [Call] {
        lock.withLock {
            defer { pending.removeAll() }
            return pending
        }
    }
}

/// 低基数错误码映射：只保留分类结论，不回显错误正文（正文可能夹带原文或凭据）。
public enum AudiobookAnalysisErrorCode {
    public static func code(for error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let analysisError = error as? AudiobookAnalysisError {
            switch analysisError {
            case .notConfigured:
                return "not_configured"
            case .badConfiguration:
                return "bad_configuration"
            case .inputBudgetExceeded:
                return "input_budget_exceeded"
            case .primaryWindowTooLarge:
                return "window_too_large"
            case .invalidStructuredOutput:
                return "invalid_structured_output"
            case .atomCoverageViolation:
                return "atom_coverage_violation"
            case .rootCallBudgetExhausted:
                return "call_budget_exhausted"
            case .configurationChangedDuringRun:
                return "configuration_changed"
            case .cancelled:
                return "cancelled"
            case .windowFailed:
                return "window_failed"
            }
        }
        if error is LLMError {
            return LLMObservability.errorCode(for: error)
        }
        if (error as? URLError)?.code == .cancelled {
            return "cancelled"
        }
        return "unknown"
    }
}
