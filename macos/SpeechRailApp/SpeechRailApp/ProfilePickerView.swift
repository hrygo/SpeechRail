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
                .font(SpeechRailDesignTokens.Typography.panelTitle)
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                Picker("档位", selection: $selectedProfile) {
                    ForEach(SpeechRailProfile.allCases, id: \.self) { profile in
                        Text(profile.rawValue)
                            .tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                Button("应用档位") {
                    isConfirmingProfileApply = true
                }
                .disabled(model.isBusy)
                .confirmationDialog(
                    "确认切换模型档位？",
                    isPresented: $isConfirmingProfileApply,
                    titleVisibility: .visible
                ) {
                    Button("确认切换", role: .destructive) {
                        Task { await model.execute(.profileApply, profile: selectedProfile) }
                    }
                    Button("取消", role: .cancel) {}
                }
                if let active = model.profile?.preset {
                    Text("当前：\(active.rawValue)")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                }
                if let operation = model.operation {
                    Text("操作：\(operation.state.rawValue)")
                        .font(SpeechRailDesignTokens.Typography.secondary)
                        .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                    if let phase = operation.phase {
                        Text("阶段：\(phase)")
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                    }
                    if let errorCode = operation.errorCode {
                        Text("错误码：\(errorCode.rawValue)")
                            .font(SpeechRailDesignTokens.Typography.technical)
                            .foregroundStyle(SpeechRailDesignTokens.Palette.secondaryText)
                    }
                    if let message = operation.message {
                        Text(message)
                            .font(SpeechRailDesignTokens.Typography.secondary)
                            .foregroundStyle(SpeechRailDesignTokens.Palette.critical)
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
        .speechRailSurface(.panel)
    }
}
