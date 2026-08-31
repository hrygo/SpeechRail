# ADR-0006：SpeechRail 作为公共 ASR/TTS 运行时，voice-realtime 直接迁移 Realtime v2

## Status

Accepted

## Date

2026-08-31

## Context

SpeechRail 现有 ASR foundation 已证明 Qwen3 batch worker 和 OpenAI-compatible REST 路径。
`voice-realtime` 仍依赖旧 WLK 风格的实时转写，而未来消费者同时需要整句与流式 TTS。
如果完整复制 WLK `/asr` snapshot，会把历史协议变成公共长期负担；如果把 LLM 对话、播放
和会议一起迁入，则会违背独立运行时边界。

## Decision

SpeechRail 提供公共 ASR/TTS runtime：batch REST、async jobs 和 ASR/TTS Realtime v2。它不
提供端到端语音对话、LLM/Agent 编排、设备控制或会议持久化。

- 保持 `/v1/audio/transcriptions`，新增 `/v1/audio/speech` 与受控 batch job resources。
- 现有 `/v1/realtime` 保持兼容；新流式能力使用 `/v2/realtime` 的 `transcription` 与
  `speech` session type。
- `voice-realtime` 新增窄 Realtime v2 adapter，直接迁移到最终协议；`/asr` 仅短期回滚。
- ASR 与 TTS 使用独立 worker/profile 和优先级 lane；应用仍拥有播放、打断、会议和 UI。
- 首发 TTS 只使用预置 voice，不保存或克隆用户声音。

该决策取代 ADR-0005 中“SpeechRail 不负责 TTS”的部分；ADR-0005 关于设备、会议、
LLM、数据库和 UI 所有权的其他结论仍然有效。

## Consequences

- 公共服务新增 TTS 模型、音频输出、job 生命周期、实时调度和更严格的隐私边界。
- `voice-realtime` 的迁移成本集中于一个 adapter，而不是 WLK 协议的长期双维护。
- 需要先实现并验收 v2 ASR，再以 `voice-realtime` 的语音助手和会议助手作为真实 smoke。
- TTS 迁移可独立、后置，不阻塞 ASR 会议后端迁移。
