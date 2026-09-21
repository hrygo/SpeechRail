# SDD ledger — plan: docs/superpowers/plans/2026-09-21-teleprompter-workflow-reliability.md

Setup: executing inline in the authorized current worktree `main`; no separate worktree was created because the user authorized implementation in the shared workspace.

Pre-flight: shared interfaces found between Task 1 diagnostics, Task 2 provider mode, Task 3 stage protocol/recovery, Task 4 session/UI, and Task 5 docs/quality. Spec authority: `docs/superpowers/specs/2026-09-20-ai-teleprompter-final-spec.md`; ADR authority for this change: `docs/decisions/0020-teleprompter-workflow-reliability.md`.

Ruling: keep the existing JSON mode as a supported provider path — the final teleprompter specification explicitly defines it as the current compatibility strategy; strict structured output is capability-aware optimization, not a mandatory replacement.

Ruling: separate grouping from rewriting while retaining rewriting — the product contract requires an AI-generated natural reading candidate; only the source grouping/range decision is safe to make non-textual.

Ruling: preserve the existing persistence format in this implementation — changing the internal AI wire does not require a user-data migration, and no migration design is currently authorized.

Task 1: complete — added privacy-safe diagnostic codes and decoder mapping for syntax, duplicate keys, schema keys/version, range gaps/overlaps/bounds, group limits, mode mismatch, protected literals, and truncation; added regression coverage. Verification: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparation` → 33 tests passed.

Task 2: complete — added explicit `json_object`/`json_schema` output modes to `LLMProvider`; capable endpoints keep strict JSON Schema, OpenCode Go uses `json_object` proactively because its Chat gateway rejects the `response_format=json_schema` wire shape, and unknown compatible endpoints fall back once only for a precise structured-output capability rejection. Verification: `swift test --package-path macos/SpeechRailApp --filter LLMProviderTests` → 45 tests passed.

Task 3: complete — added `teleprompter.grouping.v1` and `teleprompter.rewrite.v1`, typed decoders, fixed source ownership, bounded retries, deterministic per-window fallback, coverage/count reporting, and protection from Reduce rewriting unresolved fallback blocks. Verification: Preparation-focused tests → 37 tests passed.

Task 4: complete — wired local fallback state through `TeleprompterSession` and the review workspace, including reloaded-draft inference and partial/full fallback messaging. Verification: full SwiftPM test suite passed; Xcode Debug App target build succeeded with signing disabled. No UI automation or visual acceptance was performed.

Task 5: complete for deterministic implementation — synchronized the active teleprompter specification, developer guide, ADR and plan; added the recovery-prompt privacy regression; added the project-wide plain-language/progressive-disclosure rule; simplified the review workspace default path, moved advanced segment editing into a named menu, and changed review text fields to wrapped multiline editors so the full generated text remains visible. Focused and full deterministic verification passed. Real-model holdout, human fact review and UI visual/interaction acceptance remain explicitly pending.

Final self-review: no subagent-driven-development tool was available in this environment, so the review was performed inline. Checked the changed-file set, `git diff --check`, red-green focused tests, final full SwiftPM tests (155 XCTest + 83 Swift Testing), Release App build after the multiline-editor change, bundle/signing/XPC verification, and installation launch. Installed `SpeechRail.app` remains `3.1.3 (25)` at the unique user path; its executable SHA-256 matches the retained Release artifact and differs from the pre-wrap-install binary. Managed service runtime/profile were not changed or restarted; `8201/health` was rechecked as ready. Real OpenCode live-model acceptance and UI visual/interaction acceptance remain pending a user-triggered retry because no UI automation was authorized.
