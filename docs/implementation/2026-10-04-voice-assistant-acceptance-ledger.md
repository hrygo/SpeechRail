---
title: "语音助手用户旅程验收账本（VA-01～VA-18 / A01～A60）"
status: in_progress
version: "0.1.0"
date: 2026-10-04
---

# 语音助手用户旅程验收账本

- 需求依据：[SpeechRail 语音助手：按用户旅程优化的详细可执行方案](SpeechRail_Voice_Assistant_User_Journey_Executable_Plan_2026-10-03.md)
- 执行方案：[语音助手用户旅程优化：Luna 详细执行方案](2026-10-03-voice-assistant-user-journey-luna-guide.md)
- 分支：`codex/voice-assistant-journey-va`；基线 `71fc9231`；账本时间 2026-10-04 Asia/Shanghai
- 范围声明：本账本只记录确定性测试（D）与代码落点；U（人工/前台）与 R（真实模型/设备/长时）未授权执行，一律记 `not_run`，不得用 D 结果代替。
- 测试命令：`swift test --package-path macos/SpeechRailApp --filter 'Assistant'`（本轮 162 项通过，0 失败，2026-10-04 Asia/Shanghai 复验；含 AssistantReplayEvaluator 3 项 + A43 true 分支 1 项 + A13 unknown 终态 1 项 + A35 代码块跨片 1 项 + A50 seed 超限 1 项 + A47 活跃保护 1 项 + §7.3 A03/A04 交叉变体 2 项 + §7.3 A12 并发/顺序变体 2 项 + §7.3 A40/A52 ledger 变体 2 项 + §7.3 A35/A39 服务端小限额 1 项 + §7.3 A47/A50 future-schema 1 项）。
- runner 冒烟：`swift run --package-path macos/SpeechRailApp assistant-replay --manifest <仓库外JSON>` 可输出 `assistant.eval.v1` 聚合报告（合成事件冒烟通过，不含音频/正文；真实素材未跑）。
- 全包回归：`swift test --package-path macos/SpeechRailApp` 全通过、0 失败（2026-10-04 Asia/Shanghai 复验；`swift package clean` 后 `Executed 611 tests`，旧摘要行仍报 384/16 suites，属构建缓存口径差异；含新增 A43 true 分支 1； `--filter 'Assistant'` 158 项通过）；无连带回归。
- 本轮复验（2026-10-04 16:16 Asia/Shanghai）：`--filter 'Assistant'` 162 项通过（含 A43 true 分支 + A13 unknown 终态 + A35 代码块跨片 + A50 seed 超限 + A47 活跃保护）；全包 384 项/16 suites 通过（缓存口径；clean 后曾验 `Executed 611 tests`）；`swift package clean` 后全包 `Executed 611 tests` 通过（旧摘要行 384/16 suites 为缓存口径，未重建缓存前全包漏编新增未跟踪文件）；`git diff --check` 通过；runner 用 4 事件合成 manifest 输出 `assistant.eval.v1`（event_count=4/turn=1/completed=1/sealed=1，caveats 非空），空 events 按 `emptyEvents` 拒绝；真实素材未跑。
- A43 变体：`testA43VoiceFieldCanReplaySpeechIsTrue`（语音场建通道后 `canReplaySpeech == true`，与纯文字场 false 配对覆盖直透两分支）。变异验证：`canReplaySpeech` 恒 false 后按预期失败（1 failure），恢复后通过；生产文件无残留。
- §7.3 A12 变体：`testA12EndDuringAskKeepsAcceptedQuestion`（并发）+ `testA12EndAfterAskSealsSameRecord`（顺序）。并发版加强断言时曾暴露用例竞态（end 快照早于 ask 建记录则合法 noConversation），已按“结束只认快照身份”修正口径，顺序版覆盖 ended 分支；并发版连跑 5 次稳定通过。
- §7.3 A40/A52 变体：`testPlayedMissingNeverClaimsCompletion`（played 缺失不宣称完成）+ `testRebuiltDeviceOldRenderedAndPlayedAreRejected`（重建后旧代双回拒收）。三处变异（去 played 门、去 complete/markPlayed 代门）共 5 failures，恢复后通过；生产文件无变异残留。
- §7.3 A35/A39 变体：`testSmallerServerLimitsFailBounded`（started 小限额 maxAppend=4，6 scalar 经 flush 交出后有界失败、不发出）。初版用例因无标点文本不触发 readyChunks 且 ACK 配置错而失败，已按 flush 路径修正；去掉服务端限额门后按预期失败（2 failures），恢复后通过。
- §7.3 A47/A50 变体：`testFutureSchemaVersionIsRejected`（user_version=99 的库 open 抛 unsupportedSchemaVersion）。去掉 future 守卫后按预期失败，恢复后通过；生产文件无变异残留。迁移失败 rollback 无注入点（真实 SQLite 建表失败表达不了），记限制。
 - §7.3 未补（无对应生产分支，不硬凑）：A21 同 endpoint 只换 model（已试补但为无效断言：`llmModel` 开场赋值、`runReply` 快照只影响下行 model，Fake 不记录下行 model，用例已删除）、A24 同 route 扩大发送范围（无独立 consent 状态机）、A05/A06 receipt/marker 时序（无独立事件）、A09/A10 提交后超时（Session 直调真实 Store，无注入门）、A35 未完成数字 deadline（buffer 安全切分已有分包用例覆盖语义；代码块跨片已补 `testA35UnclosedCodeSpanIsHeldUntilItCloses`，fence 变异验证有效）、A50 seed 超限（已补 `testA50ContinuationSeedTruncatesToMaxTurns`，maxTurns 变异验证有效）、A47 活跃记录移除保护（已补 `testA47ActiveRecordSealIsSkippedNotSealed`，skipped 变异验证有效；迁移失败 rollback 仍无注入点，记限制）。
- 交付报告：`2026-10-04-voice-assistant-implementation-report.md`（v0.1.0，draft_uncommitted）已按执行方案 §10.3 落盘，汇总 base/head、18 包、A 矩阵、三方一致、误停、对照缺口与回退；D 明细以本账本为准。
- 拟提交单元（未执行，需明确授权）：① M0 安全底座（VA-01～06 + VA-16 最小计数 + 相关 D 用例）；② M1 主旅程（VA-07～10 + VA-15a + 纯策略与 presentation）；③ M2 朗读与分包（VA-11/12 + buffer/ledger/coordinator + 回放评估器与 runner）；④ M3 上下文与续接（VA-13/14/15b + turn/context policy）；⑤ 资产与文档（账本/U/REAL/报告 + 开发者文档 0.6.1 + Package target）。顺序按 M0→M3，每单元精确暂存、`git diff --staged --check` 后本地 commit，不带无关文件，不 push。
- A13 变体：`testA13UnknownFailedTerminalLeavesNewRoundUntouched`（语音场 unknown 失败终态不改 phase/error/正文，与 coordinator 层 `testStaleIdentityIsIgnored` 配对）。变异验证：去掉 Session 层 `currentRequestID` 身份门后按预期失败，恢复后通过；生产文件无残留。retired 分支仍由 coordinator 闩语义覆盖，记限制。
- §7.3 变异验证：禁用 `terminalSignals` prefetch 后 `testTerminalArrivingBeforeWaitStillConfirmsCancel` 按预期失败，恢复后通过；禁用 `handleTerminal` 身份门后 `testOldTerminalDoesNotLeakIntoNewStart` 按预期失败（2 failures），恢复后通过；生产文件无变异残留（`AssistantTTSStreamCoordinator.swift` diff 仅 VA-05 改动）。
- §7.3 证据限制：“cancel effect 本身被 end 取消”在 coordinator 层无外部可断言行为（`invalidate()` 清的是 `cancelServerBounded` 内部竞速任务，已被闩语义覆盖；禁用该清理后用例仍通过，属无效断言，已删除用例不硬凑）。
- 验收文档：U 清单 `2026-10-03-voice-assistant-ui-acceptance.md`（v0.1.0，not_run）、R 入口 `2026-10-03-voice-assistant-real-acceptance.md`（v0.1.0，not_run）已落盘；离线回放 `AssistantReplayEvaluator` + `assistant-replay`（Package 已声明 target）已建，A59/A60 真实长时仍记 R not_run。
- 文档更新：`docs/developers/macos-app-development.md` 0.6.0 → 0.6.1（2026-10-04），新增「续接、重播与试听」小节；仅正文实质变更更新 version/date。
- 工作区改动未提交；无 push/PR/merge/release；无服务启停、模型下载、录音与 UI 自动化。
- PR #213 CI（2026-10-04 Asia/Shanghai，run 37188962265）：Change Scope pass；Quality Gates fail（`check_macos_test_target_coverage.py` 报 13 个新增测试文件未进 Xcode Unit Test Sources）；macOS App Build fail（`AssistantView.swift:1877/2759` 报 `cannot find 'AssistantComposerPolicy' in scope`，缺 App Sources 成员）；`swift test`（SPM 超集）不受影响。缺口 19 文件：生产 6（Composer/Context/Observability/Presentation/ReplayEvaluator/TurnPolicy）+ 测试 13；runner 无 Xcode target 不计入。本地 `xcodebuild build` 复现同一失败（2026-10-04）。pbxproj 按规则不在本机手工合并，待 Xcode 内补成员后复验；此期间 PR 不合并。
- PR #213 CI：run 37188962265 曾 fail（Quality Gates：13 个新增测试文件未进 Xcode Unit Test Sources；macOS App Build：`AssistantView.swift:1877/2759 cannot find 'AssistantComposerPolicy' in scope`）。修复提交 `dd74b444` 补齐 19 文件 membership（生产 6 进 App Sources + 测试 13 进 Unit Test Sources，只做加法，未删改既有条目；runner 无 Xcode target 不计入）后，run 37190082198 全绿（2026-10-04 Asia/Shanghai 实测：Quality Gates pass 35s / macOS App Build pass 6m33s / Gate Summary pass；本地 `check_macos_test_target_coverage.py OK` + `xcodebuild build BUILD SUCCEEDED`）。U/R 仍 not_run，PR 不合并。

## VA 工作包状态

| 工作包 | 状态 | 说明 |
|---|---|---|
| VA-17a 工装与账本 | done（D） | Fake/临时 Store/账本可用；本账本即 VA-17b 的过程版本 |
| VA-01 结束隔离 | done（D） | A01/A02/A18 通过 |
| VA-02 取消接收解耦 | done（D） | A03/A04/A08/A55 通过 |
| VA-03 排空封存 | done（D） | A05/A06/A07/A47 通过 |
| VA-04 回复幂等 | done（D） | A09/A10/A11/A12 通过 |
| VA-05 身份过滤 | done（D） | A13/A14/A15/A52（D 部分）通过 |
| VA-06 路由冻结 | done（D） | A21/A22/A23/A24（D 部分）通过 |
| VA-07 文字可用 | done（D） | A16/A17/A19/A20（D 部分）通过 |
| VA-08 可信首屏 | done（D） | A25/A26/A27 + 十二态纯测试通过；真实视觉走查记 U not_run |
| VA-09 草稿阅读 | done（D） | A28/A29/A30 + IME 路由纯策略通过；A31/A32 记 U not_run |
| VA-10 模态提示 | done（D） | A33/A34（D 部分）通过；真实输出记 R not_run |
| VA-11 分包保真 | done（D） | A35/A36/A37/A38（D 部分）/A39 通过；A38 真实朗读记 R not_run |
| VA-12 播放交付 | done（D） | A40/A41（D 部分）/A42（D 部分）/A43（D 部分）/A44 通过；真实尾延迟记 R not_run |
| VA-13 接话策略 | done（D） | A08 必修通过；聚合/duck 维持关闭（deferred_evidence）；A56/A57/A58 记 R not_run |
| VA-14 上下文记忆 | done（D） | A41（D 部分，随播放）/A45/A46/A48 通过；真实语义记 R not_run |
| VA-15 记录闭环 | done（D） | A47/A49/A50（D 部分）/A51 通过；A50 用无 schema 变更的种子续接实现，schema v2 仍记 deferred |
| VA-16 观测 | done（D） | A52（D 部分）/A53/A54 通过 |
| VA-17b 完整资产 | done（D+资产） | D 账本齐；U/REAL 文档已建（均 not_run）；`AssistantReplayEvaluator` + `assistant-replay` 已建并回归；A59/A60 真实长时仍记 R not_run |
| VA-18 交付门禁 | partial | 代码/D/账本齐；Package 已补 SPM（含 assistant-replay），Xcode membership 未补（手工改 pbxproj 风险高，留待 Xcode 内操作）；文档已部分同步（0.6.1 续接重播试听）；安装/性能对照未做 |

## A01～A60 状态矩阵

| ID | 类型 | 状态 | 证据 |
|---|---|---|---|
| A01 | D/U | D pass / U not_run | AssistantEndRoutingTests.testA01TextEndWithoutOccupancy |
| A02 | D/U | D pass / U not_run | AssistantEndRoutingTests.testA02TextEndWhileMeetingOwnsLease |
| A03 | D | pass | AssistantCancelReceiveTests.testA03BargeInTerminalThroughReceiveLoop |
| A04 | D | pass | AssistantCancelReceiveTests.testA04CancelTimeoutFailsClosed |
| A05 | D | pass | AssistantDrainTests.testA05TailFinalDuringDrainArchivesOnly |
| A06 | D | pass | AssistantDrainTests.testA06ReceiptCannotBypassStoreGate |
| A07 | D | pass | AssistantDrainTests.testA07DrainClassifiesEmptyFailedAndTimeout |
| A08 | D | pass | AssistantTurnPolicyTests.testA08EvidenceEmptyDuplicateAndFinalOnly |
| A09 | D | pass | AssistantReplyPersistenceRaceTests.testA09LatePartialInsertKeepsNewReply |
| A10 | D | pass | AssistantReplyPersistenceRaceTests.testA10LateFinalizeCannotClearNewReply |
| A11 | D | pass | AssistantReplyPersistenceRaceTests.testA11ConcurrentTerminationClaimsOnce |
| A12 | D | pass | AssistantReplyPersistenceRaceTests.testA12ConsecutiveInputsRetirePredecessor |
| A13 | D | pass | AssistantStaleEventTests.testA13OldRequestCannotChangeNewState + `testA13UnknownFailedTerminalLeavesNewRoundUntouched`（Session 层 unknown 失败终态，变异验证有效） |
| A14 | D | pass | AssistantStaleEventTests.testA14OldPlaybackEpochCannotRefundNewBudget + PlaybackLedger A44 |
| A15 | D | pass | AssistantStaleEventTests.testA15SupersededStartupCleansPrivateLeaseOnly |
| A16 | D/U | D pass / U not_run | AssistantTextAvailabilityTests.testA16DeniedMicrophoneKeepsTextUsable |
| A17 | D/U | D pass / U not_run | AssistantTextAvailabilityTests.testA17VoiceLossKeepsTextContext |
| A18 | D/U | D pass / U not_run | AssistantEndRoutingTests.testA18RepeatedAndReviewedEndTargets |
| A19 | D/U | D pass / U not_run | AssistantTextAvailabilityTests.testA19VoiceUpgradeRequiresOccupiedLeaseDecision |
| A20 | D | pass | AssistantTextAvailabilityTests.testA20RetryPreservesConversationMuteAndRoute |
| A21 | D/U | D pass / U not_run | AssistantRoutingTests.testA21PreferencesCannotRerouteLiveConversation |
| A22 | D | pass | AssistantRoutingTests.testA22TextAndVoiceShareContextInitialization |
| A23 | D | pass | AssistantRoutingTests.testA23MemoryLoadFailureNeverReusesPreviousSession |
| A24 | D/U | D pass / U not_run | AssistantRoutingTests.testA24ConsentTracksDestinationAndPayloadScope |
| A25 | D/U | D pass / U not_run | AssistantPresentationTests.testA25ConfiguredDoesNotMeanVoiceReady |
| A26 | D/U | D pass / U not_run | AssistantPresentationTests.testA26TextAssistantDoesNotBorrowOtherMeters |
| A27 | D/U | D pass / U not_run | AssistantPresentationTests.testA27OldReviewHasNoLiveConnectionOrFreshSuccess |
| A28 | D/U | D pass / U not_run | AssistantComposerPolicyTests.testA28TemplateCannotSilentlyReplaceDraft |
| A29 | D/U | D pass / U not_run | AssistantComposerPolicyTests.testA29SendCompletionPreservesNewDraft |
| A30 | D/U | D pass / U not_run | AssistantComposerPolicyTests.testA30ReadingPositionControlsFollowLatest + IME 路由纯策略 |
| A31 | U | not_run | 需中文 IME/键盘人工验收，未执行 |
| A32 | U | not_run | 需窗口/无障碍人工验收，未执行 |
| A33 | D/R | D pass / R not_run | VoicePromptTests.testA33ModalityPreservesRequestedStructure |
| A34 | D/R | D pass / R not_run | VoicePromptTests.testA34CriticalRecognitionAmbiguityIsNotGuessed |
| A35 | D | pass | AssistantSpeechTextBufferTests.testA35SixHundredScalarsPartitionEquivalence + `testA35UnclosedCodeSpanIsHeldUntilItCloses`（代码块跨片，fence 变异验证有效） |
| A36 | D | pass | AssistantPlaybackLedgerTests.testA36UnicodeScalarAndAckAgreement |
| A37 | D | pass | AssistantPlaybackLedgerTests.testA37WordsAndWhitespaceSurviveChunking |
| A38 | D/R | D pass / R not_run | AssistantPlaybackLedgerTests.testA38NumericTokensRemainFaithful |
| A39 | D | pass | AssistantSpeechTextBufferTests.testA39BudgetsAreAtomicAndRespectNegotiatedLimits |
| A40 | D/R | D pass / R not_run | AssistantPlaybackLedgerTests.testA40TerminalWaitsForPlayedEvidence |
| A41 | D | pass | AssistantReplyPersistenceRaceTests.testA41InterruptedPlaybackDoesNotInventHeardText |
| A42 | D/U | D pass / U not_run | AssistantCancelReceiveTests.testA42ReplayInterruptTargetsOriginalTurn |
| A43 | D/U | D pass / U not_run | `testA43ReplayAndSoundPreviewHaveRealActions` 断纯文字场 `canReplaySpeech==false` + `testA43VoiceFieldCanReplaySpeechIsTrue` 断语音场 `canReplaySpeech==true`（复用 voice harness，变异验证有效）；试听走 previewSelectedVoice、禁播原因文案均为 View 接线（D 不覆盖）；U 走查 not_run |
| A44 | D | pass | AssistantPlaybackLedgerTests.testA44PendingVoiceTracksActualNextRequest |
| A45 | D | pass | AssistantContextPolicyTests.testA45ContextBudgetKeepsCompleteRecentTurns |
| A46 | D/U | D pass / U not_run | AssistantContextPolicyTests.testA46MemoryRequiresEditedConfirmation |
| A47 | D/U | D pass / U not_run | AssistantDrainTests.testA47SealFailureRetainsUnsavedRecovery + `testA47ActiveRecordSealIsSkippedNotSealed`（活跃保护，变异验证有效） |
| A48 | D | pass | AssistantContextPolicyTests.testA48MemoryIsBoundedDataAndRevocationIsExplicit |
| A49 | D/U | D pass / U not_run | AssistantRecordObservabilityTests.testA49ReuseSettingsMakesNoContextPromise |
| A50 | D/U | D pass / U not_run | AssistantReplyPersistenceRaceTests.testA50ContinuationFreezesSelectedSourceTurns + `testA50ContinuationSeedTruncatesToMaxTurns`（seed 超限，变异验证有效）；生产 continueFromRecord + View 继续入口已接；schema v2 仍 deferred |
| A51 | D/U | D pass / U not_run | AssistantRecordObservabilityTests.testA51RecordOperationFailureCannotLookSuccessful + View 改名/删除/导出失败保留 |
| A52 | D/R | D pass / R not_run | AssistantStaleEventTests.testA52DeviceGenerationRejectsLateCallbacks |
| A53 | D | pass | AssistantRecordObservabilityTests.testA53LossAndUploadFailureAreBoundedAndVisible |
| A54 | D | pass | AssistantRecordObservabilityTests.testA54ObservabilityFailureAndNoSamplesAreHonest |
| A55 | D | pass | AssistantCancelReceiveTests.testA55ProviderFailureUsesOwnedCancellationBarrier |
| A56 | R | not_run | 需真人语料与标注，未执行 |
| A57 | R | not_run | 需多设备 AEC/双讲闭环，未执行 |
| A58 | R | not_run | 需噪声/复述评估，未执行 |
| A59 | R | not_run | 需 30～60 分钟长会话，未执行 |
| A60 | R | not_run | 需失败/休眠/设备旅程，未执行 |

## 未验证事项与风险

- schema v2（assistant_reply_state / playback_invocation / continuation / memory_provenance 表）未实施；A50 续接用内存种子实现，不依赖迁移。不得把“无 v2”等同“续接完成”的全部语义。
- Xcode project membership 未补：5 个新生产策略文件与新增测试文件仅进 SPM；Xcode 侧仍缺。pbxproj 手工合并已回退，需在 Xcode 内补成员后复验。
- 缺口明细（pbxproj 0 命中，需 Xcode 内补）：生产 6 个（AssistantComposerPolicy/AssistantContextPolicy/AssistantObservability/AssistantPresentation/AssistantReplayEvaluator/AssistantTurnPolicy）+ runner（AssistantReplayTool/main.swift）+ 新增测试 13 个；Package.swift 已声明 `assistant-replay` target，仅 SPM 可跑。
- U（A01/A02/A16～A19/A21/A24～A32/A42/A43/A46/A47/A49/A51）与 R（A33/A34/A38/A40/A52/A56～A60）全部 not_run；不得用 D 结果宣称通过。
- 性能/声学/安装/迁移均未执行；`SessionStore.schemaVersion` 仍为 1，无真实数据操作。
- 改动未提交：交付为未提交 diff；提交、推送、PR、发布均未授权执行。

## 回退方式

- 源码回退只作用本任务改动且保留他人修改；先 `git status --short` 确认唯一写入文件，再按 VA 包逐个 revert。
- 运行态回滚按专项流程；本轮未改变运行态，无需回滚服务、档位、安装与模型。
