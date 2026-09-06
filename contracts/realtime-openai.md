# SpeechRail OpenAI Realtime 兼容契约

`WS /v1/realtime` 实现 OpenAI Realtime WebSocket 协议的 ASR/TTS 子集，让标准 OpenAI
客户端（`openai` SDK 的 `client.realtime.connect(model=...)`、以及硬编码 `/v1/realtime`
路径的客户端）无需定制 URL 即可接入 SpeechRail 的本机转写与合成能力。

SpeechRail 只承载 ASR/TTS。LLM 对话历史、工具调用、图像 modality 和任意模型名都不会被
伪装：未支持能力返回稳定的 `error`，而不是静默接受。

## 连接与认证

```text
ws://127.0.0.1:8201/v1/realtime
```

- 认证：配置 API key 时握手必须携带 `Authorization: Bearer <key>`；失败以
  `1008` 关闭。
- **并发会话**：多个 WebSocket 连接可同时存在，共享同一 streaming worker。
  worker 帧按 `session_id` 路由到独立会话状态，互不干扰；同时活跃的
  backend ASR 会话数由 `SPEECHRAIL_REALTIME_MAX_SESSIONS` 限制
  （默认 `2`，范围 `1-8`）。达到上限后，触发 backend 会话创建的
  `input_audio_buffer.append` 返回 `error`（`backend_busy`），该连接自身的
  session 保持可用并可在其他会话释放后继续。
- 仅接受 JSON 文本事件；音频放在 Base64 字段，**ASR 输入固定为 16 kHz、单声道、
  16-bit little-endian PCM**。
- `?model=` 查询参数在握手即生效（对应标准 `client.realtime.connect(model=...)`）：已知模型在
  `session.created.session.model` 中回显请求名，内部归一化到 SpeechRail canonical profile；
  缺省使用 canonical ASR profile。未登记模型在 accept 后发送 `error`（`model_not_found`）并以
  close code `4004` 关闭，不发送 `session.created`。模型清单：
  - `speechrail/qwen3-asr-1.7b`（canonical）
  - `whisper-1`、`gpt-4o-transcribe`、`gpt-4o-mini-transcribe`、`gpt-transcribe`、
    `gpt-live-transcribe` → ASR 兼容 alias
  - `gpt-4o-transcribe-diarize` → 需要可用 diarization profile 的 ASR alias；profile 未就绪时
    握手返回 `model_not_found`，与 `/v1/models` 的隐藏语义一致（diarization 启用仍需
    `session.update`）
  - `speechrail/qwen3-tts`（canonical，需 TTS backend ready）
  - `tts-1`、`tts-1-hd`、`gpt-4o-mini-tts` → TTS 兼容 alias
  - `session.update.session.model` 继续同样解析；两者同时出现时以最后一次生效。
- `/v1/models` 列出 canonical 与当前可用的兼容 alias，alias 条目带 `resolves_to` 标注其
  canonical profile；canonical 条目同时声明当前受管档位、实际 artifact、variant 与量化；
  `gpt-4o-transcribe-diarize` 仅在 diarization profile 可用时出现。
- `/v1/voices` 的 `available`、`variant` 与 `capabilities` 取自同一次启动所加载的档位。
  Realtime 客户端应选择 `available=true` 的 voice；OpenAI voice alias 仍按固定映射解析。

## 支持的客户端事件

| 事件 | 语义 |
|---|---|
| `session.update` | 更新 session 配置；仅接受 ASR/TTS 允许字段。`turn_detection` 支持 `null`/`manual` 以及 `{"type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 400}`；`tools` 非空 → `unsupported_tools`；`modalities` 仅 `text`/`audio`；`input_audio_format`/`output_audio_format` 仅 `pcm16`；支持 `input_audio_transcription.language`、`languages`、`prompt`（≤2000 字符，超限 → `prompt_too_long`）、`keywords`（动态热词注入）、`timestamp_granularities`、`known_speaker_names`、`known_speaker_references` 和可选 `diarization`。`instructions`、`temperature`、`max_response_output_tokens`、`tool_choice` 接受但**无效果**（本服务器不承载 LLM，无对应语义通道；拒绝会伤害按标准发完整载荷的客户端）；`voice` 接受已注册 voice 与 13 个 OpenAI 标准 voice 别名并驱动 TTS 合成；配置入口即校验：未知 voice → `voice_not_found`，已注册但当前权重不支持 → `voice_not_available`，非字符串或空白 → `invalid_voice`。失败均保持 session 可用；客户端可改用 `/v1/voices` 中 `available=true` 的系统 preset。返回 `session.updated` |
| `input_audio_buffer.append` | 追加 base64 PCM16；在启用 `server_vad` 时进行实时语音活动检测与防抖，并在检测到用户说话时触发当前会话内的 Barge-in 打断；推流累积达到时间窗时服务端自动驱动 partial 识别；未提交缓冲区达到上限时自动分段结转（Auto-Commit Rollover），避免硬断；返回 `input_audio_buffer.committed` 只在 commit、VAD 静音截断或超限结转时；不支持语言或后端忙返回 `error`（`language_not_supported`/`backend_busy`），session 保持可用 |
| `input_audio_buffer.commit` | 触发流式转写终态；按序发送 `input_audio_buffer.committed` → `conversation.item.created` → `conversation.item.input_audio_transcription.delta`*（若后端产出 partial）→ `completed`/`failed`；`committed` 恒先于转写终态；缓冲区为空时幂等完成空闭环，保持 session 正常存活 |
| `input_audio_buffer.clear` | 丢弃未提交缓冲；重置 VAD 状态机，返回 `input_audio_buffer.cleared` |
| `conversation.item.create` | 接受单个 `role=user` 的 `input_text` 内容，创建文本 item（需 TTS ready）；随后必须发送 `response.create` 才触发合成 |
| `response.create` | 用最近一次 `conversation.item.create` 的文本触发 TTS 流式合成（使用 `StreamingSentenceSplitter` 分句合成并施加淡入淡出音频平滑）；无待处理文本 → `invalid_state`；`response.voice` 按与 `session.update.voice` 相同的规则校验（`voice_not_found`/`voice_not_available`/`invalid_voice`） |
| `response.cancel` | 取消进行中的 TTS response；丢弃未发送音频并返回 `response.done`（`status: cancelled`） |

以下客户端事件被拒绝（`unsupported_operation`）：`conversation.item.delete`、
`conversation.item.truncate`。

## 服务端事件

| 事件 | 说明 |
|---|---|
| `session.created` | 连接建立后立即发送；声明实际能力（modalities、`input_audio_format`/`output_audio_format: pcm16`、`turn_detection: null`）、`capabilities` 列表及由当前权重生成的 `speech_capabilities`（`available`、`variant`、`supports_speaker`、`supports_instruction`） |
| `conversation.created` | 会话容器；SpeechRail 不实现可查询/可编辑的消息历史 |
| `session.updated` | `session.update` 的确认；重复当前 `speech_capabilities`，调用方无需上传或感知本机档位 |
| `input_audio_buffer.speech_started` | 启用 `server_vad` 时，检测到连续有效语音帧（$\ge 96\text{ms}$ 防抖通过）后触发；自动打断当前会话正在进行的 TTS 合成输出 |
| `input_audio_buffer.speech_stopped` | 启用 `server_vad` 时，检测到静音持续超过 `silence_duration_ms` 后触发；随后自动执行 committed 转写 |
| `input_audio_buffer.committed` / `cleared` | 缓冲状态变化；`committed` 携带 `item_id` |
| `conversation.item.created` | 每次 committed 输入或文本 item 创建（item ID 仅当前 WebSocket 会话有效）；item 含 `object: "realtime.item"` |
| `conversation.item.input_audio_transcription.delta` | partial 转写（native 流式后端产出时）；携带 `item_id`/`content_index`/`delta` |
| `conversation.item.input_audio_transcription.segment` | 启用 diarization 且 backend 返回已验证 segment 时发送；携带 `id`/`text`/`speaker`/`start`/`end`/`item_id`/`content_index`，时间单位为秒；未启用时不伪造 speaker |
| `conversation.item.input_audio_transcription.completed` / `failed` | ASR 终态；`completed` 携带 `item_id`/`content_index`/`transcript`/`usage`（经轻量 ITN 规整），在 commit 后必然发送 |
| `response.created` | TTS response 开始；`response.id` 用于关联后续事件 |
| `response.output_item.added` / `done` | TTS 输出 item 生命周期 |
| `response.content_part.added` / `done` | TTS 输出音频 part 生命周期 |
| `response.audio.delta` / `done` | TTS 音频块（base64）；携带 `response_id`/`item_id`/`output_index`/`content_index`；输出为 24 kHz PCM16 |
| `response.audio_transcript.delta` / `done` | TTS 输入文本回显；不代表 ASR 结果 |
| `response.done` | TTS response 终态（`status: completed` 或 `cancelled`） |
| `error` | 统一错误 envelope：`{"type": "error", "error": {"type": "invalid_request_error", "code": "...", "message": "...", "event_id": "<可选，回显触发错误的客户端事件 id>"}}`；分人 profile 不可用时 `code=diarization_not_available`；`session.update` 传入超限转写 prompt 时 `code=prompt_too_long`；非法语言或后端忙时 `code=language_not_supported`/`backend_busy` |

每个服务端事件还带顶层 `event_id`、`session_id` 和从 1 开始单调递增的 `sequence`。
`event_id` 由服务端每次发送时生成、在一个连接内唯一；断线不会恢复旧事件，重连会创建新的 session。
`event_id`/`session_id`/`sequence` 是相对 OpenAI 的加法字段，标准 SDK 宽松解析容忍。
本服务器不发送 `rate_limits.updated`（单机部署无多租户配额语义）。

## 转写语义

`conversation.item.input_audio_transcription.delta`（partial）在推流累积达到时间窗时自动驱动，
下发相对上一窗口的增量增量切片（客户端直接追加无文本重复）；客户端亦以 `commit` 后的
`completed` 作为最终全量结果。

启用 diarization 时，`completed` 事件携带词级 `segments`（worker 对已累积音频做一次
强制对齐，按 `{text, start_ms, end_ms}` 产出），WS 层据此按 segment 粒度发送
`conversation.item.input_audio_transcription.segment`，每项含 `speaker`；**未启用
diarization 时 `segments` 为空、不发送 `.segment` 事件**，行为与无分人路径一致。

`/v1/realtime` 是 SpeechRail 唯一的 Realtime 入口。此前的 SpeechRail-native `/v2/realtime`
已移除；客户端不得依赖私有 v2 事件或把 v2 作为隐式降级路径。

## 语音准入与无声闭环（SR-SILENCE-1）

在 `server_vad` 模式下，SpeechRail 引入有界语音准入机制（`SpeechAdmission`），默认启用（`realtime_speech_admission_enabled`，可用环境变量显式关闭回到 legacy 路径）：

1. **准入与 ASR 隔离**：在未检测到确认的连续人声前（IDLE/CANDIDATE 状态），不向 ASR 推理器输入音频、不执行无声 flush，且绝不发送非空 `delta`、`segment` 或 `completed` 文本（杜绝纯静音下输出“嗯”等幻觉转录）。legacy 路径（准入关闭时）保留防抖前音频缓冲，但仅保留最近 `prefix_padding_ms` 窗口，静音不进入 ASR、缓冲不无界增长。
2. **时钟守恒与时间映射**：连续输入的 session sample 时钟以及 diarization 输入不受准入跳过静音的影响，始终按物理音频线性推进；ASR 接纳区间的本地时间统一映射回 session-global sample 时钟（包括 pre-roll 前置缓冲与尾音）。
3. **确定性空闭环**：在纯静音、空缓冲或未准入语音状态下触发的 commit（无论是客户端显式 commit 还是超限结转），均执行统一的空终态序列：`input_audio_buffer.committed` → `conversation.item.created` → `conversation.item.input_audio_transcription.completed`（其中 `transcript=""`，扩展模式下 `attribution_units=[]`）。连接与会话保持健康可用。
4. **全双工打断（Barge-in）**：在 TTS 正在播放时，一旦检测到有效人声输入（`speech_started`），立即原子取消当前 TTS 响应并释放硬件排队槽位，随后无阻塞启动 ASR 会话。
5. **话语中途 commit 与超限结转的单次闭环**：当客户端显式 `commit` 或缓冲超限结转发生在已准入话语进行中时，服务端先发送 `input_audio_buffer.speech_stopped`，随后对该 item 恰好执行一次 `committed` → `item.created` → `completed` 终态序列；不产生重复 `committed`、幻影空 item 或额外空闭环。ASR 会话随后为新准入区间重新建立。
6. **协议透明与兼容**：`turn_detection=null` 或 `manual` 模式完全保持原有行为；`server_vad` 模式不新增未协商的私有 wire 字段，现有 OpenAI Realtime 客户端与 Sona 无缝兼容。

### VAD 引擎

`realtime_vad_engine` 选择帧级语音概率评分器：`legacy`（默认，能量 + 过零率评分）或 `silero`（Silero VAD v4 ONNX，`input/h/c/sr` 递归 schema；v5 ONNX 的 `input/state/sr` schema 不受支持，加载时明确报错，不静默回退）。`silero` 引擎要求 `realtime_speech_admission_enabled=true`（服务端配置校验强制），且要求配置 `realtime_vad_model_path`。客户端下发的 `turn_detection.threshold` 在 legacy 引擎下映射到能量评分门限、在 silero 引擎下为真实语音概率门限；两者对同一取值的灵敏度不同。

- **双阈值迟滞**（参照 Silero 官方 VADIterator）：起振帧须达到 `threshold`；已进行的话语仅在概率低于 `threshold - 0.15`（服务端 `stop_threshold`，可显式覆盖）时开始收尾。处于迟滞带（低于 entry、不低于 exit）的帧不会截断进行中的话语，也不会从静音新开话语。
- **server_vad 参数默认值**：`threshold=0.5`、`prefix_padding_ms=300`、`silence_duration_ms=400` 为 SpeechRail 本地默认。注意 `silence_duration_ms` 的 OpenAI 官方默认为 **500ms**：依赖平台默认端点时长的客户端应显式传参以获得确定行为。
- **ONNX 会话共享**：`InferenceSession` 按模型文件路径跨 WebSocket 连接共享（`Run()` 官方线程安全）；递归 h/c 状态按连接隔离并在 `reset`/`clear` 时清零。
- **shadow 观测**：`realtime_vad_shadow_enabled`（仅 legacy 引擎可用）下 shadow 引擎逐帧打分仅用于观测对比，不改任何协议行为；指标 `speechrail_realtime_vad_shadow_frames_total{agreement=both_speech|both_silence|primary_only|shadow_only}` 按帧记录主引擎与 shadow 引擎相对 entry threshold 的判定一致性。

## Diarization 扩展 `speechrail.diarization.v1`（SPK-E2E-1）

本节为 opt-in 加法扩展：未协商的会话行为与本文件其余部分完全一致。设计事实源为
`docs/architecture/speaker-diarization-e2e-design.md` 第 5 节；JSON Schema 与 fixtures
位于 `contracts/diarization/v1/`（schema + 语义规则共同构成校验标准）。连续分人的
native 能力未经 R1 探针与真实 CPU smoke 验证前，本扩展不会被广播，也不可协商成功。

### 协商

- `session.created.capabilities` 仅在连续分人 adapter 与契约实现均可用时包含
  `speechrail.diarization.v1`。
- 客户端必须先读 capability，再在 `session.update` 中显式请求：
  `input_audio_transcription.diarization.extensions = ["speechrail.diarization.v1"]`
  （数组去重，只接受登记值；未知值 → `invalid_diarization`）。
- 协商成功后 `session.updated.session.diarization_contract` 固定为
  `{version: 1, timebase: "session_samples", sample_rate: 16000, max_speakers: 4,
  max_item_duration_ms: 8000, max_revision_delay_ms: 3000, group_generation}`；
  未成功回显即未启用。
- 扩展只能在首个 PCM 前协商；已接受音频后的首次协商 → `invalid_state`，
  能力未广播时请求 → `unsupported_operation`，扩展模式下 `speaker_count_hint > 4`
  → `speaker_limit_exceeded`（1–4 不裁掉模型活动输出）。
- 新旧组合：旧客户端保持旧事件集合；新客户端连旧服务收到
  `unsupported_operation` 后继续 legacy 模式。

### 扩展模式下的事件差异

- `input_audio_buffer.committed`、`conversation.item.created` 与
  `conversation.item.input_audio_transcription.completed` 使用每次 commit 唯一的
  `item_id`（不再是 `item_{session_id}_input`）。
- `completed` 新增 `audio_start_sample`/`audio_end_sample`（session-global 16 kHz
  整数样本域）与 `attribution_units`（`segment_uid`、`text_start`/`text_end`
  canonical 码点区间、`audio_start_sample`/`audio_end_sample`、`timing_quality`，
  `aligned | unavailable`）。单元完整分割 canonical text；空 transcript 为空数组；
  无法与固定正文一致对齐时整 item 使用一个 `timing_quality="unavailable"` 单元。
  这些字段在归属修订中不可变。
- 扩展模式**不再发送**旧 `.segment` 事件，避免双写；legacy 会话不受影响。
- `speechrail.diarization.update`：服务端推送的归属修订事件，携带 `stable_through_sample`、
  `updates`（含 `segment_uid`、`revision` 从 1 严格递增、`status: tentative | stable | unknown`、
  `speaker`、`coverage_ratio`、`overlap_ratio`、`candidates`）以及会话级 `speaker_links` 声学建议；
  无法对齐或过期的单元直接归属为 `unknown`（`speaker: null`）。
- `speechrail.diarization.status`：发生不可恢复故障（如 `diarization_overloaded`、
  `diarization_invalid_output` 或 `finalization_timeout`）时触发单次 active→degraded 转换，
  先为未定态单元发送 `unknown` update，再发送本事件；此后正文正常交付，归属保持 `unknown`。
- `speechrail.diarization.finalize`（客户端）与 `speechrail.diarization.finalized`（服务端终态）：
  客户端推流完毕后发送 finalize 请求（携带 `finalization_id`）；服务端进入 DRAINING 屏障，
  冲刷声学尾部并排空所有 pending updates，最后发送 finalized 事件（携带 `through_sample`、
  `stable_through_sample`、`status: complete | degraded` 与 `last_update_sequence`）。
  相同 `finalization_id` 重试幂等回显；不同 ID 请求拒绝返回 `invalid_state`；finalize
  后追加音频返回 `invalid_state`。
