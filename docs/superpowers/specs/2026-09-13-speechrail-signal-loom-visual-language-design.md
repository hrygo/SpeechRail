---
title: "SpeechRail Signal Loom 视觉语言与 App-wide Token 设计规范"
status: "review"
audience: "SpeechRail macOS App 产品、设计、前端与核心开发人员"
version: "0.2.0"
date: 2026-09-13
supersedes: "docs/architecture/speechrail-macos26-workspace-redesign-design.md"
---

# 🎙️ SpeechRail Signal Loom 视觉语言与 App-wide Token 设计规范 (v0.2.0)

> **设计定位与事实基线**：
> 本规范定义 SpeechRail macOS 原生应用（`SpeechRailApp`，面向 macOS 26.0+ Apple Silicon）的统一设计系统与视觉工程标准。它彻底终结“通用圆角卡片堆叠”、“悬浮标题竞争”、“无语义状态色块”以及“运维界面挤占创作主线”的历史设计债务，确立以 **Signal Loom「信号织网」** 为核心的顶尖工业级设计范式。
>
> **评审状态说明**：
> 当前版本为经过产品、设计与工程多方审阅校准后的 `review` 评审稿，所有设计决策严格与 Python 服务端资源治理、FluidAudio CoreML 匿名分人、macOS 桌面人机界面指南（HIG）以及真实服务能力边界对齐。在工程团队依据本规范编写实施计划并验收通过后，方作为代码落地之基准。

---

## 1. 核心设计哲学：Signal Loom 的三大支柱

SpeechRail 不是一个冷冰冰的模型包装器，而是一座架设在 Apple Silicon 上的**本地声音中枢**。它向上支撑创意者的音色雕琢与配音心流，向下掌控多模型并发调度、FluidAudio CoreML 匿名分人（Session-scoped 说话人分段，不持久化声纹库）与实时流式传输。

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        SIGNAL LOOM 设计哲学体系                         │
├───────────────────┬────────────────────────────┬───────────────────────┤
│   SIGNAL (信号)   │        LOOM (织网)         │     STUDIO (工坊)     │
│   系统真理与遥测   │      时序编排与结构秩序      │     声学温度与触感    │
├───────────────────┼────────────────────────────┼───────────────────────┤
│ • 状态结论优先    │ • 经纬分明的信息轨道        │ • 陶土暖色 (Terracotta)│
│ • 杜绝孤立红绿点  │ • 字段化 (Field) 取代卡片   │ • 声学胶囊与波形触感   │
│ • 严谨的时延与指标 │ • 连续对齐的行进节奏        │ • 沉浸式 A/B 试听机架  │
└───────────────────┴────────────────────────────┴───────────────────────┘
```

### 1.1 四大设计原则 (The 4 Design Principles)

1. **真实高于装饰 (Truth Before Ornament)**
   - 杜绝装饰性动效与伪造的进度条；
   - 状态必须包含「图标 + 结论标签 + 影响说明 + 明确下一步」四要素，严禁孤立颜色圆点；
   - macOS 26 Liquid Glass 材质严格限制于导航与工具栏层，正文内容区保持纯净极简的哑光字段（Fields）。
2. **声学物理触感 (Acoustic Tactility)**
   - 声音是有形且可感知的；
   - 创作流提供波形预览、声学特征标签（Acoustic Chips）以及符合 macOS 桌面习惯的交互反馈；
   - 音色创作专属陶土暖色（`Color.voice`），在冷峻的系统蓝调中点亮创作心流。
3. **渐进启示与统一真理 (Progressive Disclosure & Unified Truth)**
   - **Level 1（普通用户/创作者层）**：首屏 3 秒内识别“当前状态、能做什么、如何开始”，零技术术语门槛，不常驻暴露原生端口和内部模型 revision；
   - **Level 2（工程师/排障层）**：通过可折叠 Inspector 获得脱敏端口、Worker 租约、RTF 时延、内存高水位；
   - 两层必须基于同一套状态事实源，严禁出现结论打架。
4. **macOS 26 原生人体工学 (Native Desktop Ergonomics)**
   - 完全依托 macOS 26 标准窗口拓扑、SF Pro / SF Mono 系统排版、Dynamic Type 与全键盘快捷链路；
   - 遵循 macOS 桌面级指针交互尺寸（Compact 28pt / Regular 34pt / Prominent 40pt），不生搬硬套移动端触控 44pt 规则。

---

## 2. 空间拓扑与双轨工作台架构 (Dual-Track Workspace)

为兼顾“创作者心流”与“工程师掌控”，侧边栏采用清晰的**双轨语义分组（Dual-Track Navigation）**，杜绝页面定位混乱。

### 2.1 整体空间视区规划

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│  Window Toolbar: [Sidebar Toggle] [Title & Status Pill]  ──  [Track Actions] [Inspector]│
├──────────────────┬──────────────────────────────────────────────┬──────────────────────┤
│ SIDEBAR (240pt)  │ MAIN CANVAS (1,240pt max)                    │ INSPECTOR (320pt)    │
│                  │                                              │                      │
│ ▾ STUDIO (创作)  │ ┌──────────────────────────────────────────┐ │ ▾ 选中对象详情       │
│   🎙️ 配音台      │ │ 页面定位说明与主任务区                   │ │   ID / 规格参数    │
│   🎨 音色创作    │ └──────────────────────────────────────────┘ │   声学参数 / 属性    │
│   🗂️ 音色库      │ ┌──────────────────────────────────────────┐ │                      │
│   📦 我的作品    │ │ StatusConclusion (状态结论，仅按需出现)  │ │ ▾ 试听 / 快捷操作  │
│                  │ └──────────────────────────────────────────┘ │   [▶ 试听] [复制]    │
│ ▾ ENGINE (核心)  │ ┌──────────────────────────────────────────┐ │                      │
│   ⚡ 服务中枢    │ │ Field 容器 (列表 / 编辑器 / 指标趋势)    │ │ ▾ 开发者技术证据   │
│   🧠 模型档位    │ └──────────────────────────────────────────┘ │   Worker/Latency     │
│   📈 运行监控    │                                              │                      │
│   🩺 系统诊断    │                                              │                      │
├──────────────────┴──────────────────────────────────────────────┴──────────────────────┤
│ Sidebar Footer: [✓ 服务已就绪 · Quality] (无孤立红绿点、不暴露原生端口)       v2.5.2     │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 双轨职责与心智模型

| 轨道 | 涵盖页面 | 交互心智与视觉特征 | 默认 Inspector 行为 |
|---|---|---|---|
| **Studio 创作工坊** | 配音台、音色创作、音色库、我的作品 | 强调白噪音降低、专注文本与声音雕琢。引入 `Accent.voice`（陶土暖色），主区大留白（`Spacing.hero`） | 承载音色参数微调、A/B 试听候选机架、波形控制器 |
| **Engine 核心引擎** | 服务中枢、模型档位、运行监控、系统诊断 | 强调精确、可靠、低延迟与高透明度。主打冷墨色、信号蓝与系统状态色，等宽数字排版 | 承载模型 Manifest 校验、Worker 进程租约、脱敏排障日志 |

---

## 3. 全局 Design Token 体系 (App-wide Tokens)

Token 唯一工程落地源：`macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`。
所有命名均基于**语义与功能角色**，严禁使用页面名或视觉别名（如 `blueCard`、`successGreen`）。
**API 统一命名约定**：文档中提及的 `Color.*` 在 Swift 中完全对应于 `SpeechRailDesignTokens.Color.*`，保持 1:1 纯正对应。

### 3.1 语义色彩体系 (Color & Signal Tokens)

所有颜色必须完美自适应 Light Mode、Dark Mode 以及 Increase Contrast（提高对比度模式）。
- **默认对比度标度**：符合 WCAG AA 级无障碍标准（正文文本 4.5:1，UI 组件与边界 3:1）；
- **系统高对比度偏好**：在开启 macOS「提高对比度（Increase Contrast）」偏好时，关键文字与交互边界全面提升至 WCAG AAA（7:1）。

```text
       INK (墨底)             RAIL (信号蓝)            VOICE (陶土暖色)
┌──────────────────────┐ ┌──────────────────────┐ ┌──────────────────────┐
│ Light: #111822       │ │ Light: #4E61E6       │ │ Light: #C26743       │
│ Dark:  #F0F4F8       │ │ Dark:  #8796FF       │ │ Dark:  #E88F6D       │
│ 角色: 品牌主干与高强文本│ │ 角色: 导航聚焦与系统主动作│ │ 角色: 音色创作专属强调 │
└──────────────────────┘ └──────────────────────┘ └──────────────────────┘
```

#### 核心调色板规格表

| Token (Swift: `SpeechRailDesignTokens.Color.*`) | Light (Hex) | Dark (Hex) | High Contrast (Light / Dark) | 语义角色与禁止用法 |
|---|---|---|---|---|
| `Color.ink` | `#111822` | `#F0F4F8` | `#000000` / `#FFFFFF` | 品牌墨色；用于高强调文本，禁止做大面积实色背景 |
| `Color.canvas` | `#F6F8F9` | `#13171A` | `#FFFFFF` / `#000000` | 窗口根底色与主滚动区域 |
| `Color.field` | `#FFFFFF` | `#1C2227` | `#FFFFFF` / `#161B1E` | 内容承载表面（编辑器、表格、列表组、图表底面） |
| `Color.rail` | `#23687D` | `#4FA4BA` | `#144959` / `#7FD3E6` | **Logo 声轨信号色**；提取自官方 App 图标冷青铁轨钢光（Sonic Rail Cyan），用于系统信号、当前聚焦选中、主要动作 |
| `Color.titanium` | `#4D5358` | `#CCD1D0` | `#24282B` / `#FAFAFA` | **航天冷钛金属色**；提取自 Logo 'S' Crest 微雕质感与频谱微光 |
| `Color.voice` | `#C26743` | `#E88F6D` | `#9E4928` / `#FFAE90` | **音色创作专属色**；用于 VoiceDesign 候选、试听条、声学标签 |
| `Color.ready` | `#26856C` | `#52BFA1` | `#175C4A` / `#6FE0C0` | **已就绪 / 正常**；必须配合 ✓ 图标与文字使用 |
| `Color.attention`| `#9E6E1C` | `#D9AB43` | `#78510E` / `#F0C45C` | **准备中 / 资源告警 / 待确认**；禁止暗示系统已崩溃 |
| `Color.critical` | `#BA3539` | `#E87074` | `#8E1E22` / `#FF9296` | **不可用 / 失败 / 破坏性操作**；必须配合 ✕ 图标与确定性文案 |
| `Color.info` | `#39729E` | `#6EA9D6` | `#254E6D` / `#8DC0EA` | **中立信息 / 能力说明 / 技术详情** |

#### 前景与文本角色映射

| Token | 系统级绑定 | 典型场景 |
|---|---|---|
| `Foreground.primary` | `Color.primary` | 标题、主要数值、选中文本 |
| `Foreground.secondary`| `Color.secondary` | 描述段落、表单说明、次级时间戳 |
| `Foreground.tertiary` | `Color.secondary.opacity(0.7)` | 占位符、边框辅助、极弱分隔 |
| `Foreground.technical`| `Font.system(.caption2, design: .monospaced)` | 端口号、SHA256 摘要、Worker 租约 ID、音频参数（由字体层实现等宽） |

---

### 3.2 表面与材质物理体系 (Surface & Elevation)

macOS 26 倡导沉浸式材质分层。**绝对禁止“全屏卡片套卡片”或“多层漫反射黑阴影”**。层级全部依托**材质透过率、精密描边（Hairline Strokes）与自然间距**呈现。

```text
[Level 0: Window Background] ── 纯色/环境底色
  └─ [Level 1: System Liquid Glass] ── 仅用于 Sidebar 与 Toolbar (支持壁纸色相渗透)
       └─ [Level 2: Canvas 主画布] ── 纯净平铺底色
            └─ [Level 3: Field 字段表面] ── 0.5px 精密描边，承载核心信息
                 └─ [Level 4: Control 交互控件] ── 悬浮/聚焦态轻量材质
```

| 层级 | 语义 Token | macOS 26 材质策略 | 边框与阴影规范 |
|---|---|---|---|
| **Level 0** | `Surface.window` | 系统基础窗口背板 | 无边框，无阴影 |
| **Level 1** | `Surface.navigation` | `.glassEffect(.regular)` | 系统内建 Liquid Glass，自适应暗区色相渗透 |
| **Level 2** | `Surface.canvas` | `Color.canvas` 哑光纯色 | 纯净底面，禁止叠加任何阴影 |
| **Level 3** | `Surface.field` | `Color.field` | 边框：`Color.primary.opacity(0.07)` 0.5px 极细线；<br>Dark 模式辅以顶部 `0.5px` 的 `white.opacity(0.05)` 内高光；**零模糊投影** |
| **Level 4** | `Surface.inspector` | `.thinMaterial` 或纯色底面 | 左边缘配备 `1px` 细分界线，独立纵向滚动 |
| **Level 5** | `Surface.control` | `.regularMaterial` 或状态色微填充 | 聚焦态激活 `2px` `Color.rail.opacity(0.4)` Focus Ring |

---

### 3.3 空间节奏与布局常量 (Spacing & Layout)

基于 **4-pt / 8-pt 物理网格** 演进，杜绝任何任意手写数值（如 `17`、`23`、`38`）。

```text
4pt(micro) ── 8pt(xs) ── 12pt(sm) ── 16pt(md) ── 24pt(lg) ── 32pt(xl) ── 48pt(hero)
```

| Token | 数值 (pt) | 唯一用途 |
|---|---:|---|
| `Spacing.hairline` | 1 | 极细分割线、表头下划线 |
| `Spacing.micro` | 4 | 图标与相邻文字间隙、胶囊内边距 |
| `Spacing.xs` | 8 | 表单输入框内组件间隙、同组按钮间距 |
| `Spacing.sm` | 12 | 列表行垂直间距、紧凑字段组内边距 |
| `Spacing.md` | 16 | 标准字段内边距、常规卡片内嵌间隙 |
| `Spacing.lg` | 24 | 大模块间纵向间隔、段落组间距 |
| `Spacing.xl` | 32 | 页面外框边距（Page Margin）、主双列水平间距 |
| `Spacing.hero` | 48 | 仅用于配音台/音色创作编辑器的呼吸空间、空状态大视距 |

#### 布局与桌面端尺寸约束

- `Control.compact`: `28 pt`（紧凑辅助按钮、段落操作）
- `Control.regular`: `34 pt`（标准表单输入、常规按钮）
- `Control.prominent`: `40 pt`（页面主操作 Primary CTA）
- `Layout.windowMinimumWidth`: `1,120 pt`（低于此尺寸收起 Inspector，防止内容挤压）
- `Layout.windowMinimumHeight`: `720 pt`（确保首屏至少完整展示定位、状态与主任务）
- `Layout.sidebarIdealWidth`: `240 pt`（可调整范围：`200 pt` ~ `280 pt`）
- `Layout.inspectorIdealWidth`: `320 pt`（可调整范围：`280 pt` ~ `400 pt`）
- `Layout.contentMaximumWidth`: `1,240 pt`（大屏超宽显示器下限制文本行宽，保持最佳视线跨度）

---

### 3.4 形状与圆角嵌套定律 (Corner Radii)

圆角必须遵循**同心同率定律**：`Corner.outer = Corner.inner + Padding`。禁止外小内大或尖锐突变。

```text
┌─────────────────────────────────────────────────────────┐ ── Corner.field (14pt)
│  Padding: 12pt (sm)                                     │
│  ┌───────────────────────────────────────────────────┐  │
│  │ 内部可交互行组 / 控件                               │  │ ── Corner.row (8pt)
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

| Token | 半径 (pt) | 应用实体 |
|---|---:|---|
| `Corner.control` | 6 | 小型按钮、输入框、下拉选单、微型开关 |
| `Corner.row` | 8 | 列表选中高亮条、内部单元格、次级分组行 |
| `Corner.field` | 14 | 承载表面（Fields）、图表容器、主文本编辑器 |
| `Corner.module` | 18 | 独立浮动窗口、主对话框、大面板外廓 |
| `Corner.pill` | 999 | 状态胶囊、声学标签（Chips）、音频时长标 |

---

### 3.5 排版与字体层次 (Typography Scale)

全面启用系统 Dynamic Type 机制。正文采用 **SF Pro**，数值与度量采用 **SF Pro Rounded**（具备 Tabular 属性），工程数据采用 **SF Mono**。

| 角色 Token | 字体规格 | 默认特征 | 用途与约束 |
|---|---|---|---|
| `Typography.display` | `Font.system(.title, design: .default, weight: .bold)` | 极具冲击力 | 仅用于空状态邀请语、作品标题 |
| `Typography.pageTitle`| 由系统 Toolbar 统一托管（`title2`，semibold） | 统一原生 | **严禁在内容区重复手写大标题** |
| `Typography.section` | `Font.system(.headline, design: .default, weight: .semibold)` | 明确层级 | 模块与字段组标题（如“声学属性”、“推理时延”） |
| `Typography.body` | `Font.system(.body, design: .default, weight: .regular)` | 舒适阅读 | 页面定位段落、核心操作提示 |
| `Typography.label` | `Font.system(.callout, design: .default, weight: .medium)` | 高扫描性 | 控件文案、表头标签、列表主标题 |
| `Typography.caption` | `Font.system(.caption, design: .default, weight: .regular)` | 辅助弱化 | 绝对时间戳、只读辅助备注 |
| `Typography.metric` | `Font.system(.title3, design: .rounded, weight: .semibold).monospacedDigit()` | 无跳动刷新 | RTF 倍率、时延数值（如 `184ms`）、显存占用 |
| `Typography.technical`| `Font.system(.caption2, design: .monospaced, weight: .regular)` | 严谨等宽 | 端口、SHA256、Worker PID、错误代码 |

---

### 3.6 触觉与声音交互建议 (待实测验证项)

> **工程边界说明**：
> 下列触觉与音效为 macOS 桌面端人机交互的原生设计建议，属于体验增强项，**不作为当前公共服务契约的强保证**。具体在 App 运行时结合系统 API 实测表现逐步落地：

- **触控板微触感（建议）**：音色生成/导出完成可尝试触发轻量弹性回馈；模型切换应用触发明确确认顿挫感；阻断性操作触发双击阻尼感；
- **系统提示音（建议）**：长任务耗时完成后调用系统微和弦（如 `NSSound` 原生提示音），静默后台任务不打扰前台心流。

---

## 4. 核心组件交互与工业制图 (Component Specifications)

### 4.1 页面标准骨架 (`PageScaffold`)

所有 8 个页面必须统一采用 `PageScaffold`，严格统一外框秩序：

```text
┌────────────────────────────────────────────────────────────────────────┐
│ Toolbar: [Sidebar Toggle]  页面标题 (Title)      [操作群] [Inspector开闭]│
├────────────────────────────────────────────────────────────────────────┤
│ Page Content (Padding: 32pt)                                           │
│ ┌────────────────────────────────────────────────────────────────────┐ │
│ │ 1. 页面定位条 (Page Subtitle / Orientation): 简练一句话说明核心价值 │ │
│ └────────────────────────────────────────────────────────────────────┘ │
│ ┌────────────────────────────────────────────────────────────────────┐ │
│ │ 2. StatusConclusion (可选): 仅当状态发生跃迁或存在阻断时常驻置顶   │ │
│ └────────────────────────────────────────────────────────────────────┘ │
│ ┌────────────────────────────────────────────────────────────────────┐ │
│ │ 3. 主任务工作区 (Primary Action Field): 编辑器 / 矩阵 / 核心配置   │ │
│ └────────────────────────────────────────────────────────────────────┘ │
│ ┌────────────────────────────────────────────────────────────────────┐ │
│ │ 4. 次级详情字段 (Secondary Fields): 数据趋势 / 历史列表             │ │
│ └────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────┘
```

- **Toolbar 状态锚定铁律**：`Title & Status Pill` 必须是原生 window toolbar 内挂载的状态信息（如 `.windowToolbar` / `.principal` 或 leading 导航项），**严禁在画布内容正文重新渲染脱离窗口顶栏的居中悬浮大标题**。

---

### 4.2 状态结论面板 (`StatusConclusion`)

状态组件必须在 2 秒内解答“发生了什么、影响有多大、我该做什么”。

```text
┌────────────────────────────────────────────────────────────────────────┐
│ [✓/!/✕ 图标]  【状态大标签：已就绪 / 需处理】   [最后同步: 14:38:02]   │
│               说明文本：SpeechRail 本机引擎正常运行，全部能力准备就绪。  │
│               影响范围：本地端口监听中；所有集成 Agent 均可调用。        │
│                                                                        │
│               [主要恢复动作: 立即应用]    [次要动作: 查看能力清单]      │
└────────────────────────────────────────────────────────────────────────┘
```

- **语义语法**：`[Icon] + [Headline] + [Explanation] + [Scope] + [Single Primary CTA]`；
- **防冲突与非重复原则**：
  - **Sidebar Footer 是唯一的紧凑全局常驻入口**；
  - 正文 `StatusConclusion` 绝不无脑复制全局健康信息。它**仅在**以下场景条件激活：① 「服务中枢」主视区，② 页面任务遇到阻断（如缺少模型、离线），③ 长任务执行跃迁中。在正常的创作页面（如配音台、我的作品），首屏完全留给创作任务，不显示重复的状态横幅。

---

### 4.3 异步操作与模型生命周期轨道 (`OperationBar`)

模型下载（通常 2GB ~ 8GB）、权重校验与环境准备涉及长时耗时。必须依托真实的 Python 后端状态，以**确定性进度轨道**呈现：

```text
未开始 ──► 已接受 ──► 下载中 (MB/s & ETA) ──► 校验中 (SHA256) ──► 就绪待应用 ──► 切换中 ──► 已激活
                           │                                                 │
                           └──► 失败 / 空间不足 / 被中断                     └──► 切换失败 / 回退
```

#### 组件物理结构

```text
┌────────────────────────────────────────────────────────────────────────┐
│ 🧠 Quality 档位 (Qwen3-TTS 1.7B + Align-bf16)       [下载中 42%]       │
│                                                                        │
│ ▰▰▰▰▰▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱   1.2 GB / 2.8 GB (18.4 MB/s)  │
│ 预计剩余时间: 1 分 14 秒 · 校验方式: SHA256                            │
│                                                                        │
│ [取消并清理下载]                                             [后台静默] │
└────────────────────────────────────────────────────────────────────────┘
```

- **关键准则**：下载完成**绝不等于**已应用。下载完成后状态转换为 `[就绪待应用]`。切换档位涉及后台 Worker 进程管理与资源重载，应用前必须展示明确的影响范围确认，并支持平稳回退。

---

### 4.4 音色创作器与声学胶囊机架 (`VoiceDesignStudio` & `AcousticRack`)

面向 Qwen3 VoiceDesign 打造的专业级创作面板：

```text
┌────────────────────────────────────────────────────────────────────────┐
│ 🎨 声音特征描述 (Voice Description)                       [Accent.voice]│
│ ┌────────────────────────────────────────────────────────────────────┐ │
│ │ 成年男性中文声线，低沉、近距离、克制而清晰，略带胸腔共鸣。         │ │
│ └────────────────────────────────────────────────────────────────────┘ │
│ 常用声学特征胶囊 (Acoustic Chips):                                     │
│ [＋ 磁性胸腔]  [＋ 近场收音]  [＋ 纪录片解说]  [＋ 青年男声]  [＋ 治愈系] │
│                                                                        │
│ 试听参考文案: 「你可以称我为愚者，亦或是时间的记录人。」              │
│                                                                        │
│                                   [生成音色候选 (⌘ Return)  ── 陶土色] │
├────────────────────────────────────────────────────────────────────────┤
│ 候选试听机架 (Candidate A/B/C/D Shelf):                                │
│ ┌────────────────────────────────────────────────────────────────────┐ │
│ │ [▶ 播放] 候选 A (4.2s)   |||i|li|i|li|i|l|i (波形预览)   [保存到音色库]│
│ │ [▶ 播放] 候选 B (4.1s)   ||li|i|li|li|i|l|i (波形预览)   [保存到音色库]│
│ └────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────┘
```

---

### 4.5 开发者与上下文审阅侧栏 (`DeveloperInspector`)

- 选中主画布任意项目（模型行、音色卡、诊断项、历史日志）时，Inspector 立即流式推入对应上下文；
- **数据与脱敏边界双轨隔离**：
  - **业务作品层（我的作品）**：展示完整的输入文本回溯，属于创作者自有的创作资产，保障可读与复用；
  - **技术审计层（Developer Inspector）**：严守脱敏铁律，仅展示 Request ID、推理时延、Token 计数、脱敏 Worker PID 和匿名化分人标签（`speaker_0`），**严禁**暴露用户完整 Prompt、Base64 音频、绝对文件路径或实名身份；
- **一键调试**：所有技术标识（Job ID, Revision, Hash）自带小巧复制图标与键盘 `⌘C` 响应。

---

## 5. 八大核心页面空间映射与交互蓝图 (Screen-by-Screen Blueprint)

### 5.1 配音台 (Dubbing Studio)
- **用户心智**：快速选择音色，输入或导入文本，高保真生成目标语音并导出。
- **视觉重心**：主文本排版编辑器，字号 16pt，具备行号与标点停顿标记提示。
- **Inspector**：当前所选音色的参数（语速 `0.5x~2.0x`、音频格式 `WAV/MP3/FLAC`、采样率）。
- **杜绝要素**：严禁在首屏放置复杂的服务器端口、模型下载卡片等运维杂音。

### 5.2 音色创作 (Voice Design Studio)
- **用户心智**：通过自然语言与声学胶囊塑造独一无二的全新声音。
- **视觉重心**：陶土色系强化的 Prompt 描述框与即时候选播放列表。
- **Inspector**：候选音色基础参数概览、参考文本快速试听。
- **杜绝要素**：严禁使用技术栈异常报错堆栈覆盖创作区。

### 5.3 音色库 (Voice Catalog)
- **用户心智**：沉淀、分类、标记和管理系统音色与自定义克隆音色。
- **视觉重心**：清晰的双列/表格列表，每行包含：音色试听按钮、音色名称、声学标签、创建时间。
- **Inspector**：音色详情、基模型来源（Base / Design）、关联配音作品数、删除音色（破坏性保护确认）。

### 5.4 我的作品 (Audio Archive)
- **用户心智**：回溯、复用与导出过往生成的音频资产。
- **视觉重心**：时间轴排序的音频资产清单，内嵌轻量波形试听条与导出按钮（Share/Export）。
- **Inspector**：完整输入文本回溯、生成耗时与 RTF 记录、文件磁盘大小与采样参数。

### 5.5 服务中枢 (Service Core)
- **用户心智**：一眼确认本地服务是否健康，当前激活了什么档位，如何优雅启停。
- **视觉重心**：`StatusConclusion` 置顶大面板（例如：“● Quality 档位运行中 · 延迟 184ms”）。
- **次级字段**：能力矩阵表（ASR 原生词级时间戳、VoiceDesign 并发、FluidAudio 匿名分人就绪）。
- **Inspector**：LaunchAgent 托管信息、端口绑定状态（127.0.0.1 闭环保护）、活跃客户端连接数。

### 5.6 模型档位 (Model Profiles)
- **用户心智**：在 Light（低内存）、Balanced（均衡）与 Quality（全能力）三档间自由调度，并监控磁盘下载。
- **视觉重心**：三档横向比对字段，当前激活档位具备 `Color.rail` 精致边框高亮。
- **次级字段**：模型文件资产列表与 `OperationBar` 下载校验进度。
- **Inspector**：各组件量化精度（Q8 / BF16 / FP16）、CoreML 编译状态、模型磁盘目录安全引用。

### 5.7 运行监控 (Telemetry & Metrics)
- **用户心智**：了解系统负载、内存驻留是否超预算、语音合成是否发生拥堵。
- **视觉重心**：单条趋势图（实时并发与 RTF 时延），配备 Tabular 紧凑指标条（活动请求数、内存占用、平均首包时延）。
- **Inspector**：Worker 进程树明细、内存上限预算图解（物理内存 / 2）、模式冲突熔断计数。

### 5.8 系统诊断 (Diagnostic Triage)
- **用户心智**：遇到异常时迅速定位根因，一键执行恢复或复制排障报告。
- **视觉重心**：递进式检查项清单（Launchd 权限、端口占用、模型完整性、CoreML 加速可用性）。
- **Inspector**：选中断言失败项的官方排障指引与一键修复动作（如“清理冲突端口”）。

---

## 6. Swift 工程落地契约 (`SpeechRailDesignTokens.swift`)

为确保设计规范以零折损直接落地到 SwiftUI 代码中，工程层必须提供以下标准 API 架构：

```swift
import AppKit
import SwiftUI

// MARK: - SpeechRail Signal Loom Design Tokens (v0.2.0 Baseline)

public enum SpeechRailDesignTokens {

    // MARK: 1. Spacing (4-pt / 8-pt Grid)
    public enum Spacing {
        public static let hairline: CGFloat = 1
        public static let micro: CGFloat    = 4
        public static let xs: CGFloat       = 8
        public static let sm: CGFloat       = 12
        public static let md: CGFloat       = 16
        public static let lg: CGFloat       = 24
        public static let xl: CGFloat       = 32
        public static let hero: CGFloat     = 48
    }

    // MARK: 2. Corner Radii
    public enum Corner {
        public static let control: CGFloat  = 6
        public static let row: CGFloat      = 8
        public static let field: CGFloat    = 14
        public static let module: CGFloat   = 18
        public static let pill: CGFloat     = 999
    }

    // MARK: 3. Semantic Colors (Unified Public API: SpeechRailDesignTokens.Color.*)
    public enum Color {
        public static let ink = SwiftUI.Color("Ink", bundle: .main)
        public static let canvas = SwiftUI.Color("Canvas", bundle: .main)
        public static let field = SwiftUI.Color("Field", bundle: .main)

        // Dynamic Adaptive Accents
        public static let rail = SwiftUI.Color("RailSignal", bundle: .main)
        public static let voice = SwiftUI.Color("VoiceAccent", bundle: .main)

        // Signal States
        public static let ready = SwiftUI.Color("SignalReady", bundle: .main)
        public static let attention = SwiftUI.Color("SignalAttention", bundle: .main)
        public static let critical = SwiftUI.Color("SignalCritical", bundle: .main)
        public static let info = SwiftUI.Color("SignalInfo", bundle: .main)
    }

    // MARK: 4. Surface & Stroke Tokens
    public enum Surface {
        public static let hairlineStroke = SwiftUI.Color.primary.opacity(0.07)
        public static let selectedFill = Color.rail.opacity(0.10)
        public static let voiceSelectedFill = Color.voice.opacity(0.12)
        public static let focusRing = Color.rail.opacity(0.40)
    }

    // MARK: 5. Typography Scale
    public enum Typography {
        public static let display = Font.system(.title, design: .default, weight: .bold)
        public static let section = Font.system(.headline, design: .default, weight: .semibold)
        public static let body = Font.system(.body, design: .default, weight: .regular)
        public static let label = Font.system(.callout, design: .default, weight: .medium)
        public static let caption = Font.system(.caption, design: .default, weight: .regular)
        public static let metric = Font.system(.title3, design: .rounded, weight: .semibold).monospacedDigit()
        public static let technical = Font.system(.caption2, design: .monospaced, weight: .regular)
    }

    // MARK: 6. Layout Constants
    public enum Layout {
        public static let windowMinimumWidth: CGFloat   = 1_120
        public static let windowMinimumHeight: CGFloat  = 720
        public static let contentMaximumWidth: CGFloat  = 1_240
        public static let sidebarIdealWidth: CGFloat    = 240
        public static let inspectorIdealWidth: CGFloat  = 320
    }

    // MARK: 7. Motion
    public enum Motion {
        public static let springTransition = Animation.spring(response: 0.28, dampingFraction: 0.82)
        public static let selectionFeedback = Animation.easeOut(duration: 0.14)
    }
}

// MARK: - Standard Field Container ViewModifier

public struct SpeechRailFieldModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    public func body(content: Content) -> some View {
        content
            .background(SpeechRailDesignTokens.Color.field)
            .clipShape(RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field))
            .overlay {
                RoundedRectangle(cornerRadius: SpeechRailDesignTokens.Corner.field)
                    .stroke(SpeechRailDesignTokens.Surface.hairlineStroke, lineWidth: 0.5)
            }
    }
}

public extension View {
    func speechRailField() -> some View {
        modifier(SpeechRailFieldModifier())
    }
}
```

---

## 7. 渐进式实施与验收标准 (Handoff & Acceptance)

### 7.1 阶段性交付路线图

```text
阶段 1: Token & 基础层 (Tokens & Primitives)
  ├── 落地 Color Asset Catalog (Dark/Light/High-Contrast 9 组 Color Sets 补齐)
  ├── 落地 SpeechRailDesignTokens.swift 全量定义并保持向前兼容别名
  └── 统一 PageScaffold 容器与窗口最小约束

阶段 2: 核心引擎页面重构 (Engine Surfaces)
  ├── 重塑「服务中枢」：落地单一置顶 StatusConclusion，移除浮动绿点与卡片堆叠
  ├── 重塑「模型档位」：实现 OperationBar 真实状态生命周期轨道
  └── 重塑「运行监控」与「系统诊断」：接入单趋势折线与按需推入 Inspector

阶段 3: 创作工坊页面重构 (Studio Surfaces)
  ├── 落地「音色创作」：陶土色系注入，声学胶囊机架与 A/B 候选试听机架
  └── 统一「配音台」、「音色库」与「我的作品」列表与 Field 容器

阶段 4: 契约终验与清理 (Final Sweep)
  ├── 清除所有过时别名（如 Palette.panel, Palette.tint 等）
  ├── VoiceOver 无障碍巡检与键盘全链路测试
  └── 执行代码门禁：Swift Build、Pytest、OpenAPI Lint 与回归测试
```

### 7.2 严苛验收指标 (Acceptance Criteria)

1. **信息层级扫描性**：首屏 3 秒内，任何新用户均能准确回答出“服务状态、激活档位、主任务区”三要素；
2. **零卡片堆叠**：全 App 内容区不再存在两层以上的白底嵌套矩形与生硬的深色漫反射投影；
3. **桌面端触达合规**：所有控件符合 macOS 原生人机交互标准，主操作、辅助按钮尺寸与焦点环清晰分层；
4. **色彩与对比度合规**：默认满足 WCAG AA 标度；在系统开启「提高对比度」模式下，文本对比度达到 WCAG AAA（7:1）；
5. **单视觉重心**：单屏内仅有一处突出 Primary CTA，次级操作一律退入标准 Control 层；
6. **工程门禁**：`SpeechRailApp` 编译 0 Warning，相关测试 100% 通过。

---

## 8. 实施前锁定的五个关键工程约束 (Engineering Lock-in Agreements)

本节明确记录经产品、设计与工程团队共同签署确认的 5 大工程落地边界，在后续实施计划与代码开发中**严格遵循，不得随意漂移**：

1. **Toolbar 状态原生挂载，严禁居中悬浮标题**
   - 页面标题与 Status Pill 必须使用系统原生 `.toolbar` 挂载于窗口工具栏（如 `.windowToolbar` / `.principal` 或 leading 导航项），彻底杜绝在主画布内重新绘制居中脱节的卡片式大标题。
2. **全局状态单一入口原则，杜绝信息冗余复制**
   - 侧边栏底部 `[✓ 服务已就绪 · Quality]` 是全 App 唯一的常驻全局服务状态指示；
   - 正文中的 `StatusConclusion` 绝不机械复制全局健康信息。它仅在服务专属主页（Service Overview）、任务受阻（如模型缺失）或长任务跃迁期间条件出现。在正常的创作流中，首屏空间 100% 留给任务区。
3. **公共 API 命名统一收敛为 `SpeechRailDesignTokens.Color.*`**
   - 文档中的 `Color.ink`、`Color.field` 与 Swift 实现完全统合，直接采用 `SpeechRailDesignTokens.Color.ink`，消除文档与代码之间的命名认知摩擦。
4. **Asset Catalog 前置就绪铁律 (Color Sets)**
   - 鉴于当前 `Assets.xcassets` 仅有 AppIcon，实施阶段 1 必须在 `SpeechRailApp/Assets.xcassets` 中补齐全套 9 个包含 Any/Light/Dark/High-Contrast 外观的 Color Sets，并在 Swift 层提供安全的系统色兜底，避免运行时颜色丢失。
5. **真实能力条件渲染与数据隐私边界双轨隔离**
   - **真实服务能力门禁**：波形预览、回退操作、端口修复和 CoreML 预热编译等高级控件必须基于 Python 后端实际能力条件展示，未就绪时优雅降级为静态标签，杜绝假进度与未支持操作；
   - **业务资产与技术审计双轨隔离**：「我的作品」中展示创作者自有的完整输入文本；而「开发者 Inspector」严格遵循脱敏协议，仅展示匿名化元数据（Request ID、时延、Token 统计、会话级匿名分人标签 `speaker_0`），严禁日志侧泄露用户输入、Base64 音频或绝对敏感路径。

---

## 9. 验收测试标准与断言清单 (Acceptance Criteria & Test Matrix)

为确保工程落地、设计走查与 QA 测试具备可量化、可验证的闭环标准，制定以下 8 组可测试断言清单（Acceptance Criteria）：

### AC-01: Token 体系完整性与 Asset Catalog 契约
- **Given**：在 macOS 26.0+ 环境下使用 Xcode 编译并启动 `SpeechRailApp`；
- **When**：各页面视图直接引用 `SpeechRailDesignTokens.Color.*`（包含 `ink`, `canvas`, `field`, `rail`, `voice`, `ready`, `attention`, `critical`, `info`）；
- **Then**：
  1. `SpeechRailApp/Assets.xcassets` 中包含上述 9 组命名 Color Sets，且全部补齐 Any / Light / Dark / High Contrast 4 种外观变体；
  2. 动态切换系统深色/浅色模式时，界面背景与字段边缘自然自适应，无生硬闪烁或取色丢失（Fall-through to black/clear）；
  3. 兼容层保留的旧别名（如 `@available(*, deprecated) Palette.panel`）仍能通过编译，不破坏现有过渡代码。
- **验证手段**：Xcode Build 0 错误 + `SpeechRailDesignTokensTests` 单元测试。

### AC-02: 原生 Toolbar 挂载与零悬浮大标题
- **Given**：用户在侧边栏任意切换 8 个视图页面；
- **When**：主内容画布（Main Canvas）完成布局与首帧渲染；
- **Then**：
  1. 页面标题与状态胶囊（Status Pill）严格位于系统原生 `.toolbar` 内部（`.windowToolbar` / `.principal` 或 leading 导航项）；
  2. 主画布正文区**绝对不存在**脱节的居中悬浮大标题、伪卡片外框或重复的主标题文本；
  3. 画布首行仅允许存在紧凑的「页面定位说明（Page Subtitle）」，字号为 `Typography.body`，描述简洁明确（不超过 40 字）。
- **验证手段**：Accessibility Inspector 检查窗口 AX 结构树，断言无重复 `AXHeading`。

### AC-03: 双轨工作台导航与侧边栏唯一全局状态入口
- **Given**：打开 `SpeechRailApp` 主窗口；
- **When**：观察侧边栏（Sidebar）；
- **Then**：
  1. 侧边栏结构清晰呈现为两大独立语义分组：`STUDIO (创作工坊)`（配音台、音色创作、音色库、我的作品）与 `ENGINE (核心引擎)`（服务中枢、模型档位、运行监控、系统诊断）；
  2. 侧边栏底部常驻全 App **唯一的紧凑全局服务状态摘要**（如 `[✓ 服务已就绪 · Quality]`），严禁出现无语义的孤立颜色圆点，严禁暴露 `127.0.0.1:8201` 等内部端口；
  3. 点击侧边栏底部状态，可平滑呼出或跳转至「服务中枢」视图；
  4. 正文主视区的 `StatusConclusion` 在正常的创作者工作流（配音台、我的作品、音色库）中**保持隐藏**，杜绝与侧边栏/工具栏状态发生双重复制。
- **验证手段**：UI 自动化测试 + 页面视觉走查。

### AC-04: 模型生命周期与 OperationBar 确定性轨道
- **Given**：用户在「模型档位」页面对未安装的 Profile（如 Quality 档位）点击下载；
- **When**：模型长任务处于各个执行阶段（未开始、下载中、校验中、就绪待应用、切换中、已激活、失败/取消）；
- **Then**：
  1. 下载中阶段必须实时显示已下载字节、总字节、瞬时速度（MB/s）与预计剩余时间（ETA）；
  2. 下载与校验完成后，状态明确跃迁为 `[就绪待应用]`，**绝对不得**自动激活或误导用户认为已在生效；
  3. 用户点击「应用档位」时，弹出二次确定框，明确告知将无缝热重载 TTS/ASR 服务并显示预计耗时；
  4. 用户主动点击「取消并清理」或发生校验错误时，状态转为 `失败 / 已取消`，并提供垃圾制品清理与一键重试能力；
  5. 界面中不存在“暂停下载”、“优先下载”等未经 Python 后端支持的虚构功能。
- **验证手段**：Mock Agent 状态机测试 + 模拟网络错误与校验失败。

### AC-05: Studio 音色创作与声学机架交互
- **Given**：创作者进入「音色创作」视图；
- **When**：输入声音 Prompt 描述并生成候选音色；
- **Then**：
  1. 描述编辑器获取聚焦时激活专属陶土暖色高亮（`Color.voice`）；
  2. 提供开箱即用的声学特征胶囊（Acoustic Chips，如 `[＋ 磁性胸腔]`、`[＋ 治愈系]`），点击可将标签无缝插入描述；
  3. 生成完成后，候选列表以 A/B/C/D 试听机架排列，每项支持：播放/暂停控制、音频波形预览、时长显示以及「保存到音色库」动作；
  4. 若生成发生异常，展示用户可理解的失败原因与恢复入口，严禁底层原始 Python Traceback 遮蔽创作主视区。
- **验证手段**：UI 交互测试 + 候选播放器状态流转测试。

### AC-06: 业务创作资产与开发者 Inspector 隐私脱敏隔离
- **Given**：在「我的作品」选中历史生成项，或在监控/诊断页选中审计对象；
- **When**：展开右侧上下文 Inspector；
- **Then**：
  1. **业务资产侧（我的作品）**：主视图展示创作者完整的输入文本内容（供回溯复用），保障正常业务可读性；
  2. **开发者审计侧（Developer Inspector）**：严守脱敏协议，仅展示 Request ID、时延（ms）、Token 统计、脱敏 Worker PID 以及会话级匿名分人标签（`speaker_0`）；
  3. **脱敏红线**：Developer Inspector 与排障日志中**严禁**输出用户完整 Prompt、Base64 音频明文、绝对模型路径或实名身份。
- **验证手段**：Inspector 数据源绑定单元测试 + 脱敏正则断言。

### AC-07: macOS 桌面人机工学与无障碍/对比度合规
- **Given**：在 macOS 系统偏好中切换不同辅助功能与显示设置；
- **When**：遍历 App 各交互表面；
- **Then**：
  1. 常用控件尺寸符合 macOS 桌面交互标准：Compact 28pt、Regular 34pt、Prominent 40pt，键盘焦点环（Focus Ring）清晰可辨；
  2. 默认模式下文本/组件对比度符合 WCAG AA（正文 $\ge 4.5:1$，组件 $\ge 3:1$）；在系统「提高对比度」模式下，关键文字提升至 WCAG AAA（$\ge 7:1$）；
  3. VoiceOver 轮转器（Rotor）按标准语义顺序导航：`窗口导航 → 页面定位 → 状态结论 (若有) → 主任务区 → 列表/编辑器 → Inspector`；
  4. 所有状态图标具备 `accessibilityLabel`，所有图表具备 `accessibilityChartDescriptor`，无孤立无名元素。
- **验证手段**：Accessibility Inspector 审查 + 系统 High Contrast / VoiceOver 走查。

### AC-08: 工程构建门禁与测试套件完全通过
- **Given**：完成全部 Signal Loom 代码与资源改动；
- **When**：在仓库根目录执行工程构建与自动化门禁脚本；
- **Then**：
  1. `./scripts/macos_app_build.sh --configuration Debug` 构建成功，零编译错误，零新增 Warning；
  2. Xcode 单元测试 `SpeechRailAppTests` 100% 通过；
  3. `SpeechRailAppUITests` 彻底消除多窗口并发定位冲突，全套 UI 用例全部亮绿灯；
  4. 全局质量门禁 `uv run --extra dev pytest`、`ruff check`、`mypy src`、`npx @redocly/cli lint contracts/openapi.yaml` 及 `git diff --check` 全部通过。
- **验证手段**：本地构建脚本与质量门禁命令全量执行。
