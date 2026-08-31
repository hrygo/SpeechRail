from __future__ import annotations

from collections.abc import AsyncIterator

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.ports import AudioChunk, SpeechRequest


class FakeSpeechSynthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            assert request.text == "你好"
            assert request.voice == "default"
            yield AudioChunk(response_id="resp-test", chunk_index=0, audio=b"\x00\x00")
            yield AudioChunk(response_id="resp-test", chunk_index=1, audio=b"\x01\x00")

        return chunks()


def test_openai_compatible_speech_endpoint_streams_pcm() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "response_format": "pcm",
        },
    )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/x-pcm")
    assert response.content == b"\x00\x00\x01\x00"


def test_speech_endpoint_returns_stable_not_ready_error_without_backend() -> None:
    client = TestClient(create_app(Settings(qwen3_model_dir=None, qwen3_python=None)))

    response = client.post(
        "/v1/audio/speech",
        json={"model": "speechrail/qwen3-tts", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "backend_not_ready"


def test_speech_endpoint_requires_bearer_key_when_configured() -> None:
    client = TestClient(
        create_app(
            Settings(api_key="secret", qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={"model": "speechrail/qwen3-tts", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_api_key"


def test_speech_endpoint_rejects_unknown_model_before_synthesis() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={"model": "not-a-model", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "model_not_found"


def test_speech_endpoint_validates_speed_at_the_public_boundary() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "default",
            "speed": 9.0,
        },
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"
