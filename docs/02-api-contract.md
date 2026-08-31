---
title: "SpeechRail 公共 API 契约"
status: active
api_version: "v1"
date: 2026-08-31
---

# SpeechRail 公共 API 契约

## 1. 契约选择

SpeechRail 的文件转写 API 遵循 OpenAI Audio Transcriptions 的请求形状，使用
`POST /v1/audio/transcriptions`；这样 QwenPaw、Hermes Agent 和任何使用 OpenAI
SDK 的应用都可以复用已有客户端。实时 API 使用 OpenAI Realtime transcription
的事件命名；旧 `voice-realtime` 则继续使用独立的 `/asr` 兼容协议。

参考：

- [OpenAI Audio Transcriptions](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)
- [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)

公共 API 的 base URL 是服务根地址；使用 OpenAI SDK 时把 `/v1` 作为 `base_url`：

```text
服务根地址：  http://127.0.0.1:8201
SDK base_url：http://127.0.0.1:8201/v1
```

## 2. 稳定端点

| 方法 | 路径 | 用途 | 稳定性 |
|---|---|---|---|
| GET | `/health` | 进程存活和版本 | stable |
| GET | `/readyz` | 模型/运行时是否可接收请求 | stable |
| GET | `/v1/models` | 公共模型清单和兼容别名 | stable |
| POST | `/v1/audio/transcriptions` | 文件/批量转写 | stable |
| WS | `/v1/realtime` | 新实时客户端 | stable after realtime milestone |
| WS | `/asr` | `voice-realtime` WLK 兼容层 | legacy |

`/health` 为进程存活，不代表模型 ready；客户端在发起推理前检查 `/readyz` 或把
`503` 当作可重试错误。

## 3. 模型身份

服务内部使用一个 canonical ID：

```text
speechrail/qwen3-asr-1.7b
```

以下别名在 `0.x` 兼容期接受，并由 `/v1/models` 返回：

```text
Qwen3-ASR-1.7B
qwen3-asr-1.7b
whisper-1             # 仅兼容旧配置；不代表实际使用 Whisper
```

`whisper-1` 只为旧 Hermes/OpenAI 配置提供迁移缓冲；新配置必须使用 canonical ID。
服务日志和审计记录同时保留 `requested_model` 与 `resolved_model`，以便识别旧别名。

## 4. REST 请求

```http
POST /v1/audio/transcriptions HTTP/1.1
Host: 127.0.0.1:8201
Authorization: Bearer <optional-local-key>
Content-Type: multipart/form-data; boundary=...
X-Request-ID: req_client_123

file=@meeting.wav
model=speechrail/qwen3-asr-1.7b
language=zh
prompt=产品名：SpeechRail、QwenPaw
response_format=verbose_json
timestamp_granularities[]=segment
```

### 请求字段

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `file` | binary | 必填 | 音频文件；服务端统一解码为 16 kHz mono PCM |
| `model` | string | canonical ID | 接受 canonical 或已登记 alias |
| `language` | string | auto | 建议 `zh`、`en`；也兼容 `Chinese`/`English` |
| `prompt` | string | 空 | 专名/领域上下文；有长度上限，不是系统指令 |
| `response_format` | enum | `json` | `json`、`verbose_json`、`text`、`srt`、`vtt` |
| `timestamp_granularities[]` | string[] | `segment` | 当前只在真实能力存在时返回 word 时间戳 |
| `stream` | boolean | `false` | 文件转写首发不支持 `true`；实时请使用 WS |

### 音频限制

- 支持的容器由解码器配置决定；首发覆盖 WAV、MP3、M4A、WebM、OGG、FLAC 等常见格式。
- 服务端不会信任文件扩展名；先落入受限临时文件，再通过 `ffmpeg` 无 shell 方式解码。
- 最大字节数和最大时长必须由配置控制，默认值不写死在客户端。
- 空文件、损坏容器、超限文件在进入模型前拒绝。
- 源音频处理结束后删除临时文件；需要留存由消费者显式负责，不由 SpeechRail 隐式保存。

## 5. REST 响应

### `json`

```json
{
  "text": "这是转写结果。",
  "usage": {
    "type": "duration",
    "seconds": 5.2
  }
}
```

### `verbose_json`

```json
{
  "task": "transcribe",
  "language": "zh",
  "duration": 5.2,
  "text": "这是转写结果。",
  "segments": [
    {
      "id": "seg_0001",
      "start": 0.0,
      "end": 5.2,
      "text": "这是转写结果。"
    }
  ],
  "words": [],
  "usage": {
    "type": "duration",
    "seconds": 5.2
  }
}
```

`words` 为空表示当前 backend 没有真实 word-level 时间戳，不表示服务端计算失败。
禁止用平均插值结果冒充真实对齐。

### `text`、`srt`、`vtt`

- `text`：`text/plain; charset=utf-8`，只返回全文。
- `srt`：`text/plain; charset=utf-8`，使用 `HH:MM:SS,mmm`。
- `vtt`：`text/vtt; charset=utf-8`，使用 `WEBVTT` 和 `HH:MM:SS.mmm`。

## 6. 错误契约

为了让 OpenAI SDK、Hermes 和 QwenPaw 都能稳定解析，公共接口统一使用 OpenAI-compatible
`error` envelope，而不是让不同端点各自返回不同结构：

```json
{
  "error": {
    "message": "SpeechRail inference backend is not ready",
    "type": "server_error",
    "param": null,
    "code": "backend_not_ready",
    "request_id": "req_abc123",
    "retryable": true
  }
}
```

| HTTP | code | retryable | 典型原因 |
|---:|---|:---:|---|
| 400 | `invalid_request` / `model_not_found` | 否 | 参数或模型别名不合法 |
| 401 | `invalid_api_key` | 否 | key 缺失或错误 |
| 413 | `audio_too_large` | 否 | 文件字节数超限 |
| 422 | `validation_error` | 否 | multipart 字段缺失或类型错误 |
| 429 | `queue_full` | 是 | 有界推理队列已满 |
| 408 | `inference_timeout` | 是 | 单次推理超时 |
| 500 | `internal_error` | 视情况 | 非预期错误；正文不含 traceback |
| 503 | `backend_not_ready` / `backend_unavailable` | 是 | 模型尚未 ready 或熔断 |
| 504 | `backend_timeout` | 是 | 下游 runtime 超时 |

所有响应包含 `X-Request-ID`；客户端重试只针对 `retryable=true`，并使用指数退避和
`Retry-After`。重复的 REST 请求如需业务级幂等，由消费者用自己的 request ID 管理；
服务不默认缓存音频正文。

## 7. 认证与网络

- 默认只监听 `127.0.0.1`，本机场景可不设置 key。
- 绑定 LAN/`0.0.0.0` 时必须设置 `SPEECHRAIL_API_KEY`，并限制 CORS/origin。
- HTTP 使用 `Authorization: Bearer <key>`。
- Realtime 使用握手 `Authorization` header；浏览器场景使用经过认证的短期会话票据，
  不把长期 key 写进 URL。
- legacy `/asr?token=...` 仅为旧客户端兼容保留，属于弃用路径；因为 URL 可能进入代理
  日志，迁移后的 `voice-realtime` 应改用 header 认证。

## 8. 版本策略

- 路径版本固定为 `/v1`；新增可选字段、响应字段和端点属于兼容扩展。
- 删除字段、改变类型、改变错误语义或改变 realtime 事件状态机时创建 `/v2`。
- legacy `/asr` 至少保留到所有 `voice-realtime` 实例切换到 `/v1/realtime` 后一个发布周期。
- 兼容 alias 先记录弃用告警，再在主版本移除；不会静默重解释成另一个模型。
