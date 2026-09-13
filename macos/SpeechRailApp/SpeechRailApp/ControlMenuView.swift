import SwiftUI
import SpeechRailControlKit

public struct ControlMenuView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var pendingServiceAction: ControlCommand?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                Image(systemName: "waveform")
                    .foregroundStyle(SpeechRailDesignTokens.Palette.railSignal)
                Text("SpeechRail")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                ServiceStatusBadge()
            }
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(statusSummary)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                Text(model.service.serviceState)
                    .font(SpeechRailDesignTokens.Typography.technical)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            }

            Divider()

            Button {
                openWindow(id: AppNavigationState.controlCenterWindowID)
            } label: {
                Label("打开管理控制台", systemImage: "rectangle.3.group")
            }
            .keyboardShortcut("0", modifiers: [.command, .option])

            Button {
                navigation.request(.voiceDesign)
                openWindow(id: AppNavigationState.controlCenterWindowID)
            } label: {
                Label("开始音色创作", systemImage: "waveform")
            }
            .keyboardShortcut("N", modifiers: [.command])

            Divider()

            Button("启动服务") {
                pendingServiceAction = .start
            }
            .disabled(model.isBusy)
            Button("停止服务") {
                pendingServiceAction = .stop
            }
            .disabled(model.isBusy)
            Button("重启服务") {
                pendingServiceAction = .restart
            }
            .disabled(model.isBusy)

            Divider()

            Button("打开设置") {
                openSettings()
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .frame(minWidth: 280, alignment: .leading)
        .confirmationDialog(
            confirmationTitle,
            isPresented: isConfirmingServiceAction,
            titleVisibility: .visible
        ) {
            if let pendingServiceAction {
                Button(confirmationButtonTitle(for: pendingServiceAction), role: .destructive) {
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
            if ProcessInfo.processInfo.arguments.contains("--ui-test-open-control-center") {
                openWindow(id: AppNavigationState.controlCenterWindowID)
            }
        }
    }

    private var statusSummary: String {
        if model.service.ready == true {
            return "本机服务已就绪"
        }
        if model.service.serviceState == "unavailable" {
            return "服务不可用，请打开控制台诊断"
        }
        return "服务尚未就绪"
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
}
