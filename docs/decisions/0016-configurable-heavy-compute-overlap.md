---
title: "ADR-0016：可配置的 ASR∥TTS 重计算重叠"
status: accepted
date: 2026-09-11
---

# ADR-0016：可配置的 ASR∥TTS 重计算重叠

## 背景

ADR-0003 要求模型运行时隔离与离线准入，ADR-0011 要求单机共享但有界并行、由 `ResourceGovernor` 防范资源争抢。`ResourceGovernor` 一直对 ASR 与 TTS 的重计算采取互斥准入（`_can_admit` 的串行分支）：只要有一路 ASR 在推理就拒绝 TTS，反之亦然。v2.2.0 基线把这一互斥固定为关闭重叠（见 [v2.4.0 三档基准](../archive/performance/2026-09-11-v2.4.0-performance-benchmark.md)）。

这在 8–16GB 机器上是安全的，但在 32GB+ 机器上浪费可用内存：`quality` 档 ASR（1.7B q8，约 2.60 GiB）+ TTS（1.7B VoiceDesign q8，约 3.07 GiB）+ 分人（CoreML Sortformer FP16，约 0.48 GiB）+ 服务开销约 0.5 GiB，合计约 **6.66 GiB**，远低于这些机器的物理内存。串行执行使一次 TTS 合成阻塞了本可并行的 ASR 请求。

要解决的问题：在**不引入多租户、不复制 worker 进程、不猜测内存**的前提下，让内存足够的机器并行 ASR 与 TTS 的重计算工作。

## 决策

1. 把 ASR∥TTS 重计算重叠从固定行为改为**可配置策略**，以**声明常驻字节 + 物理内存预算**判定，而不是按档位或机器型号硬编码：
   - `SPEECHRAIL_ALLOW_HEAVY_OVERLAP`（`auto` 默认 / `true` / `false`）；
   - 声明键 `SPEECHRAIL_ASR_RESIDENT_BYTES`、`SPEECHRAIL_TTS_RESIDENT_BYTES`、`SPEECHRAIL_DIARIZATION_RESIDENT_BYTES`。
   - `_heavy_overlap_policy` 组装 `ComponentFootprint`（各**启用**组件的声明常驻峰值 + 服务开销），预算为 `budget_for_hardware(host_memory) = max(4 GiB, host_memory // 2)`；`can_overlap_heavy_compute` 判定 `total ≤ budget` 则放行，否则串行，并返回可读 reason。
2. **`auto` 默认 fail-closed**：任一启用组件声明为 0 字节（未知）时，或声明总量超过预算时，均串行；只有全部启用组件都声明了非零峰且总量在预算内才放行重叠。`true` / `false` 是**运维与实验强制**开关，其决定记录在 reason 中，用于受控 A/B 与排障。
3. **重叠轴严格限定为 ASR∥TTS**，不泛化为任意并发：
   - TTS∥TTS 仍受「一个物理 TTS worker」约束，第二个 TTS 留在有界 governor 队列，不进入后端私有锁；
   - ASR∥ASR 仍受「一个共享 ASR worker」约束，batch 与 native streaming 的模式冲突稳定返回 `backend_busy`；
   - 重叠不复制任何 worker 进程，不改变 `total_capacity`、realtime 预留与 batch FIFO/aging，也不取消或抢占已进入推理的工作。
4. 只影响 governor 准入判定；不改模型权重、量化、推理图、worker 协议、档位组成或公共 API 契约。

**Supersedes:** 无。本 ADR 在不改变 ADR-0003 隔离边界与 ADR-0011 有界并行的前提下，收敛它们所约束的「ASR/TTS 互斥准入」实现：由固定互斥改为声明字节 + 预算驱动。

## 迁移

- 无状态迁移。默认 `auto` 在未声明字节时保持串行，与旧行为一致，升级本身安全。
- 要启用在具体机器上的重叠：测量各组件常驻 `phys_footprint` 峰值并写入 `*_RESIDENT_BYTES`，重启后策略自动放行（本机 128 GiB → 预算 64 GiB，声明总量 6.66 GiB，判定 within budget）。
- 反向：不声明或设 `SPEECHRAIL_ALLOW_HEAVY_OVERLAP=false` 即回串行。

## 回滚

- 配置级：`SPEECHRAIL_ALLOW_HEAVY_OVERLAP=false`（或在 `auto` 下清空声明字节）并重启，立即恢复旧串行行为。
- 版本级：按 ADR-0014 回退到上一 managed release。

## 后果

- 内存足够的机器上，TTS 活跃期间可并发放行 ASR。受控 A/B 证据：governor batch 峰值 **1→2**，被放行 ASR 延迟 **~3.78 s → ~0.31 s（≈12×）**，两半 ABBA 复现；顺序与 Realtime 差落在既有噪声带内（见 [v2.4.0 重叠 ON/OFF A/B 对照](../archive/performance/2026-09-11-v2.4.0-overlap-ab.md)）。
- `auto` 对未声明或内存不足的机器保持 fail-closed，不会静默变成并发。
- 预算判定依赖声明方提供真实峰值：声明过低会偏向放行（风险在声明侧，须以实测 `phys_footprint` 为依据）；声明为 0 视为未知并串行。
- 并发只在单 GPU 上发生，可能引入瞬时争用；性能门值须在受控静默环境重复后再冻结，当前保持 `unset`。

## 参考

- [v2.4.0 ASR∥TTS 重计算重叠 ON/OFF A/B 对照](../archive/performance/2026-09-11-v2.4.0-overlap-ab.md)
- [v2.4.0 性能与质量基准](../archive/performance/2026-09-11-v2.4.0-performance-benchmark.md)
- [ADR-0011：统一语音运行时与仅权重分档](0011-unified-runtime-model-tiers.md)、[ADR-0003：模型运行时隔离与离线准入](0003-runtime-isolation.md)
- 代码：`src/speechrail/application/services.py`（`_heavy_overlap_policy`）、`src/speechrail/runtime/model_budget.py`（`budget_for_hardware` / `can_overlap_heavy_compute`）、`src/speechrail/runtime/resource_governor.py`（`allow_heavy_overlap` / `_can_admit`）、`src/speechrail/config/__init__.py`（`allow_heavy_overlap` 与 `*_resident_bytes`）

## 2026-09-12 Amendment — Quality 双 TTS capability 的预算口径

Quality 新增 Base clone artifact 后，**安装体积**会上升，但运行时重模型预算不能简单把
VoiceDesign 与 Base 两套 1.7B TTS 同时相加。`Qwen3TtsCapabilityRouter` 把它们作为一个互斥
TTS 槽：切换 capability 前关闭另一 worker，Base 首次 clone 请求才加载。因此
`SPEECHRAIL_TTS_RESIDENT_BYTES` 应声明“当前可驻留的单个 TTS capability 的可信峰值上界”，并在
VoiceDesign 与 Base 两条路径分别实测后取保守值。

Quality quality-runs 也属于受治理的 `BATCH_TTS` 工作：固定 probe 生成必须经过
`ResourceGovernor` 并受统一绝对 deadline 约束，不能因为它是验收接口就绕开 heavy-compute
准入。后续 ASR intelligibility 复核仍必须在 TTS phase 结束并释放 TTS capability lock 后再进入
ASR phase，避免形成未治理的 Base TTS ∥ ASR 隐式并行。
