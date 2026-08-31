from __future__ import annotations

import asyncio
import base64
from collections.abc import AsyncIterator

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.diarization import (
    DiarizationAssignment,
    DiarizationSpeaker,
    DiarizationUpdate,
)
from speechrail.domain.ports import (
    AudioChunk,
    SpeechRequest,
    StreamingAsrEvent,
    TranscriptionRequest,
)
from speechrail.realtime.v2_session import PCM16, PCM16_24K


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
            assert request.text == "你好"
            yield AudioChunk(response_id="internal", chunk_index=0, audio=b"\x00\x00")

        return chunks()


class SlowSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest):
        async def chunks():
            assert request.text == "请取消"
            await asyncio.sleep(1)
            yield AudioChunk(response_id="internal", chunk_index=0, audio=b"\x00\x00")

        return chunks()


def _client() -> TestClient:
    return TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            v2_transcriber=FakeTranscriber(),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )


def test_v2_transcription_flush_and_commit_keep_event_sequence_ordered() -> None:
    client = _client()
    with client.websocket_connect("/v2/realtime") as socket:
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "type": "transcription",
                    "model": "speechrail/qwen3-asr-1.7b",
                    "language": "zh",
                    "audio_format": PCM16,
                    "endpointing": {"mode": "manual"},
                },
            }
        )
        created = socket.receive_json()
        assert created["type"] == "session.created"

        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        ack = socket.receive_json()
        assert ack["type"] == "input_audio_buffer.ack"

        socket.send_json({"type": "input_audio_buffer.flush"})
        completed = socket.receive_json()
        assert completed["type"] == "transcription.completed"
        assert completed["text"] == "2 bytes"

        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x01\x00")}
        )
        socket.receive_json()
        socket.send_json({"type": "input_audio_buffer.commit"})
        final_item = socket.receive_json()
        terminal = socket.receive_json()

        assert final_item["type"] == "transcription.completed"
        assert terminal["type"] == "session.completed"
        assert [created["sequence"], ack["sequence"], completed["sequence"]] == [1, 2, 3]


def test_v2_rejects_audio_before_session_update() -> None:
    client = _client()
    with client.websocket_connect("/v2/realtime") as socket:
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")}
        )
        error = socket.receive_json()

        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_state"


def test_v2_streaming_asr_backend_emits_partial_and_completed_before_commit() -> None:
    class FakeStreamingSession:
        def __init__(self) -> None:
            self.events_queue: asyncio.Queue[StreamingAsrEvent | None] = asyncio.Queue()
            self.received: list[bytes] = []

        async def connect(self) -> None:
            return None

        async def append_audio(self, audio: bytes) -> None:
            self.received.append(audio)

        async def flush(self) -> None:
            await self.events_queue.put(StreamingAsrEvent(kind="partial", text="正在"))
            await self.events_queue.put(
                StreamingAsrEvent(kind="completed", text="正在讲话", language="zh")
            )

        async def commit(self) -> None:
            await self.events_queue.put(None)

        def events(self) -> AsyncIterator[StreamingAsrEvent]:
            async def iterator() -> AsyncIterator[StreamingAsrEvent]:
                while (event := await self.events_queue.get()) is not None:
                    yield event

            return iterator()

        async def close(self) -> None:
            return None

    class FakeStreamingFactory:
        def __init__(self) -> None:
            self.session = FakeStreamingSession()

        def create(self, *, language: str | None, prompt: str) -> FakeStreamingSession:
            assert language == "zh"
            assert prompt == ""
            return self.session

    factory = FakeStreamingFactory()
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None), realtime_asr_factory=factory
        )
    )
    with client.websocket_connect("/v2/realtime") as socket:
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "type": "transcription",
                    "language": "zh",
                    "audio_format": PCM16,
                    "endpointing": {"mode": "manual"},
                },
            }
        )
        assert socket.receive_json()["type"] == "session.created"
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")})
        assert socket.receive_json()["type"] == "input_audio_buffer.ack"
        socket.send_json({"type": "input_audio_buffer.flush"})
        partial = socket.receive_json()
        completed = socket.receive_json()
        assert partial["type"] == "transcription.delta"
        assert partial["text"] == "正在"
        assert completed["type"] == "transcription.completed"
        assert completed["text"] == "正在讲话"
        socket.send_json({"type": "input_audio_buffer.commit"})
        assert socket.receive_json()["type"] == "session.completed"
        assert factory.session.received == [b"\x00\x00"]


def test_v2_streaming_asr_backend_error_is_sent_without_waiting_for_commit() -> None:
    class ErrorStreamingSession:
        async def connect(self) -> None:
            return None

        async def append_audio(self, audio: bytes) -> None:
            del audio

        async def flush(self) -> None:
            return None

        async def commit(self) -> None:
            return None

        def events(self) -> AsyncIterator[StreamingAsrEvent]:
            async def iterator() -> AsyncIterator[StreamingAsrEvent]:
                yield StreamingAsrEvent(kind="error", error_code="wlk_error")

            return iterator()

        async def close(self) -> None:
            return None

    class ErrorStreamingFactory:
        def create(self, *, language: str | None, prompt: str) -> ErrorStreamingSession:
            assert language == "zh"
            assert prompt == ""
            return ErrorStreamingSession()

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            realtime_asr_factory=ErrorStreamingFactory(),
        )
    )
    with client.websocket_connect("/v2/realtime") as socket:
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "type": "transcription",
                    "language": "zh",
                    "audio_format": PCM16,
                    "endpointing": {"mode": "manual"},
                },
            }
        )
        assert socket.receive_json()["type"] == "session.created"

        error = socket.receive_json()

        assert error["type"] == "error"
        assert error["error"]["code"] == "wlk_error"
        assert error["error"]["retryable"] is True


def test_v2_diarization_annotates_completed_segments_and_finalizes_before_eof() -> None:
    class SegmentTranscriber:
        async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
            return TranscriptResult(
                request_id=request.request_id,
                model_id="speechrail/qwen3-asr-1.7b",
                text="两位说话人",
                language="zh",
                duration_ms=100,
                segments=(
                    TranscriptSegment(
                        id="seg-1", start_ms=0, end_ms=100, text="两位说话人"
                    ),
                ),
            )

    class FakeDiarizationSession:
        async def append_audio(self, audio: bytes) -> None:
            assert audio == b"\x00\x00"

        async def annotate(self, segments: tuple[TranscriptSegment, ...]) -> DiarizationUpdate:
            return DiarizationUpdate(
                assignments=(
                    DiarizationAssignment(
                        segment_id=segments[0].id,
                        speakers=(DiarizationSpeaker(id="spk_01", confidence=0.93),),
                    ),
                )
            )

        async def finalize(self) -> DiarizationUpdate:
            return DiarizationUpdate(mapping={"spk_02": "spk_01"})

        async def close(self) -> None:
            return None

    class FakeDiarizationEngine:
        def create(self, *, config: object) -> FakeDiarizationSession:
            assert config.enabled is True
            return FakeDiarizationSession()

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            v2_transcriber=SegmentTranscriber(),
            diarization_engine=FakeDiarizationEngine(),
        )
    )
    with client.websocket_connect("/v2/realtime") as socket:
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "type": "transcription",
                    "language": "zh",
                    "audio_format": PCM16,
                    "diarization": {"enabled": True, "finalize": True},
                },
            }
        )
        assert socket.receive_json()["type"] == "session.created"
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x00\x00")})
        assert socket.receive_json()["type"] == "input_audio_buffer.ack"
        socket.send_json({"type": "input_audio_buffer.flush"})
        completed = socket.receive_json()
        assert completed["segments"][0]["speaker"] == "spk_01"
        assert completed["segments"][0]["speakers"] == [{"id": "spk_01", "confidence": 0.93}]
        socket.send_json({"type": "input_audio_buffer.commit"})
        finalized = socket.receive_json()
        terminal = socket.receive_json()
        assert finalized["type"] == "transcription.diarization.completed"
        assert finalized["mapping"] == {"spk_02": "spk_01"}
        assert terminal["type"] == "session.completed"


def test_v2_speech_streams_ordered_audio_and_completes_on_commit() -> None:
    client = _client()
    with client.websocket_connect("/v2/realtime") as socket:
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "type": "speech",
                    "model": "speechrail/qwen3-tts",
                    "voice": "default",
                    "audio_format": PCM16_24K,
                },
            }
        )
        assert socket.receive_json()["type"] == "session.created"
        socket.send_json({"type": "speech_input.append", "text": "你好"})
        socket.send_json({"type": "speech_input.commit"})

        created = socket.receive_json()
        delta = socket.receive_json()
        completed = socket.receive_json()
        terminal = socket.receive_json()

        assert created["type"] == "response.created"
        assert delta["type"] == "response.audio.delta"
        assert completed["type"] == "response.audio.completed"
        assert terminal["type"] == "session.completed"


def test_v2_speech_cancel_stops_pending_audio_before_the_next_delta() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=SlowSpeechSynthesizer(),
        )
    )
    with client.websocket_connect("/v2/realtime") as socket:
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "type": "speech",
                    "model": "speechrail/qwen3-tts",
                    "voice": "default",
                    "audio_format": PCM16_24K,
                },
            }
        )
        assert socket.receive_json()["type"] == "session.created"
        socket.send_json({"type": "speech_input.append", "text": "请取消"})
        socket.send_json({"type": "speech_input.flush"})

        created = socket.receive_json()
        socket.send_json({"type": "response.cancel", "response_id": created["response_id"]})
        cancelled = socket.receive_json()

        assert created["type"] == "response.created"
        assert cancelled["type"] == "response.audio.cancelled"


def _pcm16(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")
