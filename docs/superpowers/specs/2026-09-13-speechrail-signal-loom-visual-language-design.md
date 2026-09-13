---
title: "SpeechRail Signal Loom 视觉语言与 App-wide Token 设计"
status: review
audience: "SpeechRail macOS App 产品、设计、开发与测试人员"
version: "0.1.0"
date: 2026-09-13
---

# SpeechRail Signal Loom 视觉语言与 App-wide Token 设计

## 1. 决策摘要

采用 **Signal Loom「信号织网」** 作为 SpeechRail macOS App 的全局视觉语言。

它把 SpeechRail 看成一条将本机语音信号接入、转换、观察和创作的清晰路径：

```text
输入 / 创作  →  模型能力  →  服务运行  →  结果 / 诊断
```

视觉上以“信号线、层级、留白和可追踪状态”建立秩序，以一处受控的暖色音色语义保留创作
温度。它同时服务两类用户：普通用户先看到“现在是什么状态、能做什么、下一步是什么”，
开发者再通过 Inspector 或开发者详情获得版本、worker、metrics 和错误码。

本规范先于实现生效。当前状态为 `review`：视觉方向已经确认，以下 token、组件规则和页面
映射需要作为下一轮实现的审阅基线；在用户确认本规范后，才编写实施计划并修改 SwiftUI。

## 2. 为什么要重做

此前问题不是诊断页单页问题，而是全局语言问题：

- 所有内容都被包装成同等重量的圆角卡片，页面缺少主次和阅读路径；
- 标题、页面说明、状态和操作彼此竞争，出现悬浮标题、重复标题或脱离上下文的按钮；
- 工具栏存在重复刷新/信息动作，侧边栏出现只有颜色没有语义的孤立绿色点；
- Inspector 默认承载重复内容、固定占位并发生截断，不能体现“选中对象的上下文细节”；
- 颜色、间距、圆角和表面 token 偏向实现方便，而不是围绕 SpeechRail 的产品语义；
- Liquid Glass 被当成装饰性容器，而不是 macOS 26 的导航和交互层能力。

因此本次不是换一组颜色，也不是把旧卡片重新配色，而是重建以下关系：

```text
语义 → 信息层级 → 页面结构 → 组件 → token → SwiftUI 实现
```

## 3. 设计目标与非目标

### 3.1 目标

1. 每一页在首屏回答“这是什么、现在怎样、下一步做什么”。
2. 让创作、管理、监控、模型下载和诊断共享一套能解释的视觉语法。
3. 保留并强化音色创作 / VoiceDesign，不让运维能力吞掉产品主线。
4. 模型下载、校验、应用、取消、恢复和失败状态清晰可区分。
5. 普通用户不必理解端口、profile、worker 和 revision 才能完成任务。
6. 开发者能在选中对象后取得脱敏且足够排障的技术上下文。
7. 直接使用 macOS 26 的系统导航、toolbar、Inspector、字体、材料和可访问能力；App 层不为
   macOS 14 增加兼容视觉分支。

### 3.2 非目标

- 不改变 Python 服务的单 worker、资源治理、模型 manifest 或公共音频协议；
- 不让 App 直接加载模型、处理音频、执行 `launchctl` 或成为服务 owner；
- 不自动下载、加载、卸载、应用模型或切换 profile；涉及运行状态和磁盘占用的动作必须确认；
- 不把模型、音频、日志、私有配置或 secrets 放入仓库；
- 不为追求视觉统一而删除系统标准控件、菜单栏命令、键盘路径或 VoiceOver 语义。

## 4. 设计语言：Signal Loom

### 4.1 三个关键词

| 关键词 | 在 SpeechRail 中的含义 | 视觉表达 |
|---|---|---|
| `Signal` 信号 | 服务是否可用、操作处于哪一阶段、结果是否可信 | 明确状态、信号线、图标与文字组合 |
| `Loom` 织网 | ASR、TTS、实时、分人和模型能力由同一服务编排 | 列表、轨道、对齐的列和连续的分组节奏 |
| `Studio` 工作室 | 音色创作是产品能力，不是运维页的附属按钮 | 一处受控的 `Voice` 暖色、编辑空间和试听 Inspector |

### 4.2 视觉性格

- **冷静但不冷漠**：服务和诊断使用深墨色、青绿色和靛蓝，创作使用陶土色点亮情绪；
- **精确但不机械**：技术信息使用等宽数字和紧凑行，用户说明使用正常比例字体；
- **有层次但不堆叠**：使用窗口、导航、画布、字段和 Inspector 的层级，不把每个区块做成卡片；
- **可信但不喧哗**：状态先结论后细节，颜色只加强语义，不承担唯一信息职责。

### 4.3 视觉重心

每个上下文只允许一个视觉重心：

- 服务状态：当前结论和唯一主要恢复动作；
- 运行监控：健康结论和一条主要趋势；
- 模型：选中的档位及其准备/应用状态；
- 诊断：选中的检查项及其下一步；
- 音色创作：描述编辑器与试听结果；
- 配音台：文本编辑器与生成动作。

任何“卡片、彩色背景、粗体标题、按钮、图表”只要无法解释为当前视觉重心，就不应提升为
一级表面。

## 5. Token 体系

### 5.1 命名原则

SwiftUI 的唯一实现来源仍为：

`macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`

新 token 使用“角色/语义”命名，不使用 `blueCard`、`successGreen`、`defaultPanel` 等视觉或
页面命名。命名空间按以下层次组织：

```text
SpeechRailDesignTokens
├── Color       // 语义颜色与自适应映射
├── Surface     // 层级和材质策略
├── Spacing     // 空间节奏
├── Corner      // 形状层级
├── Typography  // 内容角色
├── Layout      // 窗口与列约束
├── Control     // 触达、图标和控件尺寸
└── Motion      // 状态变化与 Reduce Motion
```

旧的 `Palette.success`、`Palette.warning`、`Corner.panel` 等兼容别名只允许在迁移期存在，
页面迁移完成后删除；不得继续新增引用。

### 5.2 语义颜色

下表是设计参考值，不代表页面直接使用固定 hex。实现必须提供 Light、Dark、Increase
Contrast 的自适应映射，系统 `Color.primary`、`Color.secondary`、系统 accent 和标准语义色
优先于自绘颜色。

#### 核心色板

| Token | Light 参考值 | Dark 参考值 | 角色 |
|---|---|---|---|
| `Color.ink` | `#17212B` | `#F2F5F6` | 产品墨色；仅用于品牌标记或高强调文本 |
| `Color.canvas` | `#F5F7F7` | `#171B1E` | detail 根内容画布 |
| `Color.field` | `#FFFFFF` | `#20262B` | 编辑器、列表组、图表所在的信息字段 |
| `Color.rail` | `#6073F2` | `#91A0FF` | 当前选中、主要动作、服务信号 |
| `Color.voice` | `#C97859` | `#E39A78` | 音色创作 / VoiceDesign 专属强调 |
| `Color.ready` | `#3A9C83` | `#65C5A8` | 已就绪、已通过、可继续 |
| `Color.attention` | `#B1812C` | `#E0B65A` | 需要处理、准备中、资源不足 |
| `Color.critical` | `#C94E52` | `#F28A8C` | 失败、不可用、危险操作 |
| `Color.info` | `#4C86B8` | `#83B9E8` | 信息、能力说明、开发者提示 |

#### 语义映射

| Token | 用途 | 禁止用法 |
|---|---|---|
| `Foreground.primary` | 用户正文、标题、主要值 | 不用作大面积色块 |
| `Foreground.secondary` | 辅助说明、时间、范围 | 不承载关键结论 |
| `Foreground.technical` | 端口、版本、revision、错误码 | 不用于普通用户标题 |
| `Signal.ready` | `已就绪`、`通过`、可执行 | 不只画一个绿点 |
| `Signal.attention` | `需要处理`、`准备中`、`未安装` | 不暗示失败 |
| `Signal.critical` | `不可用`、`失败`、危险动作 | 必须同时有文字与图标 |
| `Signal.info` | 能力、来源、解释 | 不与健康状态混用 |
| `Accent.rail` | 服务/导航/主要动作 | 不用于音色创作结果 |
| `Accent.voice` | 音色描述、候选、试听、保存 | 不用于服务健康或错误 |

### 5.3 表面层级

表面不是“每个区块一个卡片”，而是内容所处的空间层级：

| 层级 | 语义 token | macOS 26 实现策略 | 允许内容 |
|---|---|---|---|
| 0 | `Surface.window` | 系统窗口背景 | 全局窗口承载 |
| 1 | `Surface.navigation` | 系统 sidebar / toolbar glass | 导航、页面命令、窗口级控制 |
| 2 | `Surface.canvas` | 自适应内容背景 | 页面主体、滚动内容 |
| 3 | `Surface.field` | 标准内容表面，必要时细描边 | 编辑器、列表组、图表、资源区 |
| 4 | `Surface.inspector` | 可折叠的上下文侧栏，内容表面 | 当前选中对象的细节 |
| 5 | `Surface.control` | 系统控件或薄材质 | 主要动作、筛选、紧凑操作 |

规则：

1. `navigation` 可以使用系统 Liquid Glass；`canvas`、`field`、`inspector` 不铺玻璃。
2. `field` 必须有内容语义：没有表格、编辑器、图表或资源列表时，不应凭空创建。
3. 同一页面最多一个 `Surface.control` 视觉重心，次要按钮使用标准 macOS 控件层。
4. 默认不使用自定义阴影；层级由留白、描边、选择态和系统材料完成。
5. `Surface.inspector` 只显示当前选中对象或用户主动请求的开发者详情，不重复页面结论。

### 5.4 空间节奏

| Token | 值 | 用途 |
|---|---:|---|
| `Spacing.hairline` | 1 | Divider / 结构线 |
| `Spacing.micro` | 4 | 图标与文字、状态图标内部 |
| `Spacing.xs` | 8 | 行内组、紧凑控件 |
| `Spacing.sm` | 12 | 列表行、标签组、字段内间距 |
| `Spacing.md` | 16 | 区块内部、表单字段 |
| `Spacing.lg` | 24 | 主区块之间 |
| `Spacing.xl` | 32 | 页面边距、主列分隔 |
| `Spacing.hero` | 44 | 仅用于创作编辑器或空状态的呼吸空间 |

页面默认节奏为 `4/8/12/16/24/32`。`44` 不是新的通用间距，只有编辑器主区或空状态经过
设计评审才可使用。禁止在页面中随意出现 `20`、`28`、`36`、`40` 等一次性数值。

### 5.5 形状与边界

| Token | 值 | 用途 |
|---|---:|---|
| `Corner.control` | 6 | 标准控件外的轻量容器 |
| `Corner.row` | 10 | 选中行、列表行组 |
| `Corner.field` | 14 | 编辑器、图表、资源字段 |
| `Corner.module` | 18 | 必须独立存在的主模块 |
| `Corner.window` | 22 | App 自有窗口边界（不覆盖系统窗口圆角） |
| `Corner.pill` | 999 | 标签、紧凑状态胶囊；不用于大按钮 |

边界规则：

- 内层圆角不得大于外层圆角；
- 同一垂直层级不能同时出现三种以上圆角；
- 模块没有实际独立语义时，改用 Divider、列表分组和留白；
- 线条默认使用 `hairline`，禁止用粗边框制造“卡片感”。

### 5.6 排版角色

使用系统 SF Pro，技术数据使用 SF Mono；字号由 Dynamic Type / 用户字体偏好接管，不在页面
内直接写字号。

| Token | 角色 | 默认字重 | 用途 |
|---|---|---|---|
| `Typography.display` | 编辑器/空状态主句 | semibold | 只用于创作主入口或没有数据时的明确邀请 |
| `Typography.pageTitle` | 页面标题 | semibold | 由 toolbar 承载，每页只出现一次 |
| `Typography.section` | 区块标题 | semibold | 能力、制品、最近事件等主要区块 |
| `Typography.body` | 用户说明 | regular | 页面定位、影响范围、下一步 |
| `Typography.label` | 行标题、按钮文本 | medium | 可扫描的控件和列表语义 |
| `Typography.caption` | 时间、辅助提示 | regular | 不承载唯一结论 |
| `Typography.metric` | 指标数值 | semibold / tabular | 活跃请求、延迟、容量 |
| `Typography.technical` | 开发者字段 | monospaced | 版本、revision、端口、错误码 |

规则：

- 页面标题不在正文重复；
- 用字重和间距建立层级，不用每个模块换一种字号；
- 技术字段必须有用户可理解的标签，不直接把 raw key 当主标题；
- 指标使用 tabular figures，避免刷新时数字跳动破坏扫描。

### 5.7 控件与布局

| Token | 值 | 规则 |
|---|---:|---|
| `Control.minimumHitTarget` | 44 | 指针、键盘和辅助功能最低触达尺寸 |
| `Control.icon` | 16 | 行内 SF Symbol |
| `Control.toolbarIcon` | 18 | toolbar 命令 |
| `Control.compact` | 28 | 紧凑辅助控件，不牺牲 hit target |
| `Control.regular` | 34 | 标准表单/按钮视觉高度 |
| `Control.prominent` | 40 | 页面唯一主要动作 |
| `Layout.sidebarIdealWidth` | 240 | 顶层导航 |
| `Layout.inspectorIdealWidth` | 304 | 上下文细节 |
| `Layout.contentMaximumWidth` | 1,240 | 大窗口下的内容节制 |
| `Layout.windowMinimumWidth` | 1,120 | 保证主任务可读 |
| `Layout.windowMinimumHeight` | 720 | 保证定位、状态和动作同时可见 |

窗口、sidebar 和 Inspector 必须可调整；固定宽度只用于默认值和最小可读约束，不能锁死
用户的工作区。

### 5.8 状态与信号语法

状态采用四部分组合：

```text
[SF Symbol / 形状]  [结论标签]  [一句解释]  [下一步动作]
```

例如：

```text
✓ 已就绪    SpeechRail 可以接收本机语音请求。    查看能力
! 需要处理  模型尚未准备，当前服务仍可提供基础能力。  准备模型
× 不可用    控制 Agent 未连接，服务动作暂不可执行。  运行诊断
```

禁止：

- 只有颜色或孤立绿点表达健康；
- 只显示“正常”而不说明对象和更新时间；
- 用红色 raw error 代替影响范围和恢复动作；
- 同一页面同时出现两个互相竞争的全局健康结论。

### 5.9 动效

| Token | 默认 | Reduce Motion |
|---|---:|---:|
| `Motion.stateTransition` | 180 ms | 0 ms |
| `Motion.selection` | 140 ms | 0 ms |
| `Motion.progress` | 系统控件动画 | 静态进度与文字时间戳 |

动效只表达状态变化的连续性，不表达状态本身。下载、预检和监控刷新必须同时显示文字、
进度/时间或结果；Reduce Motion 时保留全部信息。

## 6. 组件语法

### 6.1 `PageScaffold`

每页固定结构：

```text
系统 toolbar：页面标题 + 页面命令 + Inspector 控制
正文：一句页面定位
正文：StatusConclusion（可选，但不能重复 toolbar 状态）
正文：一个主任务区
正文：必要的列表/图表/编辑器
Inspector：按选中项或用户请求出现
```

`PageScaffold` 不自动生成卡片、底部服务栏或重复标题。它只提供对齐、滚动、toolbar 和
Inspector 容器。

### 6.2 `StatusConclusion`

用于服务、模型、诊断和长任务状态。必须有结论、对象、更新时间/阶段和下一步。主要动作
最多一个；停止、重启、应用档位等影响运行状态的动作必须进入确认流程。

### 6.3 `SignalRow`

用于能力、模型制品、检查项和事件：

```text
[状态图标] [主标题]                    [结论/值]
             [一句用途或影响说明]       [Disclosure / action]
```

行内不放大面积彩色背景；选中只使用轻量 `rail` selection fill 和明显的 keyboard focus。

### 6.4 `OperationBar`

用于模型下载、校验、应用、取消、重试和可恢复操作。它是页面内联的操作轨道，不是一个新
的“进度卡片”。必须区分：

```text
未开始 → 已接受 → 准备中 → 校验中 → 可应用 → 已应用
                         ↘ 失败 / 已取消 / 被中断
```

下载完成不等于档位已应用；应用前必须再次说明影响范围并确认。

### 6.5 `DeveloperInspector`

Inspector 只显示当前选中对象相关的信息。默认字段以标签/值形式展示，技术值使用
`Typography.technical`，支持复制但不暴露 secret、完整日志、绝对路径、原始音频、完整转写、
embedding 或实名 speaker。

### 6.6 `MetricStrip` 与 `TrendFigure`

监控首屏最多一个趋势图和一行紧凑指标，不再把每个指标做成同等权重的 MetricTile。图表
必须有文字标题、时间范围、样本状态和 accessibility chart descriptor；数据不足时显示原因
和下一步，而不是画一条误导性的平线。

### 6.7 创作组件

保留音色创作框架，并与服务页共享布局和状态语法：

- `VoiceDescriptionEditor`：主编辑字段，`Accent.voice` 只在此语义域出现；
- `VoiceCandidateInspector`：候选、试听、保存和生成状态；
- `DubbingComposer`：文本、音色、参数和生成操作；
- `CreatorEmptyState`：说明“能创作什么”和下一步，不展示运维卡片堆叠。

## 7. 页面映射

| 页面 | 用户定位 | 主视觉重心 | 默认 Inspector | 不应出现 |
|---|---|---|---|---|
| 配音台 | 用已有音色把文本变成语音 | 文本编辑器 + 生成 | 音色、参数、结果 | 服务 footer、端口字段 |
| 音色创作 | 描述并试听新音色 | 描述编辑器 + 候选 | 候选试听、保存状态 | 运维指标抢主位 |
| 音色库 | 管理可复用音色 | list/table | 音色元数据和试听 | 空白卡片网格 |
| 我的作品 | 找到并复用已生成结果 | 作品列表 | 文件/生成信息 | 技术日志首屏展开 |
| 服务状态 | 判断现在能不能用 | 单一健康结论 + 能力行 | 服务版本/worker | 四个健康卡片 |
| 模型 | 准备和应用模型档位 | 选中档位 + OperationBar | manifest、revision、校验 | 下载等于已应用的暗示 |
| 运行监控 | 判断是否需要处理 | 健康结论 + 一条趋势 | worker、延迟、资源预算 | 四个大 MetricTile |
| 诊断 | 找到原因并采取恢复动作 | 检查项列表 + 选中解释 | 脱敏错误码/组件版本 | 固定重复 Inspector |

## 8. 普通用户与开发者的渐进式信息

### 8.1 普通用户默认层

默认可见且可读的内容：

- 结论：`已就绪`、`准备中`、`需要处理`、`不可用`；
- 用途：当前页面解决什么问题；
- 影响：是否占用磁盘、是否影响所有客户端、是否改变当前档位；
- 下一步：一个主要动作和一个可选的了解更多入口。

### 8.2 开发者层

通过选中项、Inspector 或“显示开发者详情”进入：

- service/version/backend/port；
- profile、artifact、revision、量化、文件数和校验摘要；
- operation ID、phase、状态、字节进度；
- worker、ASR/TTS latency、RTF、队列和资源预算；
- 稳定错误分类、能力探测结果和恢复建议。

技术层必须与用户层保持同一结论，不得出现“普通用户说已就绪、Inspector 却显示未知”这类
语义冲突。若能力不匹配，用户层显示可理解的影响，开发者层补充证据。

## 9. 交互与 macOS 26 规则

1. `NavigationSplitView` 承载创作/服务两组导航；不另造平行导航栏。
2. 页面标题由 system toolbar 承载；正文不再重复一个同名大标题或浮动圆形标题。
3. toolbar 动作按语义分组；全局刷新、页面刷新和对象刷新只能保留一个当前有效入口。
4. 高频命令必须同时进入菜单栏/Commands，隐藏 toolbar 后能力仍然可达。
5. sidebar 的服务状态使用“图标 + 文字/accessible value”；不放只有颜色的状态点。
6. Inspector 默认跟随选中对象，可隐藏、可调整；没有选中对象时不渲染重复占位内容。
7. 重要操作使用系统确认框或明确 inline confirmation：下载/校验、应用档位、停止、重启、
   删除或覆盖都要写明影响范围。
8. 图表、列表、DisclosureGroup、按钮和状态都提供可访问 label/value；颜色、动效和声音不
   得是唯一状态来源。
9. Light、Dark、Increase Contrast、Dynamic Type、Reduce Motion、键盘和 VoiceOver 都属于
   设计验收矩阵，不以“默认浅色截图好看”作为完成标准。

## 10. 迁移规则

### 10.1 必须删除或替换

- 删除页面级重复标题、重复 `ServiceStatusFooterView` 和孤立健康点；
- 替换“标题 + 说明 + 状态 + 操作 + 技术详情 + footer”的通用卡片堆叠；
- 统一重复的 refresh / info / developer detail 命令；
- 将默认 Inspector 改为选中项上下文，而不是固定的全局详情栏；
- 将 `Palette` 的视觉命名替换为 `Color` / `Signal` / `Accent` 语义命名；
- 删除没有内容语义的 `.panel`、`.elevated` 包装和多层自定义阴影。

### 10.2 迁移顺序

1. 先替换 token 定义和表面层级，保留旧 alias 仅用于编译过渡；
2. 重构 `ControlCenterView` 与 `PageScaffold`，统一 toolbar、导航和 Inspector；
3. 迁移服务状态、诊断、监控和模型页，先完成状态/操作语义；
4. 迁移配音台、音色创作、音色库和作品，保留 VoiceDesign 主流程；
5. 删除旧 alias 和未使用组件，补充 UI/可访问性回归测试；
6. 更新 active design system 文档和视觉验收记录。

迁移期间不得同时维护两套“当前 token”文档；未迁移页面必须明确标记，不得把临时兼容 alias
当作新的设计 API。

## 11. 验收标准

### 11.1 视觉与结构

- 首屏五秒内能说清页面用途、当前状态和下一步；
- 页面不存在无语义的卡片堆叠、重复标题、重复服务 footer 或漂浮孤立按钮；
- 只有一个主要视觉重心；主要动作、次要动作和技术详情层级可见；
- Light/Dark/Increase Contrast 下颜色仍满足对比度，状态不依赖颜色；
- 选中行、焦点环、Inspector 和列表列对齐，不出现截断的固定三栏。

### 11.2 产品能力

- 模型下载、文件校验、档位应用、取消、恢复、失败和版本不匹配均有独立可理解的状态；
- 下载完成不自动暗示已应用；应用档位有影响范围确认；
- 音色创作仍能进入描述、候选、试听和保存；
- 服务未就绪时，创作页仍解释原因并提供恢复入口，不显示伪造的生成成功状态。

### 11.3 工程与可访问性

- 所有页面样式来自 `SpeechRailDesignTokens.swift`，无新增页面级颜色/间距/圆角常量；
- App 继续以 macOS 26.0 为 deployment target，不添加 macOS 14 UI fallback；
- UI tests 覆盖导航、主要状态、确认/取消/恢复和 Inspector 显隐；
- VoiceOver 顺序为“导航 → 页面定位 → 结论 → 主要动作 → 列表/编辑器 → Inspector”；
- 完成 build、Swift 单测、UI 测试、Python gate、契约 lint、`git diff --check` 和人工视觉矩阵。

## 12. 回退与风险

- token、共享组件和页面迁移按独立逻辑 commit 交付，可回退而不影响 Python runtime、模型或
  本机服务；
- 旧服务 Agent 不支持模型控制时，仍显示能力不匹配，不执行危险重放；
- macOS 26 的系统材质和窗口行为可能随 beta/point release 微调，产品 token 只定义语义和
  层级，不复制系统玻璃实现；
- 本轮暂不改变服务契约，若模型操作能力需要新增字段，另行走 API/interface design 与契约
  评审，不把 UI 需要直接变成隐式后端变更。

## 13. 审阅问题

请审阅以下三件事后再进入实施计划：

1. 是否确认 `Signal Loom` 作为 App-wide 基线，并接受“服务冷静、创作陶土色”的双语义色策略；
2. 是否确认 `Surface.field` 取代大多数通用卡片，Inspector 只跟随选中项或用户主动打开；
3. 是否确认上述页面映射和模型下载的状态/确认语法覆盖管理控制台、运行监控、模型和音色创作。

