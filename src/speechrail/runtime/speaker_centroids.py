"""Bounded, anonymous in-memory centroids for diarization reconnects."""

from __future__ import annotations

import math
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from time import monotonic


@dataclass
class _Group:
    centroids: dict[str, tuple[float, ...]] = field(default_factory=dict)
    counts: dict[str, int] = field(default_factory=dict)
    updated_at: float = 0.0


class SpeakerCentroidStore:
    """TTL-scoped anonymous acoustic state; it intentionally stores no PCM or names."""

    def __init__(
        self,
        *,
        max_groups: int,
        ttl_seconds: float,
        similarity_threshold: float,
        clock: Callable[[], float] = monotonic,
    ) -> None:
        if max_groups < 1 or ttl_seconds <= 0 or not 0 < similarity_threshold <= 1:
            raise ValueError("invalid centroid store limits")
        self._max_groups = max_groups
        self._ttl_seconds = ttl_seconds
        self._similarity_threshold = similarity_threshold
        self._clock = clock
        self._groups: dict[str, _Group] = {}

    @property
    def group_count(self) -> int:
        return len(self._groups)

    def assign(self, *, group_id: str, raw_label: str, embedding: Sequence[float]) -> str:
        if not group_id or not raw_label:
            raise ValueError("group_id and raw_label must be non-empty")
        vector = _unit(embedding)
        now = self._clock()
        self.expire(now=now)
        group = self._groups.get(group_id)
        if group is None:
            self._evict_if_full()
            group = _Group(updated_at=now)
            self._groups[group_id] = group
        canonical = self._best_match(group, vector)
        if canonical is None:
            canonical = raw_label if raw_label not in group.centroids else self._next_label(group)
        self._update(group, canonical, vector)
        group.updated_at = now
        return canonical

    def expire(self, *, now: float | None = None) -> None:
        current = self._clock() if now is None else now
        expired = [
            group_id
            for group_id, group in self._groups.items()
            if current - group.updated_at >= self._ttl_seconds
        ]
        for group_id in expired:
            del self._groups[group_id]

    def _evict_if_full(self) -> None:
        if len(self._groups) < self._max_groups:
            return
        oldest = min(self._groups, key=lambda group_id: self._groups[group_id].updated_at)
        del self._groups[oldest]

    def _best_match(self, group: _Group, vector: tuple[float, ...]) -> str | None:
        best_label: str | None = None
        best_score = -1.0
        for label, centroid in group.centroids.items():
            score = sum(left * right for left, right in zip(vector, centroid, strict=True))
            if score > best_score:
                best_score, best_label = score, label
        return best_label if best_score >= self._similarity_threshold else None

    @staticmethod
    def _next_label(group: _Group) -> str:
        number = 1
        while f"spk_{number:02d}" in group.centroids:
            number += 1
        return f"spk_{number:02d}"

    @staticmethod
    def _update(group: _Group, label: str, vector: tuple[float, ...]) -> None:
        previous = group.centroids.get(label)
        count = group.counts.get(label, 0)
        if previous is None:
            group.centroids[label] = vector
            group.counts[label] = 1
            return
        merged = tuple(
            (left * count + right) / (count + 1)
            for left, right in zip(previous, vector, strict=True)
        )
        group.centroids[label] = _unit(merged)
        group.counts[label] = count + 1


def _unit(values: Sequence[float]) -> tuple[float, ...]:
    vector = tuple(float(value) for value in values)
    if not vector:
        raise ValueError("embedding must be non-empty")
    length = math.sqrt(sum(value * value for value in vector))
    if length <= 1e-12:
        raise ValueError("embedding norm must be positive")
    return tuple(value / length for value in vector)
