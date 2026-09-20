# SDD ledger — plan: docs/superpowers/plans/2026-09-20-settings-general-user-ux.md

Pre-flight: shared interfaces found — Task 1 produces the explicit `LLMKeyDraftPolicy` save decision consumed by Tasks 3–4; Task 2 produces shared settings helpers consumed by Tasks 3–4; Task 3 produces the bindings/closures consumed by Task 4; Task 5 documents and tests the behavior produced by Tasks 1–4; Task 6 verifies the complete branch.

Ruling: executing-plans helper scripts — `subagent-driven-development` is not installed in the available skill roots, so `task-start`, `task-brief`, `task-done`, and `review-package` cannot run; I will preserve the same task order, BASE/test evidence, and completion records manually in this ledger. Cost if wrong: the manual ledger may lack helper-generated briefs, so the final self-review must re-read the full plan and spec.

Task 1: complete (uncommitted working tree, tests: swift test --package-path macos/SpeechRailApp --filter SettingsKeyDraftPolicyTests → Executed 2 tests, with 0 failures)

Task 2: complete (uncommitted working tree, tests: xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -configuration Debug -destination 'platform=macOS' build → BUILD SUCCEEDED)

Task 3: complete (uncommitted working tree, tests: xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -configuration Debug -destination 'platform=macOS' build → BUILD SUCCEEDED)

Task 4: complete (uncommitted working tree, tests: xcodebuild -project macos/SpeechRailApp/SpeechRailApp.xcodeproj -scheme SpeechRailApp -configuration Debug -destination 'platform=macOS' build → BUILD SUCCEEDED)

Task 5: complete (uncommitted working tree, active design-system contract, UI-test source assertions, and implemented spec updated; UI automation intentionally not run)

Task 5: Ruling: unit-test entrypoint — the Xcode `SpeechRailApp` scheme does not include the SwiftPM-only `SpeechRailMacControlTests` target, so the planned `xcodebuild -only-testing` command fails before compilation; use the repository's actual `swift test --package-path macos/SpeechRailApp --filter SettingsKeyDraftPolicyTests` command. Cost if wrong: an Xcode test-plan change would be broader than this settings refactor.

Task 6: complete (uncommitted working tree, final VCS scope check, Debug build, build-for-testing, focused policy test, focused URL validation test, and full SwiftPM test all passed)

Final review: self-review (no subagent tool available) — re-read the complete spec and plan, reviewed all tracked and new task files, checked settings tab order, plain-language copy, explicit Keychain save gating, module fallback presentation, UserDefaults/Keychain boundaries, Xcode/SwiftPM source registration, accessibility composition, and secret/path exclusion. One important finding was fixed: module status now inspects the raw override instead of the resolved global fallback, and URL query/fragment rejection now has a regression test. No remaining Critical or Important findings; UI/frontmost/real-service verification remains explicitly unverified.

Ruling: the spec acceptance checklist marks the visual/accessibility item as unverified because the project rules require current user authorization for UI automation; all deterministic implementation and build checks are complete.

Final verification rerun: 2026-09-20 22:11 CST — `swift test --package-path macos/SpeechRailApp` passed (126 XCTest + 28 Swift Testing); `scripts/macos_app_build.sh --configuration Debug` passed; Xcode `build-for-testing` passed; tracked and new-file whitespace checks passed with no output; no UI automation or runtime mutation performed.
