"""Run one benchmark phase and persist sanitized evidence."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from collections.abc import Mapping, Sequence
from contextlib import suppress
from pathlib import Path
from types import MappingProxyType

try:
    from .benchmark_http import (
        _default_ffprobe,
        _default_http_runner,
        _fixture_request,
        _probe,
        build_auth_headers,
        validate_base_url,
    )
    from .benchmark_manifest import (
        PHASES,
        PROFILE_DEVICE_PHASES,
        BenchmarkInputError,
        load_manifest,
        required_phases,
    )
    from .benchmark_resources import (
        BenchmarkDependencies,
        ProcessResourceMonitor,
        _default_system_sampler,
        _hardware_and_os,
        _model_ids,
        _normalise_resources,
        _release_gate,
        _sanitize_evidence,
        _sanitize_mapping,
        _sanitize_model_identity,
    )
except ImportError:  # pragma: no cover - exercised when run as a script
    from benchmark_http import (  # type: ignore[no-redef]
        _default_ffprobe,
        _default_http_runner,
        _fixture_request,
        _probe,
        build_auth_headers,
        validate_base_url,
    )
    from benchmark_manifest import (  # type: ignore[no-redef]
        PHASES,
        PROFILE_DEVICE_PHASES,
        BenchmarkInputError,
        load_manifest,
        required_phases,
    )
    from benchmark_resources import (  # type: ignore[no-redef]
        BenchmarkDependencies,
        ProcessResourceMonitor,
        _default_system_sampler,
        _hardware_and_os,
        _model_ids,
        _normalise_resources,
        _release_gate,
        _sanitize_evidence,
        _sanitize_mapping,
        _sanitize_model_identity,
    )


def validate_output_path(output: Path) -> Path:
    """Resolve a new output path and reject overwrite or a non-directory parent."""

    resolved = Path(output).expanduser().absolute()
    if resolved.exists() or resolved.is_symlink():
        raise BenchmarkInputError("output would overwrite an existing file")
    if not resolved.parent.is_dir():
        raise BenchmarkInputError("output parent directory does not exist")
    return resolved


def run_profile_benchmark(
    base_url: str,
    manifest: Path,
    *,
    profile: str,
    phase: str,
    dependencies: BenchmarkDependencies | None = None,
) -> dict[str, object]:
    """Run one evidence collection phase through the public HTTP API."""

    normalized_base = validate_base_url(base_url)
    normalized_profile = profile.strip().lower() if isinstance(profile, str) else ""
    required_phases(normalized_profile)
    normalized_phase = phase.strip().lower() if isinstance(phase, str) else ""
    if normalized_phase not in PHASES and normalized_phase not in PROFILE_DEVICE_PHASES.values():
        raise BenchmarkInputError(f"unknown benchmark phase: {phase}")
    loaded = load_manifest(manifest)
    deps = (
        BenchmarkDependencies(monitor=ProcessResourceMonitor())
        if dependencies is None
        else dependencies
    )
    injected_dependencies = dependencies is not None
    auth_headers = build_auth_headers()
    runner = _default_http_runner if deps.http_runner is None else deps.http_runner
    clock = deps.clock
    ffprobe = _default_ffprobe if deps.ffprobe is None else deps.ffprobe
    sampler = _default_system_sampler if deps.system_sampler is None else deps.system_sampler

    monitor = deps.monitor
    default_sampler_used = deps.system_sampler is None and monitor is None
    monitor_started = False
    monitor_result: Mapping[str, object] = MappingProxyType({})
    monitor_stop_error: str | None = None
    if monitor is not None:
        try:
            monitor.start()
        except Exception as exc:
            raise BenchmarkInputError("resource monitor start failed") from exc
        monitor_started = True

    raw_system: Mapping[str, object] = MappingProxyType({})
    try:
        health, health_status = _probe(runner, normalized_base, "/health", auth_headers)
        readyz, readyz_status = _probe(runner, normalized_base, "/readyz", auth_headers)
        models, models_status = _probe(runner, normalized_base, "/v1/models", auth_headers)
        if monitor is None:
            try:
                raw_system = sampler()
            except Exception:
                raw_system = MappingProxyType({})

        fixture_results: list[dict[str, object]] = []
        for fixture in loaded.fixtures:
            try:
                duration: float | None = None
                if fixture.kind == "asr":
                    duration = float(ffprobe(fixture.path))
                    if not math.isfinite(duration) or duration <= 0:
                        raise ValueError("duration must be positive")
                fixture_results.append(
                    _fixture_request(
                        fixture,
                        base_url=normalized_base,
                        runner=runner,
                        clock=clock,
                        duration=duration,
                        auth_headers=auth_headers,
                    )
                )
            except (OSError, ValueError, TypeError, BenchmarkInputError) as exc:
                fixture_results.append(
                    {
                        "id": fixture.id,
                        "kind": fixture.kind,
                        "language": fixture.language,
                        "actual_audio_seconds": None,
                        "duration_source": None,
                        "latency_seconds": None,
                        "rtf": None,
                        "status_code": None,
                        "inference_observed": False,
                        "measurement_error": type(exc).__name__,
                    }
                )
    finally:
        if monitor_started and monitor is not None:
            try:
                stopped = monitor.stop()
                if isinstance(stopped, Mapping):
                    monitor_result = dict(stopped)
                else:
                    monitor_stop_error = "invalid_result"
            except BaseException:
                monitor_stop_error = "stop_error"

    if monitor is not None:
        raw_system = monitor_result
    hardware, operating_system, memory = _hardware_and_os(raw_system)

    model_identity = dict(loaded.model_identity)
    for source in (health, models):
        candidate = source.get("model_identity")
        if not model_identity and isinstance(candidate, Mapping):
            model_identity = dict(candidate)
    safe_model_identity = _sanitize_model_identity(model_identity)
    safe_hardware = dict(hardware)
    safe_os = dict(operating_system)
    safe_memory = dict(memory)
    safe_phase_evidence = {
        phase_name: _sanitize_evidence(evidence)
        for phase_name, evidence in loaded.phase_evidence.items()
    }
    inference_observed = any(
        item.get("inference_observed") is True for item in fixture_results
    )
    quality = _sanitize_evidence(loaded.quality)
    soak = _sanitize_evidence(loaded.soak)
    switch = _sanitize_evidence(loaded.switch)
    if normalized_phase == "quality" and not quality:
        quality = dict(safe_phase_evidence.get("quality", {}))
    if normalized_phase == "soak" and not soak:
        soak = dict(safe_phase_evidence.get("soak", {}))
    if normalized_phase == "switch" and not switch:
        switch = dict(safe_phase_evidence.get("switch", {}))
    if normalized_phase not in safe_phase_evidence:
        safe_phase_evidence[normalized_phase] = {
            "status": "passed" if inference_observed else "observed",
            "real": safe_hardware.get("real") is True,
            "source": safe_hardware.get("source", "unknown"),
        }

    resources = _normalise_resources(raw_system)
    if monitor_stop_error is not None:
        resources["monitor"] = {"status": "incomplete", "error": monitor_stop_error}
        resources["sampling_complete"] = False
    elif monitor is not None:
        resources["monitor"] = {"status": "complete"}
    release_pass, release_reasons = _release_gate(
        profile=normalized_profile,
        phase=normalized_phase,
        hardware=safe_hardware,
        memory=safe_memory,
        model_identity=safe_model_identity,
        phase_evidence=safe_phase_evidence,
        quality=quality,
        soak=soak,
        switch=switch,
        inference_observed=inference_observed,
        resources_complete=bool(resources["sampling_complete"]),
        injected_dependencies=injected_dependencies,
        default_sampler_used=default_sampler_used,
        monitor_stop_error=monitor_stop_error,
    )

    observed_phases = sorted(safe_phase_evidence)
    if normalized_phase not in observed_phases:
        observed_phases.append(normalized_phase)
        observed_phases.sort()
    return {
        "schema_version": 1,
        "tool": "speechrail-bench-profiles",
        "evidence_mode": "injected" if injected_dependencies else "real",
        "base_url": normalized_base,
        "profile": normalized_profile,
        "phase": normalized_phase,
        "required_phases": sorted(required_phases(normalized_profile)),
        "observed_phases": observed_phases,
        "hardware": safe_hardware,
        "os": safe_os,
        "memory": safe_memory,
        "model_identity": safe_model_identity,
        "software": _sanitize_mapping(loaded.software),
        "service": {
            "health_status": health_status,
            "readyz_status": readyz_status,
            "models_status": models_status,
            "health": {
                key: health[key]
                for key in ("status", "asr_ready", "tts_ready")
                if key in health
            },
            "readyz": {"ready": readyz.get("ready")} if "ready" in readyz else {},
            "models": {
                "object": models.get("object"),
                "ids": _model_ids(models.get("data")),
            },
        },
        "fixtures": fixture_results,
        "resources": resources,
        "quality": quality,
        "soak": soak,
        "switch": switch,
        "phase_evidence": safe_phase_evidence,
        "release_pass": release_pass,
        "release_reasons": release_reasons,
    }


def write_result(result: Mapping[str, object], output: Path) -> Path:
    """Write one new, indented JSON evidence file without overwriting."""

    destination = validate_output_path(output)
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    try:
        descriptor = os.open(destination, flags, 0o600)
    except FileExistsError as exc:
        raise BenchmarkInputError("output would overwrite an existing file") from exc
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
    except Exception:
        with suppress(OSError):
            destination.unlink()
        raise
    return destination


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--phase", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        result = run_profile_benchmark(
            args.base_url,
            args.manifest,
            profile=args.profile,
            phase=args.phase,
        )
        write_result(result, args.output)
    except (BenchmarkInputError, OSError, TypeError, ValueError) as exc:
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    return 0
