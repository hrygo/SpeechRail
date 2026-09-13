import Foundation
import SpeechRailControlKit
import SwiftUI

public struct ModelManagementView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProfile: SpeechRailProfile = .balanced
    @State private var pendingAction: ModelAction?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                SurfaceHeaderView(route: .models)
                explanationPanel
                GlassEffectContainer(spacing: SpeechRailDesignTokens.Spacing.lg) {
                    diskSummary
                    profilePicker
                    artifactStatusPanel
                    operationPanel
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
                Button(actionTitle(for: pendingAction), role: pendingAction == .apply ? .destructive : nil) {
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

    private var explanationPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
            Label("模型下载是准备动作", systemImage: "arrow.down.circle")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            Text("SpeechRail 只从仓库锁定的目录下载模型，逐文件校验大小和 SHA-256，再原子发布。下载完成不会自动切换当前运行档位。")
                .font(SpeechRailDesignTokens.Typography.body)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            Text("普通用户：选择档位并下载。开发者：展开制品状态，确认 revision、量化和校验进度。")
                .font(SpeechRailDesignTokens.Typography.secondary)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("选择要准备的档位")
                .font(SpeechRailDesignTokens.Typography.panelTitle)
            ForEach(SpeechRailProfile.allCases, id: \.self) { profile in
                ProfileChoiceRow(
                    profile: profile,
                    summary: model.modelCatalog?.profiles.first(where: { $0.id == profile }),
                    isSelected: selectedProfile == profile
                ) {
                    selectedProfile = profile
                }
            }
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Button("下载并校验") { pendingAction = .download }
                    .buttonStyle(.glassProminent)
                Button("应用此档位") { pendingAction = .apply }
                Text("应用会改变正在使用的服务配置")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            }
            .disabled(model.isBusy)
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }

    private var diskSummary: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("本机空间")
                .font(SpeechRailDesignTokens.Typography.panelTitle)
            if let disk = model.modelStatus?.disk {
                HStack(spacing: SpeechRailDesignTokens.Spacing.xl) {
                    diskValue("模型已占用", disk.modelBytes)
                    diskValue("当前可用", disk.freeBytes)
                    Spacer(minLength: 0)
                }
            } else {
                Text("暂时无法读取磁盘状态")
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }

    private func diskValue(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xxs) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            Text(formatBytes(bytes))
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
        }
    }

    private var artifactStatusPanel: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("制品状态")
                .font(SpeechRailDesignTokens.Typography.panelTitle)
            if let catalog = model.modelCatalog {
                ForEach(
                    catalog.artifacts.filter { $0.requiredBy.contains(selectedProfile) },
                    id: \.key
                ) { artifact in
                    ArtifactStatusRow(
                        artifact: artifact,
                        status: model.modelStatus?.artifacts.first(where: { $0.key == artifact.key })
                    )
                }
                if let diarization = model.modelStatus?.diarization, !diarization.isEmpty {
                    Divider()
                    Text("分人资产")
                        .font(SpeechRailDesignTokens.Typography.panelTitle)
                    Text("Quality / Balanced 档位共用 CoreML 资产，并按档位使用对应 aligner。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                    ForEach(diarization, id: \.key) { item in
                        DiarizationStatusRow(status: item)
                    }
                }
            } else {
                ContentUnavailableView(
                    "模型目录暂时不可用",
                    systemImage: "shippingbox",
                    description: Text("管理控制台会通过本机控制 Agent 读取锁定目录。")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .speechRailSurface(.panel)
    }

    private var operationPanel: some View {
        Group {
            if let operation = model.operation,
               operation.command == .modelPrepare,
               operation.state == .accepted || operation.state == .running || operation.state == .interrupted
            {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    Label(
                        operation.state == .interrupted ? "上次准备被中断" : "正在准备模型",
                        systemImage: operation.state == .interrupted
                            ? "exclamationmark.triangle"
                            : "arrow.down.circle"
                    )
                        .font(SpeechRailDesignTokens.Typography.panelTitle)
                    if operation.state == .interrupted {
                        Text("控制 Agent 曾在准备过程中重启，当前文件状态需要重新校验。请重新下载并校验，不会伪造续传。")
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                    }
                    Text(operation.phase ?? "等待开始")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                    if let progress = operation.progress {
                        Text(progress.file ?? progress.artifactKey ?? "校验中")
                            .font(SpeechRailDesignTokens.Typography.technical)
                            .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                        if let completedBytes = progress.completedBytes,
                           let expectedBytes = progress.expectedBytes,
                           expectedBytes > 0
                        {
                            ProgressView(
                                value: Double(completedBytes),
                                total: Double(expectedBytes)
                            )
                            .controlSize(.small)
                            Text("\(formatBytes(completedBytes)) / \(formatBytes(expectedBytes))")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                        }
                    }
                    if operation.state == .interrupted {
                        Button("重新下载并校验") {
                            pendingAction = .download
                        }
                    } else {
                        Button("停止下载") {
                            Task { await model.cancelCurrentOperation() }
                        }
                    }
                }
                .padding(SpeechRailDesignTokens.Spacing.lg)
                .speechRailSurface(.panel)
            }
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
        switch pendingAction {
        case .download:
            "确认下载并校验 \(selectedProfile.rawValue) 档位模型？"
        case .apply:
            "确认应用 \(selectedProfile.rawValue) 档位？"
        case nil:
            "确认操作"
        }
    }

    private func actionTitle(for action: ModelAction) -> String {
        switch action {
        case .download: "下载并校验"
        case .apply: "应用此档位"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
    }
}

private struct DiarizationStatusRow: View {
    let status: ModelArtifactStatusSnapshot

    var body: some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
            Image(systemName: status.state == .verified ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(
                    status.state == .verified
                        ? SpeechRailDesignTokens.Palette.success
                        : SpeechRailDesignTokens.Palette.warning
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xxs) {
                Text(status.key == "diarization-coreml" ? "FluidAudio CoreML" : "Aligner · \(status.key)")
                    .font(SpeechRailDesignTokens.Typography.panelTitle)
                Text(statusText)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.key)，\(statusText)")
    }

    private var statusText: String {
        switch status.state {
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
            HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isSelected
                            ? SpeechRailDesignTokens.Palette.tint
                            : SpeechRailDesignTokens.Palette.secondaryText
                    )
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xxs) {
                    Text(profileTitle)
                        .font(SpeechRailDesignTokens.Typography.panelTitle)
                    Text(profilePurpose)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                }
                Spacer()
                if let summary {
                    Text(formatBytes(summary.downloadBytes))
                        .font(SpeechRailDesignTokens.Typography.technical)
                        .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                }
            }
            .padding(SpeechRailDesignTokens.Spacing.md)
            .background(
                isSelected
                    ? SpeechRailDesignTokens.Palette.tint.opacity(0.12)
                    : SpeechRailDesignTokens.Palette.canvas.opacity(0.01),
                in: .rect(cornerRadius: SpeechRailDesignTokens.Corner.control)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(profile.rawValue)
    }

    private var profileTitle: String {
        switch profile {
        case .quality: "Quality · 创作优先"
        case .balanced: "Balanced · 分人和日常"
        case .light: "Light · 轻量快速"
        }
    }

    private var profilePurpose: String {
        switch profile {
        case .quality: "VoiceDesign 与高质量对齐，适合音色创作"
        case .balanced: "8-bit 运行与分人能力的平衡选择"
        case .light: "更小的 ASR 组合，适合快速启动"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
    }
}

private struct ArtifactStatusRow: View {
    let artifact: ModelArtifactSnapshot
    let status: ModelArtifactStatusSnapshot?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                LabeledContent("模型 ID", value: artifact.modelID)
                LabeledContent("来源", value: "\(artifact.provider) · \(artifact.repository)")
                LabeledContent("revision", value: artifact.revision)
                LabeledContent("文件", value: "\(artifact.fileCount) 个 · \(formatBytes(artifact.sizeBytes))")
            }
            .font(SpeechRailDesignTokens.Typography.technical)
            .padding(.top, SpeechRailDesignTokens.Spacing.xs)
        } label: {
            HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                Image(systemName: status?.state == .verified ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(
                        status?.state == .verified
                            ? SpeechRailDesignTokens.Palette.success
                            : SpeechRailDesignTokens.Palette.warning
                    )
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xxs) {
                    Text(artifact.variant.replacingOccurrences(of: "_", with: " "))
                        .font(SpeechRailDesignTokens.Typography.panelTitle)
                    Text(statusText)
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                }
                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artifact.variant)，\(statusText)")
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

    private func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
    }
}
