---
title: "SpeechRail macOS App 有声书工坊开发说明"
status: active
audience: "macOS App 开发者、架构与测试工程师"
version: "1.16.0"
date: 2026-10-22
---

# SpeechRail macOS App 有声书工坊开发说明

本文档说明 macOS App 中「有声书工坊 (`AppRoute.audiobookWorkshop`)」的源码边界、存储模型、全书理解管线、角色与音色确认门禁、流式章节合成、返修/撤销以及 M4B/MP3 导出与 XPC 桥接。

工作区从存储 actor 的一致输入生成，统计与正文投影通过 @concurrent 入口执行；每个选择域最多一个执行请求与一个最新等待请求。界面保留当前书与两个章节投影，存储缓存各最多两本书；制作终态单独可靠刷新。分析经过时间由局部 TimelineView 订阅，在功能隐藏或不活跃时暂停。具体容量、取消与回归口径见[性能观测与回归](macos-app-performance.md)。

## 1. 模块组成与文件清单

### 1.1 `SpeechRailAppSupport` 核心模型与控制器（可独立进入 SwiftPM 与 Xcode 单测）

- **`AudiobookDomain.swift`**：书籍状态机 (`AudiobookLifecycleState`)、章节、段落、阅读块 (`AudiobookBlock`)、说话人证据 (`AudiobookSpeakerEvidence`)、角色实体 (`AudiobookCharacter`)、音频切片 (`AudiobookFragment`)、候选音频 (`AudiobookCandidate`)、生产版本 (`AudiobookProductionRevision`)、收听进度 (`AudiobookListeningProgress`) 与失败信封 (`AudiobookFailureEnvelope`)。
- **`AudiobookSourceIndex.swift`**：工作 UTF-8 `Data` 与标量起点索引，`text(in:)` 按半开字节区间切片并校验边界；同文件的 `AudiobookTextPreparation` 复用段落分类与连接政策，在分章前生成工作字节、SHA-256、加工版本和单调来源映射。原文件与解码参考文本独立封存，原始编码文件不参与工作偏移解释。SQLite 不重复存储整书正文。
- **`AudiobookTXTImporter.swift` & `AudiobookChapterPlanner.swift`**：编码探测（UTF-8 / BOM / UTF-16 / GB18030）、64 MiB 导入上限与 SHA-256；先规整逻辑段落，再规划章节并生成核对预览。`.epub` 先由 `AudiobookEPUBImporter` 按 spine 顺序提取 XHTML 正文/标题与 OPF 书名作者，再复用同一套纯文本导入；原始压缩包不保存。除中英文显式章名外，识别有空行/居中排版及后续正文证据的多篇独立篇名；无上级篇名时，连续编号小节可作为章节。缺失开篇标题使用「开篇」，无可靠标题保留「全文」，不按作品知识补写标题。目录和段落完整覆盖来源；预览支持按章核对规整结果和原始排版，canonical UTF-8 保存已加工文本，原始换行只存在于参考文本；原始排版预览通过来源映射回到参考坐标。
  编码探测不再在歧义时阻断预览：非 UTF-8 的合法 GB18030 字节流按 GB18030 提供临时预览，C1 控制符等可疑 UTF-8 同样标记待确认；`requiresEncodingConfirmation` 为 true 时导入面板显示提示，用户切换编码后重新生成预览，错误在面板内可见。
  `AudiobookChapterPlanner.plan` 额外返回 `tableOfContentsRanges`：连续至少三个章名行之间只隔空白/页码/点引线，且有目录标记或后文同名标题时，整段识别为目录页，从章名候选中移除，并作为首个相关章节的 `excludedRanges`。仅含目录的合成「开篇」会并入下一章；目录字节仍被章节覆盖，但不会生成 atom、进入分析或朗读。`plan` 保留无目录时的既有边界与标题。
- **`AudiobookEPUBImporter.swift`**：纯 Swift ZIP 中央目录预检（加密位、method、条目数、压缩/解压总量、路径穿越），再用系统 `ditto` 解压到临时目录并拒绝符号链接/越界路径；只读取 `META-INF/container.xml`、OPF manifest/spine 与 XHTML，忽略脚本、样式和外部资源。XHTML 按块级标签保留段落/标题边界，常见 HTML 实体转 Unicode，非严格 XHTML 走去标签兜底。DRM、损坏包、缺失 container/spine、空正文均返回可行动错误。
- **`AudiobookStoreSchema.swift`、`AudiobookAssetJournal.swift`、`AudiobookProjectStore.swift`**：独立 `audiobooks/library.sqlite3`（WAL、`foreign_keys = ON`、`user_version = 6`）与文件事务日志；候选提交通过 staged 文件、数据库登记及恢复核查保护音频资产；配声修订和跨目录登记意图分别支持撤销及中断恢复。`pronunciation_bindings` 每书保存一条不可变词表 revision 绑定，`chapters.is_skipped` 保存章节跳过状态，`books.analysis_failure_json` 保存分析失败信息。打开作品库时，以建库 SQL 生成内存参照，核对表、列类型、空值约束、默认值、主键、外键与索引；同版本结构不符时明确拒绝，不在后续导入时才暴露 SQL 错误。
- **`AudiobookAnalysisPolicy.swift`、`AudiobookAnalysisPrompts.swift`、`AudiobookCastRegistry.swift`、`AudiobookAnalysisPipeline.swift`**：按 `LLMModule.audiobook` 解析专用/全局大模型配置；两级结构化 JSON 解析（章节窗口对话归属 + 跨章角色别名合并）；低置信度或漏标的直接对白归为 `unknown`，阻止对应章节制作，等待显式确认。
- **`AudiobookAnalysisProgress.swift`**：分析进度观测的闭式事件（`AudiobookAnalysisEvent`）、快照投影（`AudiobookAnalysisProgress`）与有界诊断缓冲。事件只带序号、计数、耗时、token 数与低基数错误码，不带原文、prompt、转写、密钥、路径或实名；投影侧按 `runID` + 序号丢弃过期/跨 run 事件，百分比单调不回退。管线在规划、提取、归并、标注、拆窗重试与终态处发射事件；`LLMProvider` 观测经 `callDiagnostics` 汇入，runID 与 LLM 观测 sessionID 一串到底。
- **`AudiobookAnalysisProgressRailView.swift`**：确定性进度轨道的纯展示视图（阶段 + n/N + 百分比 + 心跳 + 重试/停滞提示 + 开发者诊断折叠区）。输入只有不可变快照、时钟 tick、事件数与暂停回调，不读 `AppModel`，可经 `ImageRenderer` 离屏渲染做视觉回归；文案走同文件的纯函数（心跳三档阈值与 `AudiobookAnalysisProgressLimits` 一致），工作台只做薄委托。
- **`AudiobookCastController.swift`**：角色重命名、合并/拆分、单条台词改派、音色匹配打分、一键试听样本生成，以及进入批量合成前的「旁白确认 + 必选角色确认 + 试听通过」门禁。
- **`AudiobookFragmentPlanner.swift` & `AudiobookInvalidation.swift`**：默认上限为 240 Unicode 标量，按标点切分且不跨说话人边界；根据工作修订、加工版本、文字、角色与音色等依赖摘要计算片段失效，普通制作可复用未变化的有效候选。提供 atoms 时按“非格式、未被章节排除”的正文原子校验覆盖：重复或缺失标注直接拒绝规划，避免静默漏读；发音规则只把实际命中词条的片段并入 `pron:<hash>` 依赖，未命中的片段摘要保持不变。
- **`AudiobookDependencies.swift` & `AudiobookProductionController.swift`**：串行 TTS 合成队列、能力快照版本锁定 (`effective_capabilities_v1`)、8 MiB 单响应护栏、通过 `AVAudioConverter` 正规化为 48 kHz PCM16 单声道 WAV、原子候选落盘与断点续作。
- **`AudiobookRevisionController.swift`**：候选与不可变章节版本分离；显式采用创建新的 `AudiobookChapterRevision` 并切换 `currentChapterRevisionID`，保留上一版本供撤销。
- **`AudiobookPronunciationController.swift`**：把本书词表经 `AudiobookPronunciationClient` 保存为不可变 revision（header `SpeechRail-Pronunciation-Set: <set_id>@<revision>`），本地缓存于 `pronunciation_bindings`。保存冲突（409）不覆盖远端，置 `needsRefresh` 并提示先刷新；刷新先从摘要取最新 revision，再按该 revision 读取词条，可恢复本地缓存缺失或别处更新的场景。渲染请求携带固定 header，片段依赖只对命中词条变化。
- **`AudiobookListeningController.swift`**：复用 `SharedPlaybackOwner` 唯一播放句柄，支持倍速、章节/段落跳转与收听书签；外部试听先保存当前收听位置，再交出播放权。播放期间按 `progressSampleInterval`（默认 200 ms）采样播放器片内进度，换算片段/章节已播时间，并按 `bookmarkAutosaveInterval`（默认 5 s，复用 `AudiobookLimits.bookmarkAutosaveIntervalSeconds`）自动写书签；暂停、离开或试听抢占前先应用当前采样再保存。采样只接受向前推进的值，seek 后旧回调不会把时间轴拉回。仅显示与保存用 `AudiobookDisplayFormat` 统一时间码与倍速文本。
- **`AudiobookCoverAssetStore.swift`**：书籍自有封面资产的落盘与读取（`books/<book_id>/cover/cover.<jpg|jpeg|png>`）。安装前校验普通文件、非符号链接、扩展名白名单（`jpg`/`jpeg`/`png`）与 8 MiB 上限，采用同目录临时文件加原子替换；封面随 `books/<book_id>` 由既有废纸篓生命周期携带，不写 SQLite。
- **`AudiobookMediaVerifier.swift` & `AudiobookExportController.swift`**：导出前校验全部采用切片的磁盘存在性、WAV 头、帧数与 SHA-256；写入 `<app_home>/audiobooks/exports/<request_id>/request.json` 并通过 `SpeechRailControlAgent` 执行 `speechrail media encode-audiobook`，导出完成后用 `AVURLAsset` 做时长、音轨、章节数与封面存在性的二次校验。准备阶段由 Workflow 持有 requestID，可调用 `cancel(requestID:)` 中止编码并显示“未生成任何文件”；保存阶段对已存在的 M4B 文件或 MP3 目录都要求显式替换确认，目录不会被静默整体覆盖。导出面板先调用 `AudiobookExportController.audit(...)` 做只读预检（与 `prepare` 共用 `buildPlan`，不写文件、不保存生产版本），按 `AudiobookExportBlocker` 逐章列出缺分析、待确认说话人、无当前音频、资产缺失或空片段，再禁用整本 M4B 或空的 MP3 选择；准备/保存失败写入 `exportErrorMessage`，在导出 Sheet 的操作浮层中显示，成功后清除。带封面时清单升级为 `audiobook_media_export_v2` 并携带封面相对路径与图像 SHA-256；`chapter_mp3` 与跨书封面在写清单前拒绝。
- **`AudiobookWorkflowModel.swift` & `AudiobookProductionWiring.swift`**：`@MainActor @Observable` 顶层编排器，将书架、工作台两页签、收听模式与 `AppModel` / `SharedPlaybackOwner` / `SpeechCreationAdmission` 连接起来；异步读取和制作收尾校验书籍身份与任务代次。

角色分析的 primary/context、工作台展示、选角试听和 TTS 共用 `workingSourceSnapshot` 固定的工作索引及 `text(in:)`，同一区间的文字与工作文件字节一致。LLM 只引用该修订的 atom ID。检查点保存 source ID 与加工版本，片段依赖包含加工版本；提交角色、标注、候选、章节和完成进度时重新核对修订，迟到结果不能修改新 source 的状态。 加工生成的段间空白不构成新的标题证据；来源映射保留每个逻辑段落的原始标题候选判定，导入与重开后使用相同判定。


Store 的 schema 7 将旧 source 标记为 `reference`，不自动准备旧作品。`prepareWorkingRevision(bookID:expectedSourceID:)` 只在明确作品操作中调用，暂存校验后 CAS 切换，保留全部历史行与 WAV；`activateSourceRevision` 按指针回退。工作文件或映射损坏不得回退原文；未准备作品返回 `working_text_preparation_required`。历史收听按章节修订取候选；`ExportController.audit/prepare` 可传 `productionRevisionID`，使用该修订的 source、章节和音频，不写入当前工作采用版本。

分析前章节编辑通过 `chapterEditDraft(bookID:chapterID:)` 冻结活动 source/hash、章节身份和布局摘要；`saveChapterEdit(_:title:body:)` 在事务内复核阶段与版本。正文输入按 UTF-8 原样保存，不调用原文加工或自动分章。正文变更产生新 source、章节和 atom，使用 `isGenerated` 与 `isUserEdited` 标注非逐字参考映射；已存在的来源映射无需迁移。生成映射在非逐字区间内部裁切时，参考证据归左侧，右侧使用其末端锚点，不按比例推算参考偏移。未改章节的字节、顺序、名称及跳过状态保持；仅重命名或无变化不创建工作 source。

正文草稿仅包含 `text(in:excluding:)` 返回的实际正文。用户修改正文后，以可见正文替换本章整个工作范围并清空本章旧目录排除区间；其他章节排除区间按位移更新。原文、旧工作资产和已有音频始终保留。`AudiobookWorkflowModel` 持有草稿及未保存输入，编辑时互斥分析/制作/章节整理及选择；保存失败保留输入和内联错误，保存成功后刷新活动 source 与所选新章节。

回目识别支持“零 / 〇 / ○”，并为与前后正文粘连的可靠回目建立虚拟行边界，边界仍指向原始字节。合集目录优先保留独立篇名，篇内编号章节保留在该篇正文中；章回体优先使用回目。相邻同名标题之间仅有空白或分隔线时合并目录入口，来源文字不删除。CRLF 的两个 scalar 必须同时计入 atom 的 160 scalar 预算。

`AudiobookImportPreview.repeatedContentWarnings` 按完整章节的规整文本摘要发现重复组，不因标题相同就判断正文重复。重复组保留所有章节与原文，`canConfirmImport` 在用户显式确认前为 false；Workflow 导入入口和确认按钮共同执行此门禁。确认仅作用于本次预览，不修改持久化格式。真实语料的可选验证入口见 [测试与验收](testing-acceptance.md#有声书外置小说语料回归)。

### 1.2 SwiftUI 视图层（页面在 App target 编译，独立组件按需进入单测）

- **`AudiobookWorkshopView.swift`**：顶层容器与页面头部动作、状态结论横幅、模式切换（书架 / 制作工作台 / 沉浸收听）及导入面板。
- **`AudiobookImportTextView.swift`**：导入核对正文使用 `NSViewRepresentable` 承载只读、可选择的 TextKit 2 `NSTextView` 与 `NSScrollView`；外层提供固定视口，正文高度由 AppKit 管理，不参与 SwiftUI 弹窗尺寸协商。原始/整理排版和章节切换只更新同一个文本控件；正文未变时保留选区与滚动位置，变更时回到开头。输入沿用 `maxPreviewScalars` 上限，不改原始字节、来源区间或章节划分。该控件同时进入 SwiftPM 与 Xcode 单测目标，支持无窗口回归；离屏测试不代表桌面滚动、键盘或复制交互已经验收。
- **`AudiobookBookShelfView.swift`**：书架网格/列表、引导空态、每本书的进度胶囊与直达动作（「继续制作」「收听」「导出」）；支持把 TXT/EPUB 直接拖入书架，并在移入废纸篓后提供一次性撤销横幅。
- **`AudiobookBookWorkspaceView.swift`**：左侧章节列表与「整理章节」次级菜单、中央「准备与角色」「制作与返修」两页签、人物与声音面板，以及片段重录、候选对比和显式采用区域。分析前在正文面板和菜单提供「编辑章节…」，原生标题/正文编辑器支持显式保存、取消及放弃修改确认；标题用于目录与导出，正文中的标题行独立编辑。分析后保留标题重命名，正文编辑关闭。
- **`AudiobookListeningView.swift`**：收听视图，含章节目录、正文与「返修此段」导航、传输控制条。

### 1.3 Python 媒体导出子系统 (`src/speechrail/media/`)

- **`manifest.py`**：校验 `audiobook_media_export_v1`/`audiobook_media_export_v2` 请求清单、64 MiB 体积上限、路径穿越与符号链接拦截、所有输入 WAV 的 64 KiB 分块 SHA-256 核对。音频与封面路径中的书籍 UUID 按相同身份比较，不区分十六进制字母大小写；文件读取保留清单中的原始路径，不改名或移动资产。v2 额外要求固定形状的封面路径 `books/<book_id>/cover/cover.<jpg|jpeg|png>`（文件名固定为 `cover`）、图像 SHA-256 与 8 MiB 上限；`v1` 出现 `cover` 键、`chapter_mp3` 配 v2 一律拒绝。v2 的 `loudness` 与封面同为可选扩展，可独立出现：`unit` 固定 `lufs`、`target_i` 必填、`true_peak_db`（默认 `-1.5`）与 `loudness_range`（默认 `11`）范围校验、未知键拒绝；`v1` 携带 `loudness` 同样拒绝。
- **`encoder.py`**：定位 `ffmpeg`，整理章节 PCM 为 48 kHz 单声道，生成以 `1/48000` 为时间基准的 FFMETADATA 章节轨，编码为 `.m4b`（AAC、`+faststart+disable_chpl`）或分章 `.mp3`；有封面时 `.m4b` 追加第二路输入并以 `-map 2:v:0 -c:v copy -disposition:v:0 attached_pic` 挂载封面（同时移除 `-vn`），无封面时命令行与既有输出逐项一致；Swift 校验器独立探测实际媒体并与预期帧数核对。请求带 `loudness` 时先以 `-f null` 测量整本节目、解析 `print_format=json` 的 I/LRA/TP/thresh/offset，再以 `linear=true` 把同一组测量值应用到 `.m4b` 或每个分章 `.mp3`；工具链探测不到 `loudnorm` 时抛 `MediaCodecUnavailableError`，测量失败即报错，不回退单遍处理。

- **`commands.py` & `cli.py`**：提供 `speechrail media export --app-home <path> --request-id <uuid> --json`，供 `SpeechRailControlAgent` 调用并记入 `OperationJournal`。JSON 行协议以 `event=progress` 报告进度，以 `event=result` 报告成功或失败终态；失败返回 `status=failed`、稳定的 `error_code` 与脱敏后的 `message`，即使尚未开始编码也遵守相同终态格式。

## 2. 关键不变量

1. **参考原文封存与工作文本区间**：原始 TXT 与解码参考文本只读保留；一次加工后的工作 UTF-8 是全部新工作输入，章节、段落、阅读块、角色证据和音频切片以该 source 的 `[startByte, endByte)` 定位。旧修订偏移不用于新字节。
2. **角色与音色双层解耦**：LLM 理解只产出 `CharacterID`，合成只读取 `CharacterID -> VoiceBinding`。更换角色音色只重算该角色的片段签名，不重跑 LLM。
3. **单播放源**：试听、返修对比、成书收听全部经由 `SharedPlaybackOwner`；生产队列由独立准入与暂停机制管理。
4. **资产恢复与提交验证**：候选通过 `AudiobookAssetJournal` 恢复，未采用候选与历史版本引用保留；导出通过舞台产物校验、目标旁临时副本复核及原子安装提交。
5. **封面为书籍自有资产**：封面只作为 `books/<book_id>/cover/cover.<ext>` 存在，不进入作品 schema；`v2` 清单以「相对路径 + 图像 SHA-256」传递，导出后由 `AudiobookMediaVerifier` 以 AVFoundation 复核封面存在/缺失，坏封面一律可见失败，不静默产出无封面书。

### 2.1 选角方案与正式制作边界

- 全书分析后自动准备已有声音方案；`autoAssignRecommendedVoices` 默认不接受新增共享，只有「一键智能配声」显式传入共享同意。该同意只覆盖 `sharedVoiceConsentRequired`，同章撞音和版本更新仍按方案身份集中确认。主按钮不调用声音创建、试听或章节制作；精细创作保留在角色与次级菜单中。
- 可用声音不足时，`AudiobookVoicePreparation` 从实际发声角色、声音要求和原文标注准备 `AudiobookVoiceCreationDraft`。创建资料与生成分离，`AudiobookVoicePreparationSheet` 集中展示可编辑名称、声音描述、试听稿和折叠的原文依据；建议与原文来源分开说明。名称上限为 64 scalar、描述为 1–10000 scalar、试听稿为 20–240 scalar；提交前校验，不在服务装配层隐藏修改合法文稿。
- `createSelectedVoiceDrafts` 仅提交已勾选且未完成的项目，串行复用设计、参考声音检查、发布和资产登记链。发布后的身份核对不要求声音已通过输出检查；先用无绑定的登记意图保留本书资产，再通过 `SpeechRailVoiceQualityClient` 检查配音效果。报告通过且 `validationPersisted=true` 后重新读取能力，只有 `production_ready=true` 及版本、参数均合法才提交角色绑定。检查失败呈现「已创建待检查」，保留资产并可仅重试检查，不再次设计。创建身份绑定具名的完整物料字段及创建尝试：编辑后使用新身份；传输或登记中断复用原尝试，参考声音检查已确认的终止失败使用新尝试身份与种子。取消不再启动下一候选或下一项目；发布成功后的身份核验与资产登记独立收尾，保留本书归属。异步返回同时核对作品与资料会话身份，切书开始即停止旧结果写回界面；在途人工选声继续受冻结上下文保护。
- 创建资料冻结角色、已有绑定、原文摘要、章节范围与标注身份；提交前重新核对，原文归属或角色变化要求重新准备。成功后刷新声音并重新准备配声建议，不隐式同意共享/撞音或启动章节制作。未提交草稿只驻留当前工作台内存，不新增持久化格式；重新读取时保留仍适用的编辑，切书清除。
- `isAssigningRecommendedVoices` 覆盖能力读取、匹配、保存和制作条件核对四个步骤，`castingPreparationProgressText` 显示实际阶段。重复准备或应用不重入；取消和切书后检查目标身份，完成后不自动进入音频制作。集中应用方案后也完成合法的角色确认，避免再要求逐个设置。
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
- SQLite schema 1→2 将 `voice_revision` 改为可空，2→3 增加政策/画像及可空实际身份列，3→4 增加意图与配声修订，4→5 增加发音词表绑定。5→6 幂等补齐章节跳过与分析失败列，覆盖 schema 5 已含任一列或两列的库；迁移先通过 SQLite backup API 保存包含已提交 WAL 的一致性副本，在同一事务内补结构、验证并推进版本，失败回滚该步。新建空库也在事务内建表和验证；没有版本标记的非空库不猜测迁移路径。同版本不静默重建缺失表，更高版本直接拒绝。升级后保留 schema 6 和目录 schema 2；旧 App 不支持 schema 6，不得降低版本标记或用旧备份覆盖后续作品。冻结历史 DDL 的迁移测试只使用合成临时库。

规格见 [大规模选角与音色资产规范](audiobook-mass-casting-spec.md)；实施及证据见 [P0 定向验收记录](../audits/2026-10-15-audiobook-mass-casting-p0-acceptance.md) 和 [S3～S5 离线验收记录](../audits/2026-10-15-audiobook-mass-casting-p1-acceptance.md)。真实模型听评及 UI 验收独立记录，未执行不能推定通过。

## 3. 章节整理、制作与按范围重录

- 工作台顶部默认「只补缺失音频…」；本章与全书的补缺失、更新和重新制作在「更多操作」中分别提供。所有用户入口先预览，展示章节、目标片段编号、数量和保留/采用规则；单段重录也先打开范围确认。人物与声音确认后显示状态，「查看章节音频」只导航。
- `previewProduction` 不写片段、候选或检查点，也不请求在线能力；核验实际资产后生成 `AudiobookProductionPlan`。`missingOnly` 跳过任何可用已有音频（包括依赖过时和回执未确认的候选）；文件缺失或损坏可补，旧文件保留。历史片段范围与新规划重叠时视为已有，无法映射的历史音频令该章保守保留，不凭空认定缺失。`updateOutdated` 仅处理已有且无当前有效候选的片段，明确排除缺失。`regenerate` 只规划目标正文与依赖，不读取无关历史候选的音频文件；同任务续作仅对待复用候选验证资产。内部执行接收非可选的冻结计划，所有入口先生成或恢复计划。
- 空目标计划使用简短结果 Sheet，只显示保留结果与“完成”；补缺失空结果中的“查看待更新音频”仅在原章节范围内生成新的 `updateOutdated` 预览，仍须再次确认。关闭旧预览后，迟到的新预览不能重新打开弹窗。
- 候选提交成功但回执未验证时，候选保留，任务写入 `failed` 与可选 `verificationFailureFragmentID`，不得报告完成或提供原条件续作。相同依赖已有待校验候选时，更新预览报出校验问题，禁止重复生成；补缺失仍保留其音频。旧 checkpoint 缺少该可选字段时正常解码。`isComplete` 按本次任务的完成阶段及状态判断，章节部分成片不妨碍已完成的批次显示 100%。
- `start` 默认 `missingOnly`；没有目标时不创建任务或读取在线能力。批准计划冻结稿件、章节与完整片段依赖，执行前逐一重规划比较，禁止增加目标；开始每段补缺失前再次核验已保存音频。首次完整章节可形成初始版本，已有版本在更新和重做时保留，必须显式采用候选才替换。完成投影依据未跳过章节及 `resumePlan.readyChapterIDs`；书架总数排除跳过章节，全部跳过不视为成书；`reviewChapterIDs` 引导已有完整更新候选的核对。
- `AudiobookRegenerationDraft` 冻结作品、加工稿件、章节和片段预览。逐章保留规划阻塞原因，其他章节的准备问题不阻止打开范围面板。所选范围包含受阻章时，确认接口拒绝并提供处理入口；确认接口也拒绝空范围和跨作品/跨章节片段；控制器再验证稿件 ID 与重规划范围，先校验再保存片段。整章重录为所有目标片段生成本任务新候选，已有章节不自动采用；尚无音频的完整章节可首次发布。
- Checkpoint 的可选 `productionPlan` JSON 保存意图和原片段清单，不改变 SQLite schema。续作先展示原任务类型和范围；控制器校验稿件、原章节、计划身份及每个目标依赖，不能加入后来新增的缺失或待更新。重做只复用同任务候选；所有缺少冻结计划的旧检查点（含显式重录）均拒绝自动续作，用户需重新预览；程序内直接发起的重做也必须先冻结片段依赖。开始新操作前明确提示将替换已暂停任务的续作记录，保留所有音频和版本。回退时保留库及资产，不用旧 App 续作含新计划字段的任务。
- 重做面板使用有界 Sheet，正文独立滚动，固定章数/片段数摘要及取消/确认；默认当前章节，支持片段多选、章节多选和整本，打开建立焦点，Escape 取消。源码及编译验证不能替代真实窗口交互验收。

- `renameChapter(bookID:chapterID:title:)` 只更新标题。结构编辑由 `updateChapters` 执行，在事务内核实尚未开始分析且没有分析或制作记录，再重建目录与文本原子并同步旁白章节关联。禁止通过结构编辑清空旧分析或音频历史。
- Workflow 的结构编辑投影仅开放分析前的默认路径；正文选区必须落在已有文本原子的起点，界面不要求用户填写字节偏移。异步编辑收尾只更新对应书籍的选择和提示。
- `regenerateFragment(bookID:chapterID:fragmentID:)` 与整章制作共用入口互斥、配声确认、能力快照、资源准入、暂停和音频提交机制。目标必须属于当前规划；即使存在相同依赖的有效候选，也生成新候选，其他片段不发送渲染请求。
- 单段模式不自动发布章节版本，Workflow 仅为已有 `currentChapterRevisionID` 的章节开放重录。任务继续以 bookID / runID 追踪，完成后在已有候选比较区试听并显式采用；普通制作保留相同依赖候选复用及首个完整章节的自动发布行为。
- 候选提交和章节版本发布的异步边界之后复查运行代次。暂停保留已提交候选，并将活动任务状态写为 paused；迟到的旧任务不能越过已接受的暂停继续提交完成。最终完成事务开始后等待保存结果，成功后才发布完成进度；此时的取消或暂停不再把已提交的完成状态改写为 paused，保存失败仍走暂停与存储错误处理。
- 制作从准备阶段即发布 `AudiobookProductionProgress`，区分准备、核对已有音频、生成、重试、保存和章节整理，提供已保存/总片段数、复用数、当前章节、时间与重试次数。Workflow 每 250 ms 读取快照，独立进度卡每秒更新用时；进度常驻两页签上方，书架显示同一活动任务的实时百分比。没有片段总数时显示准备状态，不伪造百分比；一分钟无阶段或片段进展时提示等待较久。
- `production_checkpoints` 附加表保存本次任务 ID、所选章节、可选 `regenerationScope`（整章或片段 ID 集合）及进度。范围写在现有 JSON 中，不改变 SQLite schema；旧单段检查点可按 `regeneratingFragmentID` 读取范围，但缺少 `productionPlan` 时仅供状态展示，不能自动续作。每段提交后保存，暂停/完成时保存终态；书籍制作状态与检查点在同一事务中写入，完成时同步提交对应的可收听状态。初始章节发布保留音频、版本和可收听状态，队列持有的制作终态只随最终检查点提交。服务错误正文不落盘。继续前重新验证条件、依赖与音频，显式重录仅复用同一任务已经提交的候选，不能误用重录前的旧候选。应用恢复区的书籍快照也携带检查点。
- 暂停先取消 Workflow 父任务与在途渲染，再等待安全收尾。暂停期间由暂停操作统一刷新并释放运行身份，完成/失败回调不抢先清除它。收尾以控制器的实际终态显示结果：paused 显示暂停，已完成保留普通制作或单段重录的完成提示，单段候选仍须显式采用。准备阶段的取消也保留原任务范围；未通过输入校验的操作不覆盖已有完成状态。检查点写入失败时内存进度标为 failed 并显示存储错误，暂停收尾不显示成功或承诺重新打开后可续作。
- 章节跳过只更新 `chapters.is_skipped`，不重建文本原子、不删除分析与候选；`planRootWindows`、二次消歧、制作选章和导出均显式排除跳过章节。整本 M4B 的阻塞原因不计跳过章节，跳过项仍写入导出记录的 omitted 清单。恢复只清标记，后续分析/制作重新纳入。
- 全书分析重跑时，`user_confirmed` 的标注按 atomID 保留原行（含 id/windowID/assignment/revision），LLM 结果不能覆盖人工确认；二次消歧只处理 `unknown && !user_confirmed`，默认最多 200 次调用并在每个簇前检查 `Task.checkCancellation()`，Workflow 暴露“取消 AI 复核”。
- `AudiobookExportTests` 的章节媒体夹具由 AVFoundation 动态生成合成 AAC，再用 PATH 中的 `ffmpeg` 按产品封装方式生成 QuickTime 章节轨；找不到工具时明确跳过该正例，不下载依赖。测试不使用真实书稿或模型。fake 编码流程必须显式注入 fake 媒体验证器，生产默认验证器始终读取实际媒体。

人物与声音在窄窗口使用锚定其工具栏按钮的原生浮层；集中确认与应用操作保持在可见窗口内，Escape 可关闭浮层。顶部主动作在未准备时执行一键配声，有需确认的风险时打开配声方案。

### 文本准备与历史音频选择

旧作品由 `prepareSelectedBookWorkingText` 显式调用 Store 的准备与 source CAS；打开作品只读取元数据。准备后取消配声建议与试听身份，新文本要求重新分析及确认配声。旧章节的采用版本在切换前形成生产快照，部分制作也保留可选音频版本。

`selectedAudioRevisionID` 同时固定听书与导出预检/准备的生产版本；历史章节、跟读正文与选择状态独立于可编辑工作区。播放器按指定章节版本解析候选并验证资产；返回制作台不会用旧坐标定位新文本。分析状态写入另受 Store 的 run token 保护，暂停先撤销当前 token，过期任务只结束自身进度，不改新任务状态。
