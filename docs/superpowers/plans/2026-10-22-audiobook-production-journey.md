# 有声书制作完成与重新制作 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 完成后明确引导收听与导出，普通制作幂等，显式重做可选范围并保留已有音频和历史。

**Architecture:** 沿用 WorkflowModel → ProductionController → Store/RevisionController。普通制作筛选待处理内容；显式重做冻结章节及片段范围到 checkpoint，续作仅复用本任务已保存的候选。界面复用现有听书与导出入口。

**Tech Stack:** Swift 6、SwiftUI、SQLite、XCTest、macOS 26+。

**Spec:** 当前会话用户批准的四种重做范围、完成引导及版本保护方案。

## Global Constraints

- 不修改真实用户作品库、不安装、不改变服务运行态、不执行前台 UI 自动化。
- 保留已有采用音频与历史候选，显式采用才替换已制作章节；不自动提交或推送。
- 现有未提交 contracts 文档属于其他工作，保持不动。
- Sheet 正文独立滚动、固定取消与确认、打开即聚焦并支持 Escape；使用既有 Token。

## Review Focus

- 重启后的普通制作不重复创建任务；失效或损坏音频仍可补做。
- 跳过章节不影响全书完成判断；全部跳过不能误报制作完成。
- 重做暂停、重开后严格保留范围，只复用同任务候选。
- 空范围、跨书或过期片段拒绝执行，不能退化为整书制作。
- 已有采用版本、历史和音频文件在重做、取消和错误后保留。

### Task 1: 制作意图与持久化范围

**Files:** `AudiobookProductionController.swift`、`AudiobookRevisionController.swift`、`AudiobookProductionTests.swift`。

**Interfaces:** 新增可编码 `AudiobookRegenerationScope`（章节 / 片段集合）；`start(..., regenerationScope:)`；checkpoint 保存范围，旧单段检查点仍可读取。

- [x] 写测试：普通制作重放不改 checkpoint/candidates/revisions；重做指定片段仅生成目标；章节重做保留采用版本；暂停续作保留范围。
- [x] 定向运行测试观察失败。
- [x] 实现范围校验、普通制作无变更返回、显式重做与任务内复用，排除跳过章节计算完成状态。
- [x] 定向运行 Production 测试并检查失败数。

### Task 2: 完成投影与工作流

**Files:** `AudiobookWorkflowModel.swift`、`AudiobookProjectStore.swift`、`AudiobookWorkflowTests.swift`。

**Interfaces:** 完成/待处理章节投影、重做范围预览与确认方法；普通制作仅接收符合条件章节；续作透传持久化范围。

- [x] 写测试：全书完成及跳过章节主动作；重复点击不忙碌、不建任务；空范围拒绝；重做结束引导试听采用。
- [x] 观察失败后实现；完成章节主动作改为收听，未完成明确剩余数量。
- [x] 定向运行 Workflow 与 Production 回归。

### Task 3: 工作台引导与范围面板

**Files:** `AudiobookBookWorkspaceView.swift`、`AudiobookBookShelfView.swift`、用户与开发文档。

- [x] 完成状态常驻显示收听、导出；已完成章节不突出制作按钮。
- [x] 更多操作打开范围面板，默认当前章节，支持所选片段 / 当前章 / 勾选章 / 整本；展示章数与片段数并确认。
- [x] 同步用户文档、运行最小定向回归与包装脚本 App 编译，独立审查后处理实质问题。

## Execution record

用户已明确授权按方案实施；在当前功能分支原位执行，不再次索取同一授权。仅定向 fake 测试及必要编译，不执行完整测试套件。新增 checkpoint 可选字段不改变 SQLite schema；回退保留库与资产，旧 App 不续作新范围任务。


### 验证与审查（2026-10-22）

- 原成品重复点击回归先失败（新建任务、重写 checkpoint），修复后通过；待采用候选重复制作、其他章节阻塞当前重做、普通暂停任务静默缩小范围也分别观察到失败并修复。
- 独立只读审查提出三项 P2，上述三个边界均修复并纳入回归；没有延期小项。
- `swift test --package-path macos/SpeechRailApp --filter 'Audiobook(Production|Workflow|Revision|Store|Export|Listening)Tests'`：212 项通过、0 失败、0 跳过。覆盖音频资产验证、旧采用版本保留、范围 JSON 编解码与暂停续作、稿件变更拒绝、成品和待采用候选幂等、完成与跳过章节投影。
- `git diff --check` 通过；`bash scripts/macos_app_build.sh --configuration Debug` 最终通过（`BUILD SUCCEEDED`），包装脚本正常退出并清理临时 App。编译暴露的面板视图类型推断问题已定位到提示组件状态值并修正，选章/选段视图拆分为小组件。
- 实施选择：整本范围包括所有未跳过章，尚无音频的完整章可首次发布；已有章仍只保存候选。代价是部分完成作品的整本重做会首次制作尚未完成章节，面板明确说明并显示范围。
- 实施选择：原任务包含后来跳过的章节时拒绝续作并引导恢复原范围，避免修改同一任务的既定范围。
- 新增恢复计划 `reviewChapterIDs` 属于内存投影；SQLite schema 不变。用户源数据、音频、运行态及已有 contracts 并行改动未处理。
- 尚未验证：真实窗口最小尺寸、滚动、焦点与 Escape、真实音色质量、模型推理或长时稳定性；未安装、提交或推送。
