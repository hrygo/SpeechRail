---
title: "SpeechRail 系统总体架构"
status: active
audience: "系统架构师、核心开发者"
version: "1.16.0"
date: 2026-09-11
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
        Admit["AdmissionQueue + ResourceGovernor<br/>Realtime 容量预留；Batch FIFO + aging<br/>可选 ASR∥TTS 重计算重叠"]
        VAD["Silero 或 legacy VAD、SpeechAdmission、Barge-in"]
        Diar["可选 CoreML 分人 worker<br/>FluidAudio Sortformer FP16<br/>单一连续会话与私有二进制 IPC"]
        Life["RuntimeLifecycle + WorkerIdleEvictor<br/>默认 300 秒；可配置"]

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
    Life -. 尝试释放常驻权重 .-> ASR
    Life -. 尝试释放常驻权重 .-> TTS
    Life -. 丢弃常驻引用 / 生命周期 .-> Diar
```

### 运行时事实

- `build_app_services` 组合 `Qwen3SharedWorker`、`Qwen3TtsWorker`、可选 `CoreMLSortformerEngine`、`AdmissionQueue`、`ResourceGovernor` 与生命周期组件。分人模型只由惰性启动的私有 Swift worker 持有，FastAPI 主进程不加载 NeMo 或 CAM++。
- 分人生产制品固定为 FluidAudio CoreML FP16 `v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc`，使用 `computeUnits=.all` 直接加载已编译 bundle；没有 provider 自动选择、精度降级或 NeMo 回退。运行时选择证据见 D1 报告，质量、尾部和长期资源门仍须单独验收。
- ASR 的 batch 与 native streaming facade 共享一个物理 owner；它们不是同机同时工作的产品场景，冲突稳定返回 `backend_busy`。
- `ResourceGovernor` 为 realtime 留出容量，并让 batch 按 FIFO/aging 准入；它不取消或抢占已经进入推理的 batch 工作。
- ASR∥TTS 重计算重叠是可配置策略（ADR-0016），由声明常驻字节与物理内存预算判定：`SPEECHRAIL_ALLOW_HEAVY_OVERLAP=auto`（默认）在任一启用组件未声明非零峰、或声明的总量超过 `budget_for_hardware = max(4 GiB, host_memory // 2)` 时 fail-closed 串行，否则放行 ASR 与 TTS 并行；`true`/`false` 是运维与实验强制开关。重叠轴严格限定为 ASR∥TTS：TTS∥TTS 仍受单一 TTS worker 约束，ASR∥ASR（batch 与 native streaming）仍返回 `backend_busy`，且不复制任何 worker 进程。
- Worker IPC 使用长度前缀、JSON metadata 和可选 raw binary payload。它避免在主进程与 worker 间对 PCM 使用 Base64，但编码、拼接和读取仍会复制字节，不能称为 zero-copy。
- 分人 worker 在活跃会话结束时由 supervisor 定向取消并回收；IPC 是长度前缀 JSON header 加 PCM16 binary payload。不存在活跃分人会话时，普通 ASR/TTS 不创建或租用该 worker。

### 三档组成、模型目录与精度策略

模型目录（`src/speechrail/assets/model-catalog.json`）为 schema v2：`presets` 描述三档组成，顶层 `precision_policy` 取代旧的“全档 8-bit”约束。档位只选择权重与量化精度，以及是否供给分人制品。

| 档位 | 定位 | ASR | TTS | Aligner | 分人 |
|---|---|---|---|---|---|
| 🟢 `light` | Embedded（8GB 基础机） | `asr-0.6b-q8`（8-bit） | `tts-0.6b-custom-q8`（8-bit） | —（无） | ✗ |
| 🟡 `balanced` | Pro Workflow（16–24GB） | `asr-1.7b-q8`（8-bit） | `tts-0.6b-custom-q8`（8-bit） | `aligner-q8`（8-bit） | ✓ |
| 🟣 `quality` | Studio（32GB+） | `asr-1.7b-q8`（8-bit） | `tts-1.7b-design-q8`（8-bit） | `aligner-bf16`（bf16） | ✓ |

- **按档位精度策略**：三档均 8-bit 权重，`quality` 的 aligner 保持 bf16；曾评估的 4-bit `light`（`asr-0.6b-q4` / `tts-0.6b-custom-q4`）因验收门 E1 在公开真人语料上测得 0.6B ASR 相对 8-bit 基线劣化 1.38pp（>0.5pp 阈值）而未采纳，制品保留在 catalog 但不再被任何档位使用。
- **aligner 是分人专用制品**：aligner 是 catalog 一等制品，但**不进入 `PreparedModelSet` / `prepare_models`**，而由 `diarization_assets.prepare_diarization_assets` 按档位供给到 `app_home/diarization/<aligner-key>`，因此无 `prepared_id` / registry 迁移。词级时间戳来自 ASR 原生输出，不依赖 aligner。
- **选择与供给**：`config.selection.resolve_selection` 按档位覆盖 `qwen3_aligner_model_dir`，在 `light` 清空它并同时清空 `diarization_coreml_model_path`；aligner 快照缺失时 fail closed（清晰报错，不半启动）。`profile apply <tier>` 在切换时供给该档分人制品并写入/移除 CoreML 与 aligner 环境键。
- **契约与声明**：三档的公共 API 契约形状、worker 协议、调度与进程隔离保持一致；**对外声明的能力随档位不同**——`gpt-4o-transcribe-diarize` 仅在分人就绪（`balanced`/`quality`）时出现在 `/v1/models`，`light` 不声明。

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

文件分人使用原生 `gpt-4o-transcribe-diarize` / `diarized_json`，每个 segment 的匿名标签为 A–D。文件与 Realtime 都把 PCM、固定文本单元和活动更新交给同一个 `application.diarization.DiarizationSession` actor：transport 只投影领域事件，正文一经 completed 不会被分人改写。Qwen3 `ForcedAligner` 从按档位供给到 `app_home/diarization/<aligner-key>` 的本地 snapshot（`balanced` 为 `aligner-q8`，`quality` 为 `aligner-bf16`）取得固定正文的时间边界；它复用私有 ASR worker，不执行第二次 `Session.transcribe`，且仅为分人路径服务——`light` 不供给 aligner/CoreML，未配置时分人能力不就绪。词级时间戳来自 ASR 原生输出，与 aligner 无关。Realtime 通过 `session.speechrail.diarization.enabled=true` opt-in；没有开启时不会创建 actor、启动 CoreML worker 或初始化对齐器。实名映射、跨会议声纹库、会议数据库和最终播放仍属于调用方。

## 5. 目录职责映射

| 代码目录 | 责任 |
|---|---|
| `src/speechrail/app.py` | FastAPI 组合根、middleware、lifespan、路由注册 |
| `src/speechrail/application/` | 用例组装、Realtime 会话、音频流与分人协调 |
| `src/speechrail/domain/` | vendor-neutral types、ports、timeline 与 attribution ledger |
| `src/speechrail/backends/` | Qwen3 ASR/TTS、VAD、唯一 CoreML Sortformer adapter |
| `src/speechrail/runtime/` | queue、ResourceGovernor、worker lifecycle、IPC、jobs |
| `src/speechrail/http/` | REST/WebSocket 传输、鉴权、错误与 metrics middleware |
| `src/speechrail/compatibility/` | OpenAI model alias、Realtime event mapping 与稳定 envelope |
| `src/speechrail/mcp/` | 独立 `speechrail-mcp` 进程的 REST client 与工具组合根 |

## 6. 不变边界

- 默认 loopback；非 loopback 必须使用 API key 与明确 origin 策略。
- 请求路径不下载模型、不读取远程音频 URL、不持久化原始音频或完整转写。
- 一个 SpeechRail 服务、一个 ASGI worker；不得通过复制模型进程提高吞吐（ASR∥TTS 重计算重叠是既有单 worker 进程内的准入策略，不复制进程）。
- 三档只替换权重与量化组合（含按档位精度策略与是否供给分人制品）；公共 API 契约形状、调度和 worker 协议保持一致，但对外声明能力随档位不同，必须如实声明。
- 客户端拥有麦克风、播放、会议、数据库和 LLM 编排；SpeechRail 提供本地推理、协议与资源边界。
