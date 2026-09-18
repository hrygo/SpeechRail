---
title: "SpeechRail macOS App · UX/UI 统一规范（全 App）"
status: active
audience: "设计与实现（Figma 稿 + macOS App）"
version: "1.0.0"
date: 2026-09-18
---

# SpeechRail macOS App · UX/UI 统一规范

用户 2026-09-18 的要求：「统筹 SpeechRail 所有功能，是一个有机融合的整体，在此前提下执行
UX/UI 优化——一个整体，一个规范。」这份文件就是那个「一个规范」：**它管全 App，不再分
「会话三屏」与「其余模块」两套口径**。稿的生成器（`figma-kit/main.js`）与实现
（`macos/SpeechRailApp`）都以它为准。

## 1. 文档地位与阅读顺序

| 文档 | 它是什么 | 与本文的关系 |
|---|---|---|
| **本文（UX-UI-SPEC）** | 全 App 的**规范层**：token 契约、组件、版式、交互语法、导航、状态模型、覆盖矩阵、门禁 | 唯一规范；冲突时以它为准 |
| [`2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md`](./2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md) | 逐页细节与 35+ 轮标定记录（含大量帧实测证据） | 详图与证据；**规则**已上收到本文 |
| [`2026-09-17-live-sessions/SESSIONS-SPEC.md`](./2026-09-17-live-sessions/SESSIONS-SPEC.md) | 会话三能力的模块细节：边界、逐面规格、状态矩阵、SQLite 数据模型、用户旅程 | 会话模块详图 |
| [`2026-09-18-session-layer/TECHNICAL-DESIGN.md`](./2026-09-18-session-layer/TECHNICAL-DESIGN.md) | 会话层技术终态：原生 / Python 分工、边界规矩、验收判据 | 实现映射 |
| [`2026-09-17-session-closures/`](./2026-09-17-session-closures/)、[`2026-09-18-figma-handover/`](./2026-09-18-figma-handover/) | 闭环稿的设计包、离线门禁、实跑 SOP、交接 | 过程与证据 |
| [`archive/`](./archive/) | 上一代设计包 | **历史**，不是当前承诺 |

事实来源顺序：当前代码与实测 → 公共契约 → 标记 `active` 的文档 → 归档。**本文里的数字都出自
生成器与门禁的当前实测**（核实日期 2026-09-18）；标「推断」的地方不能当实测用。

## 2. 一个整体：三条产品线，一份骨架

SpeechRail 是一个窗口里的**一台本地语音机器**，不是三个 App：

```
一个窗口（1440 × 900，最小 1120 × 720）
├── 标题栏        窗口标识 + 状态入口（信息 / 更多）
├── 侧边栏 240    三组导航：创作 · 会话 · 引擎 ＋ 常驻两行状态（服务就绪 / 谁在用麦克风）
└── 内容区        页头（页名 + 一句话说明 + 动作）→ 状态带 → 主体 → 底部（抽屉 / 结论条）
```

| 产品线 | 用户来干什么 | 路由 |
|---|---|---|
| **创作** | 做声音资产：配音、设计音色、克隆音色、管理音色与作品 | `dubbing` `voiceDesign` `voiceClone` `voiceLibrary` `works` |
| **会话** | 用声音做三件事：对话、记事、看字 | `assistant` `meeting` `captions` |
| **引擎** | 看这台机器在干什么、坏了怎么查 | `overview` `monitoring` `models` `diagnostics` `developerDocs` |

**有机融合的四条硬约束**：

1. **一套骨架**：三个产品线共用同一个 `buildShell` / `PageScaffold`（标题栏、侧栏、页头、状态带）。
   任何一条产品线都不得自带第二套外壳（SESSIONS-SPEC §4-S4 的红线）。
2. **一套组件**：同一个动作在一屏只出现一次，同一个形状只有一个实现（§4）。
3. **一个列宽 / 一个内宽**：全 App 只有「目录列 280」与「详情列 360」两个列宽（§5）。
4. **一件事只有一种说法**：系统入口、模型在哪配、记录落在哪、谁在用麦克风、能不能分人、
   资产与存储——六件事在三条产品线里必须一致（§9）。

## 3. 设计 token 契约

### 3.1 颜色（23 个，浅 / 深成对）

定义在生成器 `COLOR_TOKENS`，写成 Figma 变量（浅色一个集合，深色用第二个 mode 或
`dark/*` 引用集合）。语义分组：

| 组 | token | 用在哪 |
|---|---|---|
| 强调 | `accent/rail`（青）、`accent/voice`（琥珀） | rail = 机器与结构；voice = 人声与创作 |
| 状态 | `status/ready` `status/attention` `status/critical` `status/info` | 状态胶囊、状态带、诊断结论；各自有 `surface/*Tint` 底 |
| 表面 | `surface/window` `surface/sidebar` `surface/content` `surface/panel` `surface/field` `surface/railTint` `surface/voiceTint` | 四级表面阶梯：窗口 < 面板 < 内容卡 < 字段 |
| 描边 | `border/separator`（hairline）、`border/strong`（可交互边界） | 见 §4.2 的描边规则 |
| 文字 | `text/primary` `text/secondary` `text/tertiary` `text/onAccent` | 三级文字 + 反白 |

规则：**不许出现字面色**（`audit.js` 会拦）；状态色不做装饰用；可用性色（红/琥珀/绿）只在
它真的表示状态时出现。

### 3.2 文本样式（11 档）

定义在 `TEXT_STYLE_DEFS`：`Title / Large`、`Title / Page`、`Heading / Section`、`Body`、
`Body / Medium`、`Callout`、`Subheadline`、`Caption`、`Caption / Medium`，加字幕正文两档
`Caption Band / 标准`、`Caption Band / 大字`（字号由用户设置驱动，不是界面层级）。

规则：样式名是**语义档位**，不是字号（如 `Heading / Section` = 13pt Semi Bold）；
实现侧映射到系统文本样式以随「更大文字」缩放（`Typography.display/body/callout/caption…`）。

### 3.3 版式数值：单点声明（LAYOUT / NT）

**规则：同一语义只声明一次，跟随值由它推导。** 颜色与文本样式走变量；版式数值走生成器顶部的
`LAYOUT` 块，并逐个与 `NUMBER_TOKENS` 里的同名变量对应（`NT["space/16"]` 这样按名字取用）。
行内微间距（2 / 4 / 8 / 12…）仍是就地字面量——它们不构成跨页约束。

| 语义 | 值 | 推导 / 说明 | 实现符号 |
|---|---|---|---|
| 窗口 | 1440 × 900 | 每一块屏幕画板 | — |
| 最小窗口 | 1120 × 720 | 与实现同值 | `Layout.windowMinimumWidth/Height` |
| 侧栏 | 240 | `sidebarInnerW = 240 − 2×10 = 220` | `Layout.sidebarWidth` |
| 页边距 | 20 | 内容区四周 | `Layout.contentPadding` |
| 区块间距 | 20 | 内容区纵向块 | `Layout.cardInset` 一档 |
| 区域间距 | 16 | 同屏两个区域（列表 ↔ 详情 / 转录 ↔ 详情列） | `Layout.cardInset` 一档 |
| **目录列** | **280** | 记录库 / 助手记录 / 文档目录列 / 模型配置列表**共用一个数** | `Layout.modelProfileListWidth` |
| 列表内宽 | 248 | `= 280 − 2 × 16`（列表卡片内边距）；搜索框、页脚用它 | 由实现按列宽推导 |
| 列表行内宽 | 228 | `= 248 − 2 × 10`（行内留白） | 同上 |
| **详情列** | **360** | 本次对话 / 记录信息 / 会议信息 / 音频来源 / 字幕文件 | `Layout.inspectorColumnWidth` |
| 档位卡 | 220 | `innerW = 220 − 2×12 = 196` | `Layout.modelProfileListWidth` 一档 |
| 空态 | 320 / pad 32 | 正文宽 `= min(320 − 64, 460) = 256`；页面级空态上限 460 | `Layout.emptyStateMinimumHeight` 一档 |
| 设置说明列 | 260 | 设置窗口 16 行只有这一档 | `Settings` |
| 菜单面板 | 288 | `MENU_ROW_W = 288 − 10 = 278`、`MENU_TEXT_W = 278 − 20 = 258` | `Menu.contentWidth` |
| 详情工具栏搜索 | 300 | 整页宽工具栏（音色库 / 我的作品） | — |
| 画布 | 1600 | Cover / Foundations / Components / 闭环总览（不是窗口尺寸） | — |

**门禁**：`audit.js` 的「版式单点声明」一节把上表加粗的受管值盯住——它们再以字面量出现在
宽度位置（`size(node, W, …)`、`searchField(…, W)`、`captionWidth: W`）就是失败。这一条是
2026-09-18 第十一轮补的，拦的正是此前查出的四类漂移（§12）。

### 3.4 稿 ↔ 实现对照（token 契约的两侧）

实现侧的唯一 token 文件是 `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`。
两侧的规矩：**同一个语义在两边各只有一处声明，且值相同**；任何一侧改值必须同时改注释里引用的
另一侧位置。

| 语义 | 稿 | 实现 |
|---|---|---|
| 间距阶梯 | `NT["space/2…48"]` | `Spacing.hairline/tight/micro/xs/sm/md/gutter/lg/xl/hero` |
| 圆角 | `radius/container` 12、`radius/control` 8、`radius/tile` 10、胶囊 999 | `Corner.container` 12 / `Corner.nested` 8 / `ConcentricRectangle` |
| 控件高度 | `size/controlComp` 28、`size/control` 34、`size/controlProm` 40 | `Control.compactHeight/regularHeight/prominentHeight` |
| 命中区 | `size/hitMin` 44 | `Interaction.minimumHitTarget` |
| 图标框 | 侧栏 20 / 工具栏 24 / 行内 16 | `Icon.navigationFrame/toolbarFrame`、`Control.diagnosticIconFrame` |
| 列表行 | 行框 64（页面列表）/ 侧栏行 30 | `List.pageRowMinimumHeight` / `List.sidebarRowHeight` |

## 4. 组件：一个动作一个组件

### 4.1 原语清单（生成器里的实现，稿与实现同名）

`card`（容器）、`hairline`（1pt 分隔）、`pageHead`（页头）、`sessionStatusBar`（会话状态带）、
`conclusionBand`（结论条）、`meetingRow` + `recordListColumn`（列表行 / 记录库列）、`turnRow`
（对话行）、`searchField`、`segmented`、`pill`、`badge`、`iconButton`、`primaryButton` /
`secondaryButton`、`textField`、`switchControl`、`sliderControl`、`kvRow`、`closureCheckRow`、
`settingsWindow`（4 页签）、`menuPanel` / `menuRow`（菜单栏面板）、`captionBandFrame`（字幕带浮层）、
`meetingOSBar` / `meetingOSPanel`（内心 OS 抽屉）、`sideToggle`（非主框体收起）。

**新增组件的判据**：只有当「已有组件 + 参数」表达不了这个形状时才新增，并且必须在本文 §4 登记。
同一形状有两份实现（例如 `recordListColumn` 之前被抄了两遍）算缺陷。

### 4.2 描边与投影（只给三类）

静态容器（卡片 / 列表 / 分组 / 流程格）**不描边、不投影**，分离靠填充层级 + `hairline`。
保留描边的只有：① 承载状态的元素（选中档位卡、播放中候选卡、焦点字段、结论面板）；
② 系统控件（输入框 / 按钮 / 分段控件 / 键帽）；③ 窗口级浮层（菜单面板）。

### 4.3 一个动作一屏只出现一次

页头 / 状态带 / 结论条 / 右栏不得重复同一个动作（2026-09-18 第七轮去重 7 处之后由
`smoke.js` 的「48 块闭环屏的动作没有重复」守着）。跨屏重复当然可以——那是导航，不是重复。

## 5. 版式与骨架

- **窗口**：1440 × 900 的屏幕画板；最小 1120 × 720。窄窗口**不自动收起面板**，过窄交给系统 overflow。
- **页骨架**：标题栏（交通灯 + 身份 + 两个状态入口）→ 内容区（`padX 20 / padY 20 / gap 20`）。
- **两列布局**：目录列 280 + `regionGap 16` + 内容/详情；详情列 360。
  最小窗口算术（1440 → 1120）：内容区 = 1120 − 240（侧栏）− 40（页边） = 840；
  最紧的一屏（目录列 + 详情列）是 280 + 16 + 544，仍然放得下主列。**这是算术，不是实测**。
- **滚动**：内容超出交给系统；稿上不画自绘滚动条（第六 / 十七轮的口径）。

## 6. 交互语法：每种状态只有一种画法

| 语法 | 规则 | 落在哪 |
|---|---|---|
| **状态带** | 一屏只有一条，说「现在在干什么 + 多长时间 + 电平 + 事实（已存多少 / 分人开没开）」 | 会话三屏；引擎页用服务状态卡 |
| **结论条** | 只在「有结论要说」时出现：Ready / Attention / Critical + 一句话 + 一个出口；不弹错误框 | 全 App（`conclusionBand`） |
| **列表 + 选中 + 详情** | 记录类内容只有这一种形状；列表在左、详情在右 | 记录库 / 字幕库 / 音色库 / 诊断 |
| **非主框体可收起** | 六条判据：① 有收起态 ② 控件贴分界线（内容列首行尾端 `sidebar.right`，28pt）③ 一处唯一 ④ 收起后主框体吃满 ⑤ 不看面板也不会做错事 ⑥ 按屏记忆 | 右详情列 / 贴底抽屉 / 字幕带浮层 / 导航侧栏 / 卡内明细 / 目录列（SESSIONS-SPEC §18） |
| **贴底抽屉** | 常驻一行，随时展开/收起；展开不改主任务 | 会议内心 OS（`⌘⇧I`） |
| **浮层** | 贴屏、不抢焦点、不阻断；结束要显式（字幕带上的 `x`） | 字幕带 |
| **破坏性确认** | 写清影响面与能不能恢复；只给「取消 + 确认」两个出口 | 移除记录 / 清空字幕库 / 结束并切换会话 |
| **空态** | 图标 28 + `Heading / Section` 标题 + `Callout` 正文（≤ 容器内宽，上限 460）+ 一行动作；页面级空态可加一行状态胶囊 | `Empty State` 组件；会议空态是它的页面级用法 |
| **受阻 / 未配置** | 不是错误对话框：写清缺什么、影响什么、给唯一出口 | 模型未配 / 麦克风被占 / 服务未就绪 |

## 7. 导航与键盘

- 侧栏三组：创作（5）· 会话（3）· 引擎（5）；会话组里常驻一句定位语
  「要文字用字幕，要纪要用会议，要对话用助手。」
- 侧栏底部常驻两行：`服务已就绪 · Quality` 与**会话所有权**（`麦克风空闲` / `语音助手进行中 · 00:03:42`…）。
  后者是本机产品的首要事实，不是「点了才被拒绝」的隐藏状态。
- 快捷键：会话组 `⌘6 / ⌘7 / ⌘8`；引擎组 `⌘9 / ⌘0 / ⌘⇧M / ⌘⇧D / ⌘⇧H`；字幕带 `⌘⇧L`；
  会议 `⌘⇧N`；内心 OS `⌘⇧I`；面板显隐 `⌘⌃I`；隐藏侧栏 `⌘⌃S`；静音麦克风 `M`（有焦点时）。
- **待核**：`⌘⌃I` / `⌘⌥S` 尚未在真机做冲突检测（SESSIONS-SPEC §18.5）。

## 8. 状态模型

每一页都只有这五态，**不是五张页面**：空 / 未开始 → 进行中 → 暂停或被占 → 受阻（缺能力 / 缺授权）
→ 刚结束与归档。产物落在页内长期存在的资产区（记录库），所以「再来一轮」不需要新页面。

## 9. 跨模块脊柱：六件事只有一种说法

| 事 | 唯一说法 | 落在哪 |
|---|---|---|
| 系统入口 | 菜单栏面板 + 全局快捷键；App 不必在前台 | 菜单栏面板（三行入口）、`⌘⇧L` / `⌘⇧N` |
| 大模型在哪配 | 设置 · 会话；要求实现 **Responses API**（不是 Chat Completions）；密钥进钥匙串 | 设置窗口第 4 页签；`closureSettingsBoard` |
| 记录落在哪 | 本机 SQLite（`~/Library/Application Support/SpeechRail/sessions.sqlite3`），长期保留；原始音频不存 | 三屏的结论条与页脚一致陈述 |
| 谁在用麦克风 | 侧栏常驻所有权行 + 菜单栏状态项；后到的会话以受阻态出现，只给两个出口 | `SESSION_STATES`；会话占用板 |
| 能不能分人 | 按档位如实发布：`light` 无分人、`balanced/quality` 可匿名分人；只有匿名 label | 档位卡、字幕/会议状态带、受阻行 |
| 资产与存储 | 记录 = 资产（长期）；音频 = 用完即弃；换档位不迁移数据、重装不丢库 | 设置 · 数据、归档页、用户旅程 J0 |

## 10. 覆盖矩阵（13 路由 + 非路由界面）

「稿上的落点」= 生成器里的画板/板面；「实现」= 当前 App 的落点（会话组尚未进 `AppRoute`，
见 §13）。

| 路由 | 稿上的落点 | 规范条目 | 实现（`macos/SpeechRailApp/SpeechRailApp/`） |
|---|---|---|---|
| `dubbing` 配音台 | `▸ 配音台` | §5 两列 / §6 结论条 | `CreatorSurfaceViews.swift` |
| `voiceDesign` 音色创作 | `▸ 音色创作` | §4 组件 / §6 空态 | `CreatorSurfaceViews.swift` |
| `voiceClone` 音色克隆 | `▸ 音色克隆` | §6 受阻 / 录音电平 | `VoiceCloneView.swift`、`VoiceRecordingController.swift` |
| `voiceLibrary` 音色库 | `▸ 音色库` | §6 列表+详情 / §5 详情列 360 | `CreatorSurfaceViews.swift` |
| `works` 我的作品 | `▸ 我的作品` | §6 列表+详情 | `CreatorSurfaceViews.swift`、`CreativeWorkStore.swift` |
| `overview` 服务状态 | `▸ 服务状态` | §6 结论条 / §4 状态胶囊 | `ServiceOverviewView.swift` |
| `monitoring` 运行监控 | `▸ 运行监控` | §3.3 表格列宽 / §4 卡内明细 | `RuntimeMonitoringView.swift` |
| `models` 模型 | `▸ 模型` | §3.3 列表列 280 / §6 档位卡 | `ModelManagementView.swift`、`ProfilePickerView.swift` |
| `diagnostics` 诊断 | `▸ 诊断` | §4 描边规则 / §6 结论条 | `PreflightDiagnosticsView.swift` |
| `developerDocs` 开发者文档 | `▸ 开发者文档` | §3.3 目录列 280 / §5 | `DeveloperDocsView.swift`、`DeveloperDocsContent.swift` |
| `assistant` 语音助手 | 闭环稿 A0–A8（未开始 / 未配置 / 对话中 / 收起 / 实时对讲 / 换音色 / 记忆 / 记录库） | §6 状态带 / 抽屉 / 浮层；SESSIONS-SPEC §6.1 | 计划中（会话层） |
| `meeting` 会议助手 | 闭环稿 M1–M6（空态选来源 / 录制中 / 内心 OS / 中断 / 整理中 / 已归档） | §6 状态带 / 贴底抽屉；SESSIONS-SPEC §6.2 | 计划中 |
| `captions` 实时字幕 | 闭环稿 C1–C4 + 5 块浮层（跟随 / 回看 / 大字 / 受阻 / 贴在画面上） | §6 浮层 / 非主框体；SESSIONS-SPEC §6.3 | 计划中 |
| 非路由：设置 | `▸ 设置 · 会话` + 全量稿 4 页签 | §9 大模型 | `SettingsView.swift` |
| 非路由：菜单栏面板 | `▸ 菜单栏 · 三个入口` + 全量稿 4 个面板 | §9 系统入口 | `ControlMenuView` |
| 非路由：会话占用确认 | `会话占用 · 结束会议并切换` | §6 破坏性确认 | 计划中 |
| 非路由：闭环总览与规则板 | `闭环总览 · 三条闭环`、`非主框体 · 收起规则`、`换音色 vs 换人设`、`分人 · 说话人标签` | 本文件的判据来源 | — |

## 11. 门禁与证据等级

| 证据 | 守什么 | 不守什么 |
|---|---|---|
| `node audit.js` | 颜色 / 图标 / 文本样式 / kebab 字面量全部可解析；数值 token 可解析；**版式单点声明**（§3.3） | 几何 |
| `node smoke.js full` | 全量稿：48 板 / 478 连线 / 21 深色 / 导出设置 / 深色改绑 / 游离节点 | 几何 |
| `node smoke.js closures` | 闭环稿：59 板 / 234 连线 / 29 深色 / 48 屏动作无重复 | 几何 |
| `node check-links.js closures` | 声明连线源（53）全部能在稿里找到控件 | 连线落点是否语义正确 |
| **Figma 实跑** | 真实布局：溢出、折行、深色改绑、导出 | 真机行为（焦点、动画、权限） |
| **真机运行** | 焦点顺序、`.inspector` 收起行为、快捷键冲突、性能与资源 | — |

**当前的证据缺口（重要）**：Figma 里仍是 2026-09-18 12:38 那一版 **53 板**；生成器已是 **59 板**，
且第十一轮又改了版式与组件。所以「几何干净」这句话在**下一次实跑之前不成立**。
2026-09-18 16:05–16:12 的三次实跑尝试被本机锁屏挡住（`cua.getApp("Figma")` 返回
「The Mac is locked and automatic unlock could not unlock it」），未取得窗口句柄，故本轮没有新增实跑证据。

实跑未成时做了一次**静态几何复核**（详见交接包第十一轮的「静态复核补记」）：把 9 个具名宽度
逐个对回容器内宽，`sidebarInnerW` / `listInnerW` / `listRowInnerW` / `profileCardInnerW` /
`emptyBodyW` / `MENU_TEXT_W` 都等于容器内宽（精确贴合），`settingsLabelW` 与两处搜索框余量充足；
**发现并修掉一处真实内溢**（菜单面板告警行，见 §12 第 11 项）。这层复核只覆盖写死的宽度，
hug 宽度、换行与字体仍只有 Figma 能证。

## 12. 第十一轮改动清单（2026-09-18，全 App 统一）

代码落点：`figma-kit/main.js`（新增 `LAYOUT` + `NT`、`recordListColumn` 抽件）、
`figma-kit/audit.js`（新增版式单点声明门禁）。

| # | 改动 | 之前 | 现在 |
|---|---|---|---|
| 1 | 版式数值单点声明 | 值散在各调用点，数值 token 定义 21 个、引用 0 个 | `LAYOUT` 29 处引用，`audit.js` 盯住 9 个受管值 |
| 2 | 记录库列抽成一个组件 | 字幕记录库与对话记录库各抄一遍（240 / 232） | `recordListColumn`：宽度、搜索、行、页脚全部由列宽推导 |
| 3 | 控制圆角 | 控件画 7（与 token 声明的 8 不一致） | 统一 `radius/control` = 8（与实现 `Corner.nested` 同值） |
| 4 | 列表行文本折行宽 | 196（列宽改了它没跟） | 248 = 列表内宽（**这是真值变化**；同一轮里 `Doc Topic Row` 的 248 / 228 只是换成具名 token） |
| 5 | 空态 | 会议空态 34 图标 + `Title / Page`；组件正文 260（超出内宽 4pt） | 统一：图标 28 + `Heading / Section` + 正文 ≤ 容器内宽（256 / 上限 460） |
| 6 | 设置说明列 | 240 / 260 / 300 三个值并存 | `260` 一个值 |
| 7 | 菜单面板文本宽 | 246 / 246 / 220 | 整行内宽 `258`（由面板宽推导）；带前置图标的行另用 `MENU_TEXT_W_LEAD` = 237，见第 11 项 |
| 11 | 菜单告警行内溢（实跑未成时的静态复核发现） | 文本宽 220 写死，够用 | 并入 `MENU_TEXT_W` 后需要 21 + 258 = 279 > 258 → 新增 `MENU_TEXT_W_LEAD` = `MENU_TEXT_W − 图标 14 − 间距 7` |
| 12 | 构建日志标签 | `build.js` 把 `code.length` 标成 “bytes”（文档里那处「352,603 字节」错误的根因） | 同时打印 chars 与 bytes |
| 8 | 字幕详情工具栏搜索框 | 260（全稿最后一个 260） | 248 = 列表内宽（同一屏两个搜索框同宽） |
| 9 | 文档目录列内边距 | 12（与记录库的 16 不一致） | 16 = `LAYOUT.listPadX` |
| 10 | 会议来源口径 | 稿面「自动混音」与规范「三选一」冲突 | 统一为「麦克风单选 + 本机音频多选，勾多个自动合流」（§14.1 / 旅程表 / USER-JOURNEYS 已同步） |

**需要实跑确认的**：第 3–9 条都动了真实几何（圆角 ±1pt、折行宽、内边距、字号档）。其中
第 4 条把助手记录库的行文本从 196 放宽到 248（52pt 是原来的欠宽，现在是精确贴合列表内宽）；
第 6 / 8 条只放宽了文本折行宽（当前文案都是短句，风险低）；第 3 条是 1pt 的圆角对齐；
第 5 条修掉了组件内 4pt 溢出。第 11 项属于**反向**的教训——归一化本身会制造溢出，它是静态复核
查出来的，上一轮的同名门禁（只查字面量重复）看不见。**这些都还是算术与静态检查，不是实测。**

**回退**：第十一轮改了 `main.js`、`audit.js`、`build.js`、`build-closures.js` 四个文件（+ 文档）。
`git diff` 可整轮回退；稿的产物（`code.js`）重新构建即可复原。

## 13. 未决与后续

1. **Figma 实跑**（2026-09-18 已获当次授权但被本机锁屏挡住）：解锁后把 59 板落到 Figma 的
   页 `01 闭环`，确认几何、深色改绑与导出。产物包已是 16:10 那一版（closure kit md5
   `8ffdf02b07ca624d2d5196cab062c038`）；实跑要看的是插件报告的 `AUDIT VERDICT` 与
   `prototype links`（应为 234/234），以及本轮改过真实几何的那几处有没有新溢出。
2. **会话组进 `AppRoute`**：当前实现只有 创作 / 引擎 两个组 10 个路由；`assistant` / `meeting` /
   `captions` 尚未成为路由。三者要成为一等公民（同一个侧栏、同一套快捷键、同一份状态带），
   第一步是把 `AppRouteGroup` 补上 `.session`。
3. **`⌘⌃I` / `⌘⌥S` 冲突检测**（真机）。
4. **实现侧 token 补齐**：`Layout` 里还没有「列表列 280 / 列表内宽 248 / 空态 320」这几个会话侧
   用的符号，加的时候按 §3.4 的对照表命名，不要新造第三个名字。
5. **圆角注释债**：`SpeechRailDesignTokens.swift` 里两处注释引用稿的「圆角 7」，本轮稿已改为 8，
   实现侧数值本来就是 8（`Corner.nested`），只需更新注释文字。
6. **收起态的覆盖面**：收起控件已落在 16 块画板；**收起态画面**只画了语音助手一块作为对齐样例，
   会议与字幕的收起态属于同一规则的状态、不另画板（判据④的实现要求见 SESSIONS-SPEC §18.4）。
