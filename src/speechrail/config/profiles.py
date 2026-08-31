"""Capability declarations for independently deployable ASR runtimes."""

from __future__ import annotations

from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field


class Capability(StrEnum):
    BATCH = "batch"
    REALTIME = "realtime"
    LEGACY_WLK = "legacy_wlk"
    SEGMENT_TIMESTAMPS = "segment_timestamps"
    WORD_TIMESTAMPS = "word_timestamps"
    DIARIZATION = "diarization"
    TRANSLATION = "translation"


class RuntimeProfile(BaseModel):
    """Capabilities published by one backend without exposing vendor types."""

    model_config = ConfigDict(frozen=True)

    name: str = Field(min_length=1, max_length=100)
    capabilities: frozenset[Capability] = Field(min_length=1)
