from __future__ import annotations

import pytest

from speechrail.domain.tts_stream import (
    DEFAULT_TTS_STREAM_LIMITS,
    TTS_STREAM_ERROR_CODES,
    TtsStreamError,
    TtsStreamEvent,
    TtsStreamEventKind,
    TtsStreamInputState,
    TtsStreamLimits,
    TtsStreamOptions,
    TtsStreamOutputState,
    TtsStreamStateMachine,
    TtsStreamTerminal,
)


def _running(limits: TtsStreamLimits | None = None) -> TtsStreamStateMachine:
    state = TtsStreamStateMachine() if limits is None else TtsStreamStateMachine(limits=limits)
    state.mark_running()
    return state


def _code(state: TtsStreamStateMachine, call, *args, **kwargs) -> str:
    with pytest.raises(TtsStreamError) as failure:
        call(*args, **kwargs)
    assert failure.value.code in TTS_STREAM_ERROR_CODES
    return failure.value.code


def test_default_limits_are_the_documented_conservative_values() -> None:
    limits = DEFAULT_TTS_STREAM_LIMITS

    assert limits.max_append_codepoints == 512
    assert limits.max_total_codepoints == 4096
    assert limits.max_pending_codepoints == 2048
    assert limits.max_pending_audio_bytes == 48_000
    assert limits.input_wait_seconds == 15.0
    assert limits.utterance_wall_clock_seconds == 120.0
    assert limits.slow_consumer_seconds == 2.0


def test_limits_reject_bools_non_integers_and_impossible_orderings() -> None:
    with pytest.raises(ValueError):
        TtsStreamLimits(max_append_codepoints=True)  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        TtsStreamLimits(max_total_codepoints=0)
    with pytest.raises(ValueError):
        TtsStreamLimits(max_pending_audio_bytes=1.5)  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        TtsStreamLimits(input_wait_seconds=float("inf"))
    with pytest.raises(ValueError):
        TtsStreamLimits(max_append_codepoints=4097, max_total_codepoints=4096)
    with pytest.raises(ValueError):
        TtsStreamLimits(max_pending_codepoints=4097)


def test_options_require_identity_and_finite_speed() -> None:
    options = TtsStreamOptions(request_id="r1", response_id="resp_1", voice="serena", speed=1.0)

    assert options.language == "auto"
    assert options.expected_voice_revision is None
    with pytest.raises(ValueError):
        TtsStreamOptions(request_id="", response_id="resp_1", voice="serena")
    with pytest.raises(ValueError):
        TtsStreamOptions(request_id="r1", response_id="resp_1", voice="  ")
    with pytest.raises(ValueError):
        TtsStreamOptions(request_id="r1", response_id="resp_1", voice="serena", speed=float("nan"))
    with pytest.raises(ValueError):
        TtsStreamOptions(request_id="r1", response_id="resp_1", voice="serena", speed=True)  # type: ignore[arg-type]


def test_append_sequences_must_start_at_zero_and_stay_contiguous() -> None:
    state = _running()

    assert state.accepted_sequence == -1
    assert _code(state, state.accept_append, 1, "你好") == "tts_sequence_invalid"
    assert state.accepted_sequence == -1

    assert state.accept_append(0, "你好") == 2
    assert state.accepted_sequence == 0

    assert _code(state, state.accept_append, 0, "你好") == "tts_sequence_invalid"
    assert state.accepted_sequence == 0
    assert _code(state, state.accept_append, 2, "继续") == "tts_sequence_invalid"
    assert state.accepted_sequence == 0

    state.accept_append(1, "继续")
    assert state.accepted_sequence == 1


def test_non_integer_sequence_is_rejected_by_the_stream_not_the_parser() -> None:
    state = _running()

    assert _code(state, state.accept_append, True, "你好") == "tts_sequence_invalid"
    assert _code(state, state.accept_finish, "0") == "tts_sequence_invalid"  # type: ignore[arg-type]


def test_finish_requires_the_exact_last_accepted_sequence_and_closes_once() -> None:
    state = _running()
    state.accept_append(0, "你好")

    assert _code(state, state.accept_finish, -1) == "tts_sequence_invalid"
    assert state.input_state is TtsStreamInputState.OPEN

    state.accept_finish(0)
    assert state.input_state is TtsStreamInputState.CLOSED
    assert state.output_state is TtsStreamOutputState.DRAINING

    assert _code(state, state.accept_finish, 0) == "tts_input_closed"
    assert _code(state, state.accept_append, 1, "继续") == "tts_input_closed"
    assert state.accepted_sequence == 0


def test_finish_without_any_append_completes_a_zero_audio_utterance() -> None:
    state = _running()

    state.accept_finish(-1)

    assert state.complete() is TtsStreamTerminal.COMPLETED
    event = state.terminal_event("resp_1")
    assert event.kind is TtsStreamEventKind.COMPLETED
    assert event.pcm16 == b""


def test_codepoint_limits_count_whitespace_and_are_separate_from_bytes() -> None:
    limits = TtsStreamLimits(
        max_append_codepoints=4,
        max_total_codepoints=6,
        max_pending_codepoints=5,
        max_pending_audio_bytes=8,
    )
    state = _running(limits)

    assert state.accept_append(0, "  ") == 2
    assert state.total_codepoints == 2
    assert _code(state, state.accept_append, 1, "你好吗啊呀") == "tts_stream_limit_exceeded"
    assert state.total_codepoints == 2

    assert state.accept_append(1, "你好") == 2
    assert state.total_codepoints == 4
    state.mark_text_consumed(4)
    assert state.accept_append(2, "你好") == 2
    assert state.total_codepoints == 6
    assert _code(state, state.accept_append, 3, "你") == "tts_stream_limit_exceeded"
    assert state.total_codepoints == 6

    position = state.enqueue_audio(8)
    assert position.chunk_index == 0
    assert state.pending_audio_bytes == 8
    assert _code(state, state.enqueue_audio, 2) == "tts_backpressure"


def test_pending_text_backpressure_and_consumption() -> None:
    limits = TtsStreamLimits(max_pending_codepoints=3)
    state = _running(limits)

    state.accept_append(0, "你")
    assert state.pending_codepoints == 1
    assert _code(state, state.accept_append, 1, "你好吗") == "tts_backpressure"
    assert state.accepted_sequence == 0
    assert state.pending_codepoints == 1

    state.mark_text_consumed(1)
    assert state.pending_codepoints == 0
    assert state.accept_append(1, "你好") == 2
    with pytest.raises(ValueError):
        state.mark_text_consumed(3)


def test_audio_positions_are_monotonic_and_free_the_byte_budget() -> None:
    limits = TtsStreamLimits(max_pending_audio_bytes=6)
    state = _running(limits)

    first = state.enqueue_audio(4)
    assert (first.chunk_index, first.sample_offset, first.byte_length) == (0, 0, 4)
    assert _code(state, state.enqueue_audio, 4) == "tts_backpressure"

    state.dequeue_audio(4)
    second = state.enqueue_audio(6)
    assert (second.chunk_index, second.sample_offset) == (1, 2)

    with pytest.raises(ValueError):
        state.enqueue_audio(3)
    with pytest.raises(ValueError):
        state.dequeue_audio(7)


def test_completion_requires_a_closed_input_and_happens_once() -> None:
    state = _running()
    state.accept_append(0, "你好")

    assert _code(state, state.complete) == "tts_input_closed"
    assert state.terminal is None

    state.accept_finish(0)
    assert state.complete() is TtsStreamTerminal.COMPLETED
    assert state.output_state is TtsStreamOutputState.TERMINAL
    assert _code(state, state.complete) == "tts_input_closed"
    assert _code(state, state.accept_append, 1, "继续") == "tts_input_closed"


def test_cancel_is_idempotent_and_outranks_a_later_failure() -> None:
    state = _running()
    state.accept_append(0, "你好")
    state.enqueue_audio(4)

    assert state.cancel() is TtsStreamTerminal.CANCELLED
    assert state.cancel() is TtsStreamTerminal.CANCELLED
    assert state.terminal is TtsStreamTerminal.CANCELLED
    assert state.pending_audio_bytes == 0
    assert state.terminal_event("resp_1").kind is TtsStreamEventKind.CANCELLED
    assert _code(state, state.fail, "tts_backpressure") == "tts_input_closed"


def test_failure_requires_a_registered_code_and_is_terminal_once() -> None:
    state = _running()

    with pytest.raises(ValueError):
        state.fail("tts_unknown_code")
    assert state.terminal is None

    assert state.fail("tts_input_timeout") is TtsStreamTerminal.FAILED
    assert state.input_state is TtsStreamInputState.CLOSED
    event = state.terminal_event("resp_1", error_code="tts_input_timeout")
    assert event.kind is TtsStreamEventKind.FAILED
    assert event.error_code == "tts_input_timeout"
    with pytest.raises(ValueError):
        state.terminal_event("resp_1")


def test_started_and_audio_events_enforce_their_invariants() -> None:
    started = TtsStreamEvent(kind=TtsStreamEventKind.STARTED, response_id="resp_1")
    assert started.terminal is None

    audio = TtsStreamEvent(
        kind=TtsStreamEventKind.AUDIO,
        response_id="resp_1",
        pcm16=b"\x00\x00",
        chunk_index=0,
        sample_offset=0,
    )
    assert audio.pcm16 == b"\x00\x00"

    with pytest.raises(ValueError):
        TtsStreamEvent(kind=TtsStreamEventKind.AUDIO, response_id="resp_1")
    with pytest.raises(ValueError):
        TtsStreamEvent(
            kind=TtsStreamEventKind.AUDIO,
            response_id="resp_1",
            pcm16=b"\x00",
            chunk_index=0,
            sample_offset=0,
        )
    with pytest.raises(ValueError):
        TtsStreamEvent(
            kind=TtsStreamEventKind.TEXT_ACCEPTED,
            response_id="resp_1",
            sequence=0,
            pcm16=b"\x00\x00",
        )
    with pytest.raises(ValueError):
        TtsStreamEvent(kind=TtsStreamEventKind.FAILED, response_id="resp_1", error_code="nope")
    with pytest.raises(ValueError):
        TtsStreamEvent(kind=TtsStreamEventKind.COMPLETED, response_id="resp_1")


def test_running_state_requires_the_starting_state() -> None:
    state = TtsStreamStateMachine()

    assert state.output_state is TtsStreamOutputState.STARTING
    state.mark_running()
    assert state.output_state is TtsStreamOutputState.RUNNING
    assert _code(state, state.mark_running) == "tts_input_closed"
