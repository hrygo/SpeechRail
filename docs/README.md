# SpeechRail 文档中心

SpeechRail 的文档按“产品边界 → 公共契约 → 运行实现 → 接入迁移 → 验收”组织。
公共 API 先于具体模型运行时冻结；任何实现变更都必须先检查契约和 ADR。

## 文档地图

| 文档 | 作用 | 状态 |
|---|---|---|
| [产品范围](00-product-scope.md) | 目标、非目标、术语、成功标准 | active |
| [总体架构](01-architecture.md) | 组件、数据流、进程模型、边界 | active |
| [API 契约](02-api-contract.md) | REST、Realtime、错误、版本策略 | active |
| [voice-realtime 吸收方案](03-voice-realtime-absorption.md) | 迁移哪些代码、保留哪些所有权 | active |
| [客户端接入](04-integrations.md) | QwenPaw、voice-realtime、Hermes | active |
| [运行与部署](05-runtime-deployment.md) | 模型、MPS、配置、启动、升级 | active |
| [安全与可观测性](06-security-observability.md) | 认证、隐私、队列、指标、日志 | active |
| [测试与验收](07-testing-acceptance.md) | 契约测试、实机 smoke、发布门禁 | active |
| [迁移 Runbook](08-migration-runbook.md) | 并行运行、切换、回退、退役旧服务 | active |
| [已知边界](09-open-questions.md) | 当前明确决定与剩余风险 | active |

## 设计与执行产物

- [SpeechRail 设计规格](superpowers/specs/2026-08-31-speechrail-design.md)
- [SpeechRail 实施计划](superpowers/plans/2026-08-31-speechrail-foundation.md)
- [ADR 索引](decisions/README.md)

## 证据边界

本项目方案基于 2026-08-31 对以下本机项目和文档的核对：

- `/Users/hrygo/Documents/voice-realtime`：版本 `1.4.0`，当前分支为
  `feature/physical-output-audio`；其 ASR 契约、Qwen3 隔离 worker、WLK 适配和
  `8001` 服务边界是迁移输入，不是 SpeechRail 的最终 API。
- `/Users/hrygo/Documents/QwenPaw`：当前语音转写使用 OpenAI-compatible
  `whisper_api` 形态；本机配置记录的服务地址为 `127.0.0.1:8001/v1`。
- `/Users/hrygo/.hermes/hermes-agent`：版本 `0.20.5`；转写工具使用
  `STT_OPENAI_BASE_URL`、`STT_OPENAI_MODEL` 和 `audio.transcriptions.create`。
- 本机 LM Studio 文档：Qwen3-ASR 运行时不属于 LM Studio 的稳定公共转写接口，
  因此 SpeechRail 将模型运行时与客户端契约解耦。

这些是当前核对结果；运行态、版本、模型快照和网络绑定仍以执行时检查为准。
