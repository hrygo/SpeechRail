"""Vendor-independent speech recognition domain contracts."""

from speechrail.domain.contracts import (
    TranscriptResult,
    TranscriptSegment,
    TranscriptWindow,
    TranscriptWord,
)

__all__ = ["TranscriptResult", "TranscriptSegment", "TranscriptWindow", "TranscriptWord"]
