# 有声书大规模选角分阶段实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 `executing-plans` 逐任务执行，步骤用复选框记录。2026-10-15 用户授权实施 S0～S2 及 P0 定向验收；保留已有未提交改动，迁移仅用临时副本，不操作真实用户库、不改变运行态、不提交或安装。S3～S5 保持计划状态，不从本文推导额外授权。

**Goal:** 先消除种子、候选隔离、准入、容量与批量写入的 P0 风险，再建立稳定选角、可恢复音色资产管理和独立的听感验收。

**Architecture:** App 消费同一能力快照与目录快照，生成可评审的 `AudiobookCastingPlan`，通过现有 Store actor 原子提交。服务端参数契约保持不变；分配器可在保留 P0 守卫的条件下退回基础算法，持久化迁移独立设置恢复点。

**Tech Stack:** Apple Silicon macOS 26.0、现有 Swift 6 工具链、SwiftUI/Foundation、SQLite、JSON、XCTest；Python `>=3.14,<3.15` 的现有 fake-backend 契约测试。P0 不引入模型、求解器或向量数据库依赖。

**Spec:** [有声书工坊大规模角色选角与音色资产规范](../../developers/audiobook-mass-casting-spec.md)，version `2.0.1`。阅读时同时核对 `contracts/openapi.yaml`、`src/speechrail/domain/tts_request.py`、`docs/developers/testing-acceptance.md` 和 macOS 设计系统。

**状态（2026-10-15）:** S0～S2 已完成。独立审查提出的五项问题已逐项复现并修复；最终定向验收为 Swift 209 项、Python 9 项零失败，S3～S5 未实施。实际命令、数量、迁移恢复及早期夹具目录隔离问题见 [P0 定向验收记录](../../audits/2026-10-15-audiobook-mass-casting-p0-acceptance.md)。以下基线表记录实施前静态事实，不能代替验收结果。

## Global Constraints

- 单服务、单 worker；不下载、加载或卸载模型，不改变服务、档位、安装或发布状态。
- 克隆合成为 `speed=1.0` 且 caller seed 省略；其他路径读取 `voice.operations.http_speech.parameters`，不按模式名称推定完整能力。
- 正式制作始终 `require_output_pass`；试听与输出检查保留各自入口，不把不可路由或未验收状态默认成成功。
- 他书专用、归档和未知归属的自定义音色不得自动入池；候选为空不回退到原目录。
- 旁白计入容量；人工独占、锁定与已确认声音受保护，任何批量错误整批零提交。
- 不删除/改写原文、历史候选、已采用音频或并行编辑；未知来源不伪造，真实素材与备份放仓库外。
- 保留已有暂存和未暂存改动；同一处出现并行编辑时暂停该处写入并核实，不还原整文件或重置分支。
- 测试使用 fake backend、URL transport 替身和临时目录；不操作真实作品库，不运行完整 gate 或全套测试来替代定向验收。
- 产出 `.app` 的构建只用 `scripts/macos_app_build.sh` 并遵循 release skill。UI 自动化须当前用户逐次明确授权；真实质量/性能测量须另行授权。
- P0 仅为合法 system 身份缺失做 `voice_revision` 可空的最小迁移，不混入画像、政策或目录格式演进；所有正式用户数据迁移在后续明确实施授权、影响和备份覆盖之前只在临时副本演练。
- 计划命令本身不证明已执行；实际证据单独记录，不自动 commit、push、安装或发布。

## Review Focus

1. 池内全是他书、归档或未就绪声音时，应返回可解释空集；不能因“需要完成绑定”扩大可见范围（S2，AC-P0-02）。
2. 旧 clone 绑定已有 caller seed 时，应展示修正方案并保留作品；不能直接向服务发送非法参数或静默改写已确认绑定（S1，AC-P0-01）。
3. system 合法缺少 voice revision 与自定义声音身份缺失不同；前者可省略 header，后者阻断，不能共用伪造版本兜底（S1，AC-P0-06）。
4. 批量中最后一项失败、输入变化或任务取消时，前面项目和共享政策也必须不提交（S2，AC-P0-04/07）。
5. 音色晋升后归档恢复、迁移后又产生新作品时，应保持全局身份和新增作品；旧备份不能无条件覆盖当前数据（S4，AC-P1-06/07）。

## 1. 阶段顺序与发布门

| 阶段 | 优先级 | 可独立评审的交付 | 依赖与退出门 | 相对工作量 |
| :--- | :--- | :--- | :--- | :--- |
| S0 | P0 前置 | 源码基线、触及文件清单、临时夹具和恢复准备 | 开始写代码前完成；不把工作区整理成干净状态 | 小 |
| S1 | P0 | 合法参数、完整 header 透传、冻结 pin 与真实追溯状态 | AC-P0-01/06；不修改正式服务契约 | 小～中 |
| S2 | P0 | 严格候选池、容量方案、锁定保护与原子批量提交 | 依赖 S1；AC-P0-02/03/04/05/07/08；全部 P0 才算通过 | 中 |
| S3 | P1 | 稳定人物政策、画像、场景图与有界分配；绑定 schema 演进 | 依赖 P0；AC-P1-01～04/08；回退算法保留全部 P0 守卫 | 中～大 |
| S4 | P1 | 作用域/生命周期拆分、目录迁移和跨 Store 恢复 | 依赖 P0 与 S3 的绑定政策；AC-P1-06/07 | 中 |
| S5 | P1／独立质量门 | 推荐解释、试听、影响预览、撤销及授权后的听评 | 依赖 S3/S4；AC-P1-05、AC-Q-01～03；未验收微语速保持关闭 | 中，听评取决于授权与素材 |

相对工作量是规划判断，不是工时承诺。S1/S2 可以独立交付安全修复，不等待后续画像、UI 或听评；不能因 P1 尚未完成而退回不合法参数或宽松候选。

## 2. 2026-10-15 静态基线

下列入口须在 S0 重新核对，不能把行号或其他会话的测试结果当作执行证据。

| 已核对事实 | 当前入口 | 对应处理 |
| :--- | :--- | :--- |
| clone caller seed 被服务拒绝；共享辅助函数却为 clone/instruction 分配四个循环种子 | `contracts/openapi.yaml`、`src/speechrail/domain/tts_request.py`、`AudiobookCastRegistry.computeMicroProsodyAndSeed` | S1：修正生成与旧绑定请求边界，改写 AC4 |
| 渲染载体有 seed，但请求选项与真实适配器没有完整 header 透传 | `AudiobookDependencies.swift`、`ServiceContractTypes.swift`、`AudiobookProductionWiring.swift` | S1：新增 callerSeed 选项并覆盖所有复制 helper |
| `ServiceAPIClient.createSpeechRender` 已在边界强制严格准入；上层仍保留放宽选项的重试分支 | `ServiceAPIClient.swift`、`AudiobookProductionWiring.swift` | 保留边界强制策略，清理无效/误导的降级分支；不能声称当前正式 client 已被该分支降级 |
| 当前选角器仅过滤 available，scopedVoices 为空时退回全部声音 | `AudiobookCastRegistry.recommendVoiceBindings` | S2：统一候选检查与结构化失败 |
| 当前容量算法与原规格公式不同，并将可用声音数至少视为二 | `AudiobookCastRegistry.computeRoleDialogueStats` | S2：用真实容量与显式分池替代；人物层级分离在 S3 完成 |
| 批量绑定发现复用时会自动开启角色共享 | `AudiobookCastController.bindVoicesBatch` | S2：完整方案验证后原子应用，不修改人工独占意图 |
| 确认门禁在 Store 事务中，已有分析状态与实际发声检查 | `AudiobookProjectStore.saveCastConfirmation` | 复用该事务边界，补充缺失/unknown 反例，不在 controller 复制另一套不一致门禁 |
| 适配器会采用最新 revision，结果又可写请求 modelRevision；WAV 大小参与 provenance 判定 | `AudiobookProductionWiring.LiveAudiobookSpeechRenderer` | S1：冻结请求与实际事实分离；缺失证据保持未知 |
| voice_bindings 的 voice_revision/model_revision 为非空列；目录 JSON 无显式 schema envelope，错误被吞掉 | `AudiobookStoreSchema.swift`、`VoiceCatalogStore` | S1 最小可空身份迁移；S3/S4 的政策与目录迁移单独恢复 |
| 恢复归档声音会根据 originBookID 重新推导 scope | `VoiceCatalogStore.unarchiveVoices` | S4：保留晋升后的可见范围，未知旧记录不猜测 |

记忆中的“自动准备、关键处确认”和作品保护仅作背景，不证明这些入口通过验收。

> 🧠 **From Hindsight memory (有声书工坊 TXT 多角色有声书)** — 历史产品方向要求试听后固定角色声音、更换前展示影响范围，并只重做受影响片段；本计划保留这些约束。

## 3. S0：实施前基线与恢复准备

**Files:** 只读 `AGENTS.md`、本规格、实际将修改的 Swift/Python 入口及相关测试；不整理其他任务的文件。

**Interfaces:** 输出本次基线清单：分支、目标文件内容摘要、既有改动边界、可运行的定向测试入口、后续阶段使用的夹具与备份方式。

- [x] 运行 `git status --short --branch`，核对当前 diff；重新检查基线表，记录测试尚未运行和源文件并行变更。
- [x] 定位现有 fake renderer、URL transport、临时 Store fixture；复用 `ServiceContractTests`、`AudiobookCastTests` 和 `AudiobookStoreTests` 的注入边界。
- [x] 为每个任务记录修改前的目标文件快照或精确补丁，保存在仓库外；仅用于三方比较本任务改动，不作为整文件覆盖其他编辑的依据。
- [x] 准备 schema 1 的临时作品库、目录夹具、一致性备份及失败注入；S1/S3/S4 各自演练迁移与恢复，均不接触真实作品库。若当前 schema 已被其他任务演进，先重新协调迁移版本再写入。

**验收:** 文件所有权明确；测试不读取用户目录；计划中的现有文件均存在，新建文件明确登记为待创建。

**回退:** 此阶段无产品写入；保留原工作区和用户数据，停止后续实施即可。

## 4. S1：合法参数与真实渲染链（P0）

### Task 1：参数策略与 header 透传

**Files:** 修改 `macos/SpeechRailApp/SpeechRailControlKit/ServiceContractTypes.swift`、`macos/SpeechRailApp/SpeechRailApp/{AudiobookCastRegistry,AudiobookDependencies,AudiobookProductionWiring,ServiceAPIClient}.swift`；测试在 `macos/SpeechRailApp/SpeechRailMacControlTests/{ServiceContractTests,AudiobookCastTests,AudiobookProductionTests}.swift` 与 `tests/test_tts_request_validation.py`。

**Interfaces:** 为 `SpeechRailRequestOptions` 增加 `callerSeed: Int?`，header 为 `SpeechRail-Seed`；请求载体的 `seed` 映射到此选项。合法域 `0...4294967295`，未知/不支持路径不发送；clone 的生成策略固定 `(speed: 1.0, seed: nil)`，不修改 Python 放行规则。

- [x] 先添加 `testCallerSeedTravelsAsHeaderAndSurvivesOptionCopies`、`testClonePolicyOmitsCallerSeed`、`testSeedBoundsRejectInvalidValues` 和 `test_base_clone_rejects_caller_seed`；断言 body 没有 seed，所有 `with...` 和正式渲染复制 helper 保留合法选项。
- [x] 通过 `AudiobookProductionWiring.makeLiveDependencies` 注入临时 rootURL、fake discovery/control/LLM 和使用 URL transport 替身的 ServiceAPIClient，捕获从绑定到真实请求构造器的请求；添加 `testAudiobookRenderCarriesSupportedSeedToWire`，禁止只在 DTO 上断言字段相等或调用真实网络。非法种子由请求构造边界抛出结构化本地参数错误，不裁剪、不靠断言崩溃。
- [x] 定向运行新增用例，确认失败原因对应缺陷；实施能力检查、clone 无种子与完整透传，再运行同一用例至通过。
- [x] 对已有非法 clone 绑定返回“需要重新确认声音参数”的修正方案，不就地覆盖持久化绑定或旧音频；新增推荐默认不启用微语速。
- [x] 验证 `testRenderRetriesKeepFrozenParametersAndStrictPolicy`：仅瞬态忙碌允许有限重试；参数拒绝不换 seed、不换声音、不降低 validation policy。

### Task 2：冻结 pin、严格准入与事实报告

**Files:** 修改 `AudiobookProductionWiring.swift`、`AudiobookDependencies.swift`、`AudiobookProductionController.swift`、`AudiobookDomain.swift`、`AudiobookStoreSchema.swift`、`AudiobookProjectStore.swift`；必要时调整 `ServiceAPIClient.swift` 的回执事实载体。测试在 `AudiobookProductionTests.swift`、`AudiobookStoreTests.swift` 与 `ServiceContractTests.swift`。

**Interfaces:** 请求预期 identity 与实际 `AudiobookRenderCallOutput` 分离；`AudiobookVoiceBinding.voiceRevision` 和请求的 `expectedVoiceRevision` 改为 `String?`。仅在 system 且契约认可时接受缺失，custom 缺失阻断。SQLite 从核实的 schema 1 迁移至 schema 2，仅将 `voice_bindings.voice_revision` 改为可空并同步序列化和 digest 的缺失标记；其他列、主外键、记录和作品引用保持。冻结请求不采纳新 pin；输出身份缺失保持 optional，provenance 仅取已核验事实。旧占位版本无法证明身份时要求重建并确认方案，不静默改写旧绑定。

- [x] 添加 `testRenderRejectsRevisionDriftInsteadOfRepinning`、`testSystemVoiceMayOmitVoiceRevision`、`testMissingReceiptKeepsActualIdentityUnknown` 与 `testWAVLengthDoesNotVerifyProvenance`，先证实失败。
- [x] 添加 `testNullableVoiceRevisionMigrationPreservesAllRows`、`testIdentityMigrationFailureLeavesSchemaOneIntact` 与 `testSchemaTwoRoundTripsSystemMissingRevision`；在临时库中演练表重建、事务回滚、外键与历史引用核验。迁移前保留一致性备份，未知旧身份保持待确认，不回填空字符串或假版本。
- [x] 保留 `createSpeechRender` 在最外边界钉死 `require_output_pass` 的行为，并覆盖协议默认实现/替身路径；移除上层以旧验收原因放宽选项的重试。
- [x] 使用当前快照仅验证计划 pin 和参数是否仍成立；revision 不同、必需身份未知或确定性拒绝时返回结构化待处理项。
- [x] 运行定向回归并记录实际测试数和新增测试名：

```bash
swift test --package-path macos/SpeechRailApp --filter 'ServiceContractTests|Audiobook(Cast|Production|Store)Tests'
uv run --no-sync pytest --no-cov tests/test_tts_request_validation.py
```

**S1 验收:** AC-P0-01/06 全部通过；新增测试实际执行且零失败；Python clone 拒绝合同保持；最小 schema 迁移及失败恢复在临时副本通过。未迁移真实用户库、真实推理或安装。此门只证明参数与身份边界，不宣称 P0 全部完成。

**S1 回退:** 在支持 schema 2 的安全实现内回退支持种子的可选路径并保持 `callerSeed=nil`，保留 clone 限制、严格准入和版本漂移拒绝。迁移未提交时原 schema 1 保持；提交后优先保留新 schema，不强行转回非空列。只有确认没有迁移后写入且恢复演练通过时才能恢复旧快照与匹配代码；已有新作品时不得覆盖。不能恢复非法种子或伪造 provenance。无法保持守卫时暂停新制作，旧作品继续可读。

## 5. S2：候选、容量与原子应用（P0）

### Task 3：完整候选池与可评审规划结果

**Files:** 修改 `AudiobookDomain.swift`、`AudiobookCastRegistry.swift`、`AudiobookWorkflowModel.swift`；测试在 `AudiobookCastTests.swift`、`AudiobookWorkflowTests.swift`。

**Interfaces:** 在现有领域模块定义规格 §2.4 的 `VoiceCatalogSnapshot`、`VoiceCatalogLoadState`、`AudiobookCastingIssue`、`AudiobookCastingPlan`，以及方案需要的 `AudiobookRoleVoicePolicy` 内存类型；该政策的完整持久化在 S3 完成。规划入口统一为：

```swift
public static func recommendVoiceBindings(
    characters: [AudiobookCharacter],
    annotations: [AudiobookAnnotation],
    snapshot: EffectiveCapabilitySnapshot,
    catalog: VoiceCatalogSnapshot,
    bookID: UUID,
    existingBindings: [UUID: AudiobookVoiceBinding]
) -> AudiobookCastingPlan
```

本书首选合集从 catalog 快照读取；调用方同步迁移，不保留绕过完整快照的旧字典返回入口。P0 的目录加载状态先围绕现有文件格式建立，只读失败不能伪装为空目录。

- [x] 添加 `testEmptyScopedPoolNeverFallsBack`、`testAvailableButNotProductionReadyIsExcluded`、`testMissingCustomScopeNeedsConfirmation`、`testCatalogReadFailureIsNotEmptyCatalog` 和 `testAliasesDoNotIncreaseVoiceCapacity`，包含 false/nil/unsupported/unknown 组合。
- [x] 先运行新增失败用例，再实施统一候选检查；系统预设例外只认快照可证的身份，自定义来源未知不默认全局。
- [x] 将缺失候选、未就绪、目录故障等原因投影为恢复动作；不通过隐藏问题凑成“100% 已绑定”。

### Task 4：容量与既有锁定保护

**Files:** 修改 `AudiobookCastRegistry.swift`、`AudiobookCastController.swift`；测试在 `AudiobookCastTests.swift`。

**Interfaces:** `AudiobookCastingPlan` 包含独占/共享占用与拟议政策变化；先做受限候选最大匹配，再按规格 `R+K+S≤M` 分池。S2 不新增政策 schema，保守保留既有绑定与独占约束；不能识别其来源时按受保护项处理，暂不提供自动重排。

- [x] 添加参数化 `testCastingCapacityIncludesNarrator`，覆盖 M=0/1/2/3/5/6、零台词、多旁白异常输入、少角色与已占用声音；明确 M=6/R=1/S=2 时其他独占最多三。
- [x] 添加 `testExclusiveMatchingDoesNotConsumeAnotherRolesOnlyCandidate` 与 `testLockedDuplicateReturnsIssueWithoutDemotion`，用小型可行/不可行候选集合断言结果。
- [x] 先验证新增用例失败，再实施容量与独占匹配；取消把 M 提升为二的做法，不为满足数量静默改共享政策。
- [x] 添加重复输入/输入重排/取消与有限预算用例；P0 沿用基础共享评分，残余同场问题如实展示，不宣称已完成 S3 场景算法。

### Task 5：整批校验、确认门禁与故障恢复

**Files:** 修改 `AudiobookCastController.swift`、`AudiobookProjectStore.swift`、`AudiobookWorkflowModel.swift`；回归在 `AudiobookCastTests.swift`、`AudiobookStoreTests.swift`、`AudiobookWorkflowTests.swift` 与 `AudiobookInvalidationTests.swift`。

**Interfaces:** 新建 `applyCastingPlan(bookID: UUID, plan: AudiobookCastingPlan, acknowledgedIssueIDs: Set<UUID>) async throws`，对新增共享提议及同场共享等可接受风险要求显式确认，接受记录绑定 inputDigest；硬约束不可确认绕过。Store 的 `saveCastingPlan(bookID: UUID, plan: AudiobookCastingPlan) throws` 在单事务中重算包含标注与绑定的 localInputDigest，比较 cast 修订并提交可由既有列表达的政策、绑定和必要失效；不先删除角色再插入，未持久化的新政策来源重启后仍按受保护的未知来源处理。目录/能力预检在事务前完成，每次后续片段准入重新检查相关事实，避免把跨进程检查说成联合事务。

- [x] 添加 `testBatchConflictNeverEnablesSharing`、`testLastInvalidBindingRollsBackWholeBatch`、`testStalePlanDoesNotOverwriteNewCast`、`testChangedAnnotationsInvalidatePlanWithoutCharacterChange`、`testChangedPlanCannotReuseRiskAcknowledgement` 和 `testCancelledApplyDoesNotCommitPartialBindings`，注入末项和数据库提交失败。
- [x] 添加 `testSilentRoleExemptionRequiresCompleteAnnotations` 与 `testUnknownDialogueKeepsChapterGate`；复用 Store 内确认事务，不复制弱化门禁。
- [x] 将旧单角/批量/按行当入口接入同一校验；默认只选未绑定未锁定角色，去掉遇冲突自动设置共享和静默 continue 的成功路径。
- [x] 验证计划确认后、片段开始前音色被归档/归属变化时阻止新增不合法请求；进行中的候选保留为待复核，不删除音频或自动采用。
- [x] 运行以下定向回归，检查新增用例实际被选择；失败先区分本任务与并行基线：

```bash
swift test --package-path macos/SpeechRailApp --filter 'ServiceContractTests|Audiobook(Cast|Store|Production|Workflow|Invalidation)Tests'
git diff --check
```

**S2 验收:** AC-P0-02/03/04/05/07/08 全部通过，连同 S1 证据覆盖全部八项 P0；目录空集不泄漏、人工政策不被改写、事务故障零部分提交，旧音频及采用版本仍可读。任何未执行/跳过的新 P0 反例都不能记为通过。

**S2 回退:** 保留候选与严格请求守卫，停用自动推荐/批量应用，退回对合法声音的逐角色手动绑定。按本任务精确补丁回退计算/投影改动，不覆盖并行编辑；已接受的合法绑定和音频保留，不重新启用未过滤池或自动共享。S2 无额外格式迁移；回退代码必须兼容 S1 的 schema 2，数据库不随计算代码回退而还原。

## 6. S3：稳定角色政策、画像与场景分配（P1）

### Task 6：政策与身份的持久化演进

**Files:** 修改 `AudiobookDomain.swift`、`AudiobookStoreSchema.swift`、`AudiobookProjectStore.swift`、`AudiobookCastController.swift`、`AudiobookFragmentPlanner.swift`、`AudiobookInvalidation.swift`；测试在 `AudiobookStoreTests.swift`、`AudiobookCastTests.swift`、`AudiobookInvalidationTests.swift`。

**Interfaces:** 落实 `AudiobookRoleVoicePolicy(sharingPolicy, bindingOrigin, isLocked)`；来源事实与预期值分别存储。数据库在 S1 schema 2 的基础上进入 schema 3，增加政策与事实字段，保留全部原始记录和作品引用；旧来源统一 `legacyUnknown`，不猜测用户意图。依赖摘要使用有效输出语义，不使用一次性 snapshotID 作全量失效键。

- [ ] 建立 schema 2 夹具，添加 `testLegacyPolicyMigratesAsLockedUnknown`、`testPolicyMigrationKeepsUnknownIdentity` 和 `testPolicyMigrationInterruptionRecovers`，覆盖旧占位身份待确认、system 合法缺失、未知政策冻结、迁移中断和重启恢复；先测失败再实施 schema 3 迁移。
- [ ] 在临时副本完成前后角色/绑定/候选/章节版本计数与引用核验；未知身份不被填成假值。
- [ ] 测试新增无关声音、修改标签、原文重分块时已确认绑定零改动；声音/参数真实变化只失效受影响片段。

### Task 7：统计、画像与有界场景规划

**Files:** 从大文件提取 `VoiceTaxonomyClassifier` 到待创建的 `macos/SpeechRailApp/SpeechRailApp/VoiceTaxonomyClassifier.swift`；新建 `AudiobookSceneConflictGraph.swift`、`AudiobookCastingPlanner.swift`。调整 `AudiobookDomain.swift`、`AudiobookCastRegistry.swift` 和调用方；新增/调整相应 `AudiobookCastTests.swift`，必要时创建 `AudiobookCastingPlannerTests.swift`。新文件同步 SwiftPM 与 Xcode 的既有注册方式，不生成第三方 checkout。

**Interfaces:** Registry 保留 S2 的完整快照规划入口，委托纯计算 planner。场景图的边独立保存 `directDialogue / sceneCoPresence / chapterCoPresence` 与稳定来源；画像六维独立、带 source/confidence。planner 的策略显式区分 `baseline` 与 `sceneAware`，两者共用 P0 候选/锁定校验。

- [ ] 添加 `testRechunkingPreservesDialogueScalarCount`、`testNarrationDistanceDoesNotCreateDirectDialogue`、`testDifferentScenesKeepDistinctEdges`、`testDuplicateWindowsDoNotDoubleCountEdges` 和 `testWeakEdgesNeverBecomeDirectDialogue`，用具体原文区间断言统计与边类型；人工层级不被计算覆盖。
- [ ] 添加 `testVoiceTaxonomyKeepsIndependentUnknownAttributes` 和 `testManualVoiceTraitsOverrideInference`，使用男童/女童/老年女性/中性/无描述及中英混合描述的标注夹具；断言未知保留和人工覆盖，不以每个条目都有枚举值当准确。
- [ ] 添加 `testScenePlannerSolvesKnownColorableFixture`、`testTwoVoicesCannotResolveDialogueTriangle` 和 `testSearchBudgetDoesNotRelaxLockedBindings`；比较基础评分与 DSATUR 候选排序＋局部修复。已知可着色小图零直接冲突，两色三角返回可解释结果，冻结项零改动；预算上限为 100000 个局部变更候选。
- [ ] 用 200 角色×500 声音纯计算夹具验证基础画像评分至多 100000 个组合，复用缓存不改变结果；不凭该检查报告毫秒级性能或真实模型吞吐。
- [ ] 定向运行 Cast/Store/Invalidation 与新增 Planner 测试，按需用包装脚本编译注册后的 target；不运行 UI 自动化。

**S3 验收:** AC-P1-01～04/08 通过；同一输入结果稳定，锁定与 P0 守卫保持；迁移副本完整性与失败恢复有证据。正式用户库迁移仍受后续授权与备份条件约束。

**S3 回退:** 在支持新 schema 的同一实现中将 planner 切回 `baseline`，保留画像、政策、锁定、作品和 P0 校验，不降级数据库。若需旧 App，仅在可读性验证及后续写入审计后处理；有新增作品时不得用迁移前快照覆盖。无法安全读取时只读打开/导出恢复信息，保留原数据待修复。

## 7. S4：音色资产生命周期与恢复（P1）

### Task 8：目录 schema 与可靠保存

**Files:** 修改 `VoiceCatalogStore` 及目录领域类型；可从 `AudiobookDomain.swift` 移至待创建的 `macos/SpeechRailApp/SpeechRailApp/VoiceCatalogStore.swift`，保持唯一声明并同步 target 注册。回归在 `AudiobookCastTests.swift`，或待创建的 `VoiceCatalogStoreTests.swift`。

**Interfaces:** 目录 envelope 使用 `schemaVersion=2`，分离 `visibilityScope` 与 `lifecycleState`；对外 `VoiceCatalogSnapshot` 接口沿用 S2。mutator 失败可抛出，只有持久化成功后递增 revision 并发布通知；保留单进程串行写，不增加数据库或多实例架构。

- [ ] 添加 `testPromoteArchiveRestoreKeepsGlobalScope`、`testArchivedLegacyOriginIsNotEnoughToInferScope`、`testWriteFailureDoesNotPublishSuccess` 和 `testUnreadableCatalogPreservesUnknownRecords`。
- [ ] 先测失败，再实施版本化读取、旧数据迁移、原子保存及恢复点；旧归档记录无法证明归档前 scope 时保持 archived/unknown，待显式确认。
- [ ] 验证迁移和恢复重启后的属性、合集和来源完整；未来 schema 被拒绝且原文件保留，不以重建空文件修复。

### Task 9：设计/克隆返回与跨 Store 意图恢复

**Files:** 修改 `AudiobookWorkflowModel.swift`、`AudiobookCastController.swift`、`AudiobookProjectStore.swift`、`AudiobookStoreSchema.swift`、`CreatorSurfaceViews.swift` 与对应 Store/Workflow/Cast 测试。

**Interfaces:** SQLite 从 S3 的 schema 3 进入 schema 4，登记 `voice_registration_intents`（操作 ID、book/role/voice ID、有界且不含书稿/prompt 的目标元数据及其摘要、预期修订和阶段）；目录先持久化 bookExclusive，再提交绑定并完成意图。恢复幂等处理未完成意图，校验修订以免覆盖其他操作，不删除声音或自动晋升全局；设计与克隆保存各自真实来源。

- [ ] 添加参数化 `testVoiceRegistrationRecoversAtEveryCommitBoundary`，依次在意图登记、目录写入、绑定提交前后注入故障；重复恢复不重复绑定、不泄漏资产、不删除其他任务的新记录。
- [ ] 验证本书角色/群像定制默认书籍专用；晋升只由显式用户动作触发。配音台与其他书籍读取同一目录政策，目录变化后投影刷新。
- [ ] 验证归档不破坏历史播放和引用；恢复后可见范围正确，继续制作仍须重新满足当前生产准入。
- [ ] 运行目录、Cast、Store、Workflow 定向回归；核对迁移前后一致性清单及无真实目录访问。

**S4 验收:** AC-P1-06/07 全部通过；跨 Store 每个故障点可恢复，内存成功与磁盘成功一致，旧未知事实保留。目录修订变化不得触发无关片段全量重做。

**S4 回退:** 停用新建返回与批量生命周期动作，保留读取、播放、P0 过滤和 journal。优先在支持目录 schema 2 及当前 SQLite schema 的版本内修复/恢复单个意图；只有确认没有后续修改时才恢复目录快照，不连带覆盖作品库。旧代码无法读取新目录时保留原文件并报告，不自动转成空目录。

## 8. S5：选角交互与独立听评（P1）

### Task 10：推荐理由、影响预览、试听与撤销

**Files:** 修改 `AudiobookWorkflowModel.swift`、`AudiobookBookWorkspaceView.swift`、`CreatorSurfaceViews.swift`、`AudiobookRevisionController.swift` 及对应 Workflow/Revision 测试。新增视觉值仅在 `SpeechRailDesignTokens.swift` 定义并同步设计系统。

**Interfaces:** 消费 Plan 的 issues、影响集合和目录通知；相同文本试听与对手戏试听分别建模。批量 apply 的确认绑定 plan 身份及已接受问题 ID，撤销通过新修订恢复旧政策，不删除音频或覆盖已采用版本。

- [ ] 添加 `testRecommendationExplainsEmptyPoolAndRecovery`、`testStaleRecommendationCannotApply`、`testBatchImpactAndUndoPreserveAdoptedVersion` 和 `testCatalogChangesRefreshProjection` 的纯投影/控制器回归；再调整页面，默认只呈现完成当前任务的少量动作。
- [ ] 保留一个清楚的主动作和搜索范围；收藏独立于作用域；高级画像和技术诊断渐进披露，不新增一排所有维度的首屏筛选。
- [ ] 定向测试 Workflow/Revision/Invalidation；获实施构建授权时使用 `scripts/macos_app_build.sh --configuration Debug`。未获逐次授权不启动前台 UI 自动化。

### Task 11：冻结试验并验证角色辨识与微语速

**Files:** 验收方案和脱敏结果写入获授权的新 `docs/audits/` 记录；原始材料放仓库外。本任务不预先创建通过报告或下载模型。

**Interfaces:** AC-Q-01/02 的冻结 manifest 至少包含制品/模型 revision、声音 revision、参数、素材摘要、对手戏分组、基线与候选、听众/评分设计及统计方法；报告每组结果与未覆盖项，不保存完整书稿或实名听众信息。

- [ ] 在获得真实模型/质量验收授权后读取 perf-benchmark skill，先冻结至少 20 段、10 组对手戏与至少 3 位听众的方案；试验执行前固定指标和阈值。
- [ ] 按 AC-Q-01 检查总体≥90%、每组≥80% 的角色辨识；按 AC-Q-02 检查逐条文本忠实度和配对自然度区间。统计不足或任一门未通过时记录未通过/未验收，保持微语速关闭。
- [ ] 获当次 UI 自动化授权后才执行 AC-Q-03；人工走查、自动化和真实声音分别记录，不把其中一个结果扩展到其他维度。

**S5 验收:** AC-P1-05 及已获授权的 AC-Q 项有独立证据；未获授权的项目明确 `not_evaluated`。默认 speed=1.0 和无自动微语速可独立交付，听评未完成不虚构质量通过。

**S5 回退:** 恢复基础选角投影，保留已确认绑定和影响预览/撤销；微语速默认关闭，新提案回到 1.0。已经确认的参数变更须再次展示影响并显式接受，不就地重写旧 Binding、候选或采用音频。

## 9. 证据、文档同步与阶段交接

- [x] 每个任务先运行新增失败反例，再实施、重跑同一回归；必要时扩大到受影响模块。不用零测试、筛选摘要或独立退出码代替实际断言与对象状态。
- [x] 每阶段记录执行时间、分支/源码摘要、测试命令、实际用例/失败/跳过数、关键断言、备份与恢复范围，以及并行修改和未执行项目；保持 S0～S5 状态与实际证据一致。
- [x] P0 交付前检查全部八项 AC-P0 有所属测试与证据，review 实际 diff、敏感字段和精确变更范围；不因此自动提交或发布。
- [x] 按实际行为同步 `docs/architecture/audiobook-workshop.md`、`docs/developers/macos-app-audiobook.md`、`docs/users/audiobook-workshop.md` 和 `docs/developers/audiobook-workshop-testing-handover.md`；开发文档目录说明随语义更新，不改根 README 或归档来制造当前承诺。
- [x] 规格与现有 AC1～AC10 逐项迁移追踪；新回归不得继续断言 clone 种子互异、未知声音随意分类或资源不足仍强制全部绑定。
- [x] 文档检查只覆盖实际改动；所有计划命令使用原生命令。完整 gate、安装/运行态、真实质量与 UI 验收按各自当前授权执行。

## 10. 回退总则与恢复演练

| 触发条件 | 允许的回退 | 必须保留/核对 |
| :--- | :--- | :--- |
| S1/S2 参数或分配实现回归 | 停用可选控制/自动批量；保留 P0 候选、严格请求与手动合法绑定 | 原工作区、已确认绑定、音频和版本；不退回宽松隔离 |
| S3 场景算法质量或成本回归 | 同一 schema 下 `sceneAware → baseline` | 人工锁定、有效版本与局部失效；不降级数据 |
| S1/S3/S4 迁移准备或临时副本校验失败 | 不执行真实迁移；修复后重新演练 | 旧副本、失败证据及全部未知记录 |
| 迁移后出现故障且已有新作品/编辑 | 使用可读新 schema 的安全实现修复；暂停新写入并保留数据 | 不用旧快照覆盖新增状态；必要时只读恢复/导出 |
| 目录或注册返回中断 | 恢复单个 intent；关闭新增动作直至恢复 | 不删音色、不晋升未知资产、不覆盖作品库 |
| 微语速/听评未通过 | 默认关闭该实验控制，保留基础速度与试听 | 已生成作品、冻结试验和失败结果；参数修正重新确认 |

恢复演练必须至少证明：旧音频与采用版本可读、当前合法绑定可恢复、新增作品不丢失、P0 守卫仍有效。正式 App 安装/回滚须另按 release skill 和当前用户授权精确定位；本计划不提供全局重置、模糊进程终止或覆盖式恢复命令。
