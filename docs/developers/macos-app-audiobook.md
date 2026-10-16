---
title: "SpeechRail macOS App 有声书工坊开发说明"
status: active
audience: "macOS App 开发者、架构与测试工程师"
version: "1.6.1"
date: 2026-10-16
---

# SpeechRail macOS App 有声书工坊开发说明

本文档说明 macOS App 中「有声书工坊 (`AppRoute.audiobookWorkshop`)」的源码边界、存储模型、全书理解管线、角色与音色确认门禁、流式章节合成、返修/撤销以及 M4B/MP3 导出与 XPC 桥接。

工作区从存储 actor 的一致输入生成，统计与正文投影通过 @concurrent 入口执行；每个选择域最多一个执行请求与一个最新等待请求。界面保留当前书与两个章节投影，存储缓存各最多两本书；制作终态单独可靠刷新。分析经过时间由局部 TimelineView 订阅，在功能隐藏或不活跃时暂停。具体容量、取消与回归口径见[性能观测与回归](macos-app-performance.md)。

## 1. 模块组成与文件清单

### 1.1 `SpeechRailAppSupport` 核心模型与控制器（可独立进入 SwiftPM 与 Xcode 单测）

- **`AudiobookDomain.swift`**：书籍状态机 (`AudiobookLifecycleState`)、章节、段落、阅读块 (`AudiobookBlock`)、说话人证据 (`AudiobookSpeakerEvidence`)、角色实体 (`AudiobookCharacter`)、音频切片 (`AudiobookFragment`)、候选音频 (`AudiobookCandidate`)、生产版本 (`AudiobookProductionRevision`)、收听进度 (`AudiobookListeningProgress`) 与失败信封 (`AudiobookFailureEnvelope`)。
- **`AudiobookSourceIndex.swift`**：持有规范 UTF-8 `Data` 与标量起点索引，按半开字节区间 (`[startByte, endByte)`) 读取正文并校验标量边界。编码与排版探测之后建立 `AudiobookParagraph` 只读投影，连接段内折行，保护空行、缩进段首、独立对白与诗行；每个段落保留原始字节范围，`normalizedText(in:)` 提供规整后的阅读文本，原始换行和 SHA-256 不变。SQLite 不重复存储整书正文。
- **`AudiobookTXTImporter.swift` & `AudiobookChapterPlanner.swift`**：编码探测（UTF-8 / BOM / UTF-16 / GB18030）、64 MiB 导入上限与 SHA-256；先规整逻辑段落，再规划章节并生成核对预览。除中英文显式章名外，识别有空行/居中排版及后续正文证据的多篇独立篇名；无上级篇名时，连续编号小节可作为章节。缺失开篇标题使用「开篇」，无可靠标题保留「全文」，不按作品知识补写标题。目录和段落完整覆盖来源；预览支持按章核对规整结果和原始排版，LF 仅用于阅读投影，canonical UTF-8 保留原始换行。
- **`AudiobookStoreSchema.swift`、`AudiobookAssetJournal.swift`、`AudiobookProjectStore.swift`**：独立 `audiobooks/library.sqlite3`（WAL、`foreign_keys = ON`、`user_version = 4`）与文件事务日志；候选提交通过 staged 文件、数据库登记及恢复核查保护音频资产；配声修订和跨目录登记意图分别支持撤销及中断恢复。
- **`AudiobookAnalysisPolicy.swift`、`AudiobookAnalysisPrompts.swift`、`AudiobookCastRegistry.swift`、`AudiobookAnalysisPipeline.swift`**：按 `LLMModule.audiobook` 解析专用/全局大模型配置；两级结构化 JSON 解析（章节窗口对话归属 + 跨章角色别名合并）；低置信度或漏标的直接对白归为 `unknown`，阻止对应章节制作，等待显式确认。
- **`AudiobookAnalysisProgress.swift`**：分析进度观测的闭式事件（`AudiobookAnalysisEvent`）、快照投影（`AudiobookAnalysisProgress`）与有界诊断缓冲。事件只带序号、计数、耗时、token 数与低基数错误码，不带原文、prompt、转写、密钥、路径或实名；投影侧按 `runID` + 序号丢弃过期/跨 run 事件，百分比单调不回退。管线在规划、提取、归并、标注、拆窗重试与终态处发射事件；`LLMProvider` 观测经 `callDiagnostics` 汇入，runID 与 LLM 观测 sessionID 一串到底。
- **`AudiobookAnalysisProgressRailView.swift`**：确定性进度轨道的纯展示视图（阶段 + n/N + 百分比 + 心跳 + 重试/停滞提示 + 开发者诊断折叠区）。输入只有不可变快照、时钟 tick、事件数与暂停回调，不读 `AppModel`，可经 `ImageRenderer` 离屏渲染做视觉回归；文案走同文件的纯函数（心跳三档阈值与 `AudiobookAnalysisProgressLimits` 一致），工作台只做薄委托。
- **`AudiobookCastController.swift`**：角色重命名、合并/拆分、单条台词改派、音色匹配打分、一键试听样本生成，以及进入批量合成前的「旁白确认 + 必选角色确认 + 试听通过」门禁。
- **`AudiobookFragmentPlanner.swift` & `AudiobookInvalidation.swift`**：默认上限为 240 Unicode 标量，按标点切分且不跨说话人边界；根据原文、角色与音色等依赖摘要计算片段失效，普通制作可复用未变化的有效候选。
- **`AudiobookDependencies.swift` & `AudiobookProductionController.swift`**：串行 TTS 合成队列、能力快照版本锁定 (`effective_capabilities_v1`)、8 MiB 单响应护栏、通过 `AVAudioConverter` 正规化为 48 kHz PCM16 单声道 WAV、原子候选落盘与断点续作。
- **`AudiobookRevisionController.swift`**：候选与不可变章节版本分离；显式采用创建新的 `AudiobookChapterRevision` 并切换 `currentChapterRevisionID`，保留上一版本供撤销。
- **`AudiobookListeningController.swift`**：复用 `SharedPlaybackOwner` 唯一播放句柄，支持倍速、章节/段落跳转与收听书签；外部试听先保存当前收听位置，再交出播放权。
- **`AudiobookMediaVerifier.swift` & `AudiobookExportController.swift`**：导出前校验全部采用切片的磁盘存在性、WAV 头、帧数与 SHA-256；写入 `<app_home>/audiobooks/exports/<request_id>/request.json` 并通过 `SpeechRailControlAgent` 执行 `speechrail media encode-audiobook`，导出完成后用 `AVURLAsset` 做时长、音轨与章节数二次校验。
- **`AudiobookWorkflowModel.swift` & `AudiobookProductionWiring.swift`**：`@MainActor @Observable` 顶层编排器，将书架、工作台两页签、收听模式与 `AppModel` / `SharedPlaybackOwner` / `SpeechCreationAdmission` 连接起来；异步读取和制作收尾校验书籍身份与任务代次。

角色分析的 prompt 文本及工作台的段落、片段展示共用 `source.normalizedText(in:)`，不会把排版折行当作语义断句。LLM 仍只引用既有 atom ID；完整覆盖、持久化来源、片段依赖及校验使用原始字节区间。导入不重写已有作品的原文或音频。

回目识别支持“零 / 〇 / ○”，并为与前后正文粘连的可靠回目建立虚拟行边界，边界仍指向原始字节。合集目录优先保留独立篇名，篇内编号章节保留在该篇正文中；章回体优先使用回目。相邻同名标题之间仅有空白或分隔线时合并目录入口，来源文字不删除。CRLF 的两个 scalar 必须同时计入 atom 的 160 scalar 预算。

`AudiobookImportPreview.repeatedContentWarnings` 按完整章节的规整文本摘要发现重复组，不因标题相同就判断正文重复。重复组保留所有章节与原文，`canConfirmImport` 在用户显式确认前为 false；Workflow 导入入口和确认按钮共同执行此门禁。确认仅作用于本次预览，不修改持久化格式。真实语料的可选验证入口见 [测试与验收](testing-acceptance.md#有声书外置小说语料回归)。

### 1.2 SwiftUI 视图层（仅在 `SpeechRailApp` target 编译）

- **`AudiobookWorkshopView.swift`**：顶层容器与页面头部动作、状态结论横幅、模式切换（书架 / 制作工作台 / 沉浸收听）及导入面板。
- **`AudiobookBookShelfView.swift`**：书架网格/列表、引导空态、每本书的进度胶囊与直达动作（「继续制作」「收听」「导出」）。
- **`AudiobookBookWorkspaceView.swift`**：左侧章节列表与「整理章节」次级菜单、中央「准备与角色」「制作与返修」两页签、人物与声音面板，以及片段重录、候选对比和显式采用区域。
- **`AudiobookListeningView.swift`**：收听视图，含章节目录、正文与「返修此段」导航、传输控制条。

### 1.3 Python 媒体导出子系统 (`src/speechrail/media/`)

- **`manifest.py`**：校验 `audiobook_media_export_v1` 请求清单、64 MiB 体积上限、路径穿越与符号链接拦截、所有输入 WAV 的 64 KiB 分块 SHA-256 核对。
- **`encoder.py`**：定位 `ffmpeg`，整理章节 PCM 为 48 kHz 单声道，生成以 `1/48000` 为时间基准的 FFMETADATA 章节轨，编码为 `.m4b`（AAC、`+faststart+disable_chpl`）或分章 `.mp3`；Swift 校验器独立探测实际媒体并与预期帧数核对。
- **`commands.py` & `cli.py`**：提供 `speechrail media encode-audiobook --app-home <path> --request-id <uuid> --format json`，供 `SpeechRailControlAgent` 调用并记入 `OperationJournal`。

## 2. 关键不变量

1. **原文零改写与字节区间真源**：导入生成的 `source.txt` 只读封存，章节、段落、阅读块与音频切片一律通过 `[startByte, endByte)` 指向 `source.txt`，数据库不存储冗余全文拷贝。
2. **角色与音色双层解耦**：LLM 理解只产出 `CharacterID`，合成只读取 `CharacterID -> VoiceBinding`。更换角色音色只重算该角色的片段签名，不重跑 LLM。
3. **单播放源**：试听、返修对比、成书收听全部经由 `SharedPlaybackOwner`；生产队列由独立准入与暂停机制管理。
4. **资产恢复与提交验证**：候选通过 `AudiobookAssetJournal` 恢复，未采用候选与历史版本引用保留；导出通过舞台产物校验、目标旁临时副本复核及原子安装提交。

### 2.1 选角方案与正式制作边界

- `AudiobookCastRegistry.recommendVoiceBindings` 消费完整能力快照和 `VoiceCatalogSnapshot`，输出 `AudiobookCastingPlan`。候选需归属明确、对本书可见、可用且 `productionReady == true`，并明确支持拟用参数；池为空时返回问题，不退回原始列表。只有快照可证的系统预设可以在未登记目录元数据时通用。
- 旁白计入声音容量；别名不增加数量。自动推荐、按行当补全和自动创建主角声音只处理未绑定角色。已有选择受保护，独占冲突不会自动改为共享。任何新增共享建议都需要与方案摘要绑定的显式接受，同章冲突另行说明；单个未采用候选的排除说明不要求接受风险。同书音色的来源角色影响排序，不额外限制其可见范围。
- `Store.prepareCastingPlan` 在同一 actor 中补齐原文/章节上下文摘要与影响片段；纯 Registry 结果不能直接提交。`CastController.applyCastingPlan` 重新核对能力及目录修订；Store 在单事务中比较角色、标注、绑定和原文/章节输入，保存政策、绑定、修订及确认失效。任一项错误、过期或取消均无部分提交。
- 真正零台词角色只有在全书分析及所有应读文本标注完整、说话人明确时才免绑定；其旧绑定保留但不占发声容量，独占检查针对必需发声角色，重新出现台词时恢复校验。标注缺失或未知对白保留门禁。音色生成上下文冻结角色修订与 `voiceSetDigest`，单个/批量生成返回都不能覆盖期间的新选择；Store 保存前再次比较，绑定失败不报告成功。
- 新推荐使用 `speed=1.0`、`callerSeed=nil`。clone 固定此组合；旧 clone 非法参数要求重新确认，原绑定和作品保留。其他声音只使用能力快照声明的参数域。合法种子经 `SpeechRail-Seed` header 传递，所有请求选项复制保留它；正式渲染始终 `require_output_pass`，重试冻结参数且不重试确定性拒绝。
- 请求的模型/声音 pin 不能自动换成最新版本。合法 system 可缺少 `voiceRevision`，自定义声音缺失则阻断；实际回执身份未知时保持未知，WAV 大小或请求预期值不能证明 provenance。开始每个新片段时重新校验目录与能力；在途声音被归档后，已得到的候选保留待复核，不自动采用。
- 对白量按原文 Unicode scalar 的去重区间统计，分层建议不修改 `isMajor` 或声音共享政策；人工层级优先。独立画像保留未知及来源，必需条件约束自动与手工入口。场景图区分直接对白、同场与同章，原文距离包含旁白；重复窗口不重复计权。
- 独占先核实最大匹配，再做最大权重一对一分配；共享采用受候选限制的 DSATUR 排序和有界修复。`sceneAware` 与 `baseline` 共用 P0 守卫；评分矩阵最多 100000 个组合，加权匹配最多 20000000 次成本单元及势更新工作，局部候选计算最多 100000 次。超界报告预算耗尽并保持原绑定，内层循环检查取消。角色/音色语义缓存与目录全局修订分开，局部目录改动不要求全量重新评分。
- `VoiceCatalogStore` 的 JSON envelope 为 schema 2，`visibilityScope` 与 `lifecycleState` 独立。成功原子保存后才通知界面；错误向调用方传播。收藏叠加于范围筛选，归档/恢复保留推广后的全局身份。设计与克隆回填分别保留实际来源，从最新能力解析身份，不使用占位版本或设计种子充当 clone caller seed。
- `voice_registration_intents` 先登记书籍专用目标，目录成功后才提交绑定；每个阶段可幂等恢复，期间改选进入待确认，不覆盖新选择。`casting_revisions` 同时覆盖绑定与共享政策开关，重复设置不占用历史；撤销新增修订并恢复旧政策/绑定，保留已采用音频；当前状态不匹配时拒绝撤销。
- 工作坊先展示推荐方案、原因、风险和影响，再按方案身份接受。相同原文及相邻对白试听冻结身份与参数，使用 `allow_unverified`，只交给共享播放器；不生成正式候选，不自动确认质量。
- SQLite schema 1→2 将 `voice_revision` 改为可空，2→3 增加政策/画像及可空实际身份列，3→4 增加意图与配声修订。每步通过 SQLite backup API 保存一致性副本，事务推进版本；失败保留旧阶段与资产。回退保留 schema 4 和目录 schema 2，可切回 `baseline`，不能以旧备份覆盖后续作品。迁移验收只使用临时合成副本。

规格见 [大规模选角与音色资产规范](audiobook-mass-casting-spec.md)；实施及证据见 [P0 定向验收记录](../audits/2026-10-15-audiobook-mass-casting-p0-acceptance.md) 和 [S3～S5 离线验收记录](../audits/2026-10-15-audiobook-mass-casting-p1-acceptance.md)。真实模型听评及 UI 验收独立记录，未执行不能推定通过。

## 3. 章节整理与单段重录

- `renameChapter(bookID:chapterID:title:)` 只更新标题。结构编辑由 `updateChapters` 执行，在事务内核实尚未开始分析且没有分析或制作记录，再重建目录与文本原子并同步旁白章节关联。禁止通过结构编辑清空旧分析或音频历史。
- Workflow 的结构编辑投影仅开放分析前的默认路径；正文选区必须落在已有文本原子的起点，界面不要求用户填写字节偏移。异步编辑收尾只更新对应书籍的选择和提示。
- `regenerateFragment(bookID:chapterID:fragmentID:)` 与整章制作共用入口互斥、配声确认、能力快照、资源准入、暂停和音频提交机制。目标必须属于当前规划；即使存在相同依赖的有效候选，也生成新候选，其他片段不发送渲染请求。
- 单段模式不自动发布章节版本，Workflow 仅为已有 `currentChapterRevisionID` 的章节开放重录。任务继续以 bookID / runID 追踪，完成后在已有候选比较区试听并显式采用；普通制作保留相同依赖候选复用及首个完整章节的自动发布行为。
- 候选提交和章节版本发布的异步边界之后复查运行代次。暂停保留已提交候选，并将活动任务状态写为 paused；迟到的旧任务不能越过已接受的暂停继续提交完成。最终完成事务开始后等待保存结果，成功后才发布完成进度；此时的取消或暂停不再把已提交的完成状态改写为 paused，保存失败仍走暂停与存储错误处理。
- 制作从准备阶段即发布 `AudiobookProductionProgress`，区分准备、核对已有音频、生成、重试、保存和章节整理，提供已保存/总片段数、复用数、当前章节、时间与重试次数。Workflow 每 250 ms 读取快照，独立进度卡每秒更新用时；进度常驻两页签上方，书架显示同一活动任务的实时百分比。没有片段总数时显示准备状态，不伪造百分比；一分钟无阶段或片段进展时提示等待较久。
- `production_checkpoints` 附加表保存本次任务 ID、所选章节、可选重录片段及进度。每段提交后保存，暂停/完成时保存终态；书籍制作状态与检查点在同一事务中写入，完成时同步提交对应的可收听状态。初始章节发布保留音频、版本和可收听状态，队列持有的制作终态只随最终检查点提交。服务错误正文不落盘。继续前重新验证条件、依赖与音频，单段模式仅复用同一任务已经提交的候选，不能误用重录前的旧候选。应用恢复区的书籍快照也携带检查点。
- 暂停先取消 Workflow 父任务与在途渲染，再等待安全收尾。暂停期间由暂停操作统一刷新并释放运行身份，完成/失败回调不抢先清除它。收尾以控制器的实际终态显示结果：paused 显示暂停，已完成保留普通制作或单段重录的完成提示，单段候选仍须显式采用。准备阶段的取消也保留原任务范围；未通过输入校验的操作不覆盖已有完成状态。检查点写入失败时内存进度标为 failed 并显示存储错误，暂停收尾不显示成功或承诺重新打开后可续作。
- `AudiobookExportTests` 的章节媒体夹具由 AVFoundation 动态生成合成 AAC，再用 PATH 中的 `ffmpeg` 按产品封装方式生成 QuickTime 章节轨；找不到工具时明确跳过该正例，不下载依赖。测试不使用真实书稿或模型。fake 编码流程必须显式注入 fake 媒体验证器，生产默认验证器始终读取实际媒体。
