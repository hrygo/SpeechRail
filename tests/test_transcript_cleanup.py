"""Repetition collapse removes a fault, never a speaker's word choice.

These tests pin the threshold (5 rhetorical repeats stay, 6 collapse), the two
passes (one token in a row, one substring in a row), the boundaries (no
merging across a passage, no change when disabled) and the self-consistency a
transcript result must keep (text, segments and words shrink together, because
``format_diarized`` rebuilds the text out of the segments).
"""

from __future__ import annotations

import time

import pytest

from speechrail.domain.contracts import (
    TranscriptResult,
    TranscriptSegment,
    TranscriptWord,
)
from speechrail.domain.transcript_cleanup import (
    DEFAULT_MIN_RUN,
    CollapseResult,
    collapse_repetitions,
    collapse_transcript_result,
)


def _result(
    text: str,
    *,
    segments: tuple[TranscriptSegment, ...] = (),
    words: tuple[TranscriptWord, ...] = (),
) -> TranscriptResult:
    return TranscriptResult(
        request_id="req-1",
        model_id="speechrail/qwen3-asr-1.7b",
        text=text,
        duration_ms=1_000,
        segments=segments,
        words=words,
    )


# --- threshold ------------------------------------------------------------


def test_five_repeats_survive_and_six_collapse() -> None:
    assert collapse_repetitions("不不不不不").text == "不不不不不"
    assert collapse_repetitions("不不不不不不").text == "不"
    assert collapse_repetitions("abc" * 5).text == "abc" * 5
    assert collapse_repetitions("abc" * 6).text == "abc"
    assert collapse_repetitions("OK OK OK OK OK").text == "OK OK OK OK OK"
    assert collapse_repetitions("OK OK OK OK OK OK").text == "OK"


def test_normal_speech_is_byte_for_byte_identical() -> None:
    text = (
        "我们今天讨论三个议题：第一是预算，第二是排期，第三是风险。"
        "预算部分需要财务确认，排期部分我已经和产品对了。"
        "There are exactly two open questions and neither blocks us."
    )
    result = collapse_repetitions(text)
    assert result == CollapseResult(text=text, collapsed_runs=0, collapsed_chars=0)


def test_a_doubled_word_is_not_a_run() -> None:
    # A threshold of 1 makes every character a run, so it is refused outright;
    # 2 is the floor, and at 2 a doubled word genuinely is a run.
    with pytest.raises(ValueError):
        collapse_repetitions("", min_run=1)
    assert collapse_repetitions("that that is fine", min_run=2).text == "that is fine"
    assert collapse_repetitions("fine that that", min_run=2).text == "fine that"


# --- the two passes -------------------------------------------------------


def test_word_pass_collapses_one_token_at_a_time() -> None:
    # CJK has no spaces, so a decoder loop there is a run of single ideographs.
    result = collapse_repetitions("嗯嗯" * 6)
    assert result.text == "嗯"
    assert (result.collapsed_runs, result.collapsed_chars) == (1, 11)
    # Mixed script, case-insensitive on Latin tokens: six of them collapse to
    # the first spelling, five survive.
    assert collapse_repetitions("the The THE the The THE").text == "the"
    assert collapse_repetitions("the The THE the The").text == "the The THE the The"


def test_substring_pass_collapses_a_looping_phrase() -> None:
    sentence = "我说明一下这个事情"
    assert collapse_repetitions(sentence * 8).text == sentence
    assert collapse_repetitions("hello world " * 5 + "hello world").text == "hello world"
    assert collapse_repetitions("OK OK OK OK OK OK").text == "OK"


def test_a_run_cut_off_by_the_end_of_audio_still_collapses() -> None:
    # A runaway almost always ends where the audio did, so the last copy is
    # routinely a prefix of the unit rather than a whole one.
    assert collapse_repetitions("abc" * 5 + "ab").text == "abc"
    assert collapse_repetitions("abc" * 4 + "ab").text == "abc" * 4 + "ab"


def test_one_whole_copy_plus_a_prefix_is_not_a_run() -> None:
    # "that" is one copy of "that", not a copy of "tha" plus a fragment; a
    # decaying tail only counts when the run was already almost there.
    assert collapse_repetitions("fine that", min_run=2).text == "fine that"
    assert collapse_repetitions("fine that", min_run=6).text == "fine that"
    assert collapse_repetitions("好的").text == "好的"


def test_a_collapse_exposes_a_nested_run() -> None:
    assert collapse_repetitions("还是这个" * 6 + "还是这个"[:2]).text == "还是这个"


# --- boundaries -----------------------------------------------------------


def test_a_run_never_merges_across_a_passage() -> None:
    text = "\n".join(["section 3"] * 6)
    assert collapse_repetitions(text).text == text
    single = "section 3" * 6
    assert collapse_repetitions(single).text == "section 3"


def test_a_run_stops_at_a_real_boundary_not_at_an_arbitrary_cost_cap() -> None:
    long_run = "预算" * 3_000
    assert collapse_repetitions(long_run).text == "预算"


# --- whole results --------------------------------------------------------


def test_a_result_is_returned_untouched_when_nothing_loopened() -> None:
    result = _result("今天天气很好", words=(TranscriptWord(word="今天", start_ms=0, end_ms=1),))
    assert collapse_transcript_result(result) is result


def test_disabled_returns_the_same_object_not_a_copy() -> None:
    result = _result("不不不不不不")
    assert collapse_transcript_result(result, enabled=False) is result


def test_text_segments_and_words_shrink_together() -> None:
    # The loop lives inside one segment, so the segment text and the top-level
    # text must both lose it, and the run count must be reported once.
    looped = TranscriptSegment(id=0, start_ms=0, end_ms=5_000, text="好的" * 6, partial=False)
    result = _result(
        "好的" * 6,
        segments=(looped,),
        words=tuple(
            TranscriptWord(word="好的", start_ms=index * 100, end_ms=index * 100 + 90)
            for index in range(6)
        ),
    )
    cleaned = collapse_transcript_result(result)

    assert cleaned.text == "好的"
    assert cleaned.segments[0].text == "好的"
    assert len(cleaned.words) == 1
    # The kept word owns the whole run's span, so no timing hole appears.
    assert (cleaned.words[0].start_ms, cleaned.words[0].end_ms) == (0, 590)
    assert cleaned.repetition_collapsed == 1


def test_a_run_straddling_two_segments_is_left_alone() -> None:
    # ``format_diarized`` reconstructs the transcript from its segments, so a
    # cross-segment collapse that only the top-level text performed would make
    # that reconstruction fail. Leaving it alone is the safe answer.
    first = TranscriptSegment(id=0, start_ms=0, end_ms=3_000, text="好的好的")
    second = TranscriptSegment(id=1, start_ms=3_000, end_ms=6_000, text="好的好的好的好的")
    result = _result("好的好的好的好的好的好的", segments=(first, second))
    cleaned = collapse_transcript_result(result)

    assert cleaned.text == "好的好的好的好的好的好的"
    assert cleaned.segments == (first, second)
    assert cleaned.repetition_collapsed == 0


def test_spans_that_no_longer_match_the_text_fall_back_to_the_whole_string() -> None:
    # A result whose segment text is not a substring of its own text is one
    # this helper was never promised; the whole string is still cleaned rather
    # than crashing the request.
    segment = TranscriptSegment(id=0, start_ms=0, end_ms=1_000, text="别处的话")
    result = _result("不不不不不不", segments=(segment,))
    assert collapse_transcript_result(result).text == "不"


def test_segments_and_words_are_cleaned_without_segments_text() -> None:
    result = _result(
        "",
        segments=(TranscriptSegment(id=0, start_ms=0, end_ms=1_000, text="还是" * 6),),
        words=(),
    )
    cleaned = collapse_transcript_result(result)
    assert cleaned.segments[0].text == "还是"
    assert cleaned.repetition_collapsed == 1


# --- cost -----------------------------------------------------------------


def test_the_cleanup_stays_bounded_on_large_transcripts() -> None:
    started = time.monotonic()
    payload = ("这是一段普通的会议记录，讨论的是预算和排期，没有循环。" * 200) + "预算" * 4_000
    collapsed = collapse_repetitions(payload)
    assert collapsed.text.endswith("预算")
    assert time.monotonic() - started < 5.0


def test_default_threshold_is_the_documented_one() -> None:
    assert DEFAULT_MIN_RUN == 6
    assert collapse_repetitions("abc" * DEFAULT_MIN_RUN).text == "abc"
