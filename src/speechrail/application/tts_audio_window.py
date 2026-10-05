"""Request-scoped PCM consumption credits, independent of model and playback."""

from __future__ import annotations

import asyncio

from speechrail.domain.tts_stream import TtsStreamError


class TtsAudioWindow:
    """Bound sent-but-unconsumed PCM without retaining audio or owning playback."""

    def __init__(self, maximum_bytes: int, *, inactivity_seconds: float = 2.0) -> None:
        self.maximum_bytes = maximum_bytes
        self.sent_samples = 0
        self.consumed_samples = 0
        self.closed = False
        self._changed = asyncio.Event()
        self._inactivity_seconds = inactivity_seconds
        self._last_progress_at = 0.0

    async def reserve(self, byte_length: int) -> bool:
        if byte_length <= 0 or byte_length % 2 or byte_length > self.maximum_bytes:
            raise TtsStreamError("tts_backpressure", "audio chunk exceeds the consumption window")
        samples = byte_length // 2
        loop = asyncio.get_running_loop()
        waiting_since = loop.time()
        while not self.closed:
            if 2 * (self.sent_samples - self.consumed_samples + samples) <= self.maximum_bytes:
                self.sent_samples += samples
                return True
            self._changed.clear()
            remaining = self._inactivity_seconds - (
                loop.time() - max(waiting_since, self._last_progress_at)
            )
            if remaining <= 0:
                raise TtsStreamError(
                    "tts_backpressure", "audio consumption made no progress"
                )
            try:
                await asyncio.wait_for(self._changed.wait(), timeout=remaining)
            except TimeoutError:
                # Recheck credits and progress after the deadline callback:
                # an ACK can race with that callback on the same event loop.
                continue
        return False

    def acknowledge(self, sample_offset: int) -> None:
        if not self.consumed_samples <= sample_offset <= self.sent_samples:
            raise ValueError("audio consumption watermark is backward or ahead of sent PCM")
        if sample_offset > self.consumed_samples:
            self.consumed_samples = sample_offset
            self._last_progress_at = asyncio.get_running_loop().time()
            self._changed.set()

    def close(self) -> None:
        """Wake the blocked sender; closing never grants additional credits."""

        self.closed = True
        self._changed.set()
