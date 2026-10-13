"""Frozen-text alignment and anonymous attribution ownership."""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import Awaitable, Callable, Mapping
from contextlib import AsyncExitStack
from dataclasses import dataclass
from typing import Any, Protocol, cast
from uuid import uuid4

from speechrail.application.diarization import (
    DiarizationSession,
    ItemAttributionUpdated,
    SessionDone,
    StatusChanged,
)
from speechrail.application.realtime_state import AsrIdentity, FrozenTranscript
from speechrail.compatibility.openai_realtime import (
    ASR_KERNEL_SAMPLE_RATE,
    WIRE_SAMPLE_RATE,
    RealtimeAdapterError,
    alignment_done,
    alignment_failed,
    diarization_done_event,
    diarization_failed,
    diarization_updated,
    parse_finish_request,
)
from speechrail.config import Settings
from speechrail.domain.alignment import AlignmentGranularity, AlignmentRequest, AlignTextPort
from speechrail.domain.audio_timeline import (
    RateMap,
    SampleSpan,
)
from speechrail.domain.diarization import (
    Attribution,
    DiarizationError,
    TextUnit,
)
from speechrail.domain.diarization.attribution import AttributionLedger
from speechrail.domain.diarization.timeline import AttributionUnit
from speechrail.domain.ports import (
    DiarizationEngine,
)
from speechrail.observability.metrics import Metrics
from speechrail.runtime.alignment_admission import AlignmentAdmission, AlignmentAdmissionFullError
from speechrail.runtime.diarization_admission import (
    DiarizationAdmission,
    DiarizationAdmissionFullError,
)

logger = logging.getLogger(__name__)

_MAX_UPDATES_PER_EVENT = 256


class AsrFinalSource(Protocol):
    @property
    def identity(self) -> AsrIdentity: ...
    async def wait_finals(self) -> None: ...


class AuxiliaryIngress(Protocol):
    @property
    def alignment_enabled(self) -> bool: ...
    @property
    def diarization_enabled(self) -> bool: ...
    @property
    def diarization_active(self) -> bool: ...
    @property
    def phase(self) -> str: ...
    @property
    def degraded_reason(self) -> str | None: ...
    async def ensure_diarization(self) -> None: ...
    async def append(self, pcm16: bytes) -> None: ...
    async def cancel_alignment_tasks(self) -> None: ...
    async def reset(self) -> None: ...
    def start_alignment(self, result: FrozenTranscript) -> None: ...


@dataclass(frozen=True, slots=True)
class RealtimeAuxiliaryPorts:
    aligner: AlignTextPort | None
    engine: DiarizationEngine | None
    alignment_admission: AlignmentAdmission
    diarization_admission: DiarizationAdmission
    metrics: Metrics
    ready: Callable[[], bool]
    status_message: Callable[[], str]


class RealtimeAuxiliaryOwner:
    """Own alignment and attribution; canonical text arrives as a frozen value."""

    def __init__(
        self,
        *,
        ports: RealtimeAuxiliaryPorts,
        settings: Settings,
        session_id: str,
        task_id: str,
        send: Callable[[dict[str, object]], Awaitable[int | None]],
        config: Callable[[], Mapping[str, Any]],
        input_source: AsrFinalSource,
    ) -> None:
        self._ports = ports
        self._settings = settings
        self._session_id = session_id
        self._task_id = task_id
        self._send = send
        self._config_snapshot = config
        self._input = input_source
        self._diarization_engine = ports.engine
        self._metadata_revision = 0
        self._diarization: DiarizationSession | None = None
        self._diarization_events: asyncio.Task[None] | None = None
        self._diarization_resources: AsyncExitStack | None = None
        self._diarization_epoch: str | None = None

        self._alignment_tasks: set[asyncio.Task[None]] = set()
        self._alignment_enabled = False
        self._diarization_enabled = False

        self._ledger: AttributionLedger | None = None
        self._diarization_phase = "active"
        self._degraded_reason: str | None = None
        self._status_sent = False
        self._finalization_id: str | None = None
        self._finalized_payload: dict[str, object] | None = None
        self._last_update_sequence = 0
        self._units_by_id: dict[str, AttributionUnit] = {}
        self._wire_span_by_unit: dict[str, SampleSpan] = {}
        self._speaker_by_unit: dict[str, str | None] = {}

    @property
    def _config(self) -> Mapping[str, Any]:
        return self._config_snapshot()

    @property
    def alignment_enabled(self) -> bool:
        return self._alignment_enabled

    @property
    def diarization_enabled(self) -> bool:
        return self._diarization_enabled

    @property
    def diarization_active(self) -> bool:
        return self._diarization is not None

    @property
    def phase(self) -> str:
        return self._diarization_phase

    @property
    def degraded_reason(self) -> str | None:
        return self._degraded_reason

    async def configure(self, *, alignment: bool, diarization: bool) -> None:
        previous = self._diarization_enabled
        self._diarization_enabled = diarization
        if diarization:
            try:
                await self._ensure_diarization()
            except BaseException:
                await self._close_diarization()
                self._diarization_enabled = previous
                raise
        else:
            await self._close_diarization()
        self._alignment_enabled = alignment

    async def append(self, pcm16: bytes) -> None:
        if self._diarization is not None:
            await self._diarization.append(pcm16)

    async def ensure_diarization(self) -> None:
        await self._ensure_diarization()

    async def cancel_alignment_tasks(self) -> None:
        await self._cancel_alignment_tasks()

    async def reset(self) -> None:
        await self._close_diarization()
        self._units_by_id.clear()
        self._wire_span_by_unit.clear()
        self._speaker_by_unit.clear()

    async def close(self) -> None:
        await self._cancel_alignment_tasks()
        await self._close_diarization()

    def start_alignment(self, result: FrozenTranscript) -> None:
        task = asyncio.create_task(
            self._finish_alignment(
                task_id=result.task_id,
                epoch=result.epoch,
                generation=result.generation,
                item_id=result.item_id,
                transcript=result.transcript,
                transcript_revision=result.transcript_revision,
                item_start_wire=result.item_start_wire,
                item_end_wire=result.item_end_wire,
                item_start_kernel=result.item_start_kernel,
                item_end_kernel=result.item_end_kernel,
                pcm16=result.pcm16,
                overflow=result.overflow,
                degraded_reason=result.degraded_reason,
            )
        )
        self._alignment_tasks.add(task)
        task.add_done_callback(self._alignment_tasks.discard)

    def _alignment_granularity(self) -> AlignmentGranularity:
        """Return the requested alignment granularity, defaulting to segments.

        The wire field is a list; the finest requested granularity wins, and an
        empty or unknown request degrades to segment-level units.
        """

        declared = self._config.get("alignment_granularity")
        if declared in {"character", "word", "segment"}:
            return cast(AlignmentGranularity, declared)
        requested = self._config.get("timestamp_granularities")
        if isinstance(requested, (list, tuple)) and "character" in requested:
            return "character"
        if isinstance(requested, (list, tuple)) and "word" in requested:
            return "word"
        return "segment"

    async def _cancel_alignment_tasks(self) -> None:
        """Cancel auxiliary work before releasing the session's model owner."""

        tasks = tuple(self._alignment_tasks)
        for task in tasks:
            if not task.done():
                task.cancel()
        for task in tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await task
        self._alignment_tasks.clear()

    async def _finish_alignment(
        self,
        *,
        task_id: str,
        epoch: int,
        generation: int,
        item_id: str,
        transcript: str,
        transcript_revision: int,
        item_start_wire: int,
        item_end_wire: int,
        item_start_kernel: int,
        item_end_kernel: int,
        pcm16: bytes,
        overflow: bool,
        degraded_reason: str | None,
    ) -> None:
        try:
            # Only a connection-level change invalidates the result outright: a
            # reconnect or a new task means there is nobody left to deliver to.
            #
            # Turn-level identity must NOT suppress delivery.  The event carries
            # `utterance_id` and `transcript_revision` itself, and the contract
            # already tells clients to drop stale revisions, so a result that
            # lands after the next turn started is still correctly attributable.
            # Worse, the turn state it would be compared against is gone by then:
            # commit cleanup calls `_reset_turn_observability`, which zeroes
            # `_current_transcript_revision`, so that comparison was false for
            # *every* result and alignment silently produced nothing at all.
            if (
                task_id != self._task_id
                or epoch != self._input.identity.epoch
                or generation != self._input.identity.generation
            ):
                self._ports.metrics.record_alignment_event("fixed_text_stale")
                # Still terminal: a client that enabled alignment must never
                # wait forever for an event that cannot arrive.
                await self._send(
                    alignment_failed(
                        task_id=task_id,
                        epoch=epoch,
                        utterance_id=item_id,
                        transcript_revision=transcript_revision,
                        metadata_revision=self._metadata_revision,
                        code="alignment_stale",
                        message="connection changed before alignment completed",
                    )
                )
                return
            units, failure = await self._build_alignment_units(
                item_id=item_id,
                transcript=transcript,
                transcript_revision=transcript_revision,
                item_start=item_start_kernel,
                item_end=item_end_kernel,
                pcm16=pcm16,
                overflow=overflow,
                degraded_reason=degraded_reason,
            )
            if (
                task_id != self._task_id
                or epoch != self._input.identity.epoch
                or generation != self._input.identity.generation
            ):
                return
            aligned = bool(units) and all(unit.timing_quality == "aligned" for unit in units)
            wire_spans = self._alignment_wire_spans(
                units,
                kernel_span=SampleSpan(item_start_kernel, item_end_kernel),
                wire_span=SampleSpan(item_start_wire, item_end_wire),
            )
            if not transcript or aligned:
                self._ports.metrics.record_alignment_event("fixed_text_completed")
                await self._send(
                    alignment_done(
                        task_id=task_id,
                        epoch=epoch,
                        utterance_id=item_id,
                        transcript_revision=transcript_revision,
                        metadata_revision=self._metadata_revision,
                        sample_span=(item_start_wire, item_end_wire),
                        codepoint_span=(0, len(transcript)),
                        units=self._render_units(units, wire_spans),
                    )
                )
            else:
                self._ports.metrics.record_alignment_event("fixed_text_unavailable")
                await self._send(
                    alignment_failed(
                        task_id=task_id,
                        epoch=epoch,
                        utterance_id=item_id,
                        transcript_revision=transcript_revision,
                        metadata_revision=self._metadata_revision,
                        code=failure or "alignment_unavailable",
                        message="fixed-text alignment failed",
                    )
                )
            # The connection ledger owns completed items, including those whose
            # final or alignment arrives after the next item has begun.
            if units:
                self._metadata_revision += 1
                if self._diarization is not None:
                    self._wire_span_by_unit.update(wire_spans)
                await self._register_units(item_id, units)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("realtime alignment task failed")
            with contextlib.suppress(Exception):
                await self._send(
                    alignment_failed(
                        task_id=task_id,
                        epoch=epoch,
                        utterance_id=item_id,
                        transcript_revision=transcript_revision,
                        metadata_revision=self._metadata_revision,
                        code="alignment_failed",
                        message="fixed-text alignment failed",
                    )
                )

    async def _build_alignment_units(
        self,
        *,
        item_id: str,
        transcript: str,
        transcript_revision: int,
        item_start: int,
        item_end: int,
        pcm16: bytes,
        overflow: bool,
        degraded_reason: str | None,
    ) -> tuple[tuple[AttributionUnit, ...], str | None]:
        """Align frozen text without ever replacing the ASR final."""

        if not transcript:
            return (), None

        def unavailable(reason: str) -> tuple[tuple[AttributionUnit, ...], str]:
            return (
                (self._unavailable_unit(transcript, item_start, item_end),),
                reason,
            )

        if degraded_reason is not None:
            return unavailable(degraded_reason)
        aligner = self._ports.aligner
        item_samples = item_end - item_start
        if overflow:
            # The retained pin is bounded; overflow fails loudly instead of
            # aligning a truncated span and pretending the timestamps are exact.
            return unavailable("alignment_pcm_overflow")
        if aligner is None or len(pcm16) // 2 != item_samples:
            return unavailable("alignment_unavailable")
        alignment_epoch = (
            self._diarization_epoch or f"{self._session_id}:{self._input.identity.epoch}"
        )
        try:
            async with self._ports.alignment_admission.reserve():
                async with asyncio.timeout(self._settings.request_timeout_seconds):
                    result = await aligner.align(
                        AlignmentRequest(
                            task_id=self._task_id,
                            epoch=alignment_epoch,
                            utterance_id=item_id,
                            transcript_revision=transcript_revision,
                            pcm16=pcm16,
                            span=SampleSpan(item_start, item_end),
                            text=transcript,
                            language=self._config.get("language"),
                            granularity=self._alignment_granularity(),
                        )
                    )
        except AlignmentAdmissionFullError:
            self._ports.metrics.record_alignment_event("fixed_text_overflow")
            return unavailable("alignment_overloaded")
        except TimeoutError:
            return unavailable("alignment_timeout")
        if result.failure is not None:
            return unavailable(result.failure)
        return (
            tuple(
                AttributionUnit(
                    segment_uid=f"seg_{uuid4().hex[:12]}",
                    text_start=unit.text_start,
                    text_end=unit.text_end,
                    start_sample=(
                        unit.audio_span.start if unit.audio_span is not None else item_start
                    ),
                    end_sample=(unit.audio_span.end if unit.audio_span is not None else item_end),
                    timing_quality="aligned",
                    granularity=unit.granularity,
                )
                for unit in result.units
            ),
            None,
        )

    def _unavailable_unit(self, canonical: str, item_start: int, item_end: int) -> AttributionUnit:
        return AttributionUnit(
            segment_uid=f"seg_{uuid4().hex[:12]}",
            text_start=0,
            text_end=len(canonical),
            start_sample=item_start,
            end_sample=item_end,
            timing_quality="unavailable",
            granularity=self._alignment_granularity(),
        )

    def _alignment_wire_spans(
        self,
        units: tuple[AttributionUnit, ...],
        *,
        kernel_span: SampleSpan,
        wire_span: SampleSpan,
    ) -> dict[str, SampleSpan]:
        # A flushed 24->16 kHz tail can round up. Each frozen item's exact
        # wire endpoints, rather than a global inverse rate map, own its units.
        rate_map = RateMap(
            source_rate=ASR_KERNEL_SAMPLE_RATE,
            target_rate=WIRE_SAMPLE_RATE,
            origin_source=kernel_span.start,
            origin_target=wire_span.start,
        )

        def endpoint(sample: int) -> int:
            if sample <= kernel_span.start:
                return wire_span.start
            if sample >= kernel_span.end:
                return wire_span.end
            return min(wire_span.end, max(wire_span.start, rate_map.to_target(sample)))

        return {
            unit.segment_uid: SampleSpan(endpoint(unit.start_sample), endpoint(unit.end_sample))
            for unit in units
        }

    def _render_units(
        self,
        units: tuple[AttributionUnit, ...],
        wire_spans: dict[str, SampleSpan],
    ) -> list[dict[str, object]]:
        rendered: list[dict[str, object]] = []
        for unit in units:
            wire_span = wire_spans[unit.segment_uid]
            rendered.append(
                {
                    "segment_uid": unit.segment_uid,
                    "text_start": unit.text_start,
                    "text_end": unit.text_end,
                    "audio_start_sample": wire_span.start,
                    "audio_end_sample": wire_span.end,
                    "timing_quality": unit.timing_quality,
                    "granularity": unit.granularity,
                }
            )
        return rendered

    async def _register_units(self, item_id: str, units: tuple[AttributionUnit, ...]) -> None:
        """Register immutable text units; actor events carry only speaker revisions."""
        if self._diarization is None or not units:
            return
        for unit in units:
            self._units_by_id[unit.segment_uid] = unit
            self._speaker_by_unit.setdefault(unit.segment_uid, None)
        try:
            await self._diarization.register_completed(
                item_id,
                tuple(
                    TextUnit(
                        id=unit.segment_uid,
                        text_start=unit.text_start,
                        text_end=unit.text_end,
                        audio_span=(
                            None
                            if unit.timing_quality == "unavailable"
                            else SampleSpan(unit.start_sample, unit.end_sample)
                        ),
                    )
                    for unit in units
                ),
            )
        except DiarizationError as exc:
            await self._handle_degradation(exc)
        except ValueError as exc:
            await self._handle_degradation(
                DiarizationError(str(exc), code="diarization_invalid_output")
            )

    def _diarization_units_payload(self) -> list[dict[str, object]]:
        """Project immutable unit spans onto the 24 kHz public sample axis."""

        payload: list[dict[str, object]] = []
        for unit in sorted(
            self._units_by_id.values(), key=lambda item: (item.start_sample, item.segment_uid)
        ):
            wire_span = self._wire_span_by_unit[unit.segment_uid]
            payload.append(
                {
                    "speaker": self._speaker_by_unit.get(unit.segment_uid),
                    "sample_span": {"start": wire_span.start, "end": wire_span.end},
                }
            )
        return payload

    async def _send_diarization_updates(self, attributions: tuple[Attribution, ...]) -> None:
        """Project domain speaker revisions into the current extension DTO."""
        if self._ledger is None or not attributions:
            return
        for attribution in attributions:
            if attribution.unit_id in self._units_by_id:
                self._speaker_by_unit[attribution.unit_id] = attribution.speaker
        units = self._diarization_units_payload()
        if not units:
            return
        self._metadata_revision += 1
        for start in range(0, len(units), _MAX_UPDATES_PER_EVENT):
            chunk = units[start : start + _MAX_UPDATES_PER_EVENT]
            sequence = await self._send(
                diarization_updated(
                    task_id=self._task_id,
                    epoch=self._input.identity.epoch,
                    utterance_id=self._input.identity.item_id,
                    transcript_revision=self._input.identity.transcript_revision,
                    metadata_revision=self._metadata_revision,
                    units=chunk,
                )
            )
            if sequence is not None:
                self._last_update_sequence = sequence

    def _mark_degraded(self, reason: str) -> None:
        if self._degraded_reason is None:
            self._degraded_reason = reason

    async def _handle_degradation(self, exc: DiarizationError) -> None:
        """First-wins transport projection for an actor degradation."""
        reason = (
            exc.code
            if exc.code in {"diarization_overloaded", "diarization_invalid_output"}
            else "diarization_invalid_output"
        )
        self._mark_degraded(reason)
        if not self._status_sent:
            self._status_sent = True
            await self._send(
                diarization_failed(
                    task_id=self._task_id,
                    epoch=self._input.identity.epoch,
                    utterance_id=self._input.identity.item_id,
                    transcript_revision=self._input.identity.transcript_revision,
                    metadata_revision=self._metadata_revision,
                    code=reason,
                    message="streaming diarization failed",
                )
            )

    async def finish(self, event: dict[str, Any]) -> None:
        if self._ledger is None:
            raise RealtimeAdapterError(
                "unsupported_operation",
                "diarization is not enabled on this session",
            )
        finalization_id = parse_finish_request(event)
        if self._diarization_phase == "finalized":
            if self._finalization_id != finalization_id or self._finalized_payload is None:
                raise RealtimeAdapterError(
                    "invalid_state",
                    "session already finalized with a different finalization_id",
                )
            await self._send(dict(self._finalized_payload))
            return
        if self._diarization_phase == "draining":
            if self._finalization_id != finalization_id:
                raise RealtimeAdapterError(
                    "invalid_state", "another finalization is already in progress"
                )
            return
        self._finalization_id = finalization_id
        self._diarization_phase = "draining"
        await self._drain_and_finalize()

    async def _drain_and_finalize(self) -> None:
        """Close the append barrier only after frozen text has registered."""
        deadline = self._settings.realtime_diarization_drain_deadline_seconds
        assert self._finalization_id is not None
        done: SessionDone | None = None
        try:
            async with asyncio.timeout(deadline):
                await self._input.wait_finals()
                await self._wait_for_pending_alignment()
                if self._diarization is not None:
                    done = await self._diarization.finish(self._finalization_id)
        except TimeoutError:
            self._mark_degraded("finalization_timeout")
            if not self._status_sent:
                self._status_sent = True
                await self._send(
                    diarization_failed(
                        task_id=self._task_id,
                        epoch=self._input.identity.epoch,
                        utterance_id=self._input.identity.item_id,
                        transcript_revision=self._input.identity.transcript_revision,
                        metadata_revision=self._metadata_revision,
                        code="finalization_timeout",
                        message="streaming diarization finalization timed out",
                    )
                )
        if done is not None and done.status == "degraded" and self._degraded_reason is None:
            self._mark_degraded("finalization_incomplete")
        if self._degraded_reason is None:
            payload = diarization_done_event(
                task_id=self._task_id,
                epoch=self._input.identity.epoch,
                utterance_id=self._input.identity.item_id,
                transcript_revision=self._input.identity.transcript_revision,
                metadata_revision=self._metadata_revision,
                units=self._diarization_units_payload(),
            )
        else:
            payload = diarization_failed(
                task_id=self._task_id,
                epoch=self._input.identity.epoch,
                utterance_id=self._input.identity.item_id,
                transcript_revision=self._input.identity.transcript_revision,
                metadata_revision=self._metadata_revision,
                code=self._degraded_reason,
                message="streaming diarization finalization did not complete",
            )
        self._finalized_payload = payload
        self._diarization_phase = "finalized"
        await self._send(payload)

    async def _wait_for_pending_alignment(self) -> None:
        """Drain every frozen-text alignment task before closing the ledger."""
        while True:
            tasks = tuple(self._alignment_tasks)
            if not tasks:
                return
            await asyncio.gather(*tasks)
            # gather may return synchronously for already completed tasks.
            # Do not rely on scheduled discard callbacks to drain the set.
            self._alignment_tasks.difference_update(tasks)

    async def _ensure_diarization(self) -> None:
        if self._diarization is not None:
            return
        if not self._diarization_enabled:
            return
        engine = self._diarization_engine
        if not self._ports.ready() or engine is None:
            raise RealtimeAdapterError(
                "diarization_not_available",
                self._ports.status_message(),
            )
        await self._reserve_diarization()
        try:
            holder: dict[str, DiarizationSession] = {}
            epoch = f"rt-{uuid4().hex}"
            self._ledger = AttributionLedger(
                accepted_samples=lambda: holder["session"].accepted_samples
            )
            self._diarization = DiarizationSession(
                activity=engine.open(epoch=epoch), ledger=self._ledger
            )
            self._diarization_epoch = epoch
            holder["session"] = self._diarization
            await self._diarization.start()
            self._diarization_events = asyncio.create_task(self._consume_diarization_events())
        except BaseException:
            await self._release_diarization()
            raise

    async def _close_diarization(self) -> None:
        if self._diarization is not None:
            with contextlib.suppress(Exception):
                await self._diarization.cancel()
            self._diarization = None
        if self._diarization_events is not None:
            self._diarization_events.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._diarization_events
            self._diarization_events = None
        self._ledger = None
        self._diarization_epoch = None
        await self._release_diarization()

    async def _reserve_diarization(self) -> None:
        self._diarization_resources = AsyncExitStack()
        try:
            await self._diarization_resources.enter_async_context(
                self._ports.diarization_admission.reserve()
            )
        except DiarizationAdmissionFullError as exc:
            await self._diarization_resources.aclose()
            self._diarization_resources = None
            raise RealtimeAdapterError(
                "backend_busy",
                "another diarization session is active",
                busy_reason=str(exc.busy_reason),
            ) from exc

    async def _release_diarization(self) -> None:
        if self._diarization_resources is not None:
            await self._diarization_resources.aclose()
            self._diarization_resources = None

    async def _consume_diarization_events(self) -> None:
        """Project actor output without allowing transport code into its state."""

        assert self._diarization is not None
        async for event in self._diarization.events():
            if isinstance(event, ItemAttributionUpdated):
                await self._send_diarization_updates(event.attributions)
            elif isinstance(event, StatusChanged):
                await self._handle_degradation(
                    DiarizationError(
                        "streaming diarization degraded",
                        code=event.reason,
                    )
                )
