"""Bounded single-writer pump for realtime outbound events."""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import Awaitable, Callable
from typing import Any

OutboundEvent = dict[str, Any]
SendEvent = Callable[[OutboundEvent], Awaitable[None]]


class SlowConsumerError(RuntimeError):
    """The peer cannot consume ordered realtime output within the queue budget."""


class BoundedOutboundEventPump:
    """Serializes sends and bounds queued events without retaining audio indefinitely."""

    def __init__(self, *, max_events: int, send: SendEvent) -> None:
        if max_events < 1:
            raise ValueError("max_events must be positive")
        self._events: asyncio.Queue[OutboundEvent | None] = asyncio.Queue(maxsize=max_events)
        self._send = send
        self._writer: asyncio.Task[None] | None = None

    async def start(self) -> None:
        if self._writer is not None:
            raise RuntimeError("outbound pump has already started")
        self._writer = asyncio.create_task(self._write())
        await asyncio.sleep(0)

    async def publish(self, event: OutboundEvent) -> None:
        if self._writer is None:
            raise RuntimeError("outbound pump has not started")
        if self._writer.done():
            await self._writer
            raise RuntimeError("outbound writer stopped unexpectedly")
        try:
            self._events.put_nowait(event)
        except asyncio.QueueFull:
            raise SlowConsumerError("realtime outbound queue is full") from None

    async def finish(self) -> None:
        if self._writer is None:
            return
        try:
            self._events.put_nowait(None)
        except asyncio.QueueFull:
            await self.abort()
            raise SlowConsumerError("realtime outbound queue is full") from None
        await self._writer
        self._writer = None

    async def abort(self) -> None:
        if self._writer is None:
            return
        self._writer.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self._writer
        self._writer = None

    async def _write(self) -> None:
        while True:
            event = await self._events.get()
            if event is None:
                return
            await self._send(event)
