"""ASR batch/streaming 模式同步准入门测试。"""

from __future__ import annotations

import asyncio
import weakref
from typing import cast

import pytest

from speechrail.runtime.asr_mode import (
    AsrModeBusy,
    AsrModeGate,
    AsrModeScheduler,
)
from speechrail.runtime.busy import BusyReason


def test_batch_cannot_enter_unfinished_stream() -> None:
    gate = AsrModeGate()

    stream_lease = gate.acquire("streaming")
    assert gate.active_mode == "streaming"
    assert gate.active_count == 1

    with pytest.raises(AsrModeBusy, match="streaming") as caught:
        gate.acquire("batch")
    assert caught.value.busy_reason == BusyReason.ASR_MODE_CONFLICT
    assert caught.value.retryable is True

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



def test_scheduler_gives_waiting_realtime_the_next_batch_boundary() -> None:
    async def scenario() -> None:
        gate = AsrModeGate()
        scheduler = AsrModeScheduler(gate, batch_aging_seconds=30)
        ticket = scheduler.new_batch_ticket()
        realtime_started = asyncio.Event()
        release_realtime = asyncio.Event()
        second_batch_started = asyncio.Event()

        async with scheduler.batch_window(ticket):
            async def realtime() -> None:
                async with scheduler.streaming():
                    realtime_started.set()
                    await release_realtime.wait()

            realtime_task = asyncio.create_task(realtime())
            for _ in range(100):
                if scheduler.snapshot().pending_streaming == 1:
                    break
                await asyncio.sleep(0)
            assert scheduler.snapshot().pending_streaming == 1

        async def second_batch() -> None:
            async with scheduler.batch_window(ticket):
                second_batch_started.set()

        batch_task = asyncio.create_task(second_batch())
        await asyncio.wait_for(realtime_started.wait(), timeout=1)
        assert not second_batch_started.is_set()
        assert gate.active_mode == "streaming"

        release_realtime.set()
        await asyncio.gather(realtime_task, batch_task)
        assert second_batch_started.is_set()
        assert ticket.service_windows == 2
        assert ticket.cumulative_wait_seconds >= 0
        assert gate.active_mode is None

    asyncio.run(scenario())


def test_scheduler_aged_batch_blocks_new_streaming_joiners_until_progress() -> None:
    async def scenario() -> None:
        gate = AsrModeGate()
        scheduler = AsrModeScheduler(gate, batch_aging_seconds=0.02)
        ticket = scheduler.new_batch_ticket()
        first_stream_started = asyncio.Event()
        release_first_stream = asyncio.Event()
        batch_started = asyncio.Event()
        release_batch = asyncio.Event()
        second_stream_started = asyncio.Event()

        async def first_stream() -> None:
            async with scheduler.streaming():
                first_stream_started.set()
                await release_first_stream.wait()

        first_task = asyncio.create_task(first_stream())
        await first_stream_started.wait()

        async def batch() -> None:
            async with scheduler.batch_window(ticket):
                batch_started.set()
                await release_batch.wait()

        batch_task = asyncio.create_task(batch())
        for _ in range(100):
            if scheduler.snapshot().pending_batch == 1:
                break
            await asyncio.sleep(0.001)
        assert scheduler.snapshot().pending_batch == 1
        await asyncio.sleep(0.03)

        async def second_stream() -> None:
            async with scheduler.streaming():
                second_stream_started.set()

        second_task = asyncio.create_task(second_stream())
        await asyncio.sleep(0)
        assert not second_stream_started.is_set()

        release_first_stream.set()
        await asyncio.wait_for(batch_started.wait(), timeout=1)
        assert not second_stream_started.is_set()
        release_batch.set()

        await asyncio.gather(first_task, batch_task, second_task)
        assert second_stream_started.is_set()
        assert ticket.service_windows == 1
        assert gate.active_mode is None

    asyncio.run(scenario())


def test_scheduler_cancelled_batch_waiter_leaves_no_pending_state() -> None:
    async def scenario() -> None:
        gate = AsrModeGate()
        scheduler = AsrModeScheduler(gate, batch_aging_seconds=30)
        ticket = scheduler.new_batch_ticket()
        release_stream = asyncio.Event()

        async def stream() -> None:
            async with scheduler.streaming():
                await release_stream.wait()

        stream_task = asyncio.create_task(stream())
        for _ in range(100):
            if gate.active_mode == "streaming":
                break
            await asyncio.sleep(0)
        assert gate.active_mode == "streaming"

        async def batch() -> None:
            async with scheduler.batch_window(ticket):
                raise AssertionError("cancelled waiter must not enter")

        batch_task = asyncio.create_task(batch())
        for _ in range(100):
            if scheduler.snapshot().pending_batch == 1:
                break
            await asyncio.sleep(0)
        assert scheduler.snapshot().pending_batch == 1

        batch_task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await batch_task
        assert scheduler.snapshot().pending_batch == 0
        assert ticket.service_windows == 0

        release_stream.set()
        await stream_task
        assert gate.active_mode is None

    asyncio.run(scenario())
