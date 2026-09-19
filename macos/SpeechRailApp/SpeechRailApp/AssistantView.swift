import AppKit
import SwiftUI

// 语音助手页。形状按 `figma-kit/main.js` 的六块画板：未开始（先定人设与音色）、未配置模型、
// 对话中（含收起态）、换音色、记忆、记录库。
//
// 页面按状态换内容，不为每个时刻单开一屏（稿 `闭环总览` 的状态模型）：页头与状态带在所有
// 状态里原地不动，所以「不看右栏也不会做错事」；右栏是可收起的非主框体，收起后 360pt
// 全归主框体（`closurePanelRulesBoard`）。
//
// 本页只做一件事：把 `AssistantSession` 的状态摆出来，并把用户的动作交回去。

public struct AssistantView: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionCoordinator.self) private var session
    @Environment(AssistantSession.self) private var assistant
    @Environment(SessionPreferences.self) private var preferences
    /// 受阻时的「去服务状态」是一条真出口，所以这一页要能发起跳转（与创作页同一套）。
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.openSettings) private var openSettings

    @State private var typed = ""
    /// 「本次会话」那一栏收起了没有。稿：收起不是少一个面板，是同一个面板的另一个状态。
    @State private var isInspectorCollapsed = false
    /// 记录是否是因为窗口拉窄而由响应式布局自动收起右栏（拉宽时据此决定是否自动恢复展开）
    @State private var autoCollapsedDueToWidth = false
    @State private var inspectorTab: InspectorTab = .session
    @State private var memories: [AssistantMemory] = []
    @State private var recent: [SessionSummary] = []
    @State private var reviewRecord: SessionRecord?
    @State private var reviewLines: [TranscriptLine] = []
    @State private var reviewSpeakerNames: [String: String] = [:]
    /// 这一条记录里的音色变更点（`session_change`）。回看时每一行的徽标按它回推。
    @State private var reviewVoiceChanges: [SessionChange] = []
    @State private var selectedPersonaID = ""
    @State private var selectedVoiceID = ""
    @State private var mode: AssistantMode = .duplex
    @State private var isCheckingInput = false
    @State private var isCreatingPersona = false
    @State private var personaDraft = PersonaDraft()
    @State private var isShowingConfigHelp = false
    /// 记录库那一栏：重命名与移除都用一次确认，移除还要刷新列表（`reloadToken`）。
    @State private var isRenamingRecord = false
    @State private var renameDraft = ""
    @State private var confirmingRemove = false
    @State private var libraryReloadToken = 0
    /// 记忆库那一栏：主动添加记忆的内联草稿
    @State private var isAddingMemory = false
    @State private var newMemoryDraft = ""
    /// 就地配置对话模型的那三个字段（2026-09-19 用户反馈「门槛极高」之后加的）。
    @State private var llmBaseURLDraft = ""
    @State private var llmModelDraft = ""
    @State private var llmKeyDraft = ""
    @State private var llmSaveNote: String?
    /// 钥匙串里有没有那一份密钥。**不在 body 里读**：那是一次可能被系统弹框拦下的
    /// 同步调用，读它要放在 `.task` 里（见那一段的注解）。
    @State private var hasStoredKey = false
    /// 「未开始」态里"换个角色 / 换个声音"是可选项，默认收起：想开始的人不该先做两道选择题。
    @State private var showsStyleOptions = false
    /// 是否展开就地快速配置大模型卡片
    @State private var isShowingQuickLLM = false
    /// 刚刚由这一页**结束**掉的那一段。只有它会在记录库顶上多一条绿色结论条——
    /// 翻一条旧记录时不该看见「刚结束」（那是一条谎）。
    @State private var justEndedSessionID: String?
    /// 刚落进记忆的那一句的回执（写在对话卡页脚那一行）。**必须有回执**：
    /// 「记住」按下去只是往库里写一行，屏幕上零变化就与"点了没反应"没有区别。
    @State private var memoryNote: String?
    /// 这一页此刻在不在屏幕上（`onAppear` / `onDisappear`）。「结束之后落到刚结束的那一段」
    /// 只对**正在看的这一页**做：结束一场会议时用户人在会议页，那时把助手页翻到一条旧记录上，
    /// 等他半小时后回来会看见"刚结束"三个字——那是一条过期的谎。
    @State private var isOnScreen = false
    /// 这一次结束是**为了接着开新的一轮**（`restartWithPersonaPick`）：那种结束不落地，
    /// 用户要的是新的一轮，不是上一段的回看。见 `landOnFinalized` 第 4 条。
    @State private var isEndingToRestart = false
    @State private var voiceSearchQuery = ""
    @State private var voiceFilterScope: VoiceFilterScope = .all
    @State private var voicePageIndex = 0
    private let voicePageSize = 5

    private enum VoiceFilterScope: String, CaseIterable, Identifiable {
        case all = "全部"
        case custom = "克隆定制"
        case system = "预置声音"

        var id: String { rawValue }
    }

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case session
        case voice
        case record
        case memory

        var id: String { rawValue }

        var title: String {
            switch self {
            case .session: "会话"
            case .voice: "音色"
            case .record: "记录"
            case .memory: "记忆"
            }
        }
    }

    struct PersonaDraft {
        var title = ""
        var body = ""
    }

    public init() {}

    // MARK: - 状态判定

    private var isLive: Bool { assistant.phase.isLive }

    /// 受阻原因：运行时记下的优先，其次是**首屏就能知道的事实**。
    ///
    /// 「没配对话模型」不需要用户先点一次「开始对话」才知道。2026-09-19 真机走查里，
    /// 首屏是绿的「现在就能开始」，同一屏右栏却写着红字「对话模型 未配置」，按下
    /// 「开始对话」才翻到稿上的受阻板（`screenAssistantBlocked`）——**首屏骗人**。
    /// 这一条本来就在 `preferences` 里躺着，所以判定要读它，而不是等一次失败。
    /// 受阻原因：麦克风被拒、服务没起来、被占用等真正的硬件/运行时阻断。
    /// 未配大模型时不进入硬受阻，而是作为就绪待配置状态，在首屏提供极简一键预设。
    private var blockedReason: AssistantSession.BlockReason? {
        if isLive { return nil }
        if let blocked = assistant.blocked { return blocked }
        return nil
    }

    /// 四态：未开始 / 运行时受阻 / 对话中 / 记录库回看。
    private var state: PageState {
        if reviewRecord != nil { return .review }
        if isLive { return .live }
        return blockedReason == nil ? .ready : .blocked
    }

    private enum PageState {
        case ready
        case blocked
        case live
        case review
    }

    // MARK: - 页面

    public var body: some View {
        // `scrollable: true` + `minimumContentHeight` + `growsWithContent`：正文**先吃满窗格**
        // （卡片因此能像稿那样吃满、两列等高），清单比窗格长时页面整页滚动，而不是把
        // 多出来的部分裁掉。
        //
        // 为什么必须这么做（2026-09-19 装机件实测）：`scrollable: false` 的封套把正文的
        // **理想高度**直接报给 `NavigationSplitView`；只要正文里有一处理想高度超过窗格
        // （音色列表有 18 条、约 790pt 就够），分栏就按理想高度铺开、再在窗口里垂直居中——
        // 侧栏与正文一起被推出可视区，整窗全白（AX 树却完整）。实测：坏版分栏 1355×4317，
        // 好版 1355×781（窗口内容区 741）。这与 `WorkspaceComponents.PageScaffold` 注里
        // 记的「第三十轮」是同一个失败面，`minimumContentHeight` 那条滚动路径正是为它建的。
        PageScaffold(
            route: .assistant,
            scrollable: false,
            purpose: pagePurpose,
            minimumContentHeight: 420,
            growsWithContent: false
        ) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                if state == .live {
                    statusBar
                    splitArea
                } else if state == .review {
                    justEndedBand
                    reviewArea
                } else {
                    if state == .blocked {
                        band
                    }
                    splitArea
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: navigation.layoutTier, initial: true) { _, newTier in
                syncInspectorWithLayoutTier(newTier)
            }
            .onChange(of: state) { _, _ in
                syncInspectorWithLayoutTier(navigation.layoutTier)
            }
        } trailing: {
            headerActions
        }
        .task {
            selectedPersonaID = preferences.defaultPersonaID
            selectedVoiceID = preferences.defaultVoiceID
            mode = preferences.assistantMode
            llmBaseURLDraft = preferences.llmBaseURL
            llmModelDraft = preferences.llmModel
            // 钥匙串**只在这里读一次**，而且不在主线程上读。
            //
            // 读钥匙串是一次可能被系统弹框拦下的同步调用（这一条目属于哪个 App 由
            // 签名决定，换一个构建就变了）。原先它写在右栏事实行里——每次重算版面都会
            // 押在主线程上等一次，`sr-shot-pages` 离屏工装就是被它卡死的
            // （2026-09-19，栈顶停在 `SecItemCopyMatching`）。真机走的是同一条路径。
            hasStoredKey = await Task.detached { LLMKeychain.hasKey }.value
            await reloadMemories()
            await reloadRecent()
            await model.refreshCreatorVoices()
        }
        // 「结束」的落点由**封存完成**这件事驱动（见 `landOnFinalized`）：
        // 页头按钮、`⌘⇧.`、菜单栏三个入口因此有同一个结局。
        .onChange(of: session.lastFinalizedSessionID) { _, newValue in
            guard let newValue else { return }
            Task { await landOnFinalized(id: newValue) }
        }
        .onChange(of: voiceSearchQuery) { _, _ in
            voicePageIndex = 0
        }
        .onChange(of: voiceFilterScope) { _, _ in
            voicePageIndex = 0
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .sheet(isPresented: $isCreatingPersona) { personaSheet }
        .sheet(isPresented: $isCheckingInput) { InputLevelSheet() }
        .sheet(isPresented: $isShowingConfigHelp) { configurationHelpSheet }
        .sheet(isPresented: $isRenamingRecord) { renameRecordSheet }
        .confirmationDialog(
            "从记录库移除这一条？",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) { Task { await removeReviewedRecord() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这一条对话的正文与它的分组信息都会从本机库里删掉，之后找不回来。"
                + "只是不想再看了，用「新建对话」离开就好——记录会一直留着。")
        }
    }

    private var pagePurpose: String {
        switch state {
        case .ready: "定好角色与声音就能开始；说也行，打字也行。"
        case .blocked: "和本机大模型用语音一来一往；识别与回复只留在这台 Mac 上。"
        case .live: "和它一来一往：说也行，打字也行；对话只留在这台 Mac 上。"
        case .review: "和本机大模型用语音一来一往；记录长期留在记录库。"
        }
    }

    // MARK: - 页头动作（稿逐态各一套）

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            switch state {
            case .ready:
                // 「开始对话」**不在页头**：它已经在结论条上（用户第一眼看的地方）。
                // 同一个动作在一屏里画两遍，是上一轮刚收掉的毛病。
                PageActionButton(
                    title: "打开设置",
                    systemImage: "slider.horizontal.3",
                    helpText: "打开会话设置：模型地址、默认角色与声音"
                ) { openSettings() }
            case .blocked:
                PageActionButton(
                    title: "设置 · 会话",
                    systemImage: "slider.horizontal.3",
                    helpText: "打开会话设置，填对话模型的地址、模型与密钥"
                ) { openSettings() }
            case .live:
                SessionHeaderKeycap("⌘⇧.")
                PageActionButton(
                    title: "音色与风格",
                    systemImage: "slider.horizontal.3",
                    helpText: "换音色只改声音，下一句生效；换角色要新开一轮"
                ) { showInspector(tab: .voice) }
                PageActionButton(
                    title: "结束对话",
                    systemImage: "stop.circle",
                    helpText: "结束这次对话；记录会留在记录库里"
                ) { Task { await endConversation() } }
            case .review:
                // 稿 `screenClosureAssistantClosed` 的页头：`⌘⇧.` / 导出 / 新建对话。
                // 「返回实时」只在**确实还开着**一段对话时才给：记录库里翻旧记录的时候
                // 可能同时有一轮在跑，那时它是一条真出口；没在跑时它只会把人送回"未开始"，
                // 与「新建对话」是同一件事，摆两颗一样的按钮就是凑数。
                SessionHeaderKeycap("⌘⇧.")
                if isLive {
                    PageActionButton(
                        title: "返回实时",
                        systemImage: "arrow.uturn.backward",
                        helpText: "回到还在进行的那一轮"
                    ) { closeReview() }
                }
                exportMenu
                PageActionButton(
                    title: "新建对话",
                    systemImage: "message",
                    helpText: "回到「先定角色与声音」：这一条记录留在库里，一个字都不动"
                ) { startNewRound() }
            }
            if state != .review {
                // 收起控件的名字按右栏**此刻装着什么**说（稿 `sideToggle`）。
                SessionPanelToggle(
                    panelName: inspectorTogglePanelName,
                    isCollapsed: isInspectorCollapsed
                ) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        isInspectorCollapsed.toggle()
                        autoCollapsedDueToWidth = false
                    }
                }
            }
        }
    }

    private var inspectorTogglePanelName: String {
        switch inspectorTab {
        case .session: return "会话状态"
        case .voice: return "音色库"
        case .record: return "记录库"
        case .memory: return "记忆库"
        }
    }

    // MARK: - 状态带

    private var statusBar: some View {
        SessionStatusBar(
            title: statusTitle,
            tone: statusTone,
            facts: statusFacts,
            elapsed: isLive ? session.elapsed : nil,
            level: isLive ? assistant.level : nil
        )
    }

    private var statusTitle: String {
        switch state {
        case .ready: return "还没有开始对话"
        case .blocked: return "这次对话没有开始"
        case .live:
            if assistant.isMuted { return "麦克风已静音" }
            return assistant.phase.title
        case .review: return "这一段对话已经结束"
        }
    }

    private var statusTone: StatusTone {
        switch state {
        case .ready: .neutral
        case .blocked: .attention
        case .live:
            switch assistant.phase {
            case .preparing, .thinking: .attention
            default: .healthy
            }
        case .review: .neutral
        }
    }

    /// 状态带只放**事实**：动作一律在下面各自的行里给一处（稿的第七轮去重）。
    private var statusFacts: [String] {
        switch state {
        case .ready, .blocked:
            return [mode.title]
        case .live, .review:
            var facts: [String] = []
            if let model = assistant.llmModel ?? (preferences.isLLMConfigured ? preferences.llmConfiguration.model : nil) {
                facts.append("大模型 \(model) · 已连接")
            }
            facts.append(mode.title)
            return facts
        }
    }

    // MARK: - 结论条

    /// 结论条只在「未开始」与「未配置模型」两态出现；调用点只想问一句"有没有"。
    ///
    /// **不要改回 `AnyView?`**：2026-09-19 装机件实测，这一条被 `AnyView` 包起来之后，
    /// 整页的理想高度被报成 4317pt（窗口内容区只有 741pt），`NavigationSplitView` 于是
    /// 按理想高度铺开、再垂直居中到窗口里——侧栏与正文一起被推出可视区，窗口看起来
    /// 全白（AX 树却完整）。同一份内容直接写出来（`_ConditionalContent`，类型不擦除）
    /// 布局正常。二分证据：`AnyView` 版本 1355×4317，直接版本 1355×781。
    @ViewBuilder
    private var band: some View {
        if state == .blocked, let reason = blockedReason {
            SessionConclusionBand(
                tone: .attention,
                title: reason.title,
                message: reason.detail,
                hint: blockedHint(reason)
            ) {
                blockedActions(reason)
            }
        } else {
            EmptyView()
        }
    }

    // MARK: - 刚结束（记录库顶上那条绿色结论条）

    /// 「结束对话」之后落在这里：这一刻用户真正的疑问只有一个——**我刚才说的那些去哪了**。
    ///
    /// 稿 `语音助手 · 记录库 · 刚结束` 顶上就是这条绿带子。它与 `.ready` 的结论条是同一形状、
    /// 同一个位置，所以"结束"这件事有回执：记录已经封存、被选中、而且不因为结束就少一个字
    /// （用户 2026-09-17：「记录和纪要是资产」）。它**不给按钮**：真正的动作在页头
    /// （导出 / 新建对话）与正文底部（继续 / 重命名 / 移除），这里再摆一遍就是同一个动作画两遍。
    ///
    /// 只在**刚由这一页结束**的那一段上出现。翻旧记录时不出现——「刚结束」放在三天前那一条
    /// 上就是一句谎（`justEndedSessionID` 由 `endConversation()` 写、`openRecord()` 清）。
    @ViewBuilder
    private var justEndedBand: some View {
        if let record = reviewRecord, record.id == justEndedSessionID {
            SessionConclusionBand(
                tone: .healthy,
                title: "刚结束的这段已经写进记录库",
                // 打开这一刻已经从库里读回来一遍（`openRecord`），所以这里的名字、句数与
                // 时长都是**库里那一行**的读数，不是界面上的残留。
                message: "「\(record.title ?? "这一轮对话")」\(reviewExchangeCount) 轮 · "
                    + "\(reviewDurationText)，排在列表最上面，也已经选中。"
                    + "记录长期留在这台 Mac 上，角色、声音与大模型都随它一起存下来。",
                hint: "「结束对话」只结束这一次；记录不会因为结束少一个字。"
                    + "不想要了是另一个动作——正文底部的「从记录库移除」，只在这一页给，而且会先问一次。"
            ) { EmptyView() }
        }
    }

    /// 受阻的出口：每一类原因只有**一条**真能解决它的路，再配一个不改状态的「重试」。
    /// 稿 `screenAssistantBlocked` 只画了「未配置」那一类（两条出口），其余按同一形状补。
    @ViewBuilder
    private func blockedActions(_ reason: AssistantSession.BlockReason) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            switch reason {
            case .llmNotConfigured:
                // **不给「打开设置…」**：就地填的那张卡（`llmSetupCard`）就在这条带子下面，
                // 摆一颗更远的主按钮等于同一件事两个入口，还把人的视线从表单上引开
                // （用户 2026-09-19：一次性设置只在必要时刻就地打扰）。
                // 想去设置页的人（那里有「检查连接」）仍有一条安静的路。
                Button("了解如何配置") { isShowingConfigHelp = true }
                    .speechRailButton(.secondary)
                Button("去设置里填") { openSettings() }
                    .speechRailButton(.quiet)
            case .llmUnreachable:
                Button("打开设置…") { openSettings() }
                    .speechRailButton(.primary)
                retryAction
            case .microphoneDenied:
                Button("打开系统设置") { openMicrophoneSettings() }
                    .speechRailButton(.primary)
                retryAction
            case .serviceNotReady:
                Button("去服务状态") { navigation.request(.overview) }
                    .speechRailButton(.primary)
                retryAction
            case .occupiedBy:
                // 出口就是占用守卫本身：协调器会先弹「结束那个会话并切换」的确认。
                Button("结束会话并切换") { Task { await session.requestStart(.assistant) } }
                    .speechRailButton(.primary)
            case .serviceBusy, .storeUnavailable, .streamFailed:
                retryAction
            }
        }
    }

    private var retryAction: some View {
        Button("重试") { Task { await assistant.retry() } }
            .speechRailButton(.secondary)
    }

    /// 结论条那一行小字：正文说的是「怎么了」，它说「改完在哪一步生效、要满足什么」。
    private func blockedHint(_ reason: AssistantSession.BlockReason) -> String {
        switch reason {
        case .llmNotConfigured:
            "密钥只存钥匙串，不写进配置文件，也不出现在日志或导出物里；"
                + "下面三格填完点「保存并开始对话」就连一次，连不上会在这条带子上说明原因。"
        case .llmUnreachable:
            "地址、模型或密钥改完点一次「重试」即可，不用重启 App。"
        case .microphoneDenied:
            "系统设置 → 隐私与安全性 → 麦克风；给过权限之后回来点「重试」。拒绝一次不会反复弹窗。"
        case .serviceNotReady:
            "识别与合成由侧边栏「服务状态」那一页管理；服务没起来时助手、会议、字幕都连不上。"
        case .serviceBusy:
            "服务同一时刻只跑一个重任务：等它跑完点「重试」，或者先打字问。"
        case .occupiedBy:
            "麦克风同一时刻只由一个会话使用；确认之后当前那个会先结束，不会静默抢。"
        case .storeUnavailable:
            "记录库写不进去就不开始对话：识别与回复都是要留下的记录，宁可不录。"
        case .streamFailed:
            "已经定稿的对话都还在库里；点「重试」重新接一段。"
        }
    }

    // MARK: - 主区

    private var splitArea: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                switch state {
                case .ready:
                    if !preferences.isLLMConfigured || isShowingQuickLLM {
                        llmSetupCard
                    }
                    readyMainWorkbenchCard
                case .blocked:
                    if blockedReason == .llmNotConfigured {
                        llmSetupCard
                        capabilitiesCard
                    } else {
                        capabilitiesCard
                    }
                    controlsCard
                default:
                    liveChatWorkbenchCard
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !isInspectorCollapsed {
                inspectorColumn
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 460, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: isInspectorCollapsed)
    }

    // MARK: 人设（未开始）

    /// 「未开始」态里的**可选项**：角色与声音，默认收起成一行。
    ///
    /// 理由（用户 2026-09-19：「门槛极高」）：想开始的人只需要按一次「开始对话」——
    /// 默认角色与默认声音本来就能用。把一条角色列表加一条音色列表摆在首屏，
    /// 等于用户还没听到一句话就得先做两道选择题。这里默认收起，展开才给全部选择。
    private var styleOptions: some View {
        DisclosureGroup(isExpanded: $showsStyleOptions) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
                personaCard
                voicesCard
                modeCard
            }
            .padding(.top, SpeechRailDesignTokens.Spacing.sm)
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text("换个角色、声音或对话方式（可选）")
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text("现在是「\(selectedPersonaTitle)」·「\(currentVoiceName ?? Self.defaultVoiceLabel)」·「\(mode.title)」")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer(minLength: 0)
            }
        }
        .disclosureGroupStyle(SpeechRailDisclosureGroupStyle())
    }

    /// 「未开始」态下的声学概览卡：声学与人格集成全景展示，附带灵感提问。
    /// 「未开始」态下的声学主舞台：声学生命力展示、人设与音色双核中枢、灵感提问与快捷开麦。
    /// 「未开始」态下的一体化全高声学主工作台：
    /// 声学舞台中枢、角色与音色双核名片、2×2 场景任务矩阵、最近会话回溯、锚定底部的输入中枢。
    private var readyMainWorkbenchCard: some View {
        SessionPanel(expandsVertically: true) {
            SessionPanelHead(
                title: "声学对讲工作台",
                badge: "待机就绪"
            )
            SessionHairline()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
                    // 1. 声学舞台中枢：动态呼吸声波与环境状态条
                    acousticStageRow

                    // 2. 伙伴角色与发音音色双核心名片
                    personaAndVoiceRow

                    // 3. 灵感任务与场景卡片矩阵（2×2）
                    scenarioGrid

                    // 4. 最近会话快速回溯（若有记录）
                    if let latest = recent.first {
                        recentSessionResumeBar(latest)
                    }

                    Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                }
                .padding(SpeechRailDesignTokens.Spacing.md)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SessionHairline()

            // 5. 锚定底部的输入中枢（一体化底栏）
            VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                controlsInputRow
                controlsSecondaryRow
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var acousticStageRow: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.md) {
            AcousticWaveformAura(
                isPlaying: model.isAudioPlaying,
                isLoading: model.isCreatingSpeech && model.previewingVoiceID != nil,
                isLive: false,
                level: model.isAudioPlaying ? Double(model.playbackLevel) : assistant.level,
                envelope: currentVoice.flatMap { model.waveformEnvelope(forVoiceID: $0.id) },
                progress: model.playbackProgress
            )
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    StatusPill(tone: .healthy, label: "声场就绪")
                    Text("Apple Silicon 本地低延迟声学管道")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                }
                Text("当前输入源：\(microphoneLabel) · 说话即录，打字即问")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            Spacer()

            StatusPill(tone: .healthy, label: "就绪待命")
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
        )
    }

    private var personaAndVoiceRow: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.md) {
            // 对话角色卡
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                HStack {
                    Label("对话角色", systemImage: "theatermasks")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Spacer()
                    Menu {
                        ForEach(preferences.personas) { p in
                            Button {
                                selectedPersonaID = p.id
                                preferences.defaultPersonaID = p.id
                            } label: {
                                HStack {
                                    Text(p.title)
                                    if p.id == selectedPersonaID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("新建自定义角色…") {
                            personaDraft = PersonaDraft()
                            isCreatingPersona = true
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text("切换")
                                .font(SpeechRailDesignTokens.Typography.caption)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    }
                    .menuStyle(.borderlessButton)
                }
                Text(selectedPersonaTitle)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(selectedPersonaSummary)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .lineLimit(2)
            }
            .padding(SpeechRailDesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SpeechRailDesignTokens.Color.field,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            )

            // 发音音色卡
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                HStack {
                    Label("发音音色", systemImage: "waveform")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Spacer()
                    if let voice = currentVoice {
                        let isPlaying = model.isAudioPlaying && model.playingVoiceID == voice.id
                        let isLoading = model.isCreatingSpeech && model.previewingVoiceID == voice.id
                        Button {
                            if isPlaying || isLoading {
                                model.stopAudio()
                            } else {
                                Task { await model.previewVoice(voice) }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("准备中…")
                                        .font(SpeechRailDesignTokens.Typography.caption)
                                } else if isPlaying {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 9))
                                    Text("停止")
                                        .font(SpeechRailDesignTokens.Typography.caption)
                                } else {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.system(size: 9))
                                    Text("试听")
                                        .font(SpeechRailDesignTokens.Typography.caption)
                                }
                            }
                            .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                        }
                        .buttonStyle(.borderless)
                        .help(isPlaying ? "停止试听" : (isLoading ? "正在准备试听音频…" : "试听 \(voice.name)"))
                    }
                    voicePickerMenu
                }
                HStack(spacing: 4) {
                    Text(currentVoiceName ?? Self.defaultVoiceLabel)
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    if let currentVoice {
                        StatusPill(
                            tone: currentVoice.isSystem ? .neutral : .healthy,
                            label: currentVoice.isSystem ? "预置" : "克隆"
                        )
                    }
                }
                Text(currentVoice?.description.isEmpty == false ? currentVoice!.description : "支持 SpeechRail 音色库任意音色，随时可换")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .lineLimit(2)
            }
            .padding(SpeechRailDesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SpeechRailDesignTokens.Color.field,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            )
        }
    }

    private var customVoices: [CreatorVoice] {
        voiceRows.filter { !$0.isSystem && $0.available }
    }

    private var systemVoices: [CreatorVoice] {
        voiceRows.filter { $0.isSystem && $0.available }
    }

    private var voicePickerMenu: some View {
        Menu {
            let custom = customVoices
            if !custom.isEmpty {
                Section("我的定制与克隆声音") {
                    ForEach(custom) { v in
                        Button {
                            selectVoice(v)
                        } label: {
                            HStack {
                                Text(v.name)
                                if v.id == effectiveVoiceID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
            let system = systemVoices.isEmpty ? voiceRows : systemVoices
            Section("系统预置声音") {
                ForEach(system) { v in
                    Button {
                        selectVoice(v)
                    } label: {
                        HStack {
                            Text(v.name)
                            if v.id == effectiveVoiceID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
            Button("🎙️ 录制专属声音（音色克隆）…") {
                navigation.request(.voiceClone)
            }
            Button("✨ 创作新音色（音色创作）…") {
                navigation.request(.voiceDesign)
            }
            Button("📚 打开音色库管理…") {
                navigation.request(.voiceLibrary)
            }
        } label: {
            HStack(spacing: 2) {
                Text("换音色")
                    .font(SpeechRailDesignTokens.Typography.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
        }
        .menuStyle(.borderlessButton)
    }

    private struct AcousticWaveformAura: View {
        let isPlaying: Bool
        var isLoading: Bool = false
        let isLive: Bool
        let level: Double
        var envelope: [CGFloat]? = nil
        var progress: Double = 0

        private static let baseHeights: [CGFloat] = [
            8, 14, 22, 12, 28, 18, 32, 24, 16, 30, 20, 26, 14, 18
        ]

        var body: some View {
            TimelineView(.animation(minimumInterval: 0.04, paused: !isPlaying && !isLoading && !isLive)) { timeline in
                let date = timeline.date.timeIntervalSinceReferenceDate
                let heights = resolvedHeights
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<Self.baseHeights.count, id: \.self) { index in
                        let base = heights[index]
                        let factor: CGFloat = {
                            if isPlaying {
                                // 真实播放中：由真实实时电平 level (0...1) 驱动真实振幅
                                let normalizedLevel = CGFloat(max(0.08, min(1.0, level * 1.6)))
                                // 结合真实播放进度，播放头附近的条目具有更强的声学灵动性
                                let pos = Double(index) / Double(Self.baseHeights.count)
                                let isNearHead = abs(pos - progress) < 0.15
                                let dynamicMultiplier: CGFloat = isNearHead ? 1.25 : 0.85
                                return CGFloat(0.35 + 0.65 * normalizedLevel * dynamicMultiplier)
                            } else if isLoading {
                                // 生成请求中：温和呼吸波，明确提示正在计算准备中，绝不乱舞
                                let wave = sin(date * 3.5 + Double(index) * 0.35)
                                return CGFloat(0.45 + 0.25 * abs(wave))
                            } else if isLive {
                                // 麦克风录音对讲中：由真实输入电平驱动
                                let currentLevel = CGFloat(max(0.1, min(1.0, level * 3.0)))
                                let phase = date * 5.0 + Double(index) * 0.4
                                let sineAmplitude = CGFloat(abs(sin(phase)))
                                let modulation = currentLevel * (0.5 + 0.5 * sineAmplitude)
                                return 0.3 + 0.7 * modulation
                            } else {
                                return 0.4
                            }
                        }()
                        let barHeight = max(4, min(34, base * factor))
                        let isPlayed: Bool = {
                            guard isPlaying, progress > 0 else { return true }
                            return Double(index + 1) / Double(Self.baseHeights.count) <= progress + 0.08
                        }()
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(
                                isPlaying
                                    ? SpeechRailDesignTokens.Color.voice
                                    : (isLoading ? SpeechRailDesignTokens.Color.rail.opacity(0.8) : SpeechRailDesignTokens.Color.rail)
                            )
                            .frame(width: 3, height: barHeight)
                            .opacity(
                                isPlaying
                                    ? (isPlayed ? 0.95 : 0.35)
                                    : (isLoading ? 0.65 : (isLive ? 0.85 : 0.45))
                            )
                    }
                }
                .frame(height: 36)
            }
        }

        /// 真实音频幅度包络重采样为 14 根条；未加载完成则回退至标准声学基准轮廓
        private var resolvedHeights: [CGFloat] {
            guard let envelope, !envelope.isEmpty else { return Self.baseHeights }
            let peak: CGFloat = 32.0
            return AudioEnvelope.resample(envelope, to: Self.baseHeights.count).map {
                max(6, $0 * peak)
            }
        }
    }

    private struct ScenarioPrompt: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
        let prompt: String
    }

    private static let scenarioCards: [ScenarioPrompt] = [
        ScenarioPrompt(
            id: "critique",
            icon: "brain.head.profile",
            title: "批判性思辨与方案剖析",
            subtitle: "以尖锐视角深度审查架构边界与隐性风险",
            prompt: "请以批判性思维深度分析我接下来的方案，直指潜在漏洞与设计边界。"
        ),
        ScenarioPrompt(
            id: "actions",
            icon: "checklist.checked",
            title: "核心逻辑与行动项梳理",
            subtitle: "梳理繁杂材料，提炼清晰逻辑线与落地决策清单",
            prompt: "请帮我梳理手头材料的核心逻辑，并提炼为清晰的行动清单。"
        ),
        ScenarioPrompt(
            id: "rehearsal",
            icon: "waveform.and.mic",
            title: "即兴口语对讲与演练",
            subtitle: "模拟业务汇报与答辩，练习流利自然的口头表达",
            prompt: "我们来做一段即兴口语汇报练习，你来向我提出专业质询与提问。"
        ),
        ScenarioPrompt(
            id: "summarize",
            icon: "text.badge.checkmark",
            title: "精简提炼核心结论",
            subtitle: "去粗取精，用简明有力的口吻输出高价值决策摘要",
            prompt: "请用简练有力的口吻，为我提炼当前讨论的核心结论与三条关键要点。"
        )
    ]

    private var scenarioGrid: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack {
                Label("灵感场景与任务指引", systemImage: "sparkles")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer()
                Text("点击直接填入输入框，随时开麦发问")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: SpeechRailDesignTokens.Spacing.sm),
                    GridItem(.flexible(), spacing: SpeechRailDesignTokens.Spacing.sm)
                ],
                spacing: SpeechRailDesignTokens.Spacing.sm
            ) {
                ForEach(Self.scenarioCards) { item in
                    Button {
                        typed = item.prompt
                    } label: {
                        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs + 2) {
                            Image(systemName: item.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                .frame(width: 26, height: 26)
                                .background(
                                    SpeechRailDesignTokens.Color.rail.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                    .lineLimit(1)
                                Text(item.subtitle)
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(SpeechRailDesignTokens.Spacing.sm)
                        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                        .background(
                            SpeechRailDesignTokens.Color.field,
                            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                                .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("填入「\(item.prompt)」")
                }
            }
        }
    }

    private func recentSessionResumeBar(_ latest: SessionSummary) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(SpeechRailDesignTokens.Color.voice)
            Text("最近会话：")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Text(latest.record.title ?? "这一轮对话")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
            Text("· \(recordSubtitle(latest))")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .lineLimit(1)
            Spacer()
            Button("查看记录") {
                Task { await openRecord(latest) }
            }
            .font(SpeechRailDesignTokens.Typography.captionMedium)
            .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
        )
    }

    private var selectedPersonaSummary: String {
        let persona = preferences.persona(id: selectedPersonaID) ?? preferences.defaultPersona
        return personaSummary(persona)
    }

    /// 「未开始」态里的第三个可选项：对讲模式。
    ///
    /// 它和角色、声音一样是**开始前的选择**，所以收在同一行里。不这么做的话，想开「实时对讲
    /// （耳机）」的人只能去设置页改默认值再回来——而那正是用户点的「一次性设置不该到处拦人」
    /// 的反面（2026-09-19 低门槛改造）。状态带里那一句事实行本来就报这个值，这里让它可改。
    private var modeCard: some View {
        SessionPanel {
            SessionPanelHead(
                title: "对话方式",
                badge: nil,
                detail: "开始那一刻定下来，本次对话中途不变；新开一轮可以换（记录留着）。"
            )
            SessionHairline()
            ForEach(Array(AssistantMode.allCases.enumerated()), id: \.element.id) { index, option in
                if index > 0 { SessionHairline() }
                SessionCheckRow(
                    tone: option == mode ? .selected : .neutral,
                    name: option.title,
                    detail: option.detail
                ) {
                    Button {
                        mode = option
                        preferences.assistantMode = option
                    } label: {
                        StatusPill(
                            tone: option == mode ? .healthy : .neutral,
                            label: option == mode ? "已选" : "可选"
                        )
                    }
                    .buttonStyle(.plain)
                    .help("用这种方式开始下一轮")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var personaCard: some View {
        SessionPanel {
            SessionPanelHead(
                title: "角色（它怎么跟你说话）",
                badge: nil,
                detail: "只改它怎么答，不改它知道什么；记住的事在「记忆」那一栏。"
            )
            SessionHairline()
            ForEach(Array(preferences.personas.enumerated()), id: \.element.id) { index, persona in
                if index > 0 { SessionHairline() }
                SessionCheckRow(
                    tone: persona.id == selectedPersonaID ? .selected : .neutral,
                    name: persona.title,
                    detail: personaSummary(persona)
                ) {
                    Button {
                        selectedPersonaID = persona.id
                        preferences.defaultPersonaID = persona.id
                    } label: {
                        StatusPill(
                            tone: persona.id == selectedPersonaID ? .healthy : .neutral,
                            label: persona.id == selectedPersonaID ? "已选" : "可选"
                        )
                    }
                    .buttonStyle(.plain)
                    .help("用这条角色开始下一轮；开始之后本轮不再变")
                }
            }
            Spacer(minLength: 0)
            SessionHairline()
            CardFoot(note: "开始之后这一项变成只读：要换角色就新开一轮对话，记录不会丢。") {
                Button("新建自定义角色") {
                    personaDraft = PersonaDraft()
                    isCreatingPersona = true
                }
                .speechRailButton(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 人设那一行的说明。内置目录里每一条的正文是给模型看的，这里给的是给用户看的一句；
    /// 自定义人设没有预设说明，就摘正文的第一句。
    private func personaSummary(_ persona: Persona) -> String {
        if let summary = Self.personaSummaries[persona.id] { return summary }
        let firstSentence = persona.body
            .split(whereSeparator: { "。；\n".contains($0) })
            .first
            .map(String.init) ?? persona.body
        return firstSentence + "。"
    }

    private static let personaSummaries: [String: String] = [
        "patient": "默认：先给结论，再补一句为什么；适合边看材料边问。",
        "concise": "一次只答被问到的那件事，不展开；适合连续追问。",
        "reviewer": "先给结论与依据，再指不确定与反例；适合要做判断的时候。",
        "interpreter": "默认把中文译成自然的英文，只给译文；适合边听边用。"
    ]

    // MARK: 本机能做什么（未配置模型）

    /// 对话模型**就地配置**（2026-09-19 用户反馈「门槛极高」）。
    ///
    /// 为什么长在这一页：这是**必要时刻**——用户按「开始对话」时才知道要填这三样。
    /// 把人送去设置页，等于让他放下正在做的事、在一个有四组的表单里找到「会话」那一组，
    /// 填完再回来按第二次。这里只问三个字段，填完**原地开始**。
    ///
    /// 接口不在这里选：今天只走 Responses API（兼容 OpenAI 的那一套），给一个选择器
    /// 只会让"该选哪个"变成新的门槛；要换的地方在设置页，那里是给探索的人准备的。
    private var llmSetupCard: some View {
        SessionPanel {
            SessionPanelHead(
                title: "连一台模型服务就能说话",
                badge: "一次填好，长期有效",
                detail: "助手要连一台兼容 OpenAI 的模型服务才能回话。地址和模型名由那台服务给，"
                    + "密钥只存这把 Mac 的钥匙串。"
            )
            SessionHairline()
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                llmPresetsView
                SessionHairline()
                llmField(
                    label: "服务地址",
                    hint: "那台服务的地址，末尾不用带 /v1",
                    placeholder: "http://127.0.0.1:1234",
                    text: $llmBaseURLDraft,
                    isSecret: false
                )
                llmField(
                    label: "模型名",
                    hint: "服务端列出的名字，原样照抄",
                    placeholder: "例如 gpt-4o-mini",
                    text: $llmModelDraft,
                    isSecret: false
                )
                llmField(
                    label: "密钥",
                    hint: "那台服务不需要密钥就留空（如本地 Ollama）",
                    placeholder: "sk-…",
                    text: $llmKeyDraft,
                    isSecret: true
                )
                Text("接口固定走 Responses API（兼容 OpenAI 的那一套），不需要选。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                if let llmSaveNote {
                    Text(llmSaveNote)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(StatusTone.attention.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.md)
            CardFoot(note: "密钥通过本地安全加密保管（AES-GCM），不进配置文件，也不出现在日志中。") {
                Button("保存并开始对话") { Task { await saveLLMAndStart() } }
                    .speechRailButton(.primary)
                    .disabled(!canSaveLLM)
                    .help(canSaveLLM ? "存下这三样，立刻开始这一次对话" : "地址与模型名都要填")
            }
        }
    }

    private func llmField(
        label: String,
        hint: String,
        placeholder: String,
        text: Binding<String>,
        isSecret: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(label)
                .font(SpeechRailDesignTokens.Typography.bodyMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.hairline) {
                if isSecret {
                    SecureField(placeholder, text: text)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(placeholder, text: text)
                        .textFieldStyle(.roundedBorder)
                }
                Text(hint)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
        }
    }

    private var canSaveLLM: Bool {
        !llmBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !llmModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 存下这三样并**立刻开始**：按钮写着「保存并开始对话」，那就必须真的开始，
    /// 不能存完停在原地让人再找一次「开始对话」（那正是"点了没反应"的另一种写法）。
    private func saveLLMAndStart() async {
        preferences.llmBaseURL = llmBaseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.llmModel = llmModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try LLMKeychain.save(llmKeyDraft)
        } catch {
            llmSaveNote = "密钥没能存进钥匙串：\(error.localizedDescription)"
            return
        }
        llmSaveNote = nil
        llmKeyDraft = ""
        await start()
    }

    private var llmPresetsView: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack {
                Text("常用提供商一键填入：")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer()
                Button {
                    previewSelectedVoice()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 9))
                        Text("无需大模型：先试听音色原声")
                            .font(SpeechRailDesignTokens.Typography.caption)
                    }
                    .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                }
                .buttonStyle(.plain)
                .help("直接调用本地 Apple Silicon TTS 试听当前音色，感受本地声学质量")
            }
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                presetChip(title: "DeepSeek", url: "https://api.deepseek.com", model: "deepseek-chat")
                presetChip(title: "硅基流动", url: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-7B-Instruct")
                presetChip(title: "OpenAI", url: "https://api.openai.com/v1", model: "gpt-4o-mini")
                presetChip(title: "本地 Ollama", url: "http://localhost:11434/v1", model: "qwen2.5")
            }
        }
        .padding(.vertical, 2)
    }

    private func presetChip(title: String, url: String, model: String) -> some View {
        let isSelected = llmBaseURLDraft == url && llmModelDraft == model
        return Button {
            llmBaseURLDraft = url
            llmModelDraft = model
        } label: {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    isSelected ? SpeechRailDesignTokens.Color.rail.opacity(0.12) : SpeechRailDesignTokens.Color.field,
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(
                        isSelected ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Surface.border,
                        lineWidth: 1
                    )
                )
                .foregroundStyle(isSelected ? SpeechRailDesignTokens.Color.rail : SpeechRailDesignTokens.Color.ink)
        }
        .buttonStyle(.plain)
        .help("一键填入 \(title) 的地址与默认推荐模型")
    }

    private var capabilitiesCard: some View {
        SessionPanel {
            SessionPanelHead(
                title: "本机能做什么",
                badge: nil,
                detail: "照这台 Mac 现在的实际情况报，能用的就写能用。"
            )
            SessionHairline()
            ForEach(Array(capabilityRows.enumerated()), id: \.offset) { index, row in
                if index > 0 { SessionHairline() }
                HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Text(row.name)
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        .frame(width: 140, alignment: .leading)
                    StatusPill(tone: row.tone, label: row.pill)
                        .frame(width: 88, alignment: .leading)
                    Text(row.note)
                        .font(SpeechRailDesignTokens.Typography.callout)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
                .accessibilityElement(children: .contain)
            }
            Spacer(minLength: 0)
            SessionHairline()
            CardFoot(note: "设置里改完不用重启：连接检查会立刻给出结论。") { EmptyView() }
        }
        .frame(maxHeight: .infinity)
    }

    private var capabilityRows: [(name: String, tone: StatusTone, pill: String, note: String)] {
        // 只读服务健康快照，不猜：拿"列表里有没有某一类音色"当能力依据，会在服务已经
        // 发布能力时报出假的「未就绪」（服务状态页同一条口径）。
        let health = model.health
        func verdict(_ ready: Bool) -> (StatusTone, String) {
            ready ? (.healthy, "可用") : (.attention, "未就绪")
        }
        let asr = verdict(health?.asrReady == true)
        let tts = verdict(health?.ttsReady == true)
        let diarization = verdict(health?.diarizationReady == true)
        return [
            // 这一行只写"它是干什么的"：能不能用由左边那颗状态胶囊回答。
            // 原来那句尾巴是「……现在就能用」——服务没起来时它和「未就绪」正面打架
            // （2026-09-19 离屏走查，同一屏两句话说反）。
            ("语音识别", asr.0, asr.1, "实时字幕与会议记录都靠它。"),
            ("语音合成", tts.0, tts.1, "助手说话用它；音色可以在设置里换。"),
            ("谁在说话", diarization.0, diarization.1,
             "多人说话时自动标出每一句是谁说的（一号、二号…），只在这一场里有效，不用提前录声音。"),
            llmCapabilityRow
        ]
    }

    /// 「对话模型」这一行说的是**本机现在的配置**，不是「这一类能力有没有」。
    /// 模型配好了、只是因为别的理由受阻（麦克风被占、服务没起来）时，仍报「未配置」
    /// 就是这一屏第二处骗人的字（`BlockReason.title` 已经在说真正的原因）。
    private var llmCapabilityRow: (name: String, tone: StatusTone, pill: String, note: String) {
        guard preferences.isLLMConfigured else {
            return ("对话模型", .attention, "未配置",
                    "填一个兼容 OpenAI、且支持 Responses API 的服务地址与模型。")
        }
        return ("对话模型", .healthy, "已配置",
                "已指向 \(preferences.llmConfiguration.model)；可达性与接口是否对得上由设置页的「检查连接」回答。")
    }

    // MARK: 实时对讲主 Chat 工作台（对话中）

    private var liveChatWorkbenchCard: some View {
        SessionPanel(expandsVertically: true) {
            liveChatHeader
            SessionHairline()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if assistant.turns.isEmpty && assistant.partialText == nil && assistant.streamingReply == nil {
                            liveListeningWorkspace
                        } else {
                            ForEach(Array(assistant.turns.enumerated()), id: \.element.id) { index, turn in
                                turnRow(turn)
                                    .id(turn.id)
                            }
                            // 用户实时语音转写中
                            if let partial = assistant.partialText, !partial.isEmpty {
                                SessionTurnRow(who: "你", text: partial, isPartial: true, bodyWidth: bodyWidth)
                            }
                            // 助手思考态
                            if assistant.phase == .thinking && assistant.streamingReply == nil {
                                liveAssistantThinkingBubble
                            }
                            // 助手实时朗读回复流
                            if let streaming = assistant.streamingReply, !streaming.isEmpty {
                                SessionTurnRow(
                                    who: "助手", isVoice: true, voiceBadge: currentVoiceName,
                                    text: streaming, isPartial: true, bodyWidth: bodyWidth
                                )
                            }
                        }
                    }
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: assistant.turns.count) { _, _ in
                    guard let last = assistant.turns.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SessionHairline()
            liveChatIntegratedControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 对讲顶栏状态与控制

    private var liveChatHeader: some View {
        ViewThatFits(in: .horizontal) {
            liveChatHeaderRow
            liveChatHeaderWrapped
        }
    }

    private var liveChatHeaderRow: some View {
        HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            liveChatIdentity
            liveChatVoiceButton
            liveChatPhasePill

            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

            liveChatStats
            liveChatElapsed
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveChatHeaderWrapped: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.xs) {
                liveChatIdentity
                Spacer(minLength: 0)
                liveChatElapsed
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    liveChatVoiceButton
                    liveChatPhasePill
                    Spacer(minLength: 0)
                    liveChatStats
                }

                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        liveChatVoiceButton
                        liveChatPhasePill
                        Spacer(minLength: 0)
                    }
                    liveChatStats
                }
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveChatIdentity: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            ZStack {
                Circle()
                    .fill(SpeechRailDesignTokens.Color.rail.opacity(0.12))
                    .frame(width: 22, height: 22)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    .accessibilityHidden(true)
            }
            Text(activePersonaTitle)
                .font(SpeechRailDesignTokens.Typography.bodyMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private var liveChatVoiceButton: some View {
        Button {
            inspectorTab = .voice
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.wave.2")
                    .font(.system(size: 9))
                    .accessibilityHidden(true)
                Text(currentVoiceName ?? "默认音色")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                SpeechRailDesignTokens.Color.voice.opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(SpeechRailDesignTokens.Color.voice)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help("当前使用的朗读音色；点击在右栏切换音色，下一句生效")
    }

    private var liveChatPhasePill: some View {
        StatusPill(
            tone: assistant.isMuted ? .attention : (assistant.phase == .speaking ? .healthy : .neutral),
            label: livePhaseStatusLabel
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private var liveChatStats: some View {
        Text("已聊 \(liveExchangeCount) 轮 · 共 \(assistant.turns.count) 句")
            .font(SpeechRailDesignTokens.Typography.caption)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var liveChatElapsed: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(assistant.isMuted ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
            Text(formatElapsed(session.elapsed))
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .monospacedDigit()
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var livePhaseStatusLabel: String {
        if assistant.isMuted { return "麦克风已静音" }
        return assistant.phase.title
    }

    // MARK: - 助手思考中动效气泡

    private var liveAssistantThinkingBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(SpeechRailDesignTokens.Color.rail.opacity(0.12))
                    .frame(width: 26, height: 26)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
            }
            .padding(.top, 2)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text("助手正在思考与生成回答…")
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                SpeechRailDesignTokens.Color.field,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            )

            Spacer(minLength: 40)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, 4)
    }

    // MARK: - 正在聆听交互中心（刚开麦对话空态）

    private var liveListeningWorkspace: some View {
        VStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            Spacer(minLength: 20)

            // 呼吸式声学雷达指示
            ZStack {
                Circle()
                    .fill(SpeechRailDesignTokens.Color.rail.opacity(0.08))
                    .frame(width: 80, height: 80)
                Circle()
                    .stroke(SpeechRailDesignTokens.Color.rail.opacity(0.2), lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                Circle()
                    .fill(SpeechRailDesignTokens.Color.rail.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: assistant.isMuted ? "mic.slash.fill" : "waveform.and.mic")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(assistant.isMuted ? Color.orange : SpeechRailDesignTokens.Color.rail)
            }

            VStack(spacing: 4) {
                Text(assistant.isMuted ? "麦克风当前已静音" : "对讲已就绪，正在聆听您的声音")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(assistant.isMuted ? "点击下方「取消静音」即可开口对讲" : "请直接开口说话，或在下方输入文字（回车或 ⌘⏎ 发送）")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            // 快捷破冰话题推荐
            VStack(spacing: 8) {
                Text("快捷破冰提问：")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                HStack(spacing: 8) {
                    Button("👋 你好，介绍一下你自己") {
                        sendPrompt("你好，介绍一下你自己")
                    }
                    .speechRailButton(.secondary)

                    Button("💡 讲一个有趣的科技冷知识") {
                        sendPrompt("讲一个有趣的科技冷知识")
                    }
                    .speechRailButton(.secondary)

                    Button("🎙️ 测试朗读语速与音色效果") {
                        sendPrompt("请用当前音色朗读一段优美散文，测试音色效果")
                    }
                    .speechRailButton(.secondary)
                }
            }
            .padding(.top, SpeechRailDesignTokens.Spacing.sm)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
    }

    private func sendPrompt(_ text: String) {
        typed = text
        send()
    }

    // MARK: - 沉底集成式控制底座

    private var liveChatIntegratedControls: some View {
        ViewThatFits(in: .horizontal) {
            liveChatIntegratedControlsRow
            liveChatIntegratedControlsWrapped
        }
    }

    private var liveChatIntegratedControlsRow: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            liveChatMuteButton
            liveChatTextField
            if isAssistantSpeaking {
                liveChatStopButton
            }
            liveChatSendButton
            liveChatEndButton
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveChatIntegratedControlsWrapped: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                liveChatTextField
                liveChatSendButton
            }

            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                liveChatMuteButton
                if isAssistantSpeaking {
                    liveChatStopButton
                }
                Spacer(minLength: 0)
                liveChatEndButton
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveChatMuteButton: some View {
        Button {
            assistant.toggleMute()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: assistant.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
                Text(assistant.isMuted ? "取消静音" : "静音")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
            }
        }
        .speechRailButton(assistant.isMuted ? .primary : .secondary)
        .fixedSize(horizontal: true, vertical: false)
        .help(assistant.isMuted ? "取消静音，恢复麦克风拾音" : "静音麦克风，暂停语音输入")
    }

    private var liveChatTextField: some View {
        TextField("说点什么，或在此打字输入…", text: $typed)
            .textFieldStyle(.plain)
            .font(SpeechRailDesignTokens.Typography.body)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
            .padding(.vertical, 7)
            .background(
                SpeechRailDesignTokens.Color.inputField,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.borderStrong, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            }
            .onSubmit { send() }
            .disabled(!canCompose)
            .frame(maxWidth: .infinity)
    }

    private var liveChatStopButton: some View {
        Button {
            Task { await assistant.stopSpeaking() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: assistant.phase == .speaking ? "speaker.wave.2.fill" : "circle.dotted")
                    .font(.system(size: 10))
                    .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                    .accessibilityHidden(true)
                Image(systemName: "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
                Text("停止朗读")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
            }
        }
        .speechRailButton(.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .keyboardShortcut(.escape, modifiers: [])
        .help("停止当前语音朗读（Esc）；保留会话与上下文")
    }

    private var liveChatSendButton: some View {
        Button("发送") { send() }
            .speechRailButton(.primary)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!canCompose || typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
    }

    private var liveChatEndButton: some View {
        Button {
            Task { await endConversation() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "stop.circle")
                    .font(.system(size: 11))
                    .accessibilityHidden(true)
                Text("结束")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
            }
        }
        .speechRailButton(.quiet)
        .fixedSize(horizontal: true, vertical: false)
        .help("结束这次对话；记录会保存在记录库里")
    }

    private var isAssistantSpeaking: Bool {
        assistant.phase == .speaking || assistant.phase == .thinking
    }

    /// 对话正文的折行宽：收起右栏之后主框体变宽，正文跟着变宽（稿的收起态）。
    private var bodyWidth: CGFloat? {
        isInspectorCollapsed ? 1_128 : 760
    }

    private func turnRow(_ turn: AssistantSession.Turn) -> some View {
        let isAssistant = turn.role == .assistant
        var pills: [SessionTurnRow.Pill] = []
        if turn.isInterrupted {
            pills.append(.init(tone: .attention, label: "被打断"))
        }
        if turn.source == .keyboard {
            pills.append(.init(tone: .neutral, label: "打字"))
        }
        return SessionTurnRow(
            who: isAssistant ? "助手" : "你",
            isVoice: isAssistant,
            // 换过音色之后，**前面那些行仍是旧音色**——徽标要按变更点回推，
            // 而不是一律显示"现在选的那个"（稿 `换音色（下一句生效）` 的第一行
            // 是 夜航主持、后面才是 温柔讲解）。
            voiceBadge: isAssistant ? assistantVoiceName(at: turn.ordinal) : nil,
            pills: pills,
            // 稿上行右侧有时间码（`14:02:11`）；`SessionTurnRow` 一直支持它，
            // 只是这一页从没传过（2026-09-19 与 4K 稿并排比对）。
            timestamp: Self.clock(turn.createdAt),
            text: turn.text,
            bodyWidth: bodyWidth,
            // 「记住」放在最后：它是这一行上的第三个动作，前两个（重播 / 复制）是常用的，
            // 而它会**改变跨会话的行为**（写进下一轮的 system prompt），不适合排在最前面
            // 被顺手点掉。
            actions: isAssistant ? [.play, .copy, .remember] : [.copy, .remember],
            onAction: { action in
                switch action {
                case .play: Task { await assistant.replay(turn: turn) }
                case .copy: copy(turn.text)
                case .remember: Task { await remember(turn) }
                }
            }
        )
    }

    /// 把这一句写进长期记忆。
    ///
    /// 这一条链路此前**没有写入点**：`upsertMemory` 从头到尾没有调用者，于是「记忆」那一栏
    /// 永远只有空态——而它写的那句话（"它在对话里提议、你点头之后才会写进来"）描述的是一套
    /// 还没做的事。现在写入由**用户点这一行**发起，与那句话是同一件事：只有你说记住的才进去。
    ///
    /// 归类一律记成「事实」：分不出用户是在陈述事实还是表达偏好，就别替他判。**不静默积累**：
    /// 写进去的只有这一句，用户可以停用或移除（§16.5 记忆的写入要用户确认）。
    private func remember(_ turn: AssistantSession.Turn) async {
        guard let id = assistant.sessionID else {
            memoryNote = "这一段还没开始记（不在对话里），没有可以挂住记忆的地方。"
            return
        }
        do {
            try await session.upsertMemory(kind: .fact, body: turn.text, sourceSessionID: id)
            await reloadMemories()
            memoryNote = "已记住这一句，在右栏「记忆」里能停用或移除；下一轮开始生效。"
        } catch {
            memoryNote = "这一句没能写进记忆：\(error.localizedDescription)"
        }
    }

    /// 主动保存用户在记忆面板手动输入的长期记忆。
    private func saveNewMemory() async {
        let text = newMemoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = assistant.sessionID ?? "manual_user_preference"
        do {
            try await session.upsertMemory(kind: .preference, body: text, sourceSessionID: id)
            await reloadMemories()
            withAnimation {
                isAddingMemory = false
                newMemoryDraft = ""
            }
            memoryNote = "已记住新条目，在右栏「记忆」里可停用或移除；下一轮生效。"
        } catch {
            memoryNote = "记忆没能保存成功：\(error.localizedDescription)"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: 音色：某一句是谁的声音

    /// 第 `ordinal` 句的助手用的是哪个音色：取**这一句之前最后一次**变更；
    /// 一句都没换过就是本场开始那一刻那个。
    private func assistantVoiceName(at ordinal: Int) -> String? {
        if let change = assistant.voiceChanges.last(where: { $0.atOrdinal <= ordinal }) {
            return change.name ?? voiceName(forID: change.voiceID)
        }
        return voiceName(forID: assistant.startVoiceID ?? effectiveVoiceID)
    }

    private func voiceName(forID id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return model.creatorVoices.first { $0.id == id }?.name ?? id
    }

    /// `session_change.value` 存的是 `id|name`（改名或删除之后仍说得清当时是谁）。
    private func voiceName(fromChangeValue value: String) -> String {
        let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let id = String(parts.first ?? "")
        let stored = parts.count > 1 ? String(parts[1]) : nil
        return voiceName(forID: id) ?? stored ?? id
    }

    /// 行右侧那个墙上时间码。回看与对话中共用同一种格式，也就不会有"同一句话
    /// 在两屏显示成两种时间"这种事。
    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    // MARK: 音色（未开始，整行一张卡）

    private var voicesCard: some View {
        SessionPanel {
            SessionPanelHead(
                title: "音色",
                detail: nil,
                trailingDetail: "音色只影响朗读，所以开始之后仍然能随时换，下一句就听得见。"
            )
            SessionHairline()
            if voiceRows.isEmpty {
                // 空态也要说人话：音色列表来自本机语音服务，服务没起来（或还在加载）时
                // 这一栏会是空的。原来这里什么都不画，卡片只剩一行标题——看起来像坏了
                // （2026-09-19 离屏走查所见）。现在直说为什么空、以及不选也能开始。
                Text("还没读到可用的声音：音色由本机语音服务提供，它没起来或还在加载时这一栏是空的。"
                    + "不选也能开始，会用默认声音。")
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
            } else {
                ForEach(Array(pagedVoiceRows.enumerated()), id: \.element.id) { index, voice in
                    if index > 0 { SessionHairline() }
                    voiceRow(voice)
                }
                SessionHairline()
                voicePaginationBar
            }
        }
    }

    private func voiceRow(_ voice: CreatorVoice) -> some View {
        let isSelected = voice.id == effectiveVoiceID
        return HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight + 1) {
                Text(voice.name)
                    .font(SpeechRailDesignTokens.Typography.bodyMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                Text(voiceSubtitle(voice))
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusPill(tone: voice.available ? .healthy : .attention, label: voicePillLabel(voice, isSelected: isSelected))
            let isPlaying = model.isAudioPlaying && model.playingVoiceID == voice.id
            let isLoading = model.isCreatingSpeech && model.previewingVoiceID == voice.id
            Button {
                if isPlaying || isLoading {
                    model.stopAudio()
                } else {
                    Task { await model.previewVoice(voice) }
                }
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 16, height: 16)
                } else {
                    RowActionGlyph(systemImage: isPlaying ? "stop" : "play")
                }
            }
            .buttonStyle(.borderless)
            .disabled(!voice.available)
            .help(isPlaying ? "停止试听" : (isLoading ? "正在准备试听音频…" : (voice.available ? "试听 \(voice.name)" : "这个音色现在用不了")))
            .accessibilityLabel(isPlaying ? "停止试听" : "试听 \(voice.name)")
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, 10)
        .background(isSelected ? SpeechRailDesignTokens.Color.rail.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
            .onTapGesture {
                guard voice.available else { return }
                selectVoice(voice)
            }
        .accessibilityElement(children: .contain)
    }

    private func voiceSubtitle(_ voice: CreatorVoice) -> String {
        if !voice.available {
            return "这个音色现在用不了：服务端没有它的参考音频，或者当前识别精度下不加载它"
        }
        return voice.description.isEmpty ? "服务端可用音色" : voice.description
    }

    private func voicePillLabel(_ voice: CreatorVoice, isSelected: Bool) -> String {
        if !voice.available { return "现在用不了" }
        return isSelected ? "当前" : "可选"
    }

    private var voiceRows: [CreatorVoice] {
        model.creatorVoices
    }

    private var effectiveVoiceID: String {
        assistant.voiceID ?? selectedVoiceID
    }

    private var currentVoice: CreatorVoice? {
        model.creatorVoices.first { $0.id == effectiveVoiceID && $0.available }
    }

    private var currentVoiceName: String? {
        let id = effectiveVoiceID
        guard !id.isEmpty else { return nil }
        return model.creatorVoices.first { $0.id == id }?.name ?? id
    }

    /// 一个音色都没选时**生效的**东西：服务端自己的默认声音。
    /// 界面上只有一个说法——「默认声音」——可选项那一行与右栏事实行共用它。
    private static let defaultVoiceLabel = "默认声音"

    #if DEBUG
    /// 离屏渲染工装（`/tmp` 的 `NSHostingView`）用的**只写展示状态**夹具。
    ///
    /// 「记录库 · 刚结束」这一屏靠用户点开一条记录才会出现（`reviewRecord` 与 `inspectorTab`
    /// 都是这一页内部的状态，离屏点不了），所以在 2026-09-19 之前它一次都没有被渲染过——
    /// 而它正是"记录是资产"这句话的落点（记录库那一列、回看的右栏、刚结束的结论条都在这里）。
    /// 口径与 `CaptionSession.applyRenderFixture` 一致：只在 Debug 构建里存在，不读库、
    /// 不联网、不碰设备，也不改变任何产线行为。
    public enum RenderTab: Sendable {
        case session
        case voice
        case record
        case memory
    }

    public init(
        renderReview record: SessionRecord,
        lines: [TranscriptLine],
        speakerNames: [String: String] = [:],
        voiceChanges: [SessionChange] = [],
        memories: [AssistantMemory] = [],
        recent: [SessionSummary] = [],
        justEnded: Bool = false,
        tab: RenderTab = .session
    ) {
        // 必须写全 `SwiftUI.State`：这一页里有个同名的嵌套枚举 `State`（页面的四种态），
        // 它会把这个名字遮住。
        _reviewRecord = SwiftUI.State(initialValue: record)
        _reviewLines = SwiftUI.State(initialValue: lines)
        _reviewSpeakerNames = SwiftUI.State(initialValue: speakerNames)
        _reviewVoiceChanges = SwiftUI.State(initialValue: voiceChanges)
        _memories = SwiftUI.State(initialValue: memories)
        _recent = SwiftUI.State(initialValue: recent)
        _justEndedSessionID = SwiftUI.State(initialValue: justEnded ? record.id : nil)
        _inspectorTab = SwiftUI.State(initialValue: Self.tab(from: tab))
    }

    private static func tab(from tab: RenderTab) -> InspectorTab {
        switch tab {
        case .session: .session
        case .voice: .voice
        case .record: .record
        case .memory: .memory
        }
    }

    /// 只把右栏翻到某一页（不进记录库）。右栏那四页的**内容**靠这一页内部的状态选，
    /// 离屏点不到那排分段控件——而「音色」那一页与「记忆」那一页此前也一次都没被渲染过。
    public init(
        renderTab tab: RenderTab,
        memories: [AssistantMemory] = [],
        recent: [SessionSummary] = []
    ) {
        _inspectorTab = SwiftUI.State(initialValue: Self.tab(from: tab))
        _memories = SwiftUI.State(initialValue: memories)
        _recent = SwiftUI.State(initialValue: recent)
    }
    #endif

    private func selectVoice(_ voice: CreatorVoice) {
        selectedVoiceID = voice.id
        preferences.defaultVoiceID = voice.id
        // 名字一起交给会话层：`session_change` 那一列要能替代音色库说话
        // （音色改名或删除之后，这一场仍然说得清当时用的是谁）。
        Task { await assistant.changeVoice(to: voice.id, name: voice.name) }
    }

    private func previewSelectedVoice() {
        guard let voice = currentVoice else { return }
        Task { await model.previewVoice(voice) }
    }

    // MARK: 底部控制区（对话中 / 未配置模型）

    private var controlsCard: some View {
        SessionPanel {
            VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                controlsInputRow
                controlsSecondaryRow

                if state == .blocked {
                    Text(blockedControlsNote)
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        }
    }

    private var controlsInputRow: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            TextField(inputPlaceholder, text: $typed)
                .textFieldStyle(.plain)
                .font(SpeechRailDesignTokens.Typography.body)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                .background(
                    SpeechRailDesignTokens.Color.inputField,
                    in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                        .stroke(SpeechRailDesignTokens.Surface.borderStrong, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                }
                .onSubmit { send() }
                .disabled(!canCompose)
            Button("发送") { send() }
                .speechRailButton(.primary)
                .disabled(!canCompose || typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // §8 的「对话页：结束并发送」`⌘⏎`（与配音台同义）。Enter 仍然是
                // `onSubmit` 那条路，加上 ⌘ 之后是一条**带修饰键**的命令，
                // 不会跟输入框里的普通按键抢键。
                .keyboardShortcut(.return, modifiers: .command)

            if assistant.phase == .speaking || assistant.phase == .thinking {
                Button {
                    Task { await assistant.stopSpeaking() }
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("停止朗读")
                    }
                }
                .speechRailButton(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
                .help("立刻停止朗读当前回答（Esc）；保留会话与上下文")
            }
        }
        // 打字这条路的可用性与「能不能开口说话」**不是**同一件事（§6.1）：
        // 麦克风被占、服务正忙这几类受阻里，输入框照常亮着，所以淡出只作用在
        // 用不了的那一行上，而不是整张卡（整卡 0.45 会让能用的输入框看起来也是坏的）。
        .opacity(canCompose ? 1 : 0.45)
    }

    private var controlsSecondaryRow: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            if isLive {
                Button(assistant.isMuted ? "取消静音" : "静音麦克风") {
                    assistant.toggleMute()
                }
                .speechRailButton(.secondary)
                .help("只是暂时不说了；对话、记录都留着。要结束用页头的「结束对话」")

                livePersonaBadge
                controlsModeIndicator
            } else {
                Button {
                    Task { await start() }
                } label: {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 11, weight: .bold))
                        Text("开麦对讲")
                    }
                }
                .speechRailButton(.primary)
                .help("开启双向语音对讲，对着麦克风说话即可交流")

                idlePersonaCapsule
                controlsModeIndicator
            }

            Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

            // 音色随时换：SpeechRail 音色库支持的任何音色（分组并支持直通工坊）
            SessionVoiceCapsule(name: currentVoiceName ?? "未选音色") {
                let custom = customVoices
                if !custom.isEmpty {
                    Section("我的定制与克隆声音") {
                        ForEach(custom) { voice in
                            Button {
                                selectVoice(voice)
                            } label: {
                                HStack {
                                    Text(voice.name)
                                    if voice.id == effectiveVoiceID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
                let system = systemVoices.isEmpty ? voiceRows : systemVoices
                Section("系统预置声音") {
                    ForEach(system) { voice in
                        Button {
                            selectVoice(voice)
                        } label: {
                            HStack {
                                Text(voice.name)
                                if voice.id == effectiveVoiceID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("🎙️ 录制专属声音（音色克隆）…") {
                    navigation.request(.voiceClone)
                }
                Button("✨ 创作新音色（音色创作）…") {
                    navigation.request(.voiceDesign)
                }
                Button("📚 打开音色库管理…") {
                    navigation.request(.voiceLibrary)
                }
            }

            // 一键试听当前选中的声音
            if let voice = currentVoice {
                let isPlaying = model.isAudioPlaying && model.playingVoiceID == voice.id
                let isLoading = model.isCreatingSpeech && model.previewingVoiceID == voice.id
                Button {
                    if isPlaying || isLoading {
                        model.stopAudio()
                    } else {
                        Task { await model.previewVoice(voice) }
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: isPlaying ? "stop.circle.fill" : "speaker.wave.2.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                    }
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "停止试听" : (isLoading ? "正在准备试听音频…" : "随时试听当前音色：\(voice.name)"))
            }
        }
        .opacity(state == .blocked ? 0.45 : 1)
    }

    /// 待机态下的角色风格切换胶囊
    private var idlePersonaCapsule: some View {
        Menu {
            ForEach(preferences.personas) { p in
                Button {
                    selectedPersonaID = p.id
                    preferences.defaultPersonaID = p.id
                } label: {
                    HStack {
                        Text(p.title)
                        if p.id == selectedPersonaID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "theatermasks")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(selectedPersonaTitle)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
            .padding(.vertical, 4)
            .background(
                SpeechRailDesignTokens.Color.field,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            )
        }
        .menuStyle(.borderlessButton)
        .help("对话角色（风格）：开始前可自由选择，开始之后本轮会话中途锁定")
    }

    /// 会话中风格严格锁定：不切换会话不能更换风格
    private var livePersonaBadge: some View {
        Menu {
            Text("当前会话已绑定角色：「\(selectedPersonaTitle)」")
            Text("按设计规范，中途更换风格会导致上下文认知混乱。")
            Divider()
            Button("结束当前会话，并以新角色开新对话…") {
                Task { await restartWithPersonaPick() }
            }
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                Image(systemName: "theatermasks")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(selectedPersonaTitle)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                StatusPill(tone: .neutral, label: "本轮锁定")
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
            .padding(.vertical, 4)
            .background(
                SpeechRailDesignTokens.Color.field,
                in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
            )
        }
        .menuStyle(.borderlessButton)
        .help("风格已绑定当前会话。不切换会话不能更换风格；点击可结束并新开一轮。")
    }

    private var liveModeIconName: String {
        assistant.mode == .duplex ? "waveform.and.mic" : "bubble.left.and.bubble.right"
    }

    private var liveModeBadge: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
            Image(systemName: liveModeIconName)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Text(assistant.mode.title)
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            StatusPill(tone: .neutral, label: "本轮已定")
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, 4)
        .background(
            SpeechRailDesignTokens.Color.field,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
        )
        .help("本次对话的方式在开始那一刻定下了：" + assistant.mode.detail + "。新开一轮可以换。")
    }

    @ViewBuilder
    private var controlsModeIndicator: some View {
        if isLive {
            liveModeBadge
        } else {
            Picker("对讲模式", selection: $mode) {
                ForEach(AssistantMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: mode) { _, newMode in
                preferences.assistantMode = newMode
            }
            .help("选择下一轮对话的方式：" + mode.detail)
        }
    }

    private var inputPlaceholder: String {
        state == .ready
            ? "直接打字发问（↵ 发送 · 静音不朗读）…"
            : "输入消息（↵ 发送 · 静音不朗读）…"
    }

    /// 受阻时底部那行小字：说清楚**现在能用哪一条路**，而不是一律说「配好模型就会亮」。
    private var blockedControlsNote: String {
        guard let reason = blockedReason else { return "" }
        if reason.allowsTyping {
            return "打字是现在就能用的那条路：文字不经过麦克风，回答也只读给你听（点一下播放）。"
        }
        return reason == .llmNotConfigured
            ? "配好对话模型后这里会亮起来。"
            : "解决上面那一条之后，这里就会亮起来。"
    }

    private var canCompose: Bool {
        switch state {
        case .live: true
        case .ready: true
        case .blocked: blockedReason?.allowsTyping == true
        default: false
        }
    }

    private func send() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if state == .ready && !preferences.isLLMConfigured {
            withAnimation { isShowingQuickLLM = true }
            return
        }
        typed = ""
        Task {
            if state == .ready {
                await start()
                let deadline = Date().addingTimeInterval(3.0)
                while Date() < deadline && assistant.sessionID == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            await assistant.ask(typed: text)
        }
    }

    // MARK: - 右栏（非主框体）

    private var inspectorColumn: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            inspectorPanel
                .frame(width: SpeechRailDesignTokens.Layout.sessionInspectorWidth, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var inspectorPanel: some View {
        SessionPanel(expandsVertically: true) {
            SessionPanelHead(title: headlineTitle, badge: headlineBadge)
            SessionHairline()
            if state != .review {
                segmentedTabs
                SessionHairline()
            }
            Group {
                switch inspectorTab {
                case .session:
                    factsTabBody
                case .voice:
                    voiceTabBody
                case .record:
                    recordTabBody
                case .memory:
                    memoryTabBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: SpeechRailDesignTokens.Layout.sessionInspectorWidth)
        .frame(maxHeight: .infinity)
    }

    private var headlineTitle: String {
        if state == .review { return "记录信息" }
        switch inspectorTab {
        case .session:
            return state == .live ? "会话运行状态" : "会话环境信息"
        case .voice:
            return "音色库与试听"
        case .record:
            return "历史对话归档"
        case .memory:
            return "长期记忆资产"
        }
    }

    private var headlineBadge: String {
        if state == .review { return "已归档 · 本地留存" }
        switch inspectorTab {
        case .session:
            switch state {
            case .ready: return "待机就绪"
            case .blocked: return "需要注意"
            case .live: return "对讲进行中"
            case .review: return "已归档"
            }
        case .voice:
            let count = model.creatorVoices.count
            return count > 0 ? "\(count) 个可用音色" : (model.isRefreshingCreatorVoices ? "正在读取…" : "未读取到")
        case .record:
            return recent.isEmpty ? "暂无记录" : "\(recent.count) 段对话"
        case .memory:
            return memories.isEmpty ? "暂无条目" : "\(memories.count) 条记忆"
        }
    }

    private var segmentedTabs: some View {
        HStack {
            Picker("", selection: $inspectorTab.animation(.easeInOut(duration: 0.12))) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
    }

    private var factsTabBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state == .live {
                liveFactsCard
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.top, SpeechRailDesignTokens.Spacing.md)
                    .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(factRows.enumerated()), id: \.offset) { _, row in
                        SessionKVRow(row.0, row.1)
                    }
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.top, SpeechRailDesignTokens.Spacing.md)
                .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)
            }

            SessionHairline()

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(factsNoteTitle)
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text(factsNote)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)

            acousticPipelineCard
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.top, SpeechRailDesignTokens.Spacing.xs)

            Spacer(minLength: 0)
            SessionHairline()
            SessionPanelActions(alignment: .spread) {
                if state == .ready {
                    Button("检查输入电平") { isCheckingInput = true }
                        .speechRailButton(.secondary)
                } else if state == .blocked {
                    Button("检查连接") { Task { await assistant.retry() } }
                        .speechRailButton(.secondary)
                        .disabled(!preferences.isLLMConfigured)
                        .help(
                            preferences.isLLMConfigured
                                ? "重新走一遍连通性与接口检查"
                                : "还没填服务地址与模型；先在「设置 · 会话」里填好，再来点它"
                        )
                } else if state == .live {
                    Button("🎨 换音色") { inspectorTab = .voice }
                        .speechRailButton(.secondary)
                    Button("🔄 新开一轮换角色") { Task { await restartWithPersonaPick() } }
                        .speechRailButton(.secondary)
                }
            }
        }
    }

    private var liveFactsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实时对讲链路")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Spacer()
                StatusPill(tone: .healthy, label: "已连线")
            }

            VStack(alignment: .leading, spacing: 8) {
                SessionKVRow("对话模型", assistant.llmModel ?? "未连接")
                SessionKVRow("当前音色", "\(currentVoiceName ?? Self.defaultVoiceLabel) · 下一句生效")
                SessionKVRow("对话角色", "\(activePersonaTitle) · 本轮已锁定")
                SessionKVRow("打断策略", assistant.mode.detail)
                SessionKVRow("拾音设备", microphoneLabel)
                SessionKVRow("交互进度", "\(liveExchangeCount) 轮 · 共 \(assistant.turns.count) 句")
            }
        }
    }

    private var acousticPipelineCard: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 11))
                    .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                Text("声学链路与硬件运行")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Spacer()
                StatusPill(tone: .healthy, label: "本地私有")
            }
            Text("实时麦克风电平动态感应，音频 PCM 纯内存流转、绝不落盘；识别与合成均由 Apple Silicon 独立单元驱动。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SpeechRailDesignTokens.Spacing.sm)
        .background(
            SpeechRailDesignTokens.Color.recessedField,
            in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
        )
    }

    /// 「几轮」= **一问一答**算一轮，所以按"你说了几次"数，不按行数。
    ///
    /// 每一行都叫一轮的时候，一问一答之后右栏就写着「已聊 2 轮」、页头写「第 2 轮」——
    /// 数字对得上行数，说法对不上用户的理解（2026-09-19 离屏走查）。
    private var liveExchangeCount: Int {
        assistant.turns.filter { $0.role == .user }.count
    }

    private var reviewExchangeCount: Int {
        reviewLines.filter { $0.role == .user }.count
    }

    /// 现在这一路声音是从哪个麦克风进来的（稿：`麦克风 MacBook 麦克风`）。
    ///
    /// 名字读不到就退回「系统默认」——不让这一行变成空的，也不假装知道。
    private var microphoneLabel: String {
        MicrophoneCapture.defaultInputDeviceName ?? "系统默认"
    }

    /// 记录里那一份音色快照（音色被删或改名之后，旧记录仍然说得清当时用的是谁）。
    private var reviewVoiceLabel: String {
        guard let voice = reviewRecord?.voice else { return Self.defaultVoiceLabel }
        return voice.name ?? (voice.id.isEmpty ? Self.defaultVoiceLabel : voice.id)
    }

    private var factRows: [(String, String)] {
        switch state {
        case .ready:
            [
                // 「已配置」不是「已连接」：这一行读的是**填过没有**，还没发过一次请求。
                // 能不能连上由设置页的「检查连接」回答（2026-09-19 走查：上一版写「已连接」，
                // 地址写错时这一屏照样说连上了）。
                ("对话模型", preferences.isLLMConfigured
                    ? "已配置 · \(preferences.llmConfiguration.model)"
                    : "未配置"),
                ("输入方式", "语音或打字"),
                ("对话方式", mode.title),
                ("麦克风", microphoneLabel),
                ("角色", "\(selectedPersonaTitle) · 本轮定"),
                // 没选音色时真正生效的是服务端的默认声音（`AssistantSession` 不传 id 就是它），
                // 所以这里与上面那行可选项说同一句话：默认声音。原来写「未选」，
                // 同一屏就出现「默认声音」与「未选」两种说法（2026-09-19 离屏走查）。
                ("音色", currentVoiceName ?? Self.defaultVoiceLabel)
            ]
        case .blocked:
            [
                ("大模型", "未配置"),
                ("服务地址", preferences.llmBaseURL.isEmpty ? "—" : preferences.llmBaseURL),
                ("密钥", hasStoredKey ? "已存钥匙串" : "—"),
                ("音色", currentVoiceName ?? Self.defaultVoiceLabel),
                ("角色", selectedPersonaTitle),
                ("麦克风", microphoneLabel)
            ]
        case .live:
            [
                ("大模型", assistant.llmModel ?? "未配置"),
                ("音色", "\(currentVoiceName ?? Self.defaultVoiceLabel) · 下一句可换"),
                ("角色", "\(activePersonaTitle) · 本轮已定"),
                // 「插话」问的是**我能不能打断它**，取值直接用模式自己那句话
                // （`AssistantMode.detail`）。原来这一行的标签是「打断」、取值是
                // 「一问一答：它说话时闭麦」——标签像个状态、取值在讲另一种模式，
                // 读两遍也不知道到底能不能插话（2026-09-19 离屏走查）。
                ("插话", assistant.mode.detail),
                ("已聊", "\(liveExchangeCount) 轮 · 共 \(assistant.turns.count) 句"),
                ("输入", "语音或打字"),
                ("麦克风", microphoneLabel)
            ]
        case .review:
            // 回看态现在由 `reviewArea` 负责「记录列表 + 正文」两栏；若记录事实卡被复用，
            // 仍然读取这一条记录自己的快照，而不是此刻还开着的那一轮（§14.4）。
            // 对话方式没进记录（`session` 表没有这一列），所以这里不摆那一行，也不猜。
            [
                ("大模型", reviewRecord?.llmModel ?? "未记录"),
                ("音色", reviewVoiceLabel),
                ("角色", reviewRecord?.persona?.title ?? "默认角色"),
                ("已聊", "\(reviewExchangeCount) 轮 · 共 \(reviewLines.count) 句"),
                // 记录摘要给的是**结束于 / 轮数 / 时长**：
                // 翻一条旧记录时先想知道的是"哪一段、多久"，而不是它从几点开始。
                ("结束于", reviewRecord.map {
                    ($0.endedAt ?? $0.startedAt).formatted(date: .numeric, time: .shortened)
                } ?? "—"),
                ("时长", reviewDurationText)
            ]
        }
    }

    private var reviewDurationText: String {
        guard let record = reviewRecord else { return "—" }
        let end = record.endedAt ?? record.startedAt
        let seconds = max(0, end.timeIntervalSince(record.startedAt))
        return SessionExporter.clock(seconds)
    }

    private var factsNoteTitle: String {
        switch state {
        case .ready: "打字提问时为什么不朗读"
        case .blocked: "配好之后"
        case .review: "关于这一段"
        default: "关于这一栏"
        }
    }

    private var factsNote: String {
        switch state {
        case .ready:
            "「我在打字」通常说明我在静音场景：回复只出现在这里，点一下播放按钮才会读出来。"
                + "想边听边说，切到实时对讲（耳机）。"
        case .blocked:
            // 这一句原来写「这里会显示模型名、连接延迟与记忆轮数」——上面那六行里
            // 从来没有连接延迟，也没有记忆轮数（2026-09-19 离屏走查）。说清这一栏现在
            // 到底给什么，比预告三样不存在的东西有用。
            "上面是现在填了什么；能不能连上由设置页的「检查连接」回答。"
                + "对话从第一轮开始记，之前的不用补。"
        case .review:
            "这一段用的是当时的角色与声音，它们随记录一起存下来。"
                + "换角色或音色只影响下一轮，这条记录一个字都不动。"
        default:
            "角色改的是它怎么和你说话，本轮锁住；音色只改声音，下一句就换。"
        }
    }

    /// 右栏的「音色」页：换音色与换角色的区别都摆在这一屏上（稿
    /// `语音助手 · 对话页 · 换音色（下一句生效）`：那一屏的右栏就是一张音色表 + 一块
    /// 人设只读区）。
    ///
    /// 它存在的理由有两层：一是稿上「换音色」那颗按钮通向的就是它，而上一版把它接到
    /// 「记录」页去了（按下去看到的是记录列表）；二是 `inspectorTab` 的默认值原先在
    /// 分段控件里没有对应项，切走就回不来（2026-09-19 离屏走查）。
    private var filteredVoiceRows: [CreatorVoice] {
        let base = voiceRows.filter { voice in
            switch voiceFilterScope {
            case .all: true
            case .custom: !voice.isSystem
            case .system: voice.isSystem
            }
        }
        let query = voiceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    private var totalVoicePages: Int {
        let count = filteredVoiceRows.count
        guard count > 0 else { return 1 }
        return max(1, Int(ceil(Double(count) / Double(voicePageSize))))
    }

    private var pagedVoiceRows: [CreatorVoice] {
        let items = filteredVoiceRows
        guard !items.isEmpty else { return [] }
        let safeIndex = min(max(0, voicePageIndex), totalVoicePages - 1)
        let start = safeIndex * voicePageSize
        guard start < items.count else { return [] }
        let end = min(start + voicePageSize, items.count)
        return Array(items[start..<end])
    }

    private var voicePaginationBar: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Text("第 \(voicePageIndex + 1) / \(totalVoicePages) 页")
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)

            Text("· 共 \(filteredVoiceRows.count) 个音色")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Button {
                    if voicePageIndex > 0 {
                        voicePageIndex -= 1
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 8, weight: .bold))
                        Text("上一页")
                    }
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        voicePageIndex > 0 ? SpeechRailDesignTokens.Color.field : Color.clear,
                        in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                            .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(voicePageIndex <= 0)
                .opacity(voicePageIndex <= 0 ? 0.35 : 1.0)

                Button {
                    if voicePageIndex < totalVoicePages - 1 {
                        voicePageIndex += 1
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text("下一页")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        voicePageIndex < totalVoicePages - 1 ? SpeechRailDesignTokens.Color.field : Color.clear,
                        in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                            .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(voicePageIndex >= totalVoicePages - 1)
                .opacity(voicePageIndex >= totalVoicePages - 1 ? 0.35 : 1.0)
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, 6)
        .background(SpeechRailDesignTokens.Color.recessedField.opacity(0.6))
    }

    private var voiceTabBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 搜索框与分类过滤（支持海量音色毫秒级检索）
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    TextField("搜索音色名或特点…", text: $voiceSearchQuery)
                        .textFieldStyle(.plain)
                        .font(SpeechRailDesignTokens.Typography.body)
                    if !voiceSearchQuery.isEmpty {
                        Button {
                            voiceSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                .padding(.vertical, 6)
                .background(
                    SpeechRailDesignTokens.Color.inputField,
                    in: RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                        .stroke(SpeechRailDesignTokens.Surface.borderStrong, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                )

                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    ForEach(VoiceFilterScope.allCases) { scope in
                        Button {
                            voiceFilterScope = scope
                        } label: {
                            Text(scope.rawValue)
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    voiceFilterScope == scope
                                        ? SpeechRailDesignTokens.Color.rail.opacity(0.15)
                                        : SpeechRailDesignTokens.Color.field,
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().stroke(
                                        voiceFilterScope == scope
                                            ? SpeechRailDesignTokens.Color.rail
                                            : SpeechRailDesignTokens.Surface.border,
                                        lineWidth: 1
                                    )
                                )
                                .foregroundStyle(
                                    voiceFilterScope == scope
                                        ? SpeechRailDesignTokens.Color.rail
                                        : SpeechRailDesignTokens.Color.ink
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if model.isRefreshingCreatorVoices {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.top, SpeechRailDesignTokens.Spacing.sm)
            .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)

            SessionHairline()

            // 当前朗读生效音色高亮卡片
            activeVoiceCard

            SessionHairline()

            // 分页音色列表：单页限制条数，告别超长铺满
            if voiceRows.isEmpty {
                VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Spacer()
                    if model.isRefreshingCreatorVoices {
                        ProgressView("正在从本机服务读取音色…")
                            .font(SpeechRailDesignTokens.Typography.caption)
                    } else {
                        Image(systemName: "waveform.badge.exclamationmark")
                            .font(.system(size: 24))
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                        Text("还没有读取到可用音色")
                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                        Text("服务可能刚刚启动，点击下方按钮重新读取。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                        Button("重新读取音色") {
                            Task { await model.refreshCreatorVoices() }
                        }
                        .speechRailButton(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else if filteredVoiceRows.isEmpty {
                VStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    Text("未找到匹配的音色")
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Button("清除搜索") {
                        voiceSearchQuery = ""
                        voiceFilterScope = .all
                    }
                    .speechRailButton(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pagedVoiceRows.enumerated()), id: \.element.id) { index, voice in
                        if index > 0 { SessionHairline() }
                        voiceRow(voice)
                    }
                }
                .frame(minHeight: 220, alignment: .top)

                SessionHairline()
                voicePaginationBar
            }

            SessionHairline()
            personaLockBlock
            Spacer(minLength: 0)
            SessionHairline()
            SessionPanelActions(alignment: .spread) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Button("🎙️ 录音克隆…") {
                        navigation.request(.voiceClone)
                    }
                    .speechRailButton(.secondary)
                    .help("录制 10~30 秒样本，克隆专属音色")

                    Button("✨ 创作音色…") {
                        navigation.request(.voiceDesign)
                    }
                    .speechRailButton(.secondary)
                    .help("用提示词创作新音色")
                }

                Button("回到会话") { inspectorTab = .session }
                    .speechRailButton(.primary)
            }
        }
    }

    /// 紧凑角色说明区：告知用户角色在新轮次前已定，而音色随时可换且下一句生效。
    private var personaLockBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .accessibilityHidden(true)
                Text("对话角色：\(activePersonaTitle)")
                    .font(SpeechRailDesignTokens.Typography.captionMedium)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                StatusPill(tone: .neutral, label: "会话锁定")
                Spacer()
            }
            Text("角色设定仅在新开会话前可选；朗读音色可随时在上方切换并于下一句生效。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .background(SpeechRailDesignTokens.Color.recessedField.opacity(0.35))
    }

    private var activeVoiceCard: some View {
        let currentVoice = model.creatorVoices.first(where: { $0.id == effectiveVoiceID })
        let name = currentVoice?.name ?? currentVoiceName ?? Self.defaultVoiceLabel
        let isPlaying = model.isAudioPlaying && model.playingVoiceID == currentVoice?.id
        let isLoading = model.isCreatingSpeech && model.previewingVoiceID == currentVoice?.id

        return HStack(alignment: .center, spacing: SpeechRailDesignTokens.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(SpeechRailDesignTokens.Color.voice.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SpeechRailDesignTokens.Color.voice)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Text(name)
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    StatusPill(tone: .healthy, label: "当前生效")
                }
                Text("下一句朗读时将使用此音色输出")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            Spacer()

            if let voice = currentVoice {
                Button {
                    if isPlaying || isLoading {
                        model.stopAudio()
                    } else {
                        Task { await model.previewVoice(voice) }
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16, height: 16)
                    } else {
                        HStack(spacing: 3) {
                            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text(isPlaying ? "停止" : "试听")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                        }
                    }
                }
                .speechRailButton(.secondary)
                .help(isPlaying ? "停止试听" : "试听当前生效的音色")
            }
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, 8)
        .background(SpeechRailDesignTokens.Color.voice.opacity(0.06))
    }

    private var recordTabBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SessionKVRow("当前会话", "\(liveExchangeCount) 轮 · 共 \(assistant.turns.count) 句")
                SessionKVRow("历史归档", recent.isEmpty ? "还没有对话记录" : "\(recent.count) 段 · 本地加密留存")
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.top, SpeechRailDesignTokens.Spacing.md)
            .padding(.bottom, SpeechRailDesignTokens.Spacing.sm)

            SessionHairline()

            if recent.isEmpty {
                VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 24))
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    Text("还没有对话记录")
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("结束一轮对话后，它会自动归档在此处。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(recent.prefix(8).enumerated()), id: \.element.id) { _, summary in
                            Button {
                                Task { await openRecord(summary) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                        Text(summary.record.title ?? "未命名对话")
                                            .font(SpeechRailDesignTokens.Typography.bodyMedium)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                            .lineLimit(1)
                                        Spacer()
                                        StatusPill(tone: .neutral, label: "\(summary.lineCount) 句")
                                    }

                                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                                        if let persona = summary.record.persona?.title {
                                            Text(persona)
                                                .font(SpeechRailDesignTokens.Typography.caption)
                                                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                                            Text("·")
                                                .font(SpeechRailDesignTokens.Typography.caption)
                                                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                        }
                                        Text(recordSubtitle(summary))
                                            .font(SpeechRailDesignTokens.Typography.caption)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                                .padding(.vertical, 8)
                                .background(
                                    SpeechRailDesignTokens.Color.field,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                                )
                            }
                            .buttonStyle(.plain)
                            .speechRailPointerCursor()
                        }
                    }
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                }
            }

            Spacer(minLength: 0)
            SessionHairline()
            SessionPanelActions(alignment: .spread) {
                Button("查看完整记录库") {
                    if let first = recent.first {
                        Task { await openRecord(first) }
                    }
                }
                .speechRailButton(.secondary)
                .disabled(recent.isEmpty)

                Button("回到会话") { inspectorTab = .session }
                    .speechRailButton(.primary)
            }
        }
    }

    private func recordSubtitle(_ summary: SessionSummary) -> String {
        "\(summary.record.startedAt.formatted(date: .numeric, time: .shortened)) · \(summary.lineCount) 句"
    }

    private var memoryTabBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("长期记忆资产")
                        .font(SpeechRailDesignTokens.Typography.captionMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("自动注入提示词上下文，下一轮起效")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                }
                Spacer()
                Button(isAddingMemory ? "取消" : "+ 添加记忆") {
                    withAnimation {
                        isAddingMemory.toggle()
                        newMemoryDraft = ""
                    }
                }
                .speechRailButton(.secondary)
            }
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            .padding(.top, SpeechRailDesignTokens.Spacing.sm)
            .padding(.bottom, SpeechRailDesignTokens.Spacing.xs)

            SessionHairline()

            if isAddingMemory {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.tight) {
                    TextField("输入要记住的事（如：回答优先使用 Swift）…", text: $newMemoryDraft)
                        .textFieldStyle(.plain)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                        .padding(.vertical, 6)
                        .background(
                            SpeechRailDesignTokens.Color.inputField,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(SpeechRailDesignTokens.Surface.borderStrong, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                        )
                        .onSubmit { Task { await saveNewMemory() } }

                    HStack {
                        Spacer()
                        Button("取消") {
                            withAnimation {
                                isAddingMemory = false
                                newMemoryDraft = ""
                            }
                        }
                        .speechRailButton(.secondary)

                        Button("保存") { Task { await saveNewMemory() } }
                            .speechRailButton(.primary)
                            .disabled(newMemoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
                SessionHairline()
            }

            if memories.isEmpty && !isAddingMemory {
                VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Spacer()
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 24))
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    Text("还没有长期记忆")
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text("在对话中点击句末「记住」或上方添加，内容将在下一轮开始起效。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(memories.enumerated()), id: \.element.id) { _, memory in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.xs) {
                                    Text(memory.body)
                                        .font(SpeechRailDesignTokens.Typography.body)
                                        .foregroundStyle(memory.isActive ? SpeechRailDesignTokens.Color.ink : SpeechRailDesignTokens.Color.inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    StatusPill(
                                        tone: memory.isActive ? .healthy : .neutral,
                                        label: memory.isActive ? memoryKindTitle(memory.kind) : "已停用"
                                    )
                                }

                                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                                    Button(memory.isActive ? "停用" : "启用") {
                                        Task {
                                            try? await session.setMemoryActive(id: memory.id, active: !memory.isActive)
                                            await reloadMemories()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)

                                    Button("移除") {
                                        Task {
                                            try? await session.removeMemory(id: memory.id)
                                            await reloadMemories()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .font(SpeechRailDesignTokens.Typography.caption)
                                    .foregroundStyle(Color.red.opacity(0.8))
                                }
                            }
                            .padding(.horizontal, SpeechRailDesignTokens.Spacing.sm)
                            .padding(.vertical, 8)
                            .background(
                                SpeechRailDesignTokens.Color.field,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(SpeechRailDesignTokens.Surface.border, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                            )
                        }
                    }
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                }
            }

            Spacer(minLength: 0)
            SessionHairline()
            SessionPanelActions(alignment: .spread) {
                Text(memories.isEmpty ? "记忆留存本机" : "已记录 \(memories.count) 条记忆资产")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                Button("回到会话") { inspectorTab = .session }
                    .speechRailButton(.primary)
            }
        }
    }



    private func memoryKindTitle(_ kind: AssistantMemoryKind) -> String {
        switch kind {
        case .preference: "偏好"
        case .fact: "事实"
        case .summary: "摘要"
        }
    }

    // MARK: - 记录库（刚结束 / 回看）

    private var reviewArea: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            SessionLibraryColumn(
                kind: .assistant,
                title: "对话记录",
                foot: "搜索标题与正文；记录长期留在记录库，App 重启也在。",
                selectedID: reviewRecord?.id,
                reloadToken: libraryReloadToken,
                onSelect: { summary in Task { await openRecord(summary) } }
            )
            .frame(width: SpeechRailDesignTokens.Layout.sessionListWidth)
            .frame(maxHeight: .infinity)

            SessionPanel(expandsVertically: true) {
                SessionPanelHead(title: reviewRecord?.title ?? "这一轮对话", detail: nil, trailingDetail: reviewDetail)
                SessionHairline()

                // 历史记录摘要状态栏
                if let record = reviewRecord {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                            Text(record.persona?.title ?? "默认角色")
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                        }

                        Text("·")
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                                .font(.system(size: 10))
                                .foregroundStyle(SpeechRailDesignTokens.Color.voice)
                            Text(reviewVoiceLabel)
                                .font(SpeechRailDesignTokens.Typography.captionMedium)
                        }

                        Text("·")
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

                        Text("耗时 \(reviewDurationText)")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)

                        Spacer()

                        StatusPill(tone: .healthy, label: "已归档")
                    }
                    .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
                    .padding(.vertical, 6)
                    .background(SpeechRailDesignTokens.Color.recessedField.opacity(0.5))

                    SessionHairline()
                }

                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(reviewLines.enumerated()), id: \.element.id) { _, line in
                            SessionTurnRow(
                                who: line.role == .assistant ? "助手" : "你",
                                isVoice: line.role == .assistant,
                                voiceBadge: line.role == .assistant
                                    ? reviewVoiceName(for: line)
                                    : nil,
                                pills: reviewPills(line),
                                timestamp: Self.clock(line.createdAt),
                                text: line.text,
                                bodyWidth: 760
                            )
                        }
                        if reviewLines.isEmpty {
                            SessionEmptyState(
                                systemImage: "text.alignleft",
                                title: "这一条记录里还没有正文",
                                message: "它可能是被打断就结束的一段。"
                            ) { EmptyView() }
                        }
                    }
                    .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                SessionHairline()
                CardFoot(note: "继续这一轮是新开一轮：角色与声音可以重新选；这一条记录一个字不动。") {
                    reviewFooterActions
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var reviewFooterActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                copyReviewedRecordButton
                continueReviewedRecordButton
                renameReviewedRecordButton
                removeReviewedRecordButton
            }

            VStack(alignment: .trailing, spacing: SpeechRailDesignTokens.Spacing.xs) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    copyReviewedRecordButton
                    continueReviewedRecordButton
                }
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    renameReviewedRecordButton
                    removeReviewedRecordButton
                }
            }
        }
    }

    private var copyReviewedRecordButton: some View {
        Button("复制全文") { copy(reviewLines.map(\.text).joined(separator: "\n")) }
            .speechRailButton(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var continueReviewedRecordButton: some View {
        Button("继续这一轮") { continueFromReview() }
            .speechRailButton(.primary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var renameReviewedRecordButton: some View {
        Button("重命名") {
            renameDraft = reviewRecord?.title ?? ""
            isRenamingRecord = true
        }
        .speechRailButton(.secondary)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var removeReviewedRecordButton: some View {
        Button("从记录库移除", role: .destructive) { confirmingRemove = true }
            .speechRailButton(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var reviewDetail: String {
        let rounds = reviewLines.count
        return "\(rounds) 句 · 角色与声音随记录一起存"
    }

    /// 回看时这一行的音色：读这一条记录自己的 `session_change`，取这一句之前最后一次变更；
    /// 一句都没换过就用记录里那份快照（它是**开始那一刻**的音色）。
    ///
    /// 原来这里读的是 `currentVoiceName`——**此刻**设置里的那个音色，于是翻一条旧记录时
    /// 每一行都顶着今天的设置，而记录里存下来的那份反而没人看（2026-09-19 离屏走查）。
    private func reviewVoiceName(for line: TranscriptLine) -> String? {
        if let change = reviewVoiceChanges.last(where: { $0.atOrdinal <= line.ordinal }) {
            return voiceName(fromChangeValue: change.value)
        }
        return reviewVoiceLabel
    }

    /// 回看时把「这一句是谁说的」与「它有没有被打断」都挂在句子上（稿的分人标签口径）。
    private func reviewPills(_ line: TranscriptLine) -> [SessionTurnRow.Pill] {
        var pills: [SessionTurnRow.Pill] = []
        if let label = line.speakerLabel {
            pills.append(.init(
                tone: .neutral,
                label: SpeakerLabeling.chipText(label: label, displayName: reviewSpeakerNames[label])
            ))
        }
        if line.isInterrupted {
            pills.append(.init(tone: .attention, label: "被打断"))
        }
        return pills
    }

    // MARK: - 动作

    private var selectedPersonaTitle: String {
        preferences.persona(id: selectedPersonaID)?.title ?? preferences.defaultPersona.title
    }

    private var activePersonaTitle: String {
        assistant.persona?.title ?? selectedPersonaTitle
    }

    private func start() async {
        guard preferences.isLLMConfigured else {
            await MainActor.run {
                withAnimation { isShowingQuickLLM = true }
            }
            return
        }
        let persona = preferences.persona(id: selectedPersonaID) ?? preferences.defaultPersona
        await assistant.start(
            persona: persona,
            voiceID: selectedVoiceID.isEmpty ? nil : selectedVoiceID,
            mode: mode
        )
    }

    /// 「新开一轮以换人设」：人设锁的唯一出口，所以它必须结束当前这一段再开始。
    private func restartWithPersonaPick() async {
        isEndingToRestart = true
        await session.stopCapture(endingWith: .user)
        // 结束会触发一次「落到刚结束那一段」（`landOnFinalized`）。这里要的是**新的一轮**，
        // 所以先把回看状态清干净再开始——否则屏幕上会停在旧记录，而后台已经在录新的一轮
        // （`state` 优先报 `.review`，那就完全看不到在录了）。
        closeReview()
        await reloadRecent()
        await start()
        isEndingToRestart = false
    }

    private func openRecord(_ summary: SessionSummary) async {
        // 翻记录先把这个标记清掉：下面 `endConversation()` 会在打开之后重新写上它。
        justEndedSessionID = nil
        guard let record = (try? await session.record(id: summary.id)) ?? nil else { return }
        reviewRecord = record
        reviewLines = (try? await session.lines(sessionID: summary.id)) ?? []
        reviewSpeakerNames = (try? await session.speakerNames(sessionID: summary.id)) ?? [:]
        reviewVoiceChanges = (try? await session.voiceChanges(sessionID: summary.id)) ?? []
        inspectorTab = .session
    }

    private func closeReview() {
        justEndedSessionID = nil
        reviewRecord = nil
        reviewLines = []
        reviewSpeakerNames = [:]
        reviewVoiceChanges = []
    }

    /// 「结束对话」：结束之后**落到刚结束的这一段**上，不给一个空白的"未开始"。
    ///
    /// 稿的 `记录库 · 刚结束` 说的是这件事：结束是一次交互的终点，不是这段对话的终点。
    /// 原来的实现在结束之后直接回到「未开始」——用户刚说完一段话，屏幕上却像什么都没发生过，
    /// "我说的那些还在不在"只能自己猜（2026-09-19 与 4K 稿并排比对）。
    ///
    /// 落地的触发不写在这里，而是**由库写完这件事本身触发**（下面 `.onChange`
    /// 观察 `session.lastFinalizedSessionID`）：页头那颗按钮、`⌘⇧.` 与菜单栏是同一个结束动作，
    /// 三个入口必须落到同一个屏幕上。写在这里的话，走键盘结束的人会得到另一种结局。
    private func endConversation() async {
        await session.stopCapture(endingWith: .user)
    }

    /// 把屏幕交给刚刚封存的那一段。
    ///
    /// 三道闸都是真会撞上的情况，不是防御性编程：
    /// 1. `recent` 只装助手的记录，所以会议 / 字幕封存时这里会在第一条就返回——
    ///    结束会议不该把语音助手这一页翻到一条会议记录上；
    /// 2. **不在屏幕上的这一页不落**（`isOnScreen`）：用户人在别的页面上，
    ///    等他回来时"刚结束"已经过期了；
    /// 3. **正在翻旧记录时不抢屏**：用户手上那一条留在原地（他自己会离开）；
    /// 4. `assistant.phase == .idle`：`restartWithPersonaPick()` 会先结束再新开一轮，
    ///    而这一条落地任务与新开的那一轮是并行的。已经在开始新的一轮时落过去，页面会停在
    ///    旧记录上、而会话在后台跑——`state` 优先报 `.review`，屏幕上就完全看不到在录了。
    ///    所以两处 `await`（读库、打开记录）前后各确认一次。
    /// 4 这一条还有一半靠 `isEndingToRestart`：两件事都在主线程上，靠"读 `phase` 时它还没变"
    /// 来回避竞态是碰运气，所以那一处结束**自己声明**它不是一次要落地的结束。
    private func landOnFinalized(id: String) async {
        await reloadRecent()
        guard isOnScreen,
              !isEndingToRestart,
              state != .review,
              assistant.phase == .idle,
              let summary = recent.first(where: { $0.id == id }),
              summary.lineCount > 0
        else { return }
        await openRecord(summary)
        guard isOnScreen, !isEndingToRestart, assistant.phase == .idle else {
            closeReview()
            return
        }
        justEndedSessionID = id
    }

    /// 把右栏打开到某一页。**收起状态下这两个动作必须一起做**：页头的「音色与风格」只切
    /// `inspectorTab` 的话，右栏收着的时候按下去屏幕上一个像素都不动——`inspectorTab` 已经
    /// 换到音色页了，只是那一栏没露出来。这正是"点了没反应"（2026-09-19 离屏走查）。
    private func showInspector(tab: InspectorTab) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            isInspectorCollapsed = false
            autoCollapsedDueToWidth = false
            inspectorTab = tab
        }
    }

    // MARK: - 记录正文底部的三个动作（稿 `screenClosureAssistantClosed`）

    /// 「继续这一轮」= **新开一轮**（`SESSIONS-SPEC` §15 的 E7）：人设与音色按这一条记录预填，
    /// 但人设是每轮锁一次，所以新的这一轮**可以重选**——这正是它存在的理由
    /// （`SessionPreferences.prefill(from:)` 本来就是为它写的，此前没有调用点）。
    ///
    /// 它不把新的一轮接进这一条记录：记录是资产，旧的那条一个字不动（库里另起一条 `session` 行）。
    private func continueFromReview() {
        guard let record = reviewRecord else { return }
        preferences.prefill(from: record)
        selectedPersonaID = preferences.defaultPersonaID
        selectedVoiceID = preferences.defaultVoiceID
        closeReview()
    }

    /// 「新建对话」= 同一条出口，但**不**预填：用现在的默认人设与音色开头。
    private func startNewRound() {
        selectedPersonaID = preferences.defaultPersonaID
        selectedVoiceID = preferences.defaultVoiceID
        closeReview()
    }

    /// 重命名只改 `session.title`（列表与页头读它），正文一个字不动。
    /// 库里那一行是唯一权威，所以改完**重新读一遍**，界面不与库脱钩。
    private func renameReviewedRecord() async {
        guard let id = reviewRecord?.id else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await session.setSessionTitle(id: id, title: name.isEmpty ? nil : name)
        if let refreshed = (try? await session.record(id: id)) ?? nil {
            reviewRecord = refreshed
        }
        libraryReloadToken += 1
        isRenamingRecord = false
    }

    /// 移除这一条记录。**只在这一页给**（稿），且必须先确认（上面那张 `confirmationDialog`）。
    /// 删完把列表重新读一遍并退出回看——留在"已经不在的那一条"上只会看到空状态。
    private func removeReviewedRecord() async {
        guard let id = reviewRecord?.id else { return }
        try? await session.removeSession(id: id)
        closeReview()
        libraryReloadToken += 1
    }

    /// 页头的导出动作。四种格式收进一个菜单（与记录库、会议页同一个口径）：
    /// 助手默认纯文本，其余三种仍可选。导出**重新读库**，不导界面上这一份内存镜像。
    private var exportMenu: some View {
        PageActionsMenu(
            title: "导出…",
            systemImage: "square.and.arrow.down",
            helpText: "把这一条记录导出成文件"
        ) {
            ForEach(orderedFormats) { format in
                Button(format.title) {
                    Task { await exportReviewedRecord(as: format) }
                }
            }
        }
        .disabled(reviewRecord == nil)
    }

    private var orderedFormats: [SessionExportFormat] {
        let preferred = SessionExportFormat.preferred(for: .assistant)
        return [preferred] + SessionExportFormat.allCases.filter { $0 != preferred }
    }

    private func exportReviewedRecord(as format: SessionExportFormat) async {
        guard let id = reviewRecord?.id else { return }
        guard let record = (try? await session.record(id: id)) ?? nil else { return }
        let rows = (try? await session.lines(sessionID: id)) ?? []
        let names = (try? await session.speakerNames(sessionID: id)) ?? [:]
        SessionExportPanel.write(
            SessionExportPayload(record: record, lines: rows, speakerNames: names, minutes: nil),
            as: format
        )
    }

    private var renameRecordSheet: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text("给这一条记录起个名字")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            Text("只在记录库里显示。留空就把名字去掉，回到按时间认它。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("名字", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await renameReviewedRecord() } }
            HStack {
                Spacer(minLength: 0)
                Button("取消") { isRenamingRecord = false }
                    .speechRailButton(.secondary)
                Button("保存") { Task { await renameReviewedRecord() } }
                    .speechRailButton(.primary)
            }
        }
        .padding(SpeechRailDesignTokens.Layout.cardInset)
        .frame(width: 420)
    }

    /// 「麦克风未授权」的唯一出口。`Privacy_Microphone` 这个锚点与音色克隆、字幕带用的是
    /// 同一处（`VoiceCloneView` / `CaptionBandWindow`），所以三页落进同一个系统面板。
    private func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func reloadRecent() async {
        recent = (try? await session.listSummaries(kind: .assistant)) ?? []
    }

    private func reloadMemories() async {
        memories = (try? await session.memories(activeOnly: false)) ?? []
    }

    // MARK: - 两个 sheet

    private var personaSheet: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("新建自定义角色")
                .font(SpeechRailDesignTokens.Typography.display)
            Text("角色是它开口前读的第一段话：写清「怎么答」，不用写「知道什么」（那是记忆的事）。")
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("名字（列表里显示这一行）", text: $personaDraft.title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $personaDraft.body)
                .font(SpeechRailDesignTokens.Typography.body)
                .frame(minHeight: 140)
                .overlay {
                    RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.nested, style: .continuous)
                        .stroke(SpeechRailDesignTokens.Surface.borderStrong, lineWidth: SpeechRailDesignTokens.Stroke.hairline)
                }
            HStack {
                Spacer(minLength: 0)
                Button("取消") { isCreatingPersona = false }
                    .speechRailButton(.secondary)
                Button("保存") {
                    if preferences.addPersona(title: personaDraft.title, body: personaDraft.body) != nil {
                        isCreatingPersona = false
                    }
                }
                .speechRailButton(.primary)
                .disabled(
                    personaDraft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || personaDraft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(SpeechRailDesignTokens.Layout.cardInset)
        .frame(width: 520)
    }

    private var configurationHelpSheet: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("怎么配对话模型")
                .font(SpeechRailDesignTokens.Typography.display)
            Text(
                """
                1. 打开「设置 · 会话」，填服务地址与模型名。
                2. 服务必须实现 Responses API；只支持 Chat Completions 的服务接不上。
                3. 密钥填进设置后只存钥匙串：不写进配置文件，也不出现在日志或导出物里。
                4. 地址是本机还是局域网都行；识别、合成与「谁在说话」由 SpeechRail 本机提供。
                """
            )
            .font(SpeechRailDesignTokens.Typography.callout)
            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("关闭") { isShowingConfigHelp = false }
                    .speechRailButton(.secondary)
            }
        }
        .padding(SpeechRailDesignTokens.Layout.cardInset)
        .frame(width: 520)
    }

    // MARK: - 辅助面板响应式联动（接入中央 WindowLayoutTier 断点总线）

    private func syncInspectorWithLayoutTier(_ tier: WindowLayoutTier) {
        // 历史回看本身就是「记录列表 + 正文」两栏，不参与实时对讲的右栏收起策略。
        guard state != .review else { return }
        let shouldCollapse = tier == .compact

        if shouldCollapse {
            if !isInspectorCollapsed {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                    isInspectorCollapsed = true
                    autoCollapsedDueToWidth = true
                }
            }
        } else {
            if isInspectorCollapsed && autoCollapsedDueToWidth {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                    isInspectorCollapsed = false
                    autoCollapsedDueToWidth = false
                }
            }
        }
    }
}

// MARK: - 输入电平检查

/// 稿的「检查输入电平」：开始之前先确认这台 Mac 真的收得到声音。
///
/// 它按需占用麦克风，**关掉就释放**（`SESSIONS-SPEC` §设备占用：按功能启用、功能离开释放），
/// 不落盘、不留文件。
struct InputLevelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var level: Double = 0
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("检查输入电平")
                .font(SpeechRailDesignTokens.Typography.display)
            Text("对着麦克风说一句话。看完这一眼就关掉，它不会录音、也不留文件。")
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let failure {
                Text(failure)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: SpeechRailDesignTokens.Spacing.micro) {
                    ForEach(0..<20, id: \.self) { index in
                        let threshold = Double(index + 1) / 20
                        let shape = 0.35 + 0.65 * sin(Double.pi * Double(index) / 19)
                        Capsule()
                            .fill(
                                level >= threshold
                                    ? SpeechRailDesignTokens.Color.voice
                                    : SpeechRailDesignTokens.Surface.border
                            )
                            .frame(width: 3, height: max(3, 20 * shape))
                    }
                }
                .frame(height: 22)
                .accessibilityLabel("输入电平")
                .accessibilityValue("\(Int(level * 100))%")
            }

            HStack {
                Spacer(minLength: 0)
                Button("完成") { dismiss() }
                    .speechRailButton(.primary)
            }
        }
        .padding(SpeechRailDesignTokens.Layout.cardInset)
        .frame(width: 460)
        .onAppear { start() }
        .onDisappear {
            task?.cancel()
            task = nil
        }
    }

    private func start() {
        task = Task {
            let capture = MicrophoneCapture()
            do {
                let stream = try await capture.start()
                for await chunk in stream {
                    if Task.isCancelled { break }
                    level = chunk.level
                }
            } catch {
                failure = (error as? LocalizedError)?.errorDescription
                    ?? "拿不到麦克风：\(error.localizedDescription)"
            }
            capture.stop()
        }
    }
}
