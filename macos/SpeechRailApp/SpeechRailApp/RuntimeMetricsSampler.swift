import Foundation
import SpeechRailControlKit

public struct RuntimeMetricsSample: Identifiable, Equatable, Sendable {
    public let capturedAt: Date
    public let activeRequests: Int
    public let pendingRequests: Int
    public let requestCount: Double?
    public let queueRejections: Double?
    public let asrLatencySeconds: Double?
    public let ttsLatencySeconds: Double?
    public let asrRTF: Double?
    public let ttsRTF: Double?
    public let ttsTTFASeconds: Double?
    public let activeRealtimeSessions: Int?
    public let requestRatePerSecond: Double?
    public let queueRejectionRatePerSecond: Double?
    public let resources: RuntimeResourceSnapshot?

    public var id: Date { capturedAt }

    public init(
        capturedAt: Date,
        activeRequests: Int,
        pendingRequests: Int,
        requestCount: Double?,
        queueRejections: Double?,
        asrLatencySeconds: Double?,
        ttsLatencySeconds: Double?,
        asrRTF: Double? = nil,
        ttsRTF: Double? = nil,
        ttsTTFASeconds: Double? = nil,
        activeRealtimeSessions: Int? = nil,
        requestRatePerSecond: Double? = nil,
        queueRejectionRatePerSecond: Double? = nil,
        resources: RuntimeResourceSnapshot? = nil
    ) {
        self.capturedAt = capturedAt
        self.activeRequests = activeRequests
        self.pendingRequests = pendingRequests
        self.requestCount = requestCount
        self.queueRejections = queueRejections
        self.asrLatencySeconds = asrLatencySeconds
        self.ttsLatencySeconds = ttsLatencySeconds
        self.asrRTF = asrRTF
        self.ttsRTF = ttsRTF
        self.ttsTTFASeconds = ttsTTFASeconds
        self.activeRealtimeSessions = activeRealtimeSessions
        self.requestRatePerSecond = requestRatePerSecond
        self.queueRejectionRatePerSecond = queueRejectionRatePerSecond
        self.resources = resources
    }
}

public enum RuntimeMetricsSampler {
    public static func makeSample(
        from metrics: RuntimeMetricsSnapshot,
        capturedAt: Date = Date(),
        previous: RuntimeMetricsSample? = nil
    ) -> RuntimeMetricsSample {
        let requestCount = sumValues(
            metrics.counters,
            prefix: "speechrail_http_requests_total"
        )
        let queueRejections = sumValues(
            metrics.counters,
            prefix: "speechrail_governor_queue_rejections_total"
        )
        return RuntimeMetricsSample(
            capturedAt: capturedAt,
            activeRequests: metrics.activeRequests.realtime + metrics.activeRequests.batch,
            pendingRequests: metrics.pendingRequests.realtime + metrics.pendingRequests.batch,
            requestCount: requestCount,
            queueRejections: queueRejections,
            asrLatencySeconds: histogramAverage(
                metrics,
                name: "speechrail_asr_inference_duration_seconds"
            ),
            ttsLatencySeconds: histogramAverage(
                metrics,
                name: "speechrail_tts_inference_duration_seconds"
            ),
            asrRTF: histogramAverage(metrics, name: "speechrail_asr_rtf"),
            ttsRTF: histogramAverage(metrics, name: "speechrail_tts_rtf"),
            ttsTTFASeconds: histogramAverage(
                metrics,
                name: "speechrail_tts_ttfa_seconds"
            ),
            activeRealtimeSessions: sumValues(
                metrics.gauges,
                prefix: "speechrail_realtime_active_sessions"
            ).map { max(0, Int($0.rounded())) },
            requestRatePerSecond: counterRate(
                current: requestCount,
                previous: previous?.requestCount,
                capturedAt: capturedAt,
                previousCapturedAt: previous?.capturedAt
            ),
            queueRejectionRatePerSecond: counterRate(
                current: queueRejections,
                previous: previous?.queueRejections,
                capturedAt: capturedAt,
                previousCapturedAt: previous?.capturedAt
            ),
            resources: metrics.resources
        )
    }

    private static func sumValues(_ values: [String: Double], prefix: String) -> Double? {
        let matchingValues = values
            .filter { $0.key == prefix || $0.key.hasPrefix("\(prefix){") }
            .map(\.value)
        guard !matchingValues.isEmpty else { return nil }
        return matchingValues.reduce(0, +)
    }

    private static func histogramAverage(
        _ metrics: RuntimeMetricsSnapshot,
        name: String
    ) -> Double? {
        guard let series = metrics.histograms[name], !series.isEmpty else { return nil }
        let samples = series.values.filter { $0.count > 0 }
        guard !samples.isEmpty else { return nil }
        let count = samples.reduce(0) { $0 + $1.count }
        guard count > 0 else { return nil }
        let sum = samples.reduce(0.0) { $0 + $1.sum }
        return sum / Double(count)
    }

    private static func counterRate(
        current: Double?,
        previous: Double?,
        capturedAt: Date,
        previousCapturedAt: Date?
    ) -> Double? {
        guard let current,
              let previous,
              let previousCapturedAt,
              current >= previous
        else { return nil }
        let elapsed = capturedAt.timeIntervalSince(previousCapturedAt)
        guard elapsed > 0 else { return nil }
        return (current - previous) / elapsed
    }
}
