from __future__ import annotations

import asyncio
import base64
from collections.abc import AsyncIterator

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from speechrail.application.services import AppOverrides, build_app_services
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    apply_session_update,
    transcription_segment,
)
from speechrail.config import Settings
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
from speechrail.http.routes.realtime_openai import create_openai_realtime_router


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
        segments: tuple[object, ...] = (),
        partials: tuple[str, ...] = (),
    ) -> None:
        self.language = language
        self.segments = segments
        self.partials = partials
        self.received: list[bytes] = []
        self.events_queue: asyncio.Queue[StreamingAsrEvent | None] = asyncio.Queue()
        self._finished = asyncio.Event()

    async def connect(self) -> None:
        return None

    async def append_audio(self, audio: bytes) -> None:
        self.received.append(audio)

    async def flush(self) -> None:
        return None

    async def commit(self) -> None:
        for partial in self.partials:
            await self.events_queue.put(StreamingAsrEvent(kind="partial", text=partial))
        await self.events_queue.put(
            StreamingAsrEvent(
                kind="completed", text="你好", language="zh", segments=self.segments
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
        return None


class FakeStreamingFactory:
    def __init__(
        self, *, segments: tuple[object, ...] = (), partials: tuple[str, ...] = ()
    ) -> None:
        self.segments = segments
        self.partials = partials
        self.sessions: list[FakeStreamingSession] = []
        self.released: list[RealtimeAsrSession] = []

    def create(self, *, language: str | None, prompt: str) -> FakeStreamingSession:
        session = FakeStreamingSession(
            language=language, segments=self.segments, partials=self.partials
        )
        self.sessions.append(session)
        return session

    def release(self, session: RealtimeAsrSession) -> None:
        self.released.append(session)


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
    def __init__(self) -> None:
        self.sessions: list[FakeDiarizationSession] = []

    def create(self, *, config):
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
    diarization_engine=None,
    tts_synthesizer=None,
    api_key: str | None = None,
) -> tuple[TestClient, FakeStreamingFactory]:
    factory = FakeStreamingFactory(segments=segments, partials=partials)
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
        api_key=api_key,
    )
    services = build_app_services(
        settings,
        AppOverrides(
            batch_transcriber=FakeTranscriber(),
            tts_synthesizer=tts_synthesizer or FakeSpeechSynthesizer(),
            realtime_asr_factory=factory,
            diarization_engine=diarization_engine,
        ),
    )
    app = FastAPI()
    app.include_router(create_openai_realtime_router(services))
    return (
        TestClient(app),
        factory,
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
    segment = TranscriptSegment(id="seg_1", start_ms=0, end_ms=500, text="你好")
    client, _ = _client(segments=(segment,), diarization_engine=engine)
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


def test_openai_rejects_server_vad_turn_detection() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json(
            {
                "type": "session.update",
                "session": {"turn_detection": {"type": "server_vad"}},
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


def test_openai_commit_without_audio_fails_closed() -> None:
    client, _ = _client()
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.receive_json()
        socket.send_json({"type": "input_audio_buffer.commit"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_state"


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
        assert "response.output_audio.delta" in events
        assert "response.output_audio.done" in events
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


def test_openai_segment_formatter_uses_standard_fields() -> None:
    event = transcription_segment(
        session_id="realtime_test",
        item_id="item_test",
        segment_id="seg_test",
        text="你好",
        speaker="spk_01",
        start_ms=0,
        end_ms=1200,
    )

    assert event["type"] == "conversation.item.input_audio_transcription.segment"
    assert event["item_id"] == "item_test"
    assert event["content_index"] == 0
    assert event["id"] == "seg_test"
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
        TranscriptSegment(id="seg_1", start_ms=0, end_ms=800, text="你好"),
        TranscriptSegment(id="seg_2", start_ms=800, end_ms=1600, text="世界"),
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
        segments=(TranscriptSegment(id="seg_1", start_ms=0, end_ms=100, text="你好"),),
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
        "你好",
        "你好啊",
    ]


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
        assert response_events[-1]["type"] == "response.output_audio.delta"

        socket.send_json({"type": "response.cancel"})
        cancelled = socket.receive_json()

    assert cancelled["type"] == "response.done"
    assert cancelled["response"]["status"] == "cancelled"
