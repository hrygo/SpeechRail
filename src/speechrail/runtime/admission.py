"""Bounded async admission, independent of a particular inference backend."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from typing import TypeVar

T = TypeVar("T")


class QueueFullError(RuntimeError):
    pass


class AdmissionQueue:
    def __init__(self, capacity: int) -> None:
        self._slots = asyncio.BoundedSemaphore(capacity)

    async def run(self, operation: Callable[[], Awaitable[T]], *, deadline: float) -> T:
        if self._slots.locked():
            raise QueueFullError
        await self._slots.acquire()
        try:
            async with asyncio.timeout(deadline):
                return await operation()
        finally:
            self._slots.release()
