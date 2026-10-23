"""Synthetic references for selective, frozen-identity attribution metrics."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from examples.perf.stable_speaker_metrics import score_stable_speakers


def span(start, end, speaker):
    return {"start": start, "end": end, "speaker": speaker}


@pytest.mark.parametrize("extra_count", [1, 2])
def test_four_major_speakers_and_unknown_extras(extra_count):
    reference = [span(i * 22.5, (i + 1) * 22.5, f"R{i}") for i in range(4)]
    reference += [
        span(90 + i * 10 / extra_count, 90 + (i + 1) * 10 / extra_count, f"R{4 + i}")
        for i in range(extra_count)
    ]
    hypothesis = [span(row["start"], row["end"], f"S{i}") for i, row in enumerate(reference[:4])]
    hypothesis += [span(90, 100, "unknown")]
    result = score_stable_speakers(
        reference, hypothesis, duration=100, speaker_mapping={f"S{i}": f"R{i}" for i in range(4)}
    )
    assert result["identity_limit"] == 4
    assert result["identity_budget_exceeded"] is False
    assert result["known_precision"] == 1
    assert result["correct_coverage"] == pytest.approx(0.9)
    assert result["unknown_fraction"] == pytest.approx(0.1)
    assert result["out_of_set_false_accept_rate"] == 0
    assert result["tracked_speech_fraction"] == pytest.approx(0.9)
    assert result["oracle_top_four_fraction"] == pytest.approx(0.9)
    assert len(result["per_speaker"]) == 4 + extra_count
    assert result["per_speaker"]["R4"]["correct_coverage"] == 0
    assert "quality_gate" not in result


def test_balanced_eight_speakers_have_half_speech_oracle_ceiling():
    reference = [span(i * 2, (i + 1) * 2, f"R{i}") for i in range(8)]
    result = score_stable_speakers(
        reference,
        [span(i * 2, (i + 1) * 2, f"S{i}") for i in range(4)],
        duration=16,
        speaker_mapping={f"S{i}": f"R{i}" for i in range(4)},
    )
    assert result["correct_coverage"] == result["oracle_top_four_fraction"] == 0.5
    assert result["unknown_fraction"] == result["tracked_speech_fraction"] == 0.5


def test_short_interjection_unknown_and_return_after_budget_is_full():
    reference = [span(i * 2, (i + 1) * 2, f"R{i}") for i in range(4)]
    reference += [span(8, 8.5, "R4"), span(8.5, 10.5, "R0")]
    hypothesis = [span(i * 2, (i + 1) * 2, f"S{i}") for i in range(4)]
    hypothesis += [span(8, 8.5, None), span(8.5, 10.5, "S0")]
    mapping = {f"S{i}": f"R{i}" for i in range(4)}
    good = score_stable_speakers(reference, hypothesis, duration=10.5, speaker_mapping=mapping)
    assert good["per_speaker"]["R0"]["correct_seconds"] == 4
    assert good["short_turns"] == {
        "threshold_seconds": 1.5,
        "count": 1,
        "misattributed_count": 0,
        "reference_seconds": 0.5,
        "correct_seconds": 0,
        "unknown_seconds": 0.5,
    }
    hypothesis[-2]["speaker"] = "S0"
    bad = score_stable_speakers(reference, hypothesis, duration=10.5, speaker_mapping=mapping)
    assert bad["short_turns"]["misattributed_count"] == 1
    assert bad["out_of_set_false_accept_rate"] == 1
    assert bad["per_speaker"]["R4"]["known_seconds"] == 0.5


def test_frozen_mapping_exposes_returning_speaker_identity_swaps():
    reference = [span(0, 2, "R0"), span(2, 4, "R1"), span(4, 6, "R0"), span(6, 8, "R1")]
    hypothesis = [span(0, 2, "S0"), span(2, 4, "S1"), span(4, 6, "S1"), span(6, 8, "S0")]
    result = score_stable_speakers(
        reference, hypothesis, duration=8, speaker_mapping={"S0": "R0", "S1": "R1"}
    )
    assert result["known_precision"] == result["correct_coverage"] == 0.5
    assert result["unknown_fraction"] == 0


def test_unknown_gaps_use_reference_speech_denominator_and_no_text_claim():
    result = score_stable_speakers(
        [span(2, 6, "R0")],
        [span(2, 3, "S0"), span(3, 4, "unknown")],
        duration=10,
        speaker_mapping={"S0": "R0"},
    )
    assert result["unknown_fraction"] == 0.75
    assert result["correct_coverage"] == 0.25
    assert result["per_speaker"]["R0"]["unknown_seconds"] == 3
    assert not any("text" in key or "word" in key for key in result)


def test_known_precision_includes_nonspeech_false_alarms():
    result = score_stable_speakers(
        [span(1, 2, "R0")],
        [span(0, 3, "S0")],
        duration=4,
        speaker_mapping={"S0": "R0"},
    )
    assert result["known_precision"] == pytest.approx(1 / 3)
    assert result["correct_coverage"] == 1


def test_all_unknown_and_zero_speech_are_not_perfect_scores():
    result = score_stable_speakers([span(0, 1, "R0")], [], duration=1, speaker_mapping={})
    assert result["known_precision"] is None
    assert result["correct_coverage"] == 0
    assert result["unknown_fraction"] == 1
    empty = score_stable_speakers([], [], duration=1, speaker_mapping={})
    for key in (
        "known_precision",
        "correct_coverage",
        "unknown_fraction",
        "out_of_set_false_accept_rate",
        "tracked_speech_fraction",
        "oracle_top_four_fraction",
    ):
        assert empty[key] is None


def test_mapping_is_confirmed_not_inferred_from_most_frequent_speakers():
    result = score_stable_speakers(
        [span(0, 9, "R0"), span(9, 10, "R1")],
        [span(9, 10, "S0")],
        duration=10,
        speaker_mapping={"S0": "R1"},
    )
    assert result["tracked_speech_fraction"] == 0.1
    assert result["correct_coverage"] == 0.1
    assert result["oracle_top_four_fraction"] == 1


def test_adjacent_reference_fragments_form_one_turn_and_inputs_are_unchanged():
    reference = [span(1, 2, "R0"), span(0, 1, "R0")]
    result = score_stable_speakers(reference, [], duration=2, speaker_mapping={})
    assert result["short_turns"]["count"] == 0
    assert reference == [span(1, 2, "R0"), span(0, 1, "R0")]


@pytest.mark.parametrize("duration", [float("nan"), float("inf"), True, "1", 0, -1])
def test_invalid_duration(duration):
    with pytest.raises(ValueError):
        score_stable_speakers([], [], duration=duration, speaker_mapping={})


@pytest.mark.parametrize(
    "row",
    [
        span(float("nan"), 1, "R0"),
        span(0, float("inf"), "R0"),
        span(-1, 1, "R0"),
        span(0, 2, "R0"),
        span(1, 1, "R0"),
        span(True, 1, "R0"),
        span("0", 1, "R0"),
        span(0, 1, ""),
        {},
    ],
)
@pytest.mark.parametrize("track", ["reference", "hypothesis"])
def test_invalid_intervals(row, track):
    with pytest.raises(ValueError):
        score_stable_speakers(
            [row] if track == "reference" else [],
            [row] if track == "hypothesis" else [],
            duration=1,
            speaker_mapping={},
        )


@pytest.mark.parametrize("label", [None, "unknown"])
def test_reference_must_contain_real_identity(label):
    with pytest.raises(ValueError):
        score_stable_speakers([span(0, 1, label)], [], duration=1, speaker_mapping={})


@pytest.mark.parametrize("track", ["reference", "hypothesis"])
def test_overlaps_rejected_even_for_same_label(track):
    rows = [span(0, 1, "R0"), span(0.5, 1.5, "R0")]
    with pytest.raises(ValueError, match="overlap"):
        score_stable_speakers(
            rows if track == "reference" else [],
            rows if track == "hypothesis" else [],
            duration=2,
            speaker_mapping={"R0": "R0"},
        )


@pytest.mark.parametrize(
    "mapping",
    [
        {"S0": "R0", "S1": "R0"},
        {"unknown": "R0"},
        {"S0": "unknown"},
        {"S0": None},
        {None: "R0"},
        {f"S{i}": f"R{i}" for i in range(5)},
    ],
)
def test_invalid_frozen_mapping(mapping):
    with pytest.raises(ValueError):
        score_stable_speakers([], [], duration=1, speaker_mapping=mapping)


def test_unmapped_output_and_fifth_output_fail_explicitly():
    for labels in (["S4"], [f"S{i}" for i in range(5)]):
        with pytest.raises(ValueError, match=r"mapping|budget"):
            score_stable_speakers(
                [],
                [span(i, i + 1, label) for i, label in enumerate(labels)],
                duration=5,
                speaker_mapping={f"S{i}": f"R{i}" for i in range(4)},
            )


def test_partial_short_turn_confusion_and_unknown_are_accounted_separately():
    result = score_stable_speakers(
        [span(0, 1, "R0"), span(1, 2.5, "R1")],
        [span(0, 0.25, "S0"), span(0.25, 0.5, "S1"), span(0.5, 1, None)],
        duration=3,
        speaker_mapping={"S0": "R0", "S1": "R1"},
    )
    assert result["short_turns"]["count"] == 1  # Exactly 1.5 seconds is not short.
    assert result["short_turns"]["misattributed_count"] == 1
    assert result["short_turns"]["correct_seconds"] == 0.25
    assert result["short_turns"]["unknown_seconds"] == 0.5
    assert result["per_speaker"]["R0"]["known_seconds"] == 0.5


def test_silent_confirmed_identity_and_non_speech_false_alarm():
    result = score_stable_speakers(
        [],
        [span(0, 1, "S0")],
        duration=1,
        speaker_mapping={"S0": "R0"},
    )
    assert result["known_precision"] == 0
    assert result["correct_coverage"] is None
    assert result["unknown_fraction"] is None
    assert result["per_speaker"] == {}
