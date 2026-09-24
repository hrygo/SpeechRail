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
    @State private var isBreathingGlow: Bool = false
    @State private var hasCopiedSummary: Bool = false

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
            .onAppear {
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                        isBreathingGlow = true
                    }
                }
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

            // 2. 细窄进度条与段落编号（支持时间 vs 文本双轨进度对照）
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                stageProgressBar
                    .frame(minWidth: 46, maxWidth: 76)

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

    private var stageProgressBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(SpeechRailDesignTokens.Color.inputField.opacity(0.9))
                    .frame(height: 4)

                Capsule()
                    .fill(SpeechRailDesignTokens.Color.rail)
                    .frame(width: max(4, width * CGFloat(progressValue)), height: 4)

                if session.targetMinutes > 0 && session.runClock.elapsedSeconds > 0 {
                    let timeRatio = min(1.0, session.runClock.elapsedSeconds / max(1.0, session.runClock.targetSeconds))
                    let tickX = min(max(0, width * CGFloat(timeRatio) - 1), width - 2)
                    let isAhead = progressValue >= timeRatio
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(isAhead ? SpeechRailDesignTokens.Color.ready : SpeechRailDesignTokens.Color.attention)
                        .frame(width: 2, height: 8)
                        .offset(x: tickX)
                }
            }
            .frame(height: height, alignment: .center)
        }
        .frame(height: 8)
    }

    @ViewBuilder
    private var statusCapsule: some View {
        switch session.phase {
        case .ready, .draft:
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "mic.badge.checkmark")
                    .font(.system(size: 9))
                Text("候场待命 · 空格开讲")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
            .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
            .background(SpeechRailDesignTokens.Color.rail.opacity(0.14), in: Capsule())

        case .following, .uncertain:
            followStatusCapsule()

        case .paused:
            followStatusCapsule(hint: "空格继续")

        case .manual:
            followStatusCapsule(hint: "方向键校正")

        case .preparing:
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在连接麦克风…")
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

    private func followStatusCapsule(hint: String? = nil) -> some View {
        let statusText = hint.map { "\(session.followStatusText) · \($0)" } ?? session.followStatusText
        return HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            if session.followState == .tracking {
                Circle()
                    .fill(followStatusColor)
                    .frame(
                        width: SpeechRailDesignTokens.Teleprompter.stageStatusIndicatorSize,
                        height: SpeechRailDesignTokens.Teleprompter.stageStatusIndicatorSize
                    )
                    .opacity(isBreathingGlow ? 1.0 : 0.6)
            } else {
                Image(systemName: followStatusSymbol)
                    .font(.system(size: 9))
                    .opacity(session.followState == .waitingForSpeech || session.followState == .listening
                        ? (isBreathingGlow ? 1.0 : 0.45) : 1.0)
            }
            Text(statusText)
                .font(SpeechRailDesignTokens.Typography.captionMedium)
        }
        .foregroundStyle(followStatusColor)
        .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
        .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
        .background(followStatusBackground, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    private var followStatusColor: Color {
        switch session.followState {
        case .waitingForSpeech, .listening, .catchingUp, .paused:
            SpeechRailDesignTokens.Color.attention
        case .tracking:
            SpeechRailDesignTokens.Color.ready
        case .freePlaying:
            SpeechRailDesignTokens.Color.rail
        case .manual:
            SpeechRailDesignTokens.Color.inkSecondary
        }
    }

    private var followStatusBackground: Color {
        switch session.followState {
        case .waitingForSpeech, .listening, .catchingUp, .paused:
            SpeechRailDesignTokens.Color.attention.opacity(0.14)
        case .tracking:
            SpeechRailDesignTokens.Color.ready.opacity(0.14)
        case .freePlaying:
            SpeechRailDesignTokens.Color.rail.opacity(0.14)
        case .manual:
            SpeechRailDesignTokens.Color.inputField
        }
    }

    private var followStatusSymbol: String {
        switch session.followState {
        case .waitingForSpeech: "mic.fill"
        case .listening: "waveform"
        case .tracking: "checkmark"
        case .catchingUp: "arrow.triangle.2.circlepath"
        case .freePlaying: "arrow.triangle.branch"
        case .paused: "pause.fill"
        case .manual: "hand.tap.fill"
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

    private var paceDelta: TimeInterval? {
        let total = session.activeVersion?.segments.count ?? 0
        return TeleprompterStagePresentation.paceDeltaSeconds(
            currentIndex: session.currentSegmentIndex,
            totalCount: total,
            elapsedSeconds: session.runClock.elapsedSeconds,
            targetSeconds: session.runClock.targetSeconds
        )
    }

    @ViewBuilder
    private var paceIndicatorCapsule: some View {
        let status = currentPaceStatus
        if let delta = paceDelta {
            let formatted = TeleprompterStagePresentation.formattedPaceDelta(deltaSeconds: delta)
            if formatted.isAhead {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "hare.fill")
                        .font(.system(size: 8))
                    Text(formatted.label)
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingHorizontal)
                .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingVertical)
                .background(SpeechRailDesignTokens.Color.rail.opacity(0.12), in: Capsule())
                .help("当前进度超前预定用时 \(Int(round(delta))) 秒 · 保持当前语速可准时或提前完稿，后续段落可从容展开")
            } else if formatted.isBehind {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "tortoise.fill")
                        .font(.system(size: 8))
                    Text(formatted.label)
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingHorizontal)
                .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingVertical)
                .background(SpeechRailDesignTokens.Color.attention.opacity(0.14), in: Capsule())
                .help("当前进度滞后预定用时 \(Int(round(abs(delta)))) 秒 · 建议适当加快语速或精简细节保持准时完稿")
            } else {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8))
                    Text(formatted.label)
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                .foregroundStyle(SpeechRailDesignTokens.Color.ready)
                .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingHorizontal)
                .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePaceIndicatorPaddingVertical)
                .background(SpeechRailDesignTokens.Color.ready.opacity(0.12), in: Capsule())
                .help(status.advice)
            }
        } else {
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
        .help(isBrowsingAll ? "切换为跟读聚焦两段模式（快捷键 ⌘A）" : "展开查阅完整讲稿，可随时点选段落从容起讲（快捷键 ⌘A）")
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
        let currentText = session.currentSegment?.text ?? ""
        let offset = min(currentText.utf16.count, max(0, session.readingOffset))
        let snippet = anchorSnippet(from: currentText, offset: offset, length: 8)

        return HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "arrow.triangle.branch")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            if !snippet.isEmpty {
                Text("脱稿发挥中 · 读出下划线「\(snippet)…」即可自动归队")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            } else {
                Text("脱稿发挥中 · 读回屏幕文字即可自动归队")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            }
            Spacer(minLength: 0)
            Text("按 ←/→ 或点击段落随时重定位")
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
        .accessibilityLabel("脱稿发挥中")
        .accessibilityValue(snippet.isEmpty ? "脱稿发挥中，读回屏幕文字即可自动恢复跟读" : "脱稿发挥中，读出\(snippet)即可自动恢复跟读")
    }

    private func anchorSnippet(from text: String, offset: Int, length: Int = 8) -> String {
        guard let range = Range(NSRange(location: min(offset, text.utf16.count), length: min(length, max(0, text.utf16.count - offset))), in: text) else {
            return ""
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
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
                                    Text("由此段起讲 ↵")
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

                    // 段末停顿与留白指引（处于当前主讲段且有停顿时呈现，精准落位在句末视线处）
                    if isCurrent && (segment.pauseHint == .medium || segment.pauseHint == .long) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Image(systemName: pauseHintIcon(segment.pauseHint))
                                .font(.system(size: 8))
                            Text(pauseHintGuidance(segment.pauseHint))
                                .font(SpeechRailDesignTokens.Typography.caption)
                        }
                        .foregroundStyle(pauseHintColor(segment.pauseHint))
                        .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
                        .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
                        .background(pauseHintColor(segment.pauseHint).opacity(0.12), in: Capsule())
                        .padding(.top, SpeechRailDesignTokens.Spacing.tiny)
                    }
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
                        .opacity(1.0)
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
            return "脱稿暂离 · 第 \(index + 1) 段"
        } else if session.phase == .following {
            return session.hasHeardSpeech ? "跟读对齐 · 第 \(index + 1) 段" : "待命起讲 · 第 \(index + 1) 段"
        } else if session.phase == .paused {
            return "已暂停 · 第 \(index + 1) 段"
        } else if session.phase == .ready || session.phase == .draft {
            return "候场起讲点 · 第 \(index + 1) 段"
        } else {
            return "当前定位 · 第 \(index + 1) 段"
        }
    }

    private var currentSegmentHint: String {
        if isFollowing {
            return "空格暂停 · 点击可重设起讲点"
        } else {
            return "按空格立即开讲 · 当前从此段开始"
        }
    }

    private func nonCurrentSegmentHeader(at index: Int) -> String {
        if index < session.currentSegmentIndex {
            return "已读段落 · 第 \(index + 1) 段"
        } else if index == session.currentSegmentIndex + 1 {
            return "下一段预备 · 第 \(index + 1) 段"
        } else {
            return "后续段落 · 第 \(index + 1) 段"
        }
    }

    private func nonCurrentSegmentHint(at index: Int) -> String {
        if index < session.currentSegmentIndex {
            return "点击切换为此段重讲"
        } else if index == session.currentSegmentIndex + 1 {
            return "点击切换为主讲段"
        } else {
            return "点击跳转至此段起讲"
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
            Image(systemName: pauseHintIcon(hint))
                .font(.system(size: 8))
            Text(pauseHintLabel(hint))
                .font(SpeechRailDesignTokens.Typography.caption)
        }
        .foregroundStyle(pauseHintColor(hint))
        .padding(.horizontal, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingHorizontal)
        .padding(.vertical, SpeechRailDesignTokens.Teleprompter.stagePauseHintPaddingVertical)
        .background(
            pauseHintColor(hint).opacity(0.12),
            in: Capsule()
        )
    }

    private func pauseHintIcon(_ hint: TeleprompterPauseHint) -> String {
        switch hint {
        case .short: "wind"
        case .medium: "timer"
        case .long: "hourglass.bottomhalf.filled"
        }
    }

    private func pauseHintLabel(_ hint: TeleprompterPauseHint) -> String {
        switch hint {
        case .short: "微换气"
        case .medium: "留白 1s"
        case .long: "驻足 2s"
        }
    }

    private func pauseHintGuidance(_ hint: TeleprompterPauseHint) -> String {
        switch hint {
        case .short: "此处轻微换气 · 自然过渡"
        case .medium: "段末留白 1 秒 · 稍作换气再接下段"
        case .long: "段末驻足 2 秒 · 让要点落地再开下段"
        }
    }

    private func pauseHintColor(_ hint: TeleprompterPauseHint) -> Color {
        switch hint {
        case .short: SpeechRailDesignTokens.Color.inkSecondary
        case .medium: SpeechRailDesignTokens.Color.rail
        case .long: SpeechRailDesignTokens.Color.ready
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
            if session.uncertainty != nil && count < segment.text.utf16.count {
                let anchorLen = min(8, segment.text.utf16.count - count)
                if let anchorNSRange = Range(NSRange(location: count, length: anchorLen), in: segment.text),
                   let anchorRange = Range(anchorNSRange, in: text) {
                    text[anchorRange].underlineStyle = .single
                    text[anchorRange].foregroundColor = SpeechRailDesignTokens.Color.rail
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
                    Text(isFollowing ? "暂停提词" : startLabel)
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
            // 隐藏辅助快捷键：支持演示翻页笔（↑/↓、PageUp/PageDown）、首末跳段（Home/End）、字号缩放（⌘+/⌘-/⌘0）、透明度微调（⌘[/⌘]）与全稿查阅（⌘A）
            Group {
                Button("") { session.moveToPrevious() }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { session.moveToNext() }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { session.moveToPrevious() }
                    .keyboardShortcut(.pageUp, modifiers: [])
                Button("") { session.moveToNext() }
                    .keyboardShortcut(.pageDown, modifiers: [])
                Button("") { session.moveToSegment(0) }
                    .keyboardShortcut(.home, modifiers: [])
                Button("") {
                    if let last = session.activeVersion?.segments.count, last > 0 {
                        session.moveToSegment(last - 1)
                    }
                }
                .keyboardShortcut(.end, modifiers: [])
                Button("") { settings.increaseFontScale() }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("") { settings.decreaseFontScale() }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("") { settings.resetFontScale() }
                    .keyboardShortcut("0", modifiers: [.command])
                Button("") { settings.decreaseOpacity() }
                    .keyboardShortcut("[", modifiers: [.command])
                Button("") { settings.increaseOpacity() }
                    .keyboardShortcut("]", modifiers: [.command])
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
            // 1. 顶部复盘标头（专业、清晰、数据导向）
            VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: SpeechRailDesignTokens.Teleprompter.stageSummaryIconSize))
                    .foregroundStyle(SpeechRailDesignTokens.Color.ready)

                Text("演说复盘与节奏分析")
                    .font(SpeechRailDesignTokens.Typography.windowTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)

                Text("本次提词已结束。以下是本次演说的时长、语速与节拍分析数据")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .padding(.top, SpeechRailDesignTokens.Spacing.sm)

            // 2. 统计卡片栅格 (4 个核心量化指标)
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
                    label: "实际用时",
                    value: formatClock(summary.elapsedSeconds),
                    subtext: timingSubtext(summary: summary)
                )

                let benchmarkWPM = Int(round(session.pace.cjkUnitsPerMinute / session.calibrationFactor))
                let deltaWPM = summary.actualWPM - benchmarkWPM
                let deltaStr = deltaWPM >= 0 ? "+\(deltaWPM)" : "\(deltaWPM)"
                let wpmSubtext = summary.actualWPM > 0 ? "基准约 \(benchmarkWPM) 字/分 (\(deltaStr))" : "基准约 \(benchmarkWPM) 字/分"
                summaryMetricCard(
                    icon: "waveform",
                    label: "实际语速",
                    value: summary.actualWPM > 0 ? "\(summary.actualWPM) 字/分" : "--",
                    subtext: wpmSubtext
                )

                summaryMetricCard(
                    icon: "doc.text",
                    label: "完成段数",
                    value: "\(summary.completedSegments) / \(summary.totalSegments) 段",
                    subtext: "总字数：共约 \(summary.totalSpokenUnits) 字"
                )

                summaryMetricCard(
                    icon: "gauge.with.dots.needle.50percent",
                    label: "节奏评估",
                    value: summary.paceStatus.title,
                    subtext: summary.paceStatus.advice,
                    valueColor: paceColor
                )
            }
            .frame(maxWidth: .infinity)

            // 3. 个人语速基准校准卡（真实服务与能力沉淀闭环）
            if summary.canCalibrate {
                if summary.needsCalibration {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Image(systemName: "slider.horizontal.below.square.and.filled.rectangle")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.attention)

                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Text("更新个人语速基准 (推荐)")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            Text("实测语速为 \(summary.actualWPM) 字/分（建议系数 \(String(format: "%.2fx", summary.suggestedCalibrationFactor))）。采纳后，后续讲稿的时长预估和排期将自动按你的个人语速计算。")
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
                                Text(hasAdoptedCalibration ? "已更新基准" : "采纳为个人基准")
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

                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Text("语速与当前基准高度吻合")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            Text("实测语速（约 \(summary.actualWPM) 字/分）与现有个人基准偏差在 2% 以内，当前排稿预估模型准确可靠，无需调整。")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }

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
                        Text("重新演练")
                        kbdBadge("␣")
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                .speechRailButton(.secondary)
                .help("重置回第一段，准备重新朗读演练（快捷键空格）")

                Button {
                    copySummaryReport(summary: stageSummary)
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: hasCopiedSummary ? "checkmark" : "doc.on.doc")
                        Text(hasCopiedSummary ? "已复制复盘" : "复制复盘报告")
                    }
                }
                .speechRailButton(.secondary)
                .help("将本次演说复盘数据复制到剪贴板，方便归档沉淀")

                Spacer()

                Button {
                    close()
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "checkmark")
                        Text("完成提词")
                        kbdBadge("Esc")
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
                .speechRailButton(.primary)
                .help("关闭提词舞台卡片并保留进度（快捷键 Esc）")
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

    private func copySummaryReport(summary: TeleprompterStageSummary) {
        let docTitle: String = {
            let raw = session.document?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? "未命名讲稿" : raw
        }()
        let benchmarkWPM = Int(round(session.pace.cjkUnitsPerMinute / session.calibrationFactor))
        let deltaWPM = summary.actualWPM - benchmarkWPM
        let deltaStr = deltaWPM >= 0 ? "+\(deltaWPM)" : "\(deltaWPM)"
        let text = """
        【SpeechRail 提词演说复盘报告】
        · 讲稿篇目：\(docTitle)
        · 实际用时：\(formatClock(summary.elapsedSeconds)) / 计划用时：\(formatClock(summary.targetSeconds))（\(timingSubtext(summary: summary))）
        · 实际语速：\(summary.actualWPM) 字/分（基准语速：\(benchmarkWPM) 字/分，偏差 \(deltaStr)）
        · 讲稿达成：\(summary.completedSegments) / \(summary.totalSegments) 段（演说字数：共约 \(summary.totalSpokenUnits) 字）
        · 节奏评估：\(summary.paceStatus.title)（\(summary.paceStatus.advice)）
        · 个人校准：建议系数 \(String(format: "%.2fx", summary.suggestedCalibrationFactor))（当前基准：\(String(format: "%.2fx", session.calibrationFactor))）
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        withAnimation {
            hasCopiedSummary = true
        }
    }

    private func timingSubtext(summary: TeleprompterStageSummary) -> String {
        if summary.targetSeconds > 0 {
            let diff = abs(summary.targetSeconds - summary.elapsedSeconds)
            let percent = Int(round((diff / summary.targetSeconds) * 100))
            if summary.elapsedSeconds <= summary.targetSeconds {
                return diff < 3 ? "与计划时长吻合" : "提前 \(formatClock(diff)) (比计划快 \(percent)%)"
            } else {
                return "超出 \(formatClock(diff)) (比计划慢 \(percent)%)"
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
        case .paused: "继续提词"
        case .manual: "恢复跟读"
        default: "开始提词"
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
        if session.uncertainty != nil { return "脱稿发挥中 · 读回屏幕文字即可自动归队" }
        switch session.phase {
        case .following: return session.hasHeardSpeech ? "语音识别正常跟读中" : "麦克风已就绪，请朗读屏幕稿件"
        case .paused: return "已暂停跟读，按空格恢复"
        case .manual: return "手动选段模式：可用 ← / → 校正起讲位置"
        case .preparing: return "正在连接语音识别…"
        case .analyzing: return "正在整理稿件…"
        case .review: return "请先检查 AI 建议"
        case .ready, .draft: return "候场待命：按空格键开始提词"
        case .ended: return "提词已圆满结束"
        case .uncertain: return "脱稿发挥中 · 读回屏幕文字即可自动归队"
        }
    }
}
