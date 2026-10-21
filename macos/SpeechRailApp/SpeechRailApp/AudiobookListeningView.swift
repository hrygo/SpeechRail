import SwiftUI

/// T13：有声书沉浸听书视图（共享唯一文件播放器、48kHz 真实采样帧时长、±15s 跨片段跳转、0.5x–2.0x 倍速、“之前的版本”与“章节已更新”横幅提示）。
public struct AudiobookListeningView: View {
    @Environment(AppModel.self) private var appModel

    public init() {}

    private var workflow: AudiobookWorkflowModel {
        appModel.audiobookWorkflow
    }

    private var listening: AudiobookListeningController? {
        workflow.listeningController
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            AudiobookAudioVersionPicker(workflow: workflow)
            if workflow.isListeningToHistoricalAudio {
                Text("正在收听之前版本，正文随该版本显示。返回制作台可继续处理当前正文。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            if let notice = listening?.chapterUpdatedBannerMessage {
                StatusBanner(
                    kind: .standard,
                    tone: .healthy,
                    title: "章节已更新",
                    message: notice,
                    actionTitle: "知道了"
                ) {}
            }

            if listening?.canResumeInterruptedListening == true {
                StatusBanner(
                    kind: .standard,
                    tone: .attention,
                    title: "听书已暂停以进行试听",
                    message: "您刚才试听了角色或候选声音，听书位置已自动保存在原片段进度处。",
                    actionTitle: "继续听"
                ) {
                    Task { try? await listening?.resume() }
                }
            }

            if !workflow.hasListenableChapter {
                CardSurface {
                    SessionEmptyState(
                        systemImage: "headphones",
                        title: "还没有可收听的章节",
                        message: "先在制作台把至少一章生成音频，再回到听书模式逐章收听。已跳过的章节不会出现在可收听列表里。"
                    ) {
                        Button("去制作章节") {
                            workflow.surfaceMode = .workspace
                            workflow.workbenchTab = .production
                        }
                        .speechRailButton(.primary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                }
            } else {
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                    chapterOutlineColumn
                        .frame(width: SpeechRailDesignTokens.Layout.sessionListWidth)

                    followAlongTranscriptColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                transportBar
                    .frame(height: SpeechRailDesignTokens.Layout.audiobookTransportBarHeight)
            }
        }
    }

    // MARK: - Left Chapter Switcher

    private var chapterOutlineColumn: some View {
        SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                SessionPanelHead(
                    title: "可收听章节",
                    trailingDetail: "\(listenableChapters.count) 章"
                )
                SessionHairline()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        ForEach(listenableChapters) { chapter in
                            let isSelected = (workflow.listeningChapterID == chapter.id)
                            let hasCurrent = (chapter.currentChapterRevisionID != nil)
                            let hasPrevious = (chapter.previousChapterRevisionID != nil)

                            Button {
                                Task { await workflow.startListening(chapterID: chapter.id) }
                            } label: {
                                HStack {
                                    Text("#\(chapter.ordinal + 1)")
                                        .font(SpeechRailDesignTokens.Typography.technical)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                    Text(chapter.title)
                                        .font(SpeechRailDesignTokens.Typography.body)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                        .lineLimit(1)
                                    Spacer()
                                    if hasCurrent {
                                        StatusPill(tone: workflow.isListeningToHistoricalAudio ? .attention : .healthy, label: workflow.isListeningToHistoricalAudio ? "之前版本" : "当前版本")
                                    } else if hasPrevious {
                                        StatusPill(tone: .attention, label: "旧版音频")
                                    } else {
                                        StatusPill(tone: .neutral, label: "未制作")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
                                .background(isSelected ? SpeechRailDesignTokens.Color.rail.opacity(0.14) : Color.clear, in: SpeechRailDesignTokens.Corner.controlShape)
                                .contentShape(.interaction, Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!hasCurrent && !hasPrevious)
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.xs)
                }
            }
        }
    }

    // MARK: - Center Follow-Along Reader

    private var followAlongTranscriptColumn: some View {
        SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    SessionPanelHead(
                        title: currentChapterTitle,
                        trailingDetail: activeFragmentProgressLabel
                    )
                    if listening?.activePlayback?.isPreviousRevision == true {
                        StatusPill(tone: .attention, label: "正在收听：旧版音频")
                            .padding(.trailing, SpeechRailDesignTokens.Spacing.sm)
                    }
                }
                SessionHairline()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        ForEach(workflow.listeningTexts) { fragment in
                            let isActive = (listening?.activePlayback?.fragmentID == fragment.id)
                            let text = fragment.text

                            CardSurface {
                                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                        AudiobookVoiceTag(
                                            name: fragment.roleName,
                                            detail: isActive ? "正在朗读" : "片段 #\(fragment.ordinal + 1)"
                                        )
                                        if isActive {
                                            WaveformBars(
                                                pattern: SpeechRailDesignTokens.Waveform.resultBar,
                                                isPlaying: listening?.isPlaying == true
                                            )
                                            .frame(width: 48, height: 14)
                                        }
                                        Spacer()
                                        Button("重录本段") {
                                            Task {
                                                await listening?.pause()
                                                workflow.selectedFragmentID = fragment.id
                                                workflow.workbenchTab = .production
                                                workflow.surfaceMode = .workspace
                                            }
                                        }
                                        .speechRailButton(.quiet)
                                        .disabled(workflow.isListeningToHistoricalAudio)
                                        .help(workflow.isListeningToHistoricalAudio ? "之前版本保留原音频；请返回当前文本制作新版本。" : "返回制作工作台重新生成此段音频")
                                    }

                                    Text(text)
                                        .font(SpeechRailDesignTokens.Typography.body)
                                        .foregroundStyle(
                                            isActive
                                                ? SpeechRailDesignTokens.Color.ink
                                                : SpeechRailDesignTokens.Color.inkSecondary
                                        )
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
                            }
                            .overlay(
                                SpeechRailDesignTokens.Corner.containerShape
                                    .stroke(
                                        isActive ? SpeechRailDesignTokens.Color.rail : Color.clear,
                                        lineWidth: isActive ? 1 : 0
                                    )
                            )
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.md)
                }
            }
        }
    }

    // MARK: - Bottom Transport Bar (64pt Token Height)

    private var transportBar: some View {
        SessionPanel {
            HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                Button {
                    Task { try? await listening?.skip(seconds: -15) }
                } label: {
                    Label("快退 15 秒", systemImage: "gobackward.15")
                }
                .speechRailButton(.secondary)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .accessibilityLabel("后退 15 秒")
                .accessibilityIdentifier("audiobook-listening-skip-back-15")

                Button {
                    Task {
                        if listening?.isPlaying == true {
                            await listening?.pause()
                        } else if listening?.activePlayback != nil {
                            try? await listening?.resume()
                        } else {
                            await workflow.startListening()
                        }
                    }
                } label: {
                    Label(
                        listening?.isPlaying == true ? "暂停" : "继续听",
                        systemImage: listening?.isPlaying == true ? "pause.fill" : "play.fill"
                    )
                }
                .speechRailButton(.primary)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(listening?.isPlaying == true ? "暂停播放" : "开始播放")
                .accessibilityIdentifier("audiobook-listening-play-pause")

                Button {
                    Task { try? await listening?.skip(seconds: 15) }
                } label: {
                    Label("快进 15 秒", systemImage: "goforward.15")
                }
                .speechRailButton(.secondary)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .accessibilityLabel("前进 15 秒")
                .accessibilityIdentifier("audiobook-listening-skip-forward-15")

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    Text(timecodeSummary)
                        .font(SpeechRailDesignTokens.Typography.technical)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("自动保存收听进度，暂停或离开后可随时续听")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }

                Spacer()

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("收听倍速")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                    ForEach([Float(0.75), Float(1.0), Float(1.25), Float(1.5), Float(2.0)], id: \.self) { rate in
                        let isCurrent = abs((listening?.playbackRate ?? 1.0) - rate) < 0.01
                        Button(AudiobookDisplayFormat.playbackRate(rate)) {
                            Task { await listening?.setRate(rate) }
                        }
                        .speechRailButton(isCurrent ? .primary : .quiet)
                        .accessibilityLabel("收听倍速 \(AudiobookDisplayFormat.playbackRate(rate))")
                        .accessibilityValue(isCurrent ? "当前倍速" : "未选中")
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    }
                }

                Button("返回工作台") {
                    Task {
                        await workflow.leaveWorkshop()
                        workflow.surfaceMode = .workspace
                    }
                }
                .speechRailButton(.secondary)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listenableChapters: [AudiobookChapter] {
        workflow.exportChapters.filter { !$0.isSkipped }
    }

    private var currentChapterTitle: String {
        guard let chID = workflow.listeningChapterID,
              let chapter = workflow.exportChapters.first(where: { $0.id == chID })
        else {
            return "章节收听"
        }
        return chapter.title
    }

    private var activeFragmentProgressLabel: String {
        guard let active = listening?.activePlayback else {
            return "未开始播放"
        }
        return "片段 \(active.fragmentIndex + 1) / \(active.totalFragments)"
    }

    private var timecodeSummary: String {
        let elapsed = listening?.chapterElapsedSeconds ?? 0
        let total = listening?.chapterTotalDurationSeconds ?? 0
        return AudiobookDisplayFormat.timecode(elapsed) + " / " + AudiobookDisplayFormat.timecode(total)
    }
}
