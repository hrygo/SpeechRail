"""Append-only, steppable generation control for Qwen3-TTS.

This module is an additive SpeechRail vendor extension: it lives beside the
upstream ``qwen3_tts`` package and never edits upstream files.  It supplies the
control layer only -- the model integration is injected as a backend -- so the
same state machine drives the offline probe and the production worker.

Upstream ``Qwen3TTS.generate`` is a single blocking loop over a fully known
text.  Two invariants make that loop unusable for a streaming utterance:

* the caller cannot hand over text after the first audio frame, because the
  loop already consumed a trailing queue that ends in ``tts_eos``;
* reaching the end of that queue always means "finish", so a temporarily empty
  input is indistinguishable from a finished reply.

``IncrementalSessionDriver`` keeps the same per-frame model stepping but moves
the decision out of the loop.  Text that has not been consumed yet stays in a
re-tokenizing buffer whose already-consumed prefix is protected, and the feeder
answers one question per frame: consume text, wait for more text, or seal with
the held-back EOS.  Sampling and vocoding therefore stay inside one generation
whose KV cache, code predictor cache and vocoder streaming state are never
rebuilt between appends.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Final, Literal, Protocol

EventKind = Literal["pcm", "waiting_for_text", "finished", "error"]
FeedAction = Literal["text", "wait", "seal", "pad"]

MAX_APPEND_CHARS: Final[int] = 4_096
MAX_FRAMES_WITHOUT_TERMINAL: Final[int] = 4_096


class IncrementalTextError(RuntimeError):
    """Raised when an append would invalidate already generated audio."""


class IncrementalStateError(RuntimeError):
    """Raised when the driver is asked to advance outside its lifecycle."""


class IncrementalBackendError(RuntimeError):
    """Raised when the model backend reports a failed frame."""


@dataclass(frozen=True, slots=True)
class IncrementalEvent:
    """One bounded outcome of a driver step."""

    kind: EventKind
    pcm16: bytes = b""
    error_code: str | None = None


@dataclass(frozen=True, slots=True)
class FrameOutcome:
    """What one backend frame produced."""

    pcm16: bytes = b""
    terminal: bool = False


class IncrementalBackend(Protocol):
    """Model-side seam owned by the vendor extension."""

    @property
    def generation_identity(self) -> str: ...

    @property
    def sample_rate(self) -> int: ...

    @property
    def prefill_target_tokens(self) -> int: ...

    @property
    def peak_memory_bytes(self) -> int | None: ...

    def encode_target_text(self, text: str) -> Sequence[int]: ...

    def begin_generation(self, text: str) -> int:
        """Freeze conditioning, build the single prefill, return its text tokens."""

    def advance(self, *, token: int | None, seal: bool) -> FrameOutcome:
        """Run one talker frame with one text token, the held-back EOS, or pad."""

    def cancel(self) -> None: ...

    def close(self) -> None: ...


class StableTextTokenBuffer:
    """Cumulative target text whose consumed token prefix must never change.

    Every append re-tokenizes the whole accumulated text, because a tokenizer
    cannot merge two independently encoded fragments into the same ids.  The
    guard is that the prefix already handed to the model is byte-for-byte
    identical afterwards; otherwise the audio already emitted would no longer
    match the text it was generated from, so the append fails closed.
    """

    def __init__(self, encode: Callable[[str], Sequence[int]]) -> None:
        self._encode = encode
        self._text = ""
        self._tokens: tuple[int, ...] = ()
        self._consumed = 0

    @property
    def text(self) -> str:
        return self._text

    @property
    def consumed(self) -> int:
        return self._consumed

    @property
    def tokens(self) -> tuple[int, ...]:
        return self._tokens

    @property
    def remaining(self) -> int:
        return len(self._tokens) - self._consumed

    def append(self, text: str) -> tuple[int, ...]:
        """Accumulate text and return the tokens the model has not consumed yet."""

        if not isinstance(text, str):
            raise IncrementalTextError("append_text_requires_str")
        combined = self._text + text
        if len(combined) > MAX_APPEND_CHARS:
            raise IncrementalTextError("append_text_exceeds_limit")
        encoded = tuple(int(item) for item in self._encode(combined))
        if len(encoded) < self._consumed:
            raise IncrementalTextError("stable_text_prefix_changed")
        if encoded[: self._consumed] != self._tokens[: self._consumed]:
            raise IncrementalTextError("stable_text_prefix_changed")
        self._text = combined
        self._tokens = encoded
        return encoded[self._consumed :]

    def take(self, count: int) -> tuple[int, ...]:
        """Mark tokens as consumed by the model and return them."""

        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise IncrementalTextError("token_count_invalid")
        if count > self.remaining:
            raise IncrementalStateError("consumed_beyond_available_text")
        taken = self._tokens[self._consumed : self._consumed + count]
        self._consumed += count
        return taken

    def next_token(self) -> int:
        return self.take(1)[0]


class IncrementalTextFeeder:
    """Decide, per frame, between text, waiting, and the sealed EOS tail."""

    def __init__(self, buffer: StableTextTokenBuffer) -> None:
        self._buffer = buffer
        self._input_finished = False
        self._sealed = False

    @property
    def input_finished(self) -> bool:
        return self._input_finished

    @property
    def sealed(self) -> bool:
        return self._sealed

    @property
    def starved(self) -> bool:
        return self._buffer.remaining == 0 and not self._input_finished

    def finish_input(self) -> None:
        self._input_finished = True

    def next_action(self) -> FeedAction:
        if self._buffer.remaining > 0:
            return "text"
        if not self._input_finished:
            return "wait"
        if not self._sealed:
            return "seal"
        return "pad"

    def consume(self) -> int:
        """Consume exactly one buffered target token."""

        return self._buffer.next_token()

    def seal(self) -> None:
        """Record that the held-back EOS has been handed to the model."""

        self._sealed = True


class IncrementalSessionDriver:
    """Own one append-only generation on top of an injected model backend."""

    def __init__(
        self,
        backend: IncrementalBackend,
        encode_target_text: Callable[[str], Sequence[int]] | None = None,
        *,
        max_chars: int = MAX_APPEND_CHARS,
    ) -> None:
        encode = encode_target_text or backend.encode_target_text
        self._backend = backend
        self._buffer = StableTextTokenBuffer(encode)
        self._feeder = IncrementalTextFeeder(self._buffer)
        self._max_chars = max_chars
        self._prefill_count = 0
        self._prefill_frame_pending = False
        self._frames = 0
        self._pending_pcm: list[bytes] = []
        self._terminal = False
        self._cancelled = False
        self._closed = False

    # ---------------------------------------------------------------- metadata

    @property
    def generation_identity(self) -> str:
        return self._backend.generation_identity

    @property
    def sample_rate(self) -> int:
        return self._backend.sample_rate

    @property
    def initial_prefill_count(self) -> int:
        return self._prefill_count

    @property
    def prefill_target_tokens(self) -> int:
        return self._backend.prefill_target_tokens

    @property
    def peak_memory_bytes(self) -> int | None:
        return self._backend.peak_memory_bytes

    # ------------------------------------------------------------- text input

    def append_text(self, text: str) -> Sequence[int]:
        """Commit new text and report the token suffix still to be spoken."""

        if self._closed:
            raise IncrementalStateError("session_closed")
        if self._terminal:
            raise IncrementalStateError("session_finished")
        if self._cancelled:
            raise IncrementalStateError("session_cancelled")
        if len(self._buffer.text) + len(text) > self._max_chars:
            raise IncrementalTextError("append_text_exceeds_limit")
        return self._buffer.append(text)

    def finish_input(self) -> None:
        if self._closed:
            raise IncrementalStateError("session_closed")
        self._feeder.finish_input()

    # ------------------------------------------------------------------ steps

    def step(self, *, max_steps: int) -> IncrementalEvent:
        """Advance the model and report one bounded outcome.

        ``max_steps`` bounds how many talker frames one call may run, so the
        caller can still observe cancellation and text appends.  The call never
        reports a terminal or waiting event that is not true at the moment it
        returns, which is what lets the probe reject a backend that submits the
        final EOS while the caller still intends to append.
        """

        if not isinstance(max_steps, int) or isinstance(max_steps, bool) or max_steps <= 0:
            raise IncrementalStateError("max_steps_invalid")
        if self._closed:
            raise IncrementalStateError("session_closed")
        if self._cancelled:
            raise IncrementalStateError("session_cancelled")
        if self._terminal:
            return IncrementalEvent(kind="finished")

        try:
            if self._prefill_count == 0:
                if self._buffer.remaining == 0:
                    return IncrementalEvent(kind="waiting_for_text")
                consumed = self._backend.begin_generation(self._buffer.text)
                self._buffer.take(consumed)
                self._prefill_count = 1
                # The prefill forward pass is the first frame; the backend only
                # starts reading the trailing text queue after it has sampled
                # that frame, so it must not consume a text token here.
                self._prefill_frame_pending = True
            return self._advance(max_steps)
        except (IncrementalTextError, IncrementalStateError):
            raise
        except Exception:
            self._terminal = True
            return IncrementalEvent(kind="error", error_code="tts_backend_failed")

    def _advance(self, max_steps: int) -> IncrementalEvent:
        for _ in range(max_steps):
            if self._pending_pcm:
                return IncrementalEvent(kind="pcm", pcm16=self._pending_pcm.pop(0))
            if self._prefill_frame_pending:
                # Upstream samples the first codec frame from the prefill
                # forward pass itself.  Taking a text token for it would drop
                # that token and shift the whole utterance by one frame.
                self._prefill_frame_pending = False
                outcome = self._backend.advance(token=None, seal=False)
            else:
                action = self._feeder.next_action()
                if action == "wait":
                    return IncrementalEvent(kind="waiting_for_text")
                if action == "seal":
                    outcome = self._backend.advance(token=None, seal=True)
                    self._feeder.seal()
                elif action == "pad":
                    outcome = self._backend.advance(token=None, seal=False)
                else:
                    outcome = self._backend.advance(token=self._feeder.consume(), seal=False)
            self._frames += 1
            if self._frames > MAX_FRAMES_WITHOUT_TERMINAL:
                self._terminal = True
                return IncrementalEvent(kind="error", error_code="tts_backend_failed")
            if outcome.pcm16:
                self._pending_pcm.append(outcome.pcm16)
            if outcome.terminal:
                self._terminal = True
        if self._pending_pcm:
            return IncrementalEvent(kind="pcm", pcm16=self._pending_pcm.pop(0))
        if self._terminal:
            return IncrementalEvent(kind="finished")
        # A frame budget that expires without audio is only allowed while the
        # driver is genuinely waiting for text; anything else would hide a
        # stalled model behind a legal event.
        if self._feeder.starved:
            return IncrementalEvent(kind="waiting_for_text")
        raise IncrementalBackendError("incremental_frame_budget_exhausted")

    # -------------------------------------------------------------- lifecycle

    def cancel(self) -> None:
        if self._cancelled:
            return
        self._cancelled = True
        self._backend.cancel()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._backend.close()


__all__ = [
    "MAX_APPEND_CHARS",
    "FrameOutcome",
    "IncrementalBackend",
    "IncrementalBackendError",
    "IncrementalEvent",
    "IncrementalSessionDriver",
    "IncrementalStateError",
    "IncrementalTextError",
    "IncrementalTextFeeder",
    "StableTextTokenBuffer",
]
