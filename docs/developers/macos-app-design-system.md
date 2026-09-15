---
title: "SpeechRail macOS App 设计系统与 Token"
status: active
audience: "SpeechRail macOS App 设计、开发与测试人员"
version: "0.8.0"
date: 2026-09-15
---

# SpeechRail macOS App 设计系统与 Token

> **迁移已完成（2026-09-15）**：[`docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md`](../design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md)
> 的 §5（视觉语言 v2）与 §7（逐页规格）已落到 `macos/SpeechRailApp`：阶段 1 外壳、阶段 2 token 收敛、
> 阶段 3 命令与键盘、阶段 4 逐页重构均已完成，本文 §3 与 §4 已按 v2 语义重写，两份文档不再并行描述两套规范。
> 设计决策与阶段状态以 REDESIGN-SPEC §10 为准；本文件只描述落地后的 token 与组件契约。

> **已知未验证项（2026-09-15）**：以下内容只完成代码与构建验证，尚未做桌面人工走查或 UI 自动化：
> Light/Dark、Increase Contrast、Dynamic Type、Reduce Motion 的实际观感；VoiceOver 实读顺序；
> 列表「空格试听」在真实焦点下的行为；`.searchable` 与页面级 `List` 在窄窗口下的布局。

## 1. 研究基线与 Logo 设计基因

本设计系统以 Apple 官方 macOS 26 / Xcode 26 资料为基线。`SpeechRailApp` GUI target
明确以 macOS 26.0 为最低版本，不为 App UI 编写 macOS 14 的兼容 fallback；服务协议、
ControlKit、ControlAgent 和服务侧 SwiftPM worker 是独立边界，是否保留更低最低版本由各自
运行职责决定。研究结论是：App 在 macOS 26 上完整使用系统新设计能力，不把新特性降级为
共同最低版本的视觉实现。

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

> v2 起，颜色、字体、圆角和表面**不再由 SpeechRail 自己定义**：token 层只做系统语义色的映射，
> 让 App 跟随用户的外观、强调色和辅助功能设置。下表是当前唯一有效的语义映射。

| 物理领域 | Swift 命名空间 | 核心 Token 与规格约束 |
|---|---|---|
| 文本层级 | `Color` | `ink/inkSecondary/inkTertiary` → 系统 `labelColor/secondaryLabelColor/tertiaryLabelColor`；不使用自挑灰度 |
| 表面底色 | `Color` | `canvas` → `windowBackgroundColor`；`field` → `controlBackgroundColor`；`recessedField` → `textBackgroundColor` |
| 分隔与描边 | `Color` | `separator` → `separatorColor`；静态表面不再有自绘描边、机加工微切线与辉光 |
| 强调色 | `Color` | `rail` → **`Color.accentColor`**（跟随系统强调色）。全 App 只有这一个产品强调色，替代原先 `#23687D` 与 `#2A4E57` 并存的冲突 |
| 语义状态 | `Color` | `ready/attention/critical/info` → 系统 `.green/.orange/.red/.blue`；`voice`（音色/声学）为唯一产品语义色 |
| 控件描边与焦点 | `Color` | `focusRing` 与自定义行的 `Navigation.focusRing` 都解析为 `keyboardFocusIndicatorColor`，全 App 焦点环同色；`disabled`/`quaternaryFill` 表示禁用层级 |
| 间距节奏 | `Spacing` | 使用 `tight/micro/xs/sm/md/lg/xl/hero`，基准节奏为 2/4/8/12/16/24/32/48 pt |
| 圆角几何 | `ConcentricRectangle` | 控件/面板/槽位/列表行一律使用 SwiftUI `ConcentricRectangle`，由系统按容器计算同心圆角；`Corner` 枚举（手挑 6/8/14/18/12/16）已整体删除，代码中不再存在自挑圆角 |
| 布局规整 | `Layout` | sidebar 220–280pt（ideal 240）、inspector 300–440pt（ideal 360）、模型档位列 220–320pt（ideal 280）、音色名列 160–260pt（ideal 220）、页面内容内边距 `contentPadding = 20`、窗口最小 1,120×720pt |
| 表面修饰 | `ViewModifiers` | `.speechRailSurface(_:)` / `.speechRailContentSurface()`（系统 `controlBackgroundColor` + 同心圆角，无描边无阴影）、`.speechRailRecessedSlot()` / `.speechRailField()`（`textBackgroundColor`）、`.speechRailKnurledCapsule()`（系统胶囊，仅选中态用强调色） |
| 字体层级 | `Typography` | 只用系统文本样式（`.body/.caption/.caption2` 等），不再使用 `design: .rounded` 或手挑字号；数字一律 `.monospacedDigit()` |
| 动效反馈 | `Motion` | 仅保留系统级转场；按压缩放已从按钮移除，波形脉冲在 Reduce Motion 下退化为静态；选区反馈 `0.14s` |
| Inspector 行 | `SpeechRailInspectorLabeledContentStyle` | 标签列固定 `Inspector.labelColumnWidth = 92`，取值右对齐、可选文本，供全 App inspector 复用 |

诊断结论区的用户影响说明使用 `Diagnostics.summaryMessageMaximumLines`，默认最多两行；当动态字体或
错误文案需要更多垂直空间时，结论区只能自然增高，不得用固定最大高度裁切内容。

### 3.2 全局交互语言与组件契约

1. **Toolbar 标题锁定**：`WorkspaceTitleLockup` 是唯一的 toolbar principal 标题组件，呈现“icon + workspace”的单行标题；标题使用固定槽位、尾部截断和最小缩放，永远不换行。路由切换不改变标题中心几何，不挤压右侧操作。
2. **系统表面 (System Surfaces)**：`.speechRailSurface(_:)` 只渲染系统填充色与同心圆角。承载交互或用层级表达关系的容器**没有边框、没有阴影、没有高光**；只有窗口级浮动层（`.elevated`）使用 `regularMaterial` 与系统阴影。
3. **沉降式凹槽 (Recessed Slot)**：文稿编辑框与参数输入框统一采用 `.speechRailRecessedSlot()` / `.speechRailField()`，底色比所在面板低一级（`textBackgroundColor`），焦点态由系统 `keyboardFocusIndicatorColor` 描边而非自定义发光。
4. **指针与无障碍命中区**：可操作实例统一通过 `speechRailPointerCursor()` 暴露 pointing hand；自定义行/卡片使用 `SpeechRailInteractiveButtonStyle`；命中区由控件自身尺寸决定，不再对按钮强制 44pt 最小框架（该约束会挤压紧凑工具栏）。
5. **列表交还系统**：音色库、我的作品、诊断检查项和监控表格使用系统 `List`/`Table`，由系统渲染选中态、悬停、交替行和键盘导航；页面不再自绘选中底色与焦点环。
6. **命令与快捷键**：`SpeechRailCommands`（`App.swift`）提供 File/View/Help 菜单与 `⌘N`、`⌘E`、`⌘1–⌘8`、`⌘⌥I`、`⌘?`；`⌘E` 通过 `FocusedValues.selectedWorkCommand` 绑定到当前场景选中的作品。

## 4. 八大页面 UI/UX 优化蓝图

### 4.1 空间拓扑与双轨导航心智
- **STUDIO 创作工坊**（配音台、音色创作、音色库、我的作品）：聚焦声音雕琢与文本心流，大留白（`Spacing.hero`），注入 `Color.voice` 陶土暖色，首屏 100% 留给创作任务，不显示冗余服务状态横幅。
- **ENGINE 核心引擎**（服务中枢、模型档位、运行监控、系统诊断）：强调确定性、低时延与高透明度，等宽数字排版，冷钛金与冷青导轨色为主基调。
- **全局状态唯一性**：侧边栏底部 `[✓ 服务已就绪 · Quality]` 是全 App 唯一的常驻全局服务状态指示器，正文仅在服务专属总览、任务受阻或长任务跃迁时按需显示置顶 `StatusConclusion`。

### 4.2 页面级重点优化规则
1. **配音台 (Dubbing Desk)**：文稿编辑器占满剩余高度（最小 320pt），系统文本背景 + 系统焦点环，正文 `.body`；页脚在分隔线之内给出 `n/上限 字`（超限转红并带图标）与「清空」；控制条在窄窗口自动换行；生成结果条留在本页，提供播放 / 在 Finder 中显示 / 导出… / 查看我的作品。
2. **音色创作 (Voice Design Studio)**：描述文本框（最小 160pt）+ 计数行 + 琥珀色系统胶囊 chips（点击追加声学特征）+ 页脚键帽；「更多设置」把参考文案与保存名称折叠起来；候选区为 2×2 网格（候选 1–4），每张卡头部按 Figma `Candidate Tile` 固定为 槽位名（Body / Medium）/ 状态胶囊 / 右对齐 seed，动作行为「试听或停止 + 保存为音色」，失败卡保持同一骨架并把波形区换成原因说明 + 重试；档位不满足时用 `ContentUnavailableView` 给出「去模型页切档」。
3. **音色库与我的作品 (Catalog & Archive)**：两页都是「系统 `List` + 右侧 `.inspector`」详情面。音色库顶部为 `.searchable`（名称与描述）与来源分段控件（全部/系统/我的），行内只有名称、来源徽标、一行描述、可用性说明和行内试听；试听文案、seed、变体、模式、使用次数、关联作品、描述全文与「重命名/编辑描述/删除」都在 Inspector。我的作品顶部为 `.searchable`（标题）与时间排序，行内是标题、音色、创建时间、等宽时长和行内播放，次动作（导出 `⌘E`、在 Finder 中显示、重命名、删除）走行内右键菜单与工具栏；删除作品会连同本机音频文件一起移除，因此必须有破坏性确认。
4. **服务中枢 (Service Core)**：四要素状态结论大面板（图标 + 结论标签 + 影响范围 + 单一主动作），并列展示 ASR 词级时间戳、VoiceDesign 并发与 FluidAudio 匿名分人能力矩阵。
5. **模型档位 (Model Profiles)**：三档横向比对机架，模型准备/下载采用确定性 `OperationBar`（MB/s 速度、预计时间、SHA256 校验进度、安全回退确认）。
6. **运行监控 (Telemetry)**：时间序列是页面主对象，占满整宽并位于首位。顶部是时间窗分段控件（1 分钟 / 5 分钟 / 本次会话）与采样状态（「最近 n 个样本」/「等待监控样本」）；并发与时延各自一张 Swift Charts 折线图（并发计请求数、时延计秒，共用一条轴会把两者都压平），网格线用系统分隔色、标签 12pt；下方用 `Table` 呈现 worker 生命周期与直方图摘要，数字等宽。没有样本时用 `ContentUnavailableView` 说明「这不代表服务异常」。
7. **系统诊断 (Diagnostics)**：递进式结构化排障，异常项配备一键修复动作与脱敏排障报告复制。

### 4.3 真实能力条件渲染与脱敏双轨隔离
- **真实能力门禁**：波形预览、回退操作与端口修复基于后端实际能力条件展示，未就绪时优雅降级为静态说明。
- **脱敏双轨隔离**：「我的作品」允许查看创作者自有的完整输入文本；「开发者 Inspector」严格执行脱敏协议，仅展示 Request ID、时延、Token 统计、脱敏 Worker PID 和会话级匿名标签（`speaker_0`），严禁暴露 Base64 音频、实名身份或绝对系统路径。

## 5. 验收清单

- [x] App target 的最低系统版本为 macOS 26.0，并使用系统 Liquid Glass 结构能力（2026-09-13 Debug build 已验证）。
- [x] App 未通过自绘根背景阻断 scroll edge effect；玻璃只用于窗口/导航层，内容和 Inspector 使用统一内容表面（2026-09-13 代码审查已验证）。
- [x] 所有 App 页面主要产品间距、尺寸、颜色和字体从 `SpeechRailDesignTokens` 读取；零间距仅用于 Divider/列表拼接等结构性布局。
- [x] Logo 设计基因（形、质、光、色）已完整解构并落盘至规范文档与 Swift Token 映射。
- [ ] Light、Dark、Increase Contrast、Dynamic Type 和 Reduce Motion 均有 UI 验证；当前只完成代码/构建检查，尚未完成桌面人工矩阵。
- [ ] VoiceOver 可按“导航 → 页面说明 → 主操作 → 状态详情”的顺序访问；图表、档位和 DisclosureGroup 语义已接入，尚未完成桌面 VoiceOver 实测。
- [x] 页面高频动作已提供 toolbar、菜单栏或键盘路径，不依赖 hover；2026-09-13 UI tests 验证控制台、设置和主要页面入口。
- [x] 音色创作、模型下载、profile 应用、服务启停的边界在 UI 文案和确认动作中可见；模型下载与档位应用使用独立按钮和确认框。
- [x] 全局标题使用单行 `WorkspaceTitleLockup`，动作菜单统一为“更多操作”，导航 route icon 集中管理；2026-09-13 Debug build 已验证。
- [x] custom clickable rows/cards 使用共享按压、hover、focus、disabled 与 cursor 规则，静态表面不再伪装成可操作区域；2026-09-13 代码审查已验证。

## 6. 当前实现与验证矩阵

| 范围 | 实际结果 | 验证时间 |
|---|---|---|
| App Debug 构建 | `BUILD SUCCEEDED`，Xcode 26.6 / SDK 26.5，目标为 `arm64-apple-macos26.0`，0 条新增 warning；未运行测试 | 2026-09-15 20:33 |
| Swift 单元测试 | 本轮未运行；此前历史记录不作为本轮证据 | — |
| UI 测试 | 本轮未运行（AGENTS.md 硬约束：未经当次明确授权不运行 UI 自动化） | — |
| 设置单场景复核 | 本轮未执行 | — |
| App 安装 | `2.6.4 (8)`、`arm64`、`LSMinimumSystemVersion=26.0`，ad-hoc 签名与嵌入 XPC 通过；Debug 构建已覆盖安装到 `~/Applications/SpeechRail.app`，旧版本存档于 `~/Library/Application Support/SpeechRail/app-archive/` | 2026-09-15 20:33 |
| 桌面视觉矩阵 | 待用户手工走查：本机无 UI 自动化授权，Light/Dark、Increase Contrast、Dynamic Type、Reduce Motion 均未实测 | — |
| VoiceOver 实测 | 尚未完成 | — |

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

## 7. 变更流程

新增组件先判断是否能由标准 SwiftUI 控件表达；确需定制时先补充 token 和可访问语义，
再实现组件。token 变更必须同时更新本文件、对应 Swift 定义、组件测试和 macOS App
视觉验收记录。不得在单页样式中创建只被一次使用的产品色、间距或圆角。
