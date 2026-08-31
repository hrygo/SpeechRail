"""Vendor-independent speech recognition domain contracts."""

from speechrail.domain.contracts import (
    TranscriptResult,
    TranscriptSegment,
    TranscriptWindow,
    TranscriptWord,
)
from speechrail.domain.ports import AudioChunk, SpeechRequest, TranscriptionRequest

__all__ = [
    "AudioChunk",
    "SpeechRequest",
    "TranscriptResult",
    "TranscriptSegment",
    "TranscriptWindow",
    "TranscriptWord",
    "TranscriptionRequest",
]
