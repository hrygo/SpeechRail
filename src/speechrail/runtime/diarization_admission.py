"""Single-session admission for the exclusive CoreML diarization worker."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager


class DiarizationAdmissionFullError(RuntimeError):
    """Another continuous diarization session already owns the worker."""


class DiarizationAdmission:
    """Reject rather than queue a second session that would duplicate CoreML state."""

    def __init__(self) -> None:
        self._active = 0

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
            self._active = 0
