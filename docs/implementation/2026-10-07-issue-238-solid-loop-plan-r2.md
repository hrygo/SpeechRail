<!-- loop-plan-r2: 2026-10-07, baseline 1edf9398 -->
# Issue #238 DRY / SOLID 收敛 Loop 实施计划 r2（新基线 `1edf9398`）

> r1（`2026-10-07-issue-238-solid-loop-plan.md`，基线 `159fea09`，随 R01 PR #320 提交）的后继修订。
> 凡与 r1 不一致处以本文件为准。当前目标包含实施、审查、验证、提交、推送及通过后的合并；分组/跨包门结论继承 r1。

**Goal:** 11 个 issue（#231 #232 #234 #235 #236 #237 #240 #241 #242 #244 #246）分 9 个 PR 交付。
**Spec:** [Epic #238](https://github.com/hrygo/SpeechRail/issues/238)、[Epic #245](https://github.com/hrygo/SpeechRail/issues/245)。
**核验日期：** 2026-10-07，Asia/Shanghai；CI 时间戳为 UTC。进度以本次回读的 SHA、PR 状态和 run ID 为准。基线 `origin/main = 1edf9398`（已 fetch）；每包合并后刷新。

**当前实施目标：** R01、R02、R05 已合入；剩余 7 个 issue 分 6 个 PR，按 R03 → R04 → R06 → R07 → R08 → R09 完成实施、实质审查、必要验证与通过后的合并。保持 #245 的语义边界；完整验收对照前不关闭 issue。结构化 goal 仍 active；现有接口不支持更新正文，旧正文中的基线、逐包等待确认和错误同文件判断均由本文更正，不将旧目标虚假标为完成。

## 0. 基线与 #245 现状（只读快照）

- `origin/main = 1edf9398`：包含 #249/#252 文档及提词器 preview 500ms 预设变更（这是业务行为变化）、#321 V17 回归、#324 3.8.0 发布提交，以及 R01/R02/R05。
- #245 子任务历史快照：#247–#252 CLOSED、#253 OPEN，开工前重新核验。`git worktree list` 当前未登记 4841；不据此断言目录不存在。已登记 acceptance-evidence、app-validation、boundary-fix、consumer-replay、delivery、validation-v8 等 ASR worktree。
- #320 R01（#244）已合并为 `451aeb1e`；#322 R02（#240/#246）已合并为 `1edf9398`；#323 R05（#242）已合并为 `ff34bfcf`。三包均在匹配的 head 上通过实质审查、定向验证与必需 CI 后 squash 合并。
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
| #235 验证用例 | 审查中 | 两个应用用例已接线；同次执行身份、unknown、CAS/撤销、保存失败、重复取消与 timeout/cancel 交错回归通过；369 项定向验证通过，待独立审查完成与必需 CI | R03 |
| #237 坏 2xx | 未修 | `LLMProvider.check`（约 2475–2480）2xx 即 `.connected`；`operationUnavailable` 只判 operation 不可用 | R04 |
| #236 中立支持 | 未修 | provider 仍持 `TeleprompterAIObservationHandler/Context/StrictJSON`（1175/1264/1382/1509+/1614 行）；零提交 | R04 |
| #241 封存结果 | 部分改善 | 剩余 `finalize`(442-)/`endAssistant`(543-) 纯文字分支 `try?` + 无条件成功 ID | R06（收窄） |
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
| R03 #235 | 审查中 | 无 | 基线 `1edf9398`；369 项定向 fake/HTTP/contract 回归、Ruff/Mypy 通过；独立审查及必需 CI 待完成 |
| R04 #237+#236 | planned | 无 | 主要修改 LLMProvider，与 R06 文件不同 |
| R06 #241 | planned | 无 | 范围收窄（§1 行） |
| R07 #232 | planned | 无 | 注意 consumer-replay 分支 |
| R08 #231 | planned | 无 | 注意 clear-barrier 分支，只读合同 |
| R09 #234 | planned | 无 | #249 关闭已解锁，排末位 |

### R03 验证与取舍（2026-10-07）

- 两个用例各自拥有状态/提交，共享有界执行组件；阶段表见 [执行所有权](../architecture/voice-validation-usecases.md)。HTTP 不导入其他 route 私有业务，application 不依赖 HTTP 框架。
- 先观察重复取消提前释放 reservation、timeout 后再次取消中断清理、质量保存失败错误类型、日志私密异常文本回归转红，再修复。移除 quality expected revision guard 使回归以 `DID NOT RAISE VoiceRevisionConflictError` 转红，恢复后通过。
- Ruling：阶段 task 与其 deadline 同 owner，复用 `join_cleanup`；deadline 已取消时不追加 cancel，避免第二次取消打断 backend 清理。回收未确认时保留 ownership 或隔离 lane；不将响应 deadline 解释为强制进程回收上界。
- Ruling：清理失败中止后续 probe/ASR/commit，返回不可自动重试的 `503 backend_reclamation_failed`；契约与独立用户说明同步。ASR 团队在改 `docs/users/api-contract.md`，本包不写该文件。
- 独立审查指出候选 close/eviction 的原始异常未映射，新增两个 HTTP 反例观察未处理 RuntimeError，再接稳定 503；共享 helper 的生成入口也补映射与 design lane 隔离。候选生成/验证和 quality-runs 共 5 个清理失败 HTTP 回归通过。
- 定向命令：`SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD=1 uv run pytest --no-cov -rA tests/test_voice_validation_execution.py tests/test_candidate_validation_usecase.py tests/test_voice_quality_routes.py tests/test_voice_design_workflow.py tests/test_voice_design_concurrency.py tests/test_voice_validation.py tests/test_voice_validation_residency.py tests/test_voice_quality_gates.py tests/test_voice_quality_evidence.py tests/test_voice_revision_routes.py tests/test_voice_revision_contract.py tests/test_tts_delivery.py tests/test_tts_errors.py tests/test_resource_governor.py tests/test_tts_profile_snapshot.py tests/test_openapi_contract.py tests/test_audio_error_contract.py tests/test_user_doc_contract.py` → 369 passed。
- `ruff check` 全部改动 Python；`mypy` 9 个生产 source 文件通过。没有运行完整本机测试、真实模型、服务/UI、性能或长稳验收。
- 提交前核对六个已登记 ASR worktree：本包路由、registry、架构导航、OpenAPI 无 dirty 或 branch diff；仅 API 手册存在独立 ASR 文档变更，已避让。新文件无对应图谱索引，按当前源码审查，不宣称图谱完整。

## 6. 来源

- 11 个 issue 全文历史 + 2026-10-07 状态同步评论（`issuecomment-6027094348` epic；各 issue 同日评论见时间线）。
- 新基线只读证据：`git log dc0744fb..b91e6f88 -- <file>` + 当前源码行级核对（§1 括号内锚点为阅读定位，非长期合同）。
- r1 `docs/implementation/2026-10-07-issue-238-solid-loop-plan.md`（随 PR #320）：分组/边界/跨包门结论继承；不一致处以本文件为准。
