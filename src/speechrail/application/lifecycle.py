"""Single-owner runtime lifecycle for repository recovery, local workers and idle eviction."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Awaitable
from contextlib import asynccontextmanager
from typing import Protocol

from speechrail.runtime.cleanup import join_cleanup
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

    def recover_interrupted(self, *, max_attempts: int) -> int: ...


async def run_job_runner(runner: JobRunner, *, poll_seconds: float) -> None:
    """Run one durable job at a time; idle waits prevent a busy loop."""
    while True:
        if not await runner.run_once():
            await asyncio.sleep(poll_seconds)


class RuntimeLifecycle:
    """Own repository recovery, worker start/close, idle eviction and JobRunner task.

    Startup order is repository recovery → ASR worker → TTS worker → JobRunner
    task → Evictor. Alignment is owned but starts on demand. Shutdown attempts
    every physical owner, joins cleanup despite waiter cancellation, and reports
    failures after the other owners have been processed.
    """

    def __init__(
        self,
        *,
        repository: RecoveryRepository | None = None,
        asr: StartableComponent | None = None,
        tts: StartableComponent | None = None,
        streaming: StartableComponent | None = None,
        alignment: StartableComponent | None = None,
        runner: JobRunner | None = None,
        evictor: WorkerIdleEvictor | None = None,
        lazy_load: bool = False,
        poll_seconds: float = 1.0,
        max_job_attempts: int = 2,
        cleanup_timeout_seconds: float = 5.0,
    ) -> None:
        if cleanup_timeout_seconds <= 0:
            raise ValueError("cleanup_timeout_seconds must be positive")
        self._repository = repository
        self._asr = asr
        self._tts = tts
        self._streaming = streaming
        self._alignment = alignment
        self._roles = (
            ("asr", asr),
            ("tts", tts),
            ("streaming", streaming),
            ("alignment", alignment),
        )
        self._pending: tuple[StartableComponent, ...] = tuple(
            {
                id(component): component for _, component in self._roles if component is not None
            }.values()
        )
        self._eager = tuple(
            {
                id(component): component
                for name, component in self._roles
                if component is not None and name != "alignment"
            }.values()
        )
        self._runner = runner
        self._evictor = evictor
        self._lazy_load = lazy_load
        self._poll_seconds = poll_seconds
        self._max_job_attempts = max_job_attempts
        self._started_components: list[StartableComponent] = list(self._pending)
        self._runner_task: asyncio.Task[None] | None = None
        self._cleanup_timeout = cleanup_timeout_seconds
        self._shutdown_task: asyncio.Task[None] | None = None
        self._cleanup_tasks: dict[str, asyncio.Task[None]] = {}
        self._running = False

    def worker_states(self) -> dict[str, str]:
        """Return low-cardinality lifecycle states for managed inference workers."""
        states: dict[str, str] = {}
        for name, comp in self._roles:
            if comp is None:
                continue
            if self._evictor is not None:
                states[name] = str(self._evictor.state_of(comp))
            else:
                is_alive = bool(getattr(comp, "alive", False) or getattr(comp, "ready", False))
                states[name] = "active" if is_alive else "inactive"
        return states

    def tts_warm(self) -> bool | None:
        """Return whether the managed TTS worker is loaded and ready now.

        ``None`` is used for an injected synthesizer that does not expose a
        lifecycle signal.  A missing TTS component is a known cold state and
        therefore returns ``False``.
        """
        if self._tts is None:
            return False
        ready = getattr(self._tts, "ready", None)
        return ready if isinstance(ready, bool) else None

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
        if self._shutdown_task is not None:
            # Failed/unconfirmed cleanup cannot be silently reused.
            await join_cleanup(self._shutdown_task)
            self._shutdown_task = None
            self._started_components = list(self._pending)
            self._cleanup_tasks.clear()
        try:
            if self._repository is not None:
                self._repository.recover_interrupted(max_attempts=self._max_job_attempts)
            if not self._lazy_load:
                for component in self._eager:
                    await component.start()
            if self._runner is not None:
                self._runner_task = asyncio.create_task(
                    run_job_runner(self._runner, poll_seconds=self._poll_seconds)
                )
            if self._evictor is not None:
                await self._evictor.start()
            self._running = True
        except BaseException as startup_error:
            try:
                await self.close()
            except BaseException as cleanup_error:
                raise BaseExceptionGroup(
                    "runtime startup and rollback failed", [startup_error, cleanup_error]
                ) from None
            raise

    async def close(self) -> None:
        self._running = False
        if self._shutdown_task is None:
            self._shutdown_task = asyncio.create_task(self._shutdown())
        await join_cleanup(self._shutdown_task)

    async def _shutdown(self) -> None:
        errors: list[Exception] = []
        if self._evictor is not None:
            await self._close_operation("monitor", self._evictor.close(), errors)
        if self._runner_task is not None:
            self._runner_task.cancel()
            if await self._join_operation("runner", self._runner_task, errors, cancelled_ok=True):
                self._runner_task = None
        for component in tuple(reversed(self._started_components)):
            role = next(name for name, value in self._roles if value is component)
            if await self._close_operation(role, component.close(), errors):
                self._started_components.remove(component)
        if errors:
            raise ExceptionGroup("runtime cleanup incomplete", errors)

    async def _close_operation(
        self, role: str, operation: Awaitable[None], errors: list[Exception]
    ) -> bool:
        async def run() -> None:
            await operation

        task = asyncio.create_task(run())
        def observe(finished: asyncio.Task[None]) -> None:
            if not finished.cancelled():
                finished.exception()
        task.add_done_callback(observe)
        self._cleanup_tasks[role] = task
        return await self._join_operation(role, task, errors)

    async def _join_operation(
        self,
        role: str,
        task: asyncio.Task[None],
        errors: list[Exception],
        *,
        cancelled_ok: bool = False,
    ) -> bool:
        done, _ = await asyncio.wait({task}, timeout=self._cleanup_timeout)
        if not done:
            # Keep the handle: timeout does not prove that the resource closed.
            errors.append(RuntimeError(f"{role} cleanup timed out"))
            return False
        try:
            task.result()
        except asyncio.CancelledError:
            if cancelled_ok:
                return True
            errors.append(RuntimeError(f"{role} cleanup cancelled"))
            return False
        except Exception as exc:
            failure = RuntimeError(f"{role} cleanup failed ({type(exc).__name__})")
            failure.__cause__ = exc
            errors.append(failure)
            return False
        return True
