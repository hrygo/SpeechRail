"""Vendor-neutral incremental TTS stream contract.

This module owns the only definition of incremental TTS limits, options, states
and events. It imports no MLX, worker or HTTP code so the stream state table can
be verified deterministically with fakes, and it never mutates
``SpeechRequest.text`` into a stream: the existing complete-text path keeps its
own types.

Two independent state axes exist because receiving text and generating audio
overlap: the input is OPEN or CLOSED while the output is STARTING, RUNNING,
DRAINING or TERMINAL. Exactly one terminal outcome may be recorded per
utterance.
"""

from __future__ import annotations

import math
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Final, Protocol

TTS_STREAM_ERROR_CODES: Final[frozenset[str]] = frozenset(
    {
        "tts_streaming_unsupported",
        "tts_sequence_invalid",
        "tts_input_closed",
        "tts_input_timeout",
        "tts_stream_limit_exceeded",
        "tts_backpressure",
        "tts_backend_failed",
    }
)


class TtsStreamError(RuntimeError):
    """One stable incremental-stream failure with a wire-level code."""

    def __init__(self, code: str, message: str) -> None:
        if code not in TTS_STREAM_ERROR_CODES:
            raise ValueError(f"unregistered incremental stream error code: {code}")
        super().__init__(message)
        self.code = code


class TtsStreamInputState(StrEnum):
    """Whether more text may still be appended."""

    OPEN = "open"
    CLOSED = "closed"


class TtsStreamOutputState(StrEnum):
    """Where the audio-producing side currently is."""

    STARTING = "starting"
    RUNNING = "running"
    DRAINING = "draining"
    TERMINAL = "terminal"


class TtsStreamTerminal(StrEnum):
    """The single terminal outcome of one utterance."""

    COMPLETED = "completed"
    CANCELLED = "cancelled"
    FAILED = "failed"


class TtsStreamEventKind(StrEnum):
    """Events surfaced to callers of one incremental utterance."""

    STARTED = "started"
    TEXT_ACCEPTED = "text_accepted"
    AUDIO = "audio"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    FAILED = "failed"


_TERMINAL_EVENTS: Final[dict[TtsStreamTerminal, TtsStreamEventKind]] = {
    TtsStreamTerminal.COMPLETED: TtsStreamEventKind.COMPLETED,
    TtsStreamTerminal.CANCELLED: TtsStreamEventKind.CANCELLED,
    TtsStreamTerminal.FAILED: TtsStreamEventKind.FAILED,
}


def _require_positive_int(value: object, *, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValueError(f"{name} must be a positive integer")
    return value


def _require_positive_seconds(value: object, *, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be a positive number of seconds")
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError(f"{name} must be a positive number of seconds")
    return seconds


@dataclass(frozen=True, slots=True)
class TtsStreamLimits:
    """Safety limits for one incremental utterance.

    These are conservative starting values, not tuned quality settings. Text is
    bounded in Unicode codepoints and pending audio in bytes so the two budgets
    can never be conflated.
    """

    max_append_codepoints: int = 512
    max_total_codepoints: int = 4096
    max_pending_codepoints: int = 2048
    max_pending_audio_bytes: int = 48_000
    input_wait_seconds: float = 15.0
    utterance_wall_clock_seconds: float = 120.0
    slow_consumer_seconds: float = 2.0

    def __post_init__(self) -> None:
        for name in (
            "max_append_codepoints",
            "max_total_codepoints",
            "max_pending_codepoints",
            "max_pending_audio_bytes",
        ):
            _require_positive_int(getattr(self, name), name=name)
        for name in (
            "input_wait_seconds",
            "utterance_wall_clock_seconds",
            "slow_consumer_seconds",
        ):
            _require_positive_seconds(getattr(self, name), name=name)
        if self.max_append_codepoints > self.max_total_codepoints:
            raise ValueError("max_append_codepoints must not exceed max_total_codepoints")
        if self.max_pending_codepoints > self.max_total_codepoints:
            raise ValueError("max_pending_codepoints must not exceed max_total_codepoints")


DEFAULT_TTS_STREAM_LIMITS: Final[TtsStreamLimits] = TtsStreamLimits()


@dataclass(frozen=True, slots=True)
class TtsStreamOptions:
    """Frozen per-utterance request identity.

    Voice and model revisions are captured at ``start`` so a later voice update
    cannot change what an in-flight utterance is speaking as.
    """

    request_id: str
    response_id: str
    voice: str
    language: str = "auto"
    speed: float = 1.0
    expected_voice_revision: str | None = None
    expected_model_revision: str | None = None

    def __post_init__(self) -> None:
        for name in ("request_id", "response_id", "voice", "language"):
            value = getattr(self, name)
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{name} must be a non-empty string")
        if isinstance(self.speed, bool) or not isinstance(self.speed, (int, float)):
            raise ValueError("speed must be a finite number")
        if not math.isfinite(float(self.speed)):
            raise ValueError("speed must be a finite number")


@dataclass(frozen=True, slots=True)
class TtsStreamEvent:
    """One sanitized incremental-stream event.

    Audio events carry the PCM plus the byte-exact position they occupy so a
    client can drop stale audio after cancellation without re-deriving offsets.
    """

    kind: TtsStreamEventKind
    response_id: str
    sequence: int | None = None
    accepted_codepoints: int = 0
    pcm16: bytes = b""
    chunk_index: int | None = None
    sample_offset: int | None = None
    terminal: TtsStreamTerminal | None = None
    error_code: str | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.response_id, str) or not self.response_id:
            raise ValueError("response_id must be a non-empty string")
        if self.kind is TtsStreamEventKind.AUDIO:
            if not self.pcm16 or len(self.pcm16) % 2:
                raise ValueError("audio events require even-length PCM16")
            if self.chunk_index is None or self.sample_offset is None:
                raise ValueError("audio events require chunk_index and sample_offset")
            if self.chunk_index < 0 or self.sample_offset < 0:
                raise ValueError("audio positions must not be negative")
            return
        if self.pcm16:
            raise ValueError("only audio events carry PCM")
        if self.kind is TtsStreamEventKind.TEXT_ACCEPTED:
            if self.sequence is None or self.sequence < 0:
                raise ValueError("text_accepted events require a sequence")
            if self.accepted_codepoints < 0:
                raise ValueError("accepted_codepoints must not be negative")
            return
        if self.kind is TtsStreamEventKind.FAILED:
            if self.error_code not in TTS_STREAM_ERROR_CODES:
                raise ValueError("failed events require a registered error code")
            return
        if self.kind in {TtsStreamEventKind.COMPLETED, TtsStreamEventKind.CANCELLED}:
            if self.terminal is None:
                raise ValueError("terminal events require a terminal outcome")
            return
        if self.kind is TtsStreamEventKind.STARTED and self.terminal is not None:
            raise ValueError("started events are not terminal")


@dataclass(frozen=True, slots=True)
class TtsStreamAudioPosition:
    """Byte-exact position of one produced audio chunk."""

    chunk_index: int
    sample_offset: int
    byte_length: int


@dataclass(slots=True)
class TtsStreamStateMachine:
    """Deterministic state table for one incremental utterance.

    The controller owns the model; this object owns only the bounded bookkeeping
    that must be identical for every backend and is verified with fakes.
    """

    limits: TtsStreamLimits = field(default_factory=lambda: DEFAULT_TTS_STREAM_LIMITS)
    _input_state: TtsStreamInputState = TtsStreamInputState.OPEN
    _output_state: TtsStreamOutputState = TtsStreamOutputState.STARTING
    _terminal: TtsStreamTerminal | None = None
    _accepted_sequence: int = -1
    _total_codepoints: int = 0
    _pending_codepoints: int = 0
    _pending_audio_bytes: int = 0
    _chunk_index: int = 0
    _sample_offset: int = 0

    @property
    def input_state(self) -> TtsStreamInputState:
        return self._input_state

    @property
    def output_state(self) -> TtsStreamOutputState:
        return self._output_state

    @property
    def terminal(self) -> TtsStreamTerminal | None:
        return self._terminal

    @property
    def accepted_sequence(self) -> int:
        """Sequence of the last accepted append; ``-1`` before any append."""

        return self._accepted_sequence

    @property
    def total_codepoints(self) -> int:
        return self._total_codepoints

    @property
    def pending_codepoints(self) -> int:
        return self._pending_codepoints

    @property
    def pending_audio_bytes(self) -> int:
        return self._pending_audio_bytes

    def mark_running(self) -> None:
        """Record that the backend accepted the utterance and started producing."""

        self._require_active()
        if self._output_state is not TtsStreamOutputState.STARTING:
            raise TtsStreamError("tts_input_closed", "stream is not starting")
        self._output_state = TtsStreamOutputState.RUNNING

    def accept_append(self, sequence: int, text: str) -> int:
        """Validate one append and record it as accepted, returning its codepoints.

        Acceptance means the text entered a bounded queue; it does not mean the
        model has spoken it. Every received codepoint counts, including spaces and
        whitespace-only packets.
        """

        self._require_active()
        if self._input_state is TtsStreamInputState.CLOSED:
            raise TtsStreamError("tts_input_closed", "text input is already closed")
        if isinstance(sequence, bool) or not isinstance(sequence, int):
            raise TtsStreamError("tts_sequence_invalid", "sequence must be an integer")
        if sequence != self._accepted_sequence + 1:
            raise TtsStreamError(
                "tts_sequence_invalid",
                "append sequence must be contiguous and monotonic",
            )
        if not isinstance(text, str):
            raise ValueError("appended text must be a string")
        codepoints = len(text)
        if codepoints > self.limits.max_append_codepoints:
            raise TtsStreamError(
                "tts_stream_limit_exceeded",
                "appended text exceeds the per-append codepoint limit",
            )
        if self._total_codepoints + codepoints > self.limits.max_total_codepoints:
            raise TtsStreamError(
                "tts_stream_limit_exceeded",
                "utterance exceeds the total codepoint limit",
            )
        if self._pending_codepoints + codepoints > self.limits.max_pending_codepoints:
            raise TtsStreamError(
                "tts_backpressure",
                "text is queued faster than the model consumes it",
            )
        self._accepted_sequence = sequence
        self._total_codepoints += codepoints
        self._pending_codepoints += codepoints
        return codepoints

    def mark_text_consumed(self, codepoints: int) -> None:
        """Record model consumption of previously accepted text."""

        self._require_active()
        if isinstance(codepoints, bool) or not isinstance(codepoints, int) or codepoints < 0:
            raise ValueError("consumed codepoints must be a non-negative integer")
        if codepoints > self._pending_codepoints:
            raise ValueError("cannot consume text that was never accepted")
        self._pending_codepoints -= codepoints

    def accept_finish(self, last_sequence: int) -> None:
        """Close text input, requiring the exact last accepted sequence."""

        self._require_active()
        if self._input_state is TtsStreamInputState.CLOSED:
            raise TtsStreamError("tts_input_closed", "text input is already closed")
        if isinstance(last_sequence, bool) or not isinstance(last_sequence, int):
            raise TtsStreamError("tts_sequence_invalid", "last_sequence must be an integer")
        if last_sequence != self._accepted_sequence:
            raise TtsStreamError(
                "tts_sequence_invalid",
                "last_sequence must equal the last accepted append",
            )
        self._input_state = TtsStreamInputState.CLOSED
        self._output_state = TtsStreamOutputState.DRAINING

    def enqueue_audio(self, byte_length: int) -> TtsStreamAudioPosition:
        """Reserve one produced audio chunk inside the pending-audio budget."""

        self._require_active()
        if (
            isinstance(byte_length, bool)
            or not isinstance(byte_length, int)
            or byte_length <= 0
            or byte_length % 2
        ):
            raise ValueError("audio chunks must be a positive even number of bytes")
        if self._pending_audio_bytes + byte_length > self.limits.max_pending_audio_bytes:
            raise TtsStreamError(
                "tts_backpressure",
                "pending audio exceeds the configured byte budget",
            )
        position = TtsStreamAudioPosition(
            chunk_index=self._chunk_index,
            sample_offset=self._sample_offset,
            byte_length=byte_length,
        )
        self._pending_audio_bytes += byte_length
        self._chunk_index += 1
        self._sample_offset += byte_length // 2
        return position

    def dequeue_audio(self, byte_length: int) -> None:
        """Record that previously produced audio left the transport buffer."""

        if isinstance(byte_length, bool) or not isinstance(byte_length, int) or byte_length < 0:
            raise ValueError("dequeued bytes must be a non-negative integer")
        if byte_length > self._pending_audio_bytes:
            raise ValueError("cannot dequeue audio that was never enqueued")
        self._pending_audio_bytes -= byte_length

    def complete(self) -> TtsStreamTerminal:
        """Record the single normal terminal outcome."""

        return self._finish_terminal(TtsStreamTerminal.COMPLETED)

    def cancel(self) -> TtsStreamTerminal:
        """Record the single cancellation terminal outcome; it is idempotent."""

        if self._terminal is TtsStreamTerminal.CANCELLED:
            return self._terminal
        if self._terminal is not None:
            raise TtsStreamError("tts_input_closed", "stream already reached a terminal state")
        self._terminal = TtsStreamTerminal.CANCELLED
        self._input_state = TtsStreamInputState.CLOSED
        self._output_state = TtsStreamOutputState.TERMINAL
        self._pending_audio_bytes = 0
        return self._terminal

    def fail(self, code: str) -> TtsStreamTerminal:
        """Record the single failure terminal outcome."""

        if code not in TTS_STREAM_ERROR_CODES:
            raise ValueError(f"unregistered incremental stream error code: {code}")
        if self._terminal is not None:
            raise TtsStreamError("tts_input_closed", "stream already reached a terminal state")
        self._terminal = TtsStreamTerminal.FAILED
        self._input_state = TtsStreamInputState.CLOSED
        self._output_state = TtsStreamOutputState.TERMINAL
        self._pending_audio_bytes = 0
        return self._terminal

    def terminal_event(self, response_id: str, *, error_code: str | None = None) -> TtsStreamEvent:
        """Project the recorded terminal outcome onto its event."""

        if self._terminal is None:
            raise ValueError("stream has no terminal outcome yet")
        kind = _TERMINAL_EVENTS[self._terminal]
        if kind is TtsStreamEventKind.FAILED:
            if error_code is None:
                raise ValueError("failed terminals must carry their error code explicitly")
            return TtsStreamEvent(
                kind=kind,
                response_id=response_id,
                terminal=self._terminal,
                error_code=error_code,
            )
        return TtsStreamEvent(kind=kind, response_id=response_id, terminal=self._terminal)

    def _finish_terminal(self, outcome: TtsStreamTerminal) -> TtsStreamTerminal:
        self._require_active()
        if self._input_state is TtsStreamInputState.OPEN:
            raise TtsStreamError(
                "tts_input_closed",
                "finish_text must close the input before completion",
            )
        self._terminal = outcome
        self._output_state = TtsStreamOutputState.TERMINAL
        self._pending_audio_bytes = 0
        return outcome

    def _require_active(self) -> None:
        if self._terminal is not None:
            raise TtsStreamError("tts_input_closed", "stream already reached a terminal state")


class IncrementalSpeechSession(Protocol):
    """One open incremental utterance owned by a model backend."""

    @property
    def options(self) -> TtsStreamOptions: ...

    async def append_text(self, sequence: int, text: str) -> None: ...

    async def finish_text(self, last_sequence: int) -> None: ...

    def events(self) -> AsyncIterator[TtsStreamEvent]: ...

    async def cancel(self) -> None: ...

    async def close(self) -> None: ...


class IncrementalSpeechSynthesizer(Protocol):
    """Vendor-neutral entry point; implementations must fail closed when unsupported."""

    async def open_stream(self, options: TtsStreamOptions) -> IncrementalSpeechSession: ...


__all__ = [
    "DEFAULT_TTS_STREAM_LIMITS",
    "TTS_STREAM_ERROR_CODES",
    "IncrementalSpeechSession",
    "IncrementalSpeechSynthesizer",
    "TtsStreamAudioPosition",
    "TtsStreamError",
    "TtsStreamEvent",
    "TtsStreamEventKind",
    "TtsStreamInputState",
    "TtsStreamLimits",
    "TtsStreamOptions",
    "TtsStreamOutputState",
    "TtsStreamStateMachine",
    "TtsStreamTerminal",
]
