"""Vendor-neutral, session-scoped speaker diarization contracts.

These types deliberately describe anonymous acoustic labels only.  Identity,
voiceprint enrolment and persistence belong to consuming applications.
"""

from __future__ import annotations

import math
import re
from collections.abc import Mapping
from dataclasses import dataclass

from pydantic import BaseModel, ConfigDict, Field, model_validator

_SPEAKER_ID = re.compile(r"^spk_[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
_GROUP_ID = re.compile(r"^[A-Za-z0-9_-]{16,128}$")


class DiarizationError(ValueError):
    """Stable, protocol-neutral failure from the diarization boundary."""

    def __init__(self, message: str, *, code: str = "diarization_error") -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class SpeakerActivity:
    """One anonymous activity interval in session-global samples.

    ``speaker`` is an opaque session-scoped label (never an identity); the
    interval bounds are integer samples at 16 kHz.
    """

    start_sample: int
    end_sample: int
    speaker: str
    activity_score: float

    def __post_init__(self) -> None:
        if self.start_sample < 0 or self.end_sample <= self.start_sample:
            raise DiarizationError(
                "activity interval must be ordered and non-empty",
                code="diarization_invalid_output",
            )
        if not self.speaker:
            raise DiarizationError(
                "activity speaker label must be non-empty",
                code="diarization_invalid_output",
            )
        if not math.isfinite(self.activity_score) or not 0.0 <= self.activity_score <= 1.0:
            raise DiarizationError(
                "activity score must be a finite number in [0, 1]",
                code="diarization_invalid_output",
            )


@dataclass(frozen=True, slots=True)
class ActivitySnapshot:
    """Bounded streaming diarization output up to one session sample position.

    ``stable_through_sample`` marks the watermark before which attribution is
    no longer revised automatically; it never claims correctness.
    """

    processed_through_sample: int
    stable_through_sample: int
    activities: tuple[SpeakerActivity, ...] = ()

    def __post_init__(self) -> None:
        if self.processed_through_sample < 0:
            raise DiarizationError(
                "processed watermark must be non-negative",
                code="diarization_invalid_output",
            )
        if not 0 <= self.stable_through_sample <= self.processed_through_sample:
            raise DiarizationError(
                "stable watermark must not exceed the processed watermark",
                code="diarization_invalid_output",
            )
        previous_end = 0
        for activity in self.activities:
            if activity.start_sample < previous_end:
                raise DiarizationError(
                    "activities must be ordered and non-overlapping",
                    code="diarization_invalid_output",
                )
            previous_end = activity.end_sample


@dataclass(frozen=True, slots=True)
class DiarizationReadiness:
    """Safe, path-free readiness information for an optional diarization profile."""

    configured: bool
    ready: bool
    code: str | None
    message: str
    profile: str | None = None


class DiarizationConfig(BaseModel):
    """An opt-in request for session-local speaker attribution."""

    model_config = ConfigDict(frozen=True, strict=True)

    enabled: bool = False
    speaker_count_hint: int | None = Field(default=None, ge=1, le=8)
    finalize: bool = True
    group_id: str | None = None

    @model_validator(mode="after")
    def validate_group_id(self) -> DiarizationConfig:
        if self.group_id is not None and _GROUP_ID.fullmatch(self.group_id) is None:
            raise ValueError("group_id must be an opaque 16-128 character identifier")
        return self


class DiarizationSpeaker(BaseModel):
    """One anonymous speaker active during an ASR segment."""

    model_config = ConfigDict(frozen=True, strict=True)

    id: str = Field(min_length=5, max_length=68)
    confidence: float = Field(ge=0, le=1)

    @model_validator(mode="after")
    def validate_id(self) -> DiarizationSpeaker:
        if _SPEAKER_ID.fullmatch(self.id) is None:
            raise ValueError("speaker id must be an anonymous spk_* label")
        return self


class DiarizationAssignment(BaseModel):
    """Speaker attribution for one immutable ASR segment, including overlap."""

    model_config = ConfigDict(frozen=True, strict=True)

    segment_id: int = Field(ge=0)
    speakers: tuple[DiarizationSpeaker, ...] = Field(min_length=1, max_length=8)
    revision: int = Field(default=1, ge=1)

    @model_validator(mode="after")
    def validate_speakers(self) -> DiarizationAssignment:
        if len({speaker.id for speaker in self.speakers}) != len(self.speakers):
            raise ValueError("speaker ids must be unique within an assignment")
        return self

    @property
    def primary_speaker_id(self) -> str:
        """The highest-confidence label preserves legacy single-speaker displays."""
        return max(self.speakers, key=lambda speaker: speaker.confidence).id


class DiarizationUpdate(BaseModel):
    """Validated backend output for segment labels and commit-time reconciliation."""

    model_config = ConfigDict(frozen=True, strict=True)

    assignments: tuple[DiarizationAssignment, ...] = ()
    mapping: dict[str, str] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_mapping(self) -> DiarizationUpdate:
        for source, target in self.mapping.items():
            if _SPEAKER_ID.fullmatch(source) is None or _SPEAKER_ID.fullmatch(target) is None:
                raise ValueError("mapping keys and values must be anonymous spk_* labels")
            if source == target:
                raise ValueError("speaker mapping must not map to itself")
        for source in self.mapping:
            visited: set[str] = set()
            current = source
            while current in self.mapping:
                if current in visited:
                    raise ValueError("speaker mapping must not contain a cycle")
                visited.add(current)
                current = self.mapping[current]
        return self

    def canonical_mapping(self) -> Mapping[str, str]:
        """Collapse chains so application clients can apply one atomic remap."""
        resolved: dict[str, str] = {}
        for source in self.mapping:
            target = self.mapping[source]
            while target in self.mapping:
                target = self.mapping[target]
            resolved[source] = target
        return resolved
