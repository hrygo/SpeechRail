"""Single serial actor joining fixed text with continuous speaker activity."""

from __future__ import annotations

import asyncio
import contextlib
from collections import deque
from collections.abc import AsyncIterator
from dataclasses import dataclass

from speechrail.domain.diarization.attribution import AttributionLedger
from speechrail.domain.diarization.ports import ActivitySession
from speechrail.domain.diarization.types import Attribution, TextUnit


@dataclass(frozen=True, slots=True)
class ItemAttributionUpdated:
    item_id: str
    attributions: tuple[Attribution, ...]
    sequence: int


@dataclass(frozen=True, slots=True)
class StatusChanged:
    status: str
    reason: str
    sequence: int


@dataclass(frozen=True, slots=True)
class SessionDone:
    event_id: str
    status: str
    last_sequence: int


SessionEvent = ItemAttributionUpdated | StatusChanged | SessionDone


class DiarizationSession:
    """Own exactly one activity session and serially publish domain revisions."""

    def __init__(
        self,
        *,
        activity: ActivitySession,
        ledger: AttributionLedger,
        drain_timeout_seconds: float = 30,
        max_pending_update_events: int = 64,
        activity_backlog_seconds: float = 5,
    ) -> None:
        if max_pending_update_events < 1 or activity_backlog_seconds <= 0:
            raise ValueError("diarization session limits must be positive")
        self._activity = activity
        self._ledger = ledger
        self._drain_timeout_seconds = drain_timeout_seconds
        self._max_pending_update_events = max_pending_update_events
        self._activity_backlog_seconds = activity_backlog_seconds
        self._accepted_samples = 0
        self._accepting_audio = True
        self._events: deque[SessionEvent | None] = deque()
        self._events_changed = asyncio.Condition()
        self._pump: asyncio.Task[None] | None = None
        self._sequence = 0
        self._done: dict[str, SessionDone] = {}
        self._closed = False
        self._degraded_reason: str | None = None
        self._discard_attribution_updates = False
        self._activity_terminated = False

    @property
    def accepted_samples(self) -> int:
        return self._accepted_samples

    async def start(self) -> None:
        if self._pump is None:
            self._pump = asyncio.create_task(self._pump_activity())

    async def append(self, pcm16: bytes) -> None:
        if not self._accepting_audio:
            raise ValueError("diarization session no longer accepts audio")
        if len(pcm16) % 2:
            raise ValueError("PCM16 input must contain whole samples")
        await self.start()
        start_sample = self._accepted_samples
        samples = len(pcm16) // 2
        if self._activity_terminated:
            self._accepted_samples += samples
            return
        try:
            await asyncio.wait_for(
                self._activity.append(start_sample=start_sample, pcm16=pcm16),
                timeout=self._activity_backlog_seconds,
            )
        except TimeoutError:
            self._accepted_samples += samples
            self._activity_terminated = True
            await self._degrade("diarization_backlog_exceeded")
            await self._activity.cancel()
        else:
            self._accepted_samples += samples

    async def register_completed(self, item_id: str, units: tuple[TextUnit, ...]) -> None:
        if len(units) > 4096:
            raise ValueError("diarization unit limit exceeded")
        spans = [unit.audio_span for unit in units if unit.audio_span is not None]
        if spans and (
            max(span.end for span in spans) - min(span.start for span in spans) > 30 * 16_000
        ):
            raise ValueError("diarization pending window exceeded")
        attributions = self._ledger.register(item_id, units)
        if attributions:
            await self._emit(ItemAttributionUpdated(item_id, attributions, self._next_sequence()))

    async def finish(self, event_id: str) -> SessionDone:
        if not event_id:
            raise ValueError("finish requires an event id")
        if existing := self._done.get(event_id):
            return existing
        if self._done:
            raise ValueError("diarization session has already been finished")
        self._accepting_audio = False
        await self.start()
        status = "complete"
        try:
            if not self._activity_terminated:
                await self._activity.finish(through_sample=self._accepted_samples)
            if self._pump is not None:
                await asyncio.wait_for(self._pump, timeout=self._drain_timeout_seconds)
        except (TimeoutError, ValueError, RuntimeError) as exc:
            status = "degraded"
            await self._degrade(str(exc) or "diarization_failure")
            await self._activity.cancel()
        if self._degraded_reason is not None:
            status = "degraded"
        reason = "finalization_incomplete" if status == "degraded" else "finalized"
        final = self._ledger.terminate_pending(reason)
        if final:
            await self._emit(ItemAttributionUpdated("", final, self._next_sequence()))
        done = SessionDone(event_id=event_id, status=status, last_sequence=self._sequence)
        self._done[event_id] = done
        await self._emit(done)
        await self._close_events()
        return done

    async def cancel(self) -> None:
        if self._closed:
            return
        self._accepting_audio = False
        if self._pump is not None and not self._pump.done():
            self._pump.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._pump
        await self._activity.cancel()
        self._activity_terminated = True
        await self._close_events()

    async def events(self) -> AsyncIterator[SessionEvent]:
        while True:
            async with self._events_changed:
                await self._events_changed.wait_for(lambda: bool(self._events))
                event = self._events.popleft()
            if event is None:
                return
            yield event

    async def _pump_activity(self) -> None:
        try:
            async for update in self._activity.updates():
                changed = self._ledger.apply(update)
                if changed:
                    await self._emit(ItemAttributionUpdated("", changed, self._next_sequence()))
        except (ValueError, RuntimeError) as exc:
            del exc
            await self._degrade("diarization_invalid_output")

    async def _degrade(self, reason: str) -> None:
        if self._degraded_reason is not None:
            return
        self._degraded_reason = reason
        final = self._ledger.terminate_pending(reason)
        if final:
            await self._emit(ItemAttributionUpdated("", final, self._next_sequence()))
        await self._emit(StatusChanged("degraded", reason, self._next_sequence()))

    def _next_sequence(self) -> int:
        self._sequence += 1
        return self._sequence

    async def _emit(self, event: SessionEvent) -> None:
        async with self._events_changed:
            if isinstance(event, ItemAttributionUpdated):
                self._append_or_coalesce_update(event)
            else:
                self._events.append(event)
            self._events_changed.notify()

    async def _close_events(self) -> None:
        if not self._closed:
            self._closed = True
            async with self._events_changed:
                self._events.append(None)
                self._events_changed.notify()

    def _append_or_coalesce_update(self, event: ItemAttributionUpdated) -> None:
        """Keep every revision or fail closed when the pending queue is full.

        Sona and the persistence layer require per-unit revisions to arrive
        strictly consecutively.  Replacing a queued revision with a newer
        snapshot would therefore turn ``1, 2, 3`` into ``1, 3`` for a slow
        consumer.  Once the bounded queue is exhausted, discard pending
        attribution updates and publish one degraded status instead of emitting
        a protocol-invalid revision sequence.
        """

        if self._discard_attribution_updates:
            return

        pending_updates = sum(
            isinstance(queued, ItemAttributionUpdated) for queued in self._events
        )
        if pending_updates < self._max_pending_update_events:
            self._events.append(event)
            return

        self._mark_update_backlog_exceeded()

    def _mark_update_backlog_exceeded(self) -> None:
        reason = "diarization_event_backlog_exceeded"
        if self._degraded_reason is not None:
            return
        self._degraded_reason = reason
        self._discard_attribution_updates = True
        self._events = deque(
            queued
            for queued in self._events
            if not isinstance(queued, ItemAttributionUpdated)
        )
        if not any(isinstance(queued, StatusChanged) for queued in self._events):
            self._events.append(StatusChanged("degraded", reason, self._next_sequence()))
