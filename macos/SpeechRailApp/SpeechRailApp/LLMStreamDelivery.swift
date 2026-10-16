import Foundation
import Synchronization

/// A slow consumer retains at most 128 deltas; the whole response also has a UTF-8 budget.
final class LLMStreamDelivery: Sendable {
    let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private struct State { var bytes = 0; var closed = false }
    private let state = Mutex(State())
    private let maxPayloadBytes: Int

    init(maxEvents: Int = 128, maxPayloadBytes: Int = 262_144) {
        precondition(maxEvents > 0 && maxPayloadBytes >= 0)
        let pair = AsyncThrowingStream<String, any Error>.makeStream(bufferingPolicy: .bufferingOldest(maxEvents))
        stream = pair.stream
        continuation = pair.continuation
        self.maxPayloadBytes = maxPayloadBytes
    }

    var payloadBytes: Int { state.withLock { $0.bytes } }

    func cancelWhenTerminated(_ action: @escaping @Sendable () -> Void) {
        continuation.onTermination = { _ in action() }
    }

    func yield(_ delta: String) throws {
        let bytes = delta.utf8.count
        let failure: LLMError? = state.withLock { state in
            guard !state.closed else { return .cancelled }
            guard bytes <= maxPayloadBytes - state.bytes else {
                state.closed = true
                return .streamBudgetExceeded("正文 UTF-8 超过容量预算")
            }
            switch continuation.yield(delta) {
            case .enqueued:
                state.bytes += bytes
                return nil
            case .dropped:
                state.closed = true
                return .streamBudgetExceeded("正文消费速度不足，待处理事件超过容量预算")
            case .terminated:
                state.closed = true
                return .cancelled
            @unknown default:
                state.closed = true
                return .streamBudgetExceeded("正文流无法继续交付")
            }
        }
        if let failure {
            continuation.finish(throwing: failure)
            throw failure
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        let finish = state.withLock { state in
            guard !state.closed else { return false }
            state.closed = true
            return true
        }
        if finish { continuation.finish(throwing: error) }
    }
}

enum StreamProgressEvent: Sendable { case text, reasoning, other }

/// Pure deadline rules. A progress event at the deadline is already late.
struct StreamDeadlineState: Sendable {
    let firstProgressDeadline: ContinuousClock.Instant?
    let stallTimeout: Duration?
    private(set) var stallDeadline: ContinuousClock.Instant?
    private(set) var firstTextSeen = false

    init(firstProgressDeadline: ContinuousClock.Instant?, stallTimeout: Duration?, initialStall: ContinuousClock.Instant? = nil) {
        self.firstProgressDeadline = firstProgressDeadline
        self.stallTimeout = stallTimeout
        self.stallDeadline = initialStall
    }

    var nextWake: ContinuousClock.Instant? { firstTextSeen ? stallDeadline : firstProgressDeadline }

    func expiry(now: ContinuousClock.Instant) -> String? {
        if !firstTextSeen, let firstProgressDeadline, now >= firstProgressDeadline {
            return "首个有效正文超时未到达"
        }
        if firstTextSeen, let stallDeadline, now >= stallDeadline { return "正文停滞超时未推进" }
        return nil
    }

    mutating func advance(event: StreamProgressEvent, now: ContinuousClock.Instant) throws {
        if let reason = expiry(now: now) { throw LLMError.streamBudgetExceeded(reason) }
        switch event {
        case .text:
            firstTextSeen = true
            if let stallTimeout { stallDeadline = now + stallTimeout }
        case .reasoning:
            if let stallTimeout { stallDeadline = now + stallTimeout }
        case .other: break
        }
    }
}

/// One reschedulable native timer and one waiter per stream, with no per-byte hop or per-delta Task.
final class StreamTimer: Sendable {
    private struct State {
        let source: any DispatchSourceTimer
        var deadline: StreamDeadlineState
        var expiryReason: String?
        var stopped = false
        var eventChecks = 0
        var wakeCount = 0
        var scheduledWake: ContinuousClock.Instant?
        var scheduleCount = 0
    }
    private let state: Mutex<State>
    private let notifications = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))

    init(firstDeadline: ContinuousClock.Instant?, stallTimeout: Duration?, initialStall: ContinuousClock.Instant?) {
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        state = Mutex(State(source: source, deadline: .init(firstProgressDeadline: firstDeadline,
            stallTimeout: stallTimeout, initialStall: initialStall)))
        source.setEventHandler { [weak self] in self?.fire() }
        source.resume()
        state.withLock { Self.schedule(&$0) }
    }

    deinit { stop() }

    var expired: Bool { state.withLock { $0.expiryReason != nil } }
    var expiryReason: String { state.withLock { $0.expiryReason ?? "" } }
    var firstTextSeen: Bool { state.withLock { $0.deadline.firstTextSeen } }
    var eventChecks: Int { state.withLock { $0.eventChecks } }
    var wakeCount: Int { state.withLock { $0.wakeCount } }
    var scheduledWake: ContinuousClock.Instant? { state.withLock { $0.scheduledWake } }
    var scheduleCount: Int { state.withLock { $0.scheduleCount } }

    func advance(events: [StreamProgressEvent], now: ContinuousClock.Instant, terminal: Bool = false) throws {
        let failure: LLMError? = state.withLock { state in
            state.eventChecks += 1
            if let reason = state.expiryReason { return .streamBudgetExceeded(reason) }
            guard !state.stopped else { return .cancelled }
            do {
                for event in events.isEmpty ? [.other] : events {
                    try state.deadline.advance(event: event, now: now)
                }
            } catch {
                state.expiryReason = state.deadline.expiry(now: now)
                state.source.cancel()
                return .streamBudgetExceeded(state.expiryReason ?? "正文等待超时")
            }
            if terminal { state.stopped = true; state.source.cancel() }
            else { Self.schedule(&state) }
            return nil
        }
        if let failure {
            notifications.continuation.yield(expiryReason)
            notifications.continuation.finish()
            throw failure
        }
        if terminal { notifications.continuation.finish() }
    }

    func stop() {
        state.withLock { state in
            state.stopped = true
            state.source.cancel()
        }
        notifications.continuation.finish()
    }

    func waitForExpiry() async throws {
        let needed = state.withLock { $0.expiryReason != nil || (!$0.stopped && ($0.deadline.nextWake != nil || $0.deadline.stallTimeout != nil)) }
        guard needed else { return }
        for await reason in notifications.stream { throw LLMError.streamBudgetExceeded(reason) }
    }

    private func fire() {
        let reason = state.withLock { state -> String? in
            guard !state.stopped, state.expiryReason == nil else { return nil }
            state.wakeCount += 1
            let reason = state.deadline.expiry(now: .now)
            if let reason { state.expiryReason = reason; state.source.cancel() }
            else { Self.schedule(&state) }
            return reason
        }
        if let reason {
            notifications.continuation.yield(reason)
            notifications.continuation.finish()
        }
    }

    private static func schedule(_ state: inout State) {
        guard !state.stopped, let wake = state.deadline.nextWake else { return }
        let components = max(Duration.zero, wake - ContinuousClock.now).components
        let nanoseconds = max(0, min(Double(Int.max / 2), Double(components.seconds) * 1e9
            + Double(components.attoseconds) / 1e9))
        state.source.schedule(deadline: .now() + .nanoseconds(Int(nanoseconds)), leeway: .milliseconds(1))
        state.scheduledWake = wake
        state.scheduleCount += 1
    }
}

/// Idempotent transport shutdown shared by cancellation, timeout, failure and normal release.
final class StreamTransportCancellation: Sendable {
    private let cancelled = Mutex(false)
    private let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func cancel() {
        let first = cancelled.withLock { value in
            if value { return false }
            value = true
            return true
        }
        if first { action() }
    }
}

final class StreamRunWork: Sendable {
    private let state = Mutex((active: 0, peak: 0))
    var activeTasks: Int { state.withLock { $0.active } }
    var peakTasks: Int { state.withLock { $0.peak } }
    func begin() { state.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) } }
    func end() { state.withLock { $0.active -= 1 } }
}

/// Only the latest presentation snapshot is retained. Formal reply state is updated independently.
@MainActor
final class LLMTextPreview {
    private(set) var pendingText: String?
    private(set) var timerStartCount = 0
    var hasTimer: Bool { timerTask != nil }
    private var timerTask: Task<Void, Never>?
    private let publish: @MainActor (String) -> Void
    private var stopped = false

    init(interval: Duration = .milliseconds(50), publish: @escaping @MainActor (String) -> Void) {
        self.publish = publish
        timerStartCount += 1
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                self.flushPending()
            }
        }
    }

    deinit { timerTask?.cancel() }

    func submit(_ text: String) {
        guard !stopped else { return }
        pendingText = text
    }

    func flushPending() {
        guard let text = pendingText else { return }
        pendingText = nil
        publish(text)
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        stopped = true
        pendingText = nil
        let task = timerTask
        timerTask = nil
        task?.cancel()
        return task
    }

    func finish() async {
        flushPending()
        let task = stop()
        await task?.value
    }

    func cancel() async {
        let task = stop()
        await task?.value
    }
}
