"""Validation and code-point mapping for fixed-text forced alignment.

The adapter never re-decodes audio: it hands the frozen text and an exact PCM
span to an independent aligner owner and maps the returned tokens back onto the
original code points.  Text is compared without normalization so a returned
offset always addresses the frozen revision the caller already published.
"""

from __future__ import annotations

import math
import unicodedata
from collections.abc import Iterable
from dataclasses import replace
from typing import Protocol

from speechrail.domain.alignment import (
    AlignmentGranularity,
    AlignmentRequest,
    AlignmentResult,
    AlignmentUnit,
)
from speechrail.domain.audio_timeline import CORE_SAMPLE_RATE, SampleSpan


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
    """Map aligner tokens onto the frozen text or fail without re-decoding it.

    Tokens must match the frozen text in order at code-point granularity.  When
    the caller asked for word or character output the returned tokens must
    actually carry that granularity; evenly splitting a phrase and calling it
    ``character`` is reported as ``granularity_unsupported`` rather than
    silently accepted.
    """

    cursor = 0
    tokens: list[tuple[str, int, int, SampleSpan]] = []
    for token, start_seconds, end_seconds in raw:
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
        text_end = text_start + len(token)
        start = request.span.start + round(start_seconds * CORE_SAMPLE_RATE)
        end = request.span.start + round(end_seconds * CORE_SAMPLE_RATE)
        if start < request.span.start or end > request.span.end or end <= start:
            return _failed(request, "alignment_out_of_bounds")
        if tokens and start < tokens[-1][3].end:
            return _failed(request, "alignment_not_monotonic")
        tokens.append((token, text_start, text_end, SampleSpan(start, end)))
        cursor = text_end
    if not tokens:
        return _failed(request, "text_mismatch")
    if not _granularity_supported(request.granularity, tokens):
        return _failed(request, "granularity_unsupported")
    # The aligner timestamps spoken tokens, not typography.  Preserve the
    # original immutable text by attaching every intervening code point
    # (spaces and punctuation included) to the following spoken token.  The
    # final unspoken suffix is attached to the preceding token below.
    units = [
        AlignmentUnit(
            unit_id=f"{request.utterance_id}-{index}",
            text_start=previous_end,
            text_end=text_end,
            audio_span=span,
            granularity=request.granularity,
        )
        for index, (_token, previous_end, text_end, span) in enumerate(
            _with_leading_gaps(tokens)
        )
    ]
    if units[-1].text_end < len(request.text):
        units[-1] = replace(units[-1], text_end=len(request.text))
    return AlignmentResult(
        task_id=request.task_id,
        epoch=request.epoch,
        utterance_id=request.utterance_id,
        transcript_revision=request.transcript_revision,
        units=tuple(units),
    )


def _with_leading_gaps(
    tokens: list[tuple[str, int, int, SampleSpan]],
) -> list[tuple[str, int, int, SampleSpan]]:
    """Return each token paired with the code-point gap that precedes it."""

    cursor = 0
    result: list[tuple[str, int, int, SampleSpan]] = []
    for token, _text_start, text_end, span in tokens:
        result.append((token, cursor, text_end, span))
        cursor = text_end
    return result


def _granularity_supported(
    granularity: AlignmentGranularity,
    tokens: list[tuple[str, int, int, SampleSpan]],
) -> bool:
    if granularity == "segment":
        return True
    if granularity == "character":
        return all(_is_character_token(token) for token, *_ in tokens)
    return all(_is_word_token(token) for token, *_ in tokens)


def _is_character_token(token: str) -> bool:
    """Accept one base code point plus its combining marks, never a phrase."""

    if not token:
        return False
    base = token[0]
    marks = token[1:]
    if unicodedata.combining(base):
        return False
    return all(unicodedata.combining(mark) for mark in marks)


def _is_word_token(token: str) -> bool:
    """Accept a single unbroken word run, never a phrase with delimiters."""

    return bool(token) and not any(
        character.isspace() or unicodedata.category(character).startswith("P")
        for character in token
    )


def _failed(request: AlignmentRequest, reason: str) -> AlignmentResult:
    return AlignmentResult(
        task_id=request.task_id,
        epoch=request.epoch,
        utterance_id=request.utterance_id,
        transcript_revision=request.transcript_revision,
        units=(),
        failure=reason,
    )


__all__ = ["FixedTextAligner", "FixedTextTokenClient", "validate_alignment"]
