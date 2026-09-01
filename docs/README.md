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
| Qwen3-ASR 本地 worker | 已实现 | 隔离 Python 子进程、离线 snapshot 预检、MPS/`float16` 身份校验 |
| Qwen3-TTS VoiceDesign worker | 已实现并可推理 | 本机已配置外部 runtime/snapshot；`/v1/audio/speech` 实测输出 24 kHz PCM16，真实音质、时延和资源仍按部署验收 |
| REST 文件转写 | 已实现 | OpenAI-compatible `/v1/audio/transcriptions`；真实客户端状态见用户/迁移文档 |
| REST TTS | 已实现并可用（本机已验证） | `/v1/audio/speech` 使用登记 preset；未配置 TTS runtime 时返回 `backend_not_ready` |
| TTS preset 目录 | 路由已注册 | `/v1/voices` 按当前代码应独立返回目录；TTS worker 未就绪时条目标记 `available=false`，运行态 404 先核对进程、端口/base URL 和重启状态 |
| Realtime v1 | 有限实现 | append 后一次 commit 最终转写，不输出 partial delta |
| Realtime v2 | 协议部分实现 | ASR/TTS state machine、背压、取消和 fake-backend 回归已有；真实 worker 闭环仍需验收 |
| legacy `/asr` | 兼容骨架 | 仅 config 与空 PCM EOF/`ready_to_stop`，不进行 ASR，不适合 LAN/公网 |
| `voice-realtime` | 已有 v2/REST 客户端边界 | 会议、播放、UI、数据库和 LLM 仍由调用方拥有；真实端到端发布门另行验收 |
| 常驻服务 | CLI 已实现（macOS） | 通过 `speechrail service install/enable/status/restart/disable/uninstall` 显式管理当前用户 `LaunchAgent`；不会自动安装或启用 |

## 事实来源层级

1. 当前代码、测试和实际运行结果。
2. [OpenAPI 契约](../contracts/openapi.yaml)与 [Realtime 契约](../contracts/realtime.md)、[Realtime v2 契约](../contracts/realtime-v2.md)。
3. [正式架构/用户/开发/运维文档](#先按角色进入)和 [ADR](decisions/README.md)。
4. [归档过程材料](archive/README.md)仅用于历史追溯。

当文档、历史记录和当前实测冲突时，报告差异并以当前实测判断运行状态；不要把计划、配置存在或 `readyz=200` 当作真实模型质量验收。
