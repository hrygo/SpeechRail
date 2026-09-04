"""Immutable dependency snapshot and explicit backend composition."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from uuid import uuid4

from speechrail.application.lifecycle import RuntimeLifecycle
from speechrail.backends.camplus import CamPlusEmbeddingExtractor
from speechrail.backends.nemo_sortformer import NemoSortformerEngine
from speechrail.backends.qwen3_native import (
    Qwen3BackendConfig,
    Qwen3BatchTranscriber,
    Qwen3Worker,
    resolve_backend_dtype,
)
from speechrail.backends.qwen3_streaming import (
    NativeRealtimeFactory,
    Qwen3StreamingBackendConfig,
    Qwen3StreamingWorker,
)
from speechrail.backends.qwen3_tts import Qwen3TtsBackendConfig, Qwen3TtsWorker
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.diarization import DiarizationReadiness
from speechrail.domain.ports import (
    BatchTranscriber,
    DiarizationEngine,
    RealtimeAsrFactory,
    SpeechSynthesizer,
    TranscriptionRequest,
)
from speechrail.observability.metrics import Metrics
from speechrail.runtime.admission import AdmissionQueue
from speechrail.runtime.job_runner import JobProcessor, JobRunner
from speechrail.runtime.jobs import JobRepository
from speechrail.runtime.resource_governor import ResourceGovernor
from speechrail.runtime.speaker_centroids import SpeakerCentroidStore
from speechrail.runtime.worker_lease import EvictableWorker, WorkerIdleEvictor

Transcribe = Callable[[bytes, str | None, str, bool], Awaitable[TranscriptResult]]


def _package_root() -> Path:
    """Return the import root for source checkouts and installed wheels alike."""
    return Path(__file__).resolve().parents[2]


class _CallableBatchTranscriber(BatchTranscriber):
    """Bridge the legacy callable seam to the typed batch-transcription port."""

    def __init__(self, transcribe: Transcribe, model_id: str) -> None:
        self._transcribe = transcribe
        self._model_id = model_id

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        result = await self._transcribe(
            request.audio, request.language, request.prompt, request.include_timestamps
        )
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
    batch_transcriber: BatchTranscriber | None = None
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
    batch_transcriber: BatchTranscriber | None
    realtime_asr_factory: RealtimeAsrFactory | None
    diarization_engine: DiarizationEngine | None
    tts_synthesizer: SpeechSynthesizer | None
    job_repository: JobRepository | None
    asr_worker: Qwen3Worker | None
    admission: AdmissionQueue
    governor: ResourceGovernor
    lifecycle: RuntimeLifecycle
    metrics: Metrics = field(default_factory=Metrics)

    @property
    def asr_ready(self) -> bool:
        return (
            self.transcribe is not None
            or self.batch_transcriber is not None
            or self.realtime_asr_factory is not None
            or self.settings.backend_ready
        )

    @property
    def tts_ready(self) -> bool:
        return self.tts_synthesizer is not None or self.settings.backend_ready

    @property
    def diarization_status(self) -> dict[str, object]:
        """Expose optional profile readiness without filesystem or identity data."""
        if self.diarization_engine is None:
            return {
                "configured": False,
                "ready": False,
                "code": "diarization_not_configured",
                "message": "diarization profile is not configured",
                "profile": None,
            }
        readiness = getattr(self.diarization_engine, "readiness", None)
        if isinstance(readiness, DiarizationReadiness):
            return {
                "configured": readiness.configured,
                "ready": readiness.ready,
                "code": readiness.code,
                "message": readiness.message,
                "profile": readiness.profile,
            }
        return {
            "configured": True,
            "ready": True,
            "code": None,
            "message": "diarization backend is ready",
            "profile": None,
        }

    @property
    def diarization_ready(self) -> bool:
        return bool(self.diarization_status["ready"])


def build_app_services(settings: Settings, overrides: AppOverrides) -> AppServices:
    """Compose concrete Qwen/NeMo/job components without starting them."""
    job_repository = overrides.job_repository
    if job_repository is None and settings.job_spool_dir is not None:
        job_repository = JobRepository(settings.job_spool_dir)

    asr_worker: Qwen3Worker | None = None
    transcribe = overrides.transcribe
    batch_transcriber = overrides.batch_transcriber
    if (
        transcribe is None
        and settings.qwen3_model_dir is not None
        and settings.qwen3_python is not None
    ):
        asr_worker = Qwen3Worker(
            Qwen3BackendConfig(
                repository_root=_package_root(),
                python_executable=settings.qwen3_python,
                model_dir=settings.qwen3_model_dir,
                device=settings.device,
                dtype=resolve_backend_dtype(settings.qwen3_model_dir, settings.dtype),
                cache_limit_mb=settings.mlx_cache_limit_mb,
                memory_limit_mb=settings.mlx_memory_limit_mb,
                timeout_seconds=settings.request_timeout_seconds,
            )
        )
        transcribe = asr_worker.transcribe
        batch_transcriber = Qwen3BatchTranscriber(worker=asr_worker, model_id=settings.model_id)

    tts_worker: Qwen3TtsWorker | None = None
    tts_synthesizer = overrides.tts_synthesizer
    if (
        tts_synthesizer is None
        and settings.qwen3_tts_model_dir is not None
        and settings.qwen3_tts_python is not None
    ):
        tts_worker = Qwen3TtsWorker(
            Qwen3TtsBackendConfig(
                repository_root=_package_root(),
                python_executable=settings.qwen3_tts_python,
                model_dir=settings.qwen3_tts_model_dir,
                device=settings.device,
                dtype=resolve_backend_dtype(
                    settings.qwen3_tts_model_dir,
                    "float16" if settings.device == "mps" else "float32",
                ),
                sample_rate=settings.tts_sample_rate,
                timeout_seconds=settings.request_timeout_seconds,
                chunk_ms=settings.tts_chunk_ms,
                repetition_penalty=settings.tts_repetition_penalty,
                temperature=settings.tts_temperature,
                top_p=settings.tts_top_p,
                warmup_on_start=settings.tts_warmup_on_start,
                cache_limit_mb=settings.mlx_cache_limit_mb,
                memory_limit_mb=settings.mlx_memory_limit_mb,
            )
        )
        tts_synthesizer = tts_worker

    realtime_asr_factory = overrides.realtime_asr_factory
    streaming_worker: Qwen3StreamingWorker | None = None
    if (
        realtime_asr_factory is None
        and settings.realtime_asr_backend == "native"
        and settings.qwen3_python is not None
        and settings.qwen3_model_dir is not None
    ):
        # Dedicated streaming worker: concurrent realtime sessions multiplex one
        # pipe via session_id frame routing (the worker, not batch, owns the
        # streaming read side). Keeping batch on a separate worker bounds batch
        # latency from delaying realtime frames.
        streaming_worker = Qwen3StreamingWorker(
            Qwen3StreamingBackendConfig(
                repository_root=_package_root(),
                python_executable=settings.qwen3_python,
                model_dir=settings.qwen3_model_dir,
                device=settings.device,
                dtype=resolve_backend_dtype(settings.qwen3_model_dir, settings.dtype),
                cache_limit_mb=settings.mlx_cache_limit_mb,
                memory_limit_mb=settings.mlx_memory_limit_mb,
                mode=settings.qwen3_streaming_mode,
                chunk_sec=settings.qwen3_streaming_chunk_sec,
                left_context_sec=settings.qwen3_streaming_left_context_sec,
                right_context_ms=settings.qwen3_streaming_right_context_ms,
                hold_back_words=settings.qwen3_streaming_hold_back_words,
                stable_iterations=settings.qwen3_streaming_stable_iterations,
                max_new_tokens=settings.qwen3_streaming_max_new_tokens,
                timeout_seconds=settings.request_timeout_seconds,
            )
        )
        realtime_asr_factory = NativeRealtimeFactory(
            worker=streaming_worker,
            mode=settings.qwen3_streaming_mode,
            next_session_id=lambda: f"sess_{uuid4().hex}",
            max_sessions=settings.realtime_max_sessions,
        )

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
    metrics = Metrics()
    governor = ResourceGovernor(
        settings.governor_limits,
        on_reject=metrics.record_governor_rejection,
    )
    job_runner: JobRunner | None = None
    if job_repository is not None and overrides.job_processor is not None:
        job_runner = JobRunner(
            repository=job_repository,
            governor=governor,
            processor=overrides.job_processor,
            deadline_seconds=settings.request_timeout_seconds,
        )
    if batch_transcriber is None and transcribe is not None:
        batch_transcriber = _CallableBatchTranscriber(transcribe, settings.model_id)

    evictor: WorkerIdleEvictor | None = None
    if settings.worker_idle_timeout_seconds > 0:
        # The in-service diarization engine participates in idle eviction too:
        # once resident it holds ~0.5GB in the host process and is otherwise
        # never released. Its close() drops the weights; the next diarize
        # reloads lazily under the load lock. The domain DiarizationEngine
        # protocol intentionally knows nothing about lifecycle, so the engine
        # is narrowed to the runtime EvictableWorker protocol it implements.
        evictable: list[EvictableWorker] = [
            w for w in (asr_worker, tts_worker, streaming_worker) if w is not None
        ]
        if isinstance(diarization_engine, EvictableWorker):
            evictable.append(diarization_engine)
        if evictable:
            evictor = WorkerIdleEvictor(
                evictable,
                idle_timeout_seconds=settings.worker_idle_timeout_seconds,
                warm_standby_timeout_seconds=settings.worker_warm_standby_timeout_seconds,
                min_uptime_seconds=settings.worker_min_uptime_seconds,
                on_eviction=metrics.record_eviction,
            )

    lifecycle = RuntimeLifecycle(
        repository=job_repository,
        asr=asr_worker,
        tts=tts_worker,
        streaming=streaming_worker,
        runner=job_runner,
        evictor=evictor,
        lazy_load=settings.worker_lazy_load,
        poll_seconds=settings.job_poll_seconds,
    )
    return AppServices(
        settings=settings,
        transcribe=transcribe,
        batch_transcriber=batch_transcriber,
        realtime_asr_factory=realtime_asr_factory,
        diarization_engine=diarization_engine,
        tts_synthesizer=tts_synthesizer,
        job_repository=job_repository,
        asr_worker=asr_worker,
        admission=admission,
        governor=governor,
        lifecycle=lifecycle,
        metrics=metrics,
    )
