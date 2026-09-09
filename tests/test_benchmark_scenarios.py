"""Deterministic regression tests for the full-stack benchmark scenarios."""

from __future__ import annotations

import queue
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf import bench_realtime, benchmark_scenarios
from examples.perf.benchmark_http import HttpResponse


class _FakeRealtimeConnection:
    def __init__(self, *, server_vad: bool = False, diarization: bool = False) -> None:
        self._events: queue.Queue[object] = queue.Queue()
        self._server_vad = server_vad
        self._diarization = diarization
        self._vad_emitted = False
        self._closed = False
        self._events.put({"type": "conversation.created"})

    def recv(self) -> object:
        event = self._events.get()
        if isinstance(event, BaseException):
            raise event
        return event

    def send(self, event: dict[str, object]) -> None:
        event_type = event.get("type")
        if event_type == "session.update":
            self._events.put({"type": "session.updated"})
        elif event_type == "input_audio_buffer.append" and self._server_vad:
            if not self._vad_emitted:
                self._vad_emitted = True
                self._events.put({"type": "input_audio_buffer.speech_started"})
                self._events.put({"type": "input_audio_buffer.speech_stopped"})
                self._events.put(
                    {
                        "type": "conversation.item.input_audio_transcription.completed",
                        "transcript": "测试",
                    }
                )
                if self._diarization:
                    self._events.put({"type": "speechrail.diarization.updated"})
        elif event_type == "input_audio_buffer.commit":
            self._events.put(
                {
                    "type": "conversation.item.input_audio_transcription.completed",
                    "transcript": "测试",
                }
            )
            if self._diarization:
                self._events.put({"type": "speechrail.diarization.updated"})
        elif event_type == "speechrail.diarization.finish":
            self._events.put({"type": "speechrail.diarization.done"})
        elif event_type == "conversation.item.create":
            self._events.put({"type": "conversation.item.created"})
        elif event_type == "response.create":
            self._events.put({"type": "response.audio.delta", "delta": "AA=="})
            self._events.put({"type": "response.done"})

    def close(self) -> None:
        self._closed = True
        self._events.put(RuntimeError("closed"))


def test_realtime_benchmark_records_server_vad_and_diarization_events() -> None:
    connection = _FakeRealtimeConnection(server_vad=True, diarization=True)

    result = bench_realtime._run_connected_session(
        connection,
        b"\x00\x00" * 800,
        "测试",
        1,
        turn_detection="server_vad",
        diarization=True,
    )
    connection.close()

    assert result["vad_started"] is True
    assert result["vad_stopped"] is True
    assert result["diarization_updated"] is True
    assert result["diarization_done"] is True
    assert result["response_done"] is True
    assert "transcript" not in result


def test_resource_summary_reports_expected_roles_and_complete_ticks() -> None:
    summary = benchmark_scenarios._resource_summary(
        {
            "sampling_complete": True,
            "role_transitions": [1],
            "simultaneous_peak": {"phys_footprint_bytes": 123},
            "samples": [
                {
                    "complete": True,
                    "processes": [
                        {"role": "host-fastapi"},
                        {"role": "streaming-asr"},
                        {"role": "tts"},
                    ],
                }
            ],
        },
        ("host-fastapi", "streaming-asr", "tts"),
    )

    assert summary["missing_expected_roles"] == []
    assert summary["expected_roles_in_complete_tick"] is True
    assert summary["role_transitions"] == [1]


def test_resource_summary_accepts_complete_active_window_for_incarnated_worker() -> None:
    summary = benchmark_scenarios._resource_summary(
        {
            "sampling_complete": False,
            "active_window_sampling_complete": True,
            "active_windows": [
                {
                    "roles": ["batch-asr", "diarization", "host-fastapi"],
                    "complete": True,
                    "simultaneous_peak": {
                        "phys_footprint_bytes": 987,
                    },
                }
            ],
            "samples": [],
        },
        ("host-fastapi", "batch-asr", "diarization"),
    )

    assert summary["resource_evidence_verdict"] == "active_window_complete"
    assert summary["active_window_count"] == 1
    assert summary["active_window_peak"]["phys_footprint_bytes"] == 987


def test_lifecycle_prime_keeps_lazy_diarization_worker_active(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sent: list[dict[str, object]] = []
    waits: list[float] = []

    class Connection:
        def send(self, event: dict[str, object]) -> None:
            sent.append(event)

    monkeypatch.setattr(benchmark_scenarios.time, "sleep", waits.append)

    benchmark_scenarios._prime_lifecycle_session(Connection(), b"\x00\x00" * 40_000)

    assert sent[0]["type"] == "input_audio_buffer.append"
    assert isinstance(sent[0]["audio"], str)
    assert waits == [benchmark_scenarios._LIFECYCLE_PRIME_WAIT_SECONDS]


def test_lifecycle_close_waits_for_server_side_cleanup(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    closed: list[bool] = []
    waits: list[float] = []

    class Connection:
        def close(self) -> None:
            closed.append(True)

    monkeypatch.setattr(benchmark_scenarios.time, "sleep", waits.append)

    benchmark_scenarios._close_lifecycle_connection(Connection())

    assert closed == [True]
    assert waits == [benchmark_scenarios._LIFECYCLE_CLOSE_SETTLE_SECONDS]


def test_scenario_selection_is_explicit_and_duplicate_free() -> None:
    assert benchmark_scenarios._normalise_scenario_ids(["e", "C"]) == ("E", "C")
    assert benchmark_scenarios._normalise_scenario_ids(None) == ("A", "B", "C", "D", "E")
    with pytest.raises(ValueError, match="duplicate"):
        benchmark_scenarios._normalise_scenario_ids(["A", "a"])
    with pytest.raises(ValueError, match="unknown"):
        benchmark_scenarios._normalise_scenario_ids(["Z"])


def test_rest_diarization_runner_keeps_transcript_out_of_evidence(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"RIFF")

    def fake_http(
        method: str,
        url: str,
        body: bytes | None,
        headers: dict[str, str],
    ) -> HttpResponse:
        assert method == "POST"
        assert url.endswith("/v1/audio/transcriptions")
        assert body is not None
        assert b"gpt-4o-transcribe-diarize" in body
        assert b"diarized_json" in body
        assert headers["Content-Type"].startswith("multipart/form-data")
        return HttpResponse(
            status_code=200,
            body=b'{"text":"secret transcript","segments":[{"speaker":"spk_0"}]}',
        )

    monkeypatch.setattr(benchmark_scenarios, "_default_http_runner", fake_http)
    result = benchmark_scenarios._rest_diarization_run(
        "http://127.0.0.1:8201/v1",
        audio,
        {},
    )

    assert result["status"] == "passed"
    assert result["text_present"] is True
    assert "secret transcript" not in str(result)


def test_safe_error_does_not_copy_exception_message() -> None:
    safe = benchmark_scenarios._safe_error(RuntimeError("private path and token"))

    assert safe == {"type": "RuntimeError"}


def test_realtime_error_is_not_silently_turned_into_a_timeout() -> None:
    events: queue.Queue[object] = queue.Queue()
    events.put({"type": "error", "error": {"code": "invalid_argument"}})

    with pytest.raises(bench_realtime.RealtimeEventError) as excinfo:
        bench_realtime.recv_until(events, [], "target", timeout=0.1)

    assert excinfo.value.code == "invalid_argument"
