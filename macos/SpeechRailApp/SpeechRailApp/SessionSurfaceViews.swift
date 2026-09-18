import AppKit
import SwiftUI

// 会话三页共用的外壳与组件（UX-UI-SPEC §4.1、SESSIONS-SPEC §6.7）。
//
// 这一个文件里放三样东西，都是「三页共用一份实现」的：
//   1. `SessionEmptyState`——空态的唯一形状（图标 28 + `Heading / Section` + 正文 ≤ 容器内宽）；
//   2. `SessionStatusBar`——会话状态带（状态点 + 阶段文字 + 可选的真实电平 + 等宽计时 + 事实条 + 动作）；
//   3. `SessionOwnershipRow`——侧边栏第二行「谁在用麦克风」。
//
// **本批没有的东西（不要在这里补一个假的）**：三条能力各自的正文面（对话流 / 转录流 / 字幕带）
// 与「开始对话 / 开始会议 / 打开字幕带」三个主按钮，随各自的能力阶段落地（§12 阶段 3/5/6）。
// 主按钮在这里缺席是**有意的**：采集还没接上，放一个按了不动的按钮比暂不提供更糟。

// MARK: - 空态

/// 三页共用的空态。形状与 §12 第 5 项一致：图标 28、标题 `Heading / Section`、
/// 正文折行宽不超过容器内宽（页面级下限 460），一组动作排在下面。
public struct SessionEmptyState<Actions: View>: View {
    public let systemImage: String
    public let title: String
    public let message: String
    private let actions: Actions

    public init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: SpeechRailDesignTokens.Layout.sessionEmptyIconSize))
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .accessibilityHidden(true)

            Text(title)
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .multilineTextAlignment(.center)

            Text(message)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .multilineTextAlignment(.center)
                // 上限 460 是稿的页面级空态口径；放进分栏时由外层容器再收窄，不超这个数。
                .frame(maxWidth: SpeechRailDesignTokens.Layout.sessionEmptyBodyMaximumWidth)

            actions
                .padding(.top, SpeechRailDesignTokens.Spacing.tight)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 会话状态带

/// 会话状态带。三页首屏与会议 live 带共用这一份实现：`MetricStrip` 是纯读数、
/// `StatusPill` 是单个胶囊，拼出来的话三页会各拼一套（正是 Sona 的 S4 代价）。
public struct SessionStatusBar<Trailing: View>: View {
    public let title: String
    public let tone: StatusTone
    public let facts: [String]
    public let elapsed: TimeInterval?
    /// 真实电平（0…1）。**没接上采集时传 `nil`**——那时不画波形，
    /// 而不是画一根动的假波形（§6.1：电平来自麦克风的 `averagePower`）。
    public let level: Double?
    private let trailing: Trailing

    public init(
        title: String,
        tone: StatusTone,
        facts: [String] = [],
        elapsed: TimeInterval? = nil,
        level: Double? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.tone = tone
        self.facts = facts
        self.elapsed = elapsed
        self.level = level
        self.trailing = trailing()
    }

    public var body: some View {
        CardSurface {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(title)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)

                if let level {
                    LevelMeterBar(level: level)
                }

                if let elapsed {
                    Text(SessionCoordinator.formatted(elapsed))
                        .font(SpeechRailDesignTokens.Typography.technicalValue)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .accessibilityLabel("已进行 \(SessionCoordinator.formatted(elapsed))")
                }

                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                trailing
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        }
    }
}

public extension SessionStatusBar where Trailing == EmptyView {
    init(
        title: String,
        tone: StatusTone,
        facts: [String] = [],
        elapsed: TimeInterval? = nil,
        level: Double? = nil
    ) {
        self.init(
            title: title,
            tone: tone,
            facts: facts,
            elapsed: elapsed,
            level: level,
            trailing: { EmptyView() }
        )
    }
}

/// 电平条。只有拿到真实电平才画（`SessionStatusBar` 保证这一点）。
struct LevelMeterBar: View {
    let level: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<12, id: \.self) { index in
                let threshold = Double(index + 1) / 12
                Capsule()
                    .fill(
                        level >= threshold
                            ? SpeechRailDesignTokens.Color.rail
                            : SpeechRailDesignTokens.Color.inkTertiary.opacity(0.25)
                    )
                    .frame(width: 3, height: 4 + CGFloat(index) * 0.6)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 侧边栏第二行

/// 侧边栏第二行：谁在用麦克风（P1 的落点，也是与 Sona S1/S2 的分界）。
/// 与第一行「服务已就绪」同形状：8pt 状态点 + 一行 `Callout`，没有标题行与 chevron。
public struct SessionOwnershipRow: View {
    @Environment(SessionCoordinator.self) private var session
    @Environment(AppNavigationState.self) private var navigation

    public init() {}

    public var body: some View {
        Button {
            navigation.request(session.ownershipRoute)
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(session.ownershipText)
                    .font(.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.List.rowHorizontalPadding)
            .padding(.vertical, SpeechRailDesignTokens.List.rowVerticalPadding)
        }
        .speechRailInteractiveButtonStyle(
            fillsAvailableWidth: true,
            minimumHeight: SpeechRailDesignTokens.List.sidebarRowHeight
        )
        .help(session.isIdle ? "麦克风空闲；打开实时字幕" : "打开正在进行的会话")
        .accessibilityLabel("麦克风")
        .accessibilityValue(session.ownershipText)
    }

    private var tone: StatusTone {
        guard session.occupancy != nil else { return .neutral }
        if session.phase == .interrupted { return .critical }
        // 稿把「正在收声」画成 attention 点（`sessionDot(live, "attention")`），
        // 与「空闲」的 neutral 只差颜色，不差形状。
        return .attention
    }
}

// MARK: - 记录库页面（三个能力共用一份实现）

/// 记录库页面。三个能力的记录住在同一个本机库里、长得一样，所以**这一份实现服务三页**：
/// 差别只有 `kind` 与几处文案（UX-UI-SPEC §4.1 的 `recordListColumn` 同一判断）。
///
/// 它今天就能真跑：列表、选中、搜索、复制、移除都不依赖麦克风与模型
/// （`IMPLEMENTATION-READINESS.md` §12 阶段 2：记录库不依赖麦克风）。
public struct SessionLibraryView: View {
    public let kind: SessionKind

    @Environment(AppModel.self) private var model
    @Environment(SessionCoordinator.self) private var session
    @Environment(CaptionSession.self) private var caption
    @Environment(SessionPreferences.self) private var preferences
    @Environment(\.openSettings) private var openSettings
    @State private var summaries: [SessionSummary] = []
    @State private var selectedID: String?
    @State private var lines: [TranscriptLine] = []
    @State private var speakerNames: [String: String] = [:]
    @State private var searchText = ""
    @State private var loadFailure: String?
    @State private var pendingRemoval: SessionSummary?
    @State private var isShowingDataDirectoryHint = false
    /// 前置检查态那一栏「本次字幕」收起了没有（与语音助手、会议页同一套规矩）。
    @State private var isInspectorCollapsed = false

    public init(kind: SessionKind) {
        self.kind = kind
    }

    public var body: some View {
        // 与语音助手 / 会议页同一个封套口径：先吃满窗格，内容比窗格长时整页滚动。
        // 记录库这一屏的清单长度由使用量决定（转录几十段、字幕记录几百条），
        // `scrollable: false` 会把它的理想高度直接报给分栏（见 AssistantView.body 注）。
        PageScaffold(
            route: kind.route,
            minimumContentHeight: 420,
            growsWithContent: true
        ) {
            VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
                SessionStatusBar(
                    title: session.ownershipText,
                    tone: session.isIdle ? .neutral : .attention,
                    facts: statusFacts,
                    elapsed: session.occupancy == nil ? nil : session.elapsed
                )

                if let loadFailure {
                    StatusBanner(
                        kind: .standard,
                        tone: .critical,
                        title: "记录库不可用",
                        message: loadFailure,
                        actionTitle: "重试",
                        action: { Task { await reload() } }
                    )
                }

                if summaries.isEmpty {
                    emptyState
                } else {
                    library
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } trailing: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                if kind == .captions {
                    // 稿 `screenClosureCaptionsIdle` 的页头第一件是 `kbdInRow(row, "⌘⇧L", 34)`：
                    // 字幕这条闭环的入口**不在这个窗口里**，所以把键画在页头是最省事的一次说明。
                    // 键是真装着的（`SpeechRailApp.wireGlobalShortcuts()`），不是装饰。
                    // 只在空态画：稿的「回看中 / 刚结束」两块画板页头都没有这个键。
                    if summaries.isEmpty {
                        SessionHeaderKeycap("⌘⇧L")
                    }
                    // 页头的主入口（稿 `primaryButton(row, "打开字幕带", …)`）。它**只放在这里**：
                    // 空态里再放一颗同一动作的按钮，等于同一件事两个入口。
                    PageActionButton(
                        title: caption.phase.isLive ? "显示字幕带" : "打开字幕带",
                        systemImage: "captions.bubble",
                        helpText: caption.phase.isLive
                            ? "把字幕带重新显示到屏幕上；它一直在听"
                            : "开始实时字幕：不依赖大模型，只做识别与显示（⌘⇧L）"
                    ) {
                        Task { await caption.openBand() }
                    }
                }
                exportMenu
                if kind == .captions, summaries.isEmpty {
                    SessionPanelToggle(
                        panelName: "本次字幕",
                        isCollapsed: isInspectorCollapsed
                    ) {
                        isInspectorCollapsed.toggle()
                    }
                }
            }
        }
        .task(id: refreshToken) { await reload() }
        .confirmationDialog(
            "移除这条记录？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { summary in
            Button("移除记录", role: .destructive) {
                Task { await remove(summary) }
            }
            Button("取消", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { summary in
            Text(removalMessage(for: summary))
        }
    }

    private var refreshToken: String {
        "\(kind.rawValue)|\(model.health?.ready == true)"
    }

    private var statusFacts: [String] {
        var facts = [kind.title]
        if let profile = model.health?.profile {
            facts.append(SpeechRailProfilePresentation.shortTitle(profile))
        }
        return facts
    }

    // MARK: - 导出（§6.2 第三条判断：走系统保存面板，不画伪保存）

    /// 页头的导出动作。四种格式收进一个菜单而不是排成四颗按钮——页头是低频动作的地方，
    /// 四种格式不值得占四个槽位。默认格式排第一：会议是 Markdown、字幕是 SRT、助手是纯文本。
    private var exportMenu: some View {
        PageActionsMenu(
            title: "导出",
            systemImage: "square.and.arrow.down",
            helpText: selectedSummary == nil
                ? "先在左边的记录列表里选一条，再导出"
                : "把选中的记录导出成文件"
        ) {
            ForEach(orderedFormats) { format in
                Button(format.title) {
                    guard let summary = selectedSummary else { return }
                    export(summary, as: format)
                }
            }
        }
        .disabled(selectedSummary == nil)
    }

    private var orderedFormats: [SessionExportFormat] {
        let preferred = SessionExportFormat.preferred(for: kind)
        return [preferred] + SessionExportFormat.allCases.filter { $0 != preferred }
    }

    /// 导出**重新从库里读一遍**，不拿界面上正在显示的那一份：列表里选中的是这一条，
    /// 但导出物该是库里的定稿内容（`includePartial == false`），两者不该因为一次选中而耦合。
    private func export(_ summary: SessionSummary, as format: SessionExportFormat) {
        Task {
            let payload = await exportPayload(for: summary)
            SessionExportPanel.write(payload, as: format)
        }
    }

    private func exportPayload(for summary: SessionSummary) async -> SessionExportPayload {
        let rows = (try? await session.lines(sessionID: summary.id)) ?? []
        let names = (try? await session.speakerNames(sessionID: summary.id)) ?? [:]
        let minutes = try? await session.latestMinutes(sessionID: summary.id)
        return SessionExportPayload(
            record: summary.record,
            lines: rows,
            speakerNames: names,
            minutes: minutes
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if kind == .captions {
            return AnyView(captionsIdleState)
        }
        return AnyView(genericEmptyState)
    }

    /// 实时字幕的空态（稿 `实时字幕 · 记录库 · 未开始（前置检查）`）。
    ///
    /// 字幕这条闭环的入口不在主窗口里（⌘⇧L 或菜单栏），所以这一屏要把「开始之前要满足
    /// 什么、三种受阻各给哪个出口」一次说清——起点没画清，后面全是悬空的。
    private var captionsIdleState: some View {
        VStack(spacing: SpeechRailDesignTokens.Spacing.gutter) {
            SessionConclusionBand(
                tone: .healthy,
                title: "现在就可以开始字幕",
                message: "它只依赖语音识别，不依赖大模型；开始后字幕带贴在屏幕底部，SpeechRail 不必在前台。",
                hint: "再按一次 ⌘⇧L 结束并保存。字幕带不持有焦点，所以 esc 不会关掉它。"
            ) {
                Button("字幕设置") { openSettings() }
                    .speechRailButton(.secondary)
            }

            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
                SessionPanel {
                    SessionPanelHead(
                        title: "开始之前",
                        detail: "三件事里只有前两件是必须的；第三件决定字幕里有没有说话人。"
                    )
                    SessionHairline()
                    SessionCheckRow(tone: microphoneTone, name: "麦克风", detail: microphoneDetail)
                    SessionHairline()
                    SessionCheckRow(tone: serviceTone, name: "语音服务", detail: serviceDetail)
                    SessionHairline()
                    SessionCheckRow(
                        tone: preferences.captionsDiarizationEnabled ? .ready : .neutral,
                        name: "说话人标签 · 可选",
                        detail: "档位不够时只记文字、不标说话人，正文照常；它也不接大模型，不需要另配模型。"
                    )
                    Spacer(minLength: 0)
                    SessionHairline()
                    CardFoot(
                        note: "字幕带只做识别与显示：不接大模型，也不替你做总结。"
                            + "记录库空着的时候，这里只有「开始字幕」。"
                    ) { EmptyView() }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                // 「非主框体都能收起」这条规矩在这一屏也要成立（用户 2026-09-18），
                // 稿 `screenClosureCaptionsIdle` 的页头末件就是 `sideToggle(row, "本次字幕")`。
                if !isInspectorCollapsed {
                    SessionPanel {
                        SessionPanelHead(title: "本次字幕", badge: "还没有开始")
                        SessionHairline()
                        VStack(alignment: .leading, spacing: 10) {
                            SessionKVRow("运行档位", profileRowText)
                            SessionKVRow("默认字号", "标准")
                            SessionKVRow("字幕带位置", "屏幕底部居中 · 每块屏各记一套")
                            SessionKVRow("采集设备", "系统默认")
                            SessionKVRow("保存位置", "记录库 · 长期保留")
                            SessionKVRow("最近一条记录", lastRecordText)
                        }
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                        .padding(.vertical, SpeechRailDesignTokens.Spacing.md)
                        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Text("运行档位是什么意思")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            Text(
                                "\(profileRowText) 是这台 Mac 现在跑的那一档：认得越准，越能标出说话人。"
                                    + "换档在设置里，已经存下的记录不跟着变。"
                            )
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                        .padding(.bottom, SpeechRailDesignTokens.Spacing.md)
                        Spacer(minLength: 0)
                    }
                    .frame(width: SpeechRailDesignTokens.Layout.sessionInspectorWidth)
                }
            }

            SessionPanel {
                SessionPanelHead(
                    title: "受阻时",
                    detail: nil,
                    trailingDetail: "三种受阻共用同一个形状：说明影响 + 唯一出口；不弹对话框。"
                )
                SessionHairline()
                SessionCheckRow(
                    tone: microphoneAuthorized ? .ready : .attention,
                    name: "麦克风未授权",
                    detail: "系统设置里给过权限才能采音。拒绝一次不会反复弹窗。"
                ) {
                    Button("打开系统设置") { openMicrophoneSettings() }
                        .speechRailButton(.secondary)
                }
                SessionHairline()
                SessionCheckRow(
                    tone: serviceTone,
                    name: "语音服务未就绪",
                    detail: "识别服务没起来时，字幕带换成同一条受阻带并保留最后一句。"
                ) {
                    // 稿这里写的是 `[去服务状态]`；实现给 `[重试]`——服务还没起来时重试会
                    // 原样再报一次，出口在这一屏够用（SESSIONS-SPEC §12.1.2 第 3 条未决项）。
                    Button("重试") { Task { await caption.retry() } }
                        .speechRailButton(.secondary)
                }
                SessionHairline()
                SessionCheckRow(
                    tone: .attention,
                    name: "麦克风被占用",
                    detail: "同一时刻只有一个会话能用麦克风；交还要确认，不会静默抢。"
                ) {
                    Button("结束会话并切换") { Task { await caption.takeOverOccupiedMicrophone() } }
                        .speechRailButton(.secondary)
                }
            }
        }
    }

    private var genericEmptyState: some View {
        SessionEmptyState(
            systemImage: kind.systemImage,
            title: emptyTitle,
            message: emptyMessage
        ) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Button("打开数据目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.libraryURL])
                }
                .buttonStyle(.bordered)

                Button("重新读取") {
                    Task { await reload() }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .speechRailSurface(.panel)
        .clipShape(SpeechRailDesignTokens.Corner.containerShape)
    }

    private var emptyTitle: String {
        switch kind {
        case .assistant: "还没有对话记录"
        case .meeting: "还没有会议记录"
        case .captions: "还没有字幕记录"
        }
    }

    // MARK: 前置检查的读数（只读系统与服务的现状，不猜）

    private var microphoneAuthorized: Bool {
        MicrophoneCapture.authorizationStatus() == .authorized
    }

    private var microphoneTone: SessionRowTone {
        microphoneAuthorized ? .ready : .attention
    }

    private var microphoneDetail: String {
        switch MicrophoneCapture.authorizationStatus() {
        case .authorized: "已经给过权限，开始就能采音。"
        case .notDetermined: "第一次开始时会请求授权；拒绝后这一行会变成受阻态并给出出口。"
        default: "系统里没给麦克风权限：识别拿不到声音，先去设置里打开。"
        }
    }

    private var serviceTone: SessionRowTone {
        model.health?.ready == true ? .ready : .attention
    }

    private var serviceDetail: String {
        model.health?.ready == true
            ? "识别在本机跑，服务已就绪。"
            : "识别在本机跑；服务未就绪时字幕带会换成同一条受阻带。"
    }

    private var profileRowText: String {
        guard let profile = model.health?.profile else { return "未读取" }
        return SpeechRailProfilePresentation.shortTitle(profile)
    }

    private var lastRecordText: String {
        guard let latest = summaries.first else { return "还没有记录" }
        let when = latest.record.startedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(when) · \(latest.lineCount) 行"
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private var emptyMessage: String {
        switch kind {
        case .assistant:
            "开始对话之后，你说过的话和助手的回答会留在这里，可以回看、搜索、复制。原始音频不留存。"
        case .meeting:
            "开始会议之后，转录会边听边出现；结束后可以生成纪要、改说话人的名字，并导出 Markdown 或 SRT。原始音频不留存。"
        case .captions:
            "字幕带打开之后，看过的字幕会留在这里，可以回看、搜索和导出 SRT。原始音频不留存。"
        }
    }

    private var library: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            recordList
            if let selected = selectedSummary {
                recordDetail(selected)
            } else {
                SessionEmptyState(
                    systemImage: kind.systemImage,
                    title: "选一条记录",
                    message: "左边选一条记录，这里显示它的正文与信息。"
                ) { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .speechRailSurface(.panel)
                .clipShape(SpeechRailDesignTokens.Corner.containerShape)
            }
        }
    }

    private var recordList: some View {
        CardSurface {
            VStack(spacing: 0) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    SectionHeading(title: "记录", detail: "\(summaries.count)")
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Layout.sessionListPadding)
                .padding(.top, SpeechRailDesignTokens.Spacing.sm)
                .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)

                TextField("搜索记录", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, SpeechRailDesignTokens.Layout.sessionListPadding)
                    .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)

                Divider()

                List(selection: $selectedID) {
                    ForEach(filteredSummaries) { summary in
                        recordRow(summary)
                            .tag(summary.id)
                            .contextMenu {
                                Menu("导出") {
                                    ForEach(orderedFormats) { format in
                                        Button(format.title) {
                                            export(summary, as: format)
                                        }
                                    }
                                }
                                Button("复制全文") {
                                    Task { await copyTranscript(of: summary) }
                                }
                                Button("移除记录…", role: .destructive) {
                                    pendingRemoval = summary
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: SpeechRailDesignTokens.Layout.sessionListWidth)
    }

    private func recordRow(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(displayTitle(for: summary))
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                if let reason = summary.openInterruption {
                    StatusPill(tone: .critical, label: reason.title)
                }
                Spacer(minLength: SpeechRailDesignTokens.Spacing.micro)
                if summary.record.state == .recording {
                    StatusPill(tone: .attention, label: "录制中")
                } else if summary.record.state == .processing {
                    StatusPill(tone: .attention, label: "整理中")
                }
            }
            Text(recordSubtitle(summary))
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(
                    maxWidth: SpeechRailDesignTokens.Layout.sessionListRowInnerWidth,
                    alignment: .leading
                )
                .lineLimit(1)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
    }

    private func recordDetail(_ summary: SessionSummary) -> some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    SectionHeading(title: displayTitle(for: summary), detail: recordSubtitle(summary))
                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                    Menu {
                        ForEach(orderedFormats) { format in
                            Button(format.title) {
                                export(summary, as: format)
                            }
                        }
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.down")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
                    Button("复制全文") {
                        Task { await copyTranscript(of: summary) }
                    }
                    .buttonStyle(.bordered)
                    Button("移除记录…", role: .destructive) {
                        pendingRemoval = summary
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)

                Divider()

                if lines.isEmpty {
                    Text("这条记录里还没有正文。")
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                            ForEach(lines) { line in
                                lineRow(line)
                            }
                        }
                        .padding(SpeechRailDesignTokens.Spacing.md)
                    }
                }

                Divider()

                Text("记录只保存在这台 Mac 上；原始音频不留存。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func lineRow(_ line: TranscriptLine) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text(speakerText(for: line))
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(width: SpeechRailDesignTokens.Layout.sessionSpeakerColumnWidth, alignment: .leading)
                .lineLimit(1)

            Text(Self.timecode(line.tStart))
                .font(SpeechRailDesignTokens.Typography.technical)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .frame(width: SpeechRailDesignTokens.Layout.sessionTimecodeColumnWidth, alignment: .leading)

            Text(line.text)
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.tight)
    }

    private func speakerText(for line: TranscriptLine) -> String {
        // 显式 `return`：`.speaker` 那一支里有两个语句，整个 switch 因此不是表达式，
        // 不能靠隐式返回（上一版就是这么编译失败的）。
        switch line.role {
        case .user: return "你"
        case .assistant: return "助手"
        case .speaker:
            guard let label = line.speakerLabel else { return "说话人" }
            return speakerNames[label] ?? "说话人 \(label)"
        }
    }

    private static func timecode(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "--:--" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - 数据

    private var filteredSummaries: [SessionSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return summaries }
        return summaries.filter { summary in
            displayTitle(for: summary).localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedSummary: SessionSummary? {
        summaries.first { $0.id == selectedID }
    }

    private func displayTitle(for summary: SessionSummary) -> String {
        if let title = summary.record.title, !title.isEmpty { return title }
        return summary.record.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func recordSubtitle(_ summary: SessionSummary) -> String {
        var parts = [SessionCoordinator.formatted(summary.duration())]
        parts.append("\(summary.lineCount) 行")
        if summary.speakerCount > 0 {
            parts.append("\(summary.speakerCount) 位说话人")
        }
        parts.append(summary.record.audioSource.title)
        if summary.record.state == .archived, let reason = summary.record.endReason, reason != .user {
            parts.append(reason.title)
        }
        return parts.joined(separator: " · ")
    }

    private func removalMessage(for summary: SessionSummary) -> String {
        let title = displayTitle(for: summary)
        return "「\(title)」的正文、纪要与内心 OS 问答会一起删掉，无法撤销。"
            + "原始音频本来就没有留存。"
    }

    private func reload() async {
        do {
            let loaded = try await session.listSummaries(kind: kind)
            summaries = loaded
            if selectedID == nil || !loaded.contains(where: { $0.id == selectedID }) {
                selectedID = loaded.first?.id
            }
            loadFailure = nil
            await loadLines()
        } catch {
            loadFailure = error.localizedDescription
            summaries = []
            lines = []
        }
    }

    private func loadLines() async {
        guard let selectedID else {
            lines = []
            speakerNames = [:]
            return
        }
        lines = (try? await session.lines(sessionID: selectedID)) ?? []
        speakerNames = (try? await session.speakerNames(sessionID: selectedID)) ?? [:]
    }

    private func copyTranscript(of summary: SessionSummary) async {
        let rows = (try? await session.lines(sessionID: summary.id)) ?? []
        let text = rows.map { "\(speakerText(for: $0))  \($0.text)" }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func remove(_ summary: SessionSummary) async {
        pendingRemoval = nil
        try? await session.removeSession(id: summary.id)
        if selectedID == summary.id {
            selectedID = nil
        }
        await reload()
    }
}
