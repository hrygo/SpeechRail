from __future__ import annotations

import asyncio
import base64
import time
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from speechrail.application.realtime_openai import Pcm16RateConverter
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    apply_session_update,
    transcription_segment,
)
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.diarization import (
    DiarizationAssignment,
    DiarizationError,
    DiarizationSpeaker,
    DiarizationUpdate,
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

    async def append_audio(self, audio: bytes) -> None:
        self.received.append(audio)

    async def annotate(self, segments):
        return DiarizationUpdate(
            assignments=tuple(
                DiarizationAssignment(
                    segment_id=segment.id,
                    speakers=(
                        DiarizationSpeaker(
                            id=f"spk_{index + 1:02d}", confidence=0.95
                        ),
                    ),
                )
                for index, segment in enumerate(segments)
            )
        )

    async def finalize(self) -> DiarizationUpdate:
        return DiarizationUpdate()

    async def close(self) -> None:
        self.closed = True


class FakeDiarizationEngine:
    def __init__(self, *, supports_stream: bool = True) -> None:
        self.supports_stream = supports_stream
        self.sessions: list[FakeDiarizationSession] = []

    def create(self, *, config):
        session = FakeDiarizationSession()
        self.sessions.append(session)
        return session

    def create_stream(self, *, config):
        session = FakeDiarizationSession()
        self.sessions.append(session)
        return session


class FailingDiarizationSession(FakeDiarizationSession):
    async def annotate(self, segments):
        raise DiarizationError("invalid diarization output", code="diarization_invalid_output")


class FailingDiarizationEngine:
    def create(self, *, config):
        return FailingDiarizationSession()


def _client(
    *,
    segments: tuple[object, ...] = (),
    partials: tuple[str, ...] = (),
    flush_partials: tuple[str, ...] = (),
    completed_text: str = "你好",
    emit_text_on_flush: str | None = None,
    diarization_engine=None,
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


def test_openai_session_created_and_updated() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        created = socket.receive_json()
        assert created["type"] == "session.created"
        assert created["session"]["model"] == "speechrail/qwen3-asr-1.7b"
        assert "capabilities" in created["session"]
        assert created["session"]["turn_detection"] is None

        conversation = socket.receive_json()
        assert conversation["type"] == "conversation.created"

        socket.send_json(
            {
                "type": "session.update",
                "session": {"model": "whisper-1", "turn_detection": None},
            }
        )
        updated = socket.receive_json()
        assert updated["type"] == "session.updated"
        assert updated["session"]["model"] == "whisper-1"


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
            {"type": "response.audio.delta"},
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
        socket.receive_json()  # conversation.created

        socket.send_json(
            {
                "type": "session.update",
                "session": {"model": "whisper-1", "turn_detection": None},
            }
        )
        socket.receive_json()  # session.updated

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


def test_openai_commit_releases_streaming_slot_for_next_append() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"model": "whisper-1", "turn_detection": None},
            }
        )
        socket.receive_json()

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
        socket.receive_json()
        socket.receive_json()
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
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {"type": "session.update", "session": {"model": "gpt-4o-transcribe"}}
        )
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break
        assert len(factory.sessions) == 1


def test_openai_diarized_model_alias_enables_diarization() -> None:
    engine = FakeDiarizationEngine()
    segment = TranscriptSegment(id=1, start_ms=0, end_ms=500, text="你好")
    client, factory = _client(segments=(segment,), diarization_engine=engine)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"model": "gpt-4o-transcribe-diarize"},
            }
        )
        socket.receive_json()
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

    assert len(engine.sessions) == 1
    assert any(event["type"].endswith(".segment") for event in events)
    assert factory.sessions and factory.sessions[0].want_segments is True


def test_openai_commit_without_diarization_does_not_request_segments() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {"type": "session.update", "session": {"model": "whisper-1"}}
        )
        socket.receive_json()
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


def test_openai_realtime_rejects_a_frame_over_the_configured_limit() -> None:
    factory_client, _ = _client()
    with factory_client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"model": "whisper-1"},
            }
        )
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80_001)}
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "frame_too_large"


def test_openai_tts_model_alias_resolves_in_session_update() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json({"type": "session.update", "session": {"model": "tts-1"}})
        updated = socket.receive_json()
        assert updated["type"] == "session.updated"
        assert updated["session"]["model"] == "tts-1"


def test_openai_rejects_unknown_model() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {"type": "session.update", "session": {"model": "gpt-5-fake"}}
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "model_not_found"


def test_openai_rejects_unsupported_turn_detection() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"turn_detection": {"type": "unsupported_mode"}},
            }
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_turn_detection"


def test_openai_rejects_tools() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"tools": [{"type": "function", "name": "x"}]},
            }
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_tools"


def test_openai_commit_without_audio_is_graceful_and_preserves_session() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
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
        socket.receive_json()
        socket.receive_json()
        socket.send_json({"type": "conversation.item.delete", "item_id": "x"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "unsupported_operation"


def test_openai_invalid_audio_fails_closed() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json({"type": "input_audio_buffer.append", "audio": "not-base64!!"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_audio"


def test_openai_realtime_bad_json_is_recoverable() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
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
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "你好"}],
                },
            }
        )
        item_created = socket.receive_json()
        assert item_created["type"] == "conversation.item.created"
        assert item_created["item"]["content"][0]["type"] == "input_text"
        socket.send_json({"type": "response.create"})
        events: list[str] = []
        for _ in range(16):
            event = socket.receive_json()
            events.append(event["type"])
            if event["type"] == "response.done":
                break
        assert "response.created" in events
        assert "response.output_item.added" in events
        assert "response.content_part.added" in events
        assert "response.audio.delta" in events
        assert "response.audio.done" in events
        assert "response.content_part.done" in events
        assert "response.output_item.done" in events
        assert events[-1] == "response.done"


def test_openai_response_create_without_item_fails_closed() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json({"type": "response.create"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_state"


def test_openai_text_item_requires_nonempty_text() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
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
        assert error["error"]["code"] == "invalid_item_content"


def test_openai_session_release_called_on_disconnect() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
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
        socket.receive_json()
        socket.receive_json()
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


def test_openai_session_update_preserves_diarization_and_standard_hints() -> None:
    _, config = apply_session_update(
        {
            "type": "session.update",
            "session": {
                "input_audio_transcription": {
                    "model": "gpt-4o-transcribe-diarize",
                    "language": "zh",
                    "languages": ["zh", "en"],
                    "keywords": ["SpeechRail"],
                    "timestamp_granularities": ["segment"],
                    "diarization": {"enabled": True, "speaker_count_hint": 2},
                    "known_speaker_names": ["Alice"],
                    "known_speaker_references": ["ref_opaque"],
                }
            },
        },
        session_id="realtime_test",
        asr_model="speechrail/qwen3-asr-1.7b",
        tts_model="speechrail/qwen3-tts",
        tts_ready=True,
        registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
        registered_tts=frozenset({"speechrail/qwen3-tts"}),
        tts_voice_ids=frozenset({"default", "warm", "bright", "calm"}),
    )

    assert config["language"] == "zh"
    assert config["languages"] == ["zh", "en"]
    assert config["keywords"] == ["SpeechRail"]
    assert config["timestamp_granularities"] == ["segment"]
    assert config["diarization"]["enabled"] is True
    assert config["diarization"]["speaker_count_hint"] == 2
    assert config["known_speaker_names"] == ["Alice"]
    assert config["known_speaker_references"] == ["ref_opaque"]


def test_openai_realtime_emits_diarized_segments_before_completed_with_ordered_events() -> None:
    from speechrail.domain.contracts import TranscriptSegment

    segments = (
        TranscriptSegment(id=1, start_ms=0, end_ms=800, text="你好"),
        TranscriptSegment(id=2, start_ms=800, end_ms=1600, text="世界"),
    )
    diarization = FakeDiarizationEngine()
    client, _ = _client(segments=segments, diarization_engine=diarization)

    with client.websocket_connect("/v1/realtime") as socket:
        events = [socket.receive_json(), socket.receive_json()]
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "input_audio_transcription": {
                        "model": "gpt-4o-transcribe-diarize",
                        "diarization": {"enabled": True},
                    }
                },
            }
        )
        events.append(socket.receive_json())
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            events.append(event)
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                break

    types = [event["type"] for event in events]
    segment_types = "conversation.item.input_audio_transcription.segment"
    assert types.count(segment_types) == 2
    segment_events = [event for event in events if event["type"] == segment_types]
    assert [event["speaker"] for event in segment_events] == ["spk_01", "spk_02"]
    assert [event["start"] for event in segment_events] == [0.0, 0.8]
    assert types.index(segment_types) < types.index(
        "conversation.item.input_audio_transcription.completed"
    )
    assert [event["sequence"] for event in events] == list(range(1, len(events) + 1))
    assert len({event["event_id"] for event in events}) == len(events)
    assert {event["session_id"] for event in events} == {events[0]["session_id"]}
    assert diarization.sessions[0].received == [b"\x00\x00"]
    assert diarization.sessions[0].closed is True


def test_openai_realtime_rejects_diarization_without_profile() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "input_audio_transcription": {
                        "diarization": {"enabled": True},
                    }
                },
            }
        )
        error = socket.receive_json()

    assert error["type"] == "error"
    assert error["error"]["code"] == "diarization_not_available"


def test_openai_realtime_reports_diarization_backend_error() -> None:
    client, _ = _client(
        segments=(TranscriptSegment(id=1, start_ms=0, end_ms=100, text="你好"),),
        diarization_engine=FailingDiarizationEngine(),
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"input_audio_transcription": {"diarization": {"enabled": True}}},
            }
        )
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "error":
                break

    assert event["error"]["code"] == "diarization_invalid_output"


def test_openai_realtime_clear_discards_active_audio_session() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
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
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"input_audio_transcription": {"diarization": {"enabled": True}}},
            }
        )
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        socket.send_json({"type": "input_audio_buffer.clear"})
        assert socket.receive_json()["type"] == "input_audio_buffer.cleared"

    assert diarization.sessions[0].closed is True


def test_openai_realtime_forwards_multiple_partial_events_before_final() -> None:
    client, _ = _client(partials=("你", "你好", "你好啊"))
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
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
        socket.receive_json()
        socket.receive_json()
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
        socket.receive_json()
        socket.receive_json()
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
        socket.receive_json()
        socket.send_json({"type": "session.update", "session": {"turn_detection": vad}})
        assert socket.receive_json()["session"]["turn_detection"] == vad
        socket.send_json(
            {
                "type": "session.update",
                "session": {"input_audio_transcription": {"language": "zh"}},
            }
        )
        updated = socket.receive_json()

    assert updated["session"]["turn_detection"] == vad


def test_realtime_accepts_current_nested_24khz_transcription_session() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
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
        updated = socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 1200)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while (
            socket.receive_json()["type"]
            != "conversation.item.input_audio_transcription.completed"
        ):
            pass

    assert updated["session"]["turn_detection"] is None
    assert factory.sessions[0].language == "zh"
    assert sum(len(chunk) for chunk in factory.sessions[0].received) == 1600


def test_pcm24k_converter_is_frame_partition_invariant() -> None:
    pcm = b"".join(index.to_bytes(2, "little", signed=True) for index in range(1200))
    one_frame = Pcm16RateConverter(input_rate=24_000).convert(pcm)
    split_converter = Pcm16RateConverter(input_rate=24_000)
    split_frames = b"".join(
        split_converter.convert(pcm[start : start + width])
        for start, width in ((0, 214), (214, 782), (996, 1404))
    )

    assert split_frames == one_frame


def test_openai_session_update_rejects_non_string_language_hints() -> None:
    with pytest.raises(RealtimeAdapterError, match="languages must be a string array"):
        apply_session_update(
            {
                "type": "session.update",
                "session": {
                    "input_audio_transcription": {"languages": ["zh", 1]},
                },
            },
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            tts_model="speechrail/qwen3-tts",
            tts_ready=True,
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
            registered_tts=frozenset({"speechrail/qwen3-tts"}),
            tts_voice_ids=frozenset({"default", "warm", "bright", "calm"}),
        )


def test_openai_session_update_rejects_invalid_timestamp_granularity() -> None:
    with pytest.raises(RealtimeAdapterError, match="timestamp_granularities"):
        apply_session_update(
            {
                "type": "session.update",
                "session": {
                    "input_audio_transcription": {"timestamp_granularities": ["character"]},
                },
            },
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            tts_model="speechrail/qwen3-tts",
            tts_ready=True,
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
            registered_tts=frozenset({"speechrail/qwen3-tts"}),
            tts_voice_ids=frozenset({"default", "warm", "bright", "calm"}),
        )


def test_openai_session_update_rejects_invalid_diarization_config() -> None:
    with pytest.raises(RealtimeAdapterError, match="speaker_count_hint"):
        apply_session_update(
            {
                "type": "session.update",
                "session": {
                    "input_audio_transcription": {
                        "diarization": {"enabled": True, "speaker_count_hint": 9},
                    },
                },
            },
            session_id="realtime_test",
            asr_model="speechrail/qwen3-asr-1.7b",
            tts_model="speechrail/qwen3-tts",
            tts_ready=True,
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
            registered_tts=frozenset({"speechrail/qwen3-tts"}),
            tts_voice_ids=frozenset({"default", "warm", "bright", "calm"}),
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


def test_openai_realtime_rejects_text_item_when_tts_is_not_ready() -> None:
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
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "你好"}],
                },
            }
        )
        error = socket.receive_json()

    assert error["error"]["code"] == "backend_not_ready"


def test_openai_tts_invalid_audio_emits_stable_error() -> None:
    client, _ = _client(tts_synthesizer=InvalidSpeechSynthesizer())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "你好"}],
                },
            }
        )
        socket.receive_json()
        socket.send_json({"type": "response.create"})
        while True:
            event = socket.receive_json()
            if event["type"] == "error":
                break

    assert event["error"]["code"] == "tts_audio_invalid"


def test_openai_response_cancel_suppresses_audio_and_emits_cancelled_terminal() -> None:
    client, _ = _client(tts_synthesizer=BlockingSpeechSynthesizer())
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "你好"}],
                },
            }
        )
        socket.receive_json()
        socket.send_json({"type": "response.create"})
        response_events = [socket.receive_json() for _ in range(4)]
        assert response_events[-1]["type"] == "response.audio.delta"

        socket.send_json({"type": "response.cancel"})
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
                socket.receive_json()
                socket.send_json(
                    {
                        "type": "session.update",
                        "session": {"model": "whisper-1", "turn_detection": None},
                    }
                )
                socket.receive_json()
                socket.send_json(
                    {
                        "type": "conversation.item.create",
                        "item": {
                            "type": "message",
                            "role": "user",
                            "content": [{"type": "input_text", "text": "你好"}],
                        },
                    }
                )
                socket.receive_json()
                socket.send_json({"type": "response.create"})
                while socket.receive_json()["type"] != "response.audio.delta":
                    pass

                socket.send_json(
                    {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
                )
                socket.send_json({"type": "input_audio_buffer.commit"})
                socket.send_json({"type": "response.cancel"})
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


def test_realtime_tts_total_deadline_covers_generation() -> None:
    client, _ = _client(
        tts_synthesizer=HangingSpeechSynthesizer(),
        settings_kwargs={"request_timeout_seconds": 0.01},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "你好"}],
                },
            }
        )
        socket.receive_json()
        socket.send_json({"type": "response.create"})
        events = [socket.receive_json() for _ in range(5)]

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
        socket.receive_json()
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
        socket.receive_json()
        socket.send_json({"type": "definitely-unknown", "event_id": "evt_client_42"})
        error = socket.receive_json()
    assert error["type"] == "error"
    assert error["error"]["code"] == "unknown_event"
    assert error["error"]["event_id"] == "evt_client_42"
    assert error["event_id"] != "evt_client_42"
    assert error["event_id"].startswith("event_")


def test_openai_unsupported_language_surfaces_error_event_and_recovers() -> None:
    factory = RejectingLanguageStreamingFactory()
    client, _ = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
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
                "type": "session.update",
                "session": {"input_audio_transcription": {"language": "zh"}},
            }
        )
        socket.receive_json()
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
        socket.receive_json()
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
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"input_audio_transcription": {"prompt": "医疗术语"}},
            }
        )
        socket.receive_json()
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
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"input_audio_transcription": {"prompt": "x" * 2001}},
            }
        )
        error = socket.receive_json()
    assert error["type"] == "error"
    assert error["error"]["code"] == "prompt_too_long"


class RecordingSpeechSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

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
            "type": "conversation.item.create",
            "item": {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "你好"}],
            },
        }
    )
    socket.receive_json()  # type: ignore[attr-defined]
    payload: dict[str, object] = {"type": "response.create"}
    if response_body is not None:
        payload["response"] = response_body
    socket.send_json(payload)  # type: ignore[attr-defined]
    events: list[dict[str, object]] = []
    while True:
        event = socket.receive_json()  # type: ignore[attr-defined]
        events.append(event)
        if event["type"] in {"response.done", "error"}:
            return events


def test_realtime_session_update_voice_alias_resolves_to_registered_preset() -> None:
    synthesizer = RecordingSpeechSynthesizer()
    client, _ = _client(tts_synthesizer=synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json({"type": "session.update", "session": {"voice": "nova"}})
        assert socket.receive_json()["type"] == "session.updated"
        events = _drive_tts(socket)
    assert events[-1]["type"] == "response.done"
    assert synthesizer.requests[0].voice == "vivian"


def test_realtime_session_update_rejects_unknown_voice_and_session_survives() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {"type": "session.update", "session": {"voice": "definitely-not-a-voice"}}
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "voice_not_found"
        socket.send_json({"type": "session.update", "session": {"voice": "warm"}})
        assert socket.receive_json()["type"] == "session.updated"


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
            }
            socket.receive_json()
            socket.send_json(
                {"type": "session.update", "session": {"voice": voice_id}}
            )
            error = socket.receive_json()
            assert error["type"] == "error"
            assert error["error"]["code"] == "voice_not_available"
            socket.send_json({"type": "session.update", "session": {"voice": "warm"}})
            updated = socket.receive_json()
            assert updated["type"] == "session.updated"
            assert updated["session"]["speech_capabilities"] == created["session"][
                "speech_capabilities"
            ]
            unavailable = _drive_tts(socket, {"voice": voice_id})
            assert unavailable[-1]["type"] == "error"
            assert unavailable[-1]["error"]["code"] == "voice_not_available"
            fallback = _drive_tts(socket, {"voice": "alloy"})
            assert fallback[-1]["type"] == "response.done"
    finally:
        registry.delete_custom_profile(voice_id)


def test_realtime_response_create_voice_override_resolves_alias_and_type() -> None:
    synthesizer = RecordingSpeechSynthesizer()
    client, _ = _client(tts_synthesizer=synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        events = _drive_tts(socket, {"voice": {"id": "custom"}})
        assert events[-1]["type"] == "error"
        assert events[-1]["error"]["code"] == "invalid_voice"
        events = _drive_tts(socket, {"voice": "alloy"})
    assert events[-1]["type"] == "response.done"
    assert synthesizer.requests[0].voice == "serena"


def test_realtime_connect_failure_releases_factory_slot_and_recovers() -> None:
    class ConnectFailureSession(FakeStreamingSession):
        async def connect(self) -> None:
            raise RuntimeError("streaming session.open failed")

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
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "backend_busy"
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
        socket.receive_json()
        socket.send_json({"type": "session.update", "session": {"model": "x" * 5000}})
        error = socket.receive_json()
    assert error["error"]["code"] == "model_not_found"
    assert len(error["error"]["message"]) < 300


def test_realtime_prompt_exactly_at_limit_forwards_to_session() -> None:
    client, factory = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"input_audio_transcription": {"prompt": "p" * 2000}},
            }
        )
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00" * 80)}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        while True:
            event = socket.receive_json()
            if event["type"] == "input_audio_buffer.committed":
                break
    assert factory.sessions[0].prompt == "p" * 2000


def test_realtime_multi_sentence_stream_in_tts() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": "你好！今天天气真好，我们去散步吧。"}
                    ],
                },
            }
        )
        assert socket.receive_json()["type"] == "conversation.item.created"
        socket.send_json({"type": "response.create"})
        events: list[str] = []
        deltas: list[dict[str, object]] = []
        for _ in range(32):
            event = socket.receive_json()
            events.append(event["type"])
            if event["type"] == "response.audio.delta":
                deltas.append(event)
            if event["type"] == "response.done":
                break

        assert "response.created" in events
        assert "response.output_item.added" in events
        assert "response.content_part.added" in events
        assert len(deltas) >= 2  # multiple sentences with breath pauses
        assert "response.audio_transcript.delta" in events
        assert "response.audio_transcript.done" in events
        assert "response.audio.done" in events
        assert events[-1] == "response.done"


def test_realtime_current_audio_profile_emits_one_current_wire_family() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "audio": {"output": {"format": {"type": "audio/pcm", "rate": 24000}}}
                },
            }
        )
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json(
            {
                "type": "conversation.item.create",
                "item": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "你好"}],
                },
            }
        )
        assert socket.receive_json()["type"] == "conversation.item.created"
        socket.send_json({"type": "response.create"})
        events: list[str] = []
        while True:
            event_type = socket.receive_json()["type"]
            events.append(event_type)
            if event_type == "response.done":
                break

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
        socket.receive_json()
        socket.receive_json()

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
        socket.receive_json()
        socket.receive_json()

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
        socket.receive_json()
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
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"model": "whisper-1", "turn_detection": None},
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
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"model": "whisper-1", "turn_detection": None},
            }
        )
        socket.receive_json()

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
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"model": "whisper-1", "turn_detection": None},
            }
        )
        socket.receive_json()

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
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
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
        socket.receive_json()

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
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"model": "whisper-1", "turn_detection": None},
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
                socket.receive_json()
                socket.receive_json()
                socket.send_json(
                    {
                        "type": "session.update",
                        "session": {"model": "whisper-1", "turn_detection": None},
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
        socket.receive_json()  # conversation.created
        socket.send_json(
            {
                "type": "session.update",
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
        assert socket.receive_json()["type"] == "session.updated"

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
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
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
        assert socket.receive_json()["type"] == "session.updated"

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
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
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
        assert socket.receive_json()["type"] == "session.updated"

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
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
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
        assert socket.receive_json()["type"] == "session.updated"

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
    from test_diarization_extensions import EXTENSION, _FakeDiarizationEngine
    from test_realtime_vad_bargein import _silence_pcm, _sine_pcm

    client, _ = _client(
        completed_text="扩展模式转写",
        diarization_engine=_FakeDiarizationEngine(supports_stream=True),
        settings_kwargs={"realtime_speech_admission_enabled": True},
    )
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "turn_detection": {
                        "type": "server_vad",
                        "threshold": 0.3,
                        "prefix_padding_ms": 100,
                        "silence_duration_ms": 100,
                    },
                    "input_audio_transcription": {
                        "diarization": {
                            "enabled": True,
                            "extensions": [EXTENSION],
                        }
                    },
                },
            }
        )
        assert socket.receive_json()["type"] == "session.updated"

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
