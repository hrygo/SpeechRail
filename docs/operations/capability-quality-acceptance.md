---
title: "SpeechRail 能力诊断与质量验收"
status: active
audience: "本机运维人员、发布负责人、集成工程师"
version: "1.0.3"
date: 2026-09-09
---

# 能力诊断与质量验收

SpeechRail 是单机语音基座。诊断只报告当前可用能力和可复现证据，不读取音频、不显示转写或模型绝对路径，也不会因一次探针下载或加载模型。

## 调用前诊断

先读取 `GET /health`：`asr_ready`、`tts_ready`、`diarization_ready` 分别表示可按需服务；`asr_state`、`tts_state`、`streaming_state` 表示 worker 的当前生命周期；`tts_lifecycle` 在 TTS worker 支持时给出取消是否可协作、回退中止数与重载数；`realtime_vad` 给出配置值、实际解析的引擎、语音准入开关以及 `ready`、`code`、`message`。`realtime_vad.ready=false` 只阻止依赖 `server_vad` 的 Realtime 会话，不改变 ASR、TTS 或 diarization 的核心就绪结论；`code=vad_runtime_missing` 表示服务进程环境缺少 `onnxruntime`，`code=vad_model_missing` 表示 Silero 模型文件不可用。`GET /v1/models` 和 `GET /v1/voices` 说明当前 profile 的 artifact、音色和功能边界；MCP 的 `describe()` 转发同一安全健康字段及模型、音色快照。

不使用 MCP 的终端可运行 `uv run speechrail diagnose`。它只读取上述三个公开端点，输出 profile、readiness、worker 状态、TTS lifecycle、VAD、模型 ID、音色数量、`last_smoke: unset` 与恢复动作；不会输出 API key、参考文本、音频或模型路径。服务启用 key 时，CLI 优先读取 `SPEECHRAIL_API_KEY`，否则自动读取 managed app home 的 `config/.env`，命令不会回显该值。

`GET /readyz` 仍仅表示 ASR 或 TTS 至少一个可用；成功响应中的 `realtime_vad` 是独立的能力诊断，不能把顶层 `ready=true` 当作 `server_vad` 已可用。`backend_busy`、`queue_full` 和 `backend_timeout` 是某次请求的稳定错误，调用方应依据 `retryable` 和 `retry_after` 退避；不要把瞬时忙碌当作全局健康状态。

### 当前 v2.0.3 运行快照

当前 quality managed release 的有效组合为：

| 能力 | 当前事实 |
|---|---|
| Realtime VAD | `auto → silero`，`speech_admission_enabled=true`，`ready=true` |
| Sona subtitle policy | threshold `0.65`、prefix `300ms`、silence `400ms` |
| Sona meeting policy | threshold `0.65`、prefix `300ms`、silence `900ms` |
| diarization | CoreML Sortformer FP16 profile ready；activity 与 endpointing 分离 |
| clone TTS | deterministic seed、clone-only sampling、request-local loudness freeze、peak ceiling、reference signal validation |
| clone speed | 非 `1.0` 明确返回 `clone_speed_unsupported` |

上述 subtitle/meeting policy 是调用方通过 Realtime `session.update` 传入的策略，不是 SpeechRail 把一个全局 VAD 值复制到所有业务。16kHz/512-sample 帧为 32ms，停止边界存在约一帧量化。

先设 `APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"`。恢复顺序固定为：`uv run speechrail service status --app-home "$APP_HOME"` → `uv run speechrail service preflight --app-home "$APP_HOME"` → `curl http://127.0.0.1:8201/health`。带 `--app-home` 的 service CLI 会自动使用 active managed runtime；不需要手工从源码 `.venv` 运行 preflight。若 `realtime_vad.code=vad_runtime_missing`，应修复当前 managed release 并重新发布，再重复 preflight；不要在客户端单独安装 SDK，也不要把已配置的 Silero 模型静默降级成 legacy。若 profile 未配置或 artifact 不可用，再用 `uv run speechrail profile status --app-home "$APP_HOME"` 检查选择状态。诊断中没有“最近 smoke”字段时，结论必须记为 `unset`，不得把历史报告或 `readyz=200` 记作当前质量通过。

## Clone TTS 响度能力

当前 `voice_design` Realtime worker 若启用 clone 响度控制，会在
`session.created.session.speech_capabilities.audio_loudness_profile` 声明
`stable_loudness_v1`；Sona 等客户端据此只保留 peak safety，未声明能力的旧服务走有界
compatibility guard。SpeechRail 的 clone PCM normalization 使用请求级状态，并以私有的
200 ms 缓冲合并稀疏模型 chunk；200 ms 是内部处理边界，不是客户端可依赖的公共 Realtime
delta 大小承诺。

当前代码级 review 修复与脱敏证据见
[2026-09-08 clone TTS 响度验收记录](../archive/performance/2026-09-08-clone-tts-loudness-acceptance.md)。
真实 managed runtime 的 clone 重复生成复测已完成：同一请求连续 3 次输出 hash 一致，输出
24kHz mono PCM16，active RMS 约 `-21.03 dBFS`，peak 约 `-3.81 dBFS`，未发现 chunk 边界点击型突变证据。物理扬声器主观试听和 cancel/interruption 覆盖仍须单独记录；本节不把静态测试或 `readyz=200` 当作完整声音质量通过。

## 外部语料与 benchmark

语料、原始音频、转写和原始 benchmark 结果均在仓库外保存。`examples/perf/benchmark_manifest.py` 强制 manifest 和 fixture 是本地绝对路径、位于仓库外、不是 URL；结果输出也使用新建的仓库外路径并以 `0600` 权限写入。

一个最小 manifest 只保存不含姓名的 fixture ID、语言和外部文件路径，并附带本次实际的 model identity、quality、phase evidence、soak 与 switch 证据。缺失质量或独立评测来源时填 `unset`；不会通过 release gate。

```bash
uv run python examples/perf/bench_profiles.py \
  --base-url http://127.0.0.1:8201 \
  --app-home "${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}" \
  --manifest <absolute-path-outside-repository>/manifest.json \
  --profile quality \
  --phase quality \
  --output <absolute-path-outside-repository>/result.json
```

结果需要同时保留日期、commit、profile、公开模型 identity、硬件摘要、阶段、资源采样完整性和聚合指标。单个退出码、`readyz`、模型存在或旧报告都不足以证明当前的性能、质量、VAD 或长稳通过。

## Diarization profile 与内存证据

`diarization_ready=true` 只表示配置的 profile、文件路径与运行时检查通过，表示服务可以按需
尝试处理；它不表示权重已经驻留，也不证明真实模型质量或物理内存开销。未配置 profile 时不
创建分人模型权重；历史 v1.13.0 基准未包含 diarization，不能据此发布通用的 `+0.5 GB` 数字。

`SPEECHRAIL_WORKER_IDLE_TIMEOUT_SECONDS` 默认是 `300` 秒，设为 `0` 可禁用空闲驱逐。驱逐器
会尝试调用可驱逐组件的 `close()` 并丢弃常驻引用；这不保证操作系统物理内存精确回到固定基线，
尤其是 CoreML/ANE 统一内存的实际回收取决于系统时。若需要发布内存数字，必须在明确的 profile、硬件、
模型快照和请求条件下，用同一时刻的 macOS `phys_footprint` 采样记录活跃与驱逐后的结果，并把
它作为该条件下的 benchmark，不得写成架构不变量。

## 连续分人 gate

当前生产路径是 FluidAudio CoreML FP16 私有 worker。D1 已确认固定制品能 direct-load 并完成 runtime smoke；它不替代后续的真实质量门。先运行只读静态探针：

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
