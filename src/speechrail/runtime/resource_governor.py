"""Capacity reservation and fair admission for ASR/TTS runtime work."""

from __future__ import annotations

import asyncio
import time
from collections import deque
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager, suppress
from dataclasses import dataclass
from enum import StrEnum
from typing import TypeVar

from speechrail.domain.resource_limits import GovernorLimits

T = TypeVar("T")


class WorkClass(StrEnum):
    REALTIME_ASR = "realtime_asr"
    REALTIME_TTS = "realtime_tts"
    BATCH_ASR = "batch_asr"
    BATCH_TTS = "batch_tts"

    @property
    def is_realtime(self) -> bool:
        return self in {self.REALTIME_ASR, self.REALTIME_TTS}


class GovernorQueueFullError(RuntimeError):
    """The bounded waiting queue for a work class is full."""


@dataclass(frozen=True, slots=True)
class GovernorSnapshot:
    active_realtime: int
    active_batch: int
    pending_realtime: int
    pending_batch: int


@dataclass(frozen=True, slots=True)
class _Waiter:
    ticket: int
    work_class: WorkClass
    enqueued_at: float

    @property
    def is_realtime(self) -> bool:
        return self.work_class.is_realtime


class ResourceGovernor:
    """Reserve capacity for realtime work while keeping batch work FIFO.

    Batch work may use only the non-reserved capacity.  This intentionally
    leaves a real scheduling slot free instead of relying on cancellation or
    preemption when a realtime client begins producing audio.
    """

    def __init__(
        self,
        limits: GovernorLimits,
        *,
        on_reject: Callable[[WorkClass], None] | None = None,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self._limits = limits
        self._on_reject = on_reject
        self._clock = clock or time.monotonic
        self._condition = asyncio.Condition()
        self._ticket = 0
        self._active_realtime = 0
        self._active_batch = 0
        self._realtime_waiters: deque[_Waiter] = deque()
        self._batch_waiters: deque[_Waiter] = deque()

    async def run(
        self,
        operation: Callable[[], Awaitable[T]],
        work_class: WorkClass,
        *,
        deadline: float | None = None,
    ) -> T:
        """Run work after capacity admission, respecting an optional deadline."""
        async with self.reserve(work_class, deadline=deadline):
            return await operation()

    @asynccontextmanager
    async def reserve(
        self, work_class: WorkClass, *, deadline: float | None = None
    ) -> AsyncIterator[None]:
        """Hold one resource lane while an operation yields streamed output."""
        if deadline is None:
            await self._acquire(work_class)
        else:
            async with asyncio.timeout(deadline):
                await self._acquire(work_class)
        try:
            yield
        finally:
            await self._release(work_class)

    def snapshot(self) -> GovernorSnapshot:
        """Return a point-in-time metric view suitable for readiness/metrics."""
        return GovernorSnapshot(
            active_realtime=self._active_realtime,
            active_batch=self._active_batch,
            pending_realtime=len(self._realtime_waiters),
            pending_batch=len(self._batch_waiters),
        )

    async def _acquire(self, work_class: WorkClass) -> None:
        async with self._condition:
            waiters = self._waiters_for(work_class)
            if len(waiters) >= self._limits.max_pending_per_class:
                if self._on_reject is not None:
                    self._on_reject(work_class)
                raise GovernorQueueFullError(f"{work_class.value} admission queue is full")
            self._ticket += 1
            waiter = _Waiter(
                ticket=self._ticket, work_class=work_class, enqueued_at=self._clock()
            )
            waiters.append(waiter)
            try:
                while not self._can_admit(waiter):
                    timeout = self._batch_aging_wait_timeout(waiter)
                    if timeout is None:
                        await self._condition.wait()
                        continue
                    with suppress(TimeoutError):
                        await asyncio.wait_for(self._condition.wait(), timeout=timeout)
                waiters.popleft()
                if waiter.is_realtime:
                    self._active_realtime += 1
                else:
                    self._active_batch += 1
                self._condition.notify_all()
            except BaseException:
                if waiter in waiters:
                    waiters.remove(waiter)
                self._condition.notify_all()
                raise

    async def _release(self, work_class: WorkClass) -> None:
        async with self._condition:
            if work_class.is_realtime:
                self._active_realtime -= 1
            else:
                self._active_batch -= 1
            self._condition.notify_all()

    def _can_admit(self, waiter: _Waiter) -> bool:
        if self._active_realtime + self._active_batch >= self._limits.total_capacity:
            return False
        if waiter.is_realtime:
            return self._realtime_waiters[0] == waiter
        if self._batch_waiters[0] != waiter:
            return False
        batch_capacity = self._limits.total_capacity - self._limits.realtime_reserved_capacity
        if self._active_batch < batch_capacity and not self._realtime_waiters:
            return True
        # Aging: a batch request that has waited past the threshold may use the
        # reserved realtime lane, so sustained realtime traffic cannot starve
        # batch work entirely. FIFO within the batch class is preserved.
        aged = self._clock() - waiter.enqueued_at >= self._limits.batch_aging_seconds
        return aged and self._active_batch < self._limits.total_capacity

    def _batch_aging_wait_timeout(self, waiter: _Waiter) -> float | None:
        if waiter.is_realtime or self._batch_waiters[0] != waiter:
            return None
        remaining = (
            waiter.enqueued_at
            + self._limits.batch_aging_seconds
            - self._clock()
        )
        return remaining if remaining > 0 else None

    def _waiters_for(self, work_class: WorkClass) -> deque[_Waiter]:
        return self._realtime_waiters if work_class.is_realtime else self._batch_waiters


__all__ = [
    "GovernorLimits",
    "GovernorQueueFullError",
    "GovernorSnapshot",
    "ResourceGovernor",
    "WorkClass",
]
