---
title: "有声书大规模选角 T11 自动化验收记录"
status: active
date: 2026-10-15
---

# 有声书大规模选角 T11 自动化验收记录

## 范围与结论

2026-10-15 21:43 CST 开始，按当前授权仅执行 30 分钟内可完成的自动化验证。真实调用使用已经运行的 `quality/quality` 服务；不启停服务、不切换档位、不安装、不提交、不操作真实作品库，不接管窗口或播放声音。原始音频、合成文本、ASR 回读和临时程序均保存在仓库外私有临时目录。此记录属于 T11 的诊断性自动化子集，不是正式性能基准或发布验收。

**音频/回执完整性和离线交互回归通过；微语速生效性未通过。** 40 组候选与基线 PCM 全部相同，因此不能用本次结果证明微语速对忠实度或自然度安全。AC-Q-01、AC-Q-02 的人工质量门以及 AC-Q-03 的实际 UI/无障碍门均保持 `not_evaluated`，自动微语速继续关闭。

## 冻结材料与身份

在批量生成前冻结 20 段原创合成中文短句、10 组对手戏、两种已有系统声音以及所有请求参数。没有使用用户书稿或声音克隆。每段同时覆盖两个声音和两个参数条件，共 80 个测量样本；另有两个预热、两个重复控制，总计 84 次 TTS。80 个测量样本分别进行一次 ASR 回读。已有音频另派生 10 组基线/候选对话文件，供诊断复核；由于语速条件未实际产生差异，不作为有效盲听 A/B 材料。

| 项目 | 冻结值或实际观测 |
|---|---|
| manifest SHA-256 | `76408feef78e0219019d1e23a47411cdd1811880f8f6402ab8fe13a3ee7b300c`；运行后未变 |
| 声音 | `serena`、`uncle_fu`；声音 revision 未知，保留 `null` |
| 参数 | 基线 `speed=1.0`；候选分别 `1.02`、`0.98`；全部 caller seed `42` |
| 输出和策略 | WAV、24 kHz、mono、PCM16；`allow_unverified`；integrity receipt |
| TTS 制品 | `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit` |
| TTS catalog revision | `08b854525817066e04ef6b6430a3faa0eebd24d2`；每个测量回执核对 |
| TTS 观测 runtime revision | `rt_d19125c0b66c2ed0438ee51ae4563906ab5991073f838ee0f580d14a397235e6`；每个测量回执与预热观测一致 |
| ASR 配置身份 | `mlx-community/Qwen3-ASR-1.7B-8bit`；catalog revision `579e237ce6ec925252973afe835d2f98a138602f`，不冒充逐请求观测身份 |

本次只冻结自动化指标：完整且非静音的 PCM、回执身份和哈希一致、重复控制、候选/基线 PCM 与时长比较，以及 ASR 字符差异标记。任意非零 ASR 差异均标记待人工复核，不设置可放行的 CER 阈值。至少三位听众、角色标签盲化、自然度评分及统计方法尚未完成冻结，不能将上述自动化 manifest 认定为完整的人类试验方案。

## 实测结果

批量 TTS/ASR 于 21:52:07 CST 完成；末次 HTTP 复核于 21:57:51 CST 完成。

| 自动化检查 | 结果 | 解释边界 |
|---|---|---|
| 测量请求 | TTS 80/80、ASR 80/80 成功 | 另有 4 次成功的预热/重复 TTS；无重试掩盖失败 |
| WAV/PCM 与回执 | 80/80 通过 | 帧数、时长、PCM SHA-256、声音 ID、TTS catalog/runtime、文本摘要及回执参数一致；非静音，未观察到满幅削波 |
| 配方完整性 | 80/80 `partial` | 缺少 `voice.revision`、`parameters.seed_policy`；未改写为完整可重现保证 |
| 固定参数重复控制 | 2/2 PCM 完全一致 | 仅证明这两个样本的本次重复，不保证跨运行或全模型确定性 |
| 微语速实际生效 | **未通过：40/40 对 PCM 完全相同** | 候选/基线时长比全部为 1.0；回执中的不同 `effective_speed` 不能证明声音已改变 |
| ASR 文本代理 | 基线、候选各 2/506 字符差异，CER 均约 0.395% | 各 40 段中 38 段零差异；4 个非零结果来自同一句同音字“它/他”，不能判定为实际读错，也不能自动豁免人工忠实度验收 |
| 离线交互逻辑回归 | 10 项通过，0 失败，0 跳过 | 覆盖目录刷新/空集恢复/过期推荐、同文与对话试听、固定参数和策略、共用确认、批量影响及撤销；使用临时存储与 fake transport/player，无前台 UI |
| 结束时服务读数 | `/health`、`/readyz`、`/metrics` 均 200；档位仍 `quality/quality`；batch/realtime active、pending 均 0 | 实时 session gauge 缺失，记为未知；不是资源或长时稳定性验收 |

ASR 使用现有 `examples/perf/asr_quality.py` 的 NFKC、casefold、字母/数字/标记字符归一化和字符编辑距离；标点不进入该 CER。TTS 生成语音上的回读只是可懂度/文本差异代理，不是独立 ASR 质量数据集，也不能计算角色听感辨识率。

离线测试实际通过的方法：`testResidualSceneSharingRequiresExplicitAcknowledgement`、`testSurfaceCatalogRequiresDefaultSystemIdentityForUnknownVoices`、`testBatchImpactAndUndoPreserveAdoptedVersion`、`testCatalogChangesRefreshProjection`、`testDialogueAuditionUsesOrderedAdjacentSourceWithoutChangingAssignments`、`testRecommendationExplainsEmptyPoolAndRecovery`、`testSameTextAuditionKeepsSourceAndFrozenParametersWithoutCommitting`、`testStaleRecommendationCannotApply`、`testAudiobookAuditionUsesPreviewPolicyAndPreservesPins`、`testRenderPinsStrictPolicyAndAuditionStaysUnverified`。测试日志记录 10 项均实际开始并通过，结束于 21:52:08 CST；没有执行 XCUITest。

## 语速异常与运行环境变化

仓库和当前安装适配器的 `MlxQwenTtsEngine._generate` 将 `speed` 透传给模型。只读检查本机 `vendor/current` 的 Qwen3-TTS 实现发现：`generate` 声明该参数，但函数 AST 对参数读取数为 0；文档字符串注明尚未直接支持，CustomVoice 分派也未传入语速。这与实测无效果一致。该 vendor 文件摘要为 `0d9437e4f08680d7bf8cb7bf3b44c8e3de37ad9edf025f50dba37dface2e6902`。未追溯已结束 worker 的实际 import 路径，因此这是当前本机源码证据，不扩大为所有模型、所有运行版本的结论。

后续修复应先让能力声明、参数拒绝/执行和回执实际效果一致，再重新冻结有效配对样本并听评。不能仅调整回执或用不同随机种子制造差异。本次只做验证，未实施该修复。

采样结束后检测到服务监听 PID 从 `26113` 变为 `36460`，后者启动于 21:53:07 CST；能力快照的实例 epoch 同时变化。前后档位、配置模型 catalog revision 和 managed runtime 目标相同。本代理未执行任何服务控制操作，无法据此确定外部操作者或原因，也不能声称整个会话服务实例不变。测量于该新进程启动前完成，每个测量 TTS 回执均核验同一观测模型身份；没有逐请求实例 epoch 证据。

Git HEAD 在本次期间从 `934a6d0c` 推进到 `53dd77bc`，属于本代理之外的并行状态变化。写文档前，进入本次时记录的 1,358 个源码/文档文件摘要全部一致；没有回退或覆盖这些并行提交。本次写入范围仅为本验收记录和实施计划的状态补充。

## 剩余验收与回退

| 门槛 | 本次状态 | 下一步条件 |
|---|---|---|
| AC-Q-01 角色辨识 | `not_evaluated` | 冻结完整听评设计；至少 3 位听众盲听，报告总体与逐组样本量、辨识率及区间 |
| AC-Q-02 忠实度/自然度 | `not_evaluated`；另有语速生效性失败 | 先解决无实际效果的问题；重新生成有效配对样本，逐条人工核验忠实度及自然度差值区间 |
| AC-Q-03 实际 UI/无障碍 | `not_evaluated` | 用户当次明确授权前台操作；逻辑回归不能替代键盘、VoiceOver、外观和 Reduce Motion 验收 |
| 性能、全库质量、长期稳定性 | `not_evaluated` | 单独确定场景、资源预算及验收范围 |

维持现有默认 `speed=1.0`、自动微语速关闭；没有修改任何绑定、候选或采用音频。无需运行态或用户库回退。临时诊断材料可在后续获授权清理时单独处理；代码回退不删除用户数据。本次文档可按该两处精确差异撤销，须保留其后并行改动，不能整文件还原。

外部证据包含 `frozen-manifest.json`、逐样本 TTS/ASR 指标、84 份原始音频及回执、重复控制、10 组派生对话、10 项离线测试完整日志和 `summary.json`。仓库中不保存完整合成文本、回读正文或音频；这些临时证据不作为永久可用的仓库 fixture 承诺。

21:59 CST 完成收尾核验，距开始约 17 分钟：manifest 摘要未变，实际文件计数与测试日志一致，4 个本地文档链接有效，工作区及暂存区差异空白检查通过。进入本次时的 1,358 个文件中，仅实施计划出现本代理新增的一行状态记录，其余 1,357 个保持原摘要；另新增本验收记录。未暂存、提交或改动产品代码。
