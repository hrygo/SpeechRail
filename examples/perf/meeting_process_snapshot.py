"""Bounded caller-owned process-tree reads; no discovery by name or workload start.

libproc ABI: Apple XNU bsd/sys/resource.h and libsyscall/wrappers/libproc.
A sequential read span is not an atomic snapshot, a peak, or reaping proof.
No command lines, environment, paths, RSS fallback or process control is used.
"""

from __future__ import annotations

import ctypes
import math
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any, Protocol

_MAX_PROCESSES = 64


def _integer(value: Any, low: int, high: int) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ValueError("invalid process sample integer")
    return value


@dataclass(frozen=True, slots=True)
class ProcessKey:
    pid: int
    start_abstime: int

    def __post_init__(self) -> None:
        _integer(self.pid, 1, (1 << 31) - 1)
        _integer(self.start_abstime, 1, (1 << 64) - 1)


@dataclass(frozen=True, slots=True)
class ProcessUsage:
    key: ProcessKey
    phys_footprint_bytes: int

    def __post_init__(self) -> None:
        if type(self.key) is not ProcessKey:
            raise ValueError("invalid process sample identity")
        _integer(self.phys_footprint_bytes, 0, (1 << 64) - 1)


class ProcessReader(Protocol):
    backend: str

    def read(self, pid: int) -> ProcessUsage | None: ...

    def children(self, pid: int) -> tuple[int, ...]: ...


class _RusageInfoV0(ctypes.Structure):
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        *[
            (name, ctypes.c_uint64)
            for name in (
                "ri_user_time",
                "ri_system_time",
                "ri_pkg_idle_wkups",
                "ri_interrupt_wkups",
                "ri_pageins",
                "ri_wired_size",
                "ri_resident_size",
                "ri_phys_footprint",
                "ri_proc_start_abstime",
                "ri_proc_exit_abstime",
            )
        ],
    ]


class MacProcessReader:
    """Explicit native reader; construction never starts a sampler or model."""

    def __init__(self, *, _library: Any = None) -> None:
        self.backend = "injected" if _library is not None else "libproc_rusage_info_v0"
        if _library is None:
            if sys.platform != "darwin":
                raise ValueError("process footprint reader requires macOS")
            try:
                _library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            except OSError:
                raise ValueError("process footprint reader unavailable") from None
        self._library = _library
        self._library.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self._library.proc_pid_rusage.restype = ctypes.c_int
        self._library.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self._library.proc_listchildpids.restype = ctypes.c_int

    def read(self, pid: int) -> ProcessUsage | None:
        _integer(pid, 1, (1 << 31) - 1)
        info = _RusageInfoV0()
        result = self._library.proc_pid_rusage(pid, 0, ctypes.byref(info))
        if (
            type(result) is not int
            or result != 0
            or info.ri_proc_exit_abstime
            or not info.ri_proc_start_abstime
        ):
            return None
        return ProcessUsage(
            ProcessKey(pid, int(info.ri_proc_start_abstime)), int(info.ri_phys_footprint)
        )

    def children(self, pid: int) -> tuple[int, ...]:
        _integer(pid, 1, (1 << 31) - 1)
        buffer = (ctypes.c_int * (_MAX_PROCESSES + 1))()
        ctypes.set_errno(0)
        count = self._library.proc_listchildpids(pid, buffer, ctypes.sizeof(buffer))
        if ctypes.get_errno() or type(count) is not int or not 0 <= count < len(buffer):
            raise ValueError("process child enumeration failed or saturated")
        children = tuple(_integer(buffer[i], 1, (1 << 31) - 1) for i in range(count))
        if len(set(children)) != len(children):
            raise ValueError("duplicate process child")
        return children


def collect_process_snapshot(
    *,
    roots: Sequence[ProcessKey],
    reader: ProcessReader,
    clock: Callable[[], float] = time.monotonic,
    max_processes: int = _MAX_PROCESSES,
    max_span_seconds: float = 1.0,
) -> dict[str, Any]:
    """Fail closed on missing/changed identities, ancestry, budget or read span.

    The caller enrolls exact owned root lifetimes. All descendants are included;
    roots that are also descendants are deduplicated. A second pass verifies
    lifetime tokens and child sets, without claiming atomicity or peak coverage.
    """
    try:
        _integer(max_processes, 1, _MAX_PROCESSES)
        if (
            type(max_span_seconds) not in (int, float)
            or not math.isfinite(max_span_seconds)
            or not 0 < max_span_seconds <= 5
            or not 1 <= len(roots) <= 16
            or reader.backend not in {"injected", "libproc_rusage_info_v0"}
        ):
            raise ValueError("invalid process sample scope")
        expected: dict[int, ProcessKey] = {}
        for root in roots:
            if type(root) is not ProcessKey or expected.setdefault(root.pid, root) != root:
                raise ValueError("conflicting process sample roots")
        started = clock()
        if type(started) not in (int, float) or not math.isfinite(started):
            raise ValueError("invalid process sample clock")
        rows: dict[int, ProcessUsage] = {}
        edges: dict[int, tuple[int, ...]] = {}
        parents: dict[int, int] = {}
        pending = list(expected)
        while pending:
            pid = pending.pop(0)
            if pid in rows:
                continue
            if len(rows) >= max_processes:
                raise ValueError("process sample budget exceeded")
            usage = reader.read(pid)
            if (
                type(usage) is not ProcessUsage
                or usage.key.pid != pid
                or (pid in expected and usage.key != expected[pid])
            ):
                raise ValueError("process sample lifetime missing or changed")
            children = reader.children(pid)
            if (
                type(children) is not tuple
                or len(children) > max_processes
                or len(set(children)) != len(children)
            ):
                raise ValueError("invalid process children")
            rows[pid], edges[pid] = usage, children
            for child in children:
                _integer(child, 1, (1 << 31) - 1)
                if child == pid or parents.setdefault(child, pid) != pid:
                    raise ValueError("process ancestry changed")
                pending.append(child)
        depths: dict[int, int] = {}
        for pid in rows:
            seen = set()
            current = pid
            while current in parents:
                if current in seen:
                    raise ValueError("process ancestry cycle")
                seen.add(current)
                current = parents[current]
            depths[pid] = len(seen)
        # Ancestry order also holds when nested roots arrive child-first.
        for pid in sorted(rows, key=lambda item: depths[item], reverse=True):
            usage = reader.read(pid)
            if type(usage) is not ProcessUsage or usage.key != rows[pid].key:
                raise ValueError("process sample lifetime changed")
            children = reader.children(pid)
            if (
                type(children) is not tuple
                or len(children) != len(edges[pid])
                or set(children) != set(edges[pid])
            ):
                raise ValueError("process ancestry changed")
        ended = clock()
        if (
            type(ended) not in (int, float)
            or not math.isfinite(ended)
            or not 0 <= ended - started <= max_span_seconds
        ):
            raise ValueError("process sample span invalid")
        return {
            "schema_version": 1,
            "backend": reader.backend,
            "scope": "caller_owned_roots_and_descendants_sequential_span",
            "started_at": started,
            "ended_at": ended,
            "duration_seconds": ended - started,
            "processes": [
                {
                    "pid": row.key.pid,
                    "start_abstime": row.key.start_abstime,
                    "phys_footprint_bytes": row.phys_footprint_bytes,
                }
                for _, row in sorted(rows.items())
            ],
            "sample_sum_phys_footprint_bytes": sum(
                row.phys_footprint_bytes for row in rows.values()
            ),
            "atomic_snapshot_verified": False,
            "peak_footprint_verified": False,
            "worker_reaping_verified": False,
            "certification_eligible": False,
        }
    except Exception:
        raise ValueError("process footprint snapshot failed") from None
