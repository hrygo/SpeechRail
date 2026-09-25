"""Parent-process client for the incremental Qwen3-TTS worker stream.

One session owns exactly one receive dispatcher for the active utterance. Text
and control frames are written through the transport's write lock, while every
acknowledgement, audio chunk and terminal frame is routed by that dispatcher, so
a parked reader can never steal a batch response and the model thread never
writes PCM itself.

Cancellation is cooperative first: the session asks the worker to stop, then
bounds how long it waits before the transport aborts the precise worker child.
The parent process never signals an unrelated process.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import time
from collections.abc import AsyncIterator, Mapping
from typing import Final, Protocol

from speechrail.backends.qwen3_tts_stream_host import (
    FRAME_STREAM_AUDIO,
    FRAME_STREAM_CANCEL,
    FRAME_STREAM_DONE,
    FRAME_STREAM_ERROR,
    FRAME_STREAM_FINISH,
    FRAME_STREAM_START,
    FRAME_STREAM_STARTED,
    FRAME_STREAM_TEXT,
    FRAME_STREAM_TEXT_ACCEPTED,
)
from speechrail.domain.tts_stream import (
    DEFAULT_TTS_STREAM_LIMITS,
    TTS_STREAM_ERROR_CODES,
    TtsStreamError,
    TtsStreamEvent,
    TtsStreamEventKind,
    TtsStreamLimits,
    TtsStreamOptions,
    TtsStreamStateMachine,
    TtsStreamTerminal,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, ProtocolError

_EVENT_QUEUE_SIZE: Final[int] = 32
_TERMINAL_EVENTS: Final[frozenset[TtsStreamEventKind]] = frozenset(
    {
        TtsStreamEventKind.COMPLETED,
        TtsStreamEventKind.CANCELLED,
        TtsStreamEventKind.FAILED,
    }
)
_FALLBACK_ERROR_CODE: Final[str] = "tts_backend_failed"

# Conditioning fields travel with the utterance but may never redefine the
# identity or envelope the parent already validated.
_RESERVED_START_FIELDS: Final[frozenset[str]] = frozenset(
    {
        "version",
        "type",
        "request_id",
        "response_id",
        "voice",
        "stream_protocol",
    }
)


class StreamTransport(Protocol):
    """The slice of ``AsyncFramedWorkerProcess`` the stream client depends on."""

    @property
    def alive(self) -> bool: ...

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None: ...

    async def receive(self, *, wait_for_frame: bool = False) -> dict[str, object]: ...

    async def abort(self) -> None: ...


def _registered_code(raw: object) -> str:
    if isinstance(raw, str) and raw in TTS_STREAM_ERROR_CODES:
        return raw
    return _FALLBACK_ERROR_CODE


def _decode_audio(frame: Mapping[str, object]) -> bytes:
    raw = frame.get("_binary")
    if isinstance(raw, bytes) and raw:
        return raw
    encoded = frame.get("pcm_b64")
    if isinstance(encoded, str):
        try:
            return base64.b64decode(encoded, validate=True)
        except (ValueError, TypeError) as exc:
            raise ProtocolError("invalid streamed audio frame") from exc
    return b""


class Qwen3TtsIncrementalSession:
    """One open incremental utterance owned by the parent process."""

    def __init__(
        self,
        *,
        transport: StreamTransport,
        options: TtsStreamOptions,
        limits: TtsStreamLimits = DEFAULT_TTS_STREAM_LIMITS,
        io_timeout_seconds: float = 120.0,
        cancel_grace_seconds: float = 5.0,
        start_fields: Mapping[str, object] | None = None,
    ) -> None:
        self._transport = transport
        self._options = options
        self._start_fields = (
            {
                key: value
                for key, value in start_fields.items()
                if key not in _RESERVED_START_FIELDS
            }
            if start_fields
            else {}
        )
        self._limits = limits
        self._io_timeout = io_timeout_seconds
        self._cancel_grace = cancel_grace_seconds
        self._state = TtsStreamStateMachine(limits=limits)
        self._events: asyncio.Queue[TtsStreamEvent | None] = asyncio.Queue(
            maxsize=_EVENT_QUEUE_SIZE
        )
        self._ack_waiters: dict[int, asyncio.Future[None]] = {}
        self._started: asyncio.Future[None] | None = None
        self._dispatcher: asyncio.Task[None] | None = None
        self._fatal: BaseException | None = None
        self._notices: list[str] = []
        self._closed = False
        self._cancelled = False
        self._terminal_published = False
        self._abort_used = False
        self._expected_chunk_index = 0
        self._expected_sample_offset = 0
        self.last_active: float = time.monotonic()

    @property
    def options(self) -> TtsStreamOptions:
        return self._options

    @property
    def limits(self) -> TtsStreamLimits:
        return self._limits

    @property
    def terminal(self) -> TtsStreamTerminal | None:
        return self._state.terminal

    @property
    def cancelled(self) -> bool:
        return self._cancelled

    @property
    def notices(self) -> tuple[str, ...]:
        """Recoverable protocol notices observed while the utterance was open."""

        return tuple(self._notices)

    @property
    def used_abort_fallback(self) -> bool:
        return self._abort_used

    async def open(self) -> Qwen3TtsIncrementalSession:
        """Send ``start`` and wait for the worker's ``started`` acknowledgement."""

        frame: dict[str, object] = {
            "version": PROTOCOL_VERSION,
            "type": FRAME_STREAM_START,
            "request_id": self._options.request_id,
            "response_id": self._options.response_id,
            "voice": self._options.voice,
            "speed": self._options.speed,
            "language": self._options.language,
            "stream_protocol": 1,
        }
        frame.update(self._start_fields)
        if self._options.expected_voice_revision is not None:
            frame["expected_voice_revision"] = self._options.expected_voice_revision
        if self._options.expected_model_revision is not None:
            frame["expected_model_revision"] = self._options.expected_model_revision
        loop = asyncio.get_running_loop()
        self._started = loop.create_future()
        self._dispatcher = asyncio.create_task(
            self._dispatch(), name="tts-stream-dispatcher"
        )
        try:
            await self._transport.send(frame)
            async with asyncio.timeout(self._io_timeout):
                await self._started
        except TimeoutError as exc:
            await self._abort()
            raise TtsStreamError(
                "tts_input_timeout", "the worker never acknowledged the utterance"
            ) from exc
        except BaseException:
            await self._abort()
            raise
        return self

    async def append_text(self, sequence: int, text: str) -> None:
        """Validate locally, send one append, and wait for its acknowledgement."""

        if self._closed or self._state.terminal is not None:
            raise TtsStreamError("tts_input_closed", "the utterance is already finished")
        self._state.accept_append(sequence, text)
        waiter: asyncio.Future[None] = asyncio.get_running_loop().create_future()
        self._ack_waiters[sequence] = waiter
        try:
            await self._transport.send(
                {
                    "version": PROTOCOL_VERSION,
                    "type": FRAME_STREAM_TEXT,
                    "request_id": self._options.request_id,
                    "sequence": sequence,
                    "text": text,
                }
            )
            async with asyncio.timeout(self._io_timeout):
                await waiter
        except TtsStreamError:
            self._ack_waiters.pop(sequence, None)
            raise
        except TimeoutError as exc:
            self._ack_waiters.pop(sequence, None)
            await self.cancel()
            raise TtsStreamError(
                "tts_input_timeout", "the worker never acknowledged appended text"
            ) from exc
        finally:
            self.last_active = time.monotonic()

    async def finish_text(self, last_sequence: int) -> None:
        """Close the text side; generation continues until the terminal event."""

        self._state.accept_finish(last_sequence)
        await self._transport.send(
            {
                "version": PROTOCOL_VERSION,
                "type": FRAME_STREAM_FINISH,
                "request_id": self._options.request_id,
                "last_sequence": last_sequence,
            }
        )

    async def events(self) -> AsyncIterator[TtsStreamEvent]:
        """Yield sanitized events until the single terminal outcome arrives."""

        while True:
            event = await self._events.get()
            if event is None:
                return
            yield event
            if event.kind in {
                TtsStreamEventKind.COMPLETED,
                TtsStreamEventKind.CANCELLED,
                TtsStreamEventKind.FAILED,
            }:
                return

    async def cancel(self) -> None:
        """Ask the worker to stop, then bound how long the parent waits for it."""

        if self._cancelled:
            return
        self._cancelled = True
        if self._state.terminal is None:
            self._state.cancel()
        with contextlib.suppress(Exception):
            await self._transport.send(
                {
                    "version": PROTOCOL_VERSION,
                    "type": FRAME_STREAM_CANCEL,
                    "request_id": self._options.request_id,
                }
            )
        await self._await_dispatcher(self._cancel_grace)
        if self._state.terminal is TtsStreamTerminal.CANCELLED:
            self._publish(
                TtsStreamEvent(
                    kind=TtsStreamEventKind.CANCELLED,
                    response_id=self._options.response_id,
                    terminal=TtsStreamTerminal.CANCELLED,
                )
            )

    async def close(self) -> None:
        """Release the utterance, aborting the child only if it will not stop."""

        if self._closed:
            return
        self._closed = True
        if self._state.terminal is None and not self._cancelled:
            # cancel() already bounds how long it waits for the worker's terminal.
            await self.cancel()
        dispatcher = self._dispatcher
        self._dispatcher = None
        if dispatcher is not None and not dispatcher.done():
            dispatcher.cancel()
            await asyncio.gather(dispatcher, return_exceptions=True)
        self._fail_pending_waiters(
            TtsStreamError("tts_input_closed", "the incremental session was closed")
        )
        self._events.put_nowait(None)
        if self._fatal is not None:
            await self._abort()

    async def _dispatch(self) -> None:
        try:
            while True:
                frame = await self._transport.receive(wait_for_frame=True)
                if not self._handle_frame(frame):
                    return
        except asyncio.CancelledError:
            raise
        except BaseException as exc:
            self._fatal = exc
            if self._started is not None and not self._started.done():
                self._started.set_exception(exc)
            self._fail_pending_waiters(exc)
            self._publish(
                TtsStreamEvent(
                    kind=TtsStreamEventKind.FAILED,
                    response_id=self._options.response_id,
                    terminal=TtsStreamTerminal.FAILED,
                    error_code=_registered_code(getattr(exc, "code", None)),
                )
            )

    def _handle_frame(self, frame: Mapping[str, object]) -> bool:
        frame_type = frame.get("type")
        if frame.get("request_id") != self._options.request_id:
            raise ProtocolError("incremental frame carried a foreign request_id")
        if frame_type == FRAME_STREAM_STARTED:
            if self._started is not None and not self._started.done():
                self._started.set_result(None)
            self._publish(
                TtsStreamEvent(
                    kind=TtsStreamEventKind.STARTED,
                    response_id=self._options.response_id,
                )
            )
            return True
        if frame_type == FRAME_STREAM_TEXT_ACCEPTED:
            sequence = frame.get("sequence")
            accepted = frame.get("accepted_codepoints")
            if isinstance(sequence, bool) or not isinstance(sequence, int):
                raise ProtocolError("invalid text_accepted sequence")
            if isinstance(accepted, bool) or not isinstance(accepted, int) or accepted < 0:
                raise ProtocolError("invalid text_accepted codepoint count")
            waiter = self._ack_waiters.pop(sequence, None)
            if waiter is not None and not waiter.done():
                waiter.set_result(None)
            else:
                self._note(f"unmatched text acknowledgement for sequence {sequence}")
            self._publish(
                TtsStreamEvent(
                    kind=TtsStreamEventKind.TEXT_ACCEPTED,
                    response_id=self._options.response_id,
                    sequence=sequence,
                    accepted_codepoints=accepted,
                )
            )
            return True
        if frame_type == FRAME_STREAM_AUDIO:
            self._publish(self._audio_event(frame))
            return True
        if frame_type == FRAME_STREAM_DONE:
            terminal = frame.get("terminal")
            if terminal == TtsStreamTerminal.COMPLETED.value:
                outcome = TtsStreamTerminal.COMPLETED
                kind = TtsStreamEventKind.COMPLETED
            elif terminal == TtsStreamTerminal.CANCELLED.value:
                outcome = TtsStreamTerminal.CANCELLED
                kind = TtsStreamEventKind.CANCELLED
            else:
                raise ProtocolError("invalid incremental terminal frame")
            if self._state.terminal is None:
                if outcome is TtsStreamTerminal.COMPLETED:
                    self._state.complete()
                else:
                    self._state.cancel()
            self._publish(
                TtsStreamEvent(
                    kind=kind, response_id=self._options.response_id, terminal=outcome
                )
            )
            return False
        if frame_type == FRAME_STREAM_ERROR:
            code = _registered_code(frame.get("code"))
            terminal = frame.get("terminal") is True
            sequence = frame.get("sequence")
            if not terminal:
                self._note(code)
                if isinstance(sequence, int) and not isinstance(sequence, bool):
                    waiter = self._ack_waiters.pop(sequence, None)
                    if waiter is not None and not waiter.done():
                        waiter.set_exception(TtsStreamError(code, code))
                return True
            if self._state.terminal is None:
                self._state.fail(code)
            self._publish(
                TtsStreamEvent(
                    kind=TtsStreamEventKind.FAILED,
                    response_id=self._options.response_id,
                    terminal=TtsStreamTerminal.FAILED,
                    error_code=code,
                )
            )
            return False
        raise ProtocolError("unsupported incremental worker frame")

    def _audio_event(self, frame: Mapping[str, object]) -> TtsStreamEvent:
        chunk_index = frame.get("chunk_index")
        sample_offset = frame.get("sample_offset")
        if isinstance(chunk_index, bool) or not isinstance(chunk_index, int):
            raise ProtocolError("invalid streamed audio chunk_index")
        if chunk_index != self._expected_chunk_index:
            raise ProtocolError("streamed audio chunk_index is not contiguous")
        if isinstance(sample_offset, bool) or not isinstance(sample_offset, int):
            raise ProtocolError("invalid streamed audio sample_offset")
        if sample_offset != self._expected_sample_offset:
            raise ProtocolError("streamed audio sample_offset is not contiguous")
        pcm = _decode_audio(frame)
        if not pcm or len(pcm) % 2:
            raise ProtocolError("invalid streamed audio payload")
        self._expected_chunk_index += 1
        self._expected_sample_offset += len(pcm) // 2
        self.last_active = time.monotonic()
        return TtsStreamEvent(
            kind=TtsStreamEventKind.AUDIO,
            response_id=self._options.response_id,
            pcm16=pcm,
            chunk_index=chunk_index,
            sample_offset=sample_offset,
        )

    def _publish(self, event: TtsStreamEvent) -> None:
        if self._terminal_published:
            return
        terminal = event.kind in _TERMINAL_EVENTS
        if terminal:
            # A terminal outcome must always reach the caller, so a stalled
            # consumer loses stale audio instead of losing the ending.
            while True:
                try:
                    self._events.put_nowait(event)
                    break
                except asyncio.QueueFull:
                    with contextlib.suppress(asyncio.QueueEmpty):
                        self._events.get_nowait()
            self._terminal_published = True
            return
        try:
            self._events.put_nowait(event)
        except asyncio.QueueFull:
            self._note("dropped an incremental event because the caller is not reading")
            if self._state.terminal is None:
                self._state.fail("tts_backpressure")
                self._fail_pending_waiters(
                    TtsStreamError("tts_backpressure", "the caller is not reading events")
                )

    def _note(self, message: str) -> None:
        if len(self._notices) < 16:
            self._notices.append(message)

    def _fail_pending_waiters(self, error: BaseException) -> None:
        for waiter in self._ack_waiters.values():
            if not waiter.done():
                waiter.set_exception(error)
        self._ack_waiters.clear()

    async def _await_dispatcher(self, seconds: float) -> None:
        dispatcher = self._dispatcher
        if dispatcher is None or dispatcher.done():
            return
        with contextlib.suppress(TimeoutError):
            async with asyncio.timeout(seconds):
                await asyncio.shield(dispatcher)

    async def _abort(self) -> None:
        if self._abort_used:
            return
        self._abort_used = True
        with contextlib.suppress(Exception):
            await self._transport.abort()


class Qwen3TtsIncrementalSynthesizer:
    """Open incremental utterances on one already-leased TTS worker transport."""

    def __init__(
        self,
        transport: StreamTransport,
        *,
        limits: TtsStreamLimits = DEFAULT_TTS_STREAM_LIMITS,
        io_timeout_seconds: float = 120.0,
        cancel_grace_seconds: float = 5.0,
        stream_protocol: int | None = None,
    ) -> None:
        self._transport = transport
        self._limits = limits
        self._io_timeout = io_timeout_seconds
        self._cancel_grace = cancel_grace_seconds
        self._stream_protocol = stream_protocol

    @property
    def supported(self) -> bool:
        return self._stream_protocol == 1

    async def open_stream(
        self,
        options: TtsStreamOptions,
        *,
        start_fields: Mapping[str, object] | None = None,
    ) -> Qwen3TtsIncrementalSession:
        """Fail closed when the ready handshake never negotiated streaming.

        ``start_fields`` carries the conditioning frozen by the owning worker
        (voice-profile snapshot or clone reference); it can never replace the
        utterance identity validated above.
        """

        if not self.supported:
            raise TtsStreamError(
                "tts_streaming_unsupported",
                "the TTS worker did not negotiate the incremental stream protocol",
            )
        session = Qwen3TtsIncrementalSession(
            transport=self._transport,
            options=options,
            limits=self._limits,
            io_timeout_seconds=self._io_timeout,
            cancel_grace_seconds=self._cancel_grace,
            start_fields=start_fields,
        )
        return await session.open()


__all__ = [
    "Qwen3TtsIncrementalSession",
    "Qwen3TtsIncrementalSynthesizer",
    "StreamTransport",
]
