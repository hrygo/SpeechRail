import SwiftUI
import SpeechRailControlKit

public struct ControlMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var pendingServiceAction: ControlCommand?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Menu.sectionSpacing) {
            // Figma `menuHead`：产品名 + 结论 + 版本与端口。菜单栏面板是唯一
            // 不经过页面就打开的窗口，所以它自带身份与两条本机事实。
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Image(systemName: "waveform")
                        .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                        .accessibilityHidden(true)
                    Text("SpeechRail")
                        .font(SpeechRailDesignTokens.Typography.sectionTitle)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                }
                // 状态行用档位短名：`服务已就绪 · Quality`（REDESIGN-SPEC §7.9、
                // macOS App 设计系统 §4.1）。长写法「Quality · 创作优先」属于卡片标题，
                // 拼进这一行会变成两段「 · 」。
                Text(statusSummary + " · " + profileText)
                    .font(SpeechRailDesignTokens.Typography.callout)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detailLine)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            if let operation = model.serviceOperation,
               operation.phase.isActive || operation.phase == .failed
            {
                ServiceOperationCompactStatus(operation: operation)
            }

            Divider()

            Button {
                openWindow(id: AppNavigationState.controlCenterWindowID)
            } label: {
                Label("打开 SpeechRail", systemImage: "macwindow")
                    .speechRailMenuRow()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button {
                navigation.request(.dubbing)
                openWindow(id: AppNavigationState.controlCenterWindowID)
            } label: {
                Label("开始配音", systemImage: AppRoute.dubbing.systemImage)
                    .speechRailMenuRow()
            }
            .keyboardShortcut("n", modifiers: .command)

            Button {
                navigation.request(.voiceDesign)
                openWindow(id: AppNavigationState.controlCenterWindowID)
            } label: {
                Label("音色创作", systemImage: AppRoute.voiceDesign.systemImage)
                    .speechRailMenuRow()
            }

            Divider()

            Button {
                navigation.request(.diagnostics)
                openWindow(id: AppNavigationState.controlCenterWindowID)
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

            // A greyed-out group with no reason on screen is the failure mode
            // this line exists to prevent (Figma `warning`).
            if !canMutate {
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
                    // 跟随菜单面板自己的圆角；面板不提供容器形状时退到叶面保底值。
                    in: SpeechRailDesignTokens.Corner.nestedShape
                )
            }

            Button {
                pendingServiceAction = .start
            } label: {
                Label("启动服务…", systemImage: "play.circle")
                    .speechRailMenuRow()
            }
            .disabled(serviceActionsDisabled)

            Button {
                pendingServiceAction = .stop
            } label: {
                Label("停止服务…", systemImage: "stop.circle")
                    .speechRailMenuRow()
            }
            .disabled(serviceActionsDisabled)

            Button {
                pendingServiceAction = .restart
            } label: {
                Label("重启服务…", systemImage: "arrow.clockwise")
                    .speechRailMenuRow()
            }
            .disabled(serviceActionsDisabled)

            Divider()

            Button {
                openSettings()
            } label: {
                Label("打开设置…", systemImage: "gearshape")
                    .speechRailMenuRow()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 SpeechRail", systemImage: "power")
                    .speechRailMenuRow()
            }
            .keyboardShortcut("q", modifiers: .command)
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
                openSettings()
            }
#endif
        }
    }

    /// 版本 + 端口：菜单面板里仅有的两条纯事实（Figma `menuHead` 第二行）。
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
        // 状态行要的是短名：`服务已就绪 · Quality`（REDESIGN-SPEC §7.9、
        // macOS App 设计系统 §4.1）。「Quality · 创作优先」是卡片标题的写法。
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

/// Figma `menuBarStrip`（`figma-kit/main.js`）：常态只有图标，操作进行中才
/// 出现文字与琥珀色状态点。菜单栏属于系统，不属于产品，所以产品名默认不
/// 占用标题宽度；只有长任务真的在跑时才占用。
struct MenuBarStatusLabel: View {
    let isOperating: Bool

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Menu.menuBarItemSpacing) {
            Image(systemName: AppRoute.dubbing.systemImage)
            if isOperating {
                Text("SpeechRail")
                Circle()
                    // 「服务操作进行中」是注意状态，不是声音语义：琥珀只标记
                    // 音色类对象（REDESIGN-SPEC §5.4）。
                    .fill(SpeechRailDesignTokens.Color.attention)
                    .frame(
                        width: SpeechRailDesignTokens.Menu.menuBarStatusDotSize,
                        height: SpeechRailDesignTokens.Menu.menuBarStatusDotSize
                    )
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOperating ? "SpeechRail，服务操作进行中" : "SpeechRail")
    }
}
