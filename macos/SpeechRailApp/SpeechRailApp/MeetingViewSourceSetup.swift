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
        if reviewRecord != nil {
            postMeeting
        } else {
            switch meeting.phase {
            case .idle:
                emptyState
            case .archived, .processing:
                postMeeting
            default:
                liveTranscript
            }
        }
    }

    /// 空态（§6.2 第一行那一条）：音频来源有**默认答案**（麦克风），不问也能开始。
    /// 勾多个来源就是自动合流，所以这里没有第三个「混音」选项。
    ///
    /// 2026-09-19 低门槛改造（用户反馈「门槛极高」）：**默认已经选好麦克风**，
    /// 结论条上只放一件事——「开始会议」；本机音频那 9 个 App 的清单折进一行可选项里，
    /// 想连电脑里的声音一起记的人展开就有全部选择，不想的人一眼都不用扫。
    /// 2026-10-20 布局与间距优化：将「会议主题」与「音频拾音环境」收敛为紧凑的会前配置面板，
    /// 限制音源展开区的最大高度，把充足的纵向视口留给下方的「会议记录库」。
    /// 空态（首屏）：一体化会议发起控制台（Launcher），整合主题输入、主行动点、音源与发言人快速配置及会议记录库。
    private var emptyState: some View {
        VStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            launcherCard
            libraryCard
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// 一体化会前启动台：统一标题输入、唯一开始主按钮、横向拾音与发言人配置栏。
    private var launcherCard: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                // 卡片顶栏：明确意图 + 唯一的 Primary CTA
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Image(systemName: "waveform.badge.mic")
                            .font(SpeechRailDesignTokens.Typography.sectionTitle)
                            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                            Text("快速发起会议")
                                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                            Text("边开会边记 · 角色分离 · 自动合流 · 仅存本机")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                    }
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.md)

                    Button {
                        Task { await start() }
                    } label: {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                            Image(systemName: "mic.fill")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                            Text("开始会议")
                                .font(SpeechRailDesignTokens.Typography.calloutMedium)
                            Text("⌘⇧N")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.rail.opacity(0.85))
                        }
                    }
                    .speechRailButton(.primary)
                    .disabled(meeting.minutes.isBusy)
                    .help("按当前所选音源开始录制（快捷键 ⌘⇧N）")
                }

                if meeting.minutes.isBusy {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("上一场纪要正在整理，完成后可开始新会议。")
                            .font(SpeechRailDesignTokens.Typography.callout)
                        Spacer(minLength: 0)
                        Button("停止整理") { meeting.minutes.stop() }
                            .buttonStyle(.bordered)
                    }
                }

                // 核心主题输入槽
                titleField

                // 快捷参数控制栏（横向排布）
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    audioSourceControls
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    speakerCapacityControls
                }

                // 应用音频抽屉（折叠/展开）
                if showsSourceOptions {
                    sourceOptionsDrawer
                }

                // 底部轻量安全与隐私背书
                SessionHairline()
                privacyTrustFooter
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
        }
    }

    /// 音频来源快捷胶囊（麦克风开关 + 应用音频展开）
    private var audioSourceControls: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Button {
                usesMicrophone.toggle()
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: usesMicrophone ? "mic.fill" : "mic.slash")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(usesMicrophone ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.inkTertiary)
                    Text("麦克风")
                        .font(SpeechRailDesignTokens.Typography.calloutMedium)
                        .foregroundStyle(usesMicrophone ? SpeechRailDesignTokens.Color.ink : SpeechRailDesignTokens.Color.inkSecondary)
                    Circle()
                        .fill(usesMicrophone ? SpeechRailDesignTokens.Color.ready : SpeechRailDesignTokens.Color.inkTertiary)
                        .frame(
                            width: SpeechRailDesignTokens.Icon.liveIndicatorDotSize,
                            height: SpeechRailDesignTokens.Icon.liveIndicatorDotSize
                        )
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.compact)
                .background(usesMicrophone ? SpeechRailDesignTokens.Color.rail.opacity(0.12) : SpeechRailDesignTokens.Color.recessedField)
                .clipShape(SpeechRailDesignTokens.Corner.controlShape)
                .overlay {
                    SpeechRailDesignTokens.Corner.controlShape
                        .stroke(usesMicrophone ? SpeechRailDesignTokens.Color.rail.opacity(0.3) : SpeechRailDesignTokens.Surface.border, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .speechRailPointerCursor()
            .help(usesMicrophone ? "已开启麦克风录制（点击可关闭）" : "麦克风已关闭（点击开启）")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsSourceOptions.toggle()
                }
            } label: {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Image(systemName: "macbook.and.iphone")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(!systemApps.isEmpty ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.inkSecondary)
                    Text(systemApps.isEmpty ? "录制应用声音…" : "已选 \(systemApps.count) 个应用声音")
                        .font(SpeechRailDesignTokens.Typography.calloutMedium)
                        .foregroundStyle(!systemApps.isEmpty ? SpeechRailDesignTokens.Color.ink : SpeechRailDesignTokens.Color.inkSecondary)
                    Image(systemName: showsSourceOptions ? "chevron.up" : "chevron.down")
                        .font(SpeechRailDesignTokens.Typography.chipIcon)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.compact)
                .background(!systemApps.isEmpty ? SpeechRailDesignTokens.Color.rail.opacity(0.12) : SpeechRailDesignTokens.Color.recessedField)
                .clipShape(SpeechRailDesignTokens.Corner.controlShape)
                .overlay {
                    SpeechRailDesignTokens.Corner.controlShape
                        .stroke(!systemApps.isEmpty ? SpeechRailDesignTokens.Color.rail.opacity(0.3) : SpeechRailDesignTokens.Surface.border, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .speechRailPointerCursor()
            .help("勾选正在发声的 App（如腾讯会议、音乐等）进行自动混音录制")
        }
    }

    /// 发言人区分容量配置胶囊
    private var speakerCapacityControls: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            Image(systemName: "person.2.fill")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(preferences.meetingDiarizationEnabled ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.inkTertiary)
            Text("发言人:")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Picker("发言人", selection: $expectedSpeakerCount) {
                ForEach(MeetingExpectedSpeakerCount.allCases) { count in
                    Text(count.title).tag(count)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(!preferences.meetingDiarizationEnabled)
            .help(!preferences.meetingDiarizationEnabled
                ? "在设置 → 会话开启「会议显示说话人」后生效"
                : expectedSpeakerCount == .moreThanFour
                ? "最多区分 4 位说话人，其余或不确定的发言标为未识别；文字照常保留"
                : "选择人数后，超出或不确定的发言会标为未识别；文字照常保留")
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        .background(SpeechRailDesignTokens.Color.recessedField)
        .clipShape(SpeechRailDesignTokens.Corner.controlShape)
        .overlay {
            SpeechRailDesignTokens.Corner.controlShape
                .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: 1)
        }
    }

    /// 展开的应用音频抽屉：精炼说明 + 原生图标 App 列表
    private var sourceOptionsDrawer: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "info.circle")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                Text("勾选正在播放声音的 App，将与麦克风自动合流识别；App 退出或重启会自动接回。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer(minLength: 0)
                Button {
                    refreshSources()
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                        Image(systemName: "arrow.clockwise")
                            .font(SpeechRailDesignTokens.Typography.caption)
                        Text("重新扫描")
                            .font(SpeechRailDesignTokens.Typography.caption)
                    }
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                }
                .buttonStyle(.plain)
                .speechRailPointerCursor()
                .help("重新检测正在运行的音频应用程序")
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
            .padding(.top, SpeechRailDesignTokens.Spacing.micro)

            if sourceCandidates.isEmpty {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Image(systemName: "waveform.slash")
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                        Text("未检测到正在出声的普通应用程序")
                            .font(SpeechRailDesignTokens.Typography.calloutMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Text("请先启动会议或音乐软件并播放声音，然后点击右上角「重新扫描」。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    Spacer()
                    Button("打开系统设置…") { openAudioPrivacySettings() }
                        .speechRailButton(.secondary)
                }
                .padding(SpeechRailDesignTokens.Spacing.md)
                .background(SpeechRailDesignTokens.Color.recessedField)
                .clipShape(SpeechRailDesignTokens.Corner.controlShape)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        ForEach(sourceCandidates) { app in
                            appAudioRow(app)
                        }
                    }
                    .padding(SpeechRailDesignTokens.Spacing.micro)
                }
                .frame(maxHeight: SpeechRailDesignTokens.Layout.meetingSourceOptionsMaxHeight)
                .background(SpeechRailDesignTokens.Color.recessedField)
                .clipShape(SpeechRailDesignTokens.Corner.controlShape)
                .overlay {
                    SpeechRailDesignTokens.Corner.controlShape
                        .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: 1)
                }
            }
        }
        .padding(.top, SpeechRailDesignTokens.Spacing.xs)
    }

    private func appAudioRow(_ app: SystemAudioApp) -> some View {
        let isSelected = systemApps.contains(app)
        return Button {
            binding(for: app).wrappedValue.toggle()
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                appIconView(for: app)
                    .frame(
                        width: SpeechRailDesignTokens.Layout.badgeCompactSize,
                        height: SpeechRailDesignTokens.Layout.badgeCompactSize
                    )

                Text(app.name)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)

                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

                if isSelected {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "checkmark")
                            .font(SpeechRailDesignTokens.Typography.chipIcon)
                        Text("已选录制")
                            .font(SpeechRailDesignTokens.Typography.captionMedium)
                    }
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.tiny)
                    .background(SpeechRailDesignTokens.Color.rail.opacity(0.12))
                    .clipShape(Capsule())
                } else {
                    Text("未选")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.tiny)
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.compact)
            .contentShape(Rectangle())
            .background(isSelected ? SpeechRailDesignTokens.Color.field.opacity(0.6) : Color.clear)
            .clipShape(SpeechRailDesignTokens.Corner.controlShape)
        }
        .buttonStyle(.plain)
        .speechRailPointerCursor()
    }

    private func appIconView(for app: SystemAudioApp) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return AnyView(
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            )
        } else {
            return AnyView(
                Image(systemName: "app.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            )
        }
    }

    /// 底部轻量安全与隐私背书
    private var privacyTrustFooter: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "lock.shield")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                Text("全离线安全处理，文字仅保存在本机")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Text("·")
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "waveform")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                Text("无需虚拟声卡，原始音频不存盘")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "sparkles")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                Text("多路音源自动合流")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
    }

    var meetingInfoCard: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            CardSurface {
                VStack(alignment: .leading, spacing: 0) {
                    CardHead(
                        title: "本次会议",
                        detail: "会前就绪概览"
                    ) {
                        StatusPill(
                            tone: (usesMicrophone || !systemApps.isEmpty) ? .healthy : .attention,
                            label: (usesMicrophone || !systemApps.isEmpty) ? "已就绪" : "待配置"
                        )
                    }
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.top, SpeechRailDesignTokens.Spacing.md)
                    .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)

                    SessionHairline()

                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        SessionKVRow("识别精度", profileRowText)
                        SessionKVRow("音频来源", sourceSummary)
                        SessionKVRow("发言人区分", preferences.meetingDiarizationEnabled
                            ? expectedSpeakerCount.title
                            : "未开启")
                        SessionKVRow("纪要整理", preferences.isLLMConfigured(for: .minutes) ? "结束后自动生成" : "未配置模型（仅存文字）")
                        SessionKVRow("数据存储", "SQLite 本地库 · 长期保存")
                    }
                    .padding(SpeechRailDesignTokens.Spacing.md)
                }
            }

            CardSurface {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Image(systemName: "waveform.and.mic")
                            .font(SpeechRailDesignTokens.Typography.callout)
                            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                        Text("麦克风收音检测")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Spacer()
                    }

                    Text("开会前快速确认麦克风拾音电平与反应，不录音也不留文件。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Spacer()
                        Button("检查麦克风音量…") { isCheckingInput = true }
                            .speechRailButton(.secondary)
                            .help("查看当前麦克风的实时音量反应")
                    }
                    .padding(.top, SpeechRailDesignTokens.Spacing.micro)
                }
                .padding(SpeechRailDesignTokens.Spacing.md)
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
        guard let selection = model.health?.selection else { return SpeechRailDisplayFormat.MissingValue.notLoaded.text }
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
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.rail)

            TextField("输入本次会议主题，如「产品规划讨论」（可留空，直接按 ↵ 开始）", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(SpeechRailDesignTokens.Typography.body)
                .onSubmit {
                    Task { await start() }
                }
                .accessibilityLabel("这场会议的标题，输入后可按回车直接开始，也可以留空")

            if !titleDraft.isEmpty {
                Button {
                    titleDraft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
                .buttonStyle(.plain)
                .speechRailPointerCursor()
                .help("清空标题")
            }

            HStack(spacing: SpeechRailDesignTokens.Spacing.tight) {
                Text("↵ 开始")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.micro)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
            .background(SpeechRailDesignTokens.Color.recessedField)
            .clipShape(SpeechRailDesignTokens.Corner.compactShape)
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
            title: titleDraft,
            expectedSpeakerCount: expectedSpeakerCount
        )
        if meeting.phase == .recording { expectedSpeakerCount = .uncertain }
    }
}
