"""Quality evidence must expose scores, never raw reference or ASR text."""

import json
import sys
from pathlib import Path
from typing import cast

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf.asr_quality import (
    character_error_metrics,
    punctuation_error_metrics,
)
from examples.perf.benchmark_http import HttpResponse, _fixture_request
from examples.perf.benchmark_manifest import Fixture


@pytest.mark.parametrize(
    "gold_kind",
    [["human_reading_prompt"], {"kind": "human_reading_prompt"}, True],
    ids=["list", "dict", "bool"],
)
def test_punctuation_metrics_rejects_non_string_gold_kind(gold_kind: object):
    with pytest.raises(ValueError, match="unsupported punctuation gold kind"):
        punctuation_error_metrics(
            "hello.",
            "hello.",
            gold_kind=cast(str | None, gold_kind),
        )


def test_identical_punctuation_only_texts_match_at_empty_lexical_anchor():
    result = punctuation_error_metrics(
        "!",
        "!",
        gold_kind="human_punctuation_annotation",
    )

    assert result["gold_mark_count"] == 1
    assert result["hypothesis_mark_count"] == 1
    assert result["true_positives"] == 1
    assert result["false_positives"] == 0
    assert result["false_negatives"] == 0
    assert result["f1"] == 1.0


def test_empty_lexical_anchor_does_not_merge_before_and_after_first():
    result = punctuation_error_metrics(
        "!a",
        "a!",
        gold_kind="human_punctuation_annotation",
    )

    assert result["true_positives"] == 0
    assert result["false_positives"] == 1
    assert result["false_negatives"] == 1
    assert result["f1"] == 0.0


def test_nfkc_ellipsis_is_ignored_while_a_real_period_still_scores():
    result = punctuation_error_metrics(
        "a\ufe19b.",
        "ab.",
        gold_kind="human_punctuation_annotation",
    )

    assert result["gold_mark_count"] == 1
    assert result["hypothesis_mark_count"] == 1
    assert result["true_positives"] == 1
    assert result["false_positives"] == 0
    assert result["false_negatives"] == 0
    assert result["f1"] == 1.0


@pytest.mark.parametrize(
    ("reference", "hypothesis", "errors"),
    [("甲乙丙", "甲丁丙", 1), ("甲乙丙", "甲丙", 1), ("甲乙丙", "甲乙乙丙", 1),
     ("A，１２！", "a12", 0), ("甲乙", "", 2)],
)
def test_cer_counts_substitution_deletion_insertion_and_empty(reference, hypothesis, errors):
    result = character_error_metrics(reference, hypothesis)
    assert result["character_errors"] == errors
    assert "reference_text" not in result and "text" not in result


def test_reference_is_scored_locally_and_never_injected_into_request(tmp_path: Path):
    path = tmp_path / "audio.wav"
    path.write_bytes(b"test audio container")
    reference = "distinctive reference"
    fixture = Fixture("sample", path, "asr", "en", "default", None, reference)
    requests = []

    def runner(method, url, body, headers):
        requests.append(body)
        return HttpResponse(200, json.dumps({"text": reference}).encode())

    result = _fixture_request(
        fixture, base_url="http://127.0.0.1:8201", runner=runner,
        clock=lambda: 1.0, duration=1.0, auth_headers={},
    )
    assert reference.encode() not in requests[0]
    assert reference not in json.dumps(result)
    assert result["quality_metrics"]["cer"] == 0
    assert result["quality_metrics"]["punctuation_gate"] == "unset"
    assert "punctuation_metrics" not in result["quality_metrics"]


def test_punctuation_metrics_align_supported_classes_after_unicode_normalization():
    result = punctuation_error_metrics(
        "你好，世界。你呢？",
        "你好,世界.你呢?",
        gold_kind="human_reading_prompt",
    )

    assert result["method"] == "normalized_lexical_character_alignment_v1"
    assert result["class_scope"] == ["comma", "period", "question", "exclamation"]
    assert result["gold_scope"] == (
        "reading_prompt_source_punctuation_not_audio_specific_annotation"
    )
    assert result["punctuation_gate"] == "unset"
    assert result["gold_mark_count"] == 3
    assert result["hypothesis_mark_count"] == 3
    assert result["true_positives"] == 3
    assert result["false_positives"] == 0
    assert result["false_negatives"] == 0
    assert result["precision"] == result["recall"] == result["f1"] == 1.0
    assert result["class_support"]["exclamation"]["gold_marks"] == 0
    assert result["class_support"]["question"]["gold_marks"] == 1


def test_wrong_or_shifted_punctuation_is_false_positive_and_false_negative():
    wrong_class = punctuation_error_metrics(
        "a,b.", "a.b?", gold_kind="human_punctuation_annotation",
    )
    shifted = punctuation_error_metrics(
        ".abc", "a.bc", gold_kind="human_punctuation_annotation",
    )

    assert (wrong_class["true_positives"], wrong_class["false_positives"],
            wrong_class["false_negatives"]) == (0, 2, 2)
    assert (shifted["true_positives"], shifted["false_positives"],
            shifted["false_negatives"]) == (0, 1, 1)


def test_ideographic_enumeration_comma_is_outside_the_comma_class():
    result = punctuation_error_metrics(
        "a、b", "a,b", gold_kind="human_punctuation_annotation",
    )

    assert result["class_support"]["comma"]["gold_marks"] == 0
    assert result["class_support"]["comma"]["hypothesis_marks"] == 1
    assert result["class_support"]["comma"]["true_positives"] == 0
    assert result["false_positives"] == 1
    assert result["false_negatives"] == 0
    assert result["f1"] == 0.0


def test_ellipsis_sequences_are_not_counted_as_periods():
    result = punctuation_error_metrics(
        "a...b.",
        "a…b.",
        gold_kind="human_punctuation_annotation",
    )

    assert result["gold_mark_count"] == 1
    assert result["hypothesis_mark_count"] == 1
    assert result["class_support"]["period"]["true_positives"] == 1
    assert result["class_support"]["period"]["false_positives"] == 0
    assert result["class_support"]["period"]["false_negatives"] == 0
    assert result["f1"] == 1.0


def test_punctuation_metrics_count_missing_added_duplicate_and_empty_hypothesis():
    missing = punctuation_error_metrics(
        "你好，世界。", "你好世界", gold_kind="human_punctuation_annotation",
    )
    added_and_duplicated = punctuation_error_metrics(
        "你好，世界。", "你好，，世界。？", gold_kind="human_punctuation_annotation",
    )
    empty = punctuation_error_metrics(
        "你好，世界。", "", gold_kind="human_punctuation_annotation",
    )

    assert (missing["true_positives"], missing["false_positives"],
            missing["false_negatives"]) == (0, 0, 2)
    assert missing["recall"] == 0.0
    assert missing["f1"] == 0.0
    assert added_and_duplicated["true_positives"] == 2
    assert added_and_duplicated["false_positives"] == 2
    assert added_and_duplicated["false_negatives"] == 0
    assert empty["true_positives"] == 0
    assert empty["false_negatives"] == 2
    assert empty["recall"] == 0.0
    assert empty["f1"] == 0.0


def test_punctuation_alignment_handles_lexical_errors_and_repeated_word_ties():
    word_error = punctuation_error_metrics(
        "good morning, friend.",
        "good bright morning, friend.",
        gold_kind="human_reading_prompt",
    )
    repeated_word = punctuation_error_metrics(
        "go go, now.",
        "go, now.",
        gold_kind="human_reading_prompt",
    )

    assert word_error["true_positives"] == 2
    assert word_error["false_positives"] == 0
    assert word_error["false_negatives"] == 0
    assert repeated_word["true_positives"] == 2
    assert repeated_word["false_positives"] == 0
    assert repeated_word["false_negatives"] == 0


def test_punctuation_without_gold_and_zero_gold_never_claim_a_pass():
    no_gold = punctuation_error_metrics(None, "hello, world.", gold_kind=None)
    zero_gold = punctuation_error_metrics(
        "hello world", "hello, world", gold_kind="human_reading_prompt",
    )
    zero_gold_and_zero_hypothesis = punctuation_error_metrics(
        "hello world", "hello world", gold_kind="human_reading_prompt",
    )

    assert no_gold["status"] == "unset"
    assert no_gold["reason"] == "gold_not_provided"
    assert no_gold["punctuation_gate"] == "unset"
    assert zero_gold["gold_mark_count"] == 0
    assert zero_gold["false_positives"] == 1
    assert zero_gold["f1"] == 0.0
    assert zero_gold_and_zero_hypothesis["gold_mark_count"] == 0
    assert zero_gold_and_zero_hypothesis["f1"] is None
    assert zero_gold_and_zero_hypothesis["punctuation_gate"] == "unset"


def test_punctuation_alignment_limit_unsets_only_punctuation_scores():
    long_reference = "a" * 1_500 + "."
    result = punctuation_error_metrics(
        long_reference,
        "a" * 1_500 + ".",
        gold_kind="human_punctuation_annotation",
    )
    cer = character_error_metrics(long_reference, long_reference)

    assert result["status"] == "unset"
    assert result["reason"] == "alignment_cell_limit"
    assert result["f1"] is None
    assert result["punctuation_gate"] == "unset"
    assert cer["cer"] == 0.0


def test_punctuation_raw_text_length_limit_unsets_without_echoing_gold():
    gold_text = "private-gold," + "," * 10_000
    hypothesis = "." * 10_000
    result = punctuation_error_metrics(
        gold_text,
        hypothesis,
        gold_kind="human_punctuation_annotation",
    )
    cer = character_error_metrics(gold_text, gold_text)

    assert result["status"] == "unset"
    assert result["reason"] == "raw_text_length_limit"
    assert result["gold_mark_count"] is None
    assert result["hypothesis_mark_count"] is None
    assert result["punctuation_gate"] == "unset"
    assert "private-gold" not in json.dumps(result)
    assert cer["cer"] == 0.0
