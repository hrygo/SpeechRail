---
title: "SpeechRail macOS App 有声书工坊开发说明"
status: active
audience: "macOS App 开发者、架构与测试工程师"
version: "1.2.0"
date: 2026-10-15
---

# SpeechRail macOS App 有声书工坊开发说明

本文档说明 macOS App 中「有声书工坊 (`AppRoute.audiobookWorkshop`)」的源码边界、存储模型、全书理解管线、角色与音色确认门禁、流式章节合成、返修/撤销以及 M4B/MP3 导出与 XPC 桥接。

## 1. 模块组成与文件清单

### 1.1 `SpeechRailAppSupport` 核心模型与控制器（可独立进入 SwiftPM 与 Xcode 单测）

- **`AudiobookDomain.swift`**：书籍状态机 (`AudiobookLifecycleState`)、章节、段落、阅读块 (`AudiobookBlock`)、说话人证据 (`AudiobookSpeakerEvidence`)、角色实体 (`AudiobookCharacter`)、音频切片 (`AudiobookFragment`)、候选音频 (`AudiobookCandidate`)、生产版本 (`AudiobookProductionRevision`)、收听进度 (`AudiobookListeningProgress`) 与失败信封 (`AudiobookFailureEnvelope`)。
- **`AudiobookSourceIndex.swift`**：持有规范化 UTF-8 `Data` 与标量起点索引，按半开字节区间 (`[startByte, endByte)`) 读取正文并校验标量边界；SQLite 不重复存储整书正文。
- **`AudiobookTXTImporter.swift` & `AudiobookChapterPlanner.swift`**：编码探测（UTF-8 / BOM / UTF-16 / GB18030）、换行归一化为 `\n`、64 MiB 导入上限与 SHA-256；扫描中英文章节标题，按段落边界拆分或合并相邻章节，校验目录完整覆盖原文。
- **`AudiobookStoreSchema.swift`、`AudiobookAssetJournal.swift`、`AudiobookProjectStore.swift`**：独立 `audiobooks/library.sqlite3`（WAL、`foreign_keys = ON`、`user_version = 1`）与文件事务日志；候选提交通过 staged 文件、数据库登记及恢复核查保护音频资产。
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

## 3. 章节整理与单段重录

- `renameChapter(bookID:chapterID:title:)` 只更新标题。结构编辑由 `updateChapters` 执行，在事务内核实尚未开始分析且没有分析或制作记录，再重建目录与文本原子并同步旁白章节关联。禁止通过结构编辑清空旧分析或音频历史。
- Workflow 的结构编辑投影仅开放分析前的默认路径；正文选区必须落在已有文本原子的起点，界面不要求用户填写字节偏移。异步编辑收尾只更新对应书籍的选择和提示。
- `regenerateFragment(bookID:chapterID:fragmentID:)` 与整章制作共用入口互斥、配声确认、能力快照、资源准入、暂停和音频提交机制。目标必须属于当前规划；即使存在相同依赖的有效候选，也生成新候选，其他片段不发送渲染请求。
- 单段模式不自动发布章节版本，Workflow 仅为已有 `currentChapterRevisionID` 的章节开放重录。任务继续以 bookID / runID 追踪，完成后在已有候选比较区试听并显式采用；普通制作保留相同依赖候选复用及首个完整章节的自动发布行为。
- 候选提交、章节版本发布和制作收尾的异步边界之后复查运行代次。暂停保留已提交候选，并将活动任务状态写为 paused；迟到的旧任务不能把暂停状态覆盖为完成。
- `AudiobookExportTests` 的章节媒体夹具由 AVFoundation 动态生成合成 AAC，再用 PATH 中的 `ffmpeg` 按产品封装方式生成 QuickTime 章节轨；找不到工具时明确跳过该正例，不下载依赖。测试不使用真实书稿或模型。fake 编码流程必须显式注入 fake 媒体验证器，生产默认验证器始终读取实际媒体。
