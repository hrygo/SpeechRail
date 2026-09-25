"""Deterministic contract tests for the incremental TTS cancel/soak benchmark."""

from __future__ import annotations

import sys
import urllib.request
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf.bench_tts_stream_lifecycle import (
    CancelTurnTrace,
    fetch_gauges,
    probe_idle_cancel,
    run_cancel_turn,
    summarise_cancel,
)

from speechrail.app import create_app
from speechrail.config import Settings
from test_realtime_tts_incremental import FakeIncrementalSynthesizer, _preset_kwargs


class _WebSocketBenchmarkAdapter:
    """Adapt a test websocket to the benchmark's ``send`` / ``recv`` seam."""

    def __init__(self, session: Any) -> None:
        self._session = session

    def send(self, event: dict[str, Any]) -> None:
        self._session.send_json(event)

    def recv(self) -> dict[str, Any]:
        return self._session.receive_json()


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class ScriptedConnection:
    """Return one canned event per ``recv`` and record what was sent."""

    def __init__(self, script: list[dict[str, Any]], clock: FakeClock) -> None:
        self.sent: list[dict[str, Any]] = []
        self._script = list(script)
        self._clock = clock

    def send(self, event: dict[str, Any]) -> None:
        self.sent.append(event)

    def recv(self) -> dict[str, Any]:
        if not self._script:
            raise AssertionError("the benchmark read past the end of the fake script")
        event = self._script.pop(0)
        self._clock.advance(0.001)
        return event


def test_cancel_trace_separates_teardown_from_release() -> None:
    trace = CancelTurnTrace(
        request_id="req",
        cancel_sent_at=10.0,
        first_audio_at=9.5,
        last_audio_at=10.05,
        terminal_at=10.2,
        terminal_status="cancelled",
        audio_bytes_before_cancel=48_000,
        audio_bytes_after_cancel=4_800,
        next_start_accepted_at=10.6,
    )
    # 4800 bytes at 24 kHz PCM16 is 100 ms that should never have been sent.
    assert trace.audio_seconds_after_cancel == pytest.approx(0.1)
    assert trace.cancel_to_last_audio_seconds == pytest.approx(0.05)
    assert trace.cancel_to_terminal_seconds == pytest.approx(0.2)
    assert trace.next_start_accepted_seconds == pytest.approx(0.6)


def test_summarise_cancel_flags_stale_audio_and_missing_terminals() -> None:
    clean = CancelTurnTrace(
        request_id="a",
        cancel_sent_at=0.0,
        first_audio_at=-0.1,
        last_audio_at=-0.01,
        terminal_at=0.2,
        terminal_status="cancelled",
        audio_bytes_before_cancel=9600,
        audio_bytes_after_cancel=0,
        next_start_accepted_at=0.3,
    )
    stale = CancelTurnTrace(
        request_id="b",
        cancel_sent_at=0.0,
        first_audio_at=-0.1,
        last_audio_at=0.01,
        terminal_at=0.4,
        terminal_status="cancelled",
        audio_bytes_before_cancel=9600,
        audio_bytes_after_cancel=1920,
        next_start_accepted_at=0.5,
        failure="tts_not_active",
    )
    wedged = CancelTurnTrace(
        request_id="c",
        cancel_sent_at=0.0,
        first_audio_at=None,
        last_audio_at=None,
        terminal_at=None,
        terminal_status=None,
        audio_bytes_before_cancel=0,
        audio_bytes_after_cancel=0,
    )

    summary = summarise_cancel([clean, stale, wedged])
    assert summary.samples == 2  # the wedged turn is never averaged in
    assert summary.cancelled_turns == 2
    assert summary.stale_audio_turns == 1
    assert summary.failures == ("tts_not_active",)
    assert summary.cancel_to_terminal_ms_p50 == pytest.approx(400.0)
    payload = summary.as_dict()
    assert payload["stale_audio_turns"] == 1
    assert payload["cancel_to_terminal_ms"]["p95"] == pytest.approx(400.0)


def test_probe_idle_cancel_reads_the_stable_error_code() -> None:
    clock = FakeClock()
    connection = ScriptedConnection(
        [{"type": "error", "error": {"code": "tts_not_active"}}], clock
    )
    assert probe_idle_cancel(connection, clock=clock) == "tts_not_active"
    assert connection.sent == [
        {"type": "speechrail.tts.cancel", "request_id": "bench_lifecycle_idle_cancel"}
    ]


def test_run_cancel_turn_drives_the_real_realtime_server() -> None:
    """The interrupt probe must speak the protocol the server actually implements."""

    synthesizer = FakeIncrementalSynthesizer()
    client = TestClient(
        create_app(Settings(**_preset_kwargs("balanced")), tts_synthesizer=synthesizer)
    )

    with client.websocket_connect("/v1/realtime") as socket:
        trace = run_cancel_turn(
            _WebSocketBenchmarkAdapter(socket),
            text="你好，这是一次被中断的增量朗读。",
            cancel_trigger="first_ack",
            timeout_seconds=30.0,
        )

    assert trace.failure is None
    assert trace.terminal_status == "cancelled"
    assert trace.audio_bytes_after_cancel == 0
    assert trace.cancel_to_terminal_seconds is not None
    # The release probe proves the server let go of the stream slot.
    assert trace.next_start_accepted_at is not None
    assert synthesizer.sessions[0].cancelled is True
    assert synthesizer.sessions[0].closed is True


def test_soak_sampling_keeps_footprint_and_release_evidence(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A soak must read recovery and the memory trend, not just active gauges.

    Watching only the active-request gauges cannot tell a released reservation
    from one that never came back, and cannot separate MLX allocator caching
    from a real physical-footprint trend.  Both come from the service's own
    authoritative metrics, so the artifact has to carry them.
    """

    metrics = (
        "# HELP speechrail_realtime_active_sessions sessions\n"
        "speechrail_realtime_active_sessions 0\n"
        'speechrail_governor_releases_total{class="realtime_tts",'
        'outcome="completed",purpose="interactive"} 52\n'
        "speechrail_resource_physical_footprint_bytes 3.50602e+09\n"
        "speechrail_resource_footprint_process_count 3\n"
        "speechrail_resource_footprint_complete 1\n"
        'speechrail_unrelated_free_form{prompt="private"} 7\n'
    )

    class _Response:
        def __enter__(self) -> _Response:
            return self

        def __exit__(self, *_: object) -> None:
            return None

        def read(self) -> bytes:
            return metrics.encode("utf-8")

    monkeypatch.setattr(urllib.request, "urlopen", lambda *_a, **_k: _Response())

    observed = fetch_gauges(metrics_url="http://127.0.0.1:8201/metrics", api_key=None)

    assert observed["speechrail_resource_physical_footprint_bytes"] == 3.50602e09
    assert observed["speechrail_resource_footprint_process_count"] == 3
    assert observed["speechrail_resource_footprint_complete"] == 1
    assert observed["speechrail_realtime_active_sessions"] == 0
    assert observed[
        'speechrail_governor_releases_total{class="realtime_tts",'
        'outcome="completed",purpose="interactive"}'
    ] == 52
    # Free-form series never enter the artifact.
    assert not any("unrelated" in name for name in observed)
