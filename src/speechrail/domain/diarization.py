"""Vendor-neutral, session-scoped speaker diarization contracts.

These types deliberately describe anonymous acoustic labels only.  Identity,
voiceprint enrolment and persistence belong to consuming applications.
"""

from __future__ import annotations

import re
from collections.abc import Mapping

from pydantic import BaseModel, ConfigDict, Field, model_validator

_SPEAKER_ID = re.compile(r"^spk_[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


class DiarizationConfig(BaseModel):
    """An opt-in request for session-local speaker attribution."""

    model_config = ConfigDict(frozen=True, strict=True)

    enabled: bool = False
    speaker_count_hint: int | None = Field(default=None, ge=1, le=8)
    finalize: bool = True


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

    segment_id: str = Field(min_length=1, max_length=200)
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
