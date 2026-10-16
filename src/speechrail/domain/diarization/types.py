"""Vendor-neutral types for anonymous, session-scoped diarization."""

from __future__ import annotations

import math
from dataclasses import dataclass

from speechrail.domain.audio_timeline import SampleSpan


class DiarizationError(ValueError):
    def __init__(self, message: str, *, code: str = "diarization_error") -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class ActivityFrame:
    span: SampleSpan
    scores: tuple[float, ...] | None
    active_slots: frozenset[int]
    reason: str | None = None

    def __post_init__(self) -> None:
        if self.reason not in {None, "identity_uncertain", "speaker_capacity", "activity_gap",
                               "audio_expired", "model_not_ready"}:
            raise ValueError("unknown activity reason")
        if self.scores is not None and (not 1 <= len(self.scores) <= 32 or any(
            not math.isfinite(score) or not 0 <= score <= 1 for score in self.scores
        )):
            raise ValueError("activity scores must be finite values in [0, 1]")
        if any(
            type(slot) is not int
            or not 0 <= slot < 32
            or (self.scores is not None and slot >= len(self.scores))
            for slot in self.active_slots
        ):
            raise ValueError("activity slots must be in [0, 31] and match score dimensions")


@dataclass(frozen=True, slots=True)
class ActivityUpdate:
    epoch: str
    step_id: int
    replace_span: SampleSpan
    frames: tuple[ActivityFrame, ...]
    processed_through: int
    stable_through: int

    def __post_init__(self) -> None:
        if not self.epoch or self.step_id < 0:
            raise ValueError("activity update requires an epoch and non-negative step id")
        if not 0 <= self.stable_through <= self.processed_through:
            raise ValueError("stable watermark must not exceed processed watermark")
        if any(
            not (
                self.replace_span.start
                <= frame.span.start
                <= frame.span.end
                <= self.replace_span.end
            )
            for frame in self.frames
        ):
            raise ValueError("activity frames must be contained by replace_span")


@dataclass(frozen=True, slots=True)
class TextUnit:
    id: str
    text_start: int
    text_end: int
    audio_span: SampleSpan | None

    def __post_init__(self) -> None:
        if not self.id or self.text_start < 0 or self.text_end <= self.text_start:
            raise ValueError("text unit must have an id and non-empty text range")


@dataclass(frozen=True, slots=True)
class Attribution:
    unit_id: str
    speaker: str | None
    active_speakers: tuple[str, ...]
    state: str
    reason: str | None
    revision: int

    def __post_init__(self) -> None:
        if self.state not in {"provisional", "final"} or self.revision < 1:
            raise ValueError("invalid attribution")
        if self.speaker is not None and self.speaker not in self.active_speakers:
            raise ValueError("primary speaker must be active")


@dataclass(frozen=True, slots=True)
class DiarizationReadiness:
    configured: bool
    ready: bool
    code: str | None
    message: str
    profile: str | None = None
