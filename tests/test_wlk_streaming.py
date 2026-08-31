from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

from speechrail.backends.wlk_streaming import WlkStreamingBackend


class FakeTransport:
    def __init__(self) -> None:
        self._frames = [
            {"lines": [], "buffer_transcription": "正在"},
            {
                "lines": [{"text": "正在讲话", "start": 0, "end": 1, "speaker": 0}],
                "buffer_transcription": "",
            },
        ]

    def snapshots(self) -> AsyncIterator[dict[str, object]]:
        async def iterator() -> AsyncIterator[dict[str, object]]:
            for frame in self._frames:
                yield frame

        return iterator()


def test_wlk_snapshots_are_normalized_before_becoming_streaming_events() -> None:
    async def collect() -> list[object]:
        backend = WlkStreamingBackend(FakeTransport(), source_epoch=3)
        return [event async for event in backend.events()]

    events = asyncio.run(collect())
    assert [event.kind for event in events] == ["partial", "completed"]
    assert events[0].text == "正在"
    assert events[1].segments[0].text == "正在讲话"
