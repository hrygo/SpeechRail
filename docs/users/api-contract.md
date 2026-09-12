---
title: "SpeechRail 公共 API 契约手册"
status: active
audience: "应用开发者、客户端工程师、API 消费者"
version: "2.1.1"
date: 2026-09-13
---

# 📡 SpeechRail 公共 API 契约手册

> 机器可读的 OpenAPI 3.1 规范位于 [`contracts/openapi.yaml`](../../contracts/openapi.yaml)；WebSocket 全双工事件规范位于 [`contracts/realtime-openai.md`](../../contracts/realtime-openai.md)。

---

## 1. 模型身份与别名映射

SpeechRail 对外暴露 Canonical（规范）模型名与 OpenAI 标准别名（Alias）：

| 能力类别 | Canonical 模型 ID | 兼容别名 (Aliases) | 说明 |
|---|---|---|---|
| **语音识别 (ASR)** | `speechrail/qwen3-asr-1.7b` | `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` | 别名自动归一化路由至本地 Qwen3-ASR 运行时（支持 1.7B / 0.6B 权重目录） |
| **语音合成 (TTS)** | `speechrail/qwen3-tts` | `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts` | 别名自动归一化路由至当前档位的 VoiceDesign、CustomVoice 或 Quality Base capability |

> 💡 **模型规格自适应**：Canonical 模型 ID 标识服务后端能力契约，底层可通过 `SPEECHRAIL_QWEN3_MODEL_DIR` 自由加载 **Qwen3-ASR-1.7B** 或 **Qwen3-ASR-0.6B**（显存占用更低、适用于 8GB 内存设备），对外均遵循相同的 OpenAI 协议。

客户端向 `GET /v1/models` 发起请求即可获取完整的模型清单及其 `resolves_to` 映射关系。
TTS 模型条目还会返回 `capabilities.supports_preview`、`supports_clone` 与
`supports_instruction`。`quality` 的默认 TTS 是 `voice_design`，同时独立配置
`base` clone capability，因此可同时声明 preview/instruction/clone；`balanced/light`
为 `custom_voice` 且不配置 Base clone capability。客户端必须读取运行时能力字段，不能仅由默认 `variant` 推断 clone。

### 1.1 档位与能力可用性矩阵

SpeechRail 有三档运行 profile（🟢 `light` Embedded / 🟡 `balanced` Pro Workflow / 🟣 `quality`
Studio）。三档**共享同一套** Canonical 模型名、OpenAI 别名、端点路径、请求/响应 schema、错误
envelope 与 Realtime 子集；差异只在“如实声明哪些能力可用”。客户端应以 `GET /v1/models`、
`GET /health`/`/readyz` 的运行时字段为准，不要假定某能力在全部档位都存在。

| 能力 | 🟢 `light` (Embedded) | 🟡 `balanced` (Pro Workflow) | 🟣 `quality` (Studio) |
|---|---|---|---|
| 批量文件转写 / Realtime / `segment`+`word` 时间戳 / translation | ✓ | ✓ | ✓ |
| 匿名讲话人分离（`gpt-4o-transcribe-diarize` / `diarized_json`） | ✗ | ✓ | ✓ |
| 自然语言音色设计 / 试听（VoiceDesign） | ✗ | ✗ | ✓ |
| 参考音频克隆（Base，`/v1/voices/clone`） | ✗ | ✗ | ✓ |

> - **词级时间戳由 ASR 原生提供**：`timestamp_granularities=["segment", "word"]` 在三档均可用，
>   与 aligner 无关。aligner 是分人专用制品，不是词级时间戳的依赖。
> - **分人只在支持分人的档位声明**：`gpt-4o-transcribe-diarize` 与 `diarized_json` 仅在
>   `balanced`、`quality` 可用；`light` 不供给 aligner/Sortformer，`/v1/models` 不列出该别名，
>   文件分人与 Realtime 分人扩展（`session.speechrail.diarization.enabled=true`）在 `light` 上均不可用。
> - **音色创造仅 `quality`**：prompt design / preview 由 VoiceDesign 承担；reference clone 由独立 Base capability 承担。`balanced`、`light` 上 `supports_instruction`、`supports_preview`、`supports_clone` 均为 `false`。
> - **双 capability lane**：Quality 的 VoiceDesign 与 Base clone 由两个独立 worker 提供；不同 capability 可同时常驻并发，同一 capability lane 内串行。开启懒加载时按首次请求加载，连续请求不会因 capability 切换反复换模；空闲冷却后仍会由生命周期组件按 Quality group 驱逐，下一次请求惰性恢复所需 worker。

---

## 2. API 端点全览

| 请求方法 | 路径 | 描述 | 主要参数 / 返回格式 |
|---|---|---|---|
| `GET` | `/health` | 进程存活检查与组件诊断 | 返回各 Worker 进程存活状态与配置信息；`tts_ready` 表示可按需服务，`tts_warm` 表示当前无需加载即可服务，`realtime_vad` 表示 `server_vad` 子能力的独立状态 |
| `GET` | `/readyz` | 推理就绪状态检查 | HTTP 200 只表示 ASR 或 TTS 至少一项可按需服务；响应中的 `realtime_vad` 仍需单独检查，worker 是否驻留请读取 `/health.tts_warm` 与 `/health.tts_state` |
| `GET` | `/metrics` | 运行指标导出 | 默认 Prometheus 文本；`Accept: application/json` 返回结构化视图 |
| `GET` | `/v1/models` | 模型清单与别名路由 | 列出 Canonical 模型名与 `whisper-1` 等兼容别名 |
| `GET` | `/v1/voices` | 注册与自定义的 TTS 音色列表 | 返回系统预置与自建音色全属性及可用性 |
| `POST` | `/v1/voices` | 自然语言创建自定义音色 (Voice Design) | 接收名称与人设描述，固化专属 Seed 并持久化 |
| `DELETE` | `/v1/voices/{voice_id}` | 删除自定义音色 | 删除指定自建音色（系统预置音色只读保护） |
| `POST` | `/v1/audio/transcriptions` | OpenAI 兼容文件转写（匿名讲话人分离仅在支持分人的档位可用，见 §1.1） | `json`, `verbose_json`, `text`, `srt`, `vtt`, `diarized_json` |
| `POST` | `/v1/audio/speech` | OpenAI 兼容语音合成 | `mp3`(默认), `opus`, `aac`, `flac`, `wav`, `pcm` (24kHz 16-bit Mono) |
| `POST` | `/v1/voices/previews` | 不落盘的自然语言音色试听 | VoiceDesign instruction、可选 seed 与音频格式 |
| `POST/GET/DELETE` | `/v1/jobs` | 异步任务 Spool 管理 | 提交长任务元数据、查询状态与取消任务 |
| `WS` | `/v1/realtime` | OpenAI Realtime WebSocket | 实时音频流式转写与合成；讲话人分离通过显式 session opt-in 开启（仅在支持分人的档位可用，见 §1.1） |

`GET /health` 的 `tts_ready` 保持 v1 兼容含义：TTS 已配置并可按需接收请求；它不承诺权重
当前驻留。新增的 `tts_warm` 为 `true` 时表示 worker 已完成加载握手，可直接产生 PCM，
为 `false` 时表示冷/未配置，注入的 backend 无法报告驻留状态时为 `null`。`tts_state` 提供
`active`、`warm_standby`、`cold_evicted`、`inactive` 或 `unconfigured` 等低基数诊断；冷状态
不会单独把仍可在请求时加载的 `tts_ready=true` 改成 false。

---

## 3. 文件转写 API (`POST /v1/audio/transcriptions`)

```http
POST /v1/audio/transcriptions
Content-Type: multipart/form-data
```

### 请求参数表 (Multipart Form-Data)
| 参数名 | 类型 | 必填 | 默认值 | 说明 |
|---|---|---|---|---|
| `file` | Binary | **是** | - | 音频文件（支持 `wav`, `mp3`, `m4a`, `ogg`, `flac`, `webm` 等） |
| `model` | String | 否 | `whisper-1` | 模型名（支持 Canonical ID 或 OpenAI 标准别名） |
| `language` | String | 否 | `auto` | 语言代码（如 `zh`, `en`, `ja`, `auto` 等） |
| `prompt` | String | 否 | - | 专有名词提示文本（最长 2000 字符） |
| `response_format` | String | 否 | `json` | 响应格式：`json`, `verbose_json`, `text`, `srt`, `vtt`, `diarized_json`；后者仅与 `gpt-4o-transcribe-diarize` 配对 |
| `timestamp_granularities[]` | Array | 否 | `["segment", "word"]` | 时间戳精度：`segment`, `word`；须配合 `verbose_json` |

标准 multipart 数组使用重复字段，例如 `timestamp_granularities[]=word`。
旧 `timestamp_granularities` 字段仍可使用；两种写法混用时合并后验证，任一字段中的非法值都会返回
`422 invalid_timestamp_granularities`。只请求 `word` 时返回 `words`，只请求 `segment` 时返回
`segments`；省略粒度时保持同时返回两者。

上传大小仍受 `SPEECHRAIL_MAX_UPLOAD_BYTES` 限制；解码输出另受 128 MiB 和
`SPEECHRAIL_MAX_AUDIO_SECONDS` 约束。WAV fastpath 在重采样前检查预计输出，其他容器在
读取 `ffmpeg` 输出时检查，超限即停止处理。取消或解码超时会回收对应子进程；这不构成
`ffmpeg` 自身内存占用的操作系统硬限制。

### 3.1 批量讲话人分离

文件分人使用 OpenAI 原生参数 `model="gpt-4o-transcribe-diarize"` 与
`response_format="diarized_json"`。响应为 `task/duration/text/segments`；每个 segment 有
string `id`、`type="transcript.text.segment"`、`start/end`、匿名 `speaker: "A"…"D"` 与
`text`，不混入 Whisper confidence、内部 slot 或 revision 字段。`stream=true` 返回
`transcript.text.delta`、`transcript.text.segment`、`transcript.text.done` SSE。超过 30 秒的
文件必须提供 `chunking_strategy=auto|server_vad`；known-speaker 参数明确返回
`unsupported_parameter`，SpeechRail 不把匿名标签映射为真实姓名或跨会议身份。

文件分人只在支持分人的档位可用：`balanced`、`quality` 已供给 aligner 与 Sortformer，`light`
（Embedded）不供给且不在 `/v1/models` 声明 `gpt-4o-transcribe-diarize`。在未配置、未就绪或不支持
分人的 profile 上，请求不会触发模型下载，而是返回 `503 diarization_not_available`。
安装可选依赖、准备仓库外部的绝对权重路径及检查 readiness 的步骤见[运行时部署方案](../operations/runtime-deployment.md)。

---

## 4. 语音合成 API (`POST /v1/audio/speech`)

```http
POST /v1/audio/speech
Content-Type: application/json
```

```json
{
  "model": "tts-1",
  "input": "欢迎使用 SpeechRail 本地语音合成引擎。",
  "voice": "serena",
  "response_format": "mp3",
  "speed": 1.0
}
```

`mp3`、`opus`、`aac`、`flac` 的容器编码具有 15 秒超时和 128 MiB 输出上限。
编码超限或失败返回 `502 audio_encode_failed`；取消请求时回收编码子进程。
`/v1/audio/speech` 与 `/v1/voices/previews` 共享一个由
`SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` 定义的绝对总 deadline，覆盖队列准入、worker
生成、首块等待和后续流交付。响应头发送前超时返回 `503 backend_timeout`；响应头发送后
则关闭流并在 access 记录中标记 `outcome=cancelled` 或 `outcome=error`。

标准接口要求 `voice`。质量档 VoiceDesign 可将 OpenAI SDK 的复数 `instructions` 字段作为
一次性音色设计指令传入；该字段不会持久化。CustomVoice 和克隆音色会稳定返回
`400 instructions_unsupported` 或 `400 clone_instruction_unsupported`，不会静默忽略。克隆
音色仅支持 `speed=1.0`，其他值返回 `400 clone_speed_unsupported`。

`seed` 仅属于质量档 VoiceDesign preview 的确定性采样参数；系统 VoiceDesign 音色使用其
固定 profile seed，CustomVoice 与克隆音色不接受调用方 `seed`。内部 adapter 对这些不支持的
组合返回稳定错误，不以“已接受”暗示参数生效。

`/metrics` 的 TTS 交付计数只使用固定事件标签：`planner_chunk`、参考缓存命中/未命中/淘汰、
`abort_fallback` 与 `reload`。它们用于比较同一 runtime 与 profile 下的实现路径，不含文本、
音色 ID、音频、路径或实际音质结论。

### 预设音色库 (Preset Voices)

九个 canonical 角色与 Qwen CustomVoice speaker 一一对应：`serena`、`vivian`、
`uncle_fu`、`dylan`、`eric`、`ryan`、`aiden`、`ono_anna`、`sohee`。
`default/warm/bright/calm` 与 13 个 OpenAI 标准 voice 名称仍可作为兼容 alias；别名解析与档位
无关，客户端无需上送 `quality/balanced/light`。但能力的**可用性**随档位不同（分人仅支持分人的档位、
VoiceDesign 预览与 Base reference clone 仅 `quality`），见 §1.1。

---

## 5. 音色管理与自然语言设计 API (`/v1/voices`)

SpeechRail 提供系统角色目录与自然语言音色设计（Voice Design）体系。系统角色在三档均
可用；自定义 VoiceDesign 音色仅在当前权重声明 `supports_instruction=true` 时可合成。

### 5.1 系统预置音色与采样确定性保证
为了根治大模型短句切流式 TTS 合成时可能出现的**分句换人、跨轮音色漂移**问题，SpeechRail 为每个预置音色绑定了确定的随机种子（Random Seed），并在 MLX 推理前显式调用 `mx.random.seed(profile.seed)`，将生成采样温度固定为 `temperature=0.1`：

| 音色 ID | 名称 | 专属 Seed | 采样温度 | 特征定位与适用场景 | 状态 |
|---|---|---|---|---|---|
| `serena` | 温柔中文女声 | `42` | `0.1` | 温暖柔和的年轻中文女声 | 系统预置（默认、只读） |
| `vivian` | 明亮中文女声 | `1024` | `0.1` | 明亮、略带锋利质感的年轻中文女声 | 系统预置（只读） |
| `uncle_fu` | 醇厚中文男声 | `2048` | `0.1` | 成熟、低沉醇厚的中文男声 | 系统预置（只读） |
| `dylan` | 北京青年男声 | `5120` | `0.1` | 清晰自然的北京青年男声 | 系统预置（只读） |
| `eric` | 成都活力男声 | `6144` | `0.1` | 略带沙哑与四川口音的活力男声 | 系统预置（只读） |
| `ryan` | 动感英语男声 | `7168` | `0.1` | 节奏感强的英语男声 | 系统预置（只读） |
| `aiden` | 阳光美式男声 | `8192` | `0.1` | 中频清晰的美式年轻男声 | 系统预置（只读） |
| `ono_anna` | 轻快日语女声 | `9216` | `0.1` | 轻盈俏皮的日语女声 | 系统预置（只读） |
| `sohee` | 温暖韩语女声 | `10240` | `0.1` | 情感丰富的温暖韩语女声 | 系统预置（只读） |

> 🛡️ **只读保护原则**：系统预置音色标记为 `is_system: true`，禁止通过 API 进行覆盖、修改或删除。

### 5.2 获取音色目录 (`GET /v1/voices`)
```http
GET /v1/voices
Authorization: Bearer <TOKEN>
```
**响应示例**：
```json
{
  "object": "list",
  "data": [
    {
      "id": "serena",
      "name": "温柔中文女声",
      "description": "温暖柔和的年轻中文女声，音色自然亲切，语气平和，语速适中。",
      "instruction": "温暖柔和的年轻中文女声，音色自然亲切，语气平和，语速适中。",
      "seed": 42,
      "aliases": ["alloy", "ash", "coral", "default", "echo", "marin", "onyx", "sage", "warm"],
      "is_default": true,
      "is_system": true,
      "created_at": 1788582000.0,
      "available": true,
      "variant": "voice_design",
      "capabilities": {"supports_speaker": false, "supports_instruction": true}
    },
    {
      "id": "custom_1788583825_59b3",
      "name": "知性姐姐",
      "description": "温柔轻快、语调柔和的年轻女声，吐字清晰亲和，富有同理心与治愈感。",
      "instruction": "温柔轻快、语调柔和的年轻女声，吐字清晰亲和，富有同理心与治愈感。",
      "seed": 12345,
      "aliases": [],
      "is_default": false,
      "is_system": false,
      "created_at": 1788583825.0,
      "available": true,
      "variant": "voice_design",
      "capabilities": {"supports_speaker": false, "supports_instruction": true}
    }
  ]
}
```

### 5.3 自然语言设计与创建音色 (`POST /v1/voices`)
支持使用自然语言描述特征（Prompt）动态创建新音色：
```http
POST /v1/voices
Content-Type: application/json
Authorization: Bearer <TOKEN>

{
  "name": "知性姐姐",
  "instruction": "温柔轻快、语调柔和的年轻女声，吐字清晰亲和，富有同理心与治愈感。",
  "seed": 12345
}
```
**请求参数**：
- `name` (string, 必填)：音色友好展示名称。
- `instruction` (string, 必填)：音色特征自然语言描述（人设、年龄、音质、情绪、语速等）。
- `id` (string, 可选)：自定义音色标识符。若不提供则自动生成 `custom_<timestamp>_<rand>`。
- `seed` (integer, 可选)：`0`–`4294967295` 的确定性采样种子；传入后固定该 recipe，未传入则由服务生成并持久化。

**持久化机制**：创建成功的音色会使用请求提供的 Seed，或由服务自动分配固定 Seed，并持久化保存在用户目录 `~/.speechrail/custom_voices.json` 中，服务重启后依然存在。克隆音频使用受控目录内的不可变文件名（`<voice_id>.<uuid>.wav`）；历史的 `<voice_id>.wav` 引用仍可读取。损坏、不可读或结构非法的 registry 会保留原文件并进入 fail-closed 状态，列表、写入和自定义音色解析返回 `503 voice_store_unavailable`，系统预置音色仍可使用。切换到 `balanced/light` 后条目保留但返回 `available=false`，合成请求返回 `400 voice_not_available`；切回 `quality` 后恢复。

### 5.4 删除自定义音色 (`DELETE /v1/voices/{voice_id}`)
```http
DELETE /v1/voices/custom_1788583825_59b3
Authorization: Bearer <TOKEN>
```
- 若删除成功，返回 `{"status": "deleted", "id": "custom_1788583825_59b3"}`；
- 若尝试删除九个系统角色或任一保留 alias，系统返回 `403 Forbidden`；
- 若音色不存在，返回 `404 Not Found`；
- 若音色正在被 TTS 使用，返回可重试的 `409 voice_in_use`，不会修改 registry 或音频；
- metadata 已删除但音频清理失败时返回 `503 voice_store_unavailable`，调用方应保留
  `request_id` 并按运维手册处理受控目录中的残留文件。

### 5.5 在语音合成中使用自定义音色
创建成功后，自建音色的 `id` 可直接传入任何合成接口：
- **REST 试听/合成**：`POST /v1/audio/speech` 中 `{"model": "speechrail/qwen3-tts", "voice": "custom_xxx", "input": "..."}`
- **Realtime 流式会话**：`WS /v1/realtime` 中通过 `session.update` 配置 `{"session": {"voice": "custom_xxx"}}`。

### 5.6 不落盘的自然语言音色试听 (`POST /v1/voices/previews`)

该接口只在 `quality` / `voice_design` 档位可用，用于声音工坊在用户保存 VoiceProfile 前试听
一个自然语言音色配方。请求期间的 instruction 和 seed 通过内部类型化 TTS 请求传入 worker；接口
不会创建 VoiceProfile、写入 `custom_voices.json` 或保存音频文件。

```json
{
  "model": "tts-1",
  "input": "你好，这是声音设计试听。",
  "instruction": "温暖自然的中文女声，吐字清晰。",
  "seed": 12345,
  "speed": 1.0,
  "language": "zh",
  "response_format": "wav"
}
```

`instruction` 最长 10000 字符，`input` 最长 4096 字符，`seed` 范围为 `0`–`4294967295`。
支持 `mp3`、`opus`、`aac`、`flac`、`wav` 和 `pcm`；预览接口先在内存中完成生成与编码，
因此后端或编码失败时仍能返回统一错误 envelope。`balanced` 和 `light` 返回
`400 voice_preview_unsupported`；预览错误仍包含 `code`、`request_id` 和 `retryable`。

### 5.7 音色克隆与质量门控 (`POST /v1/voices/clone`, `/clone/validate`, `/quality-runs`)

质量档支持从参考音频 + 脚本文本克隆自定义音色，但 clone 与默认 VoiceDesign 已解耦：reference clone 固定由独立的 Qwen3-TTS Base capability 通过公开 reference-generation 接口执行；Base 可与 VoiceDesign 同时常驻，空闲冷却后可随 Quality group 一起回收并在下一次请求时惰性恢复。VoiceDesign 不作为 clone fallback。`balanced` / `light` 调用返回 `400 voice_cloning_unsupported`。三个接口共用 `VoiceQualityReport` 结构。2026-09-12 审计已确认现有 synthesis quality-run 存在假阳性缺口，因此绿色 `status=pass` 暂不能作为跨文本 speaker identity 或纯净度已证明的充分证据。

#### 5.7.1 克隆并注册音色 (`POST /v1/voices/clone`)

与 `POST /v1/voices`（自然语言设计）不同，克隆使用 `multipart/form-data`：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `audio` | binary | 是 | 参考音频（WebM/WAV/MP3 等），最大 15MB |
| `ref_text` | string | 是 | 用户朗读的参考脚本文本，最长 2000 字符 |
| `name` | string | 是 | 克隆音色展示名称，最长 32 字符 |
| `id` | string | 否 | 可选音色标识符，匹配 `^[a-zA-Z0-9_-]{1,64}$` |

- **幂等**：可选 `Idempotency-Key` 请求头用于去重重试。缓存键为 `(Idempotency-Key, audio 的 SHA-256, ref_text)`；命中时直接 `201` 回放已注册的 `VoiceProfile`，不重复推理。缓存为进程内内存态，服务重启即失效，非持久化幂等。同一 key 下音频或 `ref_text` 变化即视为新请求，重新走质量分级，仍可能被 `voice_quality_reject` 拒绝。
- **质量门控**：参考音频通过信号校验后按 `voice_quality_v1` 策略打分；先对上传原始音频分级以尽早拒绝无效输入，再规范化为语音感知归一后的 canonical WAV 并对该 canonical 音频重新分级，持久化的参考资产与 `quality` 报告均描述 canonical 音频（与 `/v1/voices/designs` 同一契约）；canonical 重评结果为 `reject` 时同样返回 `400` 不落库。
  - `status=reject`：拒绝注册，返回 `400`，错误 envelope 为 `{"error": {"code": "voice_quality_reject", ...}, "quality_report": {...}}`（`quality_report` 与 `error` 同级）。客户端以响应体 `error.code` 作为可见的错误码信号；服务端内部通过 `X-SpeechRail-Error-Code` 响应头把错误码交给观测中间件消费，该头在到达客户端前已被中间件移除，不属于客户端可见契约。
  - `status=warn` 或 `pass`：正常注册，`201` 返回的 `VoiceProfile` 携带 `quality` 字段（即该报告，含 `status` 与 `run_id`）。
- **历史音色**：本次架构切换（clone 固定走 Base capability）之前注册的 clone 音色，其已存储的 `voice_quality_v1` 报告描述的是旧合成路径，不代表当前 Base 路径表现；需通过 `/v1/voices/{voice_id}/quality-runs` 重新验证后方可继续作为质量依据。
- 注册写入受控目录失败返回 `503 voice_store_unavailable`（可重试）；注册结构非法返回 `400 voice_creation_failed`。

#### 5.7.2 仅校验不注册 (`POST /v1/voices/clone/validate`)

请求体与 `/v1/voices/clone` 完全一致（同样的 multipart 与档位/字段校验），但不创建也不持久化任何 `VoiceProfile`，不写 `custom_voices.json` 或音频文件。只要通过字段与音频格式校验，无论结果如何都返回 `200` + 完整 `VoiceQualityReport`——包括 `status=reject` 的报告，供调用方在注册前预检。

#### 5.7.3 音色质量探针 (`POST /v1/voices/{voice_id}/quality-runs`)

对已注册音色运行有界质量探针并返回 `VoiceQualityReport`。请求体为 JSON：

```json
{ "probe_set": "voice_quality_v1_zh", "runs": 3, "include_audio": false }
```

- `probe_set`：仅支持 `voice_quality_v1_zh`（默认值，可省略）；其他值返回 `422 validation_error`。
- `runs`：整数，范围 `1..3`（默认 `3`），含义是“每个固定 probe 的重复次数”；6 个内置 probe 始终全部执行，因此默认 `probe_count=18`；越界返回 `422 validation_error`。
- `include_audio`：布尔，默认 `false`。当前未实现内联音频试听，传入 `true` 直接返回 `422 include_audio_unsupported`。
- 探针按 `voice_quality_v1_zh` 的 6 条内置固定脚本逐条合成，完整覆盖自我介绍、短句、长段落、问句、数字标点和停顿；每条重复 `runs` 次。
- 所有 probe 输出必须同时通过格式、非静音、无满幅削波和重复确定性检查；`runs>=2` 时会对同一 probe 的 PCM SHA-256 做重复比较，`runs=1` 不宣称已验证确定性。
- 信号门全部通过后，服务释放 TTS phase，只取 6 类 probe 各自首个有效 PCM，以现有 Batch ASR 顺序回转录并计算归一化字符相似度；该 ASR phase 独立进入 `BATCH_ASR` governor/admission，避免把 Base TTS 与 ASR 变成未经治理的并行重计算。
- `synthesis.transcript_match` 为 6 类 probe 的最小匹配分，当前工程初始门为 `>=0.92 pass`、`0.80..0.92 warn`、`<0.80 reject`；该阈值仍需真实 Apple Silicon 语料校准。ASR 不可用时返回 `status=unevaluated` + `transcription_unavailable`，绝不伪装为通过。
- 合成侧稳定码包括 `probe_failed`、`clone_speed_unsupported`、`output_invalid`、`output_peak_exceeded`、`output_nondeterministic`、`transcript_mismatch`、`transcription_unavailable`。探针模式下 `reference` 为空指标对象，不产生参考侧失败码。
- 音色不存在返回 `404 voice_not_found`；后端未就绪返回 `503 backend_not_ready`（可重试）；registry 不可读返回 `503 voice_store_unavailable`（可重试）。

#### 5.7.4 `VoiceQualityReport` 结构与向后兼容

报告顶层字段：

| 字段 | 说明 |
|---|---|
| `policy_version` | 门控策略版本，当前固定 `voice_quality_v1` |
| `status` | `pass` / `warn` / `reject` / `unevaluated`。当输出信号有效但独立 ASR 可懂度证据不可获得时，`quality-runs` 会显式下发 `unevaluated`，客户端不得把它当作 pass |
| `run_id` | 本次质量运行的唯一标识 |
| `tested_at` | 测试时间（ISO 8601 UTC） |
| `reference` | 参考音频信号指标（时长、采样率、声道、语音活动比、底噪、SNR、削波比、首尾静音；`transcript_match` 始终为 `null`，因为实现未启用 ASR 文本匹配，从不计算该分数） |
| `synthesis` | 合成输出指标（`probe_count`、`successful_probe_count`、`active_rms_dbfs`、`peak_dbfs`、`chunk_jump_p95_db`、`clipping_ratio`、`deterministic`、`transcript_match`、`intelligibility_evaluated`） |
| `failure_codes` | 失败/未评估原因数组。参考侧：`audio_too_short`、`low_snr`、`high_noise_floor`、`clipping`、`transcript_mismatch`；合成侧：`probe_failed`、`clone_speed_unsupported`、`output_invalid`、`output_peak_exceeded`、`output_nondeterministic`、`transcript_mismatch`、`transcription_unavailable` |

**向后兼容**：`VoiceProfile.quality` 仅在克隆音色（或已评估音色）上出现；系统预置音色、`POST /v1/voices` 创建的音色及历史遗留记录不携带 `quality` 字段。消费端应将缺失的 `quality` 字段视为“未评估”（等同 `unevaluated`），不要假定通过。新版 `quality-runs` 也会在独立 ASR 证据不可获得时显式返回 `status=unevaluated`。

---

## 6. 全双工 Realtime WebSocket (`WS /v1/realtime`)

连接端点：`ws://127.0.0.1:8201/v1/realtime`

### 核心支持事件列表
| 事件名称 (Type) | 方向 | 说明 |
|---|---|---|
| `session.update` | 客户端 → 服务端 | 配置 VAD 模式、音色、转写语种等 |
| `input_audio_buffer.append` | 客户端 → 服务端 | 追加 16kHz PCM16 音频块 (Base64 编码) |
| `input_audio_buffer.commit` | 客户端 → 服务端 | 手动提交当前音频缓冲区并触发识别 |
| `input_audio_buffer.speech_started` | 服务端 → 客户端 | Server VAD 触发检测到人声开始 |
| `input_audio_buffer.speech_stopped` | 服务端 → 客户端 | Server VAD 触发检测到人声结束 |
| `response.create` | 客户端 → 服务端 | 触发语音合成 (Stream-In TTS) |
| `response.output_audio.delta` / `response.audio.delta` | 服务端 → 客户端 | 流式返回 24kHz PCM16 音频增量块；每个协商 wire profile 只发送其中一种事件 |
| `response.cancel` | 客户端 → 服务端 | 立即打断并取消正在进行的语音合成 |

### 6.1 多人会议讲话人分离扩展
Realtime 不在 OpenAI 原生范围内提供说话人标签，因此 SpeechRail 只增加一个 opt-in 字段：`session.speechrail.diarization.enabled=true`。必须在首个 PCM 前设置，session.updated 回显 `enabled/version/max_speakers`。旧的根级或 `input_audio_transcription.diarization` 形状固定返回 `invalid_diarization`。未开启的普通 OpenAI Realtime 会话不接收任何 `speechrail.*` 事件，也不会创建分人会话。开启后，已完成正文通过本地固定文本对齐获得时间边界，绝不为分人再次识别或替换正文。采用“**正文先固定，归属后更新**”的不可变单元与异步补丁模型：

| 扩展事件名称 (Type) | 方向 | 说明 |
|---|---|---|
| `conversation.item.input_audio_transcription.completed` | 服务端 → 客户端 | 携带全局 `audio_start_sample`/`audio_end_sample` 与不可变 `attribution_units`（含稳定 `segment_uid`、字符切片及时间质量） |
| `speechrail.diarization.updated` | 服务端 → 客户端 | 异步推送该 item 的完整归属快照；`speaker` 可为 null，标签只在当前 session 有效 |
| `speechrail.diarization.status` | 服务端 → 客户端 | 发生过载或算子异常时触发单次降级通知（`status: degraded`），正文保持正常转写交付 |
| `speechrail.diarization.finish` | 客户端 → 服务端 | 录制结束屏障请求，携带 `event_id`，触发服务端排空声学尾部与待定归属 |
| `speechrail.diarization.done` | 服务端 → 客户端 | 屏障终态响应，携带 `last_update_sequence` 与样本水位，客户端校验后安全触发会议纪要 |

---

## 7. 统一错误 Envelope 与状态码

所有 HTTP 接口的非 2xx 响应严格遵循统一的错误结构体：

```json
{
  "error": {
    "message": "The uploaded audio format could not be decoded.",
    "type": "invalid_request_error",
    "code": "audio_decode_failed",
    "request_id": "req_01j6zabc1234",
    "retryable": false
  }
}
```

### 标准错误码速查表
| HTTP 状态码 | Error Code | 是否可重试 (`retryable`) | 常见原因与处理建议 |
|---|---|---|---|
| **400** | `model_not_found` | `false` | 请求的模型名不存在，核对 `/v1/models` 清单 |
| **400** | `audio_too_long` | `false` | 音频时长超出 `SPEECHRAIL_MAX_AUDIO_SECONDS` 限制 |
| **400** | `voice_quality_reject` | `false` | 克隆参考音频未通过 `voice_quality_v1` 门禁（详见 §5.7），响应同级的 `quality_report` 含失败原因 |
| **401** | `invalid_api_key` | `false` | 未提供有效的 API Key 或 Token 错误 |
| **413** | `audio_too_large` | `false` | 音频大小超出 `SPEECHRAIL_MAX_UPLOAD_BYTES` 限制 |
| **500** | `dependency_missing` | `false` | `ffmpeg` 等外部依赖缺失导致转码失败（克隆/校验路径），配置依赖后重试 |
| **422** | `audio_decode_failed` | `false` | 上传文件损坏或非标准音频容器，检查文件有效性 |
| **429** | `queue_full` | `true` | 当前并发超出 Governor 配额，按 `Retry-After` 重试 |
| **409** | `voice_in_use` | `true` | 自定义音色仍有活动 TTS 读者，等待当前合成完成后重试删除 |
| **503** | `backend_not_ready` | `true` | 对应模型 Worker 尚未启动或预检未通过，等待就绪 |
| **503** | `backend_timeout` | `true` | 队列准入、worker 生成或音频交付超出总 deadline，减小音频分块 |
| **503** | `voice_store_unavailable` | `true` | 自定义音色 registry 或音频存储不可读/不可写，先保留原文件并按手册修复 |


## 生成参考并注册新的 Base 音色

`POST /v1/voices/designs` 是 SpeechRail 专用、Quality-only 的增量接口。它不改变 `/v1/voices` 仅保存提示词的语义，也不改变录音上传的 `/v1/voices/clone`。

```json
{
  "id": "narrator_base",
  "name": "Narrator",
  "instruction": "清晰自然的中文声音，表达平稳。",
  "reference_text": "请用自然清晰的声音朗读这段参考文字，保持平稳的语气和适中的节奏。",
  "seed": 42,
  "language": "zh"
}
```

`id` 必须为新的小写字母、数字、下划线或连字符组合（1–64 字符），不得使用系统 ID/alias；`name` 1–64 字符；`instruction` 1–10000 字符；`reference_text` 20–240 字符；seed 为 0..2^32−1 的整数，默认 42。当前仅支持 `language=zh`，不接受 URL、参考音频、速度控制或其他额外字段。

201 响应包含 `voice`（标准 VoiceProfile，mode=clone、variant=base、含 creation 来源信息）以及 `synthesis_validation: "unevaluated"`。`voice.quality` 只描述生成参考与 ASR 内容核验，输出 probe_count=0；后续使用 `/v1/audio/speech` 调用 Base，并用 `/v1/voices/{id}/quality-runs` 单独验证输出。

ID 已存在（含并发创建）返回 409 `voice_already_exists`，不会覆盖旧资产；没有幂等缓存，重试同一 ID 也返回 409，客户端可从 `/v1/voices` 确认资产。资源繁忙为 429，超时或 ASR 不可用为 503，内容不匹配为 400 `transcript_mismatch`，无效输出为 400/502。任何模型或 ASR 阶段失败都不会发布半成品。

语料质量与声纹稳定性尚需实机校准；详见[生成式音色注册架构](../architecture/generated-voice-registration.md)。
