# Clone TTS Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the clone loudness controller actually apply its calibration result on the default 200 ms streaming path and add regression evidence for the internal framing behavior.

**Architecture:** Keep the existing request-scoped PCM16 controller and 200 ms bounded clone buffer. Align the default calibration window with that first normalized block so its bounded gain is used for initial calibration; once live gain tracking has started, do not replace a sparse chunk's target with a late calibration estimate. Keep the 200 ms framing private and verify that it preserves sample order/count while explicitly measuring its latency-sensitive boundary.

**Tech Stack:** Python 3.12, `uv`, pytest, Ruff, mypy, Markdown acceptance records.

**Spec:** `docs/superpowers/plans/2026-09-08-clone-tts-loudness-stability.md` and SpeechRail#34 / Sona#10 acceptance criteria.

## Global Constraints

- Do not change the public Realtime event shape or PCM16 sample rate.
- Keep clone loudness state request-scoped and reset it on completion or failure.
- Do not touch unrelated concurrent changes in either repository.
- Do not record raw audio, text, Base64, API keys, or complete loudness sequences.

---

### Task 1: Reproduce the calibration gap

**Files:**
- Modify: `tests/test_tts_loudness.py`

**Interfaces:**
- Consumes: `StreamingPcm16LoudnessController.process()` with 200 ms PCM16 chunks.
- Produces: A regression test proving that the default 200 ms first block becomes the active request baseline.

- [x] **Step 1: Write the failing test**

  Feed one 200 ms quiet chunk and assert that the current request gain equals the computed calibration gain.

- [x] **Step 2: Run the focused test and verify it fails**

  Run `uv run --extra dev pytest --no-cov tests/test_tts_loudness.py -q`.

  Expected: the new test fails because the 240 ms default calibration window is not complete after the first 200 ms block.

### Task 2: Align initial calibration with clone framing

**Files:**
- Modify: `src/speechrail/domain/tts_loudness.py`
- Test: `tests/test_tts_loudness.py`

**Interfaces:**
- Consumes: the existing request-scoped `_calibration_gain_db`.
- Produces: a bounded initial calibration baseline with existing peak ceiling and reset semantics.

- [x] **Step 1: Add request state for one-time calibration application**

  Reset a `_calibration_applied` flag with the rest of request state.

- [x] **Step 2: Set the default calibration window to the private clone buffer duration**

  Use a 200 ms default so the first normalized clone block completes calibration before it is emitted.

- [x] **Step 3: Use the bounded calibration gain only before live tracking starts**

  After `_advance_calibration()`, select `_calibration_gain_db` only while request gain state is still uninitialized. Subsequent chunks continue using live RMS control so sparse late chunks do not pump toward the aggregate calibration estimate.

- [x] **Step 4: Run the focused test and verify it passes**

  Run `uv run --extra dev pytest --no-cov tests/test_tts_loudness.py -q`.

### Task 3: Guard the clone framing behavior

**Files:**
- Modify: `tests/test_tts_voice_clone.py`
- Modify: `src/speechrail/backends/qwen3_tts_worker.py` only if the test exposes a framing bug.

**Interfaces:**
- Consumes: `MlxQwenTtsEngine.synthesize()` clone PCM stream.
- Produces: deterministic evidence that 200 ms coalescing preserves PCM sample count/order and emits only a bounded residual chunk.

- [x] **Step 1: Extend the fake clone test with output-size assertions**

  Assert the first coalesced output is 4,800 samples at 24 kHz and the residual contains the remaining samples; retain the existing loudness and builtin passthrough assertions.

- [x] **Step 2: Run the focused worker tests**

  Run `uv run --extra dev pytest --no-cov tests/test_tts_voice_clone.py -q`.

- [x] **Step 3: Keep the framing constant private**

  Document in the test and acceptance record that 200 ms is an internal normalization buffer, not a new public Realtime chunk-size promise.

### Task 4: Record the verified delivery state

**Files:**
- Create: `docs/archive/performance/2026-09-08-clone-tts-loudness-acceptance.md`
- Modify: `/Users/hrygo/Documents/sona/docs/operations/clone-tts-loudness-acceptance-2026-09-08.md` in the Sona repository only.

- [x] **Step 1: Add aggregate-only final acceptance evidence**

  Record the verified profile, test gates, aggregate clone/builtin statistics, remaining per-text outlier, and the unverified physical-speaker/cancel boundary without storing raw media.

- [x] **Step 2: Mark the Sona record as superseded by the final verification**

  Preserve its historical measurements but link the current SpeechRail#34 and Sona#10 verification comments so the stale “profile missing” statement is not treated as current.

### Task 5: Run gates and commit atomic changes

- [ ] **Step 1: Run targeted tests, Ruff, mypy, and `git diff --check`**
- [ ] **Step 2: Review staged paths and exclude all concurrent changes**
- [ ] **Step 3: Commit the SpeechRail implementation/test/doc slice**

  Use `fix(tts): apply clone loudness calibration baseline`.

- [ ] **Step 4: Commit the isolated Sona documentation update only**

  Use `docs(tts): link final clone loudness acceptance`.
