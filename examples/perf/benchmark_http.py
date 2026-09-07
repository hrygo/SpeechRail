"""Loopback HTTP transport and fixture request primitives."""

from __future__ import annotations

import json
import math
import os
import subprocess
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from types import MappingProxyType
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request

try:
    from .benchmark_manifest import BenchmarkInputError, Fixture
    from .profile_metrics import rtf
except ImportError:  # pragma: no cover - exercised when run as a script
    from benchmark_manifest import BenchmarkInputError, Fixture  # type: ignore[no-redef]
    from profile_metrics import rtf  # type: ignore[no-redef]


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

_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


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
