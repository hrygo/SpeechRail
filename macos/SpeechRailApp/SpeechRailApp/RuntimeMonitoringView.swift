import Charts
import SwiftUI

public struct RuntimeMonitoringView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                SurfaceHeaderView(route: .monitoring)
                GlassEffectContainer(spacing: SpeechRailDesignTokens.Spacing.lg) {
                    metricSummary
                    chartPanel
                    runtimeDetails
                }
                ServiceStatusFooterView()
            }
            .frame(maxWidth: SpeechRailDesignTokens.Layout.contentMaximumWidth, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xl)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .task {
            while !Task.isCancelled {
                await model.refreshMonitoring()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var latestSample: RuntimeMetricsSample? {
        model.monitoringSamples.last
    }

    private var chartPoints: [RuntimeMonitoringChartPoint] {
        model.monitoringSamples.map {
            RuntimeMonitoringChartPoint(
                capturedAt: $0.capturedAt,
                activeRequests: $0.activeRequests
            )
        }
    }

    private var metricSummary: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            alignment: .leading,
            spacing: SpeechRailDesignTokens.Spacing.md
        ) {
            MetricTile(
                title: "活跃请求",
                value: latestSample.map { String($0.activeRequests) } ?? "—",
                detail: "当前正在占用运行资源"
            )
            MetricTile(
                title: "排队请求",
                value: latestSample.map { String($0.pendingRequests) } ?? "—",
                detail: "等待调度的请求"
            )
            MetricTile(
                title: "已处理请求",
                value: latestSample.flatMap { $0.requestCount }.map(formatCount) ?? "—",
                detail: "进程内累计，重启后清零"
            )
            MetricTile(
                title: "队列拒绝",
                value: latestSample.flatMap { $0.queueRejections }.map(formatCount) ?? "—",
                detail: "容量已满时被拒绝的请求"
            )
        }
    }

    private var chartPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("资源脉冲")
                .font(SpeechRailDesignTokens.Typography.panelTitle)
            if !RuntimeMonitoringChartDescriptor.isSufficient(chartPoints) {
                ContentUnavailableView(
                    "等待监控样本",
                    systemImage: "chart.xyaxis.line",
                    description: Text("打开此页面后每 5 秒读取一次本机服务 metrics，至少需要两个样本才绘制趋势。")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                Chart(model.monitoringSamples) { sample in
                    LineMark(
                        x: .value("时间", sample.capturedAt),
                        y: .value("活跃请求", sample.activeRequests)
                    )
                    .foregroundStyle(SpeechRailDesignTokens.Palette.tint)
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value("时间", sample.capturedAt),
                        y: .value("活跃请求", sample.activeRequests)
                    )
                    .foregroundStyle(SpeechRailDesignTokens.Palette.tint)
                }
                .frame(height: 240)
                .chartYAxisLabel("请求数")
                .accessibilityLabel("最近运行监控趋势")
                .accessibilityIdentifier("runtime-chart")
                .accessibilityChartDescriptor(
                    RuntimeMonitoringChartDescriptor(points: chartPoints)
                )
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }

    private var runtimeDetails: some View {
        DisclosureGroup("开发者详情", isExpanded: $showDeveloperDetails) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                if let sample = latestSample {
                    detailRow("ASR 延迟", sample.asrLatencySeconds.map(formatSeconds) ?? "样本不足")
                    detailRow("TTS 延迟", sample.ttsLatencySeconds.map(formatSeconds) ?? "样本不足")
                }
                ForEach(model.metrics?.workers.keys.sorted() ?? [], id: \.self) { key in
                    detailRow("Worker \(key)", model.metrics?.workers[key] ?? "未知")
                }
            }
            .padding(.top, SpeechRailDesignTokens.Spacing.xs)
        }
        .font(SpeechRailDesignTokens.Typography.secondary)
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(SpeechRailDesignTokens.Typography.technical)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
        }
    }

    private func formatCount(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f s", value)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(SpeechRailDesignTokens.Palette.primaryText)
            Text(detail)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailSurface(.panel)
    }
}
