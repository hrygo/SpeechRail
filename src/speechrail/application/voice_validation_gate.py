"""One validation binding and gate for every production TTS path.

Reference acceptance, output validation, and production routing are separate
observations.  This module supplies the shared binding used by discovery,
HTTP strict synthesis, and durable speech jobs so those paths cannot silently
select different evidence records.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, replace
from typing import Any, Literal, cast

from speechrail.application.render_receipts import observed_runtime_revision_for_voice
from speechrail.backends.model_identity import is_observed_runtime_revision
from speechrail.config.model_catalog import ModelArtifact
from speechrail.domain.ports import SpeechRequest
from speechrail.domain.tts import (
    VoiceProfile,
    VoiceRegistry,
    VoiceRevisionConflictError,
    VoiceStoreUnavailableError,
    get_voice_registry,
)
from speechrail.domain.tts_errors import TtsBackendError
from speechrail.domain.tts_execution import VoicePreparer, VoiceRuntimeIdentity
from speechrail.domain.voice_quality import POLICY_VERSION
from speechrail.domain.voice_validation import (
    RETIRED_VALIDATION_PROBE_SETS,
    VoiceValidationArtifact,
    VoiceValidationRepository,
    VoiceValidationStoreUnavailableError,
)
from speechrail.domain.voice_validation_policy import (
    VoiceValidationVerdict,
    evaluate_voice_validation,
)

REFERENCE_PREPROCESS_VERSION = "energy_v1"
BASE_GENERATION_RECIPE_REVISION = "qwen3_tts_base_clone_v1"
RuntimeIdentityStatus = Literal["not_requested", "unknown", "observed", "recorded"]


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
    capability_key: str | None = None

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
            "capability_key": self.capability_key,
        }


def build_validation_binding(
    profile: VoiceProfile,
    artifact: ModelArtifact | VoiceValidationArtifact | None,
    runtime_identity: VoiceRuntimeIdentity | None = None,
    *,
    require_current_binding: bool = False,
    observed_runtime_revision: str | None = None,
    capability_key: str | None = None,
) -> VoiceValidationBinding:
    """Build the current binding without loading a worker or model.

    ``capability_key`` names the exact tier/mode combination the evidence must
    cover (for example ``quality.render``).  One validated combination never
    proves another, so a digest for a different scope can never satisfy this
    binding.
    """

    runtime_revision = (
        observed_runtime_revision
        if observed_runtime_revision is not None
        else (
            observed_runtime_revision_for_voice(runtime_identity, profile.id)
            if runtime_identity is not None
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
        capability_key=capability_key,
    )


def _admits_production(evidence: dict[str, Any] | None) -> bool:
    """Whether a matching record may still gate production synthesis.

    Retiring a probe set withdraws it from the admission decision without
    deleting or rewriting it: the record stays readable for diagnostics, the
    voice stays usable under an explicit unverified policy, and a current
    quality run can replace it.
    """

    return evidence is not None and evidence.get("probe_set") not in (
        RETIRED_VALIDATION_PROBE_SETS
    )


def load_validation_evidence(
    repository: VoiceValidationRepository,
    binding: VoiceValidationBinding,
    *,
    require_current_binding: bool,
) -> dict[str, Any] | None:
    """Read only evidence matching the supplied binding and still trusted."""

    evidence = repository.get(
        voice_id=binding.voice_id,
        voice_revision=binding.voice_revision,
        model_artifact=binding.model_artifact,
        model_catalog_revision=binding.model_catalog_revision,
        model_runtime_revision=binding.model_runtime_revision,
        runtime_fingerprint=binding.runtime_fingerprint,
        preprocess_version=binding.preprocess_version,
        generation_recipe_revision=binding.generation_recipe_revision,
        policy_version=binding.policy_version,
        capability_key=binding.capability_key,
        require_current_binding=require_current_binding,
    )
    return evidence if _admits_production(evidence) else None


def _binding_from_recorded_runtime(
    binding: VoiceValidationBinding,
    repository: VoiceValidationRepository,
) -> VoiceValidationBinding | None:
    """Rebuild a binding from the runtime identity the evidence itself records.

    A runtime revision is a property of the loaded model snapshot, not of the
    worker's residency: ``qwen3_tts.runtime_revision`` reports ``None`` while
    the worker is cold-evicted, which made ``production_ready`` flip with
    occupancy while the evidence stayed byte-identical. Reading readiness must
    therefore not depend on a worker happening to be up.

    The recorded identity is only usable when it is self-consistent: it has to
    carry the canonical observed shape *and* its fingerprint has to recompute
    from its own binding dimensions. Anything else — no record, a record from a
    legacy path without a runtime, a hand-edited fingerprint — returns ``None``
    so the caller keeps reporting an unknown identity and the voice stays
    unready. Genuine staleness is unaffected: when a worker *is* resident its
    live revision is compared against the record exactly as before.
    """

    if binding.model_runtime_revision is not None:
        return None
    candidate = repository.get(
        voice_id=binding.voice_id,
        voice_revision=binding.voice_revision,
        model_artifact=binding.model_artifact,
        model_catalog_revision=binding.model_catalog_revision,
        preprocess_version=binding.preprocess_version,
        generation_recipe_revision=binding.generation_recipe_revision,
        policy_version=binding.policy_version,
        capability_key=binding.capability_key,
    )
    if candidate is None or not _admits_production(candidate):
        return None
    runtime_revision = candidate.get("model_runtime_revision")
    if not is_observed_runtime_revision(runtime_revision):
        return None
    expected_fingerprint = _runtime_fingerprint(
        runtime_revision=cast(str, runtime_revision),
        model_artifact=binding.model_artifact or "",
        model_catalog_revision=binding.model_catalog_revision or "",
        preprocess_version=binding.preprocess_version,
        generation_recipe_revision=binding.generation_recipe_revision,
        policy_version=binding.policy_version,
    )
    if candidate.get("runtime_fingerprint") != expected_fingerprint:
        return None
    return replace(
        binding,
        model_runtime_revision=cast(str, runtime_revision),
        runtime_fingerprint=expected_fingerprint,
        runtime_identity_status="recorded",
    )


def validation_verdict_for_voice(
    profile: VoiceProfile,
    artifact: ModelArtifact | VoiceValidationArtifact | None,
    repository: VoiceValidationRepository,
    runtime_identity: VoiceRuntimeIdentity | None = None,
    *,
    require_current_binding: bool,
    capability_key: str | None = None,
    observed_runtime_revision: str | None = None,
) -> tuple[VoiceValidationVerdict, dict[str, Any] | None, VoiceValidationBinding]:
    """Return the evidence, binding, and shared typed validation verdict."""

    binding = build_validation_binding(
        profile,
        artifact,
        runtime_identity,
        require_current_binding=require_current_binding,
        capability_key=capability_key,
        observed_runtime_revision=observed_runtime_revision,
    )
    evidence = load_validation_evidence(
        repository,
        binding,
        require_current_binding=require_current_binding,
    )
    if evidence is None and require_current_binding:
        recorded = _binding_from_recorded_runtime(binding, repository)
        if recorded is not None:
            binding = recorded
            evidence = load_validation_evidence(
                repository,
                binding,
                require_current_binding=require_current_binding,
            )
    state = evaluate_voice_validation(
        profile,
        artifact,
        evidence,
        runtime_revision=binding.model_runtime_revision,
        runtime_identity_status=binding.runtime_identity_status,
        validation_binding=binding.as_mapping(),
        binding_required=require_current_binding,
    )
    return state, evidence, binding


async def prepare_validated_speech(
    request: SpeechRequest,
    *,
    preparer: VoicePreparer | None,
    artifact: ModelArtifact | VoiceValidationArtifact | None,
    capability_key: str | None,
    registry: VoiceRegistry | None = None,
) -> SpeechRequest:
    """Prepare a strict request's worker and admit only current evidence.

    The caller must already hold the TTS resource admission.  This helper never
    synthesizes probe audio and never falls back to an unobserved worker
    identity.  On success the returned request pins both the voice revision and
    the exact worker runtime that the evidence was checked against.
    """

    if request.validation_policy != "require_output_pass":
        return request

    registry = registry or get_voice_registry()
    try:
        profile = registry.get_profile(request.voice)
    except VoiceStoreUnavailableError as exc:
        raise TtsBackendError(
            "voice_store_unavailable",
            stage="validate",
            public_code="voice_store_unavailable",
            retryable=True,
        ) from exc
    if (
        request.expected_voice_revision is not None
        and profile.revision != request.expected_voice_revision
    ):
        raise VoiceRevisionConflictError(
            "requested voice revision no longer matches the resolved voice"
        )
    if profile.mode != "clone":
        return request

    if preparer is None:
        raise TtsBackendError(
            "voice_validation_runtime_unavailable",
            stage="validate",
            public_code="voice_validation_runtime_unavailable",
            retryable=True,
        )
    try:
        runtime_revision = await preparer.prepare_voice(
            request.voice,
            expected_voice_revision=profile.revision,
        )
    except TtsBackendError:
        raise
    except Exception as exc:
        # `asyncio.CancelledError` derives from BaseException, so it is
        # deliberately not caught here: cancellation has to propagate so the
        # caller's admission can release the slot and lease it still holds.
        raise TtsBackendError(
            "voice_validation_runtime_unavailable",
            stage="validate",
            public_code="voice_validation_runtime_unavailable",
            retryable=True,
        ) from exc
    # Only the canonical handshake shape may travel in `expected_runtime_revision`,
    # which is declared with that exact pattern. A backend that reports some
    # other string is treated as "identity unknown" rather than trusted.
    if not is_observed_runtime_revision(runtime_revision):
        raise TtsBackendError(
            "voice_validation_runtime_unavailable",
            stage="validate",
            public_code="voice_validation_runtime_unavailable",
            retryable=True,
        )

    try:
        state, _evidence, _binding = validation_verdict_for_voice(
            profile,
            artifact,
            registry.validation_store,
            require_current_binding=True,
            capability_key=capability_key,
            observed_runtime_revision=runtime_revision,
        )
    except VoiceValidationStoreUnavailableError as exc:
        raise TtsBackendError(
            "voice_validation_store_unavailable",
            stage="validate",
            public_code="voice_validation_store_unavailable",
            retryable=True,
        ) from exc
    if not state.production_ready:
        raise TtsBackendError(
            "voice_not_production_ready",
            stage="validate",
            public_code="voice_not_production_ready",
            retryable=False,
        )
    return request.model_copy(
        update={
            "expected_voice_revision": profile.revision,
            "expected_runtime_revision": runtime_revision,
        }
    )


__all__ = [
    "BASE_GENERATION_RECIPE_REVISION",
    "REFERENCE_PREPROCESS_VERSION",
    "RuntimeIdentityStatus",
    "VoiceValidationBinding",
    "build_validation_binding",
    "load_validation_evidence",
    "prepare_validated_speech",
    "validation_verdict_for_voice",
]
