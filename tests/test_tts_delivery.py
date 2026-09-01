"""Application-level TTS delivery stream validation, frozen before wiring."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

import pytest
from pydantic import ValidationError

from speechrail.application.tts_delivery import TTSDeliveryError, iter_validated_audio
from speechrail.domain.ports import AudioChunk, SpeechRequest


def _chunks(*chunks: AudioChunk) -> AsyncIterator[AudioChunk]:
    async def stream() -> AsyncIterator[AudioChunk]:
        for chunk in chunks:
            yield chunk

    return stream()


class _CloseTrackingSource:
    """Observable source generator: yields canned chunks, counts aclose calls."""

    def __init__(self, chunks: list[AudioChunk], *, fail_on: int | None = None) -> None:
        self._chunks = list(chunks)
        self._position = 0
        self._fail_on = fail_on
        self.aclose_calls = 0

    def __aiter__(self) -> _CloseTrackingSource:
        return self

    async def __anext__(self) -> AudioChunk:
        if self._fail_on is not None and self._position == self._fail_on:
            raise ValueError("source exploded")
        if self._position >= len(self._chunks):
            raise StopAsyncIteration
        chunk = self._chunks[self._position]
        self._position += 1
        return chunk

    async def aclose(self) -> None:
        self.aclose_calls += 1


def test_valid_stream_passes_through_in_order() -> None:
    source = _chunks(
        AudioChunk(response_id="backend-a", chunk_index=0, audio=b"\x00\x00"),
        AudioChunk(response_id="backend-a", chunk_index=1, audio=b"\x01\x00"),
    )

    async def scenario() -> list[AudioChunk]:
        return [chunk async for chunk in iter_validated_audio(source)]

    chunks = asyncio.run(scenario())

    assert [chunk.chunk_index for chunk in chunks] == [0, 1]


def test_empty_stream_completes_without_error() -> None:
    source = _chunks()

    async def scenario() -> list[AudioChunk]:
        return [chunk async for chunk in iter_validated_audio(source)]

    assert asyncio.run(scenario()) == []


def test_first_chunk_must_be_index_zero() -> None:
    source = _chunks(AudioChunk(response_id="backend-a", chunk_index=1, audio=b"\x00\x00"))

    async def scenario() -> None:
        with pytest.raises(TTSDeliveryError, match="tts_chunk_order_invalid"):
            async for _ in iter_validated_audio(source):
                pass

    asyncio.run(scenario())


def test_gap_in_chunk_index_is_rejected() -> None:
    source = _chunks(
        AudioChunk(response_id="backend-a", chunk_index=0, audio=b"\x00\x00"),
        AudioChunk(response_id="backend-a", chunk_index=2, audio=b"\x01\x00"),
    )

    async def scenario() -> None:
        with pytest.raises(TTSDeliveryError, match="tts_chunk_order_invalid"):
            async for _ in iter_validated_audio(source):
                pass

    asyncio.run(scenario())


def test_duplicate_chunk_index_is_rejected() -> None:
    source = _chunks(
        AudioChunk(response_id="backend-a", chunk_index=0, audio=b"\x00\x00"),
        AudioChunk(response_id="backend-a", chunk_index=0, audio=b"\x01\x00"),
    )

    async def scenario() -> None:
        with pytest.raises(TTSDeliveryError, match="tts_chunk_order_invalid"):
            async for _ in iter_validated_audio(source):
                pass

    asyncio.run(scenario())


def test_rejects_backend_response_switch() -> None:
    source = _chunks(
        AudioChunk(response_id="backend-a", chunk_index=0, audio=b"\x00\x00"),
        AudioChunk(response_id="backend-b", chunk_index=1, audio=b"\x00\x00"),
    )

    async def scenario() -> None:
        with pytest.raises(TTSDeliveryError, match="tts_response_id_invalid"):
            async for _ in iter_validated_audio(source):
                pass

    asyncio.run(scenario())


def test_odd_pcm_bytes_are_rejected() -> None:
    source = _chunks(AudioChunk(response_id="backend-a", chunk_index=0, audio=b"\x00"))

    async def scenario() -> None:
        with pytest.raises(TTSDeliveryError, match="tts_audio_invalid"):
            async for _ in iter_validated_audio(source):
                pass

    asyncio.run(scenario())


def test_source_error_propagates_and_closes_source_once() -> None:
    source = _CloseTrackingSource(
        [AudioChunk(response_id="backend-a", chunk_index=0, audio=b"\x00\x00")],
        fail_on=1,
    )

    async def scenario() -> int:
        collected = 0
        try:
            async for _chunk in iter_validated_audio(source):
                collected += 1
        except ValueError:
            pass
        return source.aclose_calls

    assert asyncio.run(scenario()) == 1


def test_consumer_cancel_closes_source_once() -> None:
    source = _CloseTrackingSource(
        [
            AudioChunk(response_id="backend-a", chunk_index=0, audio=b"\x00\x00"),
            AudioChunk(response_id="backend-a", chunk_index=1, audio=b"\x01\x00"),
            AudioChunk(response_id="backend-a", chunk_index=2, audio=b"\x02\x00"),
        ]
    )

    async def scenario() -> int:
        agen = iter_validated_audio(source).__aiter__()
        await agen.__anext__()
        task = asyncio.ensure_future(agen.__anext__())
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        await agen.aclose()
        return source.aclose_calls

    assert asyncio.run(scenario()) == 1


def test_wrapped_stream_exposes_the_original_chunks() -> None:
    source = _chunks(
        AudioChunk(response_id="backend-a", chunk_index=0, audio=b"\x00\x00"),
        AudioChunk(response_id="backend-a", chunk_index=1, audio=b"\x01\x00"),
    )

    async def scenario() -> list[AudioChunk]:
        return [chunk async for chunk in iter_validated_audio(source)]

    chunks: list[AudioChunk] = asyncio.run(scenario())

    assert [chunk.audio for chunk in chunks] == [b"\x00\x00", b"\x01\x00"]


def test_speech_request_rejects_unknown_instructions() -> None:
    with pytest.raises(ValidationError):
        SpeechRequest(
            text="hello",
            voice="vivian",
            instructions="must not cross the internal port",  # type: ignore[call-arg]
        )
