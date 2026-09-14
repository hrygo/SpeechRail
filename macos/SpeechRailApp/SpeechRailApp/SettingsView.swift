import Foundation
import SwiftUI

public struct SettingsView: View {
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false

    public init() {}

    public var body: some View {
        Form {
            Section("常规") {
                Toggle("默认展开技术详情", isOn: $showDeveloperDetails)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: SpeechRailDesignTokens.Interaction.minimumHitTarget,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                    .speechRailPointerCursor()
                Text("面向开发者的接口状态、阶段和标识信息仍只在管理控制台中展开。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(SpeechRailDesignTokens.Settings.secondaryTextMaximumLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("关于 SpeechRail") {
                LabeledContent("产品定位", value: "本机 Apple Silicon 语音服务控制面")
                LabeledContent("最低系统", value: "macOS 26.0")
                LabeledContent("版本", value: Bundle.main.shortVersionString)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SpeechRailDesignTokens.Color.canvas)
        .environment(\.defaultMinListRowHeight, SpeechRailDesignTokens.Interaction.minimumHitTarget)
        .padding(SpeechRailDesignTokens.Spacing.lg)
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.settingsWindowMinimumWidth,
            minHeight: SpeechRailDesignTokens.Layout.settingsWindowMinimumHeight
        )
    }
}

private extension Bundle {
    var shortVersionString: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本"
    }
}
