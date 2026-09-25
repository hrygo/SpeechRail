"""Unit tests for the bounded PCM pin used by auxiliary inference tasks."""

from __future__ import annotations

import pytest

from speechrail.runtime.limits import (
    MAX_ALIGNMENT_PCM_BYTES,
    MAX_PCM_BYTES,
    PCM_SAMPLE_BYTES,
)
from speechrail.runtime.pcm_buffer import BoundedPcmBuffer, PcmBufferOverflowError


def test_buffer_accepts_exactly_capacity_and_reports_remaining() -> None:
    buffer = BoundedPcmBuffer(4 * PCM_SAMPLE_BYTES)

    buffer.append(b"\x00\x00" * 2)
    assert len(buffer) == 4
    assert buffer.remaining_bytes == 4 * PCM_SAMPLE_BYTES - 4

    buffer.append(b"\x00\x00" * 2)
    assert len(buffer) == 8
    assert buffer.remaining_bytes == 0


def test_buffer_overflow_is_explicit_and_never_partially_writes() -> None:
    buffer = BoundedPcmBuffer(2 * PCM_SAMPLE_BYTES)
    buffer.append(b"\x01\x02\x03\x04")

    with pytest.raises(PcmBufferOverflowError):
        buffer.append(b"\x05\x06")

    # The failed append is rejected whole; the original span is intact.
    assert buffer.pin() == b"\x01\x02\x03\x04"


def test_buffer_rejects_odd_pcm_and_degenerate_capacity() -> None:
    with pytest.raises(ValueError, match="whole PCM16 samples"):
        BoundedPcmBuffer(PCM_SAMPLE_BYTES + 1)
    with pytest.raises(ValueError, match="at least one sample"):
        BoundedPcmBuffer(0)

    buffer = BoundedPcmBuffer(4 * PCM_SAMPLE_BYTES)
    with pytest.raises(ValueError, match="whole PCM16 samples"):
        buffer.append(b"\x00")


def test_pin_snapshots_before_clear_so_auxiliary_task_keeps_exact_samples() -> None:
    buffer = BoundedPcmBuffer(4 * PCM_SAMPLE_BYTES)
    buffer.append(b"\xaa\xbb" * 2)

    pinned = buffer.pin()
    buffer.clear()

    assert len(buffer) == 0
    assert pinned == b"\xaa\xbb" * 2


def test_retention_bounds_account_against_one_global_budget() -> None:
    # The per-item alignment pin is far smaller than the global retained-PCM cap
    # and is a slice of that budget rather than an extra per-role reservation.
    assert MAX_ALIGNMENT_PCM_BYTES == 30 * 32_000
    assert MAX_ALIGNMENT_PCM_BYTES < MAX_PCM_BYTES
