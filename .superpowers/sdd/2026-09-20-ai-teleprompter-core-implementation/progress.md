# SDD ledger — plan: docs/superpowers/plans/2026-09-20-ai-teleprompter-core-implementation.md

Setup: current worktree retained; branch `feat/teleprompter-core-preparation` is isolated from `main`.

Pre-flight: shared interfaces
- Task 1 → Task 2: source units, pace, and timing allocation are the input to prompt payloads; keep ranges and budget mode value-semantic.
- Task 1 → Task 3: source units and timing plan are the Map window and local-budget source; pipeline must not recalculate a second weighting model.
- Task 2 → Task 3: prompt builders/decoders define the only accepted Map/Reduce wire shapes; pipeline must persist only decoded values.
- Task 1/3 → Task 4: v2 store serializes source revisions, allocations, and reading blocks; stored IDs must remain stable across one preparation run.

Ruling: the repository does not contain the optional `subagent-driven-development` scripts referenced by executing-plans; use the available inline executor flow and maintain this ledger manually. Cost if wrong: review-package automation cannot be used, so final review will be an explicit self-review with fresh commands.

Task 1: Ruling: reuse the parallel `TeleprompterTimingPolicy.swift` and the added Domain review/value types instead of defining duplicate pace/review/block symbols; add only their Package source membership and preserve their contents. Reason: the current dirty worktree already has `TeleprompterDomain.swift` referring to that policy, and the package otherwise cannot compile. Cost if wrong: the UI team's later PR may need to resolve a shared source-membership/file overlap.

Task 1: complete (commit 00c94f97, tests: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparationDomainTests` → 7/7 passed)
Task 2: complete (commit ebe586a7, tests: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparationPromptsTests` → 5/5 passed)
Task 3: complete (commit 6b096a80, tests: `swift test --package-path macos/SpeechRailApp --filter TeleprompterPreparationPipelineTests` → 5/5 passed)
Task 4: complete (focused tests: `swift test --package-path macos/SpeechRailApp --filter TeleprompterV2StoreTests` → 6/6 passed)
