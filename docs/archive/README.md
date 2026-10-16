# 文档归档

本目录保存已完成、被取代或仅用于实施过程的材料。归档内容用于追溯决策和工程过程，不是当前运行行为、公共 API 或发布状态的事实来源。

## 过程材料

- [过程材料索引](process/README.md)：实施计划、设计规格、审查交接和被取代的吸收方案。
- [性能基准归档索引](performance/README.md)：历次版本 ASR/TTS/Realtime 基准与资源监控报告及其跨版本趋势（最新基线见 v2.0.3 报告）。
- [Realtime legacy 批量协议契约](realtime-legacy-contract.md)：已退役的
  `/v1/realtime/legacy` 与 `/asr` 端点协议，v1.0.0 移除端点后归档。
- [OpenAI 契约对标历史审查 (openai-conformance-audit.md)](openai-conformance-audit.md)：v1.2.0 时期的历史对标报告，已被 `contracts/realtime-openai.md` 替代。
- [历史运维与迁移说明 (operations/)](operations/)：包含早期架构演进时期的迁移操作手册与运行态评估报告。

## 当前替代入口

- 架构事实：[架构文档](../architecture/README.md)
- 用户与集成：[用户文档](../users/README.md)
- 开发与测试：[开发者文档](../developers/README.md)
- 部署与运行：[运维文档](../operations/README.md)
- 重大决策：[ADR 索引](../decisions/README.md)
