"""Tests for the bounded admission queue's reject/wait semantics."""

from __future__ import annotations

import asyncio

import pytest

from speechrail.runtime.admission import AdmissionQueue, QueueFullError


def test_full_queue_rejects_immediately_instead_of_waiting_unbounded() -> None:
    """A request arriving at a full queue must get QueueFullError, not wait forever."""

    async def scenario() -> None:
        queue = AdmissionQueue(capacity=2)
        release = asyncio.Event()
        first_entered = asyncio.Event()
        second_entered = asyncio.Event()

        async def blocking_first() -> None:
            first_entered.set()
            await release.wait()

        async def blocking_second() -> None:
            second_entered.set()
            await release.wait()

        holder1 = asyncio.create_task(queue.run(blocking_first, deadline=30.0))
        holder2 = asyncio.create_task(queue.run(blocking_second, deadline=30.0))
        await asyncio.gather(first_entered.wait(), second_entered.wait())

        with pytest.raises(QueueFullError):
            await asyncio.wait_for(queue.run(asyncio.sleep, deadline=30.0), timeout=0.1)

        release.set()
        await asyncio.gather(holder1, holder2)

    asyncio.run(scenario())


def test_admission_deadline_covers_operation() -> None:
    async def scenario() -> None:
        queue = AdmissionQueue(capacity=1)

        async def slow() -> None:
            await asyncio.sleep(1.0)

        with pytest.raises(TimeoutError):
            await queue.run(slow, deadline=0.01)

    asyncio.run(scenario())
