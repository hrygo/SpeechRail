"""Bounded diagnostic transport for actual sealed ASR text, never references.

Overflow detaches this observer; it must not block or fail ASR transcription.
The independent ASR receiver owns its body. A failed stream is unusable for
joint evidence and cannot be recovered by a later successful finish.
"""

from __future__ import annotations

import asyncio
import math
import time
from collections import deque
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass, field
from typing import Any

from meeting_candidate_evidence import CompletedText


@dataclass(frozen=True, slots=True)
class LiveTextObservation:
    item: CompletedText = field(repr=False)
    observed_at: float


class LiveTextChannel(AsyncIterator[LiveTextObservation]):
    def __init__(
        self, *, samples: int, queue_items: int = 64, queue_characters: int = 10000,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if (
            type(samples) is not int or not 0 < samples <= 600 * 16000
            or type(queue_items) is not int or not 1 <= queue_items <= 4096
            or type(queue_characters) is not int or not 1 <= queue_characters <= 10000
        ):
            raise ValueError("invalid live text stream budget")
        self.samples = samples
        self.queue_items, self.queue_characters = queue_items, queue_characters
        self.clock = clock
        self._queue: deque[LiveTextObservation] = deque()
        self._ready = asyncio.Event()
        self._published = self._delivered = self._characters = self._queued_characters = 0
        self._through = 0
        self._previous: float | None = None
        self._failed = self._finished = self._closed = self._exhausted = self._reading = False
        self._producer_claimed = False

    def claim_producer(self) -> bool:
        if self._producer_claimed or self._failed or self._finished or self._closed:
            self.fail()
            return False
        self._producer_claimed = True
        return True

    def publish(self, item: CompletedText) -> bool:
        if self._failed or self._finished or self._closed:
            return False
        try:
            now = self.clock()
            valid = (
                isinstance(item, CompletedText)
                and type(item.sequence) is int and item.sequence == self._published
                and isinstance(item.text, str) and bool(item.text) and not item.units
                and type(item.span.start) is int and type(item.span.end) is int
                and self._through <= item.span.start < item.span.end <= self.samples
                and item.span.length <= 30 * 16000
                and self._published < 4096 and self._characters + len(item.text) <= 10000
                and len(self._queue) < self.queue_items
                and self._queued_characters + len(item.text) <= self.queue_characters
                and type(now) in (int, float) and math.isfinite(now)
                and (self._previous is None or now >= self._previous)
            )
        except Exception:
            valid = False
        if not valid:
            self.fail()
            return False
        self._queue.append(LiveTextObservation(item, float(now)))
        self._published += 1
        self._through = item.span.end
        self._characters += len(item.text)
        self._queued_characters += len(item.text)
        self._previous = float(now)
        self._ready.set()
        return True

    def finish(self) -> None:
        if not self._failed and not self._closed:
            self._finished = True
        self._ready.set()

    def fail(self) -> None:
        self._failed = True
        self._queue.clear()
        self._queued_characters = 0
        self._ready.set()

    def __aiter__(self) -> LiveTextChannel:
        return self

    async def __anext__(self) -> LiveTextObservation:
        if self._reading:
            raise ValueError("concurrent live text readers")
        self._reading = True
        try:
            while True:
                self._ready.clear()
                if self._failed or self._closed:
                    raise RuntimeError("live_text_stream_failed")
                if self._queue:
                    row = self._queue.popleft()
                    self._queued_characters -= len(row.item.text)
                    self._delivered += 1
                    return row
                if self._finished:
                    self._exhausted = True
                    raise StopAsyncIteration
                await self._ready.wait()
        finally:
            self._reading = False

    async def aclose(self) -> None:
        if not self._exhausted:
            self.fail()
        self._closed = True
        self._queue.clear()
        self._queued_characters = 0
        self._ready.set()

    def summary(self) -> dict[str, Any]:
        return {
            "published_items": self._published, "delivered_items": self._delivered,
            "published_characters": self._characters, "queued_items": len(self._queue),
            "queued_characters": self._queued_characters,
            "producer_finished": self._finished, "consumer_exhausted": self._exhausted,
            "producer_claimed": self._producer_claimed,
            "queue_items_limit": self.queue_items,
            "queue_characters_limit": self.queue_characters,
            "failed": self._failed, "closed": self._closed,
            "clock_source": "monotonic" if self.clock is time.monotonic else "injected",
            "runtime_identity_verified": False, "certification_eligible": False,
        }
