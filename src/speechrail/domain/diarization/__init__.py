"""Vendor-neutral, session-scoped speaker diarization domain package."""

from .types import (
    ActivityFrame,
    ActivityUpdate,
    AlignmentRequest,
    AlignmentResult,
    Attribution,
    DiarizationError,
    DiarizationReadiness,
    Span,
    TextUnit,
)

__all__ = [
    "ActivityFrame",
    "ActivityUpdate",
    "AlignmentRequest",
    "AlignmentResult",
    "Attribution",
    "DiarizationError",
    "DiarizationReadiness",
    "Span",
    "TextUnit",
]
