<!-- loop-plan-r2: 2026-10-07, baseline 4f6b7356 -->
# Issue #238 DRY / SOLID 收敛 Loop 实施计划 r2（新基线 `4f6b7356`）

> r1（`2026-10-07-issue-238-solid-loop-plan.md`，基线 `159fea09`，随 R01 PR #320 提交）的后继修订。
> 凡与 r1 不一致处以本文件为准。当前目标包含实施、审查、验证、提交、推送及通过后的合并；分组/跨包门结论继承 r1。

**Goal:** 11 个 issue（#231 #232 #234 #235 #236 #237 #240 #241 #242 #244 #246）分 9 个 PR 交付。
**Spec:** [Epic #238](https://github.com/hrygo/SpeechRail/issues/238)、[Epic #245](https://github.com/hrygo/SpeechRail/issues/245)。
**核验日期：** 2026-10-07，Asia/Shanghai；CI 时间戳为 UTC。进度以本次回读的 SHA、PR 状态和 run ID 为准。基线 `origin/main = 4f6b7356`（已 fetch）；每包合并后刷新。

**当前实施目标（2026-10-07 更新）：** R01、R02、R05、R03、R04、R06 已合入；剩余 3 个 issue 分 3 个独立 PR，按 **R07 #232 → R08 #231 → R09 #234** 完成实施、整包独立审查、定向验证与必要 CI，验证通过立即 squash 合并，再刷新 main。每包 1–3 issue；不堆叠 PR、不 force-push、不关闭未验收 issue、不 `Closes #238`。保持 #245 的语义禁写区，最终逐条核对十一项验收矩阵后决定关闭 issue 与完成 goal。

**最新执行目标（2026-10-07，Asia/Shanghai）：** 本次 fetch 后 `origin/main` 仍为 `4f6b7356`。R07 分支 `codex/238-r07-transcript-persistence` 的 draft PR 为 **#330**。确认框 SDK 差异已修；head `81b2cb27` 的 CI `37572108064` 全部必要检查通过。一次整包独立审查已结束，无 Critical；发现的拒绝 item 归属缓存泄漏已修，并补齐封存失败/并发验收，最新 **228 项定向实测通过**。立即目标是提交修订、等待匹配新 head 的必要 CI，通过后立即合并；不能以旧 head 的绿灯代替修订验证。R08/R09 仍在下一包。

**本次 goal 更新检查点（2026-10-07）：** 本地 HEAD 为 `0d2cf68e`；恢复入口、不完整结束、历史恢复材料展示及相关文档仍有未提交改动。220 项测试与 App 构建是前一执行阶段的实测证据，本次更新目标未重跑。接下来按以下顺序推进：

1. 检查完整 R07 diff、敏感字段和提交差异，将已验证的恢复实现与文档提交、推送到现有分支；保留未知及其他 worktree 改动。
2. 对 `4f6b7356` 到最终 R07 HEAD 做一次整包独立审查；创建只关联 #232 的 draft PR，并运行匹配最终 head 的必要 CI。Required 由主代理补反例并修复，按影响复验。
3. 审查、必要验证和 CI 通过后立即 squash 合并，刷新 main，更新 #232/#238 与执行账本；无需再次请求逐包合并确认。
4. 顺序完成 R08 #231、R09 #234，各一个从最新 main 开出的独立 PR；每包沿用相同审查、验证、合并和账本更新闭环。
5. 九包均合并后审计十一项 issue 的联合验收矩阵；只关闭已满足完整验收条件的 issue，全部完成后再将结构化 goal 标为 complete。

- **R07 完成门槛：** 固定身份和完整命令可恢复；行、ordinal 与 outbox 原子确认；失败和容量拒绝不能被成功封存掩盖；partial 不进入正式纪要、默认分享或正式来源快照；归属缓存有界且跨 record/generation 隔离。保存后 metadata I/O 归共享 owner 管理，迟到完成不改新场标签或文字；用户能重试/复制旧记录，并显式处理拒绝证明，不能永久卡在记录容量上限。完成一次整包独立审查，修复 Required，定向验证和必要 CI 通过后立即合并。
- **后续目标：** R08 补足消费 EOF、保存 settled 和封存结果的完整收尾证明；R09 收敛 loader 内核规则。各自从更新后的 main 开独立 PR，分别只关联 #231、#234。
- **跨团队边界：** #245 的 decoder、ASR policy、turn coordinator、scene、Assembler、Ledger 与 wire 禁写；在途 clear 协议和路由只读；避让 pbxproj。同一文件出现无法分离的并行修改时暂停该处写入，核实后再继续。
- **最终完成条件：** 九包合并并逐条审计十一项 issue 的验收矩阵，更新相关 issue 与文档；满足全部要求后才关闭对应 issue 和完成 goal。未执行的真实模型、性能、长稳及 UI 验收如实列出，不以确定性测试替代。

结构化 goal 仍 active。2026-10-07 再次核对：Goal 工具只提供完成/阻塞状态，不能改正文；原生 Codex UI 入口也被 computer-use 安全规则拒绝。旧 goal 的基线、PR 状态、逐包等待确认及错误同文件判断由本段执行目标更正，不虚假标为 complete 再重建，不绕过 UI 限制。

## 0. 基线与 #245 现状（只读快照）

- `origin/main = 4f6b7356`：包含 #249/#252 文档及提词器 preview 500ms 预设变更（这是业务行为变化）、#321 V17 回归、#324 3.8.0、#326 限时 ASR 诊断、#327 3.8.1 发布提交，以及 R01/R02/R05/R03/R04/R06。
- #245 子任务历史快照：#247–#252 CLOSED。R04 开工回读 #245/#253 仍 OPEN。R03 曾核对 acceptance-evidence、app-validation、boundary-fix、consumer-replay、delivery、validation-v8 等 ASR worktree；R04 的当前登记表已无这些 checkout，不据此断言在途分支停工或语义禁写区解除。
- #320 R01（#244）已合并为 `451aeb1e`；#322 R02（#240/#246）已合并为 `1edf9398`；#323 R05（#242）已合并为 `ff34bfcf`。三包均在匹配的 head 上通过实质审查、定向验证与必需 CI 后 squash 合并。
- #325 R03（#235）已在修订 head `ed02d7a3` 的全部必要 CI 通过后合并为 `baafb59b`；CI run `37556276635`，UTC `2026-10-07T01:21:27Z` 合并。
- #328 R04（#237/#236）已在 head `0f22ada5` 的全部必要 CI 通过后合并为 `151297f6`；CI run `37560283532`，UTC `2026-10-07T02:12:35Z` 合并。
- #329 R06（#241）已在 head `b38f08dc` 的全部必要 CI 通过后合并为 `4f6b7356`；CI run `37562890224`，UTC `2026-10-07T02:41:27Z` 合并。
- 在途远端分支（只读核对）：`asr-production-consumer-replay-253`（pbxproj + 新增 `ASRProductionConsumerReplayTests.swift` 881 行）、`asr-clear-barrier-245`（`application/realtime_openai.py` 283 行 + 路由 + 契约文档，#245 语义面）、`v17-backlog-playback-268`（矩阵文档 + V17 测试）。
- 用户最新授权：**PR 经实质审查和必要验证通过后尽快合并**，不再逐包询问；旧版等待合并确认的限制已被替代。main 要求线性历史，采用 squash/rebase 合并，不绕过 `Quality Gates` / `Gate Summary`，不 force-push。

审查发现的发布失败清理、独占 staging、alignment 活动未接线、退出失败隔离及测试 target/全局注入问题均已在各包补齐。合并证明代码与所列 gate 通过，不能代替未运行的真实模型、质量、性能或长稳验收。

## 1. 十一条逐条复验结论（`b91e6f88` 只读核对）

方法：`git log dc0744fb..HEAD -- <file>` 定文件是否被 #245 改动，再读当前源码确认根因。**未修**（可按原计划做）、**部分改善**（范围收窄）、**可启动**（等待解除）。

| Issue | 档 | 当前事实（main） | PR 包 |
|---|---|---|---|
| #244 短写制品 | 已合并 | 独占 staging、完整写入、发布前失败清理及数据库完成回读；127 个定向测试和选中 CI 通过。仅承诺进程级原子可见 | R01 #320 |
| #240 owner 登记 | 已合并 | eager/owned 分离，aligner 按需加载；partial-start 回收、runner/monitor/worker 失败隔离、取消保护及超时句柄保留 | R02 #322 |
| #246 活动保护 | 已合并 | 生产 alignment 与 evictor 共用 WorkerLeaseLock；活动/回收互斥，结束后重设 idle 起点；移除接线导致两个回归失败 | R02 #322 |
| #242 改名事务 | 已合并 | 映射和修订事件共用 SQLite 事务；5 个故障/幂等回归，测试自有 trigger，无生产开关和 pbxproj 修改 | R05 #323 |
| #235 验证用例 | 已合并 | 两个用例接线；同次身份、unknown、CAS/撤销、保存失败、重复取消与 timeout/cancel 回归通过；372 项定向测试，独立审查 Required 修复及全部必要 CI 通过 | R03 #325 |
| #237 坏 2xx | 已合并 | probe/正式调用共用最低响应校验；坏 2xx 不再 ready；App 展示新状态编译通过 | R04 #328 |
| #236 中立支持 | 已合并 | 中立 context/observer、唯一 parser、显式 recorder 注入；支持层独立 type-check 与全部 CI 通过 | R04 #328 |
| #241 封存结果 | 已合并 | 归档提交后读回、记录/租约冻结、会议来源确认、按记录保留失败恢复；138 XCTest +77 Swift Testing、审查修订与 CI 通过 | R06 #329 |
| #232 保存恢复 | 部分改善 | Meeting `commit`(867-) 每次 UUID 新行、恢复 note(949-) 另 UUID；Caption(809-) 同；行/outbox 两次提交 | R07 |
| #231 收尾屏障 | 部分改善 | 收尾证明面：Meeting stop(594-626)/Caption(458-525) 等了消费但不验保存成败 | R08（收窄） |
| #234 loader 规则 | 可启动 | 双份规则仍在（`qwen3_worker.py:695/709/770-776` + `model_identity.py`）；worker 现 1315 行，R09 只动 loader 内核 | R09（#249 关闭，解锁） |

## 2. 启动顺序（#249 关闭后更新）

```text
R01 审查补齐并合并 → R02 → R05 → R03 → R04 → R06 → R07 → R08 → R09
```

- R01/R02/R05 均须审查补齐后合并。R09 不再等待 #249，改排 R02–R08 之后、重定基线且核对 worker 当前写入窗口再做；不等整个 #253 验收关闭。
- R06 → R07 → R08 必须串行：同一批 Store/Session 文件，seal seam → save 内核 → drain 接线。
- R04 主要修改 `LLMProvider.swift`，R06 主要修改 `SessionCoordinator.swift`；两者不是同一文件。仍按既定顺序执行，若扩展到共同调用者再核对占用。
- #231/#232/#241、#240/#246 之间不设整单循环 blocked-by；接口可先行、实现串行、联合验收。

## 3. 与 #245 及在途分支的文件边界

### 3.1 语义禁写区（#253 关闭前仍有效）

`qwen3_stream_decoder.py`、`domain/asr_policy.py`、`application/asr_turn_coordinator.py`、`ASRScenePreset.swift`、`AssistantInputTurnAssembler.swift`、`TranscriptPreviewLedger.swift`、ASR wire 契约（`RealtimeContractTypes.swift` ASR 部分）。

### 3.2 #238 可写区（自 dc0744fb 零提交，已核对）

`runtime/local_file_processor.py`、`application/lifecycle.py`、`runtime/worker_lease.py`、`application/services.py`、`http/routes/voice_designs.py`、`http/routes/system.py`、`backends/model_identity.py`、`SessionStore.swift`、`LLMProvider.swift`。
`qwen3_worker.py`/`qwen3_tts_worker.py`：R09 只动 loader 内核（`_loader_value`/`_loader_quantization`），不动 #249 合入的解码/策略/终态语义。

### 3.3 需交接的共享文件

- `MeetingSession.swift` / `CaptionSession.swift` / `AssistantSession.swift`：R07/R08 开工前以当时 main 重定基线，一次只一处写入。
- `application/realtime_openai.py` + `http/routes/realtime_openai.py` + `contracts/realtime-openai.md`：`asr-clear-barrier-245` 在途（#245 语义面）；R08 只读 `drainAndClear` 合同，不改语义。
- `*.pbxproj` + `ASRProductionConsumerReplayTests.swift`：`consumer-replay-253` 在途；R07/R08 若碰同目录先核对 head。
- `ServiceContractTests.swift` / `AppModel.swift`：`189-audio-digest` 分支在改；R06–R08 若碰同一测试文件先核对 head。

### 3.4 Owner 划分（一句话）

#245 负责识别事实（item/revision/span/segment-close/轮次）；#238 负责已接纳内容的保存命令、消费屏障、封存证明。一方的"完成"不代替另一方的验收。

## 4. 每轮 loop 执行规则

- [ ] **定基线**：记录 checkout、base/head、在途分支 heads；只读核对同文件变更来源。
- [ ] **领边界**：列出 issue、精确文件、输入/输出接口、禁写项；同一文件同时只一个写入者。
- [ ] **补反例**：先写失败回归并确认红灯（TDD），再做最小修复。
- [ ] **最小验证**：本包定向测试 + `ruff`/`swift` 编译 + `git diff --check`；记录实测命令与 SHA。
- [ ] **成 PR 并合并**：分支 `codex/238-rXX-<slug>`，一个 PR 只关联本包 1–3 issue；检查新 main、审查及必要验证通过后直接合并，随后同步 main 开下一包。不关闭尚未完整验收的 issue，不 `Closes #238`。
- [ ] **更新账本**：§5 填真实 SHA/日期/未验项；下一轮从新 head 重建判断。

## 5. 执行账本

| 包 | 状态 | 真实 PR / SHA | 备注 |
|---|---|---|---|
| R01 #244 | MERGED | PR #320 / `451aeb1e` | 127 定向测试、Ruff/Mypy、选中 CI 通过 |
| R02 #240+#246 | MERGED | PR #322 / `1edf9398` | 99 定向测试、28 个 HTTP/lifecycle 测试；移除接线使 2 个回归转红；同步 R05 后 CI run `37550404724` 通过 |
| R05 #242 | MERGED | PR #323 / `ff34bfcf` | 42 定向 Swift 测试；去掉事务使 3 项转红；CI run `37549739387` 的 Swift/App/必需 gate 通过 |
| R03 #235 | MERGED | PR #325 / `baafb59b` | 372 项定向 fake/HTTP/contract、Ruff/Mypy；独立审查 Required 已修；CI `37556276635` 全部必要检查通过 |
| R04 #237+#236 | MERGED | PR #328 / `151297f6` | 283 定向 Swift、2 项 Python 守卫、独立编译；Required 已修，CI `37560283532` 全绿后合并 |
| R06 #241 | MERGED | PR #329 / `4f6b7356` | 138 XCTest +77 Swift Testing；首轮 Required 已修，CI `37562890224` 全绿后立即合并 |
| R07 #232 | Required 已修，待修订 CI | draft PR #330；分支 `codex/238-r07-transcript-persistence` | 基于 `4f6b7356`；228 项定向实测；独立审查完成，`81b2cb27` CI 已绿，修订 head 待验证；避让 pbxproj |
| R08 #231 | planned | 无 | 注意 clear-barrier 分支，只读合同 |
| R09 #234 | planned | 无 | #249 关闭已解锁，排末位 |

### R03 验证与取舍（2026-10-07）

- 两个用例各自拥有状态/提交，共享有界执行组件；阶段表见 [执行所有权](../architecture/voice-validation-usecases.md)。HTTP 不导入其他 route 私有业务，application 不依赖 HTTP 框架。
- 先观察重复取消提前释放 reservation、timeout 后再次取消中断清理、质量保存失败错误类型、日志私密异常文本回归转红，再修复。移除 quality expected revision guard 使回归以 `DID NOT RAISE VoiceRevisionConflictError` 转红，恢复后通过。
- Ruling：阶段 task 与其 deadline 同 owner，复用 `join_cleanup`；deadline 已取消时不追加 cancel，避免第二次取消打断 backend 清理。回收未确认时保留 ownership 或隔离 lane；不将响应 deadline 解释为强制进程回收上界。
- Ruling：清理失败中止后续 probe/ASR/commit，返回不可自动重试的 `503 backend_reclamation_failed`；契约与独立用户说明同步。ASR 团队在改 `docs/users/api-contract.md`，本包不写该文件。
- 独立审查指出候选 close/eviction 的原始异常未映射，新增两个 HTTP 反例观察未处理 RuntimeError，再接稳定 503；共享 helper 的生成入口也补映射与 design lane 隔离。候选生成/验证和 quality-runs 共 5 个清理失败 HTTP 回归通过。
- 最终独立审查发现一项 Required：`aclose()` 自身抛 TimeoutError 被普通超时抢先分类。3 个 HTTP 反例先转红，再将 close failure 优先分类，稳定返回不可重试的 reclamation failure；纯执行/驱逐 deadline 保持原语义。最终清理失败 HTTP 矩阵共 8 项通过，没有遗留 Critical/Required；审查人没有运行真实模型，最终修订由主代理 TDD 验证。
- 定向命令：`SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD=1 uv run pytest --no-cov -rA tests/test_voice_validation_execution.py tests/test_candidate_validation_usecase.py tests/test_voice_quality_routes.py tests/test_voice_design_workflow.py tests/test_voice_design_concurrency.py tests/test_voice_validation.py tests/test_voice_validation_residency.py tests/test_voice_quality_gates.py tests/test_voice_quality_evidence.py tests/test_voice_revision_routes.py tests/test_voice_revision_contract.py tests/test_tts_delivery.py tests/test_tts_errors.py tests/test_resource_governor.py tests/test_tts_profile_snapshot.py tests/test_openapi_contract.py tests/test_audio_error_contract.py tests/test_user_doc_contract.py` → 372 passed。
- `ruff check` 全部改动 Python；`mypy` 9 个生产 source 文件通过。没有运行完整本机测试、真实模型、服务/UI、性能或长稳验收。
- 提交前核对六个已登记 ASR worktree：本包路由、registry、架构导航、OpenAPI 无 dirty 或 branch diff；仅 API 手册存在独立 ASR 文档变更，已避让。新文件无对应图谱索引，按当前源码审查，不宣称图谱完整。

### R04 验证与取舍（2026-10-07）

- Pre-flight：#237 的最低响应校验由 #236 原样共享；业务 schema/usage 不进入普通 ping。新观测类型供 Provider 输出，feature adapter 补回 run/stage/item，业务与 transport retry 分开。两项交付在同一包顺序完成。
- Ruling：公共支持类型和唯一 scanner 暂在已登记的 `LLMProvider.swift` 内，避免修改 #245 在途 `.pbxproj`；独立 type-check 守卫证明不需 feature source。代价是文件暂较长，后续分文件须协调注册。
- Ruling：一次 attempt 只记录 started + 一个 terminal；结构化校验失败使用 failed，保留完整元数据，移除先 response 再 failed 的重复计数。既有日志目录、指标和维度保持，新增可选 provider correlation，不改写历史日志。
- 200 HTML/204/空对象/错误 envelope/错 operation/空正文/refusal/截断/failed/queued 的新矩阵先观察 35 个断言失败，修复后通过；合法普通文本和兼容 `output_text` 不被强制符合业务 schema。失败不保存密钥草稿。
- observer 重复 terminal 反例先观察 2≠1，迁移后通过；独立编译先报缺少 feature 类型，再仅编译共享 source 通过。复用 scanner 拒绝重复键、尾随内容及非法顶层。
- App 组合根显式注入唯一 observer 路径，保留助手/纪要/InnerOS 的通用指标。MeetingSession 只增加构造注入并转交两个 LLM 消费者，不修改识别/收尾语义；已核对登记 worktree 和两个在途 ASR 分支，这些位置无冲突。
- 独立审查 Required：跨会议知识问答仍创建裸 Provider，移除全局 recorder 后丢失遥测。补 Coordinator 构造注入与组合根接线；新测试先因缺少注入参数失败，接线后在实际 fake knowledge query 中收到 started+terminal 两条观测。R04 因此仅在 `SessionCoordinator` 增加 LLM 注入，R06 后续串行修改封存路径。
- 独立审查 Required：标准 `output[]` 缺少 status 仍被接受。probe、共享 parser、正式 complete 三项断言先红，再要求该形状显式 completed；顶层 `output_text` 兼容形状保留。正式文档同步，未增加真实探测请求或模型预算。
- 最终定向 Swift：200 个 XCTest + 83 个 Swift Testing 通过，共 283 项。Python 架构守卫 2 passed，Ruff/format 与 diff check 通过。独立编译脚本通过，已接入 Swift CI。首轮整包独立审查结束，未发现 Critical，两个 Required 均经主代理反例修复；reviewer 未再次语义复审，修订由红→绿与最终定向套件验证。
- 提交前刷新 main 至 `fe106a60`（#326 限时 ASR 排障采集）；新增文件与 R04 无交集，`AGENTS.md` 仅增加显式限时录音例外。本任务未操作录音开关或运行态。将同步该基线后提交；匹配 head/base 的 CI 仍待完成，不声明 merge-ready。
- PR #328 首个 App CI（run `37559927131`）发现 `SettingsComponents` 的 exhaustive switch 漏接新响应状态。SPM 排除了该 UI 文件，不能证明 App target 编译；补上“服务已连接，尚未确认能回答”的展示分支，颜色沿用既有未确认状态。CI 编译反例为红灯，修复后的 App 编译须由新 head CI 证明。
- Ruling：PR #327 发布提交 `eb45faaa` 在 R04 推送后合入 main。为遵守不 force-push、保留远端历史并满足 strict base，仅在 feature 分支合入最新 main（无文件内容冲突）；最终仍 squash 到 main，保持 main 线性。代价是重跑匹配新 head 的必要 CI；发布的版本材料仅随基线继承，不归 R04 变更。
- 修订 head `0f22ada5` 的 CI `37560283532`：Quality Gates、Gate Summary、Python、Swift、App Build、Package 全部通过；已立即 squash 合并为 `151297f6`。#237/#236/#238 的进度评论已同步，issue 尚 OPEN。

### R06 验证与取舍（2026-10-07）

- Ruling：R04 App/Swift CI 排队期间，从当时 main `eb45faaa` 启动独立 R06 本地分支；R04 合并后、本包推送前 rebase 到 `151297f6`。只出现两包自有构造注入的冲突，明确保留 LLM recorder 和 archive writer 两个依赖，不覆盖 ASR 工作。代价是同步后的定向复验；不会形成 stacked PR。
- Store 的唯一基础归档命令返回同一条提交后读回的 archived 记录，missing/未确认失败；已 archived 时不再 UPDATE，保留首次时间与原因。`SessionArchiveWriting` 只暴露该确认边界，默认为真实 Store，fake 可模拟提交后确认失败。
- 复用 `SessionSealResult`，冻结 record/lease/结束时间/原因和暂停区间；按记录保存进程内 pending 命令。先合暂停，再归档确认，会议最后封来源快照。快照失败只重试快照，不重新归档或生成。失败释放本目标资源，不发布成功 ID；无持久化记录只释放。
- Ruling：stopper 调用 `abandonOccupancy` 表示它撤销了保存证明（助手输入失败已有这条路径）。迟到的 finalize 返回 skipped，不能越过撤销去归档任何记录；若归档提交期间才出现新租约，则可以确认冻结的旧记录，但只能清理仍匹配的原租约。代价是被撤销目标的保存恢复仍由原 feature owner 负责，R08 后续补保存屏障结果接线。
- 首批 5 个真实 SQLite/Gate 反例出现 13 个断言失败后转绿；随后直接文字 stop 假成功、skipped retry 清掉恢复目标、会议并发加入基础归档漏快照的 3 个反例出现 4 个失败后修复。
- 通用会议入口也必须根据归档后读回的 kind 组合来源封存；新增来源失败反例先红，再修复。基础 Store 命令仍不依赖会议知识域。
- 同步后定向验证：`swift test --package-path macos/SpeechRailApp --filter "SessionSealContractTests|AssistantSessionTests|AssistantEndRoutingTests|AssistantDrainTests|MeetingSourceSealTests|MeetingKnowledgeArchiveTests|MeetingSessionLifecycleTests|CaptionSessionLifecycleTests|MeetingKnowledgeQueryTests"` → 136 XCTest passed，含 15 项封存合同测试。独立整包审查进行中；不宣称 merge-ready。
- draft PR #329 首次 CI `37561798476`：新测试文件未登记 Xcode target，Quality Gates 失败。为避让在途 pbxproj，原样将 15 项封存合同测试搬入已登记的 `AssistantEndRoutingTests.swift`；覆盖守卫 OK，搬迁后 19 XCTest 通过。
- 首次 Swift CI 的 1251 XCTest 均通过，但提词器一次运行回归在释放占用后立即断言 manual 失败；本地同一反例也转红。Ruling：占用释放证明租约交还，不能代替功能层等待封存返回后的收尾证明。测试增加有界等待 manual，保留资源/phase/位置断言；不改变产品或 ASR 语义。已核对其他登记 worktree 与 consumer-replay 分支该测试文件没有重叠改动；代价是多一个异步测试屏障，若最终不收尾仍明确失败。
- 上述测试屏障修订后扩大定向套件：原 136 XCTest + 77 项提词器生命周期 Swift Testing 全部通过；新 head 的必要 CI 与独立首轮审查仍待完成。
- 首轮整包独立审查发现 1 项 Required：助手单槽恢复入口被新会话成功清空或失败覆盖。两个跨会话反例先出现 10 个失败断言；修订按记录保留原因及冻结复制文本，成功只移除该记录，按失败顺序逐条重试。reviewer 未运行测试、不做二次审查，修订由主代理红→绿和最终定向套件验证。
- 最终定向命令在原过滤项后追加 `TeleprompterSessionLifecycleTests`，138 XCTest +77 Swift Testing 全部通过（含 17 个封存合同测试）。`cd7b13dd` 的 CI `37562445317` 全绿，但上述 Required 修订还须匹配新 head 的必要 CI，尚未合并。
- Required 修订 head `b38f08dc` 的 CI `37562890224`：Quality Gates、App Build、Swift Package Tests、独立 LLM 支持编译、Gate Summary 全部通过；已立即 squash 合并为 `4f6b7356`。选中 scope 的 Python 全套和 wheel job 跳过，不扩展为本机完整测试或真实能力验收。
- 不改 schema v13、ASR 识别事实/协议、pbxproj；不持久化跨重启 pending 命令，不运行真实音频/LLM、UI、服务、模型或发布。

### R07 实施边界与账本（2026-10-07）

- 从 R06 合并后的 `4f6b7356` 开独立分支；其他登记 worktree 在 Store/Queue/Meeting/Caption/所用事务测试文件无 dirty，在途 consumer-replay 分支在三个生产文件无差异。图谱只覆盖主 checkout 的旧 generation，相关片段已按当前源码回读，不以旧图谱证明穷尽或重建索引。
- 路径：先建立 Store 有限事务与固定 ID 确认，再将既有助手队列中立化并冻结完整行字段，最后接入 Meeting/Caption 的接纳、恢复、归属缓存与 settled 结果；R08 后续接完整消费 EOF 屏障，不修改 #245 的识别或 clear 协议语义。
- Store：正文、序号确认和持久化索引待办同事务；同 ID 按 session/正文/来源/role/归属/时间/状态/设备切换/质量比对，冲突拒绝。匹配的旧半提交可补缺失索引待办，已待处理或已索引不重复排队；partial 不进正式读取或索引。观察时间采用 SQLite Double 精度的 1 微秒确认容差，不承诺纳秒相等；未指定观察时间的旧调用不凭空要求新时间相同。
- 五个新增 SQLite 反例在旧实现出现 8 个失败（含两个未捕获 UNIQUE 错误）；事务和确认修订后 `swift test --package-path macos/SpeechRailApp --filter "SessionStoreTransactionTests|MeetingRecoveryMaterialTests|SessionSealContractTests"` → 34 XCTest passed。这是 Store 子任务实测，不表示 #232 全包已交付。
- 既有队列中立化为 `TranscriptPersistenceQueue`，不保留旧类型 alias；Command 冻结 generation、role、speaker、起止、状态、设备切换、质量和观察时间，唯一 `lineDraft` 投影供三种功能使用。系统来源重复接纳先出现两个断言失败；generation/source/record 隔离及完整字段恢复先出现缺少中立 API 的编译红灯。修订后队列与助手相关定向套件 116 XCTest passed。
- 已完成 item 身份记忆上限默认 512；失败与未完成命令继续占用队列预算且不被身份过期移除。移除身份回收接线会使有界回归转红，恢复后通过。Ruling：类型中立化但暂保留既有源文件名 `AssistantInputPersistenceQueue.swift` 与测试文件名，以复用两个构建系统已登记的编译单元，避让 pbxproj 在途改动；代价是文件名不能直接表达新类型，正式合同明确导航到此处，后续单独安全重命名，不引入兼容层。
- Meeting/Caption 已接入同一保存内核；receiver 的正文保存只冻结和接纳，保存失败保留完整字段、同一 lineID 和复制文本。空 final 与 failed 的恢复 preview 都是稳定 partial，不生成另一条 formal 替代。保存前的有界 attribution 按 record/connection/generation/item 回放；跨场复用同 item/unit 时，旧失败命令的重试只写旧记录，当前文字和 speaker B 状态保持属于新场。
- Swift 6.4 的最小复现确认：lazy 初始化表达式内直接调用注入的异步 `@Sendable` 保存闭包会出现 `default argument cannot be both main actor-isolated and @concurrent`；去掉 Observation 宏/队列默认参数仍复现。将调用移入 feature 的具名保存方法后最小复现及 feature 编译通过，不调整隔离语义或工具链。
- Caption failed item 没有命令、Meeting partial 成功后提示仍“正在保留”的反例出现 4 个失败后转绿；会议两个控制测试的预期修正为当前 `readableError` 的精确 code+正文（不改生产错误格式）。真实 Realtime 客户端配 fake transport 在第二个 completed 出现前完成同 ID 的 retry，随后重复终态不会覆盖正文；不修改共享 ASR 测试或协议。
- 新结束 Gate 证明关闭等待活动保存，写前失败不归档，旧目标 retry 不投影新记录。测试 fixture 最初缺少 ASR echo 的 server final deadline、Meeting fake close 没有结束 stream，已修正 fixture；终止了那个明确定位的 XCTest 进程并单独复验，未操作本机服务。
- 容量拒绝在队列排空后曾被报告完整并归档：两场景合计 8 个断言失败。新增有界 `TranscriptAdmissionLedger` 和 `DrainReport.admissionRejections` 后转绿；失败/拒绝不能被“全部保存”掩盖。Ruling：拒绝内容未接纳，仅保留每场最近一次有界复制预览，重复拒绝/截断明示，已接纳失败命令仍完整占预算；拒绝证明不因复制自动消失。代价：目前缺少用户确认后的解除/结束流程，须在 R07 完成前补齐，不能把永久阻止新记录当作完成。
- staged 复核发现恢复材料的接纳提示覆盖容量拒绝提示；新增反例先出现 2 个断言失败，再由接纳结果决定提示，拒绝时继续明确给出复制出口。
- 最新定向 `swift test --package-path macos/SpeechRailApp --filter "SessionStoreTransactionTests|TranscriptItemLedgerTests|AssistantInputPersistenceQueueTests|AssistantSessionTests|AssistantCancelReceiveTests|AssistantDrainTests|SessionSealContractTests|MeetingSessionLifecycleTests|MeetingRecoveryMaterialTests|CaptionSessionLifecycleTests"` → **198 XCTest、0 failures、exit 0**（2026-10-07）。这是保存 owner 子任务的实测；R07 尚未独立审查/创建 PR/运行必要 CI。
- [保存合同草稿](../architecture/transcript-persistence-contract.md) 与架构导航已建立，`under_review`。下一步仍须移出保存后 attribution 的 receiver I/O、冻结 metadata 的异步目标、接用户重试/复制和拒绝恢复入口，再做一次整包审查与 CI。R08/R09 不提前启动；#245 禁写边界继续有效。
- 保存接线子任务已提交并推送 `e60b79b36167c062671384bb812bddf54865f966`；#232 / #238 的进度评论分别为 `issuecomment-6030341273` / `issuecomment-6030341587`，明确保留未完成门槛，没有关闭 issue。
- 共享 owner 新增 `enqueueProjection`：同一 worker 处理正文和辅助写入，活动辅助任务继续占 128 项/1,024 units 预算，仅合并 queued 的相同 record/line 更新，辅助任务 queued/in-flight 时不会报告该 record settled。新增端口/预算测试先编译红灯；辅助任务优先会挤占正文的公平性反例出现 1 个失败后，改为两类工作轮换。包含三个新增队列反例的同一范围定向验证 → **201 XCTest、0 failures、exit 0**。该端口还未接入 Meeting/Caption；不得提前宣称其 attribution I/O 已移出 receiver。
- Meeting/Caption 已将保存前归属回放与保存后 attribution 接到 `enqueueProjection`。正文确认后仅排辅助工作，不在 didSave 内等待它；queued/in-flight metadata 继续阻止本 record 提前 settled。超预算保留正文并给出辅助信息不完整提示。两个零容量反例先出现 2 个真实 Store timing 断言失败，接线后转绿；两个 Store Gate 证明写入挂起时控制事件仍消费且 settled 不提前返回。
- `SpeakerLabeling` 整批冻结 unit/line/label/lifecycle；begin/load/end 使旧 UI 投影失效，unit 重绑清旧行确认，旧任务不读取新映射。四个真实 SQLite 反例先出现 7 个失败后转绿；追加同记录新生命周期的 queued 命令、nil 修订清除回归。Ruling：旧任务继续写冻结目标，但只发布已确认且仍属原生命周期的界面变化——保证已接纳工作的完整性，同时避免把迟到成功或失败投到新场；代价是旧场辅助错误不会覆盖当前场提示。
- attribution 局部批次按整行替换会抹掉已接纳的另一批 unit 修订：两个 Gate 反例出现 4 个失败断言。Ruling：此类修订禁用整行 coalescing，逐批受相同 128 项/1,024 units 预算约束——不假设每次事件都是整行完整快照；代价是高频局部更新更早达到预算，达到时明确提示辅助信息未保存，正文仍保留。
- 最新同范围追加 `SpeakerLabelingPersistenceTests` 的定向命令 → **211 XCTest、0 failures、exit 0**（2026-10-07）。无真实模型/设备、UI、服务或安装操作。R07 尚待恢复入口、拒绝结束路径、整包独立审查和必要 CI。
- 会议页、字幕页和字幕浮层复用同一 retry/copy/不完整结束组件；记录按观察日期选取，动作冻结 record ID。浮层恢复入口位于常驻页脚，不依赖 hover；恢复材料在会议/字幕回看区单独可读可复制，正式读取/全文复制/默认导出不收 partial。没有新增 Token 或修改 pbxproj。
- `TranscriptAdmissionRecovery` 冻结拒绝版本、固定恢复行与日期。显式确认后先等待所有已接纳命令，保存有限 partial 说明，再按 interrupted 封存并读回确认，最后才解除本记录的拒绝证明。新增拒绝使旧确认失效；失败保留原身份供重试。Ruling：将拒绝预览存为说明性 partial，并按中断结束来释放恢复限额——承认未完整保留，不用清空账本冒充完整保存；代价是多句/过长拒绝仍不能恢复全部正文，UI、复制和用户指南明确说明。
- 3 个端口/版本反例先编译红灯后通过；另外 6 个真实 Store/Gate 边界证明不完整结束不能丢已接纳失败项、旧 record 不停止新场、预览写入失败时保留证明且同 ID 重试。最终同范围 **220 XCTest、0 failures、exit 0**；`scripts/macos_app_build.sh --configuration Debug --timeout 600` 成功，恢复回看 UI 最终修改后重新构建也成功。未做 UI 自动化、视觉/VoiceOver 走查，未操作生产服务或安装。新用户说明见 [找回未保存的文字](../users/transcript-save-recovery.md)。
- 首轮 CI `37571682793` 的 Quality Gates 通过，Swift/App 在确认框 `item:` 重载处编译红灯。本机 SDK 与 CI SDK 差异已从两条编译日志核实；Ruling：改用基线原生 `isPresented:presenting:`，将不可变快照交给 actions 捕获——不升级 CI、不改最低平台、不让用户确认改绑新记录；代价是显式维护展示 Binding。修订后本机 **220 XCTest、0 failures、exit 0** 与 App 包装 Debug 构建均通过，CI 待匹配新 head 验证。
- 一次整包独立审查范围 `4f6b7356..81b2cb27` 完成，无 Critical。Required：正文容量拒绝后，迟到 attribution 永远无法对接正式行，成功不完整结束后仍占缓存预算。两条跨记录反例复现新行 `timingQuality=unavailable` 而非 aligned；最小修复是在 sealed、读回及精确拒绝确认均成功后按 record 释放缓存。Ruling：只回收已确认结束记录的孤立 attribution——既释放无未来消费者的预算，又保留其他场；代价是结束记录的未匹配辅助信息不再驻留。
- 审查指出不完整结束的封存失败/并发缺少 feature 集成断言，已补两种 feature 的 archive 失败、会议 source_snapshot 失败、两条并发结束测试与缓存 record 隔离测试。临时移除并发守卫出现 **6 个失败断言**；临时移除封存确认守卫出现 **18 个失败断言**，随后全部恢复。最终定向范围 **228 XCTest、0 failures、exit 0**；测试 SQL trigger 只作用于测试自建 SQLite，没有生产故障开关。
- Final: minor (deferred): `docs/developers/macos-app-development.md` 仍以源文件旧名引用队列类型；当前合同已区分 `TranscriptPersistenceQueue` 类型与保留的注册文件名，未扩写无关开发手册。
- Final: minor (deferred): Store 同 ID 冲突回归只单独变更正文，其余不可变字段已有实现比较与丰富同 ID 成功核对，字段逐项冲突测试暂未扩充。
- Final: minor (deferred): 复制路径已静态确认只读，专门“复制后仍有拒绝证明”的 feature 回归未增加；UI/键盘/VoiceOver 未实测。完整 EOF/截止时间/协议失败封存资格仍由 R08 联合验收。

## 6. 来源

- 11 个 issue 全文历史 + 2026-10-07 状态同步评论（`issuecomment-6027094348` epic；各 issue 同日评论见时间线）。
- 新基线只读证据：`git log dc0744fb..b91e6f88 -- <file>` + 当前源码行级核对（§1 括号内锚点为阅读定位，非长期合同）。
- r1 `docs/implementation/2026-10-07-issue-238-solid-loop-plan.md`（随 PR #320）：分组/边界/跨包门结论继承；不一致处以本文件为准。
