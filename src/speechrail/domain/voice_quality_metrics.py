from __future__ import annotations

import math
import struct
from typing import Final

_EPSILON_DBFS: Final = 1e-12
_ACTIVE_THRESHOLD_DB: Final = -45.0
_ACTIVE_RMS_THRESHOLD: Final = 10 ** (_ACTIVE_THRESHOLD_DB / 20.0)
_REQUIRED_SAMPLE_RATE: Final = 24_000
_PCM16_MAX_ABS: Final = 32768.0


def _validate_output_format(pcm_bytes: bytes, *, sample_rate: int) -> None:
    if sample_rate != _REQUIRED_SAMPLE_RATE:
        raise ValueError("Voice quality output must be 24kHz PCM16 mono")
    if not pcm_bytes:
        raise ValueError("pcm bytes must not be empty")
    if len(pcm_bytes) % 2 != 0:
        raise ValueError("PCM16 payload length must be even")


def _decode_pcm16_le(pcm_bytes: bytes) -> tuple[int, ...]:
    sample_count = len(pcm_bytes) // 2
    return struct.unpack(f"<{sample_count}h", pcm_bytes)


def _dbfs_from_linear(value: float) -> float:
    return 20.0 * math.log10(max(value, _EPSILON_DBFS))


def _percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    if fraction <= 0:
        return sorted(values)[0]
    if fraction >= 1:
        return sorted(values)[-1]
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[int(position)]
    lower_value = ordered[int(lower)]
    upper_value = ordered[int(upper)]
    return lower_value + (upper_value - lower_value) * (position - lower)


def compute_output_quality_metrics(
    pcm_bytes: bytes,
    *,
    sample_rate: int = _REQUIRED_SAMPLE_RATE,
    probe_count: int = 1,
    successful_probe_count: int | None = None,
    deterministic: bool = True,
) -> dict[str, object]:
    _validate_output_format(pcm_bytes, sample_rate=sample_rate)

    if probe_count <= 0:
        raise ValueError("probe_count must be positive")
    if successful_probe_count is not None and successful_probe_count < 0:
        raise ValueError("successful_probe_count must be non-negative")
    if successful_probe_count is not None and successful_probe_count > probe_count:
        raise ValueError("successful_probe_count cannot exceed probe_count")

    samples = _decode_pcm16_le(pcm_bytes)
    if not samples:
        raise ValueError("pcm bytes contains no samples")

    samples_f = [sample / _PCM16_MAX_ABS for sample in samples]
    absolute = [abs(sample) for sample in samples_f]

    peak = max(absolute)

    window_samples = max(1, int(sample_rate * 0.02))
    active_rms_sum_sq = 0.0
    active_sample_count = 0
    chunk_jumps: list[float] = []
    previous_active_rms: float | None = None

    for start in range(0, len(samples_f), window_samples):
        chunk = samples_f[start : start + window_samples]
        if not chunk:
            continue
        rms = math.sqrt(sum(value * value for value in chunk) / len(chunk))
        if rms > _ACTIVE_RMS_THRESHOLD:
            active_db = _dbfs_from_linear(rms)
            active_rms_sum_sq += sum(value * value for value in chunk)
            active_sample_count += len(chunk)
            if previous_active_rms is not None:
                chunk_jumps.append(abs(active_db - previous_active_rms))
            previous_active_rms = active_db

    if active_sample_count:
        active_rms = math.sqrt(active_rms_sum_sq / active_sample_count)
        active_rms_dbfs = _dbfs_from_linear(active_rms)
    else:
        active_rms_dbfs = -240.0

    chunk_jump_p95_db = (
        _percentile(chunk_jumps, 0.95)
        if len(chunk_jumps) >= 1
        else 0.0
    )

    clipped_count = sum(1 for sample in absolute if sample >= 32767.0 / 32768.0)
    clipping_ratio = clipped_count / len(samples_f) if samples_f else 0.0

    successful_count = probe_count if successful_probe_count is None else successful_probe_count

    return {
        "probe_count": probe_count,
        "successful_probe_count": successful_count,
        "active_rms_dbfs": active_rms_dbfs,
        "peak_dbfs": _dbfs_from_linear(peak),
        "chunk_jump_p95_db": chunk_jump_p95_db,
        "clipping_ratio": clipping_ratio,
        "deterministic": deterministic and successful_count == probe_count,
    }


__all__ = [
    "compute_output_quality_metrics",
]
