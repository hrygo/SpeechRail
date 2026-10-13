import AppKit
import SwiftUI

// 会议助手页（`SESSIONS-SPEC` §6.2，2026-09-18 第五轮重构后的骨架）。
//
// 结构自下而上只有四块，四种状态共用：**页头 → 状态带 → 主区（转录 + 会议信息栏）
// → 贴底的内心 OS 抽屉**。原来的「左侧会议列表」被去掉了：会议**库**是记录库的事，
// 这一页要回答的是「这一场现在记到哪了」。
//
// 内心 OS 是**组件不是模式**：它默认收起成贴底的一行，随时可以展开，展开时转录仍在上面
// ——所以它不可能被画成一个独立版面（那正好与"边听边记"的用法相反）。
//
// 这一页按相位分段放在几个文件里，主文件只留 `@State`、`body` 与版面契约：
//   `MeetingViewStatusBar.swift`       状态带：相位标题、语气、来源与六条轴的事实行。
//   `MeetingViewSourceSetup.swift`     会前：来源、标题、开始会议，以及按相位分派主区。
//   `MeetingViewLiveTranscript.swift`  录制中：转录流、滚动测量与转录行的时间码。
//   `MeetingViewSpeakerLabeling.swift` 录制中打开的「标注说话人」面板。
//   `MeetingViewPostMeeting.swift`     会后：纪要 / 文字记录两个页签、导出与看旧记录的导航。
//   `MeetingViewInspector.swift`       会议信息栏（360pt）：这一场的事实、中断出口、纪要版本。
//   `MeetingViewRecordLibrary.swift`   空态下方的会议记录库快捷入口。
// 同一份 `@State` 被这些文件共用，所以跨文件复用的成员是 internal 而不是 private。

public struct MeetingView: View {
    @Environment(AppModel.self) var model
    @Environment(SessionCoordinator.self) var session
    @Environment(MeetingSession.self) var meeting
    @Environment(SessionPreferences.self) var preferences
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.openSettings) var openSettings
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State var usesMicrophone = true
    @State var systemApps: [SystemAudioApp] = []
    /// 会前标题（方案 §4.1：「保留**轻量标题**和来源摘要。标题可为空」）。
    ///
    /// **不写进偏好**：上一场叫什么不该替下一场预填——用户多半是在开新一场会，
    /// 带着上一场的名字开始，事后还得回来改。
    @State var titleDraft = ""
    @State var sourceCandidates: [SystemAudioApp] = []
    @State private var isInspectorCollapsed = false
    @FocusState private var inspectorToggleFocused: Bool
    @State private var autoCollapsedDueToWidth = false
    @State var isCheckingInput = false
    /// 会后：正文区顶部的 `纪要 / 转录` 分段。
    @State var postTab: PostTab = .minutes
    @State var selectedMinutesVersionID: String?
    @State private var confirmingFinish = false
    @State var recent: [SessionSummary] = []
    /// 完整会议知识库（MA-12）。这一段只快取最近几场，
    /// 「查看全部」才是完整分页列表——静默截断到 8 场会让人以为其余的没了（MC-52）。
    @State var showsKnowledgeLibrary = false
    @State var reviewRecord: SessionRecord?
    @State var reviewLines: [TranscriptLine] = []
    @State var reviewSpeakerNames: [String: String] = [:]
    @State var reviewMinutes: MinutesVersion?
    /// 采用哪一版时的冲突提示（MC-31）：两个窗口基于同一旧版改采用时，
    /// 后返回的那个不覆盖，改为提示刷新。
    @State var adoptConflictNotice: String?
    /// 录制中打开「标注说话人」面板（稿 `screenMeetingRecording` 表头那一颗）。
    @State var isLabelingSpeakers = false

    /// 空态里「想连电脑里的声音一起记」那一行可选项的展开态。
    @State var showsSourceOptions = false

    /// 当前纪要各条结论的核对结论（MA-21 审阅轴）。
    /// 没有依据可核的条目**不计入**——"没核过"不是"核过了"。
    @State var reviewVerdicts: [MinutesEvidenceValidator.Verdict] = []

    /// 空 final 留下的恢复材料（MA-02 / MC-11）。默认读库口径不返回它们，
    /// 所以要单独按 `includePartial: true` 取——用户提示里说了"已保留"，
    /// 就必须真能取回来。
    @State var recoveryLines: [TranscriptLine] = []

    /// 转录流的粘底状态（MA-10）：用户离开底部后不许被新句子拽走。
    @State var transcriptFollow = TranscriptFollowState()

    /// 内容底边在滚动坐标里的位置，用来算「离底部多远」。
    @State var transcriptBottomMarkerY: CGFloat = 0
    @State var transcriptViewportHeight: CGFloat = 0

    enum PostTab: String, CaseIterable, Identifiable {
        case minutes
        case transcript

        var id: String { rawValue }
        var title: String { self == .minutes ? "纪要" : "文字记录" }
    }

    public init() {}

    public var body: some View {
        // 页面本身固定在窗口视口内；实时转写与会后正文由各自内容面板滚动。
        // 动态来源列表也在展开后的来源面板内滚动，不能把整页撑高。
        PageScaffold(
            route: .meeting,
            layout: .fill(minimumHeight: 420)
        ) {
            VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
                statusBar
                if !meeting.saveRecoveryRecords.isEmpty {
                    TranscriptSaveRecoveryPanel(
                        records: meeting.saveRecoveryRecords,
                        preview: { meeting.unsavedTranscriptText(recordID: $0) },
                        retry: { await meeting.retryPendingSaves(recordID: $0) },
                        finishIncomplete: { await meeting.endIncompleteRecord($0) }
                    )
                }
                if meeting.phase == .processing, !meeting.minutes.isBusy,
                   let id = meeting.sessionID, let failure = meeting.lastFailure {
                    CardSurface {
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                            Text("这场会议尚未完成收尾")
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            Text(failure).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                if session.captureCompletionFailure(recordID: id) != nil {
                                    Button("按中断结束") { Task { await meeting.finishIncompleteCapture() } }
                                        .help("保留已保存的文字，按中断归档，不生成完整纪要")
                                } else {
                                    Button("重试结束并整理") { Task { await meeting.requestFinish() } }
                                }
                                exportMenu(title: "导出已保存文字…", helpText: "保留已保存的文字记录")
                            }
                        }
                        .padding(SpeechRailDesignTokens.Spacing.md)
                    }
                }
                if let blocked = meeting.blocked, !meeting.phase.isLive {
                    blockedCard(blocked)
                }
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
                        mainArea
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    if !isInspectorCollapsed {
                        inspector.speechRailInspectorColumn(alignment: .topLeading)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                InnerOSDrawer(session: meeting.innerOS, sessionID: meeting.sessionID)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } trailing: {
            // 页头动作逐态一屏（稿 `meetingShell` 的 `headActions` + 那一处共用的右栏收起）。
            // 空态这三件曾经一件都没有：设计稿的主按钮「开始会议」在界面上不存在，
            // 只能靠 ⌘⇧N 或菜单栏——同一页的受阻卡里反倒有一个「重试」能开始（2026-09-19 实测）。
            if meeting.phase == .idle, meeting.blocked == nil {
                SessionHeaderKeycap("⌘⇧N")
                PageActionButton(
                    title: "查看设置",
                    systemImage: "slider.horizontal.3",
                    helpText: "打开会话设置：谁在说话、纪要模型与默认对话方式"
                ) { openSettings() }
            } else if meeting.phase.isLive || meeting.phase == .interrupted {
                // 稿 `screenMeetingRecording` 的页头三件：`⌘⇧.` 键帽 / 静音麦克风 / 结束会议。
                // 键帽跟在它对应的那个按钮旁边说"这个动作还有键位"（§8：⌘⇧. = 结束当前会话；
                // 内心 OS 是 ⌘⇧I，与本页底部抽屉的那条链路同源）。
                // 静音只在这一处给，状态带是状态不是第二个控制区（`main.js:3394` 的同一条口径）。
                // 纯本机音频的会议**不摆**这个开关：没有麦克风可静，摆着就是个按了没反应的死按钮。
                SessionHeaderKeycap("⌘⇧.")
                if meeting.phase == .recording, meeting.usesMicrophone {
                    PageActionButton(
                        title: meeting.isMicrophoneMuted ? "取消静音" : "静音麦克风",
                        systemImage: meeting.isMicrophoneMuted ? "mic.slash.fill" : "mic.slash",
                        helpText: meeting.isMicrophoneMuted
                            ? "恢复把你这边的话送进文字记录；本机音频那一侧一直没停"
                            : "只是暂时不把你这边的声音送进去；录制、本机音频、文字记录都照旧"
                    ) {
                        meeting.toggleMicrophoneMute()
                    }
                }
                if meeting.phase == .interrupted {
                    // 中断板（稿 `screenClosureMeetingInterrupted`）：页头两件是「打开数据目录」与
                    // 「继续这一段」；结束这一场仍在中断卡里（那里它叫「结束并整理」，与卡片自己的
                    // 说明在同一处看），所以页头不再重复第三个按钮。
                    PageActionButton(
                        title: "打开数据目录",
                        systemImage: "folder",
                        helpText: "在访达里选中记录库文件；它一直在本机，随时可以复制走"
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([session.libraryURL])
                    }
                    PageActionButton(
                        title: "继续这一段",
                        systemImage: "play.fill",
                        helpText: "重新拿一次来源接着录：序号继续，断点期间没录上的就是没有"
                    ) {
                        Task { await meeting.continueAfterInterruption() }
                    }
                } else {
                    PageActionButton(
                        title: "结束会议",
                        systemImage: "stop.circle",
                        helpText: "结束这一场；文字记录会留下，接着开始整理纪要"
                    ) {
                        confirmingFinish = true
                    }
                }
            } else if meeting.minutes.isBusy {
                // 整理中（稿 `screenClosureMeetingProcessing`）：页头两件。
                // ①「先导出转录…」——纪要最长要跑十几分钟，等它出来才让导是不合理的：
                //   转录此时**已经封存**，导出读库、不等纪要（§20.3 的 J2 摩擦点）。
                // ②「停止整理」——停下来不丢东西，可以重新生成。
                exportMenu(title: "先导出文字记录…", helpText: "把已经存好的文字记录导出成文件；纪要还在生成，不等它")
                PageActionButton(
                    title: "停止整理",
                    systemImage: "stop.circle",
                    helpText: "停下这一次整理；文字记录已经存好，随时可以重新生成"
                ) {
                    meeting.minutes.stop()
                }
            } else if meeting.phase == .archived, meeting.sessionID != nil {
                // 已归档（稿 `screenMeetingMinutes` 的页头两件）。
                exportMenu(title: "导出…", helpText: "导出这一场：文字记录加已生成的纪要")
                PageActionButton(
                    title: "重新生成纪要",
                    systemImage: "arrow.clockwise",
                    helpText: "按现在的模型设置再整理一遍；旧版本都留着，不会覆盖"
                ) {
                    Task { await regenerateMinutes(for: pageSessionID) }
                }
            }
            // 右栏收起控件：会议页四个状态共用一处（稿 `meetingShell` 末行）。名字按右栏
            // 当时装着什么说——空态是「本次会议」，录起来才是「会议信息」。
            SessionPanelToggle(
                panelName: meeting.phase == .idle ? "本次会议" : "会议信息",
                isCollapsed: isInspectorCollapsed
            ) {
                setInspectorCollapsed(!isInspectorCollapsed, autoCollapsed: false)
            }
            .focused($inspectorToggleFocused)
        }
        .onChange(of: navigation.layoutTier, initial: true) { _, _ in
            syncInspectorWithLayoutContract(navigation.layoutContract)
        }
        .task {
            usesMicrophone = preferences.meetingUsesMicrophone
            let saved = preferences.meetingSystemAudioBundleIDs
            sourceCandidates = SystemAudioAppCatalog.runningApps(
                excluding: Bundle.main.bundleIdentifier
            )
            systemApps = sourceCandidates.filter { saved.contains($0.bundleID) }
            await reloadRecent()
            await reloadPostMeeting()
        }
        .onChange(of: meeting.phase) { _, _ in
            Task { await reloadPostMeeting() }
        }
        .onChange(of: meeting.sessionID) { _, newValue in
            // 换一场会就复位：上一场的回看位置不该带过来。
            transcriptFollow = transcriptFollow.reset()
            Task { await meeting.innerOS.bind(sessionID: newValue) }
        }
        .confirmationDialog(
            "结束这一场会议？",
            isPresented: $confirmingFinish,
            titleVisibility: .visible
        ) {
            Button("结束并整理") { Task { await meeting.requestFinish() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("麦克风同一时刻只能由一个会话使用。结束后文字记录会留着，接着开始整理纪要。")
        }
        .sheet(isPresented: $showsKnowledgeLibrary) {
            MeetingKnowledgeLibraryView(coordinator: session)
        }
        .sheet(isPresented: $isCheckingInput) { InputLevelSheet() }
        .sheet(isPresented: $isLabelingSpeakers) {
            SpeakerLabelingSheet(labeling: meeting.labeling, sessionID: meeting.sessionID) {
                isLabelingSpeakers = false
            }
        }
    }

    // MARK: - 版面契约（右栏收起）
    private func syncInspectorWithLayoutContract(_ contract: WindowLayoutContract) {
        guard contract.inspector == .collapsed else {
            if isInspectorCollapsed && autoCollapsedDueToWidth {
                setInspectorCollapsed(false, autoCollapsed: false)
            }
            return
        }

        if !isInspectorCollapsed {
            setInspectorCollapsed(true, autoCollapsed: true)
        }
    }

    private func setInspectorCollapsed(_ collapsed: Bool, autoCollapsed: Bool) {
        let update = {
            isInspectorCollapsed = collapsed
            autoCollapsedDueToWidth = autoCollapsed
            inspectorToggleFocused = true
        }

        if reduceMotion {
            update()
        } else {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.88), update)
        }
    }
}
