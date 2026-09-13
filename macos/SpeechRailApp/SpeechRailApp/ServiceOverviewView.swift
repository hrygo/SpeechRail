import SwiftUI
import SpeechRailControlKit

public struct ServiceOverviewView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @State private var pendingAction: ControlCommand?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                SurfaceHeaderView(route: .overview)
                GlassEffectContainer(spacing: SpeechRailDesignTokens.Spacing.lg) {
                    readinessCard
                    ControlAgentStatusView()
                    capabilityGrid
                    serviceControls
                    technicalDetails
                }
                ServiceStatusFooterView()
            }
            .frame(maxWidth: SpeechRailDesignTokens.Layout.contentMaximumWidth, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xl)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .confirmationDialog(
            confirmationTitle,
            isPresented: isConfirmingAction,
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(actionTitle(for: pendingAction), role: .destructive) {
                    let command = pendingAction
                    self.pendingAction = nil
                    Task { await model.execute(command) }
                }
            }
            Button("取消", role: .cancel) {
                pendingAction = nil
            }
        }
        .task { await model.refresh() }
    }

    private var readinessCard: some View {
        let isReady = model.service.ready == true
        return HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(
                    isReady
                        ? SpeechRailDesignTokens.Palette.success
                        : SpeechRailDesignTokens.Palette.warning
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xxs) {
                Text("服务状态")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                Text(isReady ? "服务可用" : "服务尚未就绪")
                    .font(SpeechRailDesignTokens.Typography.sectionTitle)
                Text(
                    isReady
                        ? "SpeechRail 已准备好接收本机语音请求。"
                        : "先启动服务或运行预检，控制台会说明阻塞原因。"
                )
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            }
            Spacer()
            if let profile = model.profile?.preset {
                Text(profile.rawValue)
                    .font(SpeechRailDesignTokens.Typography.technical)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isReady ? "服务可用" : "服务尚未就绪")
    }

    private var capabilityGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            alignment: .leading,
            spacing: SpeechRailDesignTokens.Spacing.md
        ) {
            CapabilityTile(
                title: "语音识别",
                detail: model.health?.asrState ?? "未读取",
                ready: model.health?.asrReady
            )
            CapabilityTile(
                title: "语音合成",
                detail: model.health?.ttsState ?? "未读取",
                ready: model.health?.ttsReady
            )
            CapabilityTile(
                title: "分人识别",
                detail: model.health?.diarization?.message ?? "按档位启用",
                ready: model.health?.diarizationReady
            )
            CapabilityTile(
                title: "实时语音",
                detail: model.health?.streamingState ?? "未读取",
                ready: model.health?.realtimeVAD?.ready
            )
        }
    }

    private var serviceControls: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("服务控制")
                .font(SpeechRailDesignTokens.Typography.panelTitle)
            Text("启动、停止和重启会影响所有使用 SpeechRail 的客户端。每次操作都会先要求确认。")
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Button("启动服务") { pendingAction = .start }
                Button("停止服务") { pendingAction = .stop }
                Button("重启服务") { pendingAction = .restart }
            }
            .disabled(model.isBusy || !model.controlAgentStatus.allowsMutation)
            if let message = model.message {
                Text(message)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.critical)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }

    private var technicalDetails: some View {
        DisclosureGroup("技术详情", isExpanded: $showDeveloperDetails) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                detailRow("服务", model.health?.service ?? "未读取")
                detailRow("版本", model.health?.version ?? "未读取")
                detailRow("后端", model.health?.backend ?? "未读取")
                detailRow("端口", model.service.port.map(String.init) ?? "未读取")
            }
            .padding(.top, SpeechRailDesignTokens.Spacing.xs)
        }
        .font(SpeechRailDesignTokens.Typography.secondary)
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(SpeechRailDesignTokens.Typography.technical)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
        }
    }

    private var isConfirmingAction: Binding<Bool> {
        Binding(
            get: { pendingAction != nil },
            set: { isPresented in
                if !isPresented { pendingAction = nil }
            }
        )
    }

    private var confirmationTitle: String {
        guard let pendingAction else { return "确认操作" }
        return switch pendingAction {
        case .start: "确认启动本机服务？"
        case .stop: "确认停止本机服务？"
        case .restart: "确认重启本机服务？"
        default: "确认操作？"
        }
    }

    private func actionTitle(for command: ControlCommand) -> String {
        switch command {
        case .start: "启动服务"
        case .stop: "停止服务"
        case .restart: "重启服务"
        default: "确认"
        }
    }
}

private struct CapabilityTile: View {
    let title: String
    let detail: String
    let ready: Bool?

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: ready == true ? "checkmark.circle" : "circle.dashed")
                .foregroundStyle(
                    ready == true
                        ? SpeechRailDesignTokens.Palette.success
                        : SpeechRailDesignTokens.Palette.secondaryText
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xxs) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.panelTitle)
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(SpeechRailDesignTokens.Spacing.md)
        .speechRailSurface(.panel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(detail)")
    }
}
