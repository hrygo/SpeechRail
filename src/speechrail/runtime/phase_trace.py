"""Bounded, optional wall-clock diagnostics; never perform I/O inside a lease.

Durations include transport/native waiting, not just accelerator execution.
Invalid clocks and overflow invalidate evidence without interrupting reclamation.
"""

from __future__ import annotations

import asyncio
import math
import time
from collections.abc import Callable
from types import TracebackType
from typing import Literal

Phase = Literal["compute_queue", "load", "infer", "finalize", "close"]
Operation = Literal["append", "finish", "start", "close"]
_PHASES = frozenset({"compute_queue", "load", "infer", "finalize", "close"})


class PhaseTrace:
    """Event-loop-local recorder. Drain between calls; loss permanently invalidates it."""

    def __init__(self, *, capacity: int = 256, clock: Callable[[], float] = time.monotonic):
        if type(capacity) is not int or not 1 <= capacity <= 65536:
            raise ValueError("invalid phase trace capacity")
        self._capacity = capacity
        self._clock = clock
        self._clock_source = "monotonic" if clock is time.monotonic else "injected"
        self._previous: float | None = None
        self._events: list[dict[str, object]] = []
        self._reason: str | None = None
        self._open = 0
        self._count = 0
        self._completed: set[str] = set()

    def _now(self) -> float | None:
        try:
            value = self._clock()
            if (
                type(value) not in (int, float)
                or not math.isfinite(value)
                or (self._previous is not None and value < self._previous)
            ):
                raise ValueError
            self._previous = float(value)
            return float(value)
        except Exception:
            self._reason = self._reason or "invalid_clock"
            return None

    def span(
        self, phase: Phase, operation: Operation, *, through_sample: int | None = None
    ) -> PhaseSpan:
        if phase not in _PHASES or operation not in {"append", "finish", "start", "close"}:
            raise ValueError("invalid phase trace label")
        if through_sample is not None and (type(through_sample) is not int or through_sample < 0):
            raise ValueError("invalid phase trace sample")
        return PhaseSpan(self, phase, operation, through_sample)

    def drain(self) -> tuple[dict[str, object], ...]:
        events = tuple(self._events)
        self._events = []
        return events

    def status(self) -> dict[str, object]:
        return {
            "enabled": True,
            "complete": self._reason is None and self._open == 0 and self._count > 0,
            "reason": self._reason,
            "clock_source": self._clock_source,
            "open_spans": self._open,
            "pending_count": len(self._events),
            "event_count": self._count,
            "required_phases_observed": self._completed == _PHASES,
        }


class PhaseSpan:
    def __init__(
        self, trace: PhaseTrace | None, phase: Phase, operation: Operation,
        through_sample: int | None = None,
    ) -> None:
        self._trace = trace
        self._phase = phase
        self._operation = operation
        self._through = through_sample
        self._start: float | None = None
        self._ended = False

    def __enter__(self) -> PhaseSpan:
        if self._trace is not None:
            self._trace._open += 1
            self._start = self._trace._now()
        return self

    def finish(self, status: str = "completed") -> None:
        if self._ended:
            return
        self._ended = True
        trace = self._trace
        if trace is None:
            return
        trace._open -= 1
        end = trace._now()
        if self._start is None or end is None:
            return
        trace._count += 1
        if len(trace._events) >= trace._capacity:
            trace._reason = trace._reason or "capacity_exceeded"
            return
        trace._events.append({
            "phase": self._phase, "operation": self._operation,
            "through_sample": self._through, "started_monotonic_seconds": self._start,
            "ended_monotonic_seconds": end, "duration_seconds": end - self._start,
            "status": status, "clock_source": trace._clock_source,
        })
        if status == "completed":
            trace._completed.add(self._phase)

    def __exit__(
        self, exc_type: type[BaseException] | None, exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.finish(
            "cancelled" if isinstance(exc, asyncio.CancelledError)
            else "failed" if exc is not None else "completed"
        )
