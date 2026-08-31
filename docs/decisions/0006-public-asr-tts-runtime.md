# ADR-0006：SpeechRail 作为公共 ASR/TTS 运行时，voice-realtime 直接迁移 Realtime v2

## Status

Accepted

## Date

2026-08-31

## Review

2026-08-31 高级工程师审查结论为“接受但修改”；本 ADR 已吸收必须修改项，保留原决策方向。

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
- `voice-realtime` 使用一个共享 Realtime v2 client，并分别实现会议/字幕所需的
  `StreamingTranscriber` 与语音助手所需的 `ConversationSTTFactory` adapter；`/asr` 仅短期回滚。
- v2 transcription 以逐句 item completed 和 session terminal event 分离 confirmed 与 EOF；
  v2.0 不做 session 恢复，断线由应用建立新 source epoch 并记录 gap。
- ASR 与 TTS 使用独立 profile 和受控 worker；全局 Resource Governor 通过实时容量预留、
  batch 剩余容量准入和 aging 隔离资源，不采用单一严格全局优先队列。
- TTS 音频块归属于稳定 response ID；取消确认后服务不再产生该 response 的新块，应用仍拥有
  播放、丢弃、打断、会议和 UI。
- async job 使用独立取消和结果删除语义，结果 TTL 从 completed_at 开始，并要求主体隔离、
  容量控制和重启恢复。
- 首发 TTS 只使用预置 voice，不保存或克隆用户声音。

该决策取代 ADR-0005 中“SpeechRail 不负责 TTS”的部分；ADR-0005 关于设备、会议、
LLM、数据库和 UI 所有权的其他结论仍然有效。

## Consequences

- 公共服务新增 TTS 模型、音频输出、job 生命周期、实时调度和更严格的隐私边界。
- `voice-realtime` 的迁移成本集中于一个共享协议 client 和两个窄端口 adapter，而不是 WLK
  协议的长期双维护或一个耦合所有生命周期的万能 adapter。
- 需要先通过真实 streaming/资源可行性门，再固化 worker 拓扑；fake contract 不依赖模型门。
- 需要实现并验收 v2 ASR，再分别以 `voice-realtime` 的语音助手和会议助手作为真实 smoke。
- TTS 迁移可独立、后置，不阻塞 ASR 会议后端迁移。

## Rejected Alternatives

- 扩展 `/v1/realtime`：会改变现有一次 commit/一次 final 的可观察语义。
- 完整复制 WLK `/asr`：把迁移协议固化为长期公共负担。
- 一个万能 `voice-realtime` adapter：无法同时忠实表达会议 EOF/snapshot 与语音助手
  Pipecat processor 生命周期。
- 单一严格全局优先队列：不可抢占推理仍会阻塞实时工作，并可能让 batch 永久饥饿。
- v2.0 服务端透明重连：需要音频 ACK、重放窗口和持久 session，复杂度超过本机服务首发需求。
