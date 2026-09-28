---
title: "语音助手 App 与服务层端到端 19 项缺陷修复 — Luna 实施方案"
status: proposed
date: 2026-09-28
baseline: f3063a6e
service_baseline: 0f171401
revision: 3
implementation_branch: codex/assistant-e2e-fixes
progress_ledger: .superpowers/sdd/2026-09-28-assistant-e2e-eleven-fixes-luna-guide/progress.md
---

# 1. 问题结论

本方案对应 2026-09-28 对语音助手的端到端源码审查，覆盖页面入口、启动、采集、WebSocket 队列、VAD/ASR、外部 LLM、增量 TTS、worker IPC、资源准入、播放、打断、重连、持久化与回看，共 **19 项：App D01–D11，服务端 B01–B08**。保留原文件名和 D 编号，便于继续引用。目标是修复已有功能，不重做语音助手，也不改变 SpeechRail 服务端只负责 ASR/TTS、调用方负责 LLM/播放/业务记录的产品边界。

**本文件是实施方案，不是修复完成报告。** 它的定位是给 Luna 的唯一实施口径：设计、步骤、测试矩阵和验收清单都以本文件为准；实际进度以 `progress_ledger` 指向的账本为准，两者不得互相覆盖。实施已在独立 worktree 的 `codex/assistant-e2e-fixes` 分支开始（基线 `0f171401`），本轮只补充完善本文件，未在主工作区修改业务代码；构建、测试、UI 自动化与服务操作仍遵循当时授权及 AGENTS.md。

证据基线：

- 初版 App 方案的 2026-09-28 源码核查：分支 `main`，HEAD `f3063a6e`；初版写入前工作区干净。这是历史取证状态，不代表本次更新时的工作区。
- 初版相对当时上一轮审查基线 `5fe25481`，核对的 `macos/SpeechRailApp` 和服务端 `application/realtime_openai.py`、`application/tts_stream.py` 无差异。
- 以下“事实”均指当前源码事实；故障表现来自控制流推导，尚未运行复现。实施先补可控 fake 回归，记录首次失败原因，不能把静态推导写成真机实测。
- 图谱 generation 为 `2026-09-27T20:54:17Z`。已对证据路径检查覆盖；AssistantSession、AssistantView、RealtimeASRClient 等存在 partial 或 freshness 缺口，本方案依靠相关范围源码补证，不把图谱视为完整证明。
- 外部 Responses 文档检索未返回可核验正文；本方案没有据此宣称完成最新官方协议核验。D10 的成功终态规则是本次明确采用的严格产品行为；实现前只读复核所用 SDK/提供方事件形状，不能因提供方省略终态就恢复静默成功。
- 服务层补充核查基线为 `0f171401`；更新方案时分支已为 `codex/voice-creation-use-e2e`。工作区存在其他任务对 `tests/test_voice_design_workflow.py`、`tests/test_voice_quality_routes.py` 的修改，以及另一个方案和 `.superpowers/sdd/` 下的未跟踪产物；均不属于本轮写入范围，不清理、不还原。
- B01–B08 是源码与可达时序分析，不是运行复现。图谱对 Realtime 应用/路由/协议适配及测试提示 freshness 变化，已直接读源码；`vendor/` 不在索引内，增量 driver 的消费语义以直接读取的 overlay 源码为依据。没有重建索引。
- D01–D11 保留原审查事实与实施设计，本轮没有重新宣称 App 全部路径经过新一轮实测。实施前必须对照当前源码确认是否已被并行工作修复。
- 交付前再次查看工作区时，另一任务已扩展修改到 `src/speechrail/backends/qwen3_tts.py`、能力/音色验证、HTTP 路由及相关测试。其中 `qwen3_tts.py` 与 SB2/SB3 有文件交集；本方案没有写这些文件。后续执行者必须核对并行改动后的 opener/lease 实现并保留其修改，不能直接按旧基线覆盖；B 项的控制流结论仍按上述取证基线标记，不冒称已复审全部并行新实现。
- **Xcode 目标结构为 2026-09-28 直接读取 `project.pbxproj` 所得事实**：`objectVersion = 56`，文件中 `PBXFileSystemSynchronizedRootGroup` 出现次数为 0，即不使用文件系统同步组，所有源文件都是显式 `PBXFileReference` + 每 target 独立 `PBXBuildFile`。因此“把文件放进目录即可生效”的前提在本项目不成立，`xcode-project-setup` 技能中“无需手改 pbxproj”的分支不适用，必须按 §6.8 显式登记。
- **单测 target 直接编译生产源文件**：Unit Test Sources phase 中包含 `SessionCoordinator.swift`、`SessionStore.swift`、`SessionDomain.swift`、`AppModel.swift` 等生产文件；而 `AssistantSession.swift`、`SessionPreferences.swift` **当前只在 App Sources，不在 Unit Test Sources**。新增任何引用 `AssistantSession` 的单测，都必须同时补齐它在 Test Sources 的 BuildFile，否则测试 target 缺符号。
- **执行环境限制为 2026-09-28 本机实测**：`timeout`(1) 不存在；`swift test` 被中断后会残留进程持有 `.build` 锁，使后续运行静默排队；测试输出经管道时块缓冲，挂死过程中看不到任何进度。§8.3 给出对应的正确命令形态，避免把“命令跑完”“退出码为 0”当成红绿证据。

| 编号 | 优先级 | 缺陷 | 主要后果 |
|---|---|---|---|
| D01 | P1 | 文本 ACK 与播放等待覆盖同一个 continuation | 回复/事件消费永久挂起 |
| D02 | P1 | 准备期间结束不能使旧启动失效 | 结束后重新打开采集，资源失去归属 |
| D03 | P1 | 重连复用首次建档流程 | 清空上下文、生成新记录、原记录未封存 |
| D04 | P2 | 静音错误映射为非活动会话 | 页面退回 ready，静音期间断线不处理 |
| D05 | P2 | 设备重建与播放账本不同步 | 排空永远不成立或触发背压失败 |
| D06 | P2 | LLM 失败不终止已启动的 TTS | 失败后继续播放、闭麦或服务端 utterance 残留 |
| D07 | P2 | 打字降级依赖成功的语音会话 | 麦克风拒绝后发送无响应且输入丢失 |
| D08 | P2 | 打断只取消任务/修改内存 | 部分回复丢失、回看缺少打断标记 |
| D09 | P2 | 发言时间游标不推进 | 用户发言起始时间恒为会话起点 |
| D10 | P2 | SSE EOF 被视为生成成功 | 截断回答被保存为完整回答 |
| D11 | P2 | TTS 丢弃纯空白 delta | 英文词语粘连、换行丢失 |
| B01 | P1 | ASR rollover 在 commit 锁内再次获取同一锁 | 连接处理挂起、ASR 资源滞留 |
| B02 | P1 | 取消控制队列等待尚未 dispatch 的音频 | 串行资源配置下打断形成循环等待 |
| B03 | P1 | VAD 句末提交把同包剩余完整帧按静音处理 | 下一句丢失、识别结果依赖网络分包 |
| B04 | P2 | TTS pending 字符只增加、不确认消费 | 累计超过 2048 后永久背压，4096 总额度不可用 |
| B05 | P2 | TTS 终态早于连接状态和 governor 清理 | 终态后立即 start 仍返回 tts_in_progress |
| B06 | P2 | ASR reader 吞掉取消及 RuntimeError | 超时/故障缺少失败终态 |
| B07 | P2 | 协商后的 pending 预算未传递到执行层 | started 声明的限制与实际背压不符 |
| B08 | P2 | session.update 先改内部状态再完成校验 | 被拒绝的更新仍部分生效 |

B 编号按上一轮服务端报告顺序固定；特别是 B01/B03 共享代码但分别验证“资源活性”和“音频完整性”，不得以修复其中一个代替另一个。

# 2. 当前实现与根因

## 2.1 文件地图与现有边界

下列路径以仓库根为基准。行号仅定位基线，实施以符号为准。

| 文件 | 相关符号与责任 |
|---|---|
| `macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift` | `startPipeline`、`retry`、`runReply`、`commitUserTurn`、`stopCapture`、`interruptCurrentReply`；当前集中编排 |
| `macos/SpeechRailApp/SpeechRailApp/AssistantView.swift` | `state`、`send`、`canCompose`、`endConversation`、`landOnFinalized`；入口与回看 |
| `macos/SpeechRailApp/SpeechRailApp/AssistantTTSStreamCoordinator.swift` | `wait`、`resolve`、`releaseWaiters`、`cancel`、`reportOutcome`；utterance、ACK、播放预算协调 |
| `macos/SpeechRailApp/SpeechRailApp/AssistantPlaybackLedger.swift` | `begin`、`complete`、`invalidate`；采样预算与排空 |
| `macos/SpeechRailApp/SpeechRailApp/AssistantAudioSession.swift` | `AssistantAudioSession`、`AudioEngineSession.rebuildAfterConfigurationChangeOnQueue`、`didFinishPlaybackBuffer` |
| `macos/SpeechRailApp/SpeechRailApp/AssistantAudioPlayback.swift` | `PCMStreamPlayer`；普通音源注入路径的播放器 |
| `macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift` | `connect`、`events`、`cancelTTS`、`startTTSStream`、`handle`；当前 wire adapter |
| `macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift` | `stream`、`runStream`；Responses SSE 消费 |
| `macos/SpeechRailApp/SpeechRailApp/SessionCoordinator.swift` | `begin`、`finalize`、`resumeAfterInterruption`、`appendLine`；全局设备会话占用与 Store 门面 |
| `macos/SpeechRailApp/SpeechRailApp/SessionStore.swift` | `appendLine`、`finalizeSession`、`sealAbandonedSessions`；SQLite 权威 |
| `macos/SpeechRailApp/SpeechRailApp/SessionDomain.swift` | `LineDraft`、`TranscriptLine`、`SessionLineStatus`、`SessionTimingQuality` |
| `macos/SpeechRailApp/SpeechRailApp/SessionPreferences.swift` | `AssistantMode`、`Persona`、`SessionPreferences`；偏好与本场快照输入 |
| `macos/SpeechRailApp/SpeechRailApp/App.swift` | production 依赖注入、starter/stopper 接线 |
| `macos/SpeechRailApp/SpeechRailControlKit/RealtimeContractTypes.swift` | `RealtimeEventEnvelope.receivedAt`、有界事件流 |
| `macos/SpeechRailApp/Package.swift` | SwiftPM 明确 source 列表，目前不包含 AssistantSession |
| `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj` | 显式 PBX 文件/构建引用，新增文件不能只加进目录 |
| `src/speechrail/application/realtime_openai.py` | `_claim_tts_request`；同连接只允许一个活动 TTS |
| `src/speechrail/application/tts_stream.py` | `_watch`、`_deadline`；服务端输入/总时限兜底，不能替代 App 主动清理 |

相关正式文档：`docs/developers/macos-app-development.md`、`docs/developers/macos-app-audio-capture.md`、`docs/developers/macos-app-design-system.md`、`docs/developers/testing-acceptance.md`、`contracts/realtime-openai.md`。

## 2.2 每项缺陷的事实、触发路径与根因

### D01：共享 waiter 覆盖

- 事实：`sendChunk` 等 `.acknowledgement(sequence)`，`awaitPlaybackBudget` 等 `.playback`；两条异步执行路径共用唯一 `pendingWait`（约 537–584 行）。
- 触发：文本 append 已发、ACK 未消费，此时一块音频触发播放背压。第二次 `wait` 覆盖第一次 continuation。相反覆盖顺序也危险。
- 深层原因：把 MainActor 串行访问误当作“只能有一个异步等待”；actor 在 await 处可重入。
- 修复约束：增加超时不能找回已丢失的 continuation；必须保存并精确释放每个 waiter。

### D02：启动没有所有权屏障

- 事实：`startPipeline` 多次 await，没有启动 token；`stopCapture` 只使回复失效，不使启动失效（约 482–643、647–678 行）。
- 触发：在能力发现、LLM 探测、权限请求、连接握手或建档任一挂起点结束/切换会话，再释放旧操作。
- 后果推导：旧路径可创建设备、连接和记录；协调器已 idle 或属于别的功能。
- 深层原因：回复有 generation，但启动与设备租约没有对应身份；`SessionCoordinator.begin` 的旧 catch 也可能无条件清理新占用。

### D03：恢复和新建共享破坏性初始化

- 事实：`retry` 先调用 `resumeAfterInterruption` 再 `startPipeline`；后者清空 history/turns、重置时间和 ordinal、建新记录（约 600–628、1123–1136 行）。
- 触发：已有多轮对话 → WS 断线 → 点击重试。
- 后果推导：会话 ID 与上下文改变，旧记录仍未正常 finalize；重连再次失败时协调器可能已错误显示 recording。
- 深层原因：持久会话生命周期与传输连接生命周期混为一体。

### D04：静音与中断共用 paused

- 事实：`toggleMute` 把 listening 改为 paused；`Phase.isLive` 不包括 paused，View 据此判 ready；`handleUnexpectedClose` 也依赖 isLive（约 431、1092 行）。
- 触发：聆听时静音，再断线。
- 深层原因：界面活跃、设备上行开关、连接健康没有各自明确语义。新会话也没有明确重置 `isMuted`。

### D05：设备层丢弃与上层账本不同步

- 事实：设备重建递增本地 playbackGeneration、清零 pendingBuffers，旧播放回调被过滤，但未通知 TTS ledger（约 599–619、662–685 行）。
- 触发：有未播放完 PCM 时切换音频路由。
- 后果推导：成功重建后旧预算仍占着；失败重建时仅设置错误文案，采集生命周期也未完全切到可恢复中断。
- 深层原因：设备“缓冲被丢弃”不是“已经播完”，但上层缺少对应终态事件。

### D06：LLM 异常没有回复级收尾

- 事实：`runReply` 普通 catch 设置错误、清显示、listening 后返回，没有关闭 TTS（约 1011–1016 行）。`handleUnexpectedClose` 也没有首先使活动 LLM 回复失效。
- 触发：首段已播 → provider 失败/不完整；或 WS 断开时 LLM 还在生成。
- 深层原因：LLM、TTS、播放、持久化分别收尾，缺少同一个回复身份下的幂等终结。

### D07：降级入口依赖语音成功初始化

- 事实：麦克风失败导致 reset 清空 sessionID；View 允许 typing、先清空草稿；`ask` 因 sessionID 缺失返回（约 369–405、View 2640–2657 行）。
- 触发：麦克风拒绝或其他功能占用时发送文字。
- 深层原因：纯文字会话不需要设备，但建档和发送被绑定到麦克风/WS 启动成功。
- 范围注意：另一功能占用时，不能通过创建文字会话覆盖 `SessionCoordinator.activeSessionID` 或停止该功能。

### D08：打断没有稳定的行身份与持久终态

- 事实：生成完成之后才写助手行；停止仅改内存最后一行；Turn.id 与落库自动生成 ID 不统一（约 439–468、1031–1067 行）。
- 触发：生成中 ESC/barge-in；或完整文本落库后、音频未播完时停止。
- 深层原因：回复任务身份、SQLite 行身份、播放 utterance 身份未建立稳定映射；简单更新“最后一行”可能更新错误回复。

### D09：时间游标未推进

- 事实：`pendingItem` 只声明/清空，`commitCursor` 只初始化/清空，定稿始终回退会话起点（约 824 行）。
- 当前可用证据：事件 envelope 有本地单调 `receivedAt`，metadata 只有事件/会话/序号；`partialSnapshot` 载荷没有精确 sample span。wire 的扩展信息不能假定已经完整传到此层。
- 深层原因：旧时间窗口状态留下了貌似精确、实际恒零的数据。

### D10：传输结束冒充业务成功

- 事实：`LLMProvider.runStream` 对 `[DONE]`/EOF 直接退出循环；识别失败事件，但未要求成功终态（约 1443–1486 行）。
- 触发：返回几个 delta 后正常 EOF，或只给 `[DONE]`。
- 深层原因：没有明确区分传输结束、生成成功、生成失败、调用方取消。

### D11：启动条件被误用为增量过滤条件

- 事实：每个纯空白 delta 都在送入 TTS buffer 前被过滤，但显示与历史累加原始 delta（约 983–1004 行）。
- 触发：合成 fixture 按词拆为普通文字、单独空格、下一词；或单独换行。
- 深层原因：是否值得启动 TTS 与启动后是否应保留文本被同一个 guard 处理。

## 2.3 服务层文件地图与根因

所有路径均相对仓库根，行号对应 `0f171401`，后续以符号定位。

| 文件 | 现有符号与修改责任 |
|---|---|
| `src/speechrail/http/routes/realtime_openai.py` | `receive_loop`、`handle_loop`、`control_loop`；队列、控制事件顺序、断线回收 |
| `src/speechrail/application/realtime_openai.py` | `_handle_admission_decision`、`_append_audio`、`_commit_audio`、`_commit_audio_once`、`_drain_asr_events`；ASR/VAD；`_claim_tts_request`、`_run_tts_stream`、`_on_stream_event`、`_release_stream_state`；TTS owner；`_update_session`；配置事务 |
| `src/speechrail/realtime/speech_admission.py` | `SpeechAdmission.push/finish`；VAD 决策与不足一帧尾部 |
| `src/speechrail/application/tts_stream.py` | `TtsStreamService.open/_open_session`、`StreamController._settle/_shutdown`；limits 传递、清理与终态 |
| `src/speechrail/domain/tts_stream.py` | `TtsStreamLimits`、`TtsStreamStateMachine`、`IncrementalSpeechSynthesizer`；预算、序列、内部协议 |
| `src/speechrail/backends/qwen3_tts_stream_client.py` | `Qwen3TtsIncrementalSession.append_text`、worker 帧分发；父端预算镜像 |
| `src/speechrail/backends/qwen3_tts_stream_host.py` | `accept_text`、`step`、`ModelStepEvent`、`StreamFrame`；worker 预算权威、内部 IPC |
| `src/speechrail/backends/qwen3_tts_worker.py` | stream start 解码和 host 构造；接收 limits、worker writer 队列 |
| `src/speechrail/backends/qwen3_tts.py` | `open_incremental_stream`、`_LeasedTtsStreamSession`；worker lease 与关闭确认 |
| `src/speechrail/backends/qwen3_tts_incremental.py` | `Qwen3TtsIncrementalModelSession.step`；vendor 事件边界 |
| `src/speechrail/compatibility/openai_realtime.py` | `_stream_limits` 与 start/update 解析；输入验证 |
| `src/speechrail/runtime/resource_governor.py` | `_can_admit`、reserve/release；保留串行资源保护，不通过放宽准入绕开死锁 |
| `vendor/mlx-audio-incremental/src/mlx_audio/tts/models/qwen3_tts/incremental.py` | `StableTextTokenBuffer`、`IncrementalSessionDriver`；本轮只读依据，默认不修改 overlay |

### B01：提交锁递归等待

- `_handle_admission_decision` 的 audio 分支在缓冲溢出时调用 `_commit_audio`（832–835）；后者持 `_commit_lock` 执行 `_commit_audio_once`（1026）。
- commit 的尾部刷新又调用 `_handle_admission_decision(..., in_commit=True)`（1068/1071）。audio 分支忽略 `in_commit`，可以再次进入同一非重入锁。
- 具体路径：当前 item 已接近上限 → 一个多帧 append 触发 rollover → commit 刷新尚未处理的帧/尾部 → 新 audio 决策再次超过上限。请求 deadline 在 1121 才建立，包不住这次等待。
- 深层原因：VAD 的“语音结束”、ASR 的“item 容量切分”、wire 的“提交”复用一个会继续派发决策的递归入口。

### B02：取消优先级被音频 dispatch 屏障抵消

- 路由把 cancel 关联到 `latest_append_dispatch`，控制队列等待该 future（206–224、302–310）。
- 场景：TTS 持有 lane；音频 A 等 `_reserve_asr`；音频 B 在数据队列里；cancel 等 B 的 dispatch；B 等 A；A 等 TTS 释放。`allow_heavy_overlap=False` 是受支持的串行准入状态，不是异常环境。
- 等待可被准入超时/TTS 自行结束打破，故不是所有配置下永久死锁；仍违反及时打断。不可将修复写成增加资源重叠或调短全局超时。

### B03：剩余包体误当不足一帧尾部

- `_append_audio` 在逐帧循环内 await 句末提交（915–935）；此时 `_vad_raw_buffer` 可含多个尚未评分的完整帧。
- commit 把全部剩余包体以 `probability=0.0` 送给 admission（1053–1071），源码“总小于 512 samples”的注释在自动提交路径不成立。
- 同一包的 speech→silence→speech 中，第二段可进入静音 prefix，而不是新语音。现有句末保留测试用逐帧 append，不能证明多帧包安全。

### B04：文本消费记账断链

- `accept_append` 同时增长 total/pending，`mark_text_consumed` 是唯一递减入口；生产 `src/speechrail` 搜索没有该函数调用，只有定义，单元测试有调用。
- client 在发送前记账，host 在 vendor append 前记账；ACK 表示 accepted，不表示模型已消费，不能在 ACK 时直接清零。
- vendor `waiting_for_text` 表示当次可用 token 已消耗完；`accepted_tokens` 是重分词后的剩余 token 数，不是本次字符消费量。字符/token/PCM 三种单位不能互换。

### B05：终态与资源可复用时刻不一致

- `StreamController._settle` 先发送终态，再 `_shutdown`；governor 释放在后者。Realtime 的 `_tts_task` 要等 `wait_closed` 后才清理；新 start 仍按该 task 判忙。
- `_LeasedTtsStreamSession.events` 可以在交出 worker 终态前释放内部 worker slot，因此本项不能写成“worker 必然一直占用”。确认的问题是连接 owner/governor 清理晚于 wire 终态。
- App S4 已把终态当作下一轮屏障；服务端必须提供匹配承诺，不能用 App sleep 或遇忙自动重发正文掩盖。

### B06：reader 的取消与错误吞掉

- commit 已返回、reader 仍等待时，外层 timeout 取消 await 的 reader；reader 捕获 `CancelledError` 后返回，可能使外层继续正常收尾而没有 `backend_timeout`。
- `RuntimeError` 同样被视为无须报告；它也可能来自 backend iterator，不能与 WebSocket 断开混为一类。
- `test_openai_commit_total_deadline_releases_hung_reader_slot` 实际使用 `_HangingCommitSession`，其 `commit` 本身不返回，未覆盖 ACK 后挂起阶段。

### B07：协商值只在上层存在

- `_stream_limits` 接受仅收紧的 override；`_append_tts_stream` 只检查 append/total；`TtsStreamService._open_session` 仅向 opener 传 options。
- worker host/client 使用各自默认 limits，导致 pending 字符/音频限制与 started 不一致。不能通过只修改 advertised limits 隐藏已接受的客户端约束。

### B08：配置更新没有原子发布边界

- `_update_session` 在 revision/voice/VAD 校验前写 alignment/diarization 开关；后续失败不会统一恢复旧状态，而 `_config` 最后才更新。
- “启用 alignment + 不匹配 revision”即可形成 rejected update 与内部状态不一致；VAD 创建失败也可发生在 diarization 资源调整之后。
- 目标不是给所有字段逐个补反向赋值，而是先验证/准备候选状态，再一次发布；失败仅回收候选资源。

## 2.4 拟新增文件与构建目标登记

本表是新增文件的唯一事实来源。§5 各步骤不再重复声明注册要求；文件实际落地后逐行核对，未使用的能力连同文件一起取消，不留空壳。

| 拟新增文件 | 用途 | 引入步骤 | SwiftPM | Xcode target |
|---|---|---|---|---|
| `macos/SpeechRailApp/SpeechRailApp/AssistantSessionDependencies.swift` | LLM / Realtime / Playback 三个协议与依赖容器 | S0 | App sources | App + Unit Test |
| `macos/SpeechRailApp/SpeechRailApp/AssistantSessionLifecycle.swift` | 生命周期 token 与状态投影 | S2、S3 | App sources | App + Unit Test |
| `macos/SpeechRailApp/SpeechRailApp/AssistantReplyState.swift` | 单轮回复的值类型：稳定 lineID、原始文本、落库与终态 | S4 | App sources | App + Unit Test |
| `macos/SpeechRailApp/SpeechRailMacControlTests/AssistantSessionTests.swift` | 真实编排层 + fake 依赖的回归主入口 | S0 | tests | Unit Test |
| `macos/SpeechRailApp/SpeechRailMacControlTests/SessionCoordinatorLifecycleTests.swift` | 共享租约的进入/退出/重入 | S2 | tests | Unit Test |
| `macos/SpeechRailApp/SpeechRailMacControlTests/AssistantAudioSessionLifecycleTests.swift` | 设备重建通知与账本失效 | S5 | tests | Unit Test |
| `macos/SpeechRailApp/SpeechRailMacControlTests/AssistantComposerTests.swift` | 草稿 single-flight 与发送结果 | S6 | tests | Unit Test |
| `macos/SpeechRailApp/SpeechRailMacControlTests/AssistantPersistenceTests.swift` | 回复落库、回看与时间语义 | S4、S7 | tests | Unit Test |
| `tests/fixtures/assistant_realtime_lifecycle.json` | 跨层闭环合成 fixture | §7.2 | pytest 资源 | 不适用 |

注册规则：

- 本项目 `Package.swift` 与 `project.pbxproj` 是两套独立的源文件清单，**两边都要登记**。只改 SwiftPM 会得到“测试全绿但 App 编译失败”的假象；只改 Xcode 会得到“本地测试编不过”的反向假象。
- 单元测试 target 直接参与编译生产源文件（见 §1 证据基线）。任何新单测引用到的生产文件，如果当前不在 Unit Test Sources phase 中，必须补一条该文件的 Test Sources BuildFile，不能依赖 `@testable import` 跨 target 解析。
- 一个生产文件被两个 target 编译时，**共用同一个 `PBXFileReference`，另建两条 `PBXBuildFile`**。复制 FileReference 会让 Xcode 显示同名文件的两个独立引用，后续改名/删除只作用于其中一条。
- fixture 若被 Swift 侧测试读取，必须通过 `#filePath` 相对定位或显式声明测试资源，不依赖当前工作目录。

# 3. 目标行为

1. 每个异步操作有明确 session、connection 或 utterance 身份；迟到结果只允许清理自己持有的资源。
2. 结束启动中的会话后，旧任务不能再发布设备、连接、记录或界面状态；完成清理后才能把租约交给下一功能。
3. 重连保留同一 sessionID、对话、人设、记忆快照、起始时间、音色变更与序号；仅替换传输和设备实例。
4. 静音只抑制上行，不退出活动页面，不影响断线检测；新建会话默认取消静音，原会话重连保留用户的静音选择。
5. 设备重建丢弃未播放缓冲时，本轮朗读明确中止，不伪造播放完成；成功恢复可继续下一轮，恢复失败进入中断。
6. 回复成功、失败、用户打断、服务丢失、会话结束都经过统一、幂等的回复收尾。
7. 文字发送无需麦克风、语音服务或设备租约；只有问题成功接收并落库后才清空草稿。
8. 已生成的非空回复在打断后可回看；完整生成但未播完的回复保留全文并标记打断。标记不等于精确“听到哪一个字”。
9. 每个 item 保留自己的真实本地观测时刻；无法证明的声学起止时间存 NULL，不能填零或把接收时间宣称为开口时间。
10. 只有明确成功事件才把 Responses 流判成功；缺终态、失败、不完整均可见地失败，取消不冒充 provider 故障。
11. TTS 输入保留合法空白；纯空白整轮不创建 utterance。
12. ASR 分段不递归提交；同样 PCM 的合法分包方式不改变语音检测、样本保留和 item 的容量切分结果。
13. TTS cancel 不等待尚未执行的音频、模型推理或 ASR 准入；已接受音频保持其数据队列顺序，取消 TTS 不自动清空用户语音。
14. pending 字符是“已接受但尚未被确认消费”的上界，total 是累计接受量。消费归还 pending，不归还 total；背压拒绝不推进 sequence。
15. 收到匹配 TTS 终态意味着该 utterance 不再发音频，旧 owner/资源已释放，允许新 request_id 开始。无法证明回收时关闭连接，不发送可复用的假终态。
16. ASR 成功必须有 reader 成功终态；超时和 backend iterator 故障不能静默成功。连接已断开时仍清理，但不强求向断开的 socket 投递错误。
17. 同一 effective limits 从协议解析传到 controller、父端、worker；协商的 pending 预算在实际排队边界执行。
18. rejected session.update 不改变已提交配置及活动资源；成功后才发送 session.updated。

UI 语义固定如下：

| 状态 | 页面 | 麦克风 | 可见动作 |
|---|---|---|---|
| idle，无记录 | ready | 不占用 | 开始语音、文字发送 |
| preparing | live/preparing | 可能正在获取 | 结束；禁止重复启动 |
| 语音活动 + muted | live | 仍属于当前会话，不上行 | 取消静音、结束、文字发送 |
| 语音中断 | blocked，保留记录内容 | 已释放 | 重试语音、结束；可用时文字发送 |
| 纯文字活动 | live，显示“文字对话” | 不获取 | 发送、结束、显式启用语音 |
| ending | live/ending | 释放中 | 禁用重复操作 |

# 4. 推荐解决方案

## 4.1 采用少量可测试的边界，不拆成 11 套状态机

- 保留 `AssistantSession` 作为业务编排入口；将依赖工厂和最小协议放入拟新增 `AssistantSessionDependencies.swift`，生命周期 token 与投影放入拟新增 `AssistantSessionLifecycle.swift`。
- 将每条回复的原始文本、稳定行 ID、保存状态和终结原因集中为拟新增 `AssistantReplyState.swift` 中的值类型。不要再把状态散放成更多无关联布尔值。
- TTS 自有独立递增 epoch，不能复用同一个 `replyGeneration` 作为多次重播的播放身份。`replyGeneration` 继续标识 LLM 回复；两者责任明确。
- Store 继续是持久化权威，不在 UI 中写 SQL。没有必要增加数据库列或破坏历史格式。
- 服务端范围扩展到 B01–B08 的 Realtime、TTS controller/IPC 及必要契约说明；保留现有 ASR/TTS 公共事件名称。模型、档位、Governor 准入政策、Keychain 和 LLM SDK 版本仍在范围外。

备选“只逐点加 guard/延迟”：改动少，但无法同时解决停止重入、重连建档和记录终态，因此不采用。也不引入全 App 通用状态机框架或通用多会话管理系统。

## 4.2 文字会话与设备占用的明确选择

推荐让纯文字助手记录由 `AssistantSession` 持有其 sessionID，通过 `SessionCoordinator` 的显式 sessionID Store 门面读写，**不调用设备占用型 `begin/sessionDidStartRecording`**。因此可与会议的设备占用并存。

为防跨会话污染：

- `appendLine` 只在 `draft.sessionID == activeSessionID` 时推进全局设备会话水位。
- 新增按 ID 封存独立记录的门面，不能调用会停止其他功能的 `coordinator.finalize()`。
- 助手结束入口统一经 `assistant.endConversation()`（拟新增）：持有助手设备租约时委托 coordinator；纯文字时只终结自己的回复和记录。
- 纯文字结束通知由助手自己的 `lastFinalizedSessionID` 发出；View 统一监听该结果，语音结束也映射到同一个结果，避免监听两条路径重复跳转。
- 全局“结束当前采集”快捷键仍对应设备 owner；助手页“结束对话”对应助手记录。纯文字界面要显示键盘可达的本页结束动作，不冒用另一功能的占用提示。
- 从纯文字启用语音必须经过现有占用守卫；获准后复用当前记录。用户取消切换确认，文字会话继续且草稿不丢。

这一选择会扩展 App 内部记录门面，但不新增后台采集、服务进程或业务数据库。

## 4.3 跨层修复顺序与取舍

1. 服务端先建立 fake harness，合并设计并串行实施 B01/B03，避免两次分别改同一个提交循环；再处理 B06、B08。
2. B02 取消解耦与 B05 终态屏障配套；B04 消费记账与 B07 limits 贯通配套。这些是逻辑分组，不授权并行子代理或同时编辑同一文件。
3. App S0–S3 可独立准备；S4/D06 的“终态后下一轮”验收依赖 B02/B05，D11 的长回复验收依赖 B04/B07。没有后端修复证据，不能宣称跨层闭环完成。
4. 不采用 sleep/retry 掩盖终态竞态，不放宽 governor，不提高 2048 上限掩盖消费缺失，不取消 pending 约束。
5. pending 文本默认采用**保守的整批消费水位**：worker 收到 vendor 的 `waiting_for_text` 才归还截至该刻全部已接受字符的额度；不估算 token 到字符的比例。这会比逐字符消费略保守，但有现有 driver 语义支撑，且不改 vendor overlay、采样参数或模型质量 gate。
6. 内部 IPC 新增消费水位及 start limits；公共 WS 不新增“consumed”事件，`text_accepted` 仍只表示接收。Python 父进程与 worker 同版本更新，不维护混合旧 IPC fallback。

# 5. 详细实施步骤

## S0：建立真实编排层的 fake 测试入口

文件：`AssistantSession.swift`、拟新增 `AssistantSessionDependencies.swift`、`App.swift`、`Package.swift`、`SpeechRailApp.xcodeproj/project.pbxproj`。

1. 给 LLM check/stream、Realtime client 工厂、audio 工厂和时钟提供最小注入。沿用现有 `AudioChunkSource` 与 `AssistantAudioSession`，不再制造同义音频协议。
2. 拟新增 `AssistantRealtimeClient` 协议覆盖实际使用的 connect/events/append/drainAndClear/close、voice 与 TTS 方法；生产 `RealtimeASRClient` 实现。协议尊重 actor 隔离，不用 unchecked Sendable 掩盖编译问题。
3. 保留生产默认行为，由 App composition root 明确注入实际实现；fake 不读取钥匙串、不访问 loopback、不创建 AVAudioEngine。
4. 将 `AssistantSession.swift`、`SessionPreferences.swift`、音频实现及新辅助文件加入 SwiftPM source 列表；若音频默认构造移入 composition root，则只编译实际依赖，避免条件编译另一份业务逻辑。
5. 新增 `AssistantSessionTests.swift`：临时目录 SessionStore、独立 UserDefaults suite、可暂停/释放的 fake 操作、虚拟时钟、fake 音频/WS/LLM。每个测试用自己的实例，避免共享静态脚本串扰。
6. Xcode 使用显式 PBX 引用（`PBXFileSystemSynchronizedRootGroup` 计数为 0），新增文件必须按 §6.8 同步 FileReference、每 target 一条 BuildFile、Group children 与 Sources phase；只让 SwiftPM 通过不算完成。`xcode-project-setup` 技能“不改 pbxproj”的分支在本项目不适用，可借其校验清单，但不能照搬其前提。
7. 登记完成后立即跑一次 App 编译（§8.1 的包装脚本），把失败符号与缺失的 BuildFile 一一对应补齐；**SwiftPM 通过而 Xcode 缺符号是本步骤最常见的返工**，不要留到全部 App 改动完成后再验证。

完成条件：同一份生产 AssistantSession 可用 fake 执行 start/ask/end，且设备/网络工厂调用计数可断言；SwiftPM 与 Xcode 两侧对 §2.4 每个新增文件都已登记，`bash scripts/macos_app_build.sh --configuration Debug` 退出码为 0。先补 D01–D11 失败场景再实施对应修复，不用测试专用分支绕过真实逻辑。

## S1：修复 TTS waiter 与 epoch（D01，支持 D05/D06）

文件：`AssistantTTSStreamCoordinator.swift`、`AssistantPlaybackLedger.swift`、现有 `AssistantTTSStreamCoordinatorTests.swift`。

1. `pendingWait` 改为按 `WaitTarget` 存储的 waiter 集合；每个 waiter 附加唯一 ID 和 utterance epoch。当前同一 target 只允许一个 waiter；重复注册显式失败，不覆盖。
2. ACK/start 预到达缓存也带 epoch；audio playback 不预存过期唤醒。timeout 精确匹配 waiterID，不能取消新注册的同 target。
3. Task 取消通过 cancellation handler 回到 MainActor 释放对应 waiter。注册前与注册后都检查取消/epoch，封闭“取消先于注册”的窗口。
4. `invalidate` 同步摘下全部 waiters、清空缓存，再逐一取消 timer/resume；不在遍历字典时重入修改集合。
5. 每个 `begin` 分配新的播放 epoch，含重播；把 epoch 传到 enqueue 和 rendered 回调。`onOutcome` 保留逻辑 reply identity，并同时保证旧 utterance 不能回报到新一轮。
6. `cancel` 的 await 后必须检查原 utterance 身份；旧取消完成不能设置新 utterance 的 outcome。调用方回调不再丢弃 generation 参数。
7. 处理播放背压会暂停唯一事件消费者的情况：waiter 分离消除挂起，但不能假设 ACK 一定即时消费。测试须包含队列满时 ACK 到达、稍后播放释放、随后 ACK 被消费的真实顺序。

完成条件：双向交错等待、超时、取消、invalidate 都精确唤醒一次；没有被遗忘的 continuation；旧回调无法改变新账本。

## S2：启动、结束与重连分离（D02、D03）

文件：`AssistantSession.swift`、拟新增 `AssistantSessionLifecycle.swift`、`SessionCoordinator.swift`、`App.swift`。

1. 拆分 `prepareConversationContext`、`openVoiceTransport`、`createConversationRecord`、`resumeVoiceTransport`（均为拟新增职责；允许名称微调但责任不合并回原大函数）。
2. 会话级生命周期 token 在每次开始/结束改变；connection token 在每次建连/重连改变；reply token 单独管理。
3. start task 必须有句柄。设备、client、player 在操作私有 scope 创建，验证 token 后才发布到 self。每个 await 返回后验证；stale 路径只关闭自己的资源。
4. 结束首先关闭新输入入口并使启动 token 失效，再 cancel 启动、回复与连接任务。对可协作取消的 fake/真实依赖使用明确清理屏障；不能通过无界 `await task.value` 等一个不响应取消的外部调用。
5. 暂未返回的权限/连接调用保留 cleanup owner；晚返回时立即停止私有资源。设备尚未确认释放时 coordinator 保持 ending/不可再准入，不提前标 idle。超时显示“正在释放设备，请稍后重试”，不抢开第二台引擎。
6. `SessionCoordinator.begin/finalize` 增加操作身份：旧 starter 的成功或 catch 只处理旧租约；旧结束流程不能清空新 occupancy。不要只修 AssistantSession 而留下共享协调器的重入清理窗口。
7. 建档放在语音准备成功且 token 有效之后。建档期间被取消也可能产生记录：预分配 record ID 跟踪该创建；如果确实落库，只按该 ID 封存，不删除，也不将其挂到新会话。
8. 重连路径不得重建记录、重置 turns/history/ordinal/startTime/persona/memories/voiceChanges。只刷新能力 binding、设备、WS 和连接 epoch；本轮 LLM 配置按已选快照继续，配置变化要求新会话。
9. `resumeAfterInterruption` 放到新连接与音频确实 ready、token 验证成功之后；重连失败仍保持 interruption 未闭合、可重试、无设备残留。
10. 重试做 single-flight；结束和第二次重试都能使旧重试失效。已结束记录不允许 retry 把它重新变成 recording。
11. 断线先冻结当前回复、释放本连接资源并记一次 interruption；所有事件以 connection token 门禁。停机 drain 返回的最终 ASR 可以落用户行，但不能再启动 LLM/TTS。

完成条件：所有启动 await 位置的 stop/switch 测试通过；重试前后记录数、sessionID、历史内容与序号连续性符合目标。

## S3：统一界面活动与静音语义（D04）

文件：`AssistantSession.swift`、`AssistantView.swift`、拟新增 `AssistantSessionLifecycle.swift`。

1. `isMuted` 只控制上传；不再用 `phase = .paused` 表达静音。paused 如保留，仅用于语音中断。
2. 增加明确的 `hasActiveConversation`、`canEndConversation`、`canRetryVoice` 投影；View 不再用一个 `phase.isLive` 推导所有入口。
3. 断线处理检查当前 connection identity 和 intentional-stop 标记，不依赖 presentation phase。
4. 首次新会话初始化 `isMuted = false`；同一会话重连保留静音。voice 开关与播放期间抑制上行仍独立。
5. 静音期间保留对话、结束与恢复按钮；状态文字“麦克风已静音”。不新增裸 token，不改变布局风格。
6. 纯文字、paused、preparing、ending 与 blocked 映射按 §3 的表统一，移除以 `isLive == false` 即显示“未开始”的旧分支。

完成条件：静音不改变记录/占用；静音后断线也释放设备、显示重试；下一场默认可上行。

## S4：回复身份、落库与幂等终结（D06、D08）

文件：`AssistantSession.swift`、拟新增 `AssistantReplyState.swift`、`SessionCoordinator.swift`、`SessionStore.swift`、`SessionDomain.swift`。

1. 每轮开始分配固定 replyID，同时作为助手 lineID；保存 sessionID、reply generation、原始文本、startedAt、source、是否已落库、是否已结束生成和播放终态。
2. 第一段非空正文到达时按该 ID 插入助手 partial 行，随后仅在内存累计；无需每 token 写 SQLite。最终/打断/失败时按该 ID 更新完整已知文本。
3. 新增受约束 Store 操作，例如 `finalizeAssistantLine(sessionID:lineID:text:interrupted:)`，同时验证 session、lineID、role。仅更新 text/status/interrupted 等本任务字段，保留星标和已有 created_at。
4. 只有第一次插入推进 ordinal/水位；后续更新不重复计数。Turn.id 必须与 SQLite 行 ID 一致，不再单独生成 UUID。
5. 生成终态和播放终态分开：完整文本可以先作为 final 保存；随后用户打断播放时按同一行 ID 更新 interrupted=true。部分生成被打断则保存非空部分，标记 final + interrupted=true。
6. 错误导致的部分回复同样保留并标记 interrupted；空回复不创建伪造正文行。没有用户原文的诊断信息只进入错误状态，不插入模型正文。
7. `finishReply(reason:)`（拟新增）按 replyID 幂等：先冻结旧回复和禁止新 delta → 取消 LLM → 停播屏障 → 对仍活动的 TTS 发取消 → 持久化已知正文与标记 → 更新历史/界面。
8. 不允许正常完成路径和取消路径同时插两行或重复追加 history。取消函数使用自己的不可变 reply snapshot，不能在 await 后读取“当前回复”覆盖新一轮。
9. LLM 已生成完整正文但没播完时 history 保留完整正文、记录标记 interrupted；生成中打断只加入已保存部分正文，不虚构余文。下一轮仍按原有角色结构发给 provider，不添加伪造成功消息。
10. 持久化失败保留内存正文和可重试保存标记；不得显示“记录已保存”。结束流程等待本次保存结果再封存，失败必须可见，不静默丢弃。
11. 语音连接异常、设备故障、输入替换、ESC、barge-in、结束都复用此终结入口。新语音回复不能在旧 TTS 仍活动时调用 start。
12. 当前 `cancelTTS()` 返回只代表 send 完成。取消后以匹配 requestID 的终态作为远端空闲屏障；有界等待超时则关闭该连接、进入可重试语音中断，不在同连接强行启动下一轮。事件泵不能被“等待它自己消费的 terminal”阻塞：终态闩在 Realtime 接收层解锁，或将业务收尾转为独立受控任务，二者择接收层闩为默认。
13. 新增 partial 行后要补异常退出恢复：`sealAbandonedSessions` 在封存 assistant 记录的同一事务中，把该记录残留的 assistant partial 行转为 final + interrupted，保留已经保存的正文；不得影响会议/字幕的 partial 规则。进程崩溃前尚未持久化的内存 delta 不承诺恢复，不增加逐 token 写库。

启动和结束须避免自等待：`stopper` 不能 await 一个正在等待 `coordinator.finalize` 的同一任务；保存 worker 与 reply producer 的句柄要分开。

完成条件：生成中/生成后播放中打断均可重新打开 Store 回看；同一回复只有一个 ID、一个 ordinal；无旧音、无旧回复写入新会话。

## S5：设备重建通知与恢复（D05）

文件：`AssistantAudioSession.swift`、`AssistantSession.swift`、`AssistantTTSStreamCoordinator.swift`。

1. 在现有音频协议增加明确的设备重建事件（拟新增），携带失效的 playback epoch/设备 generation 与恢复结果；不要把 discarded frames 伪造成 rendered 回调。
2. 引擎串行队列在丢弃旧缓冲时推进设备 generation，并通知 MainActor；重建期间阻止该旧 epoch 的新 enqueue。异步通知不能留出把旧 PCM 放入新引擎的窗口。
3. 上层只中止对应旧 utterance、使账本失效并归零，经 S4 保存 interrupted。不能等旧 rendered 回调归还已丢弃的帧。
4. 成功重建后，允许下一轮使用新 epoch，当前这一轮不自动重放。界面显示“音频设备已切换，本次朗读已停止”。
5. 重建失败时停止 capture/WS，按同一会话记录中断，保留文字输入及显式重试。原先 onFailure 只设置 lastFailure 的逻辑改为生命周期处理。
6. 重建完成通知携带 token；结束/重连之后到达的旧设备通知只清理旧实例。

完成条件：fake 注入“有排队采样时重建成功/失败”后账本不再悬挂；旧 rendered 不清新预算；成功可发下一轮，失败不假称聆听。

## S6：真正可用的文字降级（D07）

文件：`AssistantSession.swift`、`AssistantView.swift`、`SessionCoordinator.swift`、`SessionDomain.swift`。

1. 新增明确 `ensureTextConversation` 与发送结果，例如 `.accepted` / `.rejected(message)`（拟新增）。只要求 LLM 配置和 Store；不检查 ASR/TTS capability、不请求麦克风、不打开 WS。
2. ready 状态点击文字发送直接建立文字记录；麦克风拒绝/占用时仍走同一入口。语音启动失败不能导致 typed 先丢失。
3. 初始人设、记忆、LLM 快照只初始化一次。语音重试或文字升级语音不能重置这些上下文。
4. 保留当前 `SessionAudioSource` 的“所选采集来源配置”语义，文字记录沿用助手的预选 `.microphone` 配置，不能把它展示成“实际用了麦克风”。实际问题来源继续以已有 `line.source = keyboard` 表示；本轮 runtime 使用 text-only 模式，回看助手记录没有 microphone 用户行时显示“文字对话”（空记录显示“无对话内容”），不显示实际麦克风采集声明。已核实 schema 的 audio_source 是无 CHECK 的 TEXT，但旧版 `sessionRecord` 遇到未知枚举会跳过记录，因此本次明确不新增持久化 `.none`，不引入数据迁移。新文字记录的 engineProfile 用现有缺省语义 `unknown`，不编造一个实际运行档位。
5. SessionCoordinator 添加显式 sessionID 的封存门面，水位和语音变更写入均验证目标记录身份；文字操作不能影响另一会议的 activeSessionID、计时、watermark、设备租约。
6. View 在 `.accepted` 且当前草稿仍等于发送时快照时才清空。用户等待期间输入的新内容不得清除；双击发送做 single-flight，旧 3 秒轮询移除。
7. 存储失败/配置失败显示原因并保留原草稿；LLM 后续失败不把已落库的用户问题复制回草稿，不自动重复发送。
8. 文字模式下回复不自动朗读；没有有效 voice transport 时重播按钮禁用并显示“启用语音后可朗读”，不偷偷获取设备。
9. 助手页结束与回看改走 §4.2 所定义的统一助手结束结果；不要误结束当前会议。

完成条件：拒绝麦克风与会议占用两种 fake 场景都能打字回答；零音频/WS 调用；另一功能状态完全不变；问题恰好落一行。

## S7：修复时间语义（D09）

文件：`AssistantSession.swift`、`SessionDomain.swift`、`SessionStore.swift`、`AssistantView.swift`。

1. 移除不再有有效写入的 `pendingItem/commitCursor` 时间窗口实现，改为连接 token + itemID 索引的首个非空证据时间。
2. 每个连接建立 `ContinuousClock.Instant` 与 Date 锚点，通过 envelope.receivedAt 计算单调、可重现的本地观测时刻；不要在 SQLite await 后重新取当前时间。
3. 有 hypothesis/delta 时取首个非空证据；没有 partial 的 final-only item 取 final 接收时刻。重复 final 不改第一次时间，失败/定稿后清理 item 映射；重连清理旧连接条目。
4. 当前方案明确不新增 sample-span 公共接口。语音行精确 `tStart/tEnd` 写 NULL，`timingQuality = .unavailable`，直到已有合法对齐证据能证明精确边界。不要添加假的 aligned 标记。
5. `LineDraft` 拟新增可选 `createdAt`，默认 nil 继续沿用 Store 当前插入时间；助手传首个观测时刻。Store 只替换 created_at 绑定来源，不改表结构。实时 Turn 和回看 TranscriptLine 使用同一值。
6. 展示语义为“收到这句的时间”，不再声称“开口时间”；NULL 的导出时轴显示缺失，不转成 00:00。仅修改助手相关文案/消费点，其他会话保持原行为。
7. 历史恒零数据不批量修正，没有证据就不能重造过去的时轴。

完成条件：多条 item 的 createdAt 随观测时间变化，实时/回看相同；精确时轴缺失可识别；重连/时钟跳变不串 item。

## S8：Responses 成功终态判定（D10）

文件：`LLMProvider.swift`、现有 `LLMProviderTests.swift`；必要时拟新增 `LLMResponseStreamState.swift` 作为纯解析状态，不重写 HTTP transport。

1. 给本轮流建立 `awaitingTerminal / completed / failed / cancelled` 状态；记录 response ID（若事件提供），不接受不同响应的成功终态。
2. 继续按现有 delta 类型输出正文；`response.completed` 确认成功，`response.failed`、`response.incomplete`、`error` 立即失败。
3. EOF 或 `[DONE]` 在 completed 之前抛专门可读错误“回答提前结束，已保留收到的内容”；不要把非空正文当成功条件。
4. 收到合法 completed 即终止本轮读取，不要求提供方再关 TCP；取消底层读取的资源，但不能将自己的正常收尾又报告为取消错误。
5. 空成功响应允许 provider 正常结束，由 AssistantSession 现有空内容提示处理；refusal 文本仍需成功终态，不能因看到 refusal delta 就自动算成功。
6. 非 JSON data、关键事件缺失必要字段不能无限静默跳过直到假成功；明确失败。忽略注释/心跳和不影响本任务的有效事件。SSE 多行 data 的拼接按事件边界处理，测试按网络切块而非按 JSON 完整行假设。
7. 调用方取消保持取消类型贯通；与 D06 的 provider 故障收尾区分。已输出正文后不自动重试请求，避免重复历史、朗读和费用。
8. 修改共享 provider 时确认所有 stream 消费者；测试原有 thinking profile、请求形状不变。不升级 SDK、不引入另一份网络栈。

完成条件：delta+EOF 必须失败，delta+completed 必须成功；D06 接收到失败后关闭 TTS 并保存部分正文。

## S9：保留 TTS 空白（D11）

文件：`AssistantSession.swift`、现有 `AssistantSpeechTextBufferTests.swift`、新增 `AssistantSessionTests.swift`。

1. 仅用“已累计文本含非空白字符”决定第一次 start。
2. 启动前保留有界 pending 原始文本；成功 start 后一次 offer pending，清空该缓冲；后续每个 delta 原样 offer，含空格和换行。
3. 纯空白整轮不 start；前导空白缓冲必须复用本轮文本上限或在超限时明确失败，不能另建无界 buffer。
4. 原始显示、history、SQLite 不清洗；TTS 仍由原有 `VoicePrompt.spokenText` 清洗。断言需区分清洗前分词边界保留与清洗后合法输出，不能要求 Markdown 原样朗读。
5. start 失败之后只停本轮自动朗读、继续正文与落库，不无限重试 start；状态通过统一收尾归位。

完成条件：拆分空格/换行与整段输入在清洗前拼接完全一致；纯空白零 TTS start。

## S10：文档同步与交付

修改 `docs/developers/macos-app-development.md`、`docs/developers/macos-app-audio-capture.md` 中受影响的启动/重连/设备切换/时间语义；UI 交互说明涉及实质变化时同步 `macos-app-design-system.md` 的对应规则。无需改根 README。

D01–D11 本身不需要新 wire 字段；服务端 B 项同步 `contracts/realtime-openai.md` 的取消顺序、终态屏障、limits 与 update 原子性语义。`contracts/realtime-events.schema.json` 只有在对应字段约束实质变化时更新；不为了文字说明改 REST OpenAPI。数据库 CHECK 与模型协议扩展仍非本次目标。

## SB0：服务层回归基础与提交分包修复（B01、B03）

文件：`src/speechrail/application/realtime_openai.py`、必要时 `src/speechrail/realtime/speech_admission.py`；测试 `tests/test_realtime_admission_commits.py`、`tests/test_realtime_openai.py`。

1. 先用脚本化 VAD score、记录收到 PCM 的 fake ASR 建立两个失败用例：多帧包中跨句末；接近 item cap 时同包继续语音触发 rollover。用 gate 和有界测试 watchdog 定位挂起，不把 timeout 本身当作功能断言。
2. 拆分三个职责（以下名称拟新增）：`_drain_vad_frames` 只按顺序评分完整帧；`_consume_admitted_pcm` 顺序切分并投递已确认的语音；`_finalize_current_asr_item` 只完成一个 ASR item，不再回调 admission dispatcher。
3. 所有完整帧只在 drain 入口评分一次，自动 `vad_stop` 只结束当前语音/item，不能拿走 `_vad_raw_buffer` 后续帧。返回外层 loop 继续评分，保留绝对 sample cursor。不把下一句当作本句的 resampler EOF。
4. 容量 rollover 只切换 ASR item，**不**调用 `SpeechAdmission.finish()`，不重置 ACTIVE/HANGOVER，不清空未评分音频或 prefix。按 PCM16 的 2-byte 对齐边界将 `dec.pcm` 分段投递；可切分一个大 prefix 决策，不能让单个决策越过 cap。
5. item 已满时先 finalize，再建立下一个 item 并递增相应 generation；精确满额但没有剩余 PCM 时不创建空 item。保留 diarization 的容量政策和绝对时轴，不能用 wire bytes 代替 16 kHz kernel bytes。
6. 只有显式 client commit/输入真正结束才 flush resampler、处理不足一帧尾部并调用 admission.finish。先排空完整 VAD 帧，再处理短尾；短尾沿用当前 admission 状态，不给下一段完整帧虚构 probability。确认 resampler 尾部只投递一次，alignment/diarization 收到同样样本跨度。
7. `_commit_lock` 只由最外层 item-finalization owner 获取；锁内不得进入可再次 finalize 的 dispatcher。尾部产生的 audio 决策先经 `_consume_admitted_pcm` 处理，必要 rollover 返回后再完成显式末次提交；重复 commit 用 item/generation 身份幂等。
8. 将显式 commit 的总 deadline 覆盖其尾部处理、ASR commit、terminal 等待和必要清理；超时/失败后丢弃失败 item 的残留并释放 owner。不能重播已提交 PCM，也不能让下一次 clear 再产出该失败 item 的成功事件。
9. 不要求不同分包具有相同事件投递墙钟时间；比较 admitted PCM、item 样本跨度、顺序与终态。预期没有精确时间的 fake 不断言模型文本或真实声学质量。

完成条件：同一合成 PCM 按一包/逐帧/跨半帧分包得到相同语音内容及确定性容量切分；无重入锁、无丢帧/重帧；连续多 item 后 governor 与 fake session 归零。

## SB1：取消绕过音频等待（B02）

文件：`src/speechrail/http/routes/realtime_openai.py`、`src/speechrail/application/realtime_openai.py`；测试 `tests/test_realtime_openai.py`，复用 `tests/test_resource_governor.py` 的可控资源 fixture。

1. 删除 TTS cancel 对 `latest_append_dispatch` 的依赖及只为该屏障维护的 future；普通 client events 继续 FIFO，原有队列字节/条数上限与扣减不能遗漏。
2. 控制队列按控制事件顺序立即派发匹配 request_id 的 TTS 取消；不等待 ASR append、commit、reserve 完成。cancel 只结束对应 TTS owner，不等同于 `input_audio_buffer.clear`，不能丢弃已入队用户音频。
3. 保留 request_id 校验、重复 cancel 幂等和旧 request 不影响新 request；控制路径与 `_run_tts_stream` 的并发收尾使用 SB3 的 owner 身份。未建立的 utterance 依既有契约报错，不把 cancel 记到未来 request。
4. 路由断线同时撤销两条消费任务，按现有异常出口收回 pending 字节，不遗留 dispatch future；不引入第二个 socket reader。
5. 用真实 governor + fake TTS 持有 lane，让 append A 确定卡在 reserve、B 确定入队，再发 cancel。断言 cancel handler 在 A/B 完成之前被调用；释放假 worker 后 A/B 能继续，字节/样本顺序不变。另测长 ASR commit + 排队音频时 cancel 独立推进。

完成条件：上述场景不靠 request timeout/TTS 自然结束解除阻塞；不改 `_allow_heavy_overlap` 和 lane 数量。

## SB2：真实消费水位与全链路 limits（B04、B07）

文件：`domain/tts_stream.py`、`application/tts_stream.py`、`application/realtime_openai.py`、`compatibility/openai_realtime.py`、`backends/qwen3_tts.py`、`backends/qwen3_tts_stream_client.py`、`backends/qwen3_tts_stream_host.py`、`backends/qwen3_tts_worker.py`（均在 `src/speechrail/` 下）；相关 fake opener 同步签名。

1. 使用唯一 `TtsStreamLimits` 验证器；把 effective limits 作为显式参数从 `TtsStreamService._open_session` 经 synthesizer、parent session、IPC start 传到 host。拟调整内部 opener 为 `open_incremental_stream(options, *, limits=...)`；项目内所有实现/fake 同步，不使用捕获 TypeError 重试旧签名。
2. IPC start 的 limits 只含既有安全字段，worker 独立校验类型、正值、关系及不超过服务默认值；不能信任父端 JSON。worker started 回传有效 limits，父端核对一致后才向 WS 发 started，不一致按协议失败并清理。
3. host 是文本接受/消费权威。拟新增内部 `tts_stream_text_consumed` 帧，包含 request_id、单调 `consumed_codepoints_total` 与对应 `through_sequence`，不包含原文。新增常量、编码/解析分支及 IPC 文档说明；不暴露为公共 WS 事件。
4. `host.step()` 返回 `waiting_for_text` 时，当前已接受文本 token 已用完；记录截至此刻累计 accepted codepoints/sequence，通过差值调用 `mark_text_consumed` 并发水位。重复饥饿只发递增水位。成功 terminal 可结清已消费预算；failed/cancelled 只释放整个状态，不冒称内容已消费。
5. host 的 append 和 step 必须在现有模型执行线程串行；先记录消费水位，再处理后续 append。parent 依据水位差归还 pending；相同水位幂等，倒退/超过已 ACK 总量/请求身份不匹配 fail-closed。ACK 与水位通过同一有序 IPC 控制输出，不能让水位抢到对应 ACK 前面。
6. ACK 仍只表示 vendor 已接受文本；不能借收到 PCM、完成播放或收到 ACK 推断字符消费。`accepted_tokens` 不用于字符记账；默认不改 vendor overlay。在已有纯 Python vendor 状态测试中钉住 `waiting_for_text` 真正 starved 的语义。
7. 修复 append 的事务边界：预算/sequence 校验不提前永久推进父端已接受状态。发送中的文本占用独立有界 reservation；ACK 帧处理器先提交状态，再唤醒 append waiter，保证紧随 ACK 的消费水位不会抢先看到旧计数。明确拒绝后撤销，状态不明确的 IPC 超时则终结本轮，不猜测重发。host 先验证，再 vendor append 成功后提交 accepted；vendor 异常终结本轮。
8. 背压拒绝必须保持 sequence 未消费，客户端可在模型消费后按原 sequence 重试；不可把可重试背压变成 sequence gap。新 append 的 pending = 已接受未消费 + 尚未 ACK reservation，total = 已接受累计 + reservation；重试不重复累计。
9. pending 音频预算通过同一 effective limits 传递并在 host/parent 实际持有 PCM 的排队处生效。一个 PCM chunk 大于 budget 时按 sample 对齐切分，保持连续 chunk_index/sample_offset；使用有界的切片游标按额度投递，不一次把全部小块另装进无界列表。只在 writer 已交付/parent 已消费后归还对应字节。明确区分模型单次 step 返回的临时 PCM 与待发送队列预算，不把切片后仍持有的队列数据漏计；不得通过大包直通绕开预算或在入队时就标 delivered。
10. `max_pending_audio_bytes` 小于一个 PCM16 sample（2 bytes）或为奇数时在 start 边界明确拒绝，并同步契约/测试；不能接受一个永远不能容纳样本的预算。慢消费者超时继续使用现有错误语义，不无限缓存切分后的 chunks。
11. 保留总字符 4096、默认 pending 2048。连续五批 512、每批等消费水位后继续，应接受 2560；不消费时超过 pending 必须拒绝；无论消费多少，超过 total 仍拒绝。两种限额不能复用一个计数器。

完成条件：wire/controller/parent/host 生效值完全相同；背压可恢复、序列可重试、Unicode codepoint 计数一致；队列在小音频预算与慢消费者下有界。新增内部帧与父子版本一起交付，不支持混装旧 worker。

## SB3：终态前完成回收与 owner 退休（B05，配合 B02）

文件：`src/speechrail/application/tts_stream.py`、`src/speechrail/application/realtime_openai.py`、必要时 `src/speechrail/backends/qwen3_tts.py`；测试 `tests/test_tts_stream_application.py`、`tests/test_realtime_openai.py`。

1. 固定生命周期为 ACTIVE → SETTLING → RELEASED → TERMINAL_SENT。结果一旦 claim，不再发 audio；并发 cancel/正常完成只竞争同一个结果和清理任务。
2. `_settle` 先完成 worker/session close 确认，再释放 governor，最后投递终态。不能只对 close 抛错使用 suppress 后假装已回收；复用已有 worker abort/lease 回收路径。回收无法确认时隔离 owner 并关闭 WS，不能允许新 start。
3. 将“活动 utterance 的占用”与“旧 task 是否尚在返回”分离。每个 request 有不可变 owner token、receipt、terminal 状态；`_claim_tts_request` 只检查当前活动/settling owner，不再把旧 task.done 作为唯一准入依据。
4. 资源确认释放后，冻结本轮 terminal payload，按 owner token 退休当前连接占用并发送终态。确保 terminal 在新 request 的 started 前写入 socket（复用输出串行化；必要时增设仅控制发布顺序的锁），不等待 App ACK，不持有会阻塞唯一接收泵的锁。
5. 旧 task 的 finally、cancel 回调、`_release_stream_state` 必须 compare-and-clear，仅能清理自己；不可清空新 controller/request/receipt 或重置新 terminal 标记。request ledger 保留同连接唯一 ID 约束。
6. 失败打开 utterance 的路径也必须遵循资源清理、owner 退休、单终态顺序；没有 started 的失败保持既有公共错误形状，不制造一个虚构 started。
7. 在 fake close 上设 gate：释放 gate 前不得见 wire terminal；释放后收到 terminal 立即发新 request，必须正常 started；让旧 finally 延迟执行，证明新 request 不受影响。另测 cancel/complete 竞态和终态写出失败断线。

完成条件：终态后新 request 可开始，不因旧 task 尾部被拒绝；资源归还一次、终态一次、旧音频零投递。App S4 的屏障必须用该契约验证。

## SB4：ASR 终态与取消传播（B06）

文件：`src/speechrail/application/realtime_openai.py`；测试 `tests/test_realtime_openai.py`。

1. `_drain_asr_events` 对 `CancelledError` 清理后重新抛出；不要与 WebSocketDisconnect/RuntimeError 合并。连接关闭可退出投递，但仍通过 owner 的 finally 回收。
2. `RuntimeError` 作为 backend iterator 错误处理；发送失败与读取失败分开捕获。只有确认 socket 已关闭时才忽略发送错误，不能用异常类本身推断断线。
3. 为一个 ASR item 建立单一终态归属（拟新增内部 result/terminal claim）：reader 的 completed/failed、commit deadline 和外层异常都按 item/generation 竞争一次。允许已有协议级 error 与 failed 各自承担其职责，但不得发送两个相互矛盾的 item 终态。
4. reader 正常 EOF 但没有 completed/error 也视为失败，不让空返回冒充成功。正常 completed 已发送后发生的 teardown 问题单独诊断，不补第二个 failed。
5. 外层 timeout 捕获后走失败清理并保留稳定 `backend_timeout` 错误 envelope/commit_event_id；区分外部 cancel，不把用户断线取消当 backend timeout。所有清理校验原 item 身份。
6. 保留现有 hangs-in-commit 测试并准确命名；新增 commit 立即返回、events 永不终止的 fake。断言 deadline 到达、有失败证据、无 completed、资源归零，后续新 item 可用；再测 RuntimeError、ValueError、无终态 EOF、disconnect。

完成条件：ACK 前后两类超时均覆盖；没有吞取消造成的假成功，不重复 item 终态。

## SB5：原子 session.update（B08）

文件：`src/speechrail/application/realtime_openai.py`，必要时抽出同模块内候选配置值类型；测试 `tests/test_realtime_openai.py`、`tests/test_diarization_extensions.py`。

1. parse candidate 后先完成纯校验：首次音频限制、voice 可用性、model/asr revision、alignment/diarization 能力、VAD 参数与 readiness。此阶段不得写 live flags、关闭旧资源或清空 buffer。
2. 以局部 candidate bundle 准备确有变化的新 VAD/admission/diarization；资源操作在独立 AsyncExitStack 下进行，不通过读取/写入 self 的 `_ensure_diarization` 偷渡候选配置。未变化的对象复用，避免无关 update 重置 VAD 状态。
3. 全部准备成功且 session/connection token 仍有效后，在无 await 的发布段一次替换 config、flags、detector 和资源引用；再退休不再使用的旧资源，然后发送 session.updated。旧资源退休失败应进入明确的连接失败/隔离路径，不能当作普通 rejected update 回到可继续使用状态。
4. 校验、准备失败或准备期间取消，仅关闭新创建的候选资源，旧配置、VAD cursor/buffer 和旧引用保持不变；不要对所有字段做易漏的反向赋值。
5. 发布后网络发送失败按断线清理，不声称这次 update 在服务内部未生效；原子拒绝保证针对发布前的业务校验/准备失败。
6. 回归覆盖 alignment/diarization 开关变化 + revision 冲突、不可用 voice、VAD readiness 失败、候选创建失败/取消。对比完整旧快照及对象身份/close 次数，再发送合法更新并 append，证明连接仍正常。

完成条件：每个 rejected update 无部分生效；成功只发布一次；不泄漏候选资源，也不关闭仍在使用的旧资源。

# 6. 关键实现说明

以下均为拟新增设计示意，不是当前已存在接口。

## 6.1 waiter 精确释放

```swift
struct WaitKey: Hashable {
    let utteranceEpoch: Int
    let target: WaitTarget
}
struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<WaitResult, Never>
    let timeoutTask: Task<Void, Never>
}
// MainActor 隔离
var waiters: [WaitKey: Waiter]

func resolve(key: WaitKey, waiterID: UUID?, result: WaitResult) {
    // timeout/cancel 指定 waiterID；网络 ACK 以 key 定位。
    // 先匹配、从表中移除，再 cancel timer + resume。
    // 无 waiter 时只缓存允许预到达的 ACK/start；缓存必须带 epoch。
}
```

timeout timer 的 cancel 不能触发第二次 resolve。invalidate 必须同时覆盖“已注册 waiter”和“cancel 已到但尚未注册”的路径。

## 6.2 生命周期与资源发布

```text
开始:
  分配 token，登记 pending operation
  await 准备依赖
  校验 token
  创建本操作私有设备/连接
  每个 await 后校验 token
  建档或取得已有记录
  校验 token，发布到 session，开始 event pump

结束:
  撤销 token，禁止新问题/新回复
  取消 pending operation
  对私有资源等待可证明的释放/晚到 cleanup
  停止当前回复与语音资源
  保存终态并按本 sessionID 封存
  确认仍是同一租约，再释放 coordinator owner
```

不可取消依赖的“有界返回”不等于资源释放完成。资源尚未证明释放时保留租约或阻止新准入，避免重现 D02。

## 6.3 回复记录 SQL 约束

示意更新条件：

```sql
UPDATE line
SET text = ?, status = 'final', interrupted = ?
WHERE id = ? AND session_id = ? AND role = 'assistant';
```

检查受影响行数；0 行不能被静默当成功。初次插入使用现有显式 ID 的 appendLine，ordinal 由现有 SQL 分配。重复终结保持同一内容或只将 interrupted 从 false 推向 true，不允许旧成功覆盖新的 interrupted=true。

`isInterrupted` 表示回复/朗读未完整交付，不表示精确播放位置。当前项目没有逐字已听凭据，本次不实现按音频截断文字。

## 6.4 状态与持久化边界

- connection token 隔离 ASR itemID 和连接重试；reply token 隔离 LLM；utterance epoch 隔离 TTS/播放。三个不可互相替代。
- 新回复开始前，旧回复已被冻结且保存顺序已确定；落库更新失败不能使旧 async 操作写入新 replyID。
- 结束 drain 只允许最后用户句落库，不触发“会话已结束后仍回答”。
- 文字模式没有设备租约，不允许从 coordinator 的 activeSessionID 推导自己的记录身份。
- 会话级 persona/memory/LLM 快照与音色变更记录在重连中保持；新会话才清零。

## 6.5 服务层不得互相替代的屏障

| 屏障 | 证明什么 | 不能证明什么 |
|---|---|---|
| append 入队/dispatch | 传输已收取/开始处理 | ASR 已准入、TTS 可以取消 |
| text_accepted | 文本已进入模型输入 | 文本已消费、已合成或已听到 |
| 内部 consumed 水位（拟新增） | 截至该水位的文本已进入模型消费流程 | 音频已生成/投递/播放 |
| TTS terminal | 服务资源与 request owner 已退休、旧音频不再发送 | App 扬声器已排空 |
| App rendered/ledger drain | 当前播放 epoch 已播完 | LLM 成功、记录持久化成功 |
| ASR completed | 该 item 有识别终态 | metadata/alignment 必然成功 |

App 同时满足“远端 TTS 终态”和“本地播放排空”才判完整朗读；本地停播无需先等远端取消，远端终态必须独立处理，不能阻塞事件泵。

## 6.6 pending 记账与拒绝不消费序号

拟新增的内部记账示意：

```text
accepted_total: 累计已 ACK 的 Unicode codepoint 数
consumed_total: 已确认消费的累计水位，单调且 <= accepted_total
reserved: 已发送但未获确定 ACK/拒绝的字符数
pending = accepted_total - consumed_total + reserved
total_for_admission = accepted_total + reserved

ACK(sequence): 提交 reservation -> accepted，然后唤醒 waiter
reject(sequence): 撤销 reservation；不推进 accepted_sequence
consumed(request_id, through_sequence, total):
  验证身份、已 ACK 序号、水位关系
  仅归还 total - consumed_total，不归还累计 total
terminal/cancel: 丢弃本 request 的全部局部状态，不复用到下一轮
```

水位不跨 request，request_id 不复用；通过 ACK 序号及累计字符快照验证水位，不用 token 数推算 Unicode 长度。水位消息需要进入有界控制输出，不能被 PCM backlog 无限饿死；取消仍拥有最高控制优先级。

## 6.7 终态发布顺序

```text
claim result(owner)                    # 恰好一次，禁止新 audio
await close_or_abort_confirmed(owner)  # 仅清理此 owner；必须可证实
await release_governor(owner)
freeze terminal payload(owner)
retire connection owner if same token
publish terminal before next started
old task finally: compare-and-clear only
```

若回收失败/超时，不走 retire+可复用 terminal，关闭/隔离连接并报告失败；底层资源何时重新可用仍由现有 worker 生命周期决定。不要在 asyncio task cancelled 之后放任 detached cleanup 成为无 owner 的后台任务。

## 6.8 Xcode 目标登记程序

已核实的现状（`macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`，`objectVersion = 56`）：

| 用途 | 现有标识 |
|---|---|
| 应用源文件组 `SpeechRailApp` | `A30000000000000000000002` |
| 单测源文件组 `SpeechRailMacControlTests` | `A30000000000000000000006` |
| App Sources phase | `A70000000000000000000001` |
| Unit Test Sources phase | `A70000000000000000000012` |
| 参照三联（同一 fileRef，两个 target） | fileRef `A400000000000000000000DA`、App BuildFile `A500000000000000000000F9`、Test BuildFile `A500000000000000000000FC` |

标识家族约定：FileReference 用 `A4…`，BuildFile 用 `A5…`，Group 用 `A3…`，Sources phase 用 `A7…`。

每个新文件必须改四处，缺一即编译失败：

1. `PBXFileReference` 段新增一条，形态同
   `A400000000000000000000DA /* X.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = X.swift; sourceTree = "<group>"; };`
2. `PBXBuildFile` 段为**每个**目标各新增一条，`fileRef` 指向上面那一条；注释里的 target 名要与所属 phase 一致（`in Sources` / `in Test Sources`）。
3. 对应 Group 的 `children` 追加该 fileRef（生产文件进 `A3…02`，测试文件进 `A3…06`）。
4. 对应 Sources phase 的 `files` 追加该 BuildFile。

ID 分配纪律：

- 取家族末尾未占用值，写入前逐个 grep 确认全文件 0 命中。
- 保持长度与既有条目完全一致（24 位十六进制），不要缩短或改前缀风格。
- 不改 `objectVersion`，不重排既有条目，不重命名已有 Group/phase。
- 不复制 fileRef：两个 target 必须引用同一条（见 §2.4）。

验证：

```bash
# 变更面：应只有新增行，没有删除/改写既有条目
git diff -- macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj

# 编译：SwiftPM 之外的真实 App 目标
bash scripts/macos_app_build.sh --configuration Debug
```

`git diff` 中若出现既有行被修改（而非纯新增），说明误改了共享条目，必须还原该行而不是继续叠加。编译错误里的 `cannot find type 'X' in scope` 与 `duplicate symbol` 分别对应“缺 BuildFile”和“FileReference 被复制/同一文件在两个 phase 各建一条 fileRef”，按此定位，不要盲加条目。

# 7. 测试方案

全部为拟实施的测试，当前未执行。使用人工构造短文本、合成 PCM 字节和临时 SQLite；无真实音频、真实凭据、网络或模型。并发测试以 continuation gate/虚拟时钟控制时序，禁止靠长时间 sleep 碰运气。

| 编号 | 测试文件（标明新增） | 必须覆盖的断言 |
|---|---|---|
| D01 | 现有 `AssistantTTSStreamCoordinatorTests.swift` | ACK 等待与 playback 等待双向交错；各自超时；invalidate/cancel 释放全部；超时迟到不结束新 waiter；重播同 reply 的旧 epoch 不污染新一轮 |
| D02 | 新增 `AssistantSessionTests.swift`；新增 `SessionCoordinatorLifecycleTests.swift` | 每个启动 await 处 stop；晚到成功/失败；stop 后立即切换功能；旧 catch 不清新占用；建档期间取消只封存自己的记录；零晚到上传 |
| D03 | 新增 `AssistantSessionTests.swift` | 两轮对话断线重连，sessionID/记录数/历史/ordinal 不变；两次重试 single-flight；重试失败 interruption 保持；重试中结束 |
| D04 | 新增 `AssistantSessionTests.swift` | 静音仍可结束、页面投影仍 active；无上行；静音时 WS close 被处理；新会话重置静音，同会话重连保留 |
| D05 | 新增 `AssistantAudioSessionLifecycleTests.swift`；现有 TTS 测试 | 抽出/注入 route-change 通知，排队音频被丢弃、账本失效；恢复成功允许新 epoch；恢复失败释放采集；迟到 rendered/rebuilt 不动新代 |
| D06 | 新增 `AssistantSessionTests.swift` | 首段后 LLM error/incomplete/EOF：先停本地播放再网络取消；清闭麦；部分正文保留；WS close 取消 LLM；cancel terminal 超时不直接新 start |
| D07 | 新增 `AssistantSessionTests.swift`；新增 `AssistantComposerTests.swift` | 麦克风拒绝/会议占用下文字成功；零 capture/WS；另一个会话水位/ID/租约不变；草稿失败保留、新输入不被旧完成清除、双击只插一行 |
| D08 | 新增 `AssistantSessionTests.swift`；新增 `AssistantPersistenceTests.swift` | 首段后 ESC；生成完成后停播；barge-in；重复取消；成功/取消竞态；重新打开 Store 检查单行、稳定 ID、正确 interrupted；保存失败可重试；异常退出封存 partial 后正文可见 |
| D09 | 新增 `AssistantSessionTests.swift`；新增 `AssistantPersistenceTests.swift` | 两 item 不同 observedAt；final-only；snapshot 修订不改首时刻；重复 final；重连 itemID 复用；墙钟变化；NULL 时轴与 unavailable；实时/回看 createdAt 相同 |
| D10 | 现有 `LLMProviderTests.swift` | delta+EOF、delta+[DONE]、失败/不完整、completed 后不断 TCP、空 completed、取消、坏 JSON、SSE 多行/跨网络块、responseID 不匹配 |
| D11 | 现有 `AssistantSpeechTextBufferTests.swift`；新增 `AssistantSessionTests.swift` | 单独空格/换行、连续空白、前导空白、纯空白、Unicode/Markdown 邻接、start 延迟期间累计文本无重无漏 |

补充闭环用例放在新增 `AssistantSessionTests.swift`，以真实 SessionCoordinator + SessionStore、fake 其他依赖完成：

1. 语音启动 → 两个 ASR item → 两次成功 LLM/TTS → 播放排空 → 结束 → 重开 Store 回看。
2. 语音回复半途断线 → 保存 partial/interrupted → 重连同一记录 → 下一轮 → 结束。
3. 会议持有设备 → 助手纯文字发送 → 结束助手 → 会议 owner 和记录不变。
4. 结束中的 ASR final 只落用户行，不触发新 LLM；旧 reply/设备/WS 回调全部无副作用。
5. 已有会议、字幕、提词器的 coordinator 基本生命周期测试保持通过，避免全局租约修复引入跨模块回归。

UI 展示验证优先通过生产使用的纯状态投影与输入接收逻辑测试；它们不能替代真实窗口验收。XCUITest、点击自动化、录屏、真实设备路由切换仅在当次明确授权后执行。

## 7.1 服务层定向回归

以下文件均已存在；测试名均为**拟新增**，可按项目命名规范微调。先取得预期断言的失败，再修复；不能以导入/编译错误充当红测试。

| 编号 | 测试文件 | 拟新增用例与核心断言 |
|---|---|---|
| B01 | `tests/test_realtime_admission_commits.py` | `test_rollover_with_buffered_frames_does_not_reenter_commit`：cap 边界与剩余帧下完整返回；多次 rollover 样本精确分配、无空 item、资源归零；短尾跨 cap 也覆盖 |
| B02 | `tests/test_realtime_openai.py` | `test_cancel_bypasses_two_queued_appends`：TTS 持 lane、A 等 reserve、B 入队时 cancel 先运行；另测长 commit、重复 cancel、旧 request 和断线字节账本 |
| B03 | `tests/test_realtime_admission_commits.py`、`tests/test_realtime_openai.py` | `test_vad_packetization_preserves_following_utterance`：相同 speech/silence/speech 按单包/32 ms/不齐帧分包；两句 admitted PCM 及样本跨度一致，无二次评分或尾部重复 |
| B04 | `tests/test_tts_stream_state.py`、`tests/test_tts_stream_worker.py`、`tests/test_tts_stream_client.py` | `test_consumed_watermark_restores_pending_budget`：五批 512 可达 2560；不消费时仍限流；重复/倒退/越界水位；ACK 后水位立即到达；背压重试原 sequence；total 4096 边界 |
| B05 | `tests/test_tts_stream_application.py`、`tests/test_realtime_openai.py` | `test_terminal_waits_for_resource_release`、`test_start_immediately_after_terminal`：close gate 前零终态；资源释放后终态一次；立即新 start；旧 finally 迟到不能清新 owner；close 失败必须断线/隔离 |
| B06 | `tests/test_realtime_openai.py` | `test_commit_ack_then_hung_reader_times_out`：commit 返回但 reader 挂起；RuntimeError/EOF/外部取消；deadline 发失败、无 completed、资源释放；completed 后错误不产生矛盾终态 |
| B07 | `tests/test_tts_stream_application.py`、`tests/test_tts_stream_client.py`、`tests/test_tts_stream_worker.py`、`tests/test_realtime_openai.py` | `test_negotiated_pending_limits_reach_worker`：pending=4 拒绝未消费的 10 字符；小 PCM 预算拆包连续且队列峰值有界；奇数/<2 音频预算拒绝；非法/扩张 IPC limits 拒绝；started 值一致 |
| B08 | `tests/test_realtime_openai.py`、`tests/test_diarization_extensions.py` | `test_rejected_session_update_preserves_live_state`：revision/voice/VAD/候选初始化失败与取消；旧 flags/config/buffer/资源身份不变；候选关闭一次；合法重试正常 |

`tests/test_tts_incremental_vendor_state.py` 增加或复用纯 Python fake backend 场景，证明 `waiting_for_text` 只在输入 token 耗尽时出现，且可在该事件后继续 append；不加载 MLX、不更改 vendor overlay，也不宣称通过真实模型 gate。

所有挂起场景用 gate 确保进入目标分支，再触发取消/超时；watchdog 仅防测试永久卡死。断言事件内容、资源计数、采样集合和下一轮可用性，不只断言“函数返回”。

## 7.2 App—服务边界闭环

新增共享合成 fixture（拟新增 `tests/fixtures/assistant_realtime_lifecycle.json`），记录公共请求/事件及期望顺序，不含真实音频、用户文本或凭据。服务端通过 TestClient WebSocket + fake backend 验证实际事件；Swift 端通过已有 Realtime adapter 测试 seam 消费同一 fixture，路径通过源文件定位或显式测试 resource 注入，不依赖当前 cwd。必要时更新 Package 测试资源清单。

1. **打断闭环（D01/D06/D08 + B02/B05）**：音频排队且 TTS 活动 → App 立即停本地播放并发 cancel → 服务不等 ASR 队列 → 确认资源回收后 terminal → App 保存 interrupted → 新 request 正常开始；旧音频/旧 finally 不影响新轮。
2. **长回复（D11 + B04/B07）**：带独立空格/换行的合成 delta，累计超过 2048 且不超过 4096 → 消费水位归还预算 → 文本不粘连、无永久背压；总量越界仍可见失败并走 D06。
3. **输入分包（D09 + B01/B03/B06）**：多句合成音频经不同分包 → 每个 item 终态一次、内容不漏 → App 按各 item 的实际 envelope 时间落行；不把服务 sample span 和 App 本地观测时间混为一类。
4. **断线恢复（D02/D03/D04 + B06/B08）**：静音/已有历史状态下服务失败 → 清理 → 重连同一记录 → stale revision 更新被拒绝且无部分生效 → 正确 binding 更新成功 → 下一轮可用。

这是一组双方使用真实生产 adapter 的确定性契约闭环，**不是**已运行的真实 App→真实服务→真实模型端到端验收。无法复用同一 fixture 时需记录原因并保留双方等价断言，不能只测另写的模拟协议。

## 7.3 缺陷—实施—回归—验收追踪矩阵

本表是 §5、§7、§8.2 的索引，用于逐项对账，避免三处清单各自漂移。**实施进度不写在本表**，只由 `progress_ledger` 记录；本表的“回归测试”列填写的是必须存在的用例语义，不要求文件名一字不差。

| 缺陷 | 步骤 | 主改动文件 | 回归测试（§7 编号） | 验收项（§8.2） |
|---|---|---|---|---|
| D01 | S1 | `AssistantTTSStreamCoordinator.swift` | D01 交错/超时/invalidate | D01 |
| D02 | S2 | `AssistantSession.swift`、`AssistantSessionLifecycle.swift`、`SessionCoordinator.swift` | D02 启动取消矩阵 | D02 |
| D03 | S2 | 同上 + `SessionStore.swift` | D03 重连同一记录 | D03 |
| D04 | S3 | `AssistantSession.swift`、`AssistantView.swift` | D04 静音投影 | D04 |
| D05 | S5 | `AssistantAudioSession.swift`、`AssistantTTSStreamCoordinator.swift` | D05 设备重建 | D05 |
| D06 | S4 | `AssistantSession.swift`、`AssistantReplyState.swift` | D06 失败收尾 | D06 |
| D07 | S6 | `AssistantSession.swift`、`AssistantView.swift`、`SessionCoordinator.swift` | D07 文字降级 | D07 |
| D08 | S4 | `AssistantSession.swift`、`AssistantReplyState.swift`、`SessionStore.swift` | D08 稳定行 ID 与幂等终结 | D08 |
| D09 | S7 | `AssistantSession.swift`、`SessionDomain.swift`、`SessionStore.swift` | D09 观测时刻 | D09 |
| D10 | S8 | `LLMProvider.swift` | D10 终态判定 | D10 |
| D11 | S9 | `AssistantSession.swift`、`AssistantSpeechTextBuffer.swift` | D11 空白保留 | D11 |
| B01 | SB0 | `application/realtime_openai.py` | B01 rollover 无锁重入 | B01 |
| B02 | SB1 | `http/routes/realtime_openai.py`、`application/realtime_openai.py` | B02 cancel 旁路 | B02 |
| B03 | SB0 | `application/realtime_openai.py`、`realtime/speech_admission.py` | B03 分包等价 | B03 |
| B04 | SB2 | `domain/tts_stream.py`、`backends/qwen3_tts_stream_host.py` 等 | B04 消费水位 | B04 |
| B05 | SB3 | `application/tts_stream.py`、`application/realtime_openai.py` | B05 终态屏障 | B05 |
| B06 | SB4 | `application/realtime_openai.py` | B06 reader 终态 | B06 |
| B07 | SB2 | `application/tts_stream.py`、`backends/qwen3_tts*.py`、`compatibility/openai_realtime.py` | B07 limits 贯通 | B07 |
| B08 | SB5 | `application/realtime_openai.py` | B08 原子更新 | B08 |

跨层依赖边：D06/D08 的“终态后下一轮”验收依赖 B02、B05；D11 的长回复验收依赖 B04、B07；D09 的分包验收依赖 B01、B03、B06；D03/D04 的恢复验收依赖 B06、B08。服务端未修复前，App 侧对应验收项只能标“待跨层闭环”，不能记通过。

# 8. 验收标准

## 8.1 命令与执行边界

以下命令从仓库根执行，均为后续实施阶段的计划；**本方案阶段未执行**。SwiftPM 原生命令依据现有 `.github/workflows/ci.yml` 的 `swift test --package-path macos/SpeechRailApp`；新增测试过滤目标需在 S0 接入后使用。

```bash
git status --short --branch
git diff --check
swift test --package-path macos/SpeechRailApp --filter Assistant
swift test --package-path macos/SpeechRailApp --filter SessionCoordinatorLifecycleTests
swift test --package-path macos/SpeechRailApp --filter LLMProviderTests
swift test --package-path macos/SpeechRailApp --filter RealtimeTTSStreamTests
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests
```

实施中的必要定向 fake 回归按届时修复授权执行；本文件不授权完整套件、真实 worker 或 UI 自动化。依赖已存在时复用锁文件；若缺依赖需获取网络资源，明确记录，不以运行测试为由升级 SDK。

App 编译在获得构建范围授权后，通过已核对存在的包装脚本：

```bash
bash scripts/macos_app_build.sh --configuration Debug
```

构建前读取项目 release 技能，确认临时产物/LaunchServices 清理；不裸跑 xcodebuild，不安装 App。UI 测试另行授权，不把 `macos_app_test.sh` 混入默认验收。

服务层使用现有开发测试入口的定向形式；在 SB0–SB5 实施并获得对应测试授权后，从仓库根按组执行。以下均**未执行**：

```bash
uv run --extra dev pytest --no-cov tests/test_realtime_admission_commits.py tests/test_realtime_openai.py
uv run --extra dev pytest --no-cov tests/test_tts_stream_state.py tests/test_tts_stream_client.py tests/test_tts_stream_worker.py tests/test_tts_stream_application.py tests/test_tts_incremental_vendor_state.py
uv run --extra dev pytest --no-cov tests/test_resource_governor.py tests/test_diarization_extensions.py
git diff --check
```

逐项红绿阶段优先给以上命令添加对应测试 node ID；完成分组修复后再运行相关文件，不重复无关套件。若 fixture 的新增测试文件与此清单不同，交付时记录实际 node ID。涉及契约文档后按现有 CI 入口检查用户文档契约：

```bash
uv run python scripts/check_user_doc_contract.py
```

该脚本不能证明 WebSocket 时序正确；以 §7.1/7.2 的事件与资源断言为准。锁定依赖缺失时报告前置条件，不触发下载模型、安装 runtime、完整 benchmark 或真实 worker smoke。

## 8.2 必须全部闭合的清单

- [ ] D01：全部 waiter 恰好释放一次，交错场景没有挂起任务。
- [ ] D02：每个准备阶段取消后，旧操作不能重新采集或覆盖新 owner。
- [ ] D03：重连记录数与 ID 不变、历史不丢、失败保持中断。
- [ ] D04：静音界面仍 active，断线必达清理，跨会话静音初始化符合目标。
- [ ] D05：设备丢弃不伪造 rendered，预算清零/本轮明确终止，新代可继续。
- [ ] D06：LLM 失败/WS 断开后无继续播报或旧任务写回。
- [ ] D07：文字降级可用，零音频权限依赖，不影响另一功能，草稿不丢。
- [ ] D08：中断正文/标记重开 Store 后仍在，稳定行 ID，无重复 ordinal。
- [ ] D09：观测时刻一致，精确时轴缺失存 NULL，不继续制造恒零。
- [ ] D10：没有明确成功终态绝不报告完整回答。
- [ ] D11：TTS 原始输入与 LLM 原始增量拼接一致，纯空白不启动。
- [ ] B01：rollover/显式提交尾部均无锁重入；多 item cap 正确，任务与资源可回收。
- [ ] B02：A 等准入、B 已排队时 cancel 仍独立执行；用户音频不被隐式清空。
- [ ] B03：合法分包不改变 admitted PCM 和样本顺序，句末之后的同包下一句完整保留。
- [ ] B04：实际消费归还 pending，拒绝不消耗 sequence；2560 可达、4096 总上限仍有效。
- [ ] B05：回收确认早于 wire terminal；终态后立即新 start 成功，旧 finally 不动新 owner。
- [ ] B06：commit ACK 后挂起 reader 有超时失败；无成功/失败双终态，断线清理可证。
- [ ] B07：limits 全链路一致，小 PCM 预算实际有界，非法预算在边界拒绝。
- [ ] B08：拒绝更新旧状态不变；成功原子发布；候选与旧资源没有误关或泄漏。
- [ ] §7.2 四组跨层 fixture 在双方真实 adapter 路径验证，未用 App sleep/自动重发遮盖后端竞态。
- [ ] 生产 AssistantSession 实际编译进定向测试，而不是只测另写的仿制状态机。
- [ ] §2.4 登记表中每个新增文件同时纳入 SwiftPM 与 Xcode 目标；`git diff -- …/project.pbxproj` 只有预期的新增行；被测生产文件已补进 Unit Test Sources；`macos_app_build.sh` 退出码已记录（通过或失败都写明，不留空）。
- [ ] §7.3 追踪矩阵 19 行逐行对账，无“步骤已完成但验收项未判定”的行；服务端未修复的跨层依赖项标为待闭环而非通过。
- [ ] 旧 SQLite 记录可读，星标/既有时间/其他功能记录未变，失败写入不会显示保存成功。
- [ ] 相关正式文档与最终实现一致，未顺手改根 README、服务配置或模型。

交付需逐项列“失败复现 → 修复后结果 → 测试名/证据”。退出码或测试摘要不能代替确认测试实际发现并执行了新增用例。

## 8.3 本机执行环境的已实测注意事项

以下为 2026-09-28 在本机实测确认的执行约束，直接影响红绿证据的可信度。命令按 §1 的 Shell 路由约定执行，语义以原生形态书写。

1. **没有 `timeout`(1)**。不要在 `swift test`、`macos_app_build.sh` 外面再套 `timeout`；包装脚本的 `--timeout` 参数由脚本自身实现，是唯一正确的超时入口。用了不存在的 `timeout` 的历史运行结果一律作废重跑。
2. **SwiftPM 构建锁**。被中断的 `swift test` 会残留进程并继续持有 `.build` 锁，之后所有 `swift test` / `swift build` 静默排队，日志里出现 `Another instance of SwiftPM (PID: …) is already running`。看到这个提示时，先确认该 PID 属于本任务再清理，然后重跑；排队等待不算通过，也不能据此判断测试卡死。
3. **输出块缓冲**。`swift test … | grep …` 在挂死过程中不输出任何内容，容易误判为“还在跑”。正确形态是先把输出落到文件再读取：

   ```bash
   script -q /dev/null swift test --package-path macos/SpeechRailApp > /tmp/speechrail-test.log 2>&1
   tr -d '\r' < /tmp/speechrail-test.log | grep -aE "error:|Executed [0-9]+ tests" | tail -5
   ```

   `script` 给子进程一个伪终端使行缓冲生效；读日志前先去掉回车。App 编译同理，先写日志再看 `error:` 行。

4. **失败证据优先于退出码**。Xcode 编译失败的退出码是 65，必须从日志里读出具体 `error:` 行才算定位到原因。“命令执行完毕”“退出码为 0”都不能证明新增用例被执行。
5. **红绿判据**。一次有效的红测试需要同时满足：目标用例名出现在 `Executed N tests` 列表中、失败断言指向本方案描述的行为、失败原因不是编译或导入错误。修复后同一命令必须通过且该用例仍在列表中。
6. **挂起场景用 gate，不用 sleep**。测试内部用 continuation gate 控制时序；watchdog 只负责在真挂死时兜底结束进程，不能用固定等待时间代替断言。

# 9. 风险与注意事项

1. **方案不是运行授权。** 不启动子代理、不自行提交/推送、发布、安装、启停服务或加载模型。真实声学 AEC、耳机切换和双讲稳定性仍需后续授权验收。
2. **文件变更集中。** AssistantSession、SessionCoordinator、Store 是重叠修改热点，必须串行编辑。实施前检查当前分支及并行改动；本方案行号过期不等于可以覆盖文件。
3. **共享 coordinator 风险。** 操作 token 与按 sessionID 更新水位会影响会议/字幕/提词器，必须保留针对这些功能的最小回归。不要重新定义全局占用守卫。
4. **文字来源字段。** 当前 session.audio_source 表示预选采集配置，实际问题来源由 line.source 表示。按 S6 保留已有枚举并调整助手展示，不新增旧版无法解码的值。只对已有 schema 做受约束的行更新，不要求数据库迁移。
5. **持久化语义。** `interrupted` 用于不完整交付，未新增逐字播放位置。历史错误时轴无法可信修复，不做批量回填、删除或重新封存用户记录。
6. **取消重入。** `Task.cancel()` 不保证底层操作返回；await 后都要校验 token。对不响应取消的操作只能隔离晚到资源并保持准入闭锁，不能假装设备已经释放。
7. **TTS 空闲屏障。** 取消命令 send 成功不是终态 ACK。等待 terminal 不得阻塞负责分发该 terminal 的唯一事件泵。
8. **Provider 行为变化。** 只返回 delta/EOF 的端点会从假成功变成可见失败，这是有意修正；不增加静默兼容开关。其他 stream 消费者必须纳入影响检查。
9. **时间精度。** 本次提供真实可证明的本地观测时间，而非声学精确起止；若未来要精确对齐，另行追踪 sample span 和音频时轴，不能扩大本任务。
10. **回退。** 本次方案未改运行态。实现后按逻辑提交（仅获授权时），回退针对这些代码/文档提交，不回退或清空用户 SQLite。若有必要 schema migration，单独给出旧版可读性及恢复方案，未验证前不得部署。
11. **未验证项。** 本次没有执行 fake 测试、App 构建、UI 自动化或真实服务验证；上述故障结果和优先级以源码推导为依据，实施时以失败用例校准，发现已修复或无法复现须给出证据，不强行制造改动。

12. **服务共享影响。** B01/B03/B06/B08 也影响会议、字幕及其他 Realtime 调用者；保留其手动提交、分人、alignment 和清空路径的定向回归。LLM 编排、App 播放或 SQLite 不得下沉服务端。
13. **公开行为与内部协议。** 公共事件名保持不变，终态可复用、取消优先级及 limits 执行得到加强；音频 pending 奇数/<2 的旧输入从接受改为拒绝，需写入契约变更说明。IPC 消费水位/start limits 为同版本父子协议变更，旧 worker 不混跑，不加静默 fallback。
14. **资源回收失败。** 将终态后置不能演变为无限等 close；复用受控 abort/隔离策略。没有确认回收不宣称 lane 可用，也不通过新增模型进程解决阻塞。
15. **消费不等于播放。** 整批消费水位只归还文本额度；不改 render receipt 的 delivered 口径，不声称实际已听到。保守水位引入短暂背压是允许行为，永久无法恢复不是。
16. **模型质量边界。** 默认不改 vendor overlay、采样参数、prefill、Base ICL 布局；现有真实 gate 不能为新代码自动背书。若实施发现必须修改 overlay，先记录偏差与 gate 影响，不自行运行真实质量测试或复用旧 vendor identity 声称通过。
17. **运行态回退。** 方案更新不操作运行态；后续部署须按专项授权，将父服务与 worker 作为同一 release 原子更新/回退，保留原 runtime 和配置。App SQLite 不需要为 B 项迁移或回滚，禁止以测试清理为名删除用户记录。
18. **Xcode 登记是独立 gate。** SwiftPM 与 Xcode 是两套源文件清单，只修一边会得到方向相反的假象。新增生产文件若被单测引用，还必须补 Test Sources 的 BuildFile；漏补表现为 `cannot find type … in scope`，重复登记同一 FileReference 表现为 `duplicate symbol`。按 §6.8 操作，不要用“只加目录”“只加 Group”替代完整四处登记。
19. **单测 target 编译生产源码带来的耦合。** Unit Test Sources 已包含大量生产文件，意味着单测 target 里的一次符号冲突会阻断整个 App 编译。拆分新值类型时保持单一职责、避免与既有顶层符号同名；新增顶层类型前先在两个 phase 内 grep 同名符号。
20. **进度口径分离。** 本文件是设计与验收口径，实施状态只由 `progress_ledger` 记录。两者出现分歧时以账本为准并立即回写本文件的设计变更；不得把“已实施”写进方案正文，也不得用账本里的“完成”替代 §8.2 的验收勾选。

# 10. Luna 执行清单

按以下顺序执行，同一文件只有一个写入者。每步结束用 §7.3 的追踪矩阵对账 D01–D11、B01–B08，不以完成基础重构代替全部 19 项缺陷闭合。实施状态写入 `progress_ledger`，本文件只回写设计变更。下列任务是交付给 Luna 的实施顺序，本方案不启动执行者。

1. **核对基线与范围。** 检查当前 AGENTS、HEAD、工作区、上述符号；仅在收到实施授权后修改代码。完成条件：证据仍适用，冲突点已明确且不覆盖并行改动。
2. **接入真实编排测试。** 完成 S0 的依赖 seam、fake harness，按 §2.4 登记表和 §6.8 程序完成 `Package.swift` 与 `project.pbxproj` 双侧登记（含把被测生产文件补进 Unit Test Sources），并准备服务侧 §7.1 的 gate/合成 PCM fixture。完成条件：可控启动/结束及 WS fake harness 能运行且不碰设备/外部网络；`bash scripts/macos_app_build.sh --configuration Debug` 退出码为 0；`git diff -- …/project.pbxproj` 相对基线只有纯新增行。执行命令遵守 §8.3。
3. **先钉住 19 类失败。** 按 §7 的 App/服务矩阵写定向回归；按步骤逐批运行红测试，记录断言失败而非编译失败。完成条件：每项至少一个明确行为用例或记录静态缺陷无法复现的原因。
4. **修复 TTS 并发等待。** 完成 S1（D01），处理旧 epoch 与取消重入。完成条件：waiter 交错、取消、超时及重播隔离测试通过。
5. **修复启动/重连。** 完成 S2（D02/D03），协调器租约 token 与 Assistant token 配套。完成条件：所有 await 取消矩阵及同记录重连测试通过。
6. **修复活动状态。** 完成 S3（D04）。完成条件：静音、断线、恢复、新会话的状态投影与上行门禁一致。
7. **先闭合服务层依赖。** 按下列顺序完成，逐项红绿证据独立记录：
   - **SB0 / B01+B03**：修改 Realtime 提交/分帧职责；完成条件：多分包内容等价、cap 切分无锁重入、资源归零。
   - **SB4 / B06**：修复 reader 取消和 item 终态；完成条件：ACK 前后超时分别失败，无假成功。
   - **SB5 / B08**：原子配置更新；完成条件：失败快照不变，候选资源可回收，合法重试可用。
   - **SB2 / B04+B07**：贯通 limits、消费水位和事务 ACK；完成条件：五批 512 可继续、拒绝序列可重试、小音频预算有界。
   - **SB1 / B02**：控制队列解除音频 dispatch 依赖；完成条件：两包阻塞场景 cancel 先执行且音频 FIFO 保留。
   - **SB3 / B05**：资源回收、owner 退休、终态排序；完成条件：终态后立即 start 成功，旧 finally 无副作用。
8. **统一回复持久终态。** 完成 S4（D06/D08）。完成条件：部分/完整后打断、错误、重复终结及 Store 重开回看通过，并以修复后的 B02/B05 契约验证下一轮。
9. **接入设备失效通知。** 完成 S5（D05）。完成条件：丢弃旧音频不会留下账本预算，也不伪造完成。
10. **闭合文字降级。** 完成 S6（D07）与助手结束/回看入口。完成条件：另一功能占用下文字对话可独立开始/结束，原 owner 完全不变。
11. **修复时间。** 完成 S7（D09）。完成条件：多 item/重连/墙钟变化下观测时刻可证明、NULL 精确时轴可识别。
12. **修复流终态与空白。** 完成 S8/S9（D10/D11）。完成条件：EOF 截断失败、completed 成功、空白分块无语义丢失，并联动 D06 清理及 B04/B07 长回复预算。
13. **运行闭环与共享回归。** 执行 §7.2、§8 授权范围内的定向命令；若获构建授权再编译 App，并按 §6.8 复核 pbxproj 变更面。完成条件：新增测试实际执行、原相关回归通过、构建/真机未验项分别列明；fake 闭环不写成真实端到端验收；红绿判据满足 §8.3 第 5 条。
14. **同步文档并交付。** 完成 S10 及服务 WS/IPC 语义说明，检查 diff、敏感字段与 scope。完成条件：逐项报告 19 项状态、测试证据、公共/IPC 影响、数据兼容、运行态动作和回退方式；未经授权不提交、不发布。
