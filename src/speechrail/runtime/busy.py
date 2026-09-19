"""Stable low-cardinality reasons for retryable backend contention."""

from __future__ import annotations

from enum import StrEnum


class BusyReason(StrEnum):
    """Internal contention cause; values are safe for metrics/protocol diagnostics."""

    ASR_MODE_CONFLICT = "asr_mode_conflict"
    REALTIME_SESSION_LIMIT = "realtime_session_limit"
    DIARIZATION_CAPACITY = "diarization_capacity"
    GOVERNOR_QUEUE_FULL = "governor_queue_full"
    BACKEND_TRANSITION = "backend_transition"


__all__ = ["BusyReason"]
