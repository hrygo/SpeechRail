import AppKit
import SwiftUI

struct SettingsAssistantPane: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionPreferences.self) private var preferences

    @AppStorage(SpeechRailDesignTokens.CaptionBand.fontSizeDefaultsKey)
    private var captionFontSizeRaw = CaptionBandFontSize.standard.rawValue

    @Binding private var llmKeyDraft: String
    @Binding private var llmKeySaved: Bool
    @Binding private var moduleKeyDrafts: [String: String]
    @Binding private var moduleKeySaved: Set<String>
    @Binding private var connectionResult: LLMConnectionResult?
    @Binding private var keySaveError: String?
    @Binding private var isChecking: Bool
    @Binding private var checkedModule: LLMModule?
    @Binding private var isAdvancedLLMConfigurationExpanded: Bool

    private let onCheckConnection: (LLMModule?, Bool) -> Void
    private let onClearGlobalKey: () -> Void
    private let onClearModuleKey: (LLMModule) -> Void
    private let onOpenDataDirectory: () -> Void
    private let onBackupLibrary: () -> Void

    init(
        llmKeyDraft: Binding<String>,
        llmKeySaved: Binding<Bool>,
        moduleKeyDrafts: Binding<[String: String]>,
        moduleKeySaved: Binding<Set<String>>,
        connectionResult: Binding<LLMConnectionResult?>,
        keySaveError: Binding<String?>,
        isChecking: Binding<Bool>,
        checkedModule: Binding<LLMModule?>,
        isAdvancedLLMConfigurationExpanded: Binding<Bool>,
        onCheckConnection: @escaping (LLMModule?, Bool) -> Void,
        onClearGlobalKey: @escaping () -> Void,
        onClearModuleKey: @escaping (LLMModule) -> Void,
        onOpenDataDirectory: @escaping () -> Void,
        onBackupLibrary: @escaping () -> Void
    ) {
        self._llmKeyDraft = llmKeyDraft
        self._llmKeySaved = llmKeySaved
        self._moduleKeyDrafts = moduleKeyDrafts
        self._moduleKeySaved = moduleKeySaved
        self._connectionResult = connectionResult
        self._keySaveError = keySaveError
        self._isChecking = isChecking
        self._checkedModule = checkedModule
        self._isAdvancedLLMConfigurationExpanded = isAdvancedLLMConfigurationExpanded
        self.onCheckConnection = onCheckConnection
        self.onClearGlobalKey = onClearGlobalKey
        self.onClearModuleKey = onClearModuleKey
        self.onOpenDataDirectory = onOpenDataDirectory
        self.onBackupLibrary = onBackupLibrary
    }

    var body: some View {
        settingsPane {
            settingsSection("对话服务") {
                settingsRow {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        settingsRowLabel(
                            "对话服务",
                            caption: "语音助手、会议纪要和 AI 提词器会共用这里的服务。"
                        )
                        SettingsConnectionStatus(
                            result: checkedModule == nil ? connectionResult : nil,
                            isChecking: checkedModule == nil && isChecking,
                            saveError: checkedModule == nil ? keySaveError : nil
                        )
                        if connectionResult == nil, !isChecking {
                            Text(
                                preferences.isLLMConfigured
                                    ? "可以检查连接。"
                                    : "先填写服务地址和模型，之后这里会告诉你下一步。"
                            )
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                settingsRowSeparator
                settingsRow {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        settingsRowLabel(
                            "服务地址",
                            caption: "填写服务地址，不要把密钥放进地址里。"
                        )
                        TextField("例如 https://example.com/v1", text: addressBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .accessibilityLabel("服务地址")
                            .accessibilityHint("填写服务地址，不要把密钥放进地址里。")
                        if let message = addressValidationMessage {
                            Text(message)
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.critical)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("服务地址提示：\(message)")
                        }
                    }
                }
                settingsRowSeparator
                settingsRow {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        settingsRowLabel(
                            "模型",
                            caption: "填入这台服务里实际可用的模型名称。"
                        )
                        TextField("例如 speech-model", text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                            .accessibilityLabel("模型")
                            .accessibilityHint("填写这台服务里实际可用的模型名称。")
                    }
                }
                settingsRowSeparator
                settingsRow {
                    Picker(selection: compatibilityModeBinding) {
                        ForEach(LLMCompatibilityMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    } label: {
                        settingsRowLabel(
                            "兼容协议",
                            caption: preferences.llmCompatibilityMode.detail
                                + " SpeechRail 不主动开启 thinking。"
                        )
                    }
                    .pickerStyle(.menu)
                }
                settingsRowSeparator
                settingsRow {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        settingsRowLabel(
                            "密钥",
                            caption: llmKeySaved
                                ? "已保存到安全保管库；输入新值可更换。"
                                : "只保存到安全保管库；服务不需要密钥时可以留空。"
                        )
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            SecureField("输入密钥", text: $llmKeyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 280)
                                .accessibilityLabel("密钥")
                                .accessibilityHint("输入后使用检查并保存；密钥只保存到安全保管库。")
                            if llmKeySaved {
                                Button("清除密钥", action: onClearGlobalKey)
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .speechRailPointerCursor()
                            }
                        }
                    }
                }
                settingsRowSeparator
                settingsRow {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button(globalActionTitle) {
                            onCheckConnection(nil, globalSaveRequested)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .speechRailPointerCursor()
                        .help(globalActionHelp)
                        .disabled(globalCheckDisabled)
                        Text("按功能使用 Chat Completions 或 Responses；SpeechRail 不主动开启 thinking。")
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                settingsRowSeparator
                settingsRow {
                    Text("识别、合成和说话人标签由 SpeechRail 本机提供；这里仅设置需要联网或本机运行的对话服务。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsSection("新助手默认值") {
                settingsRow {
                    Picker(selection: personaBinding) {
                        ForEach(preferences.personas) { persona in
                            Text(persona.title).tag(persona.id)
                        }
                    } label: {
                        settingsRowLabel(
                            "默认角色",
                            caption: "只影响新开始的对话；已经开始的对话不会被改写。"
                        )
                    }
                    .pickerStyle(.menu)
                }
                settingsRowSeparator
                settingsRow {
                    Picker(selection: voiceBinding) {
                        Text("跟随音色库默认").tag("")
                        ForEach(defaultVoiceChoices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    } label: {
                        settingsRowLabel("默认音色", caption: "新对话会先使用这个音色，也可以在对话中更换。")
                    }
                    .pickerStyle(.menu)
                    .disabled(defaultVoiceChoices.isEmpty)
                }
                settingsRowSeparator
                settingsRow {
                    Picker(selection: modeBinding) {
                        ForEach(AssistantMode.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    } label: {
                        settingsRowLabel(
                            "对讲方式",
                            caption: "一问一答会在它说话时闭麦；实时对讲可以随时打断，建议戴耳机。"
                        )
                    }
                    .pickerStyle(.segmented)
                }
            }

            settingsSection("字幕与会议") {
                settingsRow {
                    Picker(selection: $captionFontSizeRaw) {
                        ForEach(CaptionBandFontSize.allCases) { size in
                            Text(size.title).tag(size.rawValue)
                        }
                    } label: {
                        settingsRowLabel("字幕默认字号", caption: "字幕工具条里还可以临时调整。")
                    }
                    .pickerStyle(.segmented)
                }
                settingsRowSeparator
                settingsRow {
                    Toggle(isOn: diarizationCaptionsBinding) {
                        settingsRowLabel(
                            "字幕显示说话人",
                            caption: diarizationCaption(for: preferences.captionsDiarizationEnabled)
                        )
                    }
                        .modifier(settingsRowControl())
                }
                settingsRowSeparator
                settingsRow {
                    Toggle(isOn: diarizationMeetingBinding) {
                        settingsRowLabel(
                            "会议显示说话人",
                            caption: diarizationCaption(for: preferences.meetingDiarizationEnabled)
                        )
                    }
                        .modifier(settingsRowControl())
                }
                settingsRowSeparator
                settingsRow {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        settingsRowLabel(
                            "记录库",
                            caption: "只保留文字与说话人归属，不保存音频。"
                        )
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Button("打开数据目录", action: onOpenDataDirectory)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .speechRailPointerCursor()
                            Button("备份记录库", action: onBackupLibrary)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .speechRailPointerCursor()
                        }
                    }
                }
            }

            settingsSection("通知") {
                settingsRow {
                    Toggle(isOn: notifyBinding) {
                        settingsRowLabel(
                            "中断时通知我",
                            caption: "只在需要你决定时通知，通知里不会出现记录原文。"
                        )
                    }
                        .modifier(settingsRowControl())
                }
            }

            settingsSection("高级：按功能单独设置") {
                DisclosureGroup(isExpanded: $isAdvancedLLMConfigurationExpanded) {
                    VStack(spacing: 0) {
                        ForEach(LLMModule.allCases) { module in
                            moduleConfigurationRows(for: module)
                            if module != LLMModule.allCases.last {
                                settingsRowSeparator
                            }
                        }
                        settingsRow {
                            Text("没有单独设置时，所有功能跟随全局。专用配置只影响对应功能，填写不完整时会回退到全局。")
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, SpeechRailDesignTokens.Spacing.xs)
                } label: {
                    settingsRowLabel(
                        "为特定功能使用不同服务",
                        caption: llmModuleConfigurationSummary
                    )
                }
                .padding(.horizontal, SettingsMetrics.rowInsetX)
                .padding(.vertical, SettingsMetrics.rowInsetY)
                .accessibilityHint("展开后可为语音助手、会议纪要或 AI 提词器使用不同的服务与模型。")
            }
        }
    }

    private var globalSaveRequested: Bool {
        LLMKeyDraftPolicy.action(for: llmKeyDraft) == .checkAndSave
    }

    private var globalActionTitle: String {
        globalSaveRequested ? "检查并保存" : "检查连接"
    }

    private var globalActionHelp: String {
        globalSaveRequested
            ? "连接成功后才会保存新密钥"
            : "使用已保存的密钥检查连接"
    }

    private var globalCheckDisabled: Bool {
        isChecking
            || !preferences.isLLMConfigured
            || preferences.llmConfiguration.embedsCredential
            || !preferences.llmConfiguration.isBaseURLValid
    }

    private var addressValidationMessage: String? {
        let configuration = preferences.llmConfiguration
        guard !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if configuration.embedsCredential {
            return "地址里不要放密钥；请把密钥填写到下方的密钥字段。"
        }
        if !configuration.isBaseURLValid {
            return "请输入 http:// 或 https:// 地址，并填写到服务的 API 路径。"
        }
        return nil
    }

    private var addressBinding: Binding<String> {
        Binding(
            get: { preferences.llmBaseURL },
            set: { preferences.llmBaseURL = $0 }
        )
    }

    private var compatibilityModeBinding: Binding<LLMCompatibilityMode> {
        Binding(
            get: { preferences.llmCompatibilityMode },
            set: { preferences.llmCompatibilityMode = $0 }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { preferences.llmModel },
            set: { preferences.llmModel = $0 }
        )
    }

    private var personaBinding: Binding<String> {
        Binding(
            get: { preferences.defaultPersonaID },
            set: { preferences.defaultPersonaID = $0 }
        )
    }

    private var voiceBinding: Binding<String> {
        Binding(
            get: { preferences.defaultVoiceID },
            set: { preferences.defaultVoiceID = $0 }
        )
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { preferences.assistantMode.rawValue },
            set: { preferences.assistantMode = AssistantMode(rawValue: $0) ?? .duplex }
        )
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

    private var defaultVoiceChoices: [CreatorVoice] {
        model.creatorVoices.filter(\.available)
    }

    private func diarizationCaption(for enabled: Bool) -> String {
        if let note = SessionPreferences.diarizationGateNote(for: model.profile?.preset?.rawValue) {
            return note
        }
        return enabled
            ? "已开启：新会话会标出说话人，使用匿名编号。"
            : "默认关闭；打开后新会话才会标出说话人。"
    }

    @ViewBuilder
    private func moduleConfigurationRows(for module: LLMModule) -> some View {
        let override = preferences.llmOverride(for: module)
        let configuration = override.configuration

        settingsRow {
            Toggle(isOn: moduleEnabledBinding(for: module)) {
                settingsRowLabel(
                    module.title,
                    caption: moduleStatusText(override: override, configuration: configuration)
                )
            }
                .modifier(settingsRowControl())
        }

        if override.enabled {
            settingsRowSeparator
            settingsRow {
                Picker(selection: moduleCompatibilityModeBinding(for: module)) {
                    ForEach(LLMCompatibilityMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    settingsRowLabel(
                        "专用兼容协议",
                        caption: override.compatibilityMode.detail
                            + " SpeechRail 不主动开启 thinking。"
                    )
                }
                .pickerStyle(.menu)
            }
            settingsRowSeparator
            settingsRow {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    settingsRowLabel("专用服务地址", caption: "只影响这个功能；地址里不要放密钥。")
                    TextField("例如 https://example.com/v1", text: moduleOverrideBinding(for: module, keyPath: \.baseURL))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .accessibilityLabel("\(module.title)专用服务地址")
                        .accessibilityHint("只影响这个功能；地址里不要放密钥。")
                }
            }
            settingsRowSeparator
            settingsRow {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    settingsRowLabel("专用模型", caption: "这个功能会优先使用它；配置不完整时回退到全局。")
                    TextField("模型名称", text: moduleOverrideBinding(for: module, keyPath: \.model))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .accessibilityLabel("\(module.title)专用模型")
                        .accessibilityHint("配置不完整时会回退到全局配置。")
                }
            }
            settingsRowSeparator
            settingsRow {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    settingsRowLabel(
                        "专用密钥",
                        caption: moduleKeySaved.contains(module.rawValue)
                            ? "已保存到这个功能的安全保管库。"
                            : "留空表示继承全局密钥；新密钥只有检查成功后才保存。"
                    )
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        SecureField("输入专用密钥", text: moduleKeyBinding(for: module))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                            .accessibilityLabel("\(module.title)专用密钥")
                            .accessibilityHint("留空表示继承全局密钥；新密钥只有检查成功后才保存。")
                        if moduleKeySaved.contains(module.rawValue) {
                            Button("清除密钥") {
                                onClearModuleKey(module)
                            }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .speechRailPointerCursor()
                        }
                    }
                }
            }
            settingsRowSeparator
            settingsRow {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button(moduleActionTitle(for: module)) {
                            onCheckConnection(
                                module,
                                LLMKeyDraftPolicy.action(for: moduleKeyDraft(for: module)) == .checkAndSave
                            )
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .speechRailPointerCursor()
                            .help(moduleActionHelp(for: module))
                            .disabled(moduleCheckDisabled(for: module))
                        SettingsConnectionStatus(
                            result: checkedModule == module ? connectionResult : nil,
                            isChecking: checkedModule == module && isChecking,
                            saveError: checkedModule == module ? keySaveError : nil,
                            saveFailurePrefix: "连接已通过，但专用密钥未保存"
                        )
                    }
                }
            }
        }
    }

    private func moduleActionTitle(for module: LLMModule) -> String {
        LLMKeyDraftPolicy.action(for: moduleKeyDraft(for: module)) == .checkAndSave
            ? "检查并保存"
            : "检查连接"
    }

    private func moduleActionHelp(for module: LLMModule) -> String {
        LLMKeyDraftPolicy.action(for: moduleKeyDraft(for: module)) == .checkAndSave
            ? "连接成功后才会保存这个功能的新密钥"
            : "使用这个功能的已保存密钥检查连接"
    }

    private func moduleCheckDisabled(for module: LLMModule) -> Bool {
        let configuration = preferences.llmOverride(for: module).configuration
        return isChecking
            || !configuration.isConfigured
            || !configuration.isBaseURLValid
            || configuration.embedsCredential
    }

    private var llmModuleConfigurationSummary: String {
        let enabledModules = LLMModule.allCases.filter {
            preferences.llmOverride(for: $0).enabled
        }
        let needsAttention = enabledModules.contains {
            moduleConfigurationNeedsAttention(for: $0)
        }

        if needsAttention {
            return "有专用配置不完整；未设置的功能仍跟随全局。"
        }
        if enabledModules.isEmpty {
            return "默认跟随全局；需要不同服务时再展开。"
        }
        return "已有 \(enabledModules.count) 个功能使用专用配置；其余仍跟随全局。"
    }

    private func moduleConfigurationNeedsAttention(for module: LLMModule) -> Bool {
        let override = preferences.llmOverride(for: module)
        let configuration = override.configuration
        guard override.enabled else { return false }
        return !configuration.isConfigured
            || !configuration.isBaseURLValid
            || configuration.embedsCredential
    }

    private func moduleStatusText(
        override: LLMModuleOverride,
        configuration: LLMConfiguration
    ) -> String {
        guard override.enabled else { return "跟随全局配置。" }
        guard configuration.isConfigured, configuration.isBaseURLValid, !configuration.embedsCredential else {
            return "专用配置不完整，当前回退到全局。"
        }
        return "正在使用专用服务与模型。"
    }

    private func moduleEnabledBinding(for module: LLMModule) -> Binding<Bool> {
        Binding(
            get: { preferences.llmOverride(for: module).enabled },
            set: { preferences.setLLMOverrideEnabled($0, for: module) }
        )
    }

    private func moduleOverrideBinding(
        for module: LLMModule,
        keyPath: WritableKeyPath<LLMModuleOverride, String>
    ) -> Binding<String> {
        Binding(
            get: { preferences.llmOverride(for: module)[keyPath: keyPath] },
            set: { newValue in
                var override = preferences.llmOverride(for: module)
                override[keyPath: keyPath] = newValue
                preferences.updateLLMOverride(override, for: module)
            }
        )
    }

    private func moduleCompatibilityModeBinding(for module: LLMModule) -> Binding<LLMCompatibilityMode> {
        Binding(
            get: { preferences.llmOverride(for: module).compatibilityMode },
            set: { newValue in
                var override = preferences.llmOverride(for: module)
                override.compatibilityMode = newValue
                preferences.updateLLMOverride(override, for: module)
            }
        )
    }

    private func moduleKeyBinding(for module: LLMModule) -> Binding<String> {
        Binding(
            get: { moduleKeyDrafts[module.rawValue] ?? "" },
            set: { moduleKeyDrafts[module.rawValue] = $0 }
        )
    }

    private func moduleKeyDraft(for module: LLMModule) -> String {
        moduleKeyDrafts[module.rawValue] ?? ""
    }
}
