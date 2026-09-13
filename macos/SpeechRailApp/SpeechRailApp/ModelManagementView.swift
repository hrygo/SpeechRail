import SpeechRailControlKit
import SwiftUI

public struct ModelManagementView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppNavigationState.self) private var navigation
    @State private var selectedProfile: SpeechRailProfile = .balanced
    @State private var selectedArtifactKey: String?
    @State private var pendingAction: ModelAction?
    @State private var showInspector = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                PageIntroView(route: .models)
                mainContent
            }
            .frame(maxWidth: SpeechRailDesignTokens.Layout.contentMaximumWidth, alignment: .leading)
            .padding(.horizontal, SpeechRailDesignTokens.Spacing.xl)
            .padding(.vertical, SpeechRailDesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.automatic, for: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkspaceActionsMenu(helpText: "读取模型目录与校验状态，或查看选中制品的技术详情") {
                    Button {
                        Task { await model.refreshModelsAndHealth() }
                    } label: {
                        Label("刷新模型状态", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshingModels)
                    Divider()
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label(
                            showInspector ? "隐藏开发者详情" : "显示开发者详情",
                            systemImage: "info.circle"
                        )
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .inspector(isPresented: $showInspector) {
            modelInspector
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: isConfirmingAction,
            titleVisibility: .visible
        ) {
            if let pendingAction {
                Button(
                    actionTitle(for: pendingAction),
                    role: pendingAction == .apply ? .destructive : nil
                ) {
                    let action = pendingAction
                    self.pendingAction = nil
                    Task {
                        switch action {
                        case .download:
                            await model.prepareModels(for: selectedProfile)
                        case .apply:
                            await model.execute(.profileApply, profile: selectedProfile)
                        }
                    }
                }
            }
            Button("取消", role: .cancel) {
                pendingAction = nil
            }
        }
        .task {
            model.refreshControlAgentStatus()
            await model.refreshModelsAndHealth()
            if let active = model.operation?.profile ?? model.profile?.preset {
                selectedProfile = active
            }
            selectFirstArtifactIfNeeded()
        }
        .onChange(of: model.profile?.preset) { _, value in
            if let value { selectedProfile = value }
        }
        .onChange(of: model.operation?.profile) { _, value in
            if let value { selectedProfile = value }
        }
        .onChange(of: selectedProfile) { _, _ in
            selectFirstArtifactIfNeeded()
        }
        .onChange(of: model.modelCatalog) { _, _ in
            selectFirstArtifactIfNeeded()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch model.modelAvailability {
        case .unknown:
            ProgressView("正在读取模型目录…")
                .frame(maxWidth: .infinity, minHeight: SpeechRailDesignTokens.Layout.emptyStateMinimumHeight)
                .speechRailField()
        case .available:
            modelWorkspace
        case .unsupported:
            unavailableBanner(
                title: "模型管理暂不可用",
                message: model.message.map { SpeechRailOperationMessagePresentation.text($0) }
                    ?? "模型管理暂不可用：服务组件版本不匹配",
                tone: .critical,
                actionTitle: "打开诊断"
            ) {
                navigation.request(.diagnostics)
            }
        case .notReady:
            unavailableBanner(
                title: "模型状态尚未就绪",
                message: model.message.map { SpeechRailOperationMessagePresentation.text($0) }
                    ?? "请先确认本机服务和控制 Agent 已就绪。",
                tone: .attention,
                actionTitle: "打开诊断"
            ) {
                navigation.request(.diagnostics)
            }
        case .failed:
            unavailableBanner(
                title: "模型状态读取失败",
                message: model.message.map { SpeechRailOperationMessagePresentation.text($0) }
                    ?? "重新读取模型目录，或打开诊断查看阻塞原因。",
                tone: .critical,
                actionTitle: "重新读取"
            ) {
                Task { await model.refreshModels() }
            }
        }
    }

    private func unavailableBanner(
        title: String,
        message: String,
        tone: StatusTone,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        StatusBanner(
            tone: tone,
            title: title,
            message: message,
            actionTitle: actionTitle,
            action: action
        )
    }

    private var modelWorkspace: some View {
        HStack(alignment: .top, spacing: SpeechRailDesignTokens.Spacing.lg) {
            profileList
                .frame(width: SpeechRailDesignTokens.Layout.sidebarIdealWidth)
            selectedProfilePanel
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            SectionHeading(
                title: "运行档位",
                detail: "先选择目标，再分别准备模型或应用服务配置。"
            )
            VStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                ForEach(SpeechRailProfile.allCases, id: \.self) { profile in
                    ProfileChoiceRow(
                        profile: profile,
                        summary: summary(for: profile),
                        isSelected: selectedProfile == profile
                    ) {
                        selectedProfile = profile
                    }
                }
            }
            Divider()
            Text("当前服务档位")
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Text(model.profile?.preset.map { profileTitle(for: $0) } ?? "未读取")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
    }

    private var selectedProfilePanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(profileTitle(for: selectedProfile))
                    .font(SpeechRailDesignTokens.Typography.windowTitle)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(profilePurpose(for: selectedProfile))
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }

            profileFacts
            Divider()
            artifactSection
            if !unmanagedArtifactStatuses.isEmpty {
                Divider()
                unmanagedArtifactSection
            }
            if !independentDiarizationKeys.isEmpty {
                Divider()
                diarizationSection
            }
            if let operation = activeModelOperation {
                let canRetry = operation.state == .interrupted
                    || operation.state == .failed
                    || operation.state == .cancelled
                Divider()
                OperationBar(
                    operation: operation,
                    actionTitle: operationActionTitle(for: operation)
                ) {
                    handleOperationAction(operation, canRetry: canRetry)
                }
            }
            Divider()
            actionSection
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailField()
    }

    private var profileFacts: some View {
        HStack(spacing: 0) {
            fact("准备大小", value: summary(for: selectedProfile).map { formatBytes($0.downloadBytes) } ?? "未读取")
            Divider()
                .frame(height: SpeechRailDesignTokens.Layout.compactDividerHeight)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            fact("识别", value: summary(for: selectedProfile)?.asr ?? "未读取")
            Divider()
                .frame(height: SpeechRailDesignTokens.Layout.compactDividerHeight)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            fact("合成", value: summary(for: selectedProfile)?.tts ?? "未读取")
            Divider()
                .frame(height: SpeechRailDesignTokens.Layout.compactDividerHeight)
                .padding(.horizontal, SpeechRailDesignTokens.Spacing.md)
            fact("VoiceDesign", value: voiceDesignCapability(for: selectedProfile))
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
        }
    }

    private func fact(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            Text(value)
                .font(SpeechRailDesignTokens.Typography.technical)
                .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                .lineLimit(1)
        }
        .frame(minWidth: SpeechRailDesignTokens.Layout.modelFactMinimumWidth, alignment: .leading)
    }

    private var artifactSection: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "模型制品",
                detail: "存在状态看文件与 SHA-256；使用状态看当前服务档位和 worker 生命周期。已释放表示可按需加载，不等于缺失。"
            )
            if model.modelCatalog != nil {
                let artifacts = visibleArtifacts
                if artifacts.isEmpty {
                    ContentUnavailableView(
                    "当前档位没有已登记制品",
                        systemImage: AppRoute.models.systemImage,
                        description: Text("请运行预检或检查受管 runtime 的模型目录。")
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SpeechRailDesignTokens.Layout.modelArtifactEmptyStateMinimumHeight
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(artifacts.enumerated()), id: \.element.key) { index, artifact in
                            Button {
                                selectedArtifactKey = artifact.key
                            } label: {
                                ArtifactChoiceRow(
                                    artifact: artifact,
                                    status: status(for: artifact),
                                    usage: usage(for: artifact),
                                    selected: selectedArtifactKey == artifact.key
                                )
                            }
                            .speechRailInteractiveButtonStyle()
                            .accessibilityIdentifier("artifact-\(artifact.key)")
                            if index < artifacts.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "模型目录暂时不可用",
                    systemImage: AppRoute.models.systemImage,
                    description: Text("管理控制台会通过本机控制 Agent 读取锁定目录。")
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: SpeechRailDesignTokens.Layout.modelEmptyStateMinimumHeight
                )
            }
        }
    }

    private var diarizationSection: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "分人资产",
                detail: "当前档位需要的独立 FluidAudio CoreML 资产；对应 aligner 已列在模型制品中。"
            )
            VStack(spacing: 0) {
                ForEach(independentDiarizationKeys, id: \.self) { key in
                    DiarizationStatusRow(
                        key: key,
                        status: status(forKey: key),
                        usage: usage(forKey: key)
                    )
                }
            }
        }
    }

    private var unmanagedArtifactSection: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "已检测但未纳入当前目录",
                detail: "这些本机制品仍存在，但当前锁定 catalog 未登记；不会被受管档位选择或运行时映射。"
            )
            VStack(spacing: 0) {
                ForEach(unmanagedArtifactStatuses, id: \.key) { status in
                    UnmanagedArtifactRow(status: status)
                }
            }
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            SectionHeading(
                title: "下一步",
                detail: "下载只准备本机资产；应用档位才会改变服务配置。两项动作都会先确认影响。"
            )
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Button {
                    pendingAction = .download
                } label: {
                    Label("下载并校验", systemImage: "arrow.down.circle")
                }
                .speechRailButton(.primary)
                .disabled(!canPrepareModels)
                .accessibilityHint("准备并校验所选档位的本机模型文件")

                Button {
                    pendingAction = .apply
                } label: {
                    Label("应用此档位", systemImage: "checkmark.circle")
                }
                .speechRailButton(.secondary)
                .disabled(!canApplyProfile)
                .accessibilityHint("将所选档位写入服务配置并重启相关 worker")
            }
            if let disk = model.modelStatus?.disk {
                Text("本机模型占用 \(formatBytes(disk.modelBytes)) · 可用空间 \(formatBytes(disk.freeBytes))")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            if !missingDiarizationKeys.isEmpty {
                Text("此档位还需要 \(missingDiarizationKeys.map(assetTitle(for:)).joined(separator: "、"))通过校验。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            } else if !visibleArtifacts.isEmpty && !profileArtifactsVerified {
                Text("应用档位前，请先完成当前档位制品的下载与校验。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.attention)
            }
            if let message = model.message, !message.isEmpty, model.modelAvailability == .available {
                Text(SpeechRailOperationMessagePresentation.text(message))
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var modelInspector: some View {
        DeveloperInspector {
            if let artifact = selectedArtifact {
                SectionHeading(title: artifact.variant.replacingOccurrences(of: "_", with: " "))
                LabeledContent("模型 ID", value: artifact.modelID)
                LabeledContent("family", value: artifact.family)
                LabeledContent("来源", value: "\(artifact.provider) · \(artifact.repository)")
                LabeledContent("revision", value: artifact.revision)
                LabeledContent("量化", value: quantizationText(for: artifact))
                LabeledContent("文件", value: "\(artifact.fileCount) 个 · \(formatBytes(artifact.sizeBytes))")
                if let status = status(for: artifact) {
                    Divider()
                    LabeledContent("存在状态", value: statusText(for: status))
                    LabeledContent("完整性", value: integrityText(for: status))
                }
                LabeledContent("VoiceDesign 能力", value: voiceDesignCapability(for: selectedProfile))
                LabeledContent("使用状态", value: usage(for: artifact).text)
                if let operation = model.operation, let message = operation.message {
                    Divider()
                    LabeledContent("最近操作", value: operation.command.rawValue)
                    LabeledContent("操作状态", value: operation.state.rawValue)
                    LabeledContent("原始消息", value: message)
                }
            } else {
                SectionHeading(
                    title: "模型运行信息",
                    detail: "选择制品查看锁定来源、revision 和本机校验结果。"
                )
                LabeledContent("当前档位", value: profileTitle(for: selectedProfile))
                LabeledContent(
                    "服务档位",
                    value: model.profile?.preset.map { profileTitle(for: $0) } ?? "未读取"
                )
                LabeledContent("目录状态", value: model.modelAvailability == .available ? "已读取" : "未读取")
                if let disk = model.modelStatus?.disk {
                    LabeledContent("模型占用", value: formatBytes(disk.modelBytes))
                    LabeledContent("可用空间", value: formatBytes(disk.freeBytes))
                }
                Text("开发者详情不会改变下载或应用行为。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
        }
    }

    private var selectedArtifact: ModelArtifactSnapshot? {
        guard let key = selectedArtifactKey else { return nil }
        return visibleArtifacts.first(where: { $0.key == key })
    }

    private var visibleArtifacts: [ModelArtifactSnapshot] {
        model.modelCatalog?.artifacts.filter {
            $0.requiredBy.contains(selectedProfile)
        } ?? []
    }

    private var unmanagedArtifactStatuses: [ModelArtifactStatusSnapshot] {
        let catalogKeys = Set(model.modelCatalog?.artifacts.map(\.key) ?? [])
        return (model.modelStatus?.artifacts ?? [])
            .filter { !catalogKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
    }

    private var activeModelOperation: OperationSnapshot? {
        guard let operation = model.operation,
              operation.command == .modelPrepare || operation.command == .profileApply
        else { return nil }
        switch operation.state {
        case .accepted, .running, .interrupted, .failed, .cancelled:
            return operation
        case .committed:
            return nil
        }
    }

    private var independentDiarizationKeys: [String] {
        let visibleKeys = Set(visibleArtifacts.map(\.key))
        return requiredDiarizationKeys
            .filter { !visibleKeys.contains($0) }
    }

    private var requiredDiarizationKeys: [String] {
        guard let summary = summary(for: selectedProfile), summary.diarization else {
            return []
        }
        return ["diarization-coreml", summary.aligner].compactMap { $0 }
    }

    private var canPrepareModels: Bool {
        model.modelAvailability == .available
            && !model.isBusy
            && !model.hasActiveMutation
            && !model.isRefreshingModels
            && summary(for: selectedProfile) != nil
            && !visibleArtifacts.isEmpty
            && model.controlAgentStatus.allowsMutation
    }

    private var canApplyProfile: Bool {
        canPrepareModels && profileArtifactsVerified
    }

    private var profileArtifactsVerified: Bool {
        summary(for: selectedProfile) != nil
            && !visibleArtifacts.isEmpty
            && visibleArtifacts.allSatisfy { isVerified(status(for: $0)) }
            && profileDiarizationVerified
    }

    private var profileDiarizationVerified: Bool {
        missingDiarizationKeys.isEmpty
    }

    private var missingDiarizationKeys: [String] {
        requiredDiarizationKeys.filter { !isVerified(status(forKey: $0)) }
    }

    private func assetTitle(for key: String) -> String {
        key == "diarization-coreml" ? "FluidAudio CoreML 分人资产" : key
    }

    private func summary(for profile: SpeechRailProfile) -> ProfileSummary? {
        model.modelCatalog?.profiles.first(where: { $0.id == profile })
    }

    private func voiceDesignCapability(for profile: SpeechRailProfile) -> String {
        guard let profileSummary = summary(for: profile),
              let artifact = model.modelCatalog?.artifacts.first(where: {
                  $0.key == profileSummary.tts
              })
        else {
            return "未读取"
        }
        return artifact.variant == "voice_design" ? "支持候选预览" : "不支持候选预览"
    }

    private func status(for artifact: ModelArtifactSnapshot) -> ModelArtifactStatusSnapshot? {
        status(forKey: artifact.key)
    }

    private func status(forKey key: String) -> ModelArtifactStatusSnapshot? {
        model.modelStatus?.status(for: key)
    }

    private func usage(for artifact: ModelArtifactSnapshot) -> ModelArtifactUsagePresentation {
        usage(forKey: artifact.key)
    }

    private func usage(forKey key: String) -> ModelArtifactUsagePresentation {
        guard let activeProfile = model.profile?.preset else {
            return ModelArtifactUsagePresentation(
                text: "当前服务档位未读取",
                tone: .neutral
            )
        }
        guard let activeSummary = summary(for: activeProfile) else {
            return ModelArtifactUsagePresentation(
                text: "当前档位模型映射未读取",
                tone: .neutral
            )
        }
        guard let health = model.health else {
            return ModelArtifactUsagePresentation(
                text: "运行状态未读取",
                tone: .neutral
            )
        }
        guard let healthProfile = health.profile else {
            return ModelArtifactUsagePresentation(
                text: "运行档位未读取",
                tone: .neutral
            )
        }
        guard healthProfile == activeProfile else {
            return ModelArtifactUsagePresentation(
                text: "配置档位与运行时不一致",
                tone: .critical
            )
        }
        guard let artifactStatus = status(forKey: key) else {
            return ModelArtifactUsagePresentation(
                text: "配置引用 · 存在状态未读取",
                tone: .critical
            )
        }
        guard isVerified(artifactStatus) else {
            return ModelArtifactUsagePresentation(
                text: "配置引用 · 制品未验证",
                tone: .attention
            )
        }

        if key == activeSummary.asr {
            return runtimeUsage(
                label: "当前服务 · " + profileTitle(for: activeProfile) + " · ASR",
                ready: health.asrReady,
                state: health.asrState
            )
        }
        if key == activeSummary.tts {
            return runtimeUsage(
                label: "当前服务 · " + profileTitle(for: activeProfile) + " · TTS",
                ready: health.ttsReady,
                state: health.ttsState
            )
        }
        if key == activeSummary.ttsClone {
            return runtimeUsage(
                label: "当前服务 · " + profileTitle(for: activeProfile) + " · 克隆 TTS 备用",
                ready: health.ttsReady,
                state: health.ttsState
            )
        }
        if activeSummary.diarization,
           key == activeSummary.aligner || key == "diarization-coreml" {
            let ready = health.diarization?.ready ?? health.diarizationReady
            guard let ready else {
                return ModelArtifactUsagePresentation(
                    text: "当前分人链路 · 状态未读取",
                    tone: .neutral
                )
            }
            return ModelArtifactUsagePresentation(
                text: ready ? "当前分人链路 · 已就绪" : "当前分人链路 · 未就绪",
                tone: ready ? .healthy : .critical
            )
        }
        return ModelArtifactUsagePresentation(
            text: "目标档位未应用；当前服务未使用",
            tone: .neutral
        )
    }

    private func runtimeUsage(
        label: String,
        ready: Bool?,
        state: String?
    ) -> ModelArtifactUsagePresentation {
        guard ready != false else {
            return ModelArtifactUsagePresentation(
                text: "\(label) · 服务未就绪",
                tone: .critical
            )
        }
        guard let state else {
            return ModelArtifactUsagePresentation(
                text: "\(label) · 生命周期未读取",
                tone: .neutral
            )
        }
        let normalized = state.lowercased()
        let text: String
        let tone: StatusTone
        switch normalized {
        case "active":
            text = "\(label) · 运行中"
            tone = .healthy
        case "warm_standby":
            text = "\(label) · 温待机"
            tone = .healthy
        case "cold_evicted":
            text = "\(label) · 空闲已释放（请求时加载）"
            tone = .attention
        case "inactive", "stopped":
            text = "\(label) · 未运行"
            tone = .attention
        default:
            text = "\(label) · \(SpeechRailRuntimeStatePresentation.text(state))"
            tone = .neutral
        }
        return ModelArtifactUsagePresentation(text: text, tone: tone)
    }

    private func isVerified(_ status: ModelArtifactStatusSnapshot?) -> Bool {
        status?.state == .verified && status?.integrity == .verified
    }

    private func operationActionTitle(for operation: OperationSnapshot) -> String? {
        switch operation.command {
        case .modelPrepare:
            if operation.phase?.lowercased() == "cancelling" {
                return nil
            }
            return operation.state == .accepted || operation.state == .running
                ? "停止下载"
                : "重新下载并校验"
        case .profileApply:
            return operation.state == .accepted || operation.state == .running
                ? nil
                : "重新应用档位"
        default:
            return nil
        }
    }

    private func handleOperationAction(_ operation: OperationSnapshot, canRetry: Bool) {
        if canRetry {
            pendingAction = operation.command == .profileApply ? .apply : .download
        } else if operation.command == .modelPrepare {
            Task { await model.cancelCurrentOperation() }
        }
    }

    private func selectFirstArtifactIfNeeded() {
        guard let selectedArtifactKey,
              visibleArtifacts.contains(where: { $0.key == selectedArtifactKey })
        else {
            selectedArtifactKey = visibleArtifacts.first?.key
            return
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
        case .download:
            downloadConfirmationTitle
        case .apply:
            "确认应用 \(profileTitle(for: selectedProfile))？这会停止当前服务、切换档位、重新启动并执行健康检查。"
        }
    }

    private var downloadConfirmationTitle: String {
        let profile = profileTitle(for: selectedProfile)
        let size = summary(for: selectedProfile).map { formatBytes($0.downloadBytes) }
        let free = model.modelStatus.map { formatBytes($0.disk.freeBytes) }
        let boundary = "只下载并校验，不会重启服务、切换档位、删除模型，也不会上传音频或作品。"
        switch (size, free) {
        case let (.some(size), .some(free)):
            return "确认下载并校验 \(profile) 模型？预计占用 \(size)，当前可用空间 \(free)。\(boundary)"
        case let (.some(size), .none):
            return "确认下载并校验 \(profile) 模型？预计占用 \(size)。\(boundary)"
        default:
            return "确认下载并校验 \(profile) 模型？\(boundary)"
        }
    }

    private func actionTitle(for action: ModelAction) -> String {
        return switch action {
        case .download:
            "下载并校验"
        case .apply:
            "应用此档位"
        }
    }

    private func profileTitle(for profile: SpeechRailProfile) -> String {
        SpeechRailProfilePresentation.title(profile)
    }

    private func profilePurpose(for profile: SpeechRailProfile) -> String {
        return switch profile {
        case .quality:
            "VoiceDesign 与高质量对齐，适合音色创作"
        case .balanced:
            "8-bit 运行与分人能力的平衡选择"
        case .light:
            "更小的 ASR 组合，适合快速启动"
        }
    }

    private func quantizationText(for artifact: ModelArtifactSnapshot) -> String {
        let bits = artifact.quantization.bits.map { "\($0)-bit" } ?? "未声明位宽"
        let group = artifact.quantization.groupSize.map { " · group \($0)" } ?? ""
        return "\(bits) · \(artifact.quantization.format)\(group)"
    }

    private func statusText(for status: ModelArtifactStatusSnapshot) -> String {
        return switch status.state {
        case .verified:
            status.integrity == .verified
                ? "已验证 · \(status.verifiedFileCount)/\(status.totalFileCount) 个文件"
                : "文件存在，但完整性校验未通过"
        case .notDownloaded:
            "未下载"
        case .downloading:
            "下载中"
        case .invalid:
            "校验不匹配，需要重新准备"
        case .unknown:
            "状态未知"
        }
    }

    private func integrityText(for status: ModelArtifactStatusSnapshot) -> String {
        return switch status.integrity {
        case .verified:
            "SHA-256 已匹配"
        case .mismatch:
            "SHA-256 不匹配"
        case .notChecked:
            "尚未校验"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
    }
}

private enum ModelAction {
    case download
    case apply
}

private struct ProfileChoiceRow: View {
    let profile: SpeechRailProfile
    let summary: ProfileSummary?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected
                            ? SpeechRailDesignTokens.Color.rail
                            : SpeechRailDesignTokens.Color.inkSecondary
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                    Text(profileTitle)
                        .font(SpeechRailDesignTokens.Typography.body)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text(profilePurpose)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: SpeechRailDesignTokens.Spacing.xs)
                if let summary {
                    Text(formatBytes(summary.downloadBytes))
                        .font(SpeechRailDesignTokens.Typography.technical)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.sm)
            .background(
                isSelected
                    ? SpeechRailDesignTokens.Surface.selectedFill
                    : Color.clear,
                in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.row, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.row, style: .continuous)
                        .stroke(
                            SpeechRailDesignTokens.Navigation.focusRing,
                            lineWidth: SpeechRailDesignTokens.Stroke.strong
                        )
                }
            }
        }
        .speechRailInteractiveButtonStyle()
        .accessibilityIdentifier(profile.rawValue)
        .accessibilityLabel(profileTitle)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private var profileTitle: String {
        SpeechRailProfilePresentation.title(profile)
    }

    private var profilePurpose: String {
        return switch profile {
        case .quality:
            "VoiceDesign 与高质量对齐，适合音色创作"
        case .balanced:
            "8-bit 运行与分人能力的平衡选择"
        case .light:
            "更小的 ASR 组合，适合快速启动"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
    }
}

private struct ModelArtifactUsagePresentation {
    let text: String
    let tone: StatusTone
}

private struct ArtifactChoiceRow: View {
    let artifact: ModelArtifactSnapshot
    let status: ModelArtifactStatusSnapshot?
    let usage: ModelArtifactUsagePresentation
    let selected: Bool

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: isVerified ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(
                    isVerified
                        ? SpeechRailDesignTokens.Color.ready
                        : SpeechRailDesignTokens.Color.attention
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(artifact.key)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text("存在：\(existenceText)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text("使用：\(usage.text)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(usage.tone.color)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            Text(artifact.variant.replacingOccurrences(of: "_", with: " "))
                .font(SpeechRailDesignTokens.Typography.technical)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.sm)
        .padding(.horizontal, SpeechRailDesignTokens.Spacing.xs)
        .background(
            selected ? SpeechRailDesignTokens.Surface.selectedFill : Color.clear,
            in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.row)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(artifact.key)
        .accessibilityValue("存在：\(existenceText)，使用：\(usage.text)")
        .accessibilityHint("在开发者详情中查看模型来源和校验信息")
    }

    private var isVerified: Bool {
        status?.state == .verified && status?.integrity == .verified
    }

    private var existenceText: String {
        guard let status else { return "未读取状态" }
        return switch status.state {
        case .verified:
            status.integrity == .verified
                ? "已验证 · \(status.verifiedFileCount)/\(status.totalFileCount) 个文件"
                : "文件存在，但完整性校验未通过"
        case .notDownloaded:
            "未下载"
        case .downloading:
            "下载中"
        case .invalid:
            "校验不匹配，需要重新准备"
        case .unknown:
            "状态未知"
        }
    }
}

private struct DiarizationStatusRow: View {
    let key: String
    let status: ModelArtifactStatusSnapshot?
    let usage: ModelArtifactUsagePresentation

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: isVerified ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(
                    isVerified
                        ? SpeechRailDesignTokens.Color.ready
                        : SpeechRailDesignTokens.Color.attention
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(key == "diarization-coreml" ? "FluidAudio CoreML" : "Aligner · \(key)")
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text("存在：\(existenceText)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text("使用：\(usage.text)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(usage.tone.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key)，存在：\(existenceText)，使用：\(usage.text)")
    }

    private var isVerified: Bool {
        status?.state == .verified && status?.integrity == .verified
    }

    private var existenceText: String {
        guard let status else { return "未读取状态" }
        return switch status.state {
        case .verified:
            status.integrity == .verified
                ? "已验证 · \(status.verifiedFileCount)/\(status.totalFileCount) 个文件"
                : "文件存在，但完整性校验未通过"
        case .notDownloaded:
            "未下载"
        case .downloading:
            "下载中"
        case .invalid:
            "校验不匹配，需要重新准备"
        case .unknown:
            "状态未知"
        }
    }
}

private struct UnmanagedArtifactRow: View {
    let status: ModelArtifactStatusSnapshot

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: isVerified ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(
                    isVerified
                        ? SpeechRailDesignTokens.Color.ready
                        : SpeechRailDesignTokens.Color.attention
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(status.key)
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text("存在：\(existenceText)")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                Text("使用：当前 catalog 未登记")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.key)
        .accessibilityValue("存在：\(existenceText)，使用：当前 catalog 未登记")
    }

    private var isVerified: Bool {
        status.state == .verified && status.integrity == .verified
    }

    private var existenceText: String {
        switch status.state {
        case .verified:
            status.integrity == .verified
                ? "已验证 · \(status.verifiedFileCount)/\(status.totalFileCount) 个文件"
                : "文件存在，但完整性校验未通过"
        case .notDownloaded:
            "未下载"
        case .downloading:
            "下载中"
        case .invalid:
            "校验不匹配，需要重新准备"
        case .unknown:
            "状态未知"
        }
    }
}
