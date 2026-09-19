from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

import speechrail.domain.tts as voices
from speechrail.app import create_app
from speechrail.config import Settings


def _client_with_private_clone(
    tmp_path: Path,
    monkeypatch,
    *,
    api_key: str | None,
) -> TestClient:
    registry = voices.VoiceRegistry(
        storage_path=tmp_path / "voices.json",
        voices_dir=tmp_path / "voice-assets",
    )
    registry.create_custom_profile(
        name="Private instruction voice",
        instruction="PRIVATE_INSTRUCTION_RECIPE",
        voice_id="private_instruction",
        seed=7,
    )
    registry.create_cloned_profile(
        name="Private clone",
        ref_text="PRIVATE_REFERENCE_TEXT",
        audio_bytes=b"PRIVATE_AUDIO_BYTES",
        voice_id="private_clone",
        duration_seconds=3.0,
    )
    monkeypatch.setattr(voices, "_GLOBAL_VOICE_REGISTRY", registry)
    return TestClient(
        create_app(
            Settings(
                api_key=api_key,
                qwen3_model_dir=None,
                qwen3_python=None,
            )
        )
    )


def test_public_voice_list_is_a_minimal_safe_projection(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client = _client_with_private_clone(tmp_path, monkeypatch, api_key="secret")

    response = client.get("/v1/voices")

    assert response.status_code == 200
    data = response.json()["data"]
    clone = next(item for item in data if item["id"] == "private_clone")
    instruction = next(item for item in data if item["id"] == "private_instruction")
    required = {"id", "name", "available", "variant", "capabilities", "mode"}
    assert required.issubset(clone)
    assert required.issubset(instruction)
    for item in (clone, instruction):
        for private_field in (
            "description",
            "instruction",
            "seed",
            "ref_text",
            "quality",
            "creation",
            "audio_path",
        ):
            assert private_field not in item

    encoded = response.text
    assert "PRIVATE_REFERENCE_TEXT" not in encoded
    assert "PRIVATE_INSTRUCTION_RECIPE" not in encoded
    assert "PRIVATE_AUDIO_BYTES" not in encoded
    assert str(tmp_path) not in encoded


def test_full_voice_detail_requires_configured_auth_and_keeps_management_compatibility(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client = _client_with_private_clone(tmp_path, monkeypatch, api_key="secret")

    unauthorized = client.get("/v1/voices/private_clone")
    assert unauthorized.status_code == 401

    authorized = client.get(
        "/v1/voices/private_clone",
        headers={"Authorization": "Bearer secret"},
    )
    assert authorized.status_code == 200
    payload = authorized.json()
    assert payload["id"] == "private_clone"
    assert payload["ref_text"] == "PRIVATE_REFERENCE_TEXT"
    assert "audio_path" not in payload


def test_detail_remains_loopback_compatible_when_auth_is_not_configured(
    tmp_path: Path,
    monkeypatch,
) -> None:
    client = _client_with_private_clone(tmp_path, monkeypatch, api_key=None)

    response = client.get("/v1/voices/private_clone")

    assert response.status_code == 200
    assert response.json()["ref_text"] == "PRIVATE_REFERENCE_TEXT"
