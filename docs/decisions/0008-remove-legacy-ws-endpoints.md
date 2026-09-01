# ADR-0008：移除 legacy WS 端点与外部 WLK streaming 后端

## Status

Accepted; superseded by [ADR-0009](0009-openai-realtime-only.md)

## Date

2026-09-02

## Context

ADR-0004 决定保留 WLK `/asr` 作为迁移期过渡兼容层，`/v1/realtime/legacy` 承载旧
append-then-commit batch 协议。v1.0.0 发布前，所有已知消费者（QwenPaw、
`voice-realtime`、Hermes 配置方法）均已切换到 OpenAI-compatible `/v1/realtime`、
`/v2/realtime` 与 REST 路径；ADR-0006 已固定 `/v2/realtime` 为主迁移路线。保留两个
legacy 端点会持续承载认证盲区、无 WLK parity 的骨架行为和历史协议维护成本。

`/v2/realtime` 即将废弃，作为其可选后端的 `SPEECHRAIL_WLK_STREAMING_URL` 外部 sidecar
连接不再有消费者与验收证据，今后不再支持 wlk 后端。

## Decision

v1.0.0 起移除 `WS /asr` 与 `WS /v1/realtime/legacy` 两个公共端点，同时移除：

- 仅服务这两个端点的 `legacy.py`、`realtime_v1.py` 路由与 `realtime/events.py` 会话状态机；
- `compatibility/presenters.py` 中的 legacy wire renderers；
- `legacy_wlk_enabled`、`legacy_query_token_enabled` 配置项与 `LEGACY_WLK` capability；
- 对应契约 `contracts/realtime.md`（归档到 `docs/archive/realtime-legacy-contract.md`）。

同时移除外部 WLK streaming 后端：

- `backends/wlk_streaming.py`、`compatibility/wlk.py` 与 `tests/test_wlk_streaming.py`；
- `wlk_streaming_url` 配置项、validator，以及 `realtime_asr_backend` 的 `wlk` 选项
  （合法值收敛为 `disabled`/`native`）；
- `application/services.py` 中的 WLK factory 注入分支。

## Consequences

- 公共端点缩减为 REST（`/v1/audio/*`、`/v1/models`、`/v1/voices`、`/v1/jobs`）与
  `/v1/realtime`、`/v2/realtime` 两个 WS 表面。
- 旧客户端必须使用 `/v1/realtime`（OpenAI Realtime 兼容）或 `/v2/realtime` 完成转写；
  无过渡兼容层，回归路径按 migration-runbook 与 wheel 回滚流程执行。
- 实时流式 ASR 只使用本地 Qwen3 `native` 后端；外部 WLK endpoint 不再被连接。
- legacy 契约保留在归档区用于历史追溯，不再作为当前行为事实来源。
- ADR-0004 的过渡目标已完成，被本 ADR supersede。
