"""ASR batch/streaming 模式同步准入门测试。"""

from __future__ import annotations

import weakref
from typing import cast

import pytest

from speechrail.runtime.asr_mode import AsrModeBusy, AsrModeGate


def test_batch_cannot_enter_unfinished_stream() -> None:
    gate = AsrModeGate()

    stream_lease = gate.acquire("streaming")
    assert gate.active_mode == "streaming"
    assert gate.active_count == 1

    with pytest.raises(AsrModeBusy, match="streaming"):
        gate.acquire("batch")

    gate.release(stream_lease)
    batch_lease = gate.acquire("batch")
    assert gate.active_mode == "batch"
    assert gate.active_count == 1
    gate.release(batch_lease)


def test_active_batch_rejects_second_batch_and_streaming() -> None:
    gate = AsrModeGate()
    batch_lease = gate.acquire("batch")

    with pytest.raises(AsrModeBusy, match="batch"):
        gate.acquire("batch")
    with pytest.raises(AsrModeBusy, match="batch"):
        gate.acquire("streaming")

    assert gate.active_mode == "batch"
    assert gate.active_count == 1
    gate.release(batch_lease)


def test_one_stream_finishing_does_not_release_another() -> None:
    gate = AsrModeGate()

    first = gate.acquire("streaming")
    second = gate.acquire("streaming")
    assert gate.active_count == 2

    gate.release(first)
    assert gate.active_mode == "streaming"
    assert gate.active_count == 1
    with pytest.raises(AsrModeBusy, match="streaming"):
        gate.acquire("batch")

    gate.release(second)
    assert gate.active_mode is None
    assert gate.active_count == 0


def test_releasing_a_lease_is_idempotent() -> None:
    gate = AsrModeGate()
    lease = gate.acquire("batch")
    assert lease.released is False

    gate.release(lease)
    assert lease.released is True
    gate.release(lease)

    assert gate.active_mode is None
    assert gate.active_count == 0


def test_invalid_mode_is_rejected() -> None:
    gate = AsrModeGate()

    with pytest.raises(ValueError, match="mode"):
        gate.acquire(cast("object", "invalid"))


def test_forged_and_cross_gate_leases_are_rejected() -> None:
    gate = AsrModeGate()
    other_gate = AsrModeGate()
    lease = gate.acquire("streaming")

    with pytest.raises(ValueError, match="lease"):
        gate.release(object())

    with pytest.raises(ValueError, match="lease"):
        other_gate.release(lease)

    assert gate.active_mode == "streaming"
    assert gate.active_count == 1
    gate.release(lease)


def test_released_leases_are_not_retained_after_repeated_cycles() -> None:
    gate = AsrModeGate()

    for _ in range(1_000):
        lease = gate.acquire("streaming")
        reference = weakref.ref(lease)
        gate.release(lease)
        del lease
        assert reference() is None

    assert gate.active_mode is None
    assert gate.active_count == 0
