from __future__ import annotations

import math
import struct

import pytest

try:
    from speechrail.domain.voice_quality import compute_output_quality_metrics
except (ImportError, SyntaxError):
    from speechrail.domain.voice_quality_metrics import compute_output_quality_metrics


def _encode_i16(samples: list[int]) -> bytes:
    return struct.pack(f"<{len(samples)}h", *samples)


def _sine_pcm16(
    *,
    sample_rate: int = 24_000,
    frequency_hz: float = 440.0,
    duration_seconds: float = 1.0,
    peak_amplitude: float = 0.5,
) -> bytes:
    sample_count = round(sample_rate * duration_seconds)
    samples: list[int] = []
    for index in range(sample_count):
        value = round(
            peak_amplitude * 32767.0 * math.sin(2.0 * math.pi * frequency_hz * index / sample_rate)
        )
        samples.append(max(-32767, min(32767, value)))
    return _encode_i16(samples)


def _two_level_constant_windows(
    *,
    amplitudes: list[float],
    windows_per_segment: int = 1,
    segment_samples: int,
) -> bytes:
    samples: list[int] = []
    for amplitude in amplitudes:
        for _ in range(windows_per_segment):
            value = round(amplitude * 32767.0)
            value = max(-32767, min(32767, value))
            samples.extend([value] * segment_samples)
    return _encode_i16(samples)


def _decode_i16_le(pcm_bytes: bytes) -> list[int]:
    return [sample for sample, in struct.iter_unpack("<h", pcm_bytes)]


def _dbfs_from_amplitude(amplitude: float) -> float:
    return 20.0 * math.log10(max(amplitude, 1e-12))


def test_silence_reports_low_active_rms_peak_and_zero_clipping() -> None:
    pcm = b"\x00\x00" * 4_800

    metrics = compute_output_quality_metrics(pcm)

    assert metrics["probe_count"] == 1
    assert metrics["successful_probe_count"] == 1
    assert metrics["active_rms_dbfs"] <= -200.0
    assert metrics["peak_dbfs"] <= -100.0
    assert metrics["chunk_jump_p95_db"] == 0.0
    assert metrics["clipping_ratio"] == 0.0


def test_sine_metrics_are_predictable_for_full_level_speech() -> None:
    peak_amplitude = 0.5
    sine = _sine_pcm16(duration_seconds=0.8, peak_amplitude=peak_amplitude)

    metrics = compute_output_quality_metrics(sine)

    expected_rms_dbfs = _dbfs_from_amplitude(peak_amplitude / math.sqrt(2.0))
    expected_peak_dbfs = _dbfs_from_amplitude(peak_amplitude)
    assert metrics["active_rms_dbfs"] == pytest.approx(expected_rms_dbfs, abs=0.5)
    assert metrics["peak_dbfs"] == pytest.approx(expected_peak_dbfs, abs=0.1)
    assert metrics["clipping_ratio"] == 0.0
    assert metrics["chunk_jump_p95_db"] == pytest.approx(0.0, abs=0.5)


def test_clipped_audio_reports_clipping_ratio_and_non_extreme_peak() -> None:
    pcm = _sine_pcm16(duration_seconds=0.4, peak_amplitude=1.5)

    metrics = compute_output_quality_metrics(pcm)

    assert metrics["clipping_ratio"] > 0.0
    assert metrics["peak_dbfs"] > -1.0


def test_two_level_chunks_report_positive_p95_jump() -> None:
    window_samples = round(24_000 * 0.02)
    pcm = _two_level_constant_windows(
        amplitudes=[0.06, 0.60, 0.60, 0.06],
        windows_per_segment=1,
        segment_samples=window_samples,
    )
    metrics = compute_output_quality_metrics(pcm)

    assert metrics["chunk_jump_p95_db"] > 0.0


def test_deterministic_true_for_repeated_identical_payloads() -> None:
    pcm = _sine_pcm16(duration_seconds=0.6, peak_amplitude=0.3)

    a = compute_output_quality_metrics(pcm)
    b = compute_output_quality_metrics(pcm)

    assert a == b
    assert a["deterministic"]
    assert b["deterministic"]


def test_format_guard_rejects_wrong_sample_rate() -> None:
    pcm = _sine_pcm16(sample_rate=24_000, duration_seconds=0.1, peak_amplitude=0.2)

    with pytest.raises(ValueError, match="24kHz PCM16 mono"):
        _ = compute_output_quality_metrics(pcm, sample_rate=16_000)


def test_format_guard_rejects_odd_payload_length() -> None:
    with pytest.raises(ValueError, match="PCM16 payload length must be even"):
        compute_output_quality_metrics(b"\x00")
