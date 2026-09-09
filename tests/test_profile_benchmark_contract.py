"""Contract tests for the real-profile benchmark harness."""

from __future__ import annotations

import json
import os
import sys
import threading
from collections.abc import Mapping
from pathlib import Path
from stat import S_IMODE

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf import benchmark_resources
from examples.perf.bench_profiles import (
    PROFILE_DEVICE_PHASES,
    BenchmarkDependencies,
    HttpResponse,
    ProcessResourceMonitor,
    ResourceMonitor,
    build_auth_headers,
    load_manifest,
    main,
    required_phases,
    run_profile_benchmark,
    validate_base_url,
    validate_output_path,
    write_result,
)


def test_profile_benchmark_has_one_modular_entrypoint() -> None:
    examples_root = Path(__file__).resolve().parents[1] / "examples" / "perf"
    assert (examples_root / "benchmark_manifest.py").is_file()
    assert (examples_root / "benchmark_http.py").is_file()
    assert (examples_root / "benchmark_resources.py").is_file()
    assert (examples_root / "benchmark_runner.py").is_file()
    assert (examples_root / "benchmark_scenarios.py").is_file()
    assert not (
        Path(__file__).resolve().parents[1]
        / ".agents"
        / "skills"
        / "speechrail-perf-benchmark"
        / "scripts"
        / "run_all_benchmarks.py"
    ).exists()


def test_perf_clients_use_shared_api_key_discovery() -> None:
    project_root = Path(__file__).resolve().parents[1]
    client_paths = (
        project_root / "examples" / "perf" / "bench_asr.py",
        project_root / "examples" / "perf" / "bench_tts.py",
        project_root / "examples" / "perf" / "bench_realtime.py",
        project_root / "examples" / "perf" / "benchmark_scenarios.py",
        project_root / "examples" / "perf" / "concurrent_realtime_smoke.py",
        project_root
        / ".agents"
        / "skills"
        / "speechrail-perf-benchmark"
        / "scripts"
        / "prepare_fixtures.py",
    )

    for path in client_paths:
        content = path.read_text(encoding="utf-8")
        assert "os.environ.get(\"SPEECHRAIL_API_KEY\")" not in content
        assert "resolve_api_key" in content or "build_auth_headers" in content


def test_process_resource_monitor_records_same_tick_identity(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    identity = benchmark_resources.ProcessIdentity(pid=4242, start_time_ns=99)
    monkeypatch.setattr(benchmark_resources, "_read_rss_bytes", lambda _: 1_024)
    monitor = ProcessResourceMonitor(
        interval_seconds=0.01,
        discover=lambda: {"host-fastapi": identity},
        reader=lambda _: (0.0, 2.0, 2.0, benchmark_resources.FOOTPRINT_METRIC),
    )

    monitor.start()
    result = monitor.stop()

    samples = result["process_samples"]
    assert isinstance(samples, list) and samples
    process = samples[0]["processes"][0]
    assert process["pid"] == 4242
    assert process["start_time_ns"] == 99
    assert process["rss_bytes"] == 1_024
    assert process["phys_footprint_bytes"] == 2 * 1024 * 1024


@pytest.mark.parametrize("interval", [float("nan"), float("inf"), 0.0])
def test_process_resource_monitor_rejects_non_finite_or_non_positive_interval(
    interval: float,
) -> None:
    with pytest.raises(ValueError, match="finite and positive"):
        ProcessResourceMonitor(interval_seconds=interval)


def test_process_resource_monitor_surfaces_discovery_failure() -> None:
    failed = threading.Event()

    def discover() -> Mapping[str, benchmark_resources.ProcessIdentity]:
        failed.set()
        raise RuntimeError("sampler-secret")

    monitor = ProcessResourceMonitor(interval_seconds=0.01, discover=discover)
    monitor.start()
    assert failed.wait(timeout=1.0)

    with pytest.raises(RuntimeError, match="resource monitor"):
        monitor.stop()


def test_macos_chip_name_uses_system_profiler_system_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[list[str], dict[str, object]]] = []

    class Completed:
        stdout = json.dumps(
            {"SPHardwareDataType": [{"chip_type": "Apple M5 Max"}]}
        )

    def run(args: list[str], **kwargs: object) -> Completed:
        calls.append((args, kwargs))
        return Completed()

    monkeypatch.setattr(benchmark_resources.sys, "platform", "darwin")
    monkeypatch.setattr(benchmark_resources.subprocess, "run", run)

    assert benchmark_resources._macos_chip_name() == "Apple M5 Max"
    assert calls[0][0][0] == "/usr/sbin/system_profiler"


def test_macos_physical_memory_uses_sysctl_system_path(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[list[str], dict[str, object]]] = []

    class Completed:
        stdout = "137438953472\n"

    def run(args: list[str], **kwargs: object) -> Completed:
        calls.append((args, kwargs))
        return Completed()

    monkeypatch.setattr(benchmark_resources.sys, "platform", "darwin")
    monkeypatch.setattr(benchmark_resources.subprocess, "run", run)

    assert benchmark_resources._physical_memory_bytes() == 137438953472
    assert calls[0][0][0] == "/usr/sbin/sysctl"


def test_resource_normalisation_rejects_any_incomplete_tick() -> None:
    identity = benchmark_resources.ProcessIdentity(pid=4242, start_time_ns=99)
    normalised = benchmark_resources._normalise_resources(
        {
            "process_samples": [
                {
                    "at_seconds": 1.0,
                    "processes": [
                        {
                            "pid": identity.pid,
                            "start_time_ns": identity.start_time_ns,
                            "rss_bytes": 100,
                            "phys_footprint_bytes": 200,
                        }
                    ],
                },
                {
                    "at_seconds": 2.0,
                    "processes": [
                        {
                            "pid": identity.pid,
                            "start_time_ns": identity.start_time_ns,
                            "rss_bytes": None,
                            "phys_footprint_bytes": 300,
                        }
                    ],
                },
            ]
        }
    )

    assert normalised["sampling_complete"] is False
    assert normalised["simultaneous_peak"] == {
        "rss_bytes": 100,
        "phys_footprint_bytes": 200,
    }


def test_resource_normalisation_preserves_safe_roles_and_marks_missing_process() -> None:
    normalised = benchmark_resources._normalise_resources(
        {
            "process_samples": [
                {
                    "at_seconds": 1.0,
                    "processes": [
                        {
                            "role": "host-fastapi",
                            "pid": 100,
                            "start_time_ns": 1,
                            "rss_bytes": 100,
                            "phys_footprint_bytes": 200,
                        },
                        {
                            "role": "diarization",
                            "pid": 300,
                            "start_time_ns": 3,
                            "rss_bytes": None,
                            "phys_footprint_bytes": None,
                        },
                    ],
                }
            ]
        }
    )

    assert normalised["sampling_complete"] is False
    processes = normalised["samples"][0]["processes"]
    assert {item["role"] for item in processes} == {"host-fastapi", "diarization"}


def test_resource_normalisation_retains_empty_tick_as_incomplete() -> None:
    normalised = benchmark_resources._normalise_resources(
        {"process_samples": [{"at_seconds": 1.0, "processes": []}]}
    )

    assert normalised["samples"] == [
        {"at_seconds": 1.0, "processes": [], "complete": False}
    ]
    assert normalised["sampling_complete"] is False


def test_resource_normalisation_keeps_timing_and_role_transitions() -> None:
    process = {
        "role": "host-fastapi",
        "pid": 100,
        "start_time_ns": 1,
        "rss_bytes": 100,
        "phys_footprint_bytes": 200,
    }
    normalised = benchmark_resources._normalise_resources(
        {
            "process_samples": [
                {
                    "at_seconds": 0.0,
                    "ended_at_seconds": 0.01,
                    "duration_seconds": 0.01,
                    "discovered_roles": ["host-fastapi"],
                    "processes": [process],
                },
                {
                    "at_seconds": 0.5,
                    "ended_at_seconds": 0.51,
                    "duration_seconds": 0.01,
                    "discovered_roles": ["host-fastapi", "tts"],
                    "processes": [process],
                },
            ],
            "resource_sampler": {
                "sampling_span_seconds": 0.52,
                "observation_seconds": 0.02,
                "max_tick_span_seconds": 0.01,
            },
        }
    )

    assert normalised["role_transitions"] == [1]
    assert normalised["observed_roles"] == ["host-fastapi", "tts"]
    assert normalised["samples"][1]["ended_at_seconds"] == 0.51
    assert normalised["sampler"]["sampling_span_seconds"] == 0.52


def test_resource_normalisation_derives_complete_worker_incarnation_windows() -> None:
    def process(
        role: str,
        pid: int,
        start_time_ns: int,
        footprint: int | None,
    ) -> dict[str, object]:
        return {
            "role": role,
            "pid": pid,
            "start_time_ns": start_time_ns,
            "rss_bytes": footprint,
            "phys_footprint_bytes": footprint,
        }

    host = process("host-fastapi", 100, 1, 100)
    batch = process("batch-asr", 200, 2, 200)
    first_diarization = process("diarization", 300, 3, 300)
    missing_first_diarization = process("diarization", 300, 3, None)
    second_diarization = process("diarization", 400, 4, 400)
    normalised = benchmark_resources._normalise_resources(
        {
            "process_samples": [
                {"at_seconds": 0.0, "processes": [host, batch]},
                {
                    "at_seconds": 0.1,
                    "processes": [host, batch, first_diarization],
                },
                {
                    "at_seconds": 0.2,
                    "processes": [host, batch, first_diarization],
                },
                {
                    "at_seconds": 0.3,
                    "processes": [host, batch, missing_first_diarization],
                },
                {"at_seconds": 0.4, "processes": [host, batch]},
                {
                    "at_seconds": 0.5,
                    "processes": [host, batch, second_diarization],
                },
                {
                    "at_seconds": 0.6,
                    "processes": [host, batch, second_diarization],
                },
            ]
        }
    )

    windows = [
        window
        for window in normalised["active_windows"]
        if "diarization" in window["roles"]
    ]
    assert len(windows) == 2
    assert all(window["complete"] is True for window in windows)
    assert windows[0]["boundary_incomplete_ticks"] == 1
    assert windows[0]["simultaneous_peak"]["phys_footprint_bytes"] == 600
    assert windows[1]["simultaneous_peak"]["phys_footprint_bytes"] == 700
    assert normalised["sampling_complete"] is False
    assert normalised["active_window_sampling_complete"] is True


def test_resource_normalisation_does_not_hide_internal_window_gap() -> None:
    def process(footprint: int | None) -> dict[str, object]:
        return {
            "role": "diarization",
            "pid": 300,
            "start_time_ns": 3,
            "rss_bytes": footprint,
            "phys_footprint_bytes": footprint,
        }

    normalised = benchmark_resources._normalise_resources(
        {
            "process_samples": [
                {"at_seconds": 0.0, "processes": [process(300)]},
                {"at_seconds": 0.1, "processes": [process(None)]},
                {"at_seconds": 0.2, "processes": [process(320)]},
            ]
        }
    )

    window = normalised["active_windows"][0]
    assert window["complete"] is False
    assert window["internal_incomplete_ticks"] == 1
    assert normalised["active_window_sampling_complete"] is False


class _FakeHttpRunner:
    def __init__(
        self,
        *,
        tts_body: bytes = b"tts pcm",
        events: list[str] | None = None,
        failure: BaseException | None = None,
    ) -> None:
        self.calls: list[tuple[str, str]] = []
        self.requests: list[tuple[str, str, bytes | None, Mapping[str, str]]] = []
        self.tts_body = tts_body
        self.events = events
        self.failure = failure

    def __call__(
        self,
        method: str,
        url: str,
        body: bytes | None,
        headers: Mapping[str, str],
    ) -> HttpResponse:
        self.calls.append((method, url))
        self.requests.append((method, url, body, dict(headers)))
        if self.events is not None:
            self.events.append(f"http:{url.rsplit('/', 1)[-1]}")
        if self.failure is not None:
            failure = self.failure
            self.failure = None
            raise failure
        if url.endswith("/health"):
            payload = {"status": "ok", "asr_ready": True, "tts_ready": True}
        elif url.endswith("/readyz"):
            payload = {"ready": True}
        elif url.endswith("/v1/models"):
            payload = {"object": "list", "data": [{"id": "speechrail/qwen3-asr-1.7b"}]}
        elif url.endswith("/v1/audio/speech"):
            return HttpResponse(status_code=200, body=self.tts_body)
        else:
            payload = {"text": "secret transcript"}
        return HttpResponse(status_code=200, body=json.dumps(payload).encode())


class _FakeResourceMonitor(ResourceMonitor):
    def __init__(
        self,
        events: list[str],
        *,
        result: Mapping[str, object] | None = None,
        start_error: BaseException | None = None,
        stop_error: BaseException | None = None,
    ) -> None:
        self.events = events
        self.result = {} if result is None else result
        self.start_error = start_error
        self.stop_error = stop_error
        self.starts = 0
        self.stops = 0

    def start(self) -> None:
        self.starts += 1
        self.events.append("start")
        if self.start_error is not None:
            error = self.start_error
            self.start_error = None
            raise error

    def stop(self) -> Mapping[str, object]:
        self.stops += 1
        self.events.append("stop")
        if self.stop_error is not None:
            error = self.stop_error
            self.stop_error = None
            raise error
        return self.result


class _FakeClock:
    def __init__(self) -> None:
        self.value = 0.0

    def __call__(self) -> float:
        self.value += 0.5
        return self.value


def _manifest(tmp_path: Path) -> tuple[Path, Path]:
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"fixture")
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "fixtures": [
                    {
                        "id": "fixture-1",
                        "path": str(audio),
                        "kind": "asr",
                        "language": "zh",
                    }
                ],
                "model_identity": {
                    "model": "speechrail/qwen3-asr-1.7b",
                    "variant": "asr",
                    "quantization": {"bits": 8, "group_size": 64, "format": "mlx"},
                    "real": True,
                },
                "quality": {
                    "status": "passed",
                    "real": True,
                    "independent": True,
                    "source": "human_eval",
                },
            }
        ),
        encoding="utf-8",
    )
    return manifest, audio


def _dependencies(runner: _FakeHttpRunner) -> BenchmarkDependencies:
    return BenchmarkDependencies(
        http_runner=runner,
        system_sampler=lambda: {
            "hardware": {"real": True, "chip": "Apple M1", "architecture": "arm64"},
            "os": {"name": "macOS", "version": "15.6"},
            "memory": {"physical_bytes": 8 * 1024**3},
            "process_samples": [
                {
                    "at": 1.0,
                    "processes": [
                        {
                            "pid": 10,
                            "start_time_ns": 100,
                            "rss_bytes": 100,
                            "phys_footprint_bytes": 200,
                        }
                    ],
                },
                {
                    "at": 2.0,
                    "processes": [
                        {
                            "pid": 10,
                            "start_time_ns": 100,
                            "rss_bytes": 120,
                            "phys_footprint_bytes": 240,
                        }
                    ],
                },
            ],
        },
        clock=_FakeClock(),
        ffprobe=lambda _: 2.5,
    )


def _monitor_result() -> Mapping[str, object]:
    return {
        "hardware": {
            "real": True,
            "source": "monitor",
            "chip": "Apple M2",
            "architecture": "arm64",
        },
        "os": {"name": "macOS", "version": "15.6"},
        "memory": {"physical_bytes": 12 * 1024**3},
        "process_samples": [
            {
                "at": 1.0,
                "processes": [
                    {
                        "pid": 20,
                        "start_time_ns": 200,
                        "rss_bytes": 300,
                        "phys_footprint_bytes": 400,
                    }
                ],
            }
        ],
        "resource_sampler": {
            "available": True,
            "real": True,
            "source": "monitor",
        },
    }


def _with_monitor(
    runner: _FakeHttpRunner, monitor: _FakeResourceMonitor
) -> BenchmarkDependencies:
    base = _dependencies(runner)
    return BenchmarkDependencies(
        http_runner=base.http_runner,
        system_sampler=base.system_sampler,
        clock=base.clock,
        ffprobe=base.ffprobe,
        monitor=monitor,
    )


def test_resource_monitor_wraps_public_calls_and_stop_result(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    events: list[str] = []
    runner = _FakeHttpRunner(events=events)
    monitor = _FakeResourceMonitor(events, result=_monitor_result())

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_with_monitor(runner, monitor),
    )

    assert events[0] == "start"
    assert events[-1] == "stop"
    assert monitor.starts == 1
    assert monitor.stops == 1
    assert result["hardware"]["chip"] == "Apple M2"
    assert result["resources"]["simultaneous_peak"]["phys_footprint_bytes"] == 400


def test_resource_monitor_start_failure_sends_no_http(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    events: list[str] = []
    runner = _FakeHttpRunner(events=events)
    monitor = _FakeResourceMonitor(
        events,
        start_error=RuntimeError("start-secret"),
    )

    with pytest.raises(ValueError, match="resource monitor start failed") as error:
        run_profile_benchmark(
            "http://127.0.0.1:8201",
            manifest,
            profile="light",
            phase="quality",
            dependencies=_with_monitor(runner, monitor),
        )

    assert runner.calls == []
    assert monitor.starts == 1
    assert monitor.stops == 0
    assert "start-secret" not in str(error.value)


def test_resource_monitor_stops_after_http_runner_failure(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    events: list[str] = []
    runner = _FakeHttpRunner(events=events, failure=RuntimeError("request-secret"))
    monitor = _FakeResourceMonitor(events, result=_monitor_result())

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_with_monitor(runner, monitor),
    )

    assert monitor.stops == 1
    assert events[-1] == "stop"
    assert result["release_pass"] is False
    assert "request-secret" not in json.dumps(result)


def test_resource_monitor_stop_failure_marks_incomplete_without_message(
    tmp_path: Path,
) -> None:
    manifest, _ = _manifest(tmp_path)
    events: list[str] = []
    runner = _FakeHttpRunner(events=events)
    monitor = _FakeResourceMonitor(
        events,
        result=_monitor_result(),
        stop_error=RuntimeError("stop-secret"),
    )

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_with_monitor(runner, monitor),
    )

    assert monitor.stops == 1
    assert result["resources"]["sampling_complete"] is False
    assert result["resources"]["monitor"]["status"] == "incomplete"
    assert result["release_pass"] is False
    assert "stop-secret" not in json.dumps(result)


def test_resource_monitor_without_samples_is_marked_incomplete(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    runner = _FakeHttpRunner()
    monitor = _FakeResourceMonitor(
        [],
        result={
            "hardware": {
                "real": True,
                "source": "monitor",
                "chip": "Apple M2",
                "architecture": "arm64",
            },
            "memory": {"physical_bytes": 12 * 1024**3},
            "process_samples": [],
        },
    )

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_with_monitor(runner, monitor),
    )

    assert result["resources"]["sampling_complete"] is False
    assert result["resources"]["monitor"]["status"] == "incomplete"


def test_request_base_exception_survives_monitor_stop_failure(tmp_path: Path) -> None:
    class CancelledLike(BaseException):
        pass

    manifest, _ = _manifest(tmp_path)
    events: list[str] = []
    runner = _FakeHttpRunner(
        events=events,
        failure=CancelledLike("cancelled-request"),
    )
    monitor = _FakeResourceMonitor(
        events,
        stop_error=RuntimeError("stop-secret"),
    )

    with pytest.raises(CancelledLike, match="cancelled-request"):
        run_profile_benchmark(
            "http://127.0.0.1:8201",
            manifest,
            profile="light",
            phase="quality",
            dependencies=_with_monitor(runner, monitor),
        )

    assert monitor.starts == 1
    assert monitor.stops == 1
    assert events[-1] == "stop"


def test_injected_monitor_never_releases_even_with_passed_manifest(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["phase_evidence"] = {
        phase: {"status": "passed", "real": True, "source": "operator"}
        for phase in required_phases("light")
    }
    payload["soak"] = {"status": "passed", "real": True, "source": "operator"}
    payload["switch"] = {"status": "passed", "real": True, "source": "operator"}
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    events: list[str] = []
    runner = _FakeHttpRunner(events=events)
    monitor = _FakeResourceMonitor(events, result=_monitor_result())

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_with_monitor(runner, monitor),
    )

    assert result["evidence_mode"] == "injected"
    assert result["release_pass"] is False
    assert "injected dependencies are not real evidence" in result["release_reasons"]


def test_required_phases_are_profile_specific_and_unknown_is_fail_closed() -> None:
    light = required_phases("light")
    assert {"m1_air_8gb", "quality", "cold", "warm", "soak", "switch"} <= light
    assert PROFILE_DEVICE_PHASES["balanced"] in required_phases("balanced")
    assert PROFILE_DEVICE_PHASES["quality"] in required_phases("quality")

    with pytest.raises(ValueError, match="unknown profile"):
        required_phases("experimental")


@pytest.mark.parametrize(
    "url",
    [
        "ftp://127.0.0.1:8201",
        "file:///tmp/speechrail",
        "http://example.com:8201",
        "http://user:password@127.0.0.1:8201",
        "http://127.0.0.1:8201?token=secret",
    ],
)
def test_validate_base_url_rejects_non_loopback_credentials_and_query(url: str) -> None:
    with pytest.raises(ValueError):
        validate_base_url(url)


def test_manifest_must_be_external_and_audio_must_be_local(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    inside = repo / "manifest.json"
    inside.write_text("[]", encoding="utf-8")
    with pytest.raises(ValueError, match="outside"):
        load_manifest(inside, repository_root=repo)

    external = tmp_path / "external.json"
    external.write_text(
        json.dumps([{"id": "remote", "path": "https://example.test/audio.wav"}]),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match=r"URL|audio"):
        load_manifest(external, repository_root=repo)

    with pytest.raises(ValueError, match="does not exist"):
        load_manifest(tmp_path / "missing.json", repository_root=repo)


@pytest.mark.parametrize("fixture_id", ["/private/token", "../token", "token with spaces"])
def test_manifest_rejects_fixture_ids_that_could_leak_private_metadata(
    tmp_path: Path, fixture_id: str
) -> None:
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"fixture")
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps({"fixtures": [{"id": fixture_id, "path": str(audio)}]}),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="opaque identifier"):
        load_manifest(manifest, repository_root=tmp_path / "repo")


def test_manifest_rejects_non_language_labels_that_could_leak_tokens(tmp_path: Path) -> None:
    audio = tmp_path / "fixture.wav"
    audio.write_bytes(b"fixture")
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            {"fixtures": [{"id": "fixture-1", "language": "secret-token", "path": str(audio)}]}
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="language"):
        load_manifest(manifest, repository_root=tmp_path / "repo")


def test_output_path_cannot_overwrite_existing_file(tmp_path: Path) -> None:
    output = tmp_path / "result.json"
    output.write_text("{}", encoding="utf-8")
    with pytest.raises(ValueError, match="overwrite"):
        validate_output_path(output)


def test_asr_multipart_uses_extension_mime_and_stable_model(tmp_path: Path) -> None:
    manifest, audio = _manifest(tmp_path)
    audio_mp3 = audio.with_suffix(".mp3")
    audio_mp3.write_bytes(audio.read_bytes())
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["fixtures"][0]["path"] = str(audio_mp3)
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    runner = _FakeHttpRunner()

    run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    request = next(item for item in runner.requests if item[1].endswith("/v1/audio/transcriptions"))
    body = request[2]
    assert body is not None
    assert b'name="model"' in body and b"whisper-1" in body
    assert b'filename="fixture.mp3"' in body
    assert b"Content-Type: audio/mpeg" in body

    audio_unknown = audio.with_suffix(".bin")
    audio_unknown.write_bytes(audio.read_bytes())
    payload["fixtures"][0]["path"] = str(audio_unknown)
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    unknown_runner = _FakeHttpRunner()
    run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(unknown_runner),
    )
    unknown_request = next(
        item
        for item in unknown_runner.requests
        if item[1].endswith("/v1/audio/transcriptions")
    )
    assert b"Content-Type: application/octet-stream" in (unknown_request[2] or b"")


def test_tts_rtf_uses_valid_returned_pcm_duration(tmp_path: Path) -> None:
    manifest, audio = _manifest(tmp_path)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["fixtures"][0] = {
        "id": "tts-1",
        "path": str(audio),
        "kind": "tts",
        "text": "hello",
    }
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    runner = _FakeHttpRunner(tts_body=b"\0" * (24_000 * 2))

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    fixture = result["fixtures"][0]
    assert fixture["actual_audio_seconds"] == 1.0
    assert fixture["duration_source"] == "pcm_24khz_mono_pcm16"
    assert fixture["rtf"] == 0.5
    assert fixture["inference_observed"] is True
    request = next(item for item in runner.requests if item[1].endswith("/v1/audio/speech"))
    assert b'"model": "tts-1"' in (request[2] or b"")


@pytest.mark.parametrize("pcm", [b"", b"\0\0\0"])
def test_tts_empty_or_odd_pcm_is_not_success(tmp_path: Path, pcm: bytes) -> None:
    manifest, audio = _manifest(tmp_path)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["fixtures"][0].update({"kind": "tts", "text": "hello", "path": str(audio)})
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    runner = _FakeHttpRunner(tts_body=pcm)

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    fixture = result["fixtures"][0]
    assert fixture["inference_observed"] is False
    assert fixture["actual_audio_seconds"] is None
    assert fixture["rtf"] is None


def test_auth_header_reads_environment_without_redacting_into_result(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest, _ = _manifest(tmp_path)
    secret = "unit-token-" + os.urandom(8).hex()
    monkeypatch.setenv("SPEECHRAIL_API_KEY", secret)
    assert build_auth_headers("explicit-token") == {"Authorization": "Bearer explicit-token"}
    runner = _FakeHttpRunner()

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    assert runner.requests
    assert all(request[3].get("Authorization") == f"Bearer {secret}" for request in runner.requests)
    assert secret not in json.dumps(result)


def test_explicit_auth_header_rejects_header_injection_characters() -> None:
    with pytest.raises(ValueError, match="invalid characters"):
        build_auth_headers("bad\nkey")


def test_auth_header_discovers_private_app_home_without_environment_key(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    config = tmp_path / "config" / ".env"
    config.parent.mkdir(parents=True)
    config.write_text('SPEECHRAIL_API_KEY="managed-key"\n', encoding="utf-8")
    config.chmod(0o600)
    monkeypatch.delenv("SPEECHRAIL_API_KEY", raising=False)

    assert build_auth_headers(app_home=tmp_path) == {
        "Authorization": "Bearer managed-key"
    }


def test_benchmark_auth_failure_stops_before_inference_request(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    delegate = _FakeHttpRunner()

    def runner(
        method: str,
        url: str,
        body: bytes | None,
        headers: Mapping[str, str],
    ) -> HttpResponse:
        if url.endswith("/v1/jobs/__speechrail_benchmark_auth_probe__"):
            return HttpResponse(status_code=401)
        return delegate(method, url, body, headers)

    with pytest.raises(ValueError, match="server rejected benchmark authentication"):
        run_profile_benchmark(
            "http://127.0.0.1:8201",
            manifest,
            profile="light",
            phase="quality",
            dependencies=_dependencies(runner),
        )

    assert delegate.requests == []


def test_default_sampler_keeps_fully_passed_manifest_closed(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["phase_evidence"] = {
        phase: {"status": "passed", "real": True, "source": "operator"}
        for phase in required_phases("light")
    }
    payload["soak"] = {"status": "passed", "real": True, "source": "operator"}
    payload["switch"] = {"status": "passed", "real": True, "source": "operator"}
    manifest.write_text(json.dumps(payload), encoding="utf-8")
    runner = _FakeHttpRunner()
    dependencies = BenchmarkDependencies(
        http_runner=runner,
        ffprobe=lambda _: 2.5,
        clock=_dependencies(runner).clock,
    )

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=dependencies,
    )

    assert result["release_pass"] is False
    assert any("default process sampler" in reason for reason in result["release_reasons"])
    assert result["resources"]["sampler"]["source"] == "not_implemented"


def test_write_result_creates_private_file_without_overwrite(tmp_path: Path) -> None:
    output = tmp_path / "result.json"
    write_result({"release_pass": False}, output)
    assert S_IMODE(output.stat().st_mode) == 0o600
    with pytest.raises(ValueError, match="overwrite"):
        write_result({"release_pass": False}, output)


def test_benchmark_result_is_redacted_and_uses_public_api_with_actual_duration(
    tmp_path: Path,
) -> None:
    manifest, audio = _manifest(tmp_path)
    runner = _FakeHttpRunner()

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    assert result["schema_version"] == 1
    assert result["phase"] == "quality"
    assert result["fixtures"][0]["actual_audio_seconds"] == 2.5
    assert result["fixtures"][0]["duration_source"] == "ffprobe"
    assert result["resources"]["simultaneous_peak"]["phys_footprint_bytes"] == 240
    assert result["quality"]["real"] is True
    assert result["release_pass"] is False
    assert any("required phase" in reason for reason in result["release_reasons"])
    assert all(path not in url for _, url in runner.calls for path in (str(audio),))
    encoded = json.dumps(result, ensure_ascii=False)
    assert str(audio) not in encoded
    assert "secret transcript" not in encoded
    assert all(url.startswith("http://127.0.0.1:8201") for _, url in runner.calls)


def test_release_gate_rejects_generic_architecture_as_chip_identity(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    runner = _FakeHttpRunner()
    base = _dependencies(runner)
    dependencies = BenchmarkDependencies(
        http_runner=base.http_runner,
        system_sampler=lambda: {
            "hardware": {
                "real": True,
                "source": "sample_resources",
                "chip": "arm",
                "architecture": "arm64",
            },
            "os": {"name": "macOS", "version": "15.6"},
            "memory": {"physical_bytes": 8 * 1024**3},
            "process_samples": base.system_sampler().get("process_samples", []),
        },
        clock=base.clock,
        ffprobe=base.ffprobe,
    )

    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=dependencies,
    )

    assert result["release_pass"] is False
    assert "missing real hardware identity" in result["release_reasons"]


def test_injected_dependencies_cannot_be_recorded_as_release_evidence(tmp_path: Path) -> None:
    manifest, _ = _manifest(tmp_path)
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    payload["phase_evidence"] = {
        phase: {"status": "passed", "real": True, "source": "operator"}
        for phase in required_phases("light")
    }
    payload["soak"] = {"status": "passed", "real": True, "source": "operator"}
    payload["switch"] = {"status": "passed", "real": True, "source": "operator"}
    manifest.write_text(json.dumps(payload), encoding="utf-8")

    runner = _FakeHttpRunner()
    result = run_profile_benchmark(
        "http://127.0.0.1:8201",
        manifest,
        profile="light",
        phase="quality",
        dependencies=_dependencies(runner),
    )

    assert result["evidence_mode"] == "injected"
    assert result["release_pass"] is False
    assert "injected dependencies are not real evidence" in result["release_reasons"]


def test_main_rejects_invalid_base_url_without_creating_output(tmp_path: Path) -> None:
    output = tmp_path / "result.json"
    code = main(
        [
            "--base-url",
            "http://example.com",
            "--manifest",
            str(tmp_path / "manifest.json"),
            "--profile",
            "light",
            "--phase",
            "quality",
            "--output",
            str(output),
        ]
    )
    assert code != 0
    assert not output.exists()
