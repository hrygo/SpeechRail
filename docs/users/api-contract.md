---
title: "SpeechRail 公共 API 契约手册"
status: active
audience: "应用开发者、客户端工程师、API 消费者"
version: "1.6.8"
date: 2026-09-05
---

# 📡 SpeechRail 公共 API 契约手册

> 机器可读的 OpenAPI 3.1 规范位于 [`contracts/openapi.yaml`](../../contracts/openapi.yaml)；WebSocket 全双工事件规范位于 [`contracts/realtime-openai.md`](../../contracts/realtime-openai.md)。

---

## 1. 模型身份与别名映射

SpeechRail 对外暴露 Canonical（规范）模型名与 OpenAI 标准别名（Alias）：

| 能力类别 | Canonical 模型 ID | 兼容别名 (Aliases) | 说明 |
|---|---|---|---|
| **语音识别 (ASR)** | `speechrail/qwen3-asr-1.7b` | `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` | 别名自动归一化路由至本地 Qwen3-ASR 运行时（支持 1.7B / 0.6B 权重目录） |
| **语音合成 (TTS)** | `speechrail/qwen3-tts` | `tts-1`, `tts-1-hd`, `gpt-4o-mini-tts` | 别名自动归一化路由至本地 Qwen3-TTS 运行时 (VoiceDesign) |

> 💡 **模型规格自适应**：Canonical 模型 ID 标识服务后端能力契约，底层可通过 `SPEECHRAIL_QWEN3_MODEL_DIR` 自由加载 **Qwen3-ASR-1.7B** 或 **Qwen3-ASR-0.6B**（显存占用更低、适用于 8GB 内存设备），对外均遵循相同的 OpenAI 协议。

客户端向 `GET /v1/models` 发起请求即可获取完整的模型清单及其 `resolves_to` 映射关系。

---

## 2. API 端点全览

| 请求方法 | 路径 | 描述 | 主要参数 / 返回格式 |
|---|---|---|---|
| `GET` | `/health` | 进程存活检查与组件诊断 | 返回各 Worker 进程存活状态与配置信息 |
| `GET` | `/readyz` | 推理就绪状态检查 | HTTP 200 表示 ASR/TTS 引擎已预热并可接受流量 |
| `GET` | `/metrics` | 运行指标导出 | 默认 Prometheus 文本；`Accept: application/json` 返回结构化视图 |
| `GET` | `/v1/models` | 模型清单与别名路由 | 列出 Canonical 模型名与 `whisper-1` 等兼容别名 |
| `GET` | `/v1/voices` | 注册与自定义的 TTS 音色列表 | 返回系统预置与自建音色全属性及可用性 |
| `POST` | `/v1/voices` | 自然语言创建自定义音色 (Voice Design) | 接收名称与人设描述，固化专属 Seed 并持久化 |
| `DELETE` | `/v1/voices/{voice_id}` | 删除自定义音色 | 删除指定自建音色（系统预置音色只读保护） |
| `POST` | `/v1/audio/transcriptions` | OpenAI 兼容文件转写 | `json`, `verbose_json`, `text`, `srt`, `vtt` |
| `POST` | `/v1/audio/speech` | OpenAI 兼容语音合成 | `mp3`(默认), `opus`, `aac`, `flac`, `wav`, `pcm` (24kHz 16-bit Mono) |
| `POST/GET/DELETE` | `/v1/jobs` | 异步任务 Spool 管理 | 提交长任务元数据、查询状态与取消任务 |
| `WS` | `/v1/realtime` | OpenAI Realtime WebSocket | 实时音频流式转写、合成与说话人分割 |

---

## 3. 文件转写 API (`POST /v1/audio/transcriptions`)

```http
POST /v1/audio/transcriptions
Content-Type: multipart/form-data
```

### 请求参数表 (Multipart Form-Data)
| 参数名 | 类型 | 必填 | 默认值 | 说明 |
|---|---|---|---|---|
| `file` | Binary | **是** | - | 音频文件（支持 `wav`, `mp3`, `m4a`, `ogg`, `flac`, `webm` 等） |
| `model` | String | 否 | `whisper-1` | 模型名（支持 Canonical ID 或 OpenAI 标准别名） |
| `language` | String | 否 | `auto` | 语言代码（如 `zh`, `en`, `ja`, `auto` 等） |
| `prompt` | String | 否 | - | 专有名词提示文本（最长 2000 字符） |
| `response_format` | String | 否 | `json` | 响应格式：`json`, `verbose_json`, `text`, `srt`, `vtt` |
| `timestamp_granularities[]` | Array | 否 | `["segment", "word"]` | 时间戳精度：`segment`, `word`；须配合 `verbose_json` |

标准 multipart 数组使用重复字段，例如 `timestamp_granularities[]=word`。
旧 `timestamp_granularities` 字段仍可使用；两种写法混用时合并后验证，任一字段中的非法值都会返回
`422 invalid_timestamp_granularities`。只请求 `word` 时返回 `words`，只请求 `segment` 时返回
`segments`；省略粒度时保持同时返回两者。

上传大小仍受 `SPEECHRAIL_MAX_UPLOAD_BYTES` 限制；解码输出另受 128 MiB 和
`SPEECHRAIL_MAX_AUDIO_SECONDS` 约束。WAV fastpath 在重采样前检查预计输出，其他容器在
读取 `ffmpeg` 输出时检查，超限即停止处理。取消或解码超时会回收对应子进程；这不构成
`ffmpeg` 自身内存占用的操作系统硬限制。

---

## 4. 语音合成 API (`POST /v1/audio/speech`)

```http
POST /v1/audio/speech
Content-Type: application/json
```

```json
{
  "model": "tts-1",
  "input": "欢迎使用 SpeechRail 本地语音合成引擎。",
  "voice": "warm",
  "response_format": "mp3",
  "speed": 1.0
}
```

`mp3`、`opus`、`aac`、`flac` 的容器编码具有 15 秒超时和 128 MiB 输出上限。
编码超限、超时或失败返回 `502 audio_encode_failed`；取消请求时回收编码子进程。

### 预设音色库 (Preset Voices)
- `default`：标准清晰中性音色（OpenAI `alloy` 映射目标）。
- `warm`：温暖亲和音色（适合陪伴、聊天）。
- `calm`：沉稳平静音色（适合新闻播报、听书朗读）。
- `bright`：明亮活泼音色（适合儿童读物、助手交互）。

---

## 5. 音色管理与自然语言设计 API (`/v1/voices`)

SpeechRail 提供工业级的音色注册管理与自然语言音色设计（Voice Design）体系。

### 5.1 系统预置音色与采样确定性保证
为了根治大模型短句切流式 TTS 合成时可能出现的**分句换人、跨轮音色漂移**问题，SpeechRail 为每个预置音色绑定了确定的随机种子（Random Seed），并在 MLX 推理前显式调用 `mx.random.seed(profile.seed)`，将生成采样温度固定为 `temperature=0.1`：

| 音色 ID | 名称 | 专属 Seed | 采样温度 | 特征定位与适用场景 | 状态 |
|---|---|---|---|---|---|
| `default` | 默认原声 | `42` | `0.1` | 标准专业、自然清晰的中文女声，语气平和亲切 | 系统预置（只读保护） |
| `warm` | 温暖磁性 | `1024` | `0.1` | 温和厚重、富有同理心的青年男声，适合陪伴聊天 | 系统预置（只读保护） |
| `bright` | 清脆干练 | `2048` | `0.1` | 清脆明快、朝气蓬勃的年轻女声，适合活力交互 | 系统预置（只读保护） |
| `calm` | 沉稳专业 | `4096` | `0.1` | 沉稳庄重、节奏从容的专业播音员，适合新闻/严肃播报 | 系统预置（只读保护） |

> 🛡️ **只读保护原则**：系统预置音色标记为 `is_system: true`，禁止通过 API 进行覆盖、修改或删除。

### 5.2 获取音色目录 (`GET /v1/voices`)
```http
GET /v1/voices
Authorization: Bearer <TOKEN>
```
**响应示例**：
```json
{
  "object": "list",
  "data": [
    {
      "id": "default",
      "name": "默认原声",
      "description": "自然清晰的中文女声，语气平和亲切，语速适中，适合日常对话。",
      "instruction": "自然清晰的中文女声，语气平和亲切，语速适中，适合日常对话。",
      "aliases": ["alloy", "ash", "echo"],
      "is_default": true,
      "is_system": true,
      "created_at": 1788582000.0,
      "available": true
    },
    {
      "id": "custom_1788583825_59b3",
      "name": "知性姐姐",
      "description": "温柔轻快、语调柔和的年轻女声，吐字清晰亲和，富有同理心与治愈感。",
      "instruction": "温柔轻快、语调柔和的年轻女声，吐字清晰亲和，富有同理心与治愈感。",
      "aliases": [],
      "is_default": false,
      "is_system": false,
      "created_at": 1788583825.0,
      "available": true
    }
  ]
}
```

### 5.3 自然语言设计与创建音色 (`POST /v1/voices`)
支持使用自然语言描述特征（Prompt）动态创建新音色：
```http
POST /v1/voices
Content-Type: application/json
Authorization: Bearer <TOKEN>

{
  "name": "知性姐姐",
  "instruction": "温柔轻快、语调柔和的年轻女声，吐字清晰亲和，富有同理心与治愈感。"
}
```
**请求参数**：
- `name` (string, 必填)：音色友好展示名称。
- `instruction` (string, 必填)：音色特征自然语言描述（人设、年龄、音质、情绪、语速等）。
- `id` (string, 可选)：自定义音色标识符。若不提供则自动生成 `custom_<timestamp>_<rand>`。

**持久化机制**：创建成功的音色会自动分配一个固定随机种子（Seed），并持久化保存在用户目录 `~/.speechrail/custom_voices.json` 中，服务重启后依然生效。

### 5.4 删除自定义音色 (`DELETE /v1/voices/{voice_id}`)
```http
DELETE /v1/voices/custom_1788583825_59b3
Authorization: Bearer <TOKEN>
```
- 若删除成功，返回 `{"status": "deleted", "id": "custom_1788583825_59b3"}`；
- 若尝试删除系统预置音色（`default`, `warm`, `bright`, `calm`），系统将返回 `403 Forbidden` (`{"error": "系统预置音色受保护，不可删除"}`)；
- 若音色不存在，返回 `404 Not Found`。

### 5.5 在语音合成中使用自定义音色
创建成功后，自建音色的 `id` 可直接传入任何合成接口：
- **REST 试听/合成**：`POST /v1/audio/speech` 中 `{"model": "speechrail/qwen3-tts", "voice": "custom_xxx", "input": "..."}`
- **Realtime 流式会话**：`WS /v1/realtime` 中通过 `session.update` 配置 `{"session": {"voice": "custom_xxx"}}`。

---

## 6. 全双工 Realtime WebSocket (`WS /v1/realtime`)

连接端点：`ws://127.0.0.1:8201/v1/realtime`

### 核心支持事件列表
| 事件名称 (Type) | 方向 | 说明 |
|---|---|---|
| `session.update` | 客户端 → 服务端 | 配置 VAD 模式、音色、转写语种等 |
| `input_audio_buffer.append` | 客户端 → 服务端 | 追加 16kHz PCM16 音频块 (Base64 编码) |
| `input_audio_buffer.commit` | 客户端 → 服务端 | 手动提交当前音频缓冲区并触发识别 |
| `input_audio_buffer.speech_started` | 服务端 → 客户端 | Server VAD 触发检测到人声开始 |
| `input_audio_buffer.speech_stopped` | 服务端 → 客户端 | Server VAD 触发检测到人声结束 |
| `response.create` | 客户端 → 服务端 | 触发语音合成 (Stream-In TTS) |
| `response.audio.delta` | 服务端 → 客户端 | 流式返回 24kHz PCM16 音频增量块 |
| `response.cancel` | 客户端 → 服务端 | 立即打断并取消正在进行的语音合成 |

---

## 7. 统一错误 Envelope 与状态码

所有 HTTP 接口的非 2xx 响应严格遵循统一的错误结构体：

```json
{
  "error": {
    "message": "The uploaded audio format could not be decoded.",
    "type": "invalid_request_error",
    "code": "audio_decode_failed",
    "request_id": "req_01j6zabc1234",
    "retryable": false
  }
}
```

### 标准错误码速查表
| HTTP 状态码 | Error Code | 是否可重试 (`retryable`) | 常见原因与处理建议 |
|---|---|---|---|
| **400** | `model_not_found` | `false` | 请求的模型名不存在，核对 `/v1/models` 清单 |
| **400** | `audio_too_long` | `false` | 音频时长超出 `SPEECHRAIL_MAX_AUDIO_SECONDS` 限制 |
| **401** | `invalid_api_key` | `false` | 未提供有效的 API Key 或 Token 错误 |
| **413** | `audio_too_large` | `false` | 音频大小超出 `SPEECHRAIL_MAX_UPLOAD_BYTES` 限制 |
| **422** | `audio_decode_failed` | `false` | 上传文件损坏或非标准音频容器，检查文件有效性 |
| **429** | `queue_full` | `true` | 当前并发超出 Governor 配额，按 `Retry-After` 重试 |
| **503** | `backend_not_ready` | `true` | 对应模型 Worker 尚未启动或预检未通过，等待就绪 |
| **504** | `backend_timeout` | `true` | 单次推理超出超时硬截断限制，减小音频分块 |
