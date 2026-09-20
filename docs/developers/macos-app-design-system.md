---
title: "SpeechRail macOS App 设计系统与 Token"
status: active
audience: "SpeechRail macOS App 设计、开发与测试人员"
version: "0.8.9"
date: 2026-09-20
---

# SpeechRail macOS App 设计系统与 Token

> **迁移已完成（2026-09-15）**：[`docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md`](../design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md)
> 的 §5（视觉语言 v2）与 §7（逐页规格）已落到 `macos/SpeechRailApp`：阶段 1 外壳、阶段 2 token 收敛、
> 阶段 3 命令与键盘、阶段 4 逐页重构均已完成，本文 §3 与 §4 已按 v2 语义重写，两份文档不再并行描述两套规范。
> 设计决策与阶段状态以 REDESIGN-SPEC §10 为准；本文件只描述落地后的 token 与组件契约。

> **已知未验证项（2026-09-15）**：以下内容只完成代码与构建验证，尚未做桌面人工走查或 UI 自动化：
> Light/Dark、Increase Contrast、Dynamic Type、Reduce Motion 的实际观感；VoiceOver 实读顺序；
> 列表「空格试听」在真实焦点下的行为；`.searchable` 与页面级 `List` 在窄窗口下的布局。

> **当前范围说明（2026-09-20）**：2026-09-18 起新增的语音助手、会议助手、实时字幕，以及 2026-09-20
> 新增的 AI 提词器属于独立的 App 会话/舞台能力，不是本 2026-09-15 UI 迁移包的完整页面清单。
> 会话生命周期、音频来源与记录边界以 [`会话层技术方案`](../design/2026-09-18-session-layer/TECHNICAL-DESIGN.md)、
> [`AI 提词器开发说明`](macos-app-teleprompter.md) 和 [`macOS App 开发与测试`](macos-app-development.md) 为准；
> 本文的 token 与系统控件约束仍适用于这些页面。

## 1. 研究基线与 Logo 设计基因

本设计系统以 macOS 26 的设计语义、当前 Xcode 27.0 / macOS 27 SDK 工具链为基线。`SpeechRailApp` GUI target
明确以 macOS 26.0 为最低版本，不为 Native App、ControlKit、ControlAgent、CaptureHelper
或服务侧 SwiftPM worker 编写 macOS 14 的兼容 fallback。研究结论是：所有 Native target
在 macOS 26 上完整使用系统新设计能力，不把新特性降级为共同最低版本的视觉实现。

- Apple 的 macOS 指南要求充分利用大屏、可调整窗口、菜单栏、键盘快捷键和可定制工具栏，避免把重要内容藏在过多模态层级中。[Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- macOS 26 的新设计以 Liquid Glass 作为工具栏、侧边栏和重要控制的系统层；标准 SwiftUI 结构和控件会获得系统级更新，定制玻璃只用于真正重要的产品特性，不用自绘玻璃模拟系统。[Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)、[Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- `NavigationSplitView` 适合 SpeechRail 的多根类别导航；`MenuBarExtra` 适合常用状态和动作；`Settings` 由系统负责从 App 菜单和 `Command-,` 打开。[NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview)、[MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)、[Settings](https://developer.apple.com/documentation/swiftui/settings)
- macOS 工具栏中的高频命令必须同时存在于菜单栏，避免用户隐藏工具栏后失去能力；工具栏动作按逻辑分组，窄窗口交给系统 overflow 处理。[Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)、[Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- VoiceOver 在 macOS 上主要通过键盘操作。页面应使用合理的 accessibility container、明确的 label/value、可访问动作和快捷键；任何只依赖 hover 的动作都必须提供可见或键盘可达的替代入口。[Make your Mac app more accessible to everyone](https://developer.apple.com/videos/play/wwdc2025/229/)、[Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

### 1.1 Logo 设计基因深度解构 (Design DNA)

> 本节记录 Logo DNA 的**原始解构**，不是当前实现契约。v2 视觉语言（见 §3.1 与 REDESIGN-SPEC §5）
> 已把下面第 1 项的物理命名（`Chassis`/`SteelAlloy`/`SteelRail`/`AcousticMaster`/`ConsoleFader`）与
> 第 3、4 项的自绘倒角、沉降凹槽、轨枕分阶、钢轨滑标全部移除：这些 token 已从代码中删除，界面改为
> 系统语义色与系统控件。token 的事实来源以 §3.1 为准，本节保留的是品牌基因与配色研究。

应用徽标（`docs/assets/logo.png`）是整个产品视觉语言与工业隐喻的根基源头。设计提炼为五大核心维度：

1. **命名 (Naming & Taxonomy)**：
   - 彻底摒弃抽象通用 Web 词汇（如 `Canvas`, `Field`, `Ink`, `Surface`），建立映射电声母带硬件与铁路工程的物理实体命名空间：
     - `Chassis`（机架基座：`enclosure`, `deck`, `recessedWell`, `milledBevel`, `grooveStroke`）；
     - `SteelAlloy`（拉丝钢钛：`specularEdge`, `brushedFace`, `billetPlate`, `knurledRim`）；
     - `SteelRail`（钢轨道床：`trackCyan`, `railheadGleam`, `sleeperTie`, `gliderBead`, `signalPulse`）；
     - `AcousticMaster`（声学母带：`tubeWarmth`, `vuPhosphor`, `peakOverload`, `waveCrest`）；
     - `ConsoleFader`（母带推子：阻尼刻度、滑轨厚度、推头规格）。
2. **配色 (Chromatic DNA)**：
   - **黑曜声学机架基调**：主基底为吸光黑曜岩枪膛色（`#151719`~`#1A1C1F`），消除惨白纸质漂浮感。
   - **绝无 `#007AFF` 蓝色**：高亮与选中采用 Logo 道床冷青钢光（`#2A4E57`）与钢轨顶面反光（`#4FA4BA`）。
   - **选中高亮必须走系统强调色机制**：侧边栏/列表选中色取自 App 强调色，需同时具备 `Assets.xcassets/AccentColor`
     与构建设置 `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor`（后者产出 `NSAccentColorName`）；
     缺少构建设置时资产不会生效，选中色回落系统默认蓝。不得用 `.listRowBackground` 自绘选中背景替代。
     macOS 仅在系统强调色为「多彩 Multicolor」时应用 App 强调色，用户显式选择其他强调色时系统优先。
     **例外（2026-09-16 用户拍板，REDESIGN-SPEC §12.4 决定 15）**：音色库与我的作品两块目录页的
     **列表选中行**改用稿的 `surface/railTint`（`Surface.selectionTint`，浅 `#DCE9EE` / 深 `#36424A`），
     实现只能走 `.listRowBackground`。理由是系统那一档**同时偏离稿与本 App**：活跃窗口下它是
     **系统强调色实心**（本机 macOS 26 / arm64 实测 `#007CE7`，且因系统强调色不是 Multicolor
     而不受 App 强调色影响），未强调时是 `#DCDCDC`——稿要的是淡青底。五种写法的逐像素实测见
     REDESIGN-SPEC §11.6 第六十轮 ②（`.tint()` 无效、行内容 `.background` / `.overlay` 会被
     选中材质合成掉，只有 `listRowBackground` 能换掉，且 `List(selection:)` 的方向键与
     无障碍 selected 语义全部保留）。**这条例外只给这两处列表**，其余列表的选中态仍走系统机制。
   - **电声双阶暖冷互映**：声色创作注入真空管暖琥珀（`#F59E0B`），运行监控注入示波器磷光绿（`#10B981`）。浅色模式呈现阳极氧化实心铝锭质感（`#DDE1E6`~`#E8ECF0`），非纸白。
3. **组件效果 (Physical Craftsmanship & Optics)**：
   - **CNC 双阶倒角 (Dual-Step Chamfer)**：顶边 0.5px 镜面切削白高光，底边 0.5px 机械深槽闭塞投影。
   - **沉降式声学凹槽 (Recessed Slot)**：文稿编辑框与参数输入槽物理内陷，带上缘阴影与底边缘反光。
   - **轨枕分阶标尺 (Sleeper Divider)**：带中心声轨电珠微光的重型物理隔断。
   - **金属镶嵌透光微珠 (Jewel LED)**：侧边栏状态指示珠带金属外圈与漫反射光晕。
4. **交互方式 (Console Ergonomics)**：
   - **钢轨滑标导航 (Rail Glider)**：侧边栏依附纵向钢轨，选中项化身滑行动态光珠与冷青光晕。
   - **母带校准推子 (Calibrated Console Fader)**：语速配备物理校准阻尼刻度（0.5x, 1.0x 基准, 1.5x, 2.0x）与快切档位。
   - **4 轨母带试听机架 (4-Track Studio Rack)**：音色候选按调音台 4-Track 排布，独立试听与入库。
5. **意境 (Atmosphere & Metaphor)**：
   - **「重工业声学机架 · 钢轨声流 · 精密调音台」**：端坐于 Apple Silicon 上的专业母带级电声硬件存在感，稳定、低抖动、高保真。

## 2. App 层不以兼容牺牲特性

### 2.1 平台能力矩阵

| 能力 | SpeechRailApp macOS 26+ | 独立服务/协议边界 | 设计决策 |
|---|---|---|---|
| Liquid Glass | 直接使用系统 `glassEffect` 能力承载窗口/导航层和关键控制 | 不参与 GUI 渲染 | 玻璃只表达导航或交互层；内容与 Inspector 不铺玻璃 |
| 浮动工具栏与分组 | 直接使用系统 toolbar、`ToolbarSpacer`、scroll edge effect | 不参与 GUI 渲染 | 重要命令仍进入菜单栏，不能只放在 toolbar |
| 导航 | `NavigationSplitView` 使用 macOS 26 sidebar 行为 | 不参与 GUI 导航 | 不另造一套平行导航；窗口变窄时使用系统折叠 |
| 菜单栏入口 | `MenuBarExtra` 展示健康状态和高频动作 | 不参与 GUI 渲染 | 菜单栏是快速入口，不承载完整监控看板 |
| 可访问焦点 | 使用 macOS 26 的默认焦点、container、label/value 和键盘导航 | 协议层只传递状态，不渲染 UI | 不以旧系统 API 为理由移除可访问语义 |
| 动效 | 系统 Liquid Glass 和标准控件动效 | 不参与 GUI 渲染 | 尊重 Reduce Motion，不能把动效当信息唯一来源 |

App target 的 `MACOSX_DEPLOYMENT_TARGET` 必须为 `26.0`，只要是 App 页面或 App 专属
设计组件，就直接依赖 macOS 26 API。不得为了让 App target 继续编译到 macOS 14 而加入
条件分支、兼容视觉 fallback 或删除 macOS 26 行为；服务侧独立 target 的最低版本不改变
App 的 UI 实现。内容层使用标准 macOS 内容表面是信息层级决策，不是为了兼容旧系统而降级。

### 2.2 SpeechRail 的产品层级

1. **创作层**：配音台、音色创作、音色库、我的作品是一级产品能力，不能被服务管理页替代。
2. **服务层**：总览、运行监控、模型管理、预检与诊断解释本机服务能否使用、为什么异常以及下一步动作。
3. **技术层**：仅在用户主动打开“开发者详情”或进入诊断细节时出现端口、profile、worker、metrics 和错误码。

每个页面都先回答“它是什么、什么时候用、下一步做什么”，再按需显示技术细节。

## 3. Token 单一事实来源

SwiftUI 代码中的颜色、间距、圆角、窗口尺寸、控件高度和字体层级统一来自：

`macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`

页面不直接散落 `Color(red:green:blue:)`、任意 `CGFloat`、自定义字号或重复的 corner radius。
Apple 的系统颜色、字体、材料和标准控件优先于自定义 token；SpeechRail token 只补足产品
语义、布局约束和跨 macOS 版本的统一映射。

### 3.1 Token 语义与规范

> v2 起，字体、圆角与**大多数**颜色不再由 SpeechRail 自己定义：token 层做系统语义色的映射，
> 让 App 跟随用户的外观、强调色和辅助功能设置。**唯一的例外是中性表面阶梯**（页面地板 / 卡片 /
> 嵌套面板）：本机实测三个系统语义色在两种外观下逐位相同（四级塌成一级），所以这三层取稿的显式
> 取值（§11.6 第五十轮）。下表是当前唯一有效的语义映射。

| 物理领域 | Swift 命名空间 | 核心 Token 与规格约束 |
|---|---|---|
| 文本层级 | `Color` | `ink/inkSecondary/inkTertiary` → 系统 `labelColor/secondaryLabelColor/tertiaryLabelColor`；不使用自挑灰度 |
| 表面底色 | `Color` | `canvas` = `#E8E8EA`/`#201E21`（页面地板）、`field` = `#FFFFFF`/`#2B292C`（卡片与**编辑卡**）、`recessedField` = `#F5F5F7`/`#232124`（嵌套面板与状态条）、`inputField` = `#FFFFFF`/`#1A191C`（**表单字段**）——**显式取值，不走系统语义色**：三个系统语义色在本机逐位相同，给不出稿的四级（§11.6 第五十轮）。四级的顺序是稿自己的阶梯，不是「越深越重」：浅色下 `field` 与 `inputField` 同值（靠 1pt `borderStrong` 分），深色下 `inputField` 比卡片**更深**（`#1A191C` vs `#2B292C`），读作「凹进去的可写一格」。`named:` 刻意避开资产目录里同名的死资产 `Canvas`/`Field`（用同名会被 `dynamicColor` 优先取到旧值）。落地点：`SpeechRailSystemSurfaceModifier`、`SpeechRailSlotModifier` 与 `ControlCenterView` 的详情区地板（§11.6 第五十三轮） |
| 分隔与描边 | `Color` | `separator` → `separatorColor`（分隔线，动态表面）；`borderStrong` = 稿 `border/strong`（`#C6C6CB`/`#4A484C`）**只给可编辑输入槽当边界**——它是「可以输入」的视觉定义（§11.6 第五十一轮）。静态表面不再有自绘描边、机加工微切线与辉光 |
| 强调色 | `Color` | `rail` → **`Color.accentColor`**（跟随系统强调色）。全 App 只有这一个产品强调色，替代原先 `#23687D` 与 `#2A4E57` 并存的冲突 |
| 语义状态 | `Color` | `ready/attention/critical/info` → 系统 `.green/.orange/.red/.blue`；`voice`（音色/声学）为唯一产品语义色 |
| 控件描边与焦点 | `Color` | `focusRing` 与自定义行的 `Navigation.focusRing` 都解析为 `keyboardFocusIndicatorColor`，全 App 焦点环同色；`disabled`/`quaternaryFill` 表示禁用层级 |
| 间距节奏 | `Spacing` | 使用 `tight/micro/xs/sm/md/gutter/lg/xl/hero`，基准节奏为 2/4/8/12/16/20/24/32/48 pt；页面级块间距固定用 `gutter`（20pt，稿实测），栏与栏用 `md`（16pt），网格项用 `sm`（12pt） |
| 圆角几何 | `Corner` + `ConcentricRectangle` | **容器声明一次、叶面同心推导、控件固定取值**：容器用 `Corner.containerShape`（`RoundedRectangle(Corner.container = 12, .continuous)`）并由 `.containerShape()` 把形状发布给子层；**表面**叶面用 `Corner.nestedShape`（`ConcentricRectangle(corners: .concentric(minimum: .fixed(Corner.nested = 8)))`）跟随容器；**控件**（输入槽、图标框）用 `Corner.controlShape`（`RoundedRectangle(Corner.nested, .continuous)`，固定 8，= 稿 `radius/control` / `radius/field`）——它们的内缩 `cardInset = 20` 会让推导值 ≤ 0 而画成方角（§11.6 第四十八轮）。全 App 只有 12 / 8 两个半径数值，但形状有三个声明点；`speechRailContainerSurface(_:)` 是唯一的容器声明点。**注意量出来的口径**：叶面半径 = 容器半径 − 内缩（12→0），`minimum` 只在容器给不出半径时兜底、**不是**推导值的下限，所以内缩 ≥ 12pt 的叶面会得到方角（§11.6 第四十六轮）；`.continuous` 与 `.circular` 在同半径下缺角形状不同，两者必须并排量才分得清。**按钮不在这套几何里**：`SpeechRailButtonAppearance` 用原生 `.borderedProminent`/`.bordered` + `.controlSize`，圆角归 AppKit——离屏实测 macOS 26 的原生按钮就是**半高胶囊**（主按钮 36pt 高 / 缺角 66.8pt²、次按钮 28pt 高 / 41.2pt²，都等于 `高度 ÷ 2` 的胶囊），与 8pt continuous 参考（13.0pt²）明显不同档；键帽若还用自绘圆角，会和同排的系统按钮读成两个体系，所以快捷键提示改成按钮标签内的一段文字（§11.6 第四十八 / 五十一轮） |
| 布局规整 | `Layout` | sidebar 220–280pt（ideal 240）、**inspector 定宽 360pt（`inspectorColumnWidth`，唯一声明点 `speechRailInspectorColumn()`）**、模型档位列 220–320pt（ideal 280）、音色名列 160–260pt（ideal 220）、页面内容内边距 `contentPadding = 20`、卡片内容内边距 `cardInset = 20`（稿 18，工具栏式卡片用 `md`/`sm` = 16/12）、窗口最小 1,120×720pt。详情列此前是一个**区间**（300–440，ideal 360），列宽因此是窗口余量、内容最小宽与打开顺序的函数：空态那一瞬会落到系统默认的 270，窗口紧时会被压到 300，两块目录页因此可以各是一个宽度（§11.6 第六十一轮） |
| 控件高度 | `Control` | 稿的档位是 34 / 30 / 28（Figma `size/control`、次按钮、`controlComp`）。系统控件在本机实测为 `.regular` 24 / `.large` 28 / `.extraLarge` 36，且 `.controlSize` 不改标签字号，所以按钮高度一律走 `SpeechRailButtonAppearance`：主按钮 `.extraLarge`、次按钮/危险按钮 `.large`、安静按钮 `.regular`（见 §11.6 第二十一轮）。手写输入槽、页脚带等仍用 `Control.regularHeight`(34) / `compactHeight`(28) |
| 头部（窗口工具栏） | `Toolbar` | 只有两个子档：`Identity`（页面身份锁：**`.navigation` 槽、槽内左对齐**、固定槽位 280×32、单行、尾截断、最小缩放 0.82）与 `Action`（头部动作控件：28pt 高、图标 14pt/18pt 框、左右内边距 8、图标与文字间距 4）。三条契约：页面名只在 `Identity` 出现一次（正文不重复标题）；头部动作要么是具体动作、要么是图标 + 精确的无障碍标签，不用「更多操作」这类通用文字标签常驻；状态不进头部（服务是否就绪由侧边栏底部状态区独家承担）。**身份槽的落点由系统给：`Identity` 必须是详情列的 leading 项**（窗口左沿那一格被系统侧栏切换按钮占用且不可移除），`.principal` 只适用于「窗口中心标题」，在带工具栏搜索框的页面上会整体左移 135pt（§11.6 第五十五轮）。`Icon.rowActionSize` 是**列表行内**动作，与本档不共用 |
| 表面修饰 | `ViewModifiers` | `.speechRailSurface(_:)` / `.speechRailContentSurface()`（`Color.field` + 同心圆角，**无描边**——只有窗口级浮动层 `.elevated` 有材质与阴影）、`.speechRailRecessedSlot()`（`inputField` + 1pt `borderStrong` + `controlShape`，**只给表单字段**）、`.speechRailEditorCard()`（`field` + 1pt `borderStrong` + `containerShape`，**编辑卡**：整张卡就是那个字段）、`.speechRailField()`（只有 `recessedField` 底色，状态/操作条用）、`.speechRailInspectorPreviewPanel()`（`recessedField` + 1pt `separator` 描边 + `previewRadius`，**详情面板里的试听面板**，见 `SpeechRailInspectorPanel`）、`.speechRailKnurledCapsule()`（系统胶囊，仅选中态用强调色）。三个有边界的不是同一个 token，差别见 §3.2 第 3 条 |
| 字体层级 | `Typography` | 只用系统文本样式（`.title/.headline/.body/.callout/.subheadline/.caption` 等），不再使用 `design: .rounded` 或手挑字号；数字一律 `.monospacedDigit()`。稿的 `Title / Page` = 20pt Semi Bold，系统样式里没有 20，取 `.title`（22，+2pt）：页标题、卡片/面板标题、状态结论标题、诊断详情标题统一走这一档；行内状态与空态标题走 `Heading / Section`（13pt Semi Bold）。列头与状态胶囊用 `captionMedium`（稿 `Caption / Medium`，10pt Medium）；取值槽用 `technicalValue`（稿 `Callout` 12 + 应用自己的等宽数字约定）；`caption`/`technical` 只留给应用自有的密集区块（设置快捷键清单、诊断开发者折叠区、下载进度文件名） |
| 动效反馈 | `Motion` | 仅保留系统级转场；按压缩放已从按钮移除，波形脉冲在 Reduce Motion 下退化为静态；选区反馈 `0.14s` |
| 波形（听觉对象的形状） | `Waveform` | `resultBar`(12 根) / `candidateTile`(18 根) / `libraryPreview`(16 根) 三处只声明**条数与排布**（宽 `barWidth` 2、圆角 `barRadius` 1、间隙、峰值高度），条高一律来自真实音频的幅度包络（`envelopeBuckets` 32 桶、逐窗**峰值**、整段归一化，`AudioEnvelope`）；静音窗下限 `envelopeMinimumHeight`(3)；播放中未播到的部分 `remainingOpacity`(0.35)，进度取播放器真实的 `currentTime / duration`（`progressInterval` 20Hz）。`Pattern.heights` 只在**没有包络**时使用（「这段音频还没算过」，例如还没试听过的音色）。波形脉冲**只在**这种无包络的情形保留（§11.6 第五十七轮） |
| Inspector 面板 | `SpeechRailInspectorPanel` + `SpeechRailInspectorLabeledContentStyle` | 目录页（音色库 / 我的作品）右侧详情面**唯一的结构声明点**：身份带（`Typography.display` + `Typography.caption`/`inkTertiary` 徽标）→ 整宽 hairline → 试听段（`.speechRailInspectorPreviewPanel()`，段内边距 `previewWrapInsetY`）→ hairline → 取值段（`Inspector.contentPadding`）→ hairline → 固定动作区（`Inspector.actionPadding`，在 `ScrollView` 之外）。取值行用 `SpeechRailInspectorLabeledContentStyle`：标签列固定 `Inspector.labelColumnWidth = 92`，取值右对齐、可选文本，供全 App inspector 复用。其他六页的「开发者详情」是另一套（`DeveloperInspector`） |

诊断结论区的用户影响说明使用 `Diagnostics.summaryMessageMaximumLines`，默认最多两行；当动态字体或
错误文案需要更多垂直空间时，结论区只能自然增高，不得用固定最大高度裁切内容。

> **2026-09-16 第五十六轮对账（更正本表「圆角几何」行的一句话）**：那一行末尾写「全 App 只有
> 12 / 8 两个半径数值」，与同一张表「表面修饰」行自己列出的 `.speechRailInspectorPreviewPanel()`
> （`previewRadius`）矛盾。全仓复查 `RoundedRectangle(cornerRadius:)` 共 **5 处**：
> `Corner.containerShape`(12)、`Corner.controlShape`(8)、`Waveform.barRadius`(1，稿的波形单根圆角)、
> `Inspector.previewRadius`(10，稿 `preview` 面板) 与 `Inspector.previewRadius + 1`(11，描边画在
> 填充外的那一圈)。准确说法是：**同心推导那一族只有 12 / 8 两个数值**；另有 1 / 10 / 11 三个只服务
> 单个元素、取自稿值的半径，都不参与推导。新增半径仍然只走「改进 token 或复用 `Corner`」这一条，
> 不得就地写死。

### 3.2 全局交互语言与组件契约

1. **页面身份只有一处**：`PageIdentityToolbarItem(route)` 在**窗口组合根**（`ControlCenterView`
   的 detail 工具栏）声明一次——身份是当前路由的纯函数，页面没有要额外携带的标题状态，
   所以声明一次最省、也最不可能漂移。它渲染 `WorkspaceTitleLockup`
   （icon + 页面名的单行标题，固定槽位 280×32、**槽内左对齐**、尾部截断、最小缩放，永远不换行；
   放在 `.navigation` 槽——即详情列的 leading 位置，十页恒定同一点，见 §11.6 第五十五轮）；
   页面只声明自己的动作。`PageScaffold` 不再渲染页面名，正文只留一句话说明
   （`purpose`，默认取 `AppRoute.pageSubtitle`）。页面名统一取 `AppRoute.title`，不另设别名
   （REDESIGN-SPEC §6.2 / §11.6 第四十九轮）。
   **头部动作**：每页最多一组，要么是具体命名的动作（「服务」「新建音色」），要么是图标 + 精确的
   无障碍标签（`PageActionButton` / `PageActionsMenu`）；头部不再有「更多操作」这类通用文字标签，
   也不放服务状态。窗口里只保留**一个**搜索框，且它属于内容（音色库 / 我的作品的工具栏搜索）。
2. **系统表面 (System Surfaces)**：`.speechRailSurface(_:)` 只渲染表面填充色（`Color.field`，见 §3.1 的例外）与同心圆角。承载交互或用层级表达关系的容器**没有边框、没有阴影、没有高光**；只有窗口级浮动层（`.elevated`）使用 `regularMaterial` 与系统阴影。
3. **可编辑表面分两档，边界是它们的共同记号**。两档都带 1pt `Color.borderStrong` 边界，焦点态由系统 `keyboardFocusIndicatorColor` 描边而非自定义发光；**边界只属于可编辑**：状态/操作条用不带边界的 `.speechRailField()`，否则「有边框」不再等于「可以输入」（§11.6 第五十一轮）。
   - **表单字段**（名称、seed、参考文案、重命名这类「卡片里的一格」）用 `.speechRailRecessedSlot()`：稿 `surface/field`（`Color.inputField`）+ `radius/field`(8)。
   - **编辑卡**（配音台文稿卡、音色创作描述卡——整张卡就是那个字段）用 `.speechRailEditorCard()`：稿 `surface/content`（`Color.field`）+ `radius/container`(12)。它比表单字段高一整级表面，**不是一个槽套在卡片里**：稿的 `main.js:1448-1452` 写过「在白卡里再套一个白输入框只会给同一句话画两圈边」，4x 帧的浅色与深色两版都只有一圈描边、且位于卡沿（§11.6 第五十三轮）。
   两条配方都不是自造：稿的 `textField()` / `TextField` 组件集是 `surface/field` + 1pt `border/strong` + `radius/field`，聚焦态才换 `accent/rail` 2pt。
4. **指针与无障碍命中区**：可操作实例统一通过 `speechRailPointerCursor()` 暴露 pointing hand；自定义行/卡片使用 `SpeechRailInteractiveButtonStyle`；命中区由控件自身尺寸决定，不再对按钮强制 44pt 最小框架（该约束会挤压紧凑工具栏）。
   > 2026-09-16 该样式新增三个参数（§11.6 第五十二轮）：`horizontalInset`（默认 `Spacing.xs`(8)，
   > 行/叶面按钮的悬停填色比内容各宽 8pt）、`baseFill`（默认 `.clear`）、`corner`
   > （默认 `.nested`；**自带底色的卡片**要传 `.container`，否则填色圆角比卡片小一档）。
   > 状态色与底色叠在**同一个背景层**里，所以「卡片自己画不透明底色」与「样式画悬停色」
   > 不再互相覆盖——模型页的档位卡就是按这条收口的（底色与 `horizontalInset: 0` 一起交给样式，
   > 可见间隔因此回到帧的 12pt）。
5. **列表交还系统**：音色库、我的作品、诊断检查项和监控表格使用系统 `List`/`Table`，由系统渲染选中态、悬停、交替行和键盘导航；页面不再自绘选中底色与焦点环。**唯一例外**是音色库与我的作品的**列表选中行**（`Surface.selectionTint`，见 §3.2 第 2 条的 2026-09-16 例外）：那是系统那一档同时偏离稿与本 App 时取稿值的裁决，容器、键盘导航与无障碍语义仍由系统 `List` 提供。
6. **命令与快捷键**：`SpeechRailCommands`（`App.swift`）提供 File/View/Help 菜单与 `⌘N`、`⌘E`、`⌘R`、`⌘1–⌘9`、`⌘0`（十个一级页面各有一个直达键，按 `AppRoute` 顺序）、`⌘⌥I`、`?`；
   `⌘E` 通过 `FocusedValues.selectedWorkCommand` 绑定到当前场景选中的作品；`⌘R`（重新读取当前页）
   通过 `FocusedValues.reloadPageCommand` 绑定到**页面自己声明的**重读动作——所以头部不需要十个
   含义各异的「刷新…」菜单项，没有可重读内容的页面（我的作品）该菜单项自然禁用。
   `⌘F` 目前未绑定：SwiftUI `.searchable` 没有公开的聚焦 API，聚焦搜索框需要额外的 AppKit 桥接，
  留作后续（REDESIGN-SPEC §6.3）。
   **快捷键文案显示在哪**：有菜单栏镜像的命令（`⌘N`/`⌘E`/`⌘R`/`⌘1–⌘9` 与 `⌘0`/`⌘?`）由菜单栏承担提示，
   按钮不重复；**只有正文入口、菜单栏没有同义项**的命令（`⌘⏎` 生成）才把快捷键写进按钮标签
   （`ButtonShortcutHint`，降一档不透明度、对辅助技术隐藏），不再画独立键帽。
7. **文本按宽度截断，不在构造时预截**（2026-09-16 用户反馈，REDESIGN-SPEC §11.6 第五十一轮）：
   需要「随 UI 宽度显示更多」的文本，一律**按整段保存、按可用宽度渲染**——单行 `Text` +
   `.lineLimit(1)` + `.truncationMode(...)`，绝不把「前 N 字 + `…`」写进模型或落盘。
   数据层只保留一个远大于任何窗口宽度的上限（`CreativeWork.titleMaximumLength = 120`）防止异常输入，
   显示层用 `displayTitle` 把历史上按 24 字预截的旧记录还原成整行。反例见「我的作品」：
   名称在写入时就被截断并持久化，于是窗口再宽也只能显示那 24 个字。

## 4. 十个页面 UI/UX 优化蓝图

### 4.1 空间拓扑与双轨导航心智
- **STUDIO 创作工坊**（配音台、音色创作、音色克隆、音色库、我的作品）：聚焦声音雕琢与文本心流，大留白（`Spacing.hero`），注入 `Color.voice` 陶土暖色，首屏 100% 留给创作任务，不显示冗余服务状态横幅。
- **ENGINE 核心引擎**（服务中枢、模型档位、运行监控、系统诊断、开发者文档）：强调确定性、低时延与高透明度，等宽数字排版，冷钛金与冷青导轨色为主基调。
- **全局状态唯一性**：侧边栏底部 `[✓ 服务已就绪 · Quality]` 是全 App 唯一的常驻全局服务状态指示器，正文仅在服务专属总览、任务受阻或长任务跃迁时按需显示置顶 `StatusConclusion`。

### 4.2 页面级重点优化规则
1. **配音台 (Dubbing Desk)**：文稿编辑器为原生 `TextEditor`，高度**跟随正文**——下限 144pt
   （`Layout.creatorComposerMinimumHeight`，静止状态看得见 3 行写作区）、上限 360pt（`creatorComposerMaximumHeight`），
   中间由正文自身高度（含一行 20pt 余量）决定，到上限为止，超出部分由原生滚动条承担；
   系统文本背景 + 系统焦点环，正文 `.body`；页脚是分隔线之内一条 42pt 高的带
   （`Layout.composerMetaRowHeight`，稿实测 42.5），带内居中给出 `n / 上限 字`（超限转红并带图标）与「清空」
   （橡皮擦图标 + 文字，与稿 `editor/meta` 一致）；
   控制条在窄窗口自动换行；生成结果条留在本页，提供播放 / 在 Finder 中显示 / 导出… / 查看我的作品。
   （2026-09-15 用户复核：不再「占满剩余高度」——那会把三行文稿拉成一屏白板。滚动条按原生行为处理，
   不隐藏、不接管滚动。2026-09-16 三度校准：区间**套在整张卡（正文 + 页脚字数行）**上，不再只套在
   `TextEditor` 上——稿量的是整卡高度，套在编辑器上会让卡比 token 高出页脚那一行。同日四度校准
   「大小高度继续优化」后改为跟随正文：离屏实测固定区间下默认 53 字文稿只占 16pt、编辑框却有 277pt，
   量测用一个同字体同行距的隐藏 `Text` 副本取一个高度值，滚动仍是原生 `TextEditor` 的行为，
   见 REDESIGN-SPEC §11.6 第二十七轮。同日五度校准「可接受滚动条、优先原生组件，但大小高度仍要优化」
   后再收静止高度：卡内固定开销 83pt（内边距 40 + 分隔线 1 + 页脚带 42）占掉下限大半，200pt 的卡只留
   117pt 正文区（≈5.9 行），故下限 200 → 160（正文区 77pt ≈ 4 行），上限与跟随规则不变，见第三十二轮。）
2. **音色创作 (Voice Design Studio)**：描述文本框为原生 `TextEditor`（130–200pt 固定区间，超出由原生滚动条承担）
   —— 本页是滚动容器、纵向提案无界，因此由 `frame(idealHeight:)` 取 160pt
   （`creatorVoiceInstructionIdealHeight`）作为确定高度。它是**嵌在 `promptCard` 面板里**的输入区
   （`SpeechRailComposerTextEditor.Chrome.embedded`）：内边距由面板给，正文与计数行之间不加分隔线
   （稿里这张卡本来就没有分隔线）；离屏实测正文顶距卡沿 20pt（稿 21）、可写区 99.5pt（稿 102.5）。
   框内一行 tertiary 引导
   （`SpeechRailComposerTextEditor` 的 `hint`）+
   卡片页脚左为计数（`n / 上限 字`）、右为「真实预览未返回前不可保存」，按 `Control.compactHeight`(28) 居中
   （比配音台的 42pt 紧一档）；再往下是琥珀色系统胶囊 chips
   （点击追加声学特征）；
   「更多设置：参考文案与保存名称」把两项折叠起来，折叠行必须整行可点（`SpeechRailDisclosureGroupStyle`，≥ `Interaction.minimumHitTarget`），
   并且与右侧主按钮**同一行**（4x 帧上折叠行文字与主按钮填充的中点重合，见 REDESIGN-SPEC §11.6 第二十轮）；
   `⌘⏎` 不再是自绘键帽：它是一段挂在按钮标签内的提示（`ButtonShortcutHint`，
   `Button.shortcutOpacity = 0.72`，对辅助技术隐藏——按钮的无障碍标签已经说明了这个快捷键，
   见 REDESIGN-SPEC §11.6 第四十八轮）。
   候选区为 2×2 网格（候选 1–4），每张卡头部按 Figma `Candidate Tile` 固定为 槽位名（Body / Medium）/ 状态胶囊 / 右对齐 seed，
   动作行为「试听或停止 + 保存为音色」，保存成功后同一位置换成「在音色库中查看」（状态胶囊已显示「已保存」，
   不留停用按钮），失败卡保持同一骨架并把波形区换成原因说明 + 重试；档位不满足时用 `ContentUnavailableView` 给出「去模型页切档」。
3. **音色库与我的作品 (Catalog & Archive)**：两页都是「系统 `List` + 右侧 `.inspector`」详情面。音色库顶部为 `.searchable`（名称与描述）与来源分段控件（全部/系统/我的），行内只有名称、来源徽标、一行描述、可用性说明和行内试听；试听文案、seed、变体、模式、使用次数、关联作品、描述全文与「重命名/编辑描述/删除」都在 Inspector；头部只有「新建音色」（**整页唯一入口**，列表页脚不再重复）与详情面板开关。我的作品顶部为 `.searchable`（标题）与时间排序，行内是标题、音色、创建时间、等宽时长和行内播放，次动作（导出 `⌘E`、在 Finder 中显示、重命名、删除）走行内「⋯」与右键菜单，导出另有 File ▸ ⌘E；头部不再重复一遍只对选中行生效的同一批命令（REDESIGN-SPEC §11.6 第四十九轮）。删除作品会连同本机音频文件一起移除，因此必须有破坏性确认。
   > 2026-09-16 两块侧边栏收成一个结构声明点（`SpeechRailInspectorPanel`，§11.6 第五十四轮）：
   > 身份带 / 试听 / 取值 / 固定动作区四段，段间整宽 hairline，动作区在 `ScrollView` 之外。
   > 音色库原本就是这条（第四十五轮），我的作品此前是 `SectionHeading` + 缩进 `Divider` +
   > 动作散在正文里，本轮归位：试听拿到与音色库同形的嵌套面板，`导出…` 作为主按钮、
   > `在 Finder 中显示 / 重命名 / 删除` 作为次级行压在最底部——与行内「⋯」/右键菜单同源，
   > 破坏性动作不再被正文推走。同一轮把试听面板的底色从 `Color.field`（与栏目同色、
   > 只剩一圈描边）改回 token 注释里写明的 `Color.recessedField`。
   > **动作区搬出 `ScrollView` 的连带约束**：动作区里若放带竖直弹性的东西（例如
   > `SpeechRailDisclosureGroupStyle` 标签里原先垫的那层 `Color.clear`），它会和
   > `ScrollView` 平分栏目高度；该样式已按此收口（§11.6 第五十四轮 ④）。
4. **服务中枢 (Service Core)**：四要素状态结论大面板（图标 + 结论标签 + 影响范围 + 单一主动作），并列展示 ASR 词级时间戳、VoiceDesign 并发与 FluidAudio 匿名分人能力矩阵。
5. **模型档位 (Model Profiles)**：三档横向比对机架，模型准备/下载采用确定性 `OperationBar`（MB/s 速度、预计时间、SHA256 校验进度、安全回退确认）。
   制品列表是四列表格（制品 / 量化 / 文件 / 校验），行内只保留一眼要量的字段——来源、目标档位与使用状态在右侧 Inspector；
   校验列取值用 `statusPresentation.title` 的原样输出（已验证 / 未下载 / 校验失败 / 下载中 / 状态未知）。
6. **运行监控 (Telemetry)**：时间序列是页面主对象，占满整宽并位于首位，但**先说人话、再说口径**（§11.6 第六十三轮）。
   页首一句话说明这一页看什么（「服务最近在做什么、快不快、占多少内存」），顶部是时间窗分段控件（1 分钟 / 5 分钟 / 本次会话）。
   首屏六个数字只答用户会问出口的问题：正在处理、语音合成（次数 + 音频时长）、语音识别（次数 + 音频时长）、合成耗时、识别耗时、失败请求；
   **「请求」只数语音接口**（`/v1/audio/speech`、`/v1/voices/previews`、`/v1/audio/transcriptions`），
   不含 App 自己每 5 秒的控制面轮询——本机实测控制面占累计请求的 97.6%。
   口径仍按 Prometheus / Grafana 读法计算：计数器取窗口增量（`increase(...)`），直方图取窗口均值（`increase(sum)/increase(count)`），
   服务端 lifetime 均值与累计计数器不作为「当前状态」展示；`rate` 与累计口径保留在开发者详情与复制摘要里。
   无数据（样本不足、计数器回退、指标缺失）显示「—」并说明原因，0 次与「读不到」不用同一个符号；
    并发与时延是**一张** Swift Charts 图：一根横轴、一个绘图区、**纵轴两套刻度**——面积读左轴（请求量，整数刻度）、
   折线读右轴（耗时毫秒，刻度取 1 / 2 / 2.5 / 5 × 10ⁿ 整档，两者用一个线性比例对齐）。
    单位不同不能共用一根刻度，但也不需要两张图（2026-09-16 用户复核「合并到一个坐标系」，§11.6 第六十五轮）。
    图上的点是相邻数据点之间的窗口值，网格线用系统分隔色（只画左轴那一套）、标签取 `secondary`(11)；
    运行组件**由卡自己画表**（列头 `captionMedium` + 行 `Callout` + 1pt `Divider`，
    第一列定宽 `Layout.monitoringWorkerNameColumnWidth` 380、行高 `List.compactRowHeight` 42；
    不再用系统 `Table`，它的底色、隔行底纹与列分隔线都不在 token 里，§11.6 第六十八轮），
    组件名用用户语言（服务报的 `streaming` 映射为「实时语音」）；
   内存与并行、服务能力、不同音色类型的合成耗时、服务启动以来的累计统计收进默认收起的「更多细节」卡（渐进式披露）。
   没有数据时用 `ContentUnavailableView` 说明「这不代表服务异常」。
7. **系统诊断 (Diagnostics)**：递进式结构化排障，异常项配备一键修复动作与脱敏排障报告复制。
   详情卡的结构固定为「结论胶囊 + 时间 → 标题 → 这项检查确认 / 对当前服务的影响
   → **唯一动作**（检查通过时换成「当前项目状态正常。」）→ 分隔线 → `开发者详情` 折叠区
   （检查标识 / 安全技术结果 / 结果 / 建议动作 / 模型相关检查的受管制品与完整性 / 运行档位 /
   配置档位 / 服务状态）→ 编号修复步骤」；那个动作是整宽主按钮，文案是目的地
   （`打开模型管理` / `查看服务状态` / `复制脱敏报告`），所以重跑预检只在页头有一个次按钮
   （`重新运行预检`），详情卡里不重复（REDESIGN-SPEC §11.6 第二十六轮）。
   头部（窗口工具栏）只放「复制脱敏诊断报告」这一件跨页要用的动作；重新运行预检在页头次按钮与
   空态主按钮上，重新读取走 View ▸ `⌘R`（§11.6 第四十九轮）。

8. **音色克隆 (Voice Clone)**：四张卡按顺序出现（提词稿 → 录制 → 回听与核对 → 注册），未走到的
   步骤不预先铺开——这是本页的渐进式披露形态。提词稿是服务端下发的 4 段官方文本 + 「自己写一段」，
   文本与时长提示都来自服务端，应用不内置文案；正文槽取 `Typography.promptScript`（= `.title`，
   与稿 `Title / Page` 同档），且五个选项**共用一个固定外框** `VoiceClone.scriptBodyHeight`——
   套在两种形态之外、两形态同用 `Spacing.md` 内边距（编辑器左内边距再减
   `VoiceClone.editorLineFragmentPadding`(5)，抵掉原生编辑器自带的行片段内边距），所以只读稿与
   自写编辑器的外框、正文原点逐点相同，换稿时卡片不跳、正文也不跳
   （REDESIGN-SPEC §11.6 第六十六、六十七轮）；录制卡的电平是 `AVAudioRecorder.averagePower`
   的真实读数（20Hz，与波形进度同一节奏），到 `VoiceClone.maximumSeconds`(45s) 自动停止并说明原因，
   录到 `VoiceClone.silenceHintSeconds`(4s) 仍没有越过 `VoiceClone.signalFloorLevel` 时直说
   「麦克风没有收到声音」（只解释现象，不改录音行为）；`RecorderBox.stop(upTo:)` 让收尾只收
   「这一代及更早」的录音器，紧接着按下的重录不会被上一次的收尾停掉；
   采集链关闭 AEC / AGC / 降噪——这一页要的正是用户本来的音色。回听卡的波形来自这段录音自己的
   包络，播放进度取播放器真实的 `currentTime / duration`，动作是 `播放 / 重录 / 删除`——删除
   一段还没注册的临时录音不需要确认框（磁盘上的临时文件在收下时就删了，内存里这一段是唯一副本，
   而「实际朗读的文本」是输入、不跟着删）；下面是「实际朗读的文本」输入槽，默认填
   选中的提词稿、可改成真正说出的内容。注册卡给出名称、「先检查参考音频」（`validate`）与
   「注册音色」（`clone`）：服务端边界（2–45s、≤15MB、`ref_text` ≤2000、名称 ≤32）在本地先量一次，
   避免为一次上传才发现问题。档位门禁读 `/v1/models` 的 `supports_clone`——`false` 时给「去模型管理
   切档」，还没读到（`nil`）不拦；麦克风被拒时给的是「打开系统设置」这一条路，不是重试按钮。
   录音只落系统临时目录，应用收下后立刻删文件、字节只留内存，注册成功后连内存也放掉。
9. **开发者文档 (Developer Docs)**：顶部一条接入信息带（服务地址 / 鉴权 / 运行档位 / 已发布能力 +
   「复制接入信息」），下面一张「目录列 + 正文列」的卡：8 个主题，一次只展开一个。目录列是系统
   `List(selection:)`（方向键与选中语义归系统），正文按 block 渲染（段落 / 要点 / 端点 / 代码块 /
   注意），代码块与接入信息都能一键复制。内容纪律：每条事实都要指回 `contracts/` 或 `docs/users/`，
   不写服务端内部（worker、队列、资源治理、模型路径），数量与取值写「契约说多少」；应用内这一份是
   入口，完整版仍在仓库文档。

> 2026-09-16 新增上述两页（第 8、9 条，REDESIGN-SPEC §13）：`AppRoute` 因此到 10 个一级页面，
> `⌘1–⌘9` 与 `⌘0` 按 `AppRoute` 顺序一一对应直达键；本页目录列**不**进 §3.2 第 5 条的选中例外，
> 仍用系统选中态。

### 4.3 真实能力条件渲染与脱敏双轨隔离
- **真实能力门禁**：波形预览、回退操作与端口修复基于后端实际能力条件展示，未就绪时优雅降级为静态说明。
- **脱敏双轨隔离**：「我的作品」允许查看创作者自有的完整输入文本；「开发者 Inspector」严格执行脱敏协议，仅展示 Request ID、时延、Token 统计、脱敏 Worker PID 和会话级匿名标签（`speaker_0`），严禁暴露 Base64 音频、实名身份或绝对系统路径。

## 5. 验收清单

- [x] App target 的最低系统版本为 macOS 26.0，并使用系统 Liquid Glass 结构能力（2026-09-13 Debug build 已验证）。
- [x] App 未通过自绘根背景阻断 scroll edge effect；玻璃只用于窗口/导航层，内容和 Inspector 使用统一内容表面（2026-09-13 代码审查已验证）。
- [x] 所有 App 页面主要产品间距、尺寸、颜色和字体从 `SpeechRailDesignTokens` 读取；零间距仅用于 Divider/列表拼接等结构性布局。
- [x] Logo 设计基因（形、质、光、色）已完整解构并落盘至 §1.1。**v2 收敛后**（REDESIGN-SPEC §5.1）
  只有色彩基因进入运行时契约：`Color.rail`（钢轨冷青）与 `Color.voice`（真空管琥珀），
  形与质按「材质交还系统」的决定不再映射为 token；§1.1 因此是历史解构，不是当前实现契约。
- [ ] Light、Dark、Increase Contrast、Dynamic Type 和 Reduce Motion 均有 UI 验证；当前只完成代码/构建检查，尚未完成桌面人工矩阵。
- [ ] VoiceOver 可按“导航 → 页面说明 → 主操作 → 状态详情”的顺序访问；图表、档位和 DisclosureGroup 语义已接入，尚未完成桌面 VoiceOver 实测。
- [x] 页面高频动作已提供 toolbar、菜单栏或键盘路径，不依赖 hover；2026-09-13 UI tests 验证控制台、设置和主要页面入口。
- [x] 音色创作、模型下载、profile 应用、服务启停的边界在 UI 文案和确认动作中可见；模型下载与档位应用使用独立按钮和确认框。
- [x] 页面身份统一走 `PageIdentityToolbarItem` + 单行 `WorkspaceTitleLockup`（页面名只在工具栏出现一次，
  正文不重复标题；**`.navigation` 槽 + 槽内左对齐**，八路由与最小窗口实测同一点 x=252），
  头部动作统一走 `PageActionButton` / `PageActionsMenu`（不再有「更多操作」文字标签），
  导航 route icon 集中管理；2026-09-16 Debug 构建通过（`/tmp/sr-build-mine`），桌面走查未做。
- [x] custom clickable rows/cards 使用共享按压、hover、focus、disabled 与 cursor 规则，静态表面不再伪装成可操作区域；2026-09-13 代码审查已验证。

## 6. 当前实现与验证矩阵

| 范围 | 实际结果 | 验证时间 |
|---|---|---|
| App Debug 构建 | 历史 `BUILD SUCCEEDED`，Xcode 26.6 / SDK 26.5，目标为 `arm64-apple-macos26.0`，0 条新增 warning；未运行测试 | 2026-09-15 20:33 |
| App Release 构建（当前工作树） | 本次文档同步的最小构建检查未通过：未提交的 `SessionDesignSurface.swift:1083` 报 `Extraneous '}' at top level`；该文件不属于本次文档改动，未擅自修改 | 2026-09-20 |
| Swift 单元测试 | 本轮未运行；此前历史记录不作为本轮证据 | — |
| UI 测试 | 本轮未运行（AGENTS.md 硬约束：未经当次明确授权不运行 UI 自动化） | — |
| 设置单场景复核 | 本轮未执行 | — |
| App 安装 | 此前独立 Release 构建已安装 `2.7.0 (19)`、`arm64`、`LSMinimumSystemVersion=26.0`，ad-hoc 签名与嵌入 XPC 通过，路径为 `~/Applications/SpeechRail.app`。`mdfind` 还会返回两个预先存在的 DerivedData Debug bundle，不能再把 bundle ID 搜索结果当成唯一安装实例；该制品不等同于当前未提交工作树 | 2026-09-20 |
| 深色（离屏） | 八页深色扫查、页面底 `#1E1E1E` / 卡片 `#171717`、`StatusTone` 与系统语义色四外观逐字节相同；材质观感仍需真机 | 2026-09-16（§11.6 第三十七轮） |
| Increase Contrast | **离屏不可测**：Swift 常量 `.accessibilityHighContrastAqua` 的 rawValue 少了 `HighContrast`，`NSAppearance(named:)` 静默回退成普通 Aqua；系统资源已改名 `AquaAX.car` / `DarkAquaAX.car`，旧名解析出的是浅色混合体（`hc-*` 渲染不作证据） | 2026-09-16（§11.6 第三十七轮） |
| 动态字体 | macOS 上 `.dynamicTypeSize` 对系统文本样式不生效（`body`/`title`/`caption` 五档字号墨迹逐像素相同）；落地口径改为「系统文本样式 + `minHeight`」并在真机改系统文字大小走查 | 2026-09-16（§11.6 第三十七轮） |
| 桌面视觉矩阵（余项） | 待用户手工走查：本机无 UI 自动化授权，Reduce Motion、VoiceOver、真机深色材质与系统文字大小均未实测 | — |
| VoiceOver 实测 | 尚未完成 | — |

> 2026-09-15 22:5x 用户复核轮（REDESIGN-SPEC §11.6 第五轮）：输入区改为自量高且正文装得下时不显示滚动条、
> 折叠行改为整行命中、运行监控改为 Prometheus/Grafana 的窗口口径并把密集区块收进渐进式披露。
> App Debug 构建与 `build-for-testing` 通过；**滚动条与命中区域的观感仍需人工走查**，
> 本轮未运行测试与 UI 自动化。
>
> 2026-09-15 23:0x 用户改判（§11.6 第六轮）：滚动条可接受、优先原生组件。输入区去掉自量高与
> `scrollIndicators` 分支，只保留 `minHeight`/`maxHeight` 高度区间；折叠行命中与运行监控口径不变。
>
> 2026-09-15 23:2x §5 / §8 / §9 逐项核对（§11.6 第七轮）：材质、圆角、颜色、字体、间距、图标
> 六项均以源码取证。修正 1 处颜色语义（菜单栏「操作进行中」状态点由琥珀改为 attention）、
> 3 处未受 Reduce Motion 保护的 `withAnimation`（运行监控与诊断页的复制回执）、波形脉冲改为显式
> `!reduceMotion`。删除 4 个无引用且与 §5.7 冲突的 token：`Control.iconSize`、`Control.toolbarIconSize`、
> `Control.sidebarIconSize`、`Typography.emptyStateGlyph`。仍缺：桌面视觉矩阵与 VoiceOver 实测。

> 2026-09-15 23:4x 高度取值与保存后入口（§11.6 第十一轮）：输入区高度改用原生
> `frame(minHeight:idealHeight:maxHeight:)`，滚动页面下有确定高度（配音台 420pt / 音色创作 200pt）；
> 音色创作候选保存成功后动作行改为「在音色库中查看」；`AppModel.playWork` 开始播放时清掉
> `playingVoiceID`，避免音色库残留「正在试听」状态。App Debug 构建与 `build-for-testing` 通过，
> 未运行测试与 UI 自动化。

> 2026-09-16 00:1x 逐屏文案互查（§11.6 第十二轮）：把稿里八个屏幕的 215 条界面文案抽出来逐条在
> 应用源码里找。修掉 4 处文案差异（配音台「清空」补橡皮擦图标；描述框补引导行、
> 页脚改「真实预览未返回前不可保存」；折叠行改「更多设置：参考文案与保存名称」），
> 并在稿侧改回 2 处（能力卡说明用应用的「按当前运行档位…」；候选 3 的保存态改为「在音色库中查看」）。
> 稿的 `promptField` 130pt 属静态样张近似，未追。构建与 `build-for-testing` 通过，`code.js` 已重新生成。

> 2026-09-16 00:3x 证据来源更正（用户指出 `figma-kit/main.js` 只是喂给 Figma 的生成脚本，不是设计来源）：
> 逐字核对改用用户导出的帧图（`~/Downloads/speechrail-screens-4x/`）为准，并列出「保留差额」表
> （静态样例值 vs 运行时值、按 worker 的时延表不可得等）。运行监控按 `/metrics` 真实的
> `voice_class` 维度补「按音色类别」面板（§11.6 第十四轮）。

> 2026-09-16 01:0x 帧的代次判定（§11.6 第十五轮）：那批帧图导出时间 2026-09-15 22:04，
> 比当前生成脚本旧一代（诊断检查项、设置页签行、监控表列数、音色库排序标签都是旧样例）。
> 五页剩余页面（音色库 / 我的作品 / 诊断 / 菜单面板 / 设置）的应用实现与当前脚本逐项一致；
> 脚本侧补了两处（来源徽标每行都画、作品页补排序控件），`code.js` 已重新生成
> （SHA-256 `97cd825b41718ec5704e6438cceea13713a24ef209bae9cc2fbf0d539d8ba3e2`）。
> 即：源码侧校准已无待办，剩下的是「重新安装本机 App + 桌面走查/无障碍矩阵」这类需要用户在场的事。

> 2026-09-16 输入区高度标定（§11.6 第十七轮）：用户把第五轮的第一条重新定调——**滚动条可接受、
> 优先原生组件、只优化大小高度**。本轮不动滚动行为，只量准改对：4x 帧实测配音台输入卡约 567pt
> （占满剩余高度）、音色创作描述字段 130pt。应用侧把高度区间**从 `TextEditor` 移到整张卡**上
> （token 才与稿的整卡口径对齐，否则卡比 token 高一行约 35pt），并把配音台 320–420 收到 280–360
> （常规窗口停在 360）、描述框 160–320 收到 130–200（理想 160）。生成脚本同步为 360 / 160。
> 文稿框是否仍偏大、描述框够不够写属桌面走查项——两个数值各只有一对 token，走查后单点可调。
> 同轮续做页面级间距：八页 4x 帧实测块间距 19–22pt（即 20pt），与生成脚本 `gap: 20` 一致，
> 应用此前混用 `lg`(24) 与 `sm`(12)。新增 `Spacing.gutter = 20` 并统一 5 处页面栈间距；
> 诊断两栏按帧（15pt 带）改用 `md`(16)。卡片内边距（稿：页面卡 18 / 组件卡 12–14，应用 12/16/24 混杂）
> 中，两张输入卡已按帧对齐到 `md`(16)：正文距卡沿从约 14pt 提到 16pt（稿 20pt），
> 配音台控制卡取 16/12（与稿精确一致），页脚信息行同步跟随；其余页面卡留作逐卡对账的下一轮。

> 2026-09-16 卡片内边距逐卡对账（同一轮续做）：把六个页面的卡片区域整段取样后发现稿只有一档——
> 首个字素都在距卡左沿 278.2–282.0pt 处（卡左沿 261），即**卡片内容内边距 18pt**，内容卡、
> 表头、表行、列表行一致（脚本 `card()` 默认 `pad: 18`，表卡 `pad: 0` + 内层 `padX: 18`）。
> 应用此前分 12/16/24 三档，本轮新增 `Layout.cardInset = 20`（距稿 2pt 残差、与页面级块间距同值）
> 并统一：两张输入卡的正文/提示/页脚、`promptCard`、六个页面内容卡。稿里显式写死的工具栏式卡片
> （配音台 `composer` 16/12）不套这一档；sheet 不在稿内、保留原值。（这里写的「设置窗口不在稿内」
> 只指八个主页面帧——设置窗口在 `05 Menu & Settings` 里，第三十三轮已按该帧对齐，见下。）

> 2026-09-16 字号与图标标定（§11.6 第十八轮，方法与间距同源：Foundations 变量表 + 帧上 ink 高度）：
> 稿的标题只有一档 `Title / Page` 20pt Semi Bold（四处实测 ink 18.25–19.0），应用此前拆成
> `.title2`(17) 与 `.title3`(15)；系统样式无 20（本机实测 title1 22 / title2 17），统一取 `.title`(22，+2pt)。
> `StatusBanner` 增加 `Kind`：`.conclusion`（状态底色 + 1pt 状态描边 + 26pt 图标 + `Title / Page` 标题，
> 服务状态页）与 `.standard`（面板底色 + 17pt 图标 + `Heading / Section` 标题，行内反馈与空态）。
> 行内文字按稿的行样式归位：10 处 `Typography.label`（12 Medium，稿里没有这一档）拆到 `callout`(7)
> 与 `bodyMedium`(3)。稿的手挑 tint 变量与「居中无动作」空态版式保留应用做法，已在 §11.6 记录。

> 2026-09-16 输入卡页脚带与计数行（§11.6 第十九轮）：`▸ 配音台.png` 上分隔线到卡底是 **42.5pt**
> 的固定带（与 `compactDividerHeight` 同值），应用此前只给上下 `micro`(4) 内边距、约 21pt。
> 共享组件新增 `Layout.composerMetaRowHeight`（默认 42），页脚用 `minHeight` 在带内居中；
> 音色创作显式传 `Control.compactHeight`(28)（整卡仍是 160 = 稿字段 130 + 提示行 + 元信息行）。
> 两张卡的计数行字面按帧改成 `n / 上限 字`（斜杠两侧有空格）。

> 2026-09-16 字号档位标定（§11.6 第二十轮）：量的是**字**——稿的 `Foundations` 有完整文字样式表，
> 应用有几处落在相邻档位上。新增 `Typography.captionMedium`（稿 `Caption / Medium`：状态胶囊、
> 我的作品列头、制品表列头）与 `Typography.technicalValue`（稿 `Callout` 12 + 等宽数字：
> Inspector 取值、制品表量化/文件列）；Inspector 取值行标签 `caption` → `callout`。输入卡相关：
> 页脚计数行 10 → 11（配音台 secondary #6E6E73、音色创作 tertiary #A1A1A6）、提示行 10 → `callout`、
> 控制条补出「音色」标签并把「语速」取值提到 `bodyMedium`；音色创作的折叠行与键帽、主按钮改成
> **同一行**（帧上两者中点重合）。运行监控原生 `Table` 的表头/行字体交给系统（差 1pt 不追），
> 设置窗口与开发者折叠区不在稿内、保留原值。验证与缺项同第十九轮：类型检查 0 error，
> `xcodebuild` 因 Xcode 27.0 许可未接受仍不可用，未运行测试与 UI 自动化。

> 2026-09-16 控件高度与卡片带（§11.6 第二十一轮，帧对账 + 本机**离屏**量测系统控件）：
> 离屏实测（`ImageRenderer`，不开窗口）`.regular` 24 / `.large` 28 / `.extraLarge` 36，
> 且 `.controlSize` **不改变标签字号**；稿的主按钮 34、次按钮 30。于是共享的
> `SpeechRailButtonAppearance` 改为：主按钮 `.extraLarge`(36)、次按钮/危险按钮 `.large`(28)、
> 安静按钮保持 `.regular`（无填充，差的是命中区）；配音台/音色创作两颗生成按钮与配音台音色胶囊
> 同步（胶囊 30 → `.large` 28）。卡片带：`CardHead` 按稿分两档（有 `detail` padY 16 = 稿 `head`；
> 只有标题 padY 12 = 稿 `listHead`），`runtimeRow` 与制品表行 padY 8 → 12（补回稿的 40pt 行带），
> 制品表列头/行的左沿 8 → 16（与同卡 `CardHead` 对齐）。状态胶囊与键帽本来就是 17 ≈ 稿 18，不动。
> sheet、确认框、空态不在稿内，不动。系统行高比稿紧约 3.5pt/行，不逐条补 `lineSpacing`。
> 同轮还把制品表的列几何按稿改对（稿 `COLS = [440, 200, 140]` + 校验列吃余量、列间距 0）：
> `ArtifactColumnGrid` 先按稿排、窄窗口用 `ViewThatFits` 退到收窄版；离屏量测显示 1440 宽窗口下
> 三列列沿与帧逐列重合到 1.5pt 内。此前「四列挤在右侧」的版本最右一列与稿差约 250pt。

> 2026-09-16 输入区的「嵌卡」形态（§11.6 第二十二轮，用户三度校准：滚动条可接受、优先原生组件、
> 大小高度仍要优化）：滚动行为不动，滚动条继续由原生 `TextEditor` 承担。本轮把
> `SpeechRailComposerTextEditor` 的**归属**做成显式参数 `Chrome`——`.card` 自带 `Layout.cardInset`
> 内边距与页脚分隔线（配音台，输入区自己就是一张卡），`.embedded` 内边距由外层卡片给、不加分隔线
> （音色创作，描述框嵌在 `promptCard` 面板里）；页脚的水平内边距收进组件，调用点不再各写一份。
> 理由与量测：4x 帧 `▸ 音色创作.png` 的卡在正文与计数行之间**没有**分隔线（y=270–320 全为纯白），
> 而 `▸ 配音台.png` 在 y=661 有一条 220,220,224 的分隔线；改前两页共用 `.card`，音色创作的正文
> 被面板与输入区各内缩一次（距卡沿 40pt，稿 21pt）、可写区只有 67.5pt（稿 102.5pt）。改后离屏实测
> 20pt / 99.5pt。区间 token 本身不变：配音台 280 / 340 / 360（确定提案 → 取 360），
> 音色创作 130 / 160 / 200（滚动页的 `nil` 提案 → 取 160）。

> 2026-09-16 列表与档位卡条带（§11.6 第二十三轮，帧对账 + 一条证据边界）：
> `ImageRenderer` **不渲染** `List` / `ScrollView` / `TextEditor`（三者都出系统占位块），
> 这类原生容器**内部**的行高与内边距无法离屏量测，只能「代码声明对稿」。据此改了三处：
> ① 档位卡 `spec` 行距 `micro`(4) → `xs`(8)（稿 `spec` gap 6 + `Callout` 行高 17.4 = 行距 23.4，
> 帧实测 24 / 22.25；应用的 `callout` 行盒 15，配 8 得 23）；② 作品列表头 padY `xs`(8) → `sm`(12)
> （稿 `cols` padY 10 + `Caption/Medium` 13.5 = 33.5，帧 34；8 给 29、12 给 37）；
> ③ 三条页面列表行（音色库 / 我的作品 / 诊断）统一显式 **padX 16 / padY 12** 并
> `listRowInsets(EdgeInsets())` 清零，行高变成确定的 35 + 24 = 59（稿 `row` 同值，帧行带 63–64）。
> **侧栏不变**：稿的侧栏项是 padX 8，`List.rowHorizontalPadding`(8) 只留给侧栏。
> 服务状态能力行帧 44 / 应用 41（4pt 节奏里最近值）与运行信息行 40 保持不动。
> 验证：类型检查 0 error、`git diff --check` 干净；① 有离屏复刻量测，② ③ 的最终行高待桌面走查。

> 2026-09-16 原生控件的真实几何（§11.6 第二十四轮，`NSHostingView` 量测 + 运行监控字号）：
> `ImageRenderer` 不渲染 `List` / `Table` / `ScrollView`，故改用 `NSHostingView` 把视图挂起来、
> `layoutSubtreeIfNeeded()` 后遍历内部 `NSTableView`（**不开窗口、不接管前台**）。本机实测系统
> `Table`：`headerView.height` = **28**、`rowHeight` = **24** —— 应用自己的 `tableHeight(for:)`
> 写的是 `36 + 26n`，四行多留 16pt 空白，已改为 `28 + 24n`（运行监控两处 Table 共用）。
> 同法确认 `List` 的行高在无窗口环境里不按内容布局（内容 90pt 的行仍报 24），所以 **List 行高
> 只能靠桌面走查**。运行监控字号按帧归位：图表图例 `caption`(10) → `secondary`(11)（帧 ink 10.5）、
> 坐标轴标签由手挑 `.system(size: 12)` → `secondary`(11)（稿的折线图 SVG 用 font-size 11；
> 同时消除手挑字号，§3），§7.6 的「标签 12pt」按帧改正为 11。帧 `workers` 的手画表（表头 32 /
> 行 39）与系统 `Table`（28 / 24）的差异记录在案：本页按 §7.6 用系统 `Table`，不换成手搭网格。

> 2026-09-16 一致性复查与量测边界（§11.6 第二十五轮，本轮无代码改动）：机械项全过——
> §9「固定 height 全改 minHeight」（全仓 15 处固定高度都是图表 / 原生 Table / 分隔线 / 弹层 / 隐藏占位，
> 没有文字容器）、§6.3 键盘命令（`⌘N`/`⌘E`/`⌘⌥I`/`⌘1–8`/`⌘?`/`⌘⏎`/`空格` 均可达）、结论面板与页头几何
> （帧 83.75 / 标题 ink 19.0 等）都与应用一致。两条边界一并记下，避免以后重复试：**离屏只能拿几何、
> 拿不到像素**（`NSHostingView` + `cacheDisplay` 出来是空白画布）；**`List` 行矩形在无窗口时读不到**
> （行视图不实例化），所以列表行高必须桌面走查。

> 2026-09-16 模型页动作行的位置（§11.6 第二十六轮，帧对账）：4x 帧 `▸ 模型.png` 的纵向条带是
> 档位卡 134.00–299.75 → **动作行 320.00–353.75** → 制品卡顶边 374.00，两张卡之间只放一行 34pt 的
> 动作，上下各 20.25pt（= 页面级 `Spacing.gutter`）。应用原来把动作放在 `selectedProfilePanel` 的
> 最后，要滚过整张制品表才看得见，已移到档位卡之后、制品卡之前（页面栈间距同时由 `lg` 24 改为
> `gutter` 20，面板内边距由 `lg` 改为 `Layout.cardInset`）。同轮按帧改了三处细节：主按钮图标
> `arrow.down.circle` → `tray.and.arrow.down`（帧是托盘 + 下箭头）、次按钮「应用此档位」去掉
> `checkmark.circle`（帧里这个按钮 81×30pt、内部正好 5 个字形簇，没有图标）、删掉「下一步」小标题
> （帧上没有，页头副标题已说过同一句话）。就绪结论行移进面板的状态块，长任务 `OperationBar` 移到
> 动作行下方（§6.4 触发页内联）。同轮还按生成脚本收了诊断详情卡的动作与顺序，见下一条。

> 2026-09-16 诊断详情卡的动作与顺序（§11.6 第二十六轮续做）：**这一页以当前生成脚本为准，
> 不以 `▸ 诊断.png` 那张旧帧为准**——那张 2026-09-15 22:04 的帧上还写着「技术上下文」与
> `artifact_key / verify_status`（第十五轮判定的旧一代），当前脚本已按第四轮改成应用的真实文案。
> 按脚本改了三处：动作从卡片底部的「下一步」小节提到结论与影响之后（整宽主按钮、图标改
> `tray.and.arrow.down`），删掉那颗重复的「重新运行诊断」主按钮（§7.8 的页头已经有「重新运行预检」），
> 「开发者详情」折叠区移到「修复步骤」之前；另外删掉重复的「检测结果」一行——它与折叠区里的
> 「安全技术结果」是同一句话（`safeTechnicalResult(for:)` 就是 `resultMessage(for:)`）。
> 同轮还按 §7.6.1 的密度约束收了两处、**一条事实没删**：「建议动作」从首屏进折叠区；
> 整块「模型证据」（分隔线 + 小标题 + 说明 + 三行）降为折叠区里的「受管制品」「完整性」两行，
> 第三行「当前服务」与折叠区已有的「运行档位」同值合并。首屏还剩「这项检查确认」一行
> （与左侧列表副标题同源，但它是唯一解释「这一项在确认什么」的人话），要压掉只需删一行。
> 模型页同轮补了一处：两个按钮的间距由 `sm`(12) 改 `xs`(8)——脚本是 `gap: 8`，4x 帧在按钮
> **中线**上量是 8.25（顶边附近会被圆角吃掉约 4.5pt，量成 9.75）。

> 2026-09-16 输入卡高度跟随正文（§11.6 第二十七轮，用户第四度校准「可接受滚动条、优先原生组件、
> 大小高度继续优化」）：`SpeechRailComposerTextEditor` 新增 `HeightPolicy`，配音台文稿用
> `.contentDriven(minimum:maximum:)`（200–360pt，中间由正文高度 + 一行 20pt 余量决定，到上限后
> 由原生滚动条承担），音色创作描述框仍用 `.band`（130–200pt，滚动容器取 `ideal` 160pt）。
> 量测用同字体、同行距、同宽度的隐藏 `Text` 副本 + `onGeometryChange`，只取一个高度值；
> 滚动仍是原生 `TextEditor` 的行为，不隐藏滚动条、不加动效。`creatorComposerIdealHeight`（340）
> 删除，`creatorComposerMinimumHeight` 280 → 200。离屏实测（NSHostingView，不开窗口）：1 行文稿
> 卡 200pt（改前 360）、8 行 255pt、16 行触到 360pt 上限并出现原生滚动（doc 316.5 > clip 277）；
> 1440 × 900 与 1120 × 720 两档整页渲染一致，音色创作页布局无回归。
> （区间里的下限在第三十二轮由 200 收到 160，见下一条。）

> 2026-09-16 控制条几何与运行监控卡片内边距（§11.6 第二十八轮，帧矢量尺子 + 浅色离屏像素扫描）：
> 配音台控制条按 4x 帧归位——音色胶囊总宽对齐 **160**（`creatorVoicePickerWidth` 180 → 134，
> 因为该 token 是标签内宽，系统次按钮还要各加约 13pt）、语速滑块从**拉满整行（实测 748pt）改为
> 定宽 132pt**（`creatorSpeedSliderWidth` 120 → 132），当前取值 `1.0x` 从标签行右侧移回控制行、
> 紧跟滑块（稿 `speedRow` 的排法）。两条保留的偏离：`Stepper` 是 §7.1 要求但帧没画；
> 按钮宽度一律按内容自撑（只钉高度），帧上写死的宽度不跟。
> 运行监控图表卡与「逐指标明细」卡的内边距由 `Spacing.md`(16) 归到 `Layout.cardInset`(20)（稿 18）。
> 同轮确认图表卡表头与图之间**没有**分隔线（与脚本一致）。探针新增能力：换上任一 fixture 诊断客户端
> 后，服务四页可离屏渲染出真实布局并逐像素扫描（仍不开窗口、不接管前台）。

> 2026-09-16 页头副标题的最小高度（§11.6 第三十轮，离屏量测 + 一处真修复）：`PageScaffold`
> 页头副标题的 `.fixedSize(horizontal: false, vertical: true)` 会在「未定宽度提案」下按极窄宽度测量，
> 一句二十来字的说明因此报出三百多点的理想高度，把**整页的最小高度**抬到声明的最小窗口高之上。
> 离屏实测各页内容最小高度（`NSHostingView`，读 `.inspector` 生成的 `SystemSplitView` 高度）：
> 配音台 **760**、我的作品 **889**、诊断 **664**，而 `Layout.windowMinimumHeight` 是 720；
> 宿主比该下限矮时 SwiftUI 按底对齐、**页头被裁**（1440 × 720 实渲：标题只剩底部 4pt）。
> 修法是给这一行加 `.lineLimit(2)`（保留 `fixedSize`，常见文案仍不截断）：改后配音台 **475**、
> 我的作品 **529**、诊断 **454**，配音台空页从 379 降到宿主下限。验证：七页在 1440 × 900 与
> 1120 × 900 的逐像素墨迹区间**修前修后完全一致**，1440 × 720 与 1120 × 720 不再有页面被裁。
> 真机上的表现是「窗口最小高度被抬高」还是「页头被裁」取决于 AppKit 是否按内容最小尺寸约束窗口，
> 离屏无法区分，留给桌面走查；但页面最小高度超过声明的最小窗口高本身就是必须修的。

> 2026-09-16 配音台输入卡静止高度（§11.6 第三十二轮，用户第五度校准「可接受滚动条、优先原生组件、
> 但大小高度仍要优化」）：正文仍是原生 `TextEditor`（滚动、滚动条、焦点环、文本背景全由系统给），
> 只把**静止高度**收了一档——`creatorComposerMinimumHeight` 200 → **160**。依据是量出来的固定开销：
> 卡里内边距 40 + 分隔线 1 + 页脚带 42 = 83pt，200pt 的下限只留 117pt 正文区，一行 16pt 文稿下面
> 空着约 100pt；160pt 的卡正文区 77pt（≈4 行）。上限 360 与「跟随正文」规则不变，8 行 / 16 行的
> 卡高与滚动行为与改前完全一致（离屏实测：1 行 200→160、3 行 200→160、8 行 255 不变、
> 16 行 360 + 原生滚动不变）。稿的 `editor` 同步画 160。**未构建**（Xcode 许可未接受）、
> **未运行单元测试与 UI 自动化**、**未桌面走查**。

> 2026-09-16 设置窗口与菜单行几何（§11.6 第三十三轮，离屏量测 + 系统菜单样式确认）：
> ① 菜单栏面板确认是**系统菜单**——`App.swift` 的 `MenuBarExtra` 用默认 `.menu` 样式，
> UI 测试按 `app.menuItems["打开 SpeechRail"]` 断言；稿的 `menuPanel`（288 宽 / 5pt 内边距 /
> 圆角 12 / 行高 26）是这类面板的示意图。应用只改了一处：`Menu.rowHeight` 44 → **26**
> （离屏实测行标签固有高度 288 × 44 → 288 × 26；稿 `menuRow` = 26）：`Interaction.minimumHitTarget`
> 套在菜单行上会让菜单栏面板与每页工具栏动作菜单都变成两倍高的列表行，而菜单项的整行本来就是
> 可点区域。
> ② 设置窗口 560 × 360 → **640 × 454**（宽度对齐 §11.2 与稿；高度取三页里最高的一页，
> 切页签不跳；表单内边距 24 → 16，行卡 608 vs 稿 604）。三页自然高度用离屏 `fittingSize` 量：
> 通用 319、创作更矮、服务 454（含系统 `TabView` 33pt 页签条）。
> **2026-09-16 修正（§11.6 第五十二轮）**：这里的「表单内边距 16 / 行卡 608」量错了口径——
> 那一轮是在**没有窗口**的宿主里量的，grouped `Form` 的行没实例化，量到的是表单区边缘、
> 不是行卡边缘。有窗口的离屏实测：那 16pt 与系统 `Form` 自己的 20pt 叠起来，行卡距窗口
> 左右各 39pt、卡宽 562。现已去掉那层 padding，行卡回到系统原生的左右各 20pt（600 宽，
> 稿 608）；地板也从 `.padding` 里面移到页签内容区，铺满整个内容区（稿的内容区地板是
> `#E8E8EA`，`#F2F2F4` 只是标题栏 + 页签那条 84pt 高的系统 chrome）。
> ③ 设置行改成「标题 + 行内副标题」（稿 `controlRow/labels` 的 `gap: 3` → 新增
> `Settings.rowLabelSpacing`），说明不再另起一行——此前 grouped `Form` 会在标题行与说明行之间
> 画分隔线；顺带补上「默认语速」在稿里有、应用漏掉的说明「0.5×–2.0×，可在配音台逐条覆盖。」。
> **未构建**（Xcode 许可未接受）、**未运行单元测试与 UI 自动化**、**未桌面走查**。

> 2026-09-16 全量文案核对（§11.6 第三十六轮）：把 `figma-kit/main.js` 里 133 条界面文案
> （`text(...)` 101 条 + 按钮/分段/搜索/页头 32 条）逐条与 App 源码比对。多数「找不到」的是
> 画板样张内容与非应用页面（`Foundations` / `Archive` / 画板标题）的文案；真正属于界面的偏差
> 有三处，已按稿改回：**侧栏搜索占位符**「搜索创作和服务」→「搜索」（4x 帧上就是这两个字）、
> **运行监控「运行组件」说明带**「指标为最近样本的平均值；…」→「worker 生命周期状态；…」
> （那张卡的表列是「组件 / 状态」，原句讲的是窗口指标）、**配音失败条标题**「配音未完成」→
> 「生成未完成」（原因仍用服务端真实文案单独成行）。两处看起来像差异其实是动态拼接，已确认一致
> （监控页头副标题、作品空态）。**未构建、未跑测试与 UI 自动化、未桌面走查。**

> 2026-09-16 作品列头带高 + 预览构建（§11.6 第三十五轮）：① 我的作品的列头取回稿的
> `padY 10`（`cols` 是 `padX 16 / padY 10` + `Caption / Medium`，4x 帧带高 33.75）；
> 此前按「与下方行同为 padY 12」取 `sm`(12)，带高 12 + 13 + 12 = 37，高 3.25pt——
> 列头只有一行，不是列表行。改后 33（残差 0.75），离屏 A/B 分隔线 y=158 → **154**。
> ② 走查用的**预览构建**：Xcode 在 2026-09-16 00:51 被换成 27.0，而许可记录仍是 26.6，
> 所以 `xcodebuild` 现在被许可门挡住（根因是换版本）。绕开它：`swiftc` 按
> `Config/Debug.xcconfig`（`arm64-apple-macos26.0` / Swift 6 / `-D DEBUG`）重编译 App 可执行文件，
> 复制已安装包、替换 `Contents/MacOS/SpeechRail`、重新 ad-hoc 签名，得到
> `/tmp/sr-appbuild/SpeechRail.app`（`codesign --verify --deep --strict` 通过，load command 与
> 参照件一致）。**这不是发布件、不覆盖已安装件、未做启动验证**；要让界面走查看到当前工作树，
> 双击它即可，官方路径仍是 `sudo xcodebuild -license accept` 后跑 `scripts/macos_app_build.sh`。
> ③ 记下唯一一处「规范 ↔ 稿」正面冲突：配音台生成结果条，稿是 `surface/railTint` + 1pt
> `#2A4E57` 描边，而 §5.2「浮起层」一行点名要求「浮动的播放/生成结果条使用系统材质」、
> §5.4 已把强调色交给系统 —— 应用按规范用 `.regularMaterial`（现状），**不改**，
> 该条待用户拍板（维持规范，或改规范并把结果条定义为品牌化浮层）。

> 2026-09-16 输入卡下限复核 + 声学特征芯片（§11.6 第三十四轮）：① 第三十二轮的输入卡高度
> 用同一套离屏量测重跑——1440 × 900 下 1 行 / 3 行卡高 160（正文区 77pt，无滚动条）、8 行 255、
> 16 行 360 + 原生滚动，1120 × 720 与深浅两种外观一致；音色创作描述框正文区 101pt（稿可写区
> 102.5pt）、同样没有默认滚动条。两处仍是原生 `TextEditor`，本轮**没有新改动**。
> ② 音色创作的声学特征芯片从「灰底无描边」改成稿的**琥珀标注胶囊**：填充
> `surface/attentionTint`（`#FBEEDA` / `#3D2F16`）、1pt `accent/voice` 描边、高 22、间距 6、
> 标签 `Subheadline`、加号 13pt 图标框（墨迹 8.66）。改前灰胶囊在浅色页面里读起来像
> 「禁用 / 占位」，与 §7「chips 使用系统胶囊样式 + 琥珀语义色」一直没落地的那一项对齐。
> 新增 `Chip` 几何 token 与 `Surface.attentionTint`；离屏实测 chip 22.0 × 81.0（稿 82）、间距 6，
> 填充与描边在 sRGB 下与稿逐位相同（离屏 PNG 是 `Generic RGB Profile`，**取色前必须
> `sips --matchTo sRGB`**，否则会读到 `#FAEAD1` / `#CE630B` 这种宽色域数值）。
> **未构建**（Xcode 许可未接受）、**未运行单元测试与 UI 自动化**、**未桌面走查**。

> 2026-09-15 状态说明：设计规范升级至 v0.8.0，token 收敛（阶段 2）与逐页重构（阶段 4）已落地，
> 本文与 REDESIGN-SPEC 不再并行描述两套规范。Debug 构建已覆盖安装到 `~/Applications/SpeechRail.app`
> （旧版本存档保留），但**视觉与无障碍矩阵尚未人工走查**，因此本文件不作「已验收」结论。
>
> 2026-09-15 20:33 逐条对照审计（§5/§6/§7/§8/§9 对源码）：8 页结构、状态矩阵、键盘路径与
> `ViewThatFits` 窄窗口换行均已落地；本轮补齐 4 处偏差并删除已无引用的 token——
> 自定义行/档位行的选中与 hover 容器改为 `ConcentricRectangle`、焦点环统一为系统焦点色、
> 参考文案框由固定 80pt 改 `minHeight`（`Layout.creatorReferenceMinimumHeight`）、
> 音色徽标改用 v2 琥珀 `Color.voice`（同时获得 Increase Contrast 变体）、
> 音色创作门禁动作措辞对齐 §7.2「去模型页切档」。
> 已删除的 token：`Layout.contentMaximumWidth`、`List.selectionCornerRadius`、`Button.cornerRadius`、
> `Interaction.pressedScale`、`Motion.springTransition`、`Navigation.selectedFill`、
> `Corner.continuousRadiusRatio`、`Layout.creatorSlotBadgeSize`。
>
> 2026-09-15 20:5x 第二轮：整块 legacy 机架代码已删除——`Chassis`、`SteelAlloy`、`SteelRail`
> （含 `typealias TrackRail`）、`AcousticMaster`（含 `typealias Console`）、`ConsoleFader`、`Palette`
> 六个枚举，`SpeechRailSurfaceModifier` / `SpeechRailFieldModifier` / `SpeechRailContentSurfaceModifier` /
> `SpeechRailKnurledCapsuleModifier` / `SpeechRailSleeperDivider` 五个类型，`Corner` 枚举与
> `SpeechRailSurfaceLevel.cornerRadius`；`Surface` 只保留仍被引用的系统语义成员，
> `Navigation.selectedForeground` 收敛为 `Color.rail`（唯一强调色）。tokens 文件 975 → 465 行。
> 上述改动只经编译验证，**视觉观感仍待人工走查**。

> 2026-09-16 深色 / 高对比 / 动态字号取证 + token 合规扫描（§11.6 第三十七轮）：
> ① **探针陷阱**——`cacheDisplay` 出来的 PNG 里页面没画到的区域是**透明**的（真机由 `NSWindow`
> 提供那一层），深色下会被读成「卡片黑、页面白」。探针现在先按当前外观的
> `NSColor.windowBackgroundColor` 合成再落盘；实测深色页面底 `#1E1E1E`、输入卡 `#171717`
> （第三十一轮对自绘表面的读数因此不变）。
> ② 八页深色扫查：无漏底 / 反色 / 读不清的文字，原生控件（滑杆、分段控件、弹窗按钮）按系统深色呈现；
> 卡片表面走系统材质，材质在没有窗口时的解析值不等于真机，材质观感仍归真机走查。
> ②b **Increase Contrast 离屏测不了**：Swift 常量 `.accessibilityHighContrastAqua` 的 rawValue 是
> `NSAppearanceNameAccessibilityAqua`（少了 `HighContrast`），`NSAppearance(named:)` 静默回退成普通
> Aqua；系统外观资源也已改名（`AquaAX.car` / `DarkAquaAX.car`），旧名解析出的是浅底浅字的混合体。
> 因此 `--contrast` 渲染**不作为证据**，该项仍是真机走查项（应用侧没有可查代码，对比度交给系统语义色）。
> ③ token 合规扫描：全仓 App 源码没有写死颜色；唯一命中的 `StatusTone.color`（`Color.green/.orange/.red`）
> 与规范要求的系统语义色在浅色 / 深色 / 两个 Increase Contrast 外观下**逐字节相同** → 不算偏差，不改。
> ④ 动态字号：`.dynamicTypeSize` 在 macOS 上对系统文本样式**无效**（五种字号下墨迹像素完全相同），
> §9 该项的验收口径改为「系统文本样式 + `minHeight` + 真机改系统文字大小走查」。
> ⑤ 稿里唯一的阴影只用在系统菜单上，应用浮起层的阴影没有稿面对应值（§5.2 允许），不改。
> **未构建**（Xcode 许可未接受）、**未运行单元测试与 UI 自动化**、**未桌面走查**。

> 2026-09-16 页面列表行高结案 + 两处字号归位（§11.6 第三十七轮续）：
> ① **「`List` 行高量不出来」结案**。根因：SwiftUI 的 `List` 走 `NSTableView` 且
> `usesAutomaticRowHeights = true`，委托 `OutlineListCoordinator` 不实现 `heightOfRow`，
> `rect(ofRow:)` 只有估计值 24，没有窗口就没有行布局。改从两端取证——4x 帧扫分隔线得三页行距
> 都是 **64.00pt**（选中行填充 63.00 + 1pt hairline），应用侧按同修饰符栈离屏量得行内容 35、
> padY 12×2 → **59.00**。差额 3.9 来自**行盒**（稿 `Body/Medium` 13@150% = 19.5、`Callout` 12@145% =
> 17.4，系统样式只有 16 + 15）。处置：新增 `List.pageRowMinimumHeight = 63`，
> 音色库 / 我的作品 / 诊断三处改用它；`List.rowHeight`(44) 仍归侧栏项与折叠行的命中区。
> ② **诊断检查行说明** `caption` → `callout`（稿 `Callout`；帧上该行墨迹 12.50 vs 名称行 12.00）。
> ③ **字段标签** 6 处 `caption` → `captionMedium`（稿 `fieldLabel` = `Caption / Medium`）。
> 行距在真机上是 63 + hairline 还是 63 整，依赖 `List` 分隔线与行框的叠放关系，离屏量不到，
> 留给桌面走查；行框 63 由构造确定。**未构建官方包、未跑测试与 UI 自动化、未桌面走查。**

> 2026-09-16 配音台输入卡下限 160 → 144（§11.6 第三十八轮，用户第六度校准「可接受滚动条，
> 优先使用原生组件，但大小高度等需要优化」）：组件仍是原生 `TextEditor`（滚动、滚动条、
> 焦点环、文本背景全由系统给），只动一个 token。依据：画板上 `editor` 的 160 是**3 行**示例
> 文稿自然长出来的高度（`main.js` 该帧画两段共 3 行），不是「一行文稿的高度」；滚动条既已被
> 接受，下限只需保证静止状态看得见 3 行写作区——3 × 20pt 行距 + 卡内固定开销 83pt
> （内边距 40 + 分隔线 1 + 页脚带 42）= 143，取 4pt 网格 **144**。离屏实测（宽 1400，不开窗口）：
> 1 行文稿卡高 160 → **144**（正文区 77 → 61）、**3 行 160 → 158**（越过下限后由正文高度决定，
> 因此画板那一档几乎没动）、8 行 255 与 16 行 360 + 原生滚动**完全不变**；1440 × 900 整页
> `[scrolls] scroll h=61 doc=61 clip=61`（无滚动条），卡以上版式不动、卡以下整体上移 16pt。
> 音色创作页渲染与改前**逐字节相同**。稿的 `size(editor, null, 160)` 保持不变（画的是 3 行那一档）。
> **未构建官方包、未跑测试与 UI 自动化、未桌面走查**（预览包已按本轮源码重建并 ad-hoc 签名）。

> 2026-09-16 行首状态字形 10 → 13（§11.6 第三十九轮，两端逐像素量测）：
> 稿的 `icon(row, item.icon, 16)` 是 **16pt 图标框**不是 16pt 墨迹。`▸ 诊断.png`（4x）
> 实测：警示三角行墨迹 **13.5 × 12.0**、对勾行 **12.0 × 8.75**（lucide `check` 在 16 框里
> 就是 12 × 8.75，与帧一致）。应用此前用 `.imageScale(.small)`，实测只有 **10.0 × 10.0**，
> 比稿小 20–30%，而且是这一族里唯一的异类——`ControlAgentStatusView`、`ModelManagementView`
> 资源行、`RuntimeMonitoringView` 能力行都随正文继承到 13。处置：新增 `Icon.rowStatusSize`(13)
> 与 `Typography.rowStatusIcon`，三处 `imageScale` 全部改用它（`imageScale` 写法在整个 App
> 里清零）。13 semibold 的 `exclamationmark.triangle.fill` 实测 **13 × 12**，对稿残差 0.5 × 0。
> 诊断行的文字列因此左移 3pt（残差由 8pt 收到 5pt）。诊断行属于 `List`，无窗口不布局，
> 整页渲染取不到——证据是字形探针 + 4x 帧，行内观感留给桌面走查。
> 同轮还有配音台音色胶囊的两处取色：波形图标按稿（`icon(capsule, "audio-waveform", 15,
> V["accent/voice"])`，4x 帧同样是琥珀）与 §5.4「琥珀标记音色徽标、波形、候选卡」改为
> `Color.voice`（此前不设色、继承成正文色，与同一行的琥珀徽标割裂）；尾部 chevron 按稿的
> `text/secondary` 由 `inkTertiary` 改为 `inkSecondary`（应用自己的折叠行 chevron 本来就是
> `inkSecondary`，这里曾是全 App 唯一的三级色 chevron）。两处尺寸不动（残差 1 / 1.2pt）。

> 2026-09-16 行内动作字形与 Inspector 试听面板按帧校准（§11.6 第四十四轮）：稿的行内动作
> 图标按钮是同一个原语 `iconButton(parent, name, 28)`（28 × 28 框、圆角 7、**无底色**、
> `icon(b, name, 15, text/secondary)`），4x 帧在音色库列表行 / Inspector 试听行 / 我的作品行
> 五处量到的 `play` 墨迹都是 **10.25 × 11.5**、色 **#6E6E73**（= `secondaryLabelColor`），
> `download` 是 12.5 × 12.5 —— 稿的 15 是**图标框**，墨迹比框小一档。应用此前这一族用
> `Typography.statusIcon`（17pt semibold），播放钮还自造成**琥珀实心圆 `play.circle.fill`**
> （13 × 15，比帧大 30–44%，而稿上根本没有实心圆）。现在收敛到一个组件 `RowActionGlyph`
> （新 token `Icon.rowActionSize` = 13 + `Typography.rowActionIcon`，13pt semibold 与
> `Icon.rowStatusSize` 同族；本机实测 `play` 13pt semibold = 10.0 × 11.5 / 42.5pt²，与帧的
> 10.25 × 11.5 / 44.4pt² 吻合），播放态从 `stop.circle.fill` 改成 `stop`，导出与「更多操作」
> 同档；离屏实测音色库行 10.0 × 11.5、我的作品行 10.5 × 11.5，残差 ≤0.25。
> 同轮按稿重建音色库 Inspector 的试听面板：`previewWrap(padX 16 / padY 14)` 里嵌
> `preview(gap 10 / padX 12 / padY 10 / radius 10 / fill surface/panel)` + 1pt `border/separator`，
> 描边画在**填充之外**（帧：填充带 50.0、外框 52.0），面板底色按 §5.4 映射取
> `controlBackgroundColor`、边框取 `separatorColor`；离屏实测填充带 **50.00**、外框 **52.00**、
> 波形 **77.0 × 30.0** 且上下各 10、播放字形 10.0 × 11.5 —— 与帧逐位相同（波形水平位置差 2.5）。
> 预览包已重建并覆盖安装（sha256 `c338b8c3…`）；官方包仍被 Xcode 许可挡住；未跑单元测试与
> UI 自动化、未桌面走查。同轮记录四处未擅改的帧—应用冲突（我的作品行多一颗「更多操作」、
> Inspector 分区 hairline、Inspector 宽 360 vs 300、列表选中行底色），见 §11.6 第四十四轮 ⑤。
>
> 2026-09-16 行高的两类校准 + 一条量测边界被推翻（§11.6 第四十三轮）：探针加了
> `--window`（真实但**从不显示、从不激活**的 `NSWindow` 只作宿主），`List` 的行
> 第一次能按内容布局并出图——第二十三 / 二十五轮记的「`NSHostingView` 不出图、
> `List` 行矩形读不到」其实都只是「没有窗口」。据此改了两处行高：
> **页面列表行（音色库 / 我的作品 / 诊断）63 → 64**——系统分隔线画在行矩形**内部**，
> 所以 63 的矩形只剩 62 的内容区、行距也只有 63；改后行距 64、内容区 63，与稿
> （行框 63 + 独立 1pt hairline）逐位相同；**侧栏导航行 52 → 32**（稿 `navItemRow`
> 220 × 30 + `group` gap 1 = 行距 31；`.sidebar` 行矩形自带 32 下限，实测把这个值
> 改成 20 仍是 32，故与稿差 1pt 且不可再压）；**侧栏底部状态行 44 → 30**（稿
> `sidebarStatus` 220 × 30，样式新增 `minimumHeight` 参数，默认仍是 44 的命中区下限）。
> 侧栏两处只有几何证据（`NavigationSplitView` 的侧栏行内容取不到像素），
> 页面行是产品代码自己的离屏渲染。**未构建官方包、未跑测试与 UI 自动化、未桌面走查。**

> 2026-09-16 诊断检查行补框与间距 + 结果条标题区 / 安静出口 + 时长零填充（§11.6 第四十一轮）：
> 稿的诊断行是 `frame("diagRow", { gap: 10, padX: 16, padY: 12 })` + `icon(row, item.icon, **16**)`
> + 行尾 `chevron-right`（`main.js` 2009/2016）：那个 16 是**图标框**，不是墨迹。行首
> `Control.diagnosticIconFrame`(16) 与 gap 10 补齐后，文字列由 37 收到 **42**（4x 帧实测 41.75–42），
> 行盒 63 + 1pt hairline = **64** 与帧一致，行尾那两个字的状态文本换成稿的灰 chevron
> （状态已在行首字形、列表头与 `accessibilityValue` 里说过）。结果条按 `main.js` 1368–1383：
> 名称 `Body / Medium`、时长独立成 `Callout` + 等宽数字 + `inkSecondary`、出口是 `padX 8 / padY 4`
> 的**安静行**（不是第四颗边框按钮），chevron 墨迹 5.0 × 8.5 与稿逐位相同。作品时长一律零填充
> `mm:ss`。**未构建官方包、未跑测试与 UI 自动化、未桌面走查。**
>
> 2026-09-16 波形原语按稿重建（§11.6 第四十二轮）：稿的 `waveform(parent, bars, colorVar, gap)`
> 是「每根 2pt 宽、圆角 1、按给定高度居中」的原语，三处只在参数上不同——结果条 12 根 / 间隙 2
> → 46 × 17、音色创作候选卡 18 根 / 间隙 3 → 87 × 36、音色库试听行 16 根 / 间隙 3 → 77 × 30
> （4x 帧三处实测与脚本逐位吻合）。应用此前用一个固定组件（9 根 / 3+3 / 72 × 20）顶两处、
> 结果条还用 SF `waveform` 字形，三处都比稿小且左对齐。现改为 `SpeechRailDesignTokens.Waveform`
> （`barWidth` 2 / `barRadius` 1 + 三个 `Pattern`，宽高由 pattern 推出）驱动的 `WaveformBars`，
> 离屏实测三处 **46.0 × 17.0 / 87.0 × 36.0 / 77.0 × 30.0**，残差 0。播放态不再改颜色或砍半高
> （稿上波形一律琥珀满高），只留 §5.7 的脉冲，条状视图用显式透明度动画、Reduce Motion 下停。
> 同轮删掉 `Layout.creatorWaveformWidth/Height`、`Control.waveformBarSpacing/Width/Radius`、
> `Color.waveformInactive`。
> 两轮的预览包已重建并覆盖安装到 `~/Applications/SpeechRail.app`（sha256 `381bb0c8…`），
> 官方包仍被 Xcode 许可挡住；未跑单元测试与 UI 自动化、未桌面走查。

> 2026-09-16 侧栏底部状态区收成一行 + hairline 按稿内缩（§11.6 第四十轮）：
> 稿的 `Sidebar Status`（`main.js` 三个 tone 变体 + 页面帧 `sidebarStatusWrap`）是
> **一行**：`padX 8 / padY 7` 里放 8pt 状态点 + `Callout` 文本、颜色 `text/secondary`，
> 没有标题行也没有尾部 chevron；4x 帧 `▸ 配音台.png` 实测整行墨迹 125.25 × 12.75、点 8.0 × 8.0。
> 应用此前是「服务状态」标题 + 语义色 `caption` 状态行两行 + `chevron.right`，本轮按稿收成一行
> （`inkSecondary` 文本），点击面 / `.help` / 无障碍语义不变。同轮把那道分隔线按稿内缩：
> 稿是 `sidebarStatusWrap` 里的 **220 × 1** 矩形（侧栏 `padX: 10`），4x 帧实测 x 10.0–230.0，
> 应用此前用系统 `Divider()` 通栏（x 0–240），现改为 1pt 矩形 + `Control.sidebarHairlineInset`(10)。
> 离屏实测（240 宽探针，无窗口）：块高 47.0 → **45.0**、hairline x 0–240 → **10–230**、
> 状态文本两行 → 单行 12.0pt 墨迹、hairline 到文本顶 18.0（稿 20.25）。
> 记录在案：行高仍是 44（`SpeechRailInteractiveButtonStyle` 的命中区下限，与侧栏项同族）vs 稿 30，
> 点 / 文本左侧仍是 16 vs 稿 18（侧栏内缩由系统 `List` 给）。侧栏在无窗口环境不布局，
> 它在真实侧栏里的观感归桌面走查。**未构建官方包、未跑测试与 UI 自动化、未桌面走查**；
> 预览包已按本轮源码重建并覆盖安装到 `~/Applications/SpeechRail.app`（用户当轮授权），
> 回退点与细节见 REDESIGN-SPEC §12.4。

> 2026-09-16 Inspector 分段 + 圆角改造成果的离屏取证（§11.6 第四十五 / 四十六轮）：
> 音色库 Inspector 按稿 `main.js` 1584–1641 改成「头部 / 试听 / 取值 / 底部固定动作」四段，
> 段间是**整宽 1pt hairline**（帧 y 260.0 / 341.0 / 820.0 三条），动作区不再随内容滚动；
> 头部从 `SectionHeading`(13 + 12pt) 换成稿的 `Title / Page` + `Caption`（离屏实测标题
> 82.0 × 20.0 vs 帧 79.25 × 19.0，即 `.title` 22pt 的 +2pt 残差；徽标 10pt / `tertiaryLabelColor`）。
> 本轮离屏复测还发现并修回一条**重复的 hairline**（动作区自带的 `Divider()` 与段间 `Divider()`
> 相隔 14pt 双画）。
> 同轮为并行线的圆角改造补上离屏取证：新增探针 `--corners`，在同一张黑底图上并排给出
> **已知半径的参考形状**与**真实容器**，用同图参考校准抗锯齿偏移后读缺角。结论：`.control` /
> `.panel` / `.inspector` / `CardSurface` / `.elevated` 的缺角都是 **161px² / 15.0 × 15.0**，
> 与 `RoundedRectangle(12, .continuous)` 参考**逐像素相同**（同半径 `.circular` 是 147px² /
> 12.0 × 12.0，8pt continuous 是 81px² / 10.0 × 10.0）；叶面半径 = **容器半径 − 内缩**
> （inset 0/2/4/6/8/12 → 12/10/8/6/4/0），**`minimum` 只在容器给不出半径时兜底**
> （无容器时实测 81px² = 8pt），所以内缩 ≥ 12pt 的叶面会得到方角——新增嵌套时要按这条检查。
> **未运行单元测试与 UI 自动化、未桌面走查**；预览包已按本轮源码重建并覆盖安装到
> `~/Applications/SpeechRail.app`（先精确 `kill -TERM` 再换二进制、ad-hoc 签名、`open -g`），
> 回退点与细节见 REDESIGN-SPEC §12.4。

> 2026-09-16 按钮档位收口（§11.6 第四十七轮）：§5 那条「按钮高度一律走
> `SpeechRailButtonAppearance`」此前只是**写在文档里**——全仓 21 处裸 `.buttonStyle(...)`
> 有 6 处没跟 `.controlSize`，落到系统默认 24pt（稿的主按钮 34 / 次按钮 30，本应用的映射档
> 是 36 / 28，所以那几处比稿小 6–10pt）。本轮把 18 颗标准动作按钮（Inspector 动作区、
> 两个弹窗页脚、三处空态 CTA、配音台失败卡、预检全过结论、作品 Inspector 动作）接进
> `speechRailButton(_:)`；删除按钮保留 `role: .destructive` 但视觉走次级档（帧上三颗同形，
> 没有红底）。离屏实测 Inspector 动作区 52.00 → **64.00**（14 + 36 + 14），
> 自定义音色的次级行 28.00。**未运行单元测试与 UI 自动化、未桌面走查**；覆盖安装细节见
> REDESIGN-SPEC §12.4。

> 2026-09-16 两块「侧边栏」收成一个结构声明点（§11.6 第五十四轮）：音色库与我的作品
> 两页右侧的详情面改由 `SpeechRailInspectorPanel` 统一声明四段（身份带 / 试听 /
> 取值 / 固定动作区）与段间整宽 hairline。我的作品因此从 `SectionHeading` + 缩进
> `Divider` + 散在正文里的动作，换成与音色库同形的身份带、嵌套试听面板
> （`.speechRailInspectorPreviewPanel()`，`play` 图标按钮 + 波形原语）与压在底部的
> 动作区（`导出…` 主按钮 + `在 Finder 中显示 / 重命名 / 删除` 次级行，破坏性动作不再
> 随内容滚动）。同轮修回两处 token 偏差：试听面板底色 `Color.field` →
> `Color.recessedField`（否则面板与 Inspector 列同色，只剩一圈描边），字段标签
> `caption` → `captionMedium`（稿 `Caption / Medium`）。离屏实测（`--inspector` /
> 新增 `--works-inspector`，360 × 900、浅深两态）两页预览面板逐像素同形，
> 音色库那三条 hairline 与面板带宽（50.00pt）逐项不变。**未验证**：720pt 高窗口与
> 展开「技术上下文」时动作区的高度分配、离屏取不到强调色填充的主按钮观感、
> 悬停/按压与 VoiceOver；**未运行单元测试与 UI 自动化**（按 AGENTS.md 需当次授权）。

> 2026-09-16 详情面板的波形改成**真实数据**（§11.6 第五十七轮）。三处 `WaveformBars`
> 此前画的是稿的固定高度数组、播放时只叠一层透明度呼吸；现在条高来自这段音频自己的
> 幅度包络（`AudioEnvelope`，32 桶、逐窗峰值、整段归一化），播放中未播到的部分按
> `AudioPlaybackController` 的真实进度降到 `Waveform.remainingOpacity`。
> `Pattern.heights` 从此只决定条数与排布，不再决定高度；没有包络时（还没试听过的音色）
> 才退回固定图形并保留脉冲。同轮把「试听文案」输入槽改成多行
> （`TextField(axis: .vertical)` + `lineLimit(2...5)`），并给两块目录页侧边栏补上
> `DeveloperInspector` 一直有的列宽声明（300 / 360 / 440）与 `surface/field` 底色——
> 此前列宽是内容的函数。**未验证**：真机听感、进度顺滑度、新 token 的组件测试。

> 2026-09-16 详情列改成**定宽**（§11.6 第六十一轮）。用户复核「两个侧边栏应该保持宽度
> 一致」：上一轮补的列宽声明是**区间**（300 / 360 / 440），区间在真实窗口里会被窗口余量
> 与内容最小宽推到两端——装机件里音色库那一列是 300（截图 2x 实测预览面板外框 539px
> = 269.5pt，加两侧 16pt = 列宽 301.5pt = 区间下限），我的作品那一列是 360；空态更是
> 完全没有声明（离屏实测 270 = 系统默认）。三个区间 token 因此收成一个
> `Layout.inspectorColumnWidth`（= 360，与稿的 Inspector 同口径），声明点收成
> `speechRailInspectorColumn()` 一处，`SpeechRailInspectorPanel`、`DeveloperInspector`
> 与两块目录页的**空态**都走它。代价是分割线不再可拖（稿上本来就是定宽列）。
> 同轮给音色库试听段尾补 14pt（`Inspector.previewWrapInsetY`）：改前输入槽下边框与
> 段间 hairline **重叠**（离屏 vscan：槽底 230–232 与 hairline 231 同一行），改后间距
> 14.0pt，段上下因此同值。**未验证**：真机拖动窗口与切页时的列宽观感、窄窗口下详情列的
> 挤压主观感受；**未运行单元测试与 UI 自动化**（按 AGENTS.md 需当次授权）。

> 2026-09-16 详情列开关从**系统工具栏**移到**内容列首行尾端**（§11.6 第六十二轮）。
> 用户要求「按钮更靠右侧、临着边栏，从边栏左沿算起留一定空间」：窗口工具栏是一整条，
> 动作项的落点由系统按「固定项 + 浮动间隔」分配，内容列右端没有可声明的槽位——
> 离屏实测同一枚按钮在 1120 / 1280 / 1440 / 1600pt 窗口下落在 x 639.5 / 719.5 / 799.5 /
> 879.5，到详情列左沿（= 窗口宽 − 360）的距离从 76.5 涨到 316.5；去掉组合根的
> `ToolbarSpacer(.flexible)`、改 `.status` / `.secondaryAction` / 交给 `.inspector` 声明 /
> 可拉伸容器五种写法都不改变这一点。改法：两页把开关放进 `PageScaffold` 的 `trailing` 槽
> （该槽已有先例：运行监控的时间窗选择器），首行由内容列承载、右沿即详情列左沿，间隔取
> `Layout.contentPadding`（20pt，不新增数值）。三档窗口实测图标墨迹右沿到详情列左沿恒为
> 29.5pt。同轮按用户授权做了 app-only 装机：`CFBundleVersion` 10 → 11（`MARKETING_VERSION`
> 仍 2.6.4），`scripts/macos_app_build.sh --configuration Debug` 通过，装到
> `~/Applications/SpeechRail.app`（`mdfind` 只剩这一条），回退点
> `SpeechRail-2.6.4-10-installed-20260916-1539.zip`，服务未被触碰（8201 唯一 listener、
> `/readyz` 200）。**未验证**：真机观感与热区、详情列收起后的相对位置；**未运行单元测试与
> UI 自动化**（UI 自动化需当次明确授权）。

> 2026-09-16 运行监控回到用户语言（§11.6 第六十三轮，用户指令「我现在都看不懂监控的啥」）。
> 取证：本机 `quality` 服务的 `/metrics` 里 1188 次累计请求有 1159 次是控制面轮询
> （`/health` 469、`/metrics` 197、`/v1/voices` 216、`/v1/models` 142、`/v1/voices/{voice_id}` 135），
> 语音接口只有 `/v1/audio/speech` 15 次、`/v1/voices/previews` 12 次；`workers` 实际是
> `{asr, tts, streaming}` 而映射表没有 `streaming`，组件表直接露出英文；`physical_footprint_complete`
> 为 false，那一行恒为「未提供」。改法：首屏六格换成「正在处理 / 语音合成 / 语音识别 / 合成耗时 /
> 识别耗时 / 失败请求」，次数与音频时长都只数语音接口并按窗口增量算；结论句改为「最近 5 分钟：
> 合成 3 次、识别 1 次，都正常。」；图卡改「使用趋势」，序列名与坐标轴换词；组件表补 `streaming`
> 映射并说明「空闲一段时间后自动释放」；折叠明细改「更多细节」（服务能力 / 内存与并行 /
> 不同音色类型的合成耗时 / 累计统计，累计平均列带单位）。数据层新增 `RuntimeUsageTotals`、
> 窗口侧 `usageIncrease` / `errorIncrease` / `queueRejectionIncrease` 与 `RuntimeHistogramPresentation`，
> 旧的 `rate`、窗口均值、直方图累计口径一个都没删。`scripts/macos_app_build.sh --configuration Debug`
> 与 `xcodebuild … build-for-testing` 均通过（**只编译**，未运行测试）。稿侧 `main.js` 的
> `screenMonitoring` 同步换文案，`node audit.js` clean；**插件重跑与重导出未执行**（无 Figma 连接器工具）。
> **未验证**：离屏量测与真机目视（本机没有离屏渲染 harness）、单元测试、UI 自动化。

> 2026-09-16 运行监控两张表改由**应用自己画**（§11.6 第六十八轮，用户在装机截图旁问
> 「这里咋这么突兀，这符合系统设计 token 么？」）。取证：截图 2x 逐带取均值——卡头/卡脚
> `(43,41,44)` = `Color.field` 的 `#2B292C`（逐位相同，说明截图未被色彩管理改写），
> 表体 `(31,29,41)` = `#1F1D29`、第二行 `(42,40,51)`，两者都不在 token 里；离屏探针
> （`NSHostingView`，暗色）指出系统表 `backgroundColor = #1E1E1E`、
> `usesAlternatingRowBackgroundColors = true`（偶数行叠 5% 白 = `(42,40,51)`，与截图逐位吻合）、
> 表体顶部还有 5pt 内容内缩。结论：那条浅色带是**隔行底纹**而不是选中行，读起来是一处
> 假的可选中暗示；`Table` 的系统行为（排序 / 列宽 / 键盘导航）在这两张静态表上一次都没用到。
> 改法：列头 + 行 + 1pt `Divider` 自己排，行高 `List.compactRowHeight`(42)、行内 `Callout`、
> 列头 `captionMedium`/`inkSecondary`；新增 `Layout.monitoringWorkerNameColumnWidth`(380)/
> `monitoringSampleColumnWidth`(84)/`monitoringMetricValueColumnWidth`(110)，
> 删掉 `monitoringWorkerRowHeight`/`monitoringTableHeaderHeight`。
> `scripts/macos_app_build.sh --configuration Debug` **BUILD SUCCEEDED**；复刻探针实测卡片自然高
> 266（补齐真实 `CardFoot` 后 ≈ 280，与稿 280.2 同档），视图树里 `NSTableView`/`NSScrollView` 均为 0。
> **未验证**：装机后的观感、窄窗（1120pt）下第一列与状态列的关系、单元测试与 UI 自动化。

> 2026-09-17 运行监控的**耗时单位改成毫秒**（REDESIGN-SPEC §11.6 第六十九轮，
> 用户在装机截图上指令「时间单位改 ms」）。展示层口径收进 `RuntimeLatencyPresentation`
> （`RuntimeMetricsSampler.swift`）：`0.4126` → `413 ms`、`0.001` → `1 ms`、
> `0.0004` → `0.40 ms`、`0` → `0 ms`，无障碍另给 `spokenUnit = "毫秒"`。
> `RuntimeHistogramPresentation.unit(forMetric:)` 对四条耗时直方图返回 `ms`，
> 首屏耗时 / 音色类型耗时 / 累计平均 / p95 / 右轴刻度与图例 / 折叠详情 / 复制摘要 /
> AX 描述符都走这一处；音频时长与历史跨度仍是秒、分钟。
> `scripts/macos_app_build.sh --configuration Debug` **BUILD SUCCEEDED**、
> `xcodebuild … build-for-testing` 编译通过。**未运行单元测试与 UI 自动化**（需当次明确授权）；
> **未验证**右轴刻度改成毫秒后的目视观感。

## 7. 变更流程
新增组件先判断是否能由标准 SwiftUI 控件表达；确需定制时先补充 token 和可访问语义，
再实现组件。token 变更必须同时更新本文件、对应 Swift 定义、组件测试和 macOS App
视觉验收记录。不得在单页样式中创建只被一次使用的产品色、间距或圆角。
