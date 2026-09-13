import SwiftUI
import SpeechRailControlKit

public struct ProfilePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProfile: SpeechRailProfile = .balanced
    @State private var isConfirmingProfileApply = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.md) {
            Text("模型档位")
                .font(SpeechRailDesignTokens.Typography.sectionTitle)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                Picker("档位", selection: $selectedProfile) {
                    ForEach(SpeechRailProfile.allCases, id: \.self) { profile in
                        Text(SpeechRailProfilePresentation.title(profile))
                            .tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                Button("应用档位") {
                    isConfirmingProfileApply = true
                }
                .speechRailButton(.primary)
                .disabled(
                    model.isBusy
                        || model.hasActiveMutation
                        || !model.controlAgentStatus.allowsMutation
                )
                .confirmationDialog(
                    "确认应用\(SpeechRailProfilePresentation.title(selectedProfile))？这会停止当前服务、切换档位并重新执行健康检查。",
                    isPresented: $isConfirmingProfileApply,
                    titleVisibility: .visible
                ) {
                    Button("应用档位", role: .destructive) {
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
                if let active = model.profile?.preset {
                    selectedProfile = active
                }
            }
            .onChange(of: model.operation?.state) { _, state in
                if state == .failed || state == .cancelled {
                    selectedProfile = model.profile?.preset ?? .balanced
                }
            }
        }
        .padding(SpeechRailDesignTokens.Spacing.lg)
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
