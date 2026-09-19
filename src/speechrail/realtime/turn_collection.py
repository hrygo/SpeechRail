"""Bounded reference consumer for SpeechRail's manual ASR commit/clear barrier.

Feed every server event (including session events) in wire order. The caller
owns one serialized writer and must stop appending before begin_close(), then
send commit followed by clear. This proves protocol completion, not ASR quality
or sample-exact audio acceptance. No audio or transcript is logged here.
"""
from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True, slots=True)
class CollectedTranscript:
    epoch: str
    item_ids: tuple[str, ...]
    text: str


class ManualTurnCollector:
    """Collect rollover items exactly once without mistaking cleared for success."""

    def __init__(
        self, *, epoch: str, start_sequence: int = 0, max_events: int = 16_384,
        max_items: int = 1024, max_text_chars: int = 100_000,
    ) -> None:
        if not epoch or start_sequence < 0 or min(max_events, max_items, max_text_chars) < 1:
            raise ValueError("invalid_collection_limits")
        self.epoch = epoch
        self.state: Literal["collecting", "closing", "completed", "failed", "cancelled"] = (
            "collecting"
        )
        self.failure_reason: str | None = None
        self.result: CollectedTranscript | None = None
        self._sequence = start_sequence
        self._limits = (max_events, max_items, max_text_chars)
        self._events: dict[str, str] = {}
        self._order: list[str] = []
        self._texts: dict[str, str] = {}
        self._text_chars = 0

    def _fail(self, reason: str) -> None:
        self.state = "failed"
        self.failure_reason = self.failure_reason or reason
        self.result = None

    def note_append(self) -> None:
        """Call before sending append; a writer violation invalidates this turn."""
        if self.state != "collecting":
            self._fail("append_during_close")
            raise ValueError("turn_not_collecting")

    def begin_close(self) -> None:
        """Mark the sole outstanding commit/clear pair before writing either."""
        if self.state != "collecting":
            self._fail("duplicate_close")
            raise ValueError("turn_not_collecting")
        self.state = "closing"

    def cancel(self) -> None:
        self.state = "cancelled"
        self.result = None

    def disconnect(self) -> None:
        if self.state not in {"completed", "cancelled"}:
            self._fail("disconnected_before_barrier")

    def accept(self, event: Mapping[str, object], *, epoch: str) -> None:
        """Accept one JSON event. Ignore obsolete connections, not sequence gaps."""
        if epoch != self.epoch or self.state in {"failed", "cancelled", "completed"}:
            return
        sequence, event_id = event.get("sequence"), event.get("event_id")
        if (
            type(sequence) is not int or not isinstance(event_id, str)
            or not 0 < len(event_id) <= 128
        ):
            self._fail("invalid_event_envelope")
            return
        try:
            digest = hashlib.sha256(
                json.dumps(dict(event), sort_keys=True, ensure_ascii=False).encode("utf-8")
            ).hexdigest()
        except (TypeError, ValueError):
            self._fail("invalid_event_envelope")
            return
        previous = self._events.get(event_id)
        if previous is not None:
            if previous != digest:
                self._fail("conflicting_duplicate")
            return
        if len(self._events) >= self._limits[0]:
            self._fail("event_budget_exceeded")
            return
        if sequence != self._sequence + 1:
            self._fail("sequence_gap")
            return
        self._events[event_id] = digest
        self._sequence = sequence
        kind = event.get("type")
        if kind in {"error", "conversation.item.input_audio_transcription.failed"}:
            self._fail("upstream_error")
        elif kind == "input_audio_buffer.committed":
            item = event.get("item_id")
            if (
                not isinstance(item, str) or not 0 < len(item) <= 256
                or item in self._order or len(self._order) >= self._limits[1]
            ):
                self._fail("invalid_committed_item")
                return
            self._order.append(item)
        elif kind == "conversation.item.input_audio_transcription.completed":
            item, text = event.get("item_id"), event.get("transcript")
            if not isinstance(item, str) or item not in self._order or not isinstance(text, str):
                self._fail("invalid_terminal")
                return
            if item in self._texts:
                if self._texts[item] != text:
                    self._fail("conflicting_terminal")
                return
            if self._text_chars + len(text) > self._limits[2]:
                self._fail("text_budget_exceeded")
                return
            self._texts[item] = text
            self._text_chars += len(text)
        elif kind == "input_audio_buffer.cleared":
            if self.state != "closing" or not self._order or len(self._texts) != len(self._order):
                self._fail("incomplete_barrier")
                return
            self.state = "completed"
            self.result = CollectedTranscript(
                epoch=self.epoch, item_ids=tuple(self._order),
                text="".join(self._texts[item] for item in self._order),
            )
