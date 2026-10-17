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
| E0 | 候选摘要漏后处理，oracle 指标误名 | T1/T2 定向测试及身份拒绝验证，待实施 |
| E1 | 原作者报告机制测试通过，未由本会话复验 | T3 独占 owner、故障/队列/预算回归，待实施 |
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
| T2 | 待实施 | 评分口径与独立交叉校验 |
| T3 | 待实施 | owner、隔离、队列和预算 |
| T4–T6 | 待实施 | fake/preflight 可先交付；真实模型/评测另行授权 |
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
