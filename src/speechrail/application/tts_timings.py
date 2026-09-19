"""Bounded lifecycle registry for optional TTS timing sidecars."""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from typing import Literal
from uuid import uuid4

from speechrail.domain.tts_timing import TtsTimingSidecar

TimingStatus = Literal["pending", "completed", "unavailable", "cancelled", "error"]


@dataclass(slots=True)
class _TimingState:
    timing_id: str
    request_id: str
    sample_rate: int
    display_mapping_status: Literal["identity", "mapped", "unavailable"]
    expected_text_spans: tuple[tuple[int, int], ...]
    display_spans: tuple[tuple[int, int] | None, ...]
    display_mapping_reason: str | None = None
    status: TimingStatus = "pending"
    reason: str | None = None
    sidecar: TtsTimingSidecar | None = None
    created_at: float = field(default_factory=time.time)
    completed_at: float | None = None


class TtsTimingRegistry:
    """Store metadata-only timing results; never retain audio or source text."""

    def __init__(self, *, max_entries: int = 512) -> None:
        if max_entries < 1:
            raise ValueError("max_entries must be positive")
        self._max_entries = max_entries
        self._lock = threading.RLock()
        self._entries: dict[str, _TimingState] = {}
        self._order: list[str] = []

    def begin(
        self,
        *,
        request_id: str,
        sample_rate: int,
        display_mapping_status: Literal["identity", "mapped", "unavailable"],
        expected_text_spans: tuple[tuple[int, int], ...],
        display_spans: tuple[tuple[int, int] | None, ...] = (),
        display_mapping_reason: str | None = None,
    ) -> str:
        if sample_rate <= 0:
            raise ValueError("sample_rate must be positive")
        timing_id = f"tm_{uuid4().hex}"
        state = _TimingState(
            timing_id=timing_id,
            request_id=request_id,
            sample_rate=sample_rate,
            display_mapping_status=display_mapping_status,
            expected_text_spans=expected_text_spans,
            display_spans=display_spans,
            display_mapping_reason=display_mapping_reason,
        )
        with self._lock:
            self._make_room_locked()
            self._entries[timing_id] = state
            self._order.append(timing_id)
        return timing_id

    def _make_room_locked(self) -> None:
        while len(self._order) >= self._max_entries:
            victim = next(
                (
                    index
                    for index, existing_id in enumerate(self._order)
                    if self._entries[existing_id].status != "pending"
                ),
                None,
            )
            if victim is None:
                raise RuntimeError("timing store is full of pending entries")
            existing_id = self._order.pop(victim)
            self._entries.pop(existing_id, None)

    def complete(self, timing_id: str, sidecar: TtsTimingSidecar) -> None:
        with self._lock:
            state = self._entries[timing_id]
            if state.status != "pending":
                return
            backend_spans = tuple(
                (chunk.text_start, chunk.text_end) for chunk in sidecar.chunks
            )
            if sidecar.sample_rate != state.sample_rate:
                state.status = "unavailable"
                state.reason = "timing_sample_rate_mismatch"
            elif backend_spans != state.expected_text_spans:
                state.status = "unavailable"
                state.reason = "planner_contract_mismatch"
            elif state.display_spans and len(state.display_spans) != len(sidecar.chunks):
                state.status = "unavailable"
                state.reason = "display_mapping_chunk_mismatch"
            else:
                state.sidecar = sidecar
                state.status = "completed"
            state.completed_at = time.time()

    def unavailable(self, timing_id: str, reason: str) -> None:
        self._finish(timing_id, status="unavailable", reason=reason)

    def cancel(self, timing_id: str) -> None:
        self._finish(timing_id, status="cancelled", reason="cancelled")

    def fail(self, timing_id: str, reason: str) -> None:
        self._finish(timing_id, status="error", reason=reason)

    def _finish(self, timing_id: str, *, status: TimingStatus, reason: str) -> None:
        with self._lock:
            state = self._entries[timing_id]
            if state.status != "pending":
                return
            state.status = status
            state.reason = reason
            state.completed_at = time.time()

    def get(self, timing_id: str) -> dict[str, object]:
        with self._lock:
            state = self._entries.get(timing_id)
            if state is None:
                raise KeyError(timing_id)
            sidecar = state.sidecar
            chunks: list[dict[str, object]] = []
            if sidecar is not None:
                for index, chunk in enumerate(sidecar.chunks):
                    item = chunk.model_dump(mode="json")
                    display_span = (
                        state.display_spans[index]
                        if index < len(state.display_spans)
                        else None
                    )
                    item["display_start"] = (
                        display_span[0] if display_span is not None else None
                    )
                    item["display_end"] = (
                        display_span[1] if display_span is not None else None
                    )
                    chunks.append(item)
            return {
                "timing_id": state.timing_id,
                "request_id": state.request_id,
                "status": state.status,
                "timing_quality": sidecar.timing_quality if sidecar is not None else "unavailable",
                "coordinate_space": (
                    sidecar.coordinate_space if sidecar is not None else None
                ),
                "planner_version": sidecar.planner_version if sidecar is not None else None,
                "sample_rate": state.sample_rate,
                "total_samples": sidecar.total_samples if sidecar is not None else None,
                "display_mapping": {
                    "status": state.display_mapping_status,
                    "reason": state.display_mapping_reason,
                },
                "chunks": chunks,
                "reason": state.reason,
                "created_at": state.created_at,
                "completed_at": state.completed_at,
            }


__all__ = ["TtsTimingRegistry"]
