import Foundation
import os
import Synchronization

public struct AppPerformanceSummary: Sendable {
    public private(set) var samples: UInt64 = 0
    public private(set) var bytes: UInt64 = 0
    public private(set) var count: UInt64 = 0
    public private(set) var totalDurationNanoseconds: UInt64 = 0
    public private(set) var maximumDurationNanoseconds: UInt64 = 0
    public private(set) var cancelled: UInt64 = 0
    public private(set) var failed: UInt64 = 0
    public private(set) var durationBuckets = [UInt64](repeating: 0, count: 13)

    private static let bounds: [UInt64] = [
        100_000, 250_000, 500_000, 1_000_000, 2_000_000, 5_000_000,
        10_000_000, 20_000_000, 50_000_000, 100_000_000, 500_000_000, 1_000_000_000,
    ]

    fileprivate mutating func record(_ sample: AppPerformanceSample) {
        samples = Self.add(samples, 1)
        bytes = Self.add(bytes, UInt64(max(0, sample.bytes)))
        count = Self.add(count, UInt64(max(0, sample.count)))
        totalDurationNanoseconds = Self.add(totalDurationNanoseconds, sample.durationNanoseconds)
        maximumDurationNanoseconds = max(maximumDurationNanoseconds, sample.durationNanoseconds)
        if sample.outcome == .cancelled { cancelled = Self.add(cancelled, 1) }
        if sample.outcome == .failed { failed = Self.add(failed, 1) }
        let index = Self.bounds.firstIndex { sample.durationNanoseconds <= $0 } ?? Self.bounds.count
        durationBuckets[index] = Self.add(durationBuckets[index], 1)
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}

/// Passive observations only: no tasks, observers, timers, or retained raw samples.
public final class AppPerformanceMetrics: AppPerformanceSink {
    public static let shared = AppPerformanceMetrics()
    private let collecting: Bool
    private let signposting: Bool
    private let signposter = OSSignposter(subsystem: "com.speechrail.desktop", category: "AppPerformance")
    private let summaries = Mutex(
        Array(repeating: AppPerformanceSummary(), count: AppPerformanceOperation.allCases.count)
    )

    public init(collecting: Bool = false, signposting: Bool = true) {
        self.collecting = collecting
        self.signposting = signposting
    }

    public var isEnabled: Bool { collecting || (signposting && signposter.isEnabled) }

    public func record(_ sample: AppPerformanceSample) {
        if collecting {
            summaries.withLock { $0[sample.operation.rawValue].record(sample) }
        }
        if signposting && signposter.isEnabled {
            signposter.emitEvent(
                "Operation",
                "operation=\(sample.operation.rawValue) duration_ns=\(sample.durationNanoseconds) bytes=\(max(0, sample.bytes)) count=\(max(0, sample.count)) outcome=\(sample.outcome.rawValue)"
            )
        }
    }

    public func snapshot(for operation: AppPerformanceOperation) -> AppPerformanceSummary {
        summaries.withLock { $0[operation.rawValue] }
    }

    /// Synchronous closure stays on its caller's executor; it does not relocate work.
    public func measure<Value>(
        _ operation: AppPerformanceOperation, bytes: Int = 0, count: Int = 1,
        body: () throws -> Value
    ) rethrows -> Value {
        let enabled = signposting && signposter.isEnabled
        guard collecting || enabled else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        let interval = enabled ? signposter.beginInterval("AppOperation", "operation=\(operation.rawValue)") : nil
        var outcome = AppPerformanceOutcome.success
        defer {
            if let interval { signposter.endInterval("AppOperation", interval) }
            record(.init(
                operation: operation,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- start,
                bytes: bytes, count: count, outcome: outcome
            ))
        }
        do { return try body() }
        catch {
            outcome = error is CancellationError ? .cancelled : .failed
            throw error
        }
    }
}
