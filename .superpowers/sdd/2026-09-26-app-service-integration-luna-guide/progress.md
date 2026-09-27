# SDD ledger — plan: docs/superpowers/plans/2026-09-26-app-service-integration-luna-guide.md

Execution: inline on `codex/app-service-integration`; implementation initially remained uncommitted. The user later explicitly authorized committing, pushing this branch, and creating a PR. Installation and publication remain outside scope.

Execution tooling: `executing-plans/scripts/task-start` and `task-done` are installed, but both require the unavailable sibling `subagent-driven-development/scripts` directory. Track the six plan slices manually here. No subagents are used.

Pre-flight:
- S1 capability binding → S2 request consumers: snapshot selector must provide exact per-voice model revision; establish this before client fallback removal.
- S2 current-only client → S3 idempotency and candidate surfaces: retain existing clone POST key, add status GET; candidate cancel is POST.
- S4 VoiceDesign asset contract → S6 OpenAPI/docs: service, schema, tests, client and user docs move together.
- S5 Realtime event identity → session consumers: connection generation/session identity must be enforced before delivery; preserve session-scoped diarization finish.

Ruling: Use a feature branch because implementation is authorized and the current checkout was `main`; preserve the pre-existing uncommitted design and plan files. Cost if wrong: local branch naming/placement only; no user edits discarded.
Ruling at implementation start: Keep UI automation, app launch/install, managed-service lifecycle, model actions and remote Git out of scope because they require separate current-message authorization. The user later authorized remote Git only for submitting this branch as a PR; UI takeover and runtime/release actions remain unauthorized. Cost if wrong: those acceptance dimensions remain explicitly unverified.

## Progress — 2026-09-26 (Asia/Shanghai)

- S1–S6 implementation is present in the worktree. The capability facade stays in `AppModel.swift`; `RealtimeEventState` stays in `RealtimeASRClient.swift`; tests use existing suites rather than new Swift test files.
- D1 reference/validation audio routes, candidate revision checks, WAV/PCM identity checks, client/UI review gating, OpenAPI and user docs are implemented. Final review also moved confirm/publish reads through the repository validator and added state checks so stale confirmation or publication cannot overwrite a concurrent cancel.
- Realtime now validates event sequence/session identity before dispatch, bounds the event/audio queues and per-item state, merges same-revision auxiliary shards, and emits an explicit close on overflow. The oversized-transcript transport fixture now uses normal server metadata stamping.
- Deterministic evidence: RealtimeContractTests 27 passed; grouped AppModel/ServiceContract/ControlKit/RealtimeTTS/StreamingTTS tests 89 passed plus 14 TeleprompterSessionLifecycleTests; AssistantTTSStreamCoordinatorTests 14 passed; CreativeWorkStoreTests 5 passed; VoiceDesign/OpenAPI pytest 23 passed; relevant Ruff checks passed. Contract scripts reported 41 realtime fixtures/32 fields and 39 OpenAPI paths/47 operations. Debug App build succeeded.
- The authorized default VoiceDesign candidate JSON and asset paths were absent; no local data was deleted. UI automation, manual app/audio review, real service/runtime, Release build and performance/quality benchmarks remain `not_run`.
