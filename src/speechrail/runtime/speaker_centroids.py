"""Bounded, anonymous in-memory centroids for diarization reconnects."""

from __future__ import annotations

import hashlib
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


# ---------------------------------------------------------------------------
# R3: multi-evidence speaker matching with generation isolation


@dataclass(frozen=True, slots=True)
class SpeakerLinkSuggestion:
    """One anonymous cross-session link suggestion (contract 5.3 payload shape).

    ``relation`` is always ``same_speaker`` and is attached by the caller.
    This is a non-transitive suggestion, never an identity merge.
    """

    from_session_id: str
    from_speaker: str
    to_session_id: str
    to_speaker: str
    similarity: float


@dataclass
class _EvidenceClip:
    start_sample: int
    end_sample: int
    embedding: tuple[float, ...]
    similarity: float


@dataclass
class _EvidenceGroup:
    centroids: dict[str, tuple[float, ...]] = field(default_factory=dict)
    summary_counts: dict[str, int] = field(default_factory=dict)
    clips: dict[tuple[str, str], list[_EvidenceClip]] = field(default_factory=dict)
    aliases: dict[tuple[str, str], str] = field(default_factory=dict)
    alias_confidence: dict[tuple[str, str], float] = field(default_factory=dict)
    alias_sessions: list[str] = field(default_factory=list)
    updated_at: float = 0.0


class SpeakerEvidenceIndex:
    """Bounded multi-evidence speaker matching, isolated per group generation.

    CAM++ policy (design 4.5): one raw label is only renamed to a canonical
    centroid after at least two non-overlapping clean clips match it.  The
    index stores unit vectors and clip summaries only - never PCM - with hard
    caps on centroids per group, summaries per centroid, and recent session
    aliases.  ``generation`` is derived from the model fingerprint and a
    process seed; a different fingerprint or process restart yields a
    different generation, and consumers must never link across generations.
    """

    def __init__(
        self,
        *,
        max_groups: int,
        ttl_seconds: float,
        model_fingerprint: str,
        generation_seed: str,
        similarity_threshold: float = 0.80,
        candidate_margin: float = 0.10,
        min_clips: int = 2,
        max_centroids_per_group: int = 4,
        max_summaries_per_centroid: int = 8,
        max_session_aliases: int = 4,
        max_clips_per_label: int = 8,
        clock: Callable[[], float] = monotonic,
    ) -> None:
        if max_groups < 1 or ttl_seconds <= 0 or not 0 < similarity_threshold <= 1:
            raise ValueError("invalid evidence index limits")
        if not model_fingerprint or not generation_seed:
            raise ValueError("model_fingerprint and generation_seed are required")
        self._max_groups = max_groups
        self._ttl_seconds = ttl_seconds
        self._similarity_threshold = similarity_threshold
        self._candidate_margin = candidate_margin
        self._min_clips = min_clips
        self._max_centroids = max_centroids_per_group
        self._max_summaries = max_summaries_per_centroid
        self._max_session_aliases = max_session_aliases
        self._max_clips_per_label = max_clips_per_label
        self._clock = clock
        self._groups: dict[str, _EvidenceGroup] = {}
        self._embedding_dim: int | None = None
        digest = hashlib.sha256(
            f"{model_fingerprint}|{generation_seed}".encode()
        ).hexdigest()
        self._generation = f"gen_{digest[:32]}"

    @property
    def generation(self) -> str:
        """Opaque generation id; changes when the model or process changes."""
        return self._generation

    @property
    def group_count(self) -> int:
        return len(self._groups)

    def observe(
        self,
        *,
        group_id: str,
        session_id: str,
        raw_label: str,
        embedding: Sequence[float],
        clip_start_sample: int,
        clip_end_sample: int,
    ) -> str | None:
        """Record one clip observation.

        Returns the canonical label once the raw label has gathered at least
        ``min_clips`` non-overlapping clips matching the same centroid, else
        ``None``.  Overlapping or duplicate-span clips do not count.
        """
        if not group_id or not session_id or not raw_label:
            raise ValueError("group_id, session_id and raw_label must be non-empty")
        vector = _unit(embedding)
        if self._embedding_dim is None:
            self._embedding_dim = len(vector)
        elif len(vector) != self._embedding_dim:
            raise ValueError("embedding dimension mismatch with model manifest")
        now = self._clock()
        self.expire(now=now)
        group = self._groups.get(group_id)
        if group is None:
            self._evict_if_full()
            group = _EvidenceGroup(updated_at=now)
            self._groups[group_id] = group
        group.updated_at = now

        key = (session_id, raw_label)
        clips = group.clips.setdefault(key, [])
        overlaps_existing = any(
            max(clip.start_sample, clip_start_sample) < min(clip.end_sample, clip_end_sample)
            for clip in clips
        )
        if overlaps_existing:
            return group.aliases.get(key)

        canonical, similarity = self._match(group, vector)
        if canonical is None:
            if len(group.centroids) >= self._max_centroids:
                return None
            canonical = self._next_label(group)
            group.centroids[canonical] = vector
            group.summary_counts[canonical] = 1
            similarity = 1.0
        clips.append(
            _EvidenceClip(
                start_sample=clip_start_sample,
                end_sample=clip_end_sample,
                embedding=vector,
                similarity=similarity,
            )
        )
        if len(clips) > self._max_clips_per_label:
            del clips[0]
        self._merge_summary(group, canonical, vector)

        threshold = self._similarity_threshold
        matched = [
            clip
            for clip in clips
            if self._cosine(clip.embedding, group.centroids[canonical]) >= threshold
        ]
        non_overlapping: list[_EvidenceClip] = []
        for clip in matched:
            if all(
                max(clip.start_sample, kept.start_sample) >= min(clip.end_sample, kept.end_sample)
                for kept in non_overlapping
            ):
                non_overlapping.append(clip)
        if len(non_overlapping) >= self._min_clips:
            self._confirm_alias(group, session_id, raw_label, canonical, similarity)
            return canonical
        return None

    def suggest_links(
        self, *, group_id: str, session_id: str
    ) -> tuple[SpeakerLinkSuggestion, ...]:
        """Session-scoped link suggestions for aliases sharing a canonical."""
        group = self._groups.get(group_id)
        if group is None:
            return ()
        own = {
            canonical: raw
            for (sid, raw), canonical in group.aliases.items()
            if sid == session_id
        }
        suggestions: list[SpeakerLinkSuggestion] = []
        for (sid, raw), canonical in group.aliases.items():
            if sid == session_id or canonical not in own:
                continue
            confidence = min(
                group.alias_confidence.get((sid, raw), 0.0),
                group.alias_confidence.get((session_id, own[canonical]), 0.0),
            )
            suggestions.append(
                SpeakerLinkSuggestion(
                    from_session_id=sid,
                    from_speaker=raw,
                    to_session_id=session_id,
                    to_speaker=own[canonical],
                    similarity=round(confidence, 6),
                )
            )
        return tuple(suggestions)

    def release_session(self, *, group_id: str, session_id: str) -> None:
        """Drop one session's temporary clips and aliases (also on error paths)."""
        group = self._groups.get(group_id)
        if group is None:
            return
        for key in [key for key in group.clips if key[0] == session_id]:
            del group.clips[key]
        for key in [key for key in group.aliases if key[0] == session_id]:
            del group.aliases[key]
            group.alias_confidence.pop(key, None)
        if session_id in group.alias_sessions:
            group.alias_sessions.remove(session_id)

    def expire(self, *, now: float | None = None) -> None:
        current = self._clock() if now is None else now
        expired = [
            group_id
            for group_id, group in self._groups.items()
            if current - group.updated_at >= self._ttl_seconds
        ]
        for group_id in expired:
            del self._groups[group_id]

    def _match(
        self, group: _EvidenceGroup, vector: tuple[float, ...]
    ) -> tuple[str | None, float]:
        scored = sorted(
            (
                (self._cosine(vector, centroid), label)
                for label, centroid in group.centroids.items()
            ),
            reverse=True,
        )
        if not scored or scored[0][0] < self._similarity_threshold:
            return None, 0.0
        if len(scored) > 1 and scored[0][0] - scored[1][0] < self._candidate_margin:
            return None, 0.0
        return scored[0][1], scored[0][0]

    def _merge_summary(
        self, group: _EvidenceGroup, canonical: str, vector: tuple[float, ...]
    ) -> None:
        count = group.summary_counts.get(canonical, 0)
        if count >= self._max_summaries:
            return
        previous = group.centroids[canonical]
        merged = tuple(
            (left * count + right) / (count + 1)
            for left, right in zip(previous, vector, strict=True)
        )
        group.centroids[canonical] = _unit(merged)
        group.summary_counts[canonical] = count + 1

    def _confirm_alias(
        self,
        group: _EvidenceGroup,
        session_id: str,
        raw_label: str,
        canonical: str,
        similarity: float,
    ) -> None:
        key = (session_id, raw_label)
        group.aliases[key] = canonical
        group.alias_confidence[key] = max(
            group.alias_confidence.get(key, 0.0), similarity
        )
        if session_id not in group.alias_sessions:
            group.alias_sessions.append(session_id)
        while len(group.alias_sessions) > self._max_session_aliases:
            evicted = group.alias_sessions.pop(0)
            for key in [key for key in group.aliases if key[0] == evicted]:
                del group.aliases[key]
                group.alias_confidence.pop(key, None)

    def _evict_if_full(self) -> None:
        if len(self._groups) < self._max_groups:
            return
        oldest = min(self._groups, key=lambda gid: self._groups[gid].updated_at)
        del self._groups[oldest]

    @staticmethod
    def _cosine(left: tuple[float, ...], right: tuple[float, ...]) -> float:
        return sum(a * b for a, b in zip(left, right, strict=True))

    @staticmethod
    def _next_label(group: _EvidenceGroup) -> str:
        number = 1
        while f"spk_{number:02d}" in group.centroids:
            number += 1
        return f"spk_{number:02d}"
