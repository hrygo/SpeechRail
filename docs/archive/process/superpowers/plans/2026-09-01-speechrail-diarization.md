# SpeechRail Public Speaker Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore multi-speaker meeting capability through a reusable SpeechRail diarization profile without moving meeting ownership into the public runtime.

**Architecture:** A vendor-neutral domain port produces session-scoped anonymous assignments and a final remap. The FastAPI Realtime v2 gateway only orchestrates the port and serializes additive events. `sona` maps those events into meeting entities and removes its ineffective acoustic runtime.

**Tech Stack:** Python 3.12, Pydantic v2, FastAPI WebSocket, pytest, PostgreSQL meeting repository.

**Spec:** `docs/superpowers/specs/2026-09-01-speechrail-diarization-design.md`

## Global Constraints

- SpeechRail remains an ASR/TTS public runtime; it owns no meeting state, identity, database or playback.
- No model download, PCM persistence, hidden fallback, or unbounded audio buffer.
- All public additions are backward-compatible and return existing error envelopes.
- Python is `>=3.12,<3.13`; use `uv`, strict mypy, Ruff and deterministic fake backends.

---

### Task 1: Define public domain and wire contracts

**Files:**
- Create: `src/speechrail/domain/diarization.py`
- Modify: `src/speechrail/domain/contracts.py`, `src/speechrail/domain/ports.py`, `src/speechrail/realtime/v2_session.py`, `contracts/realtime-v2.md`
- Test: `tests/test_diarization_contracts.py`, `tests/test_realtime_v2_session.py`

- [x] Write failing contract tests for valid/invalid anonymous labels, overlap assignments, 1–8 hint validation and a final mapping.
- [x] Implement immutable Pydantic models and the `DiarizationEngine` / session ports; validate vendor output at this boundary.
- [x] Extend `TranscriptionSession` with additive diarization configuration and ordered final mapping event.
- [x] Run the focused tests, then commit `feat: define public diarization contract`.

### Task 2: Add bounded orchestration to Realtime v2

**Files:**
- Create: `src/speechrail/runtime/diarization.py`
- Modify: `src/speechrail/app.py`, `src/speechrail/config/__init__.py`, `src/speechrail/runtime/resource_governor.py`
- Test: `tests/test_realtime_v2_websocket.py`, `tests/test_diarization_runtime.py`

- [x] Write failing WebSocket tests for enabled diarization, unavailable profile, segment annotation and commit-before-finalize ordering.
- [x] Implement the in-memory bounded session adapter and dependency injection seam; use the existing Resource Governor rather than a second queue.
- [x] Map unavailable/invalid engine outcomes to stable protocol errors and ensure cancel releases all state.
- [x] Run focused tests, then commit `feat: stream diarization through realtime v2`.

### Task 3: Migrate the meeting client and remove ineffective acoustic ownership

**Files:**
- Modify: `../sona/src/sona/asr/adapters/speechrail_realtime.py`, `src/sona/meeting/session.py`, `src/sona/ui/server.py`, `src/sona/config.py`
- Delete: `src/sona/meeting/voiceprint.py` and its tests after confirming no remaining references
- Test: `../sona/tests/asr/test_speechrail_realtime.py`, `tests/test_meeting_session.py`, `tests/test_config.py`

- [x] Write failing adapter tests for multi-speaker mapping, overlap primary selection and fail-closed meeting startup.
- [x] Implement event parsing and remap propagation through the meeting port; retain only application-level smoothing and identity mapping.
- [x] Delete CAM++/AHC configuration and full-meeting PCM buffering; update tests and documentation references.
- [x] Run focused tests, then commit `refactor: consume SpeechRail diarization in meetings`.

### Task 4: Integrate, document and verify

**Files:**
- Modify: `contracts/openapi.yaml`, `docs/08-migration-runbook.md`, `docs/11-operations-runbook.md`, `../sona/README.md`
- Test: both repositories’ complete suites plus static and frontend gates

- [x] Update contract and operations docs with profile configuration, resource limits, privacy guarantees, known real-model gate and rollback.
- [x] Fix pre-existing test isolation failures without re-enabling legacy ASR.
- [ ] Run full validation and real local smoke tests, inspect the complete diff, commit each repository, and merge only verified commits into `main`.
