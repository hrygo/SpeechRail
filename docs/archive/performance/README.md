# 性能基准归档索引 (Performance Baseline Archive)

本目录保存 SpeechRail 历次性能基准与资源监控报告。归档用于追溯测量与版本演进，**最新基线以时序最新的报告为准**；历史报告反映当时版本与运行条件，非当前承诺。

## 最新性能基准（v1.11.0，MINOR 三档）

> **结论**：v1.11.0 已完成 `quality → balanced → light → quality` 的三档真实基准。ASR/TTS N=5、Realtime 3 session、三档 `phys_footprint` 采样和最终 quality 恢复均通过；独立 CER/WER、MOS/ABX 与 speaker embedding 仍为 `unset`。ASR 与 realtime 复用 v1.10.0 的同一 fixture（SHA-256 一致），可直接纵向比较；TTS 采用本轮固定文本集，仅作本版横向。本轮为纯行为/基础设施改动（`/health` 就绪语义、系统路由鉴权、语音克隆原子持久化、流式计时中间件、`voice_class` 指标降基数），未触碰推理模型。详见
> [v1.11.0 性能与质量基准](2026-09-07-v1.11.0-performance-benchmark.md)。

## 上一发布基线（v1.10.0，MINOR 三档）

> **结论**：v1.10.0 已完成 `quality → balanced → light → quality` 的三档真实基准。ASR/TTS N=5、Realtime 3 session、三档 `phys_footprint` 采样和最终 quality 恢复均通过；独立 CER/WER、MOS/ABX 与 speaker embedding 仍为 `unset`。首轮被外部 Sona realtime WebSocket 占用触发的 `backend_busy` 已定位并补入部署/发布/性能 skill 的前置隔离检查。详见
> [v1.10.0 性能与质量基准](2026-09-07-v1.10.0-performance-benchmark.md) 与
> [v1.10.0 发布验收](2026-09-06-v1.10.0-release-acceptance.md)。

> **工具链复验**：同日完成模块化 benchmark、真实资源 monitor、managed wheel 安装和
> `stop → start → ready` 计时；本轮每档为 N=1 warm 观测，正式 release gate 仍保持 `unset`。
> 详见 [v1.10.0 operator efficiency recheck](2026-09-07-v1.10.0-operator-efficiency.md)。

## 历史安装验收（v1.9.2，PATCH quality）

> **结论**：v1.9.2 修复 LaunchAgent 停止真空窗导致的旧 worker 残留、候选误测和
> `worker_load_error` 回滚，并保留同端口单实例与 managed preflight runtime 修复。
> 当前 `quality` 的公共 ASR/TTS smoke、三档切换、profile 身份和第二实例拒绝均通过；
> 完整性能 gate 未打开。详见
> [v1.9.2 性能与运行稳定性基准](2026-09-06-v1.9.2-performance-benchmark.md)。

## 历史安装验收（v1.9.0，MINOR 三档）

> **结论**：v1.9.0 wheel 已完成 managed 安装，`quality` 的公共 ASR/TTS/VoiceDesign
> preview smoke 与一轮真实 warm fixture 均成功；`balanced`、`light` 切换在候选 worker
> 启动 smoke 报 `worker_load_error` 后自动回滚，最终恢复 `quality`。三档性能 gate 未完成，
> 不把历史数字冒充本版本结果。详见
> [v1.9.0 安装与性能验收](2026-09-06-v1.9.0-performance-benchmark.md)。

## 上一发布基线（v1.8.1，PATCH quality）

> **结论**：v1.8.1 按 PATCH 范围仅复测当前 `quality`；公共 ASR/TTS warm N=5 均成功，
> 真实 `phys_footprint` 采样 17/17 tick 完整，稳态 6609.9 MB、同 tick 峰值 7770.1 MB，
> 最终恢复 `quality`。单轮性能差异未设置冻结噪声带，不作代码回归归因。详见
> [v1.8.1 性能与稳定性基准](2026-09-06-v1.8.1-performance-benchmark.md)。

## 历史发布基线（v1.8.0，MINOR 三档）

> **结论**：v1.8.0 已完成三档真实 ASR/TTS/Realtime 与完整物理资源采样，最终恢复
> `quality`。首轮 `balanced → light` smoke 失败后自动回滚，第二次切换通过；SPK-E2E-1
> 完整架构与契约已进入发布 wheel，但连续 native diarization 仍由 `supports_stream` gate
> 保护，当前未广播扩展能力。详见
> [v1.8.0 性能、架构与发布验收报告](2026-09-06-v1.8.0-performance-benchmark.md)。

## 历史发布基线（v1.7.1，PATCH quality）

> **结论**：v1.7.1 修复 profile smoke 的 CustomVoice 空转写误回滚；当前 `quality`
> ASR/TTS 各 N=5、完整物理采样和 `quality → balanced → light → quality` 连续切换均通过。
> 详见 [v1.7.1 性能与稳定性基准](2026-09-05-v1.7.1-performance-benchmark.md)。

## 历史三档研究基线（v1.7.0，MINOR 三档）

> **结论**：v1.7.0 已按 MINOR 规则在同一 Apple M5 Max 上串行测试 `quality`、
> `balanced`、`light`，最大同时物理占用为 6943.9、6085.9、4462.9 MB；每档
> 中英文 ASR 与 TTS 均 5/5。`quality` 的同一输入在进程内和服务重启后 PCM hash
> 一致。后续完整套件加入真人 ASR、Realtime、短时 soak、每档 81 条九角色压力集和
> speaker embedding；`balanced/light` 的同名角色中心高度一致，`quality` 的 VoiceDesign
> 跨文本角色分离较弱，人工 ABX 仍未执行。详见
> [v1.7.0 三档完整本机验收与音色稳定性研究](2026-09-05-v1.7.0-full-three-tier-acceptance.md)。

## 历史发布基线（v1.6.8，发布后重测）

> **结论**：v1.6.8 在发布后的真实服务 runtime 上完成完整 7 步基准，ASR/TTS/Realtime 和 4/8 并发请求全部成功。预热总物理常驻 **9.15 GB**，与 v1.6.7 的 9.17 GB 基本持平；本轮单次压测峰值 **10.36 GB**、并发吞吐 **2.74 req/s**，较历史单次读数更高，暂不据此归因性能回归。详见 [v1.6.8 完整报告](2026-09-05-v1.6.8-performance-benchmark.md)。

| 指标 | v1.6.8（发布后重测） | v1.6.7（修正后重跑） |
|---|---|---|
| 主服务常驻 | **0.54 GB** | 0.54 GB |
| ASR batch 常驻 | **2.50 GB** | 2.51 GB |
| ASR streaming 常驻 | **2.56 GB** | 2.56 GB |
| 总物理常驻 (Idle) | **9.15 GB** | 9.17 GB |
| ASR 超长音频 | 1.38s (35.0s, RTF 0.04x) | 0.90s (34.7s, RTF 0.03x) |
| 并发吞吐 (4w×8, 8s) | 2.74 req/s (P95 1.48s) | 3.97 req/s (P95 1.02s) |
| TTS 长句 (50 字符) | 3.28s (RTF 0.37x) | 2.26s (RTF 0.27x) |
| Realtime commit | 457-592ms（稳定） | 375-395ms（稳定） |
| Realtime TTFA | 44-78ms | 34-41ms |

**运行前提**：本轮是发布后单次完整重测；相对历史单次读数的延迟和峰值差异不单独作为回归结论，长期趋势仍以同口径、静默环境的重复基准为准。

## 报告索引

| 版本 | 报告 | 关键事件 / 说明 |
|---|---|---|
| **v1.10.0 operator** | [2026-09-07-v1.10.0-operator-efficiency.md](2026-09-07-v1.10.0-operator-efficiency.md) | 模块化 benchmark、真实资源采样、managed wheel 安装与停启效率复验；N=1 warm，gate 保持 unset |
| **v1.10.0** | [2026-09-07-v1.10.0-performance-benchmark.md](2026-09-07-v1.10.0-performance-benchmark.md) | MINOR 三档真实性能/资源/Realtime 基准；外部 Sona `backend_busy` 根因与隔离 SOP 已固化 |
| **v1.9.2** | [2026-09-06-v1.9.2-performance-benchmark.md](2026-09-06-v1.9.2-performance-benchmark.md) | PATCH 当前 `quality`；三档切换与停机恢复通过；完整性能 gate 未完成 |
| **v1.9.1** | [2026-09-06-v1.9.1-performance-benchmark.md](2026-09-06-v1.9.1-performance-benchmark.md) | PATCH 当前 `quality`；修复重复服务进程与 smoke 误测；完整性能 gate 未完成 |
| **v1.9.0** | [2026-09-06-v1.9.0-performance-benchmark.md](2026-09-06-v1.9.0-performance-benchmark.md) | MINOR 安装验收；quality 公共推理通过；balanced/light 自动回滚；三档性能 gate 未完成 |
| **v1.8.1** | [2026-09-06-v1.8.1-performance-benchmark.md](2026-09-06-v1.8.1-performance-benchmark.md) | PATCH 当前 `quality` 基准；公共推理与完整 `phys_footprint` 采样；性能噪声带未冻结 |
| **v1.8.0** | [2026-09-06-v1.8.0-performance-benchmark.md](2026-09-06-v1.8.0-performance-benchmark.md) | MINOR 三档真实基准；Voice clone；SPK-E2E-1 完整架构与 fail-closed native gate |
| **v1.7.1** | [2026-09-05-v1.7.1-performance-benchmark.md](2026-09-05-v1.7.1-performance-benchmark.md) | PATCH 当前 `quality` 基准；有界空转写重试；三档切换连续通过 |
| **v1.7.0 完整研究** | [2026-09-05-v1.7.0-full-three-tier-acceptance.md](2026-09-05-v1.7.0-full-three-tier-acceptance.md) | 真人 ASR、3/10/30/60s、Realtime、短时 soak、九角色 243 条生成与 speaker embedding |
| **v1.7.0** | [2026-09-05-v1.7.0-performance-benchmark.md](2026-09-05-v1.7.0-performance-benchmark.md) | MINOR 三档 N=5 基础基准；版本纵向与档位横向对比；加入同文本/跨重启音色稳定性证据 |
| **三档专项** | [2026-09-05-three-tier-feasibility.md](2026-09-05-three-tier-feasibility.md) | 同一共享 runtime 的三档公共 API、准确率代理和完整物理内存采样；结束时恢复 quality |
| **v1.6.8** | [2026-09-05-v1.6.8-performance-benchmark.md](2026-09-05-v1.6.8-performance-benchmark.md) | 发布后完整 7 步重测；总常驻 9.15 GB，单次并发 2.74 req/s；因仅一轮测量暂不改写长期趋势 |
| **v1.6.7** | [2026-09-05-v1.6.7-performance-benchmark.md](2026-09-05-v1.6.7-performance-benchmark.md) | Sortformer 空闲自动卸载，主服务回落 0.54 GB；修复 sample_resources 进程误分类，batch-asr 回真实基线 2.51 GB |
| **v1.6.6** | [2026-09-04-v1.6.6-performance-benchmark.md](2026-09-04-v1.6.6-performance-benchmark.md) | 静默环境重跑为正式基线；流式分人落地（见 ADR-0010） |
| **v1.6.5** | [2026-09-03-v1.6.5-performance-benchmark.md](2026-09-03-v1.6.5-performance-benchmark.md) | TTS/streaming 走 int8，历史最精简内存基线（6.60 GB）；含稳定性探针 [2026-09-04-v1.6.5-stability-probe.md](2026-09-04-v1.6.5-stability-probe.md) |
| **v1.6.3** | [2026-09-03-v1.6.3-performance-benchmark.md](2026-09-03-v1.6.3-performance-benchmark.md) | 修复 `_clear_metal_cache()` 分支排序，ASR 常驻从 v1.6.2 的 4.69 GB 回落 |
| **v1.6.2** | [2026-09-03-v1.6.2-performance-benchmark.md](2026-09-03-v1.6.2-performance-benchmark.md) | 零依赖 Prometheus 指标引擎；金属缓存回归（常驻峰值 10.17 GB） |
| **v1.6.0** | [2026-09-03-v1.6.0-performance-benchmark.md](2026-09-03-v1.6.0-performance-benchmark.md) | 共享权重 realtime 多会话引擎 |
| **v1.5.2** | [2026-09-03-v1.5.2-performance-benchmark.md](2026-09-03-v1.5.2-performance-benchmark.md) | 缺陷修复版：realtime 槽位释放、断开即释放 |
| **v1.5.0** | [2026-09-02-v1.5.0-performance-benchmark.md](2026-09-02-v1.5.0-performance-benchmark.md) | 统一 ASR worker（常驻 7.85 GB，v1.5.2 拆分后回落） |
| **v1.3.1** | [2026-09-02-v1.3.1-performance-benchmark.md](2026-09-02-v1.3.1-performance-benchmark.md) | 早期基线 |
| **首份** | [2026-09-02-baseline-benchmark.md](2026-09-02-baseline-benchmark.md) | 项目首份基准（v1.3 前） |

## 跨版本趋势概览（v1.5.2 → v1.6.7；v1.6.8 暂不纳入趋势）

> 口径提示：v1.5.2 / v1.6.0 / v1.6.2 的 Realtime commit 为**整段一次提交**（2.3-2.7s，8s 级音频），v1.6.3 起改为**窗口化增量提交**（0.3-1.0s），两者不可直接比绝对值；TTS/ASR 单请求延迟在各代内同口径可比较。峰值 CPU 为采样瞬间读数，不代表推理负载。**v1.6.7 修复了 `sample_resources.py` 进程误分类**——此前 native streaming worker 被误归入 batch-asr 导致 batch 常驻虚高；修正后 batch-asr 回真实基线（原本 batch+streaming 为两进程，v1.6.6 及之前同款脚本均受影响，故历史报告 batch-asr 一列为"含 streaming 混叠或未计 streaming"两种口径，trend 表中 v1.6.7 以后的分列 batch/streaming）。

| 指标 | v1.5.2 | v1.6.0 | v1.6.2 | v1.6.3 | v1.6.5 | v1.6.6 | v1.6.7 |
|---|---|---|---|---|---|---|---|
| 主服务常驻 | 0.54 GB | 0.55 GB | 0.54 GB | 0.54 GB | 0.54 GB | 1.08 GB（+Sortformer） | **0.54 GB** ✅ |
| ASR batch 常驻 | 2.54 GB | 2.54 GB | 4.69 GB ❌ | 2.60 GB ✅ | 2.50 GB | 2.50 GB | **2.51 GB** ✅ |
| ASR streaming 常驻 | 未计 | 未计 | 未计 | 未计 | 未计 | 未计 | 2.56 GB |
| TTS 常驻 | 4.94 GB | 4.94 GB | 4.94 GB | 4.94 GB | **3.56 GB**（int8） | 3.56 GB | 3.56 GB |
| 总常驻 | 8.02 GB | 8.02 GB | 10.17 GB ❌ | 8.08 GB | **6.60 GB** | 7.14 GB | 9.17 GB（含 streaming） |
| ASR 10s 级 | ~0.8s | 0.75s | 0.82s | 0.84s | 0.78s | 0.80s | **0.81s**（并发均值） |
| 并发吞吐 | 4.00 req/s | 4.35 req/s | 3.99 req/s | 3.87 req/s | 4.19 req/s | 4.04 req/s | **3.97 req/s** |
| 并发 P95 | 1.00s | 0.90s | 0.98s | 1.02s | 0.94s | 0.99s | **1.02s** |
| TTS 长句 | — | — | — | — | 2.27s | 2.44s | **2.26s** |
| Realtime TTFA | 74-78ms | 44ms | 70-80ms | 45-64ms | 34-44ms | 35-52ms | **34-41ms** |

### 关键演进事件

1. **v1.5.2**：dedicated realtime streaming worker 拆分，总常驻从 v1.5.0 的 7.85 GB（统一 worker）进入 8.02 GB 稳态。
2. **v1.6.2 → v1.6.3**：`_clear_metal_cache()` 分支排序错误（优先已弃用 `mx.metal.clear_cache()`）导致 ASR 常驻 +2.15 GB；v1.6.3 翻转排序后回落基线——一次被完整记录与修复的真实内存回归。
3. **v1.6.5**：TTS/streaming 全面走 int8（3.56 GB），总常驻降至历史最低 6.60 GB；ASR `-8bit` 快照直接加载。
4. **v1.6.6**：仅主服务 +0.54 GB（in-service Sortformer diarization），其余全部指标与 v1.6.5 一致；延迟/吞吐五版本稳定在 4 req/s / P95 ~1s 噪声带内。
5. **v1.6.7**：主服务回落 0.54 GB（Sortformer 空闲自动卸载），回到 v1.6.5 基线；延迟/吞吐与 v1.6.6 一致。**另修复 sample_resources 进程误分类**（native streaming worker 误入 batch-asr 导致 batch 常驻虚高），修正后 batch-asr 回真实基线 2.51 GB，streaming-asr 独立计量。
