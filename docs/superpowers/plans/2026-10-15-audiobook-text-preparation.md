# 有声书导入段落与章节规整实施计划

> **For agentic workers:** 按 `executing-plans` 在当前会话实施；遵循用户授权范围，不提交、不安装。

**Goal:** TXT 编码与排版探测后，先整理段落和目录，再核对预览、分析角色。

**Architecture:** 规范 UTF-8 和原文件保持只读。逻辑段落是带原始字节范围的投影，导入预览、分章和后续文本切分共享边界；不改写持久化格式或已有作品。

**Tech Stack:** Swift 6、Foundation、SwiftUI、XCTest；沿用现有 target 与设计 Token。

**Spec:** 用户 2026-10-15 请求；`docs/superpowers/specs/2026-10-14-audiobook-text-segmentation-and-layout-spec.md` §1–3。

## Global Constraints

- Apple Silicon macOS 26.0；不下载模型、不调用真实 AI、不改变服务或安装态。
- 原始字节、canonical UTF-8、SHA-256 和字节区间可追溯；规整只调整逻辑排版。
- 保护空行、缩进段首、独立对白与诗行；不补写缺失篇名，不自动删除注释或作者信息。
- 保留任务开始前的未提交修改；同一处出现新的并行修改时暂停核实。

## Review Focus

- CRLF 的两个 scalar 不得错误改变缩进判定。
- 带脚注和副标题的独立篇名可识别，注释、作者和日期不得成为篇名。
- 数字小节与极短对白、诗句不得混淆。
- 规整预览与后续切分共享段落边界；原始预览可查看。
- 无标题的开篇保持原文，不推测作品名称；章节和 atom 仍完整覆盖来源。

### Task 1: 逻辑段落与分章

**Files:** `AudiobookSourceIndex.swift`、`AudiobookChapterPlanner.swift`、`AudiobookTXTImporter.swift`；回归放入既有 `AudiobookImportTests.swift`、`AudiobookSourceTests.swift`。

**Interfaces:** SourceIndex 提供带 `sourceRange` 的段落及规整预览；ChapterPlanner 消费段落中的标题候选；Importer 在编码探测后创建投影并生成预览。

- [ ] 补充虚构硬折行合集、独立篇名/数字小节、对白/诗行、CRLF 和来源保真回归。
- [ ] 运行 `swift test --package-path macos/SpeechRailApp --filter 'Audiobook(Import|Source)Tests'`，确认新增行为失败。
- [ ] 实施段落规整、保守篇名识别和来源边界复用，重跑同一回归，预期零失败。

### Task 2: 规整核对界面与文档

**Files:** `AudiobookWorkshopView.swift`、`docs/users/audiobook-workshop.md`、`docs/developers/macos-app-audiobook.md`。

**Interfaces:** 消费 Task 1 的段落统计、规整预览与章节；保留现有确认导入动作。

- [ ] 探测后展示「整理段落与章节」，给出段落/折行/章节统计，默认展示规整结果，原始排版渐进披露。
- [ ] 同步用户和开发说明，区分逻辑排版与只读来源。
- [ ] 用 `scripts/macos_app_build.sh --configuration Debug` 编译；不运行前台 UI 自动化。

### Task 3: 验证与交付

- [ ] 运行受影响有声书回归，检查本次 diff 与来源覆盖不变量。
- [ ] 用用户提供的外部 TXT 做本地纯解析检查，仅记录统计和目录，不把书稿复制入仓库。
- [ ] 记录验证结果、未验项目和回退边界；不提交、不安装。

## 执行记录

- Pre-flight: Task 2 仅消费 Task 1 的只读投影；无需数据库或运行态变更。
- Ruling: 用户已明确要求优化该导入路径，直接在当前会话实施；相关既有文件先保存任务前快照，避免混入已有改动。
