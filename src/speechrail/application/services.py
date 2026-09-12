"""Immutable dependency snapshot and explicit backend composition."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import cast
from uuid import uuid4

from speechrail.application.diarization.alignment import FixedTextAligner
from speechrail.application.lifecycle import RuntimeLifecycle
from speechrail.backends.diarization.coreml import CoreMLSortformerEngine
from speechrail.backends.model_identity import inspect_model
from speechrail.backends.qwen3_native import (
    Qwen3BackendConfig,
    Qwen3BatchTranscriber,
    Qwen3Worker,
    resolve_backend_dtype,
)
from speechrail.backends.qwen3_shared import Qwen3SharedWorker
from speechrail.backends.qwen3_streaming import (
    NativeRealtimeFactory,
    Qwen3StreamingBackendConfig,
    Qwen3StreamingWorker,
)
from speechrail.backends.qwen3_tts import (
    Qwen3TtsBackendConfig,
    Qwen3TtsCapabilityRouter,
    Qwen3TtsWorker,
    TtsModelVariant,
)
from speechrail.config import Settings
from speechrail.config.selection import active_model_catalog
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.diarization import DiarizationReadiness
from speechrail.domain.diarization.ports import AlignTextPort
from speechrail.domain.ports import (
    BatchTranscriber,
    DiarizationEngine,
    RealtimeAsrFactory,
    SpeechSynthesizer,
    TranscriptionRequest,
)
from speechrail.observability.metrics import Metrics
from speechrail.runtime.admission import AdmissionQueue
from speechrail.runtime.alignment_admission import AlignmentAdmission
from speechrail.runtime.diarization_admission import DiarizationAdmission
from speechrail.runtime.job_runner import JobProcessor, JobRunner
from speechrail.runtime.jobs import JobRepository
from speechrail.runtime.local_file_processor import LocalFileJobProcessor
from speechrail.runtime.model_budget import (
    ComponentFootprint,
    budget_for_hardware,
    can_overlap_heavy_compute,
    detect_system_memory_bytes,
)
from speechrail.runtime.resource_governor import ResourceGovernor
from speechrail.runtime.worker_lease import EvictableWorker, WorkerIdleEvictor

Transcribe = Callable[[bytes, str | None, str, bool], Awaitable[TranscriptResult]]
_SERVICE_OVERHEAD_BYTES = 512 * 1024**2


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


def _heavy_overlap_policy(
    settings: Settings,
    *,
    asr_enabled: bool,
    tts_enabled: bool,
    diarization_enabled: bool,
) -> tuple[bool, str]:
    """Decide whether heavy ASR/TTS compute may overlap.

    Declared `*_resident_bytes` settings feed a shared hardware budget. An
    enabled component with 0 declared bytes is still unknown and fail-closes
    under `auto`. `allow_heavy_overlap` may force the decision: "true" always
    allows overlap and "false" always serializes, both recorded in the reason.
    """
    if settings.allow_heavy_overlap == "false":
        return False, "heavy overlap disabled by configuration"

    def _bytes(enabled: bool, declared: int) -> int | None:
        if not enabled:
            return 0
        return declared if declared > 0 else None

    footprint = ComponentFootprint(
        asr_bytes=_bytes(asr_enabled, settings.asr_resident_bytes),
        tts_bytes=_bytes(tts_enabled, settings.tts_resident_bytes),
        diarization_bytes=_bytes(diarization_enabled, settings.diarization_resident_bytes),
        service_bytes=_SERVICE_OVERHEAD_BYTES,
        device=settings.device,
    )
    if settings.allow_heavy_overlap == "true":
        return True, "heavy overlap forced on by configuration"
    try:
        budget = budget_for_hardware(detect_system_memory_bytes())
    except (RuntimeError, ValueError) as exc:
        return False, f"Unsupported hardware budget: {exc}; serializing workloads"
    return can_overlap_heavy_compute(budget, footprint)


@dataclass(frozen=True, slots=True)
class AppOverrides:
    """Explicit caller-provided replacements for composed inference components."""

    transcribe: Transcribe | None = None
    batch_transcriber: BatchTranscriber | None = None
    realtime_asr_factory: RealtimeAsrFactory | None = None
    diarization_engine: DiarizationEngine | None = None
    text_aligner: AlignTextPort | None = None
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
    text_aligner: AlignTextPort | None = None
    alignment_admission: AlignmentAdmission = field(default_factory=AlignmentAdmission)
    diarization_admission: DiarizationAdmission = field(default_factory=DiarizationAdmission)
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
    def tts_warm(self) -> bool | None:
        """Whether TTS can produce audio without a worker load transition."""
        if self.tts_synthesizer is None:
            return False
        ready = getattr(self.tts_synthesizer, "ready", None)
        if isinstance(ready, bool):
            return ready
        return None

    @property
    def realtime_vad_status(self) -> dict[str, object]:
        """Expose the resolved realtime VAD capability without loading a model."""
        settings = self.settings
        resolved_engine = "silero" if settings.resolves_to_silero_vad else "legacy"
        status: dict[str, object] = {
            "configured_engine": settings.realtime_vad_engine,
            "resolved_engine": resolved_engine,
            "speech_admission_enabled": settings.realtime_speech_admission_enabled,
        }
        if resolved_engine == "legacy":
            status.update({"ready": True, "code": None, "message": "legacy VAD is ready"})
            return status

        # The adapter performs only bounded path/import checks here.  It opens
        # the ONNX session lazily on the first admitted frame, so health and
        # readiness probes never load model state or consume inference budget.
        from speechrail.backends.neural_vad import SileroVadDetector

        ready, reason = SileroVadDetector.check_readiness(settings.realtime_vad_model_path)
        if ready:
            status.update(
                {
                    "ready": True,
                    "code": None,
                    "message": "Silero VAD runtime and model are ready",
                }
            )
            return status

        reason_text = str(reason or "Silero VAD is not ready")
        if "onnxruntime" in reason_text:
            code = "vad_runtime_missing"
            message = "onnxruntime is not installed in the service environment"
        elif "model" in reason_text or "file" in reason_text:
            code = "vad_model_missing"
            message = "Silero VAD model is unavailable"
        else:
            code = "vad_not_ready"
            message = "Silero VAD is not ready"
        status.update({"ready": False, "code": code, "message": message})
        return status

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
        if (
            isinstance(self.diarization_engine, CoreMLSortformerEngine)
            and self.settings.qwen3_aligner_model_dir is None
        ):
            return {
                "configured": False,
                "ready": False,
                "code": "diarization_alignment_not_configured",
                "message": "diarization requires a local fixed-text aligner snapshot",
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

    @property
    def subsystem_states(self) -> dict[str, str]:
        """Per-subsystem inference lifecycle state for transparent readiness.

        The ``*_ready`` booleans mean "configured and able to serve on demand".
        This carries the granular lifecycle (active / warm_standby /
        cold_evicted / inactive) so a cold-evicted or idle worker is visible
        instead of hidden behind a bare readiness flag.
        """
        worker_states = self.lifecycle.worker_states()
        return {
            "asr": self._state_for("asr", self._asr_configured, worker_states),
            "tts": self._state_for("tts", self._tts_configured, worker_states),
            "streaming": self._state_for(
                "streaming", self._streaming_configured, worker_states
            ),
        }

    @property
    def _asr_configured(self) -> bool:
        return bool(
            self.transcribe is not None
            or self.batch_transcriber is not None
            or self.realtime_asr_factory is not None
            or self.settings.backend_ready
        )

    @property
    def _tts_configured(self) -> bool:
        return self.tts_synthesizer is not None or self.settings.backend_ready

    @property
    def _streaming_configured(self) -> bool:
        return self.realtime_asr_factory is not None

    @staticmethod
    def _state_for(
        name: str, configured: bool, worker_states: dict[str, str]
    ) -> str:
        if not configured:
            return "unconfigured"
        if name in worker_states:
            return worker_states[name]
        return "active"


def build_app_services(settings: Settings, overrides: AppOverrides) -> AppServices:
    """Compose concrete Qwen/NeMo/job components without starting them."""
    metrics = Metrics()
    job_repository = overrides.job_repository
    if job_repository is None and settings.job_spool_dir is not None:
        job_repository = JobRepository(settings.job_spool_dir)

    asr_worker: Qwen3Worker | None = None
    shared_owner: Qwen3SharedWorker | None = None
    transcribe = overrides.transcribe
    batch_transcriber = overrides.batch_transcriber
    if (
        transcribe is None
        and batch_transcriber is None
        and settings.qwen3_model_dir is not None
        and settings.qwen3_python is not None
    ):
        asr_config = Qwen3BackendConfig(
            repository_root=_package_root(),
            python_executable=settings.qwen3_python,
            model_dir=settings.qwen3_model_dir,
            aligner_model_dir=settings.qwen3_aligner_model_dir,
            device=settings.device,
            dtype=resolve_backend_dtype(settings.qwen3_model_dir, settings.dtype),
            cache_limit_mb=settings.mlx_cache_limit_mb,
            memory_limit_mb=settings.mlx_memory_limit_mb,
            timeout_seconds=settings.request_timeout_seconds,
        )
        shared_owner = Qwen3SharedWorker(asr_config, max_sessions=settings.realtime_max_sessions)
        try:
            asr_worker = Qwen3Worker(asr_config, shared_owner=shared_owner)
        except TypeError:
            asr_worker = Qwen3Worker(asr_config)
        transcribe = asr_worker.transcribe
        batch_transcriber = Qwen3BatchTranscriber(worker=asr_worker, model_id=settings.model_id)

    tts_worker: Qwen3TtsWorker | Qwen3TtsCapabilityRouter | None = None
    tts_synthesizer = overrides.tts_synthesizer
    if (
        tts_synthesizer is None
        and settings.qwen3_tts_model_dir is not None
        and settings.qwen3_tts_python is not None
    ):
        tts_python = settings.qwen3_tts_python
        assert tts_python is not None

        active_tts_catalog = active_model_catalog(settings)

        def make_tts_worker(
            model_dir: Path,
            *,
            warmup: bool,
            catalog_variant: str | None,
        ) -> Qwen3TtsWorker:
            raw_variant = catalog_variant or inspect_model(model_dir).variant
            if raw_variant not in {"voice_design", "custom_voice", "base"}:
                raise RuntimeError("backend_identity_mismatch: unsupported TTS model variant")
            variant = cast(TtsModelVariant, raw_variant)
            return Qwen3TtsWorker(
                Qwen3TtsBackendConfig(
                    repository_root=_package_root(),
                    python_executable=tts_python,
                    model_dir=model_dir,
                    model_variant=variant,
                    device=settings.device,
                    dtype=resolve_backend_dtype(
                        model_dir,
                        "float16" if settings.device == "mps" else "float32",
                    ),
                    sample_rate=settings.tts_sample_rate,
                    timeout_seconds=settings.request_timeout_seconds,
                    chunk_ms=settings.tts_chunk_ms,
                    repetition_penalty=settings.tts_repetition_penalty,
                    temperature=settings.tts_temperature,
                    top_p=settings.tts_top_p,
                    warmup_on_start=warmup,
                    cache_limit_mb=settings.mlx_cache_limit_mb,
                    memory_limit_mb=settings.mlx_memory_limit_mb,
                ),
                on_delivery_event=lambda event, amount: metrics.record_tts_delivery_event(
                    event, amount=amount
                ),
            )

        primary_tts_worker = make_tts_worker(
            settings.qwen3_tts_model_dir,
            warmup=settings.tts_warmup_on_start,
            catalog_variant=(
                active_tts_catalog.tts.variant if active_tts_catalog.tts is not None else None
            ),
        )
        clone_tts_worker = (
            make_tts_worker(
                settings.qwen3_tts_clone_model_dir,
                warmup=False,
                catalog_variant=(
                    active_tts_catalog.tts_clone.variant
                    if active_tts_catalog.tts_clone is not None
                    else None
                ),
            )
            if settings.qwen3_tts_clone_model_dir is not None
            else None
        )
        tts_worker = Qwen3TtsCapabilityRouter(
            primary_tts_worker,
            clone=clone_tts_worker,
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
        # 两种逻辑入口共用同一物理模型。模式门限制 batch/streaming 互斥。
        streaming_config = Qwen3StreamingBackendConfig(
            repository_root=_package_root(),
            python_executable=settings.qwen3_python,
            model_dir=settings.qwen3_model_dir,
            aligner_model_dir=settings.qwen3_aligner_model_dir,
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
        if shared_owner is None:
            shared_owner = Qwen3SharedWorker(
                streaming_config, max_sessions=settings.realtime_max_sessions
            )
        try:
            streaming_worker = Qwen3StreamingWorker(streaming_config, shared_owner=shared_owner)
        except TypeError:
            streaming_worker = Qwen3StreamingWorker(streaming_config)
        realtime_asr_factory = NativeRealtimeFactory(
            worker=streaming_worker,
            mode=settings.qwen3_streaming_mode,
            next_session_id=lambda: f"sess_{uuid4().hex}",
            max_sessions=settings.realtime_max_sessions,
        )

    diarization_engine = overrides.diarization_engine
    if diarization_engine is None and settings.diarization_coreml_model_path is not None:
        assert settings.diarization_worker_path is not None
        diarization_engine = CoreMLSortformerEngine(
            model_path=settings.diarization_coreml_model_path,
            executable=settings.diarization_worker_path,
        )

    admission = AdmissionQueue(settings.max_queue_size)
    allow_heavy_overlap, policy_reason = _heavy_overlap_policy(
        settings,
        asr_enabled=(
            transcribe is not None
            or batch_transcriber is not None
            or realtime_asr_factory is not None
        ),
        tts_enabled=tts_synthesizer is not None,
        diarization_enabled=diarization_engine is not None,
    )
    governor = ResourceGovernor(
        settings.governor_limits,
        on_reject=metrics.record_governor_rejection,
        allow_heavy_overlap=allow_heavy_overlap,
        policy_reason=policy_reason,
    )
    if batch_transcriber is None and transcribe is not None:
        batch_transcriber = _CallableBatchTranscriber(transcribe, settings.model_id)
    job_runner: JobRunner | None = None
    if job_repository is not None:
        processor = overrides.job_processor
        if processor is None:
            processor = LocalFileJobProcessor(
                spool_dir=job_repository.spool_dir,
                batch_transcriber=batch_transcriber,
                tts_synthesizer=tts_synthesizer,
                max_upload_bytes=settings.max_upload_bytes,
                max_audio_seconds=settings.max_audio_seconds,
                tts_sample_rate=settings.tts_sample_rate,
                ffmpeg_path=settings.ffmpeg_path,
            )
        job_runner = JobRunner(
            repository=job_repository,
            governor=governor,
            processor=processor,
            deadline_seconds=settings.request_timeout_seconds,
            result_ttl_seconds=settings.job_result_ttl_seconds,
        )

    text_aligner = overrides.text_aligner
    if (
        text_aligner is None
        and asr_worker is not None
        and settings.qwen3_aligner_model_dir is not None
    ):
        text_aligner = FixedTextAligner(asr_worker)

    evictor: WorkerIdleEvictor | None = None
    if settings.worker_idle_timeout_seconds > 0:
        # The CoreML engine creates one Swift child for each session and that
        # child is closed at finish/cancel. It is not a long-lived evictable
        # worker, so only persistent ASR/TTS owners belong in this list.
        evictable: list[EvictableWorker] = [
            w for w in (shared_owner, tts_worker) if w is not None
        ]
        if evictable:
            evictor = WorkerIdleEvictor(
                evictable,
                idle_timeout_seconds=settings.worker_idle_timeout_seconds,
                warm_standby_timeout_seconds=settings.worker_warm_standby_timeout_seconds,
                min_uptime_seconds=settings.worker_min_uptime_seconds,
                on_eviction=metrics.record_eviction,
            )

    asr_owner = getattr(asr_worker, "shared_owner", asr_worker) if asr_worker is not None else None
    streaming_owner = (
        getattr(streaming_worker, "shared_owner", streaming_worker)
        if streaming_worker is not None
        else None
    )
    lifecycle = RuntimeLifecycle(
        repository=job_repository,
        asr=asr_owner,
        tts=tts_worker,
        streaming=streaming_owner,
        runner=job_runner,
        evictor=evictor,
        lazy_load=settings.worker_lazy_load,
        poll_seconds=settings.job_poll_seconds,
        max_job_attempts=settings.max_job_attempts,
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
        text_aligner=text_aligner,
        metrics=metrics,
    )
