"""Synthetic frozen-mode regressions; no model, private audio, or playback."""
from __future__ import annotations

import math
import random
import struct
from itertools import pairwise

import pytest

from speechrail.domain.tts_loudness import (
    Pcm16LoudnessConfig,
    StreamingPcm16LoudnessController,
)

SR = 24_000
N = 4_800


def pcm(samples: list[int]) -> bytes:
    return struct.pack(f"<{len(samples)}h", *samples)


def decode(data: bytes) -> list[int]:
    return [sample[0] for sample in struct.iter_unpack("<h", data)]


def tone(amplitude: float = 0.05, count: int = N) -> bytes:
    return pcm([
        round(amplitude * 32767 * math.sin(2 * math.pi * 220 * i / SR))
        for i in range(count)
    ])


def new() -> StreamingPcm16LoudnessController:
    return StreamingPcm16LoudnessController(
        sample_rate=SR, freeze_gain_after_calibration=True,
    )


def level(data: bytes) -> float:
    samples = decode(data)
    rms = math.sqrt(sum(x * x for x in samples) / len(samples)) / 32768
    return 20 * math.log10(max(rms, 1e-12))


def warm(controller: StreamingPcm16LoudnessController, amplitude: float = 0.05) -> None:
    # Calibration plus time for the causal gain ramp to settle.
    for _ in range(4):
        controller.process(tone(amplitude))


def test_frozen_leading_silence_does_not_poison_calibration() -> None:
    reference = new()
    warm(reference)
    expected = level(reference.process(tone()))
    subject = new()
    subject.process(bytes(N * 2))
    subject.process(bytes(3600 * 2) + tone(count=1200))
    warm(subject)
    assert subject._calibration_gain_db is not None
    assert level(subject.process(tone())) == pytest.approx(expected, abs=0.15)


def test_frozen_single_impulse_does_not_establish_calibration() -> None:
    subject = new()
    impulse = [0] * N
    impulse[N // 2] = 26214
    subject.process(pcm(impulse))
    assert subject.consume_stats().get("calibrated", 0) == 0
    assert subject._current_gain_db is None
    warm(subject)
    assert level(subject.process(tone())) == pytest.approx(-20.0, abs=0.2)


def test_frozen_peak_does_not_attenuate_samples_before_it() -> None:
    reference, subject = new(), new()
    warm(reference, 0.02)
    warm(subject, 0.02)
    quiet = tone(0.02)
    spike = decode(quiet)
    spike[-1] = 26214
    expected = reference.process(quiet)
    actual = subject.process(pcm(spike))
    assert actual[:-2] == expected[:-2]
    assert abs(decode(actual)[-1]) <= math.floor(32768 * 10 ** (-1 / 20))


def test_frozen_peak_release_survives_process_boundary() -> None:
    subject = new()
    warm(subject, 0.02)
    before = decode(subject.process(pcm([655] * N)))
    subject.process(pcm([26214]))
    tail = decode(subject.process(pcm([655] * N)))
    assert tail[0] < before[-1] // 2
    assert 0 <= tail[1] - tail[0] <= 3
    assert tail[-1] > tail[0]
    assert max(abs(b - a) for a, b in pairwise(tail)) <= 3


def test_frozen_near_silence_does_not_toggle_whole_chunk_gain() -> None:
    subject = new()
    warm(subject, 0.005)
    quiet = subject.process(pcm([29] * N))
    crossing = subject.process(pcm([29] * (N - 1) + [36]))
    assert quiet[:-2] == crossing[:-2]
    assert decode(quiet)[0] > 29  # The already locked gain applies consistently.
    assert subject.process(bytes(N * 2)) == bytes(N * 2)


def test_frozen_processing_is_independent_of_transport_partition() -> None:
    signal = bytes(3120 * 2) + tone(count=16000) + pcm([26214]) + tone(0.02, 6000)
    whole = new().process(signal)
    controller = new()
    rng = random.Random(34)
    outputs = []
    offset = 0
    while offset < len(signal):
        size = 2 * rng.randint(1, 1700)
        outputs.append(controller.process(signal[offset:offset + size]))
        offset += size
    assert b"".join(outputs) == whole
    assert len(whole) == len(signal)


def test_frozen_short_input_does_not_lock_unreliable_gain() -> None:
    subject = new()
    signal = tone(count=239)  # Less than one 10 ms analysis frame.
    result = subject.process(signal)
    assert len(result) == len(signal)
    assert result == signal
    assert subject._current_gain_db is None
    assert subject.consume_stats().get("calibrated", 0) == 0


def test_frozen_reset_discards_calibration_ramp_and_limiter_state() -> None:
    subject = new()
    warm(subject, 0.005)
    subject.process(pcm([30000]))
    subject.reset()
    signal = bytes(300) + tone(count=6301)
    assert subject.process(signal) == new().process(signal)


def test_frozen_trusted_lock_is_gradual_not_a_step() -> None:
    subject = new()
    samples = decode(subject.process(pcm([655] * (N * 2))))
    assert samples[N - 2] == 655
    assert samples[N - 1] - samples[N - 2] <= 10
    assert max(abs(b - a) for a, b in pairwise(samples)) <= 10
    assert samples[-1] > samples[0] * 4


def test_frozen_keeps_gain_target_fixed_after_trusted_lock() -> None:
    subject = new()
    warm(subject)
    target = subject._current_gain_db
    subject.process(tone(0.2))
    subject.process(tone(0.005))
    assert subject._current_gain_db == target


def test_frozen_retains_sample_order_when_at_unity() -> None:
    signal = pcm(list(range(-100, 100)))
    assert new().process(signal) == signal


@pytest.mark.parametrize("count", [0, 1, 239, 240, 241, 4799, 4800, 4801])
def test_frozen_preserves_sample_count_including_partial_frames(count: int) -> None:
    subject = new()
    assert len(subject.process(tone(count=count))) == count * 2


def test_frozen_invalid_input_does_not_mutate_state() -> None:
    subject = new()
    signal = tone(count=7000)
    with pytest.raises(ValueError, match="PCM16"):
        subject.process(b"x")
    assert subject.process(signal) == new().process(signal)


def test_frozen_peak_ceiling_before_calibration_is_safe() -> None:
    subject = new()
    result = subject.process(pcm([-32768, 32767]))
    assert max(abs(x) for x in decode(result)) <= math.floor(32768 * 10 ** (-1 / 20))


def test_frozen_silence_wait_does_not_accumulate_audio() -> None:
    subject = new()
    for _ in range(50):
        assert subject.process(bytes(N * 2)) == bytes(N * 2)
    assert subject._current_gain_db is None
    warm(subject)
    assert subject.consume_stats().get("calibrated") == 1


def test_frozen_collection_timeout_falls_back_without_false_calibrated_metric() -> None:
    subject = new()
    subject.process(tone(count=240))  # One eligible frame starts collection.
    subject.process(bytes(SR * 2))  # Deadline: max(1 second, 5 * calibration).
    assert subject._frozen_state == "fallback"
    assert subject._current_gain_db == 0.0
    assert subject.consume_stats().get("calibrated", 0) == 0
    assert subject.process(tone()) == tone()


def test_frozen_statistics_do_not_reset_gain_or_limiter() -> None:
    first, second = new(), new()
    warm(first, 0.02)
    warm(second, 0.02)
    first.process(pcm([26214]))
    second.process(pcm([26214]))
    assert first.consume_stats().get("peak_ceiling") == 1
    assert first.consume_stats().get("peak_ceiling", 0) == 0
    assert first.process(tone()) == second.process(tone())


@pytest.mark.parametrize("sample_rate", [8_000, 16_000, 24_000, 48_000])
def test_frozen_uses_media_time_at_different_sample_rates(sample_rate: int) -> None:
    subject = StreamingPcm16LoudnessController(
        sample_rate=sample_rate, freeze_gain_after_calibration=True,
    )
    subject.process(pcm([655] * (sample_rate // 5 - 1)))
    assert subject._current_gain_db is None
    subject.process(pcm([655]))
    assert subject.consume_stats().get("calibrated") == 1


@pytest.mark.parametrize("release", [0, -1, True, 0.5, float("nan"), float("inf")])
def test_invalid_limiter_release_is_rejected(release: object) -> None:
    with pytest.raises(ValueError, match="limiter_release_ms"):
        Pcm16LoudnessConfig(limiter_release_ms=release)


def test_frozen_release_configuration_controls_recovery() -> None:
    outputs = []
    for release in (20, 200):
        subject = StreamingPcm16LoudnessController(
            sample_rate=SR,
            config=Pcm16LoudnessConfig(limiter_release_ms=release),
            freeze_gain_after_calibration=True,
        )
        warm(subject, 0.02)
        subject.process(pcm([26214]))
        outputs.append(decode(subject.process(pcm([655] * 2400)))[-1])
    assert outputs[0] > outputs[1]


def test_frozen_calibration_ignores_single_outlier_frame_among_steady_frames() -> None:
    subject = new()
    # One high-energy frame cannot dominate the median of 20 valid frames.
    subject.process(tone(0.8, 240) + tone(0.05, N - 240))
    warm(subject)
    assert level(subject.process(tone())) == pytest.approx(-20.0, abs=0.2)


def test_frozen_stats_storage_is_bounded_for_sparse_collection() -> None:
    subject = new()
    for _ in range(40):
        subject.process(tone(count=240) + bytes(2400 * 2))
    assert len(subject._frozen_frame_powers) < 20
    assert subject._frozen_state == "fallback"
