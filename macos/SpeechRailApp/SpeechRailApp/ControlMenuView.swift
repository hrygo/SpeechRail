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
                Image(systemName: AppRoute.dubbing.systemImage)
                    .foregroundStyle(SpeechRailDesignTokens.Color.rail)
                Text("SpeechRail")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
            }
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(statusSummary)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SpeechRailRuntimeStatePresentation.text(model.service.serviceState))
                    .font(SpeechRailDesignTokens.Typography.technical)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                Label("打开管理控制台", systemImage: "rectangle.3.group")
                    .speechRailMenuRow()
            }
            .keyboardShortcut("0", modifiers: [.command, .option])

            Button {
                navigation.request(.models)
                openWindow(id: AppNavigationState.controlCenterWindowID)
            } label: {
                Label("管理模型", systemImage: AppRoute.models.systemImage)
                    .speechRailMenuRow()
            }

            Button {
                navigation.request(.voiceDesign)
                openWindow(id: AppNavigationState.controlCenterWindowID)
            } label: {
                Label("开始音色创作", systemImage: AppRoute.voiceDesign.systemImage)
                    .speechRailMenuRow()
            }
            .keyboardShortcut("N", modifiers: [.command])

            Divider()

            Button {
                pendingServiceAction = .start
            } label: {
                Label("启动服务", systemImage: "play.circle")
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
                Label("停止服务", systemImage: "stop.circle")
                    .speechRailMenuRow()
            }
            .disabled(
                model.isBusy
                    || model.hasActiveMutation
                    || model.isRefreshingService
                    || !canMutate
            )
            Button {
                pendingServiceAction = .restart
            } label: {
                Label("重启服务", systemImage: "arrow.clockwise.circle")
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
                openSettings()
            } label: {
                Text("打开设置")
                    .speechRailMenuRow()
            }
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
            if ProcessInfo.processInfo.arguments.contains("--ui-test-open-control-center") {
                openWindow(id: AppNavigationState.controlCenterWindowID)
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-open-settings") {
                openSettings()
            }
#endif
        }
    }

    private var statusSummary: String {
        if model.serviceOperation?.phase.isActive == true {
            return "服务操作进行中，请等待结果"
        }
        if model.serviceOperation?.phase == .failed {
            return "服务操作未完成，请重新读取"
        }
        if model.healthMessage != nil {
            switch model.healthFailure {
            case .some(.timeout):
                return "健康检查超时，请重新读取"
            case .some(.connection):
                return "服务未连接，请打开管理控制台"
            case .some(.invalidResponse), .some(.server):
                return "健康状态异常，请打开管理控制台"
            default:
                return "服务状态暂不可用，请打开管理控制台"
            }
        }
        if model.controlPlaneMessage != nil {
            return "服务状态已读取，但控制通道不可用"
        }
        if displayedHealth?.ready == true {
            if !model.controlAgentStatus.allowsMutation {
                return "本机服务已就绪，但控制受限"
            }
            return "本机服务已就绪"
        }
        if model.service.serviceState == "unavailable" {
            return "服务不可用，请打开控制台诊断"
        }
        return "服务尚未就绪"
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
