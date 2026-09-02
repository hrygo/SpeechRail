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
  canonical profile；`gpt-4o-transcribe-diarize` 仅在 diarization profile 可用时出现。

## 支持的客户端事件

| 事件 | 语义 |
|---|---|
| `session.update` | 更新 session 配置；仅接受 ASR/TTS 允许字段。`turn_detection` 支持 `null`/`manual` 以及 `{"type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 400}`；`tools` 非空 → `unsupported_tools`；`modalities` 仅 `text`/`audio`；`input_audio_format`/`output_audio_format` 仅 `pcm16`；支持 `input_audio_transcription.language`、`languages`、`prompt`（≤2000 字符，超限 → `prompt_too_long`）、`keywords`（动态热词注入）、`timestamp_granularities`、`known_speaker_names`、`known_speaker_references` 和可选 `diarization`。`instructions`、`temperature`、`max_response_output_tokens`、`tool_choice` 接受但**无效果**（本服务器不承载 LLM，无对应语义通道；拒绝会伤害按标准发完整载荷的客户端）；`voice` 接受 4 个服务端 preset（`default`/`warm`/`bright`/`calm`）与 13 个 OpenAI 标准 voice 别名（归一化到最近 preset，与 REST 同规则）并驱动 TTS 合成；配置入口即校验：未知 voice → `voice_not_found`（快速失败，session 不损坏），非字符串或空白 → `invalid_voice`。返回 `session.updated` |
| `input_audio_buffer.append` | 追加 base64 PCM16；在启用 `server_vad` 时进行实时语音活动检测与防抖，并在检测到用户说话时触发当前会话内的 Barge-in 打断；返回 `input_audio_buffer.committed` 只在 commit 或 VAD 静音截断时；不支持语言或后端忙返回 `error`（`language_not_supported`/`backend_busy`），session 保持可用 |
| `input_audio_buffer.commit` | 触发流式转写终态；按序发送 `input_audio_buffer.committed` → `conversation.item.created` → `conversation.item.input_audio_transcription.delta`*（若后端产出 partial）→ `completed`/`failed`；`committed` 恒先于转写终态 |
| `input_audio_buffer.clear` | 丢弃未提交缓冲；重置 VAD 状态机，返回 `input_audio_buffer.cleared` |
| `conversation.item.create` | 接受单个 `role=user` 的 `input_text` 内容，创建文本 item（需 TTS ready）；随后必须发送 `response.create` 才触发合成 |
| `response.create` | 用最近一次 `conversation.item.create` 的文本触发 TTS 流式合成（使用 `StreamingSentenceSplitter` 分句合成并施加淡入淡出音频平滑）；无待处理文本 → `invalid_state`；`response.voice` 按与 `session.update.voice` 相同的别名/注册 preset 规则校验（`voice_not_found`/`invalid_voice`） |
| `response.cancel` | 取消进行中的 TTS response；丢弃未发送音频并返回 `response.done`（`status: cancelled`） |

以下客户端事件被拒绝（`unsupported_operation`）：`conversation.item.delete`、
`conversation.item.truncate`。

## 服务端事件

| 事件 | 说明 |
|---|---|
| `session.created` | 连接建立后立即发送；声明实际能力（modalities、`input_audio_format`/`output_audio_format: pcm16`、`turn_detection: null`）与 `capabilities` 列表 |
| `conversation.created` | 会话容器；SpeechRail 不实现可查询/可编辑的消息历史 |
| `session.updated` | `session.update` 的确认 |
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

`conversation.item.input_audio_transcription.delta`（partial）仅在 native 流式后端
可靠产出 partial 时发送；windowed 后端的手动 flush 可能无 delta，客户端必须依赖
`commit` 后的 `completed` 作为最终结果，这与 OpenAI 的 manual turn detection 语义一致。

`/v1/realtime` 是 SpeechRail 唯一的 Realtime 入口。此前的 SpeechRail-native `/v2/realtime`
已移除；客户端不得依赖私有 v2 事件或把 v2 作为隐式降级路径。
