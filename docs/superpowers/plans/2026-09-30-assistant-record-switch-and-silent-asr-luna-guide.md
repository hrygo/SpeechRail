---
title: "语音助手：记录切换卡顿与识别结果静默丢失"
status: in_progress
date: 2026-09-30
---

> 修订记录（2026-09-30 review 后修正）：U1 确定性断言（B5）；U2/U3 顺序依赖（B3）与 §6.1 伪代码 fail-close（B1/B2）；
> 空 itemID 的 failed 策略（B4）；U5 完整引用点清单（B6）；"一次 await 调用"用词（B7）；
> U4 `clearFailure()` 调用点更正（B8）；U6 主次对调（B9）。

## 执行结果（2026-09-30）

| 单元 | 状态 | 落地 |
|---|---|---|
| U1 回归测试 | 已完成 | `AssistantSessionTests` 4 例；修复前 3 红 1 绿，修复后全绿 |
| U3 片段按 item 隔离 | 已完成 | 随 P1 一起提交（`1e96f77a`；B3 允许 U2/U3 合并） |
| U2 空 final 保留 | 已完成 | `1e96f77a` |
| U4 失败在界面可见 | 已完成 | `1e96f77a` |
| U5 一次快照读 | 已完成 | `60d5d55b`（生产代码）+ `f288e689`（回归测试） |
| U7 文档同步 | 已完成 | `18f79e9a`：设计系统 §6 验证矩阵一行；契约 §5.1 补第三条准入语义，4.2.0 → 4.3.0 |
| M1 卡顿测量 | 未做 | 需用户单独授权接管前台窗口 |
| U6 列表行隔离重绘 | 暂缓 | 按 §9.1：M1 未测，不得先改 |
| M2–M4 行为层验收 | 暂缓 | 需真机麦克风与在跑的服务 |
| §7 离屏渲染用例 | 不可行 | 见下 |
| **服务端根因修复** | **已发布并装机** | `06b3570e` + `chore(release): 3.4.1`（`9b070aca`），见附录 A' |
| 服务重装 | 已完成 | 3.4.0 → **3.4.1**；真实 ASR smoke 单句已定稿 |
| App 重装 | 已完成 | 3.4.0/38 → **3.4.1/39**，已归档旧版，待用户验收 |

**§7「`AssistantView` 离屏渲染夹具用例」在本 target 不可行**，已实测确认而非推测：
`SpeechRailAppTests` 没有 `TEST_HOST`／`BUNDLE_LOADER`，进程里没有 `NSApplication`。
探针把一个含 `Text` 与 `Button` 的 `NSHostingView` 离屏渲染并遍历无障碍树，实测
`accessibilityChildren()` 为 0、标签为空——`NSHostingView` 在无 `NSApplication` 时
根本不建无障碍树。因此"断言提示文案出现在 AX 树中"这条断言在本 bundle 里恒为空，
写了也只是假绿。这与项目自己的记录一致：历次离屏走查都是用 `/tmp` 下的独立
`NSHostingView` 工装做的，不是单测 target。U4 的等价验证改为两条结构性判据：
`AssistantSession` 侧注入 `.failed` 后 `lastFailure` 非 nil（有测试），
`AssistantView` 侧 `grep -c lastFailure` ≥ 1 且绑定了提示条；"提示真的出现在屏幕上"
属于 M2–M4 的真机走查范围。

补充的三例取舍回归（`AssistantSessionTests`）：未定稿的半句不进模型
（`streamCount == 0`）、同一 item 的终态重放不重复落库、成功定稿后软提示自己退场。

验证（2026-09-30 20:10–20:16 核验）——

- `scripts/macos_app_test.sh --only-testing SpeechRailAppTests`：**374 项 0 failures / exit 0**；
- `swift test --package-path macos/SpeechRailApp`：**395 tests / 16 suites 通过**（同一批
  新用例在这条门禁里也跑到了，两条 CI 门禁覆盖的是同一份实现）；
- `scripts/macos_app_build.sh --configuration Release`：**BUILD SUCCEEDED**（出货配置编译通过）；
- 四个契约检查脚本（realtime / openapi / user-doc / version consistency）全部 exit 0。

**未跑 UI 自动化**（AGENTS.md 硬约束：未经当次明确授权不运行）。
**未安装 App**：需要发布动作，用户未授权。

### 库读侧基准（2026-09-30 20:19，替代 M1 的一部分）

M1 要接管前台窗口，未获授权。但"库读到底贵不贵"这一半**不需要**接管窗口，
可以拿真实库的一份副本直接量。做法：把 `~/Library/Application Support/SpeechRail/sessions.sqlite3`
（17 条 session / 160 条 line / 12 条 session_change）复制到临时目录，用临时用例打开它，
对行数最多的那条记录（26 行）各跑 200 次，取 p50/p95。基准用例量完已删除，只留结论。

| 路径 | p50 | p95 | max |
|---|---|---|---|
| 四次分别读（原 `openRecord`） | 0.0992 ms | 0.1318 ms | 0.1842 ms |
| 一次快照读（现 `openRecord`） | 0.0538 ms | 0.0670 ms | 0.1117 ms |

**结论：库读侧整条路径在 0.1 ms 量级。** 两者之差约 0.05 ms，比人眼能察觉的
一次界面迟滞（约 100 ms 量级）低三个数量级。这条实测把 §2.3 的第 1 项开销从
"可能的热点"里划掉了，也说明：

- **U5 的可测量收益接近于零。** 它的真正价值是那 4 次串行 `await` 带来的
  **4 次 SwiftUI 状态更新不合并**（这才是"逐段跳变"的机制），而库读本身几乎不花钱。
  U5 仍然该做——它无条件成立，且把更新次数从 4 降到 1——但**不要指望它单独治好卡顿**。
- 卡顿的成因只可能在 SwiftUI 层：§2.3 的第 2 项（`state` 在 `.review` 与 `.live/.ready`
  之间整体翻转，`body` 随之整页拆建）与第 3 项（`libraryRow` 在父 body 里构造，
  选中一变整列重建）。U6 只处理第 3 项。
- 因此 **M1 仍然必要**，但它要回答的问题已经收窄成一个：在"整页拆建"与"整列重建"
  之间占主导的是哪一个。基准用例测不到这一层——SwiftUI 的渲染耗时必须真实渲染才测得到。

# 语音助手两项缺陷实施方案（Luna）

## 1. 问题结论

### P1 麦克风对话：识别文字出现后立即消失，且不进入 LLM / TTS

- **现象**：用户说话，界面出现"正在识别"的文字；话音刚落，文字消失；没有落库、没有模型回复、没有朗读，界面也不给任何提示。
- **预期**：要么这句话被定稿成一轮并继续走 LLM → TTS；要么明确告诉用户"这一句没能定稿"，并保留用户已经说出的话。
- **推荐修复方向**：三处叠加（见 §2）。核心是**失败必须可见** + **空 final 不得吞掉已识别文字** + **partial 必须带 item 身份**。

### P2 对话记录：切换会话卡顿

- **现象**：在"对话记录"列表点选不同会话，右侧详情响应迟滞、逐段跳变。
- **预期**：点击后一次到位地切到该会话的复盘内容。
- **推荐修复方向**：把 4 次串行库读合并为 1 次快照读 + 1 次状态写入；列表行隔离重绘。**测量优先于改造**（见 §9 的前置条件）。

---

## 2. 当前实现与根因

### 2.1 P1 根因

#### ① `AssistantView` 从不渲染 `lastFailure`（直接原因）

`AssistantSession` 在 `transcription.failed` 分支写 `lastFailure`（`macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift:1166-1168`），但：

```
$ grep -c lastFailure macos/SpeechRailApp/SpeechRailApp/AssistantView.swift
0
```

同层其它会话都渲染了它：

| 界面 | 位置 |
|---|---|
| 会议 | `MeetingView.swift:1100` |
| 字幕 | `CaptionBandWindow.swift:678`、`CaptionBandWindow.swift:684` |
| 提词器 | `TeleprompterStageView.swift:107`、`TeleprompterStageView.swift:200` |
| **语音助手** | **无** |

因此识别失败对语音助手用户完全静默。

#### ② 空 final 静默吞掉已识别文字（直接原因）

`AssistantSession.swift:1239-1248`：

```swift
private func commitUserTurn(itemID: String, transcript: String, observedAt observed: Date) async {
    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    partialText = nil                                   // ← 先清显示
    defer { if !itemID.isEmpty { itemObservedAt.removeValue(forKey: itemID) } }
    guard !text.isEmpty, let sessionID, let startedAt = sessionStartedAt else { return }   // ← 空文本静默返回
```

`partialText` 在校验之前就被清空，随后空文本直接 return：不落库、不进 `beginReply`、不报错。

空 final 是**契约允许**的正常事件，不是异常：

> `contracts/realtime-openai.md:108` — 「`clear` 是本地丢弃语义（**其后的一次 commit 产生空 final**）」

服务端的空 final 分支在 `src/speechrail/application/realtime_openai.py:1112-1131`（"没有准入语音 → 发空 completed"）与 `:2340-2349`（ASR 终态文本经 `apply_light_itn` 后为空）。

#### ③ `partialText` 是不带 item 身份的全局槽位（设计原因）

`AssistantSession.swift:1153-1168`：

```swift
case .partial(let itemID, let delta):
    partialText = (partialText ?? "") + delta
case .partialSnapshot(let itemID, _, let text, _):
    partialText = text.isEmpty ? nil : text
case .failed(_, let code, let message):
    partialText = nil
```

三处都**不看 `itemID`**。而服务端明确支持一条连接上存在多个并发 item（rollover commit：`realtime_openai.py:865`、`:1024`），客户端 `RealtimeEventState` 也按最多 128 个 item 追踪（`RealtimeASRClient.swift:76`）。于是：

- 迟到的旧 item 事件会覆盖或清空新 item 正在显示的文字（→ "文字立即消失"）；
- `.partial` 会把新 item 的增量追加到旧 item 残留文字后面；
- 契约明确 `speechrail.transcription.hypothesis` 是**可改写全文**（`contracts/realtime-openai.md:110-127`），`partialSnapshot` 必须整段替换，因此不能用"追加"兜底。

#### ④ 放大因素：ASR 终态缺失时同样静默

服务端 `_drain_asr_events` 的 `except Exception` 分支（`realtime_openai.py:2361-2372`）会补发 `transcription_failed`，这条路径被 ① 覆盖后完全不可见。

### 2.2 本机实测证据（2026-09-30 核验）

服务自 18:03 启动至核验时的 `/metrics` 累计值（`curl -s http://127.0.0.1:8201/metrics`）：

```
speechrail_realtime_turn_commits_total{commit_reason="vad_stop",mode="server_vad",outcome="text"}   1
speechrail_realtime_turn_commits_total{commit_reason="client",  mode="server_vad",outcome="empty"}  2
speechrail_realtime_first_hypothesis_total{outcome="partial"}  12
speechrail_realtime_first_hypothesis_total{outcome="missing"}   2
```

即：12 个 item 出过识别文字，真正定稿成一轮只有 1 次，2 次拿到空 final。

记录库侧吻合（`~/Library/Application Support/SpeechRail/sessions.sqlite3`）：18:14:08 那场只落库 2 行（1 条 user + 1 条 assistant），正对应那唯一一次 `outcome="text"`。

服务日志（`~/Library/Logs/SpeechRail/speechrail.log`）显示 18:13:36 与 18:14:08 两次 `/v1/realtime` 连接，第二次成功，第一次在记录库中**没有对应条目、也没有任何行**。

### 2.3 P2 根因

`macos/SpeechRailApp/SpeechRailApp/AssistantView.swift:3894-3903`：

```swift
private func openRecord(_ summary: SessionSummary) async {
    justEndedSessionID = nil
    guard let record = (try? await session.record(id: summary.id)) ?? nil else { return }
    reviewRecord = record
    reviewLines = (try? await session.lines(sessionID: summary.id)) ?? []
    reviewSpeakerNames = (try? await session.speakerNames(sessionID: summary.id)) ?? [:]
    reviewVoiceChanges = (try? await session.voiceChanges(sessionID: summary.id)) ?? []
    inspectorTab = .session
}
```

1. **4 次串行 actor 往返、5 处独立 `@State` 写入**。每次 `await` 返回都触发一次 SwiftUI 更新，4~5 次更新不合并 → 高亮、页头、正文、元信息分几步跳出来。
2. **整页切换无缓存无中间态**。`state`（`AssistantView.swift:142-146`）在 `.review` 与 `.live/.ready` 之间整体翻转，`body`（`AssistantView.swift:172-181`）随之在 `splitArea` 与 `justEndedBand + reviewArea` 之间整体拆建。
3. **列表整列重绘**。`SessionLibraryColumn.libraryRow(_:)`（`SessionDesignSurface.swift:1036`）在父 body 里构造，每次选中变化整列重建；每行都重跑 `Calendar.current` + `Date.formatted`（`SessionDesignSurface.swift:1151-1160`），`summary.duration()` 每行每次渲染都读一次 `Date()`。
4. **首屏多一次切换**。`reload()`（`SessionDesignSurface.swift:1177-1181`）在 `selectedID == nil` 时 `onSelect(first)`，进页面即触发一次完整 `openRecord`。

底层查询本身不重：`SessionStore` 是 actor（`SessionStore.swift:48`），SQLite 不在主线程；`listSessions` / `lines` 都是单条语句（`SessionStore.swift:718`、`:753`）。

---

## 3. 目标行为

### P1

1. 任何识别或朗读失败都在语音助手界面**可见**，且给出下一步动作。
2. `completed` 携带空 transcript 时：
   - 用户本轮说过话（存在非空 `partialText`）→ 该句**不丢失**，以"未完成"形态保留在对话流与记录库，并显示"这一句没能定稿"；
   - 用户没说话（`partialText` 为空）→ 静默跳过，属正常路径。
3. 任何 item 的识别事件**只影响它自己**的可见文字。
4. 保持不变：契约 `contracts/realtime-openai.md` 的事件语义、空 final 的合法性、`final` 行才计入记录库句数与导出的既有口径。

### P2

1. 一次点击 = 一次库读 + 一次状态提交，界面一次到位。
2. 未选中的列表行不因选中变化而重建。
3. 保持不变：`SessionLibraryColumn` 的搜索、空态、删除确认、右键菜单、`reloadToken` 刷新语义。

---

## 4. 推荐解决方案

### P1

| 改动 | 位置 | 理由 |
|---|---|---|
| 新增 `AssistantSession.clearFailure()`，供提示条关闭调用；在 `commitUserTurn` 成功路径清空（`start()` 已有复位，见 `AssistantSession.swift:382`） | `AssistantSession.swift` | `lastFailure` 多处只有写入、缺少统一复位点（`changeVoice` 成功路径除外，见 `:436`） |
| `AssistantView` 在 `liveChatWorkbenchCard` 的 `sendFailure` `NoticeBar` 旁新增一条失败提示，读 `assistant.lastFailure` | `AssistantView.swift:1564-1574` | 与会议 / 字幕 / 提词器对齐；`NoticeBar` 已在同处使用 |
| `commitUserTurn` 调整顺序：空 final 时先判断 `partialText` 是否非空，再决定丢弃还是保留 | `AssistantSession.swift:1245-1248` | 直接堵住"文字被吞" |
| 保留的句子落 `turns`（`isInterrupted: true`）+ 库行 `status: .partial` | 同上 | `LineDraft.status` 已支持 `.partial`（`SessionDomain.swift:679`、`:698`）；`SessionStore.lines(includePartial: false)` 与 `listSessions` 的 `status='final'` 口径不变，记录库句数与导出不受污染 |
| 新增 `partialItemID: String?`，`partial` / `partialSnapshot` / `failed` / `completed` 全部按 item 匹配后才写 `partialText` | `AssistantSession.swift` | 契约要求 `partialSnapshot` 整段替换，不能用追加兜底，必须做身份门禁 |

**取舍**：保留的句子**不进入 LLM/TTS**。`hypothesis` 是可改写全文，不是权威文本；拿它去问模型等于把未确认内容当事实。不生成是正确的，不生成但**必须让用户知道**才是缺陷。

**备选（不推荐）**：空 final 时回退使用 `partialText` 送 LLM。会用未定稿文本驱动模型与朗读，破坏"定稿才进对话"的语义，且用户无法区分哪句是真的。

### P2

| 改动 | 位置 | 理由 |
|---|---|---|
| `SessionStore` 新增 `reviewSnapshot(sessionID:)`，把 4 次 await 合并为一次 await 调用返回 `record + lines + speakerNames + voiceChanges` | `SessionStore.swift` | 4 次往返 → 1 次；快照天然一致。注意是 4 条独立 SELECT 的顺序执行，**不是 SQLite 事务**，不要加 `BEGIN/COMMIT`（B7 修订；`SessionCoordinator` 是 `@MainActor` 类不是 actor） |
| `SessionCoordinator` 转发一层 | `SessionCoordinator.swift` | 保持"界面不直接持有 Store"这条缝 |
| `AssistantView` 用单个 `@State private var review: SessionReviewSnapshot?` 替换 4 个 `@State` | `AssistantView.swift:37-40` | 一次写入 = 一次更新 |
| 抽出 `SessionLibraryRow: View`（`@Equatable`），让差分更新局域化；日期格式化仅在确有必要时再缓存 | `SessionDesignSurface.swift` | 未选中行不重建 |

---

## 5. 详细实施步骤

### U1 · 回归测试先行：空 final 不得吞掉已识别文字

- **文件**：`macos/SpeechRailApp/SpeechRailMacControlTests/AssistantSessionTests.swift`
- **做法**：沿用该文件既有的 `Gate` 与假 `AssistantRealtimeClient`。构造：推入 `partialSnapshot(itemID: "item-1", text: "今天天气")` → 再推入 `completed(itemID: "item-1", transcript: "")`。
- **断言**（确定的终态。原"或"式写法会让测试恒过，禁止使用）：
  `turns.last?.text == "今天天气" && turns.last?.isInterrupted == true`
  && `partialText == nil` && `lastFailure != nil`；
  且库中该 session 有一条 `status == .partial` 的 user 行。
- **完成条件**：测试在当前代码上**失败**（红），证明它确实覆盖了本次缺陷。

### U2 · `commitUserTurn` 顺序修正 + 空 final 保留

- **文件**：`macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift`
- **当前逻辑**：`partialText = nil` → `guard !text.isEmpty, let sessionID, let startedAt = sessionStartedAt else { return }`
- **目标逻辑**：先算 `text`；`text` 为空且 `partialText` 非空时走"保留"分支（追加 `Turn(isInterrupted: true)`、落 `LineDraft(status: .partial)`、写 `lastFailure`、清 `partialText` 后 return）；`text` 为空且 `partialText` 为空时静默 return；其余路径把 `partialText = nil` 放在 `guard` 之后。
- **边界**：`itemID` 去重集合 `committedItemIDs` 的增删时机保持不变（写失败要 `remove` 回滚）；保留分支同样遵守 `observedAt` 时间口径。
- **完成条件**：U1 转绿；既有用例不回归。
- **顺序依赖（B3 修订）**：U2 的保留分支读 `partialText` 时 U3 的 `partialItemID` 门禁尚未存在。
  两种做法二选一，**推荐前者**：(a) U3 先做，或 U2/U3 合并为同一 commit，保留分支条件写成
  `partialItemID == itemID && partialText 非空`；(b) 若坚持 U2 先行，必须在 U2 完成条件里加一句
  "U3 合入前保留分支暂不过滤 item"，把中间态显式化。执行清单 §10 的任务 2/3 顺序随之调整。
- **提交点**：U1 + U2 一起提交（`fix(assistant): 不让空 final 静默吞掉已识别的一句话`）。

### U3 · `partialText` 加 item 身份

- **文件**：`macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift`
- **改动**：新增 `private var partialItemID: String?`。`case .partial` 仅在 `partialItemID == nil || partialItemID == itemID` 时追加并记录 `partialItemID`；`case .partialSnapshot` 同门禁后整段替换；`case .failed` / `case .completed` 仅在匹配时清 `partialText` 与 `partialItemID`。`prepareConversationContext`、`resetToIdleKeepingTurns`、`handleUnexpectedClose` 复位 `partialItemID`。
- **边界**：`RealtimeASRClient` 在同一 item 上已抑制"hypothesis 存在时的官方 delta"（`RealtimeASRClient.swift:1545-1547`），本步不改变该口径。
- **空 itemID 策略（B4 修订）**：`invalid_hypothesis` 等失败的 `itemID` 可能为空字符串
  （`RealtimeASRClient.swift:1563` 附近 `object["utterance_id"] as? String ?? ""`）。
  空 itemID 的 `.failed` **只写 `lastFailure`，不动 `partialText` 与 `partialItemID`**，
  否则半残状态（提示立起但文字残留，或反之）。§6.2 的 `ownsPartial` 按此实现。
- **测试**：在 U1 的文件里加一例——`item-1` 的 `partialSnapshot("今天天气")` 之后来 `item-2` 的空 `partialSnapshot`，断言 `partialText` 仍为 `"今天天气"`。
- **完成条件**：新例通过。
- **提交点**：`fix(assistant): 识别片段按 item 隔离，迟到事件不再清空当前句`。

### U4 · 失败在界面可见

- **文件**：`macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift`、`macos/SpeechRailApp/SpeechRailApp/AssistantView.swift`
- **改动（B8 修订）**：`AssistantSession` 新增 `public func clearFailure()`，供 View 的提示条关闭按钮调用；
  `commitUserTurn` 成功路径、`start(persona:voiceID:mode:)`（已有 `lastFailure = nil`，见 `AssistantSession.swift:382`，
  **不是本方案新增**，不要重复加）调用它。注意 `ask(_:)` 成功路径**不碰** Session 侧 `lastFailure`
  ——`ask` 的打字失败走的是 View 侧 `@State sendFailure`（`AssistantView.swift:28`、`send()` 在 `:2672`），
  与 `lastFailure` 是两套状态，不要混。`beginCapture()` 本体不直接写 `lastFailure`，
  它经 `startPipeline()`；复位点以 `start()` 与各成功路径为准。
  `AssistantView` 在 `liveChatWorkbenchCard` 现有 `sendFailure` `NoticeBar`（`AssistantView.swift:1564-1574`）之后追加一条，
  读 `assistant.lastFailure`，`action` 调 `assistant.clearFailure()`。
- **文案**（面向普通用户，不出现协议 / 模型术语）：`"这一句没能识别完整，请再说一次。"` / `"朗读没能完成，已停止。再试一次可以说："`。
- **边界**：`blocked`（硬受阻卡）与 `lastFailure`（软提示）是两件事，**不要合并**——`blocked` 有重试出口与占用语义。
- **完成条件**：`grep -c lastFailure AssistantView.swift` ≥ 1；注入 `.failed` 后界面出现提示。
- **提交点**：`fix(assistant): 把识别与朗读失败显示在语音助手界面`。

### U5 · `openRecord` 合并为一次快照读

- **文件**：`macos/SpeechRailApp/SpeechRailApp/SessionStore.swift`、`SessionDomain.swift`、`SessionCoordinator.swift`、`AssistantView.swift`
- **改动**：
  1. `SessionDomain.swift` 新增 `public struct SessionReviewSnapshot: Sendable { record, lines, speakerNames, voiceChanges }`。
  2. `SessionStore` 新增 `public func reviewSnapshot(sessionID: String) throws -> SessionReviewSnapshot?`，在 actor 内顺序执行现有 `session(id:)` / `lines(sessionID:)` / `speakerNames(sessionID:)` / `voiceChanges(sessionID:)`（**复用现有语句，不重写 SQL**）。
  3. `SessionCoordinator` 加同名转发。
  4. `AssistantView` 用 `@State private var review: SessionReviewSnapshot?` 替换 `reviewRecord` / `reviewLines` / `reviewSpeakerNames` / `reviewVoiceChanges`（`AssistantView.swift:37-40`），`openRecord` 改为一次 `await` + 一次赋值。
- **必须同步修改的引用点**（`AssistantView.swift` 内，B6 修订：共 42 处，逐个替换为 `review?.`）。
  `:37-41`（4 个 `@State` 声明）、`:143`（`state`）、`:438`、`:2270`、`:2294-2297`
  （DEBUG `renderReview` 初始化 4 个 `@State` 的签名，App 内无外部调用者，可直接改）、`:2907`、`:2919`、
  `:2970`、`:2972-2973`、`:2976`、`:2985`、`:3646`、`:3654`、`:3658`、`:3725`、`:3738`、`:3782`、`:3802`、
  `:3825`（`reviewDetail`）、`:3835`（`reviewVoiceName`）、`:3847`（`reviewPills`）、`:3898-3901`（`openRecord`）、
  `:3907-3910`（`closeReview`）、`:3973`、`:3990`、`:3994`、`:4003`、`:4023`、`:4032`（`exportReviewedRecord` 仍用 `session.lines` 直接读，与快照无关，不要动）。
- **完成条件**：`swift build` 通过；`grep -n "reviewRecord\|reviewLines" AssistantView.swift` 无残留。
- **提交点**：`perf(assistant): 切换对话记录改为一次快照读`。

### U6 · 列表行隔离重绘

- **前置**：**先测量**（见 §8 的 M1）。若测量显示列表重建不是主要开销，本单元可不做。
- **文件**：`macos/SpeechRailApp/SpeechRailApp/SessionDesignSurface.swift`
- **改动**：把 `libraryRow(_:)` 的内容抽成 `struct SessionLibraryRow: View, @Equatable`，入参为 `summary` + `isSelected` + 回调。核心价值是**让差分更新局域化**（B9 修订：`formatSessionDate` / `formatDuration` 是 ns 级纯函数，9 行列表里不可能是主因，不要先写进程内缓存字典——那会引入内存与线程安全评审负担；确有必要时再加）。
- **完成条件**：列表行不再由父 body 构造；`macos_app_test.sh` 全绿。
- **提交点**：`perf(assistant): 记录库列表行按选中态隔离重绘`。

### U7 · 文档同步（仅在正文实质变化时）

- **文件**：`contracts/realtime-openai.md`（若决定在契约层写明"空 final 的客户端处置"）、`docs/developers/macos-app-design-system.md`（新增失败提示条时）
- **完成条件**：`version` / `date` 只在正文实质变化时更新。

---

## 6. 关键实现说明

### 6.1 U2 伪代码（B1/B2 修订：fail-close + ordinal 取返回值）

> B1：原 `try?` 版本会吞掉写入失败，导致"库里没有的行出现在 UI"且 `committedItemIDs` 留下成功标记；
> B2：原 `currentOrdinal + 1` 会与 `appendLine` 自增序号错位，影响首句标题判定与音色 `atOrdinal` 回推。
> 以下版本修复了这两处，且与 `commitUserTurn` 现有 `do/catch` 结构（落库失败 → `remove(itemID)` 回滚 → 写 `lastFailure` → `return`）保持一致。

```swift
private func commitUserTurn(itemID: String, transcript: String, observedAt observed: Date) async {
    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    defer { if !itemID.isEmpty { itemObservedAt.removeValue(forKey: itemID) } }

    guard !text.isEmpty else {
        // 空 final 是契约允许的（clear 之后 commit）。若用户本轮确实说过话，
        // 说明这段识别没能定稿：保留它，不让它无声消失。
        guard let sessionID,
              partialItemID == itemID,                       // B3：U2/U3 合并后的门禁；U2 先行时此行暂缺，见 §5-U2
              let partial = partialText, !partial.isEmpty
        else {
            partialText = nil
            partialItemID = nil
            return                                            // 没说话：正常跳过
        }
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            partialText = nil
            partialItemID = nil
            return
        }
        if !itemID.isEmpty { committedItemIDs.insert(itemID) }
        do {
            let ordinal = try await coordinator.appendLine(  // B2：ordinal 取返回值，不自行 +1
                LineDraft(
                    sessionID: sessionID,
                    role: .user,
                    text: trimmed,
                    source: .microphone,
                    tStart: nil, tEnd: nil,
                    timingQuality: .unavailable,
                    status: .partial,          // 不计入记录库句数与导出
                    createdAt: observed
                )
            )
            currentOrdinal = ordinal
            turns.append(
                Turn(id: UUID().uuidString, ordinal: ordinal, role: .user, text: trimmed,
                     source: .microphone, isInterrupted: true, speakerLabel: nil,
                     createdAt: observed)
            )
            lastFailure = "这一句没能识别完整，已按未完成保留。请再说一次。"
        } catch {                                             // B1：fail-close，与现有结构一致
            committedItemIDs.remove(itemID)
            lastFailure = error.localizedDescription
        }
        partialText = nil
        partialItemID = nil
        return
    }

    partialText = nil
    partialItemID = nil
    guard let sessionID, let startedAt = sessionStartedAt else { return }
    // …其余落库 / history / beginReply 逻辑不变
}
```

注意 `defer` 里的 `itemObservedAt` 清理与 `committedItemIDs` 的时序：保留分支里插入 `itemID` 是为了让同一 item 的迟到 `completed` 不再走第二遍。

### 6.2 U3 门禁

```swift
private func ownsPartial(_ itemID: String) -> Bool {
    // B4：空 itemID 的 failed 只写 lastFailure，不动 partialText。调用点：
    // case .failed where itemID.isEmpty → lastFailure = "…" 后直接 return。
    if itemID.isEmpty { return false }
    return partialItemID == nil || partialItemID == itemID
}
```

`partialItemID == nil` 表示"当前还没有归属"，此时接受第一个事件的 item 并绑定。绑定之后只接受同 item 的事件。`prepareConversationContext`（`:905-919`）、`resetToIdleKeepingTurns`（`:1052-1070`）、`handleUnexpectedClose`（`:1664-1701`）三处复位点要把 `partialItemID` 一起置 nil。

### 6.3 U5 快照结构

```swift
public struct SessionReviewSnapshot: Sendable {
    public var record: SessionRecord
    public var lines: [TranscriptLine]
    public var speakerNames: [String: String]
    public var voiceChanges: [SessionChange]
}
```

`SessionStore.reviewSnapshot` 内部**复用**现有的 `session(id:)` / `lines(sessionID:includePartial:)` / `speakerNames(sessionID:)` / `voiceChanges(sessionID:)` 四条语句。`lines` 保持 `includePartial: false` 默认，与 `openRecord` 现有行为一致（记录库与导出只认已定稿行）。

---

## 7. 测试方案

全部为假后端测试，不下载模型、不连 loopback、不使用真实音频。

| 文件 | 场景 | 断言 |
|---|---|---|
| `AssistantSessionTests.swift` | 空 final + 有 partial | 保留 turn 产生；`lastFailure` 非 nil；库中一条 `status == .partial` 的 user 行；`beginReply` 未被调用（无助手 turn） |
| `AssistantSessionTests.swift` | 空 final + 无 partial | 无 turn、无 `lastFailure`（正常跳过） |
| `AssistantSessionTests.swift` | 跨 item 事件 | `item-1` 有 partial 后 `item-2` 空 snapshot，`partialText` 不变 |
| `AssistantSessionTests.swift` | 正常 final 回归 | 既有 assistant 回复用例不回归（现有文件已有） |
| 新增 `SessionStoreReviewSnapshotTests.swift`（放 `macos/SpeechRailApp/SpeechRailMacControlTests/`） | `reviewSnapshot` 与四次单独读结果一致 | 四个字段逐一相等；不存在的 session 返回 `nil` |
| 新增 `AssistantView` 离屏渲染夹具用例 | `lastFailure` 非 nil 时出现提示条 | 复用 `applyRenderFixture`（`AssistantSession.swift:193-224`，仅 DEBUG）离屏渲染，断言提示文案出现在 AX 树中 |

命令：

```bash
cd /Users/hrygo/Documents/SpeechRail
bash scripts/macos_app_test.sh
```

本次改动不触碰 Python / 契约 / 迁移，因此 `uv run --extra dev pytest`、ruff、mypy、OpenAPI lint 属于**全量门禁的一部分**，按提交前门禁跑即可，不必为本次改动单独新增。

---

## 8. 验收标准

### 代码层（可执行）

- [ ] `bash scripts/macos_app_test.sh` 退出码 0。
- [ ] `grep -c lastFailure macos/SpeechRailApp/SpeechRailApp/AssistantView.swift` ≥ 1。
- [ ] `grep -n "reviewRecord\|reviewLines" macos/SpeechRailApp/SpeechRailApp/AssistantView.swift` 无输出。
- [ ] `git diff --staged --check` 无空白问题；staged diff 中无 key / token / 真实音频路径。

### 行为层（需真机，本方案**不含** UI 自动化）

- [ ] M1 测量：Xcode Instruments（或 `os_signpost`）在**对话中**（麦克风开着）点击记录库条目，记录点击到详情首帧的耗时。**这一步需要用户单独授权接管前台窗口。**
- [ ] M2：不说话直接结束 → 不出现"没能识别完整"提示（正常跳过）。
- [ ] M3：说话后正常断句 → 走原有链路，行为与修复前一致。
- [ ] M4：注入空 final 的真机复现路径（若能构造）→ 界面上保留了那句话并给出提示。

### 明确未验证项

- 服务端为什么在 12 个出字 item 上只定稿 1 轮（ASR 终态缺失 / 提交超时 / 客户端等待逻辑）——**本方案不覆盖**，见 §9。
- 长时稳定性、转写质量、朗读质量——本方案不涉及。

---

## 9. 风险与注意事项

### 9.1 前置条件：P2 必须先测量

用户只有 9 条记录。§2.3 的 4 项开销单独看都不足以产生可感知的卡顿。**在 M1 测量出热点之前不要执行 U6**，否则可能改了一堆代码而没解决卡顿。U5（合并快照读）是无条件成立的正确性 + 性能改进，可以直接做。

### 9.2 P1 的服务端根因未定位

`12 个 item 出字 / 1 轮定稿` 这个比值是**已测量事实**，但"为什么"尚未确证。U2/U3/U4 的作用是：**无论服务端为什么丢，客户端都不再静默吞掉用户的话**。这是止损，不是根治。

若要继续追服务端，需要单独一轮排查（不在本方案范围）：

- 核对 `speechrail_realtime_partial_events_total{outcome="rewrite_withheld"}` 的量（`realtime_openai.py:2276-2278`）；
- 核对 ASR 提交超时路径 `_discard_failed_commit`（`realtime_openai.py:1192-1223`）是否被触发（会记 `first_hypothesis{outcome="failed"}`，当前计数为 0）；
- 抓一次失败时段的 `/metrics` 与 `speechrail.log` 全量。

### 9.3 不在本次范围

- `CaptionSession.commit`（`CaptionSession.swift:671-679`）与 `MeetingSession.commit`（`MeetingSession.swift:634-642`）有**完全相同**的"先清 partial 再 guard 空文本"结构。本次**不改**（用户只报了语音助手），但应在交付报告里点名，避免下一次同样的问题换个模块复发。
- 服务端"没有准入语音 → 空 final"分支本身不改：那是合法语义。
- 不改 `SessionLineStatus` / 记录库 schema / 导出口径。

### 9.4 回退

U1–U6 互相独立、都是本地 commit。任一单元可通过 `git revert <commit>` 单独回退，无数据迁移、无契约变更、无运行态变更。U2 引入的 `status: .partial` 行已经存在于用户库中；回退后这些行仍然可读（`lines(includePartial: true)`），不需要清理。

### 9.5 安全与隐私

保留的 partial 行与正式行走同一条 `SessionStore.appendLine`，因此继承既有的本机 SQLite 加密留存与"不写 PCM / embedding / 实名 speaker"约束。不得把 `partialText` 原文写进日志或 `os_signpost` 的字符串载荷。

---

## 10. Luna 执行清单

**执行前核对**

1. `git status --short --branch` —— 确认在预期分支，工作区无他人未提交改动。
2. `git log -1 --format="%h %ad %s" --date=short` —— 确认基线。
3. 重跑本方案的证据采集（可选，10 分钟内）：`curl -s http://127.0.0.1:8201/metrics | grep speechrail_realtime_turn_commits_total`，把结果附在交付报告里。

**按序执行**

| # | 任务 | 完成条件 |
|---|---|---|
| 1 | U1：写"空 final 不得吞字"回归测试 | 测试在未改代码时**失败** |
| 2 | **U3 先做**（B3 修订）：`partialText` 加 item 身份门禁（含空 itemID 策略） | 跨 item 用例通过；本地 commit |
| 3 | U2：`commitUserTurn` 顺序修正 + 保留分支（门禁条件 `partialItemID == itemID` 已就绪） | 任务 1 转绿；既有 assistant 用例不回归；本地 commit |
| 4 | U4：失败提示条 + `clearFailure()` | `grep -c lastFailure AssistantView.swift` ≥ 1；本地 commit |
| 5 | U5：`reviewSnapshot` + `AssistantView` 单状态 | 编译通过；无 `reviewRecord`/`reviewLines` 残留；本地 commit |
| 6 | M1 测量（**需用户单独授权**） | 拿到"对话中点击记录"的耗时读数 |
| 7 | U6：仅当 M1 指向列表重建时执行 | 行不再由父 body 构造；本地 commit |
| 8 | 全量门禁：`bash scripts/macos_app_test.sh` | 退出码 0 |
| 9 | 交付报告 | 列出实际 commit hash、实测结果、**未验证项**（服务端 ASR 终态缺失根因、字幕 / 会议同构问题）、回退方式 |

**偏差处理**：任何一步与本方案不符时，先核实来源与意图，不覆盖他人改动，不扩大写入范围。

---

## 附录 A' · 服务端根因与修复（2026-09-30 实测）

客户端的「保留未定稿文本」只是兜底。真正让单句语音无法定稿的是服务端：
commit 在大多数情况下整体失败成 `worker_inference_error`，Realtime 侧只
收到 `transcription.failed`，根本不存在 `completed`。

### 复现（确定性约 3 秒）

本地 TTS 合成一句 → `/v1/audio/speech` → 转 24 kHz 单声道 →
`input_audio_buffer.append`（不带 `.audio`，需 `event_id`）→
`input_audio_buffer.commit`。

| 输入 | 现象 |
|---|---|
| 单句「今天天气怎么样？」 | 出 `hypothesis` rev1/rev2，commit → `transcription.failed: worker_inference_error` |
| 双句 + 1 秒停顿 | `completed: "今天天气怎么样？好的，我知道。大了。"` ✅ |

对照说明触发条件：**句中有停顿**，尾块解码才会带出新文字，从而绕开出问题的分支。

### 根因

vendor `mlx_qwen3_asr/streaming.py:273` `finish_streaming()`：

```python
if merged == prev_text and state.enable_tail_refine:
    from .transcribe import transcribe
    refined = transcribe(audio=refine_audio, model=decode_model, ...)  # 抛异常
```

`transcribe()` → `_resolve_model_components()` 收到的是**已加载对象**而非路径，
于是 `model_path` 退回 `DEFAULT_MODEL_ID`（`"Qwen/Qwen3-ASR-0.6B"`）→
`_TokenizerHolder.get()` 联网拉取 → 离线环境抛
`LocalEntryNotFoundError: Cannot find an appropriate cached snapshot folder`。

`qwen3_worker.py:1009` 调 `init_streaming()` 未传 `enable_tail_refine`，
默认 `True`（`streaming.py:79`）。单句末尾通常无新文字 → 必进精修 → 必炸。
该异常不在 `_EXCEPTION_TYPES` 白名单内，故日志只显示 `exception_type=None`。

### 修复（commit `06b3570e`）

| 改动 | 文件 | 作用 |
|---|---|---|
| `init_streaming(..., enable_tail_refine=False)` | `src/speechrail/backends/qwen3_worker.py` | 止血，一行可回退 |
| 接入 `error_frame_message` | `src/speechrail/backends/qwen3_streaming.py` | 补齐诊断（见下） |

精修仅用于补回漏字，committed text 本身已完整，关闭它不影响定稿内容。

**顺带修好的诊断缺陷**：`error_frame_message()`（嵌入 worker stderr 尾巴）
已被 `qwen3_native`(2)、`qwen3_alignment`(3)、`qwen3_shared` 使用，但
`qwen3_streaming` 一处都没有——流式 ASR 是唯一丢弃 stderr 细节的后端，
这正是本问题此前只能看到 `exception_type=None` 的原因。

`error.code` 仍保持短机器码（保住 Realtime 契约 128 字符上限），
stderr tail 只进服务端日志。

**已验证（2026-09-30 21:31–21:45）**：以 `chore(release): 3.4.1` 发布并重装 managed
runtime。真实 ASR smoke（本地 TTS 合成单句 → 24 kHz → Realtime 单次 commit）现在返回

```
conversation.item.input_audio_transcription.completed
  transcript: "今天天气怎么样？样适合。出门吗？"
```

修复前同一输入是 `transcription.failed: worker_inference_error`。

**已知代价**：关掉精修后，尾块不再被重新解码，末句偶有错字——上例的
"样适合。出门吗？" 应为 "适合出门吗？"。这是"送不出去的错字"与"送不出去"之间的
取舍：精修在本机离线环境下**必然抛异常**（根因见上），无法修好，只能选择交付。
下游 LLM 对个别错字有足够容错。

---

## 附录 A · 缺陷引入时间线（2026-09-30 用 git 考古核验）

| 缺陷 | 引入 commit | 日期 | 说明 |
|---|---|---|---|
| ① `AssistantView` 不渲染 `lastFailure` | `570df6d9` | 2026-09-18 | 同一个 commit 既新建了 `AssistantView.swift`，又在 `AssistantSession` 引入 `lastFailure`。**与功能同一天写成，不是回归。** |
| ② 空 final 静默吞字 | `570df6d9` | 2026-09-18 | 该 commit 的 `commitUserTurn` 已是 `partialText = nil` → `guard !text.isEmpty … else { return }` 的顺序 |
| ② 的服务端前提（合法空 final） | `ffbf368d` | 2026-09-06 | 服务端 speech_admission 与"没有准入语音 → 空 final"分支 |
| ③ `partialText` 无 item 身份 | `570df6d9` | 2026-09-18 | 单槽位设计 |
| ③ 加重：`partialSnapshot` 整段替换 + 空快照清屏 | `cb447ff8` | 2026-09-21 | `partialText = text.isEmpty ? nil : text` 首次出现 |
| ③ 的服务端对应：`speechrail.transcription.hypothesis` | `ac4e90d5` | 2026-09-25 | 让"整段替换"成为必须 |
| P2 `openRecord` 四次串行读 | `570df6d9` | 2026-09-18 | 原始实现；最后一次改动是 `2e120507`（2026-09-19） |
| P2 `SessionLibraryColumn`（行在父 body 构造） | `4cc49f69` | 2026-09-18 | 与 `openRecord` 同日 |
| 对照：会议 / 字幕 / 提词器**渲染**了 `lastFailure` | `eb579731` / `e64e9830` / `87511391` | 2026-09-18 / 09-18 / 09-24 | 三个兄弟界面都补了，语音助手没补 |

**结论**

- 这不是 **3.4.0（今天 18:03 装机）引入的回归**。`git merge-base --is-ancestor` 核验：`570df6d9` 与 `cb447ff8` 在 `v3.1.0`（2026-09-21）到 `v3.4.0` 的**每一个 tag 里都存在**。缺陷自语音助手功能落地起就存在，只是今天第一次被实际撞到并记录。
- `76dc4f61`（2026-09-28，按场景收敛断句静音窗口）把助手静音窗口从裸写的 **400 ms 改成 900 / 1200 ms**，方向是**更宽松**，不是本次的诱因。
- `a27c688e`（2026-09-28，19 项缺陷修复）确实改过 `partialSnapshot` 分支，但只加了 `itemID` 绑定与时间戳，`partialText` 的三行写入逻辑未变；也**没有触及** `openRecord` 与记录库列。
- `dad7d9c0`（2026-09-26，单栈切换 Realtime 协议）是协议面的大改动，但上述三个 App 侧缺陷都早于它。

**核验方法**（供复现）

```bash
cd /Users/hrygo/Documents/SpeechRail
git log --oneline -S "lastFailure" -- macos/SpeechRailApp/SpeechRailApp/AssistantView.swift   # 无输出 = 从未渲染过
git show 570df6d9:macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift | grep -n "private func commitUserTurn" -A 6
git log --oneline --reverse -S "partialText = text.isEmpty ? nil : text" --all -- macos/
for t in v3.1.0 v3.4.0; do git merge-base --is-ancestor 570df6d9 $t && echo "$t 含缺陷"; done
```
