# SpeechRail App 性能治理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking. 使用当前环境实际提供的技能名；默认串行实施。仅在用户或适用规则明确要求委派时使用 luna_worker，并划定文件所有权。

**Goal:** 消除 App 公共路径中的同步 I/O、重复全量处理与逐字节调度，使音频、导出、波形和长会话具备可验证的资源与生命周期上限。

**Architecture:** MainActor 只持有轻量界面状态；存储 actor 管理文件与事务，独占 worker 生成不可变读模型。音频逐层限流并显式报告断裂，所有任务由功能 owner 收束；性能与正确性分别验收。

**Tech Stack:** Swift 6、macOS 26+、arm64、SwiftUI/Observation、Swift Concurrency、AVFoundation/CoreAudio、NSXPC、SQLite；保留当前 MacPaw/OpenAI 0.5.1 固定版本，服务侧 Python >=3.14,<3.15。

**Spec:** [SpeechRail App 性能与资源治理设计](../specs/2026-10-16-app-performance-design.md)

**Status:** A 层代码与确定性集成完成；B/C 层实际性能与交互待验收；2026-10-16；源码基线 bedabb6a93669144c12a4e8dba6c5305f4503128，实现整理为 80173005、7f32582b 两个逻辑提交，随当前分支 PR 交付。勾选表示对应步骤已有证据；条件步骤不扩大授权。执行记录见本文末尾及[验收记录](../../audits/2026-10-16-app-performance-acceptance.md)。

## Global Constraints

- MainActor 不执行本方案移出的文件读取、JSON、fsync、全库统计与 PCM 拼装；Task/yield 不算执行域迁移。
- 保留既有磁盘 schema、未知字段、事务恢复、保存回执与完整档案；内部 Swift async 接口可同步迁移，不维护无需求的兼容 alias。
- 一个 SpeechRail 服务、一个 ASGI worker、一个共享 ASR worker；本方案不改模型、档位、Governor 或公共 Realtime wire。
- 会话采集 PCM 不落盘；创作的 TTS 作品与用户导出沿用既有文件保存流程。导出和波形测试仅用临时目录中的合成音频。不得引入原始音频、prompt、转写或敏感路径日志。
- mutable preview 可合并；final、failed、receipt、barrier 和输入断裂必须可靠交付。过期结果按记录、generation、revision 拒绝发布。
- 音频容量与 750 ms 年龄上限、LLM 128 events/256 KiB、波形 1 active/8 queued/64 cached/256 KiB、PCM 导出 256 KiB 工作块按 Spec 执行；调整前记录基线和理由。
- 确定性测试使用 fake、合成事件和手动时钟；不以 CPU 或墙钟速度作 CI 正确性断言。真实性能验收、UI 自动化、服务操作分别需要对应授权。
- 新生产文件登记 Package.swift 显式 sources 及 Xcode target；新测试登记 Xcode Unit Test Sources。不得通过 coverage allowlist 跳过 App/SwiftPM 双入口验证。
- 每个任务是独立逻辑变更；不自动 commit、push、发布或安装。并行计划触及同一文件时串行整合，不回退他人修改。

## Review Focus

1. 外部原子替换、同大小文件变化与损坏目录：必须刷新或明确失败，不能继续拿旧许可生产。T01 的 externalReplace/corrupt 测试固定此行为。
2. 快速切书/切章/换版本与迟到结果：旧结果不得覆盖新选择，最终刷新不得被进度合并吞掉。T02/T09 的 generation 与 finalRefresh 测试负责。
3. 取消恰逢事务提交、磁盘满或导出覆盖：已有数据保持可恢复，已提交结果有真实回执。T03/T04 的 cancelAtCommit、diskFull、destinationUnchanged 测试负责。
4. 慢消费者、网络永久停顿、helper 无 ack 与时钟跳跃：资源有界，终止可交付，输入残缺不能成为完整回答。T05/T06 的 stalledRead、overflow、noAck、lateTick 测试负责。
5. 4 h 历史、迟到归属与用户回看/复制：完整历史保留，可见投影有限，用户位置和复制范围正确。T10 的 lateAttribution、pageAnchor、copyRange 测试负责。

## 任务依赖、文件所有权与验证入口

推荐顺序：T00 → T01 → T02 → T03 → T05 → T06 → T07 → T04 → T08 → T09 → T10 → T11 → T12 → T13。T04 依赖 T03，T07 依赖 T06，T11 依赖 T04 的文件身份/lease；T08 与 T10 在 MeetingView 的改动串行。

~~~mermaid
flowchart LR
  T00 --> T01 --> T02
  T00 --> T03 --> T04 --> T11
  T00 --> T05
  T00 --> T06 --> T07
  T01 --> T08
  T02 --> T08
  T00 --> T09
  T06 --> T10
  T08 --> T10
  T00 --> T12
  T02 --> T13
  T04 --> T13
  T05 --> T13
  T07 --> T13
  T09 --> T13
  T10 --> T13
  T11 --> T13
  T12 --> T13
~~~

以下 Files 路径均相对仓库根。每个任务列出的既有测试要在迁移接口后继续通过；新增测试名是预期交付项，不表示现在已经存在。公共注册文件 macos/SpeechRailApp/Package.swift / macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj 由当前唯一实施者串行编辑。新增 Swift 文件以单一职责为限，不因本计划预先建立空框架。

所有 Swift 定向命令使用如下形式，任务中给出具体 filter；运行目录为仓库根。RED 表示新断言真实暴露旧行为，或新接口尚未实现导致编译失败；GREEN 必须同时检查断言与用例数量，不能仅看退出码。

~~~bash
swift test --package-path macos/SpeechRailApp --enable-swift-testing --filter SpecificTests
python3 scripts/check_macos_test_target_coverage.py
git diff --check
~~~

真实基准授权之前，T00/T12/T13 只交付观测能力、fake 验证与待测表，不运行真实音频/模型或占用前台。若 SwiftPM 需下载缺失依赖，先报告依赖状态，不把联网同步混入性能数据。

## T00 / P0：最小观测与改前证据

**Files:** Create macos/SpeechRailApp/SpeechRailApp/AppPerformanceMetrics.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/AppPerformanceMetricsTests.swift；Create docs/developers/macos-app-performance.md。粗粒度调用点随各责任任务接入，不在此任务批量改业务文件。

**Interfaces:** 新增 AppPerformanceOperation 枚举，值为 catalogRefresh、workspaceRead、workspaceProject、storeCommit、dubbingExport、llmEvent、captureEnqueue、mixerTick、captureStop、teleprompterPrepare、teleprompterMatch、transcriptPublish、waveformScan。AppPerformanceSample: Sendable 包含 operation、durationNanoseconds: UInt64、bytes: Int、count: Int、outcome（success/cancelled/failed）。AppPerformanceSink: Sendable 只暴露 record(_ sample: AppPerformanceSample)；生产实现用 OSSignposter 与固定桶计数，测试实现统计次数。队列峰值与在途计数由各 owner 暴露到快照，不创建全局逐帧采样器。

- [x] **1. RED 测试：** AppPerformanceMetricsTests.testMetricsStorageRemainsBoundedAfterMillionSamples、testMetricsContainOnlyNumericOperationData。固定 histogram 桶数量，输入任意重复 sample 不增加容器长度；公开 sample 类型没有字符串正文或路径字段。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter AppPerformanceMetricsTests；确认缺失实现或容量断言失败。
- [x] **3. 实施：** 实现轻量 sink 与启用检查；未开启 signpost 时不创建任务、日志或 timer。文档列出 Spec 场景、单位、Release 构建、预热、前后同条件及匿名汇总格式。
- [x] **4. GREEN：** 重跑上述 filter 与注册检查；用例断言记录次数与固定占用，不断言纳秒速度。
- [x] **5. 证据出口：** 整理待测 baseline 表，按 App/helper/service/worker 分 PID、构建和输入规模；若未来用户已授权性能测量，再先读取 speechrail-perf-benchmark 技能执行对应范围。未获授权的表格填“未测”，不使用估计数冒充基线。

完成条件：新增观测本身没有无界内存或常驻工作；后续任务能取得改前/改后同口径计数。

## T01 / P0：VoiceCatalog 内存读模型

**Files:** Modify macos/SpeechRailApp/SpeechRailApp/AudiobookDomain.swift、AudiobookWorkflowModel.swift、AudiobookBookWorkspaceView.swift、CreatorSurfaceViews.swift、VoiceCloneView.swift、AudiobookCastController.swift、AudiobookProductionController.swift、AudiobookDependencies.swift、AudiobookProductionWiring.swift（上述省略目录的文件均位于 macos/SpeechRailApp/SpeechRailApp/）；Create macos/SpeechRailApp/SpeechRailApp/VoiceCatalogModel.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/VoiceCatalogPerformanceTests.swift；更新 AudiobookCastTests.swift、AudiobookProductionTests.swift、AudiobookStoreTests.swift、AudiobookWorkflowTests.swift、ServiceContractTests.swift 中真实调用受影响的部分。

**Interfaces:** VoiceCatalogStore 成为 actor，新增 refresh() -> VoiceCatalogSnapshot；已有 set/register/promote/archive/unarchive/toggle/create/add 方法保留参数与结果，跨 actor 调用改为 try await。VoiceCatalogSnapshot.revision: String 改为构造时保存的摘要；VoiceCatalogLoadState 增加 loading。MainActor VoiceCatalogModel 持有 snapshot: VoiceCatalogSnapshot，提供 refresh() async 与 requireFreshSnapshot() async throws -> VoiceCatalogSnapshot；后者仅在 ready/missing 且本次刷新成功时返回。

- [x] **1. RED 测试：** testThousandMetadataReadsDoNotReadOrDecodeFile；testRevisionIsBuiltOncePerSnapshot；testExternalAtomicReplaceWithSameSizeInvalidates；testCorruptFileIsNotEmptyReady；testCommitFailureDoesNotPublish；testMutationRetainsUnknownFieldsAndOwnership。通过文件操作 spy、显式刷新和可控 watcher 事件断言，不依赖真实文件事件时序或 sleep。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter 'VoiceCatalogPerformanceTests|AudiobookCastTests'。旧实现对重复 snapshot 的 read/decode 计数应失败。
- [x] **3. 实施：** actor init 不读盘；将现有 reload/mutate 迁移到 actor。Model 只发布整份内存快照，所有行与列表投影先捕获同一 snapshot；删除逐行 store 查询。保留缺失/损坏/不支持 schema 的区别。父目录事件 50 ms 合并，1 在途 + dirty；model 生命周期结束取消 watcher。mutate 每次重读并保留现有未知字段/迁移备份/原子提交，不扩大跨进程保证。
- [x] **4. 动作 freshness：** 配声锁定、生产、归档读取 requireFreshSnapshot，核对现有 voice/cast/source revision；新增 testStaleCatalogCannotAuthorizeProduction、testWatcherStopsWithOwner。迁移所有编译器识别出的 store 调用者，不增加同步兼容 facade。
- [x] **5. GREEN：** 重跑 RED filter，并定向运行 AudiobookProductionTests、AudiobookStoreTests、AudiobookWorkflowTests、ServiceContractTests 的受影响用例；检查注册与 diff。UI body 读次数增量必须为 0，真正 refresh/write 的计数另列。

完成条件：音色表格求值不访问文件，失败不扩大可用音色范围，关键动作仍校验新鲜状态。

## T02 / P0：有声书一致读入与后台投影

**Files:** Modify macos/SpeechRailApp/SpeechRailApp/AudiobookProjectStore.swift、AudiobookCastRegistry.swift、AudiobookWorkflowModel.swift、WorkspaceComponents.swift；Create macos/SpeechRailApp/SpeechRailApp/AudiobookWorkspaceReader.swift、AudiobookWorkspaceProjection.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookWorkspacePerformanceTests.swift；更新 AudiobookWorkflowTests.swift、AudiobookCastTests.swift。

**Interfaces:** 迁出已有 AudiobookBookWorkspaceSnapshot / AudiobookChapterDetailsSnapshot 到 Projection 文件，保持原字段含义并取消 private 文件作用域。新增 AudiobookWorkspaceRequest: Sendable（bookID: UUID、chapterID: UUID?、preferredFragmentID: UUID?、selectionGeneration: UInt64），AudiobookWorkspaceRevision: Equatable, Sendable（sourceSHA: String、contentDigest: String）。AudiobookProjectStore.loadWorkspaceInput(bookID: UUID, chapterID: UUID?) throws -> AudiobookWorkspaceInput 在一个 SQLite 读事务内取得必要领域值；candidates 查询限定到该章 fragment。AudiobookWorkspaceReader.load(_ request: AudiobookWorkspaceRequest) async throws -> AudiobookWorkspaceResult 返回 request、revision 和上述两个 snapshot。Input/Result 是冻结的 Sendable 结构，不含连接、workflow 或可变句柄。

- [x] **1. RED 测试：** testRoleStatsVisitAnnotationsAndEdgesOnce（operation count 随 A/E 增长，等价旧算法）；testChapterLoadDoesNotFetchOtherChapterCandidates；testLatestSelectionWinsAfterSlowProjection；testProgressCoalescesButFinalAlwaysRefreshes；testSameCompletedCountWithNewRevisionReloads。用受控 gate 阻塞旧请求后先完成新选择，确认旧内容与错误都不能发布。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter 'AudiobookWorkspacePerformanceTests|AudiobookWorkflowTests|AudiobookCastTests'。
- [x] **3. 实施统计与查询：** annotation 按 role 聚合，edge 建 adjacency，range 合并只处理命中范围；与参考输出逐字段比对。store 内完成一致读取，candidate 在 SQL/存储层按 chapter/fragment 限定。复用 sourceIndex，避免 UI 规范化正文。若 SQLite 参数数目受限，按固定 500 IDs 分批且保持同一读事务。
- [x] **4. 实施快照一致性：** 声线恢复沿用已有 once-per-book 规则。resumePlan/readiness 需要其他 controller 时，将其计算安排在 store 读事务之外，前后核对 content revision；变化最多重试一次，再变则返回 staleInput 并由 owner 请求下一次刷新，不能无限重试。MainActor 只校验 request/revision 并发布；现有 SpeechRailSelectionLoad 的取消/代次防护继续保留。
- [x] **5. 实施请求合并与缓存：** 每个选择域 1 read + dirty；选中章相关 revision 改变才读详情，保留 250 ms 轻量生产进度；final/failed/stop 单独可靠请求。缓存仅当前书 + 当前/上一章详情，换书释放；新增 testCacheEvictsOldBookAndThirdChapter、testCancellationStopsProjectionBatches。
- [x] **6. GREEN：** 重跑上述 filter，检查 10 倍规模时计数增长为近线性；确认不存在 production polling 每 tick 直接重建工作区。注册检查通过，既有选择回归继续通过。

完成条件：统计/投影不占 MainActor；章节读取不随全书 candidate 增长；同代次最终状态一定可见。

## T03 / P0：CreativeWorkStore 与 DubbingProjectStore actor 迁移

**Files:** Modify macos/SpeechRailApp/SpeechRailApp/CreativeWorkStore.swift、DubbingProjectStore.swift、DubbingWorkflowModel.swift、CreatorSurfaceViews.swift；Create macos/SpeechRailApp/SpeechRailApp/StoreCommitReceipt.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/CreativeWorkStoreTests.swift、DubbingProjectStoreTests.swift；Create macos/SpeechRailApp/SpeechRailMacControlTests/CreativeStoreConcurrencyTests.swift。

**Interfaces:** 两个 store 改为 actor，读方法保留领域参数和结果；写方法增加 operationID: UUID，原领域结果包装为 StoreWriteResult<Value: Sendable>（value: Value、receipt: StoreCommitReceipt）。例如 CreativeWorkStore.save(_ work: CreativeWork, audioData: Data, operationID: UUID) throws -> StoreWriteResult<CreativeWork>；其他 save/rename/delete/adopt/undo 按原返回类型同样包装，原 Void 对应 Value == Void。init 只配置路径；workflow 新增 loadLibrary() async，用操作 ID 发布列表。CreativeWorkFileOperations 留在 actor 内，注入 interceptor 改为 @Sendable；测试 probe 用有锁对象。StoreCommitReceipt: Sendable 包含 operationID: UUID、committed: Bool、indexDigest: String；actor 最近 64 个 receipt 以固定 ring 保存，receipt(operationID: UUID) -> StoreCommitReceipt? 仅供本进程查询。UI 不以 Task.isCancelled 推断提交结果；重启后仍由既有 journal/index 判断状态，不新建落盘操作账本。

- [x] **1. RED 测试：** testSlowFilesystemDoesNotBlockMainActor（文件操作 spy 若仍在主线程则立即记录失败并抛注入错误，避免旧实现的 RED 测试锁死；迁移后在后台 gate 阻塞期间 MainActor 独立任务能运行，再显式放行，不用耗时阈值）；testConcurrentWritesRemainSerialized；testCancelAtCommitReturnsActualReceipt；testInjectedDiskFailurePreservesRecoverableIndex。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter 'CreativeStoreConcurrencyTests|CreativeWorkStoreTests|DubbingProjectStoreTests'。
- [x] **3. 实施：** 移除 store 的 @MainActor，actor 独占 FileManager、锁、journal。存储锁内无外部 await，按原提交点决定成功；传入 operation ID，保存结果可由 workflow 获取。UI 在收到 receipt 后刷新，不在 init 或 body 同步 list。测试闭包/句柄遵守 Sendable，不新加 unchecked 声明。
- [x] **4. 取消策略：** 进入 actor 时先检查取消；一旦接受并进入同步事务，不再因调用方取消中断 durable commit，直至成功或可恢复失败，写锁内没有 await。Swift Task 取消不会自动终止同步 actor 方法；调用方仍取得真实结果，但页面 generation 可以拒绝旧页面更新。actor 记录有限 receipt，重开页面从 index 刷新。新增 testCloseViewDoesNotLeaveOrphanCommit、testReceiptHistoryIsBounded，沿用现有恢复与幂等依据，不新建任务队列或落盘 schema。
- [x] **5. GREEN：** 重跑上述 filter，保留旧恢复/哈希/删除/采用关系断言；查清所有调用者完成 async 迁移。定向验证启动列表加载与失败状态，不运行 UI 自动化。

完成条件：存储耗时与主线程解耦；恢复、durability 和用户保存状态没有降级。

## T04 / P1：分块导出与 URL 播放

**Files:** Modify macos/SpeechRailApp/SpeechRailApp/DubbingProjectStore.swift、DubbingWorkflowModel.swift、AudiobookWorkflowModel.swift、SharedPlaybackOwner.swift；Create macos/SpeechRailApp/SpeechRailApp/DubbingExportWriter.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/DubbingExportStreamingTests.swift；更新 DubbingProjectStoreTests.swift。

**Interfaces:** 消费 T03 actor。PreparedDubbingExport: Sendable 包含 leaseID: UUID、audioURL: URL、scriptURL: URL、sourceRevision: String、audioBytes: UInt64、baseName: String。DubbingProjectStore.prepareExport(projectID: String) throws -> PreparedDubbingExport；releaseExport(leaseID: UUID) 显式释放。DubbingExportWriter 是独立 actor，copyPrepared(_ export: PreparedDubbingExport, audioDestination: URL, scriptDestination: URL) async throws -> ExportCopyReceipt；receipt 分别记录每个目标的 committed 状态，避免把两个文件错误描述为文件系统原子事务。播放继续用既有 driver 的 fileURL 入口。

- [x] **1. RED 测试：** testStreamingWAVMatchesReferencePCM；testCopyNeverReadsMoreThan256KiB；testSlowExportCopyDoesNotBlockMainActor；testFormatMismatchAndRIFFOverflowFailBeforePublishing；testCancelLeavesExistingDestinationUnchanged；testOnlyOneExportLease；testMissingCandidateFailsWithoutSilence。RIFF 超限用 fake 文件尺寸，不创建 4 GiB fixture。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter 'DubbingExportStreamingTests|DubbingProjectStoreTests'。
- [x] **3. 实施 prepare：** 冻结项目 revision 与采纳 candidate 顺序，建立 candidateID 字典避免每段线性查找；持有 store 序列化所有权执行 WAV header 验证和分块 PCM 拷贝，流式生成 script 文件。块 ≤256 KiB，一次最多一个打开的源；检查长度溢出并更新 WAV header。异常/取消释放本次临时目录。避免跨 await 持锁或允许 candidate 在导出中途被删。
- [x] **4. 实施保存与播放：** prepare 返回可取消 copy 阶段；MainActor workflow 只拥有一个 copy Task，调用 try await writer.copyPrepared，所有 FileHandle/复制/fsync/替换在 writer actor 内执行。文件操作 spy 若在主线程立即失败；后台 copy gate 阻塞时 MainActor 可继续处理状态。写目标同目录 staging，复制完成后检查取消，再原子替换该文件。音频/脚本各自回执；若第二个失败，明确报告部分保存并保留可重试 lease，不删除第一份真实成功产物。试听与播放使用 URL，清除 MainActor 的整段音频读取；更新旧 DubbingExportBundle/Data API 的消费者和测试，不保留无调用 alias。
- [x] **5. GREEN：** 重跑上述 filter；新增 testFailureOfSecondDestinationReportsPartialSuccess、testReleaseOnCancelAndFailure、testPreviewDoesNotLoadWholeAudioOnMainActor。确定性检查最大 read chunk 与活跃句柄，真实 RSS/120 min 导出留待 T13。

完成条件：长音频不构造完整 PCM Data；文件顺序、格式与样本一致；覆盖、取消和部分保存都有真实状态。

## T05 / P0：LLM 事件计时、传输取消与有限交付

**Files:** Modify macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift、AssistantSession.swift、AudiobookWorkflowModel.swift、TeleprompterPreparationPipeline.swift；Create macos/SpeechRailApp/SpeechRailApp/LLMStreamDelivery.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift、LLMStreamDeliveryTests.swift。后两个业务文件仅迁移实际 stream 消费及 preview pacing，不能改变 prompt、模型或业务流程。

**Interfaces:** LLMProvider.stream 继续返回 AsyncThrowingStream<String, Error>。新增内部 LLMStreamDelivery，init(maxEvents: Int = 128, maxPayloadBytes: Int = 262144)，暴露 stream、yield(_ delta: String) throws、finish(throwing: Error?)；原生 bufferingOldest 限制 128 个 delta，累计 text UTF-8 bytes 限制 256 KiB，yield 的 dropped/terminated 使 owner 立即取消 transport 并以错误结束。累计而非在途字节限制更保守，且现有总文本限制仍保留。新增 StreamDeadlineState，保存 firstProgressDeadline / stallDeadline 与现有进度分类，advance(event:now:) 和 expiry(now:) 为纯状态决策；transport/deadline task 由同一个 run owner 收束。

- [x] **1. RED 测试：** 在 LLMProviderTests 加 testDeadlineChecksScaleWithEventsNotBytes、testStalledReadIsCancelledWithoutAnotherByte、testReasoningPreservesExistingProgressSemantics、testEOFMissingTerminalIsFailure；同一 SSE 分成单字节/多字节输入，文本、计时状态转换一致且不按 byte 发 actor 消息。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter 'LLMProviderTests|LLMStreamDeliveryTests'。
- [x] **3. 实施：** byte loop 保留增量 UTF-8/SSE parser，不再 await timer；完整事件后串行更新 deadline，不创建每 delta 的 Task。用独立 deadline waiter 与传输取消句柄保证网络挂住也能结束。截止点先后使用事件接收的单调时间，加入 testEventAtDeadlineHasDeterministicOutcome，不依赖线程调度顺序。
- [x] **4. 有界与 UI：** 新增 testSlowConsumerOverflowPreservesFailure、testEmptyDeltaCannotBypassEventLimit、testOversizedUnterminatedLineFails、testCancellationDoesNotReportCompletion；沿用现有文本上限并落实 parser line/buffer 上限。UI 只用最多 1 份最新全文、50 ms owned timer 合并预览；终态立即 flush，正式输出逐事件保留。若 timer 已存在复用，不为每 token 创建睡眠任务。
- [x] **5. GREEN：** 全部 LLMProviderTests 及 delivery 定向通过，包含 UTF-8 split、多行 SSE、reasoning、finish、非 2xx 与取消分类；统计 timer 唤醒和任务峰值，不能只验证输出文案。

完成条件：读网络的 byte 数不会放大 actor hop；慢消费者有硬上限；超时能结束底层传输且不丢终态。

## T06 / P0：音频通道、XPC credit 与 mixer 生命周期

**Files:** Create macos/SpeechRailApp/SpeechRailApp/AudioChunkStream.swift、StreamMixer.swift、CaptureDeliveryWindow.swift；Modify macos/SpeechRailApp/SpeechRailApp/MicrophoneCapture.swift、AssistantAudioSession.swift、AudioSourceCoordinator.swift、CaptureHelperClient.swift、CaptureHelperProtocol.swift、CoreAudioTapCapture.swift、AssistantSession.swift、AssistantSessionDependencies.swift、MeetingSession.swift、MeetingSessionDependencies.swift、MeetingSessionProductionWiring.swift、CaptionSession.swift、TeleprompterSession.swift；Modify macos/SpeechRailApp/SpeechRailCaptureHelper/main.swift。Test 新增 AudioChunkStreamTests.swift、StreamMixerTests.swift、CaptureDeliveryWindowTests.swift；更新 AudioChunkSource 的所有 fake 与四场景生命周期测试。

**Interfaces:** AudioChunkSource.start() async throws -> AudioChunkStream、stop() async；所有显式 owner await stop 完成。AudioChunkStream: AsyncSequence & Sendable 的 Element 为 AudioChunk，Iterator.next() async throws -> AudioChunk?；生产侧 offer(_ chunk: AudioChunk) -> AudioOfferResult（accepted/closed/overflow），finish(_ reason: AudioStreamTermination)。AudioStreamTermination 为 completed/cancelled/overflow/staleInput/sourceLost/droppedSamples，错误携带 epoch、sourceID 与数值缺口，不含 PCM。新增 AudioCaptureStamp（Spec 所列字段）与 source watermarks；原有可选证据字段仍保留，nil 只表示未知。

CaptureDeliveryWindow 使用 begin(epoch: UUID)、offer(sequence: UInt64, bytes: Int) -> Bool、acknowledge(epoch: UUID, throughSequence: UInt64)、stop()，最多 4 chunks/7,680 B。XPC deliver 参数为 pcm: Data、level: Double、epoch: String、sourceID: String、sequence: UInt64、capturedUptimeNanoseconds: UInt64、droppedSamplesBefore: UInt64；新增 acknowledge(epoch: String, throughSequence: UInt64)。字符串 UUID 在边界校验，负值/溢出/越权 ack 明确失败。StreamMixer 的 source key 为 UUID，start() -> AudioChunkStream、attach(sourceID: UUID, stream: AudioChunkStream) throws、retire(sourceID: UUID) async、stop() async；时钟可注入，快照含活动 slots、在途 tasks、queued bytes、gaps。

- [x] **1. RED 通道：** AudioChunkStreamTests.testOverflowTerminatesOutOfBandWithoutSilentDrop、testOldEpochCannotPublish、testGatePreservesAllSourceEvidence、testChunkAgeOver750msFails、testUnknownSequenceIsNotClaimedContinuous。慢消费者从不 next 时 offer 达到 bytes/count 任一上限即失败，后续 next 收到明确错误，不无限 drain 陈旧队列。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter 'AudioChunkStreamTests|StreamMixerTests|CaptureDeliveryWindowTests'。
- [x] **3. 实施通道与上游：** 按 Spec 每层 byte/count 容量配置，gate/watch 拉取式转换不加队列。错误独立存储并释放 pending PCM；真实 source 全部携带 epoch/sequence/drop，mix 输出保留每源水位。AudioChunkSource stop 改为等待清理；deinit 只能调用具体类的同步 requestStop 安全开关，不能替代正常 owner 的 await stop。更新所有 fake，包括 ASRProductionSessionReplaySupport、AssistantDrain/EndRouting、Meeting/Caption/Teleprompter 生命周期支持。
- [x] **4. XPC：** deliver 增元数据和 credit，dequeue 才 ack；helper 无 credit 停发送，ack 事件唤醒，有在途数据时 1 s 无有效 ack 终止。新增 testFourInFlightBlocksFifthUntilDequeued、testOldEpochAckDoesNotReleaseNewCredits、testAckBeyondSentSequenceFails、testNoAckTerminatesAndReleasesCapture、testNoInFlightAudioDoesNotStartAckTimeout。纯 policy + fake protocol 测试证明 App/helper 不用额外队列绕过 credit；共享新文件同时登记到 helper 与 App target，校验 NSXPCInterface 类型配置。
- [x] **5. Mixer：** 提取真实 actor 到 StreamMixer.swift，移除 Coordinator 内旧实现，有限 slot 表 + ring cursors，退休回收 task。单次 tick 批量填 PCM，保留饱和求和。新增 testHundredReconnectsKeepTwoSlots、testLateTickDoesNotReplayMissedDeadlines、testNoSourceDoesNotEmitSyntheticSilence、testMixedPCMMatchesReference、testStopJoinsTickerIngestAndObserver。手动推进 30 s 后仅处理一个当前 tick，不循环 750 次。
- [x] **6. 四场景终止：** Assistant/Meeting/Caption/正式提词与试读统一映射 overflow/stale/drop 为不完整输入，停止 append、执行既有受限 draining、保留真实已保存内容，不生成完整意图回复。新增 testInputDiscontinuityNeverTriggersAssistantAnswer、testDrainStillAcceptsMatchingFinalAndReceipt、testSourceLostPreservesExistingRecovery。sourceLost 是已知中断，不一概转换成不可恢复失败。
- [x] **7. GREEN：** 重跑上述 filter 与 AssistantDrainTests、AssistantSessionTests、MeetingSessionLifecycleTests、CaptionSessionLifecycleTests、TeleprompterSessionLifecycleTests 的受影响用例；按 Spec 容量表计算峰值（双路排队 PCM ≤137,280 B，其他固定区单列）。stop 后 active/task/queued 计数回到 0。真实 XPC/capture 启动与硬件压力留待授权验收，不能用 policy 单测假称通过。

完成条件：全链路积压可计算，错误不丢、stop 可等待、重连不增 slot；App/helper 同步升级与回退。

## T07 / P1：麦克风实时回调移出转换与分配

**Files:** Modify macos/SpeechRailApp/SpeechRailApp/MicrophoneCapture.swift、AssistantAudioSession.swift、AudioSampleRing.swift；Create macos/SpeechRailApp/SpeechRailApp/AudioCaptureDrain.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/AudioCaptureDrainTests.swift；更新 AudioSampleRingTests.swift。

**Interfaces:** 消费 T06 AudioChunkStream/AudioCaptureStamp。AudioCaptureDrain 由 source 唯一拥有，start 配置输入格式与 ring 容量，requestStop() 同步停止接收，stop() async 等待 drain 完成；固定 scratch/converter 只在 drain 域访问。Source 样本位置与 drop 数以累计水位传递，capture uptime 在 tap 时记录，不在 drain 时伪造为刚采集。

- [x] **1. RED 测试：** testTapOnlyCopiesIntoPreallocatedRing（注入 converter spy，回调路径调用数为 0）；testOverflowAdvancesDroppedSampleWatermark；testConvertedSampleTimelineMatchesReference；testStopWaitsForInFlightDrain；testFormatChangeRetiresOldEpoch。用合成 Float 样本与手动 callback gate，不访问真实麦克风。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter 'AudioCaptureDrainTests|AudioSampleRingTests'。
- [x] **3. 实施：** 复用已有 AudioEngineSession ring/drain 能力，但不合并 voice processing 与通用麦克风业务。tap 去除 converter、Data、AVAudioPCMBuffer 分配和 Task；drain 重用 scratch 并发出有限 PCM。发生格式变化先关闭旧 epoch，再重建，不能在回调扩容。
- [x] **4. GREEN：** 上述 filter 通过，并重跑 T06 的 source/stop 回归；每种输入格式统计 ring/scratch 容量。实际 callback 分配与耗时必须由 Instruments 证明，单测只证明自有 converter 未在 callback 执行。

完成条件：回调边界明确，时间轴与已有采集证据保留，停止后无 buffer use-after-free。

## T08 / P1：高频 UI 依赖隔离

**Files:** Modify macos/SpeechRailApp/SpeechRailApp/MeetingView.swift、MeetingViewStatusBar.swift、MeetingViewLiveTranscript.swift、AudiobookBookWorkspaceView.swift、AudiobookWorkflowModel.swift；Create macos/SpeechRailApp/SpeechRailApp/SessionActivityIndicators.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/SessionActivityPolicyTests.swift。实施前读取 macos-app-design-system.md 的相关范围。

**Interfaces:** MeetingLevelIndicator 直接读取轻量 level；AudiobookAnalysisElapsedLabel 直接读取 analysis 开始/停止时间与 active/visible 状态。父 View 只持有子 View 所需 owner，不提前读高频属性。若需单独 ActivityState，其 MainActor 模型只含 level/elapsed/active，不包含 transcript 数组；视觉值复用现有 Tokens。

- [x] **1. RED 测试：** testLevelChangesDoNotChangeTranscriptProjectionRevision、testElapsedClockStopsWhenInactiveOrHidden、testReduceMotionKeepsStatusAccessible。测试状态与生命周期，不能据此宣称 SwiftUI body 更新次数已减少。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter SessionActivityPolicyTests。
- [x] **3. 实施：** 移走父级 level/analysisClockTick 读取，按现有 ProductionProgressRail 模式建立局部 TimelineView；显式暂停不可见/非活跃时钟。保留 Assistant waveform 现有暂停与 Reduce Motion 策略，避免平行计时器。保持原 ID、可访问标签、键盘入口和布局。
- [x] **4. GREEN 与审查：** 上述 filter 及相关 progress rail 定向回归通过；静态核对父 body/计算属性没有高频依赖。获准采样后用 SwiftUI Instruments 核对父 body 与长列表 diff 下降；未测之前标记“依赖已收窄、实际更新次数未验证”。

完成条件：高频状态具有独立订阅边界，且没有新增隐藏运行的 timer。

## T09 / P1：提词试读缓存与 anchor 二分

**Files:** Modify macos/SpeechRailApp/SpeechRailApp/TeleprompterAligner.swift、TeleprompterSession.swift、TeleprompterFollowController.swift；Create macos/SpeechRailApp/SpeechRailApp/PreparedTeleprompterScript.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterScriptPerformanceTests.swift；更新 TeleprompterAlignerTests.swift、TeleprompterFollowControllerTests.swift、TeleprompterSessionLifecycleTests.swift。

**Interfaces:** PreparedTeleprompterScript: Sendable（versionID: String、segmentDigest: String、script: TeleprompterAligner.Script）；Script 内建立按 segmentIndex/utf16Offset 排序的 token start offsets。试读与正式跟随在版本变化时 prepare，一次 ASR 更新只调用已有 locate(tokens:script:anchor:)；输入预览、终态与版本校验语义保留。

- [x] **1. RED 测试：** testHundredTrialPreviewsPrepareScriptOnce、testAnchorSearchComparisonsGrowLogarithmically、testIndexedAnchorMatchesLinearReference、testVersionSwitchRejectsOldMatch、testFinalIsNotCoalescedAway。覆盖重复词、空稿、别名、emoji/中英与 anchor 越界。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter 'TeleprompterScriptPerformanceTests|TeleprompterPositionTests|TeleprompterFollowControllerTests|TeleprompterSessionLifecycleTests'。现有 Aligner 文件 suite 为 TeleprompterPositionTests，以实际发现为准。
- [x] **3. 实施：** 共享 prepare key 与冻结 Script，替换试读全稿重建；二分定位 anchor 后保留原 72 token 输入上限及现有前后窗口/DP，别名导致多个 token 共享位置时选第一个满足原比较关系的 token。缓存仅当前版本，切换清除。
- [x] **4. GREEN：** 重跑上述 filter，随机有限语料与参考旧算法逐字段比较 Match；操作计数不随全稿线性增长。仅实测匹配 p95 >5 ms 时另增 matcher actor 任务说明；本任务不预先重构完整跟随流水线。

完成条件：同版本试读不重复 tokenize，anchor 定位近 O(log N)，匹配结果与正式/试读终态行为一致。

## T10 / P1：长会话投影与完整历史分页

**Files:** Modify macos/SpeechRailApp/SpeechRailApp/MeetingSession.swift、CaptionSession.swift、SessionStore.swift、MeetingViewLiveTranscript.swift、CaptionBandWindow.swift；Create macos/SpeechRailApp/SpeechRailApp/TranscriptPresentation.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/TranscriptPresentationTests.swift、TranscriptPagingTests.swift；更新 MeetingSessionLifecycleTests.swift、CaptionSessionLifecycleTests.swift。

**Interfaces:** MainActor TranscriptPresentation.apply(_ line: TranscriptLine)、replace(_ line: TranscriptLine)、requestPage(beforeOrdinal: Int?) async；以 ID 索引和有序 ordinal 存储有限可见投影，暴露 revision 与 scrollAnchorID: String?。SessionStore.linesPage(sessionID: String, beforeOrdinal: Int?, limit: Int = 200) throws -> TranscriptPage；nil 取最新页，非 nil 取更早的行，返回升序 rows 和 nextBeforeOrdinal: Int?。既有完整 lines()/search/导出接口保留供完整范围请求，页面切换不改写数据库。

- [x] **1. RED 索引：** testAppendDoesNotSortWholeHistory、testAttributionUpdatesOnlyMatchingID、testCaptionMetricsStopsAfterVisibleRows；operation spy 检查新增单行不遍历所有已归档行。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter 'TranscriptPresentationTests|TranscriptPagingTests'。
- [x] **3. 实施索引：** 优先交付 ID/ordinal 索引、定点替换与 caption reverse break；乱序 line 做有序插入，重复 item 幂等。只有保存 receipt 后按现有规则进入正式档案，不能为降低数组成本提前宣布保存。
- [x] **4. 分页 RED：** testFourHourEventsKeepPresentationBoundedAndArchiveComplete、testLateAttributionUpdatesOffscreenRecord、testOlderPageArrivalPreservesScrollAnchor、testCopyRangeIncludesOffscreenRows、testNewLineDoesNotStealHistoryPosition。事件通过 synthetic timeline 快进，不真实等待 4 h。
- [x] **5. 实施分页：** tail ≤500，页大小 200、页缓存 ≤3，有限在途 item/保存/归属单元按现有协议上限管理；退休后清除仅用于 live 的 map。SQL 以 session/ordinal 做 keyset 分页，避免 OFFSET；根据当前 schema 验证查询计划，不无证据增新迁移。复制/搜索从 store 请求完整目标范围。与既有原生滚动和未来 mutable revision 设计合并，不换稳定 ID 或缩短可修订区间；若交互无法保留，索引先交付、分页单独评审与提交。
- [x] **6. GREEN：** 上述 filter 与 Meeting/Caption 生命周期定向回归通过；完整存储行数等于正式输入，presentation 最多 500+3×200 去重行及既有有限在途，迟到归属不让缓存增长。UI 滚动、选区与复制实际操作仅在逐次获准后验证，不能用纯模型测试替代。

完成条件：4 h 合成事件不扩大显示与 live 辅助 map，完整档案、保存顺序和用户阅读位置可验证。

## T11 / P1：波形 single-flight、lease 与有限缓存

**Files:** Modify macos/SpeechRailApp/SpeechRailApp/SharedPlaybackOwner.swift、AudioEnvelope.swift；Create macos/SpeechRailApp/SpeechRailApp/WaveformEnvelopeLoader.swift；Test macos/SpeechRailApp/SpeechRailMacControlTests/WaveformEnvelopeLoaderTests.swift。

**Interfaces:** WaveformKey: Hashable, Sendable 包含 assetID: String、revision: String、fileIdentity: String、bucketCount: Int。WaveformEnvelopeLoader.acquire(key: WaveformKey, fileURL: URL) async -> WaveformRequest；WaveformRequest 是 ready(levels:[Double]) / pending(leaseID:UUID) / deferred / failed，release(leaseID: UUID) async。pending 结果经 result(leaseID: UUID) async throws -> [Double] 等待，同 key 共享一个 operation；直接 ready 不需 lease。新增 @concurrent nonisolated func scanWaveformEnvelope(fileURL: URL, buckets: Int) async throws -> [Double]，只接收冻结值，内部沿用 AVAudioFile 分块读取并检查 Task 取消。loader 持有唯一 activeTask: Task<[Double], Error>；创建的 owned task 调用该入口，扫描不占 loader actor，release 能在扫描期间执行。文件身份使用 T04/既有作品元数据中的不可变 identity，不在 MainActor 对完整音频做 hash。

- [x] **1. RED 测试：** testSameKeyHasOnePhysicalScan、testOneActiveAndEightPendingLimit、testLastOwnerReleaseCancelsScan、testReleaseIsHandledWhileScanWorkerIsBlocked、testOldRevisionCannotPopulateNewEntry、testCacheEvictsByBothCountAndBytes。注入受 gate 控制的 reader，断言真正执行次数与峰值。
- [x] **2. 执行 RED：** swift test --package-path macos/SpeechRailApp --filter WaveformEnvelopeLoaderTests。
- [x] **3. 实施：** actor 只维护 pending/owner/LRU 与 activeTask 句柄；owned Task await 显式 @concurrent 扫描入口，不能在 loader actor 同步调用 computeAudioEnvelope。最后 owner release 先标 retiring、cancel worker，再 await 真正结束；await 期间 actor 可重入，但 active slot 直到旧 worker 结束仍保留。完成回调核对 operation ID 与 revision 后再发布/启动下一个。排队溢出返回 deferred，不循环重试；owner 离页、换音频、导出 lease 释放时解除兴趣。
- [x] **4. GREEN：** 重跑 filter，追加 testCancelledTempAudioIsRemoved、testNoOwnersLeavesNoBackgroundTasks；缓存 ≤64 条且 payload ≤256 KiB（levels 的元素内存按 Double 计，容器固定元数据单列），queued ≤8，active ≤1。仅对已持久化的作品/candidate 计算波形；T04 的 PreparedDubbingExport 临时文件仅用于保存，不引入导出临时文件试听流程。删除/替换导致打开失败时明确失败，不缓存空结果为成功。

完成条件：重复请求不重复读文件，功能退出不留下无主波形扫描。

## T12 / P2 条件项：服务侧热点归因

**Files:** 默认只补 docs/developers/macos-app-performance.md 的归因记录。只有实际采样证实时，后续变更候选为 src/speechrail/domain/audio_timeline.py、src/speechrail/application/realtime_asr.py；相关确定性测试 tests/test_audio_timeline.py、tests/test_realtime_asr_timing.py、tests/test_realtime_asr_control.py。不修改 worker 数量或模型选择。

**Interfaces:** 本任务不预先改变 Python 公共接口。条件触发后，以当前 RationalResampler 和 RealtimeAsrOwner 的输入/输出合同形成单独变更说明：必须保留每个 PCM sample 的相位、边界、有效长度与 async 取消后的资源所有权。

- [x] **1. 分流判断：** 有授权且有基线时，分别检查 App/helper/service/worker 的主热线程和服务 event-loop lag；没有授权或采样证据，填“待测，无服务代码改动”，不得凭逐样本 for 推断当前就是满核根因。
- [x] **2. 若命中热点再 RED：** 在已有测试文件加入分块边界随机化、48/44.1→24/16 kHz 连续相位、短帧/末尾 flush 与取消后不提前释放 lane 的回归；保留原实现作为 test-only 参考。
- [x] **3. 条件命令：** uv run --no-sync pytest tests/test_audio_timeline.py tests/test_realtime_asr_timing.py tests/test_realtime_asr_control.py -q；测试为 fake，缺依赖则报告，不隐式 sync/下载模型。
- [x] **4. 条件实施与 GREEN：** 先减少逐样本 Python 开销，确有 event loop 阻塞再迁移到一个受拥有串行执行域；重跑同一命令并做同口径基准。已有 Resource Governor 准入与 turn coordinator 边界必须维持。证据不支持改动时，以“不改服务，记录原因”完成本任务。

完成条件：服务修复由证据触发；未测项明确列出，不能把 App 的 CPU 收益算到推理 worker 上。

## T13 / P0：集成、性能验收与正式文档

**Files:** Modify docs/developers/macos-app-performance.md、docs/developers/README.md、docs/developers/testing-acceptance.md 中实质受影响的说明；按任务更新 macos-app-audiobook.md、macos-app-teleprompter.md、macos-app-development.md 的真实实现约束。Create docs/audits/YYYY-MM-DD-app-performance-acceptance.md（实际验收日期）。不自动更新根 README、版本号或 CHANGELOG。

**Interfaces:** 消费 T00–T12 的计数、回归结果与 Spec 场景矩阵。验收记录每行包含 caseID、build SHA、process role、输入规模、sample duration、warmup、before、after、重复次数、结论、未验证项；数值附单位，匿名制品引用位于仓库外。

- [x] **1. 定向集成：** 重跑接口边界受到影响的定向 suite：catalog→制作、store→导出→播放、LLM→取消、capture→四场景 draining、transcript→分页。先运行注册检查和 diff 检查，不因任务数量多自动扩为完整测试套件。
- [x] **2. App 编译：** 在用户已授权实施/构建的范围内执行 bash scripts/macos_app_build.sh --configuration Debug；不能裸跑产出 App 的 xcodebuild。跨 target 重点检查 CaptureHelperProtocol、新共享文件和 Sendable；编译成功不能证明运行时 XPC 类型或硬件正确。
- [x] **3. 定向 Xcode 单测：** 需要验证 SwiftPM 未覆盖的 App/helper 集成时，使用包装入口，显式过滤相关 suite，例如下列命令；不启动 UI tests，不安装 App。其他边界按实际变更追加 only-testing，不重复完整 gate。

~~~bash
bash scripts/macos_app_build.sh --test-unit --configuration Debug -- -only-testing:SpeechRailAppTests/AudioChunkStreamTests -only-testing:SpeechRailAppTests/StreamMixerTests -only-testing:SpeechRailAppTests/CaptureDeliveryWindowTests
~~~

- [ ] **4. 性能基准授权后：** 按 speechrail-perf-benchmark 的对应入口及 macos-app-performance 手册执行 Spec 场景矩阵，至少 3 次配对比较；先采改前可复现构建，再测改后，不能只对比一份旧日志。CPU、main-thread、RSS、queue depth、任务数、音频 gap 和 cancellation-to-release 都有结论。未获授权不执行，记录“代码回归完成，实际性能未验收”。
- [ ] **5. UI 自动化逐次授权后：** 才检查长会话回看/复制、叶子依赖、Reduce Motion、快速导航及窄窗口；明确占用的窗口与时长。手工操作可由用户配合，记录方式。单元测试不能替代这些交互结论。
- [x] **6. 交付审查：** 对照 F01–F12，每项链接实现、测试与证据；检查没有悬空任务/observer、无界队列、未知 Sendable 绕过、输入残缺伪成功、数据格式迁移或未授权运行态动作。完成代码审查与 verification-before-completion 后再称对应范围完成；所有实际性能目标满足前不得宣称“全面消除单核满载”。
- [x] **7. 回退准备：** 保留原磁盘格式与原事务恢复入口；每个逻辑变更能独立回退，T06 App/helper 成套。记录回退后的 queue、receipt、库可读性验证；实际安装/回滚另走发布 skill 和明确授权，不写删除用户库的指令。

完成条件分层记录：A=确定性行为与集成完成；B=真实性能达标；C=实际交互核验。缺少任何授权对应层保持未验收，不由另一层结果替代。

本次 A 层完成；第 4、5 步的授权条件未满足，保持未勾选，分别属于后续 B、C 层验收。

## 实施前自查与交付清单

- [x] 复核最新 SHA、git status 与同日其他计划的重叠文件；当前基线移动时重定位符号，不机械套用旧行号。
- [x] F01→T01、F02→T02、F03→T03、F04→T04、F05→T05、F06→T06、F07→T07、F08→T08、F09→T09、F10→T10、F11→T11、F12→T12 完整对应，T00/T13 负责观测与闭环。
- [x] T01→T02/T08、T03→T04→T11、T06→T07/T10 的类型与取消语义一致；新 API 不返回不可发送句柄。
- [x] 同步更新 SwiftPM/Xcode 生产 sources、helper 共享 sources 与 Unit Test Sources；执行覆盖检查，避免只有一个入口通过。
- [x] 每项输出列出定向测试数、失败/取消路径、实测/推断、未验证与回退方式。文档命令用原生工具，不复制本机 wrapper 或缓存路径。
- [x] 用户未要求提交、运行态变更、真实基准或 UI 自动化时，不因本计划中的步骤而自行执行。

## 方案可实施性审查记录（2026-10-16）

按 brainstorming 的 builder-check，以只读独立评审检查设计与任务接口。发现并已在文档解决两项执行域歧义：T04 的用户目标复制明确由 DubbingExportWriter actor 承担，新增 MainActor 可继续运行的断言；T11 的扫描使用独立受拥有 @concurrent worker，管理 actor 可处理 release，新增扫描阻塞期间的取消与实际退出断言。修订后复核结论为 nothing important left；其余重点未发现必须先由作者决定的问题。这是方案审查结果，不是实现或性能验收结果。

## 实施证据（2026-10-16）

- T00：固定容量观测、隐私字段和调用者执行域说明已实现；新用例先因缺少类型失败，再 5/5 通过；macOS 测试清单覆盖检查通过。实际 CPU/内存基线仍未测。

- T01：存储 actor、不可变界面快照、目录事件合并和动作 freshness 已实现；12 个新目录回归通过，受影响的 6 个 suite 共 273 个用例通过。未知字段与归属由既有迁移/归属用例覆盖，生产中归档由 AudiobookProductionTests 覆盖。App Debug 包装构建通过；首次构建发现并修正 onChange 中的 async 迁移遗漏。未启动 App，未采真实性能。

- T02：一致读入、后台投影、按章索引查询、统计聚合、有限缓存与读取合并已实现。统计与旧算法逐字段等价，标注/边访问各一遍；新测试覆盖候选 revision、取消、1 执行/1 等待及最终刷新。定向回归先 164/164 通过，后续边界组合 97/97 通过，最终等待回收改动再 3/3 通过；App 包装构建通过（末次小型等待收尾由 SwiftPM 再编译验证）。SQLite 查询复用既有索引，无 schema 变更。实际 CPU 与交互仍未验收。

- T02 补查：SelectionLoadTests 需显式启用 Swift Testing 运行器，单独执行 5/5 通过；未将其计入上述 XCTest 数量。

- T03：作品库与段落项目库已迁移到 actor；初始化不读盘，界面从异步快照读取。写入携带 operation ID、durable commit 回执和最近 64 条固定容量记录，关闭页面仅阻止过期发布。定向 188 个现有 XCTest 与 10 个 Swift Testing 并发用例通过，App 包装构建成功；未执行安装、UI 自动化或真实性能测量。

- T05：LLM 事件交付限制为 128 个待处理 delta 和累计 256 KiB UTF-8，溢出保留错误；逐字节循环不再访问计时 actor，也不再为 delta 创建 Task。独立可重调度计时器负责关闭挂住的传输，reader/waiter 结束前完成回收。助手展示合并到每轮一个 50 ms 定时任务，完整正文仍逐事件保留，取消与终态立即收束。197 个现有用例和 13 个新增用例通过，App 包装构建成功；没有真实网络或 CPU 基准结论。

T06/T07 定向证据：184 个 XCTest 与 122 个 Swift Testing 用例通过，App/helper 联合构建通过。覆盖 bounded stream、credit/最后一条 ACK、100 次重连、延迟 tick、正常尾音、源时间轴与四场景 draining。真实 XPC 往返、硬件释放、callback 分配及 CPU/RSS 尚未实测；构建与纯 policy 测试不替代这些项目。范围内的 AssistantView 输入电平页也已迁移到 throwing stream 与可等待停止。

T04 定向证据：180 个 XCTest 与 8 个 Swift Testing 用例通过；App 包装构建通过。导出块上限 256 KiB、一次一个源句柄、格式/RIFF 预检查、取消、部分保存、单 lease 与共享播放请求失效均有确定性检查。原样本与脚本断言通过 test-only materialization 保留；生产不返回整段音频 Data。120 min 导出 RSS 与实际播放延迟未测。

T08 证据：54 个 XCTest 与 3 个 activity policy 用例通过；App 包装构建通过。父级会议状态与有声书工作区不读取高频电平/时钟，分析 workflow 无周期 Task；局部时间线按可见性/活跃状态暂停。尚未测 SwiftUI body 数、视觉或 VoiceOver；projection revision 隔离以 T10 的索引回归补证，不能把 policy 测试当作渲染计数。状态 accessibilityHint 的后续小改动留在集成构建中复核。

T09 定向证据：170 个 Swift Testing 用例/6 suites 通过，冻结旧 matcher 的 Match 逐字段等价。anchor 使用原有 token.end 谓词以保留别名和边界语义；实际匹配 p95 未测。

T10 定向证据：184 个现有 XCTest 与 12 个 Swift Testing 用例通过；App 包装构建通过。最终合成场景检查另有 11 个 Swift Testing 函数/3 suites 通过，包括两个场景分别快进 4 h 规模、完整保存 2,880 行、显示 500 行和退休 live 索引清零。电平不改变转写投影 revision。滚动锚点、分页与完整范围复制已做模型/存储检查，真实交互及长时性能未测。

T11 定向证据：97 个 XCTest 与 17 个 Swift Testing 函数/2 suites 通过（其中波形 9 个）。容量、single-flight、真实取消退出、版本隔离与合成包络等价均有回归；将队列上限临时改为 9 后测试按预期失败，已恢复。参考录音质量分析复用原解码循环，不再额外扫描。实际 CPU/RSS 未测。

T12 分流：待测，无服务代码改动。无基线或授权采样，条件 RED/实施/同口径基准均不适用；不会从 App 回归推断推理 worker 收益。

T13 集成证据（2026-10-16 19:35 CST）：最终定向 SwiftPM 464 个 XCTest + 260 个 Swift Testing 用例/18 suites，零失败；App/helper Debug 包装构建成功；Xcode 包装定向单测 26 个 XCTest + 93 个 Swift Testing 用例/13 suites，零失败。sources 清单、PBX plist 与 tracked/untracked 差异空白检查通过。没有运行完整测试套件、UI 自动化、真实采样或安装。

新上下文只读审查发现 5 项 Important：播放请求自行失效吞掉错误、保存成功后的清理错误丢失回执、后台投影后的 revision 漏检、共享 UI 导致单测 target 编译失败、迟到 ACK 复活过期窗口。由作者一次集中修复；分别以实际 driver 抛错、清理故障、投影等待期间编辑、同入口编译失败、假时钟迟到 ACK 观察 RED，再通过上述完整定向回归。Minor 留待后续：AVAudioConverter 正常停止时未显式 EOS flush，44.1 kHz 等重采样尾部完整性未验证。详细范围与回退条件见验收记录。
