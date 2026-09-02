from __future__ import annotations

from collections.abc import AsyncIterator

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.ports import AudioChunk, SpeechRequest


class CapturingSpeechSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id="test", chunk_index=0, audio=b"\x00\x00")

        return chunks()


def test_voice_catalog_exposes_the_configured_preset_profiles() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )

    response = client.get("/v1/voices")

    assert response.status_code == 200
    body = response.json()
    assert body["object"] == "list"
    assert [voice["id"] for voice in body["data"]] == ["default", "warm", "bright", "calm"]
    assert body["data"][0]["is_default"] is True


def test_voice_catalog_exposes_openai_standard_voice_aliases() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )

    body = client.get("/v1/voices").json()
    aliases = {voice["id"]: set(voice["aliases"]) for voice in body["data"]}

    assert "alloy" in aliases["default"]
    assert aliases["calm"] == {"fable", "shimmer"}
    assert set().union(*aliases.values()) == {
        "alloy",
        "ash",
        "ballad",
        "cedar",
        "coral",
        "echo",
        "fable",
        "marin",
        "nova",
        "onyx",
        "sage",
        "shimmer",
        "verse",
    }


def test_rest_speech_resolves_standard_voice_alias_to_preset() -> None:
    synthesizer = CapturingSpeechSynthesizer()
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=synthesizer,
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "nova",
            "response_format": "pcm",
        },
    )

    assert response.status_code == 200
    assert synthesizer.requests[0].voice == "bright"


def test_rest_speech_forwards_language_to_the_typed_synthesizer() -> None:
    synthesizer = CapturingSpeechSynthesizer()
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=synthesizer,
        )
    )

    response = client.post(
        "/v1/audio/speech",
        json={
            "model": "speechrail/qwen3-tts",
            "input": "你好",
            "voice": "warm",
            "language": "zh",
            "response_format": "pcm",
        },
    )

    assert response.status_code == 200
    assert synthesizer.requests[0].language == "zh"

