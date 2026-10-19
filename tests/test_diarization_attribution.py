from __future__ import annotations

import pytest

from speechrail.domain.diarization.attribution import AttributionLedger, union_support
from speechrail.domain.diarization.types import ActivityFrame, ActivityUpdate, SampleSpan, TextUnit


def _frame(start: int, end: int, *slots: int) -> ActivityFrame:
    return ActivityFrame(
        span=SampleSpan(start, end),
        scores=(0.9, 0.9, 0.9, 0.9),
        active_slots=frozenset(slots),
    )


def _update(
    *,
    step: int,
    start: int,
    end: int,
    frames: tuple[ActivityFrame, ...],
    processed: int,
    stable: int,
) -> ActivityUpdate:
    return ActivityUpdate(
        epoch="epoch_1",
        step_id=step,
        replace_span=SampleSpan(start, end),
        frames=frames,
        processed_through=processed,
        stable_through=stable,
    )


def test_growth_is_union_not_repeated_evidence() -> None:
    unit = SampleSpan(0, 1600)
    assert union_support(unit, (SampleSpan(0, 1600), SampleSpan(0, 3200))) == 1.0


def test_overlap_is_not_a_probability_distribution() -> None:
    unit = SampleSpan(0, 1600)
    support = union_support(unit, (unit,))
    assert support + support == 2.0


def test_repeated_local_attribution_does_not_rescan_unrelated_history(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    frames = tuple(_frame(i * 10, (i + 1) * 10, 0) for i in range(4096))
    ledger = AttributionLedger(accepted_samples=lambda: 40960)
    ledger.apply(_update(step=1, start=0, end=40960, frames=frames,
                         processed=40960, stable=40960))
    ledger.register("warmup", (TextUnit("warmup", 0, 1, SampleSpan(40000, 40010)),))
    reads = 0
    original = ActivityFrame.__getattribute__

    def counted(frame: ActivityFrame, name: str):
        nonlocal reads
        if name == "span":
            reads += 1
        return original(frame, name)

    monkeypatch.setattr(ActivityFrame, "__getattribute__", counted)
    (result,) = ledger.register("next", (TextUnit("next", 0, 1, SampleSpan(40010, 40020)),))
    assert result.speaker == "A" and result.state == "final"
    # Work, rather than elapsed time: independent of CPU speed and CI load.
    assert reads < 64


def test_nested_earlier_activity_remains_evidence_for_later_text() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 10000)
    ledger.apply(_update(step=1, start=0, end=10000,
                         frames=(_frame(0, 10000, 0), _frame(100, 200, 1),
                                 _frame(300, 400, 1)),
                         processed=10000, stable=10000))
    (result,) = ledger.register("item", (TextUnit("late", 0, 1, SampleSpan(9000, 9100)),))
    assert result.speaker == "A" and result.active_speakers == ("A",)


def test_local_attribution_after_compaction_uses_retained_activity() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 30)
    ledger.apply(_update(step=1, start=0, end=30,
                         frames=(_frame(0, 10, 0), _frame(10, 20, 1), _frame(20, 30, 2)),
                         processed=30, stable=30))
    ledger.register("warmup", tuple(
        TextUnit(f"old-{i}", i, i + 1, SampleSpan(i * 10, (i + 1) * 10))
        for i in range(3)
    ))
    ledger.compact(20)
    (result,) = ledger.register("late", (TextUnit("late", 0, 1, SampleSpan(20, 30)),))
    assert result.speaker == "C" and result.active_speakers == ("C",)


def _scored_overlap(
    scores: tuple[float, ...] | None, *, start: int = 0, end: int = 1600,
    reason: str | None = None,
) -> ActivityFrame:
    return ActivityFrame(SampleSpan(start, end), scores, frozenset({0, 1}), reason)


def _attribute_frames(frames: tuple[ActivityFrame, ...]):
    ledger = AttributionLedger(accepted_samples=lambda: 1600)
    ledger.apply(_update(step=1, start=0, end=1600, frames=frames,
                         processed=1600, stable=1600))
    return ledger.register("item", (TextUnit("unit", 0, 1, SampleSpan(0, 1600)),))[0]


def test_confident_independent_scores_resolve_ambiguous_activity() -> None:
    # Both participants cover the whole word; their scores need not sum to one.
    result = _attribute_frames((_scored_overlap((0.95, 0.70)),))
    assert result.speaker == "A" and result.reason is None
    assert result.active_speakers == ("A", "B") and result.state == "final"


def test_probability_support_is_weighted_by_duration_not_frame_count() -> None:
    result = _attribute_frames((
        _scored_overlap((0.99, 0.51), end=160),
        _scored_overlap((0.51, 0.95), start=160),
    ))
    assert result.speaker == "B"


@pytest.mark.parametrize("frames", [
    (_scored_overlap((0.95, 0.94)),),
    (_scored_overlap((0.59, 0.25)),),
    (_scored_overlap(None),),
    (_scored_overlap((0.95, 0.70), end=800), _scored_overlap(None, start=800)),
    (_scored_overlap((0.95, 0.70)), _scored_overlap((0.95, 0.70))),
    (_scored_overlap((0.95, 0.70), end=1200),
     _scored_overlap((0.95, 0.70), start=800)),
    # Only one participant meets the existing activity coverage minimum.
    (_scored_overlap((0.95, 0.70), end=880),
     ActivityFrame(SampleSpan(880, 960), (0.95, 0.70), frozenset({0})),
     ActivityFrame(SampleSpan(960, 1600), (0.95, 0.70), frozenset())),
    # Scores without active evidence cannot contribute support.
    (_scored_overlap((0.95, 0.70), end=900),
     ActivityFrame(SampleSpan(900, 1600), (0.95, 0.70), frozenset())),
])
def test_ambiguous_or_incomplete_probability_evidence_stays_unknown(
    frames: tuple[ActivityFrame, ...],
) -> None:
    result = _attribute_frames(frames)
    assert result.speaker is None and result.reason == "insufficient_evidence"


@pytest.mark.parametrize("reason", [
    "activity_gap", "audio_expired", "model_not_ready", "speaker_capacity",
    "identity_uncertain",
])
def test_probability_evidence_cannot_override_degradation_reason(reason: str) -> None:
    result = _attribute_frames((_scored_overlap((0.95, 0.70), reason=reason),))
    assert result.speaker is None and result.reason == reason


def test_probability_evidence_preserves_unambiguous_activity_assignment() -> None:
    result = _attribute_frames((
        _scored_overlap((0.30, 0.99), end=800),
        ActivityFrame(SampleSpan(800, 1600), (0.30, 0.99), frozenset({0})),
    ))
    assert result.speaker == "A"


def test_one_voice_across_an_internal_pause_retains_word_attribution() -> None:
    # A single aligned word can include a pause. The same sole voice speaks
    # at both ends; inactive frames are not a competing speaker.
    result = _attribute_frames((
        ActivityFrame(SampleSpan(0, 400), (0.9, 0.01), frozenset({0})),
        ActivityFrame(SampleSpan(400, 1200), (0.05, 0.01), frozenset()),
        ActivityFrame(SampleSpan(1200, 1600), (0.9, 0.01), frozenset({0})),
    ))
    assert result.speaker == "A" and result.active_speakers == ("A",)
    assert result.state == "final" and result.reason is None


@pytest.mark.parametrize("middle,last", [
    # Another speaker, unavailable scores, missing coverage, overlapping frames,
    # degraded evidence, and an open edge must not become a confident identity.
    (ActivityFrame(SampleSpan(400, 1200), (0.05, 0.9), frozenset({1})),
     ActivityFrame(SampleSpan(1200, 1600), (0.9, 0.01), frozenset({0}))),
    (ActivityFrame(SampleSpan(400, 1200), None, frozenset()),
     ActivityFrame(SampleSpan(1200, 1600), (0.9, 0.01), frozenset({0}))),
    (ActivityFrame(SampleSpan(500, 1200), (0.05, 0.01), frozenset()),
     ActivityFrame(SampleSpan(1200, 1600), (0.9, 0.01), frozenset({0}))),
    (ActivityFrame(SampleSpan(300, 1200), (0.05, 0.01), frozenset()),
     ActivityFrame(SampleSpan(1200, 1600), (0.9, 0.01), frozenset({0}))),
    (ActivityFrame(SampleSpan(400, 1200), (0.05, 0.01), frozenset(), "activity_gap"),
     ActivityFrame(SampleSpan(1200, 1600), (0.9, 0.01), frozenset({0}))),
    (ActivityFrame(SampleSpan(400, 1200), (0.05, 0.01), frozenset()),
     ActivityFrame(SampleSpan(1200, 1600), (0.05, 0.01), frozenset())),
    (ActivityFrame(SampleSpan(400, 1200), (0.05, 0.01), frozenset()),
     ActivityFrame(SampleSpan(1200, 1500), (0.9, 0.01), frozenset({0}))),
])
def test_internal_pause_does_not_override_conflicting_or_missing_evidence(
    middle: ActivityFrame, last: ActivityFrame,
) -> None:
    result = _attribute_frames((
        ActivityFrame(SampleSpan(0, 400), (0.9, 0.01), frozenset({0})),
        middle, last,
    ))
    assert result.speaker is None


def test_internal_pause_requires_confidence_weighted_by_active_duration() -> None:
    result = _attribute_frames((
        ActivityFrame(SampleSpan(0, 100), (0.99,), frozenset({0})),
        ActivityFrame(SampleSpan(100, 1000), (0.05,), frozenset()),
        ActivityFrame(SampleSpan(1000, 1600), (0.4,), frozenset({0})),
    ))
    assert result.speaker is None and result.reason == "insufficient_evidence"


def test_leading_silence_is_not_an_internal_pause() -> None:
    result = _attribute_frames((
        ActivityFrame(SampleSpan(0, 800), (0.05,), frozenset()),
        ActivityFrame(SampleSpan(800, 1600), (0.9,), frozenset({0})),
    ))
    assert result.speaker is None and result.reason == "insufficient_evidence"


def test_internal_pause_attribution_follows_watermarks_and_final_is_immutable() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 1600)
    frames = (
        ActivityFrame(SampleSpan(0, 400), (0.9,), frozenset({0})),
        ActivityFrame(SampleSpan(400, 1200), (0.05,), frozenset()),
        ActivityFrame(SampleSpan(1200, 1600), (0.9,), frozenset({0})),
    )
    ledger.apply(_update(step=1, start=0, end=1600, frames=frames,
                         processed=1600, stable=0))
    (first,) = ledger.register("item", (TextUnit("word", 0, 2, SampleSpan(0, 1600)),))
    assert first.speaker == "A" and first.state == "provisional"
    (final,) = ledger.apply(_update(step=2, start=1600, end=1600, frames=(),
                                   processed=1600, stable=1600))
    assert final.speaker == "A" and final.state == "final"
    assert final.revision == first.revision + 1
    assert ledger.terminate_pending("model_not_ready") == ()


def test_changed_scores_revise_provisional_attribution_but_not_final_text() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 3200)
    ledger.apply(_update(step=1, start=0, end=1600,
                         frames=(_scored_overlap((0.95, 0.70)),),
                         processed=1600, stable=0))
    (first,) = ledger.register("item", (TextUnit("unit", 0, 1, SampleSpan(0, 1600)),))
    (changed,) = ledger.apply(_update(step=2, start=0, end=1600,
                                     frames=(_scored_overlap((0.70, 0.95)),),
                                     processed=1600, stable=1600))
    assert first.speaker == "A" and first.state == "provisional"
    assert changed.speaker == "B" and changed.state == "final"
    assert changed.revision == first.revision + 1
    assert ledger.apply(_update(step=3, start=1600, end=3200,
                                frames=(_scored_overlap((0.95, 0.70), start=1600, end=3200),),
                                processed=3200, stable=3200)) == ()


def test_replacement_clips_a_crossing_frame_without_losing_the_stable_prefix() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 30 * 16000, label_mode="meeting_dynamic")
    ledger.apply(
        _update(
            step=1,
            start=0,
            end=20 * 16000,
            frames=(ActivityFrame(SampleSpan(0, 20 * 16000), None, frozenset({4})),),
            processed=20 * 16000,
            stable=10 * 16000,
        )
    )
    (first,) = ledger.register(
        "item", (TextUnit("crossing", 0, 1, SampleSpan(9 * 16000, 11 * 16000)),)
    )
    assert first.speaker == "S5" and first.state == "provisional"
    changed = ledger.apply(
        _update(
            step=2,
            start=10 * 16000,
            end=30 * 16000,
            frames=(ActivityFrame(SampleSpan(10 * 16000, 30 * 16000), None, frozenset({4})),),
            processed=30 * 16000,
            stable=20 * 16000,
        )
    )
    assert len(changed) == 1
    assert changed[0].state == "final" and changed[0].speaker == "S5"
    (before,) = ledger.register(
        "late-fixed-text", (TextUnit("prefix", 0, 1, SampleSpan(0, 10 * 16000)),)
    )
    assert before.speaker == "S5" and before.state == "final"


def test_duplicate_activity_step_is_idempotent_but_conflict_fails() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 1600)
    update = _update(
        step=1,
        start=0,
        end=1600,
        frames=(_frame(0, 1600, 0),),
        processed=1600,
        stable=0,
    )

    assert ledger.apply(update) == ()
    assert ledger.apply(update) == ()
    with pytest.raises(ValueError, match="different payload"):
        ledger.apply(
            _update(
                step=1,
                start=0,
                end=1600,
                frames=(_frame(0, 1600, 1),),
                processed=1600,
                stable=0,
            )
        )


def test_watermarks_are_monotonic_and_stable_frames_are_immutable() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 3200)
    ledger.apply(
        _update(
            step=1,
            start=0,
            end=1600,
            frames=(_frame(0, 1600, 0),),
            processed=1600,
            stable=1600,
        )
    )
    with pytest.raises(ValueError, match="stable frames"):
        ledger.apply(
            _update(
                step=2,
                start=0,
                end=1600,
                frames=(_frame(0, 1600, 1),),
                processed=1600,
                stable=1600,
            )
        )
    with pytest.raises(ValueError, match="move backwards"):
        ledger.apply(
            _update(
                step=2,
                start=1600,
                end=3200,
                frames=(_frame(1600, 3200, 1),),
                processed=3200,
                stable=0,
            )
        )


def test_final_attribution_is_covered_by_real_stable_watermark() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 1600)
    unit = TextUnit("unit_1", 0, 2, SampleSpan(0, 1600))
    first = ledger.register("item_1", (unit,))
    assert first[0].state == "provisional"
    changed = ledger.apply(
        _update(
            step=1,
            start=0,
            end=1600,
            frames=(_frame(0, 1600, 0),),
            processed=1600,
            stable=1600,
        )
    )
    assert len(changed) == 1
    assert changed[0].state == "final"
    assert changed[0].speaker == "A"


@pytest.mark.parametrize("slots", [(), (0,)])
def test_unchanged_activity_preserves_revision_until_finalization(slots: tuple[int, ...]) -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 3200)
    ledger.apply(
        _update(step=1, start=0, end=1600, frames=(_frame(0, 1600, *slots),),
                processed=1600, stable=0)
    )
    (first,) = ledger.register("item", (TextUnit("unit", 0, 1, SampleSpan(0, 1600)),))
    assert first.revision == 1 and first.state == "provisional"

    # A later activity step can repeat the same evidence without changing the label.
    assert ledger.apply(
        _update(step=2, start=0, end=3200,
                frames=(_frame(0, 1600, *slots), _frame(1600, 3200, 1)),
                processed=3200, stable=0)
    ) == ()

    (final,) = ledger.apply(
        _update(step=3, start=3200, end=3200, frames=(), processed=3200, stable=1600)
    )
    assert final.revision == 2 and final.state == "final"
    assert final.speaker == first.speaker
    assert final.active_speakers == first.active_speakers


def test_changed_provisional_speaker_still_emits_next_revision() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 1600)
    ledger.apply(
        _update(step=1, start=0, end=1600, frames=(_frame(0, 1600, 0),),
                processed=1600, stable=0)
    )
    (first,) = ledger.register("item", (TextUnit("unit", 0, 1, SampleSpan(0, 1600)),))
    (changed,) = ledger.apply(
        _update(step=2, start=0, end=1600, frames=(_frame(0, 1600, 1),),
                processed=1600, stable=0)
    )
    assert first.speaker == "A"
    assert changed.speaker == "B" and changed.state == "provisional"
    assert changed.revision == first.revision + 1


@pytest.mark.parametrize("frames", [(), (_frame(1600, 3200, 1),)])
def test_unrelated_activity_avoids_pending_unit_work_but_finalization_still_runs(
    monkeypatch: pytest.MonkeyPatch, frames: tuple[ActivityFrame, ...]
) -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 3200)
    ledger.apply(
        _update(step=1, start=0, end=1600, frames=(_frame(0, 1600, 0),),
                processed=1600, stable=0)
    )
    ledger.register("item", (TextUnit("unit", 0, 1, SampleSpan(0, 1600)),))
    original_frames = ledger._frames
    evaluate = ledger._evaluate
    evaluated: list[str] = []

    def measured(unit: TextUnit, *, revision: int):
        evaluated.append(unit.id)
        return evaluate(unit, revision=revision)

    monkeypatch.setattr(ledger, "_evaluate", measured)
    assert ledger.apply(
        _update(step=2, start=1600, end=3200 if frames else 1600, frames=frames,
                processed=3200 if frames else 1600, stable=0)
    ) == ()
    # Count work rather than elapsed time so the bound holds on slower machines.
    assert evaluated == []
    if not frames:
        assert ledger._frames is original_frames
    (final,) = ledger.apply(
        _update(step=3, start=3200, end=3200, frames=(), processed=3200, stable=1600)
    )
    assert evaluated == ["unit"]
    assert final.state == "final" and final.speaker == "A" and final.revision == 2


def test_degradation_only_finalizes_pending_unknown_units() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 3200)
    ledger.apply(
        _update(
            step=1,
            start=0,
            end=1600,
            frames=(_frame(0, 1600, 0),),
            processed=1600,
            stable=1600,
        )
    )
    first, second = ledger.register(
        "item_1",
        (
            TextUnit("final", 0, 1, SampleSpan(0, 1600)),
            TextUnit("pending", 1, 2, SampleSpan(1600, 3200)),
        ),
    )
    assert first.state == "final"
    assert second.state == "provisional"
    changed = ledger.terminate_pending("worker_crash")
    assert len(changed) == 1
    assert changed[0].unit_id == "pending"
    assert changed[0].speaker is None
    assert changed[0].state == "final"


def test_session_labels_are_stable_anonymous_a_through_d() -> None:
    ledger = AttributionLedger(accepted_samples=lambda: 6400)
    ledger.apply(
        _update(
            step=1,
            start=0,
            end=6400,
            frames=(
                _frame(0, 1600, 3),
                _frame(1600, 3200, 1),
                _frame(3200, 4800, 2),
                _frame(4800, 6400, 0),
            ),
            processed=6400,
            stable=6400,
        )
    )
    units = tuple(
        TextUnit(f"unit-{index}", index, index + 1, SampleSpan(index * 1600, (index + 1) * 1600))
        for index in range(4)
    )

    assigned = ledger.register("item", units)

    assert [item.speaker for item in assigned] == ["A", "B", "C", "D"]
    assert all(item.state == "final" for item in assigned)


def test_compaction_retains_only_bounded_recent_activity_and_rejects_late_rewrite():
    from speechrail.domain.audio_timeline import SampleSpan
    from speechrail.domain.diarization.attribution import AttributionLedger
    from speechrail.domain.diarization.types import ActivityFrame, ActivityUpdate

    accepted = 7200 * 16000
    ledger = AttributionLedger(accepted_samples=lambda: accepted)
    for step in range(720):
        start, end = step * 160000, (step + 1) * 160000
        ledger.apply(
            ActivityUpdate(
                epoch="long",
                step_id=step,
                replace_span=SampleSpan(start, end),
                frames=(ActivityFrame(SampleSpan(start, end), (0.9, 0.0, 0.0, 0.0), (0,)),),
                processed_through=end,
                stable_through=end,
            )
        )
        ledger.compact(max(0, end - 60 * 16000))
    assert ledger.retained_counts["frames"] <= 6
    assert ledger.retained_counts["steps"] <= 64
