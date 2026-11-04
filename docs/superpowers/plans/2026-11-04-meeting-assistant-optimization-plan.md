---
title: "SpeechRail 会议助手模块深度优化与多维审查实施方案"
status: completed
date: 2026-11-04
scope: "macos/SpeechRailApp (MeetingSession, SpeakerLabeling, SpeakerTextStatistics, MinutesGenerator, MeetingView*, MinutesReviewView, MeetingKnowledgeLibraryView, InnerOSDrawer)"
---

# SpeechRail 会议助手模块深度优化与多维审查实施方案

本方案对 `SpeechRail` **会议助手（Meeting Assistant）**模块执行算法、UX、UI、全生命周期用户旅程及行业最佳实践对标的深度分析，并经过架构契约、数据库兼容、并发安全、快捷键焦点守卫、渐进式披露及崩溃恢复指纹幂等性六维审查后定稿。

---

## 1. 行业最佳实践对标与产品边界适配

`SpeechRail` 会议助手的核心架构约束为：**无会议机器人（Bot-free）、原始 PCM 音频不落盘（Zero-PCM Persistence）、文字记录与结构化证据沉淀于本机 SQLite、首屏傻瓜化与渐进式披露、全部界面采用自然用户语言**。在此边界下，对标行业主流产品的取舍与转化如下：

| 体验维度 | 行业标杆实践 | 现有实现差距（痛点） | SpeechRail 转化与落地方案 |
| :--- | :--- | :--- | :--- |
| **会前准备与上下文衔接** | **Granola Pre-meeting Briefs**：会前快速回顾上场遗留问题与未完成事项；**MacWhisper**：极简音源选择与热启动。 | `MeetingKnowledgeLibraryView` 已实现完整的「会前准备稿（`prepSheet`）」与「未完成事项（`openItemsSheet`）」，但会前首屏 `MeetingViewRecordLibrary.swift` 仅展示「全部知识库」，用户开会前无法一键调阅准备稿。 | 在 `MeetingViewRecordLibrary.swift` 头部提供**「会前准备稿」**与**「全部知识库」**双入口，支持从会前工作台一键拉起跨会议待跟进事项与未决问题。 |
| **无音频场景下的说话人认领** | **飞书妙记 / MacWhisper**：提供说话人占比条与快速认领；传统软件依赖点击回放录音听声辨人。 | 因 `SpeechRail` 不落盘原始音频，会后无法听音辨人；而 `SpeakerLabelingView.swift` 仅显示 `说话人 1 · 12 段`，无任何台词上下文，用户难以回忆 `说话人 1` 是谁；`SpeakerTextStatistics.swift` 仅有纯数字百分比，无可视化占比条。 | 1. 在 `SpeakerTextStatistics.swift` 新增**高辨识度代表句提取算法**（过滤“嗯/好的/收到”等寒暄碎片，按有效实词长度与信息密度提取代表原话与时间码）；<br>2. 在 `SpeakerLabelingView.swift` 展示每位说话人的代表句摘录，并在 `SpeakerTextSharePanel` 增加可视化水平占比条；<br>3. 点击会中转写行说话人标签选择「重命名」时，直接传入 `initialEditingLabel` 自动聚焦该说话人输入框。 |
| **会中实时重点留痕与防抢焦** | **Granola / 飞书妙记**：会中随时一键标记重点时刻，会后按重点快速复盘；实时转写支持防抢焦回看与筛选。 | `MeetingSession.swift` 对流式 `partial` 缺少类似 `CaptionPartialStability` 的单帧尾部防回退稳定化；会中缺乏「一键记重点（Bookmark）」与「仅看重点」过滤能力。 | 1. 在 `MeetingSession.swift` 流式 `partial` 链路接入 `CaptionPartialStability.stabilizedDisplayPartial`，消除 `rollback_tokens` 引起的单帧末尾抖动；<br>2. 在 `MeetingSession` 新增会话级重点标记（`bookmarkedLineIDs` + 状态栏 `⌘B` 一键记重点 + 未落定句预约标记 + 行内星标切换）；<br>3. 在会中 `MeetingViewLiveTranscript.swift` 与会后 `MeetingViewPostMeeting.swift` 支持「★ 仅看重点」筛选，并在 `MinutesGenerator` 补充流中标注用户重点行以强化关键结论提取。 |
| **会后纪要局部恢复与分层复制** | **Notion AI Meeting Notes / Otter.ai**：长会议分块失败支持局部增量重试；支持按用途一键复制不同粒度内容。 | `MinutesGenerator.swift` 已完整实现 `retryFailedWindows` 与 `retryableWindowCount`（分窗局部重试），但 `MeetingViewPostMeeting.swift` 未暴露入口，导致长会议单个窗口超时后用户只能整场重跑；复制按钮仅支持单一复制。 | 1. 在 `MeetingViewPostMeeting.swift` 当 `meeting.minutes.retryableWindowCount > 0` 时，显式展示**「重试未完成片段（N 个窗口）」**入口；<br>2. 将会后复制升级为支持「复制纪要全文」、「复制纪要 + 文字记录」及「仅复制重点发言」的分层能力。 |
| **Design Tokens 与无障碍合规** | **macOS 26 Design System**：全量使用语义 Token，支持 Escape 关闭、焦点守卫与 Reduce Motion。 | `MinutesReviewView.swift`、`MeetingKnowledgeLibraryView.swift`、`InnerOSDrawer.swift` 存在 20+ 处裸写 `.font(.caption)` / `.font(.body)` / `.font(.title2)` / `minHeight: 320` 等硬编码视觉值。 | 全面清理会议模块视图中的裸写字体与尺寸常量，100% 收敛至 `SpeechRailDesignTokens.Typography` 与 `Layout`，补齐无障碍标签与 Escape 键处理。 |

---

## 2. 四大维度深度优化设计规格

### 2.1 算法与会话内核优化

#### (A) 流式预览（Partial）单帧防缩回稳定化
- **定位文件**：`macos/SpeechRailApp/SpeechRailApp/MeetingSession.swift`（第 100–130 行、第 1129–1147 行）
- **根因分析**：流式 ASR 在滑动窗口边界受 `rollback_tokens` 影响，偶发出现同一 `itemID` 的新一帧 `partial` 比上一帧短 1~5 个字符或句尾标点瞬时闪烁。`CaptionSession` 已通过 `CaptionPartialStability.stabilizedDisplayPartial` 解决该问题，但 `MeetingSession` 仍直接透传 `previewLedger.visiblePartial`。
- **改造方案**：
  - 在 `MeetingSession` 中维护 `lastStabilizedPartialItemID: String?` 与 `partialRollbackHeldOnce = false`；
  - 当收到 `.partial` 或 `.partialSnapshot` 时，通过 `CaptionPartialStability.stabilizedDisplayPartial(currentDisplayed: partialText, incoming: previewLedger.visiblePartial, sameItem: lastStabilizedPartialItemID == itemID, alreadyHeldOnce: &partialRollbackHeldOnce)` 产出稳定文本；
  - 在 `.completed`、`.failed`、`releaseCapture`、`resetForNewMeeting` 时同步复位稳定化状态。

#### (B) 无音频场景下的高辨识度代表句评分算法
- **定位文件**：`macos/SpeechRailApp/SpeechRailApp/SpeakerTextStatistics.swift`（第 1–95 行）
- **根因分析**：用户在不保存录音的前提下认领说话人，最需要的是“这个人典型说了哪句话”以及“他第一次开口是在第几分钟”。若直接取第一句，往往是“喂，听得到吗”、“好的”等毫无身份辨识度的寒暄。
- **算法设计**：
  - 在 `SpeakerTextStatistics` 中新增：
    - `firstTimestampBySpeaker: [String: TimeInterval]`：记录每位说话人首次定稿发言的起始时间码（当具备可靠时间码时记录）；
    - `representativeExcerptBySpeaker: [String: String]`：按信息量评分选出每位说话人最具代表性的一句发言。
  - **代表句评分函数 `representativeScore(for text: String) -> Int`**：
    1. 剥离首尾空白与末尾标点后，若命中口语寒暄集合（`好的/是的/嗯/嗯嗯/对/没错/可以/行/走吧/行了/收到/明白/听得到吗/喂/你好/大家好/谢谢`）或有效字符数 `<= 2`，得分为 `1`（仅在没有任何其他句子时兜底）；
    2. 有效字符长度在 `10...48` 之间得基础高分 `+30`（长度适中、语义完整、适合卡片单行/双行预览）；`5...9` 字得 `+15`；超过 `48` 字得 `+22`（展示时截断至 46 字加 `…`）；
    3. 包含数字（日期、金额、排期、指标）或拉丁专名缩写额外 `+8`；
    4. 包含决策/行动语义词（`决定/确认/负责/排期/下周/方案/问题/建议/需要/目标`）额外 `+6`。

#### (C) 会中重点标记（Bookmarks）与纪要生成证据加权
- **定位文件**：
  - `macos/SpeechRailApp/SpeechRailApp/MeetingSession.swift`
  - `macos/SpeechRailApp/SpeechRailApp/MinutesGenerator.swift`（第 1040–1146 行）
- **根因分析**：用户在会中标记的重点行代表人为确认的高价值信息（往往是核心决议、关键数字或待办承诺），但若仅停留在 UI 标记而不传给 `MinutesGenerator`，大模型在长会议分窗提炼时可能会忽略用户最关心的段落。
- **算法与架构设计**：
  1. **非侵入式持久化存储**：在 `MeetingSession` 中提供 `bookmarkedLineIDs: Set<String>`，按 `sessionID` 存储在 `UserDefaults`（键：`speechrail.meeting.bookmarks.<sessionID>`），并提供 `isBookmarked(lineID:)`、`toggleBookmark(lineID:)`、`bookmarkLatestOrNextLine()`（若当前已有定稿行则标记最新一行并返回其序号；若首句尚未定稿则置 `pendingBookmarkOnNextCommit = true`，待下一句定稿落库时自动标记）。
  2. **纪要生成联动（保持无重点时 Fingerprint 100% 幂等）**：
     - 在 `MinutesGenerator` 中新增 `bookmarkedLinesPromptSection(units: [MinutesSourceUnit], bookmarkedLineIDs: Set<String>) -> String`：当 `bookmarkedLineIDs` 为空时返回空字符串，确保无重点标记时 `MinutesGenerator.prompt` 与 `MinutesGenerator.inputFingerprint` 的 SHA-256 指纹与既有契约完全一致（保障 `MeetingMinutesJobRecoveryTests` 崩溃恢复指纹校验零偏差）；
     - 当 `bookmarkedLineIDs` 非空时，将命中的来源单元格式化为 `【用户在会中标记的重点发言（请优先审视其中是否包含决议、待办或未决问题，引用时仍使用对应 [uX] 编号）】` 并入 `supplements` 输入流，既自动参与 `inputFingerprint` 哈希计算，又无需改动 `MinutesCandidateCodec` 的严格 JSON Schema。
  3. **指纹一致性**：由于重点发言段落随 `supplements` 一并进入 `inputFingerprint(units:windows:supplements:)`，用户在会后增删重点标记并点击「重新生成纪要」时，新版本将自动记录更新后的输入指纹。

---

### 2.2 全链路用户旅程与 UX 优化

#### 阶段一：会前准备（`MeetingViewSourceSetup.swift`、`MeetingViewRecordLibrary.swift`、`MeetingKnowledgeLibraryView.swift`）
1. **会前准备稿直达入口**：
   - 在 `MeetingViewRecordLibrary.swift` 的 `libraryCard` 顶栏，当存在历史会议（`!recent.isEmpty`）时，除「全部知识库」外提供**「会前准备稿」**快捷按钮，点击后打开知识库并自动弹出 `prepSheet`（通过 `MeetingKnowledgeLibraryView(coordinator: session, initialSheet: .prep)` 传入初始面板参数）。
2. **音源控件无障碍与状态反馈**：
   - 为 `MeetingViewSourceSetup.swift` 的麦克风开关胶囊、应用音频抽屉按钮补齐 `.accessibilityLabel` 与 `.accessibilityValue`。

#### 阶段二：会中实时协同（`MeetingViewStatusBar.swift`、`MeetingViewLiveTranscript.swift`、`MeetingViewInspector.swift`、`MeetingViewSpeakerLabeling.swift`）
1. **状态带「★ 记重点」快捷动作（`⌘B`）**：
   - 在 `MeetingViewStatusBar.swift` 的 `statusBar` 右侧（`暂停录制` 按钮旁），新增**「记重点」**（`star` / `star.fill`）按钮，绑定快捷键 `⌘B`（当文本输入框未聚焦时生效），点击立即标记最新一句（或预约正在识别的当前句），并通过轻量状态回执告知用户「已标记重点」。
2. **实时转录流重点星标与会中筛选**：
   - 在 `MeetingViewLiveTranscript.swift` 的 `CardHead` 中，当本场已有重点标记（`!meeting.bookmarkedLineIDs.isEmpty`）时，展示轻量过滤胶囊 `「★ 仅看重点 (\(meeting.bookmarkedLineIDs.count))」`；
   - 在 `liveLine(_ line:)` 右侧与右键菜单（`.contextMenu`）中提供「标记为重点 / 取消重点标记」，已标记重点的行在时间码旁显示主色星标徽章与柔和底色强调。
3. **会中说话人一键直达改名**：
   - 在 `MeetingViewLiveTranscript.swift` 点击行内 `speakerColumn` 的「重命名说话人…」时，记录 `speakerLabelToEdit = label` 并打开 `SpeakerLabelingSheet`，`SpeakerLabelingPanel` 接收 `initialEditingLabel` 自动展开该说话人的姓名输入框，消除二次点击摩擦。
4. **会中右栏实时重点计数**：
   - 在 `MeetingViewInspector.swift` 的 `thisMeetingCard` 中，当存在重点标记时展示 `inspectorRow("重点标记", "\(meeting.bookmarkedLineIDs.count) 处")`。

#### 阶段三：会后复盘、认人与纪要整理（`MeetingViewPostMeeting.swift`、`SpeakerLabelingView.swift`、`SpeakerTextStatistics.swift`）
1. **无音频「代表句 + 首次出场时间 + 占比条」认人体验**：
   - 在 `SpeakerLabelingView.swift` 的 `SpeakerLabelingPanel` 中，异步加载当前会话的 `SpeakerTextStatistics`，在每位说话人行下展示其**代表性原话摘录**（如 `「“…”」`）与首次发言时间码；
   - 在 `SpeakerTextStatistics.swift` 的 `SpeakerTextSharePanel` 中，为每位说话人渲染直观的水平占比进度条与有效字数，直观呈现会中发言分布。
2. **分窗失败局部重试入口激活**：
   - 在 `MeetingViewPostMeeting.swift` 的 `minutesBody` 中，当 `meeting.minutes.retryableWindowCount > 0` 且 `!meeting.minutes.isBusy` 时，显示提示条与**「重试未完成片段（\(meeting.minutes.retryableWindowCount) 段）」**按钮，直接调用 `meeting.minutes.retryFailedWindows(...)`，无需整场重跑。
3. **会后文字记录重点过滤与分层复制**：
   - 在 `MeetingViewPostMeeting.swift` 的 `transcriptFilterBar` 中增加「★ 仅看重点」筛选开关（当该场会议存在重点标记时显示）；
   - 在会后表头提供分层复制菜单（在纪要页签支持「复制纪要全文」与「复制纪要 + 文字记录」；在文字记录页签支持「复制当前显示记录」与「仅复制重点记录」）。

#### 阶段四：跨会议知识库与 Design Tokens 全面对齐（`MinutesReviewView.swift`、`MeetingKnowledgeLibraryView.swift`、`InnerOSDrawer.swift`）
1. **清理全部裸写字体与尺寸常量**：
   - `MinutesReviewView.swift`：替换 `.font(.callout)`、`.font(.body)` 为 `SpeechRailDesignTokens.Typography.callout` / `body`，并为 `supplementSheet` 增加 `.onKeyPress(.escape)`。
   - `MeetingKnowledgeLibraryView.swift`：将 20+ 处 `.font(.title2)`、`.font(.headline)`、`.font(.body)`、`.font(.callout)`、`.font(.caption)`、`.font(.caption2)` 统一替换为 `SpeechRailDesignTokens.Typography` 对应语义 Token。
   - `InnerOSDrawer.swift`：将 `sentencePicker` 中的 `.font(.headline)`、`.font(.callout)`、`.font(.body)` 与 `minHeight: 320` 统一收敛至 `SpeechRailDesignTokens`。

---

## 3. 多维度方案审查记录（Multi-Dimensional Review）

在进入编码实施前，对上述设计执行以下六个维度的严格交叉审查与修正：

| 审查维度 | 审查发现的潜在风险点 | 修正与加固措施（已纳入定稿） |
| :--- | :--- | :--- |
| **1. 协议与数据契约边界** | 若直接在 `MeetingSession` 中把相邻同说话人 `TranscriptLine` 物理合并为一条数据库行，会破坏 `segment_uid -> lineID` 的声纹归属回写坐标以及 `MinutesSourceUnit` 的行级证据锚点。 | **严格保持底层 `TranscriptLine` 一 `item` 一行的存储契约不变**；仅在流式 `partial` 上屏阶段接入 `CaptionPartialStability` 防缩回，不篡改已落库行的 `lineID` 与时间窗口。 |
| **2. 数据库 Schema 兼容性** | 若为会中重点标记修改 SQLite `transcript_lines` 表结构，将涉及全量迁移、备份归档包（`SessionStoreArchivePackage`）格式变更与旧库兼容风险。 | 采用 `UserDefaults` 按 `speechrail.meeting.bookmarks.<sessionID>` 集合轻量持久化重点行 ID，**零 Schema 破坏、100% 兼容现有归档包与单测**。 |
| **3. 并发安全与主线程性能** | `SpeakerTextStatistics` 若在每次 `partial` 到来时重算代表句，会导致主线程高频遍历全文。 | `SpeakerTextStatistics` 仅在定稿行（`status == .final`）或归属修订（`transcriptRevision` / `attributionRevision`）变更时于 `Task.detached` 后台线程计算，且带 150ms 防抖合并，不阻塞 `@MainActor`。 |
| **4. 快捷键冲突（IME 组字守卫）** | 会中新增 `⌘B` 记重点快捷键，若用户在会中私聊（`InnerOSDrawer`）或改名框中输入文字时按下快捷键，可能产生误触。 | 遵循 `ReviewShortcutPolicy`，在 `MeetingView` 监听 `.speechRailTextInputFocusChanged` 通知，当文本输入控件聚焦时禁用会话级 `⌘B` 快捷键。 |
| **5. 傻瓜化与渐进式披露** | 若在没有重点标记的会议里常驻显示“仅看重点 (0)”按钮，或在没有失败窗口时显示“局部重试”，会制造界面噪音。 | 「★ 仅看重点」过滤胶囊仅在当前会议 `bookmarkedCount > 0` 时渐进显现；「重试未完成片段」仅在 `retryableWindowCount > 0` 时显现，首屏保持极简。 |
| **6. 崩溃恢复指纹幂等性（`inputFingerprint`）** | `MeetingMinutesJobRecoveryTests` 在测试崩溃恢复时会预先用 `MinutesGenerator.inputFingerprint(units:windows:supplements: "")` 计算指纹并写入 SQLite，若无条件修改 `MinutesGenerator.prompt` 基础文本会导致恢复时指纹不匹配抛出 `InputCheckError.changed`。 | 当会话无重点标记（`bookmarkedLineIDs.isEmpty`）时，`prompt` 与 `inputFingerprint` 保持原字节级输出不变；仅当存在重点标记时才将重点单元列表合入 `supplements` 参与生成与哈希。 |

---

## 4. 实施文件清单与验证计划

### 4.1 涉及修改的源码文件
1. `macos/SpeechRailApp/SpeechRailApp/SpeakerTextStatistics.swift`：新增代表句评分提取算法、首次发言时间统计与可视化水平占比条。
2. `macos/SpeechRailApp/SpeechRailApp/SpeakerLabelingView.swift`：接入代表句预览展示与 `initialEditingLabel` 自动聚焦编辑。
3. `macos/SpeechRailApp/SpeechRailApp/MeetingViewSpeakerLabeling.swift`：透传 `initialEditingLabel` 至 `SpeakerLabelingPanel`。
4. `macos/SpeechRailApp/SpeechRailApp/MeetingSession.swift`：接入 `CaptionPartialStability` 流式防抖动，新增会中重点标记管理（`bookmarkedLineIDs`、`toggleBookmark`、`bookmarkLatestOrNextLine`）。
5. `macos/SpeechRailApp/SpeechRailApp/MinutesGenerator.swift`：支持合并会中重点标记单元至 `supplements`，并在无重点时保持 `inputFingerprint` 100% 幂等。
6. `macos/SpeechRailApp/SpeechRailApp/MeetingView.swift`：新增会中筛选/说话人编辑状态变量、文本输入焦点守卫与重点标记反馈通知。
7. `macos/SpeechRailApp/SpeechRailApp/MeetingViewStatusBar.swift`：新增会中「★ 记重点（⌘B）」快捷按钮。
8. `macos/SpeechRailApp/SpeechRailApp/MeetingViewLiveTranscript.swift`：新增行内星标标记、右键菜单标记、表头「★ 仅看重点」筛选，以及说话人菜单点击「重命名」直达输入框。
9. `macos/SpeechRailApp/SpeechRailApp/MeetingViewPostMeeting.swift`：新增「★ 仅看重点」筛选、分窗失败局部重试入口（`retryFailedWindows`）及分层复制菜单。
10. `macos/SpeechRailApp/SpeechRailApp/MeetingViewInspector.swift`：在会中与会后信息栏展示重点标记统计。
11. `macos/SpeechRailApp/SpeechRailApp/MeetingViewRecordLibrary.swift` & `MeetingKnowledgeLibraryView.swift`：打通会前工作台一键打开「会前准备稿」，并全面收敛 `MeetingKnowledgeLibraryView.swift` 中的裸写字体 Token。
12. `macos/SpeechRailApp/SpeechRailApp/MeetingViewSourceSetup.swift`、`MinutesReviewView.swift`、`InnerOSDrawer.swift`：收敛硬编码字体/尺寸至 `SpeechRailDesignTokens`，补齐无障碍语义与 Escape 键处理。

### 4.2 自动化测试与编译验证
- 运行 `swift build --disable-sandbox --package-path macos/SpeechRailApp` 验证零编译错误与警告；
- 新增与更新针对代表句提取算法、会中重点标记与预约标记、纪要重点源单元标注及会话生命周期的单元测试，运行 `swift test --disable-sandbox --package-path macos/SpeechRailApp --filter Meeting` 验证全部通过。
