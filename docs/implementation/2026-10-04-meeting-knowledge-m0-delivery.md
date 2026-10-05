---
title: "会议知识闭环 M0/M1 交付说明：版本指针、失败语义、恢复、检索、备份、MA-05 迁移"
status: active
version: "3.0"
date: 2026-10-05
branch: "codex/meeting-knowledge-migrate"
base: "origin/main @ d72535c7"
---

# 会议知识闭环 M0 交付说明

## 范围

本分支只动纪要版本链、结束封存上报与知识检索语义，不做 schema 迁移、不改表结构、不碰采集链路。

分支共 37 个提交：排队指针原子化、空输出与结构失败记失败、
认领代际、恢复认领原任务、导出固定选定版本、知识检索、私密边界、备份校验、引文校验、
删除语义回归，外加会议库分页、封存上报、恢复认领、结束走上报、快照补充、正文落库、
断线恢复、封存隔离、行动项恢复、检索隔离等收尾回归。

1.1 追加（MC-27/MC-17/MC-20 收尾）：`MinutesGenerator.recoverPending`
改走 `pendingMinutesRows` 按原 job 认领续跑（`resume`），不再经 `generate`
新建版本；`MeetingSession.finishAndSummarize` 改用 `sealMeeting` 上报结果，
封存失败留在 processing 并给出重试/复制出口，不谎报已归档。

1.2 追加（MC-43/MC-35/MC-36 收尾）：快照输入 = 转录终稿 + 已校验的用户补充。
`verifyEvidenceQuotes` 经协调器透传；生成与恢复续跑两处组装点统一走
`MinutesSupplements.render`，未选中、未逐字命中、空问答不进入 prompt，
补充逐条标注身份，不升级成会议事实。

1.3 追加（验收 1 保存可靠）：正文落库同 id 重复插入必须失败且不新增行；
序号按场独立单调，跨场不串写。

1.4 追加（验收 1/MC-24 断线恢复）：异常退出后 `sealAbandonedSessions`
只封存不删行，已存正文重开可读、可检索；会议说话人 partial 不受助手封存影响。

## 回归证据

- `MeetingMinutesVersioningTests` 28 个用例，对应 MC-12（同 id 重复落行）、MC-17、MC-20、MC-24、MC-25、MC-26、
 MC-27、MC-29、MC-33、MC-34、MC-35、MC-36、MC-43、MC-44、MC-46（含后半句：改名记修订事件、旧版标需复核、
 引用仍指旧 revision，重复同名不刷事件；Domain 纯逻辑只标晚于创建的修订）、MC-48、MC-49、MC-52、MC-62、
 MA-19（JSON 导出携带版本身份与创建时间）、验收 5（损坏备份校验失败且原库仍可读写）、
 验收 1（关闭连接后同一目录重开，正文纪要问答可找回且可继续写）。
- 连同 `AssistantPersistenceTests` 共 40 个用例，2026-10-05 实测全部通过。
- 命令：`swift test --package-path macos/SpeechRailApp --skip-update
  --filter 'MeetingMinutesVersioningTests|AssistantPersistenceTests'`。

### MC-46 后半句（无迁移实现，v2.3 新增）

- 改名（`renameSpeaker`）在显示名确有变化时，向既有 `session_change` 表追加
  `kind = 'speaker'` 修订事件（`value = label|name`，`at_ordinal = 0`）；旧纪要正文不动，
  `speaker_name` 幂等语义不变，无 schema 迁移（`schemaVersion` 仍为 1）。
- 新增只读判断 `minutesNeedsReview(minutesID:)`：任一修订事件晚于纪要创建时间即需复核；
  引用仍指旧 revision，只是提示结论可能过期。`speakerRevisions` / `minutesNeedsReview`
  经 `SessionCoordinator` 透传。
- `voiceChanges` 收敛为只读 `kind = 'voice'`，说话人修订不混进音色变更点，
  既有回看徽标与快照语义不受污染（`AssistantPersistenceTests` 快照用例仍全过）。
- v2.4 接线：`MinutesGenerator.versionsNeedingReview` 随版本列表刷新（含 `reload` 与
  生成/恢复各组装点），比较逻辑下沉 Domain 层 `MinutesReview`；`MeetingView`
  在版本行标“需复核”徽标，查看旧版时正文上方提示结论可能过期。`MeetingView`
  不进 SPM 测试目标，仅做 `swiftc -parse` 语法检查；判断逻辑由 Domain 纯逻辑回归覆盖。
- v2.5 导出口径（MC-25/MC-48）：记录库导出、会议页回看、重新生成后刷新、会议页导出
  （未选旧版时）统一读 `latestUsableMinutes`；最新尝试失败时不拿失败版空正文遮旧版，
  无可用版时导出只出转录。会议页导出已选旧版时仍固定该版。库层口径由既有
  `testLatestUsableStaysAfterFailedAttempt` / `testLatestUsableMinutesReturnsNewestReady`
  覆盖；View 层仅做 `swiftc -parse` 语法检查，未做界面走查。
- v2.6 全文检索入口（MC-49/MC-52/MC-54）：记录库搜索框回车触发 `searchKnowledge`，
  查转录终稿与已完成纪要，不查私密问答；命中时按命中会话过滤列表并选中第一条，
  无命中回退标题过滤不清空列表，失败只记错误。库层由既有检索回归覆盖；
  View 层仅做 `swiftc -parse` 语法检查，未做界面走查。
- v2.8 引用恢复（验收 5）：新增 `testBackupRestoreKeepsEvidenceLinksVerifiable`，
  备份恢复到临时新库后，引文仍能指回恢复库里的转录行并通过逐字校验；
  恢复库只读核对，不写原库。
- v2.9 删除语义（MA-18/验收 4）：`testRemovedSessionDisappearsFromKnowledge`
  追加问答、引文、转录行的级联验证，完整删除不暗留引文全文；用例数不变，
  仍共 35 项。
- v2.10 问答终态（MC-41/MC-42/MA-04）：`saveInnerOSExchange` 建行与证据同一事务；
  新增 `finishInnerOSExchange` 条件 UPDATE（只允许从 generating 推向终态，
  0 行抛错），答案、状态、证据同一事务落库；`InnerOSSession` 终态改走该入口，
  写入失败报可读错不半保存。`InnerOSSession` 不进 SPM 测试目标，仅做
  `swiftc -parse` 语法检查；事务语义由新增 `testInnerOSExchangeFinishIsTransactional` 覆盖。
- v2.11 切会归属（MC-45）：`InnerOSSession.bind` 切会先取消在飞的那一问；
  迟到结果库归档照写建行那一场（不丢 A 的答案），界面状态只写当初那一场
  （归属判断下沉 Domain 层 `LateResultOwnership`），不写 B、不清 B 新任务句柄。
  `InnerOSSession` 不进 SPM 测试目标，仅做 `swiftc -parse` 语法检查；
  归属逻辑由新增 `testLateResultOwnershipGuardsUIWrites` 覆盖。

## M1 增量（MA-05，2026-10-05）

范围：schema v1→v2 增量迁移 + 协调器接线 + 迁移回归 + 提词器 E2/E3 收尾分交。

- 提交 `8e6888c4`（会议知识）：`meeting_document` / `transcript_revision` /
  `source_snapshot` 三表 + `minutes.is_legacy_import` 列；`migrateV1ToV2`
  逐级升、失败整库回滚（MC-67/MC-69）；`SessionCoordinator` 透传文档 CRUD、
  快照封存、修订链读写；`removeSession` 已关联知识时拒绝级联（MC-62）。
- 提交 `292d0e4f`（提词器，与 M1 无关的分交）：稳定前缀截断换算、
  同位确认门槛、空 final 未确认语义、评估报告 v2。
- 回归证据：`MeetingMinutesVersioningTests` 32/32（含新增 MC-67/MC-68/
  MC-20/MC-62 四用例），联合 `AssistantPersistenceTests` 47/47；
  Teleprompter 两套 84 项通过。
- 命令：`swift test --package-path macos/SpeechRailApp --skip-update
  --filter 'MeetingMinutesVersioningTests|AssistantPersistenceTests'`；
  `swift test --package-path macos/SpeechRailApp --skip-update
  --filter 'TeleprompterFollowControllerTests|TeleprompterReplayEvaluatorTests'`。

### M1 迁移说明

- v0→v1 照旧建全部 v1 表；v1→v2 执行 `schemaV2Delta`（三表 IF NOT EXISTS 幂等）
  + `minutes.is_legacy_import` 列追加（PRAGMA 查列，已存在跳过）；
  旧 minutes 行全标 legacy，final 行回填 `legacy_import` 修订起点。
- v2 新库新建行默认非 legacy；v1 旧库行的 legacy 回填只由迁移 UPDATE 完成。
- 旧程序不得直接打开 v2 库：`migrate()` 遇更高 user_version 抛错保留原库。

### M1 回退说明

- 整支回退：切回 `origin/main @ d72535c7`；v2 库文件保留，需用迁移前备份恢复 v1。
- 单个提交回退：`292d0e4f`（提词器）可独立 revert；`8e6888c4`（MA-05）
  回退后 v2 表残留但无读写入口，需备份恢复才算干净。
- 回退不删除用户数据：`removeSession` 拒绝语义只挡误删，不清知识文档。

### M1 未验证事项

- 界面走查（版本切换、导出菜单、检索入口、删除确认）未做。
- 真实模型生成、拒答、截断的端到端语义未做。
- v1 真实旧库文件的迁移演练未做（只有空库直建 + 新行语义回归）。
- 真实采集、UI 自动化、发布另行授权。

## M1 增量（MA-06 采用指针，2026-10-05）

范围：任务状态与内容审阅分离，采用指针成为展示与导出的唯一口径。

- 提交 `80b4ac19`、`ee660959`：schema v3 追加 `minutes.is_accepted`（旧行默认 0，
  不猜用户意图）；`adoptMinutes(sessionID:minutesID:expectedCurrentID:)` 同事务清旧指针
  立新指针，按预期采用版比较，冲突/失败版/未知版一律拒绝（MC-31）；
  `currentMinutes(sessionID:)` 采用版优先、其次最新可用候选，是展示/搜索/导出的唯一口径
  （MC-25/MC-48）；`MinutesGenerator.reload`、回看、导出接线同步。
- 界面：版本行区分「当前采用 / 最新 / 历史」，新增「采用」动作与冲突提示。
- 回归证据：`MeetingMinutesVersioningTests` 35/35、`AssistantPersistenceTests` 15/15。

## M1 增量（MA-07 持久生成队列，2026-10-05）

范围：任务身份落到行上——恢复查原请求、取消有痕迹、配置在排队时冻结。

- 提交（本节）：schema v4 追加 `minutes.remote_response_id` /
  `config_snapshot` / `snapshot_id` / `cancel_requested_at`；`migrateV3ToV4`
  只加列、**不回填**（老任务当年没存过远端响应 id，补值等于伪造"确认过远端没在跑"）。
- 六处 `minutes` 读列清单收敛为单一常量 `minutesSelectColumns`，与
  `minutesVersion(from:)` 的列序号映射一一对应；映射按 `sqlite3_column_count`
  兼容 v1～v3 老形状。
- 新增带 fencing（`expectedAttempts`）的库动作：`recordMinutesRemoteResponse`
  （收到 id 那一刻就落库，MC-28）、`renewMinutesLease`（心跳，间隔 = 租约/3）、
  `requestCancelMinutes`（先落取消请求再停本地任务）、`cancelMinutesIfOwner`
  （取消 ≠ 失败）、`markMinutesSubmissionUnknown`（远端提交结果未知，**不进
  自动恢复队列**，不无条件重发，§8.5）。
- `MinutesJobConfig`：排队那一刻冻结端点/模型/兼容模式的指纹，**不含密钥**；
  恢复旧任务时按指纹还原配置而不是读当前设置（MC-32），差异通过
  `jobConfigDiffersFromCurrent` 告知界面"新配置从下一次任务生效"。
- `MinutesGenerator`：`resume` 有远端 id 时直接 `pollBackground` 原请求，
  不 `startBackground`；`stop()` 先写取消请求再 `Task.cancel()`；
  取消落 `cancelled` 状态并给出**如实的**远端结论
  （`LLMProvider.cancelBackground` 返回 confirmed / unsupported / unconfirmed，
  `404/405/501` 记为端点没有该能力，其余非 2xx 与传输错误记为未确认）。
- 回归证据：新增 `MeetingMinutesJobRecoveryTests` 10/10（MC-27～MC-32），
  联合 `MeetingMinutesVersioningTests` 35/35 + `AssistantPersistenceTests` 15/15
  = **60/60 通过**（2026-10-05 核验）；`./scripts/macos_app_build.sh` BUILD SUCCEEDED。

### M1 增量（MA-06/MA-07）迁移说明

- v2→v3 追加 `is_accepted`；v3→v4 追加任务身份四列，均为 `PRAGMA table_info`
  查列后 `ALTER TABLE`，已存在则跳过，迁移幂等。新库由 `schemaV1` 一次建全。
- 新旧行语义差别：新建行 `remote_response_id` 等四列为 NULL，表示"没有这项信息"，
  不是"这项为否"。旧程序不得直接打开 v4 库（`migrate()` 遇更高 `user_version` 抛错）。

### M1 增量（MA-06/MA-07）回退说明

- 整支回退：切回 `origin/main @ d72535c7`；v3/v4 库文件保留，
  需用迁移前备份恢复才能让旧程序打开。
- 单个提交回退：MA-07 提交 revert 后 v4 列残留但无读写入口；
  回退**不需要**清任务表或删候选（计划明确禁止以清数据作为回退）。

### M1 增量（MA-07）未验证事项与已知边界

- 真实端到端未做：真实 background 提交、远端过期、取消确认、App 退出恢复的真实演练
  都没有跑过；本轮全部是确定性回归与构建。
- **偏保守的一侧**：`MinutesSubmissionCertainty` 把所有 `LLMError.transport`
  都算成"远端收没收到查不出来"，所以"连不上服务"（其实还没发出去）也会显示
  「提交结果待确认」。宁可多问一句，不替用户断言远端没在跑。
- 来源快照绑定已落库（`snapshot_id`）并有查询入口 `latestSourceSnapshot(sessionID:)`，
  但**还没有生产路径创建快照**（MA-05 只交付了库与 API），所以今天排队出来的任务
  `snapshot_id` 基本为 nil；封存接线属 MA-08。
- 远端取消只对已拿到 response id 的任务问得着；端点没有该接口时界面明说
  「无法确认」，不谎称云端任务已消失。
- 真实采集、UI 自动化、模型质量基准、发布另行授权。

## M1 增量（MA-08 结构化纪要与证据核对，2026-10-05）

范围：结论可定位到来源、语气与数字可核对、错误结果保留但不升可信。

- **来源单元（§7.5）**：转录在进 prompt 前由 `MinutesGenerator.sourceUnits`
  分配 `u1`、`u2`… 这样的 id，模型只能引用、不能自己编。`source_unit_ids`
  在 `json_schema` 里是**必填**，"没有依据"因此成为模型必须写出来的一件事。
- **v2 候选契约**：`speechrail.minutes.v2`，字段带 `modality`
  （decided / conditional / proposed / retracted）与 `commitment`
  （committed / proposed），待办的 `owner_text` / `due_expression` **照写**，
  没依据就空——不为填满 JSON 折算出一个具体时间（MC-38）。
- **失败原因可区分（MC-33/MC-34）**：`MinutesFailureKind` 分
  empty / unstructured / schemaInvalid / refused / incomplete。
  纯文本那一支**原文保留**当候选，但走 `.failed`，**禁止原文兜底后 ready**。
  `schema_version` 对不上直接判 `schemaInvalid`，不"尽量按新的理解解析"。
- **`MinutesEvidenceValidator`**：核对身份、语气、数字/单位、负责人、期限。
  - 引用不存在或属于别的会议的来源单元 → `rejected`，**绝不按序号兜底**（MC-35）；
  - 原文是建议/条件/撤回而结论写成已决定 → `needsReview`（MC-37）；
  - 结论里的数字在所引原文里找不到 → `needsReview`（MC-38）；
  - 待办标成已承诺但原文没人认领、负责人/期限在原文里查无此说 → `needsReview`；
  - 条件如实写出、数字照抄、负责人留空时**不误报**——验证器不能变成噪声源。
- **保留但不升可信**：被拒的条目**仍然渲染进正文**（让人看得见模型编了什么），
  但带「未通过引用核对 / 待核对」标记，正文末尾附「需要你核对的地方」，
  界面在纪要区给出条数说明。
- **schema v5**：`minutes` 追加 `candidate_json` / `review_json`，
  `migrateV4ToV5` 只加列不回填（v4 之前的正文是 Markdown，没有候选可还原，
  硬造一份等于凭空给旧纪要安上引用）。`saveMinutesCandidate` 让
  **正文、候选、核对报告在同一条 UPDATE 里落库**并带 fencing——
  分两次写就会出现"正文在、报告没了"的假核对。
- 回归证据：新增 `MeetingMinutesEvidenceTests` **17/17**，
  联合 `MeetingMinutesVersioningTests` 35 + `MeetingMinutesJobRecoveryTests` 10
  + `AssistantPersistenceTests` 15 = **77/77 通过**（2026-10-05 核验）；
  `./scripts/macos_app_build.sh` BUILD SUCCEEDED。

### M1 增量（MA-08）迁移说明

- v4→v5 追加 `candidate_json` / `review_json`，`PRAGMA table_info` 查列后
  `ALTER TABLE`，已存在则跳过，迁移幂等。新库由 `schemaV1` 一次建全。
- **旧 Markdown 纪要继续可读**：v5 不回填候选与报告，旧版本的
  `candidateJSON` / `reviewJSON` 为 NULL，界面按"这一版没有核对报告"处理，
  不假装核对通过。

### M1 增量（MA-08）回退说明

- 整支回退：切回 `origin/main @ d72535c7`；v5 库文件保留，需迁移前备份才能让旧程序打开。
- 单个提交回退：MA-08 提交 revert 后 v5 列残留但无读写入口；
  回退**不删除任何已存纪要**——计划明确要求"停止新结构化发布而不是删除旧纪要"。
- 已存正文不受影响：回退后旧程序读 `body` 字段，Markdown 原样可读。

### M1 增量（MA-08）未验证事项与已知边界

- 来源快照封存已在下面的「MA-03 收尾 / MA-05 落地」一节接上，`snapshot_id` 不再为空。
  证据锚点（`minutes_item` / `minutes_evidence`）也在下面的「MA-08 收尾」一节落库了，
  "从某条结论跳回原句"已经是查一条索引而不是解析 JSON；界面侧的来源面板仍属 MA-11。
- 真实模型端到端未做：真实结构化输出、`source_unit_ids` 回填质量、
  验证器的误报/漏报率都**没有真实样本校准**。本轮全部是确定性回归与构建。
- 验证器是**词法级**核对（数字串、关键词、语气词），不做语义蕴含判断：
  它能挡住"引用不存在""语气写反""数字听错"，挡不住"引文存在但其实不支持结论"
  的深层情形——那一条按计划仍属人工核对（MC-37 的 D/R 层）。
- `NSRegularExpression` 抽数字：能处理小数与多位数字，但不处理中文数字
  （"三千"不会被抽出来核对）。这是已知的一侧，不在 MC-38 的验收口径内。
- 真实采集、UI 自动化、模型质量基准、发布另行授权。

## M1 增量（MA-03 收尾 / MA-05 落地：来源封存接线，2026-10-05）

范围：把"来源"这一层从只有表和 API 变成真的有生产路径。

- **接线前的状态**：`recordTranscriptRevision` 与 `sealMeetingSource` 只有库和测试在用，
  `meeting_document` / `transcript_revision` / `source_snapshot` 三张表没有生产写入方，
  所以 MA-07 的 `snapshot_id` 一直是 NULL——"这一版依据哪几句话"始终悬空。
- `SessionStore.sealMeetingSource(sessionID:)`：一个事务里做完三件事——
  建/取这一场的知识文档（`source_session_id` 唯一，标题跟会话同源）、
  把定稿行物化成不可变的行修订、写下这一份来源快照。任一步失败整库回滚。
- **幂等**：文字没变的行不新插修订，同一场重复封存不会长出第二份文档。
  只有文字真的变了才新增修订，并把上一条挂成 `parent_revision_id`——
  修订链就是这么长出来的。
- **快照 id 由内容决定**（`snap-<sessionID>-<FNV1a(revisionIDs)>`，自实现稳定摘要，
  不用 `hashValue`——它每次启动都不同，拿它当 id 会让"同一份来源"在两次运行之间
  被当成两份）。内容没变→同一份快照；内容变了→新的快照。
- **MC-46**：改了转录再封存，旧快照原样保留，旧纪要的 `snapshot_id` 仍指向它当时
  依据的那几段话；`latestSourceSnapshot` 只给**新**任务用。
- **没有定稿正文时不写空快照**：库里"没有快照"就是"还没有可锚定的来源"，
  造一条空的等于宣称"这一场没有任何依据"。文档仍然建立（这一场存在）。
- 接到 `SessionCoordinator.sealMeeting`：来源快照冻结成功才算封存成功——
  MA-03 的"快照冻结成功后才排纪要"。这一步失败时**转录已经归档**，
  所以失败原因明说"文字记录已经归档"，避免用户以为整场没存上而重录。
- 回归证据：新增 `MeetingSourceSealTests` **5/5**，
  联合 17 + 35 + 10 + 15 = **82/82 通过**（2026-10-05 核验）；
  `./scripts/macos_app_build.sh` BUILD SUCCEEDED。

### M1 增量（来源封存）迁移说明

- **无 schema 变更**：用的是 MA-05 已经建好的三张表，本轮只补写入路径。
- 旧库不受影响：没有走过封存接线的历史记录仍然没有快照，
  纪要的 `snapshot_id` 仍为 NULL，界面按"这一版没有来源快照"处理。

### M1 增量（来源封存）回退说明

- 整支回退：切回上一提交即可。回退后已封存的快照与行修订**留在库里**，
  不被删除——它们是用户数据的来源记录，不是缓存。
- 回退后重新升级：`sealMeetingSource` 幂等，重新封存不会重复插入。

### M1 增量（来源封存）未验证事项与已知边界

- 正文编辑入口尚未存在（属 MA-11「可逆编辑」）：本轮的"用户改了转录"场景
  是通过直接改库模拟的。真实编辑路径上线后需要重跑 MC-46 的端到端。
- 分人在封存时的说话人映射以 `speaker_name.updated_at` 的最大值作为版本标记，
  **不是逐条映射快照**：能回答"这份来源对应哪一版命名"，但不能逐条回放命名映射。
  逐条版本化属 MA-13。
- 真实采集端到端未做：真实 ASR 文本 + 真实封存的联动没有跑过。

## M1 增量（MA-08 收尾：结论条目与证据锚点，2026-10-05）

范围：把"这条结论依据哪几句"从候选 JSON 里的字符串，变成可查、不可漂移行。

- **schema v6**：`minutes_item`（结论条目）+ `minutes_evidence`（证据锚点）。
  两者此前只以 JSON 文本存在于 `minutes.candidate_json`——能显示，但**问不了、
  删不掉、也保证不了与正文同生共死**。
- **锚点指不可变修订**：`minutes_evidence.revision_id → transcript_revision.id`，
  不是 `line.id`。中间那步映射（`latestRevisionIDsByLine`）是这一节的关键：
  少了它，用户改一次转录，旧纪要的"依据"就悄悄换成了新文字（MC-46）。
- **原文不复制**：`quote` 从修订读回（`LEFT JOIN transcript_revision`）。
  复制一份就会漂移；修订被删时 `quote` 为 nil 且 `revision_id` 被
  `ON DELETE SET NULL` 清空——明确是"来源已不可读"，**不拿当前 `line` 顶替**。
- **同生共死**：`saveMinutesCandidate` 改为一个事务里写 minutes 行 + 条目 + 锚点，
  并带 fencing。旧执行者迟到时先 `ROLLBACK` 返回 false，一条条目都不留。
- **verdict 落库**：每条存 `supported` / `needs_review` / `rejected`，
  一条上多个问题时**取最严重的那个**（有引用不成立，整条就不能算通过）。
  `nil` 只留给"没跑过验证器"的旧 Markdown 版本——把"没查过"和"查过且没问题"
  混同，是这类系统最典型的假阳性。
- 回归证据：新增 `MeetingEvidenceAnchorTests` **7/7**，
  联合 17 + 35 + 10 + 5 + 15 = **89/89 通过**（2026-10-05 核验）；
  `./scripts/macos_app_build.sh` BUILD SUCCEEDED。

### M1 增量（证据锚点）迁移说明

- v5→v6 只新建两张表（`CREATE TABLE IF NOT EXISTS`），不动既有行。
- 旧版本没有条目，读回是空数组；界面按"这一版没有结构化引用"处理。

### M1 增量（证据锚点）回退说明

- 整支回退：切回上一提交即可。已写入的条目与锚点**留在库里**，不被删除——
  它们是用户数据的来源记录。
- 回退后重新升级：`saveMinutesCandidate` 会先 `DELETE` 该版本旧条目再重建，
  重复保存不会堆出重复条目。

### M1 增量（证据锚点）未验证事项与已知边界

- **界面还没消费这批锚点**：本轮把数据落到了库、把查询接口开了，
  但"点某条结论跳回原句"的来源面板属 MA-11，尚未接线。
- 来源单元 id（`u1`、`u2`…）由**当前**来源单元集合分配。恢复旧任务时按当前转录
  重建，若任务两次尝试之间转录被改写，id 的含义会漂移——真正的修法是按快照里的
  `line_revision_ids` 还原单元，属 MA-09 的覆盖账本范围。
- 锚点只到**整条来源单元**（`whole_unit`），没有字符级区间。精确片段匹配属 §7.4
  的第二期，当前不做，也不假装做了。
- 真实端到端未跑：真实模型输出 → 条目落库 → 界面定位的链路没有端到端验证。

## 迁移说明


- 无需迁移：没有新增表、列、索引，`schemaVersion` 保持 1。
- 旧库直接可用；新查询（`latestUsableMinutes`、`pendingMinutesRows`、
  `minutesVersion(id:)`、`searchKnowledge`、`verifyBackup`、`verifyEvidenceQuotes`）
  只读现有表。

## 回退说明

- 整支回退：切回 `origin/main` 即可，库文件不受影响（只新增数据行语义，无结构变更）。
- 单个提交回退：各提交互相独立，按提交哈希逐个 revert；`f213301e` 是纯测试提交，
  回退不影响生产代码。
- 回退不删除用户数据：`removeSession` 语义未变，级联行为与原来一致。

## 未验证事项

- 界面走查（版本切换、导出菜单、检索入口、删除确认）未做。
- 真实模型生成、拒答、截断的端到端语义未做。
- 重启恢复的真实演练、真实设备备份恢复未做。
- 中文短词与精确专名检索质量、删除后索引失效的真实链路未做。
- 真实采集、UI 自动化、发布另行授权。
- 尾句屏障（drain 失败路径）仅静态核验：`releaseCapture(drain:)` 失败记 `lastFailure`、
  分人超时标降级，封存继续走上报结果；真实链路演练未做，另行授权。
- MC-46 已在本分支无迁移约束下落地：改名记修订事件、旧正文原样可查、
  旧版标需复核、引用仍指旧 revision（含重复同名不刷事件的回归）。
  显式“引用指旧 revision id”的字段级溯源仍需来源 revision 的 schema 迁移，未启动。
- 会前准备（MC-04）仅静态核验：来源默认麦克风、偏好恢复已选 App，
  检查失败重试不重置用户已选来源；输入检查 UI 行为未做自动化走查，另行授权。

## M1 增量（MA-09 长会议分窗、覆盖账本与局部重试，2026-10-05）

### 做了什么

- **分窗器**（`MinutesWindowPlanner`，Domain 纯逻辑）：按保守 token 估计把来源单元切成有界窗口。
  - 没有 tokenizer，所以刻意不做"字符数当 token 数"的等价换算：CJK 按 1 字 ≈ 1 token、
    其余按 4 字符 ≈ 1 token，值明显偏大。偏大只会让窗口更碎，偏小会让请求超限、把尾部悄悄丢掉。
  - **每个来源单元恰好 owned 一次**；相邻窗口的重叠单元只进 `context`，只读、不可引用。
  - 超长单句按字符边界切成多段（id 形如 `u7#2`），`lineID` 仍指向原句——锚点照样落回不可变修订。
  - 切点优先落在说话人变化处，避免把一个话题腰斩；没有轮次边界才按 token 硬切。
  - `MinutesWindowBudget.fit(contextTokens:requestedOutputTokens:)` 按模型上下文反推预算；
    拿不到模型上下文时返回 nil，用保守默认值——**不**因为"不知道"就假装整场塞得进一窗。
- **拥有区只读规则进了验证器**：`MinutesEvidenceValidator.validate` 新增 `citableUnitIDs`。
  分窗核对时传 `window.citableUnitIDs`，引用重叠区会被判 `rejected` 并说明原因。
  这是程序侧约束，不依赖提示词自觉。
- **归并（reduce）**（`MinutesCandidateMerger`，Domain 纯逻辑，确定性）：
  以来源身份去重——待办按「任务文本相同 **或** 来源完全相同」合并，负责人/期限取并集，
  同一条待办不会因为落在重叠区而出现两遍（MC-39）。
  跨窗撤回按**结论正文**归组（不是按来源单元——提出在第 3 句、撤回在第 80 句是常态）：
  同一件事既有 `decided` 又有 `retracted` 时两个事件都保留，并标 `存在分歧/未确认`。
  归并后按**全量**来源单元重新核对，引用仍必须落在真实快照里。
- **覆盖账本**（`MinutesCoverageLedger` + schema v7）：
  `minutes.coverage_json` 记整版覆盖，`minutes_window` 逐窗记拥有区间与处理结果
  （processed / failed / truncated、失败原因、该窗候选 JSON、远端响应 id）。
  `isComplete` 要求「单元全覆盖 **且** 无失败/无截断」，缺口不给原文只报数量。
- **生成器接线**：`MinutesGenerator.run` 从「单请求」改为「切窗 → 逐窗 map → 归并 → 复核 → 落库」。
  - 短会得到单窗，走**同一条**验证与落库路径（回退口径：不截取全文前 N 字符）。
  - 每跑完一窗落一行（`recordMinutesWindow`，带父行 fencing）。崩溃恢复时已完成的窗口直接复用，
    不把整场重新发一遍（MC-28/MC-27）。
  - 一个窗口都没成功 → 整场如实失败，不发布半成品。部分成功 → 候选可用但正文带覆盖说明，
    `coverage` 暴露给界面，**不标整场完整**（MC-40）。
  - 取消时逐个取消在飞的远端任务并逐个如实汇报，不再只取消最后一个。
- **局部重试**（`MinutesGenerator.retryFailedWindows`）：只重跑失败窗口，成功窗口的候选直接复用；
  重新归并时以来源身份去重，同一条待办不会因为重跑多出一条。
  边界：**已采用的版本拒绝重开**（用户核对过的东西不能被一次重试换掉）；
  没有失败窗口时不做任何事，不新建版本、不发请求。

### 回归证据（2026-10-05 核验）

- 新增 `MeetingWindowCoverageTests` 14 项：拥有区唯一/重叠只读、短会单窗、首中尾均 owned、
  超长单句切分与范围映射、token 估计保守性、重叠区同一条待办归并后只有一条、
  跨窗撤回保留两个事件并标未确认、中间窗失败报缺口、截断窗不算完整、
  账本随版本落库重开可读、局部重试只重跑失败窗 + 旧代际迟到写入被 fencing 挡住、
  已采用版本拒绝重试、v6 → v7 迁移不补造覆盖账本。
- 会议相关套件 103 项全绿：`MeetingWindowCoverageTests` 14、`MeetingMinutesEvidenceTests` 17、
  `MeetingMinutesVersioningTests` 35、`MeetingMinutesJobRecoveryTests` 10、`MeetingSourceSealTests` 5、
  `MeetingEvidenceAnchorTests` 7、`AssistantPersistenceTests` 15。
- 全量 `swift test --package-path macos/SpeechRailApp`：**744 项全绿**。
- `./scripts/macos_app_build.sh`：**BUILD SUCCEEDED**（SPM 不编译 `MinutesGenerator.swift`，
  只有这个脚本真正类型检查生成器接线）。

### M1 增量（MA-09）迁移说明

- schema v6 → v7：`minutes` 追加 `coverage_json`；新增 `minutes_window`
  （`minutes_id` 外键级联、窗口序号、拥有/重叠单元 JSON、结果、失败原因、该窗候选、远端响应 id）。
- **不回填** `coverage_json`：v6 之前是单窗生成的，从来没有分窗账本。
  补一份"全部覆盖"等于替用户断言"当时整场都整理到了"，是伪造。
  读回时 `coverage` 为 nil 就明确是"没有账本"，不会退化成"全覆盖"。
- 老库升上来后行为不变：仍是单窗纪要，只是 `coverage` 为 nil。

### M1 增量（MA-09）回退说明

- 代码回退：revert 本次提交即可。库文件不回退也不需要回退——
  v7 只新增表与列，老版本读库时 `sqlite3_column_count` 兼容、不读新列。
- 数据回退：`minutes_window` 行与 `coverage_json` 列是纯增量，删除它们不改变既有纪要正文、
  条目与锚点。**不建议**手工删列；确需回到 v6 形状时按 §"迁移说明"的逆操作。
- 失败口径回退：窗口失败不影响转录，转录早已封存；用户随时可以重新生成。

### M1 增量（MA-09）未验证事项与已知边界

- **窗口预算是实验起点，不是能力承诺**：`windowTokens = 3000`（计划给的 2,500～4,000 区间中点）。
  当前 `LLMConfiguration` 里**没有** provider/model 的上下文能力字段，所以没有按模型校准。
  接真实模型前必须实测并调整 `MinutesGenerator.windowBudget` 或改用
  `MinutesWindowBudget.fit` 传入真实上下文能力。这是本轮最需要后续校准的一处。
- **归并是程序侧确定性合并，不是模型 reduce**。好处：不新增一次 provider 调用与失败面、
  可完整单测。代价：语义层面的"两件事其实是一件"只能靠文本/来源去重识别，
  同义改写（"李雷跟进" vs "李雷负责跟进"）在 task 文本完全不同时不会被合并。
  计划 §6.3 要求"全局合并必须能访问候选对应原文"——本实现通过「归并后按全量单元重新核对 +
  锚点读自修订」满足，但没有让模型重读原文做语义归并。
- **跨窗分歧判定按结论正文归组**，正文不同但实为同一件事的两条结论不会被标未确认。
  验证器是词法级，不做语义蕴含判断（MA-08 已记录的同一边界）。
- **未接真实模型**：没有跑过任何真实 provider 的多窗请求，因此
  「逐窗请求真的被 provider 接受」「远端 id 真的能按窗恢复」只有代码层保证，
  没有实测证据。真实质量基准按目标另行授权。
- **窗口是串行处理的**。长会窗口多时总时长线性增长；没有做并发，也就没有验证过
  并发下的资源准入与租约表现。
- **超长单句切分按字符边界**，切点优先落在标点/空白。它保证不丢字、不改字，
  但不保证语义完整——一句跨窗口的话可能被切成两段分别归纳。
- 界面未消费覆盖账本：`coverage` / `retryableWindowCount` 已有，但"覆盖缺口"面板与
  「只重试失败的部分」按钮属 MA-11，本轮没有 UI 改动。
- 真实采集、UI 自动化、发布另行授权，本轮均未做。
