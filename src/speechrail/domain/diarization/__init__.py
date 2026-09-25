"""Vendor-neutral, session-scoped speaker diarization domain package."""

from speechrail.domain.audio_timeline import SampleSpan

from .types import (
    ActivityFrame,
    ActivityUpdate,
    Attribution,
    DiarizationError,
    DiarizationReadiness,
    TextUnit,
)

__all__ = [
    "ActivityFrame",
    "ActivityUpdate",
    "Attribution",
    "DiarizationError",
    "DiarizationReadiness",
    "SampleSpan",
    "TextUnit",
]
