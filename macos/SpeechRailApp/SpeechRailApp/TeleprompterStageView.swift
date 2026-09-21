import SwiftUI

public struct TeleprompterStageView: View {
    @Bindable private var session: TeleprompterSession
    @Bindable private var settings: TeleprompterStageSettings
    private let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slices: [TeleprompterNormalizer.ReadingSlice] = []
    @State private var scrollPosition = ScrollPosition(idType: String.self)

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
        .onChange(of: session.activeVersion?.id, initial: true) { _, _ in
            slices = TeleprompterNormalizer.readingSlices(
                segments: session.activeVersion?.segments ?? [],
                tokensPerSlice: SpeechRailDesignTokens.Teleprompter.stageReadingTokensPerSlice
            )
            scrollToReadingPosition()
        }
        .onChange(of: readingSliceID) { _, _ in scrollToReadingPosition() }
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

            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

            // 等宽运行计时看板（已用、目标剩余/超时、正文预计剩余）
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                HStack(spacing: 3) {
                    Text("已用")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    Text(formatSeconds(session.runClock.elapsedSeconds))
                        .font(SpeechRailDesignTokens.Typography.technicalValue)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                }

                Text("·")
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                if session.runClock.isOverTarget {
                    HStack(spacing: 3) {
                        Text("超时")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                        Text(formatSeconds(session.runClock.overTargetSeconds))
                            .font(SpeechRailDesignTokens.Typography.technicalValue)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    }
                } else {
                    HStack(spacing: 3) {
                        Text("目标剩余")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        Text(formatSeconds(session.runClock.targetRemainingSeconds))
                            .font(SpeechRailDesignTokens.Typography.technicalValue)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                }

                Text("·")
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                HStack(spacing: 3) {
                    Text("预计剩余")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    Text(formatSeconds(session.runClock.estimatedRemainingSeconds))
                        .font(SpeechRailDesignTokens.Typography.technicalValue)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
            .padding(.vertical, 3)
            .background(
                SpeechRailDesignTokens.Color.recessedField,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.control, style: .continuous)
            )

            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                StatusPill(
                    tone: session.phase == .following ? .healthy : (session.phase == .uncertain ? .attention : .neutral),
                    label: stagePhaseBadge(session.phase)
                )
                VStack(alignment: .trailing, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text(session.progressText)
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                        .frame(width: 90)
                        .tint(SpeechRailDesignTokens.Color.rail)
                }
            }
            .accessibilityLabel("提词进度")
            .accessibilityValue("\(session.progressText)，完成约 \(Int(progressValue * 100))%")
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
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Teleprompter.stageSegmentSpacing) {
                    ForEach(slices) { slice in
                        Button {
                            session.moveToSegment(slice.segmentIndex)
                        } label: {
                            Text(styledText(slice))
                                .font(.system(size: settings.scriptPointSize))
                                .lineSpacing(settings.lineSpacing)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                        .background(
                            slice.id == readingSliceID
                                ? SpeechRailDesignTokens.Color.rail.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                        )
                        .accessibilityLabel(slice.text)
                        .accessibilityHint("选择这段作为起讲位置，再点击开始或继续跟读")
                        .accessibilityAddTraits(slice.id == readingSliceID ? .isSelected : [])
                        .opacity(readingSliceOpacity(for: slice))
                        .id(slice.id)
                    }
                    Color.clear.frame(height: geometry.size.height)
                        .accessibilityHidden(true)
                }
                .scrollTargetLayout()
            }
            .scrollPosition($scrollPosition)
        }
    }

    private var readingSliceID: String? {
        slices.first {
            $0.segmentIndex == session.currentSegmentIndex && session.readingOffset < $0.end
        }?.id ?? slices.last { $0.segmentIndex == session.currentSegmentIndex }?.id
    }

    private func scrollToReadingPosition() {
        guard let id = readingSliceID else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
            scrollPosition.scrollTo(id: id, anchor: .top)
        }
    }

    private func styledText(_ slice: TeleprompterNormalizer.ReadingSlice) -> AttributedString {
        var text = AttributedString(slice.text)
        text.foregroundColor = slice.segmentIndex < session.currentSegmentIndex
            ? SpeechRailDesignTokens.Color.inkTertiary : SpeechRailDesignTokens.Color.ink
        if slice.segmentIndex == session.currentSegmentIndex {
            let count = min(slice.text.utf16.count, max(0, session.readingOffset - slice.start))
            if let range = Range(NSRange(location: 0, length: count), in: slice.text),
               let attributedRange = Range(range, in: text) {
                text[attributedRange].foregroundColor = SpeechRailDesignTokens.Color.inkTertiary
            }
        }
        return text
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
                Text("正在听：\(partial)")
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
                if isFollowing {
                    session.pauseFollowing()
                } else {
                    Task { await session.resumeFollowing() }
                }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: isFollowing ? "pause.fill" : "play.fill")
                    Text(isFollowing ? "暂停跟读" : startLabel)
                    ButtonShortcutHint("Space")
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(isFollowing ? "暂停跟读，快捷键空格" : "\(startLabel)，快捷键空格")
            .disabled(session.isResuming || session.phase == .preparing)
            .speechRailButton(isFollowing ? .secondary : .primary)

            Button {
                session.moveToPrevious()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "chevron.left")
                    Text("上一段")
                    ButtonShortcutHint("←")
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityLabel("上一段，快捷键左方向键")
            .speechRailButton(.secondary)

            Button {
                session.moveToNext()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("下一段")
                    Image(systemName: "chevron.right")
                    ButtonShortcutHint("→")
                }
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .accessibilityLabel("下一段，快捷键右方向键")
            .speechRailButton(.secondary)

            Button {
                Task { await session.resetFollow() }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("从这里继续")
                    ButtonShortcutHint("R")
                }
            }
            .keyboardShortcut("r", modifiers: [])
            .accessibilityLabel("从当前位置重置跟读，快捷键 R")
            .disabled(session.isResuming || session.phase == .preparing)
            .speechRailButton(.secondary)

            Spacer(minLength: 0)

            Button {
                Task {
                    await session.endFollowing()
                    close()
                }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "xmark")
                    Text("结束")
                    ButtonShortcutHint("Esc")
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("结束提词并关闭舞台，快捷键 Esc")
            .speechRailButton(.destructive)
        }
        .controlSize(.regular)
    }

    private var isFollowing: Bool {
        session.phase == .following || session.phase == .uncertain
    }

    private var startLabel: String {
        switch session.phase {
        case .paused: "继续跟读"
        case .manual: "恢复跟读"
        default: "开始跟读"
        }
    }

    private var progressValue: Double {
        guard let count = session.activeVersion?.segments.count, count > 0 else { return 0 }
        return min(1, Double(session.currentSegmentIndex + 1) / Double(count))
    }

    private func readingSliceOpacity(for slice: TeleprompterNormalizer.ReadingSlice) -> Double {
        if slice.id == readingSliceID { return SpeechRailDesignTokens.Teleprompter.segmentOpacityCurrent }
        if slice.segmentIndex < session.currentSegmentIndex {
            return SpeechRailDesignTokens.Teleprompter.segmentOpacityPrevious
        }
        if slice.segmentIndex < session.currentSegmentIndex + settings.visibleSegmentCount {
            return SpeechRailDesignTokens.Teleprompter.segmentOpacityNext
        }
        return SpeechRailDesignTokens.Teleprompter.segmentOpacityPrevious
    }

    private var statusText: String {
        if let blocked = session.blocked { return blocked.title }
        if session.isResuming { return "正在准备继续…" }
        if session.uncertainty != nil { return "正在确认阅读位置，你可以继续读或手动选段" }
        switch session.phase {
        case .following: return session.hasHeardSpeech ? "正在跟读，请按你的节奏朗读" : "请读一句稿件，系统会跟随你的声音"
        case .paused: return "已暂停跟读，按空格恢复"
        case .manual: return "手动提词：可用 ← / → 校正位置"
        case .preparing: return "正在连接语音识别…"
        case .analyzing: return "正在整理稿件…"
        case .review: return "请先检查 AI 建议"
        case .ready, .draft: return "准备开始：按空格开始跟读"
        case .ended: return "提词已结束"
        case .uncertain: return "正在确认阅读位置，你可以继续读或手动选段"
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
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
