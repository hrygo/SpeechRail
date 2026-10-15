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

    // MARK: - Left Chapter Switcher

    private var chapterOutlineColumn: some View {
        SessionPanel {
            VStack(alignment: .leading, spacing: 0) {
                SessionPanelHead(
                    title: "可收听章节",
                    trailingDetail: "\(workflow.chapters.count) 章"
                )
                SessionHairline()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                        ForEach(workflow.chapters) { chapter in
                            let isSelected = (workflow.selectedChapterID == chapter.id)
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
                                        StatusPill(tone: .healthy, label: "当前版本")
                                    } else if hasPrevious {
                                        StatusPill(tone: .attention, label: "之前的版本")
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
                        StatusPill(tone: .attention, label: "正在收听：之前的版本")
                            .padding(.trailing, SpeechRailDesignTokens.Spacing.sm)
                    }
                }
                SessionHairline()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        ForEach(workflow.chapterFragments) { fragment in
                            let isActive = (listening?.activePlayback?.fragmentID == fragment.id)
                            let role = workflow.characters.first(where: { $0.id == fragment.roleID })
                            let text = workflow.fragmentTextsByID[fragment.id] ?? ""

                            CardSurface {
                                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                        AudiobookVoiceTag(
                                            name: role?.displayName ?? "角色",
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
                                        Button("返修此段") {
                                            Task {
                                                await listening?.pause()
                                                workflow.selectedFragmentID = fragment.id
                                                workflow.workbenchTab = .production
                                                workflow.surfaceMode = .workspace
                                            }
                                        }
                                        .speechRailButton(.quiet)
                                        .help("暂停听书并前往制作工作台重录或替换当前片段")
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
                .accessibilityIdentifier("audiobook-listening-play-pause")

                Button {
                    Task { try? await listening?.skip(seconds: 15) }
                } label: {
                    Label("快进 15 秒", systemImage: "goforward.15")
                }
                .speechRailButton(.secondary)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .accessibilityIdentifier("audiobook-listening-skip-forward-15")

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    Text(timecodeSummary)
                        .font(SpeechRailDesignTokens.Typography.technical)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("按 48 kHz 实际采样帧计时 · 自动每 5 秒与暂停/离开时保存书签")
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
                        Button(String(format: "%.2gx", rate)) {
                            Task { await listening?.setRate(rate) }
                        }
                        .speechRailButton(isCurrent ? .primary : .quiet)
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

    private var currentChapterTitle: String {
        guard let chID = workflow.selectedChapterID,
              let chapter = workflow.chapters.first(where: { $0.id == chID })
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
        let elapsed = Int(listening?.chapterElapsedSeconds ?? 0)
        let total = Int(listening?.chapterTotalDurationSeconds ?? 0)
        return String(
            format: "%02d:%02d / %02d:%02d",
            elapsed / 60,
            elapsed % 60,
            total / 60,
            total % 60
        )
    }
}
