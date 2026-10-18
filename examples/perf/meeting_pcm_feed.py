"""Bounded, sample-clocked in-memory PCM delivery; no models or file I/O.

Delivery timestamps describe this host producer, not microphone capture or
model acceptance. Injected clocks can only provide synthetic timing evidence.
"""

from __future__ import annotations

import asyncio
import hashlib
import math
import time
from collections.abc import AsyncIterator, Awaitable, Callable, Sequence
from dataclasses import dataclass, field
from typing import Any

from meeting_evaluation_identity import canonical_digest

from speechrail.runtime.cleanup import join_cleanup


@dataclass(frozen=True, slots=True)
class PcmChunk:
    sequence: int
    start_sample: int
    end_sample: int
    target_at: float
    offered_at: float
    pcm: bytes = field(repr=False)


class _Lane(AsyncIterator[PcmChunk]):
    def __init__(self, feed: CommonPcmFeed):
        self.feed = feed
        self.queue: asyncio.Queue[PcmChunk] = asyncio.Queue(feed.queue_chunks)
        self.ready = asyncio.Event()
        self.delivered = self.high_water = 0
        self.exhausted = self.busy = False
        self.max_queue_seconds = 0.0

    def __aiter__(self) -> _Lane:
        return self

    async def __anext__(self) -> PcmChunk:
        if self.feed.closed:
            raise ValueError("PCM source scope is closed")
        if self.busy:
            raise ValueError("concurrent reads from one PCM lane")
        if self.delivered == self.feed.samples:
            self.exhausted = True
            raise StopAsyncIteration
        self.busy = True
        self.ready.set()
        try:
            chunk = await self.queue.get()
            if chunk.start_sample != self.delivered:
                raise ValueError("PCM delivery sequence differs")
            self.delivered = chunk.end_sample
            self.max_queue_seconds = max(
                self.max_queue_seconds, self.feed.tick() - chunk.offered_at
            )
            return chunk
        finally:
            self.busy = False


class CommonPcmFeed:
    """One producer with fixed source deadlines and independently bounded lanes.

    The owner must join produce() and every consumer in one cancellation scope.
    Full queues fail immediately: backpressure never shifts the source clock.
    """

    def __init__(
        self,
        pcm: bytes,
        *,
        expected_pcm_sha256: str,
        lanes: Sequence[str],
        chunk_samples: int,
        queue_chunks: int,
        max_lateness_seconds: float,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ):
        if (
            type(pcm) is not bytes
            or not 0 < len(pcm) <= 600 * 16000 * 2
            or len(pcm) % 2
            or type(chunk_samples) is not int
            or not 1 <= chunk_samples <= 16000
            or (len(pcm) // 2 + chunk_samples - 1) // chunk_samples > 65536
            or type(queue_chunks) is not int
            or not 1 <= queue_chunks <= 64
            or type(max_lateness_seconds) not in (int, float)
            or not math.isfinite(max_lateness_seconds)
            or not 0 < max_lateness_seconds <= 1
            or not isinstance(expected_pcm_sha256, str)
            or len(expected_pcm_sha256) != 64
            or any(c not in "0123456789abcdef" for c in expected_pcm_sha256)
            or not lanes
            or len(set(lanes)) != len(lanes)
            or any(name not in {"asr", "diarization"} for name in lanes)
        ):
            raise ValueError("invalid common PCM feed")
        self.pcm, self.samples = pcm, len(pcm) // 2
        self.expected_pcm_sha256 = expected_pcm_sha256
        self.chunk_samples, self.queue_chunks = chunk_samples, queue_chunks
        self.max_lateness_seconds = float(max_lateness_seconds)
        self.clock, self.sleep = clock, sleep
        self.clock_source = (
            "monotonic" if clock is time.monotonic and sleep is asyncio.sleep else "injected"
        )
        self.previous: float | None = None
        self.lanes = {name: _Lane(self) for name in lanes}
        self.origin: float | None = None
        self.finished = self.started = self.closed = False
        self.max_lateness = 0.0
        self.chunks = 0
        self.final_offered_at: float | None = None

    def tick(self) -> float:
        value = self.clock()
        if (
            type(value) not in (int, float)
            or not math.isfinite(value)
            or (self.previous is not None and value < self.previous)
        ):
            raise ValueError("invalid PCM clock")
        self.previous = float(value)
        return self.previous

    def stream(self, name: str) -> AsyncIterator[PcmChunk]:
        return self.lanes[name]

    def verify_drained(self, name: str) -> None:
        if not self.lanes[name].exhausted:
            raise ValueError("PCM consumer did not exhaust its source")

    async def produce(self) -> None:
        if self.started or self.closed:
            raise ValueError("PCM producer cannot be reused")
        self.started = True
        digest = await join_cleanup(
            asyncio.create_task(asyncio.to_thread(lambda: hashlib.sha256(self.pcm).hexdigest()))
        )
        if digest != self.expected_pcm_sha256:
            raise ValueError("PCM source differs from preregistered digest")
        for lane in self.lanes.values():
            await lane.ready.wait()
        self.origin = self.tick()
        for start in range(0, self.samples, self.chunk_samples):
            end = min(start + self.chunk_samples, self.samples)
            target = self.origin + end / 16000
            delay = target - self.tick()
            if delay > 0:
                await self.sleep(delay)
            offered = self.tick()
            lateness = offered - target
            if lateness < 0 or lateness > self.max_lateness_seconds:
                raise ValueError("PCM source deadline missed")
            self.max_lateness = max(self.max_lateness, lateness)
            chunk = PcmChunk(
                self.chunks, start, end, target, offered, self.pcm[start * 2 : end * 2]
            )
            for lane in self.lanes.values():
                lane.queue.put_nowait(chunk)
                lane.high_water = max(lane.high_water, lane.queue.qsize())
            self.chunks += 1
            self.final_offered_at = offered
        self.finished = True

    def close(self) -> None:
        """Called only after producer and consumers have been joined."""
        self.closed = True
        self.pcm = b""
        for lane in self.lanes.values():
            while not lane.queue.empty():
                lane.queue.get_nowait()

    def summary(self) -> dict[str, Any]:
        if (
            self.closed
            or not self.finished
            or any(not lane.exhausted for lane in self.lanes.values())
        ):
            raise ValueError("PCM feed did not complete")
        assert self.origin is not None
        policy = {
            "clock_source": self.clock_source,
            "sample_rate": 16000,
            "chunk_samples": self.chunk_samples,
            "queue_chunks": self.queue_chunks,
            "max_lateness_seconds": self.max_lateness_seconds,
            "source_pcm_sha256": self.expected_pcm_sha256,
            "source_samples": self.samples,
        }
        return {
            **policy,
            "policy_sha256": canonical_digest(policy),
            "chunks": self.chunks,
            "timing_scope": "host_producer_sample_end_deadlines",
            "source_origin_at": self.origin,
            "source_end_target_at": self.origin + self.samples / 16000,
            "source_end_offered_at": self.final_offered_at,
            "source_duration_seconds": self.samples / 16000,
            "max_offer_lateness_seconds": self.max_lateness,
            "delivered_samples": {name: lane.delivered for name, lane in self.lanes.items()},
            "queue_high_water_chunks": {name: lane.high_water for name, lane in self.lanes.items()},
            "max_queue_seconds": {
                name: lane.max_queue_seconds for name, lane in self.lanes.items()
            },
            "model_acceptance_verified": False,
            "microphone_capture_verified": False,
        }
