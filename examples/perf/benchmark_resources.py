"""Resource sampling, sanitization, and release evidence gates."""

from __future__ import annotations

import os
import platform
import subprocess
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol, cast

try:
    from .benchmark_http import Clock, Ffprobe, HttpRunner
    from .benchmark_manifest import _mapping_or_empty, required_phases
    from .profile_metrics import ProcessIdentity, simultaneous_peak_by_identity
except ImportError:  # pragma: no cover - exercised when run as a script
    from benchmark_http import Clock, Ffprobe, HttpRunner  # type: ignore[no-redef]
    from benchmark_manifest import _mapping_or_empty, required_phases  # type: ignore[no-redef]
    from profile_metrics import (  # type: ignore[no-redef]
        ProcessIdentity,
        simultaneous_peak_by_identity,
    )

_SENSITIVE_KEYS = frozenset(
    {
        "authorization",
        "api_key",
        "apikey",
        "credential",
        "password",
        "secret",
        "token",
        "transcript",
        "text",
        "audio",
        "path",
        "url",
        "uri",
    }
)


type SystemSampler = Callable[[], Mapping[str, object]]


class ResourceMonitor(Protocol):
    """Lifecycle boundary for collecting resources across the whole benchmark."""

    def start(self) -> None:
        """Start sampling before the first public API probe."""
        ...

    def stop(self) -> Mapping[str, object]:
        """Stop sampling and return sanitized-input-compatible raw evidence."""
        ...


@dataclass(frozen=True, slots=True)
class BenchmarkDependencies:
    """Injectable side effects so contract tests never need a service or model."""

    http_runner: HttpRunner | None = None
    system_sampler: SystemSampler | None = None
    monitor: ResourceMonitor | None = None
    clock: Clock = time.monotonic
    ffprobe: Ffprobe | None = None


def _physical_memory_bytes() -> int | None:
    if sys.platform == "darwin":
        try:
            process = subprocess.run(
                ["sysctl", "-n", "hw.memsize"],
                capture_output=True,
                text=True,
                check=True,
            )
            darwin_value = int(process.stdout.strip())
            return darwin_value if darwin_value > 0 else None
        except (OSError, subprocess.SubprocessError, ValueError):
            return None
    try:
        value: int = int(os.sysconf("SC_PHYS_PAGES")) * int(os.sysconf("SC_PAGE_SIZE"))
        return value if value > 0 else None
    except (AttributeError, OSError, ValueError):
        return None


def _default_system_sampler() -> Mapping[str, object]:
    """Collect hardware identity; process samples stay explicit until a sampler supplies them."""

    return {
        "hardware": {
            "real": True,
            "source": "system",
            "architecture": platform.machine() or "unknown",
            "chip": platform.processor() or platform.machine() or "unknown",
        },
        "os": {"name": platform.system() or "unknown", "version": platform.release()},
        "memory": {"physical_bytes": _physical_memory_bytes()},
        "process_samples": [],
        "resource_sampler": {
            "available": False,
            "real": False,
            "source": "not_implemented",
        },
    }

def _safe_scalar(key: str, value: object) -> object:
    lowered = key.lower()
    if any(token in lowered for token in _SENSITIVE_KEYS):
        return None
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return None


def _sanitize_mapping(value: Mapping[str, object]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            continue
        safe = _safe_scalar(key, item)
        if safe is not None or item is None:
            result[key] = safe
    return result


def _sanitize_model_identity(value: Mapping[str, object]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key in ("model", "model_id", "variant", "family", "real", "source", "fingerprint"):
        if key in value:
            safe = _safe_scalar(key, value[key])
            if safe is not None:
                result[key] = safe
    quantization = value.get("quantization")
    if isinstance(quantization, Mapping):
        result["quantization"] = {
            key: quantization[key]
            for key in ("bits", "group_size", "format")
            if key in quantization and _safe_scalar(key, quantization[key]) is not None
        }
    return result


def _sanitize_evidence(value: Mapping[str, object]) -> dict[str, object]:
    allowed = {
        "status",
        "real",
        "source",
        "independent",
        "method",
        "duration_seconds",
        "device",
        "profile",
    }
    return {
        key: _safe_scalar(key, item)
        for key, item in value.items()
        if key in allowed and (_safe_scalar(key, item) is not None or item is None)
    }


def _normalise_resources(raw: Mapping[str, object]) -> dict[str, object]:
    raw_ticks = raw.get("process_samples", raw.get("samples", []))
    sampler = _sanitize_mapping(
        _mapping_or_empty(raw.get("resource_sampler"), label="resource_sampler")
    )
    sanitized_ticks: list[dict[str, object]] = []
    rss_snapshots: list[dict[ProcessIdentity, int]] = []
    footprint_snapshots: list[dict[ProcessIdentity, int]] = []
    paired_snapshots = False
    if isinstance(raw_ticks, Sequence) and not isinstance(raw_ticks, (str, bytes, bytearray)):
        for tick in raw_ticks:
            if not isinstance(tick, Mapping):
                continue
            raw_processes = tick.get("processes", [])
            if not isinstance(raw_processes, Sequence) or isinstance(
                raw_processes, (str, bytes, bytearray)
            ):
                continue
            rss_tick: dict[ProcessIdentity, int] = {}
            footprint_tick: dict[ProcessIdentity, int] = {}
            output_processes: list[dict[str, object]] = []
            for process in raw_processes:
                if not isinstance(process, Mapping):
                    continue
                pid = process.get("pid")
                started = process.get("start_time_ns")
                if (
                    isinstance(pid, bool)
                    or not isinstance(pid, int)
                    or pid < 0
                    or isinstance(started, bool)
                    or not isinstance(started, int)
                    or started < 0
                ):
                    continue
                identity = ProcessIdentity(pid=pid, start_time_ns=started)
                rss = process.get("rss_bytes")
                footprint = process.get("phys_footprint_bytes")
                rss_valid = isinstance(rss, int) and not isinstance(rss, bool) and rss >= 0
                footprint_valid = (
                    isinstance(footprint, int)
                    and not isinstance(footprint, bool)
                    and footprint >= 0
                )
                if rss_valid:
                    rss_tick[identity] = cast(int, rss)
                if footprint_valid:
                    footprint_tick[identity] = cast(int, footprint)
                output_processes.append(
                    {
                        "pid": pid,
                        "start_time_ns": started,
                        "rss_bytes": rss if rss_valid else None,
                        "phys_footprint_bytes": (
                            footprint if footprint_valid else None
                        ),
                    }
                )
            if output_processes:
                at = tick.get("at", tick.get("at_seconds"))
                sanitized_ticks.append(
                    {
                        "at_seconds": at if isinstance(at, (int, float)) else None,
                        "processes": output_processes,
                    }
                )
            if rss_tick:
                rss_snapshots.append(rss_tick)
            if footprint_tick:
                footprint_snapshots.append(footprint_tick)
            if rss_tick and footprint_tick and set(rss_tick) == set(footprint_tick):
                paired_snapshots = True

    def _peak(snapshots: list[dict[ProcessIdentity, int]]) -> int | None:
        if not snapshots:
            return None
        try:
            return cast(int, simultaneous_peak_by_identity(snapshots))
        except (TypeError, ValueError):
            return None

    rss_peak = _peak(rss_snapshots)
    footprint_peak = _peak(footprint_snapshots)
    return {
        "sampler": sampler,
        "samples": sanitized_ticks,
        "simultaneous_peak": {
            "rss_bytes": rss_peak,
            "phys_footprint_bytes": footprint_peak,
        },
        "sampling_complete": bool(
            sanitized_ticks
            and paired_snapshots
            and rss_peak is not None
            and footprint_peak is not None
        ),
    }


def _hardware_and_os(
    raw: Mapping[str, object],
) -> tuple[dict[str, object], dict[str, object], dict[str, object]]:
    hardware = _sanitize_mapping(_mapping_or_empty(raw.get("hardware"), label="hardware"))
    operating_system = _sanitize_mapping(
        _mapping_or_empty(raw.get("os", raw.get("operating_system")), label="os")
    )
    memory_raw = raw.get("memory")
    if isinstance(memory_raw, Mapping):
        memory = _sanitize_mapping(dict(memory_raw))
    elif isinstance(memory_raw, int) and not isinstance(memory_raw, bool):
        memory = {"physical_bytes": memory_raw}
    else:
        memory = {}
    return hardware, operating_system, memory


def _model_ids(value: object) -> list[str]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes, bytearray)):
        return []
    result: list[str] = []
    for item in value:
        if not isinstance(item, Mapping):
            continue
        item_id = item.get("id")
        if isinstance(item_id, str):
            result.append(item_id)
    return result


def _real_evidence(value: Mapping[str, object]) -> bool:
    return value.get("real") is True and str(value.get("source", "")).lower() not in {
        "fake",
        "mock",
        "test",
    }


def _passed_evidence(value: Mapping[str, object]) -> bool:
    status = str(value.get("status", "")).strip().lower()
    return _real_evidence(value) and status in {"ok", "pass", "passed", "complete"}


def _quality_evidence_valid(value: Mapping[str, object]) -> bool:
    source = str(value.get("source", "")).strip().lower()
    if any(
        marker in source for marker in ("asr_self", "self_generated", "synthetic", "generated")
    ):
        return False
    return _passed_evidence(value) and value.get("independent") is True


def _model_identity_complete(value: Mapping[str, object]) -> bool:
    required_strings = ("model", "variant")
    if any(
        not isinstance(value.get(key), str) or not str(value[key]).strip()
        for key in required_strings
    ):
        return False
    quantization = value.get("quantization")
    return isinstance(quantization, Mapping) and bool(quantization)


def _phase_evidence_valid(value: Mapping[str, object]) -> bool:
    status = str(value.get("status", "")).strip().lower()
    return _real_evidence(value) and status not in {"failed", "error", "missing"}


def _release_gate(
    *,
    profile: str,
    phase: str,
    hardware: Mapping[str, object],
    memory: Mapping[str, object],
    model_identity: Mapping[str, object],
    phase_evidence: Mapping[str, Mapping[str, object]],
    quality: Mapping[str, object],
    soak: Mapping[str, object],
    switch: Mapping[str, object],
    inference_observed: bool,
    resources_complete: bool,
    injected_dependencies: bool,
    default_sampler_used: bool,
    monitor_stop_error: str | None,
) -> tuple[bool, list[str]]:
    required = required_phases(profile)
    reasons: list[str] = []
    missing_phases = sorted(
        item for item in required if not _phase_evidence_valid(phase_evidence.get(item, {}))
    )
    if missing_phases:
        reasons.append(f"missing required phase/device evidence: {', '.join(missing_phases)}")
    physical_bytes = memory.get("physical_bytes")
    if (
        not _real_evidence(hardware)
        or not isinstance(hardware.get("chip"), str)
        or not str(hardware["chip"]).strip()
        or not isinstance(hardware.get("architecture"), str)
        or not str(hardware["architecture"]).strip()
        or not isinstance(physical_bytes, int)
        or isinstance(physical_bytes, bool)
        or physical_bytes <= 0
    ):
        reasons.append("missing real hardware identity")
    if not _real_evidence(model_identity) or not _model_identity_complete(model_identity):
        reasons.append("missing real model/variant/quantization identity")
    if not _quality_evidence_valid(quality):
        reasons.append("missing real quality result")
    if "soak" in required and not _passed_evidence(soak):
        reasons.append("missing real soak evidence")
    if "switch" in required and not _passed_evidence(switch):
        reasons.append("missing real switch evidence")
    if not resources_complete:
        reasons.append("missing complete simultaneous resource samples")
    if default_sampler_used:
        reasons.append("default process sampler unavailable; release gate remains closed")
    if monitor_stop_error is not None:
        reasons.append("resource monitor stop failed; evidence incomplete")
    if not inference_observed:
        reasons.append("only readyz evidence; no successful public inference")
    if injected_dependencies:
        reasons.append("injected dependencies are not real evidence")
    return not reasons, reasons
