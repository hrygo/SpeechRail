"""Zero-dependency Prometheus and OpenMetrics-compatible observability engine.

Tracks low-cardinality in-process counters, gauges, and histograms tailored for
SpeechRail's local ASR/TTS/Realtime streaming runtime with sub-millisecond overhead.
"""

from __future__ import annotations

import threading
from collections import Counter
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

HTTP_DURATION_BUCKETS: tuple[float, ...] = (
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0
)
ASR_DURATION_BUCKETS: tuple[float, ...] = (
    0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0
)
RTF_BUCKETS: tuple[float, ...] = (
    0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 0.8, 1.0, 1.5, 2.0
)
TTS_DURATION_BUCKETS: tuple[float, ...] = (
    0.1, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 10.0
)
TTFA_BUCKETS: tuple[float, ...] = (
    0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0
)

LabelKey = tuple[tuple[str, str], ...]


def _make_label_key(**labels: str | int | float) -> LabelKey:
    """Normalize label kwargs into an immutable sorted tuple of string pairs."""
    return tuple(sorted((str(k), str(v)) for k, v in labels.items()))


def _format_labels(key: LabelKey, **extra: str | int | float) -> str:
    """Format label tuple into Prometheus `{k="v",...}` syntax.

    Escapes backslash, double-quote and newline to keep the exposition text
    parser-compatible even for attacker-influenced label values.
    """
    merged = dict(key)
    for k, v in extra.items():
        merged[k] = str(v)
    if not merged:
        return ""
    pairs = [f'{k}="{_escape_label_value(v)}"' for k, v in sorted(merged.items())]
    return f"{{{','.join(pairs)}}}"


def _escape_label_value(value: str | int | float) -> str:
    text = str(value)
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


@dataclass(slots=True)
class _HistogramData:
    buckets: tuple[float, ...]
    counts: list[int]  # len = len(buckets) + 1 (last is +Inf)
    sum_val: float = 0.0
    count: int = 0

    def observe(self, value: float) -> None:
        self.count += 1
        self.sum_val += value
        for i, bound in enumerate(self.buckets):
            if value <= bound:
                self.counts[i] += 1
        self.counts[-1] += 1  # +Inf bucket always increments


class Metrics:
    """Thread-safe Prometheus / OpenMetrics metrics registry with zero external dependencies."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._counters: dict[str, dict[LabelKey, float]] = {}
        self._gauges: dict[str, dict[LabelKey, float]] = {}
        self._histograms: dict[str, dict[LabelKey, _HistogramData]] = {}
        self._descriptions: dict[str, str] = {}
        self._legacy_counters: Counter[tuple[str, str]] = Counter()

        # Pre-register core metric descriptions & types
        self._describe("speechrail_http_requests_total", "Total count of HTTP requests processed")
        self._describe(
            "speechrail_http_request_duration_seconds",
            "HTTP request duration in seconds",
        )
        self._describe(
            "speechrail_asr_processed_audio_seconds_total",
            "Total cumulative duration of transcribed audio in seconds",
        )
        self._describe(
            "speechrail_asr_inference_duration_seconds",
            "ASR inference processing duration in seconds",
        )
        self._describe(
            "speechrail_asr_rtf",
            "ASR Real-Time Factor (inference duration / audio duration)",
        )
        self._describe(
            "speechrail_tts_generated_audio_seconds_total",
            "Total cumulative duration of synthesized audio in seconds",
        )
        self._describe(
            "speechrail_tts_input_characters_total",
            "Total count of input text characters synthesized",
        )
        self._describe(
            "speechrail_tts_inference_duration_seconds",
            "TTS synthesis duration in seconds",
        )
        self._describe(
            "speechrail_tts_ttfa_seconds",
            "Streaming TTS Time-To-First-Audio latency in seconds",
        )
        self._describe(
            "speechrail_realtime_sessions_total",
            "Total WebSocket realtime sessions opened",
        )
        self._describe(
            "speechrail_realtime_active_sessions",
            "Current count of active WebSocket realtime sessions",
        )
        self._describe(
            "speechrail_realtime_bargein_events_total",
            "Total Barge-in interruption events triggered during playback",
        )
        self._describe(
            "speechrail_realtime_vad_speech_events_total",
            "Total VAD speech activity detection events",
        )
        self._describe(
            "speechrail_governor_active_requests",
            "Current active inference reservations by class",
        )
        self._describe(
            "speechrail_governor_pending_requests",
            "Current pending/queued inference requests by class",
        )
        self._describe(
            "speechrail_governor_queue_rejections_total",
            "Total requests rejected due to full capacity queue",
        )
        self._describe(
            "speechrail_worker_evictions_total",
            "Total worker lifecycle eviction events by phase",
        )
        self._describe(
            "speechrail_worker_status",
            "Inference worker lifecycle state (1=current state)",
        )
        self._describe(
            "speechrail_health_status",
            "Subsystem readiness status (1=ready, 0=not ready)",
        )

    def _describe(self, name: str, help_text: str) -> None:
        self._descriptions[name] = help_text

    # --- Backwards compatibility for existing tests ---
    def increment(self, name: str, outcome: str) -> None:
        """Legacy 2-element counter."""
        with self._lock:
            self._legacy_counters[(name, outcome)] += 1

    def snapshot(self) -> dict[str, int]:
        """Legacy snapshot representation."""
        with self._lock:
            return {
                f"{name}:{outcome}": val
                for (name, outcome), val in self._legacy_counters.items()
            }

    # --- Standard Metric Primitives ---
    def inc(self, name: str, amount: float = 1.0, **labels: str | int | float) -> None:
        """Increment a monotonic counter with labels."""
        key = _make_label_key(**labels)
        with self._lock:
            series = self._counters.setdefault(name, {})
            series[key] = series.get(key, 0.0) + amount

    def set_gauge(self, name: str, value: float, **labels: str | int | float) -> None:
        """Set an instantaneous gauge value."""
        key = _make_label_key(**labels)
        with self._lock:
            series = self._gauges.setdefault(name, {})
            series[key] = float(value)

    def inc_gauge(self, name: str, amount: float = 1.0, **labels: str | int | float) -> None:
        """Increment a gauge value."""
        key = _make_label_key(**labels)
        with self._lock:
            series = self._gauges.setdefault(name, {})
            series[key] = series.get(key, 0.0) + amount

    def dec_gauge(self, name: str, amount: float = 1.0, **labels: str | int | float) -> None:
        """Decrement a gauge value."""
        key = _make_label_key(**labels)
        with self._lock:
            series = self._gauges.setdefault(name, {})
            series[key] = max(0.0, series.get(key, 0.0) - amount)

    def observe(
        self,
        name: str,
        value: float,
        buckets: tuple[float, ...],
        **labels: str | int | float,
    ) -> None:
        """Observe a sample value into a histogram series."""
        key = _make_label_key(**labels)
        with self._lock:
            series = self._histograms.setdefault(name, {})
            hist = series.get(key)
            if hist is None:
                hist = _HistogramData(buckets=buckets, counts=[0] * (len(buckets) + 1))
                series[key] = hist
            hist.observe(value)

    # --- Domain-Specific Convenience Recorders ---
    def record_http_request(
        self, endpoint: str, method: str, status: int, duration_sec: float
    ) -> None:
        self.inc("speechrail_http_requests_total", endpoint=endpoint, method=method, status=status)
        self.observe(
            "speechrail_http_request_duration_seconds",
            duration_sec,
            HTTP_DURATION_BUCKETS,
            endpoint=endpoint,
        )

    def record_asr(self, audio_duration_sec: float, inference_duration_sec: float) -> None:
        self.inc("speechrail_asr_processed_audio_seconds_total", amount=audio_duration_sec)
        self.observe(
            "speechrail_asr_inference_duration_seconds",
            inference_duration_sec,
            ASR_DURATION_BUCKETS,
        )
        if audio_duration_sec > 0:
            rtf = inference_duration_sec / audio_duration_sec
            self.observe("speechrail_asr_rtf", rtf, RTF_BUCKETS)

    def record_tts(
        self,
        voice: str,
        char_count: int,
        audio_duration_sec: float,
        inference_duration_sec: float,
    ) -> None:
        self.inc(
            "speechrail_tts_generated_audio_seconds_total",
            amount=audio_duration_sec,
            voice=voice,
        )
        self.inc("speechrail_tts_input_characters_total", amount=char_count, voice=voice)
        self.observe(
            "speechrail_tts_inference_duration_seconds",
            inference_duration_sec,
            TTS_DURATION_BUCKETS,
            voice=voice,
        )

    def record_ttfa(self, ttfa_sec: float) -> None:
        self.observe("speechrail_tts_ttfa_seconds", ttfa_sec, TTFA_BUCKETS)

    def record_realtime_session_start(self) -> None:
        self.inc("speechrail_realtime_sessions_total")
        self.inc_gauge("speechrail_realtime_active_sessions")

    def record_realtime_session_end(self) -> None:
        self.dec_gauge("speechrail_realtime_active_sessions")

    def record_bargein(self) -> None:
        self.inc("speechrail_realtime_bargein_events_total")

    def record_vad(self, event: str) -> None:
        self.inc("speechrail_realtime_vad_speech_events_total", event=event)

    def record_eviction(self, component: str, phase: str) -> None:
        self.inc("speechrail_worker_evictions_total", component=component, phase=phase)

    def record_governor_rejection(self, work_class: str) -> None:
        self._increment_labeled(
            "speechrail_governor_queue_rejections_total",
            1.0,
            {"class": str(work_class), "reason": "queue_full"},
        )

    def _increment_labeled(
        self,
        name: str,
        amount: float,
        labels: Mapping[str, str | int | float],
    ) -> None:
        """Increment a counter series whose labels cannot be spelled as kwargs."""
        key = _make_label_key(**dict(labels))
        with self._lock:
            series = self._counters.setdefault(name, {})
            series[key] = series.get(key, 0.0) + amount

    # --- Dynamic gauge sync (shared by both exporters) ---
    def _sync_dynamic_gauges(
        self,
        *,
        governor_snapshot: Any | None,
        worker_states: Mapping[str, str] | None,
        readiness: Mapping[str, bool] | None,
    ) -> None:
        """Write live runtime state into gauge series under the registry lock.

        The caller must already hold ``self._lock``.
        """
        if governor_snapshot is not None:
            active = self._gauges.setdefault("speechrail_governor_active_requests", {})
            active[_make_label_key(**{"class": "realtime"})] = float(
                getattr(governor_snapshot, "active_realtime", 0)
            )
            active[_make_label_key(**{"class": "batch"})] = float(
                getattr(governor_snapshot, "active_batch", 0)
            )
            pending = self._gauges.setdefault("speechrail_governor_pending_requests", {})
            pending[_make_label_key(**{"class": "realtime"})] = float(
                getattr(governor_snapshot, "pending_realtime", 0)
            )
            pending[_make_label_key(**{"class": "batch"})] = float(
                getattr(governor_snapshot, "pending_batch", 0)
            )

        if readiness is not None:
            health = self._gauges.setdefault("speechrail_health_status", {})
            for comp, is_ready in readiness.items():
                health[_make_label_key(component=comp)] = 1.0 if is_ready else 0.0

        if worker_states is not None:
            worker_gauge = self._gauges.setdefault("speechrail_worker_status", {})
            for comp, state in sorted(worker_states.items()):
                for s in ("active", "warm_standby", "cold_evicted", "inactive"):
                    val = 1.0 if state == s else 0.0
                    worker_gauge[_make_label_key(component=comp, state=s)] = val

    # --- Exporters: Prometheus Exposition Format & JSON ---
    def render_prometheus(
        self,
        *,
        governor_snapshot: Any | None = None,
        worker_states: Mapping[str, str] | None = None,
        readiness: Mapping[str, bool] | None = None,
    ) -> str:
        """Render standard OpenMetrics / Prometheus 0.0.4 text format."""
        with self._lock:
            # Sync live dynamic state into gauges
            self._sync_dynamic_gauges(
                governor_snapshot=governor_snapshot,
                worker_states=worker_states,
                readiness=readiness,
            )

            lines: list[str] = []

            # 1. Output Counters
            for name, counter_series in sorted(self._counters.items()):
                help_text = self._descriptions.get(name, "SpeechRail metric")
                lines.append(f"# HELP {name} {help_text}")
                lines.append(f"# TYPE {name} counter")
                for key, val in sorted(counter_series.items()):
                    fmt_val = f"{val:g}" if isinstance(val, float) else str(val)
                    lines.append(f"{name}{_format_labels(key)} {fmt_val}")

            # 2. Output Gauges
            for name, gauge_series in sorted(self._gauges.items()):
                help_text = self._descriptions.get(name, "SpeechRail metric")
                lines.append(f"# HELP {name} {help_text}")
                lines.append(f"# TYPE {name} gauge")
                for key, val in sorted(gauge_series.items()):
                    fmt_val = f"{val:g}" if isinstance(val, float) else str(val)
                    lines.append(f"{name}{_format_labels(key)} {fmt_val}")

            # 3. Output Histograms
            for name, hist_series in sorted(self._histograms.items()):
                help_text = self._descriptions.get(name, "SpeechRail metric")
                lines.append(f"# HELP {name} {help_text}")
                lines.append(f"# TYPE {name} histogram")
                for key, hist in sorted(hist_series.items()):
                    for bound, count in zip(hist.buckets, hist.counts[:-1], strict=False):
                        bound_str = f"{bound:g}"
                        label_str = _format_labels(key, le=bound_str)
                        lines.append(f"{name}_bucket{label_str} {count}")
                    # +Inf bucket
                    inf_label = _format_labels(key, le="+Inf")
                    lines.append(f"{name}_bucket{inf_label} {hist.counts[-1]}")
                    lines.append(f"{name}_sum{_format_labels(key)} {hist.sum_val:.6g}")
                    lines.append(f"{name}_count{_format_labels(key)} {hist.count}")

        return "\n".join(lines) + "\n"

    def render_json(
        self,
        *,
        governor_snapshot: Any | None = None,
        worker_states: Mapping[str, str] | None = None,
        readiness: Mapping[str, bool] | None = None,
    ) -> dict[str, Any]:
        """Render a structured JSON view for APIs and debugging."""
        with self._lock:
            # Propagate live runtime state into gauge series first so the JSON
            # ``gauges`` segment is complete without a prior Prometheus scrape.
            self._sync_dynamic_gauges(
                governor_snapshot=governor_snapshot,
                worker_states=worker_states,
                readiness=readiness,
            )
            counters = {
                f"{name}{_format_labels(k)}": v
                for name, s in self._counters.items()
                for k, v in s.items()
            }
            gauges = {
                f"{name}{_format_labels(k)}": v
                for name, s in self._gauges.items()
                for k, v in s.items()
            }
            histograms = {
                name: {
                    _format_labels(k): {
                        "count": hist.count,
                        "sum": hist.sum_val,
                        "avg": hist.sum_val / hist.count if hist.count > 0 else 0.0,
                    }
                    for k, hist in s.items()
                }
                for name, s in self._histograms.items()
            }

        return {
            "active_requests": {
                "realtime": (
                    getattr(governor_snapshot, "active_realtime", 0)
                    if governor_snapshot
                    else 0
                ),
                "batch": (
                    getattr(governor_snapshot, "active_batch", 0)
                    if governor_snapshot
                    else 0
                ),
            },
            "pending_requests": {
                "realtime": (
                    getattr(governor_snapshot, "pending_realtime", 0)
                    if governor_snapshot
                    else 0
                ),
                "batch": (
                    getattr(governor_snapshot, "pending_batch", 0)
                    if governor_snapshot
                    else 0
                ),
            },
            "workers": dict(worker_states or {}),
            "health": dict(readiness or {}),
            "counters": counters,
            "gauges": gauges,
            "histograms": histograms,
        }
