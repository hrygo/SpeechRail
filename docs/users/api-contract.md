---
title: "SpeechRail 公共 API 契约"
status: active
api_version: "v1"
date: 2026-08-31
---

# SpeechRail 公共 API 契约

机器可读 REST 事实来源是 [OpenAPI 3.1](../../contracts/openapi.yaml)。本页解释客户端应如何
使用当前实现；`/v1/realtime` 的事件详情以 [Realtime v1 契约](../../contracts/realtime.md) 为准。
`/v2/realtime` 已有可测试的 ASR/TTS state-machine 实现，完整事件与已知运行时边界见
[Realtime v2 契约](../../contracts/realtime-v2.md)。没有已授权并通过 smoke 的真实 worker 时，
该端点不得被表述为模型可用。

ASR v2 默认仍可使用受限 batch backend 在 flush/commit 后产出结果。仅在明确设置
`SPEECHRAIL_WLK_STREAMING_URL` 时，它才连接已存在的本地 WLK endpoint 并在 commit 前产出
持续 partial/completed；该配置不会启动或下载 sidecar。

## 地址、身份和版本

服务根地址默认是 `http://127.0.0.1:8201`；OpenAI SDK / QwenPaw 的 base URL 是
`http://127.0.0.1:8201/v1`。公共 canonical model ID：

```text
ASR: speechrail/qwen3-asr-1.7b
TTS: speechrail/qwen3-tts
```

客户端可直接使用 OpenAI 标准模型名（`whisper-1`、`tts-1`、`gpt-4o-transcribe`、
`gpt-4o-mini-tts` 等）或 canonical ID 接入；`/v1/models` 列出 canonical 与全部 alias，
alias 条目带 `resolves_to` 标注其 canonical profile。标准名不代表服务加载 OpenAI 模型，
实际推理能力以对应 profile 配置和 smoke 为准。

删除字段、改变字段类型、错误码语义或 WebSocket 状态机属于破坏性变更，必须进入 `/v2`
并附迁移说明。`/asr` 不承诺稳定新功能。

## 当前端点

| 方法 | 路径 | 实际行为 |
|---|---|---|
| `GET` | `/health` | 返回进程、版本及 `asr_ready`/`tts_ready` 独立状态 |
| `GET` | `/readyz` | 至少一个已配置 ASR/TTS 推理入口可接受请求；真实模型仍需 smoke |
| `GET` | `/v1/models` | canonical ASR/TTS ID 与兼容 aliases |
| `GET` | `/v1/voices` | 登记的 TTS preset 目录；TTS worker 未就绪时仍可返回目录并标记 `available=false` |
| `POST` | `/v1/audio/transcriptions` | OpenAI-compatible multipart 文件转写 |
| `POST` | `/v1/audio/speech` | OpenAI-compatible 整句 TTS；当前支持 `wav` 与 `pcm` |
| `POST` | `/v1/jobs` | 创建 owner-scoped 异步语音任务元数据（需配置 spool） |
| `GET` | `/v1/jobs/{job_id}` | 读取同 owner 的任务状态与可选结果引用 |
| `DELETE` | `/v1/jobs/{job_id}` | 取消 queued 任务，或清除 completed 任务的结果引用 |
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
| `file` | 必填 | 支持 `flac`、`mp3`、`mp4`、`mpeg`、`mpga`、`m4a`、`ogg`、`wav`、`webm`；multipart MIME 与文件名仅作格式提示，服务会用固定 `ffmpeg` 参数校验并解码 |
| `model` | 可选 | 留空或使用 canonical/已登记 alias |
| `language` | 可选 | `zh`、`en`、`auto` 及 worker 支持的语言别名 |
| `prompt` | 可选 | 最多 2,000 字符的专名提示，不是指令通道 |
| `response_format` | 可选 | `json`、`verbose_json`、`text`、`srt`、`vtt` |

当前路由不接收 `stream` 或 `timestamp_granularities[]`；不要依赖它们。`verbose_json`
包含 segment 结果；Qwen3 当前不生成 word-level timestamps，`words` 为空。

上传字节数由 `SPEECHRAIL_MAX_UPLOAD_BYTES` 强制限制。`SPEECHRAIL_MAX_AUDIO_SECONDS`
已是配置字段，但 `0.1.0` 尚未在解码后强制按时长拒绝，因此运营上应同时控制客户端
音频时长和上传字节数。

## 文本转语音

先用 `GET /v1/voices` 获取服务器登记的 preset；成功响应的形状为
`{"object":"list","data":[...]}`。首发 preset 为 `default`、`warm`、`bright` 和
`calm`，客户端不得上传 voice sample、clone prompt、文件或 URL。

`/v1/voices` 只负责返回服务端登记的目录，不以 TTS worker ready 作为路由前置条件。按当前代码，未配置
外部 TTS runtime 时也应返回目录，条目标记为 `available=false`；如果实际返回 404，应先核对客户端的
base URL、服务端口和运行中的进程是否为当前代码，再重启服务。Creator 等客户端要执行真正的 TTS 合成，
必须在 SpeechRail 的 `.env` 中同时配置 `SPEECHRAIL_QWEN3_TTS_MODEL_DIR` 和
`SPEECHRAIL_QWEN3_TTS_PYTHON`，然后重启服务；缺少配置时 `/v1/audio/speech` 的预期错误是
`503 backend_not_ready`，不是 `/v1/voices` 404。

```http
POST /v1/audio/speech
Authorization: Bearer <key-if-configured>
Content-Type: application/json
```

```json
{
  "model": "speechrail/qwen3-tts",
  "input": "SpeechRail smoke test.",
  "voice": "default",
  "response_format": "pcm",
  "speed": 1.0,
  "language": "auto"
}
```

`response_format` 支持 `pcm` 和 `wav`；公共 PCM 输出是 24 kHz、单声道、signed little-endian
PCM16。`speed` 范围为 `0.25..4.0`，`language` 默认为 `auto`。没有配置外部 TTS runtime
时，端点返回稳定的 `503 backend_not_ready`；TTS 未就绪不应被客户端当作 ASR 不可用。

## 异步 Jobs

`POST /v1/jobs` 接收 `{"kind":"speech"|"transcription","input_ref":"…"}` 并返回
`202` 与 `{id, kind, state, error_code, result_ref}`。`input_ref` 是调用方自行解析的
不透明外部引用：不得传入原始音频、转写正文、文本内容或凭据。服务只保存该引用和 API-key
派生的 owner 指纹（loopback 无 key 时为本机 owner），因此不同 owner 一律得到 404。

仅当设置绝对路径 `SPEECHRAIL_JOB_SPOOL_DIR` 时才启用该资源；未设置时返回
`503 backend_not_ready`。启动时残留的 `running` 记录会标记为
`failed / worker_interrupted`。当前 `0.1.0 foundation` 已有元数据生命周期与 TTL
原语。部署代码可显式注入受信任的 `JobProcessor` 后启动 batch runner；它与 realtime 共用
Resource Governor。首发没有内建的 `input_ref` 路径/URL resolver，因此默认部署不会把
`queued` 自动解释为可读取的模型输入。

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
`SPEECHRAIL_API_KEY`；REST、`/v1/realtime` 和 `/v2/realtime` 要求
`Authorization: Bearer <key>`。
`allowed_origins` 是预留配置，当前版本未安装 CORS middleware；不要把它当作 LAN 防护。
legacy `/asr` 目前也不校验 header/query token，因此只能用于 loopback 开发验证。
