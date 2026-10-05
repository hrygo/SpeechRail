"""Deterministic consumption credits, separate from transport deadlines."""

import asyncio

import pytest

from speechrail.application.tts_audio_window import TtsAudioWindow
from speechrail.domain.tts_stream import TtsStreamError


def test_consumption_progress_extends_wait_beyond_a_single_deadline() -> None:
    async def run() -> None:
        window = TtsAudioWindow(8, inactivity_seconds=0.1)
        await window.reserve(8)
        pending = asyncio.create_task(window.reserve(8))
        for offset in (1, 2, 3, 4):
            await asyncio.sleep(0.04)
            window.acknowledge(offset)
        assert await pending
        assert window.sent_samples == 8

    asyncio.run(run())


def test_duplicate_watermarks_do_not_extend_the_consumption_deadline() -> None:
    async def run() -> None:
        window = TtsAudioWindow(8, inactivity_seconds=0.05)
        await window.reserve(8)
        pending = asyncio.create_task(window.reserve(2))
        for _ in range(4):
            await asyncio.sleep(0.02)
            window.acknowledge(0)
        with pytest.raises(TtsStreamError, match="consumption"):
            await pending

    asyncio.run(run())


def test_close_wakes_a_blocked_consumer_without_granting_credit() -> None:
    async def run() -> None:
        window = TtsAudioWindow(8, inactivity_seconds=1)
        await window.reserve(8)
        pending = asyncio.create_task(window.reserve(2))
        await asyncio.sleep(0)
        window.close()
        assert await pending is False
        assert window.sent_samples == 4

    asyncio.run(run())
