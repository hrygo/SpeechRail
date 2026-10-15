# 有声书制作进度与续作 Implementation Plan

> **For agentic workers:** 按 executing-plans 在当前会话实施；本任务不提交、不安装、不改变服务运行态。

**Goal:** 章节制作持续显示真实进度，用户可暂停，并在重新打开后继续原任务、复用验证通过的音频。

**Architecture:** 保留串行制作和现有候选提交日志。在现有制作快照中补充阶段、时间与重试信息；SQLite 用独立附加表保存任务范围及已提交进度。Workflow 负责跨页展示和续作，视图只读取投影。

**Tech Stack:** Swift 6、SwiftUI、SQLite、XCTest fake renderer。

**Spec:** 当前用户要求；`docs/users/audiobook-workshop.md` 第四步与 `docs/architecture/audiobook-workshop.md` 的资产恢复合同。

## Global Constraints

- macOS 26.0、arm64；复用设计 Token、原生 ProgressView 与既有卡片。
- 不保存书稿、音频或模型输出到进度记录；候选仍使用原有原子提交与校验。
- 保存进度采用附加表，不改写既有表或删除资产；旧程序可忽略附加表。
- 只执行相关 fake 单测与包装脚本编译；不接管前台、不访问真实模型。

## Review Focus

- 准备阶段还没有片段总数时仍显示状态，暂停可取消准备请求。
- 已提交片段计数与持久化一致，失败与暂停不丢失已有音频。
- 继续只处理上次选择的章节；单段重录继续后仍只生成该段。
- 重启后不信任内存或进度数字，按依赖摘要和媒体校验决定复用。
- 切书、暂停与收尾竞态不能把旧任务的快照写入新任务。

### Task 1: 制作快照与任务保存

**Files:** `AudiobookProductionController.swift`、`AudiobookProjectStore.swift`、`AudiobookStoreSchema.swift`、`AudiobookProductionTests.swift`。

- [x] 先用阻塞 fake 验证准备阶段进度和暂停后恢复范围；观察失败。
- [x] 扩展 `AudiobookProductionProgress`；增加 `AudiobookProductionCheckpoint` 与 Store 读写方法。
- [x] 在准备、验证、渲染、退避、保存与组装章节时更新快照；候选提交后持久化检查点。
- [x] 制作测试在 `swift test --package-path macos/SpeechRailApp --filter Audiobook` 中全部通过。

### Task 2: Workflow 续作与常驻进度

**Files:** `AudiobookWorkflowModel.swift`、`AudiobookBookWorkspaceView.swift`、`AudiobookBookShelfView.swift`、`AudiobookWorkflowTests.swift`。

- [x] 先写单段暂停、重建 Workflow 后继续和原章节范围不扩大的回归，观察失败。
- [x] 启动即提供准备快照，运行中持续读取，重开书籍加载已保存检查点。
- [x] `resumeProduction()` 读取原范围并复用已有候选；暂停先取消父任务，再等待安全收尾。
- [x] 常驻进度显示真实片段数、百分比、阶段、章节、耗时、重试与停滞提示；暂停/继续始终可见。
- [x] 运行制作与 Workflow 相关测试并用仓库脚本编译 App。

### Task 3: 文档与交付

**Files:** `docs/users/audiobook-workshop.md`、`docs/developers/macos-app-audiobook.md`、`docs/architecture/audiobook-workshop.md`。

- [x] 同步进度、暂停和续作行为及附加表的回退边界。
- [x] 检查差异、敏感字段和 `git diff --check`，进行独立代码审查。
- [x] 记录实际测试结果；明确未进行 UI 自动化、安装与真实推理。

### Task 4: 审查发现的收尾一致性修复

- [x] 将完成状态、可收听状态与最终检查点放入同一 Store 事务，验证写入失败时共同回滚、重开可续作且不重复生成音频。
- [x] 暂停收尾按实际终态提示，覆盖普通制作和单段重录完成后的刷新竞态。
- [x] 最终事务开始后等待提交结果；提交成功后不再因迟到的暂停降级，提交失败保留可恢复的收尾路径。
- [x] 先确认新增回归失败，再修复并验证，最后重新进行独立代码审查。

## 执行记录

- 基线：`main` 领先 `origin/main` 7 个提交，工作区干净；实施分支 `codex/audiobook-production-progress`。
- 图谱 generation `2026-10-15T06:11:26Z` 对相关源码存在过期与解析缺口，判断改用已定位范围的当前源码。
- 2026-10-15 17:43（Asia/Shanghai）：先测后改，准备阶段进度与单段重开续作两个新增用例均复现失败；暂停回调还复现了完成状态覆盖暂停的竞态。
- 2026-10-15 17:52：恢复区快照保留检查点的新增用例复现失败，补齐快照读写；日期夹具固定到整秒，匹配既有快照 ISO-8601 精度。
- 2026-10-15 17:55：`swift test --package-path macos/SpeechRailApp --filter Audiobook` 共 124 项，1 项人工关键帧导出按默认跳过，0 失败。覆盖准备快照、运行中投影、原书归属、单段续作、提交边界候选复用、进度计时与检查点恢复；不代表真实模型或 UI 验收。
- 2026-10-15：`bash scripts/macos_app_build.sh --configuration Debug` 为 `BUILD SUCCEEDED`，包装脚本正常清理本次临时 bundle；未安装。编译存在既有 warning，不能据此声称零 warning。
- 2026-10-15 18:00：新增退出应用回归，重建 Workflow 后只继续原先选择的章节；Workflow 17 项，0 失败。
- 2026-10-15 18:05：独立只读审查发现准备阶段暂停时，检查点写入失败会被当作暂停成功。临时 SQLite trigger 拒绝写入的用例先复现 3 项断言失败；随后统一保存失败的进度与错误呈现，暂停收尾不再承诺已可靠保存。相关 Production/Workflow 26 项通过，审查复核未发现新的可行动缺陷。
- 2026-10-15 18:07：最终有声书模块回归共 126 项，1 项人工关键帧导出按默认跳过，0 失败；新增用例覆盖退出应用和检查点写入故障。未进行 UI 自动化、真实模型推理或安装。
- 2026-10-15：审查修复后的 App Debug 包装构建再次 `BUILD SUCCEEDED`，未导出或安装；`git diff --check` 通过，本次差异的凭据模式扫描无命中。
- 2026-10-15 18:19：用户要求修复审查发现的收尾问题；两项正式 Workflow 回归先复现 9 项断言失败，覆盖最终记录写入失败后的重开续作，以及普通制作/单段重录完成刷新时点击暂停。回归同时定位到初始章节发布会提前改写制作终态，队列发布时改为保留其任务状态，已发布音频与可收听状态保持可用。
- 2026-10-15 18:23：两项新增 Workflow 回归通过；完成状态与最终检查点由同一 Store 事务提交，暂停按实际终态提示。另补 Store 层故障注入，核验完成状态、可收听状态与检查点共同回滚。
- 2026-10-15 18:31：独立 review 发现最终事务已经提交、控制器尚未返回时仍可降级为暂停。门控 Production 回归先复现 4 项断言失败；最终事务阶段改为等待保存结果，成功才发布完成进度，不再受迟到取消影响。
- 2026-10-15 18:34：稳定源码的有声书模块回归共 139 项，1 项人工关键帧导出按默认跳过，0 失败。本次修复新增 4 个测试方法，分别覆盖最终提交后的迟到暂停、普通制作/单段重录完成刷新提示、持续存储故障后的重开续作及候选复用，以及 Store 完成事务共同回滚；模块总数包含并行角色修复的回归。
- 2026-10-15 18:36：隔离包中的变异验证确认回归有效：恢复章节发布的提前终态写入会触发 4 项断言失败；移除最终事务的暂停保护会触发 3 项断言失败。两次变异均只发生在临时副本，恢复后对应回归通过，工作区源码未作变异。
- 2026-10-15 18:36：再次独立只读 review 未发现新的可行动缺陷，范围为本次制作收尾、事务、状态所有权和四项回归。App Debug 包装构建 `BUILD SUCCEEDED`，临时构建目录已清理；`git diff --check` 通过，本次源码/测试差异的凭据模式扫描无命中。未安装、未提交、未更改服务，未进行 UI 自动化或真实模型验收。
- 2026-10-15 18:37：保留并行新增的版本事务测试后，再次单独执行本次 4 项回归，全部通过；复核产品源码与独立审查快照逐文件一致。
- 并行改动：角色合并与配声确认修复涉及 `AudiobookCastController.swift`、`AudiobookCastRegistry.swift`、`AudiobookCastTests.swift`、Store 的 `saveCharacters/saveCast*` 区段及 Workflow 确认回归，另有文档整理差异；与本次制作收尾区段分离，全部保留。18:36 检查时又出现并行的 `AudiobookRevisionTests.swift` 版本事务故障回归，仅测试文件有变化，源码仍与审查快照一致；这些新增并行回归不在上述 139 项结果内。
- 回退：仅撤销本次代码、测试与文档差异，保留并行角色合并改动；本次没有提交、安装或服务操作。后续若已使用新增检查点表，回退代码时保留数据库、检查点表和音频，旧程序可忽略附加表，但不保证相同的精确范围续作。
