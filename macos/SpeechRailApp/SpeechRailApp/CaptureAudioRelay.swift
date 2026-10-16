import Foundation
import Synchronization

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

    init(epoch: UUID, stream: AudioChunkStream,
         now: @Sendable @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         deliver: @Sendable @escaping (AudioChunk) -> Void,
         stopCapture: @Sendable @escaping (AudioStreamTermination) -> Void) {
        self.epoch = epoch; self.stream = stream; self.now = now; self.deliver = deliver; self.stopCapture = stopCapture
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
                guard let stamp = chunk.captureStamp, stamp.captureEpoch == epoch,
                      window.offer(sequence: stamp.sourceSequence, bytes: chunk.pcm.count) else {
                    requestStop(.sourceLost); return
                }
                state.withLock { $0.sourceID = stamp.sourceID }
                scheduleDeadline()
                deliver(chunk)
            }
        } catch {
            requestStop((error as? AudioStreamError)?.reason ?? (error is CancellationError ? .cancelled : .sourceLost), evidence: error as? AudioStreamError)
        }
    }
}
