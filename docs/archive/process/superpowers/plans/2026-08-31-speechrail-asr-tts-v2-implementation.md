# SpeechRail ASR/TTS Realtime v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Deliver a local public ASR/TTS runtime with OpenAI-compatible REST, durable batch jobs, Realtime v2 sessions, and direct sona v2 adapters.

**Architecture:** Preserve existing v1 behavior. Add typed v2 state machines, a Resource Governor, isolated ASR/TTS backend ports, and an external SQLite job spool. sona owns devices, meeting, LLM, playback and UI; it connects through a shared v2 client and two adapters.

**Tech Stack:** Python 3.12, FastAPI, Pydantic v2, asyncio, SQLite, websockets, ffmpeg, isolated Qwen runtimes, mlx-audio in an isolated TTS runtime, pytest, Ruff, mypy, OpenAPI 3.1.

**Spec:** docs/superpowers/specs/2026-08-31-speechrail-asr-tts-runtime-design.md; contracts/realtime-v2.md; docs/decisions/0006-public-asr-tts-runtime.md

## Global Constraints

- Python >=3.12,<3.13; use uv and PEP 621 metadata.
- Preserve every v1 observable behavior. Realtime v2 is additive at /v2/realtime.
- Models, job spool and generated audio use external absolute paths; requests never download models or fetch URLs.
- Do not log keys, PCM, Base64, full text, prompts, voice samples or private model paths.
- One profile owns one long-lived worker; ASGI workers never duplicate models.
- Realtime v2 is non-resumable. sequence is session-local only.
- New HTTP/WS endpoints require Bearer auth when an API key is configured.
- sona is changed only in a separate worktree/branch after SpeechRail v2 is testable.
- Model download/activation, client cutover and service installation are separate authorization gates.

---

## File Map

| Path | Responsibility |
|---|---|
| src/speechrail/domain/realtime_v2.py | Immutable v2 event/data models and validation errors |
| src/speechrail/realtime/v2_session.py | ASR/TTS session state machines and sequence allocation |
| src/speechrail/realtime/v2_gateway.py | WebSocket routing and backend event pumps |
| src/speechrail/runtime/governor.py | Reserved realtime capacity and batch aging |
| src/speechrail/backends/streaming.py | Backend protocols and typed backend events |
| src/speechrail/backends/wlk_streaming.py | WLK-compatible streaming ASR normalization |
| src/speechrail/backends/qwen3_tts.py | Isolated Qwen3-TTS worker client |
| src/speechrail/backends/qwen3_tts_worker.py | Offline TTS worker process |
| src/speechrail/runtime/jobs.py | SQLite job metadata, ownership, TTL and recovery |
| src/speechrail/http/speech.py | Speech REST schema and binary response rendering |
| src/speechrail/http/jobs.py | Job HTTP resources |
| contracts/openapi.yaml | REST v1 ASR/TTS/job schemas |
| contracts/realtime-v2.md | Exact tested Realtime v2 wire contract |
| tests/test_*_v2.py | Deterministic protocol, governor, job and fake-backend tests |

## Task 1: Lock v2 domain types and session state machines

实施状态：**已完成**（`c2efe11`、`000d847`）。

**Files:**
- Create: src/speechrail/domain/realtime_v2.py
- Create: src/speechrail/realtime/v2_session.py
- Create: tests/test_realtime_v2_session.py
- Modify: src/speechrail/realtime/__init__.py

**Interfaces:**
- Create SessionKind = Literal["transcription", "speech"], V2SessionError and V2Event.
- Create TranscriptionSession and SpeechSession.
- Both expose configure(), event(), cancel() and session-local sequence.
- TranscriptionSession exposes append(audio_b64), flush(), commit(), delta(), completed().
- SpeechSession exposes append(text), flush(), commit(), response_created(), audio_delta(), response_completed(), response_cancelled().

- [x] **Step 1: Write the failing tests**

    def test_delta_is_a_revisable_snapshot() -> None:
        session = TranscriptionSession("sess_1", max_frame_bytes=64, max_buffer_bytes=128)
        session.configure({"type": "transcription", "audio_format": PCM16})
        assert session.delta("item_1", 1, "你好")["revision"] == 1
        assert session.delta("item_1", 2, "你好，世界")["text"] == "你好，世界"
        with pytest.raises(V2SessionError, match="revision_not_monotonic"):
            session.delta("item_1", 2, "重复")

Add cases for append-before-configure, double configuration, bad Base64, odd PCM, oversized frame, empty TTS text, unknown response ID, commit-after-cancel and monotonic event sequence.

- [x] **Step 2: Run the focused test and verify it fails**

Run: uv run --extra dev pytest tests/test_realtime_v2_session.py -q --no-cov

Expected: module import failure.

- [x] **Step 3: Implement the minimal state machines**

    class SequencedSession:
        def event(self, event_type: str, **payload: object) -> dict[str, object]:
            self._sequence += 1
            return {
                "type": event_type,
                "event_id": f"evt_{uuid4().hex}",
                "session_id": self.session_id,
                "request_id": self.request_id,
                "sequence": self._sequence,
                **payload,
            }

Reject every invalid state transition with V2SessionError(code). Store only bounded uncommitted audio/text; do not import a worker or vendor SDK.

- [x] **Step 4: Run tests and commit**

Run: uv run --extra dev pytest tests/test_realtime_v2_session.py -q --no-cov

    git add src/speechrail/domain/realtime_v2.py src/speechrail/realtime tests/test_realtime_v2_session.py
    git commit -m "feat: add realtime v2 session state machines"

## Task 2: Add Resource Governor and Settings

实施状态：**已完成**（`69ff841`）。

**Files:**
- Create: src/speechrail/runtime/governor.py
- Create: tests/test_governor.py
- Modify: src/speechrail/config/__init__.py

**Interfaces:**
- Create GovernorConfig(realtime_asr_slots, realtime_tts_slots, batch_slots, batch_aging_seconds).
- Create ResourceGovernor.acquire(lane) and try_acquire(lane).
- lane is asr_realtime, tts_realtime or batch.

- [x] **Step 1: Write failing isolation/fairness tests**

    async def test_batch_cannot_consume_reserved_asr_slot() -> None:
        governor = ResourceGovernor(GovernorConfig(1, 1, 1, 0.01))
        async with governor.acquire("asr_realtime"):
            assert await governor.try_acquire("asr_realtime") is None
            assert await governor.try_acquire("batch") is not None

Add a fake monotonic-clock test: an aged batch request becomes eligible after batch_aging_seconds but cannot bypass already queued realtime work.

- [x] **Step 2: Run RED**

Run: uv run --extra dev pytest tests/test_governor.py -q --no-cov

- [x] **Step 3: Implement governor and config**

Use separate bounded semaphores and an enqueue-time batch deque. Do not use Semaphore.locked() as the admission decision. Add positive settings with defaults: REALTIME_ASR_SLOTS=1, REALTIME_TTS_SLOTS=1, BATCH_SLOTS=1, BATCH_AGING_SECONDS=30.

- [x] **Step 4: Run GREEN and commit**

    uv run --extra dev pytest tests/test_governor.py -q --no-cov
    git add src/speechrail/runtime/governor.py src/speechrail/config tests/test_governor.py
    git commit -m "feat: reserve realtime speech capacity"

## Task 3: Define streaming backend ports

实施状态：**已完成**（`c214541`）。

**Files:**
- Create: src/speechrail/backends/streaming.py
- Create: tests/test_streaming_backends.py
- Modify: src/speechrail/backends/__init__.py

**Interfaces:**
- StreamingAsrBackend.open(config) returns a session with send_pcm(), flush(), commit(), cancel() and events().
- StreamingTtsBackend.open(config) returns a response with append_text(), flush(), commit(), cancel() and audio().
- AsrBackendEvent(kind, item_id, revision, text, segments).
- TtsBackendEvent(kind, response_id, chunk_index, audio, duration_ms).

- [x] **Step 1: Write failing typed-event tests**

    async def test_backend_events_are_typed_before_public_rendering() -> None:
        session = FakeStreamingAsrSession()
        await session.send_pcm(b"\x00\x00")
        assert [event.kind async for event in session.events()] == ["partial", "completed"]

- [x] **Step 2: Run RED**

Run: uv run --extra dev pytest tests/test_streaming_backends.py -q --no-cov

- [x] **Step 3: Implement protocols and strict event models**

Vendor JSON and WLK lines/buffer_transcription never cross the port. Public JSON rendering remains the responsibility of the v2 gateway.

- [x] **Step 4: Run GREEN and commit**

    uv run --extra dev pytest tests/test_streaming_backends.py -q --no-cov
    git add src/speechrail/backends tests/test_streaming_backends.py
    git commit -m "feat: define streaming speech backend ports"

## Task 4: Expose Realtime v2 transcription with a fake backend

实施状态：**已完成**（`000d847`）。

**Files:**
- Create: src/speechrail/realtime/v2_gateway.py
- Create: tests/test_realtime_v2_websocket.py
- Modify: src/speechrail/app.py
- Modify: contracts/realtime-v2.md

**Interfaces:**
- create_app accepts streaming_asr_backend for deterministic tests.
- WS /v2/realtime accepts only one session.update.
- v2 errors follow the common fields defined in contracts/realtime-v2.md.

- [x] **Step 1: Write failing WebSocket tests**

    with client.websocket_connect("/v2/realtime") as socket:
        socket.send_json({"type": "session.update", "session": TRANSCRIPTION_CONFIG})
        assert socket.receive_json()["type"] == "session.created"
        socket.send_json({"type": "input_audio_buffer.append", "audio": PCM_B64})
        assert socket.receive_json()["type"] == "input_audio_buffer.ack"
        assert socket.receive_json()["type"] == "transcription.delta"
        socket.send_json({"type": "input_audio_buffer.commit"})
        assert socket.receive_json()["type"] == "transcription.completed"

Test auth failure, invalid event order (1008), governor saturation (1013), flush preserving a session, cancel producing one terminal event and reconnect generating a new session ID.

- [x] **Step 2: Run RED**

Run: uv run --extra dev pytest tests/test_realtime_v2_websocket.py -q --no-cov

- [x] **Step 3: Implement the gateway**

Inject the backend. Run a client-event producer and backend-event consumer task. Acquire asr_realtime capacity before opening the session. On cancel, cancel/await both tasks and suppress all later events. Convert only QueueFullError/profile saturation to 1013.

- [x] **Step 4: Synchronize the contract and commit**

    uv run --extra dev pytest tests/test_realtime_v2_websocket.py -q --no-cov
    git add src/speechrail/app.py src/speechrail/realtime contracts/realtime-v2.md tests/test_realtime_v2_websocket.py
    git commit -m "feat: expose realtime v2 transcription"

## Task 5: Port the TTS worker mechanics and add REST speech

实施状态：**代码完成，真实模型未验收**（`5805f3c`）。REST、受监督隔离 TTS worker、
私有 IPC 与 fake-runtime 生命周期测试均已完成；模型下载、依赖安装、实际加载及质量/延迟
验收仍需单独授权。

**Files:**
- Create: src/speechrail/backends/qwen3_tts.py
- Create: src/speechrail/backends/qwen3_tts_worker.py
- Create: src/speechrail/http/speech.py
- Create: tests/test_speech_api.py
- Modify: pyproject.toml, src/speechrail/config/__init__.py, src/speechrail/app.py, contracts/openapi.yaml

**Interfaces:**
- POST /v1/audio/speech accepts model, input, voice, response_format and speed.
- Qwen3TtsWorker.stream(text, voice, speed) yields PCM after returning a negotiated sample rate.
- Preset voices are server registry entries, never free-form voice descriptions or samples.

- [ ] **Step 1: Write failing fake-backend REST tests**

    response = client.post("/v1/audio/speech", json={
        "model": "speechrail/tts-default-zh",
        "input": "你好。",
        "voice": "speechrail/voice/zh-default",
        "response_format": "pcm",
        "speed": 1.0,
    })
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/")
    assert response.content == PCM_FIXTURE

Cover unknown model/voice, blank/overlong input, invalid speed, unavailable backend, PCM and WAV response correctness.

- [ ] **Step 2: Run RED**

Run: uv run --extra dev pytest tests/test_speech_api.py -q --no-cov

- [ ] **Step 3: Port reusable worker mechanics only**

Port text normalization, bounded producer/consumer queue, cancellation, PCM conversion and sample-rate validation from sona tts_bridge/engine.py. Do not port global voice mutation, custom voice text, HTTP service state, playback or application configuration.

- [ ] **Step 4: Add optional runtime configuration**

Add a tts dependency group with the Python-3.12-compatible mlx-audio requirement. Add external QWEN3_TTS_MODEL_DIR, QWEN3_TTS_PYTHON, preset voices, output sample rate and TTS_ALLOW_MODEL_DOWNLOADS=false. Do not run the tts dependency install or download weights without separate authorization.

- [ ] **Step 5: Implement REST/OpenAPI and commit**

WAV response prepends a correct 44-byte header only after final PCM length is known. Streaming PCM uses StreamingResponse. Do not advertise compressed formats before an encoder and test exist.

    uv run --extra dev pytest tests/test_speech_api.py -q --no-cov
    uv run --extra dev ruff check src tests
    uv run --extra dev mypy src
    git add pyproject.toml src/speechrail/backends src/speechrail/http src/speechrail/config src/speechrail/app.py contracts/openapi.yaml tests/test_speech_api.py
    git commit -m "feat: add public text to speech endpoint"

## Task 6: Add Realtime v2 TTS response lifecycle

实施状态：**已完成**（`8bf2389`、`af21d7c`）。

**Files:**
- Create: tests/test_realtime_v2_tts.py
- Modify: src/speechrail/realtime/v2_gateway.py
- Modify: src/speechrail/app.py
- Modify: contracts/realtime-v2.md

**Interfaces:**
- Produce response.created, response.audio.delta, response.audio.completed, response.audio.cancelled and session.completed.
- Only one active response may produce audio per speech session.

- [ ] **Step 1: Write failing cancellation/backpressure tests**

    socket.send_json({"type": "speech_input.append", "text": "第一句。"})
    socket.send_json({"type": "speech_input.flush"})
    created = socket.receive_json()
    assert created["type"] == "response.created"
    socket.send_json({"type": "response.cancel", "response_id": created["response_id"]})
    assert socket.receive_json()["type"] == "response.audio.cancelled"

Assert contiguous chunk_index, no delta after cancellation confirmation and slow-consumer terminal behavior.

- [ ] **Step 2: Run RED**

Run: uv run --extra dev pytest tests/test_realtime_v2_tts.py -q --no-cov

- [ ] **Step 3: Implement bounded event pump**

Use a bounded outbound queue; producer assigns chunk_index and writer serially sends events. On full queue, cancel backend, emit slow_consumer, then close. Acquire tts_realtime capacity before response creation.

- [ ] **Step 4: Run GREEN and commit**

    uv run --extra dev pytest tests/test_realtime_v2_tts.py -q --no-cov
    git add src/speechrail/realtime src/speechrail/app.py contracts/realtime-v2.md tests/test_realtime_v2_tts.py
    git commit -m "feat: stream text to speech over realtime v2"

## Task 7: Implement durable batch jobs

实施状态：**已完成**（`2116085` 至 `6d582a5`）。

**Files:**
- Create: src/speechrail/runtime/jobs.py
- Create: src/speechrail/http/jobs.py
- Create: tests/test_jobs.py
- Modify: src/speechrail/config/__init__.py
- Modify: src/speechrail/app.py
- Modify: contracts/openapi.yaml

**Interfaces:**
- JobRepository.create(), claim_next(), complete(), fail(), cancel(), delete_result(), expire().
- Job state is queued, running, completed, failed, cancelled or expired.
- Job result access is scoped to an owner fingerprint, never a raw key.

- [ ] **Step 1: Write failing SQLite tests**

    job = repository.create(kind="speech", owner="key-fingerprint", request={"input": "你好"})
    assert repository.cancel(job.id).state == "cancelled"
    assert repository.get(job.id, owner="other") is None

Cover atomic claim, restart conversion of running jobs to failed(worker_interrupted), result deletion and TTL measured from completed_at.

- [ ] **Step 2: Run RED**

Run: uv run --extra dev pytest tests/test_jobs.py -q --no-cov

- [ ] **Step 3: Implement external spool**

Require an absolute SPEECHRAIL_JOB_SPOOL_DIR outside the repository. Use SQLite WAL, directory mode 0700 and files 0600. Delete source audio after inference. On startup recover unfinished jobs before accepting new jobs.

- [ ] **Step 4: Expose REST resources and commit**

POST returns 202/job ID; GET returns only same-owner state/result reference; DELETE cancels queued work or removes a completed result. Route execution through the batch governor lane.

    uv run --extra dev pytest tests/test_jobs.py -q --no-cov
    git add src/speechrail/runtime/jobs.py src/speechrail/http/jobs.py src/speechrail/config src/speechrail/app.py contracts/openapi.yaml tests/test_jobs.py
    git commit -m "feat: add durable speech batch jobs"

## Task 8: Port real streaming ASR backend without leaking WLK

实施状态：**代码完成，sidecar smoke 未验收**（`4fd23de`）。已实现外部 WLK endpoint 的
受限连接、snapshot 归一化和 v2 session 接线；服务不会安装、启动或下载 sidecar。

**Files:**
- Create: src/speechrail/backends/wlk_streaming.py
- Create: src/speechrail/backends/wlk_sidecar.py
- Create: tests/test_wlk_streaming.py
- Modify: src/speechrail/config/__init__.py
- Modify: src/speechrail/app.py
- Modify: docs/05-runtime-deployment.md

**Interfaces:**
- WlkStreamingBackend implements Task 3 StreamingAsrBackend.
- Sidecar paths/executable are explicit external settings and never trigger downloads.
- Public output is AsrBackendEvent, never WLK lines or buffer_transcription.

- [ ] **Step 1: Write failing fake-transport tests**

    async def test_snapshot_becomes_partial_then_completed() -> None:
        transport = FakeWlkTransport([
            {"lines": [], "buffer_transcription": "正在"},
            {"lines": [{"text": "正在讲话", "start": 0, "end": 1}], "buffer_transcription": ""},
        ])
        events = [event async for event in WlkStreamingBackend(transport).events()]
        assert [event.kind for event in events] == ["partial", "completed"]

- [ ] **Step 2: Run RED**

Run: uv run --extra dev pytest tests/test_wlk_streaming.py -q --no-cov

- [ ] **Step 3: Implement adapter/supervisor**

Port protocol normalization from sona asr/adapters/wlk.py and local executable lifecycle constraints from subtitles/launcher.py. Preflight paths, own the sidecar process, cancel on session teardown and translate snapshots before the backend port.

- [ ] **Step 4: Add disabled-until-proven profile and commit**

The profile returns backend_not_ready until a separately authorized local streaming runtime passes synthetic 16 kHz PCM smoke with recorded device/dtype/event order.

    uv run --extra dev pytest tests/test_wlk_streaming.py -q --no-cov
    git add src/speechrail/backends src/speechrail/config src/speechrail/app.py docs/05-runtime-deployment.md tests/test_wlk_streaming.py
    git commit -m "feat: adapt streaming asr backend for realtime v2"

## Task 9: Migrate sona through two narrow adapters

实施状态：**代码完成，影子/切换未验收**（`e585597` 至 `dcb45f2`）。

**Workspace:** create a new sona worktree and branch. Do not edit SpeechRail in this task.

**Files:**
- Create: src/sona/asr/adapters/speechrail_realtime.py
- Create: tests/asr/test_speechrail_realtime.py
- Modify: src/sona/asr/defaults.py
- Modify: src/sona/asr/registry.py
- Modify: src/sona/ui/subtitle_proxy.py
- Modify: src/sona/interaction/pipeline.py

**Interfaces:**
- SpeechRailRealtimeClient owns handshake, sequence validation, non-resumable reconnect and close.
- SpeechRailStreamingTranscriber implements existing StreamingTranscriber for subtitles/meetings.
- SpeechRailConversationSTTFactory implements existing ConversationSTTFactory for Pipecat.

- [ ] **Step 1: Write failing fake-v2-server tests**

Assert PCM maps to append, finish maps to commit, delta becomes a current TranscriptWindow snapshot, completed becomes confirmed segments, a disconnect creates a new source epoch and shadow output cannot persist meetings or trigger LLM.

- [ ] **Step 2: Run RED**

Run: VR_TEST_DATABASE_URL=postgresql:///knowledge uv run pytest tests/asr/test_speechrail_realtime.py -q --no-cov

- [ ] **Step 3: Implement shared client and two adapters**

Keep WLK fields out of the new client. The subtitle adapter maps v2 items to TranscriptWindow. The Pipecat factory maps completed items to existing STT frames. Do not change AudioHub, RuntimeModeCoordinator, echo suppression, TTS bridge, meeting repository or UI.

- [ ] **Step 4: Add opt-in settings, shadow test and commit**

Add disabled-by-default independent ASR v2 settings for subtitles and conversation. Shadow mode duplicates bounded PCM only for diagnostics and never writes duplicate results.

    VR_TEST_DATABASE_URL=postgresql:///knowledge uv run pytest tests/asr/test_speechrail_realtime.py -q --no-cov
    git add src/sona/asr src/sona/ui/subtitle_proxy.py src/sona/interaction/pipeline.py tests/asr/test_speechrail_realtime.py
    git commit -m "feat(asr): add speechrail realtime v2 adapters"

## Task 10: Complete docs, tests and separately authorized smokes

实施状态：**文档与确定性质量门已完成；真实运行 gate 待授权**（`ecfb815`、`39dcb9b`）。

**Files:**
- Modify: README.md, CHANGELOG.md, configs/speechrail.example.env, contracts/openapi.yaml
- Modify: docs/02-api-contract.md, docs/04-integrations.md, docs/05-runtime-deployment.md, docs/06-security-observability.md, docs/07-testing-acceptance.md, docs/08-migration-runbook.md, docs/09-open-questions.md
- Create: tests/test_v2_integration.py

- [ ] **Step 1: Write failing full-route fake-backend integration tests**

Drive one v2 ASR session, one v2 TTS session and one job through FastAPI. Assert auth, request IDs, terminal event order, cancellation, TTL cleanup and redacted logs.

- [ ] **Step 2: Implement remaining operations/docs**

Document v1/v2 coexistence, profile readiness, slots, spool, voice registry, loopback-only legacy route, non-resumable reconnect and the two adapter migration. Mark all model-backed claims unverified until their real smoke evidence exists.

- [ ] **Step 3: Run complete SpeechRail quality gate**

    uv run --extra dev pytest
    uv run --extra dev ruff check src tests
    uv run --extra dev mypy src
    npx @redocly/cli lint contracts/openapi.yaml
    plutil -lint deploy/macos/com.speechrail.plist.example
    git diff --check

- [ ] **Step 4: Run separately authorized runtime/client gates**

Only after explicit authorization: ASR v2 synthetic PCM; TTS REST/v2 preconfigured voice; QwenPaw REST regression; sona subtitle shadow; sona conversation STT shadow; then each cutover and rollback. Record no raw audio or transcript in Git.

- [ ] **Step 5: Commit**

    git add README.md CHANGELOG.md configs contracts docs tests
    git commit -m "docs: document public asr tts runtime rollout"

## Plan Self-Review

- Tasks 1-4 cover the Realtime v2 contract; Tasks 2 and 7 cover Resource Governor/jobs; Tasks 5-6 implement batch/stream TTS; Task 8 supplies real streaming ASR; Task 9 migrates both sona ports; Task 10 covers security, operations and acceptance.
- No task downloads models, activates a profile, switches a client or installs a service without the named authorization gate.
- Every public event is produced from Task 1 session types and Task 3 typed backend ports; no vendor or meeting field crosses into the public API.
