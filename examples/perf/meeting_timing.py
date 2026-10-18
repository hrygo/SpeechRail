"""Bounded common-clock metadata; no raw text, P95 or latency certification."""

from __future__ import annotations

import hashlib
import math
import time
from collections import Counter
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from meeting_pcm_feed import PcmChunk

if TYPE_CHECKING:
    from meeting_candidate_evidence import CompletedText


def _integer(value: Any) -> int:
    if type(value) is not int:
        raise ValueError("timing sample or sequence must be an integer")
    return value


def _finite(value: Any) -> float:
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError("timing clock must be finite")
    return float(value)


@dataclass(frozen=True, slots=True)
class _Ticket:
    id: int
    kind: str
    entered: float
    record: int | None


@dataclass(slots=True)
class _Record:
    kind: str
    start: int
    end: int
    sequence: int
    known: bool | None
    text_sha256: str | None
    entered: float
    finished: float | None = None

    def row(self) -> list[Any]:
        return [self.kind, self.start, self.end, self.sequence, self.known,
                self.text_sha256, self.entered, self.finished]


class MeetingTiming:
    MAX_RECORDS = 98304
    MAX_ASR_RECORDS = 65536
    MAX_PUBLICATION_RECORDS = MAX_RECORDS - MAX_ASR_RECORDS - 1
    MAX_OPEN = 64
    KINDS = frozenset({"phase", "activity", "asr_text_ready", "stable_activity_frame",
                       "activity_watermark", "text", "asr_body_snapshot"})

    def __init__(self, *, samples: int, clock: Callable[[], float] = time.monotonic) -> None:
        if type(samples) is not int or not 0 < samples <= 600 * 16000:
            raise ValueError("invalid timing source")
        self.samples, self.clock = samples, clock
        self.source_samples = self.source_frames = self.asr_sealed = self.dia_stable = 0
        self._dia_observed = 0
        self.origin: float | None = None
        self._previous: float | None = None
        self._records: list[_Record] = []
        self._record_counts: Counter[str] = Counter()
        self._open: dict[int, _Ticket] = {}
        self._counter = 0
        self._entered: Counter[str] = Counter()
        self._delivered: Counter[str] = Counter()
        self._failed: Counter[str] = Counter()
        self._marks: dict[str, float] = {}
        self._max_queue = self._max_sink = 0.

    def tick(self) -> float:
        value = self.clock()
        if (type(value) not in (int, float) or not math.isfinite(value)
                or (self._previous is not None and value < self._previous)):
            raise ValueError("invalid common timing clock")
        self._previous = float(value)
        return float(value)

    def source(self, frame: PcmChunk) -> None:
        if (
            not isinstance(frame, PcmChunk)
            or type(frame.sequence) is not int or frame.sequence != self.source_frames
            or type(frame.start_sample) is not int or frame.start_sample != self.source_samples
            or type(frame.end_sample) is not int
            or not frame.start_sample < frame.end_sample <= self.samples
            or self.source_frames >= 65536
            or any(type(v) not in (int, float) or not math.isfinite(v)
                   for v in (frame.target_at, frame.offered_at))
            or frame.offered_at < frame.target_at
        ):
            raise ValueError("invalid timing source sequence")
        origin = frame.target_at - frame.end_sample / 16000
        if (self.origin is not None
                and not math.isclose(origin, self.origin, rel_tol=0, abs_tol=1e-6)):
            raise ValueError("timing source origin changed")
        self.origin = origin
        delay = self.tick() - frame.offered_at
        if delay < -1e-6:
            raise ValueError("timing clock precedes source offer")
        self._max_queue = max(self._max_queue, delay)
        self.source_frames += 1
        self.source_samples = frame.end_sample

    def _add(self, record: _Record) -> int:
        bucket = (
            "asr" if record.kind == "asr_sealed" else
            "snapshot" if record.kind == "asr_body_snapshot" else "publication"
        )
        limit = {"asr": self.MAX_ASR_RECORDS, "snapshot": 1,
                 "publication": self.MAX_PUBLICATION_RECORDS}[bucket]
        if self._record_counts[bucket] >= limit or len(self._records) >= self.MAX_RECORDS:
            raise ValueError("timing record budget exceeded")
        self._records.append(record)
        self._record_counts[bucket] += 1
        return len(self._records) - 1

    def asr_terminal(self, start: int, end: int) -> None:
        if (type(start) is not int or type(end) is not int or start != self.asr_sealed
                or not start < end <= self.source_samples):
            raise ValueError("invalid ASR sealed timing coverage")
        at = self.tick()
        self._add(_Record("asr_sealed", start, end, -1, None, None, at, at))
        self.asr_sealed = end

    def begin_delivery(self, row: Mapping[str, Any]) -> _Ticket:
        kind = row.get("kind")
        if not isinstance(kind, str) or kind not in self.KINDS or len(self._open) >= self.MAX_OPEN:
            raise ValueError("invalid timing delivery or budget")
        entered, index = self.tick(), None
        if kind == "activity_watermark":
            accepted, processed, stable = (_integer(row.get(k)) for k in (
                "accepted_samples", "processed_samples", "stable_samples"))
            if not self._dia_observed <= stable <= processed <= accepted <= self.samples:
                raise ValueError("invalid stable watermark timing")
            index = self._add(_Record(kind, self._dia_observed, stable, -1, None, None, entered))
            self._dia_observed = stable
        elif kind == "text":
            start, end, sequence = (_integer(row.get(k)) for k in (
                "start_sample", "end_sample", "sequence"))
            text, speaker = row.get("text"), row.get("speaker")
            if (
                not 0 <= start < end <= self.samples or not 0 <= sequence < 4096
                or type(row.get("unit_index")) is not int or row["unit_index"] != 0
                or type(text) is not str or not 0 < len(text) <= 10000
                or row.get("granularity") != "utterance"
                or type(speaker) is not str
                or speaker not in {"unknown", *[f"S{i}" for i in range(1, 9)]}
            ):
                raise ValueError("invalid text publication timing")
            index = self._add(_Record(kind, start, end, sequence, speaker != "unknown",
                                      hashlib.sha256(text.encode()).hexdigest(), entered))
        elif kind == "asr_body_snapshot":
            index = self._add(_Record(kind, 0, self.samples, -1, False, None, entered))
        ticket = _Ticket(self._counter, kind, entered, index)
        self._counter += 1
        self._entered[kind] += 1
        self._open[ticket.id] = ticket
        return ticket

    def end_delivery(self, ticket: _Ticket) -> None:
        if self._open.get(ticket.id) is not ticket:
            raise ValueError("timing delivery is not open")
        at = self.tick()
        if ticket.record is not None:
            record = self._records[ticket.record]
            if record.kind == "activity_watermark":
                if record.start != self.dia_stable:
                    raise ValueError("stable watermark acknowledgements reordered")
                self.dia_stable = record.end
            record.finished = at
        self._max_sink = max(self._max_sink, at - ticket.entered)
        self._delivered[ticket.kind] += 1
        del self._open[ticket.id]

    def fail_delivery(self, ticket: _Ticket) -> None:
        if self._open.pop(ticket.id, None) is ticket:
            self._failed[ticket.kind] += 1

    def mark(self, kind: str) -> None:
        if (kind not in {"asr_callback_complete", "dia_input_eof", "dia_scope_closed"}
                or kind in self._marks):
            raise ValueError("invalid timing milestone")
        self._marks[kind] = self.tick()

    def summary(
        self, feed: Mapping[str, Any], expected: Sequence[CompletedText],
    ) -> dict[str, Any]:
        origin = _finite(feed.get("source_origin_at"))
        if (self.origin is None
                or not math.isclose(origin, self.origin, rel_tol=0, abs_tol=1e-6)
                or feed.get("clock_source") not in {"monotonic", "injected"}):
            raise ValueError("timing source origin is unconfirmed")
        delivered: dict[int, list[_Record]] = {}
        maxima: dict[str, float] = {}
        for record in self._records:
            if record.finished is None:
                continue
            delay = record.finished - origin - record.end / 16000
            if delay < -1e-6:
                raise ValueError("timing publication precedes source sample end")
            if record.end > record.start:
                maxima[record.kind] = max(maxima.get(record.kind, 0.), delay)
            if record.kind == "text":
                delivered.setdefault(record.sequence, []).append(record)
        matched = known = 0
        for item in expected:
            rows = delivered.get(item.sequence, [])
            if (len(rows) == 1 and rows[0].start == item.span.start and rows[0].end == item.span.end
                    and rows[0].text_sha256 == hashlib.sha256(item.text.encode()).hexdigest()):
                matched += 1
                known += int(rows[0].known is True)
        sequences = {item.sequence for item in expected}
        extra = sum(len(rows) for sequence, rows in delivered.items() if sequence not in sequences)
        return {
            "schema_version": 1, "scope": "diagnostic_host_sink_acknowledgements",
            "clock_source": feed["clock_source"], "source_origin_at": origin,
            "source_samples_observed": self.source_samples,
            "source_frames_observed": self.source_frames,
            "asr_sealed_through": self.asr_sealed, "dia_stable_through": self.dia_stable,
            "expected_text_units": len(expected),
            "missing_or_invalid_text_units": len(expected) - matched,
            "extra_text_units": extra, "known_text_units": known,
            "unknown_text_units": matched - known,
            "text_delivery_verified": matched == len(expected) and extra == 0,
            "open_sink_deliveries": len(self._open), "failed_sink_deliveries": dict(self._failed),
            "entered_by_kind": dict(self._entered), "completed_by_kind": dict(self._delivered),
            "max_asr_source_queue_seconds": self._max_queue, "max_sink_seconds": self._max_sink,
            "asr_terminal_end_max_delay_seconds": maxima.get("asr_sealed"),
            "dia_watermark_sink_end_max_delay_seconds": maxima.get("activity_watermark"),
            "text_sink_end_max_delay_seconds": maxima.get("text"),
            "milestones_at": dict(self._marks),
            "record_fields": ["kind", "start_sample", "end_sample", "sequence", "known",
                              "text_sha256", "entered_at", "completed_at"],
            "records": [record.row() for record in self._records],
            "max_records": self.MAX_RECORDS, "max_open_deliveries": self.MAX_OPEN,
            "max_asr_records": self.MAX_ASR_RECORDS,
            "max_publication_records": self.MAX_PUBLICATION_RECORDS,
            "sampling_policy": "not_registered", "stable_label_p95_seconds": None,
            "finish_p95_seconds": None, "latency_gate": "not_evaluated",
            "certification_eligible": False, "microphone_capture_verified": False,
        }
