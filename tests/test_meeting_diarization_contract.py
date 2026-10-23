"""Meeting evidence identifies at most four stable anonymous speakers."""

import pytest

from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.diarization.attribution import AttributionLedger
from speechrail.domain.diarization.types import ActivityFrame, ActivityUpdate, TextUnit


@pytest.mark.parametrize("slot", [0, 1, 3])
def test_dynamic_activity_has_no_fabricated_probability_and_stable_numeric_label(slot):
    frame = ActivityFrame(SampleSpan(0, 16000), None, frozenset({slot}))
    ledger = AttributionLedger(accepted_samples=lambda: 16000, label_mode="meeting_dynamic")
    ledger.apply(ActivityUpdate("epoch", 1, frame.span, (frame,), 16000, 16000))
    unit = ledger.register("item", (TextUnit("unit", 0, 1, frame.span),))[0]
    assert unit.speaker == f"S{slot + 1}"


@pytest.mark.parametrize(
    "slots,scores",
    [
        (frozenset({32}), None),
        (frozenset({True}), None),
        (frozenset({4}), (0.1, 0.2, 0.3, 0.4)),
        (frozenset(), ()),
    ],
)
def test_out_of_bounds_or_mismatched_evidence_is_rejected(slots, scores):
    with pytest.raises(ValueError):
        ActivityFrame(SampleSpan(0, 16000), scores, slots)


def test_empty_activity_stays_unknown():
    ledger = AttributionLedger(accepted_samples=lambda: 16000, label_mode="meeting_dynamic")
    ledger.apply(ActivityUpdate("epoch", 1, SampleSpan(0, 16000), (), 16000, 16000))
    assert (
        ledger.register("item", (TextUnit("unit", 0, 1, SampleSpan(0, 16000)),))[0].speaker is None
    )


def test_activity_gap_is_retained_as_unknown_reason():
    ledger = AttributionLedger(accepted_samples=lambda: 16000, label_mode="meeting_dynamic")
    frame = ActivityFrame(SampleSpan(0, 16000), None, frozenset(), "activity_gap")
    ledger.apply(ActivityUpdate("epoch", 1, frame.span, (frame,), 16000, 16000))
    unit = ledger.register("item", (TextUnit("unit", 0, 1, frame.span),))[0]
    assert unit.speaker is None and unit.reason == "activity_gap"
