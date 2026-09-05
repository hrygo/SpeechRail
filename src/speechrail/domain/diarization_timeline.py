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
from collections import deque
from collections.abc import Sequence
from dataclasses import dataclass
from itertools import pairwise

from speechrail.domain.diarization import (
    ActivitySnapshot,
    DiarizationError,
    SpeakerActivity,
)

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


# ---------------------------------------------------------------------------
# R3: bounded attribution ledger over streaming activities

_ACTIVITY_RING_SAMPLES = 30 * SAMPLE_RATE


@dataclass(frozen=True, slots=True)
class AttributionUnit:
    """One immutable canonical-text unit awaiting speaker attribution.

    ``start_sample``/``end_sample`` are session-global; the text range can
    never be modified after construction (frozen dataclass), matching the
    contract that attribution revisions change speakers only.
    """

    segment_uid: str
    text_start: int
    text_end: int
    start_sample: int
    end_sample: int
    timing_quality: str

    def __post_init__(self) -> None:
        if not 0 < len(self.segment_uid) <= 128:
            raise ValueError("segment_uid must be 1-128 characters")
        if self.text_start < 0 or self.text_end < self.text_start:
            raise ValueError("invalid canonical text range")
        if self.start_sample < 0 or self.end_sample < self.start_sample:
            raise ValueError("invalid session sample range")
        if self.timing_quality not in ("aligned", "unavailable"):
            raise ValueError("timing_quality must be aligned or unavailable")


@dataclass(frozen=True, slots=True)
class AttributionResult:
    """One attribution revision for a registered unit."""

    segment_uid: str
    revision: int
    status: str
    speaker: str | None
    coverage_ratio: float
    overlap_ratio: float
    candidates: tuple[tuple[str, float], ...]


class _LedgerUnit:
    __slots__ = (
        "candidates",
        "consistent_steps",
        "coverage",
        "final",
        "overlap",
        "revision",
        "speaker",
        "status",
        "unit",
    )

    def __init__(self, unit: AttributionUnit) -> None:
        self.unit = unit
        self.revision = 0
        self.status = "tentative"
        self.speaker: str | None = None
        self.coverage = 0.0
        self.overlap = 0.0
        self.candidates: tuple[tuple[str, float], ...] = ()
        self.consistent_steps = 0
        self.final = False

    def content(self) -> tuple[object, ...]:
        return (
            self.status,
            self.speaker,
            self.coverage,
            self.overlap,
            self.candidates,
        )


class AttributionLedger:
    """Bounded, session-scoped unit attribution over streaming activities.

    Implements the SPK-E2E-1 section 4.4 policy: interval intersection per
    canonical unit, no pseudo-probability normalisation, overlap marked but
    never force-assigned, a 3-second automatic revision window terminated as
    unknown, stable only after two consistent inference steps once the
    activity watermark covers the word end, and an explicit freeze barrier.
    The ledger stores no PCM and no embeddings; its activity cache and unit
    table are hard-capped and overflow raises ``diarization_overloaded``
    instead of silently dropping units.
    """

    def __init__(
        self,
        *,
        revision_delay_samples: int = 3 * SAMPLE_RATE,
        coverage_min: float = 0.60,
        onset_min: float = 0.60,
        stable_margin: float = 0.20,
        overlap_min: float = 0.20,
        min_activity_samples: int = 0,
        stable_steps: int = 2,
        max_candidates: int = 4,
        max_pending_units: int = 4096,
        max_pending_duration_samples: int = 30 * SAMPLE_RATE,
    ) -> None:
        if revision_delay_samples < 0 or min_activity_samples < 0:
            raise ValueError("invalid ledger window configuration")
        if not 0 < coverage_min <= 1 or not 0 < onset_min <= 1:
            raise ValueError("invalid ledger threshold configuration")
        if not 0 <= stable_margin <= 1 or not 0 <= overlap_min <= 1:
            raise ValueError("invalid ledger threshold configuration")
        self._revision_delay = revision_delay_samples
        self._coverage_min = coverage_min
        self._onset_min = onset_min
        self._stable_margin = stable_margin
        self._overlap_min = overlap_min
        self._min_activity = min_activity_samples
        self._stable_steps = stable_steps
        self._max_candidates = max_candidates
        self._max_pending_units = max_pending_units
        self._max_pending_duration = max_pending_duration_samples
        self._units: dict[str, _LedgerUnit] = {}
        self._activities: deque[SpeakerActivity] = deque()
        self._processed_through = 0
        self._stable_through = 0

    @property
    def stable_through_sample(self) -> int:
        """Watermark before which attribution is no longer auto-revised."""
        return self._stable_through

    def register(self, unit: AttributionUnit) -> None:
        """Register one immutable unit; duplicate ids are rejected."""
        if unit.segment_uid in self._units:
            raise ValueError(f"segment_uid already registered: {unit.segment_uid}")
        if unit.timing_quality == "unavailable" or unit.end_sample <= unit.start_sample:
            self._units[unit.segment_uid] = self._terminate_unknown(unit)
            return
        pending_count = sum(1 for state in self._units.values() if not state.final)
        if pending_count + 1 > self._max_pending_units:
            raise DiarizationError(
                "pending attribution unit limit exceeded", code="diarization_overloaded"
            )
        if self._units:
            starts = [state.unit.start_sample for state in self._units.values() if not state.final]
            ends = [state.unit.end_sample for state in self._units.values() if not state.final]
            if starts and ends:
                span = max(max(ends), unit.end_sample) - min(min(starts), unit.start_sample)
                if span > self._max_pending_duration:
                    raise DiarizationError(
                        "pending attribution window exceeded", code="diarization_overloaded"
                    )
        state = _LedgerUnit(unit)
        self._units[unit.segment_uid] = state
        if unit.end_sample <= self._stable_through:
            # Late unit: decide once from the frozen activity cache; the
            # revision window is never reopened for it.
            self._evaluate(state)
            speaker = state.speaker
            state.status = "stable" if speaker is not None else "unknown"
            state.final = True

    def apply_activity(self, snapshot: ActivitySnapshot) -> tuple[AttributionResult, ...]:
        """Fold one activity snapshot; return results for changed units only."""
        self._processed_through = max(self._processed_through, snapshot.processed_through_sample)
        known = {(a.start_sample, a.end_sample, a.speaker) for a in self._activities}
        for activity in snapshot.activities:
            if activity.end_sample - activity.start_sample < self._min_activity:
                continue
            key = (activity.start_sample, activity.end_sample, activity.speaker)
            if key in known:
                continue
            known.add(key)
            self._activities.append(activity)
        self._trim_activities()

        changed: list[AttributionResult] = []
        for state in self._units.values():
            if state.final:
                continue
            before = state.content()
            if state.unit.end_sample + self._revision_delay <= self._processed_through:
                state.status = "unknown"
                state.speaker = None
                state.final = True
            else:
                self._evaluate(state)
                if (
                    state.speaker is not None
                    and self._processed_through >= state.unit.end_sample
                ):
                    state.consistent_steps += 1
                    if state.consistent_steps >= self._stable_steps:
                        state.status = "stable"
                        state.final = True
                else:
                    state.consistent_steps = 0
            if state.content() != before:
                state.revision += 1
                changed.append(self._result(state))

        self._stable_through = max(
            self._stable_through, self._processed_through - self._revision_delay
        )
        self._release_finalised()
        return tuple(changed)

    def freeze(self, through_sample: int) -> tuple[AttributionResult, ...]:
        """Freeze every unit ending at or before ``through_sample``."""
        changed: list[AttributionResult] = []
        for state in self._units.values():
            if state.final or state.unit.end_sample > through_sample:
                continue
            before = state.content()
            self._evaluate(state)
            state.status = "stable" if state.speaker is not None else "unknown"
            state.final = True
            if state.content() != before:
                state.revision += 1
                changed.append(self._result(state))
        self._stable_through = max(self._stable_through, through_sample)
        self._release_finalised()
        return tuple(changed)

    def unit_state(self, segment_uid: str) -> dict[str, object] | None:
        """Introspection helper for tests and degraded-state reporting."""
        state = self._units.get(segment_uid)
        if state is None:
            return None
        return {
            "status": state.status,
            "speaker": state.speaker,
            "revision": state.revision,
            "final": state.final,
        }

    def _evaluate(self, state: _LedgerUnit) -> None:
        start = state.unit.start_sample
        end = state.unit.end_sample
        duration = end - start
        relevant = [
            activity
            for activity in self._activities
            if activity.end_sample > start and activity.start_sample < end
        ]
        if duration <= 0 or not relevant:
            state.speaker = None
            state.coverage = 0.0
            state.overlap = 0.0
            state.candidates = ()
            return

        coverage = _covered_length(start, end, relevant) / duration
        support: dict[str, int] = {}
        for activity in relevant:
            overlap = min(end, activity.end_sample) - max(start, activity.start_sample)
            if overlap > 0:
                support[activity.speaker] = support.get(activity.speaker, 0) + overlap
        candidates = tuple(
            sorted(
                ((speaker, length / duration) for speaker, length in support.items()),
                key=lambda item: (-item[1], item[0]),
            )
        )
        overlap_ratio = _multi_speaker_length(start, end, relevant) / duration

        speaker: str | None = None
        if (
            overlap_ratio < self._overlap_min
            and coverage >= self._coverage_min
            and candidates
            and candidates[0][1] >= self._onset_min
            and (
                len(candidates) == 1
                or candidates[0][1] - candidates[1][1] >= self._stable_margin
            )
        ):
            speaker = candidates[0][0]
        state.speaker = speaker
        state.coverage = coverage
        state.overlap = overlap_ratio
        state.candidates = candidates[: self._max_candidates]

    def _terminate_unknown(self, unit: AttributionUnit) -> _LedgerUnit:
        state = _LedgerUnit(unit)
        state.status = "unknown"
        state.speaker = None
        state.final = True
        state.revision = 1
        return state

    def _trim_activities(self) -> None:
        keep_after = self._processed_through - _ACTIVITY_RING_SAMPLES
        while self._activities and self._activities[0].end_sample <= keep_after:
            self._activities.popleft()

    def _release_finalised(self) -> None:
        """Drop finalised units past the revision horizon; results were emitted."""
        for uid in [
            uid
            for uid, state in self._units.items()
            if state.final and state.unit.end_sample <= self._stable_through
        ]:
            del self._units[uid]

    def _result(self, state: _LedgerUnit) -> AttributionResult:
        return AttributionResult(
            segment_uid=state.unit.segment_uid,
            revision=state.revision,
            status=state.status,
            speaker=state.speaker,
            coverage_ratio=state.coverage,
            overlap_ratio=state.overlap,
            candidates=state.candidates,
        )


def _covered_length(start: int, end: int, activities: Sequence[SpeakerActivity]) -> int:
    """Total length of [start, end) covered by at least one activity."""
    points: list[int] = [start, end]
    for activity in activities:
        points.append(max(start, min(end, activity.start_sample)))
        points.append(max(start, min(end, activity.end_sample)))
    points = sorted(set(points))
    total = 0
    for left, right in pairwise(points):
        if right <= left:
            continue
        if any(
            activity.start_sample <= left and activity.end_sample >= right
            for activity in activities
        ):
            total += right - left
    return total


def _multi_speaker_length(start: int, end: int, activities: Sequence[SpeakerActivity]) -> int:
    """Total length of [start, end) covered by two or more distinct speakers."""
    points: list[int] = [start, end]
    for activity in activities:
        points.append(max(start, min(end, activity.start_sample)))
        points.append(max(start, min(end, activity.end_sample)))
    points = sorted(set(points))
    total = 0
    for left, right in pairwise(points):
        if right <= left:
            continue
        active = {
            activity.speaker
            for activity in activities
            if activity.start_sample <= left and activity.end_sample >= right
        }
        if len(active) >= 2:
            total += right - left
    return total
