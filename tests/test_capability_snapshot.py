"""Read-only capability discovery, independent of model startup or private audio."""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import speechrail.domain.tts as voices
from speechrail.app import create_app
from speechrail.config import Settings


def test_capability_snapshot_is_stable_and_discovery_remains_available(
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
    assert first.json()["realtime"] == {
        "orchestration": "caller",
        "server_llm": False,
        "conversation_state": False,
        "websocket_path": "/v1/realtime",
        "mcp_realtime": False,
    }
    assert client.get("/v1/voices").status_code == 200
    assert client.get("/v1/models").status_code == 200


def test_capability_discovery_uses_configured_auth(tmp_path: Path, monkeypatch) -> None:
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


_ACTIVE_SELECTIONS = [
    ("fast", "fast"),
    ("quality", "fast"),
    ("quality", "quality"),
    ("reference", "reference"),
]


def _active(asr_spec: str, tts_spec: str):
    from speechrail.config.model_catalog import load_catalog
    from speechrail.config.selection import ActiveModelCatalog

    catalog = load_catalog()
    artifacts = {item.key: item for item in catalog.artifacts}
    return ActiveModelCatalog(
        profile=f"{asr_spec}/{tts_spec}",
        asr=artifacts[catalog.binding(asr_spec, "asr")],
        tts=artifacts[catalog.binding(tts_spec, "tts_custom_voice")],
        tts_clone=artifacts[catalog.binding(tts_spec, "tts_base")],
        # VoiceDesign is bound independently of the tier, exactly as the shipped
        # selection binds it.
        voice_design=artifacts[catalog.voice_design_artifact().key],
        aligner=None,
        diarization=False,
        asr_spec=asr_spec,
        tts_spec=tts_spec,
    )


def test_design_only_voice_is_not_advertised_as_a_synthesis_voice() -> None:
    """A design candidate resolves the VoiceDesign artifact but has no route.

    /v1/audio/speech answers `voice_design_task_required` for any voice whose
    `runtime_role` is None, so discovery must not report it as available, must not
    advertise synthesis-side parameters for it, and must say why.
    """
    from speechrail.application.capability_snapshot import build_capability_snapshot

    profile = voices.VoiceProfile(
        id="draft",
        mode="instruction",
        instruction="PRIVATE_INSTRUCTION",
        created_at=0.0,
    )
    snapshot = build_capability_snapshot(
        [profile],
        _active("quality", "quality"),
        epoch="e",
        ready=True,
        enabled_voices=frozenset(),
        sample_rate=24_000,
    )
    entry = snapshot["voices"][0]
    # The artifact is known and the binding resolves — this is not an identity
    # failure, it is a routing fact.
    assert entry["model"]["variant"] == "voice_design"
    assert entry["available"] is False
    assert entry["availability_reason"] == "voice_design_task_required"
    assert entry["production_ready"] is False

    speech = entry["operations"]["http_speech"]["parameters"]
    assert speech["instructions"]["status"] == "unsupported"
    assert entry["timing_sidecar"]["status"] == "unsupported"
    assert entry["timing_sidecar"]["values"] == []
    assert entry["conditional_synthesis"]["status"] == "unsupported"
    assert "PRIVATE_INSTRUCTION" not in str(snapshot)


def test_published_clone_voice_stays_available_with_the_design_lane_bound() -> None:
    """Binding the design lane must not disturb the production route."""
    from speechrail.application.capability_snapshot import build_capability_snapshot

    profile = voices.VoiceProfile(
        id="published",
        mode="clone",
        instruction=None,
        created_at=0.0,
    )
    snapshot = build_capability_snapshot(
        [profile],
        _active("quality", "quality"),
        epoch="e",
        ready=True,
        enabled_voices=frozenset(),
        sample_rate=24_000,
    )
    entry = snapshot["voices"][0]
    assert entry["available"] is True
    assert entry["availability_reason"] == "available"
    assert entry["model"]["variant"] == "base"
    assert entry["timing_sidecar"]["status"] == "supported"
    assert entry["operations"]["http_speech"]["parameters"]["instructions"][
        "status"
    ] == "unsupported"
    # S3-2: the Base clone lane rejects a caller seed; only custom_voice
    # advertises it (clone_seed_unsupported at the domain boundary).
    assert entry["operations"]["http_speech"]["parameters"]["seed"] == {
        "status": "unsupported",
        "reason": "clone_seed_unsupported",
    }


@pytest.mark.parametrize(("asr_spec", "tts_spec"), _ACTIVE_SELECTIONS)
def test_voice_design_is_published_as_a_peer_role_not_a_tts_variant(
    asr_spec: str, tts_spec: str
) -> None:
    """The design lane must be discoverable without reading the tts variant.

    `models["tts"]` can only ever name custom_voice or base, so a design verdict
    read from that slot is unsatisfiable by construction. Publishing design as
    its own peer role is what makes design admission decidable.
    """
    from speechrail.application.capability_snapshot import build_capability_snapshot

    snapshot = build_capability_snapshot(
        [], _active(asr_spec, tts_spec), epoch="e", ready=True,
        enabled_voices=frozenset(), sample_rate=24_000,
    )
    assert snapshot["models"]["tts"]["variant"] in {"custom_voice", "base"}
    assert snapshot["models"]["voice_design"]["variant"] == "voice_design"
    assert snapshot["models"]["voice_design"]["artifact"] == "tts-1.7b-design-bf16"

    operation = snapshot["operations"]["voice_design"]
    assert operation["status"] == "supported"
    assert operation["scope"] == "design_period_only"
    assert operation["affects_production_tts_route"] is False
    assert operation["publishes_to_base_variant"] is True
    # Design availability must not leak into or out of the production route.
    assert snapshot["operations"]["voice_preview"]["status"] == "supported"


def test_unbound_design_artifact_degrades_the_design_role_only() -> None:
    from speechrail.application.capability_snapshot import build_capability_snapshot
    from speechrail.config.model_catalog import load_catalog
    from speechrail.config.selection import ActiveModelCatalog

    catalog = load_catalog()
    artifacts = {item.key: item for item in catalog.artifacts}
    active = ActiveModelCatalog(
        profile="quality/quality",
        asr=artifacts[catalog.binding("quality", "asr")],
        tts=artifacts[catalog.binding("quality", "tts_custom_voice")],
        tts_clone=artifacts[catalog.binding("quality", "tts_base")],
        voice_design=None,
        aligner=None,
        diarization=False,
        asr_spec="quality",
        tts_spec="quality",
    )
    snapshot = build_capability_snapshot(
        [], active, epoch="e", ready=True,
        enabled_voices=frozenset(), sample_rate=24_000,
    )
    assert snapshot["models"]["voice_design"] == {
        "assurance": "unknown",
        "runtime_revision": None,
    }
    assert snapshot["operations"]["voice_design"]["status"] == "unsupported"
    assert (
        snapshot["operations"]["voice_design"]["reason"]
        == "voice_design_artifact_not_bound"
    )
    # Production TTS is untouched by a missing design artifact.
    assert snapshot["models"]["tts"]["variant"] == "custom_voice"
    assert snapshot["operations"]["tts_text_planner"]["max_chars"] > 0


@pytest.mark.parametrize(("asr_spec", "tts_spec"), _ACTIVE_SELECTIONS)
@pytest.mark.parametrize("mode", ["system", "instruction", "clone"])
def test_effective_matrix_uses_captured_voice_and_base_lane(
    asr_spec: str, tts_spec: str, mode: str, monkeypatch
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
        _active(asr_spec, tts_spec),
        epoch="epoch",
        ready=True,
        enabled_voices=frozenset({"serena"}),
        sample_rate=24_000,
    )
    entry = data["voices"][0]
    assert entry["voice_revision"] is None
    assert entry["voice_identity_assurance"] == "legacy"
    # The target architecture keeps VoiceDesign out of daily routing, so the
    # tier's primary TTS is CustomVoice (built-in speakers) and the clone lane
    # is Base. Only those two roles resolve; an unpublished instruction draft
    # stays unavailable until it is published as a Base-served revision.
    assert entry["available"] is (mode in {"system", "clone"})
    encoded = str(data)
    for secret in ["PRIVATE_INSTRUCTION", "PRIVATE_REFERENCE", "/private/", "PRIVATE_QUALITY"]:
        assert secret not in encoded
    if mode == "clone":
        assert entry["variant"] == "base"
        assert entry["operations"]["http_speech"]["parameters"]["speed"]["values"] == [1.0]
    # Instructions are a VoiceDesign-only parameter; no tier's primary TTS is
    # VoiceDesign, so both built-in speakers and the Base clone lane reject them.
    assert (
        entry["operations"]["http_speech"]["parameters"]["instructions"]["status"]
        == "unsupported"
    )
    parameters = entry["operations"]["http_speech"]["parameters"]
    # S3-2: custom_voice (system) accepts a caller seed via the SpeechRail-Seed
    # header; the Base clone lane still rejects it (clone_seed_unsupported).
    # An unpublished instruction draft owns no runtime role, so its seed stays
    # "unknown" rather than advertised as supported.
    if mode == "clone":
        assert parameters["seed"]["status"] == "unsupported"
    elif mode == "system":
        assert parameters["seed"]["status"] == "supported"
    else:
        assert parameters["seed"]["status"] == "unknown"
    assert parameters["phoneme"]["status"] == "unsupported"
    assert parameters["ssml"]["status"] == "unsupported"
    assert parameters["pronunciation_set"]["status"] == "supported"
    expression = parameters["native_expression"]
    if mode == "clone":
        assert expression == {
            "status": "unsupported",
            "reason": "fixed_identity_neutral_only",
        }
    else:
        assert expression == {
            "status": "unknown",
            "reason": "identity_preservation_unevaluated",
        }
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

    # A clone revision is the target's routable custom voice; an unpublished
    # instruction draft is intentionally unavailable, so readiness would not be
    # observable on it.
    profile = voices.VoiceProfile(
        id="local",
        mode="clone",
        ref_text="first",
        audio_path="/private/reference.wav",
    )

    def snap(profile, *, ready=True):
        return build_capability_snapshot(
            (profile,),
            _active("quality", "quality"),
            epoch="epoch",
            ready=ready,
            enabled_voices=frozenset(),
            sample_rate=24_000,
        )

    initial = snap(profile)
    assert (
        initial["catalog_revision"]
        != snap(replace(profile, ref_text="second"))["catalog_revision"]
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
        (profile,), _active("quality", "quality"), epoch="e", ready=True,
        enabled_voices=frozenset(), sample_rate=24_000,
    )
    assert data["voices"][0]["quality_summary"]["status"] == "unevaluated"
    assert "PRIVATE" not in str(data)


@pytest.mark.parametrize(("asr_spec", "tts_spec"), _ACTIVE_SELECTIONS)
def test_snapshot_matches_documented_openapi_schema(asr_spec: str, tts_spec: str) -> None:
    import jsonschema
    import yaml

    from speechrail.application.capability_snapshot import build_capability_snapshot

    spec = yaml.safe_load(Path("contracts/openapi.yaml").read_text())
    schema = {
        "$ref": "#/components/schemas/EffectiveCapabilitySnapshot",
        "components": spec["components"],
    }
    jsonschema.Draft202012Validator(schema).validate(
        build_capability_snapshot(
            tuple(voices.SYSTEM_VOICE_PROFILES.values()),
            _active(asr_spec, tts_spec),
            epoch="e",
            ready=True,
            enabled_voices=frozenset(voices.SYSTEM_VOICE_PROFILES),
            sample_rate=24_000,
        )
    )


def test_snapshot_tracks_the_actual_planner_policy(monkeypatch) -> None:
    import speechrail.application.capability_snapshot as discovery
    from speechrail.domain.tts_text_planner import PLANNER_VERSION, TtsTextPlanner

    def snapshot():
        return discovery.build_capability_snapshot(
            (), _active("quality", "quality"), epoch="same", ready=True,
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
        mode="clone",
        seed=42,
        ref_text="stable private recipe",
        audio_path="/private/reference.wav",
        revision=revision,
    )
    data = build_capability_snapshot(
        (profile,),
        _active("quality", "quality"),
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


def test_clone_reference_pass_does_not_imply_production_ready_without_output_pass() -> None:
    from speechrail.application.capability_snapshot import build_capability_snapshot

    active = _active("quality", "quality")
    revision = "vr_" + "b" * 32
    profile = voices.VoiceProfile(
        id="clone_ready_reference",
        name="Clone",
        mode="clone",
        ref_text="参考文本",
        audio_path="/private/reference.wav",
        revision=revision,
        quality={
            "policy_version": "voice_quality_v1",
            "status": "pass",
            "run_id": "run_reference",
        },
    )

    before = build_capability_snapshot(
        (profile,), active, epoch="e", ready=True,
        enabled_voices=frozenset(), sample_rate=24_000,
    )["voices"][0]
    assert before["available"] is True
    assert before["validation_state"]["reference"]["status"] == "pass"
    assert before["validation_state"]["synthesis"]["status"] == "unevaluated"
    assert before["validation_state"]["identity"]["status"] == "unevaluated"
    assert before["validated_for"] == []
    assert before["production_ready"] is False
    assert before["production_ready_reason"] == "synthesis_validation_not_run"

    profile_with_output = voices.VoiceProfile(
        id=profile.id,
        name=profile.name,
        mode=profile.mode,
        ref_text=profile.ref_text,
        audio_path=profile.audio_path,
        revision=profile.revision,
        quality={
            **(profile.quality or {}),
            "synthesis_validation": {
                "status": "pass",
                "run_id": "run_output",
                "voice_revision": revision,
                "model_artifact": active.tts_clone.key,
                "model_catalog_revision": active.tts_clone.revision,
                "model_runtime_revision": None,
                "failure_codes": [],
            },
        },
    )
    validation = {
        "voice_id": profile.id,
        "status": "pass",
        "run_id": "run_output",
        "voice_revision": revision,
        "model_artifact": active.tts_clone.key,
        "model_catalog_revision": active.tts_clone.revision,
        "model_runtime_revision": None,
        "failure_codes": [],
        "validated_for": ["output"],
    }
    after = build_capability_snapshot(
        (profile_with_output,), active, epoch="e", ready=True,
        enabled_voices=frozenset(), sample_rate=24_000,
        validation_records={profile.id: validation},
    )["voices"][0]
    assert after["validation_state"]["synthesis"]["status"] == "pass"
    assert after["validation_state"]["identity"]["status"] == "unevaluated"
    assert after["validated_for"] == ["output"]
    assert after["production_ready"] is True


def test_clone_output_pass_does_not_survive_unknown_current_runtime() -> None:
    from speechrail.domain.voice_validation_policy import evaluate_voice_validation

    active = _active("quality", "quality")
    revision = "vr_" + "d" * 32
    profile = voices.VoiceProfile(
        id="runtime_bound_clone",
        mode="clone",
        revision=revision,
        ref_text="参考文本",
        audio_path="/private/reference.wav",
        quality={"policy_version": "voice_quality_v1", "status": "pass"},
    )
    validation = {
        "voice_id": profile.id,
        "voice_revision": revision,
        "status": "pass",
        "model_artifact": active.tts_clone.key,
        "model_catalog_revision": active.tts_clone.revision,
        "model_runtime_revision": "rt_" + "1" * 64,
        "runtime_fingerprint": "vf_" + "1" * 64,
        "preprocess_version": "energy_v1",
        "generation_recipe_revision": "qwen3_tts_base_clone_v1",
        "policy_version": "voice_quality_v1",
        "validated_for": ["output"],
    }
    state = evaluate_voice_validation(
        profile,
        active.tts_clone,
        validation,
        runtime_identity_status="unknown",
        validation_binding={
            "model_runtime_revision": None,
            "runtime_fingerprint": None,
            "preprocess_version": "energy_v1",
            "generation_recipe_revision": "qwen3_tts_base_clone_v1",
            "policy_version": "voice_quality_v1",
        },
        binding_required=True,
    )
    assert state.production_ready is False
    assert state.production_ready_reason == "stale_synthesis_validation"
    assert state.synthesis.stale_reason == "model_runtime_identity_unknown"


def _snapshot(**overrides):
    from speechrail.application.capability_snapshot import build_capability_snapshot

    kwargs = {
        "epoch": "e",
        "ready": True,
        "enabled_voices": frozenset(),
        "sample_rate": 24_000,
    }
    kwargs.update(overrides)
    return build_capability_snapshot((), _active("quality", "quality"), **kwargs)


def test_asr_operations_are_conservative_without_declared_facts() -> None:
    snapshot = _snapshot()
    ops = snapshot["operations"]
    assert ops["transcription"]["status"] == "unsupported"
    assert ops["transcription"]["reason"] == "asr_not_configured"
    assert ops["transcription"]["granularity"] == "segment"
    assert ops["alignment_transcription"]["status"] == "unsupported"
    assert ops["alignment_transcription"]["granularity"] == "word"
    assert ops["realtime_transcription"]["duplex"] == "half_duplex"
    assert ops["jobs"]["status"] == "unsupported"
    assert snapshot["guarantees"]["websocket_bidirectional_is_not_full_duplex"] is True
    assert snapshot["guarantees"]["realtime_full_duplex"] is False


def test_asr_operations_reflect_declared_input_limits_and_readiness() -> None:
    facts = {
        "available": True,
        "ready": True,
        "max_upload_bytes": 25 * 1024**2,
        "max_audio_seconds": 120,
        "alignment_available": True,
        "jobs_available": True,
        "realtime_formats": ("pcm16",),
        "realtime_pcm_sample_rate": 24_000,
        "realtime_endpointing": ("server_vad",),
    }
    ops = _snapshot(asr_capabilities=facts)["operations"]
    assert ops["transcription"]["status"] == "supported"
    assert ops["transcription"]["reason"] is None
    assert ops["transcription"]["input"]["max_upload_bytes"] == 25 * 1024**2
    assert ops["transcription"]["input"]["max_audio_seconds"] == 120
    assert ops["transcription"]["languages"]["status"] == "unknown"
    assert ops["alignment_transcription"]["status"] == "supported"
    assert ops["realtime_transcription"]["input"]["pcm_sample_rate"] == 24_000
    assert ops["jobs"]["status"] == "supported"


def test_full_duplex_is_reported_only_after_joint_certification() -> None:
    uncertified = _snapshot(
        asr_capabilities={"available": True, "ready": True}
    )
    assert uncertified["operations"]["realtime_transcription"]["duplex"] == "half_duplex"
    assert uncertified["guarantees"]["realtime_full_duplex"] is False

    certified = _snapshot(
        asr_capabilities={
            "available": True,
            "ready": True,
            "realtime_full_duplex_certified": True,
        }
    )
    assert certified["operations"]["realtime_transcription"]["duplex"] == "full_duplex"
    assert certified["guarantees"]["realtime_full_duplex"] is True
    # Certification changes are content changes and must invalidate discovery.
    assert certified["catalog_revision"] != uncertified["catalog_revision"]


def test_engine_revision_and_selection_generation_invalidate_revision() -> None:
    baseline = _snapshot(runtime_revision="engine-1")
    other_engine = _snapshot(runtime_revision="engine-2")
    assert baseline["catalog_revision"] != other_engine["catalog_revision"]
    assert baseline["snapshot_id"] != other_engine["snapshot_id"]


def test_busy_state_does_not_deform_supported_capability_enumeration() -> None:
    from speechrail.application.capability_snapshot import build_capability_snapshot

    facts = {"available": True, "ready": True}
    snapshot = build_capability_snapshot(
        (),
        _active("quality", "quality"),
        epoch="e",
        ready=True,
        enabled_voices=frozenset(),
        sample_rate=24_000,
        asr_capabilities=facts,
    )
    # build_capability_snapshot is pure: it accepts no activity/busy input at
    # all, so a busy lane cannot shrink the supported operations it reports.
    assert snapshot["operations"]["transcription"]["status"] == "supported"
    assert snapshot["operations"]["realtime_transcription"]["status"] == "supported"
