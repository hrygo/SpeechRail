"""Run the minimum full-stack SpeechRail memory scenarios.

The runner deliberately records only timings, event names, status flags, and
role-aware resource evidence.  It never writes audio, transcripts, command
lines, or authentication material to the result file.
"""

from __future__ import annotations

import argparse
import base64
import math
import queue
import statistics
import threading
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

from openai import OpenAI

try:
    from .bench_realtime import recv_loop, recv_until, run_session
    from .benchmark_http import (
        _default_http_runner,
        _json_body,
        _probe,
        _public_url,
        build_auth_headers,
        ensure_authentication,
        validate_base_url,
    )
    from .benchmark_resources import (
        ProcessResourceMonitor,
        _normalise_resources,
    )
    from .benchmark_runner import validate_output_path, write_result
except ImportError:  # pragma: no cover - exercised when run as a script
    from bench_realtime import recv_loop, recv_until, run_session  # type: ignore[no-redef]
    from benchmark_http import (  # type: ignore[no-redef]
        _default_http_runner,
        _json_body,
        _probe,
        _public_url,
        build_auth_headers,
        ensure_authentication,
        validate_base_url,
    )
    from benchmark_resources import (  # type: ignore[no-redef]
        ProcessResourceMonitor,
        _normalise_resources,
    )
    from benchmark_runner import validate_output_path, write_result  # type: ignore[no-redef]


type ScenarioAction = Callable[[], list[dict[str, object]]]

_SCENARIO_ROLES: dict[str, tuple[str, ...]] = {
    # The managed runtime uses one physical qwen3 worker for batch and
    # realtime logical modes.  The command-line role is therefore the
    # evidence role; the scenario request proves the logical mode.
    "A": ("host-fastapi", "batch-asr", "tts"),
    "B": ("host-fastapi", "batch-asr", "tts"),
    "C": ("host-fastapi", "batch-asr", "diarization"),
    "D": ("host-fastapi", "batch-asr", "tts", "diarization"),
    "E": ("host-fastapi", "diarization"),
}


def _safe_error(exc: BaseException) -> dict[str, object]:
    """Keep failure evidence actionable without copying vendor messages."""

    result: dict[str, object] = {"type": type(exc).__name__}
    code = getattr(exc, "code", None)
    if isinstance(code, str) and code:
        result["code"] = code[:64]
    return result


def _safe_realtime_result(result: Mapping[str, object]) -> dict[str, object]:
    allowed = {
        "session",
        "turn_detection",
        "diarization_requested",
        "setup_ms",
        "upload_ms",
        "asr_ms",
        "audio_s",
        "asr_rtf",
        "tts_first_delta_ms",
        "tts_bytes",
        "transcript_present",
        "transcript_chars",
        "response_done",
        "vad_started",
        "vad_stopped",
        "diarization_updated",
        "diarization_done",
        "vad_to_asr_started_ms",
    }
    safe = {key: result[key] for key in allowed if key in result}
    raw_events = result.get("event_types")
    if isinstance(raw_events, Sequence) and not isinstance(raw_events, (str, bytes, bytearray)):
        safe["event_types"] = [
            event
            for event in raw_events[:128]
            if isinstance(event, str) and len(event) <= 96
        ]
    return safe


def _numeric_summary(runs: Sequence[Mapping[str, object]], key: str) -> dict[str, object]:
    values = [
        float(value)
        for run in runs
        if isinstance((value := run.get(key)), (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    ]
    if not values:
        return {"count": 0, "min": None, "median": None, "max": None}
    return {
        "count": len(values),
        "min": min(values),
        "median": statistics.median(values),
        "max": max(values),
    }


def _resource_summary(
    resources: Mapping[str, object], expected_roles: Sequence[str]
) -> dict[str, object]:
    raw_samples = resources.get("samples")
    samples = (
        raw_samples
        if isinstance(raw_samples, list)
        else []
    )
    observed_roles: set[str] = set()
    expected_complete_ticks = 0
    role_sets: list[tuple[str, ...]] = []
    for sample in samples:
        if not isinstance(sample, Mapping):
            continue
        roles: set[str] = set()
        processes = sample.get("processes")
        if isinstance(processes, Sequence) and not isinstance(
            processes, (str, bytes, bytearray)
        ):
            for process in processes:
                if not isinstance(process, Mapping):
                    continue
                role = process.get("role")
                if isinstance(role, str):
                    roles.add(role)
        observed_roles.update(roles)
        role_sets.append(tuple(sorted(roles)))
        if sample.get("complete") is True and set(expected_roles).issubset(roles):
            expected_complete_ticks += 1

    expected = set(expected_roles)
    return {
        "expected_roles": list(expected_roles),
        "observed_roles": sorted(observed_roles),
        "missing_expected_roles": sorted(expected - observed_roles),
        "expected_roles_in_complete_tick": expected_complete_ticks > 0,
        "sampling_complete": resources.get("sampling_complete") is True,
        "sample_count": len(samples),
        "complete_sample_count": sum(
            1
            for sample in samples
            if isinstance(sample, Mapping) and sample.get("complete") is True
        ),
        "role_transitions": resources.get("role_transitions", []),
        "simultaneous_peak": resources.get("simultaneous_peak", {}),
        "observed_role_sets": sorted(set(role_sets)),
        "resource_evidence_verdict": (
            "complete"
            if resources.get("sampling_complete") is True
            and not (expected - observed_roles)
            and expected_complete_ticks > 0
            else "incomplete"
        ),
    }


def _with_resource_window(
    action: ScenarioAction,
    *,
    interval_seconds: float,
) -> tuple[list[dict[str, object]], dict[str, object], dict[str, object] | None]:
    monitor = ProcessResourceMonitor(interval_seconds=interval_seconds)
    monitor_error: dict[str, object] | None = None
    runs: list[dict[str, object]] = []
    try:
        monitor.start()
        runs = action()
    except Exception as exc:
        runs.append({"status": "failed", "error": _safe_error(exc)})
    finally:
        try:
            raw = monitor.stop()
        except Exception as exc:
            raw = {}
            monitor_error = _safe_error(exc)
    resources = _normalise_resources(raw if isinstance(raw, Mapping) else {})
    if monitor_error is not None:
        resources["sampling_complete"] = False
    return runs, resources, monitor_error


def _realtime_scenario(
    client: OpenAI,
    pcm: bytes,
    *,
    scenario_id: str,
    description: str,
    iterations: int,
    turn_detection: str,
    diarization: bool,
    interval_seconds: float,
) -> dict[str, object]:
    def action() -> list[dict[str, object]]:
        runs: list[dict[str, object]] = []
        for session_no in range(1, iterations + 1):
            try:
                result = run_session(
                    client,
                    pcm,
                    "SpeechRail 全链路内存证据测试。",
                    session_no,
                    turn_detection=turn_detection,
                    diarization=diarization,
                )
                safe = _safe_realtime_result(result)
                if (
                    not bool(safe.get("transcript_present"))
                    or safe.get("response_done") is not True
                    or (
                        turn_detection == "server_vad"
                        and not (safe.get("vad_started") and safe.get("vad_stopped"))
                    )
                    or (
                        diarization
                        and not (
                            safe.get("diarization_updated")
                            and safe.get("diarization_done")
                        )
                    )
                ):
                    safe["status"] = "failed"
                    safe["error"] = {"type": "scenario_assertion_failed"}
                else:
                    safe["status"] = "passed"
                runs.append(safe)
            except Exception as exc:
                runs.append(
                    {
                        "session": session_no,
                        "status": "failed",
                        "error": _safe_error(exc),
                    }
                )
        return runs

    runs, resources, monitor_error = _with_resource_window(
        action,
        interval_seconds=interval_seconds,
    )
    expected_roles = _SCENARIO_ROLES[scenario_id]
    resource_summary = _resource_summary(resources, expected_roles)
    passed_runs = sum(1 for run in runs if run.get("status") == "passed")
    return {
        "id": scenario_id,
        "description": description,
        "request": {
            "turn_detection": turn_detection,
            "diarization": diarization,
            "iterations": iterations,
        },
        "runs": runs,
        "latency_summary": {
            "asr_ms": _numeric_summary(runs, "asr_ms"),
            "tts_first_delta_ms": _numeric_summary(runs, "tts_first_delta_ms"),
        },
        "passed_runs": passed_runs,
        "scenario_pass": passed_runs == iterations,
        "resource_summary": resource_summary,
        "resources": resources,
        **({"monitor_error": monitor_error} if monitor_error else {}),
    }


def _multipart_diarization_body(audio_file: Path) -> tuple[bytes, str]:
    boundary = "----speechrail-scenario-diarization"
    data = bytearray()
    fields = (
        ("model", "gpt-4o-transcribe-diarize"),
        ("response_format", "diarized_json"),
        ("chunking_strategy", "auto"),
    )
    for name, value in fields:
        data.extend(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n"
            f"{value}\r\n".encode()
        )
    data.extend(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"{audio_file.name}\"\r\n"
        "Content-Type: audio/wav\r\n\r\n".encode()
    )
    data.extend(audio_file.read_bytes())
    data.extend(f"\r\n--{boundary}--\r\n".encode())
    return bytes(data), f"multipart/form-data; boundary={boundary}"


def _rest_diarization_run(
    base_url: str,
    audio_file: Path,
    headers: Mapping[str, str],
) -> dict[str, object]:
    body, content_type = _multipart_diarization_body(audio_file)
    request_headers = dict(headers)
    request_headers["Content-Type"] = content_type
    started = time.monotonic()
    try:
        response = _default_http_runner(
            "POST",
            _public_url(base_url, "/v1/audio/transcriptions"),
            body,
            request_headers,
        )
    except Exception as exc:
        return {"status": "failed", "error": _safe_error(exc)}
    elapsed_ms = (time.monotonic() - started) * 1000
    payload = _json_body(response)
    text_value = payload.get("text")
    segments = payload.get("segments")
    segment_items = (
        list(segments)
        if isinstance(segments, Sequence) and not isinstance(segments, (str, bytes, bytearray))
        else []
    )
    speaker_count = len(
        {
            speaker
            for item in segment_items
            if isinstance(item, Mapping)
            and isinstance((speaker := item.get("speaker")), str)
            and (
                speaker in {"A", "B", "C", "D"}
                or speaker.startswith("spk_")
            )
        }
    )
    passed = (
        200 <= response.status_code < 300
        and isinstance(text_value, str)
        and bool(text_value.strip())
        and bool(segment_items)
        and speaker_count > 0
    )
    result: dict[str, object] = {
        "status": "passed" if passed else "failed",
        "status_code": response.status_code,
        "latency_ms": elapsed_ms,
        "text_present": isinstance(text_value, str) and bool(text_value.strip()),
        "segment_count": len(segment_items),
        "anonymous_speaker_count": speaker_count,
    }
    if not passed:
        result["error"] = {
            "type": "diarized_json_assertion_failed"
            if 200 <= response.status_code < 300
            else f"http_{response.status_code}"
        }
    return result


def _rest_diarization_scenario(
    base_url: str,
    audio_file: Path,
    headers: Mapping[str, str],
    *,
    iterations: int,
    interval_seconds: float,
) -> dict[str, object]:
    def action() -> list[dict[str, object]]:
        return [
            _rest_diarization_run(base_url, audio_file, headers)
            for _ in range(iterations)
        ]

    runs, resources, monitor_error = _with_resource_window(
        action,
        interval_seconds=interval_seconds,
    )
    expected_roles = _SCENARIO_ROLES["C"]
    passed_runs = sum(1 for run in runs if run.get("status") == "passed")
    return {
        "id": "C",
        "description": "REST gpt-4o-transcribe-diarize + diarized_json",
        "request": {
            "model": "gpt-4o-transcribe-diarize",
            "response_format": "diarized_json",
            "iterations": iterations,
        },
        "runs": runs,
        "latency_summary": {"latency_ms": _numeric_summary(runs, "latency_ms")},
        "passed_runs": passed_runs,
        "scenario_pass": passed_runs == iterations,
        "resource_summary": _resource_summary(resources, expected_roles),
        "resources": resources,
        **({"monitor_error": monitor_error} if monitor_error else {}),
    }


def _open_lifecycle_connection(
    client: OpenAI,
    *,
    session_no: int,
) -> tuple[Any, queue.Queue[object], list[Exception], list[str]]:
    conn = client.realtime.connect(model="whisper-1").enter()
    events: queue.Queue[object] = queue.Queue()
    errors: list[Exception] = []
    event_log: list[str] = []
    threading.Thread(
        target=recv_loop,
        args=(events, errors, conn),
        daemon=True,
        name=f"speechrail-lifecycle-recv-{session_no}",
    ).start()
    recv_until(events, errors, "conversation.created", timeout=15, event_log=event_log)
    conn.send(
        {
            "type": "session.update",
            "session": {
                "model": "whisper-1",
                "input_audio_format": "pcm16",
                "turn_detection": {
                    "type": "server_vad",
                    "silence_duration_ms": 400,
                },
                "speechrail": {"diarization": {"enabled": True}},
            },
        }
    )
    recv_until(events, errors, "session.updated", timeout=15, event_log=event_log)
    return conn, events, errors, event_log


def _lifecycle_scenario(
    client: OpenAI,
    pcm: bytes,
    *,
    loops: int,
    soak_seconds: float,
    interval_seconds: float,
) -> dict[str, object]:
    def action() -> list[dict[str, object]]:
        runs: list[dict[str, object]] = []
        for session_no in range(1, loops + 1):
            conn: Any | None = None
            try:
                conn, _events, _errors, event_log = _open_lifecycle_connection(
                    client,
                    session_no=session_no,
                )
                conn.send(
                    {
                        "type": "input_audio_buffer.append",
                        "audio": base64.b64encode(pcm[: min(len(pcm), 6400)]).decode("ascii"),
                    }
                )
                runs.append(
                    {
                        "session": session_no,
                        "status": "passed",
                        "closed": False,
                        "event_types": event_log[:64],
                    }
                )
            except Exception as exc:
                runs.append(
                    {"session": session_no, "status": "failed", "error": _safe_error(exc)}
                )
            finally:
                if conn is not None:
                    try:
                        conn.close()
                        if runs[-1].get("session") == session_no:
                            runs[-1]["closed"] = True
                    except Exception as exc:
                        runs.append(
                            {
                                "session": session_no,
                                "status": "failed",
                                "error": _safe_error(exc),
                            }
                        )

        if soak_seconds > 0:
            conn = None
            started = time.monotonic()
            try:
                conn, _events, _errors, event_log = _open_lifecycle_connection(
                    client,
                    session_no=loops + 1,
                )
                while time.monotonic() - started < soak_seconds:
                    time.sleep(min(1.0, max(0.0, soak_seconds - (time.monotonic() - started))))
                runs.append(
                    {
                        "session": loops + 1,
                        "status": "passed",
                        "closed": False,
                        "soak_seconds": soak_seconds,
                        "event_types": event_log[:64],
                    }
                )
            except Exception as exc:
                runs.append(
                    {"session": loops + 1, "status": "failed", "error": _safe_error(exc)}
                )
            finally:
                if conn is not None:
                    try:
                        conn.close()
                        if runs[-1].get("session") == loops + 1:
                            runs[-1]["closed"] = True
                    except Exception as exc:
                        runs.append(
                            {
                                "session": loops + 1,
                                "status": "failed",
                                "error": _safe_error(exc),
                            }
                        )
        return runs

    runs, resources, monitor_error = _with_resource_window(
        action,
        interval_seconds=interval_seconds,
    )
    passed_runs = sum(1 for run in runs if run.get("status") == "passed" and run.get("closed"))
    expected_roles = _SCENARIO_ROLES["E"]
    return {
        "id": "E",
        "description": "repeated close plus sustained diarization session",
        "request": {
            "close_loops": loops,
            "soak_seconds": soak_seconds,
        },
        "runs": runs,
        "passed_runs": passed_runs,
        "scenario_pass": passed_runs == loops + (1 if soak_seconds > 0 else 0),
        "resource_summary": _resource_summary(resources, expected_roles),
        "resources": resources,
        **({"monitor_error": monitor_error} if monitor_error else {}),
    }


def run_scenario_suite(
    *,
    base_url: str,
    pcm_file: Path,
    audio_file: Path,
    profile: str,
    app_home: Path | None,
    iterations: int,
    lifecycle_loops: int,
    soak_seconds: float,
    interval_seconds: float,
) -> dict[str, object]:
    normalized_base = validate_base_url(base_url)
    if iterations < 1 or lifecycle_loops < 1:
        raise ValueError("iterations and lifecycle_loops must be positive")
    if not math.isfinite(soak_seconds) or soak_seconds < 0:
        raise ValueError("soak_seconds must be finite and non-negative")
    if not math.isfinite(interval_seconds) or interval_seconds <= 0:
        raise ValueError("interval_seconds must be finite and positive")
    pcm = pcm_file.read_bytes()
    if not pcm or len(pcm) % 2:
        raise ValueError("pcm_file must contain non-empty even-length PCM16")
    audio_file.stat()
    auth_headers = build_auth_headers(app_home=app_home)
    ensure_authentication(_default_http_runner, normalized_base, auth_headers)
    health, health_status = _probe(
        _default_http_runner,
        normalized_base,
        "/health",
        auth_headers,
    )
    readyz, readyz_status = _probe(
        _default_http_runner,
        normalized_base,
        "/readyz",
        auth_headers,
    )
    api_key = auth_headers.get("Authorization", "local").removeprefix("Bearer ")
    client = OpenAI(api_key=api_key, base_url=normalized_base)
    scenarios = [
        _realtime_scenario(
            client,
            pcm,
            scenario_id="A",
            description="manual realtime ASR followed by fixed TTS",
            iterations=iterations,
            turn_detection="manual",
            diarization=False,
            interval_seconds=interval_seconds,
        ),
        _realtime_scenario(
            client,
            pcm,
            scenario_id="B",
            description="server_vad realtime ASR followed by fixed TTS",
            iterations=iterations,
            turn_detection="server_vad",
            diarization=False,
            interval_seconds=interval_seconds,
        ),
        _rest_diarization_scenario(
            normalized_base,
            audio_file,
            auth_headers,
            iterations=iterations,
            interval_seconds=interval_seconds,
        ),
        _realtime_scenario(
            client,
            pcm,
            scenario_id="D",
            description="server_vad + realtime diarization + TTS",
            iterations=iterations,
            turn_detection="server_vad",
            diarization=True,
            interval_seconds=interval_seconds,
        ),
        _lifecycle_scenario(
            client,
            pcm,
            loops=lifecycle_loops,
            soak_seconds=soak_seconds,
            interval_seconds=interval_seconds,
        ),
    ]
    resource_evidence_complete = all(
        scenario.get("resource_summary", {}).get("resource_evidence_verdict") == "complete"
        for scenario in scenarios
        if isinstance(scenario.get("resource_summary"), Mapping)
    )
    return {
        "schema_version": 1,
        "tool": "speechrail-benchmark-scenarios",
        "profile": profile.strip().lower(),
        "base_url": normalized_base,
        "iterations": iterations,
        "lifecycle_loops": lifecycle_loops,
        "soak_seconds": soak_seconds,
        "sample_interval_seconds": interval_seconds,
        "service": {
            "health_status": health_status,
            "readyz_status": readyz_status,
            "health": {
                key: health[key]
                for key in ("status", "asr_ready", "tts_ready")
                if key in health
            },
            "readyz": {"ready": readyz.get("ready")} if "ready" in readyz else {},
        },
        "scenarios": scenarios,
        "scenario_pass": all(scenario.get("scenario_pass") is True for scenario in scenarios),
        "resource_evidence_complete": resource_evidence_complete,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8201/v1")
    parser.add_argument("--profile", required=True)
    parser.add_argument("--pcm-file", required=True, type=Path)
    parser.add_argument("--audio-file", required=True, type=Path)
    parser.add_argument("--app-home", type=Path)
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--lifecycle-loops", type=int, default=10)
    parser.add_argument("--soak-seconds", type=float, default=600.0)
    parser.add_argument("--sample-interval", type=float, default=0.1)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        result = run_scenario_suite(
            base_url=args.base_url,
            pcm_file=args.pcm_file,
            audio_file=args.audio_file,
            profile=args.profile,
            app_home=args.app_home,
            iterations=args.iterations,
            lifecycle_loops=args.lifecycle_loops,
            soak_seconds=args.soak_seconds,
            interval_seconds=args.sample_interval,
        )
        write_result(result, validate_output_path(args.output))
    except (OSError, TypeError, ValueError) as exc:
        print(f"error: {type(exc).__name__}", file=__import__("sys").stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
