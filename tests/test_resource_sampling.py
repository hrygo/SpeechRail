"""Deterministic tests for the bounded resource sampler."""

from __future__ import annotations

import sys
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf import sample_resources as resources
from examples.perf.profile_metrics import ProcessIdentity


class _Completed:
    def __init__(self, stdout: str, returncode: int = 0) -> None:
        self.stdout = stdout
        self.returncode = returncode


def test_worker_pids_deduplicates_same_process_identity(monkeypatch: pytest.MonkeyPatch) -> None:
    ps_output = "\n".join(
        [
            "USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND",
            "u 100 0.0 0.1 1 1 ?? S 10:00AM 0:00 speechrail.backends.qwen3_worker",
            "u 100 0.0 0.1 1 1 ?? S 10:00AM 0:00 speechrail.backends.qwen3_worker",
        ]
    )
    identity = ProcessIdentity(pid=100, start_time_ns=1)
    monkeypatch.setattr(
        resources.subprocess,
        "run",
        lambda *_args, **_kwargs: _Completed(ps_output),
    )
    monkeypatch.setattr(resources, "_current_process_identity", lambda *_args, **_kwargs: identity)

    found = resources.worker_pids()

    assert found == {"batch-asr": identity}


def test_missing_ps_output_is_incomplete_instead_of_zero(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(resources, "_read_ps_number", lambda *_args: None, raising=False)
    monkeypatch.setattr(resources, "_sample_footprint_mb", lambda _pid: None)
    monkeypatch.setattr(resources.subprocess, "run", lambda *_args, **_kwargs: _Completed(""))

    assert resources.sample(100) is None


def test_rss_fallback_is_explicitly_outside_phys_footprint_gate(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(resources, "_sample_footprint_mb", lambda _pid: None)
    monkeypatch.setattr(
        resources,
        "_read_ps_number",
        lambda _pid, field: 12.0 if field == "%cpu=" else 2048.0,
    )

    observation = resources.sample(100)

    assert observation is not None
    assert observation[3] == resources.RSS_FALLBACK_METRIC


def test_same_tick_current_footprints_are_summed_once() -> None:
    first = ProcessIdentity(pid=100, start_time_ns=1)
    second = ProcessIdentity(pid=200, start_time_ns=1)
    state = resources.SamplingStats()

    resources._record_tick(
        {"first": first, "second": second},
        state,
        lambda process: {
            first: (1.0, 3.0, 30.0, "Footprint"),
            second: (2.0, 5.0, 50.0, "Footprint"),
        }[process],
    )

    assert state.peak_concurrent_mb == 8.0
    assert state.complete_ticks == 1
    assert state.gate_complete is True


def test_rss_and_missing_ticks_never_pass_complete_gate() -> None:
    process = ProcessIdentity(pid=100, start_time_ns=1)
    state = resources.SamplingStats()
    for value in [(1.0, 2.0, 3.0, resources.RSS_FALLBACK_METRIC), None]:
        resources._record_tick({"worker": process}, state, lambda _, item=value: item)
    assert state.gate_complete is False
    assert state.peak_concurrent_mb is None


def test_missing_process_does_not_make_a_false_complete_peak() -> None:
    first = ProcessIdentity(pid=100, start_time_ns=1)
    second = ProcessIdentity(pid=200, start_time_ns=1)
    state = resources.SamplingStats()

    resources._record_tick(
        {"first": first, "second": second},
        state,
        lambda process: {
            first: (1.0, 10.0, 10.0, "Footprint"),
            second: None,
        }[process],
    )

    assert state.peak_concurrent_mb is None
    assert state.complete_ticks == 0
    assert state.incomplete_ticks == 1
    assert state.missing_observations == 1


def test_pid_reuse_is_missing_for_the_original_process_lifetime(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    expected = ProcessIdentity(pid=100, start_time_ns=1)
    reused = ProcessIdentity(pid=100, start_time_ns=2)
    monkeypatch.setattr(resources, "_current_process_identity", lambda *_args, **_kwargs: reused)
    monkeypatch.setattr(
        resources,
        "sample",
        lambda _pid: (1.0, 10.0, 10.0, "Footprint"),
    )

    assert resources._sample_process(expected) is None


def test_pid_reuse_during_sampling_discards_observation(monkeypatch: pytest.MonkeyPatch) -> None:
    first = ProcessIdentity(pid=100, start_time_ns=1)
    identities = iter([first, ProcessIdentity(pid=100, start_time_ns=2)])
    monkeypatch.setattr(resources, "_current_process_identity", lambda *_: next(identities))
    monkeypatch.setattr(resources, "sample", lambda _: (1.0, 10.0, 10.0, "Footprint"))
    assert resources._sample_process(first) is None


def test_process_start_time_is_nanoseconds_not_encoded_text() -> None:
    first = resources._start_time_identity("Sat Sep  5 10:00:00 2026")
    second = resources._start_time_identity("Sat Sep  5 10:00:01 2026")
    assert first is not None and second is not None
    assert second - first == 1_000_000_000
    assert resources._start_time_identity("10:00AM") is None


def test_missing_lifetime_is_not_replaced_by_ps_aux_hint(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(resources, "_read_process_start_time", lambda _: None)
    assert resources._current_process_identity(100, start_hint="10:00AM") is None


def test_all_mode_runs_batch_then_tts_in_each_iteration(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    audio = tmp_path / "fixture.wav"
    audio.touch()
    events: list[str] = []

    def fake_batch(*_args: object, **_kwargs: object) -> tuple[int, str]:
        events.append("batch")
        return 200, "ok"

    def fake_tts(*_args: object, **_kwargs: object) -> tuple[float, int]:
        events.append("tts")
        return 0.1, 480

    monkeypatch.setattr(resources, "transcribe_batch", fake_batch)
    monkeypatch.setattr(resources, "synthesize_tts", fake_tts)
    monkeypatch.setattr(resources.time, "sleep", lambda _seconds: None)

    resources._run_load("all", "http://local", 1, audio, "model")

    assert events == ["batch", "tts"]


def test_sampler_thread_records_and_cleans_up_reader_exception() -> None:
    process = ProcessIdentity(pid=100, start_time_ns=1)
    state = resources.SamplingStats()
    stop = threading.Event()

    def failing_reader(_process: ProcessIdentity) -> resources.SampleValue | None:
        raise RuntimeError("fake sampler failure")

    thread = threading.Thread(
        target=resources._sampler_loop,
        args=({"worker": process}, stop, state),
        kwargs={"reader": failing_reader, "interval_seconds": 0.0, "sleep_fn": lambda _: None},
    )
    thread.start()
    thread.join(timeout=1.0)

    assert not thread.is_alive()
    assert isinstance(state.error, RuntimeError)
    assert state.sampling_span_seconds is not None
