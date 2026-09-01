# 用户与集成文档

本目录面向调用 SpeechRail 的用户、客户端和应用集成方。客户端只依赖公共 HTTP/WebSocket 契约，不直接访问模型目录、厂商 SDK 或 worker。

## 推荐阅读顺序

1. [用户与客户端接入](integrations.md)：按 QwenPaw、OpenAI SDK、Hermes 和 `voice-realtime` 选择接入方式。
2. [公共 API 契约](api-contract.md)：确认模型 ID、端点、请求字段、错误和认证行为。
3. [OpenAI Realtime 兼容契约](../../contracts/realtime-openai.md)（标准客户端接入 `/v1/realtime`）或 [Realtime v2 契约](../../contracts/realtime-v2.md)（`/v2/realtime`）：需要 WebSocket 时阅读完整事件顺序和限制。
4. 接入前先完成[运维 Runbook 的健康检查与 smoke](../operations/operations-runbook.md)。

## 当前公共身份

| 能力 | canonical model ID | OpenAI 标准名（alias） | 公共入口 |
|---|---|---|---|
| ASR | `speechrail/qwen3-asr-1.7b` | `whisper-1`、`gpt-4o-transcribe`、`gpt-4o-mini-transcribe` | `/v1/audio/transcriptions`、`/v2/realtime` transcription |
| TTS | `speechrail/qwen3-tts` | `tts-1`、`tts-1-hd`、`gpt-4o-mini-tts` | `/v1/audio/speech`、`/v2/realtime` speech |

客户端可直接使用 OpenAI 标准模型名（如 `whisper-1`、`tts-1`），无需知道底层模型细节；
`/v1/models` 列出 canonical 与全部 alias，alias 条目带 `resolves_to` 标注其 canonical
profile。标准名不代表服务加载 OpenAI 模型，实际推理仍以对应 profile 配置和短音频/短文本
smoke 为准。
