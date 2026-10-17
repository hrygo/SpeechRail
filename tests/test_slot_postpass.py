"""Deterministic unit tests for whole-session Sortformer slot consolidation."""

from __future__ import annotations

import sys
from collections.abc import Iterable
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "examples" / "perf"))

from probe_meeting_sortformer_1to4 import (
    frames_to_speaker_spans,
)

from speechrail.backends.diarization.slot_postpass import (  # type: ignore[import-untyped]
    SlotConsolidationConfig,
    consolidate_slot_spans,
)
from speechrail.domain.audio_timeline import (  # type: ignore[import-untyped]
    SampleSpan,
)
from speechrail.domain.diarization.types import (  # type: ignore[import-untyped]
    ActivityFrame,
)


def _frame(start_sample: int, end_sample: int, slots: int | Iterable[int]) -> ActivityFrame:
    active_slots = frozenset({slots}) if isinstance(slots, int) else frozenset(slots)
    return ActivityFrame(
        span=SampleSpan(start_sample, end_sample),
        scores=None,
        active_slots=active_slots,
    )


def test_contiguous_frames_merge_into_one_span() -> None:
    frames = [_frame(0, 16_000, 0), _frame(16_000, 32_000, 0)]
    assert consolidate_slot_spans(frames, duration=10.0) == [
        {"start": 0.0, "end": 2.0, "speaker": "S1"}
    ]


def test_short_gap_within_bridge_seconds_becomes_one_span() -> None:
    # 0.0-1.0 and 1.1-2.0: a 0.1 s gap is below the 0.24 s bridge.
    frames = [_frame(0, 16_000, 0), _frame(17_600, 32_000, 0)]
    assert consolidate_slot_spans(frames, duration=10.0) == [
        {"start": 0.0, "end": 2.0, "speaker": "S1"}
    ]


def test_span_shorter_than_min_turn_is_dropped() -> None:
    frames = [_frame(0, 3_200, 0)]  # 0.2 s < 0.32 s minimum turn.
    assert consolidate_slot_spans(frames, duration=10.0) == []


def test_low_support_ghost_slot_is_merged_and_cluster_count_drops() -> None:
    frames = [
        _frame(0, 320_000, 0),  # dominant slot S1: 0-20 s
        _frame(640_000, 960_000, 0),  # dominant slot S1: 40-60 s
        _frame(320_000, 352_000, 1),  # ghost slot S2: 20-22 s
        _frame(960_000, 992_000, 1),  # ghost slot S2: 60-62 s
    ]
    result = consolidate_slot_spans(frames, duration=100.0)
    assert result == [
        {"start": 0.0, "end": 22.0, "speaker": "S1"},
        {"start": 40.0, "end": 62.0, "speaker": "S1"},
    ]
    assert {str(row["speaker"]) for row in result} == {"S1"}


def test_balanced_never_coactive_slots_are_not_merged() -> None:
    frames = [
        _frame(0, 320_000, 0),  # S1: 0-20 s
        _frame(640_000, 960_000, 0),  # S1: 40-60 s
        _frame(320_000, 640_000, 1),  # S2: 20-40 s
        _frame(960_000, 1_280_000, 1),  # S2: 60-80 s
    ]
    result = consolidate_slot_spans(frames, duration=100.0)
    assert result == [
        {"start": 0.0, "end": 20.0, "speaker": "S1"},
        {"start": 20.0, "end": 40.0, "speaker": "S2"},
        {"start": 40.0, "end": 60.0, "speaker": "S1"},
        {"start": 60.0, "end": 80.0, "speaker": "S2"},
    ]
    assert {str(row["speaker"]) for row in result} == {"S1", "S2"}


def test_ghost_shared_by_two_non_overlapping_slots_is_not_merged() -> None:
    # The ghost slot never overlaps two independent slots, so the target is
    # ambiguous and the low-support slot is left untouched.
    frames = [
        _frame(0, 320_000, 0),  # S1: 0-20 s
        _frame(320_000, 640_000, 1),  # S2: 20-40 s
        _frame(640_000, 704_000, 2),  # ghost S3: 40-44 s (4 s <= 6 s support)
    ]
    result = consolidate_slot_spans(frames, duration=100.0)
    assert {str(row["speaker"]) for row in result} == {"S1", "S2", "S3"}
    assert len(result) == 3


def test_empty_frames_return_empty_spans() -> None:
    assert consolidate_slot_spans([], duration=10.0) == []


def test_overlapping_slots_are_preserved_and_sorted() -> None:
    frames = [
        _frame(0, 80_000, 0),  # S1: 0-5 s
        _frame(32_000, 112_000, 1),  # S2: 2-7 s
        _frame(16_000, 48_000, 2),  # S3: 1-3 s
    ]
    result = consolidate_slot_spans(frames, duration=10.0)
    assert result == [
        {"start": 0.0, "end": 5.0, "speaker": "S1"},
        {"start": 1.0, "end": 3.0, "speaker": "S3"},
        {"start": 2.0, "end": 7.0, "speaker": "S2"},
    ]


def test_no_op_config_matches_probe_raw_conversion() -> None:
    # A config with no bridging, a near-zero minimum turn, and no ghost
    # re-attribution must reproduce the probe's raw conversion exactly, proving
    # consolidation is additive and the raw path is unchanged.
    frames = [
        _frame(0, 16_000, 0),
        _frame(16_000, 32_000, 0),
        _frame(35_200, 48_000, 1),
    ]
    config = SlotConsolidationConfig(
        bridge_seconds=0.0,
        min_turn_seconds=1e-9,
        ghost_support_fraction=0.0,
    )
    assert consolidate_slot_spans(frames, duration=10.0, config=config) == (
        frames_to_speaker_spans(frames, sample_rate=16_000, duration=10.0)
    )


def test_invalid_duration_and_config_are_rejected() -> None:
    with pytest.raises(ValueError, match="duration"):
        consolidate_slot_spans([], duration=-1.0)
    with pytest.raises(ValueError, match="duration"):
        consolidate_slot_spans([], duration=float("nan"))
    with pytest.raises(ValueError, match="min_turn_seconds"):
        SlotConsolidationConfig(min_turn_seconds=0.0)
    with pytest.raises(ValueError, match="ghost_support_fraction"):
        SlotConsolidationConfig(ghost_support_fraction=1.5)
    with pytest.raises(ValueError, match="sample_rate"):
        SlotConsolidationConfig(sample_rate=0)
