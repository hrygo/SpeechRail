"""Background idle eviction and two-phase standby management for inference workers."""

from __future__ import annotations

import asyncio
import contextlib
import enum
import time
from collections.abc import AsyncIterator, Callable, Sequence
from contextlib import asynccontextmanager
from typing import Protocol


class WorkerLifecycleState(enum.StrEnum):
    ACTIVE = "active"
    WARM_STANDBY = "warm_standby"
    COLD_EVICTED = "cold_evicted"


class EvictableWorker(Protocol):
    """Narrow interface for an inference worker that can be inspected and closed on idle."""

    @property
    def alive(self) -> bool: ...

    async def close(self) -> None: ...


class WorkerLeaseLock:
    """Async mutual exclusion lock with monotonic lease generation token and lease counter."""

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._active_leases = 0
        self._generation = 0

    @property
    def active_leases(self) -> int:
        return self._active_leases

    @property
    def generation(self) -> int:
        return self._generation

    @asynccontextmanager
    async def lease(self) -> AsyncIterator[int]:
        async with self._lock:
            self._active_leases += 1
            self._generation += 1
        try:
            yield self._generation
        finally:
            async with self._lock:
                self._active_leases = max(0, self._active_leases - 1)


class WorkerIdleEvictor:
    """Monitors active workers and executes two-phase standby & cold eviction when idle."""

    def __init__(
        self,
        workers: Sequence[EvictableWorker],
        *,
        idle_timeout_seconds: float = 900.0,
        warm_standby_timeout_seconds: float = 180.0,
        min_uptime_seconds: float = 0.0,
        check_interval_seconds: float = 10.0,
        on_eviction: Callable[[str, str], None] | None = None,
    ) -> None:
        self._workers = tuple(w for w in workers if w is not None)
        self._idle_timeout = idle_timeout_seconds
        self._warm_standby_timeout = min(warm_standby_timeout_seconds, idle_timeout_seconds)
        self._min_uptime = min_uptime_seconds
        self._check_interval = check_interval_seconds
        self._on_eviction = on_eviction
        self._last_active: dict[EvictableWorker, float] = {}
        self._loaded_at: dict[EvictableWorker, float] = {}
        self._was_alive: dict[EvictableWorker, bool] = {}
        self._states: dict[EvictableWorker, WorkerLifecycleState] = {}
        self._lease_locks: dict[EvictableWorker, WorkerLeaseLock] = {}
        self._task: asyncio.Task[None] | None = None
        now = time.monotonic()
        for worker in self._workers:
            self._last_active[worker] = now
            self._loaded_at[worker] = now
            self._was_alive[worker] = getattr(worker, "alive", False)
            self._states[worker] = WorkerLifecycleState.ACTIVE
            self._lease_locks[worker] = WorkerLeaseLock()

    def touch(self, worker: EvictableWorker) -> None:
        """Record activity on a worker at current time."""
        self._last_active[worker] = time.monotonic()
        self._states[worker] = WorkerLifecycleState.ACTIVE

    def state_of(self, worker: EvictableWorker) -> WorkerLifecycleState:
        return self._states.get(worker, WorkerLifecycleState.COLD_EVICTED)

    def lease_lock_of(self, worker: EvictableWorker) -> WorkerLeaseLock:
        return self._lease_locks[worker]

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

    async def force_evict(self, worker: EvictableWorker | None = None) -> None:
        """Force immediate cold eviction (e.g. on macOS memory pressure notification)."""
        targets = (worker,) if worker is not None else self._workers
        for w in targets:
            lease_lock = self._lease_locks.get(w)
            if lease_lock is not None and lease_lock.active_leases > 0:
                continue  # In active use, do not evict
            if getattr(w, "alive", False) or getattr(w, "ready", False):
                with contextlib.suppress(Exception):
                    await w.close()
            self._states[w] = WorkerLifecycleState.COLD_EVICTED

    async def _eviction_loop(self) -> None:
        while True:
            await asyncio.sleep(self._check_interval)
            now = time.monotonic()
            for worker in self._workers:
                worker_activity = getattr(worker, "last_active", None)
                if (
                    isinstance(worker_activity, (int, float))
                    and worker_activity > self._last_active.get(worker, 0.0)
                ):
                    self._last_active[worker] = worker_activity
                    self._states[worker] = WorkerLifecycleState.ACTIVE

                lease_lock = self._lease_locks.get(worker)
                if lease_lock is not None and lease_lock.active_leases > 0:
                    self._last_active[worker] = now
                    self._states[worker] = WorkerLifecycleState.ACTIVE
                    continue

                # Detect a fresh load (lazy first start or restart after eviction)
                # and open the anti-thrash uptime window with a fresh idle clock.
                worker_alive = bool(getattr(worker, "alive", False)) or bool(
                    getattr(worker, "ready", False)
                )
                if worker_alive and not self._was_alive.get(worker, False):
                    self._loaded_at[worker] = now
                    self._last_active[worker] = now
                self._was_alive[worker] = worker_alive

                # Stage 0: Min-Uptime Guard: a freshly loaded worker is kept for
                # at least min_uptime_seconds so bursty traffic cannot alternate
                # between long model loads and immediate eviction (thrash).
                # The guard postpones eviction decisions without refreshing the
                # idle clock, so eviction proceeds as soon as it expires.
                if self._min_uptime > 0.0 and (
                    now - self._loaded_at.get(worker, now) < self._min_uptime
                ):
                    self._states[worker] = WorkerLifecycleState.ACTIVE
                    continue

                last_time = self._last_active.get(worker, now)
                idle_duration = now - last_time

                # Stage 2: Cold Eviction (idle >= _idle_timeout)
                if idle_duration >= self._idle_timeout:
                    if getattr(worker, "alive", False) or getattr(worker, "ready", False):
                        with contextlib.suppress(Exception):
                            await worker.close()
                    self._states[worker] = WorkerLifecycleState.COLD_EVICTED
                    self._last_active[worker] = now
                    if self._on_eviction is not None:
                        self._on_eviction(type(worker).__name__, "cold_evict")
                # Stage 1: Warm Standby (idle >= _warm_standby_timeout)
                elif idle_duration >= self._warm_standby_timeout:
                    if self._states.get(worker) == WorkerLifecycleState.ACTIVE:
                        trim_fn = getattr(worker, "trim_memory", None) or getattr(
                            worker, "release_cache", None
                        )
                        if callable(trim_fn):
                            with contextlib.suppress(Exception):
                                if asyncio.iscoroutinefunction(trim_fn):
                                    await trim_fn()
                                else:
                                    trim_fn()
                        self._states[worker] = WorkerLifecycleState.WARM_STANDBY
                        if self._on_eviction is not None:
                            self._on_eviction(type(worker).__name__, "standby")
