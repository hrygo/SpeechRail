from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import VoiceRegistry
from speechrail.domain.tts_pronunciation import PronunciationRegistry


class CaptureSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(
                response_id="resp-test",
                chunk_index=0,
                audio=b"\x00\x00" * 8,
            )

        return chunks()


def _client(
    tmp_path: Path,
    monkeypatch,
) -> tuple[TestClient, CaptureSynthesizer, PronunciationRegistry]:
    preset = load_catalog().preset("quality")
    voice_registry = VoiceRegistry(
        storage_path=tmp_path / "voices.json",
        voices_dir=tmp_path / "voices",
    )
    voice_registry.create_custom_profile(
        name="Narrator",
        instruction="stable",
        voice_id="narrator",
        seed=7,
    )
    pronunciation_registry = PronunciationRegistry(
        tmp_path / "pronunciation.json"
    )
    monkeypatch.setattr(
        "speechrail.domain.tts._GLOBAL_VOICE_REGISTRY",
        voice_registry,
    )
    monkeypatch.setattr(
        "speechrail.http.routes.system.get_pronunciation_registry",
        lambda: pronunciation_registry,
    )
    monkeypatch.setattr(
        "speechrail.http.routes.audio.get_pronunciation_registry",
        lambda: pronunciation_registry,
    )
    synth = CaptureSynthesizer()
    app = create_app(
        Settings(
            qwen3_model_dir=tmp_path / preset.asr,
            qwen3_python=None,
            qwen3_tts_model_dir=tmp_path / preset.tts,
            qwen3_tts_clone_model_dir=(
                tmp_path / preset.tts_clone
                if preset.tts_clone is not None
                else None
            ),
            qwen3_tts_python=None,
        ),
        tts_synthesizer=synth,
    )
    return TestClient(app), synth, pronunciation_registry


def _create_set(client: TestClient) -> str:
    response = client.put(
        "/v1/speechrail/pronunciation-sets/story",
        json={
            "expected_revision": None,
            "entries": [
                {
                    "id": "place",
                    "surface": "长安",
                    "spoken": "常安",
                    "language": "zh",
                    "case_sensitive": True,
                    "word_boundary": False,
                    "source": "user",
                }
            ],
        },
    )
    assert response.status_code == 200
    return response.json()["revision"]


def test_v1_pronunciation_revision_rewrites_actual_synthesis_and_receipt(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, synth, _registry = _client(tmp_path, monkeypatch)
    revision = _create_set(client)

    response = client.post(
        "/v1/audio/speech",
        headers={
            "SpeechRail-Pronunciation-Set": f"story@{revision}",
            "SpeechRail-Receipt-Mode": "integrity",
        },
        json={
            "model": "speechrail/qwen3-tts",
            "input": "去长安",
            "voice": "narrator",
            "response_format": "wav",
            "language": "zh",
        },
    )
    assert response.status_code == 200
    assert synth.requests[-1].text == "去常安。"

    receipt = client.get(
        f"/v1/speechrail/audio/receipts/{response.headers['SpeechRail-Receipt-Id']}"
    ).json()
    assert receipt["text"]["pronunciation_set_id"] == "story"
    assert receipt["text"]["pronunciation_revision"] == revision
    assert receipt["text"]["pronunciation_hit_count"] == 1
    assert receipt["planner"]["planner_version"] == "tts_bounded_v1"
    assert "去长安" not in str(receipt)
    assert "去常安" not in str(receipt)


def test_v1_pronunciation_header_does_not_force_receipt(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, synth, _registry = _client(tmp_path, monkeypatch)
    revision = _create_set(client)
    before = len(synth.requests)

    response = client.post(
        "/v1/audio/speech",
        headers={"SpeechRail-Pronunciation-Set": f"story@{revision}"},
        json={
            "model": "speechrail/qwen3-tts",
            "input": "去长安",
            "voice": "narrator",
            "response_format": "wav",
        },
    )
    assert response.status_code == 200
    assert len(synth.requests) == before + 1
    assert synth.requests[-1].text == "去常安。"
    assert "SpeechRail-Receipt-Id" not in response.headers


def test_pronunciation_management_cas_privacy_and_revoke(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client, _synth, _registry = _client(tmp_path, monkeypatch)
    revision = _create_set(client)

    listing = client.get("/v1/speechrail/pronunciation-sets")
    assert listing.status_code == 200
    assert listing.json()["data"][0]["revision"] == revision
    assert "长安" not in listing.text
    assert "常安" not in listing.text

    stale = client.put(
        "/v1/speechrail/pronunciation-sets/story",
        json={
            "expected_revision": "pr_" + "0" * 32,
            "entries": [],
        },
    )
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "pronunciation_conflict"

    revoke = client.post(
        f"/v1/speechrail/pronunciation-sets/story/revisions/{revision}/revoke"
    )
    assert revoke.status_code == 200

    speech = client.post(
        "/v1/audio/speech",
        headers={"SpeechRail-Pronunciation-Set": f"story@{revision}"},
        json={
            "model": "speechrail/qwen3-tts",
            "input": "去长安",
            "voice": "narrator",
            "response_format": "wav",
        },
    )
    assert speech.status_code == 409
    assert speech.json()["error"]["code"] == "pronunciation_revoked"

    deleted = client.delete("/v1/speechrail/pronunciation-sets/story")
    assert deleted.status_code == 200
