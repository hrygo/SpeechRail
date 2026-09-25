"""Deterministic contract tests for the incremental TTS latency benchmark."""

from __future__ import annotations

import base64
import sys
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf.bench_tts_streaming import (
    StreamingTurnTrace,
    _append_schedule,
    percentile,
    run_incremental_turn,
    summarise,
)

from speechrail.app import create_app
from speechrail.config import Settings
from test_realtime_tts_incremental import FakeIncrementalSynthesizer, _preset_kwargs

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

    def recv(self) -> dict[str, Any]:
        if not self._script:
            raise AssertionError("the benchmark read past the end of the fake script")
        event = self._script.pop(0)
        self._clock.advance(0.001)
        if event["type"] == "speechrail.tts.started":
            self.started = True
        return event

    def of_type(self, kind: str) -> list[dict[str, Any]]:
        return [event for event in self.sent if event["type"] == kind]


class _WebSocketBenchmarkAdapter:
    """Adapt a test websocket to the benchmark's ``send`` / ``recv`` seam."""

    def __init__(self, session: Any) -> None:
        self._session = session

    def send(self, event: dict[str, Any]) -> None:
        self._session.send_json(event)

    def recv(self) -> dict[str, Any]:
        return self._session.receive_json()


def _audio_delta(payload: bytes, *, sample_rate: int = 24_000) -> dict[str, Any]:
    return {
        "type": "response.output_audio.delta",
        "delta": base64.b64encode(payload).decode("ascii"),
        "speechrail": {"kind": "tts", "sample_rate": sample_rate},
    }


def _handshake() -> list[dict[str, Any]]:
    return [
        {"type": "session.created"},
        {"type": "transcription_session.updated"},
        {"type": "response.created"},
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
        first_audio_at=1.3,
        terminal_at=4.3,
        audio_bytes=48_000,
        text_gap_seconds=0.5,
    )
    assert trace.append_to_first_pcm_seconds == pytest.approx(0.3)
    assert trace.audio_seconds == pytest.approx(1.0)
    assert trace.generation_seconds == pytest.approx(2.5)
    assert trace.generation_rtf == pytest.approx(2.5)


def test_trace_without_audio_publishes_no_ratio() -> None:
    trace = StreamingTurnTrace(
        submitted_at=1.0, first_audio_at=None, terminal_at=2.0, audio_bytes=0
    )
    assert trace.append_to_first_pcm_seconds is None
    assert trace.generation_rtf is None


def test_summarise_counts_incomplete_turns_without_averaging_them_in() -> None:
    complete = StreamingTurnTrace(
        submitted_at=0.0, first_audio_at=0.4, terminal_at=2.4, audio_bytes=48_000
    )
    second = StreamingTurnTrace(
        submitted_at=0.0,
        first_audio_at=0.6,
        terminal_at=2.6,
        audio_bytes=48_000,
        failure="tts_backpressure",
    )
    failed = StreamingTurnTrace(
        submitted_at=0.0, first_audio_at=None, terminal_at=0.0, audio_bytes=0
    )

    summary = summarise([complete, second, failed])
    assert summary.samples == 2
    assert summary.completed_turns == 2
    assert summary.failed_turns == 1
    assert summary.append_to_first_pcm_ms_p50 == pytest.approx(600.0)
    assert summary.append_to_first_pcm_ms_p95 == pytest.approx(600.0)
    assert summary.generation_rtf_p50 == pytest.approx(2.0)
    assert summary.failures == ("tts_backpressure",)

    payload = summary.as_dict()
    assert payload["samples"] == 2
    assert payload["failed_turns"] == 1
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
        {"type": "response.output_audio_transcript.delta", "delta": "增量"},
        {"type": "speechrail.tts.text_accepted", "append_sequence": 1},
        _audio_delta(b"\x01\x02" * 24_000),
        {"type": "response.output_audio.done"},
        {"type": "response.done", "response": {"status": "completed"}},
    ]
    trace, connection = _turn(script, text="你好，世界", slices=2)

    assert [event["type"] for event in connection.sent] == [
        "transcription_session.update",
        "speechrail.tts.start",
        "speechrail.tts.append_text",
        "speechrail.tts.append_text",
        "speechrail.tts.finish_text",
    ]
    start = connection.sent[1]
    assert "voice" not in start
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
        {"type": "response.done", "response": {"status": "completed"}},
    ]
    _, connection = _turn(script, text="单段", slices=1, voice="serena")

    assert connection.sent[1]["voice"] == "serena"


def test_run_incremental_turn_adopts_the_sample_rate_reported_on_the_wire() -> None:
    script = [
        *_handshake(),
        _STARTED,
        {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
        _audio_delta(b"\x00\x00" * 24_000, sample_rate=48_000),
        {"type": "response.done", "response": {"status": "completed"}},
    ]
    trace, _ = _turn(script, text="单段", slices=1)

    assert trace.sample_rate == 48_000
    assert trace.audio_seconds == pytest.approx(0.5)


def test_run_incremental_turn_excludes_a_gap_that_ended_before_first_audio() -> None:
    script = [
        *_handshake(),
        _STARTED,
        {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
        {"type": "speechrail.tts.text_accepted", "append_sequence": 1},
        _audio_delta(b"\x00\x00" * 24_000),
        {"type": "response.done", "response": {"status": "completed"}},
    ]
    trace, _ = _turn(script, text="两段文本", slices=2, append_interval_seconds=0.5)

    assert trace.first_audio_at is not None
    assert trace.text_gap_seconds == 0.0
    assert trace.generation_rtf is not None


def test_run_incremental_turn_subtracts_a_gap_that_overlaps_generation() -> None:
    script = [
        *_handshake(),
        _STARTED,
        _audio_delta(b"\x00\x00" * 24_000),
        {"type": "speechrail.tts.text_accepted", "append_sequence": 0},
        {"type": "speechrail.tts.text_accepted", "append_sequence": 1},
        {"type": "response.done", "response": {"status": "completed"}},
    ]
    trace, _ = _turn(script, text="两段文本", slices=2, append_interval_seconds=0.5)

    assert trace.text_gap_seconds == pytest.approx(0.5)
    assert trace.generation_seconds is not None
    assert trace.generation_seconds >= 0.0


def test_run_incremental_turn_surfaces_a_pre_created_failure() -> None:
    clock = FakeClock()
    connection = FakeConnection(
        [
            {"type": "session.created"},
            {"type": "transcription_session.updated"},
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
        {"type": "response.done", "response": {"status": "failed"}},
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
        {"type": "response.done", "response": {"status": "completed"}},
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
        create_app(Settings(**_preset_kwargs("balanced")), tts_synthesizer=synthesizer)
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
    assert [sequence for sequence, _ in session.appended] == [0, 1]
    assert "".join(piece for _, piece in session.appended) == "你好，这是增量朗读的延迟测量。"
    assert session.finished == 1
