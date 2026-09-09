"""Realtime WS benchmark with resource sampling, writing one JSON evidence file.

Runs the same OpenAI-SDK realtime session as ``bench_realtime.py`` (ASR commit
latency, TTS first-audio-delta, transcript presence) but wraps the measured
sessions in a real ``ProcessResourceMonitor`` and persists a sanitized result
in the ``speechrail-bench-realtime`` schema (v1). The warm-up session is
excluded from statistics; set ``--no-warmup`` only when the model is confirmed
unloaded and a genuine cold measurement is intended.

Usage:
  uv run python examples/perf/bench_realtime_json.py audio_10s_16k.pcm \
    --profile quality --output /tmp/quality-realtime.json \
    --app-home "$HOME/Library/Application Support/SpeechRail"
"""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path

try:
    from .bench_realtime import run_session
    from .benchmark_resources import ProcessResourceMonitor, _normalise_resources
except ImportError:  # pragma: no cover - exercised when run as a script
    from bench_realtime import run_session  # type: ignore[no-redef]
    from benchmark_resources import (  # type: ignore[no-redef]
        ProcessResourceMonitor,
        _normalise_resources,
    )

from openai import OpenAI

from speechrail.config.auth import resolve_api_key


def _sanitize_session(result: dict[str, object], session_no: int) -> dict[str, object]:
    """Project one raw realtime session onto the persisted evidence shape."""
    return {
        "session": session_no,
        "setup_ms": result["setup_ms"],
        "asr_ms": result["asr_ms"],
        "audio_s": result["audio_s"],
        "asr_rtf": result["asr_rtf"],
        "tts_first_delta_ms": result["tts_first_delta_ms"],
        "tts_bytes": result["tts_bytes"],
        "transcript_present": result["transcript_present"],
        "transcript_chars": result["transcript_chars"],
    }


def run_realtime_benchmark(
    pcm_file: Path,
    *,
    profile: str,
    output: Path,
    sessions: int,
    warmup: bool,
    tts_text: str,
    app_home: Path | None,
    base_url: str,
) -> dict[str, object]:
    """Run warm-up plus N measured sessions under one resource window."""
    if sessions < 1:
        raise ValueError("sessions must be positive")
    pcm = pcm_file.read_bytes()
    if not pcm or len(pcm) % 2:
        raise ValueError("pcm_file must contain non-empty even-length PCM16")
    if output.exists() or output.is_symlink():
        raise FileExistsError("output would overwrite an existing file")
    if not output.parent.is_dir():
        raise FileExistsError("output parent directory does not exist")

    api_key = resolve_api_key(app_home=app_home) or "local"
    client = OpenAI(api_key=api_key, base_url=base_url)

    if warmup:
        run_session(client, pcm, tts_text, 0)

    monitor = ProcessResourceMonitor(interval_seconds=0.25)
    monitor.start()
    session_results: list[dict[str, object]] = []
    try:
        for session_no in range(1, sessions + 1):
            result = run_session(client, pcm, tts_text, session_no)
            session_results.append(_sanitize_session(result, session_no))
    finally:
        raw = monitor.stop()

    payload: dict[str, object] = {
        "schema_version": 1,
        "tool": "speechrail-bench-realtime",
        "evidence_mode": "real",
        "profile": profile.strip().lower(),
        "warmup_completed": warmup,
        "sessions": session_results,
        "resources": _normalise_resources(raw),
    }
    fd = output.open("x", encoding="utf-8", newline="\n")
    try:
        fd.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    finally:
        fd.close()
    return payload


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pcm_file", type=Path, help="16 kHz mono PCM16 fixture")
    parser.add_argument("--profile", required=True, choices=("quality", "balanced", "light"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--sessions", type=int, default=3)
    parser.add_argument("--warmup", dest="warmup", action="store_true", default=True)
    parser.add_argument(
        "--no-warmup",
        dest="warmup",
        action="store_false",
        help="measure from unloaded state",
    )
    parser.add_argument("--tts-text", default="本地实时语音合成性能测试。")
    parser.add_argument("--base-url", default="http://127.0.0.1:8201/v1")
    parser.add_argument("--app-home", type=Path, help="managed app home for API-key discovery")
    args = parser.parse_args(argv)
    try:
        payload = run_realtime_benchmark(
            args.pcm_file,
            profile=args.profile,
            output=args.output,
            sessions=args.sessions,
            warmup=args.warmup,
            tts_text=args.tts_text,
            app_home=args.app_home,
            base_url=args.base_url,
        )
    except (OSError, ValueError, TypeError) as exc:
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    resources = payload["resources"]
    assert isinstance(resources, dict)
    if isinstance(payload["sessions"], list):
        print(
            f"wrote {args.output} sessions={len(payload['sessions'])} "
            f"sampling_complete={resources.get('sampling_complete')}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
