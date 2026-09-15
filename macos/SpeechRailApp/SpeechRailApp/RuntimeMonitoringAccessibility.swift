import Accessibility
import Foundation
import SwiftUI

public struct RuntimeMonitoringChartPoint: Equatable, Sendable {
    public let capturedAt: Date
    public let activeRequests: Int

    public init(capturedAt: Date, activeRequests: Int) {
        self.capturedAt = capturedAt
        self.activeRequests = activeRequests
    }
}

public struct RuntimeMonitoringChartDescriptor: AXChartDescriptorRepresentable {
    public let points: [RuntimeMonitoringChartPoint]

    public init(points: [RuntimeMonitoringChartPoint]) {
        self.points = points
    }

    public static func isSufficient(_ points: [RuntimeMonitoringChartPoint]) -> Bool {
        points.count >= 2
    }

    public func makeChartDescriptor() -> AXChartDescriptor {
        let sortedPoints = points.sorted { $0.capturedAt < $1.capturedAt }
        let timestamps = sortedPoints.map { $0.capturedAt.timeIntervalSince1970 }
        let firstTimestamp = timestamps.first ?? 0
        let lastTimestamp = timestamps.last ?? firstTimestamp + 1
        let xAxis = AXNumericDataAxisDescriptor(
            title: "时间",
            range: firstTimestamp ... max(lastTimestamp, firstTimestamp + 1),
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                Date(timeIntervalSince1970: value)
                    .formatted(.dateTime.hour().minute().second())
            }
        )
        let maximumRequests = max(
            1,
            sortedPoints.map(\.activeRequests).max() ?? 1
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: "活跃请求",
            range: 0 ... Double(maximumRequests),
            gridlinePositions: [0, Double(maximumRequests)],
            valueDescriptionProvider: { value in
                "\(Int(value.rounded())) 个请求"
            }
        )
        let dataPoints = sortedPoints.map { point in
            AXDataPoint(
                x: point.capturedAt.timeIntervalSince1970,
                y: Double(point.activeRequests),
                label: point.capturedAt.formatted(.dateTime.hour().minute().second())
            )
        }
        let series = AXDataSeriesDescriptor(
            name: "活跃请求",
            isContinuous: true,
            dataPoints: dataPoints
        )
        let summary: String
        if let first = sortedPoints.first, let last = sortedPoints.last {
            summary = "共 \(sortedPoints.count) 个样本，活跃请求从 \(first.activeRequests) 变为 \(last.activeRequests)。"
        } else {
            summary = "暂无足够样本。"
        }
        return AXChartDescriptor(
            title: "最近运行监控趋势",
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            series: [series]
        )
    }
}

public struct RuntimeLatencySample: Equatable, Sendable {
    public let capturedAt: Date
    public let asrSeconds: Double?
    public let ttsSeconds: Double?

    public init(capturedAt: Date, asrSeconds: Double?, ttsSeconds: Double?) {
        self.capturedAt = capturedAt
        self.asrSeconds = asrSeconds
        self.ttsSeconds = ttsSeconds
    }
}

/// The latency chart is a second chart, so it needs its own descriptor; a
/// chart without one is invisible to VoiceOver (REDESIGN-SPEC §9).
public struct RuntimeLatencyChartDescriptor: AXChartDescriptorRepresentable {
    public let samples: [RuntimeLatencySample]

    public init(samples: [RuntimeLatencySample]) {
        self.samples = samples
    }

    public static func isSufficient(_ samples: [RuntimeLatencySample]) -> Bool {
        samples.count >= 2
            && samples.contains { $0.asrSeconds != nil || $0.ttsSeconds != nil }
    }

    public func makeChartDescriptor() -> AXChartDescriptor {
        let sorted = samples.sorted { $0.capturedAt < $1.capturedAt }
        let timestamps = sorted.map { $0.capturedAt.timeIntervalSince1970 }
        let firstTimestamp = timestamps.first ?? 0
        let lastTimestamp = timestamps.last ?? firstTimestamp + 1
        let xAxis = AXNumericDataAxisDescriptor(
            title: "时间",
            range: firstTimestamp ... max(lastTimestamp, firstTimestamp + 1),
            gridlinePositions: [],
            valueDescriptionProvider: { value in
                Date(timeIntervalSince1970: value)
                    .formatted(.dateTime.hour().minute().second())
            }
        )
        let values = sorted.flatMap { [$0.asrSeconds, $0.ttsSeconds] }.compactMap { $0 }
        let maximum = max(1, values.max() ?? 1)
        let yAxis = AXNumericDataAxisDescriptor(
            title: "时延",
            range: 0 ... maximum,
            gridlinePositions: [0, maximum],
            valueDescriptionProvider: { value in
                String(format: "%.2f 秒", value)
            }
        )
        let series = [
            ("ASR 时延", sorted.compactMap { sample -> AXDataPoint? in
                guard let seconds = sample.asrSeconds else { return nil }
                return AXDataPoint(
                    x: sample.capturedAt.timeIntervalSince1970,
                    y: seconds,
                    label: sample.capturedAt.formatted(.dateTime.hour().minute().second())
                )
            }),
            ("TTS 时延", sorted.compactMap { sample -> AXDataPoint? in
                guard let seconds = sample.ttsSeconds else { return nil }
                return AXDataPoint(
                    x: sample.capturedAt.timeIntervalSince1970,
                    y: seconds,
                    label: sample.capturedAt.formatted(.dateTime.hour().minute().second())
                )
            }),
        ]
        .filter { !$0.1.isEmpty }
        .map { AXDataSeriesDescriptor(name: $0.0, isContinuous: true, dataPoints: $0.1) }

        let latestAsr = sorted.last { $0.asrSeconds != nil }?.asrSeconds
        let latestTTS = sorted.last { $0.ttsSeconds != nil }?.ttsSeconds
        let summary = [
            latestAsr.map { String(format: "最近一次 ASR 时延 %.2f 秒。", $0) },
            latestTTS.map { String(format: "最近一次 TTS 时延 %.2f 秒。", $0) },
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        return AXChartDescriptor(
            title: "时延趋势",
            summary: summary.isEmpty ? "当前时间窗内没有时延样本。" : summary,
            xAxis: xAxis,
            yAxis: yAxis,
            series: series
        )
    }
}
