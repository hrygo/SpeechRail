# 开发者文档

本目录面向修改 SpeechRail、扩展公共契约或维护测试门禁的开发者。公共行为先看契约，再看实现和测试；不要把调用方应用的会议、播放、UI、数据库或 LLM 责任搬入本仓库。

## 推荐阅读顺序

1. [开发指南](development-guide.md)：本地环境、目录职责、契约变更和提交要求。
2. [公共 API 契约说明](../users/api-contract.md)以及仓库根目录的 [OpenAPI](../../contracts/openapi.yaml) 和 [Realtime 契约](../../contracts/realtime-v2.md)。
3. [测试与验收](testing-acceptance.md)：确定性测试、真实 worker smoke 和集成验收矩阵。
4. [架构决策记录](../decisions/README.md)：了解不能在实现阶段重复决策的边界。

## 变更边界

- `/v1` 的兼容扩展必须同步更新契约、实现、测试和用户文档。
- 破坏性 REST/WS 行为进入 `/v2`，并提供迁移说明和回滚路径。
- 模型、音频、prompt、凭据和完整转写不得进入仓库、日志或测试 fixture。
- 归档的实施计划只提供历史上下文，不是当前实现清单；当前能力以代码、契约和正式文档为准。
