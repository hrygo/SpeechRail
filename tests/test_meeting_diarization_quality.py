"""Tiny human-constructed references check independent scoring and identity scope."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from examples.perf.diarization_quality import score_diarization


def test_annotation_rounding_clips_at_most_one_actual_pcm_sample():
    result = score_diarization([span(0, 1.000025, "R1")], [span(0, 1, "S1")], duration=1)
    assert result["der"] == 0
    with pytest.raises(ValueError):
        score_diarization([span(0, 1.001, "R1")], [], duration=1)


def span(a, b, speaker):
    return {"start": a, "end": b, "speaker": speaker}


def test_whole_session_mapping_cannot_hide_window_identity_swaps():
    reference = [span(0, 5, "R1"), span(5, 10, "R2"), span(10, 15, "R1"), span(15, 20, "R2")]
    correct = [span(0, 5, "S2"), span(5, 10, "S1"), span(10, 15, "S2"), span(15, 20, "S1")]
    swapped = [span(0, 5, "S2"), span(5, 10, "S1"), span(10, 15, "S1"), span(15, 20, "S2")]
    good = score_diarization(reference, correct, duration=20)
    bad = score_diarization(reference, swapped, duration=20)
    assert good["der"] == 0 and good["known_accuracy"] == 1
    assert bad["der"] == pytest.approx(0.5) and bad["known_accuracy"] == pytest.approx(0.5)


def test_unknown_and_ignoring_short_interjectors_cannot_pass():
    reference = [
        span(0, 10, "R1"),
        span(10, 20, "R2"),
        span(20, 30, "R3"),
        span(30, 40, "R4"),
        span(40, 43, "R5"),
    ]
    partial = [span(0, 10, "S1"), span(10, 20, "S2"), span(20, 30, "S3"), span(30, 40, "S4")]
    result = score_diarization(reference, partial, duration=43)
    assert result["known_accuracy"] == 1 and result["quality_gate"] == "fail"
    assert result["other_min_known_coverage"] == 0
    unknown = score_diarization(reference, [], duration=43)
    assert unknown["known_coverage"] == 0 and unknown["quality_gate"] == "fail"


def test_overlap_and_collars_are_reported_separately_without_new_mapping():
    reference = [span(0, 4, "R1"), span(2, 6, "R2")]
    hypothesis = [span(0, 4, "S1"), span(2, 6, "S2")]
    result = score_diarization(reference, hypothesis, duration=6)
    assert result["der"] == result["jer"] == 0
    assert result["overlap_reference_speaker_seconds"] == 4
    assert result["comparable"]["collar_seconds"] == 0.25
