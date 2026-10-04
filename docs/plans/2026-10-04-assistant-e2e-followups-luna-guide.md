---
title: "语音助手全链路后续问题 Luna 实施方案"
status: active
date: 2026-10-04
scope: "macOS 助手接收循环、取消屏障、音色意图、上下文与记录投影；不含服务端行为、数据库 schema 或运行态变更"
baseline: "本地 codex/fix-assistant-clone-tts-binding，HEAD 7ae70b0358b6ad45161c6eb5bf056844c9297f0d"
---

# 语音助手全链路后续问题 Luna 实施方案

> 核验日期：2026-10-04（Asia/Shanghai）。本轮只审查和修改本文件，没有执行业务修复、测试、构建或真实设备验证。
> 基线来自本地 Git；原文所称 PR #215 的远端头与合并状态未核验，不作为实施前提。
> 本文件给出后续实施口径，不授权启动实施、创建子代理、提交、推送、安装或改变服务状态。

## 1. 问题结论

优先解除 receiver 的等待依赖，再修音色与上下文投影。原方案存在三处不能照做的设计：把“已发起取消”改成 `Bool true` 会冒充远端空闲；ACK 超时后重发不符合序号契约；在保存前发起回答会改变现有失败语义。P2/P4 的固定 RTT 收益也没有证据，降为延期评估项。

以下“确认”表示当前源码/测试形状支持结论，**不表示已经运行复现**。不再把长会话、网络抖动或蓝牙插拔列为通用复现步骤：服务端走 loopback，LLM provider 可能远程，二者故障不能混为一谈。

| 编号 | 审查结论与优先级 | 本方案处理 |
|---|---|---|
| B3 | **P1 正确性**：receiver 内等待取消，而确认终态仍须由同一 receiver 消费，构成等待环 | 同步发起中断意图，effect 异步等待；保留远端确认结果的原语义 |
| B2 | **P1 正确性**：正常 final、空 final 保留和 draining 保存都在 receiver 内 await IO | 有所有权、保序的保存队列；仍在保存成功后投影 history 并提交回答 |
| P3 | **P1 正确性**：receiver 还直接 await 音频播放预算，阻塞 ACK/terminal；原方案只暂停文本泵不能解除这个等待 | 有界音频队列与独立消费任务；先解耦，不先放宽超时，不重发未知 ACK |
| B1 | **P1 正确性**：换音色存在跨 await 旧连接和乱序覆盖；缺少断线期意图与真实生效记录 | 按选择版本取最新意图；按 request 固定 voice/revision，以实际 ordinal 登记 |
| P1 | **P2 完整性/资源**：已有预算策略，未接入真实 LLM 请求，策略本身也有配对与 scalar 边界缺陷 | 修正并接入 `AssistantContextPolicy`，保持固定指令/当前问题，设置输出预算 |
| C2 | **P2 语义**：失败正文需要保留，但生成失败与播放未完成缺少请求级区分 | 与 P1 共用带身份的上下文投影，保留原文并附事实状态；不删除 interrupted history |
| C3 | **P2 记录**：partial 行占 ordinal 是正常库语义，以 `ordinal == 1` 判断首句标题才是缺陷 | 独立判定第一条正式 user 行，并保护人工标题 |
| C1 | **P3 清理**：当前 App/测试源码只发现 `takeSentences` 定义，历史方案仍有文字引用 | 实施前复核可执行引用，删除方法与失效注释，定向验证 |
| P2 | **延期**：预检与设备并行会破坏当前“LLM 不可达时不取设备”约束 | 保持门禁；有启动分段证据后另评估无副作用环节并行 |
| P4 | **延期**：把 started 等待移入泵仍须等同一回执，不会自动省掉一次 RTT | 若证实 LLM 消费被握手阻塞，再评估预缓冲；不改变 start/append 顺序 |

## 2. 当前实现与根因

### 2.1 证据入口与限制

路径缩写：`APP` = `macos/SpeechRailApp/SpeechRailApp`，`TEST` = `macos/SpeechRailApp/SpeechRailMacControlTests`。下文符号为本地基线核验；拟新增类型、方法和配置均显式标注。

| 证据 | 文件与符号 |
|---|---|
| 单 receiver、保存与中断调用链 | `APP/AssistantSession.swift`：`startPump`、`handle`、`commitUserTurn`、`keepUnfinalizedUtterance`、`noteSpeechEvidence`、`enqueueInterruptEffect`、`stopCapture` |
| TTS 等待与退役屏障 | `APP/AssistantTTSStreamCoordinator.swift`：`begin`、`cancel`、`handleAudio`、`awaitPlaybackBudget`、`sendChunk`、`handleTerminal` |
| 已有上游事件预算 | `macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift`：`RealtimeEventStream.Limits`、`RealtimeEventChannel` |
| 音色仅影响下一 request | `APP/RealtimeASRClient.swift`：`updateVoice`、`startTTSStream`；`APP/AssistantSession.swift`：`changeVoice`、`openVoiceTransport` |
| 记录权威 | `APP/SessionCoordinator.swift`：两种 `appendLine`、`noteVoiceChange`、`setSessionTitle`；`APP/SessionStore.swift`：`appendLine` |
| 预算与生成收尾 | `APP/AssistantContextPolicy.swift`：`trimHistory`、`trimMemories`；`APP/AssistantSession.swift`：`runReply`、`finalizeReply`；`APP/AssistantReplyState.swift`：`Termination` |
| 原意图与验收记录 | `docs/implementation/2026-10-03-voice-assistant-user-journey-luna-guide.md`：VA-02/12/14；`docs/implementation/2026-10-04-voice-assistant-acceptance-ledger.md` |
| ACK 序号约束 | `contracts/realtime-openai.md` §5.3；`src/speechrail/domain/tts_stream.py::TtsStreamStateMachine.accept_append`；`tests/test_tts_stream_state.py::test_append_sequences_must_start_at_zero_and_stay_contiguous` |

图谱 generation 为 `2026-10-01T23:35:51Z`，`check_index_coverage` 提示多个 Swift 文件已变化、部分解析或未跟踪，`RealtimeASRClient.swift` 解析不可用。本轮以图谱定位候选，再直接读取当前相关源码与测试；没有重建索引，也不将图谱调用方列表视为穷尽结果。

> 🧠 **From Hindsight memory (SpeechRail 开发约定与验证方法)** — 2026-10-04 历史报告记录了 receiver 轻量归约、完整 turn 预算与生成/播放交付分离的意图；这些报告不能证明当前调用链已接通。

当前源码核对结果与上述意图存在差距：`submitTurn` 虽然同步，进入它之前仍等用户行保存；取消 effect 虽然建成 Task，其调用者仍 await；预算测试只调用纯策略，`runReply` 没有使用该策略。既有账本的 `done（D）` 是历史报告口径，本方案不沿用它证明集成完成。

### 2.2 B3 与 P3：两个 receiver 等待环

`startPump` 对每个 envelope 顺序 `await handle`。插话链为 `handle(partial/partialSnapshot) → noteSpeechEvidence → interruptCurrentReply → enqueueInterruptEffect → await effect.value`。effect 内的 `stream.cancel()` 等匹配 request 的 terminal；terminal 又排在同一 receiver 后面。因此问题不只是“慢几秒”，还可能让本可收到的确认只能超时。`noteSpeechEvidence` 随后也 await `finalizeReply` 或 `markLastReplyInterruptedAfterPlaybackCut`，只拆 cancel 等待仍不够。

现有 `AssistantCancelReceiveTests.testA03BargeInTerminalThroughReceiveLoop` 实际注入未知 `tts_req_playback` 并调用 `stopSpeaking`，没有通过 partial 触发真实活跃 request 的中断。该测试名称不能证明 receiver 内插话链安全。

第二条链为 `handle(ttsAudio) → await stream.handleAudio → awaitPlaybackBudget/enqueuePlayback`。队列满时，后续 ACK、terminal、partial 都无法处理。文本泵的 `sendChunk` 只等 ACK，没有播放预算门，原方案在此新增 suspend 不能替代音频消费解耦；延长播放等待到 10 秒还会延长控制事件阻塞。

### 2.3 B2：保存路径与身份

`commitUserTurn` 的正常和 draining 分支、`keepUnfinalizedUtterance` 都直接 await `coordinator.appendLine`。draining 的 `pendingDrainSaves` 当前是内联保存计数，**尚非后台任务注册表**。空 final 在生命周期分流前进入 partial 保留分支，实施时必须一起纳入结束屏障。

`SessionStore` 是单写者 actor，`appendLine` 是普通 INSERT，支持指定行 ID，但不提供重复 INSERT 的幂等成功语义。数据库分配 ordinal；当前正常 user 的 `Turn.id` 又是另一个 UUID。仅以 `committedItemIDs.insert` 预占并启动多个 Task，不能保证重连后的 itemID 隔离、保存顺序、失败恢复或结束等待。

### 2.4 B1：需要校验整个 await 链

`changeVoice` 在 binding await 前捕获 client，随后 `updateVoice` 本身也跨 actor await；之后无身份校验便更新 `voiceID/activeRealtimeBinding`。快速选择 B→C、B 的 binding 晚到，可覆盖 C；旧请求失败时 `voiceID = previous` 也可回滚后来成功的选择。只在一次 await 后重取 client 不足以解决问题。

`RealtimeASRClient.updateVoice` 只写本地下一次 TTS 的 voice 与 pins，不是服务端接受音色的回执。`changeVoice` 使用 `currentOrdinal + 1` 和 `try? noteVoiceChange` 提前记录生效，既非实际 request ordinal，也会吞掉保存失败。VA-12 已要求 request 固定音色与真实生效记录，B1 应把这个缺口一起补齐。

### 2.5 P1/C2：预算未接线，状态未投影

`runReply` 全量追加 `history`，记忆也全量拼接，`maxOutputTokens: nil`。`AssistantContextPolicy` 已声明 12 个完整 turn、16,000 历史 scalar、4,000 记忆 scalar、1,024 输出 tokens，禁止另起 40/20 消息阈值替代它。

现有 `trimHistory` 实际按消息数取 suffix；短于阈值直接返回而不校验 scalar；超限时逐消息删除会拆配对；剩两条再大也不继续校验。现有 `AssistantContextPolicyTests` 未通过 fake provider 核验真实请求参数，不能证明请求有预算。

`finalizeReply(.failed)` 保留已生成正文，`.failed/.interrupted` 都 `marksInterrupted == true`。当前 `playbackDeliveryNotes` 在 App 内，不进入 LLM messages。原方案按 `marksInterrupted` 删除 history 会同时删除用户打断和完整生成但没播完的答案，违背 VA-12/14；只在 UI 写说明也不能改变下一请求语义。

### 2.6 C3、P2、P4

C3：partial 是实际保存的行，正常占 ordinal；缺陷在 `commitUserTurn` 的 `appendedOrdinal == 1` 标题门。不能改库取号，也不能让重连重置的布尔值再次覆盖用户改名。

P2：`openVoiceTransport` 明确“LLM 连不上时不开会话、不取设备”。这是产品门禁，不是任意串行代码。直接并行 `provider.check/source.start` 会提前取麦克风；`async let` 的 await 顺序也不保证错误自然按“最先失败者”报告。

P4：`begin` 当前返回即代表 started 已确认，`offer` 同步缓冲并启动泵。仍坚持 append 必须在 started 后发送时，移动等待位置不会消除 wire 往返。`runReply` 等 begin 会暂停继续消费 LLM delta，但“可重叠消费”与“省一个首嗓 RTT”是不同指标。

## 3. 目标行为

- 接收循环不等待磁盘 IO、停播、播放预算或远端取消确认。以 gate 验证后续控制事件可达，不承诺未测的 50ms 硬上限。
- 用户 final 在到达时按固定 session/connection/item 认领并排队；保存成功才进入正式 turns/history 与回答；失败不发起回答，不伪装保存成功。partial 只归档，draining 永不启动新回复。
- 本地撤销旧输出权与远端空闲是不同状态。确认未知期间不得在同连接开新 TTS；取消终态仍由唯一 receiver 交给协调器。
- 最新有效音色选择在断线/重连期间保留；当前 request 的 voice/revision 不变。新 request 使用最新选择；实际接受与记录保存结果分别报告。
- LLM 请求复用统一预算，裁剪完整历史 turn，保留当前问题与必要指令；原始记录与续接种子不被改写。超大不可裁内容有明确错误，scalar 限额不冒充模型 token window 或费用保证。
- 失败回答保留已知正文和生成失败状态；完整生成但朗读未完成保留全文与播放状态。不能推算“用户听到了哪些字”。
- 标题来自第一条正式用户正文；partial 不抢占命名，人工标题不被异步自动命名覆盖。

## 4. 推荐解决方案

### 4.1 B3：同步登记意图，结果保持真实

拟新增同步 `requestReplyInterrupt(...) -> InterruptIntent`，意图包含 intentID、recordID、connection、replyID/generation、旧 stream/client 与不可变回复快照，并持有可等待的 result。现有 `interruptCurrentReply() async -> Bool` 保留为等待该意图结果的入口，`true` 仍表示远端已确认；receiver 只发起意图并返回。

本地撤权、记录旧 request 待确认资格与意图登记必须在第一个 await 前完成。必要时将协调器 `cancel` 拆成内部“准备取消/执行 effect”两段；原异步入口可复用两段，避免 Task 尚未调度时新 begin 抢先覆盖旧 request。effect 负责停播→cancel→terminal、旧回复保存与收尾。重复同目标中断合并等待，不另发取消；被替代 effect 仍保有回收句柄。

`stopSpeaking/replay` 使用等待结果；`stopCapture` 当前自有 draining 流程，不能机械替换成同一个 await 入口。provider failure 统一接入有身份取消屏障，避免旁路 `cancelTTS + invalidate` 把未知远端误当空闲。effect 完成不得覆盖后来接管的新 generation。

### 4.2 B2：receiver 排队，保存成功后提交

拟新增助手专属、单消费者的 `AssistantInputPersistenceQueue`，保存不可变命令而非无界创建 Task。命令固定 recordID、connection、itemID、lineID、observedAt、正文、formal/partial 与接纳次序；同一连接重复 item 只认领一次，跨连接同 item 不混同。空 itemID 使用本地唯一接纳 ID。

receiver 同步校验生命周期、清 partial 槽并入队即返。worker 顺序 await `appendLine(draft,id:)`；成功按固定 lineID 投影，ordinal 只取库返回值；再检查是否仍为 active 同场同连接，符合才同步 `submitTurn`。保存前不预造 ordinal、不把正文发给 LLM。

结束屏障注册所有已接纳在途保存，包括 active 转 draining 前的任务和空 final partial；按 record 聚合，不使用会被新场 reset 的裸全局计数。接纳次序决定 user 输入处理顺序，不承诺所有 assistant/user 行绝对交错。拟新增队列 Configuration，首版候选默认最多 32 个在途命令、合计 64,000 正文 scalar（包括失败待恢复命令），可注入更小值做边界测试；这是短时积压保护，不是会话总长限制。满时保留已有任务并报告未接纳新输入，不静默丢弃、无限缓存或无限重试。

失败从“已认领”转为可恢复失败，保留原命令；不自动重新调用 `submitTurn`。指定 ID INSERT 仍可能失败，恢复时按 ID 读回并核对，不能将唯一键错误直接当成功。Task 或 connection 取消不得顺手撤销已接纳的旧记录保存。

### 4.3 P3：先解耦音频消费，再评估容忍窗口

将当前 `handleAudio` 的等待移到协调器唯一、有句柄的音频消费任务。receiver 同步验证 request/epoch 并交入有界 FIFO；消费任务保序等待 ledger 预算并入播放层。拟新增 `maximumPendingAudioBytes`，候选默认 48,000 bytes，实际取其与 started 协商 `maxPendingAudioBytes` 的较小值；FIFO 和在途待入队块共享该限额，播放层仍受既有 ledger 预算限制。待消费 PCM、正在等待的块和已入播放队列的字节合计有上限，不能每包起 Task，也不能通过 unbounded `AsyncStream` 绕开预算。

上游 `RealtimeEventStream` 已有 256 events / 4 MiB decoded audio 的默认限额，本次不扩大。报告总体在途 PCM 上界时要加上该上游预算与新 FIFO/播放预算，不能只报告新队列的 48,000 bytes。块转移只记账一次，入播放器前预占，失败返还；显式超限后通过现有失败/取消路径收束，不阻塞 receiver 等容量。

协调器 terminal 先登记服务端状态；只有当前 FIFO、在途入队和账本都排空才完成。队列满、单块大于预算或入队失败应有明确结果并清理该代资源。取消立即撤权并丢弃旧 PCM，晚到播放器回调不得触碰新代账本。文本 ACK/terminal 在音频等待期间仍可处理。

本单元默认保留现有 2 秒播放等待与 5 秒 ACK 期限，先移除错误等待依赖。**不重发 ACK 状态未知的 append**：服务端重复 accepted sequence 返回 `tts_sequence_invalid`。如后续实测确需更长恢复窗口，单独定义单次停滞、总等待和总缓存上限，再改配置；10 秒不作为已批准默认值。设备重建当前会停止本轮，不能承诺蓝牙切换后自动续播。

### 4.4 P1 + C2：接通预算与状态投影

复用 `AssistantContextPolicy`，拟新增有身份的上下文 entry/turn 投影（仅 App 内存，不迁移 SQLite）：user 与所属 reply 按 ID 关联，生成状态与播放状态分别保存。生成失败保留已知正文；没有回复、连续 user 输入或续接种子缺配对时，不把相邻无关消息强配成完整 turn。

按 VA-14 将 12 解释为**最多 12 个历史 user/reply turn**，当前问题单独保留；这会修正现有“12 条消息”的实现偏差。历史最多 16,000 scalar，记忆最多 4,000 scalar，输出传 1,024 tokens。历史超限从最早完整 turn 移除；超大历史 turn 整轮省略，绝不逐消息删到半对。

builder 同时计入固定 instructions、人设、状态说明、记忆和当前问题。拟新增 `maxRequestScalars = 24_000` 作为首版保守产品预算（历史 16,000 + 记忆 4,000 + 固定内容/当前问题共用余量），集中在同一 policy 并用边界用例锁定；不推断模型窗口。预算不足先丢可选历史/记忆，当前问题与必需指令自身超限则返回可修改内容的错误，不静默截断。

状态说明由应用生成、通过 entry ID 绑定到相应消息，不插入正文、不伪装用户/assistant 说过的话；用户正文仍按数据处理。生成失败说明“以下是未完成回答”，播放状态只说明“朗读未完成，已生成全文保留”。不添加无事实根据的“已听完”。固定语音/文字指令与 frozenRoute 保持当前口径。

范围说明进入 App 可见状态，沿用现有展示组件；如需改 `AssistantView`，按设计系统做最小接线。摘要无既有轻量模型依据，也不因本轮自动引入，按 VA-14 的进入条件延期。上下文预算不能解决 turns/history 内存长期增长，内存分页另列后续任务。

### 4.5 B1、C3、C1

B1：拟新增 `VoiceSelectionIntent`，含单调 selectionRevision、场次身份（启动期间为 startToken，建场后绑定 recordID）、voiceID/name；只保留最新意图。binding await、updateVoice await 与记录 await 后都校验对应身份；过期成功/失败不得改当前选择、错误或 pending。重连发布前校验选择版本，旧 binding 的私有连接不得直接成为可用连接；同一失败场中 pending 保留，真正结束/新场才清空。

对 client 的 `updateVoice` 必须由唯一应用任务串行提交：若 await 期间选择更新，返回后继续应用最新版本，再放行下一 request。仅丢弃旧 await 的 UI 回调不能撤销它已对 client 写入的旧音色；验收必须观察 client 实际下一 start 的参数，不能只看 `session.voiceID`。binding 解析可被替代，client 写入不能有两个并发提交者。

TTS request 启动时固定 voice/revisions 与 replyID；started 表示该 request 的接受事实，之后按该 reply 实际库 ordinal 登记 `session_change`。若 ordinal 晚到，暂存登记任务按 ID 补记。`SessionCoordinator.noteVoiceChange` 当前隐式读取 activeSessionID，需增加明确 sessionID 的内部入口防串场。保存失败报告“已用于朗读但记录未保存”，不回滚正在播放 request、不发布虚假已保存记录。

C3：首条正式 user 与 ordinal 分开。拟新增按 record 作用域的自动命名认领；partial 不认领，重连不清空，标题写入失败可按同目标恢复。自动命名在 Store 写入时仅对仍未命名的记录条件更新，防止“查询→await→用户改名→覆盖”的竞态；可增加明确用途的 coordinator/store 方法，不新增 schema。typed 首句与语音首句采用同一口径。

C1：仅删除已确认无可执行引用的 `takeSentences` 及邻近失效注释，不重写历史归档文档，不借机拆整个 `AssistantSession`。

## 5. 详细实施步骤

执行基线选**包含本地 7ae70b03 改动的实际代码**。如果实施时已合入 main，先核实包含关系；若未合入，使用包含该修复的基线，不能从缺前置的 main 无条件开工。保持工作区并行改动；不要求清空所有未提交文件。

推荐依赖顺序：**B3 → B2（含 C3）→ P3 → B1 → P1/C2 → C1**。B3/B2 可各自建立确定性回归，不互为前置；B1 的真实 ordinal 登记依赖保存身份稳定，P1/C2 共用上下文模型，应作为一个自洽单元。P2/P4 无默认实施步骤。

### S1：B3 中断与接收解耦

1. 在 `AssistantSession/AssistantTTSStreamCoordinator` 定位 receiver 插话、stopSpeaking、replay、provider failure、end/stopCapture 的取消入口，列清结果依赖。
2. 先新增真实 active request 经 partial 触发中断的回归，started/ACK/terminal 全由 fake client 的 events 流到 receiver，不直接调用 coordinator handler。
3. 实现 §4.1；将 `noteSpeechEvidence` 的旧回复保存与播放标记移入有身份 effect，保留必要的远端屏障和输出权门禁。
4. 测 effect pending 时新 final/typed/replay、连续插话、结束和重连；确认新 TTS 不能越过未知旧 request。
5. 完成条件：无终态时确定失败关闭，有终态时不因 receiver 自锁而超时；旧 effect 不能清新轮，句柄/waiter 最终回收。

### S2：B2 保存队列与 C3 标题

1. 在 `AssistantSessionDependencies` 添加最小保存注入 seam（拟新增），生产委托 coordinator，测试用 gate 挂起保存；不为 seam 抽象整个 coordinator。
2. 新增 §4.2 的队列，接通 normal、partial、draining；沿用 MainActor 编排与 Store actor IO，不用 `Task.detached`。
3. lineID 贯穿命令、库与 Turn；成功回调区分“归档资格”和“当前回答资格”，迟到旧连接仅完成旧记录。
4. 将 stop/end 的保存屏障改为按 record 查询，超时仍明确未保存，不在 reset 后让旧 completion 递减新场计数；封存不能冒称全部保存。
5. 实现 §4.5 的条件命名。新增源/测试文件同步登记 `Package.swift` 与 `project.pbxproj`。
6. 完成条件：gate 未放行时后续 ACK/terminal 已被消费，provider 尚未发起；放行后按序保存且一次提交。失败、重连同 item 和结束尾句均不串场、不重复。

### S3：P3 有界音频消费

1. 先在真实 receiver 流中填满 fake 播放预算，再投递 ACK/terminal/partial，复现控制事件被音频等待挡住。
2. 在协调器新增有界 FIFO、唯一消费任务与在途字节记账，Session 的音频分发只做同步准入；与现有 ledger/waiters 共用 epoch。
3. 更新 completed 判据包含 FIFO/在途块；cancel/invalidate 回收任务、PCM、waiter，保留 terminal 退役处理。
4. 固定 ACK 无重发；覆盖 ACK 迟到、音频预算满、超大块、队列溢出、enqueue false、取消后的播放回调。
5. 完成条件：等待期间 receiver 可处理控制事件；内存有界、音频顺序不变、terminal 不抢先 completed。不以此声称设备切换可恢复或真实播放质量提升。

### S4：B1 最新选择与实际 request 记录

1. 在 `AssistantSession` 建选择意图/version 与统一应用流程；在 `changeVoice/openVoiceTransport/reconnectPipeline` 接通，复核每个 await 边界。
2. fake binding/client 分别卡住，交错 B→C、旧失败、新连接发布和结束，测试最终只接受最新同场选择。
3. request 固定 pins，借 S2 的 lineID/实际 ordinal 登记音色；为 coordinator 增显式目标方法，记录失败不能 `try?` 静默吞掉。
4. 完成条件：旧 request 保持 A，下一已接受 request 为 C，记录目标 session/ordinal 一致；same ID 新 revision 也可刷新，不按 voiceID 相同直接跳过。

### S5：P1/C2 请求预算与语义

1. 修 `AssistantContextPolicy` 的 turn 分组、短 history scalar 漏检、单巨大 turn、完整配对与省略计数，计数单位统一为 turn。
2. 将 `runReply` 接入 builder；补充请求捕获 fake，观察实际 messages、instructions、`maxOutputTokens`，不能只测纯函数。
3. 接通回复 ID 的生成状态和播放说明；保留成功/failed/interrupted 正文与记录原文，旧 finalize 不改新 entry。
4. 加 memory/request 总预算与可见省略状态；超限清楚结束本次生成，typed 草稿/已保存问题和原始记录不能丢失。
5. 完成条件：§7 的预算/状态矩阵通过；真实请求有界，frozenRoute、人设、当前问题与语音/文字指令正确。摘要保持延期。

### S6：C1 与文档收尾

1. 全 App/测试源码复核 `takeSentences` 引用后删除方法/邻近注释，运行相关定向回归。
2. 同步本次实质行为涉及的 active 开发/用户文档，说明预算、失败/保存结果与音色生效语义；不自动改根 README。
3. 完成条件：文档不声称实现了 P2/P4、自动摘要、ACK 幂等重发或蓝牙续播；实际执行结果另写，不将本方案改成完成证明。

S1～S6 可分别作为本地逻辑提交点，但**仅在用户明确授权提交时执行**，依据根 `AGENTS.md`“未被明确要求时不自动提交、推送”。本方案不要求每项独立分支；依赖修复可在同一授权分支按顺序实施，若另开分支必须携带前置。推送/PR/合并分别按授权处理。

## 6. 关键实现说明

### 6.1 中断状态

| 状态 | receiver 行为 | 后续 TTS 准入 |
|---|---|---|
| 意图已登记、本地已撤权 | 继续消费 partial/ACK/terminal；不等 effect | 同连接等待该意图结果，不返回乐观“已确认” |
| 匹配 terminal 已确认 | 只解除对应旧 request 的屏障 | 当前会话仍有效才允许下一 request |
| 超时/连接归属未知 | effect 调既有 `handleUnconfirmedRemoteIdle`，关闭/进入可重试中断 | 不在未知连接继续 start |
| effect 过期 | 只完成自己持有的资源与旧记录 | 不改新 generation 的 phase/error/history |

本地取消 Task 不等于服务端取消。同步 `invalidateReply` 也不等于播放层已经静音；物理停播仍经现有 barrier 确认，不能把“已发起停止”写成“已停完”。

### 6.2 保存与音频边界

保存身份至少为 `(recordID, connection, itemID/acceptanceID)`；reply 用自身 replyID/generation。旧连接的保存完成仍可写旧记录，但不能获得新场回答资格。重连必须允许新连接相同 itemID，不能因原集合残留误去重。

音频身份为 `(requestID, utteranceEpoch)`；从 FIFO 取块前及 await 入队返回后复核 epoch，不能使用 await 后读取的新 epoch 归还旧预算。completed 要求服务端成功终态、无 pending PCM/在途入队、当前播放账本排空，三者不能互代。

所有新增长期 Task 都有 owner 与句柄；结束、取消、过期和错误路径分别说明“等待完成”或“取消并回收”。不得只留一条跨场会 reset 的计数，也不得把 weak self 当生命周期管理。

### 6.3 上下文口径

12 turn 是历史预算，当前问题只出现一次。失败/打断不构造空成功消息；省略说明来自实际 entry/turn 计数。固定 instructions 也计入 scalar 总预算，输出 token 预算独立保留。续接种子作为输入参与裁剪，但种子正文与原 Store 不改写。

C2 不改变持久化 schema；因此生成失败的细分类状态首先为本场内存事实，重新打开旧记录若只有 interrupted，必须标“原因未知”，不能倒推 provider 失败。这项限制在交付中明确说明。

## 7. 测试方案

仅安排实施授权下的定向 fake 测试：人工文本、合成 PCM、临时 SQLite、独立 defaults；不连真实 provider/服务，不碰真实设备或用户库。用 continuation gate/注入 clock 控制时序，watchdog 仅防永久挂起。

| 单元 | 优先复用的测试文件 | 必须新增/强化的行为断言 |
|---|---|---|
| B3 | `AssistantCancelReceiveTests`、`AssistantStaleEventTests`、`AssistantReplyPersistenceRaceTests` | 捕获真实 requestID；partial 经唯一 receiver 触发取消；terminal 排在其后仍被消费；missing terminal 不开新 TTS；重复/过期 effect 不清新轮；provider failure 共用屏障 |
| B2/C3 | `AssistantPersistenceTests`、`AssistantDrainTests`、`AssistantReplyPersistenceRaceTests`、`AssistantSessionTests` | 保存 gate 未开时 ACK 可达且 provider 调用为 0；放行后三个 user 顺序落库；同 item 无重；跨连接同 item 合法；normal→end、partial drain、失败恢复、容量满；partial→正式标题及人工重命名竞态 |
| P3 | `AssistantTTSStreamCoordinatorTests`、`AssistantPlaybackLedgerTests`、`AssistantCancelReceiveTests` | FIFO 满时 ACK/terminal/partial 可达；上游/FIFO/播放总在途预算不超限；terminal 已消费但 FIFO/播放未排空不提前 completed；超大块/溢出有界失败；cancel 收净；ACK 超时 sendAppend 仍只一次 |
| B1 | `AssistantSessionTests`；可拟新增 `AssistantVoiceSwitchTests` | B→C 乱序 binding/update；旧失败不回滚 C；断线/启动期间选音色；end 后不重放；same voice 新 revision；当前 request pins 不变、下一 request pins 正确；记录保存失败有实情 |
| P1/C2 | `AssistantContextPolicyTests`、`AssistantRoutingTests`、`AssistantTextAvailabilityTests`、`AssistantReplyPersistenceRaceTests` | 0/1/12/13 turn；短 history 的超大正文；单巨大 turn；连续 user/缺 reply；Unicode scalar；记忆/总输入超限；当前问恰好一次；真实 fake 请求输出 1,024；failed/interrupted/未播完各有正确状态且原文不改 |
| C1 | `AssistantSpeechTextBufferTests`、`AssistantSessionTests` | 删除后现行增量分段与 reply 流仍可编译/执行，不测已删除 helper |

已有测试若只验证源码旁的新纯函数或名字与实际触发路径不符，应补接真实生产 seam，不能借用旧通过记录。fake provider 现有 `stream` 未保存请求参数，S5 必须增加请求捕获能力。保存 gate 用 S2 新 seam，不以“slow coordinator”泛称一个尚不存在的可替换实现。

每个正确性修复先取得目标行为断言的红，再在同一测试下取得绿；编译/导入错误不算红。优先修复前复现，不把整片生产代码 `stash` 作为默认变异验证。若红绿不足且需局部变异，使用隔离副本、精确补丁与恢复核对，不触碰并行改动，不默认跑完整变异套件。

## 8. 验收标准

以下为**后续计划命令，本轮均未执行**。从仓库根运行；每单元只选相关测试过滤器，确认目标用例实际发现、执行并断言行为。完整套件、App 构建和 UI 自动化均不是默认验收。

```bash
# 按单元选择，不要求每次全部运行
swift test --package-path macos/SpeechRailApp --filter AssistantCancelReceiveTests
swift test --package-path macos/SpeechRailApp --filter AssistantStaleEventTests
swift test --package-path macos/SpeechRailApp --filter AssistantPersistenceTests
swift test --package-path macos/SpeechRailApp --filter AssistantDrainTests
swift test --package-path macos/SpeechRailApp --filter AssistantReplyPersistenceRaceTests
swift test --package-path macos/SpeechRailApp --filter AssistantTTSStreamCoordinatorTests
swift test --package-path macos/SpeechRailApp --filter AssistantPlaybackLedgerTests
swift test --package-path macos/SpeechRailApp --filter AssistantSessionTests
swift test --package-path macos/SpeechRailApp --filter AssistantContextPolicyTests
swift test --package-path macos/SpeechRailApp --filter AssistantRoutingTests
swift test --package-path macos/SpeechRailApp --filter AssistantTextAvailabilityTests
swift test --package-path macos/SpeechRailApp --filter AssistantSpeechTextBufferTests

# 新增 Swift 文件或改 target 登记时
uv run python scripts/check_macos_test_target_coverage.py

# diff 不包含未跟踪文件；新增文件须另外检查正文
git diff --check
```

拟新增 `AssistantVoiceSwitchTests` 接入两套 target 后，再使用同名 filter。不要锁死“384 tests/16 suites”或“只增不减”；记录本次实际发现/执行的用例，退出码不能单独证明覆盖。

- [ ] B3：真实 request 的终态经 receiver 解闩；超时保持 fail-closed；新旧回复身份隔离。
- [ ] B2/C3：receiver 无保存等待；保存成功后才提交回答；全生命周期屏障、失败/容量行为与条件命名满足 §7。
- [ ] P3：receiver 无播放预算等待；FIFO/在途/播放合计有界；finish/terminal/cancel 顺序正确；ACK 不重发。
- [ ] B1：最新意图与 pins 生效准确；真实 ordinal 与明确 session 的记录一致；保存失败不伪装。
- [ ] P1/C2：真实请求受统一预算约束；当前问题/固定指令保留；完整 turn 裁剪；状态与原文分开。
- [ ] C1：可执行引用复核与相关回归通过；源/测试 target 登记一致。
- [ ] 交付分别标记：源码分析、失败复现、修复后定向测试、构建未验、真实设备/质量/性能未验；注明验证日期、基线与实际命令。

若之后明确授权延迟测量，应分开记录 `submit→首个 LLM delta`、`TTS start→started`、`首个 append→首包 PCM` 与 `提交→实际播放`，不能把首包 PCM 指标称为首字延迟。同 route/model/voice 与冷暖状态下做对照；次数和方法按基准技能确定。本方案不预设“各跑 3 次即证明改善”，也不启动测量。

## 9. 风险与注意事项

- B3/P3 改动同一取消/音频状态机，串行写入。重点防止 effect pending 开新 TTS、旧 epoch 回调清新预算和 terminal 提前宣布完成。
- B2 保留先保存后回答，库慢仍会延迟该句回答，这是明确取舍；收益是其它控制事件不再被这次 IO 占住。若需“未保存也回答”，另评审 pending UI、恢复、顺序与失败契约，不能夹带实施。
- B1 与 B2 都影响 ordinal/音色变更记录，须以实际数据库取号为准。更晚保存的旧结果不能降低当前水位或串入新场。
- P1 会改变超预算会话的可见上下文和输出长度；12 turn 与 24,000 请求 scalar 是产品策略，不是质量/模型窗口保证。完整 Store 与可复制原文保留。
- C2 生成/播放细分类暂不持久化，重开记录不能恢复全部状态；C3 条件标题写入不迁移 schema。本文不授权数据库清理或迁移。
- P2/P4、自动摘要、长会话内存分页、设备切换续播、延长恢复期限为明确延期项；它们不阻塞正确性修复，也不计为本案完成。
- 只新增助手专属最小边界，不重写通用 transport/provider 或整个 coordinator。若增加 View 接线，先读 `docs/developers/macos-app-design-system.md`；窗口、焦点、点击与录屏测试仍须当次明确授权。
- 回退依赖关系：代码单元无提交时按任务专属补丁恢复；获提交授权后按具体 commit 回退，依赖后续先回退。不能“revert 分支”或宣称各单元互不影响。回退不删除用户记录，不自动替换已安装 App/服务。

## 10. Luna 执行清单

- [ ] 收到实施授权后核对 HEAD、前置包含关系、工作区与同文件并行改动；偏差更新 §2，不清空他人文件。
- [ ] 先按 S1 补真实 receiver 插话回归，再实现有身份 effect 与远端屏障；目标测试红绿、资源回收均可核验。
- [ ] 按 S2 接通全部用户保存路径与结束屏障，顺带修 C3 条件标题；保存前不发回答，身份/顺序/失败断言通过。
- [ ] 按 S3 解耦音频消费，锁定有界缓存与完成条件；确认 ACK 不重发、超时不被无依据放宽。
- [ ] 按 S4 修最新音色意图与实际 request 登记；交错 await、重连、保存失败覆盖齐全。
- [ ] 按 S5 修并接通统一预算与 C2 状态投影；验证 fake provider 实际请求，而非只有 policy helper。
- [ ] 按 S6 删除 C1、同步涉及的 active 文档；P2/P4 与摘要保留延期。
- [ ] 每单元运行授权范围内的定向回归、diff/target 检查并记录结果；完整套件、构建、真实设备、UI 与基准另按授权。
- [ ] 只有明确授权后创建本地 commit；检查 staged diff、`git diff --staged --check` 与任务范围。未经授权不 push、开 PR、合并或发布。
- [ ] 最终报告列实际改动、验证日期/命令、未验证项、并行改动与回退；有授权提交才列 commit hash。不把计划或历史账本写成当前测试成绩。
