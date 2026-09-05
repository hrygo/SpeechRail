"""Application service for attaching anonymous diarization to transcript segments."""

from __future__ import annotations

from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import (
    ActivitySnapshot,
    DiarizationError,
    DiarizationUpdate,
)
from speechrail.domain.diarization_timeline import Timeline
from speechrail.domain.ports import ContinuousDiarizationSession, DiarizationSession


class DiarizationCoordinator:
    """Keep model-specific session state behind a narrow, validated boundary.

    Two modes exist:

    - legacy batch-at-commit: one ``DiarizationSession`` consumes accumulated
      PCM and is annotated when an ASR commit delivers segments;
    - continuous (SPK-E2E-1): one ``ContinuousDiarizationSession`` spans the
      whole WebSocket session; ASR commits end items, never this state, and
      the coordinator owns the session-global sample clock so every accepted
      sample advances it exactly once.
    """

    def __init__(
        self,
        session: DiarizationSession | None = None,
        *,
        continuous: ContinuousDiarizationSession | None = None,
    ) -> None:
        if (session is None) == (continuous is None):
            raise ValueError("exactly one of session or continuous is required")
        self._session = session
        self._continuous = continuous
        self._timeline = Timeline()
        self._closed = False

    @property
    def is_continuous(self) -> bool:
        return self._continuous is not None

    async def append_audio(self, audio: bytes) -> None:
        if self._closed:
            raise DiarizationError("diarization session is closed", code="invalid_audio")
        if self._continuous is not None:
            start, _end = self._timeline.accept(audio)
            await self._continuous.append(audio, start)
            return
        assert self._session is not None
        await self._session.append_audio(audio)

    async def activities(self, through_sample: int | None = None) -> ActivitySnapshot | None:
        """Return the streaming activity snapshot (continuous mode only)."""
        if self._continuous is None:
            return None
        through = (
            self._timeline.accepted_samples if through_sample is None else through_sample
        )
        return await self._continuous.activities(through)

    async def annotate(
        self, segments: tuple[TranscriptSegment, ...]
    ) -> tuple[TranscriptSegment, ...]:
        if self._continuous is not None:
            raise DiarizationError(
                "continuous diarization assigns attribution through activity snapshots",
                code="diarization_error",
            )
        assert self._session is not None
        if not segments:
            return segments
        update = await self._session.annotate(segments)
        assignments = {assignment.segment_id: assignment for assignment in update.assignments}
        unknown_ids = assignments.keys() - {segment.id for segment in segments}
        if unknown_ids:
            raise DiarizationError(
                "diarization returned an unknown segment", code="diarization_invalid_output"
            )
        return tuple(
            segment
            if (assignment := assignments.get(segment.id)) is None
            else segment.model_copy(
                update={
                    "speaker": assignment.primary_speaker_id,
                    "speakers": assignment.speakers,
                    "speaker_revision": assignment.revision,
                }
            )
            for segment in segments
        )

    async def finalize(self) -> DiarizationUpdate:
        assert self._session is not None
        return await self._session.finalize()

    async def finish_stream(self, through_sample: int | None = None) -> ActivitySnapshot | None:
        """Flush the streaming tail at EOF (continuous mode only)."""
        if self._continuous is None:
            return None
        through = (
            self._timeline.accepted_samples if through_sample is None else through_sample
        )
        return await self._continuous.finish(through)

    async def close(self) -> None:
        self._closed = True
        if self._continuous is not None:
            await self._continuous.close()
            return
        assert self._session is not None
        await self._session.close()
