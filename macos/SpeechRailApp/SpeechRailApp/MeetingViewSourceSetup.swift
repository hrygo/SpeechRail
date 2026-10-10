import AppKit
import SwiftUI

// `MeetingView` 的会前实现：来源选择、标题、开始会议，以及按相位分派主区。
// 纯搬移自主文件；跨文件共用的是主文件里的 `@State` 与 `body` 调用的入口。

extension MeetingView {
    // MARK: - 受阻

    func blockedCard(_ blocked: MeetingSession.BlockReason) -> some View {
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
    var mainArea: some View {
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
            titleField
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

    var meetingInfoCard: some View {
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
        guard let selection = model.health?.selection else { return "未读取" }
        return SpeechRailProfilePresentation.shortTitle(selection.asrSpec)
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

    /// 会前标题。**一个输入框，不是一张表单**——
    /// §4.1 写得很直接：「不要为了归档要求用户先完成复杂表单」。
    ///
    /// 留在 `@State` 里而不是绑定到会话：启动失败之后它**一个字都不该丢**
    /// （MC-04）。失败往往还发生在同一台机器、同一个占着麦克风的应用上，
    /// 让用户重打一遍他没有能力消除的那个问题，是白添摩擦。
    private var titleField: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("标题")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("可以不填，之后在知识库里改也行", text: $titleDraft)
                .textFieldStyle(.plain)
                .accessibilityLabel("这场会议的标题，可以留空")
            Text("可以不填")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .speechRailSingleLineInput(.regular)
    }

    private func start() async {
        preferences.meetingUsesMicrophone = usesMicrophone
        preferences.meetingSystemAudioBundleIDs = systemApps.map(\.bundleID)
        await meeting.start(
            selection: MeetingAudioSelection(
                usesMicrophone: usesMicrophone,
                systemApps: systemApps.map { MeetingAudioApp(bundleID: $0.bundleID, name: $0.name) }
            ),
            title: titleDraft
        )
    }
}
