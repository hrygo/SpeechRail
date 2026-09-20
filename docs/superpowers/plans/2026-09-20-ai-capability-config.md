# AI Capability Configuration Implementation Plan

> **For agentic workers:** Execute this plan task by task. Preserve unrelated worktree changes.

**Goal:** 在保持全局 LLM 配置兼容的前提下，为语音助手、会议纪要、AI 提词器提供可选的模块专用 endpoint/model/Key，并让 UI 与运行时共享同一套解析规则。

**Architecture:** 在现有 `LLMConfiguration` 与 `LLMKeychain` 之上增加模块枚举、值类型覆盖、纯解析器和 scoped encrypted-key API；`SessionPreferences` 负责 UserDefaults 持久化与旧 `minutesModel` 兼容，应用入口把 resolved value 注入各功能。Settings 以全局默认作为唯一主路径，使用统一的 design tokens 通过渐进式披露呈现可选模块覆盖。

**Tech Stack:** Swift 6 / SwiftUI / Observation / Foundation / CryptoKit；现有 macOS 26 App target 与 `SpeechRailAppSupport` SwiftPM 测试 target。

**Spec:** `docs/superpowers/specs/2026-09-20-ai-capability-config-design.md`

**Implementation status:** completed in the isolated `feat/ai-teleprompter` worktree on 2026-09-20; focused tests and Debug build passed.

## Global Constraints

- 不改 SpeechRail 公共 REST/Realtime 契约，不改变 Responses 请求形状。
- Key 只能进入现有本机加密 vault；不进入 UserDefaults、日志、prompt、记录库或错误正文。
- 使用 `SpeechRailDesignTokens`，不引入新的颜色/间距/圆角常量。
- 不运行 UI 自动化；只做相关单测、SwiftPM 编译/测试、App Debug build 和 diff/敏感字段检查。
- 保留当前工作树中不属于本任务的改动；不使用 destructive git 命令。

## Task 1: Add the pure module configuration model and resolver ✅

**Files:** `macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift`, `macos/SpeechRailApp/SpeechRailMacControlTests/LLMProviderTests.swift`

1. 先添加失败测试：global default、valid module override、incomplete atomic fallback、module Key fallback。
2. 运行 `swift test --package-path macos/SpeechRailApp --filter LLMProviderTests` 确认 RED。
3. 实现 `LLMModule`、`LLMModuleOverride`、`LLMConfigurationOrigin`、`LLMConfigurationFallbackReason`、`ResolvedLLMConfiguration` 与 `LLMConfigurationResolver`。
4. 重跑同一测试确认 GREEN，并保持 `LLMConfiguration` 现有校验语义。

## Task 2: Persist scoped overrides and keys ✅

**Files:** `SessionPreferences.swift`, `LLMProvider.swift`, `LLMProviderTests.swift`

1. 为 `SessionPreferences` 增加覆盖字典、JSON Data 持久化、旧 `minutesModel` 兼容读取和统一 `resolvedLLMConfiguration(for:)`。
2. 为 `LLMKeychain` 增加 global/module scope 的加密文件 API，保持旧 global API 调用兼容。
3. 添加偏好加载/解析测试能覆盖旧 minutes 语义；不在测试中写真实 vault。

## Task 3: Wire every AI module to resolved configuration ✅

**Files:** `App.swift`, `AssistantSession.swift`, `InnerOSDrawer.swift`, `InnerOSSession.swift`, `MeetingSession.swift`, `MeetingView.swift`, `MinutesGenerator.swift`, `AssistantView.swift`

1. Assistant/Inner OS 使用 `assistant` resolved value。
2. Meeting/Minutes 使用 `minutes` resolved value，并显式传递 apiKey，移除后台生成器对 global Key 的隐式读取。
3. Teleprompter closure 使用 `teleprompter` resolved value。
4. 运行相关 SwiftPM 测试与 App Debug build，解决 Swift 6 隔离/类型错误。

## Task 4: Add token-aligned settings UI ✅

**Files:** `SettingsView.swift`

1. 将全局设置标题和说明改成“全局默认”，保留现有 global 连接检查，并明确所有功能默认继承它。
2. 添加一个默认收起的“高级：按功能自定义”入口；展开后提供三个模块覆盖卡片：开关、endpoint、model、专用 Key、保存/清除、实际生效来源、模块连接检查。
3. 删除重复的旧纪要模型输入 UI，但保留旧存储键和运行时兼容。
4. 已有模块覆盖或回退异常时自动展开高级入口；只使用既有 `settingsSection/settingsRow` 与 `SpeechRailDesignTokens`。

## Task 5: Review, documentation and verification ✅

1. 更新本计划的执行状态和实现说明（不改原始提词器规格的历史结论）。
2. 运行 focused tests、`scripts/macos_app_build.sh --configuration Debug`、`git diff --check`、敏感字段检索。
3. 手工 review：模块作用域是否一致、是否存在隐式跨 endpoint 重试、Key 是否误入持久化、旧配置是否保持、UI 是否显示 fallback。
4. 报告实际改动、验证时间、未运行的 UI 自动化、风险和回退方式。
