"""Bounded async admission, independent of a particular inference backend."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from typing import TypeVar

T = TypeVar("T")


class QueueFullError(RuntimeError):
    pass


class AdmissionQueue:
    """Fixed-capacity admission with immediate rejection at saturation.

    A token queue (instead of a check-then-acquire semaphore) makes the
    fullness decision atomic: a request that arrives at a full queue is
    rejected now rather than parked without a deadline.
    """

    def __init__(self, capacity: int) -> None:
        self._tokens: asyncio.Queue[None] = asyncio.Queue(maxsize=capacity)

    async def run(self, operation: Callable[[], Awaitable[T]], *, deadline: float) -> T:
        try:
            self._tokens.put_nowait(None)
        except asyncio.QueueFull as exc:
            raise QueueFullError from exc
        try:
            async with asyncio.timeout(deadline):
                return await operation()
        finally:
            self._tokens.get_nowait()
            self._tokens.task_done()
