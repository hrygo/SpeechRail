"""Deterministic contract tests for the incremental TTS worker-side host.

These tests never import MLX or a vendor runtime: the model session is a fake so
the wire vocabulary, the single state machine and the slow-consumer/limit rules
can be pinned exactly.
"""

from __future__ import annotations

from typing import Any

import pytest

from speechrail.backends.qwen3_tts_stream_host import (
    FRAME_STREAM_AUDIO,
    FRAME_STREAM_CANCEL,
    FRAME_STREAM_DONE,
    FRAME_STREAM_ERROR,
    FRAME_STREAM_FINISH,
    FRAME_STREAM_STARTED,
    FRAME_STREAM_TEXT,
    FRAME_STREAM_TEXT_ACCEPTED,
    TTS_STREAM_PROTOCOL_VERSION,
    ModelStepEvent,
    StreamFrame,
    TtsStreamHost,
    parse_stream_command,
)
from speechrail.backends.qwen3_tts_worker import _drive_stream
from speechrail.domain.tts_stream import (
    DEFAULT_TTS_STREAM_LIMITS,
    TtsStreamLimits,
    TtsStreamOptions,
    TtsStreamTerminal,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, ProtocolError


class FakeModelSession:
    """Mirror the vendor driver contract without loading any model state."""

    def __init__(
        self,
        *,
        sample_rate: int = 24_000,
        generation_identity: str = "gen-a",
        events: list[ModelStepEvent] | None = None,
        on_step: Any = None,
    ) -> None:
        self.sample_rate = sample_rate
        self.generation_identity = generation_identity
        self.prefill_target_tokens = 1
        self.events = list(events or [])
        self.appended: list[str] = []
        self.finished = False
        self.cancelled = 0
        self.closed = 0
        self.step_calls = 0
        self._on_step = on_step

    def append_text(self, text: str) -> tuple[int, ...]:
        if self.finished:
            raise RuntimeError("input already finished")
        self.appended.append(text)
        return tuple(range(len(text)))

    def finish_input(self) -> None:
        self.finished = True

    def step(self, *, max_steps: int) -> ModelStepEvent:
        self.step_calls += 1
        if self._on_step is not None:
            self._on_step(max_steps)
        if self.events:
            return self.events.pop(0)
        return ModelStepEvent(kind="finished")

    def cancel(self) -> None:
        self.cancelled += 1

    def close(self) -> None:
        self.closed += 1


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def _options(**overrides: Any) -> TtsStreamOptions:
    base: dict[str, Any] = {
        "request_id": "req_stream",
        "response_id": "resp_stream",
        "voice": "serena",
    }
    base.update(overrides)
    return TtsStreamOptions(**base)


def _host(
    session: FakeModelSession,
    *,
    options: TtsStreamOptions | None = None,
    limits: TtsStreamLimits | None = None,
    clock: Any = None,
    step_size: int = 4,
) -> TtsStreamHost:
    return TtsStreamHost(
        session,
        options or _options(),
        limits=limits or DEFAULT_TTS_STREAM_LIMITS,
        clock=clock or Clock(),
        step_size=step_size,
    )


def _pcm(samples: int) -> bytes:
    return b"\x01\x00" * samples


def test_parse_stream_command_validates_the_envelope() -> None:
    with pytest.raises(ProtocolError):
        parse_stream_command({"version": 2, "type": FRAME_STREAM_CANCEL, "request_id": "r"})
    with pytest.raises(ProtocolError):
        parse_stream_command({"version": PROTOCOL_VERSION, "type": "synthesize"})
    with pytest.raises(ProtocolError):
        parse_stream_command({"version": PROTOCOL_VERSION, "type": FRAME_STREAM_CANCEL})

    text = parse_stream_command(
        {
            "version": PROTOCOL_VERSION,
            "type": FRAME_STREAM_TEXT,
            "request_id": "r1",
            "sequence": 3,
            "text": "你好",
        }
    )
    assert (text.kind, text.sequence, text.text) == ("text", 3, "你好")
    finish = parse_stream_command(
        {
            "version": PROTOCOL_VERSION,
            "type": FRAME_STREAM_FINISH,
            "request_id": "r1",
            "last_sequence": 3,
        }
    )
    assert (finish.kind, finish.last_sequence) == ("finish", 3)
    cancel = parse_stream_command(
        {"version": PROTOCOL_VERSION, "type": FRAME_STREAM_CANCEL, "request_id": "r1"}
    )
    assert cancel.kind == "cancel"


def test_parse_stream_command_rejects_non_integer_sequence() -> None:
    with pytest.raises(ProtocolError):
        parse_stream_command(
            {
                "version": PROTOCOL_VERSION,
                "type": FRAME_STREAM_TEXT,
                "request_id": "r1",
                "sequence": True,
                "text": "x",
            }
        )
    with pytest.raises(ProtocolError):
        parse_stream_command(
            {
                "version": PROTOCOL_VERSION,
                "type": FRAME_STREAM_FINISH,
                "request_id": "r1",
                "last_sequence": "3",
            }
        )


def test_started_frame_announces_protocol_identity_and_limits() -> None:
    session = FakeModelSession()
    host = _host(session)
    (frame,) = host.started_frames()
    assert frame.payload["type"] == FRAME_STREAM_STARTED
    assert frame.payload["request_id"] == "req_stream"
    assert frame.payload["response_id"] == "resp_stream"
    assert frame.payload["stream_protocol"] == TTS_STREAM_PROTOCOL_VERSION
    assert frame.payload["sample_rate"] == 24_000
    assert frame.payload["generation_identity"] == "gen-a"
    assert frame.payload["prefill_target_tokens"] == 1
    limits = frame.payload["limits"]
    assert limits["max_append_codepoints"] == DEFAULT_TTS_STREAM_LIMITS.max_append_codepoints
    assert frame.binary is None


def test_contiguous_append_is_acknowledged_and_forwarded_to_the_model() -> None:
    session = FakeModelSession()
    host = _host(session)
    (first,) = host.accept_text(0, "你好。")
    assert first.payload["type"] == FRAME_STREAM_TEXT_ACCEPTED
    assert first.payload["sequence"] == 0
    assert first.payload["accepted_codepoints"] == 3
    assert host.accepted_sequence == 0
    (second,) = host.accept_text(1, "继续")
    assert second.payload["sequence"] == 1
    assert session.appended == ["你好。", "继续"]


def test_sequence_gap_is_recoverable_and_does_not_advance_state() -> None:
    session = FakeModelSession()
    host = _host(session)
    assert host.accept_text(0, "abc")[0].payload["type"] == FRAME_STREAM_TEXT_ACCEPTED
    (rejected,) = host.accept_text(2, "def")
    assert rejected.payload["type"] == FRAME_STREAM_ERROR
    assert rejected.payload["code"] == "tts_sequence_invalid"
    assert rejected.payload["terminal"] is False
    assert rejected.payload["sequence"] == 2
    assert host.accepted_sequence == 0
    assert session.appended == ["abc"]
    # The caller can retry the rejected packet with the right sequence.
    assert host.accept_text(1, "def")[0].payload["type"] == FRAME_STREAM_TEXT_ACCEPTED
    assert host.accepted_sequence == 1


def test_append_after_finish_is_rejected_without_ending_the_utterance() -> None:
    session = FakeModelSession()
    host = _host(session)
    host.accept_text(0, "abc")
    assert host.finish_input(0) == ()
    (rejected,) = host.accept_text(1, "def")
    assert rejected.payload["code"] == "tts_input_closed"
    assert rejected.payload["terminal"] is False
    assert host.terminal is None


def test_finish_requires_the_last_accepted_sequence() -> None:
    session = FakeModelSession()
    host = _host(session)
    host.accept_text(0, "abc")
    (wrong,) = host.finish_input(7)
    assert wrong.payload["code"] == "tts_sequence_invalid"
    assert wrong.payload["terminal"] is False
    assert host.input_state.value == "open"
    assert host.finish_input(0) == ()
    assert host.input_state.value == "closed"
    assert session.finished is True


def test_per_append_limit_ends_the_utterance() -> None:
    limits = TtsStreamLimits(max_append_codepoints=3)
    session = FakeModelSession()
    host = _host(session, limits=limits)
    (failed,) = host.accept_text(0, "abcd")
    assert failed.payload["type"] == FRAME_STREAM_ERROR
    assert failed.payload["code"] == "tts_stream_limit_exceeded"
    assert failed.payload["terminal"] is True
    assert host.terminal is TtsStreamTerminal.FAILED
    assert session.appended == []


def test_audio_frames_carry_monotonic_byte_exact_positions() -> None:
    session = FakeModelSession(
        events=[
            ModelStepEvent(kind="pcm", pcm16=_pcm(100)),
            ModelStepEvent(kind="pcm", pcm16=_pcm(240)),
            ModelStepEvent(kind="finished"),
        ]
    )
    host = _host(session)
    host.accept_text(0, "abc")
    host.finish_input(0)
    first = host.step()
    assert first.frames[0].payload["type"] == FRAME_STREAM_AUDIO
    assert first.frames[0].payload["chunk_index"] == 0
    assert first.frames[0].payload["sample_offset"] == 0
    assert first.frames[0].binary == _pcm(100)
    second = host.step()
    assert second.frames[0].payload["chunk_index"] == 1
    assert second.frames[0].payload["sample_offset"] == 100
    third = host.step()
    assert third.terminal is True
    assert third.frames[0].payload["type"] == FRAME_STREAM_DONE
    assert third.frames[0].payload["terminal"] == "completed"


def test_audio_budget_is_released_only_after_the_writer_confirms_delivery() -> None:
    limits = TtsStreamLimits(max_pending_audio_bytes=6)
    session = FakeModelSession(
        events=[ModelStepEvent(kind="pcm", pcm16=_pcm(3)) for _ in range(4)]
    )
    host = _host(session, limits=limits)

    first = host.step()
    assert first.frames[0].binary == _pcm(3)
    # Nothing is retired yet, so the next chunk already exceeds the budget.
    blocked = host.step()
    assert blocked.terminal is True
    assert blocked.frames[0].payload["code"] == "tts_backpressure"

    other_session = FakeModelSession(
        events=[ModelStepEvent(kind="pcm", pcm16=_pcm(3)) for _ in range(2)]
    )
    retrying = _host(other_session, limits=limits)
    for _ in range(2):
        produced = retrying.step()
        assert produced.frames[0].payload["type"] == FRAME_STREAM_AUDIO
        assert callable(produced.frames[0].on_sent)
        produced.frames[0].on_sent()


class DeliveryPump:
    """Pump stand-in that retires every frame as soon as it is submitted.

    The real ``StreamPump`` runs ``on_sent`` on its writer thread once the frame
    is on the wire; doing it synchronously here keeps the worker forwarding
    contract deterministic.
    """

    def __init__(self) -> None:
        self.frames: list[StreamFrame] = []
        self.at_eof = False
        self.read_error: BaseException | None = None
        self.write_error: BaseException | None = None
        self.cancel_request_id: str | None = None
        self._inbound: list[dict[str, object]] = []

    @property
    def cancel_pending(self) -> bool:
        return False

    def enqueue(self, *frames: dict[str, object]) -> None:
        self._inbound.extend(frames)

    def poll(self, timeout: float | None = None) -> dict[str, object] | None:
        return self._inbound.pop(0) if self._inbound else None

    def submit(self, frame: StreamFrame, *, timeout: float | None = None) -> bool:
        self.frames.append(frame)
        if frame.on_sent is not None:
            frame.on_sent()
        return True

    def acknowledge_cancel(self, request_id: str | None) -> None:
        self.cancel_request_id = None


def test_worker_retires_the_audio_budget_once_frames_are_delivered() -> None:
    limits = TtsStreamLimits(max_pending_audio_bytes=24)
    session = FakeModelSession(
        events=[ModelStepEvent(kind="pcm", pcm16=_pcm(4)) for _ in range(10)]
    )
    host = _host(session, limits=limits)
    host.accept_text(0, "abc")
    host.finish_input(0)

    pump = DeliveryPump()
    _drive_stream(pump, host)  # type: ignore[arg-type]

    audio = [item for item in pump.frames if item.payload["type"] == FRAME_STREAM_AUDIO]
    # Every chunk fits the budget only because delivery retires it again.
    assert [item.payload["chunk_index"] for item in audio] == list(range(10))
    assert [item.payload["sample_offset"] for item in audio] == [
        index * 4 for index in range(10)
    ]
    errors = [item.payload["code"] for item in pump.frames if item.payload.get("code")]
    assert errors == []
    (done,) = [item for item in pump.frames if item.payload["type"] == FRAME_STREAM_DONE]
    assert done.payload["terminal"] == "completed"
    assert host.terminal is TtsStreamTerminal.COMPLETED


def test_invalid_pcm_is_rejected_as_a_backend_failure() -> None:
    session = FakeModelSession(events=[ModelStepEvent(kind="pcm", pcm16=b"\x00")])
    host = _host(session)
    result = host.step()
    assert result.terminal is True
    assert result.frames[0].payload["code"] == "tts_backend_failed"


def test_starved_input_ends_the_utterance_at_the_input_deadline() -> None:
    clock = Clock()
    session = FakeModelSession(events=[ModelStepEvent(kind="waiting_for_text")])
    host = _host(session, clock=clock)
    waiting = host.step()
    assert waiting.waiting_for_text is True
    assert waiting.terminal is False
    assert host.timeout_remaining() == pytest.approx(
        DEFAULT_TTS_STREAM_LIMITS.input_wait_seconds
    )
    clock.advance(DEFAULT_TTS_STREAM_LIMITS.input_wait_seconds)
    session.events.append(ModelStepEvent(kind="waiting_for_text"))
    expired = host.step()
    assert expired.terminal is True
    assert expired.frames[0].payload["code"] == "tts_input_timeout"


def test_utterance_wall_clock_ends_the_utterance() -> None:
    clock = Clock()
    limits = TtsStreamLimits(utterance_wall_clock_seconds=5.0, input_wait_seconds=60.0)
    session = FakeModelSession(events=[ModelStepEvent(kind="waiting_for_text")])
    host = _host(session, limits=limits, clock=clock)
    assert host.step().waiting_for_text is True
    clock.advance(5.0)
    session.events.append(ModelStepEvent(kind="waiting_for_text"))
    expired = host.step()
    assert expired.terminal is True
    assert expired.frames[0].payload["code"] == "tts_stream_limit_exceeded"


def test_waiting_after_the_input_is_closed_fails_closed() -> None:
    session = FakeModelSession(events=[ModelStepEvent(kind="waiting_for_text")])
    host = _host(session)
    host.accept_text(0, "abc")
    host.finish_input(0)
    stalled = host.step()
    assert stalled.terminal is True
    assert stalled.frames[0].payload["code"] == "tts_backend_failed"


def test_unregistered_model_error_codes_normalise_to_backend_failed() -> None:
    session = FakeModelSession(
        events=[ModelStepEvent(kind="error", error_code="codec_eos_before_text_eos")]
    )
    host = _host(session)
    result = host.step()
    assert result.terminal is True
    assert result.frames[0].payload["code"] == "tts_backend_failed"
    assert host.failure_code == "tts_backend_failed"


def test_registered_timeout_code_that_the_model_reports_is_preserved() -> None:
    session = FakeModelSession(
        events=[ModelStepEvent(kind="error", error_code="tts_input_timeout")]
    )
    host = _host(session)
    result = host.step()
    assert result.frames[0].payload["code"] == "tts_input_timeout"


def test_a_raising_model_session_becomes_one_backend_failure() -> None:
    def boom(_max_steps: int) -> None:
        raise RuntimeError("mlx exploded")

    session = FakeModelSession(on_step=boom)
    host = _host(session)
    result = host.step()
    assert result.terminal is True
    assert result.frames[0].payload["code"] == "tts_backend_failed"
    assert host.step().terminal is True
    assert host.step().frames == ()


def test_terminal_outcome_is_emitted_exactly_once() -> None:
    session = FakeModelSession(events=[ModelStepEvent(kind="finished")])
    host = _host(session)
    host.accept_text(0, "abc")
    host.finish_input(0)
    first = host.step()
    assert first.terminal is True
    assert first.frames[0].payload["type"] == FRAME_STREAM_DONE
    second = host.step()
    assert second.terminal is True
    assert second.frames == ()
    assert host.step().frames == ()
    assert session.closed == 1


def test_cancel_is_an_idempotent_single_terminal() -> None:
    session = FakeModelSession()
    host = _host(session)
    (cancelled,) = host.cancel()
    assert cancelled.payload["type"] == FRAME_STREAM_DONE
    assert cancelled.payload["terminal"] == "cancelled"
    assert host.terminal is TtsStreamTerminal.CANCELLED
    assert host.cancel() == ()
    assert session.cancelled == 1
    assert session.closed == 1


def test_expire_is_a_no_op_after_a_terminal_outcome() -> None:
    session = FakeModelSession()
    host = _host(session)
    host.cancel()
    assert host.expire() == ()


def test_close_does_not_emit_a_terminal_frame() -> None:
    session = FakeModelSession()
    host = _host(session)
    host.close()
    assert session.cancelled == 1
    assert session.closed == 1
    assert host.terminal is None


def test_step_uses_the_configured_step_budget() -> None:
    seen: list[int] = []
    session = FakeModelSession(
        events=[ModelStepEvent(kind="waiting_for_text")], on_step=seen.append
    )
    host = _host(session, step_size=7)
    host.step()
    assert seen == [7]
    session.events.append(ModelStepEvent(kind="waiting_for_text"))
    host.step(max_steps=1)
    assert seen == [7, 1]
