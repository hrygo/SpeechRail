---
title: "SpeechRail 语音 API 对 OpenAI 标准 符合度对标审查"
status: active
version: "1.4.2"
date: 2026-09-02
---

# SpeechRail 语音 API 对 OpenAI 标准 符合度对标审查

本报告对 SpeechRail v1.2.0 的对外语音接口（HTTP REST + WebSocket Realtime）与
OpenAI 标准语音 API 做逐项对标，区分"高度兼容"、"有意裁剪/扩展"和"真实兼容性风险"，
并给出带证据分层的修复建议。**本报告为只读评估，未改动任何代码、契约或服务。**

**v1.3 复核（2026-09-02）**：对 v1.2 中依赖"既有 API 常识"的 OpenAI 侧结论，已用
openai-python `main` 分支生成模型与 `RealtimeServerEvent` union 一手源码重新核实，并
live 复跑本机服务与 sona 消费者代码。修正 6 处过时/错误判断（§一、§三、§4.4 #3~#6、
§五、附录 B），并将 §七 升级为按产品画像——**本机部署语音基座 × 多应用按 OpenAI 标准
接入**——裁定的**最终整改方案（落盘）**。被审计的服务版本仍为 v1.2.0。

**v1.4 执行关闭（2026-09-02）**：§七 全部批次已在分支 `feat/openai-conformance` 实施并通过
全量 gate 与 :8202 live smoke，详见 §九；本报告此前的"只读评估"表述仅适用于 v1.0–v1.3。

## 结论摘要

SpeechRail 是**有契约、有 ADR 背书的 OpenAI 兼容子集**，不是逐字段克隆：

- **ASR 文件转写**：高质量兼容（路径、multipart、主要参数、5 种 `response_format`、错误
  envelope 全对齐）；真破坏点是 `verbose_json` segment `id` 类型（str vs 现行 int）与
  缺失的 Whisper 置信字段族。复核更正：时间戳键名 `start`/`end` **已与现行 SDK 一致**，
  v1.2 的"改 `start_time`/`end_time`"判断作废（§一）。
- **TTS**：请求体同形，但 `response_format` 宽度不足（缺 mp3/opus/aac/flac）、不认 OpenAI
  标准音色名、默认格式与 OpenAI 不同；README 已宣称 mp3，形成**文档↔代码矛盾**。
- **Realtime**：ASR/TTS 手动 commit 子集，ASR 方向事件名与现行对齐；但 TTS 音频事件用
  **旧版预览命名**（现行 union 仅含 `response.audio.*`，一手已证）、`?model=` 查询参数与
  契约不符、若干标准 session 参数被静默丢弃（其中 `voice` 复核确认实际生效）、不支持语言
  存在未捕获异常 → socket 1011 路径（复核坐实）。

## 证据分层（贯穿全文）

| 标记 | 含义 | 可信度 |
|---|---|---|
| 🟢 | live 实测：本次直接调用本机 `127.0.0.1:8201`（release `speechrail-1.2.0`，`asr_ready=true`、`tts_ready=true`）| 最高（运行时真值）|
| 🔵 | 契约：`contracts/openapi.yaml`、`contracts/realtime-openai.md` | 声明性事实 |
| 🟣 | 源码追踪：路由/应用/适配层实现 | 结构性事实（部分为 agent 追踪，关键项已 live 复核）|
| 🟡 | OpenAI 官方规范：TTS 已带链接确认；**v1.3 复核已用 openai-python `main` 一手源码补全 Transcriptions/Realtime 侧**（文件清单见 §八）| 一手（v1.3 起）|

---

## 一、ASR 文件转写 `POST /v1/audio/transcriptions`

**请求参数**（🔵契约 / 🟢实测）：`file`、`model`（接受标准 alias）、`language`、`prompt`、
`response_format`、`temperature`（0–2）、`timestamp_granularities[]`（`word`/`segment`）。

| 维度 | OpenAI 🟡 | SpeechRail | 判定 |
|---|---|---|---|
| `response_format` | json / text / srt / verbose_json / vtt | 同 5 种 + 扩展 `diarized_json` | ✅ 超集 |
| `stream` | 支持流式 multipart | 🟢 拒绝 `stream_unsupported` | ⚠️ 有意不支持 |
| `chunking_strategy` | `auto`/`vad` | 拒绝 `chunking_strategy_unsupported` | ⚠️ 有意 |
| `language` | ISO-639-1 码 | 🟢 接受；`verbose_json` 内输出 `language:"Chinese"`（首字母大写全称）| ⚠️ 归一化差异（整改 B5，有 sona 耦合）|
| `prompt` | 无硬上限（whisper 约 224 token）| 🔵 maxLength 2000 | ✅ 更严格但可接受 |
| `include`/`keywords`/`known_speaker_*` | 部分为新版参数 | 🔵 接受并忽略（SDK parity）| ✅ 加法容忍 |

**`verbose_json` 响应结构（🟢实测 + 🟡v1.3 一手规范复核，最需关注）**：

- segment 键实测：`{id, start, end, text, speaker, speakers, speaker_revision}`
  - ✅ **复核更正**：时间戳键名**无需改**。现行 openai-python `TranscriptionSegment` 字段即
    `start`/`end`（float 秒）；v1.2 报告所述 `start_time`/`end_time` 是过时版 schema，该 P0 作废。
  - ⚠️ `id` 为字符串（`"seg_0"`）；现行 SDK 为 `id: int` → **真破坏点**（整改 B4）。
  - ⚠️ 现行 SDK 将 `seek`、`tokens`、`temperature`、`avg_logprob`、`compression_ratio`、
    `no_speech_prob` 全部声明为必填；本机 MLX 后端诚实层面产不出 → 裁定输出显式 `null`
    并在契约声明"不产出、绝不伪造"（整改 B4），不造假数据。
  - 扩展 `speaker`/`speakers`/`speaker_revision`（diarization；OpenAI 无，加法容忍；
    SDK `construct_type_unchecked` 宽松解析，不致破坏）
- `words[]` 实测：`{word, start, end}` → ✅ 与现行 `TranscriptionWord` 完全一致
- 顶层：`{task, language, duration, text, segments, words, usage}` → **复核更正**：
  `usage:{type:"duration",seconds}` 是现行标准字段，非 SpeechRail 私有扩展；
  `language` 实测 `"Chinese"` 非官方示例形态（整改 B5 归一化，存在 sona 耦合）

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
| `voice` | 13 内置名（alloy/ash/ballad/coral/echo/fable/nova/onyx/sage/shimmer/verse/marin/cedar；tts-1 子集 9 个）| `default/warm/bright/calm`（自有 preset）| ❌ 不认标准音色名（复核更正：实测返回 **400 `voice_not_found`**，`audio.py:345-352`；422 是 `response_format` 走 pydantic 的路径）|
| `input` 上限 | 4096 字符 | 🔵 maxLength 100000 | ✅ 更宽松 |
| `speed` | 0.25–4.0，默认 1.0 | 0.25–4.0，默认 1 | ✅ |
| `instructions` | 仅 gpt-4o-mini-tts | 🔵 接受并忽略（Qwen3-TTS 无指令通道）| ✅ 加法容忍 |
| `stream_format` | sse / audio（sse 仅 gpt-4o-mini-tts）| 🔵 仅 `audio` | ⚠️ 无 SSE |
| model | tts-1 / tts-1-hd / gpt-4o-mini-tts | canonical `speechrail/qwen3-tts` + 3 alias | ✅ alias 覆盖 |

**真实风险（🟢实测 + 🟡一手 SDK 复核，v1.3 更新）**：
1. 不传 `response_format` 时 OpenAI 客户端默认拿 **mp3**（SDK 侧 omit 该字段→server default），
   SpeechRail 返回 **wav**；显式 `response_format="mp3"` → pydantic Literal → **422**。
   **复核新证据**：README 已宣称 `mp3, wav, pcm` 且 SDK 示例 `stream_to_file("output.mp3")`
   不带格式——当前默认使**自家文档产出错误文件**，支持默认翻转（整改 B1）。
2. `voice="alloy"`/`"nova"` 等标准名 → **400**；标准客户端写死 OpenAI 音色名会失败。
   **复核新证据**：真实消费者已写 workaround——sona `src/sona/speechrail/tts.py:63` 硬编码
   `alloy→default`，证明 voice alias 是实测痛点（整改 B2）。

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
- 🟡 **v1.3 复核补强**：现行 openai-python `realtime.connect()` 一手源码把 model 拼进 WS URL
  的 `?model=` query param——标准客户端在握手层给出的模型名会被静默丢弃（整改 A1）。

**#3 🟠 标准 session 字段被静默丢弃（🟣 源码 + 🟢 复核）**
`apply_session_update` 完全不读：`instructions`、`temperature`、`max_response_output_tokens`、
`tool_choice`；`modalities`/`turn_detection` 仅做成员校验、**不存储、不驱动行为**。
- **后果**：客户端设 `instructions`（引导转写）或 `temperature` 时 SpeechRail **假装接受但无效**（fail-open）；
  而 `server_vad`/`tools` 却**明确拒绝**（fail-closed）——**一致性策略不统一**。
- ✅ **v1.3 更正**：`voice` 并非被丢弃——实测 `session.voice` 被读取、存储并驱动 TTS 合成
  （`application/realtime_openai.py:223`），v1.2 表述过宽。真正的空洞仅限
  `instructions`/`temperature`/`max_response_output_tokens`/`tool_choice`。
- **裁定（落盘 §七 A7）**：维持 accept-but-noop + 契约显式声明。这些字段是 LLM 语义参数，
  对无 LLM 的 ASR/TTS 服务器 no-op 本就正确；改为拒绝会砸掉按标准发完整 session 载荷的客户端。
  另发现真功能缺口：`input_audio_transcription.prompt` 未透传（REST 支持、Realtime 硬编码
  `prompt=""`，`application/realtime_openai.py:163`）→ 列入整改 A6。

**#4 🟡→⚪ 非标准 envelope 附加字段（🟢+🟣，v1.3 降级为文档级）**
每个服务端事件带顶层 `event_id` + `session_id` + **`sequence`**（单调递增，非 OpenAI 字段）；
发送时 `event_id` 被路由用随机 uuid 覆盖。`session.created.session` 含自定义 `capabilities`
数组，且**缺** `input_audio_transcription`（OpenAI 会带 `null`）。
- ✅ **v1.3 降级依据（一手）**：现行 SDK `parse_event` 用 `construct_type_unchecked` 宽松构造，
  附加字段与 server 事件带 `event_id`（官方模型本就要求该字段）均不致破坏 → 保留 `sequence`
  等本机调试有用字段，仅契约标注（A7）。
- ⚠️ **复核新增小缺陷**：路由 `payload["event_id"] = f"event_{uuid4().hex}"`（
  `routes/realtime_openai.py:44`）**无条件覆盖**，把 `error_event` 自带的关联 event_id 也冲掉，
  破坏代码自身的错误关联意图（整改 A5：存在则保留）。

**#5 排序（v1.3 一更正一升格）**：
- ✅ **更正**：~~`conversation.created` 在首次 `session.update` 后补发（非连接时）~~ 与当前代码
  矛盾——`start()` 在连接时即发送（`application/realtime_openai.py:89`）。v1.2 观察可能来自旧
  release 或误读，当前无需动作。
- ⚠️ **升格为必改**：ASR commit 时 `input_audio_transcription.completed` 可能**先于**
  `input_audio_buffer.committed`（drain task 与 `_commit_audio:176-177` 竞态：await 后才发
  committed）。`contracts/realtime-openai.md:38` **本就规定 committed 在前** → 这是对自家契约的
  违反，非可选项（整改 A3，一行重排）。

**#6 ⚪→🟠 v1.3 逐行坐实（升级为真缺陷，未 live 复现）**：`qwen3_streaming.py:327-350`
`create()` 对不支持语言抛 `RuntimeError('language_not_supported:*')`（另有
`'realtime streaming backend busy'`，line 334）；WS 路由只捕获 `RealtimeAdapterError`/
`DiarizationError`（`routes/realtime_openai.py:56-61`）→ `session.update` 设非法语言后
**首次 `input_audio_buffer.append` 即未捕获 RuntimeError → socket 1011**，而非干净 `error` 事件。
v1.2 未送该语言音频故未复现；路径已由 file:line 确认（整改 A2，配回归测试）。

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

- ✅ **v1.3 复核关闭**：主路径已实现契约条件（`system.py:63-64`：diarize alias 在
  `diarization_ready=false` 时跳过）。live 复跑时 `diarization_ready=true`，alias 在列**即契约
  行为**，v1.2 所述"false 仍出现"的前提当前不可复现。**残余真问题（一行）**：
  `compatibility_model_ids` 兜底循环（`system.py:72-84`）无同款过滤，若配置注入该 alias 可绕过
  条件（整改 A4）。
- 📌 `/v1/voices`、`/v1/jobs`、`/health`、`/readyz` 是 **SpeechRail 扩展端点**（OpenAI 无对应），非偏差。

## 六、错误 envelope

- REST：`{error:{message, type∈[invalid_request_error,authentication_error,server_error], param, code, request_id, retryable}}`
  → OpenAI 同形 + 扩展 `request_id`/`retryable`（契约声明，加法）。
- Realtime：`error.type` 恒 `invalid_request_error`（ASR 失败用 `transcription_error`）；
  22 种内部 code 字符串（`unsupported_*`、`unknown_event`、`invalid_state`、`model_not_found`、
  `frame_too_large`、`buffer_too_large`、`backend_not_ready`、`queue_full`、`backend_timeout` 等）。

## 七、最终整改方案（v1.3 复核裁定；v1.4 已执行关闭，见 §九）

**裁定过滤器（产品画像）**：本机部署的语音基座，供多个应用按 OpenAI 标准接入。
判据：标准客户端（照现行 OpenAI 文档/SDK 编写）接入时真会坏的才实现；伪造本机后端
产不出的数据、或为假想的多租户/公网场景铺路的，一律不做。

### Batch A｜Realtime 面卫生（一个 PR；`contracts/realtime-openai.md` 只动一次）

| 项 | 内容 | 落点 |
|---|---|---|
| A1 | 解析 `?model=`：路由读 `websocket.query_params`，复用 `canonical_asr_model`/`canonical_tts_model` registry；缺省→canonical 默认（向后兼容）；未登记模型→accept + `model_not_found` error 事件 + close（不发 `session.created`；close code 用文档化的 4xxx，不复用 1008）；`gpt-4o-transcribe-diarize` 且 diarization 未就绪→同样 `model_not_found`，与 `/v1/models` 隐藏语义一致 | `http/routes/realtime_openai.py` |
| A2 | 非法语言/后端忙：应用层把 `factory.create()` 的 `RuntimeError` 包成 `RealtimeAdapterError`（code `language_not_supported`/`backend_busy`），session 保持可用（客户端可 `session.update` 改语言后重试）；补回归测试（未 live 复现过，测试兜底） | `application/realtime_openai.py` |
| A3 | 事件序：`_commit_audio` 先发 `input_audio_buffer.committed` 再 `await asr.commit()`（契约 `realtime-openai.md:38` 本就如此规定）；后端失败仍发 `transcription_failed` | 同上 |
| A4 | `/v1/models` 的 `compatibility_model_ids` 循环补 diarize 过滤（与主循环 `system.py:63-64` 同语义） | `http/routes/system.py` |
| A5 | `send_event` 仅在事件未携带 `event_id` 时生成 uuid，保留 error 事件的关联 id | `http/routes/realtime_openai.py` |
| A6 | 透传 `input_audio_transcription.prompt` 到 streaming ASR `create()`（当前硬编码 `""`；REST 已有 prompt 通道，属 Realtime 侧功能缺口，非新增能力） | compatibility + application |
| A7 | 契约声明（文档级）：`instructions`/`temperature`/`max_response_output_tokens`/`tool_choice` 为 accept-but-noop 及理由；`voice` 已生效；`sequence`/`session_id` 为加法字段；`rate_limits.updated` 不 emit（单机无配额语义） | `contracts/realtime-openai.md` |

### Batch B｜REST 面符合度（一个 PR；`openapi.yaml`+README+CHANGELOG 各动一次）

| 项 | 内容 |
|---|---|
| B1 | `/v1/audio/speech` 补 `mp3`/`opus`/`aac`/`flac`（ffmpeg 封装 24 kHz PCM16，容器细节先验证后写契约：opus→Ogg Opus、aac→ADTS 待定）；六格式齐后默认 `wav`→`mp3` 翻转（omit→mp3 是标准语义；README 现版已按 mp3 宣称并示例 `output.mp3`）。前置：枚举本机消费者中依赖"省略格式拿 wav"的调用并显式 pin `response_format=wav` |
| B2 | voice alias：13 个 OpenAI 标准名→4 个本机 preset 映射（`alloy` 等→`default`），本机 preset 仍是事实来源；`/v1/voices` 以 `resolves_to` 形式暴露映射，避免黑盒。sona 已有 `alloy→default` workaround 佐证需求 |
| B3 | `input` 上限 `100000`→`4096`（OpenAI 标准值 + 本机有界原则；10 万字符整段合成是真实资源风险） |
| B4 | `verbose_json`：segment `id` 改 int（源头 `qwen3_native.py:62`、`qwen3_streaming.py:297` + domain 类型 + formatter 同步；`diarized_json` 共享 `format_verbose` 一处覆盖；消费者扫描显示仅 tests/ 用 `seg_` 字面值，低风险）；`seek`/`tokens`/`temperature`/`avg_logprob`/`compression_ratio`/`no_speech_prob` 输出显式 `null` + 契约声明"MLX 后端不产出、绝不伪造"；`start`/`end` 键名**不动**（已与现行 SDK 一致） |
| B5 | `language` 值归一化：当前 `"Chinese"` 非标准形态；实现时以 OpenAI 官方示例复核目标形态（小写全称或 ISO 码），并与 sona 白名单（`speechrail_realtime.py:40` 含 `"Chinese"`/`"English"`）lockstep 或过渡期双值输出 |

### Batch C｜Realtime TTS 事件名改名（跨仓协调，最后执行）

- `response.output_audio.delta`/`done` → `response.audio.delta`/`done`；
  `response.output_audio_transcript.*` → `response.audio_transcript.*`。
- **策略裁定：clean cut，不 dual-emit、不做协商开关。** 依据：现行 SDK `RealtimeServerEvent`
  union 一手确认无 `output_audio.*` 系名字；本端点契约承诺的就是"OpenAI Realtime 兼容"，
  旧名从来不是该标准的一部分，修正属对承诺契约的 bugfix，不触发 /v2 规则；dual-emit 会使
  realtime 热路径 base64 音频翻倍且延续错误命名，违反画像过滤器。
- 同窗口影响面（已实测枚举）：`compatibility/openai_realtime.py:332-384`、
  `application/realtime_openai.py:324-360`、`tests/test_realtime_openai.py:497,915`、
  `examples/perf/bench_realtime.py:110,125`、`contracts/realtime-openai.md:62-63` 事件表、
  **sona `src/sona/speechrail/tts.py:33-35,120`**（外部仓，确认消费旧名）。
- **门**：sona 无法在同一窗口 lockstep 更新，则推迟 Batch C，绝不 dual-emit。
- 改名前用现行 union 复核 `response.output_item.*`/`response.content_part.*` 等非音频事件名
  仍为现行（当前证据支持，作执行时 checklist 项）。

### Batch D｜收尾

- 全量代码 gate（`pytest`、`ruff`、`mypy`、`redocly lint`、`git diff --check`）+ live smoke：
  REST 六格式 TTS、Realtime 事件序、`?model=` 拒绝路径、verbose_json 解析（用真实 openai
  SDK 做 10 行解析测试验证 null/absent 行为）。
- CHANGELOG 迁移说明：TTS 默认翻转、segment `id` 类型、`input` 4096、Realtime 事件名。
- 本审查报告按最终态做一次性修订收尾（v1.4）。

### 明确不做（画像外/过度对齐，维持现状并保留文档背书）

| 项 | 理由 |
|---|---|
| `/v1/audio/translations` | 无消费者；本机面向中文转写（§二已判范围裁剪） |
| multipart `stream` / `chunking_strategy` | 稳定拒绝已实现并文档化 |
| `server_vad`/`semantic_vad`、`tools`、LLM 对话/历史 | ADR-0009 有意裁剪；fail-closed 拒绝保持 |
| `rate_limits.updated` | 单机无配额语义 |
| 伪造 Whisper 置信族（tokens/avg_logprob 等） | 诚实能力边界；B4 用显式 `null`+契约声明替代 |
| dual-emit 过渡事件名 / 版本协商 | 影响面全部本机可控（sona+examples），过度设计 |
| 为此另开 `/v2` | 各项修正都是对齐本端点一直声称的 OpenAI 标准，配 CHANGELOG 迁移说明即可 |

### 执行顺序与依赖

`A → B →（sona lockstep 确认后）C → D`。契约文件各面只动一次：`realtime-openai.md` 在 A
（连接/错误/字段语义）与 C（事件表）两处不重叠章节；`openapi.yaml`/README 仅在 B。
工作量：A ≤ 半天；B 1–2 天（ffmpeg 封装路径 + 测试）；C 仓内快、外部协调 gating；D 快。

## 八、证据边界与完整性（v1.3 更新）

- **一手证据**：HTTP（live 实测 + 契约 + 源码逐行）、Realtime（live + 源码 + 契约 +
  **openai-python main 事件 union 一手比对**）、TTS OpenAI 官方规范（带链接抓取）。
- **v1.3 已补齐**（v1.2 披露的缺口现已闭合，方式为直接抓取 openai-python `main` 生成模型，
  替代此前因限流中断的调研 agent）：
  `types/audio/transcription_segment.py`、`transcription_word.py`、`transcription_verbose.py`、
  `types/realtime/realtime_server_event.py`、`resources/realtime/realtime.py`、
  `resources/audio/speech.py`。§一/§四 的 OpenAI 侧描述已按一手证据修正。
- **§五 `gpt-4o-transcribe-diarize`**：已闭合（live 复核 + `system.py:63-64` 逐行；见 §五 更正）。
- **§4.4 #6**：由"未复现"升级为"逐行坐实"（`qwen3_streaming.py:327-350` + 路由捕获面
  `routes/realtime_openai.py:56-61`），回归测试为执行门。
- **仍开放（诚实披露）**：① OpenAI `opus`/`aac` 实际输出容器（Ogg/ADTS）未在真实 API 字节上
  验证——B1 实现前定容器并写入契约；② sona 对 `language` 字符串、segment `id` 类型的全部
  消费点未逐行扫完（已知 `speechrail_realtime.py:40`、`tts.py:63` 两处）——B5/C 执行前补扫；
  ③ SDK 对 required-but-absent 字段的行为（None vs AttributeError）未实测——B 批次用真实
  openai SDK 做解析测试。
- **并行改动**：v1.3 复核与修订期间，工作树存在其他任务对 `README.md` 等文件的改动；本报告
  修订全程仅触及本文件，README 的 mp3 宣称按其当时工作树内容引用。

## 九、执行关闭记录（v1.4，2026-09-02）

在独立 worktree 分支 `feat/openai-conformance` 上按 `A → B →（sona lockstep 确认后）C → D` 执行完毕：

| Batch | Commit | 内容 | 验证 |
|---|---|---|---|
| A | `cb2cd56` | 握手 `?model=`/close 4004、语言与 busy 错误包装并释放预留、`committed` 事件序、`prompt` 透传、error `client_event_id`、`/v1/models` diarize 过滤、realtime 契约标注 | 定向 55+9 测试 GREEN |
| B | `c1d9ba3` | segment `id` 整数化（domain/backends/nemo/compat）、verbose honest-null 字段族、`language` 小写、TTS 六格式 + 默认 `mp3`（固定 ffmpeg argv remux）、13 voice 别名 + `/v1/voices.aliases`、`input` ≤4096、`openapi.yaml` 锁定 | 全量 gate：pytest 通过（coverage 81.23% ≥ 80）、ruff、mypy（56 files）、redocly valid |
| C | `ed69f8e` | `response.output_audio.*` → `response.audio.*`（含 transcript 对）、content part `output_audio` → `audio`；builders/tests/bench/契约同步 | 定向 GREEN；sona lockstep（`tts.py` 与其测试改名，`5 passed`；sona 侧保留未提交待其发布窗口）|
| D | 本提交 | CHANGELOG `[Unreleased]`、README、`docs/users/api-contract.md`、docs 能力矩阵同步、本报告 v1.4 | 全量 gate 复跑全绿；:8202 ephemeral live smoke |

Live smoke（临时实例 :8202，真实 ASR/TTS/diarization runtime；合成非敏感音频 TTS→ASR 闭环）：

- REST 17/17 PASS：默认 `mp3` 魔数、`wav/opus/flac/aac/pcm` 真实容器输出、`voice=alloy` 走别名、
  4096 过字段校验 / 4097 → 422、`verbose_json` `id=0` 整数 + honest nulls + `language="chinese"`、
  转写文本闭环（`语音合规冒烟测试。` 原样回环）。
- WS 14/15 PASS：`?model=nope-xyz` → `model_not_found` + close 4004；`session.created` 回显
  `whisper-1` 且服务端 `event_id` 生成；TTS 腿 live 仅见 `response.audio.*` /
  `response.audio_transcript.*`（零 `output_audio.*`）；`klingon` → `language_not_supported`
  错误事件且会话存活；`committed` 先于终结事件。
- 唯一非通过项为**冒烟断言超出现有后端能力**，非回归：`qwen3_worker._handle_commit` 的 completed
  帧恒 `segments: []`（native streaming 无分段；`include_timestamps` 仅 batch 路径消费），realtime
  segment 事件 live 无法产生；segment `id` 整数契约由单测（`segment_id=7`）与 REST live（`id=0`）
  双重证实。

执行期发现的两个**先前存在**的运维边界（超出本整改范围，另行处理）：

1. `SPEECHRAIL_DEVICE=mps` + `SPEECHRAIL_DTYPE=int8` 组合下 TTS 身份握手恒不匹配
   （`qwen3_tts_worker.py` 身份硬编码 `float16`，而 `qwen3_tts.py` 比较 `config.dtype`），服务启动
   即 `backend_identity_mismatch` 中止。常驻 :8201 因早于 int8 写入配置而存活；**下次重启会失败**，
   需先修身份透传或在 `.env` 回退 `float16`。
2. TTS 流被客户端中途断开时按既有 fail-closed 设计（"abort on any unfinished stream"）终止 worker，
   且 `tts_ready` 不再自动恢复；重拉语义建议与上一条一并评估。

> **后置更新（边界 1 已关闭）**：上述边界 1 已由 TTS 精度可配置量化变更修复（见 CHANGELOG
> `[Unreleased]`）。TTS worker 现接收 `--dtype` 并对 `int8` 做 W8A16 内存量化（talker 子树），
> 身份帧如实报告量化后的 dtype；`qwen3_tts.py` 握手按 `config.dtype` 严格匹配，不再容忍
> "配置 int8、实际 bf16" 静默降级。边界 2（流中途断开终止 worker）仍待评估。

边界披露：真实 `openai` SDK 解析测试未执行（worktree venv 无 `openai` 包），以逐字段 JSON 断言替代；
A6 `prompt` 透传与 `rate_limits` 语义仅单元/契约层证实，live 未单独观测。

### 审查修复（Batch E，fixup）

实施后做了双轨审查（五轴自查 + Oracle 独立对抗审查），verdict = APPROVE WITH FIXES，合并为
单一 fixup 批次（本提交）：

1. **#1 Realtime voice 别名链**：`session.update.voice`/`response.create.response.voice` 此前仅做
   类型检查、原样透传，REST 已实现的 13→4 别名归一化与注册 preset 成员校验在 WS 侧缺失，未知
   voice 到合成时才以 worker 内部错误暴露。现统一在配置入口 `resolve_voice` + 成员校验，
   快速失败 `voice_not_found`/`invalid_voice`，session 不损坏。
2. **#2 流式会话槽位泄漏**（合并阻塞）：`connect()` 失败仅释放 governor 预留，`RealtimeAsrFactory`
   槽位与孤儿 session 不归还。现 `except` 路径先 `close()` 孤儿 session 再 `release()`。
   **F2 自纠**：Batch A 表中「释放预留容量」表述不完整——当时仅释放预留，未归还 factory 槽位。
3. **#3 空合成输出**：后端零 chunk 时 pcm/wav 返回空 200 主体、容器格式依赖 ffmpeg 行为不一致；
   现六格式统一 `502 audio_encode_failed`（pcm 以首 chunk peek 实现，保持流式）。
4. **#4 错误回显放大**：握手与 `session.update` 的 `unknown model: {model}` 未截断，可回显任意长度
   客户端输入；现截断至 200 字符。
5. **#5 边界测试补齐**：`prompt` 恰 2000 边界透传、REST 别名目标 preset 未注册时拒绝、
   REST `prompt` 2000/2001 边界、connect 失败后会话恢复（`committed` 可达）、error envelope
   截断等 characterization + 回归用例。

`contracts/realtime-openai.md` 的 `session.update`/`response.create` 语义与 CHANGELOG 已同步。

## 附录 A：Realtime TTS OpenAI 官方参数（🟡 已带链接确认）

来源：platform.openai.com/docs/api-reference/audio/createSpeech、
platform.openai.com/docs/guides/text-to-speech、github.com/openai/openai-openapi、
github.com/openai/openai-python（`resources/audio/speech.py`）。

- `response_format` 枚举：`mp3`(默认)/`opus`/`aac`/`flac`/`wav`/`pcm`；**pcm = 24 kHz、16-bit 有符号、小端、单声道、无头**。
- 内置 voice（13）：`alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer, verse, marin, cedar`；`tts-1`/`tts-1-hd` 支持子集 9 个（除 `ballad/verse/marin/cedar`）。
- `input` ≤ 4096 字符；`speed` 0.25–4.0（默认 1.0）；`instructions` 仅 `gpt-4o-mini-tts`；`stream_format` = `audio`(默认)/`sse`（sse 仅 `gpt-4o-mini-tts`）。
- 模型：`tts-1`、`tts-1-hd`、`gpt-4o-mini-tts`（+ 日期快照）。

## 附录 B：Realtime 事件集对照（OpenAI 现行 vs SpeechRail）

（来源：openai-python `main` 生成模型 `types/realtime/realtime_server_event.py`，v1.3 一手比对）

| OpenAI 现行事件 | SpeechRail | 备注 |
|---|---|---|
| `response.audio.delta`/`done` | `response.audio.delta`/`done` | ✅ v1.4 已对齐（Batch C `ed69f8e`，live 验证）|
| `response.audio_transcript.delta`/`done` | 同名 | ✅ v1.4 已对齐（Batch C，live 验证）|
| `conversation.item.input_audio_transcription.delta`/`completed`/`failed` | 同名 | ✅ 现行命名 |
| `conversation.item.input_audio_transcription.segment` | 同名 emit | ✅ **v1.3 更正**：该事件在现行 union 中，命名与 OpenAI 对齐；字段含 SpeechRail diar 扩展 |
| `input_audio_buffer.speech_started`/`stopped` | 不 emit | 无 VAD（有意，ADR-0009；§七不做清单）|
| `rate_limits.updated` | 不 emit | ✅ v1.3 裁定：单机无配额语义，维持裁剪 + 契约标注（A7）|
| `response.text.*`/`response.function_call_arguments.*` | 不 emit | 不承载 LLM/工具（有意）|
| `session.created`/`updated`、`input_audio_buffer.*`、`conversation.item.created`、`response.created`/`done`/`output_item.*`/`content_part.*`、`error` | 对齐 | ✅（C 执行时按 union 复核非音频事件名为 checklist 项）|
| 顶层 `sequence`、`session_id`；server 事件带 `event_id` | 附加 | ⚪ v1.3 降级：SDK `construct_type_unchecked` 宽松解析不致破坏；契约标注（A7）；error 事件关联 id 被覆盖是唯一真瑕疵（A5）|
