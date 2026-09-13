# SpeechRail macOS 26 Console Chrome Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the SpeechRail macOS 26 control console chrome with a coherent title system, understandable action hierarchy, high-contrast sidebar language, and a one-screen diagnostic workspace while preserving model download and VoiceDesign flows.

**Architecture:** Keep `NavigationSplitView` as the native window shell and route all page titles through one shared `WorkspaceTitleView`. Keep operational actions in their owning page, collapse low-frequency actions into one labeled toolbar menu, and split the diagnostic page into a compact summary, two-column check list, and selected-check detail surface. All visual values remain in `SpeechRailDesignTokens.swift`.

**Tech Stack:** Swift 6, SwiftUI, macOS 26, Xcode 17, XCTest/XCUITest, existing `SpeechRailControlKit` and `AppModel` transport boundaries.

**Spec:** `docs/superpowers/specs/2026-09-13-speechrail-macos26-console-chrome-redesign-design.md`

## Global Constraints

- App UI targets macOS 26.0 only; do not add macOS 14 compatibility branches.
- Preserve the single local SpeechRail service, XPC control boundary, model preparation confirmation, and model operation recovery behavior.
- Preserve `音色创作`, `配音台`, `音色库`, `我的作品`, model download/verification, monitoring, service status, and diagnostics routes.
- User-facing content leads with conclusion, purpose, impact, and next action; technical details remain progressive disclosure and sanitized.
- Do not display API keys, Authorization headers, raw audio, complete prompts/transcripts, embeddings, real speaker identities, absolute model paths, or reusable internal logs.
- Do not install an App while an older installed App remains; after every UI test remove temporary bundles, runners, LaunchServices registrations, and temporary derived data.
- Use `apply_patch` for source edits, preserve unrelated working-tree changes, and commit one logical change at a time.
- Run each changed UI test after the corresponding source change, then run the complete Python and macOS gates before release.

### Task 1: Establish the shared title and route visual contract

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/AppRoute.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**
- `AppRoute.title` remains the stable user-facing route name used by navigation and accessibility.
- Add `AppRoute.contextTitle: String` returning `创作` or `服务`.
- Add `AppRoute.workspaceTitle: String` for task-oriented titles, with `models` returning `模型管理` and `diagnostics` returning `系统诊断`; other routes retain their clear task names.
- Add `AppRoute.systemImage` mappings from the design spec.
- Add `WorkspaceTitleView(route: AppRoute, service: ServiceSnapshot?)` and `RouteIconView(route: AppRoute, selected: Bool)` as reusable SwiftUI views.
- Add token groups for `Typography.workspaceTitle`, `Typography.workspaceContext`, `Control.sidebarRowHeight`, `Control.sidebarIconFrame`, `Control.sidebarIconSize`, `Control.workspaceTitleHeight`, `Navigation.selectedFill`, and `Navigation.focusRing`.

- [ ] **Step 1: Add a failing route/title contract test**

Update the UI test to verify that after opening the control center and selecting `音色创作`, a descendant with identifier `workspace-title` exists and its label contains `音色创作`; verify the same identifier updates to a label containing `模型管理` after selecting `模型`.

```swift
let title = app.descendants(matching: .any)["workspace-title"]
XCTAssertTrue(title.waitForExistence(timeout: 5))
XCTAssertTrue(title.label.contains("音色创作"))

app.buttons["模型"].tap()
XCTAssertTrue(title.waitForExistence(timeout: 5))
XCTAssertTrue(title.label.contains("模型管理"))
```

- [ ] **Step 2: Run the focused UI test and confirm it fails**

Run: `scripts/macos_app_test.sh` with the focused test selection through Xcode’s `-only-testing:SpeechRailAppUITests/SpeechRailAppUITests/testControlCenterSeparatesCreatorAndServiceNavigation`.

Expected: FAIL because `workspace-title` does not exist and the old toolbar text is not a stable macOS 26 accessibility contract.

- [ ] **Step 3: Implement route metadata and title/icon tokens**

Add the route context/title properties and replace the existing mixed icon mapping with:

```swift
case .dubbing: "waveform.and.mic"
case .voiceDesign: "waveform.badge.plus"
case .voiceLibrary: "music.note.list"
case .works: "square.stack.3d.up"
case .overview: "server.rack"
case .monitoring: "chart.xyaxis.line"
case .models: "shippingbox"
case .diagnostics: "stethoscope"
```

Add the title/navigation/control values only to `SpeechRailDesignTokens.swift`. Keep dynamic colors and high-contrast fallbacks; use the existing rail color as the selected background and system adaptive foreground for selected text.

- [ ] **Step 4: Implement `WorkspaceTitleView` and `RouteIconView`**

Use the existing project file `SurfaceHeaderView.swift` for the title implementation so the Xcode project file does not gain an unnecessary source registration. Keep `SurfaceHeaderView` as a compatibility wrapper that renders `PageIntroView` where it is still referenced.

`WorkspaceTitleView` must render one accessibility element with identifier `workspace-title`, the route icon, `route.workspaceTitle`, `route.contextTitle`, and an optional service status chip. The title must have an identity keyed by `route.id` so macOS 26 replaces the semantic node on route changes.

`RouteIconView` must use the fixed token frame, `.symbolRenderingMode(.hierarchical)`, and `accessibilityHidden(true)` when the route label already names the icon.

- [ ] **Step 5: Run the focused title test and commit**

Run: the focused UI test from Step 2.

Expected: PASS, with the title identifier and label updating after route changes.

Commit:

```bash
git add macos/SpeechRailApp/SpeechRailApp/AppRoute.swift macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift macos/SpeechRailApp/SpeechRailApp/SurfaceHeaderView.swift macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git commit -m "feat(macos): establish shared workspace title language"
```

### Task 2: Simplify the control-center toolbar and sidebar states

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**
- `ControlCenterView` owns navigation and the centered `WorkspaceTitleView`; it must not own a global refresh action.
- Every page exposes no more than one labeled low-frequency toolbar menu, with page primary actions placed beside the state they affect.
- Sidebar rows use `NavigationLink(value:)` with `RouteIconView`; selected text is not manually forced to `Color.ink` or any fixed dark color.
- Remove the fixed sidebar status card; status is available in the title chip and the service overview page.

- [ ] **Step 1: Add a failing action-hierarchy UI assertion**

Extend the first UI test to assert that the selected page has a labeled `操作` menu and does not expose a global `刷新状态` button. Use identifiers rather than counting system toolbar controls.

```swift
XCTAssertTrue(app.buttons["操作"].waitForExistence(timeout: 5))
XCTAssertFalse(app.buttons["刷新状态"].exists)
```

- [ ] **Step 2: Run the focused test and record the old toolbar failure**

Run: `scripts/macos_app_test.sh` with the focused control-center test.

Expected: FAIL because `ControlCenterView` still injects `刷新状态` and pages expose separate icon actions.

- [ ] **Step 3: Replace the global toolbar implementation**

In `ControlCenterView`, render `WorkspaceTitleView(route:selection ?? .overview, service:model.service)` in the principal toolbar position, keep `ToolbarSpacer(.flexible)`, and remove the global refresh toolbar item. Keep route selection in `List(selection:)` and preserve the current `NavigationLink(value:)` behavior.

Use a plain `Label` row with the route icon and no foreground override that can produce blue-background/black-text selection. Apply the selected-state token only to custom non-system surfaces; let the native sidebar supply selected foreground contrast.

- [ ] **Step 4: Consolidate page actions**

For each page, keep the primary user action in the body and consolidate low-frequency actions into one labeled `操作` menu:

- `ServiceOverviewView`: combine developer details and service commands; keep destructive confirmation dialogs.
- `RuntimeMonitoringView`: move refresh to the chart summary/body and keep developer details in `操作`.
- `ModelManagementView`: keep `下载并校验` and `应用此档位` in the selected-profile action section; move refresh and developer details into `操作`.
- `PreflightDiagnosticsView`: keep `重新运行诊断` in the summary; move developer context into `操作`.
- `CreatorSurfaceViews`: keep service status as a non-action status indicator; expose the Works inspector through a labeled action menu without adding duplicate icon buttons.

Every menu item must use a verb that describes its effect: `刷新监控`, `显示开发者详情`, `启动服务`, `停止服务`, or `重启服务`.

- [ ] **Step 5: Run UI navigation/action tests and commit**

Run: `scripts/macos_app_test.sh` with `testControlCenterSeparatesCreatorAndServiceNavigation` and `testControlSurfaceShowsServiceAndProfiles`.

Expected: PASS; all creator and service routes remain reachable, the title updates, selected text is legible, and no page shows three unexplained top-right icon buttons.

Commit:

```bash
git add macos/SpeechRailApp/SpeechRailApp/ControlCenterView.swift macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git commit -m "fix(macos): clarify console toolbar and sidebar navigation"
```

### Task 3: Rebuild diagnostics as a one-screen workspace

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**
- `PreflightDiagnosticsView` remains the owner of refresh state, selected check state, and navigation requests.
- Add `DiagnosticsSummaryView(checks:action:)`, `DiagnosticsCheckList(checks:selectedName:onSelect:)`, and `DiagnosticsDetailView(check:navigation:)` as local or shared SwiftUI components with stable accessibility identifiers.
- Add `Layout.diagnosticsSummaryHeight`, `Layout.diagnosticsListWidth`, `Layout.diagnosticsDetailMinimumWidth`, `Layout.diagnosticsRowHeight`, and `Layout.diagnosticsBodyMinimumHeight`.
- Summary identifiers: `diagnostics-summary`, `diagnostics-run`; list identifier: `diagnostics-check-list`; selected detail identifier: `diagnostics-check-detail`.

- [ ] **Step 1: Add failing one-screen structure assertions**

Extend diagnostics UI tests to require the summary, check list, selected detail, and semantic primary action:

```swift
XCTAssertTrue(app.otherElements["diagnostics-summary"].waitForExistence(timeout: 5))
XCTAssertTrue(app.otherElements["diagnostics-check-list"].exists)
XCTAssertTrue(app.otherElements["diagnostics-check-detail"].exists)
XCTAssertTrue(app.buttons["重新运行诊断"].exists)
```

- [ ] **Step 2: Run diagnostics tests and confirm the old layout fails the new contract**

Run: `scripts/macos_app_test.sh` with `testControlSurfaceShowsServiceAndProfiles` plus the diagnostics-focused tests.

Expected: FAIL because the current page has a large vertical scroll surface, old banner copy, and no stable summary/list/detail identifiers.

- [ ] **Step 3: Implement the compact summary**

Replace the existing large `StatusBanner` conclusion with a compact `DiagnosticsSummaryView` that shows the status icon, conclusion text, `passed/total` summary, the latest check context, and one `重新运行诊断` button. Use the new summary height token and keep all long error details out of this area.

- [ ] **Step 4: Implement the two-column check list**

Replace the single vertical stack of checks with a `LazyVGrid` containing two flexible columns inside the fixed list surface. Each row uses the new row height, status icon plus text status, stable identifier `preflight-<name>`, and `.accessibilityElement(children: .combine)` with label/value. Keep the first check selected by default and preserve selection when results refresh.

- [ ] **Step 5: Implement the selected-check detail surface**

Render the selected result in the right surface in this order: result and check name, what the check confirms, impact, next action, then a `DisclosureGroup` for sanitized technical information. Hide actions for passed checks when no action is required; failed checks must show a recovery action. Keep navigation requests to `.models` and `.overview` unchanged.

- [ ] **Step 6: Fit the page at the minimum window and run focused tests**

Run: the diagnostics test cases, including missing metrics, model recovery, and model unsupported states.

Expected: PASS with the complete check list and selected detail visible at `1120 × 720`; model states still explain version mismatch and recovery, and model download remains confirmation-gated.

- [ ] **Step 7: Commit the diagnostics redesign**

```bash
git add macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git commit -m "feat(macos): make diagnostics a one-screen workspace"
```

### Task 4: Align all page chrome with the title system

**Files:**
- Modify: `macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift`
- Modify: `macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift`
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

**Interfaces:**
- All pages use `PageIntroView` only for one purpose sentence; no page repeats the toolbar title as a large body heading.
- `SectionHeading` preserves child accessibility semantics and does not merge unrelated page headings with adjacent content.
- All page surfaces use the existing `speechRailContentSurface`/`speechRailField` hierarchy; do not add a new card style per page.

- [ ] **Step 1: Add route coverage for every top-center title**

Add a UI test helper that opens each route by its accessibility identifier and asserts `workspace-title` contains the expected title from the route contract: `配音台`, `音色创作`, `音色库`, `我的作品`, `服务状态`, `运行监控`, `模型管理`, `系统诊断`.

- [ ] **Step 2: Run the route coverage test before alignment**

Run: the new route title test.

Expected: FAIL for at least the routes whose title is currently only a raw toolbar `Text` or whose page adds an unrelated toolbar item set.

- [ ] **Step 3: Remove duplicated page title treatments**

Keep each page’s existing functional content, including VoiceDesign candidate generation, playback, save-to-library, model operations, monitoring chart, service commands, and Works inspector. Only remove duplicated title text and relocate actions to their owning surfaces.

- [ ] **Step 4: Fix semantic boundaries**

Use explicit accessibility containment for `PageIntroView`, `SectionHeading`, diagnostic summary/list/detail, model operation status, and Works developer inspector so adjacent SwiftUI `Text` values do not collapse into an unqueryable macOS 26 node. Keep labels concise and values informative.

- [ ] **Step 5: Run creator/model/monitoring/works UI tests and commit**

Run: `scripts/macos_app_test.sh` for voice design, model download confirmation, recovery, unsupported state, monitoring empty state, and works inspector tests.

Expected: PASS without requiring an installed App bundle; model download still opens an explicit confirmation dialog, and test assertions use stable identifiers or label predicates where macOS 26 merges adjacent text.

Commit:

```bash
git add macos/SpeechRailApp/SpeechRailApp/ServiceOverviewView.swift macos/SpeechRailApp/SpeechRailApp/RuntimeMonitoringView.swift macos/SpeechRailApp/SpeechRailApp/ModelManagementView.swift macos/SpeechRailApp/SpeechRailApp/PreflightDiagnosticsView.swift macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift macos/SpeechRailApp/SpeechRailApp/WorkspaceComponents.swift macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift
git commit -m "fix(macos): align all workspaces with shared page chrome"
```

### Task 5: Run visual/accessibility verification and clean test artifacts

**Files:**
- Modify: `scripts/macos_app_test.sh` only if a cleanup gap is proven by a failing cleanup check
- Test: `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`
- Inspect: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`

**Interfaces:**
- The test script’s `cleanup_test_artifacts` must unregister both temporary app bundles and delete its unique derived-data directory.
- No installed `/Users/hrygo/Applications/SpeechRail.app` bundle may be used as a test target.

- [ ] **Step 1: Run the complete macOS App test suite from a clean install state**

Before the run, verify the installed old App path is absent. Run `scripts/macos_app_test.sh` without manual CUA interaction.

Expected: all unit and UI tests pass; no test bundle is installed into `/Users/hrygo/Applications`.

- [ ] **Step 2: Run visual inspections at the required states**

Build Debug to a disposable derived-data path and inspect the following states at `1120 × 720` and a wide window: service overview, diagnostics all-pass, diagnostics failure, model download confirmation, monitoring empty state, VoiceDesign candidate rack, and Works inspector. Inspect Light, Dark, and High Contrast appearances when available.

Expected: title hierarchy is clear, right-side actions are labeled, diagnostics fits the main content in one screen, selected sidebar text is readable, and icon optical sizes are consistent.

- [ ] **Step 3: Clean the visual test App**

Quit the exact temporary bundle, unregister it with LaunchServices, remove its disposable derived-data directory, and verify no process matches `SpeechRailAppUITests-Runner`, `speechrail-macos-test.*`, or a temporary `SpeechRail.app` path.

- [ ] **Step 4: Commit only any proven test cleanup change**

If the existing script passes the cleanup check, do not change it. If a gap is proven, update the cleanup trap and add a deterministic shell-level assertion without using broad process matching.

### Task 6: Run full project gates and prepare the 2.6.0 release commit

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `pyproject.toml`
- Modify: `src/speechrail/__init__.py`
- Modify: `src/speechrail/config/__init__.py`
- Modify: `contracts/openapi.yaml`
- Modify: `configs/speechrail.example.env`
- Modify: `configs/speechrail.example.yaml`
- Modify: `tests/test_app_contract.py`
- Modify: `tests/test_installer.py`
- Modify: `tests/test_release_verification.py`
- Modify: `macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj`
- Modify: `uv.lock`
- Test: all project gates listed below

**Interfaces:**
- All version declarations must resolve to `2.6.0`.
- macOS App `MARKETING_VERSION` is `2.6.0` and `CURRENT_PROJECT_VERSION` is `2`.
- Existing version consistency script remains authoritative for duplicate version locations.

- [ ] **Step 1: Review the staged and unstaged diff**

Run: `git status --short --branch`, `git diff --stat`, and `git diff --check`.

Expected: only the known release files and the completed macOS redesign are present; unrelated user changes remain untouched.

- [ ] **Step 2: Run Python and contract gates**

Run:

```bash
env -u SPEECHRAIL_API_KEY uv run --extra dev pytest
uv run --extra dev ruff check src tests tools examples/perf .agents/skills/speechrail-perf-benchmark/scripts/prepare_fixtures.py
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
uv run python scripts/check_version_consistency.py
plutil -lint deploy/macos/com.speechrail.plist.example
plutil -lint macos/SpeechRailApp/Resources/LaunchAgents/com.speechrail.desktop.control.plist
git diff --check
```

Expected: all checks pass; no secrets, model files, audio, logs, benchmark raw artifacts, or build products enter Git.

- [ ] **Step 3: Build and test the macOS App**

Run:

```bash
scripts/macos_app_build.sh --configuration Release
scripts/macos_app_test.sh
```

Expected: Release build succeeds on macOS 26 arm64 and the complete App test suite passes. The known AppIntents metadata warning is recorded only if it remains non-fatal and unchanged.

- [ ] **Step 4: Build the wheel and record an external digest**

Run:

```bash
env -u SPEECHRAIL_API_KEY uv build --no-sources --wheel
shasum -a 256 dist/speechrail-2.6.0-py3-none-any.whl
```

Keep the wheel outside Git’s tracked files; record its path and digest in the release report.

- [ ] **Step 5: Commit the release**

Stage the completed design and release changes after inspecting the staged diff:

```bash
git add CHANGELOG.md configs/speechrail.example.env configs/speechrail.example.yaml contracts/openapi.yaml macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj pyproject.toml src/speechrail/__init__.py src/speechrail/config/__init__.py tests/test_app_contract.py tests/test_installer.py tests/test_release_verification.py uv.lock
git diff --cached --check
git diff --cached --stat
git commit -m "release: prepare SpeechRail 2.6.0"
```

### Task 7: Publish main, tag the release, and clean only merged branches

**Files:**
- Git state: `main`, tag `v2.6.0`, local merged branch `fix/issue-14-speechrail-contract`
- External artifacts: release wheel and any local App package outside the repository

**Interfaces:**
- `main` must contain the release commit and be pushed without force.
- `v2.6.0` must point to the release commit.
- A branch is deletable only after `git log main..<branch>` and `git diff main...<branch>` show no unique commits or changes, and no worktree uses it.

- [ ] **Step 1: Verify branch and remote state before mutation**

Run: `git branch -a -vv`, `git worktree list --porcelain`, `git log main..fix/issue-14-speechrail-contract`, and `git diff --stat main...fix/issue-14-speechrail-contract`.

Expected: the fix branch is fully merged and no remote non-main branch is deleted without separate evidence.

- [ ] **Step 2: Push main and create the annotated tag**

Run:

```bash
git push origin main
git tag -a v2.6.0 -m "Release 2.6.0"
git push origin v2.6.0
```

Expected: no force push and the tag resolves to the pushed release commit.

- [ ] **Step 3: Create the hosted release when authenticated**

Inspect recent release conventions with `gh release list --limit 5`. If `gh` is authenticated, create the release with the version changelog and attach only the external wheel artifact. If authentication is unavailable, report that the main branch and tag were pushed and leave the hosted release creation for the user.

- [ ] **Step 4: Delete only the confirmed merged local branch**

Run: `git branch -d fix/issue-14-speechrail-contract`.

Expected: safe deletion succeeds without force; `main`, `origin/main`, and any unmerged branch remain.

- [ ] **Step 5: Install only after uninstalling the old App**

If a local release App is requested as part of the release handoff, first verify `/Users/hrygo/Applications/SpeechRail.app` is absent and quit any exact old bundle. Move an existing old bundle to Trash, verify the path is absent, then install the new `2.6.0 (2)` App and verify its bundle identifier, deployment target, version, signature type, and digest. Keep a rollback ZIP outside the repository.

- [ ] **Step 6: Verify the final Git and test state**

Run: `git status --short --branch`, `git describe --tags --always --dirty`, `git tag --points-at HEAD`, `git branch -a -vv`, and the exact test-process cleanup check.

Expected: clean `main` at `v2.6.0`, no leftover test App/runner/temp process, and a release report that distinguishes the published artifact from the still-running service runtime.
