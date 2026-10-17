# AI 提词器（Teleprompter）模块体验优化：调研、方案与落地验收记录

- **日期**：2026-10-17
- **任务名**：提词器模块体验优化：调研、方案与落地
- **状态**：已完成确定性单测与编译验收（前台视觉/无障碍/真机麦克风按约束标未验证）
- **适用范围**：`macos/SpeechRailApp/SpeechRailApp/TeleprompterView.swift`、`TeleprompterSession.swift`、`TeleprompterStageView.swift`、`TeleprompterStageWindow.swift`、`SpeechRailDesignTokens.swift` 及对应单测与开发者文档
- **对标参考**：`docs/superpowers/plans/2026-10-16-audiobook-ux-ui-redesign.md`（有声书模块流线型减负与三栏焦点收敛方案）、`docs/developers/macos-app-teleprompter.md`、`docs/developers/macos-app-design-system.md`

---

## 一、现状调研：已落地能力与当前代码偏离盘点

在制定本次方案前，先对仓库历史方案（`2026-09-24-teleprompter-manual-first-design.md`、`2026-10-03-teleprompter-user-journey-plan.md`、`2026-10-05-teleprompter-user-journey-delivery.md`）与当前工作区源码进行逐项核对，明确**哪些历史计划已落地（禁止重复造轮子或假定旧 Bug 仍存在）**、**哪些在演进中出现了新的体验死锁或偏离**。

### 1.1 已落地且运作良好的基础能力（本次保留不动）
1. **即启草稿与归属防丢（E1）**：`TeleprompterSession.updateQuickDraft(title:sourceText:)` 与 `flushPendingDraftSave()` 已实现首次输入即建稿、切稿/开台/AI 整理前强制落盘，失败时置 `draftSaveState = .failed` 并阻塞切换。
2. **手动优先主动作层级（E2）**：`.draft` 原稿相位底部主按钮已是 `打开提词器`（`⌘⏎`），无需等待 AI 或开启麦克风即可直接按段落打开悬浮舞台；`整理朗读稿` 作为次级可选入口。
3. **非目标历史包袱已清理（E4）**：逐句审阅/事实核对（`TeleprompterReviewIssue`）与稿件范围选择（`TeleprompterContentSelection`）已在 2026-10-01 彻底移除，三步 AI 整理流水线（删改建议 -> 分组 -> 口语重写）保持纯粹。
4. **悬浮舞台视觉行与镜面翻转核心能力（E6 / E7 / E8）**：`TeleprompterStageLineLayout` 1/2/3 视觉行排版、`TeleprompterStageSettings.contentWidth` 独立正文栏宽、`TeleprompterStagePreset`（`.camera` / `.podium` / `.custom`）模型层、分光镜镜像模式（`isMirrored` / `⌘⌥M`）以及 `TeleprompterVoiceAssistLifecycle` 代际防串台已落地并通过单测。

### 1.2 当前代码与有声书模块高度相似的五大体验症结（真实源码证据）
对比近期有声书模块（`035821e0`）解决的「卡片海套娃、顶底按钮重复、隐私提示占满首屏、状态流转卡死」问题，当前提词器模块存在以下 5 个可由源码直接证实的痛点：

| 编号 | 严重度 | 痛点概述 | 源码证据位置 |
| :--- | :--- | :--- | :--- |
| **P0-1** | **致命（流程死锁）** | **`.ready` / `.ended` 相位下「重新编辑原稿」按钮完全失效（100% No-op）**：用户点击「打开提词器」直接上台后，`openForManualReading()` 会生成确定性分段并设 `activeVersionID`；关台回到工作台后处于 `.ready`（或 `.ended`）。此时底部按钮「重新编辑原稿」调用 `session.discardPendingVersion()`，而该函数在 `activeVersion != nil` 时会执行 `phase = .ready`！用户被永久锁死在只读分段列表中，既无法回原稿改错别字，也没有入口触发 AI「整理朗读稿」。 | `TeleprompterView.swift:2007-2010`<br>`TeleprompterSession.swift:742-749` |
| **P1-2** | **高（卡片海与契约缺失）** | **`.prepared` 口述字符稿阶段三层卡片套娃、每段 144pt 巨型编辑框、每段重复渲染「撤销上次段落修改」按钮、顶底双重「恢复原稿」按钮，且缺失文档承诺的段落「⋯」拆分/合并/插入菜单**：<br>1. `unifiedWorkbench` 已是 `CardSurface`，内部 `workbenchPreparedContent` 又套一层 `CardSurface` + `recessedField` + 每段 `inputField` 卡片，且每段 `TextEditor` 强制 `minHeight = 144pt`（`preparedBlockEditorMinHeight`），10 段短句会撑出近 1600pt 空白盒子；<br>2. `if session.canUndoPreparedEdit { Button("撤销上次段落修改") }` 被写在 `ForEach(session.readingBlocks)` 循环内的 `preparedBlockRow` 里，改过一次段落后**每一段下方都重复出现一个撤销按钮**；<br>3. `workbenchPreparedContent` 顶栏与底部动作坞同时渲染两个 `恢复原稿` 按钮，直接违背 `docs/developers/macos-app-teleprompter.md`「整理相位（`.prepared`）的操作只有常驻底座一处」的规范；<br>4. `TeleprompterSession` 虽已实现 `splitBlock(at:)`、`mergeBlock(at:)`、`insertBlock(after:)`，但 `TeleprompterView.swift` 中**零处调用**，文档承诺的段落右侧「⋯」高级拆分/合并/插入菜单完全缺失。 | `TeleprompterView.swift:1565-1683, 1982`<br>`TeleprompterSession.swift:1180-1268` |
| **P1-3** | **高（数据失步与错拷）** | **目标时长输入框未失焦同步导致按旧时长整理，且左侧列表行菜单「复制稿件内容」拷错稿件并缺失原稿回退**：<br>1. `targetMinutesInput` 仅在 `.onSubmit`（按回车）时调用 `session.setTargetMinutes(mins)`；用户改完数字直接点「整理朗读稿」或「打开提词器」时，使用的是旧时长（默认 20 分钟）；<br>2. 左侧列表行右键/「⋯」菜单的「复制稿件内容」直接调用 `session.exportMarkdown()`，既忽略了被点击行对应的 `document.id`（未选中行会拷成当前激活稿件），又未回退 `sourceText`（未生成版本时什么都拷不到，违背 `macos-app-teleprompter.md` §用户旅程 1）。 | `TeleprompterView.swift:827-833, 1151-1163`<br>`TeleprompterSession.swift:610-628` |
| **P1-4** | **中（顶底栏噪音与预设缺失）** | **首屏常驻推流/隐私长文横幅、顶栏重复「打开提词器」主按钮、底部视效坞缺失「镜头口播 / 讲台阅读」场景预设且在写稿期常驻多行滑杆**：<br>1. `welcomeSafetyNotice` 在即启首屏底部常驻大段推流与隐私提示，挤压写稿空间（有声书模块已收敛为顶栏 `[AI 与隐私 ⓘ]` Popover）；<br>2. `headerActions` 在顶栏重复放置「打开提词器」，与底座主按钮 `打开提词器 ⌘⏎` 视觉竞争；<br>3. 工作台底部视效坞 `workbenchStageSettingsStrip` 缺失 `docs/developers/macos-app-teleprompter.md` §用户旅程 4 规定的 `镜头口播 / 讲台阅读 / 自定义` 场景预设切换器，且在写稿/整理期常驻展开两行滑杆与开关。 | `TeleprompterView.swift:281-348, 619-653, 2036-2155` |
| **P2-5** | **中（舞台按键穿透与副驾弱）** | **悬浮舞台 `TeleprompterPanel.keyHandler` 绕过焦点守卫导致 Space/V/M/Esc 穿透，且就绪/运行态工作台缺少「回到首段」与实时台词副驾预览**：<br>1. `TeleprompterStageWindow.swift:208-243` 的 `panel.keyHandler` 在 AppKit 层直接拦截 `Space/J/K/Left/Right/V/M/Esc`，未检查 `TeleprompterStageView` 的控件焦点或外观 Popover 状态——导致外观 Popover 打开时按 `Esc` 直接关掉整个舞台窗口（违背 `2026-09-24` 规范 §5.2「Esc 优先关闭已打开的菜单/popover，否则关闭舞台」），且当焦点在舞台按钮或 Popover 内时按 `Space`/`V`/`M` 会误触翻行或开关语音；<br>2. `.ready` 分段列表在 `currentSegmentIndex > 0` 时缺少一键「回到首段」按钮；舞台打开时的工作台 `workbenchRunningContent` 仅显示 3 个数字，缺少当前朗读段落的实时副驾预览（Operator View）与手动上一行/下一行/回首段操控。 | `TeleprompterStageWindow.swift:208-243`<br>`TeleprompterStageView.swift:318-378`<br>`TeleprompterView.swift:1711-1897` |

---

## 二、主流提词器竞品真实用户流程研究（核实日期：2026-10-17）

以下调研基于厂商官方文档与近期产品发布资料（核实日期：**2026-10-17**），严格区分**【来源事实】**与**【对 SpeechRail 的设计推断】**。

### 2.1 竞品事实矩阵（官方可核验来源）

| 产品名称 | 核心工作流与交互事实（【来源事实】） | 官方可核验来源链接与核实日期 |
| :--- | :--- | :--- |
| **Elgato Studio 2.0 (Prompter)** | 1. **Untethered（无硬件强绑）文档优先流**：2026 年 9 月发布的 Elgato Studio 2.0 将 Prompter 重构为独立的 `Prompter` 顶层标签页，无需连接硬件即可随时写稿、分段与排练。<br>2. **类 Google Docs / Notion 连续块编辑**：摒弃旧版把整篇稿件锁进单一大章节的做法，提供连续文档流（Document-First），支持按自然段落切分、标记提示块，并随时在编辑与提词间往返。<br>3. **Voice Sync 2.0 与已读压暗**：语音同步跟随朗读推进，已读文本自动压暗（Dimming），支持可选显示进度条与会话计时。<br>4. **1:1 Studio Operator View（主窗导播副驾视图）**：当提词器在镜头前或浮窗运行时，主窗口提供实时同步的导播预览与操控。 | [Elgato Studio 2.0 — The Prompter Experience, Rebuilt](https://www.elgato.com/us/en/explorer/products/teleprompter/elgato-studio-2-0-the-prompter-experience-rebuilt/)（官方发布页，2026-09-03 更新，2026-10-17 核实） |
| **Teleprompter Pro (Mac / iPad)** | 1. **写稿态（Compose/Edit）与提词态（Prompting）零摩擦往返**：脚本列表选中后直接编辑正文；进入提词后可随时退回脚本编辑修改字句，不会因进入过一次提词态就被锁定在只读视图。<br>2. **显示设置渐进披露**：字号、边距（文本栏宽）、镜像翻转（Mirroring）、计时器显示（Show Clocks）、滚动时隐藏控件（Hide Controls While Scrolling）收纳在轻量的设置面板（Settings Popover）中，不挤占写稿画布。<br>3. **手动拖拽/按键优先（Dragging Stops Scrolling）**：任何手动干预立即接管位置，目标时长模式（Timed Scrolling）在手动调速时自动退让。 | [Settings \| Teleprompter Pro Official User Guide](https://guide.teleprompterpro.com/teleprompter/settings/)、[Create a Script \| Teleprompter Pro Official User Guide](https://guide.teleprompterpro.com/scripts/create-a-script/)、[Teleprompter Pro Features](https://teleprompterpro.com/features)（官方文档，2026-10-17 核实） |
| **PromptSmart Pro** | 1. **VoiceTrack 语音跟随与脱稿静默等待**：语音识别仅在用户照稿朗读时推进，停顿或即兴发挥时自动等待，回到稿件词句时继续跟随，且支持离线本地运行。<br>2. **半透明置顶浮窗（Presentation Window）**：在桌面视频会议或录屏软件上方提供紧凑半透明浮窗，将视线固定在摄像头正下方。 | [PromptSmart Official Site](https://promptsmart.com/)（官方产品页，2026-10-17 核实） |
| **Descript & Riverside Teleprompter** | 1. **粘贴即读 + 镜头旁紧凑视窗**：核心路径均为「粘贴/撰写文稿 → 一键开启摄像头旁提词浮窗 → 录制间隙一键返回改词重录（Retake）」。 | [Descript Online Teleprompter](https://www.descript.com/tools/teleprompter)、[Riverside Teleprompter](https://riverside.com/teleprompter)（官方工具页，2026-10-17 核实） |

### 2.2 【设计推断】（结合竞品事实与 SpeechRail 架构约束）
1. **编辑态与就绪态必须双向自由往返（对应 Elgato Studio 2.0 / Teleprompter Pro / Descript 的 Retake 循环）**：真实口播录制中，用户必然经历「写草稿 → 打开提词器试读 → 发现顺口溜或错字 → 关窗回改原稿或做 AI 口语整理 → 再次打开提词器」的高频循环。修复 `.ready` / `.ended` 下「重新编辑原稿」失效是打通这一核心闭环的第一优先级。
2. **口述字符稿（`.prepared`）应采用紧凑的连续文档流，而非高密度套娃大卡片（对应 Elgato Studio 2.0 类 Notion 连续段落流）**：每段强制 144pt 最小高度加三层背景边框会让短句稿件变成巨大的输入框矩阵。改为单层列表流 + 左侧 3pt 语义色条（照念=Accent、提示=Warning、跳过=Muted）+ 紧凑高度（52pt 起）+ 右上角一键切跟读方式与「⋯」拆分/合并/插入菜单，既兑现 `macos-app-teleprompter.md` 规范，又消除视觉噪音。
3. **主窗口在舞台开启时应充当有价值的「导播副驾台（Studio Operator View）」（对应 Elgato Studio 2.0）**：当悬浮舞台开启时，主工作台除了展示进度与时间外，应实时展示当前朗读段正文与上一行/下一行/回到首段快捷控制，方便双屏或桌面导播查看与控场。
4. **舞台设置与合规提示应遵循渐进披露（对应 Teleprompter Pro 设置收纳 & SpeechRail 有声书模块重构经验）**：写稿与整理阶段主画布只留高频摘要与「镜头口播 / 讲台阅读」预设一键切换，细项滑杆收进「显示设置…」Popover；推流防拍与 AI 隐私说明收进顶栏「推流与隐私 ⓘ」Popover。

---

## 三、目标与非目标

### 3.1 优化目标（Goals）
1. **打通「原稿 ↔ 整理 ↔ 就绪 ↔ 舞台」全状态双向闭环**：修复 `.ready` / `.ended` 相位下「重新编辑原稿」按钮失效的死锁，支持从 `.ready` / `.ended` 一键返回 `.draft` 编辑原稿（未改稿前保留已激活版本与朗读进度，并支持 `returnToReadyVersion()` 一键返回已就绪分段）或直接触发「重新整理朗读稿」。
2. **重构 `.prepared` 口述字符稿视图与补齐段落编辑闭环**：移除内部套娃 `CardSurface`，将段落最小高度从 144pt 降至紧凑 Token（`52pt`），消除每段重复渲染的「撤销上次段落修改」与顶栏重复的「恢复原稿」按钮，并补齐段落右侧「⋯」菜单（拆分本段、与下一段合并、在下方插入新段）。
3. **修复目标时长失步与侧栏稿件错拷缺陷**：目标时长输入实时同步并在启动整理/开台前兜底提交；侧栏稿件行菜单「复制稿件内容」精确复制目标 `documentID` 的内容并支持原稿回退。
4. **顶栏/首屏/底部视效坞减负与场景预设补齐**：将首屏常驻推流/隐私横幅收敛为顶栏 `[推流与隐私 ⓘ]` Popover，移除顶栏重复的「打开提词器」按钮；在工作台底部视效坞补齐 `镜头口播 / 讲台阅读 / 自定义` 场景预设切换，并将多维滑杆收敛到 `[显示设置…]` Popover。
5. **修复悬浮舞台键盘焦点守卫与增强就绪/运行态副驾体验**：修复 `TeleprompterPanel.keyHandler` 绕过 `acceptsReadingKeyCommands` 与 `Esc` 未优先关闭外观 Popover 的问题；在 `.ready` 增加「回到首段」快捷重置，在舞台运行态工作台增加当前段落实时预览与手动翻行/回首段控制。

### 3.2 明确非目标（Non-Goals）
- **不改变手动优先与语音显式开启原则**：打开提词器绝不自动开启麦克风或连接实时 ASR。
- **不重新引入已废弃功能**：不重新引入逐句审阅/事实核对（`TeleprompterReviewIssue`）或稿件范围选择（`TeleprompterContentSelection`）。
- **不改动服务端、公共协议或存储 Schema**：不修改 Python 后端、`TeleprompterV2Store` JSON 磁盘格式或跨模块公共接口。
- **不执行未授权的前台 UI 自动化或真机录音测试**：不运行 XCUITest、Playwright、录屏或接管窗口焦点的自动化脚本。

---

## 四、分阶段工作计划与影响文件

### Phase 1：会话状态机闭环与复制/时长同步修复（P0-1 & P1-3）
- **文件**：
  - `macos/SpeechRailApp/SpeechRailApp/TeleprompterSession.swift`
  - `macos/SpeechRailApp/SpeechRailApp/TeleprompterView.swift`
- **改动内容**：
  1. 在 `TeleprompterSession` 新增 `public func returnToDraftEditing()` 与 `public func returnToReadyVersion()`：仅当 `canEdit` 为真时，将 `pendingVersion` 清空并将 `phase` 切回 `.draft`，同时保留 `activeVersion` 与 `savedRunState`（未改原稿前可通过 `returnToReadyVersion()` 一键返回已就绪分段；若修改了 `sourceText`，自动失效旧版本状态）。
  2. 在 `TeleprompterSession` 新增 `public func copyableDocumentText(documentID: String) -> String?`：当 `documentID == document?.id` 时复用 `copyableDocumentText()`；当复制侧栏非当前选中稿件时，优先调用 `v2Store.exportReading(documentID:)`，若该稿件尚未生成正式版本则回退读取该稿件的 `sourceText`。
  3. 在 `TeleprompterView` 的 `.ready` / `.ended` 底座动作栏中，将「重新编辑原稿」绑定至 `session.returnToDraftEditing()`，并新增次级按钮「重新整理朗读稿」（调用 `requestAIAnalysis()`）。
  4. 在 `TeleprompterView` 的 `targetMinutesInput` 增加 `.onChange` 即时校验同步与 `commitTargetMinutesInputIfNeeded()` 提交前兜底，确保无需按回车即可生效。

### Phase 2：`.prepared` 口述字符稿文档流减负与段落「⋯」菜单补齐（P1-2）
- **文件**：
  - `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`
  - `macos/SpeechRailApp/SpeechRailApp/TeleprompterView.swift`
- **改动内容**：
  1. 在 `SpeechRailDesignTokens.Teleprompter` 新增 `public static let preparedBlockCompactMinHeight: CGFloat = 52`、`workbenchStageSettingsPopoverWidth: CGFloat = 320`、`privacyDisclosurePopoverWidth: CGFloat = 360`。
  2. 重构 `TeleprompterView.workbenchPreparedContent`：
     - 移除外层冗余的 `CardSurface` 包装，直接融入 `unifiedWorkbench` 主卡片；
     - 顶栏仅保留统计摘要与**唯一一处**「撤销上次段落修改」按钮（当 `session.canUndoPreparedEdit` 为真时显示），移除顶栏重复的「恢复原稿」按钮（仅保留底座动作坞中的「恢复原稿」）；
     - 重构 `preparedBlockRow(_ block:)`：移除每段内部的重复撤销按钮；采用左侧 3pt 语义色条（`照念` = `rail`、`只作提示` = `attention`、`跳过` = `inkTertiary`）+ 紧凑 `TextEditor`（`minHeight: 52pt`）；
     - 每段右上角提供一键切换跟读方式胶囊（`照念 / 只作提示 / 跳过`）以及渐进披露的「⋯」菜单（`拆分本段` → `session.splitBlock(at: block.ordinal)`、`与下一段合并` → `session.mergeBlock(at: block.ordinal)`、`在下方插入新段` → `session.insertBlock(after: block.ordinal)`）。

### Phase 3：顶栏/首屏/底部视效坞去噪与场景预设补齐（P1-4）
- **文件**：
  - `macos/SpeechRailApp/SpeechRailApp/TeleprompterView.swift`
- **改动内容**：
  1. 移除 `headerActions` 中重复的「打开提词器」按钮；新增紧凑的 `[推流与隐私 ⓘ]` Popover 按钮（`accessibilityIdentifier("teleprompter-privacy-streaming-disclosure")`），集中展示 OBS/桌面共享防拍说明与 AI 整理隐私说明，并移除即启页底部常驻的 `welcomeSafetyNotice` 横幅。
  2. 重构工作台底部 `workbenchStageSettingsStrip`：
     - 补齐 `镜头口播 / 讲台阅读 / 自定义`（`TeleprompterStagePreset`）分段切换器，点选直接调用 `stageSettings.apply(preset)` 并触发 `stageController.refreshWindowSizeIfNeeded()`；
     - 展示单行紧凑视效摘要（如 `38pt · 3行 · 透光48% · 镜像`）与快捷镜像开关，将字号、行距、文本栏宽、背景透光度、常显控制栏、时钟进度等细项收进 `[显示设置…]` Popover（`accessibilityIdentifier("teleprompter-workbench-stage-settings-popover")`），使写稿与整理期底部保持清爽单行。

### Phase 4：悬浮舞台键盘焦点守卫修复与就绪/运行态副驾增强（P2-5）
- **文件**：
  - `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageWindow.swift`
  - `macos/SpeechRailApp/SpeechRailApp/TeleprompterStageView.swift`
  - `macos/SpeechRailApp/SpeechRailApp/TeleprompterView.swift`
  - `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterSessionLifecycleTests.swift`
  - `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterStageSettingsTests.swift`
  - `docs/developers/macos-app-teleprompter.md`
  - `docs/developers/macos-app-design-system.md`
- **改动内容**：
  1. 在 `TeleprompterStagePresentationState` 新增 `controlFocusInside: Bool` 与 `isAppearancePopoverPresented: Bool` 状态及 `acceptsReadingKeyCommands` 计算属性，并提供 `dismissPresentedPopoverIfNeeded() -> Bool`（若 `isAppearancePopoverPresented` 为真则先关闭 Popover 并返回 `true`，否则返回 `false` 交由窗口关闭）。
  2. 在 `TeleprompterStageView` 将 `focusedControl != nil` 与 `isAppearancePopoverPresented` 同步至 `presentationState`，使 `TeleprompterPanel.keyHandler` 严格遵守 `TeleprompterStageInteractionPolicy.acceptsReadingKeyCommands` 与 `Esc` 优先关 Popover 契约。
  3. 在 `TeleprompterView.workbenchReadyContent` 顶栏当 `session.currentSegmentIndex > 0` 时提供「回到首段」快捷按钮；在 `workbenchRunningContent` 增加当前朗读段实时正文卡片与「上一行 / 下一行 / 回到首段」副驾控制栏。
  4. 补充确定性单元测试并同步更新开发者文档。

---

## 五、逐项验收标准与实测证据（Acceptance Criteria & Evidence）

| AC 编号 | 验收维度 | 量化验收标准 | 实测命令与证据 | 当前状态 |
| :--- | :--- | :--- | :--- | :--- |
| **AC-1** | **P0 状态机双向闭环** | 1. 从 `.draft` 点击「打开提词器」进入 `.manual` 并关闭舞台（进入 `.ready`），或完成一次演讲进入 `.ended`，或采纳 AI 整理稿进入 `.ready` 后，调用 `returnToDraftEditing()`（对应界面「重新编辑原稿」按钮）必须将 `session.phase` 切回 `.draft`，不再停留在 `.ready`。<br>2. 切回 `.draft` 时若未修改 `sourceText`，原 `activeVersion` 与 `savedRunState` 保持不丢失，且支持 `returnToReadyVersion()` 一键返回已就绪分段；在 `.ready` / `.ended` 亦可一键发起「重新整理朗读稿」。 | 1. **确定性单测**：`TeleprompterSessionLifecycleTests.returnToDraftEditingBreaksReadyDeadlockAndPreservesActiveVersion` 实测通过（`passed after 0.345 seconds`，退出码 `0`）。<br>2. **目标码编译**：`TeleprompterSession.o`（1.2MB）与 `TeleprompterView.o`（6.1MB）经 `swift-frontend -c` 编译生成通过（退出码 `0`）。 | **确定性单测与编译已通过**（前台点击交互未验证） |
| **AC-2** | **P1 `.prepared` 文档流减负与段落菜单** | 1. `SpeechRailDesignTokens.Teleprompter.preparedBlockCompactMinHeight` 为 `52pt`，`.prepared` 视图不再嵌套第二层 `CardSurface`。<br>2. 「撤销上次段落修改」按钮移至 `.prepared` 列表顶栏且全局仅渲染 1 处；顶栏重复的「恢复原稿」按钮被移除，全工作台仅底座保留 1 处「恢复原稿」。<br>3. 每段右上角具备跟读方式切换与「⋯」菜单，真实接线 `session.splitBlock(at:)`、`session.mergeBlock(at:)`、`session.insertBlock(after:)`，且单测验证拆分/合并/插入与单步撤销行为。 | 1. **确定性单测**：<br>- `TeleprompterSessionLifecycleTests.preparedBlockSplitMergeInsertAndUndoRoundTrip`（`passed after 0.576 seconds`）<br>- `TeleprompterStageSettingsTests.preparedBlockCompactHeightTokenStaysCompact`（`passed after 1.238 seconds`）<br>2. **编译修正与验证**：在 `swift-frontend -typecheck` 阶段捕获并修复了 `TeleprompterView.swift` 中 `TeleprompterBlockDisposition` 类型名与 `.speechRailButton(.secondary)` + `.controlSize(.small)` 修饰符签名问题，重跑 `swift-frontend -c` 零错误产出 `TeleprompterView.o`（退出码 `0`）。 | **确定性单测与编译已通过**（前台视觉排版未验证） |
| **AC-3** | **P1 目标时长同步与按 ID 复制回退** | 1. 修改 `targetMinutesInput` 为有效分钟数（1–180）时无需按回车即同步至 `session.targetMinutes`，且在发起 AI 整理或直接开台前强制调用 `commitTargetMinutesInputIfNeeded()`。<br>2. `session.copyableDocumentText(documentID:)` 对任意指定稿件 ID 均能返回可读文本（已生成版本返回导出稿，未生成版本回退返回该稿件 `sourceText`），绝不误拷其他稿件或返回空 nil。 | 1. **确定性单测**：`TeleprompterSessionLifecycleTests.copyableDocumentTextByDocumentIDCopiesTargetDocumentWithFallback` 实测通过（`passed after 1.238 seconds`，退出码 `0`）。<br>2. **目标码编译**：`TeleprompterSession.o` 与 `TeleprompterView.o` 编译通过（退出码 `0`）。 | **确定性单测与编译已通过**（前台剪贴板粘贴未验证） |
| **AC-4** | **P1 顶栏/首屏/视效坞渐进披露与场景预设** | 1. 即启首屏移除常驻底部的 `welcomeSafetyNotice` 大横幅，顶栏移除重复的「打开提词器」按钮，统一收敛为顶栏 `[推流与隐私 ⓘ]` Popover（`teleprompter-privacy-streaming-disclosure`）。<br>2. 工作台底部视效坞包含 `镜头口播 / 讲台阅读 / 自定义`（`TeleprompterStagePreset`）切换器与单行参数摘要，细项滑杆收纳进 `[显示设置…]` Popover（`teleprompter-workbench-stage-settings-popover`）。 | 1. **确定性单测**：`TeleprompterStageSettingsTests.displayPresetsApplyAndPersist` 与 `manualDisplayEditsSelectCustomPreset` 实测通过（套件 45 项测试全绿，退出码 `0`）。<br>2. **目标码编译**：`TeleprompterView.o` 与 `TeleprompterStageSettings.o` 经 `swift-frontend -c` 编译通过（退出码 `0`）。 | **预设模型单测与视图编译已通过**（Popover 展开视觉效果未验证） |
| **AC-5** | **P2 舞台键盘守卫与主窗副驾控场** | 1. `TeleprompterStagePresentationState` 同步控件焦点与外观 Popover 状态：当控件获焦或外观 Popover 打开时，`acceptsReadingKeyCommands` 为 `false`，`TeleprompterPanel.keyHandler` 不拦截 `Space/J/K/V/M`；当外观 Popover 打开时按 `Esc` 优先关闭 Popover 而不关闭舞台窗口。<br>2. `.ready` 视图在 `currentSegmentIndex > 0` 时提供「回到首段」按钮；舞台开启时的工作台 `workbenchRunningContent` 显示当前朗读段实时文本与「上一行 / 下一行 / 回到首段」控制。 | 1. **确定性单测**：`TeleprompterStageSettingsTests.stagePresentationStateGuardsReadingKeysAndDismissesPopoverFirst` 与 `TeleprompterStageInteractionPolicyTests` 实测通过（`passed after 1.116 seconds`，退出码 `0`）。<br>2. **目标码编译**：`TeleprompterStageWindow.o`（213KB）、`TeleprompterStageView.o`（2.2MB）、`TeleprompterView.o`（6.1MB）经 `swift-frontend -c` 编译生成通过（退出码 `0`）。 | **确定性单测与编译已通过**（前台窗口按键与焦点视觉流转未验证） |

---

## 六、实际测试/构建执行记录与未验证边界

### 6.1 真实命令、退出状态与输出摘要

1. **仓库测试目标覆盖率与提词器报告契约检查**
   - **命令**：
     ```bash
     python3 scripts/check_macos_test_target_coverage.py && python3 scripts/check_teleprompter_report.py
     ```
   - **退出状态**：`0`
   - **真实输出**：
     ```text
     macos-test-target-coverage: OK
     teleprompter report: ok
     ```

2. **仓库 `scripts/macos_app_build.sh --configuration Debug` 执行核验（受限于本机 CommandLineTools 环境）**
   - **命令**：
     ```bash
     ./scripts/macos_app_build.sh --configuration Debug
     ```
   - **真实输出与阻塞原因**：
     ```text
     macos-test-target-coverage: OK
     xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance
     ```
     同时尝试 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/macos_app_build.sh --configuration Debug` 返回 `xcrun: error: missing DEVELOPER_DIR path: /Applications/Xcode.app/Contents/Developer`（沙箱仅授权访问 `/Users/hrygo/Documents/SpeechRail` 与 `/Library/Developer/CommandLineTools`）。因此 `xcodebuild` 完整 `.app` 产物打包在当前沙箱/CommandLineTools 环境下无法直接执行，改用 CommandLineTools 下的 `swift test` 与 `swift-frontend -c` 对全部提词器模块源码与测试套件做真实编译与单测执行。

3. **提词器全量 Swift Testing 确定性单测套件（14 个测试套件、共 377 项测试）**
   - **命令**：
     ```bash
     SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test \
       --build-system native --disable-sandbox --disable-xctest --enable-swift-testing \
       --package-path /tmp/speechrail-spm \
       -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
       -Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
       -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
     ```
     *（注：因沙箱禁网且 `macos/SpeechRailApp/.build/checkouts` 为空，在 `/tmp/speechrail-spm` 下通过符号链接挂载工作区真实源码目录与离线 `OpenAI` 协议层完成编译与测试，结束后已完整清理 `/tmp/speechrail-*` 临时目录。）*
   - **退出状态**：`0`
   - **真实输出摘要**：
     ```text
     ✔ Suite TeleprompterPreparationDomainTests passed after 0.028 seconds.
     ✔ Suite TeleprompterStageInteractionPolicyTests passed after 0.028 seconds.
     ✔ Suite TeleprompterVoiceAssistLifecycleTests passed after 0.028 seconds.
     ✔ Suite TeleprompterTimingPolicyTests passed after 0.028 seconds.
     ✔ Suite TeleprompterRealtimeFollowAdapterTests passed after 0.028 seconds.
     ✔ Suite TeleprompterPreparationPromptsTests passed after 0.028 seconds.
     ✔ Suite TeleprompterReplayEvaluatorTests passed after 0.035 seconds.
     ✔ Suite TeleprompterPreparationPipelineTests passed after 0.068 seconds.
     ✔ Suite TeleprompterScriptPerformanceTests passed after 0.135 seconds.
     ✔ Suite TeleprompterV2StoreTests passed after 0.232 seconds.
     ✔ Test "returning to draft editing from ready or ended breaks the read-only deadlock and preserves active version until modified" passed after 0.345 seconds.
     ✔ Suite TeleprompterFollowControllerTests passed after 0.570 seconds.
     ✔ Test "prepared block progressive disclosure actions split, merge, insert, and undo cleanly" passed after 0.576 seconds.
     ✔ Test "stage presentation state guards reading key commands when controls or popover are active and dismisses popover first on Escape" passed after 1.116 seconds.
     ✔ Test "prepared block compact height token stays below full editor minimum height" passed after 1.238 seconds.
     ✔ Test "copyableDocumentText by documentID copies target document rather than active document and falls back to sourceText" passed after 1.238 seconds.
     ✔ Suite TeleprompterStageSettingsTests passed after 1.241 seconds.
     ✔ Suite TeleprompterAnalysisTests passed after 1.280 seconds.
     ✔ Suite TeleprompterSessionLifecycleTests passed after 1.654 seconds.
     ✔ Test run with 377 tests in 14 suites passed after 1.654 seconds.
     ```

4. **`SpeechRailApp` 提词器与设计 Token 全量视图/窗口目标码编译验证（`swift-frontend -c`）**
   - **编译期发现并修复的问题**：
     - 初次运行 `swift-frontend -frontend -typecheck` 时捕获到 `TeleprompterView.swift` 两处编译错误：`TeleprompterSegmentDisposition` 类型名应为 `TeleprompterBlockDisposition`（第 1641、1652 行），以及 `.speechRailButton(.secondary, size: .compact)` 多余 `size:` 参数（应为 `.speechRailButton(...)` 搭配 `.controlSize(.small)`，共 6 处）。
     - 修复后重新运行 `swift-frontend -frontend -c` 对 `TeleprompterView.swift`、`TeleprompterStageView.swift`、`TeleprompterStageWindow.swift`、`TeleprompterSession.swift`、`TeleprompterStageSettings.swift`、`TeleprompterTrialReadingSheet.swift`、`TeleprompterReadingAliasSheet.swift`、`SpeechRailDesignTokens.swift` 执行完整类型检查与 `.o` 目标码生成。
   - **退出状态**：`0`（`CODEGEN_EXIT=0`）
   - **真实产物校验（验证后已清理 `/tmp`）**：
     ```text
     CODEGEN_EXIT=0
     -rw-r--r--@ 1 hrygo  wheel   639K Oct 17 02:43 /tmp/speechrail-verify/SpeechRailDesignTokens.o
     -rw-r--r--@ 1 hrygo  wheel   519K Oct 17 02:43 /tmp/speechrail-verify/TeleprompterReadingAliasSheet.o
     -rw-r--r--@ 1 hrygo  wheel   1.2M Oct 17 02:43 /tmp/speechrail-verify/TeleprompterSession.o
     -rw-r--r--@ 1 hrygo  wheel   220K Oct 17 02:43 /tmp/speechrail-verify/TeleprompterStageSettings.o
     -rw-r--r--@ 1 hrygo  wheel   2.2M Oct 17 02:43 /tmp/speechrail-verify/TeleprompterStageView.o
     -rw-r--r--@ 1 hrygo  wheel   213K Oct 17 02:43 /tmp/speechrail-verify/TeleprompterStageWindow.o
     -rw-r--r--@ 1 hrygo  wheel   693K Oct 17 02:43 /tmp/speechrail-verify/TeleprompterTrialReadingSheet.o
     -rw-r--r--@ 1 hrygo  wheel   6.1M Oct 17 02:43 /tmp/speechrail-verify/TeleprompterView.o
     ```

### 6.2 仍未验证项与风险边界（如实声明）
1. **完整 Xcode `.app` 签名打包（未验证）**：由于当前环境 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools` 且 `/Applications/Xcode.app` 位于连接目录沙箱之外，`./scripts/macos_app_build.sh --configuration Debug` 在调用 `xcodebuild` 时报错退出。用户在本机完整 Xcode 环境下可运行 `./scripts/macos_app_build.sh --configuration Debug --test-unit` 完成 `.app` 产物构建。
2. **前台 UI 自动化与窗口焦点实机交互（未验证）**：遵循指令红线，未运行 XCUITest、Playwright、录屏或点击驱动测试；舞台 Popover 的实际鼠标点击、焦点环切换与窗口拖拽未做前台自动化验证。
3. **真实视觉观感与 Reduce Motion 动画肉眼核验（未验证）**：玻璃材质透光度、外接显示器分光镜物理反射效果及系统「减弱动态效果」下的过渡观感待真机目视确认。
4. **VoiceOver 实机播报与真麦克风实时跟读（未验证）**：无障碍标识符与标签已编译入视图，但未在开启系统 VoiceOver 语音播报或真实麦克风 + 实时 ASR 服务端流下做真机演练。
