"""Bind live private-owner handles to explicit process lifetimes, without discovery.

This is a ready-owner observation scope, not cold-start or loaded-byte proof.
The enclosing runtime keeps lifecycle responsibility and must outlive the scope.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass

from meeting_process_observer import ProcessPhaseObserver, observe_process_phases
from meeting_process_snapshot import (
    ProcessKey,
    ProcessReader,
    ProcessUsage,
    collect_process_snapshot,
)

from speechrail.runtime.cleanup import join_cleanup


def _pids(handles: tuple[object, ...]) -> tuple[int, ...]:
    if type(handles) is not tuple or not 1 <= len(handles) <= 16:
        raise ValueError("invalid process owner handles")
    values = []
    for handle in handles:
        pid = getattr(handle, "pid", None)
        if (
            type(pid) is not int
            or not 1 <= pid < (1 << 31)
            or getattr(handle, "returncode", False) is not None
        ):
            raise ValueError("process owner is not live")
        values.append(pid)
    if len(set(values)) != len(values):
        raise ValueError("duplicate process owner handles")
    return tuple(values)


@dataclass(frozen=True, slots=True)
class OwnedProcessScope:
    roots: tuple[ProcessKey, ...]
    _handles: tuple[object, ...]
    _get_processes: Callable[[], tuple[object, ...]]
    _reader: ProcessReader
    _backend: str

    def verify(self) -> None:
        """Event-loop guard; hold exact handle objects, never rediscover by PID."""
        try:
            current = self._get_processes()
            if (
                type(current) is not tuple
                or len(current) != len(self._handles)
                or any(now is not old for now, old in zip(current, self._handles, strict=True))
                or _pids(current) != tuple(root.pid for root in self.roots)
                or self._reader.backend != self._backend
            ):
                raise ValueError
        except Exception:
            raise ValueError("process owner scope changed or closed") from None

    def observe(
        self,
        *,
        phases: Sequence[str],
        interval_seconds: float = 0.25,
        max_samples: int = 4096,
        max_processes: int = 64,
        max_span_seconds: float = 1.0,
    ) -> AbstractAsyncContextManager[ProcessPhaseObserver]:
        self.verify()
        phases = tuple(phases)
        if "cold_start" in phases:
            raise ValueError("ready process owner scope cannot cover cold start")
        return observe_process_phases(
            roots=self.roots,
            reader=self._reader,
            phases=phases,
            interval_seconds=interval_seconds,
            max_samples=max_samples,
            max_processes=max_processes,
            max_span_seconds=max_span_seconds,
            scope_guard=self.verify,
        )


def _read_roots(pids: tuple[int, ...], reader: ProcessReader) -> tuple[ProcessKey, ...]:
    try:
        keys = []
        for pid in pids:
            usage = reader.read(pid)
            if type(usage) is not ProcessUsage or usage.key.pid != pid:
                raise ValueError
            keys.append(usage.key)
        # Recheck lifetimes and descendants instead of trusting a first PID read.
        collect_process_snapshot(roots=keys, reader=reader)
        return tuple(keys)
    except Exception:
        raise ValueError("process owner lifetime enrollment failed") from None


async def capture_owned_process_scope(
    *, get_processes: Callable[[], tuple[object, ...]], reader: ProcessReader
) -> OwnedProcessScope:
    """Join enrollment and its dedicated thread, then recheck the actual owner.

    The getter must guard an actual private runtime. Bare PID lists or copies
    of handles cannot establish its ownership or model provenance here.
    """
    try:
        handles = get_processes()
        pids = _pids(handles)
        backend = reader.backend
        if backend not in {"injected", "libproc_rusage_info_v0"}:
            raise ValueError
    except Exception:
        raise ValueError("process owner unavailable for enrollment") from None
    pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="meeting-owner-enroll")

    async def read() -> tuple[ProcessKey, ...]:
        return await asyncio.get_running_loop().run_in_executor(pool, _read_roots, pids, reader)

    try:
        roots = await join_cleanup(asyncio.create_task(read()))
    finally:
        await join_cleanup(asyncio.create_task(asyncio.to_thread(pool.shutdown, wait=True)))
    scope = OwnedProcessScope(roots, handles, get_processes, reader, backend)
    scope.verify()
    return scope
