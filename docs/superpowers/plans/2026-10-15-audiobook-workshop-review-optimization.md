# 有声书工坊审查与优化 Implementation Plan

> **For agentic workers:** 按文件所有权并行执行，先以定向 fake 回归复现问题，再修改实现；主代理统一运行测试并复核全部差异。不自动提交、发布或安装。

**Goal:** 修复有声书工坊从 TXT 导入到成书导出的确定性缺陷，使流程、算法和用户下一步动作一致。

**Architecture:** 保留现有 SwiftUI → WorkflowModel → 控制器 → SQLite / 受控媒体导出的边界。算法只处理规范化原文区间，用户状态由工作流统一投影；生产媒体校验遇到无法探测的产物必须拒绝。

**Tech Stack:** Swift 6、macOS 26+、SwiftUI、AVFoundation、SQLite、SwiftPM XCTest。

**Spec:** `docs/users/audiobook-workshop.md`、`docs/developers/macos-app-audiobook.md`、`docs/architecture/audiobook-workshop.md`、`docs/developers/macos-app-design-system.md` 及本次用户“直接按审查结果优化”的授权。

## Global Constraints

- 完整保留原文与用户作品，不改持久化格式，不迁移真实数据库。
- 同一文件只由一名执行者写入；发现未知并行改动先核实。
- 不新增依赖，不更改公共服务 API、发布版本、运行配置或模型。
- 定向测试使用 fake backend；不开前台窗口，不做 UI 自动化、真实模型、声学基准、安装或发布。
- 页面复用设计 Token、系统控件、中文任务语言和唯一主动作。
- Xcode App 编译仅使用 `scripts/macos_app_build.sh --configuration Debug`。

## Review Focus

- 章号与标题连写、普通叙事提到章号时，识别目录同时避免误分章。
- 同一本书的长文窗口必须覆盖全部原文，归并结果不得让其他窗口失去角色身份。
- 快速重复操作、挂起时取消和任务重入不得泄漏生成租约或提交旧代次结果。
- 分析后仍有待确认对白时，用户应能定位、解决并继续可制作章节。
- 非空损坏媒体、错误格式、分章时长偏差不得被显示为成功导出。

---

### Task 1: 恢复定向回归可执行性

**Files:** `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookCastTests.swift`

**Interfaces:** 测试夹具 `makeTwoChapterBook(store:root:)` 为静态函数，显式接收临时目录，避免跨 actor 传递 XCTestCase。

- [x] 运行 `swift test --package-path macos/SpeechRailApp --filter AudiobookAcceptanceTests`，确认原有 `@MainActor` 用例因发送 `self` 编译失败。
- [x] 让异步夹具不持有测试对象，保持夹具数据与断言。
- [x] 重跑相同命令，确认 fake 全流程 1 项、0 失败。

### Task 2: 导入与分析算法

**Files:** `AudiobookChapterPlanner.swift`、`AudiobookAnalysisPipeline.swift`、`AudiobookAnalysisPolicy.swift`、`AudiobookCastRegistry.swift`、`AudiobookImportTests.swift`、`AudiobookAnalysisTests.swift`。

**Interfaces:** 保持 `AudiobookChapterPlanner` 既有返回结构、原文区间与哈希语义。

- [x] 写回归：`第一章风起` / `第二章夜雨` 连写标题识别为两章，区间完整覆盖；普通正文提到章号不被误切。
- [x] 写回归：模型只返回部分对白时，缺失的直接对白为 `unknown`，普通叙述仍可安全归旁白；超过 32 个既有角色时，归并候选包含本批证据所在章节的角色。
- [x] 运行新增回归，确认原实现失败。
- [x] 修正章节标题判定，并检查其他已确认分析缺陷。
- [x] 分析策略升为 `audiobook_analysis_policy_v2`：仅在用户下次主动分析时重新计算 v1 检查点，避免继续复用漏标对白的旁白结果；不操作真实数据库。
- [x] 运行受影响 Import / Analysis 测试。

### Task 3: 制作互斥与媒体验收

**Files:** `AudiobookProductionController.swift`、`AudiobookProductionWiring.swift`、`AudiobookFragmentPlanner.swift`、`AudiobookMediaVerifier.swift`、`AudiobookExportController.swift` 与对应 Production / Export / Acceptance 测试。

**Interfaces:** 生产 `AudiobookMediaVerifier.verify(url:expected:)` 严格检查可读取音轨和实际时长；fake 编码器的测试须显式注入 fake 验证，不能依靠生产验证器放行假字节。

- [x] 写回归：非空损坏单文件、损坏分章 MP3 被拒绝；重复启动不产生并发渲染或泄漏租约。
- [x] 运行新增回归并确认失败。
- [x] 在控制器入口建立任务互斥；在媒体探测边界拒绝无法检查的产物，逐章核对实际时长。
- [x] 补初始化期间暂停与导出异步校验期间取消回归，确保暂停不被后续初始化覆盖，取消后不提交目标文件。
- [x] 运行 Production / Export / Acceptance 相关回归。

### Task 4: 用户旅程与工作流状态

**Files:** `AudiobookWorkflowModel.swift`、`AudiobookBookShelfView.swift`、`AudiobookBookWorkspaceView.swift`、`AudiobookWorkflowTests.swift`。

**Interfaces:** 界面只转发意图，异步任务状态和唯一主动作由 WorkflowModel 统一投影。

- [x] 核对目录、分析、角色确认、章节制作、收听与导出各阶段的入口和恢复路径。
- [x] 写回归：同书制作双触发只有一个有效任务；快速选 A→B 后，A 的迟到读取不能覆盖 B 的原文、标注、片段或错误。
- [x] 同步修复换书后角色选择归属，并跟踪实际制作书籍，使暂停动作和进度不会错误显示在另一书下。
- [x] 对已确认阻塞先补状态/行为回归，再修复最小实现与对应用户提示。
- [x] 运行 Workflow 与相关模型回归；页面变更后执行受控 Debug 编译。

### Task 5: 文档、交叉审查与交付

**Files:** `docs/users/audiobook-workshop.md`、本计划与 `docs/developers/audiobook-workshop-review-2026-10-15.md`。

- [x] 按实际行为修正文档承诺，记录各链路审查结果、修复、限制及后续项。
- [x] 主代理复核图谱 coverage 和当前源码，复查差异中的状态、数据、取消、错误与资源边界。
- [x] 运行全部受影响的 Audiobook 模块回归、目标覆盖检查、`git diff --check`；不运行全仓测试套件。
- [x] 交付修改、实测命令/结果、未验证事项和恢复方式；保持未提交状态。

## 执行记录

- 2026-10-15：初始工作区干净；审查期间另有 `e655228e` 发布提交进入当前分支，仅涉及版本材料，与本任务源码修改可分离，已保留。
- 2026-10-15：Task 1 原始编译错误已复现；修正后 Acceptance 基线 1/1 通过。
- 2026-10-15：算法三项回归 RED（3 项、5 处失败）；首次关联回归 19 项中唯一失败命中章标题普通正文反例，已补全行尾锚。旧策略缓存回归 RED（1 项、2 处失败），已升级内部分析策略版本。
- 2026-10-15：媒体与重复制作回归 RED（2 项、6 处失败）；工作流关联回归 RED（10 项、6 处失败），新增三种跨书/章状态竞态均复现。

- 2026-10-15：追加回归复现预检暂停、提交校验取消、编码摘要/准备后替换、旧采样策略复用、废纸篓迟到快照、关闭后误改完成状态。服务原始 PCM 回执与本地产物摘要分开计算，转换前限制输入/输出内存，默认渲染策略升 v2。
- 2026-10-15：工作流测试夹具改为与工作流共用同一 Store actor，避免跨实例标注缓存造成假失败；制作终态延至刷新后同步提交，原有 Cast 集成回归恢复。
- 2026-10-15 15:25:13：Audiobook 模块回归 105 项、1 项人工关键帧导出跳过、0 失败；目标覆盖检查通过。隔离 Debug App 两次构建通过，第二次包含制作收尾修正，临时 DerivedData 已清理；没有安装、启动或 UI 自动化。
- 2026-10-15：用户确认工作台人物卡片/音色选择器并行布局差异来自另一任务，要求保留并纳入编译验证。
