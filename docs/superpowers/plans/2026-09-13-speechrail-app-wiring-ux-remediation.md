# SpeechRail App 接线与 UI/UX 修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复管理控制台的 operation 终态、模型应用门禁和运行态反馈，并把监控、诊断及共享文案收敛到已批准的 macOS 26 设计语言。

**Architecture:** 保持现有 SwiftUI App → `SpeechRailControlKit` → XPC control agent → managed Python CLI 的边界。operation 仍由 Agent 作为唯一事实源；App 只消费 typed snapshots、派生展示状态并通过既有 `/health`、`/metrics` 和 XPC 请求刷新，不新增服务端管理 API。

**Tech Stack:** Swift 6、SwiftUI macOS 26、Swift Charts、XCTest/XCUITest、XPC、Python 3.12 既有模型 catalog/status/prepare。

**Spec:** `docs/superpowers/specs/2026-09-13-speechrail-app-management-observability-design.md` 与 `docs/superpowers/specs/2026-09-13-speechrail-macos26-console-chrome-redesign-design.md`

## Global Constraints

- 保持 `ControlConstants.schemaVersion == 1`，不破坏已有 ControlKit wire 字段。
- 不修改公开 HTTP 路由，不让 App 直接下载模型、读取模型路径、日志、音频或凭据。
- App target 保持 macOS 26-only，不添加 macOS 14 兼容 UI fallback。
- 模型 apply 的事实仍由 managed Python 的事务、smoke 和 rollback 决定；UI 不承诺“无缝热重载”。
- 保留用户当前工作树中的并行修改；本任务只修改接线和 UI/UX 必需文件。
- 用户已要求暂停自动化测试；本轮不执行测试、构建、安装、签名、公证或服务重启，只做静态检查。

---

### Task 1: 固化 Agent operation 终态顺序

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentOperationStore.swift`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/AgentCoreTests.swift`

- [ ] 添加一个可在 runner 完成后继续发出 progress 的 fake runner 和回归测试。
- [ ] 让 `updateProgress` 只接受 `accepted`/`running` 状态，终态和中断状态拒绝迟到的进度事件。
- [ ] 复查 `finish`、`cancelOperation`、journal 持久化和 `operationStatus` 的终态一致性。

### Task 2: 修复模型档位就绪门与应用操作反馈

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift` only where operation refresh semantics are required

- [ ] 按选中 profile 汇总 catalog artifact 与独立 `diarization-coreml` status，Balanced/Quality 未验证时禁用 apply。
- [ ] 避免分人状态对 Light 档位无条件展示，并避免 aligner 在两个区域重复表达。
- [ ] 让 `OperationBar` 根据 `modelPrepare`/`profileApply` 使用正确标题、阶段和恢复动作。
- [ ] 修正 apply confirmation，明确会停止、切换、启动并进行健康检查；下载确认显示估算容量和空间影响。

### Task 3: 完成监控数据派生与部分失败表达

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/RuntimeMetricsSampler.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`

- [ ] 接入服务已发布的 TTS TTFA、实时 active sessions 和窗口 counter rate；缺字段继续显示 `—`。
- [ ] health/metrics 分别保留最近成功快照与最近失败信息，普通层展示对应的最近成功读取时间。
- [ ] 将 failed worker 映射为 critical、starting/stopping 映射为 attention。
- [ ] 对 `/health` 的 `ok` 和 operation 内部消息建立稳定中文 presentation mapping，开发者详情保留原始值。

### Task 4: 收敛诊断页面的可用布局与视觉层级

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift` only if an existing token cannot express the adaptive layout

- [ ] 保持一屏优先，但为长详情提供局部滚动；在最小窗口下避免 list/detail 固定最小宽度互相挤压。
- [ ] 保留标题单行、原生 sidebar selection、单一“操作”菜单和 token 化 icon/focus/contrast 语义。
- [ ] 将已知 runtime failure message 纳入用户文案映射，未知值使用通用中文 fallback；技术详情才显示 raw message。

### Task 5: 静态复查与交付记录

**Files:**

- Modify: `docs/developers/macos-app-design-system.md` only if the current verification note needs factual update

- [ ] 运行 `git diff --check` 和源码/契约定向检索，确认没有新增 raw path、secret、HTTP 管理入口或 macOS 14 fallback。
- [ ] 记录本轮没有执行测试、构建、安装和运行态动作；不把历史验证写成本轮通过。
- [ ] 等用户解除自动化测试暂停后，再执行 native unit/UI、Python gate 和最小窗口/深色/高对比度/VoiceOver 验收矩阵。

## Definition of Done

- 终态 operation 不会被迟到 progress 回写为 running。
- Balanced/Quality 的必需分人 CoreML 未验证时不能应用档位。
- 模型下载和档位应用在 UI 中分别显示正确的 operation 语义与恢复入口。
- 监控展示真实可用指标，不把缺失数据伪装成零，并能表达 health/metrics 部分失败。
- 诊断页在目标最小窗口下可读、可滚动、可恢复；顶部中心标题不换行。
- 本轮静态验证通过，且没有声称未经执行的自动化结果。
