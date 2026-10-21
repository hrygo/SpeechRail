---
title: "有声书加工文本统一输入实施计划"
status: completed
date: 2026-10-21
---

# 有声书加工文本统一输入 Implementation Plan

> **For agentic workers:** 实施时使用已安装的 `executing-plans` skill，按任务执行。用户已授权实施与定向回归；不迁移真实作品、不安装、不发布。

**Goal:** 使初始加工文本成为有声书全部生产环节的唯一工作输入，消除排版折行重新进入语音合成的问题。

**Architecture:** 导入准备生成不可变工作文本及来源映射，Store 以 source revision 保存身份；所有工作索引与任务只读取固定工作修订。原文件与 UTF-8 参考文本仅供追溯；已有作品通过新增修订保留历史，禁止直接修改旧字节并沿用旧偏移。

**Tech Stack:** Swift 6、Foundation、SQLite、现有 SpeechRail 公共合成接口；macOS 26.0+、arm64。

**Spec:** [有声书加工文本与全流程输入规范](../specs/2026-10-21-audiobook-working-text.md)

**Diagnostic evidence:** 2026-10-21 用户听评确认，实际完整制作片段只连接排版折行后，“老監生”“寒暄”均恢复连贯；原句繁简体两版亦连贯，“长一辈”与补充的“长胖了／長胖了”均读作 `zhang3`。此次未复现最初的多音字错误，不将它与已确认的折行缺陷混为同一根因。每个变体仅一次生成，不宣称全面质量验收。

## Global Constraints

- 保留现有模型与运行档位；不重启服务、不下载模型。
- 原始文件、旧工作 source、标注、候选、采用版本和音频不得覆盖或删除。
- 默认保留繁简体与正文；仅连接确定的排版折行。
- 所有新工作区间使用固定版本的工作 UTF-8 字节坐标。
- 工作区存在并行改动；实施前重新检查状态，同一文件由一个执行者写入。
- 本计划的测试使用临时库与 fake renderer。仅运行定向测试，不启动 UI 自动化或完整套件。
- 不自动提交、推送、安装、迁移真实库或替换已有采用音频。

## Review Focus

1. CRLF、中文词内折行、英文词间折行混合：不能删掉英文必需空格，不能保留词内排版换行。由 Task 1 覆盖。
2. 诗行、真实段落与对白：加工不能为了连读吞掉内容边界。由 Task 1 覆盖。
3. 旧作品的区间、角色证据与音频：新工作字节不能解释旧偏移。由 Task 2、4 覆盖。
4. 工作修订切换或暂停恢复期间返回旧请求：不能把旧结果提交到新修订。由 Task 3、4 覆盖。
5. 工作文件损坏、准备失败或写入中断：不得悄悄回退到原文继续制作。由 Task 2、3 覆盖。

## Task 1: 生成可追溯的工作文本

**Files:**
- Create: `macos/SpeechRailApp/SpeechRailApp/AudiobookTextPreparation.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookTXTImporter.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookSourceIndex.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookImportTests.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookSourceTests.swift`

**Interfaces:**
- `AudiobookTextPreparation.prepare(referenceUTF8: Data) throws -> AudiobookPreparedText`。
- `AudiobookPreparedText` 提供 `workingUTF8: Data`、`workingSHA256: String`、`preparationVersion: String`、`sourceMap: [AudiobookWorkingSourceSpan]`。
- `AudiobookWorkingSourceSpan` 的工作与参考区间均为 UTF-8 字节范围；参考区间指解码后的参考文本，不指原始编码文件。
- 初始策略标识 `audiobook_text_preparation_v1`；空文本拒绝。现有导入预算继续应用于原文件和加工结果。

- [x] 先补 `preparedTextJoinsLayoutBreaksInsideChineseWords`：合成夹具中的 `老監\r\n生`、`寒\r\n暄` 应成为完整词。
- [x] 补 `preparedTextPreservesParagraphsPoetryAndLatinSpacing`、`preparedTextIsIdempotentAndKeepsTraditionalCharacters`、`preparedSourceMapUsesDecodedReferenceUTF8`：分别断言结构、幂等、字形与单调有界映射。
- [x] 实现纯加工器，提取复用现有排版判断与连接逻辑；不维护另一套显示专用规整算法。
- [x] 导入预览、章节初次规划均从同一 `workingUTF8` 建立索引。
- [x] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookImportTests` 与 `--filter AudiobookSourceTests`；上述新断言和原有相关回归均通过。

## Task 2: 持久化工作修订与原文参考身份

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookDomain.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookStoreSchema.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookProjectStore.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookStoreTests.swift`

**Interfaces:**
- source revision 记录 `sourceKind`（`reference` / `working`）、`referenceSourceID`、`preparationVersion`、工作内容哈希和来源映射资产。
- 工作 source 的 `canonical_rel_path` 保存加工 UTF-8；原文件和解码参考文本各保留独立资产，禁止复用同一路径。
- `workingSourceSnapshot(bookID: UUID) throws -> AudiobookWorkingSourceSnapshot` 返回固定 `sourceID`、工作哈希、加工版本和工作索引；没有工作修订时返回 `working_text_preparation_required`。
- `prepareWorkingRevision(bookID: UUID, expectedSourceID: UUID) async throws -> UUID` 在暂存区构建新修订，验证后以 CAS 原子切换活动 source；错误保留旧指针。
- 旧数据迁移仅补身份元数据。已有未加工 source 标记为 reference，不在启动时重写内容或区间。

- [x] 补 `importPersistsPreparedBytesAndImmutableReference`，证明重开后工作字节与预览一致、原始字节未改。
- [x] 补 `legacyUpgradeDoesNotRewriteSourceOrAudio`、`failedPreparationKeepsActiveRevision`、`corruptWorkingSourceDoesNotFallBackToReference`。
- [x] 在临时数据库验证 schema 升级、外键、SHA 校验与来源映射资产事务；使用现有 SQLite backup 与资产发布模式。
- [x] 给章节/角色及全部派生查询增加工作修订作用域：章节使用现有 `source_id`；角色及其证据补 source 身份，音色绑定随对应角色隔离。
- [x] 新修订创建独立章节与角色 ID；旧行与旧音频保留。所有 book 级聚合只汇总所选修订，禁止混入历史行。
- [x] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookStoreTests`，确认临时旧库无损升级及失败恢复。

## Task 3: 统一全部消费者

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookChapterPlanner.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookAnalysisPipeline.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookFragmentPlanner.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookProductionController.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookProductionWiring.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookPronunciationController.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookAnalysisPromptTests.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookProductionTests.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookPronunciationTests.swift`

**Interfaces:**
- 所有生产入口接受 Task 2 的 `AudiobookWorkingSourceSnapshot`，任务开始固定一次；不从调用方自行拼装原文索引。
- 工作文本用 `text(in:)` 直接取片段。`normalizedText` 不再负责生产文本加工；原文只从明确命名的 reference 读取入口访问。
- 合成请求的 `text` 必须等于固定工作 source 对应区间的文字；发音规则再由现有服务按 raw→spoken 契约应用。

- [x] fake analysis client 与 fake renderer 捕获实际请求：断言同一区间的预览、AI primary/context、发音命中及合成文本一致。
- [x] 补 `productionUsesPreparedTextForBothInitialAndSingleFragmentRender`，分别覆盖首次制作和单段重录。
- [x] 补 `crossLinePronunciationRuleMatchesWorkingText`，证明跨原始排版换行的词条能命中工作词。
- [x] 实施依赖收敛，覆盖章切分、atom 计数、上下文窗口、选角试听、正式合成、局部返修与导出标题/文字元数据；同一流程不混用两套偏移。
- [x] 补 `missingWorkingRevisionBlocksNewProductionButAllowsHistoricalPlayback`。
- [x] 运行上述三个定向测试类；不使用真实音频或真实模型作为确定性断言。

## Task 4: 隔离缓存、恢复与历史版本

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookDomain.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookProjectStore.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookProductionController.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookRevisionController.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookListeningController.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AudiobookExportController.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookRevisionTests.swift`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookProductionTests.swift`

**Interfaces:**
- 检查点、分析配置及候选校验固定 `sourceID` 与 `preparationVersion`，提交时再次比较。
- 历史播放/导出按所选 production/chapter revision 的 source 读取；新生产只允许 working source。
- 片段依赖保留现有局部正文、角色、声音、参数与命中词条摘要，增加加工策略身份；不因无关词条变化失效。

- [x] 补 `lateRenderCannotCommitAcrossWorkingRevision`、`resumeRejectsCheckpointFromDifferentPreparedSource`。
- [x] 补 `newWorkingRevisionDoesNotReuseReferenceBasedCandidates`、`historicalAudioRemainsPlayableAfterPreparation`。
- [x] 新工作修订需要重新分析；旧人工角色/音色选择只能作为可确认建议，不能沿用旧证据区间。保留原音色资产。
- [x] 通过工作修订指针回退，覆盖准备失败、CAS 冲突和重开；不以旧库覆盖新库。
- [x] 运行 `AudiobookRevisionTests`、`AudiobookProductionTests` 相关定向回归。

## Task 5: 文档同步与专项验收

**Files:**
- Modify: `docs/architecture/audiobook-workshop.md`
- Modify: `docs/developers/macos-app-audiobook.md`
- Modify: `docs/users/audiobook-workshop.md`
- Modify: `docs/developers/testing-acceptance.md`

- [x] 将“原文区间为工作真源”改为“工作文本版本及其 UTF-8 区间”，明确原文参考和来源映射边界。保留历史文档时点，不重写归档承诺。
- [x] 更新已有作品的准备、历史收听和重做说明；普通页面只表达任务与下一步。若需新增交互，先读取当前设计系统相关规范。
- [x] 重跑 Task 1–4 定向回归；用临时库核对全链路请求和版本。若需要产出 `.app` 的测试，使用 `scripts/macos_app_test.sh` 并精确限定非 UI target。
- [x] 复用本次同模型繁简体听评证据，明确只覆盖这些文本；补充任何新增真实试听须在用户授权范围内。没有测得字级时间戳就不报告停顿毫秒值。
- [x] `git diff --check`、核对全部 staged/unstaged 改动归属；未获明确要求不提交。

## 决策与回退

仅在制作前调用 `normalizedText` 成本较低，但会让工作区间、AI 分析、缓存与实际朗读继续分裂，不满足用户要求。本计划选择一次加工、持久化工作修订、全链路统一消费；额外成本集中于旧作品版本隔离与坐标保护。

真实库不在本计划编写阶段迁移。实施验证先使用合成临时库；真实作品的准备在支持版本隔离的实现完成后由明确的作品操作触发。保留旧工作修订和采用音频，失败或回退不会删除它们。全链路修复后仍出现的多音字错误单独建样例，不默认通过繁转简、加拼音或更换模型掩盖。

## 实施与定向验收记录（2026-10-21）

加工 UTF-8、SHA、策略版本及来源映射已成为新分析、分章、配声试听、发音命中、制作和重录的共同输入。原始 TXT 与解码参考文本独立封存；EPUB 延续只封存提取文本的边界。工作输入缺失或损坏时拒绝新工作，不回退原文。来源映射保存原始标题排版证据，避免加工生成的段间空白把短正文识别为篇名。

schema 7 仅为旧 source 补充参考身份。作品页提供「准备加工文本」明确操作，创建新坐标与角色身份，重新要求分析和配声确认。切换前保存已有采用章节的生产快照，包括只完成部分章节的作品；听书与导出通过独立音频版本选择固定历史 source、章节与跟读正文，不把旧偏移送入当前编辑工作区。Store 支持 source 指针回退，保留两侧资产和工作状态。

一次独立只读复核发现 6 项 Important，均纳入同一次修复：合成准入泄漏、分析入口跨 source 状态写入、同 source 旧任务收尾覆盖、准备操作缺少产品入口、历史音频选择未接线，以及生成空行造成篇名误判。新增回归先复现再修复；扩大定向运行发现的取消终态事件缺失及 source 错误重试包装也已修正。

验证使用临时 SQLite、fake analysis/renderer/播放器与合成测试资产：

- `swift test --package-path macos/SpeechRailApp --filter 'Audiobook(Import|Source|Store|Analysis|AnalysisPrompt|Production|Pronunciation|Revision|Export|Listening|Workflow|Workspace).*Tests'`：292 项 XCTest 中 288 项通过、4 项按需跳过，另 2 项 Swift Testing 通过，共 290 项通过、0 失败。
- 4 项跳过分别为手工进度帧导出、大规模索引基准、真实语料基准、真实 EPUB 导入；它们没有被当前定向验证范围启用。
- `python3 scripts/check_audiobook_schema.py --base-ref HEAD`：schema v7 实现与冻结契约一致。
- `scripts/macos_app_build.sh --configuration Debug`：App 构建成功，使用包装脚本收尾清理临时 bundle；未导出安装包。
- `git diff --check`：通过；对原工作区执行前核对任务文件与起始快照，无并行冲突，只同步本次差异。

实施选择：加工与映射类型复用现有 SourceIndex 文件，不新增项目注册；合法 U+FFFD 与繁简体均保留。验证只覆盖本次定向范围，不运行全量套件、不自动提交。新增准备入口和历史音频选择供将来用户明确操作，本次不操作真实作品；界面只做编译与模型层回归，未做前台 UI 自动化或人工视觉验收。

运行边界：未安装 App、未迁移真实作品或打开真实库进行写入、未覆盖真实音频、未变更模型/档位/服务，也未提交或推送。此前用户听评仅证明给定样本连行后连贯；最初多音字错误未复现，本次不宣称全面读音质量验收。代码回退须只逆向本次任务差异，保留开始时已有改动；旧作品的回退使用 source 修订指针，不替换数据库或音频。
