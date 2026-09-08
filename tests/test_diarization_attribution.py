from __future__ import annotations

import pytest

from speechrail.domain.diarization.attribution import AttributionLedger, union_support
from speechrail.domain.diarization.types import ActivityFrame, ActivityUpdate, Span, TextUnit


def _frame(start: int, end: int, *slots: int) -> ActivityFrame:
    return ActivityFrame(
        span=Span(start, end),
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
        replace_span=Span(start, end),
        frames=frames,
        processed_through=processed,
        stable_through=stable,
    )


def test_growth_is_union_not_repeated_evidence() -> None:
    unit = Span(0, 1600)
    assert union_support(unit, (Span(0, 1600), Span(0, 3200))) == 1.0


def test_overlap_is_not_a_probability_distribution() -> None:
    unit = Span(0, 1600)
    support = union_support(unit, (unit,))
    assert support + support == 2.0


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
    unit = TextUnit("unit_1", 0, 2, Span(0, 1600))
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
            TextUnit("final", 0, 1, Span(0, 1600)),
            TextUnit("pending", 1, 2, Span(1600, 3200)),
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
        TextUnit(f"unit-{index}", index, index + 1, Span(index * 1600, (index + 1) * 1600))
        for index in range(4)
    )

    assigned = ledger.register("item", units)

    assert [item.speaker for item in assigned] == ["A", "B", "C", "D"]
    assert all(item.state == "final" for item in assigned)
