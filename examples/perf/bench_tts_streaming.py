"""Incremental (append-only) TTS latency benchmark for one utterance.

The full-text REST path already has ``bench_tts.py``.  This entry point measures
the *incremental* path instead: how long a real client waits from the moment it
sends the first stabilised text to the first playable PCM, and how long the
utterance then takes to reach its terminal.

Two numbers are deliberately kept apart, because one without the other is
misleading:

* ``append_to_first_pcm_ms`` is anchored at the first stable text *send* and
  covers everything the caller does before the first byte of audio can be
  played, including the deliberate small-window wait that
  ``--append-interval-ms`` emulates.
* ``generation_rtf`` divides ``terminal_time - first_stable_text_send_time`` by
  the audio the model produced.  The window therefore includes the wait the
  caller inserts between slices; that wait is reported separately as
  ``text_gap_ms`` instead of being subtracted, so a client-side stall can never
  be presented as a faster model.

``playback_headroom_ms`` compares the audio already received against the elapsed
time *before* adding the newly arrived packet, so a packet that lands after an
underrun cannot hide the deficit.  A turn only enters the success distribution
when its terminal is ``completed`` and its PCM is valid; a turn that produced
audio and then failed or timed out is a failure, and an expected ``cancelled``
terminal is counted on its own.

The ``/2`` report schema replaces ``/1`` because those anchors changed:
``append_to_first_pcm_ms``, ``generation_rtf``, ``playback_headroom_ms`` and the
success denominator are not comparable with a ``/1`` summary.  Earlier
incremental-TTS reports are left as written and are not re-certified under this
strategy.

The trace follows the public contract for one incremental utterance: ``start``,
wait for ``speechrail.tts.started``, append one slice and wait for the
``speechrail.tts.text_accepted`` whose sequence matches that append, repeat, then
``finish_text`` carrying the last acknowledged sequence.  A blocking ``recv``
runs on a daemon reader with a monotonic deadline, so one silent transport can
neither stall the sender loop nor outlive the turn.  It requires a running
service with the TTS backend ready and a voice whose incremental capability is
``supported``; running it against a fake backend or an unsupported voice proves
nothing.  Audio is counted and discarded, never retained or written to a file.

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
import queue
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from openai import OpenAI

from speechrail.config.auth import resolve_api_key
from speechrail.domain.tts import DEFAULT_VOICE_ID as DEFAULT_VOICE

DEFAULT_SAMPLE_RATE = 24_000
_BYTES_PER_SAMPLE = 2
_DEFAULT_ASR_MODEL = "whisper-1"


def session_update_event(model: str = _DEFAULT_ASR_MODEL) -> dict[str, Any]:
    """Build the one current-only ``session.update`` that enables incremental TTS.

    The single wire carries the ASR model under ``session.audio.input`` and the
    SpeechRail extension under ``session.speechrail``; there is no flat
    ``input_audio_format`` and no ``transcription_session.update``.
    """

    return {
        "type": "session.update",
        "session": {
            "type": "transcription",
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": DEFAULT_SAMPLE_RATE},
                    "transcription": {"model": model},
                    "turn_detection": None,
                }
            },
            "speechrail": {"task": "conversation", "tts": {"enabled": True}},
        },
    }


class RealtimeTurnError(RuntimeError):
    """A stable server error that ended the utterance before ``speechrail.tts.started``."""

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
    audio_arrivals: tuple[tuple[float, int], ...] = ()
    started_at: float | None = None
    first_stable_text_at: float | None = None
    finish_sent_at: float | None = None
    terminal_status: str | None = None

    @property
    def append_to_first_pcm_seconds(self) -> float | None:
        """Compatibility alias for the first-stable-text to first-PCM measure."""

        return self.first_pcm_seconds

    @property
    def first_pcm_seconds(self) -> float | None:
        if self.first_audio_at is None:
            return None
        anchor = self.first_stable_text_at
        if anchor is None:
            anchor = self.submitted_at
        return self.first_audio_at - anchor

    @property
    def start_to_started_seconds(self) -> float | None:
        if self.started_at is None:
            return None
        return self.started_at - self.submitted_at

    @property
    def audio_seconds(self) -> float:
        return self.audio_bytes / (self.sample_rate * _BYTES_PER_SAMPLE)

    @property
    def generation_seconds(self) -> float | None:
        """Wall clock from the first stable text send through the terminal.

        This deliberately includes caller-inserted gaps and first-segment
        overhead.  Sender gaps are reported separately instead of being
        subtracted, so RTF cannot hide client-side starvation.
        """

        anchor = self.first_stable_text_at
        if anchor is None:
            return None
        return max(0.0, self.terminal_at - anchor)

    @property
    def generation_rtf(self) -> float | None:
        generating = self.generation_seconds
        if generating is None or self.audio_seconds <= 0:
            return None
        return generating / self.audio_seconds

    @property
    def playback_headroom_seconds(self) -> float | None:
        """Smallest audio buffer the caller held while playing this turn.

        A caller that starts playing on the first audio byte has, before each
        later arrival, the previously received audio minus elapsed time.  The
        current packet is intentionally not added before checking: that would
        let a packet arriving after an underrun hide the deficit.  This is a
        supply-cadence proxy, not an audio-device measurement.
        """

        if len(self.audio_arrivals) < 2 or self.first_audio_at is None:
            return None
        first_at, _ = self.audio_arrivals[0]
        bytes_per_second = self.sample_rate * _BYTES_PER_SAMPLE
        worst: float | None = None
        for previous, current in zip(
            self.audio_arrivals, self.audio_arrivals[1:], strict=False
        ):
            at, _ = current
            headroom = previous[1] / bytes_per_second - (at - first_at)
            worst = headroom if worst is None else min(worst, headroom)
        return worst

    @property
    def first_pcm_before_finish(self) -> bool | None:
        """Whether playable PCM arrived before the text input was finished."""

        if self.first_audio_at is None or self.finish_sent_at is None:
            return None
        return self.first_audio_at < self.finish_sent_at


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
    playback_headroom_ms_p50: float | None = None
    playback_headroom_ms_p95: float | None = None
    underrun_turns: int = 0
    total_turns: int = 0
    cancelled_turns: int = 0
    start_to_started_ms_p50: float | None = None
    start_to_started_ms_p95: float | None = None
    first_pcm_before_finish_turns: int = 0

    def as_dict(self) -> dict[str, object]:
        return {
            "schema": "speechrail-perf/tts-streaming/2",
            "total_turns": self.total_turns,
            "samples": self.samples,
            "completed_turns": self.completed_turns,
            "failed_turns": self.failed_turns,
            "cancelled_turns": self.cancelled_turns,
            "failures": list(self.failures),
            "start_to_started_ms": {
                "p50": self.start_to_started_ms_p50,
                "p95": self.start_to_started_ms_p95,
            },
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
            "playback_headroom_ms": {
                "p50": self.playback_headroom_ms_p50,
                "p95": self.playback_headroom_ms_p95,
            },
            "underrun_turns": self.underrun_turns,
            "first_pcm_before_finish_turns": self.first_pcm_before_finish_turns,
        }


def summarise(traces: list[StreamingTurnTrace]) -> StreamingTurnSummary:
    """Aggregate protocol-complete turns; every other terminal is counted."""

    completed = [
        trace
        for trace in traces
        if trace.terminal_status == "completed" and trace.failure is None
    ]

    first_pcm = [
        seconds * 1000
        for trace in completed
        if (seconds := trace.first_pcm_seconds) is not None
    ]
    start_to_started = [
        seconds * 1000
        for trace in completed
        if (seconds := trace.start_to_started_seconds) is not None
    ]
    generation = [
        value for trace in completed if (value := trace.generation_rtf) is not None
    ]
    text_gap = [
        trace.text_gap_seconds * 1000
        for trace in completed
        if trace.first_audio_at is not None
    ]
    headroom = [
        seconds * 1000
        for trace in completed
        if (seconds := trace.playback_headroom_seconds) is not None
    ]
    cancelled = sum(1 for trace in traces if trace.terminal_status == "cancelled")
    return StreamingTurnSummary(
        samples=len(first_pcm),
        append_to_first_pcm_ms_p50=percentile(first_pcm, 0.50),
        append_to_first_pcm_ms_p95=percentile(first_pcm, 0.95),
        generation_rtf_p50=percentile(generation, 0.50),
        generation_rtf_p95=percentile(generation, 0.95),
        text_gap_ms_p50=percentile(text_gap, 0.50),
        text_gap_ms_p95=percentile(text_gap, 0.95),
        completed_turns=len(completed),
        failed_turns=len(traces) - len(completed) - cancelled,
        failures=tuple(trace.failure for trace in traces if trace.failure is not None),
        playback_headroom_ms_p50=percentile(headroom, 0.50),
        playback_headroom_ms_p95=percentile(headroom, 0.95),
        underrun_turns=sum(1 for value in headroom if value < 0),
        total_turns=len(traces),
        cancelled_turns=cancelled,
        start_to_started_ms_p50=percentile(start_to_started, 0.50),
        start_to_started_ms_p95=percentile(start_to_started, 0.95),
        first_pcm_before_finish_turns=sum(
            1 for trace in completed if trace.first_pcm_before_finish is True
        ),
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


def _append_limit(event: dict[str, Any]) -> int | None:
    limits = event.get("limits")
    if not isinstance(limits, dict):
        return None
    return _positive_int(limits.get("max_append_codepoints"))


def _failure_code(event: dict[str, Any]) -> str:
    error = event.get("error")
    if isinstance(error, dict) and isinstance(error.get("code"), str):
        return str(error["code"])
    return "tts_backend_failed"


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


@dataclass(frozen=True, slots=True)
class _ReceivedEvent:
    event: dict[str, Any]
    received_at: float


class _ReceiverFailure:
    def __init__(self, error: BaseException) -> None:
        self.error = error


class InterruptibleRealtimeReader:
    """Read one realtime event at a time without blocking the sender loop.

    A synchronous SDK connection has no portable ``recv(timeout=...)``.  The
    reader therefore owns the blocking call on a daemon thread, while callers
    request-at-most-one read and wait with a queue timeout.  Keeping one read
    outstanding while the sender sleeps lets audio arrive during caller-side
    pacing without leaving a reader parked on the shared connection after the
    turn has been consumed.
    """

    def __init__(self, connection: Any, clock: Callable[[], float]) -> None:
        self._connection = connection
        self._clock = clock
        self._requests: queue.Queue[None] = queue.Queue()
        self._results: queue.Queue[_ReceivedEvent | _ReceiverFailure] = queue.Queue()
        self._lock = threading.Lock()
        self._outstanding = 0
        self._closed = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name="bench-realtime-reader",
            daemon=True,
        )
        self._thread.start()

    def request(self) -> None:
        """Request one read if the reader is currently idle."""

        if self._closed.is_set():
            return
        with self._lock:
            if self._outstanding:
                return
            self._outstanding = 1
        self._requests.put(None)

    def receive(self, deadline: float) -> tuple[dict[str, Any], float]:
        """Return the requested event or raise when the monotonic deadline passes."""

        with self._lock:
            if self._outstanding != 1:
                raise RuntimeError("realtime reader has no outstanding request")
        remaining = deadline - self._clock()
        if remaining <= 0:
            with self._lock:
                self._outstanding = 0
            self.interrupt()
            raise TimeoutError("incremental TTS benchmark timed out")
        try:
            item = self._results.get(timeout=remaining)
        except queue.Empty:
            with self._lock:
                self._outstanding = 0
            self.interrupt()
            raise TimeoutError("incremental TTS benchmark timed out") from None
        with self._lock:
            self._outstanding = 0
        if isinstance(item, _ReceiverFailure):
            raise item.error
        return item.event, item.received_at

    def close(self) -> None:
        """Stop the idle helper without closing the caller-owned connection."""

        if self._closed.is_set():
            return
        self._closed.set()
        self._requests.put(None)
        self._thread.join(timeout=0.5)
        if self._thread.is_alive():
            # A receive was still outstanding; only this exceptional path
            # interrupts the connection so a timed-out reader cannot survive
            # into the next utterance.
            self.interrupt()

    def interrupt(self) -> None:
        """Best-effort wake a blocked transport, then retire the helper."""

        self._closed.set()
        for name in ("close", "abort", "cancel"):
            action = getattr(self._connection, name, None)
            if callable(action):
                with contextlib.suppress(Exception):
                    action()
        self._requests.put(None)
        self._thread.join(timeout=0.5)

    def _run(self) -> None:
        while not self._closed.is_set():
            try:
                self._requests.get(timeout=0.05)
            except queue.Empty:
                continue
            if self._closed.is_set():
                return
            try:
                event = _event_object(self._connection.recv())
                self._results.put(_ReceivedEvent(event, self._clock()))
            except BaseException as exc:
                self._results.put(_ReceiverFailure(exc))
                return


def _receive_event(
    reader: InterruptibleRealtimeReader, deadline: float
) -> tuple[dict[str, Any], float]:
    return reader.receive(deadline)


def _recv(connection: Any, deadline: float, clock: Callable[[], float]) -> dict[str, Any]:
    reader = InterruptibleRealtimeReader(connection, clock)
    try:
        reader.request()
        event, _ = _receive_event(reader, deadline)
        return event
    finally:
        reader.close()


def _recv_until_reader(
    reader: InterruptibleRealtimeReader,
    deadline: float,
    wanted: frozenset[str],
) -> dict[str, Any]:
    while True:
        reader.request()
        event, _ = _receive_event(reader, deadline)
        if event.get("type") in wanted:
            return event
        if event.get("type") == "error":
            raise RealtimeTurnError(_error_code(event))


def _recv_until(
    connection: Any,
    deadline: float,
    clock: Callable[[], float],
    wanted: frozenset[str],
) -> dict[str, Any]:
    reader = InterruptibleRealtimeReader(connection, clock)
    try:
        return _recv_until_reader(reader, deadline, wanted)
    finally:
        reader.close()


def _error_code(event: dict[str, Any]) -> str:
    error = event.get("error")
    if isinstance(error, dict) and isinstance(error.get("code"), str):
        return str(error["code"])
    return "realtime_error"


def run_incremental_turn(
    connection: Any,
    *,
    text: str,
    model: str = _DEFAULT_ASR_MODEL,
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
    reader = InterruptibleRealtimeReader(connection, clock)
    try:
        connection.send(session_update_event(model))
        _recv_until_reader(reader, deadline, frozenset({"session.updated"}))

        request_id = f"bench_stream_{int(clock() * 1000)}"
        start: dict[str, Any] = {
            "type": "speechrail.tts.start",
            "request_id": request_id,
            "task": "conversation",
            "voice": voice or DEFAULT_VOICE,
        }
        submitted_at = clock()
        connection.send(start)

        pieces: list[str] = []
        gaps: list[tuple[float, float]] = []
        first_audio_at: float | None = None
        first_stable_text_at: float | None = None
        started_at: float | None = None
        finish_sent_at: float | None = None
        task_id: str | None = None
        arrivals: list[tuple[float, int]] = []
        terminal_at = submitted_at
        terminal_status: str | None = None
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
            reader.request()
            if started and not finish_sent:
                if sent < len(pieces) and (sent == 0 or accepted_sequence >= sent - 1):
                    if sent and append_interval_seconds:
                        sleep(append_interval_seconds)
                    sent_at = clock()
                    if sent:
                        gaps.append((acknowledged_at, sent_at))
                    if first_stable_text_at is None:
                        first_stable_text_at = sent_at
                    connection.send(
                        {
                            "type": "speechrail.tts.append_text",
                            "request_id": request_id,
                            "sequence": sent,
                            "text": pieces[sent],
                        }
                    )
                    sent += 1
                elif sent == len(pieces) and accepted_sequence == len(pieces) - 1:
                    finish_sent_at = clock()
                    connection.send(
                        {
                            "type": "speechrail.tts.finish_text",
                            "request_id": request_id,
                            "last_sequence": accepted_sequence,
                        }
                    )
                    finish_sent = True

            event, now = _receive_event(reader, deadline)
            kind = event.get("type")

            if kind == "speechrail.tts.started":
                event_request_id = event.get("request_id")
                if event_request_id is not None and event_request_id != request_id:
                    raise ValueError("started event carried a foreign request_id")
                raw_task_id = event.get("task_id")
                if isinstance(raw_task_id, str):
                    task_id = raw_task_id
                started_at = now
                started = True
                created = True
                sample_rate = _started_sample_rate(event) or sample_rate
                pieces = _append_schedule(text, slices, max_codepoints=_append_limit(event))
            elif kind == "speechrail.tts.text_accepted":
                event_request_id = event.get("request_id")
                if event_request_id is not None and event_request_id != request_id:
                    raise ValueError("text_accepted event carried a foreign request_id")
                event_task_id = event.get("task_id")
                if (
                    task_id is not None
                    and event_task_id is not None
                    and event_task_id != task_id
                ):
                    raise ValueError("text_accepted event carried a foreign task_id")
                sequence = event.get("append_sequence")
                if isinstance(sequence, bool) or not isinstance(sequence, int):
                    raise ValueError("text_accepted event had no integer append_sequence")
                expected = sent - 1
                if sequence != expected:
                    raise ValueError(
                        f"text_accepted sequence {sequence} did not match {expected}"
                    )
                accepted_sequence = sequence
                acknowledged_at = now
            elif kind == "speechrail.tts.audio.delta":
                chunk = _decode_audio(event.get("delta"))
                if chunk:
                    if first_audio_at is None:
                        first_audio_at = now
                    audio_bytes += len(chunk)
                    arrivals.append((now, audio_bytes))
            elif kind == "error":
                code = _error_code(event)
                if not created:
                    raise RealtimeTurnError(code)
                failure = failure or code
            elif kind == "speechrail.tts.completed":
                terminal_at = now
                terminal_status = "completed"
                break
            elif kind == "speechrail.tts.cancelled":
                terminal_at = now
                terminal_status = "cancelled"
                break
            elif kind == "speechrail.tts.failed":
                terminal_at = now
                terminal_status = "failed"
                failure = failure or _failure_code(event)
                break

        if audio_bytes % _BYTES_PER_SAMPLE:
            raise ValueError("incremental TTS benchmark received truncated PCM16 audio")
        text_gap_seconds = sum(max(0.0, end - start) for start, end in gaps)
        return StreamingTurnTrace(
            submitted_at=submitted_at,
            first_audio_at=first_audio_at,
            terminal_at=terminal_at,
            audio_bytes=audio_bytes,
            sample_rate=sample_rate,
            text_gap_seconds=text_gap_seconds,
            failure=failure,
            audio_arrivals=tuple(arrivals),
            started_at=started_at,
            first_stable_text_at=first_stable_text_at,
            finish_sent_at=finish_sent_at,
            terminal_status=terminal_status,
        )
    finally:
        reader.close()


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
    headroom = trace.playback_headroom_seconds
    if headroom is not None:
        text += f" headroom={headroom * 1000:.0f}ms"
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
                model=args.model,
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
