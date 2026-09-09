"""Resource sampling, sanitization, and release evidence gates."""

from __future__ import annotations

import json
import math
import os
import platform
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from itertools import pairwise
from typing import Protocol, cast

try:
    from .benchmark_http import Clock, Ffprobe, HttpRunner
    from .benchmark_manifest import _mapping_or_empty, required_phases
    from .profile_metrics import ProcessIdentity, simultaneous_peak_by_identity
    from .sample_resources import FOOTPRINT_METRIC, _sample_process, worker_pids
except ImportError:  # pragma: no cover - exercised when run as a script
    from benchmark_http import Clock, Ffprobe, HttpRunner  # type: ignore[no-redef]
    from benchmark_manifest import _mapping_or_empty, required_phases  # type: ignore[no-redef]
    from profile_metrics import (  # type: ignore[no-redef]
        ProcessIdentity,
        simultaneous_peak_by_identity,
    )
    from sample_resources import (  # type: ignore[no-redef]
        FOOTPRINT_METRIC,
        _sample_process,
        worker_pids,
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

_SAFE_ROLE_CHARS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.#-"
)


type SystemSampler = Callable[[], Mapping[str, object]]

_PROCESS_COMMAND_TIMEOUT_SECONDS = 1.0
_MONITOR_STOP_TIMEOUT_SECONDS = 5.0
_GENERIC_CHIP_IDENTITIES = frozenset(
    {"", "unknown", "arm", "arm64", "aarch64", "x86_64", "amd64", "i386"}
)


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


def _read_rss_bytes(pid: int) -> int | None:
    try:
        completed = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(pid)],
            capture_output=True,
            text=True,
            check=False,
            timeout=_PROCESS_COMMAND_TIMEOUT_SECONDS,
            env={"PATH": os.defpath, "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        rss_kib = int(completed.stdout.strip())
    except ValueError:
        return None
    return rss_kib * 1024 if completed.returncode == 0 and rss_kib >= 0 else None


class ProcessResourceMonitor:
    """Collect same-tick managed-process RSS and macOS physical footprint samples."""

    def __init__(
        self,
        *,
        interval_seconds: float = 0.25,
        discover: Callable[[], Mapping[str, ProcessIdentity]] = worker_pids,
        reader: Callable[[ProcessIdentity], tuple[float, float, float, str] | None]
        = _sample_process,
    ) -> None:
        if not math.isfinite(interval_seconds) or interval_seconds <= 0:
            raise ValueError("resource monitor interval must be finite and positive")
        self._interval_seconds = interval_seconds
        self._discover = discover
        self._reader = reader
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._samples: list[dict[str, object]] = []
        self._error: BaseException | None = None
        self._started = False
        self._started_at: float | None = None
        self._observation_seconds = 0.0
        self._max_tick_span_seconds = 0.0

    def _collect_tick(self) -> None:
        tick_started_at = time.monotonic()
        if self._started_at is None:
            self._started_at = tick_started_at
        discovered = dict(self._discover())
        processes: list[dict[str, object]] = []
        missing_roles: list[str] = []
        for role, identity in discovered.items():
            observation = self._reader(identity)
            if observation is None:
                missing_roles.append(role)
                rss_bytes = None
                footprint_bytes = None
            else:
                _, current_mb, _, metric = observation
                rss_bytes = _read_rss_bytes(identity.pid)
                footprint_bytes = (
                    int(current_mb * 1024 * 1024) if metric == FOOTPRINT_METRIC else None
                )
            processes.append(
                {
                    "role": role,
                    "pid": identity.pid,
                    "start_time_ns": identity.start_time_ns,
                    "rss_bytes": rss_bytes,
                    "phys_footprint_bytes": footprint_bytes,
                }
            )
        tick_ended_at = time.monotonic()
        tick_duration = max(0.0, tick_ended_at - tick_started_at)
        self._observation_seconds += tick_duration
        self._max_tick_span_seconds = max(self._max_tick_span_seconds, tick_duration)
        relative_started = max(0.0, tick_started_at - self._started_at)
        relative_ended = max(0.0, tick_ended_at - self._started_at)
        self._samples.append(
            {
                "at_seconds": relative_started,
                "ended_at_seconds": relative_ended,
                "duration_seconds": tick_duration,
                "processes": processes,
                "discovered_roles": sorted(discovered),
                "missing_roles": sorted(missing_roles),
                "complete": bool(processes) and not missing_roles,
            }
        )

    def _run(self) -> None:
        try:
            while not self._stop.is_set():
                self._collect_tick()
                self._stop.wait(self._interval_seconds)
        except BaseException as exc:
            self._error = exc
            self._stop.set()

    def start(self) -> None:
        if self._started:
            raise RuntimeError("resource monitor already started")
        self._started = True
        self._started_at = time.monotonic()
        self._thread = threading.Thread(
            target=self._run,
            name="speechrail-resource-monitor",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> Mapping[str, object]:
        if not self._started:
            raise RuntimeError("resource monitor was not started")
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=_MONITOR_STOP_TIMEOUT_SECONDS)
            if self._thread.is_alive():
                raise RuntimeError("resource monitor stop timed out")
        if self._error is not None:
            raise RuntimeError("resource monitor failed") from self._error
        started_at = self._started_at if self._started_at is not None else time.monotonic()
        hardware = _hardware_snapshot(source="sample_resources")
        return {
            "hardware": hardware,
            "os": {"name": platform.system() or "unknown", "version": platform.release()},
            "memory": {"physical_bytes": _physical_memory_bytes()},
            "process_samples": self._samples,
            "resource_sampler": {
                "available": True,
                "real": True,
                "source": "sample_resources",
                "schema_version": 2,
                "role_aware": True,
                "interval_seconds": self._interval_seconds,
                "sampling_span_seconds": max(0.0, time.monotonic() - started_at),
                "observation_seconds": self._observation_seconds,
                "max_tick_span_seconds": self._max_tick_span_seconds,
            },
        }


def _physical_memory_bytes() -> int | None:
    if sys.platform == "darwin":
        try:
            process = subprocess.run(
                ["/usr/sbin/sysctl", "-n", "hw.memsize"],
                capture_output=True,
                text=True,
                check=True,
                timeout=_PROCESS_COMMAND_TIMEOUT_SECONDS,
                env={"PATH": os.defpath, "LC_ALL": "C"},
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


def _macos_chip_name() -> str | None:
    """Read only the chip field from macOS hardware metadata."""
    if sys.platform != "darwin":
        return None
    try:
        process = subprocess.run(
            ["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"],
            capture_output=True,
            text=True,
            check=True,
            timeout=3.0,
            env={"PATH": os.defpath, "LC_ALL": "C"},
        )
        payload = json.loads(process.stdout)
    except (OSError, subprocess.SubprocessError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, Mapping):
        return None
    entries = payload.get("SPHardwareDataType")
    if not isinstance(entries, Sequence) or isinstance(entries, (str, bytes, bytearray)):
        return None
    for entry in entries:
        if not isinstance(entry, Mapping):
            continue
        chip = entry.get("chip_type")
        if isinstance(chip, str) and chip.strip():
            return chip.strip()
    return None


def _hardware_snapshot(*, source: str) -> dict[str, object]:
    architecture = platform.machine() or "unknown"
    chip = _macos_chip_name() or platform.processor() or architecture
    return {
        "real": True,
        "source": source,
        "architecture": architecture,
        "chip": chip,
    }


def _default_system_sampler() -> Mapping[str, object]:
    """Collect hardware identity; process samples stay explicit until a sampler supplies them."""

    return {
        "hardware": _hardware_snapshot(source="system"),
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
    raw_tick_count = 0
    complete_tick_count = 0
    invalid_tick_seen = False
    observed_roles: set[str] = set()
    role_sets: list[tuple[str, ...]] = []
    if isinstance(raw_ticks, Sequence) and not isinstance(raw_ticks, (str, bytes, bytearray)):
        for tick in raw_ticks:
            raw_tick_count += 1
            if not isinstance(tick, Mapping):
                invalid_tick_seen = True
                sanitized_ticks.append({"at_seconds": None, "processes": [], "complete": False})
                continue
            raw_processes = tick.get("processes", [])
            if not isinstance(raw_processes, Sequence) or isinstance(
                raw_processes, (str, bytes, bytearray)
            ):
                invalid_tick_seen = True
                sanitized_ticks.append(
                    {
                        "at_seconds": tick.get("at_seconds", tick.get("at")),
                        "processes": [],
                        "complete": False,
                    }
                )
                continue
            rss_tick: dict[ProcessIdentity, int] = {}
            footprint_tick: dict[ProcessIdentity, int] = {}
            output_processes: list[dict[str, object]] = []
            invalid_process = False
            seen_identities: set[ProcessIdentity] = set()
            for process in raw_processes:
                if not isinstance(process, Mapping):
                    invalid_process = True
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
                    invalid_process = True
                    continue
                identity = ProcessIdentity(pid=pid, start_time_ns=started)
                if identity in seen_identities:
                    invalid_process = True
                seen_identities.add(identity)
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
                safe_process: dict[str, object] = {
                    "pid": pid,
                    "start_time_ns": started,
                    "rss_bytes": rss if rss_valid else None,
                    "phys_footprint_bytes": footprint if footprint_valid else None,
                }
                role = process.get("role")
                if role is not None:
                    if (
                        not isinstance(role, str)
                        or not role
                        or len(role) > 64
                        or any(character not in _SAFE_ROLE_CHARS for character in role)
                    ):
                        invalid_process = True
                    else:
                        safe_process["role"] = role
                output_processes.append(safe_process)
            tick_complete = bool(
                output_processes
                and not invalid_process
                and len(rss_tick) == len(output_processes)
                and len(footprint_tick) == len(output_processes)
                and set(rss_tick) == set(footprint_tick)
                and tick.get("complete", True) is not False
            )
            at_raw = tick.get("at", tick.get("at_seconds"))
            at = (
                float(at_raw)
                if isinstance(at_raw, (int, float))
                and not isinstance(at_raw, bool)
                and math.isfinite(float(at_raw))
                and float(at_raw) >= 0
                else None
            )
            sanitized_tick: dict[str, object] = {
                "at_seconds": at,
                "processes": output_processes,
                "complete": tick_complete,
            }
            for timing_key in ("ended_at_seconds", "duration_seconds"):
                timing_value = tick.get(timing_key)
                if (
                    isinstance(timing_value, (int, float))
                    and not isinstance(timing_value, bool)
                    and math.isfinite(float(timing_value))
                    and float(timing_value) >= 0
                ):
                    sanitized_tick[timing_key] = float(timing_value)
            if at is None:
                invalid_tick_seen = True
                sanitized_tick["complete"] = False
            discovered_roles = tick.get("discovered_roles")
            missing_roles = tick.get("missing_roles")
            role_fields = (
                ("discovered_roles", discovered_roles),
                ("missing_roles", missing_roles),
            )
            for key, roles in role_fields:
                if isinstance(roles, Sequence) and not isinstance(roles, (str, bytes, bytearray)):
                    safe_roles = [
                        role
                        for role in roles
                        if isinstance(role, str)
                        and role
                        and len(role) <= 64
                        and all(
                            character
                            in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.#-"
                            for character in role
                        )
                    ]
                    sanitized_tick[key] = safe_roles
                    if key == "discovered_roles":
                        role_set = tuple(sorted(set(safe_roles)))
                        role_sets.append(role_set)
                        observed_roles.update(role_set)
            for process in output_processes:
                role = process.get("role")
                if isinstance(role, str):
                    observed_roles.add(role)
            sanitized_ticks.append(sanitized_tick)
            if sanitized_tick["complete"] is True:
                complete_tick_count += 1
                rss_snapshots.append(rss_tick)
                footprint_snapshots.append(footprint_tick)

    def _peak(snapshots: list[dict[ProcessIdentity, int]]) -> int | None:
        if not snapshots:
            return None
        try:
            return cast(int, simultaneous_peak_by_identity(snapshots))
        except (TypeError, ValueError):
            return None

    rss_peak = _peak(rss_snapshots)
    footprint_peak = _peak(footprint_snapshots)
    role_transitions = [
        index
        for index, (previous, current) in enumerate(pairwise(role_sets), start=1)
        if previous != current
    ]
    return {
        "sampler": sampler,
        "samples": sanitized_ticks,
        "observed_roles": sorted(observed_roles),
        "role_transitions": role_transitions,
        "simultaneous_peak": {
            "rss_bytes": rss_peak,
            "phys_footprint_bytes": footprint_peak,
        },
        "sampling_complete": bool(
            sanitized_ticks
            and not invalid_tick_seen
            and raw_tick_count == len(sanitized_ticks)
            and complete_tick_count == len(sanitized_ticks)
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


def _hardware_identity_complete(value: Mapping[str, object]) -> bool:
    chip = value.get("chip")
    architecture = value.get("architecture")
    if not isinstance(chip, str) or not chip.strip():
        return False
    if not isinstance(architecture, str) or not architecture.strip():
        return False
    normalized_chip = chip.strip().lower()
    normalized_architecture = architecture.strip().lower()
    return (
        normalized_chip not in _GENERIC_CHIP_IDENTITIES
        and normalized_chip != normalized_architecture
    )


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
        or not _hardware_identity_complete(hardware)
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
