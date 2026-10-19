"""Human-constructed examples distinguish product, standard and oracle scores."""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest
from meeting_quality_metrics import score_meeting_quality


def policy() -> dict:
    return json.loads(
        (
            Path(__file__).resolve().parents[1] / "examples/perf/meeting-evaluation-policy.json"
        ).read_text()
    )


def span(start, end, speaker, text=None):
    result = {"start": start, "end": end, "speaker": speaker}
    if text is not None:
        result["text"] = text
    return result


def score(ref, hyp, duration=10, override=None):
    return score_meeting_quality(
        [{k: v for k, v in r.items() if k != "text"} for r in ref],
        [{k: v for k, v in r.items() if k != "text"} for r in hyp],
        reference_text=ref,
        hypothesis_text=hyp,
        duration=duration,
        policy=override or policy(),
    )


def test_overlap_contributes_to_speaker_time_denominator():
    result = score([span(0, 1, "R1"), span(0, 1, "R2")], [span(0, 1, "S1")])
    product = result["product_all_regions"]
    assert product["reference_speaker_seconds"] == 2
    assert product["correct_speaker_seconds"] == 1
    assert product["recall"] == 0.5
    assert product["quality_gate"] == "fail"
    assert result["legacy_nonoverlap"]["known_coverage"] is None


def test_extra_speaker_and_reference_silence_reduce_precision():
    ref = [span(0, 1, "R1")]
    hyp = [span(0, 1, "S1"), span(0, 2, "S2")]
    product = score(ref, hyp)["product_all_regions"]
    assert product["recall"] == 1
    assert product["hypothesis_speaker_seconds"] == 3
    assert product["precision"] == pytest.approx(1 / 3)


def test_unknown_and_empty_reference_cannot_pass():
    product = score([span(0, 1, "R1")], [span(0, 1, "unknown")])["product_all_regions"]
    assert product["correct_speaker_seconds"] == 0
    assert product["recall"] == 0
    assert product["precision"] is None
    assert product["quality_gate"] == "fail"
    empty = score([], [span(0, 1, "S1")])["product_all_regions"]
    assert empty["recall"] is None
    assert empty["quality_gate"] == "not_observed"


def test_subsecond_interjection_stays_in_denominator():
    product = score([span(0, 5, "R1"), span(4, 4.1, "R2")], [span(0, 5, "S1")])[
        "product_all_regions"
    ]
    assert product["reference_speaker_seconds"] == pytest.approx(5.1)
    assert product["recall"] == pytest.approx(5 / 5.1)
    assert product["top_four_min_recall"] == 0
    assert product["quality_gate"] == "fail"


def test_one_session_mapping_penalizes_late_identity_swap():
    ref = [span(0, 2, "R1"), span(2, 4, "R2"), span(4, 6, "R1"), span(6, 8, "R2")]
    hyp = [span(0, 2, "S1"), span(2, 4, "S2"), span(4, 6, "S2"), span(6, 8, "S1")]
    assert score(ref, hyp)["product_all_regions"]["recall"] == 0.5


def test_duplicate_same_speaker_spans_do_not_duplicate_speaker_time():
    product = score([span(0, 1, "R1"), span(0.5, 1, "R1")], [span(0, 1, "S1"), span(0, 1, "S1")])[
        "product_all_regions"
    ]
    assert product["reference_speaker_seconds"] == 1
    assert product["hypothesis_speaker_seconds"] == 1
    assert product["quality_gate"] == "pass"


def test_temporal_oracle_is_not_reported_as_dicp():
    result = score(
        [span(0, 1, "R1", "red"), span(2, 3, "R2", "blue")],
        [span(0, 1, "S1", "blue"), span(2, 3, "S1", "red")],
    )
    standard = result["standard_metrics"]
    assert standard["greedy_di_cp_wer"]["algorithm"] == "meeteval.greedy_di_cp"
    assert "temporal_oracle" not in json.dumps(standard)
    assert result["diagnostics"]["temporal_oracle"]["certification_eligible"] is False


def test_eight_speaker_cp_matches_reference_assignment():
    ref = [span(i, i + 0.5, f"R{i}", f"word{i}") for i in range(8)]
    hyp = [span(i, i + 0.5, f"S{7 - i}", f"word{i}") for i in range(8)]
    standard = score(ref, hyp)["standard_metrics"]
    assert standard["cp_wer"]["error_rate"] == 0
    assert standard["cp_cer"]["error_rate"] == 0
    assert standard["cp_wer"]["reference_tokens"] == 8


def test_time_constraint_changes_tcp_without_changing_cp():
    ref = [span(0, 1, "R1", "hello world")]
    hyp = [span(8, 9, "S1", "hello world")]
    standard = score(ref, hyp)["standard_metrics"]
    assert standard["cp_wer"]["error_rate"] == 0
    assert standard["tcp_wer"]["error_rate"] > 0


def test_standard_cp_keeps_unknown_text_but_product_rejects_unknown_identity():
    result = score([span(0, 1, "R1", "你好")], [span(0, 1, "unknown", "你好")])
    assert result["standard_metrics"]["cp_cer"]["error_rate"] == 0
    assert result["diagnostics"]["unknown_text_fraction"] == 1
    assert result["product_all_regions"]["recall"] == 0


def test_empty_text_denominator_is_not_perfect():
    result = score([span(0, 1, "R1", "")], [span(0, 1, "S1", "extra")])
    metric = result["standard_metrics"]["cp_cer"]
    assert metric["error_rate"] is None
    assert metric["availability"] == "not_observed"


def test_missing_any_text_reference_does_not_score_partial_text():
    result = score([span(0, 1, "R1", "a"), span(1, 2, "R1")], [span(0, 1, "S1", "a")])
    assert result["standard_metrics"]["cp_cer"]["availability"] == "not_observed"


@pytest.mark.parametrize(
    "field",
    [
        "speaker_time_recall_min",
        "speaker_time_precision_min",
        "top_four_recall_min",
        "other_recall_min",
        "other_min_duration_seconds",
        "scorer_versions",
        "tokenization",
        "collar_seconds",
        "skip_overlap",
        "tcp_collar_seconds",
        "legacy_nonoverlap",
    ],
)
def test_policy_never_silently_fills_missing_production_defaults(field):
    incomplete = copy.deepcopy(policy())
    del incomplete[field]
    with pytest.raises(ValueError, match="policy"):
        score_meeting_quality(
            [], [], reference_text=None, hypothesis_text=None, duration=1, policy=incomplete
        )


@pytest.mark.parametrize(
    "bad",
    [
        span(0, 1, ""),
        span(0, 1, None),
        span(-1, 1, "R1"),
        span(0, float("nan"), "R1"),
        span(0, 12, "R1"),
    ],
)
def test_invalid_intervals_fail_without_scoring(bad):
    with pytest.raises(ValueError):
        score([bad], [])


def test_reference_unknown_is_missing_ground_truth():
    with pytest.raises(ValueError, match="reference"):
        score([span(0, 1, "unknown")], [])


def test_group_bootstrap_does_not_count_repeated_windows_as_meetings():
    from meeting_quality_metrics import paired_meeting_interval

    baseline = {"M1": [0.2], "M2": [0.4]}
    candidate = {"M1": [0.1], "M2": [0.2]}
    once = paired_meeting_interval(baseline, candidate, policy=policy())
    repeated = paired_meeting_interval(
        {"M1": [0.2] * 9, "M2": [0.4]}, {"M1": [0.1] * 9, "M2": [0.2]}, policy=policy()
    )
    assert once == repeated
    assert once["groups"] == 2
    assert once["difference"] == pytest.approx(-0.15)
    assert once["upper"] == pytest.approx(-0.1)
    assert once["seed"] == 1717 and once["draws"] == 10000


def test_missing_pair_or_nonfinite_result_never_passes():
    from meeting_quality_metrics import paired_meeting_interval

    with pytest.raises(ValueError, match="same"):
        paired_meeting_interval({"M1": [0]}, {"M2": [0]}, policy=policy())
    with pytest.raises(ValueError):
        paired_meeting_interval({"M1": [0]}, {"M1": [float("nan")]}, policy=policy())
    one = paired_meeting_interval({"M1": [0]}, {"M1": [0]}, policy=policy())
    assert one["upper"] is None


def test_nodegradation_requires_point_and_paired_upper_bound():
    from meeting_quality_metrics import nondegradation_gate

    # Negative mean is insufficient when a plausible paired difference is positive.
    baseline = {"der": {"A": [0.2], "B": [0.2]}, "cp_cer": {"A": [0.2], "B": [0.2]}}
    candidate = {"der": {"A": [0.0], "B": [0.3]}, "cp_cer": {"A": [0.1], "B": [0.1]}}
    result = nondegradation_gate(baseline, candidate, policy=policy())
    assert result["metrics"]["der"]["difference"] < 0
    assert result["metrics"]["der"]["upper"] > 0
    assert result["quality_gate"] == "fail"


def test_interval_crossing_zero_is_not_automatically_equivalent():
    from meeting_quality_metrics import allows_latency_tiebreaker, paired_meeting_interval

    diff = paired_meeting_interval(
        {"A": [0.1], "B": [0.1]}, {"A": [0.08], "B": [0.12]}, policy=policy()
    )
    assert diff["lower"] < 0 < diff["upper"]
    assert allows_latency_tiebreaker(diff, policy=policy()) is False


def test_aggregate_preserves_missing_strata_and_per_person_failure():
    from meeting_quality_metrics import summarize_meeting_quality

    good = score([span(0, 1, "R1")], [span(0, 1, "S1")])
    rows = [
        {"fixture_id": f"F{i}", "source_meeting_id": f"M{i}", "speakers_count": 1, "quality": good}
        for i in range(6)
    ]
    complete = summarize_meeting_quality(rows, required_strata=(1,), policy=policy())
    assert complete["quality_gate"] == "pass"
    missing = summarize_meeting_quality(rows, required_strata=(1, 2), policy=policy())
    assert missing["quality_gate"] == "fail"
    assert missing["certified_max_speakers"] is None
    bad = score([span(0, 5, "R1"), span(4, 4.1, "R2")], [span(0, 5, "S1")])
    rows[0] = {**rows[0], "quality": bad}
    assert (
        summarize_meeting_quality(rows, required_strata=(1,), policy=policy())["quality_gate"]
        == "fail"
    )


def test_single_meeting_repetitions_do_not_create_certification_evidence():
    from meeting_quality_metrics import summarize_meeting_quality

    good = score([span(0, 1, "R1")], [span(0, 1, "S1")])
    rows = [
        {"fixture_id": f"F{i}", "source_meeting_id": "M1", "speakers_count": 1, "quality": good}
        for i in range(24)
    ]
    result = summarize_meeting_quality(rows, required_strata=(1,), policy=policy())
    assert result["strata"]["1"]["independent_groups"] == 1
    assert result["quality_gate"] == "fail"


def test_duplicate_fixture_cannot_be_relabelled_as_a_repeat():
    from meeting_quality_metrics import summarize_meeting_quality

    good = score([span(0, 1, "R1")], [span(0, 1, "S1")])
    row = {"fixture_id": "F0", "source_meeting_id": "M0", "speakers_count": 1, "quality": good}
    with pytest.raises(ValueError, match="duplicate fixture"):
        summarize_meeting_quality([row, row], required_strata=(1,), policy=policy())


def test_many_fragments_cannot_downweight_a_sources_pooled_precision_failure():
    from meeting_quality_metrics import summarize_meeting_quality

    reference = [span(0, 0.5, "R1"), span(0.25, 0.5, "R2")]
    hypothesis = [span(0, 0.5, "S1"), span(0.25, 0.5, "S2")]
    bad = score(reference, [*hypothesis, span(0.25, 0.25 + 0.75 * (1 / 0.94 - 1), "S3")])
    good = score(reference, hypothesis)
    assert bad["legacy_nonoverlap"]["quality_gate"] == "pass"
    assert bad["product_all_regions"]["participant_gate"] == "pass"
    rows = [
        {"fixture_id": f"fragment-{i}", "source_meeting_id": "M0",
         "speakers_count": 2, "quality": bad}
        for i in range(1000)
    ] + [
        {"fixture_id": f"good-{i}", "source_meeting_id": f"M{i}",
         "speakers_count": 2, "quality": good}
        for i in range(1, 6)
    ]
    result = summarize_meeting_quality(rows, required_strata=(1, 2), policy=policy())["strata"]["2"]
    assert result["decision"] == "point_failed"
    assert result["pooled_precision"]["value"] == pytest.approx(1005 / (1000 / 0.94 + 5))


def test_activity_and_text_are_independent_observations():
    activity_ref = [span(0, 1, "R1")]
    activity_hyp = [span(0, 1, "S1")]
    result = score_meeting_quality(
        activity_ref, activity_hyp,
        reference_text=[span(0, 2, "R1", "hello world")],
        hypothesis_text=[span(8, 9, "S1", "hello world")],
        duration=10, policy=policy(),
    )
    assert result["standard_metrics"]["diarization"]["der"] == 0
    assert result["product_all_regions"]["precision"] == 1
    assert result["standard_metrics"]["cp_wer"]["error_rate"] == 0
    assert result["standard_metrics"]["tcp_wer"]["error_rate"] > 0
    wrong_activity = score_meeting_quality(
        activity_ref, [span(8, 9, "S1")],
        reference_text=[span(0, 2, "R1", "hello world")],
        hypothesis_text=[span(8, 9, "S1", "hello world")],
        duration=10, policy=policy(),
    )
    assert wrong_activity["product_all_regions"]["recall"] == 0
    assert wrong_activity["standard_metrics"]["cp_wer"] == result["standard_metrics"]["cp_wer"]


def test_absent_text_is_not_inferred_from_activity():
    result = score_meeting_quality(
        [span(0, 1, "R1")], [span(0, 1, "S1")],
        reference_text=None, hypothesis_text=None, duration=1, policy=policy(),
    )
    assert result["standard_metrics"]["cp_cer"]["availability"] == "not_observed"
    assert result["diagnostics"]["unknown_text_fraction"] is None
    with pytest.raises(ValueError, match="text"):
        score_meeting_quality(
            [span(0, 1, "R1", "a")], [span(0, 1, "S1")],
            reference_text=None, hypothesis_text=None, duration=1, policy=policy(),
        )
    with pytest.raises(ValueError, match="text"):
        score_meeting_quality(
            [span(0, 1, "R1")], [span(0, 1, "S1")],
            reference_text=[span(0, 1, "R1", "a")], hypothesis_text=None,
            duration=1, policy=policy(),
        )


def overlap_summary_rows(extra_seconds):
    # Ghost activity only in overlap: legacy nonoverlap still passes. This
    # isolates the additional all-region precision rule from the retained gate.
    ref = [span(0, 2, "R1"), span(1, 2, "R2")]
    hyp = [span(0, 2, "S1"), span(1, 2, "S2")]
    good = score(ref, hyp)
    bad_precision = score(ref, [*hyp, span(1, 1 + extra_seconds, "S3")])
    assert bad_precision["legacy_nonoverlap"]["quality_gate"] == "pass"
    one = score([span(0, 1, "R1")], [span(0, 1, "S1")])
    rows = [
        {"fixture_id": f"F{count}_{i}", "source_meeting_id": f"M{count}_{i}",
         "speakers_count": count,
         "quality": one if count == 1 else good}
        for count in (1, 2) for i in range(6)
    ]
    rows[-1]["quality"] = bad_precision
    return rows, bad_precision


def test_stratum_overall_gate_does_not_add_a_per_meeting_precision_gate():
    from meeting_quality_metrics import summarize_meeting_quality

    rows, bad_precision = overlap_summary_rows(0.18)
    assert bad_precision["product_all_regions"]["precision"] < 0.95
    result = summarize_meeting_quality(rows, required_strata=(1, 2), policy=policy())
    assert result["quality_gate"] == "pass"
    assert result["decision"] == "pass"


def test_point_failure_and_insufficient_evidence_require_different_actions():
    from meeting_quality_metrics import summarize_meeting_quality

    rows, bad_precision = overlap_summary_rows(0.6)
    result = summarize_meeting_quality(rows, required_strata=(1, 2), policy=policy())
    assert result["quality_gate"] == "fail"
    assert result["strata"]["2"]["pooled_precision"]["value"] > 0.95
    assert result["decision"] == "insufficient_evidence"
    rows = [dict(r, quality=bad_precision) if r["speakers_count"] == 2 else r for r in rows]
    result = summarize_meeting_quality(rows, required_strata=(1, 2), policy=policy())
    assert result["decision"] == "point_failed"


def test_legacy_score_schema_cannot_be_pooled_after_input_semantics_change():
    from meeting_quality_metrics import summarize_meeting_quality

    old = score([span(0, 1, "R1")], [span(0, 1, "S1")])
    old["schema_version"] = 2
    with pytest.raises(ValueError, match="schema"):
        summarize_meeting_quality(
            [{"fixture_id": "F1", "source_meeting_id": "M1", "speakers_count": 1, "quality": old}],
            required_strata=(1,), policy=policy(),
        )


def test_nondegradation_distinguishes_insufficient_interval_from_worse_point():
    from meeting_quality_metrics import nondegradation_gate

    baseline = {name: {"A": [0.2], "B": [0.2]} for name in ("der", "cp_cer")}
    candidate = {name: {"A": [0.0], "B": [0.3]} for name in ("der", "cp_cer")}
    result = nondegradation_gate(baseline, candidate, policy=policy())
    assert result["decision"] == "insufficient_evidence"
    worse = {name: {"A": [0.3], "B": [0.3]} for name in ("der", "cp_cer")}
    assert nondegradation_gate(baseline, worse, policy=policy())["decision"] == "point_failed"
    assert nondegradation_gate(baseline, baseline, policy=policy())["decision"] == "pass"


def test_missing_strata_cannot_be_treated_as_expandable_confidence():
    from meeting_quality_metrics import summarize_meeting_quality

    result = summarize_meeting_quality([], required_strata=(1,), policy=policy())
    assert result["decision"] == "not_observed"
    assert result["strata"]["1"]["decision"] == "not_observed"


def test_observed_total_miss_is_point_failure_not_missing_observation():
    from meeting_quality_metrics import summarize_meeting_quality

    missed = score([span(0, 1, "R1", "a")], [])
    assert missed["standard_metrics"]["cp_cer"]["error_rate"] == 1
    rows = [
        {"fixture_id": f"F{i}", "source_meeting_id": f"M{i}",
         "speakers_count": 1, "quality": missed}
        for i in range(6)
    ]
    result = summarize_meeting_quality(rows, required_strata=(1,), policy=policy())
    assert result["decision"] == "point_failed"
    assert result["strata"]["1"]["availability"] == "observed"


@pytest.mark.parametrize("fault", ["missing", "weight", "quantile"])
def test_latency_sampling_is_required_and_cannot_change_after_policy_freeze(fault):
    value = policy()
    if fault == "missing":
        value["latency"].pop("sampling", None)
    elif fault == "weight":
        value["latency"]["sampling"]["stable_weight"] = "unit_count"
    else:
        value["latency"]["sampling"]["quantile"] = "linear_interpolation"
    with pytest.raises(ValueError, match="latency"):
        score([span(0, 1, "R1")], [span(0, 1, "S1")], override=value)


def test_relative_sampling_is_registered_with_explicit_owned_completion_boundaries():
    from meeting_latency_policy import latency_policy

    registered = latency_policy()["relative_sampling"]
    assert registered["origin"] == "last_source_sample_target"
    assert registered["asr_completion"] == "host_callback_return_including_owned_cleanup"
    assert registered["dia_single_completion"] == "host_callback_and_report_validation_joined"
    assert registered["dia_joint_completion"] == "actual_dia_scope_closed_not_relay"
    value = policy()
    value["latency"].pop("relative_sampling")
    with pytest.raises(ValueError, match="latency"):
        score([span(0, 1, "R1")], [span(0, 1, "S1")], override=value)
