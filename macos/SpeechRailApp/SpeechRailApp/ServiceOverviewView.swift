import Foundation
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
                statusArea
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
            ToolbarItem(placement: .primaryAction) {
                WorkspaceActionsMenu(helpText: "刷新状态、查看技术详情，或启动、停止和重启本机 SpeechRail 服务") {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("刷新服务状态", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshingService)
                    Divider()
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(
                            showInspector ? "隐藏开发者详情" : "显示开发者详情",
                            systemImage: "info.circle"
                        )
                    }
                    Divider()
                    serviceActions
                }
            }
            .sharedBackgroundVisibility(.hidden)
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
                Button(
                    actionTitle(for: pendingAction),
                    role: isDestructive(pendingAction) ? .destructive : nil
                ) {
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

    @ViewBuilder
    private var statusArea: some View {
        if let operation = model.serviceOperation {
            ServiceOperationStatusView(
                operation: operation,
                actionTitle: operation.phase == .failed ? "重新读取" : nil
            ) {
                Task { await model.refresh() }
            }
        }
        if model.serviceOperation?.phase.isActive != true {
            statusBanner
        }
    }

    private var statusBanner: some View {
        let isReady = model.service.ready == true && model.healthMessage == nil
        let isUnavailable = model.service.serviceState == "unavailable" || model.healthMessage != nil
        let canMutate = model.controlAgentStatus.allowsMutation
        let tone: StatusTone = if isReady {
            .healthy
        } else if isUnavailable {
            .critical
        } else {
            .attention
        }
        let actionTitle: String = if model.healthMessage != nil {
            "重新读取"
        } else if canMutate {
            isReady ? "重启服务" : "启动服务"
        } else {
            "打开诊断"
        }
        return StatusBanner(
            tone: tone,
            title: isReady ? "服务可用" : (isUnavailable ? "服务不可用" : "服务尚未就绪"),
            message: statusMessage,
            actionTitle: actionTitle,
            actionDisabled: model.isBusy
                || model.hasActiveMutation
                || model.isRefreshingService
                || model.serviceOperation?.phase.isActive == true
        ) {
            if model.healthMessage != nil {
                Task { await model.refresh() }
            } else if canMutate {
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
                        detail: model.health?.asrState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取",
                        ready: model.health?.asrReady
                    )
                    Divider()
                    capabilityRow(
                        title: "语音合成",
                        detail: model.health?.ttsState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取",
                        ready: model.health?.ttsReady
                    )
                    Divider()
                    capabilityRow(
                        title: "实时语音",
                        detail: model.health?.streamingState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取",
                        ready: model.health?.realtimeVAD?.ready
                    )
                    Divider()
                    capabilityRow(
                        title: "分人识别",
                        detail: model.health?.diarization.map { SpeechRailDiarizationPresentation.text($0) }
                            ?? "按当前档位启用",
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
                    Button {
                        Task { await model.refreshPreflight() }
                    } label: {
                        Label("运行预检", systemImage: AppRoute.diagnostics.systemImage)
                    }
                    .speechRailButton(.secondary)
                    .disabled(model.isBusy || model.isRefreshingPreflight)
                    Button {
                        navigation.request(.models)
                    } label: {
                        Label("打开模型管理", systemImage: AppRoute.models.systemImage)
                    }
                    .speechRailButton(.secondary)
                    if let message = model.message, !message.isEmpty {
                        Text(SpeechRailOperationMessagePresentation.text(message))
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
    }

    private func capabilityRow(title: String, detail: String, ready: Bool?) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: capabilityIcon(ready))
                .foregroundStyle(capabilityColor(ready))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(title)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(detail)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            Text(capabilityStatus(ready))
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(capabilityColor(ready))
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(capabilityStatus(ready))，\(detail)")
    }

    private func capabilityStatus(_ ready: Bool?) -> String {
        switch ready {
        case .some(true):
            "已就绪"
        case .some(false):
            "未就绪"
        case .none:
            "未读取"
        }
    }

    private func capabilityColor(_ ready: Bool?) -> SwiftUI.Color {
        switch ready {
        case .some(true):
            SpeechRailDesignTokens.Color.ready
        case .some(false):
            SpeechRailDesignTokens.Color.critical
        case .none:
            SpeechRailDesignTokens.Color.inkSecondary
        }
    }

    private func capabilityIcon(_ ready: Bool?) -> String {
        switch ready {
        case .some(true):
            "checkmark.circle.fill"
        case .some(false):
            "xmark.circle.fill"
        case .none:
            "questionmark.circle"
        }
    }

    private var serviceActions: some View {
        Group {
            Button {
                pendingAction = .start
            } label: {
                Label("启动服务", systemImage: "play.circle")
            }
                .disabled(
                    model.isBusy
                        || model.hasActiveMutation
                        || model.isRefreshingService
                        || !model.controlAgentStatus.allowsMutation
                )
            Button {
                pendingAction = .stop
            } label: {
                Label("停止服务", systemImage: "stop.circle")
            }
                .disabled(
                    model.isBusy
                        || model.hasActiveMutation
                        || model.isRefreshingService
                        || !model.controlAgentStatus.allowsMutation
                )
            Button {
                pendingAction = .restart
            } label: {
                Label("重启服务", systemImage: "arrow.clockwise.circle")
            }
                .disabled(
                    model.isBusy
                        || model.hasActiveMutation
                        || model.isRefreshingService
                        || !model.controlAgentStatus.allowsMutation
                )
        }
    }

    private var statusMessage: String {
        if let healthMessage = model.healthMessage {
            let lastRead = model.lastHealthRefresh.map { "最近成功读取于 \(relativeTime($0))" } ?? "尚无成功读取"
            return "\(healthMessage)。\(lastRead)。"
        }
        if model.service.ready == true {
            let profile = model.profile?.preset.map { SpeechRailProfilePresentation.title($0) } ?? "未读取"
            return "SpeechRail 已准备好接收本机语音请求。当前档位：\(profile)。"
        }
        if model.service.serviceState == "unavailable" {
            return "控制中心暂时无法读取 SpeechRail，通常意味着服务尚未启动或正在重新启动。"
        }
        if !model.controlAgentStatus.allowsMutation {
            return "\(model.controlAgentStatus.detail) 只读诊断仍可使用。"
        }
        return "先启动服务或运行预检，控制台会说明阻塞原因。"
    }

    private func relativeTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
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

    private func isDestructive(_ command: ControlCommand) -> Bool {
        command == .stop || command == .restart
    }
}
