from __future__ import annotations

import asyncio
import math

from speechrail.application.alignment import FixedTextAligner, validate_alignment
from speechrail.domain.alignment import AlignmentGranularity, AlignmentRequest
from speechrail.domain.audio_timeline import SampleSpan


def _request(
    text: str = "2026年。",
    *,
    granularity: AlignmentGranularity = "segment",
) -> AlignmentRequest:
    return AlignmentRequest(
        task_id="task-1",
        epoch="epoch-1",
        utterance_id="item-1",
        transcript_revision=3,
        pcm16=b"\x00\x00" * 32_000,
        span=SampleSpan(0, 32_000),
        text=text,
        language="zh",
        granularity=granularity,
    )


def test_validate_alignment_preserves_the_frozen_code_point_ranges() -> None:
    result = validate_alignment(_request(), (("2026", 0.0, 1.0), ("年。", 1.0, 2.0)))

    assert result.failure is None
    assert result.status == "done"
    assert result.transcript_revision == 3
    assert [(unit.text_start, unit.text_end) for unit in result.units] == [(0, 4), (4, 6)]
    assert [(unit.audio_span.start, unit.audio_span.end) for unit in result.units] == [
        (0, 16_000),
        (16_000, 32_000),
    ]


def test_validate_alignment_assigns_unspoken_typography_without_rewriting() -> None:
    request = _request("你好， world！")

    result = validate_alignment(request, (("你好", 0.0, 0.5), ("world", 0.8, 1.5)))

    assert result.failure is None
    assert [(unit.text_start, unit.text_end) for unit in result.units] == [(0, 2), (2, 10)]
    covered = "".join(request.text[unit.text_start : unit.text_end] for unit in result.units)
    assert covered == request.text


def test_validate_alignment_preserves_unicode_code_point_ranges() -> None:
    request = _request("你好👋，世界！")

    result = validate_alignment(request, (("你好", 0.0, 1.0), ("世界", 1.0, 2.0)))

    assert result.failure is None
    assert [(unit.text_start, unit.text_end) for unit in result.units] == [(0, 2), (2, 7)]
    assert "".join(request.text[u.text_start : u.text_end] for u in result.units) == request.text


def test_validate_alignment_keeps_original_offsets_for_combining_sequences() -> None:
    # "e" + U+0301 is one grapheme but two code points.  The span must stay in
    # the frozen text's own code-point domain, never a normalized copy.
    request = _request("cafe\u0301", granularity="character")

    result = validate_alignment(request, (("c", 0.0, 0.5), ("e\u0301", 0.5, 1.0)))

    assert result.failure is None
    assert [(unit.text_start, unit.text_end) for unit in result.units] == [(0, 1), (1, 5)]
    assert [unit.granularity for unit in result.units] == ["character", "character"]


def test_validate_alignment_matches_repeated_words_in_order() -> None:
    request = _request("go go now", granularity="word")

    result = validate_alignment(
        request, (("go", 0.0, 0.3), ("go", 0.3, 0.6), ("now", 0.6, 1.0))
    )

    assert result.failure is None
    assert [(unit.text_start, unit.text_end) for unit in result.units] == [(0, 2), (2, 5), (5, 9)]


def test_validate_alignment_rejects_phrase_when_character_granularity_is_requested() -> None:
    request = _request("你好世界", granularity="character")

    # Evenly splitting a two-character phrase is not character-level evidence.
    result = validate_alignment(request, (("你好", 0.0, 1.0), ("世界", 1.0, 2.0)))

    assert result.failure == "granularity_unsupported"
    assert result.units == ()


def test_validate_alignment_rejects_phrase_when_word_granularity_is_requested() -> None:
    request = _request("hello world", granularity="word")

    assert (
        validate_alignment(request, (("hello world", 0.0, 1.0),)).failure
        == "granularity_unsupported"
    )


def test_validate_alignment_accepts_aligner_character_tokens() -> None:
    request = _request("你好。", granularity="character")

    result = validate_alignment(
        request, (("你", 0.0, 0.5), ("好", 0.5, 1.0), ("。", 1.0, 1.5))
    )

    assert result.failure is None
    assert [(unit.text_start, unit.text_end) for unit in result.units] == [(0, 1), (1, 2), (2, 3)]
    assert all(unit.granularity == "character" for unit in result.units)


def test_validate_alignment_fails_closed_for_bad_tokens_or_times() -> None:
    request = _request()
    assert validate_alignment(request, (("二〇二六", 0.0, 1.0),)).failure == "text_mismatch"
    assert validate_alignment(request, (("2026", 0.0, math.nan),)).failure == "invalid_alignment"
    assert validate_alignment(request, (("2026", 1.0, 2.1),)).failure == "alignment_out_of_bounds"
    assert (
        validate_alignment(request, (("2026", 1.0, 2.0), ("年。", 0.5, 1.0))).failure
        == "alignment_not_monotonic"
    )
    assert validate_alignment(request, ()).failure == "text_mismatch"


def test_validate_alignment_requires_the_requested_granularity() -> None:
    assert validate_alignment(_request("abc"), (("abc", 0.0, 1.0),)).failure is None
    assert (
        validate_alignment(_request("abc", granularity="word"), (("abc", 0.0, 1.0),)).failure
        is None
    )
    assert (
        validate_alignment(
            _request("abc", granularity="character"), (("abc", 0.0, 1.0),)
        ).failure
        == "granularity_unsupported"
    )


def test_fixed_text_aligner_returns_only_validated_units() -> None:
    class Client:
        calls = 0

        async def align_text(
            self, pcm: bytes, *, text: str, language: str | None
        ) -> tuple[tuple[str, float, float], ...]:
            self.calls += 1
            assert pcm == _request().pcm16
            assert text == "2026年。"
            assert language == "zh"
            return (("2026", 0.0, 1.0), ("年", 1.0, 2.0))

    client = Client()
    result = asyncio.run(FixedTextAligner(client).align(_request()))

    assert client.calls == 1
    assert result.failure is None
    request = _request()
    covered = "".join(request.text[u.text_start : u.text_end] for u in result.units)
    assert covered == request.text


def test_fixed_text_aligner_reports_unavailable_instead_of_empty_success() -> None:
    class BrokenClient:
        async def align_text(
            self, pcm: bytes, *, text: str, language: str | None
        ) -> tuple[tuple[str, float, float], ...]:
            raise RuntimeError("aligner crashed")

    result = asyncio.run(FixedTextAligner(BrokenClient()).align(_request()))

    assert result.status == "failed"
    assert result.failure == "alignment_unavailable"
    assert result.units == ()
