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
- 仅接受 JSON 文本事件；音频放在 Base64 字段，输入为单声道、16-bit little-endian PCM。
  legacy profile 使用 16 kHz；当前 transcription profile 也接受 24 kHz，并在会话内转换为
  ASR 的 16 kHz 内核格式。
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
| `session.update` | 更新 session 配置；缺失字段保持当前有效值，显式 `null` 清除对应可清除配置；候选配置通过校验后原子生效。兼容 legacy 根字段与当前 transcription session 的 `audio.input.{format,transcription,turn_detection}`：输入为 PCM16，支持 `16000` 或 `24000` Hz；24 kHz 在会话内有状态降采样为内部 16 kHz，首个 PCM 后不得改格式。`turn_detection` 支持 `null`/`manual` 以及 `{"type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 400}`；`tools` 非空 → `unsupported_tools`；`modalities` 仅 `text`/`audio`；`input_audio_format`/`output_audio_format` 仅 `pcm16`；支持 `input_audio_transcription.language`、`languages`、`prompt`（≤2000 字符，超限 → `prompt_too_long`）、`keywords`（动态热词注入）、`timestamp_granularities`、`known_speaker_names` 与 `known_speaker_references`。分人仅接受 `session.speechrail.diarization.enabled`；旧 `diarization` 请求形态 → `invalid_diarization`。`instructions`、`temperature`、`max_response_output_tokens`、`tool_choice` 接受但**无效果**（本服务器不承载 LLM，无对应语义通道）；`voice` 接受已注册 voice 与 13 个 OpenAI 标准 voice 别名并驱动 TTS 合成；配置入口即校验：未知 voice → `voice_not_found`，已注册但当前权重不支持 → `voice_not_available`，非字符串或空白 → `invalid_voice`。失败均保持 session 可用；客户端可改用 `/v1/voices` 中 `available=true` 的系统 preset。返回 `session.updated` |
| `input_audio_buffer.append` | 追加 base64 PCM16；在启用 `server_vad` 时进行实时语音活动检测与防抖，并在检测到用户说话时触发当前会话内的 Barge-in 打断；推流累积达到时间窗时服务端自动驱动 partial 识别；未提交缓冲区达到上限时自动分段结转（Auto-Commit Rollover），避免硬断；返回 `input_audio_buffer.committed` 只在 commit、VAD 静音截断或超限结转时；不支持语言或后端忙返回 `error`（`language_not_supported`/`backend_busy`），session 保持可用。接入层同时限制待处理 JSON/Base64 字节与事件数；预算耗尽以 `1013` 关闭，客户端应重新连接而不是重放未确认音频 |
| `input_audio_buffer.commit` | 触发流式转写终态；按序发送 `input_audio_buffer.committed` → `conversation.item.created` → `conversation.item.input_audio_transcription.delta`*（若后端产出 partial）→ `completed`/`failed`；`committed` 恒先于转写终态。ASR 的 commit、终态读取与资源回收共享 `SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` 总 deadline；超时返回 `backend_timeout` 并释放该 turn 的 worker lane。缓冲区为空时幂等完成空闭环，保持 session 正常存活 |
| `input_audio_buffer.clear` | 丢弃未提交缓冲；重置 VAD 状态机，返回 `input_audio_buffer.cleared` |
| `conversation.item.create` | 接受单个 `role=user` 的 `input_text` 内容，创建文本 item（需 TTS ready）；随后必须发送 `response.create` 才触发合成 |
| `response.create` | 用最近一次 `conversation.item.create` 的文本触发 TTS 流式合成（当前 Qwen worker 使用 `TtsTextPlanner(tts_bounded_v1)` 包装既有 `bounded_sentences` 进行有界分段，并施加淡入淡出音频平滑）；无待处理文本 → `invalid_state`；`response.voice` 按与 `session.update.voice` 相同的规则校验（`voice_not_found`/`voice_not_available`/`invalid_voice`）。准入与整个生成/交付共享一个总 deadline；同一 TTS capability 内请求共用有界 worker lane；Quality 的 VoiceDesign 与 Base lane 独立；超时返回 `backend_timeout` 与 failed `response.done`，已知 worker 生命周期不可用返回 `backend_busy`（带 `speechrail.busy_reason=backend_unavailable` 与重试提示），其他未知 TTS 运行时失败返回脱敏的 `backend_error`，均以 failed `response.done` 终止 response。 |
| `response.cancel` | 取消进行中的 TTS response；丢弃未发送音频并返回 `response.done`（`status: cancelled`）。该事件走独立、有界的控制通道：先等待此前已接收的 `input_audio_buffer.append` 在 FIFO 数据通道开始分派，再取消 TTS；它不等待正在进行的 ASR `commit` 或推理结束，避免 TTS 占用 worker lane 时形成互相等待。其他客户端事件仍按接收顺序执行。 |

以下客户端事件被拒绝（`unsupported_operation`）：`conversation.item.delete`、
`conversation.item.truncate`。

### 可选 TTS model revision 条件绑定

在首个 TTS response 前，客户端可以通过 `session.update` 提供：

```json
{
  "type": "session.update",
  "session": {
    "speechrail": {
      "model_revision": {"expected": "<40-char-hex>"}
    }
  }
}
```

服务端会在 `session.updated` 回显 `expected` 与匹配的 `catalog_revision`。条件不满足时返回
`model_revision_conflict`，候选配置不会提交，当前 session 仍可继续使用或重新协商。该 revision
是已加载 catalog artifact 的配置身份，不是模型权重内容 hash，也不替代真实 worker/runtime
身份回执或跨重启证据。

### 可选 TTS 完整性回执

客户端可在首个 TTS response 前发送：

```json
{
  "type": "session.update",
  "session": {"speechrail": {"render_receipts": {"enabled": true}}}
}
```

服务端在 `session.updated` 中回显协商结果；启用后，最终 `response.done` 追加
`speechrail.render_receipt`。回执只包含 voice/catalog identity、终态、24 kHz PCM sample
count 与 SHA-256，不包含音频正文或原始文本。`model.runtime_revision` 只有在首个已验证
PCM chunk 由 worker 产生且 ready handshake 身份完整时才填充 `rt_...`；缺少可信身份时保持
`null`。该摘要不暴露本地路径，也不把 `shape:` 结构元数据宣称为权重内容哈希。

## 服务端事件

| 事件 | 说明 |
|---|---|
| `session.created` | 连接建立后立即发送；声明实际能力（modalities、`input_audio_format`/`output_audio_format: pcm16`、`turn_detection: null`）、`capabilities` 列表及由当前权重生成的 `speech_capabilities`（`available`、默认 TTS `variant`、`supports_speaker`、`supports_instruction`、`supports_clone`）。`supports_clone=true` 表示独立 Base clone capability 已配置；此时同时声明 `audio_loudness_profile: stable_loudness_v1`。clone voice 由 Quality capability router 路由至独立 Base worker；它与 VoiceDesign 可双常驻、跨 capability 并发，同一 capability 内串行 |
| `conversation.created` | 会话容器；SpeechRail 不实现可查询/可编辑的消息历史 |
| `session.updated` | `session.update` 的确认；重复当前 `speech_capabilities`（包括可选的 `audio_loudness_profile`），调用方无需上传或感知本机档位 |
| `input_audio_buffer.speech_started` | 启用 `server_vad` 时，检测到连续有效语音帧（$\ge 96\text{ms}$ 防抖通过）后触发；自动打断当前会话正在进行的 TTS 合成输出 |
| `input_audio_buffer.speech_stopped` | 启用 `server_vad` 时，检测到静音持续超过 `silence_duration_ms` 后触发；随后自动执行 committed 转写 |
| `input_audio_buffer.committed` / `cleared` | 缓冲状态变化；`committed` 携带 `item_id` |
| `conversation.item.created` | 每次 committed 输入或文本 item 创建（item ID 仅当前 WebSocket 会话有效）；item 含 `object: "realtime.item"` |
| `conversation.item.input_audio_transcription.delta` | partial 转写（native 流式后端产出时）；携带 `item_id`/`content_index`/`delta`。只发送可直接追加的稳定前缀；改写中的尾部保留到 `completed` |
| `conversation.item.input_audio_transcription.segment` | 非分人会话在 backend 返回已验证 segment 时发送；携带 `id`/`text`/`start`/`end`/`item_id`/`content_index`，时间单位为秒。分人扩展用 `attribution_units` 与 `speechrail.diarization.updated`，不在该事件混入 speaker |
| `conversation.item.input_audio_transcription.completed` / `failed` | ASR 终态；`completed` 携带 `item_id`/`content_index`/`transcript`/`usage`（经轻量 ITN 规整），在 commit 后必然发送 |
| `response.created` | TTS response 开始；`response.id` 用于关联后续事件 |
| `response.output_item.added` / `done` | TTS 输出 item 生命周期 |
| `response.content_part.added` / `done` | TTS 输出音频 part 生命周期 |
| `response.audio.delta` / `done` | legacy TTS 音频块（base64）；携带 `response_id`/`item_id`/`output_index`/`content_index`；输出为 24 kHz PCM16 |
| `response.output_audio.delta` / `done` | current nested `audio` session profile 的 TTS 音频块；同一 response 只会使用一组 audio event literal，避免客户端重复播放 |
| `response.audio_transcript.delta` / `done` | TTS 输入文本回显；不代表 ASR 结果 |
| `response.done` | TTS response 终态（`status: completed`、`failed` 或 `cancelled`） |
| `error` | 统一错误 envelope：`{"type": "error", "error": {"type": "invalid_request_error", "code": "...", "message": "...", "event_id": "<可选，回显触发错误的客户端事件 id>"}}`；格式错误 JSON 或非对象事件返回 `invalid_event`，不使会话任务异常退出；分人 profile 不可用时 `code=diarization_not_available`；`session.update` 传入超限转写 prompt 时 `code=prompt_too_long`；非法语言或后端忙时 `code=language_not_supported`/`backend_busy`；未知 TTS 运行时失败使用 `code=backend_error` 与固定脱敏消息，不返回内部异常文本。后端忙的 Realtime 错误可在顶层 `speechrail.busy_reason` 中提供低基数原因：`asr_mode_conflict`、`realtime_session_limit`、`diarization_capacity`、`governor_queue_full`、`backend_transition` 或 `backend_unavailable`；同一 `speechrail` namespace 还提供布尔 `retryable` 与低基数 `retry_hint`，例如 `wait_for_realtime_session_slot`、`retry_after_worker_recovery`、`backoff_and_retry`；worker 生命周期不可用仍保持兼容的 `code=backend_busy`。 |

每个服务端事件还带顶层 `event_id`、`session_id` 和从 1 开始单调递增的 `sequence`。
`event_id` 由服务端每次发送时生成、在一个连接内唯一；断线不会恢复旧事件，重连会创建新的 session。
`event_id`/`session_id`/`sequence` 是相对 OpenAI 的加法字段，标准 SDK 宽松解析容忍。
本服务器不发送 `rate_limits.updated`（单机部署无多租户配额语义）。

`/metrics` 仅记录低基数的 Realtime 阶段耗时：`asr_admission`、`asr_flush`、
`asr_commit_ack`、`asr_terminal_wait`、`tts_admission`、`tts_complete` 与 `send`。
这些是服务端 source-side 阶段边界；其中 `asr_commit_ack`/`asr_terminal_wait` 支持
commit-tail 分解，`tts_complete` 在最终音频/content 事件发送后、`response.done` 前记录。
阶段标签不包含 request/session ID、文本或音频内容，阶段之间不应被简单相加，也不能替代
客户端实际播放延迟或 managed/人工质量证据。服务端发送也受
`SPEECHRAIL_REQUEST_TIMEOUT_SECONDS` 约束；慢消费者超过该时限会以 `1011` 关闭连接，
避免长期占住会话发送锁。

## 转写语义

`conversation.item.input_audio_transcription.delta`（partial）在推流累积达到时间窗时自动驱动，
只下发相对已发送稳定前缀的可追加切片。若上游改写已有前缀，服务端不发送无法安全追加的
文本，客户端以 `commit` 后的 `completed` 全量结果为准。每个 committed 输入都有唯一的
会话内 `item_id`；`committed`、`conversation.item.created`、partial、segment、completed 与 failed
均使用该同一 ID。

启用 diarization 时，`completed` 事件携带词级 `segments`（worker 对已累积音频做一次
强制对齐，按 `{text, start_ms, end_ms}` 产出），WS 层据此按 segment 粒度发送
`conversation.item.input_audio_transcription.segment`，每项含 `speaker`；**未启用
diarization 时 `segments` 为空、不发送 `.segment` 事件**，行为与无分人路径一致。

`/v1/realtime` 是 SpeechRail 唯一的 Realtime 入口。此前的 SpeechRail-native `/v1/speechrail/realtime`
已移除；客户端不得依赖私有 v2 事件或把 v2 作为隐式降级路径。

## 语音准入与无声闭环（SR-SILENCE-1）

在 `server_vad` 模式下，SpeechRail 引入有界语音准入机制（`SpeechAdmission`），默认启用（`realtime_speech_admission_enabled`，可用环境变量显式关闭回到 legacy 路径）：

1. **准入与 ASR 隔离**：在未检测到确认的连续人声前（IDLE/CANDIDATE 状态），不向 ASR 推理器输入音频、不执行无声 flush，且绝不发送非空 `delta`、`segment` 或 `completed` 文本（杜绝纯静音下输出“嗯”等幻觉转录）。legacy 路径（准入关闭时）保留防抖前音频缓冲，但仅保留最近 `prefix_padding_ms` 窗口，静音不进入 ASR、缓冲不无界增长。
2. **时钟守恒与时间映射**：连续输入的 session sample 时钟以及 diarization 输入不受准入跳过静音的影响，始终按物理音频线性推进；ASR 接纳区间的本地时间统一映射回 session-global sample 时钟（包括 pre-roll 前置缓冲与尾音）。
3. **确定性空闭环**：在纯静音、空缓冲或未准入语音状态下触发的 commit（无论是客户端显式 commit 还是超限结转），均执行统一的空终态序列：`input_audio_buffer.committed` → `conversation.item.created` → `conversation.item.input_audio_transcription.completed`（其中 `transcript=""`，扩展模式下 `attribution_units=[]`）。连接与会话保持健康可用。
4. **全双工打断（Barge-in）**：在 TTS 正在播放时，一旦检测到有效人声输入（`speech_started`），立即原子取消当前 TTS 响应并释放硬件排队槽位，随后无阻塞启动 ASR 会话。取消后进入 `realtime_vad_bargein_cooldown_ms`（默认 250ms）冷却窗口，窗口内新的 `speech_started` 不再触发取消，防止 TTS 尾部回声反复触发打断。
5. **话语中途 commit 与超限结转的单次闭环**：当客户端显式 `commit` 或缓冲超限结转发生在已准入话语进行中时，服务端先发送 `input_audio_buffer.speech_stopped`，随后对该 item 恰好执行一次 `committed` → `item.created` → `completed` 终态序列；不产生重复 `committed`、幻影空 item 或额外空闭环。ASR 会话随后为新准入区间重新建立。
6. **协议透明与兼容**：`turn_detection=null` 或 `manual` 模式完全保持原有行为；`server_vad` 模式不新增未协商的私有 wire 字段，现有 OpenAI Realtime 客户端与 Sona 无缝兼容。

### VAD 引擎

`realtime_vad_engine` 选择帧级语音概率评分器：`auto`（默认，配置 `realtime_vad_model_path` 时解析为 `silero`，否则回退 `legacy`）、`legacy`（能量 + 过零率评分）或 `silero`（Silero VAD ONNX，自动探测 v4 `input/h/c/sr` 与 v5/v6 `input/state` schema；不支持的 schema 在加载时明确报错、不静默回退）。解析为 `silero` 时要求 `realtime_speech_admission_enabled=true`（服务端配置校验强制），且要求配置 `realtime_vad_model_path`；`auto` 已配置模型但 preflight 失败时返回 `backend_not_ready`，不降级到 `legacy`。受支持的 Apple Silicon managed wheel（macOS 14+）直接携带并锁定 `onnxruntime==1.30.0`；服务启动前的 preflight 使用 ASGI 应用实际 Python 验证该导入，`/health` 与成功的 `/readyz` 以 `realtime_vad.ready/code/message` 暴露结果。客户端不需要安装 VAD SDK；若返回 `vad_runtime_missing`，应修复 SpeechRail release，而不是改变客户端协议或静默改用 legacy。客户端下发的 `turn_detection.threshold` 在 legacy 引擎下映射到能量评分门限、在 silero 引擎下为真实语音概率门限；两者对同一取值的灵敏度不同。

- **双阈值迟滞**（参照 Silero 官方 VADIterator）：起振帧须达到 `threshold`；已进行的话语仅在概率低于 `threshold - 0.15`（服务端 `stop_threshold`，可显式覆盖）时开始收尾。处于迟滞带（低于 entry、不低于 exit）的帧不会截断进行中的话语，也不会从静音新开话语。
- **server_vad 参数默认值**：`threshold=0.5`、`prefix_padding_ms=300`、`silence_duration_ms=400` 为 SpeechRail 本地默认。注意 `silence_duration_ms` 的 OpenAI 官方默认为 **500ms**：依赖平台默认端点时长的客户端应显式传参以获得确定行为。
- **ONNX 会话共享**：`InferenceSession` 按模型文件路径跨 WebSocket 连接共享（`Run()` 官方线程安全）；递归状态（v4 的 h/c，v5/v6 的合并 state + 64 采样上下文）按连接隔离并在 `reset`/`clear` 时清零。
- **shadow 观测**：`realtime_vad_shadow_enabled`（仅 legacy 主引擎可用）下 shadow 引擎逐帧打分仅用于观测对比，不改任何协议行为；指标 `speechrail_realtime_vad_shadow_frames_total{agreement=both_speech|both_silence|primary_only|shadow_only}` 按帧记录主引擎与 shadow 引擎相对 entry threshold 的判定一致性。`auto` 解析为 silero 主引擎时不启用 shadow。

## Diarization 扩展

本节为 opt-in 加法扩展：未协商的会话行为与本文件其余部分完全一致。运行时固定为
FluidAudio CoreML FP16 私有 worker；D1 已确认 runtime 选择，但真实质量、尾部和长期资源仍
需要独立验收。

### 协商

- 客户端在首个 PCM 前以 `session.update.session.speechrail.diarization.enabled=true` 开启。
  此对象只允许 boolean `enabled`；服务未就绪时只拒绝该请求，普通 ASR 会话保持可用。
- 协商成功后 `session.updated.session.speechrail.diarization` 回显
  `{enabled: true, version: 1, max_speakers: 4}`；未成功回显即未启用。
- 扩展只能在首个 PCM 前协商；已接受音频后的首次协商 → `invalid_state`，
  能力未广播时请求 → `unsupported_operation`。最多四名匿名说话人由固定模型约束。
- 不需要分人的客户端继续使用标准 Realtime 调用；需要分人的客户端只增加该 namespaced
  opt-in，并处理扩展事件。

### 扩展模式下的事件差异

- 所有模式下 `input_audio_buffer.committed`、`conversation.item.created`、partial、segment 与
  `conversation.item.input_audio_transcription.completed` / `failed` 都使用每次 commit 唯一的
  `item_id`。
- `completed` 新增 `audio_start_sample`/`audio_end_sample`（session-global 16 kHz
  整数样本域）与 `attribution_units`（`segment_uid`、`text_start`/`text_end`
  canonical 码点区间、`audio_start_sample`/`audio_end_sample`、`timing_quality`，
  `aligned | unavailable`）。单元完整分割 canonical text；空 transcript 为空数组；
  无法与固定正文一致对齐时整 item 使用一个 `timing_quality="unavailable"` 单元。
  这些字段在归属修订中不可变。
- 扩展模式**不发送** `.segment` speaker 事件，避免双写；未启用扩展的标准会话不受影响。
- `speechrail.diarization.updated`：服务端推送的归属修订事件，携带 `stable_through_sample`、
  `updates`（含 `segment_uid`、`revision` 从 1 严格递增、`status: tentative | stable | unknown`、
  `speaker`、`coverage_ratio`、`overlap_ratio`、`candidates`）以及会话级 `speaker_links` 声学建议；
  无法对齐或过期的单元直接归属为 `unknown`（`speaker: null`）。
- `speechrail.diarization.status`：发生不可恢复故障（如 `diarization_overloaded`、
  `diarization_invalid_output` 或 `finalization_timeout`）时触发单次 active→degraded 转换，
  先为未定态单元发送 `unknown` update，再发送本事件；此后正文正常交付，归属保持 `unknown`。
- 客户端 `speechrail.diarization.finish` 与服务端终态 `speechrail.diarization.done`：
  客户端推流完毕后发送 `{event_id}`；服务端进入 DRAINING 屏障，
  冲刷声学尾部并排空所有 pending updates，最后发送 done 事件（携带 `through_sample`、
  `stable_through_sample`、`status: complete | degraded` 与 `last_update_sequence`）。
  相同 `event_id` 重试幂等回显；不同 ID 请求拒绝返回 `invalid_state`；finish
  后追加音频返回 `invalid_state`。


## 普通 manual ASR：commit/clear 收口参考契约

这是一段逻辑录音的客户端收集规则，不新增服务端事件，也不改变普通 OpenAI 请求。
调用方必须使用**单一串行 writer**：先停止 append，再发送一次 commit，紧跟一次 clear。
在收到 cleared 前，不再发送新的 append/commit/clear；另一段录音不能共用这个关闭栅栏。
服务端 FIFO 会先处理前面接收的音频、自动 rollover、commit 和资源收尾，再确认 clear。

`cleared` 只证明处理顺序/清缓冲，**不是 ASR 成功回执**。成功结果同时要求：已观测到所有
committed item，所有 item 都收到 completed，没有相关 error/failed、序号缺口、断线或取消，
且最终收到本关闭窗口的 cleared。空缓冲的显式 commit 仍发出空的 committed/created/completed
闭环；空文本不能被替换成上一次结果或合成占位语。

参考消费者 `speechrail.realtime.turn_collection.ManualTurnCollector` 以 `(epoch, item_id)`
隔离会话，用 committed 到达顺序拼接终态文本，每个 item 仅记一次。不能依赖
`previous_item_id`（当前为 null），也不能按终态到达顺序或文本相同与否去重。
全部服务端事件，包括 session/conversation 事件，都交给收集器，以校验连续 sequence。
重连必须更新 epoch；同一连接开始另一段逻辑录音时应新建收集器并传入当前 `start_sequence`。
`max_events/max_items/max_text_chars` 是显式有限预算，超限失败，不静默丢弃前段转录。

确定性 wire 回归包含多次 rollover、末段提交、空输入、终态早于 backend commit ack、
append 失败后 clear；消费者回归还覆盖乱序终态、重复/冲突、旧 epoch、缺失 item、
取消和断线。它们不证明模型是否读对、样本级音频确认或真实延迟。

## 请求内 TTS planner

REST、Realtime 和 preview 继续共用 Qwen worker 的有界规划边界。worker 先执行既有
`normalize_tts_text`，再通过不可变 `TtsTextPlanner`（`tts_bounded_v1`，240 Unicode
codepoints/chunk）生成声学输入；没有将 Realtime 改成增量文本摄入。每个内部 chunk
记录规范化文本的半开区间、边界类型和 spoken text。其坐标不等于 HTTP 原文、UTF-8
字节、UTF-16 单元或音频时间；原文到规范化文本的映射由独立的词典/规范化契约负责。

该版本保持既有逐 chunk 模型调用和波形平滑，不添加跨请求 decoder/KV 共享、不插入
额外静音，也不声称已适配原生跨句 context。`suggested_pause_ms=null` 表示未提供建议，
不是测得零停顿。`/v1/speechrail/capabilities.operations.tts_text_planner` 公布策略版本；策略
变更会使目录 revision 失效。内部 `summary()` 可提供低基数版本/数量摘要，但尚未
增加 TTS 完成回执、网络事件或新的指标。协议 chunk 不等于网络 audio delta。

文本守恒只针对进入 planner 的规范化文本；旧的 Markdown 清理、末尾标点补齐仍发生在
它之前。本版本不凭构造测试宣称原始文本语义、发音准确率、自然度或 TTFA/RTF 已验收。
