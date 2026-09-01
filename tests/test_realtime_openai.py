from __future__ import annotations

import asyncio
import base64
from collections.abc import AsyncIterator

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.compatibility.openai_realtime import apply_session_update, transcription_segment
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import (
    AudioChunk,
    RealtimeAsrSession,
    SpeechRequest,
    StreamingAsrEvent,
    TranscriptionRequest,
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


class FakeStreamingSession:
    def __init__(self, *, language: str | None) -> None:
        self.language = language
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
        await self.events_queue.put(StreamingAsrEvent(kind="completed", text="你好", language="zh"))
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
    def __init__(self) -> None:
        self.sessions: list[FakeStreamingSession] = []
        self.released: list[RealtimeAsrSession] = []

    def create(self, *, language: str | None, prompt: str) -> FakeStreamingSession:
        session = FakeStreamingSession(language=language)
        self.sessions.append(session)
        return session

    def release(self, session: RealtimeAsrSession) -> None:
        self.released.append(session)


def _client() -> tuple[TestClient, FakeStreamingFactory]:
    factory = FakeStreamingFactory()
    return (
        TestClient(
            create_app(
                Settings(qwen3_model_dir=None, qwen3_python=None),
                v2_transcriber=FakeTranscriber(),
                tts_synthesizer=FakeSpeechSynthesizer(),
                realtime_asr_factory=factory,
            )
        ),
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
