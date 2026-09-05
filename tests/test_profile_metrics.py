"""Deterministic tests for benchmark metrics and the TTS read loop."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import patch

import pytest

# ``examples`` is an intentional PEP 420 namespace and is not part of the
# installed wheel, so make the checkout root importable for these script tests.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf import bench_tts
from examples.perf.profile_metrics import (
    ProcessIdentity,
    rtf,
    simultaneous_peak,
    simultaneous_peak_by_identity,
)


def test_peaks_are_attributed_to_the_same_instant() -> None:
    assert simultaneous_peak([{1: 3, 2: 1}, {1: 1, 2: 3}]) == 4
    assert rtf(4.0, 8.0) == 0.5


@pytest.mark.parametrize(
    ("elapsed_seconds", "audio_seconds"),
    [
        (1.0, 0.0),
        (1.0, -1.0),
        (-1.0, 1.0),
        (float("nan"), 1.0),
        (1.0, float("nan")),
        (float("inf"), 1.0),
    ],
)
def test_rtf_rejects_invalid_durations(
    elapsed_seconds: float, audio_seconds: float
) -> None:
    with pytest.raises(ValueError, match=r"finite|positive|non-negative"):
        rtf(elapsed_seconds, audio_seconds)


def test_simultaneous_peak_does_not_zero_fill_an_incomplete_snapshot() -> None:
    samples = [{1: 3, 2: 1}, {1: 10}, {1: 2, 2: 4}]

    assert simultaneous_peak(samples) == 6


def test_simultaneous_peak_rejects_when_no_complete_snapshot_exists() -> None:
    with pytest.raises(ValueError, match=r"complete|sample"):
        simultaneous_peak([{1: 3}, {2: 4}])


def test_pid_reuse_is_distinguished_by_process_start_time() -> None:
    first_instance = ProcessIdentity(pid=17, start_time_ns=100)
    second_instance = ProcessIdentity(pid=17, start_time_ns=200)

    assert first_instance != second_instance
    with pytest.raises(ValueError, match=r"complete|sample"):
        simultaneous_peak_by_identity([{first_instance: 3}, {second_instance: 7}])


class _FakeResponse:
    def __init__(self, chunks: list[bytes]) -> None:
        self._chunks = iter(chunks)
        self.read_sizes: list[int] = []

    def __enter__(self) -> _FakeResponse:
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def read(self, size: int = -1) -> bytes:
        raise AssertionError("read 会等待填满缓冲区，不能测量首个可用音频块")

    def read1(self, size: int = -1) -> bytes:
        self.read_sizes.append(size)
        if size < 0:
            raise AssertionError("the benchmark must read the response incrementally")
        return next(self._chunks, b"")


def test_tts_truncated_pcm_is_not_reported_as_valid_audio() -> None:
    response = _FakeResponse([b"\x00"])
    with (
        patch.object(bench_tts.request, "urlopen", return_value=response),
        pytest.raises(ValueError, match="PCM"),
    ):
        bench_tts.synthesize_with_metrics(
            "http://local/v1/audio/speech", "测试", "default", "speechrail/qwen3-tts"
        )


def test_tts_stream_metrics_use_first_audio_and_actual_pcm_duration() -> None:
    response = _FakeResponse([b"\x00" * 480, b"\x01" * 960])

    with patch.object(bench_tts.request, "urlopen", return_value=response):
        metrics = bench_tts.synthesize_with_metrics(
            "http://local/v1/audio/speech", "测试", "default", "speechrail/qwen3-tts"
        )

    assert metrics.audio_bytes == 1_440
    assert metrics.actual_audio_seconds == pytest.approx(1_440 / bench_tts.PCM_BYTES_PER_SECOND)
    assert metrics.ttfa_seconds is not None
    assert metrics.continuous_rtf is not None
    assert len(metrics.block_intervals_seconds) == 1
    assert response.read_sizes
    assert all(size > 0 for size in response.read_sizes)


def test_tts_synthesize_keeps_the_existing_tuple_result() -> None:
    response = _FakeResponse([b"\x00" * 480])

    with patch.object(bench_tts.request, "urlopen", return_value=response):
        elapsed, audio_bytes = bench_tts.synthesize(
            "http://local/v1/audio/speech", "测试", "default", "speechrail/qwen3-tts"
        )

    assert elapsed >= 0.0
    assert audio_bytes == 480


def test_tts_empty_response_has_no_fake_duration_or_ttfa() -> None:
    response = _FakeResponse([])

    with patch.object(bench_tts.request, "urlopen", return_value=response):
        metrics = bench_tts.synthesize_with_metrics(
            "http://local/v1/audio/speech", "测试", "default", "speechrail/qwen3-tts"
        )

    assert metrics.audio_bytes == 0
    assert metrics.actual_audio_seconds == 0.0
    assert metrics.ttfa_seconds is None
    assert metrics.continuous_rtf is None
    assert metrics.block_intervals_seconds == ()


def test_tts_cli_reports_stream_metrics_while_retaining_rtf_summary(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    metrics = bench_tts.SynthesisMetrics(
        elapsed_seconds=0.6,
        audio_bytes=bench_tts.PCM_BYTES_PER_SECOND,
        actual_audio_seconds=1.0,
        ttfa_seconds=0.1,
        continuous_rtf=0.5,
        block_intervals_seconds=(0.2, 0.3),
    )
    monkeypatch.setattr(bench_tts, "synthesize_with_metrics", lambda *_args: metrics)
    monkeypatch.setattr("sys.argv", ["bench_tts.py", "--repeat", "1"])

    bench_tts.main()

    output = capsys.readouterr().out
    assert "actual_audio_seconds=1.000000" in output
    assert "ttfa=0.100s" in output
    assert "continuous_rtf=0.50x" in output
    assert "block_interval_mean=0.250s" in output
    assert "rtf=0.60x" in output
