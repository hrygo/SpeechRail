# SpeechRail Realtime WebSocket 契约

本文件只描述当前已实现的 v1。已审查但尚未实现的目标协议见
[Realtime v2 设计契约](realtime-v2.md)；客户端不得在 v2 上线前依赖该设计契约。

`WS /v1/realtime` 是面向新客户端的 PCM 转写协议。事件名称参考 OpenAI Realtime
transcription，但本版本的语义是“收集音频后一次 batch 转写”，不是持续 partial streaming。

## 连接与认证

```text
ws://127.0.0.1:8201/v1/realtime
```

若配置了 API key，握手必须携带 `Authorization: Bearer <key>`。仅接受 JSON 文本事件；
音频放在 Base64 字段中，格式固定为 16 kHz、单声道、16-bit little-endian PCM。

## 客户端顺序

```text
连接
  → transcription_session.update
  → 0..N × input_audio_buffer.append
  → input_audio_buffer.commit
  → completed
  → 连接结束
```

`transcription_session.update` 示例：

```json
{
  "type": "transcription_session.update",
  "session": {
    "language": "zh",
    "model": "speechrail/qwen3-asr-1.7b",
    "prompt": "产品名：SpeechRail",
    "audio_format": {
      "type": "audio/pcm",
      "rate": 16000,
      "channels": 1,
      "sample_width": 2
    }
  }
}
```

`input_audio_buffer.append`：

```json
{
  "type": "input_audio_buffer.append",
  "audio": "<base64-s16le-pcm>"
}
```

`input_audio_buffer.commit`：

```json
{ "type": "input_audio_buffer.commit" }
```

会话不允许在 commit 后继续 append 或第二次 commit。单帧/累计缓冲受
`SPEECHRAIL_MAX_REALTIME_FRAME_BYTES` 与 `SPEECHRAIL_MAX_REALTIME_BUFFER_BYTES` 限制。

## 服务端事件

连接成功后先返回：

```json
{
  "type": "transcription_session.created",
  "session": { "id": "sess_...", "model": "speechrail/qwen3-asr-1.7b" }
}
```

一次成功的 commit 返回最终事件：

```json
{
  "type": "conversation.item.input_audio_transcription.completed",
  "event_id": "evt_...",
  "session_id": "sess_...",
  "item_id": "item_...",
  "transcript": "最终转写文本",
  "language": "Chinese",
  "segments": []
}
```

当前实现**不会**产生 `conversation.item.input_audio_transcription.delta`。客户端必须把
completed 当作唯一转写结果，不得把此接口用于要求低延迟 partial 的字幕场景。

非法事件/顺序会得到 `type: error` 并以 1008 关闭。worker/队列错误的处理仍受服务版本
限制；调用方应将连接断开或失败视为可重建会话的条件，并且不假定服务会保留或重放音频。

## legacy `/asr`

`WS /asr` 仅用于 loopback 开发和未来迁移准备。当前行为为：连接后发送
`{ "type": "config", "mode": "full" }`；客户端发送空二进制帧后，服务发送
`{ "type": "ready_to_stop" }`。非空 PCM 当前不会产生转写或 WLK `lines` /
`buffer_transcription`。

因此它不具备 `voice-realtime` 替换资格，也未实现认证。新客户端必须使用
`/v1/realtime` 或 REST。
