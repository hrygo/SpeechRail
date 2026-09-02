# ADR-0004：保留 WLK `/asr` 作为过渡兼容层

## Status

Superseded by [ADR-0008](0008-remove-legacy-ws-endpoints.md)

## Date

2026-08-31（2026-09-02 由 ADR-0008 取代）

## Context

当前 `sona` 的 `SubtitleStream` 依赖 `/asr?language=...&mode=full`、
`lines`、`buffer_transcription` 和空 PCM EOF。立即要求它切换到新 WS 会把 ASR 服务
迁移与会议/字幕业务改造绑定在同一个发布窗口。

## Decision

SpeechRail 在迁移期提供 legacy `/asr`，内部通过 adapter 生成领域窗口，再序列化为
WLK wire shape。新客户端不再使用该路径；完成所有消费者切换后再按发布周期移除。

## Consequences

- 可以先替换服务进程，降低 QwenPaw/sona 切换风险。
- legacy serializer 必须有 parity fixtures，且不能把 WLK raw JSON 传播到核心层。
- 过渡期同时维护 `/v1/realtime` 和 `/asr` 两个 WS 表面。
