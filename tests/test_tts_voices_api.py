from __future__ import annotations

from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.model_spec import required_spec_artifact
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


def _managed_voice_client(tmp_path: Path, tier: str) -> TestClient:
    asr_key = required_spec_artifact(tier, "asr")  # type: ignore[arg-type]
    tts_key = required_spec_artifact(tier, "tts_custom_voice")  # type: ignore[arg-type]
    base_key = required_spec_artifact(tier, "tts_base")  # type: ignore[arg-type]
    design_key = required_spec_artifact(tier, "voice_design")  # type: ignore[arg-type]
    assert asr_key is not None and tts_key is not None and base_key is not None
    return TestClient(
        create_app(
            Settings(
                qwen3_model_dir=tmp_path / asr_key,
                asr_resident_bytes=1 * 1024**3,
                qwen3_python=None,
                qwen3_tts_model_dir=tmp_path / tts_key,
                tts_resident_bytes=1 * 1024**3,
                qwen3_tts_python=None,
                selection_schema_version=2,
                selection_asr_spec=tier,
                selection_tts_spec=tier,
                asr_artifact_key=asr_key,
                tts_artifact_key=tts_key,
                tts_base_artifact_key=base_key,
                voice_design_artifact_key=design_key,
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
        "serena",
        "vivian",
        "uncle_fu",
        "dylan",
        "eric",
        "ryan",
        "aiden",
        "ono_anna",
        "sohee",
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

    assert "alloy" in aliases["serena"]
    assert {"default", "warm"}.issubset(aliases["serena"])
    assert aliases["uncle_fu"] == {"calm", "fable", "shimmer"}
    assert set().union(*aliases.values()) == {
        "default",
        "warm",
        "bright",
        "calm",
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


def test_voice_catalog_marks_an_explicitly_disabled_system_voice_unavailable() -> None:
    client = TestClient(
        create_app(
            Settings(
                qwen3_model_dir=None,
                qwen3_python=None,
                tts_voice_ids=("serena",),
            ),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )

    voices = {voice["id"]: voice for voice in client.get("/v1/voices").json()["data"]}

    assert voices["serena"]["available"] is True
    assert voices["vivian"]["available"] is False


def test_standard_voice_alias_remains_stable() -> None:
    assert resolve_voice("alloy") == "serena"
    assert resolve_voice("coral") == "serena"
    assert resolve_voice("bright") == "vivian"


@pytest.mark.parametrize(
    "tier",
    ["fast", "quality", "reference"],
)
def test_managed_voice_catalog_reports_active_tier_capabilities(
    tmp_path: Path,
    tier: str,
) -> None:
    voices = _managed_voice_client(tmp_path, tier).get("/v1/voices").json()["data"]

    assert {voice["variant"] for voice in voices if voice["is_system"]} == {
        "custom_voice"
    }
    assert all(voice["available"] for voice in voices if voice["is_system"])
    assert all(
        voice["capabilities"]
        == {
            "supports_speaker": True,
            "supports_instruction": False,
            "supports_clone": False,
        }
        for voice in voices
        if voice["is_system"]
    )


def test_custom_voice_is_unavailable_under_custom_voice_weights(tmp_path: Path) -> None:
    client = _managed_voice_client(tmp_path, "fast")
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
        assert created["variant"] is None
        assert created["available"] is False
        assert created["capabilities"] == {
            "supports_speaker": False,
            "supports_instruction": False,
            "supports_clone": False,
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
    assert synthesizer.requests[0].voice == "vivian"


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


def test_custom_voice_detail_and_metadata_update_round_trip() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )
    voice_id = "test_voice_update_round_trip"
    try:
        created = client.post(
            "/v1/voices",
            json={
                "name": "原始名称",
                "instruction": "自然清晰的中文女声。",
                "id": voice_id,
                "seed": 123,
            },
        )
        assert created.status_code == 201

        detail = client.get(f"/v1/voices/{voice_id}")
        assert detail.status_code == 200
        assert detail.json()["id"] == voice_id

        updated = client.patch(
            f"/v1/voices/{voice_id}",
            json={
                "name": "更新后的名称",
                "instruction": "沉稳、温暖、语速略慢的中文女声。",
                "seed": 2026,
            },
        )
        assert updated.status_code == 200
        assert updated.json()["name"] == "更新后的名称"
        assert updated.json()["instruction"] == "沉稳、温暖、语速略慢的中文女声。"
        assert updated.json()["seed"] == 2026

        listed = {
            voice["id"]: voice for voice in client.get("/v1/voices").json()["data"]
        }
        assert listed[voice_id]["name"] == "更新后的名称"
        assert "seed" not in listed[voice_id]
        assert "instruction" not in listed[voice_id]
        detail_after = client.get(f"/v1/voices/{voice_id}")
        assert detail_after.status_code == 200
        assert detail_after.json()["seed"] == 2026
    finally:
        client.delete(f"/v1/voices/{voice_id}")


def test_voice_detail_and_update_reject_unknown_or_empty_patch() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )

    missing = client.get("/v1/voices/does_not_exist")
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "voice_not_found"

    empty = client.patch("/v1/voices/serena", json={})
    assert empty.status_code == 400
    assert empty.json()["error"]["code"] == "invalid_payload"

    protected = client.patch("/v1/voices/serena", json={"name": "不应修改"})
    assert protected.status_code == 403
    assert protected.json()["error"]["code"] == "voice_update_unsupported"


def test_custom_voice_accepts_and_returns_explicit_seed() -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )
    voice_id = "test_seeded_voice"
    try:
        response = client.post(
            "/v1/voices",
            json={
                "name": "固定种子音色",
                "instruction": "自然清晰的中文女声。",
                "id": voice_id,
                "seed": 12345,
            },
        )

        assert response.status_code == 201
        assert response.json()["seed"] == 12345
        listed = {voice["id"]: voice for voice in client.get("/v1/voices").json()["data"]}
        assert "seed" not in listed[voice_id]
        detail = client.get(f"/v1/voices/{voice_id}")
        assert detail.status_code == 200
        assert detail.json()["seed"] == 12345
    finally:
        client.delete(f"/v1/voices/{voice_id}")


@pytest.mark.parametrize("seed", [-1, 2**32, True, "12345"])
def test_custom_voice_rejects_invalid_seed(seed: object) -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/voices",
        json={
            "name": "非法种子音色",
            "instruction": "自然清晰的中文女声。",
            "id": f"test_invalid_seed_{str(seed).lower()}",
            "seed": seed,
        },
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_seed"


@pytest.mark.parametrize("reserved_id", ["serena", "default", "alloy"])
def test_custom_voice_cannot_override_canonical_or_alias_ids(reserved_id: str) -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/voices",
        json={"name": "冲突音色", "instruction": "自然中文女声。", "id": reserved_id},
    )

    assert response.status_code == 400


def test_custom_voice_rejects_instruction_over_domain_limit() -> None:
    """POST /v1/voices instruction >10k must 400, mirroring SpeechRequest."""
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            tts_synthesizer=CapturingSpeechSynthesizer(),
        )
    )

    response = client.post(
        "/v1/voices",
        json={
            "name": "超长指令音色",
            "instruction": "x" * 10_001,
            "id": "test_overlong_instruction_voice",
        },
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_instruction"
