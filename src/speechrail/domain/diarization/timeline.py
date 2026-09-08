"""Small, transport-neutral timebase types for Realtime diarization."""

from __future__ import annotations

from dataclasses import dataclass

SAMPLE_RATE = 16_000


class Timeline:
    """Monotonic session-global sample clock over accepted PCM16 bytes."""

    __slots__ = ("_accepted_samples",)

    def __init__(self) -> None:
        self._accepted_samples = 0

    @property
    def accepted_samples(self) -> int:
        return self._accepted_samples

    def accept(self, pcm16: bytes) -> tuple[int, int]:
        """Account one PCM16 chunk and return its half-open sample span."""

        if len(pcm16) % 2:
            raise ValueError("timeline accepts even-length PCM16 bytes only")
        start = self._accepted_samples
        self._accepted_samples += len(pcm16) // 2
        return start, self._accepted_samples


@dataclass(frozen=True, slots=True)
class AttributionUnit:
    """Immutable client-facing text unit in the session-global sample domain."""

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
        if self.timing_quality not in {"aligned", "unavailable"}:
            raise ValueError("timing_quality must be aligned or unavailable")
