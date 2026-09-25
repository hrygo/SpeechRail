# SpeechRail Realtime current-only 契约

> 契约版本：`3.1.0`；生效日期：2026-09-25。当前版本是一次直接切换：SpeechRail 没有外部用户，因此不提供旧事件、旧字段、旧 wire profile、旧 alias 或 `/v2` 兼容层。旧设计只在 `docs/archive/` 与历史审计中保留，不构成当前承诺。

## 1. 定位与责任边界

`WS /v1/realtime` 是无状态 Speech Plane。它只负责：

- 16 kHz mono PCM16 音频接收、VAD/endpointing 事实、ASR partial/final；
- 可选的 session-scoped 匿名分人事实；
- 调用方显式提交文本后的无状态 TTS 流式渲染，以及调用方持续追加文本的增量 TTS utterance；
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
      "timestamp_granularities": ["segment"]
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
      "model_revision": {"expected": "<40-char-hex>"},
      "transcription": {"partial_mode": "snapshot", "chunk_duration_ms": 500}
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
| `timestamp_granularities` | 当前仅支持 `segment`；由 streaming worker 生成并校验 segment 时间戳。`word` 明确返回 `unsupported_operation`，不会静默忽略 |
| `turn_detection` | `null`、`"manual"` 或 `{"type":"server_vad", ...}` |
| `speechrail.tts.enabled` | 调用方显式开启无状态 TTS；未开启时 `speechrail.tts.create` 返回 `tts_not_enabled` |
| `speechrail.diarization.enabled` | 首个 PCM 前 opt-in；按档位能力返回 `diarization_not_available` |
| `speechrail.render_receipts.enabled` | 首个 TTS 前协商；只返回摘要，不返回音频/文本 |
| `speechrail.model_revision.expected` | 可选 40 位小写 hex；TTS 绑定不匹配返回 `model_revision_conflict` |
| `speechrail.transcription.partial_mode` | `delta`（默认）或 `snapshot`；`snapshot` 允许提词器接收可修订的最新全文。 |
| `speechrail.transcription.chunk_duration_ms` | 会话级识别分块，仅允许 `500`、`1000`、`2000`；必须在首个 PCM 前设置，默认 `2000`。 |

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

- `request_id` 必填、连接内唯一；服务端只保留最多 256 个 opaque ID。账本满后拒绝新的 request，避免淘汰旧 ID 造成重复请求重新有效；不保留请求历史。
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

#### 3.3.1 增量 TTS utterance

增量模式让调用方把 LLM 的流式文本持续追加到**同一个生成状态**，从而在保持跨句韵律的同时获得低首音延迟。它与 `speechrail.tts.create` 互斥：两者共享同一个「连接内只允许一个活动 TTS」判定和同一个 `request_id` 账本，因此 `create` 与 `start` 的拒绝顺序一致（先 `tts_in_progress`，空闲时才报 `tts_request_invalid`）。

```json
{
  "type": "speechrail.tts.start",
  "request_id": "caller-turn-42",
  "voice": "serena",
  "speed": 1.0,
  "expected_voice_revision": "vr_...",
  "expected_model_revision": "<40-char-hex>",
  "limits": {"slow_consumer_seconds": 2.0}
}
```

```json
{
  "type": "speechrail.tts.append_text",
  "request_id": "caller-turn-42",
  "response_id": "resp_...",
  "sequence": 0,
  "text": "这是调用方已经稳定的一小段文本。"
}
```

```json
{
  "type": "speechrail.tts.finish_text",
  "request_id": "caller-turn-42",
  "response_id": "resp_...",
  "last_sequence": 0
}
```

| 事件 | 规则 |
|---|---|
| `speechrail.tts.start` | 绑定一个增量 utterance；已知字段仅 `request_id`、`voice`、`speed`、`expected_voice_revision`、`expected_model_revision`、`limits`。未知字段返回 `tts_request_invalid`。 |
| `speechrail.tts.append_text` | 追加不可修改文本；`sequence` 从 `0` 起且必须严格连续递增，重复或跳号返回 `tts_sequence_invalid` 且不消费文本。 |
| `speechrail.tts.finish_text` | 关闭文本输入并继续生成尾音；`last_sequence` 必须等于最后一次 ACK 的 `append_sequence`，空输入为 `-1`。重复 finish 或 finish 后 append 返回 `tts_input_closed`。 |
| `speechrail.tts.cancel` | 与完整文本模式相同的取消命令；取消后不再投递旧音频。 |

规则：

- `start` 通过校验后才创建 response；失败发生在 `response.created` 之前时只发 `error`，不伪造 `response.done`。`response.created` 之后任何失败都收敛为一次 `failed` 终态。
- `start` 成功即异步建立生成状态，服务端不会因为等待整轮文本而阻塞后续 `append_text`；客户端必须等到 `speechrail.tts.started` 才追加文本。
- 每一段提交文本计入 Unicode codepoint 预算：单次 append、utterance 总量、待模型消费队列各有上限；文本与音频队列分别计量。超限返回 `tts_stream_limit_exceeded`，队列背压返回 `tts_backpressure`。
- 请求可以收紧 `limits`（只能小于等于服务端默认值），放宽返回 `tts_stream_limit_exceeded`。生效值在 `speechrail.tts.started.limits` 中回显。
- 增量能力按 voice 解析，不是全档统一开关：`voice_design`（VoiceDesign instruction 音色）当前明确不支持增量，必须先在服务端注册固定音色 clone 再使用；`custom_voice` 与 `base` clone 支持。详见 §4 的能力协商。

## 4. 服务端事件

所有事件带连接内唯一的 `event_id`、`session_id` 和单调 `sequence`。

| 事件 | 语义 |
|---|---|
| `session.created` | 唯一握手事件；声明 `type=transcription`、`input_audio_format=pcm16`、ASR/ speech 能力和当前 `speechrail.tts.enabled=false`。 |
| `transcription_session.updated` | 确认 current-only session 配置和能力；包含 TTS、diarization、receipt、model revision 及 transcription 选项的实际状态。 |
| `input_audio_buffer.speech_started/stopped` | VAD 事实；不携带播放控制，不触发服务端 barge-in。 |
| `input_audio_buffer.committed/cleared` | 输入缓冲状态。 |
| `conversation.item.created` | ASR 输入 item 的临时容器事件；它不是可查询 conversation，也不能作为 TTS 输入。 |
| `conversation.item.input_audio_transcription.delta` | 只发送可追加的稳定 partial 前缀。 |
| `speechrail.transcription.snapshot` | 提词器 opt-in 的可修订 partial 最新全文；同一 item 的 `revision` 严格递增，调用方替换 `text`，不得追加。 |
| `conversation.item.input_audio_transcription.segment` | ASR 已提供且已验证的 segment；分人信息通过 SpeechRail namespace 交付。 |
| `conversation.item.input_audio_transcription.completed/failed` | ASR turn 终态；completed 的 transcript 是唯一冻结正文。 |
| `speechrail.diarization.updated/status/done` | session-scoped 匿名分人增量、降级通知和最终屏障。 |
| `response.created` | TTS render 开始，包含 `response.id`。 |
| `response.output_item.added/done` | TTS message/audio item 生命周期。 |
| `response.content_part.added/done` | 音频 content part 生命周期。 |
| `response.output_audio_transcript.delta/done` | 对已提交 TTS 文本的回显，不是 ASR 结果。 |
| `response.output_audio.delta/done` | 统一的当前 TTS PCM16 Base64 音频流。增量 utterance 的每个 delta 额外携带 `speechrail.{kind:"tts",chunk_index,sample_offset,sample_rate,channels}`，`sample_offset` 以 mono 样本计（`+= len(pcm)//2`）。音频事件不会被拆成第二条通道。 |
| `speechrail.tts.started` | 增量 utterance 已取得准入并开始生成；携带 `protocol_version`、`implementation_version`、`voice_variant`、`voice_mode`、`output_format` 和生效 `limits`。客户端在此之前不得追加文本，服务端在此之前不得发送 PCM。 |
| `speechrail.tts.text_accepted` | 确认一次 append：携带 `append_sequence`、`accepted_codepoints` 和累计 `total_codepoints`。ACK 失败不推进 `append_sequence`。注意 `append_sequence` 是调用方的追加序号，与所有事件都有的传输层 `sequence` 不是同一字段。 |
| `response.done` | TTS 终态：`completed`、`failed` 或 `cancelled`；包含 caller `request_id` 和 `speechrail.kind=tts`。 |
| `error` | 稳定错误 envelope；请求级错误在 `error.request_id` 回显触发请求 ID，事件级错误在 `error.event_id` 回显客户端事件 ID。 |

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

增量 utterance 的正常序列是：

```text
response.created
→ response.output_item.added
→ response.content_part.added
→ speechrail.tts.started
→ (speechrail.tts.text_accepted → response.output_audio_transcript.delta)*
→ response.output_audio.delta*
→ response.output_audio_transcript.done
→ response.output_audio.done
→ response.content_part.done
→ response.output_item.done
→ response.done(status=completed)
```

音频与 append 的交错顺序由模型实际生成速度决定，服务端不保证「先收完文本再出声」。取消/失败仍以一次 `response.done` 结束；已发送音频不会回滚，调用方负责停止播放并丢弃本地播放队列。失败时先发一次 `error`（携带稳定错误码），再发一次 `response.done(status=failed)`；`error` 本身不是终态。

### 4.1 增量能力协商

`session.created` 与 `transcription_session.updated` 的 `session.speech_capabilities.streaming_tts` 按当前 voice 解析增量能力，各轴独立，不做「模型支持就等于所有 voice 支持」的推断：

```json
{
  "supported": true,
  "reason": null,
  "hint": null,
  "protocol_version": 1,
  "implementation_version": "qwen3-tts-incremental-v1",
  "voice_mode": "system",
  "voice_variant": "custom_voice",
  "limits": {"max_append_codepoints": 512, "max_total_codepoints": 4096},
  "axes": {
    "variant_supported": true,
    "artifact_available": true,
    "profile_enabled": true,
    "reference_ready": true,
    "implementation_supported": true,
    "protocol_negotiated": true,
    "ready": true,
    "budget_available": true
  }
}
```

- `supported` 是 `axes` 中除 `budget_available` 外的合取；`ready` 是同一判定在当前 `tts_ready` 下的瞬时结果。
- `budget_available` 只是瞬时预算信号，不参与 `supported`，避免「暂时忙」被误报为「不支持」。
- `supported=false` 时 `reason` 为 `voice_disabled`、`backend_not_ready`、`artifact_unavailable`、`variant_not_supported`、`reference_not_ready` 或 `implementation_not_negotiated`，`hint` 给出下一步动作。
- `/v1/voices[].streaming` 使用同一 resolver，`/v1/models[].capabilities.streaming_input` 只声明 `scope="per_voice"` 与实现轴，不声称覆盖全部 voice。

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

增量 TTS 追加错误码：`tts_streaming_unsupported`（当前 voice/实现/档位没有增量路径，fail closed，不静默降级为等待全文）、`tts_sequence_invalid`、`tts_input_closed`、`tts_input_timeout`、`tts_stream_limit_exceeded`、`tts_backpressure`、`tts_backend_failed`。可恢复的错序/错字段不消费输入；超限、输入饥饿超时、慢消费者和后端失败终止当前 response。

以下事件和字段是明确拒绝项，不会翻译为当前事件：`session.update`、`session.updated`、`conversation.created`、`conversation.item.create`、`conversation.item.delete`、`conversation.item.truncate`、`response.create`、`response.cancel`、`response.audio.*`、`response.audio_transcript.*`、旧根级 `model`/`language`/`audio_format`、LLM `tools`/`modalities`/`instructions`。

## 7. 隐私、资源与实现边界

- PCM、Base64、完整 prompt、完整 transcript、embedding、实名 speaker 和绝对模型路径不得进入普通日志、fixture 或报告。
- 一个 SpeechRail 服务、一个 ASGI worker；ASR/TTS/diarization 的资源准入和 worker lane 由服务端负责，但不改变无状态应用语义。
- 分人只输出当前 session 的匿名 label；不保存声纹、embedding、跨会话身份或原始 PCM。
- MCP 是无状态 REST proxy，使用 `describe/transcribe/synthesize/voice/job` 工具；它不持有或转发 `/v1/realtime` WebSocket handle。Realtime 调用方必须直连 WebSocket。

权威实现与测试：`src/speechrail/compatibility/openai_realtime.py`、`src/speechrail/application/realtime_openai.py`、`tests/test_realtime_openai.py`、`tests/test_realtime_caller_wire.py`。任何公共变更必须同时更新本契约、用户接入文档和回归测试。
