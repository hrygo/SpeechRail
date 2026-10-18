"""Explicit phase observation of owned process trees; no workload or native default.

Reads run in a dedicated executor. Closing joins even a cancelled caller's
in-flight read; the read-span budget is post-hoc, not an interruptible deadline.
Phase coverage and observed maxima are metadata, never peak certification.
"""

from __future__ import annotations

import asyncio
import copy
import math
import time
from collections.abc import AsyncIterator, Sequence
from concurrent.futures import ThreadPoolExecutor
from contextlib import AbstractAsyncContextManager, asynccontextmanager, suppress
from functools import partial
from typing import Any

from meeting_process_snapshot import ProcessKey, ProcessReader, collect_process_snapshot

from speechrail.runtime.cleanup import join_cleanup

_PHASES = {"cold_start", "steady_state", "silence_recovery", "overlap", "finish", "cancel"}


def _number(value: Any, low: float, high: float) -> None:
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise ValueError("invalid observer policy number")


class ProcessPhaseObserver:
    """One-shot observer; use observe_process_phases to own its entire lifetime."""

    def __init__(
        self,
        *,
        roots: Sequence[ProcessKey],
        reader: ProcessReader,
        phases: Sequence[str],
        interval_seconds: float,
        max_samples: int,
        max_processes: int,
        max_span_seconds: float,
    ) -> None:
        roots, phases = tuple(roots), tuple(phases)
        if (
            not 1 <= len(roots) <= 16
            or any(type(root) is not ProcessKey for root in roots)
            or len({root.pid for root in roots}) != len(roots)
            or not 1 <= len(phases) <= 64
            or any(type(label) is not str or label not in _PHASES for label in phases)
            or type(max_samples) is not int
            or not 1 <= max_samples <= 4096
            or type(max_processes) is not int
            or not len(roots) <= max_processes <= 64
            or reader.backend not in {"injected", "libproc_rusage_info_v0"}
        ):
            raise ValueError("invalid observer policy")
        _number(interval_seconds, 0.01, 5)
        _number(max_span_seconds, 0.001, 5)
        self._roots, self._reader = roots, reader
        self._backend = reader.backend
        self._max_samples, self._max_processes = max_samples, max_processes
        self._labels = phases
        self._policy = {
            "interval_seconds": interval_seconds,
            "max_samples": max_samples,
            "max_processes": max_processes,
            "max_span_seconds": max_span_seconds,
        }
        self._windows: list[dict[str, Any]] = [
            {"index": i, "label": label, "started_at": None, "ended_at": None}
            for i, label in enumerate(phases)
        ]
        self._samples: list[dict[str, Any]] = []
        self._index = 0
        self._closed = False
        self._budget_exhausted = False
        self._monitor_failed = False
        self._closing: asyncio.Task[None] | None = None
        self._task: asyncio.Task[None] | None = None

    @property
    def sample_count(self) -> int:
        return len(self._samples)

    async def _start(self) -> None:
        if self._task is not None:
            raise ValueError("observer already started")
        self._stop = asyncio.Event()
        self._first = asyncio.Event()
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="meeting-footprint")
        self._windows[0]["started_at"] = time.monotonic()
        self._task = asyncio.create_task(self._run())
        # First attempt is owned before the caller starts the observed workload.
        await self._first.wait()

    def advance_phase(self, label: str) -> None:
        if self._task is None or self._task.done() or self._closing is not None or self._closed:
            raise ValueError("observer not active or closed")
        if self._index + 1 >= len(self._labels) or label != self._labels[self._index + 1]:
            raise ValueError("phase must be the next registered slot")
        now = time.monotonic()
        self._windows[self._index]["ended_at"] = now
        self._index += 1
        self._windows[self._index]["started_at"] = now

    async def _run(self) -> None:
        try:
            loop = asyncio.get_running_loop()
            for _ in range(self._max_samples):
                index = self._index
                started = time.monotonic()
                snapshot = None
                # Do not retain exception objects, command lines or paths.
                with suppress(Exception):
                    snapshot = await loop.run_in_executor(
                        self._executor,
                        partial(
                            collect_process_snapshot,
                            roots=self._roots,
                            reader=self._reader,
                            max_processes=self._max_processes,
                            max_span_seconds=self._policy["max_span_seconds"],
                        ),
                    )
                if snapshot is not None and snapshot["backend"] != self._backend:
                    snapshot = None
                ended = time.monotonic()
                window = self._windows[index]
                contained = index == self._index and (
                    window["ended_at"] is None or ended <= window["ended_at"]
                )
                status = (
                    "read_failed" if snapshot is None else ("ok" if contained else "cross_phase")
                )
                self._samples.append(
                    {
                        "requested_phase_index": index,
                        "phase_index": index if status == "ok" else None,
                        "status": status,
                        "started_at": started,
                        "ended_at": ended,
                        # Includes dispatch, native read and event-loop resumption;
                        # not CPU time or an isolated measurement of perturbation.
                        "observer_span_seconds": ended - started,
                        "read_started_at": None if snapshot is None else snapshot["started_at"],
                        "read_ended_at": None if snapshot is None else snapshot["ended_at"],
                        "read_span_seconds": (
                            None if snapshot is None else snapshot["duration_seconds"]
                        ),
                        "sample_sum_bytes": (
                            None
                            if snapshot is None
                            else snapshot["sample_sum_phys_footprint_bytes"]
                        ),
                        "processes": []
                        if snapshot is None
                        else [
                            [row["pid"], row["start_abstime"], row["phys_footprint_bytes"]]
                            for row in snapshot["processes"]
                        ],
                    }
                )
                self._first.set()
                if self._stop.is_set():
                    return
                if len(self._samples) == self._policy["max_samples"]:
                    self._budget_exhausted = True
                    return
                try:
                    await asyncio.wait_for(self._stop.wait(), self._policy["interval_seconds"])
                except TimeoutError:
                    continue
                return
        except Exception:
            self._monitor_failed = True
        finally:
            self._first.set()

    async def _finish(self) -> None:
        try:
            if self._task is not None:
                await self._task
        finally:
            # The in-flight native callable has completed before shutdown. Join
            # the executor off-loop as well; no worker thread is abandoned.
            await asyncio.to_thread(self._executor.shutdown, wait=True)
            self._closed = True

    async def _close(self) -> None:
        if self._closing is None:
            self._windows[self._index]["ended_at"] = time.monotonic()
            self._stop.set()
            self._closing = asyncio.create_task(self._finish())
        await join_cleanup(self._closing)

    def report(self) -> dict[str, Any]:
        if not self._closed:
            raise ValueError("observer not closed")
        phases = []
        for window in self._windows:
            values = [
                s["sample_sum_bytes"] for s in self._samples if s["phase_index"] == window["index"]
            ]
            phases.append(
                {
                    **window,
                    "valid_samples": len(values),
                    "observed_max_sample_sum_bytes": max(values) if values else None,
                }
            )
        failed = sum(s["status"] == "read_failed" for s in self._samples)
        complete = (
            all(p["valid_samples"] for p in phases)
            and not failed
            and not self._budget_exhausted
            and not self._monitor_failed
        )
        return copy.deepcopy(
            {
                "schema_version": 1,
                "status": "complete_metadata" if complete else "incomplete_metadata",
                "clock": "host_monotonic_seconds",
                "backend": self._backend,
                "scope": "caller_owned_roots_and_descendants_sequential_span",
                "roots": [[r.pid, r.start_abstime] for r in self._roots],
                "policy": self._policy,
                "phases": phases,
                "samples": self._samples,
                "failed_reads": failed,
                "cross_phase_reads": sum(s["status"] == "cross_phase" for s in self._samples),
                "sample_budget_exhausted": self._budget_exhausted,
                "monitor_failed": self._monitor_failed,
                "observer_thread_joined": True,
                "atomic_snapshot_verified": False,
                "peak_footprint_verified": False,
                "worker_reaping_verified": False,
                "runtime_identity_verified": False,
                "certification_eligible": False,
            }
        )


@asynccontextmanager
async def _observe(observer: ProcessPhaseObserver) -> AsyncIterator[ProcessPhaseObserver]:
    try:
        await observer._start()
        yield observer
    finally:
        await observer._close()


def observe_process_phases(
    *,
    roots: Sequence[ProcessKey],
    reader: ProcessReader,
    phases: Sequence[str],
    interval_seconds: float = 0.25,
    max_samples: int = 4096,
    max_processes: int = 64,
    max_span_seconds: float = 1.0,
) -> AbstractAsyncContextManager[ProcessPhaseObserver]:
    """Freeze scope/policy now; reading begins only on explicit async entry.

    The caller marks real phase boundaries and owns process provenance. This
    does not infer cold/warm conditions or start/stop/reap any observed process.
    """
    return _observe(
        ProcessPhaseObserver(
            roots=roots,
            reader=reader,
            phases=phases,
            interval_seconds=interval_seconds,
            max_samples=max_samples,
            max_processes=max_processes,
            max_span_seconds=max_span_seconds,
        )
    )
