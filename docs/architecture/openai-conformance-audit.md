---
title: "SpeechRail 语音 API 对 OpenAI 标准 符合度对标审查"
status: active
version: "1.2.0"
date: 2026-09-02
---

# SpeechRail 语音 API 对 OpenAI 标准 符合度对标审查

本报告对 SpeechRail v1.2.0 的对外语音接口（HTTP REST + WebSocket Realtime）与
OpenAI 标准语音 API 做逐项对标，区分"高度兼容"、"有意裁剪/扩展"和"真实兼容性风险"，
并给出带证据分层的修复建议。**本报告为只读评估，未改动任何代码、契约或服务。**

## 结论摘要

SpeechRail 是**有契约、有 ADR 背书的 OpenAI 兼容子集**，不是逐字段克隆：

- **ASR 文件转写**：高质量兼容（路径、multipart、主要参数、5 种 `response_format`、错误
  envelope 全对齐）；唯一破坏点是 `verbose_json` 时间戳字段命名。
- **TTS**：请求体同形，但 `response_format` 宽度不足（缺 mp3/opus/aac/flac）、不认 OpenAI
  标准音色名、默认格式与 OpenAI 不同。
- **Realtime**：ASR/TTS 手动 commit 子集，事件名总体对齐；但 TTS 音频事件用了**旧版预览
  命名**、`?model=` 查询参数与契约不符、若干标准 session 参数被静默丢弃。

## 证据分层（贯穿全文）

| 标记 | 含义 | 可信度 |
|---|---|---|
| 🟢 | live 实测：本次直接调用本机 `127.0.0.1:8201`（release `speechrail-1.2.0`，`asr_ready=true`、`tts_ready=true`）| 最高（运行时真值）|
| 🔵 | 契约：`contracts/openapi.yaml`、`contracts/realtime-openai.md` | 声明性事实 |
| 🟣 | 源码追踪：路由/应用/适配层实现 | 结构性事实（部分为 agent 追踪，关键项已 live 复核）|
| 🟡 | OpenAI 官方规范：**TTS 已带链接确认**；Transcriptions/Realtime 因调研 agent 限流中断，基于既有 OpenAI API 常识（置信度高，无本次 URL 引用）| 见 §证据边界 |

---

## 一、ASR 文件转写 `POST /v1/audio/transcriptions`

**请求参数**（🔵契约 / 🟢实测）：`file`、`model`（接受标准 alias）、`language`、`prompt`、
`response_format`、`temperature`（0–2）、`timestamp_granularities[]`（`word`/`segment`）。

| 维度 | OpenAI 🟡 | SpeechRail | 判定 |
|---|---|---|---|
| `response_format` | json / text / srt / verbose_json / vtt | 同 5 种 + 扩展 `diarized_json` | ✅ 超集 |
| `stream` | 支持流式 multipart | 🟢 拒绝 `stream_unsupported` | ⚠️ 有意不支持 |
| `chunking_strategy` | `auto`/`vad` | 拒绝 `chunking_strategy_unsupported` | ⚠️ 有意 |
| `language` | ISO-639-1 码 | 🟢 接受；`verbose_json` 内输出 `language:"Chinese"`（首字母大写全称）| ⚠️ 归一化差异 |
| `prompt` | 无硬上限（whisper 约 224 token）| 🔵 maxLength 2000 | ✅ 更严格但可接受 |
| `include`/`keywords`/`known_speaker_*` | 部分为新版参数 | 🔵 接受并忽略（SDK parity）| ✅ 加法容忍 |

**`verbose_json` 响应结构（🟢实测，最需关注）**：

- segment 键实测：`{id, start, end, text, speaker, speakers, speaker_revision}`
  - ⚠️ 用 `start`/`end`；OpenAI 用 **`start_time`/`end_time`** → **破坏严格 SDK 反序列化**
  - ⚠️ `id` 为字符串（`"seg_0"`）；OpenAI 为**整数**
  - ⚠️ 缺 `seek`、`tokens`、`temperature`、`avg_logprob`、`compression_ratio`、`no_speech_prob`（Whisper 置信度族；本机 mlx 后端不产出）
  - 扩展 `speaker`/`speakers`/`speaker_revision`（diarization；OpenAI 无，加法容忍）
- `words[]` 实测：`{word, start, end}` → ✅ 与 OpenAI `words[]` 形状一致
- 顶层：`{task, language, duration, text, segments, words, usage}` → `usage:{type:"duration",seconds}` 为 SpeechRail 扩展

**错误 envelope（🟢实测）**：`invalid_response_format`、`stream_unsupported`、`validation_error`
（422）均返回 `{error:{message, type:"invalid_request_error", param, code, request_id, retryable}}`。

**音频容器兼容（🔵契约）**：`flac/mp3/mp4/mpeg/mpga/m4a/ogg/wav/webm`；`Content-Type`/filename
仅作提示，最终以固定 `ffmpeg` 解码为准（容纳 QwenPaw 的 `video/webm`）。

## 二、ASR 翻译 `POST /v1/audio/translations`

🟢 实测 **404 未实现**。OpenAI 提供该端点（任意语种→英文）。属**范围裁剪**（本机面向中文转写，
无翻译消费者）。若未来需英文翻译输出为明确缺口。

## 三、TTS `POST /v1/audio/speech`（🟡 官方规范已带链接确认）

| 维度 | OpenAI 🟡（已确认）| SpeechRail 🔵🟢 | 判定 |
|---|---|---|---|
| `pcm` 格式 | **24 kHz / 16-bit LE / mono / 无头** | 🟢 实测 24 kHz PCM16 | ✅ **精确对齐** |
| `response_format` | mp3 / opus / aac / flac / wav / pcm（默认 **mp3**）| 仅 **pcm / wav**（默认 wav）| ❌ 缺 mp3/opus/aac/flac |
| `voice` | 13 内置名（alloy/ash/ballad/coral/echo/fable/nova/onyx/sage/shimmer/verse/marin/cedar；tts-1 子集 9 个）| `default/warm/bright/calm`（自有 preset）| ❌ 不认标准音色名（🟢 `alloy`→422）|
| `input` 上限 | 4096 字符 | 🔵 maxLength 100000 | ✅ 更宽松 |
| `speed` | 0.25–4.0，默认 1.0 | 0.25–4.0，默认 1 | ✅ |
| `instructions` | 仅 gpt-4o-mini-tts | 🔵 接受并忽略（Qwen3-TTS 无指令通道）| ✅ 加法容忍 |
| `stream_format` | sse / audio（sse 仅 gpt-4o-mini-tts）| 🔵 仅 `audio` | ⚠️ 无 SSE |
| model | tts-1 / tts-1-hd / gpt-4o-mini-tts | canonical `speechrail/qwen3-tts` + 3 alias | ✅ alias 覆盖 |

**两处真实风险（🟢实测）**：
1. 不传 `response_format` 时 OpenAI 客户端默认拿 **mp3**，SpeechRail 返回 **wav**；显式
   `response_format="mp3"` → **422**。
2. `voice="alloy"`/`"nova"` 等标准名 → **422**；标准客户端写死 OpenAI 音色名会失败。

## 四、Realtime `WS /v1/realtime`

SpeechRail 实现 OpenAI Realtime 的 **ASR/TTS 手动子集**（不承载 LLM 对话/工具/历史/图像，
见 ADR-0009）。以下为 🟢 live + 🟣 源码 + 🔵 契约三方交叉后的对齐结论。

### 4.1 连接与 session 配置

- 🟢 `session.created.session` 键：`{id, model, modalities:[text,audio], instructions, voice,
  input_audio_format:"pcm16", output_audio_format:"pcm16", turn_detection:null, tools,
  tool_choice, temperature, max_response_output_tokens, capabilities}`。
- 音频：入 **16 kHz mono PCM16**、出 **24 kHz PCM16** ✅ 与 OpenAI Realtime 一致。
- 🔵 契约声明 `?model=` 与 `session.update.session.model` 同样生效，未登记模型返回 `model_not_found`。

### 4.2 客户端事件（🟣 源码 `application/realtime_openai.py` dispatch + 🟢 实测）

| 事件 | 处理 |
|---|---|
| `session.update` | 接受（见 4.4 字段）→ `session.updated` |
| `input_audio_buffer.append` | 接受（base64 PCM16，偶数字节、有帧/缓冲上限）|
| `input_audio_buffer.commit` | 接受 → 触发转写终态 |
| `input_audio_buffer.clear` | 接受 → `input_audio_buffer.cleared` |
| `conversation.item.create` | 接受**单个** `role=user` `input_text`（TTS 文本入口，需 TTS ready）|
| `response.create` / `response.cancel` | 接受（TTS 触发/取消）|
| `conversation.item.truncate` / `.delete` | 拒绝 `unsupported_operation`（不断线）|
| 其他未知事件 | 拒绝 `unknown_event`（不断线）|
| `input_audio_buffer.cleared`（客户端回发）| **静默忽略**（防御 echo）|

### 4.3 服务端事件（🟢 实测 wire 顺序 + 🟣 源码 emit 集合）

SpeechRail **emit**：`session.created`、`conversation.created`、`session.updated`、
`input_audio_buffer.committed`/`cleared`、`conversation.item.created`、
`conversation.item.input_audio_transcription.delta`/`.segment`/`.completed`/`.failed`、
`response.created`、`response.output_item.added/done`、`response.content_part.added/done`、
**`response.output_audio.delta/done`**、**`response.output_audio_transcript.delta/done`**、
`response.done`、`error`。

**OpenAI 标准有、SpeechRail 不 emit**：`input_audio_buffer.speech_started`/`speech_stopped`
（无 VAD）、`rate_limits.updated`、`conversation.item.truncated`/`deleted`、
`response.text.delta/done`、`response.function_call_arguments.*`、以及**现行命名**的
`response.audio.*` / `response.audio_transcript.*`。

### 4.4 已确认的 Realtime 偏差（🟢/🟣）

**#1 🔴 TTS 音频事件命名代际错配（🟢 live 验证）**
实测 TTS 合成 wire 顺序为：
```
conversation.item.created → response.created → response.output_item.added
→ response.content_part.added → response.output_audio.delta ×N
→ response.output_audio_transcript.delta → .done → response.output_audio.done
→ response.content_part.done → response.output_item.done → response.done
```
- SpeechRail 用 **`response.output_audio.*` / `response.output_audio_transcript.*`**（2024-10-01
  preview 命名）；OpenAI **现行** Realtime 用 **`response.audio.*` / `response.audio_transcript.*`**。
- 🟣 同一实现混用两代命名：ASR 方向用**新**名 `conversation.item.input_audio_transcription.*`，
  TTS 方向用**旧**名 `response.output_audio.*`。
- **后果**：按现行 OpenAI 文档监听 `response.audio.delta` 的客户端，接 SpeechRail TTS **收不到
  匹配事件名**。这是 Realtime 面最高兼容性风险。

**#2 🟠 `?model=` 查询参数被忽略（🟢 验证，契约↔代码矛盾）**
- 🟢 带 `?model=gpt-4o-transcribe` 连接、不发 `session.update` → `session.created.model` =
  默认 canonical `speechrail/qwen3-asr-1.7b`（**非**请求 alias）。
- 🟢 带垃圾 `?model=does-not-exist-xyz` → 仍返回默认 canonical、**无 `model_not_found`**。
- 🟣 `http/routes/realtime_openai.py` 不读 `websocket.query_params`。
- **结论**：模型只能经 `session.update.session.model` 生效（该路径确实解析 alias、支持
  `model_not_found`）。与 `contracts/realtime-openai.md` 的"`?model=` 同样生效"不符。

**#3 🟠 标准 session 字段被静默丢弃（🟣 源码）**
`apply_session_update` 完全不读：`instructions`、`temperature`、`max_response_output_tokens`、
`tool_choice`；`modalities`/`turn_detection` 仅做成员校验、**不存储、不驱动行为**。
- **后果**：客户端设 `instructions`（引导转写）或 `temperature` 时 SpeechRail **假装接受但无效**（fail-open）；
  而 `server_vad`/`tools` 却**明确拒绝**（fail-closed）——**一致性策略不统一**。

**#4 🟡 非标准 envelope 附加字段（🟢+🟣）**
每个服务端事件带顶层 `event_id` + `session_id` + **`sequence`**（单调递增，非 OpenAI 字段）；
发送时 `event_id` 被路由用随机 uuid 覆盖。`session.created.session` 含自定义 `capabilities`
数组，且**缺** `input_audio_transcription`（OpenAI 会带 `null`）。属加法扩展，宽松 SDK 可忽略，
严格 schema 校验会告警。

**#5 🟢 排序细节**：`conversation.created` 在首次 `session.update` 后补发（非连接时）；
ASR commit 时 `input_audio_transcription.completed` 可能**先于** `input_audio_buffer.committed`
（🟣 committed 在 `await asr.commit()` 之后才发）。

**#6 ⚪ 潜在缺陷（未复现）**：🟣 源码推断"不支持语言在 ASR create 时抛未捕获 `RuntimeError` →
socket 1011"而非干净 `error` 事件。🟢 但 `session.update` 传 `language:"zz-qq"` **不报错**（校验
被延后）；未继续送该语言音频，**未复现崩溃**，故不下定论。

### 4.5 有意设计（非缺陷，ADR/契约背书）

- 无 `server_vad`/`semantic_vad`（🟢 `unsupported_turn_detection`）→ 仅手动 commit（ADR-0009：
  不伪装 VAD/barge-in）。
- 拒绝 `tools`（🟢 `unsupported_tools`）、无 LLM/函数调用/对话历史。
- diarization 仅 session-scoped 匿名 `spk_*`（ADR-0007），`diarization_not_available` fail-closed。

## 五、模型身份与 alias（🟢 实测 `/v1/models` 13 条）

canonical：`speechrail/qwen3-asr-1.7b`、`speechrail/qwen3-tts`。
ASR alias（→qwen3-asr）：`whisper-1`、`gpt-4o-transcribe`、`gpt-4o-mini-transcribe`、
`gpt-4o-transcribe-diarize`、`gpt-live-transcribe`、`gpt-transcribe`、`Qwen3-ASR-1.7B`、`qwen3-asr-1.7b`。
TTS alias（→qwen3-tts）：`tts-1`、`tts-1-hd`、`gpt-4o-mini-tts`。均带 `resolves_to`。

- ⚠️ **偏差候选**：🟢 `gpt-4o-transcribe-diarize` 即使 `diarization_ready=false` 仍出现在列表；
  🔵 `realtime-openai.md` 称"仅在 diarization profile 可用时出现"。HTTP 代码测绘 agent 中断，未逐行确认。
- 📌 `/v1/voices`、`/v1/jobs`、`/health`、`/readyz` 是 **SpeechRail 扩展端点**（OpenAI 无对应），非偏差。

## 六、错误 envelope

- REST：`{error:{message, type∈[invalid_request_error,authentication_error,server_error], param, code, request_id, retryable}}`
  → OpenAI 同形 + 扩展 `request_id`/`retryable`（契约声明，加法）。
- Realtime：`error.type` 恒 `invalid_request_error`（ASR 失败用 `transcription_error`）；
  22 种内部 code 字符串（`unsupported_*`、`unknown_event`、`invalid_state`、`model_not_found`、
  `frame_too_large`、`buffer_too_large`、`backend_not_ready`、`queue_full`、`backend_timeout` 等）。

## 七、修复建议（评估结论，未实施）

| 优先级 | 建议 | 依据 |
|---|---|---|
| **P0** | Realtime TTS 事件名对齐 OpenAI 现行（`response.audio.*`/`response.audio_transcript.*`），或契约头**显式声明**用 preview 命名 + SDK 适配说明 | §4.4 #1 |
| **P0** | `verbose_json` segment 改 `start_time`/`end_time`+int `id`（破坏性→`/v2`），或提供兼容 shim；至少契约明示差异 | §一 |
| **P1** | 修契约或补实现让 `?model=` 生效（含 `model_not_found`），或明确"`?model=` 仅提示、以 session.update 为准" | §4.4 #2 |
| **P1** | TTS 补 `mp3`（ffmpeg 封装 24k PCM 极廉价）+ voice alias（alloy/echo/nova…→preset）；默认值对齐或文档声明 | §三 |
| **P2** | 对 `instructions`/`temperature` 等至少**明示忽略**，统一 fail-open vs fail-closed 策略 | §4.4 #3 |
| **P2** | 专项复现"不支持语言 + 送音频"，若确为未捕获异常则包成 `error` 事件 | §4.4 #6 |
| **P3** | envelope 附加字段（`sequence`/`capabilities`/`event_id` 覆盖）在契约标注；核实 `gpt-4o-transcribe-diarize` 列表条件 | §4.4 #4、§五 |

## 八、证据边界与完整性

- **已完成一手证据**：HTTP（live 实测 + 契约）、Realtime（live 实测 + 源码追踪 + 契约）、
  TTS OpenAI 官方规范（**已带链接抓取**）。
- **缺口（诚实披露）**：Transcriptions 与 Realtime 的 OpenAI 官方【带链接逐字段引用】调研 agent
  因 lmstudio→deepseek 限流连锁全部 `Aborted`，本报告 §一/§四 的 OpenAI 侧描述基于**既有 API 常识**
  （置信度高，无本次 URL 引用）。§五 `gpt-4o-transcribe-diarize` 列表条件、§4.4 #6 语言崩溃路径
  待补。HTTP 路由逐字段校验、Realtime `rate_limits.updated` 是否 emit 因 HTTP 代码测绘 agent 中断
  未逐行确认（其可观测行为已由 live 实测覆盖）。
- **§四.4 #6 未复现**：不作为已确认缺陷计入总评。
- **并行改动**：审查期间工作树有约 45 个 `docs/`、ADR、`examples/` 文件被其他任务修改，
  本报告全程只读、未触碰这些改动。

## 附录 A：Realtime TTS OpenAI 官方参数（🟡 已带链接确认）

来源：platform.openai.com/docs/api-reference/audio/createSpeech、
platform.openai.com/docs/guides/text-to-speech、github.com/openai/openai-openapi、
github.com/openai/openai-python（`resources/audio/speech.py`）。

- `response_format` 枚举：`mp3`(默认)/`opus`/`aac`/`flac`/`wav`/`pcm`；**pcm = 24 kHz、16-bit 有符号、小端、单声道、无头**。
- 内置 voice（13）：`alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse, marin, cedar`；`tts-1`/`tts-1-hd` 支持子集 9 个（除 `ballad/verse/marin/cedar`）。
- `input` ≤ 4096 字符；`speed` 0.25–4.0（默认 1.0）；`instructions` 仅 `gpt-4o-mini-tts`；`stream_format` = `audio`(默认)/`sse`（sse 仅 `gpt-4o-mini-tts`）。
- 模型：`tts-1`、`tts-1-hd`、`gpt-4o-mini-tts`（+ 日期快照）。

## 附录 B：Realtime 事件集对照（OpenAI 现行 vs SpeechRail）

| OpenAI 现行事件 | SpeechRail | 备注 |
|---|---|---|
| `response.audio.delta`/`done` | **`response.output_audio.delta`/`done`** | ⚠️ 旧版命名 |
| `response.audio_transcript.delta`/`done` | **`response.output_audio_transcript.*`** | ⚠️ 旧版命名 |
| `conversation.item.input_audio_transcription.delta`/`completed`/`failed` | 同名 | ✅ 现行命名 |
| `conversation.item.input_audio_transcription.segment` | emit | SpeechRail diar 扩展 |
| `input_audio_buffer.speech_started`/`stopped` | 不 emit | 无 VAD（有意）|
| `rate_limits.updated` | 🟣 未见 emit | 待确认 |
| `response.text.*`/`response.function_call_arguments.*` | 不 emit | 不承载 LLM/工具（有意）|
| `session.created`/`updated`、`input_audio_buffer.*`、`conversation.item.created`、`response.created`/`done`/`output_item.*`/`content_part.*`、`error` | 对齐 | ✅ |
| 顶层 `sequence`、`session.created.capabilities` | 附加 | SpeechRail 扩展 |
