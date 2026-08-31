# ADR-0002：公共 API 采用 OpenAI-compatible REST 与 Realtime 事件

## Status

Accepted

## Date

2026-08-31

## Context

QwenPaw 当前使用 `whisper_api` 形态，Hermes Agent 使用 OpenAI SDK 的
`audio.transcriptions.create`。两者都已经理解 multipart `/audio/transcriptions`，
为每个客户端再发明一套 API 会增加适配和升级成本。

## Decision

- 文件转写使用 `POST /v1/audio/transcriptions`。
- 模型清单使用 `GET /v1/models`。
- 实时新客户端使用 `/v1/realtime`，事件名对齐 OpenAI transcription session。
- 统一错误 envelope，保留 `code`、`request_id`、`retryable` 扩展字段。
- `voice-realtime` 的 `/asr` 独立标记为 legacy，不污染核心 API。

## Alternatives considered

### 自定义 `/speech-to-text`

语义清楚，但 QwenPaw/Hermes 不能直接复用 SDK，客户端需要额外实现。

### 只提供 WLK `/asr`

能服务当前字幕，但不适合文件型 Agent 客户端，也会把 vendor full snapshot 变成长期公共契约。

### 只提供 REST

无法满足实时字幕、partial 和会议 EOF 需要，因此增加现代 Realtime WS。

## Consequences

- 客户端适配成本低，模型实现细节隐藏。
- OpenAI 兼容字段会成为长期可观察行为，需遵守加法优先和版本策略。
- Realtime 事件需要独立契约测试，不能只验证 REST。
