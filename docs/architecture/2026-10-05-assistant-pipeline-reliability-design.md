---
title: "语音助手 STT → LLM → TTS 闭环：代码审查与优化方案"
status: proposed
audience: "macOS 助手与 Speech Plane 维护者、方案评审者"
version: "0.1.0"
date: 2026-10-05
baseline: "d72535c7533855fa113018f3dddb78bb61e37fb4"
scope: "方案评审；不实施业务代码、公共协议、数据库或运行态变更"
---

# 语音助手 STT → LLM → TTS 闭环：代码审查与优化方案

## 1. 结论与证据范围

现有系统已经具备流式识别、外部 LLM、单 utterance 增量 TTS、取消屏障、输入保存队列和播放账本。
本轮应在这些边界上补齐生产接线、生命周期和观测，随后解除生成路径的串行等待。
无需把 LLM、播放器或应用级插话策略搬进 Python 服务，也无需重建一套句子级 TTS 请求队列。

优先处理四个正确性问题：空识别快照误打断、设备重建绕过远端取消、停播被未退出的音频消费者阻塞、
渲染完成冒充设备播放完成。性能工作先补分段计时，再解耦首次回复保存与 TTS 握手；
输入新鲜度和 LLM 流容量必须一起治理，避免用更多缓存换取表面流畅。

核验日期为 2026-10-05 UTC。基线是本地 HEAD，同时通过 `git ls-remote` 核实其等于远端 `main`；
仓库为 `hrygo/SpeechRail`。文中链接固定到该提交，路径缩写 `APP` =
`macos/SpeechRailApp/SpeechRailApp`，`TEST` = `macos/SpeechRailApp/SpeechRailMacControlTests`。
公共边界见 [Realtime 契约](../../contracts/realtime-openai.md)与
[机器 schema](../../contracts/realtime-events.schema.json)，本方案不修改它们。

证据口径：

- **源码确认**：直接读到的调用、预算、状态或缺少生产引用，不等于运行复现。
- **契约声明**：`contracts/realtime-openai.md` 定义应有行为；实现不得擅自扩大该边界。
- **历史证据**：近期验收文档记录的 fake 回归结果，本轮没有重跑，不作为当前实测成绩。
- **风险推断**：由等待关系或生命周期推导的故障场景，必须通过后续 gate 测试复现。
- **外部语义**：本轮读取 Apple 官方 completion 文档，核实 rendered 与 played 的区别；没有测试设备。

本 PR 只新增方案与目录入口。没有执行模型加载、服务操作、App 构建、UI 自动化、真实音频、
性能或长稳测试；不声称已降低延迟或提高识别质量。

## 2. 当前闭环与应保留的设计

```mermaid
flowchart LR
    MIC[麦克风] --> AUDIO[共享 AudioEngineSession<br/>系统 voice processing / native ring]
    AUDIO --> UP[独立 uploader<br/>24 kHz PCM16]
    UP --> WS[RealtimeASRClient<br/>同一 WebSocket 的 ASR / TTS]
    WS --> SP[Python Speech Plane<br/>VAD / ASR / Governor / TTS worker]
    SP --> WS
    WS --> RX[唯一 receiver<br/>connection / request 校验]
    RX --> SAVE[输入保存队列<br/>SQLite 成功后提交回答]
    SAVE --> GEN[runReply<br/>上下文预算 / Responses 流]
    GEN --> TTS[AssistantTTSStreamCoordinator<br/>单次 start / 文本 ACK / finish]
    TTS --> WS
    RX --> FIFO[有界 PCM FIFO<br/>独立音频消费者]
    FIFO --> AUDIO
    AUDIO --> LEDGER[渲染回调 / 播放账本]
    LEDGER --> TTS
    RX --> CANCEL[同步撤权 / 异步取消 effect]
    CANCEL --> TTS
```

1. `openVoiceTransport` 先确认能力和 LLM 可达，再获取设备；共享引擎在双工模式启用输入、输出
   voice processing，已有 AEC 参考路径。[启动及设备边界][startup]、[音频实现][audio]。
2. 输入、接收任务分开；receiver 将 final 同步放入单消费者保存队列，保存成功后才进入正式上下文与回答。
   队列包括键盘/语音保序、重复 item、失败恢复及结束屏障。[接收与保存][receive]、[保存队列][savequeue]。
3. `runReply` 已调用 `AssistantContextPolicy.buildRequestContext`：历史按显式 user/reply 关系裁剪，
   当前问题单独保留，实际 provider 请求传入输出预算。[生成调用][generation]、[上下文策略][context]。
4. 每轮一次 `speechrail.tts.start`，文本分段在同一 utterance 内 append；`finish_text` 不越过 ACK。
   接收 PCM 只做有界准入，消费等待不占 receiver；服务端终态到达后还需等待本地排空。[TTS 协调器][tts]。
5. 取消在 Task 调度前同步登记 retired request，未知远端 ownership 拒绝下一 start。
   不响应取消的旧 outbound 仍有句柄；ACK 超时不重发正文。[中断编排][interrupt]、[退役与屏障][tts-cancel]。
6. Python 入站数据与 TTS cancel 有独立控制通道，控制器先回收 lane，再发布唯一终态。
   Resource Governor 管理重计算与独立 capability lane；不能用多 worker 或无条件 ASR/TTS 并发替代它。
   [WS 路由][wsroute]、[StreamController][controller]、[Governor][governor]。

[10 月 4 日方案](../plans/2026-10-04-assistant-e2e-followups-luna-guide.md) 的 B1/B2/B3、P1/P3、C1/C2/C3
已有后续实现，见[历史验收记录](../plans/2026-10-04-assistant-e2e-followups-acceptance.md)。
本方案承接该实现，不重新宣称 receiver 内的取消/保存/播放等待环仍然存在。

## 3. 剩余问题：源码位置、影响与复现条件

优先级含义：P1 为闭环正确性或失控资源风险；P2 为性能、可维护性与未完成观测。
以下复现条件均为**拟新增验收场景**，不是本轮运行结果。

| ID | 优先级 | 源码确认 | 影响与后续复现条件 |
|---|---|---|---|
| E1 | P1 | `handle(.partialSnapshot)` 无条件调用 `noteSpeechEvidence()`，忽略 revision；`.partial` 只判断 `isEmpty`。`AssistantTurnPolicy.isBargeInEvidence` 只被测试调用。[接收][receive]、[策略][turnpolicy] | 活跃生成/播放时注入空快照或纯空白 delta，也会撤销旧回答。纯策略 A08 不能证明生产接线安全。重复旧证据是否能影响新回答还需区分 Realtime 客户端过滤与 App 轮次边界。 |
| E2 | P1 | `onPlaybackInvalidated(recovered: true)` 直接 `ttsStream.invalidate()`，取消 LLM 并保存 interrupted，随后回 listening；没有发送 TTS cancel 或关闭连接。[设备通知][device] | 本地已忘记 request，但服务端仍可能合成并持有 lane。新问题可能收到 `tts_in_progress`。现有设备测试只断言保存/UI，未验证恢复后的第二轮远端准入。[设备测试][device-test] |
| E3 | P1 | `runCancellation` 先无限期 `await audioConsumerAtPreparation?.value`，再 `await stopPlayback()`；发送与终态有超时，但这两个前置等待没有共同 deadline。[取消实现][tts-cancel] | 若 `enqueuePlayback` 不响应 Task 取消，已排入设备的声音不能及时停止。可用挂起 enqueue 的 gate 验证，而非仅测试挂起网络 cancel。 |
| E4 | P1 | 两条播放器均用 `.dataRendered`；协调器按 terminal + FIFO/consumer/ledger 排空报 completed，进而把上下文播放状态投影为 completed。`markPlayed/isPlayedThrough` 未进入生产路径。[音频][audio]、[备用播放器][player]、[账本][ledger]、[完成判定][tts-completion] | 声音渲染后，设备尤其蓝牙仍可能有输出延迟；当前完成语义过强。拆开 rendered/played 回调，并验证 rendered 已到、played 未到时不宣布设备播放完成。 |
| E5 | P2 | `runReply` 收到 delta 后先 `await persistReplyPartial`；首个可朗读文本还会等待取消 effect、音色应用、`stream.begin` 与音色记录；LLM 结束后先等 `finishInput` 再保存生成终态。`didSaveInput` 在 submit 前等待自动标题。[生成][generation]、[持久化][reply-save]、[输入保存后投影][receive] | 首次回复 INSERT、标题 IO、TTS started 会暂停正文消费或回答启动，文本 ACK 还会延迟生成终态保存。实际耗时未知；用 gate 分别测出这些等待，不能宣称固定减少一个 RTT。 |
| E6 | P1 | `LLMProvider.stream` 使用默认无界 `AsyncThrowingStream`，忽略 yield 结果；decoder 的行/事件缓冲、非 2xx body 累加无读取上限；流式请求缺少独立首正文/正文停滞/整轮 deadline。[LLM stream][llm-stream]、[decoder][decoder]、[网络读取][llm-read] | provider 输出预算不是客户端内存保证；异常大行、慢 Store 或 started 等待可积压。平台 URLSession 默认超时也不能表达正文停滞，keep-alive 不应无限延长回答。 |
| E7 | P1 | 共享音频每 100ms drain，native ring 为 131,072 samples，输出流 `.bufferingNewest(64)`；ring 满时停止拷贝，yield 的 dropped 结果未计数；`AudioChunk.capturedAt` 已存在但这里未填，上行只显示电平/错误。[采集][audio]、[ring][ring]、[AudioChunk][chunk]、[上行][receive] | 名义 100ms 分包下可缓存约 6.4s 旧输入；满后丢块而无可关联的 discontinuity。连续发送残缺语音可能让用户得到错误但看似完整的转写。实际积压需测量。 |
| E8 | P2 | `AssistantObservability` 仅有测试与 target 登记引用，未挂到助手采集、Store、LLM、TTS、停播；A53/A54 只测试计数类型。[观测类型][observability]、[观测测试][observability-test] | 无法定位首音/误打断/欠载来源，也无法证明丢块可见。计数饱和实现还应拒绝负增量、正确处理整数溢出，不能只依赖当前小值测试。 |
| E9 | P2 | `AssistantSession` 基线 2,877 行，持有连接、音色、保存、reply、播放、记录与多个 task/身份集合；`turns/contextTurns` 和 request/reply 映射随会话累积，请求裁剪不回收场内状态。[会话状态][session-state]、[回复投影][reply-save] | 已有依赖 seam，但职责与长会话内存边界仍弱。必须按任务/latch/记录引用的存活条件回收，而非任意删掉 retired ownership 或未保存正文。 |

E4 的官方依据（2026-10-05 本轮读取）：Apple 对
[`dataRendered`](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/datarendered)
明确说明不计 player 下游信号处理延迟；
[`dataPlayedBack`](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/dataplayedback)
计入下游处理与播放设备延迟，适用于音频设备渲染。
这证明回调语义不同，不证明某台设备已经正确发出 played 回调，更不能证明用户听懂。

## 4. 目标边界：应用编排解耦，保留 Speech Plane

以下类型名为**拟新增内部组件**，不是当前 API 或已实现能力。先提取明确职责，再决定是否迁移 actor；
不把所有子组件都改成 actor 来增加无意义的跨域等待。

| 组件 | 拟承担职责 | 复用与限制 |
|---|---|---|
| `AssistantSession` facade | 用户命令、可观察 UI 投影、composition root | UI 仍从当前入口读取；设备/网络不由 View 直接操作 |
| `AssistantConversationReducer` | 同步归约事件、轮次所有权、状态转换、effect 命令 | 单一写者；归约不等待网络、磁盘、播放或清理 |
| `AssistantVoiceTransport` | connect/upload/receive/drain/close、连接与设备代次 | 包装现有 `AssistantRealtimeClient` 和 `AssistantAudioSession`，一条语音连接 |
| `AssistantReplyRunner` | LLM 请求、流预算、文本增量与生成终态 | 包装 `AssistantLLM`，保持冻结 route 和已接通的 context policy |
| `AssistantReplyPersistence` | 固定 replyID 的创建、收尾、失败恢复 | 复用 `SessionCoordinator/SessionStore`；与输入保存队列分别保有权威身份 |
| `AssistantTTSStreamCoordinator` | start/append ACK/finish、文本清洗、音频准入、retired ownership | 保留单 utterance 模型，不新增逐句 REST 合成回退 |
| Playback adapter | enqueue、同步撤销 epoch、stop barrier、rendered/played 事实 | 共享 AVAudioEngine 保留 AEC；旧设备/epoch 回调不得改新状态 |
| `AssistantPipelineTrace` | 有界阶段时间、计数、队列高水位、失败原因 | 不进入原始正文；低基数汇总，不记录 PCM、完整 prompt 或转写 |

事件/effect 使用内部值类型，例如：

```text
Ownership = recordID + connectionGeneration + replyID + replyGeneration
SpeechOwnership = Ownership + requestID + playbackEpoch + deviceGeneration
Effect = effectID + Ownership + immutable input + deadline + retained task handle
```

`recordID` 是本地 SQLite 记录，不能当作 wire `session_id`；`connectionGeneration` 是 App 代次，
不能与服务端 transcription epoch 混用。旧 effect 可以保存自己的记录，但只能更新匹配身份的当前投影。
线上继续使用 current-only envelope 与 `speechrail.tts.*`，不增加应用 replyID、LLM 或播放协议。

状态至少拆为四条轴：输入（active/draining/closed）、生成（idle/running/terminal）、
TTS ownership（idle/starting/active/retiring/unknown）、播放（idle/buffering/rendering/played/invalidated）。
主界面 `phase` 是这些事实的投影，不能靠 setting `.listening` 推断远端已空闲。

## 5. 正确性闭环设计（E1–E4）

### 5.1 有效输入证据才打断

- 在生产 `handle` 接入统一 policy：空/纯空白无副作用；hypothesis 仍整段替换，绝不拼接修订文本。
- revision 归属键至少为 `(connectionGeneration, itemID)`；不同 item 的同一 revision 不能互相去重。
  记录已用于打断的证据与生效时点，重复证据不能重新打断刚启动的新回复。
- 与 `RealtimeASRClient` 已有 revision/sequence 验证分别测试：客户端负责 wire 合法性，编排器负责
  当前活动轮的输入意图。不要依赖只测 policy 的 A08，必须通过真实 Session receiver 注入事件。
- final-only 保留统一接管路径；以合法且成功接纳的 final 建立中断意图，保存成功才回答。
  队列满、重复 final、旧连接 final 不发起新回答，不擅自改变输入保存失败语义。
- 第一阶段只修空值、重复与归属。最短人声时长、回声相关性、duck/相邻 final 聚合都是后续设备调优项；
  电平或文本非空都不能可靠识别说话对象。未经质量对照不增加硬阈值误伤轻声、短词或无障碍用户。

### 5.2 设备恢复仍需关闭旧远端 utterance

设备重建先由音频层使旧 playback generation 失效并丢弃缓冲，再向编排器报告。
编排器在丢掉 request 身份前登记取消 preparation：停止本地输出、取消 LLM、
保留生成正文与播放未完成事实，然后由**仍然存活的 receiver**接收匹配 TTS terminal。

- `recovered: true` 只证明音频图重建成功。远端终态确认后才允许新 start。
- terminal 超时或旧发送任务未退出：关闭该连接，保留本地记录与文字输入，进入显式重试；
  不把 recovered 映射成远端空闲，不自动重播旧 PCM。
- 第二次设备切换、主动结束或 retry 与取消竞态时，旧 effect 只清自己的资源。
  设备已自行停播应允许幂等 stop，不伪造 rendered/played 归还预算。

### 5.3 本地停播独立于清理等待

不能简单把当前 join 移到 stop 后：那会允许跨 await 的旧 enqueue 在 stop 后重新排音。
先加强 playback adapter 的 epoch 准入，再调整取消顺序：

1. 同步撤销当前输出 epoch，登记 retired request；音频层也撤销其物理 generation。
2. 立即请求音频队列执行 stop/reset；每个 queued enqueue 在**实际 schedule 前**复验设备与播放身份。
3. 取消文本泵与音频消费者，保留未退出任务；清理 join 在独立 effect 中有 deadline。
4. 保持 outbound-exit → cancel-send → matching-terminal 屏障。只有这些条件和本地 stop 都确认，
   才放行下一轮；无法确认则退役连接/音频实例，不释放未知 owner。

采用整次取消的绝对 deadline 与分阶段耗时，不能让每个 2s 阶段各自重置导致总等待超出产品预算。
CoreAudio 自身卡住时不能承诺硬实时停播；超时报告 stop 未确认，停止接纳新语音任务。
不靠 `Task.cancel()` 假定不合作的任务已经退出，也不让丢弃 task 句柄冒充释放资源。

### 5.4 渲染与设备播放分开确认

两条 adapter 增加带 `(epoch, chunkID, samples)` 的 rendered/played 事实；
`chunkID` 让重复回调只归还一次。接纳、渲染、设备完成、失效分别计量，旧代回调全部拒绝。

优先验证 player 回调选择 `.dataPlayedBack` 后，如何保守地归还预算并记 played。
AVAudioPlayerNode 单次 schedule 只选择一种 completion 类型，**不能假定同一块自动回调两次**。
首版可仅用 played 回调释放队列预算，同时记录“渲染时点未单独观测”；
若需更早释放 rendered 预算，则另建有依据的渲染水位，不能用 enqueue 或估算时长伪造回调。

完成判定必须是：生成/TTS 的对应状态已确定、服务端 completed、FIFO 与在途 enqueue 为零、
该 epoch 的设备 played 水位覆盖所有成功提交音频。失败/取消/设备 invalidation 永远是 incomplete。
没有 played 证据或播放超时则为 unknown/incomplete，不能降为 rendered-completed。
生成全文与朗读交付状态继续分离；没有逐字对齐，不按采样比例截正文、不写“用户已听到第 N 字”。

## 6. 流畅度设计：保序流水线与端点调优（E5、E6）

### 6.1 用户保存边界与回复保存解耦

用户 final **保存成功后才请求 LLM**，沿用当前失败语义。保存成功后先完成正文投影和回答资格校验，
自动标题作为有身份的可等待 effect 处理；标题失败不得阻塞已经保存的问题。
结束会话仍要等标题/记录 effect 收尾，不覆盖人工标题。

首个 LLM delta 到达即进入有界正文状态与朗读入口，不再等待 assistant 首次 INSERT。
`AssistantReplyPersistence` 每个 reply 只有一个创建任务；finalization 与创建共享句柄和固定行 ID。
结束、provider failure、用户打断都等待同一收尾命令，不重复 INSERT。
首次保存失败只记录未保存事实和恢复入口，不影响已接纳的用户输入；失败正文保持有界。
明确权衡：首次落库前进程崩溃，assistant 内存正文无法恢复；当前实现也不承诺每 token 落盘。

### 6.2 TTS 握手与 LLM 正文消费重叠

将 begin 拆为启动意图和 started confirmation，由独立、有身份的启动任务等待。
LLM 继续消费正文到**有界** raw speech staging，原始空白保留。
确认取消屏障、最新音色与 started 后，再按连续 sequence append；不得提前发送 append。
started 失败停止本轮朗读并保留文本，不另开逐句 create/REST 回退。

复用 `AssistantSpeechStartGate/AssistantSpeechTextBuffer` 的 scalar 与清洗规则。
目前 150ms 文本 deadline、30ms tick、512 单片与 4096 整轮是代码参数，不是首音 SLA；
Markdown 未闭合还有 force 路径，ACK/启动/推理等待也会改变实际首音。
第一阶段保持这些默认值，先测出 started 前积压与首段大小，再比较事件驱动唤醒和首段/后续段策略。

收益预期是正文消费、保存与握手重叠，**不是少一次协议往返**。
即使生成提前结束，finish 也只能在 started 和最后文本 ACK 后发送。
LLM completed 到达即记录生成终态并提交正文收尾，TTS finish/ACK/播放交付异步继续；
它们的失败只改变朗读状态，不能反向把已完整生成的文本称为生成失败。结束屏障仍覆盖两侧任务。

### 6.3 LLM 流必须有端到端预算

为 assistant 调用增加内部、可注入的 `AssistantLLMStreamBudget`；共享 provider 的非助手调用保持显式策略，
不能因本方案把会议、纪要或后台作业套入语音短响应超时。

预算包含 delta 数/UTF-8 bytes、累计正文 scalar、SSE 单行 bytes、单事件 bytes、错误 body bytes，
以及 connect/header、首正文、正文无进展、总轮次 deadline。
可评审的首版候选：最多 128 条/256 KiB pending delta、256 KiB SSE line/event、8 KiB 错误正文；
累计回答候选 16,384 scalar，仍保留 TTS 4096 scalar 上限，超朗读预算只中止朗读并保留有界文本。
候选均不是实测最优值；按真实 provider 包形和 fake 边界复核后集中定义。

使用可异步背压的单消费者 channel，使 decoder 到消费者之间真正有容量约束。
若保留 AsyncThrowingStream，则必须检查 yield/drop 并显式失败，**不得静默丢 token**。
正文 deadline 仅由有效正文推进重置，SSE 注释、心跳、重复事件不延长它；总 deadline 不重置。
候选首正文 10s、正文停滞 5s、总轮次 60s，实施前按 provider 基线评审，不冒充当前配置。
取消统一区分 CancellationError/URLError.cancelled 与 transport failure，并将等待者恰好唤醒一次。

### 6.4 端点等待单独优化

当前助手 duplex 静音窗口 900ms，turnTaking 1200ms，服务端 SpeechAdmission 另有起音确认、pre-roll、
迟滞和尾音保护。[场景配置][vadprofile]、[服务端准入][admission]。
不能把 900ms 当作链路延迟全部，也不能假定通用 300ms 静音适用于中文思考停顿。

有真机基线后比较 900/700/500ms 场景候选：统计误切句、漏尾音、短词与自纠正，
最后按模式选择默认。优先复用现有参数，不增加 LLM 语义端点网络调用；
相邻 final 聚合会改变问答次序，在明确质量收益前保持关闭。

## 7. 队列、输入新鲜度与内存闭环（E6、E7、E9）

| 位置 | 当前源码预算 | 方案要求 |
|---|---|---|
| native ring | 131,072 float samples；可用容量少一个 sample | 以 native sample rate 换算时间，记录 accepted/dropped；48 kHz 下约 2.73s 是容量推导，不是实测排队时间 |
| capture AsyncStream | newest 64 chunks，名义 100ms/chunk | 同时约束 bytes 与 age；记录被替换块；不能把旧输入大量堆积当作抗抖动 |
| WS 下行 | 256 events、4 MiB decoded PCM | 保留现有 overflow 失败出口；控制事件不得被应用等待阻塞，不改变 wire sequence |
| input persistence | 32 commands、64,000 scalar，失败命令计入 | 保留保存后回答、队列满可读提示、结束 drain 与恢复所有权 |
| LLM delta/SSE | 默认无界 delta；parser/body 无独立容量上限 | 应用候选预算、显式背压或超限失败、首正文/停滞/总 deadline |
| speech text | 512 单片、4096 整轮 raw scalar | started 前 staging 共享整轮预算；清洗后的实际 append 再核对协商限额 |
| PCM FIFO + player ledger | FIFO 48,000 bytes（取协商较小值）；player 24,000 samples | 区分内存拥有字节与逻辑 reservation，同一 in-flight enqueue 不重复计算 PCM；played 未确认仍在完成账本 |
| 长会话状态 | 请求已裁剪；场内 turns/context/maps 仍累积 | 正文记录保存在 SQLite；只保留有界可视窗口、请求上下文与活动/未保存/retired 项，引用释放后回收 |

4 MiB decoded PCM 在 24 kHz PCM16 下约 87.4s 是**字节容量换算**，不是当前存在 87s 延迟；
event-count 也可能先成为限制。客户端总 PCM 容量必须包含上游、FIFO、player 和 in-flight 的唯一实际 buffer；
Python/worker/kernel/AVAudioEngine 各自预算分别报告，不能只宣称“缓冲 1 秒”。
服务端 send/worker 消费不是客户端 played ACK；第一阶段不新增远端播放 credit 协议。

采集先填充已有 `AudioChunk.capturedAt`，并增加块序号、native/wire 样本跨度、丢块原因。
时间点应来自采集 tap/样本轴，不能把 drain 或 upload 时刻称为真实采样时刻；缺证据显示 unavailable。
ring 在实时回调中只更新无锁/原子计数，离开回调才换算、记录或通知 UI。

候选输入最长等待 300ms（待基线评审），短暂拥塞仍保序；超过 age/byte budget 或检测到丢块，
将本次 utterance 标为不完整并显式结束/重试，不继续把断裂 PCM 当作连续完整输入。
首版可关闭旧连接、保留已确认/未定稿文字并重试，避免 speculative clear 丢掉尾句。
如后续支持局部重置，必须通过原子停止上传、样本水位和输入屏障确认后再 clear；
原契约没有缺口事件，不静默追加新 wire 字段或伪造缺失音频。

重试范围区分 loopback Speech Plane、外部 LLM 和本地音频设备。
已开始输出的 LLM 不自动重新生成并拼接，ACK 未知的 TTS append 不重发，设备切换不自动续播旧音。
只有明确支持幂等的完成屏障/记录恢复才能重试；重连不重置本地会话记录和已保存上下文。

## 8. 抗干扰策略：在已有 AEC/VAD 上验证

已有系统 voice processing + 服务端 Silero SpeechAdmission，后者具备 onset debounce、双阈值迟滞、
pre-roll 与 hangover；当前不是“没有 AEC/VAD”。但函数存在/启用成功不能证明实用回声抑制或噪声鲁棒性。

确定性阶段先完成 E1/E2/E3，真实阶段分别覆盖：扬声器播报时用户沉默、播报时插话、键盘/风扇/咳嗽、
背景电视/他人说话、近讲/远讲/轻声、短词“停”、中文停顿/自纠正、耳机和蓝牙切换。
按设备和模式统计误打断、漏打断、尾音丢失与恢复时间；阈值不能只优化一个样本或一种设备。

ASR 文本非空是应用证据，不是噪声分类器。要提前于识别结果打断，应另行评审本地 voice-activity
事实与 output-active 联合策略，不在 Python 端擅自恢复已移除的 `speech_started` 事件。
背景人声无法只靠 VAD 区分；若产品需要明确说话对象，单独设计近讲/按键/唤醒入口，
不引入实名声纹或跨会话身份。无质量证据时不默认开启 duck 或自动聚合 final。

## 9. 观测与验收指标（E8）

使用同一进程内 `ContinuousClock`，跨进程各自记单调耗时、用 request/item 关联，不直接相减两个进程
的 clock instant。墙钟只用于显示/审计。保存匿名摘要、有限 trace ring 和分布；ID 不作为指标 label。

| 指标 | 起点 → 终点 | 必须区分 |
|---|---|---|
| 用户说完到首音 | 可证明的最后用户语音样本 → 首音输出估计/可测播放证据 | 服务端端点估计与人工/测试标注；没有声学测量时不能称实际可听首音 |
| final-to-first-output | App 收到 final → 首块入队、首 render、首 played 分别计时 | 它不包含端点等待；played 是缓冲完成，不是首采样出声时间 |
| 生成路径 | 输入保存完成 → provider request → 首正文/生成终态 | 标题、reply INSERT、started、ACK 的阻塞分别计时 |
| 打断链 | 有效输入证据 → revoke → stop-confirmed → remote-terminal | UI speaking=false 不是设备静音；晚回调与未知 owner 单独计数 |
| 流畅度 | 播放活动期内 queued=0 且未 terminal 的欠载 | 首次预缓冲、已完成和取消不能算断流；记录次数及最长持续时间 |
| 输入完整性 | native attempted/accepted/dropped，wire emitted/uploaded，max age | 静音/半双工主动抑制不是丢块；native 与 24 kHz wire 单位分开 |
| 稳定性 | 保存/输入回执/取消/恢复成功率，task/owner/queue 高水位 | 无样本 N/A；失败不能写成功；统计不保存正文或 PCM |

性能目标先形成分设备/模式/provider 的 P50/P95 基线，再确认预算。候选 warm 场景目标为
有效插话到本地 stop P95 ≤150ms、final-to-first-enqueue P95 ≤1s；
它们不是已测成绩，也不能替代真实可听首音或 ASR/TTS 质量。
本地、远程 LLM 分组，冷加载单列；不把资源不足下的 fail-closed 作为性能回归误判。

## 10. 分阶段实施与可审查验收

每个阶段另开实施 PR；本方案 PR 不实施下表。需要真实运行态、UI 或 benchmark 时，再按专项授权执行。

| 阶段 | 范围与主要文件 | 出口条件 |
|---|---|---|
| M0 正确性 | E1–E4：Session receiver/device handler、TurnPolicy、TTS coordinator、两条 playback adapter、Ledger | 真实 Session fake 场景证明空值不取消、设备恢复下一轮可准入、enqueue 挂起也先撤权/停播、rendered 不冒充 played；保留已有取消/ACK/保存回归 |
| M1 边界与观测 | E8/E9：提取 reducer/transport/reply persistence，接入 trace 和 task registry | effect 有身份、结束屏障、回收条件；trace failure 不影响主流程；旧 effect 不能清新代；不以减少行数作为验收 |
| M2 生成流水线 | E5/E6：ReplyRunner/LLMProvider/SSE decoder、启动 staging、回复保存 | INSERT/started gate 挂起时后续 delta 可处理但缓存有界；无静默丢 token；超大 SSE/error body 失败；心跳不延长正文 deadline |
| M3 输入和容量 | E7/E9：AudioEngineSession、AudioSampleRing、AudioChunk、uploader、场内记录窗口 | 每个丢样点可计数；过期/断裂输入不发起伪完整问答；长会话活动内存有界且完整 SQLite 记录保留；无新增未评审协议 |
| M4 真机调优与认证 | 端点候选、声学场景、设备切换、冷/暖模型、实际 provider、长稳 | 分场景延迟与质量基线、故障恢复证据、资源预算通过；不以 fake green 关闭真实验收项 |

建议先给 M0 的四个问题各自独立修复，再逐步提取组件。新增 Swift 源码/测试须同步 SwiftPM 与 Xcode
两个 target；不得先大规模搬迁再失去行为证据。M2 改共享 LLMProvider 时必须覆盖其他调用方的默认行为。

### 必补的行为场景

| 验收 ID | 场景/注入 | 应有结果与已有入口 |
|---|---|---|
| V01 | 在真实活跃 request 上注入空/空白 hypothesis、空白 delta | cancel 计数不变；正文/队列不撤销；扩展 `AssistantCancelReceiveTests`，不能仅调用 TurnPolicy |
| V02 | 同 revision 跨 item、重复旧证据、新 final-only、旧连接 final | 独立归属、至多一次中断意图、合法新输入正常保存后回答 |
| V03 | 服务端 TTS 仍 active 时设备 recovered；随后第二问题 | 旧 request 收到取消并确认 terminal 后新 start；没有确认则关连接且重试，不是仅 UI listening |
| V04 | enqueue 不响应取消；已有音频在播；晚到 enqueue 返回 | 本地先撤 epoch/stop，晚 enqueue 无音；保留 task owner，下一轮不能越过未知清理屏障 |
| V05 | terminal 在 played 前到；rendered 已到；旧/重复 chunk 回调 | 不提前 completed；played 有唯一记账；invalidation 落 incomplete；扩展 Ledger/TTS 和 adapter 用例 |
| V06 | 首次 reply INSERT、自动标题、started 分别被 gate 挂起 | 首 delta 不被回复 INSERT 阻塞；标题不挡 LLM；started 前消费正文有界，append 仍在 started 后 |
| V07 | 正文消费慢、巨型 delta、无换行 SSE、多行事件、巨大错误响应、只有心跳 | 每个容量/deadline 显式失败并释放已知资源；完整前缀保留；EOF 不冒充模型成功 |
| V08 | native ring/stream overflow、上传阻塞、超过输入 max age | 计数与样本跨度准确、丢块原因可见、不静默转写残缺输入；合成样本不落盘 |
| V09 | 无响应 Store/stop/cancel、retry/结束交错、长会话 | receiver 控制可达，未知 owner 不放新轮，结束报告真实待保存；无无界 task/context 增长 |
| V10 | trace 写失败、负增量、整数上界、无样本 | 主流程不失败；计数饱和正确；N/A 不显示 0ms；覆盖实际生产通知而非仅纯类型 |

现有关键回归应继续保留：
`testA03BargeInTerminalThroughReceiveLoop`、`testA04CancelTimeoutFailsClosed`、
`testCancelCannotConfirmOrRestartWhileCancelledAppendIsInFlight`、
`testAcknowledgementTimeoutDoesNotResendAppend`、
`testReceiverContinuesWhileAudioWaitsForPlaybackBudgetAndDrainsFIFO`、
`testAggregateAudioCapIncludesChunkAwaitingPlaybackEnqueue`、
`testActualProviderRequestUsesOutputBudgetAndCurrentQuestionOnce`。
这些测试在基线中存在，本轮未执行；新增用例先在基线证明可编译的行为失败，再验证修复。

后续实施按阶段运行定向 fake 测试；公共 wire 如另行修改，需同时更新 schema、契约、Python/Swift 共享 fixture。
不能在 Linux 上用类型/语法检查替代 macOS 26 Apple Silicon 音频与设备验收。
M4 需记录 commit、设备、系统、ASR/TTS active spec、voice revision、provider 模式、样本数及未通过项；
只保存脱敏计时和汇总，原始音频、完整 prompt/转写和真实配置留在仓库外。

## 11. 取舍、兼容性与回退

- 保留服务端 ASR/TTS 子集、单服务/单 ASGI worker、Governor fail-closed 与显式 capability lane。
  不为延迟绕过资源准入，不引入分布式队列或持久 job 轮询到实时链路。
- 不通过缩短所有 timeout、放大 PCM 队列或未经证实的“省 RTT”来优化。
  服务端 delivered 只表示发送事实；App played 也不表示用户理解。
- 第一阶段不改数据库 schema。生成/播放细分状态重开记录后的恢复精度仍受现有 schema 限制；
  需要持久化时另写数据迁移与恢复方案，不能默默复用 `isInterrupted` 表达全部终态。
- 不采用 speculative LLM 对 partial 的正式回答，不自动追加未识别正文到上下文；
  不改变输入先保存再回答、冻结 provider route、当前 request 固定 voice/revision 的语义。
- 实施发生的内部接口破坏须在对应 PR 同步全部调用方和测试，不保留无期限过渡层。
  回退按实施 commit 的精确文件范围执行，保持已保存用户记录；不删除数据库或清理未知任务来假装恢复。

本方案回退仅撤回新文档与架构目录入口。没有运行态或用户数据需要回滚。

## 12. 本方案 PR 的验证与后续决策

本轮验证范围是文档与证据一致性：核对相对链接、固定基线源码路径/行号、引用的现存测试名、
Markdown 表格列数、空白和仅 docs 变更面。未重跑业务测试，未取得性能、模型质量或设备结论。

2026-10-05 本轮静态核验：29 个固定提交源码引用、18 处行号范围、两份文档的 28 个相对链接、
方案 59 行表格的列数与 7 个现存测试符号均通过；生产引用检查确认 TurnPolicy、Observability 与
played 记账尚未接线。仓库 `ci_changed_scope.py` 将两份变更判定为 `meta`，不选择 Python/Swift
业务门禁；`git diff --check` 通过。这些是文档/源码结构检查，不是缺陷运行复现或业务回归结果。

评审先决定：M0 四个正确性问题的实施顺序、played 回调的保守首版口径、
LLM/输入候选预算、M4 设备/provider 场景。默认沿用现有协议与资源边界，
不因方案列出候选数值就把它们写成已批准的产品默认或硬 SLA。

### 固定基线源码索引

[startup]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift#L1074-L1318
[device]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift#L1211-L1234
[receive]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift#L1788-L2198
[interrupt]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift#L932-L987
[generation]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift#L2473-L2683
[reply-save]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift#L2199-L2427
[session-state]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift#L280-L504
[audio]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantAudioSession.swift#L46-L645
[player]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantAudioPlayback.swift#L11-L133
[ring]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AudioSampleRing.swift
[chunk]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/MicrophoneCapture.swift#L43-L61
[savequeue]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantInputPersistenceQueue.swift
[context]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantContextPolicy.swift
[tts]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantTTSStreamCoordinator.swift
[tts-cancel]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantTTSStreamCoordinator.swift#L321-L448
[tts-completion]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantTTSStreamCoordinator.swift#L878-L923
[ledger]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantPlaybackLedger.swift
[turnpolicy]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantTurnPolicy.swift
[observability]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/AssistantObservability.swift
[observability-test]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailMacControlTests/AssistantRecordObservabilityTests.swift#L64-L86
[device-test]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailMacControlTests/AssistantSessionTests.swift#L1757-L1791
[llm-stream]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift#L920-L945
[decoder]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift#L751-L822
[llm-read]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift#L1500-L1783
[vadprofile]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift#L5-L25
[admission]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/src/speechrail/realtime/speech_admission.py
[wsroute]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/src/speechrail/http/routes/realtime_openai.py
[controller]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/src/speechrail/application/tts_stream.py
[governor]: https://github.com/hrygo/SpeechRail/blob/d72535c7533855fa113018f3dddb78bb61e37fb4/src/speechrail/runtime/resource_governor.py
