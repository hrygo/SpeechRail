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

## 遗留修复实施（2026-10-15）

用户要求按审查发现继续执行修复。Task 1–5 保留已完成证据；新增任务只处理审查记录中的遗留项。沿用已有工作区和未提交差异，按文件所有权并行，不自动提交。现有授权覆盖直接实施，不重复等待方案确认。

实施裁定：目录拆分/合并仅开放给尚未开始分析、没有制作资产的书籍；已制作作品可重命名章节，但不通过重新分章删除其标注、候选或版本。该限制保护既有作品；若后续支持制作后改目录，应另设计版本映射和撤销流程。

### Task 6: 校验 M4B 容器实际章节

**Files:** `AudiobookMediaVerifier.swift`、`AudiobookExportTests.swift`。

**Interfaces:** `verify(url:expected:)` 以 AVFoundation 读取实际章节元数据；对比所选章节的数量、顺序、标题及按独立帧数计算的起止位置，不能用输入投影代替容器证据。

- [x] 写合成媒体回归：无章节、标题/数量/时序不符被拒绝，真实多章节 AAC 容器通过；先看 RED。
- [x] 实施读取与 fail-closed 验证，保留 codec/时长/摘要校验及 MP3 行为。
- [x] 运行 Export 测试并记录 GREEN。

### Task 7: 恢复中断制作状态并保护章节资产

**Files:** `AudiobookProjectStore.swift`、`AudiobookStoreTests.swift`。

**Interfaces:** 首次启动恢复只处理打开作品库时遗留且未被后续工作更新的分析/制作 `.running`（制作含 `.pausing`），重复资产核查不改变本进程活动任务；`renameChapter(bookID:chapterID:title:)` 只修改标题，`updateChapters(bookID:chapters:)` 对已分析或已有制作资产的书籍拒绝破坏性重分章。

- [x] 写恢复回归：重开库后 running→paused，完成状态不变，同一实例后续活动不被重复 recover 暂停；先看 RED。
- [x] 写目录回归：重命名保留片段/采用版本，初始重分章保留原文覆盖，已分析/已有资产时拒绝重分章。
- [x] 实施事务化状态/目录操作，保持 schemaVersion 和真实库不变。
- [x] 运行 Store / Import 相关回归并记录 GREEN。

### Task 8: 单段重新生成且显式采用

**Files:** `AudiobookProductionController.swift`、`AudiobookProductionTests.swift`。

**Interfaces:** `regenerateFragment(bookID:chapterID:fragmentID:) async throws` 复用正式制作门禁、冻结音色、租约、暂停、音频正规化和提交机制，只生成目标片段的新候选，不自动更换章节已采用版本。

- [x] 写回归：同依赖的已完成片段仍会生成新候选；其他片段不发请求；当前采用版本不变；无效目标/并发/取消不写错误候选；先看 RED。
- [x] 把单段模式接入同一制作生命周期，保持普通制作的复用与首次自动采用。
- [x] 运行 Production / Revision 相关回归并记录 GREEN。

### Task 9: 接入章节整理与重录操作

**Files:** `AudiobookWorkflowModel.swift`、`AudiobookBookWorkspaceView.swift`、`AudiobookChapterPlanner.swift`、`AudiobookWorkflowTests.swift`、`AudiobookImportTests.swift`。

**Interfaces:** 章节列表的“整理章节”次级菜单提供重命名、与上一章合并、在选中段落前拆分；拆分选择正文已有段落，不暴露字节区间。片段提供“重录本段”，共享制作互斥，完成后显示新候选，必须显式“采用此候选”。

- [x] 写工作流回归：菜单能力门禁、章节操作保持选中身份与完整正文、重录不切回其他书、不自动采用。
- [x] 实施原生菜单/输入弹窗和清晰提示，复用现有 Token 与候选比较区域，保留用户确认的并行布局。
- [x] 运行 Workflow / Import 相关回归并记录 GREEN。

### Task 10: 集成验证与记录

**Files:** 本计划、审查记录、架构文档、用户指南。

- [x] 复核修改路径的图谱 coverage 和直接源码；执行一次独立只读交叉审查。
- [x] 运行 `swift test --package-path macos/SpeechRailApp --filter Audiobook`、测试目标覆盖检查、`git diff --check`，必要时隔离 Debug 构建。
- [x] 更新遗留项状态、当前真实支持范围、证据与回退边界，不自动暂存或提交。

### 遗留修复验证记录

- 2026-10-15 15:32:41：Production / Revision 10 项、0 失败；单段重录先以旧复用行为复现 RED，再接入目标片段模式。追加暂停与并发断言后，15:40:23 的 Production 6 项、0 失败。
- 2026-10-15 15:40:23：Store / Export / Import / Workflow / Production 共 44 项，46 处断言失败（其中 rename 占位抛错为 1 处 unexpected）。运行时复现缺失/不符章节被放行、遗留 running 未恢复、旁白章节关联未更新、分析或资产存在时重建目录会丢历史，以及缺少合并和 Workflow 重录入口。各临时占位仅用于得到可执行 RED，交付前必须全部替换。
- 2026-10-15：独立并行任务将上一轮改动纳入 `faa1fabd`，本轮继续在此基线上实施；共享暂存区另被并行任务批量更新，本轮不操作 index、提交或回退他人差异。
- 2026-10-15：另一任务将本轮中间差异纳入 `6ae7b369`，其中仍含 RED 占位；本轮继续替换占位并验证，不把提交存在视为完成。随后 ProductionController / ProductionWiring 出现制作门禁与回执语义的并行变更，已暂停两文件写入，等待用户裁定。独立复核另发现候选提交/章节晋升 await 后缺少取消代次检查，需要在冲突消解后处理。
- 2026-10-15 15:54:07：导出准备校验期间取消回归 2 项、5 处断言失败；已补取消后置门禁、稳定错误映射和舞台产物清理，并让媒体扫描保留取消语义。
- 2026-10-15 15:54:51：模块回归 118 项、1 项人工关键帧导出跳过、1 处失败；Store 10 / Import 6 / Production 6 / Revision 4 / Workflow 15 全部通过。唯一失败为原生双章 M4B 夹具没有可读取的章节，正在修正夹具；真实章节正例尚未通过前不标记媒体验证完成。
- 2026-10-15：用户确认并行制作校验改动已获授权，要求保留并单独记录风险；对应两文件写入冲突已解除，本轮仅修复无冲突的暂停收尾，不覆盖该策略。章节重录入口限制到已有采用版本，避免首个候选没有采用路径；补齐改名取消键和段落选择无障碍语义。
- 2026-10-15 16:00:02：提交后暂停回归 1 项、2 处失败，确认旧任务会返回成功并将 paused 覆盖为 allConfirmedChaptersProduced；通过可注入候选提交器，在真实提交成功后 gate 精确控制取消时点。实现已在提交、章节晋升及最终状态写入后复查运行代次，保留已提交资产并归一化为 paused，待关联回归。
- 2026-10-15 16:06:46：模块回归 118 项、1 项人工关键帧导出跳过、1 处失败。真实双章 M4B、导出准备取消和候选提交后暂停均通过；唯一失败为原有 Cast 集成中专属音色创建后绑定丢失。独立只读审查定位为 saveCharacters 删除全部角色触发 voice_bindings 级联删除，需改为无损同步并补确定性回归。
- 2026-10-15 16:15:43：角色保存的确定性 RED（保留角色绑定变成 nil）修复后，Store 新增回归与原有 Cast 集成共 2 项、0 失败；补充验证删除角色绑定清理、isNarrator 更新、跨书籍/重复 ID 拒绝且数据不变。独立源码审查确认差量删除与 UPSERT 保持原全量列表语义。
- 2026-10-15 16:16:24：最终 Audiobook 模块回归 119 项、1 项人工关键帧导出跳过、0 失败；真实章节容器测试实际执行通过，目标覆盖与工作区/暂存区差异检查通过。16:17 核验隔离 Debug 构建 `BUILD SUCCEEDED`，包含用户要求保留的并行改动；包装脚本完成清理，没有安装、启动、前台 UI 自动化或真实模型调用。
- 2026-10-15 16:19:04：核对并行任务新增的六类群像/宽松制作 Cast 用例后再次执行模块回归，119 项、1 跳过、0 失败。保留并行 Python 测试增补，本任务未执行该用例。确认临时 App 构建根目录已不存在，最终文档更新后再次检查差异。
