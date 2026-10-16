"""Validation and code-point mapping for fixed-text forced alignment.

The adapter never re-decodes audio: it hands the frozen text and an exact PCM
span to an independent aligner owner and maps the returned tokens back onto the
original code points.  Text is compared without normalization so a returned
offset always addresses the frozen revision the caller already published.

Matching is literal first and *spoken-form* second.  The aligner timestamps
speech, not typography: it splits on whitespace and keeps only letters, digits
and apostrophes, so ``3:45`` comes back as ``345`` and ``forty-two`` as
``fortytwo``.  Neither is a substring of the frozen text, and a plain
``str.find`` therefore rejected every ordinary sentence containing a digit or a
hyphen.  A token that fails the literal search is retried against a
punctuation-free projection of the same text, and the match is mapped back onto
the original code points so published offsets still address the frozen revision.
"""

from __future__ import annotations

import bisect
import math
import unicodedata
from collections.abc import Callable, Iterable
from contextlib import AbstractAsyncContextManager, nullcontext
from dataclasses import dataclass, replace
from typing import Protocol

from speechrail.domain.alignment import (
    AlignmentGranularity,
    AlignmentRequest,
    AlignmentResult,
    AlignmentUnit,
    AlignTextPort,
    InvalidAlignmentOutputError,
)
from speechrail.domain.audio_timeline import CORE_SAMPLE_RATE, PCM_SAMPLE_BYTES, SampleSpan
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment, TranscriptWord
from speechrail.observability.alignment import log_alignment_failure


class FixedTextTokenClient(Protocol):
    """Private adapter contract for a worker that aligns supplied text only."""

    async def align_text(
        self, pcm: bytes, *, text: str, language: str | None
    ) -> tuple[tuple[str, float, float], ...]: ...


def _diagnostic_timestamp_sample(value: object) -> int | None:
    """Keep invalid or extreme vendor numbers from breaking diagnostic logging."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        if not math.isfinite(value):
            return None
    except OverflowError:
        return None
    limit_seconds = 1_000_000_000 / CORE_SAMPLE_RATE
    return round(max(-limit_seconds, min(limit_seconds, value)) * CORE_SAMPLE_RATE)


class FixedTextAligner:
    """Application adapter that validates worker tokens against immutable text."""

    def __init__(
        self,
        client: FixedTextTokenClient,
        *,
        worker_lease: Callable[[], AbstractAsyncContextManager[object]] | None = None,
    ) -> None:
        self._client = client
        self._worker_lease = worker_lease

    async def align(self, request: AlignmentRequest) -> AlignmentResult:
        stage = "admission"
        try:
            async with self._worker_lease() if self._worker_lease else nullcontext():
                stage = "worker"
                raw = await self._client.align_text(
                    request.pcm16, text=request.text, language=request.language
                )
                stage = "validation"
                result = validate_alignment(request, raw)
                if result.failure is not None:
                    starts = [
                        sample for _, start, _ in raw
                        if (sample := _diagnostic_timestamp_sample(start)) is not None
                    ]
                    ends = [
                        sample for _, _, end in raw
                        if (sample := _diagnostic_timestamp_sample(end)) is not None
                    ]
                    log_alignment_failure(
                        code=result.failure, stage="validation",
                        audio_samples=request.span.length, text_characters=len(request.text),
                        expected_audio_samples=request.span.length,
                        span_start_sample=request.span.start,
                        transcript_revision=request.transcript_revision,
                        token_count=len(raw),
                        collapsed_tokens=sum(start == end for _, start, end in raw),
                        timestamp_min_start_sample=min(starts, default=-1),
                        timestamp_max_end_sample=max(ends, default=-1),
                    )
                return result
        except (RuntimeError, ValueError, OSError) as exc:
            if isinstance(exc, TimeoutError):
                code = "alignment_timeout"
            elif stage == "admission":
                code = "alignment_unavailable"
            elif isinstance(exc, InvalidAlignmentOutputError) or stage == "validation":
                code = "invalid_alignment"
            elif isinstance(exc, ValueError):
                code = "alignment_failed"
            else:
                code = "alignment_worker_failed"
            log_alignment_failure(
                code=code, stage=stage, audio_samples=request.span.length,
                expected_audio_samples=request.span.length,
                text_characters=len(request.text), span_start_sample=request.span.start,
                transcript_revision=request.transcript_revision, exception=exc,
            )
            return _failed(request, code)


class TranscriptAlignmentError(RuntimeError):
    """A finished transcript could not be given a truthful timeline."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


_SAMPLES_PER_MILLISECOND = CORE_SAMPLE_RATE // 1000


async def align_transcript_timeline(
    *,
    aligner: AlignTextPort,
    pcm16: bytes,
    result: TranscriptResult,
    utterance_id: str,
    granularities: frozenset[AlignmentGranularity],
) -> TranscriptResult:
    """Attach segment and word timelines to a finished transcript.

    The ASR owner decodes text only.  Timestamps come from the independent
    fixed-text aligner over the frozen transcript -- the same owner
    diarization already uses -- so there is no second ASR decode and the
    request path never reaches the network.  Qwen3-ASR has no native
    word-level timing: the vendor resolves an implicit ``Qwen/Qwen3-ForcedAligner``
    repository whenever ``return_timestamps`` is set, which cannot resolve
    under the managed offline environment and used to surface as an opaque
    500.  A granularity the aligner cannot support is reported as a failure,
    never as evenly split placeholders.
    """
    if not result.text:
        return result.model_copy(update={"segments": (), "words": ()})
    if not granularities:
        return result

    segments: tuple[TranscriptSegment, ...] = ()
    words: tuple[TranscriptWord, ...] = ()
    for granularity in sorted(granularities):
        outcome = await aligner.align(
            AlignmentRequest(
                task_id="transcribe",
                epoch=f"batch-{utterance_id}",
                utterance_id=utterance_id,
                transcript_revision=1,
                pcm16=pcm16,
                span=SampleSpan(0, len(pcm16) // PCM_SAMPLE_BYTES),
                text=result.text,
                language=result.language or None,
                granularity=granularity,
            )
        )
        if outcome.failure is not None:
            raise TranscriptAlignmentError(
                "timestamp_alignment_unavailable",
                "fixed-text alignment could not produce the requested "
                f"{granularity} timestamps ({outcome.failure})",
            )
        if granularity == "segment":
            segments = _units_to_segments(result.text, outcome.units)
        else:
            words = _units_to_words(result.text, outcome.units)
    return result.model_copy(update={"segments": segments, "words": words})


def _unit_milliseconds(unit: AlignmentUnit) -> tuple[int, int]:
    if unit.audio_span is None:
        raise TranscriptAlignmentError(
            "timestamp_alignment_unavailable",
            "fixed-text alignment returned a unit without an audio span",
        )
    return (
        unit.audio_span.start // _SAMPLES_PER_MILLISECOND,
        unit.audio_span.end // _SAMPLES_PER_MILLISECOND,
    )


def _units_to_segments(
    text: str, units: tuple[AlignmentUnit, ...]
) -> tuple[TranscriptSegment, ...]:
    segments: list[TranscriptSegment] = []
    for unit in units:
        rendered = text[unit.text_start : unit.text_end].strip()
        if not rendered:
            continue
        start_ms, end_ms = _unit_milliseconds(unit)
        segments.append(
            TranscriptSegment(
                id=len(segments), start_ms=start_ms, end_ms=end_ms, text=rendered
            )
        )
    return tuple(segments)


def _units_to_words(
    text: str, units: tuple[AlignmentUnit, ...]
) -> tuple[TranscriptWord, ...]:
    words: list[TranscriptWord] = []
    for unit in units:
        rendered = text[unit.text_start : unit.text_end].strip()
        if not rendered:
            continue
        start_ms, end_ms = _unit_milliseconds(unit)
        words.append(TranscriptWord(word=rendered, start_ms=start_ms, end_ms=end_ms))
    return tuple(words)


def _is_spoken_char(character: str) -> bool:
    """Return whether the pinned aligner keeps ``character`` inside a token.

    Mirrors ``mlx_qwen3_asr.ForcedAlignTextProcessor.is_kept_char``.  The
    mirror is pinned by ``tests/test_alignment_spoken_projection.py``, which
    fails if the two rules ever diverge.
    """

    if character == "'":
        return True
    category = unicodedata.category(character)
    return category.startswith("L") or category.startswith("N")


@dataclass(frozen=True, slots=True)
class _SpokenProjection:
    """Punctuation-free view of the frozen text plus its code-point origins.

    Whitespace survives verbatim so a token can never be matched across a word
    boundary, mirroring the aligner's own whitespace split.  Every other
    unspoken code point is dropped, which is what makes ``345`` locatable in
    ``"at 3:45 p.m."`` and ``fortytwo`` locatable in ``"forty-two"``.
    """

    spoken: str
    origins: tuple[int, ...]

    @classmethod
    def of(cls, text: str) -> _SpokenProjection:
        characters: list[str] = []
        origins: list[int] = []
        for index, character in enumerate(text):
            if character.isspace() or _is_spoken_char(character):
                characters.append(character)
                origins.append(index)
        return cls("".join(characters), tuple(origins))

    def locate(self, text: str, token: str, cursor: int) -> tuple[int, int] | None:
        """Return the frozen code-point range ``token`` spans at or after ``cursor``."""

        if not token or any(character.isspace() for character in token):
            return None
        start = self.spoken.find(token, bisect.bisect_left(self.origins, cursor))
        if start < 0:
            return None
        end = self.origins[start + len(token) - 1] + 1
        # The punctuation the aligner stripped belonged to this token, so the
        # token keeps it: ``pm`` came from ``p.m.`` and must also carry the
        # periods, otherwise they fall into the next token's leading gap and a
        # word renders as ``". on"``.  Claiming only unspoken, non-space
        # code points stops at the next word, which matters for Chinese where a
        # whole clause is one whitespace-delimited chunk.
        while end < len(text) and not text[end].isspace() and not _is_spoken_char(text[end]):
            end += 1
        return self.origins[start], end


def validate_alignment(
    request: AlignmentRequest, raw: Iterable[tuple[str, float, float]]
) -> AlignmentResult:
    """Map aligner tokens onto the frozen text or fail without re-decoding it.

    Tokens must match the frozen text in order at code-point granularity.  A
    token the aligner stripped punctuation from is matched against the spoken
    projection and mapped back to the code points it actually covers, so the
    returned units still address the frozen text verbatim.  When the caller
    asked for word or character output the returned tokens must actually carry
    that granularity; evenly splitting a phrase and calling it ``character`` is
    reported as ``granularity_unsupported`` rather than silently accepted.
    """

    cursor = 0
    projection: _SpokenProjection | None = None
    tokens: list[tuple[str, int, int, int, int]] = []
    previous_end_seconds: float | None = None
    duration_seconds = request.span.length / CORE_SAMPLE_RATE
    for token, start_seconds, end_seconds in raw:
        if (
            not isinstance(token, str)
            or not token
            or isinstance(start_seconds, bool)
            or not isinstance(start_seconds, (int, float))
            or isinstance(end_seconds, bool)
            or not isinstance(end_seconds, (int, float))
        ):
            return _failed(request, "invalid_alignment")
        try:
            finite_timestamps = math.isfinite(start_seconds) and math.isfinite(end_seconds)
        except OverflowError:
            finite_timestamps = False
        if not finite_timestamps:
            return _failed(request, "invalid_alignment")
        if end_seconds < start_seconds:
            return _failed(request, "invalid_alignment")
        if start_seconds < 0 or end_seconds > duration_seconds:
            return _failed(request, "alignment_out_of_bounds")
        if previous_end_seconds is not None and start_seconds < previous_end_seconds:
            return _failed(request, "alignment_not_monotonic")
        text_start = request.text.find(token, cursor)
        if text_start >= 0:
            text_end = text_start + len(token)
        else:
            if projection is None:
                projection = _SpokenProjection.of(request.text)
            located = projection.locate(request.text, token, cursor)
            if located is None:
                return _failed(request, "text_mismatch")
            text_start, text_end = located
        start = request.span.start + round(start_seconds * CORE_SAMPLE_RATE)
        end = request.span.start + round(end_seconds * CORE_SAMPLE_RATE)
        if start < request.span.start or end > request.span.end or end < start:
            return _failed(request, "alignment_out_of_bounds")
        tokens.append((token, text_start, text_end, start, end))
        cursor = text_end
        previous_end_seconds = end_seconds
    if not tokens:
        return _failed(request, "text_mismatch")
    if not _spoken_text_is_covered(request.text, tokens):
        return _failed(request, "text_mismatch")
    # The aligner timestamps spoken tokens, not typography. Preserve the
    # original immutable text by attaching every intervening code point
    # (spaces and punctuation included) to the following spoken token. At
    # segment granularity, a timestamp-grid tie has no representable interval
    # of its own: attach its exact text range to the next timed segment, or to
    # the previous timed segment when it is trailing. The segment span expands
    # to include the collapsed timestamp point without inventing a finer split.
    unit_ranges = _with_leading_gaps(tokens)
    if any(start == end for _, _, start, end in unit_ranges):
        if request.granularity != "segment":
            return _failed(request, "alignment_time_resolution_insufficient")
        unit_ranges = _coalesce_collapsed_segments(unit_ranges)
        if not unit_ranges:
            return _failed(request, "alignment_time_resolution_insufficient")
    if not _granularity_supported(request.granularity, tokens):
        return _failed(request, "granularity_unsupported")
    units = [
        AlignmentUnit(
            unit_id=f"{request.utterance_id}-{index}",
            text_start=text_start,
            text_end=text_end,
            audio_span=SampleSpan(start, end),
            granularity=request.granularity,
        )
        for index, (text_start, text_end, start, end) in enumerate(
            unit_ranges
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
    tokens: list[tuple[str, int, int, int, int]],
) -> list[tuple[int, int, int, int]]:
    """Pair each token with the text gap and original sample interval before it."""

    cursor = 0
    result: list[tuple[int, int, int, int]] = []
    for _token, _text_start, text_end, start, end in tokens:
        result.append((cursor, text_end, start, end))
        cursor = text_end
    return result


def _coalesce_collapsed_segments(
    ranges: list[tuple[int, int, int, int]],
) -> list[tuple[int, int, int, int]]:
    """Attach zero-width text to a neighboring segment and retain its time point."""

    coalesced: list[tuple[int, int, int, int]] = []
    pending: tuple[int, int, int, int] | None = None
    for text_start, text_end, start, end in ranges:
        if start == end:
            if pending is None:
                pending = (text_start, text_end, start, end)
            else:
                pending = (pending[0], text_end, pending[2], end)
            continue
        if pending is None:
            coalesced.append((text_start, text_end, start, end))
            continue
        pending_text_start, _pending_text_end, collapsed_start, _collapsed_end = pending
        coalesced.append((pending_text_start, text_end, min(collapsed_start, start), end))
        pending = None
    if pending is not None:
        if not coalesced:
            return []
        text_start, text_end, start, end = coalesced[-1]
        pending_text_start, pending_text_end, _collapsed_start, collapsed_end = pending
        if pending_text_start != text_end:
            return []
        coalesced[-1] = (
            text_start,
            pending_text_end,
            start,
            max(end, collapsed_end),
        )
    return coalesced


def _spoken_text_is_covered(
    text: str, tokens: list[tuple[str, int, int, int, int]]
) -> bool:
    """Return whether the tokens account for every spoken code point.

    The unit builder below hands every unmatched code point to a neighbouring
    token, which is how the punctuation the aligner stripped stays inside the
    published offsets.  That is only sound while the unmatched regions really
    are unspoken: a dropped word would otherwise be published as part of the
    next token's audio span, turning a truncated alignment into a plausible
    looking timeline.  Whitespace and punctuation may be absorbed; anything the
    aligner would have kept inside a token may not.
    """

    cursor = 0
    for _token, text_start, text_end, _start, _end in tokens:
        if any(_is_spoken_char(character) for character in text[cursor:text_start]):
            return False
        cursor = text_end
    return not any(_is_spoken_char(character) for character in text[cursor:])


def _granularity_supported(
    granularity: AlignmentGranularity,
    tokens: list[tuple[str, int, int, int, int]],
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
    """Accept a single unbroken word run, never a phrase with delimiters.

    The rule is the aligner's own kept-character set rather than a punctuation
    ban: the vendor strips ``don't`` down to a word but keeps the apostrophe,
    and rejecting that would fail ordinary English word timestamps.
    """

    return bool(token) and all(
        _is_spoken_char(character) for character in token
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


__all__ = [
    "FixedTextAligner",
    "FixedTextTokenClient",
    "TranscriptAlignmentError",
    "align_transcript_timeline",
    "validate_alignment",
]
