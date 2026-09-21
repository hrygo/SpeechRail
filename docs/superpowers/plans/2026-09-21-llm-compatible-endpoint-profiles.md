# LLM Compatible Endpoint Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 SpeechRail 以通用 OpenAI-compatible 模式支持任意端点/model ID，同时以显式 adapter 保留 OpenCode Go 与本机模板端点的 thinking 关闭规则。

**Architecture:** 在 `LLMConfiguration`/`LLMModuleOverride` 增加显式 `LLMCompatibilityMode`，默认 `.openAICompatible`。请求层由 `LLMProvider` 根据 mode 和 operation 生成标准或 provider-specific 的最小字段；业务层不再知道 provider 细节。连接检查按 Chat/Responses operation 执行，`/models` 只做可选信息源。

**Tech Stack:** Swift 6、SwiftUI、XCTest、macOS 26、MacPaw/OpenAI 0.5.1、UserDefaults Codable。

**Spec:** `docs/superpowers/specs/2026-09-21-llm-compatible-endpoint-profiles.md`

## Global Constraints

- 保持任意合法 HTTP(S) endpoint 与任意非空 model ID，不做 host/model 推断或白名单。
- SpeechRail 所有 LLM 请求不主动开启 thinking；通用模式只用标准禁用字段，专有字段只由显式 mode adapter 注入。
- 不记录 API key、Authorization、完整 prompt、原始音频、完整转写或完整响应。
- 不操作仓库外的本机代理服务、配置或凭据。
- 保留已有未提交改动；不使用 destructive git 命令。

## Review Focus

- 旧 Codable override 缺少 `compatibilityMode` 时必须默认为通用模式：Task 1 的 persistence test。
- 通用请求不得泄漏 `x-opencode-session`、`thinking`、`chat_template_kwargs`：Task 2 的 request-shape tests。
- thinking 控制被拒后不能无限重试，也不能把一个 mode 的拒绝污染另一个 mode：Task 2 的 retry/key tests。
- `/models` 不可用或未列出 alias model 时仍需探测实际操作：Task 3 的 check tests。
- 设置页的全局与模块 override 必须原子地保存 endpoint/model/mode：Task 4 的 binding/config tests。

### Task 1: Add the compatibility configuration contract

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift:124-303`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SessionPreferences.swift:59-218`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift`

**Interfaces:**
- Produces `LLMCompatibilityMode`, `LLMOperation`, and mode-aware `LLMConfiguration`/`LLMModuleOverride` values.
- Missing persisted mode decodes as `.openAICompatible`; all existing initializers remain source-compatible through default arguments.

- [x] **Step 1: Write failing tests** for mode round-trip, missing Codable key migration, atomic module resolution, arbitrary endpoint/model values, and operation labels.
- [x] **Step 2: Run the focused XCTest** and verify the new symbols/expectations fail before implementation.
- [x] **Step 3: Implement the enums, configuration fields, custom Codable migration, UserDefaults persistence, and legacy minutes inheritance.** Keep URL syntax/credential validation unchanged.
- [x] **Step 4: Run the focused XCTest** and verify the contract tests pass.

### Task 2: Isolate thinking control and provider-specific request decoration

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift:81-121,435-1179`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift`

**Interfaces:**
- `SpeechRailOpenAIMiddleware` receives compatibility mode and an include/omit decision.
- `LLMProvider.completeJSON`, `complete`, `stream`, background requests, and probes use the same mode mapping.

- [x] **Step 1: Add failing request-shape tests** for generic Chat/Responses, OpenCode Go, local template mode, and the one-time rejected-control retry.
- [x] **Step 2: Run only the new request-shape tests** and confirm they fail against the current unconditional OpenCode/template fields.
- [x] **Step 3: Implement mode-aware middleware, standard `reasoning_effort=none`/`reasoning.effort=none`, native OpenCode fields, local template fields, and mode+operation scoped rejection memory.** Keep `max_tokens` and JSON validation behavior unchanged.
- [x] **Step 4: Run all `LLMProviderTests`** and verify no request contains an unintended provider-specific field.

### Task 3: Make capability checks operation-specific and model-list tolerant

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift:312-353,1046-1235`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SettingsView.swift:317-356`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SettingsComponents.swift:121-142`
- Test: `macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift`

**Interfaces:**
- `LLMProvider.check(configuration:apiKey:operation:)` returns `notChatAPI` or `notResponsesAPI` according to the requested operation.
- `/models` failure/missing ID never short-circuits a valid operation probe.

- [x] **Step 1: Add failing tests** for Chat-only checks, optional `/models`, alias model IDs, and module-to-operation routing.
- [x] **Step 2: Run the check tests** and verify current Responses-only behavior fails the Chat-only cases.
- [x] **Step 3: Implement Chat and Responses probes, optional model listing, operation-aware settings invocation, and user-facing result text.** Preserve explicit model-error classification.
- [x] **Step 4: Run the focused provider and settings-support tests** and verify request URLs/body shapes and classifications.

### Task 4: Expose the mode in configuration UI and synchronize current docs

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/SettingsAssistantPane.swift:87-157,407-493,560-570`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AssistantView.swift:49-53,188-195,1191-1238,1287-1301`
- Modify: `docs/superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md:301-305`
- Modify: `docs/superpowers/plans/2026-09-21-teleprompter-chat-completions.md`

**Interfaces:**
- Global and module-specific UI bindings persist endpoint/model/mode together.
- Quick setup defaults to generic OpenAI-compatible mode; OpenCode Go is an explicit choice.

- [x] **Step 1: Add UI/source tests or compile-time coverage** for global/module mode bindings where existing test conventions allow; keep UI automation out of scope.
- [x] **Step 2: Implement mode pickers, plain-language descriptions, quick-setup persistence, and update stale current docs.** Do not alter historical archive evidence.
- [x] **Step 3: Build the macOS target** and verify settings sources compile with the new enum/bindings.

### Task 5: Full verification and review

**Files:**
- Verify: all files above plus current git diff

- [x] **Step 1: Run `xcodebuild` Debug build and the focused XCTest suite after the final code change.**
- [x] **Step 2: Run `git diff --check` and inspect the diff for secrets, unintended proxy references, and accidental edits to unrelated user changes.**
- [x] **Step 3: Check coverage/index freshness for all changed code paths and report verified, unverified, and runtime-not-touched items.**
