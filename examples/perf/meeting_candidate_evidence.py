"""Bounded attribution of actual ASR evidence to causal candidate activity.

No reference speaker, reference boundary or reference text is an input. Final
text events belong in external evaluation sinks, never logs or repository files.
"""

from __future__ import annotations

from dataclasses import dataclass

from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.diarization.attribution import AttributionLedger, AttributionPolicy
from speechrail.domain.diarization.types import ActivityUpdate, Attribution, TextUnit

RETENTION_SAMPLES = 60 * 16000
MAX_PENDING_CHARACTERS = 262144
MAX_UNITS = 4096
MAX_ACTIVITY_FRAMES = 8192


def attribution_configuration() -> dict[str, object]:
    policy = AttributionPolicy()
    return {
        "algorithm": "causal_attribution_ledger_v2",
        "min_support": policy.min_support,
        "min_margin": policy.min_margin,
        "continuity_gap_seconds": policy.continuity_gap_seconds,
        "continuity_break_on_degraded": True,
        "label_mode": "meeting_dynamic",
        "retention_samples": RETENTION_SAMPLES,
        "max_pending_characters": MAX_PENDING_CHARACTERS,
        "max_units": MAX_UNITS,
        "max_activity_frames": MAX_ACTIVITY_FRAMES,
        "text_ranges": "lossless_provided_word_or_whole_asr_span_v1",
        "production_certification": False,
    }


@dataclass(frozen=True, slots=True)
class CompletedText:
    sequence: int
    text: str
    span: SampleSpan
    units: tuple[TextUnit, ...] = ()


@dataclass(frozen=True, slots=True)
class SpeakerSpan:
    span: SampleSpan
    speaker: str


@dataclass(frozen=True, slots=True)
class AttributedText:
    sequence: int
    unit_index: int
    text: str
    span: SampleSpan
    speaker: str
    reason: str | None
    granularity: str


EvidenceEvent = SpeakerSpan | AttributedText


def _integer_span(span: SampleSpan) -> bool:
    return type(span.start) is int and type(span.end) is int


class CandidateEvidence:
    """One serial event-loop owner, using the production attribution policy."""

    def __init__(
        self,
        *,
        epoch: str,
        retention_samples: int = RETENTION_SAMPLES,
        max_pending_characters: int = MAX_PENDING_CHARACTERS,
        max_units: int = MAX_UNITS,
        policy: AttributionPolicy | None = None,
    ) -> None:
        if (
            not isinstance(epoch, str)
            or not epoch
            or any(
                type(v) is not int or v < 1
                for v in (retention_samples, max_pending_characters, max_units)
            )
        ):
            raise ValueError("invalid evidence limits or epoch")
        self.epoch = epoch
        self.accepted = self.processed = 0
        self._step = 0
        self._sequence = -1
        self._retention = retention_samples
        self._max_characters, self._max_units = max_pending_characters, max_units
        self._ledger = AttributionLedger(
            accepted_samples=lambda: self.accepted, policy=policy, label_mode="meeting_dynamic"
        )
        self._pending: dict[str, tuple[int, int, str, SampleSpan, str]] = {}
        self._pending_characters = 0
        self._open_slots: dict[int, int] = {}
        self._closed = self.complete = False

    @property
    def retained_counts(self) -> dict[str, int]:
        return {
            **self._ledger.retained_counts,
            "pending_units": len(self._pending),
            "pending_characters": self._pending_characters,
        }

    def accept(self, samples: int) -> None:
        if self._closed or type(samples) is not int or not 1 <= samples <= 16000:
            raise ValueError("invalid bounded audio acceptance")
        self.accepted += samples

    def register(self, item: CompletedText) -> tuple[AttributedText, ...]:
        if self._closed or type(item.sequence) is not int or item.sequence != self._sequence + 1:
            raise ValueError("text sequence must be contiguous")
        if (
            not isinstance(item.text, str)
            or not item.text
            or not _integer_span(item.span)
            or item.span.length <= 0
            or item.span.end > self.accepted
            or item.span.length > 30 * 16000
        ):
            raise ValueError("text requires actual accepted ASR timing")
        if self._pending_characters + len(item.text) > self._max_characters:
            raise ValueError("pending text budget exceeded")
        units = item.units or (TextUnit("coarse", 0, len(item.text), item.span),)
        if len(units) > 1 and len({unit.audio_span for unit in units}) == 1:
            raise ValueError("word evidence cannot share an utterance timestamp grid")
        if len(units) + self._ledger.retained_counts["units"] > self._max_units:
            raise ValueError("text unit budget exceeded")
        prepared = []
        cursor = 0
        for index, unit in enumerate(units):
            if (
                unit.audio_span is None
                or not _integer_span(unit.audio_span)
                or unit.audio_span.length <= 0
                or not item.span.contains(unit.audio_span)
                or not cursor <= unit.text_start < unit.text_end <= len(item.text)
                or any(c.isalnum() for c in item.text[cursor : unit.text_start])
            ):
                raise ValueError("text alignment is incomplete or outside actual ASR timing")
            end = len(item.text) if index == len(units) - 1 else unit.text_end
            if index == len(units) - 1 and any(c.isalnum() for c in item.text[unit.text_end :]):
                raise ValueError("text alignment omits transcript characters")
            uid = f"u_{item.sequence}_{index}"
            prepared.append(
                (
                    TextUnit(uid, cursor, end, unit.audio_span),
                    (
                        item.sequence,
                        index,
                        item.text[cursor:end],
                        unit.audio_span,
                        "word" if item.units else "utterance",
                    ),
                )
            )
            cursor = unit.text_end
        # Validate the whole item before the ledger or sequence can change.
        for unit, row in prepared:
            self._pending[unit.id] = row
        self._pending_characters += len(item.text)
        attributions = self._ledger.register(f"item_{item.sequence}", tuple(u for u, _ in prepared))
        self._sequence = item.sequence
        emitted = self._texts(attributions)
        self._compact()
        return emitted

    def apply(self, update: ActivityUpdate) -> tuple[EvidenceEvent, ...]:
        if (
            self._closed
            or type(update.step_id) is not int
            or type(update.processed_through) is not int
            or type(update.stable_through) is not int
            or not _integer_span(update.replace_span)
            or update.epoch != self.epoch
            or update.step_id != self._step
            or update.replace_span.start != self.processed
            or update.replace_span.end != update.processed_through
            or update.stable_through != update.processed_through
            or not self.processed <= update.processed_through <= self.accepted
            or len(update.frames) > 2048
        ):
            raise ValueError("invalid causal activity coverage or identity")
        cursor = self.processed
        for frame in update.frames:
            if (
                not _integer_span(frame.span)
                or frame.span.start != cursor
                or frame.span.length <= 0
                or frame.reason is not None
                or any(slot >= 8 for slot in frame.active_slots)
            ):
                raise ValueError("candidate activity has gaps or unavailable evidence")
            cursor = frame.span.end
        if cursor != update.processed_through:
            raise ValueError("candidate omitted activity before its watermark")
        attributions = self._ledger.apply(update)
        events: list[EvidenceEvent] = list(self._texts(attributions))
        for frame in update.frames:
            for slot in sorted(set(self._open_slots) - frame.active_slots):
                events.append(
                    SpeakerSpan(
                        SampleSpan(self._open_slots.pop(slot), frame.span.start), f"S{slot + 1}"
                    )
                )
            for slot in sorted(frame.active_slots - set(self._open_slots)):
                self._open_slots[slot] = frame.span.start
        self.processed = update.processed_through
        self._step += 1
        before = max(0, self.processed - self._retention)
        events.extend(self._texts(self._ledger.expire_before(before)))
        self._compact()
        if self._ledger.retained_counts["frames"] > MAX_ACTIVITY_FRAMES:
            raise ValueError("activity history budget exceeded")
        return tuple(events)

    def _texts(self, attributions: tuple[Attribution, ...]) -> tuple[AttributedText, ...]:
        events = []
        for attribution in attributions:
            if attribution.state != "final":
                continue
            sequence, index, text, span, granularity = self._pending.pop(attribution.unit_id)
            self._pending_characters -= len(text)
            events.append(
                AttributedText(
                    sequence,
                    index,
                    text,
                    span,
                    attribution.speaker or "unknown",
                    attribution.reason,
                    granularity,
                )
            )
        return tuple(events)

    def _compact(self) -> None:
        self._ledger.compact(max(0, self.processed - self._retention))

    def _close(self, reason: str) -> tuple[EvidenceEvent, ...]:
        if self._closed:
            return ()
        events: list[EvidenceEvent] = list(self._texts(self._ledger.terminate_pending(reason)))
        events.extend(
            SpeakerSpan(SampleSpan(start, self.processed), f"S{slot + 1}")
            for slot, start in sorted(self._open_slots.items())
        )
        self._open_slots.clear()
        self._closed = True
        return tuple(events)

    def finish(self) -> tuple[EvidenceEvent, ...]:
        if self._closed:
            return ()
        self.complete = self.processed == self.accepted and not self._pending
        return self._close("finalized" if self.complete else "finalization_incomplete")

    def abort(self, reason: str) -> tuple[EvidenceEvent, ...]:
        if self._closed:
            return ()
        self.complete = False
        return self._close(reason)
