from __future__ import annotations

import asyncio
import base64
import threading
import time
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import speechrail.application.realtime_openai as realtime_openai_module
from realtime_wire import (
    server_vad,
    session_update,
    tts_append_text,
    tts_finish_text,
    tts_start,
)
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
        socket.send_json({"type": "input_audio_buffer.commit"})

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


def test_openai_commit_releases_streaming_slot_for_next_append() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="whisper-1")
        )
# current-only handshake has no conversation.created event

        def commit_round() -> None:
            socket.send_json(
                {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
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
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="gpt-4o-transcribe")
        )
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
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
                        session_update(model="gpt-4o-transcribe-diarize")
        )
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
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
                        session_update(diarization={"enabled": True})
        )
        assert socket.receive_json()["type"] == "session.updated"
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
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="whisper-1")
        )
        socket.receive_json()  # session.updated
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
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
                        session_update(model="whisper-1", timestamp_granularities=["segment"])
        )
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
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
# current-only handshake has no conversation.created event
        socket.receive_json()  # session.created
        socket.send_json(
                        session_update(model="tts-1")
        )
        error = socket.receive_json()
        assert error["error"]["code"] == "model_not_found"


def test_openai_rejects_unknown_model() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
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
# current-only handshake has no conversation.created event
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
# current-only handshake has no conversation.created event
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
        completed = socket.receive_json()
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert completed["transcript"] == ""

        # Session remains valid for subsequent audio
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        events = []
        while True:
            event = socket.receive_json()
            events.append(event["type"])
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
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
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while (
            socket.receive_json()["type"]
            != "conversation.item.input_audio_transcription.completed"
        ):
            pass


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
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
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
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})

    assert len(factory.sessions) == 1
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
# current-only handshake has no conversation.created event
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
        completed = socket.receive_json()

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
        completed = socket.receive_json()

    assert completed["type"] == "conversation.item.input_audio_transcription.completed"
    assert diarization.sessions[0].closed is True


def test_openai_realtime_forwards_multiple_partial_events_before_final() -> None:
    client, _ = _client(partials=("你", "你好", "你好啊"))
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
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


def test_realtime_hypothesis_revisions_and_final_share_one_asr_fact_series() -> None:
    client, factory = _client(partials=("你好", "你好啊"), completed_text="你好啊")
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        events: list[dict[str, object]] = []
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break

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
    assert [event["stable_prefix_codepoints"] for event in hypotheses] == [0, 2]
    assert {event["utterance_id"] for event in hypotheses} == {completed["item_id"]}
    assert hypotheses[-1]["text"] == completed["transcript"]
    assert len(factory.sessions) == 1


def test_realtime_partial_rewrite_is_withheld_until_final() -> None:
    """A non-append partial must not corrupt append-only SDK consumers."""
    client, _ = _client(partials=("abc", "adc"), completed_text="adc")
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
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
            while (
                socket.receive_json()["type"]
                != "conversation.item.input_audio_transcription.completed"
            ):
                pass
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
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
                        session_update(diarization={"enabled": True})
        )
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 800)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while (completed := socket.receive_json())["type"] != (
            "conversation.item.input_audio_transcription.completed"
        ):
            pass

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
            while (completed := socket.receive_json())["type"] != (
                "conversation.item.input_audio_transcription.completed"
            ):
                pass

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
        while (completed := socket.receive_json())["type"] != (
            "conversation.item.input_audio_transcription.completed"
        ):
            pass
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
            session_update(languages=["zh", 1]),  # type: ignore[list-item]
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


def test_openai_unsupported_language_surfaces_error_event_and_recovers() -> None:
    factory = RejectingLanguageStreamingFactory()
    client, _ = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json(
                        session_update(language="xx-qq")
        )
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "language_not_supported"
        socket.send_json(
                        session_update(language="zh")
        )
        socket.receive_json()  # session.updated
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
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
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "backend_busy"
        # The closed error object folds the retry policy into the message.
        assert "retryable=True" in str(error["error"]["message"])
        assert "hint=retry_after_worker_recovery" in str(error["error"]["message"])
        assert factory.released == [factory.sessions[0]]
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break


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
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
                        session_update(prompt="p" * 2000)
        )
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
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


def test_realtime_partial_delta_driven_by_periodic_flush() -> None:
    """Verifies that accumulating audio frames drives flush() and produces incremental deltas."""
    client, factory = _client(
        flush_partials=("Hello", "Hello world"),
        settings_kwargs={"qwen3_streaming_chunk_duration_ms": 500},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
# current-only handshake has no conversation.created event
# current-only handshake has no conversation.created event

        # 32,000 wire bytes is 16,000 bytes (0.5 s) at the 16 kHz kernel, the
        # configured periodic-flush threshold, so each append flushes once.
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 32_000)}
        )
        hypothesis1 = socket.receive_json()
        assert hypothesis1["type"] == "speechrail.transcription.hypothesis"
        delta1 = socket.receive_json()
        assert delta1["type"] == "conversation.item.input_audio_transcription.delta"
        assert delta1["delta"] == "Hello"

        # Send second 32,000 bytes -> triggers second flush
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 32_000)}
        )
        hypothesis2 = socket.receive_json()
        assert hypothesis2["type"] == "speechrail.transcription.hypothesis"
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

        # Append 4000 wire bytes (< 4096 frame/null limit, ≈2666 kernel bytes)
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 4000)}
        )

        # Another 3000 wire bytes (≈2000 kernel bytes) pushes the streaming
        # buffer past 4096 -> triggers auto-commit rollover
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 3000)}
        )

        # First segment auto-commits cleanly.
        completed = socket.receive_json()
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"

        # The second append started a new turn, verify we can commit it
        assert len(factory.sessions) == 2
        socket.send_json({"type": "input_audio_buffer.commit"})
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


def test_openai_commit_failure_emits_error_and_releases_slot() -> None:
    """A failed commit must not leak the streaming slot or the governor lane."""
    factory = FailingCommitStreamingFactory()
    client, factory = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
# current-only handshake has no conversation.created event
        socket.receive_json()
        socket.send_json(
                        session_update(model="whisper-1")
        )
        socket.receive_json()  # session.updated

        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        socket.send_json({"type": "input_audio_buffer.commit"})
        event = socket.receive_json()
        assert event["type"] == "error"
        assert event["error"]["code"] == "backend_timeout"

        assert len(factory.released) == 1

        # The slot is usable again: the next append opens a fresh ASR session
        # and a normal commit round-trips to completion.
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
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
                        session_update(model="whisper-1")
        )
        socket.receive_json()  # session.updated

        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        socket.send_json({"type": "input_audio_buffer.commit"})
        event = socket.receive_json()
        assert event["error"]["code"] == "backend_timeout"
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

        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
            if event["type"] == "error":
                raise AssertionError(f"unexpected error event: {event}")

        assert len(factory.sessions) == 1
        received_samples = sum(
            len(chunk) // 2 for session in factory.sessions for chunk in session.received
        )
        # Byte conservation across the 24k wire -> 16k kernel boundary: every
        # frame, including the commit frame, is resampled and appended.
        wire_samples = (len(frame) * 3 + len(silence) * 4) // 2
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
                                        session_update(model="whisper-1")
                )
                socket.receive_json()
                socket.send_json(
                    {"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)}
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

        events: list[dict[str, object]] = []
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
        assert [event["type"] for event in events] == [
            "conversation.item.input_audio_transcription.completed"
        ]
        assert events[0]["transcript"] == ""
        # Silence never admitted speech, so no ASR session was ever opened.
        assert factory.sessions == []

def test_server_vad_silence_rollover_has_no_text() -> None:
    """R0/R2: silence past the buffer threshold still produces one empty final."""
    client, _ = _client(
        completed_text="嗯",
        settings_kwargs={
            "max_realtime_buffer_bytes": 4000,
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

        event = socket.receive_json()
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

        event = socket.receive_json()
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

        events: list[dict[str, object]] = []
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                assert event["transcript"] == "你好世界"
                break
            if event["type"] == "error":
                raise AssertionError(f"unexpected error: {event}")

        observed = {event["type"] for event in events}
        assert observed == {
            "speechrail.transcription.hypothesis",
            "conversation.item.input_audio_transcription.delta",
            "conversation.item.input_audio_transcription.completed",
        }
        hypothesis = next(
            event
            for event in events
            if event["type"] == "speechrail.transcription.hypothesis"
        )
        assert hypothesis["text"] == "你好"
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

        completed = None
        # The text final precedes the auxiliary alignment, so wait for the
        # alignment result before asking diarization to publish its units.
        for _ in range(256):
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                completed = event
            elif event["type"] == "speechrail.alignment.done":
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
        settings_kwargs={"max_realtime_buffer_bytes": 3500, "max_realtime_frame_bytes": 8192},
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
        # Two server-side rollover commits plus one explicit commit produce one
        # terminal per item.  Rollover is server-initiated, so the caller must
        # declare its expected item count up front; each 3000-byte append is
        # 2000 kernel bytes, so every append past the first rolls over the
        # 3500-byte streaming buffer.
        for _ in range(3):
            collector.expect_item()
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 3000)})
        for _ in range(2):
            socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00" * 3000)})
            receive()  # rollover terminal
        collector.begin_close()
        socket.send_json({"type": "input_audio_buffer.commit"})
        socket.send_json({"type": "input_audio_buffer.clear"})
        final = receive()  # explicit commit terminal
        assert final["type"] == "conversation.item.input_audio_transcription.completed"
        assert collector.result is not None
        assert collector.result.text == "samesamesame"
        assert len(collector.result.item_ids) == 3
        assert len(set(collector.result.item_ids)) == 3
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
        # No clear acknowledgement on the current wire; a failed append must
        # never turn into a success receipt.
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
        collector.expect_item()
        collector.begin_close()
        socket.send_json({"type": "input_audio_buffer.commit"})
        socket.send_json({"type": "input_audio_buffer.clear"})
        event = socket.receive_json()
        collector.accept(event, epoch="wire")
        assert event["type"] == "conversation.item.input_audio_transcription.completed"
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
        socket.send_json({"type": "input_audio_buffer.clear"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "backend_timeout"
        collector.accept(error, epoch="wire")
    assert collector.state == "failed"
    assert collector.result is None
    assert len(factory.released) == 1
