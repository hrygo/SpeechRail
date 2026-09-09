"""Unit tests for the ``voice_quality_v1`` reference-audio grading policy.

Covers the S4.2 metric matrix (just-pass / just-warn / just-reject boundaries),
overall severity aggregation, ``VoiceQualityReport`` serialization round-trip,
and ``VoiceProfile`` backward compatibility when ``quality`` is missing.
"""

from __future__ import annotations

import io
import math
import struct
import wave
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from speechrail.domain.tts import (
    VoiceProfile,
    VoiceRegistry,
    transcode_and_validate_clone_audio,
)
from speechrail.domain.voice_quality import (
    POLICY_VERSION,
    VOICE_QUALITY_V1_ZH_PROBES,
    VoiceQualityReference,
    VoiceQualityReport,
    VoiceQualityStatus,
    VoiceQualitySynthesis,
    clipping_ratio,
    duration_seconds,
    estimated_snr_db,
    grade_reference_quality,
    leading_trailing_silence_seconds,
    make_quality_report,
    noise_floor_dbfs,
    speech_active_ratio,
)

# ---------------------------------------------------------------------------
# Fixtures / builders
# ---------------------------------------------------------------------------


def _pcm16(samples: list[int]) -> bytes:
    return struct.pack(f"<{len(samples)}h", *samples)


def _sine_pcm16(
    duration_seconds: float,
    sample_rate: int = 24_000,
    *,
    frequency_hz: float = 440.0,
    amplitude: float = 0.5,
) -> bytes:
    count = int(duration_seconds * sample_rate)
    samples: list[int] = []
    for index in range(count):
        value = round(
            amplitude * 32767.0 * math.sin(2.0 * math.pi * frequency_hz * index / sample_rate)
        )
        samples.append(max(-32767, min(32767, value)))
    return _pcm16(samples)


def _wav_bytes(duration_seconds: float = 3.0, sample_rate: int = 24_000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(b"\x00\x00" * int(duration_seconds * sample_rate))
    return buf.getvalue()


def _passing_reference() -> VoiceQualityReference:
    return VoiceQualityReference(
        duration_seconds=10.0,
        sample_rate=24_000,
        channels=1,
        speech_active_ratio=0.8,
        noise_floor_dbfs=-60.0,
        estimated_snr_db=30.0,
        clipping_ratio=0.0,
        leading_silence_seconds=0.1,
        trailing_silence_seconds=0.1,
        transcript_match=None,
    )


def _synthesis() -> VoiceQualitySynthesis:
    return VoiceQualitySynthesis(
        probe_count=3,
        successful_probe_count=3,
        active_rms_dbfs=-20.8,
        peak_dbfs=-3.2,
        chunk_jump_p95_db=4.6,
        clipping_ratio=0.0,
        deterministic=True,
    )


# ---------------------------------------------------------------------------
# S4.2 grading matrix — per metric boundaries
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("field", "value", "expected_status", "expected_code"),
    [
        # 有效时长: 4-30 pass / 2-4|30-45 warn / else reject
        ("duration_seconds", 4.0, VoiceQualityStatus.PASS, None),
        ("duration_seconds", 30.0, VoiceQualityStatus.PASS, None),
        ("duration_seconds", 2.0, VoiceQualityStatus.WARN, "audio_too_short"),
        ("duration_seconds", 45.0, VoiceQualityStatus.WARN, "audio_too_short"),
        ("duration_seconds", 1.9, VoiceQualityStatus.REJECT, "audio_too_short"),
        ("duration_seconds", 45.1, VoiceQualityStatus.REJECT, "audio_too_short"),
        # noise_floor_dbfs: <= -45 pass / -45~-35 warn / > -35 reject
        ("noise_floor_dbfs", -45.0, VoiceQualityStatus.PASS, None),
        ("noise_floor_dbfs", -60.0, VoiceQualityStatus.PASS, None),
        ("noise_floor_dbfs", -44.9, VoiceQualityStatus.WARN, "high_noise_floor"),
        ("noise_floor_dbfs", -35.0, VoiceQualityStatus.WARN, "high_noise_floor"),
        ("noise_floor_dbfs", -34.9, VoiceQualityStatus.REJECT, "high_noise_floor"),
        # estimated_snr_db: >= 20 pass / 15-20 warn / < 15 reject
        ("estimated_snr_db", 20.0, VoiceQualityStatus.PASS, None),
        ("estimated_snr_db", 15.0, VoiceQualityStatus.WARN, "low_snr"),
        ("estimated_snr_db", 14.9, VoiceQualityStatus.REJECT, "low_snr"),
        # clipping_ratio: < 0.01% pass / 0.01-0.1% warn / > 0.1% reject
        ("clipping_ratio", 0.0, VoiceQualityStatus.PASS, None),
        ("clipping_ratio", 0.0000999, VoiceQualityStatus.PASS, None),
        ("clipping_ratio", 0.0001, VoiceQualityStatus.WARN, "clipping"),
        ("clipping_ratio", 0.001, VoiceQualityStatus.WARN, "clipping"),
        ("clipping_ratio", 0.0011, VoiceQualityStatus.REJECT, "clipping"),
        # 首/尾静音 (max of leading/trailing): <= 0.8 pass / 0.8-1.5 warn / > 1.5 reject
        ("leading_silence_seconds", 0.8, VoiceQualityStatus.PASS, None),
        ("leading_silence_seconds", 1.5, VoiceQualityStatus.WARN, "audio_too_short"),
        ("leading_silence_seconds", 1.5001, VoiceQualityStatus.REJECT, "audio_too_short"),
        # speech_active_ratio: >= 0.55 pass / 0.35-0.55 warn / < 0.35 reject
        ("speech_active_ratio", 0.55, VoiceQualityStatus.PASS, None),
        ("speech_active_ratio", 0.35, VoiceQualityStatus.WARN, "audio_too_short"),
        ("speech_active_ratio", 0.3499, VoiceQualityStatus.REJECT, "audio_too_short"),
    ],
)
def test_grade_reference_metric_boundaries(
    field: str,
    value: float,
    expected_status: VoiceQualityStatus,
    expected_code: str | None,
) -> None:
    reference = replace(_passing_reference(), **{field: value})
    status, codes = grade_reference_quality(reference)

    assert status == expected_status.value
    if expected_code is None:
        assert codes == []
    else:
        assert codes == [expected_code]


@pytest.mark.parametrize(
    ("transcript_match", "expected_status", "expected_code"),
    [
        (0.98, VoiceQualityStatus.PASS, None),
        (0.90, VoiceQualityStatus.WARN, "transcript_mismatch"),
        (0.8999, VoiceQualityStatus.REJECT, "transcript_mismatch"),
    ],
)
def test_grade_transcript_match_boundaries(
    transcript_match: float,
    expected_status: VoiceQualityStatus,
    expected_code: str | None,
) -> None:
    reference = replace(_passing_reference(), transcript_match=transcript_match)
    status, codes = grade_reference_quality(reference)

    assert status == expected_status.value
    assert codes == ([] if expected_code is None else [expected_code])


def test_transcript_match_none_is_skipped_without_code() -> None:
    # transcript_match=None is "unavailable", never auto-passed and never coded.
    status, codes = grade_reference_quality(_passing_reference())
    assert status == VoiceQualityStatus.PASS.value
    assert "transcript_mismatch" not in codes


def test_transcript_match_injected_param_overrides_reference_field() -> None:
    reference = replace(_passing_reference(), transcript_match=0.99)  # field says pass
    status, codes = grade_reference_quality(reference, transcript_match=0.5)
    assert status == VoiceQualityStatus.REJECT.value
    assert codes == ["transcript_mismatch"]


# ---------------------------------------------------------------------------
# Overall severity + code aggregation
# ---------------------------------------------------------------------------


def test_overall_status_is_most_severe_and_collects_all_codes() -> None:
    reference = replace(
        _passing_reference(),
        duration_seconds=3.0,  # warn  -> audio_too_short
        noise_floor_dbfs=-30.0,  # reject -> high_noise_floor
        clipping_ratio=0.0005,  # warn  -> clipping
        estimated_snr_db=10.0,  # reject -> low_snr
    )
    status, codes = grade_reference_quality(reference)

    assert status == VoiceQualityStatus.REJECT.value
    assert set(codes) == {"audio_too_short", "high_noise_floor", "clipping", "low_snr"}


def test_all_pass_yields_pass_and_empty_codes() -> None:
    status, codes = grade_reference_quality(_passing_reference())
    assert status == VoiceQualityStatus.PASS.value
    assert codes == []


def test_failure_codes_are_deduplicated_preserving_order() -> None:
    reference = replace(
        _passing_reference(),
        duration_seconds=3.0,  # warn -> audio_too_short
        leading_silence_seconds=1.5,  # warn -> audio_too_short
    )
    status, codes = grade_reference_quality(reference)

    assert status == VoiceQualityStatus.WARN.value
    assert codes == ["audio_too_short"]


# ---------------------------------------------------------------------------
# VoiceQualityReport serialization
# ---------------------------------------------------------------------------


def test_report_to_dict_matches_openapi_shape_field_for_field() -> None:
    report = VoiceQualityReport(
        policy_version=POLICY_VERSION,
        status=VoiceQualityStatus.PASS.value,
        run_id="vqr_0123456789abcdef0123456789abcdef",
        tested_at="2026-09-09T12:00:00Z",
        reference=VoiceQualityReference(
            duration_seconds=8.4,
            sample_rate=24_000,
            channels=1,
            speech_active_ratio=0.78,
            noise_floor_dbfs=-52.1,
            estimated_snr_db=28.4,
            clipping_ratio=0.0,
            leading_silence_seconds=0.21,
            trailing_silence_seconds=0.34,
            transcript_match=0.998,
        ),
        synthesis=VoiceQualitySynthesis(
            probe_count=3,
            successful_probe_count=3,
            active_rms_dbfs=-20.8,
            peak_dbfs=-3.2,
            chunk_jump_p95_db=4.6,
            clipping_ratio=0.0,
            deterministic=True,
        ),
        failure_codes=[],
    )

    data = report.to_dict()

    assert set(data.keys()) == {
        "policy_version",
        "status",
        "run_id",
        "tested_at",
        "reference",
        "synthesis",
        "failure_codes",
    }
    assert set(data["reference"].keys()) == {
        "duration_seconds",
        "sample_rate",
        "channels",
        "speech_active_ratio",
        "noise_floor_dbfs",
        "estimated_snr_db",
        "clipping_ratio",
        "leading_silence_seconds",
        "trailing_silence_seconds",
        "transcript_match",
    }
    assert set(data["synthesis"].keys()) == {
        "probe_count",
        "successful_probe_count",
        "active_rms_dbfs",
        "peak_dbfs",
        "chunk_jump_p95_db",
        "clipping_ratio",
        "deterministic",
    }
    assert data["reference"]["transcript_match"] == 0.998


def test_report_from_dict_round_trips_and_ignores_unknown_fields() -> None:
    reference = replace(_passing_reference(), transcript_match=0.998)
    report = make_quality_report(reference, _synthesis(), transcript_match=0.998)

    payload = report.to_dict()
    payload["extra_top_level"] = "ignored"
    payload["reference"]["extra_reference"] = 123
    payload["synthesis"]["extra_synthesis"] = True
    payload["failure_codes"].append("unknown_code")

    restored = VoiceQualityReport.from_dict(payload)

    assert restored.policy_version == report.policy_version
    assert restored.status == report.status
    assert restored.run_id == report.run_id
    assert restored.tested_at == report.tested_at
    assert restored.reference == report.reference
    assert restored.synthesis == report.synthesis
    # unknown failure codes are filtered out by the fixed enum
    assert restored.failure_codes == report.failure_codes


def test_report_from_dict_round_trips_synthesis_failure_codes() -> None:
    reference = replace(_passing_reference(), transcript_match=0.998)
    report = make_quality_report(reference, _synthesis(), transcript_match=0.998)

    payload = report.to_dict()
    payload["failure_codes"] = ["clone_speed_unsupported", "output_invalid"]

    restored = VoiceQualityReport.from_dict(payload)

    # Both synthesis-side codes belong to the 9-code OpenAPI failure_codes enum
    # and must survive the round-trip instead of being dropped by the filter.
    assert restored.failure_codes == ["clone_speed_unsupported", "output_invalid"]


def test_make_quality_report_run_id_and_tested_at_formats() -> None:
    report = make_quality_report(_passing_reference(), _synthesis())

    assert report.policy_version == "voice_quality_v1"
    assert report.status == VoiceQualityStatus.PASS.value
    assert report.run_id.startswith("vqr_")
    assert len(report.run_id) == 36  # "vqr_" + 32 hex chars
    assert all(c in "0123456789abcdef" for c in report.run_id[4:])
    assert report.tested_at.endswith("Z")
    parsed = datetime.fromisoformat(report.tested_at.replace("Z", "+00:00"))
    assert parsed.tzinfo is not None


def test_make_quality_report_grades_into_failure_codes() -> None:
    reference = replace(_passing_reference(), clipping_ratio=0.002)  # reject
    report = make_quality_report(reference, _synthesis())
    assert report.status == VoiceQualityStatus.REJECT.value
    assert report.failure_codes == ["clipping"]


# ---------------------------------------------------------------------------
# Signal metrics (mono PCM16) sanity checks
# ---------------------------------------------------------------------------


def test_duration_seconds() -> None:
    sample_rate = 24_000
    seconds = 2.0
    pcm = b"\x00\x00" * int(sample_rate * seconds)
    assert duration_seconds(pcm, sample_rate) == pytest.approx(seconds)


def test_clipping_ratio_detects_full_scale_and_clean_signal() -> None:
    assert clipping_ratio(_pcm16([0, 1000, -1000, 500])) == 0.0
    assert clipping_ratio(_pcm16([32767, -32768, 0, 32767])) == 0.75


def test_speech_active_ratio_silence_vs_speech() -> None:
    sample_rate = 24_000
    assert speech_active_ratio(b"\x00\x00" * sample_rate, sample_rate) == 0.0
    assert speech_active_ratio(_sine_pcm16(1.0, sample_rate), sample_rate) == 1.0


def test_leading_trailing_silence_seconds() -> None:
    sample_rate = 24_000
    half_second = sample_rate // 2
    pcm = (
        b"\x00\x00" * half_second
        + _sine_pcm16(1.0, sample_rate)
        + b"\x00\x00" * half_second
    )
    leading, trailing = leading_trailing_silence_seconds(pcm, sample_rate)
    assert leading == pytest.approx(0.5, abs=0.02)
    assert trailing == pytest.approx(0.5, abs=0.02)


def test_noise_floor_and_snr_for_silence_and_speech() -> None:
    sample_rate = 24_000
    assert noise_floor_dbfs(b"\x00\x00" * sample_rate) == -120.0
    loud = _sine_pcm16(1.0, sample_rate)
    assert noise_floor_dbfs(loud) < -20.0
    assert estimated_snr_db(loud, sample_rate) > 5.0


# ---------------------------------------------------------------------------
# Fixed probe set
# ---------------------------------------------------------------------------


def test_voice_quality_v1_zh_probes_are_fixed_six_entry_set() -> None:
    assert len(VOICE_QUALITY_V1_ZH_PROBES) == 6

    probes = list(VOICE_QUALITY_V1_ZH_PROBES)
    ids = [probe["id"] for probe in probes]
    texts = [probe["text"] for probe in probes]
    categories = {probe["category"] for probe in probes}

    assert len(set(ids)) == 6
    assert "请进行自我介绍" in texts
    assert {"short", "long", "question", "numbers_punct", "pauses"}.issubset(categories)
    for probe in probes:
        assert set(probe.keys()) == {"id", "category", "text"}


# ---------------------------------------------------------------------------
# VoiceProfile backward compatibility (missing quality == unevaluated)
# ---------------------------------------------------------------------------


def test_voice_profile_to_dict_omits_quality_when_missing() -> None:
    profile = VoiceProfile(id="v1", name="voice one")
    assert "quality" not in profile.to_dict()


def test_voice_profile_to_dict_includes_quality_when_present() -> None:
    quality: dict[str, object] = {
        "policy_version": "voice_quality_v1",
        "status": VoiceQualityStatus.UNEVALUATED.value,
    }
    profile = VoiceProfile(id="v1", name="voice one", quality=quality)
    assert profile.to_dict()["quality"] == quality


def test_profile_from_record_parses_optional_quality(tmp_path: Path) -> None:
    registry = VoiceRegistry(
        storage_path=tmp_path / "registry.json",
        voices_dir=tmp_path / "voices",
    )
    quality: dict[str, object] = {
        "policy_version": "voice_quality_v1",
        "status": VoiceQualityStatus.WARN.value,
    }
    record: dict[str, object] = {
        "id": "myvoice",
        "name": "My Voice",
        "instruction": "test",
        "mode": "instruction",
        "quality": quality,
    }
    profile = registry._profile_from_record(record)
    assert profile.quality == quality

    without_quality = dict(record)
    del without_quality["quality"]
    profile_missing = registry._profile_from_record(without_quality)
    assert profile_missing.quality is None


def test_create_cloned_profile_accepts_and_persists_quality(tmp_path: Path) -> None:
    storage_path = tmp_path / "registry.json"
    voices_dir = tmp_path / "voices"
    registry = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)

    quality: dict[str, object] = {
        "policy_version": "voice_quality_v1",
        "status": VoiceQualityStatus.PASS.value,
        "run_id": "vqr_test",
    }
    profile = registry.create_cloned_profile(
        name="clone",
        ref_text="你好，世界。",
        audio_bytes=_wav_bytes(3.0),
        voice_id="clone_with_quality",
        duration_seconds=3.0,
        quality=quality,
    )
    assert profile.quality == quality

    reloaded_registry = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)
    reloaded = reloaded_registry.get_profile("clone_with_quality")
    assert reloaded.quality == quality


def _clipped_wav_bytes(
    duration_seconds: float = 4.0, sample_rate: int = 24_000, clip_ratio: float = 0.01
) -> bytes:
    """Speech-like WAV with a controlled fraction of full-scale (clipped) samples."""
    count = int(duration_seconds * sample_rate)
    samples: list[int] = []
    for index in range(count):
        value = round(
            0.5 * 32767.0 * math.sin(2.0 * math.pi * 440.0 * index / sample_rate)
        )
        samples.append(max(-32767, min(32767, value)))
    step = max(1, int(1.0 / clip_ratio))
    for index in range(0, count, step):
        samples[index] = 32767
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(_pcm16(samples))
    return buf.getvalue()


def test_transcode_skip_signal_validation_param() -> None:
    # 1% clipping exceeds the 0.5% signal-validation rail, so the default path
    # rejects; skip_signal_validation=True must bypass that rail entirely.
    clipped = _clipped_wav_bytes(4.0, clip_ratio=0.01)
    with patch("subprocess.run") as mock_run:
        mock_run.return_value = SimpleNamespace(returncode=0, stdout=clipped, stderr=b"")
        with pytest.raises(ValueError, match="clipped"):
            transcode_and_validate_clone_audio(b"raw")
        wav_out, duration = transcode_and_validate_clone_audio(
            b"raw", skip_signal_validation=True
        )
    assert duration == pytest.approx(4.0, abs=0.1)
    assert len(wav_out) == len(clipped)


def test_create_cloned_profile_quality_defaults_to_none(tmp_path: Path) -> None:
    registry = VoiceRegistry(
        storage_path=tmp_path / "registry.json",
        voices_dir=tmp_path / "voices",
    )
    profile = registry.create_cloned_profile(
        name="clone",
        ref_text="你好，世界。",
        audio_bytes=_wav_bytes(3.0),
        voice_id="clone_no_quality",
        duration_seconds=3.0,
    )
    assert profile.quality is None
