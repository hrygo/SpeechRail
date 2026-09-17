import AppKit
import Charts
import Foundation
import SpeechRailControlKit
import SwiftUI

public struct RuntimeMonitoringView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 开发者详情是全 App 的一个偏好（View ▸ 显示/隐藏开发者详情 ⌘⌥I）。
    @AppStorage("speechrail.showDeveloperDetails") private var showInspector = false
    @State private var timeWindow = MonitoringTimeWindow.fiveMinutes
    @State private var reportMessage: String?
    @State private var showsDetail = false

    /// The chart samples are session-scoped, so the window only ever trims the
    /// buffer the app already holds (REDESIGN-SPEC §7.6).
    ///
    /// 2026-09-16 起，「时间窗」分成两类数据源：前三档仍然只裁剪 App 内存里的采样
    /// （5 秒粒度、最多 5 分钟），后四档读服务落盘的历史指标（60 秒/行、跨重启保留、
    /// 默认留 30 天）。两类数据的粒度与存活范围不同，所以页面必须说清当前看的是哪一类。
    private enum MonitoringTimeWindow: String, CaseIterable, Identifiable {
        case oneMinute
        case fiveMinutes
        case session
        case oneHour
        case oneDay
        case sevenDays
        case thirtyDays

        var id: String { rawValue }

        var title: String {
            switch self {
            case .oneMinute: "1 分钟"
            case .fiveMinutes: "5 分钟"
            case .session: "本次会话"
            case .oneHour: "最近 1 小时"
            case .oneDay: "最近 24 小时"
            case .sevenDays: "最近 7 天"
            case .thirtyDays: "最近 30 天"
            }
        }

        /// 选择器上的短标签（菜单里用短词，结论句里用完整说法）。
        var shortTitle: String {
            switch self {
            case .oneHour: "1 小时"
            case .oneDay: "24 小时"
            case .sevenDays: "7 天"
            case .thirtyDays: "30 天"
            default: title
            }
        }

        var interval: TimeInterval? {
            switch self {
            case .oneMinute: 60
            case .fiveMinutes: 300
            case .session: nil
            case .oneHour, .oneDay, .sevenDays, .thirtyDays: nil
            }
        }

        /// 历史窗口的跨度（秒）。`nil` 表示这一档读 App 自己的内存采样。
        var historySeconds: TimeInterval? {
            switch self {
            case .oneHour: 3_600
            case .oneDay: 86_400
            case .sevenDays: 604_800
            case .thirtyDays: 2_592_000
            case .oneMinute, .fiveMinutes, .session: nil
            }
        }

        var bucketSeconds: TimeInterval? {
            historySeconds.map { MetricsHistoryLoader.bucketSeconds(forWindowSeconds: $0) }
        }

        var isHistory: Bool { historySeconds != nil }

        /// 结论句里的时间说法。样本是 App 会话级的，所以「本次会话」的准确说法是
        /// 「这次打开 App 以来」——它不会超过 60 个采样点（5 分钟）。
        var phrase: String {
            switch self {
            case .oneMinute: "最近 1 分钟"
            case .fiveMinutes: "最近 5 分钟"
            case .session: "这次打开 App 以来"
            case .oneHour: "最近 1 小时"
            case .oneDay: "最近 24 小时"
            case .sevenDays: "最近 7 天"
            case .thirtyDays: "最近 30 天"
            }
        }
    }

    public init() {}

    public var body: some View {
        // 页首那句话取 `AppRoute.monitoring.pageSubtitle`。这一页原先自己拼
        // 「最近 n 个样本 · 刷新间隔 5 秒」——那句话讲的是采样机制，没有一个字在说
        // 这一页到底看什么（REDESIGN-SPEC §7.6，2026-09-16 用户复核）。
        PageScaffold(route: .monitoring) {
            if isAwaitingFirstSample {
                loadingState
            } else {
                monitoringSummary
                if let reportMessage {
                    Label(reportMessage, systemImage: "checkmark.circle.fill")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ready)
                        .transition(.opacity)
                }
                if isHistoryWindow {
                    historyMetricStrip
                } else {
                    metricStrip
                }
                // The time series is the page, so it gets the full width and the
                // top slot instead of sharing a row with a capability panel
                // (REDESIGN-SPEC §7.6).
                if isHistoryWindow {
                    historyChartPanel
                } else {
                    chartPanel
                }
                // Figma 把「运行组件」放在图表卡之后：先看趋势，再看是谁在跑。
                runtimeComponentsSection
                // 首屏只留黄金信号与趋势；逐指标表、资源明细和能力状态收进一个
                // 默认收起的明细区（用户全局指令：不堆密集信息，渐进式披露）。
                metricsDetailSection
            }
        } trailing: {
            timeWindowPicker
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // 这一页每 5 秒自己采样一次，所以头部没有「刷新」——手动重读
                // 留在 ⌘R（`reloadPageCommand`）与开发者详情里。
                PageActionButton(
                    systemImage: "doc.on.clipboard",
                    helpText: "复制监控摘要",
                    isEnabled: !(displayedHealth == nil && model.metrics == nil)
                ) {
                    copyMonitoringReport()
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .focusedSceneValue(
            \.reloadPageCommand,
            ReloadPageCommand(title: "立即采样一次") {
                Task { await model.refreshMonitoring() }
            }
        )
        .inspector(isPresented: $showInspector) {
            monitoringInspector
        }
        .task {
            while !Task.isCancelled {
                await model.refreshMonitoring()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // 历史按分钟级数据更新，没必要跟 5 秒轮询同频；切档后立刻读一次，
        // 之后每 60 秒重读，服务新写的行会自己出现。
        .task(id: timeWindow) {
            guard let seconds = timeWindow.historySeconds else { return }
            while !Task.isCancelled {
                await model.refreshMonitoringHistory(
                    windowSeconds: seconds,
                    bucketSeconds: timeWindow.bucketSeconds
                )
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var latestSample: RuntimeMetricsSample? {
        model.monitoringSamples.last
    }

    /// REDESIGN-SPEC §8：服务四页的「加载中」是 `ProgressView`。§7.6 的
    /// 「还没有运行数据」是**已读过**但服务没有数据时的空态，两者不能互换：
    /// 首次读取还没落地就宣告「还没有运行数据」，读起来像服务有问题。
    private var isAwaitingFirstSample: Bool {
        model.monitoringSamples.isEmpty
            && model.lastHealthRefresh == nil
            && model.healthFailure == nil
    }

    private var loadingState: some View {
        ProgressView("正在读取运行数据…")
            .frame(
                maxWidth: .infinity,
                minHeight: SpeechRailDesignTokens.Layout.emptyStateMinimumHeight
            )
            .speechRailContentSurface()
    }

    /// A cached health snapshot is useful for comparison, but it must not be
    /// presented as current runtime truth after the latest health read fails.
    private var displayedHealth: HealthSnapshot? {
        guard model.healthFailure == nil else { return nil }
        return model.health
    }

    private var chartPoints: [RuntimeMonitoringChartPoint] {
        model.monitoringSamples.map {
            RuntimeMonitoringChartPoint(
                capturedAt: $0.capturedAt,
                activeRequests: $0.activeRequests,
                realtimeActiveRequests: $0.realtimeActiveRequests,
                batchActiveRequests: $0.batchActiveRequests
            )
        }
    }

    /// 首屏的六个数字，每个答一个用户会真的问出口的问题：
    /// 它现在在干嘛（正在处理）／我用了多少（合成、识别）／快不快（耗时）／有没有出错（失败）。
    ///
    /// 口径因此换了两次，都是有意的（REDESIGN-SPEC §7.6，2026-09-16 用户复核）：
    /// 一是只数语音接口，把 App 自己每 5 秒的轮询（`/health`、`/metrics`、`/v1/models`、
    /// `/v1/voices`）排除在外——本机实测它们占累计请求的 97.6%（1188 次里 1159 次），
    /// 留着这个数字就既不跟用户的行为走、也不反映工作量；二是首屏报「次数」，不报 `rate` 与 `%`。
    /// Prometheus 的读法（`rate`、窗口均值、直方图累计）原样保留在折叠明细与 Inspector 里。
    private var metricStrip: some View {
        let usage = window.usageIncrease
        return MetricStrip(metrics: [
            MetricValue(
                id: "in-flight",
                title: "正在处理",
                value: latestSample.map { "\($0.activeRequests) 个" } ?? "—",
                detail: inFlightDetail
            ),
            MetricValue(
                id: "tts-usage",
                title: "语音合成",
                value: requestCountText(usage.ttsRequests),
                detail: usageDetail(
                    requestCount: usage.ttsRequests,
                    audioSeconds: usage.ttsAudioSeconds,
                    action: "合成"
                )
            ),
            MetricValue(
                id: "asr-usage",
                title: "语音识别",
                value: requestCountText(usage.asrRequests),
                detail: usageDetail(
                    requestCount: usage.asrRequests,
                    audioSeconds: usage.asrAudioSeconds,
                    action: "识别"
                )
            ),
            MetricValue(
                id: "tts-latency",
                title: "合成耗时",
                value: window.ttsLatencySeconds.map(formatDuration) ?? "—",
                detail: latencyDetail(requestCount: usage.ttsRequests)
            ),
            MetricValue(
                id: "asr-latency",
                title: "识别耗时",
                value: window.asrLatencySeconds.map(formatDuration) ?? "—",
                detail: latencyDetail(requestCount: usage.asrRequests)
            ),
            MetricValue(
                id: "failures",
                title: "失败请求",
                value: failureCountText,
                detail: failureDetail
            ),
        ])
    }

    /// 「正在处理」的副行：空闲就说空闲，忙的时候说清楚在等什么。
    private var inFlightDetail: String {
        guard let sample = latestSample else { return "等待样本" }
        if sample.activeRequests == 0 && sample.pendingRequests == 0 {
            return "现在空闲"
        }
        let sessions = sample.activeRealtimeSessions.map(String.init)
            ?? String(sample.realtimeActiveRequests)
        return "排队 \(sample.pendingRequests) · 实时会话 \(sessions)"
    }

    /// 次数：`3 次` / `0 次`（真的没有）/ `—`（读不到）。0 与「读不到」是两件事，
    /// 不能用同一个符号（REDESIGN-SPEC §7.6）。
    ///
    /// 计数器序列只在第一次自增时出现，所以「服务在跑、metrics 读得到、却没有这条序列」
    /// 就是这期间没有用过它——那是 0 次。只有连 metrics 本身都读不到时才显示「—」。
    private func requestCountText(_ value: Double?) -> String {
        if let value { return "\(formatCount(value)) 次" }
        return model.metrics == nil ? "—" : "0 次"
    }

    /// 用量副行：把「做了几次」和「一共多少音频」放在一起——次数相等时，音频长短
    /// 差别很大，用户关心的往往是后者。
    private func usageDetail(
        requestCount: Double?,
        audioSeconds: Double?,
        action: String
    ) -> String {
        guard requestCount != nil || audioSeconds != nil else {
            // 读不到 metrics 时不能说「没有合成」——那是在把缺数据讲成事实。
            return model.metricsMessage == nil ? "这段时间没有\(action)" : "读不到用量"
        }
        guard let seconds = audioSeconds, seconds > 0 else {
            return requestCount.map { $0 > 0 } == true ? "音频时长未提供" : "这段时间没有\(action)"
        }
        return "共 \(formatAudioDuration(seconds))"
    }

    /// 耗时副行必须说明它是平均值、并给出证据量：「0.42 秒」单独放着，用户无法判断
    /// 它是一次的结果还是一百次的平均。
    private func latencyDetail(requestCount: Double?) -> String {
        guard let count = requestCount, count > 0 else { return "这段时间没有样本" }
        return "\(formatCount(count)) 次请求的平均"
    }

    private var failureCountText: String {
        guard let errors = window.errorIncrease else { return "—" }
        return "\(formatCount(errors)) 次"
    }

    private var failureDetail: String {
        guard let errors = window.errorIncrease else { return "等待样本" }
        return errors > 0 ? "服务返回的 5xx 错误" : "这段时间没有失败"
    }

    private var monitoringSummary: some View {
        ViewThatFits(in: .horizontal) {
            monitoringSummaryHorizontal
            monitoringSummaryVertical
        }
        .padding(.horizontal, SpeechRailDesignTokens.Layout.cardInset)
        .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Layout.diagnosticsSummaryHeight)
        .speechRailContentSurface()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(monitoringTitle)
        .accessibilityValue(
            [monitoringMessage, serviceIdentity, freshnessTitle, lastMetricsRefreshText]
                .joined(separator: "，")
        )
    }

    private var monitoringSummaryHorizontal: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
            monitoringSummaryIcon
            monitoringSummaryCopy
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            monitoringFreshness(alignment: .trailing)
        }
    }

    private var monitoringSummaryVertical: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                monitoringSummaryIcon
                monitoringSummaryCopy
            }
            monitoringFreshness(alignment: .leading)
        }
    }

    private var monitoringSummaryIcon: some View {
        Image(systemName: monitoringTone.systemImage)
            .font(SpeechRailDesignTokens.Typography.statusGlyph)
            .foregroundStyle(monitoringTone.color)
            .accessibilityHidden(true)
    }

    private var monitoringSummaryCopy: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(monitoringTitle)
                .font(SpeechRailDesignTokens.Typography.diagnosticsSummary)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(monitoringMessage)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Text(serviceIdentity)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func monitoringFreshness(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Label(freshnessTitle, systemImage: freshnessTone.systemImage)
                .font(SpeechRailDesignTokens.Typography.label)
                .foregroundStyle(freshnessTone.color)
            // 数据点数量在运行组件卡的页脚里（`sampleWindowNote`），这里只留
            // 「这些数字有多新」这一件事。
            Text(monitoringFreshnessDetail)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    /// 渐进式披露区：默认收起。四个明细块共用一张卡，展开后是段落而不是并列的
    /// 四张卡——首屏之外不需要再叠一层卡片（用户全局指令：渐进式披露）。
    private var metricsDetailSection: some View {
        CardSurface {
            DisclosureGroup(isExpanded: $showsDetail) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                    capabilityPanel
                    Divider()
                    resourcePanel
                    Divider()
                    voiceClassLatencyPanel
                    Divider()
                    histogramSummarySection
                }
                .padding(.top, SpeechRailDesignTokens.Spacing.md)
            } label: {
                SectionHeading(
                    title: "更多细节",
                    detail: "内存占用、服务能力、不同音色类型的耗时，以及服务启动以来的累计统计。"
                )
            }
            .disclosureGroupStyle(SpeechRailDisclosureGroupStyle())
            // 与图表卡同一档（`Layout.cardInset`，稿 18）——同一页的卡片不留两套内边距。
            .padding(SpeechRailDesignTokens.Layout.cardInset)
        }
    }

    /// 新鲜度槽的副行：历史档说「最后一条历史记录是什么时候」，实时档说「最近一次采样」。
    /// 两句话回答的是同一个问题——这些数字有多新——但数据源不同，不能混用。
    private var monitoringFreshnessDetail: String {
        if let history, let last = history.lastRecordedAt {
            return "最后一条历史 · \(relativeTime(last))"
        }
        return latestSample.map { "最近样本 · \(relativeTime($0.capturedAt))" } ?? "等待样本"
    }

    private var capabilityPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(
                title: "服务能力",
                detail: "来自最近一次状态读取；能力按当前档位如实发布。"
            )
            .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
            VStack(spacing: 0) {
                MonitoringCapabilityRow(
                    // 与首屏、运行组件表同一套词：服务状态页的能力矩阵也叫「语音识别」。
                    // 同一页里一半叫「语音转文字」、一半叫「语音识别」，就是这一轮在修的那种不一致。
                    title: "语音识别",
                    detail: displayedHealth?.asrState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取",
                    ready: displayedHealth?.asrReady
                )
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                Divider()
                MonitoringCapabilityRow(
                    title: "语音合成",
                    detail: displayedHealth?.ttsState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取",
                    ready: displayedHealth?.ttsReady
                )
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                Divider()
                MonitoringCapabilityRow(
                    title: "实时语音",
                    detail: displayedHealth?.streamingState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取",
                    ready: displayedHealth?.realtimeVAD?.ready
                )
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                Divider()
                MonitoringCapabilityRow(
                    title: "分人识别",
                    detail: displayedHealth?.diarization.map(SpeechRailDiarizationPresentation.text)
                        ?? "按当前档位启用",
                    ready: displayedHealth?.diarizationReady
                )
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            }
        }
    }

    private var resourcePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(
                title: "内存与并行",
                detail: "实测占用与配置上限分开显示；模型文件大小不算内存占用。"
            )
            .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
            resourceSection
        }
    }

    /// 稿把「平均时延 / 样本」画在 worker 表里，但 `/metrics` 的时延直方图并不按
    /// worker 暴露：`speechrail_tts_inference_duration_seconds` 上唯一存在的维度是
    /// `voice_class`。所以这里如实拆音色类别，而不是编一张按 worker 的表
    /// （REDESIGN-SPEC §7.6）。
    private var voiceClassLatencyPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(
                title: "不同音色类型的合成耗时",
                detail: "系统音色、我的音色、参考音色分开统计；这段时间没有样本的类型不列出。"
            )
            .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
            if voiceClassLatencyRows.isEmpty {
                Label("这段时间没有合成样本", systemImage: "hourglass")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SpeechRailDesignTokens.List.compactRowHeight,
                        alignment: .leading
                    )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(voiceClassLatencyRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider()
                        }
                        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                            Text(RuntimeHistogramPresentation.voiceClassTitle(row.voiceClass))
                                .font(SpeechRailDesignTokens.Typography.body)
                            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                            Text(formatSeconds(row.seconds))
                                .font(SpeechRailDesignTokens.Typography.technical)
                                .monospacedDigit()
                            Text("样本 \(Int(row.count.rounded()))")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .monospacedDigit()
                        }
                        .frame(minHeight: SpeechRailDesignTokens.List.compactRowHeight)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var voiceClassLatencyRows: [RuntimeVoiceClassLatency] {
        window.ttsLatencyByVoiceClass
    }

    /// Figma `workers`：标题带 + worker 表 + 说明带。「运行组件」在原实现里和
    /// 能力状态共用一张卡，矩阵与表叠在一起，看不出这是两组不同的数据。
    private var runtimeComponentsSection: some View {
        CardSurface {
            CardHead(
                title: "运行组件",
                // 这张表答的是「哪些模型现在占着内存」——也包括「为什么空闲一阵之后
                // 第一次用会慢一点」。原先的「worker 生命周期状态」是引擎自己的说法
                // （REDESIGN-SPEC §7.6，2026-09-16 用户复核）。
                detail: "哪些模型现在留在内存里、哪些已经释放；空闲一段时间后会自动释放，下次使用再加载。"
            )
            Divider()
            if workerRows.isEmpty {
                Label("还没有组件状态", systemImage: "hourglass")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SpeechRailDesignTokens.List.compactRowHeight,
                        alignment: .leading
                    )
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            } else {
                // 表体自己画，不用系统 `Table`：系统那张表的底色、隔行底纹与列分隔线
                // 都不在 token 里，且它不透明地盖住卡面（§11.6 第六十八轮）。
                VStack(spacing: 0) {
                    workerColumnsHeader
                    Divider()
                    ForEach(Array(workerRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider()
                        }
                        workerRow(row)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("运行组件状态表")
            }
            Divider()
            CardFoot(note: sampleWindowNote) {
                Button {
                    Task { await model.refreshMonitoring() }
                } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                }
                .speechRailButton(.secondary)
                .disabled(model.isRefreshingMonitoring)
            }
        }
    }

    private var histogramSummarySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(
                title: "累计统计（服务启动以来）",
                detail: "服务进程启动以来的累计样本数与平均值，重启服务后归零；当下的快慢看页面顶部的数字。"
            )
            .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
            if histogramRows.isEmpty {
                Label("还没有累计统计", systemImage: "chart.bar")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SpeechRailDesignTokens.List.compactRowHeight,
                        alignment: .leading
                    )
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            } else {
                VStack(spacing: 0) {
                    histogramColumnsHeader
                    Divider()
                    ForEach(Array(histogramRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider()
                        }
                        histogramRow(row)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("直方图摘要表")
            }
        }
    }

    private struct WorkerStatusRow: Identifiable {
        let id: String
        let title: String
        let state: String
        let tone: StatusTone
    }

    private struct HistogramSummaryRow: Identifiable {
        let id: String
        let title: String
        let count: Int
        let average: String
    }

    private var workerRows: [WorkerStatusRow] {
        guard let workers = model.metrics?.workers, !workers.isEmpty else { return [] }
        return workers.keys.sorted().map { key in
            let state = workers[key] ?? "unknown"
            return WorkerStatusRow(
                id: key,
                title: workerTitle(for: key),
                state: workerStateText(for: state),
                tone: workerTone(for: state)
            )
        }
    }

    private var histogramRows: [HistogramSummaryRow] {
        guard let histograms = model.metrics?.histograms, !histograms.isEmpty else { return [] }
        return histograms.keys.sorted().flatMap { name -> [HistogramSummaryRow] in
            guard let series = histograms[name] else { return [] }
            // 名字与标签都翻成用户语言，单位跟着指标走——「累计平均」这一列如果不带单位，
            // 秒和倍率看上去就会是同一种东西（REDESIGN-SPEC §7.6）。
            let unit = RuntimeHistogramPresentation.unit(forMetric: name)
            let title = RuntimeHistogramPresentation.title(forMetric: name)
            return series.keys.sorted().map { labels in
                let summary = series[labels]
                let labelSummary = RuntimeHistogramPresentation.labelSummary(labels)
                return HistogramSummaryRow(
                    id: "\(name)/\(labels)",
                    title: labelSummary.isEmpty ? title : "\(title) · \(labelSummary)",
                    count: summary?.count ?? 0,
                    average: summary.map {
                        RuntimeHistogramPresentation.formattedAverage($0.average, unit: unit)
                    } ?? "—"
                )
            }
        }
    }

    /// Figma `workers` 的 `header`：`padX 18 / padY 9` 的一行 `Caption / Medium`，
    /// 两列宽度是 `COLS = [380]` 加一列吸收余量。左沿取 `Spacing.md`，与同一张卡的
    /// `CardHead` 对齐；行高由内容给，不钉死（§9）。
    private var workerColumnsHeader: some View {
        HStack(spacing: 0) {
            Text("组件")
                .frame(
                    width: SpeechRailDesignTokens.Layout.monitoringWorkerNameColumnWidth,
                    alignment: .leading
                )
            Text("状态")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(SpeechRailDesignTokens.Typography.captionMedium)
        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityHidden(true)
    }

    /// Figma `workers` 的 `row`：组件名 `Callout` / `text/primary`，
    /// 状态在第二列。状态仍带语义色与字形（§9「状态不只靠颜色表达」），比稿的
    /// 纯灰字多一层可读线索。
    ///
    /// 行高取 `List.compactRowHeight`(42)：与同一页的能力行、音色耗时行同一档，
    /// 也接住 2026-09-16 用户复核「高度高一些，不要需要滑动」那一条
    /// （稿的行是 `padY 11` + `Callout` 17.4 ≈ 39.4）。
    private func workerRow(_ row: WorkerStatusRow) -> some View {
        HStack(spacing: 0) {
            Text(row.title)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    width: SpeechRailDesignTokens.Layout.monitoringWorkerNameColumnWidth,
                    alignment: .leading
                )
            Label(row.state, systemImage: row.tone.systemImage)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(row.tone.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .frame(minHeight: SpeechRailDesignTokens.List.compactRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue(row.state)
    }

    /// 累计统计表的列头。列头写明「累计」：这一列是服务启动到现在的平均，不是当下。
    private var histogramColumnsHeader: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("指标")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("样本")
                .frame(
                    width: SpeechRailDesignTokens.Layout.monitoringSampleColumnWidth,
                    alignment: .trailing
                )
            Text("累计平均")
                .frame(
                    width: SpeechRailDesignTokens.Layout.monitoringMetricValueColumnWidth,
                    alignment: .trailing
                )
        }
        .font(SpeechRailDesignTokens.Typography.captionMedium)
        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityHidden(true)
    }

    /// 累计统计表的一行。两个数值列右对齐、等宽数字，位数变化时列不抖。
    private func histogramRow(_ row: HistogramSummaryRow) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(row.title)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(row.count))
                .font(SpeechRailDesignTokens.Typography.callout)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .frame(
                    width: SpeechRailDesignTokens.Layout.monitoringSampleColumnWidth,
                    alignment: .trailing
                )
            Text(row.average)
                .font(SpeechRailDesignTokens.Typography.callout)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .frame(
                    width: SpeechRailDesignTokens.Layout.monitoringMetricValueColumnWidth,
                    alignment: .trailing
                )
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .frame(minHeight: SpeechRailDesignTokens.List.compactRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue("\(row.count) 个样本，累计平均 \(row.average)")
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
        let overlapValue = switch overlapAllowed {
        case .some(true): "可以"
        case .some(false): "不行"
        case .none: "未提供"
        }
        let overlapDetail: String
        if resources == nil {
            overlapDetail = "读不到运行数据"
        } else if let rejections = window.queueRejectionIncrease {
            overlapDetail = rejections > 0
                ? "这段时间有 \(formatCount(rejections)) 次请求因排队被拒绝"
                : "这段时间没有请求被拒绝"
        } else {
            overlapDetail = "要有两个数据点才能给出区间"
        }

        return VStack(alignment: .leading, spacing: 0) {
            resourceRow(
                title: "机器内存",
                value: physicalMemory,
                detail: resources == nil ? "读不到运行数据" : "本机物理内存，服务预算按它计算",
                tone: resources?.physicalMemoryBytes == nil ? .neutral : .healthy
            )
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            Divider()
            resourceRow(
                title: "服务实际占用",
                value: physicalFootprint,
                detail: resources?.physicalFootprintComplete == true
                    ? "macOS 统计的物理内存占用"
                    : "服务未能完整统计全部进程，这一行不做推测",
                tone: resources?.physicalFootprintComplete == true ? .healthy : .neutral
            )
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            Divider()
            resourceRow(
                title: "服务可用上限",
                value: budget,
                detail: "准入策略使用的内存预算",
                tone: resources?.memoryBudgetBytes == nil ? .neutral : .attention
            )
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            Divider()
            resourceRow(
                title: "模型声明占用",
                value: declaredFootprint,
                detail: "配置里声明的常驻估算，不是实测占用",
                tone: resources?.declarationComplete == true ? .attention : .neutral
            )
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            Divider()
            resourceRow(
                title: "同时处理多个任务",
                value: overlapValue,
                detail: overlapDetail,
                tone: overlapAllowed.map { $0 ? StatusTone.healthy : .attention } ?? .neutral
            )
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
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
                // 与诊断检查行同一族（行首状态字形）：`.imageScale(.small)` 实测只有
                // 10.0 × 10.0，比稿小一档；同页的能力行用 `.medium`（13.0）本来就不一致。
                // 统一取 `Icon.rowStatusSize` = 13（REDESIGN-SPEC §11.6 第三十九轮）。
                .font(SpeechRailDesignTokens.Typography.rowStatusIcon)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    // 稿的运行组件表：行内容与表头之外一律 `Callout`（12pt Regular）。
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.technical)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(
                    minWidth: SpeechRailDesignTokens.List.numericValueMinimumWidth,
                    maxWidth: SpeechRailDesignTokens.List.numericValueMaximumWidth,
                    alignment: .trailing
                )
        }
        .padding(.vertical, SpeechRailDesignTokens.List.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)，\(detail)")
    }

    private var latestResources: RuntimeResourceSnapshot? {
        latestSample?.resources ?? model.metrics?.resources
    }

    private var chartPanel: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                chartHeading
                if !RuntimeMonitoringChartDescriptor.isSufficient(visibleChartPoints) {
                    ContentUnavailableView(
                        windowedSamples.isEmpty ? "还没有运行数据" : "数据点还不够",
                        systemImage: AppRoute.monitoring.systemImage,
                        description: Text(
                            windowedSamples.isEmpty
                                ? "打开这一页后会每 5 秒读一次本机服务；没有数据不代表服务异常。"
                                : "这段时间里只有一个数据点，画趋势至少要两个。"
                        )
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SpeechRailDesignTokens.Layout.monitoringEmptyMinimumHeight
                    )
                } else {
                    realtimeUsageChart
                    usageLegendNote("面积读左轴（个） · 折线读右轴（秒）")
                    if !latencySamples.contains(where: { $0.asrSeconds != nil || $0.ttsSeconds != nil }) {
                        latencyEmptyState
                    }
                }
                if let message = model.monitoringMessage, !message.isEmpty {
                    Text(message)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(monitoringTone.color)
                }
            }
            // 稿的卡片内边距是 18（`card()` 默认 `pad: 18`），应用统一取
            // `Layout.cardInset`(20) 这一档；这张卡此前是 16，比稿和应用自己的
            // 卡片档都紧 2–4pt（REDESIGN-SPEC §5.6 / §11.6 第二十八轮）。
            .padding(SpeechRailDesignTokens.Layout.cardInset)
        }
    }

    /// 时延样本：图上的折线、右轴的上限与「有没有耗时数据」的判断都读这一份。
    private var latencySamples: [RuntimeLatencySample] {
        windowedSamples.map {
            RuntimeLatencySample(
                capturedAt: $0.capturedAt,
                asrSeconds: $0.asrLatencySeconds,
                ttsSeconds: $0.ttsLatencySeconds
            )
        }
    }

    /// 没有任何耗时样本时，图上就没有那两条折线——这里用一行实话说明它什么时候出现。
    ///
    /// 这一行取代了此前「整张 240pt 空图」的位置：`Chart` 没有 mark 时不是空态、
    /// 是一片什么都没有的画布（第二十六轮）。合并成一张图之后，缺的只是那两条折线，
    /// 不值得再占一张图的高度。
    private var latencyEmptyState: some View {
        Label(
            "这段时间还没有语音耗时数据；合成或识别一次后，这里会出现每次的耗时曲线。",
            systemImage: "chart.xyaxis.line"
        )
        .font(SpeechRailDesignTokens.Typography.caption)
        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 使用趋势：一个坐标系，两套刻度

    /// 图卡的纵轴刻度：左边数**请求量**（面积，整数），右边数**耗时**（折线，秒）。
    ///
    /// 两个量单位不同，塞进同一根刻度会把彼此压扁——但画成上下两张图，又让人以为
    /// 「这是两张不同的图」（2026-09-16 用户复核：「为何搞俩坐标系？」→「合并到一个坐标系」）。
    /// 现在是一根横轴、一个绘图区、**纵轴两套刻度**：左轴的次数是整数，右轴的秒取
    /// 1 / 2 / 2.5 / 5 × 10ⁿ 的整档，两者用同一个线性比例对齐，所以右轴上读到的是整秒，
    /// 而不是左轴刻度的换算残数。图上再用**面积 vs 折线**区分这两件事、用颜色区分
    /// 「合成 / 识别」：面积回答「做了多少」，折线回答「快不快」。
    private struct UsageChartScale {
        /// 左轴上限（个 / 次）。
        let countPeak: Double
        /// 右轴刻度的步长（秒）；右轴上限固定为它的 4 倍。
        let secondsStep: Double

        init(countPeak: Double, secondsPeak: Double) {
            self.countPeak = max(1, countPeak.rounded(.up))
            self.secondsStep = Self.niceStep(max(secondsPeak, 0.1) / 4)
        }

        var secondsPeak: Double { secondsStep * 4 }
        /// 秒 → 左轴单位：右轴刻度与折线都用它换算。
        var secondsToCounts: Double { countPeak / secondsPeak }
        var countStep: Double { max(1, (countPeak / 4).rounded(.up)) }
        var countTicks: [Double] { Self.ticks(step: countStep, peak: countPeak) }
        var secondsTicks: [Double] { Self.ticks(step: secondsStep, peak: secondsPeak) }

        /// 1 / 2 / 2.5 / 5 × 10ⁿ 里第一个不小于 `raw` 的数——刻度因此总是「整」的。
        private static func niceStep(_ raw: Double) -> Double {
            let value = max(raw, 0.0001)
            let base = pow(10, floor(log10(value)))
            for multiplier in [1.0, 2.0, 2.5, 5.0] where base * multiplier >= value {
                return base * multiplier
            }
            return base * 10
        }

        private static func ticks(step: Double, peak: Double) -> [Double] {
            (0 ... Int((peak / step).rounded())).map { Double($0) * step }
        }
    }

    /// 左右两套刻度：左轴是次数（整数，画网格线），右轴是秒（只给刻度值，
    /// 不画第二条网格线——两套网格叠在一张图上就是噪声）。
    @AxisContentBuilder
    private func usageYAxis(_ scale: UsageChartScale) -> some AxisContent {
        AxisMarks(position: .leading, values: scale.countTicks) { value in
            AxisGridLine()
                .foregroundStyle(SpeechRailDesignTokens.Color.separator)
            AxisValueLabel {
                if let counts = value.as(Double.self) {
                    Text(formatCount(counts))
                        .font(SpeechRailDesignTokens.Typography.secondary)
                }
            }
        }
        AxisMarks(
            position: .trailing,
            values: scale.secondsTicks.map { $0 * scale.secondsToCounts }
        ) { value in
            AxisValueLabel {
                if let scaled = value.as(Double.self) {
                    Text(formatAxisSeconds(scaled / scale.secondsToCounts))
                        .font(SpeechRailDesignTokens.Typography.secondary)
                }
            }
        }
    }

    /// 右轴刻度的秒：整秒不带小数，半秒这类留一位。
    private func formatAxisSeconds(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.001
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
    }

    /// 图例：颜色（系统图例）说明「合成 / 识别」，这一行说明「面积 / 折线各读哪根轴」。
    private func usageLegendNote(_ text: String) -> some View {
        Text(text)
            .font(SpeechRailDesignTokens.Typography.secondary)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 面积的不透明度：填充要压得住，也要让网格线透出来，否则整块色块会盖掉刻度。
    private static let usageAreaOpacity: Double = 0.45

    /// 实时档的使用趋势：面积是每 5 秒采样到的同时在处理数（左轴），
    /// 折线是每次语音的耗时（右轴，值先换算到左轴域）。
    private var realtimeUsageChart: some View {
        let samples = windowedSamples
        let scale = UsageChartScale(
            countPeak: samples
                .map { Double($0.realtimeActiveRequests + $0.batchActiveRequests) }
                .max() ?? 0,
            secondsPeak: latencySamples
                .flatMap { [$0.asrSeconds, $0.ttsSeconds] }
                .compactMap { $0 }
                .max() ?? 0
        )
        let asrLatencyCount = latencySamples.reduce(0) { $0 + ($1.asrSeconds == nil ? 0 : 1) }
        let ttsLatencyCount = latencySamples.reduce(0) { $0 + ($1.ttsSeconds == nil ? 0 : 1) }
        return Chart {
            // Figma `lineChart` 的两条序列：会话式的实时请求与一次一句的请求。
            // 合计值仍在指标条与可访问性摘要里，图上看的是这两类各占多少。
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("时间", sample.capturedAt),
                    y: .value("同时处理", sample.realtimeActiveRequests)
                )
                .foregroundStyle(by: .value("类别", "实时语音会话"))
                .opacity(Self.usageAreaOpacity)
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("时间", sample.capturedAt),
                    y: .value("同时处理", sample.batchActiveRequests)
                )
                .foregroundStyle(by: .value("类别", "单次请求"))
                .opacity(Self.usageAreaOpacity)
                .interpolationMethod(.monotone)

                if let seconds = sample.asrLatencySeconds {
                    latencyLine(
                        at: sample.capturedAt,
                        seconds: seconds,
                        series: "语音识别耗时",
                        scale: scale
                    )
                    if asrLatencyCount < 2 {
                        latencyPoint(at: sample.capturedAt, seconds: seconds, series: "语音识别耗时", scale: scale)
                    }
                }
                if let seconds = sample.ttsLatencySeconds {
                    latencyLine(
                        at: sample.capturedAt,
                        seconds: seconds,
                        series: "语音合成耗时",
                        scale: scale
                    )
                    if ttsLatencyCount < 2 {
                        latencyPoint(at: sample.capturedAt, seconds: seconds, series: "语音合成耗时", scale: scale)
                    }
                }
            }
        }
        .chartForegroundStyleScale([
            "实时语音会话": SpeechRailDesignTokens.Color.rail,
            "单次请求": SpeechRailDesignTokens.Color.inkTertiary,
            "语音识别耗时": SpeechRailDesignTokens.Color.info,
            "语音合成耗时": SpeechRailDesignTokens.Color.voice,
        ])
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: SpeechRailDesignTokens.Layout.monitoringChartHeight)
        // 域从 0 起、至少到 1：全零时自动域会退化成 `0...0`，没有刻度、没有网格线，
        // 只剩一条漂在盒子里的线（2026-09-16 用户走查）。
        .chartYScale(domain: 0 ... scale.countPeak)
        .chartXAxis { monitoringAxisMarks() }
        .chartYAxis { usageYAxis(scale) }
        .accessibilityLabel("使用趋势")
        .accessibilityIdentifier("runtime-chart")
        .accessibilityChartDescriptor(
            RuntimeMonitoringChartDescriptor(points: visibleChartPoints, latency: latencySamples)
        )
    }

    /// 耗时折线：值是秒，画之前先换算到左轴域，读数由右轴给出。
    ///
    /// 单点画不出线段（`LineMark` 不给单点画符号，它的值却仍会把右轴撑起来），
    /// 所以样本不足两点的序列改画点——装机截图里「有图例、有刻度、没有线」就是这么来的。
    @ChartContentBuilder
    private func latencyLine(
        at date: Date,
        seconds: Double,
        series: String,
        scale: UsageChartScale
    ) -> some ChartContent {
        LineMark(
            x: .value("时间", date),
            y: .value("耗时", seconds * scale.secondsToCounts),
            series: .value("折线", series)
        )
        .foregroundStyle(by: .value("类别", series))
        .lineStyle(StrokeStyle(lineWidth: 2))
        .interpolationMethod(.monotone)
    }

    @ChartContentBuilder
    private func latencyPoint(
        at date: Date,
        seconds: Double,
        series: String,
        scale: UsageChartScale
    ) -> some ChartContent {
        PointMark(
            x: .value("时间", date),
            y: .value("耗时", seconds * scale.secondsToCounts)
        )
        .foregroundStyle(by: .value("类别", series))
    }

    /// Grid lines use the system separator colour and 12pt labels so the data
    /// reads louder than the chrome (REDESIGN-SPEC §7.6).
    private func monitoringAxisMarks() -> some AxisContent {
        AxisMarks { _ in
            AxisGridLine()
                .foregroundStyle(SpeechRailDesignTokens.Color.separator)
            AxisValueLabel()
                // 稿的折线图是用 SVG 画进来的，坐标轴标签 font-size 11；4x 帧实测
                // 10.5pt（y=455.75..465.75）。应用此前手挑 `.system(size: 12)`——既比稿大
                // 一档，也违反「只用系统文本样式、不手挑字号」（§3）。取 `secondary`(11)。
                .font(SpeechRailDesignTokens.Typography.secondary)
        }
    }

    private var windowedSamples: [RuntimeMetricsSample] {
        guard let interval = timeWindow.interval else { return model.monitoringSamples }
        let cutoff = Date().addingTimeInterval(-interval)
        return model.monitoringSamples.filter { $0.capturedAt >= cutoff }
    }

    /// 指标条与摘要都读这一份口径，图表读逐点值（REDESIGN-SPEC §7.6）。
    private var window: RuntimeMonitoringWindow {
        RuntimeMonitoringWindow(samples: windowedSamples)
    }

    // MARK: - 历史档（服务落盘的 60 秒/行）

    /// 历史档的首屏六个数字，答的是同一批问题，但口径变成「这段跨度里一共」：
    /// 做了多少、快不快、失败几次。`0 次`（真的没有）与 `—`（读不到）依然分开。
    private var historyMetricStrip: some View {
        let totals = history?.totals
        return MetricStrip(metrics: [
            MetricValue(
                id: "in-flight",
                title: "正在处理",
                value: latestSample.map { "\($0.activeRequests) 个" } ?? "—",
                detail: inFlightDetail
            ),
            MetricValue(
                id: "tts-usage",
                title: "语音合成",
                value: historyRequestCountText(totals?.ttsRequests),
                detail: historyUsageDetail(
                    requests: totals?.ttsRequests,
                    audioSeconds: totals?.ttsAudioSeconds,
                    action: "合成"
                )
            ),
            MetricValue(
                id: "asr-usage",
                title: "语音识别",
                value: historyRequestCountText(totals?.asrRequests),
                detail: historyUsageDetail(
                    requests: totals?.asrRequests,
                    audioSeconds: totals?.asrAudioSeconds,
                    action: "识别"
                )
            ),
            MetricValue(
                id: "tts-latency",
                title: "合成耗时",
                value: totals?.ttsSeconds.map(formatDuration) ?? "—",
                detail: historyLatencyDetail(
                    seconds: totals?.ttsSeconds,
                    p95Seconds: totals?.ttsP95Seconds,
                    requests: totals?.ttsRequests,
                    action: "合成"
                )
            ),
            MetricValue(
                id: "asr-latency",
                title: "识别耗时",
                value: totals?.asrSeconds.map(formatDuration) ?? "—",
                detail: historyLatencyDetail(
                    seconds: totals?.asrSeconds,
                    p95Seconds: totals?.asrP95Seconds,
                    requests: totals?.asrRequests,
                    action: "识别"
                )
            ),
            MetricValue(
                id: "failures",
                title: "失败请求",
                value: historyFailureText,
                detail: historyFailureDetail
            ),
        ])
    }

    private func historyRequestCountText(_ value: Double?) -> String {
        guard let value else { return history == nil ? "—" : "0 次" }
        return "\(formatCount(value)) 次"
    }

    private func historyUsageDetail(
        requests: Double?,
        audioSeconds: Double?,
        action: String
    ) -> String {
        guard history != nil else { return "还没有读到历史数据" }
        guard let requests, requests > 0 else { return "这段时间没有\(action)请求" }
        if let audioSeconds, audioSeconds > 0 {
            return "合计 \(formatAudioDuration(audioSeconds)) 音频"
        }
        return "合计 \(formatCount(requests)) 次\(action)"
    }

    private func historyLatencyDetail(
        seconds: Double?,
        p95Seconds: Double?,
        requests: Double?,
        action: String
    ) -> String {
        guard seconds != nil else { return "这段时间没有\(action)样本" }
        // p95 取跨度内各桶的最大值，说清楚它是「最慢那一段」而不是整体分位。
        if let p95Seconds {
            return "按样本量加权的平均 · 最慢一段 p95 \(formatSeconds(p95Seconds))"
        }
        if let requests, requests > 0 {
            return "\(formatCount(requests)) 次\(action)的加权平均"
        }
        return "按样本量加权的平均"
    }

    private var historyFailureText: String {
        guard let history else { return "—" }
        return "\(formatCount(history.totals.failedRequests)) 次"
    }

    private var historyFailureDetail: String {
        guard let history else { return "还没有读到历史数据" }
        let clientErrors = history.totals.clientErrors
        if history.totals.failedRequests > 0 {
            return "服务端错误（5xx）· 另有 \(formatCount(clientErrors)) 次 4xx"
        }
        if clientErrors > 0 {
            return "没有 5xx · 有 \(formatCount(clientErrors)) 次请求本身的问题（4xx）"
        }
        return "这段时间没有失败请求"
    }

    /// 与实时档同构的两张图（上「做了多少」、下「快不快」），数据换成服务落盘的区间增量。
    private var historyChartPanel: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                chartHeading
                if let history, !history.points.isEmpty {
                    historyUsageChart(points: history.points)
                    usageLegendNote("面积读左轴（次） · 折线读右轴（秒）")
                    if !history.points.contains(where: { $0.asrSeconds != nil || $0.ttsSeconds != nil }) {
                        latencyEmptyState
                    }
                    historyCoverageNote(history)
                } else if history == nil && model.isRefreshingMonitoringHistory {
                    ProgressView("正在读取历史指标…")
                        .frame(
                            maxWidth: .infinity,
                            minHeight: SpeechRailDesignTokens.Layout.monitoringEmptyMinimumHeight
                        )
                } else {
                    historyEmptyState
                }
                if let message = model.monitoringHistoryMessage, !message.isEmpty {
                    Text(message)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(SpeechRailDesignTokens.Layout.cardInset)
        }
    }

    /// 空态要说清两件事：这不是服务异常，以及数据会写到哪里。
    private var historyEmptyState: some View {
        ContentUnavailableView(
            "这段时间还没有历史数据",
            systemImage: "clock.arrow.circlepath",
            description: Text(
                "服务每次运行会把每 60 秒的用量写进 \(model.observability.historyDirectory.path)，默认保留 30 天；"
                    + "没有记录说明这段时间它还没写过。"
            )
        )
        .frame(
            maxWidth: .infinity,
            minHeight: SpeechRailDesignTokens.Layout.monitoringEmptyMinimumHeight
        )
    }

    /// 历史档的使用趋势：面积是每个统计桶的请求次数（左轴），折线是桶里的加权平均耗时（右轴）。
    ///
    /// 与实时档同构（面积「做了多少」、折线「快不快」），只是数据换成服务落盘的区间增量。
    private func historyUsageChart(points: [MetricsHistoryPoint]) -> some View {
        let scale = UsageChartScale(
            countPeak: points.map { $0.ttsRequests + $0.asrRequests }.max() ?? 0,
            secondsPeak: points.flatMap { [$0.asrSeconds, $0.ttsSeconds] }.compactMap { $0 }.max() ?? 0
        )
        let asrSampleCount = points.reduce(0) { $0 + ($1.asrSeconds == nil ? 0 : 1) }
        let ttsSampleCount = points.reduce(0) { $0 + ($1.ttsSeconds == nil ? 0 : 1) }
        return Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("时间", bucketCenter(point)),
                    y: .value("请求次数", point.ttsRequests)
                )
                .foregroundStyle(by: .value("类别", "语音合成"))
                .opacity(Self.usageAreaOpacity)
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("时间", bucketCenter(point)),
                    y: .value("请求次数", point.asrRequests)
                )
                .foregroundStyle(by: .value("类别", "语音识别"))
                .opacity(Self.usageAreaOpacity)
                .interpolationMethod(.monotone)

                if let seconds = point.asrSeconds {
                    latencyLine(
                        at: bucketCenter(point),
                        seconds: seconds,
                        series: "语音识别",
                        scale: scale
                    )
                    if asrSampleCount < 2 {
                        latencyPoint(
                            at: bucketCenter(point),
                            seconds: seconds,
                            series: "语音识别",
                            scale: scale
                        )
                    }
                }
                if let seconds = point.ttsSeconds {
                    latencyLine(
                        at: bucketCenter(point),
                        seconds: seconds,
                        series: "语音合成",
                        scale: scale
                    )
                    if ttsSampleCount < 2 {
                        latencyPoint(
                            at: bucketCenter(point),
                            seconds: seconds,
                            series: "语音合成",
                            scale: scale
                        )
                    }
                }
            }
        }
        .chartForegroundStyleScale([
            "语音合成": SpeechRailDesignTokens.Color.voice,
            "语音识别": SpeechRailDesignTokens.Color.info,
        ])
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: SpeechRailDesignTokens.Layout.monitoringChartHeight)
        .chartYScale(domain: 0 ... scale.countPeak)
        .chartXAxis { historyAxisMarks() }
        .chartYAxis { usageYAxis(scale) }
        .accessibilityLabel("使用趋势（历史）")
        .accessibilityIdentifier("runtime-history-chart")
        .accessibilityChartDescriptor(
            RuntimeMonitoringChartDescriptor(
                points: points.map {
                    RuntimeMonitoringChartPoint(
                        capturedAt: bucketCenter($0),
                        activeRequests: Int(($0.ttsRequests + $0.asrRequests).rounded()),
                        realtimeActiveRequests: Int($0.ttsRequests.rounded()),
                        batchActiveRequests: Int($0.asrRequests.rounded())
                    )
                },
                latency: points.map {
                    RuntimeLatencySample(
                        capturedAt: bucketCenter($0),
                        asrSeconds: $0.asrSeconds,
                        ttsSeconds: $0.ttsSeconds
                    )
                },
                seriesNames: ["语音合成", "语音识别"],
                latencyCaption: "折线是每个统计桶的加权平均耗时（秒），读右侧刻度。"
            )
        )
    }

    /// 统计桶的中点：面积与折线的落点都用它，两者的横坐标才对得齐。
    private func bucketCenter(_ point: MetricsHistoryPoint) -> Date {
        point.start.addingTimeInterval(point.end.timeIntervalSince(point.start) / 2)
    }

    /// 历史图的横轴按跨度换标签：一天以内给时刻，再长给日期。
    private func historyAxisMarks() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { value in
            AxisGridLine()
                .foregroundStyle(SpeechRailDesignTokens.Color.separator)
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(historyAxisLabel(date))
                        .font(SpeechRailDesignTokens.Typography.secondary)
                }
            }
        }
    }

    private func historyAxisLabel(_ date: Date) -> String {
        let seconds = timeWindow.historySeconds ?? 3_600
        if seconds <= 86_400 {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month(.defaultDigits).day())
    }

    /// 卡页脚：这份历史到底覆盖了多久、有没有洞，以及这段跨度的资源事实。
    private func historyCoverageNote(_ history: MetricsHistory) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(historyCoverageLine(history))
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(historyResourceLine(history))
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func historyCoverageLine(_ history: MetricsHistory) -> String {
        var parts = [
            "\(history.recordCount) 条区间 · 实际覆盖 \(formatSpan(history.coveredSeconds))",
            "每个点 \(formatSpan(history.bucketSeconds))",
        ]
        if history.restarts > 0 {
            parts.append("服务重启 \(history.restarts) 次")
        }
        if history.gaps > 0 {
            parts.append("中间空档 \(history.gaps) 处")
        }
        if history.skippedLines > 0 {
            parts.append("\(history.skippedLines) 行读不动")
        }
        return parts.joined(separator: " · ")
    }

    private func historyResourceLine(_ history: MetricsHistory) -> String {
        var parts: [String] = []
        if let peak = history.totals.memoryPeakBytes {
            parts.append("内存峰值 \(formatBytes(Int64(peak.rounded())))")
        }
        parts.append("并发峰值 \(Int(history.totals.activePeak.rounded())) 个")
        if history.totals.workerEvictions > 0 {
            parts.append("自动释放模型 \(Int(history.totals.workerEvictions.rounded())) 次")
        }
        if history.totals.queueRejections > 0 {
            parts.append("排队拒绝 \(Int(history.totals.queueRejections.rounded())) 次")
        }
        if let last = history.lastRecordedAt {
            parts.append("最后一条 \(relativeTime(last))")
        }
        return parts.joined(separator: " · ")
    }

    /// 时长说法：秒 / 分钟 / 小时 / 天。只在页脚出现，保持一位小数。
    private func formatSpan(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded())) 秒" }
        if seconds < 5_400 { return "\(Int((seconds / 60).rounded())) 分钟" }
        if seconds < 172_800 { return String(format: "%.1f 小时", seconds / 3_600) }
        return String(format: "%.1f 天", seconds / 86_400)
    }

    private var visibleChartPoints: [RuntimeMonitoringChartPoint] {
        windowedSamples.map {
            RuntimeMonitoringChartPoint(
                capturedAt: $0.capturedAt,
                activeRequests: $0.activeRequests
            )
        }
    }

    /// Figma `foot`：样本数与「上次读取多久前」是判断这些数字还新不新的唯一本机事实。
    /// 说法从「采样窗口 60」改成人话——「窗口」是 Grafana 的读法，不是用户读法。
    private var sampleWindowNote: String {
        if let history {
            guard let last = history.lastRecordedAt else { return "还没有历史记录" }
            return "已记录 \(history.recordCount) 条服务历史 · 最后写入 \(relativeTime(last))"
        }
        guard let latestSample else { return "还没有数据点" }
        let age = max(0, Int(Date().timeIntervalSince(latestSample.capturedAt).rounded()))
        let ageText = age < 60 ? "\(age) 秒前" : "\(age / 60) 分钟前"
        return "已记录 \(windowedSamples.count) 个数据点 · 上次读取 \(ageText)"
    }

    private var timeWindowPicker: some View {
        Picker("时间窗", selection: $timeWindow) {
            // 分两组而不是平铺七个分段：前一组是 App 自己每 5 秒的采样（只活在这次打开期间），
            // 后一组是服务落盘的历史（60 秒一行、跨重启保留）。两类数据的粒度与范围都不同，
            // 放进同一个 segmented control 会让人以为它们是同一份数据的两种裁剪。
            Section("本次打开 App · 每 5 秒采样") {
                ForEach(MonitoringTimeWindow.allCases.filter { !$0.isHistory }) { window in
                    Text(window.title).tag(window)
                }
            }
            Section("服务落盘 · 每 60 秒一行") {
                ForEach(MonitoringTimeWindow.allCases.filter(\.isHistory)) { window in
                    Text(window.shortTitle).tag(window)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("监控时间窗")
    }

    private var chartHeading: some View {
        SectionHeading(
            title: "使用趋势",
            // 图上是「一个坐标系、两套刻度」，哪根轴读什么由图上那行图例说（`usageLegendNote`）。
            // 这里只说数据源与粒度，不再重复讲图（2026-09-16 用户复核）。
            detail: isHistoryWindow
                ? "数据来自服务落盘的历史，服务重启后仍然连续；每个点是一个统计桶。"
                : "每 5 秒记录一次，只覆盖 App 打开期间。"
        )
    }

    /// 当前看的是不是服务落盘的历史（而不是 App 内存里的 5 秒采样）。
    private var isHistoryWindow: Bool { timeWindow.isHistory }

    /// 只认与当前跨度匹配的那份读数：切档后旧的跨度读数不能当成本档的结论。
    private var history: MetricsHistory? {
        guard let history = model.monitoringHistory,
              let seconds = timeWindow.historySeconds,
              history.windowSeconds == seconds
        else { return nil }
        return history
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
            LabeledContent("时间窗", value: timeWindow.title)
            // 落盘位置放在开发者详情里：这是排障时才会问的问题，但它必须能被查到
            // （2026-09-16 用户问过「存储到哪了」）。
            detailRow("历史指标目录", model.observability.historyDirectory.path)
            detailRow("日志目录", model.observability.logDirectory.path)
            if let history {
                LabeledContent("历史区间数", value: "\(history.recordCount)")
                LabeledContent("历史覆盖", value: formatSpan(history.coveredSeconds))
                LabeledContent("历史空档 / 重启", value: "\(history.gaps) / \(history.restarts)")
                LabeledContent("读不动的历史行", value: "\(history.skippedLines)")
                LabeledContent(
                    "历史服务版本",
                    value: history.serviceVersions.isEmpty
                        ? "未记录"
                        : history.serviceVersions.joined(separator: " → ")
                )
            }
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
                SectionHeading(title: "资源与准入")
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
                SectionHeading(title: "Worker")
                ForEach(model.metrics?.workers.keys.sorted() ?? [], id: \.self) { key in
                    detailRow(key, model.metrics?.workers[key] ?? "未知")
                }
            }
            if let health = displayedHealth {
                Divider()
                SectionHeading(title: "能力状态")
                detailRow("ASR", health.asrReady == true ? "ready" : "not ready")
                detailRow("TTS", health.ttsReady == true ? "ready" : "not ready")
                if let lifecycle = health.ttsLifecycle {
                    detailRow("TTS 常驻能力", ttsWarmCapabilitiesText(lifecycle))
                }
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

    private func ttsWarmCapabilitiesText(
        _ lifecycle: TTSCapabilityLifecycleSnapshot
    ) -> String {
        if let warmCapabilities = lifecycle.warmCapabilities {
            return warmCapabilities.isEmpty
                ? "无（按请求加载）"
                : warmCapabilities.joined(separator: "、")
        }
        return lifecycle.warmCapability ?? "未公开"
    }

    private func formatCount(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private func formatSeconds(_ value: Double) -> String {
        String(format: "%.3f s", value)
    }

    /// 时延说人话：小于 10 秒保留两位，更长就只留一位——这里既不需要毫秒级精度，
    /// 也不该把 `0.421 s` 这种工程写法摆在首屏。
    private func formatDuration(_ value: Double) -> String {
        value < 10 ? String(format: "%.2f 秒", value) : String(format: "%.1f 秒", value)
    }

    /// 音频时长：不足一分钟按秒，超过按「x 分 y 秒」。
    private func formatAudioDuration(_ value: Double) -> String {
        guard value >= 60 else {
            // 十秒以内保留两位，否则短音频会被四舍五入成「0.0 秒音频」，
            // 读起来像什么都没合成。
            let pattern = value < 10 ? "%.2f 秒音频" : "%.1f 秒音频"
            return String(format: pattern, value)
        }
        return "\(Int(value) / 60) 分 \(Int(value) % 60) 秒音频"
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

    private func relativeTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private var serviceIdentity: String {
        let profile = displayedHealth?.profile.map { SpeechRailProfilePresentation.title($0) }
            ?? "档位未读取"
        let version = displayedHealth?.version ?? "版本未读取"
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

    /// 复制摘要里的历史段。实时档下这段是「未选择历史跨度」，而不是空行——
    /// 读摘要的人需要知道「没有」是因为没选这一档，不是因为没有数据。
    private var historyReportLines: String {
        guard isHistoryWindow else { return "- 未选择历史跨度" }
        guard let history else { return "- 还在读取" }
        var lines = [
            "- window_seconds: \(Int(history.windowSeconds))",
            "- bucket_seconds: \(Int(history.bucketSeconds))",
            "- records: \(history.recordCount)",
            "- covered_seconds: \(String(format: "%.1f", history.coveredSeconds))",
            "- gaps: \(history.gaps)",
            "- restarts: \(history.restarts)",
            "- skipped_lines: \(history.skippedLines)",
            "- directory: \(history.directoryPath)",
            "- service_versions: \(history.serviceVersions.isEmpty ? "未记录" : history.serviceVersions.joined(separator: "→"))",
            "- tts_requests: \(formatCount(history.totals.ttsRequests))",
            "- asr_requests: \(formatCount(history.totals.asrRequests))",
            "- failed_requests: \(formatCount(history.totals.failedRequests))",
            "- tts_audio_seconds: \(String(format: "%.1f", history.totals.ttsAudioSeconds))",
            "- asr_audio_seconds: \(String(format: "%.1f", history.totals.asrAudioSeconds))",
            "- worker_evictions: \(Int(history.totals.workerEvictions.rounded()))",
            "- queue_rejections: \(Int(history.totals.queueRejections.rounded()))",
        ]
        if let peak = history.totals.memoryPeakBytes {
            lines.append("- memory_peak: \(formatBytes(Int64(peak.rounded())))")
        }
        return lines.joined(separator: "\n")
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
        profile: \(displayedHealth?.profile?.rawValue ?? "未读取")
        version: \(displayedHealth?.version ?? "未读取")
        health_ready: \(displayedHealth?.ready.map { $0 ? "true" : "false" } ?? "未读取")
        metrics_updated_at: \(model.lastMetricsRefresh.map { formatter.string(from: $0) } ?? "未读取")
        sample_count: \(model.monitoringSamples.count)/60
        freshness: \(freshnessTitle)
        window: \(timeWindow.title)
        summary: \(activitySummary)

        usage（用户口径：只含语音接口，不含本 App 的轮询）:
        - tts_requests: \(window.usageIncrease.ttsRequests.map(formatCount) ?? "未提供")
        - asr_requests: \(window.usageIncrease.asrRequests.map(formatCount) ?? "未提供")
        - tts_audio_seconds: \(window.usageIncrease.ttsAudioSeconds.map { String(format: "%.1f", $0) } ?? "未提供")
        - asr_audio_seconds: \(window.usageIncrease.asrAudioSeconds.map { String(format: "%.1f", $0) } ?? "未提供")
        - realtime_sessions: \(window.usageIncrease.realtimeSessions.map(formatCount) ?? "未提供")

        metrics:
        - active_requests: \(latestSample.map { String($0.activeRequests) } ?? "未提供")
        - pending_requests: \(latestSample.map { String($0.pendingRequests) } ?? "未提供")
        - request_rate: \(latestSample?.requestRatePerSecond.map(formatRate) ?? "未提供")
        - queue_rejections: \(latestSample?.queueRejections.map(formatCount) ?? "未提供")
        - asr_latency: \(latestSample?.asrLatencySeconds.map(formatSeconds) ?? "未提供")
        - tts_latency: \(latestSample?.ttsLatencySeconds.map(formatSeconds) ?? "未提供")
        - asr_rtf: \(latestSample?.asrRTF.map(formatRTF) ?? "未提供")
        - tts_rtf: \(latestSample?.ttsRTF.map(formatRTF) ?? "未提供")
        - tts_ttfa: \(latestSample?.ttsTTFASeconds.map(formatSeconds) ?? "未提供")
        - active_realtime_sessions: \(latestSample?.activeRealtimeSessions.map(String.init) ?? "未提供")

        workers:
        \(workerLines.isEmpty ? "- 未提供" : workerLines)

        resources:
        - physical_memory: \(resource?.physicalMemoryBytes.map(formatBytes) ?? "未提供")
        - memory_budget: \(resource?.memoryBudgetBytes.map(formatBytes) ?? "未提供")
        - declared_footprint: \(resource?.declaredFootprintBytes.map(formatBytes) ?? "未提供")
        - physical_footprint: \(resource?.physicalFootprintComplete == true ? resource?.physicalFootprintBytes.map(formatBytes) ?? "未提供" : "未提供（采样不完整）")
        - heavy_overlap: \(resource?.heavyOverlapAllowed.map { $0 ? "allowed" : "serialized" } ?? "未提供")
        - heavy_overlap_reason: \(resource?.heavyOverlapReason ?? "未提供")

        history（服务落盘的历史指标；只在这一档有值）:
        \(historyReportLines)
        """
        _ = NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(report, forType: .string) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
                reportMessage = "已复制脱敏监控摘要"
            }
        } else {
            reportMessage = "复制失败，请稍后重试"
        }
    }

    private func workerTitle(for key: String) -> String {
        switch key.lowercased() {
        case "asr":
            "语音识别"
        case "tts":
            "语音合成"
        // 服务端把实时 worker 报成 `streaming`。这个 key 此前不在映射表里，
        // 于是组件表上直接露出英文 `streaming`——用户看不懂的第一个来源就是它
        // （REDESIGN-SPEC §7.6，2026-09-16 实测 `/metrics` 的 `workers` 字段）。
        case "streaming", "realtime":
            "实时语音"
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
        if displayedHealth?.ready == false || displayedHealth == nil {
            return .attention
        }
        return .healthy
    }

    private var monitoringTitle: String {
        return switch monitoringTone {
        case .healthy:
            "服务正常"
        case .attention:
            model.metricsMessage == nil ? "还没有运行数据" : "运行数据已过期"
        case .critical:
            "无法读取服务状态"
        case .neutral:
            "还没有运行数据"
        }
    }

    private var monitoringMessage: String {
        if model.isRefreshingMonitoring {
            return "正在读取本机服务的运行状态。"
        }
        if let message = model.healthMessage {
            return "\(message) \(lastHealthRefreshText)。"
        }
        if let message = model.metricsMessage {
            return "\(SpeechRailOperationMessagePresentation.text(message))；下面的数字保留最近一次可信数据，\(lastMetricsRefreshText)。"
        }
        return switch monitoringTone {
        case .healthy:
            activitySummary
        case .attention:
            "服务可能正在启动，或当前能力还没有准备完成。"
        case .critical:
            model.monitoringMessage ?? "控制中心暂时无法连接到 SpeechRail。"
        case .neutral:
            "打开此页面后会自动读取本机运行状态。"
        }
    }

    /// 结论行的第二句必须说人话：这段时间它做了多少事、有没有出错。
    /// 「已读取 health 和 metrics」只是在复述这个页面自己做了什么。
    private var activitySummary: String {
        isHistoryWindow ? historyActivitySummary : liveActivitySummary
    }

    /// 历史档的结论句：只讲这段跨度里发生了什么。数据来自服务落盘的区间增量，
    /// 所以即使此刻服务是停的，这句话依然成立。
    private var historyActivitySummary: String {
        guard let history else {
            return "\(timeWindow.phrase)：还在读服务落盘的历史指标。"
        }
        guard !history.isEmpty else {
            return "\(timeWindow.phrase)：服务没有写过历史指标。"
        }
        let actions = [
            history.totals.ttsRequests > 0 ? "合成 \(formatCount(history.totals.ttsRequests)) 次" : nil,
            history.totals.asrRequests > 0 ? "识别 \(formatCount(history.totals.asrRequests)) 次" : nil,
        ]
        .compactMap { $0 }
        guard !actions.isEmpty else {
            return "\(timeWindow.phrase)：没有语音请求，服务空闲可用。"
        }
        let activity = actions.joined(separator: "、")
        if history.totals.failedRequests > 0 {
            return "\(timeWindow.phrase)：\(activity)；有 \(formatCount(history.totals.failedRequests)) 次失败。"
        }
        return "\(timeWindow.phrase)：\(activity)，没有失败请求。"
    }

    /// 实时档的结论句：数据来自 App 这次的采样，随 App 退出重置。
    private var liveActivitySummary: String {
        let usage = window.usageIncrease
        let actions = [
            (usage.ttsRequests ?? 0) > 0 ? "合成 \(formatCount(usage.ttsRequests ?? 0)) 次" : nil,
            (usage.asrRequests ?? 0) > 0 ? "识别 \(formatCount(usage.asrRequests ?? 0)) 次" : nil,
        ]
        .compactMap { $0 }
        guard !actions.isEmpty else {
            return "\(timeWindow.phrase)：没有语音请求，服务空闲可用。"
        }
        let activity = actions.joined(separator: "、")
        if let errors = window.errorIncrease, errors > 0 {
            return "\(timeWindow.phrase)：\(activity)；有 \(formatCount(errors)) 次返回错误。"
        }
        // 错误计数本身读不到时只报做过的事，不替它担保「都正常」。
        guard window.errorIncrease != nil else {
            return "\(timeWindow.phrase)：\(activity)。"
        }
        return "\(timeWindow.phrase)：\(activity)，都正常。"
    }
}

private struct MonitoringCapabilityRow: View {
    let title: String
    let detail: String
    let ready: Bool?

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: iconName)
                // 行首状态字形统一取 `Icon.rowStatusSize`（= 13，与上一条资源行一致；
                // 此前的 `.imageScale(.medium)` 实测同样是 13.0 墨迹，改的是写法不是大小）。
                .font(SpeechRailDesignTokens.Typography.rowStatusIcon)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
                .frame(width: SpeechRailDesignTokens.List.rowIconFrame, alignment: .leading)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    // 与监控表行同一档（稿的 kv / 表行都是 `Callout`）。
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            Text(statusText)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .frame(
                    width: SpeechRailDesignTokens.Layout.monitoringStatusColumnWidth,
                    alignment: .trailing
                )
        }
        .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.List.tallRowHeight)
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
