"""Single-owner runtime lifecycle for repository recovery, local workers and idle eviction."""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Protocol

from speechrail.runtime.job_runner import JobRunner
from speechrail.runtime.worker_lease import WorkerIdleEvictor


class StartableComponent(Protocol):
    """Narrow shape shared by the local ASR and TTS workers."""

    @property
    def alive(self) -> bool: ...

    async def start(self) -> None: ...

    async def close(self) -> None: ...


class RecoveryRepository(Protocol):
    """Narrow shape of the durable job spool recovery entry point."""

    def recover_interrupted(self) -> int: ...


async def run_job_runner(runner: JobRunner, *, poll_seconds: float) -> None:
    """Run one durable job at a time; idle waits prevent a busy loop."""
    while True:
        if not await runner.run_once():
            await asyncio.sleep(poll_seconds)


class RuntimeLifecycle:
    """Own repository recovery, worker start/close, idle eviction and JobRunner task.

    Startup order is repository recovery → ASR worker → TTS worker → JobRunner
    task → Evictor. Failure cleans up only the components that already reported a
    successful start, and ``close`` is idempotent.
    """

    def __init__(
        self,
        *,
        repository: RecoveryRepository | None = None,
        asr: StartableComponent | None = None,
        tts: StartableComponent | None = None,
        streaming: StartableComponent | None = None,
        runner: JobRunner | None = None,
        evictor: WorkerIdleEvictor | None = None,
        lazy_load: bool = False,
        poll_seconds: float = 1.0,
    ) -> None:
        self._repository = repository
        self._asr = asr
        self._tts = tts
        self._streaming = streaming
        self._pending: tuple[StartableComponent, ...] = tuple({
            id(component): component
            for component in (asr, tts, streaming) if component is not None
        }.values())
        self._runner = runner
        self._evictor = evictor
        self._lazy_load = lazy_load
        self._poll_seconds = poll_seconds
        self._started_components: list[StartableComponent] = []
        self._runner_task: asyncio.Task[None] | None = None
        self._running = False

    def worker_states(self) -> dict[str, str]:
        """Return low-cardinality lifecycle states for managed inference workers."""
        states: dict[str, str] = {}
        for name, comp in (
            ("asr", self._asr),
            ("tts", self._tts),
            ("streaming", self._streaming),
        ):
            if comp is None:
                continue
            if self._evictor is not None:
                states[name] = str(self._evictor.state_of(comp))
            else:
                is_alive = bool(getattr(comp, "alive", False) or getattr(comp, "ready", False))
                states[name] = "active" if is_alive else "inactive"
        return states

    @asynccontextmanager
    async def run(self) -> AsyncIterator[None]:
        await self.start()
        try:
            yield
        finally:
            await self.close()

    async def start(self) -> None:
        if self._running:
            return
        try:
            if self._repository is not None:
                self._repository.recover_interrupted()
            if not self._lazy_load:
                for component in self._pending:
                    await component.start()
                    self._started_components.append(component)
            else:
                self._started_components = list(self._pending)
            if self._runner is not None:
                self._runner_task = asyncio.create_task(
                    run_job_runner(self._runner, poll_seconds=self._poll_seconds)
                )
            if self._evictor is not None:
                await self._evictor.start()
            self._running = True
        except BaseException:
            await self._close_started()
            raise

    async def close(self) -> None:
        self._running = False
        if self._evictor is not None:
            await self._evictor.close()
        if self._runner_task is not None:
            self._runner_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._runner_task
            self._runner_task = None
        await self._close_started()

    async def _close_started(self) -> None:
        while self._started_components:
            component = self._started_components.pop()
            with contextlib.suppress(Exception):
                await component.close()
