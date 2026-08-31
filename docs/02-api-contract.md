---
title: "SpeechRail 公共 API 契约"
status: active
api_version: "v1"
date: 2026-08-31
---

# SpeechRail 公共 API 契约

机器可读 REST 事实来源是 [OpenAPI 3.1](../contracts/openapi.yaml)。本页解释客户端应如何
使用当前实现；WebSocket 的事件详情以 [Realtime 契约](../contracts/realtime.md) 为准。
已审查但尚未实现的 `/v2/realtime` 目标见
[Realtime v2 设计契约](../contracts/realtime-v2.md)，不得把该设计当作当前可用 API。

## 地址、身份和版本

服务根地址默认是 `http://127.0.0.1:8201`；OpenAI SDK / QwenPaw 的 base URL 是
`http://127.0.0.1:8201/v1`。公共 canonical model ID：

```text
speechrail/qwen3-asr-1.7b
```

`Qwen3-ASR-1.7B`、`qwen3-asr-1.7b`、`whisper-1` 为 `0.x` 兼容别名；最后一个不代表
服务使用 Whisper。新配置一律使用 canonical ID。

删除字段、改变字段类型、错误码语义或 WebSocket 状态机属于破坏性变更，必须进入 `/v2`
并附迁移说明。`/asr` 不承诺稳定新功能。

## 当前端点

| 方法 | 路径 | 实际行为 |
|---|---|---|
| `GET` | `/health` | 返回进程、版本、后端名称和是否有配置的推理入口 |
| `GET` | `/readyz` | 无推理入口时为 503；有入口时为 200，仍须用真实音频验收 worker |
| `GET` | `/v1/models` | canonical ID 与兼容 aliases |
| `POST` | `/v1/audio/transcriptions` | OpenAI-compatible multipart 文件转写 |
| `WS` | `/v1/realtime` | PCM append 后在一次 commit 做最终转写 |
| `WS` | `/asr` | 仅 `config` / 空帧 EOF 行为，尚无 legacy ASR |

## 文件转写

```http
POST /v1/audio/transcriptions
Authorization: Bearer <key-if-configured>
Content-Type: multipart/form-data
```

| 字段 | 当前支持 | 说明 |
|---|---|---|
| `file` | 必填 | `Content-Type` 必须以 `audio/` 开头；服务以固定 `ffmpeg` 参数解码 |
| `model` | 可选 | 留空或使用 canonical/已登记 alias |
| `language` | 可选 | `zh`、`en`、`auto` 及 worker 支持的语言别名 |
| `prompt` | 可选 | 最多 2,000 字符的专名提示，不是指令通道 |
| `response_format` | 可选 | `json`、`verbose_json`、`text`、`srt`、`vtt` |

当前路由不接收 `stream` 或 `timestamp_granularities[]`；不要依赖它们。`verbose_json`
包含 segment 结果；Qwen3 当前不生成 word-level timestamps，`words` 为空。

上传字节数由 `SPEECHRAIL_MAX_UPLOAD_BYTES` 强制限制。`SPEECHRAIL_MAX_AUDIO_SECONDS`
已是配置字段，但 `0.1.0` 尚未在解码后强制按时长拒绝，因此运营上应同时控制客户端
音频时长和上传字节数。

## 响应与错误

`json` 返回 `{ "text": "…", "usage": { "type": "duration", "seconds": … } }`。
`text`、`srt`、`vtt` 返回纯文本，`verbose_json` 返回文本、语言、时长与 segments。

所有 HTTP 错误遵循同一 envelope，且响应携带 `X-Request-ID`：

```json
{
  "error": {
    "message": "SpeechRail inference backend is not ready",
    "type": "server_error",
    "code": "backend_not_ready",
    "request_id": "req_...",
    "retryable": true
  }
}
```

当前可依赖的典型 code：`invalid_api_key` (401)、`model_not_found` (400)、
`audio_too_large` (413)、`empty_audio` / `unsupported_audio_type` / `audio_decode_failed`
(422)、`queue_full` (429)、`backend_not_ready` / `backend_timeout` (503)。只对
`retryable=true` 做带退避的有限重试；429 同时读取 `Retry-After`。

## 认证与网络

默认 loopback 且不需要 key。非 loopback host 在 Settings 校验阶段必须有
`SPEECHRAIL_API_KEY`；REST 和 `/v1/realtime` 要求 `Authorization: Bearer <key>`。
`allowed_origins` 是预留配置，当前版本未安装 CORS middleware；不要把它当作 LAN 防护。
legacy `/asr` 目前也不校验 header/query token，因此只能用于 loopback 开发验证。
