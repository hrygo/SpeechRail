---
title: "SpeechRail macOS App 设计系统与 Token"
status: active
audience: "SpeechRail macOS App 设计、开发与测试人员"
version: "0.7.3"
date: 2026-09-15
---

# SpeechRail macOS App 设计系统与 Token

> **迁移进行中（2026-09-15）**：[`docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md`](../design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md)
> 已采纳为 App UI/UX 的目标规范。其中 §5（材质、圆角、颜色、字体）与 §7（逐页规格）与本文冲突时以那份为准。
> 本文 §3.1 列出的 `Chassis` / `SteelAlloy` / `AcousticMaster` / 手挑圆角描述的是**迁移前现状**，将随对应页面重构逐节替换，
> 不保留两份长期并行；外壳（阶段 1）与路由快捷键（阶段 3）已落地，token 层尚未收敛。

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

| 物理领域 | Swift 命名空间 | 核心 Token 与规格约束 |
|---|---|---|
| 机架冶金 | `Chassis` | `enclosure`（黑曜底座）、`deck`（机架面板）、`recessedWell`（沉降槽）、`milledBevel`（切削边）、`grooveStroke`（加强边） |
| 拉丝冷钢 | `SteelAlloy` | `specularEdge`（0.5px 镜面切削高光）、`brushedFace`（各向异性拉丝银光）、`billetPlate`（铣削厚板）、`knurledRim`（滚花滚边） |
| 钢轨道床 | `SteelRail` | `trackCyan`（道床冷青 `#2A4E57`）、`railheadGleam`（钢轨反光 `#4FA4BA`）、`sleeperTie`（轨枕标尺 `#33373B`）、`gliderBead`（滑标电珠） |
| 声学母带 | `AcousticMaster` | `tubeWarmth`（真空管暖琥珀 `#F59E0B`）、`vuPhosphor`（示波器磷光 `#10B981`）、`peakOverload`（峰值过载 `#EF4444`）、`waveCrest`（声波峰谷） |
| 控制推子 | `ConsoleFader` | `calibratedDetent`（1.0x 基准阻尼点）、`detentNotchCount`（物理刻度）、`thumbWidth/Height`（推头尺寸） |
| 间距节奏 | `Spacing` | 使用 `tight/micro/xs/sm/md/lg/xl/hero`，基准节奏为 2/4/8/12/16/24/32/48 pt |
| 倒角比例 | `Corner` | 控件 6、选中行 8、字段 14、模块 18、胶囊 999；曲率比值 `continuousRadiusRatio = 0.2237` |
| 布局规整 | `Layout` | sidebar 220–280pt（ideal 240）、inspector 300–440pt（ideal 360，可压缩以免挤压页面内容）、模型档位列 220–320pt（ideal 280）、音色名列 160–260pt（ideal 220）、主内容区最大宽度 1,240pt、窗口最小 1,120×720pt |
| 表面修饰 | `ViewModifiers` | `.speechRailConsoleChassis()`（机加工机架板）、`.speechRailRecessedSlot()`（沉降声学槽）、`.speechRailKnurledCapsule()`（滚花胶囊） |
| 动效反馈 | `Motion` | 弹簧动力学 `spring(response: 0.28, dampingFraction: 0.82)`，按压缩放 `0.985`，选区反馈 `0.14s`；尊重 Reduce Motion |

诊断结论区的用户影响说明使用 `Diagnostics.summaryMessageMaximumLines`，默认最多两行；当动态字体或
错误文案需要更多垂直空间时，结论区只能自然增高，不得用固定最大高度裁切内容。

### 3.2 全局交互语言与组件契约

1. **Toolbar 标题锁定**：`WorkspaceTitleLockup` 是唯一的 toolbar principal 标题组件，呈现“icon + workspace”的单行标题；标题使用固定槽位、尾部截断和最小缩放，永远不换行。路由切换不改变标题中心几何，不挤压右侧操作。
2. **机加工表面 (Machined Console Chassis)**：`speechRailConsoleChassis()` 作为核心容器，彻底终结千篇一律的白底大圆角卡片。在 Dark 模式下自动叠加顶边 0.5px `specularEdge` 线性渐变高光切线与微距 `ambientShadow`，营造沉着内敛的专业机架面板质感。
3. **沉降式凹槽 (Recessed Slot)**：文稿编辑框与参数输入框统一采用 `speechRailRecessedSlot()`，杜绝尺寸挤压坍塌。
4. **指针与无障碍命中区**：可操作实例统一通过 `speechRailPointerCursor()` 暴露 pointing hand；自定义行/卡片使用 `SpeechRailInteractiveButtonStyle`；图标按钮有效命中区保持 `44 × 44pt`。

## 4. 八大页面 UI/UX 优化蓝图

### 4.1 空间拓扑与双轨导航心智
- **STUDIO 创作工坊**（配音台、音色创作、音色库、我的作品）：聚焦声音雕琢与文本心流，大留白（`Spacing.hero`），注入 `Color.voice` 陶土暖色，首屏 100% 留给创作任务，不显示冗余服务状态横幅。
- **ENGINE 核心引擎**（服务中枢、模型档位、运行监控、系统诊断）：强调确定性、低时延与高透明度，等宽数字排版，冷钛金与冷青导轨色为主基调。
- **全局状态唯一性**：侧边栏底部 `[✓ 服务已就绪 · Quality]` 是全 App 唯一的常驻全局服务状态指示器，正文仅在服务专属总览、任务受阻或长任务跃迁时按需显示置顶 `StatusConclusion`。

### 4.2 页面级重点优化规则
1. **配音台 (Dubbing Desk)**：文稿编辑器采用 `speechRailField()` 微陷设计，字号 16pt，行高 1.4 倍；合成后滑出内嵌微波形的试听条。
2. **音色创作 (Voice Design Studio)**：Prompt 框配合陶土色 Accent，声学胶囊机架（`Corner.pill`）支持快捷点击注入声学特征，横向 A/B 候选试听机架支持快速交叉切换。
3. **音色库与我的作品 (Catalog & Archive)**：条目内嵌 16 段跳动频谱小波形与一键试听/导出，右侧抽屉式 Inspector 显示基模型来源与脱敏生成时延。
4. **服务中枢 (Service Core)**：四要素状态结论大面板（图标 + 结论标签 + 影响范围 + 单一主动作），并列展示 ASR 词级时间戳、VoiceDesign 并发与 FluidAudio 匿名分人能力矩阵。
5. **模型档位 (Model Profiles)**：三档横向比对机架，模型准备/下载采用确定性 `OperationBar`（MB/s 速度、预计时间、SHA256 校验进度、安全回退确认）。
6. **运行监控 (Telemetry)**：专业机架仪表条（`MetricStrip`）使用 Tabular 数字无跳动刷新；并发与时延采用冷青色单趋势折线图。
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
| App Debug 构建 | `BUILD SUCCEEDED`，Xcode 26.6 / SDK 26.5，目标为 `arm64-apple-macos26.0`；未运行测试 | 2026-09-13 19:34 |
| Swift 单元测试 | 本轮按用户指令暂停；此前历史记录不作为本轮证据 | — |
| UI 测试 | 本轮按用户指令暂停；此前历史记录不作为本轮证据 | — |
| 设置单场景复核 | 本轮未执行 | — |
| Release App 安装 | `2.6.0 (2)`、`arm64`、`LSMinimumSystemVersion=26.0`，CDHash `e85dbb...`，签名与嵌入 XPC 通过；已安装到 `~/Applications/SpeechRail.app` | 2026-09-14 13:28 |
| 安装后服务隔离 | `/health`、`/readyz` 通过；仍为唯一 8201 listener（PID 70831），quality profile；未重启服务 | 2026-09-14 13:25 |
| 桌面视觉矩阵 | 待用户手工走查（深色模式机加工微切线高光、黑曜深空底座、双轨导航与控制台质感） | — |
| VoiceOver 实测 | 尚未完成 | — |

> 2026-09-14 状态说明：设计规范已正式升级至 v0.7.0，完成 Logo 设计基因解构与 Token 落地。
> 新版本 Release App `2.6.0 (2)` 已安装至 `~/Applications/SpeechRail.app`，待用户桌面人工视觉走查与验收。

## 7. 变更流程

新增组件先判断是否能由标准 SwiftUI 控件表达；确需定制时先补充 token 和可访问语义，
再实现组件。token 变更必须同时更新本文件、对应 Swift 定义、组件测试和 macOS App
视觉验收记录。不得在单页样式中创建只被一次使用的产品色、间距或圆角。
