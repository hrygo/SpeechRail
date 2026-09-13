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
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("开发者详情", systemImage: "info.circle")
                }
                .help("查看模型 ID、revision、量化和校验明细")
            }
            ToolbarItem {
                Button {
                    Task { await model.refreshModels() }
                } label: {
                    Label("刷新模型状态", systemImage: "arrow.clockwise")
                }
                .help("重新读取模型目录和本机校验状态")
            }
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
            await model.refreshModels()
            if let active = model.operation?.profile ?? model.profile?.preset {
                selectedProfile = active
            }
        }
        .onChange(of: model.profile?.preset) { _, value in
            if let value { selectedProfile = value }
        }
        .onChange(of: model.operation?.profile) { _, value in
            if let value { selectedProfile = value }
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
                message: model.message ?? "模型管理暂不可用：服务组件版本不匹配",
                tone: .critical,
                actionTitle: "打开诊断"
            ) {
                navigation.request(.diagnostics)
            }
        case .notReady:
            unavailableBanner(
                title: "模型状态尚未就绪",
                message: model.message ?? "请先确认本机服务和控制 Agent 已就绪。",
                tone: .attention,
                actionTitle: "打开诊断"
            ) {
                navigation.request(.diagnostics)
            }
        case .failed:
            unavailableBanner(
                title: "模型状态读取失败",
                message: model.message ?? "重新读取模型目录，或打开诊断查看阻塞原因。",
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
            Text(model.profile?.preset?.rawValue ?? "未读取")
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
            if !diarizationStatuses.isEmpty {
                Divider()
                diarizationSection
            }
            if let operation = activeModelOperation {
                Divider()
                OperationBar(
                    operation: operation,
                    actionTitle: operation.state == .interrupted ? "重新下载并校验" : "停止下载"
                ) {
                    if operation.state == .interrupted {
                        pendingAction = .download
                    } else {
                        Task { await model.cancelCurrentOperation() }
                    }
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
                detail: "下载动作会逐文件校验大小和 SHA-256；选择制品后可在 Inspector 查看技术细节。"
            )
            if let catalog = model.modelCatalog {
                let artifacts = catalog.artifacts.filter { $0.requiredBy.contains(selectedProfile) }
                if artifacts.isEmpty {
                    ContentUnavailableView(
                        "当前档位没有已登记制品",
                        systemImage: "shippingbox",
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
                                    selected: selectedArtifactKey == artifact.key
                                )
                            }
                            .buttonStyle(.plain)
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
                    systemImage: "shippingbox",
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
                detail: "Balanced / Quality 共用 FluidAudio CoreML 资产，并按档位使用对应 aligner。"
            )
            VStack(spacing: 0) {
                ForEach(diarizationStatuses, id: \.key) { item in
                    DiarizationStatusRow(status: item)
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
                Button("下载并校验") {
                    pendingAction = .download
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPrepareModels)
                .accessibilityHint("准备并校验所选档位的本机模型文件")

                Button("应用此档位") {
                    pendingAction = .apply
                }
                .buttonStyle(.bordered)
                .disabled(!canApplyProfile)
                .accessibilityHint("将所选档位写入服务配置并重启相关 worker")
            }
            if let disk = model.modelStatus?.disk {
                Text("本机模型占用 \(formatBytes(disk.modelBytes)) · 可用空间 \(formatBytes(disk.freeBytes))")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            if let message = model.message, !message.isEmpty, model.modelAvailability == .available {
                Text(message)
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
                    LabeledContent("状态", value: statusText(for: status))
                    LabeledContent("完整性", value: integrityText(for: status))
                }
            } else {
                SectionHeading(
                    title: "模型运行信息",
                    detail: "选择制品查看锁定来源、revision 和本机校验结果。"
                )
                LabeledContent("当前档位", value: selectedProfile.rawValue)
                LabeledContent("服务档位", value: model.profile?.preset?.rawValue ?? "未读取")
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
        return model.modelCatalog?.artifacts.first(where: { $0.key == key })
    }

    private var activeModelOperation: OperationSnapshot? {
        guard let operation = model.operation, operation.command == .modelPrepare else { return nil }
        switch operation.state {
        case .accepted, .running, .interrupted:
            return operation
        case .committed, .failed, .cancelled:
            return nil
        }
    }

    private var diarizationStatuses: [ModelArtifactStatusSnapshot] {
        model.modelStatus?.diarization ?? []
    }

    private var canPrepareModels: Bool {
        model.modelAvailability == .available
            && !model.isBusy
            && model.controlAgentStatus.allowsMutation
    }

    private var canApplyProfile: Bool {
        canPrepareModels
    }

    private func summary(for profile: SpeechRailProfile) -> ProfileSummary? {
        model.modelCatalog?.profiles.first(where: { $0.id == profile })
    }

    private func status(for artifact: ModelArtifactSnapshot) -> ModelArtifactStatusSnapshot? {
        model.modelStatus?.artifacts.first(where: { $0.key == artifact.key })
            ?? model.modelStatus?.diarization.first(where: { $0.key == artifact.key })
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
            "确认下载并校验 \(selectedProfile.rawValue) 档位模型？"
        case .apply:
            "确认应用 \(selectedProfile.rawValue) 档位？将无缝热重载相关 ASR/TTS 服务。"
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
        return switch profile {
        case .quality:
            "Quality · 创作优先"
        case .balanced:
            "Balanced · 分人和日常"
        case .light:
            "Light · 轻量快速"
        }
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
            "已验证 · \(status.verifiedFileCount)/\(status.totalFileCount) 个文件"
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
                        .stroke(SpeechRailDesignTokens.Color.rail.opacity(0.35), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(profile.rawValue)
        .accessibilityLabel(profileTitle)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private var profileTitle: String {
        return switch profile {
        case .quality:
            "Quality · 创作优先"
        case .balanced:
            "Balanced · 分人和日常"
        case .light:
            "Light · 轻量快速"
        }
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

private struct ArtifactChoiceRow: View {
    let artifact: ModelArtifactSnapshot
    let status: ModelArtifactStatusSnapshot?
    let selected: Bool

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: status?.state == .verified ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(
                    status?.state == .verified
                        ? SpeechRailDesignTokens.Color.ready
                        : SpeechRailDesignTokens.Color.attention
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(artifact.variant.replacingOccurrences(of: "_", with: " "))
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(statusText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer(minLength: SpeechRailDesignTokens.Spacing.sm)
            Text(artifact.key)
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
        .accessibilityLabel(artifact.variant)
        .accessibilityValue(statusText)
        .accessibilityHint("在开发者详情中查看模型来源和校验信息")
    }

    private var statusText: String {
        guard let status else { return "未读取状态" }
        return switch status.state {
        case .verified:
            "已验证 · \(status.verifiedFileCount)/\(status.totalFileCount) 个文件"
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
    let status: ModelArtifactStatusSnapshot

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: status.state == .verified ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(
                    status.state == .verified
                        ? SpeechRailDesignTokens.Color.ready
                        : SpeechRailDesignTokens.Color.attention
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                Text(status.key == "diarization-coreml" ? "FluidAudio CoreML" : "Aligner · \(status.key)")
                    .font(SpeechRailDesignTokens.Typography.body)
                    .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                Text(statusText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.key)，\(statusText)")
    }

    private var statusText: String {
        return switch status.state {
        case .verified:
            "已验证 · \(status.verifiedFileCount)/\(status.totalFileCount) 个文件"
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
