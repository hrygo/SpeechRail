"""Injected-fake contract tests for the ASR||TTS overlap benchmark driver."""

from __future__ import annotations

import json
import sys
import threading
from collections.abc import Mapping
from pathlib import Path
from stat import S_IMODE

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf import bench_overlap
from examples.perf.bench_overlap import OverlapDependencies, run_overlap_benchmark
from examples.perf.benchmark_http import HttpResponse
from examples.perf.benchmark_manifest import BenchmarkInputError


class _FakeRunner:
    def __init__(self, *, asr_status: int = 200, batch_peak: int = 2) -> None:
        self._lock = threading.Lock()
        self.calls: list[tuple[str, str]] = []
        self.headers: list[Mapping[str, str]] = []
        self.asr_status = asr_status
        self.batch_peak = batch_peak

    def counts(self) -> dict[str, int]:
        with self._lock:
            snapshot = list(self.calls)
        return {
            "asr": sum(1 for _, url in snapshot if url.endswith("/v1/audio/transcriptions")),
            "tts": sum(1 for _, url in snapshot if url.endswith("/v1/audio/speech")),
            "metrics": sum(1 for _, url in snapshot if url.endswith("/metrics")),
        }

    def __call__(
        self,
        method: str,
        url: str,
        body: bytes | None,
        headers: Mapping[str, str],
    ) -> HttpResponse:
        with self._lock:
            self.calls.append((method, url))
            self.headers.append(dict(headers))
        if url.endswith("/metrics"):
            payload = {"active_requests": {"batch": self.batch_peak, "realtime": 0}}
            return HttpResponse(200, json.dumps(payload).encode())
        if url.endswith("/v1/audio/speech"):
            return HttpResponse(200, b"\0" * 48000, {"x-request-id": "req-tts-private"})
        if url.endswith("/v1/audio/transcriptions"):
            if self.asr_status != 200:
                return HttpResponse(
                    self.asr_status,
                    b'{"error":{"code":"backend_busy"}}',
                    {"x-request-id": "req-asr-private"},
                )
            return HttpResponse(
                200,
                json.dumps({"text": "secret transcript"}).encode(),
                {"x-request-id": "req-asr-private"},
            )
        return HttpResponse(200, b"{}")


class _FakeMonitor:
    def __init__(self, events: list[str] | None = None, **_kwargs: object) -> None:
        self.events = events if events is not None else []
        self.starts = 0
        self.stops = 0

    def start(self) -> None:
        self.starts += 1
        self.events.append("start")

    def stop(self) -> Mapping[str, object]:
        self.stops += 1
        self.events.append("stop")
        return {
            "hardware": {
                "real": True,
                "source": "monitor",
                "chip": "Apple M5 Max",
                "architecture": "arm64",
            },
            "os": {"name": "Darwin", "version": "25.0.0"},
            "memory": {"physical_bytes": 137438953472},
            "process_samples": [
                {
                    "at_seconds": 0.0,
                    "processes": [
                        {
                            "role": "host-fastapi",
                            "pid": 10,
                            "start_time_ns": 1,
                            "rss_bytes": 100,
                            "phys_footprint_bytes": 200,
                        },
                        {
                            "role": "batch-asr",
                            "pid": 20,
                            "start_time_ns": 2,
                            "rss_bytes": 300,
                            "phys_footprint_bytes": 400,
                        },
                        {
                            "role": "tts",
                            "pid": 30,
                            "start_time_ns": 3,
                            "rss_bytes": 500,
                            "phys_footprint_bytes": 600,
                        },
                    ],
                }
            ],
            "resource_sampler": {"available": True, "real": True, "source": "monitor"},
        }


class _FakeClock:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.value = 0.0

    def __call__(self) -> float:
        with self._lock:
            self.value += 0.5
            return self.value


def _manifest(tmp_path: Path) -> tuple[Path, Path]:
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"RIFF")
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "fixtures": [
                    {"id": "asr10-w01", "path": str(audio), "kind": "asr", "language": "zh"},
                    {
                        "id": "tts-long-w01",
                        "path": str(audio),
                        "kind": "tts",
                        "voice": "serena",
                        "text": "tts-secret-text 长文本",
                    },
                ],
                "model_identity": {
                    "model": "speechrail/qwen3-asr-1.7b",
                    "variant": "asr",
                    "quantization": {"bits": 8, "format": "mlx"},
                    "real": True,
                },
            }
        ),
        encoding="utf-8",
    )
    return manifest, audio


def _dependencies(
    runner: _FakeRunner,
    monitors: list[_FakeMonitor],
    sleeps: list[float],
) -> OverlapDependencies:
    events: list[str] = []

    def factory() -> _FakeMonitor:
        monitor = _FakeMonitor(events)
        monitors.append(monitor)
        return monitor

    return OverlapDependencies(
        http_runner=runner,
        clock=_FakeClock(),
        sleep=sleeps.append,
        monitor_factory=factory,
        metrics_interval_seconds=0.01,
    )


def _run(
    tmp_path: Path,
    *,
    runner: _FakeRunner | None = None,
    scenarios: tuple[str, ...] = ("C1",),
    concurrency: int = 3,
    delay: float = 1.5,
    asr_fixture_id: str = "asr10-w01",
    tts_fixture_id: str = "tts-long-w01",
) -> tuple[dict[str, object], _FakeRunner, list[_FakeMonitor], list[float], Path]:
    manifest, audio = _manifest(tmp_path)
    fake = runner if runner is not None else _FakeRunner()
    monitors: list[_FakeMonitor] = []
    sleeps: list[float] = []
    result = run_overlap_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        asr_fixture_id=asr_fixture_id,
        tts_fixture_id=tts_fixture_id,
        concurrency=concurrency,
        delay_seconds=delay,
        scenarios=scenarios,
        dependencies=_dependencies(fake, monitors, sleeps),
    )
    return result, fake, monitors, sleeps, audio


def _scenario(result: Mapping[str, object], index: int = 0) -> dict[str, object]:
    scenarios = result["scenarios"]
    assert isinstance(scenarios, list)
    scenario = scenarios[index]
    assert isinstance(scenario, dict)
    return scenario


def _field(container: Mapping[str, object], key: str) -> dict[str, object]:
    value = container[key]
    assert isinstance(value, dict)
    return value


def _requests(scenario: Mapping[str, object]) -> list[dict[str, object]]:
    items = scenario["requests"]
    assert isinstance(items, list)
    requests: list[dict[str, object]] = []
    for item in items:
        assert isinstance(item, dict)
        requests.append(item)
    return requests


def test_c1_fires_one_tts_then_concurrent_asr(tmp_path: Path) -> None:
    result, runner, _monitors, sleeps, _audio = _run(tmp_path, scenarios=("C1",), concurrency=3)

    scenario = _scenario(result)
    assert scenario["name"] == "C1"
    requests = _requests(scenario)
    assert len(requests) == 4
    kinds = [str(item["kind"]) for item in requests]
    assert sorted(kinds) == ["asr", "asr", "asr", "tts"]
    assert sleeps == [1.5]
    counts = runner.counts()
    assert counts["asr"] == 4  # one warm-up plus three measured
    assert counts["tts"] == 2  # one warm-up plus one measured
    assert counts["metrics"] >= 1


def test_c2_fires_asr_wave_before_tts(tmp_path: Path) -> None:
    result, runner, _monitors, sleeps, _audio = _run(tmp_path, scenarios=("C2",), concurrency=2)

    scenario = _scenario(result)
    requests = _requests(scenario)
    assert len(requests) == 3
    kinds = [str(item["kind"]) for item in requests]
    assert sorted(kinds) == ["asr", "asr", "tts"]
    assert sleeps == [1.5]
    counts = runner.counts()
    assert counts["asr"] == 3  # one warm-up plus two measured
    assert counts["tts"] == 2


def test_each_scenario_gets_a_fresh_resource_monitor(tmp_path: Path) -> None:
    result, _runner, monitors, _sleeps, _audio = _run(
        tmp_path, scenarios=("C1", "C2"), concurrency=1
    )

    assert len(_requests(_scenario(result))) == 2
    assert len(monitors) == 2
    assert all(monitor.starts == 1 and monitor.stops == 1 for monitor in monitors)
    all_scenarios = result["scenarios"]
    assert isinstance(all_scenarios, list)
    assert [item["name"] for item in all_scenarios if isinstance(item, dict)] == ["C1", "C2"]


def test_scenario_records_governor_peak_and_complete_resources(tmp_path: Path) -> None:
    result = _run(tmp_path, scenarios=("C1",), concurrency=1)[0]

    scenario = _scenario(result)
    peak = _field(scenario, "governor_peak")
    assert peak["batch_active_peak"] == 2
    assert peak["realtime_active_peak"] == 0
    assert peak["available"] is True
    samples = peak["samples"]
    assert isinstance(samples, int) and samples >= 2  # boundary scrapes at start and stop
    resources = _field(scenario, "resources")
    assert resources["sampling_complete"] is True
    assert resources["active_window_sampling_complete"] is True
    assert _field(resources, "simultaneous_peak")["phys_footprint_bytes"] == 1200
    assert _field(scenario, "hardware")["chip"] == "Apple M5 Max"
    assert _field(scenario, "memory")["physical_bytes"] == 137438953472


def test_output_shape_is_overlap_schema_and_redacted(tmp_path: Path) -> None:
    result, _runner, _monitors, _sleeps, audio = _run(tmp_path, scenarios=("C1",), concurrency=2)

    assert result["schema"] == "speechrail-bench-overlap-v1"
    assert result["schema_version"] == 1
    assert result["tool"] == "speechrail-bench-overlap"
    assert result["evidence_mode"] == "injected"
    assert result["base_url"] == "http://127.0.0.1:8201"
    assert result["config"] == {
        "asr_fixture_id": "asr10-w01",
        "tts_fixture_id": "tts-long-w01",
        "concurrency": 2,
        "delay_seconds": 1.5,
        "scenarios": ["C1"],
    }
    assert result["warmup"] == {"asr_status_code": 200, "tts_status_code": 200}
    scenario = _scenario(result)
    assert isinstance(scenario["wall_seconds"], float)
    requests = _requests(scenario)
    assert len(requests) == 3  # one TTS plus two concurrent ASR
    for item in requests:
        assert set(item) == {
            "kind",
            "fixture",
            "status_code",
            "success",
            "latency_seconds",
            "response_bytes",
            "request_id_present",
        }
        assert item["request_id_present"] is True
        assert item["success"] is True

    encoded = json.dumps(result, ensure_ascii=False)
    assert str(audio) not in encoded
    assert "fixture.wav" not in encoded
    assert "secret transcript" not in encoded
    assert "tts-secret-text" not in encoded
    assert "req-tts-private" not in encoded
    assert "req-asr-private" not in encoded


def test_backend_busy_asr_is_recorded_not_swallowed(tmp_path: Path) -> None:
    result = _run(
        tmp_path,
        runner=_FakeRunner(asr_status=503),
        scenarios=("C1",),
        concurrency=2,
    )[0]

    scenario = _scenario(result)
    asr_items = [item for item in _requests(scenario) if item["kind"] == "asr"]
    assert len(asr_items) == 2
    assert all(item["status_code"] == 503 and item["success"] is False for item in asr_items)
    assert scenario["failed_requests"] == 2


def test_missing_fixture_id_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(BenchmarkInputError, match="not found"):
        _run(tmp_path, asr_fixture_id="nope-w99")


def test_fixture_kind_mismatch_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(BenchmarkInputError, match="kind"):
        _run(tmp_path, asr_fixture_id="tts-long-w01")


def test_invalid_concurrency_or_delay_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(BenchmarkInputError, match="concurrency"):
        _run(tmp_path, concurrency=0)
    with pytest.raises(BenchmarkInputError, match="delay"):
        _run(tmp_path, delay=-1.0)


def test_unknown_or_duplicate_scenario_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(BenchmarkInputError, match="unknown scenario"):
        _run(tmp_path, scenarios=("C9",))
    with pytest.raises(BenchmarkInputError, match="duplicate"):
        _run(tmp_path, scenarios=("C1", "C1"))


def test_main_writes_private_file_and_refuses_overwrite(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, _audio = _manifest(tmp_path)
    output = tmp_path / "overlap.json"
    monkeypatch.setattr(bench_overlap, "_default_http_runner", _FakeRunner())
    monkeypatch.setattr(bench_overlap, "ProcessResourceMonitor", _FakeMonitor)
    monkeypatch.setattr(bench_overlap, "build_auth_headers", lambda **_kwargs: {})
    argv = [
        "--base-url",
        "http://127.0.0.1:8201",
        "--manifest",
        str(manifest),
        "--output",
        str(output),
        "--scenario",
        "C1",
        "--delay-seconds",
        "0.0",
    ]

    assert bench_overlap.main(argv) == 0
    assert S_IMODE(output.stat().st_mode) == 0o600
    payload = json.loads(output.read_text(encoding="utf-8"))
    assert payload["schema"] == "speechrail-bench-overlap-v1"
    assert payload["evidence_mode"] == "real"

    assert bench_overlap.main(argv) == 2
    assert json.loads(output.read_text(encoding="utf-8")) == payload


def test_main_rejects_invalid_base_url_without_network(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, _audio = _manifest(tmp_path)
    output = tmp_path / "overlap.json"
    monkeypatch.setattr(bench_overlap, "build_auth_headers", lambda **_kwargs: {})

    code = bench_overlap.main(
        [
            "--base-url",
            "http://example.com",
            "--manifest",
            str(manifest),
            "--output",
            str(output),
        ]
    )
    assert code == 2
    assert not output.exists()


def test_help_exits_zero() -> None:
    with pytest.raises(SystemExit) as exit_info:
        bench_overlap.main(["--help"])
    assert exit_info.value.code == 0


def test_cli_defaults_to_single_asr_concurrency() -> None:
    parser = bench_overlap._build_parser()
    args = parser.parse_args(
        [
            "--base-url",
            "http://127.0.0.1:8201",
            "--manifest",
            "manifest.json",
            "--output",
            "overlap.json",
        ]
    )
    assert args.concurrency == 1
