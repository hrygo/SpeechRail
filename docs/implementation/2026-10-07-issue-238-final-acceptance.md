---
title: "Issue #238 十一项最终验收证据矩阵"
status: active
audience: "维护者、架构审查者"
version: "1.0.1"
date: 2026-10-07
---

# Issue #238 十一项最终验收证据矩阵

核验时间：2026-10-07，Asia/Shanghai。代码基线为 R10 合入后的 `5c7590b0`；精确包 head、CI run、红绿日志与审查取舍见 [loop r2 账本](2026-10-07-issue-238-solid-loop-plan-r2.md)。原 9 包 + R10 #242 补证，逐包独立 PR；每包 1–3 issue，非堆叠交付。

本矩阵逐条对应十一项 issue 的 **91 条验收要求**，不计“愿意贡献”勾选。`T` 表示实际定向确定性测试，`CI` 表示匹配包最终 head 的选中门禁，`M` 表示有界生产突变导致测试转红，`S` 表示当前源码/合同静态核对。组合标记不表示整条都是实验实测。计数是各包/联合套件的运行结果，存在重叠，不相加为“唯一新增测试数”。

所有测试使用 fake backend、合成响应/字节和临时 SQLite；没有生产服务、模型下载/加载、真实音频/LLM、钥匙串、用户数据库、安装/发布或 UI 自动化操作。真实声学质量、性能、长稳、屏幕观感和 VoiceOver 不属于本次通过证据；其他团队的 #245 和相邻八项不因本矩阵改变归属/状态。

## 合并与门禁

| 包 | Issue | PR | main squash | 定向证据 |
|---|---|---|---|---|
| R01 | #244 | [#320](https://github.com/hrygo/SpeechRail/pull/320) | `451aeb1e` | 127 定向 Python |
| R02 | #240/#246 | [#322](https://github.com/hrygo/SpeechRail/pull/322) | `1edf9398` | 99 定向 +28 HTTP/lifecycle |
| R05 | #242 | [#323](https://github.com/hrygo/SpeechRail/pull/323) | `ff34bfcf` | 42 定向 Swift |
| R03 | #235 | [#325](https://github.com/hrygo/SpeechRail/pull/325) | `baafb59b` | 372 定向 Python |
| R04 | #237/#236 | [#328](https://github.com/hrygo/SpeechRail/pull/328) | `151297f6` | 283 Swift +2 Python；独立 type-check |
| R06 | #241 | [#329](https://github.com/hrygo/SpeechRail/pull/329) | `4f6b7356` | 138 XCTest +77 Swift Testing |
| R07 | #232 | [#330](https://github.com/hrygo/SpeechRail/pull/330) | `c997f7b0` | 228 XCTest |
| R08 | #231 | [#331](https://github.com/hrygo/SpeechRail/pull/331) | `cb77d296` | 293 联合 XCTest；App build |
| R09 | #234 | [#332](https://github.com/hrygo/SpeechRail/pull/332) | `df8bb539` | 241 pytest；Ruff/Mypy |
| R10 | #242 | [#333](https://github.com/hrygo/SpeechRail/pull/333) | `5c7590b0` | 60 XCTest；2 次 mutation 检出共5 failures |


每包均完成一次整包独立审查；Required 由主代理补反例统一修复，按影响复验并等最终 head 必要 CI，之后 squash 合并。main 保护回读要求线性历史、strict base、Quality Gates 与 Gate Summary；没有 force-push 或绕过保护。R10 CI 为 `37583882519`（head `01e69f45`）：Swift Package Tests、App Build、Quality Gates、Gate Summary 均通过，Python/wheel 按 scope skipped。

## 逐条验收


### #244

证据入口：`tests/test_local_file_processor.py`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | 一次/多次短写后字节与长度精确一致，只有完整发布才返回引用。 | **T**：test_write_artifact_retries_short_write_until_complete + run_once 联合字节回读 |
| 2 | 零写、部分后异常有界退出，无半成品 final、描述符或 staging 泄漏。 | **T**：stalled_write / mid_write_failure：无 final/staging，关闭 descriptor 的 finally |
| 3 | close、同步、chmod、rename 失败都不进入 completed，诊断保留固定错误分类。 | **T**：publish_failure 参数化 close/fsync/chmod/replace；固定 job_artifact_incomplete |
| 4 | 发布前中断与发布后数据库提交前中断分别覆盖；恢复不删除其他 job 或重复截断有效结果。 | **T**：restart_between_publish_and_database_commit + recover_interrupted；独占 staging |
| 5 | 同 job 重试保持旧/新完整制品与数据库引用一致；失败不先破坏仍有效的旧结果。 | **T**：publish_failure_preserves_previous + reentrant_publish + completion 回读 |
| 6 | PCM 和 JSON 均用合成字节验证真实文件；不只断言引用字符串。 | **T**：speech_artifact PCM 字节、transcription JSON 内容与完整文件 |
| 7 | 路径、符号链接、权限、大小上限、PCM 验证、TTL/取消的已有防护继续成立。 | **T+S**：既有路径/symlink/大小/PCM/TTL 回归保留；取消和状态提交边界核对 |
| 8 | 复用 test_local_file_processor.py、job runner/repository 和 job artifact 测试，增加文件发布与状态联合故障回归；没有运行的验收继续保持待办。 | **T+CI**：R01 127 项定向；匹配 head 必需 CI；实际临时文件与 repository 联合 |
| 9 | 日志不含转写、音频、完整输入路径或秘密。 | **S**：JobProcessingError 固定分类，runner 日志无 content/input_ref；未宣称真实日志采样 |



### #240

证据入口：`tests/test_runtime_lifecycle.py、tests/test_application_composition.py、tests/test_worker_lease.py`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | idle 开/关两种配置，已用独立 aligner 都由明确 owner 关闭并等待；未用懒资源不被加载。 | **T**：alignment_is_owned_without_eager_loading；两配置关闭 owner，未用不 start |
| 2 | shared ASR 与 TTS router/child 的 start/close 次数和归属正确。 | **T**：shared_lifecycle_starts_and_closes_physical_worker_once；router/child 去重 |
| 3 | runner 在 claim/complete/fail 等持久化步骤已异常结束，shutdown 仍执行全部必要回收并保留原因。 | **T**：failed_runner_does_not_skip_workers_and_reports_failure |
| 4 | monitor.close、单个 worker.close 失败或反复取消等待者，不跳过其他 owner；已失败/未确认状态不伪装成功。 | **T**：monitor_and_worker_failure + repeated_waiter_cancellation + cleanup report |
| 5 | recovery、后续 worker.start、runner 创建后 evictor.start 等部分启动失败均有对称回滚和有界等待。 | **T**：partial_start_failure + already_created_runner_task 回滚 |
| 6 | 重复 close、在途 alignment、shutdown 期间新接纳及清理超时有明确结果，无旧任务覆盖新 owner。 | **T**：timed_out_cleanup_keeps_handle；重复 close/新接纳与 owner 状态核对 |
| 7 | 复用 test_application_composition.py、test_worker_lease.py 及 alignment 回归；新增失败 Gate，不能只断言正常 close 被调用。 | **T+CI**：runtime_lifecycle / worker_lease / application_composition 与 alignment 生产接线 |
| 8 | 不新增常驻模型、并发 lane 或内存预算承诺；alive/ready/warm/曾加载保持区分。 | **S**：owned/eager 分离；未改 catalog、lane 或 governor；ready/alive 不混用 |



### #246

证据入口：`tests/test_alignment_worker_activity.py、tests/test_worker_lease.py`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | 热重用、执行时间超过 TTL 但未超过请求 deadline 时，idle tick 不关闭在途 process。 | **T**：production_aligner_is_protected_during_warm_exchange 的 TTL Gate/热重用 |
| 2 | 首次懒加载、回收后重启、min-uptime 正常；不新增下载/预热。 | **T**：lazy_load、idle 后 restart、min_uptime 与 cold worker 回归 |
| 3 | 回收决定前后与新 lease 接纳前后设置 Gate，禁止已接纳任务被过时回收动作关闭。 | **T**：request_waits_for_decided_eviction_before_restarting_worker；共享同一 lease lock |
| 4 | queue-full、不曾进入执行的取消、执行异常、deadline、无效结果都正确回收 lease，未确认清理时不复用旧实例。 | **T+S**：原 alignment 错误/取消/deadline/queue 回归；追加审计纠正 idle close 失败缺口，force/TTL 隔离、进程 owner 保留、禁止 start/I/O、显式确认后恢复由 A02 故障回归补证，见[追加审计](2026-10-07-issue-238-alignment-audit.md) |
| 5 | force_evict 不关闭活动 alignment；shutdown 按 #240 的明确合同回收并等待。 | **T**：活动 exchange 的 force_evict 与 R02 lifecycle owned cleanup |
| 6 | ASR、TTS 的现有活动保护、router/child 去重、独立 lane 条件不回归。 | **T**：evictor dedup/ASR mode/lease/min_uptime；lane 合同无变更 |
| 7 | 使用 tests/test_worker_lease.py 与 alignment worker 的真实接线测试，不只验证 lease helper 或恒定 alive fake。 | **T+M**：生产 Aligner 接线；临时删除接线出现 2 个失败，不只测 helper |
| 8 | 诊断仅固定状态/计数，无原文、PCM、模型绝对路径或 vendor 敏感内容。 | **S**：低基数 cleanup 状态/计数；不输出 PCM、转写或路径 |



### #242

证据入口：`macos/SpeechRailApp/SpeechRailMacControlTests/MeetingMinutesVersioningTests.swift`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | UPSERT 前失败、UPSERT 后事件失败、COMMIT 失败分别覆盖；只能完整旧状态、完整新状态或明确待确认，不留不一致成功。 | **T**：R10 locked writer、UPSERT trigger、R05 revision trigger、deferred FK COMMIT |
| 2 | 失败后同名重试成功且恰好一条修订；成功命令重复不追加；A→B→A 保留两次真实变化。 | **T**：retry exactly one / repeat same / back-and-forth；R10 故障解除再试 |
| 3 | 更新失败不触发虚假复核，成功改名触发原版及其适用的编辑后代版本复核；正文、采用指针和原证据引用不被重写。 | **T+S**：R10 failed rename no review + original/edit review、body/adoption/lineage；原证据引用写路径未触及 |
| 4 | 不存在会话、外键失败、只读/存储异常有明确错误；不同会话同 label 不串联。 | **T+S**：R10 missing FK / session isolation / closed store / writer lock 实测；readonly SQLite 错误保留为静态核对，未做文件权限实测 |
| 5 | 回滚本身失败不覆盖首个原因，不把失败信息写成姓名/完整正文日志。 | **T+M+S**：RAISE(ROLLBACK) 后二次 rollback 不遮盖首因；覆盖首因突变 1 failure；无正文姓名日志 |
| 6 | 保留 MeetingMinutesVersioningTests 和新 MinutesReview/来源更改相关有效测试，新增真实 Store 层故障注入；SQL 探针不代替目标 macOS 门禁。 | **T+CI**：60 定向 macOS XCTest；既有 MinutesReview/SourceSeal 保留；R10 Swift/App CI |
| 7 | 与 #232 的 line/outbox 提交问题复用必要事务原语，但分别按业务后置条件验收，不能只验证 helper。 | **T**：同一 class 的 line/outbox/ordinal 回归按独立后置条件核对，不只测事务 helper |



### #235

证据入口：`tests/test_voice_validation_execution.py、tests/test_candidate_validation_usecase.py、tests/test_voice_quality_routes.py`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | 路由不互相导入评分、重采样、worker驱逐或业务投影；application不依赖HTTP类型。 | **S+T**：private route import / usecases have no HTTP dependencies AST guards；execution 与投影端口分离 |
| 2 | PCM/身份/policy来自同一执行；reservation释放和身份变化处Gate验证，不使用永远返回常量revision的fake掩盖时序。 | **T**：candidate_execution_keeps_producing_identity_after_eviction；同次 PCM/identity/policy Gate |
| 3 | TTS空输出/坏PCM/异常、ASR缺失/失败、资源拒绝、超时、证据保存失败分别保持现有错误和可用性事实。 | **T**：372 范围含 voice quality/validation/routes：坏 PCM、TTS/ASR/资源/deadline/evidence 保存失败 |
| 4 | 取消与重复取消保留owned cleanup；清理未确认不提前归还资源或发布成功，沿用当前相关保护。 | **T**：ASR/TTS repeated_cancel joins owned cleanup；close failure 隔离 lane |
| 5 | 一个绝对deadline贯穿相关阶段，任务和临时音频有owner且有界；不增加常驻模型或无预算并发。 | **T+S**：单绝对 deadline 的执行合同；temporary audio owner/finally，无常驻模型/lane 改动 |
| 6 | 验证期间候选revision变更时CAS拒绝旧结果；human review不能套旧revision，不能绕过voice撤销/租约。 | **T**：quality_commit_rejects_changed_voice_snapshot；revision CAS、撤销与 human-review 回归 |
| 7 | 新文本约束与固定probe分别有消费者测试，数字精确匹配等评分严格性不降低。 | **T**：候选文本约束与 quality 固定 probe 消费者；score exact-number 严格性保留 |
| 8 | 应用用例可通过fake端口测试，不必须构造FastAPI客户端；HTTP回归另核对status/header/body。 | **T**：candidate / quality usecase fake ports 与 HTTP status/header/body 分层 |
| 9 | 保留现有voice design/quality tests和最新cleanup回归；本轮未运行的集成矩阵不能勾选通过。 | **T+CI**：R03 372 定向 + 匹配 head 完整 Python CI；真实音色质量/设备不属于本条结构验收 |



### #237

证据入口：`macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | 200 HTML、204空体、200 `{}`、错误envelope、operation形状不符都不产生 isReady=true。 | **T**：ProbeRejectsInvalidSuccessBodies：HTML/204/{}/error envelope/wrong operation |
| 2 | 合法Chat普通文本、明确支持的Responses结构通过最低校验，不被迫符合某个业务schema。 | **T**：ChatProbeUsesTextContract + ResponsesProbeAcceptsDeclaredTextShapes |
| 3 | 空正文、refusal、incomplete、failed、queued 等有明确用途相关结果；不一律当成功或模型缺失。 | **T**：ChatProbeRejectsEmptyRefusalTruncationTools + ResponsesOutputNeedsCompletedStatus |
| 4 | models非权威、thinking协商与Assistant禁止回退的既有测试不退化。 | **T**：advisory models / thinking negotiation / Assistant requires thinking control |
| 5 | 无效探测不创建音频source/session；检查并保存失败不覆盖原已存密钥、不删除用户配置。 | **T+S**：probe 不创建 source/session；invalid check 不保存 draft，密钥与配置路径保留 |
| 6 | 相同响应向量在probe与正式基础解析结论一致；业务附加要求的差异明确命名。 | **T**：同一响应向量 probe 与基础响应 parser；strict business scanner 单独合同 |
| 7 | 新background取消确认、SSE预算、超时与旧回调隔离继续通过对应回归；不能为了共享解析删掉独立保护。 | **T**：background cancel + SSE bytes/UTF8/first text/stall/old callback 既有 suite |
| 8 | 仅合成响应即可验证，无需付费请求/真实密钥；日志不回声完整body或凭据。 | **T+S**：全部合成响应与 in-memory configuration；安全 observation 字段，无真实 key/body 日志 |



### #236

证据入口：`LLMProviderTests.swift、TeleprompterPreparationPipelineTests.swift、scripts/check_llm_support_boundary.py`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | 共享 LLM 支持可在不编译提词器 preparation/prompts 的情况下验证，不引用 Teleprompter 业务类型或静态 recorder。 | **T+CI**：check_llm_support_boundary 独立 Swift type-check + Python dependency guard |
| 2 | 提词器仍能关联 run/request/stage/item；普通调用无需伪造 feature context。 | **T**：Teleprompter recorder 显式注入保留 run/request/stage/item；中立 context 测试 |
| 3 | 一次 attempt 只记对应一次观测；nil observer 或观测故障不改变原返回、错误与取消。 | **T**：ThrowingObserverDoesNotChangeSuccessFailureOrCancellation + per-call single delivery |
| 4 | 严格 JSON 的重复键、尾随内容、非法顶层、截断/拒答/tool call 等既有拒绝不被放宽；不能用宽松 JSONSerialization 替换安全 scanner。 | **T**：保留唯一 strict scanner；structured output duplicate/trailing/top-level/refusal/tool 回归 |
| 5 | 新 SSE 容量、UTF-8 边界、首字/停滞和取消后旧回调隔离保持，后台 cancel 的确认/不支持/未知仍可区分。 | **T**：完整 LLMProvider streaming/timeout/UTF8/cancel confirmed/unsupported/unconfirmed suite |
| 6 | transport 重试与业务重试分别计数，协商缓存按端点/模型/操作隔离；会议恢复不因共享层迁移重发完整输入。 | **T+S**：thinking cache operation/profile scoped，transport 与业务 retry 计数；会议恢复回归 |
| 7 | 保留 LLMProviderTests 和提词器结构化/观测回归，补可独立编译的依赖守卫；测试通过不冒充真实模型质量验收。 | **T+CI**：283 定向 Swift + 2 Python 守卫、独立 type-check；非真实模型质量证据 |
| 8 | 日志不含 prompt、正文、凭据或自由文本高基数标签；已有读取方与日志格式有迁移核对。 | **S+T**：固定 metadata observer 字段及 reader/recorder 接线；SafeObservationMetadata 回归 |



### #241

证据入口：`AssistantEndRoutingTests.swift（SessionSealContractTests）、MeetingSourceSealTests.swift、MeetingKnowledgeArchiveTests.swift`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | 输入已保存、仅归档写失败：没有 lastFinalizedSessionID/.ended 的假成功；设备释放，恢复目标保留。 | **T**：ArchiveWriteFailureReleasesDevicesWithoutSuccess + TextEndSealFailureKeepsRecovery |
| 2 | 不存在 ID 的零行 UPDATE：明确未找到/失败，不因为没抛异常而成功。 | **T**：MissingRecordCannotReportEnded：零行更新不得成功 |
| 3 | UPDATE 提交后回读失败：同一目标待确认；重试不新建记录、不重置别的记录，不随意改写首次结束时间/原因。 | **T**：CommitThenConfirmationFailureRetriesSameRecordAndEndMetadata + archive retry |
| 4 | Meeting 已 archived 但来源快照失败：明确文字已保存，仅重试快照阶段，不重新录制、重复生成或发布完整封存成功。 | **T**：MeetingSnapshotFailureRetriesOnlySnapshot；generic meeting seal waits source confirmation |
| 5 | 等待暂停区间/stopper/store 时出现新 lease：旧流程不得清新 occupancy、activeSessionID、phase。 | **T**：LateStopperCannotArchiveOrClearNewLease + LateArchiveConfirmation |
| 6 | 无设备文字会话结束不影响会议占用；无持久化记录的功能只释放资源，不伪造封存成功。 | **T**：TextEndWhileMeetingOwnsLease + NoRecordReleasesLeaseWithoutPublishingArchive |
| 7 | 逐行保存、协议 drain、暂停区间结束、归档和快照失败分别可观察，不被下游成功覆盖。 | **T**：PauseFailure + TextStopFailure + R08 protocol/save/archive/source 独立失败 |
| 8 | 保留 MeetingSourceSealTests、MeetingKnowledgeArchiveTests、AssistantEndRoutingTests、AssistantDrainTests 的既有有效用例，新增真正的 store failure/零行更新及旧 lease Gate 场景。 | **T+CI**：R06 138 XCTest +77 Swift Testing；R08 联合 293；SourceSeal/KnowledgeArchive/EndRouting/Drain |



### #232

证据入口：`AssistantInputPersistenceQueueTests.swift、MeetingSessionLifecycleTests.swift、CaptionSessionLifecycleTests.swift、MeetingRecoveryMaterialTests.swift`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | Meeting 与 Caption 的 final 在写前失败后保留完整命令和同一 lineID，显式重试只产生一条权威行。 | **T**：Meeting/Caption frozen final command failure + explicit retry without terminal replay |
| 2 | line INSERT 成功、outbox INSERT 失败；以及 ordinal 回读失败：分别检验原子回滚或明确部分结果，不丢索引待办、不重复正文。 | **T**：LineAndIndexOutboxRollbackTogether + LineOrdinalReadFailureRollsBackBodyAndOutbox |
| 3 | 同 lineID 已存在且字段相同可核对恢复；字段冲突不能成功或覆盖。 | **T+S**：FixedLineIdentityConfirmsExactFields；正文冲突实测，其余冻结字段比较静态核对 |
| 4 | 真实 Realtime 终态去重启用时，存储重试不依赖第二个 completed；不能只直接调用 commit 两次充当端到端证据。 | **T**：ProductionClientRetriesSaveBeforeAnySecondCompleted 两 feature 真实 client + fake transport |
| 5 | partial 恢复材料也使用稳定身份与失败保留，但不进入正式纪要、默认分享或正式来源快照。 | **T**：FixedPartialIdentity + RecoveryMaterial：default formal/source/share 查询排除 partial |
| 6 | 挂起存储时控制/失败事件仍能被消费；容量耗尽拒绝新命令且保留已接纳内容，失败项不从预算消失。 | **T**：PendingSaveConsumesControl + capacity refusal + FailureRetainsCapacity；projection settled Gate |
| 7 | 观察时间、声学时间、source、timingQuality 和 generation 的新合同均保留；换连接不串记录。 | **T**：CommandPreservesEveryFrozenLineFieldAcrossRetry + GenerationSourceAndRecordBoundaries |
| 8 | attribution 在对应保存前后到达均正确关联且有界；关闭和封存等待真正 settled 结果。 | **T**：早/晚 attribution、metadata Gate、record budget release；R08 EOF 后等真正 settled |
| 9 | 复用 AssistantInputPersistenceQueueTests、MeetingSessionLifecycleTests、MeetingRecoveryMaterialTests、TranscriptItemLedgerTests，并增加真实保存端口 Gate/outbox 失败用例；现有正常路径绿灯不替代这些反例。 | **T+CI**：R07 228 与 R08 联合 293；Queue/Ledger/Lifecycle/RecoveryMaterial 和真实临时 SQLite |



### #231

证据入口：`AssistantDrainTests.swift、MeetingSessionLifecycleTests.swift、CaptionSessionLifecycleTests.swift、SpeakerLabelingPersistenceTests.swift`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | 正常 drain 启动后、receipt 前到达的同 connection final/attribution 仍被消费并恰好保存一次；新连接和 abort 后的旧包仍被拒绝。 | **T**：TailFinalDuringDrainArchivesOnly + DrainFinalAndLateAttribution；旧 generation 拒绝 |
| 2 | receipt 已到、receiver Gate 未释放、保存队列为空：stop 不得报告内容完整；放行后完成正确旧记录。 | **T**：ReceiptWithEmptyQueueCannotBypassTheOnlyReceiver：放 Gate 才完成旧 record |
| 3 | receiver 已通过 marker、store Gate 挂起：仍不发布保存或封存成功。 | **T**：ReceiverEOFStillWaitsForTheRealInputSaveOwner + A06ReceiptCannotBypassStoreGate |
| 4 | 保存失败、封存失败、快照冻结失败、协议超时、连接断开分别可见，不能以 close 成功覆盖失败。 | **T**：save/seal/source/protocol/upload/stream failure 矩阵及非合作 receiver deadline |
| 5 | 空输入、重复 final、迟到 attribution、快速 stop/start、不同 drain/clear 顺序都有确定性回归。 | **T**：empty/duplicate final/late attribution/rapid start-stop/clear/drain 既有回归 |
| 6 | 暂停使用 flush 的语义独立验收，不误清连接或结束分人；暂停能力不作为完整 drain 已修的证据。 | **T+S**：MeetingPauseCutsExactlyOnce/NoAudioWhilePaused；既有 flush 与 Caption pause 合同独立 |
| 7 | 正常结束不会启动新回复；显式取消仍可按契约丢弃未接纳输入。 | **T**：正常 drain 阻止新 reply/TTS；cancel revoke 旧输入的 CancelReceive suite |
| 8 | Meeting 只有消费、保存、归档和当前方案要求的来源快照均成功，才启动完整纪要流程。 | **T**：Meeting source freeze / archive confirmation / failure blocks summarize 的真实 feature + Store |
| 9 | 保留 `MeetingSessionLifecycleTests` 的新旧连接隔离；补真正的 receiver Gate/store Gate 测试。原 `AssistantDrainTests` 的测试名不替代实际断言范围。 | **T+CI**：唯一 receiver/store Gate 生产接线；R08 293 定向与完整 Swift/App CI |



### #234

证据入口：`tests/test_loader_metadata.py、tests/test_model_identity.py、tests/test_qwen3_worker.py、tests/test_qwen3_tts_worker.py、catalog 两测试`。Swift 测试文件未写完整路径者均在 `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 项 | 原验收要求 | 证据性质与关闭依据 |
|---|---|---|
| 1 | Mapping/object、字段缺失/None、多来源优先级分别有明确结果。 | **T**：loader_metadata Mapping/object/value priority/missing/None vectors |
| 2 | bool、浮点位宽、非法位宽、零/负group_size、位宽与group_size不配对均按原严格约束拒绝。 | **T**：bool/float/illegal bits/zero-negative group/unpaired 纯向量及 QuantizationSpec 重校验 |
| 3 | quantization/quantization_config/扁平字段的一致、矛盾、部分缺失及未知键按明确合同处理，不静默覆盖矛盾来源。 | **T**：nested/flat/multi-source conflict/unknown keys，loaded 只比较 bits/group |
| 4 | snapshot完整声明与loaded部分观测分别验收；权重量化格式不冒充计算dtype。 | **T**：model_identity snapshot 完整规格与 loaded partial 对照，mixed precision/dtype 保留 |
| 5 | 两后端自身family/variant/dtype/tts_model_type/sample_rate仍验证，当前catalog产品范围不扩大。 | **T+S**：两 fake loader 真实构造 + model_catalog tests；family/variant/rate/compute 留 adapter |
| 6 | 新增collector形状不修改基础合并规则；调整共同约束只改一处并覆盖全部消费者。 | **T+S**：collector 独立输入 shared pure merge；共同 bits/group 只有 validate_quantization_pair |
| 7 | tests/test_model_identity.py、test_qwen3_worker.py、test_qwen3_tts_worker.py 的现有有效回归保留；纯测试不加载模型。 | **T+CI+M**：241 pytest（8文件）与完整 Python/wheel CI；删接线冲突用例 2 failed |
| 8 | 本条验收不以删行数或性能改善为标准，而看规则唯一、输入差异显式及错误/未知语义不退化。 | **S+T**：共同规则唯一、来源差异显式、unknown/missing/error vectors；不以性能/删行数判定 |



## 集成门与保留边界

- A 轨 #231/#232/#241：R08 联合 293 项涵盖生产 feature → 唯一 receiver → 保存 owner → Coordinator → 临时 Store/来源封存；receipt、空队列、close 和设备释放均不能替代完整证明。正常 stop 共用绝对预算，保存/metadata 失败不假封存；旧任务迟到不投影新场。
- B 轨 #237/#236：同一最低响应 parser 与中立 observation 支持，探测不要求业务 schema；独立编译守卫保留 SSE/取消/strict scanner，合成响应不冒充实际 LLM 质量。
- C 轨 #240/#246/#235/#234：物理 owner、活动 lease/eviction、同次验证绑定和纯 loader metadata 分工明确；没有增加常驻模型、并发 lane 或 catalog 产品范围。
- D 轨 #242/#244：真实业务事务与文件完整发布分别按后置条件验收；未清库/降级 schema，文件发布仅承诺进程级原子可见，不承诺断电一致性。

R07 留存 Minor：冻结字段冲突回归只单独改变正文，其余字段的比较有源码依据；复制不清拒绝证明已静态核对，未增加专门 copy 后账本断言。开发手册旧队列类型引用在另一 worktree 的 WIP 文件中，未覆盖。R08 字幕捕获证明不可恢复时保留复制/导出与保存恢复，未增加通用中断归档按钮；该记录在本进程内不能正常完整归档。R09 来源标签是 internal collector 固定字符串合同，未来 collector 须遵守，当前生产无动态敏感 label 输入。这些取舍与成本已记入各包 Ruling。

## 恢复与回退

保存/归档失败使用同 record/line 命令恢复；捕获证明不可恢复时显式保留 incomplete，不伪造成功。历史缺失改名事件不能从当前名字倒推并补写，未知仍未知。回退通过新增 revert PR 撤销对应包代码并验证合同；不 force-push main，不清除已有数据、作品、模型或密钥。其他 worktree 未提交修改和旧 stash 保持原状。

原十一项矩阵的关闭依据对应 `6f91c25d`；追加审计发现隔离错误映射和 idle close 失败两个缺口，
原证据不能证明这两个路径已正确。补修 A01/A02 及最新验证范围见
[契约、MCP、文档与代码追加审计](2026-10-07-issue-238-alignment-audit.md)，合并状态以各补修 PR
最终 head CI 和时间线为准。Epic 的相邻八项以及真实设备/声学验收仍独立跟踪，不将本次结果
扩展为全系统生产质量完成。
