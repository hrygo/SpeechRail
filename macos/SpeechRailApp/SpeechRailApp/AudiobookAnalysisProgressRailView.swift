import SwiftUI

/// 有声书全书分析的确定性进度轨道：阶段 + n/N + 百分比 + 心跳。
///
/// 从 `AudiobookBookWorkspaceView` 抽出的纯展示视图：输入只有不可变的进度快照、
/// 时钟 tick、事件数与回调，不读 `AppModel`，不触仓库与管线，可离屏渲染做视觉回归。
/// 所有颜色、间距、字号均走 `SpeechRailDesignTokens`；面向用户的阶段文案为人话，
/// 技术量只出现在开发者折叠区内。
public struct AudiobookAnalysisProgressRailView: View {
    public var progress: AudiobookAnalysisProgress
    public var tick: Date
    public var eventCount: Int
    public var showDeveloperDetails: Bool
    public var isDeveloperSectionExpanded: Binding<Bool>
    public var onPause: () -> Void

    public init(
        progress: AudiobookAnalysisProgress,
        tick: Date,
        eventCount: Int,
        showDeveloperDetails: Bool,
        isDeveloperSectionExpanded: Binding<Bool>,
        onPause: @escaping () -> Void
    ) {
        self.progress = progress
        self.tick = tick
        self.eventCount = eventCount
        self.showDeveloperDetails = showDeveloperDetails
        self.isDeveloperSectionExpanded = isDeveloperSectionExpanded
        self.onPause = onPause
    }

    public var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(progress.phase.stepTitle)
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .lineLimit(1)
                    if let counter = progress.phase.stepCounter {
                        Text("· \(counter)")
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                    Text(Self.elapsedText(progress: progress, now: tick))
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .accessibilityLabel(Self.elapsedText(progress: progress, now: tick))
                }

                ProgressView(value: progress.fraction)
                    .controlSize(.small)
                    .tint(SpeechRailDesignTokens.Color.rail)
                    .accessibilityLabel(Self.accessibilityLabel(progress: progress))

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    if let counter = progress.windowCounterText {
                        Text(counter)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    if let chapterOrdinal = progress.currentChapterOrdinal {
                        Text("· 第 \(chapterOrdinal) 章")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    Text(String(format: "%.0f%%", progress.fraction * 100))
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Text("· \(Self.heartbeatText(progress: progress, now: tick))")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(Self.heartbeatColor(progress: progress, now: tick))
                }

                if progress.isRetryNoticeVisible {
                    retryLine
                }

                if progress.isStalled(at: tick) {
                    stallBanner
                }

                if showDeveloperDetails {
                    developerSection
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.sm)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel(progress: progress))
        .accessibilityIdentifier("audiobook-analysis-progress-rail")
    }

    private var retryLine: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                .accessibilityHidden(true)
            Text("这段较难，已拆小重试（第 \(progress.attempt) 次，最多 \(max(progress.attempt, progress.maxAttempts)) 次）")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var stallBanner: some View {
        StatusBanner(
            kind: .standard,
            tone: .attention,
            title: "这次等得比平时久",
            message: "已 \(progress.secondsSinceLastEvent(at: tick)) 秒没有新进展。已完成的检查点都已保存，可暂停稍后继续，或检查 AI 服务后重试。",
            actionTitle: "暂停分析"
        ) {
            onPause()
        }
    }

    private var developerSection: some View {
        DisclosureGroup("分析诊断（最近 \(eventCount) 个事件）", isExpanded: isDeveloperSectionExpanded) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                devRow("run", value: String(progress.runID.prefix(8)))
                devRow("窗口序号", value: progress.currentWindowOrdinal.map(String.init) ?? "—")
                devRow("本窗调用", value: "\(progress.attempt)/\(progress.maxAttempts)")
                devRow("复用检查点", value: "\(progress.reusedCheckpointWindows) 窗")
                devRow("LLM 调用", value: "\(progress.llmCallCount) 次")
                devRow("token", value: "\(progress.promptTokensTotal) 入 / \(progress.completionTokensTotal) 出")
                devRow(
                    "上次调用",
                    value: progress.lastCallMilliseconds.map { "\($0)ms" } ?? "—"
                )
                devRow("上次错误码", value: progress.lastErrorCode ?? "—")
                devRow("已用", value: "\(progress.elapsedSeconds(at: tick))s")
                devRow("上次进展", value: "\(progress.secondsSinceLastEvent(at: tick))s 前")
            }
            .padding(.top, SpeechRailDesignTokens.Spacing.micro)
        }
        .font(SpeechRailDesignTokens.Typography.caption)
        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
    }

    private func devRow(_ title: String, value: String) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(title)
                .frame(minWidth: SpeechRailDesignTokens.Layout.audiobookAnalysisDevRowLabelWidth, alignment: .leading)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 纯函数文案（视图与测试共用，阈值与 `AudiobookAnalysisProgressLimits` 一致）

    public static func elapsedText(progress: AudiobookAnalysisProgress, now: Date) -> String {
        let seconds = progress.elapsedSeconds(at: now)
        if seconds < 60 {
            return "已用 \(seconds) 秒"
        }
        return "已用 \(seconds / 60) 分 \(seconds % 60) 秒"
    }

    public static func heartbeatText(progress: AudiobookAnalysisProgress, now: Date) -> String {
        let idle = progress.secondsSinceLastEvent(at: now)
        if idle <= 3 {
            return "进展正常"
        }
        if idle >= Int(AudiobookAnalysisProgressLimits.stallWarningSeconds) {
            return "上次进展 \(idle) 秒前"
        }
        if idle >= Int(AudiobookAnalysisProgressLimits.awaitingCallNoticeSeconds) {
            return "仍在等待 AI 返回…\(idle)s"
        }
        return "等待 AI 返回…\(idle)s"
    }

    public static func heartbeatColor(progress: AudiobookAnalysisProgress, now: Date) -> Color {
        if progress.isStalled(at: now) {
            return SpeechRailDesignTokens.Color.attention
        }
        return SpeechRailDesignTokens.Color.inkSecondary
    }

    public static func accessibilityLabel(progress: AudiobookAnalysisProgress) -> String {
        var parts = ["\(progress.phase.stepTitle)，\(Int(progress.fraction * 100))%"]
        if let counter = progress.windowCounterText {
            parts.append(counter)
        }
        if progress.isRetryNoticeVisible {
            parts.append("正在重试第 \(progress.attempt) 次")
        }
        return parts.joined(separator: "，")
    }

    /// 顶栏胶囊的活文案：阶段人话 + n/N（用户语言，技术量进轨道与开发者详情）。
    public static func pillLabel(for progress: AudiobookAnalysisProgress) -> String {
        var parts: [String] = [progress.phase.stepTitle.replacingOccurrences(of: "正在", with: "")]
        if let counter = progress.windowCounterText {
            parts.append(counter)
        }
        return parts.joined(separator: " · ")
    }
}
