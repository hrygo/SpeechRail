from __future__ import annotations

import asyncio
import base64
import threading
import time
from collections.abc import AsyncIterator
from concurrent.futures import ThreadPoolExecutor
from itertools import pairwise
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import speechrail.application.realtime_asr as realtime_asr_module
import speechrail.application.realtime_openai as realtime_openai_module
from realtime_wire import (
    server_vad,
    session_update,
    tts_append_text,
    tts_cancel,
    tts_finish_text,
    tts_start,
)
from speechrail.application.realtime_asr import RealtimeAsrOwner
from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    apply_session_update,
    error_event,
)
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
from speechrail.domain.alignment import (
    AlignmentRequest,
    AlignmentResult,
    AlignmentUnit,
)
from speechrail.domain.asr_policy import ASRPolicy
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.diarization import (
    ActivityFrame,
    ActivityUpdate,
    DiarizationError,
    SampleSpan,
)
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.domain.ports import (
    AudioChunk,
    RealtimeAsrSession,
    RealtimeTranscriptionOptions,
    SpeechRequest,
    StreamingAsrEvent,
    TranscriptionRequest,
)
from speechrail.http.routes.realtime_openai import (
    OUTBOUND_SEND_TIMEOUT_CLOSE_CODE,
    _send_json_with_deadline,
    create_openai_realtime_router,
)


class FakeTranscriber:
    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        return TranscriptResult(
            request_id=request.request_id,
            model_id="speechrail/qwen3-asr-1.7b",
            text=f"{len(request.audio)} bytes",
            language=request.language or "auto",
            duration_ms=1,
        )


class FakeSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest):
        async def chunks():
            yield AudioChunk(response_id="internal", chunk_index=0, audio=b"\x00\x00")

        return chunks()


class BlockingSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest):
        async def chunks():
            yield AudioChunk(response_id="internal", chunk_index=0, audio=b"\x00\x00")
            await asyncio.sleep(60)

        return chunks()


class LoopbackSpeechSynthesizer:
    """Block the first render and complete the next one after cancellation."""

    def __init__(self) -> None:
        self.calls: list[str] = []

    def synthesize(self, request: SpeechRequest):
        call_index = len(self.calls)
        self.calls.append(request.text)

        async def chunks():
            yield AudioChunk(response_id="internal", chunk_index=0, audio=b"\x00\x00")
            if call_index == 0:
                await asyncio.sleep(60)

        return chunks()


class HangingSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest):
        async def chunks():
            if False:  # Keep this as an async generator without yielding audio.
                yield AudioChunk(response_id="internal", chunk_index=0, audio=b"")
            await asyncio.sleep(60)

        return chunks()


class InvalidSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest):
        async def chunks():
            yield AudioChunk(response_id="internal", chunk_index=0, audio=b"\x00")

        return chunks()


class EmptySpeechSynthesizer:
    def synthesize(self, request: SpeechRequest):
        async def chunks():
            if False:  # Keep this as an async generator without yielding audio.
                yield AudioChunk(response_id="internal", chunk_index=0, audio=b"\x00\x00")

        return chunks()


class UnavailableSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest):
        async def chunks():
            raise RuntimeError("worker_unavailable; worker stderr tail: private detail")
            yield AudioChunk(response_id="internal", chunk_index=0, audio=b"\x00\x00")

        return chunks()


class FailingSpeechSynthesizer:
    def __init__(self, failure: Exception) -> None:
        self._failure = failure

    def synthesize(self, request: SpeechRequest):
        async def chunks():
            raise self._failure
            yield AudioChunk(response_id="internal", chunk_index=0, audio=b"\x00\x00")

        return chunks()


class FakeStreamingSession:
    def __init__(
        self,
        *,
        language: str | None,
        prompt: str = "",
        segments: tuple[object, ...] = (),
        partials: tuple[str, ...] = (),
        flush_partials: tuple[str, ...] = (),
        completed_text: str = "你好",
        emit_text_on_flush: str | None = None,
    ) -> None:
        self.language = language
        self.prompt = prompt
        self.segments = segments
        self.partials = partials
        self.flush_partials = list(flush_partials)
        self.completed_text = completed_text
        self.emit_text_on_flush = emit_text_on_flush
        self.flushes = 0
        self.appends = 0
        self.commits = 0
        self.closes = 0
        self.received: list[bytes] = []
        self.want_segments = False
        self.events_queue: asyncio.Queue[StreamingAsrEvent | None] = asyncio.Queue()
        self._finished = asyncio.Event()
        self.options: RealtimeTranscriptionOptions | None = None

    async def connect(self) -> None:
        return None

    async def append_audio(self, audio: bytes) -> None:
        self.appends += 1
        self.received.append(audio)

    async def flush(self) -> None:
        self.flushes += 1
        if self.flush_partials:
            text = self.flush_partials.pop(0)
            await self.events_queue.put(StreamingAsrEvent(kind="partial", text=text))
        elif self.emit_text_on_flush is not None:
            await self.events_queue.put(
                StreamingAsrEvent(kind="partial", text=self.emit_text_on_flush)
            )

    async def commit(self, want_segments: bool = False) -> None:
        self.commits += 1
        self.want_segments = want_segments
        for partial in self.partials:
            await self.events_queue.put(StreamingAsrEvent(kind="partial", text=partial))
        await self.events_queue.put(
            StreamingAsrEvent(
                kind="completed", text=self.completed_text, language="zh", segments=self.segments
            )
        )
        await self.events_queue.put(None)
        self._finished.set()

    def events(self) -> AsyncIterator[StreamingAsrEvent]:
        async def iterator() -> AsyncIterator[StreamingAsrEvent]:
            while (event := await self.events_queue.get()) is not None:
                yield event

        return iterator()

    async def close(self) -> None:
        self.closes += 1
        return


class FakeStreamingFactory:
    def __init__(
        self,
        *,
        segments: tuple[object, ...] = (),
        partials: tuple[str, ...] = (),
        flush_partials: tuple[str, ...] = (),
        completed_text: str = "你好",
        emit_text_on_flush: str | None = None,
    ) -> None:
        self.segments = segments
        self.partials = partials
        self.flush_partials = flush_partials
        self.completed_text = completed_text
        self.emit_text_on_flush = emit_text_on_flush
        self.sessions: list[FakeStreamingSession] = []
        self.released: list[RealtimeAsrSession] = []
        self.creates = 0
        self.options: list[RealtimeTranscriptionOptions] = []

    def session_class(self) -> type[FakeStreamingSession]:
        return FakeStreamingSession

    def create(
        self,
        *,
        language: str | None,
        prompt: str,
        options: RealtimeTranscriptionOptions,
    ) -> FakeStreamingSession:
        self.creates += 1
        session = self.session_class()(
            language=language,
            prompt=prompt,
            segments=self.segments,
            partials=self.partials,
            flush_partials=self.flush_partials,
            completed_text=self.completed_text,
            emit_text_on_flush=self.emit_text_on_flush,
        )
        session.options = options
        self.options.append(options)
        self.sessions.append(session)
        return session

    def release(self, session: RealtimeAsrSession) -> None:
        self.released.append(session)


def _wait_for_releases(
    released: list[RealtimeAsrSession], count: int, timeout: float = 2.0
) -> None:
    """Wait for the server-side release to land after the socket closes.

    Releasing the session happens in the application's own task, so an
    assertion placed immediately after the ``with`` block races it. One test in
    this file already waited (see the deadline loop near the end); the ones that
    came first were simply never exercised under load. Measured 2026-09-29:
    ``test_openai_append_commit_produces_transcription_completed`` failed this
    way once across two full-suite runs and passed 5/5 in isolation, which is
    the signature of a teardown race rather than a behaviour change.
    """
    deadline = time.monotonic() + timeout
    while len(released) < count and time.monotonic() < deadline:
        time.sleep(0.01)


class RejectingLanguageStreamingFactory(FakeStreamingFactory):
    """Mirrors the native factory that raises RuntimeError for unsupported languages."""

    def create(
        self,
        *,
        language: str | None,
        prompt: str,
        options: RealtimeTranscriptionOptions,
    ) -> FakeStreamingSession:
        resolved = (language or "auto").strip().lower()
        if resolved.startswith("xx"):
            raise RuntimeError(f"language_not_supported: {resolved}")
        return super().create(language=language, prompt=prompt, options=options)


class _EarlyCompletionSession(FakeStreamingSession):
    """Emits final events while commit() is still awaiting the backend ack."""

    async def commit(self, want_segments: bool = False) -> None:
        self.want_segments = want_segments
        await self.events_queue.put(
            StreamingAsrEvent(kind="completed", text="你好", language="zh", segments=self.segments)
        )
        await self.events_queue.put(None)
        await asyncio.sleep(0.05)


class EarlyCompletionStreamingFactory(FakeStreamingFactory):
    def session_class(self) -> type[FakeStreamingSession]:
        return _EarlyCompletionSession


class FailingStreamingSession(FakeStreamingSession):
    """Emit a terminal worker error instead of a completed transcript."""

    async def commit(self, want_segments: bool = False) -> None:
        self.commits += 1
        self.want_segments = want_segments
        await self.events_queue.put(
            StreamingAsrEvent(kind="error", error_code="backend_error")
        )
        await self.events_queue.put(None)
        self._finished.set()


class FailingStreamingFactory(FakeStreamingFactory):
    def session_class(self) -> type[FakeStreamingSession]:
        return FailingStreamingSession


class FakeDiarizationSession:
    def __init__(self) -> None:
        self.received: list[bytes] = []
        self.closed = False
        self.epoch = ""
        self._updates: asyncio.Queue[ActivityUpdate | None] = asyncio.Queue()
        self._step = 0

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        assert start_sample == sum(len(audio) // 2 for audio in self.received)
        self.received.append(pcm16)
        end = start_sample + len(pcm16) // 2
        await self._updates.put(
            ActivityUpdate(
                epoch=self.epoch,
                step_id=self._step,
                replace_span=SampleSpan(start_sample, end),
                frames=(
                    ActivityFrame(
                        SampleSpan(start_sample, end), (0.95, 0.0, 0.0, 0.0), frozenset({0})
                    ),
                ),
                processed_through=end,
                stable_through=end,
            )
        )
        self._step += 1

    async def updates(self):
        while update := await self._updates.get():
            yield update

    async def finish(self, *, through_sample: int) -> None:
        assert through_sample == sum(len(audio) // 2 for audio in self.received)
        await self._updates.put(None)

    async def cancel(self) -> None:
        self.closed = True
        await self._updates.put(None)


class _NoEvidenceDiarizationSession(FakeDiarizationSession):
    """Emit processed audio without a speaker so provisional units stay unknown."""

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        assert start_sample == sum(len(audio) // 2 for audio in self.received)
        self.received.append(pcm16)
        end = start_sample + len(pcm16) // 2
        await self._updates.put(
            ActivityUpdate(
                epoch=self.epoch,
                step_id=self._step,
                replace_span=SampleSpan(start_sample, end),
                frames=(),
                processed_through=end,
                stable_through=0,
            )
        )
        self._step += 1


class FakeDiarizationEngine:
    def __init__(self, *, supports_stream: bool = True) -> None:
        self.supports_stream = supports_stream
        self.sessions: list[FakeDiarizationSession] = []

    def open(self, *, epoch: str):
        session = FakeDiarizationSession()
        session.epoch = epoch
        self.sessions.append(session)
        return session


class _NoEvidenceDiarizationEngine(FakeDiarizationEngine):
    def open(self, *, epoch: str) -> _NoEvidenceDiarizationSession:
        session = _NoEvidenceDiarizationSession()
        session.epoch = epoch
        self.sessions.append(session)
        return session


class FakeTextAligner:
    async def align(self, request: AlignmentRequest) -> AlignmentResult:
        return AlignmentResult(
            task_id=request.task_id,
            epoch=request.epoch,
            utterance_id=request.utterance_id,
            transcript_revision=request.transcript_revision,
            units=(
                AlignmentUnit("fixed", 0, len(request.text), request.span, "segment"),
            ),
        )


class FailingDiarizationSession(FakeDiarizationSession):
    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        del start_sample, pcm16
        raise DiarizationError("invalid diarization output", code="diarization_invalid_output")


class FailingDiarizationEngine:
    def open(self, *, epoch: str):
        del epoch
        return FailingDiarizationSession()


def _client(
    *,
    segments: tuple[object, ...] = (),
    partials: tuple[str, ...] = (),
    flush_partials: tuple[str, ...] = (),
    completed_text: str = "你好",
    emit_text_on_flush: str | None = None,
    diarization_engine=None,
    text_aligner=None,
    tts_synthesizer=None,
    api_key: str | None = None,
    factory: FakeStreamingFactory | None = None,
    settings_kwargs: dict[str, Any] | None = None,
) -> tuple[TestClient, FakeStreamingFactory]:
    streaming_factory = factory or FakeStreamingFactory(
        segments=segments,
        partials=partials,
        flush_partials=flush_partials,
        completed_text=completed_text,
        emit_text_on_flush=emit_text_on_flush,
    )
    overrides: dict[str, Any] = {
        "qwen3_model_dir": None,
        "qwen3_python": None,
        "diarization_model_path": None,
        "diarization_embedding_model_path": None,
        "api_key": api_key,
    }
    if settings_kwargs:
        overrides.update(settings_kwargs)
    settings = Settings(**overrides)
    services = build_app_services(
        settings,
        AppOverrides(
            batch_transcriber=FakeTranscriber(),
            tts_synthesizer=tts_synthesizer or FakeSpeechSynthesizer(),
            realtime_asr_factory=streaming_factory,
            diarization_engine=diarization_engine,
            text_aligner=text_aligner
            or (FakeTextAligner() if diarization_engine is not None else None),
        ),
    )
    app = FastAPI()
    app.include_router(create_openai_realtime_router(services))
    return (
        TestClient(app),
        streaming_factory,
    )


# One wire frame is 24 kHz mono PCM16; it must span at least two source
# samples so the 24k -> 16k boundary resampler emits kernel audio immediately.
_FRAME = b"\x00\x00" * 8


def _pcm16(audio: bytes) -> str:
    return base64.b64encode(audio).decode("ascii")


def test_realtime_asr_admission_preserves_isolation_error_under_serial_policy() -> None:
    async def scenario() -> None:
        settings = Settings(qwen3_model_dir=None, qwen3_python=None)
        services = build_app_services(
            settings,
            AppOverrides(
                batch_transcriber=FakeTranscriber(),
                tts_synthesizer=FakeSpeechSynthesizer(),
                realtime_asr_factory=FakeStreamingFactory(),
            ),
        )
        assert not services.governor.snapshot().allow_heavy_overlap
        services.governor.quarantine_tts_lane("tts_base")

        async def send(event: dict[str, object]) -> None:
            pytest.fail("isolated ASR must not publish successful work")

        session = OpenAIRealtimeSession(services, session_id="isolated-test", send=send)
        with pytest.raises(RealtimeAdapterError) as isolated:
            await session._asr_owner._reserve_asr()
        assert isolated.value.code == "backend_reclamation_failed"
        assert not getattr(isolated.value, "busy_reason", None)
        assert session._asr_owner._asr_resources is None
        assert services.governor.snapshot().active_asr == 0
        assert services.governor.snapshot().pending_realtime == 0

    asyncio.run(scenario())


def _receive_committed_item(
    socket: Any,
    *,
    expect_boundary: bool = True,
    allow_error: bool = False,
    expected_sample_span: tuple[int, int] | None = None,
    expected_commit_event_id: str | None = None,
) -> tuple[dict[str, Any] | None, dict[str, Any], list[dict[str, Any]]]:
    """Read and validate the close boundary before its matching terminal."""
    events: list[dict[str, Any]] = []
    boundary: dict[str, Any] | None = None
    while True:
        event = socket.receive_json()
        events.append(event)
        if event["type"] == "speechrail.transcription.segment_closed":
            assert boundary is None, "one committed item must have one close boundary"
            boundary = event
            continue
        if event["type"] in {
            "conversation.item.input_audio_transcription.completed",
            "conversation.item.input_audio_transcription.failed",
        } or (allow_error and event["type"] == "error"):
            terminal = event
            break
        if event["type"] == "error":
            raise AssertionError(f"unexpected error while waiting for item terminal: {event}")

    assert (terminal["type"] == "error") is allow_error
    assert (boundary is not None) is expect_boundary
    if boundary is not None:
        span = boundary["sample_span"]
        assert isinstance(span, dict)
        start = span["start"]
        end = span["end"]
        assert type(start) is int and type(end) is int
        assert 0 <= start < end
        assert boundary["reason"] in {"vad", "client_commit", "budget_rollover"}
        if terminal["type"] != "error":
            assert boundary["item_id"] == terminal["item_id"]
            assert boundary.get("commit_event_id") == terminal.get("commit_event_id")
        if expected_sample_span is not None:
            assert (start, end) == expected_sample_span
    if expected_commit_event_id is not None:
        assert terminal.get("commit_event_id") == expected_commit_event_id
    return boundary, terminal, events


def test_backend_busy_error_keeps_compat_code_and_namespaced_reason() -> None:
    event = error_event(
        code="backend_busy",
        message="realtime streaming session capacity is full",
        busy_reason="realtime_session_limit",
    )

    assert event["error"]["code"] == "backend_busy"
    # The closed error object folds the retry policy into the message so the
    # stable ``code`` remains the only machine-readable branch key.
    assert "retryable=True" in str(event["error"]["message"])
    assert "hint=wait_for_realtime_session_slot" in str(event["error"]["message"])


def test_openai_session_created_and_updated() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        created = socket.receive_json()
        assert created["type"] == "session.created"
        audio_input = created["session"]["audio"]["input"]
        assert audio_input["format"] == {"type": "audio/pcm", "rate": 24000}
        assert audio_input["transcription"]["model"] == "speechrail/qwen3-asr-1.7b"
        assert created["session"]["speechrail"]["task"] == "conversation"
        assert audio_input["turn_detection"] is None

        socket.send_json(session_update(model="whisper-1", language="zh"))
        updated = socket.receive_json()
        assert updated["type"] == "session.updated"
        audio_input = updated["session"]["audio"]["input"]
        # A registered compatibility alias is echoed back verbatim.
        assert audio_input["transcription"]["model"] == "whisper-1"
        assert audio_input["transcription"]["language"] == "zh"


def test_server_event_sequence_starts_at_zero_and_stays_contiguous() -> None:
    """契约 §5: 基础事件的 sequence 从 0 连续递增。

    首个事件不是 0 时, 严格的客户端会把连接判成缺口并直接关闭——这正是
    macOS App 启动失败的根因, 所以 numbering 必须由服务端测试钉住。
    """
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        created = socket.receive_json()
        assert created["type"] == "session.created"
        assert created["sequence"] == 0
        assert created["session_id"].startswith("realtime_")

        socket.send_json(session_update(model="whisper-1"))
        updated = socket.receive_json()
        assert updated["type"] == "session.updated"
        assert updated["sequence"] == 1
        assert updated["session_id"] == created["session_id"]


def test_realtime_send_timeout_closes_slow_consumer() -> None:
    class SlowWebSocket:
        def __init__(self) -> None:
            self.closed: tuple[int, str] | None = None

        async def send_json(self, payload: dict[str, object]) -> None:
            del payload
            await asyncio.Event().wait()

        async def close(self, *, code: int, reason: str) -> None:
            self.closed = (code, reason)

    async def scenario() -> SlowWebSocket:
        websocket = SlowWebSocket()
        sent = await _send_json_with_deadline(  # type: ignore[arg-type]
            websocket,
            {"type": "speechrail.tts.audio.delta"},
            timeout_seconds=0.01,
        )
        assert sent is False
        return websocket

    websocket = asyncio.run(scenario())
    assert websocket.closed == (OUTBOUND_SEND_TIMEOUT_CLOSE_CODE, "outbound send timed out")


def test_openai_append_commit_produces_transcription_completed() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            session_update(model="whisper-1")
        )
        socket.receive_json()  # session.updated

        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json(
            {"type": "input_audio_buffer.commit", "event_id": "commit-tail-1"}
        )

        boundary, completed, _ = _receive_committed_item(
            socket,
            expected_sample_span=(0, len(_FRAME) // 2),
            expected_commit_event_id="commit-tail-1",
        )
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert completed["transcript"] == "你好"
        assert completed["commit_event_id"] == "commit-tail-1"
        assert len(factory.sessions) == 1
        assert factory.sessions[0].language is None
        _wait_for_releases(factory.released, 1)
        assert len(factory.released) == 1


def test_realtime_completed_turn_records_commit_tail_duration() -> None:
    async def scenario() -> dict[str, object]:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                batch_transcriber=FakeTranscriber(),
                tts_synthesizer=FakeSpeechSynthesizer(),
                realtime_asr_factory=FakeStreamingFactory(),
            ),
        )
        events: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> None:
            events.append(event)

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_metrics_test",
            send=send,
        )
        await session.start()
        await session.handle(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        await session.handle({"type": "input_audio_buffer.commit"})
        await session.close()
        return services.metrics.render_json()

    metrics = asyncio.run(scenario())
    histograms = metrics["histograms"]
    assert isinstance(histograms, dict)
    duration = histograms["speechrail_realtime_turn_duration_seconds"]
    assert isinstance(duration, dict)
    reading = next(iter(duration.values()))
    assert reading["count"] == 1
    assert reading["avg"] > 0.0


def test_realtime_first_hypothesis_metrics_distinguish_partial_missing_and_send_failure() -> None:
    async def scenario(
        partials: tuple[str, ...], *, fail_partial_send: bool
    ) -> dict[str, object]:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(partials=partials),
            ),
        )

        async def send(event: dict[str, object]) -> int | None:
            if fail_partial_send and event.get("type") == (
                "speechrail.transcription.hypothesis"
            ):
                return None
            return 1

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_first_hypothesis_metrics",
            send=send,
        )
        await session.start()
        await session.handle(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        await session.handle({"type": "input_audio_buffer.commit"})
        await session.close()
        return services.metrics.render_json()

    partial_metrics = asyncio.run(scenario(("abc",), fail_partial_send=False))
    partial_counters = partial_metrics["counters"]
    assert isinstance(partial_counters, dict)
    assert partial_counters[
        'speechrail_realtime_first_hypothesis_total{outcome="partial"}'
    ] == 1
    partial_histograms = partial_metrics["histograms"]
    assert isinstance(partial_histograms, dict)
    latency = partial_histograms["speechrail_realtime_first_hypothesis_seconds"]
    assert isinstance(latency, dict)
    assert all(reading["count"] == 1 for reading in latency.values())
    audio = partial_histograms["speechrail_realtime_first_hypothesis_audio_seconds"]
    assert isinstance(audio, dict)
    assert next(iter(audio.values()))["count"] == 1

    missing_metrics = asyncio.run(scenario((), fail_partial_send=False))
    missing_counters = missing_metrics["counters"]
    assert isinstance(missing_counters, dict)
    assert missing_counters[
        'speechrail_realtime_first_hypothesis_total{outcome="missing"}'
    ] == 1
    missing_histograms = missing_metrics["histograms"]
    assert isinstance(missing_histograms, dict)
    assert "speechrail_realtime_first_hypothesis_seconds" not in missing_histograms

    failed_send_metrics = asyncio.run(scenario(("abc",), fail_partial_send=True))
    failed_send_counters = failed_send_metrics["counters"]
    assert isinstance(failed_send_counters, dict)
    assert failed_send_counters[
        'speechrail_realtime_first_hypothesis_total{outcome="send_failed"}'
    ] == 1


def test_realtime_first_hypothesis_metrics_record_cancelled_and_failed() -> None:
    async def scenario(*, cancel: bool) -> dict[str, object]:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        factory = FakeStreamingFactory() if cancel else FailingStreamingFactory()
        services = build_app_services(
            settings,
            AppOverrides(realtime_asr_factory=factory),
        )

        async def send(event: dict[str, object]) -> int:
            return 1

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_terminal_metrics",
            send=send,
        )
        await session.start()
        await session.handle(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        if cancel:
            await session.handle({"type": "input_audio_buffer.clear"})
        else:
            await session.handle({"type": "input_audio_buffer.commit"})
        await session.close()
        return services.metrics.render_json()

    cancelled = asyncio.run(scenario(cancel=True))
    cancelled_counters = cancelled["counters"]
    assert isinstance(cancelled_counters, dict)
    assert cancelled_counters[
        'speechrail_realtime_first_hypothesis_total{outcome="cancelled"}'
    ] == 1

    failed = asyncio.run(scenario(cancel=False))
    failed_counters = failed["counters"]
    assert isinstance(failed_counters, dict)
    assert failed_counters[
        'speechrail_realtime_first_hypothesis_total{outcome="failed"}'
    ] == 1


def test_realtime_partial_metrics_count_replaceable_snapshots_without_deltas() -> None:
    """Revisions reach snapshot consumers without publishing append-only text."""

    async def scenario() -> tuple[dict[str, object], list[dict[str, object]]]:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(partials=("abc", "wbcd")),
            ),
        )
        sent: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> int:
            sent.append(event)
            return 1

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_rewrite_withheld_metrics",
            send=send,
        )
        await session.start()
        await session.handle(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        await session.handle({"type": "input_audio_buffer.commit"})
        await session.close()
        return services.metrics.render_json(), sent

    metrics, sent = asyncio.run(scenario())
    counters = metrics["counters"]
    assert isinstance(counters, dict)
    assert counters[
        'speechrail_realtime_partial_events_total{outcome="snapshot_sent"}'
    ] == 2
    assert not any(
        event["type"] == "conversation.item.input_audio_transcription.delta"
        for event in sent
    )
    hypotheses = [
        event["text"]
        for event in sent
        if event["type"] == "speechrail.transcription.hypothesis"
    ]
    assert hypotheses == ["abc", "wbcd"]


def test_realtime_first_hypothesis_metrics_survive_a_slow_client(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A slow socket stretches one observation; it never duplicates or drops it."""

    send_delay_seconds = 0.02

    class FakeClock:
        now = 0.0

        def monotonic(self) -> float:
            return self.now

        def advance(self, duration: float) -> None:
            self.now += duration

    clock = FakeClock()
    monkeypatch.setattr(realtime_asr_module, "time", clock)

    async def scenario() -> dict[str, object]:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(partials=("abc", "abcd")),
            ),
        )

        async def send(event: dict[str, object]) -> int:
            if event["type"] == "speechrail.transcription.hypothesis":
                clock.advance(send_delay_seconds)
            return 1

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_slow_client_metrics",
            send=send,
        )
        await session.start()
        await session.handle(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        await session.handle({"type": "input_audio_buffer.commit"})
        await session.close()
        rendered: dict[str, Any] = services.metrics.render_json()
        return rendered

    metrics = asyncio.run(scenario())
    counters = metrics["counters"]
    assert isinstance(counters, dict)
    assert counters[
        'speechrail_realtime_first_hypothesis_total{outcome="partial"}'
    ] == 1
    histograms = metrics["histograms"]
    assert isinstance(histograms, dict)
    latency = histograms["speechrail_realtime_first_hypothesis_seconds"]
    assert isinstance(latency, dict)
    assert all(reading["count"] == 1 for reading in latency.values())
    # The client stall lands in the socket stage, and stays visible as the
    # server-side upper bound rather than being reported as ASR latency.
    worker_to_socket = latency['{stage="worker_to_socket"}']
    assert isinstance(worker_to_socket, dict)
    assert worker_to_socket["avg"] >= send_delay_seconds
    upstream = latency['{stage="upstream_to_worker"}']
    assert isinstance(upstream, dict)
    assert upstream["sum"] == 0.0


def test_realtime_first_hypothesis_metrics_record_at_most_once_per_turn() -> None:
    """Deduplication is per input item: three partials per turn count once.

    Two turns in one session must record exactly two observations, so the
    per-turn guard resets without leaking into the next item.
    """

    async def scenario() -> tuple[dict[str, object], list[dict[str, object]]]:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(
                    partials=("abc", "abcd", "abcde")
                ),
            ),
        )
        sent: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> int:
            sent.append(event)
            return 1

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_once_per_turn_metrics",
            send=send,
        )
        await session.start()
        for _ in range(2):
            await session.handle(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
            )
            await session.handle({"type": "input_audio_buffer.commit"})
        await session.close()
        return services.metrics.render_json(), sent

    metrics, sent = asyncio.run(scenario())
    counters = metrics["counters"]
    assert isinstance(counters, dict)
    # Six upstream partials across two turns, but one observation per turn.
    assert counters[
        'speechrail_realtime_first_hypothesis_total{outcome="partial"}'
    ] == 2
    histograms = metrics["histograms"]
    assert isinstance(histograms, dict)
    latency = histograms["speechrail_realtime_first_hypothesis_seconds"]
    assert isinstance(latency, dict)
    assert latency
    assert all(reading["count"] == 2 for reading in latency.values())
    audio = histograms["speechrail_realtime_first_hypothesis_audio_seconds"]
    assert isinstance(audio, dict)
    assert next(iter(audio.values()))["count"] == 2
    hypotheses = [
        event
        for event in sent
        if event["type"] == "speechrail.transcription.hypothesis"
    ]
    assert len(hypotheses) == 6


def test_openai_commit_releases_streaming_slot_for_next_append() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="whisper-1")
        )
# Realtime ASR/TTS handshake has no conversation.created event

        def commit_round() -> None:
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
            )
            socket.send_json({"type": "input_audio_buffer.commit"})
            boundary, completed, _ = _receive_committed_item(socket)
            assert boundary is not None
            assert completed["type"] == "conversation.item.input_audio_transcription.completed"

        commit_round()
        assert len(factory.released) == 1
        commit_round()
        assert len(factory.sessions) == 2
        assert len(factory.released) == 2


class _HangingConnectSession(FakeStreamingSession):
    """Session whose connect() never resolves until the client disconnects."""

    async def connect(self) -> None:
        await asyncio.Event().wait()


class HangingConnectStreamingFactory(FakeStreamingFactory):
    def session_class(self) -> type[FakeStreamingSession]:
        return _HangingConnectSession


def test_openai_disconnect_releases_slot_while_connect_pending() -> None:
    """A client disconnect that cancels a pending ASR connect() must still
    release the factory slot, or the slot leaks until restart and later
    sessions fail with backend_busy."""

    client, factory = _client(factory=HangingConnectStreamingFactory())
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        deadline = time.monotonic() + 2.0
        while len(factory.sessions) < 1 and time.monotonic() < deadline:
            time.sleep(0.01)
        assert len(factory.sessions) == 1
        assert len(factory.released) == 0

    deadline = time.monotonic() + 2.0
    while len(factory.released) < 1 and time.monotonic() < deadline:
        time.sleep(0.01)
    assert len(factory.released) == 1


def test_openai_model_alias_resolves_to_asr_profile() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="gpt-4o-transcribe")
        )
# Realtime ASR/TTS handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert len(factory.sessions) == 1


def test_openai_diarized_model_alias_does_not_enable_realtime_diarization() -> None:
    engine = FakeDiarizationEngine()
    segment = TranscriptSegment(id=1, start_ms=0, end_ms=500, text="你好")
    client, factory = _client(segments=(segment,), diarization_engine=engine)
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="gpt-4o-transcribe-diarize")
        )
# Realtime ASR/TTS handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, events = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

    assert engine.sessions == []
    assert all(not event["type"].startswith("speechrail.diarization") for event in events)
    assert factory.sessions and factory.sessions[0].want_segments is False


def test_realtime_diarization_encodes_missing_provisional_speaker_as_unknown() -> None:
    client, _ = _client(
        diarization_engine=_NoEvidenceDiarizationEngine(),
    )
    with client.websocket_connect("/v1/realtime") as socket:
        assert socket.receive_json()["type"] == "session.created"
        socket.send_json(
                        session_update(diarization={"enabled": True})
        )
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 8000)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, events = _receive_committed_item(
            socket,
            expected_sample_span=(0, 8_000),
        )
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

        socket.send_json(
            {"type": "speechrail.diarization.finish", "event_id": "final-no-evidence"}
        )
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] in {"speechrail.diarization.done", "error"}:
                break

    units = [
        unit
        for event in events
        if event["type"] == "speechrail.diarization.updated"
        for unit in event["units"]
    ]
    assert units
    # A unit whose speaker is not yet resolved stays explicitly null on the
    # wire instead of inventing a label.
    assert any(unit["speaker"] is None for unit in units)
    assert all(unit["speaker"] == unit["speaker"] for unit in units)


def test_openai_commit_without_diarization_does_not_request_segments() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="whisper-1")
        )
        socket.receive_json()  # session.updated
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, events = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

    assert factory.sessions and factory.sessions[0].want_segments is False
    assert not any(event["type"].endswith(".segment") for event in events)


def test_openai_commit_with_segment_timestamps_requests_segments() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="whisper-1", timestamp_granularities=["segment"])
        )
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

    assert factory.sessions and factory.sessions[0].want_segments is True


def test_openai_realtime_rejects_a_frame_over_the_configured_limit() -> None:
    factory_client, _ = _client()
    with factory_client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="whisper-1")
        )
        socket.receive_json()  # session.updated
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80_001)}
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "frame_too_large"


def test_openai_tts_model_is_rejected_in_transcription_session() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="tts-1")
        )
        error = socket.receive_json()
        assert error["error"]["code"] == "model_not_found"


def test_openai_rejects_unknown_model() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="gpt-5-fake")
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "model_not_found"


def test_openai_rejects_unsupported_turn_detection() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(turn_detection={"type": "unsupported_mode"})
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_turn_detection"


def test_openai_rejects_tools() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(extra_session={"tools": [{"type": "function", "name": "x"}]})
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_operation"


def test_openai_commit_without_audio_is_graceful_and_preserves_session() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(
            socket,
            expect_boundary=False,
        )
        assert boundary is None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert completed["transcript"] == ""

        # Session remains valid for subsequent audio
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, events = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert any(
            event["type"] == "conversation.item.input_audio_transcription.completed"
            for event in events
        )


def test_openai_rejects_unsupported_client_event() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json({"type": "conversation.item.delete", "item_id": "x"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_operation"


def test_openai_invalid_audio_fails_closed() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json({"type": "input_audio_buffer.append", "audio": "not-base64!!"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_audio"


def test_openai_realtime_bad_json_is_recoverable() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_text("{invalid json")
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_event"

        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"


def test_openai_non_string_event_type_is_recoverable_and_releases_asr() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": []})

        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_event"

        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

    assert len(factory.sessions) == 1
    assert factory.sessions[0].closes == 1
    _wait_for_releases(factory.released, 1)
    assert factory.released == factory.sessions


def test_openai_removed_response_create_is_rejected() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# Realtime ASR/TTS handshake has no conversation.created event
        socket.send_json({"type": "response.create"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_operation"


def test_openai_removed_text_item_is_rejected() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "   "}],
                },
            }
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_operation"


def test_openai_session_release_called_on_disconnect() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# Realtime ASR/TTS handshake has no conversation.created event
# Realtime ASR/TTS handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
    # after context exit the session should be released
    assert len(factory.sessions) == 1
    _wait_for_releases(factory.released, 1)
    assert len(factory.released) == 1


class _BlockedCommitSession(FakeStreamingSession):
    """A streaming session whose commit() never completes on its own."""

    async def connect(self) -> None:
        return None

    async def commit(self, want_segments: bool = False) -> None:
        del want_segments
        await asyncio.Event().wait()


class _BlockedCommitFactory(FakeStreamingFactory):
    def session_class(self) -> type[FakeStreamingSession]:
        return _BlockedCommitSession


@pytest.mark.parametrize("request_receipt", [False, True])
def test_openai_disconnect_releases_slot_even_when_commit_blocks(request_receipt: bool) -> None:
    """A client disconnect must release the ASR factory slot promptly even when
    the backend handler is parked inside commit(), instead of leaking it until
    the backend answers (or forever)."""

    client, factory = _client(factory=_BlockedCommitFactory())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# Realtime ASR/TTS handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit", "event_id": "disconnect-barrier",
                          "speechrail": {"request_receipt": request_receipt}})

    assert len(factory.sessions) == 1
    _wait_for_releases(factory.released, 1)
    assert len(factory.released) == 1


def test_openai_segment_events_are_not_part_of_the_current_wire() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {"type": "conversation.item.input_audio_transcription.segment"}
        )
        error = socket.receive_json()
    assert error["type"] == "error"
    assert error["error"]["code"] == "unsupported_operation"


def test_openai_session_update_rejects_unused_speaker_hints() -> None:
    with pytest.raises(RealtimeAdapterError, match="known_speaker"):
        apply_session_update(
                        session_update(
                model="gpt-4o-transcribe-diarize",
                language="zh",
                languages=["zh", "en"],
                keywords=["SpeechRail"],
                timestamp_granularities=["segment"],
                extra_transcription={
                    "known_speaker_names": ["Alice"],
                    "known_speaker_references": ["ref_opaque"],
                },
            ),
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )


def test_openai_realtime_rejects_retired_diarization_request_shape() -> None:
    client, _ = _client(diarization_engine=FakeDiarizationEngine())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            session_update(extra_transcription={"diarization": {"enabled": True}})
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    # Diarization is negotiated under session.speechrail, not inside
    # audio.input.transcription.  The retired shape is rejected as an unknown
    # field rather than silently ignored.
    assert error["error"]["code"] == "unsupported_operation"


def test_openai_realtime_rejects_diarization_without_profile() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# Realtime ASR/TTS handshake has no conversation.created event
        socket.send_json(
                        session_update(diarization={"enabled": True})
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "diarization_not_available"


def test_openai_realtime_clear_discards_active_audio_session() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 3000)}
        )
        socket.send_json({"type": "input_audio_buffer.clear"})
        # The current wire has no clear acknowledgement.  A following commit is
        # the observable barrier: it must produce an empty final and the clear
        # must already have released the discarded streaming session.
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(
            socket,
            expect_boundary=False,
        )
        assert boundary is None

    assert completed["type"] == "conversation.item.input_audio_transcription.completed"
    assert completed["transcript"] == ""
    assert len(factory.released) == 1


def test_openai_realtime_clear_closes_diarization_session() -> None:
    diarization = FakeDiarizationEngine()
    client, _ = _client(diarization_engine=diarization)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            session_update(diarization={"enabled": True})
        )
        socket.receive_json()  # session.updated
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 3000)}
        )
        socket.send_json({"type": "input_audio_buffer.clear"})
        # No clear acknowledgement on the current wire; a following commit acts
        # as the ordering barrier and the diarization close is observable on the
        # engine.
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(
            socket,
            expect_boundary=False,
        )
        assert boundary is None

    assert completed["type"] == "conversation.item.input_audio_transcription.completed"
    assert diarization.sessions[0].closed is True


def test_openai_realtime_forwards_multiple_snapshot_events_before_final() -> None:
    client, _ = _client(partials=("你", "你好", "你好啊"))
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# Realtime ASR/TTS handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, events = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

    hypotheses = [
        event for event in events
        if event["type"] == "speechrail.transcription.hypothesis"
    ]
    assert [event["text"] for event in hypotheses] == ["你", "你好", "你好啊"]
    assert not any(event["type"].endswith(".delta") for event in events)


def test_realtime_hypothesis_revisions_and_final_share_one_asr_fact_series() -> None:
    client, factory = _client(partials=("你好", "你好啊"), completed_text="你好啊")
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, events = _receive_committed_item(
            socket,
            expected_sample_span=(0, len(_FRAME) // 2),
        )
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

    hypotheses = [
        event
        for event in events
        if event["type"] == "speechrail.transcription.hypothesis"
    ]
    completed = events[-1]
    assert [(event["revision"], event["text"]) for event in hypotheses] == [
        (1, "你好"),
        (2, "你好啊"),
    ]
    assert [event["stable_prefix_codepoints"] for event in hypotheses] == [0, 0]
    assert {event["utterance_id"] for event in hypotheses} == {completed["item_id"]}
    assert hypotheses[-1]["text"] == completed["transcript"]
    assert len(factory.sessions) == 1


def test_realtime_policy_drives_snapshot_preview_and_closes_before_terminal() -> None:
    async def scenario() -> tuple[list[dict[str, object]], FakeStreamingFactory]:
        factory = FakeStreamingFactory(
            flush_partials=("preview one", "preview revised"),
            completed_text="preview revised",
        )
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
            max_realtime_buffer_bytes=128_000,
        )
        services = build_app_services(
            settings,
            AppOverrides(realtime_asr_factory=factory),
        )
        sent: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> int:
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="policy-preview", send=send)
        update = session_update(task="caption")
        update["session"]["speechrail"]["asr"] = {
            "preview_interval_ms": 600,
            "max_segment_ms": 2_000,
            "finalization": "full_segment",
            "final_deadline_ms": 5_000,
        }
        await session._update_session(update)
        for _ in range(2):
            await session._asr_owner.append(
                {"type": "input_audio_buffer.append", "audio": _pcm16(bytes(28_800))}
            )
        await session._asr_owner.commit(reason="client", commit_event_id="policy-close")
        await session.close()
        return sent, factory

    sent, factory = asyncio.run(scenario())
    updated = next(event for event in sent if event["type"] == "session.updated")
    echoed_policy = updated["session"]["speechrail"]["asr"]
    assert echoed_policy == {
        "preview_interval_ms": 600,
        "max_segment_ms": 2_000,
        "finalization": "full_segment",
        "rollback_tokens": 5,
        "final_deadline_ms": 5_000,
        "effective_max_segment_ms": 2_000,
    }

    options = factory.options[0]
    assert options.partial_mode == "snapshot"
    assert options.chunk_duration_ms == 600
    assert options.asr_policy == ASRPolicy(
        preview_interval_ms=600,
        max_segment_ms=2_000,
        finalization="full_segment",
        final_deadline_ms=5_000,
    )
    assert options.effective_max_segment_ms == 2_000

    hypotheses = [
        event for event in sent
        if event["type"] == "speechrail.transcription.hypothesis"
    ]
    assert [event["text"] for event in hypotheses] == ["preview one", "preview revised"]
    assert all(event["stable_prefix_codepoints"] == 0 for event in hypotheses)
    assert not any(
        event["type"] == "conversation.item.input_audio_transcription.delta"
        for event in sent
    )

    boundary = next(
        event for event in sent
        if event["type"] == "speechrail.transcription.segment_closed"
    )
    terminal = next(
        event for event in sent
        if event["type"] == "conversation.item.input_audio_transcription.completed"
    )
    assert boundary["reason"] == "client_commit"
    assert boundary["sample_span"] == {"start": 0, "end": 28_800}
    assert boundary["commit_event_id"] == "policy-close"
    assert sent.index(boundary) < sent.index(terminal)
    assert boundary["item_id"] == terminal["item_id"]


def test_realtime_partial_rewrite_is_delivered_as_replaceable_snapshot() -> None:
    client, _ = _client(partials=("abc", "adc"), completed_text="adc")
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# Realtime ASR/TTS handshake has no conversation.created event
        socket.send_json(
        {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, events = _receive_committed_item(
            socket,
            expected_sample_span=(0, len(_FRAME) // 2),
        )
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

    hypotheses = [
        event for event in events
        if event["type"] == "speechrail.transcription.hypothesis"
    ]
    assert [event["text"] for event in hypotheses] == ["abc", "adc"]
    assert not any(event["type"].endswith(".delta") for event in events)
    assert events[-1]["transcript"] == "adc"


def test_realtime_module_imports_without_audioop(monkeypatch: pytest.MonkeyPatch) -> None:
    import builtins
    import importlib

    native_import = builtins.__import__

    def import_without_audioop(name: str, *args: Any, **kwargs: Any) -> Any:
        if name == "audioop":
            raise ModuleNotFoundError("No module named 'audioop'")
        return native_import(name, *args, **kwargs)

    try:
        with monkeypatch.context() as blocker:
            blocker.setattr(builtins, "__import__", import_without_audioop)
            importlib.reload(realtime_openai_module)
    except ModuleNotFoundError as exc:
        # Restore the importable module object so a RED test does not poison
        # later tests in this process.
        importlib.reload(realtime_openai_module)
        raise AssertionError("Realtime module must not depend on audioop") from exc


def test_realtime_diarization_receives_partitioned_pcm_identically() -> None:
    pcm = b"".join(index.to_bytes(2, "little", signed=True) for index in range(1200))

    def capture(frames: tuple[bytes, ...]) -> bytes:
        engine = FakeDiarizationEngine()
        client, _ = _client(diarization_engine=engine)
        with client.websocket_connect("/v1/realtime") as socket:
            socket.receive_json()
            socket.send_json(
                                session_update(
                    model="gpt-4o-transcribe",
                    language="zh",
                    diarization={"enabled": True},
                )
            )
            assert socket.receive_json()["type"] == "session.updated"
            for frame in frames:
                socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(frame)})
            socket.send_json({"type": "input_audio_buffer.commit"})
            boundary, completed, _ = _receive_committed_item(
                socket,
                expected_sample_span=(0, len(pcm) // 2),
            )
            assert boundary is not None
            assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        return b"".join(engine.sessions[0].received)

    one_frame = capture((pcm,))
    partitioned = capture((pcm[:214], pcm[214:996], pcm[996:]))

    assert partitioned == one_frame
    # The engine sees the 16 kHz kernel stream: 24 kHz wire samples resample to
    # two thirds of their count, so byte length is ``len(pcm) // 3 * 2``.
    assert len(one_frame) == len(pcm) // 3 * 2


def test_realtime_diarization_aligns_frozen_completed_text_without_asr_segments() -> None:
    class RecordingAligner:
        request: AlignmentRequest | None = None

        async def align(self, request: AlignmentRequest) -> AlignmentResult:
            self.request = request
            return AlignmentResult(
                task_id=request.task_id,
                epoch=request.epoch,
                utterance_id=request.utterance_id,
                transcript_revision=request.transcript_revision,
                units=(
                    AlignmentUnit("direct", 0, len(request.text), request.span, "segment"),
                ),
            )

    aligner = RecordingAligner()
    client, _ = _client(
        segments=(TranscriptSegment(id=0, start_ms=0, end_ms=100, text="错误分段"),),
        diarization_engine=FakeDiarizationEngine(),
        text_aligner=aligner,
    )
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
                        session_update(diarization={"enabled": True})
        )
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 800)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(
            socket,
            expected_sample_span=(0, 800),
        )
        assert boundary is not None

        # Auxiliary timing/speaker units never ride on the ASR text final.
        assert "attribution_units" not in completed
        alignment = socket.receive_json()
    assert alignment["type"] == "speechrail.alignment.done"
    assert alignment["utterance_id"] == completed["item_id"]
    assert alignment["units"][0]["timing_quality"] == "aligned"
    assert aligner.request is not None
    assert aligner.request.text == "你好"
    # 1600 wire bytes at 24 kHz resample to the 16 kHz kernel span the aligner
    # receives; the retained PCM must match that span sample-for-sample.
    assert len(aligner.request.pcm16) // 2 == aligner.request.span.length


def test_realtime_text_final_is_sent_before_slow_alignment() -> None:
    release = threading.Event()
    alignment_started = threading.Event()

    class SlowAligner:
        async def align(self, request: AlignmentRequest) -> AlignmentResult:
            alignment_started.set()
            await asyncio.to_thread(release.wait)
            return AlignmentResult(
                task_id=request.task_id,
                epoch=request.epoch,
                utterance_id=request.utterance_id,
                transcript_revision=request.transcript_revision,
                units=(
                    AlignmentUnit("slow", 0, len(request.text), request.span, "segment"),
                ),
            )

    client, _ = _client(
        diarization_engine=FakeDiarizationEngine(),
        text_aligner=SlowAligner(),
    )
    try:
        with client.websocket_connect("/v1/realtime") as socket:
            socket.receive_json()
            socket.send_json(
                                session_update(diarization={"enabled": True})
            )
            assert socket.receive_json()["type"] == "session.updated"
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 800)}
            )
            socket.send_json({"type": "input_audio_buffer.commit"})
            boundary, completed, _ = _receive_committed_item(
                socket,
                expected_sample_span=(0, 800),
            )
            assert boundary is not None

            assert completed["transcript"] == "你好"
            assert "attribution_units" not in completed
            assert alignment_started.wait(1.0)
            assert not release.is_set()
            release.set()
            alignment = socket.receive_json()
            assert alignment["type"] == "speechrail.alignment.done"
            assert alignment["units"][0]["timing_quality"] == "aligned"
    finally:
        release.set()


def test_realtime_alignment_opt_in_without_aligner_fails_closed() -> None:
    """Accepting alignment must not echo readiness the profile cannot back."""

    async def scenario() -> None:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(realtime_asr_factory=FakeStreamingFactory()),
        )

        async def send(_event: dict[str, object]) -> int:
            return 0

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_alignment_missing",
            send=send,
        )
        await session.start()
        try:
            with pytest.raises(RealtimeAdapterError, match="alignment"):
                await session.handle(session_update(alignment={"enabled": True}))
        finally:
            await session.close()

    asyncio.run(scenario())


def test_rejected_session_update_does_not_partially_enable_alignment() -> None:
    """Validation must not publish a flag before the whole update is accepted."""

    async def scenario() -> OpenAIRealtimeSession:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(),
                text_aligner=FakeTextAligner(),
            ),
        )

        async def send(_event: dict[str, object]) -> int:
            return 0

        session = OpenAIRealtimeSession(
            services, session_id="atomic-update", send=send
        )
        await session.start()
        before = dict(session._config)
        with pytest.raises(RealtimeAdapterError) as raised:
            await session.handle(
                session_update(
                    alignment={"enabled": True},
                    expected_asr_revision="stale-revision",
                )
            )
        assert raised.value.code == "model_revision_conflict"
        assert session._auxiliary_owner._alignment_enabled is False
        assert session._config == before
        await session.close()
        return session

    asyncio.run(scenario())


def test_realtime_alignment_runs_without_diarization() -> None:
    async def scenario() -> list[dict[str, object]]:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(),
                text_aligner=FakeTextAligner(),
            ),
        )
        events: list[dict[str, object]] = []
        alignment_done = asyncio.Event()

        async def send(event: dict[str, object]) -> int:
            events.append(event)
            if event.get("type") == "speechrail.alignment.done":
                alignment_done.set()
            return len(events)

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_alignment_only",
            send=send,
        )
        await session.start()
        await session.handle(session_update(alignment={"enabled": True}))
        await session.handle(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        await session.handle(
            {"type": "input_audio_buffer.commit", "event_id": "align-only-commit"}
        )
        await asyncio.wait_for(alignment_done.wait(), timeout=0.5)
        await session.close()
        return events

    events = asyncio.run(scenario())
    completed = next(
        event
        for event in events
        if event["type"] == "conversation.item.input_audio_transcription.completed"
    )
    alignment = next(
        event for event in events if event["type"] == "speechrail.alignment.done"
    )
    assert completed["commit_event_id"] == "align-only-commit"
    assert alignment["utterance_id"] == completed["item_id"]
    assert alignment["units"][0]["timing_quality"] == "aligned"


def test_alignment_result_survives_the_turn_moving_on() -> None:
    """A late aligner result must still reach the client, tagged with its own ids.

    Commit cleanup advances the item id and zeroes the turn's transcript
    revision as soon as the text final is sent, and the alignment task is
    scheduled around that same moment -- so on a real service it routinely
    *starts* after the turn has already moved on.  Measured on 3.5.2 every
    result was dropped that way and the client received neither
    `alignment.done` nor `alignment.failed`, leaving it waiting forever.

    The event carries `utterance_id` and `transcript_revision`, so a late
    result is still attributable and has to be delivered; what it must not do
    is advance the *next* turn's bookkeeping.
    """

    async def scenario() -> tuple[list[dict[str, object]], str]:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(),
                text_aligner=FakeTextAligner(),
            ),
        )
        events: list[dict[str, object]] = []
        alignment_done = asyncio.Event()

        async def send(event: dict[str, object]) -> int:
            events.append(event)
            if event.get("type") == "speechrail.alignment.done":
                alignment_done.set()
            return len(events)

        session = OpenAIRealtimeSession(
            services, session_id="realtime_late_alignment", send=send
        )
        await session.start()
        await session.handle(session_update(alignment={"enabled": True}))
        pcm = _pcm16(_FRAME)
        await session.handle({"type": "input_audio_buffer.append", "audio": pcm})
        await session.handle(
            {"type": "input_audio_buffer.commit", "event_id": "late-commit"}
        )
        await asyncio.wait_for(alignment_done.wait(), timeout=0.5)
        completed = next(
            event
            for event in events
            if event["type"]
            == "conversation.item.input_audio_transcription.completed"
        )
        item_id = str(completed["item_id"])
        transcript = str(completed["transcript"])

        # Reproduce what commit cleanup does to the turn an already-scheduled
        # alignment task is about to look at.
        session._asr_owner._reset_turn_observability()
        session._asr_owner._current_item_id = session._asr_owner._new_item_id()
        assert session._asr_owner._current_item_id != item_id

        events.clear()
        await session._auxiliary_owner._finish_alignment(
            task_id=session._asr_owner._task_id,
            epoch=session._asr_owner._wire_epoch,
            generation=session._asr_owner._asr_generation,
            item_id=item_id,
            transcript=transcript,
            transcript_revision=1,
            item_start_wire=0,
            item_end_wire=len(pcm) // 2,
            item_start_kernel=0,
            item_end_kernel=len(pcm) // 2,
            pcm16=pcm,
            overflow=False,
            degraded_reason=None,
        )
        await session.close()
        return events, item_id

    events, item_id = asyncio.run(scenario())
    terminal = [
        event
        for event in events
        if event["type"]
        in ("speechrail.alignment.done", "speechrail.alignment.failed")
    ]
    assert terminal, "a late alignment result must still be delivered"
    assert terminal[0]["type"] == "speechrail.alignment.done"
    assert terminal[0]["utterance_id"] == item_id


def test_late_alignment_registers_units_to_its_original_item() -> None:
    async def scenario() -> tuple[
        list[dict[str, object]],
        list[str],
        tuple[str, int],
        tuple[str, int],
    ]:
        first_alignment_started = asyncio.Event()
        release_first_alignment = asyncio.Event()
        alignment_arrived = asyncio.Event()
        registration_items: list[str] = []

        class BlockingFirstAligner:
            calls = 0

            async def align(self, request: AlignmentRequest) -> AlignmentResult:
                self.calls += 1
                if self.calls == 1:
                    first_alignment_started.set()
                    await release_first_alignment.wait()
                return AlignmentResult(
                    task_id=request.task_id,
                    epoch=request.epoch,
                    utterance_id=request.utterance_id,
                    transcript_revision=request.transcript_revision,
                    units=(
                        AlignmentUnit(
                            f"unit-{request.utterance_id}",
                            0,
                            len(request.text),
                            request.span,
                            "segment",
                        ),
                    ),
                )

        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(),
                diarization_engine=FakeDiarizationEngine(),
                text_aligner=BlockingFirstAligner(),
            ),
        )
        events: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> int:
            events.append(event)
            if event.get("type") == "speechrail.alignment.done":
                alignment_arrived.set()
            return len(events)

        session = OpenAIRealtimeSession(services, session_id="late-item-register", send=send)
        register_units = session._auxiliary_owner._register_units

        async def record_units(item_id, units) -> None:
            registration_items.append(item_id)
            await register_units(item_id, units)

        session._auxiliary_owner._register_units = record_units
        await session.start()
        await session.handle(session_update(diarization={"enabled": True}))
        audio = _pcm16(b"\x00\x00" * 800)

        async def commit_item(commit_id: str) -> str:
            await session.handle(
                {"type": "input_audio_buffer.append", "audio": audio}
            )
            await session.handle(
                {"type": "input_audio_buffer.commit", "event_id": commit_id}
            )
            terminals = [
                event for event in events
                if event["type"]
                == "conversation.item.input_audio_transcription.completed"
            ]
            return str(terminals[-1]["item_id"])

        first_item = await commit_item("late-item-1")
        await asyncio.wait_for(first_alignment_started.wait(), timeout=0.5)
        second_item = await commit_item("late-item-2")
        assert first_item != second_item
        current_state_before_late_alignment = (
            session._asr_owner._current_item_id,
            session._asr_owner._current_transcript_revision,
        )

        while not any(
            event.get("utterance_id") == second_item
            for event in events
            if event["type"] == "speechrail.alignment.done"
        ):
            alignment_arrived.clear()
            if any(
                event.get("utterance_id") == second_item
                for event in events
                if event["type"] == "speechrail.alignment.done"
            ):
                break
            await asyncio.wait_for(alignment_arrived.wait(), timeout=0.5)

        assert not any(
            event.get("utterance_id") == first_item
            for event in events
            if event["type"] == "speechrail.alignment.done"
        )
        release_first_alignment.set()
        while not any(
            event.get("utterance_id") == first_item
            for event in events
            if event["type"] == "speechrail.alignment.done"
        ):
            alignment_arrived.clear()
            if any(
                event.get("utterance_id") == first_item
                for event in events
                if event["type"] == "speechrail.alignment.done"
            ):
                break
            await asyncio.wait_for(alignment_arrived.wait(), timeout=0.5)

        await session._auxiliary_owner._wait_for_pending_alignment()
        current_state_after_late_alignment = (
            session._asr_owner._current_item_id,
            session._asr_owner._current_transcript_revision,
        )
        await session.handle(
            {
                "type": "speechrail.diarization.finish",
                "event_id": "late-item-finish",
            }
        )
        await session.close()
        return (
            events,
            registration_items,
            current_state_before_late_alignment,
            current_state_after_late_alignment,
        )

    (
        events,
        registration_items,
        current_state_before_late_alignment,
        current_state_after_late_alignment,
    ) = asyncio.run(scenario())
    completed = [
        event for event in events
        if event["type"] == "conversation.item.input_audio_transcription.completed"
    ]
    aligned_items = {
        str(event["utterance_id"])
        for event in events
        if event["type"] == "speechrail.alignment.done"
    }
    done = next(
        event for event in events if event["type"] == "speechrail.diarization.done"
    )
    assert len(completed) == 2
    assert aligned_items == {str(event["item_id"]) for event in completed}
    assert set(registration_items) == aligned_items
    assert len(done["units"]) == 2
    assert current_state_after_late_alignment == current_state_before_late_alignment


def test_clear_discards_an_alignment_result_that_returns_late() -> None:
    async def scenario() -> tuple[list[dict[str, object]], list[str], str, str]:
        first_alignment_started = asyncio.Event()
        first_alignment_cancelled = asyncio.Event()
        release_cancelled_alignment = asyncio.Event()
        alignment_arrived = asyncio.Event()
        registration_items: list[str] = []

        class CancellationResistantFirstAligner:
            calls = 0

            async def align(self, request: AlignmentRequest) -> AlignmentResult:
                self.calls += 1
                if self.calls == 1:
                    first_alignment_started.set()
                    try:
                        await release_cancelled_alignment.wait()
                    except asyncio.CancelledError:
                        first_alignment_cancelled.set()
                        # Emulate a vendor worker that returns after cancellation.
                        await release_cancelled_alignment.wait()
                return AlignmentResult(
                    task_id=request.task_id,
                    epoch=request.epoch,
                    utterance_id=request.utterance_id,
                    transcript_revision=request.transcript_revision,
                    units=(
                        AlignmentUnit(
                            f"unit-{request.utterance_id}",
                            0,
                            len(request.text),
                            request.span,
                            "segment",
                        ),
                    ),
                )

        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(),
                diarization_engine=FakeDiarizationEngine(),
                text_aligner=CancellationResistantFirstAligner(),
            ),
        )
        events: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> int:
            events.append(event)
            if event.get("type") == "speechrail.alignment.done":
                alignment_arrived.set()
            return len(events)

        session = OpenAIRealtimeSession(services, session_id="clear-late-alignment", send=send)
        register_units = session._auxiliary_owner._register_units

        async def record_units(item_id, units) -> None:
            registration_items.append(item_id)
            await register_units(item_id, units)

        session._auxiliary_owner._register_units = record_units
        await session.start()
        await session.handle(session_update(diarization={"enabled": True}))
        audio = _pcm16(b"\x00\x00" * 800)

        async def commit_item(commit_id: str) -> str:
            await session.handle(
                {"type": "input_audio_buffer.append", "audio": audio}
            )
            await session.handle(
                {"type": "input_audio_buffer.commit", "event_id": commit_id}
            )
            terminals = [
                event for event in events
                if event["type"]
                == "conversation.item.input_audio_transcription.completed"
            ]
            return str(terminals[-1]["item_id"])

        cleared_item = await commit_item("clear-cancelled-item")
        await asyncio.wait_for(first_alignment_started.wait(), timeout=0.5)
        clear = asyncio.create_task(
            session.handle({"type": "input_audio_buffer.clear"})
        )
        await asyncio.wait_for(first_alignment_cancelled.wait(), timeout=0.5)
        release_cancelled_alignment.set()
        await asyncio.wait_for(clear, timeout=0.5)
        assert not any(
            event.get("utterance_id") == cleared_item
            and event["type"] in {
                "speechrail.alignment.done",
                "speechrail.alignment.failed",
            }
            for event in events
        )
        assert cleared_item not in registration_items
        assert session._auxiliary_owner._units_by_id == {}

        current_item = await commit_item("clear-current-item")
        while not any(
            event.get("utterance_id") == current_item
            for event in events
            if event["type"] == "speechrail.alignment.done"
        ):
            alignment_arrived.clear()
            if any(
                event.get("utterance_id") == current_item
                for event in events
                if event["type"] == "speechrail.alignment.done"
            ):
                break
            await asyncio.wait_for(alignment_arrived.wait(), timeout=0.5)
        await session._auxiliary_owner._wait_for_pending_alignment()
        await session.close()
        return events, registration_items, cleared_item, current_item

    events, registration_items, cleared_item, current_item = asyncio.run(scenario())
    alignment_events = [
        event for event in events
        if event["type"] in {
            "speechrail.alignment.done",
            "speechrail.alignment.failed",
        }
    ]
    assert not any(event["utterance_id"] == cleared_item for event in alignment_events)
    assert [event["utterance_id"] for event in alignment_events] == [current_item]
    assert registration_items == [current_item]
    assert f"unit-{current_item}" != f"unit-{cleared_item}"


def test_realtime_diarization_finish_waits_for_pending_alignment() -> None:
    async def scenario() -> list[dict[str, object]]:
        release = asyncio.Event()
        alignment_registered = asyncio.Event()

        class BlockingAligner:
            async def align(self, request: AlignmentRequest) -> AlignmentResult:
                await release.wait()
                alignment_registered.set()
                return AlignmentResult(
                    task_id=request.task_id,
                    epoch=request.epoch,
                    utterance_id=request.utterance_id,
                    transcript_revision=request.transcript_revision,
                    units=(
                        AlignmentUnit(
                            "blocked", 0, len(request.text), request.span, "segment"
                        ),
                    ),
                )

        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(),
                diarization_engine=FakeDiarizationEngine(),
                text_aligner=BlockingAligner(),
            ),
        )
        events: list[dict[str, object]] = []
        diarization_done = asyncio.Event()

        async def send(event: dict[str, object]) -> int:
            events.append(event)
            if event.get("type") == "speechrail.diarization.done":
                diarization_done.set()
            return len(events)

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_finish_alignment",
            send=send,
        )
        await session.start()
        await session.handle(session_update(diarization={"enabled": True}))
        await session.handle(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        await session.handle({"type": "input_audio_buffer.commit"})
        finish = asyncio.create_task(
            session.handle(
                {
                    "type": "speechrail.diarization.finish",
                    "event_id": "finish-after-alignment",
                }
            )
        )
        await asyncio.sleep(0.02)
        assert not diarization_done.is_set()
        release.set()
        await asyncio.wait_for(alignment_registered.wait(), timeout=0.5)
        await asyncio.wait_for(finish, timeout=0.5)
        assert diarization_done.is_set()
        await session.close()
        return events

    events = asyncio.run(scenario())
    order = [
        event["type"]
        for event in events
        if event["type"]
        in {
            "speechrail.alignment.done",
            "speechrail.diarization.done",
        }
    ]
    assert order == ["speechrail.alignment.done", "speechrail.diarization.done"]


def test_realtime_diarization_finish_degrades_when_alignment_never_returns() -> None:
    """Waiting for frozen text is bounded: a stuck aligner degrades, not hangs."""

    async def scenario() -> list[dict[str, object]]:
        release = asyncio.Event()

        class HangingAligner:
            async def align(self, request: AlignmentRequest) -> AlignmentResult:
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    raise
                raise AssertionError("a cancelled aligner must not return a result")

        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
            realtime_diarization_drain_deadline_seconds=0.2,
        )
        services = build_app_services(
            settings,
            AppOverrides(
                realtime_asr_factory=FakeStreamingFactory(),
                diarization_engine=FakeDiarizationEngine(),
                text_aligner=HangingAligner(),
            ),
        )
        events: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> int:
            events.append(event)
            return len(events)

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_finish_alignment_hang",
            send=send,
        )
        await session.start()
        try:
            await session.handle(session_update(diarization={"enabled": True}))
            await session.handle(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
            )
            await session.handle({"type": "input_audio_buffer.commit"})
            await asyncio.wait_for(
                session.handle(
                    {
                        "type": "speechrail.diarization.finish",
                        "event_id": "finish-hanging-alignment",
                    }
                ),
                timeout=2.0,
            )
        finally:
            release.set()
            await session.close()
        return events

    events = asyncio.run(scenario())
    failed = next(
        event
        for event in events
        if event["type"] == "speechrail.diarization.failed"
    )
    assert failed["error"]["code"] == "finalization_timeout"
    assert not any(
        event["type"] == "speechrail.diarization.done" for event in events
    ), "a degraded finalization must not also report done"


def test_realtime_alignment_failure_does_not_rewrite_text_final() -> None:
    class FailingAligner:
        async def align(self, request: AlignmentRequest) -> AlignmentResult:
            return AlignmentResult(
                task_id=request.task_id,
                epoch=request.epoch,
                utterance_id=request.utterance_id,
                transcript_revision=request.transcript_revision,
                units=(),
                failure="text_mismatch",
            )

    client, _ = _client(
        diarization_engine=FakeDiarizationEngine(),
        text_aligner=FailingAligner(),
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
                        session_update(diarization={"enabled": True})
        )
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 800)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(
            socket,
            expected_sample_span=(0, 800),
        )
        assert boundary is not None
        assert completed["transcript"] == "你好"
        failed = socket.receive_json()

    assert failed["type"] == "speechrail.alignment.failed"
    assert failed["utterance_id"] == completed["item_id"]
    assert failed["error"]["code"] == "text_mismatch"


def test_regular_realtime_transcription_never_calls_the_fixed_text_aligner() -> None:
    class CountingAligner:
        calls = 0

        async def align(self, request: AlignmentRequest) -> AlignmentResult:
            self.calls += 1
            return AlignmentResult(
                task_id=request.task_id,
                epoch=request.epoch,
                utterance_id=request.utterance_id,
                transcript_revision=request.transcript_revision,
                units=(
                    AlignmentUnit("unexpected", 0, len(request.text), request.span, "segment"),
                ),
            )

    aligner = CountingAligner()
    client, _ = _client(
        diarization_engine=FakeDiarizationEngine(), text_aligner=aligner
    )
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 800)})
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(
            socket,
            expected_sample_span=(0, 800),
        )
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

    assert aligner.calls == 0


def test_openai_session_update_rejects_non_string_language_hints() -> None:
    with pytest.raises(RealtimeAdapterError, match="languages must be a string array"):
        apply_session_update(
            session_update(languages=["zh", 1]),  # type: ignore[list-item]
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )


def test_openai_session_update_rejects_per_session_alignment_precision() -> None:
    """Precision is a profile-level model property, not a session knob."""
    with pytest.raises(RealtimeAdapterError, match="unsupported shape"):
        apply_session_update(
            session_update(alignment={"enabled": True, "precision": "q8"}),  # type: ignore[typeddict-unknown-key]
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )


def test_openai_session_update_rejects_invalid_timestamp_granularity() -> None:
    with pytest.raises(RealtimeAdapterError, match="timestamp_granularities"):
        apply_session_update(
            session_update(timestamp_granularities=["phoneme"]),
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )


def test_openai_session_update_rejects_invalid_diarization_config() -> None:
    with pytest.raises(
        RealtimeAdapterError, match=r"unsupported audio\.input\.transcription field: diarization"
    ):
        apply_session_update(
            session_update(
                extra_transcription={
                    "diarization": {"enabled": True, "speaker_count_hint": 9},
                }
            ),
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )


def test_openai_realtime_rejects_invalid_api_key_at_handshake() -> None:
    client, _ = _client(api_key="secret")
    with pytest.raises(WebSocketDisconnect), client.websocket_connect("/v1/realtime"):
        pass


def test_openai_realtime_rejects_when_no_backend_is_ready() -> None:
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
    )
    services = build_app_services(settings, AppOverrides())
    app = FastAPI()
    app.include_router(create_openai_realtime_router(services))

    with pytest.raises(WebSocketDisconnect), TestClient(app).websocket_connect("/v1/realtime"):
        pass


def test_openai_realtime_rejects_tts_when_backend_is_not_ready() -> None:
    factory = FakeStreamingFactory()
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
    )
    services = build_app_services(
        settings,
        AppOverrides(batch_transcriber=FakeTranscriber(), realtime_asr_factory=factory),
    )
    app = FastAPI()
    app.include_router(create_openai_realtime_router(services))

    with TestClient(app).websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(tts={"enabled": True})
        )
        error = socket.receive_json()

    assert error["error"]["code"] == "backend_not_ready"


class _DelayedAppendSession(FakeStreamingSession):
    """Makes the data lane observably slow without blocking TTS cancellation forever."""

    def __init__(self, **kwargs: object) -> None:
        super().__init__(**kwargs)
        self.append_started = False
        self.append_completed = False

    async def append_audio(self, audio: bytes) -> None:
        self.append_started = True
        await asyncio.sleep(0.05)
        await super().append_audio(audio)
        self.append_completed = True


class DelayedAppendStreamingFactory(FakeStreamingFactory):
    def session_class(self) -> type[_DelayedAppendSession]:
        return _DelayedAppendSession


class _BlockingAppendSession(FakeStreamingSession):
    """Hold the first append so a queued second append cannot dispatch."""

    def __init__(
        self,
        *,
        started: threading.Event | None = None,
        release: threading.Event | None = None,
        **kwargs: object,
    ):
        super().__init__(**kwargs)
        self._started = started or threading.Event()
        self._release = release or threading.Event()

    async def append_audio(self, audio: bytes) -> None:
        self._started.set()
        await asyncio.to_thread(self._release.wait, 1.0)
        await super().append_audio(audio)


class BlockingAppendStreamingFactory(FakeStreamingFactory):
    def __init__(self) -> None:
        super().__init__()
        self.append_started = threading.Event()
        self.append_release = threading.Event()

    def session_class(self) -> type[_BlockingAppendSession]:
        return _BlockingAppendSession

    def create(self, **kwargs: Any) -> FakeStreamingSession:
        session = super().create(**kwargs)
        assert isinstance(session, _BlockingAppendSession)
        session._started = self.append_started
        session._release = self.append_release
        return session


def test_tts_cancel_bypasses_two_queued_audio_appends() -> None:
    """A queued microphone append must not delay the control lane that
    releases the TTS resource the first append is waiting for."""

    factory = BlockingAppendStreamingFactory()
    client, _ = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(session_update(model="whisper-1", tts={"enabled": True}))
        socket.receive_json()
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        assert factory.append_started.wait(1.0)
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        socket.send_json(tts_cancel(request_id="missing"))

        executor = ThreadPoolExecutor(max_workers=1)
        try:
            pending = executor.submit(socket.receive_json)
            event = pending.result(timeout=0.5)
            assert factory.append_release.is_set() is False
        finally:
            factory.append_release.set()
            executor.shutdown(wait=True, cancel_futures=True)
    assert event["type"] == "error"
    assert event["error"]["code"] == "tts_not_active"


def test_openai_query_model_echoed_in_session_created() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime?model=whisper-1") as socket:
        created = socket.receive_json()
        assert created["type"] == "session.created"
        # The model echo lives under audio.input.transcription, not the retired
        # root-level ``session.model``.  ``whisper-1`` is an accepted
        # compatibility id, so it is echoed verbatim.
        assert (
            created["session"]["audio"]["input"]["transcription"]["model"] == "whisper-1"
        )
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
    assert len(factory.sessions) == 1


def test_openai_query_model_unknown_rejected_with_error_then_close_4004() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime?model=does-not-exist-xyz") as socket:
        event = socket.receive_json()
        assert event["type"] == "error"
        assert event["error"]["code"] == "model_not_found"
        with pytest.raises(WebSocketDisconnect) as excinfo:
            socket.receive_json()
    assert excinfo.value.code == 4004
    assert factory.sessions == []


def test_openai_query_tts_model_is_rejected_before_session_creation() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime?model=tts-1") as socket:
        event = socket.receive_json()
        assert event["type"] == "error"
        assert event["error"]["code"] == "model_not_found"
        with pytest.raises(WebSocketDisconnect) as excinfo:
            socket.receive_json()
    assert excinfo.value.code == 4004
    assert factory.sessions == []


def test_openai_query_diarize_alias_requires_ready_profile() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime?model=gpt-4o-transcribe-diarize") as socket:
        event = socket.receive_json()
        assert event["type"] == "error"
        assert event["error"]["code"] == "model_not_found"
        with pytest.raises(WebSocketDisconnect):
            socket.receive_json()


def test_openai_query_diarize_alias_accepted_when_profile_ready() -> None:
    client, _ = _client(diarization_engine=FakeDiarizationEngine())
    with client.websocket_connect("/v1/realtime?model=gpt-4o-transcribe-diarize") as socket:
        created = socket.receive_json()
    assert created["type"] == "session.created"
    assert (
        created["session"]["audio"]["input"]["transcription"]["model"]
        == "speechrail/qwen3-asr-1.7b"
    )


def test_openai_error_event_correlates_client_event_id() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json({"type": "definitely-unknown", "event_id": "evt_client_42"})
        error = socket.receive_json()
    assert error["type"] == "error"
    assert error["error"]["code"] == "unsupported_operation"
    assert error["error"]["event_id"] == "evt_client_42"
    assert error["event_id"] != "evt_client_42"
    assert error["event_id"].startswith("event_")


def test_openai_unsupported_language_emits_one_failed_terminal_and_recovers() -> None:
    factory = RejectingLanguageStreamingFactory()
    client, _ = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(session_update(language="xx-qq"))
        socket.receive_json()
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        failure_boundary, failed, failure_events = _receive_committed_item(
            socket,
            expect_boundary=False,
        )
        assert failure_boundary is None
        assert failed["type"] == "conversation.item.input_audio_transcription.failed"
        assert failed["error"]["code"] == "language_not_supported"
        failed_item_id = failed["item_id"]

        socket.send_json(session_update(language="zh"))
        updated = socket.receive_json()
        assert updated["type"] == "session.updated"
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, recovery_events = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert completed["item_id"] != failed_item_id
        terminals_for_failed_item = [
            event
            for event in [*failure_events, *recovery_events]
            if event.get("item_id") == failed_item_id
            and event["type"]
            in {
                "conversation.item.input_audio_transcription.completed",
                "conversation.item.input_audio_transcription.failed",
            }
        ]
        assert terminals_for_failed_item == [failed]
    assert len(factory.sessions) == 1


def test_openai_transcription_prompt_forwarded_to_streaming_session() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
                        session_update(prompt="医疗术语")
        )
        socket.receive_json()  # session.updated
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(socket)
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
    assert factory.sessions[0].prompt == "医疗术语"


def test_openai_rejects_oversized_transcription_prompt() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
                        session_update(prompt="x" * 2001)
        )
        error = socket.receive_json()
    assert error["type"] == "error"
    assert error["error"]["code"] == "prompt_too_long"


class RecordingSpeechSynthesizer:
    def __init__(self, *, runtime_revision: str | None = None) -> None:
        self.requests: list[SpeechRequest] = []
        self.runtime_revision = runtime_revision

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        del voice
        return self.runtime_revision

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id="internal", chunk_index=0, audio=b"\x00\x00")

        return chunks()


def _drive_tts(
    socket: object, response_body: dict[str, object] | None = None
) -> list[dict[str, object]]:
    socket.send_json(  # type: ignore[attr-defined]
        session_update(tts={"enabled": True})
    )
    socket.receive_json()  # type: ignore[attr-defined] session.updated
    request_id = f"tts_test_{time.monotonic_ns()}"
    overrides = dict(response_body or {})
    overrides.pop("type", None)
    overrides.pop("text", None)
    text = str((response_body or {}).get("text") or "你好")
    socket.send_json(  # type: ignore[attr-defined]
        tts_start(request_id=request_id, **overrides)
    )
    socket.send_json(  # type: ignore[attr-defined]
        tts_append_text(request_id=request_id, sequence=0, text=text)
    )
    socket.send_json(  # type: ignore[attr-defined]
        tts_finish_text(request_id=request_id, last_sequence=0)
    )
    events: list[dict[str, object]] = []
    while True:
        event = socket.receive_json()  # type: ignore[attr-defined]
        events.append(event)
        if event["type"] in {
            "speechrail.tts.completed",
            "speechrail.tts.cancelled",
            "speechrail.tts.failed",
            "error",
        }:
            return events


def _quality_model_settings() -> tuple[dict[str, Any], str]:
    catalog = load_catalog()
    asr_key = required_spec_artifact("quality", "asr")
    tts_key = required_spec_artifact("quality", "tts_custom_voice")
    base_key = required_spec_artifact("quality", "tts_base")
    assert asr_key is not None and tts_key is not None and base_key is not None
    artifact = next(item for item in catalog.artifacts if item.key == tts_key)
    return (
        {
            "qwen3_model_dir": Path(asr_key),
            "qwen3_tts_model_dir": Path(tts_key),
            "qwen3_tts_clone_model_dir": Path(base_key),
            "selection_schema_version": 2,
            "selection_asr_spec": "quality",
            "selection_tts_spec": "quality",
            "asr_artifact_key": asr_key,
            "tts_artifact_key": tts_key,
            "tts_base_artifact_key": base_key,
        },
        artifact.revision,
    )


@pytest.mark.parametrize(
    "model_revision",
    ["", 42, {"expected": "A" * 40}, "0" * 129],
)
def test_realtime_model_revision_pin_rejects_invalid_shape(model_revision: object) -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(session_update(expected_asr_revision=model_revision))
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "invalid_event"


def test_realtime_connect_failure_releases_factory_slot_and_recovers() -> None:
    class ConnectFailureSession(FakeStreamingSession):
        async def connect(self) -> None:
            raise RuntimeError("worker_unavailable")

    class FlakyConnectFactory(FakeStreamingFactory):
        def __init__(self) -> None:
            super().__init__()
            self.attempts = 0

        def session_class(self) -> type[FakeStreamingSession]:
            self.attempts += 1
            return ConnectFailureSession if self.attempts == 1 else FakeStreamingSession

    factory = FlakyConnectFactory()
    client, _ = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
        # Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        failure_boundary, failed, failure_events = _receive_committed_item(
            socket,
            expect_boundary=False,
        )
        assert failure_boundary is None
        assert failed["type"] == "conversation.item.input_audio_transcription.failed"
        assert failed["error"]["code"] == "backend_error"
        failed_item_id = failed["item_id"]
        assert factory.released == [factory.sessions[0]]
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, recovery_events = _receive_committed_item(
            socket,
            expected_sample_span=(80, 160),
        )
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert completed["item_id"] != failed_item_id
        terminals_for_failed_item = [
            event
            for event in [*failure_events, *recovery_events]
            if event.get("item_id") == failed_item_id
            and event["type"]
            in {
                "conversation.item.input_audio_transcription.completed",
                "conversation.item.input_audio_transcription.failed",
            }
        ]
        assert terminals_for_failed_item == [failed]


def test_realtime_session_update_error_message_truncates_client_model() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
                        session_update(model="x" * 5000)
        )
        error = socket.receive_json()
    assert error["error"]["code"] == "model_not_found"
    assert len(error["error"]["message"]) < 300


def test_realtime_prompt_exactly_at_limit_forwards_to_session() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
                        session_update(prompt="p" * 2000)
        )
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, _ = _receive_committed_item(
            socket,
            expected_sample_span=(0, 80),
        )
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
    assert factory.sessions[0].prompt == "p" * 2000


def test_realtime_current_audio_profile_emits_one_current_wire_family() -> None:
    from test_realtime_tts_incremental import FakeIncrementalSynthesizer, _tier_kwargs

    client, _ = _client(
        tts_synthesizer=FakeIncrementalSynthesizer(),
        settings_kwargs={
            key: value
            for key, value in _tier_kwargs().items()
            if key not in {"qwen3_python", "qwen3_tts_python"}
        },
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        events = [event["type"] for event in _drive_tts(socket)]

    assert "speechrail.tts.audio.delta" in events
    assert "speechrail.tts.completed" in events
    assert "response.audio.delta" not in events
    assert "response.audio.done" not in events


def test_realtime_snapshot_preview_driven_by_policy_interval() -> None:
    """The configured preview interval drives replaceable ASR snapshots."""
    client, factory = _client(
        flush_partials=("Hello", "Hello world"),
        settings_kwargs={"max_realtime_buffer_bytes": 128_000},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# Realtime ASR/TTS handshake has no conversation.created event
# Realtime ASR/TTS handshake has no conversation.created event
        update = session_update()
        update["session"]["speechrail"]["asr"] = {
            "preview_interval_ms": 500,
            "max_segment_ms": 2_000,
            "finalization": "full_segment",
        }
        socket.send_json(update)
        configured = socket.receive_json()
        assert configured["type"] == "session.updated"
        assert configured["session"]["speechrail"]["asr"]["preview_interval_ms"] == 500

        # Each 32,000-byte wire append exceeds the 500 ms preview interval.
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 32_000)}
        )
        hypothesis1 = socket.receive_json()
        assert hypothesis1["type"] == "speechrail.transcription.hypothesis"
        assert hypothesis1["text"] == "Hello"

        # A second append advances the latest full snapshot.
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 32_000)}
        )
        hypothesis2 = socket.receive_json()
        assert hypothesis2["type"] == "speechrail.transcription.hypothesis"
        assert hypothesis2["text"] == "Hello world"

        assert factory.sessions[0].flushes == 2

        # Final commit completes cleanly
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, completed, commit_events = _receive_committed_item(
            socket,
            expected_sample_span=(0, 32_000),
        )
        assert boundary is not None
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert commit_events[0] == boundary
        assert commit_events[-1] == completed
        assert not any(
            event["type"] == "conversation.item.input_audio_transcription.delta"
            for event in commit_events
        )


def test_realtime_segment_budget_rolls_over_before_client_commit() -> None:
    """A valid one-second budget rolls over without losing boundary or final."""
    async def scenario() -> tuple[list[dict[str, object]], FakeStreamingFactory]:
        factory = FakeStreamingFactory()
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
            max_realtime_buffer_bytes=128_000,
        )
        services = build_app_services(
            settings,
            AppOverrides(realtime_asr_factory=factory),
        )
        sent: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> int:
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="budget-rollover", send=send)
        update = session_update()
        update["session"]["speechrail"]["asr"] = {
            "preview_interval_ms": 1_000,
            "max_segment_ms": 1_000,
            "finalization": "full_segment",
        }
        await session._update_session(update)
        # Seven 8,192-byte wire frames cross the caller-selected 1,000 ms
        # segment budget while each input frame remains below the frame limit.
        for _ in range(7):
            await session._asr_owner.append(
                {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 8192)}
            )
        await session._asr_owner.commit("client", commit_event_id="rollover-tail")
        await session.close()
        return sent, factory

    events, factory = asyncio.run(scenario())
    boundaries = [
        event for event in events
        if event["type"] == "speechrail.transcription.segment_closed"
    ]
    terminals = [
        event for event in events
        if event["type"] == "conversation.item.input_audio_transcription.completed"
    ]
    assert len(boundaries) == len(terminals) == 2
    assert [event["reason"] for event in boundaries] == [
        "budget_rollover",
        "client_commit",
    ]
    assert "commit_event_id" not in boundaries[0]
    assert "commit_event_id" not in terminals[0]
    assert boundaries[1]["commit_event_id"] == "rollover-tail"
    assert terminals[1]["commit_event_id"] == "rollover-tail"
    for boundary in boundaries:
        terminal = next(
            event for event in terminals if event["item_id"] == boundary["item_id"]
        )
        assert events.index(boundary) < events.index(terminal)
    assert terminals[0]["item_id"] != terminals[1]["item_id"]
    assert len(factory.sessions) == 2


def test_realtime_single_frame_exceeds_max_buffer_bytes() -> None:
    """Verifies single frame exceeding buffer limit is rejected with buffer_too_large."""
    client, _ = _client(
        settings_kwargs={
            "max_realtime_buffer_bytes": 64_000,
            "max_realtime_frame_bytes": 128_000,
        }
    )
    with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()

        # The service budget can represent a 1,000 ms segment; a single 70 KB
        # append still exceeds its 64 KB total buffer allowance.
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 70_000)}
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "buffer_too_large"


def test_realtime_transport_byte_budget_closes_before_queue_growth() -> None:
    client, _ = _client(
        settings_kwargs={
            "max_realtime_buffer_bytes": 64_000,
            "max_realtime_frame_bytes": 128,
        }
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 100_000)}
        )
        with pytest.raises(WebSocketDisconnect) as exc_info:
            socket.receive_json()

    assert exc_info.value.code == 1013


def test_realtime_client_disconnect_during_handle_graceful() -> None:
    """Verifies that abrupt client disconnect is handled without uncaught exceptions."""
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
                        session_update(model="whisper-1")
        )
        # Socket closes on exit without error


class _FailingCommitSession(FakeStreamingSession):
    """Fails the factory's first commit like a hung worker, then behaves normally."""

    def __init__(self, *, fail_state: dict[str, bool], **kwargs: object) -> None:
        super().__init__(**kwargs)
        self._fail_state = fail_state

    async def commit(self, want_segments: bool = False) -> None:
        self.want_segments = want_segments
        if not self._fail_state["failed"]:
            self._fail_state["failed"] = True
            raise TimeoutError()
        await super().commit(want_segments=want_segments)


class FailingCommitStreamingFactory(FakeStreamingFactory):
    def __init__(self, **kwargs: object) -> None:
        super().__init__(**kwargs)
        self.fail_state = {"failed": False}

    def create(
        self,
        *,
        language: str | None,
        prompt: str,
        options: RealtimeTranscriptionOptions,
    ) -> _FailingCommitSession:
        session = _FailingCommitSession(
            language=language,
            prompt=prompt,
            segments=self.segments,
            partials=self.partials,
            flush_partials=self.flush_partials,
            fail_state=self.fail_state,
        )
        session.options = options
        self.options.append(options)
        self.sessions.append(session)
        return session


def test_openai_commit_failure_emits_failed_terminal_and_releases_slot() -> None:
    """A failed commit must not leak the streaming slot or the governor lane."""
    factory = FailingCommitStreamingFactory()
    client, factory = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
        # Realtime ASR/TTS handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(session_update(model="whisper-1"))
        socket.receive_json()  # session.updated

        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, event, failure_events = _receive_committed_item(
            socket,
            expected_sample_span=(0, len(_FRAME) // 2),
        )
        assert boundary is not None
        assert event["type"] == "conversation.item.input_audio_transcription.failed"
        assert event["error"]["code"] == "backend_timeout"
        failed_terminal = event
        failed_item_id = event["item_id"]

        assert len(factory.released) == 1

        # The slot is usable again: the next append opens a fresh ASR session
        # and a normal commit round-trips to completion.
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, event, recovery_events = _receive_committed_item(socket)
        assert boundary is not None
        assert event["type"] == "conversation.item.input_audio_transcription.completed"
        assert event["item_id"] != failed_item_id
        assert len(factory.sessions) == 2
        assert len(factory.released) == 2
        terminals_for_failed_item = [
            received
            for received in [*failure_events, *recovery_events]
            if received.get("item_id") == failed_item_id
            and received["type"]
            in {
                "conversation.item.input_audio_transcription.completed",
                "conversation.item.input_audio_transcription.failed",
            }
        ]
        assert terminals_for_failed_item == [failed_terminal]


def test_openai_commit_total_deadline_releases_hung_reader_slot() -> None:
    factory = HangingCommitStreamingFactory()
    client, factory = _client(
        factory=factory,
        settings_kwargs={"request_timeout_seconds": 0.01},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(session_update(model="whisper-1"))
        socket.receive_json()  # session.updated

        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, event, item_events = _receive_committed_item(
            socket,
            expected_sample_span=(0, len(_FRAME) // 2),
        )
        assert boundary is not None
        assert event["type"] == "conversation.item.input_audio_transcription.failed"
        assert event["error"]["code"] == "backend_timeout"
        terminals = [
            received
            for received in item_events
            if received.get("item_id") == event["item_id"]
            and received["type"]
            in {
                "conversation.item.input_audio_transcription.completed",
                "conversation.item.input_audio_transcription.failed",
            }
        ]
        assert terminals == [event]
        assert len(factory.released) == 1


def test_realtime_vad_speech_end_does_not_drop_chunk_audio() -> None:
    """The chunk where server VAD ends the turn still reaches ASR before commit."""
    from test_realtime_vad_bargein import _wire_silence_frame, _wire_speech_frame

    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            session_update(
                endpointing=server_vad(
                    threshold=0.3, prefix_padding_ms=0, silence_duration_ms=100
                )
            )
        )
        assert socket.receive_json()["type"] == "session.updated"

        # The wire is 24 kHz PCM16: one frame is 768 samples and resamples to a
        # single 512-sample 16 kHz VAD frame.
        frame = _wire_speech_frame()
        silence = _wire_silence_frame()

        def audio_b64(raw: bytes) -> str:
            return base64.b64encode(raw).decode("ascii")

        # Three loud frames cross the admission debounce.
        for _ in range(3):
            socket.send_json({"type": "input_audio_buffer.append", "audio": audio_b64(frame)})

        # Four silent frames cross the 100 ms stop debounce and commit the turn.
        for _ in range(4):
            socket.send_json({"type": "input_audio_buffer.append", "audio": audio_b64(silence)})

        wire_samples = (len(frame) * 3 + len(silence) * 4) // 2
        boundary, completed, _ = _receive_committed_item(
            socket,
            expected_sample_span=(0, wire_samples),
        )
        assert boundary is not None
        assert boundary["reason"] == "vad"
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

        assert len(factory.sessions) == 1
        received_samples = sum(
            len(chunk) // 2 for session in factory.sessions for chunk in session.received
        )
        # Byte conservation across the 24k wire -> 16k kernel boundary: every
        # frame, including the commit frame, is resampled and appended.
        expected_samples = wire_samples * 16_000 // 24_000
        assert abs(received_samples - expected_samples) <= 1
        assert factory.sessions[0].commits == 1
        assert len(factory.released) == 1

class _ExplodingEventsSession(FakeStreamingSession):
    """Session whose event stream dies with an unexpected error mid-iteration."""

    def events(self):
        async def iterator():
            yield StreamingAsrEvent(kind="partial", text="hi")
            raise ValueError("reader boom")

        return iterator()


class ExplodingEventsStreamingFactory(FakeStreamingFactory):
    def session_class(self) -> type[_ExplodingEventsSession]:
        return _ExplodingEventsSession


def test_openai_asr_reader_failure_emits_transcription_failed() -> None:
    """A dead ASR reader must surface transcription_failed, not die silently."""
    factory = ExplodingEventsStreamingFactory()
    client, _ = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
                        session_update(model="whisper-1")
        )
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.failed":
                assert event["error"]["code"] == "backend_error"
                break
            assert event["type"] != "error"


class _HangingCommitSession(FakeStreamingSession):
    """Session whose commit never resolves, stalling the event handler."""

    async def commit(self, want_segments: bool = False) -> None:
        await asyncio.Event().wait()


class HangingCommitStreamingFactory(FakeStreamingFactory):
    def session_class(self) -> type[_HangingCommitSession]:
        return _HangingCommitSession


class _HangingEventsSession(FakeStreamingSession):
    """Session whose commit is acknowledged before its event stream stalls."""

    async def commit(self, want_segments: bool = False) -> None:
        return None

    def events(self):
        async def iterator():
            yield StreamingAsrEvent(kind="partial", text="hi")
            await asyncio.Event().wait()

        return iterator()


class HangingEventsStreamingFactory(FakeStreamingFactory):
    def session_class(self) -> type[_HangingEventsSession]:
        return _HangingEventsSession


class _RuntimeErrorEventsSession(FakeStreamingSession):
    def events(self):
        async def iterator():
            raise RuntimeError("backend reader boom")
            yield StreamingAsrEvent(kind="partial", text="unreachable")

        return iterator()


class RuntimeErrorEventsStreamingFactory(FakeStreamingFactory):
    def session_class(self) -> type[_RuntimeErrorEventsSession]:
        return _RuntimeErrorEventsSession


def test_openai_commit_ack_then_hung_reader_times_out_with_failure() -> None:
    """The commit ACK alone is not an ASR terminal.  A reader that stalls
    afterwards must still hit the request deadline and release its slot."""

    async def scenario() -> tuple[list[dict[str, Any]], FakeStreamingFactory]:
        factory = HangingEventsStreamingFactory()
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
            request_timeout_seconds=0.01,
        )
        services = build_app_services(
            settings,
            AppOverrides(realtime_asr_factory=factory),
        )
        sent: list[dict[str, Any]] = []

        async def send(event: dict[str, Any]) -> int:
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="hung-reader", send=send)
        await session.handle(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        await asyncio.wait_for(session._asr_owner.commit("client"), timeout=0.5)
        await session.close()
        return sent, factory

    sent, factory = asyncio.run(scenario())
    failed = [
        event
        for event in sent
        if event["type"] == "conversation.item.input_audio_transcription.failed"
    ]
    assert len(failed) == 1
    assert failed[0]["error"]["code"] == "backend_timeout"
    assert not any(event["type"] == "error" for event in sent)
    assert not any(
        event["type"] == "conversation.item.input_audio_transcription.completed"
        for event in sent
    )
    assert len(factory.released) == 1


def test_openai_asr_reader_runtime_error_emits_transcription_failed() -> None:
    """RuntimeError from a backend iterator is a failure, not a disconnect."""

    async def scenario() -> list[dict[str, Any]]:
        settings = Settings(
            qwen3_model_dir=None,
            qwen3_python=None,
            diarization_model_path=None,
            diarization_embedding_model_path=None,
        )
        services = build_app_services(
            settings,
            AppOverrides(realtime_asr_factory=RuntimeErrorEventsStreamingFactory()),
        )
        sent: list[dict[str, Any]] = []

        async def send(event: dict[str, Any]) -> int:
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="reader-error", send=send)
        await session.handle(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        await asyncio.wait_for(session._asr_owner.commit("client"), timeout=0.5)
        await session.close()
        return sent

    sent = asyncio.run(scenario())
    failed = [
        event
        for event in sent
        if event["type"] == "conversation.item.input_audio_transcription.failed"
    ]
    assert len(failed) == 1
    assert failed[0]["error"]["code"] == "backend_error"


def test_openai_client_event_queue_overflow_closes_session(monkeypatch) -> None:
    """A stalled handler must not buffer client audio without bound.

    The whole interaction runs on a daemon thread with a bounded wait: the
    pre-fix server never closes the session, so receiving would block forever.
    """
    import threading

    factory = HangingCommitStreamingFactory()
    append_started = threading.Event()

    async def blocked_append(self, event):
        append_started.set()
        await asyncio.Event().wait()

    # Model finalization runs independently of ingress. Hold the ingress
    # operation itself to exercise the transport queue's overflow boundary.
    monkeypatch.setattr(RealtimeAsrOwner, "append", blocked_append)
    client, _ = _client(factory=factory)
    done = threading.Event()
    outcome: dict[str, object] = {}

    def scenario() -> None:
        try:
            with client.websocket_connect("/v1/realtime") as socket:
# Realtime ASR/TTS handshake has no conversation.created event
                socket.receive_json()
                socket.send_json(
                                        session_update(model="whisper-1")
                )
                socket.receive_json()
                socket.send_json(
                    {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
                )
                assert append_started.wait(2.0)
                for index in range(600):
                    socket.send_json(
                        {
                            "type": "input_audio_buffer.append",
                            "audio": _pcm16(bytes([index % 256, 0])),
                        }
                    )
                while True:
                    socket.receive_json()
        except WebSocketDisconnect:
            outcome["ok"] = True
        except Exception as exc:  # pragma: no cover - diagnostic only
            outcome["error"] = repr(exc)
        finally:
            done.set()

    threading.Thread(target=scenario, daemon=True).start()
    assert done.wait(10.0), "session never closed after client event queue overflow"
    assert outcome.get("ok") is True, outcome


def test_server_vad_silence_never_emits_text_before_commit() -> None:
    """R0/R2: pure silence under server_vad never yields text before commit."""
    client, factory = _client(
        emit_text_on_flush="嗯",
        settings_kwargs={
            "qwen3_streaming_chunk_duration_ms": 1_000,
            "realtime_speech_admission_enabled": True,
        },
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(session_update(endpointing=server_vad()))
        assert socket.receive_json()["type"] == "session.updated"

        silence_chunk = b"\x00\x00" * 320  # ~13 ms of 24 kHz wire audio
        for _ in range(65):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(silence_chunk)}
            )

        socket.send_json({"type": "input_audio_buffer.commit"})

        boundary, completed, events = _receive_committed_item(
            socket,
            expect_boundary=False,
        )
        assert boundary is None
        assert [event["type"] for event in events] == [
            "conversation.item.input_audio_transcription.completed"
        ]
        assert completed["transcript"] == ""
        # Silence never admitted speech, so no ASR session was ever opened.
        assert factory.sessions == []

def test_server_vad_silence_has_no_text_or_asr_item() -> None:
    """Silence remains an empty final under the smallest valid service budget."""
    client, _ = _client(
        completed_text="嗯",
        settings_kwargs={
            "max_realtime_buffer_bytes": 64_000,
            "realtime_speech_admission_enabled": True,
        },
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(session_update(endpointing=server_vad()))
        assert socket.receive_json()["type"] == "session.updated"

        silence_chunk = b"\x00\x00" * 500
        for _ in range(6):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(silence_chunk)}
            )
        socket.send_json({"type": "input_audio_buffer.commit"})

        boundary, event, _ = _receive_committed_item(
            socket,
            expect_boundary=False,
        )
        assert boundary is None
        assert event["type"] == "conversation.item.input_audio_transcription.completed"
        assert event["transcript"] == ""

def test_server_vad_silence_explicit_commit_closes_empty() -> None:
    """R0/R2: an explicit commit on silence closes with one empty final."""
    client, _ = _client(
        completed_text="嗯",
        settings_kwargs={"realtime_speech_admission_enabled": True},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(session_update(endpointing=server_vad()))
        assert socket.receive_json()["type"] == "session.updated"

        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 500)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})

        boundary, event, _ = _receive_committed_item(
            socket,
            expect_boundary=False,
        )
        assert boundary is None
        assert event["type"] == "conversation.item.input_audio_transcription.completed"
        assert event["transcript"] == ""

def test_server_vad_admission_admitted_speech_transcription_and_events() -> None:
    """R2: SpeechAdmission admits speech, drives ASR and yields one revisioned final."""
    from test_realtime_vad_bargein import _wire_silence_frame, _wire_speech_frame

    client, factory = _client(
        completed_text="你好世界",
        partials=("你好",),
        settings_kwargs={"realtime_speech_admission_enabled": True},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            session_update(
                endpointing=server_vad(
                    threshold=0.3, prefix_padding_ms=100, silence_duration_ms=100
                )
            )
        )
        assert socket.receive_json()["type"] == "session.updated"

        for _ in range(3):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_wire_silence_frame())}
            )
        for _ in range(4):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_wire_speech_frame())}
            )
        for _ in range(4):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_wire_silence_frame())}
            )

        boundary, completed, events = _receive_committed_item(socket)
        assert boundary is not None
        assert boundary["reason"] == "vad"
        assert completed["transcript"] == "你好世界"

        observed = {event["type"] for event in events}
        assert "conversation.item.input_audio_transcription.delta" not in observed
        assert "speechrail.transcription.segment_closed" in observed
        assert "conversation.item.input_audio_transcription.completed" in observed
        assert len(factory.sessions) == 1
        assert factory.sessions[0].commits == 1
        assert len(factory.released) == 1

def test_server_vad_admission_diarization_sample_mapping() -> None:
    """R2: an admitted server-VAD turn publishes speaker units on the wire."""
    from test_diarization_extensions import _FakeDiarizationEngine
    from test_realtime_vad_bargein import _wire_silence_frame, _wire_speech_frame

    client, _ = _client(
        completed_text="扩展模式转写",
        diarization_engine=_FakeDiarizationEngine(supports_stream=True),
        settings_kwargs={"realtime_speech_admission_enabled": True},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            session_update(
                endpointing=server_vad(
                    threshold=0.3, prefix_padding_ms=100, silence_duration_ms=100
                ),
                diarization={"enabled": True},
            )
        )
        assert socket.receive_json()["type"] == "session.updated"

        for _ in range(31):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_wire_silence_frame())}
            )
        for _ in range(4):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_wire_speech_frame())}
            )
        for _ in range(4):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_wire_silence_frame())}
            )

        boundary, completed, _ = _receive_committed_item(socket)
        assert boundary is not None
        assert boundary["reason"] == "vad"
        # The text final precedes the auxiliary alignment, so wait for the
        # alignment result before asking diarization to publish its units.
        for _ in range(256):
            event = socket.receive_json()
            if event["type"] == "speechrail.alignment.done":
                break

        socket.send_json(
            {"type": "speechrail.diarization.finish", "event_id": "sample_map"}
        )
        done = None
        for _ in range(256):
            event = socket.receive_json()
            if event["type"] == "speechrail.diarization.done":
                done = event
                break
        assert done is not None
        units = list(done["units"])  # type: ignore[arg-type]

        assert completed is not None
        assert completed["transcript"] == "扩展模式转写"
        assert units, "admitted speech must publish at least one speaker unit"
        spans = [unit["sample_span"] for unit in units]
        assert all(span["end"] > span["start"] for span in spans)
        # Units stay inside the 24 kHz wire timeline for the admitted frames.
        wire_total = (31 + 4 + 4) * 768
        assert all(span["end"] <= wire_total for span in spans)

def test_manual_rollover_commit_clear_wire_barrier_collects_every_item_once() -> None:
    """Real WebSocket handler + fake ASR; not an acoustic/latency benchmark."""
    from speechrail.realtime.turn_collection import ManualTurnCollector

    client, factory = _client(
        completed_text="same",
        settings_kwargs={
            "max_realtime_buffer_bytes": 128_000,
            "max_realtime_frame_bytes": 8192,
        },
    )
    collector = ManualTurnCollector(epoch="wire")
    observed: list[dict[str, Any]] = []
    with client.websocket_connect("/v1/realtime") as socket:
        def receive() -> dict[str, Any]:
            event = socket.receive_json()
            observed.append(event)
            collector.accept(event, epoch="wire")
            assert collector.state != "failed", collector.failure_reason
            return event

        receive()  # session.created (sequence 0)
        update = session_update()
        update["session"]["speechrail"]["asr"] = {
            "preview_interval_ms": 1_000,
            "max_segment_ms": 1_000,
            "finalization": "full_segment",
        }
        socket.send_json(update)
        receive()  # session.updated
        # Two server-side one-second rollovers plus one explicit commit produce
        # one terminal per item. Rollover is server-initiated, so the caller
        # declares the expected item count before streaming.
        for _ in range(3):
            collector.expect_item()
        for frame_count in (7, 7, 3):
            for _ in range(frame_count):
                socket.send_json(
                    {
                        "type": "input_audio_buffer.append",
                        "audio": _pcm16(b"\x00" * 8192),
                    }
                )
            if frame_count != 3:
                while receive()["type"] != (
                    "conversation.item.input_audio_transcription.completed"
                ):
                    pass  # Drain the rollover boundary and its matching terminal.
        collector.begin_close()
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            final = receive()
            if final["type"] == "conversation.item.input_audio_transcription.completed":
                break  # The explicit item first publishes its segment boundary.
        socket.send_json({"type": "input_audio_buffer.clear"})
        assert final["type"] == "conversation.item.input_audio_transcription.completed"
        assert collector.result is not None
        assert collector.result.text == "samesamesame"
        assert len(collector.result.item_ids) == 3
        assert len(set(collector.result.item_ids)) == 3
        boundaries = [
            event for event in observed
            if event["type"] == "speechrail.transcription.segment_closed"
        ]
        terminals = [
            event for event in observed
            if event["type"] == "conversation.item.input_audio_transcription.completed"
        ]
        assert len(boundaries) == len(terminals) == 3
        assert [event["reason"] for event in boundaries] == [
            "budget_rollover",
            "budget_rollover",
            "client_commit",
        ]
        spans = [event["sample_span"] for event in boundaries]
        assert all(
            type(span["start"]) is int
            and type(span["end"]) is int
            and 0 <= span["start"] < span["end"]
            for span in spans
        )
        assert spans[0]["start"] == 0
        assert all(
            previous["end"] == current["start"]
            for previous, current in pairwise(spans)
        )
        assert spans[-1]["end"] == 17 * (8192 // 2)
        for boundary in boundaries:
            terminal = next(
                event for event in terminals if event["item_id"] == boundary["item_id"]
            )
            assert observed.index(boundary) < observed.index(terminal)
        assert not any(
            event["type"] == "conversation.item.input_audio_transcription.delta"
            for event in observed
        )
    assert len(factory.sessions) == 3
    assert all(session.closes == 1 for session in factory.sessions)


def test_manual_append_failure_followed_by_clear_never_becomes_final_transcript() -> None:
    from speechrail.realtime.turn_collection import ManualTurnCollector

    client, _ = _client(
        settings_kwargs={
            "max_realtime_buffer_bytes": 64_000,
            "max_realtime_frame_bytes": 128,
        }
    )
    collector = ManualTurnCollector(epoch="wire")
    with client.websocket_connect("/v1/realtime") as socket:
        for _ in range(1):
            collector.accept(socket.receive_json(), epoch="wire")
        collector.note_append()
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\0" * 5000)})
        failed = socket.receive_json()
        assert failed["type"] == "error"
        assert failed["error"]["code"] == "frame_too_large"
        collector.accept(failed, epoch="wire")
        socket.send_json({"type": "input_audio_buffer.clear"})
        # No clear acknowledgement on the current wire; a failed append must
        # never turn into a success receipt.
    assert collector.state == "failed" and collector.result is None


@pytest.mark.parametrize("empty", [False, True])
def test_manual_clear_after_terminal_preserves_completed_and_empty_input(empty: bool) -> None:
    from speechrail.realtime.turn_collection import ManualTurnCollector

    client, factory = _client(factory=EarlyCompletionStreamingFactory())
    collector = ManualTurnCollector(epoch="wire")
    with client.websocket_connect("/v1/realtime") as socket:
        for _ in range(1):
            collector.accept(socket.receive_json(), epoch="wire")
        if not empty:
            collector.note_append()
            socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\0" * 1000)})
        collector.expect_item()
        collector.begin_close()
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, terminal, item_events = _receive_committed_item(
            socket,
            expect_boundary=not empty,
            expected_sample_span=(0, 500) if not empty else None,
        )
        assert (boundary is not None) is not empty
        for event in item_events:
            collector.accept(event, epoch="wire")
        event = terminal
        assert event["type"] == "conversation.item.input_audio_transcription.completed"
        socket.send_json({"type": "input_audio_buffer.clear"})
    if not empty:
        assert factory.sessions[0].closes == 1
    assert collector.state == "completed"
    assert collector.result is not None
    assert collector.result.text == ("" if empty else "你好")


@pytest.mark.parametrize("timeout_reader", [False, True])
def test_manual_commit_timeout_followed_by_clear_never_succeeds(timeout_reader: bool) -> None:
    """A successful FIFO cleanup cannot erase a failed commit or hung ASR terminal."""
    from speechrail.realtime.turn_collection import ManualTurnCollector

    factory: FakeStreamingFactory = (
        HangingCommitStreamingFactory() if timeout_reader else FailingCommitStreamingFactory()
    )
    client, factory = _client(
        factory=factory, settings_kwargs={"request_timeout_seconds": 0.01}
    )
    collector = ManualTurnCollector(epoch="wire")
    with client.websocket_connect("/v1/realtime") as socket:
        for _ in range(1):
            collector.accept(socket.receive_json(), epoch="wire")
        socket.send_json(
                        session_update(model="whisper-1")
        )
        collector.accept(socket.receive_json(), epoch="wire")
        collector.note_append()
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        collector.expect_item()
        collector.begin_close()
        socket.send_json({"type": "input_audio_buffer.commit"})
        boundary, terminal, item_events = _receive_committed_item(
            socket,
            expected_sample_span=(0, len(_FRAME) // 2),
        )
        assert boundary is not None
        assert terminal["type"] == "conversation.item.input_audio_transcription.failed"
        assert terminal["error"]["code"] == "backend_timeout"
        socket.send_json({"type": "input_audio_buffer.clear"})
        for event in item_events:
            collector.accept(event, epoch="wire")
    assert collector.state == "failed"
    assert collector.result is None
    assert len(factory.released) == 1


@pytest.mark.parametrize("with_audio", [False, True])
def test_optional_commit_receipt_covers_empty_duplicate_and_clear_watermark(
    with_audio: bool,
) -> None:
    async def scenario() -> None:
        factory = FakeStreamingFactory()
        services = build_app_services(Settings(), AppOverrides(
            batch_transcriber=FakeTranscriber(), tts_synthesizer=FakeSpeechSynthesizer(),
            realtime_asr_factory=factory,
        ))
        events: list[dict[str, object]] = []
        async def send(event: dict[str, object]) -> None:
            events.append(event)
        session = OpenAIRealtimeSession(services, session_id="receipt-test", send=send)
        try:
            if with_audio:
                await session.handle({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
            for event_id in ("first", "repeat", "repeat"):
                await session.handle({"type": "input_audio_buffer.commit", "event_id": event_id,
                                      "speechrail": {"request_receipt": True}})
                assert events[-1] == {
                    "type": "speechrail.input_audio_buffer.committed", "commit_event_id": event_id,
                    "accepted_samples": len(_FRAME) // 2 if with_audio else 0,
                }
            finals = [e for e in events
                      if e["type"] == "conversation.item.input_audio_transcription.completed"]
            assert len(finals) == 1
            await session.handle({"type": "input_audio_buffer.clear"})
            await session.handle({"type": "input_audio_buffer.commit", "event_id": "after-clear",
                                  "speechrail": {"request_receipt": True}})
            assert events[-1]["accepted_samples"] == (len(_FRAME) // 2 if with_audio else 0)
            assert all(s.closes == 1 for s in factory.sessions)
        finally:
            await session.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("requested", [None, False])
def test_default_and_false_receipt_preserve_legacy_wire(requested: bool | None) -> None:
    async def scenario() -> None:
        services = build_app_services(Settings(), AppOverrides(
            batch_transcriber=FakeTranscriber(), tts_synthesizer=FakeSpeechSynthesizer(),
            realtime_asr_factory=FakeStreamingFactory(),
        ))
        events: list[dict[str, object]] = []
        async def send(event: dict[str, object]) -> None:
            events.append(event)
        session = OpenAIRealtimeSession(services, session_id="legacy-test", send=send)
        try:
            event: dict[str, Any] = {"type": "input_audio_buffer.commit", "event_id": "old"}
            if requested is not None:
                event["speechrail"] = {"request_receipt": requested}
            await session.handle(event)
            await session.handle(event)
            assert [e["type"] for e in events] == [
                "conversation.item.input_audio_transcription.completed"
            ]
        finally:
            await session.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("cancel_before_delivery", [False, True])
def test_commit_receipt_waits_for_terminal_delivery_and_cancel_never_acknowledges(
    cancel_before_delivery: bool,
) -> None:
    async def scenario() -> None:
        factory = FakeStreamingFactory()
        services = build_app_services(Settings(), AppOverrides(
            batch_transcriber=FakeTranscriber(), tts_synthesizer=FakeSpeechSynthesizer(),
            realtime_asr_factory=factory,
        ))
        events: list[dict[str, object]] = []
        terminal_send_started = asyncio.Event()
        deliver_terminal = asyncio.Event()
        async def send(event: dict[str, object]) -> None:
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                terminal_send_started.set()
                await deliver_terminal.wait()
            events.append(event)
        session = OpenAIRealtimeSession(services, session_id="delivery-test", send=send)
        try:
            await session.handle({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
            commit = asyncio.create_task(session.handle({
                "type": "input_audio_buffer.commit", "event_id": "barrier",
                "speechrail": {"request_receipt": True},
            }))
            await asyncio.wait_for(terminal_send_started.wait(), 1)
            assert not commit.done()
            assert not any(e["type"] == "speechrail.input_audio_buffer.committed" for e in events)
            if cancel_before_delivery:
                commit.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await asyncio.wait_for(commit, 1)
                assert not any(
                    e["type"] == "speechrail.input_audio_buffer.committed" for e in events
                )
            else:
                deliver_terminal.set()
                await asyncio.wait_for(commit, 1)
                assert [e["type"] for e in events][-2:] == [
                    "conversation.item.input_audio_transcription.completed",
                    "speechrail.input_audio_buffer.committed",
                ]
        finally:
            deliver_terminal.set()
            await session.close()
        assert all(s.closes == 1 for s in factory.sessions)
    asyncio.run(scenario())


@pytest.mark.parametrize("extension", [None, True, {"request_receipt": 1}, {"unknown": True}])
def test_commit_receipt_rejects_invalid_extension(extension: object) -> None:
    from speechrail.compatibility.openai_realtime import parse_commit_receipt_request
    with pytest.raises(RealtimeAdapterError):
        parse_commit_receipt_request({"event_id": "id", "speechrail": extension})


def test_commit_receipt_requires_correlation_id() -> None:
    from speechrail.compatibility.openai_realtime import parse_commit_receipt_request
    with pytest.raises(RealtimeAdapterError):
        parse_commit_receipt_request({"speechrail": {"request_receipt": True}})


def test_auto_rollover_terminal_precedes_tail_commit_receipt_on_real_route() -> None:
    client, factory = _client(
        settings_kwargs={
            "max_realtime_buffer_bytes": 128_000,
            "max_realtime_frame_bytes": 25_000,
        }
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        update = session_update()
        update["session"]["speechrail"]["asr"] = {
            "preview_interval_ms": 1_000,
            "max_segment_ms": 1_000,
            "finalization": "full_segment",
        }
        socket.send_json(update)
        assert socket.receive_json()["type"] == "session.updated"
        for _ in range(2):
            socket.send_json(
                {
                    "type": "input_audio_buffer.append",
                    "audio": _pcm16(b"\0" * 25_000),
                }
            )
        old_boundary, old, _ = _receive_committed_item(
            socket,
            expected_sample_span=(0, 24_000),
        )
        assert old_boundary is not None
        assert old_boundary["reason"] == "budget_rollover"
        assert old["type"] == "conversation.item.input_audio_transcription.completed"
        assert "commit_event_id" not in old
        socket.send_json({"type": "input_audio_buffer.commit", "event_id": "tail-barrier",
                          "speechrail": {"request_receipt": True}})
        tail_boundary, tail, _ = _receive_committed_item(
            socket,
            expected_sample_span=(24_000, 25_000),
            expected_commit_event_id="tail-barrier",
        )
        assert tail_boundary is not None
        assert tail_boundary["reason"] == "client_commit"
        receipt = socket.receive_json()
        assert tail["type"] == "conversation.item.input_audio_transcription.completed"
        assert tail["commit_event_id"] == "tail-barrier"
        assert receipt["type"] == "speechrail.input_audio_buffer.committed"
        assert receipt["commit_event_id"] == "tail-barrier"
        assert receipt["accepted_samples"] == 25_000
        assert receipt["sequence"] > tail["sequence"] > old["sequence"]
        socket.send_json({"type": "input_audio_buffer.commit", "event_id": "repeat-barrier",
                          "speechrail": {"request_receipt": True}})
        repeat = socket.receive_json()
        assert repeat["type"] == "speechrail.input_audio_buffer.committed"
        assert repeat["accepted_samples"] == 25_000
    assert len(factory.sessions) == 2
    assert all(s.closes == 1 for s in factory.sessions)


@pytest.mark.parametrize("failure", ["missing_terminal", "timeout"])
def test_unretired_input_never_gets_a_receipt_on_first_or_repeated_commit(failure: str) -> None:
    async def scenario() -> None:
        factory = FakeStreamingFactory()
        services = build_app_services(Settings(), AppOverrides(
            batch_transcriber=FakeTranscriber(), tts_synthesizer=FakeSpeechSynthesizer(),
            realtime_asr_factory=factory,
        ))
        events: list[dict[str, object]] = []
        async def send(event: dict[str, object]) -> None:
            events.append(event)
        session = OpenAIRealtimeSession(services, session_id="no-terminal", send=send)
        try:
            await session.handle({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
            async def bad_commit(want_segments: bool = False) -> None:
                if failure == "timeout":
                    raise TimeoutError
                await factory.sessions[0].events_queue.put(None)
            factory.sessions[0].commit = bad_commit  # type: ignore[method-assign]
            for event_id in ("first", "retry"):
                with pytest.raises(RealtimeAdapterError):
                    await session.handle({"type": "input_audio_buffer.commit", "event_id": event_id,
                                          "speechrail": {"request_receipt": True}})
            assert not any(e["type"] == "speechrail.input_audio_buffer.committed" for e in events)
            assert factory.sessions[0].closes == 1
            # An explicit discard is a new input generation, not a silent retry.
            await session.handle({"type": "input_audio_buffer.clear"})
            await session.handle({"type": "input_audio_buffer.commit", "event_id": "after-clear",
                                  "speechrail": {"request_receipt": True}})
            assert events[-1]["type"] == "speechrail.input_audio_buffer.committed"
        finally:
            await session.close()
    asyncio.run(scenario())


def test_repeated_disconnect_cancellation_joins_owned_session_close(monkeypatch) -> None:
    from starlette.websockets import WebSocket

    async def scenario() -> None:
        services = build_app_services(
            Settings(qwen3_model_dir=None, qwen3_python=None, _env_file=None),
            AppOverrides(realtime_asr_factory=FakeStreamingFactory()),
        )
        entered = asyncio.Event()
        release = asyncio.Event()
        closed = []
        original_close = OpenAIRealtimeSession.close

        async def gated_close(self):
            entered.set()
            await release.wait()
            await original_close(self)
            closed.append(self._session_id)

        monkeypatch.setattr(OpenAIRealtimeSession, "close", gated_close)
        messages = asyncio.Queue()
        messages.put_nowait({"type": "websocket.connect"})
        messages.put_nowait({"type": "websocket.disconnect", "code": 1000})

        async def send(message):
            pass

        websocket = WebSocket(
            {"type": "websocket", "path": "/v1/realtime", "headers": [], "query_string": b""},
            messages.get, send,
        )
        endpoint = create_openai_realtime_router(services).routes[0].endpoint
        task = asyncio.create_task(endpoint(websocket))
        await asyncio.wait_for(entered.wait(), timeout=1)
        try:
            task.cancel()
            await asyncio.sleep(0)
            task.cancel()
            await asyncio.sleep(0)
            assert not task.done()
            assert not closed
        finally:
            release.set()
            await asyncio.wait_for(task, timeout=1)
        assert len(closed) == 1

    asyncio.run(scenario())
