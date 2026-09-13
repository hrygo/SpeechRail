# SpeechRail macOS 26 Workspace Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 SpeechRail macOS App 重构为任务型主窗口与 Inspector 工作区，让普通用户快速理解服务状态和下一步，让开发者按选中对象查看脱敏技术细节，同时保留音色创作和模型下载能力。

**Architecture:** 保留 macOS 26 的 `NavigationSplitView` 作为顶层导航，将服务页面改为结论驱动的内容层；模型和诊断使用 list/selection + Inspector，运行监控使用指标行 + 主趋势图。所有页面通过统一 token 和共享状态组件表达层级，Liquid Glass 只留在 sidebar、toolbar 和主要交互层。

**Tech Stack:** SwiftUI / Charts / macOS 26 / Swift 6 / Xcode 26 / XCTest / XCUITest / existing `SpeechRailControlKit` and `SpeechRailControlAgentCore`.

**Spec:** `docs/superpowers/specs/2026-09-13-speechrail-macos26-workspace-redesign-design.md`

## Global Constraints

- `SpeechRailApp` UI 的 `MACOSX_DEPLOYMENT_TARGET` 固定为 `26.0`，不添加 macOS 14 UI fallback、Material fallback 或 `#available` 视觉分支。
- 服务 owner 仍是现有用户级 `com.speechrail` LaunchAgent；App 不直接执行 `launchctl`、不创建第二个服务实例、不加载模型、不采集或播放音频。
- 模型下载只通过锁定 manifest 的现有 Control Agent 命令执行；不接受用户自定义 URL、路径、shell 参数，也不自动下载、加载、卸载或切换 profile。
- “下载并校验”和“应用档位”必须是两个独立动作，并分别说明影响范围和确认要求。
- `VoiceDesign` / 音色创作页面和产品主线必须保留。
- 颜色、间距、圆角、窗口尺寸和字体从 `SpeechRailDesignTokens.swift` 读取；内容层不滥用 `.glassEffect`。
- 普通用户默认看到结论、用途、下一步和影响范围；端口、revision、worker、错误码和内部状态只在 Inspector/开发者详情展示。
- 不修改当前仓库中与本任务无关的 MCP/Python 未提交改动：`CHANGELOG.md`、`docs/architecture/speechrail-mcp-proxy.md`、`docs/users/README.md`、`docs/users/mcp-agent-integration.md`、`src/speechrail/http/errors.py`、`src/speechrail/http/routes/audio.py`、`src/speechrail/mcp/client.py`、`tests/mcp/test_client.py`、`tests/test_app_contract.py`、`tests/test_speech_api.py`。
- 每项改动完成独立测试后提交一个逻辑 commit；提交前只 stage 当前任务文件并运行 `git diff --staged --check`。

## File Map

### Shared UI and navigation

- Modify `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`: replace generic visual constants with semantic macOS 26 tokens and surface rules.
- Create `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`: define `PageIntroView`, `StatusBanner`, `ServiceStatusBadge`, `SectionHeading`, `MetricStrip`, `OperationBar` and shared Inspector styling.
- Modify `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`: keep `NavigationSplitView`, simplify sidebar rows, remove duplicated page title treatment, expose toolbar-level refresh and page actions.
- Modify `macos/SpeechRailApp/SpeechRailApp/AppRoute.swift`: rename visible service routes to `服务状态`, `模型`, `运行监控`, `诊断`, retaining stable raw values.
- Modify `macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift`: turn the existing header into compact page-intro semantics and remove the fixed service footer from rendered surfaces.
- Modify `macos/SpeechRailApp/SpeechRailApp/ControlAgentStatusView.swift` and `ControlMenuView.swift`: use inline status/command presentation without nested glass panels.
- Modify `macos/SpeechRailApp/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`: register `WorkspaceComponents.swift` in the App target.

### Service pages

- Modify `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift`: status banner, capability list, one next-step area and optional developer Inspector.
- Modify `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`: profile list, selected profile workspace, artifact list, model operation bar and Inspector.
- Modify `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift`: health summary, metric strip, main chart and developer Inspector.
- Modify `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`: check list, selected check detail and recovery action.
- Modify `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`: remove service footer and use editor + Inspector layouts while preserving VoiceDesign.
- Modify `macos/SpeechRailApp/SpeechRailApp/ServiceRoutePreviewView.swift`, `ServiceStatusView.swift`, and `ProfilePickerView.swift`: keep compiled legacy previews aligned with the new tokens and remove obsolete footer/card usage.

### Model capability and test fixtures

- Modify `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentCommandRunner.swift`: classify a managed runtime that rejects the `model` command as `.unsupported`, while retaining redaction for other stderr.
- Modify `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentOperationStore.swift`: return stable `.unsupported` responses for model catalog/status/prepare capability mismatch.
- Modify `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`: expose `ModelAvailabilityState` and map unsupported/not-ready/failed model reads to user-safe copy.
- Modify `macos/SpeechRailApp/SpeechRailApp/App.swift`: add deterministic UI-test fixture for unsupported model capability.
- Reuse existing `macos/SpeechRailApp/SpeechRailControlKit/ControlTypes.swift` error code `.unsupported` and schema version `1`; do not add a mandatory wire field for the UI-only availability state.
- Modify `macos/SpeechRailApp/SpeechRailMacControlTests/AgentCoreTests.swift` and `ControlKitTests.swift`: add red/green tests for capability mismatch and stable model behavior.
- Modify `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`: update visible route labels and add acceptance checks for page purpose, model capability error, confirmation and recovery.

### Documentation

- Modify `docs/developers/macos-app-design-system.md`: make the new semantic token table, page hierarchy, surface policy and acceptance matrix the active design-system reference.

## Task 1: Lock the token system and navigation shell

**Files:**

- Create: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppRoute.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**

- Produces semantic token namespaces `Spacing`, `Corner`, `Layout`, `Control`, `Typography`, `Palette`, `Surface` and `Motion`.
- Produces shared views `PageIntroView(route:)`, `StatusBanner`, `ServiceStatusBadge`, `SectionHeading`, `MetricStrip` and `OperationBar`.
- Keeps `AppRoute.rawValue` stable so `AppNavigationState` and menu-bar commands remain compatible.

- [x] **Step 1: Update UI assertions to the approved navigation language.**

Change UI assertions from `本机服务总览`/`模型管理`/`预检与诊断` to `服务状态`/`模型`/`诊断`, and add:

```swift
XCTAssertTrue(app.staticTexts["服务状态"].waitForExistence(timeout: 5))
XCTAssertTrue(app.buttons["模型"].exists)
XCTAssertTrue(app.buttons["运行监控"].exists)
XCTAssertTrue(app.buttons["诊断"].exists)
```

## Task 4: Rebuild the model page as a profile workspace

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**

- Consumes `modelCatalog`, `modelStatus`, `operation`, `modelAvailability`, `prepareModels`, `execute(.profileApply:)` and `cancelCurrentOperation()`.
- Produces profile selection, artifact selection, user-safe operation states and a developer Inspector.

- [x] **Step 1: Update the confirmation test to the new route and retain explicit action checks.**

Keep the test’s confirmation assertion but navigate through `app.buttons["模型"]`. Add a check for separate labels:

```swift
XCTAssertTrue(app.buttons["下载并校验"].exists)
XCTAssertTrue(app.buttons["应用档位"].exists)
```

Expected: the route label fails before the shell refactor and the new action label fails before this task.

- [x] **Step 2: Implement the three-region profile workspace.**

Use a profile `List(selection:)` on the left, selected profile content in the center, and `.inspector(isPresented:)` on the right.
The selected profile content must show:

```text
档位用途
准备大小 / 当前可用空间
[下载并校验] [应用档位]
制品列表
```

Replace profile glass cards with native list rows. Artifact rows are selectable and show verification state, not nested glass panels.

- [x] **Step 3: Implement `OperationBar` for every model operation state.**

Map states as follows:

```text
accepted/running  → 正在准备模型 + phase + progress + 停止下载
interrupted       → 上次准备被中断 + 重新下载并校验
failed            → 准备失败 + error-safe message + 重新准备
committed         → 已完成校验
cancelled         → 已取消
```

Keep `ProgressView`, file/bytes text and cancellation gating. Never claim resume when the Agent marked the operation interrupted.

- [x] **Step 4: Add the artifact Inspector and unsupported/empty states.**

The Inspector shows `modelID`, provider/repository, revision, quantization, file count/size and integrity counts for the selected artifact.
If `modelAvailability == .unsupported`, show the version mismatch `StatusBanner` and `打开诊断`; do not render stale artifact rows as current.
If catalog is empty, use a native empty state with a single next action.

- [x] **Step 5: Run model UI tests and commit.**

Run:

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -testPlan SpeechRailApp -destination 'platform=macOS' -only-testing:SpeechRailAppUITests/SpeechRailAppUITests/testModelDownloadRequiresExplicitConfirmation -only-testing:SpeechRailAppUITests/SpeechRailAppUITests/testModelRecoveryRestoresInterruptedOperationAndRetryAction test
```

Expected: confirmation, interrupted recovery and mutually exclusive retry/cancel actions pass.

```bash
git add macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git diff --staged --check
git commit -m "refactor: turn model management into a profile workspace"
```

## Task 5: Rebuild monitoring and diagnostics around scanable data

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringAccessibility.swift`
- Modify: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**

- Consumes existing `RuntimeMetricsSample`, `RuntimeMonitoringChartDescriptor`, `preflightChecks`, and `refreshPreflight()` APIs.
- Preserves `AXChartDescriptor`, stable metric semantics and failure-safe monitoring behavior.

- [x] **Step 1: Add failing UI assertions for the new monitoring and diagnostics hierarchy.**

Update monitoring test to assert `运行监控` plus `等待监控样本`, and add diagnostics assertions for `检查项` and a selected check detail.
Expected: the new `检查项` assertion fails before the page refactor.

- [x] **Step 2: Replace metric tiles with one metric strip and one primary trend area.**

Render active requests, pending requests, processed requests and queue rejections in one `MetricStrip` with separators and tabular digits.
Render the Chart in a single content surface with a heading, timestamp and empty state. Keep the existing 5-second sampling and accessibility descriptor.
Move latency, workers, RTF and resource detail into the Inspector; do not expose them as default card grid content.

- [x] **Step 3: Replace diagnostics card stack with list + selected detail.**

Use `List(selection:)` for checks, with text plus status shape. The detail pane explains the selected check’s result, impact and recovery action.
Keep `重新运行` as the page action and retain the read-only promise. Show developer fields only in Inspector/DisclosureGroup.

- [x] **Step 4: Run focused monitoring and native accessibility tests.**

Run:

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -testPlan SpeechRailApp -destination 'platform=macOS' -only-testing:SpeechRailAppUITests/SpeechRailAppUITests/testMonitoringExplainsMissingMetrics test
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -testPlan SpeechRailApp -destination 'platform=macOS' -only-testing:SpeechRailMacControlTests/ControlKitTests/testRuntimeMonitoringChartDescriptorDescribesTimeAndActiveRequests -only-testing:SpeechRailMacControlTests/ControlKitTests/testRuntimeMonitoringChartDescriptorRequiresTwoSamples test
```

Expected: empty monitoring state, chart descriptor and chart sample threshold pass.

- [x] **Step 5: Commit monitoring and diagnostics.**

```bash
git add macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringAccessibility.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git diff --staged --check
git commit -m "refactor: simplify monitoring and diagnostics hierarchy"
```

## Task 6: Preserve VoiceDesign while moving creator pages to workspaces

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceRoutePreviewView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceStatusView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ProfilePickerView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**

- Keeps public `CreatorSurfaceView`, `DubbingDeskView`, `VoiceDesignView`, `VoiceLibraryView` and `WorksView` names.
- Keeps the VoiceDesign description editor and future candidate/preview/save path.

- [x] **Step 1: Add a UI assertion for the retained VoiceDesign purpose and editor.**

Use the existing navigation test and assert:

```swift
app.buttons["音色创作"].click()
XCTAssertTrue(app.staticTexts["从一句话开始"].waitForExistence(timeout: 2))
XCTAssertTrue(app.staticTexts["先描述你想要的声音，再试听候选并保存。"].exists)
```

- [x] **Step 2: Remove the creator footer and duplicate route header.**

Keep the toolbar title and render a compact purpose line. Do not show service port/status footer on creator pages.

- [x] **Step 3: Implement creator workspaces.**

For VoiceDesign, keep the editor in the main content region and place candidate/preview/save controls in an Inspector-shaped region.
For Dubbing, keep text editing in the main region and voice/parameter controls in the Inspector. Keep disabled actions honest until the service capability exists.
Use list/table empty states for the library and works pages, with one next action and no decorative empty card.

- [x] **Step 4: Align compiled previews and legacy surfaces with the same tokens.**

Update `ServiceRoutePreviewView`, `ServiceStatusView` and `ProfilePickerView` so they no longer introduce a footer or old nested glass panel if they are opened by future routes/tests.

- [x] **Step 5: Run the VoiceDesign UI test and commit.**

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -testPlan SpeechRailApp -destination 'platform=macOS' -only-testing:SpeechRailAppUITests/SpeechRailAppUITests/testControlCenterSeparatesCreatorAndServiceNavigation test
git add macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift macos/SpeechRailApp/SpeechRailApp/ServiceRoutePreviewView.swift macos/SpeechRailApp/SpeechRailApp/ServiceStatusView.swift macos/SpeechRailApp/SpeechRailApp/ProfilePickerView.swift macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git diff --staged --check
git commit -m "refactor: preserve voice design workspace hierarchy"
```

## Task 7: Synchronize design documentation and run the complete gate

**Files:**

- Modify: `docs/developers/macos-app-design-system.md`
- Inspect only: existing unrelated dirty files listed in Global Constraints

- [x] **Step 1: Update the active design-system document.**

Document the final token values, semantic surfaces, route labels, page prototypes, Inspector policy,
model capability mismatch copy, ordinary/developer information split and the actual verification matrix.
Mark only checks demonstrated by fresh commands as complete; leave desktop visual, VoiceOver and Reduce Motion checks explicitly marked with their real result.

- [x] **Step 2: Run the full native and Python verification gate.**

Run:

```bash
scripts/macos_app_build.sh --configuration Debug
scripts/macos_app_test.sh
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
```

Expected: native build/tests and all existing project gates pass. If macOS UI automation is blocked by the desktop menu traversal environment,
record the exact failing test and separate that environmental result from compile/unit-test results.

- [x] **Step 3: Inspect the final diff and installed App without touching the managed service.**

Confirm:

```bash
git status --short
git diff --stat main...HEAD
git diff --check
```

Verify the App bundle still has `MACOSX_DEPLOYMENT_TARGET=26.0`, one embedded local XPC service and no model/audio artifacts.
Do not stop/restart/replace `com.speechrail` or download models as part of UI verification.

- [x] **Step 4: Commit documentation and report evidence.**

```bash
git add docs/developers/macos-app-design-system.md
git diff --staged --check
git commit -m "docs: align macos app design system with workspace refactor"
```

The final report must include changed files/commits, verification timestamps and results, runtime actions (none unless separately authorized),
manual visual/accessibility checks not performed, preserved unrelated changes, and the exact rollback commit boundary.

## Self-review checklist

- [x] Every section of `docs/superpowers/specs/2026-09-13-speechrail-macos26-workspace-redesign-design.md` maps to at least one task above.
- [x] `rg -n "TODO|TBD|FIXME|待定|占位" docs/superpowers/plans/2026-09-13-speechrail-macos26-workspace-redesign.md` returns no matches.
- [x] Token names and page/component names remain consistent across tasks.
- [x] The plan never authorizes direct model loading, arbitrary downloads, direct `launchctl`, or changes to the unrelated dirty worktree.
- [x] The plan distinguishes build/unit evidence from desktop visual and VoiceOver evidence.

- [x] **Step 2: Run the focused UI test to verify it fails against the old labels.**

Run:

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -testPlan SpeechRailApp -destination 'platform=macOS' -only-testing:SpeechRailAppUITests/SpeechRailAppUITests/testControlCenterSeparatesCreatorAndServiceNavigation test
```

Expected: FAIL because the current UI still exposes `本机服务总览` and `模型管理`.

- [x] **Step 3: Replace the token constants with the approved semantic values.**

Implement the following public values in `SpeechRailDesignTokens.swift`:

```swift
Spacing.micro = 4
Spacing.xs = 8
Spacing.sm = 12
Spacing.md = 16
Spacing.lg = 24
Spacing.xl = 32
Corner.control = 6
Corner.row = 8
Corner.surface = 12
Layout.windowMinimumWidth = 1120
Layout.windowMinimumHeight = 720
Layout.sidebarIdealWidth = 248
Layout.inspectorMinimumWidth = 280
Layout.inspectorIdealWidth = 336
Layout.contentMaximumWidth = 1240
Control.minimumHitTarget = 44
```

Map `Palette.railSignal` to the system accent, `Palette.voiceAccent` to the VoiceDesign-only accent,
and use adaptive system colors for canvas, content, primary text, secondary text, healthy, attention and critical states.
Remove `SpeechRailSurfaceLevel.panel` as the default content treatment; retain explicit navigation/control surface modifiers only.

- [x] **Step 4: Add shared semantic components and compile the App target.**

Implement the shared views without `.glassEffect` on content rows:

```swift
enum StatusTone { case neutral, healthy, attention, critical }
struct PageIntroView: View { let route: AppRoute }
struct StatusBanner: View { let tone: StatusTone; let title: String; let message: String; let actionTitle: String?; let action: (() -> Void)? }
struct ServiceStatusBadge: View { let compact: Bool }
struct SectionHeading: View { let title: String; let detail: String? }
struct MetricValue: Identifiable { let id: String; let title: String; let value: String; let detail: String }
struct MetricStrip: View { let metrics: [MetricValue] }
struct OperationBar: View { let operation: OperationSnapshot?; let actionTitle: String?; let action: (() -> Void)? }
```

Register the new file in the App target’s PBX file reference, build phase and App group. Keep the existing
`SurfaceHeaderView` type as a deprecated wrapper that forwards to `PageIntroView`, so compiled previews retain their source compatibility while active pages use the new name.

Run:

```bash
scripts/macos_app_build.sh --configuration Debug
```

Expected: BUILD SUCCEEDED and no old token compile errors.

- [x] **Step 5: Refactor the navigation shell and remove the fixed footer from rendered surfaces.**

Use native `Label` rows with `.tag(route)`, keep sidebar search, use `ServiceStatusBadge(compact: true)` in the service section header,
and let the toolbar own the route title. Remove the route title duplication from page bodies and stop rendering
`ServiceStatusFooterView` from all active pages. Keep toolbar refresh as a command that calls `model.refresh()`.

- [x] **Step 6: Run the focused UI test and commit the shell.**

Run the same focused UI test from Step 2. Expected: PASS for navigation labels. Then:

```bash
git add macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift macos/SpeechRailApp/SpeechRailApp/AppRoute.swift macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift macos/SpeechRailApp/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git diff --staged --check
git commit -m "refactor: establish macos 26 workspace shell"
```

## Task 2: Refactor service status and control-agent presentation

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlAgentStatusView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**

- Consumes `AppModel.service`, `health`, `profile`, `controlAgentStatus` and the existing `ControlCommand` API.
- Produces a status conclusion, capability list, next-step action and developer Inspector without changing service ownership.

- [x] **Step 1: Add a failing UI assertion for conclusion-first service status.**

Add assertions that the overview contains the approved purpose and a next-step label:

```swift
XCTAssertTrue(app.staticTexts["确认本机语音服务能否使用"].exists)
XCTAssertTrue(app.staticTexts["能力"].exists)
XCTAssertTrue(app.buttons["运行预检"].exists)
```

Expected: FAIL because the current overview has repeated `服务状态` cards and no `运行预检` action.

- [x] **Step 2: Replace the overview stack with a conclusion banner and scanable capability rows.**

Render one `StatusBanner` at the top with:

```text
服务可用 / 服务尚未就绪
Quality · 当前档位 · 最近检查时间
SpeechRail 已准备好接收本机语音请求。
主要动作：启动服务 / 打开诊断
```

Render ASR/TTS/实时语音/分人识别 as `VStack` rows with `Divider`, not four `CapabilityTile` glass cards.
Place `运行预检` as the next-step action. Put start/stop/restart in a toolbar `Menu` and retain confirmation dialogs.

- [x] **Step 3: Make control-agent state inline and actionable.**

Remove the independent `speechRailSurface(.panel)` wrapper from `ControlAgentStatusView`; show title, impact and one recovery action as an inline status row or Inspector section. Preserve `register`, `openLoginItems`, `installAgent` and `unavailable` semantics.
Update `ControlMenuView` to use the same `ServiceStatusBadge` and the same `ControlCommand` action closures.

- [x] **Step 4: Add the developer Inspector and verify UI behavior.**

Add `.inspector(isPresented:)` to the overview with service/version/backend/port and control-agent details. Default it closed unless
`speechrail.showDeveloperDetails` is enabled. Run:

```bash
scripts/macos_app_build.sh --configuration Debug
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -testPlan SpeechRailApp -destination 'platform=macOS' -only-testing:SpeechRailAppUITests/SpeechRailAppUITests/testControlSurfaceShowsServiceAndProfiles test
```

Expected: BUILD SUCCEEDED and the updated status page assertions pass.

- [x] **Step 5: Commit the service status surface.**

```bash
git add macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift macos/SpeechRailApp/SpeechRailApp/ControlAgentStatusView.swift macos/SpeechRailApp/SpeechRailApp/ControlMenuView.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git diff --staged --check
git commit -m "refactor: make service status conclusion-first"
```

## Task 3: Make model capability mismatch explicit

**Files:**

- Modify: `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentCommandRunner.swift`
- Modify: `macos/SpeechRailApp/SpeechRailControlAgentCore/AgentOperationStore.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppModel.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/App.swift`
- Modify: `macos/SpeechRailApp/SpeechRailMacControlTests/AgentCoreTests.swift`
- Modify: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**

- Produces `ManagedCommandError.unsupported` for a runtime that rejects `model` as a command.
- Produces `AppModel.ModelAvailabilityState` values `.unknown`, `.available`, `.unsupported`, `.notReady` and `.failed`.
- Keeps ControlKit schema version `1`; no mandatory wire field is introduced.

- [x] **Step 1: Add a failing runner test for the measured runtime error.**

Add a shell fixture whose stderr contains:

```text
speechrail: error: argument command: invalid choice: 'model'
```

Run:

```bash
xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -testPlan SpeechRailApp -destination 'platform=macOS' -only-testing:SpeechRailMacControlTests/AgentCoreTests/testProcessRunnerClassifiesUnsupportedModelCommand test
```

Expected: FAIL because the current runner returns `.commandFailed`/generic failure.

- [x] **Step 2: Classify only the model capability rejection.**

Extend `ManagedCommandError` with `.unsupported`. Add a redacted diagnostic classifier that returns true only when the command is one of
`.modelCatalog`, `.modelStatus`, `.modelPrepare` and stderr contains the known command-rejection forms (`invalid choice` plus `model`, or `no such command` plus `model`).
Map it to `ControlErrorCode.unsupported` and the stable message `managed runtime does not support model control commands`.
Leave all other stderr redaction and failure codes unchanged.

- [x] **Step 3: Add `ModelAvailabilityState` and fail closed in `AppModel.refreshModels()`.**

Implement:

```swift
public enum ModelAvailabilityState: Equatable, Sendable {
    case unknown
    case available
    case unsupported
    case notReady
    case failed
}
```

When catalog/status returns `.unsupported`, set `.unsupported`, clear stale catalog/status data, and set user copy to
`模型管理暂不可用：服务组件版本不匹配`. Do not retry or trigger download/profile changes. Set `.available` only after both catalog and status are read successfully.

- [x] **Step 4: Add the UI-test unsupported fixture and verify red/green behavior.**

Add `--ui-test-model-unsupported` handling in `SpeechRailApp` and make the fixture return `.unsupported` for model catalog/status.
Add a UI test that opens `模型` and asserts:

```swift
XCTAssertTrue(app.staticTexts["模型管理暂不可用：服务组件版本不匹配"].waitForExistence(timeout: 5))
XCTAssertTrue(app.buttons["打开诊断"].exists)
```

Run the focused unit and UI tests. Expected: both PASS after implementation.

- [x] **Step 5: Commit the capability boundary.**

```bash
git add macos/SpeechRailApp/SpeechRailControlAgentCore/AgentCommandRunner.swift macos/SpeechRailApp/SpeechRailControlAgentCore/AgentOperationStore.swift macos/SpeechRailApp/SpeechRailApp/AppModel.swift macos/SpeechRailApp/SpeechRailApp/App.swift macos/SpeechRailApp/SpeechRailMacControlTests/AgentCoreTests.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git diff --staged --check
git commit -m "fix: explain unsupported model control capability"
```
