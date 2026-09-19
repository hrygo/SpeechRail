from __future__ import annotations

from speechrail.domain.tts import VoiceProfile
from speechrail.domain.voice_quality import (
    VoiceQualityReference,
    VoiceQualityReport,
    VoiceQualitySynthesis,
)
from speechrail.domain.voice_quality_evidence import (
    EVIDENCE_POLICY_VERSION,
    build_quality_evidence,
)


def _report(
    *,
    deterministic: bool = True,
    transcript_match: float | None = 0.95,
    intelligibility_evaluated: bool = True,
) -> VoiceQualityReport:
    return VoiceQualityReport(
        policy_version="voice_quality_v1",
        status="pass",
        run_id="vqr_test",
        tested_at="2026-09-19T00:00:00Z",
        reference=VoiceQualityReference(
            duration_seconds=3.0,
            noise_floor_dbfs=-60.0,
            estimated_snr_db=30.0,
            clipping_ratio=0.0,
            leading_silence_seconds=0.1,
            trailing_silence_seconds=0.1,
            speech_active_ratio=0.8,
            transcript_match=None,
        ),
        synthesis=VoiceQualitySynthesis(
            probe_count=12,
            successful_probe_count=12,
            active_rms_dbfs=-20.0,
            peak_dbfs=-4.0,
            chunk_jump_p95_db=2.0,
            clipping_ratio=0.0,
            deterministic=deterministic,
            transcript_match=transcript_match,
            intelligibility_evaluated=intelligibility_evaluated,
        ),
        failure_codes=[],
    )


def test_evidence_dimensions_keep_identity_independent_from_repeatability() -> None:
    profile = VoiceProfile(
        id="voice",
        mode="instruction",
        instruction="private recipe",
        revision="vr_" + "a" * 32,
    )
    evidence = build_quality_evidence(
        profile=profile,
        report=_report(deterministic=True),
        probe_set="voice_quality_v1_zh",
        repetitions=2,
        model_artifact="artifact",
        model_source="source",
        model_variant="voice_design",
        model_catalog_revision="catalog",
    )
    assert evidence["policy_version"] == EVIDENCE_POLICY_VERSION
    dims = evidence["dimensions"]
    assert dims["repeatability"]["status"] == "pass"
    assert dims["cross_text_identity"]["status"] == "unevaluated"
    assert dims["naturalness_performance"]["status"] == "unevaluated"
    assert evidence["identity"]["voice_revision"] == "vr_" + "a" * 32
    assert evidence["identity"]["model"]["runtime_revision"] is None


def test_missing_asr_remains_unevaluated_not_pass() -> None:
    profile = VoiceProfile(id="voice", mode="instruction")
    evidence = build_quality_evidence(
        profile=profile,
        report=_report(
            transcript_match=None,
            intelligibility_evaluated=False,
        ),
        probe_set="voice_quality_v1_zh",
        repetitions=3,
        model_artifact=None,
        model_source=None,
        model_variant=None,
        model_catalog_revision=None,
    )
    assert (
        evidence["dimensions"]["synthesis_intelligibility"]["status"]
        == "unevaluated"
    )
    assert evidence["identity"]["voice_identity_assurance"] == "legacy"


def test_nondeterminism_does_not_imply_identity_reject() -> None:
    profile = VoiceProfile(
        id="voice",
        mode="instruction",
        revision="vr_" + "b" * 32,
    )
    evidence = build_quality_evidence(
        profile=profile,
        report=_report(deterministic=False),
        probe_set="voice_quality_v1_zh",
        repetitions=3,
        model_artifact="artifact",
        model_source="source",
        model_variant="voice_design",
        model_catalog_revision="catalog",
    )
    assert evidence["dimensions"]["repeatability"]["status"] == "warn"
    assert evidence["dimensions"]["cross_text_identity"]["status"] == "unevaluated"
    assert (
        evidence["guarantees"]["identity_is_not_inferred_from_repeatability"]
        is True
    )


def test_persisted_reference_report_is_a_separate_dimension() -> None:
    profile = VoiceProfile(
        id="clone",
        mode="clone",
        ref_text="private reference",
        audio_path="/private/voice.wav",
        revision="vr_" + "c" * 32,
        quality={"status": "warn", "policy_version": "voice_quality_v1"},
    )
    evidence = build_quality_evidence(
        profile=profile,
        report=_report(),
        probe_set="voice_quality_v1_zh",
        repetitions=2,
        model_artifact="base",
        model_source="source",
        model_variant="base",
        model_catalog_revision="catalog",
    )
    reference = evidence["dimensions"]["reference_signal"]
    assert reference["status"] == "warn"
    encoded = str(evidence)
    assert "private reference" not in encoded
    assert "/private/" not in encoded
