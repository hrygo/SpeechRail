"""One validation binding and gate for every production TTS path.

Reference acceptance, output validation, and production routing are separate
observations.  This module supplies the shared binding used by discovery,
HTTP strict synthesis, and durable speech jobs so those paths cannot silently
select different evidence records.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any, Literal

from speechrail.application.capability_snapshot import _validation_state
from speechrail.application.render_receipts import observed_runtime_revision_for_synthesizer
from speechrail.config.model_catalog import ModelArtifact
from speechrail.domain.tts import VoiceProfile
from speechrail.domain.voice_quality import POLICY_VERSION
from speechrail.domain.voice_validation import (
    VoiceValidationArtifact,
    VoiceValidationRepository,
)

REFERENCE_PREPROCESS_VERSION = "energy_v1"
BASE_GENERATION_RECIPE_REVISION = "qwen3_tts_base_clone_v1"
RuntimeIdentityStatus = Literal["not_requested", "unknown", "observed"]


def _preprocess_version(profile: VoiceProfile) -> str:
    creation = profile.creation
    if creation is not None:
        return creation.preprocessing_version
    # Manual clone registration uses the same canonical reference pipeline as
    # generated VoiceDesign references, but has no VoiceCreation record.
    return REFERENCE_PREPROCESS_VERSION


def _runtime_fingerprint(
    *,
    runtime_revision: str,
    model_artifact: str,
    model_catalog_revision: str,
    preprocess_version: str,
    generation_recipe_revision: str,
    policy_version: str,
) -> str:
    payload = {
        "runtime_revision": runtime_revision,
        "model_artifact": model_artifact,
        "model_catalog_revision": model_catalog_revision,
        "preprocess_version": preprocess_version,
        "generation_recipe_revision": generation_recipe_revision,
        "policy_version": policy_version,
    }
    encoded = json.dumps(
        payload,
        sort_keys=True,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return "vf_" + hashlib.sha256(encoded).hexdigest()


@dataclass(frozen=True, slots=True)
class VoiceValidationBinding:
    """Current evidence identity for one clone voice and TTS lane."""

    voice_id: str
    voice_revision: str | None
    model_artifact: str | None
    model_catalog_revision: str | None
    model_runtime_revision: str | None
    runtime_fingerprint: str | None
    preprocess_version: str
    generation_recipe_revision: str
    policy_version: str
    runtime_identity_status: RuntimeIdentityStatus

    def as_mapping(self) -> dict[str, object]:
        return {
            "voice_id": self.voice_id,
            "voice_revision": self.voice_revision,
            "model_artifact": self.model_artifact,
            "model_catalog_revision": self.model_catalog_revision,
            "model_runtime_revision": self.model_runtime_revision,
            "runtime_fingerprint": self.runtime_fingerprint,
            "preprocess_version": self.preprocess_version,
            "generation_recipe_revision": self.generation_recipe_revision,
            "policy_version": self.policy_version,
            "runtime_identity_status": self.runtime_identity_status,
        }


def build_validation_binding(
    profile: VoiceProfile,
    artifact: ModelArtifact | VoiceValidationArtifact | None,
    synthesizer: object | None = None,
    *,
    require_current_binding: bool = False,
    observed_runtime_revision: str | None = None,
) -> VoiceValidationBinding:
    """Build the current binding without loading a worker or model."""

    runtime_revision = (
        observed_runtime_revision
        if observed_runtime_revision is not None
        else (
            observed_runtime_revision_for_synthesizer(synthesizer, profile.id)
            if synthesizer is not None
            else None
        )
    )
    if runtime_revision is not None:
        runtime_status: RuntimeIdentityStatus = "observed"
    elif require_current_binding:
        runtime_status = "unknown"
    else:
        runtime_status = "not_requested"
    artifact_key = artifact.key if artifact is not None else None
    catalog_revision = artifact.revision if artifact is not None else None
    preprocess_version = _preprocess_version(profile)
    generation_recipe_revision = BASE_GENERATION_RECIPE_REVISION
    runtime_fingerprint = (
        _runtime_fingerprint(
            runtime_revision=runtime_revision,
            model_artifact=artifact_key,
            model_catalog_revision=catalog_revision,
            preprocess_version=preprocess_version,
            generation_recipe_revision=generation_recipe_revision,
            policy_version=POLICY_VERSION,
        )
        if runtime_revision is not None
        and artifact_key is not None
        and catalog_revision is not None
        else None
    )
    return VoiceValidationBinding(
        voice_id=profile.id,
        voice_revision=profile.revision,
        model_artifact=artifact_key,
        model_catalog_revision=catalog_revision,
        model_runtime_revision=runtime_revision,
        runtime_fingerprint=runtime_fingerprint,
        preprocess_version=preprocess_version,
        generation_recipe_revision=generation_recipe_revision,
        policy_version=POLICY_VERSION,
        runtime_identity_status=runtime_status,
    )


def load_validation_evidence(
    repository: VoiceValidationRepository,
    binding: VoiceValidationBinding,
    *,
    require_current_binding: bool,
) -> dict[str, Any] | None:
    """Read only evidence matching the supplied binding."""

    return repository.get(
        voice_id=binding.voice_id,
        voice_revision=binding.voice_revision,
        model_artifact=binding.model_artifact,
        model_catalog_revision=binding.model_catalog_revision,
        model_runtime_revision=binding.model_runtime_revision,
        runtime_fingerprint=binding.runtime_fingerprint,
        preprocess_version=binding.preprocess_version,
        generation_recipe_revision=binding.generation_recipe_revision,
        policy_version=binding.policy_version,
        require_current_binding=require_current_binding,
    )


def validation_state_for_voice(
    profile: VoiceProfile,
    artifact: ModelArtifact | VoiceValidationArtifact | None,
    repository: VoiceValidationRepository,
    synthesizer: object | None = None,
    *,
    require_current_binding: bool,
) -> tuple[dict[str, object], dict[str, Any] | None, VoiceValidationBinding]:
    """Return the evidence, binding, and shared projected validation state."""

    binding = build_validation_binding(
        profile,
        artifact,
        synthesizer,
        require_current_binding=require_current_binding,
    )
    evidence = load_validation_evidence(
        repository,
        binding,
        require_current_binding=require_current_binding,
    )
    state = _validation_state(
        profile,
        artifact,
        evidence,
        runtime_revision=binding.model_runtime_revision,
        runtime_identity_status=binding.runtime_identity_status,
        validation_binding=binding.as_mapping(),
        binding_required=require_current_binding,
    )
    return state, evidence, binding


__all__ = [
    "BASE_GENERATION_RECIPE_REVISION",
    "REFERENCE_PREPROCESS_VERSION",
    "RuntimeIdentityStatus",
    "VoiceValidationBinding",
    "build_validation_binding",
    "load_validation_evidence",
    "validation_state_for_voice",
]
