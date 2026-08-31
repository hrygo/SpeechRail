"""Optional local NVIDIA NeMo Sortformer diarization adapter.

The adapter owns only bounded, session-local acoustic state.  It emits opaque
labels; user identity and cross-meeting persistence remain outside SpeechRail.
"""

from __future__ import annotations

import ast
import asyncio
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, cast

from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import (
    DiarizationAssignment,
    DiarizationConfig,
    DiarizationSpeaker,
    DiarizationUpdate,
)
from speechrail.domain.realtime_v2 import RealtimeV2Error

NativeDiarize = Callable[[Sequence[float]], list[list[str]]]


class NemoSortformerEngine:
    """Lazily load one local Sortformer model without any network access."""

    def __init__(
        self,
        *,
        model_path: str | Path,
        max_buffer_bytes: int,
        diarize: NativeDiarize | None = None,
    ) -> None:
        if max_buffer_bytes <= 0:
            raise ValueError("max_buffer_bytes must be positive")
        self._model_path = Path(model_path)
        self._max_buffer_bytes = max_buffer_bytes
        self._model: Any | None = None
        self._diarize = diarize or self._load_local_model

    def create(self, *, config: DiarizationConfig) -> _NemoSortformerSession:
        if not config.enabled:
            raise ValueError("diarization config must be enabled")
        return _NemoSortformerSession(self._diarize, config, self._max_buffer_bytes)

    def _load_local_model(self, samples: Sequence[float]) -> list[list[str]]:
        if not self._model_path.is_file():
            raise RealtimeV2Error(
                "diarization model is not available", code="diarization_not_available"
            )
        try:
            import numpy as np  # type: ignore[import-not-found]
            from nemo.collections.asr.models import (  # type: ignore[import-not-found]
                SortformerEncLabelModel,
            )
        except ImportError as exc:
            raise RealtimeV2Error(
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


@dataclass
class _NemoSortformerSession:
    _diarize: NativeDiarize
    _config: DiarizationConfig
    _max_buffer_bytes: int
    _audio: bytearray = field(default_factory=bytearray)

    async def append_audio(self, audio: bytes) -> None:
        if len(self._audio) + len(audio) > self._max_buffer_bytes:
            raise RealtimeV2Error("diarization buffer limit exceeded", code="buffer_limit_exceeded")
        self._audio.extend(audio)

    async def annotate(self, segments: tuple[TranscriptSegment, ...]) -> DiarizationUpdate:
        audio = bytes(self._audio)
        self._audio.clear()
        if not audio or not segments:
            return DiarizationUpdate()
        samples = _pcm16_samples(audio)
        raw = await asyncio.to_thread(self._diarize, samples)
        activities = _parse_activities(raw, self._config.speaker_count_hint)
        assignments = tuple(
            assignment
            for segment in segments
            if (assignment := _assign(segment, activities)) is not None
        )
        return DiarizationUpdate(assignments=assignments)

    async def finalize(self) -> DiarizationUpdate:
        self._audio.clear()
        return DiarizationUpdate()

    async def close(self) -> None:
        self._audio.clear()


def _pcm16_samples(audio: bytes) -> list[float]:
    if len(audio) % 2:
        raise RealtimeV2Error("diarization requires PCM16 audio", code="invalid_audio")
    return [
        int.from_bytes(audio[index : index + 2], "little", signed=True) / 32768
        for index in range(0, len(audio), 2)
    ]


def _parse_activities(
    raw: list[list[str]], hint: int | None
) -> tuple[tuple[int, int, int], ...]:
    if len(raw) != 1:
        raise RealtimeV2Error(
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
            raise RealtimeV2Error(
                "diarization returned an invalid activity", code="diarization_invalid_output"
            ) from exc
        if (
            start_ms < 0
            or end_ms <= start_ms
            or speaker_index < 0
            or (hint is not None and speaker_index >= hint)
        ):
            continue
        activities.append((start_ms, end_ms, speaker_index))
    return tuple(activities)


def _assign(
    segment: TranscriptSegment, activities: tuple[tuple[int, int, int], ...]
) -> DiarizationAssignment | None:
    overlaps = [
        (min(segment.end_ms, end_ms) - max(segment.start_ms, start_ms), speaker_index)
        for start_ms, end_ms, speaker_index in activities
        if min(segment.end_ms, end_ms) > max(segment.start_ms, start_ms)
    ]
    if not overlaps:
        return None
    _, speaker_index = max(overlaps)
    return DiarizationAssignment(
        segment_id=segment.id,
        speakers=(DiarizationSpeaker(id=f"spk_{speaker_index + 1:02d}", confidence=1.0),),
    )
