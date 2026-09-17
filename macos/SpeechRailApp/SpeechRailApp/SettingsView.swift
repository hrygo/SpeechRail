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
        // Figma `05 Menu & Settings`：设置窗口是「通用 / 创作 / 服务」三个目的地，
        // 用系统 TabView（macOS 26 的图标 + 文字页签）而不是再加一条侧边栏。
        TabView {
            Tab("通用", systemImage: "slider.horizontal.3") {
                generalPane
            }
            Tab("创作", systemImage: "sparkles") {
                creativePane
            }
            Tab("服务", systemImage: "server.rack") {
                servicePane
            }
        }
        .frame(
            minWidth: SpeechRailDesignTokens.Layout.settingsWindowMinimumWidth,
            minHeight: SpeechRailDesignTokens.Layout.settingsWindowMinimumHeight
        )
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
