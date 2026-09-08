---
title: "D1：本机分人运行时选型决定"
status: decided
audience: "由用户指定的模型验证人员"
version: "0.3.0"
date: 2026-09-08
---

# D1：本机分人运行时选型决定

只有这一张卡。此前 V0–V5 六张卡撤回，评分器修复、协议实现、对齐、资源隔离和发布验收回归[实施方案](2026-09-08-diarization-openai-implementation.md)，不再交给用户另外安排人员验证。

本卡已由用户安排执行并完成隔离 runtime smoke。用户基于实测与测试音频的实际判断，选择 A：FluidAudio CoreML FP16。完整依据见[架构方案](../specs/2026-09-08-diarization-clean-architecture-design.md)、[理论与社区证据补充](../specs/2026-09-08-diarization-d1-selection-evidence.md)和[脱敏 runtime smoke 报告](../../archive/performance/2026-09-08-d1-diarization-runtime-smoke.md)。

## 要解决的一个决定

**已决定：Streaming Sortformer v2.1 的 CoreML FP16 实现作为本机唯一生产分人运行时。**

算法族已根据调研选定，不做广泛模型选秀。D1 runtime smoke 已证明 A 在本机可连续运行且运行成本显著优于 B；它没有 RTTM/UEM、DER、ASR 共存、分包或长期测量，因而不构成中文质量或发布批准。这些缺口由实施方案 T4/T8/T9 关闭。

## 已完成结果与决定边界

| 项目 | A：FluidAudio CoreML FP16 | B：NVIDIA NeMo CPU streaming |
|---|---:|---:|
| 90 秒连续输入处理时间 | 7.077 s | 58.549 s |
| RTFx | 12.716 | 1.537 |
| `/usr/bin/time -l` max RSS | 564 MB | 1,862 MB |
| 运行结果 | 成功，1,123 帧、33 个 segment | 成功，1,125 × 4，全部 finite |

固定条件为 M5 Max / 128 GB、`chunk=6`、`left=1`、`right=7`、`fifo=188`、`spkcache=188`、`update=144`、4 slots。A 使用 `v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc` revision `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1` 和 `computeUnits=.all`。A 的处理时间约为 B 的 1/8.3、max RSS 约为 B 的 30%，用户选择 A。

生产代码只实现 A。B 不进入 adapter、worker、配置、依赖或 fallback；它仅保留在 D1 的仓库外可复现实验资产中。A/B 尾部相差两帧（160 ms）尚未裁决，T4 以已知尾部活动 fixture 验证 finish/flush；DER、UEM、ASR 共存、P95、`phys_footprint` 和两小时 soak 留给 T8/T9。

## 有限范围

- A：FluidAudio `balancedV2_1`、CoreML FP16；优先核对 `FluidInference/diar-streaming-sortformer-coreml` 中 `v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc` 的实际 metadata。
- B：NVIDIA `nvidia/diar_streaming_sortformer_4spk-v2.1`，NeMo CPU **原生 streaming**；不是当前 SpeechRail 按 item 调用 `diarize` 的旧路径。
- 参数一致：chunk 6、left 1、right 7、FIFO 188、speaker cache 188、update period 144，前端与后处理逐项记录。若制品 static shape 不匹配，则该制品不合格，不通过改参数假称同源比较。
- 两者使用同一 16 kHz PCM、相同块序列和一次 session 生命周期；不按句重置、不用两个不同的整段 API 比分。
- 不比较 LS-EEND/pyannote/CAM++，不实施生产 adapter，不测完整两小时产品链路，不切换 SpeechRail 常驻服务。

## 交付给执行者的输入

1. 三段既有、经授权、已人工标注 RTTM 的中文音频，每段约 5 分钟：双人轮流与短插话；四人及相似音色；远场含真实 overlap。至少一段含约一分钟静音后同 speaker 返回或晚加入。
2. 总量约 15 分钟，固定 UEM、录音级 split 和匿名 clip ID。只有音频没有真值时，返回 `blocked: missing_reference`；不要扩展为一项语料库建设任务，不用 ASR 或候选模型输出当真值。
3. 参考评分使用固定版本的 `pyannote.metrics`，DER collar=0、计 overlap，整场一次匿名最优匹配；不要依赖尚未修复的 SpeechRail 自定义 CER 评分器。全静音只报 FA 秒数，不给虚假 DER=0。
4. 当前 ASR quality profile 的非敏感固定短音频 workload 和基线计时方法，用于共存对照；基线由同一机器、同一轮实验取得。

输入不足就明确列出缺项，不扩大卡片范围。模型下载、实验运行和维护窗口由用户对执行者安排；不捕获当前真实会议，不擅自启停活跃消费者。

## 执行步骤

1. **锁定实验。** 记录时间、macOS/硬件、库 commit、模型 revision/hash、前端、精度和参数；核对实际制品许可/notice、输入输出 shape、NaN/Inf 校验及本地加载。禁止模型请求路径下载网络资源。
2. **确认持续状态。** A/B 都保留 mel 边缘、FIFO、speaker cache；输出四路活动，提供真实帧起点和稳定边界；finish 补零不计入音频时长。构造连续 PCM 的不同分包方式，确认活动帧位置和尾部长度一致。
3. **跑配对质量。** 先不与 ASR 同跑，在相同三段音频上分别产生匿名 RTTM，统一同一后处理口径评分。输出每段 DER 的 miss/FA/confusion、汇总 DER 和 overlap 时段分量，记录长静音后标签交换。无需逐点浮点完全相等，最终时间轴与质量差异才是判据。
4. **跑有限性能。** 短预热后重复三次固定 workload；冷启动/编译分开记录。使用固定 10 秒音频窗统计分人 RTF P50/P95、总 RTF、进程 phys_footprint 和队列增长。不得把 GPU/ANE 理论吞吐当实测。
5. **已移交 T9 的共存对照。** 后续只比较“ASR 单独”和“ASR + A”；B 不再是生产候选，不为保持 A/B 对称而实现第二条路径。按已授权实验方式串行安排，不创建第二个 SpeechRail 服务。
6. **记录质量与发布边界。** T4/T8/T9 返回 RTTM/UEM、DER、尾部、共存和长期结果；这些结果只决定 A 是否可发布，不重新打开运行时自动选型。

## 判定规则

以下原始门保留为 A 的质量和发布门，不再作为 A/B 自动切换规则。D1 runtime smoke 只完成运行成本比较；测量前固定的质量门由 T4/T8/T9 完成，不能看到结果后放宽。

| 项目 | 判据 |
|---|---|
| 基础正确性 | 无 shape/时轴/非有限输出错误；同源分包无样本漂移；finish 覆盖真实尾部 |
| 转换质量损失 | A 汇总 DER 相对 B 增加 ≤ 1 个百分点；任何单段增加 ≤ 2 个百分点 |
| 基本可用性 | 三段汇总 DER ≤ 25%，且没有可复现的静音后整段身份互换；超出则本次首选未成立 |
| 热态速度 | 10 秒窗的分人 RTF P95 ≤ 0.5，连续输入队列无增长趋势 |
| ASR 共存 | ASR P95 延迟相对同轮基线退化 ≤ 10%；给出绝对毫秒差及重复次数 |
| 精度与设备 | FP16；显式 compute units，记录实际行为；不使用运行期自动换模型或换精度 |

DER 按整场和同一评测口径比较。15 分钟样本只用于发现明显转换损失和本机预算问题；相似小差异不能解释成统计显著的全球排名。若门槛附近波动使结论不稳，报告 `inconclusive` 及实际波动，只请求补充能够解决该歧义的最小样本。

- **运行时决定：** 用户已选择 `selected_coreml_by_owner`；交付精确制品、preset、compute units 和归档 hash。
- **A 发生 shape、BNNS、状态或尾部错误：** 阻断 A 的实现/发布并报告原因；不得暗中切到 NeMo 或另一模型。
- **缺少真值、运行条件或结果不稳：** T4/T8/T9 标记 `blocked` / `inconclusive`，准确说明缺项，不把缺失数据记 0；运行时仍保持 A，直到用户明确重新决策。

## 返回模板

```text
card_id: D1
executed_at:
decision: selected_coreml_by_owner | quality_pending | blocked | inconclusive
hardware_and_os:
asr_profile_and_runtime:
candidate_a_revision_hash_precision_device:
candidate_b_revision_hash_precision_device:
frontend_preset_postprocessing:
dataset_and_uem_fingerprint:
valid_clips_and_duration:
per_clip_der_miss_fa_confusion:
aggregate_der_a_b_delta_pp:
rtf_p50_p95_a_b:
asr_p95_baseline_with_a_with_b:
footprint_and_queue_trend:
timeline_and_finish_checks:
failures_or_missing_evidence:
reproduction_steps:
artifact_hashes:
```

报告只含匿名 ID、聚合指标与指纹。音频、RTTM、全文、模型和原始日志留在仓库外，定位信息单独交付，不在报告写姓名、API key、Base64、embedding 或绝对模型路径。负责人由用户指定，结果回传本方案后只更新运行时决策，不推翻已确定的 OpenAI 公共契约。
