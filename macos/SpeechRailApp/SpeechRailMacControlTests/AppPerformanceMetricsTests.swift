import XCTest

#if SWIFT_PACKAGE
@testable import SpeechRailAppSupport
#endif

final class AppPerformanceMetricsTests: XCTestCase {
    func testMetricsStorageRemainsBoundedAfterMillionSamples() {
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        let initial = metrics.snapshot(for: .catalogRefresh)
        let sample = AppPerformanceSample(
            operation: .catalogRefresh,
            durationNanoseconds: 2_000_000,
            bytes: 128,
            count: 1,
            outcome: .success
        )
        for _ in 0..<1_000_000 { metrics.record(sample) }

        let result = metrics.snapshot(for: .catalogRefresh)
        XCTAssertEqual(result.durationBuckets.count, initial.durationBuckets.count)
        XCTAssertEqual(result.durationBuckets.reduce(0, +), 1_000_000)
        XCTAssertEqual(result.samples, 1_000_000)
        XCTAssertEqual(result.bytes, 128_000_000)
        XCTAssertEqual(result.count, 1_000_000)
        XCTAssertEqual(result.maximumDurationNanoseconds, 2_000_000)
        XCTAssertEqual(metrics.snapshot(for: .waveformScan).samples, 0)
    }

    func testMetricsContainOnlyNumericOperationData() {
        let sample = AppPerformanceSample(
            operation: .storeCommit, durationNanoseconds: 7, bytes: 2, count: 1, outcome: .failed
        )
        let fields = Array(Mirror(reflecting: sample).children)
        XCTAssertEqual(Set(fields.compactMap(\.label)), [
            "operation", "durationNanoseconds", "bytes", "count", "outcome",
        ])
        XCTAssertFalse(fields.contains { $0.value is String || $0.value is URL || $0.value is Data })
    }

    func testDisabledCollectionDoesNotAccumulateSamples() {
        let metrics = AppPerformanceMetrics(collecting: false, signposting: false)
        metrics.record(.init(
            operation: .captureStop, durationNanoseconds: 10, bytes: 100, count: 1, outcome: .success
        ))
        XCTAssertEqual(metrics.snapshot(for: .captureStop).samples, 0)
    }

    func testCountersSaturateAndRejectNegativeResourceCounts() {
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        for _ in 0..<2 {
            metrics.record(.init(
                operation: .workspaceRead, durationNanoseconds: .max,
                bytes: -1, count: -3, outcome: .cancelled
            ))
        }
        let result = metrics.snapshot(for: .workspaceRead)
        XCTAssertEqual(result.totalDurationNanoseconds, .max)
        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.cancelled, 2)
        XCTAssertEqual(result.failed, 0)
    }

    func testMeasuredOperationPropagatesCancellationAndRecordsOutcome() {
        let metrics = AppPerformanceMetrics(collecting: true, signposting: false)
        XCTAssertThrowsError(try metrics.measure(.workspaceProject) { () throws -> Void in
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        let result = metrics.snapshot(for: .workspaceProject)
        XCTAssertEqual(result.samples, 1)
        XCTAssertEqual(result.cancelled, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(metrics.measure(.workspaceRead) { 42 }, 42)
        XCTAssertEqual(metrics.snapshot(for: .workspaceRead).samples, 1)
    }
}
