"""Public AudioChunk stream validation shared by REST and Realtime v2 routes."""

from __future__ import annotations

from collections.abc import AsyncIterator

from speechrail.domain.ports import AudioChunk


class TTSDeliveryError(RuntimeError):
    """A public AudioChunk stream violated the application delivery contract."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


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
