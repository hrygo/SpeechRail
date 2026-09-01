"""Immutable dependency snapshot and explicit backend composition."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path

from speechrail.application.lifecycle import RuntimeLifecycle
from speechrail.backends.camplus import CamPlusEmbeddingExtractor
from speechrail.backends.nemo_sortformer import NemoSortformerEngine
from speechrail.backends.qwen3_native import (
    Qwen3BackendConfig,
    Qwen3BatchTranscriber,
    Qwen3Worker,
)
from speechrail.backends.qwen3_tts import Qwen3TtsBackendConfig, Qwen3TtsWorker
from speechrail.backends.wlk_streaming import WlkRealtimeFactory
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import (
    BatchTranscriber,
    DiarizationEngine,
    RealtimeAsrFactory,
    SpeechSynthesizer,
    TranscriptionRequest,
)
from speechrail.runtime.admission import AdmissionQueue
from speechrail.runtime.job_runner import JobProcessor, JobRunner
from speechrail.runtime.jobs import JobRepository
from speechrail.runtime.resource_governor import ResourceGovernor
from speechrail.runtime.speaker_centroids import SpeakerCentroidStore

Transcribe = Callable[[bytes, str | None, str], Awaitable[TranscriptResult]]


class _CallableBatchTranscriber(BatchTranscriber):
    """Bridge the v1 callable seam while v2 adopts typed backend ports."""

    def __init__(self, transcribe: Transcribe, model_id: str) -> None:
        self._transcribe = transcribe
        self._model_id = model_id

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        result = await self._transcribe(request.audio, request.language, request.prompt)
        return result.model_copy(
            update={"request_id": request.request_id, "model_id": self._model_id}
        )


def component_ready(component: object | None) -> bool:
    """Treat injected components as ready unless they explicitly report otherwise."""
    if component is None:
        return False
    state = getattr(component, "ready", None)
    return True if state is None else bool(state)


@dataclass(frozen=True, slots=True)
class AppOverrides:
    """Explicit caller-provided replacements for composed inference components."""

    transcribe: Transcribe | None = None
    v2_transcriber: BatchTranscriber | None = None
    realtime_asr_factory: RealtimeAsrFactory | None = None
    diarization_engine: DiarizationEngine | None = None
    tts_synthesizer: SpeechSynthesizer | None = None
    job_repository: JobRepository | None = None
    job_processor: JobProcessor | None = None


@dataclass(frozen=True, slots=True)
class AppServices:
    """Resolved dependency snapshot consumed by route factories."""

    settings: Settings
    transcribe: Transcribe | None
    v2_transcriber: BatchTranscriber | None
    realtime_asr_factory: RealtimeAsrFactory | None
    diarization_engine: DiarizationEngine | None
    tts_synthesizer: SpeechSynthesizer | None
    job_repository: JobRepository | None
    asr_worker: Qwen3Worker | None
    admission: AdmissionQueue
    governor: ResourceGovernor
    lifecycle: RuntimeLifecycle

    @property
    def asr_ready(self) -> bool:
        return (
            self.transcribe is not None
            or self.v2_transcriber is not None
            or self.realtime_asr_factory is not None
            or self.settings.backend_ready
        )

    @property
    def tts_ready(self) -> bool:
        return component_ready(self.tts_synthesizer)


def build_app_services(settings: Settings, overrides: AppOverrides) -> AppServices:
    """Compose concrete Qwen/WLK/NeMo/job components without starting them."""
    job_repository = overrides.job_repository
    if job_repository is None and settings.job_spool_dir is not None:
        job_repository = JobRepository(settings.job_spool_dir)

    asr_worker: Qwen3Worker | None = None
    transcribe = overrides.transcribe
    v2_transcriber = overrides.v2_transcriber
    if (
        transcribe is None
        and settings.qwen3_model_dir is not None
        and settings.qwen3_python is not None
    ):
        asr_worker = Qwen3Worker(
            Qwen3BackendConfig(
                repository_root=Path(__file__).parents[3],
                python_executable=settings.qwen3_python,
                model_dir=settings.qwen3_model_dir,
                device=settings.device,
                dtype=settings.dtype,
                timeout_seconds=settings.request_timeout_seconds,
            )
        )
        transcribe = asr_worker.transcribe
        v2_transcriber = Qwen3BatchTranscriber(worker=asr_worker, model_id=settings.model_id)

    tts_worker: Qwen3TtsWorker | None = None
    tts_synthesizer = overrides.tts_synthesizer
    if (
        tts_synthesizer is None
        and settings.qwen3_tts_model_dir is not None
        and settings.qwen3_tts_python is not None
    ):
        tts_worker = Qwen3TtsWorker(
            Qwen3TtsBackendConfig(
                repository_root=Path(__file__).parents[3],
                python_executable=settings.qwen3_tts_python,
                model_dir=settings.qwen3_tts_model_dir,
                device=settings.device,
                dtype=settings.dtype,
                sample_rate=settings.tts_sample_rate,
                timeout_seconds=settings.request_timeout_seconds,
                chunk_ms=settings.tts_chunk_ms,
                repetition_penalty=settings.tts_repetition_penalty,
                temperature=settings.tts_temperature,
                top_p=settings.tts_top_p,
                warmup_on_start=settings.tts_warmup_on_start,
            )
        )
        tts_synthesizer = tts_worker

    realtime_asr_factory = overrides.realtime_asr_factory
    if realtime_asr_factory is None and settings.wlk_streaming_url is not None:
        realtime_asr_factory = WlkRealtimeFactory(url=settings.wlk_streaming_url)

    diarization_engine = overrides.diarization_engine
    if diarization_engine is None and settings.diarization_model_path is not None:
        embedding = (
            None
            if settings.diarization_embedding_model_path is None
            else CamPlusEmbeddingExtractor(model_path=settings.diarization_embedding_model_path)
        )
        centroids = (
            None
            if embedding is None
            else SpeakerCentroidStore(
                max_groups=settings.diarization_max_groups,
                ttl_seconds=settings.diarization_group_ttl_seconds,
                similarity_threshold=settings.diarization_similarity_threshold,
            )
        )
        diarization_engine = NemoSortformerEngine(
            model_path=settings.diarization_model_path,
            max_buffer_bytes=settings.diarization_max_buffer_bytes,
            embedding=embedding,
            centroids=centroids,
        )

    admission = AdmissionQueue(settings.max_queue_size)
    governor = ResourceGovernor(settings.governor_limits)
    job_runner: JobRunner | None = None
    if job_repository is not None and overrides.job_processor is not None:
        job_runner = JobRunner(
            repository=job_repository,
            governor=governor,
            processor=overrides.job_processor,
            deadline_seconds=settings.request_timeout_seconds,
        )
    if v2_transcriber is None and transcribe is not None:
        v2_transcriber = _CallableBatchTranscriber(transcribe, settings.model_id)

    lifecycle = RuntimeLifecycle(
        repository=job_repository,
        asr=asr_worker,
        tts=tts_worker,
        runner=job_runner,
        poll_seconds=settings.job_poll_seconds,
    )
    return AppServices(
        settings=settings,
        transcribe=transcribe,
        v2_transcriber=v2_transcriber,
        realtime_asr_factory=realtime_asr_factory,
        diarization_engine=diarization_engine,
        tts_synthesizer=tts_synthesizer,
        job_repository=job_repository,
        asr_worker=asr_worker,
        admission=admission,
        governor=governor,
        lifecycle=lifecycle,
    )
