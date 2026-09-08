from __future__ import annotations

import asyncio

import pytest

from speechrail.application.deadline import await_until


def test_absolute_expiry_stops_waiting() -> None:
    async def scenario() -> None:
        expiry = asyncio.get_running_loop().time() + 0.05
        await await_until(asyncio.sleep(0), expiry)
        with pytest.raises(TimeoutError):
            await await_until(asyncio.sleep(1), expiry)

    asyncio.run(scenario())


def test_expired_deadline_is_not_reset_by_a_second_wait() -> None:
    async def scenario() -> None:
        expiry = asyncio.get_running_loop().time() - 0.01
        for _ in range(2):
            with pytest.raises(TimeoutError):
                await await_until(asyncio.sleep(0), expiry)

    asyncio.run(scenario())
