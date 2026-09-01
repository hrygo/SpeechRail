---
title: "SpeechRail 公共 ASR/TTS 运行时最终设计"
status: accepted-design
date: 2026-08-31
review: senior-engineer-review-resolved
---

# SpeechRail 公共 ASR/TTS 运行时最终设计

## 1. 决策摘要

SpeechRail 演进为本机优先的**公共语音运行时**，只提供 ASR 与 TTS：

- 实时 ASR：会议字幕、语音输入；
- 批量 ASR：音频文件转写、字幕输出；
- 实时 TTS：文本增量到音频 chunk；
- 批量 TTS：完整文本到完整音频；
- 异步批量任务：长文件或大量文本的受控处理。

它不提供“语音入、语音出”的对话 Agent，不管理 LLM 会话、工具调用、麦克风、播放、
打断策略、会议状态、字幕 UI、SRT 或数据库。那些仍由 QwenPaw、`voice-realtime` 或其他
消费者拥有。

`voice-realtime` 将直接消费最终的 Realtime v2，而不是要求 SpeechRail 完整复刻 WLK
`/asr` snapshot。它是 SpeechRail 最重要的真实集成冒烟客户端；旧 `/asr` 仅作短期回滚面。

## 2. 目标、非目标与现状

### 2.1 目标

1. 给 OpenAI-compatible 工具提供稳定的 ASR/TTS REST 表面。
2. 给会议/实时客户端提供连续的 ASR 与 TTS WebSocket 会话。
3. 让批量和实时负载共享宿主资源治理，但不预设它们必须共享同一模型实例；通过容量预留和
   有界准入保护实时负载。
4. 允许模型替换而不要求客户端改 model path、vendor SDK 或私有协议。
5. 默认离线、本机、瞬态处理音频；不下载模型，不把音频和正文写入日志。

### 2.2 非目标

- 语音到语音端到端对话、LLM 推理、Agent 工具调用、记忆或 prompt 编排；
- 打开麦克风、播放扬声器、回声消除和 barge-in 策略；
- 会议归档、说话人映射、SRT/数据库持久化和 UI；
- 语音克隆。首发只使用服务器登记的预置 voice；克隆只能作为后续显式授权、可审计的扩展。

### 2.3 当前基线

`0.1.0` 已有 Qwen3-ASR batch worker、`POST /v1/audio/transcriptions`、基础队列和有限
`/v1/realtime`。它尚不产生持续 partial，`/asr` 也尚未进行转写。本规格描述目标状态，
不是对当前实现的完成声明。

## 3. 架构与责任

```text
                         ┌─────────────────────────────────┐
客户端 / 应用             │            SpeechRail            │
                         │                                 │
QwenPaw ─ REST ─────────►│  API gateway / auth / request ID │
批处理器 ─ REST/jobs ───►│          │                      │
voice-realtime ─ v2 WS ─►│  resource governor / scheduler   │
                         │     ├─ ASR profile worker(s)     │
                         │     │    ├─ realtime ASR lane    │
                         │     │    └─ batch ASR lane       │
                         │     └─ TTS profile worker(s)     │
                         │          ├─ realtime TTS lane    │
                         │          └─ batch TTS lane       │
                         └─────────────────────────────────┘
```

| 层 | SpeechRail 拥有 | 消费应用拥有 |
|---|---|---|
| 输入/输出设备 | 接收已编码音频、返回音频 bytes | 麦克风、扬声器、播放缓冲、打断 |
| ASR | 分段、partial/final、模型、队列、错误 | 字幕 UI、会议 confirmed 文本、SRT、数据库 |
| TTS | 文本规范化、合成、音频 chunk、voice profile | 播放队列、回声协调、何时停止播放 |
| 会话 | API session、背压、取消、超时 | Agent/LLM 会话、业务状态、权限语义 |

默认一个 runtime profile 只加载一个长生命周期 worker；是否为同一 profile 增加专用
streaming/batch worker，必须由本机内存和并发基准证明，不能由 ASGI worker 数隐式复制。

运行时维护实时 ASR、实时 TTS、batch 三个逻辑 lane，但优先级只作用于**共享受限资源的准入**：

- Resource Governor 先核对设备内存、已加载 profile、活动 session 和输出缓冲预算；
- 实时 ASR 和实时 TTS 使用显式预留容量，batch 只使用剩余容量；
- 已开始的模型调用默认不可抢占，取消只阻止后续工作并释放仍可回收的资源；
- batch 必须有等待上限和 aging，避免永久饥饿；不支持安全交错的 backend 只能在没有实时
  session 时运行 batch，或使用经基准批准的专用 worker。

因此“实时 ASR > 实时 TTS > batch”是容量保护策略，不是一个可无限阻塞低优先级请求的
全局严格优先队列。

## 4. 模型策略

| 能力 | 首选适配器 | 备选/约束 |
|---|---|---|
| ASR | 现有 Qwen3-ASR profile | 先验证真实 streaming 路径；batch worker 不能伪装成 partial streaming |
| TTS | Qwen3-TTS 候选 adapter | 公共 voice ID 不绑定具体模型；MPS、质量、首包、RTF 验收前不得成为默认 profile |
| 低延迟 TTS 备选 | Kyutai TTS / MLX adapter | 仅在同一输入/输出契约与本机基准达标后注册 |

Qwen3-TTS 官方项目声明支持流式合成和可控语音；Kyutai 提供 Apple Silicon 的 MLX 流式
TTS 路径。[Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) 与
[Kyutai TTS](https://github.com/kyutai-labs/delayed-streams-modeling) 是候选来源，不代表
本机已下载、已加载或已验收。所有模型优先从 ModelScope 获取完整可校验制品；下载、加载、
启用分别需要明确授权。

公开模型身份保持稳定：ASR 使用 `speechrail/qwen3-asr-1.7b`；TTS 首发使用
`speechrail/qwen3-tts`。后端从 Qwen3-TTS 切到其他合格 profile 时不强制客户端更名。

## 5. 公共 API

### 5.1 REST v1：兼容优先

| 方法 | 路径 | 目的 |
|---|---|---|
| `POST` | `/v1/audio/transcriptions` | 保持 OpenAI-compatible 文件 ASR |
| `POST` | `/v1/audio/speech` | OpenAI-compatible 整句 TTS |
| `GET` | `/v1/models` | 可用 ASR/TTS model 与 voice capability |
| `POST` | `/v1/audio/transcription_jobs` | 异步长音频/批量 ASR |
| `POST` | `/v1/audio/speech_jobs` | 异步批量 TTS |
| `GET` | `/v1/jobs/{job_id}` | 查询任务状态、结果元数据或稳定错误 |
| `GET` | `/v1/jobs/{job_id}/result` | 下载 completed 且未过期的结果 |
| `POST` | `/v1/jobs/{job_id}/cancel` | 请求取消 queued/running 任务 |
| `DELETE` | `/v1/jobs/{job_id}` | 删除终态任务元数据和仍存在的结果 |

`/v1/audio/speech` 的核心字段为 `model`、`input`、`voice`、`response_format` 和
`speed`。`voice` 只能是 `/v1/models` 返回的预置公开 ID；不能接收或保存声纹样本。
短请求同步返回音频。对于长文本/大批量，客户端必须使用 job resource，避免长连接和无界
内存。这里的 OpenAI-compatible 指 OpenAI SDK 可调用的受控子集；`instructions`、
`stream_format`、object voice 等未支持字段必须在 OpenAPI 中明确并以稳定错误拒绝，不能静默
忽略。

任务状态为 `queued`、`running`、`completed`、`failed`、`cancelled`、`expired`。取消端点
必须幂等：queued 可直接进入 cancelled；running 只做 best-effort 取消，若 backend 已不可
中断则继续清理但不得发布部分结果，并在调用返回后进入 cancelled；终态再次取消返回当前
状态。删除非终态任务返回稳定冲突错误。

原始输入音频在转码/推理结束或任务终止后删除；结果 TTL 从 `completed_at` 开始，默认一小时
且可配置。TTL 到期先删除结果，再原子地转为 `expired`。实现必须使用不可猜测 job ID、按
认证主体隔离访问、限制磁盘容量，并在进程重启时把遗留 running 任务转为稳定失败或重新排队；
不能静默丢失。任务正文、音频与转写不进入普通日志。

REST 保持现有 OpenAI-style `error` envelope 与 `X-Request-ID`。自定义 job API 不伪装成
OpenAI Batches API；它以独立资源和明确语义供所有客户端使用。

### 5.2 Realtime v2：只覆盖语音输入/输出

现有 `/v1/realtime` 语义冻结：它仍是一次 commit 后返回一次最终转写的兼容实现。目标实时
协议使用 `WS /v2/realtime`，避免让已有客户端因新增事件或 session 语义而失效。完整事件、
终态和映射规则以 [Realtime v2 设计契约](../../../contracts/realtime-v2.md) 为准；v2 实现前，
该文件只是一份已审查设计，不是可调用能力。

握手使用 Bearer token；成功后客户端发送 `session.update`，其中 `session.type` 只能为
`transcription` 或 `speech`。

#### `transcription` 会话

```text
session.update
  → 0..N × [input_audio_buffer.append
             → 0..N × transcription.delta
             → 0..1 × transcription.completed]
  → 0..N × input_audio_buffer.flush（manual 或强制切句）
  → input_audio_buffer.commit
  → session.completed
```

- 音频为明确声明的 PCM 格式；创建事件回显服务实际接受的采样率、声道和 sample width。
- `server_vad` endpointing 可在 session 内自动产生多个稳定 item；`manual` 模式由客户端
  flush。会议默认使用 `server_vad`，不能等到 session 结束才产生 confirmed 文本。
- `delta` 是同一 item 的可替换快照；`completed` 是不可变的逐句结果，包含稳定文本、
  segments、session 相对时间轴、语言和 item ID。
- `flush` 只确认当前语句且会话可继续；`commit` 停止输入、完成最后 item 并发送
  `session.completed`；`cancel` 丢弃未确认音频并发送 `session.cancelled`。
- 事件包含 session ID、event ID、request ID 和 session 内单调 `sequence`。v2.0 不提供
  session 恢复或事件重放；断线重连必须创建新 session/source epoch 并记录 gap。

#### `speech` 会话

```text
session.update
  → 0..N × speech_input.append
  → 0..N × [response.created
             → 0..N × response.audio.delta
             → response.audio.completed/cancelled]
  → 0..N × speech_input.flush
  → speech_input.commit
  → session.completed
```

- `append` 接收 UTF-8 文本增量；服务端只在安全的文本边界开始合成，避免逐 token 造成
  音韵和发音不稳定。
- 每个安全文本边界对应唯一 `response_id`；audio delta 同时携带 response ID、session
  sequence 和 response 内连续 chunk index。`session.created` 回显 voice 与实际 audio format。
- `flush` 强制输出当前可读短句但保持会话；`commit` 处理剩余文本并最终完成 session。
  `response.cancel` 必须以 response ID 为目标；服务端发送 cancelled 确认后不得生成该 response
  的新块，客户端负责丢弃已经收到但尚未播放的块。
- 一个 session 同时最多生成一个 active response；后续文本只能进入有界缓冲。慢消费者达到
  输出上限时以稳定错误终止，不能无界缓存音频。
- 服务不播放音频，也不决定何时打断；客户端决定缓冲、播放和丢弃策略。

所有 v2 错误统一为 `type: "error"`、稳定 `code`、`request_id` 和 `retryable`。服务只承诺
协议顺序与资源释放，不承诺未经基准证据支持的绝对延迟。

## 6. 安全、隐私与运行边界

- loopback 是默认绑定；非 loopback 需要 key、HTTP CORS allowlist、WebSocket `Origin`
  allowlist、TLS 终止、网段/反向代理策略和限速后才能启用。CORS 不能替代 WS Origin 校验。
- `/v2/realtime`、TTS REST/jobs 与 ASR REST/jobs 一律使用 header Bearer auth；不在 URL
  放长期 token。`/asr` 在迁移完成前只允许 loopback。
- 请求大小、音频时长、每 session 缓冲、文本长度、TTS 输出时长、job 并发和 TTL 都在
  API 边界强制校验。任何外部模型响应先校验再产生公共事件。
- 日志只记录 request/session/job ID、profile、format、时长、队列等待、推理耗时、错误与
  资源摘要；禁止记录音频、Base64、完整文本、prompt、voice sample、key 和绝对模型路径。
- 健康检查必须区分进程存活、各 ASR/TTS profile 的 worker ready 和 queue saturation；
  readiness 不得只凭配置字段为 true。

## 7. `voice-realtime` 直接迁移

目标路径不是 `/asr`：

```text
voice-realtime AudioHub
  → shared SpeechRailRealtimeClient
      ├─ SpeechRailStreamingTranscriber → SubtitleProxy / MeetingSession
      └─ SpeechRailConversationSTTFactory → 语音助手 Pipecat pipeline
  → /v2/realtime (transcription)
```

迁移在 `voice-realtime` 内使用一个共享协议客户端，但暴露两个应用端口 adapter：会议/字幕
端实现现有 `StreamingTranscriber`，语音助手端实现现有 `ConversationSTTFactory` 并创建
Pipecat processor。两者复用认证、连接和事件解析，但分别映射领域事件，不能用一个万能
adapter 抹平不同生命周期。

会议 adapter 将逐句 completed 累积为 `TranscriptWindow` snapshot；只有 session completed
才映射为 final/EOF。应用仍拥有 source epoch、断线 gap、SRT、PostgreSQL、会议和 UI。
SpeechRail 不 import `voice-realtime`，也不写其数据库。

迁移阶段：

1. **可行性门**：测量候选 streaming backend 的真实增量能力、首包、RTF、峰值内存和可并发
   profile，先决定 worker 拓扑和容量预算，不下载或启用未授权模型。
2. **契约阶段**：以 fake backend 固化 v2 item/session、错误、取消、背压和非恢复式重连。
3. **运行时阶段**：实现通过可行性门的 ASR streaming profile；分别跑 fake 与真实模型测试。
4. **Adapter 阶段**：在 `voice-realtime` 独立分支实现共享 client 与两个端口 adapter，保留原
   WLK/语音助手 STT 配置。
5. **影子阶段**：同一 PCM 在应用内受控复制到旧后端与 SpeechRail，仅比较测试/人工验收
   结果，不写入重复会议记录。
6. **切换阶段**：分别通过语音助手和完整会议冒烟后，关闭对应旧后端，保留一次发布周期的
   可回滚配置。
7. **退役阶段**：v2 持续稳定后删除 `/asr` 兼容路径与旧 WLK 启动依赖。

TTS 迁移独立于 ASR：`voice-realtime` 的交互 pipeline 通过共享 Realtime v2 transport
把文本增量发往 SpeechRail，并自行负责播放返回的 24 kHz PCM chunk；REST 仅用于试听/回放。

## 8. 验收与发布门

### ASR

- REST：短音频、长音频 job、错误、取消、TTL、OpenAI SDK 兼容测试；
- v2：合法顺序、非法顺序、delta revision 覆盖、逐句 completed、session final 唯一性、
  server VAD/manual flush、commit、cancel、慢消费者、重连新 epoch/gap、队列满和 worker 重启；
- `voice-realtime`：语音助手输入、会议开始/结束、字幕、confirmed 文本、SRT、数据库、
  断线与旧后端回滚的真实 smoke。

### TTS

- REST：预置 voice、文本边界、每种响应格式、错误与输出上限；
- v2：append、auto clause/flush、commit、按 response ID cancel、chunk sequence、取消后丢弃
  已缓冲块、客户端慢消费和资源释放；
- 消费端：音频连续播放、取消后无后续 chunk、与 ASR 实时 lane 并行时的资源隔离；
- 本机基准：记录 exact model/runtime/device、首个音频 chunk 时间、RTF、峰值内存和音质
  主观验收样本的访问控制；没有证据不宣称实时性能。

发布前必须运行完整测试、Ruff、mypy、OpenAPI/Realtime 契约校验，并分别运行真实模型与
`voice-realtime` 冒烟。任何模型下载、加载、客户端切换或端口替换必须由单独请求授权。

## 9. 取舍

| 方案 | 结论 | 原因 |
|---|---|---|
| 完整复刻 WLK `/asr` 再迁移 | 不作为主路线 | 长期维护私有 snapshot 协议，不能改善新 API |
| 直接 v2 adapter 迁移 | 采用 | 只替换 transport 边界，保留会议领域与回滚能力 |
| 在 SpeechRail 做 LLM 语音对话 | 不采用 | 会重新引入 Agent/会话/TTS 播放耦合 |
| 端到端 Speech-to-Speech 模型 | 不采用 | 不利于会议文本、时间轴和可观测性，也超出当前职责 |
| ASR/TTS 共用无优先级队列 | 不采用 | TTS 可能破坏会议字幕延迟 |
| 单一严格全局优先队列 | 不采用 | 不可抢占任务仍会阻塞实时请求，并可能让 batch 永久饥饿 |
| 一个万能 voice-realtime adapter | 不采用 | 会议 StreamingTranscriber 与语音助手 ConversationSTTFactory 生命周期不同 |

本设计由 ADR-0006 固化。实施前应依据本规格创建分阶段计划；每个阶段单独可验证、可回退。
