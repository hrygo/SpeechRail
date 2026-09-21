# 提词器工作流可靠性实施计划

> 本文件记录已执行的代码工作与仍待授权的质量验收。方案落盘不等于真实模型质量或 UI 视觉/交互已通过验收。

**Goal:** 降低模型承担的协议负担，让局部生成失败形成完整、可审阅的候选，并可准确定位失败原因。

**Architecture:** App 内 Swift typed workflow；分组与改写分离，程序持有来源与版本。模型结果经本地校验、有界恢复后原子装配，不引入 Python 服务或 Agent 框架。

**Tech Stack:** Swift 6.4、macOS 26+、现有 MacPaw/OpenAI SDK、现有本机 Store。

**Spec:** [ADR-0020](../../decisions/0020-teleprompter-workflow-reliability.md)；保留[终版规格](../specs/2026-09-20-ai-teleprompter-final-spec.md)的产品边界与质量门槛。

## Global Constraints

- Apple silicon macOS 26+；App 层负责 LLM 编排。
- preserve：不以目标时长授权摘要、删事实、扩写或翻译。
- 使用现有 SDK 和 adapter；不自动更换 provider/model，不新增服务或下载模型。
- 日志不含原文、完整 prompt、响应正文、密钥或实际未知字段名。
- 不改持久化格式；若确有必要，补充迁移和恢复设计后实施。
- 聚焦单元验证使用合成数据、fake provider 和临时目录；真实模型、UI 自动化、构建安装与运行态操作遵守项目专项授权。
- 不自动 commit/push；实施前重新检查并行改动。

## Review Focus

1. 协议拒绝与合法等义改写混淆：任务 1 验证两者分流。
2. 一窗失败掩盖来源缺失或全量回退：任务 3 验证完整覆盖与真实终态。
3. 编辑、取消后迟到结果覆盖现有稿件：任务 3/4 验证 generation、revision 和保存屏障。
4. strict 不支持被误识别为认证/网络失败：任务 2 验证错误分类和总调用上限。
5. 新拆阶段放大延迟、请求次数或模型事实错误：任务 5 按同一语料记录成本与质量，禁止用回退刷新成功率。

## Task 1：保留失败证据，修正诊断与文档基线

**Files:** 修改 `macos/SpeechRailApp/SpeechRailApp/TeleprompterPreparationDomain.swift`、`TeleprompterPreparationPrompts.swift`、`TeleprompterPreparationPipeline.swift`；测试位于 `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterPreparationPromptsTests.swift` 与 `TeleprompterPreparationPipelineTests.swift`。

**Interfaces:** decoder 向 workflow 返回含固定 code、stage、字段路径、组序号的类型化错误；UI 消费可操作状态，日志消费脱敏分类，不消费错误原文。

- [x] 用有效 Map/grouping/rewrite fixture 覆盖重复键、错版本、范围缺口、越界、模式矛盾、未知/重复 block ID 与 protected literal；诊断码不再统一为 `preparation_error`。
- [x] 保留 schema/来源校验硬边界；把正文候选的风险留给审阅状态。合成输入覆盖数字、单位、原文 literal 与源覆盖。
- [x] 给恢复请求传固定诊断码与字段路径；fake completion 已验证恢复提示不包含上轮响应正文或未知值。
- [x] 修正 preparation 与 annotation 的文档边界，并同步终版规格、局部编号、revision 与 promptVersion。
- [x] 运行对应聚焦测试；未声称已复现此前真实模型事件的具体根因。

## Task 2：输出模式能力边界

**Files:** 修改 `macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift`、`App.swift`；测试 `macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift`。

**Interfaces:** provider adapter 接收 schema 定义及输出能力，产出经 transport 检查的 JSON 和实际模式诊断；不把服务端 strict 等同于业务验证成功。能力身份按 ADR-0020 §3。

- [x] fake transport 验证 strict 请求体含 `json_schema/strict`，默认 JSON mode 仍发送 `json_object`；schema 不只存在于 prompt。
- [x] 使用当前锁定的 MacPaw/OpenAI SDK 类型构造请求，差异集中在 adapter。
- [x] schema 不支持只触发同端点一次模式退回；429 不触发该分支，测试覆盖请求次数与错误类别。
- [x] strict 为调用方显式选择的能力，不在页面打开时探测或静默切换 endpoint/model；已知 OpenCode Go Chat gateway 由 adapter 直接使用 JSON mode。
- [x] 提词器生产调用对一般兼容端点显式首选 strict；同一 endpoint/model/compatibility/operation/schema 摘要的明确拒绝会被内存记忆，未知端点的 `response_format type is unavailable` 只退回一次 JSON mode，避免每个窗口重复试错。
- [x] 执行 `LLMProviderTests`，检查请求正文、调用次数及异常类别。

## Task 3：拆分模型职责与局部恢复

**Files:** 修改 `TeleprompterPreparationPrompts.swift`、`TeleprompterPreparationPipeline.swift`、`TeleprompterPreparationDomain.swift`（均位于 `macos/SpeechRailApp/SpeechRailApp/`）；对应 PreparationPromptsTests、PreparationPipelineTests、PreparationDomainTests。

**Interfaces:** 分组输出只含局部半开区间；程序据此产生不可变来源组。改写输出只按程序 ID 提交 mode/text/issues，不返回或改变来源范围。workflow 输出完整候选及 AI/原文回退/待审阅计数。

- [x] 建立 grouping/rewrite schema 和 decoder 回归：分组不返回正文，改写拒绝未知/重复 ID、额外来源字段和无效 mode。
- [x] 定义 `teleprompter.grouping.v1` 与 `teleprompter.rewrite.v1` 并更新 App 接线；保存稿件仍使用原 Store 格式。
- [x] 分组失败使用确定性来源边界构造组；改写只处理固定组，并按窗口批处理。
- [x] 覆盖多窗口局部失败：成功窗口保留，失败窗口逐字回退并待确认；全回退标记未完成 AI 整理。
- [x] 不接受裁剪/正则提取的“有效 JSON”；结构不可信的响应走边界明确的局部回退。
- [x] Reduce 失败保留叶子候选；未确认回退块不会被 Reduce 擅自改写，输出仍统一重算时长。
- [x] 保留取消、认证/拒绝、版本与来源校验的停止边界；恢复预算不因拆阶段重复翻倍。
- [x] grouping/rewrite 恢复改为阶段级：rewrite 失败只重试 rewrite 并复用原 grouping；暂态错误遵守 `Retry-After`。
- [x] 运行 Preparation 聚焦回归并检查来源覆盖、终态、请求计数和实际装配正文。

## Task 4：审阅与保存屏障接线

**Files:** 修改 `macos/SpeechRailApp/SpeechRailApp/TeleprompterSession.swift`、`TeleprompterView.swift`；必要时调整现有 result 类型。复用现有 Store；测试 `TeleprompterV2StoreTests.swift` 及实际承载 session 测试的现有文件。

**Interfaces:** session 接收完整候选与待确认项，只在 generation/source revision 匹配时提交；采用动作沿用保存屏障。UI 不暴露 map/JSON/token 等实现词。

- [x] 修改 UI 前读取设计系统规则；复用既有状态条、审阅动作和语义 Token。
- [x] 部分/全量回退显示不同的审阅提示，不能把回退显示成全部 AI 完成。
- [x] 回退项沿用待确认 disposition 与采用门槛；session 通过重新加载 draft blocks 推导本地回退状态。
- [x] generation/source revision 与保存屏障保持原有边界；完整 SwiftPM 回归和 App target 构建通过。
- [x] 已完成确定性状态接线验证；视觉和交互验收仍单列，未把编译或单元测试当作 UI 通过。

## Task 5：协议、文档与质量闭环

- [x] 同步终版规格相关章节与 `docs/developers/macos-app-teleprompter.md`，并保持“已实现”和“待质量验收”分离。
- [x] 使用合成输入验证实际 schema、提示词字段、decoder；拒绝、截断、重复键和局部回退均有回归。
- [x] 运行 Preparation、LLMProvider 聚焦测试及完整 SwiftPM 测试；App target Debug 构建通过。
- [ ] 按 §15.2 完成真实同稿同模型的 Map 对照、strict/JSON mode holdout 记录。
- [ ] 真实模型验收获得对应授权后执行；报告首轮/恢复后/整稿完成率、AI 内容占比、回退占比、人工事实审阅、延迟和 token。严重事实变更阻断发布；测试通过不能替代模型质量验收。
- [ ] 发布或安装按专项流程另行执行；撤回时协调恢复代码和 wire，保留用户稿件及版本。不自动提交、部署或重启服务。

## 本次方案复审记录

- [x] 修正“json_object 就是实现错误”的判断：终版规格明确允许 JSON mode。
- [x] 修正“移除所有 text 输出”的建议：只从分组阶段移除，口语化阶段保留。
- [x] 将 strict-only 改为能力感知模式，保留已配置 JSON mode 端点可用性。
- [x] 区分局部模型失败与取消/版本/来源/保存错误，避免所有异常统一 fallback。
- [x] 部分结果与完整提交兼容：完整覆盖由原文补齐，原子提交候选且要求审阅。
- [x] 纳入统一调用预算、质量分母和拆阶段成本，禁止把原文回退计成 AI 成功。

## 实施状态（2026-09-21）

- [x] Task 1：诊断、恢复提示脱敏、规格/功能文档基线。
- [x] Task 2：JSON mode 默认、strict opt-in、OpenCode Go 兼容策略与能力拒绝分类。
- [x] Task 3：grouping/rewrite 两阶段协议、局部原文回退、覆盖与计数回归。
- [x] Task 4：session 审阅状态、采用屏障与回退提示接线。
- [x] Task 5：协议/文档同步、聚焦测试、完整 SwiftPM 测试与 Xcode build。
- [ ] 真实模型质量、holdout 对照、真人事实审阅、UI 视觉/交互验收；这些需要单独授权与样本/设备条件。

本轮未提交 commit、未安装/发布、未改变服务运行态。
