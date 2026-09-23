---
title: "SpeechRail macOS App UI/UX 重设计规格（macOS 26 原生）"
status: accepted
audience: "SpeechRail macOS App 设计与开发人员"
version: "1.8.1"
date: 2026-09-20
---

# SpeechRail macOS App UI/UX 重设计规格

## 1. 文档定位

本文件是**已采纳的目标规范**（2026-09-15 决定：配色收敛采纳、作品删除/重命名纳入本轮）。未落地的条目仍描述目标形态，不是当前实现的说明，也不代表已获批准的公共契约变更。

判断冲突时的顺序仍然是：当前代码与实测 → `contracts/` → active 的 `docs/`。因此本文**尚未落地**的条目与 [`docs/developers/macos-app-design-system.md`](../../developers/macos-app-design-system.md) 冲突之处，仍以那份 active 文档描述当前实现；已落地的部分以代码为准，并按 §10 的阶段状态逐节修订那份文档。2026-09-18 起新增的语音助手、会议助手、实时字幕由独立的 [`会话层技术方案`](../2026-09-18-session-layer/TECHNICAL-DESIGN.md) 维护，本文件不再把它们的页面与音频生命周期当作本规格的目标清单。

本文涉及 App 的视觉、信息架构、交互与键盘路径，**不改变**服务协议、XPC 命令集、运行档位、模型生命周期或任何运行态行为。

## 2. 产品定位：App 是什么

SpeechRail 服务是单人 Apple Silicon Mac 上的本地共享语音引擎，对外提供协议兼容的 REST 与 Realtime 入口。App 是它的产品化入口，承担两件在终端里做不好的事：

**引擎时刻**——我能不能现在就用它？为什么不能？下一步做什么？

**创作时刻**——把一段文字变成声音；造一个属于我的音色；回看和导出我做过的声音。

**会话时刻**由后续会话层补充：语音助手、会议助手和实时字幕是 App 的客户端能力，
其采集、播放、记录与释放边界不由本 UI 迁移包定义。

这两件事的心智、词汇密度和技术含量完全不同。重设计的核心判断是：**不要把它们混成一种语气**。引擎时刻用状态、结论和确定性数字说话；创作时刻用文稿、试听和声音本身说话。

### 2.1 边界（明确不做）

- 不做多轨 DAW、视频时间线、背景音乐混音。
- 本规格不定义会议 / 实时字幕 / 语音助手的页面与会话生命周期；这些能力现在由 App 会话层承载，
  具体行为以会话层技术方案、`docs/developers/macos-app-development.md` 与当前代码为准。
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

### 4.2 词汇：页面上的词与内部的词（2026-09-19）

用户第一轮真机体验的反馈是「门槛极高、有看不懂的词，比如『分人』」。所以 P4 加一条硬规则：

**界面上的每一个名词都必须是用户已经会说的词；内部名只允许出现在开发者详情、`docs/design/`、
开发者文档页与诊断的可复制原文里。**

| 内部 / 制品名 | 页面上说 | 出现在 |
|---|---|---|
| `quality` / `balanced` / `light` | 精准 / 均衡 / 轻量 | 侧栏状态行、档位卡、会话右栏、设置里换档的提示 |
| `VoiceDesign` / `Base` | 语音设计 / 内置音色 | 服务状态能力行、档位卡、音色创作页 |
| 「复刻」（能力声明里的 `supports_clone`） | 音色克隆 | 服务状态能力行、音色克隆页、诊断标题（与侧栏那一项同名） |
| 分人 / 匿名分人 | 说话人区分；开关与列头叫「说话人标签」 | 服务、会议、字幕、设置 |
| VAD | 实时语音断句 | 服务状态、诊断 |
| `worker` / `常驻` | 已加载的模型；`voice_design` / `voice_clone` / `tts` → 语音设计 / 音色克隆 / 内置音色 | 服务状态「运行信息」 |
| 制品 / `asset` | 模型文件 | 模型页、诊断 |
| `bits` / `dtype`（内部字段）、「量化 / 未量化」 | 精度；取值一律读位数（`8-bit` / `16-bit`） | 列名与取值在模型页的模型文件表；开发者详情按同一维度开头，后面才补 `mlx` / `bf16` / 「未量化」这些内部说法 |
| `capability` | 服务声明「X」已经可用 | 服务状态 |
| XPC / 控制 Agent | 可以在（不能）在这里管理服务 | 服务状态控制行 |

两条配套约束：**同一件事只有一个名字**（四个页面不再各叫各的），**可见的文案里不出现
下划线英文名**（服务 `/health` 给什么，页面上就翻成中文，原文留在开发者详情）。

### 4.3 两条"不能撒谎"的规则（2026-09-19 第二轮走查补）

同一轮走查（离屏渲染真实页面 + 实测本机 `/health`）又抓到两类，都归到 P4 的**诚实**那一支：

1. **服务端的原文不直接上屏。** 服务 `/health` 的两条 `message` 实测原文是
   `Silero VAD runtime and model are ready` 与 `CoreML Sortformer FP16 is configured`——
   它们是写给调用方看的，不是给用户读的。规则：**就绪态用界面自己的话**（「运行中；说话与
   安静的边界由它在线判断」），**只有没就绪时**才把服务给的原因带出来（那一刻它是唯一线索），
   原始字符串同时留在开发者详情与诊断的可复制原文里。
2. **完成态必须是观测到的，不是推断的。** 右栏写「对话模型 已连接」读的只是"配置里填过没有"，
   从没发过一次请求——地址写错时这一屏照样说连上。规则：只读了配置就写「已配置」；
   「已连接」只能出现在真的测过或真的正在通话的那一刻（设置页的「检查连接」是那条出口）。

判据只有一条，与第 4.2 节同源：**用户读到的那句话，界面必须拿得出证据。**

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
| 可编辑表面 | 两档，都带 1pt `Color.borderStrong` 边界 + 系统焦点环：表单字段 = 稿值 `Color.inputField`（`surface/field`）；编辑卡 = 稿值 `Color.field`（`surface/content`），边界圈**整张卡**（§11.6 第五十一 / 五十三轮） | `speechRailRecessedSlot()` 的内阴影/反光双描边；`.textBackgroundColor`（本机与卡片逐位同色，等于没有边界）；页面级编辑卡曾被当成表单字段，页脚也飘在卡外 |
| 分隔 | 系统 `Divider()` 与滚动边缘效果 | `speechRailSleeperDivider()`、`milledBevel` 描边 |
| 浮起层 | 仅窗口级浮层（浮动的播放/生成结果条）使用系统材质或 `glassEffect` | 静态卡片上的 `ambientShadow` |

**判据**：如果一块表面既不承载交互、也不表达层级，它就不应该有描边和阴影。现在的实现把“容器”当成了“控件”。

### 5.3 圆角与同心几何

- 窗口圆角由系统拥有，代码不设置。
- 内容容器使用系统同心圆角（目标 API `.rect(corners: .concentric)`，落地前以 Xcode 26 SDK 实测为准）；不使用 6/8/14/18 的手挑组合。
- 列表行选中、输入框、按钮一律使用系统控件自带圆角。
- `Corner.continuousRadiusRatio` 与 `Corner.control/row/field/module` 在迁移完成后废弃。
- **2026-09-16 修订（第四十六轮）**：`.concentric` 只在祖先提供容器形状时才推得出半径，
  自绘视图默认不提供，于是「全部交给同心几何」在真实渲染里退化成方角。现在**容器声明一次
  （`Corner.container = 12`，稿 `radius/container`）、叶面同心推导**（`Corner.nested = 8` 只在
  容器给不出半径时兜底）：仍然只有两个数值、不回到「逐处手挑」，但渲染结果确定。
  量测与决策见 §11.6 第四十六轮与 §12.4 决定 5。

### 5.4 颜色

目标是**两个品牌色 + 系统语义色**，其余全部交给系统：

| 用途 | Token | 说明 |
|---|---|---|
| App 强调 / 选中 / 焦点 | `AccentColor` = 钢轨青 | 已通过 `Assets.xcassets/AccentColor` + `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` 生效，继续保持 |
| 声音语义 | `VoiceAccent` = 琥珀 | 仅用于音色类徽标、候选卡、波形 |
| 成功 / 注意 / 危险 / 信息 | 系统语义色（`.green/.orange/.red/.blue` 语义等价物） | 必须同时带图标与文字，不单靠颜色 |
| 正文 / 次要 / 三级文本 | 系统 `labelColor` / `secondaryLabelColor` / `tertiaryLabelColor` | 删除 `ink/inkSecondary/inkTertiary` 的自定义亮度 |
| 页面地板 / 面板 / 嵌套 / 输入 | `Color.canvas` / `Color.field` / `Color.recessedField` / `Color.inputField` / `separatorColor` | **2026-09-16 第五十轮改**：本机实测 `windowBackgroundColor` / `controlBackgroundColor` / `textBackgroundColor` 在两种外观下逐位相同（四级塌成一级），于是这三层改为**稿的显式取值**：`canvas` `#E8E8EA`/`#201E21`、`field` `#FFFFFF`/`#2B292C`、`recessedField` `#F5F5F7`/`#232124`；**第五十二 / 五十三轮**补上第四级 `inputField` `#FFFFFF`/`#1A191C`（表单字段），并确认编辑卡走的是 `field` 而不是这一级；分隔、文本、焦点、侧栏材质仍交系统 |

浅色模式的地板是稿的冷灰 `#E8E8EA`、卡片是纯白 `#FFFFFF`；深色是 `#201E21` / `#2B292C`。
**地板与卡片之间的那一级由应用声明**——系统语义色在本机给不出这一级（第五十轮），
其余（文本层级、分隔、焦点环、侧栏材质、状态色族）仍交系统。

**语义底色的三种来源（不要互相替代）**：

1. **状态色族**（成功 / 注意 / 危险 / 信息）用系统语义色 × `Surface.statusTintOpacity`(0.14)——
   状态胶囊、结论面板、菜单栏的「控制通道不可用」提示都属于这一族。
2. **选中与强调**用 `Color.rail` × 透明度（`Surface.selectedFill`）——强调色跟随系统设置，
   不写死数值（§5.4 上表第 1 行）。
3. **标注**类（`Voice Chip` 的琥珀：它表达“这是声音/音色”，既不是状态也不是选中）才直接用稿的
   `surface/attentionTint`（应用侧 token `Surface.attentionTint`）；这类底色与状态色族不能混用，
   否则「音色」会被读成「注意」。

稿另给了 `readyTint` / `attentionTint` / `criticalTint` / `infoTint` / `railTint` / `voiceTint`
六个手挑淡底。除第 3 类外应用**不采纳**：它们与第 1、2 类的渲染差在每通道 ≤6/255
（实测：注意 `systemOrange×0.14` = `#FFF0DB` vs 稿 `#FBEEDA`；成功 `#E2F7E7` vs `#E1F2E8`；
危险 `#FFE3E2` vs `#FBE4E4`；信息 `#DBECFF` vs `#E1EBFB`），而系统色会随外观、
Increase Contrast 与用户选择的强调色自适应。**唯一例外是配音台的生成结果条**：§5.2 点名要求
它用系统材质（见 §11.6 第三十五轮 ②），这条冲突**第五十九轮已裁决：维持规范**，见 §12.4 决定 13。

**例外最终是两处，判据是同一条：能用系统自适应的就用系统；只有当系统那一档「同时偏离稿与本 App」
时才取稿值。**

1. **配音台的生成结果条**用系统材质（§5.2 点名要求，稿的 `railTint` 与之冲突）——决定 13。
2. **音色库与我的作品的列表选中行**取稿的 `surface/railTint`（`Surface.selectionTint`）——
   决定 15。系统 `List` 的选中高亮在活跃窗口下是**系统强调色实心** `#007CE7`、
   未强调时是 `#DCDCDC`，两种状态**都不跟随稿、也不跟随本 App 的强调色**（`#23687D` / `#4FA4BA`）。

六个别的手挑淡底（`readyTint` / `attentionTint` / `criticalTint` / `infoTint` / `voiceTint` 等）
仍按本节上一段的理由**不采纳**；`attentionTint` 与 `voiceBadgeFill` 是更早几轮为标注胶囊与
来源徽标引入的既有例外，不在本轮改动范围内。

### 5.5 字体与数字

- 只用系统文本样式：`.title2`（页面主标题，仅诊断/总览使用）、`.headline`（区块标题）、`.body`（正文）、`.callout`、`.subheadline`、`.caption`、`.caption2`。
- 数字：`monospacedDigit()`，不换字体族。删除 `Typography.metricValue` 的 `.rounded` 设计（圆体数字与专业工具气质不符，且与系统层级冲突）。
- 删除所有固定 `size:` 和 `design:` 组合，除 SF Symbol 尺寸外。

### 5.6 间距与密度

保留 4pt 基准节奏（2/4/8/12/16/20/24/32/48，`20` 即 `Spacing.gutter`）。变化在于**用量**：

- 页面内容水平内边距 20pt（现为 32pt），让窗口在 1120–1280 宽度下不至于过窄。
- 区块之间 20pt（`Spacing.gutter`）。2026-09-16 按 4x 帧实测标定：八个页面上「块与块之间的
  页面底色带」都是 19–22pt，稿的生成脚本里页面栈也是 `gap: 20`；应用此前混用 `lg`(24) 与
  `sm`(12)。同一根尺子下：栏与栏 16pt（诊断页两栏实测 15pt 带）、网格项 12pt（候选 2×2 实测
  13pt 带）、页面外边距 20pt（`contentPadding`，实测左右各 20pt）。区块内元素之间 8–12pt 不变。
- 卡片内容内边距 20pt（`Layout.cardInset`）。稿实测 18pt 且六个页面一档到底（内容卡、表头、表行、
  列表行、输入卡都是 18）；4pt 网格取 20，与页面级块间距同值。例外：稿里显式写死的工具栏式卡片
  （配音台 `composer`）保持 16/12。
- 创作页给文稿区最多空间：输入卡高度**跟随正文**，区间 144–360pt（`Layout.creatorComposerMinimumHeight`
  / `creatorComposerMaximumHeight`；2026-09-16 第十七轮先把上界收到 360，第二十七轮改为跟随内容、
  下限由 280 收到 200，第三十二轮收到 160，第三十八轮收到 144——静止状态看得见 3 行写作区）。
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

保留单一 `NavigationSplitView`。当前 14 条路由以 `AppRoute.allCases` 为唯一事实源，按创作、会话、引擎分组：

| 分组 | 路由 | 侧边栏标签 | 当前快捷键 |
|---|---|---|---|
| 创作 | `dubbing` | 配音台 | `⌘1` |
| 创作 | `voiceDesign` | 音色创作 | `⌘2` |
| 创作 | `voiceClone` | 音色克隆 | `⌘3` |
| 创作 | `voiceLibrary` | 音色库 | `⌘4` |
| 创作 | `works` | 我的作品 | `⌘5` |
| 会话 | `assistant` | 语音助手 | `⌘6` |
| 会话 | `meeting` | 会议助手 | `⌘7` |
| 会话 | `captions` | 实时字幕 | `⌘8` |
| 会话 | `teleprompter` | AI 提词器 | `⌘⇧T` |
| 引擎 | `overview` | 服务状态 | `⌘9` |
| 引擎 | `monitoring` | 运行监控 | `⌘0` |
| 引擎 | `models` | 模型 | `⌘⇧M` |
| 引擎 | `diagnostics` | 诊断 | `⌘⇧D` |
| 引擎 | `developerDocs` | 开发者文档 | `⌘⇧H` |

路由和键位的持续事实源是 `AppRoute.shortcutSpec`；本表与完整证据见 `UIUX-AUDIT-MATRIX.md`。

侧边栏底部保留**唯一**的全局状态区：一行状态点 + 状态文本，点击进入「服务状态」。删除 `ControlCenterView` 中重复的入口（D9）。

侧边栏搜索**取消**（第四十九轮改判）：窗口里只保留一个搜索框，且它属于内容（音色库 / 我的作品的
工具栏搜索）。固定导航项做全文过滤的收益低于代价——它与内容搜索同屏并排、外观相近而作用域不同，
用户无法从外观判断自己在搜什么；`.searchable(placement: .sidebar)` 与空态 `ContentUnavailableView.search`
随之移除。

### 6.2 工具栏

第四十九轮重写。头部是**一个系统**：几何全部来自 `Toolbar`（`Identity` + `Action`），页面只声明
「我是谁、这一页有哪些动作」。

第五十五轮补一条**落点规则**：身份槽是**详情列的 leading 项**（SwiftUI `.navigation` 槽），
槽内左对齐；`Action` 与系统搜索框在右侧。这条不是审美选择，是「身份必须恒定」的直接推论——
`.principal` 的落点是左侧组与右侧动作之间剩余空间的中点，只要有工具栏搜索框就整体左移
135pt，详见 §11.6 第五十五轮。系统侧栏切换入口保留为原生 toolbar 控件；其位置由系统管理，
应用不在身份槽内另画一颗重复按钮。

- **身份只有一处**：`PageIdentityToolbarItem(route)` 在窗口组合根（`ControlCenterView` 的
  detail 工具栏）声明**一次**，`PageScaffold` 不再渲染页面名，正文只留一句话说明
  （`purpose`，默认 `AppRoute.pageSubtitle`）。页面名统一取 `AppRoute.title`，
  `workspaceTitle` 这套别名（模型 → 模型管理、诊断 → 系统诊断）删除。
  （本轮先试过「由每个页面声明自己的身份」——功能上与组合根声明完全等价，因为身份就是
  当前路由的纯函数，而组合根声明是装机件里已经验证过的机制，页面声明则多了一份未验证的
  工具栏组合行为，故改回组合根一次声明。）
- **动作要么具体、要么图标化**：删掉八个页面共用的「更多操作」文字标签。每页头部最多一组动作，
  具体命名的动作给文字标签（服务状态页「服务」启动/停止/重启、音色库「新建音色」），
  单件低频动作给图标 + 精确的无障碍标签（运行监控「复制监控摘要」、诊断「复制脱敏诊断报告」）。
  重复的入口按 §6.4 唯一性收敛：音色库页脚与菜单里的「新建音色」只留头部一处；
  我的作品头部不再重复只对选中行生效的导出/显示/重命名/删除（行内「⋯」、右键菜单与 ⌘E 已有）；
  运行监控每 5 秒自己采样，头部不再有「刷新」。
- **开发者详情不再是页级菜单项**：它是全 App 的一个偏好（View ▸ ⌘⌥I），页面用
  `@AppStorage("speechrail.showDeveloperDetails")` 直接绑定 inspector，不再八个页面各写一条
  「显示/隐藏开发者详情 / 详情 / 开发信息」。
- **重新读取改走 ⌘R**：由当前页面声明的 `reloadPageCommand` 提供（见 §6.3），
  头部因此没有八个含义各异的「刷新…」。
- **状态不进头部**：服务是否就绪只由侧边栏底部状态区承担（§6.4 / D9），本条不变。
- 侧边栏切换按钮**保留系统那一枚**：第四十九轮复核发现
  `.toolbar(removing: .sidebarToggle)` 在这套 `NavigationSplitView` 布局下不生效
  （09:42 装机件含该修饰符，截图里按钮仍在），而窗口最小宽 1120pt 里侧栏 240 + inspector 360
  本来就紧，收起侧栏是真实需求。窄窗口仍交给系统 overflow。
  第五十五轮用**窗口视图树**（`NSWindow.toolbar.items` 与 `ToolbarItemHostingView` 的窗口坐标）
  独立复核：带与不带该修饰符的两次渲染里，`com.apple.SwiftUI.navigationSplitView.toggleSidebar`
  与其 38.5pt 的宿主视图都在 x=201 原处，`top=11.5`，逐项相同——比截图更直接地证明了
  「不生效」，也说明这条修饰符不该再被拿来当方案。

### 6.3 菜单栏与键盘

新增 `Commands`：

| 菜单 | 命令 | 快捷键 |
|---|---|---|
| File | 新建配音文稿 | `⌘N` |
| File | 导出选中作品（选中后标题带作品名） | `⌘E` |
| View | 重新读取当前页（由页面声明的 `reloadPageCommand` 提供；没有可重读内容的页面禁用） | `⌘R` |
| View | 14 个导航路由 | `AppRoute.shortcutSpec`；完整键位表见 `UIUX-AUDIT-MATRIX.md` |
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

1. 文稿编辑器：原生 `TextEditor`，**高度跟随正文**（`SpeechRailComposerTextEditor.HeightPolicy.contentDriven`）：
   下限 144pt（`Layout.creatorComposerMinimumHeight`，静止状态看得见 3 行写作区——正文区 61pt）、
   上限 360pt（`Layout.creatorComposerMaximumHeight`），中间由正文自己的高度决定——正文每长一行卡长一行，
   到上限为止，再长由**原生滚动条**承担（滚动条可接受，不隐藏、不改滚动行为）。
   底色与边界取「编辑卡」那一档（`surface/content` + 1pt `borderStrong`，边界圈整张卡，
   见 §12.4 决定 9；本节原文的「系统文本背景」已被第五十一 / 五十三轮取代）；系统焦点环；行距 1.4；字号 `.body`。高度用原生
   `frame(minHeight:idealHeight:maxHeight:)` 给值，三个值都取自量测结果；区间口径是**整张卡**
   （正文 + 页脚字数行），`TextEditor` 在其中的份量按卡内固定开销（分隔线 + 42pt 页脚带）反推。
   量测用一个与正文同字体、同行距、同宽度的隐藏 `Text` 副本（`Text.fixedSize(vertical:)` +
   `onGeometryChange`）只取一个高度值：**不接管滚动、不隐藏滚动条、不是自造控件**。
   （2026-09-15 用户复核：原「占满剩余高度」会把三行文稿拉成一屏白板；
   2026-09-16 三度校准定「可接受滚动条、优先原生组件、只优化大小高度」；同日第四度校准要求
   「大小高度继续优化」——离屏实测固定区间下默认那行 53 字文稿只占 16pt、编辑框却有 277pt 高，
   于是改为跟随内容；同日第五度校准再收静止高度：卡里固定开销（内边距 40 + 分隔线 1 + 页脚 42 = 83pt）
   占掉下限的大半，200pt 的卡只留 117pt 正文区，一行 16pt 文稿下面空着约 100pt，
   因此下限收到 160pt；同日第六度校准（同一句「可接受滚动条、优先原生组件，但大小高度等需要优化」）
   再收到 144pt——160 本来就不是「一行文稿的高度」，而是画板上 3 行示例文稿自然长出来的高度，
   滚动条既已可接受，下限只需保证静止状态看得见 3 行写作区（3 × 20 + 83 → 4pt 网格 144），
   1–2 行文稿因此变矮、3 行及以上完全不动。见 §11.6 第五、六、十七、二十七、三十二、三十八轮。）
2. 编辑器卡片页脚：分隔线之内、卡片底部**一条固定高度的带**（`Layout.composerMetaRowHeight` = 42pt，
   稿实测 42.5pt），内容在带内竖直居中 —— 字数 `n / 上限 字`（超限时 `.red` + 图标）在左，「清空」为
   `.borderless` 次要动作（橡皮擦图标 + 文字，与稿的 `editor/meta` 一致）在右。计数属于它计数的那个
   输入框，不飘到页面底色上。带高是下限，字号放大时行仍能长高。
3. 控制条（横向，窄窗口自动换行为两行）：音色选择器、语速、主按钮。
4. 生成结果条（生成成功后出现，见下）。

**音色选择器**：默认显示为一个带波形图标的胶囊（当前音色名 + 类型徽标）。点击打开 popover：

- 每行显示音色名、一句描述、来源（系统 / 我的）、行内试听按钮。
- 试听中该行显示停止图标与进行中状态。
- 滚动列表下方固定一行「管理音色库」跳转音色库（在滚动区之外，不随列表滚走）。
  稿没有画这个 popover（瞬时浮层），所以这里以 macOS popover 的惯例为准：列表是主内容，
  导航入口放在列表下方；不要把它挪到列表之上，那会让每次选音色都得先越过一个导航行。
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

1. **描述**：原生 `TextEditor`，高度区间 130pt（`creatorVoiceInstructionMinimumHeight`）到
   200pt（`creatorVoiceInstructionMaximumHeight`），超出部分由原生滚动条承担。本页是滚动容器，
   纵向提案无界，因此由原生 `frame(idealHeight:)` 给出确定高度 160pt
   （`Layout.creatorVoiceInstructionIdealHeight` = 稿 `promptField` 130 + 框内多出的字数/门禁行），
   不依赖编辑器内部报告的理想高度。区间同样套在整张卡（正文 + 引导行 + 分割线 + 页脚）上。
   描述框下方一行 tertiary 引导（稿的 `promptField/hint`：「继续描述场景、听众或情绪，候选之间的差异会更明显。」）；
   卡片页脚左为字数（`n / 上限 字`）、右为保存门禁说明（稿的 `promptCard/meta`：「真实预览未返回前不可保存」），
   竖直方向按 `Control.compactHeight`（28pt）居中——这一档比配音台的 42pt 紧，整卡 160pt 才算得过来（§11.6 第十九轮）；
   再下方一行声学特征 chips（横向滚动，点击追加）。chips 使用系统胶囊样式 + 琥珀语义色。
2. **参考文案与保存名称**：折叠进「更多设置：参考文案与保存名称」（稿的 `promptCard/foot` 标签，把折叠区
   装了什么写在标签上），默认展开时填入合理默认值（参考文案、由描述派生的名称）。
   首屏不再显示这两项。折叠行必须是**整行命中区域**（`SpeechRailDisclosureGroupStyle`）：
   系统默认样式只有三角与文字自身可点，右侧是死区，2026-09-15 用户反馈「点击困难」。
3. **候选区**：生成后以 **2×2 网格**呈现（现为纵向分隔列表）。每张候选卡：槽位编号 + 波形 + 播放/停止 + 状态 + `保存为音色`。选中的卡片以强调色描边，未就绪的卡片明确说明原因。四张卡共用同一段结构（头部 / 波形区 / 动作行）：失败卡把波形区换成居中的原因说明（警示图标 + 一句话），动作行仍保留「重试」与时长位，网格才读起来是网格。

生成按钮措辞统一为 `生成候选音色`（`⌘⏎`）；生成中为 `停止生成`。

**能力门禁**：当需要「精准」档位时，候选区用 `ContentUnavailableView` 呈现，并带一个直接动作「去模型页切档」，而不是一行灰色文字。当语音合成未就绪时，同一位置说明原因并给「查看服务状态」。

**保存流程**：保存前展示一次性确认（名称、描述、参考文案、seed）。成功后头部状态胶囊显示「已保存」，
动作行的保存按钮换成「在音色库中查看」并跳转音色库，而不是留一个停用按钮占位。

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
2. **能力矩阵**：以 `LabeledContent` 或轻量表格呈现语音识别（含每个字的时间点）、语音合成 · 语音设计 / · 内置音色、音色克隆、实时语音断句、说话人区分（匿名标签）。每项显示“可用 / 未就绪 / 当前档位不支持”及一句原因。**页面上不出现制品名**（`VoiceDesign` / `Base`）、能力声明字段（`capability`）与 `ASR` / `VAD` 这类缩写（§4.2）。
3. **运行信息**：档位、端口、版本、已加载的模型以键值卡直接呈现（标签左、值右对齐）。这一版把原先收起的「技术细节」改为直接展示：这一页本就是为看结论与事实而打开的，把四行事实藏在一次点击之后，只会让最有用的一屏空掉三分之一窗口。「已加载的模型」的取值来自 `tts_lifecycle.warm_capabilities`，服务给的是 `voice_design` / `voice_clone` / `tts`，页面上换中文（§4.2）。

### 7.6 运行监控 (Telemetry)

**主对象**：时间序列——但**先说人话，再说口径**。

这一页的第一版把 Prometheus / Grafana 的读法直接当成界面文案（「请求速率 0.42 /s」「窗内均值」
「直方图摘要 · 累计口径」「资源脉冲」），用户的原话是「我现在都看不懂监控的啥」。
2026-09-16 用户复核后按下面重写（过程见 §11.6 第六十三轮）。

- 页首一句话说明这一页看什么：**「服务最近在做什么、快不快、占多少内存」**。
  原先的「最近 n 个样本 · 刷新间隔 5 秒」讲的是采样机制，没有一个字在说这一页看什么。
  数据点数量与「上次读取多久前」仍然保留——在结论行的新鲜度槽与运行组件卡页脚里。
- 顶部：时间窗选择。分两组，因为两类数据的粒度与存活范围不同：**本次打开 App**（1 分钟 /
  5 分钟 / 本次会话，App 自己每 5 秒采样、最多留 60 个点）与**服务落盘**（最近 1 小时 /
  24 小时 / 7 天 / 30 天，服务每 60 秒一行写进 `{app_home}/state/metrics-rollup/*.jsonl`，
  跨服务重启保留、默认 30 天）。两组合计七档，一行 segmented control 排不下也分不清，所以用
  系统 `Picker(.menu)` + `Section` 分组（2026-09-16 修订，原先要求 segmented control）。
  结论句与指标条都按当前时间窗重算，并说清当前读的是哪一类数据源。
- **历史档（1 小时及以上）**：首屏六格与实时档同构（正在处理仍取当前瞬时值），但口径是
  区间合计——次数、音频秒数、按样本量加权的平均耗时、失败数。主图同样两张：上「每个统计桶的
  语音请求次数」（实线合成 / 虚线识别），下「每个桶的加权平均耗时」。卡页脚给出这份历史的
  诚实边界：区间条数、真实覆盖时长、桶粒度、空档与重启次数、读不动的行数、内存峰值、
  自动释放模型次数、最后一条记录时间。没有历史数据时用 `ContentUnavailableView` 说明
  「这不是服务异常」，并写出目录，让用户知道数据会写到哪里。
- **首屏六个数字只答用户会问出口的问题**：正在处理（瞬时 gauge）、语音合成（次数 + 音频时长）、
  语音识别（次数 + 音频时长）、合成耗时、识别耗时、失败请求。每个数字带单位与口径；
  0 次与「读不到」用不同符号——把缺数据讲成「没有」是在编事实。
- **「请求」只数语音接口**（`/v1/audio/speech`、`/v1/audio/transcriptions`）。
  控制面轮询（`/health`、`/metrics`、`/v1/models`、`/v1/voices`）同样计入
  `speechrail_http_requests_total`：2026-09-16 本机实测 1188 次累计请求里 1159 次是它们
  （97.6%）。把它算成「请求速率」时，用户什么都没做数字也在动、真的在合成时它又几乎不动。
  这条口径针对用户界面，不许改回「全部 HTTP 请求」；要对 Grafana 就看
  `rate(speechrail_http_requests_total[...])`。音色试听（`/v1/voices/previews`）走同一条
  `record_tts`，所以它算「合成」的一次——只数 `/v1/audio/speech` 会让次数与音频秒数对不上。
- **次数与时长按窗口增量读**：`increase(counter[窗口])`，由窗内首尾两个数据点求出。
  累计值不当「当前状态」；`rate(...)`、`increase(sum) / increase(count)` 的窗口均值与
  直方图累计口径保留在开发者详情与复制摘要里，不再占首屏。
- 服务重启导致计数回退、样本不足两个、整个 metrics 读不到时一律显示「—」并说明原因：
  那是无数据，不是 0。**但单调计数器缺失的序列按 0 处理**：序列只在第一次自增时出现，
  「没有失败过、没有请求被拒绝过」的真相是序列根本不存在，此时显示「— 等待样本」
  会把「一次都没有」讲成「读不到」，恰好是这一页最该避免的读法。
- 主图**一张卡、一个坐标系、两套刻度**（2026-09-16 用户复核「为何搞俩坐标系？」「合并到一个坐标系」后改定，过程见 §11.6 第六十五轮）：
  面积读**左轴**（请求量，整数刻度），折线读**右轴**（耗时毫秒，刻度取 1 / 2 / 2.5 / 5 × 10ⁿ 整档），
  两者用一个线性比例对齐——单位不同不能共用一根刻度，但也不需要两张图。
  实时档的面积是「实时语音会话 + 单次请求」，历史档的面积是「每个统计桶的合成 / 识别次数」；
  折线一律是耗时（实时档每次、历史档每桶加权平均）。用**面积 vs 折线**区分两件事、用颜色区分
  「合成 / 识别」；图例一行写清「面积读左轴 · 折线读右轴」。
  图上的每个点是**与上一个数据点之间**的窗口值；网格线用系统中性色（只画左轴那一套），
  坐标轴标签与图例取 `Subheadline`(11pt)——稿的折线图是 SVG，标签 `font-size 11`，4x 帧实测 ink 10.5pt
  （2026-09-16 第二十四轮把本条从「标签 12pt」改正）。卡标题从「资源脉冲」改为「使用趋势」。
- **运行组件卡自己画表**（组件 / 状态两列）；说明带回答「哪些模型现在留在内存里、哪些已释放」，
  并补上用户会直接感受到的那件事——**空闲一段时间后会自动释放，下次使用再加载**。
  列头是 `Caption / Medium` 的 `inkSecondary` 行（`padY` `Spacing.xs`），行是 `Callout`，
  第一列定宽 `Layout.monitoringWorkerNameColumnWidth`(380 = 稿 `workers` 的 `COLS`)、
  第二列吸收余量，行高 `List.compactRowHeight`(42，稿的行是 `padY 11` + `Callout` 17.4 ≈ 39.4)、
  行间 1pt `Divider`，左沿与同一张卡的 `CardHead` 同为 `Spacing.md`。
  表体**不再交给系统 `Table`**：那张表自带不透明底色（深色 `#1E1E1E`）、**隔行底纹**
  （`usesAlternatingRowBackgroundColors`，第二行铺一层 5% 白）与表头列分隔线，
  三样都不在 token 里；在 `Color.field` 卡面里它读起来像「贴上来的一块别的表面」，
  隔行底纹还会被误读成选中行（§11.6 第六十八轮）。
  组件名一律用用户语言：服务的 `workers` 键里有 `streaming`，映射表缺它时表里会直接露出英文。
  **时延不按 worker 拆分**：服务端只在 `speechrail_tts_inference_duration_seconds` 上带
  `voice_class`（`system` / `custom` / `clone`）这一个维度，所以「不同音色类型的合成耗时」
  放进逐指标明细，而不是编一张按 worker 的时延表。
- **渐进式披露**：首屏只有结论句、黄金信号条、趋势图和运行组件表；内存与并行、服务能力、
  不同音色类型的耗时、累计统计收进一张默认收起的「更多细节」卡内。
  累计统计的表头必须写明「累计平均」，副行说明「当下的快慢看页面顶部的数字」，
  平均值带单位（耗时毫秒 / 倍率不带单位），指标名翻成用户语言、原文留在开发者详情里。
- **耗时一律按毫秒读**（2026-09-17 用户指令「时间单位改 ms」，过程见 §11.6 第六十九轮）：
  首屏的合成 / 识别耗时、直方图累计平均、右轴刻度、折叠详情、复制摘要、无障碍描述符
  都走同一处换算（`RuntimeLatencyPresentation`）；**音频时长**（「12.34 秒音频」）与
  **历史跨度**（「每 5 分钟」）是另一种量，仍按秒 / 分钟说人话。
- 无数据时：`ContentUnavailableView`「还没有运行数据」，并说明这不代表服务异常。
- 图表接入 Swift Charts 的可访问性描述符，序列名与图上一致（「实时语音会话」「单次请求」
  「语音识别」「语音合成」）。

#### 7.6.1 全局信息密度约束（2026-09-15 用户指令）

适用于全部八个页面，与 Figma 稿冲突时以本节为准：

1. **避免文字过于密集**：说明性文案保持一句话，长解释进 Inspector、折叠区或弹窗，不铺在首屏。
2. **杜绝大量密集信息**：首屏只留结论与主对象；明细、技术字段、累计口径一律渐进式披露
   （默认收起的折叠区或右侧 Inspector）。
3. 折叠行必须整行可点，命中区域不小于 `Interaction.minimumHitTarget`。

### 7.7 模型 (Models)

**主对象**：当前档位与它的准备状态。

1. **档位选择**：三张档位卡呈现「轻量 / 均衡 / 精准」，每档一句适用场景与三行差异（说话人区分 / 音色创作 / 识别与配音质量）。档位名与这九格取值一律中文（§4.2）；`aligner-q8`、`lane` 数这类机器名只在开发者详情里出现。
2. **两个独立动作**：`下载并校验`（primary，图标是托盘 + 下箭头，可取消，显示阶段：download / verifying / publishing + 字节进度）与 `应用此档位`（secondary，纯文字无图标，+ 确认对话框，说明会重启服务与短暂不可用）。
   动作行**排在档位卡与制品卡之间**，直接落在页面底色上，右端是磁盘事实；帧实测两张卡之间是一条
   74.25pt 的页面底色带，其中动作 34pt、上下各 20.25pt（= 页面级块间距）。长任务的进度条贴在
   动作行下方，不沉到制品卡后面（第二十六轮）。
3. **模型文件列表**：每个文件显示 key、来源（脱敏 model ID）、精度、文件数、校验状态。页面上这一节叫「模型文件」，不叫「制品」；行头的机器名（`aligner-bf16` 等）保留，因为它是与诊断输出对照的锚点。这一节列的是**这一档要用的全部文件**（含不在目录里的锁定分人资产），精度列只有一套说法：一律读位数（`8-bit` / `16-bit`），未量化的制品由权重数值格式换算，读不出来时写「未读取」（§4.2、§11.6 第七十一轮）。
4. **磁盘**：已用 / 可用，等宽数字。
5. 中断的 active operation 恢复为解释性提示 + 重试入口，不承诺续传。

### 7.8 诊断 (Diagnostics)

**主对象**：检查项清单。

- 布局：左侧 `List` 检查项（状态图标 + 名称 + 一句话），右侧详情。
- 详情：结论、用户影响、可执行修复动作（若有）、编号的「修复步骤」、`DisclosureGroup` 技术上下文（错误码、request ID、脱敏字段）。修复步骤与详情卡同高，卡片不会在错误码之后就断掉。
- 顶部：`复制诊断报告`（脱敏，符合项目隐私约束）与 `重新运行预检`。
- 全部通过时用**状态结论面板**（`StatusBanner(kind: .conclusion, tone: .healthy)`，与服务状态页同款）呈现“未发现问题”，而不是一份空列表。结论不套空态组件：`ContentUnavailableView` 默认灰字、是系统「无内容」的语义，用它承载结论会被读成「诊断没有执行」（2026-09-16 修订，原条文要求 `ContentUnavailableView`）。
- 「查看检查明细」的展开**必须可逆**：全通过时清单头保留「只看结论」回到结论面板；新一次预检（`preflightRequestID` 变化）重置展开状态，不停留在上一轮点开的明细上。结论与清单是同一件事的两种粒度，不是单向的。

### 7.9 菜单栏 (MenuBarExtra)

保持 `.menu` 风格与紧凑几何。**这一条是字面意思**：App 不设 `.menuBarExtraStyle(.window)`，
面板就是系统菜单（`MenuBarExtra` 的默认样式），行高、内边距、分隔线由系统画；UI 测试也是按
`app.menuItems["打开 SpeechRail"]` 断言的（`.window` 样式下这些行会是按钮）。因此稿里
`menuPanel` 的 288 × 面板底色 / 圆角 / 描边是**这类面板的示意图**，不是可逐像素复现的目标；
应用能控的只有行的下限高度与内容顺序：

```
SpeechRail · 服务已就绪 · 精准      (不可点状态行)
────────────────────────
打开 SpeechRail                        ⌘O
开始配音                               ⌘N
────────────────────────
运行预检
停止服务…
────────────────────────
退出 SpeechRail                        ⌘Q
```

菜单行下限 **26pt**（稿 `menuRow`；系统菜单项本身约 22pt）——`Menu.rowHeight` 不用
`Interaction.minimumHitTarget`(44)：那会让面板与每个页面的工具栏动作菜单都变成两倍高的列表行，
而菜单项的整行本来就是可点区域（REDESIGN-SPEC §11.6 第三十三轮；离屏实测行标签固有高度
288 × 44 → 288 × 26）。

### 7.10 设置 (Settings)

系统 `Settings` scene 保留。分组：通用（启动行为）、创作（默认音色、默认语速、开发者详情默认展开）、服务（端口显示、诊断报告包含项）。设置项保持最小集合，不把模型管理搬进设置。

**尺寸**：窗口 640 宽（稿 `settingsWindow`），高度按三个页签里最高的一页锁定（稿
`buildMenuAndSettings` 把三个窗口拉平，切页签不跳）。应用取值 640 × 454
（`Layout.settingsWindowMinimumWidth` / `settingsWindowMinimumHeight`，454 含系统 `TabView`
的 33pt 页签条；§11.6 第三十三轮实测）。

**行结构**：每一行是「标题 + 行内副标题」（稿 `controlRow` 的 `labels` 列，`gap: 3`），
说明文字**不另起一行**——独立成行会被 grouped `Form` 加分隔线，读起来像两个设置项。
行卡宽度 608（640 − 2×16；稿 604，残差 4）。

## 8. 状态与反馈矩阵

每页必须显式定义以下状态，禁止用“空列表 + 0 值”占位：

| 状态 | 配音台 | 音色创作 | 音色库 / 作品 | 服务四页 |
|---|---|---|---|---|
| 加载中 | 编辑器可用，音色选择器显示加载 | 描述可输入 | 列表骨架或进度 | `ProgressView` |
| 成功 | 结果条可播放 | 候选可选、可试听 | 列表可播放 | 结论面板 `.healthy`（“未发现问题”）+ 主动作 |
| 空 | — | 「还没有候选音色」+ 说明 | `ContentUnavailableView` + 引导动作 | `ContentUnavailableView`（未执行 / 无数据） |
| 能力缺失 | 选择器内说明 + 动作 | `ContentUnavailableView` + 去切档 | 行内不可用徽标 + 原因 | 结论面板 + 主动作 |
| 进行中 | 主按钮变停止 + ProgressView | 主按钮变停止 + 卡片占位 | 行内进度 | 内联进度 + 侧边栏状态 |
| 失败 | 结果条错误态 + 重试 + 诊断 | 候选卡失败态 + 重试 | 行内错误 + 重试 | 结论面板 + 诊断 |
| 部分成功 | 结果条说明已保存但未播放 | n/4 候选成功 | — | 能力矩阵逐项标注 |

成功（全通过、未发现问题）是**结论**，不复用空态组件：`ContentUnavailableView` 是系统「无内容」组件、默认灰字，用它承载结论会被读成「诊断没有执行」。结论统一走状态结论面板（`StatusBanner(kind: .conclusion)`），灰只留给「未执行 / 无数据」。

## 9. 无障碍

| 项 | 要求 |
|---|---|
| 完整辅助技术导航 | 不作为当前目标人群的验收要求；保留基本控件名称、值、提示与系统键盘语义 |
| 命名 | 所有图标按钮有 `accessibilityLabel`；列表行给出名称 + 状态 + 动作 `accessibilityHint` |
| 图表 | Swift Charts 接入 `accessibilityChartDescriptor`；折线提供摘要 |
| 状态不依赖颜色 | 状态点必须搭配文字；`Differentiate Without Color` 下仍可读 |
| 动态字体 | 固定 `height` 全部改 `minHeight`；行高随字号增长 |
| Reduce Motion | 两处自定义动效退化为即时；波形脉冲停止 |
| Increase Contrast | 不使用纯装饰描边，对比由系统语义色保证 |
| 键盘 | §6.3 全部命令可达；焦点环使用系统焦点样式 |

**「动态字体」一行的 macOS 口径**（2026-09-16 实测，见 §11.6 第三十七轮）：`.dynamicTypeSize(_:)`
对 macOS 的 SwiftUI 系统文本样式**不生效**（`body` 22px、`title` 38px、`caption` 18px 在
`large → accessibility5` 之间逐像素相同）。所以这项要求的落地方式是两条代码属性——**全部文本走系统
文本样式**、**容器用 `minHeight` 而不是 `height`**——加上一次真机走查：把系统「辅助功能 → 显示 →
文字大小」调大，确认布局不裁字、不溢出。不要用动态字号 API 当作这项的验收手段。

## 10. 迁移路径与 Swift 映射

落地状态（2026-09-15，`main`）：阶段 1–4 均已在 `macos/SpeechRailApp` 落地，
`./scripts/macos_app_build.sh --configuration Debug` 通过（`BUILD SUCCEEDED`，0 条新增 warning）。
Debug 构建已覆盖安装到 `~/Applications/SpeechRail.app`。**尚未执行**：桌面人工视觉走查、
VoiceOver 实测、UI 自动化测试（AGENTS.md 硬约束），因此本文不宣称视觉或无障碍验收通过。

> **安装态已过期（2026-09-15 23:2x 实测）**：`~/Applications/SpeechRail.app` 的可执行文件时间是
> **21:32:46**，而本会话全部 App 改动（输入区高度、运行监控口径与渐进式披露、制品表四列、
> §5/§9 修正、工具栏侧边栏按钮移除）都在这之后。`scripts/macos_app_build.sh` 只构建到临时
> derived data 目录、**不安装**，所以本会话的构建没有进到 `~/Applications`。
> 任何人现在打开那个 App 看到的都是旧版 UI；走查前必须先安装当前构建（安装会覆盖
> `~/Applications/SpeechRail.app`，属需要授权的覆盖动作，旧版本按既有惯例归档到
> `~/Library/Application Support/SpeechRail/app-archive/` 以便回退）。

审计补充（2026-09-15 20:33）：按 §5/§6/§7/§8/§9 逐条对照源码复核后，补齐 4 处偏差
（自定义行容器改 `ConcentricRectangle`、焦点环统一为系统焦点色、参考文案框改 `minHeight`、
音色徽标改用 `Color.voice`）并把 §7.2 门禁动作措辞对齐为「去模型页切档」，
同时删除零引用的 `Layout.contentMaximumWidth`、`List.selectionCornerRadius` 等 7 个 token。
再次构建、覆盖安装并重启后，`~/Applications/SpeechRail.app` 为本次构建（bundle 20:33:44），
进程稳定且无崩溃日志。**注意**：macOS 不会替换运行中 App 的代码，安装后必须退出并重开
才能看到新 UI——否则会误判为「装了没生效」。视觉与无障碍结论仍待人工走查。

第三轮（2026-09-15 20:5x）：改以 Figma 生成器 `figma-kit/main.js` 的结构定义（节点、布局、
文本样式、变量绑定）为对照基准，而不是只看导出的 PNG。据此发现候选卡头部与设计不一致：
设计稿 `Candidate Tile`（组件定义与页面实例一致）是三段头部——槽位名 `候选 1`（Body / Medium、
主文本色）→ 状态胶囊 → 右对齐 `seed 101`（Caption / tertiary），实现却多画了一个 32pt 琥珀方块、
把状态推到最右、并把 seed 藏进副标题行，槽位还用 A–D 命名（与 §8 的 `n/4` 口径不一致）。
现已按设计对齐：槽位改为 1–4、头部改为三段、删掉 `Layout.creatorSlotBadgeSize` 与
`VoiceDesignCandidateSnapshot.detail`。同时把 §5.2/§5.3/§5.4 要求"迁移完成后废弃"的整套
legacy 机架代码删除（6 个枚举 + 5 个类型 + `Corner` 枚举 + `SpeechRailSurfaceLevel.cornerRadius`），
`SpeechRailDesignTokens.swift` 从 975 行降到 465 行，`Surface` 只保留仍被引用的系统语义成员。

第四轮（2026-09-15 21:3x）：收口最后两条结构性偏差。
**D9 落地**：状态呈现的唯一性改为严格执行——`WorkspaceTitleLockup` 去掉全部状态入参，
工具栏 principal 只剩「这是哪一页」，配音台「更多操作」里的「查看服务状态」入口删除，
零引用的 `WorkspaceTitleView` 包装一并删除；全局状态常驻位置只剩侧边栏底部状态区
（服务状态页的结论面板按 §6.4 保留）。**菜单栏状态项**按 `menuBarStrip` 结构实施：
常态只渲染图标，`serviceOperation.phase.isActive` 时才追加「SpeechRail」文字与 6pt
琥珀状态点，新增 `Menu.menuBarItemSpacing` / `Menu.menuBarStatusDotSize` 两个 token。
构建 `BUILD SUCCEEDED`。**未实施且不拟实施**：设置窗口「候选数量 2/4」与「默认导出位置」——
§7.10 的创作分组本就不含这两项，且 App 目前没有对应存储或能力（候选固定 4 槽、导出走
系统面板逐次选择），摆上没有作用的控件等于假声明。

| 阶段 | 状态 | 提交 |
|---|---|---|
| 1 外壳 | 已完成 | `465f7d41` |
| 2 Token 收敛 | 已完成 | `51898504` |
| 3 命令与键盘 | 已完成 | `51898504`、`641a5517` |
| 4 逐页重构（8 页） | 已完成 | `51898504`（配音台/音色创作/音色库/我的作品）、`641a5517`（服务状态/运行监控/模型/诊断） |

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

状态：**已完成**（2026-09-15，`51898504`）。`SpeechRailDesignTokens` 的颜色/字体/圆角/表面已改为系统语义映射
（`labelColor` 层级、`controlBackgroundColor`、`textBackgroundColor`、`Color.accentColor`、`ConcentricRectangle`），
`Color.rail` 收敛为单一强调色事实来源；`Chassis`/`SteelAlloy`/`AcousticMaster`/`Surface` 仅作为兼容别名保留，
新代码不再引用。本文 §12.4 记录的 `#23687D` vs `#2A4E57` 冲突随之一并解决。

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

状态：**已完成**（2026-09-15，`641a5517`）。`App.swift` 中的 `SpeechRailCommands` 提供 File（`⌘N` 新建配音文稿、`⌘E` 导出选中作品）、View（`⌘1`–`⌘8`、`⌘⌥I`）与 Help（`⌘?` 帮助窗口）。`⌘E` 通过
`FocusedValues.selectedWorkCommand` 绑定到当前场景选中的作品，因此菜单标题会显示具体作品名，未选中时禁用。
页面内 `⌘⏎` 在配音台与音色创作分别触发生成与生成候选；列表 `空格` 试听在音色库与我的作品接入 `.onKeyPress(.space)`，
仅在列表获得焦点时生效。

> 未验证：`空格` 试听与 `.searchable` 在真实焦点/窄窗口下的行为未做 UI 验证（本机未获 UI 自动化授权）。

### 阶段 4：逐页重构

顺序：配音台 → 音色创作 → 音色库 → 我的作品 → 服务状态 → 运行监控 → 模型 → 诊断。

每页完成后应更新 [`docs/developers/macos-app-design-system.md`](../../developers/macos-app-design-system.md) 的对应章节，而不是保留两份规范。

状态：**已完成**（2026-09-15）。八页均按 §7 各自规格重建，`docs/developers/macos-app-design-system.md`
已同步到 v0.8.0（含 §3.1 token 表与 §4.2 页面规则的 v2 语义），不再与新旧两套规范并行。

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
| Screens | 8 个 1440 × 900 画板：配音台、音色创作、音色库、我的作品、服务状态、运行监控、模型、诊断；浅色一列 + 深色克隆一列（深色帧命名 `<页面> · Dark`），共 16 帧；每帧带 `exportSettings = PNG @4x`（生成器顶部 `SCREEN_EXPORT_SCALE`，Figma 上限，导出为 5760 × 3600），可直接在 Figma 里批量导出 |
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

#### 第四轮：与 App 逐页对齐（仲裁规则 + 改动）

第三轮之后稿与 App 各自演化，两边出现的是**互相矛盾**而不是缺口。这一轮先定仲裁规则，再按规则改：

| 情形 | 以谁为准 | 理由 |
|---|---|---|
| 规范条文明确要求 | 本文件（§5–§9） | 它是被批准的规范，稿和 App 都只是它的实现 |
| 稿的示例串是运行时事实（能力原因、状态、计数） | App 的实际输出串 | 稿只能示意，示例串必须能在 App 里原样出现 |
| 稿画了 App 拿不到的数据（每 worker 平均时延、音色「最近使用」） | App 能证明的事实 | 稿不承诺后端给不出的东西（同 §12.1 的判断方式） |
| 同一元素措辞不同、规范未指定 | 逐字对齐到其中一侧，并在代码里注明来源 | 两套同义文案并列才是真缺陷 |

按此规则，本轮的**稿侧**改动：

| 页面 | 改动 |
|---|---|
| 运行监控 | 页头采样状态改为实测节奏（`最近 60 个样本 · 刷新间隔 5 秒`，原为「内存样本 / 3 秒」）；图表卡标题补成应用里的「资源脉冲 + 采样范围说明」；worker 表收成「组件 / 状态」两列并把状态写成中文（`运行中 / 温待机 / 已释放`），平均时延与样本数属于直方图摘要表的字段，不并进 worker 表 |
| 音色库 | 列表行去掉「最近使用」列与省略号菜单（§4.2.3 的行内元素只有名称、来源徽标、一行描述、可用性说明与行内试听）；列表头去掉「按最近使用排序」；Inspector 的「变体与模式」拆成「变体」「模式」两行，取值行顺序与标签对齐应用（可用性 / 采样种子 / 创建时间 / 变体 / 模式 / 音频时长 / 使用次数 / 关联作品） |
| 服务状态 | 能力矩阵的原因列改成应用的原样输出（`运行中；词级时间戳由 ASR 原生提供。` 等）；运行信息取值行对齐应用（当前档位 `Quality · 创作优先`、服务端口 `127.0.0.1:8201`、运行版本 `0.4.0`） |
| 诊断 | 检查项换成应用真实存在的八项（应用目录 / 配置文件 / 音频编解码 / 运行设置 / ASR 制品 / TTS 制品 / 分人对齐制品 / 实时语音检测，副标题取自 `explanation(for:)`）；详情卡标题、影响句、修复步骤与「开发者详情」字段改成应用文案（原稿的「模型校验未完成」「artifact_key / verify_status」在应用里并不存在） |
| 菜单栏 / 设置 | 菜单项标签与快捷键改成产品实际值（`打开 SpeechRail ⌘O`，原为「打开管理控制台 ⌘⌥0」）；三个服务动作与「打开设置」补上省略号（它们都会先弹确认）；状态行改成短名写法（`服务已就绪 · Quality`），副行改成 `版本 0.7.3 · 端口 8201`；设置三个页签逐行对应应用 `SettingsView` 的 Section——删掉应用里不存在的开关（登录时启动服务 / 启动后打开管理控制台 / 菜单栏图标 / 候选数量 / 默认导出位置 / 控制范围），并补上「版本」一行 |
| 配音台 / 音色创作 | 计数行统一成 `62/5000 字` / `28/400 字`（应用写法，无空格、带单位） |
| 我的作品 | 行副行改成应用 `workListSummary` 的原样输出（系统格式时间 + 音色名），标题只留作品名；**删掉「24-bit 44.1 kHz」**——服务公开的 PCM profile 是 24 kHz / 16-bit / 单声道，应用明确不写与实测不符的格式声明 |
| 模型 | 档位卡标题改成应用的「档位 · 取向」写法（`Quality · 创作优先`），副行改成应用的 `profilePurpose` 原句；磁盘行改成 `磁盘：模型已用 … · 可用 …`（应用报的是模型占用，不是整盘占用） |
| 音色库（行内不可用态） | 不可用说明改成应用的行尾「图标 + 当前档位不可用」，可用行不再常驻一个「可用」胶囊 |

本轮的 **App 侧**改动：

| 文件 | 改动 |
|---|---|
| `ServiceOverviewView.swift` | 运行信息卡收到规范与稿的四行（当前档位 / 服务端口 / 运行版本 / 常驻 worker），配置档位、配置代次、作业队列移进开发者详情，事实不丢；结论面板就绪态改用稿的句子（`本地语音服务正在 <port> 端口运行；离线也有完整的识别与合成能力。`），不再在这句里重复档位；服务端口显示为 `host:port` |
| `ControlCenterView.swift` | 侧边栏底部状态补上运行档位（`服务已就绪 · Quality`，macOS App 设计系统 §4.1 的 `[✓ 服务已就绪 · Quality]`） |
| `WorkspaceComponents.swift` | 新增 `SpeechRailProfilePresentation.shortTitle`（状态区用短名，卡片仍用「档位 · 取向」） |
| `RuntimeMetricsSampler.swift` | `RuntimeMetricsSample` 保留实时与批处理两类活跃请求计数，不再只留合计 |
| `RuntimeMonitoringView.swift` | 并发图按稿画两条序列（实时请求实线 / 批处理请求虚线），图例写成稿的那一行；搜索占位符改为稿的措辞 |
| `RuntimeMonitoringAccessibility.swift` | 并发图的 AX 描述符同步为两条序列，摘要同时报合计与两类分解 |
| `CreatorSurfaceViews.swift` | 音色库与我的作品的搜索占位符改为稿的措辞（`按名称或描述搜索` / `按标题搜索`） |
| `SpeechRailMacControlTests/ControlKitTests.swift` | 图表描述符断言从「一条序列」改为「实时请求 + 批处理请求」两条 |
| `ControlMenuView.swift` | 菜单状态行改用档位短名（`服务已就绪 · Quality`），不再拼出两段「 · 」 |
| `CreatorSurfaceViews.swift` | 音色创作计数行补上单位，与配音台统一为 `n/上限 字` |

验证状态：`./scripts/macos_app_build.sh --configuration Debug` 与 `xcodebuild … build-for-testing` 均通过（App 与测试目标都编译），
稿侧只做了 `node --check` 与 `node build.js`；两者的**目视对照需要重跑插件并重新导出**，本轮未执行 UI 自动化，也未做人工矩阵走查。

静态画板与滚动页面的关系（对照时的判据）：8 张屏幕是 **1440 × 900 窗口的首屏**，按「页面主对象 + 主要动作」绘制。
应用页面比画板长的部分（例如模型页的「目标档位 / 当前服务 / 配置档位 / 模型运行信息」细分卡、运行监控的「直方图摘要」表）在画板上不出现，
这是画板尺寸决定的，不是缺口。配对检查以**文案、结构规则与状态呈现**为准，卡片数量与滚动长度不是判据。

#### 第五轮：用户复核后的体验修订（允许偏离 Figma）

用户在 2026-09-15 复核后提出四条指令，其中前两条是**已落地体验的缺陷**，后两条是全局设计约束。
本轮按「用户指令 > 本文件旧条文 > Figma 稿」的顺序处理，因此**这些页面不再与画板逐像素对齐**，
画板需重跑插件并按本节重新导出。

| 指令 | 判断 | 改动 |
|---|---|---|
| 配音台输入区「太高、太大、太丑，且默认不应该有滚动条」 | 高度成立：原实现 `maxHeight: .infinity` 在 1440×900 下把三行文稿拉成约 640pt 的白板。滚动条部分在第六轮改判（见下） | 新增共享组件（`WorkspaceComponents.swift`），高度改为 320–420pt 区间。§7.1 条文同步改写 |
| 音色创作「也默认不应存在滚动条」 | 同一根因：高度无上界 | 描述框改用同一组件，160–320pt |
| 音色创作「更多设置不可点击、点击困难」 | 成立。该处用的是系统默认 `DisclosureGroupStyle`，可点区域只有三角和文字本身，整行右侧是死区。项目里已有整行命中的 `SpeechRailDisclosureGroupStyle`，但没有应用到这个控件 | 三处 `DisclosureGroup`（音色创作「更多设置」、音色库 Inspector「技术上下文」、作品 Inspector「技术上下文」）统一套用共享样式；§7.2 条文补充命中区域要求 |
| 运行监控按 `/metrics` 暴露指标与 Prometheus / Grafana 的最佳展现重新设计，可不按 Figma | 成立。原实现把**服务端自进程启动以来的 lifetime 均值**当实时时延画在图上，并且把累计计数器（队列拒绝次数）当当前状态展示 | 见下 |
| 全局：任何页面避免文字密集、杜绝大量密集信息，采用渐进式披露 | 成立，运行监控最典型（首屏 7 个数字磁贴 + 能力矩阵 + worker 表 + 直方图表 + 资源表） | 运行监控首屏只留黄金信号 + 趋势 + 运行组件，其余收进默认收起的「逐指标明细」；新增 §7.6.1 全局密度约束 |

运行监控的指标口径改动（App 侧，无服务端改动）：

| 位置 | 改动 |
|---|---|
| `RuntimeMetricsSampler.swift` | 新增 `RuntimeHistogramTotals`（累计 `sum`/`count` + 增量）；采样点保留 5 个直方图的累计量，并把 `asrLatencySeconds`/`ttsLatencySeconds`/`asrRTF`/`ttsRTF`/`ttsTTFASeconds` 从 lifetime 均值改成**相邻采样点增量均值**；新增 5xx 计数 `requestErrors`、`workerEvictions` 与 `errorRatePerSecond` |
| `RuntimeMetricsSampler.swift` | 新增 `RuntimeMonitoringWindow`：按当前时间窗用 `rate(counter)` / `increase(sum)/increase(count)` 得出窗口值；样本不足、计数器缺失或服务重启回退时返回 `nil`（无数据，不是 0） |
| `RuntimeMonitoringView.swift` | 指标条从 7 个（活跃/排队/速率/ASR RTF/TTS RTF/累计拒绝）改为 6 个黄金信号：请求速率、**错误率**、并发（含实时/批处理分解）、排队（含窗内拒绝速率）、ASR 时延、TTS 时延；每个数字带单位与窗口口径 |
| `RuntimeMonitoringView.swift` | 新增默认收起的「逐指标明细」卡，收纳能力状态、资源与准入、直方图累计摘要；直方图摘要改标「累计口径」；卡片内不再套卡片 |
| `RuntimeMonitoringView.swift` | 图表说明改成「每个点是与上一个采样点之间的窗口值」；摘要右列去掉与页头重复的样本数 |

本轮验证：`./scripts/macos_app_build.sh --configuration Debug` 与
`xcodebuild … build-for-testing` 均通过（App 与测试目标）。单元测试断言随口径变更同步更新
（`RuntimeMetricsSampler` 的 lifetime 均值断言改为增量断言，新增窗口聚合与「无数据不是 0」两条），
但**本轮未运行测试**（AGENTS.md：自动化验收需当次明确授权）。视觉与滚动条行为需要人工走查确认——
滚动条策略依赖 `TextEditor` 底层 `NSScrollView` 对 `scrollIndicators` 的响应，本机未做 UI 验证。

**本轮未生成新的 Figma 产物**：`figma-kit` 仍停在第四轮，画板与本文件的 §7.1 / §7.2 / §7.6
已不一致。要恢复稿与 App 的一致，需要按本节更新 `main.js` 后重跑插件并重新导出。

#### 第六轮：输入区改判（滚动条回归原生）

用户在同日复核后修正了第五轮的第一条实现方向：**滚动条可以接受，优先使用原生组件，只优化大小高度**。

第五轮那版为了让「没有内容可滚时不显示滚动条」，在 App 侧加了一份隐藏 `Text` 量高副本 +
`onGeometryChange` 反馈 + 动态切换 `.scrollIndicators`。它换来的收益只是让一个空编辑区不画滚动条，
代价是自造了一套测量与状态回传：这是典型的「为了让原生控件看起来不一样而重造机制」。
第六轮按用户口径去掉这层机制：

| 位置 | 改动 |
|---|---|
| `WorkspaceComponents.swift` | `SpeechRailGrowingTextEditor` → `SpeechRailComposerTextEditor`：删掉量高副本、三处 `onGeometryChange` 与 `scrollIndicators` 分支；组件只剩「原生 `TextEditor` + `minHeight/maxHeight` 区间 + 分隔线内页脚 + 系统焦点环」 |
| 配音台 / 音色创作 | 调用点改名，区间不变（320–420pt / 160–320pt）；滚动、滚动条、键盘滚动全部交回 `TextEditor` 原生行为 |

保留的判断：**高度必须封顶**。原生控件的默认「贪婪」行为在 1440×900 下会把三行文稿拉成一屏白板，
所以区间上下限仍然是我们的产品决定，而不是绕过原生能力。

验证：`./scripts/macos_app_build.sh --configuration Debug` 通过。视觉仍需人工走查（本机未获 UI 自动化授权）。

#### 第七轮：§5 视觉语言与 §8 / §9 逐项核对

按「每一条规范都要有当前源码证据」的方式复核 §5 / §8 / §9。结论分三类：符合（无需改动）、
不合（已修）、无法用源码证明（标记为未验证）。

| 条文 | 判据 | 当前证据 | 结论 |
|---|---|---|---|
| §5.2 材质 | 面板/输入/浮层只用系统填充，不再自绘渐变与描边 | `SpeechRailSystemSurfaceModifier`：control/panel/inspector = `Color.field` + `containerShape`；elevated = `.regularMaterial` + shadow；`SpeechRailSlotModifier` 三个 case 各取一级稿值（`inputField` / `field` / `recessedField`）。旧的渐变+0.5pt 描边实现已不存在。（第五十 / 五十一 / 五十二 / 五十三轮更新了这条证据：四个中性面改为稿的显式取值，可编辑表面另加 1pt `borderStrong` 边界并分「表单字段 / 编辑卡」两档——见 §11.6 那四轮） | 符合 |
| §5.3 圆角 | 不用手挑的 6/8/14/18 | 全仓无 `.cornerRadius(`；`RoundedRectangle` 只出现在 token 侧（`Waveform.barRadius`，第四十二轮由 `Control.waveformBarRadius` 更名、值 2 → 1 按稿；`Corner.containerShape` 的 12；第四十八轮的 `Corner.controlShape` 的 8）。第四十六轮起改为「容器声明一次 + 叶面同心推导」，并**有意偏离**「不使用手挑半径」：显式声明 `Corner.container = 12` / `Corner.nested = 8`，离屏实测容器就是 12pt `.continuous`、叶面 = 容器半径 − 内缩。第四十八轮把**控件**从推导里摘出来（内缩 ≥ 12 时推导值 ≤ 0，会退化成方角），固定取 `nested`。偏离已记为决策，见 §12.4 决定 5 / 决定 6 | 符合（有记录的有意偏离） |
| §5.4 颜色 | 双品牌色 + 系统语义色；琥珀只标记声音对象 | `ink*` 已映射 `labelColor/secondaryLabelColor/tertiaryLabelColor`；`rail = Color.accentColor`；`voice` 为琥珀动态色且仅出现在音色徽标、波形、候选卡、音色行与 TTS 序列。**发现 1 处不合**：菜单栏「服务操作进行中」状态点用了琥珀（声音语义），改为 `Color.attention` | 已修 |
| §5.5 字体 | 只用系统文本样式；除 SF Symbol 尺寸外不出现固定 `size:` | 全仓仅 2 处 `.font(.system(size:`：`SurfaceHeaderView` 的 SF Symbol 尺寸、运行监控图表 12pt 轴标签（§7.6 明确要求）。`.rounded` 设计已删除 | 符合 |
| §5.6 间距 | 4pt 节奏，无游离数值 | `spacing:` 与 `padding(.x,` 中不含非节奏常量；`Layout.contentPadding = 20`、区块间距 `Spacing.lg = 24` | 符合 |
| §5.7 图标 | SF Symbols + monochrome，导航/工具栏 16pt | `symbolRenderingMode(.monochrome)` 已用于页头与侧边栏；无 multicolor/hierarchical。**发现死 token 与规范冲突**：`Control.iconSize`(16)、`Control.toolbarIconSize`(18)、`Control.sidebarIconSize`(15) 均无引用，后两者还写出与 §5.7 不一致的尺寸；`Typography.emptyStateGlyph` 亦无引用 | 已修（删除 4 个死 token） |
| §5.8 动效 | 只保留两处自定义动效，且全部在 Reduce Motion 下退化为即时 | 自定义动效仍只有结果条进入与波形脉冲。**发现 3 处未受保护的 `withAnimation`**：运行监控「已复制监控摘要」回执、诊断页复制回执及回执自动消失；波形脉冲原先依赖系统对 symbol effect 的隐式处理 | 已修（显式 `reduceMotion ? nil : …`，脉冲改为 `isActive: isPlaying && !reduceMotion`） |
| §8 状态矩阵 | 每格都有实现 | 加载/空/能力缺失/进行中/失败/部分成功逐格核过；服务状态与运行监控两处加载态缺口已修（第五轮）。作品页无加载态是因为 `AppModel.init` 与 `refreshWorks()` 都是本机同步读取，不存在可观察的加载期 | 符合 |
| §9 图表 | 接入 `accessibilityChartDescriptor` | `RuntimeMonitoringView` 两张图各一处 descriptor，摘要报窗口口径 | 符合 |
| §9 状态不依赖颜色 | 状态点必须配文字 | 侧边栏状态点、菜单栏状态点均为 `accessibilityHidden(true)` 且相邻有文字或 `accessibilityLabel`；能力行与 worker 表都是图标 + 文字 | 符合 |
| §9 动态字体 | 固定 `height` 改 `minHeight` | 剩余固定高度只有结构性容器：页头标题槽（带 `minimumScaleFactor` + 截断）、图表画布、`Table` 的边框高度（行高随系统增长，容器可滚动，不截断文字）、分隔线与调试哨兵 | 符合（保留结构性高度） |
| §9 完整 VoiceOver 导航 | — | 用户明确当前产品不面向辅助技术用户；完整遍历不属于验收范围。控件基础 label/value/hint 由代码与代表性 UI 自动化核对 | 目标范围外；不作为阻塞项 |

本轮验证：`./scripts/macos_app_build.sh --configuration Debug`、`swift test --package-path macos/SpeechRailApp` 和完整 `SpeechRailApp` test plan 均通过；test plan 255/255。四档窗口与代表页面主动作边界见 `UIUX-AUDIT-MATRIX.md`。较大系统文字联动及未覆盖的 searchable/List 全路由组合仍为非阻塞未验证项。

#### 第八轮：§7 逐页复核（7.5 / 7.7 / 7.8）

本会话改动过 §7.1 / §7.2 / §7.6 之后，把其余带编号要求的页面重新取了一次证。

| 页面 | 要求 | 当前证据 | 结论 |
|---|---|---|---|
| §7.5 服务状态 | 六项能力（ASR 含词级时间戳 / VoiceDesign / Base / 音色复刻 / 实时 VAD / 分人），每项「可用 / 未就绪 / 当前档位不支持」+ 一句原因 | `ServiceOverviewView.capabilities` 的六项顺序与状态词表逐字一致（`CapabilityStatus.label`：可用 / 未就绪 / 当前档位不支持）；每行 `StatusPill`（图标 + 文字）与一句原因 | 符合 |
| §7.7 模型 | 三档差异、两个独立动作 + 确认、制品列表字段、磁盘等宽、中断恢复 | 档位卡含「档位名 + 当前使用胶囊 + 一句适用场景 + 三行规格」，动作是「下载并校验」/「应用此档位」且各自带确认文案；`ProfileChoiceCard` 用按钮卡而不是系统 `Picker`（稿同为卡片形态，第四轮已定）；磁盘行 `monospacedDigit()`；中断恢复为解释性提示 + 重试 | 措辞与形态符合（形态偏离已在第四轮记录）；**动作行的位置与两个按钮的图标当轮没有对**，第二十六轮按帧改正 |
| §7.7 制品列表 | 每个制品显示 key、来源、量化、文件数、校验状态 | **发现与稿和密度约束都不符**：应用的行是五行堆叠（key / 来源 / 目标 / 存在 / 使用），稿画的是四列表格（制品 / 量化 / 文件 / 校验） | 已修 |
| §7.8 诊断 | 左列表 + 右详情；详情含结论、用户影响、修复动作、编号修复步骤、`DisclosureGroup` 技术上下文；顶部两个动作；全通过时状态结论面板（`StatusBanner(kind: .conclusion, tone: .healthy)`），且「查看检查明细」的展开可逆 | 结论胶囊、`detailFact("对当前服务的影响")`、`recoveryAction(for:)`、`recoverySteps`（带序号且顺序有意义）、`DisclosureGroup` 已套共享整行样式、「复制脱敏诊断报告」「重新运行预检」、全通过 `StatusBanner(kind: .conclusion, tone: .healthy)` + 主动作「查看检查明细」；`checkListHeadTrailing` 在全通过时给「只看结论」，`.onChange(of: model.preflightRequestID)` 重置展开 | 符合（2026-09-16 修订：全通过原为 `ContentUnavailableView`，其灰字与「还没有检查项」无法区分，被读成「未执行」；展开原为单向，已补回程） |

制品行的修法：`ArtifactChoiceRow` 改成四列（`制品` 吸收余量，`量化` 84pt、`文件` 64pt、`校验` 120pt 三个定宽列），
并补上列头；被移出行的「来源」「目标档位」「使用状态」仍完整保留在右侧 Inspector（`来源` / `适用档位` / `使用状态`），
信息没有丢，只是从首屏挪到了按需展开的位置。同一轮里 `ModelArtifactUsagePresentation` 不再被行引用（Inspector 仍用），
顺带删除了随之失去引用的 `sizeText`。

稿侧同步一处运行时事实：制品表的「校验」列取值改成应用 `statusPresentation.title` 的原样输出（`已验证` / `未下载`），
原先的 `已校验` / `待校验` 在应用里并不存在。`code.js` 已重新构建（23:07，SHA-256 `bc776507…`）。

#### 第九轮：§6 信息架构与 §7.3 / §7.4 / §7.9 / §7.10

| 条文 | 要求 | 当前证据 | 结论 |
|---|---|---|---|
| §6.1 侧边栏 | 14 条路由、创作 / 会话 / 引擎三组、底部唯一状态区、页面说明只在内容层 | `AppRoute` 14 个 case；`AppRouteGroup` 三组名为「创作」「会话」「引擎」；状态区一行状态点 + 文本，点击进入服务状态；固定导航不再承担内容全文搜索 | 路由结构以当前源码和 UIUX-AUDIT-MATRIX.md 为准 |
| §6.2 工具栏 | `WorkspaceTitleLockup` 单行固定槽位尾截断；保留系统侧栏切换入口；开发者详情只在该页真有技术摘要时出现 | `WorkspaceTitleLockup` 用 `lineLimit(1)` + `truncationMode(.tail)` + 固定槽位 + `minimumScaleFactor`；14 个路由共用同一身份槽；AX 树可见原生 Hide/Show Sidebar 控件 | 符合；侧栏/Inspector toggle 已由四档 UI 矩阵验证 |
| §6.3 键盘 | ⌘N / ⌘E / 14 项 `AppRoute.shortcutSpec` / ⌘R / ⌘⌥I / 页面 ⌘⏎ 与空格试听 | `App.swift` 的 `SpeechRailCommands` 消费 `AppRoute.shortcutSpec`；route contract 脚本核对 14 项，UIUX-AUDIT-MATRIX.md 维护完整键位表 | 当前契约由 AppRoute.swift 和 UIUX-AUDIT-MATRIX.md 维护 |
| §6.4 状态唯一性 | 服务就绪只在侧边栏；长任务进度在触发页内联、侧边栏显示「服务操作进行中」；错误在触发页、诊断页汇总 | `sidebarStatusText` 在 `serviceOperation.phase.isActive` 时返回「服务操作进行中」，就绪时是唯一常驻指示器；各页结论面板只在自身页面出现 | 符合 |
| §7.3 音色库 | List + Inspector；行内五项；`.searchable` + 来源分段；Inspector 字段顺序；破坏性删除；空状态 | 行内为名称 + 来源徽标 + 一句描述 + 可用性说明 + 行内试听；`VoiceSourceFilter` 三档为「全部 / 系统 / 我的」；Inspector 首项即试听，随后可用性 / seed / 创建时间 / 变体 / 模式 / 时长 / 使用次数 / 关联作品 / 描述全文 / 三个动作；删除走 `confirmationDialog` | 符合 |
| §7.4 我的作品 | 行内五项；`.searchable` + 时间排序；行内播放、次动作走菜单与 ⌘E；破坏性删除说明音频一并移除；空状态 | `workListSummary` = 时间 + 音色名，时长 `monospacedDigit()`；`sortOrder` 控制时间正/倒序；确认对话框文案「作品条目和它的音频文件会一起从本机移除，且不可恢复。」 | 符合 |
| §7.9 菜单栏 | 不可点状态行 + 打开 / 开始配音 / 运行预检 / 服务动作 / 设置 / 退出 | 状态行是合并后的文本元素（不是按钮），状态为「服务已就绪 · Quality」+ 副行版本与端口；菜单项与快捷键 ⌘O / ⌘N / ⌘, / ⌘Q 齐备 | 符合 |
| §7.10 设置 | 三个页签，最小集合 | `Tab` 通用 / 创作 / 服务；通用含启动行为与「默认展开技术详情」，创作含默认音色与默认语速，服务含端口显示与「诊断报告包含运行档位与版本」；无模型管理入口 | 符合 |

本轮自动化验收：Debug build 通过；完整 App test plan 255/255 通过。四档窗口矩阵确认原生侧栏和 Inspector 可收起/恢复，六个代表页面的主动作 frame 均在窗口内。searchable/List 全路由全尺寸组合仍由 `UIUX-AUDIT-MATRIX.md` 标为未覆盖；完整 VoiceOver 导航不属于当前目标人群验收。

#### 第十轮：§11 稿侧规格静态核对

§11.1–§11.5 是**目标**规格，§11.6 记录**实际交付**。两者差额此前只在 §11.6 里零散出现，
这一轮按条目对完并把差额写明，避免再出现「规范说 A、产物是 B、没人说清」的情况。

| 条文 | 目标 | 生成器里的实际实现 | 差额 |
|---|---|---|---|
| §11.1 页面结构 | 7 页 | `PAGE_NAMES` 七项齐全，`03 Screens` → `04 Screens` 重命名在清空前执行 | 无 |
| §11.2 Frames | 主窗口 1440×900、最小 1120×720、宽 1920×1080、设置 640 宽撑高、菜单面板 288 宽 | `buildShell` 固定 1440×900；菜单面板 `size(panel, 288, …)`；设置窗口 `size(win, 640, …)` | **最小与宽屏回归画板未绘制**：只留下 `size/windowMinW=1120` / `size/windowMinH=720` 两个数值变量。8 张画板都是 1440×900 首屏（第四轮已定判据） |
| §11.3 Variables | 颜色 + 数值 + 文本样式三组 | 颜色 23、数值 20（含窗口最小尺寸）、文本样式 9 个 | 文本样式用的是应用实际在用的 9 级（`Title / Large`…`Caption / Medium`），不是 §11.3 列的 `LargeTitle/Title2/Headline/…+Mono/Numeric` 命名；两套是命名差异，不是层级差异 |
| §11.4 组件清单 | 20 个组件，含 hover/focused/disabled 变体 | 11 个 component set（Status Pill、Nav Item、Button/Primary、Button/Secondary、Card、List Row、Candidate Tile、Empty State、TextField、VoiceBadge、Icon Button） | 差额是「页面级结构」与「组件」的分界：§11.4 里像 `ResultBar` / `ChartPanel` / `ProfileCard` / `DiagnosticRow` 这些在稿上是画板内的结构块，没有做成 component set |
| §11.5 原型连线 | 三条主流程；同页顶层帧之间的导航自动连 | `wirePrototype` 对浅色与深色两组各写 8 帧 × 7 条同页导航 + 7 条状态行 → 服务状态 = 每组 63 条，**合计 126 条**，与 §11.6 的「126/126」在算术上一致；跨页与画板内部连线按插件 API 限制保持手动 | 无（条数可核对；生效与否要重跑插件才能确认） |

**最小 / 宽屏画板为什么没画**：`buildShell` 的整套外壳（标题栏、侧边栏 240、内容区）按 1440×900 排版，
要再出 1120×720 与 1920×1080 两版就得为八个页面各排一次，而 1120×720 下的内容必然需要重排
（不是等比缩放）。应用侧的窄窗口行为由 `ViewThatFits` 承担并在代码层核过（§5.6 / §7.1），
所以在没有真实 Figma 运行环境、无法复核越界审计的前提下，我**不擅自增加这两张画板**：
生成器改坏会让下一次插件运行失败，代价高于收益。需要回归画板的话，这是一次独立的、要单独验收的改动。

同时核了 `macos-app-design-system.md` §5 验收清单里每条打勾的声明（这轮的第三类问题：过期结论）：
最低系统版本 `MACOSX_DEPLOYMENT_TARGET = 26.0`（App 与 UI 测试目标都是）✓；主要间距/颜色/字体走 token ✓；
页头单行 `WorkspaceTitleLockup`、动作菜单统一「更多操作」、导航图标走 `RouteIconView` ✓；
破坏性边界都有确认文案 ✓。**改掉一条过期声明**：清单里「Logo 设计基因已完整落盘至规范文档与 Swift Token 映射」
在 v2 收敛之后只剩色彩基因成立，已改成如实描述（形与质按 §5.1 不再映射为 token）。

#### 第十一轮：高度取值改为原生 ideal + §7.2 保存后入口

第六轮把滚动交回原生之后，输入区高度还剩一处不落定：`frame(minHeight:maximumHeight:)`
在**无界提案**下（音色创作在 `ScrollView` 里）取的是原生编辑器内部报告的理想高度，
当前只是恰好被下限 160pt 兜住。这一轮把高度改成原生
`frame(minHeight:idealHeight:maxHeight:)`，让两种容器都取到确定值：

| 位置 | 改动 |
|---|---|
| `SpeechRailComposerTextEditor` | 增加 `idealHeight` 参数并传给原生 `frame`，不做任何自量高 |
| `SpeechRailDesignTokens.Layout` | 新增 `creatorComposerIdealHeight = 420`（弹性容器停在舒适上限）、`creatorVoiceInstructionIdealHeight = 200`（滚动容器里的确定高度，比下限宽裕又不把候选区挤出首屏） |
| `CreatorSurfaceViews.swift` | 两个调用点补 `idealHeight`；候选卡保存成功后动作行由停用的「已保存」改为「在音色库中查看」并跳转音色库（§7.2 保存流程，「已保存」仍由头部状态胶囊承担） |
| `AppModel.playWork` | 开始播放作品时清掉 `playingVoiceID`：播放器只有一个，留下旧 ID 会让音色库显示一个并不在响的「停止试听」状态（§7.1 全 App 同一时刻只有一个声音） |

本轮验证：`./scripts/macos_app_build.sh --configuration Debug` 与
`xcodebuild … build-for-testing` 均通过。仍**未运行单元测试与 UI 自动化**，
所以「滚动条位置、宽窗口下 420pt 的观感、保存后入口的手感」仍属于桌面走查项。

#### 第十二轮：逐屏文案与真稿对齐（帧 ↔ 应用互查）

这一轮换了方向取证：不再只从规范条文查应用，而是**把稿的界面文案抽出来，逐条在应用源码里找**。
做法是抽出八个屏幕的界面文案，在 `macos/SpeechRailApp/SpeechRailApp` 的全部 Swift 源码里查找，
再把「样本数据」与「界面文案」分开判断——样本（音色名、作品标题、时间、计数）本来就该不同，
界面文案必须对得上。

**证据来源更正（用户 2026-09-16 指出）**：`figma-kit/main.js` 不是设计来源，它只是喂给 Figma
生成稿的脚本；稿的权威证据是用户导出的帧图（`~/Downloads/speechrail-screens-4x/`，16 帧，4x）。
本轮的逐字比对因此以帧图为准，脚本只作为「下一次生成的输入」。上一批基于脚本做的两处改动
（能力卡说明、候选 3 保存态）只影响下一次生成，已生成的稿不会自动变。

按帧图修掉的差异：

| 位置 | 稿（帧图） | 应用（修前） | 处理 |
|---|---|---|---|
| 配音台页脚 | 橡皮擦图标 + `清空` | 纯文字 `清空` | 应用补 `Label("清空", systemImage: "eraser")` |
| 音色创作 · 描述框内 | tertiary 引导「继续描述场景、听众或情绪，候选之间的差异会更明显。」 | 无 | 共享组件新增可选 `hint` 行，原生 `TextEditor` 不支持 placeholder，所以是固定提示行而不是覆盖层 |
| 音色创作 · 卡片页脚右 | 「真实预览未返回前不可保存」 | 「描述决定音色，参考文案只用于试听与保存。」 | 应用改成稿的措辞 |
| 音色创作 · 折叠行标签 | 「更多设置：参考文案与保存名称」 | 「更多设置」 | 应用改成稿的措辞（折叠区装了什么写在标签上） |

**这批帧图比当前脚本旧一代**（第十五轮给出代次判定），所以「帧里有、应用里没有」的多数条目
不是应用落后，而是帧过期。按性质分三张表。

① 帧过期，当前脚本已与应用一致（下一次生成即消失）：

| 位置 | 帧（旧一代） | 当前脚本 + 应用 |
|---|---|---|
| 模型 · 制品表校验列 | `已校验` / `待校验` | `已验证` / `未下载`（`statusPresentation`） |
| 模型 · 磁盘行 | 「磁盘：已用 6.4 GB · 可用 182 GB」 | 「磁盘：模型已用 … · 可用 …」 |
| 模型 · 档位卡标题 | 档位名 + 短副行 | 「档位名 · 取向」+ `profilePurpose` 一句 |
| 运行监控 · 页头副行 | 「刷新间隔 3 秒」 | 「刷新间隔 5 秒」（应用确实每 5 秒轮询） |
| 运行监控 · worker 表 | 4 列（含平均时延 / 样本） | 2 列 lifecycle（时延见第十四轮的 `voice_class` 面板） |
| 音色库 · 列表头 / 行尾 | 「按最近使用排序」+ 行尾时间 | 无排序标签、行尾是可试听按钮（服务没有 `last_used`，见第十五轮） |
| 诊断 · 检查项 | 「模型校验未完成 / 受管 runtime 完整 / …」 | 应用的真实预检目录（应用目录 / 配置文件 / … / 实时语音检测），当前脚本已按应用重写 |
| 菜单面板 · 首项 | 「打开管理控制台」 | 「打开 SpeechRail」（脚本与应用一致） |
| 设置 · 三个页签 | 登录时启动服务 / 菜单栏图标 / 候选数量 / 默认导出位置 / 服务地址 / 控制范围 | 当前脚本已按 §7.10 收成最小集，与应用逐行一致 |
| 配音台 · 编辑器高度 | 帧约 567pt（占满剩余高度） | 应用**跟随正文**，200–360pt（第二十七轮；帧高按第十五轮实测改正，原记「287pt」不可复现） |
| 音色创作 · 描述框高度 | 帧字段 130pt | 应用 130–200pt（ideal 160，含框内字数/门禁行；第十七轮） |

② 真实差额（帧与当前脚本相同，但应用不该照做）：

| 位置 | 帧 + 脚本 | 应用 | 为什么以应用为准 |
|---|---|---|---|
| 服务状态 · 能力卡说明 | 「按当前 Quality 档位如实发布…」 | 「按当前运行档位如实发布…」 | 档位是运行时值，卡片在 Light / Balanced 下也要成立（脚本本轮已改） |
| 音色创作 · 候选 3 保存态 | 绿色「已保存」徽标 | 「在音色库中查看」按钮 | §7.2 要求保存后给出下一步（脚本本轮已改） |
| 音色库 / 我的作品 · 搜索框 | 页内搜索框 | `.searchable(placement: .toolbar)` | §7.3 / §7.4 写 `.searchable`；工具栏搜索是原生行为（用户全局指令要求优先原生） |

③ 用户指令允许的偏离（帧与脚本都没有，应用有）：

| 位置 | 应用 |
|---|---|
| 运行监控 · 首屏 | 多一条结论/新鲜度条 + 6 个黄金信号条（2026-09-15 用户指令：按 Prometheus/Grafana 重做，可不按稿） |
| 运行监控 · 明细区 | 「按音色类别」TTS 时延面板（第十四轮） |
| 各页 · 渐进式披露 | §7.6.1 全局密度约束（第十三轮的逐页取证） |
| 配音台 · 输入卡高度 | 帧是「占满剩余高度」（实测约 567pt），应用改成**跟随正文**的 200–360pt（2026-09-16 用户指令：滚动条可接受、优先原生组件、只优化大小高度；第四度校准「大小高度等需要优化」后由固定区间改为跟随内容，脚本同步画 200） |
| 音色创作 · 描述框 | 字数与保存门禁行收进框内（帧里那一行在字段之外），所以整卡 160pt 而不是 130pt；脚本字段同步画成 160（第十七轮） |

核对后确认**一致**的（抽样列）：`运行中；词级时间戳由 ASR 原生提供。`（应用拼 `\(state)；…`）、
`\(n) 项需要处理`、`上次预检 … · 共 n 项`、`采样窗口 n · 上次刷新 …`、`n 个制品 · n 个待校验，分人能力在补齐前不可用`、
八个诊断检查项名称与说明——都是应用按运行时数据拼出来的，稿上的静态值落在同一模板里。

本轮验证：`./scripts/macos_app_build.sh --configuration Debug` 与
`xcodebuild … build-for-testing` 通过；`node --check main.js && node build.js` 通过，
`code.js` 重新生成（142460 bytes，SHA-256 `6e3eacb4cbf2c7cbc4bf01725f61b4b0d31260294c944f41632b0c33623a5fbb`）。
仍未运行单元测试与 UI 自动化；生成脚本侧的改动要等下一次生成才会体现在稿上。

#### 第十三轮：§7.6.1 逐页密度取证

§7.6.1 的全局密度约束此前只在运行监控上验证过（第五轮），这一轮把八个页面各自的**默认可见内容**
与**渐进式披露去路**逐页对了一次，方法是从各页 `body` 往下读首屏结构，而不是看规范怎么写：

| 页面 | 首屏默认可见 | 收起来的部分 | 结论 |
|---|---|---|---|
| 配音台 | 文稿编辑器 + 一条控制条 + 结果条（生成后出现） | 输出格式/采样率等进 Inspector | 符合 |
| 音色创作 | 描述框（含一行引导）+ chips 行 + 一行可用性 + 折叠行 + 候选网格 | 参考文案与保存名称在「更多设置」；seed/时长/模式在 Inspector | 符合（本轮把页脚解释句换成更短的「真实预览未返回前不可保存」） |
| 音色库 | `List`（行内：名称、来源徽标、一句描述、可用性、试听） | 试听文案、seed、变体、模式、使用次数、关联作品、描述全文、三个动作全在 Inspector | 符合 |
| 我的作品 | `List`（行内：标题、时间 + 音色、等宽时长、行内播放） | 导出/定位/重命名/删除在行内菜单与工具栏；技术摘要在 Inspector | 符合 |
| 服务状态 | 结论面板 + 控制面状态 + 能力矩阵（6 行）+ 运行信息（4 行） | 服务身份、端口、LaunchAgent、XPC 等技术事实在 Inspector | 符合（§7.5 明确要求这一页直接展示四行运行事实；每行是「名称 · 状态 · 一句原因」的列对齐行，不是段落） |
| 运行监控 | 结论条 + 6 个黄金信号 + 趋势图 + 运行组件表 | 能力状态、资源与准入、直方图累计摘要收进默认收起的「逐指标明细」 | 符合 |
| 模型 | 三张档位卡（各：档位名 + 一句适用场景 + 三行差异）+ 动作行 + 制品表（5 行 × 4 列） | 来源、目标档位、使用状态、路径说明在 Inspector | 符合 |
| 诊断 | 左：8 项检查（名称 + 一句说明）；右：结论胶囊 + 一句影响 + 唯一修复动作 | 编号修复步骤与技术上下文在详情下方/折叠区；全通过时整页退化为一个 `StatusBanner(kind: .conclusion, tone: .healthy)` 结论面板（主动作「查看检查明细」），点开才展开清单，清单头可用「只看结论」收回 | 符合（2026-09-16 修订：全通过由 `ContentUnavailableView` 改为结论面板；展开补上回程） |

没有发现需要收起的第五处：每一页的首屏要么是「结论 + 主对象」，要么是列对齐的表格行，
没有出现整段铺开的说明文字。真正会堆字的地方（Inspector、折叠区、直方图累计口径）都已折叠或移出首屏。

本轮验证：只做源码与规范核对，没有改代码；App 构建与 `build-for-testing` 状态沿用第十二轮的通过结果。

#### 第十四轮：运行监控补上 `voice_class` 维度

第十二轮的帧图核对留了一个问题：稿的「运行组件」表有四列（组件 / 状态 / 平均时延 / 样本），
应用只有两列。这一轮先去服务端确认那两列到底能不能做出来，再决定补什么：

| 指标 | 服务端实现 | 有没有 worker 维度 |
|---|---|---|
| `speechrail_asr_inference_duration_seconds` | `Metrics.record_asr(...)` → `observe(name, value, buckets)` | **没有标签** |
| `speechrail_tts_inference_duration_seconds` | `Metrics.record_tts(...)` → `observe(..., voice_class=voice_class)` | 没有；只有 `voice_class` |
| worker 生命周期 | `speechrail_worker_evictions_total{component=…}` 等 | 有（所以「状态」列成立） |

`voice_class` 由 `tts_voice_class()` 做低基数映射，只有 `system` / `custom` / `clone` 三个值，
不存在高基数风险。结论：**按 worker 的时延表做不出来**（编一张表就是假数据），
但「按音色类别看 TTS 时延」是真实存在、且正是 Grafana 会保留的那个 label。于是：

| 位置 | 改动 |
|---|---|
| `RuntimeMetricsSampler.makeSample` | 新增 `ttsDurationByVoiceClass`：把 `speechrail_tts_inference_duration_seconds` 的各 label 序列按 `voice_class` 分组，组内仍按 Prometheus 口径聚合（`sum` 相加、`count` 加权）；新增 `labelValue(_:label:)` 只读需要的标签，不假设它在串里的位置 |
| `RuntimeMonitoringWindow` | 新增 `ttsLatencyByVoiceClass`：每个类别各算一次 `increase(sum) / increase(count)`，按类别名排序保证行序稳定；无样本返回空数组（不是 0） |
| `RuntimeMonitoringView` | 「逐指标明细」里新增「按音色类别」面板（系统音色 / 我的音色 / 参考音色 + 样本数），空态是「当前窗口没有 TTS 时延样本」 |
| `ControlKitTests` | 新增 3 条：按类别拆分且合并口径不变、无样本是空数组、标签解析只读指定 label |

面板放在默认收起的明细区，首屏仍然是黄金信号 + 趋势 + 运行组件（§7.6.1 密度约束不变）。

本轮验证：`./scripts/macos_app_build.sh --configuration Debug` 与
`xcodebuild … build-for-testing` 通过（含新增测试的编译）。按 AGENTS.md，**单测未运行**——
测试断言只有编译级证据。

#### 第十五轮：帧的出处、代次判定与剩余五页核对

用户在 2026-09-16 指出 `figma-kit/main.js` 只是喂给 Figma 的生成脚本，不是设计来源。
本轮的稿侧证据因此固定为**用户导出的帧图**，并把「这批帧是哪一次生成的」查清楚——否则会拿旧一代
的帧去改新一代的应用。

**证据出处**：`~/Downloads/speechrail-screens-4x/`，16 帧（`▸ 配音台`…`▸ 诊断` 各浅色/深色两列）
加 `Foundations.png`、`Menu & Settings.png`，导出时间 **2026-09-15 22:04**。另有更早的 1x 一组
（`~/Downloads/speechrail-screens-20260915/`，14:00），只作历史参考。

**代次判定**（用帧里可判定元素对比当前脚本，不靠时间戳猜）：

| 判据 | 帧（22:04） | 当前脚本 |
|---|---|---|
| 诊断的 8 个检查项 | 模型校验未完成 / 受管 runtime 完整 / LaunchAgent 已注册 … | 应用的真实检查名（应用目录 / 配置文件 / … / 实时语音检测） |
| 设置 · 通用 | 登录时启动服务、启动后打开管理控制台、菜单栏图标 | 「启动时读取服务状态」+「默认展开技术详情」，脚本注释写明「不放应用里不存在的开关」 |
| 设置 · 创作 | 候选数量、默认导出位置 | 默认音色 + 默认语速 |
| 音色库列表头 | 「按最近使用排序」+ 行尾时间 | 无排序标签，行尾是试听按钮 |
| 运行监控「运行组件」 | 4 列（含平均时延 / 样本） | 2 列，脚本注释「平均时延与样本数来自下面的直方图摘要」 |
| 菜单面板首项 | 「打开管理控制台」 | 「打开 SpeechRail」 |

结论：**这批帧是当前脚本前一代生成的**。所以第十二轮改掉的那 4 处文案差异是真的（帧与当时的脚本
都错），而「帧里有、应用里没有」的其余条目大多属于「帧过期」，会在下一次生成后消失。

**服务端数据可得性（决定帧里的元素能不能做）**：

| 帧里的元素 | 服务端事实 | 结论 |
|---|---|---|
| 音色行的「刚刚使用 / 昨天」+「按最近使用排序」 | `/v1/voices` 只返回 `id / name / description / seed / created_at / available / mode`（`http/routes/system.py`），**没有 `last_used`** | 做不出来；应用用行内试听 + Inspector 的「创建时间 / 使用次数（关联作品）」替代 |
| 诊断的检查项名称 | 检查项由服务端 preflight 返回，应用只做名称映射（`checkTitle(for:)`） | 不能写死样例名；当前脚本已改为应用的真实映射 |
| 按 worker 的平均时延 / 样本 | 时延直方图没有 worker 维度（第十四轮） | 做不出来；改为按 `voice_class` |

**本轮新核页面**（帧 ↔ 当前脚本 ↔ 应用逐项）：音色库、我的作品、诊断、菜单面板、设置。
五页的应用实现与当前脚本逐项一致（列表列头、行内动作、页脚说明与按钮、Inspector 字段顺序、
菜单项与快捷键、设置三个页签的每一行），**没有新增应用侧改动**；差异全部落在上面三张表里。

核对过程里发现两处**脚本本身与实现不符**（会污染下一次生成的稿），已在脚本侧修正：

| 位置 | 脚本（修前） | 修正 |
|---|---|---|
| 音色库 · 来源徽标 | 只有「我的」行画徽标 | 每行都画（系统 / 我的）：应用的 `sourceBadge` 不带条件分支，§7.3 也把来源徽标写成行内固定项 |
| 我的作品 · 工具栏行 | 只有搜索框 | 补上排序 segmented（最新优先 / 最早优先）：这是应用工具栏行左侧的控件，§7.4 要求「按时间排序」 |

`code.js` 已重新生成（142648 bytes，SHA-256 `97cd825b41718ec5704e6438cceea13713a24ef209bae9cc2fbf0d539d8ba3e2`），
下一次在 Figma 里重跑插件即得到与应用同代的稿。

本轮验证：只有文档改动，App 与测试目标的构建状态沿用第十二～十四轮的通过结果；
仍未运行单元测试与 UI 自动化。

#### 第十六轮：三处静态风险核查（字面色 / 最小窗口 / UI 测试期望值）

第十五轮结尾写了「源码侧没有待办」。这一轮按「先证伪自己」的顺序查了三件还没验过的事，
结果两件成立、一件查出真问题。

**① 字面色**：全仓搜 `Color(red:` / `Color(.sRGB` / `Color(hue:` / `Color(white:` /
`NSColor(red:` / `#RRGGBB` 六种写法，**零命中**。颜色全部来自系统语义色与 token ⇒
浅色/深色与 Increase Contrast 由系统接管，不需要应用自己维护两套值（§5.4 的代码级证据；
视觉矩阵仍待走查）。

**② 最小窗口尺寸**：§11.2 声明最小 1120×720。代码里不是只有变量——
`ControlCenterView` 用 `.frame(minWidth: Layout.windowMinimumWidth, minHeight: Layout.windowMinimumHeight)`
真的约束住窗口（UI 测试会话降到 1000 宽，好让测试窗口能放进 CI 的屏幕）。符合。

**③ UI 测试期望值**（查出问题）：把测试文件里的 42 条中文字面量逐条在应用源码里查，
6 条对不上，其中 5 条是今天这轮界面演进后**真的过期了**，1 条是从来不存在的选择标签：

| 测试里的期望（修前） | 应用当前值 | 处理 |
|---|---|---|
| `从一句话开始` | 「用一句话描述你想要的音色，从真实预览里挑一个保存进音色库。」 | 测试改用 `AppRoute.voiceDesign.pageSubtitle` |
| `A 槽位试听：播放` / `A 槽位试听：暂停` | 「候选 1 试听：播放」/「候选 1 试听：停止」（槽位是 `1`…`4`，播放中写「停止」不是「暂停」） | 测试改用真实标签 |
| `系统音色与创作资产` | 「管理系统音色，以及用参考音频复刻出来的音色。」 | 测试改用真实副行 |
| `label CONTAINS "取消试听"` | 行进中试听的行内按钮是「取消 \<音色名\> 的试听」 | 谓词改成 `label BEGINSWITH "取消"` |
| `回看 SpeechRail 创作的作品` | 「本机生成过的音频都留在这里，可随时播放、导出或删除。」 | 测试改用真实副行 |
| `label BEGINSWITH "选择作品："` | 应用从未有过这个标签（行是 `.accessibilityElement(children: .contain)`） | 作品行补 `.accessibilityIdentifier("work-row")`，测试按标识定位并点击选中 |

最后一行是应用侧唯一的改动（1 行标识，和 `workspace-title`、`diagnostics-run` 同类做法）：
行的可见标签由作品标题拼出来，测试侧无法先验知道标题，只能靠稳定标识。

本轮验证：`./scripts/macos_app_build.sh --configuration Debug` 与
`xcodebuild … build-for-testing` 通过。**UI 测试仍未运行**（AGENTS.md 硬约束：UI 自动化需当次明确授权），
所以上面这些定位符只有源码级证据，没有运行级证据。

#### 第十七轮：输入区高度标定（用户改判「可接受滚动条，优先原生组件，只优化大小高度」）

用户 2026-09-16 把第五轮的第一条重新定调：**滚动条可以出现，组件优先用系统的，但尺寸和高度要继续优化**。
这轮不再碰滚动行为，只做两件事：量准、改对。

**先把「稿有多高」量出来**（权威证据是用户导出的 4x 帧，`~/Downloads/speechrail-screens-4x/`，
5760 × 3600 = 1440 × 900 @4x；方法是在内容列 x = 0.62 × 宽度处竖列扫描像素，取卡片底色连续区间）：

| 帧 | 实测 | 说明 |
|---|---|---|
| `▸ 配音台.png` | 输入卡 135.5 → 702.2pt，**约 567pt** | 该帧画的是「占满剩余高度」——正是用户说的「太高、太大、太丑」 |
| `▸ 音色创作.png` | `promptCard` 135.5 → 430.2pt，约 296pt | 其中描述字段按脚本 130pt 画，与帧一致 |

第十二轮那张表把配音台帧高记成「约 287pt」，与本轮实测不符且无法复现（更旧的 1x 导出
`speechrail-screens-20260915/01-dubbing.png` 是另一套版式）。已按实测改正，那一行的「帧过期」归类
也不再成立——配音台高度现在是应用**主动偏离**脚本与帧的地方（见下表）。

**改动**：

| | 帧 | 应用（改前） | 应用（改后） |
|---|---|---|---|
| 配音台 · 输入卡 | 567（占满） | 320–420，实际恒为 420，卡实际渲染约 455 | **280–360**，常规窗口停在 360（卡 = token，见下） |
| 音色创作 · 描述框 | 字段 130（整卡 296） | 160–320，理想 200，卡实际约 235 | **130–200**，理想 160 |

1. **高度区间从编辑器移到整张卡**：稿的 `editor` / `promptField` 量的是「正文 + 元信息行」的整卡，
   而区间此前套在 `TextEditor` 上，卡会多出页脚那一行（约 35pt）——token 写 420，画出来是 455。
   现在 `SpeechRailComposerTextEditor` 把 `frame(minHeight:idealHeight:maxHeight:)` 套在最外层
   VStack 上，`TextEditor` 用原生 `.frame(maxHeight: .infinity)` 吃掉页脚之外的高度。
   没有自量高、没有隐藏滚动条，滚动仍是 `TextEditor` 原生行为。
2. **配音台 420 → 360**：360 保留「文稿是页面主对象」的地位，又比帧的 567 低约 37%、比改前的 455 低约 21%；
   1120 × 720 最小窗口下列高约 578pt，卡片占比从 79% 降到 62%，控制条与结果条不再被挤出。
3. **音色创作 200 → 160**：160 = 稿字段 130 + 框内多出的字数/门禁行（应用把那一行收进了框里并加了分隔线）。
   正文可写高度与稿基本一致，而候选区整体上提约 80pt（§7.6.1 渐进式披露）。
4. 音色库编辑面板里「音色描述」`TextEditor` 借用的 `creatorVoiceInstructionMinimumHeight` 由 160 降到 130
   （同一概念、同一取值口径，记录在案以免被当成意外改动）。
5. 脚本侧同步：`size(editor, null, 420)` → `360`；`size(field, 1120, 130)` → `160`，让下一次生成出来的稿
   与应用同高（字段与卡同色，看过去仍是同一块）。

本轮验证：`./scripts/macos_app_build.sh --configuration Debug` **BUILD SUCCEEDED**；
`node --check main.js && node build.js` 通过，`code.js` 重新生成（142833 bytes，
SHA-256 `69e0c87d481198d5284cd8c8fa0593254a3ab5b27ad566e2ded9cde58f754180`）；
`git diff --check` 干净。**未运行单元测试与 UI 自动化**（后者需当次明确授权）。
360pt 的文稿框是否仍偏大、130–200pt 的描述框够不够写，属于桌面走查项——数值都集中在这两个 token 对里，
走查后要调只需改一处。

**同一轮续做：页面级间距标定。** 既然高度已经用像素扫描量过，这轮把八个页面的**块间距**也用同一根尺子量了
（方法：在内容列取一条竖直扫描线，记录「页面底色」连续带；页面底色 = 取样自右上角的 `(232,232,234)`）：

| 页面 | 块与块之间的底色带（pt） |
|---|---|
| 配音台 | 19 / 19 |
| 音色创作 | 20（卡 → 区块标题 → 候选网格，共 81pt 中两侧各 20） |
| 音色库 | 22 |
| 我的作品 | 21 |
| 服务状态 | 21 / 19 |
| 运行监控 | 19 |
| 模型 | 21 / 21 |
| 诊断 | 两栏之间 15（栏与栏比块与块紧一档） |

结论：**页面级块间距 = 20pt**，与稿的生成脚本 `page: { gap: 20, padX: 20, padY: 20 }` 一致；
栏与栏 16pt、网格项 12pt（候选 2×2 横向量到 13pt 带）、页面外边距 20pt。
应用此前在页面栈里混用 `lg`(24) 与 `sm`(12)——配音台三块之间只有 12pt，比稿紧 8pt。

改动：新增 `Spacing.gutter = 20`（页面级块间距），替换 5 处页面栈间距
（`PageScaffold` 页头→正文、配音台三块、服务状态能力卡→运行卡、模型档位卡→选中面板、诊断两栏改 `md`）。

顺手把**两张输入卡的内边距**也对齐了（方法同上：量正文第一列/第一行的深色像素到卡沿的距离）：

| | 稿 | 应用（改前） | 应用（改后） |
|---|---|---|---|
| 配音台输入卡 · 正文距卡沿 | 左 20pt / 上 26pt（脚本 `padX 18, padY 16`） | 约 14pt（`Spacing.sm` = 12） | `Layout.cardInset` = 20（见下：统一后的卡片内边距） |
| 音色创作描述框 · 正文距卡沿 | 同上 | 同上 | 同上 |
| 配音台控制卡 | `padX 16, padY 12`（实测文字左沿距卡沿 17.8pt） | 12 / 12 | 16 / 12（精确一致） |
| 音色创作 `promptCard` | `pad: 18` | 12 | `Layout.cardInset` = 20 |

两张输入卡的页脚信息行（字数 / 清空 / 保存门禁）同步跟随，避免与上方正文错位。

**逐卡对账的结果是：稿只有一档。** 把量法放宽到「卡片区域整段取最小」之后（单行取样会撞上
笔画更窄的字或图标），六个页面的第一行文字都落在同一个位置：

| 页面 / 元素 | 卡左沿 | 首个字素 | 内边距 |
|---|---|---|---|
| 服务状态 · 能力卡表头 | 261 | 280.5 | ≈ 18 |
| 服务状态 · 运行信息行 | 261 | 282.0 | ≈ 19 |
| 模型 · 制品表 | 261 | 280.2 | ≈ 18 |
| 运行监控 · 图表卡表头 | 261 | 280.5 | ≈ 18 |
| 运行监控 · 运行组件表 | 261 | 280.2 | ≈ 18 |
| 音色库 · 列表行 | 261 | 278.2 | ≈ 16 |
| 我的作品 · 列表行 | 261 | 278.5 | ≈ 16 |
| 诊断 · 检查列表 | 261 | 278.5 | ≈ 16 |
| 配音台 / 音色创作 · 输入卡 | 261 | 281.0 | ≈ 18 |

即稿的**卡片内容内边距 = 18pt**，内容卡、表头、表行、列表行一致（脚本侧也对得上：`card()` 默认
`pad: 18`，表卡 `pad: 0` + 内层表头 `padX: 18` / 行 `padX: 18`）。应用此前分成 12 / 16 / 24 三档。
本轮新增 `Layout.cardInset = 20`（距稿 18 差 2pt，且与页面级块间距同值，读起来是一根尺子），
并把三档统一过去：两张输入卡的正文 / 提示行 / 页脚、音色创作 `promptCard`，以及六个页面内容卡
（服务状态控制卡、档位选择卡、模型选中面板、运行监控结论卡、路由预览卡、诊断详情面板）。
稿里显式写死的**工具栏式卡片**（配音台 `composer`，`padX 16 / padY 12`）保持 16/12，不套这一档。
sheet（重命名 / 保存音色）与设置窗口（`formStyle(.grouped)`）不在稿内，保留各自 24pt。

#### 第十八轮：字号与图标标定（Foundations 变量表对账）

第十三～十七轮把结构、文案、间距都对完了，这一轮拿稿的 **Foundations 变量表**（`Foundations.png`，
生成脚本里的 `NUMBER_TOKENS` / `TEXT_STYLE_DEFS`）逐条对应用 token，发现的不是间距而是**字号**：

**① 稿的标题只有一档。** 脚本里 `Title / Page` = 20pt Semi Bold，用在页标题、面板标题、结论标题、
诊断详情标题、档位卡标题上。4x 帧实测四处 ink 高度：页标题八页 18.75–19.0pt、服务状态结论标题
18.75、诊断详情标题 18.25、音色创作区块标题（对照）12.25 = 13pt。应用此前把这些位置拆成
`.title2`(17) 与 `.title3`(15) 两档（`display` / `windowTitle` / `statusTitle` / `diagnosticsSummary`）。
系统文本样式没有 20（`NSFont.preferredFont`：largeTitle 26 / **title1 22** / title2 17 / title3 15，
本机 Xcode 26 实测），取最近的 `.title`(22，+2pt 残差) 并把四处统一过去；保留系统样式以随
「更大文字」缩放，而不是写死 20pt。

**② 状态结论面板与行内反馈要分开。** 稿的 `conclusion` 是页面主对象（`pad 18` + `surface/readyTint`
底色 + 1pt 状态色描边 + 26pt 图标 + `Title / Page` 标题 + `Callout` 副行），而 `Empty State` 组件是
另一套（居中、`pad 32`、28pt 图标、`Heading / Section` 标题）。应用此前用同一个 `StatusBanner`
两种场合通吃，于是标题只能取中间值。本轮给 `StatusBanner` 加 `Kind`：`.conclusion`
（状态底色 + 1pt 状态描边 + 26pt 图标 + `Title / Page` 标题 + `Callout` 正文，服务状态页使用）、
`.standard`（面板底色 + 17pt 图标 + `Heading / Section` 标题 + `Callout` 正文，行内反馈与空态使用）。
图标 26 有两条独立证据：脚本 `icon(conclusion, "circle-check", 26)`，以及帧上该图标墨迹宽 21.2pt
（= 0.82 × 26）。

**③ 行内文字不再用「中等字重」凑。** 稿的行样式是明确的：表行 / kv 值 / 菜单行 / 折叠行标签都是
`Callout`（12pt Regular），诊断检查行与结果条标题是 `Body / Medium`（13pt Medium）。应用此前有
10 处用 `Typography.label`（12pt Medium，稿里不存在的组合）。本轮按元素归位：7 处改 `callout`
（音色创作折叠行、音色库与作品的 inspector 折叠行、档位卡 kv 值、监控表行、逐指标明细行、
「更多操作」菜单行），3 处改 `bodyMedium`（配音失败条标题、模型操作条标题、诊断检查行标题）。
保留 `Typography.label` 仅给 `SpeechRailStatusLine`（应用自有的行内状态行，稿里没有对应元素）。

**未对齐但记录在案的两处**：稿的空态组件是**居中、无动作**的（icon 28 + 标题 + 一行说明），
应用的行内反馈面板是左对齐且带主动作——空态在稿的页面帧里没有出现，只在组件页里定义，
本轮只对齐它的字号与正文档位，版式保留应用的（可操作）做法；稿的状态底色是手挑的 tint 变量
（`surface/readyTint` 等），应用沿用 §5.4 的系统色 + 状态色 14% 透明度约定，视觉差约 10–15 个
RGB 级差。

本轮验证：`./scripts/macos_app_build.sh --configuration Debug` **BUILD SUCCEEDED**（第一次尝试用了
`Font.TextStyle.title1`，SwiftUI 里不存在，编译期即报错并以 `.title` 修正）；`git diff --check` 干净。
字号与图标观感仍需桌面走查。

#### 第十九轮：输入卡页脚带与计数行（用户重新定调后的续标定）

用户在第十七轮之后把输入区的口径又确认了一遍：**滚动条可接受、优先原生组件、只优化大小高度**。第十七轮
已经把「高度区间套在整卡」这件事做完了，这一轮沿着同一张开着的卡继续量，量的是**卡内**的比例。

**① 页脚是一条固定高度的带，不是「一行 + 上下内边距」。** 在 `▸ 配音台.png` 上整行扫描规则线
（x ∈ [280, 1400]、判据为 190 ≤ R ≤ 246 且近中性色），只有一条贯穿卡片的线：**y = 660.5–661.25pt**；
卡片下沿在 703.75pt。即分隔线到卡底是 **42.5pt** 的固定带，与既有 token `Layout.compactDividerHeight`
（42）同值。同一根尺子扫 `▸ 音色创作.png`：整张 `promptCard` 内**没有任何贯穿线**——稿在这一页把
字数/门禁行画在字段之外、没有分隔线（应用因为把这一行收进卡里、且提示行固定在卡底，保留一条分隔线，
见 §7.2）。应用此前页脚只给上下 `Spacing.micro`(4)，约 21pt 的带，比稿紧一档。

| | 帧 | 应用（改前） | 应用（改后） |
|---|---|---|---|
| 配音台输入卡 · 页脚带 | 42.5（660.5 → 703.75） | ≈ 21（`micro` 上下内边距） | **42**（`Layout.composerMetaRowHeight`，残差 0.5） |
| 音色创作描述卡 · 页脚带 | 无分隔线，行在字段之外 | ≈ 21 | **28**（`Control.compactHeight`，紧凑控件下限） |

改动落在共享组件 `SpeechRailComposerTextEditor` 上：新增 `metaRowHeight` 参数（默认取 token 42），
页脚用 `.frame(minHeight: metaRowHeight, alignment: .center)` 居中；两个调用点不再各自给纵向内边距，
音色创作显式传 `Control.compactHeight`，整卡 160pt 仍是「稿字段 130 + 提示行 + 元信息行」的算法。
**带高是下限**：系统字号放大时行仍能长高，不写死。配音台的带高从页脚吃走 21pt，正文可写区随之
由约 339pt 收到约 317pt，方向与「太高太大」一致，整卡仍在 280–360 区间内。

**② 计数行的字面。** 两张帧的页脚计数都是 `62 / 5000 字`、`28 / 400 字`（斜杠两侧有空格；数字是稿的
占位，应用用真实上限 `SpeechRailCreatorLimits`），应用此前写作 `n/上限 字`。本轮按帧改成
`\(count) / \(limit) 字`，两个调用点同步；无障碍标签仍是口语化的「文稿 n 字，上限 m 字」，不变。

**本轮验证**：`./scripts/macos_app_build.sh --configuration Debug` **无法执行**——本机 Xcode 已升到
27.0（27A266a），而 `/Library/Preferences/com.apple.dt.Xcode.plist` 里记录的许可同意版本是 **26.6**，
任何 `xcodebuild` 动作都会以「You have not agreed to the Xcode license agreements」中止
（`-version`、`-checkFirstLaunchStatus` 不触发该检查，`/usr/bin/git`、`/usr/bin/clang` 等 CLT 影子程序
同样被挡）。已接受许可的是 **26.6**，需要管理员执行一次 `sudo xcodebuild -license accept` 才能恢复构建。
等价的替代验证：用 Xcode 工具链直接做类型检查（`swiftc -emit-module` 编出 `SpeechRailControlKit`
模块，再对 26 个 App 源文件跑 `-typecheck`，`-sdk MacOSX.sdk -target arm64-apple-macos26.0
-swift-version 6`）——**0 error**。`git diff --check` 干净。这不是完整构建，链接、资源与签名仍未验证。

页脚带 42/28 的观感、以及配音台正文区少掉 21pt 后的手感，属于桌面走查项。

#### 第二十轮：字号档位标定（页脚 / 控制条 / 列头 / 取值行）

第十九轮量的是输入卡内的**比例**，这一轮量的是**字**：稿的 `Foundations` 里有完整的文字样式表
（生成脚本 65–75 行 `TEXT_STYLE_DEFS`），应用此前有几处落在相邻的一档上。量法与前面同源——
4x 帧上扫 ink 高度，CJK 的 ink ≈ 0.92 × 字号（用 13pt 正文实测 11.75–12.0 反推）。

**① 输入卡页脚与控制条**（与用户本轮指令直接相关的部分）

| | 稿 | 应用（改前） | 应用（改后） |
|---|---|---|---|
| 配音台页脚计数行 | `Subheadline`(11) + `text/secondary`（帧实测 #6E6E73） | `caption`(10) | `Typography.secondary` + `inkSecondary` |
| 配音台页脚「清空」 | `Subheadline`(11)（「清空」两字 ink 9.5–9.75） | 系统按钮默认档 | `.font(secondary)`，控件仍是原生 `.borderless` |
| 音色创作页脚计数行 | `Subheadline`(11) + `text/tertiary`（帧实测 #A1A1A6） | `caption` + secondary | `secondary` + `inkTertiary` |
| 音色创作门禁句 | `Subheadline`(11) | `caption` | `secondary` |
| 输入卡提示行（稿 `promptField/hint`） | `Callout`(12) + tertiary（帧 ink 11.0） | `caption`(10) | `callout` |
| 控制条字段标签「音色」「语速」 | `Subheadline`(11) + secondary（帧上「音色」x 278.5–299.25、「语速」459.5–480.25） | 只有「语速」有标签且是 `caption`，胶囊上方空着 | 新增 `voiceControl`（「音色」标签包住选择器），两处都 `secondary` |
| 控制条「语速」取值 | `Body / Medium`(13) | `caption`(10) | `bodyMedium` + `monospacedDigit` |
| 音色库列表行 名称 / 副行 | `Body / Medium` / `Callout`（副行帧实测 ink 10.75） | `body` / `caption` | `bodyMedium` / `callout` |

**② 字号档位表：列头与取值行**

| | 稿 | 应用（改前） | 应用（改后） |
|---|---|---|---|
| 状态胶囊标签（`StatusPill`） | `Caption / Medium`(10 Medium) | `caption`(10 Regular) | 新增 `Typography.captionMedium` |
| 我的作品列头 / 模型制品表列头 | `Caption / Medium` | `caption` | `captionMedium` |
| Inspector 取值行标签 | `Callout`(12)（帧上 CJK 字宽 10.5、步进 11.75） | `caption`(10) | `callout` |
| Inspector 取值 / 制品表量化·文件列 | `Callout`(12) | `technical`(10 等宽) | 新增 `Typography.technicalValue`（12 等宽，保留 §9 的等宽数字约定） |

**③ 音色创作 `promptCard` 页脚：折叠行与主按钮同行。** 帧实测折叠行文字 ink 390.0–400.75
（中心 395.4）、右侧主按钮填充 378.5–412.25（中心 395.4、高 34），两处中心重合——稿把这一行画成
「左折叠行 + 右键帽 + 主按钮」。应用此前把键帽与按钮另起一行，卡片因此比稿高约 46pt。改为
同一 `HStack(alignment: .top)`，按钮侧按 `List.rowHeight` 居中：展开折叠区时按钮仍停在标签行上。

**④ 判为「不追」的三处**（记录以免被当成漏改）：

| 位置 | 稿 | 应用 | 为什么保留 |
|---|---|---|---|
| 运行监控 worker 表 | 列头 `Caption / Medium`、单元格 `Callout` | 原生 `Table` 的系统字号 | §4.2「列表交还系统」：`Table` 的表头与行字体由系统控制，与稿只差 1pt；自己钉字号就要自绘表头，与「优先原生」冲突 |
| 诊断 · 开发者详情（折叠区） | 帧上没有这一区 | `technical`(10 等宽) | 应用自有的密集区块，不是稿的元素 |
| 设置窗口 / 菜单面板 | 组件页有样式表，页面帧没有逐行字号 | 原样 | 不在稿的页面帧内（§12.3） |

**本轮验证**：与第十九轮同一处境——本机 Xcode 已升到 27.0 而许可同意记录仍是 26.6，`xcodebuild`
仍不可用，所以用工具链直接类型检查（26 个 App 源文件，`-swift-version 6 -target arm64-apple-macos26.0`）
——**0 error**；`git diff --check` 干净。**未运行单元测试与 UI 自动化**（后者需当次明确授权）。
本轮改动全是 `Typography` 换档，观感属于桌面走查项。

#### 第二十一轮：控件高度与卡片带（本机离屏量测 + 帧对账）

前二十轮都只从帧图上量，量不到「应用里这个控件到底画多高」。这一轮补上另一半证据：用
`ImageRenderer` 在**离屏**（不开窗口、不接管前台、不截屏，因而不触碰 UI 自动化授权）把系统的
`Button` / `Picker` / `Text` 渲染出来量尺寸。两个来源对上以后，字号相同的元素高度差就有定论了。

**① 本机实测的系统控件档位**（macOS 26 SDK、arm64、`-swift-version 6`）：

| 控件 | `.mini` | `.small` | `.regular` | `.large` | `.extraLarge` |
|---|---|---|---|---|---|
| `borderedProminent`（主按钮） | 13 | 20 | 24 | 28 | **36** |
| `bordered`（次按钮） | — | 20 | 24 | 28 | **36** |
| `segmented` | — | 20 | 24 | — | — |

文本行高：`body` 16 / `callout` 15 / `subheadline` 14 / `caption` 13 / `headline` 16 /
`title` 26 —— 这就是应用各条带比稿矮的那 ~3.5pt/行 的来源（稿的行高是 135–150%）。
另外实测：**`.controlSize` 不改变按钮标签字号**（三种档位下标签 ink 都是 12.0pt），
所以放大控件不会连带把文字放大。

**② 稿的控件高度 → 应用取值**：

| 元素 | 稿 | 应用（改前） | 应用（改后） |
|---|---|---|---|
| 主按钮 | 34（`primaryButton`，帧实测 737.0→770.75） | 24（`.regular`）/ 配音台 28（`.large`） | `.extraLarge` 36（残差 2） |
| 次按钮 | 30（`secondaryButton`，帧实测 691.0→720.75） | 24 | `.large` 28（残差 2） |
| 音色胶囊（配音台控制条） | 30（帧实测 757.0→786.75） | 24 | `.large` 28 |
| 安静按钮（清空 / 更多设置） | 无填充，20 高 | 16 | 保持：没有可见的填充与描边，差的是命中区 |
| 状态胶囊 / 键帽 | 18（帧实测 323.0→340.75） | 17（`tight`=2 + `caption` 13） | 不变 |
| 分段控件 | 25–27 | 24（`.regular`） | 不变（残差 ≤3） |

改法落在共享的 `SpeechRailButtonAppearance`：主按钮 `.extraLarge`、次按钮（含危险动作）
`.large`、安静按钮保持 `.regular`；页面内直写 `.buttonStyle(.borderedProminent)` 的两颗生成按钮
（配音台 / 音色创作）与页头、胶囊按钮同步。**sheet、确认框与空态不在稿内**，一律不动。

**③ 卡片带（同一轮顺手对完）**：

| 元素 | 稿 | 应用（改前） | 应用（改后） |
|---|---|---|---|
| 内容卡「标题 + 一句说明」带 | 70（`head` padX 18 / padY 16 / gap 3；能力卡、运行信息卡、运行组件卡、制品卡四处实测都是 70） | 59 | 67（`padY` 12→16） |
| 列表卡「只有标题」带 | 42（`listHead` padY 12） | 40 | 不变 ✓ |
| 服务状态 · 运行信息行 | 39.5（`infoRow` padY 10 + Body 19.5；帧实测 40） | 32 | 40（`padY` 8→12） |
| 制品表 · 数据行 | 39.4（padX 18 / padY 11 + Callout 17.4；帧实测 39） | 32 | 40（`padY` 8→12） |
| 制品表 · 列头与数据行左沿 | 18 | 8 | 16（与同一张卡里的 `CardHead` 对齐） |

改法：`CardHead` 按稿分成两档（有 `detail` 时 padY 16，只有标题时 padY 12 —— 稿上本来就是
`head` 与 `listHead` 两个组件）；`ServiceOverviewView.runtimeRow` 与
`ModelManagementView.ArtifactChoiceRow` 的纵向内边距 8 → 12（应用行高 16 比稿的 19.5 紧，
用内边距补回同一档带高）。

**④ 记录在案的两处不追**：① 系统行高比稿紧 ~3.5pt/行，不逐条补 `lineSpacing`（§5.5：只用系统
文本样式；唯一例外是输入区，那里行距是逐帧量出来的一等设计参数）；② 服务状态结论面板的动作按钮
在稿上是次按钮（帧画的是「打开诊断」这条导航动作），应用在可改写运行态时给的是填充主按钮
（「启动服务 / 重启服务」），语义不同，保留主按钮层级。

**⑤ 制品表的列几何**（同页顺带对完）。稿 `artifacts` 的列是 `COLS = [440, 200, 140]` + 校验列吃余量、
**列间距 0**；4x 帧实测列沿：制品 280.5、量化 720.5（左对齐）、文件右沿 1060.5（右对齐）、校验右沿
1400.5（右对齐）。应用此前是「弹性制品 + 84 / 64 / 120 三列挤在右侧、校验左对齐」，同一行里最右一列
的位置与稿差约 250pt。改为共用的列几何：`ArtifactColumnMetrics` 给两套值（稿的原值 / 收窄值），
`ArtifactColumnGrid` 用 `ViewThatFits` 先按稿排、排不下（1120pt 最小窗口下卡内容区只剩约 808pt）
再退到收窄版；列间距 0，与稿的 `gap: 0` 一致。

离屏复核（同样用 `ImageRenderer` 量列的 x 位置）：1440 宽窗口下制品列 16→456、量化列 456、
文件右沿 796、校验右沿 1107，与帧的 441.5 / 781.5 / 15.5（相对卡内容区）逐列重合到 **1.5pt 内**；
1120 宽窗口下自动退到收窄版，四列都在卡内、没有截断。

**本轮验证**：工具链直接类型检查 26 个 App 源文件 **0 error**；`git diff --check` 干净；
离屏量测脚本输出即上表数据。`xcodebuild` 仍被 Xcode 27.0 的许可检查挡住（需
`sudo xcodebuild -license accept`），因此**未构建、未运行单元测试与 UI 自动化**（后者需当次明确授权）。
控件高度的观感属于桌面走查项。

#### 第二十二轮：输入区的「嵌卡」形态与可写高度（用户三度校准）

**用户口径**（2026-09-16，取代第十九轮前的「默认不应有滚动条」）：滚动条**可接受**、优先原生
组件，但**大小高度仍要优化**。滚动条继续由原生 `TextEditor` 承担，不自量高、不隐藏指示器
（全仓只有检查器 `ScrollView` 一处 `.scrollIndicators`，为 `.automatic`）。

**量测口径升级**：第二十一轮的探针只渲染系统控件，量不到应用自己的输入区。本轮先把 App 源码
编译成模块（`SpeechRailControlKit` 同法），再让探针**直接实例化真实的
`SpeechRailComposerTextEditor`**（不再手抄结构），用 `ImageRenderer` 离屏量卡与内部条带。
两条布局路径给的是不同提案，因此分别量：

| 场景 | 容器提案 | 区间 token | 实测整卡 |
|---|---|---|---|
| 配音台（`PageScaffold(scrollable: false)`） | 确定高度 | 280 / 340 / 360 | **360**（取上限），正文 277、页脚带 41 |
| 音色创作（滚动页 → `ScrollView`） | 纵向 `nil` | 130 / 160 / 200 | **160**（取 `idealHeight`） |

**本轮查出的缺陷**：音色创作的描述框嵌在 `promptCard` 面板里，却仍按「自己就是一张卡」给自己
`Layout.cardInset` 内边距，于是正文被面板与输入区**各内缩一次**：

| 量 | 稿（4x 帧） | 应用（改前） | 应用（改后） |
|---|---|---|---|
| 正文顶距卡沿 | 21.0（`▸ 音色创作.png`，正文行盒 155.75 起） | 40.0 | **20.0** |
| 可写区高 | 102.5（引导行盒底 193.5 → 计数行盒顶 296） | 67.5（≈4 行） | **99.5**（≈6 行） |
| 正文与计数行之间的分隔线 | 无（帧 y=270–320 全为纯白） | 有（1pt） | **无** |

对照：`▸ 配音台.png` 的输入区**是**独立卡片，正文与页脚之间确有分隔线——帧 y=660.5–661.25
是 220,220,224，页脚带 41pt（`composerMetaRowHeight` 42 的来源）。两页结构本来就不同，
此前共用一种形态才导致差异。

**改法**：`SpeechRailComposerTextEditor` 增加 `Chrome`（`.card` / `.embedded`）——内边距与
分隔线按归属给，`.embedded` 的正文与引导行的水平内边距由外层面板提供（引导行自带
`Spacing.xs`(8) 的上间距，对应稿上正文与引导之间那 ~7pt）。页脚的水平内边距一并收进组件，
避免调用点再写一次（改前配音台的调用点自己加了一份，改后才回到 20pt）。

**记录在案的保留差异**：稿把 tertiary 引导行画在正文**下一行**（7pt 间距），应用把它放在编辑区
**下方**——原生 `TextEditor` 吃掉整块高度，要让引导行紧跟正文就得自量高或做成覆盖层，两者都会
破坏「优先原生组件」。计数行的带高仍由 `Control.compactHeight`（28）给，比稿的 14pt 行高宽松，
差额与稿里计数行到芯片行的 12.75pt 间距同量级。

**本轮验证**：全量 App 源文件类型检查 **0 error**；`git diff --check` 干净；上表四列均来自
离屏量测（探针在 `/tmp`，属临时脚本，不入库）。音色创作的两处用户反馈（更多设置可点、默认无
滚动条）仍在第二十轮与本节前面的记录里。**未构建、未运行单元测试与 UI 自动化**（后者需当次明确授权）。

#### 第二十三轮：模型卡片行距、作品列头与三条页面列表行（帧对账，原生 List 的边界）

继续把「帧上量得到、应用里量不到」的条带补齐。**先记一条证据边界**：`ImageRenderer` 不渲染
`List` / `ScrollView` / `TextEditor`（三者都出系统占位块），所以这几种原生容器**内部的**行高与
内边距无法离屏量测。这一轮对它们改用「代码声明对稿」：把行内边距显式钉成稿上的数值，
不再依赖系统默认内边距（系统默认值无从核对）。

**① 模型 · 档位卡（`ProfileChoiceCard`）**。稿 `Profile Card` 是 VERTICAL / gap 8 / pad 16，
`spec` 子帧 gap 6、`kvRow` 取 `Callout`（12pt，行高 17.4）→ 规格行行距 23.4；4x 帧
`▸ 模型.png` 实测三行 ink 起点 221.75 / 245.75 / 268（行距 24 / 22.25）。应用此前用
`Spacing.micro`(4)，系统 `callout` 行盒是 15，行距只有 19。改成 `Spacing.xs`(8)：行距 15 + 8 = 23，
离屏复刻量到 24 / 22（与帧同档），规格块残差从 11.2pt 收到 3.2pt。

**② 我的作品 · 列头**。稿 `cols` padX 16 / padY 10 + `Caption / Medium`（10pt，行高 13.5）= 33.5，
帧实测 34（y=181..214.75）。应用 `xs`(8) 只有 29，改 `sm`(12) 得 37（残差 3，另一侧是 5）。

**③ 三条页面列表行**（音色库 / 我的作品 / 诊断）。稿三处 `row` 都是 **padX 16 / padY 12**
（`info` 里 Body/Medium 19.5 + Callout 17.4 ≈ 37 → 整行 61，加 1pt hairline 即帧上 64 一档；
`▸ 音色库.png` 184 起的行带、`▸ 我的作品.png` 216 起的行带、`▸ 诊断.png` 同档，实测每行 63–64）。
应用此前只有 `List` 默认内边距 + 行内 4pt，行高不可控。三处统一改成行自己给
`padding(.horizontal, md=16) + padding(.vertical, sm=12)`，并 `listRowInsets(EdgeInsets())` 清零；
行高因此变成确定的 35 + 24 = 59（残差 4–5，余量来自系统分隔线与行密度）。
**侧栏不受影响**：稿的侧栏项是 padX 8（`main.js` navItem padX 8 / padY 7），
`List.rowHorizontalPadding` 仍是 8，留给侧栏那一处。

**④ 同轮核对、不改的两处**：服务状态 · 能力行帧实测 44（`▸ 服务状态.png` y=310..353.75 等六条
44pt 带），应用 `padY 12` + 胶囊 17 = 41——4pt 节奏里 12 与 16 分别给 41 / 49，41 更近，
按「取最近 token、记残差」保留；运行信息行 40 已在第二十一轮对平（帧 40，应用 40）。
模型页的「目标档位 / 当前服务 / 配置档位」与「准备大小 / 识别 / 合成 / VoiceDesign」两块
在画板上不出现，属第四轮已记录的「应用页面比画板长」一类，不是缺口（本轮未动）。

**本轮验证**：全量 App 源文件类型检查 **0 error**；`git diff --check` 干净；① 的行距由离屏复刻
量到（探针在 `/tmp`，不入库）；② ③ 只能给「代码声明 = 稿数值」这一步，**最终行高需要一次桌面走查**
（原生 `List` 不参与离屏渲染）。**未构建、未运行单元测试与 UI 自动化**（后者需当次明确授权）。

#### 第二十四轮：运行监控（原生控件真实几何 + 图表字号）

**量测手段再进一步**：上一轮记下「`ImageRenderer` 不渲染 `List` / `Table` / `ScrollView`」，
于是这些容器的内部几何无从核对。这一轮换成 **`NSHostingView`**：把视图挂进 `NSHostingView`、
`layoutSubtreeIfNeeded()` 之后遍历它的 `NSTableView` 子视图，直接读系统真实几何——**不开窗口、
不接管前台、不截屏**，因此仍不触碰 UI 自动化授权。

**① 系统 `Table` 的真实几何（本机 macOS 26 / arm64 实测）**：`headerView.frame.height` = **28**，
`rowHeight` = **24**（`rect(ofRow:)` 逐行都是 24）。应用自己的 `tableHeight(for:)` 写的是
`36 + 26 × n`，四行会预留 140 而系统只需要 28 + 96 = 124，多出的 16pt 会显示成表格卡底部
一段空带。改为 `28 + 24 × n`（两处 Table 共用这一个公式）。

**② 同一轮记下这手段的边界**：`List` 的行高在无窗口环境里不按内容布局（内容 90pt 高的行，
`rect(ofRow:)` 仍报 24），因此 **List 的行高仍只能靠桌面走查**（接第二十三轮 ③）。
`Table` 的行高与内容无关（系统固定行高），所以①是可信的。

**③ 运行监控字号**（帧 `▸ 运行监控.png` 逐行 ink 实测，与 §7.6 对照）：

| 元素 | 稿 | 应用改前 | 应用改后 |
|---|---|---|---|
| 折线图图例 | `Subheadline`(11)，帧 ink 10.5（y=495.75..505.75） | `caption`(10) | `secondary`(11) |
| 坐标轴标签 | 稿的折线图是 SVG，标签 `font-size 11`；帧 ink 10.5（y=455.75..465.75） | 手挑 `.system(size: 12)` | `secondary`(11)（同时去掉手挑字号，§3） |
| 卡片标题 / 说明 | `Heading / Section`(13) + `Callout`(12)，帧 ink 12.5 | `sectionTitle`(13) ✓ | 不变 |
| 卡片脚 | `listFoot` padY 12 + 次按钮 28 = 52，帧 772..823.75 = 52 | 52 | 不变 ✓ |
| 图表高度 | 帧 plot 225.5（SVG 24→252） | 240（Swift Charts 的 frame 含坐标轴） | 不变 |

§7.6 里「标签 12pt」一句按帧改正为 `Subheadline`(11)。

**④ 记录在案的形态差异**：帧 `workers` 是 Figma 手画的静态表（表头 32 = padY 9 + `Caption/Medium`
13.5；行 39 = padY 11 + `Callout` 17.4），本页按 §7.6「`Table` 呈现 worker 生命周期」用系统
`Table`，行几何随之由系统决定（**表头 28 / 行 24**），比稿紧 4 / 15pt。要逐像素对齐就得把系统
`Table` 换成手搭网格——那与 §7.6 的指定控件和「系统控件优先」冲突，本轮**不改**，仅记录。

**本轮验证**：全量 App 源文件类型检查 **0 error**；`git diff --check` 干净；①的 28/24 与③的帧 ink
均为本轮实测。**未构建、未运行单元测试与 UI 自动化**（后者需当次明确授权）。

#### 第二十五轮：机械项一致性复查（§9 / §6.3 / 结论面板 / 页头）+ 两条量测边界

条带对账做完后，这一轮改成按规范条文做**可机械复核**的检查，结论是这几项都已落地——
没有新增偏差，价值在于把「已符合」变成有记录的实测证据。

| 规范条目 | 检查方式 | 结果 |
|---|---|---|
| §9 动态字体「固定 `height` 全部改 `minHeight`」 | 全仓扫 `.frame(... height:)`（排除 min/ideal/max） | 15 处，逐条分类：图表 2、原生 `Table` 高度 2（共用第二十四轮公式）、分隔线 6（`Layout.compactDividerHeight`）、弹层尺寸 2（音色选择 popover / 设置窗口）、隐藏占位 3（0/1/8pt）。**没有一处文字容器用固定高度** ✓ |
| §6.3 键盘命令 | 扫 `keyboardShortcut` + `App.swift` 的 `Commands` | `⌘N` 新建文稿、`⌘E` 导出作品、`⌘⌥I` 开发者详情、`⌘1–⌘8` 页面、`⌘?` 帮助全部在菜单里；`⌘⏎` 在两颗生成按钮上；`空格` 试听在列表/候选行用 `.onKeyPress(.space)`；菜单栏另补 `⌘O / ⌘N / ⌘, / ⌘Q` ✓ |
| §7.5 结论面板几何 | 4x 帧 `▸ 服务状态.png` 量带高 | 帧 134..217.75 = **83.75**（pad 18 + 图标 26 + 标题/副行）；应用 pad `cardInset`(20) + 图标 26 + `display` 标题 + `callout` 副行 ≈ 85–89，残差 ≤5（标题档位是第十八轮记录在案的 +2）✓ |
| §5.6 页头 | 4x 帧 `▸ 模型.png` 量行盒 | 标题 ink 19.0（`Title / Page` 20 ✓ 与第十八轮八页实测 18.75–19.0 同档）、副行 ink 11.5（`Callout` 12）、两行盒间距 3.1（应用 `micro` 4）、页头末行到首卡 19.8（应用 `gutter` 20）✓ |

**本轮确认的两条量测边界**（写下来是为了以后不再重复试）：

1. **`NSHostingView` 快照也不出图**：把真实视图挂进 `NSHostingView`、`layoutSubtreeIfNeeded()` 后
   用 `bitmapImageRepForCachingDisplay` + `cacheDisplay` 得到的是一张空白（深色底）画布——
   SwiftUI 的绘制列表在无窗口时不刷新。`layer.render(in:)` 同理。**离屏能拿到的只有几何，不是像素**。
2. **`List` 的行矩形读不到**：无窗口时行视图不实例化（内容 90pt 高的行，`rect(ofRow:)` 仍报 24，
   `NSTableRowView` 子视图为空，`tile()` 之后也一样）。所以第二十三轮那三条页面列表行的最终行高
   **只能桌面走查**；而 `Table` 的行高/表头是系统固定值，第二十四轮量到的 28/24 仍然有效。

**本轮验证**：结论面板与页头的帧数据为本轮实测；类型检查与 `git diff --check` 状态同第二十四轮
（本轮无代码改动）。**未构建、未运行单元测试与 UI 自动化**（后者需当次明确授权）。

#### 第二十六轮：模型页动作行的位置 + 诊断详情卡的动作与顺序（对账口径：旧帧 vs 当前脚本）

第八轮把 §7.7 记为「符合」时，只对到条文措辞（「动作是『下载并校验』/『应用此档位』」），
没有对**位置**。本轮按 4x 帧 `▸ 模型.png` 量纵向条带，发现位置与帧不同，已改。

**先交代口径**：`~/Downloads/speechrail-screens-4x/` 的 16 帧导出于 2026-09-15 22:04，第十五轮
已判定它在被第四轮改过的页面上是**旧一代**。所以本轮每一处都拿**当前生成脚本**复核一次：
`figma-kit/main.js:1883-1933`（模型页）与帧完全一致——`profiles` → `actions`（`primaryButton
("下载并校验", "download", 148)` + `secondaryButton("应用此档位")` 无图标 + 右端磁盘）→ `artifacts`，
页面栈 `gap: 20`；诊断页两代不一致（见下表），以脚本为准。

| 条目 | 4x 帧证据（`▸ 模型.png`，1440×900 记） | 改前 | 改后 |
|---|---|---|---|
| 动作行的位置 | 三张档位卡 134.00–299.75 → **动作行 320.00–353.75** → 制品卡顶边 374.00。两张卡之间是一条 74.25pt 的页面底色带，只放一行 34pt 的动作，上 20.25 / 下 20.25 | 动作在 `selectedProfilePanel` 的**最后**（制品卡、未纳入目录、分人资产、操作进度之后），要滚过整张制品表才看得见 | 移到档位卡之后、制品卡之前，落在页面底色上；页面栈间距由 `lg`(24) 改为 `gutter`(20)，上下各 20 与帧一致 |
| 主按钮图标 | 动作行左侧深色按钮：图标是「托盘 + 下箭头」（`tray.and.arrow.down`），后接 5 个字形 | `arrow.down.circle`（圆形箭头） | `tray.and.arrow.down` |
| 次按钮图标 | 同一行右侧浅色按钮宽 **81pt**、高 **30pt**，内部正好 **5 个字形簇**（应用此档位），没有图标 | `Label("应用此档位", systemImage: "checkmark.circle")`（带对勾，且更宽） | 纯文字 `Text("应用此档位")` |
| 「下一步」小标题 | 帧上没有这个标题 | `SectionHeading("下一步", detail: "下载只准备本机资产；应用档位才会改变服务配置。两项动作都会先确认影响。")` | 删除。页头副标题「先下载并校验，再应用到运行档位；两者是独立操作。」已说过同一句话 |
| 就绪结论行 | 帧上没有这一行（帧只有按钮和右端的磁盘事实） | 在动作块内，小标题之下 | 移进 `selectedProfilePanel` 的状态块：档位上下文 → 档位事实 → **就绪结论** → 分隔线 → 制品卡 |
| 操作进度条 | 帧是空闲态，没有进度条 | 在制品卡之后的 `selectedProfilePanel` 底部 | 移到动作行下方（§6.4「长任务进度在触发页内联」）。只在有操作时出现，空闲态与帧一致 |
| 面板内边距 | 面板是卡片 | `Spacing.lg`(24) | `Layout.cardInset`(20)（第二轮卡片内边距标定的统一值） |
| 两个按钮的间距 | 脚本 `frame("actions", { gap: 8 })`；4x 帧在**按钮中线**上量是 8.25（`#2A4E57` 实心块到 408.75、白底描边块从 417.00） | `Spacing.sm`(12) | `Spacing.xs`(8)。顶边附近量会量成 9.75——圆角在 `dy=5` 处每侧内缩约 2.25pt，这一行只有走中线才是真值 |

**一条量测方法上的坑**（记下来避免重复）：整行取样判「这一行是不是卡片」会把动作行判成页面底色——
动作行只占 262–1418 中的一小段 x（按钮 + 右端磁盘文本），逐行主宰色是页面底色。动作行的位置是用
**按 x 分段的填充色**量出来的：一行内出现 `#2A4E57` 实心块 261.00–408.25 与白底描边块 418.50–499.25，
才是这一行有按钮的证据。

**同轮续做：§7.8 诊断详情卡的动作位置与顺序**。这一页同样做了对账，但**先说清用的是哪一代稿**：
`▸ 诊断.png`（2026-09-15 22:04 导出）属于第十五轮判定的**旧一代**，上面写的是「技术上下文」、
「模型校验未完成」、`artifact_key / verify_status`；**当前生成脚本**（`figma-kit/main.js:1979-2090`）
已经按第四轮的决定改成应用的真实文案。所以这一页以**当前脚本**为准，不以那张旧帧为准。

| 条目 | 当前脚本 | 改前 | 改后 |
|---|---|---|---|
| 详情卡的动作 | 结论/影响之后就是 `primaryButton(fix, "打开模型管理", "download", 268)`——详情卡里**唯一**的按钮，整宽（268/300）、图标是托盘 + 下箭头 | 动作沉在卡片底部的「下一步」小节里，而且并排一颗重复的「重新运行诊断」主按钮（§7.8 自己写的是「顶部：复制诊断报告 与 重新运行预检」） | 动作移到结论与影响之后，整宽主按钮，图标改 `tray.and.arrow.down`；删掉「下一步」小标题与那颗重复的主按钮；检查通过时这一格回到「当前项目状态正常。」 |
| 折叠区与步骤的先后 | `开发者详情` 折叠区 → `修复步骤` | 修复步骤在折叠区之前 | 按脚本改成折叠区在前 |
| 重复的一行 | 详情卡里没有「检测结果」，只有折叠区里的 `安全技术结果` | 可见的「检测结果」与折叠区里的「安全技术结果」是**同一句话**（`safeTechnicalResult(for:)` 就是 `resultMessage(for:)`），一屏写两遍 | 删掉可见的那一行，内容留在折叠区 |

**同轮续做：首屏密度**。脚本的详情卡首屏是「胶囊 → 标题 → 一句影响 → 动作 → 分隔线 →
折叠区 → 步骤」，应用比它多三条带标签的事实和一整块「模型证据」（分隔线 + 小标题 + 一句说明
+ 三行事实）。按 §7.6.1 的全局密度约束和「渐进式披露」的约定收了两处，**事实一条没删**：

| 位置 | 改前 | 改后 |
|---|---|---|
| 建议动作 | 首屏上一条独立事实行 | 进 `开发者详情` 折叠区（与下面的编号修复步骤讲同一件事，展开仍能读到全文） |
| 模型证据 | 首屏上一整块：分隔线 + `模型证据` 小标题 + 一句说明 + 受管制品 / 完整性 / 当前服务三行 | 降为折叠区里的「受管制品」「完整性」两行；第三行「当前服务」与折叠区已有的「运行档位」同值，合并；快照未读到时折叠区里写「模型快照：尚未读取，不能在诊断页推断模型存在或使用状态」，不猜 |

**还剩一处，按原样保留**：「这项检查确认」（`explanation(for:)`）仍在首屏——它与左侧列表行的
副标题同源，会重复一次，但它是唯一解释「这一项在确认什么」的人话（检查名本身是
`asr_snapshot` 这类标识），窄窗口下列表行还会截断。要按稿压掉它只需删一行，留给用户定。

**本轮验证**：类型检查（`swiftc -typecheck`，本机 macOS 26 SDK）0 error；`git diff --check` 干净。
模型页的帧数据为本轮实测（按钮中线量距），诊断页的依据取自**当前生成脚本**（旧帧只用来证明
「帧不等于当前稿」）。**未构建**：`xcodebuild -version` 能打印（版本查询不查许可），
`./scripts/macos_app_build.sh --configuration Debug` 仍以 exit 69 报「You have not agreed to the
Xcode license agreements」——本机需要先 `sudo xcodebuild -license accept`。**未运行单元测试与
UI 自动化**、**未桌面走查**——所以两页的最终观感（模型页新位置上的按钮与「磁盘」行是否读起来
是一件事、诊断详情卡现在首屏只有结论/影响/一个动作是否够）仍待人工确认。

#### 第二十七轮：输入卡高度改为「跟随正文」（用户第四度校准 + 离屏实测）

用户 2026-09-16 再次把输入区拎出来：「临时回到大输入 textarea 滚动条问题，修改指令，可接受滚动条，
优先使用原生组件，但大小高度等，需要优化。」第十七轮定下的固定区间 280–360 因此被重新检查，
结论是它只改了上限、没解决「框比文字大得多」这件事。

**先量它到底有多空**（方法：`NSHostingView` 离屏挂载真实页面，不开窗口、不接管前台，遍历内部
`NSScrollView` / `NSTextView` 读几何；文字需求用编辑器自己的 `usedRect`）：

| 场景（1440 × 860 内容区） | 编辑框 | 文字实际高度 | 空白 |
|---|---|---|---|
| 默认 53 字文稿（1 行） | 277pt | 16pt | **261pt** |
| 3 行文稿 | 277pt | 56pt | 221pt |
| 16 行文稿 | 277pt | 316pt | 文字反而超出 39pt（滚动条） |

也就是说固定区间在两个方向都不合适：短文稿是一块白板，长文稿又比文字矮。1440 × 900 的整页渲染
（`cacheDisplay` 逐像素扫描，x = 300pt）证实卡是 85.0 → 284.5pt，即 token 上的 360pt（含页脚）。

**改法**：`SpeechRailComposerTextEditor` 增加 `HeightPolicy`，把「固定区间」和「跟随内容」分成
两种策略，配音台文稿用后者，音色创作描述框仍是前者（它的量测口径与滚动容器都没变）：

- 编辑框目标高度 = 正文高度 + 上下内边距（`Layout.cardInset` × 2）+ 一行余量（20pt），
  再夹到 `[下限, 上限]` 里；换算成**整卡**口径时减掉分隔线与 42pt 页脚带。
- 正文高度用一个隐藏的 `Text` 副本量：同字体（`Typography.body`，随系统字号缩放）、同行距（4）、
  同宽度、`fixedSize(horizontal: false, vertical: true)`（忽略高度提案，测量不与被它决定的高度互相牵动）。
  它只提供一个数值，滚动仍然是原生 `TextEditor` 的行为。
- 20pt 余量是量出来的，不是拍的：隐藏 `Text` 的行距比 `TextEditor` 自己的排版每行少报约 0.5pt
  （8 行 152 vs 156、16 行 306 vs 316），留满一行既吸收这点误差，也让「刚好写完一行」时不会立刻
  冒出滚动条。
- 下限 280 → **200**、上限保持 360；`creatorComposerIdealHeight`（340）随之删除——跟随内容后
  再没有「理想高度」这个中间量。
- 脚本同步：`size(editor, null, 360)` → `200`，注释改成「跟随正文 200–360、画板按最常见的那一档画」，
  `node --check main.js && node build.js` 通过（`code.js` 142928 bytes，
  SHA-256 `94c38b71a2bd998576434d58e15978f6cae730589a72f81b8472c9f8c27073c7`，已落到
  `~/Downloads/SpeechRail-figma-kit/`）。画静态画板只能取一个状态：本页示例文稿在应用里正好
  停在下限，所以画 200。

**改后离屏实测**（同一台机器、同一方法，卡高含页脚与分隔线）：

| 正文 | 卡高 | 编辑框 | doc / clip | 滚动条 |
|---|---|---|---|---|
| 1 行（53 字） | **200**（下限） | 117 | 117 / 117 | 无 |
| 3 行 | **200**（下限） | 117 | 117 / 117 | 无 |
| 8 行 | **255** | 172 | 172 / 172 | 无（余 16pt） |
| 16 行 | **360**（上限） | 277 | 316.5 / 277 | **原生滚动** |

整页渲染（1440 × 900 与 1120 × 720 两档）与上述数字一致：默认文稿下卡是 200pt（改前 360），
1120 × 720 下同样是 200pt，控制条与结果条都还在首屏。同轮的回归渲染确认音色创作页（`.band` 路径）
布局未变：描述字段、引导行、计数行、声学特征 chips、折叠行与主按钮位置与改前一致。

**未做**：不隐藏滚动条、不改 `TextEditor` 的滚动行为、不加动效（长高的那一帧立即生效，避免每输入
一行都触发动画，也避开 Reduce Motion 分支）。**未构建**（Xcode 许可仍未接受，`xcodebuild` exit 69）、
**未运行单元测试与 UI 自动化**、**未桌面走查**——所以「200pt 下限在真实窗口里够不够、每长一行跳一次
20pt 的手感、长文稿时控制条下移是否接受」仍待人工确认；若要再小，改一个 token
（`creatorComposerMinimumHeight`）即可。

**本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error；`git diff --check` 干净。
第十七轮、第二十二轮记录里的「280–360 固定区间」与由此得到的 360pt 实测值均被本轮取代（那两轮
作为当时的证据保留，不再代表当前实现）。

#### 第二十八轮：配音台控制条几何 + 运行监控卡片内边距

本轮把离屏管线从「只量文字框」扩到**能渲染整页并逐像素扫描**：探针用 `NSHostingView` 挂载真实页面、
`host.appearance = .aqua` 强制浅色（与 4x 帧同一外观）、`cacheDisplay` 出像素、按行/列打印颜色连续带；
同时给探针换上与 `App.swift` UI fixture 同值的诊断客户端，服务四页从此能离屏渲染出真实布局
（此前只有加载态）。**仍然不开窗口、不接管前台。**

**控制条**（依据：4x 帧 SVG 矢量尺子 `▸ 配音台.svg` + 生成脚本 `screenDubbing` 的 `composer` 段；
帧坐标减去 240pt 侧栏宽即为应用内容坐标）：

| 元素 | 帧实测 | 应用（改前） | 应用（改后） |
|---|---|---|---|
| 音色胶囊 | x 278.5 → 438.5，**160 × 29** | 206.5 宽（`creatorVoicePickerWidth` = 180 是**标签内宽**，系统次按钮再各加约 13pt） | **160.5**，token 180 → 134 |
| 语速滑块 | 轨道 **132 × 4**（thumb 14） | **748 宽**（`minWidth` + HStack 把滑块拉满整行） | **131.5**，token 120 → 132 且改成定宽 |
| 语速取值 `1.0x` | 紧跟滑块之后（`speedRow` 一行内） | 浮在标签行最右 | 移回控制行，槽宽 `creatorSpeedValueWidth` 32 |
| 快捷档位 | 146 × 28（手画 pill 组） | 系统 segmented 160 × 24 | 不动：§7.1 明确要求用系统 segmented control，尺寸残差按系统控件记录 |
| `⌘⏎` 键帽 + 主按钮 | 31 × 19 / 132 × 34 | 系统控件、内容自撑（约 108 × 36） | 不动：按钮宽度按内容自适应是全局约定（见下） |

改后同一行像素扫描（1440 × 900，内容坐标）：胶囊 36.5 → 197（160.5）、滑块 214.5 → 346（131.5）、
取值紧随其后、segmented 422 → 582、主按钮右对齐到卡内边距——与帧同构（帧的滑块 219 → 351、
segmented 392.5 → 538.5，差值来自应用多一个 `Stepper` 与系统 segmented 的固有宽度）。

**两条记录在案的偏离**（都不是疏漏，而是规范与稿的分工）：

1. **`Stepper`**：帧里没有画，§7.1 要求「`Slider` + `Stepper`（步长 0.1）」。保留 Stepper；
   它也正是滑块收到 132pt 后仍能精确调值的配套控件。
2. **按钮宽度**：帧给每颗按钮写死宽度（132 / 148 / 83 / 168 / 118 …），应用一律按内容自撑
   （只钉 `controlSize` 决定高度：主按钮 36 vs 稿 34、次按钮 28 vs 稿 30）。按内容自撑是刻意选择：
   写死宽度在动态字号和文案变化下会截断或留空。这一条覆盖全 App，不只配音台。

**运行监控 · 图表卡内边距**：稿的 `card()` 默认 `pad: 18`，应用统一到 `Layout.cardInset`(20) 那一档
（§5.6），但这张卡此前是 `Spacing.md`(16)——同一页的卡片留着两套内边距。已改
`chartPanel` 与相邻的「逐指标明细」卡为 `Layout.cardInset`。同轮复核了两处此前存疑的结构：
**图表卡表头与图之间确实没有分隔线**（脚本 `card(d, "chart", …)` 只有 head + lineChart + legend，
应用的 `SectionHeading` 也不画线）✓；**「运行组件」卡是 `CardHead` + `Divider` + 表 + `Divider` + `CardFoot`**，
与脚本的 `workers` 卡（`tabs` 头 + hairline + 行 + 脚）一致 ✓。

**仍未对齐的一处（第五十九轮已裁决：维持规范，见 §12.4 决定 13）**：生成结果条的底色。稿把 `resultBar` 画成 `surface/railTint`
（#DCE9EE，带 1pt rail 描边），§5.2 / §5 表面层级表写的是「浮起层用系统材质或 `glassEffect`」，
应用按规范用了 `.elevated`（`.regularMaterial` + 阴影）。规范与稿在这里直接冲突，本轮**以规范为准**
（稿本身是这套脚本生成的，脚本这一处没有兑现它自己的规范），没有改代码。

**本轮验证**：`swiftc -typecheck` 0 error、`git diff --check` 干净；浅色离屏渲染 + 像素扫描见上表。
同轮把静态自检收进仓库：`figma-kit/audit.js`（`node audit.js`，不需要打开 Figma）实跑结果
**颜色变量 23/23、图标 24/30、文本样式 9/9 全部解析，数字 token 按字面量写、无可解析引用**，
只有 6 个未用图标（pause / refresh-cw / trash-2 / pencil / copy / x）作为信息项列出，结论 `audit: clean`。
它检查的是「改动 kit 时有没有留下悬空引用」，与插件在 Figma 里跑的运行时 audit 互补。
**未构建**（Xcode 许可仍未接受）、**未运行单元测试与 UI 自动化**、**未桌面走查**——控制条的新构图
在真实窗口里的手感（132pt 滑块是否够用）属于走查项。

#### 第二十九轮：输入卡高度策略的复核（不改代码）

用户第四度校准的那句（「可接受滚动条、优先原生组件、只优化大小高度」）在第二十七轮已经落地；
本轮不再改策略，只把「跟随内容」的**量测是否可信**查到底，因为整条路都压在一个隐藏 `Text` 镜像上。

**方法**：另起一个最小探针（`NSHostingView` 离屏挂载，`CFRunLoopRunInMode` 跑多轮布局让 `@State` 收敛），
把镜像报的高度与编辑器自己的 `usedRect` 并排量；再把真实页面的示例文稿换成 8 行长稿复测。
**不开窗口、不接管前台、不点击。**

| 正文 | 镜像报的高 | 编辑器需要的高 | 整卡 | doc / clip |
|---|---|---|---|---|
| 1 行（22 字） | 16 | 16 | 200（下限） | 117 / 117，无滚动 |
| 3 行 | 55 | 56 | 200（下限） | 117 / 117，无滚动 |
| 8 行 | 152 | 156 | 255 | 172 / 172，无滚动 |
| 16 行 | 306 | 316 | 360（上限） | 316.5 / 277 → **原生滚动** |

镜像与编辑器每行差 0.5pt（8 行 4pt、16 行 10pt），与第二十七轮的结论一致，20pt 余量覆盖得住；
同一组数字在 1400 / 1080 两个组件宽度下完全一致（1080 宽时编辑器文字宽 1040、镜像文字宽 1040），
说明镜像与实际排版用的是同一个宽度、换行结果相同。真实页面上换成 8 行长稿复测：卡片 255pt、
编辑器 172pt、`doc == clip`，1440 × 900 与 1120 × 720 两档都一样。

**观察到一次瞬态，不修**：真实页面第一轮布局时 SwiftUI 先提出 272pt 的宽度，镜像随之报 615pt，
随后收到真实宽度（1400 / 1080）后回到 152pt。同一次布局里**面板自己的宽度也是先 272 再到位**，
所以这不是量测 bug，而是首轮提案；加「宽度过滤」也拦不住（那一刻宽度真的就是 272）。
最终值在渲染前已经收敛，本轮实测的取图与走查所见都是收敛后的状态。

**结论**：`.contentDriven` 的高度阶梯与 §7.1 / §11.6 第二十七轮的记录一致，代码不变。
**未构建**（Xcode 许可仍未接受）、**未运行单元测试与 UI 自动化**、**未桌面走查**。

#### 第三十轮：页头副标题把整页最小高度撑到声明的最小窗口之上（真修复）

上一轮把探针扩到整页渲染后，在 1120 × 720（应用声明的最小窗口）的配音台渲染里发现页头被裁：
标题只剩底部 4pt，副标题、正文卡与控制条整体上移 40pt。本轮查清并修好。

**先量「页面内容的最小高度」**：`.inspector` 在离屏宿主里会生成一个 `SystemSplitView`，它的高度就是
SwiftUI 认定的页面最小高度；宿主比它矮时内容按底对齐、顶部被裁（位移 = 最小高度 − 宿主高度，
1440 × 720 实测 760 − 720 = 40 ✓，700 时 60 ✓）。逐页读出这个下限：

| 页面 | 修前最小高度 | 修后 | 页面结构 |
|---|---|---|---|
| 配音台 | **760** | 475 | 不可滚动页 |
| 我的作品 | **889** | 529 | 不可滚动页 |
| 诊断 | 664 | 454 | 不可滚动页 |
| 音色库 | 394 | ≤ 200 | 不可滚动页（`List` 自身可滚） |
| 音色创作 / 运行监控 / 模型 | ≤ 200 | ≤ 200 | 外层本来就是 `ScrollView` |

声明的最小窗口高是 **720**，所以前两页在最小窗口下根本放不下。

**根因**：`PageScaffold` 页头副标题上的 `.fixedSize(horizontal: false, vertical: true)`。
它在**未定宽度提案**（计算最小尺寸时就是这种提案）下按极窄宽度测量，一句 20–30 字的说明会换行成
十几二十行、报出三百多点的理想高度；这个高度又成为 `SystemSplitView` 的下限。逐项拆解验证：
把页面正文换成空 `VStack`（只留页头）时下限仍是 **379**（可见页头只有约 62pt）；把该 `fixedSize`
去掉，空页立刻回到宿主下限。

**修法**：那一行加 `.lineLimit(2)`，保留 `fixedSize`——最多两行，常见副标题（最长 26 字 ≈ 312pt）
在 1120 宽窗口下仍是一行，不产生截断；同时最小高度被真正约束住。

**验证**（离屏 `NSHostingView` + `cacheDisplay` 逐像素墨迹区间，浅色外观，不开窗口、不接管前台）：

1. 七个页面在 **1440 × 900** 与 **1120 × 900** 下，修前修后的墨迹区间**完全一致**（配音台
   `22.5–43.5 / 51.5–64.0 / 85.0–284.5 / 305.0–374.5` 等），即正常尺寸下没有任何观感变化。
2. **1120 × 720** 与 **1440 × 720** 下，修后不再有页面被裁；配音台标题回到与 900 高时相同的
   `22.5–43.5`。
3. 探针新增越界告警（内容最小高度 > 宿主高度时打印），七个页面在 720 与 620 两档都不再触发。

**未验证**：真机上的实际表现——SwiftUI 把内容最小尺寸报给窗口时，AppKit 是「抬高窗口最小高度」
还是「照旧裁切」，离屏渲染分不出来。两种情形下这一处都必须修（前者说明声明的 720 最小高度是假的，
后者是页头直接看不见），但**结论以桌面走查为准**。**未构建**（Xcode 许可仍未接受）、
**未运行单元测试与 UI 自动化**、**未桌面走查**。

**本轮验证**：`swiftc -typecheck` 0 error、`git diff --check` 干净。

#### 第三十一轮：深色外观的离屏取证（不改代码）

本机 GUI 外观是 **Dark**，而此前所有离屏取图都显式用浅色（`.aqua`），深色只做过代码层收口。
本轮把深色也渲出来量（`NSHostingView.appearance = .darkAqua` **并且**设进程级
`NSApplication.shared.appearance`，因为 `List` / `Stepper` / 分段控件这些 AppKit 控件走进程外观）。

**代码层（grep 全量）**：App 里没有任何字面量颜色——没有 `Color(red:green:blue:)`、`Color(white:)`、
`.black` / `.white`（除一处窗口阴影的 `Color.black.opacity(0.18)`）；颜色要么走 AppKit 语义色
（`labelColor` / `windowBackgroundColor` / `controlBackgroundColor` / `textBackgroundColor` /
`separatorColor` / 系统状态色），要么走唯一一个自带 light / dark / Increase Contrast 四档的动态色
`VoiceAccent`。也就是说深色在结构上不需要额外分支。

**离屏实测**（1440 × 900，七个页面）：

| 检查 | 结果 |
|---|---|
| 卡片 / 输入卡 / 图表卡填充（应用自绘表面） | 深色 **#171717**、浅色 **#FFFFFF**，随外观翻转 ✓ |
| 正文与标签 | 深色下浅字（`labelColor` 在深色为浅色）✓ |
| 纯白不透明像素占比（应用内容区） | 我的作品内容区 0.09%、配音台 0.86%（都是字形抗锯齿与系统控件描边）✓ |
| 布局 | 深色与浅色的墨迹区间一致，颜色变化不影响几何 ✓ |

**探针边界（不是应用缺陷，但会误导读数）**：无窗口宿主不画窗口 chrome——
① 顶部 55pt 的工具栏带整体是纯白；② 右侧 `.inspector` 面板（我的作品 / 音色库，实测 x 1170–1440）
也是纯白，而且面板宽度给到 270pt（应用声明的最小是 300、理想 360），说明分栏位置在这个宿主里也不作数。
所以深色下能作数的只有**应用自绘的表面**（卡片、输入区、控制条、图表卡、列表卡内部），
工具栏与 Inspector 面板的深色表现要留给桌面走查。这与第二十三、二十五轮记的
「`List` 行高在无窗口环境不成立」是同一类边界。

**未验证**：真机深色下的工具栏、Inspector 面板与系统控件外观；Increase Contrast 同样未实测。
**未构建**（Xcode 许可仍未接受）、**未运行单元测试与 UI 自动化**、**未桌面走查**。

**本轮验证**：`swiftc -typecheck` 0 error、`git diff --check` 干净（本轮无代码改动）。

#### 第三十二轮：输入卡静止高度再收一档（用户第五度校准）

用户 2026-09-16 又一次把输入区拎出来，并把指令本身改了：「临时回到大输入 textarea 滚动条问题，
修改指令，可接受滚动条，优先使用原生组件，但大小高度等，需要优化。」——**滚动条那一条被撤回**，
「优先原生」「大小高度要优化」两条留下。第二十七轮定下的策略因此逐条复核：

- **组件仍是原生的**：正文就是一个 `TextEditor`，滚动、滚动条、焦点环、文本背景全部由系统给；
  隐藏的 `Text` 副本只产出**一个高度数值**（`onGeometryChange`），不接管滚动、不做自绘。
- **滚动条不再需要被避免**：超出上限就是原生滚动条（第二十七轮已经这么做，没有回退）。
- **大小高度要优化** —— 本轮改的就是这一条。量出来的是：卡里的固定开销是
  **83pt**（上下内边距 `cardInset` 40 + 分隔线 1 + 页脚带 42），下限 200pt 里只剩 **117pt**
  给正文，而示例文稿一行只有 16pt——静止状态下一行字下面空着约 100pt（≈5 行）。

**改法**：下限 `Layout.creatorComposerMinimumHeight` 由 200 收到 **160pt**（正文区 77pt ≈ 4 行），
上限 360pt 与「跟随正文」的规则都不动。下限的职责本来就只是「短文稿也给一块写作区」，
不是「给一块比正文大好几倍的空白」。

**离屏实测**（`/tmp/sr-dub` 探针，`NSHostingView` + `CFRunLoopRunInMode` 多轮收敛，宽 1400，
不开窗口、不接管前台；卡高 = 正文 + 分隔线 + 42pt 页脚带）：

| 正文 | 卡高（改前 → 改后） | 正文区（改前 → 改后） | 滚动 |
|---|---|---|---|
| 1 行（22 字） | 200 → **160** | 117 → **77** | 无（16 ≪ 77） |
| 3 行 | 200 → **160** | 117 → **77** | 无（56 < 77） |
| 8 行 | 255 → 255 | 172 → 172 | 无 |
| 16 行 | 360 → 360 | 277 → 277 | **原生滚动**（doc 316.5 > clip 277） |

也就是：**只有静止（短文稿）这一档变了，长文稿那一侧完全不动**——8 行、16 行的卡高由正文自身
高度决定，与下限无关。整页渲染（浅色、1440 × 900 与 1120 × 720）里 TextEditor 的滚动视图高度
两档都是 **77pt**（改前 117），配音台页其他部分（页头、控制条、结果条占位）位置不受影响。

**脚本同步**：`size(editor, null, 200)` → `160`（画板只画得到一种状态，取最常见的静止那一档），
`node --check main.js && node build.js` 通过，`code.js` 142938 bytes，
SHA-256 `69b9b6b744a70cc470e4c4d3bc35d552a9c9c88a6b6308233a4fabba66329149`，
已落到 `~/Downloads/SpeechRail-figma-kit/`；`node audit.js` 仍为 `audit: clean`
（颜色 23/23、图标 24/30、文本样式 9/9）。

**考虑过、没有采用的写法**：把 `TextEditor` 换成 `TextField(..., axis: .vertical)` +
`.lineLimit(3...12)`，那是 SwiftUI 自带的自增长多行输入，能省掉隐藏 `Text` 副本。不采用的理由是
语义与行为都不对：它是**单行文本字段**语义（无文档语义、无 `TextKit` 的段落与选区行为），
4096 字文稿 + 中文输入法组合下的表现没有依据，而且到达行数上限之后是「怎么滚」也没有文档化契约；
现在的做法保住了系统的文档编辑器与系统滚动视图，只用一个数值决定框多高。

**已知取舍（写给走查）**：配音台页面是顶部对齐的（页头 / 输入卡 / 控制条 / 结果条依次排），
输入卡变矮以后，页面下方的窗口底色留白会比改前更多；稿本身是「输入卡占满剩余高度」，
所以这一点与稿不一致——它属于用户历次校准里明确要偏离的那一类（§12.4 记录）。
要往回加只需调高 `creatorComposerMinimumHeight` 一个值（200 / 240 / 280 都可直接改）。

**未验证**：真实窗口里的手感（一行文稿时 77pt 正文区够不够写、输入到第 4 行时卡开始长高是否察觉）
属于桌面走查项。**未构建**（Xcode 许可仍未接受，`xcodebuild -checkFirstLaunchStatus` = 69）、
**未运行单元测试与 UI 自动化**、**未桌面走查**。

**本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error、`git diff --check` 干净。

#### 第三十三轮：设置窗口与菜单行几何（帧里「不在主窗口」的两个界面）

§11.2 早就把「设置 640 宽撑高、菜单面板 288 宽」写成帧尺寸，但应用从未按它量过。上一轮之后，
这一段是「帧 ↔ 脚本 ↔ 应用」里唯一还没逐项对齐的界面。本轮先弄清前提，再改两处。

**① 前提：菜单栏面板是系统菜单。** `App.swift` 的 `MenuBarExtra` 没有 `.menuBarExtraStyle`，
即默认 `.menu`——面板由系统画；UI 测试也是按 `app.menuItems["打开 SpeechRail"]` 断言的
（`.window` 样式下这些行会是按钮，不是 menu item）。所以稿里 `menuPanel` 的 288 宽、5pt 内边距、
圆角 12、描边、行内 `padX 12` 是这类面板的**示意图**，不是可逐像素复现的目标；应用能控的是
行内容与行的下限高度。本轮据此只改一处：`Menu.rowHeight` **44 → 26**（稿 `menuRow`；离屏实测
行标签固有高度 288 × 44 → 288 × 26，系统菜单再叠自己的 padding）。44 来自
`Interaction.minimumHitTarget`，套到菜单行上会让菜单栏面板与**每个页面的工具栏动作菜单**
都变成两倍高的列表行；菜单项的整行本来就是可点区域，命中区没有因此变小。

**② 设置窗口尺寸（离屏实测）。** 探针给副本只加了一个初始 selection（不改布局），逐页量
`NSHostingView.fittingSize`，宿主 640 × 900、不开窗口、不接管前台：

| 页签 | 改前 | 自然高 | 改后 |
|---|---|---|---|
| 通用 | 560 × 360（被下限夹住） | 319 | 640 × **454** |
| 创作 | 560 × 360（被下限夹住） | 更矮 | 640 × **454** |
| 服务 | 560 × **454**（自然高，最矮不了） | 454 | 640 × **454** |

改法：`settingsWindowMinimumWidth` 560 → **640**（§11.2 与稿一致）；`settingsWindowMinimumHeight`
360 → **454**（三页里最高的一页，切页签窗口不跳——稿也是这样把三个窗口拉平的）；表单内边距
`Spacing.lg`(24) → `Spacing.md`(16)（稿 `content` 的 `pad: 16`，行卡随之为 608，稿 604，残差 4）。

**③ 设置行的结构（改后逐页渲了图）。** 稿的 `controlRow` 把说明写成**行内副标题**（`labels` 列：
`Body` 标题 + `gap: 3` + `Caption` 说明），应用此前把说明写成同一 `Section` 里的独立 `Text`——
grouped `Form` 会给它单独一行并画分隔线。改前的离屏渲染证实了这一点：「启动时读取服务状态」
与「控制台仍可在任意页面手动刷新。」之间有一条分隔线，读起来像两个设置项。改后说明收进同一行的
自定义标签（仍是系统的 `Toggle` / `Picker` / `LabeledContent`），并补上稿有、应用漏掉的一行说明：
「默认语速」的「0.5×–2.0×，可在配音台逐条覆盖。」。新增 token
`Settings.rowLabelSpacing`(3)（稿 `controlRow/labels` 的 gap）。

**验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error；三个页签各出一张离屏渲染图
（640 × 454、行内副标题、无多余分隔线）；`git diff --check` 干净。

**未验证**：真实窗口的观感——系统标题栏高度与 `TabView` 页签条位置随 macOS 版本不同；菜单行
26pt 在真实 `NSMenu` 里的最终行高（系统还会加自己的 padding）、以及面板是否仍按 288 宽渲染，
都只能在构建后走查确认（§12.4）。**未构建**（Xcode 许可未接受）、**未运行单元测试与 UI 自动化**、
**未桌面走查**。

#### 第三十四轮：输入卡下限复核 + 声学特征芯片（灰胶囊 → 稿的琥珀标注）

**① 输入卡（第三十二轮）复核。** 用户第五度校准「可接受滚动条、优先原生组件，但大小高度仍需优化」
之后，本轮用同一套离屏量测重跑了一遍静止高度与滚动行为，结论与第三十二轮一致，没有新改动：
1440 × 900 下 1 行 / 3 行文稿卡高 **160**（正文区 77pt ≈ 4 行，`doc = clip`，**无滚动条**）、
8 行 **255**、16 行触到上限 **360**（`doc 316.5 > clip 277`，出现原生滚动条）；1120 × 720 与
深浅两种外观下卡高、分隔线、页脚带位置一致。音色创作的描述框（`.band`，滚动容器取 `ideal`）
正文区 101pt ≈ 稿的可写区 102.5pt，`doc = clip` 同样**没有默认滚动条**。两处都仍是原生
`TextEditor`（滚动条、焦点环、文本背景全由系统给），应用只在卡片一级约束高度。

**② 声学特征芯片。** 稿与应用的差异比间距大得多：稿是**琥珀底 + 琥珀描边的标注胶囊**，
应用此前是**灰底、无描边**——在浅色页面里读起来像「禁用 / 占位」控件，语义完全不同
（§7 早就写着「chips 使用系统胶囊样式 + 琥珀语义色」，一直没落地）。口径：`figma-kit/main.js`
是当前一代（`componentSet("Voice Chip", …)`：`gap 4 / padX 10 / padY 3 / radius 999`、
`surface/attentionTint` 底、1pt `accent/voice` 描边、`Subheadline` 标签），
`▸ 音色创作.svg` 作矢量尺子（chip rect 82 × 22 @ 281,344；plus 线长 7.58 + 1.08 描边
= 墨迹 8.66，即 13pt 的 lucide 图标框）。

| 项 | 稿 | 应用（改前） | 改后（离屏实测） |
|---|---|---|---|
| 填充 | `surface/attentionTint` `#FBEEDA` / `#3D2F16` | `quaternaryLabelColor` × 0.6 → `#F0F0F0` | `#FBEEDA` / `#3D2F16`（逐位相同） |
| 描边 | 1pt `accent/voice` `#D97706` / `#F59E0B` | 无 | 1pt `#D97706` / `#F59E0B`（逐位相同） |
| 高 | 22 | 21 | **22.0** |
| 宽（四字标签） | 82 | 85 | **81.0**（残差 1） |
| 同排间距 | 6（脚本 `chips` 容器；帧实测 7） | 8 | **6** |
| 标签 | `Subheadline` | `Caption`(10) | `subheadline`，墨迹宽 40.0 = 帧的 40.0 |
| 加号 | 13pt 框 / 墨迹 8.66 | `technical`（caption2） | 框 13pt（钉住，胶囊总宽才等于稿）/ 墨迹 8.0 |

新增 token：`Chip`（`iconSize` 10 / `iconBox` 13 / `labelSpacing` 4 / `insetX` 10 /
`insetY` 3 / `height` 22 / `spacing` 6 / `borderWidth` 1）与 `Surface.attentionTint`
（脚本色板 `#FBEEDA` / `#3D2F16`；Increase Contrast 下底色保持稿值，对比由 1pt 描边与
`Color.voice` 的 HC 变体承担）。`SpeechRailChipModifier` 现在画「填充 + `strokeBorder`」，
22pt 是**含描边**的高度，与帧的 22–23pt 墨迹一致。调用点仍只有音色创作一处
（`rtk rg speechRailKnurledCapsule` 复核）。

**量测口径（后续取色值一律照此）**：离屏 PNG 带 `Generic RGB Profile`，直接采样得到的是
宽色域数值（同一颗琥珀会被读成 `#FAEAD1` / `#CE630B`，看起来像「颜色不对」）；
先用 `sips --matchTo "/System/Library/ColorSync/Profiles/sRGB Profile.icc"` 转一次，
采样才与稿的 `#FBEEDA` / `#D97706` 逐位相等。灰色（R=G=B）不受影响，所以此前用灰色
采样做比对没有暴露这个偏差。

**验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error；1440 × 900 浅色与深色
各出一张离屏渲染图并逐像素扫描（chip 高 22.0、宽 81.0、间距 6、fill/stroke 精确）；
`git diff --check` 干净。**未构建**（Xcode 许可未接受）、**未运行单元测试与 UI 自动化**、
**未桌面走查**：芯片的悬停 / 指针手型 / 键盘焦点与 VoiceOver 顺序都只在代码层确认。

#### 第三十五轮：作品列头带高 + 一条不依赖 Xcode 许可的预览构建

**① 作品列头的带高。** 稿 `cols` 是 `padX 16 / padY 10` + `Caption / Medium`（10pt，行高 13.5）
= 33.5，4x 帧实测 33.75（`▸ 我的作品.png` y=181..214.75）。第二十三轮为了让列头与下方行
「同为 padY 12 的节奏」取了 4pt 节奏里的 `sm`(12)，带高因此是 12 + 13 + 12 = **37**（高 3.25），
而列头并不是列表行（行是 padY 12 + 两行内容 = 64，列头只有一行）。本轮直接取稿的 **10**：
10 + 13 + 10 = **33**（残差 0.75）——`Settings.rowLabelSpacing`(3) 已是「稿的非 4 倍数值直接用」
的先例。改法是把 12 换成视图内的 `columnsHeaderVerticalPadding`(10)，不改共享 `Spacing`。
离屏 A/B：300–700pt 空档里的分隔线由 y=158 上移到 **y=154**（上下各收 2pt），与预测一致。

**② 记一条「规范 ↔ 稿」的正面冲突（不改代码）。** 配音台的生成结果条：稿的
`resultBar`（`main.js` 1367–1370 与 4x 帧 `▸ 配音台.svg` 第 129–130 行）画的是
`fill: surface/railTint`（`#DCE9EE`）+ 1pt `#2A4E57` 描边 + radius 11.5；应用用的是
`.speechRailSurface(.elevated)`（`.regularMaterial` + 窗口级阴影）。**这一处不是漏做，
而是规范点名要求的一处**：§5.2 的「浮起层」一行写的正是「仅窗口级浮层（浮动的播放/
生成结果条）使用系统材质或 `glassEffect`」，同节「不再使用」列还列了「自绘渐变 + 0.5px 描边」；
§5.4 也把强调色定为跟随系统的 `AccentColor`（`#2A4E57` 这个写死值已在 §12.4 决定 4 里退役）。
所以应用按规范走，稿的这一条属于旧一代视觉语言；要按稿改，等于把 §5.2 / §5.4 一起回退。
**第五十九轮结案：维持规范（现状）**，要么维持规范、要么改规范 §5.2 的那个岔口已按 §12.4
决定 13 的三条依据选定——稿那一代取值会用 ≤6/255 的色差换掉系统自适应。

**③ 预览构建（走查用，不是发布件）。** 已安装的 `~/Applications/SpeechRail.app` 停在
2026-09-15 21:32，看不到本会话任何改动，而 `xcodebuild` / `swift build` / Xcode 内那份 `otool`
现在一律返回「未同意 Xcode 许可」。本轮查明根因：**`/Applications/Xcode.app` 在 2026-09-16 00:51
被换成 Xcode 27.0（27A266a），而 `/Library/Preferences/com.apple.dt.Xcode.plist` 里记录的同意
只覆盖 26.6**（`IDEXcodeVersionForAgreedToGMLicense = 26.6`），所以这是换版本触发的重新同意，
不是许可从未接受过。

`swiftc`（`Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc`）不查许可；本会话又只改了 App 侧
源码（`SpeechRailControlKit` / `SpeechRailControlAgentCore` / `SpeechRailControlAgent` 自 HEAD
未动）。因此可以只重编译 App 可执行文件：按 `Config/Debug.xcconfig` 的
`-target arm64-apple-macos26.0 -swift-version 6 -D DEBUG` 编译，链接按仓库源码自建的
`SpeechRailControlKit`（**install name 写成包内 framework 的那一条**
`@rpath/SpeechRailControlKit.framework/Versions/A/SpeechRailControlKit`），再把
`~/Applications/SpeechRail.app` 复制一份、
替换 `Contents/MacOS/SpeechRail`、`codesign --force --sign -` 重新 ad-hoc 签名（与已安装件同为
adhoc、无沙箱、`ENABLE_HARDENED_RUNTIME = NO`、entitlements 为空）。

产物 `/tmp/sr-appbuild/SpeechRail.app`：`codesign --verify --deep --strict` 通过，
`otool -L` 与参照件一致（`@rpath/SpeechRailControlKit.framework/…` + rpath
`@executable_path/../Frameworks`），Info.plist、两个 framework、XPC 服务与 `Assets.car` 都是原样复制。
**它不是发布件**，也不覆盖已安装的 App；用途只是让人能看到当前工作树的界面。两条已知边界：
（a）应用二进制由 Xcode 27 的 Swift 编译、包内 framework 由 Xcode 26.6 编译，靠 Swift 6 的稳定
ABI 兼容（未做真机启动验证）；（b）`ControlAgentRegistration.ensureRegisteredForCurrentBundle()`
只做守卫、不会自动注册 LaunchAgent，所以从 `/tmp` 运行不会改写用户的登录项——但**「运行」本身
会接管前台窗口，属于 AGENTS.md 里需要当次授权的动作，本轮没有启动过它**。

#### 第三十六轮：全量文案核对（稿上的每一句界面文案 vs 应用）

**方法**：把 `figma-kit/main.js` 里所有 `text(id, "…")` 与按钮 / 分段 / 搜索 / 页头辅助函数的
字符串抽出来（101 + 32 条），逐条在 App 源码里查找。找不到的再人工分类——绝大多数落在两类：
**画板自身的样张内容**（「星际航行 · 夜航主持」「8 个作品 · 共 11:05」「seed 101」
「检查标识 diarization_aligner_snapshot」「磁盘：模型已用 6.4 GB · 可用 182 GB」）与
**三个非应用页面**（`03 Flows`、`05 Menu & Settings` 的画板标题、`Foundations`、`Archive`）的文案
（「Colour」「迁移前 · 机加工机架」「菜单栏状态项」「设置 · 通用」）。这两类不构成差异。

真正属于界面、却在应用里对不上的有三处，本轮改掉：

| 位置 | 稿 | 应用（改前） | 处置 |
|---|---|---|---|
| 侧栏搜索占位符 | 「搜索」（4x 帧 `▸ 配音台.png` 侧栏顶部就是这两个字） | 「搜索创作和服务」 | 改成稿的「搜索」 |
| 运行监控 · 运行组件说明带（`main.js` 1837） | 「worker 生命周期状态；ASR、双 TTS lane 与分人各自独立常驻。」 | 「指标为最近样本的平均值；…」 | 改回稿的句子——那张卡的表列就是「组件 / 状态」，原句讲的是上面的窗口指标 |
| 配音失败条标题（`main.js` 912） | 「生成未完成：服务端没有返回音频」 | 「配音未完成」 | 标题取稿的前半句「生成未完成」；原因仍由服务端的真实文案单独成行（稿的示例句不能钉死） |

三处都不属于「应用更准确、必须保留」那一类偏离（对比：作品行副标题不写「24-bit 44.1 kHz」，
那条是服务契约不支持），也没有在任何文档里记过，所以按稿改。另外核对了两处**看起来像差异、
其实是动态拼接**的：运行监控页头副标题 = `最近 N 个样本` + 「· 刷新间隔 5 秒」，等于稿的
「最近 60 个样本 · 刷新间隔 5 秒」；我的作品的空态标题/说明与稿 `Empty State` 的
`Kind=NoData` 变体逐字一致（搜索无结果另有「没有匹配的作品」那条）。

**验证**：`swiftc -typecheck`（macOS 26 SDK）0 error；`git diff --check` 干净；三处改动先做源码级
前后 grep 核对，再把运行监控整页**离屏渲染**（1440 × 2400，`/tmp/sr-dub/probe.new --render --light
--top --monitoring`）后按像素读回说明带，确认画面上就是
「worker 生命周期状态；ASR、双 TTS lane 与分人各自独立常驻。」——离屏渲染确实能核文案
（本节此前写的「离屏渲染看不出旧文案」只对旧结论成立：那时探针没渲这一类卡片文本）。
**未构建、未运行单元测试与 UI 自动化、未桌面走查。**

#### 第三十七轮：深色 / 高对比 / 动态字号的离屏取证，加 token 合规扫描

**探针修正（先说一个会读错图的陷阱）**：`cacheDisplay` 出来的 PNG 里，**页面没画到的区域是透明的**
（那一层真机由 `NSWindow` 提供）。浅色下透明被看图器当白底，看不出问题；深色下它会读成
「卡片是黑的、页面是白的」，从而误判成深色漏底。探针现在先把结果合成到当前外观的
`NSColor.windowBackgroundColor` 再落盘。实测：深色页面底 **#1E1E1E**、输入卡 **#171717**，
与真机窗口层次一致；浅色页面底仍为白。第三十一轮对**自绘表面**的读数（深色 #171717）
因此不变，本轮补上的是页面底与一个量测口径。

**新增两个开关**：`--contrast` 与 `--type <size>`（动态字号）。其中 **`--contrast` 在本机不能作为
Increase Contrast 的证据**，原因写在下一节——留着它只是为了别再重新踩一遍。

**Increase Contrast 在离屏环境里测不了（本轮实测，结论是否定的）**：
① Swift 常量 `.accessibilityHighContrastAqua` 的 rawValue 是 `NSAppearanceNameAccessibilityAqua`
（少了 `HighContrast`），`NSAppearance(named:)` 找不到它，**静默回退成普通 Aqua**——
用常量写的「高对比渲染」其实验的是普通外观，等于没验（探针 `/tmp/sr-dub/appearances.swift`）。
② 系统的外观资源已经改名：`SystemAppearance.bundle` 里是 `AquaAX.car` / `DarkAquaAX.car`，
没有 `AccessibilityHighContrast*`；用旧名构造出来的外观把语义色解成**浅色**
（`windowBackgroundColor=#ECECEC`、`labelColor=black`、`separatorColor@0.10`），
而同一轮渲染里 SwiftUI 自己的解析又给浅底配了浅字——这是**不一致的混合体**，
不对应真机任何一种外观。③ 用 `bestMatch(from:)` 判别这些名字会直接把探针进程打崩（139）。
所以：本轮的 `hc-*.png` **不作为证据**，Increase Contrast 仍是**真机走查**项；
应用侧没有可查代码（§5.4/§9 把对比度交给系统语义色与材质）。

**全页深色扫查**（1440 × 900，八页：配音台 / 音色创作 / 音色库 / 我的作品 / 服务状态 / 运行监控 /
模型 / 诊断）：没有发现写死浅色导致的漏底、反色或读不清的文字；语速滑杆、分段控件、弹窗按钮等
原生控件都按系统深色呈现。**口径提醒**：卡片表面走系统材质，材质要对背景取样，无窗口环境里的
解析值不等于真机，所以本轮的深色结论限于**结构、文字与原生控件**，材质观感仍归真机走查。

**token 合规扫描**（`rg` 全仓 App 源码）：没有 `Color(red:…)` / `#colorLiteral` /
`NSColor(calibratedRed:…)` 一类写死颜色。命中的只有两处：
`SpeechRailDesignTokens.swift` 浮起层阴影的 `Color.black.opacity(0.18)`，以及
`WorkspaceComponents.swift` 里 `StatusTone.color` 用的 `Color.green / .orange / .red / .secondary`。

**`StatusTone` 是否偏差：不是（本轮实测）**。把它与 §5.4 要求的系统语义色在四种外观下逐字节比对
（探针 `/tmp/sr-dub/tones.swift`）：浅色 `#34C759 / #FF8D28 / #FF383C`、深色
`#30D158 / #FF9230 / #FF4245`，`Color.green/.orange/.red` 与 `NSColor.systemGreen/.systemOrange/
.systemRed` **完全相同**（两个 Increase Contrast 外观也相同）。**不改**。

**阴影没有稿面对应值**：稿里唯一的阴影是 `elevate()`（`a=0.07 / y=1 / r=4`），它只用在 `menuPanel`
——那是系统菜单，阴影由系统画；`card(..., elevated: true)` 这个分支在稿里从未被调用。
所以应用「浮起层」的阴影属 §5.2 允许的自定实现，本轮不改（结果条本身的填充冲突第五十九轮已裁决，见 §12.4 决定 13）。

**动态字号在 macOS 上的边界（实测，会改 §9 的验收方式）**：`.dynamicTypeSize(_:)` 对 macOS 的
SwiftUI 系统文本样式**不生效**——同一段文字在 `large / xxLarge / accessibility3 / accessibility5`
下，`fittingSize` 与 `cacheDisplay` 的墨迹高度逐像素相同（`body` 22px、`title` 38px、`caption` 18px；
探针 `/tmp/sr-dub/dyntype.swift`）。因此 §9 的「行高随字号增长」不能用动态字号触发，
验收口径改为三条：① 全部文本走系统文本样式（代码层可查，无写死点数）；② 容器一律 `minHeight`
（已做，见第七轮）；③ 真机把系统「辅助功能 → 显示 → 文字大小」调大后走查。

#### 第三十七轮（续）：页面列表行高结案 —— 59 → 63，外加两处字号归位

**这轮把「`List` 行高量不出来」这条老账结掉了。** 先补上根因（探针 `/tmp/sr-list`）：SwiftUI 的
`List` 在 macOS 上由 `NSTableView` 支撑，且 `usesAutomaticRowHeights = true`、委托
`OutlineListCoordinator` 不实现 `tableView(_:heightOfRow:)`，所以 `rect(ofRow:)` 只会返回估计值 24，
`noteHeightOfRows` 也推不动它——没有窗口就没有行布局。但**行高 = 行内容高度**这一点是确定的
（行自己给内边距、`listRowInsets(EdgeInsets())` 清零），于是改成从两端取证：

| 端 | 方法 | 结果 |
|---|---|---|
| 稿 | `/tmp/sr-dub/rowpitch`（4x 帧上扫分隔线与选中行填充的上下沿） | 三页行距都是 **64.00pt**：`我的作品` y=215.25/279.25…、`音色库` y=226.25/290.25…、`诊断` y=177.25/241.25…；选中行填充实测正好 **63.00**，其后一条 1pt hairline |
| 应用 | `/tmp/sr-dub/lineheights`（同字体同修饰符栈的离屏量高） | 行内容 16 + 4 + 15 = **35**，加 padY 12×2 = **59.00**（旧），加 `minHeight 63` 后 **63.00**（新） |

差的 4pt 来自**行盒**而不是内边距：稿的行高百分比是 `Body/Medium` 13@150% = 19.5、`Callout` 12@145% =
17.4（`info` 的 `gap: 2`），系统文本样式只有 16 + 15，中间再补回 2pt 的 `Spacing.micro`，
正好 35 − 38.9 ≈ −3.9。**处置**：新增 `List.pageRowMinimumHeight = 63`（声明内边距仍是稿的 12，
差额由行框补，内容竖直居中，视觉上等于 padY 14），音色库 / 我的作品 / 诊断三处改用它；
`List.rowHeight`(44) 仍然是侧栏项与折叠行的命中区下限，不动。行内两行文字的墨迹间距应用 7.9、
稿 9.0，这 1.1pt 不再追（要追就得给 `Spacing.micro` 单独开一个 2pt 的值，收益不值）。
**残余不确定性**：应用 `List` 的行分隔线与行框的叠放关系离屏仍然量不到，所以「行距」在真机上是
63 + hairline 还是 63 整，留给桌面走查；行框 63 本身由构造确定。

**同轮两处字号归位**（都是「代码和自己的注释、和稿都不一致」）：

1. **诊断检查行的说明**：稿是 `Callout`（`main.js` 2013），4x 帧上这一行墨迹高 12.50、名称行 12.00
   （两行都是中文，比例可比 → 与名称同档），应用却用 `caption`(10pt)。改 `callout`。
2. **字段标签**：稿的 `fieldLabel` 是 `Caption / Medium`（`main.js` 692），应用 6 处字段标签
   （保存名称、试听与注册参考文案、试听文案、名称、音色描述、采样种子）用 `caption`(Regular)。
   改 `captionMedium`——这也是 `macos-app-design-system.md` 里「`caption` 只留给应用自有密集区块」
   那条约定第一次真正落到字段标签上。

两处都只改字重/字号，不动版式；`swiftc -typecheck`（macOS 26 SDK）0 error、`git diff --check` 干净。
**未构建官方包、未运行单元测试与 UI 自动化、未桌面走查**（预览包已按本轮源码重建并 ad-hoc 签名）。

#### 第三十八轮：输入卡下限 160 → 144（用户第六度校准）

用户 2026-09-16 又一次把输入区拎出来并改了指令：「临时回到大输入 textarea 滚动条问题，修改指令，
可接受滚动条，优先使用原生组件，但大小高度等，需要优化。」——**与第三十二轮同一句话**。本轮先按
老规矩复核一遍当前状态，再决定动不动：

**① 复核（不动代码的部分）。** 用同一套离屏探针重跑，第三十二轮的结论仍然成立：组件是原生
`TextEditor`（滚动、滚动条、焦点环、文本背景全由系统给，隐藏 `Text` 副本只产出一个高度数值）；
静止状态 `doc = clip`（无滚动条）；超上限才出现原生滚动条且不隐藏。1440 × 900 下整页
`[scrolls] scroll h=77.0 doc=77.0 clip=77.0`。

**② 为什么还是决定再收一档。** 第三十二轮把 200 收到 160 时，给的理由是「下限的职责是短文稿
也给一块整写作区」，并把 160 对应成「正文区 77pt ≈ 4 行」。但**滚动条这一条已经被用户撤回**：
下限不必再为「拖后出现滚动条」多留一行，只需要保证**静止状态看得见 3 行写作区**。而画板上的
160 从来不是「一行文稿的高度」——`figma-kit/main.js` 那一帧画的是**3 行**示例文稿（两段、
1080pt 宽）。也就是说 160 是**3 行文稿自然长出来的高度**，把它当下限套在 1–2 行文稿上，
多出来的空白没有任何稿依据。

**③ 改法（一个 token）。** `Layout.creatorComposerMinimumHeight` 由 160 收到 **144**：
3 行 × 20pt 行距 + 卡内固定开销 83pt（上下内边距 40 + 分隔线 1 + 页脚带 42）= 143，
取 4pt 网格 144（正文区 61pt ≈ 3 行）。上限 360、跟随正文的规则、原生滚动条的归属都不动。

**④ 离屏实测**（`/tmp/sr-dub` 探针，`NSHostingView` + 多轮 `layoutSubtreeIfNeeded`/`CFRunLoop`，
宽 1400，不开窗口；「编辑框」是 `NSScrollView` 的框，卡高 = 编辑框 + 分隔线 + 42pt 页脚带）：

| 正文 | 卡高（改前 → 改后） | 编辑框（改前 → 改后） | 滚动 |
|---|---|---|---|
| 1 行（22 字） | 160 → **144** | 77 → **61** | 无（16 ≪ 61） |
| 3 行 | 160 → **158** | 77 → **75** | 无（56 < 75） |
| 8 行 | 255 → 255 | 172 → 172 | 无 |
| 16 行 | 360 → 360 | 277 → 277 | **原生滚动**（doc 316.5 > clip 277） |

3 行那一档改后是 158——**这正是本轮的关键**：3 行文稿的自然高度（158）已经越过新下限（144），
所以画板上那一档（稿画 160）几乎没动，差的 2pt 是行盒估计；变小的只有 1–2 行文稿，
一行文稿下方的空白由 61pt 降到 45pt。整页渲染（浅色 1440 × 900 / 1120 × 720、深色 1440 × 900）
三档的编辑框都是 **61pt**（改前 77），其余页面（例：音色创作）渲染结果与改前**逐字节相同**。

**⑤ 整页位置核对**（1440 × 900 浅色，`imgtop` 扫列）：文稿行仍是 `107.0–119.0pt`（不受影响）、
分隔线 `202.0 → 186.0`、控制条 `307.0 → 291.0`——**卡以上的版式完全不动，卡以下整体上移 16pt**，
正好等于卡高的变化量。

**脚本同步**：`main.js` 的 `size(editor, null, 160)` **保持不变**（画的是 3 行示例，改后应用渲染
158，比改前更接近），只更新了那段注释；`node --check main.js && node build.js` 通过，
`code.js` 143001 bytes、SHA-256 `f800302f3f13204bc7421c765f4ea8c841763adfbe4c24b4df4c8ab48c21a770`
（改前 `69b9b6b7…`，与第三十二轮记录一致，说明这中间几轮没有漂移），已落到
`~/Downloads/SpeechRail-figma-kit/`；`node audit.js` 仍为 `audit: clean`。

**未验证**：真实窗口里 61pt 正文区的手感（一行文稿时够不够写、输入到第 4 行时卡开始长高是否
察觉）是桌面走查项。**未构建官方包**（Xcode 许可仍未接受）、**未运行单元测试与 UI 自动化**、
**未桌面走查**（预览包已按本轮源码重建并 ad-hoc 签名，见 §12.4）。

**本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error、`git diff --check` 干净；
改动前后离屏渲染对比（音色创作逐字节相同、配音台仅卡内与卡以下 16pt 位移）。

#### 第三十九轮：图标「16」是框不是墨迹（行首状态字形 10 → 13）+ 音色胶囊取色

上一轮尾部留下的未结项是「诊断检查行的图标：应用 `.imageScale(.small)` 实测墨迹 10.00，稿写的是
`icon(row, "check", 16)`」。本轮把它量到底，结论是**稿的 16 是图标框，应用偏小的不是框而是墨迹**，
并顺手统一了这一族；同一轮把音色胶囊里两处与稿不一致的取色也校准了。

**① 稿的真实墨迹（`▸ 诊断.png`，4x，逐像素量；新工具 `/tmp/sr-dub/inkbbox`：给定点坐标矩形，
取矩形内出现最多的颜色为背景，报「与背景不同」像素的外框）**：

| 元素 | 稿（4x 帧实测，pt） |
|---|---|
| 警示三角行（选中行，`triangle-alert`） | 墨迹 **13.5 × 12.0** |
| 对勾行（`check`，两行独立量测结果完全相同） | 墨迹 **12.0 × 8.75** |

与脚本一致：`icon(row, item.icon, 16)` 里的 16 是 **SVG 框**，lucide `check` 的路径
（`M20 6 9 17l-5-5`）在 24 格里只占 16 × 11，缩到 16pt 框就是 10.7 × 7.3 的线，加描边 1.33
≈ 12 × 8.75——与帧上量到的完全一致。

**② 应用的墨迹（探针 `/tmp/sr-dub/iconsize.swift`，同一 `checkmark.circle.fill`）**：
`.imageScale(.small)` = **10.00 × 10.00**（改前）、`.imageScale(.medium)` = 13.00、
`.font(.system(size: 13))` = 13.00、13 semibold 的 `exclamationmark.triangle.fill` = **13 × 12**。

两端的对照是干净的：**13** 对稿的三角行残差 0.5 × 0，对勾行按宽度残差 1.0（圆底字形本来就比
细线对勾高，这一点属于字形差异，不是尺寸差异）；**10** 则比稿小 20–30%。13 也正是应用自己的
既有档位——`ControlAgentStatusView`、`ModelManagementView` 两处资源行、`RuntimeMonitoringView`
能力行都随正文继承到 13，即「行首状态字形」这一族本来就在 13，`.imageScale(.small)` 是唯一的异类。

**③ 改法**：新增 `Icon.rowStatusSize`(13) 与 `Typography.rowStatusIcon`
（`.system(size: 13, weight: .semibold)`，字重与同族的 `statusIcon` / `bannerIcon` 一致），
三处 `imageScale` 全部改用它，**该写法在整个 App 里从此不存在**（`rtk rg imageScale` 只剩注释）：

- `PreflightDiagnosticsView`（诊断检查行，稿有对应元素）：10 → **13**；
- `RuntimeMonitoringView` 资源行：10 → **13**；
- `RuntimeMonitoringView` 能力行：`.medium` → 同名 token，墨迹仍是 13（改的是写法）。

**④ 副作用（记录在案）**：图标墨迹变宽 3pt，诊断行的文字列因此左移对齐到距行左沿
`16 + 13 + 8 = 37pt`，稿是 `16 + 16 + 10 = 42pt`，残差 5pt（改前残差 8pt）。行高不受影响
（13 < 行内容 35，`pageRowMinimumHeight` 63 仍由构造决定）。

**⑤ 音色胶囊的两处取色（同一轮）**。把 `imageScale` 扫干净之后，顺着同一类「没有任何显式修饰、
继承成别的值」的写法继续查，配音台控制条的**音色胶囊**里有两处：

| 元素 | 稿 | 应用（改前） | 改后 |
|---|---|---|---|
| 波形图标 | `icon(capsule, "audio-waveform", 15, V["accent/voice"])`（4x 帧同样量到琥珀） | 不设色，继承成正文色 | `Color.voice` |
| 尾部 chevron | `icon(capsule, "chevron-down", 14, V["text/secondary"])` | `inkTertiary` | `inkSecondary` |

波形那一条不只是「与稿一致」：§5.4 本身就写着琥珀标记「音色徽标、**波形**、候选卡」，
胶囊里的波形正是这一类对象，而同一行的来源徽标已经在用 `Color.voice`——一个胶囊里一半琥珀、
一半正文色，读起来像两个来源。chevron 那一条是应用自己的异类：折叠行
（`SpeechRailDisclosureGroupStyle`）的 chevron 用的就是 `inkSecondary`，全 App 只有这一处用三级色。
稿侧口径也不是一刀切：导航性 chevron（结果条「查看我的作品」13、诊断行 14、菜单行 15、设置行 13）
是 `text/tertiary`，而**展开/弹出**类（胶囊 14、折叠行 14、Inspector 14）是 `text/secondary`。
两处尺寸都不动：波形实测墨迹 11.5 × 10.0，稿的 15pt 框里 `audio-waveform` 墨迹约 12.5 宽，残差 1pt；
chevron 稿的框 14，应用 `caption2`（10pt）墨迹约 9.4 × 5.5，残差 1.2pt。

**未验证**：诊断行的 `List` 行在无窗口环境不布局（第三十七轮已查明根因），所以**这一处改动的
整页渲染无法离屏取得**——本轮的证据是字形探针的墨迹量测 + 4x 帧量测，行内观感归桌面走查。
胶囊的两处颜色**已在整页离屏渲染里确认**（波形为琥珀、chevron 为 `inkSecondary`）；但探针环境
取不到「已选音色」的形态（视图 `.task` 在无窗口宿主里不跑，`selectedVoiceID` 一直是空串），
所以带来源徽标的胶囊仍未出图，归桌面走查。
**未构建官方包**（Xcode 许可仍未接受）、**未运行单元测试与 UI 自动化**、**未桌面走查**
（预览包已按本轮源码重建并 ad-hoc 签名）。

**本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error、`git diff --check` 干净；
`imageScale` 用法清零；字形探针 8 档墨迹量测；整页离屏渲染（浅色 1440 × 900：配音台与音色创作
与上一轮逐字节相同，胶囊区域按预期变色）。

#### 第四十轮：侧栏底部状态区收成一行 + hairline 按稿内缩

本轮处理全局状态唯一性那个位置（§6.4 / D9 指定的唯一常驻指示器）。它是 App 里唯一一处
「读起来像导航」的状态呈现，此前与稿有两处结构性差异。

**① 形态：两行 + chevron → 一行**

稿的 `Sidebar Status` 三个 tone 变体（`main.js`：`componentSet("Sidebar Status", …)`）写法一致：
`layout: HORIZONTAL, gap: 8, align: CENTER, padX: 8, padY: 7` + `dot(c, 8, …)` +
`text("label", "服务已就绪 · Quality", "Callout", V["text/secondary"])`；页面帧里的 `sidebarStatus` 同款。
4x 帧 `▸ 配音台.png` 侧栏底部实测：

| 元素 | 稿（4x 帧实测，pt） |
|---|---|
| 状态点 | **8.0 × 8.0**（x 18–26，y 869–877） |
| 状态文本 | 墨迹 **108.75 × 12.5**（x 34.5–143.25） |
| 整行 | 墨迹 **125.25 × 12.75** |

应用此前是「服务状态」标题行（`callout` + `.primary`）+ 小一号的语义色状态行（`caption` +
`sidebarStatusTone.color`）两行，外加尾部 `chevron.right`（`.caption` / `.tertiary`）。
改为稿的一行：8pt 点 + `Text(sidebarStatusText).font(.callout).foregroundStyle(inkSecondary)`，
没有标题行、没有 chevron。点击面（整行 Button）、`.help`、`accessibilityLabel` / `accessibilityValue`
都不变。

**② hairline：通栏 → 按稿内缩 10**

稿的这条线不是 `Divider()`：`sidebarStatusWrap` 里是 `rect(statusWrap, "hairline", 220, 1,
V["border/separator"])`，而侧栏是 `frame("sidebar", { …, padX: 10 })`——220 宽在 240 侧栏里
等于左右各缩 10，与上方侧栏行的边缘对齐。4x 帧实测该线墨迹 **x 10.0–230.0**，与之相符。
应用此前用系统 `Divider()`（只能通栏，实测 x 0–240）。改成 1pt `Rectangle` +
`Control.sidebarHairlineInset`(10)。系统侧栏行自身的内缩由 `List` 给，这条线是否与行边缘齐平
归桌面走查。

**③ 离屏实测**（探针 `/tmp/sr-dub` 的 `--sidebarstatus`，240 宽，无窗口、不接管前台）：

| | 改前 | 改后 | 稿 |
|---|---|---|---|
| 块高（hairline + 状态行） | 47.0 | **45.0** | 53（含稿侧栏 `padY` 12 的下边距） |
| hairline 墨迹 x | 0–240（通栏） | **10–230** | 10–230 |
| 状态点 | 8 × 8 @ x16 | 8 × 8 @ x16 | 8 × 8 @ x18 |
| 状态文本 | 两行（标题 + 状态） | **单行，墨迹高 12.0** | 墨迹高 12.5 |
| hairline 到文本顶 | — | 18.0 | 20.25 |

浅色 / 深色两种外观各测一次，几何相同（hairline 深色 `#2E2E2E`、浅色 `#E6E6E6`）。

**④ 记录在案的两处残差**（都来自应用自己的既有决定，不是本轮引入）：

- **行高 44 vs 稿 30**：状态行是 `SpeechRailInteractiveButtonStyle` 的实例，该样式按
  `Interaction.minimumHitTarget` 给 44pt 命中区下限；应用侧栏项（`Navigation.sidebarRowHeight`）
  一律 44，稿的 `navItemRow` 是 30（第三十七轮的同类残差）。状态行与侧栏项同高读起来是一族的，
  代价是块高 45 而不是稿的 53，且稿侧栏 `padY: 12` 的下边距在应用侧没有对应物。
- **点 / 文本左侧 16 vs 稿 18**：应用是「样式内边距 8 + 行内 8」，稿是「侧栏 `padX` 10 + 行内 8」。
  本轮没有连带改它——侧栏内容的内缩由系统 `List` 给，硬编码 10 可能与系统当前值冲突。

**未验证**：侧栏在无窗口环境不布局（`List` → `NSTableView`，第三十七轮已查明根因），整窗渲染里
侧栏是空的——本轮证据是「把产品代码里那一段本身渲染出来」的探针 + 4x 帧量测，它在真实侧栏里
与系统行的相对位置（hairline 是否与行边缘齐平、44 行高的观感）归桌面走查。
**未构建官方包**（Xcode 许可未接受）；预览包已按本轮源码重建并**覆盖安装**到
`~/Applications/SpeechRail.app`（第 8 步授权，见 §12.4），**未运行单元测试与 UI 自动化**、
**未桌面走查**。

**本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error、`git diff --check` 干净；
改前 / 改后同一探针各一组数字（上表），改前那组由「把 `sidebarBottom` 换回 HEAD 的两行写法」
的同一探针复刻测得。

#### 第四十一轮：诊断检查行补框与间距 + 结果条标题区 / 安静出口 + 时长零填充

本轮把「诊断检查行」和「生成结果条」两处按稿重排，并把作品时长的写法改成稿的零填充。

**① 稿的写法（`main.js`）**

| 位置 | 稿 |
|---|---|
| 诊断检查行 | `frame("diagRow", { layout: HORIZONTAL, gap: 10, align: CENTER, padX: 16, padY: 12 })`（2009）；行首 `icon(row, item.icon, 16)`、名称 `Body / Medium`、说明 `Callout`；行尾 `icon(row, "chevron-right", 14, V["text/tertiary"])`（2016） |
| 结果条 | `frame("resultBar", { gap: 12, align: CENTER, pad: 14, radius: 12, fill: surface/railTint })`（1368）；标题区 `frame("titles", { gap: 8 })` = 名称 `Body / Medium` + 时长 `Callout` `text/secondary`；出口 `frame("quiet", { gap: 4, padX: 8, padY: 4, radius: 7 })` = `Callout` `text/secondary` + `icon(…, "chevron-right", 13, text/tertiary)` |
| 时长 | 七条作品行、结果条与候选卡一律零填充 `mm:ss`（`00:12` / `01:47` / `00:26` / `03:18` / `00:48` / `00:09` / `02:31`） |

**② 4x 帧实测**（`▸ 诊断.png`，就绪行在纯白底上）：

| 元素 | 稿（pt） |
|---|---|
| 行盒 | **63 + 1pt hairline = 64 周期**（颜色带：hairline 177.0–178.0 → 选中行底色 `#DCE9EE` 178.0–241.0 → hairline 241.0–242.0 → 白行 242.0–305.0 → …） |
| 行首图标墨迹 | 对勾行 **12.0 × 8.75** @ x 280.0；三角行 **13.5 × 12.0** @ x 279.25 |
| 名称墨迹 | x 304.25 起（= 卡左沿 262.5 + padX 16 + 图标框 16 + gap 10 + 首字留白 1.25 → **42 文字列**） |
| 名称 / 说明墨迹顶 | 193.75 / 214.75（行盒 178–241 里上留 15.75、下留 15.0） |
| 行尾 chevron | **5.0 × 8.5** @ x 1037.5–1042.5 |

**③ 应用改后**（探针 `--diagrow`：把 `PreflightCheckRow` 本体摆出来渲染，320 宽，无窗口、不接管前台）：

| 元素 | 改后实测 | 稿 | 残差 |
|---|---|---|---|
| 文字列 | **42.0** | 42（41.75） | ≤0.25 |
| 行盒 | **63 + 1pt hairline = 64** | 63 + 1 | 0 |
| 名称墨迹顶距行顶 | 15.5 | 15.75 | 0.25 |
| 行首图标墨迹 | 14.0 × 14.0 @ x 17 | 12.0 × 8.75 @ x 17.5 | 字形（见下） |
| 行尾 chevron | **5.0 × 8.5** | 5.0 × 8.5 | **0** |

上一轮只把行首字形从 10 收到 13，没有补 `icon(…, 16)` 的**框**与 gap 10，文字列因此停在
`16 + 13 + 8 = 37`；本轮补上 `Control.diagnosticIconFrame`(16) 与 gap 10（10 不在应用的 4pt
间距档上、也没有第二处用到，所以就地写明来源、不新造 token），文字列收到 **42**。行尾原本是
「通过 / 失败」两个字的语义色文本——比稿多一列文字，而状态在行首字形、列表头「N 项需要处理」
与行自身的 `accessibilityValue` 里已经说过三遍；按稿换成灰色 `chevron.right`。

**关于「行内墨迹比帧高」**：名称 14.0 / 说明 13.5，比帧上的 12.5 / 11.25 高。这不是字号差——
帧上那 8 项属于**另一代内容**（标题是「受管 runtime 完整」「模型校验未完成」这类），逐字比不了；
按**每字步进**比才可比：帧上「模型校验未完成」墨迹 90.5 ÷ 7 字 = 12.93、应用「分人对齐制品」
76.5 ÷ 6 字 = 12.75、「应用目录」51.5 ÷ 4 字 = 12.875，三者都是 13pt `Body / Medium` 的 1.0 em ✓
（同轮量到「查看我的作品」两端墨迹**同为 70.5pt**，也是同一口径）。

**④ 结果条**（探针 `--dubbar`，1440 × 900）：

| 元素 | 改后实测 | 稿（4x 帧） | 残差 |
|---|---|---|---|
| 标题墨迹起点（距条左沿） | x 95.0（75.0） | x 334.75（72.5） | 2.5 |
| 标题墨迹宽 | 116.0 | 113.5 | 2.5 |
| 时长墨迹 | 33.0 宽，起点距标题末 9.0 | 29.5 宽，9.5 | 3.5 / 0.5 |
| 安静出口 label | x 1313.5–1382.0（68.5） | 1308.5–1379.0（70.5） | 5 / 2 |
| 安静出口 chevron | **5.0 × 8.5** @ x 1390.0–1395.0 | 5.0 × 8.5 @ x 1388.25–1392.5 | 尺寸 **0** |
| 行首波形 | 46.0 × 17.0 | 46.0 × 17.0 | **0**（第四十二轮） |

改了三处：名称改 `bodyMedium`（此前时长并进同一行文本、字号跟着标题走）；时长拆成
`callout` + `monospacedDigit` + `inkSecondary`（去掉「· 」前缀）；出口由第四颗边框按钮改成
稿的**安静行**（`.borderless` + `callout` + `inkSecondary` + 13pt chevron，内边距 `xs` / `micro`）。

**⑤ 时长零填充**：`CreativeWorkStore.durationText` 与候选卡的 `countText` 同改 `m:ss` → `mm:ss`。

**未验证**：诊断行住在 `List` 里，本轮的证据是「把产品代码里那一行本身渲染出来」的探针；新
chevron、安静出口与 46 + 12 的文字列在真实窗口里的观感归桌面走查。**未构建官方包**、
**未运行单元测试与 UI 自动化**。

**本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error、`git diff --check` 干净。

#### 第四十二轮：波形原语（三处）按稿重建

**① 稿是「一个原语、三种参数」**：`waveform(parent, bars, colorVar, gap)`（`main.js:345`）——每根是
**2pt 宽、圆角 1** 的矩形，按给定高度**垂直居中**排开；整块宽 `n × 2 + (n − 1) × gap`、高 `max(bars)`。

| 位置 | 稿的调用 | 4x 帧实测墨迹 |
|---|---|---|
| 结果条行首（`main.js:1372`） | 12 根、间隙 2、高度 `[5,11,16,8,14,6,12,17,9,5,13,7]` | `▸ 配音台.png` **46.0 × 17.0** |
| 音色创作候选卡（`main.js:1425`，`justify CENTER`） | 18 根、间隙 3、高度 `[10,22,34,…]` | `▸ 音色创作.png` **87.0 × 36.0**（周期 5.0） |
| 音色库试听行（`main.js:1601`，`justify CENTER`） | 16 根、间隙 3、高度 `[8,16,26,…]` | `▸ 音色库.png` **77.0 × 30.0** |

**② 应用改前**：一个固定组件（9 根、3 宽 / 3 距、框 72 × 20）顶两处，结果条那处则是一个 SF
`waveform` 字形（第三十九轮实测墨迹 **11.5 × 10.0**）。三处都比稿小一大截，而且一律左对齐。

**③ 改法**：新增 `SpeechRailDesignTokens.Waveform`（`barWidth` 2 / `barRadius` 1 + 三个 `Pattern`），
宽度与高度由 pattern 推出来，不再各写一个框；`AcousticWaveformBar(active:)` 改为
`WaveformBars(pattern:isPlaying:)`。删除 `Layout.creatorWaveformWidth/Height`、
`Control.waveformBarSpacing/Width/Radius`、`Color.waveformInactive`。

播放态：稿上波形**一律琥珀、满高**（未播放的候选卡与未播放的试听行在帧上同样是琥珀满高），
所以不再按 `isPlaying` 换灰色或砍半高——候选卡的播放态由卡片描边与「试听 / 停止」承担。
`isPlaying` 只驱动 §5.7 的波形脉冲；条状视图接不了 `.symbolEffect`，因此脉冲是一段显式的
透明度动画（0.75s 往返），Reduce Motion 下停在静态。

**④ 离屏实测**（同一个组件、三种参数；探针 `--waveform` / `--candidates` / `--dubbar`）：

| 位置 | 改后实测 | 稿 | 残差 |
|---|---|---|---|
| 结果条行首 | **46.0 × 17.0** | 46.0 × 17.0 | **0** |
| 候选卡 | **87.0 × 36.0** | 87.0 × 36.0 | **0** |
| 试听行 | **77.0 × 30.0** | 77.0 × 30.0 | **0** |

三处形状与尺寸与稿逐位相同；候选卡那处渲染在卡片内居中（两张卡各自的波形中心与卡中心差 3.5pt）。
结果条的文字列随之右移到稿的位置（名称墨迹距条左沿 75.0 vs 稿 72.5）。

**未验证**：试听行住在 Inspector 里（无窗口宿主不布局，与 `List` 同源），三处波形在真实窗口里的
观感归桌面走查；脉冲只在播放中出现，离屏渲染到的是静态帧，**Reduce Motion 下的表现仍只有
代码层确认**。

**⑤ 同轮记录、本轮未改动**：音色库的试听行在稿里是
`frame("preview", { gap: 10, padX: 12, padY: 10, radius: 10, fill: surface/panel })` 里放
`iconButton(preview, "play", 28)` + 波形——4x 帧实测该面板 y 276.0–326.0（50 = 波形 30 + 上下各 10）、
底色 `#F5F5F7`；应用的试听行没有面板底，播放钮也不是稿的 28pt 图标按钮。因为 Inspector 在无窗口
环境渲染不出来（改了也取证不了），本轮只记录、不动代码。

**⑥ 交付状态（第四十一 + 四十二轮一起）**：预览包已按两轮源码重建并**覆盖安装**到
`~/Applications/SpeechRail.app`（用户当轮授权），新二进制 sha256 `381bb0c8…b30a3656`、ad-hoc 签名、
`codesign --verify --deep --strict` 通过，启动后主进程与 `…local-control.xpc` 均起来且存活
（无新崩溃报告）。**未构建官方包**（`xcodebuild` 仍被 Xcode 许可挡住）、**未运行单元测试与
UI 自动化**、**未桌面走查**；回退点见 §12.4。

#### 第四十三轮：先修量测边界，再按它校准两类行高（页面行 64、侧栏行 32 / 状态行 30）

**① 量测边界被推翻**（本轮真正的起点）。第二十三 / 二十五轮记下两条边界：「`NSHostingView`
快照不出图」「`List` 的行矩形读不到、行不按内容布局」。根因其实只有一条——**没有窗口**。
探针新增 `--window`：给宿主一个**真实但从不显示、从不激活**的 `NSWindow`
（只 `contentView = host`，不 order / 不 makeKey / 不 activate，另加 `alphaValue = 0` 与
`ignoresMouseEvents`），`List` 的行立刻按内容布局、并且**画得出来**：

| 页面 | 改前能不能离屏取证 | `--window` 后 |
|---|---|---|
| 诊断（检查清单） | 只有「把 `PreflightCheckRow` 单独摆出来」的复刻品 | **8 行全部出图**（图标 / 名称 / 说明 / 行尾 chevron / 列表头 / 页脚） |
| 音色库（音色清单） | 只有空列表 | **行出图**（名称 + 徽标 + 说明 + 试听钮） |
| 我的作品 | 只有空列表 | **8 行 + 列头 + 页脚出图** |
| 侧栏 | 只有「把 `sidebarBottom` 单独摆出来」的复刻品 | 行矩形读得到（10 行），但**行内容不画**（`NavigationSplitView` 的侧栏走另一套合成，`cacheDisplay` 取不到）——侧栏仍只有几何、没有像素 |

所以本轮对「行高」这一类问题第一次有了**产品代码自己的实测**，而不再依赖复刻品与帧的推算。
（`Table` 行高是系统固定值，第二十四轮的 28/24 不受影响。）

**② 页面列表行 63 → 64**（音色库 / 我的作品 / 诊断三页共用一个 token）

第三十七轮钉的是**帧**：帧上「行框 63 + 它下面独立的 1pt hairline」= 行距 64。但应用给的
是**系统 `List` 的行矩形**，而系统那条分隔线画在行矩形**内部**：

| 量测（诊断页，`--window`） | 改前（63） | 改后（64） | 稿 |
|---|---|---|---|
| `rect(ofRow:)` 行矩形 | 63.0 | **64.0** | —（帧的行框 63） |
| 分隔线间距（行距） | 63.0 | **64.0** | **64.0** |
| 两条分隔线之间的内容区 | 62.0 | **63.0** | **63.0**（178.0–241.0） |
| 行内墨迹距行顶 / 距行底 | 16.5 / 14.5 | 16.5 / **15.0** | 15.75 / 15.0 |

改后行距、内容区与帧逐位相同，行内墨迹上下分布差 0.75 / 0。三页同源，`我的作品`
（8 行）与 `诊断`（8 行）都实测 64.0。

**③ 侧栏导航行 52 → 32**（稿 31）

稿的 `navItemRow` 是 **220 × 30**（`gap 8 / padX 8 / radius 7`、图标 16 + `Body` 标签、
选中行填 `surface/railTint`），行间是 `group` 的 **gap 1** → **行距 31**；4x 帧
`▸ 配音台.png` 侧栏实测选中行底色带 **119.0–149.0 = 30.0**、导航行墨迹行距 30–31.75。
应用此前是 `List.rowHeight`(44) + 上下各 4 的行内边距 = **52**。

改成稿的 30、上下内边距归零后，`--window` 实测行矩形 **32**（行距 32）。同一轮还量到一条
系统边界：把这个值临时改成 **20** 再渲染，行矩形**仍是 32**——`.listStyle(.sidebar)` 的
行矩形自带 **32 下限**，所以真实行距与稿差 **1pt**，这 1pt 是系统给的，不是 token 能决定的。
应用侧栏本来就是系统 `List` + `NavigationLink`（§5.2「系统控件优先」），为这 1pt 换掉系统
侧栏行不划算，记在案。改后仍高于 macOS 指针目标的 24pt 下限。

**④ 侧栏底部状态行 44 → 30**（稿 30）

稿的 `sidebarStatus` 是 **220 × 30**（`padX 8 / padY 7`、8pt 点 + `Callout`）。第四十轮把它
收成一行，但高度仍由 `speechRailInteractiveButtonStyle` 的 44pt 命中区下限主导（块高 45）。
本轮给这个样式加了一个 `minimumHeight` 参数（默认仍是 `Interaction.minimumHitTarget`，
只有这一处传 30），`--sidebarstatus` 离屏复刻实测块高 **45.0 → 32.0**（= hairline 1 + 状态行
30 + 1pt 舍入），稿的 `sidebarStatusWrap` 是 1 + 30 = 31，残差 1pt。

**未验证**：侧栏在 `NavigationSplitView` 里行内容画不出来（见 ①），所以侧栏两处改动只有
**几何**证据（行矩形与复刻品的块高），真实窗口里的观感与侧栏行内文字基线归桌面走查；
页面行的墨迹是产品代码自己的离屏渲染，可信度与前三轮同档。**未构建官方包**、**未运行
单元测试与 UI 自动化**。

**本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error、`git diff --check` 干净；
预览包已按本轮源码重建并覆盖安装（sha256 `6d86df57…`，回退点见 §12.4），启动后主进程与
`…local-control.xpc` 均起来。

#### 第四十四轮：按帧校准行内动作字形与 Inspector 试听面板

**① 先把「字形该多大」量成数**。新增两个只读探针：`/tmp/sr-dub/glyph`（量 SF Symbol 的
墨迹外框与墨迹面积，无窗口、不接管前台）与 `--voicepreview`（把 Inspector 的试听行摆进
离屏宿主，见 ③）。帧侧量到的是同一个原语（稿 `iconButton(parent, name, 28)`：28 × 28 框、
圆角 7、无底色、`icon(b, name, 15, text/secondary)`）在三页上的墨迹：

| 位置 | 4x 帧实测墨迹 | 墨迹面积 | 色 |
|---|---|---|---|
| 音色库列表行 `play` ×3 | **10.25 × 11.5** | 711px @4x = **44.4pt²** | `#6E6E73` |
| 音色库 Inspector 试听行 `play` | **10.25 × 11.5** | 683px @4x = **42.7pt²** | `#6E6E73` |
| 我的作品行 `play` ×2 | **10.25 × 11.5** | 711px @4x = **44.4pt²** | `#6E6E73` |
| 我的作品行 `download` | **12.5 × 12.5** | 774px @4x = **48.4pt²** | `#6E6E73` |

`#6E6E73` 就是浅色的 `secondaryLabelColor` —— 稿的 15pt 是**图标框**，lucide 字形在框里留白，
所以墨迹比框小一档。本机实测（`/tmp/sr-dub/glyph`）：

| 写法 | 墨迹 | 面积 |
|---|---|---|
| `play` **13pt semibold** | **10.0 × 11.5** | **42.5pt²** |
| `play` 14pt medium | 10.5 × 12.0 | 43.8pt² |
| `play` 13pt regular | 9.0 × 11.0 | 28.8pt²（明显偏细） |
| `play` 17pt semibold（应用改前） | 13.0 × 15.0 | 72.2pt² |

13pt semibold 与帧的 10.25 × 11.5 / 44.4pt² 逐位吻合，且与第三十九轮为
`Icon.rowStatusSize` 定下的「13 + semibold」同族。

**② 应用改前**：这一族在四处各写一遍 `Typography.statusIcon`（17pt semibold），播放钮还用
`play.circle.fill` **自造成琥珀实心圆**（墨迹 13 × 15，比帧大 30–44%，而稿上根本没有实心圆）；
我的作品的导出与「更多操作」是同档的 15 × 18 / 16 × 3。改成一处 `RowActionGlyph`
（新 token `Icon.rowActionSize` = 13 + `Typography.rowActionIcon`）：播放 / 停止、导出、
更多操作统一 13pt semibold + `inkSecondary`，播放态从 `stop.circle.fill` 改成稿式的 `stop`。

| 位置 | 改后离屏实测 | 帧 | 残差 |
|---|---|---|---|
| 音色库列表行 `play`（整页 `--render --window`） | **10.0 × 11.5** | 10.25 × 11.5 | 0.25 / **0** |
| 我的作品行 `play` | **10.5 × 11.5** | 10.25 × 11.5 | 0.25 / **0** |
| 我的作品行 `download` | 12.0 × 14.0 | 12.5 × 12.5 | 0.5 / 1.5 |
| 我的作品行 `ellipsis` | 12.0 × 2.5 | —（帧上没有这颗按钮，见 ⑤） | — |

下载那一档的 1.5pt 差是**字形形状差**：SF `square.and.arrow.down` 比稿的 lucide `download`
（箭头 + 开口托盘）更窄更高，不是字号问题——13pt 是同一族里最近的一档。

离屏渲染把 `secondaryLabelColor` 画成 `#808080`：同一个探针用纯黑作对照得到的仍是 `#000000`，
说明这是**无窗口合成下的色彩解析差异**，不是取值错误（与第四十轮记录的「离屏数值 ≠ 窗口数值」同源）。

**③ Inspector 试听面板按稿重建**。稿是 `previewWrap`（`padX 16 / padY 14`）里嵌
`preview`（`gap 10 / padX 12 / padY 10 / radius 10 / fill surface/panel`）+ 1pt `border/separator`，
里面是 `iconButton(play, 28)` 与**在剩余宽度里居中**的 16 根波形（`main.js` 1594–1603）。
4x 帧 `▸ 音色库.png` 逐像素实测：

| 量 | 帧 |
|---|---|
| 面板填充带 | **50.0**（y 276.0–326.0 = 波形 30 + 上下各 10） |
| 面板描边 | 1pt，且画在**填充外**（275.0–276.0 / 326.0–327.0）→ 外框 **52.0** |
| 填充 / 描边色 | `#F5F5F7`（`surface/panel`）/ `#DCDCE0`（`border/separator`） |
| 波形 | **77.0 × 30.0**，整块**不在面板正中**：面板 1138.5–1405.5（中心 1272.0）、波形中心 1289.0，偏右 **17**（= 图标按钮占位后剩余宽度里居中） |
| 播放字形 | 10.25 × 11.5、`#6E6E73`、无底色 |

应用改前只有一行 `HStack`：没有面板底、没有描边、播放钮是琥珀实心圆、gap 用的是 12。
改后按稿实现（`Color.field` 承载 `surface/panel`，见下述口径），离屏实测：

| 量 | 改后（`--voicepreview`，浅色 / 深色） | 帧 | 残差 |
|---|---|---|---|
| 面板填充带 | **50.00 / 50.00** | 50.0 | **0** |
| 面板外框 | **52.00 / 52.00**（描边 1pt 在填充外） | 52.0 | **0** |
| 波形 | **77.00 × 30.00** | 77.0 × 30.0 | **0** |
| 波形竖直位置 | 上下各 10.0 | 上下各 10 | **0** |
| 播放字形 | 10.0 × 11.0（深色 10.0 × 11.5） | 10.25 × 11.5 | ≤0.5 |
| 波形水平位置 | 偏右 **19.5** | 偏右 17 | 2.5 |

描边画在填充外不是默认行为：SwiftUI 的 `strokeBorder` 画在边界**内侧**，所以这里用
`RoundedRectangle(cornerRadius: 10 + 1).strokeBorder(…).padding(-1)`——形状向四周外扩 1pt 后再
向内画 1pt，这条环正好落在填充之外，外圈半径也随之间心 +1。
**口径差异（记录）**：面板底色应用取 `Color.field`（= `controlBackgroundColor`，浅色解析为白），
与帧的 `#F5F5F7` **极性相反**——依据是 §5.4 的映射表（`surface/panel` ↔ `controlBackgroundColor`），
数值由 AppKit 在真实窗口里解析；边框与几何则与帧逐位相同。

**④ 未验证**：Inspector 本体在无窗口/`--window` 两种宿主下都取不到像素（第四十二 / 四十三轮已查明），
所以 ③ 的证据来自**产品代码那一块自己**的离屏渲染（`--voicepreview` 把 `voicePreviewSection`
当作被安装的 body 渲染，`model` 与 `sampleText` 都是该视图自己的动态属性），面板在真实
Inspector 材质上的最终观感归桌面走查。**未构建官方包**、**未运行单元测试与 UI 自动化**。

**⑤ 同轮记录、未擅改（待拍板）**：

| 冲突 | 帧 | 应用 | 为什么不擅改 |
|---|---|---|---|
| 我的作品行动作 | 只有 `play` + `download` 两颗（4x 帧裁到窗口右沿确认） | `play` + `download` + 「更多操作」省略号 | **第六十轮结案**：当前 kit（`main.js:1692-1694`）本来就是三颗，帧属上一代——应用现状即 kit，**不改**（§12.4 决定 16） |
| Inspector 分区 | header / preview / body / 动作之间有 1pt 全宽 hairline（帧 y 260.0–261.0 为 header 下那条） | 无分隔线，靠 `Inspector.sectionSpacing`(16) | **已在第四十五轮按稿实现**（三段 hairline，动作区固定在底部） |
| Inspector 宽度 | 300（帧面板 267 = 300 − 2 × 16） | `Layout.inspectorWidth` 360（最小已是 300） | **第六十轮结案**：维持 360——详情列含应用自有的「试听文案」一段，稿的 300 是给没有那一段的版本画的（§12.4 决定 16） |
| 列表选中行底色 | `#DCE9EE`（`surface/railTint`） | 系统 `List` 自带高亮（离屏 `#DCDCDC`；**活跃窗口实测 `#007CE7`**） | **第六十轮结案**：按稿采纳为 §5.4 的显式特例（§12.4 决定 15）——系统那一档在两种窗口状态下都不跟随稿与本 App 的强调色 |

**⑥ 本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error、`git diff --check` 干净；
预览包已按本轮源码重建并**覆盖安装**（sha256 `c338b8c3…`，二进制内含本轮新符号
`RowActionGlyph` / `previewWrapInsetY`，回退点见 §12.4），启动后主进程与 `…local-control.xpc`
均起来。**未运行单元测试与 UI 自动化**，**未桌面走查**。

#### 第四十五轮：Inspector 按稿分段，并修回一条被重复画出的 hairline

**① 结构**。稿 `main.js` 1584–1641 的 Inspector 是**一条竖列、段间整宽 1pt hairline**：
`sideHead`（`Title / Page` + `Caption`/`text/tertiary`，`gap 4 / padX 16 / padY 16`）→ hairline →
`previewWrap`（`padX 16 / padY 14`，内含 `preview` 面板）→ hairline → `sideBody`（取值行 + 描述）→
hairline → `actions`（`padX 16 / padY 14`，**压在最底部、不随内容滚动**）。应用此前段与段之间没有
分隔线（只用 16pt 间距），动作区还跟着内容一起滚。改后离屏实测色带（`--inspector`，360 × 900、2x）：

| 带（pt） | 高度 | 对应 |
|---|---|---|
| 0.00–75.00 | 75.00 | 头部（16 + 标题行 + gap 4 + 徽标行 + 16，帧同段 76.0） |
| 75.00–76.00 | 1.00 | hairline ①（头部 / 试听） |
| 89.00–90.00 / 90.00–140.00 / 140.00–141.00 | 1.00 / 50.00 / 1.00 | 试听面板的描边 / 填充 / 描边（§11.6 第四十四轮已校准） |
| 217.00–218.00 | 1.00 | hairline ②（试听 / 取值） |
| 847.00–848.00 | 1.00 | hairline ③（取值 / 动作） |
| 848.00–900.00 | 52.00 | 底部固定动作区（14 + 按钮 + 14） |

**② 头部按稿换档**。稿 `sideHead` 是 `Title / Page` + `Caption`，4x 帧实测标题墨迹
**79.25 × 19.0**（四个汉字 ⇒ 20pt）、徽标墨迹 **87.75 × 9.5**。应用这一块此前整块用
`SectionHeading`（13pt + 12pt），比稿小一到两档，徽标还用二级色。改后离屏实测标题
**82.0 × 20.0**（`Typography.display` = `.title` 22pt，即 §5.5 已记录的「系统文本样式里没有 20，
取最近一档」的 +2pt 残差）、徽标 **38.5 × 9.5**（10pt，四个汉字；帧那一处是 8 个汉字）。
徽标色按 §5.4 的系统语义色映射表取 `tertiaryLabelColor`，浅色离屏实测 **#BDBDBD**；
稿的 `text/tertiary` 是硬编码 `#A1A1A6`，两者相差一档，**不追帧上的那个灰**
（与其他 `inkTertiary` 调用点同一条口径）。

**③ 修回一条重复的 hairline（本轮复测发现的回归）**。改分段时动作区自己带了一个前置
`Divider()`，而 `ScrollView` 之外已经有一条段间 `Divider()`：渲染出来是 **834.00–835.00 与
849.00–850.00 两条整宽 hairline、相隔 14pt**。稿与 `main.js` 在这个位置都只有**一条**
（4x 帧实测 y 820.0–821.0 一条，再 14pt 到按钮上沿 835.0，与 `Inspector.actionPadding` 一致）。
去掉动作区自带的那条后，两轮离屏色带都只剩三条 hairline。

**④ 帧与 `main.js` 的分歧（本轮不改）**：4x 帧的 `sideHead` 徽标是 `系统音色 · 描述生成`
（8 个汉字 ⇒ 与实测的 87.75 一致），`main.js:1589` 是 `系统音色`；同一帧的取值区还把
`变体与模式` 合成一行，而 `main.js:1608` 明确写「变体与模式是两行，不合并」并指向
`macos-app-design-system.md` §4.2.3。**同一页上两处分歧方向相反**，说明这一代帧早于
`main.js`；应用两处都跟 `main.js`（当前一代）。若要以帧为准，只能整页回退到那一代，不能只挑徽标。

**⑤ 试听段多一块内容（第六十轮结案：保留，见 §12.4 决定 16）**：帧的试听段只有面板（80 = 14 + 52 + 14），应用多一段
「试听文案 · n/4,096」+ 输入行（+61pt）。这一段是应用自己的可编辑试听文案，稿上没有任何入口，
`macos-app-design-system.md` §3 已把它记为 Inspector 内容；归入「临时指令导致、可以不与 Figma 一致」。

**⑥ 本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error / 0 warning、
`git diff --check` 干净；覆盖安装见 §12.4。**未运行单元测试与 UI 自动化**、**未桌面走查**。

#### 第四十六轮：圆角改造的离屏取证（容器声明 12、叶面同心推导）

背景：并行线把圆角从「每个元素各自声明」改成「**容器声明一次、叶面同心推导**」——新增 token
`Corner.container = 12` / `Corner.nested = 8`、`Corner.containerShape`（`RoundedRectangle`
`.continuous`）与 `Corner.nestedShape`（`ConcentricRectangle` + `concentric(minimum:)`）、两个共享
修饰符 `speechRailContainerSurface(_:)` / `speechRailFocusRing(_:inset:)`；全仓 0 处裸
`ConcentricRectangle()`，新机制 25 个使用点分布在 5 个文件。那次只做了类型检查、**没有目视渲染**，
本节补上离屏取证。

**方法**：新增探针 `--corners`：一张黑底图（2x）上并排给出**已知半径的参考形状**与**真实容器**
（4 列 × 5 行、单元 160 × 80、间距 24、外边距 24），用同图参考校准抗锯齿的系统性偏移，
再读每个单元左上角的「缺角」像素数与墨迹外框。同图参考：

| 参考形状 | 缺角 | 外框 |
|---|---|---|
| `RoundedRectangle(12, .continuous)` | **161px²** | **15.0 × 15.0** |
| `RoundedRectangle(12, .circular)` | 147px² | 12.0 × 12.0 |
| `RoundedRectangle(8, .continuous)` | 81px² | 10.0 × 10.0 |
| `RoundedRectangle(0, .continuous)` | 0 | — |

**实测**：

| 取样 | 缺角 | 外框 | 结论 |
|---|---|---|---|
| `.control` / `.panel` / `.inspector` | 161px² | 15.0 × 15.0 | **与 12pt `.continuous` 参考逐像素相同** |
| `CardSurface` | 161px² | 15.0 × 15.0 | 同上 |
| `.elevated`（材质） | 161px² | 15.0 × 15.0 | 同上 |
| 叶面，**无容器** | 81px² | 10.0 × 10.0 | = 8pt 参考，**保底 8 生效** |
| 叶面，容器内 inset 0 / 2 / 4 / 6 / 8 / 12 / 16 | 161 / 118 / 81 / 48 / 23 / 0 / 0 px² | 15.0 / 12.5 / 10.0 / 7.0 / 4.5 / — / — | 半径 = **12 − inset** ⇒ 12 / 10 / 8 / 6 / 4 / 0 / 0 |

**两条量出来的口径**（不是推的）：

1. **`.continuous` 与 `.circular` 在同一半径下可区分**：continuous 的缺角**更宽更浅**
   （15.0 × 15.0 / 161px²），circular **更窄更深**（12.0 × 12.0 / 147px²）。所以「圆角是不是 12」
   只有在同一 `.continuous` 参考旁边才读得准，拿面积单独判会把两者看成一回事。
2. **`concentric(minimum:)` 的 `minimum` 只在「容器给不出半径」时兜底，不是对推导值的下限**：
   inset 12（= 容器半径）时推导值是 0，渲染出来就是**方角**，没有被抬到 8。
   ⇒ 任何**内缩 ≥ 12pt 的叶面**放进 12pt 容器都会得到方角。当前调用点
   （`.speechRailField()` / `.speechRailRecessedSlot()`：页内横幅、Inspector 输入、表单字段）
   都没落在这条路径上（它们的容器不是 `containerShape`，因此走保底 8）；
   **这一条要作为新增嵌套时的检查项**。

**真实页面**：配音台 1440 × 900（`--render --window`，2x）的结果条左上角在 8× 放大下圆弧跨度
约 12pt，与容器口径一致。模型管理 / 服务状态的「档位卡 / 结论横幅 / 选中候选卡」走的是同一个
`Corner.containerShape` 路径（`ModelManagementView` 1209、`ServiceOverviewView` 120、
`CreatorSurfaceViews` 1485），但**这几页的离屏整页渲染停在下游数据未就绪的空态**，所以这三处
只有「同一代码路径已被量到 12」的等价证据，逐点像素留给桌面走查。

**与 §5.3 的偏离记为决策（§12.4 决定 5）**：§5.3 原文写「不使用手挑半径」，本次实现是
**显式声明 12 / 8 两个数值**（稿的 `radius/container` / `radius/control`）。这是有意偏离：
`.concentric` 在容器不提供形状时会退化成 0，全应用 18 处 `ConcentricRectangle()` 曾因此一起退化；
「容器声明一处 + 叶面同心推导」既保住了「不逐处手挑」，又让渲染结果确定、可评审。将来的检查点：
**全应用只有 `Corner.container` / `Corner.nested` 两个半径数值**，新增半径必须改进这两个 token，
而不是就地写死。

**同轮验证**：`swiftc -typecheck` 0 error / 0 warning、`git diff --check` 干净、覆盖安装见 §12.4。
**未运行单元测试与 UI 自动化**、**未桌面走查**。`--corners` 的参考形状与真实容器都在**真实但
从不显示、从不激活**的 `NSWindow` 里离屏量测（只设 `contentView`，不 order / 不 makeKey /
不 activate，另加 `alphaValue = 0` 与 `ignoresMouseEvents`）。

#### 第四十七轮：按钮档位收口（18 处落在系统默认 24pt 的标准按钮）

**① 口径本来就有，是执行漏了**。§11.6 第二十一轮为「稿的控件高度」定过映射：稿的主按钮
34pt、次按钮 30pt（Figma `size/control`），系统 `ControlSize` 本机实测 `.regular` 24 /
`.large` 28 / `.extraLarge` 36，于是**主按钮取 `.extraLarge`、次按钮与危险按钮取 `.large`、
安静按钮留 `.regular`**，统一由 `speechRailButton(_:)` 施加
（`macos-app-design-system.md` §5 也写着「按钮高度一律走 `SpeechRailButtonAppearance`」）。
但全仓 21 处裸 `.buttonStyle(...)` 里，有 6 处只写了样式、没有跟 `.controlSize`：它们落在
系统默认的 **24pt**，比稿的主按钮小 10pt、比次按钮小 6pt。

**② 本轮收口 18 颗**（`CreatorSurfaceViews` 16 / `PreflightDiagnosticsView` 2）：把
「标准动作按钮」按语义接进 `speechRailButton(_:)`——主按钮 `.primary`、次按钮 `.secondary`、
静默行内动作仍 `.quiet`。涉及 Inspector 动作区（去配音台 / 重命名 / 编辑描述 / 删除）、
两个弹窗页脚（保存到音色库 / 重命名及其取消）、三处空态 CTA（去音色创作 / 重新加载 /
去配音台）、配音台失败卡的（重试 / 查看诊断，稿 `main.js` 914–915 把这一对都画成次级）、
预检全过结论的（重新运行预检 / 查看检查明细）、以及作品 Inspector 的（重命名 / 删除）。
删除按钮**保留 `role: .destructive` 给无障碍，视觉走次级档**——帧上这三颗是同一个
`secondaryButton`，没有单独的红底。

**③ 离屏实测（`--inspector`，2x）**：

| 量 | 改前 | 改后 | 帧 |
|---|---|---|---|
| 动作区色带（系统音色，只有「去配音台」） | 52.00 = 14 + **24** + 14（第四十五轮实测） | **64.00** = 14 + **36** + 14 | 59.00 = 1 + 14 + 30 + 14（该行是三颗次级按钮） |
| 动作区色带（自定义音色，多一行三颗） | 88.00 = 14 + 24 + 12 + 24 + 14（按同一分解式推得） | **104.00** = 14 + 36 + 12 + **28** + 14 | — |

主按钮 36 / 次按钮 28 与稿的 34 / 30 各差 2pt，是第二十一轮已记录的「取最近一档」残差；
改后两者都在 ±2pt 内，改前是 −10 / −6。

**④ 同轮记录、未擅改（待拍板）**：帧的 Inspector 动作区是**一行三颗次级按钮**
（59pt），应用在它上面多了一颗主按钮「去配音台」，动作区因此是 104pt。这颗按钮
`AppRoute.dubbing` 没有负载、不携带当前音色，与侧栏/菜单栏的「配音台」入口重复，
帧与 `main.js` 都没有它；但删入口属于**减功能**，与前一轮「我的作品行省略号」同一条口径。
**第六十轮结案：保留**（§12.4 决定 16）；要按帧去掉只需删那一块，动作带会从 104 回到稿的 88。

**⑤ 本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error / 0 warning、
`git diff --check` 干净；覆盖安装见 §12.4。**未运行单元测试与 UI 自动化**、**未桌面走查**；
空态与弹窗态的按钮高度只有「同一 `speechRailButton(_:)` 代码路径已在 Inspector 上量到
36 / 28」的等价证据。

#### 第四十八轮：控件形状改为固定 8pt（`Corner.controlShape`），并补上第四十六轮遗留的目视缺口

**① 同心推导在深内缩处必然退化成方角**。第四十六轮把「容器声明一次 + 叶面同心推导」立起来，
离屏实测的规律是**叶面半径 = 容器半径 − 到容器边的内缩**：内缩 0/2/4/6/8 → 12/10/8/6/4，
内缩 ≥ 12 一律 0。而 `ConcentricRectangle(corners: .concentric(minimum:))` 的 `minimum`
只在**容器给不出半径**时兜底，**不是**推导值的下限——所以卡内（`Layout.cardInset = 20`）
的**输入槽**、按钮标签上的**键帽**、图标框这类控件全都是**方角**，与旁边的系统胶囊按钮、
系统文本框并排读起来像两个体系。

**② 收口：表面跟随容器，控件固定取值**。新增
`Corner.controlShape = RoundedRectangle(Corner.nested = 8, style: .continuous)`，不参与推导；
**表面**（行选中底、卡片、面板）继续用 `Corner.nestedShape` 同心跟随（它们贴容器边，
同心才有意义），**控件**（输入槽、键帽、图标框）改走 `controlShape`。
`speechRailField()` / `speechRailRecessedSlot()` 两个修饰符落在同一个 `SpeechRailSlotModifier` 上，
全仓 11 个调用点（配音台输入槽、音色创作的参考文案与保存名、诊断详情槽、作品 Inspector、
运行监控等）一并归位。**本轮只归位几何**：两者的区别在第五十一轮才补上——`showsBoundary`
让「有边界」等于「可输入」，11 个调用点里 9 个是可编辑输入、2 个是状态/操作条。
半径数值仍是 `Corner.container = 12` 与 `Corner.nested = 8` 两个，
取 8 的出处是 Figma kit 的 `radius/control` / `radius/field`（§5.3 审计行）。

**③ 主按钮的快捷键提示不再自造键帽**。旧稿的 `kbd` 键帽挂在按钮**左边**，自带填充与 1pt 描边、
又不可点击，读起来像「按钮旁边还有一颗按钮」；它离容器边 20pt，正好落进上面那条退化到方角。
快捷键只对这一颗按钮生效，于是改为长在按钮标签上：沿用按钮自己的前景色降一档透明度
（`Button.shortcutOpacity = 0.72`，`ButtonShortcutHint`），不另画底色与描边，并对辅助技术隐藏
（按钮自己的 `accessibilityLabel` 已经说明了这个快捷键）。

**④ 同轮补上第四十六轮遗留的「没有目视渲染」缺口（离屏实测，仍不是桌面走查）**：

- **机制网格 `--corners`**：四个容器面（`.control` / `.panel` / `.inspector` / `CardSurface`）
  的缺角全是 **161px² / 15.0 × 15.0**，与同一张图上的
  `RoundedRectangle(cornerRadius: 12, style: .continuous)` 参考**逐像素相同**；
  同为 12pt 的 `.circular` 是 **147px² / 12.0 × 12.0**、8pt continuous 是 **81px² / 10.0 × 10.0**、
  0pt 没有缺角。四个参考互不重叠，所以这条结论不是「看着像 12」。
- **真实页面（用户截图里那三处方角）**：探针新增 `--overview` / `--models` / `--center` 的取数
  （此前这两页只能渲成「正在读取…」加载态，容器从来没在整页里出过图）。
  **服务状态页的结论横幅**沿左上角逐行量：直边 x 267.5、上边 84.5，offset 2.5/3.5/5.5/7.5/9.5pt
  处的内缩是 4.0/3.0/1.5/0.5/0.0，与同一张图上的 12pt continuous 参考**逐行吻合（≤0.5pt）**。
  **模型页的选中档位卡**（1pt 强调色描边 + 淡色填充）同样吻合（≤0.5pt）。
- **选中候选卡**：它用的是同一个 `.speechRailSurface(.control)`（容器声明）+ 选中态
  `Corner.containerShape.stroke(lineWidth: 1)`，与上面那张档位卡是同一构造；探针够不到它的私有
  `selectedSlot` 状态，所以这一处只有**代码等价证据**，没有独立像素图。
- **第四十八轮自己的控件形状**（独立探针 `slotprobe`，只依赖 token 文件，不带任何 App 探针补丁）：
  同一张 200 × 84 的卡（内缩 `cardInset = 20`）里并排画两样东西——**控件** `.speechRailField()`
  沿左上角逐行量的边缘与同图上的 1pt 描边 8pt continuous 参考**逐行相差恒定 0.5pt**
  （offset 0/0.5/1.0/1.5/…/6.0 处内缩 6.0/4.5/3.5/3.0/…/0.0），恒定差值来自
  「白描边压黑底」与「浅描边压白底」的抗锯齿差异，**形状同一条曲线**；而**表面**用
  `Corner.nestedShape` 时是**方角**（offset 0.5 处内缩就是 0）——那正是本轮之前**控件**的渲染结果。
  图见 `/tmp/sr-dub/slotprobe.png`。

**⑤ 取证对象的口径**：④ 里的页面图来自 `/tmp/sr-dub/src` 的 **08:54 源码快照**，
也就是 09:42 覆盖安装的那一版（用户实际看到的那一版）。`controlShape` 只存在于工作区，
**未构建、未安装**；它的渲染由上面那条独立探针直接覆盖（该探针从**工作区**的
`SpeechRailDesignTokens.swift` 编译，不是快照）。

**⑥ 本轮验证**：`swiftc -typecheck`（macOS 26 SDK，App 全部源码）0 error / 0 warning。
**未运行单元测试、未运行任何 UI 自动化、未桌面走查**；离屏量测一律在「真实但**从不显示、
从不激活**」的 `NSWindow` 里进行（只设 `contentView`，不 order / 不 makeKey / 不 activate，
另加 `alphaValue = 0` 与 `ignoresMouseEvents`）。

#### 第四十九轮：头部（工具栏）收敛成一个系统，逐页去重

**背景**：用户要求「对每一页的头部工具栏做精心设计」，并提三个问题——这个菜单真的有用么、
它符合最佳实践么、整个头部布局是不是已经最优。本轮先取证再改判，§6.1 / §6.2 / §6.3 已按结论重写。

**① 取证（2026-09-16 10:00 前后，只读）**

装机件是 `~/Applications/SpeechRail.app`（二进制 mtime 09:42，版本 2.6.4 / 8），截图取自 09:47；
源码事实取当前工作树。八个页面共用同一个 `WorkspaceActionsMenu`，菜单项共 24 条：

| 页面 | 本轮之前的「更多操作」内容 | 判定 |
|---|---|---|
| 配音台 | 刷新服务状态 / 开发者详情 | 两条都与本页主对象（文稿）无关 |
| 音色创作 | 刷新状态 / 开发者详情 | 同上 |
| 音色库 | 刷新音色列表 / 新建音色 / 详情 | 「新建音色」在列表页脚已有同一入口 |
| 我的作品 | 导出选中 / 在 Finder 中显示 / 重命名 / 删除 / 详情 | 与行内「⋯」、右键菜单逐条重复，导出另有 ⌘E |
| 服务状态 | 刷新 / 开发者详情 / 启动 / 停止 / 重启 | 启停重启是这一页的主动作，却藏在通用标签下 |
| 运行监控 | 刷新监控 / 复制监控摘要 / 详情 | 该页 `.task` 每 5 秒自动采样，「刷新监控」是死重 |
| 模型 | 刷新模型状态 / 开发者详情 | 下载/校验/应用档位都在卡片里 |
| 诊断 | 复制脱敏报告 / 详情 | 「复制」有效；重新预检在页头次按钮与空态主按钮上 |

**24 条里 19 条是重复或全局动作**（开发者详情 ×8、刷新 ×6、新建音色 ×1、我的作品 ×4）。
另外三条结构问题：页面名同时出现在工具栏 principal 与正文 H1（同一屏出现两次，约 100pt 垂直内），
且工具栏用 `workspaceTitle`（模型管理 / 系统诊断）、侧栏与正文用 `title`（模型 / 诊断）；
同屏两个搜索框（侧栏导航搜索 + 页面内容搜索，外观相近、作用域不同）；`⌘R`、`⌘F` 都没有绑定，
而这两件事菜单里都有命令。

**② 改判：头部是一个系统，不是每页各写一遍的装饰**

- **token 收敛到 `Toolbar`**（`SpeechRailDesignTokens.swift`）：只有 `Identity`（页面身份锁：
  固定槽位 280×32、单行、尾截断、最小缩放 0.82）与 `Action`（动作控件：28pt 高、图标 14pt / 18pt 框、
  左右内边距 8、图标与文字间距 4）两档，配 `Typography.toolbarTitle` / `toolbarActionIcon`。
  同时删掉本轮之后无引用的 `Menu.triggerHeight`、`Menu.triggerHorizontalPadding`、
  `Control.workspaceTitleHeight`、`Typography.workspaceTitle`，以及工具栏重写后没有调用点的
  `Toolbar.controlHeight` / `Toolbar.itemSpacing`（工具栏自身高度、槽位间距与窄窗口 overflow
  都归系统，声明了不用只会变成假精度）。
- **身份只有一处**：新增 `PageIdentityToolbarItem(route)`，在窗口组合根
  （`ControlCenterView` 的 detail 工具栏）声明一次；`PageScaffold` 去掉 `route.title` 那行 H1、
  只保留一句话说明（参数 `subtitle` 改名 `purpose`），页面只声明自己的动作。
  页面名统一取 `AppRoute.title`，`AppRoute.workspaceTitle` 删除。
- **动作控件**：`PageActionButton`（图标或图标+文字）与 `PageActionsMenu`（可带具体标题的菜单）
  取代 `WorkspaceActionsMenu`；通用「更多操作」文字标签不再出现，图标控件的无障碍标签一律精确到动作。
- **每页最终头部**：

| 页面 | 身份 | 头部动作 | ⌘R（重新读取当前页） |
|---|---|---|---|
| 配音台 | 配音台 | 无（「生成语音」⌘⏎ 在正文） | 重新读取音色列表 |
| 音色创作 | 音色创作 | 无（生成候选在正文） | 重新读取音色列表 |
| 音色库 | 音色库 | 新建音色（整页唯一入口）+ 工具栏搜索；**音色详情开关在内容列首行尾端**（第六十二轮） | 重新读取音色列表 |
| 我的作品 | 我的作品 | 工具栏搜索；**作品详情开关在内容列首行尾端**（第六十二轮） | 无（本机同步读取，菜单项禁用） |
| 服务状态 | 服务状态 | 服务（启动 / 停止 / 重启） | 重新读取服务状态 |
| 运行监控 | 运行监控 | 复制监控摘要 | 立即采样一次 |
| 模型 | 模型 | 无（下载/校验/应用到档位在卡片里） | 重新读取模型目录 |
| 诊断 | 诊断 | 复制脱敏诊断报告 | 重新运行预检 |

- **开发者详情**：改为八个页面共同绑定 `@AppStorage("speechrail.showDeveloperDetails")`，
  入口只剩 View ▸ ⌘⌥I（设置里也有开关），页面里不再各写一条菜单项；模型页此前是页内 `@State`、
  与 View 菜单脱钩，本轮一并接上。
- **⌘R**：`FocusedValues.reloadPageCommand` 与既有 `selectedWorkCommand` 同一套写法，
  页面声明自己的重读动作，菜单只暴露快捷键（§6.3 已补表）。
- **搜索**：侧栏 `.searchable(placement: .sidebar)` 与空态 `ContentUnavailableView.search` 删除，
  窗口里只留内容搜索（音色库 / 我的作品）。
- **侧边栏切换按钮保留系统那一枚**：见 §6.2 末尾——`.toolbar(removing: .sidebarToggle)`
  改写后的源码（`ControlCenterView.swift` mtime 08:29）确实被 09:42 的装机件包含，
  而 09:47 的截图里按钮仍在，说明该修饰符在这套 `NavigationSplitView` 布局下不生效；
  窗口最小宽 1120pt 里侧栏 240 + inspector 360 本来就紧，收起侧栏是真实需求，故撤回该条。

**③ 验证与未验证**

- 构建：`xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp
  -configuration Debug -sdk macosx -derivedDataPath /tmp/sr-build-check build` → `** BUILD SUCCEEDED **`
  （2026-09-16 10:06）；`… build-for-testing` → `** TEST BUILD SUCCEEDED **`（含本轮改过的
  `SpeechRailAppUITests`）。全程未运行 UI 自动化测试（项目硬约束：需当前用户逐次授权）。
- 未验证（留给桌面走查）：新动作控件（图标按钮 / 带标题菜单）在 Liquid Glass 工具栏里的观感与
  悬停反馈、系统搜索框与浮动间隔的相对位置、去掉正文 H1 后各页的垂直节奏、窄窗口 overflow；
  ⌘R 菜单项文案（取 `reloadPageCommand.title`）在真实菜单里的宽度与禁用态。
  （principal 槽的声明位置**不在**这一列：它仍由组合根声明，与装机件里已验证的机制相同。）
- 仍在的缺口：`⌘F` 未绑定——SwiftUI `.searchable` 没有公开的聚焦 API，聚焦搜索框需要额外的
  AppKit 桥接，本轮不做。
- 另一处有意留着的缺口：头部动作里「复制监控摘要」「复制脱敏诊断报告」「音色/作品详情开关」
  只有工具栏路径，没有菜单栏对应项。`macos-app-design-system.md` 的那条规则针对**高频命令**
  （服务启停、导出等），这三件属低频；若之后要求「工具栏动作一律有菜单栏镜像」，
  再按 §6.3 的做法补 `FocusedValues` 通道。
- 装机件已更新（用户当轮明确授权「替换为你的版本」）：2026-09-16 10:23 先整包备份
  （`SpeechRail-2.6.4-8-installed-20260916-1023.zip`，sha256 `b329baa9…`），再把旧包
  `mv` 到同目录留作第二重回退点，随后用 `ditto` 把 `/tmp/sr-build-check` 的 Debug 产物整包装到
  `~/Applications/SpeechRail.app`（文件清单与旧包逐项相同：17 个文件、零差异；版本号仍 2.6.4 / 8）。
  `codesign --verify --deep --strict` 通过（`valid on disk` / `satisfies its Designated Requirement`，
  ad-hoc 签名在 `ditto` 后仍然有效，未重签）。已装二进制按符号校验确为本轮版本：
  `PageIdentityToolbarItem` / `PageActionButton` / `reloadPageCommand` 各 3 处，
  `WorkspaceActionsMenu` / `workspaceTitle` 各 0 处（第四十四轮起的口径）。`open -g` 后台启动，
  未抢前台；主进程 pid 30314、`…local-control.xpc` pid 30333，20 秒后仍在，
  未产生新的崩溃报告。回退点：`~/Library/Application Support/SpeechRailAppBackups/`
  下的同名 ZIP 与 `.app`（两者都对应 09:42 那一版）。
- **顺带纠正一条旧结论**：§12.3 写的「重新构建需要先接受 Xcode 许可 / 只能 `swiftc` 直编绕开
  `xcodebuild`」在本机已不成立。`xcodebuild -checkFirstLaunchStatus` 仍返回 69，但
  `xcodebuild -project … -scheme SpeechRailApp -configuration Debug -sdk macosx build` 正常完成
  （2026-09-16 10:06 / 10:09 / 10:12 三次 `** BUILD SUCCEEDED **`，`build-for-testing` 一次
  `** TEST BUILD SUCCEEDED **`）。首次启动检查的退出码不能推断构建被阻塞，后续轮次可以直接用
  `xcodebuild`（`-derivedDataPath` 指到临时目录即可，不动用户的 DerivedData）。

#### 第五十轮：表面层级按稿的四级落地（方案 A）

**① 起因**：目标口径是「严格按照设计规范和 Figma 设计稿校准 APP」。而本机实测的三层系统
语义色**逐位相同**（浅色都 `#FFFFFF`、深色都 `#1E1E1E`，见下一节的取证），于是稿的四级在
应用里塌成一级：未选中的档位卡在白底上没有任何边界（用户在装机件截图上也反馈过「看不出
边界」）。这不是某一页的个例，是每一页的底色都差一级。

**② 取值来自帧，不来自推断**（4x 帧、scale 4、逐段扫描，本轮复核）：

| 层级 | 浅色 | 深色 | 帧出处 |
|---|---|---|---|
| 侧栏 | **#F2F2F4** | **#28262A** | `▸ 音色库.png` y=400（x 0–240）——系统 `.sidebar` 材质，**未动** |
| 页面地板 | **#E8E8EA** | **#201E21** | `▸ 服务状态.png` y=100/870、`▸ 音色库.png` y=400 的通槽 |
| 内容卡 | **#FFFFFF** | **#2B292C** | `▸ 模型.png` y=200（三张档位卡 376pt 宽、卡间 12pt、左侧通槽 20pt） |
| 嵌套面板 | **#F5F5F7** | **#232124** | `▸ 音色库.png` y=280 的 Inspector 试听面板（261pt 宽） |

**③ 落地（三处，缺一处都不生效）**：

- `Color.canvas` / `Color.field` / `Color.recessedField` 从「系统语义色」改为
  `dynamicColor(named:lightHex:darkHex:hcLightHex:hcDarkHex:)` 的显式取值（表同上）。
- `SpeechRailSystemSurfaceModifier`（`.control` / `.panel` / `.inspector`）与
  `SpeechRailSlotModifier` 改用 token。**这两处此前直接读 `controlBackgroundColor` /
  `textBackgroundColor`**——只改 token 不改这里，页面上什么都不会变，这是本轮最容易漏的点。
- **窗口详情区铺 `Color.canvas`**（`ControlCenterView` 的 `detail:`）：地板由页面自己声明，
  侧栏材质与工具栏那一行不参与，也不去动 `NSWindow.backgroundColor`。

**④ 一个必须记下来的坑**：资产目录里留着两个**同名的过期 colorset**——`Canvas`
（`#E5E8EC` / `#15171A`）与 `Field`（`#EDF0F3` / `#1D1E21`，浅色甚至是灰的），全仓零引用。
而 `dynamicColor` **优先取资产**，所以三个 token 的 `named:` 刻意取
`SurfaceWindow` / `SurfaceContent` / `SurfaceRecessed`：用同名就会在**真机**上悄悄落回旧值，
而**离屏探针**（不带 Assets 目录）仍然渲染新值——两边会分叉，且只在装机件上才看得出来。
这两个死资产建议后续清掉（本轮不删：不在改动范围内）。

**⑤ 验证（离屏，整窗 + 指定路由；探针本轮新增 `--route <name>`）**：

- 五页（服务状态 / 模型 / 音色库 / 我的作品 / 诊断）× 两种外观逐段扫描：**地板与卡片在两种
  外观下都分开**——浅色 `#E8E8EA` vs `#FFFFFF`、深色 `#201E21` vs `#2B292C`，页面两侧通槽 20pt；
  嵌套层（Inspector 试听面板、输入槽）取 `#F5F5F7` / `#232124`。
- **量测盲区（本轮新记）**：`.inspector` / `.sidebar` 这两列是系统
  `NSSplitViewItem` + `NSVisualEffectView`，borderless 与 titled 两种窗口样式下**离屏都解析不出
  材质**（前者整片白、后者粉底彩边）。所以：**列内内容可信，这两列的底色不可信**。
  Inspector 那一列的底色（帧是白卡 / 深色 `#2B292C`）本轮只做到代码层，需真机目视。
- 模型页档位卡：可见间隔 = 卡间 `sm`(12) + 按钮样式给每张卡左右各 8pt 的内缩 = **27.5pt**，
  而帧是 **12pt**；同一处还有「悬停填充画在卡片不透明底色之后、只在左右各露 8pt」的老问题。
  两条同源，留给下一轮按「填充交给容器、按钮不再自带内缩」一并收口（见 §12.4）。

**⑥ 未验证**：Increase Contrast（本机取不到真实的高对比外观，三个中性 token 的 HC 值先与普通
值同值——四级在 HC 下是否会再次塌成一级，需要真机复核）；真机深色材质；桌面走查；单元测试与
任何 UI 自动化（项目硬约束：需当前用户逐次授权）。

#### 第五十一轮：输入槽的边界语义、按钮内的快捷键提示、文本按宽度截断

**触发**：用户对装机件的两条**系统级**反馈（不是单点）——①「用户一眼根本看不出这是可编辑区」
（截图里红框标了 4 处输入框），并追问「按钮与快捷键文案是否应都在按钮上」「按钮的圆角是否
符合系统统一 token」；②「文本是否可以随着 UI 宽度自然被遮挡，实现随宽度动态展现更多内容」。

**① 两个根因（都不是布局）**

- **输入看不出可编辑**：输入槽当时是 `.textBackgroundColor` + **无描边**，而本机实测三个中性
  系统语义色逐位相同（第五十轮已证），等于没有底色台阶；再叠上多处输入用
  `.textFieldStyle(.plain)`，空输入框在界面上**没有任何痕迹**。稿其实有明确配方：`figma-kit/main.js`
  的 `textField()` 与 `TextField` 组件集 = `fill surface/field` + **1pt `border/strong`** +
  `radius/field`(8)，聚焦态才换 `accent/rail` 2pt。边界不是我们发明的，是漏掉的。
- **文本被钉死在 24 字**：`AppModel.workTitle(for:)` 在**写入时**把作品名截成「首行前 24 字 + …」，
  而 `title` 是持久化字段——窗口再宽也只能显示那 24 个字。这是数据层问题，不是渲染层问题。

**② 改动（5 处）**

1. 新增 `Surface.borderStrong`（稿 `border/strong`：`#C6C6CB` / `#4A484C`），`SpeechRailSlotModifier`
   增加 `showsBoundary`：`.speechRailRecessedSlot()` = **可编辑**（底色 + 1pt 内描边），
   `.speechRailField()` = 状态/操作条（只有底色）。描边用 `strokeBorder` 画在形状内侧，
   **加边界不改变槽的尺寸**。
2. 快捷键提示长进按钮标签：删掉 `KeyboardHint`（自绘键帽：自带填充与描边、在按钮外侧，
   读起来像第二颗按钮），改 `ButtonShortcutHint`（`Typography.secondary` +
   `Button.shortcutOpacity = 0.72`，无底色无描边，`accessibilityHidden`——按钮自己的
   `accessibilityLabel` 已经说了这个快捷键）。**显示在哪有明确口径**：有菜单栏镜像的命令
   （`⌘N`/`⌘E`/`⌘R`/`⌘1–⌘8`/`⌘?`）由菜单栏提示、按钮不重复；只有正文入口的 `⌘⏎`
   才写进按钮标签（它没有菜单项，写在标签上是唯一可发现路径）。
3. `Corner.controlShape`（`RoundedRectangle(8, .continuous)`，不参与同心推导）成为输入槽/图标框
   的控件几何，取值即稿的 `radius/control` / `radius/field`（第四十八轮）。
4. 作品名改「整行落盘、按宽度显示」：`CreativeWork.generatedTitle(fromScript:)` 取首行整行
   （只有超过 `titleMaximumLength = 120` 才截）、`displayTitle` 在**显示时**把旧记录还原成整行
   （**不改磁盘**）、`clampedTitle` 同时用于自动命名与手动重命名；`AppModel.workTitle(for:)` 删除。
5. 「我的作品」所有出现名称的位置（列表行、结果条、Inspector、删除确认、无障碍标签、导出文件名）
   统一改用 `displayTitle`——**包括搜索匹配**（用 `title` 匹配会让用户搜一个界面上明明看得见的词
   却搜不到，那是「显示用整行、匹配用旧值」留下的裂缝）。

**③ 实测（2026-09-16，离屏；探针 `/tmp/sr-r51`，只依赖 token 文件与真实页面，从不显示、从不激活窗口）**

- **边界真的画出来了**：真实页面（音色创作，2126×1946 @2x）在槽左缘逐像素扫：
  `#FFFFFF`（卡片 0–79）→ `#DADADD`(80) → **`#C6C6CB`(81，与 token 逐位相同)** → `#E1E1E4`(82)
  → `#F5F5F7`（槽内）。也就是卡片与槽之间同时有**一档填充台阶**和**一条真正的描边**。
- **对照：系统自己的可编辑文本框反而更弱**。同一张图上的原生 `TextField`（`.large`，200×40）：
  填充 `#FFFFFF`（与卡片**同色**）、边框 `#EDEDED` 且只有 1 设备像素——所以「看不出能输入」
  在本机 macOS 26 上有系统成因，我们的槽现在比系统自带控件更明确。
- **圆角落在 8pt continuous 曲线上**（左上空缺面积，20pt 见方）：输入槽 11.0pt²、
  同图参考 8pt `.continuous` 13.0pt²、8pt `.circular` 12.8pt²、**12pt continuous 29.2pt²**；
  沿上沿的「第一个墨迹」在槽与 8pt continuous 参考上都是 **+6.0pt**，12pt 参考是 +10.0pt。
  真实页面复核同一条：槽的顶边在距左沿 **13 设备像素（6.5pt）** 处到达。
- **按钮的圆角归系统**（这就是「是否符合统一 token」的答案）：原生按钮在这套系统里是**半高胶囊**——
  `.borderedProminent` + `.extraLarge` 实测 88 × 36pt、缺角 **66.8pt²**（= 高度 36 ÷ 2 的胶囊），
  `.bordered` + `.large` 实测 64.5 × 28pt、缺角 **41.2pt²**（= 28 ÷ 2）；两者的形状与 8pt
  continuous 参考（13.0pt²）**明显不同档**。所以自绘键帽放在按钮旁边必然像「另一个体系」，
  这也是把快捷键收进按钮标签的旁证。
- **文本随宽度展开**（我的作品页，真页逐行量标题墨迹终点）：窗口 **900 → x 373.0**、
  **1000 → 476.5**、**1303 → 721.5**、**1600 → 721.5**。最后一档不再增长，说明该标题已经
  完整显示（自然宽度 ≈ 669pt）——而按宽度展开的差别只出现在 1303 之前，正是「窄窗口被截、
  变宽后显示更多」。
- **名称逻辑**（纯逻辑探针，只依赖 `CreativeWorkStore.swift`）：首行 54 字的新作品**整行落盘**
  （不是 24 字）；旧「24 字 + …」记录 `displayTitle` 还原成 54 字；用户自取且以 `…` 结尾的名字
  **不被覆盖**；200 字文稿收敛成 121 字（120 + `…`）且 `displayTitle` 幂等；首行是空行、
  全换行、首行带空格的边界行为与旧实现一致。
- **全仓核对**：11 个调用点里 **9 个 `speechRailRecessedSlot()` 全是 `TextField`/`TextEditor`**，
  2 个 `speechRailField()` 全是操作状态横幅——「有边界 = 可输入」在调用点上也成立；
  `rg '\.prefix\('` 只剩 `clampedTitle` 与导出文件名 80 字上限，**数据层再无写入时预截**。

**④ 未验证**：Increase Contrast（本机把 `NSAppearanceNameAccessibilityHighContrast*` 设到
应用/宿主上后，渲染仍回落到普通浅色——与第三十七轮同一条结论，`borderStrong` 的 HC 值暂与普通值
同值）；真机目视与桌面走查；单元测试与任何 UI 自动化（项目硬约束：需当前用户逐次授权，
本轮只做离屏量测与 `swiftc` 编译）。

#### 附：表面层级（填充台阶）在本机 macOS 26 上塌成了一层 —— 已按方案 A 落地

**① 实测：系统的中性色阶不再分级**。用真实 `NSWindow`（borderless，从不显示、从不激活）
在两个外观下解析 AppKit 语义色（`/tmp/sr-dub/colors3`）：

| 语义色 | 浅色 | 深色 |
|---|---|---|
| `windowBackgroundColor`（应用 `Color.canvas`） | **#FFFFFF** | **#1E1E1E** |
| `controlBackgroundColor`（`Color.field`，容器面） | **#FFFFFF** | **#1E1E1E** |
| `textBackgroundColor`（`Color.recessedField`，输入槽） | **#FFFFFF** | **#1E1E1E** |
| `controlColor` | #FFFFFF | #FFFFFF a=0.25 |

系统自带的分级只剩 `underPageBackgroundColor`（#969696 / #282828，过深）与
`unemphasizedSelectedContentBackgroundColor`（#DCDCDC / #464646，也过深）。
**结论：§5.2「靠填充台阶分离层级」在当前系统里拿不到任何台阶**——这也是并行线在
模型管理页截图里「未选中的卡看不出边界」的根因，不是哪一页的个例。

**② 稿实测的四级（4x 帧 `▸ 音色库.png`，y=400 逐段扫描）**：

| 层级 | 稿 | 应用当前（离屏实测） |
|---|---|---|
| 侧栏 | **#F2F2F4**（`surface/sidebar`，x 0–240） | 系统 `.sidebar` 材质（离屏取不到） |
| 页面地板 | **#E8E8EA**（`surface/window`，侧栏右侧 17.5pt 通槽 + 卡片之间 16pt） | **#FFFFFF**（= `windowBackgroundColor`） |
| 内容卡 | **#FFFFFF**（`surface/content`，1pt `#DCDCE0` 描边 + 左缘约 2.5pt 软阴影） | **#FFFFFF** |
| 嵌套面板 | **#F5F5F7**（`surface/panel`，1pt `#DCDCE0` 描边） | **#FFFFFF**（与卡片同色，只剩描边） |

也就是说：**四级的稿在应用里只有一级**，页面上所有区分都落在 1pt 描边上；Inspector 的
试听面板在白卡里是白底白框（第四十四轮已把这条记为「极性相反」）。

**③ 可评审方案（两个选项，改动都是 3 个 token 值，单次 revert 可退）**：

- **方案 A（推荐，向稿对齐）**：把三个层级从「系统语义色」改为**稿的四处取值**，走应用已有的
  `dynamicColor(named:lightHex:darkHex:hcLightHex:hcDarkHex:)` 机制（`Color.voice` 与
  `Surface.attentionTint` 就是这样做的），并让窗口地板由 `NSWindow.backgroundColor` 承担：
  `canvas` → #E8E8EA / #201E21、`field`（容器面）→ #FFFFFF / #2B292C、
  `recessedField`/嵌套面板 → #F5F5F7 / #232124（`surface/sidebar` 与描边仍交系统）。
  影响面：所有页面的底色与卡片可读性；回退：把三个 `dynamicColor` 换回三行系统色。
  代价：偏离「§5.4 系统拥有中性色阶」这条原则——但那条原则的**前提**（系统分级）已被本机实测否定。
- **方案 B（保持现状）**：继续用系统语义色，接受「卡片靠 1pt 描边分离、没有填充台阶」，
  并把 §5.2 的「填充台阶」改写成「描边分离」，避免文档与渲染继续不一致。

**④ 结论（2026-09-16 更新）**：本节最初只给方案、未擅改。目标口径确定为「严格按设计稿校准」
后，**方案 A 已落地并通过离屏验证**，记录见上一节（第五十轮）；本节的取证保留为落地依据。
方案 B 不再采用：它会把「卡片靠 1pt 描边分离」写进规范，而稿的取值本来就拿得到。

#### 第五十二轮：设置窗口地板铺满内容区；档位卡的间隔与悬停收口

**起因**：第三十三轮把「设置窗口地板」按 4x 帧记为 `#F2F2F4`（`surface/sidebar`）。
本轮在**有窗口**的离屏宿主里把帧与渲染都重测了一遍，发现那条取证量错了带子。

**帧的纵向带谱**（`Menu & Settings.png`，scale 4，x 80–688 逐行取模态色）：

| 带 | y（pt） | 取值 |
|---|---|---|
| 标题栏 + 页签（chrome） | 921–1005 | **#F2F2F4** |
| chrome 下沿 hairline | 1005–1006 | #DCDCE0 |
| 内容区地板 | 1006–1062 | **#E8E8EA** |
| 第一张行卡（三行 × ≈60pt） | 1065–1244 | **#FFFFFF**（卡内 hairline 在 1124 / 1184） |

横向复核（y=1030 / y=1400，整窗宽）：内容区**整条都是 #E8E8EA**，与稿的 `surface/window`
同值，也与主窗口页面地板同值；`#F2F2F4` 只出现在 chrome 那条 **84pt** 高的带子里
（y=960 实测整窗宽 #F2F2F4）。**所以设置窗口的内容地板不是 `surface/sidebar`，它和主窗口
一样是 `surface/window`；`#F2F2F4` 是系统材质画的窗口 chrome。** 第三十三轮那一笔取自
y=940——正落在 chrome 带里，把「窗口 chrome」当成了「内容地板」。据此新加的
`Color.windowChrome`（`SurfaceWindowChrome`）已删除：全仓零引用，从未提交。

**落地（一处）**：`SettingsView.settingsForm` 的地板从 `.padding(16)` **里面**移到
**页签内容区**这一层（`.frame(maxWidth: .infinity, maxHeight: .infinity)` 之后），
并去掉那层 `.padding(Spacing.md)`。

- 去掉 padding 的依据：第三十三轮按「稿的 `content` 帧 `pad: 16`」加了它，但那一轮量的是
  **没有窗口**时的表单区边缘——grouped `Form` 的行在那时不实例化，看不到行卡，于是把
  「地板内缩」记成了「行卡内缩」。本轮在有窗口的宿主里实测：那 16pt 与系统 `Form` 自己的
  20pt 叠起来，行卡距窗口左右各 **39pt**、卡宽只有 562；稿是 **16pt / 608**。
- 地板画在内容区而不是 `TabView` 上：`.background` 挂在 `TabView` 上会被它自己的背衬压暗
  （实测 #E8E8EA → **#E1E1E3**），只有画在内容区里才是稿上的确切值。

**验证（离屏、有窗口、浅色，640 × 454）**：`--settings-window` 整窗渲染——仍是「只建窗、
不 order、不 makeKey、不 activate、`alphaValue=0`、忽略鼠标」的那套。水平扫描 y=300：
**#E8E8EA 从 3pt 到 637pt**（改之前 1–19 与 621–639 是 #F7F7F7 的窗体底色，也就是
「灰底外面又套了一圈白框」）；y=120：行卡 **x 23–617**（宽 594、左右各 20pt）。

**行卡取值：本轮只取证，未改。** 同一台机器上做了一次**裸系统 grouped `Form`** 对照
（探针 `--formprobe plain|hidden|rowbg`，不含任何 SpeechRail 代码）：

| 变体 | 表单区 | 行卡 |
|---|---|---|
| `plain`（什么都不加） | #FFFFFF | **#F7F7F7** |
| `hidden`（照应用的写法 `.scrollContentBackground(.hidden)` + 显式底色 #E8E8EA） | #E8E8EA | **#E1E1E3** |
| `rowbg`（在 `hidden` 之上给每行 `.listRowBackground(Color.white)`） | #E8E8EA | **#E1E1E3**（无效） |

两条结论：①**行卡的填充是半透明叠加**——同一填色在白底上得 #F7F7F7、在 #E8E8EA 上得
#E1E1E3，都约等于背景 −3%；②**`.listRowBackground` 在 macOS 的 grouped `Form` 上不生效**，
所以「把行卡刷成稿的 #FFFFFF」在原生 `Form` 里做不到。设置窗口现在的观感因此是
「比地板略深的行卡」，而稿是「比地板亮的行卡」——方向相反。本轮不擅自改：这一条要么放弃
原生 `Form`、按应用自己的卡片语言（`CardSurface` + `Color.field`）重画三个设置页
（可评审的公共界面变更），要么接受系统的原生观感。另有一个未解疑点：那层半透明填充
可能是 `NSVisualEffectView` 一类**材质**，而本机离屏对材质（`TabView`、`.sidebar`、
`.inspector`）的解析已知不可靠，所以真机上它到底是 #E1E1E3 还是 #FFFFFF，只有真机目视能定。

**仍存的残差**（同一窗口、离屏实测，均需真机目视复核）：①行卡距窗口左右各 20pt（稿 16）——
系统 grouped `Form` 自己那一档，不靠负 padding 去凑；②内容区顶到第一张行卡 **46pt**（稿 59）；
③chrome 带由系统材质画，离屏解析不出真值。

##### 档位卡：底色与状态色收进同一个背景层，间隔回到帧的 12pt

第五十轮记下的两条同源问题（模型页档位卡）本轮一并收口：

1. **可见间隔 27.5pt（帧 12pt）**：`SpeechRailInteractiveButtonStyle` 给每个按钮左右各
   加 8pt 实测内缩，与卡间 `Spacing.sm`(12) 叠起来就是 27.5；左通槽也因此从 20 变成 28。
2. **悬停/按压反馈看不见**：样式把状态色画在**背景**层，而档位卡自己在标签里又画了一层
   不透明底色（`Color.field` / `Surface.selectedFill`），于是状态色只在卡片左右各露 8pt，
   读起来是一条侧向晕边。

**改法（两处，都是加法，默认值保持既有调用点不变）**：

- `SpeechRailInteractiveButtonStyle` 新增三个参数：`horizontalInset`（默认 `Spacing.xs`）、
  `baseFill`（默认 `.clear`）、`corner`（新增 `SpeechRailInteractiveCorner`：`.nested` /
  `.container`）。`backgroundShape` 改成 **底色在下、状态色在上** 的同一个 `ZStack`——
  状态色本身是半透明填色，单独铺一层会让自带底色的卡片在悬停时「白底消失」。
- 档位卡：标签里只留 `.containerShape(Corner.containerShape)`（形状仍由卡片声明，子层的
  `.concentric` 靠它推导），底色与状态色一起交给样式：
  `horizontalInset: 0, baseFill: isSelected ? selectedFill : Color.field, corner: .container`。
  卡片因此**铺满自己的格位**，可见间隔回到 `HStack` 的 12pt。

**离屏验证（`--center --route models`，浅色）**：改前卡宽 354.5 / 间隔 27.5 / 左通槽 28；
改后卡宽 370.5 / 间隔 11.5（布局值 12）/ 左通槽 20。1440×900 下右通槽仍是 37pt——
那是**离屏宿主给纵向滚动条预留的 17pt 槽**（内容不溢出就没有，右列 1404–1440pt 全空，
无滑块）。把窗口拉到 1440×**2400** 让内容装得下，量到的是
**左通槽 20 / 卡宽 376 / 间隔 12 / 右通槽 20**，与帧逐项一致（帧同口径：20 / 376 / 12 / 20）。

**未验证**：悬停与按压的**观感**——离屏没有指针，`onHover` 不会触发；本轮只从代码层
确认了层级（状态色现在叠在底色之上、同形同尺寸）。另外探针不带应用的 `Assets.xcassets`，
所以选中卡的 `Color.rail` 在离屏图里回落到系统强调色（#007AFF）而不是应用自己的强调色——
那一格的颜色不能拿离屏图当证据。

##### 配音台「语速」：帧与 §7.1 冲突时以条文为准

4x 帧的 `speedRow`（`▸ 配音台.png` y=771 逐段扫描）只有三段：

| 段 | 帧实测 |
|---|---|
| 滑块轨道 | x 459.25–590.75（**132pt**，thumb 14） |
| 当前取值 | x 598.75–624.25（自然宽 **25.5pt**） |
| 快捷档位分段 | x 632–779（**147pt**，每条 36.75） |

- `creatorSpeedValueWidth` 32 → **26**：稿就是这串文字的自然宽度（25.5），应用多留了 6.5pt。
  该值是 `minWidth`（下限），字号放大时仍会跟着长，不会截断。
- **`Stepper` 保留**：帧与 `figma-kit/main.js:1342-1360` 都没有它，但 §7.1 的「语速」条文
  写明 `Slider` + `Stepper`（步长 0.1，范围 0.5–2.0）。两者冲突，按「明确条文优先」
  保留，代价是整组比帧宽 28pt；已在代码注释与本文件两处写明这是**有意偏离**，
  免得后来人当成漏改。
- 分段控件宽 **157 vs 帧 147**：系统 segmented 每项自带约 2.5pt 内边距（稿的 `segmented`
  是 `figma-kit` 自绘的近似件，不是系统控件）。这一档按 §5.4「控件交系统」不动。
- 语速整组比帧右移 **3.25pt**：卡片内边距 1.25 + 音色胶囊 2.5，都在既有残差范围内。

#### 第五十三轮：编辑卡是 `surface/content`，边界属于整张卡

**起因**：第五十二轮把「输入槽」的底色从 `surface/panel` 改回稿的 `surface/field` 时，
改的是一个**共享修饰符**。顺着这条线复核发现两件事：那两张页面级编辑卡根本不是表单字段，
而且它们的结构画错了位置。

**① 编辑卡与表单字段不是同一级表面。**

`SpeechRailSlotModifier` 现在有三个 case，各自对应稿的一级表面：

| case | 用在 | 稿的 token | 底色（浅 / 深） | 几何 |
|---|---|---|---|---|
| `editableInput` | 名称、seed、参考文案、重命名这类「卡片里的一格」 | `surface/field` | `#FFFFFF` / **`#1A191C`** | `radius/field`(8) + 1pt `border/strong` |
| `editorCard` | 配音台文稿卡、音色创作描述卡（**整张卡就是那个字段**） | `surface/content` | `#FFFFFF` / **`#2B292C`** | `radius/container`(12) + 1pt `border/strong` |
| `statusBar` | 状态 / 操作条 | `surface/panel` | `#F5F5F7` / `#232124` | `controlShape`，无边界 |

分辨两者的证据是**深色帧**（浅色下 `surface/content` 与 `surface/field` 同值 `#FFFFFF`，
分不出来）：

| 帧（4x） | 实测 |
|---|---|
| `▸ 配音台 · Dark.png` y=175pt 整行 | 编辑卡整卡 **#2B292C**（x 1050–5673），页面地板 #201E21 |
| `▸ 音色创作 · Dark.png` y=175pt 整行 | 描述卡整卡 **#2B292C**，卡内**没有**第二级表面 |

`main.js` 对这两张卡的 `fill` 同样写的是 `surface/content`（`screenDubbing` 的 `editor`、
`screenVoiceDesign` 的 `promptCard`）。所以第五十二轮把编辑卡按表单字段接成
`surface/field` 是错的：浅色下看不出来，深色下整张卡会凹进去一格。

**② 描述卡里不该再套一个输入框。**

`main.js:1448-1452` 的注释是明确条文：「The description box *is* the field: a white input
nested inside a white card only drew two borders around the same sentence.」4x 帧的两个外观
版本都只有**一圈**描边，且**位于卡沿**：

| 帧 | 描边位置 | 卡内 |
|---|---|---|
| `▸ 音色创作.png` y=250pt | x 261–262.5pt = **卡沿**，`#2A4E57` 1.5pt | 单色 `#FFFFFF`，无第二圈 |
| `▸ 音色创作 · Dark.png` y=250pt | x 261–262.5pt = 卡沿，`#4FA4BA` 1.5pt | 单色 `#2B292C`，无第二圈 |

应用此前在 `chrome == .embedded` 时把可写区单独套了 `.speechRailRecessedSlot()`，
于是一张白卡里多出一个内缩 20pt 的框 —— 正是条文里说的那两圈边。

**③ 编辑器卡片的页脚在卡内，不在页面地板上。**

这条三处证据同向，应用此前是错的：

- 帧：`▸ 配音台.png` 的描边实测跨 y 142.5–695.25pt（左沿列，含圆角内缩），
  把正文、分隔线与「62 / 5000 字」行一起圈在同一张卡里；分隔线以上是正文，
  以下是一条页脚带；
- `main.js:1288-1322` 的注释：「The counter belongs to the field it counts, so the
  information line lives inside the same card behind a divider instead of floating
  on the page.」；
- §7.1 第 2 条：「编辑器卡片页脚：分隔线之内、卡片底部**一条固定高度的带**」。

应用把 `.speechRailRecessedSlot()` 只套在可写区（正文 + 引导行）上，页脚留在槽外的
页面地板上，卡内分隔线也因此成了「槽的下边缘」。**本轮的改法**：`chrome == .card` 时
把底色与 1pt 边界移到**整张卡**（正文 + 分隔线 + 页脚带）上，焦点环同理；
`chrome == .embedded` 时不画自己的表面，由外层那张卡承担
（`CreatorSurfaceViews.swift` 的 `promptCard` 因此改用 `.speechRailEditorCard()`）。

**④ 帧那一圈 `accent/rail` 1.5pt 描边**：本轮**没有**跟。理由是这一帧属于更早的一代，
三条同源证据：同一张 `▸ 配音台.png` 里其他卡片的描边是 `#DCDCE0` 1pt，而当前脚本的
`card()` 帮助函数已经把卡片描边整个去掉了（`stroke: o.stroke || null`，注释直接引 §5.2）；
帧的编辑卡高度实测 **568.5pt**，正是 §7.1 记录「2026-09-15 用户复核：原『占满剩余高度』
会把三行文稿拉成一屏白板」要治的那个旧行为（现行为 `contentDriven(144…360)`）。
所以这一代的描边样式整体不是当前口径；边界仍按第五十一轮的决定取 1pt `border/strong`。
**第五十九轮结案：维持条文**（§12.4 决定 14）；这一条仍是一行可回退的判断
（`SpeechRailSlotKind` 的 `editorCard` 分支）。

**离屏验证**（`--center --route dubbing / voiceDesign`，1440×900，浅色 + 深色，2x 位图）：

| 检查 | 改前 | 改后 | 帧 |
|---|---|---|---|
| 配音台卡内 | 正文 1 圈边、页脚在卡外 | 整卡 1 圈边，分隔线 + 页脚带都在卡内 | 同 |
| 配音台卡高 | 101pt（正文 + 页脚外的带） | **141.5pt**（= 下限 144 减边框） | 568.5pt（旧一代的「占满高度」，按 §7.1 不跟） |
| 音色创作卡内 | 卡沿 1 圈 + 内缩 20pt 第二圈 | **只有卡沿 1 圈** | 同 |
| 深色卡面 | `#1A191C` | **`#2B292C`** | `#2B292C` |

同一批离屏差分（`r63` 版 ↔ 本轮，八个路由 × 浅深两态逐像素）显示改动只落在配音台与
音色创作两页；音色库、我的作品、服务状态、运行监控、模型、诊断**逐像素不变**，
包括两个状态/操作条（它们的 `statusBar` case 仍取 `surface/panel`）。

**未验证**：焦点环落在整卡上之后的观感（离屏无指针、也未真的聚焦过）；Increase Contrast
下新增的 `inputField` 取值（`hc*` 暂与普通值同值，与第五十一轮同一条限制）；真机目视。

#### 第五十四轮：两块「侧边栏」收成一个结构声明点，并修回试听面板的表面层级

范围：音色库与我的作品两页右侧的 `.inspector` 详情面（用户口径「两页的侧边栏」）。
本轮不改公共接口、不改运行态，也不动其他六页的「开发者详情」面板（那是另一套契约）。

**① 两块侧边栏此前是两套结构。** 音色库按稿落地了四段（`sideHead` → `previewWrap` →
`sideBody` → `actions`，段间整宽 hairline，动作区压在最底部；第四十五轮），我的作品则是
另一套：`SectionHeading`（`Heading / Section` 13pt + `Callout` 12pt）当标题带、唯一那条
`Divider` 被 16pt 内边距缩进、试听/导出/在 Finder 中显示散在正文里、重命名与删除夹在
取值行与「技术上下文」之间**随内容滚动**。同一个窗口里两块侧边栏读起来像两个体系。

**改法**：新增 `SpeechRailInspectorPanel`（`WorkspaceComponents.swift`，与
`DeveloperInspector` 并列）作为这两页侧边栏的**唯一结构声明点**——身份带
（`Typography.display` + `Typography.caption` 徽标）→ 整宽 hairline → 试听段 →
hairline → 取值段 → hairline → 固定动作区（`Inspector.actionPadding`，在 `ScrollView`
之外）。两页各自只提供 `preview` / `body` / `actions` 三段内容，段落顺序、内边距与
字号档不再有第二个声明点。我的作品因此拿到：身份带换档、取值段与文稿归并、动作收进
底部固定区（`导出…` 主按钮 + `在 Finder 中显示 / 重命名 / 删除` 次级行），
试听段用与音色库同一个嵌套面板（`play` 图标按钮 + 波形原语）。

**② 试听面板此前与栏目同色，嵌套关系没画出来。** 稿的 `preview` 是 `surface/panel`
（`#F5F5F7` / `#232124`），token 注释也一直这么写；而代码里用的是 `Color.field`，
Inspector 这一列自己的底色又是 `Color.field`（`Surface.inspectorFill`），于是面板只剩
一圈 1pt 描边、读不出「比所在卡片低一级」。改后填充走 `Color.recessedField`
（`speechRailInspectorPreviewPanel()`，描边与半径同处声明）。

**③ 同一块面板里的字段标签有两个字重档。** 「试听文案」用 `Caption / Medium`
（`captionMedium` 10pt Medium），「描述」却用 `caption`（10 Regular）。稿 `sideBody` 的
字段标签统一是 `Caption / Medium`，两处改齐（我的作品的「文稿」页签同档）。

**④ 动作区搬出 `ScrollView` 之后，展开「技术上下文」会把正文区压掉一半。**
`SpeechRailDisclosureGroupStyle` 的标签原来是 `ZStack { Color.clear; HStack }`：`Color.clear`
接受任意高度提案，于是那一行、整条按钮、**进而整个动作区都带上了竖直弹性**。动作区此前
住在 `ScrollView` 里，这个弹性被滚动容器吸收；本轮它成了 `ScrollView` 的**兄弟节点**，
两个弹性孩子按 SwiftUI 的规则平分栏目高度——离屏实测（`--works-inspector`，
360 × 900 / 720，打开「显示开发者详情」）：正文区 `642 → 296.5`（900 高）、
`462 → 206.5`（720 高），动作区下方留出 `360pt` / `270pt` 纯空白。整宽提案本来由标签自己的
`.frame(maxWidth: .infinity)` 给（`Color.clear` 是冗余的），去掉这一层后：
**900 高：正文 586 + 动作 160；720 高：正文 406 + 动作 160**（未展开时两页逐项不变）。

**离屏验证**（`--inspector` / 新增 `--works-inspector`，`Layout.inspectorWidth` × 900，
浅色 + 深色，2x 位图；我的作品探针只放一条 fixture，不读本机真实作品目录）：

| 检查 | 改前 | 改后 | 稿 |
|---|---|---|---|
| 音色库 · 试听面板填充（浅 / 深） | `#FFFFFF` / `#2B292C` | **`#F5F5F7` / `#232124`** | `#F5F5F7`（`surface/panel`） |
| 音色库 · 试听面板带宽 | 50.00pt（y 90–140） | **50.00pt（y 90–140，不变）** | 50.0（波形 30 + 上下各 10） |
| 音色库 · 三条段间 hairline（+ 试听面板自带两条描边） | 75/76、217/218、835/836（描边 89/90、140/141） | **逐条不变** | 76.0 / 76+… / 820.0（窗口下沿 900） |
| 我的作品 · 身份带 | `SectionHeading` 13pt + 12pt | **75.00pt（= 音色库同一段）**，标题 20pt 档 + 徽标 10pt `inkTertiary` | 稿同一段 76.0 |
| 我的作品 · 试听面板 | 无（只有两颗裸按钮） | **填充 48.00pt（y 90–138，#F5F5F7 / #232124）**，与音色库同形 | 稿 `preview` 面板 |
| 我的作品 · 段间 hairline | 1 条，且被 16pt 内边距缩进 | **3 条整宽**（y 75/76、152/153、795/796；试听面板自带的描边另在 y 89/90、138/139，按 `contentPadding` 内缩 16pt） | 稿 inspector 的四段 |
| 我的作品 · 动作区 | 散在滚动内容里 | **固定在最底部（y 796–900，104pt = 14 + 主按钮 36 + 12 + 次按钮 28 + 14）** | 稿 `actions` 24：… `padY 14` 压底 |
| 两块侧边栏 · 720pt 高窗口 | — | **动作区仍压底且高度不变**（音色库 656–720 = 64pt、我的作品 616–720 = 104pt），滚动段按差值收缩（437 / 462） | 最小窗口 1,120 × 720 |
| 两块侧边栏 · 展开「技术上下文」（`④` 修复后） | 正文区被压到栏目的一半，动作区下方留白 360pt / 270pt | **正文 586 / 406，动作 160**（= 14 + 主按钮 36 + 12 + 次按钮 28 + 12 + 展开行 44 + 14） | 渐进式披露不改变四段结构 |

两页侧边栏的预览面板在两种外观下**逐像素同形**（描边带 x 23.0–336.5pt、填充带同宽），
这是「共用一处声明」的直接证据。

**未验证**：`borderedProminent` 主按钮在离屏图里取不到强调色填充（探针不带
`Assets.xcassets`，与第五十二轮同一条限制），所以两页主按钮的视觉差异要真机确认；
悬停/按压观感、VoiceOver 顺序、单元测试与 UI 自动化（按 AGENTS.md 需当次授权）。

#### 第五十五轮：页面身份从 `.principal` 移到 `.navigation`（修跨页横跳 135pt）

**① 起因与取证手段**：用户把头部工具栏这一行交回本轮统一负责（此前归并行轨道）。
头部不在 `contentView` 里，此前所有离屏图都没有那一行；本轮给探针加 `--hier`——
把 `NSWindow` 主题框架视图树里**落在窗口顶部 60pt 的每一层**按窗口坐标打出来
（`NSThemeFrame → NSTitlebarContainerView → NSToolbarView → NSToolbarItemViewer → …`）。
仍然只创建、只读，不 order / 不 makeKey / 不 activate。

**② 顺带纠正一条取证方法**：`--theme` 把主题框架 `cacheDisplay` 成 PNG 的做法
**只在部分路由可用**——本轮八路由实测，`models / overview / monitoring / voiceDesign`
缓存出来是黑图（内容区整片 `#000000`，只剩侧栏一条白带），`dubbing / voiceLibrary / works`
正常。凡以主题 PNG「逐像素相同」为依据的结论都不成立（黑图当然等于黑图）。
下面凡涉及落点的结论一律取自视图树，不取主题 PNG。

**③ 事实：`.principal` 的落点是「剩余空间的中点」，会随页面的工具栏搜索框漂移。**
1440×900，浅色，八路由（`probe.r69`，当前工作树 + 探针补丁）：

| 路由 | 身份槽 viewer x / w | 该页头部右侧 |
|---|---|---|
| 配音台、音色创作、服务状态、运行监控、模型、诊断 | **700.5 / 288** | 动作最多一枚图标按钮（x 1392 w 44），无搜索框 |
| 音色库、我的作品 | **565.5 / 288** | 「新建音色」x 909.5 w 94 + 详情开关 x 1003.5 w 44 + 搜索框 x 1103 w 333 |

即：**切换页面时页面身份横跳 135pt**——而它是全 App 唯一一处「我在哪一页」的锚点。
窗口收到最小宽 1120pt 时同样跳 135pt（模型 540.5 / 音色库与我的作品 405.5），
且此时搜索框被系统压到 260.5pt，两侧浮动间隔只剩 8pt。

**④ 改法**：`PageIdentityToolbarItem` 的 `.principal` → `.navigation`，
`WorkspaceTitleLockup` 槽内 `.center` → `.leading`。同一个探针实测（`probe.r75` = 改后工作树）：

| 检查 | 改前 | 改后 | 判定 |
|---|---|---|---|
| 身份槽 x（八路由，1440×900） | 565.5 / 700.5（两值） | **252.0 / 288（八页同一个值）** | 恒定 |
| 身份槽 x（八路由，1120×720） | 405.5 / 540.5 | **252.0** | 恒定 |
| 身份槽 x（抽查音色库 / 模型 / 诊断，1920×1080） | — | **252.0** | 与 1440 同点，不随窗口宽漂移 |
| 槽内内容起点（icon 墨迹） | 由内容宽度决定（组居中） | **约 260**（盒 252 + 系统内缩 4 + 图标墨迹偏移 4） | 与帧的 78 不同，见 ⑤ |
| 侧栏收起时（`.detailOnly`） | — | 148.0（随系统侧栏按钮一起左移，按钮本身 x 100） | 与系统同步 |
| 内容层（八路由内容缓存逐像素差分） | — | **完全相同**（0 个差异像素） | 改动只落在窗口 chrome |

**⑤ 为什么不跟帧的 78pt**：稿 `titlebar`（`main.js:1208-1226`）是「红绿灯 + 12pt + 图标 + 标题」
的整宽横带，4x 帧实测标题墨迹从 101pt 起（图标盒 78pt、标题带高 48pt、底色 `#F2F2F4`）。
那一格正是**系统侧栏切换按钮**的位置（x 201 w 47 展开 / x 100 w 48 收起）。本轮用视图树
独立复核了 `.toolbar(removing: .sidebarToggle)`：带与不带该修饰符的两次渲染里，
`com.apple.SwiftUI.navigationSplitView.toggleSidebar` 与它 38.5pt 的宿主视图都在 x=201、
`top=11.5`，逐项相同——修饰符不生效，无法腾出那一格。要拿到 78pt 只能自绘标题栏，
而 §5.2 / D1 已定「工具栏层归系统」（自绘会失去 macOS 26 的玻璃、内容透出与 scroll edge
effect）。因此取系统能给到的最左位置：详情列左沿。标题带高 52（系统）vs 帧 48、
底色（系统材质）vs 帧 `#F2F2F4`，同属既有决定，本轮不改。

**⑥ 与正文左沿的关系**：详情列左沿 248pt，系统给该项内缩 4pt → 盒 252、内容 256；
页面正文内边距 `contentPadding = 20` → 正文 268pt（本轮在配音台内容缓存上实测 268.5）。
图标墨迹约 260–272，落在正文左沿一带；标题文字 279 起。与帧一样，标题不与正文共用左基线，
没有额外的对齐规则。

**⑦ 验证**：`swiftc -typecheck`（Swift 6 + strict concurrency，整个 `SpeechRailApp` 源码集）
exit 0 / 0 error；`xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj
-scheme SpeechRailApp -configuration Debug -sdk macosx -derivedDataPath /tmp/sr-build-mine build`
→ `** BUILD SUCCEEDED **`（2026-09-16 12:14）；八路由 × 浅色的内容缓存与改前**逐像素相同**；
1120×720 下八页身份槽恒在 252、右侧动作与搜索框无重叠。

**⑧ 装机件**（沿用本轮既有授权与流程）：12:14 优雅退出旧 App → 整包备份为
`~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260916-1214.zip`
（sha256 `a4845690…`，即第五十四轮装的那一版）→ `ditto` 把 `/tmp/sr-build-mine` 的 Debug 产物整包装到
`~/Applications/SpeechRail.app`（文件清单与旧包逐项相同）→
`codesign --verify --deep --strict` 通过（`valid on disk` / `satisfies its Designated Requirement`）
→ 已装二进制 sha256 **`a0bedb84…`**（旧包 `ee9b24d5…`），版本仍 2.6.4 / 8 →
`open` 后主进程 pid 45597、`…local-control.xpc` pid 45610，仍在。
（12:14 先装过一版 `e16dbc81…`，随后两处注释里的轮次号从 54 改成 55，于是重新构建并整包替换，
使装机件与当前工作树逐字节对应。）
回退点：上面那个 ZIP。

**未验证**：真机目视——离屏宿主是普通 `NSWindow`，**不带** App 场景的
`.windowToolbarStyle(.unifiedCompact(showsTitle: false))`，所以工具栏样式与真机仍可能有别的
差异（落点的相对关系不受影响，绝对值需桌面确认）；悬停与键盘焦点顺序（离屏无指针、无焦点）；
单元测试与 UI 自动化（按 AGENTS.md 需当次授权）。

#### 第五十六轮：圆角机制独立复核 + 端到端构建（2026-09-16）

**① 边界（用户当轮指令）**：音色库 / 我的作品的**侧边栏（右侧详情列与其行内动作）**归并行轨道，
本轮不碰。此前为对齐稿的卡宽在这两处试过的三处改动——新增 `showsActions`、去掉
`.inspectorColumnWidth`、删掉详情列的「去配音台」——**已全部撤回**（现状复核：`showsActions`
全仓无引用、`.inspectorColumnWidth` 与「去配音台」都在原位）。**13:05 / 13:06 这两个文件又被并行
轨道写入**（同一批还有 `SpeechRailDesignTokens` 13:02:08、新文件 `AudioEnvelope.swift` 13:02:20、
`AudioPlaybackController` 13:02:30、`AppModel` 13:03:30，内容是详情列的试听链路），本轮**不读、
不改、不入装机件**（见 ⑨）。留在那一轨的问题与证据见 §12.4 未决项。

**② 圆角机制复核（第四十六 / 四十八轮的机制，本轮换方法独立量测）**：新增两个只读探针工具
（`/tmp`，不入库）——`rects.py` 用**缺角面积法**求半径，`radius_check.py` 用**子像素圆弧拟合**求半径。
先用合成形状标定两条路径：8 / 12 / 18pt 依次量成 8.43 / 12.35 / 18.29（面积法系统性 **+0.35pt**），
拟合法逐位还原。实渲染读数：

| 量测对象 | 机制上的期望 | 实测 | 方法 |
|---|---|---|---|
| 配音台输入卡（容器，`Corner.containerShape`） | 12 | **12.0pt**，四角一致 | 圆弧拟合，rms 0.24pt |
| 音色库列表选中行（叶面，`Corner.nestedShape`） | 推导值 ≤ 0 时落到 8 | **7.5pt**（拟合）/ **8.17pt**（面积法，扣标定后 7.8） | 两法一致 |

即「容器声明一次、叶面同心推导」在离屏实渲染里确实落在 **12 / 8**，第四十六轮之前的方角不再出现；
拟合残差 0.24pt 说明容器那一档半径在本机与圆弧几乎不可分，`.continuous` 与 `.circular` 的观感差
只能真机同屏并排看。**这条只回答「半径是多少」，不回答「好不好看」。**

**③ 端到端构建（把并行轨道「只验到类型层」那条高风险项关掉）**：
`xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp
-configuration Debug -sdk macosx -derivedDataPath /tmp/sr-build-mine build` → `** BUILD SUCCEEDED **`（12:45 全量，
4.6s 的增量构建），产物二进制与**当时的装机件逐字节相同**（`sha256 = a0bedb84…`，`cmp` 无差异）。
一条推论：圆角改造已过链接与资源层；顺带说明第五十五轮末尾那句「12:14 之后还有注释改动」
**不影响产物**——只重签名、未重编译就产出同一个二进制，说明 12:18 那次写入没有改变编译单元。

**⚠️ 更正（13:11 复核）**：上面这条「不需要重装」只对 12:45 那一刻成立。⑦ 在 12:52:57 改了
`SettingsView.swift` 之后又跑了一次增量构建（12:54:19），中间产物里**唯一**晚于 12:40 的
`.o` 就是 `SettingsView.o`（`Build/Intermediates.noindex/…/Objects-normal/arm64/SettingsView.o`，
mtime 12:54:19），即那次只重编了本轮改的文件；产物二进制随之变成
`79e6413e5f4a053f111051258ffefe3885eac34635e14b67905386c32d84d9a1`，与装机件
`a0bedb84…` 不再相同（`cmp -l` 有 1528181 个字节不同——一个编译单元改动会让后续符号地址整体移位，
所以字节差远大于改动面）。**结论：本轮确实需要重装，⑨ 已执行。**

**④ 档位卡悬停层级（更正一条并行轨道的说法）**：并行轨道曾记「悬停填充仍被卡片不透明底色盖住，
只在左右各露一条 8pt 窄带」。当前代码是**已按第五十二轮改法**：档位卡自身只声明形状与选中描边
（`ModelManagementView.swift:1194-1223`，卡上写明「这层只声明形状，底色交给交互样式」），
底色与悬停/按压色由 `SpeechRailInteractiveButtonStyle` 画在**同一个背景层**里
（`WorkspaceComponents.swift:71-112` 与 `:340-365`，`baseFill` + 状态色叠在它上面）。
真机指针悬停的观感仍未验（离屏无指针）。

**⑤ 取证陷阱补充（接第五十五轮 ②）**：`--render` 的 `-img-` 变体走 `ImageRenderer`，本机恒是
**黄底红圈「不可渲染」占位图**，不能当页面图用；`models / voiceDesign / monitoring` 三路由连缓存 PNG
也是全白（页面要的数据在探针里没有）。能出图的只有 `dubbing / voiceLibrary / works / diagnostics`，
凡逐像素比较都只能用这几个路由的**缓存 PNG**（`--theme` 的主题 PNG 另有第五十五轮记的黑图问题）。

**⑥ 诊断行「量不到」解除（第三十九 / 四十一轮那处 5pt 残差已成立）**：诊断行住在 `List` 里，
第三十九轮记的是「无窗口宿主不实例化，整页渲染取不到」。本轮用**有窗口**的离屏宿主拿到了整页
（`R-diagnostics-1440x900.png`，浅色 1440 × 900），逐像素读数：

| 元素 | 应用实测 | 稿（4x 帧 `▸ 诊断.png`） | 残差 |
|---|---|---|---|
| 行首字形墨迹 | 13.0 × 13.0 | 对勾行 12.0 × 8.75 / 三角行 13.5 × 12.0 | 字形差异 |
| 标题墨迹 − 图标墨迹左沿 | **25.0** | 24.25（304.25 − 280.0） | 0.75 |
| 列表 hairline 起点 | 78.0（= 标题墨迹 x） | 卡左沿 + 42 | — |
| 行节距 | 64.0（`pageRowMinimumHeight` 63 + 1pt hairline） | 64.00 | 0 |
| 行尾 chevron 墨迹 | 4.0 × 7.5 | 14pt 框的 lucide `chevron-right` ≈ 4.67 × 8.17 | 0.67 × 0.67 |

即第四十一轮补的「16pt 图标框 + 10pt 间距」（把文字列从 37 拉回稿的 42）**在真实窗口里成立**，
chevron 用应用自己的 `caption` 档（10pt）换稿的 14pt 框，墨迹只差 0.67pt 见方。

**⑦ 设置页「默认语速」行按帧重标（本轮改动）**：4x 帧 `Menu & Settings.png` 实测滑轨
x 1183.0 → 1314.5 = **131.75pt**，与稿的 `sliderControl(p, 132, …)`（`main.js:2463` 定义、
`:2554` 调用）一致；应用此前在这里**就地写 `frame(width: 160)`**，残差 28pt。取值稿写全角
`1.0×`（同页 caption `0.5×–2.0×` 也是全角；帧上 `×` 墨迹 x 2439–2496 可辨），应用写 ASCII `1.0x`。
两处都改：滑块改用已有的 `Layout.creatorSpeedSliderWidth`（132——稿在设置页与配音台是同一个控件、
同一个数值，不再写第二处 132），取值改 `%.1f×`。配音台那一处稿写的是 ASCII `1.0x`
（`main.js:1359`），两页各自按稿，`CreatorSurfaceViews` 不动。

**这一处的取证边界**：设置窗口的 `Form` 行在离屏宿主里**不实例化**——`--host` 只看到
`HostingScrollView`（672 高、文档 250），既没有行也没有 `NSSlider`，所以改后拿不到像素证据，
只有「源码声明 = 稿数值」这一步；最终观感归桌面走查（与第五十一轮行卡底色同一条限制）。

**⑧ 规范对账（本轮顺手做掉的两条）**：①**§5.3 审计行与设计系统文档少列了半径声明点**——
全仓 `RoundedRectangle(cornerRadius:)` 共 5 处，除 `Corner.containerShape`(12) 与
`Corner.controlShape`(8) 之外，还有 `Waveform.barRadius`(1)、`Inspector.previewRadius`(10) 与
`Inspector.previewRadius + 1`(11，描边画在填充外那一圈)；`macos-app-design-system.md` 的
「圆角几何」行曾写「全 App 只有 12 / 8 两个半径数值」，与同一张表「表面修饰」行列出的
`previewRadius` 自相矛盾，已在该文档补一段更正（准确说法：**同心推导那一族**只有 12 / 8，
1 / 10 / 11 只服务单个元素、取自稿值、不参与推导）。②**同一条款下另外三条机械声明仍成立**：
`rtk rg` 复查 `cornerRadius(` 0 处、`ConcentricRectangle()` 0 处、页面文件里的 `Color(red:)` 0 处、
`imageScale` 只剩 5 处注释（第三十九轮的「写法清零」成立）。

**⑨ 装机（13:11，把 ⑦ 的改动送达本机运行件）**：精确 `kill -TERM 77854`（XPC 77855 随之退出）
→ 整包备份 `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260916-1311.zip`
（装前那一版，二进制 sha256 `a0bedb84…`）→ `ditto` 把 `/tmp/sr-build-mine` 的 Debug 产物**整包**
装到 `~/Applications/SpeechRail.app`。装机前先比对过两包的相对文件清单：各 **17 个文件、逐项相同**
（`diff` 无输出），所以 `ditto` 合并不会留残留。装机后：二进制 mtime **12:54:20**、
sha256 **`79e6413e5f4a053f111051258ffefe3885eac34635e14b67905386c32d84d9a1`（与构建产物逐字节相同）**、
`codesign --verify --deep --strict` 通过（`valid on disk` / `satisfies its Designated Requirement`，
`ditto` 之后 ad-hoc 签名仍有效，未重签）、`CFBundleShortVersionString` 2.6.4 / `CFBundleVersion` 8
（未改版本号）。`open -g` 后台启动未抢前台，主进程 **pid 4934** 与
`com.speechrail.desktop.local-control.xpc` **pid 4946** 均在，9 秒后仍存活；`DiagnosticReports`
里与 SpeechRail 相关的最后一条崩溃报告仍是 **09-13**，本轮无新崩溃。

**装的是 12:54:19 那次构建，不是「现在重建」——这是本轮刻意的取舍**：并行轨道在 13:02–13:06
改了 6 个文件（见 ①），其中 `AudioEnvelope.swift` 是全新未跟踪文件、试听链路尚在飞行中，
现在重建会把它们半成品打进装机件。停在 12:54 的产物意味着装机件**恰好**是「工作树在 12:54 的状态」：
包含本轮 ⑦ 的改动，不包含那 6 个文件 13:02 之后的改动。**代价与边界**：装机件因此不含并行轨道的
试听链路——但那些改动本来也不在 12:17 的旧装机件里，所以这不是回退，只是没提前带上。
**回退点**：`…-installed-20260916-1311.zip`（= 12:17 那一版，`a0bedb84…`）；更早的
`…-1214.zip` / `…-1148.zip` / `…-1102.zip` 仍在。
**仍未做**：真机目视 / 桌面走查、任何 UI 自动化（未获当次授权）、单元测试。

**下轮若要再出装机件**：先看那 6 个文件的 mtime 是否还在动（本机 13:13 仍在 13:02–13:06）。
仍不安定时，做法是**把工作树复制到 `/tmp` 再构建**，并把那 6 个文件换回 12:29 的版本
（本轮探测目录里留了 12:29 那一份副本，`AudioEnvelope.swift` 当时还不存在，直接不参与编译即可）；
**不要**在仓库工作树上直接重建，否则会把并行轨道没写完的试听链路打进装机件。

#### 第五十七轮：把「假的」波形换成真实包络与真实进度；试听文案输入槽改多行

范围：音色库与我的作品两块详情面板里的波形，以及音色库面板里的「试听文案」输入槽。
本轮不改公共接口、不改运行态。

> 编号说明：本轮在并行轨道（工具栏身份槽、圆角复核两轮）之后落笔，第五十五 / 五十六轮
> 已被那两条轨道占用，这里取第五十七轮；代码里 `§11.6 第五十七轮` 的引用都指本条。

**① 波形此前是稿上的一张固定图。** 三处 `WaveformBars` 画的都是 token 里的固定高度数组
（`Waveform.resultBar/candidateTile/libraryPreview`，数字直接抄自稿 `main.js:1372/1425/1601`），
播放时只叠一层整块透明度呼吸（§5.7 的「波形脉冲」）。用户 2026-09-16 指出
「侧边栏的播放音波效果是假的」，判断成立：它知道「在播」，但既不知道「在响什么」，
也不知道「播到哪了」——当时全 App 的 `isMeteringEnabled` / `updateMeters` / `installTap` /
`vDSP` **零命中**，播放层就是一个 `AVAudioPlayer(data:)`。

**改法**：给它两条真实通道。

- **幅度包络**（新文件 `AudioEnvelope`）：`AVAudioFile` 分块解码 → 按**整段**位置落
  `Waveform.envelopeBuckets`(32) 个等宽窗口 → 每窗取**峰值**（不是 RMS：波形图的通行读法
  就是逐窗峰值，RMS 会把语音的停顿拉成一片几乎等高的绒面）→ 按整段最大值归一化。
  视图按自己的 `Pattern` 重采样（12 / 16 / 18 根），所以 `pattern.heights` 从此只决定
  **条数与排布**（宽度 / 间隙 / 峰值高度），高度全部来自这段音频。内存里的 TTS 试听数据
  先落到系统**临时目录**再解码、读完即删（`AVAudioFile` 只认 URL）。
- **播放进度**（`AudioPlaybackController.progress`）：20Hz 采样播放器自己的
  `currentTime / duration`，播放中未播到的部分降到 `Waveform.remainingOpacity`(0.35)。
  它不是按固定时长自走的动画——暂停、结束、换曲都跟着变。

缓存：`AppModel` 按 `voice:<id>` / `work:<id>` 各存一份 32 桶包络，解码在
`Task.detached(priority: .utility)` 里做（I/O 加解码不占界面线程）。触发点三处：
试听拿到 TTS 数据时、播放作品时、作品被选中时（`.task(id:)` 先算好，点开详情就能看见形状）。
没有包络时（例如**还没试听过的音色**——那一刻确实还没有音频可画）退回稿的固定数组，
并且**只有这种情形**才保留脉冲：脉冲是「在播但画不出形状」时的状态提示，
一旦有了真实形状与进度，它只会和真实信息打架。

**② 试听文案输入槽是单行的。** 这个槽是应用自有入口（稿上没有，第四十五轮 ⑤），
上限 4096 字；单行字段的宽度由内容决定，于是「详情列多宽」变成「用户打了多少字」的函数。
改多行：`TextField(axis: .vertical)` + `lineLimit(2...5)`（两个取值进 token 层
`Layout.previewTextMinimumLines/MaximumLines`），宽度回给容器，再长由原生编辑器内部滚动。

**③ 两块目录页侧边栏此前没有声明列宽。** `DeveloperInspector` 一直有
`frame(minWidth:idealWidth:maxWidth:)` + `inspectorColumnWidth(...)` + `clipped()` +
`background(Surface.inspectorFill)`，而这两块（第四十五 / 五十四轮写的）没有——列宽因此是
内容的函数。本轮补齐同一套声明（300 / 360 / 440）与显式的 `surface/field` 底色。

**离屏验证**（`--inspector` / `--works-inspector`，360 × 900，浅色 + 深色；探针新增
`--sample <text>`、`--envelope`、`--progress <v>` 三个只存在于 `/tmp` 的参数）：

| 检查 | 改前 | 改后 | 依据 |
|---|---|---|---|
| 面板**理想宽度**（41 字 / 330 字试听文案） | 未声明，随内容 | **360.0 / 360.0** | `NSHostingView.fittingSize`，= `Layout.inspectorWidth` |
| 试听文案槽高度 | 34pt（单行，y 183–217） | **48pt**（2 行，y 184–232）；330 字时 **94pt**（触到 5 行上限） | 两行起、五行封顶 |
| 波形条高（注入线性斜坡包络 1/32…32/32） | 稿的固定锯齿 `[8,16,26,12,…]` | **单调上升**（逐条 = 包络值 × `pattern.height`，下限 `envelopeMinimumHeight` 3pt） | `--envelope`，逐像素截图 |
| 波形进度（`--progress 0.45`，16 根） | 无 | **左 7 根满色、右 9 根 0.35** | 逐像素截图 |
| 包络数学（合成 WAV：四段峰值 1.0 / 0.25 / 0.05 / 0.5） | — | **8 桶 = 1.000 1.000 0.250 0.250 0.050 0.050 0.500 0.500**；`resample 8→4` = 1.000 0.250 0.050 0.500 | 独立 `swiftc` harness（`/tmp`，入库需另授权） |

**未验证**：真机听感与 20Hz 进度的顺滑度（离屏无声卡，进度是注入值）；稿里五处
`waveform()` 现在只有详情面板这处接了真实数据，配音台结果条与音色创作候选卡仍是稿的固定
图形；**峰值**读法在低动态语音上是否足够可读（未听真机）；新增的 `envelopeBuckets` /
`envelopeMinimumHeight` / `remainingOpacity` / `progressInterval` 与
`previewTextMinimumLines/MaximumLines` 尚无组件测试（按 AGENTS.md 需当次授权）；
单元测试与 UI 自动化未运行。

#### 第五十八轮：设置窗口从系统 grouped `Form` 换成应用卡片（§7.10 的 608/16 落地）

**① 先纠正两条取证方法（都会改变结论，先记在这里）**：

1. **titled 离屏宿主会把整页压暗约 2.5%**。同一份源码、同一个页面，用
   `--window --titled` 渲染出来地板是 `#E2E2E4`、行卡 `#DCDCDF`；换成 **borderless**
   宿主（`--window`）后地板正好是 token 的 `#E8E8EA`、行卡 `#E1E1E3`。根因是
   `.fullSizeContentView` + 透明标题栏那层材质在离屏时也叠在内容上。**结论：凡是取色，
   只能用 borderless 宿主**；此前带 `--titled` 的取色都要打折看。
2. **设置窗口能出整页图**（推翻第五十六轮 ⑦ 的「拿不到像素证据」）：`--settings-window
   --window --light --size 640 454 --top` 出的缓存图里，行卡、控件、墨迹全在。
   第五十六轮那次量不到，是因为把 `--top` 省了（不加 `--top` 时外层 frame 按中心对齐，
   内容固有高度小于宿主高度时会被裁掉，缓存出来是一片白）。

**② 帧与现行 kit 脚本对账（两者已经不同代，必须先定权威）**：手上的 4x 帧
（`~/Downloads/speechrail-screens-4x/`，导出时间 09-15 22:08）与仓内 `figma-kit/main.js`
（最后一次写入 **09-16 06:39**）在三处不一致：

| 项 | 09-15 22:08 的帧 | 09-16 06:39 的 kit | 应用取 |
|---|---|---|---|
| 设置·服务页的分组 | 「服务地址 / 控制范围 / 报告包含脱敏服务日志」 | 「服务端口 / 诊断报告包含运行档位与版本」（`paneService`） | **跟 kit**（§7.10 也是 kit 口径） |
| 设置行卡的描边 | 1pt `#DCDCE0`（`border/separator`） | `card()` / `settingsSection` **无描边**（§5.2：不承载交互、不表达层级的表面不画描边） | **跟 kit**（无描边） |
| 行卡宽度常量 | 帧实测 **608**（卡沿 x 80→688，= 640 − 2×16） | `SETTINGS_CARD_W = 604`，注释写「640 − 18pt」 | **跟帧与 §7.10**（608） |

第三行是 kit 自己的**陈旧常量**（正文用 `pad: 16`、常量却按 18 写），不影响渲染出来的帧；
要改的是 `main.js:2206` 那一行，属后续（不影响应用）。

**③ 为什么必须放弃原生 grouped `Form`（本轮改动的依据）**：两条冲突是**结构性**的，
不是数值调不齐——

- **行卡是「背后的底色 −3%」**：裸系统表单实测白底 → `#F7F7F7`，应用地板 `#E8E8EA` →
  `#E1E1E3`。原生表单**画不出**帧那种「白卡坐在灰地板上」（方向相反），`.listRowBackground`
  也无效（第五十二轮的对照实验）。
- **它自己的行卡距窗口左右各 20pt**（640 宽窗口里卡 600），而 §7.10 明写「行卡宽度 608
  （640 − 2×16）」，帧实测 16。

于是 `SettingsView` 的容器由 `Form`/`.formStyle(.grouped)` 换成
**`ScrollView` + 应用自己的卡片**（`Color.field` + `Corner.containerShape`），
控件仍是系统 `Toggle` / `Picker` / `Slider` / `LabeledContent`。几何全部取自 kit 与帧：
`paneInset 13`（= 稿的 16 − 系统 `TabView` 内容区比窗口窄的 **3**；窗口视图树实测内容区
634 vs 窗口 640）、`sectionGap 16`、`sectionHead padX 4 / padY 6` + `Caption / Medium`、
`rowInsetX 16 / rowInsetY 11`、卡内 hairline 整卡宽。

**④ 改后实测（离屏、borderless、浅色 640 × 454，13:36 构建）**：

| 量测对象 | 帧 | 应用改后 | 残差 |
|---|---|---|---|
| 内容区地板 | `#E8E8EA` | **`#E8E8EA`** | 0 |
| 行卡填充 | `#FFFFFF` | **`#FFFFFF`**（改前 `#DCDCDF`） | 0 |
| 行卡左右沿 | 80→688（608 宽，距窗口 16） | **16→624**（608 宽，距窗口 16） | 0 |
| 内容顶 → 首卡 | 59.0 | **54.0** | 5.0 |
| 带副标题行高 | 59.0 | **54.0** | 5.0 |
| 无副标题行高 | 42.0 | **39.0** | 3.0 |
| 小节标题 → 卡片 | 16 | **16** | 0 |
| 行内左沿墨迹 | 卡沿 + 17.5 | **卡沿 + 16.5** | 1.0 |
| 行尾控件右沿 | 距卡内沿 16 | **距卡内沿 16** | 0 |

**残差 5 / 3 是同一件事**：稿的文本行高是 Figma 的 135%，应用走系统文本样式
（§9「全部文本走系统文本样式」），标签列因此矮 5pt、取值行矮 3pt。按第二十四轮
（表头 28 / 行 24 不跟稿的 32 / 39）的同一条口径**保留系统度量、只记录**，
不再用加内边距的方式去凑帧的行高。

**⑤ 改造过程中撞到的两个系统行为（都不是猜的，是离屏实测）**：

- **`Toggle` 离开 grouped `Form` 会掉回前导 Checkbox 样式**（视图树里是
  `AppKitPlatformViewHost<...Checkbox>` + 前导 16×16 字形）。显式 `.toggleStyle(.switch)`
  之后才是 `AppKitSwitch`（54 × 24），且要**标签列可伸缩**开关才贴行尾。
- **`LabeledContent` 有两种失败模式**：标签不可伸缩时取值贴在标签后面（不贴行尾）；
  标签可伸缩时取值被挤出可视区（滑块行的 `1.0×` 整段消失）。所以「标题 → 取值」行改成
  显式 `HStack` + `Spacer`，取值字号按稿的 `valueText()`（服务端口 `Body / Medium`、
  关于三条 `Callout`）。

**⑥ 三个页签的内容高度**（离屏 `--settings` 实测）：通用 **232** / 创作 **196** / 服务 **389**，
页签内容区 424 → 三页都不出滚动条，`Layout.settingsWindowMinimumHeight = 454` 仍然成立，
不需要改 token。深色复核：地板 `#1F1E20`、行卡 `#272628`（token `#201E21` / `#2B292C`，
离屏偏差 ≤ 4），层级方向与稿一致（卡比地板亮）。

**⑦ 构建被并行轨道挡住，本轮用隔离构建装机**：仓库工作树当前**编不过**——
并行轨道新增的 `AudioEnvelope.swift`（13:02 新建、未跟踪）还没有加进
`SpeechRailApp.xcodeproj`，而 `AppModel.swift` 已经引用它，`xcodebuild` 报
`cannot find 'AudioEnvelope' in scope`（4 处）。我没有去改他们的工程文件，而是：
把 `macos/SpeechRailApp` 复制到 `/tmp/sr-iso`，把那 6 个并行文件换回 **12:54 那一版**
（探测副本里留着它们的 `*.orig`），`SettingsView.swift` 用本轮的新版，
在隔离副本里 `xcodebuild … -derivedDataPath /tmp/sr-iso-build` → `** BUILD SUCCEEDED **`
（13:36）。即装机件 = 「12:54 工作树 + 本轮设置页改动」，**不含**并行轨道 13:02 之后的试听链路。

**⑧ 装机**：`kill -TERM 4934` → 整包备份 `…-installed-20260916-1337.zip`（装前那一版，
sha256 `79e6413e…`）→ `ditto` 整包装入。装机件二进制 mtime 13:36:23、sha256
**`3985afad78fd3667dd602d56b0826977d3896f19a4cec7ebdea0ed75e9eb9d86`**（与构建产物逐字节相同）、
文件清单 17 项与上一版逐项一致、`codesign --verify --deep --strict` 通过
（`valid on disk` / `satisfies its Designated Requirement`）、版本仍 2.6.4 / 8；
`open -g` 未抢前台，主进程 **pid 29149** 与 `…local-control.xpc` **pid 29157** 均在。

**⑨ 本轮仍未验证**：真机目视（设置窗口的白卡/行距在你的屏幕上是什么样）、
§9 的无障碍矩阵（Increase Contrast / Reduce Motion / VoiceOver / 系统「文字大小」）、
任何 UI 自动化与单元测试。**下一步是把 §12.5 的走查清单跑一遍。**

#### 第五十九轮：接手并行轨（工程文件补引用、全树装机、两条规范冲突结案）

本轮由**接手方**执行（并行轨道已收工，工作树归一处管理）。不改任何一方的源码逻辑，
只补一条构建阻塞、把全树装进本机运行件，并把 §12.4 挂了两轮的两条冲突结案。

**① 阻塞：`AudioEnvelope.swift` 没进工程文件。** 并行轨 13:22 新增该文件，
`AppModel.swift`（4 处）与 `CreatorSurfaceViews.swift`（1 处）都已引用，但
`project.pbxproj` 里没有它——`rg AudioEnvelope` 在 pbxproj 上 **0 命中**。
该工程 `objectVersion = 56`、**没有** `PBXFileSystemSynchronizedRootGroup`，
源文件必须逐条登记，于是工作树编不过：
`xcodebuild … AppModel.swift` 报 `cannot find 'AudioEnvelope' in scope`。
补法是**四处登记**（`PBXBuildFile` `A5…54`、`PBXFileReference` `A4…49`、
组 `children`、`Sources` 阶段，都取当前最大号 +1，不重排任何既有条目）。
**这是本轮唯一的代码仓库改动**，没有改任何人的源码。

**② 全树构建（官方路径）**：
`xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp
-configuration Debug -sdk macosx -derivedDataPath /tmp/sr-build-mine build`
→ `** BUILD SUCCEEDED **`（13:43）。第五十六轮 ③ 那条「只验到类型层」的高风险项，
现在对**包含第五十七 / 五十八轮的全树**同样关闭：圆角机制、试听链路、设置页重画
都过了链接与资源层。（另：本机 `xcodebuild` 已不再受 Xcode 许可阻挡，
`-checkFirstLaunchStatus` 那一关已过。）

**③ 全树装机（第一次把第五十七轮的试听链路送达本机）**：`kill -TERM 29149`
（XPC 29157 随之退出）→ 整包备份
`…/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260916-1344.zip`（装前那一版，
二进制 sha256 `3985afad…`）→ 比对两包相对文件清单（各 **17 项**、`diff` 无输出）
→ `ditto` 整包装入。装后：二进制 mtime **13:43:53**、sha256
**`3f5975e6d4e72dec7587b3da8b1ef734881edf4a51b763b9cba9b1870150bc88`**（与构建产物逐字节相同）、
`codesign --verify --deep --strict` 通过（`valid on disk` / `satisfies its Designated Requirement`）、
`CFBundleShortVersionString` 2.6.4 / `CFBundleVersion` 8（未改版本号）、17 个文件；
`open -g` 后台启动未抢前台，主进程 **pid 36499** 与 `…local-control.xpc` **pid 36501** 均在，
8 秒后仍存活，`DiagnosticReports` 无新的 SpeechRail 崩溃。
**此前本机跑的**（13:11 / 13:36 两次装机）都是「12:54 那棵树」，
即第五十七轮的真实包络 / 真实进度**一直没进运行件**；现在进了。
**回退点**：`…-installed-20260916-1344.zip`（= 13:36 那一版，`3985afad…`）；
更早的 `…-1337 / -1311 / -1214 / -1148 / -1102.zip` 仍在。

**④ 渲染回归（跨合并复核）**：用**当前工作树**重建探针（`/tmp/sr-dub/probe.r91`，
`patch_failed:CreatorSurfaceViews` 属预期——那个 patch 本来就过时），重渲染四个可出图路由
（1440 × 900、浅色、有窗口宿主）：`--center`（服务状态）/ `--voice`（音色库）/
`--works`（我的作品）/ `--diagnostics`（预检诊断）**四页全部出图**
（98 KB – 470 KB，`-img-` 那组仍是 55 KB 的占位图，未误用），
版式、卡片层级、文字列与第四十六轮以来的形状机制一致，
**没有发现合并引入的版式回归**。这一步只回答「页面还画得对」，不回答观感。
（同轮复核过：§5.3 的审计行与 `macos-app-design-system.md` 的圆角几何行
**第五十六轮 ⑧ 已经补过**，不是遗留项。）

**⑤ 两条「规范 ↔ 稿」冲突结案**（第三十五 / 五十三轮提出，本轮裁决）：见 §12.4 决定 13 / 14。
两条都裁决**维持规范**，理由不是「规范写得早就听规范」，而是稿的那一代取值会
**用 ≤6/255 的色差换掉系统自适应**（结果条）、或**把已退役的写死强调色请回来**（编辑卡边界）。
代码未改，两条都留了一行回退。

**⑥ 本轮仍未验证**：真机目视与桌面走查（§12.5 的 12 条）、Increase Contrast / 系统「文字大小」/
减弱动态效果 / VoiceOver、任何 UI 自动化与单元测试。

#### 第六十轮：音色库 / 我的作品的选中行取稿值（token 规则加一条特例），并准备发布件

**① 用户当轮指令**：采纳音色库与我的作品的修改（边界解除）；token 规则为此开特例；
解决所有冲突；准备发布版本。

**② 本轮唯一的新机制发现：系统 `List` 的选中高亮**。新建一个只读离屏 harness
（`/tmp/sr-dub/rowfill`，不入库），在**同一个** `List(selection:)` + `.listStyle(.inset)` +
`.scrollContentBackground(.hidden)` 上逐像素量五种写法；「活跃窗口」那一列用
`NSTableRowView.isEmphasized = true` 离屏复现（`isEmphasized` 决定 `NSTableRowView` 画强调态
还是未强调态），**不需要激活任何窗口**：

| 写法 | 未强调（离屏窗口的默认） | 强调（= 活跃窗口） |
|---|---|---|
| 不铺底色（改造前的现状） | `#E3E3E3` | **`#007CE7`**（系统强调色实心） |
| 行内容 `.background(#DCE9EE)` | `#E3EDF1` | `#E3EDF1` |
| `.overlay(#DCE9EE)` | `#E3EDF1` | — |
| `.listRowBackground(#DCE9EE)` | `#E3EDF1` | **`#E3EDF1`** |
| `List` 上 `.tint(#DCE9EE)` | `#E3E3E3`（无效） | — |

两条结论：①**系统选中材质画在行内容之上**——行内的 `.background` / `.overlay` 与 `List.tint()`
都改不动它（后两者分别被合成、被忽略）；②**只有 `listRowBackground` 能换掉那层高亮本身**，
而且换掉之后 `List(selection:)` 的绑定、方向键与无障碍 selected 语义**全部保留**——不需要
拆掉系统 `List`（这是本轮没有走「自绘行 + 自己实现选中」那条路的原因）。

顺带量到一条此前的判断错误：活跃窗口下系统高亮是**系统强调色** `#007CE7`，既不是稿的淡底
（`#DCE9EE`），**也不跟随本 App 的强调色**（`#23687D` 浅 / `#4FA4BA` 深）——所以这一处是
「系统默认值同时偏离设计稿与应用自身」，按稿改不是「用手挑颜色压过系统」，而是把一处
不一致换成稿值。

**残余**：选中行在实渲染里是 `#E3EDF1`，比稿的 `#DCE9EE` 亮约 3%（那层材质仍以很低的比例
叠在上面）。量到了但没有再追——ΔE ≈ 1，低于肉眼分辨，再压就要改 token 去补偿，反而让
未选中态与其它表面脱钩。

**③ 落地与实测**：新增 `Surface.selectionTint`（稿 `surface/railTint`，浅 `#DCE9EE` /
深 `#36424A`，Increase Contrast 同值），只用在这两处：
`VoiceLibraryView` 的音色列表与 `WorksView` 的作品列表，行上
`.listRowBackground(row.id == selection ? Surface.selectionTint : nil)`。
真实页面离屏实测（`--works`，1440 × 900、浅色、有窗口宿主；把**探针副本**里的条件临时改成
无条件铺色以便取像素，仓库代码不这样）：列表矩形内 **`#DCE9EE` 占 66.9%**、`#FFFFFF` 25.7%
——token 在真实页面里逐像素等于稿值。

**④ 冲突收口**：见 §12.4 决定 15（这一处）与决定 16（其余三处）。其中「我的作品的行动作」
是**证据更正**而不是取舍：当前 kit 的 works 行本来就是三颗
（`main.js:1692-1694`，`acts` 宽 92 = 3 × 28 + 2 × 4，与应用 `actionColumnWidth` 同一个式子），
只有 4x 帧是两颗——此前记的「删按钮是减功能，等拍板」把它当成了取舍，实际是 kit 与帧不一致，
而 kit 更新，**应用现状即 kit**。

**⑤ 发布件**：`CURRENT_PROJECT_VERSION` 8 → 9（三处配置 `Debug` / `Release` / `Distribution`；
`MARKETING_VERSION` 仍 `2.6.4`，与服务 `pyproject.toml` 同版——营销版本是否进位是产品决定，
本轮不动）→ `xcodebuild -project … -scheme SpeechRailApp -configuration Release -sdk macosx
-derivedDataPath /tmp/sr-release-60 build` → `** BUILD SUCCEEDED **`（14:03，0 error；
两条 `not stripping binary because it is signed` 是内嵌 framework 既签名的提示）。
产物与装机件：17 个文件、`CFBundleShortVersionString` 2.6.4 / `CFBundleVersion` **9**、
ad-hoc 签名、`codesign --verify --deep --strict` 通过、entitlements 与 Debug 版一致（空）、
二进制 sha256 **`79d5df0d4a77607f0d98f2a61563214a18cd6ca023a4d8fdea8c2a728cfa31b4`**
（与构建产物逐字节相同，装机前比对过两包相对文件清单：各 17 项、`diff` 无输出）。
装机后 `open -g` 未抢前台，主进程 **pid 55682** 与 `…local-control.xpc` **pid 55685** 均在，
`/health` 与 `/readyz` 均 200。回退点：
`…/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260916-1404.zip`（装前那一版，
`3f5975e6…`）。**未构建 Distribution、未做 notarization**（本机无 Developer ID，免分发），
**未运行单元测试与 UI 自动化**，**未桌面走查**。

**⑥ 本轮仍未验证**：选中底色在**活跃窗口**下的最终观感（离屏只复现到 `isEmphasized` 那一层）、
深色下的 `#36424A`、Increase Contrast 同值的可辨识度、以及 §12.5 走查清单其余各项。

#### 第六十一轮：详情列改成**定宽** token（两块侧边栏不可能再各是各的宽度）；试听文案段尾补 14pt

**① 用户当轮指令**：「两个侧边栏应该保持宽度一致。另外音色库侧边栏里，试听文案下方应该留有
一定间距，不要与下方的表格紧挨着，间距符合系统统一 token」。

**② 宽度不一致的根因是「声明方式」，不是某一块面板**。第五十四 / 五十七轮已经把两块目录页的
段落结构收进 `SpeechRailInspectorPanel` 一处，但**列宽**一直是**一个区间**：
`inspectorColumnWidth(min: 300, ideal: 360, max: 440)`（`DeveloperInspector` 亦然）。
区间意味着列宽是「窗口余量 + 内容最小宽 + 打开顺序 + 用户拖动」的函数，而不是 token 的函数。
离屏实测（`--render --center --route <route> --window --light`，同一扇 1440 × 900 的窗口，
音色 fixture 同时用手写的两条与 `/v1/voices` 里真实那 18 条各跑一遍，结果一致）：

| 场景 | 改前（区间） | 改后（定宽 token） |
|---|---|---|
| 音色库，有选中音色 | 360.0 | 360.0 |
| 音色库，**空态**（`ContentUnavailableView`：此前完全没有列宽声明） | **270.0**（系统默认） | **360.0** |
| 我的作品（永远走 `selectedWork ?? works.first`，没有空态） | 360.0 | 360.0 |
| 1120 / 1200 / 1300 / 1440 / 1600 / 1800 六档窗口宽 | 360.0（有内容时） | 360.0 |
| 其余六条路由（`--devdetails` 强制打开详情列）1120 与 1440 | 360.0 | 360.0 |

装机件里那块**音色库**侧边栏是 **300**：用户截图逐像素量到预览面板外框 2x 实测
x 32–571px = 269.5pt，两侧各 16pt（`contentPadding`）→ 列宽 301.5pt，正好是区间的下限；
同一帧的波形墨迹 154 × 60px 对上 token 的 77 × 30pt，确认截图就是 2x。也就是说：区间在真实
窗口里会被窗口余量与内容最小宽**推到两端**，两块目录页因此可以各是各的宽度；空态那一瞬还会
落回系统默认的 270，等面板出现再跳。离屏探针**复现不出那个 300**（它的窗口是建出来就是最终
尺寸的，真实窗口的余量/时机它没有），所以这一条以「装机截图 + 区间下限」为证据、以「定宽后
任何路径都取不到 300」为收口，而不是声称量到了同一串数字。

**改法**：`Layout` 里把 `inspectorMinimumWidth` / `inspectorIdealWidth` / `inspectorMaximumWidth`
三个区间值收成**一个定宽 token** `inspectorColumnWidth`（= `inspectorWidth` = 360，与稿的
Inspector 同口径），并新增唯一的列宽声明点 `speechRailInspectorColumn()`
（`SpeechRailInspectorColumnModifier`：定宽 frame + `clipped` + `inspectorColumnWidth(定宽)`）。
落地点三处：`SpeechRailInspectorPanel`（两块目录页共用）、`DeveloperInspector`（其余页面）、
两块目录页的**空态**（270 的来源）。**有意的代价**：分割线不再可拖——稿上的 Inspector 本来
就是一条定宽列，300–440 的区间是应用自造，而且它正是宽度不一致的来源。

**③ 试听文案下方的留白**：音色库试听段在试听面板之后还有一块应用自有的「试听文案」输入区
（稿上没有入口，第四十五轮 ⑤），它排在段内、面板的 `padY 14` 之外。改前它的下边框与段间
hairline **重叠**：离屏 `--inspector`（360 × 900、浅色）vscan 实测输入槽底边框在 y 230.0–232.0、
段间 hairline 在 y 231.0（同一行）——就是用户截图里「与下方的表格紧挨着」的样子。
改后在那一块上加 `padding(.bottom, Inspector.previewWrapInsetY)`（14 = 稿 `previewWrap` 的
`padY`，不新增数值）：输入槽底边框止于 231.0、hairline 在 245.0–246.0，间距 **14.0pt**，
试听段上下因此同值（我的作品那一段没有这块输入区，段尾本来就只有面板自带的 14pt，未受影响）。

**④ 本轮未验证**：真机上拖窗口 / 切页时列宽的观感（离屏窗口是建出来即最终尺寸，取不到
「先窄后宽」那条路径）、定宽后窄窗口里详情列被挤压的主观感受、深色下这 14pt 的视觉节奏、
以及被删掉的三个区间 token 是否还有别处引用（已全仓 `rg` 过：`swift` 只有这两处，`docs/`
只剩两份 2026-09-13 的旧设计稿把它们当历史值记着）。
**未运行单元测试与 UI 自动化，未重装或重跑构建**（按 AGENTS.md 需当次授权）。

#### 第六十二轮：详情列开关从**系统工具栏**移到内容列首行尾端（工具栏落点不可锚定）

**① 用户当轮指令**：「按钮应该更靠右侧，临着边栏，按照边栏的左侧 index 开始算位置，
留一定空间后放按钮」（红框 = 内容列上方那一条工具栏带，左起侧栏分隔线、右止详情列左沿）。

**② 根因：窗口工具栏里没有「内容列右端」这个槽位**。工具栏是一整条，动作项的落点由系统按
「固定项 + 浮动间隔」重新分配；离屏实测（`--hier`，`我的作品` / `音色库`，浅色，1440 × 900，
窗口宽 1120 / 1280 / 1440 / 1600 四档）同一枚 `sidebar.right` 按钮改前落在
x 639.5 / 719.5 / 799.5 / 879.5（项宽 44），到详情列左沿（= 窗口宽 − 360，与装机截图逐像素
核对：截图 2886px 宽下 x 2164px 由 `#D6D6D8` 转 `#FFFFFF`，即 1079.75pt）的距离从 **76.5**
一路涨到 **316.5**——它的 x 是「身份槽右沿 540」与「搜索框左沿 = 窗口宽 − 337」的中点，
随窗口宽按 1:2 漂移，所以看着像悬在内容列中间。

四种改法都试过，**都不改变「落点由系统分配」**（同一组 `--hier` 读数）：
去掉组合根那枚 `ToolbarSpacer(.flexible)`（按钮退到 x 540，贴着身份槽）；
`.status`（居中于内容列，x 642.5）；`.secondaryAction` / `.confirmationAction`（同「贴着身份槽」）；
把声明交给 `.inspector` 内部（仍排在同一组动作里）；把项包进 `maxWidth: .infinity` 的右对齐容器
（工具栏项只取理想宽，读数逐项不变）。`.searchable(placement: .toolbar)` 自带的那枚浮动间隔
永远排在动作项之后，因此右侧没有可锚的点。

**③ 改法**：开关不再声明为工具栏项，改由 `PageScaffold` 的 `trailing` 槽放进**页面首行尾端**
（音色库 / 我的作品两页；这一槽位已有先例——运行监控的时间窗选择器）。首行由**内容列**承载，
它的右沿就是详情列左沿，间隔即该行自己的 `Layout.contentPadding`（20pt），**不新增数值**。
离屏实测（`--render --center --route works|voiceLibrary --window --titled --light`，
2x PNG 描墨，窗口宽 1120 / 1440 / 1600）图标墨迹右沿到详情列左沿恒为 **29.5pt**
（= `contentPadding` 20 + 动作控件右内边距 8 + 图标框自身留白 1.5），
**三档窗口逐像素同值**：730.5 / 1050.5 / 1210.5 对 760 / 1080 / 1240。
工具栏本身因此只剩「系统侧栏按钮 · 页面身份槽 · 搜索框」（音色库另有整页唯一的「新建音色」）。

**④ 构建与装机（用户当轮授权「更新安装」，app-only，未动服务）**：`CFBundleVersion`
10 → 11（`MARKETING_VERSION` 仍 2.6.4，与前两轮同一口径）。门禁
`scripts/macos_app_build.sh --configuration Debug` → `** BUILD SUCCEEDED **`；
`plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist`
→ OK；再以独立 DerivedData 出装机产物（2.6.4 / 11、`com.speechrail.desktop`、
内嵌 `com.speechrail.desktop.local-control.xpc`、`codesign --verify --deep --strict` 通过）。
装机前把 2.6.4-10 整包备份为
`~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-10-installed-20260916-1539.zip`
（sha256 `1aeb5b8f…`），退出旧 App 后 `ditto` 到 `~/Applications/SpeechRail.app`；
`mdfind 'kMDItemCFBundleIdentifier == "com.speechrail.desktop"'` 只返回这一条，
`kMDItemFSName == "SpeechRailApp.app"` 为空；App 主进程 pid 7003 + helper pid 7007 在跑。
装机前后服务未被触碰：8201 仍是唯一 listener（pid 99260）、`/health` 正常、`/readyz` 200、
profile `quality`。临时 DerivedData 与旧 bundle 副本已注销 LaunchServices 并移入废纸篓。

**⑤ 本轮未验证**：真窗口里的悬停/点击热区观感、详情列收起后（内容列变宽）按钮的相对关系、
深色与「减弱动态」下的表现（都留给桌面目视）；**未运行单元测试与 UI 自动化**
（UI 自动化按 AGENTS.md 硬约束需当次明确授权，本轮未请求）。回退方式：App 失败直接把上一份
ZIP 恢复到同一路径；代码层两页各两处改动（`PageScaffold` 的 `trailing` 槽 + `xxxInspectorToggle`
声明），把工具栏项放回 `.toolbar { ToolbarItem(placement: .primaryAction) }` 即可。

#### 第六十三轮：运行监控回到用户语言（口径、文案与组件映射，2026-09-16）

**① 用户当轮指令**：「优化 运维监控页面，我现在都看不懂监控的啥？从用户角度出发」。

**② 取证：这一页不是文案难，是口径不成立**（2026-09-16 本机在跑的 `quality` 服务，
`curl -H 'Accept: application/json' http://127.0.0.1:8201/metrics`）：

| 实测事实 | 后果 |
|---|---|
| `speechrail_http_requests_total` 的 1188 次累计请求里，1159 次来自控制面轮询（`/health` 469、`/metrics` 197、`/v1/voices` 216、`/v1/models` 142、`/v1/voices/{voice_id}` 135） | 首屏的「请求速率」有 97.6% 是 App 自己在读状态：用户什么都没做它在动，真在合成时它几乎不动 |
| 语音接口只有 `/v1/audio/speech` 15 次、`/v1/voices/previews` 12 次 | 真正反映用户工作量的量级是两位数字，被淹没在四位数里 |
| `workers` 实际是 `{asr, tts, streaming}`，而 `workerTitle` 的映射表只有 `asr` / `tts` / `diarization` / `realtime_vad` | 组件表上直接露出英文 `streaming` |
| `resources.physical_footprint_complete = false`（`macos_footprint_incomplete`，2 个进程） | 「服务 physical footprint」在本机恒为「未提供」，而它恰恰是用户最想看的那一行 |
| 首屏六格的另一半（错误率、并发、排队、ASR/TTS 时延）在空闲时恒为 0 或「—」 | 打开这一页看到的基本是一片零和破折号，加一串 `rate` / `窗口均值` / `voice_class` 的说法 |

这几条合起来就是用户的「看不懂」：**没有一个数字在回答他会问出口的问题**，而每个数字都要求他先知道
Prometheus 的读法。

**③ 改法**（口径 + 文案 + 映射，三层一起改；§7.6 已按本轮重写）：

- **数据层**（`RuntimeMetricsSampler.swift`）：新增 `RuntimeUsageTotals`
  （`ttsRequests` / `asrRequests` / `ttsAudioSeconds` / `asrAudioSeconds` / `realtimeSessions`），
  按 `endpoint` label 只取语音接口；`/v1/voices/previews` 走同一条 `record_tts`，所以并入合成次数，
  否则「次数」与「音频秒数」对不上。窗口侧新增 `usageIncrease`（与 `RuntimeHistogramTotals
  .delta(since:)` 同一套规则：计数回退 = 无数据，不是 0）、`errorIncrease`、`queueRejectionIncrease`。
  后两者按**单调计数器**处理：序列缺失按 0（「没有失败过」），只有两侧都有序列且出现回退才是「—」；
  同理，「服务在跑、metrics 读得到、却没有 `endpoint="/v1/audio/transcriptions"` 序列」显示 0 次，
  只有整个 metrics 读不到才显示「—」。
  新增 `RuntimeHistogramPresentation`：指标名 → 用户语言 + 单位，label 串 → 音色类型 / endpoint，
  认不出的名字原样保留（指标原文仍然是排障与对 Grafana 的事实）。
- **视图层**（`RuntimeMonitoringView.swift`）：首屏六格从「请求速率 / 错误率 / 并发 / 排队 / ASR 时延 /
  TTS 时延」换成「正在处理 / 语音合成 / 语音识别 / 合成耗时 / 识别耗时 / 失败请求」，
  次数报「3 次」、时长报「共 12.4 秒音频」、耗时报「0.42 秒（3 次请求的平均）」；
  结论句不再复述自己做了什么（「已读取 health 和 metrics」），改成「最近 5 分钟：合成 3 次、识别 1 次，
  都正常。」或「没有语音请求，服务空闲可用。」；页首说明由「最近 n 个样本 · 刷新间隔 5 秒」改为
  「服务最近在做什么、快不快、占多少内存；每 5 秒读一次本机服务。」（数据点数量移到卡页脚与
  结论行的新鲜度槽）。图卡标题「资源脉冲」→「使用趋势」，序列名改成「实时语音会话 / 单次请求」
  与「语音识别 / 语音合成」，坐标轴改「同时处理（个）」「每次耗时（秒）」。组件表补 `streaming` →
  「实时语音」映射，说明带回答「哪些模型现在留在内存里、哪些已释放，空闲一段时间后自动释放」。
  折叠明细改「更多细节」：服务能力 / 内存与并行（机器内存、服务实际占用、服务可用上限、
  模型声明占用、同时处理多个任务）/ 不同音色类型的合成耗时 / 累计统计（服务启动以来，列头写明
  「累计平均」且带单位）。复制摘要新增 `usage` 段与 `summary` 行。
- **无障碍**（`RuntimeMonitoringAccessibility.swift`）：坐标轴标题、系列名、图表标题与摘要同步换词
  （VoiceOver 听到的必须和图上一样）。
- **测试**（`ControlKitTests.swift`）：新增四条——只数语音接口并取窗口增量（含试听并入合成、
  轮询不进 usage）、计数回退时是无数据不是 0、5xx 序列缺失按 0 处理、指标翻译表与未知名字保留。

**④ 验证（2026-09-16）**：`scripts/macos_app_build.sh --configuration Debug` → `** BUILD SUCCEEDED **`；
`xcodebuild -scheme SpeechRailApp build-for-testing` → `** TEST BUILD SUCCEEDED **`（**只编译**，
测试目标里的 `RuntimeMetricsSampler` / `RuntimeMonitoringAccessibility` 一并过了类型检查）。
稿侧同步：`figma-kit/main.js` 的 `screenMonitoring` 换成本轮文案（页首说明、卡标题「使用趋势」、
图例、组件表说明与组件名），`node audit.js` → `audit: clean`、`node --check main.js` 通过；
**但插件重跑与重导出未执行**（本次会话没有 Figma 连接器工具，生成器路线要人工在 Figma 桌面版
触发，见 `figma-kit/README.md`）——当前 Figma 文档里那张画板仍是旧文案。

**④+ 装机（用户当轮授权「安装，我来测试」，app-only，未动服务）**：`CFBundleVersion`
11 → 12（`MARKETING_VERSION` 仍 2.6.4，与第六十/六十二轮同一口径）。门禁
`scripts/macos_app_build.sh --configuration Debug` → `** BUILD SUCCEEDED **`；
`plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist` → OK；
再以仓库外的独立 DerivedData 出装机产物（2.6.4 / 12、`com.speechrail.desktop`、
内嵌 `com.speechrail.desktop.local-control.xpc`、`codesign --verify --deep --strict` 通过，ad-hoc）。
装机前把 2.6.4-11 整包备份为
`~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-11-installed-20260916-1709.zip`
（sha256 `617b592d91aa0b91f8ba3499cc3eaaa9d4893b1edb3bacb7eae7f23a0b394600`），
退出旧 App（pid 7003）后旧 bundle 移入废纸、`ditto` 到 `~/Applications/SpeechRail.app`，
装机后 `open` 该路径重新启动。核对：`mdfind 'kMDItemCFBundleIdentifier == "com.speechrail.desktop"'`
只返回 `~/Applications/SpeechRail.app`、`kMDItemFSName == "SpeechRailApp.app"` 为空；
App 主进程 pid 61520 + 按需启动的 control helper pid 61522；临时 DerivedData 已注销
LaunchServices 并移入废纸篓。**服务未被触碰**：8201 仍是唯一 listener（pid 99260）、
`/readyz` 200、`/health` 仍是 profile `quality` 且 asr/tts ready。
**未运行**：单元测试与 UI 自动化（AGENTS.md 硬约束：UI 自动化须当次明确授权，本轮未请求）、
离屏量测（本机没有离屏渲染 harness，`--render` / `--hier` 那几个开关不是仓库里的代码）、
真机目视走查（留给用户）。因此「渲染出来的排版是否如预期」这一层本轮**没有**证据，
结论只到「编译通过 + 口径与文案已按上述规则改写」。

**⑤ 回退**：视图层的改动集中在 `metricStrip` / `monitoringMessage` / `chartHeading` / `workerTitle` /
`resourceSection` / `histogramRows` 六处，把 `metricStrip` 换回 `rate` 与百分比、
把结论句换回「已读取 health 和 metrics」即可回到本轮之前；数据层全是新增字段与新增类型，
旧口径（`rate`、`errorRatio`、窗口均值、直方图累计）一个都没删，采样器的新增字段留着不用也不影响。
这一轮改掉的是第二十四轮「图卡标题 = 资源脉冲」与第三十六轮「组件表说明带 = worker 生命周期状态」
里**当时的文案**，字号与几何结论不变。

#### 第六十四轮：空图不是空态——时延图没数据时不再画一张 240pt 的白盒子（2026-09-16）

**① 用户当轮反馈**（装机后第一眼走查，附截图）：「这和之前有什么变化么？这么大片空白是啥？」
截图里：结论句与六格已是第六十三轮的文案，但「使用趋势」卡从标题往下是一大片空白，
底部只剩一条「语音识别 / 语音合成」图例。

**② 根因（两处，都在图卡里）**：

1. **时延图在没有任何时延样本时照样画**。`RuntimeLatencyChartDescriptor.isSufficient` 从
   第十四轮起就存在，但视图从来没调用它：`chartPanel` 只用并发图的
   `RuntimeMonitoringChartDescriptor.isSufficient`（只要求 ≥2 个数据点）决定整张卡画不画图，
   于是 `asrLatencySeconds` / `ttsLatencySeconds` 全为 `nil` 的窗口里，第二张 `Chart` 依旧占满
   `Layout.monitoringChartHeight`(240pt)。**`Chart` 没有 mark 时不是空态、是纯白画布**：
   只剩网格与坐标轴，实测在「5 分钟」窗口下约半屏。这一条在 `HEAD` 就是这个结构
   （`git show HEAD:…RuntimeMonitoringView.swift`：567 `isSufficient` / 582 `concurrencyChart` /
   583 `latencyChart`），不是第六十三轮引入的。
2. **两张图之间没有分隔**。同一张卡里两个 `Chart` 单位不同、说的是两件事，缺分隔线时第二张图
   一旦空白，整张卡就读成「标题下面一大片空白」。另外并发图在全零时 Swift Charts 的自动域
   退化成 `0...0`：没有刻度、没有网格线，只剩一条漂在盒子里的线。

**③ 改法**：

- `latencySamples` 收成一处生成，图与 AX 描述符共用；用
  `RuntimeLatencyChartDescriptor.isSufficient(latencySamples)` 决定画图，还是显示一行实话
  「这段时间还没有语音耗时数据；合成或识别一次后，这里会出现每次的耗时曲线。」（`List.tallRowHeight` 高）。
- 两张图之间加 `Divider`（上下各 `Spacing.xs`）。
- 并发图显式 `chartYScale(domain: 0 ... max(1, peak))`，零线贴回下沿、刻度回来。
- **没改**：并发图仍然常驻（它是这一页的主对象，全零也是一条信息）；时延图只在真有样本时出现。
  改用例时不把「没有时延样本」画成空图，这条对所有类似的「派生序列图」都适用。

**④ 装机（用户当轮授权，app-only，未动服务）**：`CFBundleVersion` 12 → 13，装机产物仍
2.6.4 / `com.speechrail.desktop`、ad-hoc 签名通过；回退点
`~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-12-installed-20260916-1714.zip`
（sha256 `1e38db6e…634a`）。装机后 `mdfind` 仍只返回 `~/Applications/SpeechRail.app`，
App pid 68738 + control helper pid 68742；**服务未被触碰**：8201 仍是 pid 99260、`/readyz` 200。

**⑤ 未验证**：改后的观感要等用户下一眼走查（本机无离屏渲染 harness，agent 不截屏、不驱动界面）；
并发图在全零域下的刻度读数同样只有目视能确认。回退 = 把 `Divider` 与 `latencyEmptyState` 分支
去掉、`chartYScale` 一行删除，即回到本轮之前。

#### 第六十五轮：使用趋势合并成一个坐标系；运行组件表不再挂滚动条（2026-09-16）

**① 用户当轮反馈**（装机截图两张，三句话）：图 1「为何搞俩坐标系？折线图是否是最佳体现方式？」
→「合并到一个坐标系」→「不用柱状图了，你选择最佳展现形式」；图 2「高度，高一些，不要需要滑动」
（运行组件表右侧挂着一条滚动条）。

**② 根因（两条都是量出来的，不是猜的）**：

1. **一张卡里的两张图，各有一根纵轴**：上「每次 5 秒的同时处理数」、下「每次语音的耗时」。
   单位不同确实不能共用一根刻度（共用会把两条序列都压扁），但两张图长得一模一样——
   区别只写在最右边一列灰字里（`.chartYAxisLabel`），所以读起来像「同一张图被切成了两半」。
   同一张截图还暴露第二个问题：历史档下图**有图例、有刻度、没有线**。原因是那个窗口里
   只有一个统计桶带耗时样本，而 `LineMark` 不给单点画符号——它的值却仍会把纵轴撑到 4 秒。
2. **运行组件表挂着滚动条**，不是行数超了：当时服务只有 3 个 worker
   （`/metrics` 的 `workers`：`asr` / `streaming` / `tts`，全部 `cold_evicted`）。
   离屏实测（`NSHostingView` 宿主真实 `Table`，macOS 26.6）：表头 28、系统行高下限 24，
   应用的表高公式 `28 + 24 × n` **正好等于内容高**——而 SwiftUI 在帧高等于内容高时仍然挂上
   竖直滚动条（同一次实测 `hasVerticalScroller = true`、滚动条可见；要多留 16pt 才消失，
   那 16pt 会变成表底一条空带，正是第二十四轮修掉的那种观感）。

**③ 改法**：

- **图卡（实时档 / 历史档各一张）**：一根横轴、一个绘图区、**纵轴两套刻度**。
  左轴是请求量（面积、整数刻度），右轴是耗时（折线、秒），两者用一个线性比例对齐
  （`UsageChartScale`：右轴刻度取 1 / 2 / 2.5 / 5 × 10ⁿ 整档，所以右轴读到的是整秒，
  不是左轴刻度的换算残数）。用**面积 vs 折线**区分两件事、用颜色区分「合成 / 识别」，
  图例一行写清「面积读左轴 · 折线读右轴」。历史档的面积是每个桶的合成 / 识别次数（堆叠），
  实时档的面积是「实时语音会话 + 单次请求」。
- **不用柱状图**：试过 `BarMark` / `RectangleMark`（`xStart/xEnd` + `position(by:)` 在时间轴上
  会退化成横条，定宽柱又会互相压住），用户定稿「你选择最佳展现形式」后改为
  **面积（体量）+ 折线（速度）**——这也是监控面板最常见的组合，且面积能透出网格线。
- **单点样本**：样本不足两点的序列改画 `PointMark`，补上「有刻度没有线」的那一格。
- **空图不再占位**：没有耗时样本时不画第二张 240pt 的空图，只在图下留一行实话。
- **无障碍**：`RuntimeMonitoringChartDescriptor` 增加 `latency:`，一张图里同时描述面积与折线；
  删掉已无引用的 `RuntimeLatencyChartDescriptor`（§9）。
- **运行组件表**：行高 24 → `Layout.monitoringWorkerRowHeight`（42，此前是一个没人引用的死 token，
  稿 `workers` 的行是 `padY 11` + `Callout` 17.4 ≈ 39.4），表高 = 表头 28 + 42 × 行数，
  行数不超过上限（12）时 `.scrollDisabled(true)`——表里没有够不着的内容时，滚动条只是噪音。
  三行的「运行组件」卡因此从 261 落到 ≈ 280，与稿实测的 280.2 同档（§5.6 几何表）。
  累计统计表（明细区）同口径。

**④ 实测（2026-09-16 21:03）**：`scripts/macos_app_build.sh --configuration Debug` → **BUILD SUCCEEDED**。
离屏探针（`NSHostingView` + 只建窗、不 order / 不 makeKey / 不 activate / alpha 0）：
改后的表 `header=28`、`rect(ofRow:)=[42, 42, 42]`、滚动区高 154（= 公式值）、
`hasVerticalScroller=false`、`verticalScroller=nil`；合成后的图按同一份 Charts 代码单独渲染，
一个绘图区、左轴整数刻度、右轴秒刻度、面积 + 折线 + 系统图例（2 项）、单点样本可见。

**⑤ 未验证**：装机后的实际观感（agent 不截屏、不驱动界面，UI 自动化须当次明确授权）；
未运行单元测试、UI 自动化与完整 gate；`Chart` 里的两套刻度在窄窗口（1120pt）下的右轴标签
是否与左轴挤在一起，只有目视能确认。回退 = `git diff` 里的三处视图改动（两张图表 builder、
`tableHeight(for:)` 与行高 token、无障碍描述符的 `latency:`），服务与模型未触碰。

**⑥ 装机（用户当轮授权「安装，我测试」，app-only，未动服务，2026-09-16 21:15）**：
构建产物是 2.6.5 / `CFBundleVersion` 14（并行轨已 bump）、`com.speechrail.desktop`、ad-hoc 签名；
回退点 `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.5-14-installed-20260916-2115.zip`
（sha256 `eadad4c5aa896b69…`），被替换的 bundle 走废纸篓。装机后：
`mdfind 'kMDItemCFBundleIdentifier == "com.speechrail.desktop"'` 只返回 `~/Applications/SpeechRail.app`，
App pid 88135 + control helper pid 88144；**服务未被触碰**：8201 仍是 pid 72295、`/readyz` 200。
本次**未运行** `macos_app_test.sh`（UI 自动化，AGENTS.md 硬约束：须当次明确要求）。

#### 第六十六轮：提词稿正文取稿的 `Title / Page`；录制卡自己说出「麦克风没收到声音」（2026-09-16）

**① 用户当轮反馈**（音色克隆页截图一张，三句话）：「这几个 tab 的文本框高度应相同，字体应和
高保真一样，要大一些。」「录音时，声波不动，没有声音，录制完，听也没有声音。」

**② 根因（三条，都有实测证据）**：

1. **正文槽的字比稿小一档，槽高还跟着稿子走**。`Typography.promptScript` 取的是 `.title3`
   （macOS 15pt Regular），而稿上这一段是 `Title / Page`（20pt Semi Bold，
   `figma-kit/main.js` 的 `scriptBody`）——**页标题那一档**；§5.5 对 `Title / Page` 的既有口径
   是 `.title`（22pt，+2 残差），这一处是唯一漏掉映射的地方（`display` / `windowTitle` /
   `diagnosticsSummary` 都在那一档）。高度上，四段官方稿 40–55 字、「自己写一段」又是输入框，
   只读正文走 `lineLimit(4)` + `fixedSize`、编辑器走 `minHeight`，五个选项的槽高各不相同：
   换一次稿，卡片跟着跳一次。
2. **「录音没有声音」这一条的根因在系统侧，不在这一页的代码**。2026-09-16 20:31 的实测
   （`/usr/bin/log show --predicate 'process == "SpeechRail"'`）：TCC 结论
   `Auth Right: Allowed (User Consent)`、`BuiltInMicrophoneDevice` 的 `AudioDeviceStart (err 0)`、
   HAL 侧 `IO Stopped Context 27920 after 713216 frames`（≈14.9 秒 @48 kHz）、菜单栏麦克风
   指示灯亮；而同一时刻用 ffmpeg 走 AVCapture 采 1.2 秒，拿到的 **51968 个样点全是 0**，
   `kAudioDevicePropertyMute` 读到 `unmuted`、输入音量 0.69、数据源是 `imic`。
   也就是：设备在跑、权限已给、数据全 0——这台机器的麦克风输入在系统层面就没有声音。
   走查这一页的录音时，顺序必须是**先验系统、再验应用**（系统设置 ▸ 声音 ▸ 输入 的输入电平表，
   或语音备忘录）。
3. **录音通道里确有一处真竞态**。`discard()` 把收尾（`capture.stop()`）排到录音线程上，而
   `start()` 开头就会调它；同一份日志里第二次录音的 AudioQueue 只活了 55 ms
   （20:31:37.012 建、20:31:37.067 停），正是「停止 → 立刻重录」时收尾落在新录音器之后。

**③ 改法**：

- `Typography.promptScript` 改成 `.system(.title, weight: .semibold)`（稿 `Title / Page` 那一档），
  并给提词稿正文槽一个新 token `VoiceClone.scriptBodyHeight`(112 = 3 行 `.title` 的行高 26.4 × 3
  + 上下各 16pt 内边距)：只读正文与自写编辑器共用它，`scriptMaximumLines` 收到 3。
  留到 3 行而不是稿上的 2 行，是因为最长的一段官方稿 55 字在最小窗口（1120pt）下会用到第二行的
  尾巴——给三行，任何宽度下正文都读得完整，不会为了「高度统一」把稿子截断。
- 录制卡新增一行 `signalHint`：`VoiceRecordingController.hasSignal` 在
  `VoiceClone.silenceHintSeconds`(4s) 内一次都没有越过 `signalFloorLevel`（≈ -50 dBFS）时，
  直接写「麦克风没有收到声音：确认系统输入设备选的是你在用的那支麦克风、输入音量不是 0，
  并且没有被静音。」——录音行为一点没变，只是把「电平条一直不亮」这个现象提前翻译成结论。
- `RecorderBox.stop(upTo:)`：收尾只收「这一代及更早」的录音器，`discard()` 与 `finish()`
  都带上世代号，用户紧接着按下的「重录」不再被上一次的收尾停掉。

**④ 本轮实测**：`scripts/macos_app_build.sh --configuration Debug` → `** BUILD SUCCEEDED **`
（2026-09-16 21:05）。**未运行** UI 自动化（`scripts/macos_app_test.sh`）、未安装、未跑
公共 ASR/TTS smoke——界面观感与录音要从系统侧先验。

#### 第六十七轮：提词稿两种形态对齐到同一个外框与同一条正文原点；回听行补「删除」（2026-09-16）

**① 用户当轮反馈**（承接第六十六轮）：「声音没问题了。」「我自己输入的文本框和其他几个高度有
一点差异，请完全对齐。」「录完，听了，不想用，没有删除功能？」

**② 根因与实测（离屏量测，无窗口、无 UI 自动化）**：

1. **外框其实已经等高，差的是正文原点**。第六十六轮把两种形态都做到 112pt（`NSHostingView.
   fittingSize` 与 `ImageRenderer` 位图两处实测都是 112.0），但两侧的**内边距不同档**：只读稿走
   `Spacing.md`(16)，自写编辑器走 `Spacing.xs`(8) 再在内部定高 96。实测编辑器背后的
   `PlatformTextView` 是 `textContainerInset = (0, 0)`、`lineFragmentPadding = 5`，也就是
   **正文原点就等于内边距本身**——切到「自己写一段」，正文顶沿比只读稿高 8pt、左沿高 3pt
   （8+5=13 vs 16）。用户看到的是这一跳，不是框高的差。
2. **外框高度此前是「内层定高 + 内外边距恰好抵平」推出来的，不是写死的事实**。只读稿那侧用的
   是 `minHeight`（下限），一旦内容高过内框就会自己长高——3 行 `.title` 实测 78pt、内框 80pt，
   余量只有 2pt；两个 112 是巧合而不是约束。
3. **回听与核对卡只有「播放」与「重录」**，没有「这一段我不想要了」的出口。删掉一段尚未注册的
   临时录音不是破坏性外部操作：`acceptCloneRecording` 收下字节后**已经删掉磁盘上的临时文件**，
   内存里这一段是唯一副本，重录的代价就是再读一遍——所以这一颗不需要确认框（作品删除仍走
   `confirmationDialog`，那是另一回事）。

**③ 改法**：

- `VoiceCloneView.scriptBody`：固定的 `.frame(height: VoiceClone.scriptBodyHeight)` 从两个分支
  内部提到**两种形态之外**，两个分支都改成「填满内框 + `Spacing.md` 内边距」；编辑器左内边距
  减掉新 token `VoiceClone.editorLineFragmentPadding`(5)，正文左沿才与只读稿同一条竖线。
  改后实测：两侧外框都是 112pt，正文原点都是 (16, 16)。
- 回听行的动作从两颗变三颗：`播放 / 重录 / 删除`（`Label("删除", systemImage: "trash")`，
  次级档 + `role: .destructive`，与音色库那颗删除同一口径）。`deleteTake()` 停掉回听、清这一轮的
  错误提示、放掉这一段录音与它的本地分析/预检结果，并把录音器的计时与电平读回零——删除后整页回到
  「还没开始」。用户的「实际朗读的文本」是**输入**（下一遍还要用），不跟着删。

**④ 本轮实测**：离屏探针（`NSHostingView` 子树帧 + `ImageRenderer` 位图）确认两形态逐点相等；
`scripts/macos_app_build.sh --configuration Debug` → `** BUILD SUCCEEDED **`，
`--archive` → `** ARCHIVE SUCCEEDED **`（2026-09-16 21:36 / 22:20）。

**⑤ 本轮安装**（用户当轮明确要求「安装」）：build 号按发布口径单调递增 `14 → 15`
（`MARKETING_VERSION` 仍是 `2.6.5`，与服务版本同值），覆盖安装到 `~/Applications/SpeechRail.app`，
`CFBundleShortVersionString`/`CFBundleVersion` = `2.6.5 (15)`、ad-hoc 签名 `codesign --verify --strict`
通过、内嵌 `com.speechrail.desktop.local-control.xpc` 在位；上一版归档为
`SpeechRail-2.6.5-build14-before-scriptslot-delete-20260916-222047.zip`，本版归档为
`SpeechRail-2.6.5-build15-20260916-222047.zip`（`app-archive/`，各附 SHA-256）。App 退出后
`/health`、`/readyz` 仍 200、8201 仍只有一个 listener；`mdfind` 的 bundle 查询只剩唯一安装路径。
**未运行** UI 自动化（`scripts/macos_app_test.sh`）、未跑公共 ASR/TTS smoke——界面观感仍需用户走查。

#### 第六十八轮：运行监控两张表不再用系统 `Table`（外来底色与隔行底纹被读成「突兀」，2026-09-16）

**① 用户当轮反馈**（装机截图一张，运行组件卡）：「这里咋这么突兀，这符合系统设计 token 么？」

**② 根因（截图逐像素 + 离屏探针，都是实测）**：

| 带 | 截图实测 | 是不是 token |
|---|---|---|
| 卡头 / 卡脚（`Color.field`） | `(43,41,44)` = `#2B292C` | ✓ 与 `surface/content` 深色值**逐位相同** |
| 表体（表头 + 三行） | `(31,29,41)` = `#1F1D29` | ✗ 不在 token 里（卡面 `#2B292C`、页面地板 `#201E21`） |
| 「实时语音」那一行 | `(42,40,51)` | ✗ 系统**隔行底纹**，不是选中高亮 |

截图是 2x（2326 × 620）、逐带取水平均值。卡头与卡脚的读数与 token 逐位相同，说明这份截图
没有被色彩管理改写，表体那片偏蓝的 `#1F1D29` 是**真实色差**，不是转录偏差。

离屏探针（`NSHostingView` 挂同一段 `Table` 代码，macOS 26.6，暗色）把三样东西都指了出来：
`NSTableView.backgroundColor = #1E1E1E`、`usesAlternatingRowBackgroundColors = true`、
偶数行 `backgroundColor = #FFFFFF a=0.05`；另外 `rect(ofRow:0) = (0, 5, w, 42)`——表体顶部还有
**5pt 内容内缩**（第五十六轮的高度公式 `28 + 24 × n` 没算这一格，第六十五轮改成 42 后同样没算，
所以最后一行会被裁掉 5pt）。第二行那层 5% 白压在表体底色上正是 `(42,40,51)`，与截图**逐位吻合**：
那条浅色带不是选中高亮，是系统的隔行底纹——用眼睛读就是「实时语音被选中了」，一处假的可选中暗示。

第五十六轮的「决定 11」把这两张表固定在系统 `Table` 上，当时给的理由是保留排序 / 列宽调整 /
键盘导航与无障碍。实际用法里这两张表**没有**排序绑定、没有列宽定制、没有选择绑定，
那些系统行为一件都没用上，代价却全部落在表面层：不透明底色、隔行底纹、表头列分隔线。

**③ 改法**：运行组件表与累计统计表改为**卡自己画**——`VStack` + 列头 + 行 + 1pt `Divider`，
行高 `List.compactRowHeight`(42)、行内 `Callout`、列头 `captionMedium` / `inkSecondary`，
左沿与同一张卡的 `CardHead` 同为 `Spacing.md`。`Layout` 新增 3 个列宽 token
（`monitoringWorkerNameColumnWidth` 380 = 稿 `COLS` / `monitoringSampleColumnWidth` 84 /
`monitoringMetricValueColumnWidth` 110），删掉只服务系统表的 `monitoringWorkerRowHeight`、
`monitoringTableHeaderHeight` 与 `tableHeight(for:)`、`maximumTableRows`。
每行保留语义色与字形（`Label(state, systemImage:)`，§9「状态不只靠颜色表达」）与
`.accessibilityElement(children: .combine)`；容器保留 `accessibilityLabel`。

**④ 实测（2026-09-16 22:32）**：`scripts/macos_app_build.sh --configuration Debug` → **BUILD SUCCEEDED**。
复刻同一段结构的离屏探针（1220 宽、暗色）：卡片自然高 **266**（补上真实 `CardFoot` 的按钮 28pt
与 `padY 12` 后 ≈ 280，与稿实测的 280.2 同档），视图树里 `NSTableView = 0`、`NSScrollView = 0`
——这两样正是本轮要去掉的东西。

**⑤ 未验证**：装机后的实际观感（agent 不截屏、不驱动界面，UI 自动化须当次明确授权）；
窄窗（1120pt）下 380pt 第一列与「状态」列的关系只有目视能确认；
未运行单元测试与 UI 自动化。回退 = 这一段视图改动加 3 个列宽 token
（两处 `VStack` 换回 `Table`、行高/表头 token 复原即可）。

**⑥ 裁决**：本条推翻「决定 11」的适用范围，理由与检查点见 §12.4 决定 17。

#### 第六十九轮：运行监控的耗时单位改成毫秒（2026-09-17）

**① 用户当轮反馈**（装机截图一张，红框圈住累计统计表的「累计平均」列）：「时间单位改 ms」。
截图里那一列是 `0.001 秒` / `0.064 秒` / `0.008 秒`——本机服务的响应时间本来就在
毫秒这一档，写成秒要靠小数位分辨快慢。

**② 改法**：新增展示层口径 `RuntimeLatencyPresentation`（`RuntimeMetricsSampler.swift`），
`text(seconds:)` 把秒换算成毫秒：`0.4126` → `413 ms`、`0.001` → `1 ms`、
`0.0004` → `0.40 ms`（亚毫秒保留两位，不把真实的耗时写成 `0 ms`）、`0` → `0 ms`；
无障碍口径另给 `spokenUnit = "毫秒"`。
走这一处的有：首屏「合成 / 识别耗时」、不同音色类型的合成耗时、累计统计的「累计平均」
（`RuntimeHistogramPresentation.unit(forMetric:)` 对四条耗时直方图返回 `ms`，
`formattedAverage(_:unit:)` 负责换算）、历史档耗时卡与 p95 副行、右轴刻度与图例
（刻度仍在秒域算，读数换成毫秒）、折叠详情行、复制摘要、AX 描述符的序列名与数值。
**音频时长与历史跨度不在本轮范围内**：它们是另一种量，仍按秒 / 分钟说人话。

**③ 实测（2026-09-17 18:41）**：`scripts/macos_app_build.sh --configuration Debug` →
**BUILD SUCCEEDED**；`xcodebuild … build-for-testing`（含单元测试与 UI 测试目标）→ **编译通过**。
同表达式在 `swift -` 里复算：`0.4126 → 413 ms`、`0.001 → 1 ms`、`0.064 → 64 ms`、
`0.0004 → 0.40 ms`、`0 → 0 ms`、`3.2 → 3200 ms`。

**④ 未验证**：单元测试与 UI 自动化**未运行**（按 AGENTS.md 需当次明确授权，本会话没有）；
装机后的实际观感（右轴刻度变成 `0 / 250 / 500 … ms` 后是否仍好读、窄窗下「累计平均」
这一列是否会挤）只有目视能确认。回退 = 恢复 `RuntimeLatencyPresentation` 的四处调用与
两条图例文案。

#### 第七十轮：面向用户的词汇（2026-09-19）

**① 用户当轮反馈**（原话）：「我亲自体验了下，体验非常糟糕，用户门槛极高，还有一些用户
看不懂的词汇，什么分人啊什么的。你应作为产品经理，面向用户体验打造，提供低门槛用户体验，
高级功能留给用户探索，界面要干净美观，非主界面要均可收起，一次性设置应仅在必要时的最高
恰当时机再打扰客户」。

**② 改法**：把这一句落成一条规范（新增 §4.2 词汇表），并按表清掉全 App 的用户可见词：
档位名（`Quality` / `Balanced` / `Light` → 精准 / 均衡 / 轻量，含侧栏状态行、档位卡、会话
右栏、设置里那句换档提示）；服务状态能力行（`VoiceDesign` / `Base` / 音色复刻 / 实时语音
VAD / `capability` / 「词级时间戳由 ASR 原生提供」）；「运行信息」的「常驻 worker」（并为它
加映射：`voice_design` / `voice_clone` / `tts` 会原样漏进这一页，现在翻成语音设计 / 音色克隆 /
内置音色）；模型页的三张档位卡（副行与三行规格改成「说话人区分 / 音色创作 / 识别与配音」，
机器名收进开发者详情）与「模型制品 → 模型文件」；诊断页的检查项标题与逐项备注
（`ASR 制品` → `识别模型`、`受管运行时` → `运行环境`、`Base TTS` → 内置音色那一版模型）；
音色克隆页的「声音复刻 → 音色克隆」与「预检 → 检查」；服务状态那条控制通道状态行
（`本地控制通道已就绪` → `可以在这里管理服务`）。落地页从「服务状态」改成「语音助手」
（`ControlCenterView.landingRoute`，会话规格里的 D15 一并结清）。`figma-kit/main.js` 同轮同步。

顺带修掉离屏渲染看出来的两个缺陷：控制通道那一条把「影响」写进了取值里，于是页面上出现
「影响：影响：启动、停止、换档都能用」；`residentWorkerText` 直接把服务的
`warm_capabilities` 拼给用户看。

**③ 实测（2026-09-19，本机锁屏）**：`xcodebuild … build` → **BUILD SUCCEEDED**；
`NSHostingView` 离屏工装（`/tmp`，不占屏幕、不需要解锁）重渲染 14 个页面，模型页、服务状态
页、音色创作页与诊断页逐张核对：三张档位卡的九格取值在 76pt 标签列内不折行，「已加载的
模型」等行取值到位。`node --check figma-kit/main.js` 通过。

**④ 未验证**：真机走查（本机全程锁屏，`cua.getState()` 报锁）、UI 自动化（AGENTS.md 要求
当次明确授权，本会话没有）；`figma-kit` 的改动**尚未重新导出 4K PNG**，导出物与本轮文案
存在时间差，重新导出前不要把旧 PNG 当作验收基线。回退 = 逐条恢复本轮的文案常量
（`SpeechRailProfilePresentation`、`ControlAgentRegistration.impact`、
`ModelManagementView.profileSpecs/profilePurpose`、
`PreflightDiagnosticsView.checkTitle/note(for:)`、`ControlCenterView.landingRoute`）。

#### 第七十一轮：模型文件的精度只有一套说法（2026-09-23）

**① 用户当轮反馈**（原话，五句递进）：「模型信息要清晰」「未量化是不是也有位数？」
「对拉齐到同一维度展示」「对齐」「采用用户更能清晰的认知的统一文案表达」。

**② 问题有两层，一层是文案一层是数据**。模型文件表的第四列叫「量化」，值却已经在说精度
（`8-bit` / `bf16`）——同一列里两种说法：「量化」是内部分法，用户要问的是「多少位」。
更根本的是服务只下发 `quantization.bits`：未量化制品的位数**在载荷里根本不存在**，
界面只能写「未量化」——一个否定说法，答不了用户的那一问。

**③ 改法（服务 → 契约 → App → 稿，同一维度贯通）**：

- **目录 schema**：`QuantizationSpec` 新增 `dtype`（`bf16` / `fp16` / `fp32`），与 `bits`
  **互斥**；未量化制品必须声明 `dtype`；档位的 aligner 精度声明必须与制品 `dtype` 说同一件事。
  于是 `quantization` 这一行形状对**每一份**权重都成立，不再有「这一行读不出位数」。
- **载荷**：`model_catalog_payload` 把不在目录、但同样按档位供给的锁定分人资产
  （`diarization-coreml`，上游 FP16 变体）按 catalog 制品的同一行形状下发
  （`required_by = [balanced, quality]`）。它此前既是分人输入、又被列成「已检测但未纳入
  当前目录」，而表里没有它——现在「模型文件」这张表就是**这一档要用的全部文件**。
- **App**：列名与开发者详情标签统一为「精度」；取值统一读位数——量化的读 `8-bit`，
  未量化的把权重数值格式换算成 `16-bit`（`bf16` / `fp16` → 16、`fp32` → 32），
  位数读不出来时写「未读取」，不编。`mlx`、`group 64`、`bf16` 这些格式名只解释「怎么做到的」，
  留在开发者详情（`QuantizationSpec` 的字段名也是内部名，按 §4.2 不上屏）。
- **稿**：`figma-kit/main.js` 的 `screenModels` 同轮同步——卡头标题「模型制品 → 模型文件」、
  列头「量化 → 精度」、五条样例行改成位数（`8-bit` ×3、`16-bit` ×2）、卡头说明换成应用的那一句、
  脚注说明换成应用的说法（「谁在说话在补齐前用不了」）。

**④ 实测（2026-09-23）**：`model_catalog_payload` 实际输出 8 行，每行都有精度值
（`aligner-bf16 bf16` / `asr-1.7b-q8 8-bit` / `diarization-coreml fp16` …），
精准档取该档文件得 5 行、列值 `8-bit` ×3 + `16-bit` ×2；`pytest --no-cov` 的
`test_model_commands` / `test_model_presets` / `test_model_identity` / `test_installer` /
`test_model_catalog_builder` / `test_app_contract` 全绿（新增 5 条：缺 `dtype`、`bits` 与
`dtype` 并存、档位与制品 `dtype` 不一致、CoreML 行形状、无分人档位不出该行）；
`scripts/macos_app_build.sh --configuration Debug` → **BUILD SUCCEEDED**；
`node --check figma-kit/main.js` 与 `node audit.js` 通过。

**⑤ 未验证**：真机走查（未重装 App；UI 自动化按 AGENTS.md 需当次明确授权，本会话没有）；
`figma-kit` 的帧**未重新导出**，导出物与本轮文案存在时间差，重导出前不要把旧帧当验收基线。
回退 = 恢复 `ArtifactQuantizationPresentation`（列值改回 `bf16`）、列名与开发者详情标签改回
「量化」，以及 catalog 的 `dtype` 字段与那 5 条测试。

## 12. 风险与未决

### 12.1 多角色叙事

早期概念包（`docs/design/archive/2026-09-12-macos-app-design-package/`）描绘了“粘贴小说 → 自动分角色 → 逐段生成”的工作台。当前服务契约**不提供**该能力，本次重设计不引入它。

如果产品方向确实要走到那一步，正确顺序是：先由服务端契约提供分段与多说话人 TTS，再设计界面；否则界面会承诺后端做不到的事。

### 12.2 与现有 active 设计系统的关系

本包与 `macos-app-design-system.md` 在材质、圆角、颜色 token 上直接冲突。若本提案获批，必须**同步修订**那份文档并更新其验收清单；不允许两份规范长期并行。

### 12.3 尚未验证

- **深色已离屏取证**（第三十七轮：八页深色扫查、页面底 #1E1E1E / 卡片 #171717、
  `StatusTone` 与系统语义色逐字节相同）；**Increase Contrast 在离屏环境不可测**（第三十七轮实测：
  高对比外观名在本机解析成浅色混合体，`hc-*` 渲染不作证据），**Reduce Motion 与 VoiceOver 仍未实测**。
  **Dynamic Type 在 macOS 上不可用动态字号触发**——`.dynamicTypeSize` 对系统文本样式不生效（第三十七轮
  实测），真正的入口是系统「辅助功能 → 显示 → 文字大小」，只能在真机上改设置后走查；
  该矩阵仍缺**桌面人工**部分。
- VoiceOver 实测仍未执行。
- `ConcentricRectangle` 已在 Xcode 26 SDK 上编译通过并用于所有容器表面；`glassEffect` 未在本 App 中使用（窗口与侧边栏交给系统）。
- App 侧已大量落地：Swift 源码已修改，`./scripts/macos_app_build.sh --configuration Debug` 与
  `xcodebuild … build-for-testing` 多轮通过。**仍未运行任何单元测试或 UI 自动化**（AGENTS.md：自动化验收需当次明确授权）。

已核对的部分（见 §11.6）：Figma 产物的帧尺寸、绑定归属、颜色解析值、越界（含卡片内部）与占位灰计数由插件 audit
实测输出（`all clean`，`bind errors: 0`）；同一目录的 `figma-kit/audit.js` 提供**离线**静态自检
（2026-09-16 实测 `audit: clean`：颜色变量 23/23、图标 24/30、文本样式 9/9 全部解析），改动 kit 时不必先开 Figma。
16 帧已导出 1x PNG 并逐页目视确认，浅色与深色两列都已看过。
App 侧的一致性证据见 §11.6 第四至第七轮：结构、文案、状态矩阵与 token 都逐项对过源码，
但**目视与交互结论仍缺**——所有「看起来对不对」的判断都要等桌面走查。

### 12.4 决策记录与未决项

已于 2026-09-15 决定：

1. **采纳**“单强调色（钢轨青）+ 声音语义琥珀”的配色收敛；`AcousticMaster.*` 收敛为 `VoiceAccent`，不再保留更重的品牌机架视觉。
2. **纳入**作品删除/重命名（D12），随「我的作品」页面批次一起实现（删除需破坏性确认）。
3. 落地按 §10 阶段推进，从阶段 1 外壳开始。

4. **已解决（2026-09-15，阶段 2）**：浅色强调色的两处数值冲突（资产 `#23687D` vs Figma/`Color.rail` `#2A4E57`）
   按“交给系统”收口——`Color.rail` 改为 `Color.accentColor`，App 跟随用户在系统设置中选择的强调色，
   不再由一个写死的浅色数值定义品牌色。Figma 变量保留为设计参考，不再作为运行时事实来源（§11.6 已按此记录）。

5. **决定（2026-09-16，第四十六轮）：圆角取「容器声明一处 + 叶面同心推导」，并且显式声明 12 / 8。**
   §5.3 原文是「不使用手挑半径」，本次实现有意偏离：`.concentric` 只在**祖先提供了容器形状**时
   才推得出半径，而自绘视图默认不提供，于是全应用 18 处 `ConcentricRectangle()` 曾一起退化成方角。
   现在 `Corner.container = 12`（稿 `radius/container`）是全应用唯一自声明的半径，
   `Corner.nested = 8`（稿 `radius/control` / `radius/field`）只在「容器给不出半径」时兜底；
   容器用 `RoundedRectangle(12, .continuous)` 并 `.containerShape()` 发布给子层，叶面用
   `ConcentricRectangle(corners: .concentric(minimum: .fixed(8)))` 跟随。离屏实测（第四十六轮）
   证明容器面就是 12pt `.continuous`、叶面是 `容器半径 − inset`、无容器时落到 8。
   保留这条决策的代价是「有两个数值」，收益是渲染结果确定、可评审、只改一行就能整体对齐；
   **检查点**：全应用只有这两个半径数值，新增半径必须改进 token 而不是就地写死。
   相关口径与量测见 §11.6 第四十六轮。

6. **决定（2026-09-16，第四十八轮）：控件不参与同心推导，固定取 `Corner.nested`。**
   同心推导的半径是「容器半径 − 内缩」，内缩 ≥ 12pt 时推导值 ≤ 0，叶面直接画成方角；
   而卡内控件（输入槽、键帽、图标框）的内缩正好是 `Layout.cardInset = 20`。所以
   **表面**（行选中底、卡片、面板）继续用 `Corner.nestedShape` 跟随容器，**控件**用
   `Corner.controlShape = RoundedRectangle(8, .continuous)` 固定取值。半径数值仍然只有
   12 / 8 两个（`controlShape` 复用 `nested`），但**形状有三处声明点**：
    `containerShape`（容器）、`nestedShape`（叶面表面）、`controlShape`（控件）。
   相关口径与量测见 §11.6 第四十八轮。

7. **决定（2026-09-16，第五十轮）：中性表面阶梯不再交给系统语义色，改用稿的四级取值。**
   §5.4 原文是「系统拥有中性色阶」，但那条原则的**前提**（系统有分级）已被本机实测否定：
   `windowBackgroundColor` / `controlBackgroundColor` / `textBackgroundColor` 在两种外观下
   逐位相同。于是 `canvas` → `#E8E8EA` / `#201E21`、`field` → `#FFFFFF` / `#2B292C`、
   `recessedField` → `#F5F5F7` / `#232124`（`dynamicColor` 显式取值，`named:` 避开资产目录里
   那两个同名死资产）。**检查点**：新增表面层级必须改进这三个 token，不得就地写死颜色；
   §5.4 的表述已按此改写。回退 = 把三行换回三行系统语义色。证据与验证见 §11.6 第五十轮。

8. **决定（2026-09-16，第五十一轮）：可编辑输入槽的边界取稿的 `border/strong`，且「有边界」
   只表示「可输入」。** 三档中性色里输入槽与卡片只差一档（`#F5F5F7` vs `#FFFFFF`），
   单靠填充在浅色下仍要靠很近才看得出；稿对输入本来就有 1pt `border/strong` 的配方，因此
   新增 `Surface.borderStrong` 并只给 `.speechRailRecessedSlot()` 使用，状态/操作条
   （`.speechRailField()`）保持只有底色。**检查点**：新增可编辑控件必须带这圈边界，
   新增非输入槽不得带——否则「有边框」不再等于「可以输入」，用户的辨识问题会原样回来。
  代价：`separatorColor` 之外多了一个描边 token（都是稿值，不是自挑颜色）；
  回退 = 去掉 `showsBoundary: true` 与 `Surface.borderStrong`。证据见 §11.6 第五十一轮。

9. **决定（2026-09-16，第五十三轮）：可编辑表面分两档，边界属于整张编辑卡。**
   `SpeechRailSlotModifier` 分三个 case：`editableInput`（表单字段，`surface/field` +
   `controlShape`）、`editorCard`（编辑卡，**`surface/content` + `containerShape`**）、
   `statusBar`（状态条，`surface/panel`，无边界）。配音台文稿卡与音色创作描述卡改用
   `editorCard`，并把页脚移进卡内、去掉描述卡里那个内缩的第二个框。
   **检查点**：新增可编辑表面必须选一支并带边界；**页面级编辑卡不得降级成表单字段**
   （深色下会凹进一格）。代价：几何从一处声明点变成两处（控件 8 / 容器 12），
   但两者都是稿的既有 token（`radius/field` / `radius/container`）。
   回退 = `editorCard` 分支改回 `inputField` + `controlShape`。证据见 §11.6 第五十三轮。

10. **决定（2026-09-16，第五十五轮）：页面身份放 `.navigation`（详情列 leading）并在槽内左对齐，
    不跟稿的窗口左沿 78pt。** 依据是「身份必须恒定」——`.principal` 的落点是剩余空间中点，
    音色库 / 我的作品（有工具栏搜索框）与其余六页实测差 **135pt**，切页时横跳；`.navigation`
    八页恒定在 x=252。稿把标题画在红绿灯右侧 78pt，那一格被系统侧栏切换按钮占用且
    `.toolbar(removing: .sidebarToggle)` 实测不生效（视图树复核），要拿到只能自绘标题栏，
    与 §5.2 / D1「工具栏层归系统」冲突，故不跟。
    **检查点**：头部身份只能有一条声明（组合根）+ 一个落点（`.navigation`）；
    新增「窗口居中标题」这类需求必须另开决策，不能把 `.principal` 混回来。
    回退 = 两行（`placement` 与 `alignment`）。证据见 §11.6 第五十五轮。

11. **决定（2026-09-16，第五十六轮）：运行监控的表几何跟系统 `Table`（表头 28 / 行 24），
    不跟稿的 32 / 39。** 依据是用户当轮给的口径——运行监控按 `/metrics` 暴露的指标与
    Prometheus / Grafana 那一族的呈现惯例做，**可不完全按 Figma**。本机 macOS 26 / arm64 实测
    系统 `Table` 是**表头 28 / 行 24**（§11.6 第二十四轮 ①，读 `NSTableView.headerView.frame.height`
    与 `rowHeight`，与内容无关）；稿的 `workers` 是 Figma 手画的静态表，**表头 32**（padY 9 +
    `Caption/Medium` 13.5）/ **行 39**（padY 11 + `Callout` 17.4）。要逐像素对齐就得把这层换成
    手搭网格，代价是丢掉排序、列宽调整、键盘导航与无障碍这些系统行为，也与 §4.2「列表交还系统」
    相反；而 Grafana 族的指标表本来就是紧凑行，不是稀疏行。
     **检查点**：运行监控的两张表继续用 `Table`，高度按 `28 + 24 × n` 预留；新增监控表沿用同一
     公式，不得再就地写 `36 + 26 × n`。**代价**：与帧差 4 / 15pt 的密度差被接受为「更接近监控面板
     惯例」；若将来要逐像素对齐，这是唯一需要推翻的裁决点。证据与量测见 §11.6 第二十四轮。
     **→ 2026-09-16 第六十八轮起，这两张表改由应用自己画（列头 + 行 + `Divider`），本条在
     这两张表上作废**：系统表的底色、隔行底纹与列分隔线都不在 token 里，见决定 17。

12. **决定（2026-09-16，第五十八轮）：设置窗口放弃系统 grouped `Form`，改用应用自己的卡片。**
    依据是用户对「设置窗口行卡」这条未决项的**方案 A** 选择。理由不是数值调不齐，而是两条
    **结构性**冲突：原生行卡恒等于「背后底色 −3%」（因此画不出帧那种白卡坐在灰地板上，
    `.listRowBackground` 亦无效），且它自己给 20pt 内缩（§7.10 与帧要 16 / 608 宽）。
    换掉的只是**容器**：`Toggle` / `Picker` / `Slider` / `LabeledContent` 仍是系统控件
    （`.toggleStyle(.switch)` 显式声明，否则离开 `Form` 会掉回 Checkbox）。
    **检查点**：设置行只能经 `settingsSection` / `settingsRow` / `settingsValueRow` 声明，
    几何一律取 `SettingsView.Metrics`（`paneInset` / `sectionGap` / 行内边距）；新增行不得在
    页面里就地写数值。**代价**：grouped 表单自带的行分隔改由 `settingsRowSeparator` 显式声明
    （只在稿画了 hairline 的地方加），焦点顺序仍由声明顺序决定。
    回退 = 把三个辅助函数换回第五十六轮的 `Form` + `Section` 版本（单文件、单次 revert）。
    证据见 §11.6 第五十八轮。

13. **决定（2026-09-16，第五十九轮）：配音台的生成结果条维持规范的系统材质
    （`.speechRailSurface(.elevated)`），不跟稿的 `surface/railTint`。**
    这条冲突从第三十五轮挂到 §5.4 末尾，本轮按证据结掉。三条依据：
    ① §5.2 的「浮起层」一行**点名**了「浮动的播放/生成结果条」，不是可推定的空白；
    ② §5.4 已写明稿的六个手挑淡底（`readyTint` / `attentionTint` / `criticalTint` /
    `infoTint` / `railTint` / `voiceTint`）与系统色的渲染差**每通道 ≤6/255**，
    而系统色会随外观、Increase Contrast 与用户选择的强调色自适应——按稿改等于
    **用 ≤6/255 的色差换掉三条系统自适应**，是净负；
    ③ 应用对 `railTint` 在稿上的**另外几处主要用法**（侧栏选中行、列表选中行）早就
    改成了强调色派生值（`Surface.selectedFill = Color.rail.opacity(0.16)`，
    `Color.rail = Color.accentColor`），单独把结果条改回 `railTint` 会让同一套
    「选中 / 浮起」语义在应用内部出现两种来源。
    **检查点**：窗口级浮层（结果条、浮动播放条）只用 `.elevated` / `glassEffect`；
    不得新增写死的 `railTint` 一类淡底常量，`Color.rail` 继续只走系统 `accentColor`。
    回退 = `CreatorSurfaceViews.swift` 里 `resultBar` 的 `.speechRailSurface(.elevated)`
    一行，改成新的 railTint 表面分支。

14. **决定（2026-09-16，第五十九轮）：编辑卡常驻边界维持 1pt `Surface.borderStrong`
    （灰），不跟 4x 帧的 1.5pt `accent/rail`。** 依据三条：
    ① 帧给的是写死的浅 `#2A4E57` / 深 `#4FA4BA`，而 §5.4 已把强调色定为跟随系统的
    `AccentColor`、并在 §12.4 决定 4 里退役了那两个写死值——按帧画等于把退役值请回来，
    用户换强调色时它会不跟随；
    ② 「有边界」在 §5.1 / 决定 8 里是**状态**语义（= 可以输入），强调色是**焦点**的职责
    （§11.6 第五十一轮：聚焦态才换 `accent/rail` 2pt）；常驻 1.5pt 强调色边框会与焦点环
    争同一层语义，反差也比稿自己给的 `border/strong` 弱；
    ③ 那一帧属更早一代：同页其他卡片还带 `#DCDCE0` 1pt 描边（当前脚本的 `card()` 已把
    卡片描边整体去掉），它的编辑卡高 568.5pt 也还是 §7.1 已废除的「占满剩余高度」。
    **检查点**：编辑卡常驻边界只有 `Surface.borderStrong` 1pt；强调色只出现在焦点态与选中态。
    回退 = `SpeechRailSlotKind.editorCard` 一支（描边色 + 线宽两行），结构不动。

15. **决定（2026-09-16，第六十轮）：音色库与我的作品的列表选中行取稿的 `surface/railTint`，
    并把「手挑淡底不采纳」改成带一条特例的规则。** 依据是本轮实测的系统行为：
    `List(selection:)` 的选中高亮在**活跃窗口**下是**系统强调色实心** `#007CE7`，
    未强调时是 `#DCDCDC`——两种状态**既不是稿的淡底、也不跟随本 App 的强调色**
    （`#23687D` / `#4FA4BA`），即这里的系统默认值同时偏离设计稿与应用自身。
    实现只用了 `listRowBackground` 一个修饰符（`.tint()` 无效、行内容 `.background` /
    `.overlay` 会被选中材质合成掉；五种写法逐像素实测见 §11.6 第六十轮 ②），
    因此 `List(selection:)` 的绑定、方向键与无障碍 selected 语义**全部保留**。
    **检查点**：`Surface.selectionTint` 只服务「列表选中行」，不得扩散到按钮、状态条或胶囊底色；
    §5.4 的六个手挑淡底照旧不采纳，**例外只有这一处**（与决定 13 那处「规范优先」的裁决并存，
    两者不矛盾：结果条是「系统材质换稿的淡底」，这里是「稿的淡底换系统的实心强调」——
    判据是同一条：**能用系统自适应的就用系统，系统那一档同时偏离稿与本 App 时才取稿值**）。
    **代价**：§5.4 多一个例外分支，Increase Contrast 取同值（装饰性淡底，HC 的可辨识度由行内
    ink 与分隔线承担，与 `attentionTint` 同口径）；实测选中行是 `#E3EDF1`，比稿值亮约 3%
    （ΔE ≈ 1，未追）。回退 = token 一段 + 两处 `.listRowBackground(...)`。

16. **决定（2026-09-16，第六十轮）：音色库 / 我的作品剩余三处「帧 vs 应用」按证据各自收口。**
    - **我的作品的行动作：跟当前 kit，不改。** kit 的 works 行本来就是
      `play` + `download` + `ellipsis` 三颗（`main.js:1692-1694`，`acts` 宽 92 = 3 × 28 + 2 × 4，
      与应用的 `actionColumnWidth` 同一个式子），只有 4x 帧是两颗——这条此前挂在
      「删按钮是减功能，等拍板」，实际是**证据问题**：kit 更新，帧属上一代。
      应用那颗省略号打开的就是行右键菜单的同一份内容（`Menu { workContextMenu(work) }`
      与 `.contextMenu` 同源），删或不删都不增减功能。
    - **详情列宽度：维持 360（最小 300 = 稿值）。** 这两页的详情列含**应用自有**的
      「试听文案」一段（上限 4096 字，稿上没有），压到 300 会让那一段与波形同时变窄；
      稿的 300 是给没有那一段的版本画的。**检查点**：改这一档要连带复核那一段的换行。
    - **详情列的「试听文案」输入与动作区主按钮：保留。** 两者都是应用自有入口
       （前者第四十五轮 ⑤ 已记为「临时指令导致、可与 Figma 不一致」）。
      要按帧去掉动作区那颗主按钮只需删那一块（动作带会从 104 回到稿的 88）。

17. **决定（2026-09-16，第六十八轮）：运行监控的两张表改由应用自己画，不再用系统 `Table`；
    决定 11 在这两张表上作废（它的其余部分——「监控表按内容取高、行几何不逐像素追帧」——仍有效）。**
    依据是用户当轮给的现象（装机界面上这张卡「突兀」）加上本轮实测：系统表铺一层不透明底色
    `#1E1E1E`，再给偶数行叠 **5% 白**的隔行底纹（实测 `(42,40,51)`），并自带表头列分隔线
    与 5pt 表体内容内缩；卡面是 `Color.field`(`#2B292C`)——同一张卡里因此出现三种表面，
    其中两种不在 token 里，而那条底纹读起来像「这一行被选中了」（假的可选暗示）。
    决定 11 当年换来的是系统行为（排序 / 列宽 / 键盘导航），但这两张静态表**一件都没用上**
    （没有排序绑定、没有选择绑定、没有列宽定制），所以「保留系统行为」不再是留它的理由；
    几何仍与决定 11 同口径：行高 42、按内容取高、不出现滚动条。
    **检查点**：运行监控的表一律由应用画（列头 + 行 + 1pt `Divider`），新增监控表沿用
    `List.compactRowHeight` 与 `Layout.monitoring*ColumnWidth`，不得为省事换回 `Table`。
    **代价**：失去（本来没用的）系统排序与列宽调整。回退 = 两处 `VStack` 换回 `Table`
    并恢复第六十五轮那两个几何 token。

未决：

- **头部（工具栏）只有离屏证据（2026-09-16 第五十五轮）**：身份槽已改到 `.navigation`，
  八路由 + 最小窗口的落点由窗口视图树实测恒定；但离屏宿主是普通 `NSWindow`，**不带** App
  场景的 `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`，所以真机上的工具栏样式
  （带高、材质、紧凑态）与落点仍需桌面走查确认。同一轮还纠正了一条取证方法：
  `--theme` 的主题 PNG 在 `models / overview / monitoring / voiceDesign` 四个路由缓存出来是
  **黑图**，不能拿来做逐像素比较。
- **表面层级已在第五十轮按方案 A 落地**（`canvas` / `field` / `recessedField` 取稿的四级取值），
  证据、落地位置与坑见 §11.6 第五十轮。**仍在的两条**：①三个中性 token 的 Increase Contrast
  取值与普通值同值，HC 下四级会不会再次塌成一级，需要真机复核；②`.inspector` / `.sidebar`
  两列的底色在离屏环境解析不出来（系统材质），所以 Inspector 那一列的底色只做到代码层。
- **输入槽边界的高对比取值未验（2026-09-16 第五十一轮）**：`Surface.borderStrong` 的 `hc*` 分支
  暂与普通值同值（本机把高对比外观名设到应用/宿主后渲染仍回落到普通浅色，与第三十七轮同一条
  结论），因此「HC 下这圈边界是否够用」需要真机复核。同一轮的其余未验证项：真机目视/桌面走查、
  单元测试与 UI 自动化（离屏量测与 `swiftc` 编译均已完成，见 §11.6 第五十一轮）。
- **设置窗口的行卡已按帧重画（2026-09-16 第五十二轮提出、第五十八轮关闭）**：第五十二轮
  记下「原生 grouped `Form` 的行卡是背景 −3%、给不出稿的 `#FFFFFF` 行卡」，并把它挂在
  「要么放弃原生 `Form`、要么接受原生观感」。第五十八轮按**用户选定的方案 A** 落成
  「放弃原生 `Form`、用应用自己的卡片重画三个设置页」：行卡现在是 `Color.field`（`#FFFFFF`）、
  608 宽、距窗口左右各 16pt（§7.10）；内容区顶到首卡从 46 变成 54。**仍存的两条残差**
  （行高 54 / 39 vs 帧 59 / 42、hairline 用系统 `separatorColor` 而帧是 `border/separator`）
  以及「为什么不再去凑帧的行高」见 §11.6 第五十八轮 ④。取证方法的两条更正（titled 宿主压暗
  2.5%、`--top` 不能省）也在那一节。
- **档位卡的间隔与悬停已收口（2026-09-16 第五十二轮）**：可见间隔 27.5 → **12pt**（帧 12），
  左通槽 28 → **20**，卡宽 354.5 → **376**（把窗口拉到装得下、去掉离屏的 17pt 滚动条槽之后，
  与帧逐项一致）；样式的状态色改成叠在底色之上的同一背景层，不再被卡片的不透明底色盖住。
  取证与改法见 §11.6 第五十二轮。**仍未验的是悬停/按压的观感**（离屏没有指针）。
- **编辑卡边界是灰还是 rail（2026-09-16 第五十三轮提出、第五十九轮关闭）**：裁决见
  §12.4 决定 14——**维持 1pt `Surface.borderStrong`**；帧的 `accent/rail` 1.5pt 属更早一代，
  且用的是 §5.4 / 决定 4 已退役的写死强调色。仍是一行可回退的判断
  （`SpeechRailSlotKind.editorCard` 分支），结构不动。
- **编辑器页脚与描述框结构已按帧收敛（2026-09-16 第五十三轮）**：详见 §11.6 第五十三轮。
  同轮遗留：焦点环移到整卡之后的观感未验（离屏无法聚焦），`inputField` 的 HC 取值未验。
- **视觉与无障碍矩阵未实测**：本机未获 UI 自动化授权，Light/Dark、Increase Contrast、Dynamic Type、
  Reduce Motion、VoiceOver 顺序与列表 `空格` 试听均只完成代码层验证。
- **页面最小高度与真实窗口最小尺寸的关系（第三十轮）**：离屏已证明「每页内容最小高度 ≤ 620pt，
  小于声明的 720pt 最小窗口高」，但真机上 SwiftUI 是抬高窗口最小高度、还是把页头裁掉，离屏分不出来；
  同一批离屏量测还有两个已知边界：`List` 行高在无窗口环境不实例化、原生容器内部几何读不到（第二十三、二十五轮）。
- **本机运行的 App 落后于工作树（2026-09-15 提出，2026-09-16 13:44 关闭）**：`~/Applications/SpeechRail.app` 的二进制
  构建于 2026-09-15 21:32（当时的 HEAD 是 `49cf4d8d`），而本轮全部 UI 改动
  （含输入卡高度、页头最小高度、控制条几何、运行监控密度调整等 22 个文件）都还在工作树里未提交、
  未被任何构建包含——所以桌面走查看到的仍是旧界面。重新构建需要先接受 Xcode 许可
  （`xcodebuild -checkFirstLaunchStatus` 返回 69，提示 `sudo xcodebuild -license accept`）；
  覆盖安装 `~/Applications/SpeechRail.app` 属破坏性操作，需用户当次明确授权后再做。
  **2026-09-16 更新：这一步已完成**——用户当轮明确授权覆盖安装，随后按 §11.6 第三十五轮的
  预览构建路径（`swiftc` 直编，绕开仍被许可挡住的 `xcodebuild`）重建并覆盖安装：
  已安装件 `~/Applications/SpeechRail.app` 的二进制 mtime 变为 2026-09-16 07:28
  （`CFBundleShortVersionString` 2.6.4 / `CFBundleVersion` 8，与 `project.pbxproj` 的
  `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 一致，未擅自改版本号）、ad-hoc 签名、
  结构（Frameworks / XPCServices / Library/LaunchAgents）与文件清单与上一版**逐项相同**、
  `codesign --verify --deep --strict` 通过。回退点：旧的整包 ZIP 在
  `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260915-2132.zip`
  （旧二进制 sha256 `0c364c76…a4941a6`）。启动验证：`open` 后主进程与
  `com.speechrail.desktop.local-control.xpc` 均起来（说明 bundle 内的 framework 解析正常），
  10 秒后仍存活、无新的崩溃报告。**仍未走查**：界面观感、VoiceOver 顺序、Reduce Motion、
  Increase Contrast、深色材质在真实窗口里的表现。官方路径（`scripts/macos_app_build.sh`）
  仍需用户执行 `sudo xcodebuild -license accept` 后才可用。
  在此之前，「100% 校准后准出」只能停在离屏取证与代码层验证。
  **2026-09-16 13:44 关闭（第五十九轮）**：装机件换成**全树**构建产物
  （sha256 `3f5975e6…`，含第五十七轮的试听链路与第五十八轮的设置页重画），
  官方 `xcodebuild` 路径对全树返回 `BUILD SUCCEEDED`；回退点
  `…/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260916-1344.zip`。
  见 §11.6 第五十九轮 ①②③。**剩下的唯一准出门槛是 §12.5 的人工走查。**

**2026-09-16 11:48 装机（第五十三轮）**：官方路径 `xcodebuild … build` 已可用并返回
`BUILD SUCCEEDED`（不再需要 `swiftc` 直编的绕行），装机件与构建产物
`Contents/MacOS/SpeechRail` 的 sha256 相同（`ee9b24d5…`）、`codesign --verify --deep --strict`
通过、`CFBundleShortVersionString` 2.6.4 / `CFBundleVersion` 8 未改；`open` 后主进程
（pid 12892）与 `com.speechrail.desktop.local-control.xpc`（pid 12910）均在，20 秒后仍存活。
回退点：`…Backups/SpeechRail-2.6.4-8-installed-20260916-1148.zip` 与同名 `.app`
（10:23 那一版）。**仍未走查**：界面观感、VoiceOver 顺序、Reduce Motion、Increase Contrast、
深色材质在真实窗口里的表现，以及本轮新增的「焦点环画在整卡上」的观感。
  **2026-09-16 补充（第三十五轮）**：根因查明——Xcode 在 00:51 被换成 27.0，而许可记录仍是
  26.6，属「换版本触发的重新同意」；同轮找到一条不依赖 xcodebuild 的**预览构建**路径，
  产物 `/tmp/sr-appbuild/SpeechRail.app` 可直接双击运行来做界面走查（不覆盖已安装件、
  不作为发布件、未做启动验证，见 §11.6 第三十五轮）。官方路径仍需用户执行
  `sudo xcodebuild -license accept`，之后按 `scripts/macos_app_build.sh` 重建并（经授权）覆盖安装。
  **2026-09-16 08:13 再次更新（第四十一 + 四十二轮）**：两轮源码再次走同一条预览构建路径并覆盖安装，
  已安装件的二进制 mtime 变为 2026-09-16 08:13、sha256 `381bb0c8…b30a3656`（版本号仍是
  2.6.4 / 8，未改）、ad-hoc 签名、`codesign --verify --deep --strict` 通过、bundle 结构与文件
  数量（17 个文件）与上一版一致；启动后主进程（pid 43102）与 `…local-control.xpc` 均起来、
  27 秒后仍存活、无新崩溃报告。本轮起的回退点是
  `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260916-0813.zip`
  （装前那一版的整包，二进制 sha256 `5f210e89…fed30d1`）；上一版回退点
  `…-20260915-2132.zip`（`0c364c76…a4941a6`）仍在。**仍未走查**：界面观感、VoiceOver 顺序、
  Reduce Motion、Increase Contrast、深色材质在真实窗口里的表现。
  **2026-09-16 08:31 再次更新（第四十三轮）**：同一路径重建并覆盖安装，二进制 mtime
  2026-09-16 08:31、sha256 `6d86df57…a9941ebb`（版本号仍 2.6.4 / 8）、
  `codesign --verify --deep --strict` 通过、启动后主进程（pid 47909）与
  `…local-control.xpc` 均在。本轮起的回退点是
  `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260916-0831.zip`
  （装前那一版，二进制 sha256 `381bb0c8…`）。
  **2026-09-16 08:49 再次更新（第四十四轮）**：同一路径重建并覆盖安装（先 `kill -TERM` 精确 PID
  50111，再 `cp -p` 换二进制、`codesign --force --sign -`、`open -g` 后台重启，未抢前台）。
  已安装件二进制 mtime 2026-09-16 08:49、sha256 `c338b8c3…`（版本号仍 2.6.4 / 8；
  ad-hoc 签名会改写 Mach-O，所以**同一次构建在 bundle 内与裸签名的哈希本就不同**，
  本轮改用「二进制内含本轮新符号」校验：`rg -a RowActionGlyph` = 3 处、
  `previewWrapInsetY` = 2 处）。`codesign --verify --deep --strict` 通过、启动 20 秒后主进程
  （pid 55330）与 `…local-control.xpc`（pid 55333）均在。本轮起的回退点是
  `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260916-0849.zip`
  （装前那一版 = 第四十三轮，二进制 sha256 `6d86df57…`）。
  **2026-09-16 09:30 再次更新（第四十五 / 四十六轮）**：同一路径重建并覆盖安装（先精确
  `kill -TERM 55330`，再 `cp -p` 换二进制、`codesign --force --sign -`、`open -g` 后台重启，
  未抢前台）。已安装件二进制 mtime 2026-09-16 09:30（版本号仍 2.6.4 / 8；
  ad-hoc 签名会改写 Mach-O，所以按「二进制内含本轮新符号」校验：`rg -a RowActionGlyph` = 3 处、
  `previewWrapInsetY` = 2 处，与第四十四轮同一口径）。`codesign --verify --deep --strict` 通过
  （`valid on disk` / `satisfies its Designated Requirement`）、启动后主进程（pid 70892）与
  `…local-control.xpc`（pid 70894）均在。本轮起的回退点是
  `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260916-0930.zip`
  （装前那一版 = 第四十四轮，整包 sha256 `085d0a50…`）。
  **2026-09-16 09:42 再次更新（第四十七轮）**：同一路径重建并覆盖安装（精确 `kill -TERM 70892`
  → `cp -p` → `codesign --force --sign -` → `open -g`）。已安装件二进制 mtime 2026-09-16 09:42
  （版本号仍 2.6.4 / 8）、`codesign --verify --deep --strict` 通过（`valid on disk` /
  `satisfies its Designated Requirement`）、启动后主进程（pid 80344）与 `…local-control.xpc`
  （pid 80346）均在。本轮起的回退点是
  `~/Library/Application Support/SpeechRailAppBackups/SpeechRail-2.6.4-8-installed-20260916-0942.zip`
  （装前那一版 = 第四十五 / 四十六轮，整包 sha256 `e27513a8…`）。
  **2026-09-16 10:23 再次更新（第四十九轮，头部收敛）**：本轮换了做法——不再只换二进制，
  而是先整包备份（`…-installed-20260916-1023.zip`，整包 sha256 `b329baa9…`）、把旧包
  `mv` 到备份目录留作第二重回退点，再用 `ditto` 把 `/tmp/sr-build-check` 的 Debug 产物**整包**
  装到 `~/Applications/SpeechRail.app`。装机前先比对过两包的相对文件清单：各 17 个文件、
  逐项相同（Frameworks 两个、XPCServices 一个、Library、Resources、PkgInfo、Info.plist）。
  已安装件二进制 mtime 2026-09-16 10:16、版本号仍 2.6.4 / 8；
  `codesign --verify --deep --strict` 通过（`valid on disk` / `satisfies its Designated
  Requirement`，`ditto` 之后 ad-hoc 签名仍有效，未重签）；按符号校验：
  `PageIdentityToolbarItem` / `PageActionButton` / `reloadPageCommand` 各 3 处，
  `WorkspaceActionsMenu` / `workspaceTitle` 各 0 处。`open -g` 后台启动未抢前台，
  主进程 pid 30314 与 `…local-control.xpc` pid 30333 在 20 秒后仍在，无新崩溃报告。
  本轮起的回退点是备份目录里的
  `SpeechRail-2.6.4-8-installed-20260916-1023.zip` 与同名 `.app`（两者都是 09:42 那一版）。
  **2026-09-16 10:37 再次更新（第五十轮，表面层级）**：并行线宣布收工后，用**官方
  `xcodebuild` 路径**重建（`-derivedDataPath /tmp/sr-build-mine`，`** BUILD SUCCEEDED **`，
  14.7s 增量；`SpeechRailDesignTokens.o` / `ControlCenterView.o` 的 mtime 10:36 证明本轮改动
  进了产物），再整包备份（`…-installed-20260916-1037.zip`）→ 旧包 `mv` 到备份目录留第二重
  回退点 → `ditto` 整包装到 `~/Applications/SpeechRail.app`。装机件二进制 mtime 10:36、
  文件数 17（与上一版一致）、`codesign --verify --deep --strict` 通过、**构建产物与装机件
  sha256 相同**（`d23c7342…`）。`open -g` 后台启动（pid 46338），无新崩溃报告。
  回退点：`…-20260916-1037.zip` 与 `…-20260916-1037.app`（都是 10:16 那一版）。
  **注意**：本轮起装机件才包含表面层级；`strings` 查不到 `SurfaceWindow` 这类**短字符串**
  （Swift 小字符串内联进代码，不进 `__cstring`），符号校验要改用别的字符串或直接比 sha256。
  **2026-09-16 13:11 再次更新（第五十六轮，设置页「默认语速」行）**：精确 `kill -TERM 77854`
  （XPC 77855 随之退出）→ 整包备份 `…-installed-20260916-1311.zip`（装前那一版，二进制
  sha256 `a0bedb84…`，即 12:17 那一版）→ `ditto` 整包装到 `~/Applications/SpeechRail.app`。
  装机件二进制 mtime 12:54:20、sha256
  `79e6413e5f4a053f111051258ffefe3885eac34635e14b67905386c32d84d9a1`、**与构建产物逐字节相同**、
  文件清单仍 17 项逐项一致、`codesign --verify --deep --strict` 通过（`valid on disk` /
  `satisfies its Designated Requirement`）、版本号仍 2.6.4 / 8。`open -g` 后台启动未抢前台，
  主进程 pid 4934 与 `…local-control.xpc` pid 4946 均在、无新崩溃报告。
  **装的是 12:54:19 那次增量构建**（`SettingsView.o` 的 mtime 证明只重编了本轮改的文件，
  见 §11.6 第五十六轮 ③），**没有在 13:11 重建**——并行轨道 13:02–13:06 正在改 6 个文件
  （详情列试听链路），重建会把半成品打进装机件。所以装机件 = 工作树在 12:54 的状态。
  **回退点**：`…-20260916-1311.zip`（= 12:17 那一版）。
- **菜单栏面板与工具栏菜单的最终观感（第三十三轮）**：面板是系统菜单（`.menu` 样式），行高、
  内边距、分隔线由系统画；应用只把行的下限高度从 44 收到稿的 26。真实 `NSMenu` 里 26pt 的行
  最终会有多高、面板是否仍按 288 宽渲染、以及 `ControlMenuView` 的外层内边距（16）在系统菜单里
  是否被采纳，都需要构建后走查；若系统忽略了这些几何，结论就是「面板按系统菜单呈现，稿的
  `menuPanel` 只作示意图」，不再要求逐像素一致。
| 全局：任何页面避免文字密集、杜绝大量密集信息，采用渐进式披露 | 成立，运行监控最典型（首屏 7 个数字磁贴 + 能力矩阵 + worker 表 + 直方图表 + 资源表） | 运行监控首屏只留黄金信号 + 趋势 + 运行组件，其余收进默认收起的「逐指标明细」；新增 §7.6.1 全局密度约束 |

同轮还补齐了 §8 状态矩阵里两处「加载中」缺口（服务四页要求 `ProgressView`）：
`ServiceOverviewView` 在首次 health 读取有结果之前会先说「服务需要关注」，`RuntimeMonitoringView` 会先说「等待运行状态」，
两者都是把「还没读到」渲染成结论。现在两页都以 `ProgressView`（`正在读取服务状态…` / `正在读取运行数据…`）等待首个结果，
判据是 `lastHealthRefresh == nil && healthFailure == nil`。作品页无此缺口：`AppModel.init` 与 `refreshWorks()` 都是本机同步读取，
不存在可观察的加载态（§8 该格为「列表骨架或进度」，同步读取不产生这一段）。

### 12.5 真机走查清单（人工验收，约 12 分钟）

这份清单只收**离屏取证到不了**的项目（材质、指针、系统辅助功能、真机观感）。前 5 条是本轮
改动直接作用的界面，建议先看它们；其余是历轮累计下来、一直挂着「只有离屏证据」的项。
任何一条不成立，把「页面名 + 现象」发回来即可——每一条都在 §11.6 留了对应轮次的量测与改法。

**基线**：以 **2026-09-16 14:04 装机的 Release 版**为准（二进制 sha256 `79d5df0d…`，
`CFBundleVersion` 9），含第五十七轮的「真实包络 + 真实进度」、第五十八轮的设置页重画、
第六十轮的选中行底色。更早的 13:44 装机件（`3f5975e6…`）**不含**选中行底色那一处。

| # | 看哪里 | 期望 | 不成立时看 |
|---|---|---|---|
| 1 | 设置 → 通用 | 行卡是**白卡浮在灰地板上**（不是比地板暗一档），左右留白与卡片一致、圆角 12 | §11.6 第五十八轮 ④ |
| 2 | 设置 → 创作 | 滑轨宽 132、右侧取值是**全角** `1.0×`；整卡只有一条行内分隔线（默认音色 / 默认语速之间） | 同上 |
| 3 | 设置 → 服务 | 服务端口 / 产品定位 / 最低系统 / 版本的取值**贴右沿**；「关于」卡里有两条分隔线 | 同上 |
| 4 | 设置窗口整体 | 640 × 454，切三个页签窗口不跳、任何页都不出滚动条 | §11.6 第五十八轮 ⑥ |
| 5 | 深色（系统外观切深色） | 设置三页：卡比地板**亮**、不闷；主窗口任意页没有方角容器 | §11.6 第五十 / 五十八轮 |
| 6 | 系统「辅助功能 → 显示 → 提高对比度」 | 页面底 / 卡片 / 凹槽三级在 HC 下仍分得出来 | §11.6 第五十 / 五十一轮（HC 从未实测） |
| 7 | 系统「辅助功能 → 显示 → 文字大小」调到最大 | 设置页 + 任选两页：不裁字、不溢出、不出现横向滚动 | §9 那一格的落地方式 |
| 8 | 系统「辅助功能 → 动态效果 → 减弱动态效果」 | 配音台波形脉冲停止，两处自定义动效变即时 | §9 |
| 9 | VoiceOver | 任一列表页顺序 = 导航 → 结论 → 主对象 → 主操作 → 详情；设置页每个开关读出「标题 + 说明」 | §9 |
| 10 | 键盘 | `⌘1`–`⌘8` 切页、`⌘?` 帮助、设置页 `Tab` 走一遍（焦点环是系统色、2pt、画在卡上） | §6.3 / §11.6 第五十三轮 |
| 11 | 指针悬停 | 模型页档位卡悬停有**可见**的整卡反馈（不是只在两侧露一条窄带） | §11.6 第五十二轮 |
| 12 | 音色库 / 我的作品的详情面板，播放一段音频 | 波形条高度随**这段音频自己的**幅度变化（换一首形状明显不同，不是每首都一样），播放中未播到的部分是淡色、随播放推进 | §11.6 第五十七轮 |
| 13 | 头部工具栏（当前 14 个路由共享同一槽位） | 身份标题切页时**不横跳**（恒定在 x=252 那一格），工具栏是统一紧凑样式、不重复显示窗口标题 | §11.6 第五十五轮 |
| 14 | 音色库 / 我的作品：点选一行 | 选中行是**淡青底**（稿值，不是系统实心蓝），且方向键上/下仍能换行、换行时底色跟着走 | §11.6 第六十轮 |

不在本清单：单元测试与 UI 自动化（按 AGENTS.md 需当次明确授权，本会话未运行）。

> 2026-09-16 追加：§13 新增音色克隆与开发者文档两页后，本表第 10 条的快捷键范围整体后移为
> `1`–`9` 与 `⌘0`（顺序见 §13.1），第 13 条的「身份标题恒定同一点」现在是**十页**；
> 两页各自的走查项见 §13.7。

## 13. 两个新模块：音色克隆与开发者文档（2026-09-16）

### 13.1 范围

用户当次指令：「增加音色克隆模块（克隆用户发音音色，让用户读句子，类似 sona 的实现）；
增加开发者文档模块，开发者可以通过 app 上的开发者文档清晰的指导如何对接。」

这条指令**取代**本文 §6.1 原先「保留现有 8 条路由、不新增页面」的约束——那是重设计当时
的范围，不是产品上限。本轮新增两条路由，八页变十页：

| 分组 | 路由 | 侧边栏标签 | 位置 | 快捷键 |
|---|---|---|---|---|
| 创作 | `voiceClone` | 音色克隆 | 插在「音色创作」之后（描述生成与录音复刻是同一件事的两条路） | `⌘3` |
| 引擎 | `developerDocs` | 开发者文档 | 引擎组最后一项 | `⌘⇧H` |

本段记录当时插入第 3 项后的历史顺序；当前快捷键不再按序位推导，而由 `AppRoute.shortcutSpec` 明确登记。
既然顺序必须动，就不为「保住老号位」把音色克隆放到组尾：它和音色创作是一对
（见 §13.2 第 5 条），中间夹着音色库会让这条路径读不通。

当前 14 个路由的快捷键由 `AppRoute.shortcutSpec` 统一声明，`SpeechRailCommands` 只负责转换为系统菜单命令；
引擎辅助页使用 `⌘⇧M`、`⌘⇧D`、`⌘⇧H`，避免与 `⌘0` 的运行监控入口混淆。

### 13.2 音色克隆（Voice Clone）

**它是什么**：用户读一段提词稿，用自己的声音注册一个可复用的音色。

**为什么不是「上传一个音频文件」**：这一页真正要回答的是「我读得对不对」。把录制与回听
拆到页面外（或直接收文件），用户拿到的只是一个上传框，而失败原因（太短、太吵、削波、
读的和文本不一致）全都落到提交之后才出现。四步在同一页里走完，每一步都是这段录音
能不能用的证据链——这与 Sona 声音工坊的路径一致（`sona/docs/architecture/voice-studio-guided-creation.md` §2/§6）。

1. **提词稿**（卡 1）：四段官方提词稿（`GET /v1/voices/clone/prompts`）任选，另有「自己写一段」。
   稿件正文是这一页唯一的大字对象（`Typography.promptScript` = `.title`，与稿 `Title / Page` 同档，
   见 §11.6 第六十六轮），五个选项共用同一个固定外框（`VoiceClone.scriptBodyHeight`）与同一条正文
   原点——只读稿与自写编辑器逐点相同（见 §11.6 第六十七轮）。
   选稿会同步「实际朗读的文本」，但**只在用户还没改过它的时候**——已经改过的文本是「他实际说了
   什么」，不能被下一次选稿悄悄覆盖。
2. **录制**（卡 2）：实心圆按钮（稿里唯一的圆形控件，56pt）、28 根电平条、等宽计时。
   电平来自 `AVAudioRecorder.averagePower`（20Hz 采样，与波形进度同一节奏），不是自走的动画；
   条高是**刻度**、只有颜色随电平走——真实电平驱动条高会把读数变成动画。
   到 `VoiceClone.maximumSeconds`（45s，与服务端 `max_duration` 同值）自动停止并说明原因，
   而不是让用户提交后才吃到 `audio_too_long`。
3. **回听与核对**（卡 3，录完才出现）：原始录音的波形来自这段音频自己的包络、
   播放进度取播放器真实的 `currentTime / duration`（与 §11.6 第五十七轮同一条通道）；
   动作是 `播放 / 重录 / 删除`（§11.6 第六十七轮：听完了不想用，必须有一条明确的出口，
   而不是只能靠重录把它顶掉）；下面是「实际朗读的文本」输入槽，默认填入选中的提词稿全文、
   可改成真正说出的内容。
4. **注册**（卡 4）：名称 + 「先检查参考音频」（`POST /v1/voices/clone/validate`，同一条质量门但不落档案）
   + 「注册音色」（`POST /v1/voices/clone`）。名称预填不是必须的（用户可以留空，那时按钮给出
   「填写音色名称后可以注册」），本地校验只为了让「名称没填」这类问题不花一次上传。

**边界与事实（都以当前契约为准）**

| 项 | 值 | 来源 |
|---|---|---|
| 参考音频硬边界 | 2.0–45.0 秒 | `POST /v1/voices/clone` 的 `_transcode_clone_audio(min_duration=2.0, max_duration=45.0)` |
| 上传大小 | ≤ 15 MB | 同路由的 `_read_uploaded_audio`（超出返回 `413 audio_too_large`） |
| 本地建议区间 | 5–30 秒 | 本应用 `VoiceClone.minimumSeconds` / `.targetSeconds`，只做提示 |
| 参考文本 | 1–2000 字符 | OpenAPI `VoiceCloneRequest.ref_text.maxLength` |
| 名称 | 1–32 字符 | OpenAPI `VoiceCloneRequest.name.maxLength` |
| 需求档位 | quality（VoiceDesign + Base 两个 TTS capability） | `POST /v1/voices/clone` 的 `voice_cloning_unsupported` |

**隐私边界（本模块第一次让 App 采集音频，因此写清楚）**

- 录音只在「按下录制 → 停止」之间采集，落在系统临时目录；应用收下后**立刻删除该文件**，
  字节只留在内存里，注册成功后连内存也放掉（`AppModel.acceptCloneRecording` /
  `discardCloneRecording`）。
- 采集链关闭 AEC / 降噪 / AGC：回声消除与自动增益会改掉用户本来的音色，而这一页要的正是
  用户本来的音色。这不是「更干净」的取舍，是「不能替用户改声音」的取舍。
- 注册成功后档案里留下的是**服务端生成的参考音频**，不是用户读的那一段；
  应用不上传第二次、不写进作品库、不进日志。
- 麦克风权限被拒时给的是「打开系统设置」这一条路（`x-apple.systempreferences:…Privacy_Microphone`），
  不是重试按钮。

**一致性边界**：一次逻辑注册使用稳定的 `id`（`voice_clone_<uuid>`）与 `Idempotency-Key`。
响应丢失后重试带同一对值，服务端会把第一次创建的那条档案还回来——重录才会换新身份。

**档位门禁**：`/v1/models` 的 `supports_clone == false` 时不给注册，改给一条去模型页的路；
能力还没读到（`nil`）时**不**拦——「未读取」不是「不支持」（与 §11.6 第五十一轮同一条口径）。

### 13.3 开发者文档（Developer Docs）

**它是什么**：把「怎么接进本机语音能力」放进应用，而不是只留在仓库的 Markdown 里。

**结构**：顶部一条接入信息带（服务地址 / 鉴权 / 运行档位 / 已发布能力 + 「复制接入信息」），
下面一张「目录列 + 正文列」的卡：8 个主题，一次只展开一个。文档页最忌讳的是一屏接一屏
正文——需要整段阅读的内容应该能被搜索、能被引用，而不需要铺满窗口（§5.6 的信息密度约束）。

| # | 主题 | 回答的问题 |
|---|---|---|
| 1 | 快速开始 | 改 `base_url` 就能用的最小示例（Python SDK + curl） |
| 2 | 接口一览 | REST 与 WebSocket 的入口、方法与用途 |
| 3 | 实时语音 | `/v1/realtime` 的子集边界与「不做什么」 |
| 4 | 音色与克隆 | 三类音色、两条注册路径、参考音频的边界 |
| 5 | 分档能力对照 | light / balanced / quality 发布什么 |
| 6 | MCP 接入 | `speechrail-mcp` 的 stdio 与 streamable-http |
| 7 | 错误与排查 | 统一错误信封与常见码的下一步 |
| 8 | 安全与部署 | 回环默认、Bearer、日志脱敏 |

**内容纪律（这一页最大的风险是写出漂亮但不准的话）**

- 每条事实都能指回来源：`contracts/openapi.yaml`（路径、字段、错误码、`maxLength`）、
  `contracts/realtime-openai.md`（Realtime 子集）、`docs/users/`（SDK 与 MCP 配置）。
- **不写服务端内部**：worker、队列、资源治理、模型路径都不进这一页——客户端不需要感知它们，
  写进去只会随实现漂移。
- 数量与取值写「契约说多少」而不是「我记得是多少」；能力矩阵只写三档的**能力差异**，
  不写每个档位的资源占用。
- 代码块用系统等宽字体（`Typography.code`）并支持选中与一键复制；示例是能跑的最小片段，
  不是伪代码。

**与仓库文档的关系**：应用内这一份是**入口**，不是替代品。每个主题的正文都点到对应契约
或 `docs/users/` 的位置；仓库文档仍然是唯一完整版，应用内不复制整篇。

### 13.4 Figma 侧（生成器）

| 位置 | 变更 |
|---|---|
| `ROUTES` / `SCREEN_DEFS` | 各加两条（`voiceClone` / `developerDocs`），画板总数 8 → 10，深浅色共 20 帧 |
| `icons.js` | 新增 4 个 lucide 图标（`mic` / `square` / `shield-check` / `book-open`），30 → 34 |
| `main.js` | 新增 `screenVoiceClone` / `screenDeveloperDocs` 与 `endpointRow` / `codeBlock` 两个局部构造；组件页新增 `Prompt Option` / `Level Meter` / `Doc Topic Row` / `Code Block` 四个组件集（11 → 15） |
| `03 Flows` | 新增第 4 条「音色克隆流程」（选稿 → 录制 → 回听核对 → 预检 → 注册 → 音色库） |
| `00 Cover` | 目录行改成「四条主流程 / 10 个页面 × Light / Dark」 |
| `audit.js` | 补 `primaryButton` / `secondaryButton` 的图标参数扫描——原先只扫 `icon()` / `iconButton()` / `icon:`，按钮上的图标名是**静默失去覆盖**的（本轮 `shield-check` 正是从这一条发现的）；`DOC_TOPICS` 因此从数组元组改成对象形式，让 `icon:` 键可被扫描 |
| `PAGE_LAYOUT`（新） | 七组内容改排到**两个真实页面**上（`01 Kit` 三块文档、`02 Screens` 屏幕 + 流程 + 菜单设置 + 归档），每组建完就地平铺（组间 400px，顶端对齐） |

**为什么只有两个页面**：2026-09-16 首次在 Figma 桌面版真跑时才发现，**Starter（免费）版每个文件
只允许 3 个页面**。原方案一页一组（7 页），于是 `createPage` 在第 4 页抛错，`04 Screens` 等页面
是 `undefined`，屏幕、流程、菜单设置、归档**一块都没建出来**——文件里只剩前三个文档页。改成两组、
两个页面后一次跑通（见 §13.6 的下半张表）。生成器因此不再假设「页面随便建」：先复用同名页，
再接管遗留页（改名），额度满了才尝试 `createPage`，并把不再拥有的页面清空删除。

**稿侧已知取舍**：

- 提词稿选项的标题来自服务端（`clone_prompts.json` 里带 emoji 前缀）。生成器源码里的 emoji
  会在补丁通道里被吞，因此画板用同名纯文字标签；应用显示服务端返回的原文。
- 代码块在稿里用 Inter 画示意（插件环境取不到 SF Pro／等宽字体），生产映射到系统等宽字体。
- 开发者文档的目录列在稿上是 `surface/railTint` 选中底色（与侧边栏导航同一套画法），
  应用用系统 `List` 的选中态：§3.2 第 5 条的例外只给音色库 / 我的作品两块目录页。

### 13.5 落地

- 新增文件：`VoiceRecordingController.swift`（录音通道）、`AudioReferenceCheck.swift`（本地量测）、
  `VoiceCloneView.swift`、`DeveloperDocsContent.swift`、`DeveloperDocsView.swift`。
- 改动文件：`AppRoute`（两条路由）、`ControlCenterView`（路由 → 视图）、`App.swift`（快捷键与
  UI 测试替身）、`SettingsView`（帮助清单）、`SpeechRailDesignTokens`（`VoiceClone` /
  `DeveloperDocs` 两套几何与边界 + `promptScript` / `code` 两档字体）、
  `CreatorServiceClient`（`ClonePrompt` / `VoiceQualityReportSnapshot` / 三个方法）、
  `ServiceAPIClient`（multipart 构造 + 三个调用）、`AppModel`（克隆流程状态与动作）、
  `CreatorSurfaceViews`（`WaveformBars` 由 `private` 改为模块内可见）。
- 工程配置：`project.pbxproj` 增加 5 个源文件；
  `INFOPLIST_KEY_NSMicrophoneUsageDescription` 写进 App 的三个 build configuration（Debug / Release /
  Distribution）——`GENERATE_INFOPLIST_FILE = YES` 的工程里，这是唯一的 Info.plist 声明点。
- **App 边界随之变化**：App 从此采集麦克风（只在这一页、只在这段时间、只落临时文件），
  因此 AGENTS.md 与 `docs/developers/macos-app-*.md` 里「不采集/播放音频」那句必须同步改，
  否则规则与代码打架。

### 13.6 本轮实测

| 项 | 结果 | 时间 |
|---|---|---|
| 静态自检 | `node figma-kit/audit.js` → `audit: clean`（colour 23/23、icons 31/34、text styles 9/9） | 2026-09-16 17:30 |
| 生成器语法 | `node --check figma-kit/main.js` → 通过 | 同上 |
| 插件打包 | `node figma-kit/build.js` → `code.js` 161,697 bytes 落到 `~/Downloads/SpeechRail-figma-kit/` | 同上 |
| 工程文件 | `plutil -lint SpeechRailApp.xcodeproj/project.pbxproj` → OK | 2026-09-16 17:38 |
| Debug 构建 | `scripts/macos_app_build.sh --configuration Debug` → `** BUILD SUCCEEDED **`，0 条来自本轮源码的 error/warning | 2026-09-16 17:40 |
| 测试构建 | `xcodebuild … build-for-testing` → `** TEST BUILD SUCCEEDED **`（**只编译，未运行**） | 2026-09-16 17:41 |
| Info.plist | 产物 `NSMicrophoneUsageDescription` 已写入（`plutil -p` 实测） | 同上 |

**Figma 桌面版实跑（2026-09-16 17:54–18:09，用户要求「在 figma app 里看到设计稿」，由 agent 驱动桌面版）**

| 项 | 结果 | 时间 |
|---|---|---|
| 文件与套餐 | 用户账号（Starter / Free）里**没有任何 Figma 文件**（`Search results for “SpeechRail”` 也是空），本次新建 `Untitled`；3 页额度用了 2 页 | 17:54 |
| 第一次运行（旧的 7 页方案） | `ERRORS pages -> in createPage: The Starter plan only comes with 3 pages…`；`screens / flows / menu & settings / archive -> in setCurrentPageAsync: Expected node, got undefined`；只建成 Cover / Foundations / Components 三块画板，**屏幕一块都没有** | 17:56 |
| 改版后运行（两个真实页面） | 14 个步骤全 `ok`；`10 screens · 26 frames (Kit 3 · Screens 23)`；`prototype links: 198/198`；`bind errors: 0`（`code.js` 180,770 字节，sha256 `17d17cf8…`） | 18:03 |
| 目视核对 | `01 Kit` = Cover / Foundations / Components 三块并排；`02 Screens` = 10 块浅色 + 10 块深色屏幕两列并排，右侧依次 Flows / Menu & Settings / Archive | 18:05–18:09 |
| 未通过项（1 条） | `Flows: overflow → step · 试听与使用+30, detail+16 · inner 1: steps → step`——流程画板里某一步的内容比卡片高 30px。改排前后两次运行都报同一条，本轮未追成因、未修 | 18:03 |

**第二轮：组件集排布与全量重导（2026-09-16 18:40–19:25，用户 `@电脑` 授权下由 agent 驱动桌面版）**

核验 18:38 那版 `Components` 导出（把 SVG 重栅格化后放大逐块看）发现三处生成器缺陷，改
`figma-kit/main.js` 后重跑插件并重导全部 26 块画板：

| 缺陷 | 现象 | 修法 |
|---|---|---|
| 变体不摆位 | `combineAsVariants` 只把变体重新挂到集合下、不排布，16 个组件集的状态全落在创建时的同一点：Status Pill 的 5 个标签互相压字、Sidebar Status 叠成乱码、Profile Card 只看得见不透明的那一个变体 | `componentSet()` 自己排：按 `SET_W = 704` 换行、间距 24，集合尺寸按内容算；落位改成按列游标 `gridCursor`，某个集合长高了就把下一个往下推 |
| 竖向变体被压成 40px | `comp()` 把 `w` 当主轴（竖向框的主轴是高），`o.h == null ? 40 : o.h` 又把高度写死 40：第二行起被裁掉——Profile Card 的说明、Empty State 的标题与正文、Doc Topic Row 的说明都缺 | 按轴写 `primaryAxisSizingMode` / `counterAxisSizingMode`（竖框的 `w` 归 counter 轴），两轴每次都写，未指定的轴保持 `AUTO` 继续 hug |
| 子行不拉伸 | `Candidate Tile/head`、`Code Block/codeHead` 自己 hug 宽度，里面的 `spacer()` 推不动右对齐的 `seed` 与复制按钮 | 三处改为 `add(c, stretch(head))` |
| 中文导出空白 | Inter 不承载 CJK；Figma 的缺字回退在刚重建的文档里未热，导出会把中文整段画成空白（19:09 / 19:11 / 19:13 三次导出实测，拉丁文正常） | 新增 `loadCjkFont()`（按偏好列表从 Figma 可用字体里挑一个 CJK 家族并加载）+ `applyCjkFont()`（给每个文本节点的 CJK 区段套该家族）；本轮选中 `PingFang SC`，报告新增 `CJK runs:` 一行 |

重跑报告：`26 frames (Kit 3 · Screens 23)`、`prototype links: 198/198`、`bind errors: 0`、
`CJK runs: PingFang SC`，未过项只剩既有的 `Flows: overflow → step`。导出：23 个屏幕帧用
「选中 23 个 → `Export 23 layers`」一次落盘，`Cover` / `Components` / `Foundations` 单帧导出；
52 个文件全部换成同一次构建的产物（19:17–19:25），画板尺寸与 18:20 那批一致。

### 13.7 待验证与回退

**未执行（需要授权或需要人工）**

- Figma 插件重跑与 4x 重导出：轨道 B 下连接器工具不可用，写稿只能由人工在 Figma 桌面版触发
  （`figma-kit/README.md`）。本轮只到「生成器就绪 + 静态自检 clean」。
- 离屏量测：仓库里没有离屏渲染 harness，本轮没有新建；两个新页面的排版没有渲染证据。
- 单元测试与 UI 自动化：按 AGENTS.md 需当次明确授权，本轮未运行。
- 真机功能走查：麦克风录音需要真实设备与用户操作，agent 不做。

**待验证清单（建议顺序）**

1. 音色克隆 · 未授权麦克风：结论是否给「打开系统设置」，而不是重试。
2. 音色克隆 · 录 3 秒：本地结论是否读作「太短了」（服务端下限 2 秒，本地建议 5 秒起）。
3. 音色克隆 · 录 40 秒：到 45 秒是否自动停止并说明原因。
4. 音色克隆 · 回听：波形是否来自这段录音本身、计时是否与音频时长一致。
5. 音色克隆 · 注册：成功后是否给出「去音色库查看」，并在音色库里看到带 clone 模式的新音色。
6. 音色克隆 · 档位切到 light：是否给出「去模型页切档」而不是让请求失败。
7. 开发者文档 · 目录列：方向键是否换主题；`⌘0` 是否直达本页。
8. 开发者文档 · 复制：`复制接入信息` 与代码块复制是否进剪贴板（2 秒后文案复位）。
9. 开发者文档 · 密度：默认是否只看到当前主题，不出现整页正文。
10. 两页 × 浅色/深色 × 窗口最小/默认/放大。

**回退**

- 代码回退按 hunk 挑，**不能整文件 `git checkout --`**：本轮改动叠在未提交的重设计工作区上。
- 生成器回退：`main.js` / `icons.js` / `audit.js` 的三处新增都是独立块（两条路由、两个 builder、
  四个组件集、四个图标、一段扫描），可逐块撤回。
- 工程回退：`project.pbxproj` 的五行文件引用、五行编译项与三处 `INFOPLIST_KEY_` 是唯一新增；
  `NSMicrophoneUsageDescription` 一旦回退，录音会在系统层直接失败（没有该键就没有权限弹窗）。
