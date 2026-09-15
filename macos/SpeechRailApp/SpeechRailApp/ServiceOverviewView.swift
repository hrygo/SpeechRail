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
        PageScaffold(route: .overview) {
            statusArea
            ControlAgentStatusView()
            serviceBody
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceActionsMenu(helpText: "刷新状态、查看技术详情，或启动、停止和重启本机 SpeechRail 服务") {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("刷新服务状态", systemImage: "arrow.clockwise")
                            .speechRailMenuRow()
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
                        .speechRailMenuRow()
                    }
                    Divider()
                    serviceActions
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .inspector(isPresented: $showInspector) {
            DeveloperInspector {
                LabeledContent("服务", value: displayedHealth?.service ?? "未读取")
                LabeledContent("版本", value: displayedHealth?.version ?? "未读取")
                LabeledContent("后端", value: displayedHealth?.backend ?? "未读取")
                LabeledContent("端口", value: model.service.port.map(String.init) ?? "未读取")
                LabeledContent("LaunchAgent", value: ControlConstants.agentPlistName)
                LabeledContent("XPC 通道", value: ControlConstants.agentMachServiceName)
                LabeledContent("健康连接", value: healthConnectionSummary)
                LabeledContent(
                    "控制通道",
                    value: model.controlPlaneMessage == nil ? "已响应" : "不可用"
                )
                Divider()
                LabeledContent("运行档位", value: displayedHealth?.profile.map(SpeechRailProfilePresentation.title) ?? "未读取")
                LabeledContent("配置档位", value: model.profile?.preset.map(SpeechRailProfilePresentation.title) ?? "未读取")
                LabeledContent("配置代次", value: model.profile?.generation.map(String.init) ?? "未读取")
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
            await model.refreshPreflight()
            showInspector = showDeveloperDetails
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        if let operation = model.serviceOperation, operation.phase.isActive {
            ServiceOperationStatusView(operation: operation)
        } else {
            statusBanner
        }
    }

    private var statusBanner: some View {
        let operationFailed = model.serviceOperation?.phase == .failed
        let isProfileMismatch = profileMismatch
        let serviceReady = displayedHealth?.ready == true
            && model.healthMessage == nil
            && !operationFailed
            && !isProfileMismatch
        let canMutate = model.controlAgentStatus.allowsMutation
            && model.controlPlaneMessage == nil
        let isReady = serviceReady && canMutate
        let isUnavailable = model.service.serviceState == "unavailable"
            || model.healthMessage != nil
            || operationFailed
        let healthFailureIsCritical: Bool
        switch model.healthFailure {
        case .some(.connection), .some(.invalidResponse), .some(.server):
            healthFailureIsCritical = true
        default:
            healthFailureIsCritical = false
        }
        let tone: StatusTone = if isReady && canMutate {
            .healthy
        } else if isUnavailable && (operationFailed || healthFailureIsCritical) {
            .critical
        } else {
            .attention
        }
        // The panel reaches exactly four conclusions. Every specific cause
        // belongs in the impact sentence, not in a fifth headline
        // (REDESIGN-SPEC §7.5).
        let title: String
        if operationFailed {
            title = "服务操作未完成"
        } else if isReady {
            title = "服务已就绪"
        } else if isUnavailable && healthFailureIsCritical {
            title = "服务不可用"
        } else {
            title = "服务需要关注"
        }
        let cause: String? = if operationFailed {
            nil
        } else if isProfileMismatch {
            "服务正在运行的档位与当前配置不一致。"
        } else if model.healthFailure == .timeout {
            "健康检查超时。"
        } else if model.healthFailure == .connection {
            "无法连接本机服务。"
        } else if model.healthFailure == .invalidResponse {
            "健康响应无法解析。"
        } else if model.healthFailure != nil {
            "服务报告了异常状态。"
        } else if serviceReady && !canMutate {
            "服务可用，但控制通道受限。"
        } else {
            nil
        }
        let message = [cause, statusMessage]
            .compactMap { $0 }
            .joined(separator: " ")
        let actionTitle: String = if !canMutate {
            "打开诊断"
        } else if operationFailed {
            "重新读取"
        } else if isProfileMismatch {
            "打开模型管理"
        } else if model.healthFailure == .connection {
            "启动服务"
        } else if model.healthFailure != nil || model.healthMessage != nil {
            "重新读取"
        } else {
            isReady ? "重启服务" : "启动服务"
        }
        return StatusBanner(
            tone: tone,
            title: title,
            message: message,
            actionTitle: actionTitle,
            actionDisabled: model.isBusy
                || model.hasActiveMutation
                || model.isRefreshingService
                || model.serviceOperation?.phase.isActive == true
        ) {
            if !canMutate {
                navigation.request(.diagnostics)
            } else if operationFailed {
                Task { await model.refresh() }
            } else if isProfileMismatch {
                navigation.request(.models)
            } else if model.healthFailure == .connection {
                pendingAction = .start
            } else if model.healthFailure != nil || model.healthMessage != nil {
                Task { await model.refresh() }
            } else {
                pendingAction = isReady ? .restart : .start
            }
        }
    }

    private var serviceBody: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                SectionHeading(
                    title: "能力",
                    detail: "每项由当前运行档位和已验证模型共同决定；未就绪不代表服务异常。"
                )
                VStack(spacing: 0) {
                    ForEach(Array(capabilities.enumerated()), id: \.element.title) { index, capability in
                        if index > 0 {
                            Divider()
                        }
                        capabilityRow(capability)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                SectionHeading(
                    title: "运行信息",
                    detail: nil
                )
                VStack(alignment: .leading, spacing: 0) {
                    LabeledContent(
                        "运行档位",
                        value: displayedHealth?.profile.map(SpeechRailProfilePresentation.title) ?? "未读取"
                    )
                    LabeledContent(
                        "配置档位",
                        value: model.profile?.preset.map(SpeechRailProfilePresentation.title) ?? "未读取"
                    )
                    LabeledContent("端口", value: model.service.port.map(String.init) ?? "未读取")
                    LabeledContent("版本", value: displayedHealth?.version ?? "未读取")
                    LabeledContent("常驻 worker", value: residentWorkerText)
                    LabeledContent("作业队列", value: displayedHealth?.jobSpoolReady == true ? "可用" : "未就绪")
                }
                .speechRailInspectorContent()
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
                }
                preflightSummary
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailContentSurface()
    }

    /// `warm_capabilities` is the only field that names the lanes actually
    /// resident in memory, so it is what "常驻 worker" reports.
    private var residentWorkerText: String {
        guard let lifecycle = displayedHealth?.ttsLifecycle else { return "未读取" }
        let capabilities = lifecycle.warmCapabilities
            ?? lifecycle.warmCapability.map { [$0] }
            ?? []
        guard !capabilities.isEmpty else { return "无 TTS 常驻" }
        return capabilities.joined(separator: " + ")
    }

    private struct ServiceCapability: Equatable {
        let title: String
        let status: CapabilityStatus
        let reason: String
    }

    private enum CapabilityStatus: Equatable {
        case ready
        case notReady
        case unsupported

        var label: String {
            switch self {
            case .ready: "可用"
            case .notReady: "未就绪"
            case .unsupported: "当前档位不支持"
            }
        }

        var tone: StatusTone {
            switch self {
            case .ready: .healthy
            case .notReady: .critical
            case .unsupported: .neutral
            }
        }
    }

    /// Six capabilities, each with a status and one sentence of reason. Status
    /// never relies on colour alone (REDESIGN-SPEC §7.5, §9).
    private var capabilities: [ServiceCapability] {
        guard let health = displayedHealth else {
            let reason = model.healthFailure == nil
                ? "尚未读取服务健康快照。"
                : "健康检查未返回结果，无法确认这一项。"
            return [
                ServiceCapability(title: "语音识别", status: .notReady, reason: reason),
                ServiceCapability(title: "语音合成 · Base", status: .notReady, reason: reason),
                ServiceCapability(title: "语音合成 · VoiceDesign", status: .notReady, reason: reason),
                ServiceCapability(title: "音色复刻", status: .notReady, reason: reason),
                ServiceCapability(title: "实时语音 VAD", status: .notReady, reason: reason),
                ServiceCapability(title: "分人识别", status: .notReady, reason: reason),
            ]
        }

        let asrReady = health.asrReady == true
        let asrState = health.asrState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取 ASR 运行状态。"
        let ttsReady = health.ttsReady == true
        let ttsState = health.ttsState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取 TTS 运行状态。"
        let voiceDesignVoice = model.creatorVoices.first { voice in
            voice.available && voice.variant == "voice_design" && voice.capabilities.supportsInstruction
        }
        let cloneVoice = model.creatorVoices.first { voice in
            voice.available && voice.capabilities.supportsClone
        }
        let diarizationSupported = health.profile != .light

        return [
            ServiceCapability(
                title: "语音识别",
                status: asrReady ? .ready : .notReady,
                reason: asrReady ? "\(asrState)；词级时间戳由 ASR 原生提供。" : asrState
            ),
            ServiceCapability(
                title: "语音合成 · Base",
                status: ttsReady ? .ready : .notReady,
                reason: ttsState
            ),
            ServiceCapability(
                title: "语音合成 · VoiceDesign",
                status: voiceDesignVoice != nil ? .ready : (health.profile == .quality ? .notReady : .unsupported),
                reason: voiceDesignVoice != nil
                    ? "服务已公开可用的 VoiceDesign capability。"
                    : (health.profile == .quality
                        ? "Quality 档位下服务未公开 VoiceDesign capability。"
                        : "VoiceDesign 只在 Quality 档位加载。")
            ),
            ServiceCapability(
                title: "音色复刻",
                status: cloneVoice != nil ? .ready : .notReady,
                reason: cloneVoice != nil
                    ? "服务已公开可用的音色复刻 capability。"
                    : "服务未公开可用的音色复刻 capability。"
            ),
            ServiceCapability(
                title: "实时语音 VAD",
                status: health.realtimeVAD?.ready == true ? .ready : .notReady,
                reason: health.realtimeVAD?.message
                    ?? health.streamingState.map(SpeechRailRuntimeStatePresentation.text)
                    ?? "未读取实时语音状态。"
            ),
            ServiceCapability(
                title: "分人识别",
                status: diarizationSupported
                    ? (health.diarizationReady == true ? .ready : .notReady)
                    : .unsupported,
                reason: diarizationSupported
                    ? (health.diarization.map { SpeechRailDiarizationPresentation.text($0) }
                        ?? (health.diarizationReady == true
                            ? "只输出本次会话的匿名标签；不管理实名或声纹库。"
                            : "分人 worker 尚未就绪。"))
                    : "Light 档位不加载分人能力。"
            ),
        ]
    }

    private var preflightSummary: some View {
        let failedCount = model.preflightChecks.filter { !$0.ok }.count
        let isOperating = model.serviceOperation?.phase.isActive == true
        let tone: StatusTone
        if isOperating || model.isRefreshingPreflight {
            tone = .attention
        } else if model.preflightMessage != nil {
            tone = .critical
        } else if model.preflightChecks.isEmpty {
            tone = .neutral
        } else {
            tone = failedCount == 0 ? .healthy : .critical
        }

        let title: String
        if isOperating {
            title = "等待服务操作完成"
        } else if model.isRefreshingPreflight {
            title = "正在读取预检"
        } else if model.preflightMessage != nil {
            title = "预检读取失败"
        } else if model.preflightChecks.isEmpty {
            title = "尚未运行预检"
        } else if failedCount == 0 {
            title = "预检通过"
        } else {
            title = "预检需要处理"
        }

        let detail: String
        if isOperating {
            detail = "服务操作期间不沿用旧结论，终态会重新读取服务与预检状态。"
        } else if model.isRefreshingPreflight {
            detail = "正在核对运行环境、配置和模型制品。"
        } else if let message = model.preflightMessage, !message.isEmpty {
            detail = SpeechRailOperationMessagePresentation.text(message)
        } else if model.preflightChecks.isEmpty {
            detail = "运行预检后，这里会给出是否可以继续使用的结论。"
        } else if failedCount == 0 {
            detail = "环境与配置满足当前控制面的检查条件。"
        } else {
            detail = "有 \(failedCount) 项前置条件需要处理，打开诊断查看修复路径。"
        }

        return ViewThatFits(in: .horizontal) {
            preflightSummaryHorizontal(tone: tone, title: title, detail: detail, isOperating: isOperating)
            preflightSummaryVertical(tone: tone, title: title, detail: detail, isOperating: isOperating)
        }
        .padding(.top, SpeechRailDesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("预检，\(title)，\(detail)")
    }

    private func preflightSummaryHorizontal(
        tone: StatusTone,
        title: String,
        detail: String,
        isOperating: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            preflightSummaryIcon(tone)
            preflightSummaryCopy(title: title, detail: detail)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            preflightSummaryAction(isOperating: isOperating)
        }
    }

    private func preflightSummaryVertical(
        tone: StatusTone,
        title: String,
        detail: String,
        isOperating: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
                preflightSummaryIcon(tone)
                preflightSummaryCopy(title: title, detail: detail)
            }
            preflightSummaryAction(isOperating: isOperating)
        }
    }

    private func preflightSummaryIcon(_ tone: StatusTone) -> some View {
        Image(systemName: tone.systemImage)
            .foregroundStyle(tone.color)
            .accessibilityHidden(true)
    }

    private func preflightSummaryCopy(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.label)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(detail)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func preflightSummaryAction(isOperating: Bool) -> some View {
        Button("查看诊断") {
            navigation.request(.diagnostics)
        }
        .speechRailButton(.quiet)
        .disabled(isOperating || model.isRefreshingPreflight)
    }

    private func capabilityRow(_ capability: ServiceCapability) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: capability.status.tone.systemImage)
                .foregroundStyle(capability.status.tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(capability.title)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(capability.reason)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            Text(capability.status.label)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(capability.status.tone.color)
                .lineLimit(1)
                .frame(width: SpeechRailDesignTokens.Layout.monitoringStatusColumnWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SpeechRailDesignTokens.List.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(capability.title)，\(capability.status.label)，\(capability.reason)")
    }

    private var serviceActions: some View {
        Group {
            Button {
                pendingAction = .start
            } label: {
                Label("启动服务", systemImage: "play.circle")
                    .speechRailMenuRow()
            }
                .disabled(
                    model.isBusy
                        || model.hasActiveMutation
                        || model.isRefreshingService
                        || !model.controlAgentStatus.allowsMutation
                        || model.controlPlaneMessage != nil
                )
            Button {
                pendingAction = .stop
            } label: {
                Label("停止服务", systemImage: "stop.circle")
                    .speechRailMenuRow()
            }
                .disabled(
                    model.isBusy
                        || model.hasActiveMutation
                        || model.isRefreshingService
                        || !model.controlAgentStatus.allowsMutation
                        || model.controlPlaneMessage != nil
                )
            Button {
                pendingAction = .restart
            } label: {
                Label("重启服务", systemImage: "arrow.clockwise.circle")
                    .speechRailMenuRow()
            }
                .disabled(
                    model.isBusy
                        || model.hasActiveMutation
                        || model.isRefreshingService
                        || !model.controlAgentStatus.allowsMutation
                        || model.controlPlaneMessage != nil
                )
        }
    }

    private var statusMessage: String {
        if let operation = model.serviceOperation, operation.phase == .failed {
            let detail = operation.message.map(SpeechRailOperationMessagePresentation.text)
                ?? "服务命令未完成"
            return "\(detail)。没有把旧的健康快照当作成功结果，请重新读取或打开诊断。"
        }
        if profileMismatch,
           let configured = model.profile?.preset,
           let runtime = displayedHealth?.profile
        {
            return "服务正在运行 \(SpeechRailProfilePresentation.title(runtime))，但配置档位为 \(SpeechRailProfilePresentation.title(configured))。请打开模型管理重新应用目标档位。"
        }
        if let healthMessage = model.healthMessage {
            let lastRead = model.lastHealthRefresh.map { "最近成功读取于 \(relativeTime($0))" } ?? "尚无成功读取"
            return "\(healthMessage)。\(lastRead)。"
        }
        if model.controlPlaneMessage != nil {
            return "SpeechRail 健康状态已单独读取，但控制通道不可用。只读健康信息仍可查看，请打开诊断。"
        }
        if displayedHealth?.ready == true {
            let profile = displayedHealth?.profile.map(SpeechRailProfilePresentation.title) ?? "运行档位未读取"
            if !model.controlAgentStatus.allowsMutation {
                return "SpeechRail 已准备好接收本机语音请求。当前运行档位：\(profile)。但控制 Agent 受限，服务操作和档位变更暂不可用；只读诊断仍可使用。"
            }
            return "SpeechRail 已准备好接收本机语音请求。当前运行档位：\(profile)。"
        }
        if model.service.serviceState == "unavailable" {
            return "本机服务尚未响应健康检查；如果刚执行过启动或重启，请等待操作完成后重新读取。"
        }
        if !model.controlAgentStatus.allowsMutation {
            return "\(model.controlAgentStatus.detail) 只读诊断仍可使用。"
        }
        return "先启动服务或运行预检，控制台会说明阻塞原因。"
    }

    private func relativeTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private var healthConnectionSummary: String {
        if let healthFailure = model.healthFailure {
            switch healthFailure {
            case .connection:
                return "health 无法连接"
            case .timeout:
                return "health 响应超时"
            case .invalidResponse:
                return "health 响应无效"
            case .server:
                return "health 返回服务错误"
            }
        }
        if displayedHealth != nil { return "health 已响应" }
        return "未读取"
    }

    private var displayedHealth: HealthSnapshot? {
        guard model.healthFailure == nil else { return nil }
        return model.health
    }

    private var profileMismatch: Bool {
        guard let configured = model.profile?.preset,
              let runtime = displayedHealth?.profile
        else { return false }
        return configured != runtime
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
