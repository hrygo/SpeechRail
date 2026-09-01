# ADR-0009：统一 OpenAI Realtime `/v1/realtime` 并移除 `/v2/realtime`

## Status

Accepted

## Date

2026-09-02

## Context

SpeechRail 曾同时维护 OpenAI-compatible `/v1/realtime` 与 SpeechRail-native `/v2/realtime`。
两套状态机重复实现 ASR/TTS 生命周期、取消、背压和 diarization 边界，增加了测试、文档和
客户端适配成本。`voice-realtime` 已具备 OpenAI 事件客户端，继续保留 v2 不再提供独立的
消费者价值。

## Decision

- `/v1/realtime` 是唯一公共 Realtime WebSocket 入口。
- `/v1/realtime` 承载 OpenAI Realtime ASR/TTS 子集，包括 partial/completed、TTS audio
  delta、取消、背压和可选匿名 diarization。
- 移除 `/v2/realtime`、其专属 domain/session/outbound 实现、公共契约和测试。
- `/v1/realtime` 的 WebSocket 路由只负责认证、解码、序列化和连接清理；生命周期编排留在
  `application`，协议呈现留在 `compatibility`。
- `voice-realtime` 使用 `/v1/realtime` 与 `speechrail-openai-realtime` profile，不再提供
  v2 fallback。

## Consequences

统一协议减少了重复状态机和迁移分支；OpenAI 标准客户端与 `voice-realtime` 共用同一套
契约和测试。旧 v2 客户端必须迁移到 OpenAI 事件模型，无法通过服务端兼容 alias 自动恢复。
历史设计保存在 `docs/archive/`，不作为当前实现依据。
