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
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Text(statusLine)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
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

            Button {
                pendingServiceAction = .stop
            } label: {
                Label("停止服务…", systemImage: "stop.circle")
                    .speechRailMenuRow()
            }
            .disabled(
                model.isBusy
                    || model.hasActiveMutation
                    || model.isRefreshingService
                    || !canMutate
            )

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

    /// One non-clickable line: product · conclusion · profile
    /// (REDESIGN-SPEC §7.9).
    private var statusLine: String {
        "SpeechRail · \(statusSummary) · \(profileText)"
    }

    private var profileText: String {
        guard model.healthFailure == nil, let profile = model.health?.profile else {
            return "档位未读取"
        }
        return SpeechRailProfilePresentation.title(profile)
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
