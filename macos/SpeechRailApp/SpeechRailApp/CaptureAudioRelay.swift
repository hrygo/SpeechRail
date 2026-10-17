import Foundation
import Synchronization
import os

// These metric contracts live in a source compiled by both the App and
// CaptureHelper targets. The App's collecting implementation is app-only.
public enum AppPerformanceOperation: Int, CaseIterable, Sendable {
    case catalogRefresh, workspaceRead, workspaceProject, storeCommit, dubbingExport
    case llmEvent, captureEnqueue, mixerTick, captureStop
    case teleprompterPrepare, teleprompterMatch, transcriptPublish, waveformScan
}

public enum AppPerformanceOutcome: Int, Sendable {
    case success, cancelled, failed
}

/// Deliberately excludes arbitrary labels, text, paths, and audio payloads.
public struct AppPerformanceSample: Sendable {
    public let operation: AppPerformanceOperation
    public let durationNanoseconds: UInt64
    public let bytes: Int
    public let count: Int
    public let outcome: AppPerformanceOutcome

    public init(
        operation: AppPerformanceOperation, durationNanoseconds: UInt64,
        bytes: Int = 0, count: Int = 1, outcome: AppPerformanceOutcome = .success
    ) {
        self.operation = operation
        self.durationNanoseconds = durationNanoseconds
        self.bytes = bytes
        self.count = count
        self.outcome = outcome
    }
}

public protocol AppPerformanceSink: Sendable {
    var isEnabled: Bool { get }
    func record(_ sample: AppPerformanceSample)
}

/// Signpost-only sink for capture code hosted in CaptureHelper, where the
/// App's bounded in-memory aggregation implementation is not linked.
public final class CapturePerformanceSignpostSink: AppPerformanceSink {
    public static let shared = CapturePerformanceSignpostSink()
    private let signposter = OSSignposter(subsystem: "com.speechrail.desktop", category: "AppPerformance")

    private init() {}

    public var isEnabled: Bool { signposter.isEnabled }

    public func record(_ sample: AppPerformanceSample) {
        guard signposter.isEnabled else { return }
        signposter.emitEvent(
            "Operation",
            "operation=\(sample.operation.rawValue) duration_ns=\(sample.durationNanoseconds) bytes=\(max(0, sample.bytes)) count=\(max(0, sample.count)) outcome=\(sample.outcome.rawValue)"
        )
    }
}

/// One helper-owned pump, four XPC credits, and one deadline source. No intermediate PCM queue.
final class CaptureAudioRelay: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var timer: DispatchSourceTimer?
        var started = false, stopped = false, pumpActive = false
        var sourceID: UUID?
        var terminalError: AudioStreamError?
    }
    private let state = Mutex(State())
    private let window: CaptureDeliveryWindow
    private let epoch: UUID, stream: AudioChunkStream
    private let deliver: @Sendable (AudioChunk) -> Void
    private let stopCapture: @Sendable (AudioStreamTermination) -> Void
    private let timerQueue = DispatchQueue(label: "com.speechrail.capture-credit")
    private let now: @Sendable () -> UInt64
    private let metrics: any AppPerformanceSink

    private enum EnqueueFailure: Error { case rejected }

    init(epoch: UUID, stream: AudioChunkStream,
         now: @Sendable @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         deliver: @Sendable @escaping (AudioChunk) -> Void,
         stopCapture: @Sendable @escaping (AudioStreamTermination) -> Void,
         metrics: any AppPerformanceSink = CapturePerformanceSignpostSink.shared) {
        self.epoch = epoch; self.stream = stream; self.now = now; self.deliver = deliver; self.stopCapture = stopCapture
        self.metrics = metrics
        window = CaptureDeliveryWindow(now: now); window.begin(epoch: epoch)
    }

    deinit { requestStop(.cancelled) }
    var snapshot: CaptureDeliveryWindow.Snapshot { window.snapshot }
    var terminalError: AudioStreamError? { state.withLock { $0.terminalError } }
    var isPumpActive: Bool { state.withLock { $0.pumpActive } }

    func start() {
        state.withLock { value in
            guard !value.started, !value.stopped else { return }
            value.started = true; value.pumpActive = true
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .distantFuture)
            timer.setEventHandler { [weak self] in self?.checkDeadline() }
            timer.resume(); value.timer = timer
            value.task = Task { [weak self] in await self?.run() }
        }
    }

    func acknowledge(epoch: UUID, throughSequence: UInt64) {
        do {
            if try window.acknowledge(epoch: epoch, throughSequence: throughSequence) { scheduleDeadline() }
        } catch CaptureDeliveryWindow.Failure.acknowledgementExpired {
            requestStop(.staleInput)
        } catch { requestStop(.sourceLost) }
    }

    func checkDeadline() {
        if window.expireIfNeeded() { requestStop(.staleInput) }
        else { scheduleDeadline() }
    }

    func requestStop(_ reason: AudioStreamTermination, evidence: AudioStreamError? = nil) {
        let changed = state.withLock { value in
            guard !value.stopped else { return false }
            value.stopped = true
            value.terminalError = evidence ?? AudioStreamError(reason: reason, captureEpoch: epoch, sourceID: value.sourceID)
            value.timer?.setEventHandler {}; value.timer?.cancel(); value.timer = nil
            value.task?.cancel()
            return true
        }
        guard changed else { return }
        window.stop(); stopCapture(reason)
    }

    func stop() async {
        requestStop(.cancelled)
        let task = state.withLock { $0.task }
        await task?.value
        state.withLock { $0.task = nil }
    }

    /// Producer must finish its bounded input first. The one ACK deadline remains armed while draining.
    func finishAndWait() async {
        let task = state.withLock { $0.task }
        await task?.value
        state.withLock { $0.task = nil }
    }

    private func scheduleDeadline() {
        // Read under the owner's lock so a late earlier schedule cannot overwrite a later ACK.
        state.withLock { value in
            guard !value.stopped, let timer = value.timer else { return }
            guard let deadline = window.snapshot.ackDeadlineUptimeNanoseconds else { timer.schedule(deadline: .distantFuture); return }
            let current = now()
            timer.schedule(deadline: .now() + .nanoseconds(Int(min(deadline > current ? deadline - current : 0, UInt64(Int.max)))), leeway: .milliseconds(1))
        }
    }

    private func run() async {
        defer { state.withLock { $0.pumpActive = false } }
        var reader = stream.makeAsyncIterator()
        do {
            while await window.waitForCredit(), !Task.isCancelled {
                guard let chunk = try await reader.next() else {
                    if await window.waitUntilDrained() { requestStop(.completed) }
                    return
                }
                do {
                    try enqueue(chunk)
                } catch {
                    requestStop(.sourceLost); return
                }
            }
        } catch {
            requestStop((error as? AudioStreamError)?.reason ?? (error is CancellationError ? .cancelled : .sourceLost), evidence: error as? AudioStreamError)
        }
    }

    private func enqueue(_ chunk: AudioChunk) throws {
        let shouldMeasure = metrics.isEnabled
        let startedAt = shouldMeasure ? DispatchTime.now().uptimeNanoseconds : 0
        var outcome = AppPerformanceOutcome.success
        defer {
            if shouldMeasure {
                metrics.record(.init(
                    operation: .captureEnqueue,
                    durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt,
                    bytes: chunk.pcm.count,
                    outcome: outcome
                ))
            }
        }

        do {
            guard let stamp = chunk.captureStamp, stamp.captureEpoch == epoch,
                  window.offer(sequence: stamp.sourceSequence, bytes: chunk.pcm.count) else {
                throw EnqueueFailure.rejected
            }
            state.withLock { $0.sourceID = stamp.sourceID }
            scheduleDeadline()
            deliver(chunk)
        } catch {
            outcome = error is CancellationError ? .cancelled : .failed
            throw error
        }
    }
}
