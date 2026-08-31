---
title: "SpeechRail 客户端接入"
status: active
date: 2026-08-31
---

# SpeechRail 客户端接入

## 1. 统一约定

所有客户端都只需要一个 base URL：

```text
http://127.0.0.1:8201/v1
```

如果完成兼容端口切换，则改为：

```text
http://127.0.0.1:8001/v1
```

客户端不应直接访问模型目录、`wlk`、Qwen SDK 或 SpeechRail worker。文件转写统一
调用 `POST /audio/transcriptions`（当 base URL 已包含 `/v1` 时）。

## 2. QwenPaw

### 当前核对状态

2026-08-31 的本机配置记录显示：QwenPaw 2.1.0 使用 `audio_mode: auto`，转写提供商
为 `voice-realtime-asr`，provider 类型为 `whisper_api`，模型为 `Qwen3-ASR-1.7B`，
base URL 为 `http://127.0.0.1:8001/v1`。这说明 QwenPaw 已经具备所需的 OpenAI-compatible
接入形态，不需要为 SpeechRail 开发专用 SDK。

### 推荐配置

在 QwenPaw 的语音/转写设置中：

```text
Audio mode: auto
Provider type: Whisper API / whisper_api
Base URL: http://127.0.0.1:8201/v1
Model: speechrail/qwen3-asr-1.7b
API key: 本机 loopback 可填占位值；LAN 必须填写 SpeechRail key
```

若界面限制模型输入，可暂时填兼容别名 `Qwen3-ASR-1.7B`。不要把
`voice-realtime-asr` 继续作为 SpeechRail 的产品名，它只是旧 provider 标识。

### 验证

```bash
curl http://127.0.0.1:8201/health
curl http://127.0.0.1:8201/v1/models
curl -X POST http://127.0.0.1:8201/v1/audio/transcriptions \
  -F 'file=@sample.wav' \
  -F 'model=speechrail/qwen3-asr-1.7b' \
  -F 'language=zh' \
  -F 'response_format=json'
```

确认 curl 通过后，再用 QwenPaw 录一段中文短句。更新 provider/model 后必须完整重启
QwenPaw app；仅 reload agent 配置不能保证常驻 provider registry 已刷新。

## 3. Hermes Agent

### 推荐方式：只改 STT 环境变量

Hermes Agent 0.20.5 的转写工具使用 `STT_OPENAI_BASE_URL` 和 `STT_OPENAI_MODEL`，
并通过 OpenAI SDK 的 `audio.transcriptions.create` 发送 multipart 文件。建议在
`~/.hermes/.env` 中加入：

```dotenv
STT_OPENAI_BASE_URL=http://127.0.0.1:8201/v1
STT_OPENAI_MODEL=speechrail/qwen3-asr-1.7b
```

如果当前 Hermes 配置显式选择 provider，则保持：

```yaml
stt:
  enabled: true
  provider: openai
  openai:
    model: speechrail/qwen3-asr-1.7b
```

环境变量是跨版本最稳妥的 endpoint 覆盖方式。不要为了 STT 修改全局
`OPENAI_BASE_URL`，它可能同时改变 Hermes 的聊天模型出口。loopback 地址通常不需要
真实 API key；如果本地 OpenAI SDK 初始化强制要求 key，只使用不会泄露的占位值，并确保
它只用于 STT provider。

### Hermes 的文件限制

当前 Hermes 转写工具自身仍有 25 MB 文件上限。因此：

- SpeechRail 可以有更高的服务端上限，但 Hermes 客户端超过 25 MB 仍会在客户端拒绝。
- 长会议应由 `voice-realtime` 通过 realtime/legacy WS 处理，或由调用方先切段。
- 发生 `backend_not_ready`、`queue_full`、`backend_timeout` 时按 `retryable` 和
  `Retry-After` 重试，不要无限重试。

### 验证

```bash
hermes doctor
curl http://127.0.0.1:8201/readyz
```

再从 Hermes 发送一条语音消息，检查转写文本和 provider 状态。不要把完整音频或完整
转写正文贴入公共日志。

## 4. voice-realtime

### 迁移前并行运行

第一阶段不改 `voice-realtime`：

```text
旧 WLK :8001      ← voice-realtime 字幕/会议（稳定回退）
SpeechRail :8201  ← QwenPaw、Hermes shadow smoke
```

这时 `voice-realtime` 继续使用自己的 `SubtitleProxy`、AudioHub、会议和 Sortformer。
SpeechRail 只承接新的 REST 客户端，避免端口和模型进程冲突。

### 兼容端口切换

当 SpeechRail 的 legacy `/asr` parity 验收通过后：

1. 停止 `voice-realtime` 的 `vr-subtitles`/WLK 子进程。
2. 将 SpeechRail 监听切换到 `127.0.0.1:8001`。
3. 保持 `voice-realtime` 的 `VR_SUBTITLE_HOST=127.0.0.1`、
   `VR_SUBTITLE_PORT=8001`。
4. 重新启动 `voice-realtime` UI；其现有 `SubtitleStream` 继续连接
   `/asr?language=...&mode=full`。

因为 SpeechRail 重建了 `config`、full snapshot、`lines`、`buffer_transcription` 和
空 PCM EOF，应用层可以先不改代码完成切换。

### 现代 Realtime 迁移

后续在 `voice-realtime` 增加一个 `SpeechRailRealtimeAdapter`：

```text
AudioHub PCM
  → SpeechRailRealtimeAdapter
  → WS /v1/realtime
  → delta/completed
  → SubtitleProxy / MeetingSession
```

这项改动需要修改 `voice-realtime`，当前项目没有擅自写入该仓库。推荐增加明确的
`VR_SUBTITLE_EXTERNAL_URL` 和 `VR_SUBTITLE_MANAGED=false` 配置：现有项目目前没有这
两个字段，不能把它们误写成已经生效的配置。

## 5. 通用 OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8201/v1",
    api_key="local-not-used",
)

with open("sample.wav", "rb") as audio:
    result = client.audio.transcriptions.create(
        model="speechrail/qwen3-asr-1.7b",
        file=audio,
        language="zh",
        response_format="verbose_json",
    )

print(result.text)
```

## 6. 不推荐的接入方式

- 直接 import `voice_realtime.asr`：会绑定综合应用的发布周期和会议模型。
- 直接启动 `wlk` 并让每个客户端猜参数：会产生多个模型实例和不一致的 EOF 语义。
- 把 SpeechRail base URL 填到 Hermes 的全局 `OPENAI_BASE_URL`：可能误路由聊天请求。
- 在客户端硬编码 Qwen snapshot 路径：破坏模型替换和跨机器部署。
- 用 `whisper-1` 作为新配置的实际模型 ID：会隐藏真实后端，增加排障成本。
