import SwiftUI

struct ControlAgentStatusView: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Label {
                Text(model.controlAgentStatus.title)
                    .font(SpeechRailDesignTokens.Typography.panelTitle)
            } icon: {
                Image(systemName: model.controlAgentStatus.allowsMutation
                    ? "checkmark.shield.fill"
                    : "exclamationmark.shield.fill")
                .foregroundStyle(model.controlAgentStatus.allowsMutation
                    ? SpeechRailDesignTokens.Palette.success
                    : SpeechRailDesignTokens.Palette.warning)
            }
            Text(model.controlAgentStatus.detail)
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            Text("影响：\(model.controlAgentStatus.impact)")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)

            if !compact {
                action
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("control-agent-status")
    }

    @ViewBuilder
    private var action: some View {
        switch model.controlAgentStatus.action {
        case .register:
            Button("启用控制 Agent") {
                model.enableControlAgent()
            }
            .accessibilityIdentifier("enable-control-agent")
        case .openLoginItems:
            Button("打开登录项设置") {
                model.openControlAgentSettings()
            }
            .accessibilityIdentifier("open-login-items")
        case .installAgent:
            Text("请重新安装包含控制 Agent 的 SpeechRail 应用包。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Palette.warning)
        case .none, .unavailable:
            EmptyView()
        }
    }
}
