"""Versioned, multi-dimensional voice quality evidence projections."""

from __future__ import annotations

from typing import Any

from speechrail.domain.tts import VoiceProfile
from speechrail.domain.voice_quality import VoiceQualityReport

EVIDENCE_POLICY_VERSION = "voice_quality_evidence_v2"


def _dimension(
    status: str,
    *,
    method: str,
    reason: str | None = None,
    metrics: dict[str, object] | None = None,
) -> dict[str, object]:
    data: dict[str, object] = {
        "status": status,
        "method": method,
    }
    if reason is not None:
        data["reason"] = reason
    if metrics:
        data["metrics"] = metrics
    return data


def build_quality_evidence(
    *,
    profile: VoiceProfile,
    report: VoiceQualityReport,
    probe_set: str,
    repetitions: int,
    model_artifact: str | None,
    model_source: str | None,
    model_variant: str | None,
    model_catalog_revision: str | None,
    model_runtime_revision: str | None = None,
) -> dict[str, Any]:
    """Project legacy measurements into explicit independent evidence dimensions."""

    synthesis = report.synthesis
    reference_status = "unevaluated"
    reference_reason = "reference_evidence_not_available"
    if profile.quality is not None:
        raw_status = profile.quality.get("status")
        if raw_status in {"pass", "warn", "reject", "unevaluated"}:
            reference_status = str(raw_status)
            reference_reason = "persisted_reference_quality_report"
    elif profile.mode != "clone":
        reference_reason = "not_a_reference_conditioned_voice"

    if synthesis.intelligibility_evaluated and synthesis.transcript_match is not None:
        intelligibility = _dimension(
            (
                "pass"
                if synthesis.transcript_match >= 0.90
                else "warn"
                if synthesis.transcript_match >= 0.80
                else "reject"
            ),
            method="local_asr_transcript_match",
            metrics={"transcript_match": synthesis.transcript_match},
        )
    else:
        intelligibility = _dimension(
            "unevaluated",
            method="local_asr_transcript_match",
            reason="asr_evidence_missing",
        )

    if synthesis.successful_probe_count != synthesis.probe_count:
        loudness = _dimension(
            "reject",
            method="pcm16_signal_metrics",
            reason="incomplete_probe_set",
            metrics={
                "successful_probe_count": synthesis.successful_probe_count,
                "probe_count": synthesis.probe_count,
            },
        )
    elif synthesis.clipping_ratio > 0.0:
        loudness = _dimension(
            "reject",
            method="pcm16_signal_metrics",
            reason="clipping_detected",
            metrics={
                "active_rms_dbfs": synthesis.active_rms_dbfs,
                "peak_dbfs": synthesis.peak_dbfs,
                "clipping_ratio": synthesis.clipping_ratio,
            },
        )
    else:
        loudness = _dimension(
            "pass",
            method="pcm16_signal_metrics",
            metrics={
                "active_rms_dbfs": synthesis.active_rms_dbfs,
                "peak_dbfs": synthesis.peak_dbfs,
                "chunk_jump_p95_db": synthesis.chunk_jump_p95_db,
                "clipping_ratio": synthesis.clipping_ratio,
            },
        )

    if repetitions < 2 or synthesis.successful_probe_count != synthesis.probe_count:
        repeatability = _dimension(
            "unevaluated",
            method="exact_pcm_sha256_repeatability",
            reason="insufficient_successful_repetitions",
        )
    else:
        repeatability = _dimension(
            "pass" if synthesis.deterministic else "warn",
            method="exact_pcm_sha256_repeatability",
            reason=None if synthesis.deterministic else "byte_identity_not_observed",
            metrics={"deterministic": synthesis.deterministic},
        )

    return {
        "policy_version": EVIDENCE_POLICY_VERSION,
        "run_id": report.run_id,
        "tested_at": report.tested_at,
        "identity": {
            "voice_id": profile.id,
            "voice_revision": profile.revision,
            "voice_identity_assurance": (
                "content_addressed" if profile.revision is not None else "legacy"
            ),
            "model": {
                "artifact": model_artifact,
                "source_model": model_source,
                "variant": model_variant,
                "catalog_revision": model_catalog_revision,
                "runtime_revision": model_runtime_revision,
            },
        },
        "scope": {
            "probe_set": probe_set,
            "repetitions": repetitions,
            "probe_count": synthesis.probe_count,
            "successful_probe_count": synthesis.successful_probe_count,
        },
        "dimensions": {
            "reference_signal": _dimension(
                reference_status,
                method="persisted_reference_signal_gate",
                reason=reference_reason,
            ),
            "synthesis_intelligibility": intelligibility,
            "cross_text_identity": _dimension(
                "unevaluated",
                method="independent_speaker_identity",
                reason="independent_identity_evidence_missing",
            ),
            "naturalness_performance": _dimension(
                "unevaluated",
                method="human_blind_listening",
                reason="approved_human_listening_evidence_missing",
            ),
            "loudness_peak": loudness,
            "repeatability": repeatability,
        },
        "guarantees": {
            "identity_is_not_inferred_from_repeatability": True,
            "reference_success_does_not_imply_synthesis_success": True,
            "missing_human_evidence_remains_unevaluated": True,
        },
    }
