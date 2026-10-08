"""Focused ASR triage must not turn text localization into acoustic attribution."""

import copy
import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf.asr_focus_analysis import analyze_pair, main


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def session(fixture="synthetic-case", *, errors=1, preview="preview", terminal="preview"):
    diagnostic = {
        "diagnostic_schema_version": 1,
        "normalization": "NFKC_casefold_letters_numbers_marks",
        "reference_normalized_sha256": digest("reference"),
        "reference_characters": 10,
        "hypothesis_normalized_sha256": digest(terminal),
        "hypothesis_characters": 10,
        "character_errors": errors,
        "acoustic_error_attribution": "not_observed",
        "segments": [{
            "ordinal": 0,
            "start_sample": 0,
            "end_sample": 24_000,
            "terminal_normalized_sha256": digest(terminal),
            "preview_normalized_sha256": digest(preview) if preview is not None else None,
        }],
    }
    return {
        "id": fixture,
        "repeat": 1,
        "audio_seconds": 1.0,
        "effective_policy": {
            "preview_interval_ms": 500,
            "max_segment_ms": 8000,
            "effective_max_segment_ms": 8000,
            "finalization": "streaming_finalize",
            "rollback_tokens": 5,
        },
        "quality_metrics": {
            "character_errors": errors,
            "reference_characters": 10,
            "hypothesis_characters": 10,
            "normalization": diagnostic["normalization"],
            "sample_coverage_gate": "pass",
            "segment_budget_gate": "pass",
            "segment_diagnostic": diagnostic,
        },
    }


def result(*sessions):
    return {
        "tool": "speechrail-asr-segment-diagnostic",
        "schema_version": 2,
        "diagnostic_schema_version": 1,
        "source_result_schema_version": 2,
        "evidence_mode": "real",
        "profile": "quality",
        "measurement_completed": True,
        "failure_kind": None,
        "sessions": list(sessions),
    }


def with_exact(payload, terminal="preview", preview="preview"):
    payload = copy.deepcopy(payload)
    payload["diagnostic_schema_version"] = 2
    for row in payload["sessions"]:
        diagnostic = row["quality_metrics"]["segment_diagnostic"]
        diagnostic.update(
            diagnostic_schema_version=2,
            hypothesis_exact_sha256=digest(terminal),
        )
        diagnostic["segments"][0].update(
            terminal_exact_sha256=digest(terminal),
            preview_exact_sha256=digest(preview) if preview is not None else None,
        )
    return payload


@pytest.mark.parametrize("text", ["preview.", " pre view ", "PREVIEW"])
def test_equal_cer_exact_output_change_is_visible(text):
    row = analyze_pair(
        with_exact(result(session())),
        with_exact(result(session()), terminal=text),
    )["comparisons"][0]
    assert row["output_changed"] is True
    assert row["final_normalized_changed"] is False
    assert row["final_exact_change"] == "changed"
    assert row["observation"] == "exact_only_final_changed"


def test_historical_normalized_equality_does_not_claim_exact_equality():
    row = analyze_pair(result(session()), result(session()))["comparisons"][0]
    assert row["output_changed"] is None
    assert row["final_exact_change"] == "not_observed"
    assert row["observation"] == "normalized_unchanged_exact_not_observed"


@pytest.mark.parametrize("baseline_preview,candidate_preview,state", [
    ("preview", "different", "changed"),
    ("preview", None, "missing_candidate"),
    (None, "preview", "missing_baseline"),
    (None, None, "missing_both"),
])
def test_preview_is_compared_independently_of_identical_final(
    baseline_preview, candidate_preview, state,
):
    row = analyze_pair(
        result(session(preview=baseline_preview)),
        result(session(preview=candidate_preview)),
    )["comparisons"][0]
    assert row["segment_comparisons"][0]["preview_normalized_change"] == state
    if state != "missing_both":
        assert row["observation"] == "preview_changed_with_same_normalized_final"


def test_exact_preview_change_and_repeat_inconsistency_are_visible():
    before = with_exact(result(session()))
    after = with_exact(result(session()), preview="preview.")
    for payload in (before, after):
        repeat = copy.deepcopy(payload["sessions"][0])
        repeat["repeat"] = 2
        payload["sessions"].append(repeat)
    after["sessions"][1]["quality_metrics"]["segment_diagnostic"]["segments"][0][
        "preview_exact_sha256"
    ] = digest("preview")

    report = analyze_pair(before, after)
    assert report["repeat_consistency"]["synthetic-case"] is False
    assert report["comparisons"][0]["segment_comparisons"][0][
        "preview_exact_change"
    ] == "changed"


def test_normalized_preview_inconsistency_is_visible_in_historical_repeats():
    before, after = result(session()), result(session())
    for payload in (before, after):
        repeat = copy.deepcopy(payload["sessions"][0])
        repeat["repeat"] = 2
        payload["sessions"].append(repeat)
    after["sessions"][1]["quality_metrics"]["segment_diagnostic"]["segments"][0][
        "preview_normalized_sha256"
    ] = digest("different")
    assert analyze_pair(before, after)["repeat_consistency"]["synthetic-case"] is False


def test_incomplete_new_schema_digest_is_rejected():
    after = with_exact(result(session()))
    del after["sessions"][0]["quality_metrics"]["segment_diagnostic"]["segments"][0][
        "terminal_exact_sha256"
    ]
    with pytest.raises(ValueError, match="digest"):
        analyze_pair(with_exact(result(session())), after)


def test_punctuation_class_delta_remains_visible_when_cer_is_equal():
    from examples.perf.asr_quality import punctuation_error_metrics
    before = with_exact(result(session()))
    after = with_exact(result(session()), terminal="preview.")
    for payload, text in ((before, "preview"), (after, "preview.")):
        payload["sessions"][0]["quality_metrics"]["punctuation_metrics"] = (
            punctuation_error_metrics(
                "preview.", text, gold_kind="human_punctuation_annotation",
            )
        )
        payload["sessions"][0]["quality_metrics"]["punctuation_reference_exact_sha256"] = (
            digest("preview.")
        )
    row = analyze_pair(before, after)["comparisons"][0]
    assert row["punctuation_comparison"]["status"] == "observed"
    assert row["punctuation_comparison"]["class_f1_delta"]["period"] == 1.0


@pytest.mark.parametrize("gold", ["preview?", None])
def test_different_or_missing_punctuation_gold_cannot_be_compared(gold):
    from examples.perf.asr_quality import punctuation_error_metrics
    before, after = result(session()), result(session())
    for payload, reference in ((before, "preview."), (after, gold)):
        quality = payload["sessions"][0]["quality_metrics"]
        quality["punctuation_metrics"] = punctuation_error_metrics(
            reference or "preview.", "preview.", gold_kind="human_punctuation_annotation",
        )
        if reference is not None:
            quality["punctuation_reference_exact_sha256"] = digest(reference)
    row = analyze_pair(before, after)["comparisons"][0]
    assert row["punctuation_comparison"]["status"] == "not_comparable"
    assert "class_f1_delta" not in row["punctuation_comparison"]


def test_equal_previews_and_extra_final_error_target_finalization():
    before = result(session())
    after = result(session(errors=2, terminal="changed"))

    report = analyze_pair(before, after)

    row = report["comparisons"][0]
    assert row["error_delta"] == 1
    assert row["observation"] == "final_changed_after_equal_previews"
    assert row["equal_preview_changed_final_segments"] == [0]
    assert report["triage_cases"] == [{
        "id": "synthetic-case",
        "role": "final_regression",
        "audio_seconds": 1.0,
    }]
    assert report["relative_character_error_gate"] == "fail"
    assert report["mechanism_attribution"] == "not_proven"
    assert report["acoustic_error_attribution"] == "not_observed"
    assert report["measurement_identity_gate"] == "not_evaluated"
    assert report["acceptance_gate"] == "not_evaluated"
    assert before == result(session())
    assert after == result(session(errors=2, terminal="changed"))


def test_selects_regression_gain_and_control_without_counting_repeats_as_cases():
    before = result(
        session("regression"),
        session("final-gain", errors=2),
        session("preview-gain", errors=3),
        session("control", errors=0),
    )
    after = result(
        session("regression", errors=2, terminal="changed"),
        session("final-gain", errors=0, terminal="improved"),
        session("preview-gain", errors=1, preview="new", terminal="new"),
        session("control", errors=0),
    )
    for payload in (before, after):
        extra = copy.deepcopy(payload["sessions"][0])
        extra["repeat"] = 2
        payload["sessions"].append(extra)

    report = analyze_pair(before, after)

    assert report["formal_requests_per_arm"] == 5
    assert report["independent_fixture_count"] == 4
    assert [row["role"] for row in report["triage_cases"]] == [
        "final_regression", "final_improvement", "preview_path_improvement",
        "zero_error_control",
    ]
    assert report["triage_audio_seconds_per_arm"] == 4.0
    assert report["triage_requests_per_arm"] == 4
    assert report["relative_character_error_gate"] == "fail"


def test_equal_cer_changed_output_is_not_hidden_by_aggregate_score():
    report = analyze_pair(
        result(session(errors=1)),
        result(session(errors=1, terminal="different")),
    )

    assert report["comparisons"][0]["output_changed"] is True
    assert report["comparisons"][0]["error_delta"] == 0
    assert report["triage_cases"][0]["role"] == "changed_equal_score"
    assert report["relative_character_error_gate"] == "pass"
    assert report["acceptance_gate"] == "not_evaluated"


@pytest.mark.parametrize("mutation", [
    lambda x: x.update(measurement_completed=False),
    lambda x: x.update(evidence_mode="fake"),
    lambda x: x.update(failure_kind="PartialFailure"),
    lambda x: x.update(schema_version=1),
    lambda x: x.update(profile="fast"),
    lambda x: x["sessions"][0].update(repeat=True),
    lambda x: x["sessions"][0].update(audio_seconds=float("nan")),
    lambda x: x["sessions"][0].update(audio_seconds=2.0),
    lambda x: x["sessions"][0]["effective_policy"].update(rollback_tokens=32),
    lambda x: x["sessions"][0]["quality_metrics"].update(sample_coverage_gate="unset"),
    lambda x: x["sessions"][0]["quality_metrics"].update(character_errors=True),
    lambda x: x["sessions"][0]["quality_metrics"]["segment_diagnostic"].update(
        reference_normalized_sha256=digest("different-reference")
    ),
    lambda x: x["sessions"][0]["quality_metrics"]["segment_diagnostic"].update(
        character_errors=3
    ),
    lambda x: x["sessions"][0]["quality_metrics"]["segment_diagnostic"]["segments"][0].update(
        end_sample=23_999
    ),
])
def test_invalid_or_unpaired_evidence_cannot_produce_a_valid_plan(mutation):
    after = result(session())
    mutation(after)

    with pytest.raises(ValueError):
        analyze_pair(result(session()), after)


def test_duplicate_or_differently_ordered_requests_are_rejected():
    first = session("first")
    second = session("second")
    with pytest.raises(ValueError, match="duplicate"):
        analyze_pair(result(first, first), result(first, first))
    with pytest.raises(ValueError, match="order"):
        analyze_pair(result(first, second), result(second, first))


@pytest.mark.parametrize("payload", [[], None, {"sessions": []}])
def test_non_object_and_incomplete_documents_fail_cleanly(payload):
    with pytest.raises(ValueError):
        analyze_pair(payload, result(session()))


def test_recorded_wire_digest_mismatch_is_rejected():
    before = result(session())
    after = result(session())
    before["sessions"][0]["wire_pcm_sha256"] = digest("audio-a")
    after["sessions"][0]["wire_pcm_sha256"] = digest("audio-b")

    with pytest.raises(ValueError, match="wire"):
        analyze_pair(before, after)


def test_different_segment_boundaries_do_not_get_final_only_localization():
    after = result(session(errors=2, terminal="changed"))
    diagnostic = after["sessions"][0]["quality_metrics"]["segment_diagnostic"]
    diagnostic["segments"] = [
        {**diagnostic["segments"][0], "end_sample": 12_000},
        {
            **diagnostic["segments"][0],
            "ordinal": 1,
            "start_sample": 12_000,
            "end_sample": 24_000,
        },
    ]

    row = analyze_pair(result(session()), after)["comparisons"][0]

    assert row["observation"] == "segment_boundaries_changed"
    assert row["equal_preview_changed_final_segments"] == []


def test_missing_preview_cannot_be_treated_as_equal_observed_preview():
    row = analyze_pair(
        result(session(preview=None)),
        result(session(errors=2, preview=None, terminal="changed")),
    )["comparisons"][0]

    assert row["observation"] == "preview_or_context_path_changed"
    assert row["equal_preview_changed_final_segments"] == []


def test_inconsistent_repeats_are_exposed_instead_of_majority_voting():
    before = result(session())
    after = result(session(errors=2, terminal="changed"))
    for payload in (before, after):
        extra = copy.deepcopy(payload["sessions"][0])
        extra["repeat"] = 2
        payload["sessions"].append(extra)
    after["sessions"][1] = {**session(), "repeat": 2}

    report = analyze_pair(before, after)

    assert report["repeat_consistency"]["synthetic-case"] is False
    assert report["relative_character_error_gate"] == "fail"


def test_output_does_not_copy_private_or_unknown_input_fields():
    before = result(session())
    after = result(session(errors=2, terminal="PRIVATE_HYPOTHESIS"))
    before["transcript"] = "PRIVATE_TRANSCRIPT"
    after["sessions"][0]["prompt"] = "PRIVATE_PROMPT"
    after["sessions"][0]["quality_metrics"]["reference"] = "PRIVATE_REFERENCE"

    encoded = json.dumps(analyze_pair(before, after))

    assert "PRIVATE" not in encoded


def test_cli_writes_only_new_output_and_does_not_invoke_inference(tmp_path):
    before = tmp_path / "before.json"
    after = tmp_path / "after.json"
    output = tmp_path / "analysis.json"
    before.write_text(json.dumps(result(session())))
    after.write_text(json.dumps(result(session(errors=2, terminal="changed"))))
    argv = ["--baseline", str(before), "--candidate", str(after), "--output", str(output)]

    assert main(argv) == 0
    saved = output.read_bytes()
    payload = json.loads(saved)
    assert payload["source_sha256"] == {
        "baseline": hashlib.sha256(before.read_bytes()).hexdigest(),
        "candidate": hashlib.sha256(after.read_bytes()).hexdigest(),
    }
    assert main(argv) == 2
    assert output.read_bytes() == saved
