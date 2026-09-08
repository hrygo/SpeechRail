"""Non-queuing, process-local admission for fixed-text alignment."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager


class AlignmentAdmissionFullError(RuntimeError):
    pass


class AlignmentAdmission:
    def __init__(self, limit: int = 3) -> None:
        if limit < 1:
            raise ValueError("alignment admission limit must be positive")
        self._limit = limit
        self._active = 0

    @property
    def active(self) -> int:
        return self._active

    @asynccontextmanager
    async def reserve(self) -> AsyncIterator[None]:
        if self._active >= self._limit:
            raise AlignmentAdmissionFullError("fixed-text alignment admission is full")
        self._active += 1
        try:
            yield
        finally:
            self._active -= 1
