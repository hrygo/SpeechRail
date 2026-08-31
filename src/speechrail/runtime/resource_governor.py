"""Capacity reservation and fair admission for ASR/TTS runtime work."""

from __future__ import annotations

import asyncio
from collections import deque
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from enum import StrEnum
from typing import TypeVar

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
class GovernorLimits:
    total_capacity: int
    realtime_reserved_capacity: int
    max_pending_per_class: int

    def __post_init__(self) -> None:
        if self.total_capacity < 2:
            raise ValueError("total_capacity must be at least two")
        if not 1 <= self.realtime_reserved_capacity < self.total_capacity:
            raise ValueError("realtime_reserved_capacity must be between one and total_capacity")
        if self.max_pending_per_class < 1:
            raise ValueError("max_pending_per_class must be positive")


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

    @property
    def is_realtime(self) -> bool:
        return self.work_class.is_realtime


class ResourceGovernor:
    """Reserve capacity for realtime work while keeping batch work FIFO.

    Batch work may use only the non-reserved capacity.  This intentionally
    leaves a real scheduling slot free instead of relying on cancellation or
    preemption when a realtime client begins producing audio.
    """

    def __init__(self, limits: GovernorLimits) -> None:
        self._limits = limits
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
        if deadline is None:
            await self._acquire(work_class)
        else:
            async with asyncio.timeout(deadline):
                await self._acquire(work_class)
        try:
            return await operation()
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
                raise GovernorQueueFullError(f"{work_class.value} admission queue is full")
            self._ticket += 1
            waiter = _Waiter(ticket=self._ticket, work_class=work_class)
            waiters.append(waiter)
            try:
                while not self._can_admit(waiter):
                    await self._condition.wait()
                waiters.popleft()
                if waiter.is_realtime:
                    self._active_realtime += 1
                else:
                    self._active_batch += 1
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
        if self._realtime_waiters:
            return False
        batch_capacity = self._limits.total_capacity - self._limits.realtime_reserved_capacity
        return self._active_batch < batch_capacity and self._batch_waiters[0] == waiter

    def _waiters_for(self, work_class: WorkClass) -> deque[_Waiter]:
        return self._realtime_waiters if work_class.is_realtime else self._batch_waiters
