---
title: "有声书工坊全流程优化审计与实施记录"
status: active
date: 2026-10-19
audience: "产品、架构与 macOS 开发者"
---

# 有声书工坊全流程优化审计与实施记录

本轮从用户旅程、用户体验、功能完备度与算法四个层面审计 macOS「有声书工坊」，并落地一组低风险、可回归的改动。审计基线为 `f39f9eea`，工作区含本轮改动；所有结论以当前代码与测试为准。

## 1. 方法与证据边界

- **读取范围**：`docs/users/audiobook-workshop.md`、`docs/architecture/audiobook-workshop.md`、`docs/developers/macos-app-audiobook.md`、`docs/audits/2026-10-17-speechrail-voicestudio-competitive-research.md`、`docs/audits/2026-10-17-speechrail-elevenlabs-absorption-plan.md`，以及 `macos/SpeechRailApp/SpeechRailApp/Audiobook*.swift`。
- **实测**：`swift test --package-path macos/SpeechRailApp --filter Audiobook`，293 个测试通过（1 个跳过，0 失败）；完整 `swift test --package-path macos/SpeechRailApp` 659 个测试通过；`scripts/macos_app_build.sh --configuration Debug` 成功。
- **未实测**：真实模型的长篇分析/合成质量、真实 FFmpeg 导出、前台 UI 观感、VoiceOver 顺序和键盘走查。项目规则禁止未经逐次授权的 UI 自动化，本轮未运行。
- **外置小说语料未能复跑**：`公开小说-2026-10-14` 本机目录中 5 份 TXT 的 `stat` 可读且大小与清单一致，但目录枚举与文件读取会阻塞（文件当时为云端占位状态）。为避免触发下载，本轮没有执行 `scripts/check_audiobook_text_corpus.py`，也没有把旧语料结果当作本轮证据。目录页识别因此只由确定性虚构夹具覆盖，真实长篇的分章回归仍需在语料恢复本地内容后重跑。
- **证据分层**：下文「已具备」来自代码与测试；「文档承诺」来自 active 文档；「建议」是基于两者差距的推断，不代表已实现。

## 2. 审计结论摘要

### 2.1 用户旅程

导入 → 整理分章 → 全书分析 → 角色配声 → 章节制作 → 逐段返修 → 收听 → 导出这条主链路已经闭合，且每阶段有明确主动作、暂停/续作和崩溃恢复。最影响完成率的问题不在主链路缺失，而在少数**死路与不可恢复操作**：

1. 非 UTF-8 的 GB18030 书稿在探测阶段直接抛错，导入面板不会出现，用户无法选择编码；文档却承诺支持 GB18030。
2. 带目录页的书稿会把目录条目当成章节，产生多个只有标题的重复章节，真正正文被挤进最后一章；分析后不能删除章节。
3. 收听时间码在播放中不前进，暂停时书签仍记录片段开头；`bookmarkAutosaveIntervalSeconds` 常量存在但未被使用。
4. 换声、合并/拆分章节、MP3 同名目录覆盖都缺少影响范围确认或撤销。
5. 分析/制作的失败原因只在内存，重开作品后只剩「需重试」。

### 2.2 功能完备度

相对「完整制作一本有声书」，当前缺口中价值最高的是：

| 优先级 | 缺口 | 证据 |
|---|---|---|
| 高 | 发音集完全未接入：服务端契约与 App 客户端方法已存在，制作请求未带 `SpeechRail-Pronunciation-Set` | `ServiceAPIClient.swift:687-745`、`AudiobookProductionWiring.swift:123-127` |
| 高 | 仅支持 TXT，无 EPUB | `AudiobookTXTImporter.swift`、`docs/plans/2026-10-17-speech-quality-and-latency-controls.md:228` |
| 中高 | 无法跳过版权页/目录章；M4B 要求全书就绪 | `AudiobookExportController.swift` 全量校验 |
| 中 | 导出编码长任务不可取消 | `AudiobookExportController.swift` 有 `cancel(requestID:)`，App 未暴露 |
| 中 | 数字/日期/单位不展开，制作无开关 | `src/speechrail/.../tts_text_normalization.py` |
| 中 | 无校对备注/待办清单 | 无对应模型 |

### 2.3 用户体验

- 首屏与主动作基本遵循「傻瓜化」：书架唯一主动作、工作台单主按钮、高级操作收进菜单。
- 仍存在内部术语外露：更早的「回执/摘要」「模型版本（期望…）」「n 个窗口」等；本轮统一了收听时长与倍速文案，其余留待文案专项。
- 悬停独占的段首「更换说话人」、角色卡 `onTapGesture`、倍速缺少 `accessibilityValue`，键盘与读屏可达性不足。
- 三处空态缺失：角色为空、导出全未就绪、听书无成品章节。

### 2.4 算法

审计确认的主要问题（未全部在本轮修复）：

- 全书分析检查点复用每个窗口线性扫描全部历史窗口，最坏 O(W²)。
- 制作候选复用每个片段线性扫描全书候选，O(F×C)。
- 3 个以上相邻同名标题只合并一半。
- `AudiobookInvalidation` 用来源区间作 `uniqueKeysWithValues` 键，重复区间会直接崩溃。
- 片段规划只校验「有标注」，不校验标注是否覆盖全部正文原子；缺标注会静默漏读。
- 人工确认的说话人归属可能被重跑分析覆盖（窗口完成与标注写入分两个事务）。
- 二次消歧忽略取消与代次，`try?` 吞错后继续发请求。
- 制作时能力读取在重试循环之外，一次暂态失败会中止整本。
- `targetFragmentScalars` 只进入策略摘要，不参与片段合并；改它会导致全量重合成却产出相同片段。
- `AudiobookSourceIndex` 为每个标量保存 Int64 偏移，10M 字符书稿内存占用高。

## 3. 本轮已实施

### 3.1 导入：编码歧义不再阻断，目录页不再变成章节

- **编码**：`AudiobookTXTImporter` 在无显式编码且字节可严格解码为 GB18030 时，返回 GB18030 临时预览并置 `requiresEncodingConfirmation = true`；可疑 UTF-8（C1 控制符）同样标记。导入面板显示提示，切换编码失败时错误显示在面板内而不是被 sheet 遮挡。
- **目录页**：`AudiobookChapterPlanner.plan` 新增 `tableOfContentsRanges`。连续 ≥3 个章名行之间只隔空白/页码/点引线，且存在目录标记或后文同名标题时，整段从章名候选中移除，并写入相关章节的 `excludedRanges`；仅含目录的合成「开篇」并入下一章。目录字节仍被章节覆盖，但不生成 atom、不进入分析/制作/朗读。
- **预览**：`textPreview` 与首屏预览按排除区间读取；`AudiobookSourceIndex` 新增 `readableRanges`、`normalizedText(in:excluding:)`、`text(in:excluding:)`。
- **同名标题**：3 个以上相邻同名标题现在合并为一个目录入口。
- **验收**：新增 5 个导入测试（含目录标记、无标记但后文重复、点引线页码、短编号章节不误判、三重同名标题）；导入套件 28 个测试通过。

### 3.2 收听：真实时间码与自动书签

- `AudiobookListeningController` 在播放期间按 200 ms 采样 `SharedPlaybackOwner.progress`，换算片段与章节已播时间；按 5 s 自动写书签，暂停、离开、试听抢占前先应用当前采样。
- 采样只接受向前推进的值，seek 后的旧回调不会把时间轴拉回。
- 时间码与倍速统一由 `AudiobookDisplayFormat` 生成：修正 `1.25x` 被 `%.2g` 显示为 `1.2x`，超过 1 小时显示 `h:mm:ss`。
- **验收**：新增 3 个测试（进度推进+自动书签、无进度回调时暂停保留 seek 位置、排版函数）；收听套件 6 个测试通过。

### 3.3 换声影响范围确认

- 在人物与声音面板选择新声音时，若该角色有对白，先显示确认对话框：对白数、涉及章节数、重做范围与「已采用版本和历史候选保留」的说明；取消不改变任何绑定。
- 无对白的角色保持直接绑定，避免多余打断。
- 未改候选/采用语义，也未新增持久化字段。

### 3.4 算法与性能

- 分析检查点复用改为按 `(primaryAtomIDs, policyFingerprint, configurationDigest)` 建索引，去掉 O(W²) 扫描。
- 制作候选复用改为按 `fragmentID` 分组，去掉 O(F×C) 扫描。
- `AudiobookInvalidation` 对重复来源区间改为分组后取首个，避免崩溃。
- 上述改动不改变复用判定条件与产物，只改变查找方式。
- 文档对齐：分析窗口改为与代码一致的 4,000 标量 / 256 atom / 每侧 500 标量；弱引语说明改为“纯叙述默认旁白，含对白但漏标保留待确认”，同步架构图。

### 3.5 书级发音规则（schema 5）

- 新增 `AudiobookPronunciationController` 与 `AudiobookPronunciationSheet`：按书维护不可变词表 revision，保存后缓存于 `pronunciation_bindings`；渲染请求固定携带 `SpeechRail-Pronunciation-Set: <set_id>@<revision>`。
- 片段依赖只并入实际命中词条的哈希；改词表只失效命中片段，其他已生成音频继续复用。
- 冲突（409）不覆盖远端：界面置 `needsRefresh` 并要求先刷新。刷新先从摘要取最新 revision，再按该 revision 拉词条，可恢复本地缓存缺失或别处更新的场景。
- 迁移新增表与 `chapters.is_skipped`，先备份后单事务推进；6 个发音测试覆盖保存/header、冲突刷新、删除、校验、按片段失效和 v4→v5。

### 3.6 章节跳过、导出与生产门禁

- `chapters.is_skipped` 只切标记：分析窗口、二次消歧、制作选章与导出都排除跳过章节；恢复不重建原子、不删除历史。整本 M4B 不因跳过章节阻塞，导出清单仍记录 omitted 原因。
- 片段规划新增覆盖校验：以非格式、未排除的正文字原子为基准，缺失或重复标注直接拒绝，避免静默漏读。
- 导出准备可在编码阶段取消；M4B 文件与 MP3 目录在替换前都要求显式确认，取消不改动目标。
- 重跑分析保留 `user_confirmed` 标注；二次消歧默认最多 200 次调用并在每簇前检查取消，界面提供“取消 AI 复核”。
- 分析失败持久化 `analysis_failure_json`：只存低基数错误码、可行动中文提示、时间与失败窗口序号，不存服务错误正文/原文；重开作品时书架提示与工作台横幅仍可见，取消或成功会清除。
- **验收**：新增跳过分析/制作、覆盖校验、发音端到端 header、失败码持久化、EPUB 导入等断言；有声书 306 个测试通过（1 个既有跳过），全量 XCTest 1817 个（1 个既有跳过）与 Swift Testing 659 个通过；App Debug 构建通过。

### 3.7 EPUB 只读导入

- 新增 `AudiobookEPUBImporter`：纯 Swift ZIP 中央目录预检（加密/压缩方式/条目数/解压总量/路径穿越），系统 `ditto` 解压到临时目录后再拒绝符号链接与越界路径；只读 `container.xml`、OPF 与 spine XHTML，忽略脚本/样式，不保存原始压缩包。
- 书名/作者从 OPF 读取，正文转纯文本后复用 TXT 的规范化、分章、目录页识别与重复内容检查；导入面板对 EPUB 隐藏编码切换，按钮改为“导入书稿/导入电子书”。
- DRM、损坏包、缺失 container/spine、空正文都返回可行动错误；2 个测试覆盖正常 spine/实体/脚本忽略与缺失 container 拒绝。

## 4. 未实施与建议顺序

1. **可访问性**：段首换声控件已常驻并补听书倍速无障碍值；角色卡键盘操作仍未逐一验收。
2. **内存**：`AudiobookSourceIndex` 的标量偏移表在 10M 字符书稿上占用较高，可改为按需构建或分块索引；需先做真实长篇测量。
3. **真实长篇语料回归**：本轮仍未执行外置小说语料回归（文件为云端占位符，读取会触发下载），不能据此声称真实书稿导入/分析质量通过。

## 5. 回退

- 发音与跳过涉及 schema 5：回退到 schema 4 需要保留 `pronunciation_bindings` 与 `chapters.is_skipped` 列（旧代码忽略即可），不能以旧备份覆盖新作品；新增表/列均为附加，不删除用户数据。
- 其余改动可逆向 `AudiobookTXTImporter`、`AudiobookChapterPlanner`、`AudiobookSourceIndex`、`AudiobookListeningController`、`AudiobookDomain`、发音/导出/制作控制器、相关视图与测试。
- 目录页识别只影响新导入的预览与章节规划；已导入作品不会被回填或改写。若需禁用目录识别，移除 `detectTableOfContents` 调用即可恢复旧分章，不需要数据迁移。
