# 架构文档

本目录是面向架构评审、边界设计和长期维护的正式文档入口。它描述当前服务的职责、实现拓扑、已知限制和不可逆的设计决策；实施计划、审查交接和已取代方案请看[归档区](../archive/README.md)。

## 推荐阅读顺序

1. [产品范围](product-scope.md)：确认 SpeechRail 拥有什么、不拥有什么，以及各类调用方的适配度。
2. [总体架构](architecture.md)：了解请求数据流、进程边界、目录职责和当前/目标行为的区别。
3. [当前边界与剩余风险](current-boundaries.md)：确认已验证能力与未完成的验收门。
4. [架构决策记录](../decisions/README.md)：阅读重大设计选择及其替代方案。

## 事实来源

- REST 的机器可读事实来源是 [OpenAPI 3.1](../../contracts/openapi.yaml)。
- WebSocket 的当前事件事实来源是 [OpenAI Realtime 兼容契约](../../contracts/realtime-openai.md)（`/v1/realtime`）。
- 重大架构理由记录在 [ADR](../decisions/README.md)；本目录不复制 ADR 正文。

## 使用规则

当前代码和契约优先于历史设计。文档中的“验收门”“范围外”或“待实现”表示能力尚未上线；
需要发布判断时，同时核对[开发者测试与验收](../developers/testing-acceptance.md)和
[运维 Runbook](../operations/operations-runbook.md)。
