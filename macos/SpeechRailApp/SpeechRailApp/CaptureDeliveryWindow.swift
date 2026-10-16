import Foundation
import Synchronization

/// Credit policy only. The owner schedules its one ack deadline and stops the actual capture on expiry.
/// Production gives each capture epoch its own instance; begin also retires a pending older waiter.
final class CaptureDeliveryWindow: Sendable {
    enum Failure: Error, Equatable { case invalidAcknowledgement, acknowledgementExpired }
    struct Snapshot: Sendable {
        let epoch: UUID?
        let inFlightBytes: Int
        let inFlightChunks: Int
        let waitingSenders: Int
        let waitingDrainers: Int
        let ackDeadlineUptimeNanoseconds: UInt64?
        let didExpire: Bool
    }
    private struct Entry { let sequence: UInt64; let bytes: Int }
    private struct State {
        var epoch: UUID?
        var active = false, didExpire = false
        var entries = [Entry?](repeating: nil, count: 4)
        var head = 0, count = 0, bytes = 0
        var lastSent: UInt64?, lastAcknowledged: UInt64?, deadline: UInt64?
        var waiter: CheckedContinuation<Bool, Never>?
        var drainWaiter: CheckedContinuation<Bool, Never>?
    }
    private let state = Mutex(State())
    private let now: @Sendable () -> UInt64
    init(now: @Sendable @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) { self.now = now }

    var snapshot: Snapshot {
        state.withLock { .init(epoch: $0.epoch, inFlightBytes: $0.bytes, inFlightChunks: $0.count,
            waitingSenders: $0.waiter == nil ? 0 : 1, waitingDrainers: $0.drainWaiter == nil ? 0 : 1, ackDeadlineUptimeNanoseconds: $0.deadline, didExpire: $0.didExpire) }
    }

    func begin(epoch: UUID) {
        let retired = state.withLock { value in
            let waiters = [value.waiter, value.drainWaiter].compactMap { $0 }
            value = State(epoch: epoch, active: true)
            return waiters
        }
        for waiter in retired { waiter.resume(returning: false) }
    }

    func offer(sequence: UInt64, bytes: Int) -> Bool {
        state.withLock { value in
            guard value.active, bytes > 0, bytes <= 1_920, bytes.isMultiple(of: 2),
                  value.count < 4, bytes <= 7_680 - value.bytes else { return false }
            if let previous = value.lastSent {
                guard previous < UInt64.max, sequence == previous + 1 else { return false }
            }
            value.entries[(value.head + value.count) % 4] = .init(sequence: sequence, bytes: bytes)
            value.count += 1; value.bytes += bytes; value.lastSent = sequence
            if value.deadline == nil { value.deadline = Self.deadline(after: now()) }
            return true
        }
    }

    @discardableResult
    func acknowledge(epoch: UUID, throughSequence sequence: UInt64) throws -> Bool {
        var waiter: CheckedContinuation<Bool, Never>?, drained: CheckedContinuation<Bool, Never>?
        var expiredWaiters: [CheckedContinuation<Bool, Never>] = []
        var expired = false
        let changed = try state.withLock { value in
            guard value.active, value.epoch == epoch else { return false }
            let acknowledgedAt = now()
            if value.count > 0, let deadline = value.deadline, acknowledgedAt >= deadline {
                value.didExpire = true
                expiredWaiters = Self.close(&value)
                expired = true
                return false
            }
            guard let sent = value.lastSent, sequence <= sent else { throw Failure.invalidAcknowledgement }
            if let previous = value.lastAcknowledged, sequence <= previous { return false }
            var removed = 0
            while value.count > 0, let first = value.entries[value.head], first.sequence <= sequence {
                value.entries[value.head] = nil
                value.head = (value.head + 1) % 4; value.count -= 1; value.bytes -= first.bytes
                removed += 1
            }
            guard removed > 0 else { return false }
            value.lastAcknowledged = sequence
            value.deadline = value.count == 0 ? nil : Self.deadline(after: acknowledgedAt)
            waiter = value.waiter; value.waiter = nil
            if value.count == 0 { drained = value.drainWaiter; value.drainWaiter = nil }
            return true
        }
        for continuation in expiredWaiters { continuation.resume(returning: false) }
        if expired { throw Failure.acknowledgementExpired }
        waiter?.resume(returning: true); drained?.resume(returning: true)
        return changed
    }

    func waitForCredit() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = state.withLock { value in
                    guard value.active else { return false }
                    if value.count < 4 && value.bytes < 7_680 { return true }
                    guard value.waiter == nil else { return false }
                    value.waiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: { self.stop() }
    }

    func waitUntilDrained() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: Bool? = state.withLock { value in
                    guard value.active else { return false }
                    if value.count == 0 { return true }
                    guard value.drainWaiter == nil else { return false }
                    value.drainWaiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: { self.stop() }
    }

    @discardableResult
    func expireIfNeeded() -> Bool {
        var waiters: [CheckedContinuation<Bool, Never>] = []
        let expired = state.withLock { value in
            guard value.active, value.count > 0, let deadline = value.deadline, now() >= deadline else { return false }
            value.didExpire = true
            waiters = Self.close(&value)
            return true
        }
        for waiter in waiters { waiter.resume(returning: false) }
        return expired
    }

    func stop() {
        let waiters = state.withLock { Self.close(&$0) }
        for waiter in waiters { waiter.resume(returning: false) }
    }

    private static func close(_ value: inout State) -> [CheckedContinuation<Bool, Never>] {
        value.active = false; value.deadline = nil
        for i in value.entries.indices { value.entries[i] = nil }
        value.head = 0; value.count = 0; value.bytes = 0
        let waiters = [value.waiter, value.drainWaiter].compactMap { $0 }
        value.waiter = nil; value.drainWaiter = nil
        return waiters
    }

    private static func deadline(after now: UInt64) -> UInt64 {
        let (value, overflow) = now.addingReportingOverflow(1_000_000_000)
        return overflow ? UInt64.max : value
    }
}
