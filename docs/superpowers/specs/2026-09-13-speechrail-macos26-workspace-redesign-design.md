---
title: "SpeechRail macOS 26 任务型主窗口与服务 Inspector 重构"
status: active
audience: "SpeechRail macOS App 产品、设计、开发与测试人员"
version: "0.1.0"
date: 2026-09-13
---

# SpeechRail macOS 26 任务型主窗口与服务 Inspector 重构

## 1. 决策摘要

采用“任务型主窗口 + Inspector”作为 SpeechRail macOS App 的重构基线。

重构不再把管理控制台、运行监控和模型下载实现为连续堆叠的玻璃卡片，而是将它们收敛为
清晰的任务页面：页面顶部回答当前状态和下一步，主区域承担用户任务，Inspector 按需展示
开发者细节。侧边栏保持 macOS 原生两级导航，服务状态进入页面顶部和工具栏，不再使用
固定底部状态栏。

本方案保留“音色创作”产品主线，并将其改为编辑工作区与候选/预览 Inspector 的结构。
模型下载、文件校验、档位应用和操作恢复继续是正式能力；下载完成不等于档位已应用。

本规范先于代码重构生效。实现前必须先获得本规范的用户确认，再编写实施计划。

## 2. 现状问题与证据

### 2.1 已确认的 UI/UX 问题

当前 App 的导航虽然使用 `NavigationSplitView`，但 detail 页面普遍采用以下结构：

```text
页面标题
说明卡片
控制 Agent 卡片
状态卡片
能力卡片网格
操作卡片
技术详情卡片
底部服务状态卡片
```

这会产生四个产品问题：

1. 普通用户看见许多同等重量的区块，却不知道当前页面的唯一主要任务；
2. 服务状态、操作入口和下一步建议分散在不同卡片中；
3. 开发者细节默认与用户信息争夺视觉层级，而不是在选中对象后进入 Inspector；
4. 每个 `VStack` 都叠加玻璃表面，Liquid Glass 从功能层退化为装饰层。

### 2.2 已确认的运行集成问题

2026-09-13 对当前已安装 App 和本机正在运行的 managed runtime 实测时，App 的
`AgentCommandRunner` 为模型目录、状态和准备动作发送 `speechrail model ...`，但 runtime 返回：

```text
argument command: invalid choice: 'model'
```

这是服务组件版本/能力不一致，不是用户操作错误。重构必须包含能力探测和清晰的错误呈现，
不能在 UI 中吞掉错误、无限重试或把“模型状态未知”伪装成“模型已就绪”。

## 3. macOS 26 研究结论

本方案以 2026-09-13 可访问的 Apple 官方 macOS 26 资料为依据：

- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
  强调可调整窗口、菜单栏命令、键盘操作和减少不必要的层级；
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout) 要求区分内容层与
  控制层，使用对齐、间距和渐进式披露建立层级；
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars) 将 sidebar 定义为
  顶层导航，并建议层级不超过两级；
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) 要求工具栏动作
  按逻辑分组，并让命令同时存在于菜单栏；
- [Panels](https://developer.apple.com/design/human-interface-guidelines/panels) 建议 Inspector
  展示当前选中对象的细节，而不是把面板当作文档容器；
- [Liquid Glass](https://developer.apple.com/design/human-interface-guidelines/liquid-glass) 将玻璃定位为
  导航和交互功能层，不应覆盖所有内容；
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
  展示了 macOS 26 的 `NavigationSplitView`、系统 toolbar、`ToolbarSpacer`、Inspector、
  `backgroundExtensionEffect` 和受约束的 `GlassEffectContainer` 用法。

由此固化以下产品规则：

1. 一页一个主要任务，一个主要动作；
2. 状态先说结论，再提供原因和下一步；
3. 内容使用标准 macOS 内容层，玻璃只服务于导航和关键控制；
4. 结构化资源使用 list/table/outline，选中项的技术信息进入 Inspector；
5. 重要状态和动作不得只放在窗口底部；
6. 普通用户默认读懂结果，开发者主动打开细节；
7. App 直接使用 macOS 26 能力，不为 macOS 14 增加视觉兼容分支。

## 4. 范围与非目标

### 4.1 范围

- `macos/SpeechRailApp` 的导航、页面骨架、服务管理、运行监控、模型下载和音色创作界面；
- `SpeechRailDesignTokens.swift` 的统一 token 体系；
- 普通用户和开发者两层信息架构与可访问语义；
- 模型控制命令的能力探测、版本不匹配呈现和恢复入口；
- macOS 26 Light/Dark、高对比度、Dynamic Type、Reduce Motion、键盘和 VoiceOver 验收。

### 4.2 非目标

- 不改变 SpeechRail Python 服务的单 worker、资源治理、模型 manifest 或公共音频协议；
- 不让 App 直接加载模型、处理音频、执行 `launchctl` 或成为新的服务 owner；
- 不允许用户输入任意模型 URL、shell 参数或仓库路径；
- 不自动下载、加载、卸载或应用模型；所有模型变更继续通过用户确认；
- 不删除 VoiceDesign / 音色创作框架；
- 不修改当前与本任务无关的 MCP/Python 未提交改动；
- 不使用 macOS 14 作为 App UI 的兼容目标。

## 5. 信息架构

### 5.1 主窗口

主窗口使用 `NavigationSplitView`：

```text
创作
  配音台
  音色创作
  音色库
  作品

服务
  服务状态
  模型
  运行监控
  诊断
```

侧边栏只承担顶层导航，不放解释性长文。每个行项目提供 SF Symbol、简短标题和完整
accessibility value；服务组可在“服务”标题旁显示紧凑的健康状态，但不使用颜色作为唯一信息。

页面标题由系统 toolbar 负责，正文不重复渲染同一个大标题。正文开头只保留一句页面定位和
当前主要状态，使标题、目的、操作不再重复出现三次。

### 5.2 公共窗口层

- sidebar：系统 Liquid Glass 导航层；可隐藏、可调整宽度；
- toolbar：页面标题、页面级主要动作、刷新/搜索/Inspector 控制；
- detail：标准内容背景，不添加覆盖 toolbar scroll-edge 的自定义根背景；
- Inspector：仅在存在选中对象或开发者请求时出现，展示上下文细节；
- 菜单栏：复用服务启停、打开控制台、开始音色创作和设置等高频命令；
- 不再渲染 `ServiceStatusFooterView` 作为每个页面的固定底栏。

### 5.3 服务状态

服务状态页面首先回答“能不能用”：

```text
┌──────────────┐ ┌──────────────────────────────────────────────┐
│ 服务状态     │ │ 服务可用                         [重启服务]    │
│ 模型         │ │ Quality · 当前档位  ·  最近检查：刚刚         │
│ 运行监控     │ │ SpeechRail 已准备好接收本机语音请求。          │
│ 诊断         │ ├──────────────────────────────────────────────┤
│              │ │ 能力                                             │
│              │ │ 语音识别       已就绪                           │
│              │ │ 语音合成       已就绪                           │
│              │ │ 实时语音       已就绪                           │
│              │ │ 分人识别       按当前档位启用          [查看详情] │
│              │ ├──────────────────────────────────────────────┤
│              │ │ 下一步：没有需要处理的事项        [运行预检]    │
└──────────────┘ └──────────────────────────────────────────────┘
```

设计要求：

- 顶部只保留一个结论状态和一个主要动作；
- 能力使用可扫描的 list/rows，不使用四个同等权重的 Capability card；
- 启动、停止、重启放入 toolbar/菜单，停止和重启保留确认框；
- 控制 Agent 未授权时，在状态标题附近显示影响范围和恢复动作；
- 端口、后端、版本和 worker 只在“开发者详情”或 Inspector 展示。

### 5.4 模型

模型页是资源浏览器，采用“档位列表 + 选中档位主内容 + Inspector”：

```text
┌────────────┐ ┌──────────────────────────┐ ┌──────────────────┐
│ Quality    │ │ Quality · 创作优先       │ │ 开发者详情       │
│ Balanced   │ │ VoiceDesign 与高质量对齐 │ │ 模型 ID          │
│ Light      │ │ 准备大小：…              │ │ revision         │
│            │ │ 磁盘可用：…              │ │ SHA-256          │
│            │ │ [下载并校验] [应用档位]  │ │ 文件清单         │
│            │ ├──────────────────────────┤ │ 来源/量化        │
│            │ │ 制品列表                  │ └──────────────────┘
│            │ │ ASR · TTS · Aligner      │
└────────────┘ └──────────────────────────┘
```

设计要求：

- 档位行说明“适合谁、提供什么、需要多少空间”，而不是只显示枚举名；
- 选中档位的主内容展示准备结果和文件状态；
- 制品使用 list/table row，点击或展开后在 Inspector 查看 `modelID`、provider、repository、
  revision、量化、文件数、大小和校验结果；
- `下载并校验` 是准备动作，`应用档位` 是运行配置变更，两者必须分开确认；
- operation 以页面顶部 inline progress bar 或 toolbar 状态呈现；不新增独立的进度卡片；
- `accepted/running/interrupted/failed/committed/cancelled` 均提供明确文字和下一步；
- App 重启后从 Control Agent 恢复可恢复 operation；中断时只提供重新准备，不伪造断点续传；
- 没有 `model` 能力时显示“模型管理暂不可用：服务组件版本不匹配”，并提供“打开诊断”入口。

### 5.5 运行监控

监控页首先给出“现在是否需要处理”，再展示趋势：

```text
┌─────────────────────────────────────────────────────────────┐
│ 运行监控                         正常 · 最近更新：刚刚       │
├─────────────────────────────────────────────────────────────┤
│ 活跃请求  2       排队请求  0       已处理 1,284             │
├─────────────────────────────────────────────────────────────┤
│ 请求趋势 / 延迟趋势                                           │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ 最近事件：无异常                                             │
└─────────────────────────────────────────────────────────────┘
```

设计要求：

- 顶部显示健康结论、采样时间和必要的行动入口；
- 首屏使用一个主要趋势图，不再使用四个独立 MetricTile 争夺层级；
- 活跃请求、排队、累计处理和拒绝请求使用紧凑的指标行，数字采用 tabular figures；
- 延迟、worker、RTF、资源预算等开发者数据在 Inspector 或“开发者详情”中展示；
- 图表在样本不足时使用明确空状态；所有图表提供 `AXChartDescriptor`；
- 颜色、动画和刷新频率都不能是唯一状态来源，5 秒刷新要有文本时间戳。

### 5.6 诊断

诊断页采用“检查项列表 + 选中项详情”：

- 左侧列出预检检查项和通过/失败/未知状态；
- 右侧解释失败原因、影响范围、是否会改动运行状态和建议动作；
- 普通用户看到“重新启动服务”“准备模型”“打开模型页”等语义动作；
- 开发者详情展示检查名、脱敏结果、错误码和组件版本，不展示绝对模型路径、token、原始音频或完整日志；
- 诊断动作仍遵循“先说明影响，再确认执行”。

### 5.7 创作层

“音色创作”是 SpeechRail 的产品主线之一，必须保留：

- `音色创作`：主编辑区输入音色描述，右侧 Inspector 展示候选、试听和保存状态；
- `配音台`：主编辑区输入文本，右侧 Inspector 选择已保存音色、参数和生成状态；
- `音色库`、`作品`：使用 list/table 和空状态，不用大面积空白卡片；
- 服务未就绪时，创作页显示“为什么暂不可用”和跳转服务状态的动作；
- 创作页不重复显示服务 footer，不把服务运维信息压入创作工作区。

## 6. 普通用户与开发者信息分层

### 6.1 普通用户层

默认内容必须包含：

- 当前结论：已就绪、准备中、需要处理、不可用；
- 简短用途：这个页面解决什么问题；
- 下一步：用户现在能做什么；
- 影响提示：操作是否影响所有客户端、是否占用磁盘、是否改变当前档位。

### 6.2 开发者层

开发者细节通过 Inspector、DisclosureGroup 或“显示开发者详情”进入，不改变普通用户的
主流程。可展示：

- service/version/backend/port；
- profile、artifact、revision、量化和文件校验计数；
- operation ID、phase、状态和字节进度；
- worker、ASR/TTS latency、RTF、队列和资源预算；
- 稳定错误码和脱敏能力探测结果。

不得展示：API key、Authorization、完整 prompt、原始音频、完整转写、embedding、实名 speaker、
绝对模型路径和可复用的内部日志内容。

## 7. SpeechRail Design Tokens

### 7.1 Token 原则

所有页面样式只能从
`macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift` 读取。页面不得散落
`Color(red:green:blue:)`、任意 `CGFloat`、重复字体或重复圆角。系统 semantic color、系统字体、
标准控件和系统材料优先于产品自定义值。

### 7.2 间距

| Token | 值 | 用途 |
|---|---:|---|
| `Spacing.micro` | 4 | 图标与文字、辅助标签 |
| `Spacing.xs` | 8 | 行内、紧凑组 |
| `Spacing.sm` | 12 | 列表行、控件组 |
| `Spacing.md` | 16 | 区块内部 |
| `Spacing.lg` | 24 | 区块之间 |
| `Spacing.xl` | 32 | 页面边距、主分栏间距 |

不再使用 40pt 作为默认页面节奏；只有明确的 hero 空间才可通过语义 token 使用额外留白。

### 7.3 几何与布局

| Token | 值 | 说明 |
|---|---:|---|
| `Corner.control` | 6 | 系统控件外的轻量容器 |
| `Corner.row` | 8 | 选中行、列表分组 |
| `Corner.surface` | 12 | 必须存在的独立内容表面 |
| `Layout.windowMinimumWidth` | 1120 | 避免三栏任务被压缩 |
| `Layout.windowMinimumHeight` | 720 | 保持页面说明、主操作和状态可见 |
| `Layout.sidebarIdealWidth` | 248 | 顶层导航 |
| `Layout.inspectorMinimumWidth` | 280 | 技术详情最小可读宽度 |
| `Layout.inspectorIdealWidth` | 336 | 默认 Inspector 宽度 |
| `Layout.contentMaximumWidth` | 1240 | 主内容最大宽度 |
| `Control.minimumHitTarget` | 44 | 键盘/指针/辅助功能触达尺寸 |

窗口和 Inspector 使用系统可调整行为；不通过固定卡片宽度锁死内容。

### 7.4 字体

| Token | 系统字体角色 | 用途 |
|---|---|---|
| `Typography.windowTitle` | `title2/semibold` | 页面主要标题 |
| `Typography.sectionTitle` | `headline` | 主要区块 |
| `Typography.body` | `body` | 用户说明和正文 |
| `Typography.secondary` | `subheadline` | 辅助说明 |
| `Typography.caption` | `caption` | 状态、更新时间、提示 |
| `Typography.technical` | `caption2/monospacedDigit` | revision、端口、指标和错误码 |

页面不为每个 card 定义一套独立标题字体。技术数字与用户说明必须视觉分层，不能让内部
字段成为默认首屏内容。

### 7.5 颜色

hex 仅作为品牌和设计评审参考；实现使用自适应语义色，并在深色/高对比度模式下服从系统。

| Token | 参考色 | 语义 |
|---|---|---|
| `Palette.railSignal` | `#4F67FF` | 主要动作、当前选择、服务信号 |
| `Palette.voiceAccent` | `#8B6BD9` | 仅用于音色创作和 VoiceDesign |
| `Palette.healthy` | `#2EA86B` | 已就绪、已验证 |
| `Palette.attention` | `#B87300` | 下载中、需处理 |
| `Palette.critical` | `#D24B4B` | 失败、不可用 |
| `Palette.canvas/content` | 系统背景 | 窗口层和内容层 |

`railSignal` 默认映射系统 accent；`voiceAccent` 只作为创作语义色，不用于服务健康状态。
健康、注意和失败必须同时有文字和 SF Symbol/形状表达。

### 7.6 表面与动效

| Surface | 使用场景 | 禁止事项 |
|---|---|---|
| `navigationGlass` | sidebar、toolbar | 不承载长文和模型文件列表 |
| `controlGlass` | 当前页面唯一主要操作区 | 不把每个按钮包装成玻璃卡片 |
| `contentSurface` | 表格、编辑器、图表、说明 | 不叠加玻璃和自定义阴影 |
| `inspectorSurface` | 选中对象的技术细节 | 不显示与当前选择无关的全局信息 |

默认使用系统控件动画；数据刷新和状态变化必须有文字反馈。Reduce Motion 下关闭自定义
transition，不能删除状态信息。

## 8. 组件与代码边界

### 8.1 共享组件

重构只抽取具有稳定语义的组件：

- `PageScaffold`：统一 toolbar 标题、说明、内容区域和 Inspector 容器；
- `StatusBanner`：统一健康结论、影响范围和下一步动作；
- `ServiceStatusBadge`：sidebar/toolbar 的紧凑服务状态；
- `CapabilityList`：服务能力的可扫描行列表；
- `ResourceList`：模型制品、诊断检查和创作资源的统一列表语义；
- `DeveloperInspector`：选中对象和技术详情的渐进式披露；
- `OperationBar`：下载/校验/应用等长任务的内联状态和取消/重试动作。

如果一个组件只服务单个页面且没有稳定语义，不为了减少文件数量而抽取。

### 8.2 页面文件职责

- `ControlCenterView.swift`：窗口层、导航、toolbar 和 Inspector 容器；
- `AppRoute.swift`：只描述导航语义、标题、用途和分组；
- `SpeechRailDesignTokens.swift`：唯一 token 来源；
- `ServiceOverviewView.swift`：服务结论、能力列表、下一步；
- `ModelManagementView.swift`：档位资源浏览、下载校验、应用和恢复；
- `RuntimeMonitoringView.swift`：健康摘要、趋势和监控 Inspector；
- `PreflightDiagnosticsView.swift`：检查项列表、解释和恢复动作；
- `CreatorSurfaceViews.swift`：配音台、音色创作、音色库和作品工作区。

### 8.3 命令一致性

Toolbar、菜单栏、控制中心按钮和确认框必须调用同一组 `ControlCommand` 语义，不复制一套
只为 UI 服务的命令。服务 owner 仍是现有 `com.speechrail` LaunchAgent，App 不能直接创建
第二个服务实例。

## 9. 模型能力探测与错误交互

模型页加载前或首次刷新时，Control Agent 必须返回固定能力结果：

- `supported`：读取 catalog/status，显示模型资源；
- `unsupported`：显示版本不匹配状态和诊断入口；
- `notReady`：显示服务/Agent 未就绪及恢复动作；
- `failed`：显示稳定错误分类，不将异常文本直接当作用户说明。

当出现 `speechrail model` 不被当前 runtime 识别时：

1. 普通用户看到“模型管理暂不可用：服务组件版本不匹配”；
2. 页面给出“打开诊断”动作；
3. Developer Inspector 显示能力名、服务版本、受支持命令和脱敏错误码；
4. App 不自动升级 wheel、下载模型、切换 profile 或重启服务；
5. 修复必须在控制 Agent/服务契约边界完成，并补充回归测试。

## 10. 可访问性与交互确认

- 导航顺序为：sidebar → 页面定位 → 当前结论 → 主要动作 → 资源/检查列表 → Inspector；
- 所有状态同时提供文字、图标/形状和 accessibility label/value；
- 图表提供标题、时间轴、数值轴和样本描述；
- list/table 保留持久选中状态，Inspector 跟随选中项更新；
- `DisclosureGroup` 保留展开/收起动作，不用 combine 吞掉子控件；
- 下载、校验、应用和重试操作提供清晰的确认语句；
- 停止、重启和应用档位说明影响范围；取消操作使用系统 cancel role；
- 所有高频动作可从菜单栏、toolbar 或键盘到达，不依赖 hover；
- 不用颜色、动画或声音作为唯一状态来源。

## 11. 实施前验收标准

本设计完成后，至少必须满足：

1. 首屏可以在 5 秒内回答页面定位、当前状态和下一步；
2. 管理控制台、运行监控、模型下载不再是纵向卡片堆叠；
3. 页面中不存在重复的 route 大标题、重复服务 footer 或无语义玻璃面板；
4. 模型下载、校验、应用、取消、恢复和失败状态可区分；
5. VoiceDesign 页面仍可进入描述、候选、试听和保存的产品主线；
6. 普通用户默认不需要阅读端口、revision、worker 和原始错误文本；
7. 开发者可以从 Inspector 获得排障所需的脱敏技术上下文；
8. 当前 `model` 命令能力不匹配不会再以原始 CLI 错误污染普通页面；
9. App 使用 macOS 26 原生导航、toolbar、Inspector 和 Liquid Glass 层级，不加入 macOS 14 UI fallback；
10. 代码、原生测试、构建、静态检查和 git diff 校验全部通过，人工视觉/VoiceOver 结果单独记录。

## 12. 回退与风险

- token、导航和页面 UI 使用独立逻辑 commit，可回退而不影响 Python runtime 和模型文件；
- ControlKit 能力字段保持可选和向后兼容，旧 Agent 只显示不可用/未知，不执行危险重放；
- 模型 operation 的终态以 manifest/status 重新校验为准，不信任 UI 缓存；
- App 当前运行版本的 `model` 命令不匹配是实现前必须解决或明确呈现的已知风险；
- UI 自动化可能受 macOS 菜单遍历和桌面权限影响，若再次失败，必须区分代码失败与环境阻塞。
