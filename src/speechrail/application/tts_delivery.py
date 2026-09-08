"""Public AudioChunk stream validation shared by REST and Realtime routes."""

from __future__ import annotations

from collections.abc import AsyncIterator

from speechrail.application.deadline import await_until
from speechrail.domain.ports import AudioChunk


class TTSDeliveryError(RuntimeError):
    """A public AudioChunk stream violated the application delivery contract."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class PcmOutputCounter:
    """Count a bounded PCM16 stream without retaining its audio payload."""

    def __init__(self, limit_bytes: int) -> None:
        if limit_bytes < 0:
            raise ValueError("limit_bytes must be non-negative")
        self._limit_bytes = limit_bytes
        self._total_bytes = 0

    @property
    def total_bytes(self) -> int:
        """Return the number of accepted PCM bytes."""
        return self._total_bytes

    def accept(self, byte_count: int) -> None:
        """Accept one PCM chunk size, rejecting malformed or oversized output."""
        if byte_count < 0 or byte_count % 2:
            raise TTSDeliveryError("tts_audio_invalid")
        next_total = self._total_bytes + byte_count
        if next_total > self._limit_bytes:
            raise OverflowError("audio_too_large")
        self._total_bytes = next_total


async def iter_validated_audio(
    source: AsyncIterator[AudioChunk],
) -> AsyncIterator[AudioChunk]:
    """Validate one SpeechSynthesizer stream: response boundary, order and PCM16.

    The backend response ID is only checked for internal stream consistency; it
    never replaces a public SpeechSession response ID.  Closing is best-effort:
    the port promises an AsyncIterator, so ``aclose`` is used only when the
    concrete source exposes it.
    """
    expected_index = 0
    backend_response_id: str | None = None
    try:
        async for chunk in source:
            backend_response_id = backend_response_id or chunk.response_id
            if chunk.response_id != backend_response_id:
                raise TTSDeliveryError("tts_response_id_invalid")
            if chunk.chunk_index != expected_index:
                raise TTSDeliveryError("tts_chunk_order_invalid")
            if len(chunk.audio) % 2:
                raise TTSDeliveryError("tts_audio_invalid")
            expected_index += 1
            yield chunk
    finally:
        close = getattr(source, "aclose", None)
        if close is not None:
            await close()


async def iter_until[T](source: AsyncIterator[T], expires_at: float) -> AsyncIterator[T]:
    """Consume an async iterator with one shared absolute deadline."""
    try:
        while True:
            try:
                yield await await_until(anext(source), expires_at)
            except StopAsyncIteration:
                return
    finally:
        close = getattr(source, "aclose", None)
        if close is not None:
            await close()
