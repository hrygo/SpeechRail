"""Read-only capability discovery, independent of model startup or private audio."""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import speechrail.domain.tts as voices
from speechrail.app import create_app
from speechrail.config import Settings


def test_v2_snapshot_is_stable_and_legacy_discovery_still_works(
    tmp_path: Path, monkeypatch
) -> None:
    registry = voices.VoiceRegistry(tmp_path / "voices.json")
    monkeypatch.setattr(voices, "_GLOBAL_VOICE_REGISTRY", registry)
    settings = Settings(api_key=None, qwen3_model_dir=None, qwen3_python=None)
    client = TestClient(create_app(settings))
    first = client.get("/v1/speechrail/capabilities")
    assert first.status_code == 200
    again = client.get("/v1/speechrail/capabilities")
    assert first.json() == again.json()
    assert (
        client.get(
            "/v1/speechrail/capabilities",
            headers={"If-None-Match": first.headers["etag"]},
        ).status_code
        == 304
    )
    restart = TestClient(create_app(settings)).get("/v1/speechrail/capabilities").json()
    assert first.json()["catalog_revision"] == restart["catalog_revision"]
    assert first.json()["service_instance_epoch"] != restart["service_instance_epoch"]
    assert client.get("/v1/voices").status_code == 200
    assert client.get("/v1/models").status_code == 200


def test_v2_discovery_uses_configured_auth(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(voices, "_GLOBAL_VOICE_REGISTRY", voices.VoiceRegistry(tmp_path / "v.json"))
    client = TestClient(
        create_app(Settings(api_key="test-key", qwen3_model_dir=None, qwen3_python=None))
    )
    assert client.get("/v1/speechrail/capabilities").status_code == 401
    assert (
        client.get(
            "/v1/speechrail/capabilities",
            headers={"Authorization": "Bearer test-key"},
        ).status_code
        == 200
    )


def _active(tier: str):
    from speechrail.config.model_catalog import load_catalog
    from speechrail.config.selection import ActiveModelCatalog

    catalog = load_catalog()
    preset = catalog.preset(tier)
    artifacts = {item.key: item for item in catalog.artifacts}
    return ActiveModelCatalog(
        profile=tier,
        asr=artifacts[preset.asr],
        tts=artifacts[preset.tts],
        tts_clone=artifacts.get(preset.tts_clone),
        aligner=preset.aligner,
        diarization=preset.diarization,
    )


@pytest.mark.parametrize("tier", ["light", "balanced", "quality"])
@pytest.mark.parametrize("mode", ["system", "instruction", "clone"])
def test_effective_matrix_uses_captured_voice_and_base_lane(
    tier: str, mode: str, monkeypatch
) -> None:
    from speechrail.application.capability_snapshot import build_capability_snapshot

    profile = (
        voices.SYSTEM_VOICE_PROFILES["serena"]
        if mode == "system"
        else voices.VoiceProfile(
            id="test_voice",
            mode=mode,
            instruction="PRIVATE_INSTRUCTION",
            ref_text="PRIVATE_REFERENCE",
            audio_path="/private/reference.wav",
            quality={"raw": "PRIVATE_QUALITY", "status": "pass"},
        )
    )

    # A second lookup could resolve a different registry generation; forbid it.
    def forbidden(*args, **kwargs):
        raise AssertionError("unexpected registry reread")

    monkeypatch.setattr("speechrail.backends.qwen3_voice_binding.get_voice_profile", forbidden)
    data = build_capability_snapshot(
        (profile,),
        _active(tier),
        epoch="epoch",
        ready=True,
        enabled_voices=frozenset({"serena"}),
        sample_rate=24_000,
    )
    entry = data["voices"][0]
    assert entry["voice_revision"] is None
    assert entry["voice_identity_assurance"] == "legacy"
    assert entry["available"] is (tier == "quality" or mode == "system")
    encoded = str(data)
    for secret in ["PRIVATE_INSTRUCTION", "PRIVATE_REFERENCE", "/private/", "PRIVATE_QUALITY"]:
        assert secret not in encoded
    if mode == "clone":
        assert entry["variant"] == ("base" if tier == "quality" else None)
        assert entry["operations"]["http_speech"]["parameters"]["speed"]["values"] == [1.0]
        assert (
            entry["operations"]["http_speech"]["parameters"]["instructions"]["status"]
            == "unsupported"
        )
    elif tier == "quality":
        assert (
            entry["operations"]["http_speech"]["parameters"]["instructions"]["status"]
            == "supported"
        )
    assert entry["operations"]["http_speech"]["parameters"]["seed"]["status"] == "unsupported"
    scheduling = entry["operations"]["http_speech"]["scheduling"]
    assert scheduling == {
        "default_class": "batch_tts",
        "purpose_classes": {
            "interactive": "realtime_tts",
            "prefetch": "batch_tts",
        },
        "same_lane_serial": True,
        "hard_preemption": False,
    }
    purpose = entry["operations"]["http_speech"]["parameters"]["purpose"]
    assert purpose["values"] == ["interactive", "prefetch"]
    assert purpose["transport"] == "SpeechRail-Purpose header"
    budget = entry["operations"]["http_speech"]["parameters"]["latency_budget_ms"]
    assert budget["minimum"] == 50
    assert budget["maximum"] == 120_000
    assert budget["server_cap"] == "request_timeout_seconds"
    prepared = entry["prepared_reference_condition_cache"]
    assert prepared == {
        "status": "unsupported",
        "reason": "public_api_has_no_reusable_prepared_reference_condition",
        "vendor_package": "mlx-audio",
        "vendor_version": "0.4.8",
        "public_contract": "generate(ref_audio, ref_text)",
        "private_cache_observed": True,
    }
    timing = entry["timing_sidecar"]
    if entry["available"]:
        assert timing == {
            "status": "supported",
            "values": ["chunk"],
            "coordinate_space": "normalized_spoken_unicode_codepoints",
            "display_mapping": "conditional",
            "delivery": "async_resource",
            "reason": "planner_chunk_sample_conservation",
        }
    else:
        assert timing["status"] == "unsupported"
        assert timing["values"] == []


def test_content_revision_invalidates_on_private_recipe_but_not_readiness() -> None:
    from dataclasses import replace

    from speechrail.application.capability_snapshot import build_capability_snapshot

    profile = voices.VoiceProfile(id="local", instruction="first", mode="instruction")

    def snap(profile, *, ready=True):
        return build_capability_snapshot(
            (profile,),
            _active("quality"),
            epoch="epoch",
            ready=ready,
            enabled_voices=frozenset(),
            sample_rate=24_000,
        )

    initial = snap(profile)
    assert (
        initial["catalog_revision"]
        != snap(replace(profile, instruction="second"))["catalog_revision"]
    )
    assert initial["catalog_revision"] == snap(profile, ready=False)["catalog_revision"]
    assert initial["snapshot_id"] != snap(profile, ready=False)["snapshot_id"]


def test_registry_snapshot_is_detached_from_mutable_quality(tmp_path: Path) -> None:
    registry = voices.VoiceRegistry(tmp_path / "voices.json")
    registry.create_custom_profile(name="local", instruction="private", voice_id="local")
    snapshot = registry.snapshot_profiles()
    registry.update_custom_profile("local", name="updated")
    assert next(item for item in snapshot if item.id == "local").name == "local"
    assert (
        next(item for item in registry.snapshot_profiles() if item.id == "local").name == "updated"
    )


def test_namespaced_unknown_voice_and_store_failure_are_safe(tmp_path: Path, monkeypatch) -> None:
    registry = voices.VoiceRegistry(tmp_path / "voices.json")
    monkeypatch.setattr(voices, "_GLOBAL_VOICE_REGISTRY", registry)
    client = TestClient(create_app(Settings(api_key=None, qwen3_model_dir=None, qwen3_python=None)))
    assert client.get("/v1/speechrail/voices/not-found").status_code == 404
    assert client.get("/v1/speechrail/voices/alloy").json()["id"] == "serena"
    assert client.get("/v1/speechrail/voices").json()["data"]
    (tmp_path / "voices.json").write_text("PRIVATE_INVALID_JSON", encoding="utf-8")
    response = client.get("/v1/speechrail/capabilities")
    assert response.status_code == 503
    assert "PRIVATE" not in response.text


def test_discovery_handles_untrusted_quality_status_without_disclosure() -> None:
    from speechrail.application.capability_snapshot import build_capability_snapshot

    profile = voices.VoiceProfile(id="v", mode="instruction", quality={"status": ["PRIVATE"]})
    data = build_capability_snapshot(
        (profile,), _active("quality"), epoch="e", ready=True,
        enabled_voices=frozenset(), sample_rate=24_000,
    )
    assert data["voices"][0]["quality_summary"]["status"] == "unevaluated"
    assert "PRIVATE" not in str(data)


@pytest.mark.parametrize("tier", ["light", "balanced", "quality"])
def test_snapshot_matches_documented_openapi_schema(tier: str) -> None:
    import jsonschema
    import yaml

    from speechrail.application.capability_snapshot import build_capability_snapshot

    spec = yaml.safe_load(Path("contracts/openapi.yaml").read_text())
    schema = {
        "$ref": "#/components/schemas/EffectiveCapabilitySnapshot",
        "components": spec["components"],
    }
    jsonschema.Draft202012Validator(schema).validate(build_capability_snapshot(
        tuple(voices.SYSTEM_VOICE_PROFILES.values()), _active(tier), epoch="e", ready=True,
        enabled_voices=frozenset(voices.SYSTEM_VOICE_PROFILES), sample_rate=24_000,
    ))


def test_snapshot_tracks_the_actual_planner_policy(monkeypatch) -> None:
    import speechrail.application.capability_snapshot as discovery
    from speechrail.domain.tts_text_planner import PLANNER_VERSION, TtsTextPlanner

    def snapshot():
        return discovery.build_capability_snapshot(
            (), _active("quality"), epoch="same", ready=True,
            enabled_voices=frozenset(), sample_rate=24_000,
        )

    first = snapshot()
    policy = first["operations"]["tts_text_planner"]
    plan = TtsTextPlanner().plan("test.")
    assert policy["version"] == plan.version == PLANNER_VERSION
    assert policy["max_chars"] == plan.max_chars
    assert policy["coordinate_space"] == plan.coordinate_space
    assert policy["naturalness_evidence"] == "unevaluated"
    monkeypatch.setattr(discovery, "PLANNER_VERSION", "future_policy")
    changed = snapshot()
    assert changed["catalog_revision"] != first["catalog_revision"]
    assert changed["snapshot_id"] != first["snapshot_id"]


def test_content_addressed_voice_revision_enables_conditional_synthesis() -> None:
    from speechrail.application.capability_snapshot import build_capability_snapshot

    revision = "vr_" + "a" * 32
    profile = voices.VoiceProfile(
        id="local",
        name="Local",
        instruction="stable private recipe",
        seed=42,
        mode="instruction",
        revision=revision,
    )
    data = build_capability_snapshot(
        (profile,),
        _active("quality"),
        epoch="epoch",
        ready=True,
        enabled_voices=frozenset({"serena"}),
        sample_rate=24_000,
    )
    entry = data["voices"][0]
    assert entry["voice_revision"] == revision
    assert entry["voice_identity_assurance"] == "content_addressed"
    assert entry["conditional_synthesis"]["status"] == "supported"
    assert entry["conditional_synthesis"]["reason"] == "atomic_registry_lease_pin"
    encoded = str(entry)
    assert "stable private recipe" not in encoded
