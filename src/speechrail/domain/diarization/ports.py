"""Ports used by the diarization application actor, independent of transports."""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Protocol

from .types import ActivityUpdate, AlignmentRequest, AlignmentResult


class ActivitySession(Protocol):
    async def append(self, *, start_sample: int, pcm16: bytes) -> None: ...

    def updates(self) -> AsyncIterator[ActivityUpdate]: ...

    async def finish(self, *, through_sample: int) -> None: ...

    async def cancel(self) -> None: ...


class StreamingActivityPort(Protocol):
    def open(self, *, epoch: str) -> ActivitySession: ...


class AlignTextPort(Protocol):
    async def align(self, request: AlignmentRequest) -> AlignmentResult: ...
