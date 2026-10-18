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
