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
    @Environment(\.openSettings) private var openSettings

    @State private var usesMicrophone = true
    @State private var systemApps: [SystemAudioApp] = []
    @State private var sourceCandidates: [SystemAudioApp] = []
    @State private var isInspectorCollapsed = false
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

    private enum PostTab: String, CaseIterable, Identifiable {
        case minutes
        case transcript

        var id: String { rawValue }
        var title: String { self == .minutes ? "纪要" : "转录" }
    }

    public init() {}

    public var body: some View {
        // 与语音助手页同一个封套口径：先吃满窗格，内容比窗格长时整页滚动。
        // 会议页的三张卡（音频来源 / 本机 App / 转录流）都会随运行中的 App 数与
        // 转录长度变长，`scrollable: false` 会把它们的理想高度直接报给分栏
        // （2026-09-19 实测：分栏被撑到 1355×9736、整窗全白，见 AssistantView.body 注）。
        PageScaffold(
            route: .meeting,
            minimumContentHeight: 420,
            growsWithContent: true
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
                    helpText: "打开会话设置：分人标签、纪要模型与默认对讲口径"
                ) { openSettings() }
                PageActionButton(
                    title: "开始会议",
                    systemImage: "mic",
                    helpText: "按现在选的音频来源开始；麦克风第一次会请求系统授权"
                ) { Task { await start() } }
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
                            ? "恢复把你这边的话送进转录；本机音频那一侧一直没停"
                            : "只是暂时不把你这边的声音送进去；录制、本机音频、转录都照旧"
                    ) {
                        meeting.toggleMicrophoneMute()
                    }
                }
                PageActionButton(
                    title: "结束会议",
                    systemImage: "stop.circle",
                    helpText: "结束这一场；转录会留下，接着开始整理纪要"
                ) {
                    confirmingFinish = true
                }
            } else if meeting.minutes.isBusy {
                // 整理中：这一态原本没有任何出口（纪要最长要跑十几分钟）。
                // 出口是「停止整理」——转录已经存好，停下来不丢东西，可以重新生成。
                PageActionButton(
                    title: "停止整理",
                    systemImage: "stop.circle",
                    helpText: "停下这一次整理；转录已经存好，随时可以重新生成"
                ) {
                    meeting.minutes.stop()
                }
            }
            // 右栏收起控件：会议页四个状态共用一处（稿 `meetingShell` 末行）。名字按右栏
            // 当时装着什么说——空态是「本次会议」，录起来才是「会议信息」。
            SessionPanelToggle(
                panelName: meeting.phase == .idle ? "本次会议" : "会议信息",
                isCollapsed: isInspectorCollapsed
            ) {
                isInspectorCollapsed.toggle()
            }
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
            Text("麦克风同一时刻只能由一个会话使用。结束后转录会留着，接着开始整理纪要。")
        }
        .sheet(isPresented: $isCheckingInput) { InputLevelSheet() }
    }

    // MARK: - 状态带

    private var statusBar: some View {
        SessionStatusBar(
            title: statusTitle,
            tone: statusTone,
            facts: statusFacts,
            elapsed: meeting.phase.isLive || meeting.phase == .processing ? session.elapsed : nil,
            level: meeting.phase.isLive ? meeting.level : nil
        ) {
            if meeting.phase.isLive {
                Button(meeting.isPaused ? "继续录" : "暂停一下") {
                    meeting.togglePause()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("只是暂时不再上行音频；会话、转录都在，麦克风也还归这一场")
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
        if meeting.labeling.labels.isEmpty {
            facts.append("还没有分人")
        } else {
            facts.append("\(meeting.labeling.labels.count) 位说话人")
        }
        if meeting.labeling.isEnabled { facts.append("分人已开") }
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

    /// 空态（§6.2 第一行那一条）：**音频来源必须先答**。勾多个来源就是自动合流，
    /// 所以这里没有第三个「混音」选项。
    private var emptyState: some View {
        VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
            SessionConclusionBand(
                tone: .healthy,
                title: "选好音频来源就能开始",
                message: "房间里的人走麦克风；这台 Mac 正在播放的声音（腾讯会议、QQ 音乐等）按 App 抓取。"
                    + "两边可以一起录，记录里会标出每一段来自哪一路。",
                hint: "本机音频不改变你听到的音量与内容，也不保存：原始音频和麦克风一样用完即弃；"
                    + "按 App 抓不需要装虚拟声卡。"
            ) {
                Button("说话人设置") { openSettings() }
                    .speechRailButton(.secondary)
            }

            // 空态只有**一条**右栏（页级 `inspector`，这一态渲染 `meetingInfoCard`）。
            // 2026-09-19 真机走查：这里曾另起一个 `HStack`，把 `meetingInfoCard` 再摆一次——
            // 于是「本次会议」在同一屏出现两遍，两个 360 栏加主区把宽 1105pt 的内容区挤成
            // 3 列（来源卡只剩 308pt），连稿里那句「本机音频：抓这个 App 正在播放的声音…」
            // 都被折成三行后截断。稿 `screenClosureMeetingSources` 里 split 只有
            // 「音频来源 + 本次会议」两栏。
            SessionPanel { sourcesCard }
            SessionPanel { blockedSourcesCard }
            libraryCard
        }
    }

    /// 音频来源：麦克风一行、本机音频按 App 若干行，最后一行是「自动混音」——
    /// 它是**行为**，不是用户要选的第三个选项（`AudioSourceCoordinator.swift:12`）。
    private var sourcesCard: some View {
        SessionPanel {
            SessionPanelHead(
                title: "音频来源",
                detail: "麦克风单选；本机音频按 App 多选。两路一起来时分别标注来源，"
                    + "转录里看得出哪句来自麦克风、哪句来自本机播放。"
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
                    detail: "多来源同时勾选时自动合流处理；转录中为每一句独立保留专属来源标签。"
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
                SessionKVRow("运行档位", profileRowText)
                SessionKVRow("音频来源", sourceSummary)
                SessionKVRow("说话人标签", preferences.meetingDiarizationEnabled ? "已开" : "关着")
                SessionKVRow("采集格式", "24 kHz → 内部 16 kHz")
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

    /// 运行档位那一行：读完档位才算「本机最强」，没读到就不替服务吹这一句。
    private var profileRowText: String {
        guard let profile = model.health?.profile else { return "未读取" }
        return "\(SpeechRailProfilePresentation.shortTitle(profile))（本机最强）"
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
                    title: "转录",
                    detail: meeting.labeling.isEnabled ? "点说话人标签就能改名，正文不会动" : nil
                ) { EmptyView() }
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
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
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
                StatusBanner(
                    kind: .standard,
                    tone: .attention,
                    title: "纪要没整理出来 · 转录已经存好了",
                    message: reason,
                    actionTitle: "重新生成"
                ) {
                    Task { await regenerateMinutes() }
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
                Text("这一场还没有转录。")
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
        guard let id = meeting.sessionID else { return }
        await meeting.minutes.generate(sessionID: id, configuration: preferences.minutesConfiguration)
        await meeting.minutes.reload(sessionID: id)
        // 重新生成之后看新的那一版：留着旧的选中，用户会以为"重新生成没生效"。
        selectedMinutesVersionID = nil
        postTab = .minutes
    }

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
            if meeting.phase == .archived {
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
    private var thisMeetingCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "本次会议") { EmptyView() }
                VStack(alignment: .leading, spacing: 0) {
                    inspectorRow("时长", SessionCoordinator.formatted(meeting.elapsed))
                    inspectorRow("转录", "\(meeting.storedLineCount) 段")
                    inspectorRow(
                        "说话人",
                        meeting.labeling.labels.isEmpty
                            ? "还没有"
                            : "\(meeting.labeling.labels.count) 位"
                    )
                    inspectorRow("音频来源", meeting.selection?.label ?? "还没选")
                    inspectorRow("分人", diarizationFact)
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

    private var diarizationFact: String {
        switch meeting.labeling.state {
        case .off: "关着"
        case .active: "已开"
        case .degraded: "停更了"
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
            "语音服务断开了。丢掉的音频就是没录上；已经定稿的转录都在。继续之后是新的一段。"
        case .sleep:
            "这台 Mac 睡过。醒来之后麦克风与本机音频都要重新拿一次，所以不会自动接着录。"
        case .sourceLost:
            // 这一类在库里对应两件事：**被 tap 的 App 退出**（自动接回、录制不打断，
            // 那种情况根本不会进中断态）与**采集流自己结束**（设备被拔、引擎停了）。
            // 能走到这张卡上的只有后者，所以以现场那句 note 为准；没有 note 时给一句
            // 不替它下结论的话——绝不写"已经自动接回"。
            meeting.interruptionNote ?? "音频来源停下来了。已经定稿的转录都在。"
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
    private var minutesVersionsCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                CardHead(title: "纪要版本") {
                    Button("重新生成") { Task { await regenerateMinutes() } }
                        .buttonStyle(.link)
                        .font(SpeechRailDesignTokens.Typography.caption)
                }
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
}
