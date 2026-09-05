"""G2 evidence collector/harness for the real three-tier SpeechRail benchmark.

This module deliberately records evidence and validation state only.  It does not
generate audio, call a vendor runtime, or write a performance report.  A real run
must provide an external fixture manifest and use the public SpeechRail HTTP API.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import subprocess
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from contextlib import suppress
from dataclasses import dataclass, field
from pathlib import Path
from types import MappingProxyType
from typing import Protocol, cast
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request

try:
    from .profile_metrics import (  # type: ignore[import-not-found]
        ProcessIdentity,
        rtf,
        simultaneous_peak_by_identity,
    )
except ImportError:  # pragma: no cover - exercised when run as a script
    from profile_metrics import ProcessIdentity, rtf, simultaneous_peak_by_identity


PHASES = frozenset({"baseline", "quality", "cold", "warm", "soak", "switch"})
_PCM_SAMPLE_RATE = 24_000
_PCM_BYTES_PER_SAMPLE = 2
_AUDIO_CONTENT_TYPES = MappingProxyType(
    {
        ".flac": "audio/flac",
        ".m4a": "audio/mp4",
        ".mp3": "audio/mpeg",
        ".mp4": "video/mp4",
        ".mpga": "audio/mpeg",
        ".mpeg": "video/mpeg",
        ".ogg": "audio/ogg",
        ".wav": "audio/wav",
        ".webm": "video/webm",
    }
)
PROFILE_DEVICE_PHASES: Mapping[str, str] = MappingProxyType(
    {
        "light": "m1_air_8gb",
        "balanced": "device_12gb",
        "quality": "local_quality",
    }
)
_PROFILE_REQUIRED_PHASES: Mapping[str, frozenset[str]] = MappingProxyType(
    {
        "light": frozenset(
            {"m1_air_8gb", "quality", "cold", "warm", "soak", "switch"}
        ),
        "balanced": frozenset(
            {"device_12gb", "quality", "cold", "warm", "switch"}
        ),
        "quality": frozenset(
            {"local_quality", "quality", "cold", "warm", "switch"}
        ),
    }
)
_EVIDENCE_PHASES = PHASES | frozenset(PROFILE_DEVICE_PHASES.values())
_REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})
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


class BenchmarkInputError(ValueError):
    """Raised when a benchmark input would violate the evidence contract."""


def build_auth_headers(api_key: str | None = None) -> dict[str, str]:
    """Build a Bearer header from an explicit key or the private environment key."""

    raw_key = os.environ.get("SPEECHRAIL_API_KEY") if api_key is None else api_key
    if raw_key is None or not raw_key.strip():
        return {}
    key = raw_key.strip()
    if "\r" in key or "\n" in key:
        raise BenchmarkInputError("SPEECHRAIL_API_KEY contains invalid characters")
    return {"Authorization": f"Bearer {key}"}


@dataclass(frozen=True, slots=True)
class HttpResponse:
    """Small, injectable public-HTTP response used by the harness."""

    status_code: int
    body: bytes = b""
    headers: Mapping[str, str] = field(default_factory=dict)


type HttpRunner = Callable[[str, str, bytes | None, Mapping[str, str]], HttpResponse]
type Clock = Callable[[], float]
type Ffprobe = Callable[[Path], float]
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


@dataclass(frozen=True, slots=True)
class Fixture:
    """Validated fixture metadata; the audio path never enters output JSON."""

    id: str
    path: Path
    kind: str
    language: str
    voice: str
    text: str | None


@dataclass(frozen=True, slots=True)
class LoadedManifest:
    """Validated manifest metadata with opaque fixture references."""

    fixtures: tuple[Fixture, ...]
    model_identity: Mapping[str, object]
    quality: Mapping[str, object]
    soak: Mapping[str, object]
    switch: Mapping[str, object]
    phase_evidence: Mapping[str, Mapping[str, object]]
    software: Mapping[str, object]


def required_phases(profile: str) -> set[str]:
    """Return the real-device and benchmark phases required for one profile."""

    key = profile.strip().lower() if isinstance(profile, str) else ""
    phases = _PROFILE_REQUIRED_PHASES.get(key)
    if phases is None:
        raise BenchmarkInputError(f"unknown profile: {profile}")
    return set(phases)


def validate_base_url(base_url: str) -> str:
    """Validate a loopback HTTP origin without credentials or query material."""

    if not isinstance(base_url, str) or not base_url.strip():
        raise BenchmarkInputError("base URL must be a non-blank HTTP URL")
    value = base_url.strip()
    parsed = urllib_parse.urlsplit(value)
    if parsed.scheme.lower() not in {"http", "https"}:
        raise BenchmarkInputError("base URL must use HTTP")
    if parsed.username is not None or parsed.password is not None:
        raise BenchmarkInputError("base URL must not contain credentials")
    if parsed.query or parsed.fragment or "?" in value or "#" in value:
        raise BenchmarkInputError("base URL must not contain query or fragment")
    hostname = parsed.hostname
    if hostname is None or hostname.lower() not in _LOOPBACK_HOSTS:
        raise BenchmarkInputError("base URL must point to a loopback host")
    try:
        port = parsed.port
    except ValueError as exc:
        raise BenchmarkInputError("base URL has an invalid port") from exc
    if port is not None and not 1 <= port <= 65535:
        raise BenchmarkInputError("base URL has an invalid port")
    if any(char.isspace() for char in value):
        raise BenchmarkInputError("base URL must not contain whitespace")
    return value.rstrip("/")


def validate_output_path(output: Path) -> Path:
    """Resolve a new output path and reject overwrite or a non-directory parent."""

    resolved = Path(output).expanduser().absolute()
    if resolved.exists() or resolved.is_symlink():
        raise BenchmarkInputError("output would overwrite an existing file")
    if not resolved.parent.is_dir():
        raise BenchmarkInputError("output parent directory does not exist")
    return resolved


def _looks_like_url(value: str) -> bool:
    parsed = urllib_parse.urlsplit(value)
    return bool(parsed.scheme or value.startswith("//"))


def _repository_external(path: Path, repository_root: Path) -> Path:
    if not path.is_absolute():
        raise BenchmarkInputError("manifest and fixture paths must be absolute")
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise BenchmarkInputError(f"path does not exist: {path}") from exc
    try:
        resolved.relative_to(repository_root.resolve())
    except ValueError:
        return resolved
    raise BenchmarkInputError("manifest and fixture paths must be outside the repository")


def _required_string(item: Mapping[str, object], key: str, *, label: str) -> str:
    value = item.get(key)
    if not isinstance(value, str) or not value.strip():
        raise BenchmarkInputError(f"{label}.{key} must be a non-blank string")
    return value.strip()


def _fixture_path(item: Mapping[str, object], *, repository_root: Path, label: str) -> Path:
    raw: object = item.get("path", item.get("audio_path", item.get("audio")))
    if not isinstance(raw, str) or not raw.strip():
        raise BenchmarkInputError(f"{label}.path must be an external local audio path")
    if _looks_like_url(raw.strip()):
        raise BenchmarkInputError(f"{label}.path must not be an audio URL")
    resolved = _repository_external(Path(raw).expanduser(), repository_root)
    if not resolved.is_file():
        raise BenchmarkInputError(f"fixture path is not a file: {raw}")
    return resolved


def _mapping_or_empty(value: object, *, label: str) -> Mapping[str, object]:
    if value is None:
        return MappingProxyType({})
    if not isinstance(value, Mapping):
        raise BenchmarkInputError(f"{label} must be an object")
    return dict(value)


def load_manifest(
    manifest: Path, *, repository_root: Path | None = None
) -> LoadedManifest:
    """Load an external JSON fixture list and reject URLs or repository paths."""

    root = _REPOSITORY_ROOT if repository_root is None else Path(repository_root).resolve()
    resolved_manifest = _repository_external(Path(manifest).expanduser(), root)
    if not resolved_manifest.is_file():
        raise BenchmarkInputError(f"manifest path is not a file: {manifest}")
    try:
        raw = json.loads(resolved_manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BenchmarkInputError("manifest must be valid UTF-8 JSON") from exc

    metadata: Mapping[str, object]
    if isinstance(raw, list):
        entries: object = raw
        metadata = {}
    elif isinstance(raw, Mapping):
        entries = raw.get("fixtures")
        metadata = dict(raw)
    else:
        raise BenchmarkInputError("manifest must be a fixture list or object with fixtures")
    if not isinstance(entries, list) or not entries:
        raise BenchmarkInputError("manifest fixtures must be a non-empty list")

    fixtures: list[Fixture] = []
    seen_ids: set[str] = set()
    for index, raw_item in enumerate(entries):
        label = f"fixtures[{index}]"
        if not isinstance(raw_item, Mapping):
            raise BenchmarkInputError(f"{label} must be an object")
        fixture_id = _required_string(raw_item, "id", label=label)
        if fixture_id in seen_ids or _looks_like_url(fixture_id):
            raise BenchmarkInputError(f"{label}.id must be a unique opaque identifier")
        seen_ids.add(fixture_id)
        kind = str(raw_item.get("kind", "asr")).strip().lower()
        if kind not in {"asr", "tts"}:
            raise BenchmarkInputError(f"{label}.kind must be asr or tts")
        text = raw_item.get("text")
        if kind == "tts" and (not isinstance(text, str) or not text.strip()):
            raise BenchmarkInputError(f"{label}.text is required for TTS fixtures")
        if text is not None and not isinstance(text, str):
            raise BenchmarkInputError(f"{label}.text must be a string")
        fixtures.append(
            Fixture(
                id=fixture_id,
                path=_fixture_path(raw_item, repository_root=root, label=label),
                kind=kind,
                language=str(raw_item.get("language", "auto")),
                voice=str(raw_item.get("voice", "default")),
                text=text.strip() if isinstance(text, str) else None,
            )
        )

    raw_phase_evidence = metadata.get("phase_evidence", metadata.get("evidence"))
    phase_evidence: dict[str, Mapping[str, object]] = {}
    if raw_phase_evidence is not None:
        if not isinstance(raw_phase_evidence, Mapping):
            raise BenchmarkInputError("phase_evidence must be an object")
        for phase, evidence in raw_phase_evidence.items():
            if phase not in _EVIDENCE_PHASES:
                continue
            if isinstance(evidence, Mapping):
                phase_evidence[str(phase)] = dict(evidence)

    return LoadedManifest(
        fixtures=tuple(fixtures),
        model_identity=_mapping_or_empty(metadata.get("model_identity"), label="model_identity"),
        quality=_mapping_or_empty(metadata.get("quality"), label="quality"),
        soak=_mapping_or_empty(metadata.get("soak"), label="soak"),
        switch=_mapping_or_empty(metadata.get("switch"), label="switch"),
        phase_evidence=phase_evidence,
        software=_mapping_or_empty(metadata.get("software"), label="software"),
    )


def _public_url(base_url: str, suffix: str) -> str:
    parsed = urllib_parse.urlsplit(base_url)
    root = parsed.path.rstrip("/")
    if root.endswith("/v1"):
        root = root[:-3]
    return urllib_parse.urlunsplit(
        (parsed.scheme, parsed.netloc, f"{root}{suffix}", "", "")
    )


def _default_http_runner(
    method: str, url: str, body: bytes | None, headers: Mapping[str, str]
) -> HttpResponse:
    request = urllib_request.Request(url, data=body, headers=dict(headers), method=method)
    try:
        with urllib_request.urlopen(request, timeout=600) as response:
            return HttpResponse(
                status_code=int(response.status),
                body=response.read(),
                headers={str(key).lower(): str(value) for key, value in response.headers.items()},
            )
    except urllib_error.HTTPError as exc:
        return HttpResponse(
            status_code=int(exc.code),
            body=exc.read(),
            headers={str(key).lower(): str(value) for key, value in exc.headers.items()},
        )


def _default_ffprobe(path: Path) -> float:
    process = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "csv=p=0",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    try:
        duration = float(process.stdout.strip())
    except ValueError as exc:
        raise BenchmarkInputError("ffprobe did not return a numeric duration") from exc
    if not math.isfinite(duration) or duration <= 0:
        raise BenchmarkInputError("ffprobe duration must be positive and finite")
    return duration


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


def _json_body(response: HttpResponse) -> Mapping[str, object]:
    try:
        raw = json.loads(response.body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return MappingProxyType({})
    return dict(raw) if isinstance(raw, Mapping) else MappingProxyType({})


def _probe(
    runner: HttpRunner,
    base_url: str,
    suffix: str,
    headers: Mapping[str, str],
) -> tuple[Mapping[str, object], int | None]:
    try:
        response = runner("GET", _public_url(base_url, suffix), None, headers)
    except Exception:
        return MappingProxyType({}), None
    return _json_body(response), response.status_code


def _audio_content_type(path: Path) -> str:
    return _AUDIO_CONTENT_TYPES.get(path.suffix.lower(), "application/octet-stream")


def _multipart_body(fixture: Fixture) -> tuple[bytes, Mapping[str, str]]:
    boundary = "----speechrail-profile-benchmark"
    data = bytearray()
    for name, value in (("model", "whisper-1"), ("response_format", "json")):
        data.extend(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n"
            f"{value}\r\n".encode()
        )
    data.extend(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"{fixture.path.name}\"\r\n"
        f"Content-Type: {_audio_content_type(fixture.path)}\r\n\r\n".encode()
    )
    data.extend(fixture.path.read_bytes())
    data.extend(f"\r\n--{boundary}--\r\n".encode())
    return bytes(data), {"Content-Type": f"multipart/form-data; boundary={boundary}"}


def _pcm_duration_seconds(body: bytes) -> float | None:
    if not body or len(body) % _PCM_BYTES_PER_SAMPLE:
        return None
    duration = len(body) / (_PCM_SAMPLE_RATE * _PCM_BYTES_PER_SAMPLE)
    return duration if math.isfinite(duration) and duration > 0 else None


def _fixture_request(
    fixture: Fixture,
    *,
    base_url: str,
    runner: HttpRunner,
    clock: Clock,
    duration: float | None,
    auth_headers: Mapping[str, str],
) -> dict[str, object]:
    if fixture.kind == "asr":
        body, headers = _multipart_body(fixture)
        endpoint = "/v1/audio/transcriptions"
    else:
        body = json.dumps(
            {
                "model": "tts-1",
                "input": fixture.text,
                "voice": fixture.voice,
                "response_format": "pcm",
            }
        ).encode()
        headers = {"Content-Type": "application/json"}
        endpoint = "/v1/audio/speech"
    request_headers = dict(auth_headers)
    request_headers.update(headers)
    started = clock()
    response: HttpResponse | None = None
    try:
        response = runner("POST", _public_url(base_url, endpoint), body, request_headers)
        status_code: int | None = response.status_code
    except Exception:
        status_code = None
    elapsed = max(0.0, clock() - started)
    success = status_code is not None and 200 <= status_code < 300
    actual_duration = duration
    duration_source: str | None = "ffprobe"
    measured_rtf: float | None
    measurement_error: str | None = None
    if fixture.kind == "tts":
        pcm_body = response.body if success and response is not None else b""
        actual_duration = _pcm_duration_seconds(pcm_body) if success else None
        duration_source = "pcm_24khz_mono_pcm16" if actual_duration is not None else None
        if actual_duration is None:
            measured_rtf = None
            if success:
                measurement_error = "invalid_pcm"
        else:
            measured_rtf = rtf(elapsed, actual_duration)
        success = success and actual_duration is not None
    else:
        if duration is None:
            raise BenchmarkInputError("ASR fixture is missing ffprobe duration")
        try:
            measured_rtf = rtf(elapsed, duration)
        except ValueError:
            measured_rtf = None
    return {
        "id": fixture.id,
        "kind": fixture.kind,
        "language": fixture.language,
        "actual_audio_seconds": actual_duration,
        "duration_source": duration_source,
        "latency_seconds": elapsed,
        "rtf": measured_rtf,
        "status_code": status_code,
        "inference_observed": success,
        **({"measurement_error": measurement_error} if measurement_error else {}),
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
    deps = BenchmarkDependencies() if dependencies is None else dependencies
    injected_dependencies = dependencies is not None
    auth_headers = build_auth_headers()
    runner = _default_http_runner if deps.http_runner is None else deps.http_runner
    clock = deps.clock
    ffprobe = _default_ffprobe if deps.ffprobe is None else deps.ffprobe
    sampler = _default_system_sampler if deps.system_sampler is None else deps.system_sampler
    default_sampler_used = deps.system_sampler is None

    monitor = deps.monitor
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


if __name__ == "__main__":  # pragma: no cover - CLI dispatch
    raise SystemExit(main())


__all__ = [
    "PHASES",
    "PROFILE_DEVICE_PHASES",
    "BenchmarkDependencies",
    "BenchmarkInputError",
    "Fixture",
    "HttpResponse",
    "LoadedManifest",
    "ResourceMonitor",
    "build_auth_headers",
    "load_manifest",
    "main",
    "required_phases",
    "run_profile_benchmark",
    "validate_base_url",
    "validate_output_path",
    "write_result",
]
