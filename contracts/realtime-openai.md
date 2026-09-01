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
- `?model=` 查询参数与 `session.update.session.model` 同样生效，归一化到 SpeechRail
  canonical profile：
  - `speechrail/qwen3-asr-1.7b`（canonical）
  - `whisper-1`、`gpt-4o-transcribe`、`gpt-4o-mini-transcribe` → ASR 兼容 alias
  - `speechrail/qwen3-tts`（canonical，需 TTS backend ready）
  - 未登记模型返回 `model_not_found`。

## 支持的客户端事件

| 事件 | 语义 |
|---|---|
| `session.update` | 更新 session 配置；仅接受 ASR/TTS 允许字段。`turn_detection` 只支持 `null`/`manual`（`server_vad`/`semantic_vad` → `unsupported_turn_detection`）；`tools` 非空 → `unsupported_tools`；`modalities` 仅 `text`/`audio`。返回 `session.updated` |
| `input_audio_buffer.append` | 追加 base64 PCM16；返回 `input_audio_buffer.committed` 只在 commit 时 |
| `input_audio_buffer.commit` | 触发流式转写终态；发送 `input_audio_buffer.committed` + `conversation.item.created` + `conversation.item.input_audio_transcription.completed`/`failed` |
| `input_audio_buffer.clear` | 丢弃未提交缓冲；返回 `input_audio_buffer.cleared` |
| `conversation.item.create` | 仅接受单个 `role=user` 的 `input_text` 内容，作为 TTS 输入（需 TTS ready） |
| `response.cancel` | 取消进行中的 TTS response |

以下客户端事件被拒绝（`unsupported_operation`）：`conversation.item.delete`、
`conversation.item.truncate`、`response.create`（除非通过
`conversation.item.create` 文本项驱动 TTS）。

## 服务端事件

| 事件 | 说明 |
|---|---|
| `session.created` | 连接建立后立即发送；声明实际能力（modalities、16 kHz PCM16、`turn_detection: null`）与 `capabilities` 列表 |
| `conversation.created` | 会话容器；SpeechRail 不实现可查询/可编辑的消息历史 |
| `session.updated` | `session.update` 的确认 |
| `input_audio_buffer.committed` / `cleared` | 缓冲状态变化 |
| `conversation.item.created` | 每次 committed 输入创建临时 item（item ID 仅当前 WebSocket 会话有效） |
| `conversation.item.input_audio_transcription.completed` / `failed` | ASR 终态；`completed` 在 commit 后必然发送 |
| `response.created` / `response.output_item.added` | TTS response 开始 |
| `response.output_audio.delta` / `done` | TTS 音频块（base64）；输出为 24 kHz PCM16 |
| `response.output_audio_transcript.done` | TTS 输入文本回显；不代表 ASR 结果 |
| `response.done` | TTS response 终态 |
| `error` | 统一错误 envelope：`{"type": "error", "error": {"type": "invalid_request_error", "code": "...", "message": "..."}}` |

## 转写语义

`conversation.item.input_audio_transcription.delta`（partial）仅在 native 流式后端
可靠产出 partial 时发送；windowed 后端的手动 flush 可能无 delta，客户端必须依赖
`commit` 后的 `completed` 作为最终结果，这与 OpenAI 的 manual turn detection 语义一致。