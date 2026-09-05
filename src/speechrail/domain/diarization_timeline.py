"""Sample-domain timeline and canonical-text alignment gate (SPK-E2E-1).

Pure helpers backing the speaker-diarization extensions:

- ``Timeline`` counts accepted PCM16 audio in integer samples for one WebSocket
  session, so VAD boundaries, commit rollovers and odd-sized packets can never
  restart or drift the session-global clock.
- ``verify_alignment`` and ``build_alignment_units`` decide whether a vendor
  timestamp candidate describes exactly the fixed canonical transcript; any
  inconsistency yields ``None`` so callers emit ``timing_quality="unavailable"``
  attribution instead of silently re-timing words.

Timestamps and sample ranges are integers over 16 kHz PCM16.  Item-local
sample domains start at zero; ``Timeline.absolute`` lifts them into the
session-global domain exactly once.
"""

from __future__ import annotations

import unicodedata
from collections.abc import Sequence
from dataclasses import dataclass

SAMPLE_RATE = 16_000

# Comparison sequences keep letters, digits and marks; whitespace, punctuation
# and symbols are dropped so "同意。" and "同意" describe the same characters.
_KEPT_CATEGORIES = ("L", "N", "M")


def samples_to_ms(samples: int) -> int:
    """Floor-convert session samples to whole milliseconds."""
    if samples < 0:
        raise ValueError("samples must be non-negative")
    return samples * 1000 // SAMPLE_RATE


class Timeline:
    """Monotonic session-global sample clock over accepted PCM16 bytes."""

    __slots__ = ("_accepted_samples",)

    def __init__(self) -> None:
        self._accepted_samples = 0

    @property
    def accepted_samples(self) -> int:
        return self._accepted_samples

    def accept(self, pcm: bytes) -> tuple[int, int]:
        """Account one appended PCM16 chunk and return its session sample span."""
        if len(pcm) % 2:
            raise ValueError("timeline accepts even-length PCM16 bytes only")
        start = self._accepted_samples
        self._accepted_samples += len(pcm) // 2
        return start, self._accepted_samples

    def absolute(self, item_start: int, start: int, end: int) -> tuple[int, int]:
        """Lift one item-local sample span into the session-global domain."""
        if item_start < 0 or start < 0 or end < start:
            raise ValueError("invalid item-local sample span")
        return item_start + start, item_start + end


def comparison_sequence(text: str) -> str:
    """NFKC-normalized characters kept for transcript comparison."""
    return _comparison(text)[0]


def comparison_indices(text: str) -> tuple[int, ...]:
    """Code point indices of the characters kept by ``comparison_sequence``."""
    return _comparison(text)[1]


def verify_alignment(canonical: str, candidate: str) -> bool:
    """Whether the candidate transcript describes exactly the canonical text."""
    return _comparison(canonical)[0] == _comparison(candidate)[0]


def timestamps_within_item(start: int, end: int, *, item_samples: int) -> bool:
    """Whether one item-local timestamp span is finite, ordered and in-bounds."""
    if item_samples < 0:
        return False
    return 0 <= start < end <= item_samples


@dataclass(frozen=True, slots=True)
class AlignmentUnit:
    """One canonical-text attribution span with item-local sample bounds."""

    text_start: int
    text_end: int
    start_sample: int
    end_sample: int


def build_alignment_units(
    canonical: str,
    candidate: str,
    words: Sequence[tuple[int, int, int, int]],
    *,
    item_samples: int,
) -> tuple[AlignmentUnit, ...] | None:
    """Map candidate word spans onto immutable canonical-text units.

    ``words`` holds ``(candidate_text_start, candidate_text_end,
    start_sample, end_sample)`` tuples with code point spans over the raw
    candidate string.  Returns ``None`` when the candidate does not describe
    the canonical text, when any timestamp leaves the item audio, or when the
    words do not cover every compared character exactly once.  An empty
    canonical text yields an empty tuple only when no words are given.
    Punctuation, whitespace and symbols merge into the neighbouring word
    (leading into the first, everything else into the preceding word), so the
    unit text slices always partition the canonical string.
    """
    if not verify_alignment(canonical, candidate):
        return None
    if item_samples < 0:
        return None
    if not canonical or not comparison_sequence(canonical):
        return () if not words else None

    candidate_indices = comparison_indices(candidate)
    canonical_indices = comparison_indices(canonical)
    if not words:
        return None

    mapped: list[AlignmentUnit] = []
    expected_position = 0
    previous_end_sample = 0
    for cand_start, cand_end, start_sample, end_sample in words:
        if not 0 <= cand_start < cand_end <= len(candidate):
            return None
        if not timestamps_within_item(start_sample, end_sample, item_samples=item_samples):
            return None
        if start_sample < previous_end_sample:
            return None
        previous_end_sample = end_sample

        positions = [
            position
            for position, index in enumerate(candidate_indices)
            if cand_start <= index < cand_end
        ]
        if not positions or positions[0] != expected_position:
            return None
        expected_position = positions[-1] + 1
        mapped.append(
            AlignmentUnit(
                text_start=canonical_indices[positions[0]],
                text_end=canonical_indices[positions[-1]] + 1,
                start_sample=start_sample,
                end_sample=end_sample,
            )
        )
    if expected_position != len(candidate_indices):
        return None

    merged: list[AlignmentUnit] = []
    for index, unit in enumerate(mapped):
        text_start = 0 if index == 0 else unit.text_start
        text_end = (
            mapped[index + 1].text_start
            if index + 1 < len(mapped)
            else len(canonical)
        )
        merged.append(
            AlignmentUnit(
                text_start=text_start,
                text_end=text_end,
                start_sample=unit.start_sample,
                end_sample=unit.end_sample,
            )
        )
    return tuple(merged)


def _comparison(text: str) -> tuple[str, tuple[int, ...]]:
    """Return the kept comparison characters and their source code point indices."""
    kept: list[str] = []
    indices: list[int] = []
    for index, char in enumerate(text):
        for normalized in unicodedata.normalize("NFKC", char):
            if normalized.isspace():
                continue
            if unicodedata.category(normalized)[0] not in _KEPT_CATEGORIES:
                continue
            kept.append(normalized)
            indices.append(index)
    return "".join(kept), tuple(indices)
