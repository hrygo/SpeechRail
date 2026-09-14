---
title: "SpeechRail macOS 26 全局交互语言与设计 Token 重构"
status: proposed
audience: "SpeechRail macOS App 产品、设计、开发与验收人员"
version: "0.2.0"
date: 2026-09-14
---

# SpeechRail macOS 26 全局交互语言与设计 Token 重构

## 1. 决策摘要

这不是诊断页或某个工具栏的局部修补，而是 SpeechRail 控制台的全局视觉与交互语言重构。
目标是在 macOS 26 的原生行为之上建立一套有品牌识别度、信息层级清晰、可扩展且可验收的
Design Token 与组件边界，统一所有页面的标题、工具栏、侧栏、按钮、图标、可操作状态和反馈。

采用已确认的方案 A：Native-first global interaction language。标准 macOS 控件保留系统的
按压、焦点和辅助功能行为；所有 enabled 的操作/选择控件在其真实命中区统一提供
`pointingHand` 语义，静态内容仍保持普通箭头。自定义的可点击行/卡片还必须增加明确的
交互表面反馈。视觉语言以 SpeechRail logo 的信号/波形气质为品牌底层，但不再依赖
随意的胶囊、阴影或颜色堆叠表达层级。

本规格只约束 macOS App 的呈现层与交互层，不改变服务协议、模型运行时、XPC 契约或数据模型。
配音台、音色创作、音色库、我的作品、服务状态、运行监控、模型下载和诊断等产品能力均保留；
本轮解决的是它们共享的壳层与交互语义。

## 2. 当前问题与设计目标

### 2.1 已确认的问题

当前实现和审阅截图共同暴露出以下全局问题：

1. 顶部中心标题使用了容易溢出、换行或被状态胶囊挤压的组合结构，标题没有自然融入工具栏。
2. 右上角的多个无明确语义的图标按钮和通用“操作”入口造成认知负担，用户不知道每个按钮的用途。
3. 诊断页的布局问题反映了更广泛的页面编排问题：信息层级、主操作、详情和留白没有统一规则。
4. 侧栏选中态与文字/图标对比度不足，选中和未选中状态在不同外观模式下不够稳定。
5. 菜单 icon 的语义、线宽、光学尺寸和选中态不统一，无法形成可识别的导航系统。
6. 静态区域和可操作区域都表现为指针，用户无法通过光标、hover、按压和焦点判断可操作性。
7. 当前 token 虽已集中定义，但缺少完整的交互状态、组件语义和约束，页面仍有机会各自堆叠样式。

### 2.2 目标

- 顶部中心标题在最小支持窗口和长名称场景下始终单行、可读、不溢出，并成为稳定的全局识别锚点。
- 每个页面都遵循相同的标题、内容引导、主操作和状态反馈结构；页面差异来自任务内容，而不是视觉规则。
- 用户能区分静态内容、标准控件和自定义可点击对象，并在点击后看到即时、克制且可逆的反馈。
- 普通用户能理解“现在是什么状态、下一步做什么”；开发者能快速定位运行态、能力、日志和诊断信息。
- Light、Dark、Increase Contrast、Reduce Motion、键盘操作和 VoiceOver 下保持同一套语义。
- 视觉品质从“组件集合”提升为“有节奏的工作台”：层级由留白、排版、材质和状态构成，而非由卡片数量构成。

## 3. macOS 26 原生原则

实现以 Apple 的当前 HIG 和 AppKit 文档为行为基线：

- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)：使用清晰的按钮样式和角色，避免工具栏拥挤；自定义按钮必须有按压态，交互区域满足 macOS 的可用尺寸要求。
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)：工具栏承载当前标题、导航和少量高价值动作，动作需要有清晰语义。
- [Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices)：只在真实可操作命中区提供手型指针，静态文本、状态和空白区域保持普通箭头，避免无差别覆盖整页。
- [Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection)：选中和键盘焦点是不同状态，二者都必须可识别。
- [Offering help](https://developer.apple.com/design/human-interface-guidelines/offering-help)：图标按钮提供 tooltip/help 和 VoiceOver label，但不以 tooltip 替代可理解的界面文案。
- [NSCursor](https://developer.apple.com/documentation/appkit/nscursor)：交互指针必须绑定到真实布局边界；SpeechRail 对所有 enabled 操作/选择控件统一提供 pointing hand，disabled 和静态区域不注册 cursor rect。

具体约束：

- App 只面向 macOS 26，不增加 macOS 14 兼容分支，不为兼容牺牲 macOS 26 特性。
- 使用原生 `Button`、`Menu`、`NavigationLink`、`ToolbarItem`、`NavigationSplitView` 作为行为基座。
- Liquid Glass/Material 只用于需要层次的窗口、导航、工具栏和弹出层；内容卡片默认使用结构化填充和边界，不把所有内容包成浮起胶囊。
- 标准控件不覆盖原生 hover、按压和焦点行为；共享 cursor modifier 只补充统一的可操作性提示，自定义行为通过共享组件实现，禁止页面自行复制状态逻辑。

## 4. Token 语言

`SpeechRailDesignTokens` 是唯一的视觉状态来源。页面代码不得出现用于表达设计意图的裸颜色、
裸圆角、裸间距、随意阴影或局部 hover 数值。特殊布局数值必须有明确的组件 token 或 layout token。

### 4.1 分层

| 层 | 责任 | 示例 |
| --- | --- | --- |
| Foundation | 最小可复用尺度和原始材料 | `Spacing`, `Corner`, `Typography`, `Color`, `Motion` |
| Semantic | 把材料映射为产品语义 | `Canvas`, `Surface`, `Field`, `Ink`, `Border`, `Accent`, `Status` |
| Component | 规定组件的尺寸、层级和状态 | `Toolbar`, `Button`, `Navigation`, `Inspector`, `Metric` |
| Interaction | 统一可操作状态与输入反馈 | `rest`, `hover`, `pressed`, `focused`, `selected`, `disabled`, `loading` |

页面只使用 Semantic、Component 和 Interaction token；Foundation 只在共享组件内部使用。

### 4.2 尺度与形状

- 间距以 4pt 为基础节奏：`4 / 8 / 12 / 16 / 20 / 24 / 32 / 40 / 48`。20pt 用于主要内容分组，
  不是为填空随意增加卡片内边距。
- `8pt` 用于标准控件和短行，`12pt` 用于内容表面，`16pt` 用于工作台模块；状态 badge 才使用 pill。
  标题、页面容器和普通内容不得默认使用胶囊形状。
- 默认不使用大范围投影。层级优先使用材质、分隔线、色阶和留白；弹出层或确需悬浮的表面才使用
  统一的 `ambientShadow`。
- 所有交互控件的有效命中区域至少为 `44 × 44pt`，视觉图标可以更小，但不可把命中区域缩小到图标本身。

### 4.3 颜色与对比度

颜色按角色命名，而不是按色相命名：

- 内容：`Ink`, `InkSecondary`, `InkTertiary`。
- 表面：`Canvas`, `Surface`, `SurfaceRaised`, `Field`, `Navigation`。
- 边界：`Border`, `BorderStrong`, `FocusRing`。
- 品牌：`RailAccent` 用于 SpeechRail 的信号/波形强调，`VoiceAccent` 用于音色创作语境。
- 状态：`Ready`, `Attention`, `Critical`, `Info`，必须同时配合文字或图标，不得只靠颜色传达状态。

Light/Dark 使用动态颜色提供者，Increase Contrast 提升文字、边界和选中态之间的差异。正文和主要
控件文字达到可读对比度；次要文字只用于辅助说明，不得承载唯一关键信息。选中态的前景色必须
在两种外观下都与选中背景形成明确对比，禁止“蓝色背景 + 深色文字”的组合。

### 4.4 排版

- 使用系统字体层级；页面标题、工作区标题、分组标题、正文、说明、技术标识各自有固定语义 token。
- toolbar 工作区标题为单行 semibold，使用 `lineLimit(1)` 和 tokenized max width；不得通过无限缩小字号
  解决溢出，也不得让标题换行。
- 技术标识、路径、检查项 key 和指标数值使用 `technical`/`metric` token；面向普通用户的状态和动作
  使用自然语言，不直接暴露内部 key 作为主标题。
- 不用全大写、过重字重或长串粗体制造层级。层级来自字号、字重、留白和语义色的组合。

## 5. 全局组件与行为

### 5.1 `WorkspaceTitleLockup`

新组件替代现有页面各自拼装的 `WorkspaceTitleView` 视觉逻辑，仍挂载于标准 toolbar principal。

- 不绘制胶囊背景、独立大阴影或装饰性外框；它与工具栏材质自然融合。
- 采用固定的“导航 icon + 工作区标题”单一结构，避免标题变体切换时改变 toolbar 中心几何并挤压右侧操作。
- 工作区标题永远单行；使用 tokenized 固定槽位、尾部截断、适度缩放和 tightening，context 在视觉上不进入标题槽位。
- 服务状态不挤入中心标题。它作为独立的、带文字的状态组件放在工具栏的辅助区域；空间不足时只保留
  状态 icon + accessibility label，不能把状态 chip 强行塞进标题。
- 标题有明确的固定宽度 token，不使用 `layoutPriority` 抢占左右 toolbar item 的空间；context 与服务状态只作为辅助功能语义提供。
- 长名称、中文、英文、混合字符和 VoiceOver label 都需要单行和截断语义验证。

### 5.2 Toolbar 与动作入口

- 工具栏只保留一个清晰的动作组入口，名称使用“更多操作”或当前任务的动词，不显示无法理解的三个
  无标签图标组合。
- 页面最重要且高频的一个动作可以成为显式按钮，例如“开始诊断”“下载模型”“启动服务”；其余动作
  进入语义明确的 `Menu`，菜单项用动词开头，并按主次和破坏性排序。
- 图标按钮必须有 `.help(...)`、accessibility label 和 44pt 命中区；如果图标不能让普通用户理解，
  使用文字按钮或文字+图标，而不是增加 tooltip 依赖。
- 标准 `Button`/`Menu` 保留系统按压、焦点和辅助功能反馈；enabled 实例使用真实控件边界显示 pointing hand，不把静态内容或整页伪装成网页链接。

### 5.3 Navigation 与菜单 icon

- 侧栏行是原生 `NavigationLink` 语义，整行 44pt 命中区，选中、键盘焦点和 hover 分开表达。
- 选中态采用低噪声 accent fill + 高对比前景 + 必要时的 leading rail；不使用会吞没文字的高饱和纯色块。
- 未选中态保持稳定的 InkSecondary；选中态提升为 Ink，icon 与文字同步变化。所有状态在 Dark 和 Increase
  Contrast 下都可识别。
- icon 统一使用 SF Symbols 的同一光学尺寸、weight 和层级策略，不混用风格不同的自绘线框。推荐映射：
  `waveform`（配音台）、`wand.and.stars`（音色创作）、`person.wave.2`（音色库）、`square.stack.3d.up`
  （我的作品）、`server.rack`（服务状态）、`chart.xyaxis.line`（运行监控）、`cube`（模型）、
  `stethoscope`（诊断）。最终 symbol 以 SF Symbols 在 macOS 26 的可用性核对后固化在 route token 中。
- icon 选择集中在 `RouteIconView`/route token，页面不得传入临时 symbol 名称或自行改变图标大小。

### 5.4 Button、行和卡片

组件层提供以下明确层级：

- `Primary`：当前区域唯一的主要推进动作。
- `Secondary`：同一任务中的辅助动作。
- `Quiet`：低干扰的内联动作或查看详情。
- `Destructive`：删除、停止、卸载等不可逆或高风险动作，使用系统 role 和确认流程。
- `IconOnly`：仅适合用户已熟悉的高频动作，必须有 label/help。

可点击的检查项、指标、模型行、服务行和作品行必须是真实 `Button` 或 `NavigationLink`，并通过共享
`SpeechRailInteractiveSurface`/`ButtonStyle` 获得 hover、pressed、focus、disabled 和 loading 状态。
静态卡片不添加 `contentShape`、hover fill、click cursor 或“看起来像按钮”的装饰。

## 6. 指针、状态与反馈规则

| 对象 | 光标 | hover | pressed | focus |
| --- | --- | --- | --- | --- |
| 原生 Button/Menu/NavigationLink | enabled 命中区 pointing hand；disabled 系统默认 | 系统默认 | 系统默认 | 系统默认/共享 focus ring |
| 自定义可点击行/卡片 | `pointingHand` | 轻微表面高亮或边界增强 | 轻微缩放/填充变化，约 `0.985` | 明确的 `FocusRing` |
| 静态文本/卡片/指标 | 系统 arrow | 无 | 无 | 不可聚焦 |
| disabled 控件 | 系统默认 disabled 行为 | 无交互高亮 | 无 | 保留可解释的辅助功能状态 |
| loading 控件 | 保留可取消时的语义，否则 disabled | 不暗示可重复点击 | 显示进度而非重复触发 | label 说明进行中 |

- cursor rect 只覆盖真实的 enabled 控件边界；标准控件和 custom surface 都可通过共享 modifier 提供 pointing hand，静态区域不注册 cursor rect。
- hover 不能是唯一可用线索；文字、icon、命中区域和 accessibility 语义必须本身清楚。
- 按压反馈应即时且克制，避免弹跳、强烈缩放和与操作无关的动画。
- `Motion.standardDuration`、`pressedScale` 和 `selectionFeedback` 统一从 `Interaction`/`Motion` token
  获取；Reduce Motion 下去除缩放和非必要过渡，保留状态变化和必要的进度反馈。
- 点击成功、失败、取消和异步进行中都需要有明确的状态反馈，不能只依赖瞬时颜色变化。

## 7. 页面采用范围

共享实现集中在：

- `SpeechRailDesignTokens.swift`：分层 token、状态矩阵、组件尺寸和 motion。
- `WorkspaceComponents.swift`：交互表面、按钮层级、状态 badge、指标和共享内容单元。
- `SurfaceHeaderView.swift`：`WorkspaceTitleLockup`、状态辅助项和 toolbar 标题行为。
- `ControlCenterView.swift`：统一 toolbar、NavigationSplitView、侧栏选中/焦点语义和动作组。

以下页面只消费共享组件和 token，不再各自定义同类视觉规则：

`ControlMenuView.swift`、`CreatorSurfaceViews.swift`、`ServiceOverviewView.swift`、
`RuntimeMonitoringView.swift`、`ModelManagementView.swift`、`PreflightDiagnosticsView.swift`、
`ServiceStatusView.swift`、`ServiceRoutePreviewView.swift`、`SettingsView.swift`、
`ProfilePickerView.swift`。

页面重构顺序：先完成 token 与共享 primitive，再完成 App shell 和导航，随后按“服务状态/运行监控/模型下载/
诊断/创作与作品”的任务链逐页迁移。迁移过程中保留真实接线、模型下载和音色创作框架，不以静态占位页面
替代原有动作。

## 8. 辅助功能与可用性验收

- 所有可操作对象可通过键盘到达；焦点顺序与视觉任务顺序一致。
- VoiceOver 能读出对象名称、角色、当前状态、是否 disabled/loading 以及下一步可执行动作。
- 状态不只依赖颜色；成功、注意、失败和进行中同时有 icon、文本或进度语义。
- 标题、动作、状态和技术细节的可见/隐藏变化都不会产生重复或互相矛盾的 accessibility 元素。
- 长中文、长英文、混合字符、最小窗口、Light、Dark、Increase Contrast 和 Reduce Motion 均满足单行标题与
  可操作性要求。

## 9. 实施与验证顺序

1. 将 token 拆分为 Foundation、Semantic、Component、Interaction，并保留现有公共命名的迁移别名，避免一次
   性破坏页面编译；迁移完成后删除不再使用的别名。
2. 实现 `WorkspaceTitleLockup`、共享按钮/交互表面、导航行和 icon route token。
3. 重构 `ControlCenterView` 与 toolbar，移除通用的神秘图标组和标题胶囊。
4. 迁移所有页面的标题、动作按钮、可点击行、卡片和状态组件。
5. 做静态审查：检索页面裸颜色/间距、重复 title 拼装、局部 hover/cursor、无 label icon button 和不必要的
   `buttonStyle(.plain)`；核对公共 XPC/服务边界未改变。
6. 运行允许的编译/静态检查并进行人工视觉审阅：最小窗口、长标题、Light/Dark、Increase Contrast、Reduce
   Motion、键盘和 VoiceOver。

本项目此前已暂停自动化测试，本规格阶段和后续实现阶段均不自动运行 XCTest、XCUITest 或 Python 测试；
待用户明确解除暂停后，再按项目 gate 补齐自动化验证。安装、卸载、服务启停和真实模型操作不属于本规格阶段。

## 10. 接受标准

- 所有页面的 toolbar 中心标题使用同一 `WorkspaceTitleLockup` 规则，单行、无溢出、无重复 body title。
- 顶部动作只有可解释的显式主操作和一个清晰动作组；不再出现用户无法理解的三按钮集群。
- 所有导航 icon 由 route token 统一管理，光学尺寸、weight、选中态和对比度一致。
- 用户可通过系统行为、视觉状态、命中区域和反馈区分可操作/不可操作对象；自定义对象有按压态，静态区域没有
  虚假的 hover/cursor/click affordance。
- 设计 token 是页面唯一的视觉状态来源，Light/Dark/Increase Contrast/Reduce Motion 具有完整语义映射。
- 关键功能的真实动作仍然接线：服务状态、运行监控、模型下载、诊断、音色创作和相关导航没有被空壳替代。
- 不修改 REST、Realtime、XPC、worker、模型目录或服务生命周期契约；任何后端行为变更必须另行立项。

## 11. 回退策略

本轮变更限制在 macOS App 的 SwiftUI token、共享组件和页面呈现层。按逻辑提交后可以回退该提交恢复
旧的视觉实现；不触碰服务数据、模型文件、用户配置或运行时进程。若迁移中发现局部页面无法安全拆分，
保留旧组件作为临时兼容实现，但不得重新引入新的页面级 token 分叉。
