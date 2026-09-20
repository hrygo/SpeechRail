# MCP 当前契约唯一来源收敛实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 `executing-plans` 按本计划逐项执行；每完成一项更新复选框。

**Goal:** 让 `speechrail-mcp` 只依赖当前 `effective_capabilities_v1` 契约，移除旧服务的静默 discovery fallback，并使音色 revision pin、结构化输出和文档对齐同一条当前路径。

**Architecture:** MCP 仍是无状态 REST 代理；`GET /v1/speechrail/capabilities` 是能力与安全音色目录的唯一原子来源。`/v1/models`、`/v1/voices` 和 `/health` 保留各自当前 REST 资源语义，但不再拼成或替代能力快照。缺失、不可识别或错误的能力契约直接映射为稳定 MCP 错误。

**Tech Stack:** Python 3.12、FastMCP、Pydantic、httpx、pytest、Markdown。

**Spec:** `docs/architecture/speechrail-mcp-proxy.md`

## 全局约束

- 不回退或覆盖工作区已有的并行改动；本次只写 MCP 实现、MCP 测试、MCP active 文档和本计划。
- 保留 OpenAI-compatible `/v1/audio/speech` JSON body；revision pin 继续通过 `SpeechRail-Expected-*` headers 传递。
- `voice_revision=null` 继续表示服务没有可 pin 的稳定身份，不由 MCP 猜测或伪造。
- 不运行 UI automation、真实模型/音频 smoke、benchmark 或服务运行态操作。
- 不提交 commit；交付前报告混合工作区及未验证项。

## Task 1: 先用回归测试固化 current-only 行为

**Files:**

- Modify: `tests/mcp/test_safe_discovery.py`
- Modify: `tests/mcp/test_tools.py`
- Modify: `tests/mcp/test_resources.py`
- Modify: `tests/mcp/test_server.py`（仅在 fixture 受影响时）

- [x] 新增能力路径返回 `404/405` 时必须失败的测试。
- [x] 新增未知 `schema_version` 必须失败的测试。
- [x] 更新 describe 测试，断言不再输出 `legacy_voices`、`voice_discovery_source` 和 `legacy_discovery_consistency`。
- [x] 更新所有 MCP fixture，显式提供有效 `effective_capabilities_v1`，避免测试继续暗示旧 fallback。
- [x] 运行 targeted red test，确认实现尚未满足新契约。

## Task 2: 收敛客户端、工具和结果 schema

**Files:**

- Modify: `src/speechrail/mcp/client.py`
- Modify: `src/speechrail/mcp/tools.py`
- Modify: `src/speechrail/mcp/models.py`
- Modify: `src/speechrail/mcp/server.py`（如工具描述需要同步）

- [x] `fetch_capabilities()` 返回非 optional 的当前快照；`404/405` 原样成为稳定 REST/MCP 错误，未知 schema 映射为稳定 contract error。
- [x] `describe()` 以 effective snapshot 作为 voice discovery 唯一来源，移除 legacy 输出字段。
- [x] `synthesize()` 删除 models/voices legacy fallback，只从当前快照校验 voice、能力、模型和 revision pin。
- [x] 保持显式 revision pin 优先、快照 pin 自动补齐、OpenAI body 和 header 行为不变。
- [x] 让 `DescribeResult` 的 `effective_capabilities` 成为当前契约字段。

## Task 3: 同步 active MCP 文档

**Files:**

- Modify: `docs/architecture/speechrail-mcp-proxy.md`
- Modify: `docs/users/mcp-agent-integration.md`

- [x] 把 effective capability route 写成 MCP 的必需契约。
- [x] 删除 404/405/unknown schema 的 legacy fallback 描述。
- [x] 删除 `legacy_voices`、`voice_discovery_source` 等已移除输出字段的说明。
- [x] 保留并明确 revision pin、`voice_revision=null` 和 conflict 处理语义。
- [x] 用全项目 active 文档检索确认没有 MCP current-only 语义冲突；历史归档只做追溯，不改写。

## Task 4: 验证与交付

- [x] `uv run --extra dev pytest --no-cov tests/mcp -q`
- [x] `uv run --extra dev ruff check src/speechrail/mcp tests/mcp`
- [x] `uv run --extra dev mypy src/speechrail/mcp`
- [x] `git diff --check`
- [x] 检索残留 fallback 代码、字段和 active 文档，人工核对结果模型与 MCP schema。
- [x] 报告实际验证时间、未执行的 UI/运行态验证、并行改动与回退方式。
