import Foundation
import SpeechRailControlKit
import SwiftUI

public struct ServiceOverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    /// 开发者详情是全 App 的一个偏好（View ▸ 显示/隐藏开发者详情 ⌘⌥I）。
    @AppStorage("speechrail.showDeveloperDetails") private var showInspector = false
    @State private var pendingAction: ControlCommand?

    public init() {}

    public var body: some View {
        PageScaffold(route: .overview) {
            if isAwaitingFirstHealthRead {
                loadingState
            } else {
                statusArea
                ControlAgentStatusView()
                serviceBody
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // 这一页的主动作就是服务生命周期，所以它拿到一个**具体的**标签：
                // 启动 / 停止 / 重启不再藏在通用的「更多操作」下（§6.2）。
                PageActionsMenu(
                    title: "服务",
                    systemImage: "power",
                    helpText: "启动、停止或重启本机 SpeechRail 服务"
                ) {
                    serviceActions
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .focusedSceneValue(
            \.reloadPageCommand,
            ReloadPageCommand(title: "重新读取服务状态") {
                Task { await model.refresh() }
            }
        )
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
                LabeledContent("作业队列", value: displayedHealth?.jobSpoolReady == true ? "可用" : "未就绪")
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

    /// REDESIGN-SPEC §8：服务四页的「加载中」是 `ProgressView`。首次 health
    /// 读取有结果之前，页面不给结论，也不用一屏「未就绪」占位冒充事实——
    /// 那正是「空列表 + 0 值」。
    private var isAwaitingFirstHealthRead: Bool {
        model.lastHealthRefresh == nil && model.healthFailure == nil
    }

    private var loadingState: some View {
        ProgressView("正在读取服务状态…")
            .frame(
                maxWidth: .infinity,
                minHeight: SpeechRailDesignTokens.Layout.emptyStateMinimumHeight
            )
            .speechRailContentSurface()
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
            kind: .conclusion,
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
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.gutter) {
            capabilitiesCard
            runtimeCard
        }
    }

    /// Figma `capabilities`：标题带一句话说明，下面是一条能力矩阵。名称与状态各占
    /// 固定列，说明从同一 x 起排；否则矩阵会退化成六行长短不齐的句子
    /// （REDESIGN-SPEC §7.5）。
    private var capabilitiesCard: some View {
        CardSurface {
            CardHead(
                title: "能力",
                detail: "按当前运行档位如实发布，不做能力预支。"
            )
            Divider()
            ForEach(Array(capabilities.enumerated()), id: \.element.title) { index, capability in
                if index > 0 {
                    Divider()
                }
                capabilityRow(capability)
            }
        }
    }

    /// Figma `runtime`：这一页就是为看结论与事实而打开的，取值直接列出，
    /// 不再藏在一次点击之后（REDESIGN-SPEC §7.5）。规范与 Figma 稿在这一卡里
    /// 都只放四行事实（档位 / 端口 / 版本 / 已加载的模型）；配置档位、配置代次与
    /// 作业队列属于同一批技术事实，跟随开发者详情，而不是把这张卡撑成一张表。
    private var runtimeCard: some View {
        CardSurface {
            CardHead(
                title: "运行信息",
                detail: "只反映此刻的取值；要换档位或改运行方式，去「模型」页。"
            )
            Divider()
            runtimeRow(
                "当前档位",
                displayedHealth?.profile.map(SpeechRailProfilePresentation.title) ?? "未读取"
            )
            Divider()
            runtimeRow("服务端口", serviceAddressText)
            Divider()
            runtimeRow("运行版本", displayedHealth?.version ?? "未读取")
            Divider()
            runtimeRow("已加载的模型", residentWorkerText)
        }
    }

    private func runtimeRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(label)
                .font(SpeechRailDesignTokens.Typography.bodyMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .frame(
                    width: SpeechRailDesignTokens.Layout.serviceRuntimeLabelWidth,
                    alignment: .leading
                )
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        // 稿的 `infoRow` 是 padY 10 + Body 行（19.5）= 40pt 带；应用的行高 16，
        // 取 `sm`(12) 补回同一档带高（帧实测 39.5）。REDESIGN-SPEC §11.6 第二十一轮。
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，\(value)")
    }

    /// Figma `runtime` 的「服务端口」行是 `host:port`：只报端口时看不出这一行连的是哪台
    /// 主机。主机名由诊断客户端给出，拿不到时如实退回端口。
    private var serviceAddressText: String {
        guard let port = model.service.port.map(String.init) else { return "未读取" }
        guard let host = model.serviceConnectionHost, !host.isEmpty else { return port }
        return "\(host):\(port)"
    }

    /// `warm_capabilities` is the only field that names the lanes actually
    /// resident in memory, so it is what "常驻 worker" reports.
    /// 「已加载的模型」那一行的取值。
    ///
    /// 服务给的是 `voice_design` / `voice_clone` / `tts` 这类内部名（`/health` 的
    /// `tts_lifecycle.warm_capabilities`）——它们**会原样漏到这一页上**，用户看到的是
    /// 一串英文下划线名。页面上换成人话；内部名留在开发者详情与文档里
    /// （用户 2026-09-19：「有一些用户看不懂的词汇」）。
    private var residentWorkerText: String {
        guard let lifecycle = displayedHealth?.ttsLifecycle else { return "未读取" }
        let capabilities = lifecycle.warmCapabilities
            ?? lifecycle.warmCapability.map { [$0] }
            ?? []
        // 没有常驻就是"没有"：`无 TTS 常驻` 里那个 TTS 是给排障看的写法。
        guard !capabilities.isEmpty else { return "没有" }
        return capabilities.map(Self.residentCapabilityTitle).joined(separator: " + ")
    }

    private static func residentCapabilityTitle(_ raw: String) -> String {
        switch raw.lowercased() {
        case "voice_design": "语音设计"
        case "voice_clone": "音色克隆"
        case "tts": "内置音色"
        case "both": "语音设计 + 音色克隆"
        default: raw
        }
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
                ServiceCapability(title: "语音合成 · VoiceDesign", status: .notReady, reason: reason),
                ServiceCapability(title: "语音合成 · Base", status: .notReady, reason: reason),
                ServiceCapability(title: "音色复刻", status: .notReady, reason: reason),
                ServiceCapability(title: "实时语音断句", status: .notReady, reason: reason),
                ServiceCapability(title: "说话人区分", status: .notReady, reason: reason),
            ]
        }

        let asrReady = health.asrReady == true
        let asrState = health.asrState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取 ASR 运行状态。"
        let ttsReady = health.ttsReady == true
        let ttsState = health.ttsState.map(SpeechRailRuntimeStatePresentation.text) ?? "未读取 TTS 运行状态。"
        // 能力结论只读服务声明（`/v1/models.capabilities`）：音色列表是用户数据，
        // 可以为空，而 capability 由当前档位与制品解析决定。拿“列表里有没有某一类
        // 音色”当能力依据，会在服务已经发布能力时报出假的“未就绪”。
        let declaredCapabilities = model.serviceCapabilitiesLoadState == .loaded
            ? model.serviceCapabilities
            : nil
        let supportsQualityTier = health.profile == .quality
        let voiceDesign = capabilityVerdict(
            // 页面上不摆内部名：`VoiceDesign` / `Base` 是制品名，用户看到的是"两种合成各能做什么"。
            title: "语音合成 · 语音设计",
            capability: "语音设计",
            declared: declaredCapabilities?.supportsInstruction,
            supportedByProfile: supportsQualityTier,
            missingReason: "这一档没有发布「语音设计」。",
            unsupportedReason: "语音设计只在最准的一档（精准）加载。"
        )
        let voiceClone = capabilityVerdict(
            // 名字跟着侧栏那一项走：用户点的、看到的、读到的都是「音色克隆」。
            // `复刻` 是能力声明里的措辞，留在开发者文档里（用户 2026-09-19）。
            title: "音色克隆",
            capability: "音色克隆",
            declared: declaredCapabilities?.supportsClone,
            supportedByProfile: supportsQualityTier,
            missingReason: "这一档没有发布音色克隆（需要的模型还没就位）。",
            unsupportedReason: "音色克隆只在「精准」这一档加载。"
        )
        let diarization = diarizationCapability(for: health)

        return [
            ServiceCapability(
                title: "语音识别",
                status: asrReady ? .ready : .notReady,
                reason: asrReady ? "\(asrState)；每个字的时间点由识别模型直接给出。" : asrState
            ),
            voiceDesign,
            ServiceCapability(
                title: "语音合成 · 内置音色",
                status: ttsReady ? .ready : .notReady,
                reason: ttsState
            ),
            voiceClone,
            ServiceCapability(
                title: "实时语音断句",
                status: health.realtimeVAD?.ready == true ? .ready : .notReady,
                reason: health.realtimeVAD?.message
                    ?? health.streamingState.map(SpeechRailRuntimeStatePresentation.text)
                    ?? "未读取实时语音状态。"
            ),
            ServiceCapability(
                title: diarization.title,
                status: diarization.status,
                reason: diarization.reason
            ),
        ]
    }

    /// 说话人那一行同样先看服务声明（`/health.diarization`），档位名只负责把 Light 的
    /// 未配置解释成档位取舍。服务说“没有配置”时，报“未配置”比报“worker 尚未
    /// 就绪”准确：后者把缺失的能力说成正在等待。
    private func diarizationCapability(for health: HealthSnapshot) -> ServiceCapability {
        let title = "说话人区分"
        if health.diarizationReady == true {
            return ServiceCapability(
                title: title,
                status: .ready,
                reason: health.diarization.map { SpeechRailDiarizationPresentation.text($0) }
                    ?? "只输出本次会话的匿名标签；不管理实名或声纹库。"
            )
        }
        if health.diarization?.configured == false {
            return ServiceCapability(
                title: title,
                status: health.profile == .light ? .unsupported : .notReady,
                reason: health.profile == .light
                    ? "这一档不标说话人。"
                    : "当前部署没有开启说话人区分。"
            )
        }
        if health.profile == .light {
            return ServiceCapability(
                title: title,
                status: .unsupported,
                reason: "这一档不标说话人。"
            )
        }
        return ServiceCapability(
            title: title,
            status: .notReady,
            reason: health.diarization.map { SpeechRailDiarizationPresentation.text($0) }
                ?? "说话人区分还没准备好。"
        )
    }

    /// 能力行的统一口径：服务声明了就是可用；没声明时再区分「当前档位不加载」与
    /// 「档位该有、服务没有发布」。还没读到能力清单时不下结论，也不把「用户还没有
    /// 这类音色」当成「服务没有这项能力」。
    private func capabilityVerdict(
        title: String,
        capability: String,
        declared: Bool?,
        supportedByProfile: Bool,
        missingReason: String,
        unsupportedReason: String
    ) -> ServiceCapability {
        if declared == true {
            return ServiceCapability(
                title: title,
                status: .ready,
                reason: "服务声明「\(capability)」已经可用。"
            )
        }
        if declared == false {
            return ServiceCapability(
                title: title,
                status: supportedByProfile ? .notReady : .unsupported,
                reason: supportedByProfile ? missingReason : unsupportedReason
            )
        }
        return ServiceCapability(
            title: title,
            status: .notReady,
            reason: model.serviceCapabilitiesLoadState == .failed
                ? "能力清单读取失败，无法确认这一项。"
                : "尚未读取服务能力清单，无法确认这一项。"
        )
    }

    /// Figma `cap`：名称（Body / Medium）｜状态胶囊（固定 96pt 列）｜一句原因。
    /// 状态用胶囊承载，颜色、图标与文字三者都在，不靠颜色单独表达（§9）。
    private func capabilityRow(_ capability: ServiceCapability) -> some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Text(capability.title)
                .font(SpeechRailDesignTokens.Typography.bodyMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    width: SpeechRailDesignTokens.Layout.serviceCapabilityNameWidth,
                    alignment: .leading
                )

            StatusPill(tone: capability.status.tone, label: capability.status.label)
                .frame(
                    width: SpeechRailDesignTokens.Layout.serviceCapabilityPillWidth,
                    alignment: .leading
                )

            Text(capability.reason)
                .font(SpeechRailDesignTokens.Typography.callout)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
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
            return "服务正在跑 \(SpeechRailProfilePresentation.shortTitle(runtime)) 这一档，"
                + "但配置里存的是 \(SpeechRailProfilePresentation.shortTitle(configured))。"
                + "去「模型」页重新应用一次就会一致。"
        }
        if let healthMessage = model.healthMessage {
            let lastRead = model.lastHealthRefresh.map { "最近成功读取于 \(relativeTime($0))" } ?? "尚无成功读取"
            return "\(healthMessage)。\(lastRead)。"
        }
        if model.controlPlaneMessage != nil {
            return "SpeechRail 健康状态已单独读取，但控制通道不可用。只读健康信息仍可查看，请打开诊断。"
        }
        if displayedHealth?.ready == true {
            // Figma `conclusion`：结论面板先说「本机在跑、离线也能用」，当前档位属于
            // 运行事实，已经在下面的「运行信息」卡里；在这句里重复一遍只会把唯一主动作推远。
            let port = model.service.port.map(String.init) ?? "未知"
            let ready = "本地语音服务正在 \(port) 端口运行；离线也有完整的识别与合成能力。"
            if !model.controlAgentStatus.allowsMutation {
                return ready + "但控制 Agent 受限，服务操作和档位变更暂不可用；只读诊断仍可使用。"
            }
            return ready
        }
        if model.service.serviceState == "unavailable" {
            return "本机服务尚未响应健康检查；如果刚执行过启动或重启，请等待操作完成后重新读取。"
        }
        if !model.controlAgentStatus.allowsMutation {
            return "\(model.controlAgentStatus.detail) 只读诊断仍可使用。"
        }
        return "先启动服务；还是不起作用就跑一次「诊断」里的预检，它会说清卡在哪里。"
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
