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


def test_private_realtime_v2_endpoint_is_not_registered() -> None:
    client = TestClient(create_app(Settings(qwen3_model_dir=None, qwen3_python=None)))

    assert client.get("/v2/realtime").status_code == 404


def test_openai_realtime_endpoint_remains_registered() -> None:
    client = TestClient(create_app(Settings(qwen3_model_dir=None, qwen3_python=None)))

    response = client.get("/v1/realtime")

    assert response.status_code == 404
