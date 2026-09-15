import Foundation
import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @AppStorage("speechrail.refreshOnLaunch") private var refreshOnLaunch = true
    @AppStorage("speechrail.creator.defaultVoiceID") private var defaultVoiceID = ""
    @AppStorage("speechrail.creator.defaultSpeed") private var defaultSpeed: Double = 1.0

    public init() {}

    public var body: some View {
        Form {
            Section("通用") {
                Toggle("启动时读取服务状态", isOn: $refreshOnLaunch)
                    .help("关闭后，打开管理控制台不会自动发起一次服务状态读取。")
                Text("控制台仍可在任意页面手动刷新。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("创作") {
                Picker("默认音色", selection: $defaultVoiceID) {
                    Text("服务返回的第一个可用音色").tag("")
                    ForEach(defaultVoiceChoices) { voice in
                        Text(voice.name).tag(voice.id)
                    }
                }
                .disabled(defaultVoiceChoices.isEmpty)
                Text(
                    defaultVoiceChoices.isEmpty
                        ? "尚未读到可用音色；配音台会先选中服务返回的第一个可用音色。"
                        : "新打开的配音台优先选中这个音色；参考音色仍固定 1.0x。"
                )
                .font(SpeechRailDesignTokens.Typography.caption)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

                LabeledContent("默认语速") {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Slider(value: $defaultSpeed, in: 0.5...2.0, step: 0.1)
                            .frame(width: 160)
                        Text(String(format: "%.1fx", defaultSpeed))
                            .font(SpeechRailDesignTokens.Typography.technical)
                            .monospacedDigit()
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    }
                }

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

            Section("服务") {
                LabeledContent("服务端口", value: portText)
                Toggle("诊断报告包含运行档位与版本", isOn: $includeServiceContextInReports)
                Text("报告始终不含凭据、原始音频、完整转写或本地绝对路径。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    @AppStorage("speechrail.diagnostics.includeServiceContext") private var includeServiceContextInReports = true

    private var defaultVoiceChoices: [CreatorVoice] {
        model.creatorVoices.filter(\.available)
    }

    private var portText: String {
        guard let port = model.service.port else { return "未读取" }
        return String(port)
    }
}

private extension Bundle {
    var shortVersionString: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本"
    }
}

/// What ⌘? opens: the keyboard map from REDESIGN-SPEC §6.3, so the shortcuts
/// are discoverable without leaving the app.
struct SpeechRailHelpView: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let shortcut: String
        let title: String
        let detail: String
    }

    private let groups: [(title: String, entries: [Entry])] = [
        (
            "文件",
            [
                Entry(shortcut: "⌘N", title: "新建配音文稿", detail: "跳到配音台并开始一段新文稿。"),
                Entry(shortcut: "⌘E", title: "导出选中作品", detail: "导出「我的作品」中选中的那条音频。"),
            ]
        ),
        (
            "页面",
            [
                Entry(shortcut: "⌘1–⌘4", title: "配音台 / 音色创作 / 音色库 / 我的作品", detail: "创作页之间切换。"),
                Entry(shortcut: "⌘5–⌘8", title: "服务状态 / 运行监控 / 模型 / 诊断", detail: "服务页之间切换。"),
                Entry(shortcut: "⌘⌥I", title: "显示或隐藏开发者详情", detail: "切换技术摘要的默认展开状态。"),
            ]
        ),
        (
            "页面动作",
            [
                Entry(shortcut: "⌘⏎", title: "生成语音 / 生成候选音色", detail: "在配音台和音色创作触发主操作。"),
            ]
        ),
    ]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.lg) {
                SectionHeading(
                    title: "SpeechRail 帮助",
                    detail: "本机共享 ASR/TTS 服务的控制台快捷键。"
                )
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.sm) {
                        Text(group.title)
                            .font(SpeechRailDesignTokens.Typography.sectionTitle)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(group.entries) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: SpeechRailDesignTokens.Spacing.sm) {
                                    Text(entry.shortcut)
                                        .font(SpeechRailDesignTokens.Typography.technical)
                                        .foregroundStyle(SpeechRailDesignTokens.Color.ink)
                                        .frame(width: 72, alignment: .leading)
                                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.micro) {
                                        Text(entry.title)
                                            .font(SpeechRailDesignTokens.Typography.body)
                                        Text(entry.detail)
                                            .font(SpeechRailDesignTokens.Typography.caption)
                                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, SpeechRailDesignTokens.Spacing.xs)
                            }
                        }
                    }
                }
                Text("菜单栏图标提供打开控制台、开始配音、运行预检、停止服务和退出。")
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SpeechRailDesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 460)
    }
}
