"""R0 regressions: integer sample timeline and canonical-text alignment gate.

Covers the SPK-E2E-1 invariants that the session sample clock never restarts
per ASR item, that sub-millisecond packets do not drift the clock, and that a
timestamp candidate which silently drops or rewrites canonical characters is
rejected instead of re-timing the fixed transcript.
"""

from __future__ import annotations

import pytest

from speechrail.domain.diarization import ActivitySnapshot, DiarizationError, SpeakerActivity
from speechrail.domain.diarization_timeline import (
    AttributionLedger,
    AttributionUnit,
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


# ---------------------------------------------------------------------------
# R3: bounded attribution ledger over streaming activities


class _AttributionHarness:
    """Register one word-sized unit and apply scripted activity snapshots."""

    def __init__(self, **ledger_kwargs: object) -> None:
        self.ledger = AttributionLedger(**ledger_kwargs)  # type: ignore[arg-type]
        self._counter = 0
        self.last_result = None

    def assign(
        self,
        *,
        word: tuple[int, int],
        activities: list[tuple[str, int, int]],
        score: float = 0.9,
        processed_through: int | None = None,
    ) -> object:
        self._counter += 1
        unit = AttributionUnit(
            segment_uid=f"seg_{self._counter:03d}",
            text_start=0,
            text_end=2,
            start_sample=word[0],
            end_sample=word[1],
            timing_quality="aligned",
        )
        self.ledger.register(unit)
        watermark = (
            processed_through
            if processed_through is not None
            else max(word[1], max((end for _, _, end in activities), default=0))
        )
        snapshot = ActivitySnapshot(
            processed_through_sample=watermark,
            stable_through_sample=0,
            activities=tuple(
                SpeakerActivity(
                    start_sample=start,
                    end_sample=end,
                    speaker=speaker,
                    activity_score=score,
                )
                for speaker, start, end in activities
            ),
        )
        results = self.ledger.apply_activity(snapshot)
        for result in results:
            if result.segment_uid == unit.segment_uid:
                self.last_result = result
        assert self.last_result is not None
        return self.last_result

    def reapply(
        self,
        *,
        activities: list[tuple[str, int, int]],
        processed_through: int,
        score: float = 0.9,
    ) -> list[object]:
        """Fold another activity snapshot without registering a new unit."""
        snapshot = ActivitySnapshot(
            processed_through_sample=processed_through,
            stable_through_sample=0,
            activities=tuple(
                SpeakerActivity(
                    start_sample=start,
                    end_sample=end,
                    speaker=speaker,
                    activity_score=score,
                )
                for speaker, start, end in activities
            ),
        )
        return list(self.ledger.apply_activity(snapshot))


def test_temporal_speaker_change_is_not_overlap() -> None:
    harness = _AttributionHarness()
    result = harness.assign(
        word=(0, 3200),
        activities=[("spk_01", 0, 1600), ("spk_02", 1600, 3200)],
    )
    assert result.overlap_ratio == 0
    assert result.speaker is None
    assert result.status == "tentative"
    assert len(result.candidates) == 2


def test_true_overlap_requires_two_concurrent_speakers() -> None:
    harness = _AttributionHarness()
    result = harness.assign(
        word=(0, 3200),
        activities=[("spk_01", 0, 3200), ("spk_02", 0, 3200)],
    )
    assert result.overlap_ratio >= 0.20
    assert result.speaker is None
    assert [candidate[0] for candidate in result.candidates] == ["spk_01", "spk_02"]


def test_clear_single_speaker_stabilizes_after_two_consistent_steps() -> None:
    harness = _AttributionHarness()
    first = harness.assign(word=(0, 1600), activities=[("spk_01", 0, 1600)])
    assert first.status == "tentative"
    assert first.speaker == "spk_01"
    assert first.revision == 1

    # Same evidence again with the watermark past the word end -> stable.
    second = harness.reapply(activities=[("spk_01", 0, 1600)], processed_through=1600)
    assert second and second[0].segment_uid == first.segment_uid
    assert second[0].status == "stable"
    assert second[0].speaker == "spk_01"
    assert second[0].revision == 2


def test_short_interjection_is_not_absorbed_by_the_neighbor() -> None:
    harness = _AttributionHarness()
    result = harness.assign(
        word=(0, 3200),
        activities=[("spk_01", 0, 800), ("spk_02", 800, 3200)],
    )
    assert result.speaker == "spk_02"


def test_insufficient_evidence_yields_no_speaker() -> None:
    harness = _AttributionHarness()
    result = harness.assign(word=(0, 3200), activities=[("spk_01", 0, 1600)])
    assert result.coverage_ratio < 0.60
    assert result.speaker is None


def test_expiry_after_three_seconds_terminates_unknown() -> None:
    harness = _AttributionHarness()
    harness.assign(word=(0, 1600), activities=[("spk_01", 0, 1600)])

    late = harness.assign(
        word=(1600, 3200),
        activities=[("spk_02", 1600, 3200)],
        processed_through=1600 + 3 * 16_000 + 1,
    )
    assert late.status == "tentative"

    final = harness.ledger.apply_activity(
        ActivitySnapshot(
            processed_through_sample=1600 + 3 * 16_000 + 1600,
            stable_through_sample=0,
            activities=(),
        )
    )
    expired = [r for r in final if r.segment_uid == "seg_002"]
    assert expired and expired[0].status == "unknown"
    assert expired[0].speaker is None
    assert harness.ledger.stable_through_sample >= 1600


def test_frozen_units_never_change_after_freeze() -> None:
    harness = _AttributionHarness()
    harness.assign(word=(0, 1600), activities=[("spk_01", 0, 1600)])
    frozen = harness.ledger.freeze(through_sample=1600)
    assert frozen and frozen[0].status == "stable"

    changes = harness.ledger.apply_activity(
        ActivitySnapshot(
            processed_through_sample=48_000,
            stable_through_sample=0,
            activities=(
                SpeakerActivity(
                    start_sample=0, end_sample=1600, speaker="spk_02", activity_score=0.9
                ),
            ),
        )
    )
    assert all(r.segment_uid != "seg_001" for r in changes)


def test_identical_activity_reapplication_does_not_bump_revision() -> None:
    harness = _AttributionHarness()
    harness.assign(word=(0, 1600), activities=[("spk_01", 0, 1600)])
    harness.ledger.apply_activity(
        ActivitySnapshot(
            processed_through_sample=1600,
            stable_through_sample=0,
            activities=(
                SpeakerActivity(
                    start_sample=0, end_sample=1600, speaker="spk_01", activity_score=0.9
                ),
            ),
        )
    )
    third = harness.ledger.apply_activity(
        ActivitySnapshot(
            processed_through_sample=1600,
            stable_through_sample=0,
            activities=(
                SpeakerActivity(
                    start_sample=0, end_sample=1600, speaker="spk_01", activity_score=0.9
                ),
            ),
        )
    )
    assert all(r.segment_uid != "seg_001" for r in third)


def test_pending_unit_bounds_raise_overload() -> None:
    harness = _AttributionHarness(max_pending_units=1)
    harness.assign(word=(0, 1600), activities=[("spk_01", 0, 1600)])
    # The first unit is still revisable (one consistent step so far).
    with pytest.raises(DiarizationError) as excinfo:
        harness.assign(word=(1600, 3200), activities=[("spk_01", 1600, 3200)])
    assert excinfo.value.code == "diarization_overloaded"


def test_late_unit_uses_frozen_activities_without_reopening_the_window() -> None:
    ledger = AttributionLedger()
    ledger.apply_activity(
        ActivitySnapshot(
            processed_through_sample=200_000,
            stable_through_sample=0,
            activities=(
                SpeakerActivity(
                    start_sample=0, end_sample=1600, speaker="spk_01", activity_score=0.9
                ),
                SpeakerActivity(
                    start_sample=1600, end_sample=3200, speaker="spk_01", activity_score=0.9
                ),
            ),
        )
    )
    late = AttributionUnit(
        segment_uid="seg_late",
        text_start=0,
        text_end=2,
        start_sample=0,
        end_sample=1600,
        timing_quality="aligned",
    )
    ledger.register(late)
    assert ledger.stable_through_sample >= 1600
    state = ledger.unit_state("seg_late")
    assert state is not None and state["final"] is True
    assert state["status"] == "stable"


def test_unavailable_unit_is_immediately_unknown() -> None:
    ledger = AttributionLedger()
    unit = AttributionUnit(
        segment_uid="seg_unavailable",
        text_start=0,
        text_end=3,
        start_sample=0,
        end_sample=1600,
        timing_quality="unavailable",
    )
    ledger.register(unit)
    state = ledger.unit_state("seg_unavailable")
    assert state is not None and state["status"] == "unknown"
    assert state["final"] is True


def test_duplicate_unit_registration_is_rejected() -> None:
    ledger = AttributionLedger()
    unit = AttributionUnit(
        segment_uid="seg_dup",
        text_start=0,
        text_end=2,
        start_sample=0,
        end_sample=1600,
        timing_quality="aligned",
    )
    ledger.register(unit)
    with pytest.raises(ValueError):
        ledger.register(unit)
