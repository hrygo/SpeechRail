---
title: "会议分人整场上下文算法诊断报告"
status: active
version: "1.2.0"
date: 2026-10-17
---

# 会议分人整场上下文算法诊断报告

核验日期为 2026-10-17（Asia/Shanghai）。目标是判断 AISHELL-4 开发集分人失败是否主要由滚动窗口、跨窗身份匹配、预处理或 VBx 参数引起；本报告记录的是开发集诊断，不是生产验收。

## 范围与固定条件

- 只使用锁定的 8 场 R003 开发集，manifest SHA-256 为 `ff3df5d28862fb5c2c73f597a98d4e204248121fc39994b412cf0513968c01cd`。R004 留出集未读取或参与调参。
- 固定本地模型 revision `7eab74f3463c736418d0eb10296261ae581146c9` 和 FluidAudio SDK revision `5c19d5e12320e22bbfb7a1877b089d2665a69add`；使用本地编译好的 CoreML 模型与 PLDA 参数，不下载、不编译模型。
- 预处理筛选四种配置：`stepRatio` 为 0.2 或 0.1，`minSegmentDurationSeconds` 为 1.0 或 0.0；每场每种配置只准备一次分段与 embedding，再复用到七种 clustering/VBx 配置，共 28 个组合。
- `zeroVoteReembed` 关闭。说话人标签匿名化，原始音频、参考标注和逐场中间结果均保留在仓库外。
- 评分器仍为 `pyannote.metrics 4.1`，质量门槛保持已定契约：逐场 known coverage ≥90%、known accuracy ≥95%、top-four 最低 known coverage ≥95%、其他至少 2 秒参考时长说话人的最低 known coverage ≥80%。
- FluidAudio 整场重建会把最终 padded frame 延伸到源音频结束之后。诊断适配层按当前 `MeetingDiarizationWorker` 的输入区间边界裁剪；越界超过 1 秒则拒绝。评分器本身未改。

## 结果

各预处理配置下，表中列出七种 VBx 配置里综合门槛排名最好的结果。`top-4 min` 与 `other min` 是 8 场中的最低值。

| segmentation step | 最短 embedding | 最佳 VBx `(threshold, Fa, Fb)` | 平均准确率 | 最低准确率 | 平均覆盖率 | top-4 min | other min | 平均 DER | 达标场次 | 每场平均秒数 |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.2 | 1.0 s | (0.60, 0.09, 0.8) | 94.82% | 88.97% | 96.58% | 78.87% | 61.10% | 11.19% | 0/8 | 1.68 |
| 0.1 | 1.0 s | (0.60, 0.07, 0.5) | **96.08%** | 92.10% | 96.25% | 78.49% | 0.00% | 10.21% | 0/8 | 3.26 |
| 0.2 | 0.0 s | (0.60, 0.09, 0.8) | 94.25% | 87.92% | 97.44% | 78.87% | 76.94% | 10.94% | 1/8 | 1.69 |
| 0.1 | 0.0 s | (0.60, 0.07, 0.5) | 95.40% | 91.03% | **97.45%** | 78.49% | 77.78% | **9.74%** | **2/8** | 3.34 |

最高平均准确率出现在 `stepRatio=0.1`、最短 embedding 1.0 秒的配置，但其其他说话人最低覆盖率为 0，且 0/8 场通过完整门槛。综合门槛排名第一的是 `stepRatio=0.1`、最短 embedding 0 秒与 `(threshold=0.60, Fa=0.07, Fb=0.5)`；它仍有 6/8 场未通过，`top-4 min=78.49%` 和 `other min=77.78%` 低于门槛。

与滚动窗最佳已测候选（`stepRatio=0.2`、最短 embedding 0 秒、24 组 matcher 中排名第 11）相比，整场上下文默认 VBx 在 8 场中有 5 场准确率提高、8 场覆盖率提高、8 场 DER 降低。平均准确率从 89.53% 升至 94.08%，平均覆盖率从 90.27% 升至 97.44%，平均 DER 从 21.80% 降至 11.20%；但完整门槛达标场次仅从 0/8 到 1/8。

全局筛选最优组合（`stepRatio=0.1`、最短 embedding 0 秒、`Fa=0.07`、`Fb=0.5`）相对整场上下文的短 embedding 默认聚类组合，平均准确率提高至 95.40%，平均 DER 降至 9.74%，达标场次升至 2/8。7/8 场 known accuracy 和 7/8 场 DER 有改善；覆盖门槛仍有 5/8 场 top-four 失败、1/8 场 other-speaker 失败。预处理 `stepRatio=0.1` 的候选平均每场耗时约为 3.3 秒，约为 `stepRatio=0.2` 的 1.7 秒的两倍；这些是本机开发集诊断计时，不构成正式性能验收。

## 结论与后续方向

1. 固定模型下，整场分段/embedding/聚类明显优于滚动窗口加跨窗 matcher，说明窗口局部聚类和身份回溯存在实质损失；简单调整 matcher 阈值不足以弥补它。
2. 短 embedding 与密集分段在整场上下文中能降低 DER 并增加少量达标场次，但仍未通过全开发集门槛。整场聚类参数变化主要改善平均准确率，未解除 top-four 与 other-speaker 覆盖短板。
3. 因而 Issue #370 保持 no-go；不改生产默认值，不宣称会议质量已通过。下面补充的匹配特征、zero-vote 和模型路径结果均未满足逐场门槛。

## 跨窗匹配特征与 PLDA 校准

在全局预处理 profile 3（`stepRatio=0.1`、最短 embedding 0 秒）和 VBx `(threshold=0.60, Fa=0.07, Fb=0.5)` 下，固定原始特征空间 `embedding256_cosine` 与 SDK `rho128` PLDA 特征比较。筛选候选使用 matcher policy 11；PLDA 固定策略落后后，再对 PLDA 空间运行 24 组 distance/margin/update 策略。向量只留在 worker 内存中，未写入 IPC 或制品。

下表中准确率、覆盖率、DER 是 8 场均值；括号内为 8 场中最差值。`top-four` 与 `other` 两列先计算每场相应说话人的最低覆盖率，再分别列出 8 场均值与最差场；质量门仍逐场判定。

| 匹配配置 | 准确率均值（最差场） | 覆盖率均值（最差场） | top-four 场内最低覆盖均值（最差场） | other 场内最低覆盖均值（最差场） | DER 均值 | 过门场次 |
|---|---:|---:|---:|---:|---:|---:|
| 原始 256 维，固定 matcher 11 | 88.36%（73.69%） | 90.24%（84.36%） | 71.57%（58.94%） | 84.10%（0.84%） | 22.77% | 0/8 |
| PLDA `rho128`，固定 matcher 11 | 76.67%（50.16%） | 64.23%（2.91%） | 32.40%（0.67%） | 77.33%（0.84%） | 50.77% | 0/8 |
| PLDA `rho128`，24 策略最佳观测值（index 2） | 90.40%（70.99%） | 82.71%（28.91%） | 57.61%（2.92%） | 82.76%（0.84%） | 27.24% | 0/8 |

PLDA 调参将平均准确率较 raw 固定 matcher 提高 2.04 个百分点，但平均覆盖率下降 7.53 个百分点、DER 增加 4.47 个百分点，top-four 最差覆盖只有 2.92%；它不是可冻结候选。PLDA 固定策略的 `other` 场内最低覆盖率均值是 77.33%，最差场仅 0.84%；均值不能代替逐场质量门。

## Zero-vote 后处理

仓库外已有一组成对 R003 产物，开关两侧 manifest、模型/SDK revision、worker digest 与 24 组 matcher policy digest 相同，仅 `zeroVoteReembed` 不同。固定同一 matcher policy 11 时，开启开关将平均准确率从 89.61% 升到 89.69%、平均覆盖率从 89.42% 升到 89.79%、平均 DER 从 22.32% 降至 21.90%；top-four 场内最低覆盖率均值增加 0.19 个百分点，other-speaker 最低覆盖率均值不变。两侧仍均为 0/8 场过门。

这组历史制品使用的 worker digest 与本报告当前 PLDA 诊断构建不同，因此仅作为该后处理方向的配对证据，不能宣称当前二进制已复测或把微小均值收益推广到生产。零票重嵌入也不能处理有错误聚类证据的片段。

## 工程校准路径与模型路径

PLDA refinement 首次执行在处理音频前被摘要校验拒绝。核对发现 manifest、model/SDK revision、候选集 digest 和排序均一致；缺陷是校验器将摘要内的字符串 `matching_embedding_space` 与候选 profile 字典直接比较。新增回归测试先复现失败，再将比较归一化到 profile 字段值；锁定与质量门没有放宽。该修复只恢复已声明 refinement 的可运行性，不改变任何模型评分。

模型研究（2026-10-17 只读核验）：当前动态离线管线使用 Community-1 风格的分段、WeSpeaker embedding、PLDA/VBx 组合。3D-Speaker 官方仓库提供另一条中文会议候选：AISHELL-4 整体 DER 报告为 10.30%，其 diarization 脚本以 CAM++ 中文/英文模型抽取 192 维 embedding，输入为 16 kHz、80-bin FBank，再配合中文 FSMN VAD 与 spectral clustering。[3D-Speaker 基准与模型](https://github.com/modelscope/3D-Speaker)、[官方 diarization 配置](https://github.com/modelscope/3D-Speaker/blob/main/speakerlab/bin/infer_diarization.py)。公开整体 DER 与 R003 的逐场门槛并非同一协议，不能据此预判通过。

该 CAM++ 组合是不同的 PyTorch 模型/聚类流程，不是当前 CoreML/PLDA 资产的权重替换：当前 raw matcher 使用 256 维，PLDA `rho` 为 128 维，而上游 CAM++ 脚本声明 192 维，并有不同的 VAD、重叠与 clustering 接线。项目接受的生产架构仍固定单一 CoreML 后端，不提供 CAM++ fallback 或多模型投票；因此它只能作为需单独评审的模型路径，不是本次生产配置变更。本次没有下载、转换、加载或切换模型。

较早的只读本地可得性检查未在标准 ModelScope cache 位置或 SpeechRail diarization 目录找到 CAM++ 制品，也没有找到可直接替换生产 CoreML 后端的 bundle。下方记录的 R003 对比使用独立外部 Python/ModelScope 环境；它验证的是 3D-Speaker PyTorch 管线，不代表生产 CoreML 可用性。

## CAM++ 聚类族 R003 实测

核验日期为 2026-10-17（Asia/Shanghai）。只使用锁定的 8 场 R003 开发集，manifest SHA-256 为 `ff3df5d28862fb5c2c73f597a98d4e204248121fc39994b412cf0513968c01cd`；没有读取或评分 R004 音频和参考标注。官方 [3D-Speaker 聚类源码](https://github.com/modelscope/3D-Speaker/blob/065629c313eaf1a01c65c640c46d77e61e9607b4/speakerlab/process/cluster.py) 固定在 commit `065629c313eaf1a01c65c640c46d77e61e9607b4`，CAM++ 为 `iic/speech_campplus_sv_zh_en_16k-common_advanced@v1.0.0`，FSMN VAD 为 `iic/speech_fsmn_vad_zh-cn-16k-common-pytorch@v2.0.4`。UMAP-HDBSCAN 保留上游 `cluster_line=40`；少于 40 个 embedding 时仍走上游 AHC 短输入分支。所有候选保持自动说话人数、相同 VAD/embedding、后处理、`pyannote.metrics==4.1`、overlap-inclusive DER/JER 和原逐场质量门。

| 聚类候选 | 平均 DER | 平均 JER | 平均 known coverage | 平均 known accuracy | top-four 最低覆盖 | other 最低覆盖 | 单项过门（覆盖/准确率/top4/other） | 完整质量门 | 每场平均秒数 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Spectral 基线 | 28.99% | 53.98% | 77.14% | 94.17% | 53.58% | 60.36% | 2/8 / 5/8 / 0/8 / 6/8 | 0/8 | 1.68 |
| AHC，`fix_cos_thr=0.4` | 36.28% | 59.06% | 77.14% | 84.41% | 53.58% | 60.36% | 2/8 / 0/8 / 0/8 / 6/8 | 0/8 | 1.50 |
| UMAP-HDBSCAN，固定 `random_state=0` | 28.34% | 58.44% | 77.05% | 95.47% | 53.58% | 60.36% | 2/8 / 5/8 / 0/8 / 6/8 | 0/8 | 2.59 |

UMAP-HDBSCAN 相对 spectral 的平均 DER 降低 0.65 个百分点、known accuracy 提高 1.30 个百分点，但平均 JER 增加 4.46 个百分点、known coverage 略降，且每场耗时增加约 55%。最大 DER/JER 为 42.90%/77.36%；本组参考包含 286.56 speaker-seconds 的重叠语音和 12 个不足 2 秒的参考说话人，预测有 5 个未归属区间、0 个边界裁剪区间。八场均未达到完整质量门；预测为每场 2–4 个说话人，而参考为 5–6 个，under-count 仍然存在。[HDBSCAN 将 `-1` 定义为噪声点标签](https://hdbscan.readthedocs.io/en/latest/api.html)；适配器将其作为未归属区间从 hypothesis 中省略并记录数量，既有 scorer 与质量门没有修改。该聚类族因此保持 no-go，不解锁 R004，也不改变生产 CoreML worker 或默认配置。

## 可复核材料

- 实验设计：[会议分人预处理实验规格](../superpowers/specs/2026-10-17-meeting-diarization-preprocessing-experiment.md) 与[实施计划](../superpowers/plans/2026-10-17-meeting-diarization-preprocessing-experiment-plan.md)。
- 离线探针代码位于 `native/diarization/Sources/SpeechRailDiarizationGlobalProbe/`；开发集驱动与评分位于 `examples/perf/probe_meeting_diarization_global_context.py`。
- manifest 锁、28 组分数、匿名活动片段和运行摘要在仓库外的 `global-factorial-screen-20261017-v1` 目录；PLDA refinement 在 `embedding-space-refine-plda-20261017-v1`；报告不复制逐场 ID、标注文本或活动片段。
