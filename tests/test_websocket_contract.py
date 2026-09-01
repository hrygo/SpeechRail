import base64
from collections.abc import Awaitable

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

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
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None, legacy_wlk_enabled=True),
            transcribe=_backend,
        )
    )
    with client.websocket_connect("/v1/realtime/legacy") as socket:
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
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None, legacy_wlk_enabled=True),
            transcribe=_backend,
        )
    )
    with client.websocket_connect("/asr") as socket:
        assert socket.receive_json() == {"type": "config", "mode": "full"}
        socket.send_bytes(b"")
        assert socket.receive_json() == {"type": "ready_to_stop"}


def test_v1_realtime_closes_1013_when_no_backend_is_configured() -> None:
    client = TestClient(create_app(Settings(qwen3_model_dir=None, qwen3_python=None)))

    with (
        pytest.raises(WebSocketDisconnect) as exc_info,
        client.websocket_connect("/v1/realtime/legacy"),
    ):
        pass

    assert exc_info.value.code == 1013


def test_v1_realtime_closes_1008_when_bearer_key_is_invalid() -> None:
    client = TestClient(
        create_app(
            Settings(api_key="secret", qwen3_model_dir=None, qwen3_python=None),
            transcribe=_backend,
        )
    )

    with (
        pytest.raises(WebSocketDisconnect) as exc_info,
        client.websocket_connect("/v1/realtime/legacy"),
    ):
        pass

    assert exc_info.value.code == 1008


def test_v2_realtime_closes_1013_without_any_inference_capability() -> None:
    client = TestClient(create_app(Settings(qwen3_model_dir=None, qwen3_python=None)))

    with (
        pytest.raises(WebSocketDisconnect) as exc_info,
        client.websocket_connect("/v2/realtime"),
    ):
        pass

    assert exc_info.value.code == 1013


def test_v2_realtime_closes_1008_when_bearer_key_is_invalid() -> None:
    class ReadyTts:
        ready = True

    client = TestClient(
        create_app(
            Settings(api_key="secret", qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=ReadyTts(),  # type: ignore[arg-type]
        )
    )

    with (
        pytest.raises(WebSocketDisconnect) as exc_info,
        client.websocket_connect("/v2/realtime"),
    ):
        pass

    assert exc_info.value.code == 1008


def test_legacy_websocket_closes_1008_when_disabled() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None, legacy_wlk_enabled=False),
            transcribe=_backend,
        )
    )

    with (
        pytest.raises(WebSocketDisconnect) as exc_info,
        client.websocket_connect("/asr"),
    ):
        pass

    assert exc_info.value.code == 1008
