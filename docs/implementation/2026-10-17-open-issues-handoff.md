---
title: "SpeechRail 前五项高 ROI Issue 交接"
status: active
version: "1.0.0"
date: 2026-10-17
---

# SpeechRail 前五项高 ROI Issue 交接

**核验日期：** 2026-10-17（Asia/Shanghai）
**交接范围：** GitHub `hrygo/SpeechRail` 前五项高 ROI issue：[#369](https://github.com/hrygo/SpeechRail/issues/369)、[#308](https://github.com/hrygo/SpeechRail/issues/308)、[#371](https://github.com/hrygo/SpeechRail/issues/371)、[#372](https://github.com/hrygo/SpeechRail/issues/372)、[#370](https://github.com/hrygo/SpeechRail/issues/370)。
**目标：** 让接手团队能从当前代码、已完成的实验和未满足的验收门继续推进，不重复无效实验，也不把局部回归或探索性结果当成 issue 已关闭。

## 交接结论

截至本记录核验时，五个 issue 在 GitHub 均为 **OPEN**。本地代码和验收材料已覆盖多个 issue，但没有提交、推送或关闭远端 issue。当前最确定的本地成果是 #369 的重采样结束冲刷与性能观测，以及 #308 的 V16 默认请求稳定性修正；#371、#372、#370 仍缺 issue 级真实验收证据。

| ROI 顺序 | Issue | 当前可交接状态 | 主要剩余工作 |
|---:|---|---|---|
| 1 | [#369 重采样停止尾部冲刷与六类性能观测](https://github.com/hrygo/SpeechRail/issues/369) | 本地实现、定向回归、target coverage 和 Release App/Helper 封装验证已记录通过；未做真实硬件音频与性能验收。 | 审查并纳入共享分支；保持 #371 所需真实采集与性能证据独立。 |
| 2 | [#308 TTS 同文本偶发慢放](https://github.com/hrygo/SpeechRail/issues/308) | 默认 request-derived seed 已在代码中实现；精确 V16 缺省请求 30/30 为 11.52 秒、相同 PCM 哈希、无样本超过 14 秒。通用 vendor 触发机理和显式 caller seed 长尾仍未消除或认证。 | 审查改动；补听审与代表性文本/音色复核；按 issue 当前验收文字判断能否关闭。 |
| 3 | [#371 App 性能、硬件音频与长稳验收](https://github.com/hrygo/SpeechRail/issues/371) | 有 3 组有效的 idle 前台/隐藏态 Release 配对；没有活跃音频、CaptureHelper、主线程热点、完整场景矩阵或 1/4 小时 soak 证据。一次 UI test 只停在 Xcode 发现阶段，0 tests。 | 依 issue 矩阵完成活动工作负载、1 秒采样、角色归属、长稳和交互验收。 |
| 4 | [#372 实时字幕延迟与回溯质量](https://github.com/hrygo/SpeechRail/issues/372) | 一个开发片段的探索回放中，候选 CER 17.0870%，旧路径 16.3913%；不是完整配对验收。人工逐词时间、端到端 UI 延迟、错误修订统计均缺失。 | 先取得合格的独立人工文字/时间真值，再运行同条件的基线/候选质量和时延验收。 |
| 5 | [#370 会议转写准确率与多人分人质量](https://github.com/hrygo/SpeechRail/issues/370) | 既有 R003 仅覆盖 5–6 人动态分人，全部模型/校准候选未过逐场门槛；未评估 ≤4 人 Sortformer 质量，也未完成整场会议 ASR 联合验收。R004 未读取、未评分。 | 按用户最新优先级先认证最多 4 人；分别诊断 ASR、分人和 speaker-attributed 联合结果，通过后再决定是否扩展到 5 人以上。 |

顺序及其收益/依赖依据见[ROI 计划](../superpowers/plans/2026-10-17-open-issues-roi-plan.md)。本表的状态是计划、审计记录及当前源码的交叉总结；只有明确标作“实测”的项代表运行结果，历史记录不能替代接手时对代码与制品的复核。

## Issue 交接详情

### #369 — 重采样停止尾部冲刷和观测

**已完成的本地工作：** 正常停止时先排空已接受输入，再向原 `AVAudioConverter` 发送 `.endOfStream`，最多读取 8 次尾部输出。取消、格式变化、丢样、转换错误、无进展和交付失败保持失败/取消终态；只有 converter 明确返回 EOS 且无数据时才确认正常完成。尾块沿用原 epoch/source ID、递增 sequence，并使用最后已接收输入帧的采集时钟。六项性能样本已落在实际 owner 边界：`dubbingExport`、`captureEnqueue`、`mixerTick`、`captureStop`、`teleprompterMatch`、`transcriptPublish`。

**验证证据：** [性能验收记录](../audits/2026-10-16-app-performance-acceptance.md)记录指定过滤器 5 个 XCTest 与 56 个 Swift Testing 用例、target coverage、`git diff --check` 通过；Release App 与 CaptureHelper 构建及 XPC packaging verification 通过。合成 24/44.1/48 kHz 回归覆盖尾部完整性与终态。上述验证不代表真机麦克风尾音、CPU/RSS 或 UI 通过。

**接手入口：** `macos/SpeechRailApp/SpeechRailApp/AudioCaptureDrain.swift`、`AppPerformanceMetrics.swift`、相关采集 owner，以及 `macos/SpeechRailApp/SpeechRailMacControlTests/AudioCaptureDrainTests.swift` 等定向测试；指标语义见 [`macos-app-performance.md`](../developers/macos-app-performance.md)。

**完成边界：** 先审查当前 worktree 的实现和 Xcode/SwiftPM target 接线，再合入团队选定分支并运行 issue 指定的定向 Swift 验证。真实硬件尾音和资源收益属于 #371，不能因 #369 的确定性门通过而替 #371 关门。

### #308 — Qwen3 TTS 慢放

**根因证据与修正：** 一次 32-seed 控制实验中 3/32 输出时长超过 14 秒；时长与 TTS 请求 wall time 的 Pearson `r=0.9850`，ASR 内容代理未发现相对默认输出的规范化文本差异。证据指向生成采样造成的声学 token 长度变化，而非 WAV 采样率换算或整句重复。当前缺省 CustomVoice 路径对同一 voice 与规范化文本使用确定性的 request-derived seed，避免相同默认请求在随机 seed 间切换到慢长尾。它不证明所有文本/音色都没有慢放，也不限制显式 caller seed。

**V16 窄范围复核：** 受管 `quality/quality` 服务、`serena`、`speed=1.0`、24 kHz mono PCM16、同一精确 V16 输入且无 `SpeechRail-Seed` header 连续 30 次，输出均为 11.52 秒、553,004 bytes、SHA-256 `22d0689c775d35f2ede982d7894941684be0a2d88bc3f740e3342dd485639385`；0/30 超过 14 秒。receipt 记录 `seed_policy=request_derived` 和 observed seed `4004728035`，但 receipt `state=partial`。没有保存音频或完整转写，也未重复人工听审；ASR proxy 只核对了几个 V16 关键事实。证据与限制见 [M4 验收矩阵](../plans/2026-10-06-assistant-m4-acceptance-matrix.md)及 [ROI 计划](../superpowers/plans/2026-10-17-open-issues-roi-plan.md)。

**代码入口：** `src/speechrail/backends/qwen3_tts.py`、`src/speechrail/backends/qwen3_tts_worker.py`、`src/speechrail/domain/tts_sampling.py`、`src/speechrail/domain/tts_request.py` 以及对应 `tests/test_qwen3_tts*.py`、`tests/test_tts_sampling.py`。定向 TTS 回归 73 项与 Ruff 通过的记录见 ROI 计划。

**接手动作：** 核对 request-derived seed 对相同规范化请求的稳定规则、请求 receipt 与 worker 实际采样参数一致；在当前 issue 语义下评估 V16 是否足以满足替代门。若产品目标覆盖用户显式 seed 或任意文本，需新增有边界的质量要求和覆盖面测试，不能通过截断音频或按文本长度套固定时长上限来掩盖生成慢。不要声称已定位 vendor 内部通用 bug。

### #371 — App 性能、硬件音频与长稳

**已有测量：** 现有资料记录了 3 组有效的 idle 前台/隐藏态 Release 配对。CPU 以 `ps` 累计时间差分采样，footprint/RSS 读数分辨率有限；数值差异很小，不能外推到活动负载。一次指定 UI 测试在 Xcode 发现阶段 exit 70，错误为 `No test bundle product for testingSpecifier`、0 tests；CoreSimulator 版本低于 Xcode 需求，因此没有产生产品 UI 证据。详细制品和哈希见[性能验收记录](../audits/2026-10-16-app-performance-acceptance.md)。

**尚缺验收：** issue 所列活动采集与 CaptureHelper 进程归属、主线程 profile、1 秒 CPU/RSS 与 wakeup 观测、音频队列/取消/停止释放、实际 App 场景矩阵、1 小时和 4 小时会话、前后 Release 对照，以及需要的硬件音频/交互检查。idle 300 秒样本和构建成功都不能代替这些证据。

**接手入口：** `macos/SpeechRailApp/SpeechRailApp/AppPerformanceMetrics.swift`、音频采集/传输、mixer、提词器和 transcript 相关源码与测试；场景和性能口径见[性能验收记录](../audits/2026-10-16-app-performance-acceptance.md)和[`macos-app-performance.md`](../developers/macos-app-performance.md)。当前 App/Helper 共享 XPC 参数有配套关系，基线和候选构建都应使用仓库包装脚本与隔离导出目录。

**交互授权边界：** 仓库规则要求当前用户消息逐次明确授权任何会抢占前台、焦点、输入或屏幕的 UI 自动化。新团队不能仅凭本交接文档或旧测试记录推定已有授权；需要执行时，在对应工作回合取得该项明确要求。实时服务、正式 App 安装、profile 变更与长时间占用也应依对应运维/发布流程及当前授权执行。

### #372 — 实时字幕端到端延迟与回溯质量

**已知探索结果：** 同一开发片段中，原路径 CER 为 16.3913%，候选为 17.0870%；两者不是完整、独立留出的配对矩阵，候选没有显示质量收益，继续 no-go。候选 6 收包时间约 0.498 秒到首个预览、0.783 秒到终态，但它们是客户端收包时间，不是声音词尾到用户可见文字的端到端时钟。AISHELL-4 TextGrid 是句段/话语区间，不满足逐词人工结束时刻；AMI 相关词时来自自动强制对齐，也不满足独立人工时钟要求。

**接手入口：** [会议/字幕验收记录](2026-10-16-meeting-caption-acceptance.md)的窗口探索和语料时钟检查；相关候选策略在 T8 计划及当前源码中。该记录标明没有真实端到端 UI 延迟、wrong→correct / correct→wrong 回溯统计、声学词尾真值或独立留出集收益。

**下一步：** 先建立许可清楚的人工逐词文字和时间真值，预注册分层与 holdout；冻结旧策略和候选策略后，在相同输入上同时测 ASR 质量、首字 p95 ≤1 秒、持续输出 p95 ≤1.5 秒、与 full-window CER 的差值 ≤0.5 个百分点、错误修正/误改及最终封存正确性。真实可见 UI 时钟必须来自实际界面验收；不得用 WebSocket 收包或模型自身对齐代替。没有满足门槛就保持候选关闭。

### #370 — 会议 ASR 与分人质量

> 🧠 **From Hindsight memory (会议准确性与实时字幕回溯修正落地)** — 用户已决定先保障最多 4 人会议的分人准确率，再考虑是否扩展人数；原有质量门槛不降低，R004 留出集继续封存。

**产品顺序：** 第一阶段只认证 1–4 人的 Sortformer 路径。代码当前声明 Sortformer `system_cap=4`（`src/speechrail/application/services.py`）；这是容量边界，不是分人准确率承诺。第二阶段只有在第一阶段逐场通过后，才评估 5 人以上动态分人，不把 4 人结果外推。

**必须拆分诊断、联合验收：** 对同一会议分别报告 ASR CER/WER、分人 DER/JER、已知说话人覆盖/归属准确率，再报告 speaker-attributed `cpWER`/`tcpWER`（或按项目评分实现给出的 `cpCER`）。前几项用于定位问题，联合指标回答“谁说了什么”；不能因联合指标差就直接归咎 ASR，也不能只因 DER 好就宣称最终归属准确。行业和指标来源、日期已列在 [ROI 计划](../superpowers/plans/2026-10-17-open-issues-roi-plan.md)。

**保留已有验收门：** overall known coverage ≥90%、known accuracy ≥95%、top-four speaker coverage ≥95%；超过 2 秒的其他说话人，其最低覆盖仍按 issue 门槛达到 ≥80%。最多 4 人的第一阶段，top-four 已包含全部参考说话人，“其他说话人最低覆盖”记为 N/A，不放宽其他阈值。ASR 质量需达到相对基线 CER 至少改善 10%，以配对 bootstrap 95% 置信区间报告，并核验关键事实词。逐场门槛不能以总体均值替代。

**现有证据的适用边界：** R003 锁定的 8 场 AISHELL-4 会议有 5–6 个本地 speaker ID，使用 `meeting_dynamic`，没有评估 ≤4 人 Sortformer；R003 开发 manifest SHA-256 为 `ff3df5d28862fb5c2c73f597a98d4e204248121fc39994b412cf0513968c01cd`。原有全局聚类、跨窗匹配、CAM++/UMAP-HDBSCAN、预处理与校准尝试均未找到通过全部 R003 逐场质量门的候选。CAM++ spectral 基线均值为 DER 28.99%、JER 53.98%、known coverage 77.14%、known accuracy 94.17%、top-four 最低覆盖 53.58%，完整质量门 0/8；UMAP-HDBSCAN 将平均 DER 降到 28.34%，但 JER 升至 58.44%、覆盖仍为 77.05%，也为 0/8 过门。更多候选见[整场上下文算法诊断报告](2026-10-17-meeting-diarization-global-context-report.md)。这些失败说明该动态候选在该 R003 上未达标，不能推导 Sortformer 在 1–4 人上失败或通过。

**留出集边界：** 当前重建的 R004 会议数为 4 场，manifest SHA-256 `574a2822d28ea35deb38c91e584586c6e908623810437f5d99863d0825714d13`。此前报告明确尚未读取或评分。只在开发集达到所有门槛、候选和分析方案冻结之后，才执行正式 holdout；不可把 R004 用于调参。

**AliMeeting Eval 语料状态：** OpenSLR AliMeeting 公开页面说明 Eval split 面向 2–4 人会议，8 场约 4 小时，许可为 CC BY-SA 4.0（页面于 2026-10-17 核验）。已将 Eval 归档下载到仓库外：`~/Library/Application Support/SpeechRail/benchmarks/issue370-alimeeting-eval-20261017/Eval_Ali.tar.gz.partial`。归档约 3.4 GiB；`gzip -t` 通过；本机计算的 SHA-256 为 `dc47343b2474b5ebcf458927e878155f6ddeb59c85e685b3645c32a1f9578d92`。这只是本地内容摘要，不等于与发布者校验和比对。归档尚未展开、检查标注或生成 manifest，所以当前没有可评测 fixture。

该文件源自官方 [OpenSLR AliMeeting 页面](https://www.openslr.org/119/)。Eval 是公开评测 split，应作为冻结评估材料使用，不能在其上反复选模型或调参。新团队需先在不进入 R004 的许可数据上准备并锁定 1–4 人 development split，确认通道、文字参考、speaker spans、时间粒度和所有 license 条件；再确定 holdout 隔离与评分规则。不得把语料、音频、转写或逐场实名/说话人身份写入仓库。

**实现和报告入口：** `examples/perf/prepare_meeting_corpus.py`、`examples/perf/calibrate_meeting_diarization.py`、`examples/perf/probe_meeting_diarization_global_context.py`、`native/diarization/Sources/SpeechRailDiarizationWorker/MeetingDiarizationWorker.swift`，以及 [2026-10-16 验收记录](2026-10-16-meeting-caption-acceptance.md)、[全局上下文报告](2026-10-17-meeting-diarization-global-context-report.md)。准备脚本要求源文件与输出目录位于仓库外、split 在推理前按文件 ID 冻结，并把 session speaker ID 匿名化。

## 接手执行顺序

1. **保护当前工作树。** 先完整保存 `git status --short --branch` 与 `git diff`，确认工作树 owner、工作分支和远端基线；按 issue 逐个归属文件。不要 `reset`、`checkout --`、清理或覆盖现有更改，也不要直接把整个工作树当作一个 issue 的提交。
2. **按 ROI 顺序评审 #369、#308。** 查看上文代码入口及对应测试；在接手团队的目标分支中完成审查、最小定向验证，并记录代码版本/构建身份。#308 要确认本地代码与受管 runtime 实际代码一致，不以未确认的运行态版本替代源码证据。
3. **完成 #371 真正负载测量。** 预先锁定基线与候选 bundle、设备、场景、进程 owner 和指标；按 issue 要求测 active capture/helper、主线程、1 秒 CPU、RSS/wakeup、资源释放和 1/4 小时长稳。空闲数据只作空闲基线。
4. **补足 #372 真值后再执行 UI 验收。** 先确认数据许可、人工词级时间及评测拆分，再冻结方案；UI 测试前按当前仓库授权规则逐次取得明确授权。把收包、声学和用户可见时钟分别报告。
5. **优先完成 #370 的 1–4 人阶段。** 找到可调参的 development 数据并预先锁定 split；运行 Sortformer，分层检查 1、2、3、4 人；分别比较 ASR-only、diarization-only 和 speaker-attributed 结果。失败时先按结果优化算法、模型或工程接线，之后才审查测试方法。只有所有逐场门通过且开发候选冻结后，才申请使用对应 holdout；第一阶段通过后再讨论 5 人以上。
6. **远端交付逐 issue 完成。** 只有代码、验收证据与文档都达到 issue 当前关闭标准后，才更新 GitHub；本交接文档和本机实验记录本身不是关闭或发布授权。

## 仓库与文件状态

当前工作树为 detached HEAD `da18da8a`（`v3.11.1` 发布基线），存在大量已修改和未跟踪文件，覆盖 App 音频/性能、TTS seed、会议分人试验、测试及文档。`docs/superpowers/plans/2026-10-17-open-issues-roi-plan.md`、会议聚类规格/计划和若干探针文件也是未跟踪内容。工作树含有跨多个 issue 的累积修改，且本交接没有提交或推送任何改动。应在接手第一步核对实际 `git status`、文件归属和分支来源；不要重置或整目录清理。

原始音频、模型、ASR/TTS 输出和逐场 benchmark 原始制品应留在仓库外。报告列出的部分性能 bundle、摘要和短期输出可能位于 `/private/tmp` 或 `~/Library/Application Support/SpeechRail/benchmarks/`；使用前先确认文件当前仍存在、哈希符合报告、用途许可允许且未意外进入仓库。AliMeeting Eval 目前是唯一在本轮确认完整性的外部大文件。

## 可复核文档与外部来源

- [ROI 排序与执行状态](../superpowers/plans/2026-10-17-open-issues-roi-plan.md)
- [App 性能与 #369/#371 验收证据](../audits/2026-10-16-app-performance-acceptance.md)
- [会议与字幕实施、R003/R004、#372 数据时钟检查](2026-10-16-meeting-caption-acceptance.md)
- [会议分人全局上下文、聚类和模型实验](2026-10-17-meeting-diarization-global-context-report.md)
- [V16/M4 验收矩阵](../plans/2026-10-06-assistant-m4-acceptance-matrix.md)
- [OpenSLR AliMeeting 数据页和许可](https://www.openslr.org/119/)
- [CHiME-8 结果与指标](https://www.chimechallenge.org/challenges/chime8/task2/results)
- [多说话人长音频归属 WER 指标论文](https://arxiv.org/abs/2508.02112)

## 2026-10-17 接手监督复核与本地修正记录

核验日期：2026-10-17（Asia/Shanghai）。本节记录在目标工作树 `<worktree>` 完成的独立盘点、源码/制品复核与静态门修复：

1. **工作区与 `.git` 沙盒边界实测：**
   - 目标工作树 `.git` 文件指向 `gitdir: <repository>/.git/worktrees/SpeechRail`。在仅挂载本 worktree 目录的受限沙盒下，外部主仓库 `.git/worktrees/SpeechRail` 不可直读（`git status` 返回 `exit 128`）。
   - 对照检出基线时间戳（`README.md` / `pyproject.toml`：`2026-10-17 02:56:36`）与 `/private/tmp/speechrail-performance-baseline-source-20261017` 逐文件比对，确认本工作树在检出后共有 **60 个非构建/非缓存源码、测试与文档文件发生修改或新增**（对应交接前 47 个已跟踪修改 + 17 个未跟踪文件/目录项，外加本交接文档）。全部既有改动完整保留，未执行任何 `reset`、`checkout` 或清理。
2. **交接陈述与实际证据的偏差修正（防止误判）：**
   - **#308 多分块派生 seed 细节：** `src/speechrail/backends/qwen3_tts_worker.py` 中 `MlxQwenTtsEngine.synthesize` 先经 `TtsTextPlanner().plan(clean_text)` 切分 `planned_chunk.spoken_text` 再逐块调用 `_generate`；缺省 `request_derived` 策略按每个 `planned_chunk.spoken_text` 派生 seed 并更新 `_last_sampling_observation`。单分块 V16 文本上 `seed=4004728035` 30/30 一致（11.52 秒），但不能外推为任意文本/多分块或显式 caller seed 已消除 `mlx-audio#1002` 慢放，且 `receipt state=partial`、无新一轮人工双听。
   - **#370 AliMeeting Eval 归档状态核实：** 受当前沙盒目录限制，`~/Library/Application Support/SpeechRail/benchmarks/` 在本会话返回 `Operation not permitted`。无论外部 `Eval_Ali.tar.gz.partial` 当前是否补下完成，**均未解包、未与官方发布者 checksum 对照、未生成锁定 manifest、未运行 Sortformer 1–4 人评测**，严禁把下载哈希当作质量或语料就绪结论。
   - **#370 新建 Python 探针的 `mypy` 静态门缺口已就地修复：** 独立运行 `mypy` 发现 `examples/perf/probe_meeting_diarization_global_context.py`（第 22、28 行相对导入缺少 `# type: ignore[import-not-found]`）与 `examples/perf/diarization_3d_speaker_runner.py`（第 236–242 行外部隔离环境 `modelscope`/`speakerlab`/`umap` 导入及 `umap_module` 类型重定义）存在 **7 个 mypy 错误**。已在不改变任何运行时行为的前提下完成修复，复跑 9 个相关 Python 源文件 `mypy` 为 `Success: no issues found in 9 source files`，`ruff check` 全部通过，171 项关联 `pytest` 用例全部通过。
3. **本地确定性验证实测汇总：**
   - `python3 scripts/check_macos_test_target_coverage.py`：`macos-test-target-coverage: OK`。
   - `./native/diarization/.build/out/Products/Release/SpeechRailDiarizationProtocolSelfTest`：退出码 `0`。
   - Python 定向回归（`test_tts_sampling.py`、`test_qwen3_tts.py`、`test_qwen3_tts_worker.py`、`test_probe_meeting_diarization_3d_speaker.py`、`test_calibrate_meeting_diarization.py`、`test_probe_meeting_diarization_global_context.py`、`test_diarization_worker.py`、`test_meeting_diarization_quality.py`、`test_asr_quality_metrics.py`）：**171 passed in 1.87s**。
   - Swift 定向回归（基于当前工作树 `SpeechRailAppSupport.o` 与源码编译执行）：`#369` 核心 7 个套件 **45/45 通过**（含 `AudioCaptureDrainTests` 10 项 EOS 重采样冲刷与 `captureStop` 计量），`#371` `AudiobookWorkspacePerformanceTests` **10/10 通过**。
   - 五个 issue（`#369`、`#308`、`#371`、`#372`、`#370`）在当前阶段**均保持 OPEN / 不关闭**。
