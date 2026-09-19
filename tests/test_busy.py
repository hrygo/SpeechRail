"""Stable backend contention-reason classification tests."""

from __future__ import annotations

from speechrail.runtime.busy import BusyReason, busy_retry_policy, infer_backend_busy_reason


def test_worker_failures_have_a_distinct_busy_reason() -> None:
    for code in (
        "worker_unavailable",
        "worker_not_ready",
        "worker_not_started",
        "worker_start_failed",
        "worker_invalid_start",
    ):
        assert infer_backend_busy_reason(RuntimeError(code)) == BusyReason.BACKEND_UNAVAILABLE

    assert infer_backend_busy_reason(
        RuntimeError("worker_start_failed; worker stderr tail: unavailable")
    ) == BusyReason.BACKEND_UNAVAILABLE


def test_generic_backend_failures_remain_transition_reason() -> None:
    assert infer_backend_busy_reason(RuntimeError("backend_identity_mismatch")) == (
        BusyReason.BACKEND_TRANSITION
    )


def test_explicit_busy_reason_wins_over_message_classification() -> None:
    class ExplicitBusyError(RuntimeError):
        busy_reason = BusyReason.ASR_MODE_CONFLICT

    assert infer_backend_busy_reason(ExplicitBusyError("worker_unavailable")) == (
        BusyReason.ASR_MODE_CONFLICT
    )


def test_busy_retry_policy_is_stable_and_low_cardinality() -> None:
    assert busy_retry_policy(BusyReason.REALTIME_SESSION_LIMIT).retryable is True
    assert busy_retry_policy(BusyReason.REALTIME_SESSION_LIMIT).hint == (
        "wait_for_realtime_session_slot"
    )
    assert busy_retry_policy(BusyReason.BACKEND_UNAVAILABLE).hint == (
        "retry_after_worker_recovery"
    )
    assert busy_retry_policy("future_reason").hint == "backoff_and_retry"
