"""Application service for attaching anonymous diarization to transcript segments."""

from __future__ import annotations

from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import DiarizationError, DiarizationUpdate
from speechrail.domain.ports import DiarizationSession


class DiarizationCoordinator:
    """Keep model-specific session state behind a narrow, validated boundary."""

    def __init__(self, session: DiarizationSession) -> None:
        self._session = session

    async def append_audio(self, audio: bytes) -> None:
        await self._session.append_audio(audio)

    async def annotate(
        self, segments: tuple[TranscriptSegment, ...]
    ) -> tuple[TranscriptSegment, ...]:
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
        return await self._session.finalize()

    async def close(self) -> None:
        await self._session.close()
