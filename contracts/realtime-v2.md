# SpeechRail Realtime v2 设计契约

状态：**部分实现，尚未完成真实后端验收**。`/v2/realtime` 的 ASR/TTS session 状态机、
手动 PCM 提交、可选 WLK 连续 ASR、ordered audio delta、TTS response 取消和基础容量隔离已有
deterministic fake-backend 测试。没有已授权且通过 smoke 的本地流式 ASR/TTS worker 时，服务仍会返回
`backend_not_ready`；客户端正式切换和端口退役仍须另行授权。

`WS /v2/realtime` 只承载 ASR 与 TTS，不承载 LLM response、tool call、播放、会议状态或
应用打断策略。连接建立后，客户端必须用一次 `session.update` 选择
`transcription` 或 `speech`；两类会话共享握手、错误 envelope 和背压规则，但使用独立状态机。

## 1. 连接、认证与公共事件字段

- 默认地址为 `ws://127.0.0.1:8201/v2/realtime`。
- 配置 API key 时，握手必须携带 `Authorization: Bearer <key>`；长期 token 不进入 URL。
- 非 loopback 暴露还必须启用 TLS 终止、WebSocket `Origin` allowlist、HTTP CORS allowlist、
  网段策略和限速。CORS 配置不能替代 WebSocket `Origin` 校验。
- v2.0 session **不可恢复**。断线后客户端创建新连接和新 session；服务端不保存、不重放
  旧音频或事件。`sequence` 只用于单个 session 内的有序消费和去重。

每个服务端事件都包含：

```json
{
  "type": "event.type",
  "event_id": "evt_...",
  "session_id": "sess_...",
  "request_id": "req_...",
  "sequence": 1
}
```

`sequence` 从 1 开始并在一个 session 内严格递增。WebSocket 自身保证有序交付；客户端可
丢弃已经处理过的 sequence，但不得把它当作跨连接 replay offset。
下文事件片段为突出各自字段而省略公共 envelope；实际服务端事件仍必须携带全部公共字段。

错误事件使用稳定 envelope：

```json
{
  "type": "error",
  "event_id": "evt_...",
  "session_id": "sess_...",
  "request_id": "req_...",
  "sequence": 8,
  "error": {
    "code": "invalid_event_order",
    "message": "Event is not valid in the current session state",
    "retryable": false
  }
}
```

协议错误使用 1008 关闭；worker 暂不可用或服务过载使用 1013。服务端发送 terminal event
后可以正常关闭连接。

## 2. `transcription` 会话

### 2.1 配置与 endpointing

客户端首个事件：

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "model": "speechrail/qwen3-asr-1.7b",
    "language": "zh",
    "prompt": "产品名：SpeechRail",
    "audio_format": {
      "type": "audio/pcm",
      "rate": 16000,
      "channels": 1,
      "sample_width": 2
    },
    "endpointing": {
      "mode": "server_vad"
    }
  }
}
```

`endpointing.mode` 支持：

- `server_vad`：服务端拥有语句切分；检测到稳定边界时自动产生逐句 `transcription.completed`。
  这是会议和连续字幕的默认模式。
- `manual`：只有客户端发送 `input_audio_buffer.flush` 或 `commit` 才确认当前 item。

当前 WLK transport 保留自身连续识别语义：当并且仅当服务显式配置
`SPEECHRAIL_WLK_STREAMING_URL`，它会在 `append` 后把 WLK snapshot 归一化为本契约的 delta /
completed。未配置该 endpoint 时，受限 batch ASR 仅在 flush/commit 后产生 completed；它不是
server VAD 的等价实现。

服务端返回 `session.created`，回显实际 model、language、audio format、endpointing 和运行限制。
创建成功后才可 append PCM。

### 2.2 音频、partial 与逐句完成

客户端追加音频：

```json
{
  "type": "input_audio_buffer.append",
  "audio": "<base64-s16le-pcm>"
}
```

服务端可以发送累计接收确认：

```json
{
  "type": "input_audio_buffer.ack",
  "accepted_bytes": 64000,
  "buffered_bytes": 32000
}
```

`accepted_bytes` 在 session 内单调递增，用于背压诊断，不用于断线续传。

未确认文本是一个 item 的**可替换快照**，不是追加字符串：

```json
{
  "type": "transcription.delta",
  "item_id": "item_...",
  "revision": 3,
  "text": "当前完整未确认文本",
  "audio_start_ms": 1200,
  "audio_end_ms": 2380
}
```

同一 `item_id` 的 revision 必须递增。客户端只展示最新 revision，不持久化 delta。

一个语句稳定后返回不可变结果：

```json
{
  "type": "transcription.completed",
  "item_id": "item_...",
  "text": "稳定文本",
  "language": "Chinese",
  "audio_start_ms": 1200,
  "audio_end_ms": 2460,
  "segments": [
    {
      "id": "seg_...",
      "start_ms": 1200,
      "end_ms": 2460,
      "text": "稳定文本",
      "speaker": null
    }
  ]
}
```

所有时间戳相对当前 SpeechRail session 的首个已接受 PCM 字节。客户端 adapter 负责把应用
拥有的 source epoch/offset 加到该时间轴上。`completed` 发出后，同一 item 不再修改。

### 2.3 flush、commit、cancel 与终态

- `input_audio_buffer.flush`：强制确认当前非空 item；session 保持可追加状态。空 flush 成功但
  不产生空转写。
- `input_audio_buffer.commit`：停止接收新音频，确认当前非空 item，等待所有逐句结果，然后
  发送 `session.completed`。这是正常 EOF。
- `session.cancel`：丢弃未确认音频和 partial，停止后续推理；发送 `session.cancelled` 后不得
  再产生 transcription 事件。

断线没有 terminal event 保证。客户端必须把它视为当前 session 截断，建立新 session，并
在自己的领域模型中记录无法补录的 gap。

## 3. `speech` 会话

### 3.1 配置与文本边界

`session.update` 至少包含 `type: "speech"`、公开 model、服务器登记的 preset voice 和期望
audio format。v2.0 不接受 voice sample、voice clone prompt 或任意文件/URL voice。

客户端以 `speech_input.append` 追加 UTF-8 文本。服务端按照配置的 `auto_clause` 文本边界形成
response；`speech_input.flush` 强制处理当前可读文本，`speech_input.commit` 处理剩余文本并
关闭输入。服务端不得逐 token 启动独立推理。

### 3.2 response 与音频块

每个被接受的文本单元先产生唯一 response：

```json
{
  "type": "response.created",
  "response_id": "resp_...",
  "voice": "speechrail/voice/zh-default",
  "audio_format": {
    "type": "audio/pcm",
    "rate": 24000,
    "channels": 1,
    "sample_width": 2
  }
}
```

音频块必须归属于 response：

```json
{
  "type": "response.audio.delta",
  "response_id": "resp_...",
  "chunk_index": 0,
  "audio": "<base64-pcm>"
}
```

`chunk_index` 在一个 response 内从 0 连续递增。完成时发送
`response.audio.completed`，并包含 `response_id`、`total_chunks` 和 `duration_ms`；一个 session
同时最多有一个 active response，后续文本可在受限缓冲区等待，不能并行生成多个无序音频流。

客户端可发送 `response.cancel` 并指定 `response_id`。服务端发送
`response.audio.cancelled` 后，不得再为该 response 生成新 delta；已经通过 WebSocket 发送的
块无法撤回，客户端必须按 response ID 丢弃尚未播放的缓存。`session.cancel` 取消 active
response 并清空尚未分配的文本。

`speech_input.commit` 的所有 response 终止后发送 `session.completed`。服务只生成音频；播放、
barge-in 决策、扬声器缓冲和回声协调仍由客户端负责。

## 4. 背压、限制与隐私

- API 边界强制单帧、累计音频、文本、未确认输出、session 时长和并发上限。
- 客户端慢消费导致输出队列达到上限时，服务发送 `slow_consumer` 并终止 session；不得无界
  缓存 Base64 音频。
- 队列满使用稳定 `queue_full`/`profile_saturated` 错误和 `retryable` 标志。
- 日志只记录 ID、profile、format、字节/时长、队列等待和推理耗时；不得记录 PCM、Base64、
  完整文本、prompt、key、voice sample 或绝对模型路径。

## 5. `voice-realtime` 映射约束

`voice-realtime` 使用一个共享协议客户端，但实现两个应用端口：

1. `SpeechRailStreamingTranscriber` 实现现有 `StreamingTranscriber`：
   `session.created → ready`；delta 和逐句 completed 累积为当前 `TranscriptWindow` 并产生
   `snapshot`；`session.completed → final`；`finish() → commit`；`close() → cancel/close`。
2. `SpeechRailConversationSTTFactory` 创建语音助手需要的 Pipecat `FrameProcessor`，把输入 PCM
   映射到 transcription session，并把逐句 completed 映射成应用现有 STT frame。

两个 adapter 都不拥有 AudioHub、VAD/turn-taking 业务策略、会议状态、SRT、PostgreSQL、LLM
或播放。会议断线重连由应用创建新 source epoch 并记录 gap；v2.0 服务端不提供透明续传。
