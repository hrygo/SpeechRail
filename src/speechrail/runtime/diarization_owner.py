"""Event-loop-local model ownership, independent of chunk compute reservations."""

from __future__ import annotations

import asyncio
from contextlib import suppress

from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.diarization_worker import CoreMLWorkerProcess
from speechrail.runtime.resource_governor import (
    GovernorLaneIsolatedError,
    GovernorQueueFullError,
    ResourceGovernor,
)


class DiarizationSessionOwner:
    """One service has one resident diarization child, including between chunks."""

    def __init__(self) -> None:
        self._sequence = 0
        self._generation: int | None = None
        self._child: object | None = None
        self._isolated = False

    @property
    def occupied(self) -> bool:
        return self._generation is not None

    @property
    def isolated(self) -> bool:
        return self._isolated

    def claim(self, epoch: str) -> int:
        if not isinstance(epoch, str) or not epoch:
            raise ValueError("diarization epoch is required")
        if self._isolated:
            raise GovernorLaneIsolatedError("diarization reclamation is unconfirmed")
        if self.occupied:
            raise GovernorQueueFullError("diarization model owner is busy")
        self._sequence += 1
        self._generation = self._sequence
        return self._sequence

    def attach(self, generation: int, child: object) -> None:
        if generation != self._generation or self._child is not None:
            raise ValueError("cannot attach child to a different diarization owner")
        self._child = child

    def release(self, generation: int, *, reaped: bool) -> None:
        if generation != self._generation:
            return
        if not reaped:
            self._isolated = True
            return  # Keep the exact child's reference and generation.
        self._child = None
        self._generation = None


class DiarizationWorkerLease:
    """A single, cancellation-safe close entry point for an owned exact child."""

    def __init__(
        self,
        *,
        worker: CoreMLWorkerProcess,
        governor: ResourceGovernor,
        generation: int,
    ) -> None:
        self._worker = worker
        self._governor = governor
        self._generation = generation
        self._close_task: asyncio.Task[None] | None = None
        self._start_task: asyncio.Task[None] | None = None
        governor.diarization_owner.attach(generation, worker)

    async def start(self) -> None:
        if self._close_task is not None:
            raise RuntimeError("diarization worker is closing")
        if self._start_task is None:
            self._start_task = asyncio.create_task(
                self._worker.start(), name="owned-diarization-start"
            )
        # The transport makes OS process creation cancellation-safe. Preflight
        # can then be interrupted without losing a late exact child.
        await asyncio.shield(self._start_task)

    async def close(self) -> None:
        if self._close_task is None:
            self._close_task = asyncio.create_task(self._close(), name="owned-diarization-close")
        await join_cleanup(self._close_task)

    async def _close(self) -> None:
        if self._start_task is not None:
            # Interrupt a blocked preflight, but join protected OS creation.
            self._start_task.cancel()
            with suppress(BaseException):
                await join_cleanup(self._start_task)
        try:
            await self._worker.close()
        except BaseException:
            self._governor.diarization_owner.release(self._generation, reaped=False)
            self._governor.quarantine_diarization_lane()
            raise
        else:
            self._governor.diarization_owner.release(self._generation, reaped=True)
