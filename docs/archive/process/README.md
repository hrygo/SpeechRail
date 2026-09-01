# 过程材料索引

以下文档是实施、评审或迁移过程中的历史记录。它们保留原始上下文，但不应被单独用来证明当前代码已实现或当前服务可发布。

## 已取代方案与审查交接

- [voice-realtime 吸收方案](voice-realtime-absorption.md)：已取代的早期边界/吸收设计。
- [高级工程师审查交接](senior-engineer-handoff.md)：2026-08-31 的审查结论、风险和实施前交接。
- [Realtime legacy 批量协议契约](../realtime-legacy-contract.md)：已退役的
  `/v1/realtime/legacy` 与 `/asr` 端点协议，v1.0.0 移除端点后归档。

## Superpowers 过程目录

### 设计规格

- [初始 SpeechRail 设计](superpowers/specs/2026-08-31-speechrail-design.md)
- [公共 ASR/TTS 运行时最终设计](superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md)
- [公共说话人分离设计](superpowers/specs/2026-09-01-speechrail-diarization-design.md)
- [TTS 迁移与跨项目整洁架构设计](superpowers/specs/2026-09-01-speechrail-tts-migration-design.md)

### 实施计划

- [Foundation 实施计划](superpowers/plans/2026-08-31-speechrail-foundation.md)
- [Realtime v2 实施计划](superpowers/plans/2026-08-31-speechrail-asr-tts-v2-implementation.md)
- [ASR 运行迁移计划](superpowers/plans/2026-08-31-runtime-migration.md)
- [说话人分离实施计划](superpowers/plans/2026-09-01-speechrail-diarization.md)
- [TTS 端到端实施计划](superpowers/plans/2026-09-01-speechrail-tts-end-to-end.md)
- [可执行服务实施计划](superpowers/plans/2026-09-01-executable-service.md)
- [本次文档维护计划](2026-09-01-documentation-maintenance.md)

## 当前正式文档

请改看[架构](../../architecture/README.md)、[用户](../../users/README.md)、[开发者](../../developers/README.md)和[运维](../../operations/README.md)入口；公共协议仍以仓库根目录的 `contracts/` 为准。
