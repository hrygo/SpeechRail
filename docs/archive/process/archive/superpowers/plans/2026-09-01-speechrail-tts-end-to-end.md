# SpeechRail TTS End-to-End Implementation Plan

> **For agentic workers:** Execute this plan task-by-task with review checkpoints. The shared worktree contains unrelated parallel changes; never stage or commit files outside the task's explicit file list.

**Goal:** Move the `sona` MLX Qwen3-TTS VoiceDesign path into SpeechRail and wire both REST audition and Realtime v2 playback without losing existing ASR, meeting, UI, or playback ownership.

**Architecture:** SpeechRail owns TTS policy, preset voice registry, request/session state, worker supervision, model adapter, audio validation, and public REST/WebSocket delivery. `sona` owns interaction and playback and consumes SpeechRail through a neutral outbound protocol adapter; Pipecat and UI remain delivery/application adapters. The model runtime stays behind SpeechRail's external worker boundary.

**Tech Stack:** Python 3.12, `uv`, FastAPI, Pydantic v2, asyncio, WebSocket Realtime v2, MLX `mlx-audio` in a separately configured worker environment, Pipecat 1.7, React/TypeScript, pytest, Ruff, mypy, OpenAPI/JSON Schema validation.

**Spec:** `docs/superpowers/specs/2026-09-01-speechrail-tts-migration-design.md`

## Global Constraints

- Python remains `>=3.12,<3.13`; use `uv` and PEP 621 metadata.
- Public TTS model ID is `speechrail/qwen3-tts`; the actual `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16` snapshot remains an external absolute path.
- Public audio is mono 24,000 Hz signed little-endian PCM16; REST supports `pcm` and `wav`.
- Four preset voices are `default`, `warm`, `bright`, and `calm`; `alloy` is only a `sona` compatibility alias mapped to `default`.
- Model downloads are disabled by default and never happen during a request.
- Do not persist source audio, raw transcript/TTS text, prompts, credentials, or absolute model paths in logs.
- Preserve all unrelated staged/unstaged changes in both repositories; do not run broad staging, reset, checkout, clean, or dependency upgrades.
- Every behavior change starts with a failing deterministic test and ends with the repository's focused and full verification commands.

### Task 1: Add SpeechRail TTS policy and voice registry

**Files:**
- Create: `src/speechrail/domain/tts.py`
- Modify: `src/speechrail/domain/ports.py`
- Create: `tests/test_tts_policy.py`

**Interfaces:**
- Produces `VoiceProfile(id: str, instruction: str, is_default: bool)` and an immutable `VOICE_PROFILES` registry.
- Produces `normalize_tts_text(text: str) -> str` and `generation_token_budget(text: str) -> int` with the legacy bridge behavior: markdown/emoji cleanup, weak punctuation removal, CJK/English terminator completion, and a 32..1200 token bound.
- Extends `SpeechRequest` with `language: str = "auto"`; existing constructor calls remain valid.

- [ ] **Step 1: Write the failing policy tests**

```python
def test_voice_registry_preserves_four_voice_design_instructions():
    assert tuple(VOICE_PROFILES) == ("default", "warm", "bright", "calm")
    assert VOICE_PROFILES["warm"].instruction.startswith("温暖柔和")

def test_normalize_tts_text_closes_cjk_text_and_removes_markup():
    assert normalize_tts_text(" **你好**，🙂") == "你好。"

def test_generation_budget_is_bounded():
    assert generation_token_budget("") == 32
    assert generation_token_budget("字" * 5000) == 1200
```

- [ ] **Step 2: Run `uv run pytest tests/test_tts_policy.py -q --no-cov` and verify it fails because the policy module and language field are absent.**
- [ ] **Step 3: Implement the policy as pure domain code without importing MLX, NumPy, FastAPI, or Pipecat.**
- [ ] **Step 4: Run the focused test and verify it passes; run `uv run ruff check src/speechrail/domain/tts.py src/speechrail/domain/ports.py tests/test_tts_policy.py`.**

### Task 2: Replace the SpeechRail worker engine with MLX VoiceDesign

**Files:**
- Modify: `src/speechrail/backends/qwen3_tts.py`
- Modify: `src/speechrail/backends/qwen3_tts_worker.py`
- Create: `tests/test_qwen3_tts_voice_design.py`
- Modify: `tests/test_qwen3_tts.py`
- Modify: `tests/test_qwen3_tts_worker.py`

**Interfaces:**
- `Qwen3TtsWorker` remains the `SpeechSynthesizer` implementation and continues to accept only a validated local snapshot and configured worker Python executable.
- The private worker engine calls `mlx_audio.tts.utils.load`, routes VoiceDesign profiles through `instruct`, passes `language`, `speed`, `max_tokens`, `repetition_penalty`, `temperature`, `top_p`, `stream=True`, and the configured streaming interval.
- Worker output remains framed, ordered, even-length PCM16 with identity `{backend: "mlx-qwen3-tts-voice-design", sample_rate: 24000}`.
- Cancelling or timing out a synthesis terminates the current private process and marks it not ready before the next request, so stale audio cannot cross request boundaries.

- [ ] **Step 1: Add a fake MLX model test that asserts `voice="warm"` becomes the exact `warm` instruction, `language` is forwarded, and final waveform post-processing removes trailing silence and applies a short fade.**
- [ ] **Step 2: Run `uv run pytest tests/test_qwen3_tts_voice_design.py -q --no-cov` and verify it fails against the current Torch/CustomVoice engine.**
- [ ] **Step 3: Implement the MLX worker adapter and bounded thread-to-IPC streaming; keep vendor imports private to the worker module.**
- [ ] **Step 4: Add a cancellation regression test that starts a blocked request, cancels the async stream, and verifies the worker is restarted before another request can read frames.**
- [ ] **Step 5: Run the worker-focused tests and `uv run ruff check src/speechrail/backends/qwen3_tts.py src/speechrail/backends/qwen3_tts_worker.py tests/test_qwen3_tts_voice_design.py`.**

### Task 3: Complete SpeechRail REST and Realtime v2 TTS lifecycle

**Files:**
- Modify: `src/speechrail/app.py`
- Modify: `src/speechrail/config/__init__.py`
- Modify: `src/speechrail/realtime/v2_session.py`
- Create: `tests/test_tts_voices_api.py`
- Modify: `tests/test_speech_api.py`
- Modify: `tests/test_realtime_v2_websocket.py`

**Interfaces:**
- Adds `GET /v1/voices` returning `{object: "list", data: [{id, description, is_default, available}]}`.
- `/v1/audio/speech` accepts optional `language`, validates model/voice before calling the synthesizer, and maps the same application request to PCM or WAV.
- `SpeechSession` accepts an allowed voice registry, validates `language`, exposes 24 kHz audio metadata, and guarantees `session.completed` after a committed response reaches either completed or cancelled terminal state.
- `/readyz` and `/health` report TTS readiness independently from ASR readiness; a configured TTS worker must be loaded before the TTS component is ready.

- [ ] **Step 1: Add failing API tests for `/v1/voices`, REST `language`, speech-session unknown voice, and commit-after-cancel terminal completion.**
- [ ] **Step 2: Run `uv run pytest tests/test_tts_voices_api.py tests/test_speech_api.py tests/test_realtime_v2_websocket.py -q --no-cov` and verify the new cases fail.**
- [ ] **Step 3: Implement the registry lookup and route mappings in the composition root without moving model or playback code into the route.**
- [ ] **Step 4: Fix active synthesis cleanup so `response.cancel`, `session.cancel`, disconnect, timeout, and slow-consumer paths all release the task and backend generation.**
- [ ] **Step 5: Update OpenAPI and Realtime contract documents to match the implemented fields and event order.**
- [ ] **Step 6: Run the focused API tests, contract validator, and `uv run ruff check` on changed SpeechRail files.**

### Task 4: Create the neutral `sona` SpeechRail outbound adapter

**Files:**
- Create: `../sona/src/sona/speechrail/__init__.py`
- Create: `../sona/src/sona/speechrail/transport.py`
- Create: `../sona/src/sona/speechrail/tts.py`
- Modify: `../sona/src/sona/asr/adapters/speechrail_realtime.py`
- Create: `../sona/tests/test_speechrail_tts.py`
- Modify: `../sona/tests/asr/test_speechrail_realtime.py`

**Interfaces:**
- `SpeechRailV2Transport` validates JSON object shape, `session_id`, `request_id`, and monotonically increasing `sequence`; it supports `connect`, `send_event`, `receive`, and `close` and is reusable by ASR and TTS adapters.
- `SpeechRailTTSClient(url, model, voice, language, connection_factory=None)` exposes `synthesize(text, speed) -> AsyncIterator[bytes]` and `cancel(response_id)`, validates base64 PCM and per-response chunk ordering, and maps remote error envelopes to stable local exceptions.
- Existing `SpeechRailRealtimeClient` remains import-compatible for ASR while delegating transport validation to the neutral module.

- [ ] **Step 1: Add fake-connection tests for ordered speech events, malformed external events, unknown response IDs, and cancellation.**
- [ ] **Step 2: Run `uv run pytest tests/test_speechrail_tts.py tests/asr/test_speechrail_realtime.py -q --no-cov` and verify the new adapter tests fail.**
- [ ] **Step 3: Implement the neutral transport and speech client with no Pipecat or UI imports.**
- [ ] **Step 4: Refactor the ASR adapter to reuse transport primitives while preserving its public classes and existing event mapping.**
- [ ] **Step 5: Run the adapter-focused tests and `uv run ruff check` on the new/changed adapter files.**

### Task 5: Replace the Pipecat local bridge with a Realtime v2 TTS service

**Files:**
- Modify: `../sona/src/sona/interaction/tts.py`
- Modify: `../sona/src/sona/interaction/pipeline.py`
- Modify: `../sona/src/sona/config.py`
- Create: `../sona/tests/test_speechrail_tts_service.py`
- Modify: `../sona/tests/test_pipeline.py`
- Modify: `../sona/tests/test_local_tts.py`

**Interfaces:**
- `SpeechRailTTSService(TTSService)` consumes aggregated LLM text, opens a v2 speech session per bounded clause, yields `TTSAudioRawFrame(audio, 24000, 1, context_id)`, and closes/cancels the client in every exit path.
- `SpeechRailTTSService.Settings` stores preset `voice`, `language`, and `model`; `alloy` is normalized to `default` before a request.
- `InteractionSettings` adds `speechrail_tts_rest_url`, `speechrail_tts_model`, `tts_voice`, and `tts_language`; the legacy `tts_bridge_url` remains read-compatible but is not used by the pipeline.

- [ ] **Step 1: Add a service test with a fake client that asserts text, voice, speed, frame sample rate, cancellation, and cleanup behavior.**
- [ ] **Step 2: Run `uv run pytest tests/test_speechrail_tts_service.py tests/test_pipeline.py -q --no-cov` and verify it fails because the pipeline still constructs `LocalBridgeTTSService`.**
- [ ] **Step 3: Implement the service on Pipecat `TTSService`; reuse the existing `ChineseClauseTextAggregator` only for application-level text boundaries.**
- [ ] **Step 4: Wire `build_pipeline` to the new service and the shared `speechrail_realtime_url`; leave EchoSuppression, TTSStateObserver, AudioHub, and playback ordering unchanged.**
- [ ] **Step 5: Run the focused pipeline/service tests and `uv run mypy` on changed Python modules.**

### Task 6: Move UI health, voice selection, and REST audition to SpeechRail

**Files:**
- Modify: `../sona/src/sona/ui/server.py`
- Modify: `../sona/src/sona/ui/control.py`
- Modify: `../sona/src/sona/ui/runtime.py`
- Modify: `../sona/ui/src/components/AssistantPanel.tsx`
- Modify: `../sona/ui/src/components/StatusBar.tsx`
- Modify: `../sona/ui/src/components/assistantPresentation.ts`
- Create: `../sona/tests/test_ui_speechrail_tts.py`
- Modify: `../sona/tests/test_ui_server.py`
- Modify: `../sona/tests/test_control.py`

**Interfaces:**
- UI proxy routes call SpeechRail REST derived from the configured SpeechRail endpoint, preserve upstream content type and structured error bodies, and never call port `8765`.
- `/api/services` probes SpeechRail `/health`/`/readyz` as the single `tts` service and reports the logical TTS model without exposing a snapshot path.
- `set_voice` changes application-selected preset state only; it does not call a mutable global `/v1/voice` endpoint.
- Frontend audition/replay sends `model: "speechrail/qwen3-tts"`, uses the selected preset, and reports SpeechRail errors without referring to a TTS bridge.

- [ ] **Step 1: Add failing proxy/control/UI tests that assert the SpeechRail URL and logical model, and assert no request is sent to the old bridge.**
- [ ] **Step 2: Run the focused backend tests and UI test command to verify the new expectations fail.**
- [ ] **Step 3: Implement the URL derivation, response validation, application voice state, and frontend payload changes.**
- [ ] **Step 4: Run backend focused tests, UI tests, and UI build.**

### Task 7: Retire the old bridge active path and update deployment documentation

**Files:**
- Modify: `../sona/scripts/run-all.sh`
- Modify: `../sona/pyproject.toml`
- Modify: `../sona/tests/test_run_all_script.py`
- Modify: `../sona/README.md`
- Modify: `configs/speechrail.example.env`
- Modify: `docs/11-operations-runbook.md`
- Modify: `docs/03-sona-absorption.md`
- Modify: `docs/08-migration-runbook.md`

**Interfaces:**
- `run-all.sh` starts only `vr-ui` and verifies the independently managed SpeechRail endpoint; it does not spawn `vr-bridge` or download TTS weights.
- `sona` no longer exposes a `vr-bridge` console script or TTS-only MLX/model-cache dependency after all active references are removed; meeting dependencies remain intact.
- Example configuration documents the external MLX worker Python/snapshot and `SPEECHRAIL_TTS_VOICE_IDS=["default","warm","bright","calm"]` without real paths or credentials.

- [ ] **Step 1: Add a script regression test that fails if `run-all.sh` starts `vr-bridge` or derives `VR_INTERACTION_TTS_BRIDGE_URL`.**
- [ ] **Step 2: Remove the active bridge launch and update only TTS-owned dependency/config references; retain old bridge source until the new smoke gate passes.**
- [ ] **Step 3: Run `rg -n "vr-bridge|tts_bridge_url|/v1/voice|8765|mlx-audio"` with an allowlist for migration notes and compatibility tests, then update remaining active references.**
- [ ] **Step 4: Update operations and rollback instructions with the exact logical IDs, health paths, and no-download rule.**

### Task 8: Run the complete verification and real local closed loop

**Files:**
- Modify only files required by failing verification; do not alter unrelated parallel staged files.
- Create: `tests/test_tts_closed_loop_contract.py` if a missing deterministic cross-boundary case is found.

- [ ] **Step 1: Run SpeechRail focused TTS tests, then the full `uv run pytest`, `uv run ruff check`, `uv run mypy`, OpenAPI validation, and Realtime contract validation.**
- [ ] **Step 2: Run `sona` focused TTS/adapter/UI tests, then full backend pytest, `uv run ruff check`, `uv run mypy`, UI tests, and UI build.**
- [ ] **Step 3: With an already-authorized existing MLX snapshot and configured worker Python, run health/readiness, `/v1/voices`, REST PCM/WAV, v2 append/flush/commit, Pipecat frame, playback, cancel, and recovery smoke tests.**
- [ ] **Step 4: Verify the output is actually mono 24 kHz PCM16 and non-empty, and record first-chunk/RTF/memory only as local QA evidence without logging text, audio, credentials, or absolute snapshot paths.**
- [ ] **Step 5: Re-run exact active-reference searches and graph coverage for every changed source path; confirm no SpeechRail → `sona`/LM/DB/playback dependency exists and no old bridge path is active.**
- [ ] **Step 6: Report each gate as passed, failed, or unverified; do not claim completion if the real model or end-to-end playback cannot be executed locally.**
