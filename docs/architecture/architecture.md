---
title: "SpeechRail 系统总体架构"
status: active
audience: "系统架构师、核心开发者"
version: "1.13.0"
date: 2026-09-08
---

# 🏛️ SpeechRail 系统总体架构

> SpeechRail 是单机、单用户共享的 ASR/TTS 运行时。FastAPI 主进程负责公共契约、会话、输入边界、准入和生命周期；ASR 与 TTS 在独立 MLX 子进程中执行。调用方保留音频采集、播放、会议与 LLM 编排。

## 1. 系统分层与运行时拓扑

```mermaid
flowchart TD
    subgraph Clients["客户端与可选工具进程"]
        SDK["OpenAI SDK / REST / WebSocket 客户端"]
        MCP["speechrail-mcp 外置 Proxy<br/>（stdio 或 Streamable HTTP）"]
    end

    subgraph Host["单个 SpeechRail ASGI 主进程 :8201"]
        direction TB
        Ingress["REST / WebSocket 路由、鉴权、Request ID、错误 Envelope"]
        Decode["仅音频上传：WAV fast-path 或按需 ffmpeg 管道<br/>有界内存与输入校验"]
        App["应用服务：ASR/TTS 用例、Realtime 会话、可选 JobRunner"]
        Admit["AdmissionQueue + ResourceGovernor<br/>Realtime 容量预留；Batch FIFO + aging"]
        VAD["Silero 或 legacy VAD、SpeechAdmission、Barge-in"]
        Diar["可选进程内 CPU 分人<br/>NeMo Sortformer + CAM++"]
        Life["RuntimeLifecycle + WorkerIdleEvictor<br/>按配置空闲卸载"]

        Ingress -->|音频上传| Decode --> App
        Ingress -->|系统、音色、任务、WS 控制| App
        App --> Admit
        App <--> VAD
        App <--> Diar
        App -. 活动与生命周期 .-> Life
    end

    ASR["一个共享 Qwen3-ASR MLX Worker<br/>batch 与 native streaming 复用物理模型<br/>模式冲突受限"]
    TTS["一个 Qwen3-TTS MLX Worker<br/>quality: VoiceDesign；balanced/light: CustomVoice"]

    SDK -->|OpenAI-compatible HTTP / WS| Ingress
    MCP -->|REST；仅配置 API key 时带 Bearer| Ingress
    App <==>|"长度前缀 JSON metadata + 原始二进制 payload IPC"| ASR
    App <==>|"长度前缀 JSON metadata + 原始二进制 payload IPC"| TTS
    Life -. 卸载权重 .-> ASR
    Life -. 卸载权重 .-> TTS
    Life -. 卸载权重 .-> Diar
```

### 运行时事实

- `build_app_services` 组合 `Qwen3SharedWorker`、`Qwen3TtsWorker`、可选 `NemoSortformerEngine`、`AdmissionQueue`、`ResourceGovernor` 与生命周期组件。分人引擎在主进程中惰性加载，不是第三个 MLX 子进程。
- ASR 的 batch 与 native streaming facade 共享一个物理 owner；它们不是同机同时工作的产品场景，冲突稳定返回 `backend_busy`。
- `ResourceGovernor` 为 realtime 留出容量，并让 batch 按 FIFO/aging 准入；它不取消或抢占已经进入推理的 batch 工作。
- Worker IPC 使用长度前缀、JSON metadata 和可选 raw binary payload。它避免在主进程与 worker 间对 PCM 使用 Base64，但编码、拼接和读取仍会复制字节，不能称为 zero-copy。
- `WorkerIdleEvictor` 卸载模型权重；实际 idle footprint 与卸载时机由配置和基准决定，文档不把特定内存数值当作不变量。

## 2. 输入、调度与持久化边界

REST 音频上传才经过解码流水线。`/health`、`/v1/models`、`/v1/voices`、voice 管理、jobs 与 WebSocket 控制事件直接进入应用服务，不应被画成统一经过音频解码。

`/v1/jobs` 只有在本地 job repository 与 processor 被配置时才启用。它属于主进程的可选能力，不引入外部队列、控制面或第二个常驻服务。

音频、PCM 与转写在请求路径中保持瞬态。自定义 voice 的注册信息可以持久化，但请求不保留原始参考音频；客户端负责参考音频采集、同意与播放。

## 3. OpenAI Realtime ASR/TTS 子集

`/v1/realtime` 只承载 ASR/TTS，不承载 LLM response、工具调用、播放控制或会议策略。详细事件契约以 [realtime-openai.md](../../contracts/realtime-openai.md) 为准。

```mermaid
sequenceDiagram
    autonumber
    participant Client as 客户端
    participant Host as SpeechRail ASGI / 会话
    participant VAD as 主进程 VAD / Admission
    participant ASR as 共享 ASR Worker
    participant TTS as TTS Worker

    Client->>Host: WebSocket handshake（可选 Bearer）
    Host-->>Client: session.created
    Host-->>Client: conversation.created
    Client->>Host: session.update（语种、voice、manual 或 server_vad）
    Host-->>Client: session.updated

    loop 已接纳的输入音频
        Client->>Host: input_audio_buffer.append（base64 PCM16）
        Host->>VAD: 帧级判定与样本时钟
        opt server_vad 语音起止
            VAD-->>Host: start / stop decision
            Host-->>Client: speech_started / speech_stopped
        end
    end
    Client->>Host: input_audio_buffer.commit（manual；VAD 可自动提交）
    Host->>ASR: open / append / commit（private IPC）
    ASR-->>Host: partial 或 final transcript
    Host-->>Client: committed → item.created → transcription.delta* → completed/failed

    Client->>Host: conversation.item.create（input_text）
    Host-->>Client: conversation.item.created
    Client->>Host: response.create
    Host->>TTS: streaming synthesis（private IPC）
    loop 输出音频
        TTS-->>Host: 24 kHz PCM16 chunks
        Host-->>Client: response.output_audio.delta（current）或 response.audio.delta（legacy）
    end
    Host-->>Client: response.output_audio.done / response.audio.done → response.done

    opt 取消正在输出的 TTS
        Client->>Host: response.cancel
        Host->>TTS: cancel task
        Host-->>Client: response.done（status=cancelled）
    end
```

`server_vad` 的判定、SpeechAdmission 与 Barge-in 位于主进程会话层；它们决定何时把音频推进 ASR，而不是由 ASR worker 直接向客户端发送 VAD 事件。当前 nested `audio` session profile 使用 `response.output_audio.*`；legacy profile 保持 `response.audio.*`，同一 response 不会混用两组事件。

## 4. Diarization 边界

批量分人输出 session-scoped 匿名 label。Realtime 分人扩展只会在连续 adapter 经过验证后广告和协商；当前 adapter 未验证连续能力时，服务不会伪造该能力。实名映射、跨会议声纹库、会议数据库和最终播放仍属于调用方。

## 5. 目录职责映射

| 代码目录 | 责任 |
|---|---|
| `src/speechrail/app.py` | FastAPI 组合根、middleware、lifespan、路由注册 |
| `src/speechrail/application/` | 用例组装、Realtime 会话、音频流与分人协调 |
| `src/speechrail/domain/` | vendor-neutral types、ports、timeline 与 attribution ledger |
| `src/speechrail/backends/` | Qwen3 ASR/TTS、VAD、Sortformer/CAM++ adapters |
| `src/speechrail/runtime/` | queue、ResourceGovernor、worker lifecycle、IPC、jobs |
| `src/speechrail/http/` | REST/WebSocket 传输、鉴权、错误与 metrics middleware |
| `src/speechrail/compatibility/` | OpenAI model alias、Realtime event mapping 与稳定 envelope |
| `src/speechrail/mcp/` | 独立 `speechrail-mcp` 进程的 REST client 与工具组合根 |

## 6. 不变边界

- 默认 loopback；非 loopback 必须使用 API key 与明确 origin 策略。
- 请求路径不下载模型、不读取远程音频 URL、不持久化原始音频或完整转写。
- 一个 SpeechRail 服务、一个 ASGI worker；不得通过复制模型进程提高吞吐。
- 三档只替换权重与量化组合，公共 API、调度和 worker 协议保持一致。
- 客户端拥有麦克风、播放、会议、数据库和 LLM 编排；SpeechRail 提供本地推理、协议与资源边界。
