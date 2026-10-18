"""Explicit outer observation of this isolated runner and its descendants.

Enter before private runtime loading; exit after its joined cleanup. This never
starts, kills, waits for, or reaps an observed worker. Metadata is not E3 proof.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import AsyncIterator, Sequence
from contextlib import AbstractAsyncContextManager, asynccontextmanager, suppress
from typing import Any

from meeting_process_observer import (
    ProcessPhaseObserver,
    observation_policy,
    observe_process_phases,
    registered_phases,
)
from meeting_process_owner import OwnedProcessScope, run_process_read
from meeting_process_snapshot import (
    ProcessKey,
    ProcessReader,
    ProcessUsage,
    collect_process_snapshot,
)

from speechrail.runtime.cleanup import join_cleanup

_ACTIVE: object | None = None
_ROLE_SETS = {
    ("diarization",),
    ("asr", "aligner"),
    ("asr", "aligner", "diarization"),
}


def _initial_root(pid: int, reader: ProcessReader, policy: dict[str, Any]) -> ProcessKey:
    try:
        usage = reader.read(pid)
        if type(usage) is not ProcessUsage or usage.key.pid != pid:
            raise ValueError
        snapshot = collect_process_snapshot(
            roots=(usage.key,),
            reader=reader,
            max_processes=policy["max_processes"],
            max_span_seconds=policy["max_span_seconds"],
        )
        if len(snapshot["processes"]) != 1:
            raise ValueError
        return usage.key
    except Exception:
        raise ValueError("runner is not isolated or its root is unreadable") from None


class RunnerProcessObservation:
    def __init__(
        self,
        *,
        pid: int,
        reader: ProcessReader,
        expected_roles: tuple[str, ...],
        phases: tuple[str, ...],
        policy: dict[str, Any],
    ) -> None:
        self._pid, self._reader, self._backend = pid, reader, reader.backend
        self._expected, self._phases, self._policy = expected_roles, phases, policy
        self._workers: dict[str, tuple[ProcessKey, object]] = {}
        self._monitor: ProcessPhaseObserver | None = None
        self._post_index: int | None = None
        self._closed = False
        self._root: ProcessKey

    def _guard(self) -> None:
        if os.getpid() != self._pid or self._reader.backend != self._backend:
            raise ValueError("runner identity or reader changed")

    def _active(self) -> ProcessPhaseObserver:
        if self._closed or self._monitor is None:
            raise ValueError("runner observation is not active")
        self._guard()
        return self._monitor

    def register_owner(self, *, roles: Sequence[str], scope: OwnedProcessScope) -> None:
        self._active()
        roles = tuple(roles)
        if (
            type(scope) is not OwnedProcessScope
            or scope._reader is not self._reader
            or len(roles) != len(scope.roots)
            or len(set(roles)) != len(roles)
            or any(role not in self._expected or role in self._workers for role in roles)
        ):
            raise ValueError("invalid runner owner registration")
        scope.verify()
        keys = {key for key, _ in self._workers.values()}
        if any(key.pid == self._pid or key in keys for key in scope.roots):
            raise ValueError("duplicate runner process registration")
        for role, key, handle in zip(roles, scope.roots, scope._handles, strict=True):
            self._workers[role] = (key, handle)

    def advance_phase(self, label: str) -> None:
        self._active().advance_phase(label)

    async def checkpoint(self) -> int:
        return await self._active().checkpoint()

    def report(self) -> dict[str, Any]:
        if not self._closed or self._monitor is None:
            raise ValueError("runner observation not closed")
        observation = self._monitor.report()
        registered = set(self._workers) == set(self._expected)
        closed = registered and all(
            type(getattr(handle, "pid", None)) is int
            and getattr(handle, "pid", None) == key.pid
            and type(getattr(handle, "returncode", None)) is int
            for key, handle in self._workers.values()
        )
        known = {(self._root.pid, self._root.start_abstime)} | {
            (key.pid, key.start_abstime) for key, _ in self._workers.values()
        }
        seen: set[tuple[int, int]] = set()
        unknown_count = 0
        for sample in observation["samples"]:
            for pid, token, _ in sample["processes"]:
                pair = (pid, token)
                seen.add(pair)
                unknown_count += pair not in known
        all_registered_observed = registered and all(
            (key.pid, key.start_abstime) in seen for key, _ in self._workers.values()
        )
        post = None if self._post_index is None else observation["samples"][self._post_index]
        empty = bool(
            post is not None
            and post["status"] == "ok"
            and len(post["processes"]) == 1
            and post["processes"][0][:2] == [self._root.pid, self._root.start_abstime]
        )
        complete = (
            observation["status"] == "complete_metadata"
            and closed
            and all_registered_observed
            and not unknown_count
            and empty
        )
        return {
            "schema_version": 1,
            "status": "complete_metadata" if complete else "incomplete_metadata",
            "scope": "isolated_current_runner_and_descendants",
            "expected_roles": list(self._expected),
            "registered_roles": [role for role in self._expected if role in self._workers],
            "registered_handles_closed": closed,
            "all_registered_observed": all_registered_observed,
            "unregistered_process_readings": unknown_count,
            "post_cleanup_sample_index": self._post_index,
            "post_cleanup_empty": empty,
            "observation": observation,
            "worker_reaping_verified": False,
            "peak_footprint_verified": False,
            "runtime_identity_verified": False,
            "certification_eligible": False,
        }


@asynccontextmanager
async def _observe(runner: RunnerProcessObservation) -> AsyncIterator[RunnerProcessObservation]:
    global _ACTIVE
    token = object()
    if _ACTIVE is not None:
        raise ValueError("runner resource observation already active")
    _ACTIVE = token
    try:
        runner._root = await run_process_read(
            lambda: _initial_root(runner._pid, runner._reader, runner._policy)
        )
        runner._guard()
        async with observe_process_phases(
            roots=(runner._root,),
            reader=runner._reader,
            phases=runner._phases,
            scope_guard=runner._guard,
            **runner._policy,
        ) as monitor:
            runner._monitor = monitor
            try:
                yield runner
            finally:

                async def post_cleanup() -> None:
                    # Exhausted/failed monitor cannot reuse a pre-cleanup sample.
                    with suppress(ValueError):
                        runner._post_index = await monitor.checkpoint()

                await join_cleanup(asyncio.create_task(post_cleanup()))
    finally:
        runner._closed = True
        if _ACTIVE is token:
            _ACTIVE = None


def observe_runner_process_tree(
    *,
    reader: ProcessReader,
    expected_roles: Sequence[str],
    phases: Sequence[str],
    interval_seconds: float = 0.25,
    max_samples: int = 4096,
    max_processes: int = 64,
    max_span_seconds: float = 1.0,
) -> AbstractAsyncContextManager[RunnerProcessObservation]:
    """Freeze the outer scenario before any read, runtime construction or load."""
    roles, labels = tuple(expected_roles), registered_phases(phases)
    if (
        roles not in _ROLE_SETS
        or labels[0] != "cold_start"
        or labels[-1] not in {"finish", "cancel"}
        or reader.backend not in {"injected", "libproc_rusage_info_v0"}
    ):
        raise ValueError("invalid runner resource policy")
    policy = observation_policy(
        interval_seconds=interval_seconds,
        max_samples=max_samples,
        max_processes=max_processes,
        max_span_seconds=max_span_seconds,
    )
    return _observe(
        RunnerProcessObservation(
            pid=os.getpid(),
            reader=reader,
            expected_roles=roles,
            phases=labels,
            policy=policy,
        )
    )
