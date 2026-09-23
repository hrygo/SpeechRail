import SwiftUI

public struct TeleprompterStageView: View {
    @Bindable private var session: TeleprompterSession
    @Bindable private var settings: TeleprompterStageSettings
    private let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var isBrowsingAll: Bool = false
    @State private var hasAdoptedCalibration: Bool = false
    @State private var hoveredSegmentIndex: Int? = nil

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
        stageContent
            .padding(SpeechRailDesignTokens.Teleprompter.stagePadding)
            .frame(
                minWidth: SpeechRailDesignTokens.Teleprompter.stageMinimumWidth,
                minHeight: SpeechRailDesignTokens.Teleprompter.stageMinimumHeight,
                alignment: .top
            )
            .background { stageBackground }
            .overlay { stageBorder }
            .clipShape(SpeechRailDesignTokens.Corner.containerShape)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration),
                value: session.currentSegmentIndex
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration),
                value: session.phase
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration),
                value: isBrowsingAll
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration),
                value: hoveredSegmentIndex
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("AI 提词器舞台")
            .accessibilityValue("\(session.progressText)，\(statusText)")
            .onChange(of: session.activeVersion?.id, initial: true) { _, _ in
                scrollToReadingPosition()
            }
            .onChange(of: session.currentSegmentIndex) { _, _ in scrollToReadingPosition() }
            .onChange(of: session.phase) { _, newPhase in
                handlePhaseChange(to: newPhase)
            }
    }

    @ViewBuilder
    private var stageContent: some View {
        VStack(spacing: SpeechRailDesignTokens.Teleprompter.stageSegmentSpacing) {
            if session.phase == .ended {
                stageSummaryView
            } else {
                readingProgress
                if let blocked = session.blocked {
                    attentionMessage(blocked: blocked)
                } else if session.uncertainty != nil {
                    adlibbingMessage
                }
                scriptStack
                controls
            }
        }
    }

    private var stageBackground: some View {
        RoundedRectangle(
            cornerRadius: SpeechRailDesignTokens.Corner.container,
            style: .continuous
        )
        .fill(
            SpeechRailDesignTokens.Color.canvas.opacity(settings.opacity * 0.72)
        )
        .background(
            .ultraThinMaterial.opacity(settings.opacity),
            in: RoundedRectangle(
                cornerRadius: SpeechRailDesignTokens.Corner.container,
                style: .continuous
            )
        )
    }

    private var stageBorder: some View {
        RoundedRectangle(
            cornerRadius: SpeechRailDesignTokens.Corner.container,
            style: .continuous
        )
        .strokeBorder(
            SpeechRailDesignTokens.Surface.border,
            lineWidth: SpeechRailDesignTokens.Stroke.hairline
        )
    }

    private func handlePhaseChange(to newPhase: TeleprompterSession.Phase) {
        if newPhase == .following {
            isBrowsingAll = false
        }
        if newPhase == .ready {
            hasAdoptedCalibration = false
        }
    }

    // MARK: - 舞台节奏与状态看板

    private var readingProgress: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            // 1. 跟读动态与拾音状态胶囊
            statusCapsule

            // 2. 细窄进度条与段落编号
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                    .tint(SpeechRailDesignTokens.Color.rail)
                    .frame(minWidth: 46)

                Text(session.progressText)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize()
            }

            // 3. 语速节奏指示胶囊（跟读进行中呈现）
            if isFollowing && session.hasHeardSpeech {
                paceIndicatorCapsule
            }

            Spacer(minLength: 0)

            // 4. 全稿查阅 / 聚焦两段切换（候场、暂停、手动时可用）
            if !isFollowing {
                contextBrowsingToggle
            }

            // 5. 轻量计时看板
            clockDashboard
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("提词进度与计时")
        .accessibilityValue("\(session.progressText)，\(statusText)，已读 \(formatClock(session.runClock.elapsedSeconds))")
    }

    @ViewBuilder
    private var statusCapsule: some View {
        switch session.phase {
        case .ready, .draft:
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "mic.badge.checkmark")
                    .font(.system(size: 9))
                Text("候场就绪 · 空格开讲")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
            .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
            .background(SpeechRailDesignTokens.Color.rail.opacity(0.14), in: Capsule())

        case .following:
            if session.uncertainty != nil {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 9))
                    Text("自由发挥中")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                }
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
                .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
                .background(SpeechRailDesignTokens.Color.rail.opacity(0.14), in: Capsule())
            } else if session.hasHeardSpeech {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Circle()
                        .fill(SpeechRailDesignTokens.Color.ready)
                        .frame(
                            width: SpeechRailDesignTokens.Teleprompter.stageStatusIndicatorSize,
                            height: SpeechRailDesignTokens.Teleprompter.stageStatusIndicatorSize
                        )
                    Text("跟读咬合")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ready)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
                .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
                .background(SpeechRailDesignTokens.Color.ready.opacity(0.14), in: Capsule())
            } else {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9))
                    Text("等待声音请开讲…")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                }
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
                .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
                .background(SpeechRailDesignTokens.Color.attention.opacity(0.14), in: Capsule())
            }

        case .paused:
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8))
                Text("已暂停跟读")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
            .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
            .background(SpeechRailDesignTokens.Color.attention.opacity(0.14), in: Capsule())

        case .manual:
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 8))
                Text("手动选段模式")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
            .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
            .background(SpeechRailDesignTokens.Color.inputField, in: Capsule())

        case .preparing:
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                ProgressView()
                    .controlSize(.mini)
                Text("连接中…")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
            .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
            .background(SpeechRailDesignTokens.Color.inputField, in: Capsule())

        default:
            EmptyView()
        }
    }

    private var currentPaceStatus: TeleprompterStagePaceStatus {
        let total = session.activeVersion?.segments.count ?? 0
        return TeleprompterStagePresentation.paceStatus(
            currentIndex: session.currentSegmentIndex,
            totalCount: total,
            elapsedSeconds: session.runClock.elapsedSeconds,
            targetSeconds: session.runClock.targetSeconds
        )
    }

    @ViewBuilder
    private var paceIndicatorCapsule: some View {
        let status = currentPaceStatus
        switch status {
        case .establishing:
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "waveform")
                    .font(.system(size: 8))
                Text(status.title)
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingHorizontal)
            .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingVertical)
            .background(SpeechRailDesignTokens.Color.inputField, in: Capsule())
            .help(status.advice)

        case .steady:
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 8))
                Text(status.title)
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.ready)
            .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingHorizontal)
            .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingVertical)
            .background(SpeechRailDesignTokens.Color.ready.opacity(0.12), in: Capsule())
            .help(status.advice)

        case .brisk:
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "hare.fill")
                    .font(.system(size: 8))
                Text(status.title)
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingHorizontal)
            .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingVertical)
            .background(SpeechRailDesignTokens.Color.rail.opacity(0.12), in: Capsule())
            .help(status.advice)

        case .slow:
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "tortoise.fill")
                    .font(.system(size: 8))
                Text(status.title)
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingHorizontal)
            .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingVertical)
            .background(SpeechRailDesignTokens.Color.attention.opacity(0.14), in: Capsule())
            .help(status.advice)
        }
    }

    private var contextBrowsingToggle: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
                isBrowsingAll.toggle()
                if isBrowsingAll {
                    scrollToReadingPosition()
                }
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: isBrowsingAll ? "rectangle.split.2x1" : "text.justify.left")
                    .font(.system(size: 9))
                Text(isBrowsingAll ? "聚焦两段" : "查阅全稿")
                    .font(SpeechRailDesignTokens.Typography.caption)
                kbdBadge("⌘A")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.tiny)
        .background(
            isBrowsingAll
                ? SpeechRailDesignTokens.Color.rail.opacity(0.14)
                : SpeechRailDesignTokens.Color.inputField.opacity(0.7),
            in: SpeechRailDesignTokens.Corner.nestedShape
        )
        .foregroundStyle(
            isBrowsingAll
                ? SpeechRailDesignTokens.Color.rail
                : SpeechRailDesignTokens.Color.inkSecondary
        )
        .help(isBrowsingAll ? "切换为跟读聚焦两段模式（快捷键 ⌘A）" : "展开查阅完整讲稿并可选段起讲（快捷键 ⌘A）")
    }

    private var clockDashboard: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            Image(systemName: "stopwatch")
                .font(SpeechRailDesignTokens.Typography.captionRegular)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

            Text(formatClock(session.runClock.elapsedSeconds))
                .font(SpeechRailDesignTokens.Typography.technicalValue)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)

            if session.targetMinutes > 0 {
                Text("/")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                let isOvertime = session.runClock.elapsedSeconds > session.runClock.targetSeconds
                Text(
                    isOvertime
                        ? "超时 \(formatClock(session.runClock.elapsedSeconds - session.runClock.targetSeconds))"
                        : "剩 \(formatClock(session.runClock.estimatedRemainingSeconds))"
                )
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(
                    isOvertime
                        ? SpeechRailDesignTokens.Color.attention
                        : SpeechRailDesignTokens.Color.inkSecondary
                )
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.tiny)
        .background(
            SpeechRailDesignTokens.Color.inputField.opacity(0.6),
            in: SpeechRailDesignTokens.Corner.nestedShape
        )
    }

    private func attentionMessage(blocked: TeleprompterSession.BlockReason) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            Text(blocked.title + "：" + blocked.detail)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            Spacer(minLength: 0)
        }
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
        .overlay(
            RoundedRectangle(
                cornerRadius: SpeechRailDesignTokens.Corner.nested,
                style: .continuous
            )
            .strokeBorder(
                SpeechRailDesignTokens.Color.attention.opacity(0.3),
                lineWidth: SpeechRailDesignTokens.Stroke.hairline
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("需要注意")
        .accessibilityValue(blocked.title)
    }

    private var adlibbingMessage: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "quote.bubble.fill")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            Text("自由发挥中 · 读回屏幕文字将自动跟随")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            Spacer(minLength: 0)
            Text("可按 ←/→ 切换段落")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(
            SpeechRailDesignTokens.Color.rail.opacity(
                SpeechRailDesignTokens.Teleprompter.stageAttentionBackgroundOpacity
            ),
            in: RoundedRectangle(
                cornerRadius: SpeechRailDesignTokens.Corner.nested,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: SpeechRailDesignTokens.Corner.nested,
                style: .continuous
            )
            .strokeBorder(
                SpeechRailDesignTokens.Color.rail.opacity(0.25),
                lineWidth: SpeechRailDesignTokens.Stroke.hairline
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("自由发挥中")
        .accessibilityValue("自由发挥中，读回屏幕文字将自动跟随")
    }

    // MARK: - 舞台段落阅读区

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
            totalCount: count,
            isBrowsingAll: isBrowsingAll && !isFollowing
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
            let isHovered = hoveredSegmentIndex == index && !isCurrent
            Button {
                session.moveToSegment(index)
            } label: {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    // 段落小标与引导
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        if isCurrent {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                                Circle()
                                    .fill(currentSegmentAccentColor)
                                    .frame(
                                        width: SpeechRailDesignTokens.Teleprompter.stageStatusIndicatorSize,
                                        height: SpeechRailDesignTokens.Teleprompter.stageStatusIndicatorSize
                                    )
                                Text(currentSegmentHeader(at: index))
                                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                                    .foregroundStyle(currentSegmentAccentColor)
                            }
                            Spacer(minLength: 0)
                            if segment.pauseHint == .medium || segment.pauseHint == .long {
                                pauseHintBadge(segment.pauseHint)
                            }
                            Text(currentSegmentHint)
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        } else {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                                Text(nonCurrentSegmentHeader(at: index))
                                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                                    .foregroundStyle(isHovered ? SpeechRailDesignTokens.Color.inkSecondary : SpeechRailDesignTokens.Color.inkTertiary)
                            }
                            Spacer(minLength: 0)
                            if isHovered {
                                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.system(size: 8))
                                    Text("由此段起讲")
                                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                }
                            } else {
                                Text(nonCurrentSegmentHint(at: index))
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            }
                        }
                    }

                    // 正文内容
                    Text(styledText(segment, index: index))
                        .font(.system(
                            size: settings.scriptPointSize,
                            weight: isCurrent ? .semibold : .regular
                        ))
                        .lineSpacing(settings.lineSpacing)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isCurrent
                        ? SpeechRailDesignTokens.Color.rail.opacity(
                            SpeechRailDesignTokens.Teleprompter.stageCurrentBackgroundOpacity
                        )
                        : (isHovered ? SpeechRailDesignTokens.Color.inputField.opacity(0.55) : Color.clear),
                    in: RoundedRectangle(
                        cornerRadius: SpeechRailDesignTokens.Corner.nested,
                        style: .continuous
                    )
                )
                .overlay(alignment: .leading) {
                    if isCurrent {
                        RoundedRectangle(
                            cornerRadius: SpeechRailDesignTokens.Corner.nested,
                            style: .continuous
                        )
                        .fill(currentSegmentAccentColor)
                        .frame(width: SpeechRailDesignTokens.Teleprompter.stageCurrentRailWidth)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                    }
                }
                .overlay {
                    if isHovered {
                        RoundedRectangle(
                            cornerRadius: SpeechRailDesignTokens.Corner.nested,
                            style: .continuous
                        )
                        .strokeBorder(
                            SpeechRailDesignTokens.Color.rail.opacity(0.25),
                            lineWidth: SpeechRailDesignTokens.Stroke.hairline
                        )
                    }
                }
            }
            .buttonStyle(.plain)
            .opacity(segmentOpacity(at: index))
            .onHover { isHovering in
                if isHovering {
                    hoveredSegmentIndex = index
                } else if hoveredSegmentIndex == index {
                    hoveredSegmentIndex = nil
                }
            }
            .accessibilityLabel("第 \(index + 1) 段，\(segment.text)")
            .accessibilityAction(named: "从此段起讲") {
                session.moveToSegment(index)
            }
        }
    }

    private var currentSegmentAccentColor: Color {
        if session.uncertainty != nil {
            return SpeechRailDesignTokens.Color.rail
        } else if session.phase == .following && session.hasHeardSpeech {
            return SpeechRailDesignTokens.Color.ready
        } else if session.phase == .following {
            return SpeechRailDesignTokens.Color.attention
        } else {
            return SpeechRailDesignTokens.Color.rail
        }
    }

    private func currentSegmentHeader(at index: Int) -> String {
        if session.uncertainty != nil {
            return "自由发挥中 · 第 \(index + 1) 段"
        } else if session.phase == .following {
            return session.hasHeardSpeech ? "跟读咬合 · 第 \(index + 1) 段" : "麦克风待命 · 第 \(index + 1) 段"
        } else if session.phase == .paused {
            return "已暂停 · 第 \(index + 1) 段"
        } else if session.phase == .ready || session.phase == .draft {
            return "当前起讲点 · 第 \(index + 1) 段"
        } else {
            return "当前定位 · 第 \(index + 1) 段"
        }
    }

    private var currentSegmentHint: String {
        if isFollowing {
            return "空格暂停 · 点击可重设起讲点"
        } else {
            return "空格开讲 · 当前以此段起讲"
        }
    }

    private func nonCurrentSegmentHeader(at index: Int) -> String {
        if index < session.currentSegmentIndex {
            return "前文已读 · 第 \(index + 1) 段"
        } else if index == session.currentSegmentIndex + 1 {
            return "下一段预备 · 第 \(index + 1) 段"
        } else {
            return "后续内容 · 第 \(index + 1) 段"
        }
    }

    private func nonCurrentSegmentHint(at index: Int) -> String {
        if index < session.currentSegmentIndex {
            return "点击由此段重新起讲"
        } else if index == session.currentSegmentIndex + 1 {
            return "点击切换为当前起讲段"
        } else {
            return "点击跳至此段起讲"
        }
    }

    private func segmentOpacity(at index: Int) -> Double {
        if index == session.currentSegmentIndex {
            return 1.0
        } else if hoveredSegmentIndex == index {
            return 0.88
        } else if index < session.currentSegmentIndex {
            return 0.40
        } else if index == session.currentSegmentIndex + 1 {
            return SpeechRailDesignTokens.Teleprompter.stageNextSegmentOpacity
        } else {
            return 0.55
        }
    }

    private func pauseHintBadge(_ hint: TeleprompterPauseHint) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            Image(systemName: "wind")
                .font(.system(size: 8))
            Text(pauseHintLabel(hint))
                .font(SpeechRailDesignTokens.Typography.caption)
        }
        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
        .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
        .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
        .background(
            SpeechRailDesignTokens.Color.rail.opacity(0.12),
            in: Capsule()
        )
    }

    private func pauseHintLabel(_ hint: TeleprompterPauseHint) -> String {
        switch hint {
        case .short: "换气"
        case .medium: "句间停顿"
        case .long: "长停顿"
        }
    }

    private func styledText(_ segment: TeleprompterSegment, index: Int) -> AttributedString {
        var text = AttributedString(segment.text)
        let isCurrent = index == session.currentSegmentIndex
        let isPast = index < session.currentSegmentIndex

        if isCurrent {
            text.foregroundColor = SpeechRailDesignTokens.Color.ink
            let count = min(segment.text.utf16.count, max(0, session.readingOffset))
            if let range = Range(NSRange(location: 0, length: count), in: segment.text),
               let attributedRange = Range(range, in: text) {
                text[attributedRange].foregroundColor = SpeechRailDesignTokens.Color.inkTertiary
            }
            if !segment.keywords.isEmpty {
                for keyword in segment.keywords where !keyword.isEmpty {
                    var searchRange = text.startIndex..<text.endIndex
                    while let match = text[searchRange].range(of: keyword) {
                        let matchEndOffset = text.characters.distance(from: text.startIndex, to: match.upperBound)
                        if matchEndOffset > count {
                            text[match].foregroundColor = SpeechRailDesignTokens.Color.rail
                            text[match].inlinePresentationIntent = .stronglyEmphasized
                        }
                        searchRange = match.upperBound..<text.endIndex
                    }
                }
            }
        } else if isPast {
            text.foregroundColor = SpeechRailDesignTokens.Color.inkTertiary
        } else {
            text.foregroundColor = SpeechRailDesignTokens.Color.inkSecondary
        }
        return text
    }

    // MARK: - 舞台操控栏

    private var controls: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            // 主动作：开始/暂停跟读
            Button {
                if isFollowing {
                    session.pauseFollowing()
                } else {
                    isBrowsingAll = false
                    Task { await session.resumeFollowing() }
                }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: isFollowing ? "pause.fill" : "play.fill")
                    Text(isFollowing ? "暂停跟读" : startLabel)
                    kbdBadge("␣")
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(isFollowing ? "暂停跟读，快捷键空格" : "\(startLabel)，快捷键空格")
            .disabled(session.isResuming || session.phase == .preparing)
            .speechRailButton(isFollowing ? .secondary : .primary)

            // 一级按钮：上一段
            Button {
                session.moveToPrevious()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "chevron.left")
                    Text("上一段")
                    kbdBadge("←")
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(session.currentSegmentIndex <= 0)
            .speechRailButton(.secondary)
            .help("切换到上一段（快捷键 ←）")

            // 一级按钮：下一段 / 完成演说
            if isLastSegment && isFollowing {
                Button {
                    Task {
                        await session.endFollowing()
                    }
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("完成演说")
                    }
                }
                .speechRailButton(.primary)
                .help("已至末段，点击完成演说并查看节奏小结")
            } else {
                Button {
                    session.moveToNext()
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text("下一段")
                        Image(systemName: "chevron.right")
                        kbdBadge("→")
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(isLastSegment)
                .speechRailButton(.secondary)
                .help("切换到下一段（快捷键 →）")
            }

            // 重读当前段
            Button {
                Task { await session.resetFollow() }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("重读本段")
                    kbdBadge("R")
                }
            }
            .keyboardShortcut("r", modifiers: [])
            .disabled(session.isResuming || session.phase == .preparing)
            .speechRailButton(.secondary)
            .help("从当前段开头重新跟读（快捷键 R）")

            Spacer(minLength: 0)

            // 快捷字号即时缩放微调
            HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                Button {
                    settings.decreaseFontScale()
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                .disabled(settings.fontScale <= SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale)
                .help("缩小字号（快捷键 ⌘-）")

                Text("\(Int(settings.scriptPointSize)) pt")
                    .font(SpeechRailDesignTokens.Typography.technicalValue)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .frame(minWidth: 32)

                Button {
                    settings.increaseFontScale()
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                .disabled(settings.fontScale >= SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale)
                .help("放大字号（快捷键 ⌘+）")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
            .background(
                SpeechRailDesignTokens.Color.inputField,
                in: SpeechRailDesignTokens.Corner.nestedShape
            )

            // 快捷透明度即时预设与微调
            Menu {
                Text("舞台材质透明度")
                Divider()
                Button("通透 (60%)") { settings.opacity = 0.60 }
                Button("平衡 (75%)") { settings.opacity = 0.75 }
                Button("清晰 (90%)") { settings.opacity = 0.90 }
                Button("纯色 (100%)") { settings.opacity = 1.00 }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 9))
                    Text("\(Int(round(settings.opacity * 100)))%")
                        .font(SpeechRailDesignTokens.Typography.technicalValue)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
                .background(
                    SpeechRailDesignTokens.Color.inputField,
                    in: SpeechRailDesignTokens.Corner.nestedShape
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("快速切换舞台背景透明度")

            // 结束演说
            Button {
                handleEndOrClose()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "xmark")
                    Text("结束")
                    kbdBadge("Esc")
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("结束提词，快捷键 Esc")
            .speechRailButton(.destructive)
        }
        .controlSize(.regular)
        .background {
            // 隐藏辅助快捷键：支持演示翻页笔（↑/↓）、字号缩放（⌘+/⌘-）与全稿查阅（⌘A）
            Group {
                Button("") { session.moveToPrevious() }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { session.moveToNext() }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { settings.increaseFontScale() }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("") { settings.decreaseFontScale() }
                    .keyboardShortcut("-", modifiers: [.command])
                if !isFollowing {
                    Button("") {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
                            isBrowsingAll.toggle()
                            if isBrowsingAll { scrollToReadingPosition() }
                        }
                    }
                    .keyboardShortcut("a", modifiers: [.command])
                }
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private func handleEndOrClose() {
        if session.runClock.elapsedSeconds > 10 || session.currentSegmentIndex > 0 {
            Task {
                await session.endFollowing()
            }
        } else {
            Task {
                await session.endFollowing()
                close()
            }
        }
    }

    // MARK: - 舞台完稿与复盘小结

    private var stageSummary: TeleprompterStageSummary {
        let segments = session.activeVersion?.segments ?? []
        return TeleprompterStagePresentation.computeSummary(
            segments: segments,
            currentSegmentIndex: session.currentSegmentIndex,
            elapsedSeconds: session.runClock.elapsedSeconds,
            targetSeconds: session.runClock.targetSeconds,
            pace: session.pace,
            currentCalibrationFactor: session.calibrationFactor
        )
    }

    private var stageSummaryView: some View {
        VStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            // 1. 顶部祝贺徽章
            VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: SpeechRailDesignTokens.Teleprompter.stageSummaryIconSize))
                    .foregroundStyle(SpeechRailDesignTokens.Color.ready)

                Text("演说圆满完成")
                    .font(SpeechRailDesignTokens.Typography.windowTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                Text("本次提词已全部结束，以下是你的演说节奏与语速复盘")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .padding(.top, SpeechRailDesignTokens.Spacing.sm)

            // 2. 统计卡片栅格 (4 个核心指标)
            let summary = stageSummary
            let paceColor: Color = {
                switch summary.paceStatus {
                case .steady: SpeechRailDesignTokens.Color.ready
                case .brisk: SpeechRailDesignTokens.Color.rail
                case .slow: SpeechRailDesignTokens.Color.attention
                case .establishing: SpeechRailDesignTokens.Color.inkSecondary
                }
            }()
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                summaryMetricCard(
                    icon: "stopwatch",
                    label: "实际总用时",
                    value: formatClock(summary.elapsedSeconds),
                    subtext: timingSubtext(summary: summary)
                )

                summaryMetricCard(
                    icon: "waveform",
                    label: "实测语速",
                    value: summary.actualWPM > 0 ? "\(summary.actualWPM) 字/分" : "--",
                    subtext: "基准：约 \(Int(round(session.pace.cjkUnitsPerMinute / session.calibrationFactor))) 字/分"
                )

                summaryMetricCard(
                    icon: "doc.text",
                    label: "朗读进度",
                    value: "\(summary.completedSegments) / \(summary.totalSegments) 段",
                    subtext: "总字数：约 \(summary.totalSpokenUnits) 字"
                )

                summaryMetricCard(
                    icon: "gauge.with.dots.needle.50percent",
                    label: "节奏评价",
                    value: summary.paceStatus.title,
                    subtext: summary.paceStatus.advice,
                    valueColor: paceColor
                )
            }
            .frame(maxWidth: .infinity)

            // 3. 语速个性化沉淀建议卡
            if summary.canCalibrate {
                if summary.needsCalibration {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Image(systemName: "lightbulb.max.fill")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)

                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Text("个性化语速校准建议")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            Text("实测语速为 \(summary.actualWPM) 字/分（建议系数 \(String(format: "%.2fx", summary.suggestedCalibrationFactor))）。采纳后，后续排稿预估将更加精准贴合你的说话节奏。")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }

                        Spacer(minLength: 0)

                        Button {
                            session.applyTrialCalibration(k: summary.suggestedCalibrationFactor)
                            hasAdoptedCalibration = true
                        } label: {
                            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                                if hasAdoptedCalibration {
                                    Image(systemName: "checkmark")
                                }
                                Text(hasAdoptedCalibration ? "已采纳" : "采纳此语速")
                            }
                        }
                        .disabled(hasAdoptedCalibration)
                        .speechRailButton(hasAdoptedCalibration ? .secondary : .primary)
                    }
                    .padding(SpeechRailDesignTokens.Spacing.sm)
                    .background(
                        SpeechRailDesignTokens.Color.attention.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                            .strokeBorder(
                                SpeechRailDesignTokens.Color.attention.opacity(0.2),
                                lineWidth: SpeechRailDesignTokens.Stroke.hairline
                            )
                    )
                } else {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ready)

                        Text("实测语速（约 \(summary.actualWPM) 字/分）与当前个人基准高度吻合，状态极佳。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                        Spacer(minLength: 0)
                    }
                    .padding(SpeechRailDesignTokens.Spacing.sm)
                    .background(
                        SpeechRailDesignTokens.Color.ready.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                            .strokeBorder(
                                SpeechRailDesignTokens.Color.ready.opacity(0.2),
                                lineWidth: SpeechRailDesignTokens.Stroke.hairline
                            )
                    )
                }
            }

            Spacer(minLength: 0)

            // 4. 底部动作栏
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Button {
                    session.restartToBeginning()
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("重新开讲")
                        kbdBadge("␣")
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                .speechRailButton(.secondary)
                .help("重置回第一段，准备重新朗读（快捷键空格）")

                Spacer()

                Button {
                    close()
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Text("关闭舞台")
                        kbdBadge("Esc")
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
                .speechRailButton(.primary)
                .help("关闭提词舞台卡片")
            }
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("演说复盘小结")
    }

    private func summaryMetricCard(
        icon: String,
        label: String,
        value: String,
        subtext: String,
        valueColor: Color = SpeechRailDesignTokens.Color.ink
    ) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                Text(label)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Text(value)
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Text(subtext)
                .font(.system(size: 10))
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Teleprompter.stageSummaryMetricBoxMinHeight, alignment: .topLeading)
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .background(
            SpeechRailDesignTokens.Color.inputField.opacity(0.8),
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                .strokeBorder(
                    SpeechRailDesignTokens.Surface.border,
                    lineWidth: SpeechRailDesignTokens.Stroke.hairline
                )
        )
    }

    private func timingSubtext(summary: TeleprompterStageSummary) -> String {
        if summary.targetSeconds > 0 {
            if summary.elapsedSeconds <= summary.targetSeconds {
                return "提前 \(formatClock(summary.targetSeconds - summary.elapsedSeconds))"
            } else {
                return "超时 \(formatClock(summary.elapsedSeconds - summary.targetSeconds))"
            }
        } else {
            return "计划 \(session.targetMinutes) 分钟"
        }
    }

    // MARK: - 辅助与纯文本格式化

    private func kbdBadge(_ text: String) -> some View {
        Text(text)
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stageKbdBadgePaddingHorizontal)
            .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stageKbdBadgePaddingVertical)
            .background(
                SpeechRailDesignTokens.Color.inputField.opacity(0.8),
                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
    }

    private var isLastSegment: Bool {
        guard let count = session.activeVersion?.segments.count else { return true }
        return session.currentSegmentIndex >= count - 1
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

    private func formatClock(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var statusText: String {
        if let blocked = session.blocked { return blocked.title }
        if session.isResuming { return "正在准备继续…" }
        if session.uncertainty != nil { return "自由发挥中 · 读回屏幕文字将自动跟随" }
        switch session.phase {
        case .following: return session.hasHeardSpeech ? "正在跟读，请按你的节奏朗读" : "请读一句稿件，系统会跟随你的声音"
        case .paused: return "已暂停跟读，按空格恢复"
        case .manual: return "手动提词：可用 ← / → 校正位置"
        case .preparing: return "正在连接语音识别…"
        case .analyzing: return "正在整理稿件…"
        case .review: return "请先检查 AI 建议"
        case .ready, .draft: return "候场就绪：按空格开始跟读"
        case .ended: return "提词已圆满结束"
        case .uncertain: return "自由发挥中 · 读回屏幕文字将自动跟随"
        }
    }
}
