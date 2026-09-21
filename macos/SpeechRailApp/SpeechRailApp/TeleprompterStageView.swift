import SwiftUI

public struct TeleprompterStageView: View {
    @Bindable private var session: TeleprompterSession
    @Bindable private var settings: TeleprompterStageSettings
    private let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            readingProgress
            if session.blocked != nil || session.uncertainty != nil {
                attentionMessage
            }
            scriptStack
            controls
        }
        .padding(SpeechRailDesignTokens.Teleprompter.stagePadding)
        .frame(
            minWidth: SpeechRailDesignTokens.Teleprompter.stageMinimumWidth,
            minHeight: SpeechRailDesignTokens.Teleprompter.stageMinimumHeight,
            alignment: .top
        )
        // Only the reading surface is translucent. Applying opacity to the
        // whole root made text and controls fade together while the panel
        // surface still looked opaque.
        .background {
            RoundedRectangle(
                cornerRadius: SpeechRailDesignTokens.Corner.container,
                style: .continuous
            )
            .fill(.ultraThinMaterial)
            .opacity(settings.opacity)
        }
        .clipShape(SpeechRailDesignTokens.Corner.containerShape)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration),
            value: session.currentSegmentIndex
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI 提词器舞台")
        .accessibilityValue("\(session.progressText)，\(statusText)")
        .onChange(of: session.activeVersion?.id, initial: true) { _, _ in
            scrollToReadingPosition()
        }
        .onChange(of: session.currentSegmentIndex) { _, _ in scrollToReadingPosition() }
    }

    private var readingProgress: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(SpeechRailDesignTokens.Color.rail)
                .frame(maxWidth: .infinity)

            Text(session.progressText)
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("提词进度")
        .accessibilityValue("\(session.progressText)，完成约 \(Int(progressValue * 100))%")
    }

    private var attentionMessage: some View {
        Label(statusText, systemImage: "exclamationmark.triangle")
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            .background(
                SpeechRailDesignTokens.Color.attention.opacity(
                    SpeechRailDesignTokens.Teleprompter.stageAttentionBackgroundOpacity
                ),
                in: RoundedRectangle(
                    cornerRadius: SpeechRailDesignTokens.Corner.nested,
                    style: .continuous
                )
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("需要注意")
            .accessibilityValue(statusText)
    }

    private var scriptStack: some View {
        GeometryReader { geometry in
            let contentWidth = min(
                geometry.size.width,
                SpeechRailDesignTokens.Teleprompter.stageContentMaximumWidth
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Teleprompter.stageSegmentSpacing) {
                    ForEach(visibleSegmentIndices, id: \.self) { index in
                        segmentRow(at: index)
                            .id(segmentID(at: index))
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
            }
            .scrollPosition($scrollPosition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("朗读内容")
    }

    private var visibleSegmentIndices: [Int] {
        guard let count = session.activeVersion?.segments.count else { return [] }
        return TeleprompterStagePresentation.visibleSegmentIndices(
            currentIndex: session.currentSegmentIndex,
            visibleCount: settings.visibleSegmentCount,
            totalCount: count
        )
    }

    private func scrollToReadingPosition() {
        guard let id = currentSegmentID else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
            scrollPosition.scrollTo(id: id, anchor: .top)
        }
    }

    private var currentSegmentID: String? {
        guard let segments = session.activeVersion?.segments,
              segments.indices.contains(session.currentSegmentIndex) else { return nil }
        let segment = segments[session.currentSegmentIndex]
        return segment.id
    }

    private func segmentID(at index: Int) -> String {
        guard let segments = session.activeVersion?.segments, segments.indices.contains(index) else {
            return "segment-\(index)"
        }
        return segments[index].id
    }

    @ViewBuilder
    private func segmentRow(at index: Int) -> some View {
        if let segments = session.activeVersion?.segments, segments.indices.contains(index) {
            let segment = segments[index]
            let isCurrent = index == session.currentSegmentIndex
            Button {
                session.moveToSegment(index)
            } label: {
                Text(styledText(segment, isCurrent: isCurrent))
                    .font(.system(
                        size: settings.scriptPointSize,
                        weight: isCurrent ? .semibold : .regular
                    ))
                    .lineSpacing(settings.lineSpacing)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                    .background(
                        isCurrent
                            ? SpeechRailDesignTokens.Color.rail.opacity(
                                SpeechRailDesignTokens.Teleprompter.stageCurrentBackgroundOpacity
                            )
                            : Color.clear,
                        in: RoundedRectangle(
                            cornerRadius: SpeechRailDesignTokens.Corner.nested,
                            style: .continuous
                        )
                    )
                    .overlay(alignment: .leading) {
                        if isCurrent {
                            Capsule(style: .continuous)
                                .fill(SpeechRailDesignTokens.Color.rail)
                                .frame(width: SpeechRailDesignTokens.Teleprompter.stageCurrentRailWidth)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                        }
                    }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isCurrent ? 1 : SpeechRailDesignTokens.Teleprompter.stageNextSegmentOpacity)
            .accessibilityLabel(segment.text)
            .accessibilityHint("选择这段作为起讲位置，再点击开始或继续跟读")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
        }
    }

    private func styledText(_ segment: TeleprompterSegment, isCurrent: Bool) -> AttributedString {
        var text = AttributedString(segment.text)
        text.foregroundColor = isCurrent
            ? SpeechRailDesignTokens.Color.ink
            : SpeechRailDesignTokens.Color.inkSecondary
        if isCurrent {
            let count = min(segment.text.utf16.count, max(0, session.readingOffset))
            if let range = Range(NSRange(location: 0, length: count), in: segment.text),
               let attributedRange = Range(range, in: text) {
                text[attributedRange].foregroundColor = SpeechRailDesignTokens.Color.inkTertiary
            }
        }
        return text
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
                SpeechRailButtonLabel(
                    isFollowing ? "暂停" : startLabel,
                    icon: isFollowing ? .pause : .play
                )
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(isFollowing ? "暂停跟读，快捷键空格" : "\(startLabel)，快捷键空格")
            .disabled(session.isResuming || session.phase == .preparing)
            .speechRailButton(isFollowing ? .secondary : .primary)

            PageActionsMenu(title: "更多", icon: .more, helpText: "上一段、下一段和从这里继续") {
                Button("上一段", systemImage: "chevron.left") {
                    session.moveToPrevious()
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button("下一段", systemImage: "chevron.right") {
                    session.moveToNext()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Divider()

                Button("从这里继续", systemImage: "arrow.counterclockwise") {
                    Task { await session.resetFollow() }
                }
                .keyboardShortcut("r", modifiers: [])
                .disabled(session.isResuming || session.phase == .preparing)
            }

            Spacer(minLength: 0)

            Button {
                Task {
                    await session.endFollowing()
                    close()
                }
            } label: {
                SpeechRailButtonLabel("结束", icon: .close)
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

}
