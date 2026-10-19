"""Shared-PCM activity workload; no fixed text, model startup or certification.

The caller supplies the actual ActivitySession factory bound to its governor.
This adapter alone cannot attest that binding, artifacts or exact child reaping.
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from typing import Any

from meeting_candidate_runner import run_candidate_stream
from meeting_live_text import LiveTextChannel
from meeting_pcm_feed import PcmChunk, PcmSequenceVerifier

from speechrail.domain.diarization.ports import ActivitySession
from speechrail.runtime.cleanup import join_cleanup


async def run_shared_activity_stream(
    pcm: bytes,
    frames: AsyncIterator[PcmChunk],
    *,
    activity_factory: Callable[[], ActivitySession],
    epoch: str,
    sink: Callable[[Mapping[str, Any]], Awaitable[None]],
    text_channel: LiveTextChannel | None = None,
    timeout_seconds: float = 1800,
    sink_timeout_seconds: float = 5,
    clock: Callable[[], float] = time.monotonic,
) -> dict[str, Any]:
    """Consume the existing source clock without pacing it a second time."""
    async def packets() -> AsyncIterator[bytes]:
        async for frame in frames:
            verified.accept(frame)
            yield frame.pcm
        verified.finish()

    try:
        verified = PcmSequenceVerifier(pcm)
        if text_channel is not None and text_channel.samples != len(pcm) // 2:
            raise ValueError("live text source length differs from activity source")
        result = await run_candidate_stream(
            packets(), activity_factory=activity_factory, text_replay=None,
            epoch=epoch, sink=sink, input_mode="throughput",
            text_channel=text_channel,
            timeout_seconds=timeout_seconds, sink_timeout_seconds=sink_timeout_seconds,
            clock=clock,
        )
        return {
            **result,
            "input_mode": "shared_pcm",
            "input_clock": "external_shared_source_unverified",
            "shared_pcm": verified.summary(),
        }
    finally:
        if text_channel is not None:
            await text_channel.aclose()
        close = getattr(frames, "aclose", None)
        if close is not None:
            await join_cleanup(asyncio.create_task(close(), name="activity-source-close"))
