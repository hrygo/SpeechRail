# Single-Machine Speech Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task by task.

**Goal:** Deliver the optimization proposal in four independently reviewable changes: a correct OpenAI-compatible Realtime transcription contract, bounded and observable Realtime lifecycle handling, lower-cost ASR/TTS delivery, and evidence-backed diagnostics, diarization, and user guidance.

**Architecture:** Preserve the current single ASGI process with one shared ASR worker and one TTS worker. Normalize public Realtime wire inputs into explicit session, audio-ingress, and turn contexts; keep the 16 kHz ASR kernel internal; render responses through a versioned wire profile. Admission, cancellation, and delivery share one deadline and bounded budgets. ASR alignment and TTS planning are opt-in/shared services rather than side effects of every request.

**Tech Stack:** Python 3.12, FastAPI/Starlette WebSocket, Pydantic, `mlx-qwen3-asr`, `mlx-audio`, ONNX Silero VAD, NeMo diarization adapters, pytest, Ruff, mypy, OpenAPI/Redocly.

**Spec:** [SpeechRail 单机语音基座优化方案](../../architecture/2026-09-08-single-machine-speech-foundation-optimization.md)

## Global constraints

- Keep `/v1/realtime` limited to ASR/TTS; do not add LLM, playback, conferencing, AEC, or application interrupt policy.
- Keep batch and streaming ASR mutually exclusive on the one shared worker; conflicts return the established `backend_busy` envelope.
- Do not download models, access remote audio, or change model profiles in request paths.
- Preserve current legacy Realtime behavior behind an explicit profile while a verified current OpenAI profile is opt-in. Do not double-send audio delta events.
- Validate public input at the API boundary, vendor output at adapters, and return the stable error envelope with a request ID.
- Keep audio, prompts, text, embeddings, credentials, and absolute model paths out of logs, fixtures, metrics labels, and documents.
- Every code task starts with a failing focused regression test, then the narrowest implementation. Use fake backends for deterministic tests.
- Before each PR run `env -u SPEECHRAIL_API_KEY uv run --extra dev pytest --no-cov`, `uv run --extra dev ruff check src tests tools`, `uv run --extra dev mypy src`, `npx @redocly/cli lint contracts/openapi.yaml`, and `git diff --check`.
- Performance, native diarization, and quality claims remain `unset` until the existing benchmark SOP has been run with authorized, repository-external material.

---

## Task 1: Correct Realtime session semantics and transcript delivery

**GitHub issue:** `feat(realtime): 修复会话配置、item 关联与稳定 partial`  
**Branch:** `feat/realtime-session-state`

**Files:**

- Modify `src/speechrail/compatibility/openai_realtime.py`
- Modify `src/speechrail/application/realtime_openai.py`
- Modify `src/speechrail/realtime/speech_admission.py` only if it owns the generated turn identity
- Modify `contracts/realtime-openai.md`
- Modify `tests/test_realtime_openai.py`
- Add focused fixtures/tests beneath `tests/` only when they reduce existing test setup duplication

**Implementation steps:**

1. Add failing tests for current nested transcription-session input: `session.type="transcription"`, `audio.input.format={"type":"audio/pcm","rate":24000}`, nested `audio.input.transcription`, and nested `turn_detection`. Assert the normalized internal config is complete and exposes its accepted input rate/profile.
2. Add a stateful PCM24k-to-PCM16k adapter at ingress. Test random frame boundaries, odd-byte rejection, final flush, clear, and a long stream whose accumulated sample clock does not drift with frame partitioning. Keep the converter scoped to a session and prohibit an audio format change after the first accepted frame.
3. Add tests defining three-state update semantics: omitted fields preserve their resolved value, `null` clears only that field, and explicit values replace it. Parse and validate into a candidate snapshot, then atomically commit it and render the full effective session in the update response.
4. Introduce one `TurnContext` per committed audio turn. Generate one unique item ID and retain its predecessor relationship. Route partial, completed, failed, and diarization extension events through that context. Test consecutive legacy commits and server-VAD turns for non-reused IDs and exactly one terminal state each.
5. Replace append-only partial emission with a stable-prefix policy. A partial may only extend previous client-visible text; unstable rewrites remain internal until `completed`. Test `abc → adc` emits no invalid append and final output is exactly `adc`.
6. Document supported versus adapted legacy/current session shapes, audio rate conversion, partial semantics, item correlation, and invalid configuration behavior in the Realtime contract.

**Acceptance:** Current OpenAI-style transcription payloads configure a session correctly; 24 kHz PCM is accepted through deterministic conversion; legacy 16 kHz continues to work; partial updates preserve unrelated values; all turn events share a unique item ID; partial text cannot produce duplicated or stale client text.

## Task 2: Bound Realtime transport and align the wire protocol

**GitHub issue:** `fix(realtime): 对齐 wire profile、协议错误闭环与有界背压`  
**Branch:** `fix/realtime-wire-and-backpressure`

**Files:**

- Modify `src/speechrail/http/routes/realtime_openai.py`
- Modify `src/speechrail/compatibility/openai_realtime.py`
- Modify `src/speechrail/application/realtime_openai.py`
- Modify `src/speechrail/runtime/resource_governor.py` only for deadline propagation interfaces
- Modify `src/speechrail/observability/metrics.py`
- Modify `contracts/realtime-openai.md`
- Modify `tests/test_realtime_openai.py`
- Modify `tests/test_realtime_admission_commits.py`

**Implementation steps:**

1. Add failing renderer conformance tests that assert a profile selects exactly one audio-delta wire literal, including current `response.output_audio.delta`; assert no response contains both old and current audio delta event names.
2. Move JSON/event decoding into the receive-loop error boundary. Test malformed JSON, invalid envelope, unknown event, and valid event after a recoverable error. Assert the documented stable error envelope or a deterministic close code, and session admission is released in all terminal paths.
3. Replace count-only inbound buffering with explicit limits for raw WebSocket bytes, decoded PCM duration, pending audio work, outbound bytes, and in-flight control events. Keep append-before-commit ordering. Permit `cancel` to invalidate the active generation without allowing it to reorder prior append state.
4. Thread one monotonic absolute deadline through reserve, decoding, lock acquisition, worker dispatch, and response send; model long streaming separately with total-duration and idle deadlines. Test that nested waits cannot cumulatively exceed the request budget.
5. Add low-cardinality phase metrics for queue wait, ingress/decode, model first/final output, send stall, cancellation acknowledgment, rejected budget, and worker reload. Keep historical metrics and document their old measurement scope.
6. Document the selected wire profiles, slow-consumer behavior, error recoverability, limits, and deadline semantics.

**Acceptance:** A current profile passes fixture conformance without duplicated audio; malformed input cannot leak a task exception or a session slot; slow clients and excess input receive stable bounded behavior; cancel blocks obsolete output before new output is emitted; metrics can locate the phase without storing user content.

## Task 3: Reduce ASR/TTS repeated work and make cancellation intentional

**GitHub issue:** `perf(asr-tts): 消除重复缓冲、统一 TTS 规划并改进取消`  
**Branch:** `perf/asr-tts-delivery`

**Files:**

- Modify `src/speechrail/backends/qwen3_worker.py`
- Modify `src/speechrail/backends/qwen3_tts.py`
- Modify `src/speechrail/backends/qwen3_tts_worker.py`
- Modify `src/speechrail/application/tts_delivery.py`
- Modify `src/speechrail/application/realtime_openai.py`
- Modify `src/speechrail/domain/tts.py`
- Modify `src/speechrail/observability/metrics.py`
- Modify `tests/test_qwen3_shared.py`
- Modify `tests/test_qwen3_tts.py`
- Modify `tests/test_tts_delivery.py`
- Modify `tests/test_tts_streaming_splitter.py`

**Implementation steps:**

1. Add a session-open timing/alignment requirement. Test normal streaming ASR never accumulates alignment PCM, while requested segments retain bounded audio and release it on complete, cancel, timeout, rollover, and shutdown.
2. Separate text finalization from optional alignment/diarization. Test canonical transcript text is never overwritten by a fallback alignment decode; run an expensive fallback only when the negotiated extension requires it and bound its time/audio.
3. Extract one TTS text-planning path that normalizes and sentence-plans input once for REST, Realtime, and preview. Preserve a worker-only hard maximum; test punctuation, long text, first chunk, terminal character, and no fixed inter-sentence silence inserted by a second planner.
4. Define per-flavor parameter capabilities for VoiceDesign, CustomVoice, and ICL/clone. Pass supported parameters consistently or reject unsupported ones explicitly. Cache only a validated reference waveform/adapter feature when an observed benchmark proves useful; key it by artifact, preprocessing, and voice fingerprint; set capacity and invalidate on profile/voice removal.
5. Add cooperative TTS cancellation only after a fake/vendor capability probe proves a safe iterator boundary. Test cancellation stops delivery and retains the worker under acknowledgement; preserve abort/reload as the bounded fallback for no acknowledgement, protocol corruption, or worker loss.
6. Add metrics for alignment usage/fallback, planner chunks, cache hit/miss/eviction, cooperative cancel, abort fallback, and reload. Update the user/developer documentation with behavior and measurement scope.

**Acceptance:** Normal ASR does not pay alignment-buffer cost; optional alignment cannot delay or alter ordinary final text; all TTS transports use one planning policy; each voice flavor has honest parameter behavior; normal acknowledged cancellation avoids an unnecessary worker reload, while unsafe cases retain the existing safe abort path.

## Task 4: Establish evidence gates, diagnostics, native diarization, and integration guides

**GitHub issue:** `feat(operations): 建立能力诊断、连续分人和质量验收基线`  
**Branch:** `feat/capability-diagnostics-and-quality-gates`

**Files:**

- Modify `src/speechrail/backends/nemo_sortformer.py`
- Modify `src/speechrail/application/diarization.py`
- Modify `src/speechrail/http/routes/system.py`
- Modify the existing CLI/MCP describe command under `src/speechrail/`
- Modify `src/speechrail/observability/metrics.py`
- Modify `docs/users/README.md`
- Modify `docs/developers/testing-acceptance.md`
- Modify `docs/architecture/README.md`
- Modify `contracts/diarization/v1/` and `contracts/realtime-openai.md` only when a verified public field changes
- Modify/add focused tests under `tests/test_diarization_*.py`, `tests/test_*system*.py`, and CLI/MCP tests

**Implementation steps:**

1. Define a repository-safe external corpus manifest schema containing opaque sample IDs, duration, approved hash, language/scenario, and annotation availability. Add tooling that validates a manifest without reading or committing raw audio. Record fixed runtime/artifact/profile and cold/warm conditions with every result.
2. Add a reproducible quality/performance gate using the existing benchmark SOP: contract cases, 100+ latency samples for percentile claims, ASR text metrics by scenario, TTS content/voice checks, VAD error categories, memory, cancellation, and long-run resource return. Keep all unmeasured fields `unset`.
3. Extend `describe`/system diagnostics with safe resolved capability data: configured/validated artifact, model readiness, selected VAD engine, diarization mode, known busy reason, and last smoke/benchmark status. Do not return paths, credentials, audio, transcriptions, prompts, or cardinality-unbounded telemetry.
4. Implement native continuous diarization only behind a capability probe. Test session-scoped anonymous labels, monotonic sample clock, revisions, finalize barrier, unknown/failure degradation, and no cross-session identity persistence. Do not advertise streaming support until an authorized real native CPU smoke and DER/JER/latency evidence are attached.
5. Publish three concise, executable integration paths: file transcription, text synthesis, and Realtime transcription. Add explicit boundaries for Sona, LiveKit, and Pipecat: they own microphone, playback, AEC, LLM, meeting, and interrupt policy.

**Acceptance:** Every performance/quality claim points to a dated, reproducible result or is `unset`; users can discover safe effective capabilities and recovery hints; continuous diarization cannot overclaim unsupported runtime behavior; each supported integration route has a runnable contract-aligned example.

## Review and delivery sequence

1. Open the four issues above with the exact acceptance criteria and link each PR to its issue using `Closes #<number>`.
2. Keep each issue branch based on the current protected default branch and rebase it before review if preceding work changes shared Realtime files.
3. Review each PR independently for contract, resource lifecycle, privacy, compatibility, and rollback. Re-run the full project gate after rebases.
4. Do not merge automatically. After all four PRs are accepted, run the authorized local runtime smoke and benchmark gates; record only aggregate results and then update the optimization proposal from draft evidence to a dated implementation status.
