from __future__ import annotations

import asyncio

import pytest

from speechrail.config import Settings
from speechrail.runtime.resource_governor import (
    GovernorLimits,
    GovernorQueueFullError,
    ResourceGovernor,
    WorkClass,
)


def test_realtime_slot_remains_available_when_batch_lane_is_saturated() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(total_capacity=3, realtime_reserved_capacity=1, max_pending_per_class=4)
        )
        batch_started = [asyncio.Event(), asyncio.Event()]
        release_batch = asyncio.Event()
        realtime_started = asyncio.Event()

        async def blocking_batch(index: int) -> None:
            batch_started[index].set()
            await release_batch.wait()

        async def realtime() -> None:
            realtime_started.set()

        batch_tasks = [
            asyncio.create_task(
                governor.run(lambda index=index: blocking_batch(index), WorkClass.BATCH_ASR)
            )
            for index in range(2)
        ]
        await asyncio.gather(*(event.wait() for event in batch_started))

        await governor.run(realtime, WorkClass.REALTIME_ASR)
        assert realtime_started.is_set()
        assert governor.snapshot().active_batch == 2

        release_batch.set()
        await asyncio.gather(*batch_tasks)

    asyncio.run(scenario())


def test_batch_waits_fifo_without_stealing_reserved_realtime_capacity() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(total_capacity=2, realtime_reserved_capacity=1, max_pending_per_class=4)
        )
        first_started = asyncio.Event()
        release_first = asyncio.Event()
        second_started = asyncio.Event()

        async def first() -> None:
            first_started.set()
            await release_first.wait()

        async def second() -> None:
            second_started.set()

        first_task = asyncio.create_task(governor.run(first, WorkClass.BATCH_TTS))
        await first_started.wait()
        second_task = asyncio.create_task(governor.run(second, WorkClass.BATCH_TTS))
        await asyncio.sleep(0)

        assert not second_started.is_set()
        assert governor.snapshot().pending_batch == 1

        release_first.set()
        await asyncio.gather(first_task, second_task)
        assert second_started.is_set()

    asyncio.run(scenario())


def test_queue_limit_is_reported() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(total_capacity=2, realtime_reserved_capacity=1, max_pending_per_class=1)
        )
        hold = asyncio.Event()
        entered = asyncio.Event()

        async def blocking() -> None:
            entered.set()
            await hold.wait()

        task = asyncio.create_task(governor.run(blocking, WorkClass.BATCH_ASR))
        await entered.wait()

        waiting = asyncio.create_task(governor.run(lambda: asyncio.sleep(0), WorkClass.BATCH_ASR))
        await asyncio.sleep(0)
        try:
            await governor.run(lambda: asyncio.sleep(0), WorkClass.BATCH_ASR, deadline=0.01)
        except GovernorQueueFullError:
            pass
        else:
            raise AssertionError("expected bounded batch queue to reject admission")

        hold.set()
        await asyncio.gather(task, waiting)

    asyncio.run(scenario())


def test_settings_validate_resource_governor_reservation() -> None:
    with pytest.raises(ValueError, match="realtime_reserved_capacity"):
        Settings(runtime_total_capacity=2, realtime_reserved_capacity=2)

    settings = Settings(runtime_total_capacity=3, realtime_reserved_capacity=1)
    assert settings.governor_limits.total_capacity == 3
