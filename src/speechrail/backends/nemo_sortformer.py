"""Optional local NVIDIA NeMo Sortformer diarization adapter.

The adapter owns only bounded, session-local acoustic state.  It emits opaque
labels; user identity and cross-meeting persistence remain outside SpeechRail.
"""

from __future__ import annotations

import ast
import asyncio
import importlib.util
import threading
import time
from collections import deque
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol, cast

from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import (
    ActivitySnapshot,
    DiarizationAssignment,
    DiarizationConfig,
    DiarizationError,
    DiarizationReadiness,
    DiarizationSpeaker,
    DiarizationUpdate,
    SpeakerActivity,
)
from speechrail.runtime.speaker_centroids import SpeakerCentroidStore

NativeDiarize = Callable[[Sequence[float]], list[list[str]]]
EmbeddingExtractor = Callable[[bytes], Sequence[float] | None]


class NativeStreamingDiarizer(Protocol):
    """Verified native incremental diarization step; opaque state stays inside.

    One instance serves exactly one continuous session for its whole lifetime;
    implementations must hold bounded streaming caches (AOSC/FIFO, speaker
    cache) and return one label per fed 80 ms frame.
    """

    frame_samples: int

    def step(self, frame: Sequence[float]) -> tuple[int, float]: ...

    def finish(self) -> None: ...

    def close(self) -> None: ...


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
        # Restore runs in worker threads (asyncio.to_thread); serialize the first
        # load so concurrent diarization requests cannot each load a full model.
        self._load_lock = threading.Lock()
        self.last_active = time.monotonic()
        self._diarize = self._track_activity(diarize or self._load_local_model)
        self._embedding = embedding
        self._centroids = centroids
        self._readiness = self._check_readiness(diarize=diarize, embedding=embedding)

    @property
    def alive(self) -> bool:
        """Whether model weights are resident (the idle evictor's unload signal)."""
        return self._model is not None

    async def close(self) -> None:
        """Drop resident weights; the next diarize reloads them lazily."""
        with self._load_lock:
            self._model = None

    def _track_activity(self, inner: NativeDiarize) -> NativeDiarize:
        """Stamp last_active on every diarize call for the idle evictor."""

        def run(samples: Sequence[float]) -> list[list[str]]:
            self.last_active = time.monotonic()
            return inner(samples)

        return run

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

    def create_stream(self, *, config: DiarizationConfig) -> NemoSortformerStreamSession:
        """Create a continuous stream session backed by a verified native step."""
        if not config.enabled:
            raise ValueError("diarization config must be enabled")
        return NemoSortformerStreamSession(self._create_native_stream())

    def _create_native_stream(self) -> NativeStreamingDiarizer:
        # R1 gate: the native incremental API must be version-verified by
        # tools/probe_diarization_streaming.py (and a real CPU smoke) before
        # this returns a production implementation; until then the continuous
        # capability stays offline and only injected fakes drive the port.
        raise DiarizationError(
            "continuous diarization native step is not verified for this runtime",
            code="diarization_not_available",
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
        with self._load_lock:
            if self._model is None:
                self._model = SortformerEncLabelModel.restore_from(
                    str(self._model_path), map_location="cpu"
                ).eval()
            model = self._model
        # Keep a local reference: an idle eviction may drop self._model while
        # this in-flight inference is running; it completes on the local ref.
        return cast(
            list[list[str]],
            model.diarize(
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
        # Vendor segment times are item-local ms; activities carry the
        # session-global offset. Lift each segment exactly once so second and
        # later items keep their attribution instead of overlapping nothing.
        session_segments = tuple(
            segment.model_copy(
                update={
                    "start_ms": segment.start_ms + audio_start_ms,
                    "end_ms": segment.end_ms + audio_start_ms,
                }
            )
            for segment in segments
        )
        raw_assignments = tuple(
            assignment
            for segment in session_segments
            if (assignment := _assign(segment, activities)) is not None
        )
        await self._track_remap(
            raw_assignments,
            {segment.id: segment for segment in session_segments},
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
        segments: dict[int, TranscriptSegment],
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


class NemoSortformerStreamSession:
    """Bounded continuous Sortformer session over one native streaming step.

    Implements the ``ContinuousDiarizationSession`` port.  The native step is
    created once per public session and is never reset by ASR commits; every
    accepted PCM sample advances the session-global clock exactly once.
    Merged activities are kept in a ring bounded by duration and count and are
    clipped to the processed watermark, so a two-hour meeting cannot grow the
    retained state.
    """

    def __init__(
        self,
        native: NativeStreamingDiarizer,
        *,
        max_ring_duration_samples: int = 30 * 16_000,
        max_ring_activities: int = 2048,
    ) -> None:
        self._native = native
        self._frame_samples = int(getattr(native, "frame_samples", 0) or 0)
        if self._frame_samples <= 0:
            raise ValueError("native streaming step must declare a positive frame size")
        if max_ring_duration_samples <= 0 or max_ring_activities <= 0:
            raise ValueError("ring bounds must be positive")
        self._max_ring_duration = max_ring_duration_samples
        self._max_ring_activities = max_ring_activities
        self._pending = bytearray()
        self._next_start = 0
        self._processed_samples = 0
        self._closed = False
        self._ring: deque[SpeakerActivity] = deque()
        self._ring_duration = 0
        self._open_start = 0
        self._open_end = 0
        self._open_speaker: str | None = None
        self._open_score_sum = 0.0
        self._open_frames = 0

    @property
    def next_start_sample(self) -> int:
        """The session-global start sample the next append must carry."""
        return self._next_start

    @property
    def max_ring_activities(self) -> int:
        return self._max_ring_activities

    def retained_activity_count(self) -> int:
        return len(self._ring) + (1 if self._open_speaker is not None else 0)

    async def append(self, pcm: bytes, start_sample: int) -> None:
        if self._closed:
            raise DiarizationError("diarization stream is closed", code="invalid_audio")
        if len(pcm) % 2:
            raise DiarizationError("diarization requires PCM16 audio", code="invalid_audio")
        if start_sample != self._next_start:
            raise DiarizationError(
                "diarization sample continuity broken: "
                f"expected start {self._next_start}, got {start_sample}",
                code="invalid_audio",
            )
        self._pending.extend(pcm)
        self._next_start += len(pcm) // 2
        frame_bytes = self._frame_samples * 2
        while len(self._pending) >= frame_bytes:
            frame = bytes(self._pending[:frame_bytes])
            del self._pending[:frame_bytes]
            self._consume_frame(frame)

    async def activities(self, through_sample: int) -> ActivitySnapshot:
        if self._closed:
            raise DiarizationError("diarization stream is closed", code="invalid_audio")
        return self._snapshot(through_sample)

    async def finish(self, through_sample: int) -> ActivitySnapshot:
        """Flush the trailing partial frame (zero-padded) and freeze the tail."""
        if self._closed:
            raise DiarizationError("diarization stream is closed", code="invalid_audio")
        pending = len(self._pending) // 2
        if pending:
            frame_bytes = self._frame_samples * 2
            padding = frame_bytes - len(self._pending)
            frame = bytes(self._pending) + b"\x00" * padding
            self._pending.clear()
            self._consume_frame(frame, end=self._processed_samples + pending)
        self._native.finish()
        self._freeze_open_activity()
        return self._snapshot(through_sample)

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._pending.clear()
        self._ring.clear()
        self._ring_duration = 0
        self._reset_open()
        self._native.close()

    def _consume_frame(self, frame: bytes, *, end: int | None = None) -> None:
        start = self._processed_samples
        end = start + self._frame_samples if end is None else end
        self._processed_samples = end
        speaker_index, score = self._native.step(_pcm16_samples(frame))
        if speaker_index < 0:
            self._freeze_open_activity()
            return
        speaker = f"spk_{speaker_index + 1:02d}"
        if (
            self._open_speaker == speaker
            and self._open_end == start
            and self._open_frames > 0
        ):
            self._open_end = end
            self._open_score_sum += score
            self._open_frames += 1
            return
        self._freeze_open_activity()
        self._open_start = start
        self._open_end = end
        self._open_speaker = speaker
        self._open_score_sum = score
        self._open_frames = 1

    def _freeze_open_activity(self) -> None:
        if self._open_speaker is None:
            return
        activity = SpeakerActivity(
            start_sample=self._open_start,
            end_sample=self._open_end,
            speaker=self._open_speaker,
            activity_score=self._open_score_sum / self._open_frames,
        )
        self._reset_open()
        self._ring.append(activity)
        self._ring_duration += activity.end_sample - activity.start_sample
        # Keep at least the newest activity: a single merged interval may
        # legitimately exceed the duration cap in continuously active audio.
        while len(self._ring) > 1 and (
            self._ring_duration > self._max_ring_duration
            or len(self._ring) > self._max_ring_activities
        ):
            evicted = self._ring.popleft()
            self._ring_duration -= evicted.end_sample - evicted.start_sample

    def _reset_open(self) -> None:
        self._open_start = 0
        self._open_end = 0
        self._open_speaker = None
        self._open_score_sum = 0.0
        self._open_frames = 0

    def _snapshot(self, through_sample: int) -> ActivitySnapshot:
        through = min(max(0, through_sample), self._processed_samples)
        visible = [activity for activity in self._ring if activity.end_sample <= through]
        if self._open_speaker is not None and self._open_start < through:
            visible.append(
                SpeakerActivity(
                    start_sample=self._open_start,
                    end_sample=min(self._open_end, through),
                    speaker=self._open_speaker,
                    activity_score=self._open_score_sum / self._open_frames,
                )
            )
        return ActivitySnapshot(
            processed_through_sample=through,
            stable_through_sample=through,
            activities=tuple(visible),
        )


def _parse_activities(
    raw: list[list[str]], hint: int | None, *, offset_ms: int
) -> tuple[tuple[int, int, int], ...]:
    if len(raw) != 1:
        raise DiarizationError(
            "diarization returned an invalid batch", code="diarization_invalid_output"
        )
    activities: list[tuple[int, int, int]] = []
    for encoded in raw[0]:
        start, end, speaker = _parse_activity_token(encoded)
        start_ms = int(float(start) * 1000)
        end_ms = int(float(end) * 1000)
        speaker_index = _speaker_index(speaker)
        if (
            start_ms < 0
            or end_ms <= start_ms
            or speaker_index < 0
            or (hint is not None and speaker_index >= hint)
        ):
            continue
        activities.append((start_ms + offset_ms, end_ms + offset_ms, speaker_index))
    return tuple(activities)


def _parse_activity_token(encoded: str) -> tuple[float, float, str]:
    """Parses one Sortformer activity token into ``(start_s, end_s, speaker_label)``.

    Sortformer ``diarize`` emits space-separated ``"<start> <end> speaker_N"``
    tokens (e.g. ``"0.000 2.320 speaker_0"``).  Older/newer profiles may emit
    Python tuple/list literals, so those are accepted too.
    """
    stripped = encoded.strip()
    if not stripped:
        raise DiarizationError(
            "diarization returned an invalid activity", code="diarization_invalid_output"
        )
    if " " in stripped and not stripped.startswith(("[", "(")):
        parts = stripped.split()
        if len(parts) >= 3:
            try:
                return float(parts[0]), float(parts[1]), parts[2]
            except ValueError:
                raise DiarizationError(
                    "diarization returned an invalid activity",
                    code="diarization_invalid_output",
                ) from None
    if stripped.startswith(("[", "(")):
        try:
            values = ast.literal_eval(stripped)
        except (SyntaxError, TypeError, ValueError) as exc:
            raise DiarizationError(
                "diarization returned an invalid activity", code="diarization_invalid_output"
            ) from exc
        if isinstance(values, (list, tuple)) and len(values) >= 3:
            return float(values[0]), float(values[1]), str(values[2])
    raise DiarizationError(
        "diarization returned an invalid activity", code="diarization_invalid_output"
    )


def _speaker_index(speaker: str) -> int:
    """Extracts the zero-based speaker index from ``speaker_0`` / ``spk_1`` / ``0``."""
    label = speaker.strip()
    if label.startswith(("spk_", "speaker_")):
        return int(label.rsplit("_", 1)[1])
    return int(label)


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
