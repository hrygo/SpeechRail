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
    BACKEND_UNAVAILABLE = "backend_unavailable"


_WORKER_UNAVAILABLE_CODES = frozenset(
    {
        "worker_unavailable",
        "worker_not_ready",
        "worker_not_started",
        "worker_start_failed",
        "worker_invalid_start",
    }
)


def infer_backend_busy_reason(exc: BaseException) -> BusyReason | str:
    """Classify a backend admission failure without changing its public error code.

    Explicit typed reasons remain authoritative. Worker lifecycle failures are
    separated from a generic backend transition so callers can choose a
    reconnect/backoff policy without exposing exception text as a metric label.
    """

    explicit = getattr(exc, "busy_reason", None)
    if isinstance(explicit, (BusyReason, str)) and str(explicit):
        return explicit
    code = getattr(exc, "code", None)
    message = str(exc)
    message_code = message.split(";", 1)[0].strip()
    if code in _WORKER_UNAVAILABLE_CODES or message_code in _WORKER_UNAVAILABLE_CODES:
        return BusyReason.BACKEND_UNAVAILABLE
    return BusyReason.BACKEND_TRANSITION


__all__ = ["BusyReason", "infer_backend_busy_reason"]
