# 有声书工坊 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: 使用本机已安装的 `executing-plans` 按任务执行；步骤使用 `- [ ]` 跟踪。实施方式须经用户选择。若用户选择委派，只使用 `luna_worker`，明确文件所有权；共享文件串行修改。本计划不要求调用未安装的 `superpowers:subagent-driven-development`。

**Goal:** 在 SpeechRail macOS App 创作区提供将 TXT 原文制作成多角色有声书的完整流程，支持全书分析、角色确认、逐章制作、返修恢复、听书及 M4B／MP3 导出。

**Architecture:** App 增加独立书籍 owner、SQLite 元数据与文件资产库；AI 输出来源标注，合成正文始终从不可变来源提取。片段通过已有固定版本的 REST 配音接口生成；播放沿用唯一共享 owner，媒体编码通过固定 XPC 操作委托 managed CLI。

**Tech Stack:** Swift 6、SwiftUI／Observation、Foundation／CoreFoundation、SQLite3、CryptoKit、AVFoundation、既有 MacPaw/OpenAI `0.5.1`；媒体适配器使用 Python `>=3.14,<3.15` 和 managed FFmpeg，不新增模型或远程服务。

**Spec:** [已确认设计规格](../specs/2026-10-14-audiobook-workshop-design.md)，用户于 2026-10-14 确认“规格符合”。本文件是待评审实施计划，任务尚未执行。

## Global Constraints

- Apple silicon `arm64`、macOS `26.0+`；沿用项目工具链，不添加旧系统或 Intel fallback。
- TXT 忠实原文；支持严格 UTF-8、带 BOM 的 UTF-16 和 GB18030；原始字节与规范正文同时保留。
- 来源范围使用规范正文的 UTF-8 字节半开区间；AI 不能提供替代原文的合成稿。
- 先完成全部窗口分析并确认全书角色声音，再正式制作；未知说话人只阻塞对应章节，不能默认旁白。
- 每角色固定音色与版本；参数按有效能力快照核准。生成默认 `speed=1.0`，不发送逐句情绪 `instructions`。
- 默认一次制作一本书，同一 TTS lane 串行；不新增模型进程、ASGI worker 或服务端书籍编排。
- 元数据与原文、音频均放在仓库外的 App 数据区；不迁移或改写已有配音项目和会话数据库。
- 播放及整本导出以文件和实际采样时序为依据，不把全书音频载入一个 `Data`。
- 整本 M4B 使用 AAC 与真实章节目录；分章节 MP3 明确实际范围。当前成品不得混入失效或缺失片段。
- 复用 App AI 配置及钥匙串；外部正文发送由用户选择的配置决定，文件预览不触发发送。
- 日志只含阶段、数量、耗时和稳定错误；正文、prompt、音频、凭据、作者身份推断和私有绝对路径不进入日志。
- 仅执行定向确定性测试；UI 自动化、真实模型、质量基准、完整 gate、构建安装和发布另按当前授权执行。
- 不自动 commit／push。每个任务完成后保留可审查 diff；用户要求提交时才按一个逻辑主题提交。

## Review Focus

1. **编码与字符边界**：GB18030、合法的 U+FFFD、emoji／组合字符及混合换行不能被替换、截断或错位；T01／T02 的 `testScalarBoundariesAndLiteralReplacementCharacter`、`testStrictEncodingPreview`。
2. **长书与跨窗口身份**：百万字、超长无标点段、嵌套引号和同名人物必须有界处理，未知不能冒充已确认；T05 的 `testMillionCharacterBookUsesBoundedWindows`、`testNestedQuotesAndAliasCollisionRemainReviewable`。
3. **不确定收尾**：取消后音频迟到、同一结果重复提交，以及文件／数据库之间崩溃，不能产生重复采用或伪完成；T03／T08／T09 的事务恢复、代次和幂等用例。
4. **局部修改与版本变化**：改别称保留音频，改归属只影响相关片段，换模型可能影响全书；旧版不能进入当前导出；T07／T09 的失效集合和候选采用用例。
5. **长书导出与文件边界**：300 章、特殊书名、恶意相对路径、取消、磁盘不足及目标被他人修改时，须保留原资产与已有成品；T11／T12 的章节封装、路径和提交用例。

---

## 依据、接入选择与文件组织

> 🧠 **From Hindsight memory (SpeechRail 组件职责与权威边界)** — LLM 编排、播放和应用状态归调用方，服务提供语音能力与准入。已与当前仓库规则及 macOS 状态所有权文档核对，书籍编排保留在 App。

> 🧠 **From Hindsight memory (高 ROI 进化方案全量实施)** — 沿用音频与索引一致、候选采用／撤销及回执追溯的原则；采用新的书籍结构，不复用单配方配音项目作为持久化格式。

> 🧠 **From Hindsight memory (SpeechRail 开发约定与验证方法)** — 使用与变更面匹配的确定性回归，保留未提交改动，不自动提交；历史通过记录不代替当前验证。

2026-10-14 的当前 worktree 源码核对：

| 接入点 | 核对事实与计划选择 |
| --- | --- |
| `LLMProvider.completeJSON`、`SessionPreferences` | 复用结构化调用、模块覆盖和配置解析；增加 `LLMModule.audiobook`，使用 Chat 操作，不新写 LLM transport。 |
| `SpeechRailSpeechRenderClient.createSpeechRender` | 已固定音色／模型 revision、请求 integrity receipt 与输出检查；工坊用短片段 REST 调用。 |
| `domain/job_request.py`、App job client | 持久 speech job 参数没有固定音色／模型 revision；不以其替换正式片段接口，也不扩大公共 jobs 契约。App 从已提交片段恢复，未完成片段重新制作。 |
| `ServiceHTTPTransport` | 当前使用 `session.data(for:)`；为工坊增加可选响应上限及流式读取，不能仅在完整下载后检查大小。 |
| `AudioDigest` | 已能从 WAV 提取 PCM 区间并计算服务端口径摘要；复用摘要算法，另核对格式、帧数和文件摘要。 |
| `SharedPlaybackOwner`、`AudioPlaybackController` | 当前驱动以 `Data` 播放；扩展同一驱动的文件播放、暂停、seek 和 rate，保持唯一 token。 |
| `SessionStoreSQLite` | SQLite 句柄与绑定助手已存在；书籍建立独立 actor 和 schema，不抽取或重构现有会话 store。 |
| `ManagedCommand`、`AgentOperationStore` | helper 已委托 managed Python CLI，已有长操作和取消框架；增加受约束的媒体命令，复用该操作生命周期。 |
| `config/selection.py`、`application/ffmpeg.py` | managed FFmpeg 在 vendor 目录；现有短音频 helper 返回内存 bytes，不能用于长书。增加文件输出 adapter，复用取消与子进程回收原则；不假设已有 ffprobe。 |

图谱登记 root 是另一 checkout，generation 为 `2026-10-13T10:22:47Z`；当前路径覆盖检查为 `outside_project`，只读 profile 无索引创建入口。本计划用当前路径源码补证，执行前须重新核对变更涉及的源码与工作区。

下文路径前缀是精确的仓库相对目录：`App/` = `macos/SpeechRailApp/SpeechRailApp/`；`Kit/` = `macos/SpeechRailApp/SpeechRailControlKit/`；`Agent/` = `macos/SpeechRailApp/SpeechRailControlAgentCore/`；`Tests/` = `macos/SpeechRailApp/SpeechRailMacControlTests/`。

| 新文件／文件组 | 唯一责任 | 任务 |
| --- | --- | --- |
| `App/AudiobookDomain.swift`、`App/AudiobookSourceIndex.swift` | 身份、来源范围、文本 atom 与覆盖校验 | T01 |
| `App/AudiobookTXTImporter.swift`、`App/AudiobookChapterPlanner.swift` | 严格解码预览、章节划分与显式排除 | T02 |
| `App/AudiobookProjectStore.swift`、`App/AudiobookStoreSchema.swift`、`App/AudiobookAssetJournal.swift` | 独立 SQLite、分页查询、文件事务与恢复 | T03 |
| `App/AudiobookAnalysisPolicy.swift`、`App/AudiobookAnalysisPrompts.swift` | 分析预算、schema 与来源标注提示词 | T04 |
| `App/AudiobookAnalysisPipeline.swift`、`App/AudiobookCastRegistry.swift` | 三阶段分析、检查点、全书角色归并 | T05 |
| `App/AudiobookCastController.swift` | 人工归属、声音确认、音色流程往返身份 | T06 |
| `App/AudiobookFragmentPlanner.swift`、`App/AudiobookInvalidation.swift` | 合成片段及语义依赖指纹、失效集合 | T07 |
| `App/AudiobookProductionController.swift`、`App/AudiobookDependencies.swift` | 队列、冻结条件、窄依赖与任务收尾 | T08 |
| `App/AudiobookRevisionController.swift` | 候选采用、撤销、章节版本与恢复投影 | T09 |
| `App/AudiobookListeningController.swift` | 文件序列、书籍进度、返修后的来源恢复 | T10 |
| `src/speechrail/media/manifest.py`、`encoder.py`、`commands.py`、`__init__.py` | 私有媒体清单、流式编码、CLI 协议；不加载 FastAPI／模型 | T11 |
| `Kit/MediaExportTypes.swift`、`App/AudiobookExportController.swift`、`App/AudiobookMediaVerifier.swift` | XPC 媒体 DTO、导出事务、原生媒体探测 | T12 |
| `App/AudiobookWorkflowModel.swift`、`App/AudiobookProductionWiring.swift` | 功能 owner、生产装配；视图不拥有后台任务 | T13 |
| `App/AudiobookWorkshopView.swift`、`AudiobookBookShelfView.swift`、`AudiobookBookWorkspaceView.swift`、`AudiobookListeningView.swift` | 书架、三栏工作台与听书模式 | T13 |

每个 Swift 任务同时在 `macos/SpeechRailApp/Package.swift` 和 `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj` 登记新增实现／测试；App-only 视图和生产接线加入 SwiftPM exclude，不加入测试替身。共享登记文件由当前执行者串行修改。实施修改 pbxproj 时使用已安装的 `xcode-project-setup` 技能。

## 固定接口与实施默认预算

T01 定义以下 `Codable / Equatable / Sendable` 值类型；ID 用 UUID，来源摘要为 SHA-256，文件引用仅使用 owned root 内的相对标识。atom／片段 ID 导入或规划后持久保存，恢复时不重新生成：

| 类型 | 必要字段／语义 |
| --- | --- |
| `AudiobookSourceRange` | `lowerBound: Int64`、`upperBound: Int64`；半开 UTF-8 字节区间，必须落在 scalar 边界 |
| `AudiobookBook`／`AudiobookChapter` | book/source ID、书名、用户作者字段；chapter ID、标题、顺序、sourceRange |
| `AudiobookTextAtom` | atom ID、sourceRange、chapter ID、kind（正文／标题／格式）；atom 只索引原文 |
| `AudiobookCharacter`／`AudiobookVoiceBinding` | 稳定 role ID、别称及证据；voice ID/revision、model revision、允许参数与绑定摘要 |
| `AudiobookAnalysisWindow`／`AudiobookAnnotation` | root/window ID、primary atom IDs、只读 context IDs、策略／配置指纹；角色或显式 unknown、证据、人工确认记录 |
| `AudiobookFragment` | chapter/role ID、连续 sourceRange、局部分配摘要、voice binding 摘要、生成策略及 dependency digest |
| `AudiobookRenderCandidate` | candidate/task/fragment ID、固定代次、相对文件名、文件与 PCM 摘要、帧数／采样率、真实回执及配方；未知服务身份保留 nil |
| `AudiobookProductionRevision`／`AudiobookChapterRevision` | 不可变有序片段—候选引用清单，来源／制作身份；当前采用指针独立保存 |
| `AudiobookBookmark` | book/chapter revision/fragment ID、来源锚点、片段内秒数、rate；不只保存整章秒数 |
| `AudiobookExportRecord` | export ID、制作版本、实际章节／遗漏原因、profile、媒体验证及最终文件摘要 |

辅助 DTO 在使用它的任务内定义：T02 的 `AudiobookImportPreview` 保存原始字节／规范 UTF-8、编码候选、来源摘要和章节，`AudiobookTextEncoding` 定义四种编码；T03 的 `AudiobookBookSummary` 保存书架字段、`AudiobookRecoveryReport` 列出有效／待恢复／未知资产；T04 的 `AudiobookAnalysisConfigSnapshot` 保存非秘密配置与指纹；T07 的 `AudiobookRenderPolicy` 保存切分／合成限额和版本，`AudiobookDependencySnapshot` 保存来源、分配、声音与模型依赖；T09 的 `AudiobookResumePlan` 列出可复用和需重做片段；T12 的 `AudiobookExportProfile` 为 m4b／chapterMP3，`AudiobookPreparedExport` 保存冻结版本、stage 与验证，`AudiobookMediaVerification` 保存 codec、帧数、duration、章节及产物摘要，`AudiobookOverwriteConsent` 保存用户同意覆盖的具体目标身份。所有状态枚举分别表达分析、制作和可听版本，不共用 completed。

下面数值是首版客户端和媒体 adapter 的实施默认值，供本计划评审；不是模型窗口、吞吐或费用承诺。超限明确失败，不静默截断。限额集中声明，禁止散落裸值。

| 范围 | 默认上限／策略 |
| --- | --- |
| TXT | 64 MiB 原始文件，10,000,000 Unicode scalars；预览最多 6,000 scalars |
| 来源 atom | 每 atom 最多 160 scalars，按引号／叙述／标题／换行建立边界；无标点长段也可切分 |
| AI 窗口 | primary 最多 4,000 scalars 且 256 atoms；两侧 context 各 500 scalars；角色摘要最多 4,000 scalars；含 instructions/schema 的完整请求最多 16,000 scalars |
| AI 输出与恢复 | 提取／归并各 4,000 tokens，标注 6,000 tokens，90 秒调用超时；归并每批最多 32 个角色候选；不截断全书角色库 |
| AI 调用预算 | 每个 root window 最多 4 次 `completeJSON`，拆小／结构修复共用计数；现有 provider 每次至多 3 次兼容尝试，外层不得再套无限重试；鉴权／配置错误立即暂停 |
| 合成 | 目标 180、最多 240 scalars／片段；一次在途请求；WAV 响应 8 MiB；暂态／busy 自动恢复最多 3 次，等待可取消，尊重 `Retry-After`，长等待显示暂停 |
| 查询与播放 | store 分页每页最多 100；播放器预载当前及下一片段；rate 0.5…2.0；书签每 5 秒及暂停／切章／离开时保存 |
| 导出 | 输入清单最多 64 MiB；IO chunk 64 KiB；一个导出操作；90 秒无进展超时、2 小时总期限，超限可重试 |
| 编码 profile | 中间片段 PCM16、48 kHz、mono WAV；M4B: AAC 128 kbit/s、MP4 章节轨；MP3: libmp3lame 128 kbit/s；codec 不存在明确拒绝 |

## 任务依赖与阶段交付

| 阶段 | 任务顺序 | 可审查交付 |
| --- | --- | --- |
| M1 来源与准备 | T01 → T02 → T03 → T04 → T05 | 原文保真、独立存储、全书分析及恢复 |
| M2 角色与制作 | T06 → T07 → T08 → T09 | 声音确认、逐章制作、局部返修与重启恢复 |
| M3 听书与导出 | T10；T11 → T12 | 唯一文件播放、书签、可验证媒体出口 |
| M4 App 集成 | T13 → T14 | 完整入口、用户流程、文档和分层验收记录 |

T10 依赖 T09；T11 可在 M1 后独立推进；T12 依赖 T09／T11；T13 集成前面全部接口。同一计划执行者可顺序推进，避免共享播放、ControlKit 和工程登记文件争用。

### T01：来源模型与完整覆盖

**Files:** 创建 `App/AudiobookDomain.swift`、`App/AudiobookSourceIndex.swift`、`Tests/AudiobookSourceTests.swift`。

**Interfaces:** `AudiobookSourceIndex.init(utf8: Data) throws`；`text(in: AudiobookSourceRange) throws -> String`；`validateCoverage(_ ranges: [AudiobookSourceRange], exclusions: [AudiobookSourceRange]) throws`。本地 atom ledger 将原文映射为稳定 ID，后续 AI 选择 atom，应用还原字节范围。

- [ ] 写 `testScalarBoundariesAndLiteralReplacementCharacter`：包含汉字、emoji、组合字符、合法 U+FFFD 和 CRLF；完整提取等于原文，切进 UTF-8 scalar 内抛错。写 `testCoverageRejectsHoleOverlapAndDuplicate`：洞、重叠、重复均拒绝，明确排除范围才允许不朗读。
  核心断言：`XCTAssertEqual(try index.text(in: wholeRange), originalText)`；`XCTAssertThrowsError(try index.validateCoverage(overlappingRanges, exclusions: []))`，fixture 的 wholeRange 由 UTF-8 实际长度产生。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookSourceTests`，确认预期守卫尚不存在而失败。
- [ ] 实现值类型、字节索引及 atom ledger；保留换行和 Unicode 表示，不做 NFC、trim 或“净化”。标题归旁白、格式区间记账，任何字节只有一个归属。
- [ ] 重跑同一命令，全部通过；检查 fixture 不含真实书籍和用户路径。

### T02：严格导入、章节预览与排除

**Files:** 创建 `App/AudiobookTXTImporter.swift`、`App/AudiobookChapterPlanner.swift`、`Tests/AudiobookImportTests.swift`。

**Interfaces:** `prepare(fileURL: URL, encoding: AudiobookTextEncoding?) async throws -> AudiobookImportPreview`；`chapters(source: AudiobookSourceIndex) throws -> [AudiobookChapter]`；`validateChapterEdits(_ chapters: [AudiobookChapter], source: AudiobookSourceIndex) throws`。encoding 为 utf8／utf16LE／utf16BE／gb18030，UTF-16 入口要求对应 BOM；preview 包含候选编码、来源摘要与章节区间。

- [ ] 写 `testStrictEncodingPreview`：合法三类编码可读、坏 UTF-8／孤立 surrogate／奇数 UTF-16 字节拒绝，合法 U+FFFD 保留；歧义须选择编码。写 `testSameFilenameNeverOverwritesSource`、`testNoHeadingProducesWholeTextChapter`、`testChapterEditsAndExclusionsKeepCoverage`，断言超限文件不读入、标题／广告默认保留。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookImportTests`，记录预期失败。
- [ ] 实现受限文件读取、BOM 识别与严格解码；GB18030 经 CoreFoundation 的 IANA 编码解析，检测转换失败，禁止有损替换。预览不调用 AI；重复文件名创建独立 book/source 身份。
- [ ] 实现章节预览修正：边界必须可定位且覆盖全文；调整章节使相关分析窗口失效，来源不变；替换正文建立新 source ID，原版本保留。
- [ ] 重跑定向测试通过，确认 preview 不包含网络副作用。

### T03：独立数据库、资产事务与删除边界

**Files:** 创建三个 store 文件及 `Tests/AudiobookStoreTests.swift`。

**Interfaces:** `actor AudiobookProjectStore`，`init(root: URL) throws`；`importBook(_ preview: AudiobookImportPreview) async throws -> UUID`；`commitCandidate(_ candidate: AudiobookRenderCandidate, wav: Data) async throws`；`recover() async throws -> AudiobookRecoveryReport`；`listBooks(after: UUID?, limit: Int) async throws -> [AudiobookBookSummary]`；`trashBook(id: UUID) async throws`。

- [ ] 写 `testAssetCommitRecoversEveryCrashBoundary`：在 journal、临时 WAV、资产 rename、数据库提交及 journal 完结处注入故障，重开后只出现一个可验证引用。写 `testDiskFullNeverMarksFragmentComplete`、`testMissingOrTamperedAssetNeedsRepair`、`testTrashBookPreservesOriginalExportsAndDubbing`。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookStoreTests`，确认失败。
- [ ] 建立 `Application Support/SpeechRail/audiobooks/`：`library.sqlite3` 与每书 owned 目录；来源分别保存 `original.bin`、`source.utf8`。actor 单写者，WAL、foreign keys、`user_version=1`；未知更高 schema 拒绝，不降级。
- [ ] schema 分别保存 book/source/chapter/character/voice_binding/analysis_window/annotation/fragment/render_candidate/chapter_revision/production_revision/bookmark/export_record/asset_transaction；跨书引用以复合外键约束，排序／分页不加载全书音频或全部候选。
- [ ] 实现 journal → 临时资产校验 → owned rename → SQLite 事务引用 → read-back → journal 完结；重复 candidate ID 同摘要幂等，不同摘要拒绝。未引用的已知临时资产隔离待恢复；未知文件保留。
- [ ] 删除只在用户点选具体书籍后将该书资产移入可恢复废纸篓，并提交可恢复目录记录；不跟随符号链接，不触碰原始导入文件、外部导出或既有库。
- [ ] 重跑定向测试通过。

### T04：AI 模块、固定预算与结构化标注

**Files:** 创建 policy/prompts 与 `Tests/AudiobookAnalysisPromptTests.swift`；修改 `App/LLMProvider.swift`、`App/SessionPreferences.swift`；扩展 `Tests/LLMProviderTests.swift`。

**Interfaces:** `AudiobookAnalysisPolicy` 声明上述限额；`AudiobookAnalysisPrompt` 包含 stage、instructions、input、schema、maxOutputTokens、rootWindowID；`protocol AudiobookAnalysisClient: Sendable { var configurationDigest: String { get }; func complete(_ prompt: AudiobookAnalysisPrompt) async throws -> String }`。

- [ ] 写 `testAudiobookDefaultsToGlobalConfiguration`：未覆盖时沿用全局，覆盖使用已有模块 key scope，缺配置清晰失败，无外部 fallback。写 `testPromptsBoundAllInputsAndOnlyRequestSourceAnnotations`：正文、context、角色摘要、schema／指令总量都计入上限，输出 schema 不含合成改写稿。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter 'AudiobookAnalysisPromptTests|LLMProviderTests'`，确认新增断言失败。
- [ ] 为 `LLMModule.audiobook` 定义用户标题“有声书工坊”、`requiredOperation=.chat`；复用配置 resolver／Keychain。三类 schema：人物证据、候选归并、primary atom 角色标注；输出 atom ID 必须能本地校验。
- [ ] 将书中指令当作待分析文本；prompt 明确禁止执行原文命令，旁白和 context 不作为遗漏正文的理由。记录配置指纹只含端点／model／兼容模式和 scope，不含 key。
- [ ] 重跑同一测试集通过；生产 adapter 的 `completeJSON` 接线归 T13。

### T05：全书分析、角色归并与检查点

**Files:** 创建 pipeline/cast registry 与 `Tests/AudiobookAnalysisTests.swift`；扩展 T03 store 的窗口和角色事务。

**Interfaces:** pipeline 构造注入 T03 store 和 `clientFactory: @Sendable (AudiobookAnalysisConfigSnapshot) async throws -> any AudiobookAnalysisClient`，本任务可独立用 fake factory 测试，不依赖稍后的 App 装配。`AudiobookAnalysisPipeline.run(bookID: UUID, config: AudiobookAnalysisConfigSnapshot) async throws -> AudiobookAnalysisSummary`；`cancel(bookID: UUID) async`。snapshot 为冻结配置身份及 generation，不保存密钥；summary 包含已处理窗口、unknown／冲突数量及完成标志。

- [ ] 写 `testMillionCharacterBookUsesBoundedWindows`：合成百万字输入，fake 捕获每次完整请求，断言不超 policy、每个 primary atom 恰一次，checkpoint 分页保存；不以 wall time 宣称性能。写 `testNestedQuotesAndAliasCollisionRemainReviewable`、`testFailedWindowBlocksWholeBookCompletion`、`testResumeReusesOnlyMatchingCheckpoint`、`testCancelRejectsLateAnalysis`、`testSettingsChangeNeverChangesInFlightProvider`。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookAnalysisTests`，确认预期失败。
- [ ] 实现提取 → 全书归并 → 标注；通过来源／别称索引筛选候选，32 个一批，不把全书角色库塞进 prompt。稳定 role ID 独立于姓名；同名、代词、多层引号与跨窗上下文保留证据／unknown。
- [ ] primary 和只读 context 分开；输出非法 ID、重复、洞、越界均失败。允许合法 unknown，但处理失败不算分析完成。超限输出可拆小，最小窗口 64 scalars；共享 root 调用计数耗尽后暂停，不递归续费。
- [ ] checkpoint 键固定 source hash、策略、窗口、角色版本与配置指纹；取消／配置变更递增 generation。每轮分析由 client factory 一次解析、捕获配置和内存 key，所有窗口使用同一 client，digest 必须匹配 snapshot；改设置先暂停，不在下一窗口偷换 provider。只有全部提取、归并、标注检查点有效才发布全书完成，生成门槛见 T08。
- [ ] 重跑定向测试通过。

### T06：人物确认、配声与音色流程往返

**Files:** 创建 cast controller 与 `Tests/AudiobookCastTests.swift`；在 T03 store 增加确认／撤销记录。

**Interfaces:** `assignRole(bookID: UUID, atomIDs: [UUID], roleID: UUID) async throws`；`bindVoice(bookID: UUID, roleID: UUID, binding: AudiobookVoiceBinding) async throws`；`confirmCast(bookID: UUID, revisionID: UUID) async throws`；`confirmAudition(bookID: UUID, voiceSetDigest: String) async throws`。音色往返使用 `AudiobookVoiceReturnContext(bookID, roleID, castRevisionID, generation)`。

- [ ] 写 `testUnknownBlocksOnlyItsChapterAfterGlobalAnalysis`：全书已分析且声音已确认时，A 章 unknown 阻塞，B 章可制作；未完成全书分析则两章均不可制作。写 `testDesignedVoiceMustBecomeSynthesisReady`、`testVoiceReturnCannotBindToAnotherBook`、`testSharedMinorVoiceRequiresVisibleChoice`。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookCastTests`，确认失败。
- [ ] 实现旁白、已有角色、新角色及人工归属；批量只处理用户选择的 atoms，记录数量和撤销版本。角色合并／拆分展示受影响来源，名称修改不换 ID。
- [ ] 根据有效快照筛选可用声音；design-only／未准入不进入制作。确认旁白与主要角色试听，声音变更撤销对应试听确认；年龄／性别等建议须带原文证据，没有证据就不包装成事实。
- [ ] 实现固定往返上下文；旧 cast／generation 的音色完成只保留到音色库，不改变新书或新角色。重跑测试通过。

### T07：片段切分与精确失效范围

**Files:** 创建 fragment planner/invalidation 与 `Tests/AudiobookInvalidationTests.swift`。

**Interfaces:** `plan(chapter: AudiobookChapter, annotations: [AudiobookAnnotation], bindings: [UUID: AudiobookVoiceBinding], policy: AudiobookRenderPolicy) throws -> [AudiobookFragment]`；`affectedFragments(before: AudiobookDependencySnapshot, after: AudiobookDependencySnapshot) -> Set<UUID>`。

- [ ] 写 `testCoalescingNeverCrossesSpeakerBoundary`：旁白／角色交替不能合并，连续同角色同条件可合并至 240 scalars。写 `testRenameKeepsAudioButRoleVoiceAndModelChangesInvalidatePrecisely`：别称变化集合为空，某句改归属只含该句相关片段，换角色声音含该角色全部片段，模型／全局策略变化含全部受影响片段。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookInvalidationTests`，确认失败。
- [ ] 实现连续来源切分与合并；合成文本用 T01 提取，不用 LLM 返回文字或 UI 编辑草稿。标题旁白、格式记账、明确排除均参与覆盖校验。
- [ ] dependency digest 只含来源及局部语义分配、声音／模型／允许参数／策略；不含显示名、更新时间或全局 annotation UUID。新标注版本允许复用语义未变的候选，不能因一个全局版本号使全书全部失效。
- [ ] 重跑定向测试通过。

### T08：固定条件的制作队列与停止收尾

**Files:** 创建 production controller/dependencies 与 `Tests/AudiobookProductionTests.swift`；修改 `App/SharedPlaybackOwner.swift` 的 creation admission、`Kit/ServiceHTTPTransport.swift`、`Kit/ServiceContractTypes.swift`、`App/ServiceAPIClient.swift`；扩展 `Tests/ServiceContractTests.swift`。

**Interfaces:** `start(bookID: UUID, chapterIDs: [UUID]) async throws`；`pause() async`；`shutdown() async`。依赖为已有 capability/voice/render/receipt 窄接口、T03 store、admission 及可注入 clock；`AudiobookDependencies.makeAnalysisClient` 为按非秘密 snapshot 创建 T04 冻结 client 的异步 factory。`ServiceHTTPTransport.init(session: URLSession, maximumResponseBytes: Int? = nil)`，ServiceAPIClient 的两个生产构造入口传递可选上限；超限使用 `ServiceAPIClientError.responseTooLarge(maximumBytes: Int)` 并同步用户文案。

- [ ] 写 `testFormalRenderRequiresAnalysisCastAuditionAndChapterReadiness`、`testPauseWaitsForInFlightAndRejectsLateCommit`、`testBusyHasFiniteRetryAndNoSilentVoiceChange`：fake 请求数、冻结 pins、generation、lease 与状态均断言。写 `testSpeechBodyStopsAtEightMiB`：流式 fake HTTP 大于上限时取消接收，不能先读完整再报错。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter 'AudiobookProductionTests|ServiceContractTests'`，确认失败。
- [ ] 生成前核准一个原子能力快照；冻结角色绑定／模型 pins、生成策略和所选章节版本。增加 `SpeechCreationAdmission.Owner.audiobook`，每片段有匹配租约；不把 book owner 塞进 EngineModel，也不持有 AppModel。
- [ ] 以 T07 原文和 `speed=1.0` 调用现有 `createSpeechRender`；工坊 client 使用 8 MiB 流式响应上限，校验 WAV／PCM 摘要与真实回执。缺失或不符的追溯结果保留为待核验候选，不能自动标为成品；不伪造 request ID、digest 或配方。
- [ ] 完成只在 T03 commit/read-back 成功后推进。pause 停止新提交、取消当前 client task，等待本地收尾；无法证明服务端停止时保留该事实，后续服从 backend_busy。页切换不取消队列，App 退出停止并保存。
- [ ] 错误按鉴权、冲突、结构、busy／限流、暂态与保存失败分类；自动恢复共享有限计数并尊重 Retry-After，旧响应不释放新租约。重跑定向测试通过。

### T09：候选采用、章节版本与重开恢复

**Files:** 创建 revision controller 与 `Tests/AudiobookRevisionTests.swift`；扩展 T03 store 的候选／版本事务。

**Interfaces:** `adopt(bookID: UUID, candidateID: UUID, expectedRevisionID: UUID) async throws`；`undoAdoption(bookID: UUID, chapterID: UUID) async throws`；`resumePlan(bookID: UUID) async throws -> AudiobookResumePlan`；`currentChapter(bookID: UUID, chapterID: UUID) async throws -> AudiobookChapterRevision?`。

- [ ] 写 `testRepeatedAdoptionAndCrashCannotDuplicateCurrentVersion`、`testRepairNeedsExplicitAdoptionAndUndoRestoresHistory`、`testRestartReusesValidFragmentsAndRetriesInterruptedOne`、`testStaleCandidateCannotCompleteOrExportCurrentBook`；断言当前指针、候选数量、失效集合及所需请求数。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookRevisionTests`，确认失败。
- [ ] 首次合格自动制作可采用；返修保存独立候选，用户试听后采用。SQLite 事务核对 expected revision 和 T07 digest，生成不可变章节清单；全章所有应朗读范围齐全才更新可收听指针。
- [ ] 按 source／依赖摘要恢复；已提交有效结果复用，缺失／损坏／中断片段只列入重做，不重复整章。未知服务端提交不会被虚构为完成或自动合并。
- [ ] 更名保留音频；改归属、声音和全局条件分别按 T07 标记待更新。历史完整版本保留并显式标“之前的版本”；当前整本版本引用的所有章节须自洽。重跑测试通过。

### T10：共享文件播放与收听位置

**Files:** 创建 listening controller 与 `Tests/AudiobookListeningTests.swift`；修改 `App/SharedPlaybackOwner.swift`、`App/AudioPlaybackController.swift`、`Tests/AppModelTests.swift` 的 fake driver。

**Interfaces:** shared driver 增加 `play(fileURL: URL, startAt: TimeInterval, rate: Float) throws`、`pause()`、`resume() throws`、`seek(to: TimeInterval)`、`setRate(_: Float)`；现有 Data 试听保留。target 增加 `audiobook(bookID: UUID, chapterRevisionID: UUID, fragmentID: UUID)`；listening 提供 `play(bookID:chapterID:)`、`skip(seconds:)`、`leaveWorkshop() async`。

- [ ] 写 `testFilePlaybackUsesSingleOwnerAndPreviewKeepsBookmark`：fake 仅收到文件 URL，角色试听撤销旧 token、保存位置，结束后提供显式继续。写 `testSkipFifteenSecondsAcrossFragments`、`testRateNeverChangesRenderSpeed`、`testRepairedChapterResumesAtSourceFragmentStart`、`testLeavingReleasesPlayerAndLateFinishIsIgnored`。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter 'AudiobookListeningTests|AppModelTests'`，确认新增断言失败。
- [ ] 在唯一 AudioPlaybackController 中实现文件 AVAudioPlayer、暂停／恢复／seek／rate；更新 fake 必需能力，不创建第二个可同时播放的 controller。token 在每次获取所有权时固定，迟到进度／完成回调无权改状态。
- [ ] 章节进度由片段实际帧数与 currentTime 构成；只预载当前和下一文件。书签按 policy 及离开时持久化；新版本映射来源，替换片段从起点开始并提示“章节已更新”。
- [ ] 重跑测试通过；设备播放、VoiceOver 实读和实际倍速效果留待专项验收。

### T11：文件媒体编码与受限 CLI

**Files:** 创建 `src/speechrail/media/` 四个文件、`tests/test_media_manifest.py`、`tests/test_media_encoder.py`、`tests/test_media_commands.py`；修改 `src/speechrail/cli.py`。

**Interfaces:** manifest.py 定义 `MediaExportManifest`；encoder.py 定义 `MediaToolchain`（可信 ffmpeg 路径与 encoder 集合）、`MediaProcessRunner`（固定 argv 启动、progress／cancel／wait 的可替换协议）和 `MediaExportResult`（request ID、相对产物、帧数、profile、摘要）。`load_manifest(app_home: Path, request_id: UUID) -> MediaExportManifest`；`async encode(manifest: MediaExportManifest, tools: MediaToolchain, runner: MediaProcessRunner) -> MediaExportResult`。CLI: `speechrail media capabilities --app-home <path> --json`、`speechrail media export --request-id <uuid> --app-home <path> --json`；JSON 与 T12 DTO 使用相同 schema 和稳定错误。

- [ ] 写 `test_manifest_rejects_traversal_symlink_and_unowned_inputs`、`test_encode_300_chapters_uses_chapter_track`、`test_encode_streams_and_counts_real_frames`、`test_cancel_timeout_or_disk_full_reaps_child_and_keeps_original`、`test_missing_codec_never_downloads_tool`。fake runner 断言 argv、64 KiB 读写、输出范围及 kill／wait，而非只断言成功码。
- [ ] 运行 `uv run --no-sync pytest tests/test_media_manifest.py tests/test_media_encoder.py tests/test_media_commands.py -q`，确认失败；依赖缺失时报告，不擅自下载。
- [ ] schema `audiobook_media_export_v1` 保存 source/production revision、ordered chapter/fragment、输入相对路径与摘要、profile；只读取 `audiobooks/exports/<request-id>/request.json`，输入须是该书 owned 资产，输出仅写本请求 stage。拒绝 URL、绝对输入、路径逃逸／符号链接和 shell 参数注入。
- [ ] 使用当前 managed vendor FFmpeg，检查 AAC／libmp3lame；缺工具或 codec 返回稳定错误。固定 argv，不 shell；大文件输出落盘，stdout 只用于有界 progress，stderr 脱敏且限量。
- [ ] 逐片段转为统一小 WAV 并记录实际帧数；concat 清单只含安全生成的相对名，不生成超大整本 WAV／PCM Data。时间以累计 48 kHz 帧数计算，M4B 使用 MP4 章节轨及 `disable_chpl`，避免依赖 Nero 章节数量限制；MP3 按用户实际选择章节编码。
  封装与元数据依据 [FFmpeg MOV／MP4 文档](https://ffmpeg.org/ffmpeg-formats.html#mov_002c-mp4_002c-ismv)、[FFmetadata 文档](https://ffmpeg.org/ffmpeg-formats.html#Metadata)，2026-10-14 核对；实际二进制／codec 能力仍由本任务 capabilities 探测。
- [ ] 校验输入摘要、完整解码和最终产物；取消／SIGTERM／超时需取消任务、终止并 wait FFmpeg 后才结束 CLI。磁盘不足保留已有成品与来源，只隔离本请求临时文件。重跑三个 pytest 文件通过。

### T12：媒体 XPC 操作与安全导出提交

**Files:** 创建 media DTO/export controller/verifier、`Tests/AudiobookExportTests.swift`；修改 `Kit/ControlTypes.swift`、`Agent/AgentCommandRunner.swift`、`Agent/AgentOperationStore.swift`、`Agent/OperationJournal.swift`、`Tests/AgentCoreTests.swift`。

**Interfaces:** `ControlCommand.mediaCapabilities / mediaExport`；`ControlRequest.mediaRequestID: UUID?`，export 只接收该 UUID，不接收任意命令／路径。复用 `operationStatus / operationCancel`；`ControlResponse.media: MediaControlPayload?` 为 capabilities 或 export result 的带 kind DTO，字段与 T11 JSON 一致。`AudiobookExportController.prepare(bookID: UUID, chapterIDs: [UUID]?, profile: AudiobookExportProfile) async throws -> AudiobookPreparedExport`；`commit(_ prepared: AudiobookPreparedExport, destination: URL, overwriteConsent: AudiobookOverwriteConsent?) async throws`；`AudiobookMediaVerifier.verify(url: URL, expected: AudiobookPreparedExport) async throws -> AudiobookMediaVerification`。

- [ ] 写 `testFullExportRejectsMissingStaleOrUnknownChapter`、`testPartialExportListsActualAndOmittedChapters`、`testTargetChangedAfterConsentPreservesExistingFile`、`testExportCancellationNeverCommitsStage`。扩展 Agent fake：同 mediaRequestID 不重复启动、非法 payload 拒绝、迟到 progress 不重开终态、cancel 只终止匹配操作。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter 'AudiobookExportTests|AgentCoreTests'`，确认失败。
- [ ] ManagedCommand 增加固定媒体 argv；mediaExport 使用已有单一 active mutation 和后台 operation。登记媒体 request→operation 关联，重复投递返回同一操作；terminal media payload 随 operationStatus 回读。journal 保存非秘密 mediaRequestID，重启标 interrupted，不能恢复执行或删除未知文件；App 仅核验已有 result.json/stage 后提供用户继续入口。mediaCapabilities 不启动模型；允许取消匹配媒体操作。
- [ ] 使用 App 私有清单冻结一个完整制作版本；整本拒绝任一缺章／失效，部分导出明确范围和遗漏原因。先 CLI stage，再 AVFoundation 读取实际音轨、duration、章节名与时间，验证误差不超过一个目标 codec frame；不依赖不存在的 ffprobe 或字数估时。
- [ ] NSSavePanel／目录选择由用户决定目标。stage 验证后复制到目标同目录临时项再原子提交；覆盖同名文件需要具体目标同意及目标身份再核对，跨卷、磁盘不足、取消都不修改原文件。分章导出作为独立目录 bundle 提交，清单只含必要元数据，不能带正文和配置。
- [ ] 重跑定向测试通过。旧 managed runtime 不支持媒体命令时显示“导出工具不可用”，已有音频可继续听；本任务不自行替换 runtime。

### T13：功能 owner、完整页面及生命周期

**Files:** 创建表中六个 owner／wiring／view 文件、`Tests/AudiobookWorkflowTests.swift`；修改 `App/AppModel.swift`、`App/App.swift`、`App/AppRoute.swift`、`App/AppNavigationState.swift`、`App/ControlCenterView.swift`、`App/SettingsAssistantPane.swift`、`App/WindowLayoutPolicy.swift`、`App/SpeechRailDesignTokens.swift`；更新路由检查及清单：
`scripts/check_macos_route_contract.py`、`macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`、`docs/design/2026-09-15-macos-uiux-redesign/UIUX-AUDIT-MATRIX.md`。

**Interfaces:** `@MainActor @Observable AudiobookWorkflowModel.init(dependencies: AudiobookDependencies)`；`openBook(_:)`、`beginAnalysis(_:)`、`makeConfirmedChapters()`、`leaveWorkshop() async`、`shutdown() async`；只读 shelf/selectedBook/analysis/production/listening/export 投影。AppModel 装配并暴露 `audiobookWorkflow`，不缓存另一份项目状态。

- [ ] 写 `testWorkflowOnlyShowsNextValidAction`、`testRouteChangeKeepsProductionButReleasesListening`、`testShutdownCheckpointsAndNextLaunchRequiresResume`、`testVoiceDesignReturnPreservesBookAndRole`；使用真实 owner 和 fake 窄依赖。更新 route 纯函数断言，现有快捷键不变，新增工坊使用 `⌘⇧B`。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter 'AudiobookWorkflowTests|WindowLayoutPolicyTests'`，确认新增断言失败。
- [ ] 在 App composition root 接线 store、冻结 AI 配置 adapter、有限 response 的 render client、共享 playback／admission 和媒体 transport。默认注入 unavailable 依赖不创建真实用户库；测试明确注入临时 root。后台 task 属于 controller／owner，视图 `.task` 不持有长书制作。
  analysis factory 在开始时核对 snapshot 与当前已选择配置，捕获本轮 `ResolvedLLMConfiguration` 调用 `completeJSON`；key 仅在内存，不能持久化到 snapshot 或窗口。
- [ ] 增加创作路由 `audiobook`、书架、导入预览、准备／制作同工作台、听书模式；文字使用“分析全书”“人物与声音”“确认说话人后继续”“制作已确认章节”“正在暂停”“继续听”“之前的版本”等任务语言。
- [ ] 宽窗口三栏，中等窗口按既有 layout tier 收起人物面板并保留按钮／待确认定位。修改 Token 只在唯一声明点；常用动作进入可见控件、菜单和键盘路径，详细合并／拆分／追溯渐进披露。
- [ ] AI 点击分析前展示实际 provider 和范围；配置修改不偷换在途任务。角色配声复用音色库／设计，return context 由 navigation 持有，跨书或旧版本返回须明确处理。
- [ ] 将路由契约从 14 项同步为 15 项，仅更新 UI test 的路由清单，不运行前台自动化。运行 `uv run --no-sync python scripts/check_macos_route_contract.py` 与定向 Swift 测试，均通过。

### T14：规格覆盖、用户文档与分层验收

**Files:** 创建 `Tests/AudiobookAcceptanceTests.swift`、`docs/developers/macos-app-audiobook.md`、`docs/users/audiobook-workshop.md`、`docs/architecture/audiobook-workshop.md`；修改 `docs/developers/README.md`、`docs/users/README.md`、`docs/architecture/README.md`、`docs/architecture/macos-feature-ownership.md`、`docs/developers/macos-app-design-system.md`、`docs/developers/testing-acceptance.md`。

- [ ] 写 `testFakeBookEndToEndWithReviewRepairAndRestart`：虚构三章／旁白加两角色，unknown 只挡一章，确认后完成、返修采用／撤销、重开恢复、试听抢占、完整／部分导出门槛均通过；fake media 断言真实的顺序／帧数清单，不冒充 codec 验收。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookAcceptanceTests`，确认流程断言能揭示未接线或错误门槛。
- [ ] 补齐用户“导入—分析—确认—试听—制作—听书／导出”的说明，以及隐私、有限重试、版本影响、保存恢复和工具缺失恢复。开发文档记录接口／schema／媒体桥；架构和设计系统同步 owner、路由、Token 与原文不变量，不更新无关根 README。
- [ ] 重跑 acceptance、受影响的既有 AppModel／LLM／配音／Agent 定向回归：`swift test --package-path macos/SpeechRailApp --filter 'AudiobookAcceptanceTests|AppModelTests|LLMProviderTests|DubbingProjectStoreTests|AgentCoreTests'`，全部通过；修复后不无理由扩大到完整 suite。
- [ ] 运行 `uv run --no-sync python scripts/check_macos_test_target_coverage.py`、`uv run --no-sync python scripts/check_macos_route_contract.py`、`uv run --no-sync ruff check src/speechrail/media src/speechrail/cli.py tests/test_media_manifest.py tests/test_media_encoder.py tests/test_media_commands.py`、`uv run --no-sync mypy src/speechrail/media src/speechrail/cli.py` 和 `git diff --check`；期望清单一致、类型／lint 无错误、无 diff 空白问题。
- [ ] 按下表建立交付记录：日期、命令、实际结果、版本／文件摘要、未验项目、可恢复资产及运行态动作。未实际执行的检查写“未执行”，不能从 fake 外推音质、速度、成本或媒体兼容性。

## 验收门槛与规格追踪

| 规格范围 | 任务 | 完成证据 |
| --- | --- | --- |
| §1–3 入口与完整流程 | T06／T08／T13／T14 | fake 真实 owner 流程、路由契约、明确下一步 |
| §4 原文保真 | T01–T03／T07 | 三编码、来源覆盖、章节修改及独立资产 |
| §5–6 全书分析与人物 | T04–T06 | 百万字有界输入、别称／嵌套对白、检查点和章级 unknown |
| §7 制作、返修与恢复 | T07–T09 | 固定 pins、真实摘要、崩溃注入、局部失效及采用事务 |
| §8 听书 | T10／T13 | 文件 fake、唯一 token、实际时序与来源书签 |
| §9 导出 | T11–T12 | 清单／argv／文件边界回归；实际 codec／播放器分开验收 |
| §10–11 数据、AI 与错误 | T03–T05／T08／T12–T13 | 独立库、冻结配置、有限恢复、代次与错误状态 |
| §12–14 能力与分层验收 | 全任务／T14 | 当前源码核对、定向证据、未验证项与用户评审 |

| 验收层 | 何时执行 | 门槛 |
| --- | --- | --- |
| 定向确定性测试 | 获准实施后，任务内执行 | fake LLM／render／媒体，临时库、百万字合成源、无真实网络和音频 |
| App 编译与 Xcode 成员检查 | 用户授权构建时，使用 release skill 和仓库 wrapper | 包与 App 依赖闭包一致；不安装、不影响当前服务 |
| 实际媒体编码／解码 | 用户授权媒体验收后 | 合成音调／静音 fixture、300 章 M4B 与 MP3，metadata／duration／解码；工具缺失不自动下载 |
| 真实模型与听审 | 用户明确授权对应专项 | 多角色／数字人名／跨章声线／衔接／中断恢复，固定档位、回执和素材范围 |
| 界面及目标播放器 | 用户逐次明确授权前台操作后 | Light/Dark、键盘、VoiceOver、倍速、章节跳转、真实 M4B／MP3 导入；说明占用窗口和时长 |
| 安装、服务切换或发布 | 用户另行授权 | 按 release／local-deploy 专项执行，保留旧 runtime 与独立书籍数据 |

实施回退以新模块代码／文档为单位；不降级或删除书籍 schema，不改现有配音、会话和音色数据。旧 App 不识别书籍库时保留目录；临时失败可恢复到已验证候选和此前章节指针。若需替换 managed runtime 才能启用媒体命令，先交付可评审制品和回退说明，再执行获准安装。

## 计划自审与实施交接

本计划将规格所有章节映射到任务，五个 Review Focus 均有拥有者和明确回归；文中接口名称、路径前缀、预算和代次在跨任务使用时保持一致。实现细节由测试约束，不把未验证的真实音质或模型稳定性作为完成条件。

计划评审关注：独立书籍持久化、App 检查点恢复而非扩展 durable speech job、共享文件播放、固定媒体 XPC 操作，以及上述实施默认预算。

用户评审本计划后选择实施方式：建议由当前主代理顺序实施，各阶段检查 diff 和定向证据，完成后由独立 `luna_worker` 复核整体变更；接口依赖紧密，共享文件较多。若选择分任务委派，每项由新的 `luna_worker` 实施并独立复核，再整体复核；14 个任务约需 28 次任务级新上下文，额外成本由实际上下文决定。先划清文件所有权，将工程、ControlKit、播放与 App 接线的写入保持串行。

本计划评审不包含安装、运行服务、下载模型、外部发布或前台自动化的授权。

2026-10-14 文档验证：14 个连续任务、79 个步骤、5 个 Review Focus、30 个既有文件路径及规格双向链接检查通过；无占位符、断链或空白问题。两份新文档的 `git diff --no-index --check` 无诊断，退出码 1 表示新文件相对空文件存在差异。此记录证明计划结构与引用有效，不是产品测试、构建或运行态验收结果。
