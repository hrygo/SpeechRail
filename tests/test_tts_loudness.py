from __future__ import annotations

import math
import struct
from itertools import pairwise

import pytest

from speechrail.domain.tts_loudness import (
    Pcm16LoudnessConfig,
    StreamingPcm16LoudnessController,
)


def _constant_pcm16(amplitude: float, samples: int) -> bytes:
    value = round(amplitude * 32767.0)
    return struct.pack(f"<{samples}h", *([value] * samples))


def _sparse_sine_pcm16(
    amplitude: float,
    active_fraction: float,
    phase: int,
    samples: int = 2_400,
) -> bytes:
    active_samples = max(1, round(samples * active_fraction))
    values = [
        round(
            amplitude
            * math.sin(2.0 * math.pi * 220.0 * (index + phase) / 24_000.0)
            * 32767.0
        )
        if index < active_samples
        else 0
        for index in range(samples)
    ]
    return struct.pack(f"<{samples}h", *values)


def _decode_pcm16(pcm: bytes) -> tuple[int, ...]:
    return tuple(value[0] for value in struct.iter_unpack("<h", pcm))


def _rms_dbfs(pcm: bytes) -> float:
    samples = _decode_pcm16(pcm)
    rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples)) / 32768.0
    return 20.0 * math.log10(max(rms, 1e-9))


def _peak_dbfs(pcm: bytes) -> float:
    peak = max(abs(sample) for sample in _decode_pcm16(pcm)) / 32768.0
    return 20.0 * math.log10(max(peak, 1e-9))


def test_controller_rejects_odd_pcm16_payload() -> None:
    controller = StreamingPcm16LoudnessController(sample_rate=24_000)

    with pytest.raises(ValueError, match="PCM16 payload length must be even"):
        controller.process(b"\x00")


def test_controller_does_not_raise_near_silence() -> None:
    controller = StreamingPcm16LoudnessController(sample_rate=24_000)
    silence = b"\x00\x00" * 1_920

    assert controller.process(silence) == silence


def test_controller_smooths_alternating_chunk_levels() -> None:
    controller = StreamingPcm16LoudnessController(sample_rate=24_000)
    low = _constant_pcm16(0.05, 1_920)
    high = _constant_pcm16(0.40, 1_920)

    output = [controller.process(chunk) for chunk in (low, high, low, high)]
    levels = [_rms_dbfs(chunk) for chunk in output]
    raw_jump = 20.0 * math.log10(0.40 / 0.05)

    assert max(abs(levels[i] - levels[i - 1]) for i in range(1, len(levels))) < raw_jump


def test_controller_can_freeze_clone_gain_after_request_calibration() -> None:
    controller = StreamingPcm16LoudnessController(
        sample_rate=24_000,
        freeze_gain_after_calibration=True,
    )
    low = _constant_pcm16(0.05, 4_800)
    high = _constant_pcm16(0.40, 1_920)

    # Frozen mode emits unity gain while gathering credible media-time frames,
    # then ramps to the fixed target. Compare settled levels, not calibration.
    controller.process(low)
    controller.process(low)
    first = controller.process(low)
    first_gain_db = controller._current_gain_db
    second = controller.process(high)
    third = controller.process(low)

    assert first_gain_db is not None
    assert controller._current_gain_db == pytest.approx(first_gain_db)
    assert _rms_dbfs(third) == pytest.approx(_rms_dbfs(first), abs=0.1)
    assert _rms_dbfs(second) - _rms_dbfs(first) > 15.0


def test_controller_applies_peak_ceiling_without_wraparound() -> None:
    controller = StreamingPcm16LoudnessController(sample_rate=24_000)

    output = controller.process(_constant_pcm16(0.99, 1_920))

    assert _peak_dbfs(output) <= -1.0 + 0.1
    assert max(abs(value) for value in _decode_pcm16(output)) <= 32767


def test_controller_reaches_target_for_steady_voice() -> None:
    controller = StreamingPcm16LoudnessController(sample_rate=24_000)
    chunk = _constant_pcm16(0.05, 1_920)

    output = [controller.process(chunk) for _ in range(12)]

    assert _rms_dbfs(output[-1]) == pytest.approx(-20.0, abs=1.5)


def test_controller_reset_starts_a_new_request() -> None:
    controller = StreamingPcm16LoudnessController(sample_rate=24_000)
    chunk = _constant_pcm16(0.05, 1_920)

    first = controller.process(chunk)
    for _ in range(6):
        controller.process(_constant_pcm16(0.4, 1_920))
    controller.reset()

    assert controller.process(chunk) == first


def test_controller_applies_calibration_when_first_chunk_covers_window() -> None:
    controller = StreamingPcm16LoudnessController(sample_rate=24_000)
    first_chunk = _constant_pcm16(0.02, 4_800)  # 200 ms

    controller.process(first_chunk)

    assert controller._calibration_gain_db is not None
    assert controller._current_gain_db == pytest.approx(controller._calibration_gain_db)


def test_controller_rejects_invalid_sample_rate() -> None:
    with pytest.raises(ValueError, match="sample_rate must be positive"):
        StreamingPcm16LoudnessController(sample_rate=0)


def test_controller_uses_custom_limits() -> None:
    config = Pcm16LoudnessConfig(
        target_rms=0.2,
        peak_ceiling=0.5,
        calibration_ms=80,
        attack_ms=100,
        release_ms=100,
        max_gain_db=3.0,
        max_attenuation_db=-3.0,
    )
    controller = StreamingPcm16LoudnessController(sample_rate=24_000, config=config)

    output = controller.process(_constant_pcm16(0.99, 1_920))

    assert max(abs(value) for value in _decode_pcm16(output)) <= round(0.5 * 32768)


def test_controller_reports_peak_ceiling_count_without_audio_features() -> None:
    controller = StreamingPcm16LoudnessController(sample_rate=24_000)
    samples = [round(0.01 * 32767)] * 1_919 + [round(0.99 * 32767)]
    pcm = struct.pack("<1920h", *samples)

    controller.process(pcm)

    assert controller.consume_stats() == {"peak_ceiling": 1}
    assert controller.consume_stats() == {}


def test_controller_handles_wide_voice_level_changes_without_large_jumps() -> None:
    controller = StreamingPcm16LoudnessController(sample_rate=24_000)
    amplitudes = (0.01, 0.08, 0.40, 0.02, 0.20, 0.01, 0.50, 0.03) * 3

    output = [controller.process(_constant_pcm16(amplitude, 1_920)) for amplitude in amplitudes]
    levels = [_rms_dbfs(chunk) for chunk in output]
    jumps = [abs(current - previous) for previous, current in pairwise(levels)]

    assert percentile(jumps, 0.95) < 10.0
    assert percentile(levels, 0.50) == pytest.approx(-20.0, abs=3.0)


def test_controller_handles_sparse_streaming_chunks_without_pumping() -> None:
    controller = StreamingPcm16LoudnessController(sample_rate=24_000)
    source = (
        (0.15, 1.0),
        (0.40, 0.7),
        (0.04, 0.35),
        (0.50, 0.9),
        (0.08, 0.2),
        (0.20, 0.8),
    ) * 4

    output = [
        controller.process(_sparse_sine_pcm16(amplitude, fraction, index * 2_400))
        for index, (amplitude, fraction) in enumerate(source)
    ]
    levels = [_rms_dbfs(chunk) for chunk in output]
    jumps = [abs(current - previous) for previous, current in pairwise(levels)]

    assert percentile(jumps, 0.95) < 10.0
    assert percentile(levels, 0.50) == pytest.approx(-20.0, abs=3.0)


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)
