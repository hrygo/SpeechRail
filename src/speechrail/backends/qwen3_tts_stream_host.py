"""Worker-side control host for one incremental Qwen3-TTS utterance.

The host owns the private IPC vocabulary of the incremental path plus the single
authoritative state machine that turns append-only text into ordered PCM frames.
It imports no vendor code and no voice registry: the model session is injected,
so the same host is exercised by deterministic fakes and by the real adapter,
and the model thread stays the only owner of MLX state.

Wire shapes (``TTS_STREAM_PROTOCOL_VERSION`` 1)::

    parent -> worker   tts_stream_start / text / finish / cancel
    worker -> parent   tts_stream_started / text_accepted / audio / done / error

Every frame carries ``request_id``.  The worker echoes the utterance identity it
was given instead of minting a second one, so the parent never has to correlate
two different IDs.
"""

from __future__ import annotations

import contextlib
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Final, Literal, Protocol

from speechrail.domain.tts_stream import (
    DEFAULT_TTS_STREAM_LIMITS,
    TtsStreamError,
    TtsStreamEventKind,
    TtsStreamInputState,
    TtsStreamLimits,
    TtsStreamOptions,
    TtsStreamStateMachine,
    TtsStreamTerminal,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, ProtocolError

TTS_STREAM_PROTOCOL_VERSION: Final[int] = 1

FRAME_STREAM_START: Final[str] = "tts_stream_start"
FRAME_STREAM_TEXT: Final[str] = "tts_stream_text"
FRAME_STREAM_FINISH: Final[str] = "tts_stream_finish"
FRAME_STREAM_CANCEL: Final[str] = "tts_stream_cancel"
FRAME_STREAM_STARTED: Final[str] = "tts_stream_started"
FRAME_STREAM_TEXT_ACCEPTED: Final[str] = "tts_stream_text_accepted"
FRAME_STREAM_AUDIO: Final[str] = "tts_stream_audio"
FRAME_STREAM_DONE: Final[str] = "tts_stream_done"
FRAME_STREAM_ERROR: Final[str] = "tts_stream_error"

STREAM_FRAME_TYPES: Final[frozenset[str]] = frozenset(
    {FRAME_STREAM_START, FRAME_STREAM_TEXT, FRAME_STREAM_FINISH, FRAME_STREAM_CANCEL}
)

# A sequence or closed-input mistake is a caller bug in one packet: the text is
# not consumed and the utterance keeps producing, so the caller can retry with
# the right sequence.  Every other registered stream failure means the model can
# no longer produce a correct continuation, so it ends the utterance.
RECOVERABLE_STREAM_ERROR_CODES: Final[frozenset[str]] = frozenset(
    {"tts_sequence_invalid", "tts_input_closed"}
)


@dataclass(frozen=True, slots=True)
class StreamFrame:
    """One outbound private frame plus the callback that retires its budget."""

    payload: dict[str, object]
    binary: bytes | None = None
    on_sent: Callable[[], None] | None = None


@dataclass(frozen=True, slots=True)
class StreamCommand:
    """One validated parent -> worker control frame."""

    kind: Literal["start", "text", "finish", "cancel"]
    request_id: str
    sequence: int | None = None
    text: str | None = None
    last_sequence: int | None = None


@dataclass(frozen=True, slots=True)
class ModelStepEvent:
    """One bounded model advance reported by an incremental model session."""

    kind: Literal["pcm", "waiting_for_text", "finished", "error"]
    pcm16: bytes = b""
    error_code: str | None = None


class IncrementalModelSession(Protocol):
    """Vendor-facing seam: the model state one incremental utterance owns."""

    @property
    def generation_identity(self) -> str: ...

    @property
    def sample_rate(self) -> int: ...

    @property
    def prefill_target_tokens(self) -> int: ...

    def append_text(self, text: str) -> Sequence[int]: ...

    def finish_input(self) -> None: ...

    def step(self, *, max_steps: int) -> ModelStepEvent: ...

    def cancel(self) -> None: ...

    def close(self) -> None: ...


@dataclass(frozen=True, slots=True)
class HostStepResult:
    """Outcome of one bounded model advance, including whether to wait for text."""

    frames: tuple[StreamFrame, ...] = ()
    waiting_for_text: bool = False
    terminal: bool = False


def _require_int(value: object, *, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ProtocolError(f"{name} must be an integer")
    return value


def parse_stream_command(frame: Mapping[str, object]) -> StreamCommand:
    """Validate one incremental control frame without touching model state.

    ``tts_stream_start`` needs the full voice/binding decode that already lives in
    the worker, so this parser only proves the envelope; the three mid-stream
    commands are fully validated here.  Malformed frames raise ``ProtocolError``
    (a private-IPC fault), while semantic mistakes such as a sequence gap stay in
    the domain state table and surface as registered stream error codes.
    """

    if frame.get("version") != PROTOCOL_VERSION:
        raise ProtocolError("invalid worker frame version")
    frame_type = frame.get("type")
    if frame_type not in STREAM_FRAME_TYPES:
        raise ProtocolError("unsupported incremental stream frame")
    request_id = frame.get("request_id")
    if not isinstance(request_id, str) or not request_id:
        raise ProtocolError("incremental stream frames require a request_id")

    if frame_type == FRAME_STREAM_START:
        return StreamCommand(kind="start", request_id=request_id)
    if frame_type == FRAME_STREAM_CANCEL:
        return StreamCommand(kind="cancel", request_id=request_id)
    if frame_type == FRAME_STREAM_TEXT:
        sequence = _require_int(frame.get("sequence"), name="sequence")
        text = frame.get("text")
        if not isinstance(text, str):
            raise ProtocolError("incremental stream text must be a string")
        return StreamCommand(
            kind="text", request_id=request_id, sequence=sequence, text=text
        )
    last_sequence = _require_int(frame.get("last_sequence"), name="last_sequence")
    return StreamCommand(
        kind="finish", request_id=request_id, last_sequence=last_sequence
    )


class TtsStreamHost:
    """Own one incremental utterance inside the model worker process.

    The object is created per utterance and consumed by the worker's model
    thread only.  It never reads or writes a stream itself; it returns frames for
    the writer to deliver, which keeps slow-consumer handling outside the model.
    """

    def __init__(
        self,
        session: IncrementalModelSession,
        options: TtsStreamOptions,
        *,
        limits: TtsStreamLimits = DEFAULT_TTS_STREAM_LIMITS,
        step_size: int = 16,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if isinstance(step_size, bool) or not isinstance(step_size, int) or step_size < 1:
            raise ValueError("step_size must be a positive integer")
        sample_rate = session.sample_rate
        if isinstance(sample_rate, bool) or not isinstance(sample_rate, int) or sample_rate <= 0:
            raise TtsStreamError("tts_backend_failed", "model session reported a sample rate")
        self._session = session
        self._options = options
        self._limits = limits
        self._step_size = step_size
        self._clock = clock
        self._state = TtsStreamStateMachine(limits=limits)
        self._state.mark_running()
        started_at = float(clock())
        self._started_at = started_at
        self._last_input_at = started_at
        self._failure_code: str | None = None

    @property
    def options(self) -> TtsStreamOptions:
        return self._options

    @property
    def limits(self) -> TtsStreamLimits:
        return self._limits

    @property
    def sample_rate(self) -> int:
        return self._session.sample_rate

    @property
    def terminal(self) -> TtsStreamTerminal | None:
        return self._state.terminal

    @property
    def input_state(self) -> TtsStreamInputState:
        return self._state.input_state

    @property
    def accepted_sequence(self) -> int:
        return self._state.accepted_sequence

    @property
    def failure_code(self) -> str | None:
        return self._failure_code

    def started_frames(self) -> tuple[StreamFrame, ...]:
        """Announce the accepted utterance; the caller must send this before PCM."""

        return (
            StreamFrame(
                {
                    "version": PROTOCOL_VERSION,
                    "type": FRAME_STREAM_STARTED,
                    "request_id": self._options.request_id,
                    "response_id": self._options.response_id,
                    "sample_rate": self._session.sample_rate,
                    "stream_protocol": TTS_STREAM_PROTOCOL_VERSION,
                    "generation_identity": self._session.generation_identity,
                    "prefill_target_tokens": self._session.prefill_target_tokens,
                    "limits": {
                        "max_append_codepoints": self._limits.max_append_codepoints,
                        "max_total_codepoints": self._limits.max_total_codepoints,
                        "max_pending_codepoints": self._limits.max_pending_codepoints,
                        "max_pending_audio_bytes": self._limits.max_pending_audio_bytes,
                        "input_wait_seconds": self._limits.input_wait_seconds,
                        "utterance_wall_clock_seconds": (
                            self._limits.utterance_wall_clock_seconds
                        ),
                        "slow_consumer_seconds": self._limits.slow_consumer_seconds,
                    },
                }
            ),
        )

    def accept_text(self, sequence: int, text: str) -> tuple[StreamFrame, ...]:
        """Validate one append, hand it to the model buffer, and acknowledge it."""

        try:
            codepoints = self._state.accept_append(sequence, text)
            tokens = self._session.append_text(text)
        except TtsStreamError as exc:
            return self._recoverable_or_terminal(exc, sequence=sequence)
        except Exception:
            return self._terminate(
                "tts_backend_failed",
                detail="the model session rejected appended text",
            )
        self._last_input_at = float(self._clock())
        return (
            StreamFrame(
                {
                    "version": PROTOCOL_VERSION,
                    "type": FRAME_STREAM_TEXT_ACCEPTED,
                    "request_id": self._options.request_id,
                    "sequence": sequence,
                    "accepted_codepoints": codepoints,
                    "accepted_tokens": len(tokens),
                }
            ),
        )

    def finish_input(self, last_sequence: int) -> tuple[StreamFrame, ...]:
        """Close the text side, then keep generating the remaining audio."""

        try:
            self._state.accept_finish(last_sequence)
            self._session.finish_input()
        except TtsStreamError as exc:
            return self._recoverable_or_terminal(exc)
        except Exception:
            return self._terminate(
                "tts_backend_failed",
                detail="the model session rejected the end of input",
            )
        return ()

    def cancel(self) -> tuple[StreamFrame, ...]:
        """Record the single cancellation terminal and release model state."""

        if self._state.terminal is not None:
            return ()
        self._state.cancel()
        self._release_session(cancel=True)
        return self._terminal_frames()

    def step(self, *, max_steps: int | None = None) -> HostStepResult:
        """Advance the model by a bounded amount and project the new frames."""

        if self._state.terminal is not None:
            return HostStepResult(terminal=True)
        budget = self._step_size if max_steps is None else max_steps
        try:
            event = self._session.step(max_steps=budget)
        except Exception:
            frames = self._terminate(
                "tts_backend_failed", detail="the model session raised mid-generation"
            )
            return HostStepResult(frames=frames, terminal=True)

        if event.kind == "error":
            frames = self._terminate(event.error_code or "tts_backend_failed")
            return HostStepResult(frames=frames, terminal=True)
        if event.kind == "finished":
            if self._state.input_state is not TtsStreamInputState.CLOSED:
                # The vendor driver only reports codec EOS after the text EOS
                # embedding entered model state, so finishing early means the
                # model and the caller disagree about the utterance boundary.
                frames = self._terminate(
                    "tts_backend_failed",
                    detail="the model finished before the input was closed",
                )
                return HostStepResult(frames=frames, terminal=True)
            frames = self._complete()
            return HostStepResult(frames=frames, terminal=True)
        if event.kind == "waiting_for_text":
            return self._handle_starvation()
        return self._emit_audio(event.pcm16)

    def timeout_remaining(self) -> float:
        """Seconds left before a starved input or a too-long utterance ends."""

        now = float(self._clock())
        wall = self._limits.utterance_wall_clock_seconds - (now - self._started_at)
        wait = self._limits.input_wait_seconds - (now - self._last_input_at)
        return max(0.0, min(wall, wait))

    def expire(self) -> tuple[StreamFrame, ...]:
        """Apply the deadline that ``timeout_remaining`` reported as exhausted."""

        if self._state.terminal is not None:
            return ()
        now = float(self._clock())
        if now - self._started_at >= self._limits.utterance_wall_clock_seconds:
            return self._terminate(
                "tts_stream_limit_exceeded", detail="the utterance exceeded its deadline"
            )
        return self._terminate(
            "tts_input_timeout", detail="no text arrived before the input deadline"
        )

    def close(self) -> None:
        """Idempotently release model state; never emits a second terminal."""

        self._release_session(cancel=self._state.terminal is None)

    def _handle_starvation(self) -> HostStepResult:
        if self._state.input_state is TtsStreamInputState.CLOSED:
            # The vendor feeder answers a closed input with EOS/pad tokens, never
            # with "waiting", so a waiting event here means the model stalled
            # mid-drain.  Fail closed instead of silently truncating the tail.
            frames = self._terminate(
                "tts_backend_failed",
                detail="the model stalled after the input was closed",
            )
            return HostStepResult(frames=frames, terminal=True)
        if self._state.terminal is not None:
            return HostStepResult(terminal=True)
        if self.timeout_remaining() <= 0.0:
            frames = self.expire()
            return HostStepResult(frames=frames, terminal=True)
        return HostStepResult(waiting_for_text=True)

    def _emit_audio(self, pcm16: bytes) -> HostStepResult:
        if not pcm16 or len(pcm16) % 2:
            frames = self._terminate("tts_backend_failed", detail="invalid PCM chunk")
            return HostStepResult(frames=frames, terminal=True)
        try:
            position = self._state.enqueue_audio(len(pcm16))
        except TtsStreamError as exc:
            frames = self._recoverable_or_terminal(exc)
            return HostStepResult(frames=frames, terminal=self._state.terminal is not None)
        frame = StreamFrame(
            {
                "version": PROTOCOL_VERSION,
                "type": FRAME_STREAM_AUDIO,
                "request_id": self._options.request_id,
                "chunk_index": position.chunk_index,
                "sample_offset": position.sample_offset,
                "sample_rate": self._session.sample_rate,
            },
            binary=pcm16,
            on_sent=self._audio_sent(position.byte_length),
        )
        return HostStepResult(frames=(frame,))

    def _audio_sent(self, byte_length: int) -> Callable[[], None]:
        def retire() -> None:
            if self._state.terminal is None:
                self._state.dequeue_audio(byte_length)

        return retire

    def _complete(self) -> tuple[StreamFrame, ...]:
        if self._state.terminal is not None:
            return ()
        self._state.complete()
        self._release_session(cancel=False)
        return self._terminal_frames()

    def _recoverable_or_terminal(
        self, error: TtsStreamError, *, sequence: int | None = None
    ) -> tuple[StreamFrame, ...]:
        if error.code in RECOVERABLE_STREAM_ERROR_CODES:
            payload: dict[str, object] = {
                "version": PROTOCOL_VERSION,
                "type": FRAME_STREAM_ERROR,
                "request_id": self._options.request_id,
                "code": error.code,
                "terminal": False,
                "message": str(error),
            }
            if sequence is not None:
                payload["sequence"] = sequence
            return (StreamFrame(payload),)
        return self._terminate(error.code, detail=str(error))

    def _terminate(self, code: str, *, detail: str | None = None) -> tuple[StreamFrame, ...]:
        """Record the single failure terminal; unknown codes are normalised."""

        if self._state.terminal is not None:
            return ()
        registered = code
        try:
            self._state.fail(registered)
        except ValueError:
            registered = "tts_backend_failed"
            self._state.fail(registered)
        self._failure_code = registered
        self._release_session(cancel=True)
        frames = list(self._terminal_frames(include_failure=True))
        if detail is not None and frames:
            frames[-1].payload["message"] = detail
        return tuple(frames)

    def _terminal_frames(self, *, include_failure: bool = False) -> tuple[StreamFrame, ...]:
        terminal = self._state.terminal
        if terminal is None:
            return ()
        if terminal is TtsStreamTerminal.FAILED:
            if not include_failure:
                return ()
            return (
                StreamFrame(
                    {
                        "version": PROTOCOL_VERSION,
                        "type": FRAME_STREAM_ERROR,
                        "request_id": self._options.request_id,
                        "code": self._failure_code or "tts_backend_failed",
                        "terminal": True,
                    }
                ),
            )
        return (
            StreamFrame(
                {
                    "version": PROTOCOL_VERSION,
                    "type": FRAME_STREAM_DONE,
                    "request_id": self._options.request_id,
                    "terminal": terminal.value,
                    "event": _TERMINAL_EVENT_KINDS[terminal].value,
                }
            ),
        )

    def _release_session(self, *, cancel: bool) -> None:
        session = self._session
        if cancel:
            with contextlib.suppress(Exception):
                session.cancel()
        with contextlib.suppress(Exception):
            session.close()


_TERMINAL_EVENT_KINDS: Final[dict[TtsStreamTerminal, TtsStreamEventKind]] = {
    TtsStreamTerminal.COMPLETED: TtsStreamEventKind.COMPLETED,
    TtsStreamTerminal.CANCELLED: TtsStreamEventKind.CANCELLED,
    TtsStreamTerminal.FAILED: TtsStreamEventKind.FAILED,
}


__all__ = [
    "FRAME_STREAM_AUDIO",
    "FRAME_STREAM_CANCEL",
    "FRAME_STREAM_DONE",
    "FRAME_STREAM_ERROR",
    "FRAME_STREAM_FINISH",
    "FRAME_STREAM_START",
    "FRAME_STREAM_STARTED",
    "FRAME_STREAM_TEXT",
    "FRAME_STREAM_TEXT_ACCEPTED",
    "RECOVERABLE_STREAM_ERROR_CODES",
    "STREAM_FRAME_TYPES",
    "TTS_STREAM_PROTOCOL_VERSION",
    "HostStepResult",
    "IncrementalModelSession",
    "ModelStepEvent",
    "StreamCommand",
    "StreamFrame",
    "TtsStreamHost",
    "parse_stream_command",
]
