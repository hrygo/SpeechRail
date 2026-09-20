import AppKit
import SwiftUI

public enum SpeechRailDesignTokens {
    public enum Spacing {
        public static let hairline: CGFloat = 1
        public static let tight: CGFloat = 2
        public static let micro: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        /// 页面级块间距（稿里的页面栈 gap）。2026-09-16 按 4x 帧实测标定：八个页面
        /// 上「块与块之间的页面底色带」都是 19–22pt，即 20pt；稿的生成脚本里页面栈
        /// 也是 `gap: 20`。应用原先一会儿用 `lg`（24，偏松 4pt）、一会儿用 `sm`
        /// （12，偏紧 8pt），本轮统一到这里（REDESIGN-SPEC §5.6 / §11.6 第十七轮）。
        public static let gutter: CGFloat = 20
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let hero: CGFloat = 48

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let xxs = micro
        public static let xxl: CGFloat = 40
    }

    public enum Layout {
        /// Navigation and inspector columns are calibrated for console stability.
        public static let sidebarWidth: CGFloat = 240
        public static let sidebarMinimumWidth: CGFloat = 220
        public static let sidebarIdealWidth: CGFloat = 240
        public static let sidebarMaximumWidth: CGFloat = 280
        public static let modelProfileListWidth: CGFloat = 280
        public static let modelProfileListMinimumWidth: CGFloat = 220
        public static let modelProfileListMaximumWidth: CGFloat = 320
        public static let inspectorWidth: CGFloat = 360
        /// 详情列（inspector）的**唯一宽度声明**：360pt 定宽，与稿的 Inspector 同口径。
        ///
        /// 2026-09-16 用户复核「两个侧边栏应该保持宽度一致」。此前这里是一个**区间**
        /// （min 300 / ideal 360 / max 440），列宽于是成了「窗口余量 + 内容最小宽 + 用户拖动」
        /// 的函数，而不是 token 的函数：装机截图里音色库那一列是 300（预览面板外框
        /// 2x 实测 539px = 269.5pt，加两侧 `contentPadding` 16 = 301.5pt ≈ 区间下限），
        /// 我的作品那一列是 360；空态没有声明时还会落回系统默认的 270。定宽之后两块
        /// 目录页（含空态）由同一处声明，宽度必然一致（REDESIGN-SPEC §11.6 第六十一轮）。
        public static let inspectorColumnWidth: CGFloat = inspectorWidth
        /// Page content margin. 20pt keeps the workspace readable at 1120–1280pt
        /// window widths instead of squeezing it with the old 32pt (§5.6).
        public static let contentPadding: CGFloat = 20
        /// 卡片内容内边距。2026-09-16 按 4x 帧实测：六个页面的卡片里，第一个字都在
        /// 距卡左沿 278.5pt 处（卡左沿 261）——正文距卡沿 20pt，去掉字形留白即稿上的
        /// 18pt。应用此前分 12 / 16 / 24 三档，本轮统一到这里（4pt 网格取 20，与页面级
        /// 块间距同值，残差 2pt；稿的工具栏式卡片 `composer` 例外，仍是 16/12）。
        public static let cardInset: CGFloat = 20
        public static let windowMinimumWidth: CGFloat = 800
        public static let windowMinimumHeight: CGFloat = 720
        /// 配音台输入卡的高度**跟随正文**（`SpeechRailComposerTextEditor.HeightPolicy.contentDriven`），
        /// 两个值是**整张卡**（正文 + 页脚元信息行）的下限与上限，与稿的 `editor`
        /// 帧同口径。
        ///
        /// 2026-09-16 三度校准后从固定区间 280–360 改成跟随内容。离屏实测（1440 × 900）：
        /// 固定区间下默认那行 53 字文稿只占 16pt，编辑框却有 277pt 高；帧图本身是
        /// 「占满剩余高度」（约 568pt），用户判定太高太大。
        ///
        /// 同日第五度校准（「可接受滚动条、优先原生组件，但大小高度仍要优化」）后再收一档：
        /// 下限的职责只是「短文稿也给一块整写作区」，而卡里的固定开销（上下内边距 40 +
        /// 分隔线 1 + 页脚带 42 = 83pt）本来就吃掉大半，200pt 的卡只留 117pt 正文区，
        /// 一行 16pt 文稿下面空着约 100pt（≈5 行）。先收到 160pt（正文区 77pt ≈ 4 行）。
        ///
        /// 同日第六度校准（「可接受滚动条，优先使用原生组件，但大小高度等需要优化」）后
        /// 再收一档到 **144pt**：滚动条这一条已经撤回，下限因此不必再按「留出 4 行以拖后
        /// 出现滚动条」来取，只需保证**静止状态看得见 3 行写作区**——
        /// 3 行 × 20pt 行距 + 固定开销 83 = 143，取 4pt 网格 **144**（正文区 61pt）。
        /// 1–2 行文稿因此从 160 收到 144，一行 16pt 文稿下方的空白由 61pt 降到 45pt；
        /// **3 行及以上完全不变**（3 行文稿自己的高度 159 已经越过下限，稿的 3 行示例因此
        /// 仍渲染成 ≈160，与 `figma-kit` 画板一致），上限 360 也不动。
        /// 下限之上仍由正文高度决定（每长一行卡长一行），到上限为止，再长交给原生
        /// `TextEditor` 滚动条（不隐藏、不改滚动行为）。
        /// 若还要更小或更大，改这一个值即可（REDESIGN-SPEC §11.6 第三十二、三十八轮）。
        public static let creatorComposerMinimumHeight: CGFloat = 144
        /// 输入区的舒适上限。文稿再长也不把控制条挤出首屏，超出部分交给原生滚动条。
        public static let creatorComposerMaximumHeight: CGFloat = 360
        /// 输入卡页脚（元信息行：字数 / 清空 / 保存门禁）的高度带。4x 帧实测：
        /// `▸ 配音台.png` 里分隔线在 660.5pt、卡底 703.75pt，这一行是 **42.5pt** 高的
        /// 固定带（与 `compactDividerHeight` 同值），正文与字数行都在这条带里居中。
        /// 应用此前只给上下 4pt 内边距（≈21pt 带），页脚在整卡里比稿紧一档。
        /// 音色创作的整卡高度是「稿字段 130 + 提示行 + 元信息行」推出来的，那一行取
        /// `Control.compactHeight`（28），整卡仍是 160（REDESIGN-SPEC §11.6 第十九轮）。
        public static let composerMetaRowHeight: CGFloat = 42
        public static let creatorReferenceMinimumHeight: CGFloat = 72
        /// 音色库详情面板里的**试听文案输入槽**是应用自有入口（稿上没有，§11.6
        /// 第四十五轮 ⑤），字数是 `SpeechRailCreatorLimits.speechTextMaximumLength`
        /// = 4096，单行放不下：单行字段在长文案下会按内容撑宽，把 360pt 的详情列
        /// 推向它的 440pt 上限（离屏实测：默认 41 字时槽宽 316pt、塞得下；
        /// 长文案下槽的**理想宽度**继续增长，列宽不再由设计决定而是由用户输入决定）。
        /// 所以它是多行字段：下限两行给写作区，五行封顶，再长由原生编辑器内部滚动
        /// （REDESIGN-SPEC §11.6 第五十七轮）。
        public static let previewTextMinimumLines: Int = 2
        public static let previewTextMaximumLines: Int = 5
        /// 描述框的区间，量测口径是**整张输入区**（正文 + tertiary 引导行 + 字数与保存
        /// 门禁那一行），与配音台同口径。描述框嵌在 `promptCard` 面板里（`chrome: .embedded`，
        /// 内边距由面板给）：4x 帧 `▸ 音色创作.png` 实测正文顶距卡沿 21pt、可写区 102.5pt
        /// （引导行盒底 193.5 → 计数行盒顶 296）；应用离屏量到 20pt / 99.5pt，残差 1pt / 3pt。
        /// 2026-09-16 三度校准前这里只有 67.5pt 可写区（面板与输入区各内缩一次，正文顶
        /// 距卡沿 40pt），比稿窄 35pt（REDESIGN-SPEC §11.6 第二十二轮）。
        public static let creatorVoiceInstructionMinimumHeight: CGFloat = 130
        /// 描述框所在页面是滚动容器（纵向提案无界），实际取这个确定值。≥ 稿的可写区
        /// 口径，又让候选区留在首屏（§7.6.1 密度约束）。
        public static let creatorVoiceInstructionIdealHeight: CGFloat = 160
        /// 描述框的舒适上限（§7.2）；超出由原生滚动条承担，不自量高。
        public static let creatorVoiceInstructionMaximumHeight: CGFloat = 200
        /// 音色胶囊**标签内容**的最小宽度。稿 `voiceCapsule` 是内容自撑的胶囊，样本名字下
        /// 实测总宽 160pt（帧 278.5 → 438.5，内容 padX 10）；系统次按钮自己带左右各约
        /// 13pt 内边距（本机离屏实测：标签 180 → 总宽 206.5），所以这里取
        /// 160 − 26.5 ≈ 134，渲染出来才等于稿上的 160（REDESIGN-SPEC §11.6 第二十八轮）。
        /// 名字更长时胶囊仍随内容变宽，这个值只是稳定下限。
        public static let creatorVoicePickerWidth: CGFloat = 134
        public static let creatorVoiceNameWidth: CGFloat = 220
        public static let creatorVoiceNameMinimumWidth: CGFloat = 160
        public static let creatorVoiceNameMaximumWidth: CGFloat = 260
        public static let creatorVoiceControlWidth: CGFloat = 240
        /// 稿 `speedRow/slider` 的轨道宽度：4x 帧实测 132pt（thumb 14、轨道 4）。
        /// 定宽而不是弹性：弹性会让滑块吃掉整行，控制条就读不出稿上「左侧一组控件 +
        /// 右侧主动作」的构图（REDESIGN-SPEC §11.6 第二十八轮）。
        public static let creatorSpeedSliderWidth: CGFloat = 132
        /// 当前语速取值的定宽槽（`1.0x`），避免数字位数变化时整行左右跳。
        ///
        /// 4x 帧实测：稿的 `speedRow/value` 就是这串文字的**自然宽度**——字串
        /// x 598.75–624.25（25.5pt），下一段（分段控件）因此落在 x 632.25。
        /// 应用此前取 32，整组比稿宽 6.5pt（REDESIGN-SPEC §11.6 第五十二轮）。
        /// 取值域 0.5–2.0 下这串永远是 `N.Nx`，定宽只是兜底，不需要额外余量。
        public static let creatorSpeedValueWidth: CGFloat = 26
        public static let creatorEditorMinimumWidth: CGFloat = 520
        public static let creatorEditorMinimumHeight: CGFloat = 470
        public static let creatorEditorCloneMinimumHeight: CGFloat = 320
        public static let creatorListRowMinimumHeight: CGFloat = 72
        public static let emptyStateMinimumHeight: CGFloat = 240
        public static let modelEmptyStateMinimumHeight: CGFloat = 180
        public static let modelArtifactEmptyStateMinimumHeight: CGFloat = 130
        public static let modelFactMinimumWidth: CGFloat = 100
        public static let modelVariantWidth: CGFloat = 120
        /// 档位卡的规格行：标签列固定，取值右对齐（Figma `Profile Card` 的 76pt）。
        public static let modelProfileSpecLabelWidth: CGFloat = 76
        /// 服务状态能力矩阵：名称列与状态胶囊列各占固定宽度，说明列吸收余量
        /// （Figma `caps` 的 250 / 96）。
        public static let serviceCapabilityNameWidth: CGFloat = 250
        public static let serviceCapabilityPillWidth: CGFloat = 96
        /// 服务状态运行信息：标签列固定，取值右对齐（Figma `infoRow` 的 120）。
        public static let serviceRuntimeLabelWidth: CGFloat = 120
        public static let diagnosticsEmptyListMinimumHeight: CGFloat = 180
        public static let diagnosticsEmptyDetailMinimumHeight: CGFloat = 300
        public static let monitoringEmptyMinimumHeight: CGFloat = 220
        public static let monitoringChartHeight: CGFloat = 240
        public static let compactDividerHeight: CGFloat = 42
        public static let controlMenuWidth: CGFloat = 288

        // MARK: 会话（语音助手 / 会议助手 / 实时字幕）
        //
        // 这几个数与稿是一一对应的单点声明（`UX-UI-SPEC` §3.3 / §3.4 的对照表）：
        // 目录列 = 280，与 `modelProfileListWidth` 是**同一个数、同一个角色**，所以这里
        // 引用它而不是再写一个 280；列表内宽与行内宽由它推导；空态取稿的 320 / pad 32 / 上限 460。
        // 改这里的值要同时改 `figma-kit/main.js` 的 `LAYOUT`——两侧各只有一处声明，值必须相同。

        /// 目录列：记录库 / 助手记录 / 文档目录列 / 模型配置列表共用一个数。
        public static let sessionListWidth: CGFloat = modelProfileListWidth
        /// 列表卡片的内边距（稿 `LAYOUT.listPadX` = 16）。
        public static let sessionListPadding: CGFloat = Spacing.md
        /// 列表内宽 = 列宽 − 2 × 内边距（稿 `LAYOUT.listInnerW` = 248）。
        public static var sessionListInnerWidth: CGFloat { sessionListWidth - 2 * sessionListPadding }
        /// 列表行内文字两侧的留白（稿 `LAYOUT.listRowInset` = 10）。
        public static let sessionListRowInset: CGFloat = 10
        /// 行内宽 = 列表内宽 − 2 × 行内留白（稿 `LAYOUT.listRowInnerW` = 228）。
        public static var sessionListRowInnerWidth: CGFloat { sessionListInnerWidth - 2 * sessionListRowInset }
        /// 空态图标边长（稿 §12 第 5 项：三页与 J0 统一到 28）。
        public static let sessionEmptyIconSize: CGFloat = 28
        /// 页面级空态正文的折行上限（稿 `LAYOUT.emptyBodyMaxW` = 460）。
        public static let sessionEmptyBodyMaximumWidth: CGFloat = 460
        /// 详情列：与 `inspectorColumnWidth` 是同一个数（D7 裁决 360）。
        public static let sessionInspectorWidth: CGFloat = inspectorColumnWidth
        /// 转录行里的说话人列与时间码列；两者都是固定列，正文吃剩余宽度。
        public static let sessionSpeakerColumnWidth: CGFloat = 96
        public static let sessionTimecodeColumnWidth: CGFloat = 56
        // `纪要 / 转录` 分段控件**不定宽**：稿里的 `segmented()` 是按内容排的
        // （每格 padX 9 + 标签），系统分段控件同样按内容定宽，两段都是两个字也不会跳。
        // 实现里曾经钉过 160，那是稿上没有的数（稿画出来是 90），所以撤掉。
        /// 内心 OS 抽屉展开后的高度上限。**再高就会把转录挤出视野**，
        /// 而那正好与"边听边记"的用法相反（`SESSIONS-SPEC` §14.2 的形态那一行）。
        public static let innerOSDrawerExpandedHeight: CGFloat = 220
        /// 抽屉展开后左栏（问答历史 + 输入）的宽度。右栏吃剩余宽度。
        public static let innerOSHistoryColumnWidth: CGFloat = 260

        // MARK: 字幕带（窗口级浮层，不走卡片几何）
        //
        // 这一组数与稿的 `captionBandFrame`（`figma-kit/main.js` 3958）一一对应。**浮层不用
        // 卡片几何**（`Corner.container` / `CardSurface` 那一套）：它贴在屏幕上是薄片，
        // 不是窗口里的一张卡——用卡片圆角与卡片阴影画，评审时就会被当成普通卡片
        // （`UX-UI-SPEC` §2 第 8 行、`SESSIONS-SPEC` §6.3.1）。改这里的值要同时改稿那一处。

        /// 默认宽度；用户可拖到 `captionBandMinimumWidth`…`captionBandMaximumWidth`。
        public static let captionBandDefaultWidth: CGFloat = 760
        public static let captionBandMinimumWidth: CGFloat = 420
        public static let captionBandMaximumWidth: CGFloat = 1_200
        /// 默认位置：主屏底部居中，距屏幕底 96pt（避开 Dock 与常见视频控制条）。
        public static let captionBandBottomInset: CGFloat = 96
        /// 高度按内容撑，下限 2 行、上限 4 行（再多的行走回看）。
        // 行数是**视觉行**（折行算两行），不是逻辑句数：一句长话在带子里占几行，
        // 高度就得留几行，否则最后半句会被窗口切掉。见 `CaptionBandMetrics`。
        public static let captionBandMinimumLineCount: Int = 2
        public static let captionBandMaximumLineCount: Int = 4
        /// 受阻行右侧要给动作按钮留出的宽度；算说明文字能折几行时先扣掉它。
        public static let captionBandBlockedActionsReserve: CGFloat = 240
        public static let captionBandCornerRadius: CGFloat = 12
        public static let captionBandPaddingV: CGFloat = 10
        /// 工具条 / 字幕行 / 页脚之间的间隙（稿 `gap: 4`）。
        public static let captionBandSpacing: CGFloat = 4
        public static let captionLinePaddingH: CGFloat = 16
        public static let captionLinePaddingV: CGFloat = 8
        public static let captionBandToolbarCornerRadius: CGFloat = 8
        /// 工具条内部的元素间距（稿 `hoverToolbar` 的 `gap: 6`）。
        public static let captionBandToolbarSpacing: CGFloat = 6
        public static let captionBandToolbarPaddingH: CGFloat = 10
        public static let captionBandToolbarPaddingV: CGFloat = 5
        public static let captionBandIconButtonSize: CGFloat = 26
        public static let captionBandTagPaddingH: CGFloat = 8
        public static let captionBandTagPaddingV: CGFloat = 3
        public static let captionBandFootPaddingH: CGFloat = 16
        public static let captionBandFootPaddingV: CGFloat = 4
        /// 电平柱：稿 `levelBars(foot, ratio, 14, 13)` 是 **14 根**、中间高两端低、
        /// 每根 3pt 宽、间距 3pt（组宽约 81pt）。**14 是根数，不是组宽**——上一版
        /// 把它当成组宽再除以 4，画出来是 3 根递升的柱子，与稿不是一回事。
        public static let captionBandLevelBarCount: Int = 14
        public static let captionBandLevelBarWidth: CGFloat = 3
        public static let captionBandLevelBarSpacing: CGFloat = 3
        public static let captionBandLevelBarHeight: CGFloat = 13
        public static let captionBandLevelBarCornerRadius: CGFloat = 1.5
        // Source-compatibility alias for the menu bar popover surface.
        public static let controlMenuMinimumWidth: CGFloat = controlMenuWidth
        /// 设置窗口尺寸，取自稿 `05 Menu & Settings`：窗口 **640** 宽（行卡 604 = 640 − 2×18，
        /// 应用的 `Form` 内边距 16 时行卡 608，残差 4）。高度按**三页里最高的一页**锁定，
        /// 切页签时窗口不跳——稿也是这样把三个窗口拉平的（`buildMenuAndSettings`）。
        /// 2026-09-16 离屏实测（`NSHostingView` + 探针只加初始 selection，不开窗口）：
        /// 通用页自然高 319、创作页更矮、服务页 **454**（含系统 TabView 的 33pt 页签条），
        /// 所以 360 → 454；宽度此前是 560，比稿窄 80pt（REDESIGN-SPEC §11.6 第三十三轮）。
        public static let settingsWindowMinimumWidth: CGFloat = 640
        public static let settingsWindowMinimumHeight: CGFloat = 454
        public static let diagnosticsSummaryHeight: CGFloat = 84
        public static let diagnosticsListWidth: CGFloat = 320
        public static let diagnosticsDetailMinimumWidth: CGFloat = 460
        public static let diagnosticsRowHeight: CGFloat = 44
        public static let diagnosticsBodyMinimumHeight: CGFloat = 360
        public static let monitoringCapabilityMinimumWidth: CGFloat = 280
        public static let monitoringCapabilityIdealWidth: CGFloat = 320
        public static let monitoringChartMinimumWidth: CGFloat = 320
        public static let monitoringCapabilityRowHeight: CGFloat = 58
        /// 运行监控「运行组件」表的第一列宽度。稿 `workers` 的列定义就是
        /// `COLS = [380]`（第一列定宽、第二列吸收余量），所以这里也定宽而不是按内容取宽：
        /// 组件名长短不一（「语音识别」/「实时语音」/「语音合成」），按内容取宽会让第二列
        /// 的起点随数据左右跳。
        public static let monitoringWorkerNameColumnWidth: CGFloat = 380
        /// 累计统计表两个数值列的定宽。列头与取值都右对齐，位数变化时列不抖
        /// （表体由应用自己画，不再由系统 `Table` 分配列宽，见 §11.6 第六十八轮）。
        public static let monitoringSampleColumnWidth: CGFloat = 84
        public static let monitoringMetricValueColumnWidth: CGFloat = 110
        public static let monitoringStatusColumnWidth: CGFloat = 64
        public static let metricMinimumWidth: CGFloat = 112
        public static let metricColumnCount: Int = 4
    }

    /// Native macOS menus stay compact; custom menu-bar rows use the same
    /// geometry so every action has a predictable target and rhythm.
    public enum Menu {
        public static let contentWidth: CGFloat = Layout.controlMenuWidth
        public static let contentPadding: CGFloat = Spacing.md
        public static let sectionSpacing: CGFloat = Spacing.xs
        /// 菜单行的下限高度。稿（`05 Menu & Settings` 的 `menuRow`）是 **26pt**，
        /// 「菜单是被扫读的，不是逐个点过去的」，脚本注释也是这个口径；系统菜单项本身
        /// 约 22pt。应用此前借用 `Interaction.minimumHitTarget`(44)，那会让菜单栏面板和
        /// 每个页面的工具栏动作菜单都变成两倍高的列表行——菜单项的整行本来就是可点区域，
        /// 命中区不会因为这一改动变小（REDESIGN-SPEC §11.6 第三十三轮）。
        /// 只用 `minHeight`，字号放大时行仍能长高（§9）。
        public static let rowHeight: CGFloat = 26
        // 页面头部菜单触发器的尺寸不在这一档：它是工具栏控件，几何归
        // `Toolbar.Action`；`Menu` 只管菜单面板自身（菜单栏面板、菜单行）。
        /// Figma `menuBarStrip`：状态项内图标、文字与状态点之间的间距。
        public static let menuBarItemSpacing: CGFloat = 6
        /// Figma `menuBarStrip`：操作进行中的琥珀色状态点直径。
        public static let menuBarStatusDotSize: CGFloat = 6
    }

    /// List geometry is shared by sidebar navigation and custom content lists.
    /// The rows may grow vertically for explanatory copy, but their baseline and
    /// insets never change between pages.
    public enum List {
        public static let rowHeight: CGFloat = Interaction.minimumHitTarget
        /// 侧栏导航行的高度下限：稿的 `navItemRow` 是 **220 × 30**
        /// （`layout: HORIZONTAL, gap: 8, align: CENTER, padX: 8, radius: 7`，
        /// 图标 16 + 标签 `Body`，选中行填 `surface/railTint`），行与行之间是
        /// `group` 的 `gap: 1`，所以**行距 31**；稿侧栏自己 `padX 10 / padY 12`，
        /// 组标题行是 `padX 8 / padY 2` + `Caption / Medium`。
        ///
        /// 应用此前沿用 `List.rowHeight`(44) 再加 4 + 4 的行内边距，真实行距 **52**
        /// （第四十三轮用带真实窗口的离屏宿主实测 NSTableView 行矩形）。macOS 侧栏
        /// （Finder / 邮件 / 系统设置）本来就是 28–32 这一档，30 也仍在 macOS 指针
        /// 目标的 24pt 下限之上；这一档是**按稿**的例外，不再套 `Interaction.minimumHitTarget`。
        ///
        /// 同一轮的实测边界：`.listStyle(.sidebar)` 的行矩形另有**系统下限 32**
        /// （把这个值临时改成 20 再渲染，行矩形仍是 32），所以真实行距是 **32**、
        /// 与稿的 31 差 1pt——差的这 1pt 是系统给的，不是这个 token 能决定的，
        /// 记在案、不再为它换掉系统侧栏行。
        public static let sidebarRowHeight: CGFloat = 30
        /// 页面内列表行（音色库 / 我的作品 / 诊断）的行框高度下限。
        ///
        /// 稿 `row` 是 `padY 12` + 两行内容 + `padY 12`。内容差在**行盒**上：Figma 的行高百分比
        /// 是 `Body/Medium` 13@150% = 19.5、`Callout` 12@145% = 17.4（`info` 的 `gap: 2`），
        /// 系统文本样式的行盒是 16 + 15，所以应用的内容盒只有 16 + 4 + 15 = 35，比稿矮 3.9。
        ///
        /// 4x 帧实测（`/tmp/sr-dub/rowpitch`，扫分隔线 + 选中行填充的上下沿）：
        /// 三页行距都是 **64.00** = 行框 **63.00** + 1pt hairline（`我的作品` y=215.25/279.25…、
        /// `音色库` y=226.25/290.25…、`诊断` y=177.25/241.25…）。所以行框钉到 63：
        /// 声明内边距仍是稿的 12，多出来的 4pt 由行框补，内容竖直居中——视觉上等于 padY 14。
        /// 行内两行文字的墨迹间距应用是 7.9、稿是 9.0（Figma 的行盒更松），这一档差 1.1pt，
        /// 不再为了它去改 `Spacing.micro`（REDESIGN-SPEC §11.6 第三十七轮）。
        /// 2026-09-16 第四十三轮把这一档从 63 抬到 **64**。第三十七轮量的是**帧**：帧上
        /// 「行框 63 + 它下面独立的 1pt hairline」= 行距 64。但应用这里给的是**系统 `List` 的行矩形**，
        /// 系统那条分隔线画在行矩形**内部**——所以 63 的矩形只剩 62 的内容区、行距也只有 63。
        /// 第四十三轮给探针加了一个**真实但从不显示、从不激活**的 `NSWindow` 宿主
        /// （`/tmp/sr-dub` 的 `--window`，只设 `contentView`，不 order / 不 makeKey / 不 activate），
        /// `List` 的行终于离屏可见，实测：改前 `rect(ofRow:)` 63.0、分隔线间距 63.0；
        /// 改后 64.0 / 64.0，内容区（两条分隔线之间）**63.0**——与帧逐位相同，
        /// 行内墨迹也落在「上 16.5 / 下 15.0」（帧 15.75 / 15.0）。
        public static let pageRowMinimumHeight: CGFloat = 64
        public static let compactRowHeight: CGFloat = 42
        public static let tallRowHeight: CGFloat = 58
        public static let rowSpacing: CGFloat = Spacing.xs
        public static let sectionSpacing: CGFloat = Spacing.md
        public static let contentHorizontalPadding: CGFloat = Spacing.lg
        public static let contentVerticalPadding: CGFloat = Spacing.md
        public static let rowContentPadding: CGFloat = Spacing.sm
        public static let rowVerticalPadding: CGFloat = Spacing.xs
        public static let rowHorizontalPadding: CGFloat = Spacing.xs
        public static let rowIconFrame: CGFloat = Icon.navigationFrame
        public static let numericValueMinimumWidth: CGFloat = 84
        public static let numericValueMaximumWidth: CGFloat = 110
        public static let descriptionPreviewMaximumCharacters: Int = 180
        public static let dividerInset: CGFloat = Spacing.lg
        public static let disclosureContentInset: CGFloat = Spacing.lg
    }

    /// Developer-facing metadata is deliberately denser than page content. Its
    /// width is a compressible range (`Layout.inspector*Width`) so a narrow
    /// window shrinks this panel instead of displacing page content or pushing
    /// the navigation column.
    public enum Inspector {
        public static let contentPadding: CGFloat = Spacing.md
        public static let sectionSpacing: CGFloat = Spacing.md
        public static let rowSpacing: CGFloat = Spacing.sm
        public static let labelValueSpacing: CGFloat = Spacing.micro
        public static let rowVerticalPadding: CGFloat = Spacing.xs
        public static let titleMaximumLines: Int = 1
        public static let valueMaximumLines: Int = 3
        public static let bodyMaximumLines: Int = 4
        public static let actionColumnMinimumWidth: CGFloat = 120
        public static let actionGridSpacing: CGFloat = Spacing.sm
        /// Inspectors keep one label column so values line up and read as data
        /// (REDESIGN-SPEC §7.3).
        public static let labelColumnWidth: CGFloat = 92
        /// 音色库 Inspector 的试听行：稿是 `previewWrap`（`padX 16 / padY 14`）里嵌一个
        /// `preview` 面板 —— `gap 10 / padX 12 / padY 10 / radius 10 / fill surface/panel`，
        /// 面板里是 `iconButton(preview, "play", 28)` + 居中波形（`main.js` 1594–1603）。
        ///
        /// 4x 帧 `▸ 音色库.png` 逐像素实测：填充带 **y 276.0–326.0 = 50.0**
        /// （= 波形 30 + 上下各 10），描边 1pt 画在填充**外**（275.0–276.0 / 326.0–327.0，
        /// 外框合计 **52.0**）、色 `#DCDCE0`（= 稿的 `border/separator`），
        /// 填充色 `#F5F5F7`（= 稿的 `surface/panel`，应用按 §5.4 的映射用系统
        /// `controlBackgroundColor`）。面板左右沿 x 1138.5–1405.5 = 267 = 稿的
        /// Inspector 300 − 两侧 `padX 16`（应用侧栏宽 360，面板按 360 − 2 × 16）。
        public static let previewInsetX: CGFloat = 12
        public static let previewInsetY: CGFloat = 10
        public static let previewGap: CGFloat = 10
        public static let previewRadius: CGFloat = 10
        /// 稿的 `previewWrap` 上下留白（`padY 14`）。左右沿用 `contentPadding`（16），
        /// 与稿的 `padX 16` 同值。
        public static let previewWrapInsetY: CGFloat = 14
        /// 稿的 Inspector 动作区 `frame("actions", { padX: 16, padY: 14 })`（`main.js:1626`）。
        /// 它上面有一条整宽 hairline，动作区被压在 Inspector 的最底部（4x 帧
        /// `▸ 音色库.png` 实测该 hairline 在 y 820.0–821.0，窗口下沿 900）。
        public static let actionPadding: CGFloat = 14
    }

    public enum Control {
        public static let compactHeight: CGFloat = 28
        public static let regularHeight: CGFloat = 34
        public static let prominentHeight: CGFloat = 40

        public static let minimumHitTarget: CGFloat = Interaction.minimumHitTarget
        public static let iconButtonSize: CGFloat = 28
        public static let statusIconSize: CGFloat = 17
        /// 稿的 `conclusion` 面板图标（脚本 `icon(conclusion, "circle-check", 26)`；
        /// 4x 帧实测该图标 ink 宽 21.2pt ≈ 26pt 字号的 SF Symbol 墨迹）。
        public static let statusBannerIconSize: CGFloat = 26
        public static let sidebarRowHeight: CGFloat = Interaction.minimumHitTarget
        public static let sidebarIconFrame: CGFloat = 20
        /// 侧栏底部状态区上方那条 hairline 的左右内缩。稿的 `sidebarStatusWrap`
        /// 画的是 **220 × 1** 的分隔线（`main.js`：`rect(statusWrap, "hairline", 220, 1, …)`），
        /// 而稿的侧栏 `padX` 是 10（`frame("sidebar", { …, padX: 10 })`），所以这条线在
        /// 240 宽的侧栏里左右各缩 10、与上方侧栏行的边缘对齐；4x 帧实测墨迹 x 10.0–230.0
        /// 与之相符（REDESIGN-SPEC §11.6 第四十轮）。
        public static let sidebarHairlineInset: CGFloat = 10
        /// 页面列表行行首状态字形的**图标框**。稿是 `icon(row, item.icon, 16)`
        /// （`main.js` 2009 的诊断检查行、`navItemRow` 的侧栏项同为 16 框）：
        /// 框决定文字列从哪开始，墨迹由 `Icon.rowStatusSize` 决定，两者是两件事
        /// （REDESIGN-SPEC §11.6 第三十九 / 四十一轮）。
        public static let diagnosticIconFrame: CGFloat = 16
        public static let purposeIndicatorWidth: CGFloat = 3
        public static let purposeIndicatorHeight: CGFloat = 14
    }

    /// Figma 的波形原语 `waveform(parent, bars, colorVar, gap)`（`main.js:345`）：
    /// 每根是 **2pt 宽、圆角 1、按给定高度垂直居中**的矩形，整块宽 `n × 2 + (n−1) × gap`、
    /// 高 `max(bars)`。稿的三处波形只在「根数 / 高度序列 / 间隙」上不同，所以这三个数
    /// 就是全部参数，宽高由它们推出来——应用此前是一个固定的「9 根 / 3+3 / 72 × 20」
    /// 组件顶三处，宽度比稿窄 26–36pt、高度矮 7–16pt，三处还都一律左对齐
    /// （REDESIGN-SPEC §11.6 第四十二轮）。
    public enum Waveform {
        public static let barWidth: CGFloat = 2
        public static let barRadius: CGFloat = 1

        /// 生成结果条行首（`main.js:1372`）：12 根、间隙 2 → 46 × 17；
        /// 4x 帧 `▸ 配音台.png` 实测墨迹 46.0 × 17.0、周期 4.0。
        public static let resultBar = Pattern(
            heights: [5, 11, 16, 8, 14, 6, 12, 17, 9, 5, 13, 7],
            gap: 2
        )

        /// 音色创作候选卡的波形区（`main.js:1425`，整块**居中**）：
        /// 18 根、间隙 3 → 87 × 36；4x 帧 `▸ 音色创作.png` 实测 87.0 × 36.0、周期 5.0。
        public static let candidateTile = Pattern(
            heights: [10, 22, 34, 16, 28, 12, 24, 36, 14, 20, 10, 26, 18, 30, 12, 22, 16, 28],
            gap: 3
        )

        /// 音色库试听行的波形（`main.js:1601`，整块**居中**）：
        /// 16 根、间隙 3 → 77 × 30；4x 帧 `▸ 音色库.png` 实测 77.0 × 30.0。
        public static let libraryPreview = Pattern(
            heights: [8, 16, 26, 12, 22, 9, 18, 30, 11, 15, 8, 20, 13, 24, 10, 17],
            gap: 3
        )

        /// **真实包络**（REDESIGN-SPEC §11.6 第五十七轮）。2026-09-16 用户指出
        /// 「播放音波效果是假的」——此前三处波形画的都是稿上的**固定高度数组**，
        /// 播放时只叠一层整块透明度呼吸：它知道「在播」，不知道「在响什么」，
        /// 也不知道「播到哪了」。现在条高来自这段音频自己的幅度包络，
        /// `Pattern.heights` 只决定**条数与排布**（宽度 / 间隙 / 峰值高度）；
        /// 播放中未播到的部分降到 `remainingOpacity`。
        ///
        /// 缓存分辨率与显示条数解耦：模型按 `envelopeBuckets` 存一份，视图按自己
        /// 的 `Pattern` 重采样（同一段包络因此能给 12 / 16 / 18 根三种排布用）。
        public static let envelopeBuckets: Int = 32
        /// 静音窗口的可见下限：2pt 宽、1pt 圆角的条要留下至少 3pt 才有墨迹，
        /// 否则停顿处会出现「断掉的空档」而不是一条低条。
        public static let envelopeMinimumHeight: CGFloat = 3
        /// 播放中**未播到**的部分（真实进度的另一侧）。
        public static let remainingOpacity: Double = 0.35
        /// 播放进度的采样间隔（`AVAudioPlayer.currentTime` 的读取频率，20Hz）。
        public static let progressInterval: TimeInterval = 0.05

        public struct Pattern: Sendable {
            public let heights: [CGFloat]
            public let gap: CGFloat

            public var width: CGFloat {
                CGFloat(heights.count) * barWidth + CGFloat(max(0, heights.count - 1)) * gap
            }

            public var height: CGFloat {
                heights.max() ?? 0
            }
        }
    }

    /// 字幕带的行为常量。几何在 `Layout`、字体在 `Typography`，这里只放"它怎么表现"：
    /// 位置按屏记忆的键、跟随的判定阈值。**没有主题相关的取值**——浮层材质由系统给。
    public enum CaptionBand {
        /// 位置与宽度按屏记忆（`SESSIONS-SPEC` §6.3.1「位置记忆每屏一套」）。
        /// 追加屏幕的稳定标识（`CGDirectDisplayID` 派生的 UUID），换显示器不会跑到别处。
        public static let positionDefaultsPrefix = "speechrail.captionBand.frame."
        /// 字号档。它是用户设置，跨会话记住（稿上「字号」是浮层工具条里的一档）。
        public static let fontSizeDefaultsKey = "speechrail.captionBand.fontSize"
        /// 「钉住位置」：钉住之后窗口不再跟着拖动走（工具条上那一颗要真的生效）。
        public static let pinnedDefaultsKey = "speechrail.captionBand.pinned"
        /// 「还贴着底」的判定：内容底部与可视底部的距离小于这个值就算在跟随。
        /// 给一点余量是因为滚轮的惯性会把偏移留在几像素上，按 0 判定会一直弹「回到最新」。
        public static let followThreshold: CGFloat = 24
        /// 浮层不低于这个高度：2 行 + 页脚 + 上下内边距。内容只有一行时也要撑住，
        /// 否则带子会在首句出现前先"跳"一下高度。
        public static let minimumHeight: CGFloat = 96
    }

    /// Figma `Voice Chip` 组件的几何（脚本 `componentSet("Voice Chip", …)` 是
    /// `gap 4 / padX 10 / padY 3 / radius 999`；4x 帧 `▸ 音色创作.png` 实测 chip rect
    /// 高 22、宽 82、彼此间距 7）。应用此前是 `padX 12 / padY 4 / gap 2` 且标签用
    /// `Caption`(10)：渲染出来比稿窄一档、又比稿矮一档，且底色要另见 `Surface.attentionTint`
    /// （REDESIGN-SPEC §11.6 第三十四轮）。
    public enum Chip {
        /// 稿的 `plus` 是 **13pt 图标框**（`icon(chip, "plus", 13)`，lucide 24 视框），
        /// 4x 帧上墨迹只有 8.66pt（7.58 线长 + 1.08 描边）。SF Symbol `plus` 的墨迹
        /// 约为字号的 0.85，所以字号取 10 才落在稿的 8.66pt 上，再把**布局框**钉回 13pt，
        /// 胶囊总宽才等于稿的 82（只改字号会让胶囊窄约 3pt）。
        public static let iconSize: CGFloat = 10
        public static let iconBox: CGFloat = 13
        /// 加号与标签之间（稿 `gap: 4`）。
        public static let labelSpacing: CGFloat = 4
        public static let insetX: CGFloat = 10
        public static let insetY: CGFloat = 3
        /// 帧上 chip rect 344 → 366，即 22pt。
        public static let height: CGFloat = 22
        /// 同一排 chip 之间（稿 `chips` 容器 `gap: 6`；帧实测 363 → 370 = 7）。
        public static let spacing: CGFloat = 6
        public static let borderWidth: CGFloat = 1
    }

    /// Settings keeps the native grouped Form semantics, while these values
    /// align its explanatory copy and control rhythm with the workspaces.
    public enum Settings {
        public static let secondaryTextMaximumLines: Int = 3
        public static let contentSpacing: CGFloat = Spacing.xs
        /// 设置行里标题与副标题之间（稿 `05 Menu & Settings` 的 `controlRow/labels`，`gap: 3`）。
        public static let rowLabelSpacing: CGFloat = 3
    }

    /// The diagnostic summary stays compact in the normal case but may grow
    /// when the service returns a longer user-facing explanation.
    public enum Diagnostics {
        public static let summaryMessageMaximumLines: Int = 2
    }

    /// 音色克隆（录音 → 回听 → 核对 → 注册）的几何与时长边界。
    ///
    /// 时长边界有一半不归应用管：服务端 `POST /v1/voices/clone` 会把参考音频转码后按
    /// 2.0–45.0 秒校验，所以 `maximumDuration` 必须与那份契约同值，应用只负责在
    /// 越过时**提前**告诉用户，而不是让请求失败后再解释（REDESIGN-SPEC §13.2）。
    public enum VoiceClone {
        /// 提词稿正文：朗读时眼睛只看这一段，稿上是 `Title / Page`（20pt Semi Bold），
        /// 也就是**页标题那一档**——它是这一页唯一的大字对象。
        ///
        /// 2026-09-16 用户复核「字体应和高保真一样，要大一些」：此前取 `.title3`
        /// （macOS 15pt，比稿小 5pt），是这一页唯一把稿的 `Title / Page` 映射丢了的地方。
        /// 现在按本文件对 `Title / Page` 的既有口径取 `.title`（22pt，+2pt 残差），
        /// 与 `display` / `windowTitle` / `diagnosticsSummary` 同一档。
        public static let scriptMaximumLines: Int = 3
        /// 提词稿正文槽的**固定外框高度**：五个选项（四段官方稿 + 自己写一段）共用同一个框，
        /// 换稿时卡片不再跟着稿子的行数跳。
        ///
        /// 取值 = 3 行 `.title`（离屏实测 3 行共 78pt）+ 上下各 16pt 内边距 = 110，取 4pt 网格
        /// 的 112（内框 80pt，还剩 2pt 余量给行高误差）。留到 3 行而不是稿上的 2 行，是因为
        /// 官方稿最长 55 字（`clone_prompts.json`），在 1120pt 最小窗口下会占到第二行的尾巴；
        /// 给到三行，任何窗口宽度下正文都读得完整，不会出现「为了高度统一而把稿子截断」。
        ///
        /// 这个高度套在**两种形态之外**（`VoiceCloneView.scriptBody` 那一层 `.frame(height:)`），
        /// 只读稿与自写编辑器因此不可能再各算各的（2026-09-16 第二次复核）。
        public static let scriptBodyHeight: CGFloat = 112
        /// 原生 `TextEditor` 背后的 `PlatformTextView` 自带的行片段内边距，离屏实测为 5pt
        /// （同一份实测里 `textContainerInset` 是 `(0, 0)`，即正文原点就等于外层内边距）。
        ///
        /// 提词稿正文槽要求「自己写一段」的正文左沿与只读稿同一条竖线，所以左内边距要减掉它。
        public static let editorLineFragmentPadding: CGFloat = 5
        /// 录制按钮是稿里唯一的实心圆控件（56pt），比系统按钮高两档——它是这一页的动作焦点。
        public static let recordButtonSize: CGFloat = 56
        public static let recordGlyphSize: CGFloat = 20
        /// 录音跑了这么久还没有任何输入信号，就在录制卡里直说「麦克风没收到声音」。
        ///
        /// 2026-09-16 用户反馈「录音时声波不动、没有声音」：实测这一次的根因在系统侧
        /// （`AVAudioRecorder` 拿到的整段样点全是 0，同一时刻 ffmpeg 走 AVCapture 也是全 0），
        /// 但界面上当时只有「电平条一直不亮」这一个提示——用户得自己猜是应用坏了还是麦克风坏了。
        /// 门限取 4 秒：正常朗读 4 秒一定有声音，够短也够稳。
        public static let silenceHintSeconds: TimeInterval = 4
        /// 「有信号」的判定门限（`normalizedLevel` 的 0…1 刻度上约 -50 dBFS）：
        /// 低于它的电平只可能是静音，不是「读得轻」。
        public static let signalFloorLevel: Double = 0.17
        /// 电平表：比波形条（2pt）粗一档，因为它读的是「实时有多响」，不是「一段音频的形状」。
        public static let meterBarWidth: CGFloat = 3
        public static let meterBarRadius: CGFloat = 1.5
        public static let meterBarSpacing: CGFloat = 3
        public static let meterBarCount: Int = 28
        public static let meterHeight: CGFloat = 40
        /// 已过去的那一段电平条占的比例：剩下的刻度留着，读得出「离满还有多远」。
        public static let meterActiveRatio: Double = 0.6
        /// 计时器固定宽，等宽数字换秒时不跳（`TextView` 的行宽约定同 §9）。
        public static let timerWidth: CGFloat = 48
        public static let nameFieldWidth: CGFloat = 360
        /// 本地提示的时长区间（服务端硬边界 2.0–45.0s 见 `Contract.minimumSeconds`）。
        ///
        /// 10 秒起是稿的口径（`▸ 音色克隆` 卡头「建议朗读 10–30 秒；服务接受 2–45 秒。」），
        /// 同时是 `AudioReferenceCheck` 里「时长偏短」的判定线：提示语与判定必须是同一条线，
        /// 否则用户会看到「建议 10 秒起」却对一段 6 秒的录音读到「通过」。
        public static let minimumSeconds: TimeInterval = 10
        public static let maximumSeconds: TimeInterval = 45
        public static let targetSeconds: TimeInterval = 30
        /// 准备麦克风超过这个时长还没就绪，就把「首次启动可能要等几十秒」说出来。
        ///
        /// 首次采集要走一次 CoreAudio 的冷启动（实测最坏一次 36 秒），
        /// 用户在这段时间里需要一个解释和一个退出口，而不是风火轮。
        public static let preparationHintSeconds: TimeInterval = 6
        /// 本地静态检查的窗口长度：一段 45 秒的 48 kHz 单声道录音按 20 ms 一窗统计。
        public static let analysisWindowSeconds: TimeInterval = 0.02
        /// 语音活动判定阈值（相对本段峰值）：低于它算静音窗。
        public static let speechActivityThresholdDBFS: Double = -45
        /// 削波判定：|峰值| ≥ 0.99 的样点占全部样点的比例超过它就提示。
        public static let clippingRatioThreshold: Double = 0.001

        /// 服务端契约里参考音频的硬边界：`min_duration: 2.0` / `max_duration: 45.0`
        /// （`POST /v1/voices/clone` 的转码校验）。应用只做提示，判定权在服务端。
        public enum Contract {
            public static let minimumSeconds: TimeInterval = 2
            public static let maximumSeconds: TimeInterval = 45
            /// `ref_text` 的契约上限（OpenAPI `VoiceCloneRequest.ref_text.maxLength`）。
            public static let referenceTextMaximumLength: Int = 2_000
            /// `name` 的契约上限。
            public static let nameMaximumLength: Int = 32
        }
    }

    /// 开发者文档页：目录列 + 正文列。
    public enum DeveloperDocs {
        public static let topicListWidth: CGFloat = 272
        public static let topicDescriptionMaximumLines: Int = 2
        /// 文档卡的**最小高度**：目录列要一次把八个主题全露出来，否则 `List` 会在列内
        /// 自己滚——用户点到的主题越靠下，列表就把上面的行顶出可视区，读起来像
        /// 「点一下菜单就少了几个」（2026-09-16 装机件反馈）。
        ///
        /// 数字来源：目录列的实测内容高度 = 列内边距 14×2 + 八个主题行 8 × 49
        /// （行框 = padY 9×2 + 标题 16 + gap 2 + 说明 13）= **420**，上取 4pt 网格到 424。
        /// 2026-09-16 带真实窗口的离屏宿主实测：八行都在表格可视区内、行距 49、列宽 248。
        /// 它只是**下限**：窗口够高时卡片仍然吃满页头以下的剩余高度（稿的 `grow(docs)`）。
        public static let cardMinimumHeight: CGFloat = 424
        /// 目录列与主题行的内边距。稿 `topics` 是 `padX 12 / padY 14`，行是
        /// `padX 10 / padY 8 / radius 8`，行与行之间 `gap 2`（`main.js` `screenDeveloperDocs`）。
        ///
        /// 4x 帧实测（`▸ 开发者文档.png`，选中行那条 y=1150px）：底色带宽 **248pt**
        /// ＝ 272 − 12 − 12，左沿距卡左沿 12.25pt、右沿距分隔线 11.25pt，与 padX 12 吻合；
        /// 行距 **49** ＝ padY 8×2 + 标题 16 + gap 2 + 说明 13 + 行距 2。
        public static let topicColumnHorizontalPadding: CGFloat = 12
        public static let topicColumnVerticalPadding: CGFloat = 14
        /// 行的上下内边距。稿是 `padY 8` + 行与行 `gap 2`，但 macOS 没有
        /// `listRowSpacing`（`SwiftUI.View.listRowSpacing` 在 macOS 上明确标记不可用），
        /// 所以把那 2pt 行距拆成两半铺进行里：行框 9+9，底色块再上下各缩 1pt
        /// ——于是**底色块仍是 47 高、相邻两块仍是 2 的间距**，与稿逐项吻合。
        public static let topicRowVerticalPadding: CGFloat = 9
        public static let topicRowHorizontalPadding: CGFloat = 10
        public static let topicRowCornerRadius: CGFloat = 8
        /// 正文的阅读上限：一行超过这个宽度就该换行，而不是让眼睛横扫整屏。
        public static let contentMaximumWidth: CGFloat = 760
        public static let endpointMethodWidth: CGFloat = 42
        public static let endpointPathWidth: CGFloat = 250
        /// 代码块的最小高度：一段 6–8 行的示例要完整露出来（不靠滚动看示例的结尾）。
        public static let codeBlockMinimumHeight: CGFloat = 120
        public static let codeBlockMaximumHeight: CGFloat = 260
    }

    /// 窗口头部（工具栏）的**唯一几何来源**。
    ///
    /// 头部是一个系统，不是每页各写一遍的装饰：八个页面共享同一套槽位、同一个
    /// 页面身份锁和同一批动作控件尺寸。页面只声明「我是谁、这一页有哪些动作」，
    /// 几何一律从这里取（REDESIGN-SPEC §6.2 / §11.6 第四十九轮）。
    ///
    /// 头部的三条契约：
    /// 1. **身份只有一处**——页面名只在 `Identity` 槽出现，正文不再重复标题；
    /// 2. **动作要么具体、要么图标化**——不要「更多操作」这类通用文字标签常驻；
    /// 3. **状态不进头部**——服务是否就绪由侧边栏底部状态区独家承担（§6.4 / D9）。
    public enum Toolbar {
        // 工具栏自身的高度、槽位之间的间距与窄窗口 overflow 都归系统
        // （macOS 26 unified compact toolbar），这里不声明——声明了也没有调用点，
        // 只会变成「看起来被控制、其实不被使用」的假精度（第四十九轮）。
        //
        /// 页面身份锁：图标 + 页面名，单行、居中、固定槽位、尾截断。
        /// 全应用只有这一处声明「这是哪一页」。
        public enum Identity {
            public static let maximumWidth: CGFloat = 280
            public static let height: CGFloat = 32
            public static let titleMinimumScaleFactor: CGFloat = 0.82
        }

        /// 头部动作控件：工具栏按钮与工具栏菜单触发器共用一档尺寸与字形。
        /// 这一档里没有「文字标签的溢出菜单」——头部动作要么是具体动作，
        /// 要么是图标 + 精确的无障碍标签（REDESIGN-SPEC §6.2）。
        public enum Action {
            public static let controlHeight: CGFloat = Control.compactHeight
            public static let iconOnlyWidth: CGFloat = Control.compactHeight
            public static let horizontalPadding: CGFloat = Spacing.xs
            public static let labelSpacing: CGFloat = Spacing.micro
            /// 字形与图标框：14pt medium、18pt 框，与 macOS 工具栏原生字形同档
            /// （`Icon.rowActionSize` 是**列表行内**动作，两者不共用）。
            public static let glyphSize: CGFloat = 14
            public static let glyphFrame: CGFloat = 18
        }
    }

    /// Component-level button dimensions. The visual glyph may be smaller than the
    /// hit target; the hit target is never smaller than the macOS control baseline.
    public enum Button {
        public static let standardHeight: CGFloat = 34
        public static let prominentHeight: CGFloat = 40
        public static let iconHitTarget: CGFloat = Interaction.minimumHitTarget
        /// 主按钮标签里快捷键提示的不透明度：沿用按钮自己的前景色，降一档表示
        /// 「这是提示，不是按钮文案」，不再另画底色与描边（§11.6 第四十八轮）。
        public static let shortcutOpacity: Double = 0.72
    }

    public enum Icon {
        public static let navigationSize: CGFloat = 15
        public static let navigationFrame: CGFloat = 20
        public static let toolbarSize: CGFloat = 16
        public static let toolbarFrame: CGFloat = 24
        /// 页面列表行行首的**状态字形**（诊断检查项、监控能力行、资源行）的字号。
        ///
        /// 稿的诊断检查行是 `icon(row, item.icon, 16)` —— **16pt 图标框**，不是 16pt 墨迹。
        /// `▸ 诊断.png`（4x）逐像素量到的墨迹是：对勾行 **12.0 × 8.75**、警示三角行
        /// **13.5 × 12.0**。应用此前在这一处用 `.imageScale(.small)`（本机实测墨迹只有
        /// **10.0 × 10.0**，比稿小 20–30%），而同一族的监控能力行用 `.imageScale(.medium)`
        /// 已经是 13.0。用 13 号字复现：`checkmark.circle.fill` 13 × 13、
        /// `exclamationmark.triangle.fill` **13 × 12**（对稿的 13.5 × 12.0 残差 0.5 / 0）。
        /// 因此这一族统一取 13，与正文同号（REDESIGN-SPEC §11.6 第三十九轮）。
        public static let rowStatusSize: CGFloat = 13
        /// 行内**动作**图标按钮的字号。稿的原语是 `iconButton(parent, name, 28)`
        /// （`main.js:640`）：**28 × 28 框、圆角 7、无底色**，里面是 `icon(b, name, 15,
        /// text/secondary)` —— 15 是 Figma 的**图标框**，lucide 字形在其中留白，墨迹更小。
        ///
        /// 4x 帧实测（同一个原语在 `▸ 音色库.png` 列表行 ×3、Inspector 试听行 ×1 与
        /// `▸ 我的作品.png` 行内 ×2 上完全相同）：
        /// `play` 三角 **10.25 × 11.5**、色 **#6E6E73**（= `secondaryLabelColor`）；
        /// `download` **12.5 × 12.5**、色同为 #6E6E73。
        /// 应用此前这一族用 `Typography.statusIcon`（17pt semibold）画 `play.circle.fill`
        /// —— 琥珀实心圆、墨迹 13 × 15，比稿大 30–44%，而稿上根本没有实心圆。
        ///
        /// 本机离屏量 SF Symbol（`/tmp/sr-dub/glyph`）：`play` 13pt semibold =
        /// **10.0 × 11.5 / 42.5pt²**，与帧的 10.25 × 11.5 / 44.4pt² 逐位吻合；
        /// 14pt medium 是 10.5 × 12 / 43.8（次之），13pt regular 只有 9 × 11 / 28.8
        /// （明显偏细）。所以这一族与 `rowStatusSize` 同号 13、同字重 semibold
        /// （REDESIGN-SPEC §11.6 第四十四轮）。
        public static let rowActionSize: CGFloat = 13
    }

    public enum Stroke {
        public static let hairline: CGFloat = 0.5
        public static let standard: CGFloat = 0.75
        public static let strong: CGFloat = 1
    }

    public enum Shadow {
        public static let elevatedRadius: CGFloat = 12
        public static let elevatedYOffset: CGFloat = 4
    }

    /// Corner geometry. The radius is declared once — at the container — and every
    /// surface inside derives its own radius from that container by concentricity,
    /// so nested corners share a common center instead of drifting apart
    /// (REDESIGN-SPEC §5.3). `ConcentricRectangle` has nothing to derive from when
    /// no ancestor provides a container shape — the window content floor is such a
    /// place — and resolves to a square corner there (Apple: "the corner radius the
    /// system calculates may be zero"), so leaf surfaces carry a floor. The two
    /// numbers below are the whole corner vocabulary.
    ///
    /// **控件与表面用两个不同的形状，不是同一个**（第四十八轮）：同心推导的半径
    /// 是「容器半径 − 到容器边的内缩」，内缩 ≥ 12pt 时推导结果 ≤ 0，叶面直接画成
    /// 方角。卡内的输入框内缩 20pt（`Layout.cardInset`），量到的正是 0 —— 输入槽
    /// 因此是方角，与旁边的系统胶囊按钮并排时读起来像两个体系。所以
    /// **表面**（行选中底、卡片、面板）继续用 `nestedShape` 跟随容器（它们贴容器边、
    /// 同心才有意义），**控件**（输入槽、图标框）用 `controlShape` 固定取
    /// `nested`，任何内缩下都不再退化成方角。（当时一起画成方角的键帽已删除，
    /// `⌘⏎` 改为按钮标签内的 `ButtonShortcutHint`。）
    public enum Corner {
        /// 稿 `radius/container`：全应用唯一自声明的容器圆角。
        public static let container: CGFloat = 12
        /// 稿 `radius/control` / `radius/field`：控件圆角（叶面在容器给不出半径时也用它兜底）。
        public static let nested: CGFloat = 8

        /// 容器形状：声明自己的圆角，并把它发布给子层作为同心推导的基准。
        public static var containerShape: RoundedRectangle {
            RoundedRectangle(cornerRadius: container, style: .continuous)
        }

        /// 叶面形状：跟随所在容器同心推导，容器给不出半径时退到 `nested`。
        public static var nestedShape: ConcentricRectangle {
            ConcentricRectangle(corners: .concentric(minimum: .fixed(nested)))
        }

        /// 控件形状：固定 `nested`，不随容器内缩退化（离屏实测：槽的左上空缺面积
        /// 11.0–13.0pt²，与同图的 8pt continuous 参考 13.0pt² / 上沿首个墨迹 +6.0pt
        /// 逐项吻合；12pt continuous 是 29.2pt² / +10.0pt，两者不会混淆 —— §11.6 第五十一轮）。
        public static var controlShape: RoundedRectangle {
            RoundedRectangle(cornerRadius: nested, style: .continuous)
        }
    }

    /// All non-native interactive surfaces use this matrix. Native Button/Menu/
    /// NavigationLink controls retain the system's own equivalent states.
    public enum Interaction {
        public static let minimumHitTarget: CGFloat = 44
        public static let focusRingInset: CGFloat = 1
        public static let hoverFillOpacity: Double = 0.07
        public static let pressedFillOpacity: Double = 0.12
        public static let disabledOpacity: Double = 0.45
        public static let focusLineWidth: CGFloat = 2
    }

    public enum Typography {
        /// 稿的标题只有一档 `Title / Page`（20pt Semi Bold），四个取样点实测 ink 18.25–19.0pt：
        /// 页标题（八页 18.75–19.0）、服务状态结论标题（18.75）、诊断详情标题（18.25）、
        /// 档位卡标题。系统文本样式里没有 20，取最近的 `.title`（22，+2pt 残差），
        /// 保留文本样式以便随系统「更大文字」缩放（REDESIGN-SPEC §5.5 / §11.6 第十八轮）。
        public static let display: Font = .system(.title, weight: .semibold)
        /// 卡片 / 面板级标题。稿上与页标题同档（`Title / Page`），所以取值与 `display` 一致。
        public static let windowTitle: Font = .system(.title, weight: .semibold)
        public static let sectionTitle: Font = .system(.headline, weight: .semibold)
        public static let section = sectionTitle
        public static let body: Font = .body
        /// Figma `Body / Medium`：候选卡槽位名与表格主列等需要中等字重的正文。
        public static let bodyMedium: Font = .body.weight(.medium)
        /// Figma `Callout`：页头副标题、区块说明与结果条时长等 12pt 正文。
        public static let callout: Font = .callout
        public static let secondary: Font = .subheadline
        public static let label: Font = .system(.callout, weight: .medium)
        public static let caption: Font = .caption
        /// 稿的 `Caption / Medium`（10pt Medium）：列头、状态胶囊与字段标签用它
        /// （脚本 `652` 状态胶囊、`1650–1658` 作品列头、`1848` 能力卡列头、`1945` 制品列头）。
        /// 应用此前这些位置一律用 `caption`（10pt Regular），字重比稿轻
        /// （REDESIGN-SPEC §11.6 第二十轮）。
        public static let captionMedium: Font = .system(.caption, weight: .medium)
        /// 字幕正文三档（`SESSIONS-SPEC` §6.3.1）：紧凑 17 / 标准 20 / 大字 26，映射
        /// `.title2` / `.title` / `.largeTitle`。与页标题同一条取舍：系统文本样式里没有 20，
        /// 标准档取 `.title`（22，+2pt 残差）——保留文本样式才随系统「更大文字」缩放，
        /// 这与 `display` 的既有口径一致（REDESIGN-SPEC §11.6 第十八轮）。
        public static let captionBandCompact: Font = .system(.title2, weight: .regular)
        public static let captionBandStandard: Font = .system(.title, weight: .regular)
        public static let captionBandLarge: Font = .system(.largeTitle, weight: .medium)
        public static let technical: Font = .caption2.monospacedDigit()
        /// 取值槽的等宽数字档。稿的取值单元格与 Inspector 取值行都是 `Callout`(12)
        /// （脚本 `kvRow`、制品表 `cell/v`；4x 帧实测取值行的 em 步进 11.75pt ≈ 12pt）。
        /// 应用原先这两个槽用 `technical`（10pt 等宽），比稿小一档；等宽数字是应用自己的
        /// 排版约定（§9 等宽数字），所以保留等宽、只把字号提到 12
        /// （REDESIGN-SPEC §11.6 第二十轮）。应用自有的密集区块（设置里的快捷键清单、
        /// 下载进度里的文件名）仍用 `technical`。
        public static let technicalValue: Font = .system(.callout, weight: .regular).monospacedDigit()
        public static let metricValue: Font = .system(.title3, weight: .semibold).monospacedDigit()
        public static let metric = metricValue
        /// 行内状态 / 空态标题：稿的 `Empty State` 组件口径是 `Heading / Section`（13pt Semi Bold）。
        /// 状态结论面板（`conclusion`）不用这一档，它和页标题同档，见 `display`。
        public static let statusTitle: Font = .system(.headline, weight: .semibold)
        /// 头部页面名（`WorkspaceTitleLockup`）的唯一字号档；页标题不再另设一档，
        /// 正文也不再有页标题（§6.2 / §11.6 第四十九轮）。
        public static let toolbarTitle: Font = .system(.headline, weight: .semibold)
        /// 头部动作控件的字形（页面动作菜单触发器、工具栏图标按钮），
        /// 见 `Toolbar.Action.glyphSize`。
        public static let toolbarActionIcon: Font = .system(
            size: Toolbar.Action.glyphSize,
            weight: .medium
        )
        /// 诊断详情标题：稿上是 `Title / Page`（帧实测 18.25pt ink）。
        public static let diagnosticsSummary: Font = .system(.title, weight: .semibold)
        public static let diagnosticsDetail: Font = .system(.callout, weight: .medium)
        public static let statusIcon: Font = .system(size: Control.statusIconSize, weight: .semibold)
        public static let statusGlyph: Font = .system(.title2, weight: .semibold)
        /// 页面列表行行首的状态字形（见 `Icon.rowStatusSize` 的量测依据）。
        public static let rowStatusIcon: Font = .system(size: Icon.rowStatusSize, weight: .semibold)
        /// 行内动作图标按钮的字形（播放 / 停止、导出、更多操作），见 `Icon.rowActionSize`。
        public static let rowActionIcon: Font = .system(size: Icon.rowActionSize, weight: .semibold)
        /// 提词稿正文（音色克隆）：稿上是 `Title / Page`（20pt）——朗读时眼睛只看这一行，
        /// 它和页标题同档不是排版失误，是「这一段要读出来」的直接结果。
        /// 提词稿正文（音色克隆页唯一的大字对象）。
        ///
        /// 稿上是 `Title / Page`（20pt Semi Bold），与本文件的 `display` / `windowTitle` /
        /// `diagnosticsSummary` 同一档，所以这里也取 `.title` + semibold；
        /// 2026-09-16 用户复核「字体应和高保真一样，要大一些」前它是 `.title3`（15pt Regular）。
        public static let promptScript: Font = .system(.title, weight: .semibold)
        /// 代码块（开发者文档）：稿用 Inter 画示意，生产映射到系统等宽字体——
        /// 代码里对齐的缩进和路径不能靠比例字体碰运气（REDESIGN-SPEC §13.3）。
        public static let code: Font = .system(.callout, design: .monospaced)

        // Source-compatibility aliases for compiled legacy surfaces.
        public static let pageTitle = windowTitle
        public static let panelTitle = sectionTitle
    }

    public enum Color {
        // Labels, separators and focus resolve through AppKit semantic colors so
        // light, dark and Increase Contrast behave for free (§5.4). **中性表面阶梯是
        // 唯一例外**：本机实测 `windowBackgroundColor` / `controlBackgroundColor` /
        // `textBackgroundColor` 在两种外观下都解析成同一个值（浅色都 #FFFFFF、
        // 深色都 #1E1E1E），四级塌成一级 —— 未选中的档位卡在白底上完全没有边界。
        // 因此这三层按稿的取值显式声明（REDESIGN-SPEC §11.6 第五十轮）。
        // **名称刻意避开 `Canvas` / `Field`**：资产目录里留着两个同名的过期 colorset
        // （`#E5E8EC` / `#EDF0F3`，全仓无引用），而 `dynamicColor` 会优先取资产 ——
        // 用同名就会在真机上悄悄落到那组旧值上。
        public static let ink = SwiftUI.Color(nsColor: .labelColor)
        public static let inkSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        public static let inkTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        /// Content drawn on top of the accent fill.
        public static let onRail = SwiftUI.Color(nsColor: .alternateSelectedControlTextColor)
        /// 页面地板（窗口内容区）。稿 `surface/window`：`#E8E8EA` / `#201E21`。
        public static let canvas = dynamicColor(
            named: "SurfaceWindow",
            lightHex: 0xE8E8EA,
            darkHex: 0x201E21,
            hcLightHex: 0xE8E8EA,
            hcDarkHex: 0x201E21
        )
        /// 内容卡与面板。稿 `surface/content`：`#FFFFFF` / `#2B292C`。
        public static let field = dynamicColor(
            named: "SurfaceContent",
            lightHex: 0xFFFFFF,
            darkHex: 0x2B292C,
            hcLightHex: 0xFFFFFF,
            hcDarkHex: 0x2B292C
        )
        /// 嵌套面板（卡片里的容器，如 Inspector 试听面板），比所在卡片低一级。
        /// 稿 `surface/panel`：`#F5F5F7` / `#232124`。
        ///
        /// **注意：它不是输入槽的底色**。第五十一轮曾把输入槽接到这一级，
        /// 而稿的输入用的是下一档的 `surface/field`（第五十二轮改回）。
        public static let recessedField = dynamicColor(
            named: "SurfaceRecessed",
            lightHex: 0xF5F5F7,
            darkHex: 0x232124,
            hcLightHex: 0xF5F5F7,
            hcDarkHex: 0x232124
        )
        /// **可编辑输入槽**的底色。稿 `surface/field`：`#FFFFFF` / `#1A191C`。
        ///
        /// 它在稿的表面阶梯里是独立的一级：浅色下与内容卡同值（`#FFFFFF`，靠
        /// 1pt `border/strong` 分辨），深色下**比内容卡更深**（`#1A191C` vs `#2B292C`），
        /// 所以深色里输入槽读起来是凹进去的一格 —— 这是稿对「可编辑」的表达方式，
        /// 不是浅色下少给了一级。`figma-kit/main.js` 的 `textField()` / `TextField`
        /// 组件集全部用这一档（7 处），`surface/panel` 一次都没用在输入上
        /// （REDESIGN-SPEC §11.6 第五十二轮）。
        public static let inputField = dynamicColor(
            named: "SurfaceField",
            lightHex: 0xFFFFFF,
            darkHex: 0x1A191C,
            hcLightHex: 0xFFFFFF,
            hcDarkHex: 0x1A191C
        )
        public static let separator = SwiftUI.Color(nsColor: .separatorColor)
        public static let focusRing = SwiftUI.Color(nsColor: .keyboardFocusIndicatorColor)
        public static let disabled = SwiftUI.Color(nsColor: .disabledControlTextColor)
        public static let quaternaryFill = SwiftUI.Color(nsColor: .quaternaryLabelColor)
        /// 声轨信号色：提取自 Logo 纵深延伸的双高速导轨（Sonic Rail Cyan 冷青铁轨钢光与道床）
        /// The app accent is the asset catalog color: one source of truth for
        /// selection, focus and primary controls (§5.4).
        public static let rail = SwiftUI.Color.accentColor
        /// 声学母带真空管暖琥珀色：提取自经典模拟音频硬件真空管与暖调声学流
        public static let voice = dynamicColor(
            named: "VoiceAccent",
            lightHex: 0xD97706,
            darkHex: 0xF59E0B,
            hcLightHex: 0xB45309,
            hcDarkHex: 0xFBBF24
        )
        public static let ready = SwiftUI.Color(nsColor: .systemGreen)
        public static let attention = SwiftUI.Color(nsColor: .systemOrange)
        public static let critical = SwiftUI.Color(nsColor: .systemRed)
        public static let info = SwiftUI.Color(nsColor: .systemBlue)
    }

    /// Interactive surfaces. Every member resolves to a system semantic color,
    /// so light, dark, Increase Contrast and reduced transparency come from the
    /// system (REDESIGN-SPEC §5.4). The logo-derived chrome tokens (specular
    /// chamfer, ambient shadow, rail glow) were removed once the pages stopped
    /// drawing their own containers (§5.2).
    public enum Surface {
        public static let selectedFill = Color.rail.opacity(0.16)
        public static let voiceBadgeFill = Color.voice.opacity(0.20)
        /// Figma `surface/railTint`（脚本色板 `#DCE9EE` / `#36424A`）。
        ///
        /// §5.4 原本**不采纳**稿那六个手挑淡底（与系统色渲染差每通道 ≤6/255，而系统色会随
        /// 外观、Increase Contrast 与用户强调色自适应）。这里是那个原则的**显式特例**：
        /// 音色库与我的作品两块目录页的**列表选中行**，稿（`main.js:1552` / `:1681`）与
        /// 4x 帧都画这一档；2026-09-16 用户拍板「按稿采纳，并把 token 规则改成特例」
        /// （§12.4 决定 15）。
        ///
        /// 为什么必须自己画：系统 `List` 的选中高亮在**活跃窗口**里是**实心强调色**
        /// （本机 macOS 26 / arm64 实测：`NSTableRowView.isEmphasized = true` 时为 `#007CE7`，
        /// 未强调时为 `#DCDCDC`），既不是稿的淡底、也不跟随本 App 的强调色
        /// （`#23687D`）——所以它是一处**与设计稿和本 App 都不一致**的系统默认值。
        /// `.tint()` 对它无效，行内容的 `.background` / `.overlay` 会被它合成掉
        /// （四种写法逐像素实测见 §11.6 第六十轮）；**只有 `listRowBackground` 能换掉它**，
        /// 而 `List(selection:)` 的绑定、方向键与无障碍 selected 语义都不受影响。
        ///
        /// Increase Contrast 取同值：这一支是装饰性淡底，HC 下的可辨识度由行内 ink 与
        /// 分隔线承担（与 `attentionTint` 同一条口径）。
        public static let selectionTint = dynamicColor(
            named: "SelectionTint",
            lightHex: 0xDCE9EE,
            darkHex: 0x36424A,
            hcLightHex: 0xDCE9EE,
            hcDarkHex: 0x36424A
        )
        /// Figma `surface/attentionTint`（脚本色板 `#FBEEDA` / `#3D2F16`）。稿把它用在
        /// `Voice Chip` 这类**标注**胶囊的底色上，与状态胶囊的 `*Tint` 同族。
        /// Increase Contrast 下底色保持稿值，对比由 1pt `accent/voice` 描边与 ink 的
        /// HC 变体承担（`Color.voice` 自带 HC 色）。
        public static let attentionTint = dynamicColor(
            named: "AttentionTint",
            lightHex: 0xFBEEDA,
            darkHex: 0x3D2F16,
            hcLightHex: 0xFBEEDA,
            hcDarkHex: 0x3D2F16
        )
        /// Figma `Status Pill` 的语义色底色；状态色本身带图标与文字，颜色只是补充。
        public static let statusTintOpacity: Double = 0.14
        public static let inspectorFill = Color.field
        public static let border = Color.separator
        /// Figma `border/strong`（脚本色板 `#C6C6CB` / `#4A484C`）：**可编辑输入槽的边界**。
        ///
        /// 稿对「输入」有一条明确配方（`figma-kit/main.js` 的 `textField()` 与
        /// `Text Field` 组件集）：`fill surface/field` + **1pt `border/strong`** + `radius/field`(8)，
        /// 聚焦态才换成 `accent/rail` 2pt。所以「可编辑」在稿里本来就是一个**有边界的形状**，
        /// 而不是靠底色深浅——本机实测这一版系统里三层中性语义色逐位相同，底色本来就给不出
        /// 台阶（§11.6 第五十轮）。这里取稿的 `border/strong` 而不是 `separatorColor`：
        /// 后者在本机解析成 `#EBEBEB`，压在 `#F5F5F7` 的输入槽上只差 10/255，仍然「一眼看不出」。
        /// Increase Contrast 下取值同普通值并交给系统外观（本机取不到真实高对比外观，未验；
        /// 见 §11.6 第五十一轮未验证项）。
        public static let borderStrong = dynamicColor(
            named: "BorderStrong",
            lightHex: 0xC6C6CB,
            darkHex: 0x4A484C,
            hcLightHex: 0xC6C6CB,
            hcDarkHex: 0x4A484C
        )
        /// Only window-level floating layers cast a shadow (§5.2).
        public static let elevatedShadow = SwiftUI.Color.black.opacity(0.18)
        public static let interactionHover = Color.quaternaryFill.opacity(Interaction.hoverFillOpacity * 6)
        public static let interactionPressed = Color.quaternaryFill.opacity(Interaction.pressedFillOpacity * 6)
    }

    public enum Navigation {
        /// Custom rows and the page editors share one focus ring: the system
        /// focus indicator, so focus never changes color between pages (§9).
        public static let focusRing = Color.focusRing
        /// Selection keeps the single product accent as its source of truth
        /// (§5.4); the bespoke rail-cyan highlights were retired.
        public static let selectedForeground = Color.rail
        public static let unselectedForeground = Color.ink
        public static let secondaryForeground = Color.inkSecondary
    }

    public enum Motion {
        public static let standardDuration: Double = 0.2
        public static let reducedDuration: Double = 0
        public static let hoverDuration: Double = 0.14
        public static let pressDuration: Double = 0.12
        public static let selectionFeedback = Animation.easeOut(duration: 0.14)
        public static let hoverFeedback = Animation.easeOut(duration: hoverDuration)
        public static let pressFeedback = Animation.easeOut(duration: pressDuration)
    }

    // MARK: 提词器（准备页与独立舞台窗口）
    //
    // 新增提词器视觉值只在这里声明；视图不自行散落字号、窗口尺寸或间距。
    public enum Teleprompter {
        public static let preparationMinimumHeight: CGFloat = 560
        /// 准备页「原稿」编辑区的高度范围。短稿保留稳定的写作空间，长稿在编辑器内部滚动。
        public static let sourceEditorMinimumHeight: CGFloat = 144
        public static let sourceEditorIdealHeight: CGFloat = 260
        public static let sourceEditorMaximumHeight: CGFloat = 360
        public static let stageDefaultWidth: CGFloat = 960
        public static let stageMinimumWidth: CGFloat = 640
        public static let stageDefaultHeight: CGFloat = 620
        public static let stageMinimumHeight: CGFloat = 420
        public static let stagePadding: CGFloat = Spacing.xl
        public static let stageSegmentSpacing: CGFloat = Spacing.lg
        public static let stageStatusSpacing: CGFloat = Spacing.sm
        public static let stageScriptPointSize: CGFloat = 42
        public static let stageScriptMinimumPointSize: CGFloat = 28
        public static let stageScriptMaximumPointSize: CGFloat = 64
        public static let stageLineSpacing: CGFloat = 8
        public static let stageDefaultOpacity: Double = 0.94
        public static let stageMaximumWidth: CGFloat = 1_440
        public static let stageMinimumFontScale: Double = 0.67
        public static let stageMaximumFontScale: Double = 1.52
        public static let stageMinimumOpacity: Double = 0.55
        public static let stageMaximumOpacity: Double = 1
        public static let stageMinimumLineSpacing: Double = 0
        public static let stageMaximumLineSpacing: Double = 24
        public static let stageMinimumVisibleSegmentCount = 2
        public static let stageMaximumVisibleSegmentCount = 3
        public static let stageWindowAutosaveName = "SpeechRail.Teleprompter.Stage"
        /// 舞台窗口首发距屏幕顶端偏移（贴近摄像头，建立自然眼神视线锚点）。
        public static let stageTopInset: CGFloat = 48
        /// 状态指示灯（圆点）的边长。
        public static let stageStatusIndicatorSize: CGFloat = 8
        /// 三段视界不透明度阶梯：当前段 100%、下一段预读 60%、上一段回溯 35%。
        public static let segmentOpacityCurrent: Double = 1.0
        public static let segmentOpacityNext: Double = 0.60
        public static let segmentOpacityPrevious: Double = 0.35
    }
}

private func dynamicColor(
    named name: String,
    lightHex: UInt32,
    darkHex: UInt32,
    hcLightHex: UInt32,
    hcDarkHex: UInt32
) -> SwiftUI.Color {
    if let _ = NSColor(named: name, bundle: .main) {
        return SwiftUI.Color(name, bundle: .main)
    }
    return SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let isHighContrast = appearance.name == .accessibilityHighContrastAqua
            || appearance.name == .accessibilityHighContrastDarkAqua
        let hex: UInt32 = switch (isDark, isHighContrast) {
        case (false, false): lightHex
        case (true, false):  darkHex
        case (false, true):  hcLightHex
        case (true, true):   hcDarkHex
        }
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    })
}

public enum SpeechRailSurfaceLevel: Sendable {
    case window
    case navigation
    case control
    case inspector
    case panel
    case elevated
}

public extension View {
    func speechRailSurface(_ level: SpeechRailSurfaceLevel = .control) -> some View {
        modifier(SpeechRailSystemSurfaceModifier(level: level))
    }

    /// 容器表面：底色可随状态变化，但圆角只在容器层声明一次，并发布给子层做同心
    /// 推导 —— 子层不再需要任何半径数值（REDESIGN-SPEC §5.3）。
    func speechRailContainerSurface(_ fill: SwiftUI.Color) -> some View {
        background(fill, in: SpeechRailDesignTokens.Corner.containerShape)
            .containerShape(SpeechRailDesignTokens.Corner.containerShape)
    }

    /// 唯一焦点环：系统焦点色 + 一套线宽，形状跟随所在容器（§9：焦点色不随页面变化）。
    func speechRailFocusRing(
        _ isFocused: Bool,
        inset: CGFloat = SpeechRailDesignTokens.Interaction.focusRingInset
    ) -> some View {
        overlay {
            SpeechRailDesignTokens.Corner.nestedShape
                .stroke(
                    SpeechRailDesignTokens.Navigation.focusRing,
                    lineWidth: SpeechRailDesignTokens.Interaction.focusLineWidth
                )
                .padding(inset)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    /// 非输入槽（状态 / 操作条等）：`surface/panel` 底色 + 控件圆角，不带输入槽的描边。
    func speechRailField() -> some View {
        modifier(SpeechRailSlotModifier(kind: .statusBar))
    }

    func speechRailContentSurface() -> some View {
        modifier(SpeechRailSystemSurfaceModifier(level: .panel))
    }

    func speechRailConsoleChassis() -> some View {
        modifier(SpeechRailSystemSurfaceModifier(level: .panel))
    }

    /// 可编辑输入槽。名字里的「recessed」指稿那个可写格位本身
    /// （`surface/field` 深色下比卡片更深），**不是** `surface/panel`——
    /// 第五十一轮正是被这个名字带偏，把底槽接到了 `recessedField`。
    func speechRailRecessedSlot() -> some View {
        modifier(SpeechRailSlotModifier(kind: .editableInput))
    }

    /// 编辑卡：整张卡就是那个字段（配音台文稿卡、音色创作描述卡）。
    func speechRailEditorCard() -> some View {
        modifier(SpeechRailSlotModifier(kind: .editorCard))
    }

    func speechRailKnurledCapsule(selected: Bool = false) -> some View {
        modifier(SpeechRailChipModifier(selected: selected))
    }
}

// MARK: - System surfaces (v2)

/// Content panel. System fill, and the container whose radius the nested surfaces
/// inside derive from; a surface that neither carries interaction nor expresses
/// hierarchy gets no border and no shadow (REDESIGN-SPEC §5.2 / §5.3).
public struct SpeechRailSystemSurfaceModifier: ViewModifier {
    private let level: SpeechRailSurfaceLevel

    public init(level: SpeechRailSurfaceLevel) {
        self.level = level
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        switch level {
        case .window, .navigation:
            // The window and the system sidebar own their own backgrounds.
            content
        case .control, .panel, .inspector:
            content
                .background(
                    SpeechRailDesignTokens.Color.field,
                    in: SpeechRailDesignTokens.Corner.containerShape
                )
                .containerShape(SpeechRailDesignTokens.Corner.containerShape)
        case .elevated:
            // Only window-level floating layers elevate (§5.2).
            content
                .background(.regularMaterial, in: SpeechRailDesignTokens.Corner.containerShape)
                .containerShape(SpeechRailDesignTokens.Corner.containerShape)
                .shadow(
                    color: SpeechRailDesignTokens.Surface.elevatedShadow,
                    radius: SpeechRailDesignTokens.Shadow.elevatedRadius,
                    y: SpeechRailDesignTokens.Shadow.elevatedYOffset
                )
        }
    }
}

/// 槽的三种形态。**表面与边界是一件事，所以只有一个取值**：
/// 「有边界」必须等价于「可以输入」，否则那圈描边就不再是辨识线索
/// （2026-09-16 用户反馈「一眼看不出这是可编辑区」）。把两者拆成两个参数
/// 就允许出现「带边界的非输入」和「无边界却可输入」两种自相矛盾的组合，
/// 而这正是这条反馈要治的病。
public enum SpeechRailSlotKind {
    /// **表单字段**：稿 `surface/field`（`Color.inputField`）+ 1pt `border/strong` +
    /// `radius/field`(8)。名称、seed、参考文案、重命名这类「卡片里的一格」。
    case editableInput
    /// **编辑卡**：稿 `surface/content`（`Color.field`）+ 1pt `border/strong` +
    /// `radius/container`(12)。整张卡就是那个字段（配音台文稿卡、音色创作描述卡）。
    ///
    /// 它与 `editableInput` 不是同一个表面，差在**表面阶梯**上：暗色帧实测两张编辑卡
    /// 的整卡都是 `#2B292C`（= `surface/content`），而 `surface/field` 是 `#1A191C`。
    /// 第五十二轮曾把编辑卡按表单字段接成 `surface/field`，暗色下整张卡会凹进去一格。
    case editorCard
    /// 非可编辑的状态 / 操作条：稿 `surface/panel`（`Color.recessedField`），只有底色。
    case statusBar
}

/// Slot surface: 输入槽与状态条共用一套几何，只有「表面 + 边界」不同。
///
/// **可编辑的输入槽必须有边界**：这是稿自己的规矩——`figma-kit` 的
/// `textField()` / `Text Field` 组件集是 `fill surface/field` + **1pt `border/strong`**
/// + `radius/field`，聚焦态才换 `accent/rail` 2pt。边界取 `Surface.borderStrong`，
/// 不是 `separatorColor`：后者在本机解析成 `#EBEBEB`，压在槽底上差值很小；
/// `border/strong` 是 `#C6C6CB`，在浅色 `#FFFFFF` 上差 57/255。
///
/// **底色按 case 各取自己那一级**（第五十一／五十二／五十三轮的三次修正）：
/// 表单字段是 `surface/field`，编辑卡是 `surface/content`，状态条是 `surface/panel`。
/// 第五十一轮把表单字段错接到 `surface/panel`（浅色下一整片灰），第五十二轮改成
/// `surface/field`；第五十三轮再把编辑卡单独分出来——三处数值都有帧的直接证据：
/// `surface/panel` 在两种外观下都比页面地板亮一档（「抬起的一条」）；
/// `surface/field` 深色下比卡片更深（`#1A191C` vs `#2B292C`，「凹进去的可写一格」）；
/// 而两张**编辑卡**在暗色帧里整卡是 `#2B292C`，即 `surface/content`。
///
/// **状态条不跟着改。** 稿的 `surface/field` 七处**全部**是文本输入
/// （`main.js:678/689/774/786/1007/1018/1331`），没有一处用在不可编辑的条上。
public struct SpeechRailSlotModifier: ViewModifier {
    private let kind: SpeechRailSlotKind

    public init(kind: SpeechRailSlotKind) {
        self.kind = kind
    }

    /// 全 App 只有可编辑的东西带这圈描边（见 `SpeechRailSlotKind`）。
    private var showsBoundary: Bool { kind != .statusBar }

    private var fill: Color {
        switch kind {
        case .editableInput: SpeechRailDesignTokens.Color.inputField
        case .editorCard: SpeechRailDesignTokens.Color.field
        case .statusBar: SpeechRailDesignTokens.Color.recessedField
        }
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        switch kind {
        case .editorCard:
            // 编辑卡是**容器**：取 `radius/container` 12 并把形状发布给子层推导
            // （焦点环的 `ConcentricRectangle` 靠它算出同心半径）。
            content
                .background(fill, in: SpeechRailDesignTokens.Corner.containerShape)
                .containerShape(SpeechRailDesignTokens.Corner.containerShape)
                .overlay { boundary(SpeechRailDesignTokens.Corner.containerShape) }
        case .editableInput, .statusBar:
            // 表单字段是**控件**：固定 `radius/field`(8)，不参与同心推导（第四十八轮）。
            content
                .background(fill, in: SpeechRailDesignTokens.Corner.controlShape)
                .overlay {
                    if showsBoundary {
                        boundary(SpeechRailDesignTokens.Corner.controlShape)
                    }
                }
        }
    }

    /// `strokeBorder` 把描边画在形状内侧：加描边不改变槽的尺寸（`stroke` 会外扩半个线宽）。
    private func boundary<S: InsettableShape>(_ shape: S) -> some View {
        shape.strokeBorder(
            SpeechRailDesignTokens.Surface.borderStrong,
            lineWidth: SpeechRailDesignTokens.Stroke.strong
        )
    }
}

/// Interactive chip: 稿 `Voice Chip` 组件的胶囊几何 —— 琥珀底 `surface/attentionTint`
/// + 1pt `accent/voice` 描边，几何取 `Chip`。选中态（当前没有调用点）仍用系统强调色。
///
/// 应用此前是灰底 `quaternaryLabelColor` 且无描边：在浅色页面里读起来像「禁用/占位胶囊」，
/// 与稿的**琥珀色标注**是完全不同的语义，也不属于系统语义色能自动适配的一组
/// （REDESIGN-SPEC §11.6 第三十四轮）。
public struct SpeechRailChipModifier: ViewModifier {
    public let selected: Bool

    public init(selected: Bool = false) {
        self.selected = selected
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, SpeechRailDesignTokens.Chip.insetX)
            .padding(.vertical, SpeechRailDesignTokens.Chip.insetY)
            // 稿的 22pt 是**含描边**的 chip 高度，`strokeBorder` 画在边界内侧，
            // 所以这里钉住内容盒高度即可让墨迹落在帧上的 22–23pt。
            .frame(minHeight: SpeechRailDesignTokens.Chip.height)
            .background(fill, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(stroke, lineWidth: SpeechRailDesignTokens.Chip.borderWidth)
            }
    }

    private var fill: SwiftUI.Color {
        selected
            ? SwiftUI.Color.accentColor.opacity(0.18)
            : SpeechRailDesignTokens.Surface.attentionTint
    }

    private var stroke: SwiftUI.Color {
        selected ? SwiftUI.Color.accentColor : SpeechRailDesignTokens.Color.voice
    }
}
