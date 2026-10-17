"""Whole-session consolidation of streaming Sortformer slot activity.

The streaming Sortformer emits one four-slot sigmoid observation per hop.
Turned directly into spans, those raw frames carry three artefacts: short
spurious blips, single-speaker dropouts, and a low-support "ghost" slot the
tracker creates when it re-clusters one speaker after a pause.  This module
converts the raw per-frame activity of a whole session into a small, stable set
of speaker turns.  It owns no model, worker, or I/O: it is a pure, deterministic
post-pass over :class:`ActivityFrame` values already produced by the adapter.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass

from speechrail.domain.diarization.types import ActivityFrame

_SPAN_TUPLE = tuple[float, float]
_CONTIGUOUS_TOLERANCE_SECONDS = 1e-6


@dataclass(frozen=True, slots=True)
class SlotConsolidationConfig:
    """Whole-session consolidation knobs; the defaults are the Phase 1 candidate."""

    sample_rate: int = 16_000
    bridge_seconds: float = 0.24
    min_turn_seconds: float = 0.32
    ghost_support_fraction: float = 0.10
    ghost_max_seconds: float = 6.0

    def __post_init__(self) -> None:
        if self.sample_rate <= 0:
            raise ValueError("sample_rate must be positive")
        if not self.min_turn_seconds > 0:
            raise ValueError("min_turn_seconds must be positive")
        if not self.bridge_seconds >= 0:
            raise ValueError("bridge_seconds must be non-negative")
        if not 0 <= self.ghost_support_fraction <= 1:
            raise ValueError("ghost_support_fraction must be in [0, 1]")
        if not self.ghost_max_seconds >= 0:
            raise ValueError("ghost_max_seconds must be non-negative")


def consolidate_slot_spans(
    frames: Sequence[ActivityFrame],
    *,
    duration: float,
    config: SlotConsolidationConfig = SlotConsolidationConfig(),  # noqa: B008
) -> list[dict[str, object]]:
    """Consolidate raw slot activity frames into whole-session speaker spans.

    Spans are returned as ``{"start", "end", "speaker"}`` mappings sorted by
    ``(start, end, speaker)``, where ``speaker`` is ``"S{slot + 1}"`` for the
    surviving slot index.  Consolidation applies, in order: contiguous per-slot
    merging, gap bridging, minimum-turn filtering, and low-support ghost
    re-attribution.  The function is pure and deterministic.
    """

    if not math.isfinite(duration) or duration < 0:
        raise ValueError("duration must be finite and non-negative")

    per_slot = _raw_slot_spans(
        frames, duration=duration, sample_rate=config.sample_rate
    )
    per_slot = {
        slot: _bridge(spans, bridge_seconds=config.bridge_seconds)
        for slot, spans in per_slot.items()
    }
    per_slot = {
        slot: [span for span in spans if span[1] - span[0] >= config.min_turn_seconds]
        for slot, spans in per_slot.items()
    }
    per_slot = _merge_ghosts(per_slot, duration=duration, config=config)
    return _emit_spans(per_slot)


def _raw_slot_spans(
    frames: Sequence[ActivityFrame], *, duration: float, sample_rate: int
) -> dict[int, list[_SPAN_TUPLE]]:
    """Convert frames into per-slot spans, merging contiguous observations."""

    per_slot: dict[int, list[_SPAN_TUPLE]] = {}
    for frame in frames:
        start_seconds = _clamp(frame.span.start / sample_rate, duration)
        end_seconds = _clamp(frame.span.end / sample_rate, duration)
        if end_seconds <= start_seconds:
            continue
        for slot in frame.active_slots:
            spans = per_slot.setdefault(slot, [])
            if spans and abs(spans[-1][1] - start_seconds) <= _CONTIGUOUS_TOLERANCE_SECONDS:
                spans[-1] = (spans[-1][0], end_seconds)
            else:
                spans.append((start_seconds, end_seconds))
    return per_slot


def _bridge(spans: list[_SPAN_TUPLE], *, bridge_seconds: float) -> list[_SPAN_TUPLE]:
    """Merge spans separated by a gap no wider than ``bridge_seconds``."""

    if not spans:
        return []
    merged: list[_SPAN_TUPLE] = [min(spans)]
    for start_seconds, end_seconds in sorted(spans):
        previous_start, previous_end = merged[-1]
        if start_seconds - previous_end <= bridge_seconds:
            merged[-1] = (previous_start, max(previous_end, end_seconds))
        else:
            merged.append((start_seconds, end_seconds))
    return merged


def _merge_ghosts(
    per_slot: dict[int, list[_SPAN_TUPLE]],
    *,
    duration: float,
    config: SlotConsolidationConfig,
) -> dict[int, list[_SPAN_TUPLE]]:
    """Re-attribute a low-support ghost slot to the one slot it duplicates."""

    active = {slot: list(spans) for slot, spans in per_slot.items() if spans}
    if len(active) <= 1:
        return {slot: list(spans) for slot, spans in per_slot.items()}

    totals = {
        slot: sum(end - start for start, end in spans)
        for slot, spans in active.items()
    }
    dominant = max(sorted(active), key=lambda slot: totals[slot])
    threshold = min(config.ghost_max_seconds, config.ghost_support_fraction * duration)

    for ghost in sorted(active):
        if ghost == dominant or totals[ghost] > threshold:
            continue
        ghost_spans = active[ghost]
        if not ghost_spans:
            continue
        zero_overlap = [
            slot
            for slot, spans in active.items()
            if slot != ghost and spans and not _overlaps_any(spans, ghost_spans)
        ]
        if len(zero_overlap) != 1:
            continue
        target = zero_overlap[0]
        active[target] = _bridge(
            active[target] + ghost_spans, bridge_seconds=config.bridge_seconds
        )
        active[ghost] = []
    return active


def _overlaps_any(spans: list[_SPAN_TUPLE], other: list[_SPAN_TUPLE]) -> bool:
    """Return whether any span in ``spans`` overlaps any span in ``other``."""

    return any(
        start < other_end and other_start < end
        for start, end in spans
        for other_start, other_end in other
    )


def _emit_spans(per_slot: dict[int, list[_SPAN_TUPLE]]) -> list[dict[str, object]]:
    """Flatten per-slot spans into sorted ``{"start", "end", "speaker"}`` rows."""

    rows: list[tuple[float, float, str]] = []
    for slot, spans in per_slot.items():
        speaker = f"S{slot + 1}"
        rows.extend((start, end, speaker) for start, end in spans)
    rows.sort()
    return [
        {"start": start, "end": end, "speaker": speaker}
        for start, end, speaker in rows
    ]


def _clamp(seconds: float, duration: float) -> float:
    """Clamp a converted position into ``[0, duration]``."""

    return max(0.0, min(duration, seconds))


__all__ = ["SlotConsolidationConfig", "consolidate_slot_spans"]
