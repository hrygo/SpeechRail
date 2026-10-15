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

- [x] 补充虚构硬折行合集、独立篇名/数字小节、对白/诗行、CRLF 和来源保真回归。
- [x] 运行 `swift test --package-path macos/SpeechRailApp --filter 'Audiobook(Import|Source)Tests'`，确认新增行为失败。
- [x] 实施段落规整、保守篇名识别和来源边界复用，重跑同一回归，预期零失败。

### Task 2: 规整核对界面与文档

**Files:** `AudiobookWorkshopView.swift`、`docs/users/audiobook-workshop.md`、`docs/developers/macos-app-audiobook.md`。

**Interfaces:** 消费 Task 1 的段落统计、规整预览与章节；保留现有确认导入动作。

- [x] 探测后展示「整理段落与章节」，给出段落/折行/章节统计，默认展示规整结果，原始排版渐进披露。
- [x] 同步用户和开发说明，区分逻辑排版与只读来源。
- [x] 用 `scripts/macos_app_build.sh --configuration Debug` 编译；不运行前台 UI 自动化。

### Task 3: 验证与交付

- [x] 运行受影响有声书回归，检查本次 diff 与来源覆盖不变量。
- [x] 用用户提供的外部 TXT 做本地纯解析检查，仅记录统计和目录，不把书稿复制入仓库。
- [x] 记录验证结果、未验项目和回退边界；不提交、不安装。

## 执行记录

- Pre-flight: Task 2 仅消费 Task 1 的只读投影；无需数据库或运行态变更。
- Ruling: 用户已明确要求优化该导入路径，直接在当前会话实施；相关既有文件先保存任务前快照，避免混入已有改动。
- 实施：编码与排版探测后建立带来源范围的逻辑段落，再规划目录；预览、工作台和角色分析共用规整文本，来源与音频版本仍基于只读字节。
- 2026-10-15 本地解析用户样本：809 个段落、连接 1,412 处折行、8 个目录项、3,220 个 atom；原始字节及段落/章节/atom 覆盖校验通过。开篇缺失标题不推断，注释与作者信息保留。
- RED→GREEN：导入准备/居中篇名、CRLF 与对白边界、分析请求文本均先复现再修复。独立只读审查另发现封面借后续篇名正文误判和纯空白导入，两项故障回归先红后修；按章切换原始/规整预览也有回归。
- 最后模块验证：`swift test --package-path macos/SpeechRailApp --filter Audiobook`，2026-10-15 18:54（Asia/Shanghai），154 项、1 项人工关键帧导出跳过、0 失败；包含并行作品库调整后的源码。
- Debug 验证：`scripts/macos_app_build.sh --configuration Debug` 于 18:52 成功，临时构建目录已清理。随后另一个聊天对作品库音频核验增加协作式让步；已核实来源并保留，复用其 18:53 成功的相同包装脚本构建证据，302 个源码、测试与构建输入哈希与当前文件一致，临时构建目录已清理。
- 不执行 UI 自动化、真实 AI/TTS、安装、模型或服务操作。已有作品不自动重整目录；新分章在重新导入时应用。改动可按任务前快照逐块恢复，须保留其他聊天的提交和并行修改，不使用整文件还原。
- 并行 Git：另一个用户聊天执行了 `commit all`，将本任务部分中间代码一并提交到 `9cca490b`；本任务未执行暂存、提交或改写历史，后续修正留在工作区。
- 用户追加语料回归（2026-10-15 19:02）：5 本 TXT × 8 种编码/换行组合，共 40 个用例，38 通过、2 个 CRLF 用例因 161 scalar atom 超限失败；另确认目录层级、含“○”回目和粘连/重复回目问题。新增可复跑工具，未改生产解析实现；详见 `docs/audits/2026-10-15-audiobook-text-corpus-regression.md`，先前单本样例与模块通过不代表该语料的章节规整整体通过。

## 追加修复：语料回归与外置测试数据

用户已授权修复漏章、层级、重复标题与 atom 超限，并要求真实重复正文只提示确认、不删除；五本小说不提交仓库，外置回归可跳过且不在 CI 执行。

### Task 4: 来源保真的章节识别与预算修复

**Files:** `AudiobookSourceIndex.swift`、`AudiobookChapterPlanner.swift`；独立复现只写 `AudiobookImportTests.swift`、`AudiobookSourceTests.swift`。

**Interfaces:** 对粘连回目建立虚拟段落边界，字节区间不变；目录只取最高可信层级；重复标题之间只有分隔符时合并目录入口，正文重复的章节仍保留；`buildAtoms` 的 CRLF 吸附服从 160 scalar 预算。

- [x] 独立编写最小虚构复现并确认 RED，涵盖“○”、篇名与小章、粘连标题、重复标题与 CRLF。
- [x] 实施修复，定向回归转绿；常规测试不读取五本小说。

### Task 5: 重复内容确认

**Files:** `AudiobookTXTImporter.swift`、`AudiobookWorkshopView.swift`，必要时只在 WorkflowModel 的导入入口补确认门禁，不改并行选角/制作。

**Interfaces:** Preview 暴露整章重复内容提示与显式确认状态；确认保留重复内容后才导入，原始字节、目录覆盖和重复正文始终保留，不改持久化格式。

- [x] 用虚构重复正文验证提示、未确认与已确认状态。
- [x] 复用现有通知组件与系统 checkbox，提供核对提示；不运行 UI 自动化。

### Task 6: 外置可选语料回归

**Files:** `scripts/check_audiobook_text_corpus.py`、`macos/SpeechRailApp/AudiobookTextCorpusTool/main.swift`、`macos/SpeechRailApp/Package.swift`、仅元数据的语料 manifest、工具跳过策略单测、测试说明与审计记录。

**Interfaces:** runner 默认跳过；仅显式启用并提供仓库外完整语料时运行，CI 无条件跳过，缺失数据跳过；manifest 只保存文件名、哈希与章节期望，不含书稿，不下载数据。章节正确性进入机器断言，避免只验证覆盖。

- [x] 验证默认、CI、缺失语料的跳过策略及有效显式启用。
- [x] 用五本实际小说完整运行 40 个格式用例，检查期望目录、重复提示、字节保真与 scalar 上限。
- [x] 运行有声书模块回归及包装脚本 Debug 编译，核验输入稳定并记录结果；不安装、不提交。

### 追加修复验证记录

- 五本 × 八种格式共 40 用例全部通过，目录顺序与数量、重复整章提示、完整来源覆盖和 160 scalar 上限均进入机器断言；源小说与验证输入前后哈希一致。
- 导入/来源的 33 项虚构单测、Python runner 的 9 项策略单测与定向 Ruff 检查通过。新增短对白开篇、破折号正文和跨行正文开头的故障用例均先红后绿。
- 独立语料工具引用 Swift Package 的生产模块，默认/缺失语料/CI 可跳过，不提交或下载小说。
- Debug App 包装构建两次通过且临时目录清理；扩大模块首次 196 项、1 跳过、4 条失败。并行选角更新后复核为 199 项、1 跳过、1 失败，剩余 fake 端到端用例缺失能力提供者，不能宣称整个模块全绿。详情、证据位置及回退边界见 `docs/audits/2026-10-15-audiobook-text-corpus-regression.md` 的修复后复验。

### Task 7: 端到端能力依赖修复

用户追加授权修复剩余端到端测试，并完整重跑有声书模块；只改 `AudiobookAcceptanceTests.swift` 与验证记录，保留生产校验和并行修改。

- [x] 定向复现缺失能力提供者的失败，再为选角/制作注入同一 fake renderer 的能力快照及隔离音色目录。
- [x] fake 声音采用可合成模式、合法 revision 与语速声明；绑定从快照解析身份，实际渲染请求核验相同 revision 与中性参数。
- [x] 端到端定向用例通过；完整有声书模块于 2026-10-15 20:00 通过（200 项、0 失败、1 项人工关键帧导出跳过），9 项语料工具策略测试通过。
- [x] 328 个验证输入与五本小说的哈希前后一致，小说未进入仓库；未提交、安装或运行 UI 自动化。

### Task 8: 选择性提交与独立验证

用户追加授权提交本次规整、回归修复及相关测试和文档。提交按规整修复与外置语料回归分组；混合文件只暂存本任务代码块，选角、制作及其他聊天的并行改动留在工作区，小说正文始终在仓库外。

共享暂存区被并行任务批量更新后，本任务使用独立 index 和已验证的候选树，将提交保存至本地分支 `codex/audiobook-text-preparation`；当前分支及共享暂存区由原任务继续使用。

- [x] 端到端测试改经工作流依赖装配入口注入 fake renderer，能力夹具使用线协议声明系统预设身份，不依赖并行公共构造参数。
- [x] 导出仅含本任务改动的候选树，使用独立构建缓存完整运行有声书模块：2026-10-15 20:13，166 项、0 失败、1 跳过。反向 CRLF 预算条件检出预期超限，恢复后转绿。
- [x] 9 项外置语料工具策略测试与定向 Ruff 检查通过；五本源小说哈希不变，真实语料最近完整结果为 40/40。
