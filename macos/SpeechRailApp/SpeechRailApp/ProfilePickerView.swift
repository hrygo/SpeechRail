import SwiftUI
import SpeechRailControlKit

public struct ProfilePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProfile: SpeechRailProfile = .balanced
    @State private var isConfirmingProfileApply = false

    public init() {}

    private var availableProfiles: [SpeechRailProfile] {
        model.modelCatalog?.selectableProfiles ?? []
    }

    private var profileConfirmationMessage: String {
        let summary = model.modelCatalog?.profiles.first(where: { $0.id == selectedProfile })
        let remaining = model.modelCatalog?.remainingDownloadUpperBound(
            for: selectedProfile,
            statuses: model.modelStatus
        )
        var details: [String] = []
        if let summary {
            details.append("该档模型总大小 \(formatBytes(summary.downloadBytes))")
        }
        if let remaining {
            details.append(
                remaining == 0
                    ? "模型已全部下载并校验"
                    : "尚需下载不超过 \(formatBytes(remaining))"
            )
        } else {
            details.append("需下载量待确认")
        }
        if let freeBytes = model.modelStatus?.disk.freeBytes {
            details.append("当前可用磁盘空间 \(formatBytes(freeBytes))")
        }
        details.append("已校验文件不会重下，首次加载可能更久，其他档位模型不会删除")
        if selectedProfile == .extreme {
            details.append("更大的模型权重可能增加内存占用；实际并发能力以切换后服务诊断为准")
        }
        details.append("切换后会重新读取服务状态")
        return "确认应用\(SpeechRailProfilePresentation.title(selectedProfile))？\(details.joined(separator: "；"))。"
    }

    private func syncSelectedProfile() {
        if let active = model.profile?.preset, availableProfiles.contains(active) {
            selectedProfile = active
        } else if !availableProfiles.contains(selectedProfile),
                  let first = availableProfiles.first
        {
            selectedProfile = first
        }
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
                    Picker("档位", selection: $selectedProfile) {
                        ForEach(availableProfiles, id: \.self) { profile in
                            Text(SpeechRailProfilePresentation.shortTitle(profile))
                                .tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .speechRailPointerCursor()
                    Text(SpeechRailProfilePresentation.title(selectedProfile))
                        .font(SpeechRailDesignTokens.Typography.bodyMedium)
                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                    Text(SpeechRailProfilePresentation.purpose(selectedProfile))
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("应用档位") {
                    isConfirmingProfileApply = true
                }
                .speechRailButton(.primary)
                .disabled(
                    model.isBusy
                        || model.hasActiveMutation
                        || !model.controlAgentStatus.allowsMutation
                        || !availableProfiles.contains(selectedProfile)
                )
                .confirmationDialog(
                    profileConfirmationMessage,
                    isPresented: $isConfirmingProfileApply,
                    titleVisibility: .visible
                ) {
                    Button("应用档位", role: .destructive) {
                        guard availableProfiles.contains(selectedProfile) else { return }
                        Task { await model.execute(.profileApply, profile: selectedProfile) }
                    }
                    Button("取消", role: .cancel) {}
                }
                if let active = model.profile?.preset {
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
            .task(id: model.profile?.preset) {
                syncSelectedProfile()
            }
            .onChange(of: model.modelCatalog) { _, _ in
                syncSelectedProfile()
            }
            .onChange(of: model.operation?.state) { _, state in
                if state == .failed || state == .cancelled {
                    syncSelectedProfile()
                }
            }
        }
        .padding(SpeechRailDesignTokens.Layout.cardInset)
        .speechRailContentSurface()
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
