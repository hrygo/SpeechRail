---
title: "会议转录与分人接手及实施记录"
status: active
date: 2026-10-18
---

# 会议转录与分人接手及实施记录

用户于 2026-10-18 批准[设计](../superpowers/specs/2026-10-18-meeting-asr-diarization-research-design.md)和[实施计划](../superpowers/plans/2026-10-18-meeting-asr-diarization-implementation-plan.md)，授权提交方案并在同一 PR 持续实施。全部工作由主代理执行，不使用 subagents。真实模型、语料、运行态、安装和发布遵循计划中各自的执行条件。

## 产品目标与执行优先级（2026-10-18 用户校正）

交付目标是提高 SpeechRail 在真实语音中的转录忠实度、匿名分人准确性与稳定性，改善字幕和会议体验，并降低可感知延迟与资源成本。评测、来源锁和观测工具提供决策证据；工具数量、测试数量和框架完整度不能作为产品收益。

执行采用短闭环：先用已授权开发音频运行现有生产路径，定位主要错漏、说话人归属错误、定稿延迟和资源瓶颈；每次选择一个有证据支持的生产改动，在相同输入与基线上对照，再决定保留、撤回或扩样。工具只补充当前运行或诊断必需的能力，不把完善整套评测基础设施作为开始产品优化的前提。每轮交付须指出具体生产行为变化及真实对照；只有工具变化时明确报告产品收益尚未验证。

既有质量指标作为验收标准保留；小样本诊断用于选改动方向，不代替独立参考、分人认证、共同来源扩样或最终留出验证。当前先完成修正后首片诊断和服务恢复，随后依据实际输出选择生产侧优化。新增模型、扩大运行态操作和留出使用继续遵守各自授权边界。

## 接手基线

- OpenCode 会话 `ses_eb62ef783ffey0w5LgFSx9Vjd4`，原分支 `feat/meeting-diarization-global-context`，HEAD `0cd70930b921ed1a724458333aae48ff162291c2`。
- 2026-10-18 fetch 后 `origin/main=66b2a1d6e1424d761aaf082635022af1f3e1e51c`。PR 分支 `codex/meeting-asr-diarization` 从此处创建，原工作区不切分支、不 rebase、不改写。
- 原 19 个未提交文件和本会话 2 个方案文件共 21 个，已在仓库外生成逐文件完整副本、SHA-256 manifest 和 tracked binary patch；本机恢复位置 `/tmp/speechrail-handoff-backup-20261018`。备份不是评测制品，不包含音频、私有配置或模型。
- 相对旧 HEAD，main 在本次整合范围内已修改 probe 和相关测试（89 行），资源治理及分人生产模块未变。整合以 main 为底逐项应用，不复制旧 probe 覆盖 main 修复。
- 当前图谱仅覆盖主 checkout，analysis 入口没有 `index_repository`。结构定位复用既有图谱后检查 coverage，并直接读取当前 worktree；不将图谱视为未提交改动的证据。

## 原始改动归属与处理

| 文件 | 原工作内容 | 整合原则 |
|---|---|---|
| `docs/decisions/README.md`、`docs/decisions/0022-asr-diarization-heavy-compute-overlap.md` | 独立分人 lane 决策 | T3 整合时校正机制证据与真实验收的区别 |
| `docs/implementation/README.md`、`docs/implementation/2026-10-17-meeting-diarization-phase1-evaluation-record.md` | 旧评测记录入口 | 原报告保留时点，不升级为本次认证 |
| `docs/operations/README.md`、`docs/operations/heavy-compute-overlap-configuration.md` | 配置与内存说明 | T3 对照准入实现修正；不落盘真实配置 |
| `docs/superpowers/README.md`、`docs/superpowers/plans/2026-10-17-meeting-diarization-asr-lane-decoupling-plan.md` | 旧解耦计划 | 保留源文件；新计划不继承其“全部完成”结论 |
| `examples/perf/probe_meeting_sortformer_1to4.py` | 可选 consolidation | T1 先补身份，再整合开关；旧报告仅诊断 |
| `src/speechrail/backends/diarization/slot_postpass.py`、`tests/test_slot_postpass.py` | slot 后处理及测试 | 非新候选默认项；不据此继续阈值搜索 |
| `src/speechrail/backends/diarization/coreml.py` | activity threshold 参数 | T1 绑定实际配置；T3 纳入共享 owner/计算租约 |
| `src/speechrail/backends/diarization/meeting.py`、`tests/test_meeting_diarization_session.py` | DIARIZATION 计算 lane | T3 整合，同时修正两处错误的 ASR quarantine |
| `src/speechrail/application/services.py`、`src/speechrail/runtime/model_budget.py` | footprint/组合根 | T3 在共享 owner 保证互斥驻留下整合 |
| `src/speechrail/runtime/resource_governor.py`、`tests/test_diarization_lane.py`、`tests/test_diarization_overlap_policy.py` | lane 与预算机制 | T3 补 owner、隔离、队头阻塞和故障资源记账 |

上述为原文件的归属清单，不表示已经全部进入 PR。每批实现另记验证结果。

## 证据账本

| 阶段 | 2026-10-18 起点 | 放行证据 |
|---|---|---|
| E0 | 候选摘要漏后处理，oracle 指标误名 | T1/T2 定向测试已通过；正式收据仍待来源锁接线 |
| E1 | 原作者报告机制测试通过，未由本会话复验 | T3 独占 owner、故障/队列/预算 fake 回归 251 项通过 |
| E2 | 原 dev-v2 三份报告均 no-go | 新 C0/C1/C2 共同开发集，未运行 |
| E3 | sleep 负载机制 ABBA，非真实双模型 | 真实四模式、配对时延与 footprint，未运行 |
| E4 | 未认证新候选 | 生产字节冻结及独立留出，未运行 |
| E5 | 未安装新代码 | 安装态 API、长稳、版本回滚，未运行 |

## 接口预检与决策

| 生产任务 → 消费任务 | 接口 | 检查结果 |
|---|---|---|
| T1 → T4/T5/T6/T7/T8 | candidate/manifest/policy 各自摘要及 v2 收据 | 单向依赖；运行事实必须与声明逐字段相符 |
| T2 → T4/T5/T7/T8 | 产品 speaker-time 门与独立标准 scorer | unknown 不贡献身份正确项；标准 scorer 仍接收全部文字 |
| T3 → T4/T6/T7 | session owner 与 chunk compute lease | owner 先于 worker factory；失联占用不因协程结束消失 |
| T5/T8 → T6/T7 | 共同开发终点与最终 ASR 身份 | 换 ASR/adapter/worker 后重新验证开发和共存，再冻结留出 |

Ruling: 技能所引用的 `sdd-workspace` 工具未安装，使用本记录及本计划专属 scratch ledger 记录进度与 RED/GREEN；不创建假脚本或跳过验证。代价是任务记录人工维护，以提交和实际测试输出交叉核对。

Ruling: 根据用户明确要求，最终审查也由主代理完成，不调用技能建议的独立 reviewer。代价是缺少独立审查视角；PR 保持 draft，合并前可由人审阅。

## 实施进度

| 任务 | 状态 | 验证/剩余条件 |
|---|---|---|
| T0 | 代码边界已固定；延迟前置未满足 | 见下方 policy 和静态 ASR 核对；真实实验保持关闭 |
| T1 | 已实施 | 身份与收据定向 fake 通过；旧 runner 仅诊断，不签发 v2 认证 |
| T2 | 已实施 | 产品、标准与 oracle 分开；来源组统计与旧/新门并行，80 项定向通过 |
| T3 | 已实施 | owner、隔离、队列、预算及持久任务接线；251 项定向通过 |
| T4 | 部分实施 | 八维协议、只读预检、隔离 native 包与 session 接线已交付；410 项 Python 定向测试和 3 项原生测试通过，真实模型与评测命令未接通 |
| T5–T6 | 待实施 | 来源锁、有限候选对照和真实共存 harness |
| T7 | 前置未满足 | 无生产认证，不接入默认能力、不安装 |
| T8 | 待实施 | 先交付归因工具，不声称 CER 改善 |

回退采用 PR 中各逻辑提交的反向变更；原 OpenCode 工作区与仓库外备份保持可恢复。尚未执行服务、模型、App、数据库、安装或发布动作。

## T0/T1 验证记录

2026-10-18 将获批阈值、token 化、scorer 版本、延迟、bootstrap 和扩样规则写入 [`meeting-evaluation-policy.json`](../../examples/perf/meeting-evaluation-policy.json)。后续执行收据必须锁其实际 canonical digest，不使用文档中的手抄摘要。

当前 `WindowPolicy.for_scene("meeting")` 为 owned=20 秒、review_grace=2 秒、最终处理预算 15 秒。早期音频须等块结束后复核，静态最坏等待可达约 22 秒（另加排队/推理），不足以保证稳定标签 P95≤15 秒；15 秒 finish 上限也不能证明 P95≤5 秒。此为源码推断，尚无实时速率实测；常规 ASR 模式须另测。保留获批预算，真实联合实验前先定位 A0 时钟或提出具体策略修订，不降低门槛，也不把 ASR 等待算为分人退化。

Ruling: 旧四槽 runner 保留历史 spec 解释与开发诊断，但不再签发认证或打开 holdout；v2 收据的签发需 T2 产品门及 T5 的共同来源完整性证据接线。代价是旧 CLI 不再能执行历史留出流程，避免误用缺身份的旧凭据。

T1 RED：新身份模块缺失导致 collection 失败；旧 runner 三项行为回归失败（旧收据仍放行、未记录有效身份）。GREEN：`PYTHONPATH=src:examples/perf uv run --no-sync pytest tests/test_meeting_evaluation_identity.py tests/test_probe_meeting_sortformer_1to4.py tests/test_slot_postpass.py --no-cov`，使用已有 Python 3.14 测试环境，49 项通过。随后补同一 holdout 换候选仍不可重用的回归；提交前追加 SDK 适配器回归；最终定向结果见本节末。

整合原 OpenCode 的 threshold 参数、可选 postpass 和对应测试；新 C0 仍关闭 postpass。有效身份覆盖 adapter/worker/model 文件、SDK、完整 preset、`>=0.25`、postpass 的全部参数和源码、归属/scorer。旧三份 no-go 报告和原工作区没有改写。

T1 提交前复验：上述三组加 `tests/test_diarization_sdk.py` 共 54 项通过，Ruff 检查与 `git diff --check` 通过。仅 fake 数据，无模型推理。

## T2 验证记录

2026-10-18：新增含 overlap 的 speaker-time recall/precision 和逐人门；额外 known 标签、参考静音中的假警报、unknown 和 <200ms 插话均有人工小样本。旧 nonoverlap 门与新门分别保留；空分母/null 不通过。标准 cp/tcp/greedy DI-cp 调用锁定 MeetEval，八人 assignment 不枚举 8!；unknown 原文仍作为标准 stream，产品身份门独立判定。旧 oracle 输出改名，不覆写既有结果。

按来源会议组先汇总重复，再用 seed=1717、10,000 次配对 bootstrap 计算 95% 区间；pooled/macro 都须满足下界，缺人数层、逐人失败或 C0 配对上界未支持不退化均不能通过。单一会议的重复不制造独立样本。单场或聚合评分不签发生产人数；来源锁和联合/留出验收仍待后续任务。新增 ADR-0023 固定上述批准语义。

本 worktree 的隔离 dev 环境安装并实际导入 `pyannote.metrics==4.1` 和 `meeteval==0.4.3`，lock 保留全部原版本，仅新增 MeetEval 及其两项依赖；未改服务运行依赖。首次同步触发仓库默认 native CLI build，已中断并使用 `SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD=1 uv sync --locked --extra dev` 完成测试环境同步，没有运行 worker、加载模型或产出 App。

RED：评分模块/统计接口缺失、旧 `di_cp_*` 名称回归分别失败。GREEN：`PYTHONPATH=src:examples/perf uv run --no-sync pytest tests/test_meeting_quality_metrics.py tests/test_meeting_diarization_quality.py tests/test_probe_meeting_sortformer_1to4.py tests/test_meeting_evaluation_identity.py --no-cov`，80 项通过。测试仅使用人工构造文本与时间区间，不运行模型、不读真实转写。

## T3 验证记录

2026-10-18：两个生产分人路径共享 governor 的单一 owner；认领先于 worker factory，计算预留覆盖 load/preflight、infer 和 finish。故障回收只合并到一个 lease，失联 child 保持 owner/引用与 retained 占用；资源上界未知或串行策略下全部 fail-closed。有可信完整预算时仅隔离自身轴；独立 lane 可越过因自身模型忙而阻塞的前项，同 lane FIFO 保留。启用的分人替代路径任一缺声明，都不能用 max 掩盖未知。

审查发现并补齐会议路径的取消消费者唤醒、有界慢消费者失败、重复 finish 和 close 指标。启动中的 OS 子进程创建必须完成精确 child 登记，再允许取消回收；preflight 阻塞本身可中断，不因 shield 整个启动而永久等待。HTTP/Realtime/持久任务的 owner busy 与隔离沿用已有稳定错误，不暴露 worker 细节。

Ruling: 将具体持久转录 processor 的准入改为按阶段持有，runner 保留全流程 deadline。原因是整个任务持有 ASR 后再获取分人，在串行策略下会形成自身等待。注入的其他 processor 仍由 runner 准入，speech 的 TTS 路径不变。代价是明确分担准入责任，增加组合根和真实 local processor 的 fake 集成回归。

RED：owner 模块/新轴缺失导致 collection 失败；慢消费者与取消消费者测试超时；重复 finish 返回错误；卡住的 preflight 无法取消；延迟创建的 child 未完成登记便退出。GREEN：修复后定向命令如下，251 项通过（含 HTTP/Realtime 和持久任务集成），11 个变更 source 文件通过 Mypy，变更 Python 文件通过 Ruff，`git diff --check` 通过。

```bash
PYTHONPATH=src:examples/perf uv run --no-sync pytest \
  tests/test_diarization_owner.py tests/test_diarization_lane.py \
  tests/test_diarization_overlap_policy.py tests/test_meeting_diarization_session.py \
  tests/test_diarization_worker.py tests/test_diarization_sdk.py \
  tests/test_diarization_session.py tests/test_resource_governor.py \
  tests/test_application_composition.py tests/test_local_file_processor.py \
  tests/test_job_runner.py tests/test_openai_diarized_batch.py \
  tests/test_realtime_auxiliary_attribution.py --no-cov
```

以上只证明 fake 机制和接线，未执行真实双模型、质量/性能 benchmark、服务或配置变更，不签发人数认证，也不改变生产默认并发策略。

## T4 制品预检与交付批次审查

2026-10-18：新增私有八槽 packet 校验器和 `probe_meeting_candidate.py preflight`。frame 必须为八维有限概率，采用 `>0.5`，恰好 0.5 不活动；保留 10ms 短插话，拒绝错误 SDK/epoch/watermark、帧缺口和静默填充。finish 的最后一个 padding frame 只裁到 accepted samples，不假定能检出第九位说话人。

预检固定 fast32/fast128 的完整 SDK preset、关闭外部后处理与 VAD gate，绑定实际 worker/模型/embedding、adapter 与 scorer 源码及 policy 摘要。只接受匹配的预编译 bundle 和本地 512 Float32 silence embedding，不编译、下载或启动 worker。配置依据为核验于本日的[固定 SDK Types](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Sources/FluidAudio/Diarizer/Nemotron3/Nemotron3Types.swift)与[本地加载源码](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Sources/FluidAudio/Diarizer/Nemotron3/Nemotron3Models.swift)。

输出明确 `verdict=not_evaluated`、`certified_max_speakers=null`，运行身份、实际 CoreML shape 和 snapshot 来源均未验证。`preflight` 的文件匹配不构成模型可运行或质量证据；尚不提供 development/holdout 执行命令。后续已补 native 包与锁、单 task worker、session owner 接线及构建，见下节。development/holdout 命令仍须等待 T5 来源锁与门禁接线，T5–T8 继续保留各自前置。

RED：协议模块和预检入口分别缺失。GREEN：`PYTHONPATH=src:examples/perf uv run --no-sync pytest tests/test_probe_meeting_candidate.py --no-cov`，32 项 fake 通过，包含 CLI、摘要变化拒绝及 symlink 拒绝；预检模块通过 Ruff 与指定 source path 的 Mypy。CLI `preflight --help` 已实际执行。

交付批次由主代理自行审查，未调用 subagents；逐项核对身份、含 overlap 分母、unknown 标准 stream、owner 生命周期、隔离上界、队头阻塞、持久任务接线和预检边界。审查修复纳入上述 RED/GREEN，不把自审当独立人审。原 OpenCode 的 21 个文件在本日逐项重新计算 SHA-256，均与接手备份一致。

CI `39082691725` 全量自动测试中有 3 项隔离 fixture 失败，4,347 项通过、1 项 skipped。该 fixture 模拟了 overlap/单任务预算，却没有固定故障资源上界检查所需的硬件条件；本地结果因而不能代表 CI。已显式注入已知/未知硬件预算，并同时验证资源上界未知时所有能力及 readiness 拒绝。12 项定向回归通过，不放宽生产资源检查；修复提交 `fb89beb`。

本批提交前合并复验：2026-10-18，以下 20 个相关测试文件共 393 项通过；全分支 34 个变更 Python 文件通过 Ruff，生产源文件 11 个和预检源文件 2 个分别通过 Mypy，文档本地链接/代码围栏/换行与 diff 检查通过。

```bash
PYTHONPATH=src:examples/perf uv run --no-sync pytest \
  tests/test_meeting_evaluation_identity.py tests/test_probe_meeting_sortformer_1to4.py \
  tests/test_slot_postpass.py tests/test_meeting_quality_metrics.py \
  tests/test_meeting_diarization_quality.py tests/test_diarization_owner.py \
  tests/test_diarization_lane.py tests/test_diarization_overlap_policy.py \
  tests/test_meeting_diarization_session.py tests/test_diarization_worker.py \
  tests/test_diarization_sdk.py tests/test_diarization_session.py \
  tests/test_resource_governor.py tests/test_model_budget.py \
  tests/test_application_composition.py tests/test_local_file_processor.py \
  tests/test_job_runner.py tests/test_openai_diarized_batch.py \
  tests/test_realtime_auxiliary_attribution.py tests/test_probe_meeting_candidate.py --no-cov
```

审查补充：同类等待队列满时，`lane_available` 先前仍可能把空闲的独立 lane 显示为可用，而实际 `_acquire` 会拒绝。新增 `test_lane_available_respects_full_pending_class_even_for_free_independent_lane` 首次断言失败，补齐同一队列上限条件后 GREEN；上面的 393 项合并复验包含此回归。候选制品身份同步纳入 governor 与 cleanup 源码摘要，资源策略或取消行为改变后必须刷新身份。


## T4 隔离 native worker 与会话接线

2026-10-18，新增 `native/diarization-candidate`，仅锁定候选 SDK，不改主服务 native package/lock、默认能力或运行配置。相对符号链接复用既有 PacketCodec；`traits: []` 关闭候选不使用的 SDK 文本规范化能力。SwiftPM 仍解析该上游二进制依赖；首轮下载停滞后通过原 URL 取回，SHA-256 与 SDK manifest 的 `5fa8c10d4ec26c1bb2413125f351a7222a4c68a23b74476680fbada7e26fc6aa` 一致，再由 SwiftPM 从缓存校验使用；未下载模型。

worker 由单一顺序 task 独占 SDK，只走本地 `Nemotron3Models.load` 和流式 `appendAudio/processBufferedAudio/finishStream`。加载前要求预编译 bundle 和有限的 512-Float32 silence embedding；代码要求静态 shape、FP16 I/O 与 Int32 长度字段匹配。未调用 `processComplete` 或带默认 200ms 过滤的 segments。输入每次最多 16,000 samples；响应最多 2,048 帧，JSON frame payload 最多 512KiB，保持原 64KiB header 限制。fast128 的千帧响应不能放入 header，该边界有超过 64KiB 的 fake 数据回归。

`meeting_candidate_session.py` 复用生产会话的 owner、计算准入、有界 updates 和精确回收；新增 transport 校验 runtime SDK/preset/compute units/shape 标志。调用者必须传入同一组合根 governor；它不能替代跨进程运行窗口检查。取消卡在 preflight 的真实 fake child 时，先回收精确进程，再释放 owner。概率维度、阈值、尾裁剪、异常 packet、慢消费者、owner/factory/回收失败和 IPC 身份均有 fake 覆盖。native 源码、包锁和新 adapter 进入 candidate identity，变更这些内容会使旧 spec 失配。

验证：21 个 Python 定向测试文件 `410 passed in 7.61s`；新增候选 session 文件含 17 项测试。`swift test --package-path native/diarization-candidate` 的 3 项测试先因缺少帧验证实现 RED，补实现后 GREEN；Debug CLI 编译通过。新增候选专用 GitHub Actions 工作流执行同样的无模型测试与 Release CLI 编译。本机 Swift 6.4 / SDK 27.0 已实测；Release CLI 构建通过（51.03s），SHA-256 `6dc10ad96f8109fac3b0bc5670cedcf2e63f36407b61a53ffd3d3ebf90534e60`；Mach-O `minos=26.0`、`sdk=26.0`。实际 CLI 的参数错误、缺制品、非允许 preset 三项启动拒绝检查通过，固定错误 packet 不含临时路径，无模型加载。Ruff 三文件及 Mypy 两源文件通过，staged diff 检查通过。

以上只证明代码编译、合成协议和资源生命周期；没有启动真实 native 模型，也未验证实际模型 shape、snapshot 来源、准确率、P95、共存或认证人数。T4 保持部分完成，T5–T8 未因此放行。审查仍由作者自行执行，无子代理；回退为 revert 本批提交，不涉及服务或用户数据。

## T2 评分接线复核

2026-10-18：按既定设计 §6.4 修正真实候选接入前的输入和判定语义。连续说话活动和带标签文字现在独立输入；前者计算 speaker-time/DER/JER/旧门，后者计算标准文字指标，不从一个流推导另一个流的边界。未观察文字必须两侧显式 `null`；空假设表示已观察到的全量删除。评分输出升级 schema 3，旧评分不能直接混入新汇总；不改写历史结果。

Ruling: 每场 product 总体 gate 仅作诊断，汇总使用每场逐人 gate、旧 gate，以及人数层 pooled/macro 总体门，符合获批范围；额外附加单场全区间 precision 会无意收紧设计。点值失败、区间证据不足、缺层分别报告，后续共同扩样不能复活点值失败。全量漏检属于已观察的点值失败，不能当作缺观察请求追加。

RED：独立文字输入接口缺失；随后人工 overlap 反例复现单场总体门额外收紧，旧评分 schema 未被拒绝；全量漏检被误记为缺观察。GREEN：五个相关文件共 126 项 fake 测试通过，Ruff 和 diff 检查通过。另将逐人 gate 临时替换回单场总体 gate，反例按预期失败，再恢复并复验。测试全部使用人工区间与文字，无真实音频、模型或运行态操作。

```bash
PYTHONPATH=src:examples/perf uv run --no-sync pytest --no-cov -q \
  tests/test_meeting_quality_metrics.py tests/test_meeting_diarization_quality.py \
  tests/test_meeting_evaluation_identity.py tests/test_probe_meeting_candidate.py \
  tests/test_meeting_candidate_session.py
```

T4/T5 的归属、来源锁和 runner 尚待接线；本批评分不签发人数认证或质量提升结论。用户已解除禁止子代理限制；此前自审记录保留为历史事实，后续可按任务边界使用代理。

## T5 来源锁工具

2026-10-18：新增 schema 2 catalog 准备入口，使用已有 `canonical_digest` / `file_digest`，复用旧语料准备器可提供的制品而不重做音频转换。来源/祖先、原录音摘要、已知全局人员连接为独立组；跨通道、窗口、派生版本及重复 PCM 不得跨开发/留出，不能以同一 PCM 的不同来源 ID 虚增组数。封存标记传播到派生组。自然单人、多人会议、连续片段和派生诊断分开，未知全局身份不宣称 speaker-disjoint。

固定来源池组顺序、参考规则、scorer、变换和实际文件摘要进入锁。输入制品仅从仓库外相对目录读取/散列，不解码真实音频；输出目录独占新建，不覆盖已有数据。缺人数层或来源数不足仅返回 `insufficient_sources`，不签收据、不消费留出，认证上限始终为 null。工具证明 catalog 自洽及文件摘要匹配，不证明来源声明为真，人工核验仍是前置。

Ruling: diagnostic 可与同来源 development 视图并存，但与 holdout 严格隔离；否则会阻断设计允许的开发前缀诊断。派生单轨/重混音不进入自然主认证池。所需留出池按预锁开发池的最大可用检查点预留；实际一次性留出数仍由最终共同开发终点固定，不由本工具选择。

RED：模块缺失；追加反例发现重复 PCM 可虚增组数、dataset/R004 录音标记未封存、开发诊断视图被误拒。GREEN：25 项人工文件测试通过，包含正向来源池、固定顺序、祖先循环、全局人员、字节变化、路径/符号链接、外部独占输出和 CLI 隐私错误。新工具通过指定 source path 的严格 Mypy，两个新文件通过 Ruff。与评分/身份/候选/旧 scorer 合并共 151 项通过；没有执行真实模型、质量/性能或运行态操作。

T5 仍不完整：共同检查点/不可复活调度、实际来源人工核验、真实候选 runner、开发收据签发与真实声学对照尚未完成。工具用法与精确 catalog 字段见[测试与验收](../developers/testing-acceptance.md#会议评测来源锁)。

## T5 共同检查点调度

2026-10-18：新增不可变 `CommonPrefixSchedule`。C1/C2 身份和来源组顺序固定到 manifest/scorer；1–4 人每轮仍跑 C0，5–8 人不伪造四槽对照。仅按 6/12/18/24 共同前缀接收完整配对结果；点值失败不复活，证据不足才扩样，缺观察停止，来源不足不跑零散检查点。C0 即使绝对门失败也保留为对照。跨人数层选择按同一候选交集，不把不同层各自胜者拼成完整通过。到上限仍不足的候选不进入选型，已在共同前缀通过的候选仍可参与后续比较。

状态恢复须和独立载入的来源/候选锁一致，并逐轮重放校验；拒绝换字节、换组顺序、缺候选、追加失败候选或终止后继续。此模块仅消费上游评分结论，不能代替真实评分/运行身份验证，不签收据或人数认证。实际 runner、跨场景 DER 排名、联合延迟和留出仍待接线。

RED：调度模块缺失。GREEN：17 项 fake 测试通过，两个新文件 Ruff、新 source 严格 Mypy 通过；七个相关测试文件合计 168 项通过。将跨层交集临时改为并集，反例明确失败，恢复源文件并重编译 bytecode 后复验通过。变异检查使用独立 Python cache，避免同秒等长源码恢复命中旧 bytecode。没有真实音频、模型、benchmark 或运行态操作。

## T4 活动与正文归属

2026-10-18：新增 `CandidateEvidence`，复用生产 `AttributionLedger`，不接收参考标签/边界。连续稳定帧合并为匿名活动区间，跨 chunk 保留 10ms 插话和 overlap。实际 ASR 完成项按词证据或显式整句区间归属，原始空白/标点/文字完整保留；歧义、过期历史和不完整结束保留 unknown，不借参考修正输出。

整数样本、epoch、连续 step/sequence、完整文字范围、尾部覆盖和 RAM 预算在边界校验。重复整句时间不能冒充词证据；生产者可显式选择整句粒度。历史按稳定水位压缩，中止只关闭实际处理区间，不补造未处理尾部。原文只供外部原始制品 sink，报告不含原文。

RED：模块缺失；完成后 cleanup 错误撤销 complete、浮点/bool 样本误收、整句词时间网格误收均由反例复现后修正。GREEN：17 项新 fake 测试通过，并与生产 attribution 回归合并验证；新 source 严格 Mypy、变更 Python Ruff、diff 检查通过。没有运行真实模型、音频质量/性能或服务操作；runner 与锁定评测 CLI 仍待接通，不能签发人数认证。

## T4 有界候选回放库

2026-10-18：新增 `run_candidate_stream`，在供给有界 PCM 时并发消费活动更新，复用调用方注入的共享 owner/session，不创建第二 governor。WAV 读取每次最多一秒，在线程中执行并在取消后加入读取再关闭。FixedTextReplay 只有一项前瞻，按原 ASR 生产者时序提供完成项，不输入参考 speaker/边界。原文和活动事件只交外部 raw sink，摘要不含原文。

总 deadline、慢 sink、输入失败、活动提前关闭和取消不返回成功；消费者退出与精确回收必须加入，回收失败保留现有 owner 隔离并报 `candidate_cleanup_incomplete`。1× 供给用累计样本时钟，快放不声称体验延迟。记录文字可用、活动水位、合并 append 耗时及 finish 边界；不把尚未拆分的准入/加载/推理耗时伪称为单项指标。固定 sidecar 明确不是当次真实 ASR，联合延迟与生产认证字段仍未观察。

候选身份加入实际归属配置、归属/runner/ledger 源码，拒绝旧 `not_connected` spec 与变更参数；artifact preflight 仍不启动 worker。运行器只是一项可复用机制，未签发来源/runtime 验证或质量收据；锁定 development/holdout CLI、来源核验、评分/调度及真实双路时钟仍待整合。

RED：运行器模块缺失、总 timeout 错误归为普通失败、preflight 仍声明 not_connected，以及最终 ASR 注册期间提前关闭活动流被误收为完成。GREEN：18 项新运行器 fake 和 1 项 preflight 身份用例通过，包含真实 CandidateActivitySession + fake worker 的 owner/隔离集成；与归属、旧 scorer/身份/来源/调度等相关测试合并验证。变更 source 严格 Mypy 与变更 Python Ruff 通过。没有真实模型/benchmark、服务、模型下载、安装或发布操作。

前一提交 `b432e93b` 的主 CI `39087242360` 和候选 CI `39087242479` 均在同一 SHA 成功；它们不证明本节未提交/后续提交的全量结果。当前真实质量结论仍为 no-go。

本批合并验证：上述十个相关测试文件共 `213 passed`，仅 fake/人工输入。追加 append 消费屏障验证，既拒绝提前关闭，也允许 buffering 空更新在 finish 后吐齐尾帧；屏障依赖私有 Candidate/C0 session 每次 append 发布一次更新（包括空更新），不等待活动水位追上 accepted。

```bash
PYTHONPATH=src:examples/perf uv run --no-sync pytest -o addopts= --no-cov -q \
  tests/test_meeting_candidate_schedule.py tests/test_meeting_evaluation_manifest.py \
  tests/test_meeting_quality_metrics.py tests/test_meeting_evaluation_identity.py \
  tests/test_probe_meeting_candidate.py tests/test_meeting_candidate_session.py \
  tests/test_meeting_diarization_quality.py tests/test_meeting_candidate_evidence.py \
  tests/test_meeting_candidate_runner.py tests/test_diarization_attribution.py
```

审查中禁用提前关闭 guard 后，尾部 ASR 注册反例按预期失败；恢复源码并重新编译 bytecode 后复验。fake pipeline 测试统一加 2 秒外层时限，避免错误分支等待真实会议用的长 deadline。

## T4/T5 固定 ASR 文件证据接线

2026-10-18：新增 `meeting_asr_sidecar.open_asr_sidecar`，将来源锁中既有 sidecar descriptor 转为 runner 的 `ScheduledText`，不读取参考制品。严格 JSONL header 绑定 PCM、生产者与时间摘要，逐项保留原文、真实区间和词字符偏移；没有词证据则明确整句归属。禁止附带 speaker/参考字段，空识别作为已观察结果保留。

文件先有界完整预检，再从同一打开的 descriptor 回放并核对消费摘要和文件状态；替换、读取中修改、部分消费、重复键、超预算和无效因果/词时间均失败。候选源码身份包含此读取器；固定 sidecar 的生产者 provenance、真实联合延迟与质量认证仍为 false，未添加可以绕过门禁的收据/留出入口。

runner 的 sidecar ready/finish/close 文件操作移至线程，使用 `join_cleanup` 等待在途读取后再关闭。Ruling: 预检 proof 只证明实际字节、时间摘要与声明关联，生产者真实性仍须执行器独立证明；不能把文件自报 producer hash 变成运行证明。代价是本库不能单独签发开发收据，符合 T1 的身份链要求。

RED：sidecar 模块不存在；将 runner ready 暂时恢复为事件循环直接读取后，线程隔离反例按预期失败。GREEN：29 项新合成回归通过，包括磁盘 sidecar 与受监督 runner 集成、关闭前等待取消中的读取、后续坏行在 worker 前被拒、内容及时间摘要、文件替换、部分读取和文件/行/总量预算。恢复源码后，原十个测试文件加新 sidecar 文件共 `242 passed in 5.94s`，Ruff 和三项 source 严格 Mypy 通过。没有真实音频/模型运行、benchmark、运行态、安装或发布动作。公共格式见[测试与验收](../developers/testing-acceptance.md#固定-asr-sidecar-输入)。

远端核实：`5d08af28c4522ad677e78259b9977fb00f616e90` 候选 CI `39088576081` 成功；主 CI `39088576078` 失败。Python、打包与 App 构建成功，Swift package 的 `testAutoPublicationRetriesResumeFailedStepWithoutHumanReview` 在 `AppModelTests.swift:1594/1600` 观察到 publishing 而非 published，且音色名为 nil。该用例不在本批改动范围，失败原因尚未确认；不把此前绿色 SHA 或本地定向回归当作该 SHA 的全量通过。

## T4/T5 开发回放与共同检查点接线

2026-10-18：新增 `meeting_development_fixture`。单场入口验证 schema 2 development manifest/split-lock、文件/时间/评分依赖和外部路径，将实际 WAV、固定 ASR、候选活动、正文归属及独立评分连接；不读取 holdout，不把参考提供给 activity factory。正文参考与活动参考是独立的匿名整数样本区间，评分结果不含正文或绝对路径。

共同检查点入口消费冻结的 `CommonPrefixSchedule`，完整预检同一来源前缀后串行执行 C0 和所有存活候选，每场回收确认后再构造下一场。完整配对结果进入来源组产品汇总及 DER/cpCER 不退化门，near/far 分列；只有完整成功才返回下一不可变状态。部分执行失败不记录新轮次，不复活淘汰候选。候选摘要绑定执行器、来源准备器及调度源码；评分器提供可在加载模型前调用的依赖/政策核验。

文件指纹和摘要在执行前后与完成提交前重复核验。预检 WAV 逐包扫描完整制品，不只相信 header；读取、评分和大制品写入在线程执行并加入取消清理。输出目录独占且为 0700，文件为 0600；正文只进入仓库外事件文件，限 256 MiB，参考各限 16 MiB，评分各限 100,000 段。正常结果先同步 partial，再以独占 link 提交；取消不能留下 completed 结果。跨会议只保留指纹，避免预检把整个来源池正文留在 RAM。

Ruling: 此执行器连接真实输入/输出与评分，但 factory 的实际模型/SDK/运行身份与跨进程排他仍由生产组合根证明；固定 sidecar 仍不是当次 ASR。结果保持 `runtime_identity_verified=false/certification_eligible=false/verdict=diagnostic`。调度 `passed` 只表示共同前缀评分门通过，不能签开发收据、解锁留出、证明联合延迟或宣布唯一胜者；代价是实际选型/认证仍须完成后续接线，避免自报候选摘要升级为执行证明。

RED：执行器/检查点入口缺失；反例复现完成报告写入期间取消仍留下 result、仅首包检查漏掉后续 PCM 截断，以及未在 worker 前拒绝不安全 fixture ID/评分 policy。GREEN：27 项新合成测试通过，包括 6 组 × C0/C1/C2 的完整串行回放、来源组配对统计、near/far 缺观察、文件变化、部分检查点失败、raw artifact 预算、取消进入/关闭、来源池 RAM 和已存在目录保护。与原十一文件合并为 `269 passed in 7.29s`；变更 Python Ruff、三个 source 严格 Mypy、diff 检查通过。无真实音频/模型运行、benchmark、下载、服务、安装、发布或合并。

上一提交 `c5ab132e33ac6234aeeec72360a7b8beb2b6207c` 的主 CI `39089125203`、候选 CI `39089125321` 均已成功；这不证明本节新提交的全量结果，也不解释此前音色测试的失败原因。T4/T5 仍缺生产组合根/runtime 验证、完整 phase tracing、跨层选型与评测 CLI；T6/T7 与真实质量目标未通过。

### ASR 并行只读核验

由独立只读代理核对 T8 复用路径，主代理复核图谱覆盖与关键当前源码：`compare_asr_windows.py` 尚未绑定完整 normalization/overlap/scorer，也未实现 10% 相对改善门，不作为 T8 放行器。后续优先新增 ASR A0 冻结及实际 callable 录证工具，以来源组配对区分管线敏感线索与已证明原因，不用 sidecar 或 ForcedAligner 时间变化宣称正文收益。

静态延迟措辞修正：meeting policy 是 20 秒 owned 滚动，关闭后等待 2 秒 grace，再允许 15 秒 review budget，并非固定 22 秒周期。连续语音无 VAD 提前关闭时，t=1 秒结束的早期区间可能等到首块 t=20 秒关闭、t=22 秒开始 review 才有 final，理想零计算也可等待 21 秒；这支持增加 fake clock 前置反例，不能据此宣称真实 P95 已测失败。主代理已直接复核 `asr_window.py`、`asr_window_coordinator.py` 的 policy/close/final 路径，并对代理引用路径调用 coverage；未运行真实 ASR、未改变窗口或预算。

本批验证命令（全部为人工输入/fake）：

```bash
PYTHONPATH=src:examples/perf uv run --no-sync pytest -o addopts= --no-cov -q \
  tests/test_meeting_candidate_schedule.py tests/test_meeting_evaluation_manifest.py \
  tests/test_meeting_quality_metrics.py tests/test_meeting_evaluation_identity.py \
  tests/test_probe_meeting_candidate.py tests/test_meeting_candidate_session.py \
  tests/test_meeting_diarization_quality.py tests/test_meeting_candidate_evidence.py \
  tests/test_meeting_candidate_runner.py tests/test_meeting_asr_sidecar.py \
  tests/test_meeting_development_fixture.py tests/test_diarization_attribution.py
```


## T4 分人阶段耗时与回收观测

2026-10-18：新增可选、有界 `PhaseTrace`，在实际计算准入、worker start/preflight、append/finish 请求和 exact-child 回收路径记录五类阶段。准入计时在资源获准时结束，加载只记录实际 start task 一次，close 记录到回收/隔离确认；重复 finish/cancel 不复制事件。默认关闭，不改变模型输出、公共接口或安装态。

事件只含固定标签、样本位置和数值时钟，先写 RAM；runner 在租约外逐次排空。时钟抛错、非有限值、倒退、bool 或容量溢出会永久使 trace 不完整，但不阻断 child 回收。失败回收保持 owner 隔离，取消的排队不伪造模型推理。append 总耗时在写 phase sink 前截取，避免将制品写入算为模型工作。source identity 纳入 trace 实现，变更后须重新冻结候选。

Ruling: `phase_trace_observed` 只表示无丢失且五类阶段均有 completed 记录；host wall time 包含 IPC/native 等待，取消时阶段可能交叠，不是 kernel 时间，也不能直接相加。注入时钟标记 injected；固定 sidecar 仍不证明当次 ASR、联合 P95、真实 runtime 或人数认证。生产组合根仍须实际启用并导出 trace，不能因可选代码存在宣称真实负载已测。

RED：trace 模块缺失；反例覆盖 queue 与 load/infer 分离、close 未确认前不发完成事件、回收失败隔离、时钟异常与溢出不妨碍清理、sink 错误脱敏。GREEN：13 项新 fake 回归通过；与原相关测试合并为 `282 passed in 6.31s`。随后修正 append 总耗时不得包含 phase sink 写入，相关 31 项回归 `31 passed in 0.26s`；变更 Python Ruff、生产三个 source Mypy、评测三个 source 与 trace 严格 Mypy、diff 检查通过。没有真实音频/模型、benchmark、下载、服务、安装、发布或合并。

远端核实：上一提交 `f0bacd5f4a95d1c312230b185569a3398240c4c6` 的主 CI `39089905037` 和候选 CI `39089904957` 均成功；不将其作为本节新提交的验证。

```bash
PYTHONPATH=src:examples/perf uv run --no-sync pytest -o addopts= --no-cov -q \
  tests/test_diarization_phase_trace.py tests/test_meeting_candidate_session.py \
  tests/test_meeting_candidate_runner.py
```


## T8 ASR 实际 callable 诊断库

2026-10-18：独立执行者仅拥有 `probe_meeting_asr_quality.py` 和对应测试，主线拥有 DIA trace，写入无重叠。接收后主代理复核新文件与实际生产 coordinator/WindowPolicy/admission 路径；图谱对新文件缺索引，关键结论依赖当前源码，未重建索引。

新增库将冻结 PCM/主参考/来源组与 `MeetingCandidateSpec`、调用前后观测字段匹配、实际 `WindowAsrSession.decode` 录证、生产 coordinator 封存正文及独立评分连接。每个诊断 case 最多十分钟 PCM 常驻 RAM，长块按固定音频网格≤30秒且不使用参考边界/文字；有界长块不是生产替代候选。生产重放接调用方 VAD/review adapter，支持 retained frontier/pre-roll/EOF drain；错误、无调用、缺完整覆盖、重复、截断、超时、无主分母和未观察 token-limit 均不放行。关闭通过 join_cleanup，重复取消不能提前丢失回收任务，厂商错误脱敏。

raw/normalized CER/WER 分列与确定性 S/D/I 最短路径统计；ForcedAligner 时间变化不计正文收益，编辑操作不冒充声学归因。关键事实、独立重叠 ORC 和声学归因仍缺观察；混合 WER 不冒充独立英文子集验收。身份绑定工具源码、normalization/overlap、同分路径和汇总口径，运行分包/窗口/时限另有 replay policy 摘要。

Ruling: 接收初稿把 pooled CER 点改善与来源组等权 macro CI 混用。真实候选尚未输出，主线先用反例复现估计量差异，再统一为来源组等权主 CER 点值和同口径配对区间，pooled 单列诊断，并同步设计 §6.6/评分身份。case 内重复平均 errors，同源片段合并分子分母，独立来源各一票；不能以重跑或拆片增大独立 N。保持≥10%点改善、CI上界<0、基线0时relative=null；不降低既定门槛。

Ruling: observation.origin 自报为 runtime_observed 和字段相等，不能证明可信组合根、真实 adapter、token-limit telemetry 或安装态。该库始终 `runtime_identity_verified=false/certification_eligible=false/a0_execution=not_observed`；development_text_gate 不签收据。顺序 feeder 每包 flush intents，不等价独立实时采集/P95 benchmark；fake clock 首次 final≥22秒仅为生产窗口的合成反例。主线另复现非法 NaN/inf/bool clock 被接受后修正，clock 必须有限且单调。

RED：模块缺失、身份/时限/尾部覆盖缺口、取消回收和认证自报误用、S/D/I 缺失；主线的点值/区间口径差异和非法时钟反例均先失败再修复。GREEN：50 项 ASR fake 回归通过；与前述全部相关回归合并 `332 passed in 6.67s`，仅合成 PCM/参考与 fake decoder。随后将来源字段明确命名 source_group_id，避免原始 meeting 与泄漏关联组混淆；最终针对性复验 `50 passed in 0.24s`。ASR source 严格 Mypy、两项 Python Ruff/format 通过；未运行真实音频/模型、性能质量 benchmark、下载、服务、安装、发布或合并。T8 工具可诊断，不代表实际 A0 已冻结或 CER 改善已实现。

```bash
PYTHONPATH=src:examples/perf uv run --no-sync pytest -o addopts= --no-cov -q \
  tests/test_probe_meeting_asr_quality.py
MYPYPATH=src:examples/perf uv run --no-sync mypy --strict --follow-imports=silent \
  examples/perf/probe_meeting_asr_quality.py
```


## T4 原生候选开发入口与继承排他锁

2026-10-18：新增 `meeting_candidate_execution`，并扩展 probe CLI 的 `evaluate-development`。入口连接一个冻结 development fixture 的 C1/C2 原生候选、共享串行 governor/owner、有界回放、阶段观测和标准评分；原 preflight 保持只读。实际原生 SDK/preset/compute/shape 握手必须成功，之后每个 packet 继续校验；模型/worker/adapter/scorer 的文件摘要及 inode/mtime/ctime 等在构造前、finish/cancel 后和评分后核验，修改后恢复字节也拒绝完成。控制 JSON 限16MiB，拒绝重复字段、NaN、符号链接及非普通文件。

为防评测与服务竞争同一实例，入口使用 serve 相同的 per-user/per-port flock，不写服务 owner 元数据。CoreML transport 新增默认关闭的 inherited_guard_fd；只有显式传入时才向精确 child 继承。父级释放只 close，不执行 LOCK_UN，避免解锁仍活着的 child；启动时拒绝 bool/负数/失效 FD，不接管调用方 descriptor。子任务只写 transport 和测试，主线写执行器/CLI，已复核无同文件冲突。

Ruling: 该锁仅排除显式配置的服务端口，不探测其他端口、自定义运行实例或替代 managed lifecycle；真实调用须提供实际服务端口并遵守模型运行授权。内核子进程测试证明继承 FD 在父级关闭后仍排他，不证明真实 CoreML orphan 场景已经实测。finish 墙钟含制品核验开销，不作真实联合 P95。当前入口只执行一个候选/fixture；C0 组合根、共同检查点 CLI、跨层选型、来源与最终联合身份、开发收据/留出/安装态仍未完成。

`candidate_execution` 进入完成制品前由 async verifier 核对文件、原生握手和 exact-child 回收；字段集封闭且类型严格，不允许通过扩展字段带入文字/路径。模型 revision 来源、真实联合 ASR 与生产认证保持 false，顶层 runtime_identity_verified/certification_eligible 仍 false；没有把握手或文件一致升级成产品认证。候选 source identity 纳入执行器与 server lock，旧 spec 必须重新冻结。

RED：执行器模块不存在；transport 的四项 FD 反例先失败；附加 observation 带入文字的反例先成功写出后被修正为拒绝。GREEN：新执行器15项fake/合成回归通过，transport21项通过（新增5项）；与既有相关回归共 `368 passed in 5.19s`。覆盖实际 fixture/scorer/保存摘要接线、fake native握手与错误回收、文件修改与恢复、评分后修改、holdout角色拒绝、同端口服务冲突、无模型子进程继承锁、CLI显式分派及脱敏。五个 source 严格Mypy、七个变更Python Ruff、diff检查通过；两项 CLI --help 实际执行通过。没有执行真实 evaluate-development、音频/模型/benchmark、下载、服务启停、安装、发布或合并。

上一提交 `c450e962f09133080d583545d2bd92e9769b938e` 的主CI `39090801065` 与候选CI `39090801088` 均成功，不代表本节后续提交的全量验证。

```bash
PYTHONPATH=src:examples/perf uv run --no-sync pytest -o addopts= --no-cov -q \
  tests/test_meeting_candidate_execution.py tests/test_probe_meeting_candidate.py \
  tests/test_meeting_development_fixture.py tests/test_meeting_candidate_session.py \
  tests/test_diarization_worker.py tests/test_diarization_phase_trace.py \
  tests/test_meeting_candidate_runner.py
```

### ASR 后续接线核验

独立只读代理核对当前生产装配，主代理覆盖检查并直接复核 `services.py`、`qwen3_window.py`、`qwen3_worker.py` 关键路径。实际 window review 的预算由 worker `_dynamic_budget(duration,self._max_new_tokens)` 计算；window RPC 不发送 max_tokens，组合根先创建 batch shared owner 后供 streaming/window 复用，不能把 streaming 配置值直接当有效 window cap。review 已强制 EOS、拒绝 length/truncated，不能说它没有截断检查；但 budget/finish_reason/truncated 尚未随成功结果跨 RPC 保存，当前 token_limit_hit=None 仍不可替换为False。

下一 ASR 切片应复用正式 Realtime session 的 VAD/admission/boundary 路径及独立有界输入时钟，再贯通每 attempt 的有效 decoder 证据；不复制生产 frontier 规则、不把顺序 feeder 当采集基准。该核验无模型/服务/留出操作，没有冻结真实 A0 或改善 CER。


## T4 四槽 C0 共享执行接线

2026-10-18：新增 meeting_c0，冻结当前生产四槽 C0 的 worker/model/source/scorer 身份。模型要求生产固定文件哈希和 MIL 签名；外部目录中其余文件也纳入字节摘要。配置绑定旧 SDK 的 balancedV2_1、all compute、生产 >=0.25 阈值、不做 consolidation/ghost/短轮丢弃，并记录原生 EOF 私有右上下文补齐与输入样本裁剪。probe 的只读 preflight 和显式 evaluate-development 按冻结 implementation_id 分派，拒绝未知实现。

C0 通过原 CoreMLActivitySession 解码，评测子类额外验证连续四槽概率覆盖和 EOF，保留阈值边界及单样本尾音；共享端口继承锁、先 claim 后构造、串行 governor、阶段观测、制品完整性检查、exact-child 回收和统一 fixture/scorer 路径。C0 只作为 ≤4 人对照；共同检查点 CLI 仍待接线。

Ruling: C0 protocol 1 原生 preflight 只有 ok，native_preflight_observed 仅记录该握手，不证明 SDK/config/shape/build provenance。static spec 的 SDK/config 是被源文件和固定 revision 绑定的声明，不能升级成原生执行证明；runtime_identity_verified/model_shape_verified/production_certification 继续 false。没有更改生产 worker、默认解码或 public contract。

RED：新模块缺失导致10项反例失败。GREEN：C0 spec/变更拒绝/生产模型字节/阈值边界/尾音/缺帧/非法概率，以及合成 WAV → fake protocol-1 → 实际 fixture/评分/保存摘要的完整接线，与原 probe/执行器共59项通过。严格 Mypy 三个 source 与 Ruff 四个文件通过。未执行真实模型、音频、benchmark、服务、下载、安装、UI、发布或合并。父提交 7ac3892 的主 CI 39091457710、原生 CI 39091457684 均成功；不能作为本节后续提交的全量验证。


## T8 逐 attempt 解码观测跨 RPC 传递

2026-10-18：新增内部 WindowDecodeObservation，并贯通生产 Qwen3 engine → window.result → Qwen3WindowSession。字段包括 kind、decode_max_new_tokens、generation_max_new_tokens、finish_reason、truncated、generated_token_count；缺整个观测或缺可选字段均保持未知。consumer 拒绝额外字段、非法类型/范围和 preview/review kind 错配；取消与错误回收继续沿用既有路径。

Ruling: 动态窗口 budget 与生成 budget 分开：decode_max_new_tokens 记录真实 transcribe/Bound decoder 调用入参；preview 扣除复用 prefix 后的 remaining_tokens 才是可观测 generation budget。preview token count 在 header strip/prefix merge 前取 generation.tokens 长度，不能用最终 raw_tokens 长度代替。review 的内部 generation budget/count 未观察，保持 null。finish/truncated 不再隐式 str/bool 转换；缺失保持 null，既有 review EOS/截断拒绝规则不变。未调整预算公式、复用策略或公共 Realtime 契约；评测端逐 attempt 消费、正式 Realtime 组合根与实际 A0 仍待接线/授权实测，不宣称 CER 改善。

子代理独占四个生产 source 及三个相关测试，主线只改 perf/C0 与文档；主代理复核当前 diff 和图谱覆盖，索引 generation 2026-10-17T22:35:42Z 为主 checkout，故关键证据以当前 worktree source 为准，没有重建索引。新增回归先 RED 后 GREEN；子代理 targeted fake 验证111项通过，Ruff七文件和 Mypy四 source通过。未运行真实模型、benchmark、服务或 UI。

主线联合复验：21个相关测试文件共 `490 passed in 7.29s`；11个变更 Python 文件 Ruff 通过；7个 source 按项目 strict 配置执行 Mypy 通过（保留 pyproject.toml 的 warn_unused_ignores=false）。额外强制 --strict 会覆盖该开关，报告六处既有 vendor import 的 unused-ignore；未为消除此命令差异改写依赖策略。CLI --help 与 diff 检查通过。上述证据均为机制/合成回归，不证明真实质量或人数认证。

## T8 逐次观测进入正文诊断判定

2026-10-18：正文诊断报告升为 schema 2 / asr-body-v2，移除 RuntimeObservation.token_limit_hit 自报字段。_RecordedSession 在每次实际 decode 记录匿名 attempt 摘要、kind、样本范围、真实预算、可见完成元数据与明确/未知截断状态；最多4096次，超额不启动下一 decode。只有所有 attempt 均明确 eos + truncated=false 且 decode budget 不超冻结 cap，截断证据门才能通过。缺失字段保持未知，kind 错配不推进正文，超冻结上限失败；preview 的 length/truncated 不能被随后成功 review 掩盖。review 内部 generation budget/count 未观察时仍为 null，不以其他字段补造。

Ruling: 报告仅保留哈希、样本范围、计数和固定状态；未知 finish_reason 输出 other，不能回显厂商原串。compare_asr_runs 重新校验有界逐次记录、唯一 attempt 摘要、计数、范围、预算及记录摘要，不仅依赖 quality_evidence_valid。字段/摘要自洽仍不证明生产者或实际 A0，runtime_identity_verified/certification_eligible 保持 false；冻结真实生产 cap/权重/来源与正式 Realtime 装配仍待后续接线及授权实测。旧诊断报告不能复用新 scorer 门。

RED：8项反例复现自报未截断误放行、实际元数据未消费、unknown/kind/预算错误及缺逐次记录；另两项反例复现缺一次观测被后续成功掩盖及比较器仅信摘要布尔值。GREEN：ASR probe 62项，通过与 domain/worker/window/stream decoder 合并 `173 passed in 0.89s`；两个变更 Python Ruff 和 probe 按项目 strict 配置 Mypy 通过。12项新增参数化/普通回归包含4096次调用上限、preview 截断与最终 review 成功共存的拒绝。无真实模型/音频/benchmark、下载、服务、安装、UI、发布或合并动作。父提交 b0ab7db 的主 CI 39091938089、原生 CI 39091938093 均成功，不能替代后续提交验证。

## T4 原生共同前缀 CLI 与恢复

2026-10-18：新增 meeting_checkpoint_execution 与 evaluate-checkpoint CLI。独立 schema 1 控制锁绑定 manifest/split/scorer 的 canonical digest、绝对路径、三候选 spec 和模型/worker 路径、人数层及实际排他端口。来源组顺序沿用 manifest；C0固定四槽、C1=fast32、C2=fast128，scorer和角色不能互换。恢复仅接受 standalone schedule，由 CommonPrefixSchedule.restore 对独立初始锁重放有限历史，不能自选存活集合或继续终止状态。

NativeCandidateRun 抽取原单场 factory/verifier，单场与共同检查点复用同一原生构造、先claim后构造、共享串行 governor/owner、继承端口排他、握手与exact-child回收。全部注册候选制品和全部共同前缀来源在首worker前预检；大于四人不构造C0，已淘汰候选不执行。候选adapter source tuple抽为常量，额外绑定共同检查点组合根；scorer/policy源码和整个模型目录项也进入文件状态观察，既有spec需重新冻结。

Ruling: 逐fixture与最终checkpoint增加async verifier及同步commit hook。主线复核时发现最后_input检查后增加await会重新打开输入变更窗口；追加反例证实fixture最后verifier修改PCM/参考/sidecar，以及最终artifact校验修改controls/source/模型目录项/来源PCM，曾使completed误提交。修复为慢摘要校验在计算租约外执行，所有await之后同步核对controls、adapter/scorer、worker/完整模型目录项及输入stamps，再无await地os.link提交。未确认回收不提交；失败可保留先前单场诊断制品，但不能落checkpoint.json或推进调度。这只封住可观察异步窗口，不宣称跨进程、跨文件绝对原子认证。

子代理独占五个perf源与新测试，主线独占ASR probe/测试和文档；均无同文件写入冲突。主线对六条路径coverage复核均missing，改读当前worktree源码，不重建索引。28项新增fake回归覆盖18个fake worker完整配对、全部来源与候选预检、C0高人数排除、角色交换、独立恢复/存活集合、holdout、busy端口、无效握手、strict控制文件、CLI分派/脱敏及最终变更反例。子代理精确相关114项通过；主线22个相关文件联合 `530 passed in 10.67s`，8个本轮变更Python Ruff、6个perf source按项目strict配置Mypy通过，evaluate-checkpoint --help与diff检查通过。

未执行实际evaluate-checkpoint、真实音频/模型/benchmark、下载、服务、安装、UI、发布或合并。原生C0握手仍只有ok，source声明不是SDK/shape执行证明；全部结果保持diagnostic、runtime_identity_verified=false、certification_eligible=false、certified_max_speakers=null。共同检查点CLI已接线，跨层唯一候选、正式ASR评测组合根与真实A0/质量、生产联合身份、收据、留出及授权运行仍未完成。

## T8 共用开发来源加载与独立主参考

2026-10-18：新增 meeting_asr_source，复用共同会议development输入验证，读取已锁16kHz mono PCM16 WAV，保留最多十分钟AsrCase。另传主参考descriptor及严格JSON header，绑定fixture、development manifest canonical摘要和WAV文件字节摘要；主参考不从speaker区间文字、固定sidecar或候选输出推导，ambiguous/null保持未观察。原共享活动/文字/sidecar仍核对，但不进入ASR模型请求；loader依赖共同scorer环境，未伪装成独立通用导入器。

LockedAsrCase丢弃无关参考正文，仅保留不可变case和文件指纹；evaluate_locked_asr_case在callback前和退出时joined校验，返回前同步stamps并核对case/candidate摘要。修改后恢复、来源角色/绑定错误、未知字段、symlink、digest不符或回放期间变更均不能返回verified source结果。取消先由replay负责会话清理，再等待来源复核；普通callback错误和缺文件错误均脱敏。proof只说明字节匹配，人工参考来源与source catalog真实性保持false，生产身份/实际A0/质量不升级。

RED：12项新模块缺失及来源绑定/变更反例先失败；GREEN：19项loader合成回归通过，与原共享fixture合并 `46 passed in 1.91s`。Ruff两文件、loader按项目strict配置Mypy及diff检查通过。全部为合成WAV/参考，没有真实语料/模型、benchmark、下载、服务或安装/UI操作。父提交15a3f61c的原生CI39092542609成功；同SHA主CI39092542520仍queued，继续观察同一handle，不重启或推断失败。

## T8 正式 Realtime session 诊断重放

2026-10-18：新增 meeting_realtime_asr_replay，调用实际 OpenAIRealtimeSession start/update/append/commit/close；在 AppServices 快照装饰 window factory，共享原 worker、governor、admission 与生命周期。沿用生产 VAD/admission/boundary/EOF，核对协议有效设置与实际 window/language/context、VAD 类型及 admission 参数。逆嵌入把16kHz样本对(a,b)编为24kHz wire(a,b,b)，奇数尾样本一次保留，经过当前生产线性resampler后逐decode对比原PCM；它不是声学重采样或真实24kHz采集。映射版本、正式组合根及相关生产源码、有效配置、包/队列/时钟模式与时限进入replay policy。

独立生产者/消费者经有界队列供给，1×模式按累计wire样本计时；队列满直接失败，无静默丢包。超时、输入错误和取消先加入TaskGroup，再加入生产close等待当前有界decode，不强取消共享worker；total deadline不覆盖可能剩余的当前decode清理预算。只取sealed正文，核对连续terminal coverage和已排序不重叠final units；未知outcome拒绝。全部attempt沿用schema 2预算/完成证据，缺观测或失败不能被后续成功掩盖。

Ruling: streaming配置不是实际shared window cap。冻结max_tokens只作为caller upper-bound，每attempt真实budget必须由observation证明；window_decoder_config_cap保持not_observed。前后runtime callback匹配仅是声明，保持runtime_identity_verified=false/certification_eligible=false/a0_execution=not_certified，不能冒充可信A0、真实采集/P95或质量认证。新入口只接收已ready服务，不启动模型、探测安装或执行留出。生产者与参考来源真实性仍未认证。

56项新增fake回归覆盖随机/极值/奇偶与跨wire包/EOF映射、实际decode PCM逐字节、sealed正文、production boundary fallback、独立时钟持续供给、overflow、错误隐私、timeout/cancel joined、有效admission漂移、streaming配置与实际budget不同及终态非法数据。主线增加两个来源锁→实际session→评分集成用例，证明明确主参考评分与close后参考变更拒绝；source回归共21项。24个相关文件联合 `607 passed in 15.90s`，四个Python Ruff、两个perf source按项目strict配置Mypy通过。图谱为主checkout旧generation，新文件missing，主线直接复核当前worktree源码，未重建索引。

父提交15a3f61c的主CI39092542520和原生CI39092542609均成功；这是父提交证据。没有真实语料/模型、benchmark、下载、服务、安装、UI、发布或合并操作。实际A0生产字节和可信运行组合根、真实损失归因、CER改善、认证人数及联合延迟仍未完成。

## T8 ready 握手中的有效窗口预算

2026-10-18：生产Qwen3Engine公开只读window_decode_max_new_tokens，由动态窗口budget实际使用的_max_new_tokens得到，0仍按既有512默认处理；serve仅在window能力存在时跨私有ready帧传递。shared owner严格核对32–2048整数，缺失保持未知，bool/字符串/越界拒绝握手；关闭、失败与重启清除旧代观测，NativeWindowAsrFactory只在ready期间暴露。未改变动态budget公式、生成策略或公共Realtime契约。

正式重放观察到有效cap时，要求冻结decoder.max_tokens与之相同；已知值进入configuration/replay policy，退出时变化不能返回有效诊断证据。未提供该字段的factory仍按caller upper-bound逐attempt检查，保持未知与未认证。ready cap不是streaming配置，不是已加载模型字节证明，也不证明vendor包或实际A0；现有runtime revision来自模型结构握手，shape指纹不能当权重SHA。下一组合根须在加载前锁定模型/adapter/worker/interpreter/vendor字节，加载后再次核验并绑定同一shared owner/generation及aligner/VAD依赖，不能把准备后的文件hash推断为加载时实际字节。

RED：10项新增用例暴露ready无cap、owner/factory无观测；5项正式重放反例暴露冻结cap不符和退出变化仍放行。GREEN：补充不同engine cap与launch默认、0默认、重启缺字段不复用等边界后，7个相关文件 `228 passed in 4.95s`，包含实际fake framed subprocess与合成重放，唯一warning为既有asyncio.iscoroutinefunction弃用。7个Python Ruff、4个source按项目strict配置Mypy通过。没有真实模型、音频、benchmark、服务、下载、安装或UI操作；当前分人selector由另一执行者仅写两份新perf/test文件，无同文件冲突。

## T5 跨连续人数层的开发诊断选择

2026-10-18：新增 meeting_candidate_selection，接收独立初始schedules、冻结development manifest/scorer和各层最后完成checkpoint，恢复有限历史、要求1..required_max连续层passed，再取合格候选交集。逐fixture核对实际checkpoint的完整共同前缀、候选/来源/场景/sidecar/评分身份，低人数层C0跨层固定；已淘汰候选不复活，不同候选不能使用不等参考分母，cpCER缺失也不能掩盖DER分母变化。输入总JSON上限32MiB；当前schema每fixture只有一次执行，重复行拒绝，不伪造repeat ID或增加独立N。

选择采用含overlap、零collar独立DER组件，先同来源同场景合并错误量/参考量，再来源、场景、人数层等权；DER完全同分依cpCER，仍同分或缺同分数据则固定候选顺序并声明不确定。全局source cluster按完整人数层×场景incidence分块，seed1717/10000次配对重抽样，同源跨层和near/far共同抽取，保留每cell权重。主线发现初稿按层独立抽样且拒绝跨层同源，超出manifest允许范围；替换为全局来源抽样，两层反向差值但总体恒定的反例得到精确恒定区间，未缩窄合法输入。singleton分块差值区间保持null，不能宣称1个百分点非劣。

Ruling: 当前checkpoint没有真实稳定标签P95/峰值footprint观测链，二者始终not_observed，禁止使用自报verified或处理耗时代替，不触发未经观察的速度择优。报告绑定选择实现/固定policy及每层checkpoint摘要，但这些一致性检查不证明实际模型运行、产品验收或收据可信性；selected只是开发诊断建议，全部runtime/certification字段继续false/null。正式CLI、真实开发结果、可信模型/生产者、质量/延迟门及收据仍待完成。

31项新增fake测试包含实际evaluate_development_checkpoint的18次合成WAV/fake Activity结果原样输入、独立锁/连续层/固定C0/精确配对/缺场景与DER/淘汰交集/同源片段合并/跨层全局bootstrap/cpCER同分/不接受自报时延/实现与输入摘要。缺DER保护mutation按预期失败，恢复后全部通过。主线复核新文件和依赖当前源码；图谱为旧主checkout且perf文件missing，未重建索引。子代理独占两份新perf/test，主线独占ASR遥测及文档，未覆盖并行修改。父e821bd13的主CI39093218903与原生CI39093218867均成功；无真实模型/语料/benchmark、下载、服务、安装、UI、发布或合并动作。

主线对全局来源抽样修正后的26个相关文件联合复验：`678 passed in 13.93s`，仅既有asyncio.iscoroutinefunction弃用warning；本轮9个Python Ruff、5个source按项目strict配置Mypy通过，diff检查通过。上述结果只证明合成机制和离线接线，不证明实际CER改善、真实分人上限或P95。

## T5 离线候选选择命令与独立输入锁

2026-10-18：新增 meeting_selection_execution 和 select-development CLI。独立 schema 1 selection lock 绑定 development manifest、scorer policy、连续1..required_max各层的原始空schedule与完成checkpoint，全部descriptor核对canonical JSON摘要。输入单文件限16MiB、合计限32MiB，拒绝重复键、未知字段、bool代整数、相对路径、叶符号链接和非普通文件；不从checkpoint反推初始存活集合。选择复用既有跨层配对算法，不构造worker或加载模型。

加载、评分后、写出后核对输入及直接执行/评分源码的摘要与文件状态，最后同步检查stamps、无await提交selection.json。取消先加入离线线程，失败不提交完成结果；输出采用仓库外新0700目录与0600文件，错误只保留固定状态码。修改后恢复字节仍因状态变化拒绝。报告中的input_files_verified只说明文件核对，selection_control_sha256/selection_executor_sha256只绑定诊断输入与代码；不签发可信development receipt，不解锁留出，所有runtime/certification字段保持false/null。CLI源码属于候选adapter身份，旧spec需按修改后的源码重新冻结。

18项新增合成回归覆盖实际CLI分派、严格schema/摘要/文件类型、总量预算、取消join、评分及最终写出后输入变更、隐私输出和既有目录保留；前16项在新模块缺失/CLI缺命令时先RED后GREEN，后补两项预算/FIFO保护。与selector、原probe和checkpoint执行器联合 `110 passed in 4.47s`；三个Python Ruff和两个source按项目配置Mypy通过。父提交1a9b6817的主CI39093880641、原生CI39093880632均成功，不替代本节变更验证。没有执行真实音频/模型/benchmark、下载、服务、安装、UI、发布或合并；ASR组合根由另一执行者独占新文件，无同文件写入冲突。

## T8 私有生产 ASR 组合与加载前文件冻结

2026-10-18：新增 meeting_asr_runtime。显式调用时以生产build_app_services创建私有ASR/aligner，拒绝TTS/DIA/job设置，不借用运行服务、不启动RuntimeLifecycle；构造未打开voice registry，不读取私有音色。加载前冻结模型、必要VAD、三个解释器角色、显式依赖目录和生产/评测Python源码，准备后及正式来源锁回放后复核。两个私有transport禁止写bytecode，宿主不改全局flag；声明目录的任何变化仍拒绝。ready实际cap、共享owner/generation、aligner ready/process对象和有效配置进入比较身份，sdk_revision明确为filesystem closure/config摘要，不是导入SDK版本。

主线复核推动补齐目录/源码扫描错误不能静默遗漏、resolved target以nonblocking/nofollow打开并fstat防FIFO替换、0预算对应有效512语义、完整transport环境摘要和错误路径脱敏。执行者另以RED反例修正freeze期间配置变化遗漏，以及candidate身份此前未绑定aligner/VAD/全部源码与依赖closure的问题。取消加入hash/prepare和后台回放后才关闭两个确知拥有的child；替换process不误关，其他已确认child仍清理。Silero预热cache key拒绝，但不清空宿主共享缓存；aligner无generation，只保护对象和ready identity。

Ruling: preload/post-prepare/post-replay证明具名文件稳定及对象核对，不能证明实际loader/import消费字节。loaded_model_bytes_verified/actual_imports_verified/source_import_bytes_verified以及runtime_identity_verified/certification_eligible保持false，A0为not_certified；尚无真实转录/分人质量、认证人数或P95结论。入口仅为显式库API，不执行留出、不签收据，不自动发现模型或启动managed服务。

执行者独占两份新source/test，主线只改文档，无覆盖并行改动。44项新增fake回归包含真实production owners/factory与正式OpenAIRealtimeSession接线，仅替换推理/RPC；主线十个相关测试文件联合 `361 passed, 1 warning in 11.87s`，warning为既有asyncio.iscoroutinefunction弃用。两个新Python Ruff、一个source按项目配置Mypy、diff检查通过。图谱generation 2026-10-17T22:35:42Z中新文件missing，关键结论以当前worktree源码复核，无索引重建。父提交4fc7bdb4的主CI39094547962、原生CI39094547939均成功；不是本节提交的CI证据。没有真实语料/模型/benchmark、下载、服务、安装、UI、发布或合并动作。后续仍需可信实际A0/加载来源、真实损失诊断、唯一分人候选及联合质量/延迟验收。

## T8 framed worker 的显式描述符继承

2026-10-18：为ASR正式执行器贯穿子进程排他锁补充最小transport前置。WorkerProcessSpec新增pass_fds，默认空；只接受最多16个唯一、非bool的3及以上整数，禁止隐式继承stdio或任意宿主描述符。AsyncFramedWorkerProcess将显式集合传给create_subprocess_exec；调用方仍拥有父级副本，transport只随精确child退出回收其继承副本。普通生产调用未传FD时保持空集合。

8项新增反例先因字段缺失RED，再GREEN。两个真实无模型Python子进程共同继承同一flock，父级close后任一child存活仍排他，最后一个child回收后才可重新取锁；空集合不泄漏该FD。六类非法参数拒绝。与shared/window worker联合 `95 passed, 1 warning in 3.85s`（既有弃用warning），两文件Ruff、transport项目Mypy通过。此证据不代表ASR正式执行器、真实CoreML孤儿场景或产品并发已经验收；root锁接线与正式driver由其他执行者独占perf文件继续实施，无同文件写入。无真实音频/模型/benchmark、服务、下载、安装、UI、发布或合并动作。

## T8 预登记 ASR 单场执行与关闭后提交

2026-10-18：新增 meeting_asr_execution 与专用 evaluate-development CLI。独立严格控制锁绑定来源、主参考、配置、显式依赖和事前candidate spec；settings仅init source，关闭环境/dotenv/secrets，并覆盖直接读环境的legacy validator。禁止未知字段、服务密钥和非ASR配置；模型真实路径外置，允许受冻结保护的解释器/依赖file symlink。来源先于模型预检，不接触holdout、不从本次转写输出生成A0。

私有root在同一次preload snapshot后、prepare前核对expected静态文件和closure/config，ready后核对完整spec。两个私有child继承声明端口的同一锁；候选摘要绑定uid/port/namespace/角色数量，实际FD/file identity另守卫，瞬时FD号/inode不定义稳定candidate。正常退出必须确认原process.returncode和transport清空，joined完整核对关闭期间的字节/配置；只有成功路径获得verify_closed/verify_commit资格。失败、取消、替换owner或回收不明均不提交。Silero仍是宿主共享cache，不清理全局缓存。

driver在context退出后复核关闭证明、controls/source，再写0600 partial。partial内容、inode/stamps及输出目录身份也受守卫；最终所有await完成后同步检查controls/source/runtime和partial，再exclusive link提交result.json。主线补充model bundle文件symlink指向仓库的RED反例，改为同次preload inventory对全部model entry.resolved在prepare前拒绝，封住仅验证model root的缺口。错误与报告不含路径、正文或环境值；声明端口排他不证明其他端口无实例。

runtime新增19项、driver54项、CLI5项fake回归；主线五个ASR相关文件 `204 passed in 11.22s`，六个本节Python Ruff通过，root/driver/CLI按项目配置Mypy通过。transport其他调用面额外TTS/streaming/aligner的93项fake回归通过。两执行者分别独占root/driver，主线独占CLI/文档，停写后统一复核；没有覆盖并行改动。父提交6e6f4837主CI39095347788和原生CI39095347813均成功。没有真实语料/模型、benchmark、下载、服务、安装、UI、发布或合并动作；loaded/import bytes、实际A0、CER改善、认证人数及联合P95仍未证明。

## T5 来源片段聚合与扩样耗尽后的合格选型

2026-10-18：独立只读审查确认三处问题。第一，C0不退化检查点将来源片段率当重复执行平均；六组来源各含参考量1000/1的片段，C0错误量0/0.8、候选20/0时，旧DER差值为−0.39而正确来源差值为+0.01918081918，应点值失败。第二，产品汇总先平均来源片段speaker-time，使多片段来源被稀释；一组1000片段精确率0.94、另五组单片段完美时，旧pooled为0.98947368，正确为0.94028068，应失败。第三，24组耗尽时，证据不足候选使调度成为evidence_exhausted，却错误阻止另一名已合格候选进入跨层选择。

修正为同一来源片段分子分母求和；DER/cpCER独立scorer身份和分子分母校验复用同一函数，检查点与最终排名保持一致。唯一fixture只执行一次，重复行拒绝。statistics.fixture_aggregation固定one_execution_per_fixture_source_totals_v1，进入policy及关联身份；旧policy拒绝，旧manifest/spec/schedule/checkpoint须重新冻结并重算，不重写历史报告。选择允许完成的evidence_exhausted且非空合格集合，证据不足候选仍不合格，连续人数层及候选交集要求保留。

两处聚合和耗尽选型均先以反例RED复现，再GREEN；另补cpCER、重复fixture和旧policy拒绝回归。此前八个相关文件228项fake回归通过；提交前重新核验结果见本节后续记录。仅验证合成评分与离线选型，不证明实际CER、分人质量、认证人数或P95。没有真实音频/模型、benchmark、下载、服务、安装、UI、发布或合并操作。

提交前复验：八个相关测试文件 `228 passed in 5.14s`；六个Python Ruff通过，`MYPYPATH=src:examples/perf uv run --no-sync mypy --strict --follow-imports=silent examples/perf/meeting_development_fixture.py examples/perf/meeting_candidate_selection.py` 两个source通过。直接扩大follow-imports扫描会暴露既有非类型化评分模块和第三方stubs问题，不宣称整个perf目录strict检查通过。父提交6e6f4837的主CI39095347788与原生CI39095347813已核验成功；新提交CI另行核验。

## T8 ASR 比较器的字符计数一致性

2026-10-18：直接复核当前ASR比较器时发现，它检查normalized.cer有限值却使用未经复核的characters.errors/reference_tokens聚合；同一case重复记录沿用第一个参考分母。17项反例在修复前全部RED，包含bool/负数/非整数/非有限/越界、S/D/I与总错误不符、reported CER不符，以及配对或重复case分母漂移。旧实现部分直接使用非法值，零分母还触发除零错误，而非稳定拒绝。

修正为汇总前校验字符计数、S+D+I、参考与推导预测长度、编辑同分规则、两处CER和同case参考分母。保留现有source-group等权估计量、重复错误均值及片段分子分母合并；不裁剪合法CER>1，不把缺主参考升级为观察。增加正向边界回归后，六个ASR相关文件 `284 passed in 11.66s`；两个Python Ruff通过，一个source按strict/follow-imports=silent的Mypy通过。源码摘要属于ASR_SCORER身份，旧spec/report须重新冻结和执行；计数自洽不证明生产者、参考来源或实际A0。

图谱generation2026-10-17T22:35:42Z不含这三份新ASR source/test记录，结论由当前worktree相关源码直接复核，未重建索引。父提交54f2f11c原生CI39096340069已成功，主CI39096340067仍运行；新提交另行核验。没有真实音频/模型、benchmark、下载、服务/安装变更、UI、发布或合并操作。

## T8 预登记 ASR 离线对照入口

2026-10-18：新增meeting_asr_comparison与compare-development命令，独立控制锁固定case身份/样本数、两组候选与重放身份、报告descriptor和scorer。case列表定义事前诊断范围，每组恰好一份每case结果；不从本次输出推断A0，不打开音频/主参考/模型、不签可信收据。只接受未认证development报告，复用compare_asr_runs的计数、覆盖和配对统计。

JSON输入总量32MiB、单文件16MiB；评分前后与partial之后复核输入/源码。固定匿名报告、输出目录身份和partial内容/状态，最后无await硬链提交。取消加入离线线程；目录被替换时不向新目录写完成或失败文件。全部runtime/certification仍false，quality_gate固定fail，文字诊断门单列；人工关键事实状态只作为声明。

最初18项测试在模块缺失时RED，再GREEN；随后补取消join、最后校验期间partial变化、输出目录替换、既有目录保护/总预算、禁止打开音频或启动进程，以及CLI隔离分派/错误隐私。正式OpenAIRealtimeSession合成报告原样输入的集成用例先RED，发现mode尚未包含formal_realtime_session_diagnostic，补齐后GREEN，不修改生产报告。七个ASR相关文件联合 `310 passed in 11.46s`，四个Python Ruff、两个source strict/follow-imports=silent Mypy通过。无真实音频/模型、benchmark、下载、服务/安装、UI、发布或合并操作。旧spec需因CLI执行源码变化重新冻结。父7905a111原生CI39096529214成功，主CI39096529300仍运行，新提交单独核验。

提交前补充coverage_samples拒绝bool，离线入口与CLI两文件最新 `32 passed in 0.36s`，四Python Ruff、两source Mypy和compare-development --help通过；前述310项是加入该类型守卫前的联合证据。图谱四个新/改source/test均missing，直接复核当前源码，未重建索引。

## T8 同一冻结模型的正式与长块诊断接线

2026-10-18：确认已有replay_long_blocks库尚未接通私有root/执行入口，新增不可变AsrReplayPlan与schema 2执行锁replay字段。正式模式显式登记，长块模式冻结1–30秒块长与有限正数≤300秒的逐decode时限。旧schema 1锁拒绝，不隐式升级；相关spec/controls需重新冻结。模型candidate身份保持描述同一模型配置，实际重放mode/预算另由控制锁、diagnostic_replay及replay_policy摘要绑定。

root使用同一ready window factory创建长块session，沿用既有纯PCM网格、空context与逐attempt录证；source守卫、单回放约束、全量配置/字节核验、后台取消join及两个owned child关闭后守卫均复用。长块session由replay库关闭，driver核对返回mode/policy；错误或取消不提交。两种模式都保持a0_execution=not_certified及runtime/certification=false，长块不是可上线候选。

正式/长块执行用例先因新锁缺入口RED，再GREEN。新增注册计划/非法预算/旧schema拒绝、一采样尾包、mode/policy篡改与同模型同PCM两路径对照；原root的来源→实际factory/session回归扩展到两模式，覆盖权重/依赖/源码/generation变更及后台取消。134项root+driver在补最后三个集成用例前通过；最终联合验证见后续记录。没有真实音频/模型、benchmark、下载、服务/安装、UI、发布或合并操作。父71eef764原生CI39096827560成功，主CI39096827567仍运行，新提交另行核验。

最终七个ASR相关文件联合 `331 passed in 13.28s`；四个Python Ruff、两个source strict/follow-imports=silent Mypy与diff检查通过。同PCM的合成正式CER=0、长块CER=1按规则不能判改善，未因接通新路径而放宽诊断门。图谱六个相关source/test missing，当前worktree源码直接复核，无索引重建。

## T5 现有开发语料的元数据就绪核验

2026-10-18：仅检查已知SpeechRail benchmarks下issue370-sortformer-1to4-20261017与issue370-aishell4-test-20261017两个任务目录的清单元数据，未解码音频、读取参考正文或运行模型/留出。旧dev-v2/development.json实际为schema1、dataset=AliMeeting_Train_Near_1to4_Control_v1、source_split=Train_Ali_near、split_role=development，共4条，1/2/3/4人各1条；其fixture字段不含source_meeting_id/source_group_id/source_session_id/derived_from，也没有natural_single样本类型声明。不能据此证实独立来源数或自然单人，也不满足每层至少6组。该任务目录存在Train_Ali_near.tar.gz文件；仅文件存在不证明归档完整、来源声明、许可或可直接评测。

这两个已检查目录未找到文件名包含catalog的JSON；该范围内已查看的开发清单仍为schema1，不作全机不存在新catalog的断言。旧AISHELL-4材料位于test语料任务目录，不能通过改名或重分组绕过当前封存来源规则；本次没有用它追加development。未重写旧清单、音频、参考或报告。

下一真实执行前需提供并核验schema2来源catalog、原artifact root及独立主参考：来源/祖先、录音摘要、通道与变换、自然/派生样本分类、near/far、匿名参考规则和split隔离；不足则保持insufficient_sources，不伪造独立N。旧四条仅保留诊断价值。另已核对T6计划要求的bench_asr_diarization_overlap.py尚未实现；现有bench_overlap.py是ASR/TTS，不能替代ASR/分人四模式执行器。现有candidate runner使用固定sidecar，joint_asr_latency_observed明确false，不能从其墙钟推导真实联合P95。

代码提交3516875d主CI39097139430、原生CI39097139429均已核验success/completed。该证据仍是代码/构建/确定性门禁，不能替代上述数据就绪或真实质量。此节只改文档，diff检查通过，未重复运行测试。

## T6 四模式调度与 joined 清理基础

2026-10-18：新增bench_asr_diarization_overlap.run_workload_schedule，只接显式ASR/分人异步回调和同一个ResourceGovernor，无模型构造、CLI或文件写出。支持两个单路基线和serial/overlap；检查Governor是否空闲/可准入，交叠须显式启用且Governor允许。完成报告只在线程冻结JSON并散列，不回显回调中的原文或路径。超时/失败/取消不返回完成结果，外部重复取消加入全部子任务与散列线程。

最初14项模块缺失RED后GREEN。审查发现整条回调先ASR后DIA会制造错误串行基线：补两路互相等待feed-ready、但真实Governor计算必须互斥的反例，旧写法超时RED；改为联合模式都启动两路，由serial的非交叠Governor或overlap的交叠Governor控制真实计算，随后GREEN。另以反例复现asyncio.timeout被回调吞掉取消后仍返回完成，增加deadline.expired显式拒绝，RED后GREEN。

31项新回归覆盖两路真实Governor准入、模式及显式交叠保护、单路基线、失败时加入兄弟清理、超时、自取消、重复取消、异常隐私、时钟、报告非有限数、摘要线程及失败清理期间再次取消。与既有Governor联合 `64 passed in 0.44s`，两个Python Ruff、一个source strict/follow-imports=silent Mypy通过。生产Governor/limits/cleanup图谱coverage metadata_match，新source/test missing，当前源码直接复核，未重建索引。

Ruling: 只证明回调调度与清理，不证明共用PCM、1×输入、实际计算交叠、精确child回收、模型质量或联合P95。same_source/worker_reaping/runtime/certification及joint_latency/compute_overlap均false，quality/footprint/p95未观察。完整T6的共同源、实时正文/活动/稳定发布、进程footprint、冷/热ABBA及配对统计仍未接通；没有执行真实模型/音频、benchmark、下载、服务/安装、UI、发布或合并。父fda71298主CI39097526802及原生CI39097526765均成功，新提交另行核验。

## T5 原始训练语料定位与归档元数据核验

2026-10-18：用户要求自行查找、获取本机既有语料后，核对SpeechRail benchmarks目录文件大小，总量约37.504GiB，包含Train_Ali_near归档22.846GiB、Eval_Ali归档3.421GiB和AISHELL-4 test归档4.881GiB等；数据仍在仓库外。旧四条清单只代表已制备诊断组，不能据此判断原始语料不足或要求用户重新提供路径。

完整流式遍历Train_Ali_near的tar成员并计算压缩文件SHA-256：683个WAV与683个TextGrid按同stem一一配对，无重复轨道或未匹配命名；按原文件名的房间/会议组合分组得到209组，2/3/4个headset轨道分别69/15/125组。WAV成员字节41784790844、TextGrid成员字节20817666。当前完整压缩文件SHA-256与既有本机verify记录一致；该记录不是发布方校验，publisher_checksum_verified仍false。仅遍历归档与摘要，没有解码音频、读取标注正文、运行模型或进入留出。

2026-10-18重新核对[OpenSLR官方页面](https://www.openslr.org/119/)：Train总述为212场/104.75小时、每场2–4人，训练near为headset、许可CC BY-SA 4.0。本机按文件名得到209组与官方总述212场存在差异，不能静默补成212，也不能仅凭差异断言本地包损坏。轨道数不等于参考活动中实际观察人数；后续还需逐场标注/时轴/通道与来源组核验。此近场包不证明自然单人或远场覆盖。

元数据结果仅写仓库外的training-archive-metadata-20261018.json与meeting-corpus-inventory-20261018.json，不将轨道标识或原始参考写入仓库。可继续用已定位Train来源准备schema2 catalog与独立ASR主参考，先保留缺层及来源差异；Eval_Ali与AISHELL-4已有留出继续隔离，不为扩充development而改名或重分组。该进展不是开发通过、真实CER改善、人数认证或延迟验收。

## T6 联合回调自取消的失败传播

2026-10-18：复核TaskGroup对CancelledError的语义发现，联合模式直接在lane任务内执行回调时，回调自行取消会被TaskGroup当作普通child取消，另一条路继续等待至总deadline。直接抛CancelledError与current_task().cancel两项反例先RED；将实际回调置于独立任务，使lane能区分自身收到外部取消与回调自行取消，后者转为失败触发兄弟取消并加入清理。回调使用Coroutine包装保留原Awaitable契约，另有Future回调回归。

最新调度与Governor联合67 passed in0.45s、两个Python Ruff与一个source strict/follow-imports=silent Mypy通过；原失败/重复取消/后台摘要join用例全部保留通过。source/test图谱missing，直接复核当前worktree，无索引重建。没有模型或音频评测、下载、运行态或安装操作。父51ed0b40原生CI39098376192成功，主CI39098376236最后仍运行；85ef3d41原生成功而主CI39098268969已cancelled，不能把它报告为通过。

## T5 训练标注与 WAV 元数据准备

2026-10-18：从同一冻结Train_Ali_near包逐成员读取WAV头、计算原成员摘要，并提取683份TextGrid到仓库外新目录。完整归档摘要再次匹配原库存，读取前后device/inode/size/mtime未变。只解析训练标注与音频头，无PCM解码或模型运行，不打开Eval/R004材料。原始标注正文只留仓库外；来源计划使用匿名会议与轨道摘要、原成员摘要、WAV参数、相对标注路径和parser源码摘要，未宣称人工真值验证或schema2就绪。

683条音频头均声明mono/16kHz/16-bit PCM；683份标注均由现有textgrid_intervals解析为单tier，共186605个非空正时长区间。三条轨道的标注末端超过WAV时长，分别约4.5625/40/75ms；72个来源会议的轨道长度存在差异，最大581.375ms，均不超过1秒。没有静默裁剪末端、补PCM或按模型输出挑选来源。解析成功只证明结构及所检查的时轴关系，不证明标签风格、串音、活动真值、独立ASR主参考或自然会议场景。

现有schema2契约将headset重混音与单轨视为derived_mix/derived_single_track，仅可作diagnostic。此包因此提供可追溯派生诊断来源，不能伪装natural_meeting/natural_single补齐认证层。后续catalog仍需显式变换/标注末端规则、自然场景来源、独立ASR重叠顺序与主参考；保留meeting-disjoint声明，不假定global speaker身份或模型未见数据。没有生成虚假development就绪、CER改善、人数认证或P95通过。

## T6 共同 PCM 与样本末端供给时钟

2026-10-18：新增meeting_pcm_feed与run_pcm_workload_schedule，将同一不可变PCM/SHA锁、固定16k样本网格和有界独立队列接入四模式调度。所有消费者进入读取后确定共同原点；每包在样本末端deadline供给，不移动原点，不通过等待满队列制造虚假实时性；尾部单样本不丢失。摘要在线程核验，源/策略/宿主供给与排队量独立记录，回调总区间含自身初始化和清理。

最初8项入口缺失RED后GREEN；继续补供给方自行task.cancel、作用域关闭后的读取、真实/注入时钟同policy摘要三类反例，均先RED后修正。供给任务用独立守卫将自取消转失败以取消并加入消费者；外部重复取消不放弃源摘要线程；全部任务加入后关闭流、释放源与排队引用。真实/注入时钟进入policy摘要，不把合成供给时钟用于真实认证。

新增30项回归与既有调度/Governor联合97 passed in0.52s；三Python Ruff、两source strict/follow-imports=silent Mypy通过。用合成PCM覆盖两联合模式、相同对象/序列/尾样本、队列溢出、未读完、摘要不符、非法预算、提前/迟到、超时、自取消、重复外部取消、后台散列join及20ms默认宿主时钟路径。后者是无模型合成输入的功能回归，不是性能或P95实测。

来源一致性仍只到内存交付；模型实际接受、麦克风、稳定标签、生产字节、footprint及ABBA未证明。所有认证与联合延迟标记保持false。图谱新source/test及harness missing，直接复核当前源码，无索引重建。无真实音频解码/模型/benchmark/下载/服务/安装/UI/发布/合并。父f56c9b53原生CI39098626051与主CI39098626050均已核验success/completed，新提交另行核验。

## T6 共同 PCM 接入正式 ASR session 与私有 owner

2026-10-18：正式replay新增显式shared_pcm输入模式，与外部pcm_frames必须配对。逐包检查序列/连续样本/原case字节/时间元数据；跨包保留至多一个奇数kernel样本后完成24k逆嵌入，走同一生产OpenAIRealtimeSession/VAD/admission/window/commit/close路径。共同源决定供给，不二次重放或计时；metadata时钟统一external_shared_source_unverified，不能把注入源冒充本函数默认monotonic。原有逆嵌入仍只是当前resampler的诊断等价，不代表真实24k采集。

FrozenAsrRuntime捕获实际services与NativeWindowAsrFactory共用的Governor对象，cold/ready/replay/closed对象守卫一并核对。有效handle暴露该guarded对象，共同输入evaluate只接受同一对象与正式计划；缺失、不同对象、无流传Governor及长块配流均在读取来源前拒绝。通过原LockedAsrCase的字节与主参考守卫，单飞、全量源码/依赖/权重、generation及close后复核不绕过；没有新增隐式模型构造或CLI共同源发现。

共享输入与对象绑定检查先RED后接线，另以会话启动失败未关闭输入源、源自取消导致consumer等待及大源包小wire包导致同步队列假溢出分别复现后修正。源关闭恰一次；自取消变为失败并加入兄弟任务；内部满队列先给ready consumer一次事件循环机会，仍满失败，不等待容量或移动来源时钟。私有root集成扩展到shared_pcm，包括真实生产factory/窗口session上的合成PCM、源/依赖/权重/generation变动及上下文关闭时取消正在decode的回放；模型RPC均fake。

最终十个相关测试文件联合455 passed in14.90s；四Python Ruff、两source strict/follow-imports=silent Mypy通过。改动的ASR重放/私有root及tests图谱missing，直接复核当前worktree；生产factory/services coverage metadata_match，无索引重建。源码闭包与replay policy变化后，旧ASR spec/controls/report需重新冻结执行。共同Governor对象不证明DIA预算、实际加载字节或联合身份；DIA适配、live正文/活动稳定发布、footprint及ABBA未完成。无真实音频解码、模型/benchmark、下载、运行态、安装、UI、发布或合并，所有认证/实际A0标记不升级。父2e37b783主CI39099075868与原生CI39099075836均success/completed。


## T6 共同 PCM 接入原生分人活动与稳定帧观察

2026-10-18：新增显式shared activity库适配，复用候选runner的活动校验、finish与清理。text_replay=None表示本次未观察ASR正文，digest为null；不以空FixedTextReplay冒充live ASR。ASR与DIA共同使用PcmSequenceVerifier核对冻结PCM字节、整数序列/连续样本、单包与总包预算、有限源时钟及完整EOF，不二次重放或移动供给原点。外部frames在成功、失败、取消及启动校验失败后关闭，input_clock仍external_shared_source_unverified。

NativeCandidateRun.evaluate_shared_pcm复用创建时捕获的Governor、实际原生session factory、端口继承、制品检查与native preflight。不同/替换Governor在读源前拒绝，运行中替换也不返回成功；同一handle的共享执行单飞。原生session结束并完成exact-child回收与制品复核后才返回candidate_execution，runtime/certification仍false。C0和候选源码闭包加入共享活动与PCM模块，旧spec/report须重新冻结执行；不证明实际加载字节或最终联合身份。

每个通过因果覆盖检查的稳定活动帧单独输出stable_activity_frame、匿名active_slots和接收观察时刻，sink交付时刻独立保留。连续speaker评分区间可到finish才关闭，不能拿它的关闭时间冒充稳定标签延迟。未接live ASR正文或产品稳定发布，不能计算或宣称联合P95。另以两种活动pump自取消、重复外部取消的反例先RED：自取消转失败立即取消输入；整个回收/源关闭/制品检查清理放入独立owned task并由join_cleanup加入，重复取消不放弃清理。非法bool宿主时钟在读源前拒绝。

十一相关测试文件388 passed in9.96s；九Python Ruff、五source strict/follow-imports=silent Mypy通过。回归包含共同供给→实际Governor准入→活动适配的合成尾样本、原生候选factory上的fake RPC/preflight/guard/回收、字节/序列/EOF/时钟异常与取消。它们不是实际模型、真实音频或性能质量基准。图谱相关perf源码/tests missing，直接复核worktree，生产活动types为metadata_match；未重建索引。父3e479f9a主CI39099790104与原生CI39099790102均已核验success/completed。

T6仍缺live正文归属总线、产品稳定发布、资源footprint与ABBA；真实CER、人数上限和P95均未观察，#370继续未完成。未进行真实音频解码、模型/benchmark、下载、服务/安装、UI、发布或合并。语料路径复核确认benchmarks中的三个归档入口为指向同一app home下corpus目录的符号链接；原训练/留出角色不变，不重复下载或混入开发调参。


## T6 sealed 正文有界观察与活动归属

2026-10-18：新增LiveTextChannel/LiveTextObservation，明确单producer/reader、case与排队item/字符预算、实际样本范围及有限不倒退时钟。同步publish不等待消费；溢出、非法数据、重复producer或消费者中止使通道永久失败，释放排队引用并唤醒reader。失败observer不抛回ASR正文生产者，不能用后续finish恢复或复用旧正文；报告和repr不含原文。它是诊断观察通道，不是来源/身份认证。

正式ASR session接收端只转发sealed final_units的非空实际正文，按owned_span排序并精确映射16k kernel span；不转发预览/参考，也不伪造词级时间。重放wrapper在所有结果上结束或失败通道，ASR独立评分有效但observer已失败时保留原评分并明确live_text.failed。私有ASR root只在same-Governor/formal/shared PCM下接通，后验失败使通道失效。排队预算与开关进入replay policy；正式/source与C0/候选闭包纳入live模块，旧锁和结果需要重新冻结执行。

DIA runner独立text pump等待真实accepted样本覆盖正文末端，再注册CandidateEvidence。输入不足、通道失败或缺少明确EOF不返回完成；收到ASR EOF后仍执行活动finish、文字守恒和joined清理。NativeCandidateRun与shared activity适配接收同一channel，live/fixed/未观察三类来源互斥并明确报告；producer绝对观察时刻与DIA相对sink交付时刻分开，不能直接相减宣称P95。fake共同PCM→实际OpenAIRealtimeSession→活动归属集成仅使用sealed正文，无sidecar，文字守恒且匿名归属为句级。原生candidate factory与私有ASR owner的fake RPC路径均覆盖live参数及字节/依赖/源码/generation变动和关闭中取消。

十二个相关文件457 passed in17.71s；十二Python Ruff、六source strict/follow-imports=silent Mypy通过。通道新增15个回归覆盖预算/序列/span/非法clock、EOF/reader关闭、复用、启动失败、ahead-of-DIA等待与短输入；私有root增加shared-live六种执行/变动场景。所有新perf与tests图谱missing，直接复核当前源码，未重建索引。真实PCM、模型、benchmark、下载、服务/安装、UI、发布和合并未执行。

父ccb6419f原生CI39100437295成功；主CI39100437297失败，macOS并行测试5150 passed/1 failed/1 skipped，失败为既有worker lease最短驻留测试。通过延迟首轮poll至80ms稳定复现原固定sleep断言：监控的最短驻留起点是观察load时，原测试从设置alive推算，可能提前断言回收。独立提交c25720b将该测试改为虚拟时钟与逐轮scan确认，覆盖延迟观察、驻留期前保护及期满回收；worker lease21项通过，生产代码未改，不把旧CI报告为通过。

T6仍未完成：通用调度器lane失败仍取消全部任务，observer解耦只证明独立ASR评分正文可保留，不代表整条流水线的ASR优先降级。产品稳定发布与共同时间原点、footprint、ABBA和可信联合身份尚待实施。没有新的实际CER、人数上限或P95；#370仍未完成，目标继续。


## T6 live 诊断流水线的 ASR 正文保留与 unknown 降级

2026-10-18：新增run_live_meeting_pipeline，沿用共同PCM供给与既有Governor/四模式调度中的serial或显式overlap准入，另设有界DIA relay。实际分人失败后relay继续排空该支路，实际ASR仍接收全部来源；relay complete仅证明该宿主作用域结束，不作为模型成功。DIA启动失败、自取消、队列溢出、无效结果或finish超时使观察失效并取消/加入实际调用与native清理，ASR或来源错误仍使整体失败，不借降级伪装成功。

独立SealedBody由实际生产sealed接收端记录非空正文与真实owned kernel span，不依赖observer排队与关闭。明确完成前不可读取；非完整ASR不保留为成功结果。600秒/4096unit/10000字符、单unit30秒预算与严格不可变句级证据约束；只向显式外部sink交付原文，报告仅摘要/计数，作用域结束释放正文和排队引用。正式ASR/root新增显式sealed_body参数，root继续same-Governor/formal shared限定与前后源码/依赖/权重/generation核验。

DIA完整结束后对live EOF、独立正文摘要与非bool整数计数守恒判定；实际报告先冻结，摘要与判定共用同一不可变快照，阻断摘要后原mapping变更。失败时等全部回调清理后发asr_body_snapshot、replaces_all_attribution=true，以完整原ASR句级正文和unknown覆盖此前归属；asr_preserved_as_unknown=true而joint_verdict仍no-go。sink失败不报告保留成功，未知归属不折算为质量通过。

finish watchdog从DIA relay输入EOF启动，默认/上限15秒；不能等ASR最终复核完成才计时。超时取消DIA并加入清理，ASR正文仍可继续完成，回收/正文可能超过该时刻，因此不声称产品finish硬上限已通过。sink默认/上限5秒、独立owned task，自取消及吞掉超时取消仍失败。外部重复取消加入嵌套native回收和source/报告摘要线程。policy包含deadline/队列/降级语义、共同PCM策略摘要与执行前后源码摘要；回调来源、实际加载字节、产品发布及最终联合身份仍未证明。

新24项fake回归含独立正文非法/预算/复用、正常/启动失败/溢出/自取消/finish卡住、实际OpenAIRealtimeSession在DIA正常与失败时的共同PCM正文保留、ASR/来源/sink失败、外部重复取消、EOF deadline与ASR复核相互等待，以及bool计数和摘要后mapping变动反例。后四个取消/期限/判定反例均先RED后修正；私有root shared-live六场景同时覆盖独立正文参数。最终十三相关文件481 passed in18.83s、六Python Ruff与四source strict/follow-imports=silent Mypy通过；既有asyncio.iscoroutinefunction弃用warning未顺手改动。相关perf/tests图谱missing，直接核对worktree，无索引重建。父f81060a1主CI39101028466与原生CI39101028467均已核验success/completed。

此为诊断库链路的代码与fake证据，不是生产服务/App降级验收。仍缺产品稳定标签发布及共同计时、真实进程footprint、ABBA、可信联合身份和真实质量。joint quality not_observed、runtime/certification/joint latency/worker reaping不升级，无新的CER、认证人数或P95，#370未完成。无真实PCM解码、模型/benchmark、下载、服务/安装、UI、发布或合并，目标继续。


## T6 共同宿主计时与实际正文交付核对

2026-10-18：新增MeetingTiming并接入live pipeline的同一clock。ASR取包按序校验共同源原点与offer时刻，正式sealed接收端记录包括无文字区间在内的closed coverage；DIA水位与文字在外部sink调用前/成功返回后分别打点，ASR回调完成、DIA输入EOF及joined作用域结束独立记录。报告保留注入clock标记、源原点、时序metadata、摘要、缺失/无效及失败/未完成交付计数，无原文/PCM/embedding。sink返回不证明UI显示或产品稳定标签。

先RED复现DIA报告文字摘要/计数完整、实际sink漏句/改字/重复/错误span仍被判完整的问题。现逐条核对序列、owned span与文字摘要，并要求共同源/ASR sealed/DIA稳定覆盖全部输入、无失败和开放交付；不匹配时完整ASR正文保留为unknown快照且joint no-go。覆盖实际生产session加fake RPC的sealed水位，不从非空文字反推静音覆盖。

时序记录预算98304条：ASR独占65536、DIA水位/文字32767、最终unknown快照预留1，开放ticket上限64。DIA时序超预算取消并加入分人清理，不挤占ASR与最终快照；新增整体pipeline预算耗尽回归验证正文仍完整保留。策略冻结schema/各预算，正式重放与C0/候选源码闭包加入timing模块；旧spec/controls/report需重新冻结执行。

当前policy只有15/30与5/15秒阈值，采样单位、权重与quantile口径未登记，因此本轮只提供可重算宿主记录及诊断端点最大delay，不计算P95、不宣布稳定/finish期限通过。sampling_policy=not_registered、P95=null、latency_gate=not_evaluated。失败记录不丢弃，unknown替换后不把此前known交付量作为最终有效归属。

最终十三相关测试文件473 passed in15.92s，八Python Ruff、四source Mypy通过。改动的perf源码/tests图谱freshness均missing，直接复核当前worktree，无索引重建。父fe541a0d PR所有八项checks均已核验success/completed；本轮仍为合成PCM与fake模型/RPC，不解码真实语料、不加载模型、不运行真实benchmark、不下载、不改变服务/安装/UI/发布或合并状态。T6仍缺产品稳定发布与采样/硬期限、真实进程footprint、ABBA与最终联合身份；CER、认证人数与真实P95均未观察，#370未完成，目标继续。


## T6 双水位稳定标记与延迟采样登记

2026-10-18：live pipeline新增joined稳定发布任务。实际正文sink已完成、ASR sealed水位及已交付DIA稳定水位都覆盖owned span末端后，按句末堆取出一次stable_text标记；只引用原sequence/span、匿名speaker和句级粒度，不再交付原文。sink全局串行，任务失败/自取消或吞掉超时取消均停用DIA、保持完整ASR unknown降级；全部稳定任务结束/清理后才发送全量替换，防止晚到覆盖。重复外部取消加入稳定sink的owned清理。

稳定/文字/水位共用原有publication预算，ASR与最终快照预留不变。record schema升为2，policy冻结实际稳定发布语义。正式重放、C0/候选adapter/scorer和ASR comparison闭包纳入meeting_latency_policy，scorer policy摘要改变；旧spec/controls/report须重新冻结执行，不沿用旧认证。

采样选择为所有实际非空sealed ASR unit，按owned span样本时长加权，起点为句末源样本目标时刻，完成为双水位覆盖后的稳定标记sink返回。P95用离散逆经验CDF，在累计权重首次达到95%处取值，不插值；缺失/无效/unknown保留原权重为正无穷，JSON用null表达不可得分位，不丢失败分母，任一缺失或超过30秒unit均no-go。各会议单独计算并检查最慢会议，不跨会议池化。ASR漏字由独立质量门检查，不向运行时注入参考或伪造延迟unit；后续候选调度比较必须保持相同冻结ASR身份，ASR窗口变化可能改变句段分布，不能混作同一延迟对照。

finish为单会议最后源样本目标时刻到最终确认、ASR回调完成、DIA joined清理结束的最大值，含必要的最终unknown快照确认；缺完整证据保留finish_unresolved。每执行只有一个finish观测；预登记同一来源先取全部执行最大值，再按来源等权P95及最慢来源，缺失执行不从分母消失。本轮不计算该跨来源finish P95。单会议5秒target与15秒hard分别标注；顶层认证P95仍null、latency_gate未评估、runtime/certification保持false。宿主diagnostic_pass不证明麦克风采集、UI显示或产品稳定发布；稳定/finish硬期限执行及生产接线仍需完成。

新增先RED后GREEN覆盖双水位/正文确认前禁止稳定标记、策略缺采样或改权重/quantile拒绝，以及收尾竞态：调度已结束时不能只发首个就绪批次，须排空所有批次。另覆盖15/30边界、95%离散权重边界、unknown保留权重、scope清理计入finish、稳定sink失败/吞取消和重复外部取消。十九相关测试文件659 passed in19.75s；十一Python Ruff通过，五个源文件strict/follow-imports=silent Mypy通过。另直接strict检查meeting_quality_metrics.py报告未类型化函数、第三方stub及相对导入解析问题，该模块不在五源通过范围；本轮相关变更由fake功能回归与Ruff覆盖，未扩范围重写评分实现。

父073216d7的全部八项PR checks已核验success/completed。本轮不使用真实PCM/模型，不运行真实质量或性能benchmark，不下载、不改变运行/安装/UI/发布/合并状态。图谱perf/tests missing，直接复核worktree，无索引重建。可信CER、人数上限及真实P95未观察，#370未完成；footprint、ABBA与最终联合身份及来源catalog/main reference等仍待完成。


## T6 诊断稳定与 finish 硬期限控制

2026-10-18：SealedBody在实际ASR sealed unit追加时向独立deadline账本登记sequence、owned span及文字摘要，最多4096项，不等DIA输出文字才建期限，不存第二份原文。未完成句段按末样本排序，有效稳定标记确认匹配原ASR证据才出等待堆；同一source origin下固定句末目标时刻加30秒。ASR自身迟到超过期限时，登记后即可停用DIA，但不取消ASR。未知的未来sealed句段无法提前预知，ASR封存策略的联合预算可达性仍待独立核查。

finish期限改为源原点加全部样本时长再加预算（默认/上限15秒），覆盖DIA operation、ASR尾部等待和稳定publisher；不因模型完成、relay EOF或ASR复核迟到而提前撤销或顺延。监控与发布使用独立事件通知，共同clock计算剩余量、event-loop timer等待。注入clock冻结时仍有实际timer取消，报告保留timer触发与injected属性，不作为真实采集/时钟证明。timer醒后先重读实际完成证据，期限内的确认不因监控晚调度而变超时，实际迟到标记保留迟到事实。

首次超时以stable_label_timeout/diarization_finish_timeout报告deadline_at、observed_at和timer来源；取消DIA实际operation及稳定publisher、加入其清理，relay继续排空且ASR保留完整输入与正文，随后才发unknown全量替换，joint保持no-go。清理与ASR可能晚于触发时刻完成，不把取消请求伪装为硬墙钟完成或worker_reaping_verified。policy同步起点、动作与expected-unit预算，源码闭包改变后须重新冻结旧spec/controls/report。

三个关键反例先RED再GREEN：分人尚未给文字时仍须有期限；模型作用域已结束但稳定sink卡住不能逃过finish；合成60秒来源在早期标签超时后，DIA清理完成、ASR继续消费全部60秒并保留60句unknown。账本单测覆盖30秒边界及迟到确认、很晚再观察仍保留原完成时刻。正常case的测试finish预算不再复用10ms负例预算，避免依赖摘要线程在10ms内结束。

十九相关文件663 passed in19.84s，五Python Ruff与三source strict/follow-imports=silent Mypy通过，图谱相关perf/tests missing直接复核worktree，无索引重建。父84af3235全部八项PR checks success/completed。均为合成PCM/fake模型或RPC；未解码真实语料、加载模型、运行真实benchmark、下载、改变服务/安装/UI、发布或合并。

目标继续：仍需跨来源finish统计、生产接线与真实硬期限/精确回收验收、进程footprint、ABBA及最终联合身份；schema2来源catalog/独立ASR主参考和真实质量未就绪，CER、认证人数、真实P95不升级，#370未完成。


## T6 按独立来源聚合 finish

2026-10-18：新增离线FinishCohort，在候选输出前冻结schema2 development manifest/split/scorer摘要、共同来源前缀、候选身份、共同调度配置以及全部fixture×重复的执行清单。每执行绑定PCM/样本/完整pipeline策略；提取CommonPcmFeed.policy与live_pipeline_policy供预登记使用，不声称读取前验证PCM或runtime ready。共同配置移除来源特有信息但保留clock、分包、队列和迟到预算；先RED证明仅移除整个feed摘要会漏掉分包变更，再修正为GREEN。

observe复核实际宿主报告身份、共同来源原点、稳定确认及joined里程碑，重算finish；缺稳定标记或unknown不能只靠summary声称完整。aggregate逐来源取全部fixture/重复的最大值，再等来源权重取离散P95并检查最慢来源；任一缺失/失败保留原来源权重为正无穷，不能靠派生样本数或不足5%的缺失比例稀释失败。拒绝重复执行、报告复用、篡改及源码变化。摘要只证明声明控制与宿主metadata自洽，不证明独立执行、忠实解码、真实clock或生产字节。

合成接线测试在任何输出前冻结实际pipeline策略，再消费合成PCM获得真实流水线报告并投影observation；其余五个预登记执行未运行时保持no-go。二十相关测试文件682 passed in19.67s，四Python Ruff、三source Mypy通过。父cab45e8c全部八项PR checks success/completed。相关图谱coverage missing，以当前worktree直接复核；未重建索引。

仅使用合成PCM与fake模型/RPC，未解码真实语料、加载模型、运行真实benchmark、下载或改变服务/安装/UI/发布/合并。runtime_identity_verified/certification_eligible仍false，CER、认证人数及真实P95未观察，#370未完成。目标继续：生产接线与真实回收验收、footprint、ABBA及最终联合身份、schema2来源catalog和独立ASR主参考及真实质量仍待完成。


## T6 finish 观察的明细与摘要交叉核对

2026-10-18：继续审查发现，先前observe虽然重算finish端点，仍信任stable_gate/text_delivery_verified等摘要；缺文字、摘要或span不匹配、水位有缺口、稳定确认先于正文/水位，以及稳定时延已超门但摘要仍pass时可能输出completed。新增18个先RED后GREEN反例，另含unknown文字、重复文字、最终替换快照、ASR回调/分人EOF/close早于来源完成。

现从时序明细核对连续ASR sealed/DIA稳定水位、唯一已确认文字与稳定标记的sequence/span/hash/known及确认先后，重新按span样本权重计算稳定P95与30秒硬上限；结束里程碑须覆盖源末端和相应确认。逻辑不完整保留failed并进入原来源失败分母，结构非法仍拒绝，不以摘要补造证据。已冻结队列的源码身份变化后需重建登记。仍只证明宿主metadata自洽，不证明真实采集、独立主参考、生产加载字节或质量。

四相关文件120 passed in0.56s，二Python Ruff、一source Mypy通过；合成实际流水线接线仍通过。父6ca597f0本轮核验四项checks成功、两项仍运行，未声称全绿。相关图谱missing，直接复核当前源码，未重建索引。未做真实PCM解码/模型/benchmark/下载或服务、安装、UI、发布、合并动作；CER、认证人数、真实P95和#370状态不升级，完整目标继续。


## T6 ABBA 顺序与单路基线预登记

2026-10-18：新增AbbaLedger，输出前冻结声明的development来源池/attempt/ASR/DIA/scorer/workload身份、8–24个组的单fixture/PCM、共同feed与cold/warm条件，每条件每来源1–8块均衡安排；每块单独ASR-only、DIA-only后执行A-B-B-A。来源/fixture/PCM别名拒绝，重复不增加独立N。源码和latency policy也进入计划身份；ASR私有root的perf闭包变化后旧spec须重新冻结。

宿主账本逐位置核对实际PCM scheduler报告的mode、声明条件、时钟、源hash/样本、共同分包/队列、实际lane和交付量及回调时长一致性；缺基线/错序不前进，失败和missing位置保留，不能筛掉失败block。条件和模型身份仍仅声明，未证明cold/warm准备、生产加载字节或来源独立性；不读取任何真实音频/模型/参考或留出。预算显式区分64次joint与32次单路：8来源、两条件、5分钟片段最低8小时PCM供给，另加加载/预热/清理等。

初始21项缺模块RED→GREEN，fixture别名反例另先RED后GREEN；合成接线实际调用四模式PCM scheduler共48次，完整填入warm的8块，输出仍complete_metadata而非质量或并发通过。六相关测试文件177 passed in0.73s，二Python Ruff、一source Mypy通过。父6e554009本轮四项PR checks成功、两项仍运行，未声称全绿。图谱相关perf/tests freshness missing，直接复核，无索引重建。

E3仍未验：没有主量joint tail-to-final配对区间、ASR/DIA相对门、独立质量/footprint或最终联合身份，不用callback elapsed替代并发收益；selected_schedule/primary interval保持null。已异步请求Train near开发集真实解码/模型评测授权，未收到回复时不启动实跑。无下载、服务/安装/UI/发布/合并动作；CER、认证人数、真实P95与#370状态不升级，完整目标继续。


## T6 ABBA 联合 finish 配对诊断

2026-10-18：从FinishCohort抽出validate_finish_report，共用原有完整时序核对和稳定/finish计算，队列仍在前后核验源码。ABBA schema2可选预登记全部来源×serial/overlap的完整pipeline策略和各模式共同配置，另锁仅移除mode/overlap_enabled的跨模式共同配置。先RED证明两模式各自完整登记仍可同时改sink timeout，再增加comparison锁使其拒绝，不把多变量变化归因于调度。未启用joint登记时继续仅记metadata，不事后接纳秒数。

真实输出前裁决并登记统计口径：同源同模式全部重复取最大值，再等来源权重离散P95，主差值serial-minus-overlap；PCG64 seed1717、10000次，共同来源索引配对重采样P95差值，双侧2.5/97.5 linear percentile。RNG/方法/NumPy版本进入计划，源码及版本变更拒绝复用。冷/热分开，任一基线或ABBA位置失败/缺失均保留原来源失败权重，不计算区间，绝对finish门no-go。benefit_supported只表示该宿主区间下界>0，不签发运行策略、生产身份或质量通过。

新增测试先RED再GREEN覆盖共享校验器、joint登记缺失/改动/明细失败、共同配置差异；合成恒定0.5秒配对差的区间精确为[0.5,0.5]，重复不扩N、冷/热相反收益分开，24组1失败而有限P95也不能通过。预输出冻结后48次实际单路/联合live pipeline的合成接线进入区间分析，零收益不选择overlap。六相关文件188 passed in1.33s；进一步覆盖候选执行、ASR重放、评分、来源锁和选择器等二十一相关文件734 passed in20.02s，四Python Ruff、二source Mypy通过。父08172628核验七项PR checks成功、Gate Summary仍运行。图谱coverage missing直接复核worktree，未重建。

这仍是合成PCM/fake模型/RPC及宿主metadata一致性。没有真实解码、模型/benchmark、下载、服务/安装/UI、发布或合并；授权请求未收到回复。真实ASR/DIA相对P95、footprint、冷热准备、生产联合身份及独立主参考/质量仍未就绪；selected_schedule保持null，E3未验，CER、认证人数、真实P95与#370状态不升级，完整目标继续。


## T6 owned lane 相对尾部 P95 与完整执行顺序

2026-10-18：schedule报告升schema2，显式暴露共同宿主schedule_origin_at与各lane在joined摘要校验之后的validated_at_seconds，callback elapsed仍只统计进入到返回。ASR相对门用最后源样本目标到callback返回；DIA-only到callback及报告校验joined，joint到已核验actual dia_scope_closed，不拿整段elapsed、relay或外层报告处理时间替代。latency/scorer policy预登记人口、边界、同源模式最慢后等来源P95、缺失失败及零基线规则；旧spec/controls/计划需重新冻结执行。

ABBA校验schema/原点/时刻与source一致，拒绝返回早于源末端、验证早于返回及内部scope晚于对应外层完成。按条件单独输出relative_lane_tail，ASR overlap/serial≤1.05、DIA overlap/单独≤1.10；零基线只候选同为零可过，ratio null。任一位置失败/缺失保留原来源权重并no-go，有限P95不能绕过；重复不扩N。相对门不覆盖绝对门/主收益/质量/footprint/身份。

先RED后GREEN覆盖缺宿主原点/相对统计、policy缺采样、相对门成功/超界、零分母、owned scope与外层时序矛盾；实际合成live pipeline四模式接线验证两个相对门可计算但零收益仍不选择策略。收尾另先RED证实下一次输入可在上一执行EOF后、报告验证或稳定交付结束前开始；顺序边界现取上次offer、各lane验证和可验证joint最终确认的最大值，两个反例均拒绝。七相关文件248 passed in2.26s；最终二十一相关文件746 passed in20.74s，六Python Ruff、三source Mypy通过。

父4278a22e八项PR checks均success/completed。相关图谱freshness missing直接复核worktree，未重建索引。全部为合成PCM/fake模型/RPC，不是实际ASR/DIA性能或质量证据；未解码真实语料、运行模型/benchmark、下载或改变服务/安装/UI/发布/合并状态。真实开发评测授权仍待回复；E3、footprint、最终生产联合身份及独立参考/真实质量未验，selected_schedule为null、认证false，CER/人数/真实P95及#370状态不升级，完整目标继续。


## T6 显式 root 进程树物理 footprint 读取基础

2026-10-18：核查通用sample_resources以命令名发现及秒级ps lstart标识生命周期，未直接用于T6精确owner证据；保留其行为，新增窄入口meeting_process_snapshot。Apple官方libproc实现与本机SDK头文件确认RUSAGE_INFO_V0布局、physical bytes/启动absolute-time token和child枚举的数量口径；native reader同一次rusage读取生命周期与footprint，直接保留整数bytes，不做RSS倍数或MB浮点转换。

显式传入当次owned根，最多16根/64进程，遍历后代并去重嵌套根；后代优先的第二遍核验生命周期和子集合。缺失/复用/变化/循环/预算/非法clock或跨度超限均失败且不返回部分完整样本，普通异常脱敏。原始Mach token不宣称ns或跨boot身份；顺序区间读数总和不宣称原子、峰值、清理回收或认证。跨度预算只作结束后检查，不中断内核调用。

初始12项缺模块RED后GREEN；嵌套根按子级优先传入的反例另先RED，改为实际祖先深度顺序复核后GREEN。三个相关文件45 passed in0.08s，二Python Ruff、一source Mypy通过。xcrun clang仅fsyntax-only静态断言验证sizeof96及physical/start/exit偏移72/80/88，无构建制品。另对验证脚本自身做一次native只读smoke，生命周期一致、physical字段可读、跨度有效；未输出PID或真实内存数值。这是FFI验证，不是会议/模型进程资源基准。

父09eee274八项PR checks success/completed。图谱旧通用资源文件metadata_match，新collector/tests missing，直接复核源码，无重建。未执行真实语料解码、模型或会议benchmark、下载、服务/安装/UI/发布/合并。ABBA footprint仍not_observed，尚需owned根接线、独立观察域、阶段窗口与开销/失败记录和授权实跑；E3与真实质量/最终联合身份未验，#370及完整目标继续。


## T6 独立阶段资源观察与取消清理

2026-10-18：新增显式opt-in的meeting_process_observer。同步构造冻结exact roots、reader来源和预登记阶段；异步进入后用专用单线程executor读现有snapshot，首次尝试完成才交还负载控制。按注册顺序推进最多64阶段，分别保留宿主窗口、逐次读跨度与派发/读取/恢复总跨度、整数bytes及生命周期三元组；跨阶段样本保留但不供阶段覆盖，失败/缺阶段/预算耗尽不填零或删除分母。上限4096样本×64进程，结束或预算耗尽拒绝新阶段。退出复用join_cleanup，等待已开始的读取及executor shutdown，反复取消不能遗留线程；原生调用不能强制中断，不作硬墙钟关闭承诺。

初始14测试缺模块RED后GREEN；来源改变不能混入注册证据、预算耗尽不得接受阶段标记各另先RED再GREEN。四相关文件61 passed in0.17s，二Python Ruff、一source strict Mypy通过。覆盖阶段有效/遗漏、失败脱敏、跨阶段、预算、配置复制、非法策略、启动及运行中重复取消与线程join。所有进程树/读取均注入；本轮没有原生进程采样、真实音频解码、模型或benchmark运行。新文件图谱freshness missing，直接复核worktree，没有重建索引。父5772596f八项PR checks均success/completed。

complete_metadata只表示注册槽的采样元数据覆盖，不代表完整场景矩阵、峰值或认证；atomic/peak/reaping/runtime identity/certification均保持false。ABBA footprint仍not_observed，尚需精确owner与受控负载接线、扰动评估、完整场景矩阵及获准实跑。没有修改resident或服务/安装/UI/发布/合并状态；真实开发评测授权尚待回复。E3、真实CER/人数/P95与最终生产联合身份仍未验，#370未完成，完整目标继续。


## T6 已就绪私有 owner 与阶段资源观察绑定

2026-10-18：补充capture_owned_process_scope，以实际private owner getter取得的子进程对象、live PID和启动token登记，不接受历史PID名单作为所有权。专用线程读取并做两遍进程树核对，登记/取消/线程退出均joined，结束再核对原句柄。ASR FrozenAsrRuntime与NativeCandidateRun提供窄入口；ASR复用配置/generation/进程对象guard，分人核对原governor、owner generation、attached child、transport、artifacts及端口guard。实际模型与生命周期仍归原owner，默认不采样、不启动模型。

scope.observe将owner guard置于事件循环，每次读前后和关闭时检查原对象、PID、live状态与reader来源。变动/退出/缺失拒收或使metadata不完整；已成功样本不能掩盖后续guard失败。已就绪scope拒绝cold_start，不能冒充加载阶段；scope必须在runtime关闭前退出。资源helper进入ASR冻结源码闭包和C0/fast adapter身份，旧spec/controls须重新冻结，不复用旧收据。

先RED后GREEN：通用绑定及ASR入口9项，原生候选入口/两族source closure3项，另补cold_start拒绝与非法guard两项反例。九相关测试文件229 passed in4.69s，十Python Ruff、四source strict Mypy通过；另四相关文件验证ASR执行、候选checkpoint、live pipeline与ABBA接线，174 passed in12.63s。覆盖句柄替换/PID改变/退出/移除、登记中owner变化及重复取消线程join、原生token变化、实际fake ASR/分人owner与代际改变。父a5142473八项PR checks均success/completed。新/变更图谱freshness missing，直接复核worktree，无索引重建。

全部是合成文件、fake RPC和注入进程树，无本机原生进程采样、真实音频/模型/benchmark、下载或服务/安装/UI/发布/合并。就绪ASR两根不含宿主VAD/PCM/队列/分人，分人根不含ASR/宿主；加载前、回收后与完整finish/cancel矩阵仍未覆盖，不能分别取峰相加或升级T6总内存认证。完整harness生命周期根、测量扰动及授权实跑仍待接线；ABBA footprint保持not_observed，E3/真实CER/人数/P95与最终生产联合身份未验，#370及完整目标保持未完成。


## T6 宿主外层进程树与加载至清理观察

2026-10-18：新增observe_runner_process_tree，从当前宿主PID/启动token开始，初始须无后代；一个宿主同时仅一个观察范围，不借用/停止已有进程。范围在私有runtime加载前进入，在原owner joined清理后结束，覆盖宿主VAD/PCM/队列与动态后代。预登记单路/联合角色和cold_start至finish/cancel阶段；cold_start仅为加载窗口标签，不证明冷热缓存准备。登记actual owner scope的原始句柄/生命周期，不以历史PID替代。

底层增加checkpoint，唤醒同一有界采样循环并等待调用边界之后才派发的新读取；不复用已有或正在读取的旧样本，不建立并发采样器，检查点消耗原预算。取消等待者不丢弃owned读取；外层清理后强制新检查点，再join观察器。共同单次读取/登记线程清理提取为run_process_read，原有owner登记仍使用同一join规则。

结束核对全部角色登记与实际观察、句柄PID类型/值不变且returncode为整数，以及后置快照只剩同一宿主根。缺角色、未登记生命周期、残留后代、离开后代树但登记句柄仍未退出、PID改变/布尔值、内部失败或后置预算耗尽都保持incomplete_metadata；没有杀进程或将缺失填零。cold加载、稳态、finish前后合成树与实际fake ASR私有组合根均接线，重复取消后外层singleton可释放。

9项初始checkpoint/新模块测试RED后GREEN；候选两族及ABBA source closure3反例RED后GREEN；审查另以PID=True反例先RED再修正。最终十四相关测试文件416 passed in17.34s，十一Python Ruff、四source strict Mypy通过；staged whitespace及敏感字段核对。父afe86b42八项PR checks均success/completed。相关图谱freshness missing，直接复核worktree，没有重建索引。

宿主观察/采样代码进入ASR、C0/fast及ABBA源码身份，旧spec/controls须重新冻结。完整范围仅给可调用的metadata基础，returncode和树为空不证明真实wait/reap或瞬时峰值，reaping/peak/runtime identity/certification仍false。没有真实语料解码、原生进程读取、模型/benchmark、下载或服务/安装/UI/发布/合并操作；实际完整冷热/静音/重叠/finish-cancel矩阵、扰动与ABBA内存门仍待授权实跑和证据接线，footprint保持not_observed，E3、真实CER/人数/P95与最终生产联合身份未验，#370和完整目标保持未完成。

## Train near 开发解码授权与诊断 PCM 准备

2026-10-18 16:03 CST：用户明确授权“允许开发集真实解码和模型评测”，范围为既有 Train_Ali_near；Eval/AISHELL-4 留出不进入开发，不下载模型、不改变服务或安装态，遇现有服务/模型占用冲突停止实跑。此前记录中的未授权状态仅代表当时情况。

只读预检：8201 存在服务 listener；鉴权 `/metrics` 返回 200，batch/realtime active requests 均为 0，所观察服务进程树没有模型子进程。不过，与该端口共用的 `EvaluationPortLease(8201)` 实际返回 `evaluation_port_busy`。空闲请求数不能替代独占锁；本轮未启动模型、未更换端口绕过保护、未停止或修改现有服务。真实 A0/候选评测仍未运行。

在任何候选输出出现前，以 seed 1717 冻结来源顺序和 6/12/18/24 检查点。诊断选取规则为从原始时间零点开始，120 秒后首个至少 400 ms 的全说话人空隙结束，上限 180 秒；不存在共同有效时轴、切断话语或片段内缺少某轨说话时不纳入。2/3/4 轨池分别有 24/14/24 个合格来源，首批各 6 组，共 18 组、54 条轨道。3 轨池不足 18/24 检查点，不能靠重复窗口增加独立组数。这里的轨道数是来源分层条件，不是模型检测或认证人数。

实际流式读取冻结 Train near 归档，重新核对压缩包摘要、读取前后 stat 和选中 WAV 成员摘要；解码 mono/16 kHz/PCM16。各组以相同零点及结束样本取轨道等权均值，用 nearest-even 整数舍入生成 PCM16，不补齐、不同步漂移校正、不截断参考话语。18 个派生混音共 2404.08 秒（约 40.1 分钟）。原始 PCM、TextGrid、参考正文、来源登记及脚本均留仓库外受限目录。

已生成 schema 2 catalog、diagnostic manifest、空 development/holdout manifest 及 split lock；18 组全部标记 `derived_mix` / `diagnostic`。沿用原始 TextGrid 话语区间与会话内匿名标签，时间量化为最近整数样本；不声称词级时间或人工复核。独立 ASR 主参考仍 `not_observed`，没有从多说话人标注拼接一个任意主序列。源录音摘要绑定同组轨道摘要集合，独立性只声明 meeting-disjoint，未知跨会议人员身份不升级为 speaker-disjoint。

外部制品摘要：catalog `4cadb84577c2c32d91d55324c244b4793907753d43ae3c19956fac6aae5663a9`；预登记 `9499a33d87bc986f6d3f69a41245ef63321899c4b84949c8b5d79a05d6b65bcc`。独立复核重新读取全部 WAV、核对制品哈希和 PCM 格式/帧数、校验两类参考区间及匿名标签，并重建 manifests 逐对象比较，通过。准备脚本末尾 summary 的 NumPy int64 序列化失败；保留原部分文件，另用原生整数独立重建 `verification-summary.json`，不把原退出码当完成证据。

结果边界：schema 2 catalog 可验证，不代表正式开发输入就绪；自然 development fixtures 为 0，split lock 为 `insufficient_sources`。头戴麦派生混音只适合诊断，不能填补自然单人、自然近/远场或连续 1–4 人认证。现有正式执行器也明确拒绝 diagnostic 输入，因此下一步需要补足符合计划的自然来源与独立主参考，或先实施边界明确的诊断入口；不能通过改标签、空 sidecar 或放宽校验伪造正式评测。模型占用冲突解除前不启动实跑。本轮没有质量成绩、ABBA、生产认证或运行态变更；9d7cf2fc 的远端八项 CI 均已成功，该 CI 不是模型质量证据。

## ASR 派生诊断来源入口

2026-10-18：增加 `load_locked_asr_diagnostic_case`，从仅含 diagnostic fixtures 的 schema 2 catalog 重建来源/祖先/保留分区和完整 split lock，再核对所选 PCM 及活动、文字参考的匿名样本时轴。该入口不要求既有 ASR sidecar，避免对 ASR 自身诊断形成循环依赖；development 与 holdout 混入即拒绝，原正式加载和 schema 2 执行锁仍只接受 development。两入口共用主参考绑定、PCM 读取及 `LockedAsrCase` 生命周期保护，未修改正式分人 fixture 执行器。

主参考仍须显式冻结；缺独立主参考保留 null，不从分人文字重建主顺序。诊断 source proof 带明确 scope 和自然开发不合格标记。replay 包装层覆盖回调自报的相反结论：split_role=diagnostic、quality_evidence_valid=false、natural_development_eligible=false、certification_eligible=false、certified_max_speakers=null、asr_quality_improvement_gate=not_observed。因此诊断指标不能冒充正式开发改善、人数认证或留出资格。该库未增加自动模型加载、替代端口或服务控制入口。

RED：首批 7 个反例因入口缺失失败；新增非法 candidate 摘要和回调提升质量资格两例分别重现未拒绝/未覆盖，再实施校验。GREEN：7 个相关测试文件 347 passed in 14.95s；两文件 Ruff/格式通过；`MYPYPATH=src` 的定向 strict/follow-imports=silent Mypy 通过。未设 MYPYPATH 的初次检查遇到 installed package 缺 py.typed，不计通过；后续显式使用本工作树 src 完成。图谱对所涉新增路径 freshness=missing，按直接源码核验，没有重建索引。

使用上一节真实派生 PCM，仓库外另存 18 份 main_reference=null 的绑定文件，逐组经新加载器读取并核对身份、PCM、两类参考和退出后文件一致性：18 组、38465280 样本全部通过。输入校验使用明确标注的非模型 sentinel 摘要，没有据此声明 A0/candidate 身份；没有 replay、模型加载或质量评分。最终复核实现摘要为 c190943dfd740a079339e14e71249c74443d8ebc2e376e4bad4b5951272ec7d4。原始参考及路径仅留仓库外，报告不含正文。

本轮推进了派生材料的诊断输入边界；完整诊断执行控制、实际模型字节冻结、自然开发来源与独立主参考仍待补齐。此前实测的服务独占冲突没有被本次代码绕过，未再次尝试模型启动。没有新增 CER、分人质量或人数认证结论。

## ASR 本地制品准备与首片维护窗口

2026-10-18：只读解析 managed 配置、selection 与 model bindings；`.env` 原始 ASR 路径已不存在，不能把它作为有效模型位置。selection 解析结果为 quality / asr-1.7b-q8，实际 ASR 与 aligner-bf16 文件集均匹配仓库 catalog 的大小与 SHA-256；各 10 文件，分别 2467857511 和 1840061431 字节。宿主、worker Python 均 3.14.7。按显式 stdlib/site-packages 根登记 78012 条模型、解释器、依赖与源码记录，capture 后再次 verify 通过，清单摘要 d0662d636738cd722468f826b771510c93d548f85e925957c95c4c38e0540359。全部原始路径及逐文件清单仅留仓库外。文件闭包一致不等于实际导入或加载字节证明；ready structural revision 和 A0 spec 均尚未实测。

为首个已登记 diagnostic-001 准备独立执行脚本：事前验证输入、保持同一 8201 端口保护、准备私有 ASR/aligner owner、在第一次输出前冻结 ready spec、运行同一 formal realtime diagnostic replay、清理并核对文件后才生成成功结果。模型阶段 asyncio 超时 900 秒，取消仍等待有界 decode/owner 清理；脚本不控制 managed 服务，不切端口、不下载、不读取留出。4 项 fake 检查覆盖输入失败/端口占用前不创建 runtime、cleanup 失败不生成结果及成功退出顺序；这些不是模型证据。

用户另行批准一次临时停服、首片诊断及恢复。实际维护前，通过显式 `Accept: application/json` 的鉴权 health/readyz/metrics 核验：3.12.0、quality/quality、HTTP 200，batch/realtime active requests 为 0，四类 worker cold_evicted；lsof 无 ESTABLISHED 连接。session gauge 未输出，不将缺失值冒充实测零。com.speechrail 的原 PID 62386 与 listener 身份相符。managed `service stop --json` 完成后，原 PID 已退出、listener 消失、同端口保护锁可获取。

首片进程在模型加载前失败，未创建输出目录、未加载模型或执行 decode：完整 inventory.json 为 41312622 字节，超过执行控制读取器既有 16 MiB 上限。准备时仅验证脚本语法与 fake 流程，没有提前用真实清单贯通控制解析，属于本次预检遗漏。维护外层 finally 已经通过 managed `service start --json` 恢复服务，health/readyz 均 200、版本与 profile 不变；selection、私有 .env 字节和 runtime target 摘要均保持一致，恢复后的唯一 listener PID 为 96517。没有安装、selection/profile 或模型变更。

修正保留完整审计清单，仅另建 1843 字节 inventory-roots 执行控制，仍用原摘要重算实际文件闭包，不放宽 16 MiB 上限。v2 计划与脚本分别另存，不覆盖第一次失败证据。使用真实配置、源 PCM、参考及主参考缺失声明，离线重算闭包仍匹配；以 test guard 截止执行，确认真实控制解析和输入核验均能到达端口保护边界，没有碰真实端口锁或创建模型。第二个维护窗口已另行请求，未将第一次窗口授权自动扩展为重复停服。本节不构成 CER、分人质量或人数认证证据。

## 训练来源覆盖与发布方对象完整性核验

2026-10-18：在第二次维护窗口确认仍待回复期间，仅推进来源核验，没有再次停服、模型运行或语料下载。[AliMeeting 官方 SLR119](https://www.openslr.org/119/) 明确 train 为 104.75 小时、212 场、每场 2–4 人，并区分阵列 far 与参与者 headset near；[AISHELL-4 官方 SLR111](https://www.openslr.org/111/) 描述 4–8 人原始会议和独立训练包。这两者均不能单独补齐自然单人层。[VoxConverse 官方仓库](https://github.com/joonson/voxconverse)提供音频与分人 RTTM，未声明提供本项目所需的独立 ASR 文字主参考；不将其直接当作共同 ASR/分人评测集。

经官方页面所链接对象的 HTTPS HEAD 核验，Train_Ali_far.tar.gz 为 78639309701 字节（73.239 GiB），发布方对象 CRC64 为 7416259116226311466，支持 Range；未读取对象正文。far 是既有 Train near 同一来源会议的另一采集条件，不能当作新增独立 N。只有取得后按原始会议、通道、文件摘要和参考时轴核验、预登记共同顺序，才可形成自然阵列会议的 2/3/4 人开发候选；不以当前 HEAD 信息承诺实际有效组数或正式就绪。原始录音固定通道的 mono 转换须保留完整时间线和多人参考，不用 headset RMS 混音替代自然场景。

按官方时长与 8ch/16kHz/PCM16 假设估计，far 全部展开约 89.908 GiB，加压缩包约 163.146 GiB；这是存储规划估计，未检验 far WAV 头，非实际解包大小。对应文件系统本次可用空间实测约 439.74 GiB。建议将来获准取得 far 时保留压缩归档并流式选择预登记来源，避免同时保留全量展开副本。该方案仍需补至少 6 个自然单人开发来源及相应独立封存池，并提供明确主顺序/人工复核的独立 ASR 主参考；下载 far 本身不能证明连续 1–4 人范围或 10% CER 改善。

Train near 的 HEAD 返回内容长度与本机 24530908701 字节一致，发布方对象 CRC64 为 2522796480573142712。按[OSS 官方 SDK CRC64 参数](https://github.com/aliyun/aliyun-oss-python-sdk/blob/master/oss2/utils.py)核对多项式与反射/初末异或语义，使用本机 liblzma 增量 CRC64；先以独立逐位实现和空串、123456789、字节全集、零字节向量交叉核对，以及分块续算等价性，再完整读取本机压缩归档，同时重算 SHA-256。23.98 秒内完成，CRC64 精确匹配发布方；SHA-256 仍为 4c6512112f0f23bdfe535b8878c0ff140eb267b37c923b8794171edcc5d5d996。读取前后本机 stat 和两次 HEAD 长度/ETag/时间/CRC64 均未变。原始证据留仓库外 train-near-publisher-integrity-20261018。

新增证据证明本机归档匹配当前官方链接对象的长度和 CRC64，补足此前只有本地历史摘要的完整性证据。CRC64 不是密码学来源签名；multipart ETag 不作 MD5，仍未核实发布方密码学 hash。官方 212 场与本机按文件名聚合 209 组的差异仍未解释，不据此改写来源计数或补造缺失会议。本次不打开 Eval/AISHELL-4 留出、不解析新的音频正文、不运行 scorer；没有新增转录或分人质量成绩。

## 修正后首片诊断与故障定位

2026-10-18：用户明确批准第二个临时维护窗口。预检核实唯一 listener 为 PID 96517，版本 3.12.0、quality/quality，health/readyz 均 200；batch/realtime 活动请求为 0，四类 worker cold_evicted，无 ESTABLISHED 客户端，真实控制文件及冻结闭包均匹配。managed stop 成功后确认原 PID 退出、listener 消失且同端口锁可获取，再执行同一 diagnostic-001。

v2 进程退出码为 1，仅留下 ValueError 类型，没有生成 candidate-spec 或识别结果；现有证据不能确认加载到哪一步，不把失败类型推断为模型质量问题，也不声称实际模型加载成功。维护外层 finally 的 managed start 成功，health/readyz 200、版本和 profile 保持一致，selection/.env 字节及 runtime target 摘要未变；恢复后唯一 listener PID 98048。没有新增识别、分人、延迟或资源成绩。

服务恢复后仅做离线定位：完整闭包仍匹配；使用真实配置构建冷的生产 ASR/aligner owner 成功，未启动模型；在 prepare_revision_window 入口设置明确拦截后，真实准备路径能通过冻结与配置核对到达该边界，随后清理冷 owner。该结果缩小故障范围，但不证明真实 worker 启动或 ready 身份校验通过。

保留 v1/v2 失败制品，仓库外另存 v3 同输入诊断。仅记录最多 32 条 runtime 异常的函数、行号和异常类型，以及退出栈的文件名/函数/行号；不记录异常正文、局部变量、原始路径或 worker stderr。合成异常检查确认私有文本不进入记录，未实跑。该跟踪只为定位当前阻塞，不用于性能结论；再次停服另行申请授权，尚未执行。

## 首片真实解码与输入节奏对照

2026-10-18：用户批准第三个窗口，随后进一步明确授权本任务随时停止服务；后续必要停服无需逐次询问，仍采用 managed CLI、核对身份并在评测清理后恢复。第三次预检观察到 worker 生命周期 gauge 可从 active/warm_standby/cold_evicted 转换，而 active requests 均为 0；不再把 gauge 名称当作活动请求数。停服前仍核对 active requests 与 ESTABLISHED 客户端。

第三次首片记录定位到 prepare_frozen_asr_runtime 中 prepare_revision_window 抛出 GovernorBudgetError，继而被包装为 ValueError；未生成 ready candidate。根因是仓库外诊断配置复制 ASR 字段时漏掉资源声明，使 asr_resident_bytes 默认为 0，生产策略按 enabled component 未声明峰值拒绝计算。不是本机内存不足或识别质量失败。服务恢复、health/readyz 200，配置和 runtime 未变。

修正只作用于仓库外 settings-v4：复制有效 selection/config 中现有 asr_resident_bytes=2796424312 及 shared/active/workspace/safety/include-shared 字段，并将该诊断明确限制为串行。声明来自现有资源配置，不是本次测得的物理峰值；没有把值改作更大的虚假预算，也没有修改生产准入。冷生产 owner 的 governor reserve 离线通过后，重算并核对同一文件闭包，再执行同一首片。

v4 实际完成 ASR 与 aligner ready 握手并冻结候选身份，产生 5 次 preview decode；动态 token 上限均已观察，未触及上限。123.41 秒（1974560 样本）输入中，终态覆盖仅 107008 样本（6.688 秒），报告 replay_failed、ingress_not_fully_consumed 和 coverage_gap_or_duplicate；缺主参考仍不能计算 CER。进程退出 0 表示诊断报告成功生成，不表示识别通过。两个实际子进程已清理，退出后闭包复核通过；原服务恢复至唯一 listener PID 99727，health/readyz 200、3.12.0、quality/quality，selection/.env/runtime 保持一致。

v4 输入为 throughput，生产窗口另有 20 秒未解码积压保护；存在回放快于采集而触发保护的可能，不能直接把诊断中断归因于产品。下一项同片对照保持模型与生产策略不变，仅将仓库外诊断输入改为 realtime，并在异常捕获边界记录文件名/函数/行号和类型。移除逐行 Python tracing，不将这组诊断当作性能基准。该对照正在运行，尚无结果；未据此修改生产保护或声明质量改善。


v5 同片真实时间对照已完成：103 次实际 decode（71 preview、32 review），终态覆盖 1974560/1974560 样本，wire produced/consumed 均 2961840、dropped=0，队列 high-water=1，任务已加入、session 已关闭，无 replay 异常。报告仅剩 main_reference_not_observed；输出 587 字符，不能据此判断正确率。报告无 token-limit hit、无不完整 review；32 次 review 未暴露 generated_token_count，不据此声称完整生成 token 计数。累计解码输入 568.34 秒约为源长 4.61 倍，包含正常的预览与复核重叠，是后续资源优化的候选观察点，未证明冗余可安全删除。

两个子进程已清理，退出后闭包稳定；managed 服务恢复至唯一 listener PID 2135，health/readyz 200、版本/profile 和配置保持一致。该对照支持先排除输入节奏造成的失败，不能证明 throughput 失败的具体异常类型，也不证明 ASR CER、分人、峰值资源或延迟门通过。v4/v5 的输入节奏和 tracing 不同，不把墙钟差异作为性能收益。

将已实测的 realtime 输入节奏落实到私有 runtime 的正式单场回放路由，底层显式过载诊断入口保留，shared PCM 仍由共同输入源控制；生产采集、模型参数及积压保护不变。新增路由断言先在旧实现失败，再修改一行路由。此前外部文件闭包属于修改前源码，后续实跑须重新冻结，不沿用为当前代码身份。


验证：三个相关文件 test_meeting_asr_runtime、test_meeting_asr_execution、test_meeting_realtime_asr_replay 以 --no-cov 定向运行通过；Ruff check 通过，diff check 通过。初次六例均通过但默认全仓覆盖率门使该局部命令退出非零，不记为完整 gate 通过；未运行全仓测试。两文件 format check 提示既有格式差异，另以 HEAD 原文验证同样需格式化，本次不扩展为整文件格式整理。未据定向 fake 检查声明当前源码真实模型质量通过。


## 测试可移植性与首片分人实测

2026-10-18：用户要求测试不依赖本机速度与容量，GitHub CI 不自动运行真实语料。检查当前 CI 与 Python gate 调用链，现有 CI 运行 tests 下的确定性测试、fake native 测试及制品构建，不调用真实语料 benchmark CLI。移除旧 Sortformer 脚本两处开发者绝对目录，默认路径按当前 HOME 解析且保留显式参数覆盖；正式回放集成单测改用推进式注入时钟，composition 的硬件预算固定为合成值，不探测测试宿主物理内存。两项回归分别在旧路径/真实时钟实现失败；修改后四个相关测试文件通过，Ruff check 与 diff check 通过。另验证缺少显式外部输入时不构造真实模型 engine。没有增加 CI 真实模型或语料执行步骤。

使用既有 diagnostic-001 的同一 123.41 秒 PCM 和独立活动参考，先冻结 C0 adapter、显式 native 二进制、模型文件和既定参数身份，再实际运行 CoreML ActivitySession，append 与 updates 同时推进，防止积压在有界更新队列。四槽 C0 不启用 consolidation，阈值保持 0.25，未搜索阈值。125 次更新、1543 帧，processed/stable 均达到 1974560 样本；唯一 native 子进程退出，模型/二进制/源码与输入复核稳定。此为派生混音诊断，未认证自然会议、连续人数范围、八人能力或生产联合身份。

| 首片指标 | C0 原始活动 | 既有默认 slot consolidation |
|---|---:|---:|
| 全区间 speaker-time recall | 88.9843% | 89.6235% |
| 全区间 speaker-time precision | 98.8243% | 98.8326% |
| 逐人最低 recall | 88.4672% | 89.6084% |
| 无 collar / 含 overlap 的 DER | 12.0743% | 11.4351% |
| 质量门 | fail | fail |

C0 的参考 speaker-time 为 100.13 秒，正确 89.10 秒、漏检 11.03 秒、误检 1.06 秒、混淆 0 秒。两位逐人 recall 分别 89.2470% 和 88.4672%；本片无参考重叠。37 个参考活动段全部有相应假设重叠，匹配段开始偏晚的中位数 150 ms、结束偏早的中位数 110 ms，正开始偏差合计 5.89 秒、负结束偏差合计 4.10 秒。该分析指向活动边界漏检，不能扩展为其他来源均无身份问题。

既有 postpass 对照使用实际阈值活动区间的无损二值重建，scores=None，不虚构模型概率，不重新运行模型或改变默认配置；其仅回收 0.64 秒正确 speaker-time，仍不达标，不将微小变化作为发布理由。后续优先对更多预登记来源验证边界误差，并评估有语音证据支持的边界修正；不直接整体平移、放宽参考 collar 或以本片选择生产阈值。没有 ASR 主参考/实际归属文字，文字质量仍 not_observed。

运维外层 finally 已恢复唯一 com.speechrail listener PID 5086，health/readyz 200、3.12.0、quality/quality，配置、selection 和 runtime target 不变。预检中的 worker 缺失只针对本 worktree 的默认包内位置；随后以 managed Python 的隔离导入核验已安装包的 bundled worker 实际存在。此前将该 worktree 观察称为安装态缺失不成立，外部证据另存 scope correction，本次诊断使用明确登记的原 checkout 二进制，不改安装配置。宿主 OS/架构/芯片/物理内存另存仓库外 environment.json，仅用于说明观测条件；尚未实测峰值物理内存、P95 或跨机器性能。

## C0 预登记诊断池实测

2026-10-18：同一 C0 身份和既定阈值串行运行全部 18 个预登记派生诊断来源，2／3／4 人各 6 个，总长 2404.08 秒。包含首片复跑，独立来源数仍为 18，不重复计数。每片 processed/stable 均覆盖输入，子进程清理后才进入下一片；输入、模型、二进制及控制脚本摘要复核稳定。原始匿名活动概率和结果仅保留仓库外，用于后续同源对照，不进入 CI、fixture 或报告正文。

| 说话人数 | 来源数 | speaker-time 加权 recall | speaker-time 加权 precision | 最低逐人 recall | 通过来源数 |
|---|---:|---:|---:|---:|---:|
| 2 | 6 | 82.32495% | 97.77925% | 63.55852% | 0 |
| 3 | 6 | 84.20185% | 98.36790% | 75.73490% | 0 |
| 4 | 6 | 86.28760% | 90.88469% | 63.21001% | 0 |

2／3／4 人组漏检分别为 125.27／127.98／138.12 speaker-seconds，误检分别为 11.66／9.23／78.58，混淆分别为 1.78／2.29／23.29。首片以边界漏检为主的现象不能代表整个池；4 人组同时存在明显误检和混淆，因此不据首片统一扩张边界或搜索 C0 阈值。下一项模型对照遵循已登记的 C1 fast32／C2 fast128 方案。18 片均未通过绝对质量门；派生诊断没有自然会议认证资格，缺单人层和独立 ASR 主参考，不能声明连续 1–4 人认证或 CER 改善。

维护结束后 managed 服务恢复，唯一 listener PID 6828，health/readyz 200、3.12.0、quality/quality，配置、selection 和 runtime target 保持不变。本轮未测峰值物理内存、P95 或跨机器性能，不将本机完成耗时转成其他机器的测试超时或吞吐门槛。

## 既有后处理全池对照与候选制品核验

2026-10-18：对上述 18 片已保存的实际四槽概率帧，逐片重建 ActivityFrame；先以原活动转换和同一 scorer 重算 C0，确认 product_all_regions 与实跑报告完全一致，再应用既有默认 consolidation。不改变参数、不搜索阈值、不新跑模型、不改生产默认。

| 说话人数 | 后处理加权 recall | 后处理加权 precision | recall 变化（百分点） | 最低逐人 recall：原始 → 后处理 |
|---|---:|---:|---:|---:|
| 2 | 82.80491% | 97.94793% | +0.47996 | 63.55852% → 63.27307% |
| 3 | 84.46137% | 98.38117% | +0.25952 | 75.73490% → 75.94869% |
| 4 | 86.61552% | 91.42642% | +0.32792 | 63.21001% → 62.25710% |

5 个来源整体 recall 下降，18 个来源仍全部未通过质量门。小幅平均收益伴随弱说话人覆盖退化，因此不采用该后处理作为生产改进。完整逐片匿名对照留在仓库外 existing-postpass-pool-comparison.json，适用范围仍为派生诊断。

只读检查 managed 模型目录、FluidAudio 标准缓存、Hugging Face/ModelScope 缓存及本机既有模型根目录，未发现 Nemotron 候选。候选可执行文件已存在，缺模型不能做实际推理。ModelScope 同名仓库 API 返回 404；转换方 [Hugging Face 固定快照](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/tree/25a90f97f254428d4b30374b76af9c74fdee8327/monolithic/v2)列出的 fast32／fast128 FP16 bundle 与共享 learnable_sil_emb.bin 共 9 文件、398165279 字节。已在仓库外保存文件大小、LFS SHA-256 或 Git blob ID 的下载提案，尚未下载；须在用户另行授权后取得、逐文件校验，再执行同源候选对照。该提案不改变安装、selection 或 profile。

## 分人重复修订生产修复

2026-10-18：生产 AttributionLedger.apply 在比较归属是否改变前将 revision 加一，而 dataclass 相等性包含 revision。因此每个未定稿 unit 在收到下一 activity update 时都会被判为变化，即使 speaker、active_speakers、state 和 reason 全部相同。DiarizationSession 会为这些结果生成 ItemAttributionUpdated，Realtime auxiliary 随后重新投影对应 item 并发送 metadata revision，增加无意义的事件与客户端处理。

修复保持当前 revision 计算归属，只有实际内容或定稿状态改变时才递增并返回。保持真正的匿名 label 修正、unknown 原因和 provisional → final 转换；不更改模型、阈值、活动参考、PCM 或公共字段。两例 unchanged 回归在旧实现失败，真实 speaker 变化保护例通过；修复后三个直接相关测试文件 28 项通过，四个边界/集成文件 41 项通过，定向 Ruff 和 diff check 通过。仅执行相关确定性测试，没有自动加入真实语料 CI。

另以此前 18 片实际 C0 活动帧构建仓库外确定性账本对照：使用参考活动区间作为无文字代理 units，所有 units 在 feed 前注册，按合成的一秒稳定窗口喂入。该工作负载不是实际 ASR unit 到达节奏，也不是实时性能或质量认证。前后发出的 unit 修订数为 69019 → 2290；去除仅 revision 不同的重复后，有意义修订的时间序列与全部最终 label 完全相同。证据证明该输入和调度下消除了重复修订，不能据此声称真实会话流量同比下降、CER/分人准确率提高或 P95 改善。baseline 源码、输入和逐来源计数留在仓库外 attribution-revision-diagnostic-20261018；未停服、未加载新模型完成此对照。

## Nemotron 首片实测与结束边界修复

2026-10-18：用户明确授权下载两个候选并继续同源诊断，随后给予一小时任务内自主执行授权。固定模型 revision 的 9 文件已下载到仓库外，每个文件均核对大小及发布方 LFS SHA-256 或 Git blob ID；全部匹配。没有下载其他模型或修改安装、selection、profile。候选制品预检与实际推理分开记录。

首次 fast32 在 finish 阶段失败，第二次仅补安全异常树和子进程状态，确认 runtime preflight/形状检查通过、native 子进程退出码 1 且已回收；fast128 未启动。锁定 SDK 的中心化 STFT 在 EOF 可多输出一个 10 ms 帧，原 CandidateFrames 强制输出等于输入向上取整后的长度，发生边界冲突。两例 EOF padding 测试在旧实现以 coverage 失败；修复先验证所有概率，再丢弃最多一个完全位于向上取整范围外的 padding 帧。输入范围内的输出、缺帧检查、较大越界拒绝与 NaN 拒绝均保留；不修改 SDK checkout、阈值或模型。

一次复跑在 Release 构建尚未完成时错误地冻结并使用了旧二进制，仍在 finish 失败；该结果不算修复后的证据。等待构建成功并通过 --show-bin-path 核对实际产物后，确认 SHA-256 改变再冻结 v4，避免将源码修改冒充实际二进制修改。原有失败制品全部保留。Swift Testing 的 5 项测试（含参数化用例）通过，Release 构建成功，新二进制摘要为 124ceb24924366acb6812a595e6bd215f51bc8358b82f22f6cb6440705fd8ebd。

v4 两候选均完成首片，processed/stable 为 1974560，125 次更新，runtime SDK/preset/compute-unit 与形状检查通过，实际子进程回收、输入与模型/源码/二进制复核稳定。fast32 的 recall/precision/最低逐人 recall 为 86.63737%／99.96543%／85.79899%；fast128 为 87.03685%／100%／85.82864%，质量门均 fail。它们在该片比 C0 召回率低、精确率高，不能据首片认定整体改善或替换生产。没有 ASR 主参考、实际联合转写或峰值/P95 成绩；仍为派生诊断。

四个窗口结束均恢复原服务，最终唯一 listener PID 10809，health/readyz 200、3.12.0、quality/quality，配置、selection 和 runtime target 不变。

## Nemotron 全诊断池对照

2026-10-18：冻结上述修复后的 worker/model/adapter/preset 后，在同一组 18 个预登记来源上逐来源串行执行 fast32、fast128，共 36 次运行。各候选仍是 18 个独立来源，首片重复不增加 N；没有按输出挑选容易片段或调整阈值。全部输入覆盖、运行时身份、子进程清理与退出后字节检查通过，73 个外部执行控制/脚本的摘要前后相同。服务已恢复至唯一 listener PID 11402，health/readyz 200、版本/profile 和配置保持一致。

| 人数 | 候选 | 加权 recall | 加权 precision | 最低逐人 recall | 通过来源 |
|---|---|---:|---:|---:|---:|
| 2 | C0 | 82.32495% | 97.77925% | 63.55852% | 0/6 |
| 2 | fast32 | 80.76961% | 99.02439% | 63.41579% | 0/6 |
| 2 | fast128 | 80.86699% | 98.91266% | 63.41579% | 0/6 |
| 3 | C0 | 84.20185% | 98.36790% | 75.73490% | 0/6 |
| 3 | fast32 | 82.71383% | 99.70908% | 73.86010% | 0/6 |
| 3 | fast128 | 82.76841% | 99.68015% | 72.66839% | 0/6 |
| 4 | C0 | 86.28760% | 90.88469% | 63.21001% | 0/6 |
| 4 | fast32 | 83.91229% | 97.87744% | 56.05381% | 0/6 |
| 4 | fast128 | 84.06521% | 97.76614% | 56.14723% | 0/6 |

新模型明显减少 4 人组误检/混淆对应的精确率损失，但 recall 和弱说话人覆盖退化，不能作为已验证的整体产品改善，暂不替换生产模型。4 人组宏平均 DER 从 C0 的 19.78543% 降至 fast32 的 16.21688%、fast128 的 16.14738%；2／3 人组 DER 反而上升。DER 改善不能替代逐人门，全部候选保持未认证。

显式使用 libproc 按 native PID+start-time 采样 phys_footprint，包含其后代进程，间隔 20 ms。fast32/fast128 的观测最大值分别为 215843920／218547280 字节；共 4 次读数失败，不声明完整覆盖、真实峰值、整机内存或资源门通过。C0 本轮未用同一 sampler 复跑，不能据此声称内存相对收益。全部原始采样保留仓库外。

另作 10 ms 网格的粗粒度能量诊断：参考活动存在而模型未输出任何活动的帧，RMS 中位数约 −65 至 −73 dBFS，明显低于有活动输出部分。该统计不区分低声发言、参考标注余量与派生混音影响，不据此删除参考区间或直接加入增益处理。连续自然场景认证、独立 ASR 主参考和联合延迟仍未完成。

## ASR 实时与长块同源诊断

2026-10-18：重新冻结当前源码与原模型身份，在 diagnostic-001 的同一 123.41 秒 PCM 上，先运行按实际节奏输入的 RealtimeSession，再运行固定 15 秒块；没有把参考文字、参考边界或分人结果送入模型。两路完整覆盖输入，无 token-limit 命中，最终关闭所有 owned children 后核验已回收。长块分支在整轮关闭前的中间 proof 不是最终清理证明，以外层完成后 proof 为准。

从原 TextGrid 的 37 个区间核验不存在时间重叠后，按时间拼接出诊断参考。该派生顺序不能消除原正式主参考身份缺口，未将其提升为独立 ASR 主参考；原始文字与实际模型正文仅在仓库外保存。

| 路径 | 实际 decode 次数 | 重复解码累计音频秒数 | 派生诊断字符错误 / 参考字符 | 派生诊断 CER |
|---|---:|---:|---:|---:|
| 当前实时路径 | 103（71 preview、32 review） | 570.74 | 30 / 515 | 5.82524% |
| 固定 15 秒块 | 9（全部 review） | 123.41 | 32 / 515 | 6.21359% |

长块减少重复解码输入，但本片未获得质量收益，因此不改变生产切块与实时策略。累计解码音频长度不是实际模型运行时长，不能换算成时延、RTF、功耗或跨机器性能；两路均不构成正式 CER 改善或人工关键事实验收。原服务最终恢复至唯一 listener PID 12833，health/readyz 200，配置、selection 和 runtime target 不变。

## 自然远场片段探索

2026-10-18：从 [AliMeeting 官方来源](https://www.openslr.org/119/)的 Train_Ali_far 归档按 Range 获取前 32 MiB，保持 ETag 一致并核对 Content-Range；没有取得完整约 73 GiB 归档，不能声称完整归档校验通过。按归档顺序选择首条训练录音前 180 秒，模型运行前固定八通道中的 channel 0，不作增益、补齐或混音。未读取 Eval 或 AISHELL-4 留出。

原始 far 标注尚未取得。匹配既有 Train_near 同会话四份标注，在前三个连续 60 秒窗口对比包络，far-minus-near lag 均为 −40 ms，相关系数分别为 0.6923、0.8462、0.8630。该局部诊断不能证明整条录音时钟一致；仅将 near 活动参考按此固定偏移用于探索，不冒充已验证 far 参考或 schema 2 正式评测来源。

| 模型 | 代理参考 recall | 代理参考 precision | 最低逐人 recall |
|---|---:|---:|---:|
| C0 | 88.01036% | 96.44260% | 79.46203% |
| fast32 | 85.86437% | 99.09780% | 76.73340% |
| fast128 | 86.08345% | 98.01576% | 77.34457% |

该自然音频探索仍呈现精确率提升与召回率损失的取舍，不支持替换生产模型，也不计入 18 来源的 N 或任何自然场景认证。首次三模型运行后恢复服务至 PID 13924；随后为保存实际 ActivityUpdate 轨迹，按同一冻结输入与参数再次串行运行三模型。第二次不增加独立来源数，全部清理并恢复唯一 listener PID 14570，health/readyz 200、3.12.0、quality/quality，配置、selection 和 runtime target 不变。

## 归属账本无效重算优化

2026-10-18：在重复修订修复之后，生产账本仍对每次更新遍历重算所有未定稿 units，并在空心跳时复制、排序活动历史。修复在完成 epoch、step、重复载荷和 watermark 校验后，跳过未改变活动或稳定水位的空心跳；仅对 replacement 与文字区间相交、或稳定水位已经覆盖其末端的 units 重算。水位更新、真正归属变化和空更新触发的定稿保持有效，不改匿名 label、模型与阈值。

两个参数化回归在原实现失败，修复后通过；反转相交判断的 mutation 被测试检出，源码随后精确恢复。七个直接/边界/集成测试文件共 71 项通过，定向 Ruff 与 diff check 通过。测试以重算次数和活动历史复用验证工作量，不设置依赖本机快慢的时间断言，不引入真实语料 CI。

使用上述第二次运行捕获的真实 ActivityUpdate 序列，逐事件对比保存的原账本和修复后账本。47 个 near 标注区间只作为无正文代理 units，全部在 feed 前注册，不代表实际 ASR unit 到达节奏；两侧初始快照、每步事件（含 revision）和全部最终快照完全相同。

| 真实活动轨迹 | 更新数 | 其中空更新 | 原重算次数 | 修复后重算次数 |
|---|---:|---:|---:|---:|
| C0 | 181 | 1 | 5514 | 245 |
| fast32 | 181 | 110 | 5547 | 123 |
| fast128 | 181 | 163 | 5689 | 64 |

该结果证明所列轨迹和代理工作负载下减少无效计算，不声称真实 ASR 联合延迟、整机内存、准确率或用户会话流量改善。baseline、轨迹摘要和逐项对照保存仓库外；比较本身没有再次加载模型。安装态仍使用原 release，本 PR 的生产修复尚未部署。

随后补充仓库外合成差分核验：两种匿名 label 模式、各 32 个固定随机 seed，共 6400 次有效更新，包含晚注册、区间替换、空心跳、原因变化、compaction 和最终定稿。原账本与修复账本的逐步事件、label 映射、保留计数及最终快照全部相同；该核验不加载模型、不作为质量或时延认证。

## 活动参考口径复核

2026-10-18：检索原始资料发现，[ASRU 2025 研究](https://arxiv.org/html/2507.09226v2)明确区分 AliMeeting 句级 ASR 标注与紧致分人活动标注：句内停顿会使活动漏检被高估。作者公开的[强制对齐标签](https://github.com/nttcslab-sp/diar-forced-alignment)也注明存在对齐与转写歧义，不能视为无误差人工真值。

固定该标签仓库 revision 9527b7c64846fb38316a610f32e9d3466bd6d8b7，仅获取 Train_Ali_far 中与原 18 来源一一匹配的 18 份 RTTM，逐份校验 Git blob ID 和记录 SHA-256；不获取 Eval/Test 文件。先固定全部 18 来源与原裁切范围，再对已保存的三个模型输出离线计分，没有新模型运行、阈值搜索、输出筛选或删除失败来源。原参考与原分数完全保留。

辅助参考的 speaker-time 为 2287.13 秒，原句级参考为 2720.51 秒，相差 433.38 秒（15.93%）。下表仅说明参考语义敏感性；远场标签与近场派生混音的逐来源时钟、track 对应与人工语义尚未验证，固定使用原时间、不按模型输出优化偏移。辅助参考不升级为正式主参考，表中“通过来源”只指这份辅助参考下原 scorer 的结果，不是认证。

| 人数 | 模型 | 辅助参考加权 recall | 辅助参考加权 precision | 最低逐人 recall | 辅助门通过来源 |
|---|---|---:|---:|---:|---:|
| 2 | C0 | 97.73955% | 93.59385% | 95.81378% | 1/6 |
| 2 | fast32 | 98.91981% | 97.77759% | 97.10772% | 6/6 |
| 2 | fast128 | 99.04060% | 97.66876% | 97.13049% | 6/6 |
| 3 | C0 | 96.82656% | 93.97597% | 90.24226% | 0/6 |
| 3 | fast32 | 98.11257% | 98.25887% | 91.01615% | 4/6 |
| 3 | fast128 | 98.17388% | 98.22693% | 90.94886% | 5/6 |
| 4 | C0 | 94.67698% | 86.62634% | 80.17174% | 0/6 |
| 4 | fast32 | 94.78749% | 96.04423% | 75.69607% | 0/6 |
| 4 | fast128 | 95.02024% | 95.99565% | 75.80016% | 1/6 |

同一辅助标签用于自然远场 180 秒探索，C0 recall/precision/最低逐人 recall 为 96.96935%／93.39808%／90.36732%，fast32 为 95.41721%／96.79347%／92.61619%，fast128 为 95.50218%／95.57798%／92.12894%；三者仍未通过逐人门。该片也未完成人工 far 时钟核验，不能据它给出人数认证。

由此调整后续损失定位顺序：先核实活动参考定义和自然输入时钟，再区分真实弱说话人漏检与标注内静音；保留原参考和辅助参考两路证据，不通过整体扩张活动、放宽 collar 或填满停顿迎合句级标注。Nemotron 在辅助口径下具有继续验证价值，但 3／4 人层的弱说话人问题仍存在，保持不替换生产。该结论不修改既定质量门、留出策略或完整项目目标。

对原六个四人来源进一步作固定 10 ms 网格诊断：按整片最优一对一映射识别每片最弱参考说话人，分开统计其漏失处于参考单人/重叠区间的时间。fast32 的最弱说话人漏失合计 24.94 秒，其中 22.57 秒（90.50%）在参考重叠区间；fast128 为 24.96 秒中 23.00 秒（92.15%），C0 为 21.49 秒中 18.24 秒（84.88%）。各模型六片均实际使用四个输出槽，未出现第五槽。各模型的“最弱者”不一定是同一个人，不将这些合计作同一人的配对收益。单人漏失部分的能量仅来自混音，不能视为隔离人声强度。该辅助诊断支持优先核查重叠发言的弱声覆盖，不能证明因果、排除时钟/标注问题或推出八人上限已经可用。

## 固定活动灵敏度诊断

2026-10-18：在计算变体分数前登记唯一阈值变体 fast32 strict >0.4，对照原 strict >0.5；没有网格搜索。完整保留原 18 个派生来源及 1 个自然远场探索片段，两套参考分别计分，共 76 条 case/reference/threshold 结果。使用已保存的实际八槽概率帧，不重跑模型；先逐帧核对 >0.5 与原 active_slots 相同，再确认合并后的基线活动与原 native 假设完全一致。输入、参考、策略及 scorer 源码摘要在评分前冻结，结束后全部复核稳定。该变体不是原生 SDK 已执行的新候选，不宣称实际 loader、延迟、资源或人数认证。

| 人数 | 辅助参考 recall：0.5 → 0.4 | 辅助参考 precision：0.5 → 0.4 | 最低逐人 recall：0.5 → 0.4 | 辅助门通过来源：0.5 → 0.4 |
|---|---:|---:|---:|---:|
| 2 | 98.91981% → 99.24939% | 97.77759% → 97.28367% | 97.10772% → 97.97919% | 6/6 → 6/6 |
| 3 | 98.11257% → 98.62494% | 98.25887% → 97.82385% | 91.01615% → 92.53028% | 4/6 → 5/6 |
| 4 | 94.78749% → 95.88280% | 96.04423% → 94.89537% | 75.69607% → 79.80744% | 0/6 → 2/6 |

18 片的最低逐人 recall 均有所提高，precision 也全部下降；四人组加权 precision 跌破既定 95% 门，最弱说话人仍明显不达标。原句级参考下，四人组 recall 从 83.91229% 到 85.28770%，precision 从 97.87744% 到 97.16893%，仍无来源通过原门。自然远场辅助参考 recall/precision/最低逐人 recall 从 95.41721%／96.79347%／92.61619% 到 96.22161%／95.69038%／93.94337%，逐人门仍 fail。由此不采用全局降阈值，不改生产或既定候选身份；不继续通过阈值网格迎合开发集。

只读检查锁定 SDK 的 Nemotron3StreamingFrontend 与 AudioMelSpectrogram：前端使用预加重和带固定 floor 的 log-mel，前端声明不做 normalization。该观察不能证明整个模型图没有后续归一化，也不能证明加增益会改善质量；后续如检查输入电平，须使用预登记、可因果执行的变换及原始输入对照，保留噪声、削波和高电平语音代价。该检查阶段未对音频加增益；随后按下述预登记方案进行真实输入对照，未修改第三方源码。


## 固定输入增益配对诊断

2026-10-18：先在已观察到弱说话人损失的 diagnostic-006（148 秒四人派生片段）登记唯一 2 倍线性增益，与原输入分别启动全新 native 进程。驱动先验证原始 PCM，再以 int32 乘法和 int16 饱和转换生成实际输入；冻结并核对变换后的字节摘要、样本数与削波计数，保持时间轴和模型阈值不变。该定向选片不是无偏扩样；两种模型的新增基线均与各自历史假设完全相同。没有把参考或说话人身份送入模型。

fast32 在辅助参考下 recall/precision/最低逐人 recall 从 92.16371%／93.21155%／75.69607% 提高到 94.16644%／94.90705%／83.65860%，但两路均未过门。生产 C0 同片最低逐人 recall 反而从 80.17174% 降至 79.41712%（辅助参考），原参考从 63.21001% 降至 61.43498%。由此拒绝将增益直接应用于生产模型。

随后在评分前登记完整原 18 来源、固定 fast32 strict >0.5、同一 2 倍增益，不剔除失败来源。18 次新增 native 运行全部完成并回收子进程，削波样本均为 0；变换实际输入、参考、控制脚本和 36 份缓存基线文件前后摘要稳定。此前单片的新基线证明该片与缓存输出一致；本次全池仍以缓存原输入为对照，不宣称 18 片全部重新做了 fresh/fresh 配对。缓存与新运行的完整源码身份因归属账本优化而不同，声学 adapter、native binary、SDK、模型文件和阈值保持相同；保留该限制，不把旧、新完整候选身份视为同一身份。

| 人数 | 辅助 recall：原输入 → 2 倍 | 辅助 precision：原输入 → 2 倍 | 最低逐人 recall：原输入 → 2 倍 | 辅助门通过来源 |
|---|---:|---:|---:|---:|
| 2 | 98.91981% → 99.02680% | 97.77759% → 97.54062% | 97.10772% → 97.85926% | 6/6 → 6/6 |
| 3 | 98.11257% → 98.28044% | 98.25887% → 98.14148% | 91.01615% → 91.95828% | 4/6 → 5/6 |
| 4 | 94.78749% → 95.35764% | 96.04423% → 96.19680% | 75.69607% → 81.16350% | 0/6 → 1/6 |

四人组汇总有正向信号，但辅助参考下 18 片中 15 片 precision 下降、4 片最低逐人 recall 下降；原参考也有 4 片最低逐人 recall 下降，全部仍未通过原门。固定增益未达到逐来源退化约束，也未验证自然输入、高电平和噪声代价，因此不采用全局增益、不调整生产默认。该实验不新增独立来源，不构成人数认证或时延/内存收益证明。

上述真实运行均通过 managed CLI 临时停服，完成清理后恢复；最后一个全池窗口恢复唯一 listener PID 22354，health/readyz 200、3.12.0、quality/quality，配置、selection 和 runtime target 未变。原始音频、概率帧、正文和执行制品继续保存在仓库外。


## 现有 BF16 ASR 同路径对照

2026-10-18：只读发现本机已有未量化 ASR 权重（4076186653 字节），索引完整指向单文件，707 个张量均为 BF16；未下载、转换或修改模型。与 Q8 的 tokenizer、音频预处理配置、vocab 和 merges 字节相同，主配置差异仅为量化字段。只读核验 oMLX 未加载该 ASR 模型且无加载中模型，停服前及各 arm 前重新检查；未对 oMLX 作卸载、重启或配置修改。

在新目录重新冻结当前代码、模型和依赖，Q8 与 BF16 分别启动私有 ASR owner，以相同 diagnostic-001 的 123.41 秒 PCM、同一 RealtimeSession 解码策略和同一派生参考串行实跑。正式后端根据 safetensors 精度解析请求，不因通用 Settings 的默认 dtype 将 BF16 转成 FP16；两路 ready 身份分别确认为 int8、bfloat16。BF16 私有运行的 resident 声明取 8 GiB 保守预算，它是准入声明，未冒充实测内存，也未写入生产配置。

| 权重 | 实际 decode 次数 | 完整覆盖样本数 | 派生诊断字符错误 / 参考字符 | 派生诊断 CER |
|---|---:|---:|---:|---:|
| Q8 | 104 | 1974560 | 30 / 515 | 5.82524% |
| BF16 | 94 | 1974560 | 31 / 515 | 6.01942% |

两个 arm 的声学 adapter、worker 源码、preset、decoder、归属策略、scorer 及 PCM/参考/解码策略摘要相同；权重、精度、模型 revision 和完整运行闭包身份分别冻结，不混作同一候选。实时调度受完成时序影响，decode 次数不同不等于单次模型更快，未以次数推导吞吐、延迟或资源收益。无 token-limit 命中，模型收到的输入不包含参考，关闭后 owned children 已回收，冻结文件前后稳定。

本片 BF16 多错 1 字，未观察到质量收益，因此不采用或扩展该路线。诊断参考仍非独立主参考，不能宣称正式 CER 或量化精度的一般优劣；运行 proof 中 loaded_model_bytes_verified、actual_imports_verified 和 source_import_bytes_verified 仍为 false，文件冻结与 ready 身份不补足这些完整认证缺口。两路结果仅以缺少主参考这一预期原因 fail，保留失败状态，不包装为质量门通过。

该窗口最终通过 managed CLI 恢复唯一 listener PID 24805，health/readyz 200、3.12.0、quality/quality，配置、selection 与 runtime target 保持原值。真实输出、完整权重摘要、执行身份和参考仅保存仓库外。生产修复尚未安装，PR 与项目质量目标继续保持未完成。


## 槽位时变与重叠漏失定位

2026-10-18：固定原 18 来源、C0/fast32/fast128、原句级和辅助紧致两套参考，使用已捕获的真实概率帧作 10 ms 网格诊断，不重新运行模型。所有输入、参考和控制内容先冻结摘要，分析结束后复核稳定。为估计标签重排的潜在收益，另计算每 5 秒允许用参考答案重新做最优一对一映射的 oracle；它依赖真值，只用于定位，绝不作为可执行候选或认证结果。

六个四人来源在辅助参考下，fast32 全局最优映射正确活动为 969.24 speaker-seconds，而局部 oracle 仅额外恢复 3.15 秒；C0 和 fast128 分别额外恢复 1.51、3.65 秒。fast32 最弱说话人在重叠区间漏失 22.57 秒，其中 22.40 秒已有其他参考说话人被正确识别；对应弱槽有 7.36 秒概率低于 0.1，只有 4.24 秒落在 strict >0.4 且 ≤0.5 的区间。该证据不支持把主要损失归因于槽位身份交换，也不支持靠轻微放宽阈值解决全部弱声漏检。辅助参考的时钟与语义限制保持不变，不能据此证明模型因果或真实质量门通过。

最弱者的重叠漏失中，7.91 秒分布在不超过 240 ms 的连续漏失段。以既有后处理的 240 ms 参数作唯一固定变体，只连接同一槽位内的短间隙，保留所有短插话、不合并槽位；原 18 来源加既有自然探索输出、两套参考共 76 项离线结果，基线活动与 native 假设精确一致。四人组辅助 recall 从 94.78749% 到 95.10533%，precision 从 96.04423% 到 95.46570%，最低逐人 recall 从 75.69607% 到 75.98231%，通过来源仍为 0/6。18 片辅助 precision 全部下降，未观察到最低逐人 recall 退化，但弱说话人收益不足。自然探索片最低逐人 recall 从 92.61619% 到 93.52386%，仍未过门。

由此不采用统一填洞、不扩大连接时长或继续参数网格。该离线变体尚未实现因果流式稳定水位及延迟语义，也未实跑为新的原生候选；不声称增加的活动时间是实际模型识别结果或产品收益。

## 现有离线会议模型定向对照

2026-10-18：只读核验本机已有 Community-1 模型的发布方文件摘要，构建当前仓库的 SpeechRailDiarizationGlobalProbe，SDK 锁定 5c19d5e12320e22bbfb7a1877b089d2665a69add；未修改第三方源码或下载模型。在 diagnostic-006 原始 148 秒 PCM 上仅登记一组 SDK 默认参数：segmentation step ratio 0.2、embedding minimum duration 1.0 秒、clustering threshold 0.6、Fa 0.07、Fb 0.8，自动估人数，不提供真实人数或参考给模型，不作参数搜索。

该路径使用完整 148 秒上下文，属于离线声学诊断，不与生产流式路径的延迟等价。实际只输出两个匿名说话人，原句级参考 recall/precision/最低逐人 recall 为 49.23013%／78.06708%／0%，辅助参考为 53.79086%／71.74835%／0%；均明显劣于既有路径，不扩样、不接入生产。预加载文件与模型字节在执行前后稳定，native 主进程已回收；这些检查不宣称 loader 已消费字节的完整认证。完成后恢复唯一 listener PID 26770，health/readyz 200、3.12.0、quality/quality，配置、selection 和 runtime target 未变。

同日复查 [转换方模型卡](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml)：其公开 AMI 对照将已有 fast128 列为精度优选，其他公开形状未提供可直接推导为本任务更优的证据。该模型卡只代表其指定数据和协议，不能替代中文开发实测，因此没有因更换 shape 或下载另一份权重就会改善弱声的假设而继续增加候选。

## ASR 错误结构与固定输入电平原型

2026-10-18：在原始规范化规则下，对既有三份真实正文作确定性最小编辑对齐，仅在仓库外读取正文并计算操作，报告只含聚合。Q8 实时的 30 个错误为 22 替换、4 删除、4 插入，最大连续错误段为 3 字；BF16 保留全部 30 个相同操作，另增 1 个替换。Q8 15 秒块有 32 个错误，三种结果共同包含 22 个位置及替换内容相同的操作。预先列出的常见汉字书写歧义集合覆盖 Q8 替换中的 3 项，但未进行人工语义或关键事实判定，不修改参考、规范化或 CER。这些结果不证明大段截断或重复是主要损失，也不能证明其余替换一定是声学错误。

该片整体 RMS 为 −37.19 dBFS，参考语音区间混音 RMS 中位数 −37.07 dBFS、峰值 −13.06 dBFS，固定 2 倍输入不会削波。于是登记唯一增益原型：只在 Qwen3WindowSession 将 PCM 交给实际 ASR decode 前作 int32 乘法与 int16 饱和变换，保持原 VAD、aligner、时间轴、参考和解码策略。每次先确认 request PCM 与原源区间字节相同，再记录变换后实际模型输入摘要；102 次 decode 对应 102 份输入收据，削波为 0，全部覆盖 1974560 个样本、无 token-limit 命中，关闭后 owned children 回收、冻结控制文件与缓存基线摘要稳定。

该 throwaway hook 保存在仓库外，生产候选 spec 不为它提供行为认证；结果只用于开发决策。固定增益仍为 30/515 错、CER 5.82524%，未获得质量收益，因此不移入生产或扩样。完成后恢复唯一 listener PID 28182，health/readyz 200、3.12.0、quality/quality，配置、selection 与 runtime target 未变。

自然 Train_far 原输入/2 倍增益的单片新实跑计划已准备，仍使用已取得的 180 秒/channel 0，不下载模型、不改变配置、不触及留出；参考继续标为未经认证的代理。原持续开发实跑授权限定 Train_near，覆盖 Train_far 的一小时全权窗口已结束，故在用户确认范围扩展前不启动。上述离线自然输出分析未加载模型。


## ASR 边界复核的完整单元裁取

2026-10-18：先在同一 diagnostic-001、123.41 秒原始 PCM 上重新冻结并运行 Q8 观察基线。21 次逻辑复核有 11 次退化为拥有区间重识别，其中 10 次由零时长 token 导致的 `alignment_time_resolution_insufficient` 引起，1 次确为单元跨越拥有边界。当前对齐器已有 segment 模式的保守合并能力，先补充边界反例并确认旧实现按预期失败，再让内部复核复用完整 segment 单元；没有改动对齐模型、原始输入、VAD、时间轴、解码策略或公开 timestamp 接口。

保守合并保留零时长 token 的完整文本和时间点，不创造更细的词时间；只有整个单元落在拥有区间内才能裁取，跨边界单元仍触发原来至多一次的 `owned_only` 重试。新增测试同时覆盖安全单元、左右跨界和跨界零时长 token；相关确定性回归共 165 项通过、1 项跳过，Ruff 通过。

随后冻结修改后的源码和相同依赖，重新启动私有 owner 运行同一片段：

| 项目 | 观察基线 | 完整单元候选 |
|---|---:|---:|
| 逻辑复核 | 21 | 21 |
| contextual / owned_only | 10 / 11 | 19 / 2 |
| 实际 preview / review decode | 71 / 32 | 72 / 23 |
| 实际 decode 总数 | 103 | 95 |
| 复核适配器累计诊断耗时 | 2.91580 s | 1.05833 s |
| 完整覆盖样本数 | 1974560 | 1974560 |
| 派生参考错误 / 字符数 | 30 / 515 | 30 / 515 |
| 派生诊断 CER | 5.82524% | 5.82524% |

候选两次退化均为真实单元跨界，零时长 token 未再造成整段对齐失败。额外 ASR 重试减少 9 次；预览调度随计算完成时序变化，多出 1 次，故总 decode 净少 8 次。累计复核耗时只代表这两个单片运行，不是端到端延迟、P95、RTF 或内存收益。

两份正文并不相同：固定最小编辑对齐下共有 27 项相同错误，基线和候选各有 3 项独有错误。CER 相等不证明关键事实不退化，也没有达到 CER 改善目标；保留人工语义复核、独立主参考和扩样要求，不将效率信号包装为转录质量改善。当前证据支持在 PR 保留该生产候选继续验证，尚未安装或切换正式服务。

两路冻结文件均在运行后稳定、owned children 已回收；候选无 token-limit 命中。缺少独立主参考仍是预期的唯一失败原因，loaded-model/import 字节认证缺口保持原值，不宣称正式质量通过。候选窗口通过 managed CLI 恢复唯一 listener PID 31417，health/readyz 200、3.12.0、quality/quality，配置、selection 和 runtime target 未变。音频、正文、对齐单元和原始制品只保存在仓库外。


## ASR 剩余错误定位与联合候选准备

2026-10-18：使用原 37 条无重叠参考句的真实区间和既有复核拥有区间作只读定位，不给字符均分时间。8 条参考句跨过复核边界，含 140/515 个规范化字符；固定最小编辑对齐下，基线 30 个错误中 6 个、完整单元候选 30 个错误中 5 个落在这些句内。句级定位不是字级因果证据，但不支持把剩余错误主要归因于切口，因此不继续作窗口长度参数搜索。

查阅 [Qwen3-ASR 官方说明](https://github.com/QwenLM/Qwen3-ASR) 与当前 worker：官方公开评测使用 greedy、未指定语言；本机 review 为完整音频 prefix-free 解码，未找到可直接采用且已验证的 beam search 改进。公开评测配置不能替代同源开发结论，也不据此修改生产语言设置。

本机另有 SenseVoiceSmall 缓存 snapshot，共 29 文件、943980179 字节；已检查的当前评测依赖根没有 FunASR/PyTorch，未运行或安装它。其 ASR 与情绪/事件标签不等于分人，官方也明确分人需另外组合组件，见 [SenseVoice 官方说明](https://github.com/QwenAudio/SenseVoice)。缓存盘点不宣称模型已加载、字节已通过发布方校验或质量优于当前模型。

下一项拟诊断为 [OpenMOSS-Team/MOSS-Transcribe-Diarize](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize)，固定 revision `704aa4a9c304e8520be88901e0d1960158ef5b15`，Apache-2.0、原始 BF16，16 个必要文件共 1833089258 字节（1.707 GiB）；主权重和 tokenizer 有发布方 LFS SHA-256。尚未确认 ModelScope 上版本、格式与完整文件集均匹配的制品，拟用官方 Hugging Face 源逐文件校验。其联合文字/匿名说话人路径与目标相关，但模型卡分数不证明本任务收益；这是待检验候选，不是已选中的生产模型。

候选采用独立 Python 3.14 环境，固定 `Blaizzy/mlx-audio` 源码 `4ef6c3a577ade12d946e4b1d1870e4ba67fb5b9a`。只读检查发现 loader 有原始权重布局适配；生成路径支持确定性采样，SDK 的 segment parser 会跳过非法区间或在没有时间戳时生成全长 fallback，诊断必须直接完整解析原始输出并拒绝这些情况。4096-token 固定上限、无参考/热词注入，截断或非法时间范围均失败。该 SDK 的 MLX 0.32.4 有 CPython 3.14/macOS arm64 wheel，完整依赖解析、源码执行审查及运行识别尚未完成，不改现有 runtime。

拟先仅运行已有 Train_near 的 diagnostic-001 与 diagnostic-006，每片 15 分钟超时；同时查看前者派生 CER 和两者 speaker-time 指标，结果无收益则停止，不提前实现生产 adapter 或扩大人数声明。它使用完整片段，只是离线联合诊断，不能冒充实时延迟或跨窗口身份通过。8 GiB 是拟用的保守准入预算，尚非实测内存；真实峰值和清理仍需执行证据。元数据、必要文件表与候选条件已写至仓库外，尚未下载权重、创建新环境或加载模型。新增模型下载和隔离准备的确认正在等待用户答复，原 C1/C2 下载授权不扩用。

同日核验 `adb9247c` 的八项 GitHub CI 全部通过，包括完整 Python 套件、Swift 测试、App 构建及隔离候选 fake 测试；没有真实语料 CI。正式服务自上一窗口恢复后未再次启停，生产安装与配置未改动。


## 边界复核定稿与物理内存对照

2026-10-18：在仓库外分别展开 `292871c6` 与 `adb9247c` 的相关已提交源码，使用同一个观察驱动、相同123.41秒/1974560样本、原始模型、语言与解码策略，各启动全新私有 owner 串行实跑一次。两份生产源码仅边界复核文件有差异；控制内容和源码快照先冻结，运行后复核。复用现有进程观察器，每250ms读取 runner 及实际 ASR/aligner 子进程的 PID+start-time 和 `phys_footprint`，没有使用 RSS 替代。硬件实测为 Apple M5 Max、128 GiB、macOS 27.0.1。

定稿耗时从真实1×输入时钟的拥有区间结束，到服务封存事件通过校验后的观察点计算；时钟回调直接调用标准库 monotonic，replay 仍按其契约标记为 injected，不升级正式时钟认证。每组21个拥有单元，P95采用 nearest-rank；它是本片内部单元分布，不是独立会话分布、人工字词时间或UI延迟。两组物理内存 steady-state 采样最大值约14.97/14.96 GiB，末尾 aligner 均仍约9.08 GiB，因而边界优化本身未观察到内存收益。

随后定位到已有配置链缺口：`Qwen3AlignmentConfig.cache_limit_mb` 未进入启动命令，`memory_limit_mb` 生成的参数未被 worker CLI 接收，两者都没有在对齐模型加载前设置。以 fake allocator 先复现命令丢失、参数拒绝及失败仍不具备正确处理的反例，再贯通已有参数：正值调用当前 MLX allocator API，负值在加载前拒绝，0保留既有ASR侧的vendor-default约定；设置失败返回 `worker_memory_limit_error`，不加载模型或报告ready。没有新建配置旋钮、修改数值或按本机内存大小选择逻辑。

冻结包含该修复的第三份源码快照，只复用原配置4096 MiB缓存提示及0分配提示，再跑同一片段；结果如下。

| 项目 | word 观察基线 | 完整单元裁取 | 裁取＋对齐缓存提示贯通 |
|---|---:|---:|---:|
| 实际 decode | 103 | 95 | 95 |
| contextual / owned_only | 10 / 11 | 19 / 2 | 19 / 2 |
| 复核适配器累计诊断耗时 | 3.22825 s | 1.06532 s | 1.08749 s |
| 拥有区间结束至封存，中位数 | 2.39185 s | 2.29325 s | 2.29587 s |
| 同上，本片单元P95 | 2.87346 s | 2.60619 s | 2.60138 s |
| steady-state 物理内存采样最大和 | 14.97204 GiB | 14.96256 GiB | 13.07690 GiB |
| finish阶段物理内存采样最大和 | 11.98083 GiB | 11.98161 GiB | 8.77082 GiB |
| steady-state末次tick的aligner | 9.08086 GiB | 9.07997 GiB | 5.87126 GiB |
| 派生诊断错误 / 参考字符 | 30 / 515 | 30 / 515 | 30 / 515 |

缓存提示贯通相对完整单元裁取 arm，steady-state观察最大和下降12.60%，finish观察最大和下降约3.21 GiB；95次decode、21次复核、作用域分布、覆盖和完整正文逐字相同。定稿耗时差异很小，不另行宣称缓存修复加速；CER仍为5.82524%，没有达到转录质量改善目标。内存改善只支持该片的开发候选，不能因缓存参数生效就宣称符合某个真实驻留预算或放行并发。

三个arm的观察状态均为complete_metadata：注册owner全部被观测、没有未知子进程或读取失败，注册句柄关闭、cleanup后进程树仅剩runner；独立runtime proof确认owned children回收、关闭及回放后文件稳定。三组均无token-limit命中，缺独立主参考仍是唯一预期失败。仍保留 loaded-bytes/import、原子采样与真实峰值认证缺口，0.25秒采样会漏掉更短的峰值；不把观察最大和改称硬性峰值。存储和Metal缓存未重置，阶段名cold_start不代表严格冷启动；没有warm-N、ABBA、跨硬件或长期会话结论。

缓存配置链与相关对齐/窗口定向回归132项通过、1项跳过，Ruff通过；断言参数传递、单位换算、调用顺序与失败行为，不包含真实模型、本机内存或耗时阈值。三个窗口均使用managed CLI检查无活动请求/客户端后停服并恢复；最后恢复唯一listener PID38275，health/readyz200、3.12.0、quality/quality，配置、selection及runtime target未变。新修复尚未安装，回退可revert对应逻辑commit，现有用户数据与安装态不受影响。新联合模型下载仍待单独确认。


## 四人开发片段的不完整复核恢复

2026-10-18：将资源对照扩展到既有 diagnostic-006、148秒/2368000样本、四人开发来源。基线在两个24秒上下文review失败，保护门中止第二arm并恢复服务，没有将失败运行算作有效资源对照。仅增加结构化失败记录后复跑，103次decode中有两次review没有返回观察证据；输入3552000个24kHz样本全部消费、丢失为0，但终态包含失败。输入覆盖完整不代表正文完整。

随后只在已失败的两个固定区间作原参数诊断。初次独立诊断误把WAV容器字节当PCM裁取，带来22样本偏移，其“同区间”及第二段单独可EOS的结论撤回；详见下方输入校正记录。正确解码容器后的两段上下文均返回`repetition`、`truncated=false`，各自20秒拥有区间均返回完整EOS。没有支持“168-token动态预算截断”的证据，因此没有运行提至512-token的变体，也没有修改预算或接受repetition正文。完整正式回放始终使用正确PCM，其原始两次失败及候选恢复证据不受此次独立诊断错误影响。

生产修复复用现有窗口结果、PCM pin和截止时间：worker保留不完整review的观察证据并返回`complete=false`；协调器先核对结果身份，再仅对拥有PCM重试一次，使用新的attempt ID，不扩展输入或截止时间。重试仍不完整、身份不符、运行错误或超时均按原失败终态收尾；异常假设不能封存。正常上下文复核仍可使用已有对齐裁取及至多一次owned-only回退，两种回退不会在同一初始不完整路径叠加。batch完整段仍保留原严格完整性检查，公共事件字段和默认开关不变。

评测观察器不再通过额外抛错阻断生产恢复；它仍记录`incomplete_decode`并使质量报告无效，不把恢复后的终态包装为所有解码均成功。先确认5项新反例在旧实现失败，再实施；另将恢复条件反转，两个关键回归均失败并逐字恢复源码。确定性测试覆盖精确PCM裁取、唯一重试、新attempt、持续不完整、过期身份、运行错误、原本已是owned-only的失败及非EOS/截断证据；没有本机速度、内存或语料依赖。恢复原因使用有限的`contextual_decode_incomplete`指标标签。

冻结生产候选后，同一148秒1×整片实跑104次decode，其中90次preview、14次review；两次不完整上下文结果都被对应20秒拥有区间的EOS重试恢复。相比诊断基线的91次preview、12次review，总decode净增1次，不能将调度变动当作固定成本。整片43个封存事务、0个失败项，9个正文单元；正文从674字变为938字。两个被恢复拥有区间合计40秒输入，不等于40 speaker-seconds，也不证明新增文字全对。片内拥有区间结束至封存中位数2.93875秒、nearest-rank P95 3.35656秒；基线正文覆盖不同，不据此宣称延迟改善。

该片包含重叠发言，没有独立有序主参考，CER保持未观测。报告继续保留`incomplete_decode`、`decode_limit_not_observed`及`main_reference_not_observed`失败；完整终态恢复不是CER或分人认证通过。整片候选同时包含此前缓存配置修复，不对内存或时延作单变量归因。运行后控制内容与冻结文件稳定，owned children已回收，进程观察为complete_metadata、读取失败和未知子进程为0、cleanup后仅剩runner；loaded-model/import及真实峰值认证缺口保持不变。

维护中另发现一次health/readyz正常但LaunchAgent身份与listener不一致，后续运行在停服前保护性中止。已核对无客户端及精确managed进程，通过现有controller完成一次停止/启动恢复，配置、selection、runtime target未改；后续恢复增加LaunchAgent PID与唯一listener一致性的独立核验。没有安装候选、变更档位、下载模型或触及留出，原始正文与运行制品仅保存仓库外。

随后以同一冻结候选重跑原diagnostic-001、123.41秒：95次decode、1974560样本覆盖、完整正文逐字与缓存修复基线相同，派生诊断仍30/515错、5.82524%，未触发不完整恢复，唯一预期失败仍是缺主参考。独立runtime proof确认子进程回收及文件稳定；资源读取完整、cleanup后仅剩runner。两个实跑快照后的生产改动仅为补齐有限指标原因标签，不改变解码或恢复路径，已用fake回归核验。相关八个确定性测试文件323项通过，Ruff、条件反转检出和diff检查通过；不将这些验证扩展为独立质量验收。

最后通过managed CLI恢复唯一listener PID44981，额外核对LaunchAgent PID也为44981，health/readyz200、3.12.0、quality/quality，配置、selection及runtime target与窗口前摘要相同。`06bf1325`的八项GitHub CI已全部通过；本次修复的远端CI以对应提交后结果为准。

## 固定 Qwen 的实施边界

2026-10-18：用户明确要求不更换ASR模型，固定现有Qwen。此前MOSS联合候选准备属于历史调研，下载/隔离环境/实跑计划停止；该候选没有下载权重、创建环境、加载或运行。后续围绕现有Qwen的解码完整性、上下文与边界处理、分人活动与文字归属推进，不再把联合替换模型列为下一步或等待条件。质量门、独立参考要求及留出隔离保持不变，不能以更多文字或恢复终态代替准确率与逐人召回证据。

## 独立区间输入校正

2026-10-18：扩样预检发现，初次独立区间脚本直接对4736044字节WAV文件切片，没有先除去44字节容器头；正确PCM为4736000字节/2368000样本。原独立诊断输入向前偏移22样本，其相同输入和时序差异解释均不作为证据；原制品保留，不覆写。

固定原来两个失败上下文区间及各自拥有区间，改为先校验容器摘要、使用wave解码并检查16kHz/单声道/16bit/NONE，再按PCM样本轴切片；没有改模型、语言、增益或动态预算。66.704–90.704秒与86.704–110.704秒两个24秒上下文分别返回repetition、136字和20字，均truncated=false；68.704–88.704秒与88.704–108.704秒两个20秒拥有区间分别完整EOS、127字和137字。确认问题为这两个精确输入的非EOS停止，未尝试提升预算或接受异常正文。独立子进程持有继承的同端口租约，完成后冻结文件稳定，managed服务恢复PID46345、health/readyz200、quality/quality，配置/selection/runtime target未变。完整回放的输入与恢复证据独立保留，不由此次短诊断补足质量认证。

## CI 回收测试的确定性

2026-10-18：`d739eab3` 的远端Python完整套件为5410通过、1跳过、1失败，失败为既有 `test_evictor_respects_worker_last_active_attribute`。该测试以实际40/50/60毫秒sleep推断后台检查完成；CI调度速度与本机不同，不能据此认定回收逻辑错误，也不能以放宽sleep掩盖问题。

测试改为模块内受控单调时钟，并逐次放行monitor tick；下一次sleep已进入才断言上一tick的结果。覆盖新活动延长TTL、过期活动不能倒退时钟、刚好达到TTL时回收，不改生产TTL或循环。事件循环继续使用真实时钟，1秒wait_for只作卡死保护，不作为性能门。定向测试文件与Ruff通过；将worker活动读取临时置空时新测试失败，生产源码逐字恢复。首次局部运行虽断言通过，但触发全仓80%覆盖率门，随后使用局部测试的`--no-cov`范围完成验证；完整覆盖率仍由远端完整套件验证，不将局部结果称为完整CI通过。修复已提交为`3d26306f`，对应远端八项检查全部通过，包含完整Python套件、Quality Gates、Swift测试、App构建、wheel产物、汇总门和隔离候选fake检查。

## 有界恢复的独立开发来源扩展

2026-10-18：在读分数前固定既有catalog中各人数层首个未使用来源，选取三人的diagnostic-004（162.89秒/2606240样本）及两人的diagnostic-008（120.02秒/1920320样本），来源组与001/006不同。四个arm全部先通过冻结输入预检，再按来源串行运行before/after；before为`06bf1325`，after为`d739eab3`，同一Qwen Q8、aligner、语言、参数及1×输入，不更换ASR或分人模型。

| 项目 | 三人 before → after | 两人 before → after |
|---|---:|---:|
| decode次数 | 133 → 133 | 91 → 91 |
| preview / review | 100/33 → 100/33 | 74/17 → 74/17 |
| 正文字数 | 690 → 690，逐字相同 | 549 → 549，逐字相同 |
| 失败拥有区间 | 0 → 0 | 0 → 0 |
| 不完整review / 恢复次数 | 0/0 → 0/0 | 0/0 → 0/0 |
| 拥有区间结束至封存，中位数 | 2.25788 → 2.25368 s | 2.42895 → 2.41390 s |
| 同上，片内nearest-rank P95 | 3.16836 → 3.18309 s | 3.08354 → 3.08581 s |
| steady-state物理内存采样最大和 | 13.33790 → 13.50193 GiB | 13.64564 → 13.52865 GiB |

两组完整样本覆盖及终态区间分割均通过，未触发恢复的正常路径在这两个新增来源保持正文与decode工作量相同。这是小范围未见回归的证据，不是恢复普适有效、CER改善或人数认证；每个arm仅一次，没有ABBA、严格冷启动或完整峰值认证，不将小幅耗时/内存差异解释为收益。两个来源有重叠发言且没有独立有序ASR主参考，四份报告均保留`main_reference_not_observed`与`quality_evidence_valid=false`，不补造CER。

四次窗口均完成owned children回收、控制文件摘要复核及回放/关闭后文件稳定检查；资源观察为complete_metadata、没有读取失败、cleanup后无owned子进程。每次恢复均额外确认LaunchAgent PID等于唯一listener；最后PID48995、health/readyz200、3.12.0、quality/quality，配置、selection与runtime target摘要未变。没有安装候选或读取留出，原始数据和正文保留仓库外。

## Qwen 语言判定对照

2026-10-18：完成上述四arm的完整性检查后，仅将同一Qwen Q8候选的语言从Chinese改为auto，执行预登记的唯一diagnostic-001、123.41秒对照。模型文件、设置、增益、PCM、上下文和预算不变，不给模型参考或热词。候选源码为`d739eab3`；对照此前有界恢复快照，candidate spec除语言外还有SDK源码revision差异，后者为有限指标标签补齐，不改变解码及恢复逻辑，不能把整体候选身份称为相同。

两组均95次decode、1974560样本完整覆盖，593字正文逐字相同，派生诊断仍30/515错、5.82524%。拥有区间结束至封存中位数2.29559→2.30451秒、片内P95为2.61373→2.62549秒；steady-state物理内存采样最大和12.99415→13.12437 GiB。每组仅一次，不解释小幅时延/内存变化；没有识别收益，不采用auto或继续搜索语言参数。按一种最优字符编辑对齐，30个错误由22次替换、4次插入及4次删除构成，不涉及Latin字符；不将编辑分类当作声学或语义因果证明。

候选仅保留缺独立主参考的预期失败，质量报告仍无效。关闭后owned children回收、文件稳定、完整资源观察和cleanup检查通过；managed服务恢复PID50417，LaunchAgent与唯一listener一致、health/readyz200，配置、selection与runtime target未变。没有替换ASR、下载模型、安装候选或触及留出。

## Swift 失败终态的测试观察点

2026-10-18：`2341e190`的Python完整套件通过，Swift套件的一项既有测试在部分回复已投影时过早断言`lastFailure`非空。源码确认`finalizeReply`追加turn后，调用方仍需等待interrupt effect返回，再以session/connection/generation守卫发布失败原因；行存在不等于完整失败终态已发布。

测试改为同时等待助手行、非空失败原因及listening状态，保留原有断言和等待上限，不更改生产顺序。`swift test --package-path macos/SpeechRailApp --filter AssistantSessionTests`的46项通过；只使用fake依赖，没有UI自动化、真实网络模型或服务变更。最终远端门以修复提交的CI结果为准。

## 离线分人的重叠输出核查

2026-10-18：只读检查已锁定的FluidAudio SDK，发现Community-1默认`postProcessing.exclusiveSegments=true`，重建后的sanitize会裁去不同speaker的重叠；SpeechRail的MeetingDiarizationWorker和GlobalProbe均继承该设置。该SDK子树未进入结构图索引，此结论以本地锁定源码直接核验为准。

此前离线默认候选的低召回事实保留，但不能仅据其互斥输出判断模型能否保留重叠。随后登记唯一关闭该裁剪的对照，保持现有模型、输入、自动人数及其余SDK参数，结果见下节；核查时未修改生产分人配置或宣称人数能力。

## 离线重叠裁剪的同源结果

2026-10-18：在仓库外构建相同工具链、相同SDK源码的before/after，唯一声学输出策略差异为`postProcessing.exclusiveSegments=true→false`。为避免既有SwiftPM缓存错误引发冗余网络拉取，终止已核实的本次构建/Git子进程，改用逐文件校验一致的本机SDK源码及原生依赖构建；没有修改第三方checkout或下载新模型。所有模型文件、源码、二进制、输入、参考及评分器在运行前冻结，结束后摘要复核稳定。

同一diagnostic-006、148秒四人派生来源，每个arm新建原生进程、自动估人数。新before的完整活动与历史默认输出逐项相同，两套参考的原分数均精确复现。关闭裁剪后的预测重叠时长从0增至32.37689秒，但仍仅输出2个匿名speaker：

| 参考 | 设置 | recall | precision | 最低逐人recall |
|---|---|---:|---:|---:|
| 原句级 | 互斥 | 49.23013% | 78.06708% | 0% |
| 原句级 | 保留重叠 | 58.12383% | 74.02903% | 0% |
| 辅助活动 | 互斥 | 53.79086% | 71.74835% | 0% |
| 辅助活动 | 保留重叠 | 63.52156% | 68.05115% | 0% |

召回增加伴随精确率下降，逐人门仍失败；不采用该变体、不扩样、不修改生产离线路径，不能把输出重叠本身当作真实分人质量收益。50ms采样的原生进程物理footprint最大值分别为976274488/973095992字节，读取缺失及观察到的子进程均为0；进程均已wait回收。单次before/after墙钟为1.89881/1.31805秒，包含加载及采样，不是流式延迟；操作系统及设备缓存未重置，不将差异归因于裁剪，也不宣称峰值或净性能收益。该诊断与现有生产流式Sortformer使用的模型及上下文不同，不据此替换生产模型。

## 离线人数已知的定位诊断

2026-10-18：为区分自动人数偏少与其余聚类/声学损失，仅登记一次`numSpeakers=4`的oracle诊断，同时保留重叠。明确把参考人数4提供给SDK；此设置还会按SDK实现切换到指定人数的重新聚类并关闭co-chunk constrained assignment，因此不将差异归因于单一计数器。它不是可采用候选，不满足盲测、人数认证或模型质量验收条件。

实际输出4人，原句级recall/precision/最低逐人recall为67.10440%/89.32372%/30.73783%；辅助活动为72.42965%/81.09586%/37.58217%。即便提供正确人数，弱说话人覆盖仍明显不足；不继续对该离线候选调人数或阈值，不把已知人数包装成自动识别能力。原始结果、oracle角色和参考人数证据均保留仓库外，没有推广到其他来源。

两个窗口均经managed CLI确认无客户端后停服，结束恢复；最后唯一listener与LaunchAgent均为PID55167、health/readyz200、3.12.0、quality/quality，配置、selection和runtime target未变。两套参考保持原有角色，没有替换ASR、安装候选或触及留出。`88b986a9`的八项GitHub CI已全部通过，后续文档提交以其自身CI状态为准；本轮没有可采纳的生产质量策略变更。

## 同延迟 Sortformer v2 对照准备

2026-10-18核验：锁定SDK的`SortformerTypes.swift`提示v2.1在多人同时发言时可能退化，v2可作对照；发布方模型卡则称v2.1在会议场景更稳健，不能从版本号或单条说明推断本机优劣。[发布方模型卡](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml)列出v2/v2.1低延迟配置，二者均为4speaker输出；这条对照不承担5–8人认证，也不改变固定Qwen的约束。

本机仅找到原始v2 NeMo检查点，未找到对应已编译CoreML bundle，现有评测环境也未安装PyTorch/NeMo/CoreML转换工具。已核对发布方`FluidInference/diar-streaming-sortformer-coreml`固定revision `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`的`v3/fp16/SortformerNvidiaLow_v2.mlmodelc`：10文件、246275129字节（234.87 MiB），CC-BY-4.0；LFS SHA-256与普通Git blob标识分别保留，下载后仍需按对应算法及大小校验。未检索到同revision/完整编译制品可校验的ModelScope副本，因此使用发布方Hugging Face源。

仅准备仓库外评测worker的软件构建：替换bundle名称守卫及`.balancedV2`配置，复用已核实的本机SDK与原生依赖，不改变生产代码、模型选择、安装或配置。唯一拟跑来源为已授权Train_near的006和001，活动阈值保持0.25，不提供参考或真实人数；先做同源对照，再决定是否扩样。用户随后明确授权“允许，仅分人对照”；下载与回放结果见下节。


## Sortformer v2 同源对照结果

2026-10-18实测：仅下载上述固定revision的10个文件，逐文件验证大小；LFS内容核对SHA-256，普通文件核对Git blob SHA-1。下载的最后一个权重因单连接速度较慢，停止本次下载进程后按Range续传，合并后再次核验完整权重SHA-256，随后复核全部10文件。模型、原始概率、输入、参考和日志均在仓库外。

分别构建相同工具链、相同本机SDK及原生依赖的v2.1/v2 worker，私有Swift源码仅有bundle名称守卫与`balancedV2_1→balancedV2`两处差异；Python私有adapter仅调整bundle名称守卫，仍逐文件验证冻结的候选哈希及相同MIL输入输出签名。两组preset的chunk、context、FIFO、speaker cache和阈值均相同，活动阈值固定0.25。运行前分别冻结真实preset、模型、adapter和worker源码/二进制身份；没有将v2身份伪装为v2.1。生产代码未改动。

按006的v2.1/v2、001的v2.1/v2顺序回放；每次独立原生进程，完整输入覆盖与EOF水位均核对，原生进程均已wait回收，控制文件、源码、二进制与模型在前后复核稳定。新v2.1的两片完整活动输出与历史C0逐项相同；未提供参考文本、真实人数或speaker提示给模型，没有运行或更换Qwen。

| 来源 | 参考 | 分人版本 | recall | precision | 最低逐人recall | 诊断门 |
|---|---|---|---:|---:|---:|---|
| 006（四人） | 原句级 | v2.1 | 82.70449% | 88.98657% | 63.21001% | fail |
| 006（四人） | 原句级 | v2 | 85.19233% | 73.55739% | 72.91267% | fail |
| 006（四人） | 辅助活动 | v2.1 | 92.99864% | 84.16634% | 80.17174% | fail |
| 006（四人） | 辅助活动 | v2 | 88.13643% | 64.00999% | 73.60937% | fail |
| 001（双人） | 原句级 | v2.1 | 88.98432% | 98.82431% | 88.46724% | fail |
| 001（双人） | 原句级 | v2 | 98.10247% | 97.78995% | 97.43976% | pass |
| 001（双人） | 辅助活动 | v2.1 | 98.44881% | 95.03106% | 98.31093% | pass |
| 001（双人） | 辅助活动 | v2 | 100% | 86.64012% | 100% | fail |

v2在双人原句级上改善覆盖，但辅助参考的精确率下降；四人场景原句级精确率下降15.42918个百分点，辅助参考召回、精确率及最低逐人覆盖均退化。两套参考保留各自角色，不择优替换。拒绝将v2作为生产替代，不扩展该候选、不启动阈值网格，也不能据双人单片通过宣称人数认证或总体质量达标。保留固定Qwen及生产v2.1；后续优化须针对已定位的弱说话人覆盖与重叠误报，用新可检验假设形成产品收益。

回放是本机吞吐诊断，不是实时延迟或跨机器性能验收。006的v2.1/v2墙钟为4.81650/4.42504秒，001为2.59514/2.59143秒，均包含原生启动/加载；未隔离操作系统和设备缓存，未测物理footprint，不作速度、峰值内存或资源节省结论。GitHub CI没有执行真实语料或加载模型。

四个窗口均确认无活动客户端后通过managed CLI停服，结束立即恢复；最终唯一listener与LaunchAgent一致为PID57920，health/readyz均200，配置、selection和runtime target摘要未变。没有改变安装、profile、selection，未接触far或留出。仓库外保留`sortformer-v2-balanced-review-20261018`的下载校验、冻结计划、四次结果、恢复证明和完整比较；此处不包含转写正文、音频、embedding或绝对模型路径。


## FIFO 复核概率与 ROI 止损

2026-10-18：直接核验锁定SDK源码，Sortformer会重算近期FIFO概率，而生产worker仅输出首次chunk概率并立即稳定。登记一个固定诊断，在仓库外worker额外导出已有FIFO概率，不增加模型调用、不改模型、阈值或生产协议；按相同1秒输入包回放006/001。两片首次活动逐项复现生产基线，完整覆盖、控制摘要复核和子进程回收通过。将每帧替换为最后一次可观察的FIFO概率，得到：

| 来源 | 参考 | 首次/最后FIFO | recall | precision | 最低逐人recall |
|---|---|---|---:|---:|---:|
| 006 | 原句级 | 首次 | 82.70449% | 88.98657% | 63.21001% |
| 006 | 原句级 | 最后FIFO | 82.82842% | 91.65482% | 63.88266% |
| 006 | 辅助活动 | 首次 | 92.99864% | 84.16634% | 80.17174% |
| 006 | 辅助活动 | 最后FIFO | 93.72988% | 87.24096% | 83.26828% |
| 001 | 原句级 | 首次 | 88.98432% | 98.82431% | 88.46724% |
| 001 | 原句级 | 最后FIFO | 89.00429% | 98.75887% | 88.23006% |
| 001 | 辅助活动 | 首次 | 98.44881% | 95.03106% | 98.31093% |
| 001 | 辅助活动 | 最后FIFO | 98.56371% | 95.05762% | 98.53499% |

四人精确率有局部改善，但质量门仍失败，双人原句级精确率和最低逐人覆盖轻微下降。两片最长可观察修订年龄14.88秒；这只是1秒输入包下的事后概率诊断，不是已实现的生产修订协议、稳定标签延迟或净资源收益。按用户要求的ROI顺序止损：不投入延后稳定水位、标签重修订和客户端协议改造，不继续扩大该分支或调参。没有新的生产质量策略可采用，不将诊断进度算作产品收益。

两次维护均确认无客户端后通过managed CLI停服并恢复；最后唯一listener和LaunchAgent为PID59434，health/readyz200，配置、selection及runtime target未变。Qwen未运行或变更，未下载新模型、触及far/留出。仓库外`sortformer-fifo-revision-diagnostic-20261018`保留固定假设、源码/worker身份、FIFO概率、评分和恢复证明。

后续优先级按预期用户收益、证据强度及完整实施/验收成本排序：优先定位生产会话的错漏词和文字归属损失，以及会阻塞音频接收/定稿的确定性等待；其次采用已证实的资源瓶颈修复；收益不明确的模型、阈值与多候选搜索后置。新诊断必须有单一假设与止损条件，失败即换方向，评测框架完整性不作为前置。


## 原生分人结束预算的生产修复

2026-10-18：按ROI优先处理已有结束保护的缺口。共享`DiarizationSession.finish`原先先无限等待`activity.finish`，随后才给事件pump 30秒排空预算；Realtime及HTTP外层已有自身deadline，因此不将此描述成所有调用方都会无限等待。生产修复用同一个内部预算覆盖原生EOF及事件排空，超时按`finalization_timeout`降级，取消并join活动pump；原worker的close/join与资源隔离规则仍生效。没有扩大并发、改模型或引入PCM缓冲队列。

实跑发现原生EOF取消会先关闭活动流，使pump抢先发出`diarization_invalid_output`。追加RED反例后，结束期间的流失败交由finish owner归因：正常收尾中的真实流错误仍按invalid-output降级，取消引发的错误保留timeout。Realtime投影同步保留该既有公共错误码；WebSocket反例先RED后GREEN，冻结正文保持有效。契约和用户手册同步明确结束预算与错误原因。

首次真实窗口保留正常前后与故障基线结果，因取消竞争的断言失败而结束，原服务已恢复；未覆盖原制品。修正后重新冻结源码，在仓库外同一生产v2.1 worker、SDK、模型、阈值、输入与评分器上完成四次运行：正常006的before/after、故障001的before/after。故障在真实原生EOF响应已生成后仅暂扣其交付，不模拟音频或概率。故障组内部预算固定250ms，外部诊断看门狗1秒；这不是生产默认值或机器性能门槛。

正常148秒四人片段的1850帧完整活动输出和质量评分逐项完全相同，覆盖到2368000 samples；finish观察为13.447/13.904ms，不作正常速度提升结论。故障基线耗尽1秒外部看门狗，由观察器取消，未自行返回actor终态；修复版在263.260ms返回degraded，原因为`finalization_timeout`，不依赖外部看门狗。四组原生进程均wait回收、消费者均join；未确认的尾部归属不被封存为已识别speaker。这是EOF卡住时的有界降级收益，不是CER或分人准确率改善。

50ms原生物理footprint观察最大值：正常before/after为269059200/263914600字节（各63/62次有效读取、0缺失），故障为262308944/262423656字节（73/59次读取，基线1次缺失）。采样不完整且未控制系统缓存，不宣称峰值、内存降低或净资源收益；没有运行Qwen或ASR/分人联合会话，不能外推UI延迟。运行前后冻结输入、模型、worker、actor源码与评分器摘要稳定。

验证：6个定向测试文件92项通过、0失败/跳过；四个结束阶段/取消竞争反例及WebSocket公开错误码反例覆盖新行为，首次RED保留。条件反转mutation检出取消竞争，源码逐字节恢复；Ruff及另外6项WebSocket契约/用户文档检查通过。测试使用事件门和受控deadline，不依赖本机推理速度，不加载模型或读取真实语料。完整CI以该提交的远端状态为准。

最后通过managed CLI恢复后唯一listener与LaunchAgent均为PID63138，health/readyz200、3.12.0、quality/quality，配置/selection/runtime target摘要不变。生产源码未部署或安装；运行的是仓库外冻结实现。回退可revert本逻辑提交；两次诊断目录`diarization-native-drain-deadline-20261018`和`diarization-native-drain-deadline-race-fix-20261018`保留原始证据，不进入仓库。原质量目标、独立参考和人数认证仍未完成。

## ASR 已定稿文字上下文的扩样止损

2026-10-18：冻结唯一候选，仅给正式review提供此前成功封存的模型文字后96个字符；预览保持空上下文，用户显式context优先，失败封存后清空历史。固定Qwen、中文、模型文件、解码和音频策略，不提供参考或热词给模型。首个候选尝试被诊断器原有的空context检查拦截，不计模型退化或质量结果；随后在仓库外将上下文逐次独立核对到已发送的成功封存文字，并在候选身份中声明该策略，保留PCM、attempt及结果身份检查，重新冻结后实跑。fake预检覆盖来源不符、预览非空与失败清空，没有修改生产实现或正式评测默认规则。

新001基线逐字复现既有正文。首片错误30→26后，按预登记规则，从013、015中各取最长的连续无重叠、完整语句区间，两个来源与001独立；选区不使用ASR输出。两片仍是原headset均值混音的裁剪，保留源会议分组、父PCM摘要、采样区间及原变换，不视为自然会议或独立主参考。

| 来源 | 秒数 | 归一化参考字符 | 基线/候选错误 | 基线/候选decode |
|---|---:|---:|---:|---:|
| 001 | 123.41 | 515 | 30 / 26 | 95 / 95 |
| 013无重叠区间 | 104.22 | 402 | 31 / 30 | 87 / 87 |
| 015无重叠区间 | 51.01 | 229 | 19 / 19 | 42 / 42 |
| 合计 | 278.64 | 1146 | 80 / 75 | 224 / 224 |

派生诊断CER为6.98080%→6.54450%，相对下降6.25%，不能沿用首片13.33%作为总体结论。001按同一种最优对齐减少2个删除和2个替换；013减少3个替换但增加2个插入，两个语句的错误数上升，其中一个原先无错。015错误数不变。三来源不足以建立目标所需的配对统计及关键事实人工复核；独立主参考、自然场景及相对冻结A0认证仍缺失。

三片拥有区间结束到服务封存的中位数分别为2.356→2.336、2.274→2.274、2.597→2.393秒，每组单次，不作UI或总体速度收益声明。250ms顺序物理footprint采样均无读取缺失或monitor失败，但峰值未验证；前两片steady-state观察最大和分别增加约1.16%和0.97%，第三片下降约2.85%，不宣称净资源收益。

按ROI不将该候选设为生产默认，不继续改变长度、前缀或搜索更多参数。六次有效回放均完整覆盖、无转录失败，仅保留缺主参考的预期限制；owned子进程回收、关闭后冻结文件复核和服务恢复通过。最终以安装态解释器隔离导入复核：LaunchAgent与唯一listener均为PID72774，health/readyz/metrics200、active requests均0、3.12.0、quality/quality，配置/selection/runtime target摘要未变。未下载模型、安装候选、修改profile或触及far/留出。

仓库外`asr-sealed-context-20261018`保存首个无效尝试、六个有效arm、选区与候选登记、逐次上下文摘要、正文、错误定位、资源观察、`paired-decision.json`及最终服务证明。这里只提交脱敏结论，不把工具或诊断进度计作产品收益。`82f07449`的八项GitHub CI已全部通过；下一步优先在实际会话中核查ASR文字与分人活动的归属损失，不扩大本上下文分支。

## 连续分人下的 ASR 段预算修复

2026-10-18：安装态公开WebSocket真实联合会话发现，请求20秒ASR段且开启分人时，配置回显与实际切段均被额外压到8秒；同片`full_segment`与`streaming_finalize`均为40/515次字符错误，因此不继续切换定稿方式。暂关分人的单一筛查得到20秒预算、35次错误，仅用于确认切段假设，不能作为联合候选证据。核验当前实现：固定文字对齐PCM上限及分人单次文字登记上限均为30秒，连续活动流不要求8秒ASR段。修复移除分人附加的8秒限制，仍按请求、服务缓冲和30秒解码上限取最小值；不改变VAD、预览间隔、模型、语言或原生概率阈值。

在仓库外分别冻结PR基线与仅含该修复的源码、实际Qwen/aligner/CoreML制品、依赖和输入，使用生产`AppServices`、`OpenAIRealtimeSession`、共享Governor与三个真实worker完成联合对照；私有runner不启动HTTP listener，不是候选安装态公共API或UI验收。每组1×供给相同100ms PCM包，以既有精确逆嵌入供给24k wire；这是绑定当前重采样实现的16k开发诊断，不是自然24k采集认证。ASR固定Qwen，参考与热词不进入模型。先验证001，再按登记顺序复用此前选定的013/015无重叠裁剪，没有按ASR输出重新挑选样本。

| 来源 | 音频秒数 | 参考字符 | 基线/候选错误 | 基线/候选正式段 | 基线/候选对齐失败 |
|---|---:|---:|---:|---:|---:|
| 001 | 123.41 | 515 | 40 / 35 | 24 / 21 | 0 / 0 |
| 013无重叠 | 104.22 | 402 | 45 / 40 | 26 / 22 | 1 / 0 |
| 015无重叠 | 51.01 | 229 | 21 / 20 | 10 / 7 | 0 / 0 |
| 合计 | 278.64 | 1146 | 106 / 95 | 60 / 50 | 1 / 0 |

派生诊断CER为9.24956%→8.28970%，相对下降10.37736%；三个来源均改善。001减少3个删除、4个插入，但增加2个替换，有2个参考语句变差；013减少1个插入、4个替换，无变差参考语句；015减少1个插入，无变差参考语句。全部仍缺独立主参考、充分的来源级配对统计和关键事实人工复核，不能据此宣布相对冻结A0的正式CER门通过。它与此前revision-window路径30/515的结果属于不同请求/路径，不混算改善。

013基线在连续两个8秒rollover后留下352ms尾段，ASR输出2个codepoint（归一化1字），强制对齐报`alignment_out_of_bounds`。观察器因辅助失败断言退出，全部ASR、输入、原生活动、回收和冻结复核已经完成；故障原样保留并恢复服务，没有重复跑基线。随后候选单独维护，显式统计辅助失败与全部终态，得到0次对齐失败；不裁剪或伪造时间戳。初次维护离线预检还因复用ASR-only旧源码摘要而在停服前拒绝，保留该记录，后续由各arm冻结实际联合闭包。

013/015被动记录的全部原生活动更新、概率、slot和水位逐项相同，分别覆盖1303/638帧；001未记录原生帧，不外推其speaker-time不变。按原句级区间中单一speaker、至少80%覆盖的已对齐文字单元进行整场匿名置换诊断：三来源错标文字分别0→0、0→0、2→2，未知文字4→4、4→4、6→5。013基线另有1个归一化字因对齐失败不进入该已对齐子集；单列保留。不同ASR正文和单元数不能直接当作共同词时间参考；这些文字归属诊断不是speaker-time质量门或人数认证。

资源与及时性有代价。Apple M5 Max、128GiB、macOS27.0.1、Python3.14.7，每arm一次，250ms owned进程树物理footprint采样无缺tick，但峰值未验证。三个来源的观察最大和分别为12142945016→12854813504、11104920024→13230383768、10645823960→11740684904字节，增加5.86%/19.14%/10.28%；不能称净资源优化。按模型对齐时间估算的单元音频结束至ASR正式文字中位数为3.122→3.823、2.359→2.970、2.956→4.885秒；这是模型时间与私有供给时钟，不是人工词时间或UI延迟。段关闭至正式文字中位数为0.157→0.155、0.121→0.115、0.156→0.169秒，单次不作速度提升结论。请求较短段仍受尊重，不自动扩大用户请求。

保留该低复杂度的准确性修复与预算契约，明确较长段的资源和正式文字等待取舍；安装态未替换，PR继续draft，正式质量与净资源目标仍未完成。六次实跑均完整输入、ASR终态齐全，三个owned子进程wait回收、关闭后文件复核通过；四个维护窗口均先排除客户端后managed停启并恢复，最终唯一listener/LaunchAgent为PID82583，health/readyz200、3.12.0、quality/quality，配置、selection和runtime target摘要未变。没有下载、安装、改profile或触及新增far/留出。仓库外`asr-diarization-segment-budget-20261018`保存公开筛查的关联、冻结登记、原生更新、正文、失败记录、资源/延迟比较与维护证明；Git只保留脱敏结论。

验证：4个定向测试文件184项通过，无失败或跳过；新增4个fake联合会话用例覆盖20/30秒实际切段、首次分人启用与后续策略更新、小缓冲约束和短请求。最终用例对冻结8秒基线为3失败/1通过，旧限制被检出；小缓冲控制保持通过。Ruff、用户文档契约（39路径/21错误码）及Realtime契约（61fixture/65字段）检查通过；工作树生产Python逐字匹配已实跑的冻结候选。最后再由安装态解释器隔离导入复核health/readyz/metrics200、active requests均0、PID82583与配置摘要。测试不加载模型、读取真实语料或依赖本机推理速度；完整CI以新提交的远端状态为准。回退可revert本逻辑提交，未改变持久化格式或用户数据。


## 对齐请求结束后的临时缓存释放

2026-10-18：按ROI先定位较长ASR段的资源代价，固定上一提交`ebd34638`、既有013无重叠104.22秒开发片段、20秒请求预算及全部模型和配置，复用真实联合会话，仅为已有250ms进程树观察保留worker角色。基线采样最大值分别为ASR 7.09GiB、aligner 4.91GiB、分人0.27GiB；aligner退出前仍有4.76GiB。代码核验发现ASR定稿后已有缓存清理，对齐worker仅响应显式trim。

候选只在每个`align_text`处理函数离开后调用既有缓存清理，成功和失败均经过`finally`；释放闲置分配，不卸载权重，不改变缓存上限、模型或切段参数。两个fake回归先在基线失败，再在修复后通过，验证失败请求不阻断下一请求及清理顺序；三个相关文件64项测试与Ruff通过。没有新增本机速度阈值或CI真实语料入口。

同源基线/候选各一次完整真实回放：22个ASR正式结果、22个对齐结果、411个归一化输出字、40/402个派生字符错误均不变；逐段正文及全部对齐输出一致，1303帧原生活动及概率也一致。最初按随机item ID排序比较正文集合产生假不一致，改为正文多重集并交叉核对有序对齐正文后确认一致，不修改推理结果。

进程树观察最大和13073834528→10199310616字节，下降21.99%；aligner采样中位数4702882768→2001144568字节，下降57.45%，观察最大值5266295808→3371485944字节。ASR自身观察最大值7614172592→7671893376字节，未改善；不继续在本分支叠加ASR缓存猜测。上一轮同一20秒013候选观察最大和13230383768字节，与本次基线相近，但不是本次配对重复。上述顺序物理footprint采样无缺tick，仍不是已验证峰值或跨硬件保证。

ASR正式文字后至对齐完成中位数29.74→38.57ms，增加8.82ms；段关闭至ASR正式文字110.50→113.01ms。每arm单次，不能区分微小变化与运行噪声，不声称提速。资源下降明显且内容与时间区间相同，保留该低复杂度优化；重复性、长会话、自然24k及正式质量门仍未验收。

两个维护窗口均在无客户端、active requests为0时managed停启并恢复；最终唯一listener/LaunchAgent为PID85807，health/readyz200，3.12.0、quality/quality，配置/selection/runtime target摘要未变。全部输入完整、三个owned子进程wait回收及关闭后冻结字节复核通过。未下载、安装、改profile或触及far/留出；候选仍只在draft PR中。仓库外`asr-joint-cache-diagnostic-20261018`保留登记、冻结源码、逐进程观察、完整比较和维护证明；继承driver中的旧切段假设/基线文字标签由独立登记显式更正，身份以实际冻结字节为准。回退可revert该逻辑提交，无用户数据或持久化格式变化。上一提交`ebd34638`的八项GitHub CI已全部通过，本提交CI另行观察。


## 四人联合路径的归属复核与缓存扩样

2026-10-18：按ROI停止重开已拒绝的声学阈值、增益、模型与FIFO分支。先冻结`4cd01ba6`，在既有diagnostic-006、148秒四人Train_near派生片段上运行当前Qwen、aligner及生产C0联合路径；1×供给100ms包，20秒ASR预算、15分钟推理上限、原配置及Governor不变，不向模型提供参考。全部3552000个24k wire样本消费，9个正式ASR与9个对齐结果完成，无失败；队列高水位2，三个owned子进程wait回收和关闭后冻结字节复核通过。

717个对齐单元含799个归一化输出字。沿用原句级区间中单一参考说话人覆盖至少80%的诊断及整场匿名最优置换，389个可评估字中371字正确、18字未知、0字错标；另409字落在多参考说话人的重叠区间，1字在参考边缘，不按单一真值评分。逐人可评估字的正确/未知分别179/7、19/0、147/9、26/2，样本分布不均，不能当作speaker-time逐人门。

全部输出有260字未归属。按捕获的完整原生活动、既有0.60支持率及0.10胜出差额复核，254字因多个槽位接近而不确定、5字覆盖不足、1字无活动；717单元中，完整活动支持规则与实际最终标签无一不符。此复核仅将输出匿名标签与原生slot对应，不把参考答案用于执行。1850帧活动、概率、slot与历史同片C0逐项一致，底层分人识别未改善。没有发现足以支持修改归属算法的额外应用层损失，不强制填充未知、不调整阈值、不继续该分支搜索。

随后登记上一轮缓存优化的四人扩样，复用已完成的`4cd01ba6`候选，仅补跑`ebd34638`旧缓存行为基线；顺序为候选先、基线后，各一次，不是随机ABBA。两个冻结生产源码树仅`qwen3_alignment_worker.py`的请求后清理不同。模型与PCM摘要一致；原始配置摘要因独立源码路径不同而不相同，不能直接忽略。无模型的cold重建分别精确复现两次已登记配置摘要，仅将各自冻结源码根替换为共同占位符后，完整配置摘要及所有字段一致；并复核控制/参考字节未变。

基线/候选的9个正式ASR结果、全部正文、对齐区间及原生活动完全一致，文字归属诊断也相同。250ms进程树物理footprint观察最大和14441259576→10187317720字节（下降29.46%），aligner采样中位数5844224832→2000653048字节（下降65.77%）；无缺tick，仍不声明已验证峰值或跨硬件预算。正式文字至对齐完成中位数44.50→50.71ms（增加6.22ms），段关闭至ASR正式文字568.89→568.50ms；单次不作提速结论。该独立来源扩样支持保留现有缓存改动，本轮没有新增生产策略或质量提升声明。

两个维护窗口均确认无活动客户端及请求后managed停启，最终唯一listener/LaunchAgent为PID88255，health/readyz200、3.12.0、quality/quality，配置/selection/runtime target摘要未变。未下载、安装、改profile或触及far/留出。仓库外`asr-four-person-joint-attribution-20261018`及`asr-four-person-cache-expansion-20261018`保留冻结、原生帧、逐单元支持分析、对照、cold配置证明和恢复记录；Git仅提交脱敏结论。`4cd01ba6`八项GitHub CI已全部通过，真实语料未进入CI。正式ASR主参考、关键事实人工复核、充分配对统计、自然场景及完整质量/峰值门仍缺失，`certified_max_speakers=null`，PR继续draft。


## 自然会议联合回放与ASR预览缓存释放

2026-10-18至19日：用户明确授权将真实开发评测扩展到本机已有Train_far，继续固定Qwen及生产分人模型。先核验App静态会议预设：1000ms预览、900ms静音结束、20秒full_segment，不显式指定language或final_deadline，revision window默认不启用；私有联合session按这些参数运行，未接管App或声称验证Swift客户端/UI。此前1500ms预览、400ms静音的诊断不能当作该默认预设证据。既有001近场123.41秒基线完整完成10个正式ASR与10个对齐结果，派生参考仍为35/515字符错误，未发现新的准确性收益，停止该参数方向。

首个自然输入是既有Train_far/channel 0的原始180秒，未混音或加增益，以精确映射的24k wire供给生产16k链路。来源仅有归档前32MiB的既有提取制品，完整归档未校验；近场/远场三个60秒窗口的粗粒度RMS相关时移均为−40ms，不能认证完整时钟。旧准备记录写了2人，经找到四份既有TextGrid并逐份核对原登记大小与SHA256，确认四条轨道在这180秒均有标注语音；修正人数元数据，不把四人自然片段直接当作四人认证。46条完整句作为近场文字/区间代理，仅用于诊断，跨180秒边界的句子排除；未提升为独立ASR主参考或catalog正式fixture。209个输出字处在参考重叠区间，原句级时间包含停顿，不能强行拼接全场参考计算CER。

冻结`550b43b0`自然基线的10个正式ASR、10个对齐、161个预览全部完成，792个对齐单元含852个归一化输出字。单一参考说话人覆盖至少80%的641字，经整场匿名最优置换诊断为637字正确、4字未知、0字错标；另209字在多说话人参考区间，2字在参考边缘。所有输出有111字未归属；该子集与置换方法不能代替speaker-time或人数质量门，近场代理的远场时钟尚未认证，ASR真实CER也未取得。

自然基线ASR物理footprint采样中位数6579785160字节、最大值7986892400字节，已是主要驻留来源。代码复核发现正式commit后有缓存释放，预览flush后没有。唯一候选在flush处理离开时以`finally`复用既有MLX闲置缓存清理，成功和失败均覆盖；保留权重、PCM、预览和decoder state，不改变模型、预算、VAD或任何配置。两个fake回归先在旧行为失败，修复后通过，验证清理时机、失败后继续预览和最终commit；整个worker文件45项测试及Ruff通过。首次未禁用全仓coverage的定向调用因覆盖率门退出，随后以`--no-cov`验证定向测试；未将覆盖率失败当作完整测试通过。

自然同源基线/候选各一次，冻结生产树仅`qwen3_worker.py`不同；模型、PCM、请求、映射和15分钟上限摘要均相同。两个arm的原始配置摘要因源码根不同而异，cold重建精确复现各自登记摘要，仅统一冻结源码根后完整配置及字段摘要一致。正式正文、多重集、有序对齐全部字段及原生活动更新/概率完全相同；最终文字归属诊断也相同。归属事件数15→17是异步交付轨迹差异，没有包装成识别变化。

250ms进程树物理footprint观察最大和10510590760→7604625688字节（下降27.65%），ASR采样中位数6579785160→2822917336字节（下降57.10%）。采样无缺tick，不是原子峰值或跨硬件预算。服务观察的预览水位延迟中位数185.64→197.43ms，P95为233.44→239.88ms；段关闭至ASR正式文字中位数565.66→539.90ms，对齐完成距正式文字中位数51.67→58.06ms。这些单次值不是UI/人工词时间或稳定速度认证，明确保留小幅延迟取舍，不宣称提速。


同一候选在已有001近场123.41秒App默认会议预设扩样，复用上述冻结基线，另跑候选一次。10个正式ASR、10个对齐、108个预览均完成；全部预览长度/修订/水位、正式正文、对齐与原生活动逐项相同，派生CER仍35/515。进程树采样最大和10209747584→7573774712字节（下降25.82%），ASR采样中位数5425188188→2815175992字节（下降48.11%）。预览水位延迟中位数171.58→181.39ms、P95为230.65→242.68ms；段关闭至正式文字370.41→358.68ms，对齐45.87→45.74ms。模型/请求/PCM一致，cold配置重建复核相同；这不是ABBA或长时认证，但两个来源支持保留显著资源收益的小改动，停止本轮缓存变体搜索。

自然两次、近场两次维护均先确认无活动请求/客户端，再经managed CLI停启并恢复；四次输入全部消费，三个owned子进程均wait回收，关闭后冻结字节复核通过。最终独立使用安装态解释器隔离导入复核health/readyz/metrics均200、active requests均0，唯一listener及LaunchAgent为PID93045，3.12.0、quality/quality，配置/selection/runtime target摘要未变。生产源码与实际冻结候选逐字相同。候选未安装，无新下载、profile/selection更改或留出访问。仓库外`asr-natural-meeting-joint-20261018`与`asr-meeting-default-preset-20261018`保存冻结、比较、参考代理与恢复证明，Git仅保存脱敏结果。

保留flush后的缓存释放及两项fake回归；回退可revert该逻辑提交，无用户数据或持久化格式变化。运行代码不含本机内存/速度门槛，CI不增加真实语料任务。上一提交`550b43b0`八项GitHub CI已全部通过，本提交CI另行核验。没有新ASR或分人准确性提升声明，独立主参考、关键事实人工复核、自然多人认证与完整峰值门仍未完成，`certified_max_speakers=null`，PR继续draft。


2026-10-19证据复核更正：上述自然/近场预览事件经driver的`strip`只保留文字长度；比较证明长度、修订与样本水位相同，不能证明预览正文逐字相同。正式ASR正文由独立仓库外制品完整保留，其逐字比较，以及对齐与原生活动一致结论不变。此前预览正文一致表述撤回，不据此作预览内容不退化认证。


## 短停顿切段候选的真实诊断

2026-10-19：当前001默认会议路径的35次字符编辑中，按一种最优文本对齐归到首尾5字内的有11次，另24次在段内；此归属不是声学错误时间，存在7个对齐平局。一个1.248秒尾段有两个插入字，但原近场句级区间覆盖前288ms，不能直接当成纯静音幻觉。用同一已登记Silero/PCM连续逐512样本推理，尾段39帧中10帧仍超过已有0.35退出阈值，9帧超过0.5起始阈值，最高概率0.999996；撤销删除尾段的假设，未过滤输出文字或删音频。

固定`a0b5981a`、当前App静态默认会议请求、Qwen/aligner/C0及同一123.41秒输入，只在仓库外冻结源码中试一个短停顿切段原型：当预算大于两倍原静音窗口、已进入预算末尾一个原静音窗口、且低于退出阈值的帧数达到原起始debounce帧数时，提前发出已有budget_rollover。保留VAD整轮结束判定，不改阈值、模型、请求或参考，不向生产文件引入该策略；原型借用私有状态字段只作抛弃式诊断，不作为可合并实现。

复用上一轮已完成的同源`a0b5981a`基线，仅补跑候选一次。10个正式ASR、10个对齐均完成，两个切点分别提前576ms和608ms，接纳音频区间并集完全相同，无漏样或裁剪。正文517→516个归一化字，但错误35→35/515，CER均6.7961%；一种最优对齐中32项相同、各3项独有，不是3项净改正。文字归属诊断的错标仍0、未知仍8，参考可评估分母515→514，不能把不同分母包装为改善。原生活动及概率全部相同。

采样最大物理footprint和7573774712→8154358160字节（增加7.67%）；服务观察的预览水位延迟中位数181.39→192.93ms、P95为242.68→359.74ms，段关闭至正式文字中位数358.68→372.71ms。每arm一次，不认证峰值或稳定时延退化，但已无准确性收益且无资源优势，拒绝该原型，不扩样或搜索停顿阈值。模型/PCM/请求摘要相同，cold重建复现两次登记配置摘要，仅统一源码根后全字段相同。继承driver中的旧缓存假设文字由独立登记更正，身份以冻结源码和本次登记为准。

该维护窗口先确认无活动请求及客户端，全部2961840个wire样本消费，三个owned子进程wait回收、关闭后冻结字节复核通过；managed恢复后唯一listener及LaunchAgent为PID95274，health/readyz200，3.12.0、quality/quality，配置/selection/runtime摘要未变。没有新下载、安装、profile变更或留出访问。仓库外`asr-pause-rollover-20261019`保留登记、原型、完整比较和恢复证据；工作树生产实现仍为`a0b5981a`，本次只提交证据与前述预览声明更正。真实质量认证未完成，PR继续draft。

`a0b5981a`首次完整Python CI为5423通过、1跳过、1失败；唯一失败是既有DMG测试的`hdiutil attach`报Resource temporarily unavailable，其他已选择的构建/Swift/质量门成功。保留失败日志，只重跑该workflow的失败任务一次，未放宽测试或自动宣称基础设施问题已排除；重跑结果以远端实际状态为准。

2026-10-19重跑完成：同一`a0b5981a`、workflow 39143213182 attempt 2成功，Python完整测试5424通过、1跳过，wheel及Gate Summary全部成功；独立候选构建/fake workflow也已成功。未修改生产或测试、未放宽DMG断言，首次失败记录保留。


## 发布阶段测试等待的机器无关修复

2026-10-19：`48f7cdc6`远端Python、App构建和独立候选fake门通过，Swift package任务在`testAutoPublicationRetriesResumeFailedStepWithoutHumanReview`失败：预期published，实际仍publishing，后续已发布音色断言也失败。该提交只改文档；失败时测试等待函数仅允许200次`Task.yield()`，把调度机会数当作异步完成条件，不能跨runner速度成立。保留workflow 39144161636首次失败日志，没有把它计为质量失败或忽略。

只修改`AppModelTests.swift`的发布阶段等待器：用Observation订阅实际阶段，变更后在MainActor重新观察；到达目标时只完成一次，结束/超时关闭观察，回调弱引用避免遗留持有。10秒仅为防挂看门狗，不用于性能断言；不增加sleep、轮询次数或生产API。相关AppModel类97项测试通过，包含11项定向音色/发布测试。将阶段变更后的重新观察变为停止观察，目标测试因两个阶段均未收到完成通知而失败；恢复原实现后97项通过，说明不会在未观察到实际状态时放行。未运行UI自动化、加载真实模型或改安装/配置，完整CI以修复提交的远端状态为准。


## 现有分人模型互补性与官方原生对照准备

2026-10-19：复用已冻结的18个Train_near派生来源及C0/fast32/fast128真实活动帧，不重新加载模型。先登记全部来源、两套原有角色不变的参考及唯一诊断：对每个模型按整场最大正确speaker-time做一对一匿名映射，再取映射后活动的并集，考察现有输出是否互补。它明确使用参考答案，不是可运行候选，也没有优化跨模型联合置换；不能称任何可能组合的数学上界，更不能忽略误报后当作质量门通过。

按原句级参考，2/3/4人各6来源均没有全部说话人达到95%覆盖；各层最低逐人覆盖为66.07%/79.21%/71.00%。按辅助强制对齐活动参考，相应有6/6、5/6、4/6来源达到这个单项覆盖条件，最低逐人为99.08%/93.98%/89.67%。这些计数不含precision门，不能认证人数。全部既有输入摘要复核稳定，没有新模型实跑。该固定映射诊断仍未支持同时运行三种模型的复杂度与资源开销，不实现该组合；仓库外`diarization-model-complementarity-20261019`保存登记和逐来源诊断。

检查既有离线Community-1人数诊断发现，即便明确提供参考人数4，148秒006的辅助最低逐人recall仍37.58%，此前已停止该分支；本次没有重跑、重新调人数或把参考人数用于生产。

核验日期为2026-10-19：[NVIDIA官方模型卡](https://huggingface.co/nvidia/Nemotron-3-Diarization)及[官方原生CLI](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/v0.2.0/docs/cli.md)提供独立分人入口，并支持短音频full-attention模式。准备一个同文件流式/整段对照，以区分短上下文损失与现有模型/转换路径的限制，ASR继续固定Qwen。官方v0.2.0发布目录固定绑定`nvidia/Nemotron-3-Diarization` revision `f667ed73aee57d40cc39428eb768b4fd87a0a29e`的`Nemotron-3-Diarization.q8_0.gguf`，107012128字节，SHA-256为`08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1`，许可OpenMDW-1.1。它与现有CoreML属于同系列，但不预先假定checkpoint、量化或数值等价；GGUF两arm共用同一文件，对CoreML的差异只能作跨格式/运行时诊断。

已将官方macOS arm64 Metal运行时压缩包（5031510字节）放在仓库外，按发布方SHA-256校验并解包；`diarize --help`实际执行成功，确认`--model`本地路径、`--offline`及JSON/RTTM输出可用，没有系统安装或模型推理。未在本次检查的模型缓存与项目模型目录找到目标GGUF。本机未发现可直接调用的CMake/Ninja，采用官方已校验运行时避免先建设新编译环境；不改仓库依赖。

具体提案为仅下载该固定GGUF到仓库外，先对现有006的148秒输入跑同GGUF发布方流式预设与full-attention两arm，每arm15分钟上限，不向模型提供参考或人数，不调阈值；使用既有managed维护与owned进程清理、结束恢复服务。模型下载正在独立确认，现有C1/C2许可不扩用；没有下载新权重或提前实跑。仓库外`nemo-native-diarization-review-20261019`保留官方目录、软件校验及提案。产品质量、自然多人认证与正式ASR主参考仍未完成，PR继续draft。


## 官方原生分人流式与整段对照

2026-10-19：用户在明确下载提案后授权全权推进。下载上述固定 NVIDIA GGUF，107012128字节及SHA-256均与官方目录一致，保存在仓库外；未修改Qwen、安装、profile或selection。仅使用既有006的148秒/2368000样本WAV，两arm共用同一模型文件、Metal设备及`v3-streaming`预设，第二arm只增加`--offline`。官方CLI说明明确指出`v3-offline`预设只改变流式块与缓存，不等同full attention，因此没有同时换预设。未给模型参考、人数或阈值，不搜索参数。

对完整输出区间按全部边界精确积分，同一说话人先取区间并集，再以整场一对一最大正确speaker-time置换；precision分母包含未匹配槽位。沿用原句级参考和辅助强制对齐参考的既有角色，不将它们提升为自然场景认证。C0来自相同PCM的已冻结完整活动帧，与新GGUF属于跨格式/运行时诊断，不假定权重数值相同。

| 参考 | 模型/模式 | speaker-time recall | precision | 最低逐人recall |
|---|---|---:|---:|---:|
| 原句级 | 生产C0既有帧 | 82.70% | 88.99% | 63.21% |
| 原句级 | 新GGUF流式 | 87.41% | 88.51% | 62.21% |
| 原句级 | 同GGUF整段attention | 78.83% | 82.45% | 67.54% |
| 辅助强制对齐 | 生产C0既有帧 | 93.00% | 84.17% | 80.17% |
| 辅助强制对齐 | 新GGUF流式 | 92.57% | 78.84% | 72.61% |
| 辅助强制对齐 | 同GGUF整段attention | 81.10% | 71.34% | 67.81% |

两个模式均输出4个匿名标签，均未同时通过既定门。整段attention在两套参考下均无净收益；新流式在原句级参考下提高整体覆盖，但降低precision与最低逐人覆盖，辅助参考下也没有优势。拒绝替换生产或继续该分支阈值搜索。流式最后一个区间超出148秒输入10ms，评分未悄悄裁掉，超出时间计入误报。两arm新进程各一次、无预热，进程wall time为15.305秒和0.354秒，含加载/文件处理，不作为实时交付、稳定性能或峰值物理内存认证。

managed窗口先确认无请求/客户端，再停服；两个原生子进程终态均为0并wait回收，模型、运行二进制和输入/参考摘要前后稳定。原服务恢复唯一listener/LaunchAgent PID48617、health/readyz200、3.12.0、quality/quality，配置/selection/runtime target摘要未变。仓库外`nemo-native-diarization-review-20261019`保存授权、下载校验、登记、原始输出、精确积分对照及维护记录。无留出访问，PR保持draft，人数认证不变。


## 批量转写的不完整解码拒绝

2026-10-19：沿真实006片段的已知`repetition`失败复核生产入口，发现`Qwen3Engine.finish_streaming(full_segment)`检查完整EOS，但`Qwen3Engine.transcribe`直接提取vendor正文；经`_handle_transcribe`和`Qwen3Worker._transcribe_once`会把异常停止的正文交付为批量成功。此前“四人开发片段的不完整复核恢复”中的“batch完整段仍保留原严格完整性检查”表述不准确：当时实装检查的是Realtime的full_segment定稿，不能覆盖文件批量入口。本次明确更正并补齐该入口，不用历史文字代替代码证据。

生产改动仅在batch vendor返回后复用既有`_require_complete_final`。token上限截断、repetition、mixed、缺少终止原因以及EOS同时声明truncated均拒绝；正常EOS继续提取原正文和时间信息。错误复用既有worker推理错误路径，保留request ID、不发布部分成功，也不把语义错误当作传输丢失自动重试。没有增加模型调用、预算、开关或公共字段；OpenAPI描述及用户手册同步说明完整性边界。拒绝异常解码不等于识别准确率提升。

5个参数化反例在旧实现均因未抛错而失败；另一个真实worker帧边界的fake用例验证不完整请求只返回错误、同engine的下一正常请求仍返回成功。移除新增检查后6个用例全部失败，随后逐字恢复实现。相关worker、backend、长音频、音频错误及OpenAPI定向回归、Ruff、OpenAPI和用户文档契约检查通过；测试均不加载模型或真实语料，不依赖本机速度。

真实对照只使用此前已正确解码的006 PCM和两个既定24秒上下文区间，另以各自20秒owned区间作完整EOS控制。冻结改动前后worker文件，两arm共用一份实际加载Qwen Q8、语言Chinese、空context和同一动态预算，每段按基线→候选各重新推理一次。两个24秒区间都复现`repetition`、`truncated=false`；基线分别将136/20字vendor正文返回为成功，候选均拒绝，未交付正文。两个20秒EOS控制均成功，127/137字正文摘要前后相同；8次调用全部完成，实际运行候选与工作树逐字一致。这是batch engine及worker帧边界的证据，不是安装态公共HTTP端到端认证、整片CER改善或人工复核。

首次维护在模型加载前因vendor Python不具备host预检模块依赖而失败；将预检移回host后，第二次又被历史inventory摘要不匹配拒绝。两次均恢复服务且保留失败记录，没有复用旧摘要或把失败记作有效arm。历史inventory含当前host依赖，不能继续假定与旧诊断身份一致；重新登记当前依赖及生产源码，比较两份冻结worker在这个相同新环境中的行为，推理前后完整inventory复核稳定，不拿历史推理当作本次基线。第三次完整运行成功；模型、PCM和设置摘要核验通过。

三个窗口均先排除活动请求/客户端，再managed停启并恢复；最后唯一listener/LaunchAgent PID49965、health/readyz200、3.12.0、quality/quality，配置/selection/runtime target摘要未变。真实推理子进程由900秒deadline约束并wait回收；没有新ASR模型、安装或profile更改、留出访问。本轮未测峰值物理内存和稳定性能，不据单次亚秒wall time声明提速。仓库外`asr-batch-completeness-20261019`保存冻结、新身份登记、两次无效尝试、8次真实对照及服务恢复证明。回退可revert本逻辑提交，无用户数据或持久化格式变化；完整质量目标仍未达到，PR继续draft。


## 当前会议参数下的窗口模式对照

2026-10-19：固定`ba2a76f4`生产源码、Qwen/C0/aligner和既有001的123.41秒输入，重新跑标准会议与既有opt-in会议窗口模式各一次。共用900ms静音、相同PCM及1×供给；窗口模式按公共契约替代`asr`配置，固定20秒owned、2秒左上下文、2秒review grace、1500ms预览，标准模式为1000ms预览。因此比较的是两个完整模式，不能把差异只归因于上下文。App显式实验开关和服务默认值没有修改。

两arm全部2961840个24k wire样本消费，均10个正式ASR和10个对齐、0失败、分人终态1次；窗口模式另有82个sealed事务及73个updated快照。两个派生诊断均35/515错误、6.7961%，正文和owned区间并非逐项相同，不以相同错误数宣称文字不变。完整原生活动与概率逐项相同。没有准确性净收益，不启用默认或搜索该模式参数；此前不同400ms静音等条件下的30/515不能移作当前会议默认收益。

250ms物理footprint观察最大和为7685185888→10297172464字节，ASR采样中位数2814790896→5350280384字节。基线有1次读取缺样，候选0次；不将该不完整资源对照声明为峰值门通过或精确资源回归百分比。源码复核发现窗口decode只在window.close清理闲置缓存，普通flush已有请求后清理；这为现有opt-in路径的缓存改进提供定位依据，不支持启用模式的质量结论。

首次窗口候选因私有driver访问错误的请求嵌套层级，在模型加载和供给前KeyError退出；保留成功基线及失败记录，修正后先离线核对互斥请求，再只补跑候选。两个维护窗口均managed停启并恢复；最后唯一listener/LaunchAgent PID52970、health/readyz200、3.12.0、quality/quality，配置/selection/runtime摘要未变。三个真实worker均wait回收、关闭后冻结内容稳定，两arm生产Python字节相同。仓库外`asr-meeting-window-mode-joint-20261019`保留登记、完整结果、比较、缺样与恢复记录。未安装、改变默认、下载新模型或访问留出，仍非正式质量认证。


## 提词器生命周期测试的异步等待修复

2026-10-19：`ba2a76f4`远端Python、质量、App构建、独立候选fake及wheel门成功，但Swift package任务失败。原日志确认唯一失败用例为`oneReadingRunKeepsPositionHonestAcrossEveryScenario`：掉线后释放占用和回到manual的两次等待各耗尽200次`Task.yield()`，随后的phase仍为uncertain。保留workflow 39171796423的失败记录；同一用例本机单跑通过，不能因此忽略CI失败，也不能把200次调度机会视为跨runner的等待时长。

只修改该测试文件的私有`waitFor`：继续等待实际异步条件，使用ContinuousClock的10秒截止作防挂看门狗；1ms间隔仅限制轮询工作量，不作为状态成立或性能断言。保留超时Issue.record，取消也显式记录失败。条件可跨actor读取，未增加生产API、放松断言或改变提词器行为。84项该类测试通过，完整本机Swift package通过（XCTest 1757项、1项既有跳过、0失败；Swift Testing 658项、0失败）。临时加入始终false的状态条件，短看门狗必须以等待超时失败；验证后源码逐字恢复，没有保留预期失败用例或静默放行。未接管UI、采集屏幕或加载模型。


## 窗口解码请求后的闲置缓存释放

2026-10-19：针对上一对照定位的opt-in路径ASR驻留，仅修改Qwen worker的window.decode/window.close分支：处理函数离开时用finally复用既有闲置缓存清理。保留权重、活跃decoder state与PCM，不卸载模型、不改变模式默认、配置或预算。两个fake反例在旧实现失败，修复后覆盖成功预览状态保留、失败请求清理及随后正常window.close确认；worker、window和backend相关定向回归及Ruff通过。

复用上一轮已完整完成、0缺样的窗口arm作基线，固定同一001的123.41秒输入、Qwen/aligner/C0和请求，仅补跑缓存候选一次。两个冻结生产Python树仅qwen3_worker.py不同。原始配置摘要因独立源码根不同；cold无模型重建精确复现各自登记摘要，仅统一源码根后完整配置摘要及每个字段相同。两arm均完整输入、10个正式ASR、10个对齐、82个sealed事务、73个updated快照、0失败；按拥有区间排序的正式正文和区间完全一致，派生错误仍35/515。封存正文、owned span、review scope和state一致；对齐比较只剔除跨会话随机segment_uid，其余全部字段一致。原生活动、概率与slot逐项相同。预览事件只保存文字长度，不声明预览正文逐字一致。

250ms物理footprint采样无缺tick，进程树观察最大和10297172464→8072208736字节（下降21.61%），ASR采样中位数5350280384→2815413392字节（下降47.38%）。采样为顺序读取，不是原子物理峰值或跨硬件预算认证。非空sealed事务的源采样封存边界至服务发出延迟中位数2.45540→2.46863秒（增加13.22ms）、片内P95 3.26401→3.22950秒；非空snapshot音频区间末尾至发出中位数50.24→57.33ms、P95 97.46→93.39ms。这些只是私有1×供给时钟的服务观察，不是人工词时间或UI延迟，每arm一次、不作稳定提速结论。

保留低复杂度的窗口闲置缓存释放；资源收益不构成窗口模式准确性收益，App及服务默认仍不变。该维护确认无客户端和请求后managed停启，三个worker均wait回收、关闭后冻结字节稳定；独立使用安装态解释器-I复核health/readyz/metrics200、active requests均0、唯一listener/LaunchAgent PID54602，3.12.0、quality/quality，配置/selection/runtime target未变。源码逐字匹配实际候选。仓库外`asr-window-cache-20261019`保存冻结登记、配置证明、全部比较和独立恢复结果；无下载、安装、留出访问。回退可revert本逻辑提交，无用户数据或持久化格式变化，正式质量目标仍未完成。

## 自然会议起始边界诊断（2026-10-19）

用户授权继续完成任务后，从既定 AliMeeting 官方 Train_far 对象补取压缩前缀，按固定 ETag 校验 HTTP Range，取得三个不同来源组的完整自然阵列录音；新增下载 640 MiB，累计使用 1152 MiB 压缩前缀。三份 WAV 均完整读取 PCM 并登记容器与 PCM 摘要，合计 6149.706 秒，各关联四份已有 Train_near 标注。第三份首次解压得到的不足长文件保留为 `.partial`，未作为完整录音或模型输入。未下载整个训练包、未核验完整 archive 校验和，不把 ETag 和本地成员摘要等同于发布方完整制品认证；没有访问 Eval/Test 或 AISHELL-4 留出。

首份录音按识别前固定的非重叠长语句规则选出三段，共 35.11 秒、126 个归一化参考字符，均属同一匿名说话人。固定 Qwen Q8、Chinese、空 context，串行运行耳麦与自然远场各三次完整片段识别：两种输入均累计 8 个字符错误，其中两段正文逐字相同。这是官方耳麦标注相对于关联远场的诊断代理，未经过关键事实人工复核，不能充当独立来源统计、自然四人认证或主参考认证。两处粗时钟探针的最佳偏移为 −30/−20 毫秒；较晚探针的相关性仅 0.421，不推广为整场逐字时钟已认证。

历史会议路径首段接纳起点为 9.536 秒，官方首句标注起点为 8.34 秒。先保持 18.592 秒结束点，只将离线片段起点从 9.536 秒前移至 8.352 秒，直接 batch 的错误从一次删除变为零。该 batch 显式使用 Chinese，会议路径使用默认 auto，两者不是可直接合并的对照；batch 基线正文也不同于历史会议正文，不将此结果表述为实时错误从 3 个降至 0 个。

随后冻结同一生产源码 `38e6d840c8e04d8c0b33d07a8cb2f0359ca2c31d`，以当前真实会议组合重放同一自然录音前 40 秒，唯一请求差异为 prefix_padding_ms=300/1500。两臂源码镜像字节、三类模型摘要及其余请求字段相同。首段起点为 9.536→8.352 秒，结束点均为 18.592 秒；37 字代理参考下，S/D/I 为 2/1/0→2/0/0，即补回一个被遗漏的字。后续两段正式正文及 owned span 完全相同，完整 native activity updates 也相同。每臂三次正式转写与三次对齐均成功；baseline 资源采样缺一次 tick，不据此计算资源净收益或声称峰值门通过。

扩样在查看新来源 ASR 输出前固定统一选择规则：按时间顺序取至少 3 秒、12 个归一化字符的首个孤立语句，前留 3 秒、后留 300 毫秒，片内不得与其他已标注语句相交。第二来源没有符合条件的语句，保留排除事实；第三来源选中 7.25 秒、21 字片段，耳麦/远场粗时钟最佳偏移 −10 毫秒、log-RMS 相关性 0.817，仍不作逐字认证。同样生产路径、同样 300/1500 毫秒请求对照均为零错误，正式正文完全一致，首段本地起点为 2.688→1.504 秒。每臂一次转写与对齐成功、无资源采样缺失。

四次联合回放均完整消费输入，全部具名子进程已等待退出，退出后文件闭包稳定；各维护窗口通过 managed CLI 恢复原服务，配置、selection 与 runtime target 摘要保持不变。最后恢复唯一 listener PID 58706，health/readyz 均为 200、3.12.0、quality/quality。没有安装新代码、修改 profile/selection、替换 Qwen 或新增生产默认项；原始音频、正文、执行控制和逐次结果仅存仓库外。

决策：1500 毫秒前置保留仅在一个已观察到边界损失的来源补回一字，另一前瞻来源无差异。结束该参数诊断，不继续搜索更长保留时长，不据此修改 App 或服务默认值。该结果不满足相对冻结 A0 的正式 CER、配对统计、人工事实复核或分人人数门；前述已交付的转写完整性和内存回收修复不因此扩大质量声明。GitHub CI 继续只跑确定性 fake 测试，不自动使用这些真实语料。

## 完整自然会议的分人损失定位

2026-10-19：按原始归档顺序使用已取得的三场完整 Train_far 开发会议，分别为 2045.881、2134.162、1969.663 秒，共 6149.706 秒。输入是原始八通道录音中未经混合的 channel 0；每场以一个连续 native session 运行当前生产 C0、默认阈值和生产 Resource Governor，逐块吞吐输入，不模拟实时到达，不加载 ASR。模型、可执行文件、源码、Python 依赖及 PCM/参考文件在加载前冻结，退出后复核稳定。关联原始耳麦 TextGrid 的匿名活动区间保持原时间、不调整偏移；它仍是远场代理参考，没有人工远场逐字或关键事实认证。

| 来源顺序 | speaker-time recall | precision | 最低逐人 recall |
|---|---:|---:|---:|
| 1 | 84.89% | 93.13% | 78.50% |
| 2 | 86.44% | 91.94% | 76.06% |
| 3 | 79.48% | 87.95% | 71.07% |

三场均未通过既定质量门。全部 native 帧按样本区间构成完整分区，没有缺口或重复；最终 processed/stable watermark 等于完整输入。开头、中段、结尾的粗音频时钟探针，最佳偏移在 −40 至 +80 毫秒之间，未对评分应用偏移，也不据此认证逐字时钟。

在完整输出出现前登记固定 300 秒分箱的诊断：比较整场一次最优参考置换与每箱独立最优置换，两者在三场的 recall 完全相同。此参考 oracle 不可部署，只说明这些数据不支持优先开发五分钟尺度的标签重映射；不推断所有短时混淆都不存在。按同一已映射说话人匹配一秒内最近边界，起止偏移中位数为 −10 至 +80 毫秒；没有发现足以解释主要损失的整体时间戳错位，未据此改边界、阈值或活动标签。

随后只在第一场完整录音运行一次既有 Community-1，沿用已校验的保留重叠输出版本和默认参数，不提供人数。它输出四个匿名标签，recall / precision / 最低逐人 recall 为 69.43% / 85.47% / 46.11%，明显低于同源 C0。结束该替换路线，不继续扩样或调参。其约 7.06 秒进程 wall time 含加载与评分，属于离线吞吐观测，不能与实时交付延迟或联合内存门混用。

两个维护窗口均确认无活动请求/客户端后通过 managed CLI 停服，所有自有子进程等待回收，之后恢复原服务；最后唯一 listener/LaunchAgent PID 为 61181，health/readyz 200、3.12.0、quality/quality，配置、selection 与 runtime target 摘要不变。仓库外 `dia-natural-full-c0-20261019` 与 `dia-natural-full-community1-20261019` 保存登记、完整活动、精确积分和维护结果；没有更换生产模型或修改安装态。

## 中文分人候选的有限可行性核查

核验日期为 2026-10-19。[sherpa-onnx 的 pyannote 实现](https://github.com/k2-fsa/sherpa-onnx/blob/master/sherpa-onnx/csrc/offline-speaker-diarization-pyannote-impl.h)的 powerset 映射最多保留两人同时讲话，不能把“全局可聚类更多人”当作更多同时发声能力。对上述原句级代理参考做精确时间积分，即使理想选择每个时刻的两人，三场总覆盖上限也只有 93.42%、90.84%、96.75%。前两场已不可能同时满足四位各 95% 覆盖；因此不下载该路径模型或投入集成。这个上限受当前参考定义约束，不是对其他参考或所有分人实现的结论。

[SOND 官方模型卡](https://www.modelscope.cn/models/iic/speech_diarization_sond-zh-cn-alimeeting-16k-n16k4-pytorch/summary)描述了中文 AliMeeting 交叠分人模型，但要求说话人注册样本，不能直接当作无注册流式替代品。核对固定模型 revision `0f30c403ef999dac1618cb7a32d59b35fb750f66` 的官方文件摘要、配置及 FunASR 历史推理源码；仅取得说明和配置，没有下载 SOND/SV 权重、安装推理依赖或运行模型。模型使用 AliMeeting 训练来源也限制了在本开发集上声称泛化收益。

用已有 C0 输出做一次固定规则的匿名注册准备检查：目标槽位概率至少 0.8、其余各不超过 0.1，连续时长严格大于官方要求的 2 秒，不使用参考、真实人数或耳麦注册音频。三场取得所有已预测槽位样本的最早时间分别为 236.64、83.92、1594.00 秒。第三场四个槽位在前 12.96 秒内均已出现，最慢槽位从首次预测活动到取得样本延迟 1582 秒，并非仅因该人很晚入场。简单方案不能支持及时的匿名实时体验，停止此集成路径，不以降低阈值或反复缩短样本来制造可运行条件；这不证明 SOND 的所有匿名注册方案不可行。首次依赖解析受纯 Python 包缺 wheel 限制，后一次命令参数不受当前 uv 支持，均未形成 Python 3.14 不兼容证据。

仓库外 `chinese-diarization-source-review-20261019` 保存官方来源、文件目录和注册准备检查。后续回到现有 ASR 生产修复的自然音频验证，不增加新的评测框架或模型组合；Qwen 与留出封存范围保持既定约束，人数认证仍未通过。

## 原始自然近讲长句的段预算验证

2026-10-19：在查看新识别结果前，按来源归档顺序固定六个不同 Train_near 会议组，每组取首个符合 25–40 秒、至少 80 个归一化字符的自身耳麦长轮次，相邻语句间隔不超过 900 毫秒。各保留前后 300 毫秒原音频，共 173.78 秒、795 个参考字符，没有混合声轨。参考为官方佩戴者 TextGrid，独立于候选识别；原耳麦中的其他人串音仍是干扰及参考语义限制，不把这些片段当作远场或自然四人认证。

两臂共用 `7f0403c22eb88ad775104d7b1affb5747a0be285` 的冻结生产源码、Qwen、对齐及 C0 分人模型，使用相同默认会议请求和 1× 输入。baseline 仅恢复两个文件中原有的三个 8 秒限制表达式，candidate 使用当前遵守 20 秒请求的实现；这是隔离该修复的反事实对照，不是原冻结 A0。两臂冷重建配置与各自登记摘要一致，除源码根目录及其对应环境摘要外配置相同，模型与请求字段一致。

| 来源顺序 | 参考字符 | 8 秒限制错误 | 遵守 20 秒请求错误 |
|---|---:|---:|---:|
| 1 | 159 | 8 | 7 |
| 2 | 118 | 2 | 5 |
| 3 | 98 | 13 | 14 |
| 4 | 130 | 7 | 4 |
| 5 | 163 | 9 | 7 |
| 6 | 127 | 15 | 16 |
| 合计 | 795 | 54 | 53 |

总 CER 为 6.7925%→6.6667%，相对下降仅 1.85%，三个来源改善、三个退化。沿既有来源会议配对方法，固定 seed 1717、10000 次重采样、双侧 95% 区间；每来源一次 CER 的 candidate-minus-baseline 均值为 +0.0311 个百分点，区间为 [−1.2323，+1.3680] 个百分点，跨过零。统计规则在查看字符错误前登记，但属于开发探索，不是正式预注册 A0 验收；没有人工关键事实复核。

正式段数 26→13，39 次正式转写与相应对齐均成功；十二次联合回放全部消费输入、三个自有 worker 均 wait 回收、退出后冻结字节稳定，六个来源的完整 native activity updates 逐字相同。baseline 第六来源缺一个资源采样 tick，不作完整资源门或峰值声明。较长段也有可观测等待代价：各来源相对 owned span 起点的正式回调延迟中位数，从 8.32–8.35 秒变为 10.77–17.65 秒；这是本地输入日程到正式回调的区间指标，不是人工词时钟或 App 显示延迟。

维护后恢复唯一 listener/LaunchAgent PID 65458，health/readyz 200、3.12.0、quality/quality，配置、selection 与 runtime target 摘要不变。仓库外 `asr-natural-headset-budget-20261019` 保留预选、来源校验、两臂配置复核、逐次执行和完整评分；没有下载、安装或留出访问。

决策：保留“遵守显式请求预算”的行为修正，不将此前派生混音的 10.38% 改善推广为自然音频收益；这组六来源结果未支持普遍准确性提升，也未证明 20 秒是最佳默认值。停止沿段长继续搜索，不基于该组小样本新增默认参数或复杂策略。正式 ASR、分人质量门及人数认证仍未完成。

## 连续提交后的重采样保真修复

2026-10-19：生产 `RationalResampler` 清理输入缓冲时，将已消耗游标直接设为下一目标取样位置。降采样的相位可能越过当前实际收到的输入，特别是在 client commit 补齐分数尾样本后；旧实现因此提前消耗尚未收到的位置，随后把新输入放到错误索引。24→16 kHz 最小复现：先提交 `[0,100]`，再提交 `[200,300,400,500]`，第二段应为 `[300,450]`，实际为 `[200,350,500]`；6 个源样本产生了 5 个目标样本，正确总数为 4。48→16 kHz 的任意分包也可触发同一根因。

修复只让游标按实际移除的样本数递增，并将移除数量限制在已收到的缓冲长度内；不改变插值、尾部保持、模型、VAD、时间轴比例或公共字段。全局相位跨提交连续保留。一个已提交分数尾之后的极短新 wire 包可能合法地产生零个目标样本，此时沿既有空终态路径返回空 `completed`，不调用 ASR 或创建虚假边界；两次完成屏障仍准确报告全部 wire 样本。同步明确 Realtime 契约与用户 API 手册中的该行为。

先写最小波形、重复提交和跨层反例，再实施修复。恢复旧清理函数的独立进程内 mutation 中，后续取样、24/48 kHz 重复提交总量、48 kHz 分包一致性和实际 ASR owner 收到的 PCM 五项失败；24 kHz 原连续分包控制仍通过。修复后的定向 247 项回归、全体 Realtime 及音频相关 386 项回归通过，Ruff、该源文件 strict Mypy、用户文档契约检查通过。所有测试均使用确定性合成输入和 fake backend，没有真实模型或本机速度阈值；五秒等待仅为跨层异步终态防挂。

另以先前已选的原始自然近讲第一个来源作仓库外 PCM 对照：该 16 kHz 原音频先经既有 inverse embedding 形成版本绑定的派生 24 kHz wire，再以固定 24002 个 wire 样本一段作 30 次提交。它不是原生 24 kHz 采集认证。独立参考直接按全局 3:2 取样位置和各提交末尾保持规则计算；旧实现输出 473940 个样本，额外 20 个，共同前缀中 455290 个样本与参考不同。修复后输出恰好 473920 个样本，与参考逐样本一致；两臂无中间提交的连续输入都与原始 16 kHz PCM 字节相同。输入与候选源码摘要前后稳定，控制及结果保存在仓库外 `asr-resampler-commit-fidelity-20261019`。

这是可重复的输入保真与时长修复，不把取样差异统计当作 CER、听感、分人质量或性能提升；该对照未加载模型，不作新的质量门或峰值声明。本次未停服、安装或修改配置，也未访问留出。原有人工事实复核、自然分人门及最终联合身份仍未完成；代码可通过该逻辑提交 revert 回退。

## 目标校准与完整会议参考对照

2026-10-19：用户将项目目标校准为固定 Qwen、分别证明自然会议的转录内容与匿名归属净收益；相对 A0 的 CER 改善 10% 和主要逐人覆盖 95% 保留为挑战目标，不再作为所有生产修复的统一交付前提。先验证自然连续 1–4 人，5–8 人单独扩展；正式验收前仍须冻结基线、参考、评分和非劣界限，并保留关键事实与弱说话人复核。既有 policy、旧 gate 和原结果暂不改写，不把其旧 pass/fail 当作新目标的完成判据。

行业主指标是包含重叠的 DER 及漏检、误检、混淆分量，JER 补充逐人均衡；中文会议 [M2MeT 2.0](https://arxiv.org/html/2309.13573)采用 cpCER 衡量文字及归属。[ASRU 2025 研究](https://arxiv.org/html/2507.09226v2)显示原句级标签与紧致活动标签在 AliMeeting Test 上仅因口径差异即产生 14.36% DER；边界 collar 不能消除句内停顿问题。[Nemotron 3 官方协议](https://huggingface.co/nvidia/Nemotron-3-Diarization#performance-evaluation)因此使用强制对齐标签，明确不同参考不可直接比较。不能继续把句级代理下的全部活动漏检解释为真实漏语音。

沿用已保存的三场完整原始 Train_far channel 0 C0 输出，不重新推理、不移动参考时间、不筛选输出。固定标签仓库 revision `9527b7c64846fb38316a610f32e9d3466bd6d8b7`，只取得三个来源一一匹配的 Train_Ali_far RTTM；按来源名摘要匹配，校验 Git blob、长度及 SHA-256，排除 Eval/Test。所有原活动、原评分和 policy 字节保留，辅助标签无越过音频终点记录。

| 完整来源 | 原句级 recall / precision | 紧致参考 recall / precision | 原 / 紧致参考最低逐人 recall | 原 / 紧致参考 DER |
|---|---|---|---|---|
| 1 | 84.89% / 93.13% | 94.67% / 87.81% | 78.50% / 91.25% | 19.99% / 16.83% |
| 2 | 86.44% / 91.94% | 93.75% / 86.24% | 76.06% / 84.85% | 19.44% / 19.30% |
| 3 | 79.48% / 87.95% | 92.68% / 82.58% | 71.07% / 81.86% | 29.41% / 25.02% |

这不是产品改善：同一输出的 recall 上升而 precision 下降，表明原代理既放大部分漏检，也遮蔽部分误检。紧致参考下三场漏检分别为 87.46、125.66、97.04 speaker-seconds，误检分别为 273.25、377.24、314.27；优先级应由先前的普遍补活动转为核查多报活动及逐人损失。标签尚未经人工音频复核，不升级为无误差主参考或认证依据。仓库外 `dia-natural-reference-calibration-20261019` 保留登记、校验和全部分量；正式门及独立自然来源的收益仍未完成。

## 固定 Qwen 的有限声源分离对照

2026-10-19：只测试 PCM 声源分离，不替换 Qwen ASR。候选为 `starkdmi/MossFormer2_SS_2SPK_16K_MLX`，固定 revision `3d404393efb7e60ccefa8822db0a943e5830b55d` 的 FP32 权重，223095144 bytes，SHA-256 `7a7aaeb0e482786f8f1eed33bb76bd1e2eb0dbfe554637c1bec00f6be1affb7c`；MLX 源码固定 `starkdmi/mossformer_ss_mlx` commit `bb4e03e748660c0402c4af4560be1f8937622471`。1075 项参数的 key/shape 全部匹配并严格加载，但不声称与官方 PyTorch 数值等价。它与此前停止的 OpenMOSS 联合转写模型不同。

在模型输出前，按固定规则选择第一场自然会议的一个 13.58 秒重叠片段及一个 10.01 秒单人控制，参考用于选片与评分，未提供给分离模型或 Qwen。两次分离、六次固定 Qwen 转写全部完成，计入两路全部输出，不用参考挑选较好声道。字符 ORC 错误为重叠片段 7/86→74/86、单人控制 1/37→2/37；分离后重叠片段有 67 个插入。输出有限且时长一致，但存在饱和裁剪，未调增益、门限或窗口补救。停止该固定 MLX 候选，不集成生产，也不推广为所有源分离方法不可行。

维护结束后原服务恢复为 3.12.0、quality/quality，唯一 listener/LaunchAgent PID 72435；独立 health、readyz、metrics 均为 200、活动请求为零，配置、selection 和 runtime target 摘要不变。仓库外 `overlap-separation-feasibility-20261019` 保存全部私有制品；没有安装、配置切换或留出访问。

## 紧致参考下的完整 fast32 对照

2026-10-19：参考校准改变了损失解释，因此重新评估此前未满足旧逐人门的既有 fast32，而非恢复阈值搜索。固定全部三个完整自然来源、既有权重、默认 fast32 preset 和严格大于 0.5 的活动判定；不使用真实人数、参考或热词作为模型输入。每场独立连续 session、单 epoch、16000-sample 分包、900 秒上限，按离线吞吐回放。原 C0 输出完整保留；两者使用完全相同的匹配 Train_far 紧致参考、评分 policy 和零时间平移。

| 来源 | C0 / fast32 DER | C0 / fast32 JER | C0 / fast32 precision | C0 / fast32 recall | C0 / fast32 最低逐人 recall |
|---|---|---|---|---|---|
| 1 | 16.83% / 10.25% | 17.71% / 11.56% | 87.81% / 95.07% | 94.67% / 93.83% | 91.25% / 90.32% |
| 2 | 19.30% / 10.78% | 19.90% / 12.46% | 86.24% / 94.64% | 93.75% / 93.47% | 84.85% / 84.24% |
| 3 | 25.02% / 13.30% | 24.91% / 16.07% | 82.58% / 93.38% | 92.68% / 92.36% | 81.86% / 78.89% |

三场 DER 均改善，但 coverage 略降，第三场两位说话人的 recall 分别下降 2.88、2.97 个百分点。等来源 DER 差值均值为 −8.94 个百分点；seed 1717、10000 次来源配对 bootstrap 的探索区间为 [−11.72，−6.58] 个百分点。仅三个已看过部分片段的 Train 来源，且模型训练使用过 AliMeeting Train；此区间不能充当独立泛化认证，也未预先冻结可接受的逐人退化界限。暂不切换生产默认，下一步核查弱说话人的具体损失和紧致参考争议区间。

三场全部 native 帧恰好分区全部输入、processed/stable 到达样本终点，runtime preflight 已观察、自有 child wait 回收、模型/输入/源码摘要前后稳定。独立重新评分逐字段一致；没有运行 Qwen，不宣称 ASR/cpCER 改善，也没有联合延迟或物理峰值证据。维护后恢复原服务，唯一 listener/LaunchAgent PID 75884，health/readyz 200，配置、selection 和 runtime target 摘要不变。仓库外 `dia-natural-full-fast32-20261019` 保存所有登记、完整输出和配对分量。

## 原生分数辅助固定文字归属

2026-10-19：先定位 fast32 的弱说话人损失，再只测试一个固定因果迟滞方案（0.5 onset、0.25 offset，无补帧或网格搜索）。三场 DER 分别由 10.25/10.78/13.30% 变为 10.39/12.49/14.47%，均恶化；停止该方案，不扩样或集成。

随后发现生产归属只使用二值活动并集覆盖：两人覆盖相同文字区间时，即使原生独立分数明显不同，也仍为 unknown。固定已有 Qwen 正文及真实对齐，只在原规则输出 `insufficient_evidence`、至少两人满足原活动支持下限时，使用原生分数的时长加权支持；分母为整个文字区间，仅累计对应 active 帧，分数不跨人归一化。仍使用既有 0.60 支持下限和 0.10 领先差距；不推翻覆盖判定已经明确的标签，不覆盖降级原因，不修订 final。缺分数、重复或相互重叠的帧不进入辅助判定。生产模型及 Qwen 不变，没有新增公共参数或下载。

首场仅用于探索；在另外两场 Qwen 输出前登记同一规则和接受界限：每来源 cpCER 不恶化、合并严格改善、每参考说话人至多增加 2 个字符错误、已有明确标签零改动。输入固定为剩余两个自然来源的前 180 秒，评分按同一规则截到最后完整的参考连通段；三场实际评分窗口分别为 179.25、101.05、174.20 秒，均无跨评分终点的假设字符。第二场较短窗口不能当作完整 180 秒质量覆盖。

使用独立官方佩戴者文字参考及实际模型对齐，原生 16 kHz 帧精确映射到 24 kHz wire；没有向模型提供参考、真实人数或热词。首场重建的 792 个单元与归档生产二值结果的时间、字符数量、标签逐项一致。早期一次混用 16/24 kHz 坐标的私有结果已标记无效；长多说话人精确 ORC 进程退出 138 的失败制品保留，没有无限重试或选择成功子集。

| 自然来源 | 参考字符 | 原 C0 / 辅助归属 cpCER | 原 / 辅助 unknown 字符 | 逐人错误变化 |
|---|---|---|---|---|
| 1（探索） | 964 | 372/964（38.59%） / 275/964（28.53%） | 111 / 42 | −42、−27、−15、0 |
| 2（前瞻） | 676 | 465/676（68.79%） / 395/676（58.43%） | 167 / 70 | −13、−59、−3、−6 |
| 3（前瞻） | 705 | 411/705（58.30%） / 334/705（47.38%） | 107 / 54 | −30、−35、−6、−1 |

同一来源两臂的正文和时间完全相同，合并 cpCER 为 53.22%→42.81%；所有已有明确标签零变化，12 个逐人结果中 11 个改善、1 个持平。等来源差值均值为 −10.45 个百分点，seed 1717、10000 次来源配对 bootstrap 探索区间为 [−10.92，−10.06] 个百分点；只有三个 Train 来源且含模型训练来源重叠，不作为泛化或正式认证。cpCER 将 unknown 作为显式假设流参与最优排列，额外假设流的插入不计入逐参考说话人错误之和，因此 unknown 数量、逐人分量和总分同时保留。

两场真实回放均完成 ASR、对齐和分人并回收三个 worker；维护后唯一 listener/LaunchAgent PID 80314，health/readyz 200，配置、selection、runtime target 不变。生产实现对三场 1679 个单元的输出与固定候选逐条相同。新增回归先观察到三个预期失败，再通过修复；删除重复/重叠证据保护的内存内 mutation 被两项测试捕获，不改写仓库源码。相关领域、Realtime 与候选 fake 回归 119 项、契约/文档/wire 回归 60 项通过，Ruff 和目标 Mypy 通过。

仓库外 `asr-natural-attribution-cp-expansion-20261019` 保留登记、全部模型输出、独立复算、接受检查和生产等价结果。以上是固定文字的归属收益，不是 ASR 内容改善；参考时钟与强制对齐仍须人工抽查，关键事实、在线延迟、资源及独立留出认证不能由这些分数代替。

另以第三场同一 180 秒输入实跑生产实现，保持 Qwen、aligner、C0 模型及请求参数不变；两臂各有 22 次正式转写、22 次对齐、一次分人终态，所有正文及对齐时间逐项相同。实际公开事件重建得到 cpCER 411/705→334/705（58.30%→47.38%）、unknown 字符 107→54；四位参考说话人错误均下降，已有明确标签零变化，复现固定文字诊断。原生、ASR、aligner 三个 worker 全部 wait 回收，源码与模型闭包前后稳定。

这次一倍速输入下，两臂总墙钟分别为 190.109/190.342 秒（包含准备、180 秒输入等待、验证与清理，不能称为计算 RTF）；结束调用观察为 62.44/60.29ms，准备为 593.83/604.36ms。每 250ms 顺序采样的进程树 footprint 最大值为 7484907752/7473881296 bytes，两臂均无缺 tick，但不证明原子物理峰值；没有重复样本或预先冻结的正式性能非劣界限，不宣称速度或资源改善。仓库外 `asr-probability-attribution-production-20261019` 保存前置登记、完整事件及恢复核验。维护后唯一 listener/LaunchAgent PID 82032，独立 health/readyz/metrics 200、无活动请求或外部客户端，3.12.0 quality/quality，配置/selection/runtime target 摘要不变。生产实现未安装，回退对应逻辑 commit 即可，安装态无需回滚。

## 转录失败恢复试验与数量保真修复

2026-10-19：优先保护固定 Qwen 的正文。先测试一次有界二分重试：仅在原解码未完整结束时，将同一 PCM 分成两半，每半必须正常结束，不递归、不交付部分成功。十个预定输入中八个正常输入无需重试；两个已知重复失败片段中，一个经两次额外调用得到完整结束，另一个首半仍失败即停止。总计十三次调用。获救片段缺少独立有序文字参考，完整结束不足以证明内容正确，因此不集成生产，也不扩展重试搜索。仓库外 `asr-bounded-failure-recovery-pilot-20261019` 保留全部输入登记与结果。

随后修复轻量 ITN 将相邻非零中文数字机械转换为精确值的问题。歧义数量及口头重复保留原文，明确计数、年份和小数继续按原规则转换。文件转写及标准 Realtime 的预览、完成正文共用此规则；模型已经输出的错误数字不反向猜测。未修改评分器或引入公共参数，也没有增加模型调用。

在查看 Qwen 输出前，按固定规则从三个原始 Train_far 来源各选最早满足条件的完整佩戴者语句，并加 250ms 上下文；片段分别为 13.80、11.56、4.23 秒。独立官方文字只用于选片与核验，未作为模型输入。每片仅一次固定 Qwen 推理，均正常结束；旧、新 ITN 处理完全相同的原始输出。两处概数与参考一致地恢复，另一处只消除后处理失真，模型枚举错误仍在。三片均与当前生产函数输出逐字符相同；不以目标子串存在代替完整事实正确，不宣称整体 CER、泛化或性能改善。私有完整正文与逐字符差异保存在仓库外 `asr-approximate-number-fidelity-20261019`。

十三个歧义数量反例先观察到预期失败，修复后通过；八个明确数字控制保留原行为，新增文件与 Realtime 两条 fake wire 回归。相关 ITN、转写、质量评分、Realtime 控制及契约/文档定向回归通过，Ruff 与目标 Mypy 通过。隔离进程内换回旧 ITN 后，十三个反例和两条 wire 测试全部失败，未改写仓库源码。CI 只使用合成文字与 fake backend，不依赖本机模型、语料或运行速度。

两次维护均回收诊断子进程并恢复原服务；最后独立核验唯一 listener/LaunchAgent PID 86049，health/readyz/metrics 均为 200、无活动请求或已连接客户端，3.12.0 quality/quality，配置、selection 和 runtime target 摘要不变。没有下载、安装、配置切换或访问留出。生产代码尚未安装，按此逻辑提交 revert 可回退。人工事实核验、代表性内容收益、正式资源界限及独立留出验收仍未完成。

## 数量保真的近讲与远场扩验

2026-10-19：在查看新输出前固定选片与接受条件：取同一三个 Train 来源中全部时长 1–20 秒、含相邻非零中文数字的数量表达且在目标佩戴者轨道前后各有 250ms 空隙的完整语句，排除数量保真首轮的三个目标区间；每来源再取最早的明确数字控制。得到五条新歧义数量语句（三条概数、两条口头重复）、三条控制，每条使用原始近讲和远场 channel 0 的相同区间，共十六段、104.54 秒，全部保留，无输出筛选。来源及部分较长音频在此前诊断中已使用；这不是未见来源。近讲空隙只排除该佩戴者相邻标注，不保证没有背景串音；远场不把单一佩戴者文字当成整段有序参考。

每片一次固定 Qwen 调用，全部正常结束，未向模型提供参考或热词；旧、新 ITN 处理同一原始正文，当前生产函数逐字符复现候选。用完整数量串比较，避免此前目标子串存在的误判：近讲六处、远场四处与独立参考完整匹配的模型数量表达，旧 ITN 均改写，新 ITN 全部保留。共八段正文变化，全部差异局限于数字串；六段明确数字控制的新旧正文完全相同。两段远场原始模型输出未逐字匹配目标口头重复，不能据此判断为数字事实错误；其中一段保留了去重复后的数量，另一段没有被数量串规则检出，仍须听音核验。新 ITN 不对这些输出反向猜改。

| 来源 | 近讲片段数 | 参考字符 | 旧 / 新字面错误 |
|---|---:|---:|---:|
| 1 | 2 | 55 | 8 / 6 |
| 2 | 4 | 140 | 18 / 10 |
| 3 | 2 | 21 | 5 / 3 |

字面归一化在查看输出前登记：NFKC、casefold，仅保留 Unicode L/N，不做中文数字等价折叠或参考改写。八段近讲合计 31/216→19/216（14.35%→8.80%），没有片段退化；两种独立编辑距离实现复算一致。来源等权差值为 −6.29 个百分点，seed 1717、10000 次来源配对 bootstrap 探索区间为 [−9.52，−3.64] 个百分点。其中八处保留的是概数，两处保留的是口头重复，不能把十处都当作独立数字事实修正。此处为定向选取数量表达的字面保真诊断，绝对错误包括数字书写形式差异；仍是同三个 Train 来源、背景串音和人工听音复核未解决，不代表一般会议 CER、挑战目标达成或独立泛化。远场不报整段 CER；没有新的 DER、cpCER、稳定时延或峰值资源声明。

独立核对全部原始近讲/远场父文件及标注摘要，十六份裁切 PCM 与登记来源区间逐字节相同；冻结模型、源码和输入闭包前后稳定，所有自有子进程已 wait 回收。维护后原服务恢复为唯一 listener/LaunchAgent PID 90418，独立 health/readyz/metrics 均为 200，无活动请求或已连接客户端，3.12.0 quality/quality，配置、selection 和 runtime target 摘要不变。没有下载、安装、配置切换或留出访问。仓库外 `asr-number-fidelity-expansion-20261019` 保留选片、完整结果、全数量串比较、两路复算和恢复证据；本轮只扩验已交付生产修复，不引入新的评测框架或生产参数。

## 文字归属的区间查询成本

2026-10-19：先检查安全复用 ASR 预览的可能性。既有第三场真实在线回放中，二十二个正式段的最后预览与封存区间均不相同，最后预览后仍有新 PCM；不以预览替代完整正式识别，也不为这组输入引入编码缓存。随后定位到归属计算逐文字单元线性扫描全部保留帧的问题，使用固定真实活动与对齐验证并优化此处，不改变 Qwen、正文、对齐或归属规则。

生产 ledger 按需建立帧起点与前缀最大终点索引，二分定位候选区间，再保留全部实际相交帧。前缀最大终点保留早期长帧的嵌套证据，不假设原始终点有序；重复、重叠与缺分数的原有保护继续生效。活动替换和实际删除历史帧后失效重建，没有归属查询时不建索引。顺序帧下避免逐字扫描无关历史；任意嵌套帧仍可能形成较大候选区间，不承诺所有重叠输入的查询都是对数成本。

在实施前冻结 `157b6bc6` 的 ledger 和全部三场既有来源，使用原先评分终点内完整 C0 帧与对齐单元；没有新增模型调用。每来源七轮交替顺序运行，计入 ledger 初始化、活动应用、索引构建和全部文字注册，排除制品加载与结果比较。结果如下，单位为 ms：

| 来源 | 帧 / 文字单元 | 旧 / 新墙钟中位数 | 旧 / 新 CPU 中位数 | 索引容器 bytes |
|---|---:|---:|---:|---:|
| 1 | 2241 / 792 | 33.56 / 7.02 | 33.53 / 7.01 | 36016 |
| 2 | 1264 / 390 | 11.32 / 4.03 | 11.31 / 4.03 | 20384 |
| 3 | 2178 / 497 | 22.42 / 5.80 | 22.40 / 5.80 | 35008 |

全部 1679 个归属的匿名标签、活动标签、状态、原因、revision 及顺序逐项相同，并与既有归属结果一致；同一输入不重新解释为 ASR 或分人质量提升。这里只测最终活动的确定性 Python 重放，不能代表在线更新、端到端延迟、模型 RTF 或进程物理峰值。代价是与保留帧数线性增长的两个索引元组；表中只计容器，沿用帧已有整数对象，不把 Python 分配峰值当作物理内存。

固定 seed 1717 的另一路差分验证覆盖一百次重叠/嵌套替换、稳定推进、历史压缩及晚到文字，204 次公开操作、503 个文字单元的全部归属字段一致。新增确定性工作量回归先观察到预期失败；不使用机器时延阈值。相关领域、owner、lane、session 与 Realtime 契约 fake 回归 103 项通过，Ruff、目标 Mypy 通过；内存内移除前缀最大终点、替换失效或压缩失效的三个 mutation 均被回归捕获，仓库源码不变。私有输入摘要、完整七轮观察及复算保存在仓库外 `asr-attribution-range-index-20261019`。本次未操作服务、模型、配置或安装态，代码按对应逻辑提交 revert 回退；正式在线延迟和资源验收仍待完成。

## 双人、三人自然远场扩验

2026-10-19：此前完整自然来源主要为四人会议，因此在新模型输出前，从官方 Train 元数据中以 seed 1717 固定选择一个双人、一个三人来源，排除既有三个自然来源及六个近讲对照来源。各佩戴者在前 180 秒须有至少 5 秒句级标注；取 180 秒后首个满足既有 400ms 空隙规则的终点，分别得到 181.46、192.94 秒。不按模型结果挑片，不向模型提供真实人数、文字参考或热词。这两个来源没有用于此前规则探索，但仍是 Train 数据，且存在模型训练来源重叠，不能称为独立泛化留出。

本机只有完整近讲压缩包和此前取得的少量远场来源。通过 ModelScope 官方远场 ZIP 的范围读取，仅获取两个选中完整 WAV 及已知原始录音 PCM 控制，合计传输 763417235 bytes，未下载约 78.6GB 的完整远场 ZIP。固定 CSV revision `1f3ec88f72b6b15215067ebee991f52f47b28156`，登记 ZIP 大小及 ETag，校验成员 CRC 与本地 SHA-256；控制片段与此前官方原始 PCM 逐样本一致。没有校验未下载 ZIP 的整体摘要，也不把 ETag 当作密码学完整性证明。输入为原始八声道录音的 channel 0 前缀，无混音、增益或参考驱动的处理；没有读取留出音频或标注。

独立文字来自对应官方佩戴者标注，紧致活动参考来自 `nttcslab-sp/diar-forced-alignment` revision `9527b7c64846fb38316a610f32e9d3466bd6d8b7` 的匹配 Train_far RTTM，逐文件校验 Git blob 与本地摘要，保留句级代理用于口径对照。对应五条近讲原始成员均与既有来源清单的大小、SHA-256 匹配；原压缩包 stat 未变。实跑前冻结 10ms 能量包络时钟筛查：首尾各 60 秒、搜索 ±500ms，接受绝对偏移至多 50ms、首尾差至多 20ms、相关系数至少 0.5。双人首尾为 −20/−30ms、相关 0.895/0.883；三人为 −50/−50ms、相关 0.734/0.696，均通过。评分不平移参考；该检查不能证明逐字时钟或强制对齐完全正确，人工抽查仍待完成。

固定 `1598d815` 源码、现有 Qwen、aligner、C0 分人模型和请求设置，每来源运行一次真实一倍速联合 session。固定实际 Qwen 正文及对齐，以原二值归属与当前分数辅助规则比较最终活动证据；两者都在公开 24kHz 坐标评分，原生 16kHz 帧边界按 3/2 向下取整映射，不声称重建了服务内部的逐单元整数坐标。当前线上实际归属另行独立评分，并与最终帧重算逐标签核对，两个来源均无差异。

| 来源 | 参考字符 | 二值 / 辅助归属 cpCER | 二值 / 辅助 unknown 字符 | 逐参考说话人错误变化 |
|---|---:|---|---|---|
| 双人 | 776 | 84/776（10.82%） / 82/776（10.57%） | 16 / 15 | 0、−1 |
| 三人 | 1118 | 279/1118（24.96%） / 198/1118（17.71%） | 67 / 25 | −7、−10、−22 |

合并为 363/1894→280/1894（19.17%→14.78%），减少 83 个字符错误；全部已有明确标签零变化，满足预先登记的每来源不恶化、合并改善及逐人错误增加至多 2 字的开发接受条件。额外 unknown 流的插入不计入逐参考说话人错误之和，因此逐人变化不必等于总错误差。独立 Python 字符编辑距离与全部补空说话人排列穷举，复算两场三种输出的最优总错误均与固定版本 meeteval 一致；冻结输入摘要前后不变。正文及对齐保持相同，这证明归属收益，不是 ASR 内容 CER 改善，也不是两臂均实跑的线上性能对照。

| 来源 | 紧致 / 句级代理 DER | 紧致 JER | 紧致漏检 / 误检 / 混淆（speaker-seconds） |
|---|---|---|---|
| 双人 | 6.93% / 10.73% | 7.32% | 0.61 / 8.37 / 0.00 |
| 三人 | 10.78% / 15.23% | 14.92% | 3.86 / 12.09 / 3.58 |

活动评分包含重叠、零 collar、整场一次匿名匹配；这是当前 C0 在新范围的观察，同一活动输出的参考差异不能当作模型改善。紧致参考下非重叠 known coverage 为 99.69%/99.40%，但该口径的 precision 为 93.90%/92.49%，两场均未通过既有活动质量门，不能仅以覆盖率宣布达标。短插话与关键事实的真人复核仍未完成；三人场话语较少的参考说话人仍有 43/158 个归属与内容合并字符错误，不因相对改善掩盖残余损失。

两场分别完成 16/10 次正式转写及对应对齐，分人 processed/stable 均达到全部输入终点，三个自有 worker 全部 wait 回收，冻结闭包前后稳定。结束调用观察为 77.40/56.29ms；250ms 顺序采样进程树 footprint 最大值为 7603528032/7601463768 bytes，缺 tick 为零，不能证明原子物理峰值、资源改善或计算 RTF。日志没有正式时延 policy 所需的 joined watermark 与稳定标签 sink ack，也缺少完整作用域关闭时刻；缺失观察按未通过处理，不用结束调用耗时代替正式 finish 延迟。

维护后恢复原 3.12.0 quality/quality 服务；2026-10-19 01:57:58 UTC 独立核验唯一 listener/LaunchAgent PID 99067，health/readyz/metrics 均为 200，活动请求与已连接客户端为零，配置、selection 和 runtime target 摘要未变。没有下载模型、安装或切换生产默认。仓库外 `train-far-two-three-speaker-readiness-20261019` 与 `asr-natural-two-three-speaker-20261019` 保留来源、预登记、完整观察、独立复算和恢复证据；另备好十六段合计 104.54 秒的数字事实听音清单，真人结论留空。该扩验不改生产规则、契约或 CI，不引入新的仓库评测框架；正式人工、时延、资源及独立留出验收继续保持未完成。

## 弱说话人损失与在线计时

2026-10-19：进一步核查三人场的剩余损失。最少参考字符的说话人有 38 个删除字符，其中 21 个属于常见应答字符；编辑路径不唯一，字面字符分类不等于语义事实判断。一段较长发言开头的五个字符已经由 Qwen 识别，却归入上一位说话人的流；对应原生帧给上一人的分数超过 0.95，新说话人的分数低于 0.01。至少这部分是参考归属下的错标，不能当成 Qwen 漏识别；不通过降低置信门限或猜改正文修复。人工听音仍待完成，不能把其余删除全部认定为应答省略。

随后在新输出前登记一个固定配对诊断：同一三人场 192.94 秒、相同 Qwen/aligner/C0/ITN 和请求，基线只恢复 `157b6bc6` 的归属 ledger，候选使用当前区间索引实现。每臂独立冷建 owner、按一倍速输入、只运行一次，顺序为基线、候选；没有 ASR、模型或归属规则切换。私有观察器在原发布函数完成真实 sink 返回后记录不可变文字单元的 final 状态和原生活动稳定水位，不改变公共负载、调度或标签。两臂各完成十次正式转写、十次对齐、一次分人终态；正文、对齐时间及实际匿名标签逐项相同，三个自有 worker 均已 wait 回收，冻结闭包前后稳定。

| 服务侧观察口径 | 基线 | 候选 |
|---|---:|---:|
| 源输入起点到首次非空预览 | 3.311s | 3.313s |
| 正式 ASR owned span 末尾到完成回调，按 span 时长加权 P95 | 0.751s | 0.756s |
| 对齐单元音频末尾到已知稳定归属发布，按该单元 span 时长加权 P95 | 20.071s | 20.068s |
| 最后源样本目标时刻到 session/owner/lifecycle 加入清理完成 | 0.384s | 0.388s |

首次预览时钟包含源开头静音，不能解释为纯推理耗时；这里是进程内生产链路及 sink，没有 HTTP、WebSocket 或 UI 交付测量。两臂均有 961 个实际对齐单元，其中 22 个未知或未满足已知稳定条件，占单元音频权重 2.7424%；这些样本以原权重、正无穷保留，不因其低于 5% 而宣布全部完成。正式回调与逐对齐单元稳定等待的候选/基线比为 1.0078、0.9998，处于实跑前登记的 1.05、1.10 诊断界限内；每臂仅一次，不能升级为稳定性能非劣证明。

必须区分上述对齐单元与正式 `sealed_owned_span_duration_v1` 的采样总体：后者由 `SealedBody.append` 登记 `CompletedText` 的整个封存 ASR owned span，前者是实际生产归属的细粒度对齐单元。不能把约 20 秒的逐对齐单元 P95 与正式 15 秒 owned-span 门直接比较。早期私有结果中的该比较已用 `latency-population-correction.json` 明确更正，原观察保留；没有调整门限，也不以较短回调耗时代替正式稳定标记。该次实跑未提供正式 owned-span 稳定标记，正式稳定时延继续为未证实。

250ms 顺序采样 footprint 最大和为 7877599488/7623451048 bytes，基线无缺 tick、候选缺一个 tick，不作资源改善声明。另按 Apple XNU 的 `proc_pid_rusage` V4 设计累计物理 footprint 高水位检查，已核对本机 SDK ABI 与自身读取；但实际预清理检查点的覆盖/身份断言失败，没有有效的四进程累计上界，预登记的资源非劣检查不能通过。该 API 及结构定义见 [Apple XNU resource.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h)。不以 RSS、采样最大值或不完整进程集合补成物理峰值证据，也未为此反复实跑。

维护后恢复原 3.12.0 quality/quality；2026-10-19 02:17:25 UTC 独立核验唯一 listener/LaunchAgent PID 2508，health/readyz/metrics 均为 200、无活动请求或已连接客户端，配置、selection、runtime target 摘要未变。完整配对输出、初步失效解释及更正保存在仓库外 `asr-stable-attribution-resource-20261019`。本次没有下载模型、安装、默认切换或留出访问；正式稳定时延、物理峰值及真人验收仍未完成。

## CI 工作流读取门同步

2026-10-19：证据提交 `be4dd026` 的 Swift Package Tests 在 `testPauseDuringCompletedProductionRefreshKeepsCompletionResult` 失败，原因是测试在固定 1000 次 `Task.yield()` 后认为读取门未触发；同一次执行其他 XCTest 和全部 658 项 Swift Testing 均完成，失败日志保留。测试读取门改用 `XCTestExpectation` 与实际 suspend/resume 事件同步，保留十秒超时看门狗；该用例的暂停阶段等待也按真实状态和有限时钟推进，并在释放读取门前确认 owner 已进入暂停。完成结果、候选显式采用和当前 revision 的业务断言继续保留，不改生产代码或掩盖失败。失败用例单跑及整个 `AudiobookWorkflowTests` 的 47 项定向 fake 测试通过；完整 CI 以修复后提交的独立结果为准。测试不依赖本机调度次数、真实语料或模型，未运行 UI 自动化；按逻辑提交 revert 可回退测试变更。

## 条件词、单价与省略位数的转写保真

2026-10-19：继续排查轻量 ITN 的实际内容损伤。旧规则把条件词“万一人家”变成“10001人家”，把单价“五百一个”变成“501个”，也把省略位数的“三千五元”变成“3005元”。在既有官方 Train_near 标注中检出 29 处相关表达，分布在 19 个来源组；这是标注表达数量，不能直接当作模型错误次数。修复只对带单位数量及非小数百分比的数词末尾增加保守条件：百或更大数量级后直接接非零数字时保留原文，不猜测省略位数或跨词边界。显式零位、完整位数、小数和年份的既有处理保留；底层数值解析与评分归一化均未改动，不声称解决全部中文数字语法。

补充十二个领域反例、八个显式位数控制，并扩展 batch 与标准 Realtime 的预览、终稿回归。先观察旧代码的预期失败，再验证相关 ITN、Unicode 边界、公开路径及指标测试 130 项通过，Ruff、目标 Mypy 通过；内存内恢复旧歧义条件后，十二个领域反例与四个新增公开路径用例均失败，仓库源码未被 mutation 修改。测试使用 fake backend，不引入真实语料、模型、机器时延或硬件门限。

在新模型输出前，按来源、起点、轨道顺序固定选择一个条件词片段和两个单价片段，来自三个不同 Train_near 来源组，共 15.19 秒。每段取对应佩戴者的原始近讲 PCM、前后各至多 250ms 上下文，无混音或增益；完整原始成员大小、SHA-256 及压缩包身份均核验。每段只调用一次相同 Qwen，固定中文、空 prompt，不提供参考、热词或人数；同一原始输出分别应用冻结的旧、新 ITN。三个调用均完整 EOS，其中两个输出包含与独立标注一致的完整目标表达，旧 ITN 会损坏这两个表达，候选均保留；另一个输出没有完整目标表达，前后正文相同。目标以整个正则匹配区间相等判定，不作子串命中或按输出重新挑片。这里证明后处理避免了两处已观察的误改，没有增加模型调用；不作整体 CER、关键事实准确率或性能达标声明，真人听音仍未完成。

首次维护在模型加载前因冻结摘要变化退出：并行 fake 测试更新了 `itn` 字节码及其缓存目录；原服务立即恢复。确认源文件未变后保留失败记录，禁用字节码写入、重新冻结并串行执行，第二次完整闭包前后摘要一致，推理子进程已 wait 回收。2026-10-19 02:36:41 UTC 独立核验原 3.12.0 quality/quality 已恢复，唯一 listener/LaunchAgent PID 6821，health/readyz/metrics 均为 200，无活动请求或已连接客户端，配置、selection、runtime target 摘要未变。完整选择、输入、原始输出、两次维护及恢复证据保存在仓库外 `asr-unit-phrase-fidelity-20261019`。没有下载模型、切换默认、安装或访问留出；本次代码尚未安装到 managed runtime，按逻辑提交 revert 可回退。上一提交 `7f51a365` 的全部八项 CI 检查通过；本次提交的远端检查须另行确认。

## 标签等待定位与真人复核交接

2026-10-19：复用既有三人场两臂的原始事件、对齐和 sink ack，不再加载模型。对 961 个对齐单元中的 939 个已知稳定标签，将从该单元音频末尾到发布的等待拆为四个可加部分。候选的时长加权均值为：等封存 ASR owned span 结束 9.5574 秒、其后正式识别 0.6507 秒、其后对齐 0.0624 秒、其后标签发布 0.00245 秒，合计 10.2729 秒；基线合计 10.2776 秒。十个拥有区间中九个为 20 秒，最后一个为 10.764 秒。该分解仅以已知标签为条件，22 个未知单元继续列为未完成，不将这个均值用于替代全量 P95、正式稳定门或 HTTP/UI 时延。原始文件摘要及逐区间观察保存在既有私有证据目录的 `stable-wait-localization.json`。

这场诊断没有支持“归属发布本身造成约二十秒等待”的假设；主要等待来自已有转写切段。沿用六来源段预算实验的停止决定，不再搜索段长、不改默认或增加分人并发，也不为补一次失效资源测量重复联合实跑。稳定时延总体的正式定义、完整生命周期资源预算及独立验收仍须按冻结协议验证。

把既有十六条数字表达、九条弱说话人/声音锚点及此次三条条件词/单价材料整理为仓库外 `meeting-quality-human-review-20261019/review-index.html`。二十八项、三十七个音频控件合计 173.63 秒；所有音频摘要核对，匿名编号，无完整转写、外部网络或自动推理。先播放并填写独立判断，再展开参考与候选，允许记录不确定；答案可本机暂存并导出，导出不自动认定完成。静态 HTML 结构及 JavaScript 语法通过检查，未运行浏览器或 UI 自动化，实际播放与真人结论仍未验证。此前已询问复核人安排，尚无答复；全部真人字段保持空白，不能以开发者脚本代填。`be27ed77` 的八项 GitHub CI 检查均已通过；本次只补充定位与交接记录，没有生产代码、运行态或模型变更。


## 真人复核结果与残余问题

2026-10-19：收到复核人导出的二十八项、一百二十八个非空答案（导出于当日 11:46，Asia/Shanghai）。逐项 ID、问题顺序与原清单一致，三十七个音频控件的 SHA-256 全部匹配；原始答案按字节保存在仓库外，另写接收与判读记录，不覆盖原问卷或把其空字段自动补成通过。导出模板中的 `human_review_complete=false` 不是答题缺失，也不是质量结论。此前各节“尚未收到真人结果”的表述仅描述当时状态，本节记录收到后的判断。

十九项数字、重复和条件词/单价复核中，十项实际发生了 ITN 输出变化；九项得到“更忠实／是／候选更佳”的回答，一项近讲无法听清。九项支持中，一项远场后半数量表达基本听不到，另一项独立听写栏只填写“支持”，均保留证据限制；不能换算为总体事实准确率或 ASR CER。条件词复核支持保留原意，同时指出正则提取的参考片段含义不清。两个“空”的反馈来自展示的目标表达数组为空，实际完整转写分别有 19、62 个字符，不是模型没有输出；后者前后正文相同，不认定修复收益。后续展示应明确“未提取到所列目标表达”，避免让局部提取结果冒充完整转写。

分人九行只对应八组不同音频：三人场的重叠与短插话两行使用相同近讲、远场 PCM，不能重复计数。复核人在两行分别记录听不清及两人中漏一人，原答均保留，不强行消除不确定性。复核明确指出三人场一个声音被拆成两个标签，以及双人场可听清发言中的 `unknown`；另报告短插话漏人。三人场声音锚点中的两人远场、一人近讲不能直接判为通过，近讲仅用于辨认某位佩戴者，不能充当全体声音参考。分人真人验收未通过，认证最大人数继续为未确定。

对“近讲与远场内容不一致”的反馈，复核九组裁切均逐 PCM 字节匹配各自准备好的父音频、使用相同样本区间；近讲准备与官方文字参考均按同一 annotations 顺序赋予匿名 R 编号，没有发现排序导致的轨道交换。本次未重新解包原始语料，也未以总体能量相关性证明该片段的语义或逐字边界正确，因此此项仍待定位，不能归咎于模型或要求复核人改答案。

后续按 ROI 先定位已确认的单声音拆分、短插话遗漏与 `unknown` 的具体区间，区分原生活动错判、文字对齐和归属拒判；既有高置信错人不能用统一降门限修复。保留 Qwen，不为问卷问题重新运行全部模型或要求整份重听。本次只接收、核验和记录真人反馈，没有生产代码、模型调用、服务操作、安装或留出访问。完整原答与判读保存在仓库外 `meeting-quality-human-review-20261019`；回退文档提交不会删除私有原始答案。


## 单元内部停顿的文字归属

2026-10-19：以真人指出的双人场 `unknown` 为起点，重放既有原生活动替换与固定文字单元。声音锚点和短插话两张卡实际覆盖同一个文字单元（源音频 7.552–8.192 秒），不能计作两个独立缺陷。该单元首尾均为 A 活动，中间约 320ms 无活动，整体活动覆盖为 0.50，低于原 0.60 下限；其余人无活动证据，因而落为 `insufficient_evidence`。这与三人场开头高置信错人的成因不同。

在看到新候选输出前登记一个固定规则和接受条件：仅处理原规则不能确定、没有降级原因的文字单元；区间内只有一位 active 说话人，首尾均为其活动，所有帧完整连续、不重叠且有分数时，用 active 帧时长加权的独立分数均值检查原有 0.60 下限。它不借相邻词标签、不填补发声、不改正文、对齐或已确定标签。没有搜索参数或引入新的阈值。预先要求五来源 cpCER 各不恶化、合并严格改善、逐参考人错误不增加、已知标签零变化；这是根据真人问题提出的开发候选，不是独立认证。

以当前生产实现和冻结的提交前 ledger 分别重放同一五来源 Qwen 正文、对齐与 C0 帧。四人三场和三人一场逐单元标签不变；双人场四个未知单元分别在 7.552–8.192、74.304–75.104、97.584–98.064、143.488–144.368 秒变为已有 A/A/B/B 标签，共八个评分字符。双人 cpCER 从 82/776（10.57%）降到 70/776（9.02%），S/D/I 从 38/21/23 变为 36/16/18；两位参考人的错误分别从 18/49 降到 16/47。五来源合计从 1284/4239 降到 1272/4239，unknown 字符从 206 降到 198。当前生产代码与事先固定的候选逐单元一致；独立字符 DP 加补空匿名排列穷举，复现全部十个总错误计数，十个最优匿名匹配均唯一，冻结输入摘要前后不变。

收益仅出现在一个来源。来源等权平均差为 −0.3093 个百分点，事后探索性来源 bootstrap 枚举 3125 个有放回有序抽样，百分位 95% 区间为 [−0.9278, 0.0000] 个百分点，不支持宣称稳定泛化收益。真人直接支持其中首个未知片段应有人，另外三个恢复片段尚无专项真人结论；没有把开发参考自动升格为听音真值。三人场单声音拆分、重叠漏人及参考争议均未由本规则解决。

先观察原代码在内部停顿反例上失败，再完成实现；新增领域拒判与水位/终态回归、标准 Realtime 交付回归，七个相关文件的 116 项 fake 测试通过，Ruff、目标 Mypy 通过，Realtime 契约检查覆盖 61 个 fixtures、65 个受跟踪字段。内存中禁用新规则使三项测试失败；放行缺帧使缺口拒判用例失败，生产源码未被 mutation 修改。最初定向命令同时触发了全仓 80% coverage 门失败；该定向运行不构成全仓覆盖率验收，后续按仓库约定使用 `--no-cov`，没有修改门限，完整 CI 另行跟踪。

规则只遍历当前相交帧，没有新增模型、持久化状态、进程、等待窗口或调用参数；本次未重新推理或操作服务，不据此声称实跑时延、RTF、物理峰值或生命周期正式验收通过。契约与用户文档同步说明条件及 unknown 边界，事件 schema 不变；影响限于满足上述条件的原未知文字标签，ASR 优先原则保持。私有输入、单元定位、预登记、生产重放、独立复算及 mutation 结果位于仓库外 `human-diarization-loss-localization-20261019`。代码尚未安装，按该逻辑提交 revert 可回退。


## 普通表达与小数边界的转录保真

2026-10-19：沿内容损失检查轻量 ITN。现有 Qwen Q8/BF16 对照此前未见收益，不重复精度路线。小数正则会将“一点一点”“三点一线”“五点六点”“三点一刻”分别改为带小数点的串；这会改变普通词语或钟点含义。修复在完整贪婪匹配的回调中检查紧随的“点／滴／刻／线”，有歧义时保留该匹配，不把限制直接放进会回溯的正则。含多个“点”或以“点”结尾的百分比匹配也不生成百分数，避免形成带额外“点”或空小数部分的输出。此范围不构成完整中文钟点或数字语法解析；明确小数、数字范围、年份和有效百分比保持原处理，数值解析与评分规则不变。

按现有官方 Train_near 独立标注筛选“一点一点”和“二／三点一线”，共七处、六个来源组。在看到新 Qwen 输出前，固定按来源组、起点、轨道排序，选前两段重复词和首段固定表达，三段来自不同来源组；完整语句为 1–15 秒，使用原始佩戴者近讲、前后各 250ms 清晰同轨上下文，总 29.41 秒。原始完整 WAV 成员大小、SHA-256 与既有清单一致，压缩包 stat 未变，没有混音、增益或给模型参考/热词。它们是有目标表达的开发样本，不是代表性自然会议抽样，近讲仍可能含背景串音。

固定相同 Qwen、中文、空 prompt，每片只调用一次；三次均完整 EOS。对同一原始输出应用冻结的修改前后 ITN，完整命中的两个“一点一点”和一个“三点一线”均被保留，旧规则会损坏三者；目标按完整匹配加其边界字符相等判断，不作子串命中或根据输出重新挑片。按固定 NFKC/casefold、Unicode L/N、不折叠中文与阿拉伯数字等价的字符评分，128 个参考字符的错误为 17→8，S/D/I 为 13/4/0→7/1/0，三个来源分别 6→3、6→3、5→2，独立字符 DP 复现评分器总错误。该定向样本 CER 13.28%→6.25%，不能解释为全场 ASR CER、模型识别或总体事实准确率改善；修复只避免三处已发出的后处理误改，没有增加候选推理。

按三个来源计算的等权配对 CER 差为 −10.3595 个百分点；事后探索性来源 bootstrap 枚举 27 个有放回有序抽样，95% 百分位区间 [−17.1111, −4.9003] 个百分点。该区间只描述所选表达条件，不能外推整体会议。已有十六条数量和三条条件词/单价的真实原始输出另作重放，十九条在本次修改前后逐字相同；原答、原输出和本次三个片段的真人待复核状态均保留，不以官方标注替代真人听音。

先确认原代码的预期失败，再完成领域和 batch/标准 Realtime 预览、终稿回归，三个相关测试文件共 103 项 fake 用例通过，Ruff、目标 Mypy 与 Realtime 契约检查通过。内存中禁用词边界保护使十四项测试失败，禁用百分比“点”检查使四项失败；源码未被 mutation 修改。契约和用户文档同步说明保留规则，事件 schema 和 API 参数不变，没有 CI 真实语料或硬件门限。生产文件新增七行（含说明注释），不新增模型、状态或解码调用。

串行维护前冻结现有模型、运行时、依赖、当前生产源码、实际脚本、三份 PCM 与修改前后 ITN，执行后完整闭包核验稳定，推理子进程已 wait 回收。2026-10-19 04:14:57 UTC 独立核验原 3.12.0 quality/quality 服务恢复，唯一 listener/LaunchAgent PID 26129，health/readyz/metrics 均为 200，无活动请求或客户端，配置、selection、runtime target 摘要未变。没有下载、安装、默认切换或留出访问；没有新增时延、RTF、物理峰值及长时生命周期认证。代码尚未安装，按逻辑提交 revert 可回退。完整选择、原始音频和输出、冻结、评分、mutation 与维护证据保存在仓库外 `asr-decimal-boundary-fidelity-20261019`；新提交 CI 单独跟踪。

## 联合资源观测的失效定位

2026-10-19：只读复核先前 interval-index 联合对照的原始采样、私有驱动和当前生产源码。旧驱动在 `speechrail.diarization.finish` 返回后，要求 runner、ASR、aligner、分人四个进程仍全部存活，再读取 V4 lifetime maximum；但生产 `CoreMLActivitySession.finish` 在返回前已关闭分人 worker lease，因此这个四进程检查位置不成立。原始结果仅保存 `AssertionError`，不能追溯到具体断言；本次明确定位的是已证实的时机错误，不声称恢复了缺失的峰值读数。原采样在 done 之前仍有四进程，之后仅剩 runner；两臂均符合退出阶段的时序。本机无模型只读探针对同一存活进程比较 V0/V4 start token，身份一致且 lifetime maximum 不小于当前 footprint，没有证据支持 ABI 字段错位。

原始采样、延迟和 wait 回收记录保留；此前约 7.878/7.623 GB 只能继续称为采样最大值，不能据此宣布物理峰值或资源非劣通过。后续确有产品候选需要联合实跑时，资源检查须分别绑定各 owned worker 的最后存活边界，并明确未覆盖的退出阶段；仅补采样次数或把四改成三均不能补出完整进程范围。不为这一报告缺口重复同源模型推理。本次零模型调用、零服务操作，私有证据 `asr-stable-attribution-resource-20261019/resource-checkpoint-root-cause.json` 记录输入摘要、自进程探针和终止事件前后采样；未修改原始证据、生产实现、预算或 CI。图谱不覆盖本 worktree，相关结论以实际源码与保存的原始观测为依据。

## 短前缀的声学特征区分诊断

2026-10-19：针对真人确认的三人同声拆分，原生 C0 在 65.376–66.176 秒仍高置信输出 B，随后才转为 C；这属于声学活动错人，不能由 unknown 的概率补充规则解决。只检查本机已有 Community-1 的 FBank 与 Embedding 是否提供可用的独立声音区分证据，没有重新运行全场聚类、Qwen 或调整 C0 阈值。两个既有模型共十个文件与此前冻结摘要相符，不下载、不改第三方 checkout。

模型输出出现前固定输入与判据：目标为上述 0.8 秒原始 far/channel 0 前缀；对原生槽 1/2 分别取首两个不重叠的 2.4 秒高置信单槽活动块，排除目标前后两秒。首块中心两秒作 anchor，次块首尾各 0.8 秒作 control，共七段、八秒。controls 的槽来自 C0，并非新增真人真值，只检查该方案与其自身选择依据是否一致；同一来源内的样本也不独立。初次离线准备因槽 2 不足三个合格块停止，改为两个块后完成冻结；此时未加载模型或出现新输出。无增益的 PCM16/32768 浮点输入采用既有离线提取方式的十秒补零，权重只覆盖原始音频长度；FBank 为 cpuOnly，Embedding 为 all，单次进程、900 秒上限。预登记要求目标更接近槽 2、四个 controls 都更接近各自原槽，且每项 cosine 差至少 0.1；仅作为路线去留判据，不是生产阈值或质量认证。

七次提取均返回有限的 256 维向量。目标与槽 1/2 anchor 的 cosine 为 0.85649/0.90878，方向符合目标但差仅 0.05230；四个 controls 仅一个与原槽方向一致，五项均未达到固定 margin。因此停止该短片段特征直接改标签的路线，不按结果调 margin、不扩大样本或接入生产；此结论不证明 C0 controls 全部正确，也不代表较长语音、其他提取方式或该模型整体无效。原始输入、模型、实际 Swift 源码/二进制、Python 驱动与注册内容闭包前后稳定；独立按原 PCM 重建七份浮点输入，并复算五项比较方向和固定 gate，结果一致，没有第二轮推理。

无活动请求或客户端时按 managed CLI 停服，单个诊断子进程 exit 0 且已 wait，结束恢复原服务。2026-10-19 04:28:05 UTC 独立检查唯一 listener/LaunchAgent PID 29648，3.12.0 quality/quality，health/readyz/metrics 均 200，无活动请求或客户端，配置、selection 和 runtime target 摘要未变。本次没有生产代码、安装、公共契约、留出访问或新增质量/资源认证；模型加载与七段计算的宿主墙钟约 0.79 秒不作为流式延迟或峰值资源证据。私有计划、冻结、原始结果、决策、独立复核及维护证据保存在仓库外 `human-boundary-embedding-diagnostic-20261019`。本次以实际 worktree 与被图谱排除的 SDK 源码直接核验，不把旧索引视作当前实现证明。

## 短暂停顿归属修复的联合实跑

2026-10-19：在同一已授权 Train_far 双人自然片段（181.46 秒）上，对比 b274e279 之前的 AttributionLedger 与当前生产 ledger；其余生产源码、Qwen、aligner、C0、ITN、请求和依赖相同。每臂各一次完整联合会话，按 1×供给，固定 20 秒预算及 full_segment；输入为既有原始 channel 0，经精确逆嵌入供给 24k wire，属于绑定当前重采样实现的 16k 开发诊断。使用实际 AppServices、共享 Governor、三个模型 worker 和 metadata sink，未启动 HTTP listener，不作为安装态 API、麦克风或 UI 验收。源、模型、实际脚本与完整执行闭包在每臂前后核验稳定，两臂配置和模型摘要一致。

两臂十六个拥有区间、737 个对齐单元的完整正文与时间一致，原生概率帧完全一致。实际在线标签仅在此前定位的四个区间由 unknown 变为 A/A/B/B，共八个评分字符，所有已知标签不变；区间为 7.552–8.192、74.304–75.104、97.584–98.064、143.488–144.368 秒。cpCER 82/776（10.57%）→70/776（9.02%），S/D/I 为 38/21/23→36/16/18；两位参考人的错误为 18/49→16/47。未知单元 8→4，未知字符 15→7。独立字符 DP 和补空匿名排列穷举复现两臂错误数，最优匹配均唯一，完整复现此前固定正文重放收益；这是一来源的训练开发联合诊断，没有新增跨来源置信区间或整体 ASR 内容改善声明。

| 同源宿主观测 | 基线 | 修复后 |
| --- | ---: | ---: |
| 输入起点至首次非空预览（含前置静音） | 7.942 s | 7.950 s |
| 拥有区间末样本至正式正文 P95 | 0.644 s | 0.639 s |
| 最后源样本目标至会话、owner、lifecycle joined 关闭 | 0.220 s | 0.208 s |
| 推理期四进程物理 footprint 保守上界（十进制 GB） | 9.774916 | 9.774752 |
| 严格稳定标签 P95（未知保留原权重为无穷） | 不可得 | 不可得 |

正式正文 P95 比值 0.99317、推理上界比值 0.99998，分别满足预登记的 1.05 相对非劣界；单次对照不能证明可重复的性能收益。ASR 等待 RPC 时间并集/音频时长为 0.13683→0.13369，分人为 0.05166→0.05196，含 IPC、排队与计算，已消除同角色等待区间重叠的重复计数；纯模型计算 RTF 未验证。两臂仍有 unknown，严格标签门未过。按整个拥有区间计权，含未知的权重为 61.23%→31.84%；按对齐词时长计的未知权重另为 4.59%→2.36%。词末起点的有限诊断 P95 为 20.147→19.172 秒，不能替代拥有区间口径的稳定标签验收，也不能将其变化解释为标签调度加速。

资源观测在每个 exact owned worker 的 close 入口读取 V4 lifetime maximum，runner 在全部推理和 metadata finish 后读取；分别核对已登记 PID/start token，再检查 close 已 wait 回收。四份 lifetime maximum 的和界定各自读数前的推理期上界，不是同一时刻的联合峰值，读数后的退出阶段与后续宿主制品写入不在范围内。原生 SDK C header 与 ctypes 的 size/offset 相符，两臂采样无缺失，四个 exact lifetime 均已不再存活。退出阶段峰值、重复运行置信度和完整资源认证仍待验证。

首次基线尝试遇到观测竞态：采样重复登记已退出进程，异常在 join sampler 时阻断结果落盘；没有完整质量结果，候选未运行，不纳入比较，原始失败证据保留。修正只对每个 owned lifetime 登记一次，实际峰值读取仍核对 token；sampler 任务异常和自取消关闭资源验证并允许清理、保存模型结果。小进程预检覆盖正常退出后继续 track、首次登记已消失、sampler 异常/取消及回收，再在独立 v2 目录冻结上述同一产品对照，没有修改生产代码、模型、阈值或门限。

两次窗口均无活动请求/客户端后 managed 停服并恢复。修正后的两臂完整结束、所有子进程已 wait，2026-10-19 04:56:33 UTC 独立核验原 3.12.0 quality/quality 服务恢复，唯一 listener/LaunchAgent PID 31993，health/readyz/metrics 均 200，无活动请求或客户端，配置、selection 和 runtime target 不变。没有下载、安装、默认切换或留出访问。C0 活动本身未变：含重叠、零 collar 的紧致参考 DER/JER 为 6.93%/7.32%，漏检/误检/混淆为 0.61/8.37/0 speaker-seconds；句级代理分别为 10.73%/11.09%，保留口径差异，活动质量门仍未过。新增六项补充听音仍待真人回答，三人同声拆分等既有问题保留。完整成功证据在仓库外 `asr-interior-gap-joint-v2-20261019`，首次失败在 `asr-interior-gap-joint-20261019`；先前三人资源缺口不由本次双人结果补写为通过。


## 补充听音结论与短插话定位

2026-10-19：复核人以会话回复完成六项补充判断：前三项选择 B、A、A。按原先冻结、未改动的随机展示映射，三项均选择修复后写法，对应两处“一点一点”和一处“三点一线”；这支持三处已有 ITN 修复，不外推整体 CER 或关键事实准确率。后三项的原答为片段太短、人力难以判断，统一记录为无法判断；不计作正确、错误或三项标签通过。原始会话答复及映射核验保存在仓库外 `meeting-quality-short-human-followup-20261019/human-followup-reply-20261019.json`，来源明确为会话回复，不伪装成 HTML 导出；原清单、HTML 和首次 28 项原答均未修改。六项已回答不等于分人验收通过，不再要求复核人反复辨认这些孤立短词。

同时复用三人场原始观测定位 3.80–4.12 秒短插话。它在已完成的 2.176–22.176 秒 ASR owned span 内，该位置没有相交的最终对齐文字，前后最近单元为 3.376–3.536、4.256–4.416 秒；不支持整个识别区间被 VAD 丢弃的解释，但这些终态元数据不证明 vendor 原始解码内容或精确模型上下文。重放全部原生活动替换后，覆盖目标的五帧完整连续，槽 0/1/2 活动时长分别为 0.04/0.28/0.08 秒；仅修改文字标签不能补出该处缺失的对齐单元；现有证据尚不能区分真实漏词与对齐错位，也不据此断言所有活动槽都是真人。整场一次最大重叠匹配得到紧致参考到佩戴者参考的匿名映射 R1→R3、R2→R2、R3→R1；目标紧致参考只含佩戴者 R1 的 3.83–4.09 秒活动，句级代理却包含 R1/R3，保留口径差异。两张相关真人卡使用同一音频且可听性回答不同，不算两个独立缺陷。私有 `human-diarization-loss-localization-20261019/short-interjection-pipeline-audit.json` 保存输入摘要与定位，独立逐样本覆盖重建复现全部 5120 个目标样本的分数均值、活动时长及清单映射。此次没有生产变更、模型调用、服务操作或新增认证；后续优先验证上下文充分、可明确复核的内容与错标，拒绝为无法判断的短词强行填词或猜标签。


## “统一”的数量边界保真

2026-10-19：发现轻量 ITN 会把普通词语“统一分配”“统一人员”中的“一”作为带单位数量，输出“统1分配”“统1人员”。在既有 Train_near 官方独立标注中查到三处相关完整话语、来自三个来源会议；在新模型输出前固定全选这三处，按来源、起点、轨道排序，以原始佩戴者近讲完整话语及前后至多 250ms 的同轨空隙裁切，邻接标注限制上下文边界，共 12.85 秒。全部完整原始 WAV 成员大小与 SHA-256 匹配，原压缩包 stat 未变，无混音、增益、下载或留出访问。

事先只登记一个最小候选：带单位匹配的数词恰为“一”且紧接在“统”后时保留原匹配；其他数词及解析不变，不引入通用词典或额外解码。固定现有 Qwen Q8、中文、空 prompt，每段只解码一次，未提供参考或热词；三次均完整 EOS，原始输出均正确保留“统一”，旧后处理各误改一字，候选均避免该误改。同一原始输出的 56 个独立参考字符上，错误 8→5、CER 14.29%→8.93%，S/D/I 为 6/2/0→3/2/0；逐来源错误 1→0、1→0、6→5，其他识别错误仍保留。另重放既有 22 条数量、条件词/单价和普通词语的真实输出，前后逐字一致；不能把三处后处理修复当作 Qwen 自身识别、全场 CER 或分人改善。

独立完整矩阵字符 DP 复算三个来源的两臂错误，逐个验证实际改动只是一处 1→一，输入与评分摘要稳定；当前生产文件与冻结候选逐字节相同。来源等权平均 CER 差 −11.7521 个百分点，事后探索性来源 bootstrap 枚举 27 个有放回有序抽样，95% 百分位区间 [−21.2500, −3.6752] 个百分点；这是按目标表达选取的开发样本条件结果，不证明代表性会议泛化或整体事实准确率。此次三段真人专项确认尚未进行，不挪用此前六项听音的结论。

领域反例先观察到五项预期失败，文件及标准 Realtime 预览/终稿另有两项预期失败，再把三行边界保护落入生产。相关 ITN、Unicode 边界与公开路径共 114 项 fake 测试通过，Ruff、目标 strict Mypy 及 Realtime 契约检查通过（61 fixtures、65 tracked fields）。内存中禁用该保护使七项回归失败，误将所有“统”后数词都禁止转换使“总统三人”数量控制失败；生产源码未被 mutation 修改。首次定向命令误写了 Unicode 测试文件名，零测试执行，保留原输出；更正文件名后的 114 项结果才作为验证。契约与用户文档同步说明普通词语边界，事件 schema、API 参数、模型和 CI 真实语料策略不变。

真实诊断前确认无活动请求及客户端，managed 停服；有界子进程完成且已 wait，闭包前后稳定。2026-10-19 05:12:12 UTC 独立核验原 3.12.0 quality/quality 恢复，唯一 listener/LaunchAgent PID 34146，health/readyz/metrics 均 200，无活动请求或客户端，配置、selection、runtime target 摘要不变。私有输入、原始输出、两臂评分、独立复核与维护证据在仓库外 `asr-unify-word-boundary-fidelity-20261019`。本次没有安装、默认切换、额外模型或新的性能/资源认证；源码尚未安装到 managed runtime，按本逻辑提交 revert 可回退。

### 神经 VAD 的短峰值语音准入

2026-10-19：既有四人自然会议 `natural-003` 的 99.776–107.456 秒没有任何实际 ASR owned span，期间独立文字参考包含 21 个字符。相同现有 Silero、原始连续 PCM 的逐帧重放在该区间只有三帧概率达到 0.5，最长连续两帧；三帧入口去抖未放行。101.09–102.91 秒概率最高仅 0.405，说明去抖不能解释全部缺口。独立布尔状态机复现准入区间；baseline 与实际 ASR owned 并集一致，除未评分的 EOF 14 ms 尾部外。原生分人的误报还有参考口径差异，未通过提高活动阈值或静音过滤掩盖。

模型输出前固定唯一候选：只让已解析为 Silero 的语音准入采用单帧入口确认，保留 0.5 入口、0.35 退出、请求的 900 ms 静默、300 ms 前缀与全部模型。能量 VAD 仍需三帧，不新增配置。先在既有双人、三人、四人自然音频做低成本筛查：前两者入口次数不变，四人 21→24，新增参考外准入占整段 1.1135%，四条原完全未放行的参考话语获得至少半段时长覆盖；逐人参考活动覆盖不下降。筛查条件为每源参考外增量 ≤2% 时长、入口次数比 ≤1.25，未扫描阈值。该阶段仅证明准入变化，不证明最终转录质量。

随后固定 `7a96fde0` 当前生产组合，对同一原始连续 181.23 秒四人会议执行两臂完整链路诊断。两臂各一次、全新三个 worker、1× 输入、20 秒 `full_segment`、同一 Qwen Q8、BF16 对齐器与 C0、实际资源治理和最终 metadata sink；候选仅在私有构造入口覆盖 `start_frames=1`。参考、评分、每人最多增加两个字符错误、普通拼接插入最多增加两个字符，以及正式文字 P95/推理物理上界比值 ≤1.05 均在输出前冻结。基线文字、拥有区间和对齐逐项复现上一轮同版本结果。

独立参考 742 字，按话语开始时间拼接的普通 CER 诊断错误 250→233（33.6927%→31.4016%，相对错误下降 6.8%），S/D/I 为 51/190/9→50/172/11；cpCER 357→351（48.1132%→47.3046%）。有 51 对跨人参考话语时间重叠，普通拼接 CER 的字符顺序存在歧义，仅作内容诊断；不作为顺序无关认证，也不从两种 CER 的差推导纯归属错误。四条独立参考文字流错误 96/15/61/129→97/14/60/119，一条增加一个错误，保留而不宣称逐人全胜。活动时间的整场匿名重叠匹配将最弱的 8.47 秒活动者对应到文字流 R2，其错误 15→14；该对应仍未经过新增真人核验。

完成区间 22→25，对齐单元 518→529；未知单元 50→49，但未知字符 56→61，不能只用单元数量宣称归属全面提升。实际原生活动帧完全相同，零 collar、包含重叠的紧致参考 DER/JER 仍为 28.3958%/27.7833%，miss/false-alarm/confusion 仍为 6.40/28.09/2.24 speaker-seconds。逐区间独立重建与评分器一致。目标候选的自动质量条件通过，整体分人认证未通过，新增文字与关键事实仍须真人复核。

首次非空文字 7.5182→7.5224 秒（含首段静默）；正式文字 owned-span P95 0.703698→0.707770 秒，比值 1.005786；结束至全部关闭 0.3997→0.3822 秒。四个精确进程寿命的推理阶段物理 footprint 保守上界之和为 9561825584→9567740136 bytes，比值 1.000619，零缺失采样，三个子进程均已 wait，八个 owned PID 均已消失。这不是同时总峰值、退出阶段峰值或纯计算 RTF 认证。未知单元保留完整权重，严格稳定归属 P95 仍为无穷；含未知的 owned-span 权重 67.07%→64.38%，稳定归属门仍失败。

生产实现仅按已解析的 VAD 引擎选择入口确认帧数，AST 比较证明相对冻结基线仅此一处语义变化，与私有构造参数对照一致；契约与用户 API 手册同步。十二个 fake 交互回归覆盖 auto/Silero/能量路径、单帧/两帧/三帧峰值及阈值以下的输入；旧实现四项按预期失败，其余八项通过。修改后共 82 项相关 fake 回归、Ruff、目标 strict Mypy 与 Realtime 契约校验（61 fixtures、65 tracked fields）通过。内存中过宽地把能量 VAD 也改成单帧会使两项回归失败，生产源码未被 mutation 改动，预检失败与最终验证日志均保留。真实音频和模型不进入 CI，测试不含本机性能阈值。

完整执行闭包在推理前后稳定，独立字符 DP 与匿名全排列复算、原始裁切字节、物理上界求和及进程回收检查通过。2026-10-19 05:52:45 UTC 独立核验原 managed 3.12.0 quality/quality 恢复，唯一 listener/LaunchAgent PID 41821、health/readyz/metrics 均 200、无活动请求或客户端，配置/selection/runtime target 摘要不变。两段共 34 秒、保留上下文的私人听音页已准备，只核对文字忠实度与插入/数字/否定问题，不要求辨认孤立短词的说话人。私有注册、原始输出、计分、复算和维护记录保存在仓库外 `asr-neural-onset-joint-20261019`；仅一个来源、每臂一次，无泛化区间或人数认证。本次不下载、安装、改 profile/selection 或接触留出，源码尚未安装，按本逻辑提交 revert 可回退。


## 客户端多词归属的行级压缩损失

2026-10-19：在已完成的神经 VAD 对照之后，优先检查用户实际读取的会议记录。当前 `RealtimeASRClient.mergedAttributionUnits` 保留每个对齐词的 uid、文字范围、采样范围与匿名标签；`MeetingSession` 却将同一 ASR item 的所有单元注册到一个持久化行。`SpeakerLabeling.apply` 对每个 uid 单独调用 `attachSpeakerLabel`，后者覆盖同一 `line.speaker_label` 标量；`attributedLabel` 从该行的无序 uid Set 返回第一个已写标签。因而多说话人段落会丢失逐词归属，内存显示还可能与已保存标签不同。该定位以当前 worktree 直接源码为准；另一个 checkout 的旧图谱只辅助定位，缺失／不可解析范围已直接读取。

从原文件逐字节提取 register、freezeAttribution、apply、attributedLabel 方法，使用 fake label 映射、观察与写入依赖编译成独立 Swift 探针。两个词分别为 A/B 时，产生两次覆盖写入，最终行标量为 B；12 次独立运行中 7 次内存查询返回 A。重复同批归属没有新的写入，不能自愈这一不一致。该证据是隔离生产方法复现，不是完整 App、SQLite 或 UI 验收，也不是以运行次数估算真实用户发生率。

复用已有真实候选的最终逐词 metadata 与完整文字坐标，单人前缀 2 段中没有混合标签；双人 16 段有 3 段包含多个已知标签，涉及 272 个规范化字符；三人 10 段全部包含多个已知标签，涉及 1040 字符；四人 25 段有 15 段，涉及 507 字符。已知与 unknown 同段的数量分别为 0/3/7/11。上述数字只表明单标量无法保留已有归属的范围，不把段内所有字符算成错标，不新增 CER/cpCER 或真人真值结论。仅按最终单元分组，没有伪称完成全部事件时序的 App 重放。

后续生产修复必须保留逐词归属及修订坐标，使用同一持久化依据驱动会中显示、会后记录和导出，不能仅固定取第一个／最后一个标签或按多数覆盖全段。原转录行 ID、完整正文、原有引用和用户手工标注必须保留；新辅助记录采用可回滚的追加式迁移，只在临时测试库验证，不自动迁移用户实际数据库。首先补齐混合标签、known/unknown、迟到修订、断线换代、保存失败与重开一致性的回归，再用已保存真实事件验证客户端不丢失服务端已有证据；无需为这一客户端缺陷重复模型推理。

本次仅检查已有制品与生产源码，未启停服务、运行真实模型、接管 UI、安装或访问留出；生产修复尚未实现。原始来源摘要、逐段聚合与编译探针结果在仓库外 `client-line-attribution-loss-20261019`，不提交完整转写或音频。


### 逐词归属的持久化增量

2026-10-19：先交付接收／显示接线所需的真实存储能力。`TranscriptAttributionUnit` 保留 uid、Unicode scalar 文字半开范围、可选 wire 采样范围和可空匿名标签；`TranscriptLine.speakerRuns` 保证拼接为完整原文，未对齐正文不借用邻人的标签。`SessionStore.attachTranscriptAttribution` 在单个 actor 操作及 SQL 更新中替换完整快照，越界、重复 uid、重叠或非法采样范围在写前拒绝，保留原证据。行标量仅是单一已知说话人的汇总，详细归属始终另存。

记录库 schema 13→14 通过既有迁移事务追加 `attribution_json` 与 `speaker_label_is_manual`，旧行的正文、标签、ID、时间与引用不回填或重写；不猜测旧标签是否由人工产生。人工标量标注与人工清空优先于迟到自动快照。迁移失败事务回滚；已经升级到14的库不能只靠回退旧二进制降级，须保留新库并使用升级前备份。这里只操作自动生成的临时数据库，没有升级实际用户数据库或安装 App。

五个新存储回归覆盖 Unicode/多标签、分页/范围/搜索/重开/备份恢复、非法快照不改原证据、未知与迟到修订及人工覆盖、13→14 保留旧行，以及空快照清除旧汇总；其中备份与手工清空分别纳入相关用例。首次接口回归因缺类型和保存入口而按预期编译失败；补充迁移用例时一次参数顺序错误导致未执行，修正后验证才计入结果。最终生产源的29项确定性相关回归通过；此前另5项时间标注回归在相同存储行为下通过，不将其并入最终组计数。

另以已冻结1–4人候选的原始正文、对齐及最终 metadata，只重放实际存储层：53段、2323个逐词单元写入临时 SQLite 并重开后逐项保持，全部分段拼接仍等于原文。私有重放测试与29项确定性回归同次执行，共30项、零失败；真实正文不进入仓库或测试输出，私有驱动与输入保留在仓库外 `client-word-attribution-storage-20261019`，临时测试源未进入交付或CI。完整输入哈希及最终源哈希复核通过，双测试目标登记检查通过。

本增量尚未把实时 receiver、`SpeakerLabeling`、会中／会后显示和导出接到新快照入口，不能声明客户端缺陷已修复或人数质量认证通过。下一增量须取消逐词覆盖整行标量的自动路径，冻结完整行快照并处理迟到／换代／失败，随后用相同真实事件确认文字与已有标签均能到达用户读取的结果。此次没有模型推理、服务操作、UI接管、安装或留出访问。


### 会议与字幕的完整归属快照接线

2026-10-19：会议与字幕共用的 `SpeakerLabeling` 自动保存入口由逐词标量覆盖改为完整逐行快照，`SessionCoordinator` 转发到已有原子存储接口。接收端冻结文字范围、采样范围及匿名标签后排队，不在执行时重查新场坐标；成功后以存储返回的实际行刷新内存，完整输入仅在成功后用于去重。完整接收快照替换旧 uid 集，直接按 uid 提交的局部修订则合并该行其他单元；映射前按文字坐标稳定排序。未知标签保留，缺少文字范围或重复 uid 的批次不替换当前投影坐标。旧生命周期命令只写冻结的旧行，不填入新场投影。退休清除索引及已保存投影；分页读回保留逐词归属与人工覆盖字段。

人工整行标注由存储返回实际行，同步更新去重缓存的投影；随后即使重复到达相同自动快照，也不能恢复旧标签。新增三项生产路径回归先复现多人压缩、局部未知修订丢失及自动覆盖人工选择，共七个断言失败；另加“人工修改后原样自动重推”的回归，先复现内存仍显示旧标签，再修正缓存刷新。保存失败可重试且不形成去重证明、范围缺失保留原证据也有回归。部分原生命周期 fixture 只有标签和时间质量，按其合成正文补齐真实文字范围；缺少范围的后续辅助输入仍拒绝并保留已接纳归属，没有通过猜测整句范围补位。

最终115项相关 XCTest（会议63、字幕38、归属14）与8项 Swift Testing（含容量和窗口合并）通过；附加私有快照重放同次执行，XCTest合计116项。私有驱动最初因 await 放入 XCTest 同步 autoclosure 而未编译，修正后结果才有效。仓库包装脚本的完整 unsigned App build 成功，临时 DerivedData 与 App 产物已确认清理；没有运行 App、UI 自动化或安装。测试目标登记通过，最终编译与验证对应源哈希一致。

同一批既有1–4人开发输出的53段、2323个最终词单元，通过实际 `SpeakerLabeling.freeze/register/apply` 与临时 SQLite 重放；每段重复输入一次。全部词标签、文字与采样坐标保持，内存投影逐行等于已保存行，28个多已知标签段不再伪装为单一说话人；重复输入没有额外写入，退休后单元索引与投影均释放。此为每段一个冻结末态快照的重放，不是完整模型事件时序、麦克风或UI验收。

对照从2913573f逐字节提取的原生产方法、只替换写入依赖并使用相同53份末态快照，首次标量保存回调为2248次；候选实际完整快照保存为53次。原方法单次执行的53行中有14行内存标签与最后保存标量不同，候选全部投影与存储一致。基线 Set 查询次序不稳定，14不能解释为用户发生率；该对照也不证明真实端到端延迟、SQLite峰值或模型质量提高。75个未知词单元保持未知，未借此扩大已认证人数。输入、原方法及最终源摘要与报告保存在仓库外 `client-word-attribution-owner-20261019`；真实输入和临时私有测试源不进入交付或CI。

源码注入入口随职责更新：会议／字幕依赖的 `attachSpeakerLabel` 改为 `attachTranscriptAttribution`，`SpeakerLabeling` 的 `attachLabel` 改为 `attachAttribution`，回调接收完整快照并返回实际行；仓库调用和测试已同步，不保留旧标量自动写入别名。人工标量标注入口继续独立存在。未改变REST、Realtime wire协议或模型；没有服务、安装、用户实际数据库或留出操作。会中／会后逐段呈现、导出和完整真实事件时序尚待接线验证，客户端损失修复与整体目标均保持未完成。


### 逐词归属的文字与字幕导出（2026-10-19）

`SessionExporter` 的 Markdown、纯文本和 SRT 使用逐词证据，混合发言不再因整行标签为空而失去归属。
未知正文明确显示未确认；标点、空白不单独生成未知段，相邻同标签段合并。正文、行身份和原 SRT cue
时间不变；人工整行覆盖及没有逐词证据的旧行保持其语义。JSON 在原 export/1 字段上追加完整单元及人工标志。

- 确定性反例：原实现的混合行导出测试出现 6 个失败断言；修复后相关 16 项 XCTest 通过。
- 仓库外既有自然 1–4 人开发结果的 53 条最终快照、2323 个归属单元，经实际临时 SQLite 与生产导出器重放。
  纯文本投影拆去排版前缀后逐字符重建原正文；2405 个已知正文 scalar 的标签及 93 个未知正文 scalar 均保持。
  原整行导出会丢失其中 1827 个已知正文 scalar 的标签；这是已有归属证据的传递损失，不代表这些标签都是真值正确。
  JSON 的 uid、范围、标签及可选采样范围逐项一致；每个原行仍只有一个 SRT cue。
- 私有证据：`client-word-attribution-export-20261019` 下的登记、输入哈希、临时测试源、结果和验证日志；
  原文及原始制品均在仓库外，CI 仅执行合成文本回归。私人重放测试另计 1 项通过。
- 本增量没有运行模型、停止服务、安装 App、修改用户数据库或执行 UI 自动化。
  会议实时与会后界面、复制、知识归档仍需分别接线验证；模型质量、完整事件时序和整体目标尚未验收完成。


### schema 14 的测试版本同步（2026-10-19）

PR 在 `62263ba5` 的 Swift Package Tests 因仍断言 `SessionStore.schemaVersion == 13` 失败。
本机定向复现进一步确认，两处旧的版本钉定分别影响事务窗口与纪要迁移测试；同步为 14，
保留数据、幂等、回滚、纪要及引用行为断言，未改变迁移或生产实现来迁就测试。
完整 `swift test --package-path macos/SpeechRailApp` 执行 1771 项 XCTest（1 项既有显式启用的
人工关键帧导出跳过）及 658 项 Swift Testing，均无失败；独立 LLM support 编译边界检查通过。
这覆盖本增量与先前 schema 变更的本机确定性回归，远端 CI 须以新提交重跑结果为准。


### 会中、会后与复制的逐词呈现（2026-10-19）

会议列表按共享 `displaySpeakerRuns` 显示混合发言：一个原行可呈现多个已知／未知分段，
正文、行 ID、原时间码不变。会后编号、姓名筛选和含说话人的单句／全文复制读取全部标签；
纯正文复制保持原文。未知段的人工指定菜单明确写明“整段指定为”，仍是已有整行人工覆盖语义。
导出与界面共用排版分段；原始逐词证据保留其未知标点范围，不把排版当作声学真值。

人工标注后只刷新当前会话中真正变化的可见行；修订记录失败时同样显示已保存归属，保留错误提示。
两个生产反例先出现 3 个与 2 个断言失败，修复后通过；覆盖直接由标注面板调用 owner、无需等待下一事件。
新增 Unicode、混合／未知、原文字坐标、显示名、人工覆盖及旧行复制回归。

仓库外既有 1–4 人的 53 条最终快照、2323 单元，通过实际临时 SQLite、会中行、会后行及复制格式器重放：
两种显示投影一致，正文逐字符重建，2405 个已知正文 scalar 的标签与 93 个未知正文 scalar 保持，
复制与导出一致。135 项相关 XCTest（其中 1 项为仓库外私有重放）与 8 项 Swift Testing 无失败。
无签名完整 App 由仓库包装脚本编译通过，独立 DerivedData 清理已核验；未启动 App 或执行 UI 自动化，
不能据此宣称窗口排版、辅助功能交互或用户体验实测完成。私有证据目录为
`client-word-attribution-presentation-20261019`，真实正文与私有测试源不进入仓库或 CI。

本增量没有运行模型、改服务、安装或迁移用户实际数据库。知识归档、完整真实事件时序及整体认证仍需继续。

最终完整 Swift 包测试执行 1775 项 XCTest（1 项既有显式启用的人工导出测试跳过）及
658 项 Swift Testing，零失败；最终源哈希与私有重放、App 编译时的生产来源一致。


### 定稿与归属事件的客户端链路重放（2026-10-19）

对生产提交 `cd5f9066` 使用同批自然 1–4 人开发结果验证实际客户端链路，而非只写最终快照。
其中 1 人条件仅为多人会议中的 36.05 秒单人发言前缀，不代表独立完整单人会议；其余为既有 2–4 人开发片段。
同次制品的最终正文按原 item ID 恢复，并逐项核对已记录的正文长度；保留 227 条
`segment_closed`、completed、alignment 和 diarization 更新的相对顺序及其采样、文字坐标与标签。
实际 `RealtimeASRClient` 通过 fake socket 解析，再由实际 `MeetingSession`、保存 owner 和临时 SQLite
接纳，最后经实际 drain、分人终态、归档协调器与连接关闭路径结束。

- 4 个条件共 53 条正文、2323 个归属单元与此前冻结的同源最终结果逐项一致；
  当前可见行与落库归属一致，显示分段拼接等于原正文，四个临时记录均归档且 socket 关闭。
- 1 项仓库外私有 XCTest 通过。临时扩展在验证后精确移除，原测试源 SHA-256 恢复一致；
  测试目标登记检查通过。真实正文、事件与私有测试源均不进入仓库或 CI。
- 首次夹具未开启会议 opt-in，得到 0 个归属单元及失败断言；开启独立临时偏好中的分人后通过。
  该失败证明的是夹具配置与期望不一致，不作为生产缺陷或修复收益。失败制品保留并明确标为失败。
- 边界：原制品的 508 条中间假设只有长度，无法恢复，因此未重放；握手、传输 envelope 和
  零上传的 commit receipt 为合成。分人 done 在测试 finish 命令后投递；加速投递不保留原墙钟等待。
  本验证覆盖经典定稿／匿名归属模式，不覆盖 revision window、dynamic capacity、完整原始流、
  真实网络、麦克风、模型重跑、端到端延迟、资源或真实 UI。没有据此新增人数认证。

私有证据目录为 `client-terminal-event-replay-20261019`，包含源制品哈希、预登记、输入、实际测试扩展、
失败与通过日志、结果及最终生产源哈希。没有修改服务、安装、profile、selection 或用户实际数据库。
生产提交 `cd5f9066` 的远端 CI 八项检查在本次核验时均为 SUCCESS；后续提交按其自身 CI 结果判断。

另外，当前 `ArchiveLine` / `TranscriptLine.archiveModel`、归档包导入及可读归档仍只有整行标签，
逐词证据不会随知识归档往返；这是已确认但尚未实施的后续生产修复范围。


### 知识归档的逐词证据与人工覆盖往返（2026-10-19）

分享包和完整归档保存所含行的逐词范围、匿名标签、可选采样时间与人工整行覆盖状态；
人工清空不被迟到自动归属覆盖。Markdown 使用既有共享呈现规则，未知正文仍为未知。
归档 payload 升为 /4，必需字段缺失、非法范围／时间、重复单元、人工与自动证据冲突及摘要不一致
均在写库前拒绝；旧 App 拒绝新格式，避免静默损失。既有 /3 包保留历史整行标签，不猜测
当时未存的逐词或人工来源，不改写原包；/2 仍因正文出处与修订血缘不足拒绝。
数据库保持 schema 14。本增量不迁移、打开或修改用户实际数据库。

往返反例先暴露导出／导入缺字段；修复后另由真实开发结果的重复导入发现冲突读取查询遗漏字段，
同一包被误判冲突。新增直接查询与幂等断言复现 4 个失败后，统一复用完整 storedLine 读取。
合成回归覆盖两种包、人工指定／清空、迟到更新、相同导入幂等、仅逐词变化冲突及非法包无部分写入。

仓库外既有 53 条最终快照、2323 个单元经实际临时 SQLite → 归档写出 → 解析 → 新库导入往返，
正文与单元逐项一致，75 个未知归属单元保持未知；相同包重复导入无新增行，引用检查干净。
44 项相关合成 XCTest 和 1 项私有重放零失败。私有目录为
`client-word-attribution-archive-20261019`，包含预登记、输入哈希、失败／通过日志、测试源和结果；
临时私有测试源精确移除，不进入仓库或 CI。该证据证明归档不再丢失已有归属，不证明模型标签正确或新增声学收益。

本增量没有运行模型、操作服务、安装 App、改 profile／selection 或执行 UI 自动化。
回退可撤销本主题提交；保留 /4 原包，使用支持该格式的 App 导入，不能手改 schema 降级。
工作区另有 6 处不属于本主题的并行改动，原样保留，不纳入提交；完整 Swift 验证包含其中的
SpeakerLabeling 与 MeetingRecoveryMaterialTests 改动，须与本主题独立区分。

最终完整 Swift 包回归执行 1778 项 XCTest（1 项既有需显式启用的人工关键帧导出跳过）与
658 项 Swift Testing，零失败；测试目标登记检查通过。无签名完整 App 经仓库包装脚本编译通过，
隔离 DerivedData 已清理，相关生产与测试源哈希前后一致。未作真实窗口与辅助功能交互验收。


### 神经入口修复后的剩余内容损失定位（2026-10-19）

复用四人场神经入口两臂的既有最终正文、owned-span 事件与独立文字参考，没有再次推理。
按相同 NFKC/casefold 与 Unicode L/N/M 口径，完整字符 DP 复现 250→233 个错误。
六种最短路径回溯优先序给出基线 D=189–190、候选 D=170–172；既有报告的
51/190/9→50/172/11 是其中一种确定性路径，不是唯一 S/D/I 分解。总错误不受该歧义影响。

按完整参考话语统计，其文字落在完整／部分／零 owned-span 覆盖的字符数从 695/23/24
变为 726/9/7。没有将话语时间插值成逐字时间，也没有把句级范围当作发声真值。
候选六种回溯中，完全未覆盖话语均分配 7 个删除、部分覆盖话语均为 3 个，完整覆盖话语为
160–162 个。150–153 个删除位于与其他人参考话语有时间交叠的话语内；这是关联性分类，
受跨人文字拼接顺序影响，不能据此认定重叠导致全部漏词或解释为纯模型错误。
独立滚动行 DP 与 24k 精确样本位图覆盖复算两臂总错误及三类参考字符计数，结果一致，输入摘要未变。

据此不为剩余删除继续降低 VAD 门限。非重叠且六种回溯均分配删除、同时完整送入 ASR 的
161.60–162.19 秒有三个删除，但内容类别检查确认它是同一应答字重复三次，暂不优先为此实跑。
下一解码定位优先选择 32.94–34.35 秒的八字符完整话语（一个删除），对应实际
32.640–35.264 秒 VAD 封存区间；随后为 46.59–47.07 秒的三字符话语（一个删除）。
这些只作为检查 decoder 实际上下文与正文处理的入口，不因参考含词就给模型提示或强行补词，
也不以改标签恢复缺失正文。类别检查未向报告写出原文，不能代替真人内容复核。

私有证据 `neural-onset-residual-content-20261019` 保存冻结输入摘要、一次性诊断源、六种回溯、
逐话语匿名时间计数及独立复算。初始诊断记录写三个回溯序，执行枚举全部六种排列，差异在单独
执行说明中保留，原记录未改写；这是事后探索性定位，不是候选预登记或质量验收。
本次没有生产代码、模型、服务、安装、实际用户库或留出操作，六处并行改动保持原样。


### 已封存话语的原始解码与上下文对照（2026-10-19）

对预先选定的 32.94–34.35 秒自然 far 话语，使用既有原始 channel 0，固定裁取实际 owned
32.640–35.264 秒及前后各加 500ms 的 32.140–35.764 秒两个输入，共 6.248 秒。
现有 Qwen Q8 模型摘要与神经入口联合对照一致，auto 语言、空 prompt、256 上限，每输入一次，
实际动态预算 39/45；没有提供文字参考、热词或人数。两次均完整 EOS，原始解码逐字相同。
原区间经冻结的原 ITN 后逐字复现原联合正文；原 ITN 与当前 ITN 均未改动该原始输出。
因此本例的缺失不由 ITN 造成，固定增加 500ms 上下文也未见收益，停止扩大这一上下文搜索，
不据此修改生产或宣称其他上下文均无效。八字符目标话语的独立局部编辑错误均为 2；
上轮“一个删除”仅指全场对齐在此话语分配的删除数，不代表该话语总错误为 1。

实际独立 vendor Python 调用生产 Qwen3Engine，非公共 API／完整 Realtime／安装态质量验收。
两次解码结束、subprocess.run 已返回且完整闭包复核后，驱动错误访问 CompletedProcess.pid，
收尾记录写出前以 AttributeError 退出，空 integrity.json 与失败日志保留。未重复推理；
另行只读重算冻结闭包摘要一致，实际两份 EOS 结果仍可检查，但不把该驱动 exit 1 写成全程成功。
进程已等待退出的判断依据是执行到 subprocess.run 返回后的语句，未补造无法回溯的子进程 PID。

无活动请求／客户端后 managed 停服，一个窗口完成两次调用并恢复。独立恢复检查确认唯一
LaunchAgent／listener PID 73875，原 3.12.0 quality/quality，health/readyz/metrics 均 200，
batch/realtime active 为零、无 ESTABLISHED 客户端，配置、selection、runtime target 摘要不变。
本例不提供时延、RTF 或资源门证据；没有下载、安装、切档、改生产源码、实际用户库或访问留出。
私有输入、冻结来源、原始输出、失败与独立复核存于 `asr-residual-owned-decode-20261019`。
