"""Synthetic independent-reference counterexamples for retrospective quality."""

import pytest
from examples.perf.asr_revision_trace import score_revision_trace


def human(**fields):
    return {"kind": "independent_human_annotation", **fields}


def observation(at, text, *, sealed=False, mapping=None):
    result = {"at_seconds": at, "text": text, "sealed": sealed}
    if mapping is not None:
        result["reference_token_map"] = mapping
    return result


def test_correct_to_wrong_counts_reference_tokens_and_transitions():
    result = score_revision_trace(
        "we can go",
        [observation(1, "we can", mapping=[0, 1]),
         observation(2, "we cannot", mapping=[0, 1]),
         observation(3, "we can go", sealed=True, mapping=[0, 1, 2])],
        annotation=human(correspondence_provenance="human_reviewed_trace"), clock="api_received",
    )
    assert result["correct_to_wrong"] == {
        "reference_tokens": 3, "ever_correct_tokens": 3,
        "affected_tokens": 1, "transition_count": 1, "rate": 1 / 3,
    }
    assert result["ui_submission_latency"] == "not_observed"
    assert result["churn"]["rewritten_tokens"] == 2
    assert result["churn"]["rewrite_age_seconds"]["p95"] == 1


def test_pure_tail_append_has_no_churn_and_repeated_snapshots_do_not_duplicate():
    result = score_revision_trace(
        "你好世界", [observation(1, "你好"), observation(2, "你好"),
                   observation(3, "你好世界", sealed=True)],
        annotation=human(), clock="api_received",
    )
    assert result["churn"]["rewritten_tokens"] == 0
    assert result["churn"]["rewrite_age_seconds"]["count"] == 0
    assert result["correct_to_wrong"] == "not_observed"


def test_partial_prefix_does_not_match_a_future_repeated_word():
    annotation = human(correspondence_provenance="human_reviewed_trace",
                      timing_provenance="human_reviewed_audio", token_timings=[
        {"start": 0, "end": 3, "audio_start_seconds": 0, "audio_end_seconds": 1},
        {"start": 4, "end": 6, "audio_start_seconds": 1, "audio_end_seconds": 2},
        {"start": 7, "end": 10, "audio_start_seconds": 2, "audio_end_seconds": 3},
    ])
    result = score_revision_trace(
        "yes no yes", [observation(1.5, "yes", mapping=[0]),
                       observation(2.5, "yes no", mapping=[0, 1]),
                       observation(3.5, "yes no yes", sealed=True, mapping=[0, 1, 2])],
        annotation=annotation, clock="app_ui_submission",
    )
    assert result["correct_to_wrong"]["transition_count"] == 0
    assert result["ui_submission_latency"]["first_display_seconds"]["p95"] == .5


def test_word_latency_requires_human_audio_timing_and_actual_ui_clock():
    annotation = human(
        correspondence_provenance="human_reviewed_trace",
        timing_provenance="human_reviewed_audio",
        token_timings=[
            {"start": 0, "end": 5, "audio_start_seconds": 0, "audio_end_seconds": 1},
            {"start": 6, "end": 11, "audio_start_seconds": 1, "audio_end_seconds": 2},
        ],
    )
    trace = [observation(1.5, "hello", mapping=[0]),
             observation(3, "hello world", sealed=True, mapping=[0, 1])]
    result = score_revision_trace("hello world", trace, annotation=annotation,
                                  clock="app_ui_submission")
    latency = result["ui_submission_latency"]
    assert latency["reference_tokens"] == latency["first_display_seconds"]["count"] == 2
    assert latency["first_display_seconds"]["p95"] == 1
    assert latency["last_change_to_seal_seconds"]["count"] == 2
    assert score_revision_trace("hello world", trace, annotation=annotation,
                                clock="api_received")["ui_submission_latency"] == "not_observed"


def test_missing_words_stay_in_denominator_without_invented_latency():
    annotation = human(correspondence_provenance="human_reviewed_trace",
                      timing_provenance="human_reviewed_audio", token_timings=[
        {"start": 0, "end": 2, "audio_start_seconds": 0, "audio_end_seconds": 1},
        {"start": 3, "end": 5, "audio_start_seconds": 1, "audio_end_seconds": 2},
    ])
    result = score_revision_trace("go no", [observation(3, "go", sealed=True, mapping=[0])],
                                  annotation=annotation, clock="app_ui_submission")
    assert result["ui_submission_latency"]["reference_tokens"] == 2
    assert result["ui_submission_latency"]["first_display_seconds"]["count"] == 1
    assert result["ui_submission_latency"]["unobserved_tokens"] == 1


@pytest.mark.parametrize("patch", [
    {"timing_provenance": "automatic_alignment"},
    {"token_timings": []},
    {"token_timings": [{"start": 0, "end": 1, "audio_start_seconds": 0,
                        "audio_end_seconds": 1}]},
    {"token_timings": [{"start": 0, "end": 2, "audio_start_seconds": False,
                        "audio_end_seconds": 1}]},
])
def test_timing_annotation_must_be_complete_and_independent(patch):
    annotation = human(timing_provenance="human_reviewed_audio", token_timings=[
        {"start": 0, "end": 2, "audio_start_seconds": 0, "audio_end_seconds": 1},
    ])
    annotation.update(patch)
    with pytest.raises(ValueError):
        score_revision_trace("go", [observation(3, "go", sealed=True)],
                             annotation=annotation, clock="app_ui_submission")


@pytest.mark.parametrize("trace", [
    [], [observation(1, "go")],
    [observation(2, "go"), observation(1, "go", sealed=True)],
    [observation(float("nan"), "go", sealed=True)],
    [observation(True, "go", sealed=True)],
    [observation(1, "go", sealed=True), observation(2, "go", sealed=True)],
])
def test_invalid_or_incomplete_trace_is_rejected(trace):
    with pytest.raises(ValueError):
        score_revision_trace("go", trace, annotation=human(), clock="app_ui_submission")


def test_no_human_truth_means_no_correctness_or_latency_claim():
    result = score_revision_trace("privatecanary", [observation(1, "privatecanary", sealed=True)],
                                  annotation=None, clock="api_received")
    assert result["correct_to_wrong"] == result["ui_submission_latency"] == "not_observed"
    assert "privatecanary" not in repr(result)


def test_alignment_budget_refuses_large_trace_without_partial_quality_score():
    result = score_revision_trace("go", [observation(1, "go"), observation(2, "no", sealed=True)],
                                  annotation=human(), clock="api_received", cell_budget=1)
    assert result["correct_to_wrong"] == "not_observed"
    assert result["trace_scoring"] == {"status": "not_observed", "reason": "cell_budget"}


def test_long_pure_tail_append_does_not_spend_dynamic_alignment_budget():
    result = score_revision_trace(
        " ".join(["go"] * 700),
        [observation(n, " ".join(["go"] * n), sealed=n == 700, mapping=list(range(n)))
         for n in range(1, 701)],
        annotation=human(correspondence_provenance="human_reviewed_trace"), clock="api_received",
    )
    assert result["trace_scoring"]["status"] == "observed"
    assert result["correct_to_wrong"]["ever_correct_tokens"] == 700
    assert result["churn"]["rewritten_tokens"] == 0


def test_repeated_tail_append_does_not_become_inline_churn():
    result = score_revision_trace("yes yes", [observation(1, "yes"),
                                 observation(2, "yes yes", sealed=True)],
                                 annotation=None, clock="api_received")
    assert result["churn"]["inline_inserted_tokens"] == 0
    assert result["churn"]["rewritten_tokens"] == 0


def test_ambiguous_repeated_words_are_not_guessed_without_human_correspondence():
    result = score_revision_trace(
        "yes no yes", [observation(1.5, "yes yes"), observation(2.5, "yes no"),
                       observation(3.5, "yes no yes", sealed=True)],
        annotation=human(), clock="app_ui_submission",
    )
    assert result["correct_to_wrong"] == result["ui_submission_latency"] == "not_observed"
    assert result["trace_scoring"]["clock_provenance"] == "caller_declared_unverified"
    assert result["trace_scoring"]["production_gate"] == "unset"


def test_reverse_word_times_are_rejected_even_with_human_provenance():
    with pytest.raises(ValueError, match="monotonic"):
        score_revision_trace("go no", [observation(3.5, "go no", sealed=True)],
            clock="app_ui_submission", annotation=human(
                timing_provenance="human_reviewed_audio", token_timings=[
                    {"start": 0, "end": 2, "audio_start_seconds": 2, "audio_end_seconds": 3},
                    {"start": 3, "end": 5, "audio_start_seconds": 0, "audio_end_seconds": 1},
                ]))


@pytest.mark.parametrize("mapping", [[0, 0], [1, 0], [True, 1], [0, 2], [0], "0,1"])
def test_invalid_human_correspondence_is_rejected(mapping):
    with pytest.raises(ValueError):
        score_revision_trace("go no", [observation(3, "go no", sealed=True, mapping=mapping)],
            annotation=human(correspondence_provenance="human_reviewed_trace"),
            clock="app_ui_submission")
