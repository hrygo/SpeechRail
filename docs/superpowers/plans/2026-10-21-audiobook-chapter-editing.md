# 有声书分析前章节编辑 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 分析前手工编辑章节标题及正文，显式保存后的工作修订成为后续唯一输入。

**Architecture:** 复用活动 source 快照和不可变修订机制。Store 负责阶段/版本检查与事务提交，纯计算负责 UTF-8 替换和映射，Workflow 负责编辑生命周期，现有工作区提供编辑面板。

**Tech Stack:** Swift 6、SwiftUI/AppKit、SQLite、现有 XCTest 与 fake LLM/TTS。

**Spec:** `docs/superpowers/specs/2026-10-21-audiobook-chapter-editing-design.md`

## Global Constraints

- macOS 26+ / arm64，现有设计 Token 与原生编辑控件。
- 保留原始参考、旧文本修订及已有音频；不迁移真实作品。
- 不发布、安装、操作服务或进行 UI 自动化；只运行必要定向回归。
- 不自动提交或推送；保留原工作区中的其他改动，在现有独立工作树实施。

## Review Focus

- 非 ASCII 字节长度变化、多次编辑及跨非逐字映射的裁切，必须保持范围可验证。
- 已排除目录、跳过章节和手工目录布局不能被自动分章覆盖。
- 两份草稿、source 切换或分析启动之间的竞争，旧草稿必须失败关闭。
- 保存失败与异步结果迟到，必须保留草稿且释放忙碌状态。
- 原文、旧加工文本与用户正文不同，后续分析及 TTS 必须实际使用用户正文。

### Task 1: 工作文本替换与安全提交

**Files:** Modify `AudiobookSourceIndex.swift`、`AudiobookProjectStore.swift`；Test `AudiobookSourceTests.swift`、`AudiobookStoreTests.swift`（均在现有 macOS App/测试目录）。

**Interfaces:** Store 提供 `chapterEditDraft(bookID:chapterID:) -> AudiobookChapterEditDraft` 和 `saveChapterEdit(_:title:body:) -> AudiobookChapterEditResult`。草稿包含不可变原始标题/正文及 source/layout 身份；结果包含 sourceID 和所选新 chapterID。纯计算替换返回 prepared text 与旧新章节映射；来源 span 增加可选用户编辑来源标记，兼容既有映射。

- [x] 写失败测试：保存标题+正文、多次 Unicode 替换、旧版本/原文不变、跳过与目录保留、仅标题和无变化不换 source；过期草稿/分析开始/磁盘失败拒绝且不切换。
- [x] 通过仓库包装脚本运行相关新测试，确认缺失接口失败。
- [x] 实现精确 UTF-8 替换、单调映射、预算校验、事务内 CAS 与阶段校验、不可变资产登记和缓存失效。
- [x] 运行新增 Store/Source 测试与相关原工作修订/章节结构回归，确认通过。

### Task 2: 编辑生命周期与界面

**Files:** Modify `AudiobookWorkflowModel.swift`、`AudiobookBookWorkspaceView.swift`；Test `AudiobookWorkflowTests.swift`。

**Interfaces:** 消费 Task 1 Store 接口。Workflow 提供 `chapterEditDraft`、编辑中/保存中状态、内联错误，及 `beginChapterEditing()`、`saveChapterEditing(title:body:)`、`cancelChapterEditing()`；保存返回 Bool 供面板决定是否关闭。

- [x] 写失败测试：编辑阻止启动分析/切换作品、取消释放、保存刷新选中章节与内容、失败保留草稿。
- [x] 运行新 Workflow 测试确认失败，实施加载/保存/取消及互斥门禁。
- [x] 增加可见入口与菜单入口，原生标题/正文编辑、脏关闭确认、失败内联提示、键盘与无障碍支持，样式复用现有 Token。
- [x] 运行新增 Workflow 测试与既有章节重命名/拆合相关用例，包装脚本编译 App 检查实际 UI 源码。

### Task 3: 消费者回归与交付

**Files:** Test 现有 `AudiobookAnalysisTests.swift`、`AudiobookProductionTests.swift` 或等价已有消费者用例；Modify `docs/architecture/audiobook-workshop.md`、`docs/developers/macos-app-audiobook.md`。

**Interfaces:** 消费 Task 1/2 活动工作 source，不增加消费者原文读取或动态再加工。

- [x] 加入原文/旧加工/用户正文哨兵回归，记录 fake 分析与 TTS 请求，断言用户内容、来源身份、发音依赖及元数据正确。
- [x] 运行必要消费者与历史音频保护用例，检查结果，不执行真实模型测试。
- [x] 同步架构/开发文档与设计实施状态，记录验证结果、未做人工 UI 验证及回退边界。
- [x] 新鲜只读分支审查；必要修复后重跑受影响测试，检查 diff 和工作区范围，交付未发布改动。
