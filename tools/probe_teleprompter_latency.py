"""Measure teleprompter realtime hypothesis latency without persisting transcript text.

The input WAV must be a local, authorized 24 kHz mono PCM16 fixture (the single
realtime wire rate). Audio is sent at its real 100 ms cadence; burst uploading
would hide the latency that a speaker experiences. The current wire exposes one
mutable partial-text event, ``speechrail.transcription.hypothesis``; the probe
times its cadence and revision monotonicity. The output contains only timings,
bounded event counts, revision diagnostics, and audio duration. It never writes
transcript text, item IDs, event IDs, audio bytes, or text hashes.

Usage:
  uv run python tools/probe_teleprompter_latency.py <external.wav> \
    --profile quality --output <external-result.json> \
    --app-home "$SPEECHRAIL_APP_HOME"
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import json
import platform
import queue
import threading
import time
import wave
from collections import Counter
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from uuid import uuid4

from openai import OpenAI

from speechrail.config.auth import resolve_api_key  # type: ignore[import-untyped]

UPLOAD_CHUNK_MILLISECONDS = 100
SAMPLE_RATE = 24_000
CHANNELS = 1
SAMPLE_WIDTH_BYTES = 2
MAX_RECEIVE_QUEUE_EVENTS = 2_048
# 方案 §11.6 要求每份延迟报告都带语言. 会话配置与证据文件必须用同一个常量,
# 否则「探针跑的是哪条语言」这件事会只存在于一个没人复查的字面量里.
LANGUAGE = "zh"


class ProbeInputError(ValueError):
    """Raised when a probe input violates the realtime evidence contract."""


class RealtimeProbeError(RuntimeError):
    """Raised when the realtime service returns a stable error event."""

    def __init__(self, code: str) -> None:
        self.code = code[:96] or "unknown"
        super().__init__(f"realtime_error:{self.code}")


class RealtimeQueueOverflowError(RuntimeError):
    """Raised when the probe cannot keep up with the realtime event stream."""


class RevisionTracker:
    """Count hypotheses and detect regressions within each utterance."""

    def __init__(self) -> None:
        self.partial_count = 0
        self.utterance_count = 0
        self._last_revision: dict[str, int] = {}
        self.revision_regressions = 0

    def record(self, utterance_id: object, revision: object) -> None:
        self.partial_count += 1
        if not isinstance(revision, int) or revision <= 0:
            return
        key = str(utterance_id or "unknown")
        previous = self._last_revision.get(key)
        if previous is not None and revision <= previous:
            self.revision_regressions += 1
        if key not in self._last_revision:
            self.utterance_count += 1
        self._last_revision[key] = revision


@dataclass(slots=True)
class _ProbeMeasurements:
    revisions: RevisionTracker = field(default_factory=RevisionTracker)
    partial_gaps: list[float] = field(default_factory=list)
    first_partial_at: float | None = None
    last_partial_at: float | None = None

    def record_hypothesis(self, received_at: float, event: object) -> None:
        if self.first_partial_at is None:
            self.first_partial_at = received_at
        if self.last_partial_at is not None:
            self.partial_gaps.append((received_at - self.last_partial_at) * 1_000)
        self.last_partial_at = received_at
        self.revisions.record(_value(event, "utterance_id"), _value(event, "revision"))


@dataclass(frozen=True, slots=True)
class WaveFixture:
    pcm: bytes
    duration_seconds: float


def probe_condition(model: str) -> dict[str, str]:
    """The language, device and model every latency report must carry (plan 11.6).

    The device label stays limited to system and architecture. Host name, user
    name and absolute paths would make the evidence file identify somebody.
    """

    return {
        "language": LANGUAGE,
        "device": f"{platform.system()}-{platform.machine()}",
        "model": model,
    }


def session_update_payload(model: str) -> dict[str, object]:
    """The single session configuration this probe ever sends.

    抽出来是为了让「会话用的语言」和「证据文件里写的语言」共用同一个常量这件
    事可测: 内联字面量时, 改了一处忘了另一处不会让任何用例变红.
    """

    return {
        "type": "session.update",
        "session": {
            "type": "transcription",
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": SAMPLE_RATE},
                    "transcription": {"model": model, "language": LANGUAGE},
                    "turn_detection": "manual",
                }
            },
            "speechrail": {"task": "caption"},
        },
    }


def load_wave_fixture(path: Path) -> WaveFixture:
    """Read and validate an external 24 kHz mono PCM16 WAV."""

    try:
        with wave.open(str(path), "rb") as source:
            if (
                source.getframerate() != SAMPLE_RATE
                or source.getnchannels() != CHANNELS
                or source.getsampwidth() != SAMPLE_WIDTH_BYTES
                or source.getcomptype() != "NONE"
            ):
                raise ProbeInputError("WAV must be 24 kHz mono PCM16")
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


def _media_origin_after_configuration(
    clock: Any,
    created_at: float,
    configured_at: float,
) -> float:
    """Return the first-audio origin after configuration is acknowledged."""

    now = clock()
    if now < configured_at:
        raise RuntimeError("monotonic clock moved backwards before media start")
    del created_at  # Setup latency is reported separately from media latency.
    return configured_at


def _receive_loop(
    events: queue.Queue[tuple[float, object]],
    errors: list[Exception],
    connection: Any,
    clock: Any = time.monotonic,
    max_queue_events: int = MAX_RECEIVE_QUEUE_EVENTS,
) -> None:
    try:
        while True:
            event = connection.recv()
            received_at = clock()
            try:
                events.put_nowait((received_at, event))
            except queue.Full:
                raise RealtimeQueueOverflowError(
                    f"realtime event queue exceeded {max_queue_events} items"
                ) from None
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


def _event_matches_commit(event: object, commit_event_id: str) -> bool:
    return (
        _event_type(event)
        in {
            "conversation.item.input_audio_transcription.completed",
            "conversation.item.input_audio_transcription.failed",
        }
        and _value(event, "commit_event_id") == commit_event_id
    )


def _wait_for_terminal(
    events: queue.Queue[tuple[float, object]],
    errors: list[Exception],
    commit_event_id: str,
    *,
    deadline: Any,
    on_event: Any | None = None,
) -> tuple[float, object, str]:
    while True:
        if errors:
            raise errors[0]
        remaining = deadline() - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("realtime terminal deadline exceeded")
        try:
            received_at, event = events.get(timeout=min(1.0, remaining))
        except queue.Empty:
            continue
        event_type = _event_type(event)
        if event_type == "error":
            raise RealtimeProbeError(_error_code(event))
        if on_event is not None:
            on_event(received_at, event, event_type)
        if _event_matches_commit(event, commit_event_id):
            return received_at, event, event_type


def build_evidence(
    *,
    model: str,
    fixture: WaveFixture,
    created_at: float,
    configured_at: float,
    stream_started: float,
    completed_at: float | None,
    measurements: _ProbeMeasurements,
    upload_lateness: Sequence[float],
    event_counts: Mapping[str, int],
    chunk_count: int,
) -> dict[str, object]:
    """Project one probe run into the JSON-safe evidence file.

    抽成纯函数是为了让证据文件的形状本身可测. 它此前只是 run_probe 末尾的
    一个字典字面量, 没有任何测试碰过, 于是「方案 §11.6 要求带的语言与设备没
    带出去」这类问题不会让任何用例变红.
    """

    audio_ms = fixture.duration_seconds * 1_000
    completed_ms = None if completed_at is None else (completed_at - stream_started) * 1_000
    return {
        # 4: 新增 condition(语言/设备/模型, 方案 §11.6 要求) 与
        # completed_after_audio_ms; 顶层 model 移入 condition. #108 的验收标准
        # 就是「JSON 明确版本演进」, 所以形状变了必须升版本, 不能悄悄改.
        "schema_version": 4,
        "tool": "speechrail-probe-teleprompter-latency",
        "evidence_mode": "real",
        "condition": probe_condition(model),
        "partial_mode": "hypothesis",
        "upload_chunk_ms": UPLOAD_CHUNK_MILLISECONDS,
        "audio_seconds": fixture.duration_seconds,
        "setup_ms": (configured_at - created_at) * 1_000,
        "upload_lateness": timing_summary(upload_lateness),
        "partial_gap": timing_summary(measurements.partial_gaps),
        "first_partial_ms": (
            None
            if measurements.first_partial_at is None
            else (measurements.first_partial_at - stream_started) * 1_000
        ),
        "completed_ms": completed_ms,
        # completed_ms 相对媒体起点, 整段音频时长是它的下界: 41 秒素材配 40 秒
        # commit 往返, 它读起来仍像「延迟」. 这一项才是 commit 往返.
        "completed_after_audio_ms": (
            None if completed_ms is None else completed_ms - audio_ms
        ),
        "partial_count": measurements.revisions.partial_count,
        "utterance_count": measurements.revisions.utterance_count,
        "revision_regressions": measurements.revisions.revision_regressions,
        "event_counts": dict(sorted(event_counts.items())),
        "audio_chunks": chunk_count,
    }


def run_probe(
    fixture: WaveFixture,
    *,
    base_url: str,
    app_home: Path | None,
    model: str,
) -> dict[str, object]:
    """Run one real-time hypothesis session and return sanitized evidence."""

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
    measurements = _ProbeMeasurements()
    completed_at: float | None = None
    stream_started: float | None = None
    probe_deadline = time.monotonic() + max(60.0, fixture.duration_seconds * 3 + 30.0)
    try:
        created_at, _ = _receive_until(
            events, errors, "session.created", timeout_seconds=15
        )
        event_counts["session.created"] += 1
        connection.send(session_update_payload(model))
        configured_at, _ = _receive_until(
            events, errors, "session.updated", timeout_seconds=15
        )
        event_counts["session.updated"] += 1
        stream_started = _media_origin_after_configuration(
            time.monotonic, created_at, configured_at
        )

        bytes_per_chunk = SAMPLE_RATE * SAMPLE_WIDTH_BYTES * UPLOAD_CHUNK_MILLISECONDS // 1_000
        chunk_count = 0
        for offset in range(0, len(fixture.pcm), bytes_per_chunk):
            scheduled_at = stream_started + chunk_count * UPLOAD_CHUNK_MILLISECONDS / 1_000
            time.sleep(max(0.0, scheduled_at - time.monotonic()))
            if errors:
                raise errors[0]
            if time.monotonic() >= probe_deadline:
                raise TimeoutError("realtime upload deadline exceeded")
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
        commit_event_id = f"probe-commit-{uuid4().hex}"
        connection.send({"type": "input_audio_buffer.commit", "event_id": commit_event_id})

        def record_event(received_at: float, event: object, event_type: str) -> None:
            event_counts[event_type] += 1
            if event_type != "speechrail.transcription.hypothesis":
                return
            measurements.record_hypothesis(received_at, event)

        received_at, event, event_type = _wait_for_terminal(
            events,
            errors,
            commit_event_id,
            deadline=lambda: probe_deadline,
            on_event=record_event,
        )
        event_counts[event_type] += 1
        if event_type.endswith(".failed"):
            raise RealtimeProbeError(_error_code(event))
        completed_at = received_at
    finally:
        with contextlib.suppress(Exception):
            connection.close()

    assert stream_started is not None
    return build_evidence(
        model=model,
        fixture=fixture,
        created_at=created_at,
        configured_at=configured_at,
        stream_started=stream_started,
        completed_at=completed_at,
        measurements=measurements,
        upload_lateness=upload_lateness,
        event_counts=event_counts,
        chunk_count=chunk_count,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav_file", type=Path)
    parser.add_argument(
        "--profile",
        required=True,
        choices=("fast", "quality", "reference"),
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--app-home", type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:8201/v1")
    parser.add_argument("--model", default="whisper-1")
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
        )
        result["profile"] = args.profile
        args.output.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
    except (
        OSError,
        ProbeInputError,
        RealtimeProbeError,
        RealtimeQueueOverflowError,
        TimeoutError,
    ) as exc:
        print(f"error: {type(exc).__name__}: {exc}")
        return 2
    print(f"wrote {args.output} partials={result['partial_count']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
