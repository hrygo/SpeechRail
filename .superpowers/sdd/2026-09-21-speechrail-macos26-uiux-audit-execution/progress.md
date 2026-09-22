# SDD ledger — plan: docs/superpowers/plans/2026-09-21-speechrail-macos26-uiux-audit-execution.md

## Setup

- Ruling: inline execution in the existing worktree — the user explicitly requested complete implementation and acceptance, and the current worktree contains nine pre-existing changes that an isolated worktree would not include; cost if wrong: parallel changes require file-level conflict checks throughout.
- Baseline: main, working tree dirty before this plan; the new plan file is the only change created by the planning turn.
- Constraint: no commit, push, publish, model/service operation, or UI automation without the applicable authorization.

## Pre-flight shared interfaces

- Task 1 → Task 2: the audit matrix consumes the 14-route AppRoute source of truth; verified that AppRoute.swift is the current route declaration and that the matrix will be created before route edits.
- Task 2 → Task 3: ControlCenterView and AppNavigationState consume AppRoute navigation and WindowLayoutTier independently; route registry changes must not move layout policy into AppRoute.
- Task 3 → Task 4: shared PageScaffold and page Inspector behavior consume WindowLayoutContract; the contract remains pure and view-free so Swift Package tests can cover it.
- Task 4 → Task 5: session pages consume shared PageScaffold and motion/accessibility semantics; session domain enums remain unchanged.
- Task 5 → Task 6: copy and token cleanup consumes the page state/action inventory; no token edit may change session behavior.
- Task 6 → Task 7: final matrix and active docs consume only implemented changes with fresh evidence; unverified desktop/UI automation items remain explicitly unverified.

## Task status

- Task 1: complete (no commit; docs-only; tests: route identifier scan found all 14 routes; git diff --check → pass)
- Task 2: complete (no commit; route registry/shortcut contract implemented; static contract script passed; final Swift Package tests, Debug app build, and authorized 255/255 App test plan passed)
- Task 2 ruling: add `scripts/check_macos_route_contract.sh` — `AppRoute` is app-target code and is not importable by the package test target, while UI automation is not authorized; a reusable source contract check provides red/green evidence without changing target boundaries. Cost if wrong: source-pattern checks can miss runtime menu/accessibility regressions, which remain pending authorized UI verification.
- Task 3: complete (no commit; `WindowLayoutContract` and pure boundary coverage passed; authorized four-size UI matrix verified frame constraints, native sidebar/Inspector collapse/restore, and primary-action containment on six representative routes)
- Task 4: complete (no commit; `PageScaffoldLayout`, shared status/semantic components, and Reduce Motion immediate/static paths built and tested; user clarified full VoiceOver navigation is outside the target audience and is not an acceptance blocker; basic keyboard, focus, label/value/hint, and non-color state semantics remain)
- Task 4 ruling: the current macOS SDK does not provide a writable preview override for `accessibilityReduceMotion`, and the expected `accessibilityContrast` environment key is unavailable in the current preview surface. Named Reduce Motion/High Contrast previews remain semantic fixtures, not simulations; system-setting conclusions are limited to the manual samples recorded in the matrix.
- Task 5: complete (no commit; Assistant, Meeting, Captions and Teleprompter now use `SessionPageStatusPresentation` only for rendered status fields; actual actions remain in their controls and are inventoried in the matrix; unused duplicate action/Inspector metadata was removed)
- Task 6: complete (no commit; Settings semantic tokens, shortcut/help copy, token scatter ledger, lived-in previews and active design docs updated; static checks and Debug app build passed)
- Task 7: complete within the clarified product scope (no commit; 14-route manual sample, authorized four-size UI matrix, final 255/255 App test plan, Package tests, Debug build, static contract and docs verified; non-blocking searchable/List, larger-text, and real-live capture coverage remains documented; no TCC permission was changed)

## Verification snapshot — 2026-09-22

- `scripts/check_macos_route_contract.sh` → pass: 14 enum cases, 14 shortcut specs, 14 UI test entries, 14 matrix entries, one registry.
- `swift test --package-path macos/SpeechRailApp` → exit 0; 159 XCTest and 85 Swift Testing cases pass.
- `scripts/macos_app_build.sh --configuration Debug` → exit 0; Xcode 27 / macOS 27 SDK, arm64 target, deployment target macOS 26.0; `** BUILD SUCCEEDED **`.
- `scripts/check_macos_route_contract.sh` → pass: 14 enum cases, 14 shortcut specs, 14 UI test entries, 14 matrix entries, one registry.
- `testControlCenterHonorsRequestedWindowSizes` → authorized `.xcresult` pass 1/1; 4 frame requests, sidebar/Inspector collapse/restore, and six representative route primary actions contained.
- `testWorksViewExposesSelectionAndExportActions` → pass 1/1 after updating the assertion to the selected-work File-menu title (`导出“测试作品”…`) and checking row/Inspector export controls.
- Full `xcodebuild ... -testPlan SpeechRailApp test` → `.xcresult` 255 passed, 0 failed, 0 skipped.
- Initial `scripts/macos_app_test.sh` runner automation-mode timeout (exit 65) was recovered by direct Xcode test-plan execution; no TCC permission was changed.
- `git diff --check` → pass.
- `git diff --check` → pass.
- Source scan for the retired PageScaffold names (`scrollable`, `growsWithContent`, `minimumContentHeight`) → no matches in the macOS app sources.
- Reduce Motion animation audit → page-shell transaction and explicit shared/session/page animation call sites reviewed; code/build evidence pass, system-setting behavior remains manual/unverified.
- Full-app Reduce Motion follow-up → found and fixed unguarded InnerOS drawer transition, Runtime Monitoring receipt transition and Creator waveform stop animation; final app-wide call-site scan has no unconditional `.smooth`, pulse stop animation, or transition left in scope.
- Focus/width contract audit → `SessionPanelToggle` exposes a stable accessibility identifier and `FocusState` restoration path on Assistant/Meeting/Session Library; `minimumPrimaryContentWidth` is consumed by the detail surface; code/build evidence pass, keyboard behavior remains manual/unverified.
- After explicit 2026-09-22 authorization, an initial script entry hit `XCTFuture Code=1000: Timed out while enabling automation mode` (exit 65); direct Xcode test-plan execution subsequently passed all 255 cases. No TCC permission was changed.

## Authorized desktop verification — 2026-09-22

- 14/14 sidebar routes opened; workspace identity and first-screen task/actions matched; only read-only checks were performed.
- Assistant, Meeting, Captions and Teleprompter idle states were visible; no recording, capture, audio generation, model operation or service control was started.
- Light, Dark, Increase Contrast and Reduce Transparency were observed on representative screens. Reduce Motion and the larger reading-text preference were toggled; the latter did not visibly enlarge SpeechRail text in the sampled Developer Docs page. VoiceOver was used only for exploratory AX/keyboard inspection; full VoiceOver navigation is out of scope under the clarified target audience, while basic label/value/hint and keyboard semantics remain required.
- Baseline restored: Appearance Auto; Increase Contrast, Reduce Transparency and Reduce Motion off; reading text size default; VoiceOver off. SpeechRail returned to Assistant idle with sidebar visible and Inspector collapsed.
- Display Settings reported LG HDR 4K at `1920×1080 (default)`. The authorized UI matrix now measures native `NSWindow` frames directly: the 1120×720 workspace request yields a 1120×760 outer frame because of titlebar chrome; 1280×800 and 1440×900 match; 1920×1080 is capped by the visible screen frame. Six representative page actions remain within each tested window.
- Ruling: CUA screenshot pixel dimensions remain capture-only. Frame assertions and control/action checks come from XCUITest, not screenshot scaling. `searchable`/List behavior across every route and size remains explicitly uncovered.
