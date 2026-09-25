import SwiftUI
import SpeechRailControlKit

public struct ProfilePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var quickTier: SpeechRailProfile = .quality
    @State private var asrSpec: SpeechRailProfile = .quality
    @State private var ttsSpec: SpeechRailProfile = .quality
    @State private var showsAdvanced = false
    @State private var isConfirmingProfileApply = false

    public init() {}

    private var availableProfiles: [SpeechRailProfile] {
        model.modelCatalog?.selectableProfiles ?? []
    }

    /// 快捷组合只写两项 specs；高级项按各自的选择独立提交。
    private var pendingSelection: SpecSelection {
        showsAdvanced
            ? SpecSelection(asrSpec: asrSpec, ttsSpec: ttsSpec)
            : .quick(quickTier)
    }

    private var selectionSummary: String {
        SpeechRailProfilePresentation.title(pendingSelection)
    }

    /// 为什么现在不能切：会话占用最先说，其次是别的操作在做。
    private var blockedReason: String? {
        if let reason = model.profileSwitchBlockedReason { return reason }
        if model.hasActiveMutation || model.isBusy { return "正在执行其他操作，完成后再切档。" }
        if !model.controlAgentStatus.allowsMutation {
            return "\(model.controlAgentStatus.title)：\(model.controlAgentStatus.detail)"
        }
        return nil
    }

    private var profileConfirmationMessage: String {
        let target = pendingSelection
        var details: [String] = ["识别 \(SpeechRailProfilePresentation.shortTitle(target.asrSpec))、配音 \(SpeechRailProfilePresentation.shortTitle(target.ttsSpec))"]
        if target.asrSpec == target.ttsSpec {
            // 快捷组合：目录里正好有一个整档总量，可以给出明确估算。
            if let summary = model.modelCatalog?.profiles.first(where: { $0.id == target.ttsSpec }) {
                details.append("该档模型总大小 \(formatBytes(summary.downloadBytes))")
            }
            if let remaining = model.modelCatalog?.remainingDownloadUpperBound(
                for: target.ttsSpec,
                statuses: model.modelStatus
            ) {
                details.append(
                    remaining == 0
                        ? "模型已全部下载并校验"
                        : "尚需下载不超过 \(formatBytes(remaining))"
                )
            } else {
                details.append("需下载量待确认")
            }
        } else {
            // 分别调整的混合选择没有单一整档总量；不按其中一档冒充组合大小。
            details.append("组合下载量将在准备时按缺失制品校验")
        }
        if let freeBytes = model.modelStatus?.disk.freeBytes {
            details.append("当前可用磁盘空间 \(formatBytes(freeBytes))")
        }
        details.append("已校验文件不会重下，首次加载可能更久，其他档位模型不会删除")
        if target.asrSpec == .reference || target.ttsSpec == .reference {
            details.append("更大的模型权重可能增加内存占用；实际并发能力以切换后服务诊断为准")
        }
        details.append("切换会重启本地服务，正在进行的识别与朗读会先结束")
        return "确认应用\(selectionSummary)？\(details.joined(separator: "；"))。"
    }

    /// 把已提交（或正在应用）的选择回填到两套控件上。
    private func syncSelection() {
        if let selection = model.operation?.selection ?? model.profile?.selection {
            asrSpec = selection.asrSpec
            ttsSpec = selection.ttsSpec
            if let quick = selection.quickTier {
                quickTier = quick
            } else {
                showsAdvanced = true
                if let fallback = availableProfiles.first {
                    quickTier = fallback
                }
            }
        } else if !availableProfiles.contains(quickTier), let first = availableProfiles.first {
            quickTier = first
        }
        if !availableProfiles.contains(asrSpec), let first = availableProfiles.first { asrSpec = first }
        if !availableProfiles.contains(ttsSpec), let first = availableProfiles.first { ttsSpec = first }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        String(format: "%.1f GiB", Double(bytes) / 1_073_741_824)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("模型档位")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                if availableProfiles.isEmpty {
                    ContentUnavailableView(
                        "没有可选择的档位",
                        systemImage: AppRoute.models.systemImage,
                        description: Text("服务目录尚未返回可管理的档位，请重新读取模型状态。")
                    )
                } else {
                    Picker("档位", selection: $quickTier) {
                        ForEach(availableProfiles, id: \.self) { profile in
                            Text(SpeechRailProfilePresentation.shortTitle(profile))
                                .tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .speechRailPointerCursor()
                    .disabled(showsAdvanced)
                    Text(SpeechRailProfilePresentation.title(quickTier))
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text(SpeechRailProfilePresentation.purpose(quickTier))
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    advancedSpecs
                }
                Button("应用档位") {
                    isConfirmingProfileApply = true
                }
                .speechRailButton(.primary)
                .disabled(
                    blockedReason != nil
                        || !pendingSelection.isSelectable
                        || !availableProfiles.contains(pendingSelection.asrSpec)
                        || !availableProfiles.contains(pendingSelection.ttsSpec)
                )
                .confirmationDialog(
                    profileConfirmationMessage,
                    isPresented: $isConfirmingProfileApply,
                    titleVisibility: .visible
                ) {
                    Button("应用档位", role: .destructive) {
                        let target = pendingSelection
                        guard availableProfiles.contains(target.asrSpec),
                              availableProfiles.contains(target.ttsSpec)
                        else { return }
                        Task { await model.execute(.profileApply, selection: target) }
                    }
                    Button("取消", role: .cancel) {}
                }
                if let reason = blockedReason {
                    Text(reason)
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let active = model.profile?.selection {
                    Text("当前：\(SpeechRailProfilePresentation.title(active))")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
                if let operation = model.operation {
                    Text("操作：\(operationStateText(operation.state))")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    if let phase = operation.phase {
                        Text("阶段：\(phaseText(phase))")
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    if let errorCode = operation.errorCode {
                        Text("错误码：\(errorCode.rawValue)")
                            .font(SpeechRailDesignTokens.Typography.technical)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                    if let message = operation.message {
                        Text(SpeechRailOperationMessagePresentation.text(message))
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: model.profile?.selection) {
                syncSelection()
            }
            .onChange(of: model.modelCatalog) { _, _ in
                syncSelection()
            }
            .onChange(of: model.operation?.state) { _, state in
                if state == .failed || state == .cancelled {
                    syncSelection()
                }
            }
        }
        .padding(SpeechRailDesignTokens.Layout.cardInset)
        .speechRailContentSurface()
    }

    /// 高级项：ASR 与 TTS 各自选档，写进同一对 `asr_spec`/`tts_spec`。
    @ViewBuilder
    private var advancedSpecs: some View {
        DisclosureGroup("分别调整识别与配音", isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                Picker("识别档位", selection: $asrSpec) {
                    ForEach(availableProfiles, id: \.self) { profile in
                        Text(SpeechRailProfilePresentation.shortTitle(profile))
                            .tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .speechRailPointerCursor()
                Picker("配音档位", selection: $ttsSpec) {
                    ForEach(availableProfiles, id: \.self) { profile in
                        Text(SpeechRailProfilePresentation.shortTitle(profile))
                            .tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .speechRailPointerCursor()
                Text(selectionSummary)
                    .font(SpeechRailDesignTokens.Typography.secondary)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, SpeechRailDesignTokens.Spacing.xs)
        }
        .font(SpeechRailDesignTokens.Typography.bodyMedium)
        .speechRailPointerCursor()
    }

    private func operationStateText(_ state: OperationState) -> String {
        switch state {
        case .accepted:
            "已接收"
        case .running:
            "进行中"
        case .interrupted:
            "已中断"
        case .committed:
            "已完成"
        case .failed:
            "失败"
        case .cancelled:
            "已取消"
        }
    }

    private func phaseText(_ phase: String) -> String {
        switch phase.lowercased() {
        case "accepted":
            "已接收"
        case "prepare", "preparing":
            "准备中"
        case "download", "downloading":
            "下载中"
        case "verify", "verifying":
            "校验中"
        case "apply", "applying":
            "应用中"
        case "reload", "reloading":
            "重载中"
        case "smoke", "smoke_test":
            "健康检查中"
        case "committed", "completed":
            "已完成"
        case "failed":
            "失败"
        case "cancelled", "canceled":
            "已取消"
        case "interrupted":
            "已中断"
        default:
            "处理中"
        }
    }
}
