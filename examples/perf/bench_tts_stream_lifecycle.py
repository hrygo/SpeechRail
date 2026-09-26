"""Cancel, interrupt and soak benchmark for incremental TTS.

``bench_tts_streaming`` measures how fast the first audio byte arrives and how
fast the model generates.  This entry point covers the rest of the lifecycle
budget in §8.2:

* ``cancel_to_last_audio_ms`` — how long the server keeps sending audio after
  ``speechrail.tts.cancel``.  The contract promises no stale audio, so the byte
  counter after the cancel must stay at zero.
* ``cancel_to_terminal_ms`` — how long the model keeps the utterance before the
  single ``speechrail.tts.cancelled`` terminal (budget: P95 ≤ 500 ms).
* ``next_start_accepted_ms`` — proof that the slot really was released: a fresh
  ``speechrail.tts.start`` on the same connection is accepted that fast after the
  cancel, which cannot happen if the previous utterance still held the stream.

``--mode soak`` repeats complete / interrupt / idle-cancel-failure cycles and
samples ``/metrics`` between them, so a leaked session, a wedged worker or a
never-released governance slot shows up as a rising gauge or as a worker that
never returns to ``warm_standby``.  Each sample also carries the service's own
physical footprint, its process count and whether that reading was complete,
plus the completed-reservation counter, so recovery and the memory trend are
read separately instead of being inferred from one another.

The trace follows the public contract: session update, ``speechrail.tts.start``,
wait for ``speechrail.tts.started``, append one slice, wait for
``speechrail.tts.text_accepted``, wait for the first PCM, then
``speechrail.tts.cancel``.  Audio is counted and discarded, never retained.
Results are evidence only with the surrounding manifest (commit, profile, voice,
variant, quantization); keep the JSON outside the repository.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import sys
import time
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from openai import OpenAI

sys.path.insert(0, str(Path(__file__).resolve().parent))

from bench_tts_streaming import (
    _BYTES_PER_SAMPLE,
    _DEFAULT_ASR_MODEL,
    DEFAULT_SAMPLE_RATE,
    DEFAULT_VOICE,
    RealtimeTurnError,
    _decode_audio,
    _error_code,
    _failure_code,
    _recv,
    _recv_until,
    _started_sample_rate,
    percentile,
    run_incremental_turn,
    session_update_event,
)

from speechrail.config.auth import resolve_api_key

_IDLE_CANCEL_PROBE = "bench_lifecycle_idle_cancel"
_GAUGES = (
    "speechrail_realtime_active_sessions",
    'speechrail_governor_active_requests{class="batch"}',
    'speechrail_governor_active_requests{class="realtime"}',
    'speechrail_worker_status{component="streaming",state="active"}',
    'speechrail_worker_status{component="tts",state="active"}',
    'speechrail_worker_status{component="streaming",state="warm_standby"}',
    'speechrail_worker_status{component="tts",state="warm_standby"}',
    'speechrail_worker_evictions_total{component="Qwen3TtsCapabilityRouter",phase="cold_evict"}',
    'speechrail_worker_evictions_total{component="Qwen3TtsCapabilityRouter",phase="standby"}',
    # Reservation accounting: the counter proves every cycle really released its
    # reservation, which an idle active-request gauge alone cannot show.
    'speechrail_governor_releases_total{class="realtime_tts",outcome="completed",purpose="interactive"}',
    # Memory trend uses the service's own authoritative footprint definition, so
    # the soak cannot mistake MLX allocator caching for a leak, or the reverse.
    "speechrail_resource_physical_footprint_bytes",
    "speechrail_resource_footprint_process_count",
    "speechrail_resource_footprint_complete",
)


@dataclass(frozen=True, slots=True)
class CancelTurnTrace:
    """One interrupted utterance: cancel in, terminal out, slot released."""

    request_id: str
    cancel_sent_at: float
    first_audio_at: float | None
    last_audio_at: float | None
    terminal_at: float | None
    terminal_status: str | None
    audio_bytes_before_cancel: int
    audio_bytes_after_cancel: int
    next_start_accepted_at: float | None = None
    sample_rate: int = DEFAULT_SAMPLE_RATE
    failure: str | None = None

    @property
    def cancel_to_last_audio_seconds(self) -> float | None:
        """Wall clock the server kept streaming after the cancel arrived."""

        if self.last_audio_at is None:
            return None
        return max(0.0, self.last_audio_at - self.cancel_sent_at)

    @property
    def cancel_to_terminal_seconds(self) -> float | None:
        if self.terminal_at is None:
            return None
        return max(0.0, self.terminal_at - self.cancel_sent_at)

    @property
    def next_start_accepted_seconds(self) -> float | None:
        if self.next_start_accepted_at is None:
            return None
        return max(0.0, self.next_start_accepted_at - self.cancel_sent_at)

    @property
    def audio_seconds_after_cancel(self) -> float:
        return self.audio_bytes_after_cancel / (self.sample_rate * _BYTES_PER_SAMPLE)


@dataclass(frozen=True, slots=True)
class CancelSummary:
    samples: int
    cancelled_turns: int
    stale_audio_turns: int
    cancel_to_last_audio_ms_p50: float | None
    cancel_to_last_audio_ms_p95: float | None
    cancel_to_terminal_ms_p50: float | None
    cancel_to_terminal_ms_p95: float | None
    next_start_accepted_ms_p50: float | None
    next_start_accepted_ms_p95: float | None
    failures: tuple[str, ...] = ()
    terminal_turns: int = 0
    release_proven_turns: int = 0

    def as_dict(self) -> dict[str, object]:
        return {
            "schema": "speechrail-perf/tts-stream-cancel/1",
            "samples": self.samples,
            "terminal_turns": self.terminal_turns,
            "release_proven_turns": self.release_proven_turns,
            "cancelled_turns": self.cancelled_turns,
            "stale_audio_turns": self.stale_audio_turns,
            "cancel_to_last_audio_ms": {
                "p50": self.cancel_to_last_audio_ms_p50,
                "p95": self.cancel_to_last_audio_ms_p95,
            },
            "cancel_to_terminal_ms": {
                "p50": self.cancel_to_terminal_ms_p50,
                "p95": self.cancel_to_terminal_ms_p95,
            },
            "next_start_accepted_ms": {
                "p50": self.next_start_accepted_ms_p50,
                "p95": self.next_start_accepted_ms_p95,
            },
            "failures": list(self.failures),
        }


def summarise_cancel(traces: list[CancelTurnTrace]) -> CancelSummary:
    """Aggregate interrupt traces; a turn without a terminal is never averaged in."""

    def collect(values: list[float | None]) -> list[float]:
        return [value * 1000 for value in values if value is not None]

    last_audio = collect([trace.cancel_to_last_audio_seconds for trace in traces])
    terminal = collect([trace.cancel_to_terminal_seconds for trace in traces])
    next_start = collect([trace.next_start_accepted_seconds for trace in traces])
    return CancelSummary(
        samples=len(terminal),
        cancelled_turns=sum(1 for trace in traces if trace.terminal_status == "cancelled"),
        stale_audio_turns=sum(1 for trace in traces if trace.audio_bytes_after_cancel > 0),
        cancel_to_last_audio_ms_p50=percentile(last_audio, 0.50),
        cancel_to_last_audio_ms_p95=percentile(last_audio, 0.95),
        cancel_to_terminal_ms_p50=percentile(terminal, 0.50),
        cancel_to_terminal_ms_p95=percentile(terminal, 0.95),
        next_start_accepted_ms_p50=percentile(next_start, 0.50),
        next_start_accepted_ms_p95=percentile(next_start, 0.95),
        failures=tuple(trace.failure for trace in traces if trace.failure is not None),
        terminal_turns=sum(1 for trace in traces if trace.terminal_status is not None),
        release_proven_turns=sum(
            1 for trace in traces if trace.next_start_accepted_at is not None
        ),
    )


def _session_ready(
    connection: Any, deadline: float, clock: Callable[[], float], model: str
) -> None:
    connection.send(session_update_event(model))
    _recv_until(connection, deadline, clock, frozenset({"session.updated"}))


def run_cancel_turn(
    connection: Any,
    *,
    text: str,
    model: str = _DEFAULT_ASR_MODEL,
    voice: str | None = None,
    cancel_trigger: str = "first_audio",
    timeout_seconds: float = 120.0,
    release_probe: bool = True,
    clock: Callable[[], float] = time.monotonic,
) -> CancelTurnTrace:
    """Interrupt one utterance and time the whole teardown.

    ``cancel_trigger`` decides when a user interrupt is emulated: ``first_audio``
    cancels once the first PCM has been heard (the normal case, and the only one
    that can prove "no stale audio"), ``first_ack`` cancels as soon as the text
    was accepted, which is what a fake backend that only renders on ``finish``
    can support.

    ``connection`` only has to expose ``send(dict)`` and ``recv()``, so the real
    SDK connection and a scripted fake both drive the identical code path.
    """
    if cancel_trigger not in ("first_audio", "first_ack"):
        raise ValueError("cancel_trigger must be first_audio or first_ack")

    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    deadline = clock() + timeout_seconds
    _session_ready(connection, deadline, clock, model)

    request_id = f"bench_cancel_{int(clock() * 1000)}"
    start: dict[str, Any] = {
        "type": "speechrail.tts.start",
        "request_id": request_id,
        "task": "conversation",
        "voice": voice or DEFAULT_VOICE,
    }
    connection.send(start)

    sample_rate = DEFAULT_SAMPLE_RATE
    started = False
    appended = False
    acknowledged = False
    first_audio_at: float | None = None
    last_audio_at: float | None = None
    audio_bytes = 0
    audio_bytes_after_cancel = 0
    cancel_sent_at: float | None = None
    terminal_at: float | None = None
    terminal_status: str | None = None
    next_start_accepted_at: float | None = None
    failure: str | None = None
    # One extra request id carries the release probe after the terminal.
    probe_request_id = f"{request_id}_probe"
    probe_sent = False

    while True:
        triggered = (
            first_audio_at is not None if cancel_trigger == "first_audio" else acknowledged
        )
        if started and not appended:
            connection.send(
                {
                    "type": "speechrail.tts.append_text",
                    "request_id": request_id,
                    "sequence": 0,
                    "text": text,
                }
            )
            appended = True
        if started and appended and cancel_sent_at is None and triggered:
            cancel_sent_at = clock()
            connection.send({"type": "speechrail.tts.cancel", "request_id": request_id})
        if terminal_at is not None and release_probe and not probe_sent:
            probe_sent = True
            probe_start: dict[str, Any] = {
                "type": "speechrail.tts.start",
                "request_id": probe_request_id,
                "task": "conversation",
                "voice": voice or DEFAULT_VOICE,
            }
            connection.send(probe_start)

        event = _recv(connection, deadline, clock)
        now = clock()
        kind = event.get("type")

        if kind == "speechrail.tts.started":
            if probe_sent and next_start_accepted_at is None:
                next_start_accepted_at = now
                # The probe only measures re-admission, so stop it immediately --
                # but its terminal still has to be read, or the next cycle on this
                # shared connection would mistake it for an answer of its own.
                cancel_sent_at = cancel_sent_at or now
                connection.send(
                    {"type": "speechrail.tts.cancel", "request_id": probe_request_id}
                )
            else:
                started = True
            sample_rate = _started_sample_rate(event) or sample_rate
        elif kind == "speechrail.tts.text_accepted":
            acknowledged = True
        elif kind == "speechrail.tts.audio.delta":
            chunk = _decode_audio(event.get("delta"))
            if chunk:
                if first_audio_at is None:
                    first_audio_at = now
                last_audio_at = now
                audio_bytes += len(chunk)
                if cancel_sent_at is not None:
                    audio_bytes_after_cancel += len(chunk)
        elif kind == "error":
            code = _error_code(event)
            if cancel_sent_at is None:
                raise RealtimeTurnError(code)
            failure = failure or code
        elif kind in (
            "speechrail.tts.completed",
            "speechrail.tts.cancelled",
            "speechrail.tts.failed",
        ):
            if probe_sent and event.get("request_id") == probe_request_id:
                # The release probe is retired, so this cycle owns no more frames.
                break
            if terminal_at is None:
                terminal_at = now
                terminal_status = kind.removeprefix("speechrail.tts.")
                if terminal_status == "failed":
                    failure = failure or _failure_code(event)
                elif terminal_status != "cancelled":
                    failure = failure or f"cancel_turn_{terminal_status}"
                if not release_probe:
                    break
            else:
                # A stray terminal from a prior cycle: the release probe owns the
                # next frame, so stop now rather than mis-attribute it.
                break

    return CancelTurnTrace(
        request_id=request_id,
        cancel_sent_at=cancel_sent_at or clock(),
        first_audio_at=first_audio_at,
        last_audio_at=last_audio_at,
        terminal_at=terminal_at,
        terminal_status=terminal_status,
        audio_bytes_before_cancel=audio_bytes - audio_bytes_after_cancel,
        audio_bytes_after_cancel=audio_bytes_after_cancel,
        next_start_accepted_at=next_start_accepted_at,
        sample_rate=sample_rate,
        failure=failure,
    )


def probe_idle_cancel(
    connection: Any, *, clock: Callable[[], float] = time.monotonic
) -> str | None:
    """Send a cancel with no active utterance and return the stable error code."""

    connection.send({"type": "speechrail.tts.cancel", "request_id": _IDLE_CANCEL_PROBE})
    deadline = clock() + 10.0
    while True:
        event = _recv(connection, deadline, clock)
        kind = event.get("type")
        if kind == "error":
            return _error_code(event)
        if kind in (
            "speechrail.tts.completed",
            "speechrail.tts.cancelled",
            "speechrail.tts.failed",
            "speechrail.tts.started",
        ):
            raise AssertionError(f"idle cancel answered with {kind}")


def fetch_gauges(*, metrics_url: str, api_key: str | None) -> dict[str, float]:
    """Read the lifecycle gauges a soak run watches (never the full dump)."""

    request = urllib.request.Request(metrics_url)
    if api_key:
        request.add_header("Authorization", f"Bearer {api_key}")
    with urllib.request.urlopen(request, timeout=5) as response:
        text = response.read().decode("utf-8", "replace")
    observed: dict[str, float] = {}
    for line in text.splitlines():
        if line.startswith("#") or " " not in line:
            continue
        name, _, value = line.rpartition(" ")
        if name in _GAUGES:
            with contextlib.suppress(ValueError):
                observed[name] = float(value)
    return observed


@dataclass(slots=True)
class SoakSummary:
    cycles: int
    completed_turns: int
    interrupted_turns: int
    idle_cancel_codes: list[str] = field(default_factory=list)
    failures: list[str] = field(default_factory=list)
    gauges: dict[str, dict[str, float]] = field(default_factory=dict)

    def as_dict(self) -> dict[str, object]:
        return {
            "schema": "speechrail-perf/tts-stream-soak/1",
            "cycles": self.cycles,
            "completed_turns": self.completed_turns,
            "interrupted_turns": self.interrupted_turns,
            "idle_cancel_codes": self.idle_cancel_codes,
            "failures": self.failures,
            "gauges": self.gauges,
        }


def run_soak(
    connection: Any,
    *,
    cycles: int,
    text: str,
    model: str = _DEFAULT_ASR_MODEL,
    voice: str | None = None,
    sample: Callable[[], dict[str, float]] | None = None,
    timeout_seconds: float = 120.0,
    clock: Callable[[], float] = time.monotonic,
    connection_factory: Callable[[], Any] | None = None,
    reconnect_every: int = 0,
) -> SoakSummary:
    """Repeat complete / interrupt / idle-cancel cycles.

    The server keeps a bounded, per-connection ledger of distinct TTS request
    ids (``_MAX_TTS_REQUEST_IDS``); once it is full an idle ``tts.start`` is
    rejected with ``tts_request_invalid`` until the client opens a new
    WebSocket.  A real long-lived client must therefore reconnect, so a soak
    that wants to run for hours passes ``connection_factory`` plus
    ``reconnect_every`` and this loop reopens the socket on that cadence.  When
    ``connection_factory`` is ``None`` the single ``connection`` is reused for
    every cycle, which is only valid for short runs.
    """

    if reconnect_every < 0:
        raise ValueError("reconnect_every must not be negative")
    summary = SoakSummary(cycles=cycles, completed_turns=0, interrupted_turns=0)
    if sample is not None:
        summary.gauges["before"] = sample()
    active = connection
    for index in range(cycles):
        if (
            index
            and connection_factory is not None
            and reconnect_every > 0
            and index % reconnect_every == 0
        ):
            with contextlib.suppress(Exception):
                active.close()
            active = connection_factory()
        try:
            trace = run_incremental_turn(
                active,
                text=text,
                model=model,
                voice=voice,
                slices=1,
                timeout_seconds=timeout_seconds,
                clock=clock,
            )
        except Exception as exc:  # one bad cycle must not end the soak
            summary.failures.append(f"cycle{index}_complete:{type(exc).__name__}")
        else:
            if trace.failure is None:
                summary.completed_turns += 1
            else:
                summary.failures.append(f"cycle{index}_complete:{trace.failure}")
        try:
            cancelled = run_cancel_turn(
                active,
                text=text,
                model=model,
                voice=voice,
                timeout_seconds=timeout_seconds,
                clock=clock,
            )
        except Exception as exc:
            summary.failures.append(f"cycle{index}_cancel:{type(exc).__name__}")
        else:
            if cancelled.terminal_status == "cancelled":
                summary.interrupted_turns += 1
            else:
                summary.failures.append(
                    f"cycle{index}_cancel:{cancelled.terminal_status or 'no_terminal'}"
                )
            if cancelled.audio_bytes_after_cancel:
                summary.failures.append(f"cycle{index}_stale_audio")
        try:
            code = probe_idle_cancel(active, clock=clock)
        except Exception as exc:
            summary.failures.append(f"cycle{index}_idle:{type(exc).__name__}")
        else:
            summary.idle_cancel_codes.append(code or "no_code")
            if code != "tts_not_active":
                summary.failures.append(f"cycle{index}_idle:{code}")
        if sample is not None:
            summary.gauges[f"cycle{index}"] = sample()
    if sample is not None:
        summary.gauges["after"] = sample()
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description="Incremental TTS cancel/soak benchmark")
    parser.add_argument("--base-url", default="http://127.0.0.1:8201/v1")
    parser.add_argument("--metrics-url", default="http://127.0.0.1:8201/metrics")
    parser.add_argument("--model", default="whisper-1")
    parser.add_argument("--app-home", type=Path, help="managed app home for API-key discovery")
    parser.add_argument("--text", default="你好，这是一次被中断的增量朗读。")
    parser.add_argument("--voice", default=None, help="registered voice id")
    parser.add_argument("--mode", choices=("cancel", "soak"), default="cancel")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument(
        "--reconnect-every",
        type=int,
        default=50,
        help=(
            "soak: reopen the WebSocket every N cycles; the server's per-connection "
            "TTS request-id ledger is bounded, so long soaks must reconnect (0 = never)"
        ),
    )
    parser.add_argument("--timeout-seconds", type=float, default=120.0)
    parser.add_argument(
        "--output", type=Path, help="write the summary JSON to this path (keep it outside the repo)"
    )
    args = parser.parse_args()

    api_key = resolve_api_key(app_home=args.app_home) or "local"
    client = OpenAI(api_key=api_key, base_url=args.base_url)
    payload: dict[str, object]

    if args.mode == "cancel":
        traces: list[CancelTurnTrace] = []
        for index in range(args.repeat):
            connection = client.realtime.connect(model=args.model).enter()
            try:
                trace = run_cancel_turn(
                    connection,
                    text=args.text,
                    model=args.model,
                    voice=args.voice,
                    timeout_seconds=args.timeout_seconds,
                )
            except Exception as exc:
                trace = CancelTurnTrace(
                    request_id=f"failed_{index}",
                    cancel_sent_at=0.0,
                    first_audio_at=None,
                    last_audio_at=None,
                    terminal_at=None,
                    terminal_status=None,
                    audio_bytes_before_cancel=0,
                    audio_bytes_after_cancel=0,
                    failure=f"{type(exc).__name__}:{exc}"[:120],
                )
            finally:
                with contextlib.suppress(Exception):
                    connection.close()
            traces.append(trace)
            terminal = trace.cancel_to_terminal_seconds
            print(
                f"[cancel {index + 1}/{args.repeat}] "
                f"terminal={terminal * 1000:.0f}ms"
                if terminal is not None
                else f"[cancel {index + 1}/{args.repeat}] failure={trace.failure}"
            )
        payload = summarise_cancel(traces).as_dict()
    else:
        sample = lambda: fetch_gauges(  # noqa: E731 - small local closure
            metrics_url=args.metrics_url, api_key=api_key
        )
        active_connection: dict[str, Any] = {}

        def _connect() -> Any:
            connection = client.realtime.connect(model=args.model).enter()
            active_connection["current"] = connection
            return connection

        try:
            summary = run_soak(
                _connect(),
                cycles=args.repeat,
                text=args.text,
                model=args.model,
                voice=args.voice,
                sample=sample,
                timeout_seconds=args.timeout_seconds,
                connection_factory=_connect,
                reconnect_every=args.reconnect_every,
            )
        finally:
            with contextlib.suppress(Exception):
                active_connection["current"].close()
        payload = summary.as_dict()

    text = json.dumps(payload, ensure_ascii=False, indent=2)
    print(text)
    if args.output is not None:
        args.output.write_text(text + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
