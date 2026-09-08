"""Validation and code-point mapping for fixed-text forced alignment."""

from __future__ import annotations

import math
from collections.abc import Iterable
from dataclasses import replace
from typing import Protocol

from speechrail.domain.diarization.types import AlignmentRequest, AlignmentResult, Span, TextUnit


class FixedTextTokenClient(Protocol):
    """Private adapter contract for a worker that aligns supplied text only."""

    async def align_text(
        self, pcm: bytes, *, text: str, language: str | None
    ) -> tuple[tuple[str, float, float], ...]: ...


class FixedTextAligner:
    """Application adapter that validates worker tokens against immutable text."""

    def __init__(self, client: FixedTextTokenClient) -> None:
        self._client = client

    async def align(self, request: AlignmentRequest) -> AlignmentResult:
        try:
            raw = await self._client.align_text(
                request.pcm16, text=request.text, language=request.language
            )
        except (RuntimeError, ValueError):
            return _failed(request, "alignment_unavailable")
        return validate_alignment(request, raw)


def validate_alignment(
    request: AlignmentRequest, raw: Iterable[tuple[str, float, float]]
) -> AlignmentResult:
    """Map aligner tokens onto the frozen text or fail without re-decoding it."""

    cursor = 0
    units: list[TextUnit] = []
    for index, (token, start_seconds, end_seconds) in enumerate(raw):
        if (
            not token
            or not math.isfinite(start_seconds)
            or not math.isfinite(end_seconds)
            or end_seconds <= start_seconds
        ):
            return _failed(request, "invalid_alignment")
        text_start = request.text.find(token, cursor)
        if text_start < 0:
            return _failed(request, "text_mismatch")
        token_end = text_start + len(token)
        start = request.span.start + round(start_seconds * 16_000)
        end = request.span.start + round(end_seconds * 16_000)
        if start < request.span.start or end > request.span.end or end <= start:
            return _failed(request, "alignment_out_of_bounds")
        if units and start < units[-1].audio_span.end:  # type: ignore[union-attr]
            return _failed(request, "alignment_not_monotonic")
        # The aligner timestamps spoken tokens, not typography.  Preserve the
        # original immutable text by attaching every intervening code point
        # (spaces and punctuation included) to the following spoken token.
        # The final unspoken suffix is attached to the preceding token below.
        units.append(TextUnit(f"{request.item_id}-{index}", cursor, token_end, Span(start, end)))
        cursor = token_end
    if not units:
        return _failed(request, "text_mismatch")
    if cursor < len(request.text):
        units[-1] = replace(units[-1], text_end=len(request.text))
    return AlignmentResult(request.epoch, request.item_id, tuple(units))


def _failed(request: AlignmentRequest, reason: str) -> AlignmentResult:
    return AlignmentResult(request.epoch, request.item_id, (), reason)
