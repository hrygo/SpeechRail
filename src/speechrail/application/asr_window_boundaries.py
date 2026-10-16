"""Word-evidence cropping with one bounded, prefix-free owned-only fallback."""

from __future__ import annotations

import asyncio
from collections.abc import Sequence
from typing import Literal
from uuid import uuid4

from speechrail.domain.alignment import AlignmentRequest, AlignmentUnit, AlignTextPort
from speechrail.domain.asr_window import WindowDecodeRequest, WindowDecodeResult
from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.ports import WindowAsrSession
from speechrail.observability.metrics import Metrics
from speechrail.runtime.alignment_admission import AlignmentAdmission
from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass


class BoundaryEvidenceError(ValueError):
    pass


def crop_owned_text(text: str, units: Sequence[AlignmentUnit], owned: SampleSpan) -> str:
    if not text:
        return ""
    if not units or any(u.granularity != "word" or u.audio_span is None for u in units):
        raise BoundaryEvidenceError("word_alignment_unavailable")
    cursor = 0
    for unit in units:
        if (
            unit.text_start < cursor
            or unit.text_end > len(text)
            or any(ch.isalnum() for ch in text[cursor : unit.text_start])
        ):
            raise BoundaryEvidenceError("alignment_text_coverage")
        cursor = unit.text_end
    if any(ch.isalnum() for ch in text[cursor:]):
        raise BoundaryEvidenceError("alignment_text_coverage")
    spans = [u.audio_span for u in units]
    if len(units) > 1 and len(set(spans)) == 1:
        raise BoundaryEvidenceError("alignment_timestamp_grid")
    chosen = []
    for unit in units:
        span = unit.audio_span
        assert span is not None
        if span.length == 0:
            raise BoundaryEvidenceError("alignment_timestamp_grid")
        if span.start < owned.end and span.end > owned.start:
            if span.start < owned.start or span.end > owned.end:
                raise BoundaryEvidenceError("word_crosses_owned_boundary")
            chosen.append(unit)
    if not chosen:
        raise BoundaryEvidenceError("owned_words_missing")
    start, end = chosen[0].text_start, chosen[-1].text_end
    while start and not text[start - 1].isalnum() and not text[start - 1].isspace():
        start -= 1
    while end < len(text) and not text[end].isalnum() and not text[end].isspace():
        end += 1
    return text[start:end].strip()


class WindowBoundaryReview:
    def __init__(
        self,
        *,
        decoder: WindowAsrSession,
        aligner: AlignTextPort,
        admission: AlignmentAdmission,
        governor: ResourceGovernor,
        metrics: Metrics | None = None,
    ) -> None:
        self.decoder, self.aligner = decoder, aligner
        self.admission, self.governor = admission, governor
        self.metrics = metrics

    async def __call__(
        self,
        request: WindowDecodeRequest,
        result: WindowDecodeResult,
        owned: SampleSpan,
        deadline: float,
    ) -> tuple[str, Literal["contextual", "owned_only"]]:
        if not result.text:
            return "", "contextual"
        if request.input_span == owned:
            return result.text, "owned_only"
        try:
            async with (
                self.admission.reserve(),
                self.governor.reserve(
                    WorkClass.REALTIME_ASR,
                    deadline=max(0.001, deadline - asyncio.get_running_loop().time()),
                ),
            ):
                aligned = await self.aligner.align(
                    AlignmentRequest(
                        task_id=request.identity.session_id,
                        epoch=str(request.identity.input_epoch),
                        utterance_id=request.attempt_id,
                        transcript_revision=1,
                        pcm16=request.pcm16,
                        span=request.input_span,
                        text=result.text,
                        language=result.language,
                        granularity="word",
                    )
                )
            if aligned.failure is not None:
                raise BoundaryEvidenceError(aligned.failure)
            return crop_owned_text(result.text, aligned.units, owned), "contextual"
        except (RuntimeError, ValueError) as exc:
            if self.metrics is not None:
                self.metrics.record_asr_window_fallback(
                    str(exc) if isinstance(exc, BoundaryEvidenceError) else "alignment_unavailable"
                )
            # Exactly one retry. It shares the original deadline and copy reservation.
            begin = (owned.start - request.input_span.start) * 2
            retry = WindowDecodeRequest(
                request.identity,
                "attempt_" + uuid4().hex,
                "review",
                owned,
                request.pcm16[begin : begin + owned.length * 2],
                request.language,
                request.context,
            )
            result = await self.decoder.decode(retry)
            if (
                result.identity != retry.identity
                or result.attempt_id != retry.attempt_id
                or result.input_span != owned
                or not result.complete
            ):
                raise BoundaryEvidenceError("owned_only_incomplete") from None
            return result.text, "owned_only"
