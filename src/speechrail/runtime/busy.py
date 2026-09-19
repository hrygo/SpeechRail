"""Stable low-cardinality reasons for retryable backend contention."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class BusyReason(StrEnum):
    """Internal contention cause; values are safe for metrics/protocol diagnostics."""

    ASR_MODE_CONFLICT = "asr_mode_conflict"
    REALTIME_SESSION_LIMIT = "realtime_session_limit"
    DIARIZATION_CAPACITY = "diarization_capacity"
    GOVERNOR_QUEUE_FULL = "governor_queue_full"
    BACKEND_TRANSITION = "backend_transition"
    BACKEND_UNAVAILABLE = "backend_unavailable"


@dataclass(frozen=True, slots=True)
class BusyRetryPolicy:
    """Stable retry guidance for a namespaced busy diagnostic."""

    retryable: bool
    hint: str


_WORKER_UNAVAILABLE_CODES = frozenset(
    {
        "worker_unavailable",
        "worker_not_ready",
        "worker_not_started",
        "worker_start_failed",
        "worker_invalid_start",
    }
)

_DEFAULT_BUSY_RETRY_POLICY = BusyRetryPolicy(retryable=True, hint="backoff_and_retry")
_BUSY_RETRY_POLICIES: dict[BusyReason, BusyRetryPolicy] = {
    BusyReason.ASR_MODE_CONFLICT: BusyRetryPolicy(
        retryable=True,
        hint="wait_for_asr_mode",
    ),
    BusyReason.REALTIME_SESSION_LIMIT: BusyRetryPolicy(
        retryable=True,
        hint="wait_for_realtime_session_slot",
    ),
    BusyReason.DIARIZATION_CAPACITY: BusyRetryPolicy(
        retryable=True,
        hint="wait_for_diarization_capacity",
    ),
    BusyReason.GOVERNOR_QUEUE_FULL: BusyRetryPolicy(
        retryable=True,
        hint="backoff_and_retry",
    ),
    BusyReason.BACKEND_TRANSITION: BusyRetryPolicy(
        retryable=True,
        hint="retry_after_backend_transition",
    ),
    BusyReason.BACKEND_UNAVAILABLE: BusyRetryPolicy(
        retryable=True,
        hint="retry_after_worker_recovery",
    ),
}


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


def busy_retry_policy(reason: BusyReason | str) -> BusyRetryPolicy:
    """Return bounded retry guidance for a busy reason or unknown extension."""

    try:
        normalized = BusyReason(reason)
    except (TypeError, ValueError):
        return _DEFAULT_BUSY_RETRY_POLICY
    return _BUSY_RETRY_POLICIES[normalized]


__all__ = [
    "BusyReason",
    "BusyRetryPolicy",
    "busy_retry_policy",
    "infer_backend_busy_reason",
]
