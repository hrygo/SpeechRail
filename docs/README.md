# SpeechRail 文档中心

本文档中心按读者职责组织正式文档。当前代码与契约优先于历史设计/计划；历史过程材料统一放在[归档区](archive/README.md)，不应被解读为当前功能承诺。

## 先按角色进入

| 读者/任务 | 入口 |
|---|---|
| 评估服务边界、数据流和长期设计 | [架构文档](architecture/README.md) |
| 调用 REST、Realtime 或接入应用 | [用户与集成文档](users/README.md) |
| 修改代码、契约或测试 | [开发者文档](developers/README.md) |
| 部署、启动、排障、升级或回滚 | [运维文档](operations/README.md) |
| 查看重大设计理由 | [ADR 索引](decisions/README.md) |
| 查阅实施计划、设计草案和审查记录 | [过程材料归档](archive/README.md) |

## 当前能力矩阵

| 范围 | 当前结论 | 证据边界 |
|---|---|---|
| Qwen3-ASR 本地 worker | 已实现并可推理 | 隔离 Python 子进程、离线 snapshot 预检、MPS/`float16` 身份校验；本机真实 smoke 通过 |
| Qwen3-TTS VoiceDesign worker | 已实现并可推理 | `/v1/audio/speech` 实测输出 24 kHz PCM16，本机真实 smoke 通过 |
| REST 文件转写 | 已实现并可推理 | OpenAI-compatible `/v1/audio/transcriptions`；本机真实 smoke 与性能基准完成 |
| REST TTS | 已实现并可推理 | `/v1/audio/speech` 使用登记 preset；未配置 TTS runtime 时返回 `backend_not_ready` |
| TTS preset 目录 | 已实现 | `/v1/voices` 返回登记目录，条目含 `aliases`（OpenAI 标准名 → preset）；TTS worker 未就绪时条目标记 `available=false` |
| Realtime v1（OpenAI 兼容） | 已实现并可推理 | `/v1/realtime` 标准 SDK 可接入；ASR/TTS 真实 smoke 与连续会话验证完成 |
| Realtime `/v1`（OpenAI 兼容） | 已实现 | ASR/TTS 事件、背压、取消、native streaming 与匿名 diarization 边界已覆盖 |
| `sona` | 客户端边界已接入 | 会议、播放、UI、数据库和 LLM 由调用方拥有；真实端到端发布门待验收 |
| 常驻服务 | CLI 已实现（macOS） | `speechrail service install/enable/status/restart/disable/uninstall` 管理当前用户 `LaunchAgent`；不自动安装或启用 |

## 事实来源层级

1. 当前代码、测试和实际运行结果。
2. [OpenAPI 契约](../contracts/openapi.yaml)与 [OpenAI Realtime 兼容契约](../contracts/realtime-openai.md)。
3. [正式架构/用户/开发/运维文档](#先按角色进入)和 [ADR](decisions/README.md)。
4. [归档过程材料](archive/README.md)仅用于历史追溯。

当文档、历史记录和当前实测冲突时，以当前代码、测试与运行结果为判断依据；`readyz=200`
只表示推理入口就绪，真实质量验收以对应 smoke 和性能基准为准。
