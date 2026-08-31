import base64
from collections.abc import Awaitable

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult


def _backend(_: bytes, __: str | None, ___: str) -> Awaitable[TranscriptResult]:
    async def result() -> TranscriptResult:
        return TranscriptResult(
            request_id="ws",
            model_id="speechrail/qwen3-asr-1.7b",
            text="hello",
            language="en",
            duration_ms=1,
        )

    return result()


def test_realtime_websocket_accepts_ordered_events_and_completes_once() -> None:
    client = TestClient(create_app(Settings(), transcribe=_backend))
    with client.websocket_connect("/v1/realtime") as socket:
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {"model": "speechrail/qwen3-asr-1.7b"},
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.created"
        socket.send_json(
            {"type": "input_audio_buffer.append", "audio": base64.b64encode(b"\x00\x00").decode()}
        )
        socket.send_json({"type": "input_audio_buffer.commit"})
        assert (
            socket.receive_json()["type"] == "conversation.item.input_audio_transcription.completed"
        )


def test_legacy_websocket_emits_config_then_ready_to_stop_for_empty_eof() -> None:
    client = TestClient(create_app(Settings(), transcribe=_backend))
    with client.websocket_connect("/asr") as socket:
        assert socket.receive_json() == {"type": "config", "mode": "full"}
        socket.send_bytes(b"")
        assert socket.receive_json() == {"type": "ready_to_stop"}
