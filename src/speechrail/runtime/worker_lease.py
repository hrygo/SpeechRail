"""Background idle eviction and two-phase standby management for inference workers."""

from __future__ import annotations

import asyncio
import contextlib
import enum
import time
from collections.abc import AsyncIterator, Callable, Mapping, Sequence
from contextlib import asynccontextmanager
from typing import Protocol, runtime_checkable

from speechrail.runtime.asr_mode import AsrModeGate
from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.resource_governor import GovernorLaneIsolatedError


class WorkerLifecycleState(enum.StrEnum):
    ACTIVE = "active"
    WARM_STANDBY = "warm_standby"
    COLD_EVICTED = "cold_evicted"
    RECLAMATION_FAILED = "reclamation_failed"


@runtime_checkable
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
        self._last_active = time.monotonic()
        self._reclamation_failed = False

    @property
    def reclamation_failed(self) -> bool:
        return self._reclamation_failed

    def mark_reclamation(self, *, failed: bool) -> None:
        """Record a known close outcome under idle admission or shutdown ownership."""
        self._reclamation_failed = failed

    @property
    def active_leases(self) -> int:
        return self._active_leases

    @property
    def generation(self) -> int:
        return self._generation

    @property
    def last_active(self) -> float:
        return self._last_active

    @asynccontextmanager
    async def lease(self) -> AsyncIterator[int]:
        async with self._lock:
            if self._reclamation_failed:
                raise GovernorLaneIsolatedError("backend_reclamation_failed")
            self._active_leases += 1
            self._generation += 1
            generation = self._generation
        try:
            yield generation
        finally:
            # No await here: repeated cancellation cannot leak an active lease.
            self._active_leases -= 1
            self._last_active = time.monotonic()

    @asynccontextmanager
    async def idle(self) -> AsyncIterator[bool]:
        """Hold the admission lock through idle close/trim.

        A new lease either precedes the decision and prevents eviction, or waits
        for close to finish before it can restart the worker.
        """
        async with self._lock:
            yield self._active_leases == 0


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
        on_reclamation_failure: Callable[[EvictableWorker], None] | None = None,
        lease_locks: Mapping[EvictableWorker, WorkerLeaseLock] | None = None,
    ) -> None:
        self._workers = tuple({id(w): w for w in workers if w is not None}.values())
        self._idle_timeout = idle_timeout_seconds
        self._warm_standby_timeout = min(warm_standby_timeout_seconds, idle_timeout_seconds)
        self._min_uptime = min_uptime_seconds
        self._check_interval = check_interval_seconds
        self._on_eviction = on_eviction
        self._on_reclamation_failure = on_reclamation_failure
        self._last_active: dict[EvictableWorker, float] = {}
        self._loaded_at: dict[EvictableWorker, float] = {}
        self._was_alive: dict[EvictableWorker, bool] = {}
        self._states: dict[EvictableWorker, WorkerLifecycleState] = {}
        self._lease_locks: dict[EvictableWorker, WorkerLeaseLock] = {}
        # Per-worker TTL overrides; absent entries fall back to the evictor
        # defaults above. Only the design lane overrides today (#135).
        self._idle_timeouts: dict[EvictableWorker, float] = {}
        self._standby_timeouts: dict[EvictableWorker, float] = {}
        self._task: asyncio.Task[None] | None = None
        now = time.monotonic()
        for worker in self._workers:
            self._last_active[worker] = now
            self._loaded_at[worker] = now
            self._was_alive[worker] = getattr(worker, "alive", False)
            self._states[worker] = WorkerLifecycleState.ACTIVE
            self._lease_locks[worker] = (
                lease_locks[worker] if lease_locks and worker in lease_locks else WorkerLeaseLock()
            )

    def track(
        self,
        worker: EvictableWorker,
        *,
        idle_timeout_seconds: float | None = None,
        warm_standby_timeout_seconds: float | None = None,
    ) -> None:
        """Add one worker with its own idle clock (#135: design lane TTL).

        Per-worker timeouts fall back to the evictor defaults when omitted.
        Tracking a live evictor takes effect on the next monitor tick; the
        fresh idle stamp gives the newcomer a full TTL window.
        """

        if worker is None or worker in self._lease_locks:
            return
        now = time.monotonic()
        self._workers = (*self._workers, worker)
        self._last_active[worker] = now
        self._loaded_at[worker] = now
        self._was_alive[worker] = getattr(worker, "alive", False)
        self._states[worker] = WorkerLifecycleState.ACTIVE
        self._lease_locks[worker] = WorkerLeaseLock()
        if idle_timeout_seconds is not None:
            self._idle_timeouts[worker] = idle_timeout_seconds
        if warm_standby_timeout_seconds is not None:
            self._standby_timeouts[worker] = min(
                warm_standby_timeout_seconds,
                self._idle_timeouts.get(worker, self._idle_timeout),
            )

    def touch(self, worker: EvictableWorker) -> None:
        """Record activity on a worker at current time."""
        if self._lease_locks[worker].reclamation_failed:
            return
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

    def confirm_shutdown(self) -> None:
        """Restore admission only after lifecycle joined all physical-owner closes.

        Stopping this monitor alone is not reclamation evidence. Lifecycle owns
        the shutdown boundary, including router children tracked independently.
        """
        if any(
            getattr(worker, "alive", False) or getattr(worker, "ready", False)
            for worker in self._workers
        ):
            raise RuntimeError("backend_reclamation_failed")
        for worker in self._workers:
            self._record_cold(worker)

    def _record_cold(self, worker: EvictableWorker) -> None:
        self._lease_locks[worker].mark_reclamation(failed=False)
        self._states[worker] = WorkerLifecycleState.COLD_EVICTED
        self._was_alive[worker] = False
        self._last_active[worker] = time.monotonic()

    async def force_evict(self, worker: EvictableWorker | None = None) -> None:
        """Force immediate cold eviction (e.g. on macOS memory pressure notification)."""
        targets = (worker,) if worker is not None else self._workers
        for w in targets:
            async with self._lease_locks[w].idle() as idle:
                if not idle or self._in_use(w):
                    continue
                await self._cold_evict(w)

    async def _cold_evict(self, worker: EvictableWorker) -> None:
        """Keep admission isolated until the owned close confirms reclamation.

        Record the outcome inside the cleanup task: join_cleanup may propagate
        waiter cancellation after that task has already closed successfully.
        """
        lease = self._lease_locks[worker]

        async def close_and_record() -> None:
            try:
                # alive/ready describe usability, not retained process ownership.
                # An idempotent close must also confirm an unusable owner is reaped.
                await worker.close()
                if getattr(worker, "alive", False) or getattr(worker, "ready", False):
                    raise RuntimeError("backend_reclamation_failed")
            except BaseException:
                lease.mark_reclamation(failed=True)
                self._states[worker] = WorkerLifecycleState.RECLAMATION_FAILED
                if self._on_reclamation_failure is not None:
                    self._on_reclamation_failure(worker)
                if self._on_eviction is not None:
                    self._on_eviction(type(worker).__name__, "reclamation_failed")
                raise
            self._record_cold(worker)
            if self._on_eviction is not None:
                self._on_eviction(type(worker).__name__, "cold_evict")

        try:
            await join_cleanup(asyncio.create_task(close_and_record()))
        except (Exception, asyncio.CancelledError):
            # A cancelled close owns a failed reclamation, not cancellation of
            # this monitor. Preserve actual waiter cancellation even when the
            # joined close raises a different exception.
            waiter = asyncio.current_task()
            if waiter is not None and waiter.cancelling():
                raise asyncio.CancelledError from None

    def _in_use(self, worker: EvictableWorker) -> bool:
        lease = self._lease_locks.get(worker)
        mode_gate = getattr(worker, "mode_gate", None)
        return bool(lease is not None and lease.active_leases > 0) or (
            isinstance(mode_gate, AsrModeGate) and mode_gate.active_count > 0
        )

    async def _eviction_loop(self) -> None:
        while True:
            await asyncio.sleep(self._check_interval)
            now = time.monotonic()
            for worker in self._workers:
                async with self._lease_locks[worker].idle() as idle:
                    if self._lease_locks[worker].reclamation_failed:
                        # TTL/activity cannot confirm that a failed reap recovered.
                        continue
                    if not idle:
                        self.touch(worker)
                        continue
                    lease_activity = self._lease_locks[worker].last_active
                    if lease_activity > self._last_active.get(worker, 0.0):
                        self._last_active[worker] = lease_activity
                        self._states[worker] = WorkerLifecycleState.ACTIVE
                    worker_activity = getattr(worker, "last_active", None)
                    if isinstance(
                        worker_activity, (int, float)
                    ) and worker_activity > self._last_active.get(worker, 0.0):
                        self._last_active[worker] = worker_activity
                        self._states[worker] = WorkerLifecycleState.ACTIVE

                    if self._in_use(worker):
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

                    idle_timeout = self._idle_timeouts.get(worker, self._idle_timeout)
                    standby_timeout = self._standby_timeouts.get(worker, self._warm_standby_timeout)
                    # Stage 2: Cold Eviction (idle >= _idle_timeout)
                    if idle_duration >= idle_timeout:
                        await self._cold_evict(worker)
                    # Stage 1: Warm Standby (idle >= _warm_standby_timeout)
                    elif (
                        idle_duration >= standby_timeout
                        and self._states.get(worker) == WorkerLifecycleState.ACTIVE
                    ):
                        trim_fn = getattr(worker, "trim_memory", None) or getattr(
                            worker, "release_cache", None
                        )
                        if callable(trim_fn):
                            with contextlib.suppress(Exception):
                                if asyncio.iscoroutinefunction(trim_fn):
                                    await join_cleanup(asyncio.create_task(trim_fn()))
                                else:
                                    trim_fn()
                        self._states[worker] = WorkerLifecycleState.WARM_STANDBY
                        if self._on_eviction is not None:
                            self._on_eviction(type(worker).__name__, "standby")
