import AppKit
import SwiftUI
import SpeechRailControlKit

public struct ControlMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    /// 会话那一组命令要读占用与浮层状态（§6.6 的「会话」段）。
    @Environment(SessionCoordinator.self) private var session
    @Environment(CaptionSession.self) private var caption
    @Environment(MeetingSession.self) private var meeting
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var pendingServiceAction: ControlCommand?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Menu.sectionSpacing) {
            menuHeader
            if let operation = model.serviceOperation,
               operation.phase.isActive || operation.phase == .failed
            {
                ServiceOperationCompactStatus(operation: operation)
            }

            Divider()

            primaryActions

            Divider()

            sessionActions

            Divider()

            preflightAction
            if !canMutate {
                controlChannelWarning
            }
            serviceMenu

            Divider()

            settingsAction

            Divider()

            quitAction
        }
        .padding(SpeechRailDesignTokens.Menu.contentPadding)
        .frame(width: SpeechRailDesignTokens.Menu.contentWidth, alignment: .leading)
        .controlSize(.regular)
        .confirmationDialog(
            confirmationTitle,
            isPresented: isConfirmingServiceAction,
            titleVisibility: .visible
        ) {
            if let pendingServiceAction {
                Button(
                    confirmationButtonTitle(for: pendingServiceAction),
                    role: isDestructive(pendingServiceAction) ? .destructive : nil
                ) {
                    let command = pendingServiceAction
                    self.pendingServiceAction = nil
                    Task { await model.execute(command) }
                }
            }
            Button("取消", role: .cancel) {
                pendingServiceAction = nil
            }
        }
        .task {
            await model.refresh()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-open-settings") {
                revealSettings()
            }
#endif
        }
    }

    /// 菜单栏是快速入口，不是技术看板：主层只保留身份、服务结论和档位。
    private var menuHeader: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "waveform")
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                    .accessibilityHidden(true)
                Text("SpeechRail")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
            }
            Text(statusSummary + " · " + profileText)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var primaryActions: some View {
        Button {
            revealControlCenter()
        } label: {
            Label("打开 SpeechRail", systemImage: "macwindow")
                .speechRailMenuRow()
        }
        .keyboardShortcut("o", modifiers: .command)

        Button {
            revealControlCenter(for: .dubbing)
        } label: {
            Label("开始配音", systemImage: AppRoute.dubbing.systemImage)
                .speechRailMenuRow()
        }
        .keyboardShortcut("n", modifiers: .command)

        Button {
            revealControlCenter(for: .voiceDesign)
        } label: {
            Label("音色创作", systemImage: AppRoute.voiceDesign.systemImage)
                .speechRailMenuRow()
        }
    }

    /// 空闲时不画无效的「结束当前会话」按钮；`ownershipText` 已经提供了唯一状态结论。
    @ViewBuilder
    private var sessionActions: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Circle()
                    .fill(sessionTone.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(session.ownershipText)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            if session.occupancy?.kind == .meeting, meeting.phase.isLive {
                Text("已存好 \(meeting.storedLineCount) 段"
                    + (meeting.labeling.labels.isEmpty
                        ? ""
                        : " · \(meeting.labeling.labels.count) 位说话人"))
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
            }

            Button {
                Task { await caption.openBand() }
                revealControlCenter()
            } label: {
                Label("开始实时字幕", systemImage: AppRoute.captions.systemImage)
                    .speechRailMenuRow()
            }
            .disabled(caption.phase.isLive)

            Button {
                revealControlCenter(for: .meeting)
            } label: {
                Label("开始会议", systemImage: AppRoute.meeting.systemImage)
                    .speechRailMenuRow()
            }
            .disabled(session.occupancy?.kind == .meeting)

            if !session.isIdle {
                Button {
                    session.requestEndCurrentSession()
                    // 带省略号 = 要问一句；窗口不出来的话那个确认没人能回答。
                    revealControlCenter()
                } label: {
                    Label("结束当前会话…", systemImage: "stop.circle")
                        .speechRailMenuRow()
                }

                if session.phase == .interrupted {
                    Text("这一场中断了，去页面里选「继续这一段」或「结束并整理」")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var preflightAction: some View {
        Button {
            revealControlCenter(for: .diagnostics)
            Task { await model.refreshPreflight() }
        } label: {
            Label("运行预检", systemImage: AppRoute.diagnostics.systemImage)
                .speechRailMenuRow()
        }
        .disabled(
            model.isBusy
                || model.hasActiveMutation
                || model.isRefreshingService
                || !canMutate
        )
    }

    private var controlChannelWarning: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text("控制通道不可用，服务操作已禁用")
                .font(SpeechRailDesignTokens.Typography.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(SpeechRailDesignTokens.Color.attention)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.micro)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SpeechRailDesignTokens.Color.attention.opacity(
                SpeechRailDesignTokens.Surface.statusTintOpacity
            ),
            in: SpeechRailDesignTokens.Corner.nestedShape
        )
    }

    /// 服务生命周期动作属于低频运维操作，收进原生子菜单，避免占据主层高度。
    private var serviceMenu: some View {
        Menu {
            Text(detailLine)
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)

            Divider()

            Button {
                pendingServiceAction = .start
            } label: {
                Label("启动服务…", systemImage: "play.circle")
                    .speechRailMenuRow()
            }

            Button {
                pendingServiceAction = .stop
            } label: {
                Label("停止服务…", systemImage: "stop.circle")
                    .speechRailMenuRow()
            }

            Button {
                pendingServiceAction = .restart
            } label: {
                Label("重启服务…", systemImage: "arrow.clockwise")
                    .speechRailMenuRow()
            }
        } label: {
            Label("服务", systemImage: AppRoute.overview.systemImage)
                .speechRailMenuRow()
        }
        .disabled(serviceActionsDisabled)
    }

    private var settingsAction: some View {
        Button {
            revealSettings()
        } label: {
            Label("打开设置…", systemImage: "gearshape")
                .speechRailMenuRow()
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    /// 菜单栏弹层中的窗口命令显式激活应用，避免窗口已创建但没有呈现在前台。
    private func revealControlCenter(for route: AppRoute? = nil) {
        if let route {
            navigation.request(route)
        }
        openWindow(id: AppNavigationState.controlCenterWindowID)
        NSApp.activate()
    }

    /// 设置是独立的 SwiftUI Settings scene，也要确保菜单栏应用回到前台。
    private func revealSettings() {
        openSettings()
        NSApp.activate()
    }

    private var quitAction: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("退出 SpeechRail", systemImage: "power")
                .speechRailMenuRow()
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    /// 版本 + 端口：只在「服务」子菜单中提供给需要排查的用户。
    private var detailLine: String {
        let version = Bundle.main.shortVersionString
        guard let port = model.service.port else {
            return "版本 \(version) · 端口未读取"
        }
        return "版本 \(version) · 端口 \(port)"
    }

    /// 服务操作在「控制通道不可用」或任一步操作进行中时必须一起禁用，
    /// 三个动作共用同一条判据，免得漏掉其中一个（Figma `warning` 组的语义）。
    private var serviceActionsDisabled: Bool {
        model.isBusy
            || model.hasActiveMutation
            || model.isRefreshingService
            || !canMutate
    }

    private var profileText: String {
        guard model.healthFailure == nil, let profile = model.health?.profile else {
            return "档位未读取"
        }
        // 状态行要的是当前档位短名（REDESIGN-SPEC §7.9、macOS App 设计系统 §4.1）。
        // 完整用途说明只放档位卡与选择后的详情中。
        return SpeechRailProfilePresentation.shortTitle(profile)
    }

    private var statusSummary: String {
        if model.serviceOperation?.phase.isActive == true {
            return "操作进行中"
        }
        if model.serviceOperation?.phase == .failed {
            return "操作未完成"
        }
        if model.healthMessage != nil {
            switch model.healthFailure {
            case .some(.timeout):
                return "健康检查超时"
            case .some(.connection):
                return "服务未连接"
            case .some(.invalidResponse), .some(.server):
                return "健康状态异常"
            default:
                return "状态暂不可用"
            }
        }
        if model.controlPlaneMessage != nil {
            return "控制通道不可用"
        }
        if displayedHealth?.ready == true {
            if !model.controlAgentStatus.allowsMutation {
                return "服务已就绪 · 控制受限"
            }
            return "服务已就绪"
        }
        if model.service.serviceState == "unavailable" {
            return "服务不可用"
        }
        return "服务需要关注"
    }

    private var displayedHealth: HealthSnapshot? {
        guard model.healthFailure == nil else { return nil }
        return model.health
    }

    private var canMutate: Bool {
        model.controlAgentStatus.allowsMutation && model.controlPlaneMessage == nil
    }

    private var isConfirmingServiceAction: Binding<Bool> {
        Binding(
            get: { pendingServiceAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingServiceAction = nil
                }
            }
        )
    }

    private var confirmationTitle: String {
        guard let pendingServiceAction else { return "确认操作" }
        return switch pendingServiceAction {
        case .start:
            "确认启动本机服务？"
        case .stop:
            "确认停止本机服务？"
        case .restart:
            "确认重启本机服务？"
        default:
            "确认操作？"
        }
    }

    /// 会话状态点的颜色：空闲中性、中断提醒、其余健康。与三页状态带同一套语义色。
    private var sessionTone: StatusTone {
        if session.isIdle { return .neutral }
        if session.phase == .interrupted { return .attention }
        if session.phase == .preparing { return .attention }
        return .healthy
    }

    private func confirmationButtonTitle(for command: ControlCommand) -> String {
        return switch command {
        case .start:
            "启动服务"
        case .stop:
            "停止服务"
        case .restart:
            "重启服务"
        default:
            "确认"
        }
    }

    private func isDestructive(_ command: ControlCommand) -> Bool {
        command == .stop || command == .restart
    }
}

/// Figma `menuBarStrip` + 会话状态（设计稿 `菜单栏 · 三个入口`，2026-09-18 导出）：
///
/// · **空闲**：常态只有图标（产品名不占标题宽度）；
/// · **服务操作进行中**：产品名 + 琥珀点（既有行为）；
/// · **会话进行中**：图标旁出现会话名——这是除主窗口之外唯一常驻的
///   「谁在用麦克风」，用户不必打开面板或先被拒绝才知道（`SESSIONS-SPEC` §5.3 / P5）；
/// · **会议录制中**：琥珀点（「现在正在被别人用着」）；
/// · **受阻**：红点（麦克风未授权、服务不可达），不必打开面板就知道。
///
/// 「会话名」用 `SessionKind.shortTitle`：菜单栏宽度有限，这里要的是"是哪一个"，
/// 不是一个句子（句子在面板里的状态行上）。
///
/// 四个会话对象**由调用方显式传入**，不读环境：`MenuBarExtra` 的 label 由系统单独承载，
/// 挂在其上的 `.environment(...)` 不生效（2026-09-18 真机崩溃即此）。`@Observable` 的对象
/// 作为普通属性同样会被观测，所以视图照常随会话状态重绘。
struct MenuBarStatusLabel: View {
    let isOperating: Bool
    let session: SessionCoordinator
    let caption: CaptionSession
    let meeting: MeetingSession
    let assistant: AssistantSession

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Menu.menuBarItemSpacing) {
            Image(systemName: AppRoute.dubbing.systemImage)
            if let title {
                Text(title)
            }
            if let tone {
                Circle()
                    .fill(toneColor(tone))
                    .frame(
                        width: SpeechRailDesignTokens.Menu.menuBarStatusDotSize,
                        height: SpeechRailDesignTokens.Menu.menuBarStatusDotSize
                    )
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// 图标旁那一段文字。**空闲且没有长任务时为空**：菜单栏属于系统，不该被产品名占着。
    private var title: String? {
        if let kind = blockedKind { return kind.shortTitle }
        if let kind = session.occupancy?.kind { return kind.shortTitle }
        return isOperating ? "SpeechRail" : nil
    }

    private enum Tone {
        case attention
        case critical
    }

    /// 状态点。三档与设计稿一一对应；「服务操作进行中」沿用既有行为。
    private var tone: Tone? {
        if blockedKind != nil { return .critical }
        switch session.occupancy?.kind {
        // 会议录着的时候，机器在收声——这是最需要"不打开也知道"的一态。
        case .meeting: return .attention
        case .assistant, .captions, .teleprompter: return nil
        case .none: return isOperating ? .attention : nil
        }
    }

    /// 有会话停在受阻态上（麦克风未授权 / 服务不可达 / 被占用）。
    /// 三个能力各自的 `blocked` 是同一种结论，所以这里合并成一个红点。
    private var blockedKind: SessionKind? {
        if caption.blocked != nil { return .captions }
        if meeting.blocked != nil { return .meeting }
        if assistant.blocked != nil { return .assistant }
        return nil
    }

    private func toneColor(_ tone: Tone) -> Color {
        switch tone {
        // 「服务操作进行中」与「会议录制中」都是注意状态，不是声音语义：
        // 琥珀只标记音色类对象（REDESIGN-SPEC §5.4）。
        case .attention: SpeechRailDesignTokens.Color.attention
        case .critical: SpeechRailDesignTokens.Color.critical
        }
    }

    private var accessibilityLabel: String {
        var parts = ["SpeechRail"]
        if let kind = blockedKind {
            parts.append("\(kind.shortTitle)受阻，\(blockedSummary ?? "需要处理")")
        } else if let kind = session.occupancy?.kind {
            parts.append("\(kind.shortTitle)进行中")
            if kind == .meeting { parts.append("麦克风正在收声") }
        } else if isOperating {
            parts.append("服务操作进行中")
        }
        return parts.joined(separator: "，")
    }

    /// 受阻原因的一句话；文案直接取各自 `BlockReason` 的标题（三处共用同一套说法）。
    private var blockedSummary: String? {
        if let reason = caption.blocked { return reason.title }
        if let reason = meeting.blocked { return reason.title }
        if let reason = assistant.blocked { return reason.title }
        return nil
    }
}
