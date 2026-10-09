"""Pure validation verdicts and the execution/presentation dependency boundary."""

import subprocess
import sys
from dataclasses import FrozenInstanceError, replace
from pathlib import Path

import pytest

from speechrail.domain.tts import VoiceProfile
from speechrail.domain.voice_validation import VoiceValidationArtifact
from speechrail.domain.voice_validation_policy import evaluate_voice_validation


def _facts():
    profile = VoiceProfile(
        id="policy_clone", mode="clone", revision="vr_" + "a" * 32,
        quality={"status": "pass", "policy_version": "voice_quality_v1"},
    )
    artifact = VoiceValidationArtifact(key="base", revision="catalog")
    binding = {
        "model_runtime_revision": "rt_" + "a" * 64,
        "runtime_fingerprint": "fingerprint",
        "preprocess_version": "preprocess",
        "generation_recipe_revision": "recipe",
        "policy_version": "voice_quality_v1",
        "capability_key": "quality.render",
    }
    evidence = {
        **binding, "voice_revision": profile.revision, "model_artifact": artifact.key,
        "model_catalog_revision": artifact.revision, "status": "pass",
        "identity_status": "unevaluated", "validated_for": ["output"],
        "run_id": "run", "tested_at": "2026-10-09", "failure_codes": [],
    }
    return profile, artifact, binding, evidence


@pytest.mark.parametrize("runtime_status", ["observed", "recorded"])
def test_valid_output_verdict_keeps_identity_separate_and_is_immutable(runtime_status):
    profile, artifact, binding, evidence = _facts()
    verdict = evaluate_voice_validation(
        profile, artifact, evidence, runtime_identity_status=runtime_status,
        validation_binding=binding, binding_required=True,
    )
    assert verdict.production_ready
    assert verdict.identity.status == "unevaluated"
    assert verdict.synthesis.validated_for == ("output",)
    evidence["validated_for"].clear()
    assert verdict.synthesis.validated_for == ("output",)
    with pytest.raises(FrozenInstanceError):
        verdict.production_ready = False


@pytest.mark.parametrize(
    ("field", "reason"),
    [
        ("voice_revision", "voice_revision_changed"),
        ("model_artifact", "model_artifact_changed"),
        ("model_catalog_revision", "model_catalog_revision_changed"),
        *[(field, "validation_binding_changed") for field in (
            "model_runtime_revision", "runtime_fingerprint", "preprocess_version",
            "generation_recipe_revision", "policy_version", "capability_key",
        )],
    ],
)
def test_each_identity_dimension_invalidates_the_verdict(field, reason):
    profile, artifact, binding, evidence = _facts()
    evidence[field] = "changed"
    verdict = evaluate_voice_validation(
        profile, artifact, evidence, runtime_identity_status="observed",
        validation_binding=binding, binding_required=True,
    )
    assert not verdict.production_ready
    assert verdict.stale
    assert verdict.synthesis.stale_reason == reason


@pytest.mark.parametrize(
    ("reference", "output", "scopes", "runtime", "reason"),
    [
        ("reject", "pass", ["output"], "observed", "reference_validation_not_passed"),
        ("pass", "reject", ["output"], "observed", "synthesis_validation_not_passed"),
        ("pass", "pass", [], "observed", "output_validation_scope_missing"),
        ("pass", "pass", ["output"], "unknown", "stale_synthesis_validation"),
    ],
)
def test_independent_gates_remain_distinguishable(reference, output, scopes, runtime, reason):
    profile, artifact, binding, evidence = _facts()
    profile = replace(profile, quality={"status": reference})
    evidence.update(status=output, validated_for=scopes)
    verdict = evaluate_voice_validation(
        profile, artifact, evidence, runtime_identity_status=runtime,
        validation_binding=binding, binding_required=True,
    )
    assert not verdict.production_ready
    assert verdict.production_ready_reason == reason


def test_execution_gate_does_not_import_the_discovery_presenter():
    path = Path(__file__).parents[1] / "src/speechrail/application/voice_validation_gate.py"
    source = path.read_text()
    assert "application.capability_snapshot" not in source
    assert 'state["production_ready"]' not in source


def test_policy_import_does_not_initialize_the_default_voice_registry():
    src = Path(__file__).parents[1] / "src"
    result = subprocess.run(
        [sys.executable, "-I", "-c",
         "import sys; sys.path.insert(0, sys.argv[1]); "
         "import speechrail.domain.voice_validation_policy; "
         "assert 'speechrail.domain.tts' not in sys.modules", str(src)],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stderr
