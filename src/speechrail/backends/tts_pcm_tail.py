"""Bounded PCM16 tail retention for a continuous synthesized waveform."""

from __future__ import annotations

import numpy as np


class Pcm16Tail:
    """Retain only the fade window; release the original samples at EOS."""

    def __init__(self, *, sample_rate: int, fade_ms: int = 5) -> None:
        self._maximum_bytes = max(1, sample_rate * fade_ms // 1000) * 2
        self._pending = b""

    def push(self, pcm16: bytes) -> bytes:
        joined = self._pending + pcm16
        released = max(0, len(joined) - self._maximum_bytes)
        self._pending = joined[released:]
        return joined[:released]

    def finish(self) -> bytes:
        samples = np.frombuffer(self._pending, dtype="<i2").astype(np.float32)
        self._pending = b""
        if samples.size == 1:
            samples[0] = 0
        elif samples.size:
            samples *= np.linspace(1.0, 0.0, samples.size, dtype=np.float32)
        return samples.astype("<i2").tobytes()

    def discard(self) -> None:
        self._pending = b""
