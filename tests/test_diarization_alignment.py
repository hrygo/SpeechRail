from __future__ import annotations

import asyncio
import math

from speechrail.application.diarization.alignment import FixedTextAligner, validate_alignment
from speechrail.domain.diarization import AlignmentRequest, Span


def _request() -> AlignmentRequest:
    return AlignmentRequest(
        "epoch-1", "item-1", b"\x00\x00" * 32_000, Span(0, 32_000), "2026年。", "zh"
    )


def test_fixed_text_alignment_preserves_the_frozen_code_point_ranges() -> None:
    result = validate_alignment(_request(), (("2026", 0.0, 1.0), ("年。", 1.0, 2.0)))

    assert result.failure is None
    assert [(unit.text_start, unit.text_end) for unit in result.units] == [(0, 4), (4, 6)]
    assert [(unit.audio_span.start, unit.audio_span.end) for unit in result.units] == [
        (0, 16_000),
        (16_000, 32_000),
    ]


def test_fixed_text_alignment_assigns_unspoken_typography_without_rewriting() -> None:
    request = AlignmentRequest(
        "epoch-1", "item-1", b"\x00\x00" * 32_000, Span(0, 32_000), "你好， world！", "zh"
    )

    result = validate_alignment(request, (("你好", 0.0, 0.5), ("world", 0.8, 1.5)))

    assert result.failure is None
    assert [(unit.text_start, unit.text_end) for unit in result.units] == [(0, 2), (2, 10)]
    covered = "".join(request.text[unit.text_start : unit.text_end] for unit in result.units)
    assert covered == request.text


def test_fixed_text_alignment_preserves_unicode_code_point_ranges() -> None:
    request = AlignmentRequest(
        "epoch-1", "item-1", b"\x00\x00" * 32_000, Span(0, 32_000), "你好👋，世界！", "zh"
    )

    result = validate_alignment(request, (("你好", 0.0, 1.0), ("世界", 1.0, 2.0)))

    assert result.failure is None
    assert [(unit.text_start, unit.text_end) for unit in result.units] == [(0, 2), (2, 7)]
    assert "".join(request.text[u.text_start : u.text_end] for u in result.units) == request.text


def test_fixed_text_alignment_fails_closed_for_bad_tokens_or_times() -> None:
    request = _request()
    assert validate_alignment(request, (("二〇二六", 0.0, 1.0),)).failure == "text_mismatch"
    assert validate_alignment(request, (("2026", 0.0, math.nan),)).failure == "invalid_alignment"
    assert validate_alignment(request, (("2026", 1.0, 2.1),)).failure == "alignment_out_of_bounds"
    assert validate_alignment(
        request, (("2026", 1.0, 2.0), ("年。", 0.5, 1.0))
    ).failure == "alignment_not_monotonic"


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
