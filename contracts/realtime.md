# SpeechRail Realtime WebSocket 契约

`WS /v1/realtime` 是新客户端的实时转写协议，事件命名对齐 OpenAI Realtime
transcription。它只承诺 ASR，不承诺对话、TTS 或模型响应链。

参考：[OpenAI Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)。

## 连接

```text
ws://127.0.0.1:8201/v1/realtime
```

生产或 LAN 模式必须在握手中携带：

```http
Authorization: Bearer <SPEECHRAIL_API_KEY>
```

服务端默认要求音频为 16 kHz、单声道、PCM16 little-endian。客户端应在本地完成
采样率和声道转换；服务端不会把不明格式的二进制帧静默当成有效音频。

## 客户端事件

### `transcription_session.update`

```json
{
  "type": "transcription_session.update",
  "session": {
    "language": "zh",
    "model": "speechrail/qwen3-asr-1.7b",
    "prompt": "SpeechRail、QwenPaw",
    "audio_format": {
      "type": "audio/pcm",
      "rate": 16000,
      "channels": 1,
      "sample_width": 2
    }
  }
}
```

`session` 只在连接建立后更新一次或少量更新；会话中不得切换模型 runtime。切换由
服务端冷切换流程在空闲状态完成。

### `input_audio_buffer.append`

```json
{
  "type": "input_audio_buffer.append",
  "audio": "<base64-encoded-s16le-pcm>"
}
```

每个事件建议携带 100–500 ms 音频。服务端对单事件、单连接和总时长都设置上限，
超限返回 `audio_too_large` 或 `queue_full`。

### `input_audio_buffer.commit`

```json
{
  "type": "input_audio_buffer.commit"
}
```

commit 后服务端冲刷尾部窗口，并在完成后发送 `conversation.item.input_audio_transcription.completed`。
客户端不需要发送空 PCM；空 PCM 只属于 legacy `/asr`。

## 服务端事件

### `transcription_session.created`

```json
{
  "type": "transcription_session.created",
  "session": {
    "id": "sess_01J...",
    "model": "speechrail/qwen3-asr-1.7b",
    "language": "zh",
    "audio_format": {
      "type": "audio/pcm",
      "rate": 16000,
      "channels": 1,
      "sample_width": 2
    }
  }
}
```

### `conversation.item.input_audio_transcription.delta`

```json
{
  "type": "conversation.item.input_audio_transcription.delta",
  "event_id": "evt_01J...",
  "session_id": "sess_01J...",
  "item_id": "item_01J...",
  "delta": "正在识别的尾部文本"
}
```

delta 是易失 partial，后续 delta 可以覆盖上一条 partial；客户端不应把每条 delta
当作独立最终句子。

### `conversation.item.input_audio_transcription.completed`

```json
{
  "type": "conversation.item.input_audio_transcription.completed",
  "event_id": "evt_01J...",
  "session_id": "sess_01J...",
  "item_id": "item_01J...",
  "transcript": "这是完整的最终转写。",
  "language": "zh",
  "segments": [
    {
      "id": "seg_0001",
      "start": 0.0,
      "end": 2.4,
      "text": "这是完整的最终转写。"
    }
  ]
}
```

### `error`

```json
{
  "type": "error",
  "event_id": "evt_01J...",
  "error": {
    "type": "server_error",
    "code": "backend_not_ready",
    "message": "SpeechRail inference backend is not ready",
    "retryable": true,
    "request_id": "req_01J..."
  }
}
```

## 事件顺序

```text
transcription_session.created
  → 0..N × delta
  → input_audio_buffer.commit
  → 0..N × delta
  → completed
```

连接异常或服务过载时可以没有 completed；客户端应使用 `error.retryable` 和自身
session 状态决定是否重连。服务端不保证断线后的音频自动重放。

## legacy `/asr` 兼容契约

`WS /asr?language=Chinese&mode=full` 保留当前 `voice-realtime` 行为：

1. 服务端先发送 `{ "type": "config", "mode": "full" }`。
2. 客户端发送裸二进制 `s16le/16kHz/mono` PCM。
3. 服务端发送 WLK full snapshot：`lines` + `buffer_transcription`。
4. 客户端发送空二进制帧作为 EOF。
5. 服务端发送 `{ "type": "ready_to_stop" }`。

该路径会由 `compatibility/wlk.py` 重建旧字段。核心领域事件不允许向外泄露 WLK
原始 JSON；这样未来可以替换 WLK 而不改变 REST/Realtime API。

legacy 允许 `?token=` 只为历史客户端服务；新客户端必须使用握手 Authorization。
