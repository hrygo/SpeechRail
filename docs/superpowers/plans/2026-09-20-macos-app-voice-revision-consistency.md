# macOS App 音色 revision 一致性与文档一致性收敛实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 macOS App 的 Realtime 与 REST TTS 请求都能在有效能力快照下携带正确的 voice/model revision，并将项目相关 active 文档收敛到确定、规范的当前语态。

**Architecture:** revision 由调用方从 `effective_capabilities_v1` 读取并显式 pin；SpeechRail 服务端与 MCP 继续保持无状态。revision 不可用时保留 `nil` fallback，不从名称或时间推断。

**Spec:** `docs/superpowers/specs/2026-09-20-macos-app-voice-revision-consistency-design.md`

**Execution status (2026-09-20, Asia/Shanghai):** completed. App 的 Realtime/REST TTS revision pin
已接通，active 文档已同步；未运行 UI automation、真实音频/模型 smoke、benchmark 或服务运行态操作。

## 工作树与边界

- 保留开始执行前已经存在的 MCP、契约和用户文档未提交改动；不回退、不整文件覆盖。
- 本次代码写入范围限定为 macOS App 的 TTS 请求链路、对应纯 Swift 测试和必要的 active 文档。
- 不修改 Python 服务端 revision 逻辑、MCP 状态模型、模型/运行态配置或用户数据。
- 不运行 UI automation、XCUITest、真实音频/模型 smoke、benchmark 或完整 gate。

## Task 1: 固化失败测试与请求边界

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/RealtimeContractTests.swift`
- Modify or add: `macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift`
- Inspect: `macos/SpeechRailApp/SpeechRailMacControlTests/Package.swift` 或 Xcode test target 配置

- [x] 增加 Realtime wire 断言：`expected_voice_revision` 编码到 `speechrail.tts.create`，缺省时不发送。
- [x] 增加 request options header 断言：voice/model revision 映射到既有 `SpeechRail-*` headers。
- [x] App target 不直接暴露 Realtime actor 给 package tests，因此保留 codec-level regression，并为应用层选择逻辑增加 pure helper test。
- [x] 先运行最小 Swift 测试确认 selector 缺失导致编译失败，再实现 selector 后重跑通过。

## Task 2: 接通 Realtime voice revision

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/RealtimeASRClient.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AssistantSession.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift`

- [x] 为 `RealtimeASRClient` 增加当前 voice revision 状态和初始化参数。
- [x] 在 `sendTTSCreate` 中传入 `SpeechRailTTSCreate.expectedVoiceRevision`。
- [x] 将 `updateVoice` 改为同时更新 voice 与 revision；revision 缺失必须清空旧值。
- [x] 在 `AssistantSession` 增加 `@MainActor` voice revision provider，并在初始连接/换音色时调用。
- [x] 在 `App.swift` 从 effective snapshot 按 id/alias 匹配 voice，要求 `available`、`realtime_speech` operation 和非空 revision；不满足返回 nil。
- [x] 保持现有 model revision provider 和 render receipt provider 的行为不变。

## Task 3: 接通 REST creator revision

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift`（仅在 fake creator signature 需要同步时）

- [x] 将 `SpeechRailCreatorClient.createSpeech` 收敛为唯一的带 `SpeechRailRequestOptions` 的标准 requirement；删除旧 requirement、`SpeechRailRevisionAwareCreatorClient` 和动态 fallback。
- [x] 让 `ServiceAPIClient.createSpeech` 把 options 原样交给既有 `synthesize`，不复制 header 逻辑。
- [x] 让 `AppModel` 试听和作品生成使用所选 `CreatorVoice.revision` 与当前 TTS model catalog revision。
- [x] 更新 `UnavailableCreatorClient`、`UITestCreatorClient` 等替身，保持业务行为不变。
- [x] 增加/扩展 pure Swift 测试，证明 selector 输出的 options 形成正确 headers，并在无 snapshot 时保持 nil。

## Task 4: 收敛 active 文档与索引

**Files:**

- Modify: `docs/developers/macos-app-development.md`
- Modify: `docs/users/api-contract.md`
- Modify: `docs/users/integrations.md`
- Modify: `docs/architecture/quality-voice-capabilities.md`
- Modify: `docs/architecture/voicedesign-capability-and-stability.md`
- Modify: `docs/architecture/generated-voice-registration.md`
- Modify: `docs/operations/capability-quality-acceptance.md`
- Modify: `docs/architecture/README.md`
- Modify: `docs/design/voice-management-and-interaction-contract.md`
- Modify: `docs/superpowers/README.md`

- [x] 在 Realtime/API/App 文档中说明 voice pin、model pin、legacy/nil fallback 和 mismatch 边界。
- [x] 把 revision history、CAS update、rollback、revoke 表述为已实现；保留旧资产迁移、声学身份验收和跨模型兼容性为 pending。
- [x] 将旧 runtime 版本快照明确标为历史证据，不冒充当前运行状态。
- [x] 修复架构目录重复编号、MCP loopback/Bearer 措辞和 voice management legacy/namespaced 权威关系。
- [x] 为本规格与计划补充 superpowers 目录入口；不改写历史 ledger 的历史 checkpoint。
- [x] active/under_review 文档内部链接检查为 0 个断链，`git diff --check` 通过。

## Task 5: 定向验证与交付检查

- [x] 运行相关 Swift pure tests 与 `scripts/macos_app_build.sh --configuration Debug`，不运行 UI test。
- [x] 运行与本次改动直接相关的 Python MCP/contract 静态检查；不重复完整 pytest gate。
- [x] 检查 `git diff --check`、敏感字段和未授权文件改动。
- [x] 复核 `git status --short`，确认并行未提交改动仍在且没有被覆盖。
- [x] 报告实际改动、验证时间、未执行项、剩余风险和回退方式；不宣称真实音色质量或运行态已验收。

## Task 6: 删除 creator 兼容层

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift`
- Modify: `docs/superpowers/specs/2026-09-20-macos-app-voice-revision-consistency-design.md`
- Modify: `docs/superpowers/plans/2026-09-20-macos-app-voice-revision-consistency.md`

- [x] `SpeechRailCreatorClient` 只保留带 `SpeechRailRequestOptions` 的 `createSpeech` requirement。
- [x] `ServiceAPIClient`、`UnavailableCreatorClient`、`UITestCreatorClient` 直接实现同一个标准方法。
- [x] 删除 `SpeechRailRevisionAwareCreatorClient`、旧无 options 方法和运行时 fallback。
- [x] 通过 Debug build、相关 Swift 测试和残留符号扫描验证接口收敛。

## 回退

代码可按 Task 2/3 的文件边界回退到无 pin 的旧 App 行为；文档可按单文件 diff 回退。不会删除服务端 voice revision、模型、运行态配置或用户数据。
