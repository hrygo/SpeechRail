"""Fixed-probe quality runs own measurement, binding and durable evidence commit."""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Any

from speechrail.application.render_receipts import observed_runtime_revision_for_voice
from speechrail.application.tts_admission import tts_resource_key
from speechrail.application.voice_validation_execution import (
    ValidationRuntime,
    VoiceValidationExecutionError,
    evaluate_probe_intelligibility,
    evict_quality_tts_if_supported,
    grade_quality_status,
    synthesis_report,
    synthesize_probes,
)
from speechrail.application.voice_validation_gate import build_validation_binding
from speechrail.config.selection import ActiveModelCatalog
from speechrail.domain import voice_quality as vq
from speechrail.domain.tts import (
    VoiceRevisionConflictError,
    VoiceRevokedError,
    VoiceStoreUnavailableError,
)
from speechrail.domain.tts_routing import TtsExecutionMode, tts_capability_key
from speechrail.domain.voice_ports import VoiceValidationWriter
from speechrail.domain.voice_quality_evidence import build_quality_evidence
from speechrail.domain.voice_validation import (
    OUTPUT_VALIDATION_SCOPE,
    VoiceValidationStoreUnavailableError,
)
from speechrail.runtime.admission import QueueFullError
from speechrail.runtime.resource_governor import GovernorQueueFullError, WorkClass, WorkPurpose

_LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class QualityRunResult:
    report: vq.VoiceQualityReport
    evidence: dict[str, Any]
    validation_persisted: bool


async def run_voice_quality(
    *,
    voice_id: str,
    registry: VoiceValidationWriter,
    active: ActiveModelCatalog,
    runtime: ValidationRuntime,
    runs: int,
    probe_set: str,
    request_id: str,
    expires_at: float,
) -> QualityRunResult:
    if probe_set != "voice_quality_v1_zh" or type(runs) is not int or not 1 <= runs <= 3:
        raise ValueError("invalid fixed quality probe request")
    synthesizer = runtime.synthesizer
    if synthesizer is None:
        raise VoiceValidationExecutionError(
            "backend_not_ready",
            "SpeechRail TTS backend is not ready",
            retryable=True,
        )
    # The reference asset and immutable voice snapshot remain owned through
    # ASR and commit; each production request remains pinned to this revision.
    with registry.lease_profile(voice_id) as profile:
        resource_key = tts_resource_key(runtime.tts_execution.lanes, profile.id)
        # Readiness includes quarantine. Let the Governor reject an isolated
        # lane with its non-retryable reclamation error instead of masking it.
        if not runtime.tts_ready and not runtime.governor.tts_lane_isolated(resource_key):
            raise VoiceValidationExecutionError(
                "backend_not_ready",
                "SpeechRail TTS backend is not ready",
                retryable=True,
            )
        reclamation_failed = False

        def quarantine() -> None:
            nonlocal reclamation_failed
            reclamation_failed = True
            runtime.governor.quarantine_tts_lane(resource_key)

        try:
            async with runtime.governor.reserve(
                WorkClass.BATCH_TTS,
                expires_at=expires_at,
                resource_key=resource_key,
                purpose=WorkPurpose.QUALITY_VALIDATION,
            ):
                (
                    pcm,
                    attempted,
                    ok,
                    probe_failures,
                    deterministic,
                    representative_pcm,
                ) = await synthesize_probes(
                    synthesizer,
                    profile.id,
                    runs,
                    voice_revision=profile.revision,
                    expires_at=expires_at,
                    on_close_failure=quarantine,
                )
                producing_revision = observed_runtime_revision_for_voice(
                    runtime.tts_execution.runtime_identity, profile.id
                )
        except TimeoutError:
            raise VoiceValidationExecutionError(
                "backend_timeout",
                "Voice quality run timed out",
                retryable=True,
            ) from None

        transcript_match: float | None = None
        probe_scores: list[vq.VoiceQualityProbeScore] = []
        intelligibility_evaluated = False
        intelligibility_unavailable = False
        if ok == attempted and not probe_failures:
            transcriber = runtime.transcriber
            if transcriber is None or not runtime.asr_ready:
                intelligibility_unavailable = True
            else:
                try:
                    async with runtime.governor.reserve(
                        WorkClass.BATCH_TTS,
                        expires_at=expires_at,
                        resource_key=resource_key,
                        purpose=WorkPurpose.QUALITY_VALIDATION,
                    ):
                        await evict_quality_tts_if_supported(
                            synthesizer,
                            expires_at=expires_at,
                            on_reclamation_failure=quarantine,
                        )
                    transcript_match, probe_scores = await evaluate_probe_intelligibility(
                        governor=runtime.governor,
                        admission=runtime.admission,
                        transcriber=transcriber,
                        representative_pcm=representative_pcm,
                        request_id=request_id,
                        expires_at=expires_at,
                    )
                    intelligibility_evaluated = True
                except GovernorQueueFullError, QueueFullError:
                    raise
                except TimeoutError:
                    raise VoiceValidationExecutionError(
                        "backend_timeout",
                        "Voice intelligibility validation timed out",
                        retryable=True,
                    ) from None
                except Exception:
                    # Failed eviction leaves TTS ownership uncertain. Propagate
                    # before starting ASR or writing validation evidence.
                    if reclamation_failed:
                        raise VoiceValidationExecutionError(
                            "backend_reclamation_failed",
                            "TTS resources could not be reclaimed",
                        ) from None
                    _LOGGER.warning(
                        "voice intelligibility validation unavailable: "
                        "code=transcription_unavailable request_id=%s",
                        request_id,
                    )
                    intelligibility_unavailable = True

        output_invalid = False
        try:
            synthesis = synthesis_report(
                pcm,
                attempted,
                ok,
                deterministic=deterministic,
                transcript_match=transcript_match,
                intelligibility_evaluated=intelligibility_evaluated,
                probe_scores=probe_scores,
            )
        except ValueError, TypeError:
            synthesis = vq.VoiceQualitySynthesis(
                probe_count=attempted,
                successful_probe_count=ok,
                active_rms_dbfs=-240.0,
                peak_dbfs=-240.0,
                chunk_jump_p95_db=0.0,
                clipping_ratio=0.0,
                deterministic=False,
                transcript_match=transcript_match,
                intelligibility_evaluated=intelligibility_evaluated,
                probe_scores=probe_scores,
            )
            output_invalid = True
        status, failure_codes = grade_quality_status(
            attempted=attempted,
            ok=ok,
            output_invalid=output_invalid,
            probe_failure_codes=probe_failures,
            transcript_match=transcript_match,
            intelligibility_evaluated=intelligibility_evaluated,
            intelligibility_unavailable=intelligibility_unavailable,
        )
        report = vq.VoiceQualityReport(
            policy_version=vq.POLICY_VERSION,
            status=status,
            run_id=vq.new_run_id(),
            tested_at=vq.now_iso8601_z(),
            reference=None,
            synthesis=synthesis,
            failure_codes=failure_codes,
        )
        artifact = active.artifact_for_voice_mode(profile.mode)
        # No live synthesizer lookup here: even an unknown producing identity
        # is a run fact, not a reason to adopt a later worker's identity.
        binding = build_validation_binding(
            profile,
            artifact,
            require_current_binding=True,
            observed_runtime_revision=producing_revision,
            capability_key=(
                tts_capability_key(active.tts_spec, TtsExecutionMode.RENDER)
                if active.tts_spec is not None
                else None
            ),
        )
        if asyncio.get_running_loop().time() >= expires_at:
            raise VoiceValidationExecutionError(
                "backend_timeout",
                "Voice quality run timed out",
                retryable=True,
            )
        persisted = True
        try:
            registry.update_quality_validation(
                profile.id,
                {
                    "voice_id": profile.id,
                    "status": report.status,
                    "identity_status": "unevaluated",
                    "run_id": report.run_id,
                    "tested_at": report.tested_at,
                    "policy_version": report.policy_version,
                    "voice_revision": profile.revision,
                    "model_artifact": artifact.key if artifact is not None else None,
                    "model_source": artifact.model_id if artifact is not None else None,
                    "model_variant": artifact.variant if artifact is not None else None,
                    "model_catalog_revision": artifact.revision if artifact is not None else None,
                    "model_runtime_revision": producing_revision,
                    "runtime_fingerprint": binding.runtime_fingerprint,
                    "preprocess_version": binding.preprocess_version,
                    "generation_recipe_revision": binding.generation_recipe_revision,
                    "probe_set": probe_set,
                    "repetitions": runs,
                    "capability_key": binding.capability_key,
                    "failure_codes": list(report.failure_codes),
                    "validated_for": (
                        [OUTPUT_VALIDATION_SCOPE]
                        if report.status
                        in {
                            vq.VoiceQualityStatus.PASS.value,
                            vq.VoiceQualityStatus.WARN.value,
                        }
                        else []
                    ),
                },
                expected_revision=profile.revision,
            )
        except (
            VoiceStoreUnavailableError,
            VoiceValidationStoreUnavailableError,
            KeyError,
            ValueError,
            VoiceRevisionConflictError,
            VoiceRevokedError,
        ):
            persisted = False
        evidence = build_quality_evidence(
            profile=profile,
            report=report,
            probe_set=probe_set,
            repetitions=runs,
            model_artifact=artifact.key if artifact is not None else None,
            model_source=artifact.model_id if artifact is not None else None,
            model_variant=artifact.variant if artifact is not None else None,
            model_catalog_revision=artifact.revision if artifact is not None else None,
            model_runtime_revision=producing_revision,
            validation_binding=binding.as_mapping(),
        )
        return QualityRunResult(report=report, evidence=evidence, validation_persisted=persisted)
