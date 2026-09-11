---
title: "SpeechRail 架构优化与演进基线"
status: active
audience: "架构评估者、维护者与后续演进决策者"
version: "1.0"
date: 2026-09-11
---

# SpeechRail 架构优化与演进基线

> 本文是 SpeechRail 的架构优化与**后续演进依据**：界定当前架构基线、与业界最佳实践的对齐判定、
> 待办优化项及其优先级与验收/可证伪条件。所有结论以当前代码、契约与仓库内实测为准。
>
> 证据等级：`[实测]` 仓库内真实基准 · `[契约]` 代码/契约事实 · `[一手]` 外部权威来源（论文/官方文档/WWDC） ·
> `[二手]` 社区测量 · `[推断]` 未证实推理。**结论范围严格受证据等级约束。**

---

## 1. 结论摘要（决策级）

1. **当前运行内核已对齐业界最佳实践**，应保持（§2）。
2. **已具备并已量化验证的关键性能能力**：ASR∥TTS 重计算重叠——v2.4.0 A/B 在 TTS 活跃场景将
   ASR 延迟从 ~3.78 s 降到 ~0.31 s（≈12×）`[实测]`。该能力已是默认 `auto`，不属待办。
3. **realtime 延迟口径须先统一再决策**（P0）：现有「1.8–4.2 s」属 float16/整段提交历史口径，
   当前 MLX-q8 实测 commit p50 为 v1.13.0 **238/349/374 ms**、v2.4.0 **415/548/636 ms** `[实测]`。
   在完成同口径重测前，不得据此判断 finalize 路径的收益。
4. **演进主线**：P0（口径重测 + 文档对齐）→ P1（可观测性、错误码语义、长批工作单元、deflate）→
   P2（条件性项）→ 维护债独立排期（§3、§5）。

---

## 2. 当前架构基线（保持，无需改动）

| # | 基线 | 最佳实践对齐 | 证据 |
|---|---|---|---|
| 1 | MLX-on-Metal 推理引擎 | 自回归解码走 GPU；ANE 仅适合静态形状 | `[契约]`（`qwen3_worker.py:74,945,959`；`pyproject.toml:105-108` 依赖 `mlx`，无 torch） |
| 2 | 子进程物理隔离（`create_subprocess_exec`） | macOS 框架非 fork-safe；崩溃隔离 | `[契约]`（`worker_process.py:123`） |
| 3 | q8 权重、放弃 q4 | 8-bit≈16-bit；q4 需任务级质量门 | `[一手]`+`[实测]`（E1：0.6B 4-bit 劣化 1.38pp > 0.5pp 门） |
| 4 | 单 worker + 稳定 `backend_busy` | 单实例+批处理即可饱和；复制进程只换延迟 | `[一手]`+`[契约]`（`audio.py:1047-1057`） |
| 5 | ASR∥TTS 重叠（`SPEECHRAIL_ALLOW_HEAVY_OVERLAP=auto`） | compute-bound prefill ∥ bandwidth-bound decode 互补 | `[一手]`+`[实测]`（v2.4.0 A/B） |
| 6 | 有界准入 + realtime 预留 + FIFO aging + 稳定 envelope | SRE criticality shedding / Triton rate limiter / 429-503 | `[一手]`+`[契约]`（`admission.py`、`resource_governor.py`） |
| 7 | Realtime 会话治理 | 有界事件队列 + 双通道 + 背压关闭码 | `[契约]`（`http/routes/realtime_openai.py:29,30,33,34,141`：`CLIENT=512`/`CONTROL=16`/`1013` 入口溢出/`1011` 出站慢消费/字节预算） |
| 8 | 零依赖 Prometheus/JSON 可观测底座 | 最小可观测面 | `[契约]`（`metrics.py`） |

> 注：`config` 的 `device="mps"` 是 MLX 的 **Metal 设备字面量**，非 PyTorch-MPS；仓库无 PyTorch 路径。
> 外部「MLX 比 PyTorch-MPS 快 N×」类跨框架数字与本机不符，不作为依据。

---

## 3. 优化与演进项

### 3.1 P0 — 口径与前提（先决，未完成前不得据旧数字决策）

**E1｜Realtime commit 基准重测与口径统一。** `[实测]`
当前 `docs/architecture/current-boundaries.md:38-50` 的「已实测基准（MPS/float16）」表给出
realtime `commit→completed` 为 1.8–4.2 s（`:46`）；同量纲的当前 MLX-q8 实测为 v1.13.0
238/349/374 ms、v2.4.0 415/548/636 ms。归档口径提示：v1.6.3 前的 commit 为「整段一次提交」
（2.3–2.7 s，8 s 级音频），v1.6.3 起为「窗口化增量提交」（0.3–1.0 s），**绝对值不可直接比**。
- 动作：在当前 MLX-q8 档位、16 kHz PCM16、nested profile、≥3 连续会话同口径下重测
  `commit→completed` 的 p50/p95；拆 `feed` vs `finish` 分步直方图；扣除调用方 endpointing
  静默（Sona：subtitle 400 ms / meeting 900 ms）后看纯解码占比。
- 验收：产出可比 p50/p95 与分步证据，作为 E8 判定输入。
- 文件：`docs/architecture/current-boundaries.md`、`docs/archive/performance/`、`observability/metrics.py`。

**E2｜文档口径对齐。** `[契约]`
- 版本三方不一致：`pyproject.toml:3` = **2.4.0**、`docs/README.md` 正文 = 2.3.2、
  `docs/architecture/current-boundaries.md:6` = 2.3.0；统一或标注。
- `current-boundaries.md:38-50` 基准表以当前 MLX-q8 口径重测，或显式标注为历史口径。
- `realtime_max_sessions`：config 默认 **3**（`config/__init__.py:103`），文档写「默认 2」
  （`docs/README.md`）；根因是 `NativeRealtimeFactory` 默认 2（`qwen3_streaming.py:533`）被 config 覆盖。

### 3.2 P1 — 证据充分、低契约风险（可发）

**E3｜可观测性补全。** `[契约]`
在 `speechrail_asr_rtf`（`metrics.py:124,300`）与 `realtime_turn_duration_seconds`（`metrics.py:181,411`）基础上补：
① governor rejection 的 `reason`/`age`（现仅硬编码 `reason="queue_full"`，`metrics.py:420-425`）；
② 明确的 `commit→completed` 分步直方图；③ overlap 预算利用率。
*依据*：vLLM 指标设计规则（指标采集置于内环之外、按 per-request 事件时间戳、进程内用单调时钟）、
Triton 的 rejection-reason 标签、SRE 四金信号。
*文件*：`metrics.py`、`resource_governor.py`、`services.py`。

**E4｜拆分 `backend_busy` 语义。** `[一手]`+`[契约]`
将 `backend_busy` 细分为 mode-conflict / session-limit / worker-dead 三类，并给出可重试性与建议等待；
REST 已有 `Retry-After:1`。*依据*：IETF RateLimit 草案区分 **429=配额** 与 **503+`Retry-After`=资源饱和**；
SRE 教义要求 worker-dead 用可区分的「未就绪不可重试」语义。
*文件*：`audio.py`、`realtime_openai.py:527-531`、`contracts/`。

**E5｜长批工作单元（可抢占式分块）。** `[一手]`+`[契约]`
`qwen3_native.py` 已按 30 s 窗口分块（`:321`），但 `AsrModeGate("batch")` 跨整文件持有
（`:323/:336` 获取，`:334/:342` finally 释放），使实时轮次在长批期间持续 `backend_busy`。
改为**块间释放 mode gate**（或长任务转 `/v1/jobs`）。
*依据*：Orca（OSDI'22）迭代级调度、Sarathi-Serve（OSDI'24）stall-free batching、REEF（OSDI'22）
指出的「工作单元大小才是真正的抢占比」——有界步长可在无内核抢占下保护实时尾延迟。

**E6｜关闭 permessage-deflate。** `[契约]`（`cli.py:59` 未设 `ws_per_message_deflate=False`）。
*注*：受益主要在「数千连接」场景；本项目 ≤3 会话，ROI 边际，随手为之。

### 3.3 P2 — 条件性 / 需先证伪

**E7｜idle eviction 收窄。** `[一手]`+`[实测]`
128 GiB 下驱逐省内存≈0，却付 Metal pipeline 冷编译+页错误税。约束：
① 不改全局默认——README 已公开「Configurable Idle Eviction，默认 300 秒」为产品契约；
② 保留 `light` 8 GB 档的驱逐语义；③ 先实测 idle→active reload wall-clock；
④ 用 **`MTLBinaryArchive`**（Apple Metal 持久化编译缓存，WWDC 实测 86 s→3 s `[一手]`）消除冷编译税，
而非关闭驱逐。可选：仅 ≥64 GB 档启用 `idle_timeout=0` 或内存压力感知。
*文件*：`config/__init__.py`、`services.py`、`qwen3_worker.py`。

**E8｜realtime final 变便宜（依赖 E1）。** `[推断]`
若 E1 证明当前 commit 窗口由 endpointing 静默主导，正确杠杆是 **endpointing / two-pass 策略**，
而非「finalize 全量重解码」——后者的根因在仓库外 `mlx_qwen3_asr`，未经证实。
如需触 finalize 路径，须设 CER 质量门。

**E9｜会话级 ASR state 复用（先证伪）。** `[一手]`
vLLM Automatic Prefix Caching 文档明示 APC 仅加速 prefill、且需真实前缀重复；对 ASR 而言
共享前缀很小（hotword/context preamble），属边际收益。需先测外部 `mlx_qwen3_asr` 是否保留
encoder/KV 且确有跨轮收益，否则不为此建机制。

**E10｜KV 量化（探索）。** `[一手]`
Apple Silicon 推理参考资料将 `--kv-bits` 列为「对 realtime 长会话更划算」的可探索项；
在长会话上先测质量/内存再定。

**E11｜`device_info`/`set_wired_limit`（重估理由）。** `[一手]`
价值不在「6.66 GB ≪ 64 GB」，而在**取代不可靠的 `*_RESIDENT_BYTES` 声明常量**——
overlap gate 依赖声明值 fail-closed（`current-boundaries.md:25`），小机型上的错误声明会误判放行/串行。

**E12｜热节流（thermal）观测。** `[一手]`
resident daemon + 重叠 + 长批是典型持续负载；当前未监视。建议以 `powermetrics`/IOKit 采样
（对应 DCGM 的温度/功耗/throttle-reason 字段分类）。

**E13｜多客户端 aging 重估。** `[契约]`
daemon 由多应用共享（Sona / Open-WebUI / LiveKit / Cherry Studio / OpenClaw / Dify，见 README）；
**「单用户」≠「单客户端」**，长批按到达序仍需 aging，否则可能饿死实时轮次。
*依据*：VTC（OSDI'24）——公平应按「已服务量」而非到达等待度量。

### 3.4 维护债（非性能优化，独立排期）

**E14｜巨型模块治理**：`audio.py` 1702 / `realtime_openai.py` 1683 / `domain/tts.py` 1289 /
`service/model_store.py` 1226 / `backends/qwen3_worker.py` 1223 LOC。`[契约]`

---

## 4. 演进原则（约束）

1. **单 worker、不复制进程**：并发只通过队列、预留与重叠策略解决；TTS∥TTS 与 ASR∥ASR 仍返回 `backend_busy`。
2. **只重叠 ASR∥TTS**：由 `SPEECHRAIL_ALLOW_HEAVY_OVERLAP` 与声明的 `*_RESIDENT_BYTES` 按
   `max(4 GiB, 物理内存 // 2)` 预算 fail-closed 判定（ADR-0016）。
3. **不引入多租户 / 云控制面 / 分布式队列 / 服务网格**：本服务为单机单用户多客户端设计。
4. **不做的方向**（防过度工程，保持 binding）：连续批处理 / Orca-Sarathi 迭代级调度内核 /
   VTC 抢占与迁移 / 服务端 20 ms pacer / jitter buffer / SharedMemory-IOSurface 环缓冲 /
   WebRTC / q4 / 混合精度 / 动态 watermark。
5. **公共契约变更**：破坏性变更进 `/v2` 并附迁移说明；兼容 alias 须有明确废弃计划。
6. **口径先行**：任何性能结论必须标注运行时（MLX/精度）、协议面（nested profile）、测量窗口
   （commit / commit→completed / feed / finish）与音频时长。

---

## 5. 路线图与验收条件

1. **P0**：E1（commit 口径重测 + feed/finish 拆分）∥ E2（版本/基准表对齐）。
2. **P1**：E3（reason/age + commit 直方图）→ E4（`backend_busy` 细分）→ E5（块间释放 mode gate）→ E6（deflate）。
3. **P2**：E7（收窄，先测 reload）→ E8（依 E1）→ E9（先证伪）→ E10 / E11 / E12 / E13。
4. **维护债**：E14 独立排期。

| 议题 | 可证伪条件（未满足则不推进） |
|---|---|
| E8 commit 杠杆 | 若当前 MLX commit 窗口由 endpointing 静默（400–900 ms）主导，则改走 endpointing/two-pass，不触 finalize |
| E7 idle eviction | 若 idle→active reload wall-clock < ~1 s 且重叠峰值逼近 wired 上限，则 eviction 为正收益 |
| E9 state 复用 | ASR 共享前缀命中收益显著才做 |
| E10 KV 量化 | 长会话质量/内存实测通过方可采纳 |
| E12 thermal | 持续负载下观察到明显降频/延迟抬升才专项处理 |

---

## 6. 证据与口径说明

- **本基线所有 realtime 延迟数字均为历史混合口径**，E1 完成前只能作方向性参考：
  - `current-boundaries.md:46`：1.8–4.2 s（RTF 0.18–0.42）——「MPS/float16」表，整段提交时代。
  - README v1.13.0：commit p50 238/349/374 ms、RTF 0.0238–0.0374。
  - v2.4.0（重叠开启、背景负载未控）：commit p50 415/548/636 ms，方向性。
  - 归档口径提示：整段提交（2.3–2.7 s）与窗口化增量（0.3–1.0 s）**不可比绝对值**。
- 内存有多套口径，不得混用：总 warm-idle（4.09/5.48/6.74 GB）、单 worker 常驻
  （1.96/1.96/4.76 GB）、声明总量（6.66 GB）。

### 已核实事实清单

| ID | 事实 | 状态 | 关键证据 |
|---|---|---|---|
| F1 | realtime commit 历史值 1.8–4.2 s 属 float16/整段提交口径 | 已确认 | `current-boundaries.md:38,46` + archive 口径提示 |
| F2 | idle eviction 默认 = 300 s | 已确认 | `config/__init__.py:97`（`worker_lease.py:67` 类默认 900 为死代码） |
| F3 | config `realtime_max_sessions`=3 vs 文档「2」 | 已确认 | `config:103`；`qwen3_streaming.py:533` 工厂默认 2 被覆盖 |
| F4 | 仅 TTS 有 warmup | 已确认 | `config:60`；ASR 无 |
| F5 | `cli.py:59` 未设 deflate | 已确认（代码事实） | ≤3 会话下 ROI 边际 |
| F6 | governor 仅上报 `queue_full` | 已确认 | `metrics.py:420-425` |
| F7 | 错误码映射（AsrModeBusy/queue_full/timeout） | 已确认 | `audio.py:1035-1061`；worker-dead 无独立码 |
| F8 | 每 turn 结束销毁 ASR session | 已确认 | `realtime_openai.py:891-896` ↔ `:1587-1595` |
| F9 | batch 路径跨整文件持有 `AsrModeGate` | 已确认 | `qwen3_native.py:321,323,336` |
| F10 | `:527-531` = backend_busy 用于会话上限/创建失败 | 已确认 | — |
| F11 | 巨型模块 LOC | 已确认 | 逐字吻合 |
| F12 | 版本三方漂移（2.4.0 / 2.3.2 / 2.3.0） | 已确认 | `pyproject.toml:3`、`docs/README.md`、`current-boundaries.md:6` |
| F13 | Realtime 入口治理：512 队列 / 1013 入口溢出 / 1011 出站慢消费 | 已确认 | `http/routes/realtime_openai.py:29,30,33,34,141` |
| F14 | `speechrail_asr_rtf` 存在 | 已确认 | `metrics.py:124,300`；另有 `realtime_turn_duration_seconds` |

---

## 附录 · 主要来源

- **仓库内**：`docs/architecture/current-boundaries.md`、`docs/archive/performance/README.md` 与
  v1.13.0 / v2.4.0 基准、README（benchmark 段）、`src/speechrail/{config,application,backends,runtime,observability,http}/`。
- **外部一手**：
  - 调度：Orca <https://www.usenix.org/conference/osdi22/presentation/yu> ·
    Sarathi-Serve <https://arxiv.org/abs/2403.02310> · vLLM <https://arxiv.org/abs/2309.06180> ·
    SGLang RadixAttention <https://arxiv.org/abs/2312.07104> ·
    REEF <https://www.usenix.org/conference/osdi22/presentation/han> ·
    Llumnix <https://www.usenix.org/conference/osdi24/presentation/sun-biao> ·
    VTC <https://www.usenix.org/conference/osdi24/presentation/sheng>
  - 服务/背压：Triton dynamic batcher 与 rate limiter
    <https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/user_guide/batcher.html> ·
    uvicorn <https://uvicorn.dev/settings/> · Ray Serve
    <https://docs.ray.io/en/latest/serve/configure-serve-deployment.html> · Envoy circuit breaking
    <https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/circuit_breaking> ·
    AWS load shedding
    <https://builder.aws.com/content/3Eun1EEyX6p2e3VYNyRLSJzLuMV/using-load-shedding-to-avoid-overload> ·
    Google SRE <https://sre.google/sre-book/handling-overload/> ·
    IETF RateLimit 草案 <https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-ratelimit-headers>
  - 可观测性：vLLM metrics <https://docs.vllm.ai/en/stable/usage/metrics/> ·
    Prometheus <https://prometheus.io/docs/practices/naming/> ·
    OpenTelemetry Python <https://opentelemetry.io/docs/languages/python/> ·
    NVIDIA DCGM-exporter <https://github.com/NVIDIA/dcgm-exporter> ·
    NVIDIA Riva ASR performance <https://docs.nvidia.com/deeplearning/riva/user-guide/docs/asr/asr-performance.html>
  - 生命周期：Kubernetes Pod lifecycle <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/> ·
    Kubernetes probes <https://kubernetes.io/docs/concepts/workloads/pods/probes/> ·
    vLLM sleep mode <https://docs.vllm.ai/en/stable/features/sleep_mode.html>
  - Apple：`MTLBinaryArchive` 持久化编译（WWDC）
