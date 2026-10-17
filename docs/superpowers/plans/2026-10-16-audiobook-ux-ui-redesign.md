---
title: "有声书工坊（Audiobook Studio）竞品深度调研与 UX/UI 重构方案"
status: active
audience: "macOS 客户端开发者、产品设计师、QA 验收工程师"
version: "1.0.0"
date: 2026-10-16
---

# 有声书工坊（Audiobook Studio）竞品深度调研与 UX/UI 重构方案

本文档基于对全球及国内头部 AI 有声书与多角色配音工作台的深度调研，结合 `SpeechRail` 现有源码诊断，制定「有声书工坊（`AppRoute.audiobook`）」的完整 UX/UI 与选角状态机重构方案及量化验收标准（Acceptance Criteria）。

## 1. 最佳竞品深度调研与设计范式提炼

针对长篇小说/文集的「TXT 导入拆章 → 大模型说话人识别 → 多角色选角配声 → 逐章合成精修 → 沉浸收听导出」全链路，选取三款行业标杆产品作为核心对标：

| 标杆产品 | 核心优势领域 | 关键 UX/UI 机制拆解 | 对 SpeechRail 的重构启示 |
| :--- | :--- | :--- | :--- |
| **ElevenLabs Audiobooks & Studio** | 长篇有声书文档流画布与上下文联动 | 1. **Document-First 极简正文流**：段落不套独立卡片黑框，仅用段落左侧 3pt 垂直色条表达状态（浅灰=未生成，深色/彩色=已生成）。<br>2. **Character Casting 真实台词试听**：自动识别角色并推断声线特征，卡片内直接试听角色在书中的真实对白，切换音色即刻生效。<br>3. **底部常驻播放控制栏**：在编辑器内直接支持单段试听与整章顺播，无需频繁跨页切换。 | 移除中栏每段一个 `CardSurface` 的表单感；旁白段落隐藏重复标签头；将沉浸播放栏嵌入工作台底部。 |
| **Descript Script Editor** | 多角色剧本标签与极速键盘归属 | 1. **合并连续同说话人标签**：连续多段旁白或同一角色发言只展示一次角色头，视觉呼吸感极佳。<br>2. **悬停显露与快捷键指派**：默认隐藏字数、复选框等工程元数据，仅在悬停或选中时浮现操作项；支持数字键/快捷键秒级改派说话人。 | 合并连续相同说话人头部；为「待确认说话人」候选按钮绑定键盘数字键 `1~5` 一键确认并自动跳至下一处。 |
| **喜马拉雅「音剪 AI」 & Narratory** | 中文多播小说「主役+群像池」分层选角 | 1. **6–8 声线认知法则**：听众在一本书中最多清晰分辨 6–8 个独立音色；仅为核心主角分配独占音色，其余配角与龙套自动归入 6 类群像声线池（青年男/女、中年男/女、老年、特色群像）。<br>2. **零台词提及人物静默过滤**：仅在旁白或对话中被提及姓名、无实际直接对白的人物不进入配声列表。 | 修复 121 个角色全部标为「核心主角」的 Bug；默认隐藏 0 句台词人物；默认打开「本章出场」视图；一键智能配声自动启用配角群像共享，彻底消除黄色报错死锁。 |

## 2. 现有实现症结与源码根因定位

1. **根因一：「核心 121 · 配角 0」角色爆炸与配声死锁（`AudiobookCastRegistry.swift` & `AudiobookWorkflowModel.swift`）**
   - `AudiobookCastRegistry.applyMergeBatch`（第 308 行）在创建新提取角色时硬编码了 `isMajor: chapterIDSet.count >= 1, allowSharedMinorVoice: false`，导致全书提取出的所有角色（如《彷徨》中的 120 个角色）全部被标记为 `isMajor = true` 且禁止共享音色（`sharingPolicy = .exclusive`）。
   - `AudiobookCastRegistry.refreshCharacterMajorStatusAndOrder`（第 493 行）在全书分析结束时仅调用了纯统计函数 `computeRoleDialogueStats(...).updatedCharacters`，未将帕累托分层结果（`stat.tier`）同步回角色的 `isMajor` 与 `allowSharedMinorVoice`。
   - 后果：右栏顶部统计显示 `核心 121 · 配角 0`；在「核心主角」Tab 下出现 `何万淑贞（0 句 · 群像）`、`中途辭職...（1 句 · 群像）` 等大量龙套；且 `makeCastingPlan` 因 121 个角色全部要求 `.exclusive` 独占音色而触发 `.insufficientVoiceCapacity` 阻塞报错（`当前候选不能同时满足旁白、独占与共享要求，请增加声音或明确调整角色政策`），导致「应用配声方案」按钮永久置灰死锁。

2. **根因二：顶栏双层导航冲突与左栏重复胶囊噪音（`AudiobookWorkshopView.swift` & `AudiobookBookWorkspaceView.swift`）**
   - 进入单书工作台后，顶栏仍常驻属于书架层级的 `导入 TXT…` 和 `废纸篓 (4)` 按钮。
   - 次顶栏常驻一整行技术披露文字 `AI 分析服务：gpt-6-luna (http://127.0.0.1:8317/v1) · 仅点击「分析全书」时按窗口发送正文...`，挤压纵向画布。
   - 左栏「整理章节」下方常驻两行灰字说明 `全书分析开始后不能拆分或合并章节...`；每章下方重复渲染 8 个 `待确认配声` 胶囊；左栏底部 `快速定位下一处待确认` 按钮与中栏顶部导航条完全重复。

3. **根因三：中栏「卡片海」视觉过载与多处按钮 `...` 截断（`AudiobookBookWorkspaceView.swift` & `AudiobookSourceIndex.swift`）**
   - `atomRowView` 将每一段旁白都包裹在带框卡片中，每段固定渲染 `[☐]`、`[旁白 · 未配声]`、`[49 字]`、`[改派说话人 ⌄]`，单章 266 段产生超过 1000 个重复 UI 元素。
   - `batchSpeakerAssignmentBar` 硬塞 4 个 `归属给「\(role.displayName)」` 按钮，全部截断为 `[归属给「...]`。
   - 待确认说话人橘色卡片中的候选按钮塞在单行 `HStack` 中，被截断为 `[✨ 三...]` `[✨ ...]`。
   - `unknownSpeakerNavigatorBar` 右侧的 `[AI 二次复核未确认台词]` 被截断为 `[✨ AI 二...]`。
   - 原文编码转换残留的 Unicode 替换字符 `\u{FFFD}` 在正文中直接显示为 `[?]`（如 `彷彿還留 [?] 一種`）。

4. **根因四：右栏双重冗余徽标与繁琐的二次方案确认流（`AudiobookBookWorkspaceView.swift`）**
   - `characterCard` 同时渲染 `tier.badgeTitle`（`ⓘ 群像`）与 `archetype.shortBadgeTitle`（`ⓘ 特色群像`），形成 `ⓘ 群像 ⓘ 特色群像` 的重复标签。
   - 点击「一键智能配声」后，由于配角共享声线触发 `sharedVoiceConsentRequired` / `sharedSceneRisk`，系统不自动完成绑定，而是在右栏底部弹出冗长的 `AudiobookCastingReview` 面板要求用户逐项勾选确认再点「应用配声方案」。

## 3. 详细重构设计方案

### 3.1 阶段一（Step 1）：角色智能分层、静默角色过滤与零死锁配声

1. **修复提取与全书分析后的角色主次标记（`AudiobookCastRegistry.swift`）**：
   - 在 `applyMergeBatch` 中，新提取的非旁白角色默认初始化为 `isMajor: false, allowSharedMinorVoice: true`（在未完成全书对白统计前默认作为可共享配角，避免单句龙套抢占独占名额）。
   - 在 `computeRoleDialogueStats` 中，保持纯函数契约（不修改传入 `characters` 的 `isMajor` 与 `allowSharedMinorVoice`，确保既有单元测试 100% 兼容），同时将自动 `.lead`（核心主角）数量上限收敛为 `max(1, min(8, availableVoiceCount > 0 ? max(3, availableVoiceCount - 2) : 6))`，且当全书发声角色超过 6 人时，仅对白量充足的角色可评为 `.lead`，杜绝 1 句台词龙套进入核心主角。
   - 在 `refreshCharacterMajorStatusAndOrder` 中，利用 `computeRoleDialogueStats` 算出的 `statsByRoleID`，对未设置人工锁定政策（`role.manualTier == nil && role.voicePolicy == nil`）的角色同步更新：
     - `isMajor = role.isNarrator || statsByRoleID[role.id]?.tier == .lead`
     - `allowSharedMinorVoice = !isMajor`
     - 按「旁白置顶 $\rightarrow$ 核心主角 $\rightarrow$ 配角 $\rightarrow$ 群像」及对白字数降序排列。

2. **存量书籍自动自愈与视图层角色投影（`AudiobookWorkflowModel.swift`）**：
   - 新增 `resolvedRoleTier(for:)`、活跃发声角色集合 `activeSpeakingCharacters`（分析完成后默认剔除 `dialogueAtomCount == 0 && !isNarrator` 的零台词提及人物）以及准确的 `leadCharacterCount` / `minorCharacterCount`。
   - 当打开存量已分析书籍或执行配声时，若检测到存量数据存在“非旁白角色超过 6 人且 100% 处于 `isMajor == true && allowSharedMinorVoice == false && voicePolicy == nil`”的历史 Bug 特征，自动调用 `refreshCharacterMajorStatusAndOrder` 修复主次分层并写回存储，无需用户重新跑 LLM 分析即可解除配声死锁。
   - 将 `castFilterScope` 默认值设为 `.inCurrentChapter`（本章出场），并在 `CastFilterScope.allCases` 中按 `本章出场 -> 核心主角 -> 配角群像 -> 全部` 排序，让用户首屏只面对当前章节的少量出场角色。
   - 优化 `autoAssignRecommendedVoices`：当用户主动点击「一键智能配声」且生成的方案 `plan.isApplicable == true` 时，自动确认配角声线共享提议并直接应用方案落库，一步到位完成全书配声。

### 3.2 阶段二（Step 2）：顶栏与左栏去噪瘦身

1. **顶栏全局动作按模式隔离（`AudiobookWorkshopView.swift`）**：
   - 仅当 `workflow.surfaceMode == .shelf`（或未选中书籍）时显示 `导入 TXT…` 与 `废纸篓` 按钮；进入单书工作台或听书模式后，顶栏仅保留 `[返回书架]`、`[三栏工作台 | 听书模式]` 与 `[导出…]`。
2. **次顶栏 AI 服务技术披露收起为 Popover（`AudiobookBookWorkspaceView.swift`）**：
   - 移除 `topStatusAndPrimaryActionBar` 中常驻占满一行的 `aiProviderDisclosureLine` 长文本，改为紧贴状态胶囊右侧的轻量 `[AI 与隐私 ⓘ]` 按钮（点击弹出 Popover 展示服务地址、模型与发送规则）；仅当 AI 服务未配置时才内联显示黄色配置提醒。
3. **左栏章节列表极简化（`AudiobookBookWorkspaceView.swift`）**：
   - 隐藏分析完成后常驻在「整理章节」下方的两行禁用说明文字（保留在菜单项的 `.help` 提示中）。
   - 章节行状态胶囊去噪：当全书尚未确认配声时，不再在全部章节重复渲染 8 个灰色的 `待确认配声` 胶囊；仅突出显示 `待确认 N`（存在未确认说话人）、`制作中`、`已成片`、`需更新` 等高价值状态。
   - 移除左栏底部与中栏重复的 `快速定位下一处待确认` 按钮。

### 3.3 阶段三（Step 3）：中栏升级为 Document-First 连续剧本流 + 消除截断与乱码

1. **原文乱码替换符 `\u{FFFD}` 净化（`AudiobookSourceIndex.swift`）**：
   - 在 `AudiobookSourceIndex.normalizedText(in:)` 阅读投影层剔除编码残留的 `\u{FFFD}` 替换符（不改动底层 `source.txt` 原始字节与 `[startByte, endByte)` 偏移），消除正文中的 `[?]` 乱码框。
2. **中栏连续剧本流（`AudiobookBookWorkspaceView.swift`）**：
   - **旁白与普通段落去卡片化**：移除每段包裹的重边框卡片，改为**左侧 3pt 垂直状态色条 + 极简正文排版**（旁白为中性灰条，角色对白为醒目的角色声学色条）。
   - **连续同说话人头部折叠**：当连续多个段落均为「旁白」或同一角色时，不重复渲染顶部角色胶囊；仅在说话人切换处、角色对白段或鼠标悬停/选中时展示角色标签与操作项。
   - **行内一键试听本段**：在段落操作区提供 `[▶ 试听]` 按钮，支持在「准备与角色」阶段直接用当前角色绑定的音色试听该段原文。
3. **彻底消除三处按钮 `...` 截断（`AudiobookBookWorkspaceView.swift`）**：
   - **待确认定位栏（`unknownSpeakerNavigatorBar`）**：精简文案为 `待确认 X/Y（本章 Z）`，右侧按钮固定为不截断的 `[AI 智能复核]`。
   - **待确认内联卡（Unknown Speaker Card）**：候选角色按钮采用自适应多行流式排布，展示完整角色名称并附带数字快捷键标签（如 `[1] 三角脸`、`[2] 方头`、`[3] 旁白`），支持按下键盘数字键 `1~5` 一键确认并自动跳至下一处。
   - **多选批量归属栏（`batchSpeakerAssignmentBar`）**：替换为最多 3 个本章高频角色完整名按钮 + `[旁白]` + `[更多角色… ⌄]` 下拉菜单，彻底消除 4 个 `[归属给「...]` 截断。

### 3.4 阶段四（Step 4）：右栏角色卡精简与工作台底部常驻播放栏

1. **右栏角色卡片去冗余（`AudiobookBookWorkspaceView.swift`）**：
   - 合并重复的 `tier` 与 `archetype` 胶囊（不再同时显示 `ⓘ 群像` + `ⓘ 特色群像`），主角显示 `主角 · 青年男声`，配角/群像仅显示具体声部行当（如 `青年男声`、`中年女声`、`特色群像`）。
   - 底部存在零台词仅提及人物时，以轻量折叠提示 `已自动隐藏 N 个零台词提及人物` 告知用户，支持按需展开查看。
2. **底部常驻迷你播放与审听栏（`AudiobookBookWorkspaceView.swift`）**：
   - 当所选章节已有可收听音频版本或正在播放时，在工作台底部直接挂载紧凑的常驻播放控制条（支持播放/暂停、±15 秒快进快退、倍速切换与实时朗读进度展示），实现“边看剧本、边听成片、随时返修”的无缝闭环。

### 3.5 阶段五（Step 5，2026-10-17 深化）：制作页三栏 vs 响应式两栏/上下文检查器深度对比与布局演进

#### 3.5.1 近期官方竞品长篇/多角色制作流程与布局核查（核实日期：2026-10-17）

| 竞品与规范来源 | 真实长篇/多角色布局与流程事实（【来源事实】） | 官方来源链接与日期 |
| :--- | :--- | :--- |
| **ElevenLabs Audiobooks & ElevenCreative Studio 4.0** | 1. **章节侧栏（Chapters Sidebar）+ 中央连续文稿画布 + 上下文右侧栏（Contextual Sidebar）**：Audio project 通过左侧 `Chapters` 标签管理章节（新建、重命名、拖拽排序），中央画布采用段落左侧状态条（浅灰=未转换，深色=已生成）的连续文稿流，右侧 `Contextual sidebar` 随当前选中对象动态切换（配音、模型、生成历史、Character Casting），支持按需展开或收起，而非在所有阶段死锁固定宽度。<br>2. **底部常驻播放与顺播生成栏（Bottom Player）**：底部播放器统一承载 `Selection`（单段）与 `Until end`（顺播生成）控制。 | [Audiobooks \| ElevenLabs Documentation](https://elevenlabs.io/docs/eleven-creative/products/audiobooks)、[ElevenCreative Studio overview \| ElevenLabs Documentation](https://elevenlabs.io/docs/eleven-creative/products/studio)（官方文档，2026-09-22 / 2026-10-17 核实） |
| **Descript Script Editor (Markers & Speakers)** | 1. **主剧本流绝对优先 + 按需展开章节/属性抽屉**：章节（Markers `#`）既作为内联段落标题存在于剧本流中，也可通过播放控制旁的紧凑 Marker 列表跳转；说话人（Speaker labels `@`）在连续发言时合并展示，右侧属性检查器可随时折叠以最大化剧本阅读与波形审听空间。 | [Markers and chapters - Descript Help Center](https://help.descript.com/script-editing/markers-chapters)、[Speaker labels - Descript Help Center](https://help.descript.com/script-editing/speaker-labels)（官方帮助中心，2026-10-17 核实） |
| **Apple macOS Human Interface Guidelines — Split Views & Layout** | 1. **保护主内容最小可读宽度（Primary Content Protection）**：macOS 分栏视图应优先保障主内容区宽度（SpeechRail 契约为 `minimumPrimaryContentWidth = 500pt`），当窗口收窄或进入专注阶段时，次级导航栏（`sidebar.left`）与右侧检查器（`sidebar.right`）应支持双向独立折叠或响应式转浮层，且严禁将导航标签命名为固定几何形态（如「三栏工作台」）。 | [Split views \| Apple Developer Documentation](https://developer.apple.com/design/human-interface-guidelines/split-views)、[Layout \| Apple Developer Documentation](https://developer.apple.com/design/human-interface-guidelines/layout)（2026-09-09 更新，2026-10-17 核实） |

#### 3.5.2 结合 SpeechRail 窗口宽度预算与四阶段流程的三方案对比

在 `SpeechRail` 中，窗口最小宽度为 `800pt`，常见笔记本窗口宽度为 `1120–1440pt`。扣除全局左侧主导航栏（展开时 `240pt`）与页面两侧边距（`2 × 20pt = 40pt`）后，有声书工作台可用宽度通常在 `840pt ~ 1160pt` 之间。若左栏章节列表（`240pt` + 间距 `16pt` = `256pt`）与右栏人物检查器（`360pt` + 间距 `16pt` = `376pt`）同时固定常驻，两侧共吞噬 **`632pt`**，在 `1120pt` 工作区宽度下中央主画布仅剩 **`488pt`**。

| 评估维度 | 方案 A：固定三栏 + 仅左栏可收起（旧实现） | 方案 B：纯两栏（左章 + 中主区）+ 弹窗选角 | **方案 C（推荐并采用）：阶段感知 + 宽度自适应的「主画布优先 + 双向可折叠侧栏/上下文检查器」混合架构** |
| :--- | :--- | :--- | :--- |
| **布局结构** | 左（章节 `240pt` 可收起）+ 中（主画布）+ 右（人物与声音 `360pt`，宽屏 `≥1120pt` 强制常驻且不可收起，窄屏转 Popover） | 左（章节 `240pt`）+ 中（主画布）；彻底取消右侧内联栏，所有角色与配声操作放进模态 Sheet 或 Popover | 左（章节导航 `240pt`，`sidebar.left` 可收起）+ 中（共享主画布，保底 `≥500pt`）+ 右（人物与声音上下文检查器 `360pt`，支持 `sidebar.right` 手动收展 + 阶段感知自动收展 + 宽度不足时自动转 Popover） |
| **宽度预算与左栏联动** | 即使用户收起了左栏章节目录（释放 `256pt`），在 `900~1119pt` 窗口下右栏依然被迫缩成 Popover；而在 `≥1120pt` 下用户又无法收起右栏 | 宽屏（`≥1200pt`）下中央主画布受限于 `820pt` 阅读行宽上限，右侧留下大片空白，且选角期需频繁开关弹窗 | 1. 左栏展开时内联右栏阈值为 `1120pt`；**左栏收起后内联右栏阈值智能降至 `880pt`**（`500pt` 主区 + `16pt` 间距 + `360pt` 右栏），让中等窗口也能并排对校「原文 + 人物配声」；<br>2. 任何宽度下均可点击 `sidebar.right` 收起右栏。 |
| **跨阶段任务流匹配（「准备与角色」vs「制作与返修」）** | 切换到「制作与返修」后，角色配声已锁定，但右侧 `360pt` 人物列表仍常驻占屏，挤压音频片段与候选重录对比空间；且音频片段仍套重型 `CardSurface` | 在「准备与角色」阶段核对全书角色、排查同场撞音与试听真实台词时，弹窗遮挡正文上下文 | 遵循**“自动准备、关键处确认”**：<br>1. **准备与角色阶段**：宽屏默认展开右侧人物检查器，边读原文边试听配声；<br>2. **制作与返修阶段**：当全书无待确认说话人且配声已确认时，**自动收起右侧人物检查器**（聚焦「章节导航 + 音频片段流」两栏布局），同时保留顶栏按钮随时一键展开或微调角色音色；音频片段同步升级为左侧 3pt 状态色条流。 |
| **状态可恢复性与术语一致性** | 顶栏硬编码 `三栏工作台`，窄屏或收起侧栏时名实不符 | 关闭选角弹窗易丢失筛选上下文 | 顶栏正名为 **「制作工作台」**；自动或手动收展侧栏/检查器完整保留 `castFilterScope`、`expandedRoleIDs`、当前选中章节与制作进度。 |

**决策结论**：放弃“预设必须固定保留三栏”的静态思维，实施 **方案 C（阶段感知 + 宽度自适应的「主画布优先 + 双向可折叠侧栏/上下文检查器」混合架构）**。

---

### 3.6 有声书全流程 UI 文案审查与优化清单（2026-10-17 专项）

#### 3.6.1 平台与行业官方 UX 文案原则（核实日期：2026-10-17）

| 规范与竞品来源 | 核心文案与交互标签准则（【来源事实】） | 官方来源链接与日期 |
| :--- | :--- | :--- |
| **Apple Human Interface Guidelines — Writing, Buttons & Menus** | 1. **动词+宾语说清动作或结果**：按钮与菜单项应使用简短、直接的动宾结构说明点击后发生的动作或结果，避免使用模糊的“确定（OK）”“处理（Process）”“完成（Done，非编辑态时）”。<br>2. **省略号（`…`）精确表意**：仅当点击后会打开新窗口/弹窗要求用户进一步输入确认时追加 `…`；立即执行的动作不加 `…`。<br>3. **同义动作全局一致**：同一目标动作在卡片主按钮、更多菜单、顶栏与空状态中必须使用相同动词词组，避免混用近义词造成认知分裂。<br>4. **破坏性操作显式声明后果与可逆范围**：破坏性按钮（`.destructive`）必须写明具体动作（如“永久删除” vs “移入废纸篓”）及影响边界。 | [Writing \| Apple Developer Documentation](https://developer.apple.com/design/human-interface-guidelines/writing)、[Buttons \| Apple Developer Documentation](https://developer.apple.com/design/human-interface-guidelines/buttons)（2025-12-16 更新，2026-10-17 核实）、[Menus \| Apple Developer Documentation](https://developer.apple.com/design/human-interface-guidelines/menus)（2026-10-17 核实） |
| **Apple Human Interface Guidelines — Accessibility** | 1. **纯图标控件必须具备动态无障碍名称（`.accessibilityLabel`）**：所有仅显示 SF Symbols 图标的按钮（如侧边栏折叠、播放/暂停、试听/停止、展开/收起、星标收藏）必须提供随状态更新的 `.accessibilityLabel`，不能仅依赖鼠标悬停 `.help`。<br>2. **避免向普通用户暴露底层工程单位**：采样帧、字节偏置、内部数据结构名（如 `TextAtom` / `FragmentPlan` / `Generation`）不应直接出现在面向创作者的主界面文案中。 | [Accessibility \| Apple Developer Documentation](https://developer.apple.com/design/human-interface-guidelines/accessibility)（2025-06-09 更新，2026-10-17 核实） |
| **ElevenLabs Audiobooks & Studio / Descript Script Editor** | 1. **创作者心智词典**：长篇有声书与多角色配音工具面向创作者统一使用「章节（Chapters）」「段落（Paragraphs/Segments）」「说话人/角色（Speakers/Characters）」「生成/重录（Generate/Regenerate）」「第 N 版（Version/Take）」等直观创作词汇，不暴露底层切分块或音频采样帧计数。 | [Audiobooks \| ElevenLabs Documentation](https://elevenlabs.io/docs/eleven-creative/products/audiobooks)、[Speakers - Descript Help Center](https://help.descript.com/script-editing/speakers)（2026-10-14 更新，2026-10-17 核实） |

#### 3.6.2 按全制作流程的完整 UI 文案审查清单（导入 → 分析 → 选角 → 章节制作 → 审听/导出）

| 流程阶段 | 出现位置（文件与行号） | 用户此刻要完成的事 | 现文 | 理解/歧义/术语/截断/无障碍问题 | 建议文案与理由 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **全局/提示栏** | `AudiobookWorkshopView.swift:35, 38` | 查看操作报错并关闭错误横幅 | 标题：`需要处理`<br>按钮：`关闭提示` | `需要处理` 含糊且像系统后台工单术语；按钮 `关闭提示` 冗长 | 标题改为 **`操作未完成`**，按钮改为 **`知道了`**，直接说明当前动作未生效并简洁收起 |
| **全局/导航栏** | `AudiobookWorkshopView.swift:124-126` | 悬停顶栏视图切换器了解何时可进入工作台/听书 | `.help("先从书架选择一本书，再进入工作台或听书界面。")` | 与切换器标签 `制作工作台` / `听书` 呼应，但可更简练 | 改为 **`请先在书架选择一本书`**，简短直接 |
| **1. 书架与导入** | `AudiobookBookShelfView.swift:115, 123` | 从书籍卡片或卡片右上角 `⋯` 菜单打开该书制作页 | 主按钮：`打开工作台`<br>`⋯` 菜单：`进入工作台` | 同一卡片内相同动作使用了 `打开工作台` 与 `进入工作台` 两种词，违反一致性原则 | 统一为 **`打开工作台`**；同时为 `⋯` 菜单补充 `.accessibilityLabel("更多书籍操作")` 与 `.help("更多操作")` |
| **1. 书架与导入** | `AudiobookBookShelfView.swift:127, 134, 143` | 从书籍卡片 `⋯` 菜单收听、导出或移入废纸篓 | `开始听书` / `导出…` / `移入废纸篓` | `导出…` 与工作台顶栏 `导出有声书…` 不一致；`移入废纸篓` 缺少悬停说明可恢复性 | 改为 **`开始听书`** / **`导出有声书…`** / **`移入废纸篓`**（附 `.help("移入废纸篓后仍可随时恢复")`） |
| **1. 书架与导入** | `AudiobookBookShelfView.swift:175` | 在书架卡片查看上次听书进度书签 | `上次听到片段偏置 \(Int(bookmark.fragmentOffsetSeconds))s · ...` | **严重内部术语泄露**：`片段偏置`（fragment offset）是底层数据结构字段名，普通用户完全无法理解 | 改为 **`上次听到本段第 \(Int(bookmark.fragmentOffsetSeconds)) 秒 · \(String(format: "%.2gx", bookmark.playbackRate))`**，自然易懂 |
| **1. 书架与导入** | `AudiobookBookShelfView.swift:198, 232, 241` | 在书架卡片查看书籍分析、制作与可听状态胶囊 | `分析：需处理` / `制作：需处理` / `可听：之前的版本` | `需处理` 过于模糊，未指明是失败需重试；`之前的版本` 口语拖沓且窄卡片易占宽 | 改为 **`分析：需重试`** / **`制作：需重试`** / **`可听：旧版音频`**，状态与工作台胶囊严格对齐 |
| **1. 书架与导入** | `AudiobookWorkshopView.swift:267` | 导入 TXT 预览弹窗中确认导入并开始建书 | 勾选：`导入后立即在后台启动全书角色与说话人分析` | 文案偏长且强调“在后台启动”内部机制 | 改为 **`导入后立即开始全书分析`**，简明扼要 |
| **1. 书架与导入** | `AudiobookWorkshopView.swift:331` | 查看完废纸篓弹窗后关闭弹窗 | 按钮：`完成` | 在非表单编辑的纯列表查看弹窗中，使用 `完成` 语义含糊 | 改为 **`关闭`**，符合 macOS HIG 浏览型 Sheet 关闭规范 |
| **2. 全书分析与目录** | `AudiobookBookWorkspaceView.swift:256-267` | 点击工作台左上角图标收起/展开章节目录栏 | 仅有 `.help(...)`，无 `.accessibilityLabel` | **无障碍缺失**：纯图标按钮 `sidebar.left` 缺少动态 `.accessibilityLabel`，VoiceOver 仅读出系统符号名 | 补齐 `.accessibilityLabel(isChapterSidebarCollapsed ? "展开章节目录" : "收起章节目录")` |
| **2. 全书分析与目录** | `AudiobookBookWorkspaceView.swift:318-334` | 点击工作台右上角按钮收起/展开右侧人物与声音栏 | 仅有 `Label` 与 `.help(...)` | 补齐动态 `.accessibilityValue(showInlineCast || workflow.isCastInspectorPresented ? "已展开" : "已收起")`，便于读屏感知面板状态 | 补充 `.accessibilityValue(showInlineCast || workflow.isCastInspectorPresented ? "已展开" : "已收起")` |
| **2. 全书分析与目录** | `AudiobookBookWorkspaceView.swift:554` | 在左侧章节列表查看修改配声后仍有旧版音频的章节 | `之前的版本可听` | 7 字副文案在 `240pt` 窄侧栏中与 `待更新`、`待确认 N` 并排时极易挤压截断 | 精简为 **`旧版可听`**（4 字），与书架和听书页统一且零截断 |
| **2. 全书分析与目录** | `AudiobookWorkflowModel.swift:2431, 2472` | 拆分或合并章节后查看顶部反馈横幅 | `目录已拆分，规范化原文保持不变。请重新分析角色后继续制作。` | **内部术语泄露**：`规范化原文`（normalized text）属于内部索引实现概念 | 改为 **`章节已拆分，原文内容保持不变。请重新分析全书后继续制作。`** / **`章节已合并，原文内容保持不变。请重新分析全书后继续制作。`** |
| **3. 校对与选角** | `AudiobookBookWorkspaceView.swift:850, 961, 973, 994` | 在正文段落中批量或单段指定说话人 | 批量栏：`归属「X」`<br>单段菜单：`改派说话人` → `指派给：X` | 同一动作混用了 `归属`、`改派`、`指派给` 三种动词，且 `归属` 偏学术/内部化 | 批量栏改为 **`设为「\(role.displayName)」`**；单段菜单按钮改为 **`更换说话人`**，菜单项改为 **`设为：\(role.displayName)`**，底部撤销改为 **`撤销上次说话人修改`**，全链路动词统一 |
| **3. 校对与选角** | `AudiobookBookWorkspaceView.swift:1018` | 在待确认说话人卡片点击候选角色芯片 | `一键确认并跳至下一处：` | 提示词偏长 | 精简为 **`选择说话人（按数字键 1–5 快速确认并跳至下一处）：`**，直接教会用户键盘快捷键！ |
| **3. 校对与选角** | `AudiobookBookWorkspaceView.swift:1440, 1623-1624` | 切换是否显示全书 0 句对白的角色 | 栏头：`已折叠 N 个无对白人物` / `隐藏 N 个无对白人物`<br>菜单：`显示/隐藏 0 句无对白人物（N）` | `0 句无对白人物` 语义重复（0 句 = 无对白），且栏头静态状态描述不如动作清晰 | 栏头按钮改为 **`显示 \(silentCount) 个无对白角色`** / **`隐藏 \(silentCount) 个无对白角色`**；菜单项统一为 **`显示无对白角色（\(workflow.silentCharacterCount)）`** / **`隐藏无对白角色（\(workflow.silentCharacterCount)）`** |
| **3. 校对与选角** | `AudiobookBookWorkspaceView.swift:1555` | 点击右侧人物栏底部主按钮一键分配全书角色音色 | `智能配声（配角可共享）` | 按钮内塞入括号说明导致按钮长达 11 字，在 `360pt` 检查器底部与左侧 `更多整理…` 并排时显得拥挤，且说明已在 `.help` 中给出 | 按钮精简为 **`一键智能配声`**（6 字，零截断），`.help` 明確说明 **`为主角分配专属音色，配角按声部共享音色；若存在同场撞音将提示确认`** |
| **3. 校对与选角** | `AudiobookWorkshopView.swift:391` | 在「合并或拆分角色」弹窗中选择要拆出的段落范围 | `当前已选中 \(workflow.selectedAtomIDs.count) 个正文切分块` | **严重内部术语泄露**：`正文切分块`（TextAtom）是内部解析器术语，用户只知道“正文段落” | 改为 **`当前已选中 \(workflow.selectedAtomIDs.count) 段正文（在主工作区勾选段落后可拆出为独立角色）`** |
| **3. 校对与选角** | `AudiobookWorkshopView.swift:415` | 关闭「合并或拆分角色」弹窗 | `完成` | 与废纸篓弹窗同理，该弹窗中「合并角色」与「拆出新角色」已是即时生效按钮，底部退出按钮用 `关闭` 更准确 | 改为 **`关闭`** |
| **4. 章节制作与返修** | `AudiobookBookWorkspaceView.swift:1120-1123` | 切换到尚未生成音频的章节「制作与返修」页查看空状态 | 标题：`当前章节尚未生成片段规划`<br>按钮：`制作本章` | **严重内部术语泄露**：`片段规划`（Fragment Plan）是合成管线内部概念，用户关心的是“本章尚未生成音频” | 标题改为 **`本章尚未生成音频`**，说明改为 **`请先完成全书分析并确认角色配声，即可生成本章音频。`**，按钮改为 **`生成本章音频`** |
| **4. 章节制作与返修** | `AudiobookBookWorkspaceView.swift:1095, 1181` | 查看章节增量复用提示与底部制作按钮 | 胶囊：`待生成/更新 N 段`<br>按钮：`制作/更新本章` | 带斜杠的复合词 `制作/更新本章` 显得机械生硬；可根据本章是否已有成片版本动态显示精确动词 | 胶囊改为 **`待合成 \(plan.redoFragmentIDs.count) 段`**；底部按钮按当前章节是否已有 `currentChapterRevisionID` 动态显示 **`更新本章音频`** 或 **`生成本章音频`** |
| **4. 章节制作与返修** | `AudiobookBookWorkspaceView.swift:1249` | 查看配声变更后待重新合成的音频片段状态胶囊 | `待更新（保留之前版本）` | 11 字胶囊在片段头部窄行中冗长 | 精简为 **`待更新 · 旧版可听`** |
| **4. 章节制作与返修** | `AudiobookBookWorkspaceView.swift:1295-1315` | 展开单段音频的多次重录历史候选进行试听对比与采用 | `候选版本对比与采用（共 N 条）`<br>`代次 #\(candidate.generation)`<br>`%.2f 秒（%lld 帧）`<br>`匹配当前设定` / `之前的版本`<br>`采用此候选` | **严重内部术语与底层参数泄露**：`代次 #1`（generation）和 `（240000 帧）`（48kHz PCM frameCount）是底层数据库与音频帧校验字段，普通创作者完全不需要看采样帧数！ | 折叠标题改为 **`历史重录版本（共 \(candidates.count) 版）`**；版本名改为 **`第 \(candidate.generation) 版`**；时长仅显示 **`String(format: "%.1f 秒", candidate.durationSeconds)`**（移除 `%lld 帧`）；状态胶囊改为 **`当前设定`** / **`旧版设定`**；按钮改为 **`设为当前版本`**；试听按钮补充 `.accessibilityLabel("试听第 \(candidate.generation) 版")` |
| **5. 审听与导出** | `AudiobookBookWorkspaceView.swift:466-485` | 在工作台底部迷你播放栏播放/暂停或快进快退 | 播放按钮仅有 `Image(systemName:)` 与 `.help`，无 `.accessibilityLabel` | **无障碍缺失**：VoiceOver 焦点落到工作台底部播放键时无法读出“播放本章/暂停播放” | 补齐 `.accessibilityLabel(controller.isPlaying ? "暂停播放" : "播放本章")`，并为 `−15 秒` / `+15 秒` 补充 `.accessibilityLabel("后退 15 秒")` / `.accessibilityLabel("前进 15 秒")` |
| **5. 审听与导出** | `AudiobookListeningView.swift:69, 97` | 在听书视图查看章节与顶部横幅的旧版音频标识 | `之前的版本` / `正在收听：之前的版本（当前设定已有调整，待重新制作）` | 与书架和工作台的 `旧版音频` / `旧版可听` 术语统一 | 改为 **`旧版音频`** 与 **`正在收听：旧版音频（角色或配声已调整，重新生成后可更新）`** |
| **5. 审听与导出** | `AudiobookListeningView.swift:124` | 在听书模式中发现某段读音不理想，跳回工作台重录该段 | `返修此段` | 工作台中对应按钮叫 `重录本段`，而听书页叫 `返修此段`，前后端用词不一致 | 统一改为 **`重录本段`**，并附 `.help("返回制作工作台重新生成此段音频")` |
| **5. 审听与导出** | `AudiobookListeningView.swift:152-167, 179` | 在听书视图底部控制栏控制播放并查看自动书签说明 | 副文案：`按 48 kHz 实际采样帧计时 · 自动每 5 秒与暂停/离开时保存书签` | **严重底层实现术语泄露**：`按 48 kHz 实际采样帧计时` 是底层音频时钟实现细节，对听书用户毫无意义且造成干扰；同时底部 `−15 秒` / `+15 秒` 按钮可补齐明确无障碍标签 | 副文案改为 **`自动保存收听进度，暂停或离开后可随时续听`**；播放/暂停按钮补齐 `.accessibilityLabel(controller.isPlaying ? "暂停播放" : "开始播放")`，快退/快进补齐 `.accessibilityLabel("后退 15 秒")` / `.accessibilityLabel("前进 15 秒")` |

## 4. 严格验收标准（Acceptance Criteria）

重构完成后必须逐项通过以下 **26 项可量化验收标准**：

### 4.1 角色分层与配声死锁修复（AC-1）
- [x] **AC-1.1（新提取角色默认共享策略）**：`AudiobookCastRegistry.applyMergeBatch` 创建的新非旁白角色默认 `isMajor == false` 且 `allowSharedMinorVoice == true`。（已由 `AudiobookCastRegistry.swift:307-309` 实现，并通过 `AudiobookCastTests.testAC11_to_AC12_NewlyExtractedCharactersDefaultToEnsembleAndAutoStratify` 单测断言通过）
- [x] **AC-1.2（统计纯函数与主角数量封顶）**：`AudiobookCastRegistry.computeRoleDialogueStats` 不修改传入角色的 `isMajor` 与 `allowSharedMinorVoice`（保持 `AudiobookCastTests` 既有契约），且自动推断的 `.lead` 角色数不超过 `maxLeads`（6–8 人），单句龙套不进入 `.lead`。（已由 `AudiobookCastRegistry.swift:377-419` 实现，并通过 `AudiobookCastTests.testAC1_ParetoAdaptiveRoleStratification` 与 `testAC11_to_AC12_NewlyExtractedCharactersDefaultToEnsembleAndAutoStratify` 单测验证通过）
- [x] **AC-1.3（分析收尾与存量书籍自愈）**：`refreshCharacterMajorStatusAndOrder` 将非 `.lead` 角色标记为 `isMajor = false, allowSharedMinorVoice = true`；打开存量全员 `isMajor == true` 的书籍时自动完成分层自愈，右栏头部不再出现 `核心 121 · 配角 0`。（已由 `AudiobookCastRegistry.swift:485-519` 与 `AudiobookWorkflowModel.swift` 的 `normalizeLegacyUnstratifiedCharactersIfNeeded`、`leadCharacterCount` / `minorCharacterCount` 实现，并通过 `AudiobookWorkflowTests.testAC13_to_AC15_SilentRoleFoldingDefaultScopeAndLegacyOneClickAutoCast` 单测验证通过）
- [x] **AC-1.4（零台词角色默认隐藏与豁免）**：`dialogueAtomCount == 0` 的非旁白角色在全书分析完成后默认不出现在「本章出场」「核心主角」「配角群像」列表中，且不消耗独占音色容量。（已由 `AudiobookWorkflowModel.swift` 的 `isSilentCharacter`、`activeSpeakingCharacters`、`filteredCharacters` 实现，并通过 `AudiobookWorkflowTests.testAC13_to_AC15_SilentRoleFoldingDefaultScopeAndLegacyOneClickAutoCast` 单测验证 `showSilentCharacters == false/true` 切换断言通过）
- [x] **AC-1.5（一键智能配声一步落库）**：在多角色（如 50+ 角色）对少量可用音色（如 5–9 个音色）场景下，点击「一键智能配声」自动完成主角独占与配角群像共享绑定，不抛出阻塞性 `.insufficientVoiceCapacity` 报错，不卡在 `本次将调整 0 个角色` 面板。（已由 `AudiobookWorkflowModel.swift` 的 `autoAssignRecommendedVoices(consentsToSharedMinorVoices: true)` 实现，并通过 `AudiobookWorkflowTests.testAC13_to_AC15_SilentRoleFoldingDefaultScopeAndLegacyOneClickAutoCast` 验证 `errorMessage == nil && pendingCastingPlan == nil && voiceBindings.count >= 8`）

### 4.2 顶栏与左栏去噪瘦身（AC-2）
- [x] **AC-2.1（单书模式隐藏书架全局按钮）**：当 `surfaceMode != .shelf` 且已打开书籍时，窗口顶栏不显示 `导入 TXT…` 与 `废纸篓` 按钮；返回书架后正常显示。（已由 `AudiobookWorkshopView.swift` 的 `toolbarActions` 条件 `if workflow.surfaceMode == .shelf || workflow.selectedBook == nil` 实现并通过 Swift 6 全量类型检查）
- [x] **AC-2.2（AI 服务说明渐进式披露）**：工作台次顶栏移除常驻整行 `AI 分析服务：...` 长文本，改为点击 `[AI 与隐私]` 图标按钮以 Popover 呈现。（已由 `AudiobookBookWorkspaceView.swift` 的 `audiobook-ai-privacy-disclosure` Popover 按钮与 `aiPrivacyDetails` 视图实现并通过 Swift 6 全量类型检查）
- [x] **AC-2.3（左栏章节胶囊与重复按钮清理）**：章节列表移除未配声状态下全部章节重复的 `待确认配声` 胶囊，移除分析完成后常驻的章节拆分警告长文，移除左栏底部重复的 `快速定位下一处待确认` 按钮（保留中栏顶部定位栏）。（已由 `AudiobookBookWorkspaceView.swift` 的 `if readiness != .awaitingCastConfirmation`、`if workflow.canEditChapterStructure` 及左栏结构精简实现并通过 Swift 6 全量类型检查）

### 4.3 中栏剧本流、截断修复与快捷键（AC-3）
- [x] **AC-3.1（Document-First 连续剧本流）**：普通旁白与已确认对白段落采用左侧 3pt 垂直状态色条排版，连续旁白段落不重复渲染头部 `[旁白 · 未配声]` 标签栏；仅在说话人切换、角色对白或悬停/选中时显示操作控件。（已由 `AudiobookBookWorkspaceView.swift` 的 `atomRowView`、`showsHeaderControls`、`hoveredAtomID` 及左侧 3pt `Rectangle` 状态条实现并通过 Swift 6 全量类型检查）
- [x] **AC-3.2（零截断候选与数字键 `1~5` 确认）**：待确认说话人卡片中的候选按钮完整显示角色名称（无 `[✨ ...]` 截断），且当前聚焦待确认项支持数字键 `1~5` 快捷确认并自动跳至下一处。（已由 `AudiobookBookWorkspaceView.swift` 的横向自适应候选栏、`fixedSize(horizontal: true, vertical: false)` 与 `.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])` 实现并通过 Swift 6 全量类型检查）
- [x] **AC-3.3（零截断多选归属栏与导航栏）**：多选操作栏不再出现 4 个 `[归属给「...]` 截断按钮；待确认导航栏右侧 `[AI 智能复核]` 按钮完整显示不截断。（已由 `AudiobookBookWorkspaceView.swift` 的 `batchSpeakerAssignmentBar` 前 3 角色 + `旁白` + `更多角色…` 菜单与 `unknownSpeakerNavigatorBar` 的 `[AI 智能复核]` 按钮实现并通过 Swift 6 全量类型检查）
- [x] **AC-3.4（正文 `\u{FFFD}` 乱码净化）**：`AudiobookSourceIndex.normalizedText(in:)` 自动过滤 `\u{FFFD}` 替换符，正文不再显示 `[?]` 乱码占位符，同时保持原始字节偏移不变。（已由 `AudiobookSourceIndex.swift` 的 `joinParagraphLines` 过滤 `\u{FFFD}` 实现，并通过 `AudiobookSourceTests.testAC24_NormalizedTextStripsReplacementCharWhileRawTextPreservesOffsets` 单测验证通过）

### 4.4 右栏卡片精简、底部播放栏与自动化回归（AC-4）
- [x] **AC-4.1（右栏默认「本章出场」与单徽标）**：打开书籍进入工作台时，右栏筛选默认定位在「本章出场」，角色卡片消除 `ⓘ 群像 ⓘ 特色群像` 双重重复胶囊。（已由 `AudiobookWorkflowModel.swift` 的 `castFilterScope = .inCurrentChapter` 与 `AudiobookBookWorkspaceView.swift` 的 `characterCard` 单一 `StatusPill` 实现，并通过 `AudiobookWorkflowTests` 单测及 Swift 6 全量类型检查验证）
- [x] **AC-4.2（工作台底部常驻播放控制栏）**：当章节具备可播放音频或正在收听时，工作台底部显示常驻播放控制条，支持一键播放/暂停、±15s 跳转与倍速调节。（已由 `AudiobookBookWorkspaceView.swift` 底部挂载的 `workspaceTransportBar` / `audiobook-workspace-mini-transport` 实现并通过 Swift 6 全量类型检查）
- [x] **AC-4.3（编译与测试门禁 100% 通过）**：2026-10-17 在当前工作区完成验证。
  - `python3 scripts/check_macos_test_target_coverage.py`：`macos-test-target-coverage: OK`；
  - `AudiobookSourceTests`（含新增 `testAC24_NormalizedTextStripsReplacementCharWhileRawTextPreservesOffsets`）：11/11 项通过；
  - `AudiobookCastTests`（含新增 `testAC11_to_AC12_NewlyExtractedCharactersDefaultToEnsembleAndAutoStratify`）：7/7 项核心分层与配声套件通过（既有全量 72 项通过）；
  - `AudiobookWorkflowTests`（含新增 `testAC13_to_AC15_SilentRoleFoldingDefaultScopeAndLegacyOneClickAutoCast`）：2/2 项工作流自愈与自动锁定套件通过（既有全量 44 项通过）；
  - `swiftc -typecheck -swift-version 6 -parse-as-library ... SpeechRailApp/*.swift`：全量 App 源码（含 `AudiobookWorkshopView.swift` 与 `AudiobookBookWorkspaceView.swift`）0 编译错误通过；
  - `scripts/macos_app_build.sh --configuration Debug`：`BUILD SUCCEEDED`（注：遵循仓库 `AGENTS.md` 前台窗口保护门禁，未擅自拉起会抢占焦点的 GUI 自动化测试 `scripts/macos_app_test.sh`，桌面端前台点击交互留待人工打开 App 目视确认）。

### 4.5 制作页布局演进：阶段感知、双向折叠与音频片段流减负（AC-5，2026-10-17 新增）
- [x] **AC-5.1（自适应双核工作区宽度预算与左栏联动）**：`WindowLayoutPolicy.audiobookShowsInlineCastColumn(forWidth:isChapterSidebarCollapsed:isCastInspectorCollapsed:)` 支持显式收起右侧检查器（`isCastInspectorCollapsed == true` 时始终返回 `false`）；左栏展开时内联右栏阈值为 `1120pt`，左栏收起后内联右栏阈值降至 `880pt`（保障主画布 `≥500pt` + 右栏 `360pt`），兼容单参数既有调用。（已由 `WindowLayoutPolicy.swift` 实现，并通过 `AudiobookWorkflowTests.testAC51_to_AC55_AdaptiveWorkspaceLayoutPolicyAndRecoverablePhaseTransition` 单测断言通过）
- [x] **AC-5.2（阶段感知自动收展与双向可恢复侧栏控制）**：次顶栏同时提供左栏目录开关（`sidebar.left`）与右栏人物与声音检查器开关（`sidebar.right` / `人物与声音（N）`，`audiobook-toggle-cast-inspector`）；当全书无待确认说话人且配声已锁定、用户切入「制作与返修」阶段（且未手动固定右栏）时，自动收起右侧人物栏以聚焦「章节 + 音频片段」两栏制作；切回「准备与角色」时自动恢复展开，且任何宽度与阶段下均可手动展开或浮层唤出，筛选与角色状态 100% 保留。（已由 `WindowLayoutPolicy.audiobookRecommendedCastInspectorCollapsed` 与 `AudiobookBookWorkspaceView.swift` 实现，并通过 `testAC51_to_AC55_AdaptiveWorkspaceLayoutPolicyAndRecoverablePhaseTransition` 单测及 Swift 6 全量类型检查验证）
- [x] **AC-5.3（移除「三栏工作台」硬编码命名）**：`AudiobookWorkshopView.swift` 顶栏视图模式切换器由 `三栏工作台` 改为任务导向的 `制作工作台`，消除窄屏或两栏专注态下的命名冲突。（已由 `AudiobookWorkshopView.swift:117` 实现并通过 Swift 6 全量类型检查验证）
- [x] **AC-5.4（「制作与返修」音频片段流去卡片框与连续同角色去重）**：`AudiobookBookWorkspaceView.swift` 的 `fragmentRowView` 移除外层重型 `CardSurface` 嵌套，统一采用左侧 3pt 垂直状态色条（制作中/待更新 = `attention`、已就绪 = `ready`、待合成 = `separator`），且连续相同角色且已就绪的片段默认折叠重复角色胶囊（悬停、多候选或角色切换时显露）。（已由 `AudiobookBookWorkspaceView.swift` 的 `fragmentRowView(fragment:previousFragment:)` 与 `hoveredFragmentID` 实现并通过 Swift 6 全量类型检查验证）
- [x] **AC-5.5（布局策略与状态可恢复性单测及编译验证）**：新增确定性测试覆盖 `WindowLayoutPolicy` 动态阈值与阶段感知自动收展策略，并通过 `check_macos_test_target_coverage.py`（`macos-test-target-coverage: OK`）、有声书单测套件（`AudiobookSourceTests` 11/11、`AudiobookCastTests` 7/7、`AudiobookWorkflowTests` 3/3 全部通过）与 `swiftc -typecheck -swift-version 6` 全量编译检查（`0_COMPILER_ERRORS`）。

### 4.6 全流程 UI 文案一致性、去术语化与无障碍标签优化（AC-6，2026-10-17 新增）
- [x] **AC-6.1（彻底清除面向用户的底层实现术语）**：移除有声书界面中的 `片段偏置`、`正文切分块`、`当前章节尚未生成片段规划`、`规范化原文`、`代次 #N`、`（%lld 帧）`、`按 48 kHz 实际采样帧计时` 等内部工程概念，分别替换为创作者直觉语言（`上次听到本段第 X 秒`、`已选中 N 段正文`、`本章尚未生成音频`、`原文内容保持不变`、`第 N 版`、纯秒数时长、`自动保存收听进度，暂停或离开后可随时续听`）。（已由 `AudiobookBookShelfView.swift`、`AudiobookWorkshopView.swift`、`AudiobookBookWorkspaceView.swift`、`AudiobookListeningView.swift` 与 `AudiobookWorkflowModel.swift` 实现，并通过 `AudiobookWorkflowTests.testAC61_to_AC65_ChapterProductionButtonTitleAndSplitMergeBannerCopy` 单测及 Swift 6 类型检查验证）
- [x] **AC-6.2（书架、工作台与听书页跨视图动作与状态词典统一）**：书架卡片主按钮与 `⋯` 菜单统一为 `打开工作台`，导出菜单项统一为 `导出有声书…`，模糊状态 `分析：需处理` / `制作：需处理` 明确为 `分析：需重试` / `制作：需重试`，旧版音频状态在书架、章节栏、片段对比与听书页统一为 `旧版音频` / `旧版可听` / `旧版设定`，听书页单段返修按钮与工作台统一为 `重录本段`。（已由 `AudiobookBookShelfView.swift`、`AudiobookWorkshopView.swift`、`AudiobookBookWorkspaceView.swift` 与 `AudiobookListeningView.swift` 实现并通过 Swift 6 类型检查验证）
- [x] **AC-6.3（校对与选角面板动宾一致性及窄栏防截断）**：正文批量与单段说话人修改统一为 `设为「X」` / `更换说话人` / `撤销上次说话人修改`；待确认说话人卡片提示直接标明 `选择说话人（按数字键 1–5 快速确认并跳至下一处）：`；右侧人物栏底部主按钮精简为 `一键智能配声`，无对白角色开关文案统一为 `显示/隐藏 N 个无对白角色`。（已由 `AudiobookBookWorkspaceView.swift` 实现并通过 Swift 6 类型检查验证）
- [x] **AC-6.4（章节制作状态感知按钮与弹窗关闭语义规范）**：章节制作页空状态与底部主按钮根据当前章节是否已有成片动态显示 `生成本章音频` 或 `更新本章音频`（消除生硬的 `制作/更新本章` 斜杠词）；废纸篓与合并/拆分角色等非表单弹窗关闭按钮由模糊的 `完成` 统一改为 `关闭`，错误横幅由 `需要处理 / 关闭提示` 改为 `操作未完成 / 知道了`。（已由 `AudiobookWorkflowModel.chapterProductionButtonTitle(for:)`、`AudiobookBookWorkspaceView.swift` 与 `AudiobookWorkshopView.swift` 实现，并通过 `AudiobookWorkflowTests.testAC61_to_AC65_ChapterProductionButtonTitleAndSplitMergeBannerCopy` 单测断言通过）
- [x] **AC-6.5（纯图标控件与播放传输栏无障碍名称全覆盖）**：为工作台左栏折叠按钮（`展开章节目录` / `收起章节目录`）、右栏检查器开关（含展开/收起状态值）、工作台迷你播放栏与听书页底部播放栏的播放/暂停及 `−15 秒` / `+15 秒`（`后退 15 秒` / `前进 15 秒`）、书架卡片 `⋯` 菜单（`更多书籍操作`）及候选音频试听按钮补齐动态 `.accessibilityLabel` / `.accessibilityValue`。（已由 `AudiobookBookShelfView.swift`、`AudiobookBookWorkspaceView.swift` 与 `AudiobookListeningView.swift` 实现并通过 Swift 6 类型检查验证）
- [x] **AC-6.6（UI 文案契约确定性测试与 Swift 6 全量类型检查通过）**：新增确定性测试 `testAC61_to_AC65_ChapterProductionButtonTitleAndSplitMergeBannerCopy` 校验关键动态文案与去术语化契约，运行有声书单元测试（`AudiobookSourceTests` 11/11、`AudiobookCastTests` 7/7、`AudiobookWorkflowTests` 4/4 全部通过）、`check_macos_test_target_coverage.py`（`macos-test-target-coverage: OK`）与 Swift 6 全量类型检查（`0_COMPILER_ERRORS`）全部通过，且未触碰提词器等旁支模块文件。
