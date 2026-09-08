---
title: "D1 选型证据补充：Streaming Sortformer 的理论与社区调研"
status: decision-supported
audience: "D1 验证人员、架构评审与实施者"
version: "1.1.0"
date: 2026-09-08
---

# D1 选型证据补充：Streaming Sortformer 的理论与社区调研

本材料支撑 [D1 本机分人运行时选型决定](../plans/2026-09-08-diarization-validation-cards.md)。用户已根据 D1 runtime smoke 和测试音频的实际判断选择 A；本文件保留理论、社区与未完成质量门的理由，不能将后续验收扩大为多模型横评。

## 结论

已确定：**Streaming Sortformer v2.1 的 FluidAudio CoreML FP16 是当前 1–4 人、低延迟、匿名本机分人的唯一生产运行时。** NeMo 原生 streaming 保留为已完成 D1 的算法语义和运行成本对照，不进入产品代码。

此次选择的直接实测是：固定 90 秒、单一连续 session、同一 preset 下，CoreML 为 7.077 s / RTFx 12.716 / max RSS 564 MB，NeMo CPU 为 58.549 s / 1.537 / 1,862 MB。它表明 CoreML 在本机运行成本上显著更优；没有 RTTM/UEM，不能证明 DER 或中文质量更优。CoreML 是第三方转换和状态实现，T4/T8/T9 仍须以同一中文真值、持续状态和后处理口径验收 A 本身。

不受 D1 影响的架构结论是：声学输出必须是连续状态流，固定正文必须经对齐而非二次 ASR，文件与 Realtime 必须共用同一条流式声学链路。D1 只选择唯一 production adapter。

## 1. 理论：为什么状态不可省略

Streaming Sortformer 每 80 ms 输出四路独立 sigmoid 活动；同一帧可有多个活跃说话人。论文说明它从 10 ms Mel 特征经 8 倍下采样得到 80 ms 输出，并以到达顺序排序 speaker 槽位。[Streaming Sortformer 论文](https://www.isca-archive.org/interspeech_2025/medennikov25_interspeech.pdf)

因此实现不能对四路分数做 softmax、只保留一个 `(speaker, confidence)`，也不能用 VAD 将 overlap 压为单标签。文本主 speaker 只是 API 投影，不能倒灌为声学模型约束。

更关键的是，推理不是独立的 `P_n = model(C_n)`。每块之前要由前次预测更新 AOSC speaker cache，FIFO 还提供近期上下文；AOSC 以到达顺序保存高分 embedding，解决跨块 permutation，FIFO 缓解短块上下文不足。每段重置、整段 `diarize` 或只验证一次 CoreML `predict` 都不是 Streaming Sortformer。论文方法明确把 AOSC、FIFO 和当前块一起送入模型。[论文的缓存机制](https://www.isca-archive.org/interspeech_2025/medennikov25_interspeech.pdf)

低延迟参数 `chunk=6/right=7/FIFO=188/update=144/cache=188` 来自 NVIDIA；其中 1.04 秒是输入缓冲，未计计算、排队、IPC 或 ASR 共存时间。其 RTF 在 RTX 6000 Ada 上测得，不能外推到 M5 Max。[NVIDIA 模型卡](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1)

这也解释了为何 session-scoped A–D、无跨会议 embedding 是正确边界：AOSC 维护当前 session 的 slot continuity，不是身份识别。模型最多四个槽位；论文对五人以上的观察是“追踪四个主导 speaker”，不能被改写成任意人数支持。

## 2. 中文：有训练依据，但没有免测结论

论文训练材料包含 AISHELL-4 和 AliMeeting 的近讲/远讲录音；但 NVIDIA v2.1 模型卡说明训练语料主要是英语，且非英语与 out-of-domain 条件可能退化。[论文训练集](https://www.isca-archive.org/interspeech_2025/medennikov25_interspeech.pdf)、[NVIDIA 技术限制](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1)

这并不冲突：包含中文数据不等于中文占比、远场条件或标注边界构成质量保证。D1 使用人工 RTTM 的中文 2 人、4 人和 overlap 样本是必要条件；英文公开 DER 不能替代。

## 3. 社区工程信号

| 信号 | 支持的判断 | 不能推出 |
|---|---|---|
| NVIDIA 论文和模型卡 | 四独立活动槽位、持续状态、低延迟参数有一手依据 | GPU RTF 或英文 DER 等于 M5 Max / 中文结果 |
| NeMo issue #15918（2026-07，等待维护者） | 使用者仍需自行基于 `streaming_forward_step()` 拼接逐块 API 和前端；NeMo 更适合作为语义参考 | NeMo 无法实现 worker |
| NeMo issue #15077 | streaming 模型有动态 slicing，静态图导出存在工程风险 | 任意 CoreML 转换必错 |
| FluidAudio v3 说明 | v3 为修复旧制品的 BNNS input/output alias 重建，维护者声称可 `.all` 加载 | 已证明 M5 Max DER、长会话稳定性或 MLX 共存 |

NeMo 的公开社区讨论见 [issue #15918](https://github.com/NVIDIA-NeMo/Speech/issues/15918)，动态 export 风险见 [issue #15077](https://github.com/NVIDIA-NeMo/Speech/issues/15077)。这些证据支持“CoreML 先测、NeMo 作参考”，不代替 D1。

## 4. 当前 CoreML 制品的可验证事实

2026-09-08 只读检查 Hugging Face 当前 main：CoreML repo revision 为 `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`，NVIDIA 权重 repo revision 为 `fafaab5faa1617a0ca52d38dd3dc4bd636800d3d`。

`v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc` 确实存在。其实际两段 MIL 图要求 `chunk=[1,112,128]`、`fifo=[1,188,512]`、`spkcache=[1,188,512]`，head 的 `pre_encoder_embs=[1,390,512]`，实际 `speaker_preds=[1,390,4]`。

同一模型卡的 shape 表将 NVIDIA Low 的 `speaker_preds` 写为 `[1,390,128]`，与实际图矛盾；128 是 Mel 特征维，4 才是 speaker 槽位数。因此 D1 必须以制品 metadata/MIL 与一次实际 `MLModel` 加载为准，禁止根据模型卡表格分配输出 array。公开入口：[CoreML 模型卡](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml)、[v3 README](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml/resolve/main/v3/README.md)、[NVIDIA Low head MIL](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml/resolve/main/v3/fp16/SortformerNvidiaLow_v2.1.mlmodelc/model1/model.mil)。`main` 可变化，执行时仍要记录整包 hash。

## 5. D1 的诊断顺序和结论边界

原卡门槛保持不变；按如下顺序防止把系统错误误诊为 DER 差异：

1. 制品/语义：实际 shape、dtype、compute units、AOSC/FIFO 参数、NaN、tail flush。任一失败直接淘汰。
2. 分包不变性：相同 PCM 用 20 ms、480 ms、随机合法分包重放；比较真实时轴、stable watermark、尾帧与 final segment。允许浮点微差，不允许系统性丢尾、漂移或重置 session。
3. 状态轨迹：单人→静音→返回、A/B 轮换、overlap、第三/第四人晚加入；输出 cache/FIFO 长度、first-seen 槽位与 final 标签轨迹。它定位状态错误，不替代 RTTM DER。
4. 配对质量：A/B 共享中文 RTTM、UEM、collar=0、overlap 和后处理；按录音独立匿名映射，报告 miss/FA/confusion。DER 的分量与 UEM/overlap 语义见 [pyannote.metrics](https://pyannote.github.io/pyannote-metrics/basics.html)。
5. 运行时：cold/warm 分开，分别记录输入缓冲、计算、队列、IPC 与 ASR 共存开销。

三段约 15 分钟的 D1 是工程淘汰试验：可以筛掉错误转换、明显质量损失和本机性能不可用；不能证明 1 个百分点差异具有普适统计意义。报告除原卡数字外增加每录音配对 DER 差 `A−B`、分量差和 recording-level bootstrap 区间。区间跨零或门槛时结论为 `inconclusive`，由 T9 固定 eval 集决定发布，不能事后挑选片段。

| D1 结果 | 解读与动作 |
|---|---|
| CoreML 通过所有门 | 锁定 v3 FP16 的精确制品与 runtime commit，进入 T9 正式验收 |
| CoreML 在 shape、BNNS、状态或尾部失败 | 是转换集成失败；阻断 A 的实现/发布并报告，不能自动切到 NeMo |
| 两端主要 miss 高 | 报告中文/quiet/distant 风险，不能事后调阈值制造通过 |
| overlap/confusion 高而时钟正确 | 共同 policy 仅在预先锁定 tune 集校准，再重跑，不对 A/B 分别调优 |
| 第五人、跨会话身份或姓名需求 | 超出本次产品范围，另行决策，不能由 D1 外推 |

调研停止条件：一手论文、权重模型卡、当前制品、NeMo 社区问题、转换维护者说明和评测标准已覆盖理论正确性、运行时可行性、中文局限、社区风险和 D1 可比性。新增同类博客或论坛无法替代 M5 Max 配对实验。
