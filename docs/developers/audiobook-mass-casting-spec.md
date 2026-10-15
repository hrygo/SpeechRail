---
title: "有声书工坊大规模角色配音与 100+ 音色库专业化管理技术方案（实施与验收规范）"
status: active
audience: "客户端架构师、音频算法工程师、QA 验收团队"
version: "1.0.0"
date: 2026-10-15
---

# SpeechRail 有声书工坊大规模角色配音与 100+ 音色库专业化管理技术方案

本文档完整记录 **SpeechRail 有声书工坊（Audiobook Workshop）** 针对长篇多人有声书（单书 50～200+ 出场角色）的配音效率优化，以及当用户通过「AI 设计新音色 / 录音克隆」积累 **100～500+ 音色**时的专业化分级管理、剧组专用音色隔离、六维声部分面分类与自动化验收规范（AC1～AC10）。

---

## 1. 现状代码审计：大规模角色配音与 100+ 音色管理的八大瓶颈

在长篇多人有声书制作场景下，对原有 `SpeechRailApp` 代码链路进行逐行审计，可定位出 **角色配音调度（B1～B5）** 与 **音色库资产管理（B6～B8）** 两大维度的八个核心瓶颈：

### 1.1 角色分层与自动配音调度瓶颈（B1～B5）

| 瓶颈编号 | 涉及源文件与位置 | 原有代码实现逻辑 | 导致的实际生产阻塞与听感缺陷 |
| :--- | :--- | :--- | :--- |
| **B1 · 主次判定阈值过低** | `AudiobookCastRegistry.swift`（`refreshCharacterMajorStatusAndOrder`） | `let isMajorRole = totalNonNarrators <= 4 \|\| count >= 2 \|\| copy.chapterIDs.count >= 2`，满足即设 `isMajor = true`、`allowSharedMinorVoice = false` | 任何路人只要在同一场戏一问一答说满 2 句话，或跨两章被提及，即被判定为「主要角色」并锁定独占声线，导致全书 70% 以上配角无法自动进入共享声线池 |
| **B2 · 主配角争抢同一音色池引发绑定死锁** | `AudiobookCastRegistry.swift`（`recommendVoiceBindings`）与 `AudiobookCastController.swift`（`bindVoice`） | 当未占用音色 `unusedVoices` 耗尽后，配角回退至全量 `readyVoices` 选音色；而 `bindVoice` 要求**共用同一 `voiceID` 的双方都必须开启 `allowSharedMinorVoice == true`** | 一旦配角从 `readyVoices` 中选中了某个核心主角（`allowSharedMinorVoice == false`）已绑定的音色，`bindVoice` 立即抛出 `.duplicateVoiceRequiresSharedMinorConsent`，导致大量配角自动配声失败、保持未绑定状态 |
| **B3 · 零对白背景人物抢占音色并阻塞确认门禁** | `AudiobookCastController.swift`（`confirmCast`） | `confirmCast` 要求 `characters` 表中所有角色 `100%` 绑定音色，未区分实际归属对白数 `dialogueCount == 0` 的仅提及人物 | 阶段一提取出的“回忆中提及的人物”或“有动作无台词的人物”既抢占可用音色，又在音色不足时阻塞全书角色确认门禁 |
| **B4 · 缺乏同场防撞色调度与微语速透传** | `AudiobookCastRegistry.swift`（`selectBestVoice`）与 `AudiobookProductionController.swift`（`renderSingleFragmentWithFiniteRetry`） | `selectBestVoice` 未引入章节/段落共现图惩罚，同类配角坍缩至同一最高分音色；且合成请求硬编码 `speed: policy.defaultSpeed`，忽略了 `binding.allowedSpeed` | 同一场戏中两个同类配角（如「张掌柜」与「李员外」）使用同一音色、同一语速面对面交谈，听众产生严重“自言自语”出戏感 |
| **B5 · 角色工作台平铺展示且无批量行当操作** | `AudiobookBookWorkspaceView.swift`（`characterCard`） | 所有角色卡片平铺渲染，无对白句数徽标、无主次/本章筛选器、无按声部行当批量换绑入口 | 面对 80+ 张角色卡片时，用户无法快速识别核心主角，也无法将新设计的群像音色一键应用给同类配角 |

### 1.2 音色突破 100+ 时的资产管理与选角交互瓶颈（B6～B8）

| 瓶颈编号 | 涉及源文件与位置 | 原有代码实现逻辑 | 音色突破 100+ 时的灾难性后果 |
| :--- | :--- | :--- | :--- |
| **B6 · 专用音色污染全局音色池（无作用域边界）** | `VoiceWorkflowModel.swift` 与 `AudiobookWorkflowModel.swift` | 所有系统音色、通用克隆音色、以及在某本书中为特定角色生成的「AI 设计新音色」全部平铺写入同一个全局音色列表，无 `Scope`（全局通用 vs 书籍专用 vs 已归档）元数据 | 制作 4～5 本长篇小说后，每本书为角色定制的 20～30 个专用音色全部涌入全局音色库、演播台及新书选角列表，导致新书选角被旧书专属角色音色严重干扰 |
| **B7 · 音色库无分面分类体系与剧团合集（平铺列表失效）** | `CreatorSurfaceViews.swift`（`VoiceLibraryView`） | 音色库仅支持简单的文本搜索和 `全部/系统/我的` 模式过滤，缺乏按**声部行当（Archetype）**、**作用域（通用/剧组专用/归档）**、**剧团音色包（Collections）**、**星标常用（Favorites）**的多维分面索引 | 当音色超过 100 个时，单列平铺列表需要反复滚动十余屏才能找到目标声线；无法按「中老年男声」「古风剧团包」快速筛选或批量归档旧剧组音色 |
| **B8 · 角色卡片原生 `Menu` 下拉选角在 100+ 音色下崩溃** | `AudiobookBookWorkspaceView.swift`（`characterCard`） | 使用原生扁平 `Menu` 渲染全部可用音色 | 在 macOS 上，超过 100 项的扁平 `Menu` 会变成贯穿整个屏幕高度的超长纯文字滚动条：无法输入关键词搜索、无法在选角前按声部过滤、无法看到该音色在本书是否已被其他主角独占 |

---

## 2. 100+ 音色资产专业化管理调研与方案对比

针对工业级有声书制作平台（Audible Studio、喜马拉雅有声剧工作台、ElevenLabs Projects、Pro Tools / Reaper 角色母带资产库）与游戏语音资产管理系统（Wwise / FMOD Voice Bank）的调研表明，当单用户音色资产超过 100 个时，音色会分化为两类完全不同生命周期的资产：
1. **常备剧团通用音色（Repertory / Global Reusable Voices）**：如标准旁白、青衣女声、沉稳中年男声、少年音、老者音，跨多本书高频复用；
2. **单书剧组专用音色（Book-Scoped / Role-Exclusive Voices）**：在某本书（如《迷雾渡口》）工作台内点击「AI 设计新音色」为特定角色（如「林远船长」）量身定制的声线，强绑定于该书角色人设，若直接混入全局列表将造成严重的跨书命名污染。

### 2.1 三种候选管理架构对比

| 评估维度 | 方案 A：平铺列表 + 关键词搜索（原有实现） | 方案 B：传统单树状文件夹（Folder Hierarchy） | 方案 C：三级作用域隔离 + 六维声部行当分面索引 + 剧团音色包（采纳方案） |
| :--- | :--- | :--- | :--- |
| **跨书专用音色污染治理** | 差：旧书定制角色音色全部混入新书选角菜单 | 一般：需用户每次手动创建文件夹并移动音色，操作繁琐易遗漏 | **优**：从有声书工作台跳转「AI 设计新音色」创建的声线自动标记为 `bookExclusive(bookID)`，对其他书籍默认隔离，且支持「一键晋升为全局通用音色」 |
| **多维交叉检索效率** | 差：仅能搜名字，不记得音色名时无法按声部寻找 | 差：一个音色只能放在一个文件夹（按书分就不能按男女老少分） | **优**：正交分面过滤（`作用域 Tab` × `六大声部行当 Pill` × `星标收藏` × `剧团合集包` × `实时搜索`），100+ 音色可在 2 次点击内收敛至 5～8 个候选 |
| **选角工作台联动能力** | 差：扁平 `Menu` 无法展示占用状态与声部匹配度 | 一般：多级子菜单（Submenu）仍无法搜索与试听 | **优**：专属 `AudiobookVoicePickerPopover` 根据当前角色的推断声部（如「沉稳中年男声」）自动置顶同声部可用音色与本书专用音色，并支持行内试听 |
| **向后兼容性与持久化** | 无需改动 | 需重构后端音色存储目录 | **优**：客户端轻量级 JSON 元数据层（`VoiceCatalogStore`）叠加在 `SafeVoiceCatalog` 之上，零破坏现有服务端 API 契约 |

---

## 3. 六层总体架构与核心领域模型设计

### 3.1 六层架构总览

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ 第 6 层：可扩展 UI/UX 工作台层 (AudiobookBookWorkspaceView & VoiceLibraryView) │
│   • 角色工作台五维筛选 + 行当批量配声 + 同场撞音预警 + 智能选角 Popover        │
│   • 音色库四级作用域分栏 (通用/收藏/剧组专用/归档) + 六大声部胶囊 + 晋升/归档   │
├───────────────────────────────────────────────────────────────────────────────┤
│ 第 5 层：模式感知微韵律与确定性种子分化层 (Micro-Prosody & Seed Differentiator) │
│   • system 共享音色：确定性 FNV-1a/SHA256 哈希微语速偏移 (0.94x ~ 1.06x)      │
│   • clone 共享音色：语速强制锁定 1.0x + 确定性 callerSeed 错位 (101/202/303/404)│
│   • AudiobookProductionController 合成管线透传 binding.allowedSpeed           │
├───────────────────────────────────────────────────────────────────────────────┤
│ 第 4 层：带权同场对话冲突图着色层 (Weighted Co-occurrence Graph Coloring)      │
│   • 扫描全书章节与相邻 ≤6 句对话窗口构建角色共现无向带权图 G=(V, E, w)         │
│   • Welsh-Powell 按加权度降序着色：同场对手戏强排斥 (+600) + 全局复用均衡 (+35) │
├───────────────────────────────────────────────────────────────────────────────┤
│ 第 3 层：独占池与共享池物理隔离层 (Dual-Pool Voice Partitioning)               │
│   • 旁白与核心主角独占池 (Exclusive Pool) vs 配角行当共享池 (Shared Pool)      │
│   • 本书本角专用音色 (+500) 与首选剧团音色包 (+28) 优先级加成，100% 零死锁绑定  │
├───────────────────────────────────────────────────────────────────────────────┤
│ 第 2 层：帕累托自适应四级角色分层层 (4-Tier Adaptive Role Stratification)      │
│   • 旁白 (.narrator) / 核心主角 (.lead) / 重要配角 (.supporting) / 龙套 (.ensemble)│
│   • 结合 75% 累计对白帕累托前沿与独占音色预算 K = min(6, max(1, M - 2))        │
│   • 0 台词仅提及角色 (dialogueAtomCount == 0) 自动豁免 confirmCast 门禁       │
├───────────────────────────────────────────────────────────────────────────────┤
│ 第 1 层：100+ 音色三层作用域与六维声学分类层 (VoiceCatalogStore & Classifier)  │
│   • 作用域：.globalReusable (全局通用) / .bookExclusive (剧组专用) / .archived │
│   • 六大声部行当：青年男/沉稳中年男/老者男/青年女/成熟温柔女/老年及童声        │
└───────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 核心领域模型规范（`AudiobookDomain.swift`）

#### 3.2.1 四级角色层级与六大声部行当

```swift
/// 有声书角色四级自适应层级
public enum AudiobookRoleTier: String, Codable, Sendable, CaseIterable, Comparable {
    case narrator = "narrator"       // 旁白（独占声线）
    case lead = "lead"               // 核心主角（独占声线）
    case supporting = "supporting"   // 重要配角（行当共享池 + 防同场撞音）
    case ensemble = "ensemble"       // 龙套群演 / 0 台词背景角色（声部基准池共享）
}

/// 六大标准声部行当（用于 100+ 音色自动分面归类与配角行当批量配声）
public enum AudiobookVoiceArchetype: String, Codable, Sendable, CaseIterable, Identifiable {
    case youngMale = "young_male"           // 青年男声（清亮/少年/公子）
    case matureMale = "mature_male"         // 沉稳中年男声（浑厚/掌柜/大叔）
    case elderMale = "elder_male"           // 苍老老者男声（沙哑/老叟/长老）
    case youngFemale = "young_female"       // 清亮青年女声（清脆/少女/丫鬟）
    case matureFemale = "mature_female"     // 成熟温柔女声（温婉/夫人/御姐）
    case elderOrChild = "elder_or_child"    // 慈祥老妪与童声（老妇/孩童）
}

/// 单角色全书台词统计与分层快照
public struct AudiobookRoleDialogueStats: Codable, Hashable, Sendable {
    public var roleID: UUID
    public var dialogueAtomCount: Int
    public var dialogueCharCount: Int
    public var chapterCount: Int
    public var dialogueShare: Double
    public var tier: AudiobookRoleTier

    /// 0 台词仅提及角色无需强制绑定音色即可通过全书角色确认门禁
    public var requiresVoiceBinding: Bool {
        tier == .narrator || dialogueAtomCount > 0
    }
}
```

#### 3.2.2 100+ 音色三级作用域、元数据与剧团合集（`VoiceCatalogStore`）

```swift
/// 音色资产三级作用域
public enum VoiceAssetScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case globalReusable = "global_reusable" // 全局通用常备音色（所有书籍与演播台可见）
    case bookExclusive = "book_exclusive"   // 特定书籍剧组专用音色（仅所属书籍默认可见）
    case archived = "archived"              // 已归档冷备音色（默认隐藏，可随时恢复）
}

/// 音色资产扩展元数据（持久化于 Application Support/SpeechRail/voice_catalog_metadata_v1.json）
public struct VoiceAssetMetadata: Codable, Hashable, Sendable, Identifiable {
    public var voiceID: String
    public var scope: VoiceAssetScope
    public var originBookID: UUID?
    public var originBookTitle: String?
    public var originRoleID: UUID?
    public var originRoleName: String?
    public var archetypeOverride: AudiobookVoiceArchetype?
    public var customTags: [String]
    public var isFavorite: Bool
    public var creationSource: VoiceCreationSource
    public var createdAt: Date
}

/// 剧团音色包（Repertory Voice Pack）
public struct VoiceCollection: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var voiceIDs: [String]
    public var isBuiltIn: Bool
}
```

---

## 4. 核心算法与工程机制详解

### 4.1 帕累托（80/20）自适应四级角色分层算法（`computeRoleDialogueStats`）

为了彻底消除 **B1（路人说 2 句话即锁定独占音色）**，系统根据全书实际已归属对白段落统计与当前可用音色总数 $M$，动态计算独占配额：

1. **主角独占预算计算**：
   $$\text{leadBudget} = \min\left(6, \max(1, M - 2)\right)$$
   当可用音色数 $M \ge 3$ 时，至少为配角共享池预留 $\min(2, M - 1)$ 个音色（例如仅有 5 个音色时：1 个旁白 + 最多 2 个核心主角独占 + 2 个共享音色供所有配角轮转复用）。
2. **四级判定规则**：
   - **旁白（`.narrator`）**：`character.isNarrator == true`，始终 `isMajor = true`、`allowSharedMinorVoice = false`。
   - **零台词或单句群演（`.ensemble`）**：`dialogueAtomCount == 0`（仅在文中被提及）或（非旁白总角色数 $> 6$ 且 `dialogueAtomCount <= 1` 且登场章节数 $\le 1$），自动设 `isMajor = false`、`allowSharedMinorVoice = true`。
   - **核心主角（`.lead`）**：按对白句数降序排列，在满足以下任一条件且未超出 `leadBudget` 时入选：
     - 非旁白角色总数 $\le 4$ 且 `dialogueAtomCount > 0`；
     - 排名第 1 的第一主角；
     - 累计台词占比处于前 $75\%$ 帕累托区间，且单角色对白句数 $\ge \max(3, \lceil 0.08 \times \text{totalDialogueAtoms} \rceil)$；
     - 对白句数 $\ge 6$ 且跨 $\ge 2$ 章登场。
     入选 `.lead` 的角色自动设 `isMajor = true`、`allowSharedMinorVoice = false`。
   - **重要配角（`.supporting`）**：其余有台词角色，自动设 `isMajor = false`、`allowSharedMinorVoice = true`。

### 4.2 独占池与共享池物理隔离机制（Dual-Pool Partitioning）

在 `AudiobookCastRegistry.recommendVoiceBindings` 中，彻底解耦主角与配角的候选音色池：

1. **作用域预过滤（Scope Filtering）**：
   先通过 `VoiceCatalogStore.isVoiceActiveForBook(voiceID:currentBookID:)` 过滤掉 `.archived` 音色及属于其他书籍的 `.bookExclusive` 专用音色。
2. **第一阶段：旁白与核心主角（`.narrator` + `.lead`）独占分配**：
   - 从当前书籍可见的 `readyVoices` 中，为旁白与核心主角择优分配互不重复的音色，并将已分配的 `voiceID` 记入 `exclusiveLockedVoiceIDs`。
   - 若某音色是当前书籍专为该角色生成的专用音色（`scope == .bookExclusive && originBookID == bookID && originRoleID == role.id`），赋予 **$+500$ 分**绝对优先级加成。
   - 若当前书籍指定了首选剧团音色包（`preferredCollectionID`），包内音色获得 **$+28$ 分**加成。
3. **第二阶段：构建配角共享池（`sharedPoolVoices`）**：
   $$\text{sharedPoolVoices} = \{ v \in \text{activeVoices} \mid v.\text{id} \notin \text{exclusiveLockedVoiceIDs} \}$$
   - 正常情况下（可用音色数 $>$ 独占角色数），配角与群演**严禁触碰 `exclusiveLockedVoiceIDs` 中的任何音色**，从而在数学上保证：
     - 核心主角音色 100% 独占，绝不被路人“撞声”；
     - 配角共享池中的所有角色均具备 `allowSharedMinorVoice == true`，调用 `bindVoice` 时 **100% 不会触发 `.duplicateVoiceRequiresSharedMinorConsent` 死锁**。

### 4.3 带权同场对话冲突图着色算法（Welsh-Powell Co-occurrence Coloring）

为解决 **B4（同场配角共用同一音色自言自语）**，`AudiobookCastRegistry.buildSceneConflictGraph` 扫描全书标注序列，构建无向带权共现冲突图 $G = (V, E, w)$：

1. **边权构建规则**：
   - **同章共现基础权重**：若两个非旁白角色 $u, v$ 出现在同一章节，边权 $w(u, v) \mathrel{+}= 10$；
   - **同场紧邻对话强排斥权重**：在同一章节内按原文位置排序的非旁白对白序列中，若角色 $u$ 与角色 $v$ 的发言间隔 $\Delta_{\text{atom}} \le 6$ 个原文块（即处于同一段对话交锋场景），每次交替对话令边权 $w(u, v) \mathrel{+}= 100$。
2. **Welsh-Powell 贪心图着色与打分函数**：
   对共享池中的所有配角按冲突图加权度 $\deg_w(u) = \sum_{v} w(u, v)$ 与台词量降序排列，依次为每个角色 $r$ 评估共享池候选音色 $v$ 的综合得分：
   $$\text{TotalScore}(r, v) = \text{AcousticMatchScore}(r, v) - \text{ConflictPenalty}(r, v) - \text{GlobalReusePenalty}(v)$$
   其中：
   - $\text{AcousticMatchScore}(r, v)$：基础六维声学画像匹配分 + 声部行当匹配加成（同声部 $+45$ 分，同性别跨龄 $+15$ 分，跨性别 $-120$ 分）；
   - $\text{ConflictPenalty}(r, v)$：若音色 $v$ 已被邻接角色 $u \in N(r)$ 选用：
     - 若 $w(r, u) \ge 100$（同场紧邻对话对手戏），施加 **$-600 \times \min(5, \lfloor w(r, u)/100 \rfloor)$** 的强排斥惩罚；
     - 若 $10 \le w(r, u) < 100$（同章非紧邻共现），施加 **$-120$** 的中度惩罚；
   - $\text{GlobalReusePenalty}(v) = 35 \times \text{usageCount}(v)$：确保当存在多个同声部音色时，配角均匀分布到不同音色上，而非坍缩至单一最高分音色。

### 4.4 模式感知微韵律与确定性种子分化（`computeMicroProsodyAndSeed`）

当可用音色极少（如仅有 5 个系统音色配 50 个角色）或大量同类龙套共用同一音色时，通过 `computeMicroProsodyAndSeed` 在声学韵律维度拉开听感差异，同时严格遵守后端 `SafeVoiceEntry.mode` 合成契约：

1. **核心主角与旁白（或某音色的第 1 位使用者）**：
   保持基准语速 `allowedSpeed = 1.0`，`callerSeed = nil`。
2. **共用同一 `system` 音色的第 2..N 位配角**：
   基于 `role.id` 与 `slotIndex` 的确定性 SHA-256 字节摘要，从预设微语速档位序列：
   $$[0.94,\ 1.06,\ 0.96,\ 1.04,\ 0.92,\ 1.08]$$
   中确定性选取 `allowedSpeed`（并结合角色人设中的慢速/快速倾向微调，严格钳制在 `[0.92, 1.08]` 区间），同时分配确定性 `callerSeed`。
3. **共用同一 `clone` / `design` 音色的第 2..N 位配角**：
   由于克隆音色在后端要求固定语速 `1.0` 以保障声纹保真度，系统**强制锁定 `allowedSpeed = 1.0`**，并按槽位循环分配确定性采样种子 `[101, 202, 303, 404]`，使不同配角在保持声纹稳定的同时呈现细微呼吸与停顿差异。
4. **合成管线透传（`AudiobookProductionController.swift`）**：
   在 `renderSingleFragmentWithFiniteRetry` 中将原先硬编码的 `speed: policy.defaultSpeed` 替换为 `let effectiveSpeed = binding.allowedSpeed`，使微语速真正作用于 TTS 合成产物。

### 4.5 零台词角色门禁豁免与按声部行当批量换绑

1. **零台词角色门禁豁免（`AudiobookCastController.confirmCast`）**：
   在 `confirmCast` 中统计全书已归属对白块数量 `dialogueCounts`。仅对 `role.isNarrator || dialogueCounts[role.id, default: 0] > 0` 的发声角色強制校验 `voiceBindings[role.id] != nil`；全书 0 台词的仅提及背景人物即使未绑定音色，也不再阻塞 `confirmCast` 门禁。
2. **按声部行当一键批量配声（`AudiobookCastController.batchBindArchetypeVoice`）**：
   支持按指定 `AudiobookVoiceArchetype`（如「沉稳中年男声」）将全书所有该行当的配角/群演（默认 `onlyMinorRoles = true` 保护核心主角不被覆盖，或 `onlyUnbound = true` 仅填充未配声角色）一键绑定到指定目标音色，自动开启 `allowSharedMinorVoice = true` 并为第 2..N 个角色自动注入微语速/种子错位。

---

## 5. 可扩展 UI/UX 交互规范（100+ 音色与大规模角色工作台）

### 5.1 有声书工作台右侧「人物与配声检查器」（`AudiobookBookWorkspaceView.swift`）

1. **顶部剧组统计与五维筛选胶囊条（`CastFilterScope`）**：
   - 实时展示：`主角独占 X · 配角共享 Y · 同场撞音 Z`；
   - 提供五个快速筛选胶囊：`全部`、`核心主角`、`本章登场`、`未配声`、`同场冲突`（仅当存在同场紧邻对话共用同一音色时高亮出现）。
2. **「按行当批量配声」快捷菜单**：
   - 按六大声部行当（`AudiobookVoiceArchetype.allCases`）列出当前书中各行当的配角人数，支持一键将某个可用音色批量赋给该行当的所有配角或仅未配声配角。
3. **角色卡片增强与同场撞音预警条**：
   - 每张角色卡片头部显示 `层级胶囊（核心主角/重要配角/龙套群演）`、`声部行当胶囊` 与 `N 句 · M 章` 统计；
   - 若该角色与同场紧邻对话的另一角色共用了同一 `voiceID`，卡片内显示醒目的注意色预警条：`与同场对手戏角色「XXX」共用了同一音色，建议点击下方选角器更换`。
4. **智能选角浮层（`AudiobookVoicePickerPopover`）替换原生扁平 `Menu`**：
   - 彻底移除原有的扁平 `Menu`，改为 390pt 宽度的专业选角 Popover：
     - **顶部实时搜索框**：支持按音色名称、ID、风格标签搜索；
     - **作用域切换器**：`智能推荐`、`星标收藏`、`本书专用`、`全部活跃`；
     - **六大声部行当过滤胶囊**：打开 Popover 时默认高亮提示当前角色的推断声部行当，支持一键切回「全部声部」；
     - **占用状态与行内试听**：每行音色清晰展示 `当前已绑`、`主角「XXX」独占（不可共享）`、`配角共享 ×N` 或 `空闲可用`，右侧提供一键试听按钮；
     - **微语速滑块与跳转设计新音色**：底部内置 `0.92x ~ 1.08x` 微语速调节滑块（`system` 音色可用）及「AI 为此角色设计专属新音色」「录音克隆新音色」快捷入口。

### 5.2 定制音色自动归入「本书专用」与全局音色库升级（`CreatorSurfaceViews.swift`）

1. **有声书定制音色自动注册为 `.bookExclusive`**：
   在 `AudiobookWorkflowModel.completeVoiceRoundTrip` 中，当用户从有声书角色卡片跳转至「AI 设计新音色」或「录音克隆」并保存返回时，系统自动调用：
   ```swift
   VoiceCatalogStore.shared.registerBookExclusiveVoice(
       voiceID: voiceID,
       bookID: context.bookID,
       bookTitle: bookTitle,
       roleID: context.roleID,
       roleName: roleName,
       archetype: roleArchetype,
       creationSource: .voiceDesign
   )
   ```
   使该音色默认归属于当前书籍剧组专用池，不会污染其他书籍或演播台的默认通用音色列表。
2. **全局音色库（`VoiceLibraryView`）四级作用域与六维声部过滤**：
   - 顶栏新增四级作用域分段控件：`通用活跃`、`星标收藏`、`剧组专用`、`已归档`；
   - 第二行新增六大声部行当横向胶囊过滤条（`全部声部 / 青年男声 / 沉稳中年男声 / 苍老老者男声 / 清亮青年女声 / 成熟温柔女声 / 老妪与童声`）；
   - 每张音色卡片支持点击 `★` 收藏、显示 `声部行当胶囊` 与 `《书名·角色名》专用` 溯源徽标，并提供右键菜单（或更多菜单）生命周期操作：
     - **晋升为全局通用音色**（将 `.bookExclusive` 音色一键开放给所有书籍与演播台复用，同时保留来源书籍溯源标记）；
     - **手动指定声部行当**（覆盖自动分类结果）；
     - **归档音色 / 恢复音色**（将不再使用的旧剧组音色移入冷备归档库）。
3. **演播台（`DubbingDeskView`）音色选择器净化**：
   自动过滤掉其他书籍的 `.bookExclusive` 专用音色与 `.archived` 归档音色，并将星标收藏音色置顶排序。

---

## 6. 涉及源文件清单与自动化验收矩阵（AC1～AC10）

### 6.1 核心代码改动映射表

| 模块层级 | 源文件路径 | 核心新增/修改内容 |
| :--- | :--- | :--- |
| **领域模型与音色目录** | `macos/SpeechRailApp/SpeechRailApp/AudiobookDomain.swift` | 新增 `AudiobookRoleTier`、`AudiobookVoiceArchetype`、`AudiobookRoleDialogueStats`、`VoiceAssetScope`、`VoiceCreationSource`、`VoiceAssetMetadata`、`VoiceCollection`、`VoiceTaxonomyClassifier`、`VoiceCatalogStore` 及 `AudiobookCharacter.inferredVoiceArchetype(peers:)` |
| **排演算法与图着色** | `macos/SpeechRailApp/SpeechRailApp/AudiobookCastRegistry.swift` | 实现 `computeRoleDialogueStats`（帕累托分层）、`buildSceneConflictGraph`（同场紧邻对话冲突图）、`recommendVoiceBindings`（作用域过滤 + 双池隔离 + Welsh-Powell 图着色）与 `computeMicroProsodyAndSeed` |
| **配声控制器与门禁** | `macos/SpeechRailApp/SpeechRailApp/AudiobookCastController.swift` | 实现 `batchBindArchetypeVoice`（按声部行当批量配声）与 `confirmCast` 零台词背景角色门禁豁免 |
| **TTS 合成控制器** | `macos/SpeechRailApp/SpeechRailApp/AudiobookProductionController.swift` | 在 `renderSingleFragmentWithFiniteRetry` 中透传 `binding.allowedSpeed` |
| **工作台视图模型** | `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift` | 新增 `CastFilterScope`、`roleStatsByID`、`filteredCharacters`、`sceneConflictPartnerNames`、`batchBindArchetype`、`updateRoleAllowedSpeed`，并在 `completeVoiceRoundTrip` 中自动注册 `.bookExclusive` 专用音色 |
| **有声书工作台视图** | `macos/SpeechRailApp/SpeechRailApp/AudiobookBookWorkspaceView.swift` | 新增剧组统计与五维筛选条、按行当批量配声菜单、同场撞音预警条与 `AudiobookVoicePickerPopover` |
| **音色库与演播台视图** | `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift` | `VoiceLibraryView` 新增四级作用域 Tab、六大声部胶囊、星标收藏、专用溯源徽标与晋升/归档菜单；`DubbingDeskView` 接入通用活跃音色过滤 |
| **自动化验收测试** | `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookCastTests.swift` | 新增覆盖 `AC1～AC10` 的 4 个综合自动化验收测试方法，与既有 7 个回归测试共同构成 11 项全通过测试套件 |

### 6.2 验收标准与自动化测试映射矩阵（AC1～AC10）

| 验收项编号 | 验收场景（GIVEN / WHEN） | 通过判据（THEN 强制断言） | 对应自动化测试方法 | 状态 |
| :--- | :--- | :--- | :--- | :--- |
| **AC1 · 帕累托自适应主次分层** | 全书含 1 旁白、3 高频主角（各 20 句台词）、25 个仅说 2 句台词的配角及 5 个 0 台词背景人物，可用音色数为 6 | 仅旁白与 3 个高频主角 `allowSharedMinorVoice == false`；25 个 2 句配角与 5 个 0 台词人物全部自动标为 `isMajor == false && allowSharedMinorVoice == true` | `AudiobookCastTests.testAC1_ParetoAdaptiveRoleStratification` | **PASS** |
| **AC2 · 50 角色 vs 5 音色双池零死锁全绑定** | 全书含 50 个角色（1 旁白 + 2 主角 + 47 配角），可用音色库仅有 5 个音色 | 全部 50 个角色 100% 成功生成推荐并完成 `bindVoice`，零 `.duplicateVoiceRequiresSharedMinorConsent` 异常；旁白与 2 主角的 3 个独占音色绝不被配角侵占 | `AudiobookCastTests.testAC2_50RolesVs5VoicesDualPoolZeroDeadlockAndAC6_SilentRoleExemption` | **PASS** |
| **AC3 · 同场对手戏零撞音** | 同一章节中配角「张掌柜」与「李掌柜」（同为中老年男性声部）在相邻段落交替对话 12 次，共享池有 $\ge 2$ 个可用音色 | 「张掌柜」与「李掌柜」分配到的 `voiceID` 严格不相等（`bindingA.voiceID != bindingB.voiceID`） | `AudiobookCastTests.testAC3_ScenePartnerGraphColoringAndAC4_MicroProsodyAndAC5_BatchArchetypeBinding` | **PASS** |
| **AC4 · 模式感知微语速与克隆种子错位** | 多个配角共用同一 `system` 音色，另有多个配角共用同一 `clone` 音色 | 共用 `system` 音色的配角获得差异化 `allowedSpeed`（`0.92x ~ 1.08x`）；共用 `clone` 音色的配角 `allowedSpeed` 严格锁定 `1.0` 且 `callerSeed` 互不相同 | `AudiobookCastTests.testAC3_ScenePartnerGraphColoringAndAC4_MicroProsodyAndAC5_BatchArchetypeBinding` | **PASS** |
| **AC5 · 按声部行当一键批量换绑** | 全书有多个 `matureMale` 配角与属于 `matureMale` 的核心主角 | 调用 `batchBindArchetypeVoice` 后所有中老年男配角全部换绑至目标音色并开启共享，核心主角保持原独占音色不被覆盖 | `AudiobookCastTests.testAC3_ScenePartnerGraphColoringAndAC4_MicroProsodyAndAC5_BatchArchetypeBinding` | **PASS** |
| **AC6 · 零台词背景角色不阻塞确认门禁** | 全书所有实际有对白归属的角色均已绑定音色，仅剩 2 个 `dialogueAtomCount == 0` 的仅提及背景角色未绑定 | `confirmCast` 正常通过，不抛 `.missingVoiceBindings` 异常 | `AudiobookCastTests.testAC2_50RolesVs5VoicesDualPoolZeroDeadlockAndAC6_SilentRoleExemption` | **PASS** |
| **AC7 · 书籍专用音色跨书隔离与本角优先绑定** | 音色库共 120 个音色（含《书籍 A》40 个专用音色、《书籍 B》30 个专用音色、50 个全局通用音色） | 在《书籍 A》中选角时，《书籍 B》的 30 个专用音色被 100% 隔离；且《书籍 A》内为特定角色定制的专用音色以最高优先级自动匹配回该角色 | `AudiobookCastTests.testAC7_AC8_AC9_AC10_100PlusVoiceScopeIsolationPromotionTaxonomyAndCollections` | **PASS** |
| **AC8 · 专用音色一键晋升至全局通用库** | 音色初始为《书籍 A》专用音色（`scope == .bookExclusive`），执行 `promoteToGlobalReusable` | 该音色 `scope` 更新为 `.globalReusable`（保留 `originBookTitle` 溯源信息），并立即对《书籍 B》和全局通用池可见 | `AudiobookCastTests.testAC7_AC8_AC9_AC10_100PlusVoiceScopeIsolationPromotionTaxonomyAndCollections` | **PASS** |
| **AC9 · 100+ 音色六大声部行当 100% 自动分面归类** | 120 个混合了中英文描述、`system/clone` 模式的音色列表 | 每个音色均被 `VoiceTaxonomyClassifier` 确定性归入六大声部行当之一 | `AudiobookCastTests.testAC7_AC8_AC9_AC10_100PlusVoiceScopeIsolationPromotionTaxonomyAndCollections` | **PASS** |
| **AC10 · 剧团音色包优先选角与批量归档** | 创建剧团音色包设为本书 `preferredCollectionID`；将旧书专用音色批量归档（`.archived`） | 智能配声优先选用首选剧团音色包内的音色；已归档音色从活跃选角器中 100% 隐藏 | `AudiobookCastTests.testAC7_AC8_AC9_AC10_100PlusVoiceScopeIsolationPromotionTaxonomyAndCollections` | **PASS** |
