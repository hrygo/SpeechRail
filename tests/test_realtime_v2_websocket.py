from __future__ import annotations

import base64

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import TranscriptionRequest
from speechrail.realtime.v2_session import PCM16


class FakeTranscriber:
    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        return TranscriptResult(
            request_id=request.request_id,
            model_id="speechrail/qwen3-asr-1.7b",
            text=f"{len(request.audio)} bytes",
            language=request.language or "auto",
            duration_ms=1,
        )


def _client() -> TestClient:
    return TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            v2_transcriber=FakeTranscriber(),
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


def _pcm16(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")
