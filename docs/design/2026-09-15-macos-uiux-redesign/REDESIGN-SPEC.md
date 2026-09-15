---
title: "SpeechRail macOS App UI/UX 重设计规格（macOS 26 原生）"
status: accepted
audience: "SpeechRail macOS App 设计与开发人员"
version: "1.4.0"
date: 2026-09-15
---

# SpeechRail macOS App UI/UX 重设计规格

## 1. 文档定位

本文件是**已采纳的目标规范**（2026-09-15 决定：配色收敛采纳、作品删除/重命名纳入本轮）。未落地的条目仍描述目标形态，不是当前实现的说明，也不代表已获批准的公共契约变更。

判断冲突时的顺序仍然是：当前代码与实测 → `contracts/` → active 的 `docs/`。因此本文**尚未落地**的条目与 [`docs/developers/macos-app-design-system.md`](../../developers/macos-app-design-system.md) 冲突之处，仍以那份 active 文档描述当前实现；已落地的部分以代码为准，并按 §10 的阶段状态逐节修订那份文档。

本文涉及 App 的视觉、信息架构、交互与键盘路径，**不改变**服务协议、XPC 命令集、运行档位、模型生命周期或任何运行态行为。

## 2. 产品定位：App 是什么

SpeechRail 服务是单人 Apple Silicon Mac 上的本地共享语音引擎，对外提供协议兼容的 REST 与 Realtime 入口。App 是它的产品化入口，承担两件在终端里做不好的事：

**引擎时刻**——我能不能现在就用它？为什么不能？下一步做什么？

**创作时刻**——把一段文字变成声音；造一个属于我的音色；回看和导出我做过的声音。

这两件事的心智、词汇密度和技术含量完全不同。重设计的核心判断是：**不要把它们混成一种语气**。引擎时刻用状态、结论和确定性数字说话；创作时刻用文稿、试听和声音本身说话。

### 2.1 边界（明确不做）

- 不做多轨 DAW、视频时间线、背景音乐混音。
- 不把 App 变成会议 / 实时字幕 / 语音助手客户端——那是调用方（Sona、LiveKit/Pipecat、Open-WebUI 等）的职责。
- 不在 UI 承诺后端不支持的能力。当前服务端配音是**单音色 TTS**，没有“自动分角色演播稿”能力；任何多角色叙事界面都必须等契约先具备该能力（见 §12.1）。

## 3. 现状诊断

证据均来自 `main`（2026-09-15 工作区）的实际代码。

| # | 现象 | 证据 | 影响 | 方向 |
|---|---|---|---|---|
| D1 | 自绘工具栏底色覆盖了系统工具栏材质 | `ControlCenterView.swift:71` `.toolbarBackground(Color.canvas, for: .windowToolbar)` + `:75` `.toolbarBackgroundVisibility(.visible, …)` | 工具栏失去 macOS 26 的玻璃与内容透出，窗口顶栏变成一块实心色带；滚动内容也无法获得系统 scroll edge effect | 删除该覆盖，让系统拥有工具栏层 |
| D2 | 侧边栏与内容区被同一块“黑曜底”铺满 | `ControlCenterView.swift:39,52,56` `.background(Chassis.obsidian)` | 导航层与内容层没有材质差异，侧边栏失去系统玻璃；整个窗口压成一块暗板，正文对比度与层级同时下降 | 不设置根背景；侧边栏交给 `NavigationSplitView`，内容区用系统窗口底 |
| D3 | 每张卡片都是自绘机加工面板 | `SpeechRailDesignTokens.swift` 的 `SpeechRailContentSurfaceModifier`（自绘渐变 + `specularChamfer` 顶边高光 + `ambientShadow`）；调用点 28 处 | 卡片边界靠自绘描边而非真实层级定义；大量渐变/内阴影在浅色模式下尤其“假金属”；文字可读性被装饰削弱 | 材质交给系统 `Material` / 语义色；分隔用 `Divider` 与滚动边缘 |
| D4 | 圆角是手挑的 6/8/14/18，不是系统同心几何 | `SpeechRailDesignTokens.swift:22-25` | 嵌套容器与外层窗口圆角不同心，边缘出现可见接缝；在 macOS 26 上显得“外来” | 目标 API：`.rect(corners: .concentric)` / `ConcentricRectangle`（以 Xcode 26 SDK 实测可用性为准） |
| D5 | 无窗口级菜单命令与快捷键 | `App.swift` 的 `body` 只有 `Window` / `MenuBarExtra` / `Settings`，全仓 `.commands` 命中 0 次；`ControlMenuView.swift:49,66` 的 `⌘⌥0` / `N` 只在该菜单展开时生效 | 主操作（生成配音、新建音色、导出）没有键盘路径；HIG 要求重要命令可从菜单栏触达 | 补 `.commands`（File / View / 页面动作）与 `⌘1…⌘8` 路由快捷键 |
| D6 | 配音台是“参数表单”，不是文稿工作台 | `CreatorSurfaceViews.swift:147` 标题「声学参数配置」；`:256,277,279` 「语速推子」「物理校准档位快切」；`:118` 编辑器固定 180pt 高 | 用户想做的是“把文字变成声音”，却被要求理解推子、刻度与校准；编辑器只占首屏一小块 | 改为文稿优先布局；术语回到用户语言 |
| D7 | 音色选择没有试听 | `CreatorSurfaceViews.swift` 配音台 `voicePicker` 是一个裸 `Picker` | 声音是听觉对象，用文字列表选择音色违背媒介；用户必须先生成一段才能听到差别 | 音色选择器带行内试听与描述 |
| D8 | 生成结果与作品割裂 | 配音台生成后自动保存并播放，导出只在「我的作品」的“更多操作”里，且仅在已选中作品时可用（`CreatorSurfaceViews.swift:1948-1958`） | 用户刚生成完想导出/定位文件时要跳页再找 | 生成后在原地出现结果条：试听、在 Finder 显示、导出 |
| D9 | 「服务状态」有四处入口 | `ControlCenterView.swift:206` 侧边栏底部状态按钮、同页 sidebar 的 `.overview` 路由、同页工具栏 `WorkspaceTitleLockup`、`CreatorSurfaceViews.swift:78` 配音台“更多操作 → 查看服务状态” | 同一信息重复出现，削弱侧边栏底部那一个“全局状态”的权威性 | 全局状态只留侧边栏底部一处常驻 |
| D10 | 技术细节的默认值被全局记忆 | `@AppStorage("speechrail.showDeveloperDetails")` 同时驱动配音台、音色创作、我的作品三页的 Inspector 默认展开 | 用户在某页打开过一次，之后每个创作页都默认展示技术摘要 | 保留记忆能力，但默认保持“用户语言”优先，且技术摘要只在该页相关时才出现 |
| D11 | 固定高度不随动态字体增长 | `CreatorSurfaceViews.swift:118` `frame(height: 180)`、`:549` `frame(height: 160)`；`SpeechRailDesignTokens.Layout.creator*MinimumHeight` 系列 | 增大字号或换行语言时，编辑区与输入槽可能裁切 | 固定 `height` 改 `minHeight`，并让容器自然增高 |
| D12 | 作品不可删除、不可重命名 | `CreativeWorkStore` 无 `delete`/`rename`（`rg "func (delete|rename)"` 仅命中音色的 `deleteVoice`/`updateVoice`） | 作品只增不减，本地存储与列表会持续膨胀且无法整理 | 在列表提供删除与重命名（需明确破坏性确认） |
| D13 | 每个页面都以“目的句 + 一叠等宽卡片”开头 | `WorkspaceComponents.swift` 的 `PageScaffold`：`PageIntroView` + `VStack` 卡片，全部同宽、同 padding | 页面缺少主次；工具栏标题与页面目的句重复表达同一件事 | 工具栏承担标题；正文直接进入主对象 |
| D14 | 主题色被当作装饰而非语义 | `Chassis.obsidian` / `milledBevel` / `trackGlow` 等 token 在静态容器上广泛使用；配音台主按钮 tint 为 `Color.rail`，音色创作主按钮 tint 为 `tubeWarmth` | 两个创作页的主动作不同色；颜色在装饰与语义之间摇摆，用户无法从颜色学到任何稳定含义 | 单一强调色 + 少量语义色（见 §4.4） |

## 4. 设计原则

**P1 · 用系统，不要模仿系统。** 材质、玻璃、圆角、层级、控件状态由 macOS 26 提供。品牌不参与绘制系统层，只参与颜色选择和一个关键动效。

**P2 · 一屏一件事。** 每页有一个主对象（文稿 / 候选 / 列表 / 结论），其余内容要么是它的补充，要么收进 Inspector。

**P3 · 状态只出现在需要它的地方。** 全局状态常驻侧边栏底部一处；页面只在受阻或长任务跃迁时置顶一条结论。

**P4 · 默认说用户语言，技术事实按需展开。** 端口、profile、worker、metrics、错误码保留给 Inspector 与诊断页，且始终可复制、可用于排障。

**P5 · 声音是听觉对象。** 凡是音色或作品出现的地方，都应能就地听到它；试听不是“高级功能”。

## 5. 视觉语言 v2

### 5.1 保留的 DNA

Logo 的工业声学基因继续作为**色彩与比例**语言存在，不再作为**材质**语言存在：

- 冷钛银的金属灰阶（作为中性阶，不做渐变）。
- 钢轨青（`#4FA4BA` 系）作为 App 强调色，用于选中、焦点与主控件 tint。
- 真空管琥珀（`#F59E0B` 系）降级为**语义色**：只标记“声音/音色”这一类对象（音色徽标、波形、候选卡），不再用作整页主按钮底色。
- 示波器磷光绿保留为“就绪/成功”。
- 等宽数字用于所有会跳动的量。

### 5.2 材质与层级

| 层 | 实现 | 不再使用 |
|---|---|---|
| 窗口底 | 系统窗口默认背景（不显式设置） | `Chassis.obsidian` 铺底 |
| 侧边栏 | `NavigationSplitView` 系统侧边栏（自动获得 macOS 26 玻璃） | 自绘 `.background` |
| 工具栏 | 系统 unified compact 工具栏（保留现有 `.unifiedCompact(showsTitle: false)` 与 `ToolbarSpacer`） | `.toolbarBackground` / `.toolbarBackgroundVisibility` 覆盖 |
| 内容面板 | `Color(nsColor: .controlBackgroundColor)` 或 `.regularMaterial` | 自绘渐变 + 0.5px 描边的 `speechRailContentSurface()` |
| 输入槽 | `Color(nsColor: .textBackgroundColor)` + 系统焦点环 | `speechRailRecessedSlot()` 的内阴影/反光双描边 |
| 分隔 | 系统 `Divider()` 与滚动边缘效果 | `speechRailSleeperDivider()`、`milledBevel` 描边 |
| 浮起层 | 仅窗口级浮层（浮动的播放/生成结果条）使用系统材质或 `glassEffect` | 静态卡片上的 `ambientShadow` |

**判据**：如果一块表面既不承载交互、也不表达层级，它就不应该有描边和阴影。现在的实现把“容器”当成了“控件”。

### 5.3 圆角与同心几何

- 窗口圆角由系统拥有，代码不设置。
- 内容容器使用系统同心圆角（目标 API `.rect(corners: .concentric)`，落地前以 Xcode 26 SDK 实测为准）；不使用 6/8/14/18 的手挑组合。
- 列表行选中、输入框、按钮一律使用系统控件自带圆角。
- `Corner.continuousRadiusRatio` 与 `Corner.control/row/field/module` 在迁移完成后废弃。

### 5.4 颜色

目标是**两个品牌色 + 系统语义色**，其余全部交给系统：

| 用途 | Token | 说明 |
|---|---|---|
| App 强调 / 选中 / 焦点 | `AccentColor` = 钢轨青 | 已通过 `Assets.xcassets/AccentColor` + `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` 生效，继续保持 |
| 声音语义 | `VoiceAccent` = 琥珀 | 仅用于音色类徽标、候选卡、波形 |
| 成功 / 注意 / 危险 / 信息 | 系统语义色（`.green/.orange/.red/.blue` 语义等价物） | 必须同时带图标与文字，不单靠颜色 |
| 正文 / 次要 / 三级文本 | 系统 `labelColor` / `secondaryLabelColor` / `tertiaryLabelColor` | 删除 `ink/inkSecondary/inkTertiary` 的自定义亮度 |
| 面板 / 输入 / 分隔 | 系统 `controlBackgroundColor` / `textBackgroundColor` / `separatorColor` | 删除 `Canvas/Field/RecessedSlot/milledBevel` |

浅色模式使用系统铝灰而非纯白；深色模式使用系统深灰而非纯黑。App 不再有自己的“底色”。

### 5.5 字体与数字

- 只用系统文本样式：`.title2`（页面主标题，仅诊断/总览使用）、`.headline`（区块标题）、`.body`（正文）、`.callout`、`.subheadline`、`.caption`、`.caption2`。
- 数字：`monospacedDigit()`，不换字体族。删除 `Typography.metricValue` 的 `.rounded` 设计（圆体数字与专业工具气质不符，且与系统层级冲突）。
- 删除所有固定 `size:` 和 `design:` 组合，除 SF Symbol 尺寸外。

### 5.6 间距与密度

保留 4pt 基准节奏（2/4/8/12/16/24/32/48）。变化在于**用量**：

- 页面内容水平内边距 20pt（现为 32pt），让窗口在 1120–1280 宽度下不至于过窄。
- 区块之间 24pt，区块内元素之间 8–12pt。
- 创作页给文稿区最多空间：编辑器最小高度 320pt（现为 180pt）。
- 删除 `Layout.contentMaximumWidth = 1240` 的居中约束；改用系统可读性宽度或整窗宽度，避免宽屏右侧留白。

### 5.7 图标

- SF Symbols，`symbolRenderingMode(.monochrome)`，导航 16pt、工具栏 16pt、状态 14–17pt。
- 状态图标与颜色成对出现；`waveform`、`waveform.badge.plus`、`music.note.list`、`square.stack.3d.up` 等现有语义映射保留。
- 生成中/播放中使用 `.symbolEffect(.variableColor.iterative)`（尊重 Reduce Motion）。

### 5.8 动效

- 系统动效优先；App 自定义动效只保留两处：
  1. 生成中的波形脉冲；
  2. 生成结果条从底部进入（`.move(edge: .bottom).combined(with: .opacity)`）。
- 删除列表选中行的 `spring` 与按压缩放（系统已提供选中与按压反馈）。
- 全部动效在 `accessibilityReduceMotion` 下退化为即时切换。

## 6. 信息架构与导航

### 6.1 侧边栏

保留单一 `NavigationSplitView` 与现有 8 条路由（不新增页面），但收敛措辞与结构：

| 分组 | 路由 | 侧边栏标签 | 变化 |
|---|---|---|---|
| 创作 | `dubbing` | 配音台 | 不变 |
| 创作 | `voiceDesign` | 音色创作 | 不变 |
| 创作 | `voiceLibrary` | 音色库 | 不变 |
| 创作 | `works` | 我的作品 | 不变 |
| 引擎 | `overview` | 服务状态 | 从「服务」组改为「引擎」，与技术页同组 |
| 引擎 | `monitoring` | 运行监控 | 不变 |
| 引擎 | `models` | 模型 | 不变 |
| 引擎 | `diagnostics` | 诊断 | 不变 |

侧边栏底部保留**唯一**的全局状态区：一行状态点 + 状态文本，点击进入「服务状态」。删除 `ControlCenterView` 中重复的入口（D9）。

侧边栏搜索保留 `.searchable(placement: .sidebar)`，但匹配范围改为“标签 + 页面说明全文”，并在结果为空时使用系统 `ContentUnavailableView.search`（现已有）。

### 6.2 工具栏

- principal 保留 `WorkspaceTitleLockup`（单行、固定槽位、尾截断），但去掉 icon 与标题之间的装饰间距依赖，标题继续使用 `.headline`。
- primary action 保留各页的“更多操作”菜单，但内容按页面职责收敛：开发者详情只在**该页真有技术摘要**时出现。
- 增加 `.toolbar(removing: .sidebarToggle)` 之外的默认行为不变；窄窗口交给系统 overflow。

### 6.3 菜单栏与键盘（当前完全缺失）

新增 `Commands`：

| 菜单 | 命令 | 快捷键 |
|---|---|---|
| File | 新建配音文稿 | `⌘N` |
| File | 导出选中作品… | `⌘E` |
| View | 配音台 / 音色创作 / 音色库 / 我的作品 | `⌘1`–`⌘4` |
| View | 服务状态 / 运行监控 / 模型 / 诊断 | `⌘5`–`⌘8` |
| View | 显示/隐藏开发者详情 | `⌘⌥I` |
| 页面动作 | 生成语音（配音台） | `⌘⏎` |
| 页面动作 | 生成候选音色（音色创作） | `⌘⏎` |
| 页面动作 | 播放/停止试听 | `空格`（仅当列表/候选有焦点） |
| Help | SpeechRail 帮助 | `⌘?` |

### 6.4 状态呈现的唯一性

一个状态在同一时刻只能有一个“权威位置”：

| 状态 | 权威位置 | 其他位置 |
|---|---|---|
| 服务是否就绪 | 侧边栏底部状态区 | 服务状态页的结论面板；其他页面仅在被阻塞时置顶结论 |
| 长任务进度（生成/下载/切档） | 触发它的页面内联 | 侧边栏状态区显示“服务操作进行中” |
| 错误 | 触发它的页面内联结论 | 诊断页汇总 |

## 7. 逐页规格

### 7.1 配音台 (Dubbing Desk)

**主对象**：文稿。**主动作**：生成语音。

结构（自上而下）：

1. 文稿编辑器：占满剩余高度，最小 320pt；系统文本背景、系统焦点环；行距 1.4；字号 `.body`。
2. 编辑器卡片页脚：分隔线之内、卡片底部的信息行 —— 字数 `n/上限`（超限时 `.red` + 图标）在左，「清空」为 `.borderless` 次要动作在右。计数属于它计数的那个输入框，不飘到页面底色上。
3. 控制条（横向，窄窗口自动换行为两行）：音色选择器、语速、主按钮。
4. 生成结果条（生成成功后出现，见下）。

**音色选择器**：默认显示为一个带波形图标的胶囊（当前音色名 + 类型徽标）。点击打开 popover：

- 每行显示音色名、一句描述、来源（系统 / 我的）、行内试听按钮。
- 试听中该行显示停止图标与进行中状态。
- 顶部一行“管理音色库 →”跳转音色库。
- 无可用音色时，popover 内直接用 `ContentUnavailableView` + “去音色创作”。

**语速**：`Slider` + `Stepper`（步长 0.1，范围 0.5–2.0），标签「语速」，右侧等宽数字显示当前值。快捷档位使用系统 segmented control（0.8 / 1.0 / 1.2 / 1.5），措辞去掉“推子”“校准”。参考音色（clone 模式）锁定为 1.0 时，控件 `.disabled` 并给出原因说明。

**主按钮**：`生成语音`（`.borderedProminent`，`⌘⏎`）。生成中变为 `ProgressView` + `停止`；此时编辑器与选择保持可编辑并保留输入。

**生成结果条**（新增，替代现在的“自动跳页”心智）：

```
[波形] 标题 · 00:12   [▶ 播放] [在 Finder 中显示] [导出…] [查看我的作品]
```

- 播放控件来自统一的播放控制器，全 App 同一时刻只有一个声音。
- 失败时同一位置变为错误条：原因（用户语言）+ 重试 + 「查看诊断」。

**移除**：「声学参数配置」标题、输出格式/采样率行（进 Inspector）、生成后自动播放的隐式行为（改为结果条中显式开始播放，或保留自动播放但在结果条中体现状态）。

### 7.2 音色创作 (Voice Lab)

**主对象**：候选音色。**主动作**：生成候选。

三段渐进，而不是一屏表单：

1. **描述**：大文本框（最小 160pt，不再是固定高），下方一行声学特征 chips（横向滚动，点击追加）。chips 使用系统胶囊样式 + 琥珀语义色。
2. **参考文案与保存名称**：折叠进 `DisclosureGroup`「更多设置」，默认展开时填入合理默认值（参考文案、由描述派生的名称）。首屏不再显示这两项。
3. **候选区**：生成后以 **2×2 网格**呈现（现为纵向分隔列表）。每张候选卡：槽位编号 + 波形 + 播放/停止 + 状态 + `保存为音色`。选中的卡片以强调色描边，未就绪的卡片明确说明原因。四张卡共用同一段结构（头部 / 波形区 / 动作行）：失败卡把波形区换成居中的原因说明（警示图标 + 一句话），动作行仍保留「重试」与时长位，网格才读起来是网格。

生成按钮措辞统一为 `生成候选音色`（`⌘⏎`）；生成中为 `停止生成`。

**能力门禁**：当需要 Quality 档位时，候选区用 `ContentUnavailableView` 呈现，并带一个直接动作「去模型页切档」，而不是一行灰色文字。当 TTS 未就绪时，同一位置说明原因并给「查看服务状态」。

**保存流程**：保存前展示一次性确认（名称、描述、参考文案、seed），成功后该卡变为「已保存」并给「在音色库中查看」。

### 7.3 音色库 (Voice Library)

**主对象**：音色列表。

- 布局：`List`/`Table` 双栏 + 右侧 Inspector 详情（系统 `.inspector`）。
- 列表行：名称、来源徽标（系统 / 我的）、一句描述、行内播放按钮、不可用状态。
- 顶部：`.searchable`（名称与描述）、来源筛选（系统 segmented control：全部 / 系统 / 我的）。
- 行选中后 Inspector 依次显示：行内试听（播放按钮 + 琥珀波形）、seed、可用性、创建时间、变体与模式、使用次数、关联作品、描述全文，以及「重命名 / 编辑描述 / 删除」。Inspector 内取值统一右对齐，标签列固定宽度。
- 删除使用破坏性确认对话框，明确说明影响（该音色在配音台将不可选）。
- 空状态：`ContentUnavailableView` +「去音色创作」。

### 7.4 我的作品 (Works)

**主对象**：作品列表。

- 列表行：标题、音色名、创建时间、时长（等宽数字）、行内播放；条目数按窗口高度铺满列表卡（当前样张 8 条），避免列表卡下方留出成片空白。
- 顶部：`.searchable`（标题）、按时间排序。
- 行内主动作：播放；次动作：导出（`⌘E`）、在 Finder 中显示、重命名、删除。
- 删除需确认，并说明音频文件将被移除且不可恢复（新增能力，见 D12）。
- 空状态：`ContentUnavailableView` +「去配音台」。

### 7.5 服务状态 (Service Overview)

**主对象**：一条结论。

1. **结论面板**：图标 + 结论标签（如「服务已就绪」）+ 影响一句话 + 唯一主动作（如「打开诊断」或「启动服务」）。四种状态：就绪 / 需关注 / 不可用 / 操作中。
2. **能力矩阵**：以 `LabeledContent` 或轻量表格呈现 ASR（含词级时间戳）、TTS（VoiceDesign / Base）、音色复刻、实时 VAD、分人（匿名标签）。每项显示“可用 / 未就绪 / 当前档位不支持”及一句原因。
3. **运行信息**：档位、端口、版本、常驻 worker 以键值卡直接呈现（标签左、值右对齐）。这一版把原先收起的「技术细节」改为直接展示：这一页本就是为看结论与事实而打开的，把四行事实藏在一次点击之后，只会让最有用的一屏空掉三分之一窗口。

### 7.6 运行监控 (Telemetry)

**主对象**：时间序列。

- 顶部：时间窗选择（系统 segmented control）+ 采样状态（“最近 n 个样本 / 等待监控样本”）。
- 主图：Swift Charts 折线（并发、时延），保留现有实现与配色语义，但网格线改为系统中性色，标签 12pt。
- 下方：`Table` 呈现 worker 与直方图摘要；数字等宽。
- 无 metrics 时：`ContentUnavailableView`「等待监控样本」，并说明这不代表服务异常。
- 图表接入 Swift Charts 的可访问性描述符。

### 7.7 模型 (Models)

**主对象**：当前档位与它的准备状态。

1. **档位选择**：系统 `Picker`（segmented 或表格形式）呈现 Light / Balanced / Quality，每档一句适用场景与差异（是否分人、aligner 精度、TTS lane 数）。
2. **两个独立动作**：`下载并校验`（primary，可取消，显示阶段：download / verifying / publishing + 字节进度）与 `应用此档位`（secondary + 确认对话框，说明会重启服务与短暂不可用）。
3. **制品列表**：每个制品显示 key、来源（脱敏 model ID）、量化、文件数、校验状态。
4. **磁盘**：已用 / 可用，等宽数字。
5. 中断的 active operation 恢复为解释性提示 + 重试入口，不承诺续传。

### 7.8 诊断 (Diagnostics)

**主对象**：检查项清单。

- 布局：左侧 `List` 检查项（状态图标 + 名称 + 一句话），右侧详情。
- 详情：结论、用户影响、可执行修复动作（若有）、编号的「修复步骤」、`DisclosureGroup` 技术上下文（错误码、request ID、脱敏字段）。修复步骤与详情卡同高，卡片不会在错误码之后就断掉。
- 顶部：`复制诊断报告`（脱敏，符合项目隐私约束）与 `重新运行预检`。
- 全部通过时使用 `ContentUnavailableView` 呈现“未发现问题”，而不是一份空列表。

### 7.9 菜单栏 (MenuBarExtra)

保持 `.menu` 风格与紧凑几何：

```
SpeechRail · 服务已就绪 · Quality      (不可点状态行)
────────────────────────
打开 SpeechRail                        ⌘O
开始配音                               ⌘N
────────────────────────
运行预检
停止服务…
────────────────────────
退出 SpeechRail                        ⌘Q
```

### 7.10 设置 (Settings)

系统 `Settings` scene 保留。分组：通用（启动行为）、创作（默认音色、默认语速、开发者详情默认展开）、服务（端口显示、诊断报告包含项）。设置项保持最小集合，不把模型管理搬进设置。

## 8. 状态与反馈矩阵

每页必须显式定义以下状态，禁止用“空列表 + 0 值”占位：

| 状态 | 配音台 | 音色创作 | 音色库 / 作品 | 服务四页 |
|---|---|---|---|---|
| 加载中 | 编辑器可用，音色选择器显示加载 | 描述可输入 | 列表骨架或进度 | `ProgressView` |
| 空 | — | 「还没有候选音色」+ 说明 | `ContentUnavailableView` + 引导动作 | 「未发现问题」/「无数据」 |
| 能力缺失 | 选择器内说明 + 动作 | `ContentUnavailableView` + 去切档 | 行内不可用徽标 + 原因 | 结论面板 + 主动作 |
| 进行中 | 主按钮变停止 + ProgressView | 主按钮变停止 + 卡片占位 | 行内进度 | 内联进度 + 侧边栏状态 |
| 失败 | 结果条错误态 + 重试 + 诊断 | 候选卡失败态 + 重试 | 行内错误 + 重试 | 结论面板 + 诊断 |
| 部分成功 | 结果条说明已保存但未播放 | n/4 候选成功 | — | 能力矩阵逐项标注 |

## 9. 无障碍

| 项 | 要求 |
|---|---|
| VoiceOver 顺序 | 导航 → 页面结论（若有）→ 主对象 → 主操作 → 状态详情 |
| 命名 | 所有图标按钮有 `accessibilityLabel`；列表行给出名称 + 状态 + 动作 `accessibilityHint` |
| 图表 | Swift Charts 接入 `accessibilityChartDescriptor`；折线提供摘要 |
| 状态不依赖颜色 | 状态点必须搭配文字；`Differentiate Without Color` 下仍可读 |
| 动态字体 | 固定 `height` 全部改 `minHeight`；行高随字号增长 |
| Reduce Motion | 两处自定义动效退化为即时；波形脉冲停止 |
| Increase Contrast | 不使用纯装饰描边，对比由系统语义色保证 |
| 键盘 | §6.3 全部命令可达；焦点环使用系统焦点样式 |

## 10. 迁移路径与 Swift 映射

落地状态（2026-09-15，`main` 工作区）：阶段 1 外壳与阶段 3 的路由快捷键/开发者详情开关已实现，`./scripts/macos_app_build.sh --configuration Debug` 通过（`BUILD SUCCEEDED`，无新增编译警告）。阶段 2（token 收敛）与阶段 4（逐页重构）未开始，因此 `SpeechRailDesignTokens` 目前新旧语义并存。

### 阶段 1：外壳（低风险，独立可见）

状态：**已完成**（2026-09-15）。

| 动作 | 位置 |
|---|---|
| 删除 `.toolbarBackground` / `.toolbarBackgroundVisibility` | `ControlCenterView.swift:71-75` |
| 删除三处 `.background(Chassis.obsidian)` | `ControlCenterView.swift:39,52,56` |
| 侧边栏选中交还系统（保留 `.listStyle(.sidebar)` 与无障碍标识） | `ControlCenterView.swift` 的 `navigationRow` |
| 删除选中行 3pt 发光“滑标”装饰 | `ControlCenterView.swift` 的 rail bead |

实际改动（2026-09-15）：上述四处全部落地；侧边栏行改为 `Label(_:systemImage:)` 由系统渲染选中态，区块标题改 `Section(title)`，
底部状态区去掉磷光珠光晕与自绘字体，`StatusTone` 改用系统语义色（`.green/.orange/.red/.secondary`）。

### 阶段 2：Token 收敛

| 现在 | 改为 |
|---|---|
| `Chassis.obsidian/deck/recessedWell/milledBevel/grooveStroke` | 删除；使用系统语义色 |
| `SteelAlloy.*` | 删除（不改用 Material 的自绘材质） |
| `Corner.control/row/field/module` | 删除；改系统同心圆角 |
| `Color.ink/inkSecondary/inkTertiary` | 删除；改系统 label 层级 |
| `AcousticMaster.*` | 收敛为 `VoiceAccent` 一个语义色 |
| `Typography` 的 `design:`/固定 size | 删除，仅保留文本样式 |
| `speechRailContentSurface/Chassis/RecessedSlot/KnurledCapsule` | 删除或改薄为 `Material` + 系统描边 |
| `Surface` / `Navigation` 的大量 opacity token | 收敛到系统控件状态 |

> 迁移期间新旧 token 并存会造成视觉不一致，因此阶段 2 应与逐页重构同步推进，而不是先全量替换再改页面。

### 阶段 3：命令与键盘

在 `App.swift` 增加 `.commands { … }`，并把 `AppNavigationState` 扩展为可由命令触发路由切换。

状态：**部分完成**（2026-09-15）。已加 `View` 菜单的 `⌘1`–`⌘8` 路由切换与 `⌘⌥I` 开发者详情开关（后者复用既有 `@AppStorage("speechrail.showDeveloperDetails")`，各页 Inspector 已经响应它）。`⌘N`（新建配音文稿）、`⌘E`（导出选中作品）、页面内 `⌘⏎` 与列表 `空格` 试听依赖各页的本地状态，随阶段 4 对应页面一起实现。

### 阶段 4：逐页重构

顺序：配音台 → 音色创作 → 音色库 → 我的作品 → 服务状态 → 运行监控 → 模型 → 诊断。

每页完成后应更新 [`docs/developers/macos-app-design-system.md`](../../developers/macos-app-design-system.md) 的对应章节，而不是保留两份规范。

## 11. Figma 构建规格

> 本节给出可直接在 Figma 中重建的精确规格；由于它是设计交付的一部分，数值即为设计事实来源。

### 11.1 页面结构

> 下表是目标结构；7 页现已全部生成，实际产物、原型连线与自检结论见 §11.6。

| Figma Page | 内容 |
|---|---|
| `00 Cover` | 命名、版本、日期、状态（Proposed） |
| `01 Foundations` | 颜色变量、文本样式、间距、圆角、图标、动效说明 |
| `02 Components` | 组件与变体（见 §11.4） |
| `03 Flows` | 三条主流程连线图 |
| `04 Screens` | 8 个页面 × 深/浅 × 关键状态 |
| `05 Menu & Settings` | 菜单栏菜单、设置窗口 |
| `06 Archive` | 旧版机架视觉，仅作历史对照 |

### 11.2 Frames

| Frame | 尺寸 | 说明 |
|---|---|---|
| 主窗口 | 1440 × 900 | 默认设计尺寸 |
| 主窗口（最小） | 1120 × 720 | 窄窗口回归 |
| 主窗口（宽） | 1920 × 1080 | 宽屏回归 |
| 设置窗口 | 640 × 内容撑高 | 宽固定 640；高按内容取高，三个标签页对齐到最高面板（见 §11.6） |
| 菜单栏菜单 | 288 宽 | 自适应高 |

侧边栏固定 240pt（最小 220 / 最大 280），内容区随窗口伸展。

### 11.3 变量（Variables）

颜色（`color` 集合，含 Light / Dark 两种 mode）：

```
accent/rail            #2A4E57 / #4FA4BA
accent/voice           #D97706 / #F59E0B
status/ready           #059669 / #10B981
status/attention       #D97706 / #F59E0B
status/critical        #DC2626 / #EF4444
status/info            #2563EB / #38BDF8
surface/content        (系统 controlBackgroundColor 等价)
surface/field          (系统 textBackgroundColor 等价)
surface/divider        (系统 separatorColor 等价)
text/primary           (系统 labelColor 等价)
text/secondary         (系统 secondaryLabelColor 等价)
```

数值（`number` 集合）：

```
space/2 4 8 12 16 20 24 32 48
radius/concentric      12   （容器，嵌套时由外层推导）
radius/field            8
stroke/hairline         0.5  （仅系统无法表达时）
control/height         28 34 40
hit/min                44
sidebar/width         220 240 280
```

文本样式（`text` 集合）：`LargeTitle`、`Title2`、`Headline`、`Body`、`Callout`、`Subheadline`、`Caption`、`Caption2`，外加 `Mono/Numeric`（系统文本样式 + tabular figures）。

### 11.4 组件清单

每个组件标注变体轴与关键尺寸；所有可交互组件必须有 `hover` / `focused` / `disabled` 变体。

| 组件 | 变体轴 | 说明 |
|---|---|---|
| `SidebarItem` | state(默认/选中/hover)、group(创作/引擎) | 16pt 图标 + 标签，选中由系统强调色承担 |
| `SidebarStatus` | tone(ready/attention/critical/neutral) | 状态点 + 文本 + chevron |
| `ToolbarTitle` | — | 单行固定槽位，尾截断 |
| `ToolbarActions` | — | 图标按钮组 + 溢出 |
| `StatusConclusion` | tone(4) | 图标 + 结论 + 影响 + 主动作 |
| `StatusBanner` | tone(4) | 页面内联条，含可选动作 |
| `VoicePickerCapsule` | state(默认/展开/禁用) | 波形图标 + 名称 + 徽标 |
| `VoicePickerRow` | state(默认/hover/播放中/不可用) | 名称 + 描述 + 试听按钮 |
| `VoiceBadge` | source(系统/我的) | 琥珀语义徽标 |
| `SpeedControl` | state(可用/锁定) | Slider + Stepper + 数值 |
| `PrimaryAction` | state(默认/进行中/禁用) | 40pt 高，含 `⌘⏎` 提示 |
| `ResultBar` | state(成功/失败) | 波形 + 播放 + 次要动作 |
| `CandidateTile` | state(生成中/可试听/已保存/失败) | 2×2 网格单元 |
| `WorkRow` | state(默认/hover/播放中) | 标题 + 音色 + 时间 + 时长 + 播放 |
| `EmptyState` | kind(无数据/无结果/能力缺失) | 图标 + 标题 + 说明 + 动作 |
| `MetricRow` | — | 标签 + 等宽数值 + 单位 |
| `ChartPanel` | — | 折线图标题 + 时间窗 + 图例 |
| `ProfileCard` | state(选中/可用/未准备) | 档位名 + 适用场景 + 差异 + 动作 |
| `ArtifactRow` | state(已校验/缺失/校验失败) | 制品 key + 量化 + 文件数 + 状态 |
| `DiagnosticRow` | state(通过/注意/失败) | 图标 + 名称 + 一句话 |

### 11.5 原型连线

1. **配音主流程**：配音台输入文稿 → 选择音色（popover 试听）→ 生成 → 结果条播放/导出。
2. **音色创作流程**：描述 → 生成候选 → 试听 A/B → 保存 → 音色库出现。
3. **受阻恢复流程**：配音台能力缺失 → 去模型页切档 → 返回配音台重试。

工具写入的原型连线只覆盖**同一页内的顶层 frame**：Figma 插件 API 在目标节点跨页或嵌在画板内部时会拒绝这条反应。
因此 `04 Screens` 内 16 帧之间的侧边栏导航与状态行入口已自动连好（126/126 生效），而上面三条流程的连线、
以及设置窗口内的跳转需要在 Figma 里手动补。

### 11.6 实际交付（2026-09-15）

本节记录**已经生成并核对过的** Figma 产物，与上面的目标规格区分开。

| 项 | 事实 |
|---|---|
| Figma 文件 | `SpeechRail`（Drafts，免费版），https://figma.com/design/7wZpCvjTTdfn4hMDMdcmRk/SpeechRail |
| 页面 | 7 页：`00 Cover`、`01 Foundations`、`02 Components`、`03 Flows`、`04 Screens`、`05 Menu & Settings`、`06 Archive` |
| Variables | 集合 `SpeechRail`：23 个颜色 + 20 个数值（Light mode） |
| Text styles | 9 个：`Title / Large`、`Title / Page`、`Heading / Section`、`Body`、`Body / Medium`、`Callout`、`Subheadline`、`Caption`、`Caption / Medium` |
| Components | 11 个 component set（Status Pill、Nav Item、Button / Primary、Button / Secondary、Card、List Row、Candidate Tile、Empty State、TextField、VoiceBadge、Icon Button） |
| Screens | 8 个 1440 × 900 画板：配音台、音色创作、音色库、我的作品、服务状态、运行监控、模型、诊断；浅色一列 + 深色克隆一列（深色帧命名 `<页面> · Dark`），共 16 帧；每帧带 `exportSettings = PNG @1x`，可直接在 Figma 里批量导出 |
| 文档页 | `03 Flows` 1688 × 861（三条主流程 + 步骤箭头）；`05 Menu & Settings` 2144 × 1529（菜单面板 ×3：默认 / 控制受限 / 深色，菜单栏状态项 ×2，设置窗口 ×3：通用 / 创作 / 服务）；`06 Archive` 1688 × 897（迁移前机架 vs 迁移后系统材质，另有「保留的 DNA」「移除的部分」两栏清单） |
| 画板总数 | 22 帧 = Cover 1 + Foundations 1 + Components 1 + Flows 1 + Screens 16 + Menu & Settings 1 + Archive 1；每个文档页只有 1 个顶层 frame，多出来的顶层节点会被自检报为 stray |
| 原型连线 | 126/126 生效：`04 Screens` 内 8 × 8 的侧边栏导航（跳过指向自身的那一格）+ 每帧状态行 → 服务状态；跨页与画板内部的连线不由插件写入，见 §11.5 |
| 生成器 | [`figma-kit/`](figma-kit/)：本机 Figma **开发插件**（`manifest.json` + `main.js` + `icons.js` + `build.js`），不是 Figma 官方插件 |

运行方式：`node figma-kit/build.js` 生成 `code.js` 并同步到 `~/Downloads/SpeechRail-figma-kit/`，然后在 Figma
**Plugins → Development → SpeechRail Design Kit** 执行（`⌥⌘P` 可重跑上一个插件）。生成是幂等的：重跑会清空并重建这 7 页，
不新增页面；页面重命名（`03 Screens` → `04 Screens`）在清空之前执行，避免上一轮的旧页名留成一张带内容的游离页。

#### 逐页精修（第二轮）

第一轮交付后逐页目视复查，问题集中在"页面看起来没做完"，而不是规范条文本身：内容在卡片内部聚在顶部、卡片底部留下成片空白、同一页里出现两套同类对象（例如可试听候选卡与失败候选卡）。本轮按页面处理：

| 页面 | 改动 |
|---|---|
| 配音台 | 字数/清空移进编辑器卡片页脚（分隔线之内）；控制条补 `⌘⏎` 键帽；结果条补「查看我的作品 ›」出口 |
| 音色创作 | 描述卡结构化为 描述区 / 计数行 / 特征 chips / 页脚；生成按钮旁补键帽；「生成失败」候选卡改为与其它三张相同的三段结构 |
| 音色库 | 行数补到 8 条铺满列表卡；Inspector 增加试听预览块与「使用次数 / 关联作品」；描述左对齐；动作改为「重命名 / 编辑描述 / 删除」 |
| 我的作品 | 行数补到 8 条，列表卡下方不再留出约 240pt 空白 |
| 服务状态 | 能力矩阵补「音色复刻」一行；收起的「技术细节」换成直接展示的「运行信息」键值卡 |
| 运行监控 | 图表高度 340 → 300；worker 表补到 4 行（`asr` / `tts-design` / `tts-base` / `diarization`） |
| 模型 | 档位卡补「分人 / aligner / TTS lane」三行规格并右对齐取值，卡片不再只有档位名和一句副标题 |
| 诊断 | 检查项补到 8 条；详情卡增加编号的「修复步骤」 |

键帽、键值行、Inspector 取值对齐由三个新 helper 统一：`kbd()`、`kbdInRow()`、`kvRow()`。

已知平台限制：

- **Dark 不是 mode。** Figma 免费版每个变量集合只允许 1 个 mode（实测报错原文：`in addMode: Limited to 1 modes only`），
  因此深色外观由 8 个浅色画板克隆而来，逐节点改绑到只含深色值的 `SpeechRail (Dark reference)` 集合。
  生产实现仍应使用真正的 Light/Dark 双 mode，这不是设计取舍，而是当前 Figma 账号的限制。
- 画板字体使用 `Inter`（Figma 插件环境取不到 SF Pro）；生产 UI 仍按 §5.5 使用系统字体。
- 画板里的编辑器与描述区是**固定高度的近似**（1440 × 900 的静态帧需要确定的高度）；§7.1 / §7.2 描述的是落地行为
  （编辑器占满剩余高度、描述区最小 160pt），两者不冲突，但看图时不要按固定高度实现。
- 设置窗口的高度按内容取高、三个标签页对齐到最高面板；§11.2 的 640 × 420 应视为下限，不是固定值 ——
  卡死在固定高度时最长的设置页会出现内部溢出（实测 `content ▸ group +8B~20B`）。

第二轮 audit 的实测结果（`03 Screens`，每次运行输出在插件面板）：

- `AUDIT VERDICT · 16 frames · all clean (overflow / inner / unbound-gray / dark-binding)`：16 帧全部 1440 × 900，
  无内容越界，**也没有卡片内部的溢出**（`inner`）。
- 浅色帧绑定关系为 dark/light `0/N`；深色帧为 `N/0`，且字面量与变量解析值一致（如 `lit:#201e21 var:#201e21/dark`）。
- `bind errors: 0`。
- 16 张 1x PNG 已从 Figma 批量导出到 `~/Downloads/speechrail-screens-20260915/v5/`（同名 `-dark` 为深色克隆），并逐页目视复查。

第二轮修掉的生成器缺陷（都属于脚本问题，与 Figma 本身无关）：

- 给 paint 绑定变量必须用 `figma.variables.setBoundVariableForPaint`；`node.setBoundVariable("fills", …)` 对 paint 字段无效，
  异常又被 `try/catch` 吞掉，导致所有填充停在占位灰 `#808080`，整个文件看起来是灰的。
- 语速滑块的 `thumb` 只创建未挂载，成为画布上的游离节点。
- 越界审计最初把节点自身的 `clipsContent` 也算作“已裁剪”，使 `overflow none` 成为恒真结论。
- `resize()` 在 auto-layout 的 AUTO 轴上不生效（下一次布局就会覆盖回去），所以 `size()` 必须同时把该轴切成 `FIXED`。
- `layoutGrow` / `layoutAlign` 只有节点已经有 auto-layout 父级时才写得进去；`add(d, node)` 之后再 `grow(node)` 会被静默忽略，
  节点保持“按内容撑高”。现由 `applyLayout()` 在挂载后重放这些意图。
- `text()` 先写 `characters` 再套 `textStyleId`，节点仍按旧字体测量，按钮和表格单元格会按偏小的宽度裁掉自己的标签（现改为先套样式）。
- 越界审计只看根帧时，卡片内部的溢出无人发现；新增 `auditInnerOverflow()` 逐对遍历父子。
- `spacer()` 用的是 `layoutAlign:STRETCH` + `layoutGrow`，不能放进“按内容撑高”的卡片：会在卡片内部制造 `+54B` 溢出
  （我的作品与模型两处即由此产生，已移除）。

#### 第三轮：补齐流程 / 菜单栏 / 归档页

第二轮只建了 8 个屏幕，而侧边栏之外的三个页面在结构里一直存在却是空的。第三轮把它们补出来：新增 `03 Flows`、
`05 Menu & Settings`、`06 Archive` 三个构建器，原有 16 个屏幕帧由同一套 `SCREEN_DEFS` 重建，内容不变。

| 页面 | 内容 |
|---|---|
| `03 Flows` | 配音 / 音色创作 / 受阻恢复三条主流程，每步一张卡片 + 步骤箭头，脚注说明这些连线为何要手动补 |
| `05 Menu & Settings` | 菜单面板 ×3（默认 / 控制受限 / 深色参考）、菜单栏状态项 ×2（常态只有图标、操作进行中才带文字与琥珀点）、设置窗口 ×3（通用 / 创作 / 服务） |
| `06 Archive` | 迁移前「机加工机架」与迁移后系统材质左右对照；机架一侧写死字面值 `#151719` / `#101214` / `#33373B` / `#1F2327` / `#3A3F45` / `#2E3338`（**故意不绑变量**，它就是要展示“迁移前没有 token 语言”），另附「保留的 DNA」与「移除的部分」两栏 |

第三轮修掉的生成器缺陷：

- 菜单栏状态项组装时漏了 `add(bar, item)`，两个状态项掉在页面顶层变成游离 frame（`05 Menu & Settings` 因此显示 3 帧）。
  据此新增 **stray 顶层节点检查**：每页只允许一个已知名字的顶层 frame，多出来的直接报出来，避免同类遗漏再次无声通过。
- 设置窗口固定高度会在最长的设置页内部溢出；改为按内容取高，再把三个窗口对齐到最高面板，切换标签页时窗口尺寸在图上保持一致。
- `inner` 溢出报告现在带 `branch`（出问题的顶层子节点），能直接指到 `column/service ▸ content ▸ group` 这一级，
  而不是只说“某帧有内部溢出”。

第三轮 audit 的实测结果（每次运行输出在插件面板）：

- 自检范围从「带屏幕的 4 页」扩到**全部 7 页**：`00 Cover` / `01 Foundations` / `02 Components` 三页此前不在 audit 内，
  它们同样是单帧页面，同样可能悄悄漏掉挂载。
- `AUDIT VERDICT · 22 frames · all clean (overflow / inner / unbound-gray / dark-binding / stray)`：22 帧全部通过五项检查。
- `prototype links: 126/126`、`bind errors: 0`、`no errors`；生成耗时约 4.3 ~ 4.6 s。
- 审查用 PNG（0.5x）已从最终构建导出：`~/Downloads/Flows.png`、`~/Downloads/Menu & Settings.png`、`~/Downloads/Archive.png`。
  导出由 `figma-kit/main.js` 顶部的 `EXPORT_PNGS` / `EXPORT_PAGES` 开关控制，默认关闭（构建不应该写文件）。

## 12. 风险与未决

### 12.1 多角色叙事

早期概念包（`docs/design/archive/2026-09-12-macos-app-design-package/`）描绘了“粘贴小说 → 自动分角色 → 逐段生成”的工作台。当前服务契约**不提供**该能力，本次重设计不引入它。

如果产品方向确实要走到那一步，正确顺序是：先由服务端契约提供分段与多说话人 TTS，再设计界面；否则界面会承诺后端做不到的事。

### 12.2 与现有 active 设计系统的关系

本包与 `macos-app-design-system.md` 在材质、圆角、颜色 token 上直接冲突。若本提案获批，必须**同步修订**那份文档并更新其验收清单；不允许两份规范长期并行。

### 12.3 尚未验证

- 目标 API（`.rect(corners: .concentric)`、`ConcentricRectangle`、`glassEffect` 的具体用法）需在 Xcode 26 SDK 上实测确认可用性与行为。
- 深色/浅色、Increase Contrast、Dynamic Type、Reduce Motion 的桌面人工矩阵未执行。
- VoiceOver 实测未执行。
- 本包未做任何构建、测试或运行态验证；未修改任何 Swift 源码。

已核对的部分（见 §11.6）：Figma 产物的帧尺寸、绑定归属、颜色解析值、越界（含卡片内部）与占位灰计数由插件 audit
实测输出（`all clean`，`bind errors: 0`）；16 帧已导出 1x PNG 并逐页目视确认，浅色与深色两列都已看过。
这**不等于** App 侧已实现或已验证 —— Swift 代码仍未被触碰，本轮亦未执行任何构建、测试或 UI 自动化。

### 12.4 决策记录与未决项

已于 2026-09-15 决定：

1. **采纳**“单强调色（钢轨青）+ 声音语义琥珀”的配色收敛；`AcousticMaster.*` 收敛为 `VoiceAccent`，不再保留更重的品牌机架视觉。
2. **纳入**作品删除/重命名（D12），随「我的作品」页面批次一起实现（删除需破坏性确认）。
3. 落地按 §10 阶段推进，从阶段 1 外壳开始。

未决：

- **浅色强调色有两处数值**：`Assets.xcassets/AccentColor` 浅色为 `#23687D`，而 Figma 变量与 `Color.rail` 为 `#2A4E57`（深色两者一致，均为 `#4FA4BA`）。§5.4 写“继续保持资产色”，§11 又写 Figma 数值是设计事实来源，两者冲突；进入阶段 2 前需要定一个，届时同步资产与 token。
