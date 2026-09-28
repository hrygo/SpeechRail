from __future__ import annotations

import importlib.util
import sys
import time
import wave
from pathlib import Path

import pytest

_MODULE_PATH = Path(__file__).resolve().parents[1] / "tools/probe_teleprompter_latency.py"
_SPEC = importlib.util.spec_from_file_location(
    "speechrail_probe_teleprompter_latency",
    _MODULE_PATH,
)
assert _SPEC is not None and _SPEC.loader is not None
_PROBE = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = _PROBE
_SPEC.loader.exec_module(_PROBE)

_ProbeMeasurements = getattr(_PROBE, "_ProbeMeasurements", None)
ProbeInputError = _PROBE.ProbeInputError
RealtimeQueueOverflowError = _PROBE.RealtimeQueueOverflowError
RevisionTracker = _PROBE.RevisionTracker
_event_matches_commit = _PROBE._event_matches_commit
_media_origin_after_configuration = _PROBE._media_origin_after_configuration
_receive_loop = _PROBE._receive_loop
_wait_for_terminal = _PROBE._wait_for_terminal
load_wave_fixture = _PROBE.load_wave_fixture
percentile = _PROBE.percentile
timing_summary = _PROBE.timing_summary


def test_percentile_and_timing_summary_are_deterministic() -> None:
    assert percentile([3.0, 1.0, 2.0], 0.50) == 2.0
    assert timing_summary([3.0, 1.0, 2.0]) == {
        "count": 3,
        "p50_ms": 2.0,
        "p95_ms": 3.0,
        "max_ms": 3.0,
    }
    assert timing_summary([])["p95_ms"] is None


def test_load_wave_fixture_requires_24khz_mono_pcm16(tmp_path: Path) -> None:
    path = tmp_path / "fixture.wav"
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24_000)
        output.writeframes(b"\x00\x00" * 2_400)

    fixture = load_wave_fixture(path)
    assert fixture.duration_seconds == 0.1
    assert len(fixture.pcm) == 4_800


def test_load_wave_fixture_rejects_wrong_format(tmp_path: Path) -> None:
    path = tmp_path / "wrong.wav"
    with wave.open(str(path), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(48_000)
        output.writeframes(b"\x00\x00" * 100)

    with pytest.raises(ProbeInputError):
        load_wave_fixture(path)


class _Clock:
    def __init__(self, values: list[float]) -> None:
        self.values = iter(values)

    def __call__(self) -> float:
        return next(self.values)


class _OneEventConnection:
    def __init__(self, event: object) -> None:
        self.event = event

    def recv(self) -> object:
        value = self.event
        self.event = None
        if value is None:
            raise OSError("closed")
        return value


class _MutableClock:
    def __init__(self, value: float) -> None:
        self.value = value

    def __call__(self) -> float:
        return self.value


class _ClockAdvancingConnection:
    def __init__(self, clock: _MutableClock, event: object) -> None:
        self.clock = clock
        self.event = event

    def recv(self) -> object:
        self.clock.value = 3.0
        value = self.event
        self.event = None
        if value is None:
            raise OSError("closed")
        return value


def test_receive_loop_stamps_time_after_recv_returns() -> None:
    import queue
    import threading

    events: queue.Queue[tuple[float, object]] = queue.Queue()
    errors: list[Exception] = []
    clock = _MutableClock(1.0)
    thread = threading.Thread(
        target=_receive_loop,
        args=(events, errors, _ClockAdvancingConnection(clock, {"type": "event"}), clock),
    )
    thread.start()
    thread.join(timeout=1)

    assert events.get_nowait() == (3.0, {"type": "event"})
    assert isinstance(errors[0], OSError)


def test_media_origin_is_established_after_session_configuration() -> None:
    clock = _Clock([13.0])
    created_at, configured_at = 10.0, 12.0

    assert _media_origin_after_configuration(clock, created_at, configured_at) == 12.0
    assert created_at == 10.0
    assert configured_at == 12.0


def test_media_origin_refuses_to_start_before_the_configuration_ack() -> None:
    """时钟回退必须硬失败，而不是让媒体起点早于 ACK 算出负延迟。"""

    backwards = _Clock([11.5])

    try:
        _media_origin_after_configuration(backwards, 10.0, 12.0)
    except RuntimeError as error:
        assert "monotonic clock moved backwards" in str(error)
    else:
        raise AssertionError("时钟回退时必须拒绝建立媒体起点")


def test_commit_terminal_requires_the_matching_event_id() -> None:
    rollover = {
        "type": "conversation.item.input_audio_transcription.completed",
        "commit_event_id": "older-rollover",
    }
    committed = {
        "type": "conversation.item.input_audio_transcription.completed",
        "commit_event_id": "evt-commit",
    }
    failed = {
        "type": "conversation.item.input_audio_transcription.failed",
        "commit_event_id": "evt-commit",
    }

    assert not _event_matches_commit(rollover, "evt-commit")
    assert _event_matches_commit(committed, "evt-commit")
    assert _event_matches_commit(failed, "evt-commit")
    assert not _event_matches_commit({"type": "speechrail.transcription.hypothesis"}, "evt-commit")


def test_wait_for_terminal_ignores_other_commit_and_surfaces_errors() -> None:
    import queue

    events: queue.Queue[tuple[float, object]] = queue.Queue()
    events.put(
        (
            1.0,
            {
                "type": "conversation.item.input_audio_transcription.completed",
                "commit_event_id": "other",
            },
        )
    )
    events.put((2.0, {"type": "conversation.item.input_audio_transcription.failed",
                      "commit_event_id": "evt-commit"}))

    received_at, _event, event_type = _wait_for_terminal(
        events, [], "evt-commit", deadline=lambda: time.monotonic() + 10.0
    )
    assert received_at == 2.0
    assert event_type.endswith(".failed")

    failing: list[Exception] = [RealtimeQueueOverflowError("full")]
    with pytest.raises(RealtimeQueueOverflowError):
        _wait_for_terminal(
            queue.Queue(),
            failing,
            "evt-commit",
            deadline=lambda: time.monotonic() + 10.0,
        )


def test_revision_tracker_scopes_regressions_to_one_utterance() -> None:
    tracker = RevisionTracker()
    tracker.record("utt-1", 1)
    tracker.record("utt-1", 2)
    tracker.record("utt-2", 1)
    tracker.record("utt-1", 2)

    assert tracker.partial_count == 4
    assert tracker.revision_regressions == 1
    assert tracker.utterance_count == 2


def test_probe_measurements_record_hypothesis_without_losing_first_partial() -> None:
    assert _ProbeMeasurements is not None
    measurements = _ProbeMeasurements()
    measurements.record_hypothesis(
        10.0, {"type": "speechrail.transcription.hypothesis",
               "utterance_id": "utt-1", "revision": 1}
    )
    measurements.record_hypothesis(
        10.25, {"type": "speechrail.transcription.hypothesis",
                "utterance_id": "utt-1", "revision": 2}
    )

    assert measurements.revisions.partial_count == 2
    assert measurements.first_partial_at == 10.0
    assert measurements.partial_gaps == [250.0]


def test_receive_loop_fails_instead_of_growing_an_unbounded_queue() -> None:
    import queue
    import threading

    events: queue.Queue[tuple[float, object]] = queue.Queue(maxsize=1)
    events.put((0.0, {"type": "existing"}))
    errors: list[Exception] = []
    thread = threading.Thread(
        target=_receive_loop,
        args=(
            events,
            errors,
            _OneEventConnection({"type": "new"}),
            _Clock([1.0, 2.0]),
            1,
        ),
        # 必须守护：一旦有界投递退化成阻塞投递，这个线程会永久卡在 put 上，
        # 非守护线程会让整个 pytest 进程无法退出——本项目已经吃过一次测试挂死
        # 拖垮闸门的亏（阶段报告 §2 第 9 条）。守护化后，退化只会让断言失败。
        daemon=True,
    )
    thread.start()
    thread.join(timeout=5)

    assert not thread.is_alive(), "接收循环必须在有界投递失败后退出"
    assert isinstance(errors[0], RealtimeQueueOverflowError)
    assert events.get_nowait() == (0.0, {"type": "existing"})


def test_cli_reports_queue_overflow_as_input_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    wav_path = tmp_path / "fixture.wav"
    with wave.open(str(wav_path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24_000)
        output.writeframes(b"\x00\x00" * 2_400)

    def fail_probe(*_args: object, **_kwargs: object) -> dict[str, object]:
        raise RealtimeQueueOverflowError("realtime event queue exceeded 2048 items")

    monkeypatch.setattr(_PROBE, "run_probe", fail_probe)

    assert _PROBE.main(
        [
            str(wav_path),
            "--profile",
            "quality",
            "--output",
            str(tmp_path / "result.json"),
        ]
    ) == 2
    assert "RealtimeQueueOverflowError" in capsys.readouterr().out
