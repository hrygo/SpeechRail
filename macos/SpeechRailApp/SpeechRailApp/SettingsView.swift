import Foundation
import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(SessionPreferences.self) private var preferences
    @AppStorage("speechrail.showDeveloperDetails") private var showDeveloperDetails = false
    @AppStorage("speechrail.refreshOnLaunch") private var refreshOnLaunch = true
    @AppStorage("speechrail.creator.defaultVoiceID") private var defaultVoiceID = ""
    @AppStorage("speechrail.creator.defaultSpeed") private var defaultSpeed: Double = 1.0
    @AppStorage(SpeechRailDesignTokens.CaptionBand.fontSizeDefaultsKey)
    private var captionFontSizeRaw = CaptionBandFontSize.standard.rawValue
    @State private var llmKeyDraft = ""
    /// 钥匙串里有没有那一份密钥。**不在 `@State` 的默认值表达式里读**：那个表达式在
    /// 每一次重建视图时都会跑，而读钥匙串是一次可能被系统弹框拦下的同步调用——
    /// 它与助手页那处是同一个毛病（2026-09-19）。
    @State private var llmKeySaved = false
    @State private var moduleKeyDrafts: [String: String] = [:]
    @State private var moduleKeySaved: Set<String> = []
    @State private var connectionResult: LLMConnectionResult?
    @State private var isChecking = false
    @State private var checkedModule: LLMModule?

    public init() {}

    public var body: some View {
        // Figma `05 Menu & Settings`：设置窗口是「通用 / 创作 / 服务」三个目的地，
        // 用系统 TabView（macOS 26 的图标 + 文字页签）而不是再加一条侧边栏。
        TabView {
            Tab("通用", systemImage: "slider.horizontal.3") {
                generalPane
            }
            Tab("创作", systemImage: "sparkles") {
                creativePane
            }
            Tab("会话", systemImage: "waveform.badge.mic") {
                sessionPane
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

    /// 设置页的三条几何，全部取自稿 `figma-kit/main.js` 与 4x 帧 `Menu & Settings.png`
    /// 的逐像素实测（REDESIGN-SPEC §11.6 第五十七轮）。
    ///
    /// 命名在这里而不是共用的 token 文件：这三个数值只服务设置窗口这一个界面
    /// （`settingsWindow` / `settingsSection` / `controlRow` 各一处声明），
    /// 与页面上通用的 `Spacing` 档不是同一套语义。
    private enum Metrics {
        /// 页签内容区到窗口沿的距离：稿 `content` 帧 `pad: 16`。
        ///
        /// 卡片要落在**距窗口沿 16pt**（§7.10「行卡宽 608 = 640 − 2×16」，4x 帧实测卡沿
        /// x 80→688），但系统 `TabView` 的内容区比窗口窄 **6pt**（窗口视图树实测：
        /// 640 的宿主里内容区是 634，两侧各 3pt；`NSTabView` 自身的 bezel）。所以页签
        /// 内容区里的内边距取 `16 − 3`，让卡片既落在距窗口沿 16 的位置、又是 608 宽。
        static let paneInset: CGFloat = 13
        /// 稿 `content` 的 `gap: 16`：卡片之间、以及小节标题与卡片之间都是它。
        static let sectionGap = SpeechRailDesignTokens.Spacing.md
        /// 稿 `settingsSection` 的 `sectionHead`（`padX 4` / `padY 6`）。
        static let sectionHeadInsetX = SpeechRailDesignTokens.Spacing.micro
        static let sectionHeadInsetY: CGFloat = 6
        /// 稿 `controlRow` 的 `padX 16` / `padY 11`（帧实测行高 59 = 11 + 37 + 11）。
        static let rowInsetX = SpeechRailDesignTokens.Spacing.md
        static let rowInsetY: CGFloat = 11
    }

    /// 页签内容区：地板 `surface/window`（`#E8E8EA` / `#201E21`）+ 16pt 内边距 + 16pt 节间距。
    ///
    /// **为什么不再用系统 grouped `Form`**（REDESIGN-SPEC §11.6 第五十七轮）：
    /// 系统 grouped `Form` 的两条行为与稿**结构性冲突**，不是数值调不齐——
    /// ① 行卡是**半透明叠加**，永远等于「它背后的底色 −3%」：裸系统表单实测
    /// 白底 → `#F7F7F7`，应用地板 `#E8E8EA` → `#E1E1E3`。也就是说原生表单
    /// **画不出**稿那种「白卡坐在灰地板上」（方向相反），`.listRowBackground` 也无效；
    /// ② 它自己的行卡距窗口左右各 **20pt**（卡宽 600），而稿是 **16pt / 608**
    /// （4x 帧实测卡沿 x 80→688，640 宽窗口各留 16）。§7.10 明写「行卡宽度 608
    /// （640 − 2×16）」，所以这里改成应用自己的卡片语言——与全应用其余页面的
    /// `CardSurface` 同源，控件仍是系统 `Toggle` / `Picker` / `Slider` / `LabeledContent`。
    // MARK: - 会话（第 4 个页签，`SESSIONS-SPEC` §6.5）

    private var sessionPane: some View {
        settingsPane {
            settingsSection("大模型（全局默认）") {
                settingsRow {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        settingsRowLabel(
                            "服务地址",
                            caption: "兼容 OpenAI 的服务地址，本机或局域网都行；不要把密钥写进地址里。"
                        )
                        TextField("http://127.0.0.1:8000/v1", text: addressBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                    }
                }
                settingsRowSeparator
                settingsRow {
                    // 「接口」是**只读事实**：不提供降级选项（§6.5），取值本身就是
                    // 「Responses · 必须」这一句（`SessionPreferences.llmInterface`），
                    // 所以不再另挂一颗「必须」胶囊——稿 `kvRow(req, ["接口",
                    // "Responses API（必须）"])` 也是一句取值。
                    //
                    // 布局**不能**用 `LabeledContent`：真机走查（2026-09-19）里取值那一侧
                    // 整段被挤出可视区，`Responses · 必须` 一个字都看不见，行尾只剩一个
                    // 空胶囊。老毛病在本文件「服务端口」那一行已经记过一次（标签可伸缩时
                    // 取值被挤出可视区），修法同那处：自己排「标签 → 弹性空隙 → 取值」。
                    HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
                        settingsRowLabel(
                            "接口",
                            caption: "对话与纪要都走 Responses API；只提供 Chat Completions 的服务接不上。"
                        )
                        Spacer(minLength: 0)
                        Text(preferences.llmInterface)
                            .font(SpeechRailDesignTokens.Typography.callout)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                settingsRowSeparator
                settingsRow {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        settingsRowLabel("模型", caption: "从该服务的模型列表里选；填错会得到「模型没加载」的结论。")
                        TextField("模型名", text: modelBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                    }
                }
                settingsRowSeparator
                settingsRow {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        settingsRowLabel(
                            "密钥",
                            caption: llmKeySaved
                                ? "已存入钥匙串（不落配置文件、不进日志）。"
                                : "只存钥匙串；服务不需要密钥时留空即可。"
                        )
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            SecureField("粘贴密钥", text: $llmKeyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 280)
                            Button("保存到钥匙串") {
                                do {
                                    try LLMKeychain.save(llmKeyDraft)
                                    llmKeyDraft = ""
                                    llmKeySaved = LLMKeychain.hasKey
                                } catch {
                                    connectionResult = .unreachable(error.localizedDescription)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            if llmKeySaved {
                                Button("清除") {
                                    try? LLMKeychain.remove()
                                    llmKeySaved = false
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                settingsRowSeparator
                settingsRow {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Button("检查连接") {
                                Task { await checkConnection(for: nil) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isChecking || !preferences.isLLMConfigured)
                            if isChecking, checkedModule == nil {
                                ProgressView().controlSize(.small)
                            }
                            if checkedModule == nil, let result = connectionResult {
                                StatusPill(
                                    tone: result.isReady ? .healthy : .attention,
                                    label: result.title
                                )
                            }
                        }
                        if checkedModule == nil, let result = connectionResult {
                            Text(result.detail)
                                .font(SpeechRailDesignTokens.Typography.caption)
                                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                settingsRowSeparator
                settingsRow {
                    Text("所有 AI 模块默认使用一台兼容 OpenAI、支持 Responses API 的服务；"
                        + "需要时可以在下面为单个模块指定不同配置。识别、合成与「谁在说话」由 SpeechRail 本机提供。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsSection("模块专用配置（可选）") {
                ForEach(LLMModule.allCases) { module in
                    moduleConfigurationRows(for: module)
                    if module != LLMModule.allCases.last {
                        settingsRowSeparator
                    }
                }
                settingsRow {
                    Text("专用配置只影响对应模块；没有完整填写时会整组回退到全局默认，不会把不同来源的地址与模型拼在一起。专用 Key 留空则继承全局 Key。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            settingsSection("语音助手") {
                settingsRow {
                    Picker(selection: personaBinding) {
                        ForEach(preferences.personas) { persona in
                            Text(persona.title).tag(persona.id)
                        }
                    } label: {
                        settingsRowLabel(
                            "默认角色",
                            caption: "只在新对话开始时预填；开始之后本轮不再变（中途换会让它把开头重读一遍）。"
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
                        settingsRowLabel("默认音色", caption: "对话中仍可随时换，下一句生效。")
                    }
                    .pickerStyle(.menu)
                }
                settingsRowSeparator
                settingsRow {
                    Picker(selection: modeBinding) {
                        ForEach(AssistantMode.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    } label: {
                        settingsRowLabel(
                            "对讲模式",
                            caption: "一问一答：它说话时闭麦；实时对讲：随时插话打断（建议耳机）。"
                        )
                    }
                    .pickerStyle(.segmented)
                }
            }

            settingsSection("实时字幕") {
                settingsRow {
                    Picker(selection: $captionFontSizeRaw) {
                        ForEach(CaptionBandFontSize.allCases) { size in
                            Text(size.title).tag(size.rawValue)
                        }
                    } label: {
                        settingsRowLabel("默认字号", caption: "字幕带也可以悬停工具条里临时改。")
                    }
                    .pickerStyle(.segmented)
                }
                settingsRowSeparator
                settingsRow {
                    Toggle(isOn: diarizationCaptionsBinding) {
                        settingsRowLabel(
                            "说话人标签",
                            caption: diarizationCaption(for: preferences.captionsDiarizationEnabled)
                        )
                    }
                }
            }

            settingsSection("会议") {
                settingsRow {
                    Toggle(isOn: diarizationMeetingBinding) {
                        settingsRowLabel(
                            "说话人标签",
                            caption: diarizationCaption(for: preferences.meetingDiarizationEnabled)
                        )
                    }
                }
                settingsRowSeparator
                settingsRow {
                    VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                        settingsRowLabel("记录库", caption: "本机数据库（SQLite）；删掉 App 不会动它。")
                        HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                            Button("打开数据目录") {
                                if let url = SessionStore.defaultLibraryURL()?.deletingLastPathComponent() {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("备份库文件…") {
                                backupLibrary()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                settingsRowSeparator
                settingsRow {
                    Text("不保存音频：会议只保留文本与说话人归属。")
                        .font(SpeechRailDesignTokens.Typography.caption)
                        .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                }
            }

            settingsSection("通用") {
                settingsRow {
                    Toggle(isOn: notifyBinding) {
                        settingsRowLabel(
                            "中断时用系统通知告诉我",
                            caption: "默认关。只在「必须有人决定」的中断上发一次；通知里不出现记录原文。"
                        )
                    }
                }
            }
        }
    }

    private func diarizationCaption(for enabled: Bool) -> String {
        if let note = SessionPreferences.diarizationGateNote(for: model.profile?.preset?.rawValue) {
            return note
        }
        return enabled
            ? "开着的：新会话会在行上标出说话人（匿名编号，改名字是你的动作）。"
            : "默认关；打开后新会话才开始标出谁在说话。"
    }

    // MARK: 绑定（偏好只有一处声明点：`SessionPreferences`）

    private var addressBinding: Binding<String> {
        Binding(get: { preferences.llmBaseURL }, set: { preferences.llmBaseURL = $0 })
    }

    private var modelBinding: Binding<String> {
        Binding(get: { preferences.llmModel }, set: { preferences.llmModel = $0 })
    }

    private var personaBinding: Binding<String> {
        Binding(get: { preferences.defaultPersonaID }, set: { preferences.defaultPersonaID = $0 })
    }

    private var voiceBinding: Binding<String> {
        Binding(get: { preferences.defaultVoiceID }, set: { preferences.defaultVoiceID = $0 })
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { preferences.assistantMode.rawValue },
            set: { preferences.assistantMode = AssistantMode(rawValue: $0) ?? .duplex }
        )
    }

    @ViewBuilder
    private func moduleConfigurationRows(for module: LLMModule) -> some View {
        let override = preferences.llmOverride(for: module)
        let configuration = preferences.llmConfiguration(for: module)

        settingsRow {
            Toggle(isOn: moduleEnabledBinding(for: module)) {
                settingsRowLabel(
                    module.title,
                    caption: override.enabled
                        ? moduleStatusText(override: override, configuration: configuration)
                        : "跟随全局默认配置。\(module.detail)"
                )
            }
            .modifier(settingsRowControl())
        }

        if override.enabled {
            settingsRowSeparator
            settingsRow {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    settingsRowLabel("专用服务地址", caption: "与全局配置成对生效；地址里不要放密钥。")
                    TextField("http://127.0.0.1:8000/v1", text: moduleOverrideBinding(for: module, keyPath: \.baseURL))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }
            }
            settingsRowSeparator
            settingsRow {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    settingsRowLabel("专用模型", caption: "留空或不完整时，这张卡会回退到全局配置。")
                    TextField("模型名", text: moduleOverrideBinding(for: module, keyPath: \.model))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }
            }
            settingsRowSeparator
            settingsRow {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    settingsRowLabel(
                        "专用密钥",
                        caption: moduleKeySaved.contains(module.rawValue)
                            ? "已存入模块专用安全保管库。"
                            : "留空表示继承全局 Key；只存安全保管库，不落配置文件。"
                    )
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        SecureField("留空继承全局 Key", text: moduleKeyBinding(for: module))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                        Button("保存专用 Key") {
                            saveModuleKey(for: module)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        if moduleKeySaved.contains(module.rawValue) {
                            Button("清除") {
                                clearModuleKey(for: module)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            settingsRowSeparator
            settingsRow {
                VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Spacing.xs) {
                    HStack(spacing: SpeechRailDesignTokens.Spacing.xs) {
                        Button("检查连接") {
                            Task { await checkConnection(for: module) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(
                            isChecking
                                || !configuration.isConfigured
                                || !configuration.isBaseURLValid
                                || configuration.embedsCredential
                        )
                        if isChecking, checkedModule == module {
                            ProgressView().controlSize(.small)
                        }
                        if checkedModule == module, let result = connectionResult {
                            StatusPill(
                                tone: result.isReady ? .healthy : .attention,
                                label: result.title
                            )
                        }
                    }
                    if checkedModule == module, let result = connectionResult {
                        Text(result.detail)
                            .font(SpeechRailDesignTokens.Typography.caption)
                            .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func moduleStatusText(
        override: LLMModuleOverride,
        configuration: LLMConfiguration
    ) -> String {
        guard override.enabled else { return "跟随全局默认配置。" }
        guard configuration.isConfigured, configuration.isBaseURLValid, !configuration.embedsCredential else {
            return "专用配置不完整或地址不合法，当前回退到全局默认。"
        }
        return "当前生效：专用服务与模型。"
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

    private func moduleKeyBinding(for module: LLMModule) -> Binding<String> {
        Binding(
            get: { moduleKeyDrafts[module.rawValue] ?? "" },
            set: { moduleKeyDrafts[module.rawValue] = $0 }
        )
    }

    private func saveModuleKey(for module: LLMModule) {
        do {
            try LLMKeychain.save(
                moduleKeyDrafts[module.rawValue] ?? "",
                scope: .module(module)
            )
            moduleKeyDrafts[module.rawValue] = ""
            moduleKeySaved.insert(module.rawValue)
        } catch {
            checkedModule = module
            connectionResult = .unreachable(error.localizedDescription)
        }
    }

    private func clearModuleKey(for module: LLMModule) {
        do {
            try LLMKeychain.remove(scope: .module(module))
            moduleKeyDrafts[module.rawValue] = ""
            moduleKeySaved.remove(module.rawValue)
        } catch {
            checkedModule = module
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

    private func checkConnection(for module: LLMModule?) async {
        isChecking = true
        checkedModule = module
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
        connectionResult = await LLMProvider().check(
            configuration: resolved.configuration,
            apiKey: resolved.apiKey
        )
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

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    private func settingsPane<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                content()
            }
            .padding(Metrics.paneInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 地板画在页签内容区这一层而不是 `TabView` 上：本机离屏实测，`.background`
        // 挂在 `TabView` 上会被它自己的背衬压暗（#E8E8EA 变成 #E1E1E3）。
        .background(SpeechRailDesignTokens.Color.canvas)
    }

    /// 小节：标题在卡外、行在卡内——这就是 macOS grouped form 的形状
    /// （稿 `settingsSection` 的注释），所以设置窗口不必发明自己的层级。
    ///
    /// 卡本身按 §5.2 只有填充、没有描边（稿的 `card()` 同理：既不承载交互、
    /// 也不表达层级的表面一律不画描边和阴影）。卡宽由 16pt 内边距推出 608，
    /// 与 §7.10 一致；`Corner.containerShape` 让卡内的叶面（焦点环）同心推导。
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionGap) {
            Text(title)
                .font(SpeechRailDesignTokens.Typography.captionMedium)
                .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                .padding(.horizontal, Metrics.sectionHeadInsetX)
                .padding(.vertical, Metrics.sectionHeadInsetY)
            VStack(spacing: 0) {
                rows()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SpeechRailDesignTokens.Color.field,
                in: SpeechRailDesignTokens.Corner.containerShape
            )
            .containerShape(SpeechRailDesignTokens.Corner.containerShape)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 卡内一行：稿 `controlRow` 的 `padX 16` / `padY 11`，标题列与右侧控件同属一行。
    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Metrics.rowInsetX)
            .padding(.vertical, Metrics.rowInsetY)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 卡内行之间的分隔线：稿的 `hairline()` 是**整卡宽**的 1pt `border/separator`。
    /// 应用取系统的 `separatorColor`（§5.4：分隔线交给系统），因此两种外观与
    /// Increase Contrast 都不必自成一套。
    private var settingsRowSeparator: some View {
        Rectangle()
            .fill(SpeechRailDesignTokens.Color.separator)
            .frame(height: SpeechRailDesignTokens.Spacing.hairline)
    }

    /// 「标题 → 取值」行：稿 `controlRow` 的 `grow(labels)` 把取值顶到行尾，
    /// 取值字号取 `valueText()` 的默认档 `Callout`（`main.js:2500`）。
    private func settingsValueRow(
        _ title: String,
        value: String,
        valueFont: Font = SpeechRailDesignTokens.Typography.callout
    ) -> some View {
        HStack(spacing: SpeechRailDesignTokens.Spacing.md) {
            settingsRowLabel(title)
            Spacer(minLength: 0)
            Text(value)
                .font(valueFont)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// 行内控件的通用几何：撑满整行、至少一个点击目标高、整行可点、指针变手型。
    private func settingsRowControl() -> some ViewModifier {
        SettingsRowControlModifier()
    }

    private struct SettingsRowControlModifier: ViewModifier {
        func body(content: Content) -> some View {
            content
                // `Toggle` 离开 grouped `Form` 之后会掉回**前导 Checkbox** 样式；
                // 系统 grouped form 的默认是尾随开关，稿画的也是开关（帧实测
                // 开关墨迹 x 637.8–670 = 距卡片内沿 16 起），所以显式声明 `.switch`。
                .toggleStyle(.switch)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .contentShape(Rectangle())
                .speechRailPointerCursor()
        }
    }

    /// 设置行的一行式标签：标题 + 副标题。
    ///
    /// 稿（`05 Menu & Settings` 的 `controlRow`）把说明写成**行内副标题**——`labels` 列里
    /// `Body` 标题 + 3pt + `Caption` 说明，与右侧控件同属一行。应用此前把说明写成同一
    /// `Section` 里的独立 `Text`，grouped `Form` 会给它单独一行并画分隔线，读起来像两个
    /// 设置项（离屏实渲染可见分隔线）。改成自定义标签后行结构与稿一致，也仍是系统
    /// `Toggle` / `Picker` / `LabeledContent`，VoiceOver 会把说明一并读作这一项的标签。
    private func settingsRowLabel(_ title: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: SpeechRailDesignTokens.Settings.rowLabelSpacing) {
            Text(title)
            if let caption {
                Text(caption)
                    .font(SpeechRailDesignTokens.Typography.caption)
                    .foregroundStyle(SpeechRailDesignTokens.Color.inkSecondary)
                    .lineLimit(SpeechRailDesignTokens.Settings.secondaryTextMaximumLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 标签列必须是**可伸缩**的：`Toggle` / `Picker` 的控件跟着标签的宽度走，
        // 标签一旦是固定宽度，控件就停在文字右边而不是行尾（稿 `controlRow` 是
        // `HORIZONTAL` + `grow(labels)`，右侧控件永远贴卡内沿 16pt）。
        .frame(maxWidth: .infinity, alignment: .leading)
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
