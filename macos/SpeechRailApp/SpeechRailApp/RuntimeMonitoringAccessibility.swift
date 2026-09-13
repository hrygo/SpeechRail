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
