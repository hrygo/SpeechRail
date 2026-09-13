import Charts
import SwiftUI

public struct RuntimeMonitoringView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @State private var showInspector = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                PageIntroView(route: .monitoring)
                metricSummary
                chartPanel
            }
            .frame(maxWidth: SpeechRailDesignTokens.Layout.contentMaximumWidth, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xl)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("开发者详情", systemImage: "info.circle")
                }
                .help("查看 worker、延迟样本和 metrics 读取状态")
            }
            ToolbarItem {
                Button {
                    Task { await model.refreshMonitoring() }
                } label: {
                    Label("刷新监控", systemImage: "arrow.clockwise")
                }
                .help("立即读取一次本机服务 metrics")
            }
        }
        .inspector(isPresented: $showInspector) {
            monitoringInspector
        }
        .task {
            showInspector = showDeveloperDetails
            while !Task.isCancelled {
                await model.refreshMonitoring()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: showInspector) { _, value in
            showDeveloperDetails = value
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
        MetricStrip(metrics: [
            MetricValue(
                id: "active-requests",
                title: "活跃请求",
                value: latestSample.map { String($0.activeRequests) } ?? "—",
                detail: "正在占用运行资源"
            ),
            MetricValue(
                id: "pending-requests",
                title: "排队请求",
                value: latestSample.map { String($0.pendingRequests) } ?? "—",
                detail: "等待调度"
            ),
            MetricValue(
                id: "request-count",
                title: "已处理请求",
                value: latestSample.flatMap { $0.requestCount }.map(formatCount) ?? "—",
                detail: "进程内累计"
            ),
            MetricValue(
                id: "queue-rejections",
                title: "队列拒绝",
                value: latestSample.flatMap { $0.queueRejections }.map(formatCount) ?? "—",
                detail: "容量已满时拒绝"
            ),
        ])
    }

    private var chartPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(
                    title: "资源脉冲",
                    detail: "每 5 秒采样一次活跃请求；趋势只展示当前 App 会话内的数据。"
                )
                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                Text(latestSample == nil ? "等待首个样本" : "自动刷新 · 5 秒")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            if !RuntimeMonitoringChartDescriptor.isSufficient(chartPoints) {
                ContentUnavailableView(
                    "等待监控样本",
                    systemImage: "chart.xyaxis.line",
                    description: Text("打开此页面后读取本机服务 metrics，至少需要两个样本才绘制趋势。")
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.monitoringEmptyMinimumHeight
                )
            } else {
                Chart(model.monitoringSamples) { sample in
                    LineMark(
                        x: .value("时间", sample.capturedAt),
                        y: .value("活跃请求", sample.activeRequests)
                    )
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    .interpolationMethod(.catmullRom)
                    PointMark(
                        x: .value("时间", sample.capturedAt),
                        y: .value("活跃请求", sample.activeRequests)
                    )
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                }
                .frame(height: SpeechRailDesignTokens.Layout.monitoringChartHeight)
                .chartYAxisLabel("请求数")
                .accessibilityLabel("最近运行监控趋势")
                .accessibilityIdentifier("runtime-chart")
                .accessibilityChartDescriptor(
                    RuntimeMonitoringChartDescriptor(points: chartPoints)
                )
            }
            if let message = model.message, !message.isEmpty {
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
    }

    @ViewBuilder
    private var monitoringInspector: some View {
        DeveloperInspector {
            SectionHeading(
                title: "运行样本",
                detail: "这些字段面向排障和容量判断，不代表服务质量或模型质量结论。"
            )
            LabeledContent("服务状态", value: model.service.serviceState)
            LabeledContent("最近采样", value: latestSample.map { relativeTime($0.capturedAt) } ?? "未读取")
            if let sample = latestSample {
                Divider()
                detailRow("ASR 延迟", sample.asrLatencySeconds.map(formatSeconds) ?? "样本不足")
                detailRow("TTS 延迟", sample.ttsLatencySeconds.map(formatSeconds) ?? "样本不足")
                detailRow("活跃请求", String(sample.activeRequests))
                detailRow("排队请求", String(sample.pendingRequests))
            }
            if !(model.metrics?.workers.isEmpty ?? true) {
                Divider()
                Text("Worker")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                ForEach(model.metrics?.workers.keys.sorted() ?? [], id: \.self) { key in
                    detailRow(key, model.metrics?.workers[key] ?? "未知")
                }
            }
            if let health = model.health {
                Divider()
                Text("能力状态")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                detailRow("ASR", health.asrReady == true ? "ready" : "not ready")
                detailRow("TTS", health.ttsReady == true ? "ready" : "not ready")
                detailRow("Realtime", health.realtimeVAD?.ready == true ? "ready" : "not ready")
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(SpeechRailDesignTokens.Typography.technical)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
    }

    private func formatCount(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f s", value)
    }

    private func relativeTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
