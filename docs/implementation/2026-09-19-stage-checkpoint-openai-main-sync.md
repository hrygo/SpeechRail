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
