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
