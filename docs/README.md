# SpeechRail 文档中心

本文档中心按读者职责组织。接口与代码当前状态优先于早期设计/计划；历史文档保留用于
追溯，不应被解读为已完成的功能承诺。

## 先看这里

| 你要做什么 | 阅读路径 |
|---|---|
| 启动服务、调用转写、接入 QwenPaw | [根 README](../README.md) → [用户与集成指南](04-integrations.md) |
| 开发、测试或调整公共接口 | [开发指南](10-development-guide.md) → [API 契约](02-api-contract.md) → [测试与验收](07-testing-acceptance.md) |
| 安装成常驻服务、排障、升级或回滚 | [运维 Runbook](11-operations-runbook.md) → [运行时与部署](05-runtime-deployment.md) → [安全与观测](06-security-observability.md) |
| 评估 realtime、legacy 或跨应用迁移 | [当前边界](09-open-questions.md) → [迁移 Runbook](08-migration-runbook.md) |

## 当前能力矩阵（2026-08-31）

| 范围 | 当前结论 | 证据边界 |
|---|---|---|
| Qwen3-ASR 本地 worker | 已实现 | 单一隔离 Python 子进程、离线 snapshot 预检、MPS/`float16` 身份校验 |
| REST 文件转写 | 已实现并本机冒烟 | OpenAI-compatible `/v1/audio/transcriptions`；QwenPaw 中文短音频已验证 |
| Realtime WS | 协议有限实现 | 只支持 append 后一次 commit 的最终结果，不输出 partial delta |
| legacy `/asr` | 兼容骨架 | 仅 `config` 与空 PCM EOF/`ready_to_stop`；不进行 ASR |
| QwenPaw | 已切换并本机冒烟 | provider 指向 `127.0.0.1:8201/v1`，实际运行配置不写入仓库 |
| Hermes、`voice-realtime` | 未迁移 | 文档提供接入与回滚步骤，尚无真实端到端验收 |
| 常驻服务 | 文档化、未安装 | 提供 `launchd` 模板与步骤；不会自动创建/加载系统服务 |

## 面向用户与集成方

- [产品范围](00-product-scope.md)：服务做什么、不做什么、术语与所有权。
- [公共 API 契约](02-api-contract.md)：REST、模型 ID、认证、错误与版本规则。
- [用户与集成指南](04-integrations.md)：QwenPaw、OpenAI SDK、Hermes 和
  `voice-realtime` 的当前接入状态。
- [Realtime 契约](../contracts/realtime.md)：WebSocket 实际事件顺序与限制。

## 面向开发者

- [高级工程师审查交接](12-senior-engineer-handoff.md)：当前事实、目标方案、风险与审查清单。
- [总体架构](01-architecture.md)：组件边界与数据流；其中未落地的 realtime/WLK 内容均标记为目标设计。
- [开发指南](10-development-guide.md)：本地开发、目录、测试、契约变更与提交前检查。
- [测试与验收](07-testing-acceptance.md)：自动化、真实模型 smoke 与集成验收矩阵。
- [ADR 索引](decisions/README.md)：已采纳的架构决策。

## 面向运维

- [运行时与部署](05-runtime-deployment.md)：模型、worker、配置、端口与启动模型。
- [安全与可观测性](06-security-observability.md)：网络边界、敏感数据、日志与排障信号。
- [运维 Runbook](11-operations-runbook.md)：日常运行、`launchd`、升级、故障处理与回滚。

## 迁移与历史记录

- [公共 ASR/TTS 运行时最终设计](superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md)：
  已接受的目标架构、v2 契约方向、模型策略与 voice-realtime 直迁移方案。
- [voice-realtime 吸收方案](03-voice-realtime-absorption.md)：目标模块边界，非实施完成记录。
- [分阶段迁移 Runbook](08-migration-runbook.md)：未来 Hermes / `voice-realtime` 切换的门禁与回退。
- [当前边界](09-open-questions.md)：未验证项、限制与发布门。
- [设计规格](superpowers/specs/2026-08-31-speechrail-design.md) 与
  [foundation 实施计划](superpowers/plans/2026-08-31-speechrail-foundation.md)：历史设计输入；
  与当前代码冲突时，以当前契约、代码和本页能力矩阵为准。
