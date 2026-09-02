"""Optional local NVIDIA NeMo Sortformer diarization adapter.

The adapter owns only bounded, session-local acoustic state.  It emits opaque
labels; user identity and cross-meeting persistence remain outside SpeechRail.
"""

from __future__ import annotations

import ast
import asyncio
import importlib.util
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, cast

from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import (
    DiarizationAssignment,
    DiarizationConfig,
    DiarizationError,
    DiarizationReadiness,
    DiarizationSpeaker,
    DiarizationUpdate,
)
from speechrail.runtime.speaker_centroids import SpeakerCentroidStore

NativeDiarize = Callable[[Sequence[float]], list[list[str]]]
EmbeddingExtractor = Callable[[bytes], Sequence[float] | None]


class NemoSortformerEngine:
    """Lazily load one local Sortformer model without any network access."""

    def __init__(
        self,
        *,
        model_path: str | Path,
        max_buffer_bytes: int,
        diarize: NativeDiarize | None = None,
        embedding: EmbeddingExtractor | None = None,
        centroids: SpeakerCentroidStore | None = None,
    ) -> None:
        if max_buffer_bytes <= 0:
            raise ValueError("max_buffer_bytes must be positive")
        self._model_path = Path(model_path)
        self._max_buffer_bytes = max_buffer_bytes
        self._model: Any | None = None
        self._diarize = diarize or self._load_local_model
        self._embedding = embedding
        self._centroids = centroids
        self._readiness = self._check_readiness(diarize=diarize, embedding=embedding)

    @property
    def readiness(self) -> DiarizationReadiness:
        """Return startup-checkable status without loading model weights."""
        return self._readiness

    def create(self, *, config: DiarizationConfig) -> _NemoSortformerSession:
        if not config.enabled:
            raise ValueError("diarization config must be enabled")
        return _NemoSortformerSession(
            self._diarize,
            config,
            self._max_buffer_bytes,
            self._embedding,
            self._centroids,
        )

    def _load_local_model(self, samples: Sequence[float]) -> list[list[str]]:
        if not self._model_path.is_file():
            raise DiarizationError(
                "diarization model is not available", code="diarization_not_available"
            )
        try:
            import numpy as np
            from nemo.collections.asr.models import (  # type: ignore[import-untyped]
                SortformerEncLabelModel,
            )
        except ImportError as exc:
            raise DiarizationError(
                "diarization runtime is not installed", code="diarization_not_available"
            ) from exc
        if self._model is None:
            self._model = SortformerEncLabelModel.restore_from(
                str(self._model_path), map_location="cpu"
            ).eval()
        return cast(
            list[list[str]],
            self._model.diarize(
                np.asarray(samples, dtype=np.float32), sample_rate=16_000, verbose=False
            ),
        )

    def _check_readiness(
        self,
        *,
        diarize: NativeDiarize | None,
        embedding: EmbeddingExtractor | None,
    ) -> DiarizationReadiness:
        if diarize is not None:
            return DiarizationReadiness(
                configured=True,
                ready=True,
                code=None,
                message="injected diarization backend is ready",
                profile="sortformer",
            )
        if not self._model_path.is_file():
            return DiarizationReadiness(
                configured=True,
                ready=False,
                code="diarization_not_available",
                message="diarization model is not available",
                profile="sortformer",
            )
        for module in ("numpy", "nemo.collections.asr.models"):
            try:
                if importlib.util.find_spec(module) is None:
                    return DiarizationReadiness(
                        configured=True,
                        ready=False,
                        code="diarization_not_available",
                        message="diarization runtime is not installed",
                        profile="sortformer",
                    )
            except (ImportError, ModuleNotFoundError):
                return DiarizationReadiness(
                    configured=True,
                    ready=False,
                    code="diarization_not_available",
                    message="diarization runtime is not installed",
                    profile="sortformer",
                )
        embedding_readiness = getattr(embedding, "readiness", None)
        if isinstance(embedding_readiness, DiarizationReadiness) and not embedding_readiness.ready:
            return embedding_readiness
        return DiarizationReadiness(
            configured=True,
            ready=True,
            code=None,
            message="Sortformer diarization profile is ready",
            profile="sortformer",
        )


@dataclass
class _NemoSortformerSession:
    _diarize: NativeDiarize
    _config: DiarizationConfig
    _max_buffer_bytes: int
    _embedding: EmbeddingExtractor | None = None
    _centroids: SpeakerCentroidStore | None = None
    _audio: bytearray = field(default_factory=bytearray)
    _audio_start_samples: int = 0
    _mapping: dict[str, str] = field(default_factory=dict)
    _canonical_labels: dict[str, str] = field(default_factory=dict)

    async def append_audio(self, audio: bytes) -> None:
        if len(self._audio) + len(audio) > self._max_buffer_bytes:
            raise DiarizationError(
                "diarization buffer limit exceeded", code="buffer_limit_exceeded"
            )
        self._audio.extend(audio)

    async def annotate(self, segments: tuple[TranscriptSegment, ...]) -> DiarizationUpdate:
        if not self._audio or not segments:
            return DiarizationUpdate()
        audio = bytes(self._audio)
        audio_start_ms = self._audio_start_samples // 16
        self._audio.clear()
        self._audio_start_samples += len(audio) // 2
        samples = _pcm16_samples(audio)
        raw = await asyncio.to_thread(self._diarize, samples)
        activities = _parse_activities(
            raw, self._config.speaker_count_hint, offset_ms=audio_start_ms
        )
        raw_assignments = tuple(
            assignment
            for segment in segments
            if (assignment := _assign(segment, activities)) is not None
        )
        await self._track_remap(
            raw_assignments,
            {segment.id: segment for segment in segments},
            activities,
            audio,
            audio_start_ms,
        )
        return DiarizationUpdate(assignments=raw_assignments)

    async def finalize(self) -> DiarizationUpdate:
        self._audio.clear()
        return DiarizationUpdate(mapping=dict(self._mapping))

    async def close(self) -> None:
        self._audio.clear()

    async def _track_remap(
        self,
        assignments: tuple[DiarizationAssignment, ...],
        segments: dict[str, TranscriptSegment],
        activities: tuple[tuple[int, int, int], ...],
        audio: bytes,
        audio_start_ms: int,
    ) -> None:
        if (
            self._config.group_id is None
            or self._embedding is None
            or self._centroids is None
            or not assignments
        ):
            return
        for assignment in assignments:
            for speaker in assignment.speakers:
                canonical = self._canonical_labels.get(speaker.id)
                activity = _matching_activity(
                    segments[assignment.segment_id], speaker.id, activities
                )
                embedding = (
                    None
                    if activity is None
                    else await asyncio.to_thread(
                        self._embedding,
                        _activity_audio(
                            audio,
                            audio_start_ms=audio_start_ms,
                            segment=segments[assignment.segment_id],
                            activity=activity,
                        ),
                    )
                )
                if canonical is None and embedding is not None:
                    try:
                        canonical = self._centroids.assign(
                            group_id=self._config.group_id,
                            raw_label=speaker.id,
                            embedding=embedding,
                        )
                    except ValueError as exc:
                        raise DiarizationError(
                            "speaker embedding is invalid", code="diarization_invalid_output"
                        ) from exc
                    self._canonical_labels[speaker.id] = canonical
                canonical = canonical or speaker.id
                if canonical != speaker.id:
                    self._mapping[speaker.id] = canonical


def _pcm16_samples(audio: bytes) -> list[float]:
    if len(audio) % 2:
        raise DiarizationError("diarization requires PCM16 audio", code="invalid_audio")
    return [
        int.from_bytes(audio[index : index + 2], "little", signed=True) / 32768
        for index in range(0, len(audio), 2)
    ]


def _parse_activities(
    raw: list[list[str]], hint: int | None, *, offset_ms: int
) -> tuple[tuple[int, int, int], ...]:
    if len(raw) != 1:
        raise DiarizationError(
            "diarization returned an invalid batch", code="diarization_invalid_output"
        )
    activities: list[tuple[int, int, int]] = []
    for encoded in raw[0]:
        try:
            start, end, speaker = ast.literal_eval(encoded)
            start_ms = int(float(start) * 1000)
            end_ms = int(float(end) * 1000)
            speaker_index = int(speaker)
        except (SyntaxError, TypeError, ValueError) as exc:
            raise DiarizationError(
                "diarization returned an invalid activity", code="diarization_invalid_output"
            ) from exc
        if (
            start_ms < 0
            or end_ms <= start_ms
            or speaker_index < 0
            or (hint is not None and speaker_index >= hint)
        ):
            continue
        activities.append((start_ms + offset_ms, end_ms + offset_ms, speaker_index))
    return tuple(activities)


def _assign(
    segment: TranscriptSegment, activities: tuple[tuple[int, int, int], ...]
) -> DiarizationAssignment | None:
    by_speaker: dict[int, int] = {}
    for start_ms, end_ms, speaker_index in activities:
        overlap = min(segment.end_ms, end_ms) - max(segment.start_ms, start_ms)
        if overlap > 0:
            by_speaker[speaker_index] = by_speaker.get(speaker_index, 0) + overlap
    overlaps = tuple((overlap, speaker_index) for speaker_index, overlap in by_speaker.items())
    if not overlaps:
        return None
    total = sum(overlap for overlap, _ in overlaps)
    return DiarizationAssignment(
        segment_id=segment.id,
        speakers=tuple(
            DiarizationSpeaker(
                id=f"spk_{speaker_index + 1:02d}", confidence=overlap / total
            )
            for overlap, speaker_index in sorted(overlaps, reverse=True)
        ),
    )


def _matching_activity(
    segment: TranscriptSegment,
    speaker_id: str,
    activities: tuple[tuple[int, int, int], ...],
) -> tuple[int, int, int] | None:
    speaker_index = int(speaker_id.removeprefix("spk_")) - 1
    candidates = [
        activity
        for activity in activities
        if activity[2] == speaker_index
        and min(segment.end_ms, activity[1]) > max(segment.start_ms, activity[0])
    ]
    return max(
        candidates,
        key=lambda activity: min(segment.end_ms, activity[1]) - max(segment.start_ms, activity[0]),
        default=None,
    )


def _activity_audio(
    audio: bytes,
    *,
    audio_start_ms: int,
    segment: TranscriptSegment,
    activity: tuple[int, int, int],
) -> bytes:
    start_ms, end_ms, _ = activity
    start_byte = max(0, (max(start_ms, segment.start_ms) - audio_start_ms) * 32)
    end_byte = min(len(audio), (min(end_ms, segment.end_ms) - audio_start_ms) * 32)
    return audio[start_byte:end_byte]
