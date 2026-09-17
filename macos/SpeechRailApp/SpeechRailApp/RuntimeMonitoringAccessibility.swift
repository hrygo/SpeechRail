import Accessibility
import Foundation
import SwiftUI

public struct RuntimeMonitoringChartPoint: Equatable, Sendable {
    public let capturedAt: Date
    public let activeRequests: Int
    public let realtimeActiveRequests: Int
    public let batchActiveRequests: Int

    public init(
        capturedAt: Date,
        activeRequests: Int,
        realtimeActiveRequests: Int = 0,
        batchActiveRequests: Int = 0
    ) {
        self.capturedAt = capturedAt
        self.activeRequests = activeRequests
        self.realtimeActiveRequests = realtimeActiveRequests
        self.batchActiveRequests = batchActiveRequests
    }
}

public struct RuntimeMonitoringChartDescriptor: AXChartDescriptorRepresentable {
    public let points: [RuntimeMonitoringChartPoint]
    /// 同一张图上的耗时折线（秒）。
    ///
    /// 2026-09-16 用户复核把「上下一共两张图、各一根纵轴」合并成一张图之后，
    /// 这张图的描述符必须同时讲清两件事：面积是请求量、折线是耗时——否则 VoiceOver
    /// 只听得见一半的图（REDESIGN-SPEC §9）。
    public let latency: [RuntimeLatencySample]
    /// 面积那两条序列的名字：实时档是「实时语音会话 / 单次请求」，
    /// 历史档是「语音合成 / 语音识别」。同一张图、两种口径，名字不能写死。
    public let seriesNames: [String]
    /// 耗时折线在摘要里的说法（实时档是「每次」，历史档是「每桶加权平均」）。
    public let latencyCaption: String

    public init(
        points: [RuntimeMonitoringChartPoint],
        latency: [RuntimeLatencySample] = [],
        seriesNames: [String] = ["实时语音会话", "单次请求"],
        latencyCaption: String = "折线是每次的耗时（秒），读右侧刻度。"
    ) {
        self.points = points
        self.latency = latency
        self.seriesNames = seriesNames
        self.latencyCaption = latencyCaption
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
        // 一个绘图区、两套刻度：左轴数请求个数、右轴数秒。只有耗时折线在场时才需要点明。
        let yAxis = AXNumericDataAxisDescriptor(
            title: latency.isEmpty ? "同时处理" : "同时处理（左轴）／耗时（秒，右轴）",
            range: 0 ... Double(maximumRequests),
            gridlinePositions: [0, Double(maximumRequests)],
            valueDescriptionProvider: { value in
                "\(Int(value.rounded())) 个请求"
            }
        )
        // 两条序列各自成一个 AX 系列：VoiceOver 听到的必须和图上一样区分两类请求，
        // 只有合计值会让这条曲线在无障碍侧变成另一种数据（REDESIGN-SPEC §9）。
        func dataPoints(_ value: (RuntimeMonitoringChartPoint) -> Int) -> [AXDataPoint] {
            sortedPoints.map { point in
                AXDataPoint(
                    x: point.capturedAt.timeIntervalSince1970,
                    y: Double(value(point)),
                    label: point.capturedAt.formatted(.dateTime.hour().minute().second())
                )
            }
        }
        let requestSeries = [
            AXDataSeriesDescriptor(
                name: seriesNames.first ?? "实时语音会话",
                isContinuous: true,
                dataPoints: dataPoints(\.realtimeActiveRequests)
            ),
            AXDataSeriesDescriptor(
                name: seriesNames.dropFirst().first ?? "单次请求",
                isContinuous: true,
                dataPoints: dataPoints(\.batchActiveRequests)
            ),
        ]
        // 耗时序列的数据点是「桶里的平均值」，不是某一次请求的耗时（§7.6）。
        let sortedLatency = latency.sorted { $0.capturedAt < $1.capturedAt }
        let latencySeries = [
            ("语音识别耗时（秒）", sortedLatency.compactMap { sample -> AXDataPoint? in
                guard let seconds = sample.asrSeconds else { return nil }
                return AXDataPoint(
                    x: sample.capturedAt.timeIntervalSince1970,
                    y: seconds,
                    label: sample.capturedAt.formatted(.dateTime.hour().minute())
                )
            }),
            ("语音合成耗时（秒）", sortedLatency.compactMap { sample -> AXDataPoint? in
                guard let seconds = sample.ttsSeconds else { return nil }
                return AXDataPoint(
                    x: sample.capturedAt.timeIntervalSince1970,
                    y: seconds,
                    label: sample.capturedAt.formatted(.dateTime.hour().minute())
                )
            }),
        ]
        .filter { !$0.1.isEmpty }
        .map { AXDataSeriesDescriptor(name: $0.0, isContinuous: true, dataPoints: $0.1) }
        let series = requestSeries + latencySeries
        let summary: String
        if let first = sortedPoints.first, let last = sortedPoints.last {
            var text = "共 \(sortedPoints.count) 个数据点，同时处理的请求从 \(first.activeRequests) 变为 \(last.activeRequests)；"
                + "其中 \(seriesNames.first ?? "实时语音会话") \(first.realtimeActiveRequests) → \(last.realtimeActiveRequests)，"
                + "\(seriesNames.dropFirst().first ?? "单次请求") \(first.batchActiveRequests) → \(last.batchActiveRequests)。"
            if !latencySeries.isEmpty {
                text += latencyCaption
            }
            summary = text
        } else {
            summary = "还没有足够的数据点。"
        }
        return AXChartDescriptor(
            title: "同时处理的请求数趋势",
            summary: summary,
            xAxis: xAxis,
            yAxis: yAxis,
            series: series
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
