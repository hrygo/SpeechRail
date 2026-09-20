# SpeechRail Realtime current-only 契约

> 生效日期：2026-09-20。当前版本是一次直接切换：SpeechRail 没有外部用户，因此不提供旧事件、旧字段、旧 wire profile、旧 alias 或 `/v2` 兼容层。旧设计只在 `docs/archive/` 与历史审计中保留，不构成当前承诺。

## 1. 定位与责任边界

`WS /v1/realtime` 是无状态 Speech Plane。它只负责：

- 16 kHz mono PCM16 音频接收、VAD/endpointing 事实、ASR partial/final；
- 可选的 session-scoped 匿名分人事实；
- 调用方显式提交文本后的无状态 TTS 流式渲染；
- 资源准入、worker 生命周期、稳定错误 envelope 和可选渲染回执。

调用方负责麦克风、播放、AEC、回声抑制、LLM、prompt/persona、对话历史、memory、tool calling、业务状态、sentence queue、barge-in 决策和最终用户体验。服务端不创建 conversation，不保存跨请求历史，不执行 LLM，不执行工具，不播放音频。

## 2. 连接、认证与音频

```text
ws://127.0.0.1:8201/v1/realtime
```

- 配置 `SPEECHRAIL_API_KEY` 后，握手必须使用 `Authorization: Bearer <key>`；query 参数不得携带 key。
- 默认只绑定 loopback；非 loopback 暴露必须同时配置 API key 和明确的 origin 策略。
- 每个连接拥有独立 session、sequence 和临时 item/response ID；断线即丢弃，不支持恢复或重放。
- 连接建立后服务端只发送一个 `session.created`，不会发送 conversation 容器事件。
- 输入事件只接受 JSON 文本；`input_audio_buffer.append.audio` 是 Base64 的 mono PCM16，采样率固定为 16 kHz。输入格式一旦有音频后不可变更。
- `?model=` 只选择本次连接的 ASR profile；未登记模型返回 `model_not_found` 并关闭连接。`/v1/models` 与握手中的模型 alias 是模型发现/选择语义，不是旧 wire 兼容层。

## 3. 客户端事件

### 3.1 `transcription_session.update`

唯一的会话更新事件。配置位于 `session` 对象内，缺失字段保留当前值，候选配置校验通过后原子生效。

```json
{
  "type": "transcription_session.update",
  "session": {
    "type": "transcription",
    "input_audio_format": "pcm16",
    "input_audio_transcription": {
      "model": "speechrail/qwen3-asr-1.7b",
      "language": "zh",
      "prompt": "可选，最多 2000 字符",
      "keywords": ["SpeechRail"],
      "timestamp_granularities": ["segment", "word"]
    },
    "turn_detection": {
      "type": "server_vad",
      "threshold": 0.5,
      "prefix_padding_ms": 300,
      "silence_duration_ms": 400
    },
    "speechrail": {
      "tts": {"enabled": true},
      "diarization": {"enabled": true},
      "render_receipts": {"enabled": true},
      "model_revision": {"expected": "<40-char-hex>"}
    }
  }
}
```

支持的字段：

| 字段 | 规则 |
|---|---|
| `type` | 仅 `transcription` 或省略；其他值 `invalid_event` |
| `input_audio_format` | 仅 `pcm16` |
| `input_audio_transcription.model` | 当前已登记 ASR model；未知值 `model_not_found` |
| `language` / `languages` | 传给 ASR；不支持时 `language_not_supported` |
| `prompt` | 最多 2000 字符；超限 `prompt_too_long` |
| `keywords` | 有界字符串数组，作为 hotword prompt 输入 |
| `timestamp_granularities` | ASR 原生 timestamp 请求；不依赖 aligner |
| `turn_detection` | `null`、`"manual"` 或 `{"type":"server_vad", ...}` |
| `speechrail.tts.enabled` | 调用方显式开启无状态 TTS；未开启时 `speechrail.tts.create` 返回 `tts_not_enabled` |
| `speechrail.diarization.enabled` | 首个 PCM 前 opt-in；按档位能力返回 `diarization_not_available` |
| `speechrail.render_receipts.enabled` | 首个 TTS 前协商；只返回摘要，不返回音频/文本 |
| `speechrail.model_revision.expected` | 可选 40 位小写 hex；TTS 绑定不匹配返回 `model_revision_conflict` |

不接受 `model`、`language`、`voice`、`modalities`、`tools`、`output_audio_format` 等旧的根级或 LLM 会话字段；服务端没有对应语义，不做 accept-but-no-op。

### 3.2 输入音频事件

| 事件 | 规则 |
|---|---|
| `input_audio_buffer.append` | 追加 Base64 PCM16。服务端可能发 `speech_started`/`speech_stopped` 事实；server VAD 不自动取消 TTS。 |
| `input_audio_buffer.commit` | 结束当前输入 turn。先发 `input_audio_buffer.committed`，再发 `conversation.item.created`、partial、`completed`/`failed`。空 turn 也返回确定性空闭环。 |
| `input_audio_buffer.clear` | 清空未提交音频与 VAD/ASR turn 状态，返回 `input_audio_buffer.cleared`。 |
| `speechrail.diarization.finish` | 录音结束屏障；携带 `event_id`，等待 `speechrail.diarization.done`。 |

### 3.3 调用方 TTS 事件

服务端不从 ASR 文本、不从 conversation item、不从 LLM 推断 TTS。调用方将已决定播放的句子显式提交：

```json
{
  "type": "speechrail.tts.create",
  "request_id": "caller-turn-42-sentence-03",
  "text": "这是调用方决定播放的句子。",
  "voice": "serena",
  "speed": 1.0,
  "expected_voice_revision": "vr_..."
}
```

- `request_id` 必填、连接内唯一；服务端只保留有界的 opaque ID ledger，不保留请求历史。
- `text` 最多 4096 字符；`speed` 范围 `0.25..4.0`；voice/revision/model 必须匹配当前能力。
- 同一连接同时只允许一个 TTS render。完成或取消后，调用方可以提交下一个 request。
- `speechrail.tts.cancel` 是唯一的 TTS 取消命令：

```json
{
  "type": "speechrail.tts.cancel",
  "request_id": "caller-turn-42-sentence-03",
  "response_id": "resp_..."
}
```

取消必须匹配当前 request（可选匹配 response）；服务端在取消时发一次 `response.done`，`status` 为 `cancelled`。没有活动 response 时返回 `tts_not_active`。调用方自己决定何时因 VAD、用户按键或业务状态调用 cancel。

## 4. 服务端事件

所有事件带连接内唯一的 `event_id`、`session_id` 和单调 `sequence`。

| 事件 | 语义 |
|---|---|
| `session.created` | 唯一握手事件；声明 `type=transcription`、`input_audio_format=pcm16`、ASR/ speech 能力和当前 `speechrail.tts.enabled=false`。 |
| `transcription_session.updated` | 确认 current-only session 配置和能力；包含 TTS、diarization、receipt、model revision 的实际状态。 |
| `input_audio_buffer.speech_started/stopped` | VAD 事实；不携带播放控制，不触发服务端 barge-in。 |
| `input_audio_buffer.committed/cleared` | 输入缓冲状态。 |
| `conversation.item.created` | ASR 输入 item 的临时容器事件；它不是可查询 conversation，也不能作为 TTS 输入。 |
| `conversation.item.input_audio_transcription.delta` | 只发送可追加的稳定 partial 前缀。 |
| `conversation.item.input_audio_transcription.segment` | ASR 已提供且已验证的 segment；分人信息通过 SpeechRail namespace 交付。 |
| `conversation.item.input_audio_transcription.completed/failed` | ASR turn 终态；completed 的 transcript 是唯一冻结正文。 |
| `speechrail.diarization.updated/status/done` | session-scoped 匿名分人增量、降级通知和最终屏障。 |
| `response.created` | TTS render 开始，包含 `response.id`。 |
| `response.output_item.added/done` | TTS message/audio item 生命周期。 |
| `response.content_part.added/done` | 音频 content part 生命周期。 |
| `response.output_audio_transcript.delta/done` | 对已提交 TTS 文本的回显，不是 ASR 结果。 |
| `response.output_audio.delta/done` | 统一的当前 TTS PCM16 Base64 音频流。 |
| `response.done` | TTS 终态：`completed`、`failed` 或 `cancelled`；包含 caller `request_id` 和 `speechrail.kind=tts`。 |
| `error` | 稳定错误 envelope，含 `request_id` 时回显触发事件 ID。 |

TTS 的正常序列是：

```text
response.created
→ response.output_item.added
→ response.content_part.added
→ response.output_audio_transcript.delta*
→ response.output_audio.delta*
→ response.output_audio_transcript.done
→ response.output_audio.done
→ response.content_part.done
→ response.output_item.done
→ response.done(status=completed)
```

取消/失败仍以一次 `response.done` 结束；已发送音频不会回滚，调用方负责停止播放并丢弃本地播放队列。

## 5. VAD、barge-in 与调用方编排

`server_vad` 只负责产生 speech start/stop 事实、端点提交和 ASR 资源准入。SpeechRail 不拥有播放状态，因此不会因为 `speech_started` 自动取消 TTS，也不会自行发送下一段 TTS。调用方应实现：

1. 接收 `speech_started`，按自己的播放/回声策略判断是否打断；
2. 若需要打断，发送匹配的 `speechrail.tts.cancel`；
3. 丢弃尚未送入扬声器的本地音频队列；
4. 依据 `completed` transcript 调用自己的 LLM/工具，并将新句子逐一提交 `speechrail.tts.create`。

这使 Native、Sona、会议助手和其他 Agent 可以共享 SpeechRail，而不把业务状态塞进服务端。

## 6. 错误与明确拒绝

```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "code": "unsupported_operation",
    "message": "response.create is not supported by SpeechRail",
    "event_id": "evt_..."
  }
}
```

主要错误码：`invalid_event`、`unsupported_operation`、`model_not_found`、`invalid_audio`、`unsupported_audio_format`、`language_not_supported`、`prompt_too_long`、`backend_busy`、`backend_timeout`、`backend_not_ready`、`tts_not_enabled`、`tts_request_invalid`、`tts_in_progress`、`tts_not_active`、`voice_not_found`、`voice_not_available`、`voice_revision_conflict`、`model_revision_conflict`、`diarization_not_available`、`invalid_state`。

以下事件和字段是明确拒绝项，不会翻译为当前事件：`session.update`、`session.updated`、`conversation.created`、`conversation.item.create`、`conversation.item.delete`、`conversation.item.truncate`、`response.create`、`response.cancel`、`response.audio.*`、`response.audio_transcript.*`、旧根级 `model`/`language`/`audio_format`、LLM `tools`/`modalities`/`instructions`。

## 7. 隐私、资源与实现边界

- PCM、Base64、完整 prompt、完整 transcript、embedding、实名 speaker 和绝对模型路径不得进入普通日志、fixture 或报告。
- 一个 SpeechRail 服务、一个 ASGI worker；ASR/TTS/diarization 的资源准入和 worker lane 由服务端负责，但不改变无状态应用语义。
- 分人只输出当前 session 的匿名 label；不保存声纹、embedding、跨会话身份或原始 PCM。
- MCP 是无状态 REST proxy，使用 `describe/transcribe/synthesize/voice/job` 工具；它不持有或转发 `/v1/realtime` WebSocket handle。Realtime 调用方必须直连 WebSocket。

权威实现与测试：`src/speechrail/compatibility/openai_realtime.py`、`src/speechrail/application/realtime_openai.py`、`tests/test_realtime_openai.py`、`tests/test_realtime_caller_wire.py`。任何公共变更必须同时更新本契约、用户接入文档和回归测试。
