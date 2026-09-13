# macOS 26 App 最佳实践整改 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不降低 `SpeechRailApp` macOS 26 deployment target、不中断 Python 服务和不改变模型下载边界的前提下，完成控制 Agent 授权闭环、Liquid Glass 层级、VoiceOver 语义和模型准备 operation 恢复。

**Architecture:** App 只负责状态呈现、用户确认和 XPC 请求；`SpeechRailControlKit` 承载 schema 1 的向后兼容快照；`SpeechRailControlAgentCore` 负责受控 journal、operation 生命周期和恢复判定；现有 Python CLI 仍是服务/profile/model 的唯一执行者。SMAppService 只在 Distribution 的显式启用路径使用，Debug/Release 的内嵌 local XPC 不触碰系统注册记录。

**Tech Stack:** Swift 6 / SwiftUI macOS 26 / ServiceManagement / Observation / Foundation / XCTest / Xcode 26.6。

**Spec:** [docs/superpowers/specs/2026-09-13-macos26-app-best-practices-remediation-design.md](../specs/2026-09-13-macos26-app-best-practices-remediation-design.md)

## Global Constraints

- [ ] 只修改 `macos/SpeechRailApp`、对应 active macOS App 文档和本计划；保留 `CHANGELOG.md`、MCP/Python 的并行未提交改动，不把它们加入本任务 commit。
- [ ] `ControlConstants.schemaVersion` 保持 `1`；新增 wire 字段必须是 optional，旧 Agent 缺字段时按无恢复 operation 处理。
- [ ] 不写入模型内容、绝对路径、音频、日志、凭据或 token；journal 只落脱敏 operation 元数据并使用原子替换。
- [ ] 不在 App 启动时调用 `SMAppService.unregister()`；不把注册失败吞成普通 unavailable；不改变 `com.speechrail` Python 服务 owner。
- [ ] 每个行为变更先写失败测试并确认 RED，再做最小实现确认 GREEN；每个逻辑主题单独 commit。
- [ ] App target 继续 macOS 26；不引入 `#available`、Material 或 macOS 14 视觉 fallback。

---

## Task 1: 固化 ControlKit 的授权与 operation 兼容模型

**Files:**

- Modify `macos/SpeechRailApp/SpeechRailControlKit/ControlTypes.swift`.
- Modify `macos/SpeechRailApp/SpeechRailControlKit/ServiceDiagnosticsTypes.swift`.
- Modify `macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift`.

- [ ] 先在 `ControlKitTests.swift` 添加 RED 测试：`OperationSnapshot` 可携带 optional `profile`；`OperationState.interrupted` 可编码/解码；缺少 `active_operation` 的旧 `ModelStatusSnapshot` 可解码并得到 `nil`。
- [ ] 运行聚焦测试并确认新增断言因字段/枚举不存在而失败：`xcodebuild ... -only-testing:SpeechRailAppTests/ControlKitTests test`。
- [ ] 给 `OperationSnapshot` 增加 `profile: SpeechRailProfile?`，给 `OperationState` 增加 `.interrupted`，保持已有初始化调用通过默认值；给 `ModelStatusSnapshot` 增加 `activeOperation: OperationSnapshot?` 并用 `active_operation` 编码键。
- [ ] 运行相同聚焦测试确认 GREEN，并扩展 round-trip 断言覆盖 profile、interrupted 和 active operation。
- [ ] 检查 `ControlResponse.rebound(to:)`、所有 switch 和 fake fixture 对新增状态的处理，不改变 schema 版本。
- [ ] 提交：`feat: make macos control snapshots recovery aware`。

## Task 2: 用测试驱动实现 Agent operation journal

**Files:**

- Add `macos/SpeechRailApp/SpeechRailControlAgentCore/OperationJournal.swift`.
- Modify `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentOperationStore.swift`.
- Modify `macos/SpeechRailApp/SpeechRailControlAgent/main.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj` to include the new source.
- Modify `macos/SpeechRailApp/SpeechRailMacControlTests/AgentCoreTests.swift`.

- [ ] 先添加 RED 测试：journal 写入不会出现绝对路径/secret 字段；写入后可读回 active snapshot；临时文件替换后不会留下半写 JSON；Agent 启动读取 active journal 后把 accepted/running 标成 `.interrupted` 并清除 active mutation；终态写入后清理 active journal。
- [ ] 运行 `AgentCoreTests` 聚焦测试，确认 `OperationJournal` 和恢复语义尚未实现而失败。
- [ ] 实现 `OperationJournal`：默认路径为 `ManagedRuntimeLocator.default.appHome` 下受控的内部状态文件；支持注入测试 URL；只写 operation ID、command、profile、state、phase、progress、errorCode、path-free message 和 `updated_at`；采用同目录临时文件 + 原子替换；对目录/文件设置用户私有权限；load/clear 只操作该精确文件。
- [ ] 给 `AgentOperationStore` 注入 journal，默认构造仍可用；accepted/running/progress/terminal/cancelled 都更新内存快照并 best-effort 持久化；journal 失败不阻塞 runner，但下一次 `modelStatus` 返回 path-free recovery warning。
- [ ] Agent 初始化时读取 journal：仅对 accepted/running active 记录生成 `.interrupted` 快照并保存到 operation 列表；不伪造 runner 可取消状态；终态 journal 清理；model status 通过 `activeOperation` 返回恢复上下文。
- [ ] 在 `main.swift` 用 `ManagedRuntimeLocator.default.appHome` 注入默认 journal；更新 project file 的 AgentCore source phase。
- [ ] 运行全部 `AgentCoreTests` 和 `ControlKitTests` 确认 GREEN。
- [ ] 提交：`feat: persist control agent operation recovery state`。

## Task 3: 让 App 恢复 operation 并诚实呈现控制 Agent 授权状态

**Files:**

- Modify `macos/SpeechRailApp/SpeechRailApp/ControlAgentRegistration.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/App.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift` if the explicit Login Items action belongs in the menu.
- Modify `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift` for UI-visible states.

- [ ] 先添加 RED 测试/可测纯逻辑：`enabled` 允许 mutation；`notRegistered` 只由显式启用动作触发 register；`requiresApproval` 不 register 且提供 Login Items action；`notFound`/unknown fail closed；local XPC 初始化路径不触碰 SMAppService；model status 中的 active operation 恢复到 AppModel，interrupted 只显示 retry。
- [ ] 运行聚焦 native tests/build，确认现有隐式 unregister、`try? ensureRegistered...` 和未恢复 operation 造成失败或静态契约失败。
- [ ] 增加无副作用的 registration status snapshot、状态到 action 的纯决策映射和显式 `openLoginItemsSettings()`；`ensureRegisteredForCurrentBundle()` 仅处理 `.enabled`/显式 `.notRegistered` 注册，不清理旧记录，不对 `.requiresApproval`/`.notFound` 重试。
- [ ] 调整 `App.init`：local XPC 不创建/调用 Distribution registration；Distribution 不在启动时隐式 register；删除启动 `unregister()` 和吞错的 `try?`；需要控制 mutation 时由 AppModel 根据状态调用明确的 enable flow，并保留稳定的错误分类/下一步提示。
- [ ] 调整 `AppModel`：暴露 control agent snapshot；`refreshModels()` 将 `modelStatus.activeOperation` 恢复为 `operation`，恢复 profile；`.interrupted` 清除取消入口并保留 retry 文案；wait loop 将 `.interrupted` 作为终止状态；完成后重新读取 catalog/status。
- [ ] 在总览、预检/诊断和菜单入口显示状态、影响范围和下一步；requires approval 提供系统 Login Items 入口，not found 提示安装/Agent 缺失，不直接停止服务或删除模型。
- [ ] UI test 增加 route 可见性、model recovery/interrupted 文案和主操作禁用规则；运行可执行的 native test/build。若 UI runtime 受锁屏或 LLDB 环境阻塞，只记录 build-for-testing 成功和阻塞证据，不伪称 UI pass。
- [ ] 提交：`fix: make control agent authorization explicit`。

## Task 4: 收敛 macOS 26 Liquid Glass 页面层级

**Files:**

- Modify `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift` only if a shared glass-group token is needed.
- Modify `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`.

- [ ] 先添加 UI source contract/compile expectation，确认 control center detail 根容器仍有 `.background(groupedCanvas)` 且相邻自定义 glass 没有统一容器。
- [ ] 保留 `NavigationSplitView`、system toolbar 和 `backgroundExtensionEffect`；移除 toolbar 根 detail 上的 grouped canvas，必要背景移动到 ScrollView content layer。
- [ ] 在同一页面确实相邻且需要采样/形变的自定义玻璃元素外包 `GlassEffectContainer`，间距使用 `SpeechRailSpacing`；不为静态 VStack 添加玻璃、不新增无用途 `glassEffectID`。
- [ ] 用 Debug build 验证 SwiftUI macOS 26 API 类型和最小窗口布局；不添加兼容分支。
- [ ] 提交：`refactor: align control center with macos 26 glass hierarchy`。

## Task 5: 完成运行监控和模型管理的 VoiceOver 语义

**Files:**

- Add `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringAccessibility.swift` if a dedicated descriptor type keeps the view readable.
- Modify `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`.
- Modify `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj` for any new source.
- Modify `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift` with identifiers/labels.
- Modify `macos/SpeechRailApp/SpeechRailMacControlTests/ControlKitTests.swift` only for pure formatter/descriptor data tests if extraction makes that appropriate.

- [ ] 先添加 RED 测试：给定样本时 chart descriptor 有标题/摘要、时间轴、活跃请求数轴和逐点时间/value；空样本只显示 empty state；profile choice 的 accessibility value 明确“已选择/未选择”；artifact DisclosureGroup 保留展开动作而不是 combine 成静态元素。
- [ ] 运行聚焦 native tests/build，确认 descriptor、selected value 和 view semantics 尚未满足断言。
- [ ] 给监控 Chart 添加 `AXChartDescriptorRepresentable`/`accessibilityChartDescriptor`：描述采样时间和 active request 数；样本不足时不创建空图表并让空态文字成为唯一结果。
- [ ] 给档位选择行暴露标题、用途、容量和 selected state；保留现有行式视觉选择器及 identifier。
- [ ] 删除 artifact `DisclosureGroup` 的 `.accessibilityElement(children: .combine)`；使用 contain 或显式 label/value，让展开/收起和技术详情仍可达。
- [ ] 增加 UI test identifiers/labels，覆盖导航→页面定位→主操作→状态详情顺序所需的可定位元素；开启/关闭主操作不依赖颜色或动效。
- [ ] 提交：`feat: complete macos app accessibility semantics`。

## Task 6: 更新 active App 文档并完成验证

**Files:**

- Modify `docs/developers/macos-app-design-system.md` with the actual glass/accessibility status.
- Modify `docs/developers/macos-app-development.md` with registration and operation recovery behavior.
- Modify `docs/developers/macos-app-release.md` only where startup registration/signing statements are stale.

- [ ] 先用 `rg` 对照实现检查文档中的 SMAppService、Liquid Glass、journal 和 macOS deployment target 描述，标出不再准确的句子。
- [ ] 更新文档为事实性说明：App 26-only；local XPC 与 Distribution registration 分离；用户批准由 Login Items 完成；journal 不保证下载续传，只恢复可解释状态；模型 status 仍是最终事实来源。
- [ ] 不把未完成的人工 VoiceOver/外观矩阵标成通过；记录实际完成的 build/unit/UI build-for-testing 和仍受环境阻塞的 UI runtime/Distribution notarization。
- [ ] 运行完整 gate：
  - `scripts/macos_app_build.sh --configuration Debug`
  - `scripts/macos_app_test.sh`
  - `plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist`
  - `uv run --extra dev pytest`
  - `uv run --extra dev ruff check src tests`
  - `uv run --extra dev mypy src`
  - `npx @redocly/cli lint contracts/openapi.yaml`
  - `git diff --check`
- [ ] 复查 staged diff、敏感字段、未提交范围和 `git status --short`；确认只剩用户原有 MCP/Python/CHANGELOG 改动。
- [ ] 提交：`docs: document macos 26 app remediation verification`。

## Plan Review

- [ ] 所有任务都有明确文件、失败测试、最小实现、绿色验证和 commit 边界。
- [ ] 计划覆盖 approved spec 的授权、Glass、可访问性、operation recovery、验收矩阵和回退要求。
- [ ] 未引入远程 API、模型/音频落库、兼容 macOS 14 或未经授权的签名/公证动作。
- [ ] 实现过程中如发现当前代码与计划冲突，先以代码/测试为事实来源，更新本计划和对应 ADR，再继续，不静默扩大范围。
