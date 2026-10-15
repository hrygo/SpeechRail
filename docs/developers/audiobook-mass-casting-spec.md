# SpeechRail 有声书工坊大规模角色配音与 100+ 音色库专业化管理技术方案（实施与验收规范）

## 1. 现状代码审计：大规模角色配音与 100+ 音色管理的八大瓶颈

在长篇多人有声书制作场景下（单书常含 50～200 个出场角色，且随着「AI 设计新音色」高频使用，用户音色总量极易突破 100～300+），对当前 `SpeechRailApp` 代码链路进行逐行审计，可定位出 **角色配音调度（B1～B5）** 与 **音色库资产管理（B6～B8）** 两大维度的八个核心瓶颈：

### 1.1 角色分层与自动配音调度瓶颈（B1～B5）

| 瓶颈编号 | 涉及源文件与位置 | 现状代码实现逻辑 | 导致的实际生产阻塞与听感缺陷 |
| :--- | :--- | :--- | :--- |
| **B1 · 主次判定阈值过低** | `AudiobookCastRegistry.swift`（`refreshCharacterMajorStatusAndOrder`） | `let isMajorRole = totalNonNarrators <= 4 \|\| count >= 2 \|\| copy.chapterIDs.count >= 2`，满足即设 `isMajor = true`、`allowSharedMinorVoice = false` | 任何路人只要在同一场戏一问一答说满 2 句话，或跨两章被提及，即被判定为「主要角色」并锁定独占声线，导致全书 70% 以上配角无法自动进入共享声线池 |
| **B2 · 主配角争抢同一音色池引发绑定死锁** | `AudiobookCastRegistry.swift`（`recommendVoiceBindings`）与 `AudiobookCastController.swift`（`bindVoice`） | 当未占用音色 `unusedVoices` 耗尽后，配角回退至全量 `readyVoices` 选音色；而 `bindVoice` 要求**共用同一 `voiceID` 的双方都必须开启 `allowSharedMinorVoice == true`** | 一旦配角从 `readyVoices` 中选中了某个核心主角（`allowSharedMinorVoice == false`）已绑定的音色，`bindVoice` 立即抛出 `.duplicateVoiceRequiresSharedMinorConsent`，导致大量配角自动配声失败、保持未绑定状态 |
| **B3 · 零对白背景人物抢占音色并阻塞确认门禁** | `AudiobookCastController.swift`（`confirmCast`） | `confirmCast` 要求 `characters` 表中所有角色 `100%` 绑定音色，未区分实际归属对白数 `dialogueCount == 0` 的仅提及人物 | 阶段一提取出的“回忆中提及的人物”或“有动作无台词的人物”既抢占可用音色，又在音色不足时阻塞全书角色确认门禁 |
| **B4 · 缺乏同场防撞色调度与微语速透传** | `AudiobookCastRegistry.swift`（`selectBestVoice`）与 `AudiobookProductionController.swift`（`renderSingleFragmentWithFiniteRetry`） | `selectBestVoice` 未引入章节/段落共现图惩罚，同类配角坍缩至同一最高分音色；且合成请求硬编码 `speed: policy.defaultSpeed`，忽略了 `binding.allowedSpeed` | 同一场戏中两个同类配角（如「张掌柜」与「李员外」）使用同一音色、同一语速面对面交谈，听众产生严重“自言自语”出戏感 |
| **B5 · 角色工作台平铺展示且无批量行当操作** | `AudiobookBookWorkspaceView.swift`（`characterCard`） | 所有角色卡片平铺渲染，无对白句数徽标、无主次/本章筛选器、无按声部行当批量换绑入口 | 面对 80+ 张角色卡片时，用户无法快速识别核心主角，也无法将新设计的群像音色一键应用给同类配角 |

### 1.2 音色突破 100+ 时的资产管理与选角交互瓶颈（B6～B8）

| 瓶颈编号 | 涉及源文件与位置 | 现状代码实现逻辑 | 音色突破 100+ 时的灾难性后果 |
| :--- | :--- | :--- | :--- |
| **B6 · 专用音色污染全局音色池（无作用域边界）** | `VoiceWorkflowModel.swift` 与 `AudiobookWorkflowModel.swift` | 所有系统音色、通用克隆音色、以及在某本书中为特定角色生成的「AI 设计新音色」全部平铺写入同一个全局音色列表，无 `Scope`（全局通用 vs 书籍专用 vs 已归档）元数据 | 制作 4～5 本长篇小说后，每本书为角色定制的 20～30 个专用音色全部涌入全局音色库、演播台及新书选角列表，导致新书选角被旧书专属角色音色严重干扰 |
| **B7 · 音色库无分面分类体系与剧团合集（平铺列表失效）** | `CreatorSurfaceViews.swift`（`VoiceLibraryView`） | 音色库仅支持简单的文本搜索和 `全部/系统/我的` 模式过滤，缺乏按**声部行当（Archetype）**、**作用域（通用/剧组专用/归档）**、**剧团音色包（Collections）**、**星标常用（Favorites）**的多维分面索引 | 当音色超过 100 个时，单列平铺列表需要反复滚动十余屏才能找到目标声线；无法按「中老年男声」「古风剧团包」快速筛选或批量归档旧剧组音色 |
| **B8 · 角色卡片原生 `Menu` 下拉选角在 100+ 音色下崩溃** | `AudiobookBookWorkspaceView.swift`（`characterCard`） | 使用原生扁平 `Menu` 渲染全部可用音色 | 在 macOS 上，超过 100 项的扁平 `Menu` 会变成贯穿整个屏幕高度的超长纯文字滚动条：无法输入关键词搜索、无法在选角前按声部过滤、无法看到该音色在本书是否已被其他主角独占 |

---

## 2. 六层总体架构设计

1. **第 1 层 · 音色资产三层作用域与六维声学分面索引（`VoiceAssetScope` & `VoiceTaxonomyClassifier`）**：将全部音色划分为 `全局通用库 (.globalReusable)`、`书籍剧组专用池 (.bookExclusive)` 与 `归档冷备库 (.archived)`，自动推导六大声部行当标签并支持自定义「剧团音色包（`VoiceCollection`）」。
2. **第 2 层 · 自适应四级角色分层（`AudiobookRoleTier`）**：结合全书对白帕累托分布（80/20 法则）与当前可用音色池容量 $M$，动态划分 `旁白 (.narrator)`、`核心主角 (.lead)`、`常驻配角 (.supporting)` 与 `群像/背景 (.ensemble)`。
3. **第 3 层 · 独占池与共享池物理隔离（Dual-Pool Partitioning）**：将可用音色切分为「旁白与主角独占池（Exclusive Pool）」和「配角行当共享池（Shared Repertory Pool）」，优先匹配本书专用音色与首选剧团包，确保主角声线独占且配角复用 100% 满足 `bindVoice` 双向门禁。
4. **第 4 层 · 带权对话冲突图着色算法（Weighted Co-occurrence Graph Coloring）**：从全书 `annotations` 构建角色同场对话冲突图，对同场紧邻交谈（$\le 6$ 个正文块间距）施加 $+600$ 排斥权重，结合全局复用负载均衡（$35 \times \text{usageCount}$），实现「同场对手戏零撞音」。
5. **第 5 层 · 模式感知微韵律与确定性种子错位（Mode-Aware Micro-Prosody & Seed Differentiation）**：针对共用同一 `system` 音色的配角自动注入微语速偏移（`0.92x ~ 1.08x`），针对语速锁死为 `1.0x` 的 `clone` 音色分配确定性 `callerSeed`（`101/202/303/404`），并打通 `AudiobookProductionController` 合成透传。
6. **第 6 层 · 分层角色工作台、智能选角 Popover 与分面音色管理中心（Scalable UI/UX）**：用带搜索、声部自动预筛与占用状态标识的 `AudiobookVoicePickerPopover` 替换平铺 `Menu`；将全局音色库升级为支持「作用域分栏 + 声部行当胶囊过滤 + 书籍专用分组 + 一键晋升/归档」的专业资产中心。

---

## 3. 验收标准矩阵（AC1～AC10）

| 验收项编号 | 验收场景（GIVEN / WHEN） | 通过判据（THEN 强制断言） |
| :--- | :--- | :--- |
| **AC1 · 帕累托自适应主次分层** | 全书含 1 旁白、3 高频主角（各 20 句台词）、25 个仅说 2 句台词的配角及 5 个 0 台词背景人物，可用音色数为 6 | 仅旁白与 3 个高频主角 `allowSharedMinorVoice == false`；25 个 2 句配角与 5 个 0 台词人物全部自动标为 `isMajor == false && allowSharedMinorVoice == true` |
| **AC2 · 50 角色 vs 5 音色双池零死锁全绑定** | 全书含 50 个角色（1 旁白 + 2 主角 + 47 配角），可用音色库仅有 5 个音色 | 全部 50 个角色 100% 成功绑定且不抛出 `.duplicateVoiceRequiresSharedMinorConsent`；旁白与 2 主角的 3 个独占音色绝不被配角占用 |
| **AC3 · 同场对手戏零撞音** | 同一章节中配角「张掌柜」与「李员外」（同为中老年男性声部）在相邻段落交替对话 4 次，共享池有 $\ge 2$ 个可用音色 | 「张掌柜」与「李员外」分配到的 `voiceID` 严格不相等（`bindingA.voiceID != bindingB.voiceID`） |
| **AC4 · 模式感知微语速与克隆种子错位** | 3 个配角共用同一 `system` 音色，另有 2 个配角共用同一 `clone` 音色 | 共用 `system` 音色的配角获得差异化 `allowedSpeed` 并在合成请求中透传；共用 `clone` 音色的配角 `allowedSpeed` 严格保持 `1.0` 且 `callerSeed` 互不相同 |
| **AC5 · 按声部行当一键批量换绑** | 全书有 12 个属于 `matureMale` 的配角与 1 个属于 `matureMale` 的核心主角 | 调用 `batchBindArchetypeVoice` 后 12 个中老年男配角全部换绑至目标音色并注入微语速错位，核心主角保持原专属音色不被覆盖 |
| **AC6 · 零台词背景角色不阻塞确认门禁** | 全书所有实际有对白归属的角色均已绑定音色，仅剩 2 个 `dialogueAtomCount == 0` 的仅提及背景角色未绑定 | `confirmCast` 正常通过不抛 `.missingVoiceBindings` 异常 |
| **AC7 · 书籍专用音色跨书隔离与本角优先绑定** | 音色库共 120 个音色（含《书籍 A》40 个专用音色、《书籍 B》30 个专用音色、50 个全局通用音色） | 在《书籍 A》中选角时，《书籍 B》的 30 个专用音色被 100% 隔离；且《书籍 A》内为角色「林动」定制的专用音色以最高优先级自动匹配回「林动」 |
| **AC8 · 专用音色一键晋升至全局通用库** | 音色初始为《书籍 A》专用音色（`scope == .bookExclusive`），执行 `promoteToGlobalReusable` | 该音色 `scope` 更新为 `.globalReusable`（保留 `originBookTitle` 溯源信息），并立即对《书籍 B》和全局通用池可见 |
| **AC9 · 100+ 音色六大声部行当 100% 自动分面归类** | 120 个混合了中英文描述、`system/clone` 模式的音色列表 | 每个音色均被 `VoiceTaxonomyClassifier` 确定性归入六大声部行当之一 |
| **AC10 · 剧团音色包优先选角与批量归档** | 创建「古风仙侠剧团包」设为本书 `preferredCollectionID`；将旧书专用音色批量归档（`.archived`） | 智能配声优先选用「古风仙侠剧团包」内的音色；已归档音色从活跃选角器中隐藏 |
