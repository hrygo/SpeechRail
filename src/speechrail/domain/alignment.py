"""Fixed-text alignment port and its public domain types.

Alignment is an independent capability: it receives a frozen transcript
revision, the exact PCM span that produced it and a language, and it never runs
recognition.  The types here are deliberately decoupled from diarization so a
request that only wants timestamps never acquires speaker state.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Protocol

from speechrail.domain.audio_timeline import PCM_SAMPLE_BYTES, SampleSpan

AlignmentGranularity = Literal["segment", "word", "character"]
ALIGNMENT_GRANULARITIES: tuple[AlignmentGranularity, ...] = (
    "segment",
    "word",
    "character",
)


@dataclass(frozen=True, slots=True)
class AlignmentUnit:
    """One immutable text unit mapped onto the session sample axis."""

    unit_id: str
    text_start: int
    text_end: int
    audio_span: SampleSpan | None
    granularity: AlignmentGranularity

    def __post_init__(self) -> None:
        if not self.unit_id:
            raise ValueError("alignment unit requires an id")
        if self.text_start < 0 or self.text_end <= self.text_start:
            raise ValueError("alignment unit requires a non-empty text range")
        if self.granularity not in ALIGNMENT_GRANULARITIES:
            raise ValueError("alignment unit requires a known granularity")


@dataclass(frozen=True, slots=True)
class AlignmentRequest:
    """Frozen text revision plus the exact PCM span it was decoded from."""

    task_id: str
    epoch: str
    utterance_id: str
    transcript_revision: int
    pcm16: bytes
    span: SampleSpan
    text: str
    language: str | None
    granularity: AlignmentGranularity = "segment"

    def __post_init__(self) -> None:
        if not self.task_id or not self.epoch or not self.utterance_id:
            raise ValueError("alignment requires task, epoch and utterance identity")
        if self.transcript_revision < 1:
            raise ValueError("alignment requires a positive transcript revision")
        if not self.text:
            raise ValueError("alignment requires fixed text")
        if self.granularity not in ALIGNMENT_GRANULARITIES:
            raise ValueError("alignment requires a known granularity")
        if len(self.pcm16) % PCM_SAMPLE_BYTES:
            raise ValueError("alignment span must own whole PCM16 samples")
        if self.span.length != len(self.pcm16) // PCM_SAMPLE_BYTES:
            raise ValueError("alignment span must exactly own PCM16")


@dataclass(frozen=True, slots=True)
class AlignmentResult:
    """Either finished units or an explicit failure; never a silent ``[]``."""

    task_id: str
    epoch: str
    utterance_id: str
    transcript_revision: int
    units: tuple[AlignmentUnit, ...]
    failure: str | None = None

    def __post_init__(self) -> None:
        if not self.task_id or not self.epoch or not self.utterance_id:
            raise ValueError("alignment result requires task, epoch and utterance identity")
        if self.transcript_revision < 1:
            raise ValueError("alignment result requires a positive transcript revision")
        if (self.failure is None) == (not self.units):
            raise ValueError("alignment result must be either units or a failure")

    @property
    def status(self) -> Literal["done", "failed"]:
        return "failed" if self.failure is not None else "done"


class AlignTextPort(Protocol):
    """Consumer-facing boundary; implementations own the aligner process."""

    async def align(self, request: AlignmentRequest) -> AlignmentResult: ...


__all__ = [
    "ALIGNMENT_GRANULARITIES",
    "AlignTextPort",
    "AlignmentGranularity",
    "AlignmentRequest",
    "AlignmentResult",
    "AlignmentUnit",
]
