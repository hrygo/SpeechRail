import SwiftUI

struct ControlAgentStatusView: View {
    @Environment(AppModel.self) private var model
    let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: model.controlAgentStatus.allowsMutation
                ? "checkmark.shield.fill"
                : "exclamationmark.shield.fill")
                .foregroundStyle(model.controlAgentStatus.allowsMutation
                    ? SpeechRailDesignTokens.Color.ready
                    : SpeechRailDesignTokens.Color.attention)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(model.controlAgentStatus.title)
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Text(model.controlAgentStatus.detail)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text("影响：\(model.controlAgentStatus.impact)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                if !compact {
                    action
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
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
            .speechRailButton(.secondary)
            .accessibilityIdentifier("enable-control-agent")
        case .openLoginItems:
            Button("打开登录项设置") {
                model.openControlAgentSettings()
            }
            .speechRailButton(.secondary)
            .accessibilityIdentifier("open-login-items")
        case .installAgent:
            Text("请重新安装包含控制 Agent 的 SpeechRail 应用包。")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.attention)
        case .none, .unavailable:
            EmptyView()
        }
    }
}
