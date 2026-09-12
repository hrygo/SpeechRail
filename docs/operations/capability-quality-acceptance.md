---
title: "SpeechRail 能力诊断与质量验收"
status: active
audience: "本机运维人员、发布负责人、集成工程师"
version: "1.0.5"
date: 2026-09-11
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

## 三档能力门控与按档位精度

三档的公共 API 形状一致，但按档位门控分人制品与精度策略（完整组成见[运行时与部署](runtime-deployment.md)）：

| 能力 | `light` | `balanced` | `quality` |
|---|---|---|---|
| batch / realtime / segment + word timestamps | ✓ | ✓ | ✓ |
| diarization（`gpt-4o-transcribe-diarize`） | ✗ | ✓ | ✓ |
| aligner（分人专用） | — | `aligner-q8` | `aligner-bf16` |
| 精度策略 | 8-bit ASR/TTS | 8-bit ASR/TTS | 8-bit ASR/TTS，aligner bf16 |

- **diarization 门控**：只有 `balanced` / `quality` 供给 CoreML Sortformer 与 aligner，因此仅这两档声明
  `gpt-4o-transcribe-diarize`；`light` 不声明，`/v1/models` 中不出现该别名。
- **aligner 是分人专用制品**：由安装器与 `profile apply` 供给到 `app_home/diarization/<aligner-key>`，只服务
  分人对固定正文的对齐；它不进入 `PreparedModelSet`，也不参与词级时间戳。
- **词级时间戳由 ASR 原生提供**（`timestamp_granularities`），三档均可用，与 aligner 是否存在无关。
- `diarization_ready` 是动态能力声明：该档未启用分人时不存在，不得用 `readyz=200` 推断分人可用。
- **E1 结果（2026-09-11）**：公开真人语料实测 light 的 0.6B 4-bit ASR 相对 8-bit 基线劣化
  **1.38pp**（en WER +1.25pp、zh CER +1.46pp）> 0.5pp 阈值，**E1 FAILED**；依计划「未过即回退
  上一精度」，light 回退 `asr-0.6b-q8` + `tts-0.6b-custom-q8`（8-bit）。因此 E2 不再对 light 构成
  门控；`asr-0.6b-q4` / `tts-0.6b-custom-q4` 制品保留在 catalog 但不被任何档位使用。

## Clone TTS 响度能力

当前 Quality Realtime 在独立 Base clone capability 实际配置时，通过
`session.created.session.speech_capabilities.supports_clone=true` 声明可用性，并同时声明
`audio_loudness_profile=stable_loudness_v1`。默认 TTS `variant` 仍可为 `voice_design`；客户端不能再由
默认 variant 推断 clone。clone voice 请求由 capability router 按需切换到 Base。SpeechRail 的 clone PCM
normalization 使用请求级状态，并以私有 200 ms 缓冲合并稀疏模型 chunk；200 ms 是内部处理边界，
不是客户端可依赖的公共 Realtime delta 大小承诺。

当前代码级 review 修复与脱敏证据见
[2026-09-08 clone TTS 响度验收记录](../archive/performance/2026-09-08-clone-tts-loudness-acceptance.md)。
下述真实 managed runtime clone 数据来自旧 VoiceDesign-only 基线：同一请求连续 3 次输出 hash 一致，输出
24kHz mono PCM16，active RMS 约 `-21.03 dBFS`，peak 约 `-3.81 dBFS`。它不能外推为新的 Base clone
capability 实测。新架构仍需在目标 Apple Silicon 上重做跨文本 speaker identity、切换冷启动、峰值 RSS、
物理试听及 cancel/interruption 验收；本节不把静态测试或 `readyz=200` 当作完整声音质量通过。

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

## 三档重排验收门（E1–E7）

三档重排与按档位精度策略以可证伪的验收门收口；任一档未过则该档回退上一精度。若某门缺少工具，必须先补齐或在
记录中显式标注 `UNVERIFIED-BLOCKING`，不得留空阈值：

| 门 | 范围 | 通过条件 |
|---|---|---|
| E1 | ASR 精度 | 固定 fixture 上 `asr-0.6b-q4` vs `asr-0.6b-q8` 的 CER/WER 绝对增幅 ≤ 0.5pp；命令与报告路径写入记录 |
| E2 | TTS 质量 | 用既有 `voice_quality_v1` 客观指标（与 `tests/test_voice_quality_metrics.py` 同源）比较 `tts-0.6b-custom-q4` vs `q8`，不劣化超过既定阈值；不使用未实测的 MOS/ABX |
| E3 | 分人/对齐 | `tools/evaluate_diarization_e2e.py` 上 `aligner-q8` vs `aligner-bf16` 的 DER/SACER 不劣化（阈值写入记录）|
| E4 | 资源包络 | 三档实测 `phys_footprint` 分别 ≤ light 8GB / balanced 16GB / quality 32GB 目标包络 |
| E5 | 切换闭环 | `quality → balanced → light → quality` 热切换，每步 `/health` 正确、分人状态正确 |
| E6 | 能力诚实 | `light` 的 `/v1/models` 不含 `gpt-4o-transcribe-diarize`；`balanced`/`quality` 含且可用 |
| E7 | 记录 | 聚合证据写入 `docs/operations/<日期>-tier-repositioning-acceptance.md`，不落原始媒体/文本 |

E1–E7 全过前，不得把任一档的新精度组合记作已验收；结果必须与实测证据一致。
