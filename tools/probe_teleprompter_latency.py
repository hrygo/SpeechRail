"""Measure teleprompter realtime snapshot latency without persisting transcript text.

The input WAV must be a local, authorized 16 kHz mono PCM16 fixture. Audio is
sent at its real 100 ms cadence; burst uploading would hide the latency that a
speaker experiences. The output contains only timings, bounded event counts,
revision diagnostics, and audio duration. It never writes transcript text,
item IDs, event IDs, audio bytes, or text hashes.

Usage:
  uv run python tools/probe_teleprompter_latency.py <external.wav> \
    --profile quality --output <external-result.json> \
    --app-home "/Users/hrygo/Library/Application Support/SpeechRail"
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import itertools
import json
import queue
import threading
import time
import wave
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from openai import OpenAI

from speechrail.config.auth import resolve_api_key  # type: ignore[import-untyped]

UPLOAD_CHUNK_MILLISECONDS = 100
SAMPLE_RATE = 16_000
CHANNELS = 1
SAMPLE_WIDTH_BYTES = 2


class ProbeInputError(ValueError):
    """Raised when a probe input violates the realtime evidence contract."""


class RealtimeProbeError(RuntimeError):
    """Raised when the realtime service returns a stable error event."""

    def __init__(self, code: str) -> None:
        self.code = code[:96] or "unknown"
        super().__init__(f"realtime_error:{self.code}")


@dataclass(frozen=True, slots=True)
class WaveFixture:
    pcm: bytes
    duration_seconds: float


def load_wave_fixture(path: Path) -> WaveFixture:
    """Read and validate an external 16 kHz mono PCM16 WAV."""

    try:
        with wave.open(str(path), "rb") as source:
            if (
                source.getframerate() != SAMPLE_RATE
                or source.getnchannels() != CHANNELS
                or source.getsampwidth() != SAMPLE_WIDTH_BYTES
                or source.getcomptype() != "NONE"
            ):
                raise ProbeInputError("WAV must be 16 kHz mono PCM16")
            frame_count = source.getnframes()
            pcm = source.readframes(frame_count)
    except (OSError, EOFError, wave.Error) as exc:
        raise ProbeInputError("WAV could not be read") from exc
    if not pcm or len(pcm) % SAMPLE_WIDTH_BYTES:
        raise ProbeInputError("WAV must contain non-empty PCM16 audio")
    return WaveFixture(pcm=pcm, duration_seconds=len(pcm) / (SAMPLE_RATE * SAMPLE_WIDTH_BYTES))


def percentile(values: Sequence[float], ratio: float) -> float | None:
    """Return a nearest-rank percentile for a bounded list of timings."""

    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(len(ordered) * ratio + 0.999999) - 1))
    return ordered[index]


def timing_summary(values: Sequence[float]) -> dict[str, float | int | None]:
    """Project timing samples to a small JSON-safe summary."""

    if not values:
        return {"count": 0, "p50_ms": None, "p95_ms": None, "max_ms": None}
    return {
        "count": len(values),
        "p50_ms": percentile(values, 0.50),
        "p95_ms": percentile(values, 0.95),
        "max_ms": max(values),
    }


def _value(event: object, key: str) -> object:
    if isinstance(event, dict):
        return event.get(key)
    return getattr(event, key, None)


def _event_type(event: object) -> str:
    return str(_value(event, "type") or "unknown")


def _error_code(event: object) -> str:
    error = _value(event, "error")
    code = _value(error, "code")
    return str(code or "unknown")


def _receive_loop(
    events: queue.Queue[tuple[float, object]],
    errors: list[Exception],
    connection: Any,
) -> None:
    try:
        while True:
            events.put((time.monotonic(), connection.recv()))
    except Exception as exc:  # socket close is observed by the waiter
        errors.append(exc)


def _receive_until(
    events: queue.Queue[tuple[float, object]],
    errors: list[Exception],
    target: str,
    *,
    timeout_seconds: float,
) -> tuple[float, object]:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if errors:
            raise errors[0]
        try:
            received_at, event = events.get(
                timeout=min(1.0, max(0.01, deadline - time.monotonic()))
            )
        except queue.Empty:
            continue
        event_type = _event_type(event)
        if event_type == "error":
            raise RealtimeProbeError(_error_code(event))
        if event_type == target:
            return received_at, event
    raise TimeoutError(f"realtime event timeout: {target}")


def run_probe(
    fixture: WaveFixture,
    *,
    base_url: str,
    app_home: Path | None,
    model: str,
    chunk_duration_ms: int,
) -> dict[str, object]:
    """Run one real-time snapshot session and return sanitized evidence."""

    if chunk_duration_ms not in {500, 1_000, 2_000}:
        raise ProbeInputError("chunk duration must be 500, 1000, or 2000 ms")
    client = OpenAI(api_key=resolve_api_key(app_home=app_home) or "local", base_url=base_url)
    connection: Any = client.realtime.connect(model=model).enter()
    events: queue.Queue[tuple[float, object]] = queue.Queue()
    errors: list[Exception] = []
    receiver = threading.Thread(
        target=_receive_loop,
        args=(events, errors, connection),
        name="speechrail-teleprompter-probe-receiver",
        daemon=True,
    )
    receiver.start()

    event_counts: Counter[str] = Counter()
    upload_lateness: list[float] = []
    snapshot_gaps: list[float] = []
    revisions: list[int] = []
    first_snapshot_at: float | None = None
    completed_at: float | None = None
    stream_started = time.monotonic()
    try:
        created_at, _ = _receive_until(
            events, errors, "session.created", timeout_seconds=15
        )
        event_counts["session.created"] += 1
        connection.send(
            {
                "type": "transcription_session.update",
                "session": {
                    "input_audio_format": "pcm16",
                    "input_audio_transcription": {"model": model, "language": "zh"},
                    "turn_detection": {"type": "manual"},
                    "speechrail": {
                        "transcription": {
                            "partial_mode": "snapshot",
                            "chunk_duration_ms": chunk_duration_ms,
                        }
                    },
                },
            }
        )
        configured_at, _ = _receive_until(
            events, errors, "transcription_session.updated", timeout_seconds=15
        )
        event_counts["transcription_session.updated"] += 1

        bytes_per_chunk = SAMPLE_RATE * SAMPLE_WIDTH_BYTES * UPLOAD_CHUNK_MILLISECONDS // 1_000
        chunk_count = 0
        for offset in range(0, len(fixture.pcm), bytes_per_chunk):
            scheduled_at = stream_started + chunk_count * UPLOAD_CHUNK_MILLISECONDS / 1_000
            time.sleep(max(0.0, scheduled_at - time.monotonic()))
            sent_at = time.monotonic()
            upload_lateness.append(max(0.0, (sent_at - scheduled_at) * 1_000))
            chunk = fixture.pcm[offset:offset + bytes_per_chunk]
            connection.send(
                {
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(chunk).decode("ascii"),
                }
            )
            chunk_count += 1
        connection.send({"type": "input_audio_buffer.commit"})

        last_snapshot_at: float | None = None
        while completed_at is None:
            received_at, event = events.get(timeout=60)
            event_type = _event_type(event)
            event_counts[event_type] += 1
            if event_type == "error":
                raise RealtimeProbeError(_error_code(event))
            if event_type == "speechrail.transcription.snapshot":
                if first_snapshot_at is None:
                    first_snapshot_at = received_at
                if last_snapshot_at is not None:
                    snapshot_gaps.append((received_at - last_snapshot_at) * 1_000)
                last_snapshot_at = received_at
                revision = _value(event, "revision")
                if isinstance(revision, int):
                    revisions.append(revision)
            elif event_type == "conversation.item.input_audio_transcription.completed":
                completed_at = received_at
    finally:
        with contextlib.suppress(Exception):
            connection.close()

    revision_regressions = sum(
        1 for previous, current in itertools.pairwise(revisions) if current <= previous
    )
    return {
        "schema_version": 1,
        "tool": "speechrail-probe-teleprompter-latency",
        "evidence_mode": "real",
        "model": model,
        "partial_mode": "snapshot",
        "chunk_duration_ms": chunk_duration_ms,
        "upload_chunk_ms": UPLOAD_CHUNK_MILLISECONDS,
        "audio_seconds": fixture.duration_seconds,
        "setup_ms": (configured_at - created_at) * 1_000,
        "upload_lateness": timing_summary(upload_lateness),
        "snapshot_gap": timing_summary(snapshot_gaps),
        "first_snapshot_ms": (
            None if first_snapshot_at is None else (first_snapshot_at - stream_started) * 1_000
        ),
        "completed_ms": (
            None if completed_at is None else (completed_at - stream_started) * 1_000
        ),
        "snapshot_count": len(revisions),
        "revision_regressions": revision_regressions,
        "event_counts": dict(sorted(event_counts.items())),
        "audio_chunks": chunk_count,
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav_file", type=Path)
    parser.add_argument("--profile", required=True, choices=("quality", "balanced", "light"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--app-home", type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:8201/v1")
    parser.add_argument("--model", default="whisper-1")
    parser.add_argument("--chunk-duration-ms", type=int, default=500)
    args = parser.parse_args(argv)
    try:
        if args.output.exists() or args.output.is_symlink():
            raise ProbeInputError("output already exists")
        if not args.output.parent.is_dir():
            raise ProbeInputError("output parent directory does not exist")
        fixture = load_wave_fixture(args.wav_file)
        result = run_probe(
            fixture,
            base_url=args.base_url,
            app_home=args.app_home,
            model=args.model,
            chunk_duration_ms=args.chunk_duration_ms,
        )
        result["profile"] = args.profile
        args.output.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
    except (OSError, ProbeInputError, RealtimeProbeError, TimeoutError) as exc:
        print(f"error: {type(exc).__name__}: {exc}")
        return 2
    print(f"wrote {args.output} snapshots={result['snapshot_count']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
