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
