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

    public var id: Date { capturedAt }

    public init(
        capturedAt: Date,
        activeRequests: Int,
        pendingRequests: Int,
        requestCount: Double?,
        queueRejections: Double?,
        asrLatencySeconds: Double?,
        ttsLatencySeconds: Double?
    ) {
        self.capturedAt = capturedAt
        self.activeRequests = activeRequests
        self.pendingRequests = pendingRequests
        self.requestCount = requestCount
        self.queueRejections = queueRejections
        self.asrLatencySeconds = asrLatencySeconds
        self.ttsLatencySeconds = ttsLatencySeconds
    }
}

public enum RuntimeMetricsSampler {
    public static func makeSample(
        from metrics: RuntimeMetricsSnapshot,
        capturedAt: Date = Date()
    ) -> RuntimeMetricsSample {
        RuntimeMetricsSample(
            capturedAt: capturedAt,
            activeRequests: metrics.activeRequests.realtime + metrics.activeRequests.batch,
            pendingRequests: metrics.pendingRequests.realtime + metrics.pendingRequests.batch,
            requestCount: sumValues(
                metrics.counters,
                prefix: "speechrail_http_requests_total"
            ),
            queueRejections: sumValues(
                metrics.counters,
                prefix: "speechrail_governor_queue_rejections_total"
            ),
            asrLatencySeconds: histogramAverage(
                metrics,
                name: "speechrail_asr_inference_duration_seconds"
            ),
            ttsLatencySeconds: histogramAverage(
                metrics,
                name: "speechrail_tts_inference_duration_seconds"
            )
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
}
