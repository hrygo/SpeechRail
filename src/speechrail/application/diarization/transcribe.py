"""Transport-neutral batch projection for the continuous diarization actor."""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import Callable

from speechrail.application.diarization.session import DiarizationSession, SessionEvent
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.diarization.attribution import AttributionLedger
from speechrail.domain.diarization.ports import AlignTextPort, StreamingActivityPort
from speechrail.domain.diarization.types import (
    AlignmentRequest,
    Attribution,
    DiarizationError,
    Span,
    TextUnit,
)


async def diarize_transcript(
    *,
    activity_port: StreamingActivityPort,
    aligner: AlignTextPort,
    audio: bytes,
    result: TranscriptResult,
    epoch: str,
    new_unit_id: Callable[[int], str],
) -> TranscriptResult:
    """Attach anonymous labels through the same actor used by Realtime.

    The ASR result is immutable before this function runs. Its units come from
    direct fixed-text alignment, never a second ASR decode or ASR timestamps.
    """

    # Legal silent audio has no fixed text to attribute.  It succeeds as an
    # empty OpenAI transcript and must not allocate either an aligner request
    # or a continuous CoreML session.
    if not result.text:
        return result.model_copy(update={"segments": ()})

    holder: dict[str, DiarizationSession] = {}
    ledger = AttributionLedger(accepted_samples=lambda: holder["session"].accepted_samples)
    session = DiarizationSession(activity=activity_port.open(epoch=epoch), ledger=ledger)
    holder["session"] = session
    events: list[SessionEvent] = []

    async def consume() -> None:
        async for event in session.events():
            events.append(event)

    consumer = asyncio.create_task(consume())
    try:
        await session.append(audio)
        alignment = await aligner.align(
            AlignmentRequest(
                epoch=epoch,
                item_id="batch",
                pcm16=audio,
                span=Span(0, len(audio) // 2),
                text=result.text,
                language=result.language or None,
            )
        )
        if alignment.failure is not None:
            raise DiarizationError(
                "fixed-text alignment failed", code="diarization_unresolved"
            )
        units = tuple(
            TextUnit(new_unit_id(index), unit.text_start, unit.text_end, unit.audio_span)
            for index, unit in enumerate(alignment.units)
        )
        await session.register_completed("batch", units)
        await session.finish("batch-finish")
        await consumer
    except BaseException:
        await session.cancel()
        consumer.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await consumer
        raise

    labels = _latest_labels(events)
    by_unit = {unit.id: labels.get(unit.id) for unit in units}
    segments = tuple(
        TranscriptSegment(
            id=index,
            start_ms=unit.audio_span.start // 16 if unit.audio_span is not None else 0,
            end_ms=unit.audio_span.end // 16 if unit.audio_span is not None else 0,
            text=result.text[unit.text_start : unit.text_end],
            speaker=by_unit.get(unit.id),
        )
        for index, unit in enumerate(units)
    )
    return result.model_copy(update={"segments": segments})


def _latest_labels(events: list[SessionEvent]) -> dict[str, str | None]:
    labels: dict[str, Attribution] = {}
    for event in events:
        attributions = getattr(event, "attributions", ())
        for attribution in attributions:
            labels[attribution.unit_id] = attribution
    return {unit_id: attribution.speaker for unit_id, attribution in labels.items()}
