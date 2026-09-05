"""Tests for absolute transcript-window merging and conservative text deduplication."""

from __future__ import annotations

import pytest

from speechrail.application.audio_stream import PcmBlock
from speechrail.application.transcript_merge import (
    TranscriptMerger,
    merge_results,
    offset_ms,
)
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment, TranscriptWord


def _block(
    *,
    start_sample: int,
    core_start_sample: int,
    core_end_sample: int,
    window_samples: int,
) -> PcmBlock:
    return PcmBlock(
        start_sample=start_sample,
        pcm=b"\x00\x00" * window_samples,
        core_start_sample=core_start_sample,
        core_end_sample=core_end_sample,
    )


def _result(
    text: str = "",
    *,
    duration_ms: int = 0,
    language: str | None = None,
    segments: tuple[TranscriptSegment, ...] = (),
    words: tuple[TranscriptWord, ...] = (),
) -> TranscriptResult:
    return TranscriptResult(
        request_id="child-request",
        model_id="speechrail/test-model",
        text=text,
        language=language,
        duration_ms=duration_ms,
        segments=segments,
        words=words,
    )


def test_offset_ms_preserves_global_sample_time() -> None:
    assert offset_ms(250, 16_000 * 30) == 30_250

    with pytest.raises(ValueError, match="invalid_transcript_offset"):
        offset_ms(-1, 0)


def test_timed_results_use_absolute_time_core_ownership_and_new_ids() -> None:
    first_block = _block(
        start_sample=0,
        core_start_sample=0,
        core_end_sample=16_000,
        window_samples=16_000,
    )
    second_block = _block(
        start_sample=14_400,
        core_start_sample=16_000,
        core_end_sample=30_400,
        window_samples=16_000,
    )
    first = _result(
        text="你好",
        duration_ms=1_000,
        language="zh",
        segments=(
            TranscriptSegment(
                id=9,
                start_ms=0,
                end_ms=1_000,
                text="你好",
                speaker="speaker_a",
            ),
        ),
        words=(TranscriptWord(word="你好", start_ms=0, end_ms=1_000),),
    )
    second = _result(
        text="你好世界",
        duration_ms=1_000,
        language="zh",
        segments=(
            TranscriptSegment(id=2, start_ms=0, end_ms=100, text="你好"),
            TranscriptSegment(
                id=3,
                start_ms=100,
                end_ms=1_000,
                text="世界",
                speaker="speaker_b",
            ),
        ),
        words=(
            TranscriptWord(word="你好", start_ms=0, end_ms=100),
            TranscriptWord(word="世界", start_ms=100, end_ms=1_000),
        ),
    )

    merged = merge_results(
        (first_block, second_block),
        (first, second),
        request_id="main-request",
        model_id="speechrail/test-model",
    )

    assert merged.request_id == "main-request"
    assert merged.model_id == "speechrail/test-model"
    assert merged.text == "你好世界"
    assert merged.language == "zh"
    assert merged.duration_ms == 1_900
    assert [
        (segment.id, segment.start_ms, segment.end_ms, segment.text)
        for segment in merged.segments
    ] == [
        (0, 0, 1_000, "你好"),
        (1, 1_000, 1_900, "世界"),
    ]
    assert merged.segments[0].speaker == "speaker_a"
    assert merged.segments[1].speaker == "speaker_b"
    assert [(word.word, word.start_ms, word.end_ms) for word in merged.words] == [
        ("你好", 0, 1_000),
        ("世界", 1_000, 1_900),
    ]

    overlap_only = merge_results(
        (first_block, second_block),
        (
            first,
            _result(
                text="你好",
                duration_ms=1_000,
                language="zh",
                segments=(TranscriptSegment(id=4, start_ms=0, end_ms=100, text="你好"),),
            ),
        ),
        request_id="main-request",
        model_id="speechrail/test-model",
    )
    assert overlap_only.text == "你好"
    assert len(overlap_only.segments) == 1


def test_text_only_merge_is_conservative_at_window_boundaries() -> None:
    blocks = tuple(
        _block(
            start_sample=start,
            core_start_sample=core_start,
            core_end_sample=core_end,
            window_samples=8,
        )
        for start, core_start, core_end in ((0, 0, 8), (6, 8, 14), (12, 14, 20))
    )

    chinese = merge_results(
        blocks,
        (
            _result("你好世界"),
            _result("世界和平"),
            _result("和平安宁"),
        ),
        request_id="request",
        model_id="model",
    )
    assert chinese.text == "你好世界和平安宁"

    repeated = merge_results(
        blocks[:2],
        (_result("very"), _result("very")),
        request_id="request",
        model_id="model",
    )
    assert repeated.text == "very very"

    identifiers = merge_results(
        blocks[:2],
        (
            _result("order 12345 OpenAI"),
            _result("12345 OpenAI confirmed"),
        ),
        request_id="request",
        model_id="model",
    )
    assert identifiers.text == "order 12345 OpenAI confirmed"

    abbreviation = merge_results(
        blocks[:2],
        (_result("meet U.S."), _result("U.S. tomorrow")),
        request_id="request",
        model_id="model",
    )
    assert abbreviation.text == "meet U.S. tomorrow"


@pytest.mark.parametrize(
    ("first_text", "second_text", "expected"),
    [
        ("مرحبا بالعالم", "بالعالم اليوم", "مرحبا بالعالم اليوم"),
        ("안녕 세계", "세계 반가워", "안녕 세계 반가워"),
        ("こんにちは 世界", "世界 今日は", "こんにちは 世界 今日は"),
    ],
)
def test_unicode_words_are_tokenized_for_bounded_deduplication(
    first_text: str,
    second_text: str,
    expected: str,
) -> None:
    blocks = (
        _block(start_sample=0, core_start_sample=0, core_end_sample=8, window_samples=8),
        _block(start_sample=6, core_start_sample=8, core_end_sample=14, window_samples=8),
    )

    merged = merge_results(
        blocks,
        (_result(first_text), _result(second_text)),
        request_id="request",
        model_id="model",
    )

    assert merged.text == expected


def test_text_dedup_requires_real_overlap_and_keeps_ambiguous_repeats() -> None:
    non_overlapping_blocks = (
        _block(start_sample=0, core_start_sample=0, core_end_sample=8, window_samples=8),
        _block(start_sample=8, core_start_sample=8, core_end_sample=16, window_samples=8),
    )
    non_overlapping = merge_results(
        non_overlapping_blocks,
        (_result("one two three"), _result("two three four")),
        request_id="request",
        model_id="model",
    )
    assert non_overlapping.text == "one two three two three four"

    repeated = merge_results(
        non_overlapping_blocks,
        (_result("very very"), _result("very very")),
        request_id="request",
        model_id="model",
    )
    assert repeated.text == "very very very very"

    proper_name = merge_results(
        non_overlapping_blocks,
        (_result("Paris"), _result("Paris")),
        request_id="request",
        model_id="model",
    )
    assert proper_name.text == "Paris Paris"

    number = merge_results(
        non_overlapping_blocks,
        (_result("2026"), _result("2026")),
        request_id="request",
        model_id="model",
    )
    assert number.text == "2026 2026"


def test_merger_rejects_cumulative_text_over_limit_during_add() -> None:
    blocks = (
        _block(start_sample=0, core_start_sample=0, core_end_sample=8, window_samples=8),
        _block(start_sample=8, core_start_sample=8, core_end_sample=16, window_samples=8),
    )
    merger = TranscriptMerger()
    merger.add(blocks[0], _result("a" * 60_000))

    with pytest.raises(ValueError, match="merge_text_too_long"):
        merger.add(blocks[1], _result("b" * 60_000))
    with pytest.raises(ValueError, match="merge_failed"):
        merger.finish("request", "model")


def test_language_change_is_top_level_unknown_and_silence_stays_empty() -> None:
    blocks = (
        _block(start_sample=0, core_start_sample=0, core_end_sample=8, window_samples=8),
        _block(start_sample=6, core_start_sample=8, core_end_sample=14, window_samples=8),
    )
    merged = merge_results(
        blocks,
        (_result("hello", language="en"), _result("你好", language="zh")),
        request_id="request",
        model_id="model",
    )
    assert merged.language is None
    assert merged.text

    silence = merge_results(
        blocks,
        (_result(language="en"), _result(language="en")),
        request_id="request",
        model_id="model",
    )
    assert silence.text == ""
    assert silence.duration_ms == 1


def test_merger_validates_core_continuity_and_never_returns_partial_failure() -> None:
    first_block = _block(start_sample=0, core_start_sample=0, core_end_sample=8, window_samples=8)
    gap_block = _block(start_sample=8, core_start_sample=9, core_end_sample=16, window_samples=8)
    merger = TranscriptMerger()
    merger.add(first_block, _result("first"))

    with pytest.raises(ValueError, match="merge_core_discontinuity"):
        merger.add(gap_block, _result("second"))
    with pytest.raises(ValueError, match="merge_failed"):
        merger.finish("request", "model")

    with pytest.raises(ValueError, match="merge_window_mismatch"):
        merge_results((first_block,), ())


def test_merger_finish_is_idempotent_and_does_not_retain_pcm() -> None:
    block = _block(start_sample=0, core_start_sample=0, core_end_sample=8, window_samples=8)
    merger = TranscriptMerger()
    merger.add(block, _result("done"))

    first = merger.finish("request", "model")
    second = merger.finish("other-request", "other-model")

    assert second is first
    assert all("pcm" not in slot for slot in TranscriptMerger.__slots__)
    assert all("block" not in slot for slot in TranscriptMerger.__slots__)
    assert "_language_values" not in TranscriptMerger.__slots__
    with pytest.raises(ValueError, match="merger_finished"):
        merger.add(block, _result("again"))


def test_unknown_result_is_a_failure_without_partial_success() -> None:
    block = _block(start_sample=0, core_start_sample=0, core_end_sample=8, window_samples=8)
    merger = TranscriptMerger()

    with pytest.raises(ValueError, match="merge_window_mismatch"):
        merger.add(block, object())  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="merge_failed"):
        merger.finish("request", "model")
