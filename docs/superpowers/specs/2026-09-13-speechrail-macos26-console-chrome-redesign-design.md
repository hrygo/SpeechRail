---
title: "SpeechRail macOS 26 控制台全局标题与诊断工作台重设计"
status: active
audience: "SpeechRail macOS App 产品、设计、开发与测试人员"
version: "0.1.0"
date: 2026-09-13
---

# SpeechRail macOS 26 控制台全局标题与诊断工作台重设计

## 1. 决策摘要

本次变更不是诊断页面的局部修补，而是一次控制台 Chrome 重设计，覆盖所有页面顶部中央标题、
工具栏动作、侧栏选中态和菜单 icon。页面标题的视觉结构必须属于同一套系统，同时根据“创作”
或“服务”语境表达不同的任务气质。

诊断页改为一屏可完成扫描、解释和行动的工作台：顶部只回答总体结论和主要动作，主体使用
紧凑检查清单与选中检查详情分栏，技术信息按需展开。默认视图不再依赖大面积卡片、长列表或
重复的技术字段。

SpeechRail 的产品主线“音色创作”继续保留。模型下载与校验、运行监控、服务状态和诊断仍然
是正式服务能力；本次只重构 macOS 控制面呈现，不改变 Python 服务、公共 API、模型制品位置或
XPC 控制边界。

## 2. 用户反馈转译

### 2.1 顶部中央标题

用户反馈中的“标题请完全重新设计”指所有页面顶部中央的标题区域，而不是只改“诊断”两个字。
以下页面必须统一改用新的 `WorkspaceTitleView`：

- 配音台
- 音色创作
- 音色库
- 我的作品
- 服务状态
- 运行监控
- 模型
- 诊断

窗口左上角由 macOS 管理的窗口标题“SpeechRail 管理控制台”保持不变；本规范只重设计窗口
内容区顶部中央的工作区标题。

### 2.2 右上角动作

当前全局刷新、开发者详情和服务操作并列出现，用户无法判断优先级。本次不再在右上角并列放置
三个无文字图标按钮：

- `ControlCenterView` 不再注入一个全局刷新按钮；刷新由当前页面的主要动作负责。
- 页面必须最多只有一个明确的主要动作；有多个低频动作时放入一个带文字菜单项的“操作”菜单。
- 开发者详情由 Inspector 或“显示开发者详情”菜单进入，不占据默认视觉层级。
- 服务启停只出现在“服务状态”页和菜单栏的服务命令中，并继续使用确认框。

### 2.3 诊断主体

诊断页的首屏必须让普通用户完成三件事：看懂是否正常、知道问题在哪里、知道下一步做什么。
开发者可以在同一上下文中展开脱敏技术细节，但不应迫使普通用户阅读技术字段。

### 2.4 侧栏选中态与文字对比度

选中态必须是“选中了哪一项”的明确视觉信号，而不是蓝色背景上叠加低对比黑字。实现优先
使用系统 `List(selection:)` 语义和自适应 tint；页面代码不得用固定黑色覆盖系统选中态文字。
所有状态同时提供文字和图形信号，不能只依赖颜色。

### 2.5 菜单 icon

所有侧栏 icon 重新按 SpeechRail 的“声轨、信号、控制面”语义精修。使用 macOS 26 可用的
SF Symbols，统一光学尺寸、渲染模式和状态颜色；不再混用过细、过重或语义重复的图标。

## 3. macOS 26 设计基线

本重设计沿用现有 macOS 26 基线：`NavigationSplitView` 负责顶层导航，系统 toolbar 负责窗口
级标题和动作，标准 content surface 承载正文，Inspector 承载选中对象的技术细节。Liquid Glass
只用于导航和交互层，不把每个正文区块包装成玻璃卡片。

具体规则：

1. 顶部标题说明“当前在哪个工作区”，页面正文说明“这个工作区解决什么问题”。两者不重复。
2. 每个页面只有一个任务重心；主要动作靠近它影响的状态或内容。
3. 结构化信息使用 list、grid 或 table；独立卡片只用于结论、编辑器和选中项详情。
4. 系统选中态、键盘焦点、VoiceOver label/value 和动态字号必须共同表达状态。
5. 窗口在 `1120 × 720` 最小尺寸下仍保持标题、结论、主要动作和诊断主体可用。
6. 不为 macOS 14 保留 UI 兼容分支；App 继续以 macOS 26 为唯一视觉和交互目标。

## 4. 全局顶部标题系统

### 4.1 组件结构

新增共享 `WorkspaceTitleView`，由 `ControlCenterView` 根据当前 `AppRoute` 提供上下文。标题
从左到右包含：

```text
[语义 icon]  [页面标题]  [创作/服务上下文]  [当前状态 chip（仅服务页）]
```

标题组件必须满足：

- 以页面标题为第一视觉锚点，不再只渲染一个孤立的小文本；
- icon 仅作为导航定位和品牌信号，不与状态 icon 争夺权重；
- 服务页可显示“已就绪 / 未就绪 / 需要处理”状态 chip，创作页不显示运维状态 chip；
- 状态 chip 使用文字、图形和自适应颜色；
- 标题具有稳定的 `workspace-title` accessibility identifier，label 是当前页面的完整标题；
- 页面切换时标题与 detail 同步更新，不依赖旧 toolbar 节点复用；
- 不在正文再复制一个相同的大标题。

### 4.2 页面标题语义

标题文案表达任务而不是内部实现名：

| Route | 顶部标题 | 上下文 | 首要任务 |
|---|---|---|---|
| `dubbing` | 配音台 | 创作 | 把文稿变成可试听、可交付的语音 |
| `voiceDesign` | 音色创作 | 创作 | 描述、试听并保存新的音色 |
| `voiceLibrary` | 音色库 | 创作 | 管理可复用的音色资产 |
| `works` | 我的作品 | 创作 | 回看创作历史与文稿回溯 |
| `overview` | 服务状态 | 服务 | 确认本机语音服务能否使用 |
| `monitoring` | 运行监控 | 服务 | 观察请求、延迟和资源状态 |
| `models` | 模型管理 | 服务 | 准备、校验并应用模型能力 |
| `diagnostics` | 系统诊断 | 服务 | 定位异常并执行下一步动作 |

“诊断”不再作为唯一标题方案；它在全局标题系统中以“系统诊断”参与同一套层级、间距和状态
表达。页面定位文案仍由 `AppRoute.purpose` 提供，但只在正文开头出现一次。

### 4.3 标题与动作的关系

标题居中区域只承担定位和状态确认，操作区只承担动作。标题不能变成按钮集合，也不能把
“刷新状态”“开发者详情”“服务启停”塞在标题旁边。诊断页的主动作位于结论区右侧，命名为
`重新运行诊断`；模型页的主要动作位于选中档位内容中，命名为 `下载并校验` 或 `应用此档位`。

## 5. 诊断一屏工作台

### 5.1 首屏线框

在最小窗口尺寸下，诊断页采用以下结构，不依赖外层纵向滚动才能看到主要信息：

```text
┌ 系统诊断  · 服务       10 项检查通过       [重新运行诊断] ┐
│ 定位服务阻塞，并给出下一步动作                         │
├ 检查清单（双列紧凑网格） ──────┬ 选中检查详情 ──────────┤
│ ✓ app_home                   │ ✓ 检查通过              │
│ ✓ config_file                │ app home is available   │
│ ✓ config_permissions         │ 这项检查确认什么         │
│ ✓ ffmpeg                     │ 下一步                  │
│ ✓ settings                   │ [打开模型] [服务状态]   │
│ ✓ asr_config                 │ 技术信息（折叠）         │
│ ✓ asr_snapshot               │                          │
│ ✓ asr_runtime                │                          │
│ ✓ tts_config                 │                          │
│ ✓ tts_snapshot               │                          │
└──────────────────────────────┴──────────────────────────┘
```

### 5.2 结论区

结论区高度控制在 `diagnosticsSummaryHeight` 内，包含：

- 状态 icon 与文字结论，例如“预检通过”“需要处理”“检查失败”；
- 通过数量、失败数量和最近检查时间等紧凑摘要；
- 一句用户可理解的影响说明；
- 唯一主要动作 `重新运行诊断`；
- 运行中的检查显示确定性进度或“正在检查”，不显示无意义的旋转装饰。

结论区不得放完整错误日志、绝对路径或模型 revision。

### 5.3 检查清单

检查清单使用双列紧凑列表，每行至少 `44pt` 触达高度，包含：

- 状态 SF Symbol；
- 检查项名称；
- `通过 / 失败 / 未知` 文本状态；
- 选中背景和键盘焦点环；
- 完整 accessibility label/value。

清单只做扫描和选择，不在每行塞入错误详情。默认选中第一项；当检查结果更新时保留用户当前
选择，当前选择不存在时回退到第一项。

### 5.4 选中详情

右侧详情区按“结论 → 解释 → 下一步 → 技术信息”的顺序排列：

1. 检查结果和检查名；
2. 这项检查验证的用户可理解说明；
3. 对当前状态的影响；
4. 语义化恢复动作，例如“打开模型”“查看服务状态”“重新运行”；
5. 可折叠的开发者详情，展示脱敏错误码、组件名和版本信息。

通过项不强行显示操作按钮；失败项必须提供可执行的恢复路径，不能只显示红色文本。

### 5.5 诊断信息边界

普通用户默认看不到：API key、Authorization、完整 prompt、原始音频、完整转写、embedding、
实名 speaker、绝对模型路径和可复用的内部日志。开发者详情可以显示稳定错误码和脱敏技术信息，
但仍遵守同样的隐私边界。

## 6. 侧栏选中态和 icon 语言

### 6.1 选中态

侧栏继续使用原生 `List(selection:)` 和 `NavigationLink(value:)`。侧栏行只提供 Label，不再
手工为选中项设置正文黑色或灰色。选中态规则：

- 背景使用 `Navigation.selectedFill`，在普通对比度下是深色品牌 rail signal；
- 前景使用系统自适应的高对比度选中前景；
- icon 使用同一前景色，避免选中行出现“蓝底黑字”；
- hover、focus 和 selected 是三个独立状态，不用 selected 的颜色伪装 focus；
- 选中态即使在灰度、高对比度和深色模式下也能通过形状、文字和焦点环辨认。

### 6.2 icon 规格

所有侧栏 icon 使用 `RouteIconView`：固定 `20 × 20pt` 光学 frame，SF Symbol 图形尺寸由
`Control.sidebarIconSize` 控制，使用 `.symbolRenderingMode(.hierarchical)`，行内不再出现
不同大小的图标。

| Route | SF Symbol | 语义说明 |
|---|---|---|
| `dubbing` | `waveform.and.mic` | 文稿进入语音生成 |
| `voiceDesign` | `waveform.badge.plus` | 创建新的音色形态 |
| `voiceLibrary` | `music.note.list` | 可复用的音色资产集合 |
| `works` | `square.stack.3d.up` | 已完成创作的作品集合 |
| `overview` | `server.rack` | 本机语音服务中枢 |
| `monitoring` | `chart.xyaxis.line` | 请求和资源趋势 |
| `models` | `shippingbox` | 模型制品和准备动作 |
| `diagnostics` | `stethoscope` | 检查、定位和恢复 |

icon 只承担语义，不使用装饰性渐变、阴影或自定义绘制；选中、未选中和状态色均由 token 控制。

## 7. SpeechRail Design Tokens 增量

本次实现继续以 `SpeechRailDesignTokens.swift` 为唯一 token 来源，新增或重新命名以下语义
token。现有页面仍可使用经过审查的兼容 alias，但新代码不得引入新的散落数值。

### 7.1 Typography

| Token | 角色 | 用途 |
|---|---|---|
| `Typography.workspaceTitle` | `headline/semibold` | 所有顶部中央页面标题 |
| `Typography.workspaceContext` | `caption/medium` | 创作/服务上下文 |
| `Typography.diagnosticsSummary` | `title3/semibold` + tabular figures | 诊断摘要数值 |
| `Typography.diagnosticsDetail` | `body` | 诊断解释和影响 |
| `Typography.technical` | `caption2/monospaced` | 错误码和开发者字段 |

标题组件不得在不同页面使用不同的字体大小来制造“层级”；层级来自标题、上下文和状态的关系。

### 7.2 Navigation / Control

| Token | 值 | 用途 |
|---|---:|---|
| `Control.sidebarRowHeight` | 44 | 侧栏行最小触达高度 |
| `Control.sidebarIconFrame` | 20 | icon 光学 frame |
| `Control.sidebarIconSize` | 15 | SF Symbol 图形尺寸 |
| `Control.workspaceTitleHeight` | 30 | 标题区域稳定高度 |
| `Navigation.selectedFill` | 深色 rail signal 自适应色 | 侧栏选中背景 |
| `Navigation.focusRing` | rail signal 自适应色 | 键盘焦点环 |

### 7.3 Diagnostics / Layout

| Token | 值 | 用途 |
|---|---:|---|
| `Layout.diagnosticsSummaryHeight` | 84 | 顶部结论区 |
| `Layout.diagnosticsListWidth` | 320 | 双列检查清单区 |
| `Layout.diagnosticsDetailMinimumWidth` | 460 | 详情区最低可读宽度 |
| `Layout.diagnosticsRowHeight` | 44 | 检查项行高 |
| `Layout.diagnosticsBodyMinimumHeight` | 360 | 主体一屏布局最低高度 |

### 7.4 对比度

在 Light、Dark 和 High Contrast 外观下，正文与背景的对比度目标不低于 `4.5:1`，大字号标题
不低于 `3:1`；选中态前景与选中背景同样遵守该目标。代码使用系统 adaptive foreground，
不得把 `Color.black` 或固定浅灰作为选中态文字。

## 8. 代码边界

### 8.1 共享组件

- `WorkspaceTitleView`：所有页面顶部中央标题、上下文和服务状态 chip；
- `RouteIconView`：所有侧栏 icon 的 optical size、rendering mode 和 accessibility；
- `DiagnosticsSummaryView`：诊断结论、摘要和主要动作；
- `DiagnosticsCheckList`：检查项双列列表、选择和状态语义；
- `DiagnosticsDetailView`：选中检查的解释、下一步和开发者 disclosure；
- `DeveloperInspector`：保持现有脱敏边界，只承载上下文技术信息。

### 8.2 页面职责

- `ControlCenterView.swift`：导航、标题容器、工具栏动作边界和窗口布局；
- `AppRoute.swift`：标题、上下文、用途和 icon 语义，不承载视图样式；
- `SpeechRailDesignTokens.swift`：标题、导航、诊断和对比度 token；
- `PreflightDiagnosticsView.swift`：一屏诊断工作台状态和行为；
- `WorkspaceComponents.swift`：共享标题、状态和开发者语义组件；
- `ServiceOverviewView.swift`、`RuntimeMonitoringView.swift`、`ModelManagementView.swift`、
  `CreatorSurfaceViews.swift`：接入同一标题系统，保留各页面的业务内容和音色创作框架。

## 9. 行为与测试验收

### 9.1 UI 验收

- 每个 route 都显示 `workspace-title`，标题、上下文和 detail 页面同步；
- 顶部默认不出现三个并列图标按钮；主要动作有明确文字；
- 诊断页在 `1120 × 720` 下同时看到结论区、完整检查清单和选中详情的主要动作；
- Light、Dark、High Contrast 下选中菜单文字清晰可读；
- 侧栏所有 icon frame 和视觉重量一致；
- VoiceOver 能读出 route 名称、用途、选中状态、检查结果和下一步动作；
- 模型下载仍需显式确认，运行中、失败、中断和版本不匹配状态均可解释；
- 音色创作、配音台、音色库和作品入口保持可达，不被服务重构吞掉。

### 9.2 回归测试

UI 测试应优先使用稳定 accessibility identifier 和 `label CONTAINS` 语义，不依赖 macOS 26 将
相邻 SwiftUI `Text` 拍平成单一节点的偶然结构。增加以下回归覆盖：

- 全部 route 的顶部标题和上下文；
- 诊断首屏主要区域与选中检查切换；
- 右上角动作菜单只暴露有明确文案的命令；
- 选中侧栏项的 accessibility value 与可操作性；
- 诊断失败状态的恢复动作和脱敏开发者详情。

每次 App 测试结束必须注销临时 bundle、退出测试 runner、移除临时派生数据并核验没有
`SpeechRailAppUITests-Runner`、`speechrail-macos-test.*` 或临时 `SpeechRail.app` 进程残留。

## 10. 非目标与运行发布边界

- 不修改 SpeechRail Python 服务、公共 API、模型 manifest、worker 调度或 XPC 协议；
- 不让 App 直接下载、加载或执行模型文件；模型准备仍由受管 Control Agent 完成；
- 不删除或弱化 VoiceDesign / 音色创作框架；
- 不在旧版本 App 尚未卸载前安装新版 App；
- 本设计通过 UI、代码门和 App 测试后，才恢复发布流程；服务运行时替换仍需等待现有 realtime
  session 清零，不能为发布擅自中断 Sona。

