<!-- loop-plan: 2026-10-07 -->
# Issue #238 DRY / SOLID 收敛 Loop 实施计划（新基线 `159fea09`）

> 供实施者逐包执行的 loop 计划：每轮 1–3 个内聚 issue、一个 PR。本文件基于最新 main 只读复验，不含业务改动；上一版（2026-10-06，基线 `65df3aa6`）保留为历史，其 R01–R09 分组与文件边界结论仍有效，本文件只更新“基线变化导致差异”的部分。

**Goal:** 11 个 issue（#231 #232 #234 #235 #236 #237 #240 #241 #242 #244 #246）分 9 个 PR 交付；先修完整性与生命周期，再收敛规则；与 #245 团队零文件冲突。

**Spec:** [Epic #238](https://github.com/hrygo/SpeechRail/issues/238)、[Epic #245](https://github.com/hrygo/SpeechRail/issues/245)。

**核验日期：** 2026-10-07，Asia/Shanghai。基线 `origin/main = 159fea09`（与主工作树一致，本 worktree 已 fast-forward 到此）。

## 0. 基线与 #245 现状（只读快照）

- `origin/main = 159fea09`：自旧计划基线新增 57 提交，几乎全部是 #245 系（ASR 内核/策略/decoder/场景消费/验收证据）与矩阵文档。
- #245 子任务状态：#247 #248 #250 #251 #252 为 CLOSED；**#249（WP3 解码/调度）与 #253（WP7 验收）仍 OPEN**。
- 4841 worktree（`codex/multiscene-asr-245`）：相对 main 仅剩 1 行预设改动（提词器 preview 500ms，#249）+ delivery 文档，未提交但量小。
- 远端仍有未合入分支：`codex/asr-production-consumer-replay-253`（Caption 消费回放测试，约 881 行）、`codex/189-audio-digest-wiring`（AppModel/AudioDigest）。
- 本 worktree：分支 `codex/238-r01-artifact-publish`，已同步到 `159fea09`；R01 在制品代码改动已 stash（旧基线产物，实施时重做，不直接恢复）。

## 1. 十一条逐条复验结论（`159fea09` 只读核对）

复验方法：`git log dc0744fb..HEAD -- <file>` 定文件是否被 #245 改动，再读当前源码确认根因。结论分三档：**未修**（可按原计划做）、**部分改善**（范围收窄，见备注）、**须等待**（文件被占用）。

| Issue | 档 | 当前事实（main） | PR 包 |
|---|---|---|---|
| #244 短写制品 | 未修 | `runtime/local_file_processor.py::_write_artifact` 仍单次 `os.write` + `O_TRUNC` 先截断；测试文件只有 CI 时序修复 | R01 |
| #240 owner 登记 | 未修 | `RuntimeLifecycle._pending` 仍只有 asr/tts/streaming；`alignment_worker` 只在 evictor 名单，不在 lifespan；另发现 `start()` 中 `evictor.start()` 失败后已建 runner task 未撤销（实施时定点确认） | R02 |
| #246 活动保护 | 未修 | `WorkerIdleEvictor._in_use` 仍只看 lease/mode_gate；对齐走 `AlignmentAdmission` 计数，未接入 evictor 活动事实 | R02 |
| #235 验证用例 | 未修 | `voice_designs.py` / `system.py` 自 dc0744fb 零提交 | R03 |
| #237 坏 2xx | 未修 | `LLMProvider.check` 仍 `guard 2xx → return .connected`（约 2472–2480 行），不解析 body；文件零提交 | R04 |
| #236 中立支持 | 未修 | provider 仍持有 `TeleprompterAIObservationHandler` / `TeleprompterAICallContext` / `TeleprompterStrictJSON`；文件零提交 | R04 |
| #242 改名事务 | 未修 | `SessionStore.renameSpeaker` 仍 SELECT → UPSERT → INSERT 三次独立 `withStatement`，无事务（约 369–397 行） | R05 |
| #241 封存结果 | 部分改善 | `sealSessionReporting` / `sealMeeting` 已类型化 + 读回确认；**剩余**：`SessionCoordinator.finalize`（约 442–473 行）与 `endAssistant` 纯文字分支（约 546–557 行）仍 `try?` + 无条件发布成功 ID | R06（范围收窄到这两处） |
| #232 保存恢复 | 部分改善 | Meeting/Caption 已接 `TranscriptPreviewLedger` 去重，失败转恢复材料；**剩余**：失败无固定 lineID 可恢复命令（Meeting 每次新 UUID，重试会多行；Caption 失败仅留文案），`appendLine` 行 INSERT 与 outbox 入队是两次独立提交（新增“已存但报失败”边界） | R07 |
| #231 收尾屏障 | 部分改善 | Meeting drain 路径 `invalidate` 已延后（abort 路径保留先撤权，正确）；Assistant `stopCapture` 已有 draining lifecycle + `waitForInputSaves` + pendingSeal；**剩余**：Meeting/Caption 停止路径等待了消费（`pump.value`）但不检验保存成败、无等价 settled 证明，失败只进 `lastFailure` | R08（范围收窄为收尾证明面） |
| #234 loader 规则 | 须等待 | 规则仍双份（worker 内 `_loader_value/_loader_quantization` 与 `model_identity` 并存，TT S 侧亦然）；但 `qwen3_worker.py` 已被 #249 大改（decoder/policy/终态），文件未释放 | R09（等 #249 关闭后） |

以上均为静态只读复核；旧 issue 正文中的隔离探针是历史证据，不计入新基线通过项。

## 2. PR 分组（沿用 R01–R09，9 个 PR / 11 issue）

| 包 | Issue | 一句话交付 | 基线状态 |
|---|---|---|---|
| R01 | #244 | staging + 完整写 + 原子发布 + 状态核对 | 可立即做 |
| R02 | #240 + #246 | owned 登记 + 启动回滚 + 活动/回收同协调点 | 可立即做 |
| R03 | #235 | 两个验证应用用例 + 同次执行证据 | 可立即做 |
| R04 | #237 + #236 | 先修 false-ready，再提中立解析/观测 | 可立即做（LLMProvider 无人占用） |
| R05 | #242 | rename 三语句同一事务 + 同名重试幂等 | 可立即做 |
| R06 | #241 | finalize/endAssistant 文字分支改用 reporting seal（收窄后） | R05 后（同文件串行） |
| R07 | #232 | 唯一保存内核 + 固定 lineID 回读 + 行/outbox 提交合同 | R06 后；Caption 文件注意 consumer-replay 分支 |
| R08 | #231 | Meeting/Caption 收尾保存证明 + 失败可见（收窄后） | R06/R07 后 |
| R09 | #234 | 纯 loader 内核，先 TTS 后 ASR | 等 #249 关闭释放 `qwen3_worker.py` |

R01–R09 是工作包编号，不是 GitHub PR 号；永不 `Closes #238`，未全验的 issue 用 `Refs`。

## 3. 启动顺序（最佳路径）

```text
R01 → R02 → R05 → R03 → R04 → R06 → R07 → R08 → R09
```

- R01/R02/R05 零冲突且无前置，先拿下：制品状态、资源回收、Store 小事务互不碰文件。
- R03（Python 路由）与 R04（`LLMProvider.swift`）文件都空闲，任一皆可先行；放在 R05 后是为了让 Swift/Store 热点一次至多一处写入。
- R06 → R07 → R08 必须串行：同一批 Store/Session 文件，seal seam → save 内核 → drain 接线。
- R09 殿后：等 #249 关闭（4841 仅剩 1 行预设 + 文档，预计近），绝不等整个 #245（#253 真实验收独立，不阻塞）。
- #231/#232/#241 之间、#240/#246 之间不设整单循环 blocked-by；接口可先行、实现串行、联合验收。

## 4. 与 #245 及其他分支的文件边界

### 4.1 禁写区（#249 关闭前不碰）

`backends/qwen3_worker.py`、`qwen3_streaming.py`、`qwen3_stream_decoder.py`、`domain/asr_policy.py`、`application/asr_turn_coordinator.py`、`application/realtime_openai.py`（ASR 部分）、`ASRScenePreset.swift`、`AssistantInputTurnAssembler.swift`、`TranscriptPreviewLedger.swift`、`RealtimeContractTypes.swift`（ASR wire 部分）。

### 4.2 #238 可写区（自 dc0744fb 零提交，已核对）

`runtime/local_file_processor.py`、`job_runner.py`、`jobs.py`、`job_artifacts.py`、`application/lifecycle.py`、`runtime/worker_lease.py`、`runtime/alignment_admission.py`、`application/alignment.py`、`application/services.py`、`backends/model_identity.py`、`qwen3_tts_worker.py`、`http/routes/voice_designs.py`、`http/routes/system.py`、`SessionStore.swift`、`SessionCoordinator.swift`、`LLMProvider.swift`。

### 4.3 需交接的共享文件

- `MeetingSession.swift` / `CaptionSession.swift` / `AssistantSession.swift`：已被 #250/#251（b6eada5b）改过；R07/R08 开工前以当时 main 重定基线，一次只一处写入。Caption 另注意远端 `consumer-replay` 分支的测试文件，重叠时先合入或错开。
- `RealtimeASRClient.swift`：R08 只读其 `drainAndClear` 合同，不改 ASR 事件/策略逻辑。
- `ServiceContractTests.swift` / `AppModel.swift`：`189-audio-digest` 分支在改；R06–R08 若碰同一测试文件，先核对 head。

### 4.4 Owner 划分（一句话）

#245 负责识别事实（item/revision/span/segment-close/轮次）；#238 负责已接纳内容的保存命令、消费屏障、封存证明。一方的“完成”不代替另一方的验收。

## 5. 每轮 loop 执行规则

- [ ] **定基线**：记录 checkout、base/head、在途分支 heads；只读核对同文件变更来源。
- [ ] **领边界**：列出 issue、精确文件、输入/输出接口、禁写项；同一文件同时只一个写入者。
- [ ] **补反例**：先写失败回归并确认红灯（TDD），再做最小修复。
- [ ] **最小验证**：本包定向测试 + `ruff`/`swift` 编译 + `git diff --check`；记录实测命令与 SHA。
- [ ] **成 PR**：分支 `codex/238-rXX-<slug>`，一个 PR 只关联本包 1–3 issue；无提交/push/合并授权时停在 merge-ready。
- [ ] **更新账本**：§6 填真实 SHA/日期/未验项；下一轮从新 head 重建判断。

## 6. 执行账本

| 包 | 状态 | 真实 PR / SHA | 备注 |
|---|---|---|---|
| R01 #244 | planned | 无 | 旧分支有 stash 的旧基线 WIP，实施时在新基线重做 |
| R02 #240+#246 | planned | 无 | — |
| R03 #235 | planned | 无 | — |
| R04 #237+#236 | planned | 无 | — |
| R05 #242 | planned | 无 | 注意源码注释与行为不一致（首次命名事件），修注释不改业务 |
| R06 #241 | planned | 无 | 范围已收窄（§1 #241 行） |
| R07 #232 | planned | 无 | 注意 consumer-replay 远端分支 |
| R08 #231 | planned | 无 | 范围已收窄（§1 #231 行） |
| R09 #234 | planned | 无 | 等 #249 关闭 |

## 7. 来源

- 11 个 issue 全文 2026-10-07 经 `gh issue view` 读取；#245 子任务状态同日读取。
- 新基线只读证据：`git log dc0744fb..159fea09 -- <file>`（§1 每行文件级）+ 当前源码行级核对（§1 括号内锚点为阅读定位，非长期合同）。
- 旧计划 `docs/implementation/2026-10-06-issue-238-solid-loop-plan.md`：分组/边界/跨包门结论继承；凡与本文件不一致处以本文件为准。
