"""Deterministic contract tests for the incremental TTS latency benchmark."""

from __future__ import annotations

import base64
import sys
import threading
import time
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf.bench_tts_streaming import (
    StreamingTurnTrace,
    _append_schedule,
    _recv,
    percentile,
    run_incremental_turn,
    summarise,
)

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.model_spec import required_spec_artifact
from test_realtime_tts_incremental import FakeIncrementalSynthesizer

_STARTED = {
    "type": "speechrail.tts.started",
    "output_format": {"type": "pcm16", "sample_rate": 24_000, "channels": 1},
    "limits": {"max_append_codepoints": 240},
}


class FakeClock:
    """A monotonic clock that only moves when the test moves it."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds

    def sleep(self, seconds: float) -> None:
        self.now += seconds


class FakeConnection:
    """Scripted realtime connection that refuses out-of-order protocol use."""

    def __init__(self, script: list[dict[str, Any]], clock: FakeClock) -> None:
        self.sent: list[dict[str, Any]] = []
        self.sent_at: list[float] = []
        self.started = False
        self._script = list(script)
        self._clock = clock

    def send(self, event: dict[str, Any]) -> None:
        kind = event["type"]
        if kind == "speechrail.tts.append_text" and not self.started:
            raise AssertionError("append_text was sent before speechrail.tts.started")
        if kind == "speechrail.tts.finish_text" and not self.started:
            raise AssertionError("finish_text was sent before speechrail.tts.started")
        self.sent.append(event)
        self.sent_at.append(self._clock())

    def recv(self) -> dict[str, Any]:
        if not self._script:
            raise AssertionError("the benchmark read past the end of the fake script")
        event = self._script.pop(0)
        advance = getattr(self._clock, "advance", None)
        if callable(advance):
            advance(0.001)
        if event["type"] == "speechrail.tts.started":
            self.started = True
        return event

    def of_type(self, kind: str) -> list[dict[str, Any]]:
        return [event for event in self.sent if event["type"] == kind]


class AckAwareConnection(FakeConnection):
    """Reject a next append sent before the previous append's matching ACK."""

    def __init__(self, script: list[dict[str, Any]], clock: Any) -> None:
        super().__init__(script, clock)
        self.acknowledged_sequences: set[int] = set()

    def send(self, event: dict[str, Any]) -> None:
        if event.get("type") == "speechrail.tts.append_text":
            sequence = event.get("sequence")
            if (
                isinstance(sequence, int)
                and sequence > 0
                and sequence - 1 not in self.acknowledged_sequences
            ):
                raise AssertionError(
                    f"append {sequence} was sent before ACK {sequence - 1}"
                )
        super().send(event)

    def recv(self) -> dict[str, Any]:
        event = super().recv()
        if event.get("type") == "speechrail.tts.text_accepted":
            sequence = event.get("append_sequence")
            if isinstance(sequence, int) and not isinstance(sequence, bool):
                self.acknowledged_sequences.add(sequence)
        return event


class _WebSocketBenchmarkAdapter:
    """Adapt a test websocket to the benchmark's ``send`` / ``recv`` seam."""

    def __init__(self, session: Any) -> None:
        self._session = session

    def send(self, event: dict[str, Any]) -> None:
        self._session.send_json(event)

    def recv(self) -> dict[str, Any]:
        return self._session.receive_json()


def _audio_delta(payload: bytes) -> dict[str, Any]:
    return {
        "type": "speechrail.tts.audio.delta",
        "delta": base64.b64encode(payload).decode("ascii"),
    }


def _selection_kwargs(tier: str = "quality") -> dict[str, Any]:
    asr_key = required_spec_artifact(tier, "asr")
    tts_key = required_spec_artifact(tier, "tts_custom_voice")
    base_key = required_spec_artifact(tier, "tts_base")
    assert asr_key is not None and tts_key is not None and base_key is not None
    return {
        "qwen3_model_dir": Path(asr_key),
        "qwen3_tts_model_dir": Path(tts_key),
        "qwen3_tts_clone_model_dir": Path(base_key),
        "selection_schema_version": 2,
        "selection_asr_spec": tier,
        "selection_tts_spec": tier,
        "asr_artifact_key": asr_key,
        "tts_artifact_key": tts_key,
        "tts_base_artifact_key": base_key,
    }


def _handshake() -> list[dict[str, Any]]:
    return [
        {"type": "session.created"},
        {"type": "session.updated"},
    ]


def _turn(
    script: list[dict[str, Any]],
    *,
    text: str = "增量朗读",
    slices: int = 2,
    voice: str | None = None,
    append_interval_seconds: float = 0.0,
) -> tuple[StreamingTurnTrace, FakeConnection]:
    clock = FakeClock()
    connection = FakeConnection(script, clock)
    trace = run_incremental_turn(
        connection,
        text=text,
        voice=voice,
        slices=slices,
        append_interval_seconds=append_interval_seconds,
        clock=clock,
        sleep=clock.sleep,
    )
    return trace, connection


def test_append_schedule_splits_text_into_the_requested_slices() -> None:
    assert _append_schedule("abcdef", 3) == ["ab", "cd", "ef"]
    assert _append_schedule("abcde", 3) == ["ab", "cd", "e"]
    assert _append_schedule("whole reply", 1) == ["whole reply"]
    # More slices than codepoints degrades to one codepoint per slice.
    assert _append_schedule("ab", 5) == ["a", "b"]


def test_recv_normalizes_typed_sdk_events() -> None:
    class TypedEvent:
        def model_dump(self, *, mode: str) -> dict[str, Any]:
            assert mode == "json"
            return {"type": "speechrail.tts.started"}

    class Connection:
        def recv(self) -> TypedEvent:
            return TypedEvent()

    assert _recv(Connection(), deadline=1.0, clock=lambda: 0.0) == {
        "type": "speechrail.tts.started"
    }


def test_append_schedule_respects_the_server_append_budget() -> None:
    pieces = _append_schedule("x" * 25, 2, max_codepoints=10)
    assert len(pieces) == 3
    assert [len(piece) for piece in pieces] == [9, 8, 8]


@pytest.mark.parametrize(
    ("text", "slices"),
    [("", 1), ("abc", 0), ("abc", -1)],
)
def test_append_schedule_rejects_unusable_arguments(text: str, slices: int) -> None:
    with pytest.raises(ValueError):
        _append_schedule(text, slices)


def test_append_schedule_rejects_non_positive_append_budget() -> None:
    with pytest.raises(ValueError):
        _append_schedule("abc", 1, max_codepoints=0)


def test_percentile_is_empty_safe_and_nearest_rank() -> None:
    assert percentile([], 0.5) is None
    assert percentile([7.0], 0.95) == 7.0
    assert percentile([1.0, 2.0, 3.0, 4.0], 0.0) == 1.0
    assert percentile([1.0, 2.0, 3.0, 4.0], 0.5) == 3.0
    assert percentile([1.0, 2.0, 3.0, 4.0], 0.95) == 4.0
    # An even sample rounds up, so p50 is never the optimistic side.
    assert percentile([400.0, 600.0], 0.5) == 600.0
    assert percentile([4.0, 1.0, 3.0, 2.0], 1.0) == 4.0


def test_trace_reports_first_pcm_and_generation_rtf() -> None:
    trace = StreamingTurnTrace(
        submitted_at=1.0,
        started_at=1.05,
        first_stable_text_at=1.1,
        first_audio_at=1.3,
        finish_sent_at=2.0,
        terminal_at=4.3,
        audio_bytes=48_000,
        text_gap_seconds=0.5,
        terminal_status="completed",
    )
    assert trace.start_to_started_seconds == pytest.approx(0.05)
    assert trace.first_pcm_seconds == pytest.approx(0.2)
    assert trace.append_to_first_pcm_seconds == pytest.approx(0.2)
    assert trace.audio_seconds == pytest.approx(1.0)
    assert trace.generation_seconds == pytest.approx(3.2)
    assert trace.generation_rtf == pytest.approx(3.2)
    assert trace.first_pcm_before_finish is True


def test_trace_without_audio_publishes_no_ratio() -> None:
    trace = StreamingTurnTrace(
        submitted_at=1.0,
        first_audio_at=None,
        terminal_at=2.0,
        audio_bytes=0,
        terminal_status="completed",
    )
    assert trace.append_to_first_pcm_seconds is None
    assert trace.generation_rtf is None
    assert trace.first_pcm_before_finish is None


def test_playback_headroom_reports_the_worst_supply_gap() -> None:
    # 80 ms per chunk at 24 kHz PCM16 = 3840 bytes.
    chunk = 3840
    headroom = StreamingTurnTrace(
        submitted_at=0.0,
        first_audio_at=1.0,
        terminal_at=2.0,
        audio_bytes=chunk * 2,
        audio_arrivals=((1.0, chunk), (1.10, chunk * 2)),
        terminal_status="completed",
    )
    # The second packet is not counted before the underrun check: the caller
    # had only the first 80 ms of audio when the 100 ms gap elapsed.
    assert headroom.playback_headroom_seconds == pytest.approx(-0.020)

    steady = StreamingTurnTrace(
        submitted_at=0.0,
        first_audio_at=1.0,
        terminal_at=2.0,
        audio_bytes=chunk * 3,
        audio_arrivals=((1.0, chunk), (1.05, chunk * 2), (1.10, chunk * 3)),
        terminal_status="completed",
    )
    assert steady.playback_headroom_seconds == pytest.approx(0.030)


def test_playback_headroom_needs_at_least_two_arrivals() -> None:
    single = StreamingTurnTrace(
        submitted_at=0.0,
        first_audio_at=1.0,
        terminal_at=1.5,
        audio_bytes=3840,
        audio_arrivals=((1.0, 3840),),
        terminal_status="completed",
    )
    assert single.playback_headroom_seconds is None
    assert summarise([single]).playback_headroom_ms_p50 is None


def test_summarise_counts_underrun_turns_separately() -> None:
    # A starved turn: the second chunk lands after the first would have run out.
    starved = StreamingTurnTrace(
        submitted_at=0.0,
        first_audio_at=1.0,
        terminal_at=2.0,
        audio_bytes=3840 * 2,
        audio_arrivals=((1.0, 3840), (1.20, 3840 * 2)),
        terminal_status="completed",
    )
    healthy = StreamingTurnTrace(
        submitted_at=0.0,
        first_audio_at=1.0,
        terminal_at=2.0,
        audio_bytes=3840 * 2,
        audio_arrivals=((1.0, 3840), (1.04, 3840 * 2)),
        terminal_status="completed",
    )

    summary = summarise([starved, healthy])
    assert summary.underrun_turns == 1
    # The nearest-rank rule reports the optimistic side of a two-sample run, so
    # the starved turn is visible through the counter rather than the percentile.
    assert summary.playback_headroom_ms_p50 == pytest.approx(40.0)
    payload = summary.as_dict()
    assert payload["underrun_turns"] == 1
    assert payload["playback_headroom_ms"]["p50"] == summary.playback_headroom_ms_p50


def test_streaming_report_schema_marks_the_corrected_measurement_strategy() -> None:
    """The corrected anchors are not comparable with the older ``/1`` summaries."""

    assert summarise([]).as_dict()["schema"] == "speechrail-perf/tts-streaming/2"


def test_summarise_counts_incomplete_turns_without_averaging_them_in() -> None:
    complete = StreamingTurnTrace(
        submitted_at=0.0,
        first_stable_text_at=0.0,
        first_audio_at=0.4,
        terminal_at=2.4,
        audio_bytes=48_000,
        terminal_status="completed",
    )
    # A stream that produced audio and then failed is a failure, not a
    # successful sample whose latency can be averaged into the healthy run.
    second = StreamingTurnTrace(
        submitted_at=0.0,
        first_stable_text_at=0.0,
        first_audio_at=0.6,
        terminal_at=2.6,
        audio_bytes=48_000,
        failure="tts_backpressure",
        terminal_status="failed",
    )
    failed = StreamingTurnTrace(
        submitted_at=0.0,
        first_audio_at=None,
        terminal_at=0.0,
        audio_bytes=0,
        terminal_status="failed",
    )

    summary = summarise([complete, second, failed])
    assert summary.total_turns == 3
    assert summary.samples == 1
    assert summary.completed_turns == 1
    assert summary.failed_turns == 2
    assert summary.append_to_first_pcm_ms_p50 == pytest.approx(400.0)
    assert summary.append_to_first_pcm_ms_p95 == pytest.approx(400.0)
    assert summary.generation_rtf_p50 == pytest.approx(2.4)
    assert summary.failures == ("tts_backpressure",)

    payload = summary.as_dict()
    assert payload["total_turns"] == 3
    assert payload["samples"] == 1
    assert payload["failed_turns"] == 2
    assert payload["failures"] == ["tts_backpressure"]


def test_summarise_reports_no_timings_for_an_empty_run() -> None:
    summary = summarise([])
    assert summary.samples == 0
    assert summary.append_to_first_pcm_ms_p50 is None
    assert summary.generation_rtf_p95 is None
    assert summary.text_gap_ms_p50 is None


def test_run_incremental_turn_follows_the_incremental_protocol() -> None:
    script = [
        *_handshake(),
        _STARTED,
        {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
        {"type": "speechrail.tts.text_accepted", "append_sequence": 1},
        _audio_delta(b"\x01\x02" * 24_000),
        {"type": "speechrail.tts.completed"},
    ]
    trace, connection = _turn(script, text="你好，世界", slices=2)

    assert [event["type"] for event in connection.sent] == [
        "session.update",
        "speechrail.tts.start",
        "speechrail.tts.append_text",
        "speechrail.tts.append_text",
        "speechrail.tts.finish_text",
    ]
    start = connection.sent[1]
    assert start["voice"] == "serena"
    assert start["task"] == "conversation"
    appends = connection.of_type("speechrail.tts.append_text")
    assert [event["sequence"] for event in appends] == [0, 1]
    assert "".join(event["text"] for event in appends) == "你好，世界"
    assert connection.of_type("speechrail.tts.finish_text")[0]["last_sequence"] == 1

    assert trace.audio_bytes == 48_000
    assert trace.audio_seconds == pytest.approx(1.0)
    assert trace.first_audio_at is not None
    assert trace.text_gap_seconds == 0.0
    assert trace.failure is None


def test_run_incremental_turn_pins_the_requested_voice() -> None:
    script = [
        *_handshake(),
        _STARTED,
        {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
        _audio_delta(b"\x00\x00" * 24_000),
        {"type": "speechrail.tts.completed"},
    ]
    _, connection = _turn(script, text="单段", slices=1, voice="serena")

    assert connection.sent[1]["voice"] == "serena"


def test_run_incremental_turn_adopts_the_sample_rate_reported_on_the_wire() -> None:
    script = [
        *_handshake(),
        {
            **_STARTED,
            "output_format": {"type": "pcm16", "sample_rate": 48_000, "channels": 1},
        },
        {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
        _audio_delta(b"\x00\x00" * 24_000),
        {"type": "speechrail.tts.completed"},
    ]
    trace, _ = _turn(script, text="单段", slices=1)

    assert trace.sample_rate == 48_000
    assert trace.audio_seconds == pytest.approx(0.5)


def test_run_incremental_turn_reports_a_gap_that_ended_before_first_audio() -> None:
    script = [
        *_handshake(),
        _STARTED,
        {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
        {"type": "speechrail.tts.text_accepted", "append_sequence": 1},
        _audio_delta(b"\x00\x00" * 24_000),
        {"type": "speechrail.tts.completed"},
    ]
    trace, _ = _turn(script, text="两段文本", slices=2, append_interval_seconds=0.5)

    assert trace.first_audio_at is not None
    assert trace.text_gap_seconds == pytest.approx(0.5)
    assert trace.generation_rtf is not None


def test_run_incremental_turn_does_not_hide_a_client_gap_in_generation_rtf() -> None:
    script = [
        *_handshake(),
        _STARTED,
        _audio_delta(b"\x00\x00" * 24_000),
        {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
        {"type": "speechrail.tts.text_accepted", "append_sequence": 1},
        {"type": "speechrail.tts.completed"},
    ]
    trace, _ = _turn(script, text="两段文本", slices=2, append_interval_seconds=0.5)

    assert trace.text_gap_seconds == pytest.approx(0.5)
    assert trace.generation_seconds is not None
    assert trace.generation_seconds >= trace.text_gap_seconds


def test_run_incremental_turn_waits_for_the_matching_ack_not_any_packet() -> None:
    """Audio must not open the next append window; only its own ACK does."""

    clock = FakeClock()
    connection = AckAwareConnection(
        [
            *_handshake(),
            _STARTED,
            {"type": "speechrail.tts.audio.delta", "delta": ""},
            {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
            {"type": "speechrail.tts.text_accepted", "append_sequence": 1},
            {"type": "speechrail.tts.completed"},
        ],
        clock,
    )

    trace = run_incremental_turn(
        connection,
        text="两段文本",
        slices=2,
        clock=clock,
        sleep=clock.sleep,
    )

    assert [event["sequence"] for event in connection.of_type("speechrail.tts.append_text")] == [
        0,
        1,
    ]
    assert trace.terminal_status == "completed"


def test_run_incremental_turn_rejects_a_mismatched_ack_sequence() -> None:
    script = [
        *_handshake(),
        _STARTED,
        {"type": "speechrail.tts.text_accepted", "append_sequence": 1},
        {"type": "speechrail.tts.completed"},
    ]

    with pytest.raises(ValueError, match="did not match"):
        _turn(script, text="一段", slices=1)


def test_interval_sleep_does_not_block_audio_receive() -> None:
    script = [
        *_handshake(),
        _STARTED,
        {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
        _audio_delta(b"\x00\x00" * 240),
        {"type": "speechrail.tts.text_accepted", "append_sequence": 1},
        {"type": "speechrail.tts.completed"},
    ]
    connection = AckAwareConnection(script, time.monotonic)

    trace = run_incremental_turn(
        connection,
        text="两段文本",
        slices=2,
        append_interval_seconds=0.05,
        clock=time.monotonic,
        sleep=time.sleep,
    )

    second_append_index = next(
        index
        for index, event in enumerate(connection.sent)
        if event.get("type") == "speechrail.tts.append_text" and event.get("sequence") == 1
    )
    assert trace.first_audio_at is not None
    assert trace.first_audio_at < connection.sent_at[second_append_index]


def test_receive_interrupts_a_transport_that_never_returns_an_event() -> None:
    class BlockingConnection:
        def __init__(self) -> None:
            self.closed = threading.Event()

        def recv(self) -> dict[str, Any]:
            self.closed.wait(timeout=2.0)
            raise TimeoutError("interrupted")

        def close(self) -> None:
            self.closed.set()

    connection = BlockingConnection()
    with pytest.raises(TimeoutError, match="benchmark timed out"):
        _recv(
            connection,
            deadline=time.monotonic() + 0.01,
            clock=time.monotonic,
        )
    assert connection.closed.is_set()


def test_run_incremental_turn_surfaces_a_pre_created_failure() -> None:
    clock = FakeClock()
    connection = FakeConnection(
        [
            {"type": "session.created"},
            {"type": "session.updated"},
            {"type": "error", "error": {"code": "tts_in_progress"}},
        ],
        clock,
    )

    with pytest.raises(RuntimeError, match="tts_in_progress"):
        run_incremental_turn(connection, text="增量", clock=clock, sleep=clock.sleep)


def test_run_incremental_turn_records_a_terminal_failure_without_audio() -> None:
    script = [
        *_handshake(),
        _STARTED,
        {"type": "error", "error": {"code": "tts_backpressure"}},
        {"type": "speechrail.tts.failed", "error": {"code": "tts_backpressure"}},
    ]
    trace, _ = _turn(script, text="增量", slices=1)

    assert trace.first_audio_at is None
    assert trace.failure == "tts_backpressure"
    assert summarise([trace]).failed_turns == 1


def test_run_incremental_turn_rejects_truncated_audio() -> None:
    script = [
        *_handshake(),
        _STARTED,
        {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
        _audio_delta(b"\x01\x02\x03"),
        {"type": "speechrail.tts.completed"},
    ]

    with pytest.raises(ValueError, match="truncated"):
        _turn(script, text="增量", slices=1)


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"append_interval_seconds": -0.1}, "append_interval_seconds"),
        ({"timeout_seconds": 0.0}, "timeout_seconds"),
    ],
)
def test_run_incremental_turn_rejects_unusable_arguments(
    kwargs: dict[str, float], message: str
) -> None:
    clock = FakeClock()
    connection = FakeConnection([], clock)

    with pytest.raises(ValueError, match=message):
        run_incremental_turn(connection, text="增量", clock=clock, sleep=clock.sleep, **kwargs)


def test_run_incremental_turn_drives_the_real_realtime_server() -> None:
    """The probe must speak the protocol the server actually implements.

    This runs the real ``create_app`` Realtime translation layer, the real
    admission and the real ``StreamController`` against a vendor-neutral fake
    synthesizer, so a drifting probe cannot pass on scripted events alone.
    """

    synthesizer = FakeIncrementalSynthesizer(audio_chunks=(b"\x01\x02" * 12_000,))
    client = TestClient(
        create_app(Settings(**_selection_kwargs("quality")), tts_synthesizer=synthesizer)
    )

    with client.websocket_connect("/v1/realtime") as socket:
        trace = run_incremental_turn(
            _WebSocketBenchmarkAdapter(socket),
            text="你好，这是增量朗读的延迟测量。",
            slices=2,
            timeout_seconds=30.0,
        )

    assert trace.failure is None
    assert trace.first_audio_at is not None
    assert trace.append_to_first_pcm_seconds is not None
    assert trace.audio_bytes == 24_000
    assert trace.audio_seconds == pytest.approx(0.5)

    session = synthesizer.sessions[0]
    assert synthesizer.open_calls == 1
    assert [sequence for sequence, _ in session.appended] == [0, 1]
    assert "".join(piece for _, piece in session.appended) == "你好，这是增量朗读的延迟测量。"
    assert session.finished == 1
