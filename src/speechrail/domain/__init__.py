"""Vendor-independent speech recognition domain contracts."""

from speechrail.domain.contracts import (
    TranscriptResult,
    TranscriptSegment,
    TranscriptWindow,
    TranscriptWord,
)
from speechrail.domain.ports import AudioChunk, SpeechRequest, TranscriptionRequest
from speechrail.domain.resource_limits import GovernorLimits

__all__ = [
    "AudioChunk",
    "GovernorLimits",
    "SpeechRequest",
    "TranscriptResult",
    "TranscriptSegment",
    "TranscriptWindow",
    "TranscriptWord",
    "TranscriptionRequest",
]
