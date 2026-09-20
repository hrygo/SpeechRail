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
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
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
                        .frame(width: 132)
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
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: isFollowing ? "pause.fill" : "play.fill")
                    Text(isFollowing ? "暂停跟读" : startLabel)
                    SessionKeycap("Space")
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(session.isResuming || session.phase == .preparing)
            .speechRailButton(isFollowing ? .secondary : .primary)

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
            .speechRailButton(.secondary)

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
            .speechRailButton(.secondary)

            Button {
                Task { await session.resetFollow() }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("从这里继续")
                    SessionKeycap("R")
                }
            }
            .keyboardShortcut("r", modifiers: [])
            .disabled(session.isResuming || session.phase == .preparing)
            .speechRailButton(.secondary)

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
        if session.uncertainty != nil { return "位置已保留，读回稿件后会继续跟随" }
        switch session.phase {
        case .following: return session.hasHeardSpeech ? "自动跟读中" : "请读一句稿件，系统会跟随你的声音"
        case .paused: return "已暂停跟读"
        case .manual: return "手动提词：可用 ← / → 校正位置"
        case .preparing: return "正在连接语音识别…"
        case .analyzing: return "正在整理稿件…"
        case .review: return "请先检查 AI 建议"
        case .ready, .draft: return "准备开始：按空格开始跟读"
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
