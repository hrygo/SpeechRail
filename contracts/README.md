# SpeechRail 公共契约

本目录定义服务接口的预期行为，并保存有声书作品库的 SQLite 结构快照。
实现、测试或实测与契约冲突时，应报告差异，不能静默削弱契约。

## 契约导航

| 文件 | 内容 |
|---|---|
| [openapi.yaml](openapi.yaml) | REST 路径、请求、响应与错误；包括 `/v1/audio/*`、`/v1/voices`、`/v1/voice-designs`、`/v1/jobs`、`/health` 与 `/readyz` |
| [realtime-openai.md](realtime-openai.md) | `/v1/realtime` 的 OpenAI Realtime ASR/TTS 子集、修订窗口转写与 `speechrail.*` 扩展 |
| [realtime-events.schema.json](realtime-events.schema.json) | Realtime 客户端与服务端事件的字段、类型与约束 |
| [realtime-field-matrix.json](realtime-field-matrix.json) | Realtime 字段在校验、任务与适配器之间的责任映射及 fixture 索引 |
| [audiobook-schema/README.md](audiobook-schema/README.md) | 有声书作品库的冻结 DDL 快照、版本递增与校验规则 |

## 接口边界

- OpenAI 兼容语音接口遵循各契约声明的子集；不推断支持 LLM response、tool call 或应用级打断编排。
- SpeechRail 扩展采用契约明确列出的路径、请求头和 `speechrail.*` 事件字段。音色接口位于 `/v1/voices`、`/v1/voice-designs` 等路径，不统一加上 `/v1/speechrail` 前缀。
- Realtime 未声明的字段与事件明确拒绝；会话配置校验失败时保持原配置。
- 分人标签仅在会话内有效，不提供实名身份、跨会话声纹库或持久化 PCM。
- 公共行为变化同步更新契约、相关测试和用户文档。作品库结构变化另须遵守冻结快照与迁移规则。

## 校验入口

在仓库根目录执行；Python 开发依赖须已按锁文件准备。下列检查不代表真实模型质量或真实窗口交互已通过。

```bash
uv run --no-sync --extra dev python scripts/check_openapi_contract.py
uv run --no-sync --extra dev python scripts/check_realtime_contract.py
uv run --no-sync --extra dev python scripts/check_audiobook_schema.py --base-ref origin/main
uv run --no-sync --extra dev pytest --no-cov tests/test_realtime_current_schema.py tests/test_audiobook_schema_contract.py
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests
```

完整开发与验收范围见[测试与验收](../docs/developers/testing-acceptance.md)，调用说明见[用户文档](../docs/users/README.md)。
