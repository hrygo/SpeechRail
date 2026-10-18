---
title: "会议转录与分人接手及实施记录"
status: active
date: 2026-10-18
---

# 会议转录与分人接手及实施记录

用户于 2026-10-18 批准[设计](../superpowers/specs/2026-10-18-meeting-asr-diarization-research-design.md)和[实施计划](../superpowers/plans/2026-10-18-meeting-asr-diarization-implementation-plan.md)，授权提交方案并在同一 PR 持续实施。全部工作由主代理执行，不使用 subagents。真实模型、语料、运行态、安装和发布遵循计划中各自的执行条件。

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
