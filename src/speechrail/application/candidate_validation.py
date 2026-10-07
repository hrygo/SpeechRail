"""Candidate validation owns revision checks, human review and evidence commit."""

from __future__ import annotations

import asyncio
import hashlib
import json
import time
from dataclasses import dataclass
from typing import Literal

from speechrail.application.tts_admission import tts_resource_key
from speechrail.application.voice_design import (
    VOICE_DESIGN_VALIDATION_POLICY_REVISION,
    VoiceDesignActionError,
    VoiceDesignCandidate,
    VoiceDesignConflictError,
    VoiceDesignRepository,
    VoiceDesignReview,
    VoiceDesignValidation,
    review_state_for,
)
from speechrail.application.voice_validation_execution import (
    TRANSCRIPT_PASS_SCORE,
    TRANSCRIPT_WARN_SCORE,
    ValidationRuntime,
    execute_candidate_validation,
)
from speechrail.application.voice_validation_gate import build_validation_binding
from speechrail.config.selection import ActiveModelCatalog
from speechrail.domain import voice_quality as vq
from speechrail.domain.tts import normalize_tts_text, use_voice_profile

MAX_VALIDATION_PCM_BYTES = 30 * 24_000 * 2
MAX_VALIDATION_WAV_BYTES = MAX_VALIDATION_PCM_BYTES + 44
CONTROLLED_TEST_TEXTS = (
    "今天的天气很适合在公园里慢慢散步，听听周围自然的声音。",
    "请用平稳自然的语气朗读这句话，注意每个字的清晰程度。",
    "生活里的小事往往最值得记录，比如清晨第一缕阳光照进房间。",
)


@dataclass(frozen=True)
class CandidateHumanReview:
    validation_id: str
    identity: VoiceDesignReview
    naturalness: VoiceDesignReview


def apply_human_review(
    repository: VoiceDesignRepository,
    candidate: VoiceDesignCandidate,
    review: CandidateHumanReview,
    *,
    capability_key: str,
) -> VoiceDesignCandidate:
    validation = next(
        (item for item in candidate.validations if item.validation_id == review.validation_id),
        None,
    )
    if validation is None:
        raise VoiceDesignActionError(
            "voice_design_validation_not_found",
            "Validation result was not found for this candidate",
            status_code=404,
        )
    if validation.candidate_revision != candidate.revision:
        raise VoiceDesignActionError(
            "voice_design_revision_conflict",
            "Validation belongs to an older candidate revision",
            status_code=409,
        )
    if not candidate.has_current_machine_pass(review.validation_id, capability_key=capability_key):
        raise VoiceDesignActionError(
            "voice_design_machine_validation_required",
            "Human review can only follow a passing Base validation under the current "
            "text-fidelity policy for this candidate revision",
            status_code=409,
        )
    now = time.time()

    def apply(current: VoiceDesignCandidate) -> VoiceDesignCandidate:
        current.require_validation_writable(expected_revision=candidate.revision)
        if not current.has_current_machine_pass(
            review.validation_id, capability_key=capability_key
        ):
            raise VoiceDesignConflictError("validation record changed")
        latest = next(
            item for item in current.validations if item.validation_id == review.validation_id
        )
        status: Literal["pass", "warn", "reject"]
        if "reject" in {review.identity, review.naturalness}:
            status = "reject"
        elif (
            review.identity == review.naturalness == "pass"
            and latest.runtime_fingerprint is not None
        ):
            status = "pass"
        else:
            status = "warn"
        reviewed = latest.model_copy(
            update={
                "identity_status": review.identity,
                "naturalness_status": review.naturalness,
                "status": status,
                "updated_at": max(latest.updated_at, now),
            }
        )
        merged = current.model_copy(
            update={
                "validations": [
                    reviewed if item.validation_id == reviewed.validation_id else item
                    for item in current.validations
                ],
                "updated_at": max(current.updated_at, reviewed.updated_at),
            }
        )
        return merged.model_copy(update={"state": review_state_for(merged)})

    return repository.update(candidate.candidate_id, apply)


async def validate_candidate(
    *,
    repository: VoiceDesignRepository,
    candidate_id: str,
    active: ActiveModelCatalog,
    runtime: ValidationRuntime,
    selected_capability_key: str,
    requested_capability_key: str | None,
    test_text: str | None,
    human_review: CandidateHumanReview | None,
    expires_at: float,
) -> VoiceDesignCandidate:
    candidate = repository.get(candidate_id)
    if candidate.state not in {"confirmed", "validating", "publishable"}:
        raise VoiceDesignActionError(
            "voice_design_state_conflict",
            f"Candidate {candidate.candidate_id!r} is in state {candidate.state!r}",
            status_code=409,
        )
    capability_key = requested_capability_key or selected_capability_key
    if capability_key != selected_capability_key:
        raise VoiceDesignActionError(
            "voice_design_capability_mismatch",
            "VoiceDesign validation must be observed for the currently selected render capability",
            status_code=422,
        )
    if human_review is not None:
        return apply_human_review(
            repository, candidate, human_review, capability_key=capability_key
        )

    normalized_text = (
        normalize_tts_text(test_text)
        if test_text is not None
        else next(
            (
                text
                for text in CONTROLLED_TEST_TEXTS
                if normalize_tts_text(text) != candidate.reference_text
            ),
            None,
        )
    )
    if normalized_text is None:
        raise VoiceDesignActionError(
            "controlled_test_text_conflict",
            "No controlled test text differs from the candidate reference text; "
            "pass an explicit test_text",
            status_code=422,
        )
    if not 20 <= len(normalized_text) <= 240:
        raise VoiceDesignActionError(
            "invalid_test_text",
            "Normalized test text must contain 20 to 240 characters",
            status_code=422,
        )
    if normalized_text == candidate.reference_text:
        raise VoiceDesignActionError(
            "test_text_matches_reference",
            "Base validation requires a different test text",
            status_code=422,
        )
    base = active.tts_clone
    synthesizer = runtime.synthesizer
    if base is None or base.variant != "base" or synthesizer is None:
        raise VoiceDesignActionError(
            "voice_design_base_unavailable",
            "Base validation requires an active Base capability",
            status_code=503,
            retryable=True,
        )
    now = time.time()

    def mark_validating(current: VoiceDesignCandidate) -> VoiceDesignCandidate:
        current.require_validation_writable(expected_revision=candidate.revision)
        return current.model_copy(
            update={"state": review_state_for(current), "updated_at": max(current.updated_at, now)}
        )

    repository.update(candidate_id, mark_validating)
    profile = candidate.profile()
    with use_voice_profile(profile):
        result = await execute_candidate_validation(
            synthesizer=synthesizer,
            transcriber=runtime.transcriber,
            governor=runtime.governor,
            admission=runtime.admission,
            test_text=normalized_text,
            candidate_voice_id=profile.id,
            candidate_language=candidate.language,
            candidate_revision=candidate.revision,
            resource_key=tts_resource_key(synthesizer, profile.id),
            expires_at=expires_at,
            max_pcm_bytes=MAX_VALIDATION_PCM_BYTES,
        )
    # Only immutable run facts enter the binding. Omitting the synthesizer is
    # deliberate: an unknown producing identity must not be backfilled later.
    binding = build_validation_binding(
        profile,
        base,
        require_current_binding=True,
        observed_runtime_revision=result.evidence.model_runtime_revision,
        capability_key=capability_key,
    )
    validation = build_candidate_validation(
        candidate=candidate,
        capability_key=capability_key,
        test_text=normalized_text,
        output_pcm=result.output_pcm,
        quality=result.quality,
        transcript=result.transcript,
        transcript_match=result.transcript_match,
        output_wav_sha256=result.output_wav_sha256,
        model_artifact=base.key,
        model_catalog_revision=base.revision,
        model_runtime_revision=binding.model_runtime_revision,
        runtime_fingerprint=binding.runtime_fingerprint,
        preprocess_version=binding.preprocess_version,
        generation_recipe_revision=binding.generation_recipe_revision,
        policy_version=binding.policy_version,
    )
    if asyncio.get_running_loop().time() >= expires_at:
        raise TimeoutError
    return repository.update_with_validation_audio(
        candidate_id,
        expected_revision=candidate.revision,
        validation=validation,
        audio_bytes=result.output_wav,
        max_bytes=MAX_VALIDATION_WAV_BYTES,
    )


def _hash_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _validation_id(
    *,
    candidate_revision: str,
    capability_key: str,
    validation_policy_revision: str,
    test_text_sha256: str,
    transcript_text_sha256: str | None,
    output_audio_sha256: str,
    model_artifact: str,
    model_catalog_revision: str,
    model_runtime_revision: str | None,
    runtime_fingerprint: str | None,
    preprocess_version: str,
    generation_recipe_revision: str,
    policy_version: str,
) -> str:
    digest = hashlib.sha256(
        json.dumps(
            {
                "candidate_revision": candidate_revision,
                "capability_key": capability_key,
                "validation_policy_revision": validation_policy_revision,
                "test_text_sha256": test_text_sha256,
                "transcript_text_sha256": transcript_text_sha256,
                "output_audio_sha256": output_audio_sha256,
                "model_artifact": model_artifact,
                "model_catalog_revision": model_catalog_revision,
                "model_runtime_revision": model_runtime_revision,
                "runtime_fingerprint": runtime_fingerprint,
                "preprocess_version": preprocess_version,
                "generation_recipe_revision": generation_recipe_revision,
                "policy_version": policy_version,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return f"vv_{digest[:24]}"


def build_candidate_validation(
    *,
    candidate: VoiceDesignCandidate,
    capability_key: str,
    test_text: str,
    output_pcm: bytes,
    quality: vq.VoiceQualityReport,
    transcript: str | None,
    transcript_match: float | None,
    output_wav_sha256: str,
    model_artifact: str,
    model_catalog_revision: str,
    model_runtime_revision: str | None,
    runtime_fingerprint: str | None,
    preprocess_version: str,
    generation_recipe_revision: str,
    policy_version: str,
) -> VoiceDesignValidation:
    test_text_sha256 = _hash_text(test_text)
    transcript_text_sha256 = _hash_text(transcript) if transcript is not None else None
    # Character edit distance cannot see a misread digit: swapping one digit in
    # a long probe still scores above the pass threshold, while the number the
    # listener hears is simply wrong.  Numbers are therefore compared by value,
    # independently of the similarity score.
    transcript_numbers_match = (
        vq.transcript_numbers_match(test_text, transcript) if transcript is not None else None
    )
    validation_id = _validation_id(
        candidate_revision=candidate.revision,
        capability_key=capability_key,
        validation_policy_revision=VOICE_DESIGN_VALIDATION_POLICY_REVISION,
        test_text_sha256=test_text_sha256,
        transcript_text_sha256=transcript_text_sha256,
        output_audio_sha256=hashlib.sha256(output_pcm).hexdigest(),
        model_artifact=model_artifact,
        model_catalog_revision=model_catalog_revision,
        model_runtime_revision=model_runtime_revision,
        runtime_fingerprint=runtime_fingerprint,
        preprocess_version=preprocess_version,
        generation_recipe_revision=generation_recipe_revision,
        policy_version=policy_version,
    )
    failures: list[str] = []
    machine_status: Literal["pass", "warn", "reject"]
    if quality.status == vq.VoiceQualityStatus.REJECT.value:
        machine_status = "reject"
        failures.append("output_invalid")
    elif transcript_match is None or transcript_numbers_match is None:
        machine_status = "warn"
        failures.append("transcription_unavailable")
    else:
        if transcript_match >= TRANSCRIPT_PASS_SCORE:
            machine_status = "pass"
        elif transcript_match >= TRANSCRIPT_WARN_SCORE:
            machine_status = "warn"
            failures.append("transcript_warn")
        else:
            machine_status = "reject"
            failures.append("transcript_mismatch")
        if machine_status != "reject" and not transcript_numbers_match:
            # The sentence as a whole was close enough to pass on similarity,
            # yet it says a different number.  Report the number, which is the
            # actionable defect, rather than the similarity it also tripped.
            machine_status = "reject"
            failures = ["transcript_numbers_mismatch"]
    if model_runtime_revision is None or runtime_fingerprint is None:
        machine_status = "warn" if machine_status != "reject" else machine_status
        failures.append("model_runtime_identity_unknown")
    now = time.time()
    return VoiceDesignValidation(
        validation_id=validation_id,
        candidate_revision=candidate.revision,
        status="warn",
        machine_status=machine_status,
        failure_codes=failures,
        transcript_numbers_match=transcript_numbers_match,
        validation_policy_revision=VOICE_DESIGN_VALIDATION_POLICY_REVISION,
        capability_key=capability_key,
        model_artifact=model_artifact,
        model_catalog_revision=model_catalog_revision,
        model_runtime_revision=model_runtime_revision,
        runtime_fingerprint=runtime_fingerprint,
        preprocess_version=preprocess_version,
        generation_recipe_revision=generation_recipe_revision,
        policy_version=policy_version,
        test_text_sha256=test_text_sha256,
        output_audio_sha256=hashlib.sha256(output_pcm).hexdigest(),
        output_wav_sha256=output_wav_sha256,
        transcript_text_sha256=(_hash_text(transcript) if transcript is not None else None),
        transcript_match=transcript_match,
        created_at=now,
        updated_at=now,
    )
