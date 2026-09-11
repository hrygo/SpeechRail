"""Measure ASR||TTS heavy-compute overlap through the public HTTP API.

C1 starts one long TTS request and fires ``--concurrency`` concurrent ASR
requests ``--delay-seconds`` later; C2 reverses the order (ASR wave first, TTS
after the delay).  The governor active-request peaks (sampled from ``/metrics``
inside each scenario window), per-request latency, and scenario wall time form
the A/B signal for ``SPEECHRAIL_ALLOW_HEAVY_OVERLAP``: ON admits ASR while TTS
is active (batch peak >= 2), OFF refuses it (batch peak == 1).  Every scenario
runs under a fresh ``ProcessResourceMonitor``; one warm ASR and one warm TTS
precede the measured windows and are excluded from all metrics.  The result is
written as one sanitized, repo-external JSON evidence file (O_EXCL, mode 0600).

Usage:
  uv run python examples/perf/bench_overlap.py \
    --base-url http://127.0.0.1:8201 \
    --manifest "$HOME/Library/Application Support/SpeechRail/benchmarks/manifest.json" \
    --app-home "$HOME/Library/Application Support/SpeechRail" \
    --output /tmp/overlap-arm.json
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType

try:
    from .benchmark_http import (
        Clock,
        HttpRunner,
        _default_http_runner,
        _json_body,
        _multipart_body,
        _public_url,
        build_auth_headers,
        ensure_authentication,
        validate_base_url,
    )
    from .benchmark_manifest import BenchmarkInputError, Fixture, load_manifest
    from .benchmark_resources import (
        ProcessResourceMonitor,
        ResourceMonitor,
        _hardware_and_os,
        _normalise_resources,
        _sanitize_mapping,
        _sanitize_model_identity,
    )
    from .benchmark_runner import validate_output_path, write_result
except ImportError:  # pragma: no cover - exercised when run as a script
    from benchmark_http import (  # type: ignore[no-redef]
        Clock,
        HttpRunner,
        _default_http_runner,
        _json_body,
        _multipart_body,
        _public_url,
        build_auth_headers,
        ensure_authentication,
        validate_base_url,
    )
    from benchmark_manifest import (  # type: ignore[no-redef]
        BenchmarkInputError,
        Fixture,
        load_manifest,
    )
    from benchmark_resources import (  # type: ignore[no-redef]
        ProcessResourceMonitor,
        ResourceMonitor,
        _hardware_and_os,
        _normalise_resources,
        _sanitize_mapping,
        _sanitize_model_identity,
    )
    from benchmark_runner import validate_output_path, write_result  # type: ignore[no-redef]

SCHEMA = "speechrail-bench-overlap-v1"
TOOL = "speechrail-bench-overlap"
SCENARIOS = ("C1", "C2")

_MONITOR_INTERVAL_SECONDS = 0.25
_METRICS_INTERVAL_SECONDS = 0.1
_SAMPLER_JOIN_TIMEOUT_SECONDS = 5.0


@dataclass(frozen=True, slots=True)
class OverlapDependencies:
    """Injectable side effects so contract tests never need a service or model."""

    http_runner: HttpRunner | None = None
    clock: Clock = time.monotonic
    sleep: Callable[[float], None] = time.sleep
    monitor_factory: Callable[[], ResourceMonitor] | None = None
    metrics_interval_seconds: float = _METRICS_INTERVAL_SECONDS


def _default_monitor_factory() -> ResourceMonitor:
    return ProcessResourceMonitor(interval_seconds=_MONITOR_INTERVAL_SECONDS)


def _select_fixture(fixtures: Sequence[Fixture], fixture_id: str, kind: str) -> Fixture:
    for fixture in fixtures:
        if fixture.id != fixture_id:
            continue
        if fixture.kind != kind:
            raise BenchmarkInputError(
                f"fixture {fixture_id} has kind {fixture.kind}, expected {kind}"
            )
        return fixture
    raise BenchmarkInputError(f"fixture id not found in manifest: {fixture_id}")


def _normalise_scenarios(values: Sequence[str]) -> tuple[str, ...]:
    names = tuple(str(value).strip().upper() for value in values)
    if not names:
        raise BenchmarkInputError("at least one scenario is required")
    if len(set(names)) != len(names):
        raise BenchmarkInputError("duplicate scenario ids are not allowed")
    for name in names:
        if name not in SCENARIOS:
            raise BenchmarkInputError(f"unknown scenario: {name}")
    return names


def _fire(
    fixture: Fixture,
    *,
    base_url: str,
    runner: HttpRunner,
    clock: Clock,
    auth_headers: Mapping[str, str],
) -> dict[str, object]:
    """Issue one public-API request and record only redacted fields."""
    if fixture.kind == "asr":
        body, content_headers = _multipart_body(fixture)
        endpoint = "/v1/audio/transcriptions"
    else:
        body = json.dumps(
            {
                "model": "tts-1",
                "input": fixture.text,
                "voice": fixture.voice,
                "response_format": "pcm",
            }
        ).encode("utf-8")
        content_headers = {"Content-Type": "application/json"}
        endpoint = "/v1/audio/speech"
    headers = dict(auth_headers)
    headers.update(content_headers)
    started = clock()
    status_code: int | None = None
    response_bytes = 0
    request_id_present = False
    try:
        response = runner("POST", _public_url(base_url, endpoint), body, headers)
        status_code = response.status_code
        response_bytes = len(response.body)
        request_id_present = bool(response.headers.get("x-request-id"))
    except Exception:
        status_code = None
    return {
        "kind": fixture.kind,
        "fixture": fixture.id,
        "status_code": status_code,
        "success": status_code is not None and 200 <= status_code < 300,
        "latency_seconds": max(0.0, clock() - started),
        "response_bytes": response_bytes,
        "request_id_present": request_id_present,
    }


def _as_count(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return int(value)


def _active_requests(
    runner: HttpRunner,
    base_url: str,
    auth_headers: Mapping[str, str],
) -> tuple[int | None, int | None]:
    """Read the governor batch/realtime active gauges from the JSON metrics view."""

    headers = dict(auth_headers)
    headers["Accept"] = "application/json"
    try:
        response = runner("GET", _public_url(base_url, "/metrics"), None, headers)
    except Exception:
        return None, None
    if not 200 <= response.status_code < 300:
        return None, None
    active = _json_body(response).get("active_requests")
    if not isinstance(active, Mapping):
        return None, None
    return _as_count(active.get("batch")), _as_count(active.get("realtime"))


class _MetricsSampler:
    """Poll ``/metrics`` during one scenario window and keep the per-class maxima."""

    def __init__(
        self,
        runner: HttpRunner,
        base_url: str,
        auth_headers: Mapping[str, str],
        *,
        interval_seconds: float,
    ) -> None:
        self._runner = runner
        self._base_url = base_url
        self._headers = auth_headers
        self._interval = interval_seconds
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._batch_peak: int | None = None
        self._realtime_peak: int | None = None
        self._samples = 0
        self._errors = 0

    def _scrape(self) -> None:
        batch, realtime = _active_requests(self._runner, self._base_url, self._headers)
        if batch is None and realtime is None:
            self._errors += 1
            return
        self._samples += 1
        if batch is not None:
            previous = self._batch_peak
            self._batch_peak = batch if previous is None else max(previous, batch)
        if realtime is not None:
            previous = self._realtime_peak
            self._realtime_peak = realtime if previous is None else max(previous, realtime)

    def start(self) -> None:
        self._scrape()
        self._thread = threading.Thread(
            target=self._run,
            name="speechrail-overlap-metrics",
            daemon=True,
        )
        self._thread.start()

    def _run(self) -> None:
        while not self._stop.is_set():
            self._stop.wait(self._interval)
            if self._stop.is_set():
                break
            self._scrape()

    def stop(self) -> dict[str, object]:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=_SAMPLER_JOIN_TIMEOUT_SECONDS)
        self._scrape()
        return {
            "batch_active_peak": self._batch_peak,
            "realtime_active_peak": self._realtime_peak,
            "samples": self._samples,
            "errors": self._errors,
            "available": self._samples > 0,
        }


def _waves(
    name: str, *, concurrency: int, delay_seconds: float
) -> list[tuple[float, list[str]]]:
    asr_wave = ["asr"] * concurrency
    if name == "C1":
        return [(0.0, ["tts"]), (delay_seconds, asr_wave)]
    return [(0.0, asr_wave), (delay_seconds, ["tts"])]


def _run_scenario(
    name: str,
    *,
    asr: Fixture,
    tts: Fixture,
    base_url: str,
    runner: HttpRunner,
    deps: OverlapDependencies,
    auth_headers: Mapping[str, str],
    concurrency: int,
    delay_seconds: float,
) -> dict[str, object]:
    """Execute one request schedule inside a fresh resource-monitor window."""

    monitor = (deps.monitor_factory or _default_monitor_factory)()
    try:
        monitor.start()
    except Exception as exc:
        raise BenchmarkInputError("resource monitor start failed") from exc
    sampler = _MetricsSampler(
        runner,
        base_url,
        auth_headers,
        interval_seconds=deps.metrics_interval_seconds,
    )
    sampler.start()
    started = deps.clock()
    requests: list[dict[str, object]] = []
    error: str | None = None
    raw: Mapping[str, object] = MappingProxyType({})
    monitor_stop_error: str | None = None
    try:
        try:
            pending: list[Future[dict[str, object]]] = []
            with ThreadPoolExecutor(
                max_workers=concurrency + 1,
                thread_name_prefix="speechrail-overlap",
            ) as pool:
                waves = _waves(name, concurrency=concurrency, delay_seconds=delay_seconds)
                for wait, kinds in waves:
                    if wait > 0:
                        deps.sleep(wait)
                    pending.extend(
                        pool.submit(
                            _fire,
                            asr if kind == "asr" else tts,
                            base_url=base_url,
                            runner=runner,
                            clock=deps.clock,
                            auth_headers=auth_headers,
                        )
                        for kind in kinds
                    )
                requests.extend(future.result() for future in pending)
        except Exception as exc:
            error = type(exc).__name__
        wall_seconds = max(0.0, deps.clock() - started)
    finally:
        governor_peak = sampler.stop()
        try:
            stopped = monitor.stop()
            if isinstance(stopped, Mapping):
                raw = dict(stopped)
            else:
                monitor_stop_error = "invalid_result"
        except BaseException:
            monitor_stop_error = "stop_error"

    resources = _normalise_resources(raw)
    if monitor_stop_error is not None:
        resources["monitor"] = {"status": "incomplete", "error": monitor_stop_error}
        resources["sampling_complete"] = False
    hardware, operating_system, memory = _hardware_and_os(raw)
    return {
        "name": name,
        "wall_seconds": wall_seconds,
        "requests": requests,
        "failed_requests": sum(1 for item in requests if item.get("success") is not True),
        "error": error,
        "governor_peak": governor_peak,
        "resources": resources,
        "hardware": hardware,
        "os": operating_system,
        "memory": memory,
    }


def run_overlap_benchmark(
    base_url: str,
    manifest: Path,
    *,
    asr_fixture_id: str,
    tts_fixture_id: str,
    concurrency: int,
    delay_seconds: float,
    scenarios: Sequence[str],
    app_home: Path | None = None,
    dependencies: OverlapDependencies | None = None,
) -> dict[str, object]:
    """Run the warm-up plus each selected overlap scenario and return sanitized evidence."""

    normalized_base = validate_base_url(base_url)
    if concurrency < 1 or concurrency > 32:
        raise BenchmarkInputError("concurrency must be between 1 and 32")
    if delay_seconds < 0:
        raise BenchmarkInputError("delay seconds must not be negative")
    names = _normalise_scenarios(scenarios)
    loaded = load_manifest(manifest)
    asr = _select_fixture(loaded.fixtures, asr_fixture_id, "asr")
    tts = _select_fixture(loaded.fixtures, tts_fixture_id, "tts")
    deps = OverlapDependencies() if dependencies is None else dependencies
    runner = _default_http_runner if deps.http_runner is None else deps.http_runner
    auth_headers = build_auth_headers(app_home=app_home)
    ensure_authentication(runner, normalized_base, auth_headers)

    asr_warmup = _fire(
        asr,
        base_url=normalized_base,
        runner=runner,
        clock=deps.clock,
        auth_headers=auth_headers,
    )
    tts_warmup = _fire(
        tts,
        base_url=normalized_base,
        runner=runner,
        clock=deps.clock,
        auth_headers=auth_headers,
    )

    scenario_results = [
        _run_scenario(
            name,
            asr=asr,
            tts=tts,
            base_url=normalized_base,
            runner=runner,
            deps=deps,
            auth_headers=auth_headers,
            concurrency=concurrency,
            delay_seconds=delay_seconds,
        )
        for name in names
    ]
    return {
        "schema_version": 1,
        "schema": SCHEMA,
        "tool": TOOL,
        "evidence_mode": "injected" if dependencies is not None else "real",
        "base_url": normalized_base,
        "config": {
            "asr_fixture_id": asr.id,
            "tts_fixture_id": tts.id,
            "concurrency": concurrency,
            "delay_seconds": delay_seconds,
            "scenarios": list(names),
        },
        "model_identity": _sanitize_model_identity(loaded.model_identity),
        "software": _sanitize_mapping(loaded.software),
        "warmup": {
            "asr_status_code": asr_warmup["status_code"],
            "tts_status_code": tts_warmup["status_code"],
        },
        "scenarios": scenario_results,
    }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument(
        "--app-home",
        type=Path,
        help="managed SpeechRail app home used for automatic API-key discovery",
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--asr-fixture-id", default="asr10-w01")
    parser.add_argument("--tts-fixture-id", default="tts-long-w01")
    parser.add_argument("--concurrency", type=int, default=3)
    parser.add_argument("--delay-seconds", type=float, default=1.5)
    parser.add_argument(
        "--scenario",
        action="append",
        dest="scenarios",
        choices=SCENARIOS,
        help="repeatable; defaults to both C1 and C2",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    scenarios: Sequence[str] = args.scenarios if args.scenarios else SCENARIOS
    try:
        destination = validate_output_path(args.output)
        result = run_overlap_benchmark(
            args.base_url,
            args.manifest,
            asr_fixture_id=args.asr_fixture_id,
            tts_fixture_id=args.tts_fixture_id,
            concurrency=args.concurrency,
            delay_seconds=args.delay_seconds,
            scenarios=scenarios,
            app_home=args.app_home,
        )
        write_result(result, destination)
        print(
            f"wrote {destination} scenarios={len(scenarios)} "
            f"evidence_mode={result['evidence_mode']}",
            file=sys.stderr,
        )
    except (BenchmarkInputError, OSError, TypeError, ValueError) as exc:
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
