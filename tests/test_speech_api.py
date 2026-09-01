from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path
from sys import executable

from fastapi.testclient import TestClient

import speechrail.application.services as services_module
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


def test_speech_endpoint_wraps_wav_after_collecting_pcm() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={"model": "speechrail/qwen3-tts", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("audio/wav")
    assert response.content[:4] == b"RIFF"
    assert response.content[8:12] == b"WAVE"
    assert response.content[40:44] == (4).to_bytes(4, "little")
    assert response.content[44:] == b"\x00\x00\x01\x00"


class InvalidDeliverySynthesizer:
    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id="resp-test", chunk_index=0, audio=b"\x00\x00")
            yield AudioChunk(response_id="resp-test", chunk_index=2, audio=b"\x01\x00")

        return chunks()


def test_speech_endpoint_maps_invalid_delivery_to_unified_error_envelope() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=InvalidDeliverySynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={"model": "speechrail/qwen3-tts", "input": "你好", "voice": "default"},
    )

    assert response.status_code == 502
    error = response.json()["error"]
    assert error["code"] == "tts_chunk_order_invalid"
    assert error["type"] == "server_error"
    assert error["retryable"] is True
    assert error["request_id"]


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


def test_speech_endpoint_rejects_voice_outside_server_registry() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None, tts_voice_ids=("default",)),
            tts_synthesizer=FakeSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "free-form-description",
        },
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "voice_not_found"


def test_configured_tts_paths_create_and_lifecycle_manage_private_worker(
    monkeypatch, tmp_path: Path
) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-app"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    instances: list[object] = []

    class FakeConfiguredWorker:
        def __init__(self, config: object) -> None:
            self.config = config
            self.started = False
            self.closed = False
            instances.append(self)

        async def start(self) -> None:
            self.started = True

        async def close(self) -> None:
            self.closed = True

        def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
            async def chunks() -> AsyncIterator[AudioChunk]:
                yield AudioChunk(response_id="resp-configured", chunk_index=0, audio=b"\x00\x00")

            return chunks()

    monkeypatch.setattr(services_module, "Qwen3TtsWorker", FakeConfiguredWorker)
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        qwen3_tts_model_dir=snapshot,
        qwen3_tts_python=Path(executable),
    )

    with TestClient(create_app(settings)) as client:
        response = client.post(
            "/v1/audio/speech",
            json={"model": "speechrail/qwen3-tts", "input": "你好", "voice": "default"},
        )
        assert response.status_code == 200
        assert response.content[:4] == b"RIFF"
        assert instances[0].started is True

    assert instances[0].closed is True
