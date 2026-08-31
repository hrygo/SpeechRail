---
title: "SpeechRail 公共 ASR/TTS 运行时最终设计"
status: accepted-design
date: 2026-08-31
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
3. 让批量和实时负载共享模型运行时，但通过明确优先级隔离资源。
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
voice-realtime ─ v2 WS ─►│  realtime scheduler             │
                         │     ├─ ASR streaming worker      │
                         │     ├─ ASR batch worker          │
                         │     ├─ TTS streaming worker      │
                         │     └─ TTS batch worker          │
                         └─────────────────────────────────┘
```

| 层 | SpeechRail 拥有 | 消费应用拥有 |
|---|---|---|
| 输入/输出设备 | 接收已编码音频、返回音频 bytes | 麦克风、扬声器、播放缓冲、打断 |
| ASR | 分段、partial/final、模型、队列、错误 | 字幕 UI、会议 confirmed 文本、SRT、数据库 |
| TTS | 文本规范化、合成、音频 chunk、voice profile | 播放队列、回声协调、何时停止播放 |
| 会话 | API session、背压、取消、超时 | Agent/LLM 会话、业务状态、权限语义 |

每个模型 profile 在独立、长生命周期 worker 中加载。运行时维护三个逻辑 lane：实时 ASR
优先、实时 TTS 次之、batch 最后；已经开始的推理不可抢占，但取消必须释放后续资源。不能
通过 ASGI 多 worker 复制模型。

## 4. 模型策略

| 能力 | 首选适配器 | 备选/约束 |
|---|---|---|
| ASR | 现有 Qwen3-ASR profile | 先实现真实 streaming adapter；batch worker 不能伪装成 partial streaming |
| TTS | Qwen3-TTS adapter | 公共 voice ID 不绑定具体模型；在本机质量、首包、RTF 验收后启用 |
| 低延迟 TTS 备选 | Kyutai TTS / MLX adapter | 仅在同一输入/输出契约与本机基准达标后注册 |

Qwen3-TTS 官方项目声明支持流式合成和可控语音；Kyutai 提供 Apple Silicon 的 MLX 流式
TTS 路径。[Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) 与
[Kyutai TTS](https://github.com/kyutai-labs/delayed-streams-modeling) 是候选来源，不代表
本机已下载、已加载或已验收。所有模型优先从 ModelScope 获取完整可校验制品；下载、加载、
启用分别需要明确授权。

公开模型身份保持稳定：ASR 使用 `speechrail/qwen3-asr-1.7b`；TTS 首发使用
`speechrail/tts-default-zh`。后端从 Qwen3-TTS 切到其他合格 profile 时不强制客户端更名。

## 5. 公共 API

### 5.1 REST v1：兼容优先

| 方法 | 路径 | 目的 |
|---|---|---|
| `POST` | `/v1/audio/transcriptions` | 保持 OpenAI-compatible 文件 ASR |
| `POST` | `/v1/audio/speech` | OpenAI-compatible 整句 TTS |
| `GET` | `/v1/models` | 可用 ASR/TTS model 与 voice capability |
| `POST` | `/v1/audio/transcription_jobs` | 异步长音频/批量 ASR |
| `POST` | `/v1/audio/speech_jobs` | 异步批量 TTS |
| `GET` | `/v1/jobs/{job_id}` | 查询任务状态、结果引用或稳定错误 |
| `DELETE` | `/v1/jobs/{job_id}` | 请求尚未执行任务取消，或删除可下载结果 |

`/v1/audio/speech` 的核心字段为 `model`、`input`、`voice`、`response_format` 和
`speed`。`voice` 只能是 `/v1/models` 返回的预置公开 ID；不能接收或保存声纹样本。
短请求同步返回音频。对于长文本/大批量，客户端必须使用 job resource，避免长连接和无界
内存。

任务状态为 `queued`、`running`、`completed`、`failed`、`cancelled`、`expired`。原始输入
音频在转码/推理结束后删除；生成的 TTS 音频或结果文件默认最多保留一小时，TTL 到期转为
`expired`。任务正文、音频与转写不进入普通日志。

REST 保持现有 OpenAI-style `error` envelope 与 `X-Request-ID`。自定义 job API 不伪装成
OpenAI Batches API；它以独立资源和明确语义供所有客户端使用。

### 5.2 Realtime v2：只覆盖语音输入/输出

现有 `/v1/realtime` 语义冻结：它仍是一次 commit 后返回一次最终转写的兼容实现。目标实时
协议使用 `WS /v2/realtime`，避免让已有客户端因新增事件或 session 语义而失效。

握手使用 Bearer token；成功后客户端发送 `session.update`，其中 `session.type` 只能为
`transcription` 或 `speech`。

#### `transcription` 会话

```text
session.update
  → 0..N × input_audio_buffer.append
  → 0..N × transcription.delta
  → input_audio_buffer.commit 或 input_audio_buffer.flush
  → transcription.completed
```

- 音频为明确声明的 PCM 格式；创建事件回显服务实际接受的采样率、声道和 sample width。
- `delta` 是可替换的未确认文本，客户端不得持久化为会议最终记录。
- `completed` 包含稳定文本、segments、时间轴、语言和 item ID；这是可持久化结果。
- `flush` 只冲刷当前语句，会话可继续；`commit` 完成 session；`cancel` 丢弃未处理音频并
  释放 worker slot。
- 事件必须包含 session ID、event ID、request ID 和 `sequence`，以支持客户端去重与重连。

#### `speech` 会话

```text
session.update
  → 0..N × speech_input.append
  → 0..N × response.audio.delta
  → speech_input.commit 或 speech_input.flush
  → response.audio.completed
```

- `append` 接收 UTF-8 文本增量；服务端只在安全的文本边界开始合成，避免逐 token 造成
  音韵和发音不稳定。
- `delta` 返回带 sequence 的 Base64 音频块；`session.created` 回显所选 voice 与实际
  `audio_format`。REST 可返回 MP3/WAV 等容器，实时默认返回 profile 明确的 PCM。
- `flush` 输出当前可读短句但保持会话；`commit` 结束本段；`cancel` 必须停止后续音频块。
- 服务不播放音频，也不决定何时打断；客户端决定缓冲、播放和丢弃策略。

所有 v2 错误统一为 `type: "error"`、稳定 `code`、`request_id` 和 `retryable`。服务只承诺
协议顺序与资源释放，不承诺未经基准证据支持的绝对延迟。

## 6. 安全、隐私与运行边界

- loopback 是默认绑定；非 loopback 需要 key、CORS allowlist、TLS 终止、网段/反向代理
  策略和限速后才能启用。
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
  → SpeechRailRealtimeAdapter
  → /v2/realtime (transcription)
  → internal partial / confirmed domain events
  → 现有 SubtitleProxy / MeetingSession / SRT / PostgreSQL
```

迁移 adapter 是 `voice-realtime` 内唯一必须新增的协议边界。它复用现有 PCM 获取、会议和
UI；只负责将 PCM 映射为 v2 event，并将 v2 `delta`/`completed` 映射为应用已有内部事件。
SpeechRail 不 import `voice-realtime`，也不写其数据库。

迁移阶段：

1. **契约阶段**：定义并测试 v2 transcription 事件、错误、取消、背压和重连。
2. **运行时阶段**：实现真实 ASR streaming profile；以 fake backend 与真实模型分别测试。
3. **Adapter 阶段**：在 `voice-realtime` 独立分支接入 v2，保留原 WLK 配置。
4. **影子阶段**：同一 PCM 在应用内受控复制到旧 WLK 与 SpeechRail，仅比较测试/人工验收
   结果，不写入重复会议记录。
5. **切换阶段**：通过语音助手和完整会议冒烟后，关闭应用自管 WLK，保留一次发布周期的
   可回滚配置。
6. **退役阶段**：v2 持续稳定后删除 `/asr` 兼容路径与旧 WLK 启动依赖。

TTS 迁移独立于 ASR：`voice-realtime` 可以先继续使用其现有 TTS bridge；当 `speech` 会话
验收后，再让其把文本增量发往 SpeechRail 并自行播放返回 chunk。

## 8. 验收与发布门

### ASR

- REST：短音频、长音频 job、错误、取消、TTL、OpenAI SDK 兼容测试；
- v2：合法顺序、非法顺序、partial 覆盖、final 唯一性、flush、commit、cancel、重连、
  队列满和 worker 重启；
- `voice-realtime`：语音助手输入、会议开始/结束、字幕、confirmed 文本、SRT、数据库、
  断线与旧后端回滚的真实 smoke。

### TTS

- REST：预置 voice、文本边界、每种响应格式、错误与输出上限；
- v2：append、flush、commit、cancel、chunk sequence、客户端慢消费和资源释放；
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

本设计由 ADR-0006 固化。实施前应依据本规格创建分阶段计划；每个阶段单独可验证、可回退。
