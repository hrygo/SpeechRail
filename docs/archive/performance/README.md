# 性能基准归档索引 (Performance Baseline Archive)

本目录保存 SpeechRail 历次性能基准与资源监控报告。归档用于追溯测量与版本演进，**最新基线以时序最新的报告为准**；历史报告反映当时版本与运行条件，非当前承诺。

## 最新基线（v1.6.6，静默环境重跑）

> **结论**：v1.6.6 无性能回归，全部核心指标与 v1.6.5 基线一致；唯一静态差异为主服务常驻 +0.54 GB（in-service Sortformer，分人能力功能性成本）。

| 指标 | v1.6.6（静默重跑） | v1.6.5 基线 |
|---|---|---|
| 总物理常驻 (Idle) | 7.14 GB | 6.60 GB（+0.54 GB = Sortformer） |
| ASR batch 常驻 | 2.50 GB | 2.50 GB ✅ |
| 并发吞吐 (4w×8, 9s) | 4.04 req/s (P95 0.99s) | 4.19 req/s (P95 0.94s) ✅ |
| ASR 超长音频 | 0.89s (33.0s, RTF 0.03x) | 0.87s (34.6s, RTF 0.03x) ✅ |
| TTS 长句 (50 字) | 2.44s (RTF 0.28x) | 2.27s (RTF 0.27x) ✅ |
| Realtime commit | 360-435ms | 370-827ms ✅ |
| Realtime TTFA | 35-52ms | 34-44ms ✅ |

**运行前提**：基准须在**无并发负载的静默环境**运行；若同时跑其他大内存进程，ASR 常驻采样与全部延迟数值会被拉高（v1.6.6 首版负载环境实测曾出现 ASR batch 4.34 GB / 并发 1.14 req/s，静默重跑回落至 2.50 GB / 4.04 req/s，归因见 v1.6.6 报告 §6）。

## 报告索引

| 版本 | 报告 | 关键事件 / 说明 |
|---|---|---|
| **v1.6.6** | [2026-09-04-v1.6.6-performance-benchmark.md](2026-09-04-v1.6.6-performance-benchmark.md) | 静默环境重跑为正式基线；流式分人落地（见 ADR-0010） |
| **v1.6.5** | [2026-09-03-v1.6.5-performance-benchmark.md](2026-09-03-v1.6.5-performance-benchmark.md) | TTS/streaming 走 int8，历史最精简内存基线（6.60 GB）；含稳定性探针 [2026-09-04-v1.6.5-stability-probe.md](2026-09-04-v1.6.5-stability-probe.md) |
| **v1.6.3** | [2026-09-03-v1.6.3-performance-benchmark.md](2026-09-03-v1.6.3-performance-benchmark.md) | 修复 `_clear_metal_cache()` 分支排序，ASR 常驻从 v1.6.2 的 4.69 GB 回落 |
| **v1.6.2** | [2026-09-03-v1.6.2-performance-benchmark.md](2026-09-03-v1.6.2-performance-benchmark.md) | 零依赖 Prometheus 指标引擎；金属缓存回归（常驻峰值 10.17 GB） |
| **v1.6.0** | [2026-09-03-v1.6.0-performance-benchmark.md](2026-09-03-v1.6.0-performance-benchmark.md) | 共享权重 realtime 多会话引擎 |
| **v1.5.2** | [2026-09-03-v1.5.2-performance-benchmark.md](2026-09-03-v1.5.2-performance-benchmark.md) | 缺陷修复版：realtime 槽位释放、断开即释放 |
| **v1.5.0** | [2026-09-02-v1.5.0-performance-benchmark.md](2026-09-02-v1.5.0-performance-benchmark.md) | 统一 ASR worker（常驻 7.85 GB，v1.5.2 拆分后回落） |
| **v1.3.1** | [2026-09-02-v1.3.1-performance-benchmark.md](2026-09-02-v1.3.1-performance-benchmark.md) | 早期基线 |
| **首份** | [2026-09-02-baseline-benchmark.md](2026-09-02-baseline-benchmark.md) | 项目首份基准（v1.3 前） |

## 跨版本趋势概览（v1.5.2 → v1.6.6）

> 口径提示：v1.5.2 / v1.6.0 / v1.6.2 的 Realtime commit 为**整段一次提交**（2.3-2.7s，8s 级音频），v1.6.3 起改为**窗口化增量提交**（0.3-1.0s），两者不可直接比绝对值；TTS/ASR 单请求延迟在各代内同口径可比较。峰值 CPU 为采样瞬间读数，不代表推理负载。

| 指标 | v1.5.2 | v1.6.0 | v1.6.2 | v1.6.3 | v1.6.5 | v1.6.6 |
|---|---|---|---|---|---|---|
| 主服务常驻 | 0.54 GB | 0.55 GB | 0.54 GB | 0.54 GB | 0.54 GB | **1.08 GB**（+Sortformer） |
| ASR batch 常驻 | 2.54 GB | 2.54 GB | 4.69 GB ❌ | 2.60 GB ✅ | 2.50 GB | 2.50 GB |
| TTS 常驻 | 4.94 GB | 4.94 GB | 4.94 GB | 4.94 GB | **3.56 GB**（int8） | 3.56 GB |
| 总常驻 | 8.02 GB | 8.02 GB | 10.17 GB ❌ | 8.08 GB | **6.60 GB** | 7.14 GB |
| ASR 10s 级 | ~0.8s | 0.75s | 0.82s | 0.84s | 0.78s | **0.80s** |
| 并发吞吐 | 4.00 req/s | 4.35 req/s | 3.99 req/s | 3.87 req/s | 4.19 req/s | **4.04 req/s** |
| 并发 P95 | 1.00s | 0.90s | 0.98s | 1.02s | 0.94s | **0.99s** |
| TTS 长句 | — | — | — | — | 2.27s | **2.44s** |
| Realtime TTFA | 74-78ms | 44ms | 70-80ms | 45-64ms | 34-44ms | **35-52ms** |

### 关键演进事件

1. **v1.5.2**：dedicated realtime streaming worker 拆分，总常驻从 v1.5.0 的 7.85 GB（统一 worker）进入 8.02 GB 稳态。
2. **v1.6.2 → v1.6.3**：`_clear_metal_cache()` 分支排序错误（优先已弃用 `mx.metal.clear_cache()`）导致 ASR 常驻 +2.15 GB；v1.6.3 翻转排序后回落基线——一次被完整记录与修复的真实内存回归。
3. **v1.6.5**：TTS/streaming 全面走 int8（3.56 GB），总常驻降至历史最低 6.60 GB；ASR `-8bit` 快照直接加载。
4. **v1.6.6**：仅主服务 +0.54 GB（in-service Sortformer diarization），其余全部指标与 v1.6.5 一致；延迟/吞吐五版本稳定在 4 req/s / P95 ~1s 噪声带内。