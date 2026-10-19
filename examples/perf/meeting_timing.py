"""Bounded common-clock metadata; no raw text, P95 or latency certification."""

from __future__ import annotations

import asyncio
import hashlib
import heapq
import math
import time
from collections import Counter
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from meeting_latency_policy import latency_policy, weighted_p95
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
    MAX_EXPECTED_UNITS = 4096
    KINDS = frozenset({"phase", "activity", "asr_text_ready", "stable_activity_frame",
                       "activity_watermark", "text", "stable_text", "asr_body_snapshot"})

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
        self.changed = asyncio.Event()
        self.deadline_changed = asyncio.Event()
        self._pending: list[tuple[int, int, int]] = []
        self._texts: dict[int, list[int]] = {}
        self._speakers: dict[int, str] = {}
        self._offered: dict[int, int] = {}
        self._stable: set[int] = set()
        self._expected: dict[int, tuple[int, int, str]] = {}
        self._pending_expected: list[tuple[int, int]] = []
        self._completed_expected: dict[int, float] = {}
        self._max_stable_delay = -1.
        self._max_stable_end = 0
        self._last_stable_ack = 0.

    def tick(self) -> float:
        value = self.clock()
        if (type(value) not in (int, float) or not math.isfinite(value)
                or (self._previous is not None and value < self._previous)):
            raise ValueError("invalid common timing clock")
        self._previous = float(value)
        return float(value)

    def _signal(self) -> None:
        self.changed.set()
        self.deadline_changed.set()

    def expect_text(self, item: CompletedText) -> None:
        if (type(item.sequence) is not int or item.sequence != len(self._expected)
                or len(self._expected) >= self.MAX_EXPECTED_UNITS or not item.text
                or not 0 <= item.span.start < item.span.end <= self.source_samples):
            raise ValueError("invalid expected deadline text")
        self._expected[item.sequence] = (
            item.span.start, item.span.end, hashlib.sha256(item.text.encode()).hexdigest(),
        )
        heapq.heappush(self._pending_expected, (item.span.end, item.sequence))
        self._signal()

    def next_stable_deadline(self, hard_seconds: float) -> float | None:
        hard_seconds = _finite(hard_seconds)
        if not 0 < hard_seconds <= 30:
            raise ValueError("invalid stable deadline budget")
        while self._pending_expected and self._pending_expected[0][1] in self._completed_expected:
            heapq.heappop(self._pending_expected)
        if self.origin is None or not self._pending_expected:
            return None
        return self.origin + self._pending_expected[0][0] / 16000 + hard_seconds

    def late_stable_deadline(self, hard_seconds: float) -> float | None:
        hard_seconds = _finite(hard_seconds)
        if not 0 < hard_seconds <= 30:
            raise ValueError("invalid stable deadline budget")
        if self.origin is not None and self._max_stable_delay > hard_seconds:
            return self.origin + self._max_stable_end / 16000 + hard_seconds
        return None

    def finish_completed_at(self) -> float | None:
        if (self.next_stable_deadline(30.) is not None
                or not self.asr_sealed == self.dia_stable == self.source_samples == self.samples
                or set(self._marks) != {
                    "asr_callback_complete", "dia_input_eof", "dia_scope_closed",
                }):
            return None
        return max(self._last_stable_ack, *self._marks.values())

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
        self._signal()

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
        self._signal()

    def ready_publications(self) -> tuple[dict[str, Any], ...]:
        """Claim each marker once; no raw text or reference data enters it."""
        rows = []
        through = min(self.asr_sealed, self.dia_stable)
        while self._pending and self._pending[0][0] <= through:
            _, sequence, index = heapq.heappop(self._pending)
            if sequence in self._offered or len(self._texts[sequence]) != 1:
                continue
            record = self._records[index]
            self._offered[sequence] = index
            rows.append({
                "kind": "stable_text", "sequence": sequence, "unit_index": 0,
                "start_sample": record.start, "end_sample": record.end,
                "speaker": self._speakers[index], "granularity": "utterance",
            })
        return tuple(rows)

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
            self._speakers[index] = speaker
        elif kind == "stable_text":
            sequence = _integer(row.get("sequence"))
            original = self._offered.get(sequence)
            if original is None or sequence in self._stable:
                raise ValueError("stable marker has no unique ready text")
            record = self._records[original]
            if (_integer(row.get("start_sample")) != record.start
                    or _integer(row.get("end_sample")) != record.end
                    or row.get("speaker") != self._speakers[original]
                    or row.get("granularity") != "utterance"
                    or type(row.get("unit_index")) is not int or row["unit_index"] != 0
                    or record.end > min(self.asr_sealed, self.dia_stable)):
                raise ValueError("stable marker differs from ready text")
            self._stable.add(sequence)
            index = self._add(_Record(kind, record.start, record.end, sequence,
                                      record.known, record.text_sha256, entered))
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
            if record.kind == "text":
                self._texts.setdefault(record.sequence, []).append(ticket.record)
                heapq.heappush(self._pending, (record.end, record.sequence, ticket.record))
            if record.kind == "stable_text" and self.origin is not None:
                expected = self._expected.get(record.sequence)
                if expected == (record.start, record.end, record.text_sha256):
                    self._completed_expected[record.sequence] = at
                    self._last_stable_ack = max(self._last_stable_ack, at)
                    delay = at - self.origin - record.end / 16000
                    if delay > self._max_stable_delay:
                        self._max_stable_delay, self._max_stable_end = delay, record.end
        self._max_sink = max(self._max_sink, at - ticket.entered)
        self._delivered[ticket.kind] += 1
        del self._open[ticket.id]
        self._signal()

    def fail_delivery(self, ticket: _Ticket) -> None:
        if self._open.pop(ticket.id, None) is ticket:
            self._failed[ticket.kind] += 1
            self._signal()

    def mark(self, kind: str) -> None:
        if (kind not in {"asr_callback_complete", "dia_input_eof", "dia_scope_closed"}
                or kind in self._marks):
            raise ValueError("invalid timing milestone")
        self._marks[kind] = self.tick()
        self._signal()

    def summary(
        self, feed: Mapping[str, Any], expected: Sequence[CompletedText],
    ) -> dict[str, Any]:
        origin = _finite(feed.get("source_origin_at"))
        if (self.origin is None
                or not math.isclose(origin, self.origin, rel_tol=0, abs_tol=1e-6)
                or feed.get("clock_source") not in {"monotonic", "injected"}):
            raise ValueError("timing source origin is unconfirmed")
        delivered: dict[int, list[_Record]] = {}
        stable: dict[int, list[_Record]] = {}
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
            if record.kind == "stable_text":
                stable.setdefault(record.sequence, []).append(record)
        matched = known = 0
        stable_matched = 0
        latency_rows: list[tuple[int, float | None]] = []
        for item in expected:
            stable_delay = None
            rows = delivered.get(item.sequence, [])
            if (len(rows) == 1 and rows[0].start == item.span.start and rows[0].end == item.span.end
                    and rows[0].text_sha256 == hashlib.sha256(item.text.encode()).hexdigest()):
                matched += 1
                known += int(rows[0].known is True)
                markers = stable.get(item.sequence, [])
                if (len(markers) == 1 and markers[0].start == item.span.start
                        and markers[0].end == item.span.end
                        and markers[0].text_sha256 == rows[0].text_sha256
                        and markers[0].known == rows[0].known):
                    stable_matched += 1
                    if markers[0].known and markers[0].finished is not None:
                        stable_delay = max(0., markers[0].finished - origin - item.span.end / 16000)
            latency_rows.append((item.span.length, stable_delay))
        sequences = {item.sequence for item in expected}
        extra = sum(len(rows) for sequence, rows in delivered.items() if sequence not in sequences)
        policy = latency_policy()
        p95 = weighted_p95(latency_rows)
        failed_weight = sum(weight for weight, delay in latency_rows if delay is None)
        hard_failures = sum(delay is None or delay > policy["stable_label_hard_seconds"]
                            for _, delay in latency_rows)
        stable_gate = (
            "not_evaluated_no_text" if not latency_rows else
            "no-go" if (self._open or self._failed or extra or hard_failures
                        or p95 is None or p95 > policy["stable_label_p95_seconds"]) else
            "diagnostic_pass"
        )
        finish = None
        if (stable_matched == len(expected) and not extra and not self._open and not self._failed
                and self.asr_sealed == self.dia_stable == self.source_samples == self.samples
                and set(self._marks) == {
                    "asr_callback_complete", "dia_input_eof", "dia_scope_closed",
                }):
            last_ack = max((r.finished for r in self._records
                            if r.kind in {"stable_text", "asr_body_snapshot"}
                            and r.finished is not None), default=origin)
            finish = max(last_ack, *self._marks.values()) - origin - self.samples / 16000
            if finish < -1e-6:
                raise ValueError("finish precedes source sample end")
            finish = max(0., finish)
        return {
            "schema_version": 2, "scope": "diagnostic_host_sink_acknowledgements",
            "clock_source": feed["clock_source"], "source_origin_at": origin,
            "source_samples_observed": self.source_samples,
            "source_frames_observed": self.source_frames,
            "asr_sealed_through": self.asr_sealed, "dia_stable_through": self.dia_stable,
            "deadline_expected_text_units": len(self._expected),
            "deadline_completed_text_units": len(self._completed_expected),
            "expected_text_units": len(expected),
            "missing_or_invalid_text_units": len(expected) - matched,
            "extra_text_units": extra, "known_text_units": known,
            "unknown_text_units": matched - known,
            "text_delivery_verified": matched == len(expected) and extra == 0,
            "stable_delivery_verified": stable_matched == len(expected) and extra == 0,
            "missing_or_invalid_stable_units": len(expected) - stable_matched,
            "open_sink_deliveries": len(self._open), "failed_sink_deliveries": dict(self._failed),
            "entered_by_kind": dict(self._entered), "completed_by_kind": dict(self._delivered),
            "max_asr_source_queue_seconds": self._max_queue, "max_sink_seconds": self._max_sink,
            "asr_terminal_end_max_delay_seconds": maxima.get("asr_sealed"),
            "dia_watermark_sink_end_max_delay_seconds": maxima.get("activity_watermark"),
            "text_sink_end_max_delay_seconds": maxima.get("text"),
            "stable_text_sink_end_max_delay_seconds": maxima.get("stable_text"),
            "milestones_at": dict(self._marks),
            "record_fields": ["kind", "start_sample", "end_sample", "sequence", "known",
                              "text_sha256", "entered_at", "completed_at"],
            "records": [record.row() for record in self._records],
            "max_records": self.MAX_RECORDS, "max_open_deliveries": self.MAX_OPEN,
            "max_asr_records": self.MAX_ASR_RECORDS,
            "max_publication_records": self.MAX_PUBLICATION_RECORDS,
            "sampling_policy": policy["sampling"], "stable_label_p95_seconds": None,
            "latency_diagnostics": {
                "scope": "single_meeting_host_sink_only",
                "stable_publication_p95_seconds": p95,
                "expected_weight_samples": sum(weight for weight, _ in latency_rows),
                "failed_weight_samples": failed_weight,
                "stable_hard_failure_units": hard_failures,
                "stable_gate": stable_gate,
                "finish_seconds": finish, "finish_unresolved": finish is None,
                "finish_hard_failed": finish is not None and finish > policy["finish_hard_seconds"],
                "finish_target_exceeded": (
                    finish is not None and finish > policy["finish_p95_seconds"]
                ),
                "finish_gate": "not_evaluated_single_meeting",
                "production_or_capture_verified": False,
            },
            "finish_p95_seconds": None, "latency_gate": "not_evaluated",
            "certification_eligible": False, "microphone_capture_verified": False,
        }
