from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import resolve_voice


class CapturingSpeechSynthesizer:
    def __init__(self) -> None:
        self.requests: list[SpeechRequest] = []

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        self.requests.append(request)

        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id="test", chunk_index=0, audio=b"\x00\x00")

        return chunks()


def _managed_voice_client(tmp_path: Path, preset_id: str) -> TestClient:
    preset = load_catalog().preset(preset_id)
    return TestClient(
        create_app(
            Settings(
                qwen3_model_dir=tmp_path / preset.asr,
                qwen3_python=None,
                qwen3_tts_model_dir=tmp_path / preset.tts,
                qwen3_tts_python=None,
            ),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )


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
    assert [voice["id"] for voice in body["data"] if voice.get("is_system")] == [
        "default",
        "warm",
        "bright",
        "calm",
    ]
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


def test_standard_voice_alias_remains_stable() -> None:
    assert resolve_voice("alloy") == "default"
    assert resolve_voice("coral") == "warm"


@pytest.mark.parametrize(
    ("preset_id", "variant", "supports_speaker", "supports_instruction"),
    [
        ("quality", "voice_design", False, True),
        ("balanced", "custom_voice", True, False),
        ("light", "custom_voice", True, False),
    ],
)
def test_managed_voice_catalog_reports_active_tier_capabilities(
    tmp_path: Path,
    preset_id: str,
    variant: str,
    supports_speaker: bool,
    supports_instruction: bool,
) -> None:
    voices = _managed_voice_client(tmp_path, preset_id).get("/v1/voices").json()["data"]

    assert {voice["variant"] for voice in voices if voice["is_system"]} == {variant}
    assert all(voice["available"] for voice in voices if voice["is_system"])
    assert all(
        voice["capabilities"]
        == {
            "supports_speaker": supports_speaker,
            "supports_instruction": supports_instruction,
        }
        for voice in voices
        if voice["is_system"]
    )


def test_custom_voice_is_unavailable_under_custom_voice_weights(tmp_path: Path) -> None:
    client = _managed_voice_client(tmp_path, "balanced")
    voice_id = "test_custom_voice_capability"
    try:
        created = client.post(
            "/v1/voices",
            json={
                "name": "测试音色",
                "instruction": "自然清晰的中文女声。",
                "id": voice_id,
            },
        ).json()
        assert created["variant"] == "custom_voice"
        assert created["available"] is False
        assert created["capabilities"] == {
            "supports_speaker": False,
            "supports_instruction": False,
        }
    finally:
        client.delete(f"/v1/voices/{voice_id}")


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



def test_custom_voice_lifecycle_create_list_and_delete() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )

    # 1. 创建自定义音色
    resp = client.post(
        "/v1/voices",
        json={
            "name": "知性女声",
            "instruction": "一位温和优雅的中文女性播音员，语速平稳，声音亲切自然。",
            "id": "test_zhixing_voice",
        },
    )
    assert resp.status_code == 201
    created = resp.json()
    assert created["id"] == "test_zhixing_voice"
    assert created["name"] == "知性女声"
    assert created["is_system"] is False

    # 2. 列出音色, 确认包含新建音色
    list_resp = client.get("/v1/voices")
    assert list_resp.status_code == 200
    voice_ids = [v["id"] for v in list_resp.json()["data"]]
    assert "test_zhixing_voice" in voice_ids

    # 3. 尝试删除系统音色, 预期 403 拒绝
    del_sys_resp = client.delete("/v1/voices/default")
    assert del_sys_resp.status_code == 403

    # 4. 删除刚刚创建的自定义音色
    del_resp = client.delete("/v1/voices/test_zhixing_voice")
    assert del_resp.status_code == 200
    assert del_resp.json()["status"] == "deleted"

    # 5. 再次列出, 确认已被移除
    list_resp_after = client.get("/v1/voices")
    after_ids = [v["id"] for v in list_resp_after.json()["data"]]
    assert "test_zhixing_voice" not in after_ids
