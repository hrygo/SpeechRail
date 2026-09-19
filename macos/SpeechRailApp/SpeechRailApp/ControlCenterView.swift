import AppKit
import SwiftUI
import SpeechRailControlKit

public struct ControlCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(SessionCoordinator.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// 打开窗口时落在哪一页。
    ///
    /// 2026-09-19（用户：「门槛极高」「面向用户体验」）：原先是「服务状态」——那是**服务
    /// 控制台**的视角，全新用户第一眼看到的是一张能力表与运行信息，而不是"我能做什么"。
    /// 现在落在「语音助手」：它自己就能开始，服务没起来时它的受阻态给一条真出口
    /// （「去服务状态」），不会把人卡住。内部键 `quality` 那类仍只在高级页出现。
    /// 回归方式：把这一行改回 `.overview` 即可（SESSIONS-SPEC §13 D15）。
    @State private var selection: AppRoute? = Self.landingRoute

    /// 窗口没有选中项时显示的那一页：与落地页同一个值，免得"打开时是语音助手、点空
    /// 一下变服务状态"。
    private static let landingRoute: AppRoute = .assistant
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// 记录是否是因为窗口拉窄而由系统自动收起左侧边栏（拉宽时据此自动恢复展开）
    @State private var autoCollapsedSidebarDueToWidth = false
    /// 上一次记录的窗口总宽度，用于避免初次渲染/冷启动动画闪动
    @State private var lastObservedWindowWidth: CGFloat = 0
    @State private var skipsSwitchConfirmation = false
    @AppStorage("speechrail.refreshOnLaunch") private var refreshOnLaunch = true

    public init() {}

    public var body: some View {
        if isUITestWithoutControlCenter {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    dismiss()
                }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        sidebarSection(
                            title: AppRouteGroup.creator.title,
                            routes: AppRoute.creatorRoutes
                        )
                        sidebarSection(
                            title: AppRouteGroup.session.title,
                            routes: AppRoute.sessionRoutes
                        )
                        sidebarSection(
                            title: AppRouteGroup.service.title,
                            routes: AppRoute.serviceRoutes
                        )
                    }
                    .listStyle(.sidebar)
                    // 侧栏搜索已移除：窗口里**只保留一个搜索框**，且它属于内容
                    // （音色库 / 我的作品的工具栏搜索）。八条固定导航项做全文过滤
                    // 的收益低于代价——它与内容搜索同屏并排、外观相近而作用域不同，
                    // 用户无法从外观判断自己在搜什么（REDESIGN-SPEC §6.1 / §6.2，
                    // §11.6 第四十九轮）。

                    sidebarBottom
                }
                .navigationSplitViewColumnWidth(
                    min: SpeechRailDesignTokens.Layout.sidebarMinimumWidth,
                    ideal: SpeechRailDesignTokens.Layout.sidebarIdealWidth,
                    max: SpeechRailDesignTokens.Layout.sidebarMaximumWidth
                )
            } detail: {
                detailView(for: selection ?? Self.landingRoute)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // 页面地板：窗口内容区的底色是稿的一级表面（`surface/window`），
                    // 卡片才是它上面更亮的一级；侧栏的材质与工具栏那一行不受影响
                    // （REDESIGN-SPEC §11.6 第五十轮）。
                    .background(SpeechRailDesignTokens.Color.canvas)
                    .toolbar {
                        // 页面身份（`.navigation` 槽，第五十五轮前是 `.principal`）由
                        // **窗口组合根**声明一次：它是当前路由的纯函数，页面自己没有
                        // 需要额外携带的标题状态，所以八个屏幕不可能漂移成九种头部
                        // （REDESIGN-SPEC §6.2 / §11.6 第四十九、五十五轮）。
                        PageIdentityToolbarItem(selection ?? Self.landingRoute)
                        // 这一枚浮动间隔留着：页面动作由子视图声明、会排在它之前，而系统
                        // 搜索框（`.searchable(placement: .toolbar)`）在它之后——去掉它，
                        // 搜索框就会贴到页面动作旁边，右侧留一大片空白（装机件截图里
                        // 「标题 · 动作 …… 搜索」的那道间距就是它）。
                        ToolbarSpacer(.flexible)
                    }
            }
            .navigationSplitViewStyle(.balanced)
            // 侧边栏切换按钮**保留系统那一枚**。§6.2 曾按稿（`titlebar` 只画了红绿灯、
            // 标题锁与右侧动作）要求用 `.toolbar(removing: .sidebarToggle)` 去掉它；
            // 2026-09-16 复核：改写这条修饰符的那一版源码（文件 mtime 08:29）确实被
            // 09:42 的装机件包含，而装机件截图里按钮仍在——修饰符在这套
            // `NavigationSplitView` 布局下不生效。窗口最小宽 1120pt 里侧栏 240 + 内容 +
            // inspector 360 本来就紧，收起侧栏是真实需求，系统这枚按钮是它唯一的
            // 可发现入口（View ▸ Hide Sidebar ⌘⌃S 只是备选），因此不为了对上稿面而
            // 保留一条不生效的修饰符（REDESIGN-SPEC §11.6 第四十九轮）。
            .frame(
                minWidth: controlCenterMinimumWidth,
                minHeight: SpeechRailDesignTokens.Layout.windowMinimumHeight
            )
            .background {
                ControlCenterResponsiveBridge { width, window in
                    handleWindowWidthChange(width, in: window)
                }
#if DEBUG
                if isUITestSession {
                    ControlCenterWindowActivator()
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                }
#endif
            }
            .task {
                // Settings ▸ 通用 can opt out of the launch-time read
                // (REDESIGN-SPEC §7.10).
                guard refreshOnLaunch else { return }
                await model.refresh()
            }
            .onAppear {
                if let route = navigation.consumeRequestedRoute() {
                    selection = route
                }
            }
            .onChange(of: navigation.requestedRoute) { _, _ in
                if let route = navigation.consumeRequestedRoute() {
                    selection = route
                }
            }
            // 会话占用与交还的守卫：**全窗口只有一个确认形状**（§6.4）。
            // 触发点是三个页面的开始动作、`⌘⇧N`、菜单栏「开始…」与字幕带的「开始会议」，
            // 它们都只调用 `SessionCoordinator`，确认面板在这里统一呈现一次。
            .sheet(item: switchConfirmation) { confirmation in
                sessionConfirmationSheet(confirmation)
            }
        }
    }

    private var switchConfirmation: Binding<SessionCoordinator.Confirmation?> {
        Binding(
            get: { session.pendingConfirmation },
            set: { if $0 == nil { session.cancelPending() } }
        )
    }

    @ViewBuilder
    private func sessionConfirmationSheet(_ confirmation: SessionCoordinator.Confirmation) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(confirmation.title)
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            Text(confirmation.message)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .frame(maxWidth: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Button(confirmation.confirmTitle) {
                    if skipsSwitchConfirmation, confirmation.allowsDoNotAskAgain {
                        session.rememberDoNotAskAgain()
                    }
                    Task { await session.confirmPending() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button("取消", role: .cancel) {
                    session.cancelPending()
                }
                .keyboardShortcut(.cancelAction)

                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)

                if confirmation.allowsDoNotAskAgain {
                    Toggle("以后不再询问", isOn: $skipsSwitchConfirmation)
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.gutter)
        .frame(minWidth: 440, alignment: .leading)
        .onAppear { skipsSwitchConfirmation = false }
    }

    private var displayedHealth: HealthSnapshot? {
        guard model.healthFailure == nil else { return nil }
        return model.health
    }

    @ViewBuilder
    private func sidebarSection(title: String, routes: [AppRoute]) -> some View {
        Section(title) {
            ForEach(routes, id: \.self) { route in
                navigationRow(for: route)
            }
        }
    }

    @ViewBuilder
    private func navigationRow(for route: AppRoute) -> some View {
        NavigationLink(value: route) {
            Label(route.title, systemImage: route.systemImage)
                .symbolRenderingMode(.monochrome)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: .infinity,
                    // 稿 `navItemRow` 是 220 × 30（`gap: 8`、图标 16、标签 `Body`），
                    // 不是 44 的命中区下限：侧栏是 macOS 上最密的列表，30 仍在指针
                    // 目标下限之上（第四十三轮，见 token 注释）。
                    minHeight: SpeechRailDesignTokens.List.sidebarRowHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
        }
        .listRowInsets(
            EdgeInsets(
                // 上下不再加内边距：稿的两行之间只有 1pt（`group` 的 `gap: 1`），
                // 而 `.sidebar` 的行矩形已经有系统下限 32（第四十三轮实测），
                // 再加就会把行距撑到 33 以上（改前是 44 + 4 + 4 = 52）。
                top: 0,
                leading: SpeechRailDesignTokens.Spacing.xs,
                bottom: 0,
                trailing: SpeechRailDesignTokens.Spacing.xs
            )
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier(route.id)
        .help(route.purpose)
        .accessibilityValue(
            selection == route ? "已选中。\(route.purpose)" : route.purpose
        )
        .speechRailPointerCursor()
    }

    /// 侧栏底部状态区 = 稿的 `sidebarStatusWrap`：一条 hairline + 一行状态。
    ///
    /// 稿里这条 hairline 不是通栏——是 `sidebarStatusWrap` 里的 220 × 1 矩形，在 240 宽的
    /// 侧栏里左右各内缩 10（= 稿侧栏的 `padX: 10`），与上方系统侧栏行的内缩对齐；
    /// 4x 帧实测墨迹 x 10.0–230.0。系统 `Divider()` 只能通栏，所以用 1pt 矩形加内缩
    /// （REDESIGN-SPEC §11.6 第四十轮）。
    private var sidebarBottom: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: SpeechRailDesignTokens.Spacing.hairline)
                .padding(.horizontal, SpeechRailDesignTokens.Control.sidebarHairlineInset)
            sidebarServiceStatus
            // 第二行：谁在用麦克风（P1 的落点）。第一行答「引擎能不能用」，
            // 这一行答「此刻是谁在用它」——两件事都常驻，顺序即优先级（§5.1）。
            SessionOwnershipRow()
        }
    }

    private var sidebarServiceStatus: some View {
        Button {
            selection = .overview
        } label: {
            // 稿（Figma `Sidebar Status` 的三个 tone 变体；4x 帧侧栏底部实测墨迹
            // 125.25 × 12.75，点 18–26 / 文本 34.5–143.25）是**一行**：8pt 状态点 +
            // `Callout`(12) 的文本、颜色是 `text/secondary` 灰，没有标题行、也没有尾部
            // chevron——「服务已就绪 · Quality」整句就是这一行的内容（§7 也写着
            // 「一行状态点 + 状态文本，点击进入「服务状态」」）。应用此前是「服务状态」
            // 标题行 + 小一号的语义色状态行两行，外加一个 chevron：块高只差 2pt
            // （`SpeechRailInteractiveButtonStyle` 的 44pt 命中区下限本就主导了行高，
            // 离屏实测 47 → 45），但多一行标题和一个尾随动作，读起来像「一个可以去的
            // 页面」而不是「此刻的状态」。可点击性由 hover/pressed 反馈
            // （`speechRailInteractiveButtonStyle`）、指针与 `.help` 承担
            // （REDESIGN-SPEC §11.6 第四十轮）。
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Circle()
                    .fill(sidebarStatusTone.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(sidebarStatusText)
                    .font(.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.List.rowHorizontalPadding)
            .padding(.vertical, SpeechRailDesignTokens.List.rowVerticalPadding)
        }
        // 稿 `sidebarStatus` 是 **220 × 30**（`padX 8 / padY 7`、8pt 点 + `Callout`）。
        // 这一行按稿取 30，不再套 44 的命中区下限（第四十轮记下的「块高 45 vs 稿 53」
        // 残差由此收掉；30 仍在 macOS 指针目标下限之上，第四十三轮）。
        .speechRailInteractiveButtonStyle(
            fillsAvailableWidth: true,
            minimumHeight: SpeechRailDesignTokens.List.sidebarRowHeight
        )
        .help("打开服务状态")
        .accessibilityLabel("服务状态")
        .accessibilityValue(sidebarStatusText)
    }

    private var sidebarStatusText: String {
        if model.serviceOperation?.phase.isActive == true {
            return "服务操作进行中"
        }
        if model.serviceOperation?.phase == .failed {
            return "服务操作未完成"
        }
        if model.healthMessage != nil {
            return "健康状态不可用"
        }
        if model.controlPlaneMessage != nil {
            return "控制通道不可用"
        }
        if displayedHealth?.ready == true {
            // macOS App 设计系统 §4.1：侧边栏底部是全 App 唯一的常驻服务状态指示器，
            // 并且要带上当前运行档位（Figma 状态行同一写法）。
            guard let profile = displayedHealth?.profile else { return "服务已就绪" }
            return "服务已就绪 · \(SpeechRailProfilePresentation.shortTitle(profile))"
        }
        if model.service.serviceState == "unavailable" {
            return "服务不可用"
        }
        return "服务未就绪"
    }

    private var sidebarStatusTone: StatusTone {
        if model.serviceOperation?.phase.isActive == true {
            return .attention
        }
        if model.serviceOperation?.phase == .failed {
            return .critical
        }
        if model.healthMessage != nil {
            return .critical
        }
        if model.controlPlaneMessage != nil {
            return .attention
        }
        if displayedHealth?.ready == true {
            return .healthy
        }
        if model.service.serviceState == "unavailable" {
            return .critical
        }
        return .neutral
    }

    @ViewBuilder
    private func detailView(for route: AppRoute) -> some View {
        switch route {
        case .dubbing:
            DubbingDeskView()
        case .voiceDesign:
            VoiceDesignView()
        case .voiceClone:
            VoiceCloneView()
        case .voiceLibrary:
            VoiceLibraryView()
        case .works:
            WorksView()
        case .assistant:
            // 助手页本身就是那一块产品页（§6.1 的五种态在同一页上）；
            // 记录库在它的右栏「记录」标签里，不再是另一页。
            AssistantView()
        case .meeting:
            MeetingView()
        case .captions:
            SessionLibraryView(kind: .captions)
        case .overview:
            ServiceOverviewView()
        case .monitoring:
            RuntimeMonitoringView()
        case .models:
            ModelManagementView()
        case .diagnostics:
            PreflightDiagnosticsView()
        case .developerDocs:
            DeveloperDocsView()
        }
    }

    private var isUITestWithoutControlCenter: Bool {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--ui-test") && !args.contains("--ui-test-open-control-center")
#else
        return false
#endif
    }

    private var isUITestSession: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-test")
#else
        false
#endif
    }

    private var controlCenterMinimumWidth: CGFloat {
        if isUITestSession {
            return 1_000
        }
        return SpeechRailDesignTokens.Layout.windowMinimumWidth
    }

    // MARK: - 侧边栏响应式自适应（接入中央 WindowLayoutTier 断点总线与原生 AppKit 侧边栏控制器）

    private func handleWindowWidthChange(_ width: CGFloat, in window: NSWindow?) {
        guard width > 0 else { return }
        navigation.updateWindowWidth(width)
        let isColdStart = (lastObservedWindowWidth == 0)
        lastObservedWindowWidth = width

        let tier = navigation.layoutTier
        let targetWindow = window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == AppNavigationState.controlCenterWindowID }) ?? NSApp.keyWindow

        // 在中屏与窄屏下（Window Width < 1260pt），立即优先强制收起边栏！释放 240pt，全力保障主窗体饱满宽敞
        if tier == .medium || tier == .compact {
            if !NativeSidebarBridge.isSidebarCollapsed(in: targetWindow) {
                NativeSidebarBridge.setSidebarCollapsed(true, in: targetWindow, animated: !isColdStart)
                columnVisibility = .detailOnly
                autoCollapsedSidebarDueToWidth = true
            }
        } else if tier == .expanded {
            // 宽屏状态（Window Width ≥ 1340pt）：仅当此前是因为收窄被自动收起时，才自动恢复展开
            if autoCollapsedSidebarDueToWidth {
                NativeSidebarBridge.setSidebarCollapsed(false, in: targetWindow, animated: !isColdStart)
                columnVisibility = .all
                autoCollapsedSidebarDueToWidth = false
            }
        }
    }
}

// MARK: - 窗口尺寸实时捕获与 AppKit 侧边栏桥接

private struct ControlCenterResponsiveBridge: NSViewRepresentable {
    let onResize: (CGFloat, NSWindow?) -> Void

    func makeNSView(context: Context) -> ControlCenterResponsiveNSView {
        let view = ControlCenterResponsiveNSView()
        view.onResize = onResize
        return view
    }

    func updateNSView(_ nsView: ControlCenterResponsiveNSView, context: Context) {
        nsView.onResize = onResize
    }
}

private final class ControlCenterResponsiveNSView: NSView {
    var onResize: ((CGFloat, NSWindow?) -> Void)?
    private var windowObserver: AnyObject?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        guard let window else { return }

        // 初次挂载（冷启动）：立即上报窗口当前实际尺寸
        let initialWidth = window.frame.size.width
        if initialWidth > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.onResize?(initialWidth, window)
            }
        }

        // 窗口拖拽 live resize 监听：像素级实时响应，彻底根除 GeometryReader 造成的拖拽感知延迟
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] notif in
            guard let win = notif.object as? NSWindow else { return }
            self?.onResize?(win.frame.size.width, win)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
    }
}

@MainActor
public enum NativeSidebarBridge {
    /// 强制控制 AppKit 原生侧边栏折叠/展开（穿透 SwiftUI NavigationSplitView 的系统限制）
    public static func setSidebarCollapsed(_ collapsed: Bool, in window: NSWindow?, animated: Bool = true) {
        guard let window else { return }

        // 1. 在 view 树中查找 NSSplitView，其 delegate 即为 NSSplitViewController
        if let splitVC = findSplitViewController(in: window.contentView) {
            applyCollapse(collapsed, to: splitVC, animated: animated)
            return
        }

        // 2. 在 contentViewController 递归查找
        if let rootVC = window.contentViewController,
           let splitVC = findSplitViewController(in: rootVC) {
            applyCollapse(collapsed, to: splitVC, animated: animated)
            return
        }

        // 3. 兜底方案：若查找失败且状态不符，向响应者链发送系统的原生 toggleSidebar: 动作
        if isSidebarCollapsed(in: window) != collapsed {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        }
    }

    /// 查询当前 AppKit 侧边栏是否已处于折叠状态
    public static func isSidebarCollapsed(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if let splitVC = findSplitViewController(in: window.contentView) ?? (window.contentViewController.flatMap { findSplitViewController(in: $0) }) {
            let sidebarItem = splitVC.splitViewItems.first(where: { $0.behavior == .sidebar }) ?? splitVC.splitViewItems.first
            return sidebarItem?.isCollapsed ?? false
        }
        return false
    }

    private static func applyCollapse(_ collapsed: Bool, to splitVC: NSSplitViewController, animated: Bool) {
        guard let sidebarItem = splitVC.splitViewItems.first(where: { $0.behavior == .sidebar }) ?? splitVC.splitViewItems.first else {
            return
        }
        guard sidebarItem.isCollapsed != collapsed else { return }
        if animated {
            sidebarItem.animator().isCollapsed = collapsed
        } else {
            sidebarItem.isCollapsed = collapsed
        }
    }

    private static func findSplitViewController(in view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if let splitView = view as? NSSplitView,
           let splitVC = splitView.delegate as? NSSplitViewController {
            return splitVC
        }
        for subview in view.subviews {
            if let found = findSplitViewController(in: subview) {
                return found
            }
        }
        return nil
    }

    private static func findSplitViewController(in vc: NSViewController) -> NSSplitViewController? {
        if let split = vc as? NSSplitViewController {
            return split
        }
        for child in vc.children {
            if let found = findSplitViewController(in: child) {
                return found
            }
        }
        return nil
    }
}

#if DEBUG
private struct ControlCenterWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlCenterWindowActivationView {
        ControlCenterWindowActivationView()
    }

    func updateNSView(_ nsView: ControlCenterWindowActivationView, context: Context) {
        nsView.activateIfPossible()
    }
}

private final class ControlCenterWindowActivationView: NSView {
    private var hasActivatedWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activateIfPossible()
    }

    fileprivate func activateIfPossible() {
        guard window != nil, !hasActivatedWindow else { return }
        hasActivatedWindow = true

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.fit(window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func fit(_ window: NSWindow) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

        let maximumSize = NSSize(
            width: max(1, visibleFrame.width - 16),
            height: max(1, visibleFrame.height - 16)
        )
        window.minSize = NSSize(
            width: min(window.minSize.width, maximumSize.width),
            height: min(window.minSize.height, maximumSize.height)
        )

        var frame = window.frame
        frame.size.width = min(frame.size.width, maximumSize.width)
        frame.size.height = min(frame.size.height, maximumSize.height)
        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX + 8),
            visibleFrame.maxX - frame.width - 8
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY + 8),
            visibleFrame.maxY - frame.height - 8
        )
        window.setFrame(frame, display: true, animate: false)
    }
}
#endif
