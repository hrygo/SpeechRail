---
title: "有声书大规模选角 P0 定向验收记录"
status: active
audience: "开发者、验收工程师"
version: "1.0.0"
date: 2026-10-15
---

# 有声书大规模选角 P0 定向验收记录

## 范围与结论

对应 [规格 v2.0.1](../developers/audiobook-mass-casting-spec.md) 的八项 AC-P0，以及 [实施计划](../superpowers/plans/2026-10-15-audiobook-mass-casting.md) S0～S2。源码在 `codex/audiobook-production-progress` 的既有未提交工作区局部修改；无 commit、安装、服务/档位操作、模型下载或真实推理。S3～S5 未实施。

2026-10-15 20:14（Asia/Shanghai）的定向 Swift 集为 209 项、零失败；Python 为 9 项、零失败。新增的 51 个 Swift 测试方法均能在该次日志中找到实际通过记录，没有用跳过或零用例代替执行。该次执行包含迁移后旧 WAV/采用版本读取及批量末项反例；独立审查提出的五项 Important 已补失败反例并修复，结果见下文。

证据类型为确定性测试、源文件检查及临时 SQLite/文件副本核验；不证明真实声音质量、吞吐、长时稳定性、App 完整构建或前台 UI 验收通过。

## 八项 P0 与证据

测试位于 `macos/SpeechRailApp/SpeechRailMacControlTests/`；表内省略共同目录。所有书稿和 WAV 都是测试生成的夹具。

| 验收 | 主要用例与断言 | 结果 |
| :--- | :--- | :--- |
| AC-P0-01 参数与严格准入 | `ServiceContractTests.testCallerSeedTravelsAsHeaderAndSurvivesOptionCopies`、`testAudiobookRenderCarriesSupportedSeedToWire`、`testSeedBoundsRejectInvalidValues`、`testExistingCloneSeedRequiresReconfirmationWithoutSending`、`testProtocolDefaultRenderForcesStrictPolicyAndKeepsFrozenOptions`；`AudiobookCastTests.testClonePolicyOmitsCallerSeed`；`AudiobookProductionTests.testRenderRetriesKeepFrozenParametersAndStrictPolicy`；Python `test_base_clone_rejects_caller_seed`。捕获实际请求构造：header 保留 seed、body 无 seed；所有复制 helper 保留参数；确定性 HTTP 拒绝不重试，瞬态重试参数不变 | 通过 |
| AC-P0-02 候选与归属 | `AudiobookCastTests.testEmptyScopedPoolNeverFallsBack`、`testAvailableButNotProductionReadyIsExcluded`、`testMissingCustomScopeNeedsConfirmation`、`testCatalogReadFailureIsNotEmptyCatalog`、`testUnsupportedCandidateParameterExplainsExclusionWithoutRiskConsent`。验证 false/nil/unknown、他书/归档/缺少来源、目录损坏/未来格式；另由 `testOriginRoleIsPreferenceWithinBookScope`、`testCatalogIdentityMismatchFailsClosedAndChangesRevision` 核对来源偏好和目录语义损坏；问题区分具体原因及下一步，未采用候选的说明不要求接受风险 | 通过 |
| AC-P0-03 容量与匹配 | `testAliasesDoNotIncreaseVoiceCapacity`、`testCastingCapacityIncludesNarrator`、`testExclusiveMatchingDoesNotConsumeAnotherRolesOnlyCandidate`、`testUnprovenSilentLockedRoleStillReservesItsVoice`、`AudiobookStoreTests.testProvenSilentLockedBindingDoesNotConsumeSpeakingCapacity`。M=0/1/2/3/5/6、少角色、受限候选可行/不可行及旁白占用均有断言；无完整证据时不释放占用；Store 证实零台词后保留旧绑定但释放发声预算，重新发声恢复约束 | 通过 |
| AC-P0-04 既有选择与整批校验 | `testLockedDuplicateReturnsIssueWithoutDemotion`、`testBatchConflictNeverEnablesSharing`、`testNarratorCannotBeChangedToSharedPolicy`、`AudiobookWorkflowTests.testAutomaticLeadCreationPreservesExistingSystemBinding`、`testAutomaticVoiceReturnCannotOverwriteBindingAddedDuringCreation`；`testBatchLastMissingRoleOrUnreadyVoiceNeverCommitsEarlierBinding` 验证末项缺角色/未就绪整批拒绝；数据库故障见 AC-P0-07。`testCrossChapterSharingRequiresExplicitAcceptance` 核对跨章共享接受；`testGeneratedVoiceReturnFreezesBindingSet` 核对单角色返回竞争；已有声音不自动替换，旁白不降为共享 | 通过 |
| AC-P0-05 零台词与说话人门禁 | `AudiobookStoreTests.testSilentRoleExemptionRequiresCompleteAnnotations`、`AudiobookCastTests.testUnknownDialogueKeepsChapterGate`。完整分析、真实文本覆盖及已知说话人才允许零台词豁免；保留零台词历史绑定，包括待复核状态。`AudiobookProductionTests.testFormerlySilentRoleMustRecheckExclusivePolicyBeforeProduction` 防止角色重新发声后沿用旧确认绕过独占；缺标、unknown 和未完成分析仍阻断 | 通过 |
| AC-P0-06 冻结身份与追溯 | `ServiceContractTests.testRenderRejectsRevisionDriftInsteadOfRepinning`、`testSystemVoiceMayOmitVoiceRevision`、`testCustomVoiceMissingRevisionBlocksBeforeTransport`、`testMissingReceiptKeepsActualIdentityUnknown`、`testWAVLengthDoesNotVerifyProvenance`；Store 三项迁移测试见下一节。未知实际身份保持 nil，不用请求值或音频长度补齐 | 通过 |
| AC-P0-07 过期、故障与取消 | `AudiobookStoreTests.testCatalogChangeRejectsPlanBeforeCommit`、`testStalePlanDoesNotOverwriteNewCast`、`testChangedAnnotationsInvalidatePlanWithoutCharacterChange`、`testChangedPlanCannotReuseRiskAcknowledgement`、`testLastInvalidBindingRollsBackWholeBatch`、`testCancelledApplyDoesNotCommitPartialBindings`；Cast 中既有的第二项写入/确认失效触发器故障测试；Production 中在途归档反例。比较保存前后的角色、绑定和确认状态，失败无部分写入；在途候选保留待复核 | 通过 |
| AC-P0-08 确定性与终止 | `AudiobookCastTests.testCastingInputReorderingIsDeterministic`、`testCancelledCastingAndMatchingBudgetStopWithoutBindings`、`testMatchingBudgetExhaustionIsNotReportedAsInfeasible`。输入重排的结果、摘要与 issue ID 稳定；100000 次访问预算耗尽和取消分别停止，不报告为已证明无解 | 通过 |

### 定向命令与数量

```bash
swift test --package-path macos/SpeechRailApp --filter 'ServiceContractTests|Audiobook(Cast|Store|Production|Workflow|Invalidation)Tests'
uv run --no-sync pytest --no-cov tests/test_tts_request_validation.py
git diff --check
swiftc -frontend -parse macos/SpeechRailApp/SpeechRailApp/AudiobookBookWorkspaceView.swift
```

20:14 的 Swift 分组为 Cast 45、Invalidation 2、Production 11、Store 24、Workflow 24、ServiceContract 103，总计 209。Python 9。视图仅核对数据回调语法，未执行 App 完整构建或 UI 自动化。

RED 记录先复现了 clone 非法种子、真实请求丢种子/自动更新 pin/伪造追溯、不可空 schema、空候选越界、批量原子入口缺失；补充 RED 记录覆盖选项第四个复制 helper 丢种子、确定性拒绝被重试、语速被播放范围裁剪、预算当无解、自动生成覆盖已选声音及零台词独占占用。各项修复均重跑相应用例；定向集曾暴露旧夹具仍期望自动共享、假版本或不完整标注豁免，已按规格改成合法正例与明确反例，没有跳过这些测试。

## 临时迁移、保留与回退

`testNullableVoiceRevisionMigrationPreservesAllRows` 在测试生成的 schema 1 副本中运行迁移，比较 books、sources、chapters、characters、annotations、voice_bindings、render_candidates、chapter_revisions 八表内容，核对外键、旧绑定及一致性备份；临时副本包含旧 WAV，迁移后实际核验文件/PCM 摘要及采用版本和候选引用。`testIdentityMigrationFailureLeavesSchemaOneIntact` 注入表重建失败，核对 schema 1、原表与书籍行保持。`testSchemaTwoRoundTripsSystemMissingRevision` 核对 NULL 的保存与重开读取。未知旧身份原值保留，不自动填假版本。

迁移实现先用 SQLite backup API 创建一致性备份，再单事务重建可空列并设置 schema 2；已有备份名不会被覆盖。测试只使用合成临时库及其副本，未打开默认真实 SQLite 作品库。历史候选、采用/撤销版本与存储故障保护同时由定向 Store/Cast/Invalidation 回归覆盖。

回退分开处理：

1. 计算或投影回归时，停用自动推荐/批量入口，保留合法声音的手动绑定、候选隔离、严格准入及原子保存。依据本次修改前快照、任务补丁及当前文件做三方比较；不能整文件覆盖并行编辑。
2. schema 迁移失败时原事务回滚，保留备份与失败副本。已提交 schema 2 则优先保留；不得强制恢复非空列、回填假身份或恢复非法 clone 参数。
3. 有迁移后新作品/编辑时，不用旧库覆盖。需要恢复旧副本必须先证明没有后续写入，并配套可读该 schema 的代码；恢复只针对核实的对象，不连带覆盖共享音色目录、历史音频或其他作品。

本次仓库外基线包含修改前文件、哈希、原有 diff、分支/HEAD 和运行日志；它是三方核对证据，不是已获授权的真实库恢复材料。任务 ledger 保留适用裁决及进度。

## 隔离发现、并行工作与限制

早期运行既有基线/回归时，发现旧测试及 Workflow 使用 `VoiceCatalogStore.shared`，存在向默认 JSON 音色目录写入测试条目的可能。已告知用户并将 Workflow、控制器/renderer 与所选夹具改为显式注入内存或临时目录；随后定向集不再经过此路径。**未检查或覆盖恢复真实目录，因此不能证明早期目录没有受到影响。** 默认真实 SQLite 作品库未打开；迁移始终只在临时夹具副本执行。

原有未提交改动保留。文本导入/语料任务继续修改 TXTImporter、SourceIndex、ChapterPlanner、Import/Source 测试与语料脚本及相关文档；本任务没有回退这些内容。一次中间编译因并行新增导入字段暂未齐备失败，源文件随后就绪，完整 P0 定向集重新编译并通过；不能将中间失败的退出码记为验收证据。

裁决与实施边界：在当前分支局部执行并保留外部快照；使用现有领域文件避免引入新 target 注册；Store 附加源上下文后才允许提交；旧夹具预期按 P0 合同修正。`executing-plans` 的辅助 review-package/template 路径在本环境缺失，采用精确基线 diff 与源文件清单交给一个新上下文只读 reviewer。未自动提交、安装或操作服务。

独立审查及修复已完成；审查人只读核对源码，修复由实施者用 RED→GREEN 和最终定向集验证，没有进行第二轮审查。S3～S5 的完整政策/目录 schema、场景算法、跨 Store 注册恢复、影响预览/撤销 UI 及真实听感门仍待实施与各自授权，不能从本记录推定通过。


## 独立审查与修复

新上下文 reviewer 报告 0 项 Critical、5 项 Important、0 项 Minor。五项均接受并修复：

| 问题 | 修复与验证 |
| :--- | :--- |
| 跨章共享没有显式接受 | 新增共享提议始终生成 `sharedVoiceConsentRequired`，与同章风险分别记录；`testCrossChapterSharingRequiresExplicitAcceptance` RED→GREEN |
| 已证实零台词的旧绑定占用容量 | Store 内部校验完整标注后传入必需发声集合，纯 Registry 缺乏该证据时保持保守。旧绑定不删除、不改写；只有必需发声角色参与容量/独占校验。`testProvenSilentLockedBindingDoesNotConsumeSpeakingCapacity` RED→GREEN，并覆盖历史未就绪绑定保留；制作入口重新检查角色恢复发声后的冲突 |
| 单角色生成覆盖等待期间新选择 | `AudiobookVoiceReturnContext.voiceSetDigest` 冻结开始时的绑定集合，控制器及 Store 准备提交时再次比较；旧缺少该事实的上下文拒绝应用。`testGeneratedVoiceReturnFreezesBindingSet` RED→GREEN |
| 来源角色被当成硬候选限制 | 删除 `originRoleID` 的硬过滤，保留合法范围内的来源排序偏好；`testOriginRoleIsPreferenceWithinBookScope` RED→GREEN |
| 目录 key 与记录 voice ID 错配可误准入 | 快照/读取均校验身份一致性，修订包含字典 key，损坏文件不改写；`testCatalogIdentityMismatchFailsClosedAndChangesRevision` RED→GREEN |

审查修复小集先复现 5 项、12 个失败断言，再通过同一 5 项；扩展零台词历史状态及重新发声制作入口反例也先复现后修复。最终 `p0-final.log` 为 209/209，Python `p0-python-final.log` 为 9/9；51 个新增 Swift 方法全部实际执行，无跳过。无延期 Minor。
