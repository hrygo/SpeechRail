"""Bounded, in-memory PCM retention for auxiliary inference tasks.

Retained audio is a short-lived *pin*: it lives only in RAM, is never written
to disk, and the owning request releases the whole span on commit, failure or
cancel.  Appending past the declared capacity raises instead of silently
dropping the oldest samples, so a caller can surface an explicit overflow
reason rather than pretend it retained audio it did not.

The buffer is deliberately not a lossy ring: for forced alignment the exact
samples matter, so the choice is between failing loudly and segmenting upstream
-- never quietly discarding the head of the stream.
"""

from __future__ import annotations

from speechrail.runtime.limits import PCM_SAMPLE_BYTES


class PcmBufferOverflowError(RuntimeError):
    """Raised when an append would exceed the buffer's declared capacity."""


class BoundedPcmBuffer:
    """Append-only PCM16 store with a hard byte capacity."""

    def __init__(self, capacity_bytes: int) -> None:
        if capacity_bytes < PCM_SAMPLE_BYTES:
            raise ValueError("PCM buffer capacity must hold at least one sample")
        if capacity_bytes % PCM_SAMPLE_BYTES:
            raise ValueError("PCM buffer capacity must be whole PCM16 samples")
        self._capacity_bytes = capacity_bytes
        self._data = bytearray()

    @property
    def capacity_bytes(self) -> int:
        return self._capacity_bytes

    @property
    def remaining_bytes(self) -> int:
        return self._capacity_bytes - len(self._data)

    def __len__(self) -> int:
        return len(self._data)

    def append(self, pcm16: bytes) -> None:
        """Store ``pcm16`` or raise ``PcmBufferOverflowError`` without partial writes."""

        if len(pcm16) % PCM_SAMPLE_BYTES:
            raise ValueError("PCM buffer only accepts whole PCM16 samples")
        if len(self._data) + len(pcm16) > self._capacity_bytes:
            raise PcmBufferOverflowError(
                f"PCM buffer would exceed {self._capacity_bytes} bytes"
            )
        self._data.extend(pcm16)

    def pin(self) -> bytes:
        """Return an immutable snapshot an auxiliary task may hold after clear()."""

        return bytes(self._data)

    def clear(self) -> None:
        """Release the retained span; the buffer stays reusable."""

        self._data.clear()


__all__ = ["BoundedPcmBuffer", "PcmBufferOverflowError"]
