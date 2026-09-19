"""ASR batch/streaming mode exclusion plus fair asynchronous scheduling."""

from __future__ import annotations

import asyncio
import time
from collections import deque
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Literal

from speechrail.runtime.busy import BusyReason

AsrMode = Literal["batch", "streaming"]


class AsrModeBusy(RuntimeError):  # noqa: N818 - public contract keeps this name
    """The shared ASR worker is leased by an incompatible execution mode."""

    busy_reason = BusyReason.ASR_MODE_CONFLICT
    retryable = True


class AsrModeLease:
    """Lease issued by exactly one :class:`AsrModeGate`."""

    __slots__ = ("__weakref__", "_mode", "_owner", "_released")

    def __init__(self, mode: AsrMode, *, _owner: object | None = None) -> None:
        self._owner = object() if _owner is None else _owner
        self._mode = mode
        self._released = False

    @classmethod
    def _issued(cls, owner: object, mode: AsrMode) -> AsrModeLease:
        return cls(mode, _owner=owner)

    @property
    def mode(self) -> AsrMode:
        return self._mode

    @property
    def released(self) -> bool:
        return self._released


class AsrModeGate:
    """Synchronous final exclusion guard for batch versus streaming ASR."""

    __slots__ = ("_batch_active", "_owner", "_streaming_count")

    def __init__(self) -> None:
        self._owner = object()
        self._batch_active = False
        self._streaming_count = 0

    @property
    def active_mode(self) -> AsrMode | None:
        if self._batch_active:
            return "batch"
        if self._streaming_count > 0:
            return "streaming"
        return None

    @property
    def active_count(self) -> int:
        if self._batch_active:
            return 1
        return self._streaming_count

    def acquire(self, mode: AsrMode) -> AsrModeLease:
        """Acquire immediately or raise when the active mode is incompatible."""

        if mode not in ("batch", "streaming"):
            raise ValueError(
                f"unsupported ASR mode {mode!r}; expected 'batch' or 'streaming'"
            )

        if mode == "batch":
            if self.active_count:
                raise AsrModeBusy(
                    f"ASR mode is busy: active_mode={self.active_mode!r}, "
                    f"active_count={self.active_count}"
                )
            self._batch_active = True
        else:
            if self._batch_active:
                raise AsrModeBusy(
                    "ASR mode is busy: active_mode='batch', active_count=1"
                )
            self._streaming_count += 1

        return AsrModeLease._issued(self._owner, mode)

    def release(self, lease: AsrModeLease) -> None:
        """Release one lease; duplicate release is intentionally idempotent."""

        if type(lease) is not AsrModeLease or lease._owner is not self._owner:
            raise ValueError("lease was not issued by this gate")
        if lease.released:
            return

        lease._released = True
        if lease.mode == "batch":
            self._batch_active = False
        else:
            self._streaming_count -= 1


@dataclass(slots=True)
class AsrBatchTicket:
    """Task-level fairness state reused across every bounded batch window."""

    _owner: object
    first_enqueued_at: float
    cumulative_wait_seconds: float = 0.0
    service_windows: int = 0
    last_progress_at: float | None = None
    _queued: bool = False
    _wait_started_at: float | None = None


@dataclass(frozen=True, slots=True)
class AsrSchedulingSnapshot:
    """Low-cardinality evidence for scheduler fairness and progress."""

    active_mode: AsrMode | None
    active_count: int
    pending_streaming: int
    pending_batch: int
    head_batch_cumulative_wait_seconds: float | None
    head_batch_service_windows: int | None
    head_batch_seconds_since_progress: float | None


class AsrModeScheduler:
    """Yieldable scheduling above :class:`AsrModeGate`.

    A batch ticket owns at most one inference window at a time. Reusing the same
    ticket across windows preserves cumulative wait, successful service-window
    count and time since last progress. Waiting realtime work wins the next safe
    boundary unless the head batch task has itself aged past the fairness
    threshold. Already-running streaming sessions are never hard-preempted.
    """

    def __init__(
        self,
        gate: AsrModeGate,
        *,
        batch_aging_seconds: float = 30.0,
        clock: Callable[[], float] | None = None,
    ) -> None:
        if batch_aging_seconds <= 0:
            raise ValueError("batch_aging_seconds must be positive")
        self._gate = gate
        self._batch_aging_seconds = float(batch_aging_seconds)
        self._clock = clock or time.monotonic
        self._owner = object()
        self._condition = asyncio.Condition()
        self._batch_waiters: deque[AsrBatchTicket] = deque()
        self._pending_streaming = 0

    @property
    def gate(self) -> AsrModeGate:
        return self._gate

    def new_batch_ticket(self) -> AsrBatchTicket:
        """Create task-level progress state to reuse for the whole transcription."""

        return AsrBatchTicket(
            _owner=self._owner,
            first_enqueued_at=self._clock(),
        )

    def snapshot(self) -> AsrSchedulingSnapshot:
        """Return current scheduler evidence without request or transcript labels."""

        now = self._clock()
        head = self._batch_waiters[0] if self._batch_waiters else None
        if head is None:
            cumulative_wait = None
            service_windows = None
            since_progress = None
        else:
            current_wait = (
                max(0.0, now - head._wait_started_at)
                if head._wait_started_at is not None
                else 0.0
            )
            cumulative_wait = head.cumulative_wait_seconds + current_wait
            service_windows = head.service_windows
            since_progress = max(0.0, now - self._progress_anchor(head))
        return AsrSchedulingSnapshot(
            active_mode=self._gate.active_mode,
            active_count=self._gate.active_count,
            pending_streaming=self._pending_streaming,
            pending_batch=len(self._batch_waiters),
            head_batch_cumulative_wait_seconds=cumulative_wait,
            head_batch_service_windows=service_windows,
            head_batch_seconds_since_progress=since_progress,
        )

    @asynccontextmanager
    async def streaming(self) -> AsyncIterator[None]:
        """Wait for a safe streaming slot while honoring an aged batch head."""

        lease: AsrModeLease | None = None
        async with self._condition:
            self._pending_streaming += 1
            try:
                while not self._can_admit_streaming():
                    await self._condition.wait()
                lease = self._gate.acquire("streaming")
                self._pending_streaming -= 1
                self._condition.notify_all()
            except BaseException:
                self._pending_streaming -= 1
                self._condition.notify_all()
                raise

        try:
            yield
        finally:
            assert lease is not None
            async with self._condition:
                self._gate.release(lease)
                self._condition.notify_all()

    @asynccontextmanager
    async def batch_window(self, ticket: AsrBatchTicket) -> AsyncIterator[None]:
        """Admit exactly one bounded batch inference unit for a logical task."""

        self._validate_ticket(ticket)
        lease: AsrModeLease | None = None
        admitted = False
        completed = False
        async with self._condition:
            if ticket._queued:
                raise ValueError("batch ticket is already queued")
            ticket._queued = True
            ticket._wait_started_at = self._clock()
            self._batch_waiters.append(ticket)
            try:
                while not self._can_admit_batch(ticket):
                    timeout = self._aging_wakeup(ticket)
                    if timeout is None:
                        await self._condition.wait()
                    else:
                        try:
                            await asyncio.wait_for(
                                self._condition.wait(),
                                timeout=timeout,
                            )
                        except TimeoutError:
                            pass
                self._batch_waiters.remove(ticket)
                ticket._queued = False
                now = self._clock()
                assert ticket._wait_started_at is not None
                ticket.cumulative_wait_seconds += max(
                    0.0, now - ticket._wait_started_at
                )
                ticket._wait_started_at = None
                lease = self._gate.acquire("batch")
                admitted = True
                self._condition.notify_all()
            except BaseException:
                if ticket in self._batch_waiters:
                    self._batch_waiters.remove(ticket)
                ticket._queued = False
                ticket._wait_started_at = None
                self._condition.notify_all()
                raise

        try:
            yield
            completed = True
        finally:
            if admitted:
                assert lease is not None
                async with self._condition:
                    self._gate.release(lease)
                    if completed:
                        ticket.service_windows += 1
                        ticket.last_progress_at = self._clock()
                    self._condition.notify_all()

    def _validate_ticket(self, ticket: AsrBatchTicket) -> None:
        if type(ticket) is not AsrBatchTicket or ticket._owner is not self._owner:
            raise ValueError("batch ticket was not issued by this scheduler")

    def _can_admit_streaming(self) -> bool:
        if self._gate.active_mode == "batch":
            return False
        return not self._head_batch_is_aged()

    def _can_admit_batch(self, ticket: AsrBatchTicket) -> bool:
        if not self._batch_waiters or self._batch_waiters[0] is not ticket:
            return False
        if self._gate.active_mode is not None:
            return False
        if self._pending_streaming and not self._ticket_is_aged(ticket):
            return False
        return True

    def _head_batch_is_aged(self) -> bool:
        return bool(
            self._batch_waiters
            and self._ticket_is_aged(self._batch_waiters[0])
        )

    def _ticket_is_aged(self, ticket: AsrBatchTicket) -> bool:
        return (
            self._clock() - self._progress_anchor(ticket)
            >= self._batch_aging_seconds
        )

    @staticmethod
    def _progress_anchor(ticket: AsrBatchTicket) -> float:
        return (
            ticket.last_progress_at
            if ticket.last_progress_at is not None
            else ticket.first_enqueued_at
        )

    def _aging_wakeup(self, ticket: AsrBatchTicket) -> float | None:
        if not self._pending_streaming or self._ticket_is_aged(ticket):
            return None
        remaining = (
            self._progress_anchor(ticket)
            + self._batch_aging_seconds
            - self._clock()
        )
        return max(0.001, remaining)


__all__ = [
    "AsrBatchTicket",
    "AsrMode",
    "AsrModeBusy",
    "AsrModeGate",
    "AsrModeLease",
    "AsrModeScheduler",
    "AsrSchedulingSnapshot",
]
