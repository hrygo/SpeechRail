---
title: "SpeechRail issue acceptance checkpoint — OpenAI compatibility and main sync"
status: active
date: 2026-09-19
---

# Stage checkpoint

Repository: `hrygo/SpeechRail`  
Integration PR: #74 (`feat/issue-acceptance-20260919` -> `main`)

This checkpoint records the state immediately before integrating the latest main branch.
It is evidence/history only; it does not declare all 15 issues accepted or the PR merge-ready.

## Protocol correction completed

- `POST /v1/audio/speech` is the single OpenAI-compatible TTS entry point.
- The temporary SpeechRail `/v2/audio/speech` design was removed.
- SpeechRail-only strong-consistency controls are optional request headers:
  - `SpeechRail-Expected-Voice-Revision`
  - `SpeechRail-Pronunciation-Set`
  - `SpeechRail-Receipt-Mode: integrity`
- SpeechRail management/discovery endpoints are namespaced under `/v1/speechrail/*`.
- The OpenAI speech request accepts either a string voice or a custom voice object
  `{"id":"voice_1234"}`.
- Historical SpeechRail `/v1/voices*` management endpoints are not claimed to be
  compatible with OpenAI consent-based `POST /v1/audio/voices` until an equivalent
  consent lifecycle exists.

## OpenAPI recovery

`contracts/openapi.yaml` had accumulated repeated sections after an unsafe scripted
replacement interpreted `$'` in regex-like YAML text as a JavaScript replacement token.

Recovered contract properties:

- one `components:` section;
- one `SpeechRequest` schema;
- one `/v1/audio/speech` path;
- no `/v2/` paths;
- SpeechRail extension headers explicitly documented;
- custom voice object request shape explicitly documented.

The recovered contract is approximately 76 KiB instead of the corrupted multi-megabyte
document. Subsequent scripted replacements must use literal split/join or an equivalent
non-interpreting replacement primitive for content containing dollar-sign sequences.

## Issue implementation checkpoint

Substantial code now exists for:

- #53 isolated macOS Works UI-test storage and empty-state scenario;
- #62/#71 atomic safe capability discovery and MCP safe consumption;
- #63 content-addressed voice revision, lease pin, CAS update, persisted revision history,
  rollback, revoke, and durable clone idempotency;
- #64 integrity receipts with PCM16 pre-transport sample/hash boundary and terminal states;
- #67 identity-bound quality evidence structures;
- #69 bounded manual ASR collector plus actual WebSocket handler regression matrix;
- #70 immutable pronunciation-set revisions, CAS/revoke, and spoken-text mapping;
- #72 versioned bounded TTS text planner.

#44/#65/#73 still require further implementation/acceptance work. #34/#66/#68 retain
real-model, vendor-interface, performance, and/or acoustic evidence gates that synthetic
tests cannot replace.

## Main drift discovered

Starting base: `28755de8cc51046f25ce75c7869fe1bacd34752d`.

At this checkpoint current `main` is
`2e1205072eeef5e87f09da3d0fa181682bbc472a`:

- feature branch ahead of the original base by 99 commits before this checkpoint;
- latest main ahead of the original base by 43 commits;
- merge base remains the original starting SHA;
- main's new work is concentrated in the macOS session/caption/meeting/assistant layer.

Only two paths were modified by both sides:

1. `macos/SpeechRailApp/SpeechRailApp/App.swift`
2. `macos/SpeechRailApp/SpeechRailAppUITests/SpeechRailAppUITests.swift`

The merge policy is therefore:

- use latest main as the merged tree base;
- replay the feature branch's non-overlapping final blobs directly;
- manually combine only the two overlapping Swift files;
- create a real two-parent merge commit preserving both histories;
- then require current-head CI before further acceptance claims.

## Next execution order

1. integrate latest main without dropping the UI-test isolation increment;
2. verify branch ancestry/diff and trigger current-head PR CI;
3. repair all deterministic regressions until CI is green;
4. continue #65/#44, then #73;
5. finish #66/#68/#34 evidence gates;
6. run Level C final acceptance before marking the PR merge-ready.

No merge into main, deployment, issue closure, model download, or user-service mutation is
authorized by this checkpoint.


## Second checkpoint — scheduling, observability and vendor audit

This checkpoint was recorded after the main-sync merge and the next implementation wave.

### #65 interactive TTS admission

- Added bounded `WorkPurpose`: default, interactive, prefetch, voice_creation,
  quality_validation.
- Public `/v1/audio/speech` accepts only `interactive` and `prefetch` via
  `SpeechRail-Purpose`; arbitrary client priority strings are rejected.
- `SpeechRail-Latency-Budget-Ms` is a bounded relative budget and is capped by
  the server request timeout.
- Existing `ResourceGovernor` remains the single admission authority.
- Added bounded queue-wait/service/release telemetry; no request IDs, voice IDs,
  text or audio are metric labels.
- Realtime, voice creation and quality validation now carry server-owned purposes.

### #44 E2 / E3a / E4

- E2: source release is 2.7.0; old 2.3.0 managed-runtime observations and
  MPS/float16 measurements are explicitly historical. The source default for
  realtime sessions is 3 and is no longer duplicated as a second documentation default.
- E3a: added bounded realtime phases for ASR admission, flush, commit acknowledgement,
  terminal wait, TTS admission and transport send.
- E4: introduced stable busy reasons while preserving public compatibility error codes:
  `asr_mode_conflict`, `realtime_session_limit`, `diarization_capacity`,
  `governor_queue_full`, and `backend_transition`.
- HTTP exposes typed contention only through a SpeechRail header; Realtime uses a
  namespaced `speechrail.busy_reason` field while keeping `backend_busy`/`queue_full`.

### #66 pinned vendor audit

The managed runtime pins `mlx-audio==0.4.8`. Its Qwen3-TTS implementation has a
private `_icl_cache`, but the public generation contract still consumes raw
`ref_audio + ref_text`. The private cache has no SpeechRail-safe public prepared
condition object, bounded lifecycle, cryptographic identity contract, or stable API.

SpeechRail therefore now exposes an immutable prepared-reference provider port but
keeps the pinned backend explicitly unsupported and fail-closed. No private vendor
cache is wrapped or relabeled as a SpeechRail performance feature.

Detailed evidence:
`docs/implementation/2026-09-19-issue-66-prepared-reference-audit.md`.

### CI regression handling

CI #383 surfaced deterministic integration regressions rather than acoustic/runtime
evidence failures:

- Ruff import/export ordering;
- accidental use of an undefined `_time` alias in new realtime phase metrics;
- macOS `AssistantView.State` shadowing SwiftUI's `@State` property wrapper.

The Python lint/name regressions and the Swift shadowing compile failure are corrected
on the feature branch. A fresh current-head CI remains required before acceptance.

### Next

Continue #73 with an honest chunk-level timing contract. Do not claim word/phoneme
precision unless a measured native/forced-alignment path proves it. Then continue the
remaining #44 scheduling/fairness work and the real-model evidence gates.
