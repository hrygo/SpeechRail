# SDD ledger — plan: docs/superpowers/plans/2026-09-20-macos-app-contract-alignment-plan.md

Setup: Native inline execution selected by the user. Worktree is the shared SpeechRail checkout on branch main; the user explicitly authorized implementation in this checkout by selecting Native after reviewing the plan.

Setup: Plan and spec read. Existing commits 30b0cafb (spec) and 00b7617e (plan) are the plan baseline. Existing unrelated dirty files remain protected and must never be staged.

Ruling: executing-plans helper scripts are unavailable at the documented path because /Users/hrygo/.agents/skills/subagent-driven-development does not exist. Use this ledger and direct read-only git checks as the equivalent bookkeeping; do not invent dispatch or review scripts.

Ruling: Project AGENTS.md forbids automated tests, UI automation, full gates, and build acceptance without explicit authorization in the current user message. Write the planned RED tests, but do not execute test/build/UI commands; record every skipped validation and do not claim test-passed completion.

Ruling: Moving ServiceAPIClientError into SpeechRailControlKit required updating the existing AppModel error switches and UITest creator failure to the new http case during Task 2, even though the plan listed those call sites under Task 8. This preserves one shared error type; cost if wrong: the compatibility edits are included in the Task 2 boundary and must be reviewed with the final error mapping.

Ruling: ServiceAPIClient conditional discovery methods have an overload accepting cachedValue so the AppModel can satisfy 304 reuse while the protocol-facing method still accepts only ifNoneMatch. Cost if wrong: callers that do not pass cache receive the specified notModifiedWithoutCache error.

Ruling: Task 1/2 contract source files were not present in the native Xcode source phases, even though SwiftPM auto-discovers them. Task 4 wires ServiceContractTypes, ServiceHTTPTransport and ServiceContractTests into project.pbxproj so the Native app/test targets compile the same contract sources as Package.swift.

Pre-flight: Task 1 produces ServiceContractTypes, ServiceAPIClientError, ServiceContractDecodingError, ServiceResponseDecoder, ServiceConditionalResponse, CapabilitySnapshotStore, ServiceErrorClassifier and health revision fields; Task 2 consumes the HTTP/error types, Task 3 consumes discovery state and readiness, Task 4 consumes error/DTO types, Task 5 consumes request/audio types, and Task 6 consumes shared Realtime types. Names are consistent after the plan self-review.

Pre-flight: Task 2 produces ServiceRequestBuilder, ServiceHTTPTransport, ServiceRawHTTPResponse and ServiceCapabilityDiscoveryClient; Task 3 consumes discovery methods and Task 5 consumes the response metadata/audio adapter. No conflicting signature found.

Pre-flight: Task 3 produces AppModel effectiveCapabilities, safeVoiceCatalog, discoveryState and refreshDiscovery; Task 7 consumes the snapshot for Realtime revision negotiation. No conflicting signature found.

Pre-flight: Task 6 produces generic RealtimeEventEnvelope<Payload>, RealtimeSequenceValidator, RealtimeCloseBarrier and RealtimeASRClient drainAndClear; Task 7 consumes the envelope and close API. The earlier undefined payload name was corrected in the plan before execution.

Pre-flight: Task 8 consumes ServiceErrorClassifier from Task 1 and the fake protocol defaults from Tasks 2–4. No conflicting signature found.

Tasks:
- Task 1: implemented in commit 5571608; RED/GREEN test commands not run because project authorization forbids automated validation in this turn.
- Task 2: implemented in commit 863d1af; RED/GREEN test commands not run because project authorization forbids automated validation in this turn. Static diff check passed.
- Task 3: implemented in commit ccd14b3; AppModel now retains atomic capability snapshots and safe Voice catalog with ETag/304 generation guards, maps legacy capability only from explicit snapshot fields, falls back to `/v1/models` only for 404/405 or invalid schema, and all three session readiness checks use typed `/readyz`; RED/GREEN test commands and build/UI validation not run because project authorization forbids automated validation in this turn.
- Task 4: implemented in commit 4583c69; CreatorVoice/quality/revision/provenance DTOs are additive, CAS/rollback/revoke and pronunciation-set methods use namespaced routes, quality-run fallback is limited to 404/405, and legacy Creator methods remain source-compatible. RED/GREEN test commands and build/UI validation not run because project authorization forbids automated validation in this turn.
- Task 5: implemented in commit 9cb03ef; `synthesize` returns typed audio metadata for all `audio/*` formats, receipt/timing/transcription/job methods are typed, multipart field names follow the current contract, and required response fields map to invalidContract. RED/GREEN test commands and build/UI validation not run because project authorization forbids automated validation in this turn.
- Task 6: implemented in commit 11be273; Realtime event metadata/envelope, sequence validator, close barrier, `?model=` negotiation, model-revision/render-receipt session extensions, response receipt/busy decoding, and `commit → terminal → clear` drain API are in place. Automated tests/build/UI validation were not run because project authorization forbids automated validation in this turn.
- Task 7: implemented in commit 186bb1f; Assistant/Caption/Meeting now consume Realtime envelopes, close logical recordings through the shared `commit → terminal → diarization → clear → close` barrier, and Assistant conditionally negotiates the snapshot-declared TTS catalog revision. Automated tests/build/UI validation were not run because project authorization forbids automated validation in this turn.
- Task 8: implemented in commit 742cad9; final read-only review covered shared error classification, typed response/audio metadata, atomic capability snapshot behavior, Realtime sequencing/close barrier, Native target wiring, and task commit boundaries. The review found and fixed `voice_revoked` being collapsed into the generic connection category, with a regression case added. `git diff --check` passed. Automated tests/build/UI validation were not run because project authorization forbids automated validation in this turn.
