"""Incremental (append-only) TTS latency benchmark for one utterance.

The full-text REST path already has ``bench_tts.py``.  This entry point measures
the *incremental* path instead: how long a real client waits from the moment it
submits the first stabilised text to the first playable PCM, and how fast the
model generates once it owns the utterance.

Two numbers are deliberately kept apart, because one without the other is
misleading:

* ``append_to_first_pcm_ms`` covers everything the caller does before the first
  byte of audio can be played, including the deliberate small-window wait that
  ``--append-interval-ms`` emulates.
* ``generation_rtf`` divides the window in which the model owned the utterance by
  the audio it produced.  The wait the caller itself inserts between two slices is
  subtracted as ``text_gap_ms``, because that gap is the caller's choice rather
  than model speed.

The trace follows the public contract for one incremental utterance: ``start``,
wait for ``speechrail.tts.started``, append one slice and wait for its
``speechrail.tts.text_accepted``, repeat, then ``finish_text`` carrying the last
acknowledged sequence.  It requires a running service with the TTS backend ready
and a voice whose incremental capability is ``supported``; running it against a
fake backend or an unsupported voice proves nothing.  Audio is counted and
discarded, never retained or written to a file.

Results are evidence only when they carry the surrounding manifest: keep the JSON
outside the repository and record the commit, profile, voice, variant and
quantization alongside it.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import json
import math
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from openai import OpenAI

from speechrail.config.auth import resolve_api_key

DEFAULT_SAMPLE_RATE = 24_000
_BYTES_PER_SAMPLE = 2


class RealtimeTurnError(RuntimeError):
    """A stable server error that ended the utterance before ``response.created``."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(f"realtime_error:{code}")


@dataclass(frozen=True, slots=True)
class StreamingTurnTrace:
    """Monotonic timestamps and byte counters for exactly one utterance."""

    submitted_at: float
    first_audio_at: float | None
    terminal_at: float
    audio_bytes: int
    sample_rate: int = DEFAULT_SAMPLE_RATE
    text_gap_seconds: float = 0.0
    failure: str | None = None

    @property
    def append_to_first_pcm_seconds(self) -> float | None:
        if self.first_audio_at is None:
            return None
        return self.first_audio_at - self.submitted_at

    @property
    def audio_seconds(self) -> float:
        return self.audio_bytes / (self.sample_rate * _BYTES_PER_SAMPLE)

    @property
    def generation_seconds(self) -> float | None:
        """Wall clock the model owned the utterance, minus caller-inserted gaps."""

        if self.first_audio_at is None:
            return None
        generating = self.terminal_at - self.first_audio_at - self.text_gap_seconds
        return max(0.0, generating)

    @property
    def generation_rtf(self) -> float | None:
        generating = self.generation_seconds
        if generating is None or self.audio_seconds <= 0:
            return None
        return generating / self.audio_seconds


def percentile(values: list[float], fraction: float) -> float | None:
    """Nearest-rank percentile over a non-empty sample; ``None`` when empty.

    The rank is rounded up rather than to the closest integer, so a small sample
    can never report a latency percentile below its true rank.
    """

    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = max(0, min(len(ordered) - 1, math.ceil(fraction * (len(ordered) - 1))))
    return ordered[rank]


@dataclass(frozen=True, slots=True)
class StreamingTurnSummary:
    samples: int
    append_to_first_pcm_ms_p50: float | None
    append_to_first_pcm_ms_p95: float | None
    generation_rtf_p50: float | None
    generation_rtf_p95: float | None
    text_gap_ms_p50: float | None
    text_gap_ms_p95: float | None
    completed_turns: int
    failed_turns: int
    failures: tuple[str, ...] = ()

    def as_dict(self) -> dict[str, object]:
        return {
            "schema": "speechrail-perf/tts-streaming/1",
            "samples": self.samples,
            "completed_turns": self.completed_turns,
            "failed_turns": self.failed_turns,
            "failures": list(self.failures),
            "append_to_first_pcm_ms": {
                "p50": self.append_to_first_pcm_ms_p50,
                "p95": self.append_to_first_pcm_ms_p95,
            },
            "generation_rtf": {
                "p50": self.generation_rtf_p50,
                "p95": self.generation_rtf_p95,
            },
            "text_gap_ms": {
                "p50": self.text_gap_ms_p50,
                "p95": self.text_gap_ms_p95,
            },
        }


def summarise(traces: list[StreamingTurnTrace]) -> StreamingTurnSummary:
    """Aggregate completed turns; incomplete turns are counted, never averaged in."""

    first_pcm = [
        seconds * 1000
        for trace in traces
        if (seconds := trace.append_to_first_pcm_seconds) is not None
    ]
    generation = [value for trace in traces if (value := trace.generation_rtf) is not None]
    text_gap = [
        trace.text_gap_seconds * 1000 for trace in traces if trace.first_audio_at is not None
    ]
    completed = sum(1 for trace in traces if trace.first_audio_at is not None)
    return StreamingTurnSummary(
        samples=len(first_pcm),
        append_to_first_pcm_ms_p50=percentile(first_pcm, 0.50),
        append_to_first_pcm_ms_p95=percentile(first_pcm, 0.95),
        generation_rtf_p50=percentile(generation, 0.50),
        generation_rtf_p95=percentile(generation, 0.95),
        text_gap_ms_p50=percentile(text_gap, 0.50),
        text_gap_ms_p95=percentile(text_gap, 0.95),
        completed_turns=completed,
        failed_turns=len(traces) - completed,
        failures=tuple(trace.failure for trace in traces if trace.failure is not None),
    )


def _append_schedule(text: str, slices: int, *, max_codepoints: int | None = None) -> list[str]:
    """Split ``text`` into non-empty slices of at most ``max_codepoints`` each.

    ``slices`` is the caller's requested granularity; a slice budget that is
    smaller than the resulting chunk wins, so the scheduler never emits an append
    the server would reject.
    """

    if slices < 1:
        raise ValueError("slices must be at least 1")
    if not text:
        raise ValueError("text must not be empty")
    if max_codepoints is not None and max_codepoints < 1:
        raise ValueError("max_codepoints must be at least 1")
    count = min(slices, len(text))
    if max_codepoints is not None:
        count = max(count, math.ceil(len(text) / max_codepoints))
    base, remainder = divmod(len(text), count)
    pieces: list[str] = []
    start = 0
    for index in range(count):
        size = base + (1 if index < remainder else 0)
        pieces.append(text[start : start + size])
        start += size
    return pieces


def _decode_audio(delta: object) -> bytes:
    if delta is None:
        return b""
    if isinstance(delta, bytes):
        return delta
    if not isinstance(delta, str):
        raise ValueError("audio delta must be base64 text")
    return base64.b64decode(delta, validate=True)


def _positive_int(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return None
    return value


def _started_sample_rate(event: dict[str, Any]) -> int | None:
    output_format = event.get("output_format")
    if not isinstance(output_format, dict):
        return None
    return _positive_int(output_format.get("sample_rate"))


def _audio_sample_rate(event: dict[str, Any]) -> int | None:
    metadata = event.get("speechrail")
    if not isinstance(metadata, dict):
        return None
    return _positive_int(metadata.get("sample_rate"))


def _append_limit(event: dict[str, Any]) -> int | None:
    limits = event.get("limits")
    if not isinstance(limits, dict):
        return None
    return _positive_int(limits.get("max_append_codepoints"))


def _response_status(event: dict[str, Any]) -> str | None:
    response = event.get("response")
    if not isinstance(response, dict):
        return None
    status = response.get("status")
    return status if isinstance(status, str) else None


def _event_object(event: object) -> dict[str, Any]:
    """Normalize one server event to a plain mapping.

    The pinned openai SDK parses the events it knows into typed models and leaves
    the ``speechrail.tts.*`` extensions as dicts, so a real connection yields
    both shapes on the same stream.  Normalizing here keeps the trace logic on a
    single representation without teaching it about SDK internals.
    """

    if isinstance(event, dict):
        return event
    dump = getattr(event, "model_dump", None)
    if callable(dump):
        payload = dump(mode="json")
        if isinstance(payload, dict):
            return payload
    raise ValueError("realtime event must be an object")


def _recv(connection: Any, deadline: float, clock: Callable[[], float]) -> dict[str, Any]:
    event = connection.recv()
    if clock() > deadline:
        raise TimeoutError("incremental TTS benchmark timed out")
    return _event_object(event)


def _recv_until(
    connection: Any,
    deadline: float,
    clock: Callable[[], float],
    wanted: frozenset[str],
) -> dict[str, Any]:
    while True:
        event = _recv(connection, deadline, clock)
        if event.get("type") in wanted:
            return event
        if event.get("type") == "error":
            raise RealtimeTurnError(_error_code(event))


def _error_code(event: dict[str, Any]) -> str:
    error = event.get("error")
    if isinstance(error, dict) and isinstance(error.get("code"), str):
        return str(error["code"])
    return "realtime_error"


def run_incremental_turn(
    connection: Any,
    *,
    text: str,
    voice: str | None = None,
    slices: int = 3,
    append_interval_seconds: float = 0.0,
    timeout_seconds: float = 120.0,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> StreamingTurnTrace:
    """Drive one ``speechrail.tts.start`` utterance over an open realtime session.

    ``connection`` only has to expose ``send(dict)`` and ``recv()``; both the
    openai SDK realtime connection and a plain websocket satisfy that.  Text,
    slicing, clock and sleep are injected so the whole protocol path is covered by
    deterministic tests without a service.
    """

    if append_interval_seconds < 0:
        raise ValueError("append_interval_seconds must not be negative")
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    deadline = clock() + timeout_seconds

    connection.send(
        {
            "type": "transcription_session.update",
            "session": {"speechrail": {"tts": {"enabled": True}}},
        }
    )
    _recv_until(connection, deadline, clock, frozenset({"transcription_session.updated"}))

    request_id = f"bench_stream_{int(clock() * 1000)}"
    start: dict[str, Any] = {"type": "speechrail.tts.start", "request_id": request_id}
    if voice is not None:
        start["voice"] = voice
    submitted_at = clock()
    connection.send(start)

    pieces: list[str] = []
    gaps: list[tuple[float, float]] = []
    first_audio_at: float | None = None
    terminal_at = submitted_at
    audio_bytes = 0
    sample_rate = DEFAULT_SAMPLE_RATE
    started = False
    created = False
    finish_sent = False
    sent = 0
    accepted_sequence = -1
    acknowledged_at = submitted_at
    failure: str | None = None

    while True:
        if started and not finish_sent:
            if sent < len(pieces):
                if sent:
                    if append_interval_seconds:
                        sleep(append_interval_seconds)
                    sent_at = clock()
                    gaps.append((acknowledged_at, sent_at))
                connection.send(
                    {
                        "type": "speechrail.tts.append_text",
                        "request_id": request_id,
                        "sequence": sent,
                        "text": pieces[sent],
                    }
                )
                sent += 1
            elif accepted_sequence == len(pieces) - 1:
                connection.send(
                    {
                        "type": "speechrail.tts.finish_text",
                        "request_id": request_id,
                        "last_sequence": accepted_sequence,
                    }
                )
                finish_sent = True

        event = _recv(connection, deadline, clock)
        now = clock()
        kind = event.get("type")

        if kind == "response.created":
            created = True
        elif kind == "speechrail.tts.started":
            started = True
            sample_rate = _started_sample_rate(event) or sample_rate
            pieces = _append_schedule(text, slices, max_codepoints=_append_limit(event))
        elif kind == "speechrail.tts.text_accepted":
            sequence = event.get("append_sequence")
            if isinstance(sequence, int) and not isinstance(sequence, bool):
                accepted_sequence = sequence
            acknowledged_at = now
        elif kind == "response.output_audio.delta":
            chunk = _decode_audio(event.get("delta"))
            sample_rate = _audio_sample_rate(event) or sample_rate
            if chunk and first_audio_at is None:
                first_audio_at = now
            audio_bytes += len(chunk)
        elif kind == "error":
            code = _error_code(event)
            if not created:
                raise RealtimeTurnError(code)
            failure = failure or code
        elif kind == "response.done":
            terminal_at = now
            status = _response_status(event)
            if status is not None and status != "completed":
                failure = failure or f"response_{status}"
            break

    if audio_bytes % _BYTES_PER_SAMPLE:
        raise ValueError("incremental TTS benchmark received truncated PCM16 audio")
    text_gap_seconds = 0.0
    if first_audio_at is not None:
        text_gap_seconds = sum(max(0.0, end - max(start, first_audio_at)) for start, end in gaps)
    return StreamingTurnTrace(
        submitted_at=submitted_at,
        first_audio_at=first_audio_at,
        terminal_at=terminal_at,
        audio_bytes=audio_bytes,
        sample_rate=sample_rate,
        text_gap_seconds=text_gap_seconds,
        failure=failure,
    )


def failed_trace(message: str) -> StreamingTurnTrace:
    """Represent one turn that produced no trace at all, so it still counts."""

    return StreamingTurnTrace(
        submitted_at=0.0,
        first_audio_at=None,
        terminal_at=0.0,
        audio_bytes=0,
        failure=message,
    )


def summary_line(trace: StreamingTurnTrace) -> str:
    first = trace.append_to_first_pcm_seconds
    rtf_value = trace.generation_rtf
    text = f"first_pcm={first * 1000:.0f}ms " if first is not None else "first_pcm=n/a "
    text += f"rtf={rtf_value:.2f} " if rtf_value is not None else "rtf=n/a "
    text += f"text_gap={trace.text_gap_seconds * 1000:.0f}ms"
    if trace.failure is not None:
        text += f" failure={trace.failure}"
    return text


def main() -> None:
    parser = argparse.ArgumentParser(description="Incremental TTS latency benchmark")
    parser.add_argument("--base-url", default="http://127.0.0.1:8201/v1")
    parser.add_argument("--model", default="whisper-1")
    parser.add_argument("--app-home", type=Path, help="managed app home for API-key discovery")
    parser.add_argument("--text", default="你好，这是一次增量朗读的延迟测量。")
    parser.add_argument("--voice", default=None, help="registered voice id")
    parser.add_argument("--repeat", type=int, default=5)
    parser.add_argument("--slices", type=int, default=3)
    parser.add_argument(
        "--append-interval-ms",
        type=float,
        default=0.0,
        help="wait between slices, emulating an LLM that is still typing",
    )
    parser.add_argument("--timeout-seconds", type=float, default=120.0)
    parser.add_argument(
        "--output", type=Path, help="write the summary JSON to this path (keep it outside the repo)"
    )
    args = parser.parse_args()

    client = OpenAI(
        api_key=resolve_api_key(app_home=args.app_home) or "local",
        base_url=args.base_url,
    )
    traces: list[StreamingTurnTrace] = []
    for index in range(args.repeat):
        connection = client.realtime.connect(model=args.model).enter()
        try:
            trace = run_incremental_turn(
                connection,
                text=args.text,
                voice=args.voice,
                slices=args.slices,
                append_interval_seconds=args.append_interval_ms / 1000,
                timeout_seconds=args.timeout_seconds,
            )
        # One bad turn must not end the run: keep it visible in the summary.
        except Exception as exc:
            trace = failed_trace(f"{type(exc).__name__}:{exc}"[:120])
        finally:
            with contextlib.suppress(Exception):
                connection.close()
        traces.append(trace)
        print(f"[turn {index + 1}/{args.repeat}] {summary_line(trace)}")

    summary = summarise(traces)
    payload = json.dumps(summary.as_dict(), ensure_ascii=False, indent=2)
    print(payload)
    if args.output is not None:
        args.output.write_text(payload + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
