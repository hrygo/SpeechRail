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

public struct MeetingView: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionCoordinator.self) private var session
    @Environment(MeetingSession.self) private var meeting
    @Environment(SessionPreferences.self) private var preferences
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var usesMicrophone = true
    @State private var systemApps: [SystemAudioApp] = []
    @State private var sourceCandidates: [SystemAudioApp] = []
    @State private var isInspectorCollapsed = false
    @FocusState private var inspectorToggleFocused: Bool
    @State private var autoCollapsedDueToWidth = false
    @State private var isCheckingInput = false
    /// 会后：正文区顶部的 `纪要 / 转录` 分段。
    @State private var postTab: PostTab = .minutes
    @State private var selectedMinutesVersionID: String?
    @State private var confirmingFinish = false
    @State private var recent: [SessionSummary] = []
    @State private var reviewRecord: SessionRecord?
    @State private var reviewLines: [TranscriptLine] = []
    @State private var reviewSpeakerNames: [String: String] = [:]
    @State private var reviewMinutes: MinutesVersion?
    /// 录制中打开「标注说话人」面板（稿 `screenMeetingRecording` 表头那一颗）。
    @State private var isLabelingSpeakers = false
    /// 空态里「想连电脑里的声音一起记」那一行可选项的展开态。
    @State private var showsSourceOptions = false

    private enum PostTab: String, CaseIterable, Identifiable {
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
        .sheet(isPresented: $isCheckingInput) { InputLevelSheet() }
        .sheet(isPresented: $isLabelingSpeakers) {
            SpeakerLabelingSheet(labeling: meeting.labeling, sessionID: meeting.sessionID) {
                isLabelingSpeakers = false
            }
        }
    }

    // MARK: - 状态带

    private var pageStatusPresentation: SessionPageStatusPresentation {
        return switch meeting.phase {
        case .idle:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        case .preparing:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        case .recording:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        case .interrupted:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        case .processing:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        case .archived:
            SessionPageStatusPresentation(
                title: statusTitle,
                tone: statusTone,
                facts: statusFacts
            )
        }
    }

    private var statusBar: some View {
        SessionStatusBar(
            title: pageStatusPresentation.title,
            tone: pageStatusPresentation.tone,
            facts: pageStatusPresentation.facts,
            elapsed: meeting.phase.isLive || meeting.phase == .processing ? session.elapsed : nil,
            level: meeting.phase.isLive ? meeting.level : nil
        ) {
            if meeting.phase.isLive {
                Button(meeting.isPaused ? "继续录" : "暂停一下") {
                    meeting.togglePause()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("只是暂时不把声音送进去；会话、文字记录都在，麦克风也还归这一场")
            }
        }
    }

    private var statusTitle: String {
        switch meeting.phase {
        case .idle:
            return meeting.blocked != nil ? "这一场没有开始" : "还没有开始会议"
        case .preparing: return "正在准备…"
        // 暂停与静音**不是**同一件事：暂停是整条上行都停（含本机音频），静音只关掉麦克风
        // 那一路。两句都成立时先说更强的那一句——"已暂停"已经蕴含"你这边的声音进不去"。
        case .recording:
            if meeting.isPaused { return "已暂停" }
            return meeting.isMicrophoneMuted ? "正在录音 · 麦克风已静音" : "正在录音"
        case .interrupted: return "录制中断"
        case .processing: return "正在整理会议…"
        case .archived: return "这一场已经结束"
        }
    }

    private var statusTone: StatusTone {
        switch meeting.phase {
        case .idle: meeting.blocked != nil ? .attention : .neutral
        case .preparing: .attention
        case .recording: meeting.isPaused ? .attention : .healthy
        case .interrupted: .attention
        case .processing: .attention
        case .archived: .healthy
        }
    }

    private var statusFacts: [String] {
        guard meeting.phase != .idle else {
            return meeting.selection.map { [$0.label] } ?? []
        }
        var facts: [String] = []
        if let selection = meeting.selection { facts.append("来源：\(selection.label)") }
        // 「谁在说话」这件事只说**一句**：有编号就说几位，没有就说这一场标不标。
        // 原来"还没有分人"与"分人已开"会同时出现（开着但一个编号都还没有时），
        // 两句摆在一起自相矛盾，也是用户点名的那个看不懂的词（2026-09-19）。
        if meeting.labeling.labels.isEmpty {
            facts.append(meeting.labeling.isEnabled ? "还没标出谁在说话" : "不标出谁在说话")
        } else {
            facts.append("\(meeting.labeling.labels.count) 位说话人")
        }
        facts.append("\(meeting.storedLineCount) 段已存好")
        if meeting.gapCount > 0 { facts.append("\(meeting.gapCount) 处补过静音") }
        // 标题已经说了"麦克风已静音"时不重复；只有暂停把标题占掉时才在这里补一句，
        // 否则"暂停 + 静音"两个开关叠在一起时，界面上会看不见后者的存在。
        if meeting.isMicrophoneMuted, meeting.isPaused { facts.append("麦克风已静音") }
        if meeting.reconnectedSources > 0 {
            facts.append("接回过 \(meeting.reconnectedSources) 次")
        }
        return facts
    }

    // MARK: - 受阻

    private func blockedCard(_ blocked: MeetingSession.BlockReason) -> some View {
        StatusBanner(
            kind: .standard,
            tone: .attention,
            title: blocked.title,
            message: blocked.detail,
            actionTitle: blocked.suggestsMicrophoneOnly ? "只用麦克风" : "重试"
        ) {
            if blocked.suggestsMicrophoneOnly {
                systemApps = []
                Task { await start() }
            } else {
                Task { await start() }
            }
        }
    }

    // MARK: - 主区

    @ViewBuilder
    private var mainArea: some View {
        switch meeting.phase {
        case .idle:
            emptyState
        case .archived:
            postMeeting
        default:
            liveTranscript
        }
    }

    /// 空态（§6.2 第一行那一条）：音频来源有**默认答案**（麦克风），不问也能开始。
    /// 勾多个来源就是自动合流，所以这里没有第三个「混音」选项。
    ///
    /// 2026-09-19 低门槛改造（用户反馈「门槛极高」）：**默认已经选好麦克风**，
    /// 结论条上只放一件事——「开始会议」；本机音频那 9 个 App 的清单折进一行可选项里，
    /// 想连电脑里的声音一起记的人展开就有全部选择，不想的人一眼都不用扫。
    private var emptyState: some View {
        VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
            SessionConclusionBand(
                tone: .healthy,
                title: "直接开始就能记",
                message: "默认从麦克风记房间里的声音。想连这台 Mac 正在放的声音（腾讯会议、"
                    + "QQ 音乐等）一起记，在下面展开勾一个 App 就行。",
                hint: "原始音频不留存，只有文字进记录库；本机音频不需要装虚拟声卡，"
                    + "也不改变你听到的音量和内容。"
            ) {
                Button("开始会议") { Task { await start() } }
                    .speechRailButton(.primary)
                    .help("按现在选的来源开始记；第一次用麦克风会请求系统授权")
            }

            // 空态只有**一条**右栏（页级 `inspector`，这一态渲染 `meetingInfoCard`）。
            // 2026-09-19 真机走查：这里曾另起一个 `HStack`，把 `meetingInfoCard` 再摆一次——
            // 于是「本次会议」在同一屏出现两遍，两个 360 栏加主区把宽 1105pt 的内容区挤成
            // 3 列（来源卡只剩 308pt），连稿里那句「本机音频：抓这个 App 正在播放的声音…」
            // 都被折成三行后截断。稿 `screenClosureMeetingSources` 里 split 只有
            // 「音频来源 + 本次会议」两栏。
            sourceOptions
            libraryCard
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// 「按什么来源记」是**可选项**，默认收起成一行。
    ///
    /// 理由（用户 2026-09-19：「门槛极高」）：默认就是麦克风，直接按「开始会议」即可开始。
    /// 本机音频那 9 个 App 的清单 + 两张「来源不可用时」的处置卡摆在首屏，
    /// 等于让人在按「开始」之前先读完一份设置手册。这里折成一行，展开才有全部选择。
    private var sourceOptions: some View {
        DisclosureGroup(isExpanded: $showsSourceOptions) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                    SessionPanel { sourcesCard }
                    SessionPanel { blockedSourcesCard }
                }
                .padding(.top, SpeechRailDesignTokens.Spacing.sm)
            }
            .frame(maxHeight: .infinity)
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("想连电脑里的声音一起记（可选）")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(sourceSummaryText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer(minLength: 0)
            }
        }
        .disclosureGroupStyle(SpeechRailDisclosureGroupStyle())
    }

    /// 收起时也要一眼看见「这一场到底在录什么」——所以摘要说来源名字，不说技术词。
    private var sourceSummaryText: String {
        var parts: [String] = []
        if usesMicrophone { parts.append("麦克风") }
        parts.append(contentsOf: systemApps.map(\.name))
        guard !parts.isEmpty else { return "现在没有选任何来源" }
        return "现在记：" + parts.joined(separator: " + ")
    }

    /// 音频来源：麦克风一行、本机音频按 App 若干行，最后一行是「自动混音」——
    /// 它是**行为**，不是用户要选的第三个选项（`AudioSourceCoordinator.swift:12`）。
    private var sourcesCard: some View {
        SessionPanel {
            SessionPanelHead(
                title: "音频来源",
                detail: "麦克风单选；本机音频按 App 多选。两路一起来时分别标注来源，"
                    + "这里如实说明：多选时两路合成一条流转录，来源只记「合流」——"
                    + "哪一句出在哪一路，这条链路上分不出来，也就不猜。"
            )
            SessionHairline()
            SessionCheckRow(
                tone: usesMicrophone ? .ready : .neutral,
                name: "麦克风",
                detail: "房间里的人。第一次开始时会请求授权；拒绝后这一行变受阻并给出出口。",
                onSelect: { usesMicrophone.toggle() }
            ) {
                StatusPill(tone: usesMicrophone ? .healthy : .neutral, label: usesMicrophone ? "已选" : "未选")
            }
            ForEach(sourceCandidates) { app in
                SessionHairline()
                SessionCheckRow(
                    tone: systemApps.contains(app) ? .ready : .neutral,
                    name: app.name,
                    detail: "本机音频：抓这个 App 正在播放的声音；它退出再启动会自动接回，不用重新选。",
                    onSelect: { binding(for: app).wrappedValue.toggle() }
                ) {
                    StatusPill(
                        tone: systemApps.contains(app) ? .healthy : .neutral,
                        label: systemApps.contains(app) ? "已选" : "未选"
                    )
                }
            }
            if !systemApps.isEmpty {
                SessionHairline()
                SessionCheckRow(
                    tone: .selected,
                    name: "自动混音",
                    detail: "多来源同时勾选时自动合流处理；记录行上的来源会如实记为「合流」。"
                ) {
                    StatusPill(tone: .healthy, label: "生效中")
                }
            }
            Spacer(minLength: 0)
            SessionHairline()
            CardFoot(note: "来源列表只列正在出声或最近出过声的 App；列表为空时先去那个 App 里放一声。") {
                Button("刷新列表") { refreshSources() }
                    .speechRailButton(.secondary)
            }
        }
    }

    /// 来源不可用的两种**当下就能处置**的情况。第三种（录制中来源中断）出现在录制页自己的
    /// 中断卡上——这里不摆一个按了不动的「知道了」。
    private var blockedSourcesCard: some View {
        SessionPanel {
            SessionPanelHead(
                title: "来源不可用时",
                detail: nil,
                trailingDetail: "各自一行，说明影响与唯一出口；不弹对话框、不静默留空。"
            )
            SessionHairline()
            SessionCheckRow(
                tone: .attention,
                name: "列表为空",
                detail: "没有正在出声的 App：先去那个 App 里放一声再回来选；麦克风这一路不受影响。"
            ) {
                Button("重新扫描") { refreshSources() }
                    .speechRailButton(.secondary)
            }
            SessionHairline()
            SessionCheckRow(
                tone: .attention,
                name: "未授权",
                detail: "本机音频：系统里没给「音频录制」权限时那一路会是空音轨——不如现在说清楚。"
            ) {
                Button("打开系统设置") { openAudioPrivacySettings() }
                    .speechRailButton(.secondary)
            }
        }
    }

    private var meetingInfoCard: some View {
        SessionPanel {
            SessionPanelHead(title: "本次会议", badge: "还没有开始")
            SessionHairline()
            VStack(alignment: .leading, spacing: 10) {
                // 「档位」这个词在**会话页**叫「识别精度」（`SESSIONS-SPEC` §16.3 判据 2
                // 的术语表）：这一页要说的是"你现在拿到的是哪一档质量"，不是"运行选择器"。
                // 那个选择器在设置与模型页，那边仍叫「档位」。
                SessionKVRow("识别精度", profileRowText)
                SessionKVRow("音频来源", sourceSummary)
                SessionKVRow("谁在说话", preferences.meetingDiarizationEnabled ? "已开" : "关着")
                SessionKVRow("保存位置", "记录库 · 长期保留")
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.md)
            Spacer(minLength: 0)
            SessionHairline()
            SessionPanelActions(alignment: .spread) {
                Button("检查输入电平") { isCheckingInput = true }
                    .speechRailButton(.secondary)
            }
        }
    }

    private func refreshSources() {
        sourceCandidates = SystemAudioAppCatalog.runningApps(
            excluding: Bundle.main.bundleIdentifier
        )
    }

    /// 只显示健康快照实际报告的活动档位，不由当前已加载档位推断质量排名。
    private var profileRowText: String {
        guard let profile = model.health?.profile else { return "未读取" }
        return SpeechRailProfilePresentation.shortTitle(profile)
    }

    private func openAudioPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private var sourceSummary: String {
        var parts: [String] = []
        if usesMicrophone { parts.append("麦克风") }
        if !systemApps.isEmpty { parts.append(systemApps.map(\.name).joined(separator: "、")) }
        return parts.isEmpty ? "还没有选来源" : "将录：" + parts.joined(separator: " + ")
    }

    private func binding(for app: SystemAudioApp) -> Binding<Bool> {
        Binding(
            get: { systemApps.contains(app) },
            set: { isOn in
                if isOn {
                    if !systemApps.contains(app) { systemApps.append(app) }
                } else {
                    systemApps.removeAll { $0 == app }
                }
            }
        )
    }

    private func start() async {
        preferences.meetingUsesMicrophone = usesMicrophone
        preferences.meetingSystemAudioBundleIDs = systemApps.map(\.bundleID)
        await meeting.start(
            selection: AudioSourceCoordinator.Selection(
                usesMicrophone: usesMicrophone,
                systemApps: systemApps
            )
        )
    }

    // MARK: - 录制中：转录流

    private var liveTranscript: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(
                    title: "实时记录",
                    detail: meeting.labeling.isEnabled ? "点名字那一列就能改名，正文不会动" : nil
                ) {
                    // 稿 `screenMeetingRecording` 表头那一颗（`main.js:3642`）：会中人工标注的
                    // 入口必须看得见。点行上的标签是**第一条路**（就地改名 / 合并），这颗按钮是
                    // 同一件事的**第二条路**——会中不想在长长的转录里找标签时，从这里进来一次改完。
                    // `labeling.state` 三种（没开 / 不支持 / 在用）面板自己会说话，所以按钮常在；
                    // 会话还没建起来时不给（那时没有可标注的行）。
                    if meeting.sessionID != nil {
                        Button {
                            isLabelingSpeakers = true
                        } label: {
                            Label("标注说话人", systemImage: "person.2")
                        }
                        .speechRailButton(.secondary)
                        .help("谁说了哪句：改显示名或合并；正文一个字不动")
                    }
                }
                if meeting.phase == .interrupted, let at = meeting.interruptedElapsed {
                    interruptionRow(at)
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                            if meeting.lines.isEmpty, meeting.partialText == nil {
                                Text("这一场还没有说到能定稿的句子。")
                                    .font(SpeechRailDesignTokens.Typography.callout)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                    .padding(.vertical, SpeechRailDesignTokens.Spacing.lg)
                            }
                            ForEach(meeting.lines) { line in
                                liveLine(line).id(line.id)
                            }
                            if let partial = meeting.partialText, !partial.isEmpty {
                                partialLine(partial)
                            }
                        }
                        .padding(SpeechRailDesignTokens.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: meeting.lines.count) { _, _ in
                        guard let last = meeting.lines.last else { return }
                        if reduceMotion {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        } else {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// 断点那一行：**时间码在断点处是跳的**（§6.5、D8），所以这里明写一句。
    private func interruptionRow(_ at: TimeInterval) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(StatusTone.attention.color)
                .accessibilityHidden(true)
            Text("\(SessionCoordinator.formatted(at)) 起中断 · 这一段没有文本")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)
    }

    private func liveLine(_ line: MeetingSession.Line) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(Self.timecode(line.start))
                .font(SpeechRailDesignTokens.Typography.technicalValue)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .frame(
                    width: SpeechRailDesignTokens.Layout.sessionTimecodeColumnWidth,
                    alignment: .leading
                )
            speakerColumn(label: line.speakerLabel)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(line.text)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if line.isDeviceSwitch {
                    Text("换设备")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 说话人列：**点它就能改名**（会中的轻量入口）。正文没有编辑入口——两者必须看出区别。
    @ViewBuilder
    private func speakerColumn(label: String?) -> some View {
        if let label {
            Menu {
                ForEach(meeting.labeling.labels.filter { $0 != label }, id: \.self) { other in
                    Button("与 \(other) 合并") {
                        Task { await meeting.merge(label: label, into: other) }
                    }
                }
                Button("标记为「我」") { Task { await meeting.markAsMe(label: label) } }
            } label: {
                SpeakerChip(
                    label: label,
                    displayName: meeting.labeling.displayNames[label]
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(
                width: SpeechRailDesignTokens.Layout.sessionSpeakerColumnWidth,
                alignment: .leading
            )
        } else {
            Color.clear.frame(
                width: SpeechRailDesignTokens.Layout.sessionSpeakerColumnWidth,
                height: 1
            )
        }
    }

    private func partialLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(Self.timecode(session.elapsed))
                .font(SpeechRailDesignTokens.Typography.technicalValue)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .frame(
                    width: SpeechRailDesignTokens.Layout.sessionTimecodeColumnWidth,
                    alignment: .leading
                )
            Text(text)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("正在识别…")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 会后

    private var postMeeting: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(title: postTab.title, detail: postDetail) {
                    Picker("", selection: $postTab) {
                        ForEach(PostTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ScrollView(.vertical) {
                    Group {
                        if let reviewRecord {
                            reviewBody(reviewRecord)
                        } else if postTab == .minutes {
                            minutesBody
                        } else {
                            transcriptBody
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var postDetail: String? {
        if reviewRecord != nil { return "在看以前的一场；点「回到这一场」回来" }
        guard let id = meeting.sessionID else { return nil }
        let count = reviewLines.count
        return "\(id.prefix(8)) · \(count) 段"
    }

    private var minutesBody: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            switch meeting.minutes.state {
            case .failed(let reason):
                // 出口按**失败的性质**给：配置还没填（或填错）时，「重新生成」按下去只会
                // 原样再失败一次——那一刻用户真正要做的是把对话模型填上，所以这里直接给
                // 设置那条路（用户 2026-09-19：一次性设置只在最需要它的时刻打扰）。
                if meeting.minutesNeedsSetup {
                    StatusBanner(
                        kind: .standard,
                        tone: .attention,
                        title: "纪要要用对话模型 · 文字记录已经存好了",
                        message: reason,
                        actionTitle: "去设置里填"
                    ) {
                        openSettings()
                    }
                } else {
                    StatusBanner(
                        kind: .standard,
                        tone: .attention,
                        title: "纪要没整理出来 · 文字记录已经存好了",
                        message: reason,
                        actionTitle: "重新生成"
                    ) {
                        Task { await regenerateMinutes() }
                    }
                }
            case .queued, .running:
                Text(meeting.minutes.state.title)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            default:
                EmptyView()
            }
            // 「在看哪一版」是一个**有落点的状态**：点了版本列表里的旧版就必须换正文，
            // 否则那一行按下去什么都不会发生（而这正是"旧版一直可看"的承诺）。
            if let viewing = selectedMinutesVersion, !viewing.isLatest {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text("正在看第 \(viewing.version) 版")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    StatusPill(tone: Self.tone(for: viewing.status), label: viewing.status.title)
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    Button("回到最新") { selectedMinutesVersionID = nil }
                        .buttonStyle(.link)
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
            }
            if let body = displayedMinutesBody, !body.isEmpty {
                Text(body)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .ready = meeting.minutes.state {
                Text("这一版是空的。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
    }

    /// 被点开的那一版。**选中即唯一来源**：找不到就是没选（比如换了会话，版本列表变了），
    /// 不把失效的 id 当成"还在看旧版"。
    private var selectedMinutesVersion: MinutesVersion? {
        guard let selectedMinutesVersionID else { return nil }
        return meeting.minutes.versions.first { $0.id == selectedMinutesVersionID }
    }

    /// 正文只在这一处决定：选了旧版就显示旧版，否则是最新版（`latestBody` 只作为
    /// 版本列表还没刷出来时的兜底）。
    private var displayedMinutesBody: String? {
        if let selectedMinutesVersion { return selectedMinutesVersion.body }
        if let latest = meeting.minutes.versions.first(where: \.isLatest), let body = latest.body {
            return body
        }
        return meeting.minutes.latestBody
    }

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            if reviewLines.isEmpty {
                Text("这一场还没有文字记录。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            ForEach(reviewLines) { line in
                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Text(Self.timecode(line.tStart ?? 0))
                        .font(SpeechRailDesignTokens.Typography.technicalValue)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .frame(
                            width: SpeechRailDesignTokens.Layout.sessionTimecodeColumnWidth,
                            alignment: .leading
                        )
                    if let label = line.speakerLabel {
                        Text(
                            SpeakerLabeling.chipText(
                                label: label,
                                displayName: reviewSpeakerNames[label]
                            )
                        )
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .frame(
                            width: SpeechRailDesignTokens.Layout.sessionSpeakerColumnWidth,
                            alignment: .leading
                        )
                    }
                    Text(line.text)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func reviewBody(_ record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(record.title ?? "这一场会议")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                StatusPill(tone: .neutral, label: record.endedReason.title)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                Button("回到这一场") { closeReview() }
                    .buttonStyle(.link)
                    .font(SpeechRailDesignTokens.Typography.caption)
            }
            if let reviewMinutes, let body = reviewMinutes.body {
                Text(body)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                transcriptBody
            }
        }
    }

    private func reloadPostMeeting() async {
        // 会后这一栏读的是**库里的行**，不是内存镜像：界面可能是从内存快照渲染的，
        // 而"重开 App 之后还在不在"只能由库回答（§11.2 的第二条）。
        guard let id = meeting.sessionID else { return }
        reviewLines = (try? await session.lines(sessionID: id)) ?? []
        reviewSpeakerNames = (try? await session.speakerNames(sessionID: id)) ?? [:]
        await meeting.minutes.reload(sessionID: id)
    }

    private func regenerateMinutes() async {
        await regenerateMinutes(for: meeting.sessionID)
    }

    /// 重新生成**指定那一场**的纪要（在看旧记录时页头那颗按钮作用在旧记录上）。
    /// 生成之后回到「纪要」页签看新版；选中态清掉，否则会以为"重新生成没生效"。
    private func regenerateMinutes(for sessionID: String?) async {
        guard let id = sessionID else { return }
        await meeting.minutes.generate(
            sessionID: id,
            resolvedConfiguration: preferences.resolvedLLMConfiguration(for: .minutes)
        )
        if reviewRecord?.id == id {
            reviewMinutes = try? await session.latestMinutes(sessionID: id)
            selectedMinutesVersionID = nil
            postTab = .minutes
            return
        }
        await meeting.minutes.reload(sessionID: id)
        selectedMinutesVersionID = nil
        postTab = .minutes
    }

    // MARK: - 导出（稿 M3「先导出转录…」与会后板「导出…」）

    /// 页头的导出动作。四种格式收进一个菜单：页头是低频动作的地方，四个格式不值得占四个槽位
    /// （与记录库页同一个口径）。默认格式排第一——会议是 Markdown。
    private func exportMenu(title: String, helpText: String) -> some View {
        PageActionsMenu(title: title, systemImage: "square.and.arrow.down", helpText: helpText) {
            ForEach(orderedFormats) { format in
                Button(format.title) {
                    exportCurrentSession(includeMinutes: true, as: format)
                }
            }
        }
    }

    private var orderedFormats: [SessionExportFormat] {
        let preferred = SessionExportFormat.preferred(for: .meeting)
        return [preferred] + SessionExportFormat.allCases.filter { $0 != preferred }
    }

    /// 导出**重新从库里读一遍**，不拿界面上正在显示的那份内存镜像：整理中也好、归档也好，
    /// 要带走的是库里定稿的内容（`includePartial == false`），与这一页此刻渲染到哪儿无关。
    ///
    /// `includeMinutes` 只有一处为真：**归档之后**才连纪要一起导。整理中那一颗叫「先导出转录」，
    /// 此时纪要还没生成——把它拼进去只会得到一个空章节，那正是"先导出转录"要避免的事。
    private func exportCurrentSession(includeMinutes: Bool, as format: SessionExportFormat) {
        guard let id = pageSessionID else { return }
        Task {
            guard let record = (try? await session.record(id: id)) ?? nil else { return }
            let rows = (try? await session.lines(sessionID: id)) ?? []
            let names = (try? await session.speakerNames(sessionID: id)) ?? [:]
            let minutes = includeMinutes ? (try? await session.latestMinutes(sessionID: id)) : nil
            SessionExportPanel.write(
                SessionExportPayload(
                    record: record,
                    lines: rows,
                    speakerNames: names,
                    minutes: minutes
                ),
                as: format
            )
        }
    }

    /// 页头动作到底作用在哪一场上。**在看旧记录时以旧记录为准**：这一页可以一边开着
    /// 上一场的记录（`reviewRecord`）一边保持 `phase == .archived`，若动作跟着
    /// `meeting.sessionID` 走，用户就会把「导出的那一场」和「屏幕上这一场」搞混——
    /// 一个导错对象的导出比没有导出更糟。
    private var pageSessionID: String? { reviewRecord?.id ?? meeting.sessionID }

    private func openRecord(_ summary: SessionSummary) async {
        guard let record = (try? await session.record(id: summary.id)) ?? nil else { return }
        reviewRecord = record
        reviewLines = (try? await session.lines(sessionID: summary.id)) ?? []
        reviewSpeakerNames = (try? await session.speakerNames(sessionID: summary.id)) ?? [:]
        reviewMinutes = try? await session.latestMinutes(sessionID: summary.id)
        selectedMinutesVersionID = nil
    }

    private func closeReview() {
        reviewRecord = nil
        reviewMinutes = nil
        Task { await reloadPostMeeting() }
    }

    private func reloadRecent() async {
        recent = (try? await session.listSummaries(kind: .meeting)) ?? []
    }

    // MARK: - 会议信息栏（360pt）

    private var inspector: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            if let reviewing = reviewRecord {
                // 在看**以前的一场**（从空态的「会议记录库」点进来的）时，右栏必须跟着换人：
                // 主区说的是旧记录，右栏若还挂着这一场的说话人与纪要版本，同一屏就有两个对象
                // ——和"导错一场"是同一类错误（2026-09-19 回读代码时发现，真机未验）。
                reviewInspectorCard(reviewing)
            } else if meeting.phase == .archived {
                if let id = meeting.sessionID {
                    SpeakerLabelingPanel(labeling: meeting.labeling, sessionID: id, isLive: false)
                }
                minutesVersionsCard
            } else if meeting.phase == .idle {
                // 稿 `screenClosureMeetingSources` 的右栏：「本次会议 · 还没有开始」+ 运行档位
                // 那一组事实 + 「检查输入电平」。时长/转录这些读数在还没开始时都是 0。
                meetingInfoCard
            } else {
                thisMeetingCard
                if meeting.phase == .interrupted { interruptionCard }
            }
        }
    }

    /// 「本次会议」：这一场现在的基本事实。**保存位置也写在这里**——
    /// 「记录只保存在这台 Mac 上」这句话要有一个能看见的落点（§6.3.2 的同一条口径）。
    /// 在看**以前的一场**时右栏换成它：这一栏说的永远是"你现在看的这一场"，
    /// 不是"后台还开着的那一场"。逐行读的都是这一场自己的读数（`reviewRecord` /
    /// `reviewLines` / `reviewSpeakerNames` / `reviewMinutes`），没有一处回读 `meeting`。
    private func reviewInspectorCard(_ record: SessionRecord) -> some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "这一场") {
                    Button("回到这一场") { closeReview() }
                        .buttonStyle(.link)
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
                Text(record.title ?? "这一场会议")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    inspectorRow(
                        "时间",
                        record.startedAt.formatted(date: .numeric, time: .shortened)
                    )
                    inspectorRow("文字记录", "\(reviewLines.count) 段")
                    inspectorRow(
                        "说话人",
                        reviewSpeakerNames.isEmpty ? "还没有" : "\(reviewSpeakerNames.count) 位"
                    )
                    inspectorRow("结束方式", record.endedReason.title)
                    inspectorRow("音频来源", record.audioSource.title)
                    inspectorRow("纪要", reviewMinutesVersionFact)
                    inspectorRow("保存位置", session.libraryURL.lastPathComponent)
                }
                Text("这一栏说的是这一场当时的样子：说话人名与纪要都按当时记录的原样显示。改名与合并要在那一场刚结束、这一页还停在这一场时做。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SpeechRailDesignTokens.Spacing.micro)
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    /// 在看的那一场有没有纪要、是哪一版（只有一版时不必说"第 1 版"）。
    private var reviewMinutesVersionFact: String {
        guard let reviewMinutes else { return "还没有" }
        return reviewMinutes.version > 1 ? "第 \(reviewMinutes.version) 版" : "有"
    }

    private var thisMeetingCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "本次会议") { EmptyView() }
                VStack(alignment: .leading, spacing: 0) {
                    inspectorRow("时长", SessionCoordinator.formatted(meeting.elapsed))
                    inspectorRow("文字记录", "\(meeting.storedLineCount) 段")
                    inspectorRow(
                        "说话人",
                        meeting.labeling.labels.isEmpty
                            ? "还没有"
                            : "\(meeting.labeling.labels.count) 位"
                    )
                    inspectorRow("音频来源", meeting.selection?.label ?? "还没选")
                    inspectorRow("说话人", diarizationFact)
                    inspectorRow("整理", meeting.minutes.state.title)
                    inspectorRow("保存位置", session.libraryURL.lastPathComponent)
                }
                if let failure = meeting.lastFailure {
                    Text(failure)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SpeechRailDesignTokens.Spacing.micro)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    /// 右栏那一行说的也是人话：不出现「分人」这类行话（用户 2026-09-19）。
    private var diarizationFact: String {
        switch meeting.labeling.state {
        case .off: "不标"
        case .active: "会标出"
        case .degraded: "中途停了"
        case .unavailable: "这一档不支持"
        }
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
        }
        .labeledContentStyle(SpeechRailInspectorLabeledContentStyle())
    }

    /// 中断时右栏给两个出口（§6.2 的中断行）。四类断法的处置写在下方的表里——
    /// 用户不需要记住它们，但需要知道"哪一种会自己接回来"。
    private var interruptionCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                CardHead(title: meeting.interruption?.title ?? "录制中断") { EmptyView() }
                Text(interruptionDetail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button("继续这一段") { Task { await meeting.continueAfterInterruption() } }
                        .buttonStyle(.borderedProminent)
                    Button("结束并整理") { Task { await meeting.requestFinish() } }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
                Divider()
                Text("四种断法")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                ForEach(Self.interruptionNotes, id: \.0) { note in
                    Text("\(note.0)：\(note.1)")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private var interruptionDetail: String {
        switch meeting.interruption {
        case .serviceLost:
            "语音服务断开了。丢掉的音频就是没录上；已经定稿的文字记录都在。继续之后是新的一段。"
        case .sleep:
            "这台 Mac 睡过。醒来之后麦克风与本机音频都要重新拿一次，所以不会自动接着录。"
        case .sourceLost:
            // 这一类在库里对应两件事：**被 tap 的 App 退出**（自动接回、录制不打断，
            // 那种情况根本不会进中断态）与**采集流自己结束**（设备被拔、引擎停了）。
            // 能走到这张卡上的只有后者，所以以现场那句 note 为准；没有 note 时给一句
            // 不替它下结论的话——绝不写"已经自动接回"。
            meeting.interruptionNote ?? "音频来源停下来了。已经定稿的文字记录都在。"
        case .unexpectedExit:
            "上一次没有正常结束。这一段已经封存，可以回看、导出。"
        case .none:
            "这一段停在了断点上。"
        }
    }

    private static let interruptionNotes: [(String, String)] = [
        ("服务断开", "停收声；正文保留。继续 = 新一段。"),
        ("系统睡眠", "醒来即中断态；不自动续。"),
        ("来源 App 退出", "会自动接回；只记一条区间，不打断录制。"),
        ("设备被拔 / 引擎停了", "采集流结束；要人决定继续还是结束。"),
        ("App 意外退出", "下次启动把上一场封存，可以回看、导出。")
    ]

    /// 纪要版本：**重新生成只新增版本**，旧版一直可看可导出（§5.8）。
    ///
    /// 这张卡**只列版本**：动作「重新生成纪要」在页头（稿 `screenMeetingMinutes` 的页头两件之一），
    /// 卡片里再放一颗就是同一个动作在一屏里画两遍（§17 / §19 的去重口径）。页头还有一处好处：
    /// 右栏可以收起，页面动作不会跟着被收起。
    private var minutesVersionsCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "纪要版本") { EmptyView() }
                if meeting.minutes.versions.isEmpty {
                    Text("这一场还没有生成过纪要。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                ForEach(meeting.minutes.versions) { version in
                    Button {
                        // 点一行 = 「看这一版」：换正文，并且把分段切回纪要
                        // ——在「转录」页签上点版本号却什么都没变，和没接线是一回事。
                        selectedMinutesVersionID = version.id
                        postTab = .minutes
                    } label: {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text(version.isLatest ? "最新 · 第 \(version.version) 版" : "第 \(version.version) 版")
                                .font(SpeechRailDesignTokens.Typography.callout)
                            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                            StatusPill(tone: Self.tone(for: version.status), label: version.status.title)
                        }
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.hairline)
                        .contentShape(Rectangle())
                        .background(
                            // 选中行与"正在看的那一版"必须一致：`selectedMinutesVersion` 为空时
                            // 实际在看最新版，所以最新那一行也是选中的。
                            (selectedMinutesVersionID ?? latestVersionID) == version.id
                                ? SpeechRailDesignTokens.Surface.selectedFill
                                : Color.clear,
                            in: SpeechRailDesignTokens.Corner.nestedShape
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(
                        (selectedMinutesVersionID ?? latestVersionID) == version.id ? "正在查看" : "未选中"
                    )
                    .speechRailPointerCursor()
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private var latestVersionID: String? {
        meeting.minutes.versions.first(where: \.isLatest)?.id
    }

    private static func tone(for status: MinutesStatus) -> StatusTone {
        switch status {
        case .ready: .healthy
        case .failed: .attention
        default: .neutral
        }
    }

    // MARK: - 记录库（空态下方那一段：会议**库**在记录库里，不在这一页的主区）

    private var libraryCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "会议记录库") { EmptyView() }
                if recent.isEmpty {
                    Text("还没有会议记录。结束一场之后，它会出现在这里。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(recent.prefix(8)) { summary in
                    Button {
                        Task { await openRecord(summary) }
                    } label: {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.hairline) {
                                Text(summary.record.title ?? "这一场会议")
                                    .font(SpeechRailDesignTokens.Typography.callout)
                                    .lineLimit(1)
                                Text(
                                    "\(summary.record.startedAt.formatted(date: .numeric, time: .shortened))"
                                        + " · \(summary.lineCount) 段"
                                        + (summary.speakerCount > 0 ? " · \(summary.speakerCount) 位说话人" : "")
                                )
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                            }
                            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                            if summary.openInterruption != nil {
                                StatusPill(tone: .attention, label: "有中断")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .speechRailPointerCursor()
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

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

// MARK: - 录制中的「标注说话人」面板

/// 稿 `screenMeetingRecording` 表头那颗按钮落成的面板：录制中也能打开，边走边改。
///
/// 它**不是**第二个实现：打开的就是会后右栏那块 `SpeakerLabelingPanel`，只是 `isLive` 为真
/// （文案从"说话人"变成"标注说话人"，并且说清"改的是归属，正文不动"）。
/// 单独一个 sheet，是因为录制中主区和右栏都已经被转录与会议占满——把这块内容塞进任何一栏
/// 都会挤掉正在看的转录。
struct SpeakerLabelingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let labeling: SpeakerLabeling
    let sessionID: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.hairline) {
                    Text("标注说话人")
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    Text("改的是说话人的名字与归属，记录正文一个字都不动。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
                Button("完成") { close() }
                    .keyboardShortcut(.defaultAction)
            }
            if let sessionID {
                ScrollView(.vertical) {
                    SpeakerLabelingPanel(labeling: labeling, sessionID: sessionID, isLive: true)
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.gutter)
        .frame(width: 460, height: 520, alignment: .topLeading)
    }

    private func close() {
        onClose()
        dismiss()
    }
}
