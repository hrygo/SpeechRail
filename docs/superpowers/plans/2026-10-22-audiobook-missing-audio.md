# 有声书只补缺失音频 Implementation Plan

> **For agentic workers:** 使用 executing-plans 在当前会话实施；用户已要求直接实施，无需再次确认方案。

**Goal:** 明确分开只补缺失音频、更新待更新音频和重新制作，执行前展示范围与影响。

**Architecture:** Controller 生成只读制作预览，按资产实测区分缺失、现有与待更新音频；确认后仅执行预览中的片段。Checkpoint 持久化操作意图及片段依赖，续作复核原范围，更新和重做保留已有采用版本。

**Tech Stack:** Swift 6、SwiftUI、SQLite、XCTest、macOS 26+。

**Spec:** 当前用户明确要求：只补缺失保留所有已有音频（含待更新）；更新和重做独立；执行前看清范围和影响；直接实施。

## Global Constraints

- 保留已有未提交修改；不改真实作品库，不安装、不接管 UI、不操作服务，不提交或推送。
- 只补缺失跳过可核验的任何已有音频；文件不存在或损坏属于缺失，未核验内容不冒充可用音频。
- 不能因片段边界变化而重复制作已有音频；历史范围无法判定时保守保留并提示需单独更新。
- 公共网络接口和 SQLite schema 不变；新增可选 checkpoint JSON 字段。所有缺少冻结计划的旧任务（含重做）拒绝自动续作并提示重新预览。
- 使用现有 Token、有界可滚动 Sheet、固定确认与取消、初始焦点和 Escape。

## Review Focus

- 已有旧设置音频、已有但未采用候选：补缺失不能发渲染请求或改写采用版本。
- 损坏资产：补缺失允许修复；更新不能顺便补缺失。
- 用户确认后稿件、片段依赖或章节范围变化：执行拒绝，不能扩大到新增缺失。
- 暂停重启：保留意图和片段集合，同任务结果复用；无工作时不创建任务。
- 首次章节完成可形成初始版本；已有成品永远通过显式采用更新。

### Task 1: 制作计划与执行边界

**Files:** `AudiobookProductionController.swift`、`AudiobookProductionTests.swift`。

**Interfaces:** `AudiobookProductionIntent`、`AudiobookProductionPlan`、`previewProduction(bookID:chapterIDs:intent:)`；`start` 接收意图与批准计划，checkpoint 保存计划。

- [x] 先写并观察失败：补缺失保留旧音频、更新排除缺失、零工作不建任务、损坏修复、冻结范围与续作。
- [x] 实现资产分类、默认 missingOnly、更新独立选择、计划校验和 checkpoint 恢复。
- [x] 定向 Production 回归通过。

### Task 2: 预览与明确入口

**Files:** `AudiobookWorkflowModel.swift`、`AudiobookBookWorkspaceView.swift`、`AudiobookBookShelfView.swift`、`AudiobookWorkflowTests.swift`。

**Interfaces:** `productionDraft`、`prepareProduction(intent:chapterIDs:)`、`confirmProduction`；所有用户制作入口先预览。

- [x] 写并观察失败：预览不渲染，取消不改任务；确认严格只执行目标；更新候选仍需采用。
- [x] 顶部默认只补缺失；更新、重新制作独立次级动作；按章与全书提供清楚范围说明。
- [x] 单段重录先进入既有范围确认；恢复显示原任务意图和范围。

### Task 3: 验证与交付

**Files:** 用户与开发文档、当前计划。

- [x] 同步三种动作的使用方法、缺失与损坏定义、旧任务恢复边界。
- [x] 运行定向 Production / Workflow / Revision 测试和包装脚本 App 编译；独立只读审查并处理实质问题。
- [x] 记录实际结果和未验证项。无需测试真实模型或前台 UI。

## Execution ledger

- 现有功能分支原位实施，快照保留本次任务前的未提交改动；本任务不提交。
- Pre-flight: Task 2 依赖 Task 1 的计划类型，确认、执行和 checkpoint 使用同一计划，不复制范围规则。

- 2026-10-22：只读预览与冻结计划覆盖补缺失、更新和重做；零目标不建任务；任务恢复不扩大范围。缺失含不存在/损坏的资产；已有可用音频即使待更新或尚未采用也跳过，历史范围无法映射时保守保留。
- 已观察失败再实现：缺失/更新计划 API 初始编译失败；旧重做任务缺少冻结计划的回归在修复前出现 4 处断言失败。
- 独立只读审查发现旧显式重做检查点缺少冻结依赖仍可续作（P2）。已统一拒绝无计划的旧任务，并为程序直接重做冻结计划；审查者复核通过，无新增实质问题。
- 定向验证：`swift test --package-path macos/SpeechRailApp --filter 'Audiobook(Production|Workflow|Revision)Tests'`，144 tests，0 failures。覆盖旧音频保留、独立更新、损坏修复、预览取消只读、依赖变化拒绝、任务范围冻结及旧任务恢复边界。
- 未执行真实模型、服务运行态变更、安装或前台窗口自动化。真实窗口的滚动、键盘焦点与 Escape 尚未实测；编译不代替这些交互验收。
- 保留任务前全部未提交改动；未提交/推送。回退仅回退本任务增量，保留作品库和资产；旧 App 不续作含新计划字段的任务。
- App 编译：`bash scripts/macos_app_build.sh --configuration Debug`，退出码 0，`BUILD SUCCEEDED`；临时 App 由包装脚本清理，未安装。`git diff --check` 通过。

### 审查建议修复与合入（2026-10-22）

- 用户明确授权先修复两项 Optional 再提交合入主干，覆盖此前“不提交”的实施阶段约束。
- 将正文范围规划与已有资产分类分开；显式重做不核验无关历史音频。内部执行计划改为必填，删除没有计划的旧选择路径；checkpoint 保留可选字段用于识别并拒绝旧任务。
- 新增 fake 符号链接回归：旧实现读取历史候选而失败，修复后可重做且保留该历史链接。独立源码审查通过。
- 本地定向 Production / Workflow / Revision / Store / WorkspacePerformance 回归通过，包装脚本 Debug 编译通过；没有安装或操作真实作品库。
- 主干保护要求线性历史，必需检查为 Quality Gates 和 Gate Summary；通过 PR 检查后再合并，其他任务的未提交改动保留。
