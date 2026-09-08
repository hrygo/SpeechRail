---
title: "SpeechRail 能力诊断与质量验收"
status: active
audience: "本机运维人员、发布负责人、集成工程师"
version: "1.0.0"
date: 2026-09-08
---

# 能力诊断与质量验收

SpeechRail 是单机语音基座。诊断只报告当前可用能力和可复现证据，不读取音频、不显示转写或模型绝对路径，也不会因一次探针下载或加载模型。

## 调用前诊断

先读取 `GET /health`：`asr_ready`、`tts_ready`、`diarization_ready` 分别表示可按需服务；`asr_state`、`tts_state`、`streaming_state` 表示 worker 的当前生命周期；`realtime_vad` 给出配置值、实际解析的引擎和语音准入是否启用。`GET /v1/models` 和 `GET /v1/voices` 说明当前 profile 的 artifact、音色和功能边界，MCP 使用 `describe()` 获得同一快照。

不使用 MCP 的终端可运行 `uv run speechrail diagnose`。它只读取上述三个公开端点，输出 profile、readiness、worker 状态、VAD、模型 ID、音色数量、`last_smoke: unset` 与恢复动作；不会输出 API key、参考文本、音频或模型路径。服务启用 key 时可通过现有 `SPEECHRAIL_API_KEY` 环境变量鉴权，命令不会回显该值。

`GET /readyz` 仅表示 ASR 或 TTS 至少一个可用，不能替代上述逐项检查。`backend_busy`、`queue_full` 和 `backend_timeout` 是某次请求的稳定错误，调用方应依据 `retryable` 和 `retry_after` 退避；不要把瞬时忙碌当作全局健康状态。

恢复顺序固定为：`uv run speechrail service status` → `uv run speechrail service preflight` → `curl http://127.0.0.1:8201/health`。若 profile 未配置或 artifact 不可用，再用 `uv run speechrail profile status` 检查选择状态。诊断中没有“最近 smoke”字段时，结论必须记为 `unset`，不得把历史报告或 `readyz=200` 记作当前质量通过。

## 外部语料与 benchmark

语料、原始音频、转写和原始 benchmark 结果均在仓库外保存。`examples/perf/benchmark_manifest.py` 强制 manifest 和 fixture 是本地绝对路径、位于仓库外、不是 URL；结果输出也使用新建的仓库外路径并以 `0600` 权限写入。

一个最小 manifest 只保存不含姓名的 fixture ID、语言和外部文件路径，并附带本次实际的 model identity、quality、phase evidence、soak 与 switch 证据。缺失质量或独立评测来源时填 `unset`；不会通过 release gate。

```bash
uv run python examples/perf/bench_profiles.py \
  --base-url http://127.0.0.1:8201 \
  --manifest <absolute-path-outside-repository>/manifest.json \
  --profile quality \
  --phase quality \
  --output <absolute-path-outside-repository>/result.json
```

结果需要同时保留日期、commit、profile、公开模型 identity、硬件摘要、阶段、资源采样完整性和聚合指标。单个退出码、`readyz`、模型存在或旧报告都不足以证明当前的性能、质量、VAD 或长稳通过。

## 连续分人 gate

当前生产 `NemoSortformerEngine.supports_stream` 为 `False`，因此不会广播或接受 `speechrail.diarization.v1` 的连续 native 能力。先运行只读静态探针：

```bash
uv run python tools/probe_diarization_streaming.py
```

探针返回 `candidate` 仍不是可用能力。只有版本和方法面确认后，在获授权的本机模型环境中完成 CPU smoke、DER/JER、重叠比例、unknown 比例、稳定延迟和 finalize 回归，才可将连续能力改为可广播。DER 与匿名归属质量使用仓库外、授权且 `tune`/`eval` 隔离的 manifest 运行：

```bash
uv run python tools/evaluate_diarization_e2e.py \
  --manifest <absolute-path-outside-repository>/diarization-eval.json \
  --split eval \
  --output <absolute-path-outside-repository>/diarization-result.json
```

报告只应提交聚合值、manifest SHA-256 与测试条件；不得提交原始音频、文本、路径或真实讲话人身份。
