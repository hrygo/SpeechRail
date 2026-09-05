"""R0 regressions: integer sample timeline and canonical-text alignment gate.

Covers the SPK-E2E-1 invariants that the session sample clock never restarts
per ASR item, that sub-millisecond packets do not drift the clock, and that a
timestamp candidate which silently drops or rewrites canonical characters is
rejected instead of re-timing the fixed transcript.
"""

from __future__ import annotations

import pytest

from speechrail.domain.diarization_timeline import (
    Timeline,
    build_alignment_units,
    comparison_indices,
    comparison_sequence,
    samples_to_ms,
    timestamps_within_item,
    verify_alignment,
)


def test_second_item_does_not_restart_the_session_clock() -> None:
    timeline = Timeline()
    assert timeline.accept(b"\x00\x00" * 48000) == (0, 48000)
    assert timeline.accept(b"\x00\x00" * 8000) == (48000, 56000)
    assert timeline.absolute(48000, 1600, 4800) == (49600, 52800)


def test_ten_thousand_sub_millisecond_packets_do_not_drift() -> None:
    """7-sample packets are 0.4375 ms; per-packet ms rounding must not drift."""
    timeline = Timeline()
    total = 0
    for _ in range(10_001):
        start, end = timeline.accept(b"\x00\x00" * 7)
        assert start == total
        assert end == total + 7
        total = end
    assert total == 70_007
    assert samples_to_ms(total) == 4_375


def test_odd_length_pcm_is_rejected() -> None:
    timeline = Timeline()
    with pytest.raises(ValueError):
        timeline.accept(b"\x00")
    assert timeline.accepted_samples == 0


def test_absolute_rejects_negative_or_inverted_spans() -> None:
    timeline = Timeline()
    with pytest.raises(ValueError):
        timeline.absolute(-1, 0, 10)
    with pytest.raises(ValueError):
        timeline.absolute(0, 10, 5)


def test_alignment_cannot_silently_drop_a_negation() -> None:
    assert not verify_alignment("不同意。", "同意。")
    assert verify_alignment("同意。", "同意")


def test_alignment_keeps_digits_but_ignores_punctuation_and_whitespace() -> None:
    assert not verify_alignment("第3名", "第三名")
    assert not verify_alignment("3个人", "三十个人")
    assert verify_alignment("第3名。", "第 3 名!")
    assert verify_alignment("OK, go on.", "OK go on")


def test_empty_canonical_text_compares_only_against_empty_or_punctuated() -> None:
    assert verify_alignment("", "")
    assert verify_alignment("", "。。。")
    assert not verify_alignment("", "同意")
    assert comparison_sequence("。。。") == ""
    assert comparison_indices("") == ()


def test_timestamps_must_be_finite_monotonic_and_inside_the_item() -> None:
    assert timestamps_within_item(0, 100, item_samples=200)
    assert timestamps_within_item(199, 200, item_samples=200)
    assert not timestamps_within_item(-1, 100, item_samples=200)
    assert not timestamps_within_item(100, 100, item_samples=200)
    assert not timestamps_within_item(0, 201, item_samples=200)


def test_units_partition_canonical_text_with_punctuation_merged() -> None:
    canonical = "同意，好的。"
    candidate = "同意,好的。"
    units = build_alignment_units(
        canonical,
        candidate,
        ((0, 2, 0, 1600), (3, 6, 1600, 3200)),
        item_samples=3200,
    )

    assert units is not None
    assert "".join(canonical[unit.text_start : unit.text_end] for unit in units) == canonical
    assert (units[0].start_sample, units[0].end_sample) == (0, 1600)
    assert (units[1].start_sample, units[1].end_sample) == (1600, 3200)


def test_units_absorb_leading_punctuation_into_the_first_word() -> None:
    canonical = "「同意。」"
    candidate = "同意。"
    units = build_alignment_units(canonical, candidate, ((0, 2, 0, 1600),), item_samples=1600)

    assert units is not None
    assert "".join(canonical[unit.text_start : unit.text_end] for unit in units) == canonical
    assert canonical[units[0].text_start : units[0].text_end] == "「同意。」"


def test_units_reject_inconsistent_candidate_text() -> None:
    assert (
        build_alignment_units("不同意。", "同意。", ((0, 2, 0, 1600),), item_samples=1600) is None
    )


def test_units_reject_sample_time_outside_the_item() -> None:
    assert (
        build_alignment_units("同意。", "同意。", ((0, 2, 0, 2000),), item_samples=1600) is None
    )


def test_units_reject_word_spans_leaving_uncovered_characters() -> None:
    assert (
        build_alignment_units("同意。", "同意", ((0, 1, 0, 1600),), item_samples=1600) is None
    )


def test_units_reject_overlapping_or_regressing_sample_times() -> None:
    assert (
        build_alignment_units(
            "同意好的。",
            "同意好的。",
            ((0, 2, 800, 2000), (2, 4, 0, 800)),
            item_samples=3200,
        )
        is None
    )
    assert (
        build_alignment_units(
            "同意好的。",
            "同意好的。",
            ((0, 2, 0, 2000), (2, 4, 1600, 3200)),
            item_samples=3200,
        )
        is None
    )


def test_units_accept_empty_transcript_without_words() -> None:
    assert build_alignment_units("", "", (), item_samples=1600) == ()
