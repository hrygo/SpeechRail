import AppKit
import Foundation
import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionPreferences.self) private var preferences
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @AppStorage("speechrail.refreshOnLaunch") private var refreshOnLaunch = true
    @AppStorage("speechrail.creator.defaultVoiceID") private var defaultVoiceID = ""
    @AppStorage("speechrail.creator.defaultSpeed") private var defaultSpeed: Double = 1.0
    @State private var llmKeyDraft = ""
    /// 钥匙串里有没有那一份密钥。**不在 `@State` 的默认值表达式里读**：那个表达式在
    /// 每一次重建视图时都会跑，而读钥匙串是一次可能被系统弹框拦下的同步调用——
    /// 它与助手页那处是同一个毛病（2026-09-19）。
    @State private var llmKeySaved = false
    @State private var moduleKeyDrafts: [String: String] = [:]
    @State private var moduleKeySaved: Set<String> = []
    @State private var connectionResult: LLMConnectionResult?
    /// 新密钥测试通过但写入安全保管库失败时的独立提示；连接结论本身仍然保留。
    @State private var keySaveError: String?
    @State private var isChecking = false
    @State private var checkedModule: LLMModule?
    @State private var isAdvancedLLMConfigurationExpanded = false
    @State private var didSeedAdvancedLLMConfigurationExpansion = false

    public init() {}

    public var body: some View {
        // Figma `05 Menu & Settings`：设置窗口是「通用 / 创作 / 助手 / 服务」四个目的地，
        // 用系统 TabView（macOS 26 的图标 + 文字页签）而不是再加一条侧边栏。
        TabView {
            Tab("通用", systemImage: "slider.horizontal.3") {
                generalPane
            }
            Tab("创作", systemImage: "sparkles") {
                creativePane
            }
            Tab("助手", systemImage: "waveform.badge.mic") {
                SettingsAssistantPane(
                    llmKeyDraft: $llmKeyDraft,
                    llmKeySaved: $llmKeySaved,
                    moduleKeyDrafts: $moduleKeyDrafts,
                    moduleKeySaved: $moduleKeySaved,
                    connectionResult: $connectionResult,
                    keySaveError: $keySaveError,
                    isChecking: $isChecking,
                    checkedModule: $checkedModule,
                    isAdvancedLLMConfigurationExpanded: $isAdvancedLLMConfigurationExpanded,
                    onCheckConnection: { module, saveRequested in
                        Task {
                            await checkConnection(for: module, saveRequested: saveRequested)
                        }
                    },
                    onClearGlobalKey: clearGlobalKey,
                    onClearModuleKey: clearModuleKey,
                    onOpenDataDirectory: openDataDirectory,
                    onBackupLibrary: backupLibrary
                )
            }
            Tab("服务", systemImage: "server.rack") {
                servicePane
            }
        }
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.settingsWindowMinimumWidth,
            minHeight: SpeechRailDesignTokens.Layout.settingsWindowMinimumHeight
        )
        .task {
            seedAdvancedLLMConfigurationExpansion()
            let savedModules = await Task.detached {
                LLMModule.allCases
                    .filter { LLMKeychain.hasKey(scope: .module($0)) }
                    .map(\.rawValue)
            }.value
            llmKeySaved = await Task.detached { LLMKeychain.hasKey }.value
            moduleKeySaved = Set(savedModules)
        }
    }

    private var generalPane: some View {
        settingsPane {
            settingsSection("启动与窗口") {
                settingsRow {
                    Toggle(isOn: $refreshOnLaunch) {
                        settingsRowLabel(
                            "启动时读取服务状态",
                            caption: "控制台仍可在任意页面手动刷新。"
                        )
                    }
                        .help("关闭后，打开管理控制台不会自动发起一次服务状态读取。")
                        .modifier(settingsRowControl())
                }
            }

            settingsSection("开发者") {
                settingsRow {
                    Toggle(isOn: $showDeveloperDetails) {
                        settingsRowLabel(
                            "默认展开技术详情",
                            caption: "面向开发者的接口状态、阶段和标识信息仍只在管理控制台中展开。"
                        )
                    }
                        .modifier(settingsRowControl())
                }
            }
        }
    }

    private var creativePane: some View {
        settingsPane {
            settingsSection("创作默认值") {
                settingsRow {
                    Picker(selection: $defaultVoiceID) {
                        Text("服务返回的第一个可用音色").tag("")
                        ForEach(defaultVoiceChoices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    } label: {
                        settingsRowLabel(
                            "默认音色",
                            caption: defaultVoiceChoices.isEmpty
                                ? "尚未读到可用音色；配音台会先选中服务返回的第一个可用音色。"
                                : "新打开的配音台优先选中这个音色；参考音色仍固定 1.0x。"
                        )
                    }
                    .disabled(defaultVoiceChoices.isEmpty)
                }

                // 稿 `paneCreative` 只在「默认音色 / 默认语速」之间画一条 hairline；
                // 一整张卡里的行用整宽 1pt 分隔线分节（§7.10 的 `controlRow`）。
                settingsRowSeparator

                settingsRow {
                    LabeledContent {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.sm) {
                            Slider(value: $defaultSpeed, in: 0.5...2.0, step: 0.1)
                            // 稿的 `sliderControl(parent, width, ratio, value)`（`main.js:2463`）
                            // 在设置页与配音台是**同一个控件、同一个 132**
                            // （`main.js:2554` 与 `:1352` 都传 132；4x 帧 `Menu & Settings.png`
                            // 实测滑轨 x 1183.0–1314.5 = **131.75**）。应用此前在这里就地写
                            // 160（帧 132，残差 28），且没有第二个 132 —— 所以复用配音台那个
                            // token，不再写第二处数值（REDESIGN-SPEC §11.6 第五十六轮）。
                                .frame(width: SpeechRailDesignTokens.Layout.creatorSpeedSliderWidth)
                        // 取值写**全角 ×**：稿的同一行 `main.js:2554` 是 `1.0×`、下一行 caption
                        // `:2553` 是 `0.5×–2.0×`，4x 帧两处也都是全角（波形墨迹 x 2413–2496）。
                        // 配音台那一处稿写的是 ASCII `1.0x`（`main.js:1359`），两页各自按稿，
                        // 所以本文件用 ×、`CreatorSurfaceViews` 继续用 x。
                            Text(String(format: "%.1f×", defaultSpeed))
                                .font(SpeechRailDesignTokens.Typography.technical)
                                .monospacedDigit()
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        }
                        // 控件组保持理想宽度：标签列是可伸缩的，不加这一句时滑块会把
                        // 取值文字挤到行外（离屏实测「1.0×」整段不可见）。
                        .fixedSize()
                    } label: {
                        settingsRowLabel(
                            "默认语速",
                            caption: "0.5×–2.0×，可在配音台逐条覆盖。"
                        )
                    }
                }
            }
        }
    }

    private var servicePane: some View {
        settingsPane {
            settingsSection("连接") {
                settingsRow {
                    // 稿 `paneService` 的取值走 `valueText(p, "8201", "Body / Medium")`：
                    // 标签是 `Body`、取值是**中等的正文**，且贴卡内沿（`controlRow` 的
                    // `grow(labels)` 把取值顶到行尾）。`LabeledContent` 两样都给不了：
                    // 标签不可伸缩时取值贴在标签后面，标签可伸缩时取值被挤出可视区
                    // （两种都离屏实测过，见 REDESIGN-SPEC §11.6 第五十七轮）。
                    settingsValueRow(
                        "服务端口",
                        value: portText,
                        valueFont: SpeechRailDesignTokens.Typography.bodyMedium
                    )
                }
            }

            settingsSection("诊断") {
                settingsRow {
                    Toggle(isOn: $includeServiceContextInReports) {
                        settingsRowLabel(
                            "诊断报告包含运行档位与版本",
                            caption: "报告始终不含凭据、原始音频、完整转写或本地绝对路径。"
                        )
                    }
                        .modifier(settingsRowControl())
                }
            }

            settingsSection("关于") {
                settingsRow {
                    settingsValueRow("产品定位", value: "本机 Apple Silicon 语音服务控制面")
                }
                settingsRowSeparator
                settingsRow {
                    settingsValueRow("最低系统", value: "macOS 26.0")
                }
                settingsRowSeparator
                settingsRow {
                    settingsValueRow("版本", value: Bundle.main.shortVersionString)
                }
            }
        }
    }

    private func seedAdvancedLLMConfigurationExpansion() {
        guard !didSeedAdvancedLLMConfigurationExpansion else { return }
        didSeedAdvancedLLMConfigurationExpansion = true
        isAdvancedLLMConfigurationExpanded = LLMModule.allCases.contains {
            preferences.llmOverride(for: $0).enabled
        }
    }

    private func keyDraft(for module: LLMModule?) -> String {
        if let module {
            return moduleKeyDrafts[module.rawValue] ?? ""
        }
        return llmKeyDraft
    }

    private func setKeyDraft(_ draft: String, for module: LLMModule?) {
        if let module {
            moduleKeyDrafts[module.rawValue] = draft
        } else {
            llmKeyDraft = draft
        }
    }

    private func keyScope(for module: LLMModule?) -> LLMKeychain.Scope {
        if let module {
            return .module(module)
        }
        return .global
    }

    private func markKeySaved(for module: LLMModule?) {
        if let module {
            moduleKeySaved.insert(module.rawValue)
        } else {
            llmKeySaved = LLMKeychain.hasKey
        }
    }

    @discardableResult
    private func persistDraftKeyIfPresent(for module: LLMModule?) throws -> Bool {
        let draft = keyDraft(for: module)
        guard let normalizedDraft = LLMKeyDraftPolicy.normalizedDraft(draft) else {
            return false
        }
        try LLMKeychain.save(normalizedDraft, scope: keyScope(for: module))
        setKeyDraft("", for: module)
        markKeySaved(for: module)
        return true
    }

    private func clearGlobalKey() {
        do {
            try LLMKeychain.remove()
            llmKeySaved = false
            if checkedModule == nil {
                checkedModule = nil
                connectionResult = nil
                keySaveError = nil
            }
        } catch {
            checkedModule = nil
            keySaveError = nil
            connectionResult = .unreachable(error.localizedDescription)
        }
    }

    private func clearModuleKey(for module: LLMModule) {
        do {
            try LLMKeychain.remove(scope: .module(module))
            moduleKeyDrafts[module.rawValue] = ""
            moduleKeySaved.remove(module.rawValue)
            if checkedModule == module {
                checkedModule = nil
                connectionResult = nil
                keySaveError = nil
            }
        } catch {
            checkedModule = module
            keySaveError = nil
            connectionResult = .unreachable(error.localizedDescription)
        }
    }

    private var diarizationCaptionsBinding: Binding<Bool> {
        Binding(
            get: { preferences.captionsDiarizationEnabled },
            set: { preferences.captionsDiarizationEnabled = $0 }
        )
    }

    private var diarizationMeetingBinding: Binding<Bool> {
        Binding(
            get: { preferences.meetingDiarizationEnabled },
            set: { preferences.meetingDiarizationEnabled = $0 }
        )
    }

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { preferences.notifyOnInterruption },
            set: { preferences.notifyOnInterruption = $0 }
        )
    }

    private func checkConnection(
        for module: LLMModule?,
        saveRequested: Bool
    ) async {
        isChecking = true
        checkedModule = module
        keySaveError = nil
        defer { isChecking = false }
        let resolved: ResolvedLLMConfiguration
        if let module {
            resolved = preferences.resolvedLLMConfiguration(for: module)
        } else {
            resolved = ResolvedLLMConfiguration(
                configuration: preferences.llmConfiguration,
                apiKey: LLMKeychain.load(),
                origin: .global
            )
        }
        let draft = keyDraft(for: module)
        let candidateKey = LLMKeyDraftPolicy.candidateKey(
            draft: draft,
            storedKey: resolved.apiKey
        )
        let result = await LLMProvider().check(
            configuration: resolved.configuration,
            apiKey: candidateKey
        )
        connectionResult = result
        guard LLMKeyDraftPolicy.shouldPersist(
            draft: draft,
            connection: result,
            saveRequested: saveRequested
        ) else {
            return
        }
        do {
            _ = try persistDraftKeyIfPresent(for: module)
        } catch {
            keySaveError = error.localizedDescription
        }
    }

    private func backupLibrary() {
        guard let source = SessionStore.defaultLibraryURL() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sessions-\(Self.backupStamp()).sqlite3"
        panel.title = "备份记录库"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    private func openDataDirectory() {
        guard let url = SessionStore.defaultLibraryURL()?.deletingLastPathComponent() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
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

extension Bundle {
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
                Entry(shortcut: "⌘1–⌘5", title: "配音台 / 音色创作 / 音色克隆 / 音色库 / 我的作品", detail: "创作页之间切换。"),
                Entry(shortcut: "⌘6–⌘9", title: "服务状态 / 运行监控 / 模型 / 诊断", detail: "引擎页之间切换。"),
                Entry(shortcut: "⌘0", title: "开发者文档", detail: "查看本机服务的接入方式与示例。"),
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
