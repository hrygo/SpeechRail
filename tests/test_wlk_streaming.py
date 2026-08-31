from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

from speechrail.backends.wlk_streaming import WlkRealtimeSession, WlkStreamingBackend


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


def test_wlk_realtime_session_hides_vendor_snapshots_behind_streaming_events() -> None:
    class FakeConnection:
        uri = "ws://127.0.0.1:8001/asr?language=zh&mode=full"

        def __init__(self) -> None:
            self.sent: list[bytes] = []
            self.messages = iter(
                [
                    '{"type":"config"}',
                    '{"lines":[],"buffer_transcription":"正在"}',
                    '{"lines":[{"text":"正在讲话","start":0,"end":1}],'
                    '"buffer_transcription":""}',
                    '{"type":"ready_to_stop"}',
                ]
            )

        async def send(self, message: bytes) -> None:
            self.sent.append(message)

        async def recv(self) -> str:
            return next(self.messages)

        async def close(self) -> None:
            return None

    connection = FakeConnection()

    async def collect() -> list[object]:
        session = WlkRealtimeSession(
            url="ws://127.0.0.1:8001",
            language="zh",
            connection_factory=lambda _: _connection(connection),
        )
        await session.connect()
        await session.append_audio(b"\x00\x00")
        await session.commit()
        events = [event async for event in session.events()]
        await session.close()
        return events

    events = asyncio.run(collect())

    assert [event.kind for event in events] == ["partial", "completed"]
    assert events[0].text == "正在"
    assert events[1].segments[0].text == "正在讲话"
    assert connection.sent == [b"\x00\x00", b""]


async def _connection(connection: object) -> object:
    return connection
