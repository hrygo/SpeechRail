"""Background idle eviction and lease management for inference workers."""

from __future__ import annotations

import asyncio
import contextlib
import time
from collections.abc import Sequence
from typing import Protocol


class EvictableWorker(Protocol):
    """Narrow interface for an inference worker that can be inspected and closed on idle."""

    @property
    def alive(self) -> bool: ...

    async def close(self) -> None: ...


class WorkerIdleEvictor:
    """Monitors active workers and shuts them down when idle for longer than the timeout."""

    def __init__(
        self,
        workers: Sequence[EvictableWorker],
        *,
        idle_timeout_seconds: float = 300.0,
        check_interval_seconds: float = 10.0,
    ) -> None:
        self._workers = tuple(w for w in workers if w is not None)
        self._idle_timeout = idle_timeout_seconds
        self._check_interval = check_interval_seconds
        self._last_active: dict[EvictableWorker, float] = {}
        self._task: asyncio.Task[None] | None = None
        now = time.monotonic()
        for worker in self._workers:
            self._last_active[worker] = now

    def touch(self, worker: EvictableWorker) -> None:
        """Record activity on a worker at current time."""
        self._last_active[worker] = time.monotonic()

    async def start(self) -> None:
        """Start the background eviction monitor task."""
        if self._idle_timeout <= 0 or not self._workers:
            return
        if self._task is None:
            self._task = asyncio.create_task(self._eviction_loop())

    async def close(self) -> None:
        """Stop the background monitor task."""
        if self._task is not None:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
            self._task = None

    async def _eviction_loop(self) -> None:
        while True:
            await asyncio.sleep(self._check_interval)
            now = time.monotonic()
            for worker in self._workers:
                last_time = self._last_active.get(worker, now)
                if now - last_time >= self._idle_timeout and (
                    getattr(worker, "alive", False) or getattr(worker, "ready", False)
                ):
                    with contextlib.suppress(Exception):
                        await worker.close()
