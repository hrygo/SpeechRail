import SwiftUI

public struct TeleprompterStageView: View {
    @Bindable private var session: TeleprompterSession
    @Bindable private var settings: TeleprompterStageSettings
    private let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        session: TeleprompterSession,
        settings: TeleprompterStageSettings,
        close: @escaping () -> Void
    ) {
        self.session = session
        self.settings = settings
        self.close = close
    }

    public var body: some View {
        VStack(spacing: SpeechRailDesignTokens.Teleprompter.stageSegmentSpacing) {
            header
            scriptStack
            statusBar
            controls
        }
        .padding(SpeechRailDesignTokens.Teleprompter.stagePadding)
        .frame(
            minWidth: SpeechRailDesignTokens.Teleprompter.stageMinimumWidth,
            minHeight: SpeechRailDesignTokens.Teleprompter.stageMinimumHeight,
            alignment: .top
        )
        .background(.ultraThinMaterial)
        .speechRailSurface(.panel)
        .clipShape(SpeechRailDesignTokens.Corner.containerShape)
        .opacity(settings.opacity)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration),
            value: session.currentSegmentIndex
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI 提词器舞台")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: AppRoute.teleprompter.systemImage)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                Text("AI 提词器")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                StatusPill(
                    tone: session.phase == .following ? .healthy : (session.phase == .uncertain ? .attention : .neutral),
                    label: stagePhaseBadge(session.phase)
                )
                Text(session.progressText)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .accessibilityLabel("提词进度")
            .accessibilityValue(session.progressText)
        }
    }

    private func stagePhaseBadge(_ phase: TeleprompterSession.Phase) -> String {
        switch phase {
        case .following: "跟读中"
        case .paused: "已暂停"
        case .uncertain: "待确认"
        case .manual: "手动"
        default: "提词"
        }
    }

    private var scriptStack: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Teleprompter.stageSegmentSpacing) {
            if let previous = previousSegment {
                segmentText(previous.text, emphasis: .previous)
            }
            if let current = session.currentSegment {
                segmentText(current.text, emphasis: .primary)
                    .accessibilityAddTraits(.isSelected)
                    .accessibilityLabel("当前段落")
                    .accessibilityValue(current.text)
            } else {
                Text("请先在准备页确认一版稿件。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            if settings.visibleSegmentCount >= 3, let next = nextSegment {
                segmentText(next.text, emphasis: .next)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private enum SegmentEmphasis {
        case previous
        case primary
        case next
    }

    private func segmentText(_ text: String, emphasis: SegmentEmphasis) -> some View {
        let opacity: Double = switch emphasis {
        case .primary: SpeechRailDesignTokens.Teleprompter.segmentOpacityCurrent
        case .next: SpeechRailDesignTokens.Teleprompter.segmentOpacityNext
        case .previous: SpeechRailDesignTokens.Teleprompter.segmentOpacityPrevious
        }

        return Text(text)
            .font(.system(size: settings.scriptPointSize, weight: emphasis == .primary ? .semibold : .regular))
            .lineSpacing(settings.lineSpacing)
            .foregroundStyle(
                emphasis == .primary
                    ? SpeechRailDesignTokens.Color.ink
                    : SpeechRailDesignTokens.Color.inkSecondary
            )
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(opacity)
    }

    private var statusBar: some View {
        HStack(spacing: SpeechRailDesignTokens.Teleprompter.stageStatusSpacing) {
            Circle()
                .fill(statusColor)
                .frame(
                    width: SpeechRailDesignTokens.Teleprompter.stageStatusIndicatorSize,
                    height: SpeechRailDesignTokens.Teleprompter.stageStatusIndicatorSize
                )
                .accessibilityHidden(true)
            Text(statusText)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(2)
            if let partial = session.partialText, !partial.isEmpty {
                Text(partial)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("跟读状态")
        .accessibilityValue(statusText)
    }

    private var controls: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button {
                if session.phase == .paused {
                    session.resumeFollowing()
                } else {
                    session.pauseFollowing()
                }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: session.phase == .paused ? "play.fill" : "pause.fill")
                    Text(session.phase == .paused ? "继续" : "暂停")
                    SessionKeycap("Space")
                }
            }
            .keyboardShortcut(.space, modifiers: [])

            Button {
                session.moveToPrevious()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "chevron.left")
                    Text("上一段")
                    SessionKeycap("←")
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button {
                session.moveToNext()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text("下一段")
                    Image(systemName: "chevron.right")
                    SessionKeycap("→")
                }
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button {
                session.resetFollow()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("回正")
                    SessionKeycap("R")
                }
            }
            .keyboardShortcut("r", modifiers: [])

            Spacer(minLength: 0)

            Button {
                Task {
                    await session.endFollowing()
                    close()
                }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "xmark")
                    Text("结束")
                    SessionKeycap("Esc")
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .tint(SpeechRailDesignTokens.Color.critical)
        }
        .controlSize(.regular)
        .buttonStyle(.bordered)
    }

    private var previousSegment: TeleprompterSegment? {
        guard let segments = session.activeVersion?.segments else { return nil }
        let index = session.currentSegmentIndex - 1
        return segments.indices.contains(index) ? segments[index] : nil
    }

    private var nextSegment: TeleprompterSegment? {
        guard let segments = session.activeVersion?.segments else { return nil }
        let index = session.currentSegmentIndex + 1
        return segments.indices.contains(index) ? segments[index] : nil
    }

    private var statusText: String {
        if let blocked = session.blocked { return blocked.title }
        if session.uncertainty != nil { return "请确认当前位置，可用方向键接管" }
        switch session.phase {
        case .following: return "自动跟读中"
        case .paused: return "已暂停自动跟读"
        case .manual: return "手动提词"
        case .preparing: return "正在连接语音服务…"
        case .analyzing: return "正在整理稿件…"
        case .review: return "等待确认 AI 建议"
        case .ready, .draft: return "准备开始"
        case .ended: return "提词已结束"
        case .uncertain: return "请确认当前位置"
        }
    }

    private var statusColor: Color {
        if session.blocked != nil || session.uncertainty != nil {
            return SpeechRailDesignTokens.Color.attention
        }
        if session.phase == .following {
            return SpeechRailDesignTokens.Color.ready
        }
        return SpeechRailDesignTokens.Color.inkTertiary
    }
}
