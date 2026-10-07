---
title: "Issue #238 契约、MCP、文档与代码追加审计"
status: active
version: "1.0.0"
date: 2026-10-07
---

# Issue #238 契约、MCP、文档与代码追加审计

原十一项共 91 条的[验收矩阵](2026-10-07-issue-238-final-acceptance.md)记录的是 R01–R10
在 `6f91c25d` 的交付证据。本次重新核对公共契约、MCP 工具与打包 skill、正式文档、
生产接线和错误路径，确认两项实际缺口；原关闭状态不能代替这两项的补修证据。
每个补修包仍只关联 1–3 个 issue，合并须匹配最终 head 的必要 CI 和独立审查。

## 发现与修正

| 包 | 发现 | 修正与回归 | 关联 |
|---|---|---|---|
| A01 | TTS 回收失败初次不可重试，后续隔离准入却被解释为可重试队列满；MCP 恢复指南漏同步 | 隔离异常独立类型；REST、Realtime、MCP 保留 `backend_reclamation_failed`，REST `503/retryable=false`；打包 skill 与门禁包含恢复指引。补串行策略下 ASR 同样被阻断的契约与真实 fake HTTP 回归 | #235/#238，[PR #335](https://github.com/hrygo/SpeechRail/pull/335) |
| A02 | force/TTL 吞掉 close 异常后仍报 cold；transport 在 terminate/kill/wait 失败前已摘掉旧 owner，可能启动替代 child | 共享 lease 标记 `reclamation_failed` 并拒绝新 lease；活动和 TTL 不解除隔离。transport 保留 process/stderr owner，禁止 start 与 I/O；显式再次 close/reap，或 lifecycle 确认全部物理 owner 成功关闭后解除。取消等待者不丢失已完成的关闭结果 | #240/#246/#238，[PR #337](https://github.com/hrygo/SpeechRail/pull/337) |

A01 最终 head `262d5aad94d97f6ef23a07843a0af8664b13de70` 的 CI run `37592748454`
全部成功，于 UTC `2026-10-07T08:22:50Z` squash 合入 `ebe42872a792f4e5c60fb14fcc8365ce2aafce4a`。
A02 以该合并提交为源码基线；其最终 head、CI 和合并提交以关联 PR 时间线为准。
本报告中的本地验证不提前声明远端合并通过。

正常 transport close 原本就会 terminate→wait、超时 kill→wait。本次修正只针对回收异常、
结果未确认的路径，不能描述成所有 close 都未等待进程退出。`alive` 表示 transport 可用性；
关闭中或失败后不可用，不等于资源已经回收。内部 owner 必须保留到 reap 确认成功。

## 回收与恢复合同

- idle/force close 与新 lease 接纳共用同一 admission lock，活动 alignment/TTS 不被驱逐。
- close 抛错、被内部取消，或成功返回但仍报告 alive/ready，进入 `reclamation_failed`；
  不发布 `cold_evict`，不递增 lease 代次或 active 计数，touch 和自动 TTL 不恢复该状态。
- 显式 `force_evict` 再次执行 owned close，成功确认后才能标记 cold 并允许新的 lease。
  `alive/ready=false` 不能替代 close 确认。调用者取消时仍 join owned cleanup；
  已成功关闭的 worker 记录为 cold，随后向等待者传播取消。
- transport 失败期间不复用旧管道、不 spawn 替代 child；显式 close/reap 成功后才能 start。
  该恢复合同不新增自动服务重启、第二个模型 owner 或额外并发 lane。
- 同一 `RuntimeLifecycle` 关闭后再启动的既有语义保留：先 join monitor/runner/全部物理 owner
  的 close，成功后调用 evictor 的明确 shutdown 确认，恢复全部 tracked lease，包括 router
  拥有、evictor 单独跟踪的 design 子 worker。任何关闭失败/取消/超时都不解除隔离；
  monitor.close 或属性变为 false 本身不足以确认。
- alignment 的受管调用保留 `alignment_unavailable` 失败结果；共享 lease 的 TTS 消费者保留
  `backend_reclamation_failed`。公共 REST/MCP 的不可重试和操作者恢复指引由 A01 同步。
  `describe()` 成功本身不证明隔离解除。

## 实际验证证据

核验日期为 2026-10-07（Asia/Shanghai），CI 时间为 UTC。各组范围存在重叠，数量不可相加
为唯一测试总数。

| 范围 | 结果与局限 |
|---|---|
| 审计初始 Python 联合回归 | 478 passed；1 个既有 asyncio 弃用警告 |
| 审计初始 Swift 联合回归 | 422 XCTest / 0 failures，另 35 Swift Testing；非 UI 自动化 |
| 契约与静态门禁 | OpenAPI、Realtime、MCP 工具/资源/打包 skill、用户文档、当前边界、运维文档、版本、macOS target coverage、route、独立 LLM 支持层检查通过 |
| A01 红绿 | 连续两次 HTTP 故障反例 8 failures；MCP hint/名单防漂移 4 failures。最终 442 passed，独立审查的 ASR 契约 Required 已修复 |
| A02 红绿 | 先确认 8 个旧实现反例失败；加入 TTS 接线后，一次性源码副本选择旧 lease/transport，9 个反例全部失败。独立审查再补同实例 lifecycle 恢复，修订前 3 failed / 2 passed；最终 389 passed，1 个既有 asyncio 弃用警告 |
| A02 扩展接线 | 生产 FixedTextAligner 的隔离失败/恢复；TTS open 在 idle close 失败后返回隔离码；同实例 alignment/TTS lifecycle 成功关闭后恢复、失败不恢复、父 owner 确认关闭后恢复子 worker；共享 ASR、governor、MCP 及原 worker 回归保留 |
| Python 静态检查 | Ruff 全 `src tests scripts hatch_build.py`；Mypy 全 `src`（171 个源文件）。无新增依赖或产品能力 |

A02 的首轮扩展回归曾出现 3 个共享 ASR 恢复失败：保留 owner 不能改变 transport 关闭即不可用的
语义。修正 `alive` 的可用性表达后，384 项联合回归通过。完整 diff 独立审查的唯一 Required
是同实例 lifecycle 成功关闭后未清隔离；新增 alignment、TTS 与 parent/child 三个红灯，
补成功确认接线后扩大为 389 项通过。所有失败记录属于本地反例和中间版本，不隐去失败过程，
也不将既有弃用/编译警告写成零警告。

## 审查范围、并行保护与未验边界

契约/MCP、文档证据和生产代码由独立只读审查分别核对；主代理复核当前源码、索引覆盖与
回归结果。图谱 root 是 `/Users/hrygo/Documents/SpeechRail`、generation 是
`2026-10-05T14:42:25Z`，与审计 worktree 不匹配；部分文件已变化或未跟踪。
关键结论以当前源码直接回读补足，不把图谱无命中当作无调用或无缺陷。没有重建索引。

#245 已按用户确认完成，无临时避让要求。03cf 中另一任务的 README、Realtime 与文档 WIP
得到用户明确确认；本补修使用独立 worktree 和独立 uv 环境，完整保留该任务的修改。
本报告与 r2/最终矩阵为审计源文档；一般架构入口的并行修辞修改未混入本包。

本轮只证明上述结构、公共错误语义、确定性故障和文档一致性。没有运行真实模型、真实音频、
真实 LLM、前台 UI 自动化、性能/声学基准或长稳验收；没有操作生产服务、模型、用户数据库、
安装或发布。App 编译、fake backend、合成字节和临时 SQLite 不代替这些证据。
回退使用关联 PR 的 revert PR，重新验证对应回归；不清数据、不放宽准入、不 force-push。
