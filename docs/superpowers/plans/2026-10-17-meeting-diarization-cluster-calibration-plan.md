# Meeting Diarization Cluster Calibration Implementation Plan

> **For agentic workers:** Execute this plan inline, task by task. Keep holdout data locked.

**Goal:** Add a bounded development-only calibration of FluidAudio clustering/VBx settings, then test the best two settings with the existing 24 SpeechRail matcher policies.

**Architecture:** Represent each calibration candidate as one matcher policy plus one acoustic clustering policy. The native worker prepares segmentation and embeddings once per PCM window, then serially clusters the prepared evidence under each candidate configuration; the default production path remains unchanged.

**Tech Stack:** Swift 6.4, CoreML, FluidAudio pinned SDK, Python 3.14, pytest, existing AISHELL-4 development manifest.

**Spec:** [Meeting Diarization Cluster Calibration Design](../specs/2026-10-17-meeting-diarization-cluster-calibration-design.md)

## Global Constraints

- Use the existing locked 8-session development manifest, SDK revision `5c19d5e12320e22bbfb7a1877b089d2665a69add`, and model revision `7eab74f3463c736418d0eb10296261ae581146c9`.
- Do not inspect or score R004 holdout; do not alter production defaults or edit the generated FluidAudio checkout.
- Keep one native worker process and serial candidate evaluation; keep candidate count at or below the existing 24-policy worker bound for each run.
- Write raw audio-derived traces and measurements outside the repository; preserve only sanitized aggregates.
- Do not commit, push, install, publish, or change service runtime state without a separately explicit request.

## Review Focus

- Candidate JSON must reject invalid clustering values and configurations that change segmentation or embedding inputs.
- Stage-one ranking must be diagnostic only and must never emit a selected production candidate.
- Stage-two selection must require every development session to pass all existing gates.
- `prepare` must run once per input window; candidate clustering must be serial and share loaded model instances.
- Candidate payloads must remain within the existing 4 MiB IPC limit; overflow must fail closed with no partial candidate result.

---

### Task 1: Define the bounded clustering policy

**Files:**
- Create: `native/diarization/Sources/SpeechRailDiarizationProtocol/DiarizationClusteringPolicy.swift`
- Modify: `native/diarization/Sources/SpeechRailDiarizationProtocolSelfTest/main.swift`

**Interfaces:**
- `DiarizationClusteringPolicy: Codable, Sendable` carries `threshold`, `warmStartFa`, and `warmStartFb` and validates the supported FluidAudio range.
- `MeetingDiarizationWorker` maps the validated policy to calibration-only `OfflineDiarizerConfig.Clustering`; the protocol target does not import FluidAudio and production defaults do not change.

- [x] Add self-test cases for the baseline and declared screen values, and reject non-finite, zero/negative, and out-of-range values.
- [x] Run the protocol self-test and verify the missing policy type fails before implementation.
- [x] Implement the policy model and conversion to clustering config without touching the FluidAudio checkout.
- [x] Re-run the protocol self-test and `swift build --package-path native/diarization --configuration release --product SpeechRailDiarizationWorker`.

### Task 2: Build the staged calibration manifest

**Files:**
- Modify: `examples/perf/calibrate_meeting_diarization.py`
- Modify: `tests/test_calibrate_meeting_diarization.py`

**Interfaces:**
- The screen stage emits seven single-variable acoustic candidates paired with matcher grid index 11.
- The refinement stage consumes a screen summary and emits the full 24-policy matcher grid for one selected acoustic configuration at a time.
- Candidate and screen-summary digests join the manifest/model/SDK execution lock.

- [x] Add tests for exact grid values, stage-one ranking/tie order, rejection of a modified screen-summary digest, and the rule that screen results cannot write `selected-candidate.json`.
- [x] Run the new focused tests and confirm they fail before implementation.
- [x] Implement bounded grid generation, development-only screening, top-two selection, and one-config-at-a-time refinement.
- [x] Run focused Python tests, Ruff, and Mypy on the changed Python entry points (`--follow-imports=skip` keeps unrelated scorer typing outside this check).

### Task 3: Reuse prepared audio in native calibration

**Files:**
- Modify: `native/diarization/Sources/SpeechRailDiarizationWorker/MeetingDiarizationWorker.swift`
- Modify: `native/diarization/Sources/SpeechRailDiarizationWorker/main.swift`
- Modify: `native/diarization/Sources/SpeechRailDiarizationProtocolSelfTest/main.swift`
- Modify: `src/speechrail/runtime/diarization_worker.py`
- Modify: `examples/perf/calibrate_meeting_diarization.py`

**Interfaces:**
- Calibration-only candidate JSON pairs `SpeakerMatchingPolicy` with `DiarizationClusteringPolicy`.
- `CoreMLWorkerProcess` accepts a calibration-candidate path only for `meeting_dynamic`; ordinary runtime startup continues with the default config and no calibration candidates.
- Candidate output indexes are stable within one run and candidate payload size is checked against the existing 4 MiB IPC limit.

- [x] Add protocol self-test cases for candidate decoding, candidate count bounds, and the existing packet codec's payload-limit failure.
- [x] Run the protocol self-test before adding the missing clustering policy; candidate decoder and payload-limit assertions pass after implementation.
- [x] Refactor inference to call `prepare` once, use its output for serial calibration clustering, and keep the normal result path unchanged.
- [x] Run the Swift protocol self-test, Python diarization-worker tests, and Release native worker build.

### Task 4: Execute screen and refinement on development only

**Files:**
- Update: `docs/implementation/2026-10-16-meeting-caption-acceptance.md`
- Update: `docs/superpowers/plans/2026-10-17-open-issues-roi-plan.md`

- [x] Run the seven-config screen against the locked 8-session development manifest; verify all eight sessions complete and no holdout identifier is read.
- [x] Refine the two ranked configurations with all 24 matcher policies, serially, using the same worker/model/manifest lock.
- [x] Write a selected candidate only if all eight development meetings pass every existing quality gate; both refinements had no feasible candidate, so no candidate was written and holdout stayed locked.
- [x] Record sanitized aggregate metrics, artifact ID/digest, exact scope, gate status, and unverified requirements; `git diff --check` and trailing-whitespace checks pass.

## Completion Audit

This plan completes only the expanded development calibration. It does not complete Issue #370 unless the frozen candidate also passes the independent holdout, meeting-ASR quality, installed public-API, and capability-consistency requirements from [Issue #370](https://github.com/hrygo/SpeechRail/issues/370).
