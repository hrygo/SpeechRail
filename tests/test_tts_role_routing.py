"""T07: TTS routes by plan role and binds evidence per tier and mode."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import pytest

from speechrail.application.voice_validation_gate import (
    VoiceValidationBinding,
    build_validation_binding,
    load_validation_evidence,
)
from speechrail.config.model_catalog import ModelRole, SpecTier
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.domain.tts_routing import (
    TtsExecutionMode,
    TtsRouteError,
    route_role_for_mode,
    select_tts_route,
    tts_capability_key,
)
from speechrail.domain.voice_validation import (
    VoiceValidationArtifact,
    VoiceValidationRepository,
)

_VOICE_REVISION = "vr_" + "a" * 32
_BASE_ARTIFACT = VoiceValidationArtifact("tts-1.7b-base-q8", "b" * 40)


@dataclass(frozen=True)
class _Profile:
    mode: str
    revision: str | None = _VOICE_REVISION


@pytest.mark.parametrize(
    ("tier", "mode", "role", "artifact_key"),
    [
        ("fast", "system", "tts_custom_voice", "tts-0.6b-custom-q8"),
        ("fast", "clone", "tts_base", "tts-0.6b-base-q8"),
        ("quality", "system", "tts_custom_voice", "tts-1.7b-custom-q8"),
        ("quality", "clone", "tts_base", "tts-1.7b-base-q8"),
        ("reference", "system", "tts_custom_voice", "tts-1.7b-custom-bf16"),
        ("reference", "clone", "tts_base", "tts-1.7b-base-bf16"),
    ],
)
def test_six_runtime_role_selections_bind_the_target_artifact(
    tier: SpecTier,
    mode: str,
    role: ModelRole,
    artifact_key: str,
) -> None:
    selection = select_tts_route(
        tier=tier,
        mode=TtsExecutionMode.RENDER,
        profile=_Profile(mode=mode),
    )

    assert selection.role == role
    assert selection.artifact_key == artifact_key
    assert selection.artifact_key == required_spec_artifact(tier, role)
    assert selection.capability_key == f"{tier}.render"
    assert selection.voice_revision == _VOICE_REVISION


def test_capability_keys_separate_every_tier_and_mode() -> None:
    keys = {
        tts_capability_key(tier, mode)
        for tier in ("fast", "quality", "reference")
        for mode in (TtsExecutionMode.STREAM, TtsExecutionMode.RENDER)
    }

    assert keys == {
        "fast.stream",
        "fast.render",
        "quality.stream",
        "quality.render",
        "reference.stream",
        "reference.render",
    }


@pytest.mark.parametrize("mode", ("instruction", "unknown"))
def test_design_only_and_unknown_modes_never_route_to_runtime_weights(mode: str) -> None:
    with pytest.raises(TtsRouteError):
        route_role_for_mode(mode)
    with pytest.raises(TtsRouteError):
        select_tts_route(
            tier="quality",
            mode=TtsExecutionMode.STREAM,
            profile=_Profile(mode=mode),
        )


def test_design_revision_cannot_be_selected_by_a_runtime_mode() -> None:
    with pytest.raises(TtsRouteError) as raised:
        select_tts_route(
            tier="quality",
            mode=TtsExecutionMode.STREAM,
            profile=_Profile(mode="instruction", revision=None),
        )

    assert raised.value.code == "voice_design_task_required"


def _binding(capability_key: str) -> VoiceValidationBinding:
    return build_validation_binding(
        _profile(),
        _BASE_ARTIFACT,
        observed_runtime_revision="observed-runtime-1",
        require_current_binding=True,
        capability_key=capability_key,
    )


def _record(binding: VoiceValidationBinding, run_id: str) -> dict[str, object]:
    return {
        "voice_id": binding.voice_id,
        "voice_revision": binding.voice_revision,
        "status": "pass",
        "identity_status": "pass",
        "run_id": run_id,
        "tested_at": "2026-09-25T00:00:00Z",
        "policy_version": binding.policy_version,
        "model_artifact": binding.model_artifact,
        "model_catalog_revision": binding.model_catalog_revision,
        "model_runtime_revision": binding.model_runtime_revision,
        "runtime_fingerprint": binding.runtime_fingerprint,
        "preprocess_version": binding.preprocess_version,
        "generation_recipe_revision": binding.generation_recipe_revision,
        "capability_key": binding.capability_key,
        "probe_set": "standard_v1",
        "repetitions": 1,
        "failure_codes": [],
        "validated_for": ["output"],
    }


def test_validation_evidence_is_bound_to_one_tier_and_mode(tmp_path: Path) -> None:
    repository = VoiceValidationRepository(tmp_path / "voice_validations.json")
    repository.put(_record(_binding("quality.render"), "run-quality.render"))
    repository.put(_record(_binding("quality.stream"), "run-quality.stream"))

    def _load(capability_key: str) -> dict[str, object] | None:
        return load_validation_evidence(
            repository, _binding(capability_key), require_current_binding=True
        )

    render = _load("quality.render")
    stream = _load("quality.stream")

    # Separate records coexist, and one combination never proves another.
    assert render is not None and render["run_id"] == "run-quality.render"
    assert stream is not None and stream["run_id"] == "run-quality.stream"
    assert _load("fast.render") is None
    assert _load("reference.stream") is None


def _profile():
    from speechrail.domain.tts import VoiceProfile

    return VoiceProfile(
        id="cloned",
        name="cloned",
        mode="clone",
        ref_text="参考文本",
        revision=_VOICE_REVISION,
    )
