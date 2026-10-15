---
title: "SpeechRail macOS App 有声书工坊开发说明"
status: active
audience: "macOS App 开发者、架构与测试工程师"
version: "1.1.0"
date: 2026-10-15
---

# SpeechRail macOS App 有声书工坊开发说明

本文档说明 macOS App 中「有声书工坊 (`AppRoute.audiobookWorkshop`)」的源码边界、存储模型、全书理解管线、角色与音色确认门禁、流式章节合成、返修/撤销以及 M4B/MP3 导出与 XPC 桥接。

## 1. 模块组成与文件清单

### 1.1 `SpeechRailAppSupport` 核心模型与控制器（可独立进入 SwiftPM 与 Xcode 单测）

- **`AudiobookDomain.swift`**：书籍状态机 (`AudiobookLifecycleState`)、章节、段落、阅读块 (`AudiobookBlock`)、说话人证据 (`AudiobookSpeakerEvidence`)、角色实体 (`AudiobookCharacter`)、音频切片 (`AudiobookFragment`)、候选音频 (`AudiobookCandidate`)、生产版本 (`AudiobookProductionRevision`)、收听进度 (`AudiobookListeningProgress`) 与失败信封 (`AudiobookFailureEnvelope`)。
- **`AudiobookSourceIndex.swift`**：只读 mmap / 分块游标与 UTF-8 半开字节区间 (`[startByte, endByte)`) 读取器。校验 UTF-8 标量边界，按字节区间切片而不在 SQLite 或内存中复制整书正文。
- **`AudiobookTXTImporter.swift` & `AudiobookChapterPlanner.swift`**：流式编码探测（UTF-8 / BOM / UTF-16 / GB18030）、换行归一化为 `\n`、64 MiB 导入上限、流式 SHA-256，以及单遍扫描识别中英文章节标题、前记/序章合并、超长无标题长文在句末安全切分。
- **`AudiobookStoreSchema.swift`、`AudiobookAssetJournal.swift`、`AudiobookProjectStore.swift`**：独立 `audiobooks/audiobooks.sqlite3`（WAL、`foreign_keys = ON`、`user_version = 1`）与文件事务日志。所有数据库先写、文件后删或文件先 staged、数据库切换后再清理的操作均通过 `asset_journal_entries` 保证崩溃可恢复。
- **`AudiobookAnalysisPolicy.swift`、`AudiobookAnalysisPrompts.swift`、`AudiobookCastRegistry.swift`、`AudiobookAnalysisPipeline.swift`**：按 `LLMModule.audiobook` 解析专用/全局大模型配置；两级结构化 JSON 解析（章节窗口对话归属 + 跨章角色别名合并）；低置信度台词降级为 `needsConfirmation` 并默认回退旁白音色，绝不猜测说话人。
- **`AudiobookAnalysisProgress.swift`**：分析进度观测的闭式事件（`AudiobookAnalysisEvent`）、快照投影（`AudiobookAnalysisProgress`）与有界诊断缓冲。事件只带序号、计数、耗时、token 数与低基数错误码，不带原文、prompt、转写、密钥、路径或实名；投影侧按 `runID` + 序号丢弃过期/跨 run 事件，百分比单调不回退。管线在规划、提取、归并、标注、拆窗重试与终态处发射事件；`LLMProvider` 观测经 `callDiagnostics` 汇入，runID 与 LLM 观测 sessionID 一串到底。
- **`AudiobookAnalysisProgressRailView.swift`**：确定性进度轨道的纯展示视图（阶段 + n/N + 百分比 + 心跳 + 重试/停滞提示 + 开发者诊断折叠区）。输入只有不可变快照、时钟 tick、事件数与暂停回调，不读 `AppModel`，可经 `ImageRenderer` 离屏渲染做视觉回归；文案走同文件的纯函数（心跳三档阈值与 `AudiobookAnalysisProgressLimits` 一致），工作台只做薄委托。
- **`AudiobookCastController.swift`**：角色重命名、合并/拆分、单条台词改派、音色匹配打分、一键试听样本生成，以及进入批量合成前的「旁白确认 + 必选角色确认 + 试听通过」门禁。
- **`AudiobookFragmentPlanner.swift` & `AudiobookInvalidation.swift`**：在 280 UTF-8 字节上限内按句末/分句标点切分合成片段，并计算精确的 `(chapter, block, fragment)` 脏标记传播（改单句只标脏该句，改角色音色只标脏该角色所属片段，旁白与其他角色已生成的 WAV 原样复用）。
- **`AudiobookDependencies.swift` & `AudiobookProductionController.swift`**：串行 TTS 合成队列、能力快照版本锁定 (`effective_capabilities_v1`)、8 MiB 单响应流式护栏、24 kHz → 48 kHz 确定性线性重采样、峰值与静音检测、原子 WAV 落盘与断点续作。
- **`AudiobookRevisionController.swift`**：单段重录产生新 `AudiobookCandidate`，显式点击「采用」才原子切换 `adoptedCandidateID` 并写入 `revision_history`，支持一键撤销回到上一版本。
- **`AudiobookListeningController.swift`**：复用 `SharedPlaybackOwner` 唯一播放句柄，跨切片无缝预取切换、倍速记忆、章节/段落跳转、断点续听持久化，以及进入收听或试听时自动暂停后台合成队列。
- **`AudiobookMediaVerifier.swift` & `AudiobookExportController.swift`**：导出前校验全部采用切片的磁盘存在性、WAV 头、帧数与 SHA-256；写入 `<app_home>/audiobooks/exports/<request_id>/request.json` 并通过 `SpeechRailControlAgent` 执行 `speechrail media encode-audiobook`，导出完成后用 `AVURLAsset` 做时长、音轨与章节数二次校验。
- **`AudiobookWorkflowModel.swift` & `AudiobookProductionWiring.swift`**：`@MainActor @Observable` 顶层编排器，将书架、工作台四阶段、收听模式与 `AppModel` / `SharedPlaybackOwner` / `SpeechCreationAdmission` 连接起来。

### 1.2 SwiftUI 视图层（仅在 `SpeechRailApp` target 编译）

- **`AudiobookWorkshopView.swift`**：顶层容器与页面头部动作、状态结论横幅、模式切换（书架 / 制作工作台 / 沉浸收听）及导入面板。
- **`AudiobookBookShelfView.swift`**：书架网格/列表、引导空态、每本书的进度胶囊与直达动作（「继续制作」「收听」「导出」）。
- **`AudiobookBookWorkspaceView.swift`**：左侧章节列表、中央四阶段工作区（1. 目录与分章、2. 角色与音色、3. 章节制作、4. 导出成书）、右侧 360pt `.speechRailInspectorColumn()` 详情面，以及 `720pt` 段落返修弹窗 (`Layout.Sheet.prominentWidth`)。
- **`AudiobookListeningView.swift`**：文随声动沉浸收听视图，左侧章节目录、中央同步高亮正文与段落级「重录本段」快捷返修入口、底部固定传输控制条。

### 1.3 Python 媒体导出子系统 (`src/speechrail/media/`)

- **`manifest.py`**：校验 `audiobook_media_export_v1` 请求清单、64 MiB 体积上限、路径穿越与符号链接拦截、所有输入 WAV 的 64 KiB 分块 SHA-256 核对。
- **`encoder.py`**：定位固定 `ffmpeg`/`ffprobe` 可执行文件，流式拼接章节 PCM 为 48 kHz 单声道 WAV，生成 FFMETADATA 章节轨并编码为 `.m4b`（AAC + `chpl` 章节）或分章 `.mp3`，再用 `ffprobe` 校验输出流、采样率、时长容差与章节数。
- **`commands.py` & `cli.py`**：提供 `speechrail media encode-audiobook --app-home <path> --request-id <uuid> --format json`，供 `SpeechRailControlAgent` 调用并记入 `OperationJournal`。

## 2. 关键不变量

1. **原文零改写与字节区间真源**：导入生成的 `source.txt` 只读封存，章节、段落、阅读块与音频切片一律通过 `[startByte, endByte)` 指向 `source.txt`，数据库不存储冗余全文拷贝。
2. **角色与音色双层解耦**：LLM 理解只产出 `CharacterID`，合成只读取 `CharacterID -> VoiceBinding`。更换角色音色只重算该角色的片段签名，不重跑 LLM。
3. **单播放源与合成礼让**：试听、返修对比、成书收听全部经由 `SharedPlaybackOwner`；开始收听或试听时若后台合成正在运行，控制器先在当前切片边界安全暂停合成，避免抢占音频设备与本地模型。
4. **数据库与磁盘资产强一致**：任何 WAV 或导出产物的写入、替换与清理都先登记 `AudiobookAssetJournal`，未采用的当前候选与撤销历史引用的候选受保护，不会被误删。
