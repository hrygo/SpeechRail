from __future__ import annotations

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.tts import VoiceRegistry


def _client(tmp_path, monkeypatch):
    registry = VoiceRegistry(
        storage_path=tmp_path / "custom_voices.json",
        voices_dir=tmp_path / "voices",
    )
    monkeypatch.setattr(
        "speechrail.http.routes.system.get_voice_registry",
        lambda: registry,
    )
    app = create_app(
        Settings(
            api_key=None,
            qwen3_model_dir=None,
            qwen3_python=None,
            qwen3_tts_model_dir=None,
            qwen3_tts_python=None,
        )
    )
    return TestClient(app), registry


def test_v2_voice_update_revision_list_and_rollback(tmp_path, monkeypatch):
    client, registry = _client(tmp_path, monkeypatch)
    first = registry.create_custom_profile(
        name="Narrator",
        instruction="first recipe",
        voice_id="narrator",
        seed=1,
    )

    updated = client.patch(
        "/v2/voices/narrator",
        json={
            "instruction": "second recipe",
            "seed": 2,
            "expected_revision": first.revision,
        },
    )
    assert updated.status_code == 200
    second_revision = updated.json()["voice_revision"]
    assert second_revision != first.revision

    stale = client.patch(
        "/v2/voices/narrator",
        json={
            "instruction": "stale write",
            "expected_revision": first.revision,
        },
    )
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "voice_revision_conflict"

    revisions = client.get("/v2/voices/narrator/revisions")
    assert revisions.status_code == 200
    payload = revisions.json()
    assert {item["revision"] for item in payload["data"]} == {
        first.revision,
        second_revision,
    }
    assert "first recipe" not in revisions.text
    assert "second recipe" not in revisions.text
    assert sum(bool(item["current"]) for item in payload["data"]) == 1

    rollback = client.post(
        "/v2/voices/narrator/rollback",
        json={
            "target_revision": first.revision,
            "expected_revision": second_revision,
        },
    )
    assert rollback.status_code == 200
    assert rollback.json()["voice_revision"] == first.revision
    assert registry.get_profile("narrator").instruction == "first recipe"


def test_v2_revoked_revision_cannot_be_rolled_back(tmp_path, monkeypatch):
    client, registry = _client(tmp_path, monkeypatch)
    first = registry.create_custom_profile(
        name="Narrator",
        instruction="first recipe",
        voice_id="narrator",
        seed=1,
    )
    second = registry.update_custom_profile(
        "narrator",
        instruction="second recipe",
        expected_revision=first.revision,
    )

    revoked = client.post(
        f"/v2/voices/narrator/revisions/{first.revision}/revoke"
    )
    assert revoked.status_code == 200
    assert revoked.json()["revoked"] is True

    rollback = client.post(
        "/v2/voices/narrator/rollback",
        json={
            "target_revision": first.revision,
            "expected_revision": second.revision,
        },
    )
    assert rollback.status_code == 409
    assert rollback.json()["error"]["code"] == "voice_revoked"
