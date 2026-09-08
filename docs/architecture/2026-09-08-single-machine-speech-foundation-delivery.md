---
title: "单机语音基座优化交付审计"
status: active
audience: "项目维护者、评审者、发布负责人"
version: "1.0.0"
date: 2026-09-08
---

# 单机语音基座优化交付审计

本审计对应[优化方案](2026-09-08-single-machine-speech-foundation-optimization.md)，以代码、契约、确定性测试和本机只读探针为依据。它说明计划项是否已有可审查实现；不将未取得的真实模型质量与性能测量写成通过。

## 交付边界

本轮保持单个 ASGI 进程、单个 ASR worker 与单个 TTS worker 的边界。没有下载模型、修改 profile、重启服务或引入云控制面；可回退方式是分别关闭或还原下列四个 PR。

| Issue | PR | 已交付范围 |
|---|---|---|
| [#16](https://github.com/hrygo/SpeechRail/issues/16) | [#20](https://github.com/hrygo/SpeechRail/pull/20) | C1、C3、C4、C5：Realtime session、turn 和 stable partial 语义 |
| [#17](https://github.com/hrygo/SpeechRail/issues/17) | [#21](https://github.com/hrygo/SpeechRail/pull/21) | C2、R2、R3、R4、O1：wire、协议错误、背压、deadline 和阶段指标 |
| [#18](https://github.com/hrygo/SpeechRail/issues/18) | [#22](https://github.com/hrygo/SpeechRail/pull/22) | R1、A1、A2、T1、T2：取消、对齐缓冲、分句和 TTS 参数/缓存 |
| [#19](https://github.com/hrygo/SpeechRail/issues/19) | [#23](https://github.com/hrygo/SpeechRail/pull/23) | D1、U1、S0、S4：能力诊断、连续分人 gate、benchmark 规则与本文 |

PR #21 依赖 #20 的 Realtime 状态机改动，#22 依赖 #21 的 wire 与生命周期改动；#23 以 `main` 为基线。合并时按 #20 → #21 → #22 → #23 的顺序审查，并在组合后的工作树执行完整 gate。

## 计划覆盖矩阵

| ID | 交付证据 | 回归 / 契约证据 |
|---|---|---|
| C1 | #20 的 nested session、24 kHz stateful resampler | Realtime session-format tests |
| C2 | #21 的 versioned current / legacy wire renderer | Realtime audio event literal tests |
| C3 | #20 的缺失/`null`/显式值三态配置更新 | session update preservation tests |
| C4 | #20 的逐 turn 唯一 item ID | multi-commit item correlation tests |
| C5 | #20 的只追加稳定前缀 | rewritten-prefix regression tests |
| R1 | #22 的 abort fallback 与 reload counters | cancellation and next-generation worker tests |
| R2 | #21 的可恢复 JSON error envelope | malformed-event recovery tests |
| R3 | #21 的字节预算、慢消费者 deadline 与 `response.cancel` 控制通道 | hung ASR commit does not block TTS cancellation test |
| R4 | #21 的 ASR commit、TTS 生成与发送总 deadline | hung commit / TTS / slow outbound tests |
| A1 | #22 的 `capture_alignment` opt-in | streaming session capture tests |
| A2 | #22 的有界 40 MiB alignment fallback 与 canonical-text verification | alignment mismatch and timestamp tests |
| T1 | #22 的单一 bounded sentence planner | REST / Realtime delivery planner tests |
| T2 | #22 的容量为 2 的 revision-aware reference LRU；不支持参数稳定拒绝 | cache hit/invalidation and clone parameter tests |
| D1 | #23 的 fail-closed capability diagnosis 和 native probe / evaluation gate | native extension remains absent unless `supports_stream` is verified |
| O1 | #21 的 admission / send phase metrics | metric phase tests |
| U1 | #23 的 `/health`、MCP describe、`speechrail diagnose` 与恢复动作 | CLI and health contract tests |
| S0 | #23 的外部 manifest、隐私和质量证据规则 | benchmark manifest validation tests |
| S4 | #23 的 continuous diarization broadcast gate | extension negotiation capability tests |

上述 18 个方案 ID 都映射到一个 Issue、PR 和自动化证据。`response.cancel` 是唯一允许绕过正在执行 ASR commit 的控制事件：它只修改独立 TTS 生命周期；会改变 ASR turn 状态的事件继续按接收顺序执行，避免并发破坏 item 闭环。

## 本次验证

各 PR 分支在 2026-09-08 均执行过完整静态门：

```bash
env -u SPEECHRAIL_API_KEY uv run --extra dev pytest --no-cov
uv run --extra dev ruff check src tests tools
uv run --extra dev mypy src
npx --no-install @redocly/cli lint contracts/openapi.yaml
git diff --check
```

最近的分支结果为 #21 `1271 passed`、#22 `1260 passed`、#23 `1262 passed`；差异来自彼此尚未合并的独立提交。测试包含 FastAPI fake backend，不声明真实模型质量、RTF、TTFA、DER/JER 或物理内存已通过。

本机只读检查显示已运行服务的 `/health` 和 `/readyz` 可达，quality profile 的 ASR/TTS/diarization 均可按需启动且当时处于 cold-evicted 状态。`tools/probe_diarization_streaming.py` 在开发环境未发现可用的 NeMo streaming 方法，因此连续分人能力继续不广播。这是 fail-closed 结论，不是 native 分人通过。

## 尚未取得的验收证据

真实 TTS short smoke 曾被服务以 `401 invalid_api_key` 拒绝。本审计没有读取私有服务配置或 API key，因此以下项保持 `unset`：

- 三档真实 ASR/TTS 延迟、RTF、内存和音色稳定性；
- VAD 噪声、回声与长稳场景；
- 连续 diarization 的 native CPU smoke、DER/JER、unknown 比例和稳定延迟；
- 真实 OpenAI SDK、Sona、LiveKit / Pipecat 进程级集成。

这些项目的可复现入口和失败关闭条件已在[能力诊断与质量验收](../operations/capability-quality-acceptance.md)定义。获得现有服务的非敏感鉴权后，按该文档使用仓库外 manifest 运行；结果只提交聚合指标和条件，不提交音频、文本、路径或密钥。
