---
title: "SpeechRail 共享语音识别服务设计规格"
status: accepted
date: 2026-08-31
---

# SpeechRail 共享语音识别服务设计规格

## 1. 目标

SpeechRail 是一个独立、本地优先的语音识别服务，首发后端为 `Qwen3-ASR-1.7B`，向
QwenPaw、`voice-realtime`、Hermes Agent 及其他应用提供统一接口。服务拥有模型运行时、
队列、认证、健康检查和兼容层；调用方只依赖公共契约，不依赖 Qwen SDK、模型快照路径或
WhisperLiveKit 内部模块。

首发目标不是把所有语音相关能力做成一个平台，而是把“音频输入 → ASR 结果”做成可独立
部署、升级、观测和回滚的基础服务。

## 2. 证据与约束

本规格依据 2026-08-31 对当前本机资料和代码的核对：

- `voice-realtime` 版本 `1.4.0`，当前分支为 `feature/physical-output-audio`；其 Qwen3
  隔离 worker、ASR contracts、WLK `/asr` 和 `8001` 端口是迁移输入。
- QwenPaw 当前使用 `whisper_api` 形式的 `/v1/audio/transcriptions`。
- Hermes Agent `0.20.5` 的转写工具使用 `STT_OPENAI_BASE_URL`、`STT_OPENAI_MODEL` 和
  OpenAI SDK `audio.transcriptions.create`。
- 本机 LM Studio 是 LLM/Embedding 服务；SpeechRail 不把 ASR 伪装为
  `/v1/chat/completions`，也不把 LM Studio 作为首发 ASR 运行时强依赖。

外部接口依据见 [OpenAI Audio Transcriptions API](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)、
[OpenAI Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)
和 [Qwen3-ASR 官方仓库](https://github.com/QwenLM/Qwen3-ASR)。

## 3. 范围与边界

### 3.1 SpeechRail 拥有

- Qwen3 batch 与 realtime runtime 的生命周期。
- 统一模型身份、alias 解析和能力声明。
- multipart 文件转写、现代 Realtime WebSocket、WLK legacy WebSocket。
- 有界队列、并发准入、超时、取消、错误 envelope、request/session ID。
- 认证、监听边界、隐私日志、指标和运行清单。

### 3.2 调用方继续拥有

- 麦克风、回声消除、采样率转换和音频 capture lease。
- 会议状态、speaker mapping、SRT/数据库、UI、TTS、LLM 和 Agent prompt。
- 断线后的业务重连策略，以及 transcript 的业务持久化。

特别是 `voice-realtime` 的 `AudioHub`、会议状态机、Sortformer、PostgreSQL、TTS 和
LM Studio 原生对话链不迁入 SpeechRail。

## 4. 目标拓扑

```text
QwenPaw ───────────────┐
Hermes Agent ──────────┼── HTTP /v1/audio/transcriptions ─┐
其他批量客户端 ────────┘                                  │
                                                         ▼
voice-realtime ─────── WS /v1/realtime ───────► SpeechRail supervisor
旧 SubtitleStream ──── WS /asr (legacy) ───────►   ├─ admission/queue
                                                         ├─ Qwen3 batch worker
                                                         └─ Qwen3/WLK realtime worker
```

其中 `WLK realtime worker` 在迁移期可以是 SpeechRail 管理的 WLK sidecar；它的输出先
转换为 SpeechRail 领域事件，再由 legacy serializer 生成旧 wire shape。核心层不能传播
WLK 原始 JSON。

## 5. 公共契约

### 5.1 REST

正式路径为 `POST /v1/audio/transcriptions`，`multipart/form-data` 至少包含 `file`，
推荐显式发送：

```text
model=speechrail/qwen3-asr-1.7b
language=zh
response_format=verbose_json
timestamp_granularities[]=segment
```

稳定模型 ID 为 `speechrail/qwen3-asr-1.7b`。`Qwen3-ASR-1.7B`、小写旧写法和
`whisper-1` 仅作为显式登记的迁移 alias；alias 不改变健康信息中的真实 backend，也不
意味着 SpeechRail 具备 Whisper 模型行为。

首发结果格式：

- `json`：`{"text": "...", "usage": {"type": "duration", "seconds": 1.2}}`。
- `verbose_json`：增加 `task`、`language`、`duration`、`segments`、`words`。
- `text`、`srt`、`vtt`：由统一领域结果格式化，时间戳缺失时返回明确错误，不伪造时间。

统一错误字段为 `error.message`、`error.type`、`error.code`、`error.request_id`、
`error.retryable`，可选 `error.param`。可重试的拥塞、未就绪和暂时性 worker 故障分别
使用 `429` 或 `503`，并在适用时发送 `Retry-After`。

### 5.2 Realtime

`WS /v1/realtime` 使用 JSON 事件和 Base64 编码的 `s16le/16kHz/mono` PCM：

```text
transcription_session.update
  → input_audio_buffer.append × N
  → input_audio_buffer.commit
  → delta × N
  → completed 或 error
```

`delta` 是易失 partial；`completed` 才是客户端可以持久化的最终结果。会话中不切换
模型和设备 profile。详细字段见 [`contracts/realtime.md`](../../../../../contracts/realtime.md)。

### 5.3 Legacy WLK

`WS /asr?language=...&mode=full` 只为当前 `voice-realtime` 迁移保留：首帧 `config`，
接受裸 PCM，输出 `lines`/`buffer_transcription` full snapshot，空 PCM 表示 EOF 并输出
`ready_to_stop`。该路径带有弃用标识和单独 parity fixtures，新客户端不能依赖它。

## 6. 内部领域模型

内部统一使用以下最小模型，避免把会议或 WLK 字段变成公共核心依赖：

```text
TranscriptSegment
  id: str
  start_ms: int
  end_ms: int
  text: str
  language: str | None
  speaker: str | None
  partial: bool
  source_epoch: int

TranscriptResult
  request_id: str
  model_id: str
  language: str | None
  duration_ms: int
  text: str
  segments: list[TranscriptSegment]
  words: list[TranscriptWord]
```

约束：时间戳非负且 `start <= end`；同一个 session 的 `source_epoch` 单调；partial 不
作为最终结果写入持久化；未知 vendor 字段丢弃而不是透传。

## 7. 运行时与进程模型

首发采用一个 supervisor、一个 ASGI 进程和一个 batch 推理槽位；realtime profile 若启用
则由同一 supervisor 管理独立 worker/sidecar。禁止通过 `uvicorn --workers N` 复制模型。

Qwen worker 使用 framed IPC，至少包含长度、协议版本、request ID、操作名和 payload；
启动握手返回 `model_id`、snapshot 指纹、`device`、`dtype`、`model_loaded`。supervisor
在 worker identity 不匹配时 fail fast。

模型准备是部署动作，不在 HTTP 请求内下载。首发默认：

- ModelScope 优先准备 `Qwen/Qwen3-ASR-1.7B`，并记录 revision/快照指纹。
- `HF_HUB_OFFLINE=1`、`TRANSFORMERS_OFFLINE=1`。
- MPS profile 设置 `PYTORCH_ENABLE_MPS_FALLBACK=0`，不静默降级 CPU。
- 模型目录和运行时 virtualenv 位于仓库外。

## 8. 资源与隐私

- 上传大小、音频秒数、单帧 PCM、单连接缓冲和等待队列均有界。
- 音频只进入受限临时文件或内存 buffer；成功、失败、超时、取消均清理。
- 普通日志不保存音频、Base64、完整 transcript、API key、Authorization、原始 prompt
  或包含用户目录的模型路径。
- 只接受上传内容，不接受服务端按 URL 下载音频，避免 SSRF。
- loopback 默认不强制 key；LAN 或代理暴露必须启用 Bearer key、origin/网段限制和限流。

## 9. 迁移策略

```text
0. 冻结 voice-realtime 基线
   ↓
1. SpeechRail 以 8201 旁路启动，先验收 health/ready/model/REST
   ↓
2. QwenPaw 与 Hermes 切到 8201，voice-realtime 仍留在旧 WLK 8001
   ↓
3. SpeechRail legacy /asr parity 通过后，停旧 WLK 并切 8001
   ↓
4. voice-realtime 增加现代 Realtime client adapter
   ↓
5. 冻结/退役重复 ASR server；保留可执行回滚路径
```

每一步都要保留旧端口回滚能力。SpeechRail 项目不会直接修改原
`voice-realtime` 工作树；原项目的改动使用独立 feature branch，且只改 client/config/
process ownership。

## 10. 验收标准

发布前必须同时满足：

1. OpenAPI 与代码路由、错误 envelope、模型 alias 一致。
2. Qwen worker 的离线、MPS identity、取消和临时文件清理测试通过。
3. REST、Realtime 和 legacy WLK 契约测试通过。
4. QwenPaw、Hermes Agent、`voice-realtime` 各完成真实 smoke；Hermes 聊天 endpoint 不受影响。
5. 至少一个完整字幕/会议闭环通过，包含 partial、confirmed、EOF、SRT 和重连。
6. `8201 → 8001` 切换和反向回滚演练通过，且没有删除原项目数据或代码。
