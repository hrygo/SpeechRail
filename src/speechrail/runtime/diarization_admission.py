"""Single-session admission for the exclusive CoreML diarization worker."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from speechrail.runtime.busy import BusyReason


class DiarizationAdmissionFullError(RuntimeError):
    """Another continuous diarization session already owns the worker."""

    busy_reason = BusyReason.DIARIZATION_CAPACITY
    retryable = True


class DiarizationAdmission:
    """Reject rather than queue a second session that would duplicate CoreML state."""

    def __init__(self) -> None:
        self._active = 0
        self._quarantined_owner: object | None = None

    @property
    def quarantined(self) -> bool:
        return self._quarantined_owner is not None

    def quarantine(self, owner: object) -> None:
        """Keep the unreaped singleton and its resources alive until restart."""
        if self._quarantined_owner is None:
            self._quarantined_owner = owner
        self._active = 1

    @property
    def active(self) -> int:
        return self._active

    @asynccontextmanager
    async def reserve(self) -> AsyncIterator[None]:
        if self._active:
            raise DiarizationAdmissionFullError("diarization session capacity is full")
        self._active = 1
        try:
            yield
        finally:
            self._active = int(self.quarantined)
