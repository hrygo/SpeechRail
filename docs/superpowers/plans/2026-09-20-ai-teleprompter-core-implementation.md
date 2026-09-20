# AI 提词器核心能力 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在当前 worktree 的独立分支中交付不依赖 SwiftUI 的 AI 提词器核心：无损导入与分片、时长/预算计算、严格 Prompt/JSON 契约、MapReduce 编排和 v2 文档存储。

**Architecture:** 新增四组纯核心文件放入 `SpeechRailAppSupport` target，并复用当前 worktree 中另一条并行改动已提供的 `TeleprompterTimingPolicy.swift` 与 Domain review/value types。Domain 文件只负责不可变值类型和确定性算法；Prompt 文件负责 wire payload、固定 instructions、schema 和边界校验；Pipeline 文件以 `@Sendable` completion 注入现有 Responses provider，串行执行 Map/Reduce 并在完整覆盖后产出草稿；V2 Store 文件负责版本化、备份和原子保存。现有 `TeleprompterView.swift`、`SpeechRailDesignTokens.swift`、`TeleprompterSession.swift` 和现有 v1 store 保持不改，待 UI 团队接入。

**Tech Stack:** Swift 6.0/6.2、macOS 26、Foundation、Swift Testing、XCTest（仅复用现有测试框架）、现有 `LLMProvider` 的 `/responses` completion 适配。

**Spec:** `docs/superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md`

## Global Constraints

- 只修改 UI 无关核心文件、Package/Xcode source membership、核心测试和本实现计划；不修改 SwiftUI 页面、设计 Token、App UI 接线或真实运行配置。
- 严格 UTF-8 导入，保留 BOM 元数据；拒绝解码失败与 NUL；文件上限 1,048,576 bytes、20,000 source units、参考容量 7,200 秒。
- 原文只能由本地程序分片和恢复；`concat(rawText) == sourceText` 按 UTF-8 bytes 验证，LLM 不生成来源偏移、不改写 source ranges。
- 目标时长为 1–120 个整数分钟；`targetSeconds`、本地 estimate、实际 elapsed 分开保存；无法估时不得填 0 或伪造达标。
- Map/Reduce 只接受闭合、严格 JSON；拒绝未知字段、重复 key、范围缺口/重叠、非法 mode 和不完整响应；协议失败不静默降级为自由文本。
- Map 顺序执行；Reduce 只处理相邻边界一次，patch 必须白名单、revision 匹配后原子提交；任一 Map 缺失不能激活半稿。
- Prompt 中的稿件、背景和术语都是不可信资料；不携带对话历史、ASR、身份、RAG 或外链内容；默认 `store=false`、`stream=false`。
- 所有核心值类型 `Sendable`；后台工作不依赖 `@MainActor`，completion 的 actor 隔离由接入层决定。
- 新增源码和测试必须同时加入 `Package.swift` 与 Xcode project 的对应 Sources/Test Sources；不下载依赖、不启动真实模型或麦克风。

## Review Focus

- CRLF、BOM、emoji/组合字符和 UTF-16 边界必须恢复原文 bytes；由 Task 1 的 importer/source-unit tests 固定。
- 未知数字/外语/代码导致无法可靠估时时，预算仍可用 proxy，但 estimate 必须保持 uncertain；由 Task 1 的 duration/planner tests 固定。
- Map 输出的 speak/review/omit 互斥状态、连续覆盖和空正文规则必须在本地拒绝；由 Task 2 的 decoder tests 固定。
- Reduce 只能修改当前 editable block，过期 revision、重复 ID、patch/review 冲突必须整组拒绝；由 Task 2 的 decoder tests 固定。
- Map 成功但 Reduce 失败、取消或迟到结果不能丢失叶子候选或提交半稿；由 Task 3 的 pipeline tests 固定。

---

### Task 1: 无损来源模型、导入、分片、时长与预算

**Files:**
- Create: `macos/SpeechRailApp/SpeechRailApp/TeleprompterPreparationDomain.swift`
- Create: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterPreparationDomainTests.swift`
- Modify: `macos/SpeechRailApp/Package.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`
- Adopt unchanged: `macos/SpeechRailApp/SpeechRailApp/TeleprompterTimingPolicy.swift` (parallel core dependency; do not rewrite)

**Interfaces:**
- Consumes the existing parallel `TeleprompterTimingPolicy.Pace`/bounds and Domain review/value types; produces `TeleprompterSourceFormatHint`, `TeleprompterImportLimits`, `TeleprompterImportedSource`, `TeleprompterSourceImporter`, `TeleprompterSourceUnit`, `TeleprompterSourceUnitBuilder`。
- Produces `TeleprompterDurationEstimate`, `TeleprompterDurationEstimator` and `TeleprompterTimingPlanner`，供 Prompt 与 Pipeline 使用。

- [ ] **Step 1: Write the failing tests**

  在 `TeleprompterPreparationDomainTests.swift` 覆盖：UTF-8 BOM round-trip、非法 UTF-8/NUL/空输入、扩展名 hint 不影响正文、source-unit UTF-8 拼接恒等、CRLF/emoji 不截断、1–120 分钟校验、已知中英估时、未知读法保持 nullable uncertainty、proxy 权重预算守恒和拆分不复制父预算。

- [ ] **Step 2: Run the focused tests and verify they fail**

  Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparationDomainTests`

  Expected: FAIL because the new core types and algorithms do not exist。

- [ ] **Step 3: Implement the minimal domain core**

  实现严格 UTF-8 importer；用空行/换行/句界优先、grapheme fallback 的 deterministic builder 建立连续 source units，保存 UTF-16 range、raw text、continuation 和计数器标识。实现 `relaxed/natural/brisk` 速率、Han/Latin 互斥计数、未知读法的 `knownPartSeconds + uncertaintyReasons`，以及 `B = 0.95 * target`、estimated/proxy 单一权重模式和 1ms 守恒校验。所有算法都接收 policy 参数，不把 UI 常量放进设计 Token。

- [ ] **Step 4: Run the focused tests and verify they pass**

  Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparationDomainTests`

  Expected: PASS with all importer, source-unit, duration and budget cases green。

- [ ] **Step 5: Commit the task**

  ```bash
  git add macos/SpeechRailApp/Package.swift macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj macos/SpeechRailApp/SpeechRailApp/TeleprompterTimingPolicy.swift macos/SpeechRailApp/SpeechRailApp/TeleprompterPreparationDomain.swift macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterPreparationDomainTests.swift
  git commit -m "feat: add teleprompter source and timing core"
  ```

### Task 2: Prompt、Context、Schema 和严格解码器

**Files:**
- Create: `macos/SpeechRailApp/SpeechRailApp/TeleprompterPreparationPrompts.swift`
- Create: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterPreparationPromptsTests.swift`
- Modify: `macos/SpeechRailApp/Package.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes Task 1 的 source units、timing allocation 和 pace。
- Produces `TeleprompterPreparationPrompt`, `TeleprompterMapInput/Output`, `TeleprompterReduceInput/Output`, `TeleprompterAnnotationInput`，三个 schema builder，以及 `TeleprompterMapDecoder`、`TeleprompterReduceDecoder`。

- [ ] **Step 1: Write the failing tests**

  固定 `preparation.prompt.v3`、`reduce.prompt.v2`、`annotation.prompt.v3` 的关键规则；断言动态正文不在 instructions、schema 是 closed/strict/all-required；构造三组 Map 示例验证完整覆盖、review、omit；拒绝未知字段、重复 key、非连续区间、空 speak、错误 issues；验证 Reduce whitelist、互斥 patch/review 和 revision；验证 prompt 不把 source text 当 instructions。

- [ ] **Step 2: Run the focused tests and verify they fail**

  Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparationPromptsTests`

  Expected: FAIL because the new wire types, prompts and decoders do not exist。

- [ ] **Step 3: Implement the prompt and wire layer**

  用 `JSONEncoder` 生成动态 input；固定 instructions 明确 preserve、Markdown/plaintext 兼容、资料与命令分离、连续 unit coverage、local budget 不自报时长。schema 采用 `additionalProperties=false`、所有对象字段 required、`teleprompter.preparation.v2`/`teleprompter.reduction.v1`/`teleprompter.analysis.v2`。decoder 先解析 JSON object 并检查闭合字段，再做区间、状态、文本和 whitelist 语义校验；不自动修 JSON。

- [ ] **Step 4: Run the focused tests and verify they pass**

  Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparationPromptsTests`

  Expected: PASS with all prompt, schema and decoder cases green。

- [ ] **Step 5: Commit the task**

  ```bash
  git add macos/SpeechRailApp/Package.swift macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj macos/SpeechRailApp/SpeechRailApp/TeleprompterPreparationPrompts.swift macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterPreparationPromptsTests.swift
  git commit -m "feat: add teleprompter prompt contracts"
  ```

### Task 3: MapReduce 准备编排与完整候选装配

**Files:**
- Create: `macos/SpeechRailApp/SpeechRailApp/TeleprompterPreparationPipeline.swift`
- Create: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterPreparationPipelineTests.swift`
- Modify: `macos/SpeechRailApp/Package.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes Task 1 的 `TeleprompterImportedSource`/units/timing plan 和 Task 2 的 prompt builders/decoders。
- Produces `TeleprompterPreparationInput`, `TeleprompterPreparationPolicy`, `TeleprompterPreparationProgress`, `TeleprompterReadingBlock`, `TeleprompterReadingDraft`、`TeleprompterPreparationResult` 和 `TeleprompterPreparationPipeline.prepare`。

- [ ] **Step 1: Write the failing tests**

  使用 fake `@Sendable` completion：验证短稿只发一个 Map；长稿按 24 units/预算有界分窗；每个 Map 完整覆盖；四窗一组只触发相邻 Reduce；patch 应用后全文按 source order 装配；Reduce 失败保留完整叶子且标记 boundary unchecked；Map 失败、取消、迟到结果不激活半稿；Map/Reduce 调用顺序和 local budget 可观测。

- [ ] **Step 2: Run the focused tests and verify they fail**

  Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparationPipelineTests`

  Expected: FAIL because the pipeline and draft types do not exist。

- [ ] **Step 3: Implement the pipeline**

  用确定性 packer 生成连续 Map windows，保留 read-only 前后文但不跨窗口传播生成稿作为事实。每窗校验并保存 leaf candidate 后再顺序运行 Reduce；Reduce editable blocks 只来自当前白名单和当前 revision，patch 原子应用。Finalize 校验来源 coverage、revision、ID uniqueness、用户排除缺口和 unresolved 状态后才返回 `complete`；Reduce 单独失败返回可审阅候选，Map 缺口返回失败。使用 `Task.checkCancellation()` 和 request generation，completion 不绑定 MainActor。

- [ ] **Step 4: Run the focused tests and verify they pass**

  Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparationPipelineTests`

  Expected: PASS with normal, partial failure and cancellation cases green。

- [ ] **Step 5: Commit the task**

  ```bash
  git add macos/SpeechRailApp/Package.swift macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj macos/SpeechRailApp/SpeechRailApp/TeleprompterPreparationPipeline.swift macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterPreparationPipelineTests.swift
  git commit -m "feat: add teleprompter map reduce pipeline"
  ```

### Task 4: v2 文档模型、迁移、备份和原子存储

**Files:**
- Create: `macos/SpeechRailApp/SpeechRailApp/TeleprompterV2Store.swift`
- Create: `macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterV2StoreTests.swift`
- Modify: `macos/SpeechRailApp/Package.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes Task 1 的 source/selection/timing types 和 Task 3 的 `TeleprompterReadingDraft`。
- Produces `TeleprompterV2Bundle`, immutable source/draft/version records, `TeleprompterV2Store.save/load/list`, legacy v1 migration and export helpers。

- [ ] **Step 1: Write the failing tests**

  验证 formatVersion=2 round-trip、source revision immutable、failed validation does not overwrite existing file、`.bak` is created before replacement、legacy `TeleprompterDocumentBundle` source/segments 逐字迁移为 reading version、unknown future version read-only failure、duplicate regenerates IDs and clears run progress、export separately returns original BOM bytes and approved reading text。

- [ ] **Step 2: Run the focused tests and verify they fail**

  Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterV2StoreTests`

  Expected: FAIL because v2 bundle/store types do not exist。

- [ ] **Step 3: Implement the v2 store**

  使用 value types 与 `Codable` 固化 source/selection/draft/version/run records；用临时文件写入、校验、备份旧 bundle、原子替换，任何失败都保留旧文件。迁移只做 exact copy，不做二次清洗；复制文档时重新生成 document/version/block/segment IDs；未知更高版本返回明确错误，不写回。

- [ ] **Step 4: Run the focused tests and verify they pass**

  Run: `swift test --package-path macos/SpeechRailApp --filter TeleprompterV2StoreTests`

  Expected: PASS with round-trip, migration, backup and failure isolation cases green。

- [ ] **Step 5: Commit the task**

  ```bash
  git add macos/SpeechRailApp/Package.swift macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj macos/SpeechRailApp/SpeechRailApp/TeleprompterV2Store.swift macos/SpeechRailApp/SpeechRailMacControlTests/TeleprompterV2StoreTests.swift
  git commit -m "feat: add teleprompter v2 document store"
  ```

### Task 5: 核心接入适配、计划文档和全量验证

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift` only if a non-UI fake/provider construction hook is required; otherwise leave unchanged。
- Modify: `macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift` only if the existing `complete` call cannot carry the new prompt contract; preserve existing callers。
- Add: `docs/superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md` and its two superseded predecessor markers only if they are not already included in the branch history。
- Create: `.superpowers/sdd/2026-09-20-ai-teleprompter-core-implementation/progress.md`

**Interfaces:**
- Consumes Tasks 1–4 public core types。
- Produces a UI-independent adapter surface that the UI team can call later; no SwiftUI dependency and no automatic real-model invocation。

- [ ] **Step 1: Add only the smallest provider adapter test**

  用 fake provider 断言 `TeleprompterPreparationPrompt` 的 instructions/input/schema 可以无损映射到现有 `LLMProvider.complete` 所需的 arguments；如果既有接口已经满足，则不改 `LLMProvider.swift`，仅记录 ruling。

- [ ] **Step 2: Run the package test suite**

  Run: `swift test --package-path macos/SpeechRailApp`

  Expected: PASS for existing and new control tests；不运行 UI automation、真实模型、麦克风或部署命令。

- [ ] **Step 3: Run project-level static checks**

  Run: `git diff --check` and `rg -n "TeleprompterView|SpeechRailDesignTokens" <our changed core files>`。

  Expected: no whitespace errors; changed core files contain no SwiftUI imports or UI symbol references。

- [ ] **Step 4: Review the branch boundary**

  Run: `git status --short --branch`, `git diff --stat main...HEAD`, and `git diff --name-only main...HEAD`。

  Expected: branch commits contain only core files, tests, package/project membership, plan/spec documentation; the other team’s uncommitted UI files remain uncommitted and are not staged。

- [ ] **Step 5: Commit the plan/spec or adapter-only changes and prepare the independent PR**

  ```bash
  git add docs/superpowers/plans/2026-09-20-ai-teleprompter-core-implementation.md
  git commit -m "docs: add teleprompter core implementation plan"
  ```

  Before creating a PR, run the final reviewer/verification pass and attach only the PR for `feat/teleprompter-core-preparation`. Do not merge or push shared branches without a separate explicit action。

## Self-Review Checklist

- Spec sections 5–12 map to Tasks 1–4；UI sections are explicitly deferred to the other team。
- No task depends on an undefined type or method; later interfaces are named in each task’s Interfaces block。
- No free-text fallback, hidden summarization, automatic deletion, or real endpoint/model invocation is introduced。
- No UI file is part of the intended write set；current dirty UI changes are preserved。
