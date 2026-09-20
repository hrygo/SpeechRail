from __future__ import annotations

import asyncio
import base64
import hashlib
import time
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from speechrail.application.realtime_openai import OpenAIRealtimeSession, Pcm16RateConverter
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    apply_session_update,
    error_event,
    session_created,
    transcription_segment,
)
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.diarization import (
    ActivityFrame,
    ActivityUpdate,
    AlignmentRequest,
    AlignmentResult,
    DiarizationError,
    Span,
    TextUnit,
)
from speechrail.domain.ports import (
    AudioChunk,
    RealtimeAsrSession,
    SpeechRequest,
    StreamingAsrEvent,
    TranscriptionRequest,
)
from speechrail.domain.tts import get_voice_registry
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

    def session_class(self) -> type[FakeStreamingSession]:
        return FakeStreamingSession

    def create(self, *, language: str | None, prompt: str) -> FakeStreamingSession:
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
        self.sessions.append(session)
        return session

    def release(self, session: RealtimeAsrSession) -> None:
        self.released.append(session)


class RejectingLanguageStreamingFactory(FakeStreamingFactory):
    """Mirrors the native factory that raises RuntimeError for unsupported languages."""

    def create(self, *, language: str | None, prompt: str) -> FakeStreamingSession:
        resolved = (language or "auto").strip().lower()
        if resolved.startswith("xx"):
            raise RuntimeError(f"language_not_supported: {resolved}")
        return super().create(language=language, prompt=prompt)


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
                replace_span=Span(start_sample, end),
                frames=(
                    ActivityFrame(Span(start_sample, end), (0.95, 0.0, 0.0, 0.0), frozenset({0})),
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
                replace_span=Span(start_sample, end),
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
            request.epoch,
            request.item_id,
            (TextUnit("fixed", 0, len(request.text), request.span),),
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


def _pcm16(audio: bytes) -> str:
    return base64.b64encode(audio).decode("ascii")


def test_backend_busy_error_keeps_compat_code_and_namespaced_reason() -> None:
    event = error_event(
        code="backend_busy",
        message="realtime streaming session capacity is full",
        busy_reason="realtime_session_limit",
    )

    assert event["error"]["code"] == "backend_busy"
    assert event["speechrail"] == {
        "busy_reason": "realtime_session_limit",
        "retryable": True,
        "retry_hint": "wait_for_realtime_session_slot",
    }


def test_openai_session_created_and_updated() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        created = socket.receive_json()
        assert created["type"] == "session.created"
        assert created["session"]["model"] == "speechrail/qwen3-asr-1.7b"
        assert "capabilities" in created["session"]
        assert created["session"]["turn_detection"] is None

        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"model": "whisper-1"},
                    "turn_detection": None,
                },
            }
        )
        updated = socket.receive_json()
        assert updated["type"] == "transcription_session.updated"
        assert updated["session"]["input_audio_transcription"]["model"] == "whisper-1"


def test_session_created_advertises_stable_clone_loudness_profile() -> None:
    event = session_created(
        session_id="sess-1",
        model="speechrail/qwen3-tts",
        tts_ready=True,
        tts_loudness_profile="stable_loudness_v1",
    )

    assert event["session"]["speech_capabilities"]["audio_loudness_profile"] == (
        "stable_loudness_v1"
    )


def test_realtime_quality_session_repeats_stable_clone_loudness_profile() -> None:
    preset = load_catalog().preset("quality")
    client, _ = _client(
        settings_kwargs={
            "qwen3_model_dir": Path(preset.asr),
            "qwen3_tts_model_dir": Path(preset.tts),
            "qwen3_tts_clone_model_dir": Path(preset.tts_clone),
        }
    )
    with client.websocket_connect("/v1/realtime") as socket:
        created = socket.receive_json()
        capabilities = created["session"]["speech_capabilities"]
        assert capabilities["audio_loudness_profile"] == "stable_loudness_v1"
        assert created["session"]["speechrail"]["tts"]["enabled"] is False


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
            {"type": "response.output_audio.delta"},
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
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"model": "whisper-1"},
                    "turn_detection": None,
                },
            }
        )
        socket.receive_json()  # transcription_session.updated

        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})

        committed = socket.receive_json()
        assert committed["type"] == "input_audio_buffer.committed"

        item = socket.receive_json()
        assert item["type"] == "conversation.item.created"
        completed = socket.receive_json()
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert completed["transcript"] == "你好"
        assert len(factory.sessions) == 1
        assert factory.sessions[0].language is None
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
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
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


def test_realtime_tts_records_complete_phase() -> None:
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
        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_tts_metrics_test",
            send=lambda event: asyncio.sleep(0),
        )
        await session.start()
        await session.handle(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        await session.handle(
            {
                "type": "speechrail.tts.create",
                "request_id": "tts_metrics_001",
                "text": "你好",
            }
        )
        assert session._tts_task is not None
        await session._tts_task
        await session.close()
        return services.metrics.render_json()

    metrics = asyncio.run(scenario())
    histograms = metrics["histograms"]
    assert isinstance(histograms, dict)
    phases = histograms["speechrail_realtime_phase_duration_seconds"]
    assert isinstance(phases, dict)
    complete = [
        reading
        for labels, reading in phases.items()
        if 'phase="tts_complete"' in labels
    ]
    assert len(complete) == 1
    assert complete[0]["count"] == 1


def test_openai_commit_releases_streaming_slot_for_next_append() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"model": "whisper-1"},
                    "turn_detection": None,
                },
            }
        )
# current-only handshake has no conversation.created event

        def commit_round() -> None:
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
            )
            socket.send_json({"type": "input_audio_buffer.commit"})
            while socket.receive_json()["type"] != (
                "conversation.item.input_audio_transcription.completed"
            ):
                pass

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
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
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
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"model": "gpt-4o-transcribe"}
                },
            }
        )
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
        assert len(factory.sessions) == 1


def test_openai_diarized_model_alias_does_not_enable_realtime_diarization() -> None:
    engine = FakeDiarizationEngine()
    segment = TranscriptSegment(id=1, start_ms=0, end_ms=500, text="你好")
    client, factory = _client(segments=(segment,), diarization_engine=engine)
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"model": "gpt-4o-transcribe-diarize"}
                },
            }
        )
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        events = []
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break

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
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"diarization": {"enabled": True}}},
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 8000)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        events: list[dict[str, Any]] = []
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break

        socket.send_json(
            {"type": "speechrail.diarization.finish", "event_id": "final-no-evidence"}
        )
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] in {"speechrail.diarization.done", "error"}:
                break

    updates = [
        update
        for event in events
        if event["type"] == "speechrail.diarization.updated"
        for update in event["updates"]
    ]
    assert updates
    assert any(update["status"] == "unknown" and update["speaker"] is None for update in updates)
    assert all(
        update["speaker"] is not None
        for update in updates
        if update["status"] in {"tentative", "stable"}
    )


def test_openai_commit_without_diarization_does_not_request_segments() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"model": "whisper-1"}},
            }
        )
        socket.receive_json()  # transcription_session.updated
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        events = []
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break

    assert factory.sessions and factory.sessions[0].want_segments is False
    assert not any(event["type"].endswith(".segment") for event in events)


def test_openai_commit_with_segment_timestamps_requests_segments() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"timestamp_granularities": ["segment"]}
                },
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while socket.receive_json()["type"] != (
            "conversation.item.input_audio_transcription.completed"
        ):
            pass

    assert factory.sessions and factory.sessions[0].want_segments is True


def test_openai_realtime_rejects_a_frame_over_the_configured_limit() -> None:
    factory_client, _ = _client()
    with factory_client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"model": "whisper-1"}},
            }
        )
        socket.receive_json()  # transcription_session.updated
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80_001)}
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "frame_too_large"


def test_openai_tts_model_is_rejected_in_transcription_session() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"model": "tts-1"}},
            }
        )
        error = socket.receive_json()
        assert error["error"]["code"] == "model_not_found"


def test_openai_rejects_unknown_model() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"model": "gpt-5-fake"}},
            }
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "model_not_found"


def test_openai_rejects_unsupported_turn_detection() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"turn_detection": {"type": "unsupported_mode"}},
            }
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_turn_detection"


def test_openai_rejects_tools() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"tools": [{"type": "function", "name": "x"}]},
            }
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_operation"


def test_openai_commit_without_audio_is_graceful_and_preserves_session() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
        socket.send_json({"type": "input_audio_buffer.commit"})
        committed = socket.receive_json()
        assert committed["type"] == "input_audio_buffer.committed"
        created = socket.receive_json()
        assert created["type"] == "conversation.item.created"
        assert created["item"]["content"][0]["transcript"] == ""
        completed = socket.receive_json()
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert completed["transcript"] == ""

        # Session remains valid for subsequent audio
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        events = []
        while True:
            event = socket.receive_json()
            events.append(event["type"])
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
        assert "input_audio_buffer.committed" in events
        assert "conversation.item.input_audio_transcription.completed" in events


def test_openai_rejects_unsupported_client_event() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json({"type": "conversation.item.delete", "item_id": "x"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_operation"


def test_openai_invalid_audio_fails_closed() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json({"type": "input_audio_buffer.append", "audio": "not-base64!!"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_audio"


def test_openai_realtime_bad_json_is_recoverable() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_text("{invalid json")
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_event"

        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while (
            socket.receive_json()["type"]
            != "conversation.item.input_audio_transcription.completed"
        ):
            pass


def test_openai_text_item_triggers_tts_response() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "tts_001",
                "text": "你好",
            }
        )
        events: list[str] = []
        for _ in range(16):
            event = socket.receive_json()
            events.append(event["type"])
            if event["type"] == "response.done":
                break
        assert events == [
            "response.created",
            "response.output_item.added",
            "response.content_part.added",
            "response.output_audio_transcript.delta",
            "response.output_audio.delta",
            "response.output_audio_transcript.done",
            "response.output_audio.done",
            "response.content_part.done",
            "response.output_item.done",
            "response.done",
        ]


def test_openai_tts_terminal_is_idempotent_when_cancel_races_completed() -> None:
    async def scenario() -> list[str]:
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
        terminal_started = asyncio.Event()
        terminal_release = asyncio.Event()

        async def send(event: dict[str, object]) -> None:
            events.append(event)
            if event.get("type") == "response.done":
                response = event.get("response")
                if isinstance(response, dict) and response.get("status") == "completed":
                    terminal_started.set()
                    await terminal_release.wait()

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_tts_race_test",
            send=send,
        )
        await session.start()
        await session.handle(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        await session.handle(
            {"type": "speechrail.tts.create", "request_id": "race_001", "text": "你好"}
        )
        assert session._tts_task is not None
        await asyncio.wait_for(terminal_started.wait(), timeout=1.0)

        cancel_task = asyncio.create_task(
            session.handle(
                {"type": "speechrail.tts.cancel", "request_id": "race_001"}
            )
        )
        for _ in range(100):
            if session._tts_task is not None and session._tts_task.cancelling():
                break
            await asyncio.sleep(0)
        terminal_release.set()
        await cancel_task
        await session.close()
        return [
            str(event["response"]["status"])
            for event in events
            if event.get("type") == "response.done"
            and isinstance(event.get("response"), dict)
        ]

    assert asyncio.run(scenario()) == ["completed"]


def test_fake_loopback_caller_orchestration_can_cancel_and_restart_tts() -> None:
    synthesizer = LoopbackSpeechSynthesizer()
    client, factory = _client(tts_synthesizer=synthesizer)

    with client.websocket_connect("/v1/realtime") as socket:
        assert socket.receive_json()["type"] == "session.created"
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"

        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        transcription_events: list[dict[str, Any]] = []
        while True:
            event = socket.receive_json()
            transcription_events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
        assert transcription_events[-1]["transcript"] == "你好"

        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "loopback_tts_001",
                "text": "第一句",
            }
        )
        first_tts_events: list[dict[str, Any]] = []
        while True:
            event = socket.receive_json()
            first_tts_events.append(event)
            if event["type"] == "response.output_audio.delta":
                break
        assert any(event["type"] == "response.created" for event in first_tts_events)

        socket.send_json(
            {"type": "speechrail.tts.cancel", "request_id": "loopback_tts_001"}
        )
        cancelled = socket.receive_json()
        assert cancelled["type"] == "response.done"
        assert cancelled["response"]["status"] == "cancelled"

        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "loopback_tts_002",
                "text": "第二句",
            }
        )
        second_tts_events: list[dict[str, Any]] = []
        while True:
            event = socket.receive_json()
            second_tts_events.append(event)
            if event["type"] == "response.done":
                break
        assert any(event["type"] == "response.output_audio.delta" for event in second_tts_events)
        assert second_tts_events[-1]["response"]["status"] == "completed"

        socket.send_json({"type": "input_audio_buffer.clear"})
        assert socket.receive_json()["type"] == "input_audio_buffer.cleared"

    assert len(factory.sessions) == 1
    assert len(factory.released) == 1
    assert synthesizer.calls == ["第一句", "第二句"]


def test_openai_tts_request_id_is_connection_unique() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        socket.send_json(
            {"type": "speechrail.tts.create", "request_id": "unique_001", "text": "你好"}
        )
        while socket.receive_json()["type"] != "response.done":
            pass
        socket.send_json(
            {"type": "speechrail.tts.create", "request_id": "unique_001", "text": "再次"}
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "tts_request_invalid"


def test_openai_tts_request_ledger_rejects_new_ids_when_full() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        for index in range(256):
            socket.send_json(
                {
                    "type": "speechrail.tts.create",
                    "request_id": f"ledger_{index}",
                    "text": "你好",
                }
            )
            while socket.receive_json()["type"] != "response.done":
                pass
        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "ledger_overflow",
                "text": "你好",
            }
        )
        error = socket.receive_json()

    assert error["error"]["code"] == "tts_request_invalid"
    assert "ledger" in error["error"]["message"]


def test_openai_removed_response_create_is_rejected() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
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
# current-only handshake has no conversation.created event
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
    # after context exit the session should be released
    assert len(factory.sessions) == 1
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


def test_openai_disconnect_releases_slot_even_when_commit_blocks() -> None:
    """A client disconnect must release the ASR factory slot promptly even when
    the backend handler is parked inside commit(), instead of leaking it until
    the backend answers (or forever)."""

    client, factory = _client(factory=_BlockedCommitFactory())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        socket.receive_json()  # input_audio_buffer.committed (sent before commit)

    assert len(factory.sessions) == 1
    assert len(factory.released) == 1


def test_openai_segment_formatter_uses_standard_fields() -> None:
    event = transcription_segment(
        session_id="realtime_test",
        item_id="item_test",
        segment_id=7,
        text="你好",
        speaker="spk_01",
        start_ms=0,
        end_ms=1200,
    )

    assert event["type"] == "conversation.item.input_audio_transcription.segment"
    assert event["item_id"] == "item_test"
    assert event["content_index"] == 0
    assert event["id"] == 7
    assert event["text"] == "你好"
    assert event["speaker"] == "spk_01"
    assert event["start"] == 0.0
    assert event["end"] == 1.2


def test_openai_session_update_rejects_unused_speaker_hints() -> None:
    with pytest.raises(RealtimeAdapterError, match="known_speaker"):
        apply_session_update(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {
                        "model": "gpt-4o-transcribe-diarize",
                        "language": "zh",
                        "languages": ["zh", "en"],
                        "keywords": ["SpeechRail"],
                        "timestamp_granularities": ["segment"],
                        "known_speaker_names": ["Alice"],
                        "known_speaker_references": ["ref_opaque"],
                    }
                },
            },
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )


def test_openai_session_update_rejects_word_timestamps_until_wire_support_exists() -> None:
    with pytest.raises(RealtimeAdapterError, match="word-level"):
        apply_session_update(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {
                        "timestamp_granularities": ["segment", "word"],
                    }
                },
            },
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )


def test_openai_realtime_rejects_retired_diarization_request_shape() -> None:
    client, _ = _client(diarization_engine=FakeDiarizationEngine())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"diarization": {"enabled": True}}},
            }
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "invalid_diarization"


def test_openai_realtime_rejects_diarization_without_profile() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"diarization": {"enabled": True}}},
            }
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "diarization_not_available"


def test_openai_realtime_clear_discards_active_audio_session() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.clear"})
        cleared = socket.receive_json()

    assert cleared["type"] == "input_audio_buffer.cleared"
    assert len(factory.released) == 1


def test_openai_realtime_clear_closes_diarization_session() -> None:
    diarization = FakeDiarizationEngine()
    client, _ = _client(diarization_engine=diarization)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"diarization": {"enabled": True}}},
            }
        )
        socket.receive_json()  # transcription_session.updated
        socket.send_json({"type": "input_audio_buffer.clear"})
        assert socket.receive_json()["type"] == "input_audio_buffer.cleared"

    assert diarization.sessions[0].closed is True


def test_openai_realtime_forwards_multiple_partial_events_before_final() -> None:
    client, _ = _client(partials=("你", "你好", "你好啊"))
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        events = []
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break

    assert [event["delta"] for event in events if event["type"].endswith(".delta")] == [
        "你",
        "好",
        "啊",
    ]
    # Verify concatenated deltas reconstruct the full text
    deltas = [event["delta"] for event in events if event["type"].endswith(".delta")]
    assert "".join(deltas) == "你好啊"


def test_realtime_partial_rewrite_is_withheld_until_final() -> None:
    """A non-append partial must not corrupt append-only SDK consumers."""
    client, _ = _client(partials=("abc", "adc"), completed_text="adc")
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        events = []
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break

    deltas = [event["delta"] for event in events if event["type"].endswith(".delta")]
    assert deltas == ["abc"]
    assert events[-1]["transcript"] == "adc"


def test_realtime_consecutive_commits_have_distinct_item_ids() -> None:
    client, _ = _client()
    created_ids: list[str] = []
    committed_ids: list[str] = []
    completed_ids: list[str] = []
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        for _ in range(2):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
            )
            socket.send_json({"type": "input_audio_buffer.commit"})
            while True:
                event = socket.receive_json()
                if event["type"] == "input_audio_buffer.committed":
                    committed_ids.append(event["item_id"])
                elif event["type"] == "conversation.item.created":
                    created_ids.append(event["item"]["id"])
                elif event["type"] == "conversation.item.input_audio_transcription.completed":
                    completed_ids.append(event["item_id"])
                    break

    assert len(set(committed_ids)) == 2
    assert committed_ids == created_ids == completed_ids


def test_realtime_session_update_preserves_effective_turn_detection() -> None:
    client, _ = _client()
    vad = {"type": "server_vad", "threshold": 0.6, "prefix_padding_ms": 300}
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {"type": "transcription_session.update", "session": {"turn_detection": vad}}
        )
        assert socket.receive_json()["session"]["turn_detection"] == vad
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"language": "zh"}},
            }
        )
        updated = socket.receive_json()

    assert updated["session"]["turn_detection"] == vad


def test_realtime_rejects_nested_legacy_audio_session() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "type": "transcription",
                    "audio": {
                        "input": {
                            "format": {"type": "audio/pcm", "rate": 24000},
                            "transcription": {"model": "gpt-4o-transcribe", "language": "zh"},
                            "turn_detection": None,
                        }
                    },
                },
            }
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "unsupported_operation"


def test_pcm24k_converter_is_frame_partition_invariant() -> None:
    pcm = b"".join(index.to_bytes(2, "little", signed=True) for index in range(1200))
    one_frame = Pcm16RateConverter(input_rate=24_000).convert(pcm)
    split_converter = Pcm16RateConverter(input_rate=24_000)
    split_frames = b"".join(
        split_converter.convert(pcm[start : start + width])
        for start, width in ((0, 214), (214, 782), (996, 1404))
    )

    assert split_frames == one_frame


def test_realtime_diarization_receives_partitioned_pcm_identically() -> None:
    pcm = b"".join(index.to_bytes(2, "little", signed=True) for index in range(1200))

    def capture(frames: tuple[bytes, ...]) -> bytes:
        engine = FakeDiarizationEngine()
        client, _ = _client(diarization_engine=engine)
        with client.websocket_connect("/v1/realtime") as socket:
            socket.receive_json()
            socket.send_json(
                {
                    "type": "transcription_session.update",
                    "session": {
                        "input_audio_format": "pcm16",
                        "input_audio_transcription": {
                            "model": "gpt-4o-transcribe",
                            "language": "zh",
                        },
                        "turn_detection": None,
                        "speechrail": {"diarization": {"enabled": True}},
                    },
                }
            )
            assert socket.receive_json()["type"] == "transcription_session.updated"
            for frame in frames:
                socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(frame)})
            socket.send_json({"type": "input_audio_buffer.commit"})
            while (
                socket.receive_json()["type"]
                != "conversation.item.input_audio_transcription.completed"
            ):
                pass
        return b"".join(engine.sessions[0].received)

    one_frame = capture((pcm,))
    partitioned = capture((pcm[:214], pcm[214:996], pcm[996:]))

    assert partitioned == one_frame
    assert len(one_frame) == len(pcm)


def test_realtime_diarization_aligns_frozen_completed_text_without_asr_segments() -> None:
    class RecordingAligner:
        request: AlignmentRequest | None = None

        async def align(self, request: AlignmentRequest) -> AlignmentResult:
            self.request = request
            return AlignmentResult(
                request.epoch,
                request.item_id,
                (TextUnit("direct", 0, len(request.text), request.span),),
            )

    aligner = RecordingAligner()
    client, _ = _client(
        segments=(TranscriptSegment(id=0, start_ms=0, end_ms=100, text="错误分段"),),
        diarization_engine=FakeDiarizationEngine(),
        text_aligner=aligner,
    )
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"diarization": {"enabled": True}}},
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 800)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while (completed := socket.receive_json())["type"] != (
            "conversation.item.input_audio_transcription.completed"
        ):
            pass

    assert aligner.request is not None
    assert aligner.request.text == "你好"
    assert len(aligner.request.pcm16) == 1600
    assert completed["attribution_units"][0]["timing_quality"] == "aligned"


def test_regular_realtime_transcription_never_calls_the_fixed_text_aligner() -> None:
    class CountingAligner:
        calls = 0

        async def align(self, request: AlignmentRequest) -> AlignmentResult:
            self.calls += 1
            return AlignmentResult(
                request.epoch,
                request.item_id,
                (TextUnit("unexpected", 0, len(request.text), request.span),),
            )

    aligner = CountingAligner()
    client, _ = _client(
        diarization_engine=FakeDiarizationEngine(), text_aligner=aligner
    )
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 800)})
        socket.send_json({"type": "input_audio_buffer.commit"})
        while (
            socket.receive_json()["type"]
            != "conversation.item.input_audio_transcription.completed"
        ):
            pass

    assert aligner.calls == 0


def test_openai_session_update_rejects_non_string_language_hints() -> None:
    with pytest.raises(RealtimeAdapterError, match="languages must be a string array"):
        apply_session_update(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"languages": ["zh", 1]},
                },
            },
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )


def test_openai_session_update_rejects_invalid_timestamp_granularity() -> None:
    with pytest.raises(RealtimeAdapterError, match="timestamp_granularities"):
        apply_session_update(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"timestamp_granularities": ["character"]},
                },
            },
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        )


def test_openai_session_update_rejects_invalid_diarization_config() -> None:
    with pytest.raises(RealtimeAdapterError, match=r"use session\.speechrail"):
        apply_session_update(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {
                        "diarization": {"enabled": True, "speaker_count_hint": 9},
                    },
                },
            },
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
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        error = socket.receive_json()

    assert error["error"]["code"] == "backend_not_ready"


def test_openai_tts_invalid_audio_emits_stable_error() -> None:
    client, _ = _client(tts_synthesizer=InvalidSpeechSynthesizer())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        socket.receive_json()
        socket.send_json(
            {"type": "speechrail.tts.create", "request_id": "invalid_audio", "text": "你好"}
        )
        while True:
            event = socket.receive_json()
            if event["type"] == "error":
                break

    assert event["error"]["code"] == "tts_audio_invalid"


def test_realtime_empty_tts_cannot_emit_completed_receipt() -> None:
    client, _ = _client(tts_synthesizer=EmptySpeechSynthesizer())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "speechrail": {
                        "tts": {"enabled": True},
                        "render_receipts": {"enabled": True},
                    },
                },
            }
        )
        socket.receive_json()
        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "empty_audio",
                "text": "你好",
            }
        )

        error = None
        done = None
        while done is None:
            event = socket.receive_json()
            if event["type"] == "error":
                error = event
            elif event["type"] == "response.done":
                done = event

    assert error is not None
    assert error["error"]["code"] == "empty_audio"
    assert done["response"]["status"] == "failed"
    receipt = done["speechrail"]["render_receipt"]
    assert receipt["status"] == "error"
    assert receipt["error_code"] == "empty_audio"
    assert receipt["audio"]["sample_count"] == 0


def test_openai_response_cancel_suppresses_audio_and_emits_cancelled_terminal() -> None:
    client, _ = _client(tts_synthesizer=BlockingSpeechSynthesizer())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        socket.receive_json()
        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "cancel_001",
                "text": "你好",
            }
        )
        response_events: list[dict[str, Any]] = []
        while True:
            response_events.append(socket.receive_json())
            if response_events[-1]["type"] == "response.output_audio.delta":
                break

        socket.send_json({"type": "speechrail.tts.cancel", "request_id": "cancel_001"})
        cancelled = socket.receive_json()

    assert cancelled["type"] == "response.done"
    assert cancelled["response"]["status"] == "cancelled"


def test_response_cancel_is_not_blocked_by_hung_asr_commit() -> None:
    """The control lane cancels TTS while the ordered ASR lane awaits a commit."""
    import threading

    client, _ = _client(
        factory=HangingCommitStreamingFactory(),
        tts_synthesizer=BlockingSpeechSynthesizer(),
        settings_kwargs={"request_timeout_seconds": 5.0},
    )
    done = threading.Event()
    outcome: dict[str, object] = {}

    def scenario() -> None:
        try:
            with client.websocket_connect("/v1/realtime") as socket:
                socket.receive_json()
                socket.send_json(
                    {
                        "type": "transcription_session.update",
                        "session": {
                            "input_audio_transcription": {"model": "whisper-1"},
                            "turn_detection": None,
                            "speechrail": {"tts": {"enabled": True}},
                        },
                    }
                )
                socket.receive_json()
                socket.send_json(
                    {
                        "type": "speechrail.tts.create",
                        "request_id": "cancel_hung_commit",
                        "text": "你好",
                    }
                )
                while socket.receive_json()["type"] != "response.output_audio.delta":
                    pass

                socket.send_json(
                    {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
                )
                socket.send_json({"type": "input_audio_buffer.commit"})
                socket.send_json(
                    {
                        "type": "speechrail.tts.cancel",
                        "request_id": "cancel_hung_commit",
                    }
                )
                while True:
                    event = socket.receive_json()
                    if event["type"] == "response.done":
                        outcome["status"] = event["response"]["status"]
                        return
        except Exception as exc:  # pragma: no cover - diagnostic only
            outcome["error"] = repr(exc)
        finally:
            done.set()

    threading.Thread(target=scenario, daemon=True).start()
    assert done.wait(2.0), "response.cancel was blocked by the ASR commit"
    assert outcome == {"status": "cancelled"}


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


def test_response_cancel_waits_for_preceding_audio_append_dispatch() -> None:
    """Cancellation may bypass inference, but cannot pass audio dispatch FIFO."""
    import threading

    client, factory = _client(
        factory=DelayedAppendStreamingFactory(),
        tts_synthesizer=BlockingSpeechSynthesizer(),
    )
    done = threading.Event()
    outcome: dict[str, object] = {}

    def scenario() -> None:
        try:
            with client.websocket_connect("/v1/realtime") as socket:
                socket.receive_json()
                socket.send_json(
                    {
                        "type": "transcription_session.update",
                        "session": {"speechrail": {"tts": {"enabled": True}}},
                    }
                )
                socket.receive_json()
                socket.send_json(
                    {
                        "type": "speechrail.tts.create",
                        "request_id": "cancel_delayed_append",
                        "text": "你好",
                    }
                )
                while socket.receive_json()["type"] != "response.output_audio.delta":
                    pass

                socket.send_json(
                    {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
                )
                socket.send_json(
                    {
                        "type": "speechrail.tts.cancel",
                        "request_id": "cancel_delayed_append",
                    }
                )
                while True:
                    event = socket.receive_json()
                    if event["type"] == "response.done":
                        outcome["append_started"] = bool(
                            factory.sessions and factory.sessions[0].append_started
                        )
                        return
        except Exception as exc:  # pragma: no cover - diagnostic only
            outcome["error"] = repr(exc)
        finally:
            done.set()

    threading.Thread(target=scenario, daemon=True).start()
    assert done.wait(2.0), "response.cancel did not finish after the preceding append"
    assert outcome == {"append_started": True}


def test_realtime_tts_total_deadline_covers_generation() -> None:
    client, _ = _client(
        tts_synthesizer=HangingSpeechSynthesizer(),
        settings_kwargs={"request_timeout_seconds": 0.01},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        socket.receive_json()
        socket.send_json(
            {"type": "speechrail.tts.create", "request_id": "deadline", "text": "你好"}
        )
        events: list[dict[str, Any]] = []
        while True:
            events.append(socket.receive_json())
            if events[-1]["type"] == "response.done":
                break

    assert events[-2]["type"] == "error"
    assert events[-2]["error"]["code"] == "backend_timeout"
    assert events[-1]["type"] == "response.done"
    assert events[-1]["response"]["status"] == "failed"


def test_openai_query_model_echoed_in_session_created() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime?model=whisper-1") as socket:
        created = socket.receive_json()
        assert created["type"] == "session.created"
        assert created["session"]["model"] == "whisper-1"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
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
    assert created["session"]["model"] == "gpt-4o-transcribe-diarize"


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


def test_openai_tts_error_event_correlates_request_id() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "tts_error_42",
                "text": "你好",
            }
        )
        error = socket.receive_json()
    assert error["type"] == "error"
    assert error["error"]["code"] == "tts_not_enabled"
    assert error["error"]["request_id"] == "tts_error_42"


def test_openai_unsupported_language_surfaces_error_event_and_recovers() -> None:
    factory = RejectingLanguageStreamingFactory()
    client, _ = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"language": "xx-qq"}},
            }
        )
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "language_not_supported"
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"language": "zh"}},
            }
        )
        socket.receive_json()  # transcription_session.updated
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
    assert len(factory.sessions) == 1


def test_openai_committed_precedes_transcription_completion() -> None:
    factory = EarlyCompletionStreamingFactory()
    client, _ = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        types: list[str] = []
        while True:
            event = socket.receive_json()
            types.append(event["type"])
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
    assert types[0] == "input_audio_buffer.committed"
    assert "conversation.item.created" in types


def test_openai_transcription_prompt_forwarded_to_streaming_session() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"prompt": "医疗术语"}},
            }
        )
        socket.receive_json()  # transcription_session.updated
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
    assert factory.sessions[0].prompt == "医疗术语"


def test_openai_rejects_oversized_transcription_prompt() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"prompt": "x" * 2001}},
            }
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
        {
            "type": "transcription_session.update",
            "session": {"speechrail": {"tts": {"enabled": True}}},
        }
    )
    socket.receive_json()  # type: ignore[attr-defined] transcription_session.updated
    payload: dict[str, object] = {
        "type": "speechrail.tts.create",
        "request_id": f"tts_test_{time.monotonic_ns()}",
        "text": "你好",
    }
    if response_body is not None:
        payload.update(response_body)
    socket.send_json(payload)  # type: ignore[attr-defined]
    events: list[dict[str, object]] = []
    while True:
        event = socket.receive_json()  # type: ignore[attr-defined]
        events.append(event)
        if event["type"] in {"response.done", "error"}:
            return events


def _quality_model_settings() -> tuple[dict[str, Any], str]:
    catalog = load_catalog()
    preset = catalog.preset("quality")
    assert preset.tts_clone is not None
    artifact = next(item for item in catalog.artifacts if item.key == preset.tts)
    return (
        {
            "qwen3_model_dir": Path(preset.asr),
            "qwen3_tts_model_dir": Path(preset.tts),
            "qwen3_tts_clone_model_dir": Path(preset.tts_clone),
        },
        artifact.revision,
    )


def test_realtime_model_revision_pin_is_negotiated_and_forwarded() -> None:
    settings_kwargs, revision = _quality_model_settings()
    synthesizer = RecordingSpeechSynthesizer()
    client, _ = _client(
        tts_synthesizer=synthesizer,
        settings_kwargs=settings_kwargs,
    )
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "speechrail": {"model_revision": {"expected": revision}}
                },
            }
        )
        updated = socket.receive_json()
        assert updated["type"] == "transcription_session.updated"
        assert updated["session"]["speechrail"]["model_revision"] == {
            "expected": revision,
            "catalog_revision": revision,
        }
        events = _drive_tts(socket)

    assert events[-1]["type"] == "response.done"
    assert synthesizer.requests[0].expected_model_revision == revision


def test_realtime_model_revision_pin_rejects_stale_revision_before_tts() -> None:
    settings_kwargs, revision = _quality_model_settings()
    synthesizer = RecordingSpeechSynthesizer()
    client, _ = _client(
        tts_synthesizer=synthesizer,
        settings_kwargs=settings_kwargs,
    )
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "speechrail": {"model_revision": {"expected": "0" * 40}}
                },
            }
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "model_revision_conflict"

        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "speechrail": {"model_revision": {"expected": revision}}
                },
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        events = _drive_tts(socket)

    assert events[-1]["type"] == "response.done"
    assert len(synthesizer.requests) == 1
    assert synthesizer.requests[0].expected_model_revision == revision


@pytest.mark.parametrize(
    "model_revision",
    [
        {"expected": "A" * 40},
        {"expected": "0" * 39},
        {"expected": 42},
        {"unexpected": "0" * 40},
        "0" * 40,
    ],
)
def test_realtime_model_revision_pin_rejects_invalid_shape(model_revision: object) -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"model_revision": model_revision}},
            }
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "invalid_model_revision"


def test_realtime_tts_worker_unavailable_publishes_retryable_busy_error() -> None:
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
                batch_transcriber=FakeTranscriber(),
                tts_synthesizer=UnavailableSpeechSynthesizer(),
                realtime_asr_factory=FakeStreamingFactory(),
            ),
        )
        events: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> None:
            events.append(event)

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_test",
            send=send,
        )
        await session.start()
        await session.handle(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        await session.handle(
            {"type": "speechrail.tts.create", "request_id": "busy", "text": "你好"}
        )
        assert session._tts_task is not None
        await session._tts_task
        await session.close()
        return events

    events = asyncio.run(scenario())
    error = next(event for event in events if event["type"] == "error")
    assert error["error"]["code"] == "backend_busy"
    assert error["speechrail"] == {
        "busy_reason": "backend_unavailable",
        "retryable": True,
        "retry_hint": "retry_after_worker_recovery",
    }
    assert events[-1]["type"] == "response.done"
    assert events[-1]["response"]["status"] == "failed"
    assert "private detail" not in repr(events)


@pytest.mark.parametrize("failure_type", [RuntimeError, ValueError])
def test_realtime_unknown_tts_failures_emit_sanitized_backend_terminal(
    failure_type: type[Exception], capsys: pytest.CaptureFixture[str]
) -> None:
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
                batch_transcriber=FakeTranscriber(),
                tts_synthesizer=FailingSpeechSynthesizer(
                    failure_type("/private/model/path and worker detail")
                ),
                realtime_asr_factory=FakeStreamingFactory(),
            ),
        )
        events: list[dict[str, object]] = []

        async def send(event: dict[str, object]) -> None:
            events.append(event)

        session = OpenAIRealtimeSession(
            services,
            session_id="realtime_test",
            send=send,
        )
        await session.start()
        await session.handle(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        await session.handle(
            {"type": "speechrail.tts.create", "request_id": "failure", "text": "你好"}
        )
        assert session._tts_task is not None
        await asyncio.wait_for(session._tts_task, timeout=1)
        await session.close()
        return events

    events = asyncio.run(scenario())
    error = next(event for event in events if event["type"] == "error")
    assert error["error"]["code"] == "backend_error"
    assert error["error"]["message"] == "TTS response failed"
    assert events[-1]["type"] == "response.done"
    assert events[-1]["response"]["status"] == "failed"
    assert "private/model/path" not in repr(events)
    assert "worker detail" not in capsys.readouterr().err


def test_realtime_session_update_voice_alias_resolves_to_registered_preset() -> None:
    synthesizer = RecordingSpeechSynthesizer()
    client, _ = _client(tts_synthesizer=synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        events = _drive_tts(socket, {"voice": "nova"})
    assert events[-1]["type"] == "response.done"
    assert synthesizer.requests[0].voice == "vivian"


def test_realtime_tts_uses_namespaced_response_speed() -> None:
    synthesizer = RecordingSpeechSynthesizer()
    client, _ = _client(tts_synthesizer=synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        events = _drive_tts(
            socket,
            {
                "voice": "warm",
                "speed": 1.35,
            },
        )

    assert events[-1]["type"] == "response.done"
    assert synthesizer.requests[0].speed == pytest.approx(1.35)


@pytest.mark.parametrize("speed", [0.24, 4.01, True, "fast"])
def test_realtime_tts_rejects_invalid_namespaced_response_speed(speed: object) -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        events = _drive_tts(socket, {"speed": speed})

    assert events[-1]["type"] == "error"
    assert events[-1]["error"]["code"] == "tts_request_invalid"


def test_realtime_tts_rejects_unknown_voice_and_session_survives() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        unavailable = _drive_tts(socket, {"voice": "definitely-not-a-voice"})
        assert unavailable[-1]["error"]["code"] == "voice_not_found"
        fallback = _drive_tts(socket, {"voice": "warm"})
        assert fallback[-1]["type"] == "response.done"


def test_realtime_rejects_custom_voice_unavailable_for_active_weights(
    tmp_path: Path,
) -> None:
    preset = load_catalog().preset("light")
    client, _ = _client(
        settings_kwargs={
            "qwen3_model_dir": tmp_path / preset.asr,
            "qwen3_tts_model_dir": tmp_path / preset.tts,
        }
    )
    registry = get_voice_registry()
    voice_id = "test_unavailable_realtime_voice"
    registry.create_custom_profile(
        name="Realtime 不可用测试音色",
        instruction="自然清晰的中文女声。",
        voice_id=voice_id,
    )
    try:
        with client.websocket_connect("/v1/realtime") as socket:
            created = socket.receive_json()
            assert created["session"]["speech_capabilities"] == {
                "available": True,
                "variant": "custom_voice",
                "supports_speaker": True,
                "supports_instruction": False,
                "supports_clone": False,
            }
            unavailable = _drive_tts(socket, {"voice": voice_id})
            assert unavailable[-1]["type"] == "error"
            assert unavailable[-1]["error"]["code"] == "voice_not_available"
            fallback = _drive_tts(socket, {"voice": "alloy"})
            assert fallback[-1]["type"] == "response.done"
    finally:
        registry.delete_custom_profile(voice_id)



def test_realtime_quality_accepts_clone_voice_with_base_capability() -> None:
    preset = load_catalog().preset("quality")
    assert preset.tts_clone is not None
    synthesizer = FakeSpeechSynthesizer()
    client, _ = _client(
        tts_synthesizer=synthesizer,
        settings_kwargs={
            "qwen3_model_dir": Path(preset.asr),
            "qwen3_tts_model_dir": Path(preset.tts),
            "qwen3_tts_clone_model_dir": Path(preset.tts_clone),
        },
    )
    registry = get_voice_registry()
    voice_id = "test_realtime_base_clone"
    registry.create_cloned_profile(
        name="Realtime Base Clone",
        ref_text="这是参考文本。",
        audio_bytes=b"RIFF-test-reference",
        voice_id=voice_id,
        duration_seconds=3.0,
    )
    try:
        with client.websocket_connect("/v1/realtime") as socket:
            created = socket.receive_json()
            assert created["session"]["speech_capabilities"]["supports_clone"] is True
            assert created["session"]["speech_capabilities"]["variant"] == "voice_design"
            events = _drive_tts(socket, {"voice": voice_id})
            assert events[-1]["type"] == "response.done"
    finally:
        registry.delete_custom_profile(voice_id)

def test_realtime_response_create_voice_override_resolves_alias_and_type() -> None:
    synthesizer = RecordingSpeechSynthesizer()
    client, _ = _client(tts_synthesizer=synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        events = _drive_tts(socket, {"voice": {"id": "custom"}})
        assert events[-1]["type"] == "error"
        assert events[-1]["error"]["code"] == "tts_request_invalid"
        events = _drive_tts(socket, {"voice": "alloy"})
    assert events[-1]["type"] == "response.done"
    assert synthesizer.requests[0].voice == "serena"


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
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "backend_busy"
        assert error["speechrail"] == {
            "busy_reason": "backend_unavailable",
            "retryable": True,
            "retry_hint": "retry_after_worker_recovery",
        }
        assert factory.released == [factory.sessions[0]]
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "input_audio_buffer.committed":
                break


def test_realtime_session_update_error_message_truncates_client_model() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"model": "x" * 5000}},
            }
        )
        error = socket.receive_json()
    assert error["error"]["code"] == "model_not_found"
    assert len(error["error"]["message"]) < 300


def test_realtime_prompt_exactly_at_limit_forwards_to_session() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"input_audio_transcription": {"prompt": "p" * 2000}},
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "input_audio_buffer.committed":
                break
    assert factory.sessions[0].prompt == "p" * 2000


def test_realtime_tts_delegates_sentence_planning_to_shared_backend() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "planner_001",
                "text": "你好！今天天气真好，我们去散步吧。",
            }
        )
        events: list[str] = []
        deltas: list[dict[str, object]] = []
        for _ in range(32):
            event = socket.receive_json()
            events.append(event["type"])
            if event["type"] == "response.output_audio.delta":
                deltas.append(event)
            if event["type"] == "response.done":
                break

        assert "response.created" in events
        assert "response.output_item.added" in events
        assert "response.content_part.added" in events
        assert len(deltas) == 1
        assert "response.output_audio_transcript.delta" in events
        assert "response.output_audio_transcript.done" in events
        assert "response.output_audio.done" in events
        assert events[-1] == "response.done"


def test_realtime_current_audio_profile_emits_one_current_wire_family() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        events = [event["type"] for event in _drive_tts(socket)]

    assert "response.output_audio.delta" in events
    assert "response.output_audio.done" in events
    assert "response.audio.delta" not in events
    assert "response.audio.done" not in events


def test_realtime_partial_delta_driven_by_periodic_flush() -> None:
    """Verifies that accumulating audio frames drives flush() and produces incremental deltas."""
    client, factory = _client(
        flush_partials=("Hello", "Hello world"),
        settings_kwargs={"qwen3_streaming_chunk_sec": 0.5},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
# current-only handshake has no conversation.created event

        # Send first 16,000 bytes (0.5s PCM16) -> triggers first flush
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 16_000)}
        )
        delta1 = socket.receive_json()
        assert delta1["type"] == "conversation.item.input_audio_transcription.delta"
        assert delta1["delta"] == "Hello"

        # Send second 16,000 bytes -> triggers second flush
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 16_000)}
        )
        delta2 = socket.receive_json()
        assert delta2["type"] == "conversation.item.input_audio_transcription.delta"
        # Must be incremental diff " world", NOT full "Hello world"!
        assert delta2["delta"] == " world"

        assert factory.sessions[0].flushes == 2

        # Final commit completes cleanly
        socket.send_json({"type": "input_audio_buffer.commit"})
        events = []
        while True:
            event = socket.receive_json()
            events.append(event["type"])
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
        assert "input_audio_buffer.committed" in events
        assert "conversation.item.input_audio_transcription.completed" in events


def test_realtime_buffer_overflow_auto_commit_rollover() -> None:
    """Verifies exceeding max_realtime_buffer_bytes triggers auto-commit rollover."""
    client, factory = _client(
        settings_kwargs={"max_realtime_buffer_bytes": 4096, "max_realtime_frame_bytes": 8192}
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
# current-only handshake has no conversation.created event

        # Append 3000 bytes (< 4096)
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 3000)}
        )

        # Append another 2000 bytes (total 5000 > 4096) -> triggers auto-commit rollover
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 2000)}
        )

        # First segment auto-commits cleanly
        committed = socket.receive_json()
        assert committed["type"] == "input_audio_buffer.committed"
        created = socket.receive_json()
        assert created["type"] == "conversation.item.created"
        completed = socket.receive_json()
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

        # The 2000 bytes started a new turn, verify we can commit it
        assert len(factory.sessions) == 2
        socket.send_json({"type": "input_audio_buffer.commit"})
        committed2 = socket.receive_json()
        assert committed2["type"] == "input_audio_buffer.committed"
        socket.receive_json()  # conversation.item.created
        completed2 = socket.receive_json()
        assert completed2["type"] == "conversation.item.input_audio_transcription.completed"


def test_realtime_single_frame_exceeds_max_buffer_bytes() -> None:
    """Verifies single frame exceeding buffer limit is rejected with buffer_too_large."""
    client, _ = _client(
        settings_kwargs={"max_realtime_buffer_bytes": 4096, "max_realtime_frame_bytes": 8192}
    )
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()

        # Single frame of 5000 bytes exceeds 4096 max buffer
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 5000)}
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "buffer_too_large"


def test_realtime_transport_byte_budget_closes_before_queue_growth() -> None:
    client, _ = _client(
        settings_kwargs={"max_realtime_buffer_bytes": 128, "max_realtime_frame_bytes": 128}
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 200)}
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
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"model": "whisper-1"},
                    "turn_detection": None,
                },
            }
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

    def create(self, *, language: str | None, prompt: str) -> _FailingCommitSession:
        session = _FailingCommitSession(
            language=language,
            prompt=prompt,
            segments=self.segments,
            partials=self.partials,
            flush_partials=self.flush_partials,
            fail_state=self.fail_state,
        )
        self.sessions.append(session)
        return session


def test_openai_commit_failure_emits_error_and_releases_slot() -> None:
    """A failed commit must not leak the streaming slot or the governor lane."""
    factory = FailingCommitStreamingFactory()
    client, factory = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"model": "whisper-1"},
                    "turn_detection": None,
                },
            }
        )
        socket.receive_json()  # transcription_session.updated

        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")})
        socket.send_json({"type": "input_audio_buffer.commit"})
        events = [socket.receive_json() for _ in range(2)]
        assert events[0]["type"] == "input_audio_buffer.committed"
        assert events[1]["type"] == "error"
        assert events[1]["error"]["code"] == "backend_timeout"

        assert len(factory.released) == 1

        # The slot is usable again: the next append opens a fresh ASR session
        # and a normal commit round-trips to completion.
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x01\x01")})
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
            if event["type"] == "error":
                raise AssertionError(f"unexpected error event: {event}")
        assert len(factory.sessions) == 2
        assert len(factory.released) == 2


def test_openai_commit_total_deadline_releases_hung_reader_slot() -> None:
    factory = HangingCommitStreamingFactory()
    client, factory = _client(
        factory=factory,
        settings_kwargs={"request_timeout_seconds": 0.01},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"model": "whisper-1"},
                    "turn_detection": None,
                },
            }
        )
        socket.receive_json()  # transcription_session.updated

        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")})
        socket.send_json({"type": "input_audio_buffer.commit"})
        events = [socket.receive_json() for _ in range(2)]

        assert events[0]["type"] == "input_audio_buffer.committed"
        assert events[1]["error"]["code"] == "backend_timeout"
        assert len(factory.released) == 1


def test_realtime_vad_speech_end_does_not_drop_chunk_audio() -> None:
    """The chunk where VAD fires speech_ended must still be appended before commit."""
    from test_realtime_vad_bargein import _silence_pcm, _sine_pcm

    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.3,
                        "prefix_padding_ms": 0,
                        "silence_duration_ms": 96,
                    }
                },
            }
        )
        socket.receive_json()  # transcription_session.updated

        frame = _sine_pcm(440, 32, 10000.0)
        silence = _silence_pcm(32)

        def audio_b64(raw: bytes) -> str:
            return base64.b64encode(raw).decode("ascii")

        # Three loud frames: the third crosses the debounce and emits speech_started.
        for _ in range(3):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": audio_b64(frame)}
            )
        while True:
            if socket.receive_json()["type"] == "input_audio_buffer.speech_started":
                break

        # Three silent frames: the third emits speech_ended and commits. Every
        # chunk, including the commit chunk, must have reached the ASR session.
        for _ in range(3):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": audio_b64(silence)}
            )
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
            if event["type"] == "error":
                raise AssertionError(f"unexpected error event: {event}")

        received = [chunk for session in factory.sessions for chunk in session.received]
        # Byte conservation across both VAD paths: all six 32ms chunks reach
        # the ASR (the admission path batches the activation pre-roll into a
        # single append, so count bytes rather than append calls).
        total = sum(len(chunk) for chunk in received)
        assert total == 6 * 1024, f"expected 6144 audio bytes appended, got {total}"
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
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"model": "whisper-1"},
                    "turn_detection": None,
                },
            }
        )
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
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


def test_openai_client_event_queue_overflow_closes_session() -> None:
    """A stalled handler must not buffer client audio without bound.

    The whole interaction runs on a daemon thread with a bounded wait: the
    pre-fix server never closes the session, so receiving would block forever.
    """
    import threading

    factory = HangingCommitStreamingFactory()
    client, _ = _client(factory=factory)
    done = threading.Event()
    outcome: dict[str, object] = {}

    def scenario() -> None:
        try:
            with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
                socket.receive_json()
                socket.send_json(
                    {
                        "type": "transcription_session.update",
                        "session": {
                            "input_audio_transcription": {"model": "whisper-1"},
                            "turn_detection": None,
                        },
                    }
                )
                socket.receive_json()
                socket.send_json(
                    {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
                )
                socket.send_json({"type": "input_audio_buffer.commit"})
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
    """R0/R2: Pure silence under server_vad must never trigger ASR text before commit."""
    client, factory = _client(
        emit_text_on_flush="嗯",
        settings_kwargs={
            "qwen3_streaming_chunk_sec": 1.0,
            "realtime_speech_admission_enabled": True,
        },
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 400,
                    }
                },
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"

        # 1.0s chunk_sec = 32000 bytes. Send 40,000 bytes of zero PCM
        silence_chunk = b"\x00\x00" * 320  # 640 bytes (20ms)
        for _ in range(65):  # 41,600 bytes > 32,000 bytes flush threshold
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(silence_chunk)}
            )

        socket.send_json({"type": "input_audio_buffer.commit"})

        received_types: list[str] = []
        while True:
            ev = socket.receive_json()
            received_types.append(ev["type"])
            if ev["type"] == "conversation.item.input_audio_transcription.completed":
                break

        # Under speech admission, silence never flushes ASR or emits deltas
        assert "conversation.item.input_audio_transcription.delta" not in received_types
        # ASR session should not have any appended speech frames
        if factory.sessions:
            assert factory.sessions[0].appends == 0
            assert factory.sessions[0].flushes == 0


def test_server_vad_silence_rollover_has_no_text() -> None:
    """R0/R2: Silence exceeding buffer threshold must not emit non-empty transcripts."""
    client, _ = _client(
        completed_text="嗯",
        settings_kwargs={
            "max_realtime_buffer_bytes": 4000,
            "realtime_speech_admission_enabled": True,
        },
    )
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 400,
                    }
                },
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"

        # Send 6000 bytes of silence
        silence_chunk = b"\x00\x00" * 500  # 1000 bytes
        for _ in range(6):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(silence_chunk)}
            )

        socket.send_json({"type": "input_audio_buffer.commit"})

        events = [socket.receive_json() for _ in range(3)]
        assert events[0]["type"] == "input_audio_buffer.committed"
        assert events[1]["type"] == "conversation.item.created"
        assert events[2]["type"] == "conversation.item.input_audio_transcription.completed"
        # Completed text must be empty for silence!
        assert events[2]["transcript"] == ""


def test_server_vad_silence_explicit_commit_closes_empty() -> None:
    """R0/R2: Explicit commit on silence closes with committed first, then empty completed."""
    client, _ = _client(
        completed_text="嗯",
        settings_kwargs={"realtime_speech_admission_enabled": True},
    )
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 300,
                        "silence_duration_ms": 400,
                    }
                },
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"

        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 500)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})

        events = [socket.receive_json() for _ in range(3)]
        assert events[0]["type"] == "input_audio_buffer.committed"
        assert events[1]["type"] == "conversation.item.created"
        assert events[2]["type"] == "conversation.item.input_audio_transcription.completed"
        assert events[2]["transcript"] == ""


def test_server_vad_admission_admitted_speech_transcription_and_events() -> None:
    """R2: SpeechAdmission accurately admits speech, triggers ASR and yields completed text."""
    from test_realtime_vad_bargein import _silence_pcm, _sine_pcm

    client, factory = _client(
        completed_text="你好世界",
        partials=("你好",),
        settings_kwargs={"realtime_speech_admission_enabled": True},
    )
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.3,
                        "prefix_padding_ms": 100,
                        "silence_duration_ms": 100,
                    }
                },
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"

        # 1. Send some initial silence (3 frames, ~96ms) -> should NOT trigger speech or ASR
        for _ in range(3):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_silence_pcm(32))}
            )

        # 2. Send loud active speech (4 frames, ~128ms) -> triggers speech_started & ASR
        for _ in range(4):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_sine_pcm(440, 32, 10000.0))}
            )

        events_seen = []
        # Receive speech_started
        start_ev = socket.receive_json()
        assert start_ev["type"] == "input_audio_buffer.speech_started"

        # 3. Send silence to trigger speech_ended (4 frames of silence, ~128ms > 100ms)
        for _ in range(4):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_silence_pcm(32))}
            )

        while True:
            ev = socket.receive_json()
            events_seen.append(ev["type"])
            if ev["type"] == "conversation.item.input_audio_transcription.completed":
                assert ev["transcript"] == "你好世界"
                break
            if ev["type"] == "error":
                raise AssertionError(f"unexpected error: {ev}")

        assert "input_audio_buffer.speech_stopped" in events_seen
        assert len(factory.sessions) == 1
        assert factory.sessions[0].commits == 1
        assert len(factory.released) == 1


def test_server_vad_admission_diarization_sample_mapping() -> None:
    """R2: Session sample clock and diarization units accurately preserve timing under admission."""
    from test_diarization_extensions import _FakeDiarizationEngine
    from test_realtime_vad_bargein import _silence_pcm, _sine_pcm

    client, _ = _client(
        completed_text="扩展模式转写",
        diarization_engine=_FakeDiarizationEngine(supports_stream=True),
        settings_kwargs={"realtime_speech_admission_enabled": True},
    )
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.3,
                        "prefix_padding_ms": 100,
                        "silence_duration_ms": 100,
                    },
                    "speechrail": {"diarization": {"enabled": True}},
                },
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"

        # Send 1 second of silence (31 chunks of 32ms = 992ms, 15872 samples)
        for _ in range(31):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_silence_pcm(32))}
            )

        # Send active speech (4 chunks)
        for _ in range(4):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_sine_pcm(440, 32, 10000.0))}
            )

        # Wait for speech_started
        start_ev = socket.receive_json()
        assert start_ev["type"] == "input_audio_buffer.speech_started"
        # Audio start ms should reflect the timeline after prefix padding
        assert start_ev["audio_start_ms"] >= 800

        # Send silence to complete turn
        for _ in range(4):
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_silence_pcm(32))}
            )

        completed_ev = None
        while True:
            ev = socket.receive_json()
            if ev["type"] == "conversation.item.input_audio_transcription.completed":
                completed_ev = ev
                break

        assert completed_ev is not None
        assert completed_ev["transcript"] == "扩展模式转写"
        assert completed_ev["audio_start_sample"] >= 12000
        assert completed_ev["audio_end_sample"] > completed_ev["audio_start_sample"]


def test_manual_rollover_commit_clear_wire_barrier_collects_every_item_once() -> None:
    """Real WebSocket handler + fake ASR; not an acoustic/latency benchmark."""
    from speechrail.realtime.turn_collection import ManualTurnCollector

    client, factory = _client(
        completed_text="same",
        settings_kwargs={"max_realtime_buffer_bytes": 4096, "max_realtime_frame_bytes": 8192},
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

        receive()  # session.created (sequence 1)
        for size in (3000, 2000, 3000):
            collector.note_append()
            socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * size)})
            if size == 2000 or len(observed) > 2:
                for _ in range(3):
                    receive()  # committed, created, completed at each rollover
        collector.begin_close()
        socket.send_json({"type": "input_audio_buffer.commit"})
        socket.send_json({"type": "input_audio_buffer.clear"})
        for _ in range(4):
            final = receive()
        assert final["type"] == "input_audio_buffer.cleared"
        assert collector.result is not None
        assert collector.result.text == "samesamesame"
        assert len(collector.result.item_ids) == 3
        assert len(set(collector.result.item_ids)) == 3
        assert all(
            event.get("previous_item_id") is None
            for event in observed if event["type"] == "input_audio_buffer.committed"
        )
    assert len(factory.sessions) == 3
    assert all(session.closes == 1 for session in factory.sessions)


def test_manual_append_failure_followed_by_clear_never_becomes_final_transcript() -> None:
    from speechrail.realtime.turn_collection import ManualTurnCollector

    client, _ = _client(
        settings_kwargs={"max_realtime_buffer_bytes": 4096, "max_realtime_frame_bytes": 8192}
    )
    collector = ManualTurnCollector(epoch="wire")
    with client.websocket_connect("/v1/realtime") as socket:
        for _ in range(1):
            collector.accept(socket.receive_json(), epoch="wire")
        collector.note_append()
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\0" * 5000)})
        failed = socket.receive_json()
        assert failed["type"] == "error"
        collector.accept(failed, epoch="wire")
        socket.send_json({"type": "input_audio_buffer.clear"})
        cleared = socket.receive_json()
        assert cleared["type"] == "input_audio_buffer.cleared"
        collector.accept(cleared, epoch="wire")
    assert collector.state == "failed" and collector.result is None


@pytest.mark.parametrize("empty", [False, True])
def test_manual_clear_waits_for_terminal_and_preserves_empty_input(empty: bool) -> None:
    from speechrail.realtime.turn_collection import ManualTurnCollector

    client, factory = _client(factory=EarlyCompletionStreamingFactory())
    collector = ManualTurnCollector(epoch="wire")
    with client.websocket_connect("/v1/realtime") as socket:
        for _ in range(1):
            collector.accept(socket.receive_json(), epoch="wire")
        if not empty:
            collector.note_append()
            socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\0" * 1000)})
        collector.begin_close()
        socket.send_json({"type": "input_audio_buffer.commit"})
        socket.send_json({"type": "input_audio_buffer.clear"})
        for _ in range(4):
            event = socket.receive_json()
            if event["type"] == "input_audio_buffer.cleared" and not empty:
                assert factory.sessions[0].closes == 1
            collector.accept(event, epoch="wire")
        assert event["type"] == "input_audio_buffer.cleared"
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
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_transcription": {"model": "whisper-1"},
                    "turn_detection": None,
                },
            }
        )
        collector.accept(socket.receive_json(), epoch="wire")
        collector.note_append()
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\0\0")})
        collector.begin_close()
        socket.send_json({"type": "input_audio_buffer.commit"})
        socket.send_json({"type": "input_audio_buffer.clear"})
        events = [socket.receive_json() for _ in range(3)]
        assert [event["type"] for event in events] == [
            "input_audio_buffer.committed", "error", "input_audio_buffer.cleared",
        ]
        assert events[1]["error"]["code"] == "backend_timeout"
        for event in events:
            collector.accept(event, epoch="wire")
    assert collector.state == "failed"
    assert collector.result is None
    assert len(factory.released) == 1


def test_realtime_render_receipts_are_opt_in_and_completed() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "speechrail": {
                        "tts": {"enabled": True},
                        "render_receipts": {"enabled": True},
                    }
                },
            }
        )
        updated = socket.receive_json()
        assert updated["type"] == "transcription_session.updated"
        receipt_config = updated["session"]["speechrail"]["render_receipts"]
        assert receipt_config["enabled"] is True
        assert receipt_config["integrity_boundary"] == "pcm16_after_websocket_send"

        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "receipt_001",
                "text": "你好",
            }
        )

        done = None
        while done is None:
            event = socket.receive_json()
            if event["type"] == "response.done":
                done = event

    receipt = done["speechrail"]["render_receipt"]
    assert receipt["status"] == "completed"
    assert receipt["response_id"] == done["response"]["id"]
    assert receipt["audio"]["sample_count"] == 1
    assert receipt["audio"]["pcm_sha256"] == hashlib.sha256(b"\x00\x00").hexdigest()
    assert receipt["audio"]["integrity_boundary"] == "pcm16_after_websocket_send"


def test_realtime_render_receipt_binds_observed_runtime_revision() -> None:
    runtime_revision = "rt_" + ("e" * 64)
    client, _ = _client(
        tts_synthesizer=RecordingSpeechSynthesizer(runtime_revision=runtime_revision)
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "speechrail": {
                        "tts": {"enabled": True},
                        "render_receipts": {"enabled": True},
                    }
                },
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        events = _drive_tts(socket)

    receipt = events[-1]["speechrail"]["render_receipt"]
    assert receipt["model"]["runtime_revision"] == runtime_revision


def test_realtime_render_receipt_cancelled_terminal() -> None:
    client, _ = _client(tts_synthesizer=BlockingSpeechSynthesizer())
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "speechrail": {
                        "tts": {"enabled": True},
                        "render_receipts": {"enabled": True},
                    }
                },
            }
        )
        socket.receive_json()
        socket.send_json(
            {
                "type": "speechrail.tts.create",
                "request_id": "receipt_cancel",
                "text": "你好",
            }
        )
        while True:
            event = socket.receive_json()
            if event["type"] == "response.output_audio.delta":
                break

        socket.send_json(
            {"type": "speechrail.tts.cancel", "request_id": "receipt_cancel"}
        )
        cancelled = socket.receive_json()

    assert cancelled["type"] == "response.done"
    assert cancelled["response"]["status"] == "cancelled"
    receipt = cancelled["speechrail"]["render_receipt"]
    assert receipt["status"] == "cancelled"
    assert receipt["error_code"] == "cancelled"
    assert receipt["audio"]["sample_count"] == 1


def test_realtime_response_done_has_no_receipt_without_negotiation() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        socket.receive_json()
        socket.send_json(
            {"type": "speechrail.tts.create", "request_id": "no_receipt", "text": "你好"}
        )
        while True:
            done = socket.receive_json()
            if done["type"] == "response.done":
                break

    assert "render_receipt" not in done.get("speechrail", {})


def test_realtime_render_receipt_extension_rejects_unknown_fields() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "speechrail": {
                        "render_receipts": {
                            "enabled": True,
                            "unexpected": True,
                        }
                    }
                },
            }
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "invalid_render_receipts"
