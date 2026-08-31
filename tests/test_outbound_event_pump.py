from __future__ import annotations

import asyncio

import pytest

from speechrail.realtime.outbound import BoundedOutboundEventPump, SlowConsumerError


def test_bounded_event_pump_rejects_a_producer_that_outpaces_the_writer() -> None:
    async def scenario() -> None:
        release_writer = asyncio.Event()

        async def blocked_send(_event: dict[str, object]) -> None:
            await release_writer.wait()

        pump = BoundedOutboundEventPump(max_events=1, send=blocked_send)
        await pump.start()
        await pump.publish({"type": "response.audio.delta", "chunk_index": 0})
        await asyncio.sleep(0)
        await pump.publish({"type": "response.audio.delta", "chunk_index": 1})

        with pytest.raises(SlowConsumerError):
            await pump.publish({"type": "response.audio.delta", "chunk_index": 2})

        await pump.abort()

    asyncio.run(scenario())
