---
title: "SpeechRail 用户与客户端接入"
status: active
date: 2026-08-31
---

# SpeechRail 用户与客户端接入

客户端只调用 SpeechRail 的公共 HTTP / WebSocket 接口，绝不直接访问模型目录、Qwen SDK
或 worker。接入前先完成 [运维 Runbook](11-operations-runbook.md) 的 REST smoke。

## 通用约定

```text
服务根地址：  http://127.0.0.1:8201
SDK base URL： http://127.0.0.1:8201/v1
模型：        speechrail/qwen3-asr-1.7b
```

loopback 模式不需 API key；非 loopback 模式将 key 放在客户端安全配置中并通过
`Authorization: Bearer` 发送，不写进 URL、截图或日志。

## QwenPaw（已验证）

QwenPaw 使用已有的 `whisper_api` provider，不需要 SpeechRail SDK。2026-08-31 已在本机
将 provider `voice-realtime-asr` 的 base URL 改为 `http://127.0.0.1:8201/v1`，并设置
模型 `speechrail/qwen3-asr-1.7b`；完成完整应用重启和中文短音频 smoke。

在 QwenPaw 的语音/转写设置中填写：

```text
Audio mode: auto
Provider type: Whisper API / whisper_api
Base URL: http://127.0.0.1:8201/v1
Model: speechrail/qwen3-asr-1.7b
API key: loopback 可留空或用客户端要求的占位值；非 loopback 使用服务 key
```

每次改 provider URL 或 model 后必须完整重启 QwenPaw，不能只 reload agent 配置。
先确认 `curl` 转写可用，再从 QwenPaw 录制短音频。回滚只恢复原 provider 的 base URL/model
后完整重启；不要修改聊天模型 endpoint。

## OpenAI SDK

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

客户端应捕获 HTTP 错误 envelope，只对 `retryable=true` 做指数退避。不要无界重试 429/503，
也不要依赖 `whisper-1` 作为新配置。

## Hermes Agent（配置方法，未验收）

Hermes 的 STT 配置应与聊天模型 endpoint 分离。建议设置其 STT 专用配置：

```dotenv
STT_OPENAI_BASE_URL=http://127.0.0.1:8201/v1
STT_OPENAI_MODEL=speechrail/qwen3-asr-1.7b
```

不要为了 STT 修改全局 `OPENAI_BASE_URL`，否则可能改变 Hermes 聊天流量。此方法依据其
OpenAI-compatible 转写调用形状，但尚未在当前环境完成真实 Hermes 消息 smoke；实施时先在
单独配置/进程试运行，再验证聊天功能未受影响。失败时还原这两个 STT 配置并重启 Hermes。

## `voice-realtime`（尚未迁移）

`voice-realtime` 当前仍应使用自己的 WLK / 字幕服务。SpeechRail 的 `/asr` 当前只实现
兼容握手和 EOF，不输出转写 snapshot，不能占用旧 `8001` 端口或替换会议字幕链路。

未来接入有两条路线：

1. 在 `voice-realtime` 独立分支实现 `/v1/realtime` adapter；它应把 16 kHz 单声道 PCM
   append 后 commit，并消费最终 completed 事件。
2. 先完善 SpeechRail legacy adapter、以真实 consumer fixtures 做 WLK parity，再安排
   `/asr` 的兼容切换。

两条路线都需要独立契约、会议闭环和回滚演练。SpeechRail 不会擅自修改
`voice-realtime` 的 AudioHub、会议、TTS、数据库或 UI。

## Realtime 客户端限制

新 WebSocket 客户端发送 `transcription_session.update`、0..N 个
`input_audio_buffer.append`、一次 `input_audio_buffer.commit`。当前服务会把累积音频作为
一次 batch 转写，返回 completed 后结束连接；不会连续发 delta。完整示例和状态机见
[Realtime 契约](../contracts/realtime.md)。
