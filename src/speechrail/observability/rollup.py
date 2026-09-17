"""Durable interval rollups of the in-process metrics registry.

``GET /metrics`` is a live, process-lifetime cumulative view: every counter
resets when the service restarts, and a control surface that samples it in
memory can only ever show the span since it was opened. This module appends one
bounded JSON line per interval to ``<directory>/YYYY-MM-DD.jsonl`` so the same
facts stay readable over days without a second resident process, a metrics
backend or per-request file I/O.

Guarantees:

* fail-open — a rollup failure never affects request handling or the service;
* bounded — one line per interval, low-cardinality fields only, never request
  content, credentials, audio, transcripts or model paths;
* self-describing — every line carries ``schema_version`` and ``kind``;
* retrievable — retention is enforced by filename date, so the directory stays
  bounded without scanning the file contents.

Each line describes one interval: monotonic counter deltas, per-interval
latency percentiles reconstructed from the histogram buckets, and the runtime
gauge facts sampled while the interval was open.

A failed append is retried by extending the next interval, so the history never
shows a silent gap: the line's ``interval_seconds`` states the real span.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import re
from collections import Counter
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

from speechrail.observability.metrics import (
    HistogramReading,
    LabelKey,
    Metrics,
    MetricsState,
)

_KIND = "metrics_rollup"
_SCHEMA_VERSION = 1
DIRECTORY_NAME = "metrics-rollup"
_FILE_PATTERN = re.compile(r"^(\d{4}-\d{2}-\d{2})\.jsonl$")

# The user-facing "usage" split mirrors the control surface: previews synthesize
# audio through the same path as /v1/audio/speech, so counting only the latter
# would make the request count disagree with the synthesized-seconds total.
_TTS_ENDPOINTS = frozenset({"/v1/audio/speech", "/v1/voices/previews"})
_ASR_ENDPOINTS = frozenset({"/v1/audio/transcriptions"})

_HTTP_REQUESTS = "speechrail_http_requests_total"
_HTTP_LATENCY = "speechrail_http_request_duration_seconds"
_TTS_LATENCY = "speechrail_tts_inference_duration_seconds"
_ASR_LATENCY = "speechrail_asr_inference_duration_seconds"
_TTS_AUDIO_SECONDS = "speechrail_tts_generated_audio_seconds_total"
_ASR_AUDIO_SECONDS = "speechrail_asr_processed_audio_seconds_total"
_REALTIME_SESSIONS = "speechrail_realtime_sessions_total"
_REALTIME_ACTIVE_SESSIONS = "speechrail_realtime_active_sessions"
_REALTIME_TURNS = "speechrail_realtime_turn_commits_total"
_REALTIME_BARGEIN = "speechrail_realtime_bargein_events_total"
_QUEUE_REJECTIONS = "speechrail_governor_queue_rejections_total"
_WORKER_EVICTIONS = "speechrail_worker_evictions_total"

DEFAULT_INTERVAL_SECONDS = 60.0
DEFAULT_RETENTION_DAYS = 30
_MAX_SAMPLE_SECONDS = 5.0

_LOGGER = logging.getLogger(__name__)

Record = dict[str, object]


@dataclass(frozen=True, slots=True)
class RollupContext:
    """Cheap runtime facts sampled between interval writes."""

    workers: Mapping[str, str] = field(default_factory=dict)
    ready: Mapping[str, bool] = field(default_factory=dict)
    active_requests: int = 0
    pending_requests: int = 0
    total_capacity: int = 0
    allow_heavy_overlap: bool | None = None


@dataclass(frozen=True, slots=True)
class RollupResources:
    """Observed resource facts sampled once per interval."""

    physical_footprint_bytes: int | None = None
    footprint_complete: bool = False
    footprint_process_count: int = 0
    declared_footprint_bytes: int | None = None


def default_rollup_path(app_home: Path) -> Path:
    """Return the rollup directory for an installed app home."""
    return Path(app_home) / "state" / DIRECTORY_NAME


class MetricsRollup:
    """Append one bounded JSON line per interval to a date-partitioned file.

    The writer is inert until :meth:`start` and is safe to stop and restart.
    Every filesystem operation is offloaded to a worker thread and every failure
    is logged and swallowed: a monitoring side channel must never be able to
    break request handling.
    """

    def __init__(
        self,
        *,
        directory: Path,
        metrics: Metrics,
        context: Callable[[], RollupContext],
        resources: Callable[[], RollupResources] | None = None,
        service_version: str = "",
        profile: str | None = None,
        interval_seconds: float = DEFAULT_INTERVAL_SECONDS,
        retention_days: int = DEFAULT_RETENTION_DAYS,
        sample_seconds: float | None = None,
    ) -> None:
        if interval_seconds <= 0:
            raise ValueError("interval_seconds must be positive")
        if retention_days < 1:
            raise ValueError("retention_days must be positive")
        self.directory = Path(directory)
        self.interval_seconds = float(interval_seconds)
        self.retention_days = int(retention_days)
        self.sample_seconds = float(
            min(_MAX_SAMPLE_SECONDS, self.interval_seconds)
            if sample_seconds is None
            else sample_seconds
        )
        if self.sample_seconds <= 0:
            raise ValueError("sample_seconds must be positive")
        self._metrics = metrics
        self._context = context
        self._resources = resources
        self._service_version = service_version
        self._profile = profile
        self._task: asyncio.Task[None] | None = None
        self._previous: MetricsState | None = None
        self._interval_started_at: datetime | None = None
        self._started_at: datetime | None = None
        self._last_purge_day: date | None = None
        self._last_context = RollupContext()
        self._active_peak = 0
        self._pending_peak = 0
        self._written = 0
        self._failures = 0

    @property
    def path(self) -> Path:
        """Return the file the next line is appended to."""
        return self.directory / f"{datetime.now(UTC).date().isoformat()}.jsonl"

    @property
    def written(self) -> int:
        """Return how many interval lines this writer successfully appended."""
        return self._written

    @property
    def failures(self) -> int:
        """Return how many interval writes were dropped after an error."""
        return self._failures

    async def start(self) -> None:
        """Write the first baseline and run the interval loop until stopped."""
        if self._task is not None:
            return
        now = datetime.now(UTC)
        self._started_at = now
        self._interval_started_at = now
        self._previous = self._metrics.read_state()
        self._last_context = self._safe_context()
        self._active_peak = self._last_context.active_requests
        self._pending_peak = self._last_context.pending_requests
        try:
            await asyncio.to_thread(self._prepare_directory)
        except OSError:
            _LOGGER.warning(
                "speechrail metrics rollup directory is unavailable: %s", self.directory
            )
        self._task = asyncio.create_task(self._run())

    async def stop(self) -> None:
        """Stop the interval loop without dropping the current partial interval."""
        task, self._task = self._task, None
        if task is None:
            return
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task

    async def _run(self) -> None:
        loop = asyncio.get_running_loop()
        next_write = loop.time() + self.interval_seconds
        while True:
            await asyncio.sleep(min(self.sample_seconds, self.interval_seconds))
            self._sample()
            if loop.time() >= next_write:
                await self.flush()
                next_write = loop.time() + self.interval_seconds

    async def flush(self) -> Record | None:
        """Append one line for the interval that just closed, or ``None``."""
        try:
            record = await asyncio.to_thread(self.write_interval)
        except Exception as exc:
            self._failures += 1
            _LOGGER.warning(
                "speechrail metrics rollup could not append an interval line (%s); "
                "the service keeps running and the next line covers this interval",
                exc.__class__.__name__,
            )
            return None
        self._written += 1
        return record

    def write_interval(self) -> Record:
        """Diff the registry since the last write and append one bounded line.

        Synchronous on purpose: :meth:`flush` runs it in a worker thread, and a
        test can call it directly without an event loop. The interval baseline
        only advances after the line is on disk, so a failed append extends the
        next interval instead of leaving a silent gap in the history.
        """
        now = datetime.now(UTC)
        current = self._metrics.read_state()
        previous = self._previous
        started_at = self._interval_started_at or now
        self._sample()
        self._prepare_directory()
        record = self._build_record(
            current,
            previous,
            now=now,
            started_at=started_at,
        )
        path = self.directory / f"{now.date().isoformat()}.jsonl"
        self._append(path, record)
        self._previous = current
        self._interval_started_at = now
        self._active_peak = self._last_context.active_requests
        self._pending_peak = self._last_context.pending_requests
        return record

    def purge(self, today: date | None = None) -> tuple[Path, ...]:
        """Delete rollup files older than the retention window."""
        return self._purge_old_files(today or datetime.now(UTC).date())

    def _sample(self) -> None:
        self._last_context = self._safe_context()
        self._active_peak = max(self._active_peak, self._last_context.active_requests)
        self._pending_peak = max(self._pending_peak, self._last_context.pending_requests)

    def _safe_context(self) -> RollupContext:
        try:
            return self._context()
        except Exception:
            _LOGGER.debug("speechrail metrics rollup context unavailable", exc_info=True)
            return RollupContext()

    def _safe_resources(self) -> RollupResources:
        if self._resources is None:
            return RollupResources()
        try:
            return self._resources()
        except Exception:
            _LOGGER.debug("speechrail metrics rollup resources unavailable", exc_info=True)
            return RollupResources()

    def _build_record(
        self,
        current: MetricsState,
        previous: MetricsState | None,
        *,
        now: datetime,
        started_at: datetime,
    ) -> Record:
        baseline = previous or current
        context = self._last_context
        resources = self._safe_resources()
        process_started_at = self._started_at or now
        counters = _counter_deltas(baseline, current)
        return {
            "schema_version": _SCHEMA_VERSION,
            "kind": _KIND,
            "service_version": self._service_version,
            "profile": self._profile,
            "pid": os.getpid(),
            "interval_start": _iso(started_at),
            "interval_end": _iso(now),
            "interval_seconds": round((now - started_at).total_seconds(), 3),
            "process_started_at": _iso(process_started_at),
            "uptime_seconds": round((now - process_started_at).total_seconds(), 3),
            "requests": _request_breakdown(counters),
            "audio_seconds": {
                "tts": round(current.counter_delta(baseline, _TTS_AUDIO_SECONDS), 3),
                "asr": round(current.counter_delta(baseline, _ASR_AUDIO_SECONDS), 3),
            },
            "latency_ms": _latency_breakdown(baseline, current),
            "realtime": {
                "sessions": _count(current.counter_delta(baseline, _REALTIME_SESSIONS)),
                "turns": _count(current.counter_delta(baseline, _REALTIME_TURNS)),
                "bargein_events": _count(current.counter_delta(baseline, _REALTIME_BARGEIN)),
                "active_sessions": _count(current.gauge_total(_REALTIME_ACTIVE_SESSIONS)),
            },
            "capacity": {
                "queue_rejections": _count(current.counter_delta(baseline, _QUEUE_REJECTIONS)),
                "active": context.active_requests,
                "pending": context.pending_requests,
                "active_peak": self._active_peak,
                "pending_peak": self._pending_peak,
                "total_capacity": context.total_capacity,
                "allow_heavy_overlap": context.allow_heavy_overlap,
            },
            "memory": {
                "physical_footprint_bytes": resources.physical_footprint_bytes,
                "footprint_complete": resources.footprint_complete,
                "footprint_process_count": resources.footprint_process_count,
                "declared_footprint_bytes": resources.declared_footprint_bytes,
            },
            "workers": {
                "states": dict(context.workers),
                "evictions": _count(current.counter_delta(baseline, _WORKER_EVICTIONS)),
            },
            "ready": dict(context.ready),
        }

    def _prepare_directory(self) -> None:
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.purge()

    def _purge_old_files(self, today: date) -> tuple[Path, ...]:
        if self._last_purge_day == today:
            return ()
        self._last_purge_day = today
        cutoff = today - timedelta(days=self.retention_days)
        removed: list[Path] = []
        try:
            entries = sorted(self.directory.iterdir())
        except OSError:
            return ()
        for entry in entries:
            match = _FILE_PATTERN.match(entry.name)
            if match is None or date.fromisoformat(match.group(1)) >= cutoff:
                continue
            try:
                entry.unlink()
            except OSError:
                _LOGGER.debug("speechrail metrics rollup could not remove %s", entry.name)
                continue
            removed.append(entry)
        return tuple(removed)

    @staticmethod
    def _append(path: Path, record: Record) -> None:
        line = json.dumps(record, sort_keys=True, ensure_ascii=False, default=str) + "\n"
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            handle = os.fdopen(descriptor, "a", encoding="utf-8")
        except BaseException:
            os.close(descriptor)
            raise
        with handle:
            handle.write(line)
            handle.flush()
            os.fsync(handle.fileno())


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _count(value: float) -> int:
    return round(value)


def _label_value(key: LabelKey, name: str) -> str | None:
    for label, value in key:
        if label == name:
            return value
    return None


def _counter_deltas(
    previous: MetricsState, current: MetricsState
) -> dict[str, dict[LabelKey, float]]:
    """Return per-series non-negative increments between two registry readings."""
    deltas: dict[str, dict[LabelKey, float]] = {}
    for name, series in current.counters.items():
        baseline = previous.counters.get(name, {})
        family: dict[LabelKey, float] = {}
        for key, value in series.items():
            delta = value - baseline.get(key, 0.0)
            if delta > 0:
                family[key] = delta
        if family:
            deltas[name] = family
    return deltas


def _request_breakdown(deltas: Mapping[str, Mapping[LabelKey, float]]) -> Record:
    by_endpoint: Counter[str] = Counter()
    by_status: Counter[str] = Counter()
    for key, amount in deltas.get(_HTTP_REQUESTS, {}).items():
        endpoint = _label_value(key, "endpoint") or "<unknown>"
        status = _label_value(key, "status") or "<unknown>"
        by_endpoint[endpoint] += _count(amount)
        by_status[status] += _count(amount)
    tts = sum(count for endpoint, count in by_endpoint.items() if endpoint in _TTS_ENDPOINTS)
    asr = sum(count for endpoint, count in by_endpoint.items() if endpoint in _ASR_ENDPOINTS)
    return {
        "http_total": sum(by_endpoint.values()),
        "speech_total": tts + asr,
        "tts": tts,
        "asr": asr,
        "failed": sum(count for status, count in by_status.items() if status.startswith("5")),
        "client_errors": sum(
            count for status, count in by_status.items() if status.startswith("4")
        ),
        "by_status": {status: by_status[status] for status in sorted(by_status)},
        "by_endpoint": {endpoint: by_endpoint[endpoint] for endpoint in sorted(by_endpoint)},
    }


def _latency_breakdown(previous: MetricsState, current: MetricsState) -> Record:
    endpoints: dict[str, Record] = {}
    for endpoint, reading in sorted(
        _grouped_delta(previous, current, _HTTP_LATENCY, label="endpoint").items()
    ):
        entry = _latency_entry(reading)
        if entry is not None:
            endpoints[endpoint] = entry
    return {
        "tts": _latency_entry(_grouped_delta(previous, current, _TTS_LATENCY).get("")),
        "asr": _latency_entry(_grouped_delta(previous, current, _ASR_LATENCY).get("")),
        "by_endpoint": endpoints,
    }


def _grouped_delta(
    previous: MetricsState,
    current: MetricsState,
    name: str,
    *,
    label: str | None = None,
) -> dict[str, HistogramReading]:
    """Merge one histogram family's per-series increments, optionally by label."""
    previous_family = previous.histograms.get(name, {})
    merged: dict[str, HistogramReading] = {}
    for key, reading in current.histograms.get(name, {}).items():
        delta = reading.delta(previous_family.get(key))
        if delta.total <= 0:
            continue
        group = (_label_value(key, label) or "<unknown>") if label else ""
        existing = merged.get(group)
        merged[group] = delta if existing is None else _merge_histograms(existing, delta)
    return merged


def _merge_histograms(left: HistogramReading, right: HistogramReading) -> HistogramReading:
    """Add two readings that share bucket bounds; keep ``left`` when they differ."""
    if left.bounds != right.bounds:
        return left
    return HistogramReading(
        bounds=left.bounds,
        counts=tuple(
            base + extra for base, extra in zip(left.counts, right.counts, strict=True)
        ),
        total=left.total + right.total,
        total_sum=left.total_sum + right.total_sum,
    )


def _latency_entry(reading: HistogramReading | None) -> Record | None:
    """Return count/average/percentiles in milliseconds for one merged reading."""
    if reading is None or reading.total <= 0:
        return None
    return {
        "count": reading.total,
        "avg": round(reading.total_sum / reading.total * 1000.0, 2),
        "p50": _percentile_ms(reading, 0.5),
        "p95": _percentile_ms(reading, 0.95),
    }


def _percentile_ms(reading: HistogramReading, quantile: float) -> float | None:
    """Interpolate a percentile from cumulative histogram buckets.

    Values above the last finite bound are reported as that bound: the ``+Inf``
    bucket has no upper edge, and a lower bound is more honest than an invented
    one. Returns ``None`` when the histogram carries no observations.
    """
    if reading.total <= 0:
        return None
    target = quantile * reading.total
    for index, bound in enumerate(reading.bounds):
        cumulative = reading.counts[index]
        if cumulative < target:
            continue
        lower_index = index - 1
        lower_bound = reading.bounds[lower_index] if lower_index >= 0 else 0.0
        lower_count = reading.counts[lower_index] if lower_index >= 0 else 0
        span = cumulative - lower_count
        if span <= 0:
            return round(bound * 1000.0, 2)
        fraction = (target - lower_count) / span
        return round((lower_bound + fraction * (bound - lower_bound)) * 1000.0, 2)
    if reading.bounds:
        return round(reading.bounds[-1] * 1000.0, 2)
    return None


__all__ = [
    "DEFAULT_INTERVAL_SECONDS",
    "DEFAULT_RETENTION_DAYS",
    "DIRECTORY_NAME",
    "MetricsRollup",
    "RollupContext",
    "RollupResources",
    "default_rollup_path",
]
