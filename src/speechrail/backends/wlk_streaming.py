"""Normalize a supervised WLK sidecar stream without exposing its wire shape."""

from __future__ import annotations

from collections.abc import AsyncIterator
from dataclasses import dataclass
from typing import Protocol

from speechrail.compatibility.wlk import normalize_snapshot
from speechrail.domain.contracts import TranscriptSegment


class WlkSnapshotTransport(Protocol):
    def snapshots(self) -> AsyncIterator[dict[str, object]]: ...


@dataclass(frozen=True, slots=True)
class AsrStreamingEvent:
    kind: str
    text: str
    segments: tuple[TranscriptSegment, ...]


class WlkStreamingBackend:
    """Convert legacy snapshot frames to vendor-neutral partial/final events."""

    def __init__(self, transport: WlkSnapshotTransport, *, source_epoch: int) -> None:
        self._transport = transport
        self._source_epoch = source_epoch

    async def events(self) -> AsyncIterator[AsrStreamingEvent]:
        async for payload in self._transport.snapshots():
            window = normalize_snapshot(payload, source_epoch=self._source_epoch)
            if window.partial is not None:
                yield AsrStreamingEvent("partial", window.partial, ())
            elif window.segments:
                yield AsrStreamingEvent(
                    "completed",
                    " ".join(segment.text for segment in window.segments),
                    window.segments,
                )
