import SpeechRailControlKit
import SwiftUI

public struct ServiceOverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @State private var pendingAction: ControlCommand?
    @State private var showInspector = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                PageIntroView(route: .overview)
                statusBanner
                ControlAgentStatusView()
                serviceBody
            }
            .frame(maxWidth: SpeechRailDesignTokens.Layout.contentMaximumWidth, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xl)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("开发者详情", systemImage: "info.circle")
                }
                .help("显示当前服务和控制 Agent 的技术详情")
            }
            ToolbarItem {
                serviceActions
            }
        }
        .inspector(isPresented: $showInspector) {
            DeveloperInspector {
                LabeledContent("服务", value: model.health?.service ?? "未读取")
                LabeledContent("版本", value: model.health?.version ?? "未读取")
                LabeledContent("后端", value: model.health?.backend ?? "未读取")
                LabeledContent("端口", value: model.service.port.map(String.init) ?? "未读取")
                Divider()
                LabeledContent("控制 Agent", value: model.controlAgentStatus.title)
                LabeledContent("影响", value: model.controlAgentStatus.impact)
            }
        }
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
        .task {
            model.refreshControlAgentStatus()
            await model.refresh()
            showInspector = showDeveloperDetails
        }
    }

    private var statusBanner: some View {
        let isReady = model.service.ready == true
        let canMutate = model.controlAgentStatus.allowsMutation
        let tone: StatusTone = isReady ? .healthy : .attention
        let actionTitle: String = if canMutate {
            isReady ? "重启服务" : "启动服务"
        } else {
            "打开诊断"
        }
        return StatusBanner(
            tone: tone,
            title: isReady ? "服务可用" : "服务尚未就绪",
            message: statusMessage,
            actionTitle: actionTitle
        ) {
            if canMutate {
                pendingAction = isReady ? .restart : .start
            } else {
                navigation.request(.diagnostics)
            }
        }
    }

    private var serviceBody: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                SectionHeading(
                    title: "能力",
                    detail: "这些能力由当前运行档位和已验证模型共同决定。"
                )
                VStack(spacing: 0) {
                    capabilityRow(
                        title: "语音识别",
                        detail: model.health?.asrState ?? "未读取",
                        ready: model.health?.asrReady
                    )
                    Divider()
                    capabilityRow(
                        title: "语音合成",
                        detail: model.health?.ttsState ?? "未读取",
                        ready: model.health?.ttsReady
                    )
                    Divider()
                    capabilityRow(
                        title: "实时语音",
                        detail: model.health?.streamingState ?? "未读取",
                        ready: model.health?.realtimeVAD?.ready
                    )
                    Divider()
                    capabilityRow(
                        title: "分人识别",
                        detail: model.health?.diarization?.message ?? "按当前档位启用",
                        ready: model.health?.diarizationReady
                    )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                SectionHeading(
                    title: "下一步",
                    detail: "预检只读取环境和配置，不会下载模型或改变当前服务。"
                )
                HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                    Button("运行预检") {
                        Task { await model.refreshPreflight() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                    Button("打开模型") {
                        navigation.request(.models)
                    }
                    .buttonStyle(.bordered)
                    if let message = model.message, !message.isEmpty {
                        Text(message)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Palette.critical)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailContentSurface()
    }

    private func capabilityRow(title: String, detail: String, ready: Bool?) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: ready == true ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(
                    ready == true
                        ? SpeechRailDesignTokens.Palette.healthy
                        : SpeechRailDesignTokens.Palette.secondaryText
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.body)
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            Text(ready == true ? "已就绪" : "未就绪")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(
                    ready == true
                        ? SpeechRailDesignTokens.Palette.healthy
                        : SpeechRailDesignTokens.Palette.secondaryText
                )
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(ready == true ? "已就绪" : "未就绪")，\(detail)")
    }

    private var serviceActions: some View {
        Menu {
            Button("启动服务") { pendingAction = .start }
                .disabled(model.isBusy || !model.controlAgentStatus.allowsMutation)
            Button("停止服务") { pendingAction = .stop }
                .disabled(model.isBusy || !model.controlAgentStatus.allowsMutation)
            Button("重启服务") { pendingAction = .restart }
                .disabled(model.isBusy || !model.controlAgentStatus.allowsMutation)
        } label: {
            Label("服务操作", systemImage: "ellipsis.circle")
        }
        .help("启动、停止或重启本机 SpeechRail 服务")
    }

    private var statusMessage: String {
        if model.service.ready == true {
            return "SpeechRail 已准备好接收本机语音请求。当前档位：\(model.profile?.preset?.rawValue ?? "未读取")。"
        }
        if !model.controlAgentStatus.allowsMutation {
            return "\(model.controlAgentStatus.detail) 只读诊断仍可使用。"
        }
        return "先启动服务或运行预检，控制台会说明阻塞原因。"
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
        case .start:
            "确认启动本机服务？"
        case .stop:
            "确认停止本机服务？所有客户端都会暂时不可用。"
        case .restart:
            "确认重启本机服务？正在处理的请求可能受到影响。"
        default:
            "确认操作？"
        }
    }

    private func actionTitle(for command: ControlCommand) -> String {
        switch command {
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
