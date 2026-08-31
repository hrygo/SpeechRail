"""Normalize a supervised WLK sidecar stream without exposing its wire shape."""

from __future__ import annotations

import json
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass
from typing import Protocol, cast
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import websockets

from speechrail.compatibility.wlk import normalize_snapshot
from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.ports import (
    RealtimeAsrFactory,
    RealtimeAsrSession,
    StreamingAsrEvent,
)


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


class WlkConnection(Protocol):
    uri: str

    async def send(self, message: bytes) -> None: ...

    async def recv(self) -> str | bytes: ...

    async def close(self) -> None: ...


WlkConnectionFactory = Callable[[str], Awaitable[WlkConnection]]


def _connect(uri: str) -> Awaitable[WlkConnection]:
    return cast(Awaitable[WlkConnection], websockets.connect(uri))


class WlkRealtimeSession(RealtimeAsrSession):
    """One WLK transport session normalized before it reaches public v2 events."""

    def __init__(
        self,
        *,
        url: str,
        language: str,
        connection_factory: WlkConnectionFactory | None = None,
    ) -> None:
        self._uri = _wlk_uri(url, language)
        self._connection_factory = connection_factory or _connect
        self._connection: WlkConnection | None = None
        self._last_partial = ""
        self._seen_segments: set[str] = set()

    async def connect(self) -> None:
        if self._connection is not None:
            raise RuntimeError("WLK_ALREADY_CONNECTED")
        self._connection = await self._connection_factory(self._uri)

    async def append_audio(self, audio: bytes) -> None:
        if not audio or len(audio) % 2:
            raise ValueError("WLK requires non-empty PCM16 audio")
        if self._connection is None:
            raise RuntimeError("WLK_NOT_CONNECTED")
        await self._connection.send(audio)

    async def flush(self) -> None:
        """WLK receives PCM continuously; only its empty frame commits the stream."""

    async def commit(self) -> None:
        if self._connection is None:
            raise RuntimeError("WLK_NOT_CONNECTED")
        await self._connection.send(b"")

    async def events(self) -> AsyncIterator[StreamingAsrEvent]:
        if self._connection is None:
            raise RuntimeError("WLK_NOT_CONNECTED")
        while True:
            raw = await self._connection.recv()
            if isinstance(raw, bytes):
                continue
            payload = _payload(raw)
            event_type = payload.get("type")
            if event_type == "ready_to_stop":
                return
            if event_type == "error":
                yield StreamingAsrEvent(
                    kind="error",
                    error_code="wlk_error",
                    text=str(payload.get("error") or "WLK backend error")[:1000],
                )
                return
            window = normalize_snapshot(payload, source_epoch=0)
            if window.partial is not None and window.partial != self._last_partial:
                self._last_partial = window.partial
                yield StreamingAsrEvent(kind="partial", text=window.partial)
            for segment in window.segments:
                if segment.id in self._seen_segments:
                    continue
                self._seen_segments.add(segment.id)
                yield StreamingAsrEvent(
                    kind="completed",
                    text=segment.text,
                    language=segment.language,
                    segments=(segment,),
                )

    async def close(self) -> None:
        if self._connection is not None:
            try:
                await self._connection.close()
            finally:
                self._connection = None


class WlkRealtimeFactory(RealtimeAsrFactory):
    """Creates WLK sessions only for an explicitly configured external sidecar."""

    def __init__(
        self, *, url: str, connection_factory: WlkConnectionFactory | None = None
    ) -> None:
        self._url = url
        self._connection_factory = connection_factory

    def create(self, *, language: str | None, prompt: str) -> WlkRealtimeSession:
        del prompt
        return WlkRealtimeSession(
            url=self._url,
            language=language or "auto",
            connection_factory=self._connection_factory,
        )


def _wlk_uri(url: str, language: str) -> str:
    parsed = urlsplit(url.strip().rstrip("/"))
    if (
        parsed.scheme not in {"ws", "wss"}
        or parsed.hostname is None
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise ValueError("WLK URL must be a credential-free ws(s) URL")
    path = parsed.path if parsed.path.endswith("/asr") else f"{parsed.path}/asr"
    query = dict(parse_qsl(parsed.query, keep_blank_values=True))
    query.update({"language": language, "mode": "full"})
    return urlunsplit((parsed.scheme, parsed.netloc, path, urlencode(query), ""))


def _payload(raw: str) -> dict[str, object]:
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if not isinstance(decoded, dict):
        return {}
    return {str(key): value for key, value in decoded.items()}
