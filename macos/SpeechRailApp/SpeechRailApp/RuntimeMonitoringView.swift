import AppKit
import Charts
import Foundation
import SpeechRailControlKit
import SwiftUI

public struct RuntimeMonitoringView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @State private var showInspector = false
    @State private var reportMessage: String?

    public init() {}

    public var body: some View {
        PageScaffold(route: .monitoring) {
            monitoringSummary
            if let reportMessage {
                Label(reportMessage, systemImage: "checkmark.circle.fill")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ready)
                    .transition(.opacity)
            }
            metricStrip
            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.lg) {
                capabilityPanel
                    .frame(
                        minWidth: SpeechRailDesignTokens.Layout.monitoringCapabilityMinimumWidth,
                        maxWidth: SpeechRailDesignTokens.Layout.monitoringCapabilityIdealWidth,
                        alignment: .topLeading
                    )
                chartPanel
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceActionsMenu(helpText: "读取最新运行样本，或查看 worker 与 metrics 技术详情") {
                    Button {
                        Task { await model.refreshMonitoring() }
                    } label: {
                        Label("刷新监控", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshingMonitoring)
                    Button {
                        copyMonitoringReport()
                    } label: {
                        Label("复制监控摘要", systemImage: "doc.on.clipboard")
                    }
                    .disabled(model.health == nil && model.metrics == nil)
                    Divider()
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(
                            showInspector ? "隐藏开发者详情" : "显示开发者详情",
                            systemImage: "info.circle"
                        )
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
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

    private var metricStrip: some View {
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
                id: "request-rate",
                title: "请求速率",
                value: latestSample?.requestRatePerSecond.map(formatRate) ?? "—",
                detail: "相邻样本窗口"
            ),
            MetricValue(
                id: "asr-rtf",
                title: "ASR RTF",
                value: latestSample?.asrRTF.map(formatRTF) ?? "—",
                detail: latestSample?.asrRTF == nil ? "metrics 未提供" : "越低越快"
            ),
            MetricValue(
                id: "tts-rtf",
                title: "TTS RTF",
                value: latestSample?.ttsRTF.map(formatRTF) ?? "—",
                detail: latestSample?.ttsRTF == nil ? "metrics 未提供" : "越低越快"
            ),
            MetricValue(
                id: "queue-rejections",
                title: "队列拒绝",
                value: latestSample?.queueRejections.map(formatCount) ?? "—",
                detail: "累计；\(rejectionRateDetail)"
            ),
        ])
    }

    private var monitoringSummary: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            Image(systemName: monitoringTone.systemImage)
                .font(SpeechRailDesignTokens.Typography.statusGlyph)
                .foregroundStyle(monitoringTone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(monitoringTitle)
                    .font(SpeechRailDesignTokens.Typography.diagnosticsSummary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(monitoringMessage)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                Text(serviceIdentity)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            VStack(alignment: .trailing, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Label(freshnessTitle, systemImage: freshnessTone.systemImage)
                    .font(SpeechRailDesignTokens.Typography.label)
                    .foregroundStyle(freshnessTone.color)
                Text("\(model.monitoringSamples.count)/60 个样本")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(latestSample.map { "最近样本 · \(relativeTime($0.capturedAt))" } ?? "等待样本")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Layout.diagnosticsSummaryHeight)
        .speechRailContentSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(monitoringTitle)
        .accessibilityValue(
            [monitoringMessage, serviceIdentity, freshnessTitle, lastMetricsRefreshText]
                .joined(separator: "，")
        )
    }

    private var capabilityPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "能力状态",
                detail: "来自最近一次 health 读取。"
            )
            VStack(spacing: 0) {
                MonitoringCapabilityRow(
                    title: "语音转文字",
                    detail: model.health?.asrState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取",
                    ready: model.health?.asrReady
                )
                Divider()
                MonitoringCapabilityRow(
                    title: "文字转语音",
                    detail: model.health?.ttsState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取",
                    ready: model.health?.ttsReady
                )
                Divider()
                MonitoringCapabilityRow(
                    title: "实时语音",
                    detail: model.health?.streamingState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取",
                    ready: model.health?.realtimeVAD?.ready
                )
                Divider()
                MonitoringCapabilityRow(
                    title: "分人识别",
                    detail: model.health?.diarization.map(SpeechRailDiarizationPresentation.text)
                        ?? "按当前档位启用",
                    ready: model.health?.diarizationReady
                )
                if let workers = model.metrics?.workers, !workers.isEmpty {
                    Divider()
                    SectionHeading(
                        title: "运行组件",
                        detail: "来自最近一次 metrics 读取的生命周期状态。"
                    )
                    ForEach(workers.keys.sorted(), id: \.self) { key in
                        workerRow(key: key, state: workers[key] ?? "unknown")
                    }
                }
            }
            Divider()
            resourceSection
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailContentSurface()
    }

    private var resourceSection: some View {
        let resources = latestResources
        let budget = resources?.memoryBudgetBytes.map(formatBytes) ?? "未提供"
        let physicalMemory = resources?.physicalMemoryBytes.map(formatBytes) ?? "未提供"
        let declaredFootprint = resources?.declarationComplete == true
            ? resources?.declaredFootprintBytes.map(formatBytes) ?? "未提供"
            : "未提供"
        let physicalFootprint = resources?.physicalFootprintComplete == true
            ? resources?.physicalFootprintBytes.map(formatBytes) ?? "未提供"
            : "未提供"
        let overlapAllowed = resources?.heavyOverlapAllowed
        let overlapTitle = switch overlapAllowed {
        case .some(true): "允许重计算并行"
        case .some(false): "重计算串行准入"
        case .none: "准入策略未读取"
        }
        let overlapDetail: String
        if resources != nil {
            let rejection = latestSample?.queueRejections.map(formatCount) ?? "未读取"
            let overlapPolicy = overlapAllowed == true ? "策略允许重叠" : "策略限制重叠"
            overlapDetail = "队列拒绝累计 \(rejection)；\(overlapPolicy)"
        } else {
            overlapDetail = "metrics 未提供资源策略"
        }

        return VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "资源与准入",
                detail: "实测 footprint 与配置预算分开显示，不用模型大小替代内存占用。"
            )
            resourceRow(
                title: "主机物理内存",
                value: physicalMemory,
                detail: resources == nil ? "metrics 未提供" : "用于计算服务预算",
                tone: resources?.physicalMemoryBytes == nil ? .neutral : .healthy
            )
            Divider()
            resourceRow(
                title: "服务内存预算",
                value: budget,
                detail: "当前重计算准入上限",
                tone: resources?.memoryBudgetBytes == nil ? .neutral : .attention
            )
            Divider()
            resourceRow(
                title: "声明常驻占用",
                value: declaredFootprint,
                detail: "配置估算，非实测 footprint",
                tone: resources?.declarationComplete == true ? .attention : .neutral
            )
            Divider()
            resourceRow(
                title: "服务 physical footprint",
                value: physicalFootprint,
                detail: resources?.physicalFootprintComplete == true
                    ? "macOS footprint 完整采样"
                    : "采样不完整，不展示部分总量",
                tone: resources?.physicalFootprintComplete == true ? .healthy : .neutral
            )
            Divider()
            resourceRow(
                title: overlapTitle,
                value: overlapAllowed == nil ? "未提供" : "已读取",
                detail: overlapDetail,
                tone: overlapAllowed.map { $0 ? StatusTone.healthy : .attention } ?? .neutral
            )
        }
    }

    private func resourceRow(
        title: String,
        value: String,
        detail: String,
        tone: StatusTone
    ) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: tone.systemImage)
                .foregroundStyle(tone.color)
                .imageScale(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.label)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.technical)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)，\(detail)")
    }

    private var latestResources: RuntimeResourceSnapshot? {
        latestSample?.resources ?? model.metrics?.resources
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
                systemImage: AppRoute.monitoring.systemImage,
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
            if let message = model.monitoringMessage, !message.isEmpty {
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(monitoringTone.color)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailContentSurface()
    }

    @ViewBuilder
    private var monitoringInspector: some View {
        DeveloperInspector {
            SectionHeading(
                title: "运行样本",
                detail: "这些字段面向排障和容量判断，不代表服务质量或模型质量结论。"
            )
            LabeledContent("服务状态", value: model.service.serviceState)
            LabeledContent("最近成功读取 health", value: model.lastHealthRefresh.map(relativeTime) ?? "未读取")
            LabeledContent("最近成功读取 metrics", value: model.lastMetricsRefresh.map(relativeTime) ?? "未读取")
            LabeledContent("最近采样", value: latestSample.map { relativeTime($0.capturedAt) } ?? "未读取")
            LabeledContent("数据新鲜度", value: freshnessTitle)
            LabeledContent("样本数量", value: "\(model.monitoringSamples.count)/60")
            if let message = model.metricsMessage, !message.isEmpty {
                detailRow("Metrics 错误", SpeechRailOperationMessagePresentation.text(message))
            }
            if let sample = latestSample {
                Divider()
                detailRow("ASR 延迟", sample.asrLatencySeconds.map(formatSeconds) ?? "样本不足")
                detailRow("TTS 延迟", sample.ttsLatencySeconds.map(formatSeconds) ?? "样本不足")
                detailRow("ASR RTF", sample.asrRTF.map(formatRTF) ?? "未提供")
                detailRow("TTS RTF", sample.ttsRTF.map(formatRTF) ?? "未提供")
                detailRow("TTS 首帧", sample.ttsTTFASeconds.map(formatSeconds) ?? "样本不足")
                detailRow("实时会话", sample.activeRealtimeSessions.map(String.init) ?? "样本不足")
                detailRow("活跃请求", String(sample.activeRequests))
                detailRow("排队请求", String(sample.pendingRequests))
                detailRow("请求窗口速率", sample.requestRatePerSecond.map(formatRate) ?? "样本不足")
                detailRow("拒绝窗口速率", sample.queueRejectionRatePerSecond.map(formatRate) ?? "样本不足")
            }
            if let resources = latestResources {
                Divider()
                Text("资源与准入")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                detailRow("主机物理内存", resources.physicalMemoryBytes.map(formatBytes) ?? "未提供")
                detailRow("服务内存预算", resources.memoryBudgetBytes.map(formatBytes) ?? "未提供")
                detailRow(
                    "声明常驻占用",
                    resources.declaredFootprintBytes.map(formatBytes) ?? "未提供"
                )
                detailRow(
                    "Physical footprint",
                    resources.physicalFootprintComplete == true
                        ? resources.physicalFootprintBytes.map(formatBytes) ?? "未提供"
                        : "未提供（采样不完整）"
                )
                detailRow(
                    "重计算重叠",
                    resources.heavyOverlapAllowed.map { $0 ? "允许" : "串行" } ?? "未提供"
                )
                if let reason = resources.heavyOverlapReason, !reason.isEmpty {
                    detailRow("策略原因", reason)
                }
                ForEach(resources.declaredComponentBytes.keys.sorted(), id: \.self) { key in
                    detailRow(
                        "声明 · \(key)",
                        resources.declaredComponentBytes[key].flatMap { $0 }.map(formatBytes) ?? "未知"
                    )
                }
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

    private func formatRTF(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func formatBytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }

    private func formatRate(_ value: Double) -> String {
        String(format: "%.2f /s", value)
    }

    private var rejectionRateDetail: String {
        latestSample?.queueRejectionRatePerSecond.map { "窗口 \(formatRate($0))" }
            ?? "等待两个样本"
    }

    private func relativeTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private var serviceIdentity: String {
        let profile = model.health?.profile.map { SpeechRailProfilePresentation.title($0) }
            ?? model.profile?.preset.map { SpeechRailProfilePresentation.title($0) }
            ?? "档位未读取"
        let version = model.health?.version ?? "版本未读取"
        return profile + " · " + version
    }

    private var lastHealthRefreshText: String {
        model.lastHealthRefresh.map { "health 最近成功 · \(relativeTime($0))" } ?? "health 尚无成功读取"
    }

    private var lastMetricsRefreshText: String {
        model.lastMetricsRefresh.map { "metrics 最近成功 · \(relativeTime($0))" } ?? "metrics 尚无成功读取"
    }

    private var freshnessTone: StatusTone {
        if model.isRefreshingMonitoring { return .attention }
        if model.healthMessage != nil || model.service.serviceState == "unavailable" {
            return .critical
        }
        if model.metricsMessage != nil || model.metrics == nil {
            return .attention
        }
        return .healthy
    }

    private var freshnessTitle: String {
        if model.isRefreshingMonitoring { return "正在刷新" }
        if model.healthMessage != nil || model.service.serviceState == "unavailable" {
            return "服务不可用"
        }
        if model.metricsMessage != nil {
            return "数据已过期"
        }
        if model.metrics == nil {
            return "等待数据"
        }
        return "数据新鲜"
    }

    private func copyMonitoringReport() {
        let formatter = ISO8601DateFormatter()
        let resource = latestResources
        let workerLines = (model.metrics?.workers ?? [:])
            .keys
            .sorted()
            .map { key in
                "- \(key): \(model.metrics?.workers[key] ?? "unknown")"
            }
            .joined(separator: "\n")
        let report = """
        SpeechRail 脱敏监控摘要
        generated_at: \(formatter.string(from: Date()))
        service_state: \(model.service.serviceState)
        profile: \(model.health?.profile?.rawValue ?? model.profile?.preset?.rawValue ?? "未读取")
        version: \(model.health?.version ?? "未读取")
        health_ready: \(model.health?.ready.map { $0 ? "true" : "false" } ?? "未读取")
        metrics_updated_at: \(model.lastMetricsRefresh.map { formatter.string(from: $0) } ?? "未读取")
        sample_count: \(model.monitoringSamples.count)/60
        freshness: \(freshnessTitle)

        workers:
        \(workerLines.isEmpty ? "- 未提供" : workerLines)

        resources:
        - physical_memory: \(resource?.physicalMemoryBytes.map(formatBytes) ?? "未提供")
        - memory_budget: \(resource?.memoryBudgetBytes.map(formatBytes) ?? "未提供")
        - declared_footprint: \(resource?.declaredFootprintBytes.map(formatBytes) ?? "未提供")
        - physical_footprint: \(resource?.physicalFootprintComplete == true ? resource?.physicalFootprintBytes.map(formatBytes) ?? "未提供" : "未提供（采样不完整）")
        - heavy_overlap: \(resource?.heavyOverlapAllowed.map { $0 ? "allowed" : "serialized" } ?? "未提供")
        - heavy_overlap_reason: \(resource?.heavyOverlapReason ?? "未提供")
        """
        _ = NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(report, forType: .string) {
            withAnimation(.easeOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
                reportMessage = "已复制脱敏监控摘要"
            }
        } else {
            reportMessage = "复制失败，请稍后重试"
        }
    }

    private func workerRow(key: String, state: String) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: workerTone(for: state).systemImage)
                .foregroundStyle(workerTone(for: state).color)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(workerTitle(for: key))
                .font(SpeechRailDesignTokens.Typography.label)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Text(workerStateText(for: state))
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(workerTone(for: state).color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workerTitle(for: key))
        .accessibilityValue(workerStateText(for: state))
    }

    private func workerTitle(for key: String) -> String {
        switch key.lowercased() {
        case "asr":
            "ASR 语音识别"
        case "tts":
            "TTS 语音合成"
        case "diarization":
            "分人识别"
        case "realtime_vad":
            "实时语音检测"
        default:
            key
        }
    }

    private func workerStateText(for state: String) -> String {
        SpeechRailRuntimeStatePresentation.text(state)
    }

    private func workerTone(for state: String) -> StatusTone {
        switch state.lowercased() {
        case "active", "warm_standby":
            .healthy
        case "cold_evicted", "inactive", "unconfigured":
            .attention
        case "failed":
            .critical
        case "starting", "stopping":
            .attention
        default:
            .neutral
        }
    }

    private var monitoringTone: StatusTone {
        if model.isRefreshingMonitoring {
            return .attention
        }
        if model.service.serviceState == "unavailable" || model.healthMessage != nil {
            return .critical
        }
        if model.metricsMessage != nil || model.metrics == nil || model.monitoringMessage != nil {
            return .attention
        }
        if model.health?.ready == false || model.health == nil || model.metrics == nil {
            return .attention
        }
        return .healthy
    }

    private var monitoringTitle: String {
        return switch monitoringTone {
        case .healthy:
            "运行稳定"
        case .attention:
            model.metricsMessage == nil ? "等待运行状态" : "运行数据已过期"
        case .critical:
            "无法读取服务状态"
        case .neutral:
            "等待运行状态"
        }
    }

    private var monitoringMessage: String {
        if model.isRefreshingMonitoring {
            return "正在读取本机服务 health 和 metrics。"
        }
        if let message = model.healthMessage {
            return "\(message) \(lastHealthRefreshText)。"
        }
        if let message = model.metricsMessage {
            return "\(SpeechRailOperationMessagePresentation.text(message))；保留最近可信样本，\(lastMetricsRefreshText)。"
        }
        return switch monitoringTone {
        case .healthy:
            "已读取本机服务 health 和 metrics，当前数据可用于判断负载。"
        case .attention:
            "服务可能正在启动，或当前能力还没有准备完成。"
        case .critical:
            model.monitoringMessage ?? "控制中心暂时无法连接到 SpeechRail。"
        case .neutral:
            "打开此页面后会自动读取本机运行状态。"
        }
    }
}

private struct MonitoringCapabilityRow: View {
    let title: String
    let detail: String
    let ready: Bool?

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: iconName)
                .foregroundStyle(statusColor)
                .imageScale(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.label)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(statusText)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(statusText)，\(detail)")
    }

    private var iconName: String {
        switch ready {
        case .some(true):
            "checkmark.circle.fill"
        case .some(false):
            "xmark.circle.fill"
        case .none:
            "questionmark.circle"
        }
    }

    private var statusText: String {
        switch ready {
        case .some(true):
            "正常"
        case .some(false):
            "未就绪"
        case .none:
            "未读取"
        }
    }

    private var statusColor: Color {
        switch ready {
        case .some(true):
            SpeechRailDesignTokens.Color.ready
        case .some(false):
            SpeechRailDesignTokens.Color.critical
        case .none:
            SpeechRailDesignTokens.Color.inkSecondary
        }
    }
}
