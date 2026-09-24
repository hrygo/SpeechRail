import SwiftUI

public struct TeleprompterStageView: View {
    @Bindable private var session: TeleprompterSession
    @Bindable private var settings: TeleprompterStageSettings
    @Bindable private var presentation: TeleprompterStagePresentationState
    private let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var isBrowsingAll: Bool = false
    @State private var hoveredSegmentIndex: Int? = nil
    @State private var isAppearancePopoverPresented = false
    @State private var pointerInsideStage = false
    @State private var controlsVisible = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var initialRevealActive = true
    @State private var initialRevealTask: Task<Void, Never>?
    @State private var interactionState = TeleprompterStageInteractionState()
    @State private var errorNoticeVisible = false
    @State private var errorNoticeTask: Task<Void, Never>?
    @FocusState private var focusedControl: StageControlFocus?

    private enum StageControlFocus: Hashable {
        case previous
        case next
        case voice
        case display
        case close
    }

    public init(
        session: TeleprompterSession,
        settings: TeleprompterStageSettings,
        presentation: TeleprompterStagePresentationState,
        close: @escaping () -> Void
    ) {
        self.session = session
        self.settings = settings
        self.presentation = presentation
        self.close = close
    }

    public var body: some View {
        stageWithLifecycle
    }

    private var stageBase: some View {
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
            .accessibilityElement(children: .contain)
            .accessibilityLabel("AI 提词器舞台")
            .accessibilityValue("\(session.progressText)，\(statusText)")
    }

    private var stageWithPresentation: some View {
        stageBase
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controlsLayer
            }
            .onHover { isInside in
                pointerInsideStage = isInside
                interactionState.setPointerInside(isInside)
                if isInside {
                    revealControls(immediate: true)
                } else {
                    scheduleControlsHide()
                }
            }
    }

    private var stageWithObservation: some View {
        stageWithPresentation
            .onChange(of: session.activeVersion?.id, initial: true) { _, _ in
                scrollToReadingPosition()
            }
            .onChange(of: session.currentSegmentIndex) { _, _ in scrollToReadingPosition() }
            .onChange(of: session.phase) { _, newPhase in
                handlePhaseChange(to: newPhase)
            }
            .onChange(of: session.blocked) { _, blocked in
                showErrorNoticeIfNeeded(blocked != nil || session.lastFailure != nil)
            }
            .onChange(of: session.lastFailure) { _, failure in
                showErrorNoticeIfNeeded(failure != nil && session.blocked == nil)
            }
            .onChange(of: focusedControl) { _, _ in
                handleControlFocusChange()
            }
            .onChange(of: isAppearancePopoverPresented) { _, presented in
                if presented {
                    revealControls(immediate: true)
                } else {
                    scheduleControlsHide()
                }
            }
            .onChange(of: presentation.settingsRequestID) { _, requestID in
                guard requestID != nil else { return }
                isAppearancePopoverPresented = true
            }
    }

    private var stageWithSettingsObservation: some View {
        stageWithObservation
            .onChange(of: isBrowsingAll) { _, browsing in
                if browsing {
                    session.takeOverForManualScroll()
                }
                scrollToReadingPosition()
            }
            .onChange(of: settings.alwaysShowControls) { _, _ in refreshControlsVisibility() }
            .onChange(of: settings.showClockAndProgress) { _, _ in refreshControlsVisibility() }
            .onChange(of: voiceOverEnabled) { _, _ in refreshControlsVisibility() }
            .onChange(of: session.isStageOpen) { _, isOpen in
                handleStageOpenChange(isOpen)
            }
    }

    private var stageWithKeyboard: some View {
        stageWithSettingsObservation
            .onKeyPress(.tab) { handleTabKey() }
            .onKeyPress(.space) { handleNextKey() }
            .onKeyPress(.leftArrow) { handlePreviousKey() }
            .onKeyPress(.rightArrow) { handleNextKey() }
            .onKeyPress(.upArrow) { handlePreviousKey() }
            .onKeyPress(.downArrow) { handleNextKey() }
            .onKeyPress(.pageUp) { handlePreviousKey() }
            .onKeyPress(.pageDown) { handleNextKey() }
            .onKeyPress(.home) { handleHomeKey() }
            .onKeyPress(.end) { handleEndKey() }
            .onKeyPress(.escape) { handleEscapeKey() }
    }

    private var stageWithLifecycle: some View {
        stageWithKeyboard
            .onAppear { handleStageAppear() }
            .onDisappear {
                hideControlsTask?.cancel()
                initialRevealTask?.cancel()
                errorNoticeTask?.cancel()
            }
    }

    @ViewBuilder
    private var stageContent: some View {
        VStack(spacing: SpeechRailDesignTokens.Teleprompter.stageSegmentSpacing) {
            auxiliaryStatusBar
            if errorNoticeVisible {
                if let blocked = session.blocked {
                    attentionMessage(blocked: blocked)
                } else if let failure = session.lastFailure {
                    saveFailureMessage(failure)
                }
            }
            scriptStack
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
    }

    private var acceptsReadingKeyCommands: Bool {
        focusedControl == nil && !isAppearancePopoverPresented
    }

    private func handleControlFocusChange() {
        let focusInside = focusedControl != nil
        interactionState.setControlFocus(focusInside)
        if focusInside {
            revealControls(immediate: true)
        } else if !pointerInsideStage && !isAppearancePopoverPresented {
            scheduleControlsHide()
        }
    }

    private func handleStageOpenChange(_ isOpen: Bool) {
        if isOpen {
            beginInitialReveal()
        } else {
            initialRevealActive = false
            interactionState = TeleprompterStageInteractionState()
            pointerInsideStage = false
            refreshControlsVisibility()
        }
    }

    private func handleStageAppear() {
        if session.isStageOpen {
            beginInitialReveal()
        }
        refreshControlsVisibility()
    }

    private func handleTabKey() -> KeyPress.Result {
        interactionState.requestKeyboardReveal()
        revealControls(immediate: true)
        return .ignored
    }

    private func handleNextKey() -> KeyPress.Result {
        guard acceptsReadingKeyCommands else { return .ignored }
        session.moveToNext()
        return .handled
    }

    private func handlePreviousKey() -> KeyPress.Result {
        guard acceptsReadingKeyCommands else { return .ignored }
        session.moveToPrevious()
        return .handled
    }

    private func handleHomeKey() -> KeyPress.Result {
        guard acceptsReadingKeyCommands else { return .ignored }
        session.restartToBeginning()
        return .handled
    }

    private func handleEndKey() -> KeyPress.Result {
        guard acceptsReadingKeyCommands else { return .ignored }
        if let count = session.activeVersion?.segments.count, count > 0 {
            session.moveToSegment(count - 1)
        }
        return .handled
    }

    private func handleEscapeKey() -> KeyPress.Result {
        if isAppearancePopoverPresented {
            isAppearancePopoverPresented = false
        } else {
            close()
        }
        return .handled
    }

    private var interactionVisibility: TeleprompterStageInteractionVisibility {
        TeleprompterStageInteractionVisibility(
            pointerInside: pointerInsideStage,
            controlFocusInside: focusedControl != nil,
            menuOrPopoverPresented: isAppearancePopoverPresented,
            alwaysShowControls: settings.alwaysShowControls,
            voiceOverEnabled: voiceOverEnabled,
            initialRevealActive: initialRevealActive,
            keyboardRevealRequested: interactionState.keyboardRevealRequested
        )
    }

    private func refreshControlsVisibility() {
        if TeleprompterStageInteractionPolicy.controlsVisible(for: interactionVisibility) {
            revealControls(immediate: true)
        } else {
            scheduleControlsHide()
        }
    }

    private func revealControls(immediate: Bool) {
        hideControlsTask?.cancel()
        hideControlsTask = nil
        guard !controlsVisible else { return }
        if reduceMotion || immediate {
            controlsVisible = true
        } else {
            withAnimation(.easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
                controlsVisible = true
            }
        }
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        guard controlsVisible else { return }
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: TeleprompterStageInteractionPolicy.hideDelay)
            guard !Task.isCancelled else { return }
            if TeleprompterStageInteractionPolicy.controlsVisible(for: interactionVisibility) {
                refreshControlsVisibility()
                return
            }
            if reduceMotion {
                controlsVisible = false
            } else {
                withAnimation(.easeInOut(duration: SpeechRailDesignTokens.Motion.standardDuration)) {
                    controlsVisible = false
                }
            }
        }
    }

    private func beginInitialReveal() {
        initialRevealTask?.cancel()
        initialRevealActive = true
        revealControls(immediate: true)
        initialRevealTask = Task { @MainActor in
            try? await Task.sleep(for: TeleprompterStageInteractionPolicy.initialRevealDuration)
            guard !Task.isCancelled, session.isStageOpen else { return }
            initialRevealActive = false
            refreshControlsVisibility()
        }
    }

    private func showErrorNoticeIfNeeded(_ shouldShow: Bool) {
        guard shouldShow else { return }
        errorNoticeTask?.cancel()
        errorNoticeVisible = true
        errorNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: TeleprompterStageInteractionPolicy.errorNoticeDuration)
            guard !Task.isCancelled else { return }
            errorNoticeVisible = false
        }
    }

    private var auxiliaryStatusBar: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            if session.isMicrophoneCapturing {
                Label("麦克风使用中", systemImage: "mic.fill")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
                    .accessibilityLabel("麦克风使用中")
            }

            if settings.showClockAndProgress {
                Text(session.progressText)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(formatClock(session.runClock.elapsedSeconds))
                    .font(SpeechRailDesignTokens.Typography.technicalValue)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .accessibilityLabel("本次已用 \(formatClock(session.runClock.elapsedSeconds))")
            }

            Spacer(minLength: 0)
        }
        .frame(height: SpeechRailDesignTokens.Teleprompter.stageAuxiliaryBarHeight)
        .accessibilityElement(children: .combine)
    }

    private var controlsLayer: some View {
        ZStack(alignment: .bottom) {
            if controlsVisible {
                controls
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(
                            cornerRadius: SpeechRailDesignTokens.Corner.container,
                            style: .continuous
                        )
                    )
                    .transition(
                        reduceMotion
                            ? .identity
                            : .opacity.combined(with: .move(edge: .bottom))
                    )
            }
        }
        .frame(height: SpeechRailDesignTokens.Teleprompter.stageControlAreaHeight)
        .allowsHitTesting(controlsVisible)
        .accessibilityHidden(!controlsVisible)
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

    private func saveFailureMessage(_ failure: String) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            Text("进度未保存，当前阅读仍可继续。")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("进度未保存，当前阅读仍可继续")
        .accessibilityHint(failure)
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
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .interacting {
                    session.takeOverForManualScroll()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .textSelection(.enabled)
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
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(styledText(segment, index: index))
                    .font(.system(
                        size: settings.scriptPointSize,
                        weight: isCurrent ? .semibold : .regular
                    ))
                    .lineSpacing(settings.lineSpacing)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("第 \(index + 1) 段，\(segment.text)")
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    RoundedRectangle(
                        cornerRadius: SpeechRailDesignTokens.Corner.nested,
                        style: .continuous
                    )
                    .fill(currentSegmentAccentColor)
                    .frame(width: SpeechRailDesignTokens.Teleprompter.stageCurrentRailWidth)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                } else {
                    Button {
                        session.moveToSegment(index)
                    } label: {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .help("从第 \(index + 1) 段开始")
                    .accessibilityLabel("从第 \(index + 1) 段开始")
                }
            }
            .opacity(segmentOpacity(at: index))
            .onHover { isHovering in
                if isHovering {
                    hoveredSegmentIndex = index
                } else if hoveredSegmentIndex == index {
                    hoveredSegmentIndex = nil
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "从此段开始") {
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

    private var appearanceControl: some View {
        Button {
            isAppearancePopoverPresented.toggle()
        } label: {
            Label("显示设置", systemImage: "slider.horizontal.3")
        }
        .speechRailButton(.secondary)
        .accessibilityLabel("提词器显示设置")
        .help("调节字号、背景透明度、计时进度与全稿查阅")
        .popover(isPresented: $isAppearancePopoverPresented, arrowEdge: .bottom) {
            TeleprompterStageAppearancePopover(
                settings: settings,
                isBrowsingAll: $isBrowsingAll
            )
        }
    }

    private var controls: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button {
                session.moveToPrevious()
            } label: {
                Label("上一段", systemImage: "chevron.left")
            }
            .focused($focusedControl, equals: .previous)
            .disabled(session.currentSegmentIndex <= 0)
            .speechRailButton(.secondary)
            .help("上一段（← / ↑ / PageUp）")

            Button {
                session.moveToNext()
            } label: {
                Label("下一段", systemImage: "chevron.right")
            }
            .focused($focusedControl, equals: .next)
            .disabled(isLastSegment)
            .speechRailButton(.secondary)
            .help("下一段（空格 / → / ↓ / PageDown）")

            Button {
                handleVoiceAssist()
            } label: {
                Label(voiceAssistTitle, systemImage: voiceAssistIcon)
            }
            .focused($focusedControl, equals: .voice)
            .disabled(voiceAssistBusy)
            .speechRailButton(session.voiceAssistState == .following ? .secondary : .primary)
            .help(voiceAssistHelp)

            Spacer(minLength: 0)

            appearanceControl
                .focused($focusedControl, equals: .display)

            Button {
                handleEndOrClose()
            } label: {
                Label("关闭", systemImage: "xmark")
            }
            .focused($focusedControl, equals: .close)
            .speechRailButton(.destructive)
            .help("关闭提词器（Esc）")
        }
        .controlSize(.regular)
        .background {
            // Optional text/background shortcuts only. Stage navigation and
            // voice control are real controls plus application-menu commands.
            Group {
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
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var voiceAssistTitle: String {
        switch session.voiceAssistState {
        case .off:
            "开启语音跟随"
        case .starting:
            "正在开启…"
        case .following:
            "关闭语音跟随"
        case .stopping:
            "正在停止…"
        case .stopFailed:
            "重试停止"
        case .pausedByUser:
            "恢复语音跟随"
        case .unavailable:
            "重试语音跟随"
        }
    }

    private var voiceAssistIcon: String {
        switch session.voiceAssistState {
        case .following:
            "mic.slash"
        case .stopFailed:
            "exclamationmark.arrow.triangle.2.circlepath"
        default:
            "mic"
        }
    }

    private var voiceAssistBusy: Bool {
        session.voiceAssistState.isBusy
    }

    private var voiceAssistHelp: String {
        switch session.voiceAssistState {
        case .stopFailed(let reason):
            "停止未完成：\(reason)。请先重试停止，再开启新的跟随。"
        case .unavailable(let reason):
            "上次未开启：\(reason)。可手动继续，或重试语音跟随。"
        case .following:
            "关闭语音跟随并释放麦克风；当前阅读位置保留。"
        case .pausedByUser:
            "从当前段恢复语音跟随。"
        case .off:
            "从当前段开启语音跟随。"
        case .starting, .stopping:
            "正在处理麦克风与语音连接，请稍候。"
        }
    }

    private func handleVoiceAssist() {
        switch session.voiceAssistState {
        case .following:
            Task { await session.disableVoiceAssist() }
        case .stopFailed:
            Task { await session.retryStopVoiceAssist() }
        case .off, .pausedByUser, .unavailable:
            Task { await session.enableVoiceAssist() }
        case .starting, .stopping:
            break
        }
    }

    private func handleEndOrClose() {
        Task {
            await session.closeStage()
            close()
        }
    }

    private var isLastSegment: Bool {
        guard let count = session.activeVersion?.segments.count else { return true }
        return session.currentSegmentIndex >= count - 1
    }

    private var isFollowing: Bool {
        session.phase == .following || session.phase == .uncertain
    }

    private func formatClock(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var statusText: String {
        if let blocked = session.blocked { return blocked.title }
        if session.isResuming { return "正在准备语音跟随…" }
        switch session.voiceAssistState {
        case .starting:
            return "正在开启语音跟随…"
        case .following, .stopping:
            return session.hasHeardSpeech ? "语音跟随中" : "麦克风已就绪，可以开始朗读"
        case .stopFailed(let reason):
            return "停止未完成：\(reason)"
        case .pausedByUser:
            return "语音跟随已暂停，可手动阅读"
        case .unavailable:
            return "语音跟随不可用，可手动继续"
        case .off:
            return "手动提词"
        }
    }
}

@MainActor
private struct TeleprompterStageAppearancePopover: View {
    let settings: TeleprompterStageSettings
    @Binding var isBrowsingAll: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("显示设置")
                .font(SpeechRailDesignTokens.Typography.bodyMedium)
            TeleprompterStageFontControl(settings: settings)
            TeleprompterStageTransparencyControl(settings: settings)
            TeleprompterStageQuickPresetControl(settings: settings)
            Divider()
            Toggle(
                "始终显示控制",
                isOn: Binding(
                    get: { settings.alwaysShowControls },
                    set: { settings.alwaysShowControls = $0 }
                )
            )
            Toggle(
                "显示计时与进度",
                isOn: Binding(
                    get: { settings.showClockAndProgress },
                    set: { settings.showClockAndProgress = $0 }
                )
            )
            Toggle("查阅全稿", isOn: $isBrowsingAll)
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(width: SpeechRailDesignTokens.Teleprompter.stageAppearancePopoverWidth)
    }
}

@MainActor
private struct TeleprompterStageFontControl: View {
    let settings: TeleprompterStageSettings

    var body: some View {
        TeleprompterStageContinuousSliderRow(
            title: "字号",
            valueText: String(format: "%.1f pt", Double(settings.scriptPointSize)),
            value: Binding(get: { settings.fontScale }, set: { settings.fontScale = $0 }),
            range: SpeechRailDesignTokens.Teleprompter.stageMinimumFontScale...SpeechRailDesignTokens.Teleprompter.stageMaximumFontScale,
            accessibilityLabel: "提词卡字号",
            accessibilityValue: String(format: "%.1f 点", Double(settings.scriptPointSize)),
            helpText: "连续调节提词卡字号"
        )
    }
}

@MainActor
private struct TeleprompterStageTransparencyControl: View {
    let settings: TeleprompterStageSettings

    var body: some View {
        TeleprompterStageContinuousSliderRow(
            title: "背景透明度",
            valueText: TeleprompterStageTransparencyPresentation.valueLabel(
                for: settings.backgroundTransparency
            ),
            value: Binding(
                get: { settings.backgroundTransparency },
                set: { settings.backgroundTransparency = $0 }
            ),
            range: SpeechRailDesignTokens.Teleprompter.stageMinimumTransparency...SpeechRailDesignTokens.Teleprompter.stageMaximumTransparency,
            accessibilityLabel: "提词卡背景透明度",
            accessibilityValue: TeleprompterStageTransparencyPresentation.valueLabel(
                for: settings.backgroundTransparency
            ),
            helpText: "连续调节背景透光程度；读数是控制值，实际观感也受系统材质影响"
        )
    }
}

@MainActor
private struct TeleprompterStageQuickPresetControl: View {
    let settings: TeleprompterStageSettings

    var body: some View {
        HStack {
            Text("快速预设")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Spacer()
            Menu("选择") {
                Button("清晰 · 0% 透明") { settings.backgroundTransparency = 0 }
                Button("默认 · 28% 透明") { settings.backgroundTransparency = 0.28 }
                Button("透光 · 45% 透明") { settings.backgroundTransparency = 0.45 }
                Button("更透光 · 65% 透明") { settings.backgroundTransparency = 0.65 }
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("背景透明度快速预设")
        }
    }
}

private struct TeleprompterStageContinuousSliderRow: View {
    let title: String
    let valueText: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let accessibilityLabel: String
    let accessibilityValue: String
    let helpText: String

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                Spacer()
                Text(valueText)
                    .font(SpeechRailDesignTokens.Typography.technicalValue)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Slider(value: value, in: range)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(accessibilityValue)
                .help(helpText)
        }
    }
}
