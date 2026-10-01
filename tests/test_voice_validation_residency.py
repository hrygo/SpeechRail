"""Output-gate evidence must not change verdict when the TTS worker is cold.

Regression guard for issue #129: ``production_ready`` flipped with worker
residency. The same voice, the same ``voice_revision`` and the same ``run_id``
read ``production_ready: true`` while a worker was warm and
``model_runtime_identity_unknown`` while it was cold-evicted, because
``qwen3_tts.runtime_revision`` only reports an identity while a worker is
resident. Nothing about the evidence changed.

Enforcement stays live: ``prepare_validated_speech`` starts the worker and
pins ``expected_runtime_revision`` before any production synthesis. Only the
read path has to be residency-independent.
"""

from __future__ import annotations

from pathlib import Path
from typing import cast

from speechrail.application.voice_validation_gate import (
    BASE_GENERATION_RECIPE_REVISION,
    _runtime_fingerprint,
    validation_state_for_voice,
)
from speechrail.domain.tts import VoiceProfile
from speechrail.domain.voice_validation import (
    VoiceValidationArtifact,
    VoiceValidationRepository,
)

_RUNTIME_REVISION = "rt_" + "a" * 64
_OTHER_RUNTIME_REVISION = "rt_" + "b" * 64
_VOICE_REVISION = "vr_" + "c" * 32
_ARTIFACT = VoiceValidationArtifact(key="tts_clone_base", revision="a" * 40)


class _ResidentWorker:
    """A synthesizer whose runtime identity depends on residency, as in qwen3_tts."""

    def __init__(self, *, ready: bool, revision: str | None = None) -> None:
        self.ready = ready
        self._revision = revision

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        if not self.ready:
            return None
        return self._revision or _RUNTIME_REVISION


def _profile() -> VoiceProfile:
    return VoiceProfile(
        id="wom_cold_read",
        mode="clone",
        revision=_VOICE_REVISION,
        ref_text="参考文本",
        audio_path="/private/reference.wav",
        quality={"policy_version": "voice_quality_v1", "status": "pass"},
    )


def _fingerprint(runtime_revision: str) -> str:
    return _runtime_fingerprint(
        runtime_revision=runtime_revision,
        model_artifact=_ARTIFACT.key,
        model_catalog_revision=_ARTIFACT.revision,
        preprocess_version="energy_v1",
        generation_recipe_revision=BASE_GENERATION_RECIPE_REVISION,
        policy_version="voice_quality_v1",
    )


def _repository(
    tmp_path: Path, *, runtime_revision: str | None = _RUNTIME_REVISION
) -> VoiceValidationRepository:
    repository = VoiceValidationRepository(tmp_path / "voice_validations.json")
    repository.put(
        {
            "voice_id": "wom_cold_read",
            "voice_revision": _VOICE_REVISION,
            "status": "pass",
            "run_id": "vqr_fixed",
            "tested_at": "2026-10-01T00:28:13Z",
            "model_artifact": _ARTIFACT.key,
            "model_catalog_revision": _ARTIFACT.revision,
            "model_runtime_revision": runtime_revision,
            "runtime_fingerprint": (
                None if runtime_revision is None else _fingerprint(runtime_revision)
            ),
            "preprocess_version": "energy_v1",
            "generation_recipe_revision": BASE_GENERATION_RECIPE_REVISION,
            "policy_version": "voice_quality_v1",
            "capability_key": "quality.render",
            "failure_codes": [],
            "validated_for": ["output"],
        }
    )
    return repository


def test_cold_worker_reports_the_same_production_ready_as_a_warm_one(tmp_path: Path) -> None:
    repository = _repository(tmp_path)
    profile = _profile()

    warm_state, warm_evidence, _ = validation_state_for_voice(
        profile,
        _ARTIFACT,
        repository,
        _ResidentWorker(ready=True),
        require_current_binding=True,
        capability_key="quality.render",
    )
    cold_state, cold_evidence, _ = validation_state_for_voice(
        profile,
        _ARTIFACT,
        repository,
        _ResidentWorker(ready=False),
        require_current_binding=True,
        capability_key="quality.render",
    )

    assert warm_state["production_ready"] is True
    assert cold_state["production_ready"] is True
    assert cold_state["production_ready_reason"] == "validated"
    assert cold_state["synthesis"]["status"] == "pass"
    # Same evidence record, not a re-derivation that happens to agree.
    assert cold_evidence is not None
    assert cold_evidence["run_id"] == warm_evidence["run_id"] == "vqr_fixed"


def test_a_resident_worker_reporting_another_runtime_still_invalidates_evidence(
    tmp_path: Path,
) -> None:
    # The residency fix must not become "always trust the record": a worker that
    # is up and reports a different runtime is real, detectable staleness.
    repository = _repository(tmp_path)
    state, _, _ = validation_state_for_voice(
        _profile(),
        _ARTIFACT,
        repository,
        _ResidentWorker(ready=True, revision=_OTHER_RUNTIME_REVISION),
        require_current_binding=True,
        capability_key="quality.render",
    )

    assert state["production_ready"] is False
    assert state["synthesis"]["status"] == "unevaluated"


def test_evidence_without_a_canonical_runtime_revision_still_fails_closed(
    tmp_path: Path,
) -> None:
    # A record that never carried an observed identity cannot borrow one from
    # the catalog: with no worker to compare against there is nothing to trust,
    # so the voice stays unready rather than being reported ready by default.
    for index, unusable in enumerate((None, "not-a-runtime-revision", "rt_short")):
        repository = _repository(
            tmp_path / f"case_{index}",
            runtime_revision=cast(str | None, unusable),
        )

        state, _, _ = validation_state_for_voice(
            _profile(),
            _ARTIFACT,
            repository,
            _ResidentWorker(ready=False),
            require_current_binding=True,
            capability_key="quality.render",
        )

        assert state["production_ready"] is False, unusable
        assert state["production_ready_reason"] != "validated", unusable
