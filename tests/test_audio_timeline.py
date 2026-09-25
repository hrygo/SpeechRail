from __future__ import annotations

import array
import sys

import pytest

from speechrail.domain.audio_timeline import (
    CORE_SAMPLE_RATE,
    RateMap,
    RationalResampler,
    SampleClock,
    SampleSpan,
)


def _pcm16(samples: list[int]) -> bytes:
    values = array.array("h", samples)
    if sys.byteorder != "little":  # pragma: no cover - Apple silicon is little-endian.
        values.byteswap()
    return values.tobytes()


def _decode(pcm16: bytes) -> list[int]:
    values = array.array("h")
    values.frombytes(pcm16)
    if sys.byteorder != "little":  # pragma: no cover - Apple silicon is little-endian.
        values.byteswap()
    return values.tolist()


def test_sample_span_is_half_open_and_rejects_invalid_ranges() -> None:
    span = SampleSpan(10, 20)

    assert span.length == 10
    assert span.contains(SampleSpan(12, 18))
    assert not span.contains(SampleSpan(18, 22))
    assert span.overlaps(SampleSpan(19, 30))
    assert not span.overlaps(SampleSpan(20, 30))
    with pytest.raises(ValueError):
        SampleSpan(-1, 4)
    with pytest.raises(ValueError):
        SampleSpan(5, 4)


def test_rate_map_is_rational_and_only_rounds_at_boundaries() -> None:
    mapping = RateMap(source_rate=24_000, target_rate=CORE_SAMPLE_RATE)

    assert [mapping.to_target(value) for value in (0, 1, 2, 3, 4)] == [0, 0, 1, 2, 2]
    assert mapping.to_target(24_000) == 16_000
    assert mapping.to_source(16_000) == 24_000
    assert mapping.map_span(SampleSpan(3, 6)) == SampleSpan(2, 4)


def test_rate_map_records_origin_and_resampler_delay() -> None:
    mapping = RateMap(
        source_rate=24_000,
        target_rate=CORE_SAMPLE_RATE,
        origin_source=24_000,
        origin_target=16_000,
        resampler_delay_samples=160,
    )

    assert mapping.to_target(24_000) == 16_000
    assert mapping.to_target(24_003) == 16_002
    assert mapping.map_span(SampleSpan(24_000, 24_300)) == SampleSpan(16_000, 16_200)
    assert mapping.with_delay(SampleSpan(16_000, 16_200)) == SampleSpan(15_840, 16_040)
    with pytest.raises(ValueError):
        RateMap(source_rate=0, target_rate=CORE_SAMPLE_RATE)
    with pytest.raises(ValueError):
        RateMap(source_rate=24_000, target_rate=CORE_SAMPLE_RATE, resampler_delay_samples=-1)


def test_sample_clock_accepts_wire_rate_pcm_in_half_open_spans() -> None:
    clock = SampleClock(sample_rate=24_000)

    assert clock.accept(_pcm16([0] * 1_200)) == SampleSpan(0, 1_200)
    assert clock.accept(_pcm16([0] * 600)) == SampleSpan(1_200, 1_800)
    assert clock.accepted_samples == 1_800
    assert clock.sample_rate == 24_000
    clock.reset()
    assert clock.accepted_samples == 0
    with pytest.raises(ValueError):
        clock.accept(b"\x00")


def test_resampler_identity_rate_is_byte_identical() -> None:
    resampler = RationalResampler(CORE_SAMPLE_RATE, CORE_SAMPLE_RATE)
    payload = _pcm16(list(range(-100, 100)))

    # The final sample is lookahead for the next output, so it drains on flush.
    assert resampler.process(payload) + resampler.flush() == payload
    assert resampler.rate_map.identity


def test_resampler_interpolates_non_integer_positions() -> None:
    resampler = RationalResampler(8_000, 16_000)
    source = _pcm16([0, 300, 600])

    samples = _decode(resampler.process(source) + resampler.flush())

    # 3 source samples at 2x cover 6 target positions; the trailing half-sample
    # holds the final value instead of inventing a new one.
    assert samples == [0, 150, 300, 450, 600, 600]


def test_resampler_long_sequence_has_no_accumulated_drift() -> None:
    seconds = 60
    source_samples = 24_000 * seconds
    resampler = RationalResampler(24_000, CORE_SAMPLE_RATE)
    payload = _pcm16([0] * source_samples)

    produced = len(resampler.process(payload)) // 2
    tail = len(resampler.flush()) // 2

    assert produced + tail == CORE_SAMPLE_RATE * seconds
    assert resampler.output_samples == CORE_SAMPLE_RATE * seconds


def test_resampler_chunk_split_matches_single_shot() -> None:
    source = _pcm16([(index * 37) % 2_000 - 1_000 for index in range(24_000)])
    single = RationalResampler(24_000, CORE_SAMPLE_RATE)
    expected = single.process(source) + single.flush()

    chunked = RationalResampler(24_000, CORE_SAMPLE_RATE)
    produced = bytearray()
    for offset in range(0, len(source), 358):  # deliberately not a multiple of 3 samples
        produced.extend(chunked.process(source[offset : offset + 358]))
    produced.extend(chunked.flush())

    assert bytes(produced) == expected


def test_resampler_keeps_bounded_state_for_long_stream() -> None:
    resampler = RationalResampler(24_000, CORE_SAMPLE_RATE)

    for _ in range(2_000):
        resampler.process(_pcm16([0] * 300))

    assert resampler.pending_source_samples <= 2


def test_resampler_reset_isolates_a_cancelled_epoch() -> None:
    resampler = RationalResampler(24_000, CORE_SAMPLE_RATE)
    resampler.process(_pcm16([0] * 6))
    resampler.reset()

    assert resampler.output_samples == 0
    assert resampler.pending_source_samples == 0
    fresh = RationalResampler(24_000, CORE_SAMPLE_RATE)
    payload = _pcm16([0, 100, 200, 300])
    assert resampler.process(payload) == fresh.process(payload)


def test_resampler_rejects_partial_samples() -> None:
    resampler = RationalResampler(24_000, CORE_SAMPLE_RATE)

    with pytest.raises(ValueError):
        resampler.process(b"\x00\x01\x02")
    with pytest.raises(ValueError):
        RationalResampler(0, CORE_SAMPLE_RATE)
