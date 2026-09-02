# ADR-0005：应用能力和公共 ASR 能力分开拥有

## Status

Accepted

## Date

2026-08-31

## Context

`sona` 已经拥有 AudioHub 单一麦克风源、会议状态机、Sortformer、PostgreSQL、
TTS、UI、回声抑制和 LM Studio 原生对话链。若迁移时把这些模块一并搬进 SpeechRail，
会形成新的综合 God Service。

## Decision

SpeechRail 只负责“收到音频 → 产生转写事件/结果”。

- 音频采集、回声和 TTS 留在应用。
- 会议事实源、speaker mapping、SRT/数据库留在 `sona`。
- Agent prompt、session、权限和聊天模型留在 QwenPaw/Hermes。
- SpeechRail 只输出可验证的 segment/speaker optional metadata。

## Consequences

- SpeechRail 可独立测试和部署。
- 会议服务仍需要一个轻量 client adapter。
- 说话人分离增强不自动成为所有客户端的默认成本。
