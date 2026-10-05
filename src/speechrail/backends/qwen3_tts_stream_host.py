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
import queue
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import BinaryIO, Final, Literal, Protocol

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
from speechrail.runtime.worker_protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    read_frame,
    write_frame,
)

TTS_STREAM_PROTOCOL_VERSION: Final[int] = 1

# Tail fade length, kept identical to the batch TTS path in `qwen3_tts_worker`.
TAIL_FADE_MS: Final[int] = 5

FRAME_STREAM_START: Final[str] = "tts_stream_start"
FRAME_STREAM_TEXT: Final[str] = "tts_stream_text"
FRAME_STREAM_FINISH: Final[str] = "tts_stream_finish"
FRAME_STREAM_CANCEL: Final[str] = "tts_stream_cancel"
FRAME_STREAM_STARTED: Final[str] = "tts_stream_started"
FRAME_STREAM_TEXT_ACCEPTED: Final[str] = "tts_stream_text_accepted"
FRAME_STREAM_TEXT_CONSUMED: Final[str] = "tts_stream_text_consumed"
FRAME_STREAM_AUDIO: Final[str] = "tts_stream_audio"
FRAME_STREAM_DONE: Final[str] = "tts_stream_done"
FRAME_STREAM_ERROR: Final[str] = "tts_stream_error"

# Idle poll granularity: small enough to notice a closed pipe promptly, large
# enough that a worker waiting for its next request stays nearly idle.
_POLL_INTERVAL_SECONDS: Final[float] = 0.2

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
    waiting_for_output: bool = False
    terminal: bool = False


def _require_int(value: object, *, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ProtocolError(f"{name} must be an integer")
    return value


def _fade_ramp_from(last_sample: int, sample_rate: int) -> bytes:
    """Linear PCM16 ramp from ``last_sample`` down to silence over the tail fade."""

    samples = max(1, (sample_rate * TAIL_FADE_MS) // 1000)
    if last_sample == 0:
        # Already at silence: emit the window anyway so every finished
        # utterance ends in the same explicit quiet, never mid-step.
        return b"\x00\x00" * samples
    import numpy as np

    curve = np.linspace(float(last_sample), 0.0, samples, dtype=np.float32)
    return np.clip(curve, -32768.0, 32767.0).astype("<i2").tobytes()


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
        self._consumed_codepoints = 0
        self._consumed_sequence = -1
        self._pcm_remainder = b""
        # Writer receipts cross threads; only the model thread mutates the
        # domain state machine. Receipts contain counters, never PCM.
        self._delivery_lock = threading.Lock()
        self._delivered_bytes = 0
        self._last_delivery_at = started_at
        self._output_wait_since: float | None = None
        # Last int16 sample actually handed to the transport, so the terminal
        # fade can continue the waveform instead of stepping from silence.
        self._last_audio_sample: int | None = None

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
        self._retire_delivered_audio()
        if self._pcm_remainder:
            frames = self._flush_pcm_remainder()
            if frames:
                return HostStepResult(frames=frames)
            return self._wait_for_output()
        if self._state.pending_audio_bytes >= self._limits.max_pending_audio_bytes:
            return self._wait_for_output()
        self._output_wait_since = None
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

    def output_timeout_remaining(self) -> float:
        """Bound inactivity, not the total time spent producing ahead of playback."""

        now = float(self._clock())
        with self._delivery_lock:
            progress_at = self._last_delivery_at
        wait_since = self._output_wait_since
        base = max(progress_at, now if wait_since is None else wait_since)
        return max(
            0.0,
            min(
                self._limits.slow_consumer_seconds - (now - base),
                self._limits.utterance_wall_clock_seconds - (now - self._started_at),
            ),
        )

    def _wait_for_output(self) -> HostStepResult:
        if self._output_wait_since is None:
            self._output_wait_since = float(self._clock())
        if self.output_timeout_remaining() > 0:
            return HostStepResult(waiting_for_output=True)
        if float(self._clock()) - self._started_at >= self._limits.utterance_wall_clock_seconds:
            frames = self.expire()
        else:
            frames = self._terminate(
                "tts_backpressure", detail="worker output made no delivery progress"
            )
        return HostStepResult(frames=frames, terminal=True)

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
            terminal_frames = self._terminate(
                "tts_backend_failed",
                detail="the model stalled after the input was closed",
            )
            return HostStepResult(frames=terminal_frames, terminal=True)
        if self._state.terminal is not None:
            return HostStepResult(terminal=True)
        if self.timeout_remaining() <= 0.0:
            terminal_frames = self.expire()
            return HostStepResult(frames=terminal_frames, terminal=True)
        frames: tuple[StreamFrame, ...] = ()
        consumed = self._state.total_codepoints - self._consumed_codepoints
        if consumed > 0:
            self._state.mark_text_consumed(consumed)
            self._consumed_codepoints += consumed
            self._consumed_sequence = self._state.accepted_sequence
            frames = (
                StreamFrame(
                    {
                        "version": PROTOCOL_VERSION,
                        "type": FRAME_STREAM_TEXT_CONSUMED,
                        "request_id": self._options.request_id,
                        "through_sequence": self._consumed_sequence,
                        "consumed_codepoints_total": self._consumed_codepoints,
                    }
                ),
            )
        return HostStepResult(frames=frames, waiting_for_text=True)

    def _emit_audio(self, pcm16: bytes) -> HostStepResult:
        if not pcm16 or len(pcm16) % 2:
            frames = self._terminate("tts_backend_failed", detail="invalid PCM chunk")
            return HostStepResult(frames=frames, terminal=True)
        self._pcm_remainder += pcm16
        frames = self._flush_pcm_remainder()
        if not frames:
            return self._wait_for_output()
        return HostStepResult(frames=frames)

    def _flush_pcm_remainder(self) -> tuple[StreamFrame, ...]:
        frames: list[StreamFrame] = []
        while self._pcm_remainder:
            available = self._limits.max_pending_audio_bytes - self._state.pending_audio_bytes
            if available < 2:
                break
            byte_length = min(
                available - (available % 2),
                len(self._pcm_remainder),
            )
            try:
                position = self._state.enqueue_audio(byte_length)
            except TtsStreamError as exc:
                error = self._recoverable_or_terminal(exc)
                self._pcm_remainder = b""
                return (*frames, *error)
            chunk = self._pcm_remainder[:byte_length]
            self._pcm_remainder = self._pcm_remainder[byte_length:]
            self._last_audio_sample = int.from_bytes(
                chunk[-2:], "little", signed=True
            )
            frames.append(
                StreamFrame(
                    {
                        "version": PROTOCOL_VERSION,
                        "type": FRAME_STREAM_AUDIO,
                        "request_id": self._options.request_id,
                        "chunk_index": position.chunk_index,
                        "sample_offset": position.sample_offset,
                        "sample_rate": self._session.sample_rate,
                    },
                    binary=chunk,
                    on_sent=self._audio_sent(position.byte_length),
                )
            )
        return tuple(frames)

    def _audio_sent(self, byte_length: int) -> Callable[[], None]:
        def retire() -> None:
            with self._delivery_lock:
                self._delivered_bytes += byte_length
                self._last_delivery_at = float(self._clock())

        return retire

    def _retire_delivered_audio(self) -> None:
        with self._delivery_lock:
            delivered = self._delivered_bytes
            self._delivered_bytes = 0
        if delivered:
            self._state.dequeue_audio(delivered)

    def _complete(self) -> tuple[StreamFrame, ...]:
        if self._state.terminal is not None:
            return ()
        fade = self._emit_tail_fade()
        self._state.complete()
        self._release_session(cancel=False)
        return (*fade, *self._terminal_frames())

    def _emit_tail_fade(self) -> tuple[StreamFrame, ...]:
        """Append a short fade-to-silence ramp ahead of the terminal.

        The last codec frame ends wherever the model stopped, and that is often
        mid-vowel at a large sample value, so the speaker reproduces the step
        as an audible click. The batch TTS path has always faded its final
        chunk (`qwen3_tts_worker`); without the same step here the two paths
        disagree about what a finished utterance sounds like.

        The ramp starts from the last sample that was actually sent, so it
        continues the waveform rather than stepping away from it. Emitting it
        as one more ordinary audio frame keeps chunk indices and sample
        offsets contiguous, and costs no latency: nothing is held back during
        synthesis, unlike reserving a tail that would also delay short
        utterances.
        """

        if self._last_audio_sample is None:
            return ()
        ramp = _fade_ramp_from(self._last_audio_sample, self._session.sample_rate)
        available = self._limits.max_pending_audio_bytes - self._state.pending_audio_bytes
        if available < len(ramp):
            # A truncated ramp would reintroduce the step this removes, and the
            # budget is about to be released anyway; drop it and still finish.
            return ()
        try:
            position = self._state.enqueue_audio(len(ramp))
        except TtsStreamError:
            return ()
        return (
            StreamFrame(
                {
                    "version": PROTOCOL_VERSION,
                    "type": FRAME_STREAM_AUDIO,
                    "request_id": self._options.request_id,
                    "chunk_index": position.chunk_index,
                    "sample_offset": position.sample_offset,
                    "sample_rate": self._session.sample_rate,
                },
                binary=ramp,
                on_sent=self._audio_sent(position.byte_length),
            ),
        )

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


class StreamPump:
    """Move frames between the worker pipes and the model loop with bounded queues.

    The reader thread only decodes frames and enqueues them, so a cancel that
    arrives while the model is mid-step is still observed through a priority
    flag instead of waiting behind a full text queue.  The writer thread owns
    stdout, so a parent that stops reading can never stall inference; it reports
    the broken pipe back through ``write_error`` instead.
    """

    def __init__(
        self,
        input_stream: BinaryIO,
        output_stream: BinaryIO,
        *,
        inbound_capacity: int = 64,
        outbound_capacity: int = 32,
    ) -> None:
        if inbound_capacity < 1 or outbound_capacity < 1:
            raise ValueError("frame queues must be positive")
        self._input = input_stream
        self._output = output_stream
        self._inbound: queue.Queue[dict[str, object]] = queue.Queue(
            maxsize=inbound_capacity
        )
        self._outbound_capacity = outbound_capacity
        # The writer drains this deque and every producer appends under the same
        # condition, so a terminal can retire the stale PCM of its own request
        # without reordering what a later utterance already queued.
        self._condition = threading.Condition()
        self._activity_generation = 0
        self._outbound: deque[StreamFrame] = deque()
        self._cancel = threading.Event()
        self._read_finished = threading.Event()
        self._closed = False
        self._reader: threading.Thread | None = None
        self._writer: threading.Thread | None = None
        self.cancel_request_id: str | None = None
        self.read_error: BaseException | None = None
        self.write_error: BaseException | None = None

    def start(self) -> None:
        self._reader = threading.Thread(
            target=self._read_loop, name="tts-worker-reader", daemon=True
        )
        self._writer = threading.Thread(
            target=self._write_loop, name="tts-worker-writer", daemon=True
        )
        self._reader.start()
        self._writer.start()

    @property
    def at_eof(self) -> bool:
        """True once the parent closed stdin and every queued frame was drained."""

        return self._read_finished.is_set() and self._inbound.empty()

    @property
    def cancel_pending(self) -> bool:
        return self._cancel.is_set()

    @property
    def activity_generation(self) -> int:
        with self._condition:
            return self._activity_generation

    def wait_for_activity(self, after: int, *, timeout: float) -> None:
        """Wait for input or actual output progress without losing a wakeup."""

        with self._condition:
            self._condition.wait_for(
                lambda: self._activity_generation != after or self._closed,
                timeout=max(0.0, timeout),
            )

    def _signal_activity(self) -> None:
        with self._condition:
            self._activity_generation += 1
            self._condition.notify_all()

    def poll(self, timeout: float | None = None) -> dict[str, object] | None:
        """Return the next inbound frame, or ``None`` on timeout, EOF or failure.

        The short internal wait is what lets a reader thread that died (clean EOF
        or a malformed frame) wake a model loop parked with no deadline; without
        it an idle worker would never notice the parent closed the pipe.
        """

        if self.write_error is not None:
            return None
        deadline = None if timeout is None else time.monotonic() + max(0.0, timeout)
        while True:
            try:
                return self._inbound.get_nowait()
            except queue.Empty:
                pass
            if self.read_error is not None or self.write_error is not None:
                return None
            if self._read_finished.is_set() and self._inbound.empty():
                return None
            now = time.monotonic()
            if deadline is not None and now >= deadline:
                return None
            wait = _POLL_INTERVAL_SECONDS
            if deadline is not None:
                wait = min(wait, max(0.0, deadline - now))
            try:
                return self._inbound.get(timeout=wait)
            except queue.Empty:
                continue

    def submit(self, frame: StreamFrame, *, timeout: float | None = None) -> bool:
        """Queue one outbound frame; ``False`` means the parent stopped reading."""

        deadline = None if timeout is None else time.monotonic() + max(0.0, timeout)
        with self._condition:
            while len(self._outbound) >= self._outbound_capacity:
                if self._closed or self.write_error is not None:
                    return False
                remaining = (
                    _POLL_INTERVAL_SECONDS
                    if deadline is None
                    else deadline - time.monotonic()
                )
                if remaining <= 0.0:
                    return False
                self._condition.wait(timeout=remaining)
            if self._closed or self.write_error is not None:
                return False
            self._outbound.append(frame)
            self._condition.notify_all()
            return True

    def submit_terminal(self, frame: StreamFrame) -> bool:
        """Queue a cancel/failure terminal without waiting behind its own PCM.

        A terminal is the last frame of its utterance, so it must never wait for
        the bounded audio queue to drain behind PCM the caller has stopped
        reading.  The queued PCM of *this* request is retired on the spot and the
        terminal keeps submission order, which is what makes it the final frame
        of its request instead of overtaking its own ``started`` or
        ``text_accepted`` control frames.
        """

        with self._condition:
            if self._closed or self.write_error is not None:
                return False
            self._retire_locked(request_id=_frame_request_id(frame))
            self._outbound.append(frame)
            self._condition.notify_all()
            return True

    def acknowledge_cancel(self, request_id: str | None) -> None:
        """Retire the priority flag once the model has stopped for that stream."""

        if request_id is None or self.cancel_request_id == request_id:
            self.cancel_request_id = None
            self._cancel.clear()

    def discard_ended_stream(self, request_id: str) -> None:
        """Drop queued frames that belong to a stream the worker already ended.

        The reader thread queues every inbound frame, including the cancel that
        the model loop observes through the priority flag instead of through the
        queue.  A frame left behind would be answered for a request the worker
        no longer serves, so the next utterance would read a foreign
        ``request_id`` and fail before it ever reached the model.
        """

        if not request_id:
            return
        while True:
            try:
                head = self._inbound.queue[0]
            except IndexError:
                return
            if not isinstance(head, dict) or head.get("request_id") != request_id:
                return
            try:
                self._inbound.get_nowait()
            except queue.Empty:  # pragma: no cover - single consumer
                return

    def stop(self, *, join_timeout_seconds: float = 2.0) -> None:
        """Stop both threads without ever waiting unbounded on a stuck pipe."""

        with self._condition:
            self._closed = True
            self._activity_generation += 1
            self._condition.notify_all()
        for thread in (self._writer, self._reader):
            if thread is not None:
                thread.join(timeout=join_timeout_seconds)

    def _read_loop(self) -> None:
        try:
            while not self._closed:
                frame = read_frame(self._input)
                if frame is None:
                    return
                if frame.get("type") == FRAME_STREAM_CANCEL:
                    request_id = frame.get("request_id")
                    if isinstance(request_id, str) and request_id:
                        self.cancel_request_id = request_id
                        self._cancel.set()
                    # The flag is the authoritative signal; dropping the
                    # duplicate frame keeps the reader from stalling on a full
                    # text queue.
                    with contextlib.suppress(queue.Full):
                        self._inbound.put_nowait(frame)
                    self._signal_activity()
                    continue
                self._inbound.put(frame)
                self._signal_activity()
        except BaseException as exc:
            self.read_error = exc
        finally:
            self._read_finished.set()
            self._signal_activity()

    def _write_loop(self) -> None:
        while True:
            frame = self._next_outbound()
            if frame is None:
                return
            try:
                write_frame(
                    self._output, frame.payload, binary_payload=frame.binary
                )
            except BaseException as exc:
                with self._condition:
                    self.write_error = exc
                    self._activity_generation += 1
                    self._condition.notify_all()
                self._drop_pending()
                return
            if frame.on_sent is not None:
                with contextlib.suppress(Exception):
                    frame.on_sent()
            self._signal_activity()

    def _next_outbound(self) -> StreamFrame | None:
        with self._condition:
            while True:
                if self._outbound:
                    frame = self._outbound.popleft()
                    self._condition.notify_all()
                    return frame
                if self._closed:
                    return None
                self._condition.wait(timeout=_POLL_INTERVAL_SECONDS)

    def _drop_pending(self) -> None:
        with self._condition:
            dropped = list(self._outbound)
            self._outbound.clear()
            self._retire(dropped)
            self._condition.notify_all()

    def _retire_locked(self, *, request_id: str | None) -> None:
        """Retire this request's queued PCM; keep its ordered control frames."""

        kept: deque[StreamFrame] = deque()
        retired: list[StreamFrame] = []
        for frame in self._outbound:
            if frame.binary is not None and _frame_request_id(frame) == request_id:
                retired.append(frame)
            else:
                kept.append(frame)
        if not retired:
            return
        self._outbound.clear()
        self._outbound.extend(kept)
        self._retire(retired)

    @staticmethod
    def _retire(frames: list[StreamFrame]) -> None:
        for frame in frames:
            if frame.on_sent is not None:
                with contextlib.suppress(Exception):
                    frame.on_sent()


def _frame_request_id(frame: StreamFrame) -> str | None:
    """The utterance a frame belongs to, or ``None`` when it carries no identity."""

    request_id = frame.payload.get("request_id")
    return request_id if isinstance(request_id, str) else None



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
    "FRAME_STREAM_TEXT_CONSUMED",
    "RECOVERABLE_STREAM_ERROR_CODES",
    "STREAM_FRAME_TYPES",
    "TTS_STREAM_PROTOCOL_VERSION",
    "HostStepResult",
    "IncrementalModelSession",
    "ModelStepEvent",
    "StreamCommand",
    "StreamFrame",
    "StreamPump",
    "TtsStreamHost",
    "parse_stream_command",
]
