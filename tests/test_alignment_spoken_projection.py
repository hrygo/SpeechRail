"""Regression cover for punctuation-stripped aligner tokens.

The pinned aligner timestamps speech, not typography: it splits on whitespace
and keeps only letters, digits and apostrophes.  Every token below is real
output captured from ``mlx_qwen3_asr.ForcedAlignTextProcessor`` against the
frozen transcripts, because the pre-fix suite only ever fed the validator
literal substrings and therefore never exercised a real English sentence.
"""

from __future__ import annotations

import pytest

from speechrail.application.alignment import _is_spoken_char, validate_alignment
from speechrail.domain.alignment import (
    AlignmentGranularity,
    AlignmentRequest,
    AlignmentResult,
)
from speechrail.domain.audio_timeline import SampleSpan

_SAMPLES_PER_MILLISECOND = 16
_SPAN = SampleSpan(0, 32_000)

# (frozen text, real vendor tokens) pairs.  See module docstring.
VENDOR_TOKENIZATION: tuple[tuple[str, tuple[str, ...]], ...] = (
    (
        "The quick brown fox jumps over the lazy dog at 3:45 p.m. on September 26, 2026.",
        (
            "The", "quick", "brown", "fox", "jumps", "over", "the", "lazy",
            "dog", "at", "345", "pm", "on", "September", "26", "2026",
        ),
    ),
    (
        "The build number forty-two shipped on twenty twenty-six.",
        ("The", "build", "number", "fortytwo", "shipped", "on", "twenty", "twentysix"),
    ),
    (
        "I don't think it's ready yet, and we won't ship it.",
        ("I", "don't", "think", "it's", "ready", "yet", "and", "we", "won't", "ship", "it"),
    ),
    (
        "今天下午3:45，我们在9月26日讨论了发布计划。",
        (
            "今", "天", "下", "午", "345", "我", "们", "在", "9", "月", "26", "日",
            "讨", "论", "了", "发", "布", "计", "划",
        ),
    ),
    (
        "The quick brown fox jumps over the lazy dog.",
        ("The", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog"),
    ),
)


def _request(
    text: str,
    *,
    granularity: AlignmentGranularity = "segment",
) -> AlignmentRequest:
    return AlignmentRequest(
        task_id="task-1",
        epoch="epoch-1",
        utterance_id="item-1",
        transcript_revision=1,
        pcm16=b"\x00\x00" * 32_000,
        span=_SPAN,
        text=text,
        language=None,
        granularity=granularity,
    )


def _timed(tokens: tuple[str, ...]) -> tuple[tuple[str, float, float], ...]:
    """Spread tokens over the two-second span monotonically."""

    step = 1.8 / len(tokens)
    return tuple(
        (token, round(index * step, 4), round((index + 1) * step, 4))
        for index, token in enumerate(tokens)
    )


def text_of(text: str, result: AlignmentResult) -> str:
    """Render validated units back to text using the frozen revision."""

    return "".join(text[unit.text_start : unit.text_end] for unit in result.units)


@pytest.mark.parametrize(("text", "tokens"), VENDOR_TOKENIZATION)
def test_validate_alignment_accepts_real_vendor_tokenization(
    text: str, tokens: tuple[str, ...]
) -> None:
    result = validate_alignment(_request(text), _timed(tokens))

    assert result.failure is None
    assert result.units
    assert result.units[-1].text_end == len(text)
    starts = [unit.text_start for unit in result.units]
    assert starts == sorted(starts)


@pytest.mark.parametrize(("text", "tokens"), VENDOR_TOKENIZATION)
def test_units_still_partition_the_frozen_text_verbatim(
    text: str, tokens: tuple[str, ...]
) -> None:
    """The published offsets must address the caller's text, not a normalized copy."""

    result = validate_alignment(_request(text), _timed(tokens))

    assert result.failure is None
    assert text_of(text, result) == text


@pytest.mark.parametrize(("text", "tokens"), VENDOR_TOKENIZATION)
def test_validate_alignment_word_granularity_accepts_real_vendor_tokenization(
    text: str, tokens: tuple[str, ...]
) -> None:
    result = validate_alignment(_request(text, granularity="word"), _timed(tokens))

    assert result.failure is None


def test_spoken_match_covers_the_punctuation_it_swallowed() -> None:
    text = "今天下午3:45，我们在9月26日讨论了发布计划。"
    result = validate_alignment(
        _request(text),
        _timed(
            (
                "今", "天", "下", "午", "345", "我", "们", "在", "9", "月",
                "26", "日", "讨", "论", "了", "发", "布", "计", "划",
            )
        ),
    )

    assert result.failure is None
    # "345" is not in the text; the unit must still cover "3:45" code point for
    # code point, and it must also carry the punctuation the aligner stripped
    # after it.  The lead-in is a token of its own here, so nothing unspoken may
    # be absorbed into this unit.
    unit = result.units[4]
    assert text[unit.text_start : unit.text_end] == "3:45，"


def test_spoken_match_swallows_trailing_and_leading_punctuation() -> None:
    result = validate_alignment(
        _request("Call 911 immediately, please."),
        (
            ("Call", 0, 0.2),
            ("911", 0.2, 0.4),
            ("immediately", 0.4, 0.6),
            ("please", 0.6, 0.8),
        ),
    )

    assert result.failure is None
    assert text_of("Call 911 immediately, please.", result) == (
        "Call 911 immediately, please."
    )


def test_missing_spoken_token_fails_closed() -> None:
    """A dropped word must never be absorbed into the next token's time span."""

    result = validate_alignment(
        _request("Do not pay 500 dollars."),
        (("Do", 0, 0.1), ("pay", 0.2, 0.3), ("dollars", 0.4, 0.5)),
    )

    assert result.failure == "text_mismatch"


def test_missing_trailing_and_leading_tokens_fail_closed() -> None:
    assert (
        validate_alignment(
            _request("please call now"), (("call", 0.1, 0.3), ("now", 0.4, 0.6))
        ).failure
        == "text_mismatch"
    )
    assert (
        validate_alignment(
            _request("call now please"), (("call", 0, 0.2), ("now", 0.3, 0.5))
        ).failure
        == "text_mismatch"
    )


def test_missing_number_token_fails_closed() -> None:
    assert (
        validate_alignment(
            _request("transfer 500 yuan today"),
            (("transfer", 0, 0.3), ("yuan", 0.4, 0.6), ("today", 0.7, 0.9)),
        ).failure
        == "text_mismatch"
    )


def test_spoken_match_never_crosses_a_word_boundary() -> None:
    result = validate_alignment(
        _request("hello world"), (("helloworld", 0, 1),)
    )

    assert result.failure == "text_mismatch"


def test_rendered_words_carry_no_stray_punctuation() -> None:
    """A word whose token was punctuation-stripped must render as a whole word.

    The aligner hands back ``pm`` and ``twentysix``; without claiming the
    punctuation it stripped, that punctuation lands in the *next* token's
    leading gap and the public word text reads ``". on"`` or ``", two"``.

    Only the projected path claims trailing punctuation.  The literal path
    keeps the long-standing rule that unspoken typography attaches to the
    following spoken token, which ``test_validate_alignment_preserves_unicode_
    code_point_ranges`` pins for emoji.
    """

    text = "It happened at 3:45 p.m. on September 26, 2026."
    tokens = ("It", "happened", "at", "345", "pm", "on", "September", "26", "2026")
    result = validate_alignment(_request(text, granularity="word"), _timed(tokens))

    assert result.failure is None
    raw = [text[unit.text_start : unit.text_end] for unit in result.units]
    # Each unit addresses the *frozen* text, so a token comes back spelled the
    # way the caller wrote it -- and owns the punctuation the aligner stripped.
    stripped = [word.strip() for word in raw]
    assert stripped == [
        # literal matches, verbatim
        "It", "happened", "at",
        # projected matches own the punctuation the aligner stripped, so
        # nothing leaks forward and a word reads as a word
        "3:45", "p.m.",
        # literal matches again; the comma ahead of `2026` stays in the
        # following token's leading gap, exactly as before this change
        "on", "September", "26", ", 2026.",
    ]


def test_genuinely_absent_tokens_still_fail_closed() -> None:
    assert (
        validate_alignment(_request("2026年。"), (("二〇二六", 0, 1),)).failure
        == "text_mismatch"
    )
    # Normalization must not resurrect a token that is merely reordered.
    assert (
        validate_alignment(
            _request("September 26, 2026."), (("2026", 0, 0.5), ("September", 0.5, 1))
        ).failure
        == "text_mismatch"
    )


def test_out_of_order_spoken_tokens_fail_closed() -> None:
    result = validate_alignment(
        _request("at 3:45 pm."), (("pm", 0, 0.2), ("345", 0.2, 0.4))
    )

    assert result.failure == "text_mismatch"


def test_spoken_char_rule_mirrors_the_pinned_aligner() -> None:
    vendor = pytest.importorskip(
        "mlx_qwen3_asr.forced_aligner",
        reason="aligner vendor runtime is not installed in this environment",
    )
    processor = vendor.ForcedAlignTextProcessor
    samples = [
        *"'",
        *"abcXYZ",
        *"0123456789",
        *".,:;!?-–—()[]\"'/\\",
        *"中文测试",
        *"é ü ß",
        *"€¥±×",
        *"\t\n",
        *" ",
    ]
    assert all(_is_spoken_char(ch) == processor.is_kept_char(ch) for ch in samples)
