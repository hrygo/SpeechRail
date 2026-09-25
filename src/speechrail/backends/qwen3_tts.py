"""Offline subprocess configuration for a local Qwen3-TTS runtime.

This module deliberately contains no vendor import.  The worker process owns
the optional runtime dependency and receives only an already-validated local
snapshot path.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import os
import time
from collections import deque
from collections.abc import AsyncIterator, Callable, Mapping
from contextlib import ExitStack, aclosing
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Literal, cast
from uuid import uuid4

from speechrail.backends.model_identity import observed_runtime_revision
from speechrail.backends.qwen3_tts_stream_client import (
    Qwen3TtsIncrementalSession,
    Qwen3TtsIncrementalSynthesizer,
)
from speechrail.backends.qwen3_tts_worker import TTS_BACKEND_ID
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import VoiceProfile, VoiceStoreUnavailableError
from speechrail.domain.tts_errors import TtsBackendError, from_worker_frame
from speechrail.domain.tts_request import validate_tts_parameters
from speechrail.domain.tts_stream import (
    IncrementalSpeechSession,
    TtsStreamError,
    TtsStreamEvent,
    TtsStreamOptions,
)
from speechrail.domain.tts_timing import TtsTimingSidecar
from speechrail.runtime.busy import BusyReason
from speechrail.runtime.registry import (
    TTS_RUNTIME_ROLES,
    VOICE_DESIGN_ROLE,
    engine_variant_for_role,
)
from speechrail.runtime.worker_process import (
    AsyncFramedWorkerProcess,
    WorkerProcessSpec,
    offline_environment,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, ProtocolError

if TYPE_CHECKING:
    from speechrail.backends.qwen3_voice_binding import VoiceBinding
    from speechrail.config.model_catalog import ModelRole

DeliveryEventRecorder = Callable[[str, int], None]
TtsModelVariant = Literal["voice_design", "custom_voice", "base"]


class TtsWorkerBusyError(RuntimeError):
    """A lifecycle operation was refused because an utterance still owns the worker."""

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.code = "backend_busy"
        self.busy_reason = BusyReason.BACKEND_TRANSITION


@dataclass(frozen=True, slots=True)
class Qwen3TtsBackendConfig:
    repository_root: Path
    python_executable: Path
    model_dir: Path
    model_variant: TtsModelVariant
    device: Literal["mps", "cpu"]
    dtype: Literal["float16", "float32", "int8"] = "float16"
    sample_rate: int = 24_000
    timeout_seconds: float = 120.0
    chunk_ms: int = 100
    repetition_penalty: float = 1.25
    temperature: float = 0.85
    top_p: float = 0.95
    warmup_on_start: bool = True
    cache_limit_mb: int = 256
    memory_limit_mb: int = 0

    def __post_init__(self) -> None:
        repository_root = self.repository_root.resolve(strict=True)
        python_executable = self.python_executable.absolute()
        if not python_executable.is_file() or not os.access(python_executable, os.X_OK):
            raise ValueError("python_executable must be an executable local file")
        if not self.model_dir.is_absolute():
            raise ValueError("model snapshot must be an absolute path")
        model_dir = self.model_dir.resolve(strict=True)
        if model_dir.is_relative_to(repository_root):
            raise ValueError("model snapshot must be outside repository")
        if not model_dir.is_dir() or not (model_dir / "config.json").is_file():
            raise ValueError("model snapshot is incomplete")
        if self.device == "mps" and self.dtype not in {"float16", "int8"}:
            raise ValueError("MPS requires float16 or int8")
        if self.device == "cpu" and self.dtype not in {"float32", "int8"}:
            raise ValueError("CPU requires float32 or int8")
        if self.sample_rate != 24_000:
            raise ValueError("Qwen3-TTS public PCM profile requires 24000 Hz")
        if self.timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        if not 10 <= self.chunk_ms <= 2_000:
            raise ValueError("chunk_ms must be between 10 and 2000")
        if not 1.0 <= self.repetition_penalty <= 2.0:
            raise ValueError("repetition_penalty must be between 1.0 and 2.0")
        if not 0.0 < self.temperature <= 2.0:
            raise ValueError("temperature must be between 0 and 2")
        if not 0.0 < self.top_p <= 1.0:
            raise ValueError("top_p must be between 0 and 1")
        if self.cache_limit_mb < 0 or self.memory_limit_mb < 0:
            raise ValueError("memory and cache limits must be non-negative")
        object.__setattr__(self, "repository_root", repository_root)
        object.__setattr__(self, "python_executable", python_executable)
        object.__setattr__(self, "model_dir", model_dir)

    def command(self) -> list[str]:
        command = [
            str(self.python_executable),
            "-m",
            "speechrail.backends.qwen3_tts_worker",
            "--model-dir",
            str(self.model_dir),
            "--device",
            self.device,
            "--sample-rate",
            str(self.sample_rate),
            "--chunk-ms",
            str(self.chunk_ms),
            "--repetition-penalty",
            str(self.repetition_penalty),
            "--temperature",
            str(self.temperature),
            "--top-p",
            str(self.top_p),
            "--cache-limit-mb",
            str(self.cache_limit_mb),
        ]
        if self.memory_limit_mb > 0:
            command.extend(["--memory-limit-mb", str(self.memory_limit_mb)])
        if not self.warmup_on_start:
            command.append("--no-warmup")
        return command


    def worker_spec(self) -> WorkerProcessSpec:
        return WorkerProcessSpec(
            command=tuple(self.command()),
            cwd=self.repository_root,
            env=offline_environment(self.repository_root),
            io_timeout_seconds=self.timeout_seconds,
        )


class Qwen3TtsWorker:
    """One supervised local Qwen3-TTS worker behind the public TTS port.

    The worker owns all vendor imports and model weights.  This parent process
    speaks only the private framed protocol. Leased recipes and explicit preview
    instructions stay on that local pipe; they are not discovery or log fields. The
    profile policy stays here: one ready handshake with backend/device/dtype/
    sample-rate identity, one private response ID per synthesis, a strictly
    ordered ``audio* → completed`` stream, and abort on any unfinished stream.
    """

    def __init__(
        self,
        config: Qwen3TtsBackendConfig,
        *,
        on_delivery_event: DeliveryEventRecorder | None = None,
    ) -> None:
        self.config = config
        self._transport = AsyncFramedWorkerProcess(config.worker_spec())
        self._lock = asyncio.Lock()
        self._started = False
        self._supports_profile_snapshot = False
        self._stream_protocol: int | None = None
        # One incremental utterance owns this slot until its terminal outcome.
        # Complete-text synthesis waits here instead of racing the stream's
        # single receive dispatcher on the same worker transport.
        self._incremental_slot = asyncio.Lock()
        self._epoch: int = 0
        self._fallback_abort_count = 0
        self._reload_count = 0
        self._on_delivery_event = on_delivery_event
        self._timing_sidecars: dict[str, TtsTimingSidecar] = {}
        # Utterances this parent already opened on this worker.  A stream can be
        # torn down before its terminal is read (client disconnect, cancelled
        # teardown), so the frames of a *known* utterance are stale by
        # definition and must never fail the next one.
        self._known_stream_ids: deque[str] = deque(maxlen=8)
        self.last_active: float = time.monotonic()
        self.model_variant: str = config.model_variant
        self._runtime_revision: str | None = None
        self._worker_attempt_id: str | None = None

    @property
    def alive(self) -> bool:
        return self._transport.alive

    @property
    def ready(self) -> bool:
        """Return whether the supervised worker can accept another request."""
        return self._started and self._transport.alive

    @property
    def runtime_revision(self) -> str | None:
        """Return the observed identity of the currently ready worker, if known."""
        return self._runtime_revision if self.ready else None

    @property
    def supports_incremental_stream(self) -> bool:
        """Whether this worker negotiated the private append-only protocol."""

        return self._stream_protocol == 1

    @property
    def active_incremental_stream(self) -> bool:
        """Whether one utterance currently owns this worker, including while it waits."""

        return self._incremental_slot.locked()

    @property
    def lifecycle_stats(self) -> dict[str, int | bool]:
        """Expose path-free cancellation evidence for local diagnostics.

        The batch path serves one synchronous generation at a time and has no
        verified cooperative cancellation checkpoint, so a cancelled batch
        stream uses the bounded abort fallback.  The negotiated incremental path
        does check cancellation between bounded model steps.  Keep the counters
        explicit so a capability change can be measured instead of being assumed
        from a successful cancellation response.
        """

        return {
            # Only the negotiated incremental path has a verified cooperative
            # cancellation checkpoint; the batch path still aborts.
            "cooperative_cancel_supported": self._stream_protocol == 1,
            "fallback_abort_count": self._fallback_abort_count,
            "reload_count": self._reload_count,
        }

    async def start(self) -> None:
        async with self._lock:
            await self._start_locked()

    async def _start_locked(self) -> None:
        if self._started:
            return
        is_reload = self._epoch > 0
        self._supports_profile_snapshot = False
        self._stream_protocol = None
        self._runtime_revision = None
        self._worker_attempt_id = f"tts_attempt_{uuid4().hex}"
        try:
            await self._transport.start()
            await self._transport.send(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "start",
                    "model_dir": str(self.config.model_dir),
                    "device": self.config.device,
                    "sample_rate": self.config.sample_rate,
                }
            )
            ready = await self._receive_profile_frame()
            if ready.get("type") != "ready" or ready.get("model_loaded") is not True:
                if ready.get("type") == "error":
                    raise from_worker_frame(
                        ready,
                        fallback_code="worker_start_failed",
                        stage="initialize",
                        worker_attempt_id=self._worker_attempt_id,
                    )
                raise RuntimeError("worker_start_failed")
            if (
                ready.get("backend") != TTS_BACKEND_ID
                or ready.get("device") != self.config.device
                or ready.get("dtype") != self.config.dtype
                or ready.get("sample_rate") != self.config.sample_rate
                or ready.get("model_variant") != self.config.model_variant
            ):
                raise TtsBackendError(
                    "backend_identity_mismatch",
                    stage="initialize",
                    public_code="tts_initialization_failed",
                    retryable=False,
                )
            snapshot_version = ready.get("profile_snapshot_version")
            self._supports_profile_snapshot = (
                type(snapshot_version) is int and snapshot_version == 1
            )
            stream_protocol = ready.get("tts_stream_protocol")
            self._stream_protocol = (
                stream_protocol
                if type(stream_protocol) is int and stream_protocol == 1
                else None
            )
            self._runtime_revision = observed_runtime_revision(ready)
            self._started = True
            self._epoch += 1
            if is_reload:
                self._reload_count += 1
                self._record_delivery_event("reload")
            self.last_active = time.monotonic()
        except BaseException:
            self._runtime_revision = None
            await self._transport.abort()
            raise

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        """Yield ordered public PCM chunks while serializing private worker access."""

        async def stream() -> AsyncIterator[AudioChunk]:
            from speechrail.backends.qwen3_voice_binding import resolve_binding
            from speechrail.domain.tts import get_voice_registry

            # Keep the immutable clone reference alive until the worker has
            # completed (or the abort/reap path has finished).  The registry
            # lock itself is held only for the short snapshot/refcount steps.
            with get_voice_registry().lease_profile(
                request.voice, expected_revision=request.expected_voice_revision
            ) as profile:
                binding = resolve_binding(
                    self.model_variant,
                    request.voice,
                    profile=profile,
                )
                validated = validate_tts_parameters(
                    model_variant=cast(TtsModelVariant, self.model_variant),
                    is_clone=binding.is_clone,
                    speed=request.speed,
                    language=request.language,
                    instruction=request.instruction,
                    seed=request.seed,
                )
                async with self._incremental_slot, self._lock:
                    if not self._started:
                        await self._start_locked()
                    epoch = self._epoch
                    self.last_active = time.monotonic()
                    response_id = f"resp_{uuid4().hex}"
                    frame_payload: dict[str, object] = {
                        "version": PROTOCOL_VERSION,
                        "type": "synthesize",
                        "request_id": response_id,
                        "text": request.text,
                        "voice": request.voice,
                        "speed": request.speed,
                        "language": request.language,
                    }
                    if request.instruction is not None:
                        frame_payload["instruction"] = request.instruction
                    if request.seed is not None:
                        frame_payload["seed"] = request.seed
                    if request.timing_mode is not None:
                        frame_payload["timing_mode"] = request.timing_mode
                    frame_payload["speed"] = validated.speed
                    frame_payload["language"] = validated.language
                    if (
                        self.model_variant == "voice_design" and request.instruction is None
                        and not self._supports_profile_snapshot
                    ):
                        raise RuntimeError("worker_profile_snapshot_unsupported")
                    if not binding.is_clone and self._supports_profile_snapshot:
                        # The child must not re-resolve a mutable instruction profile
                        # after this lease or between acoustic text chunks.
                        frame_payload["voice_profile"] = {
                            "id": profile.id,
                            "mode": profile.mode,
                            "instruction": profile.instruction,
                            "seed": profile.seed,
                            "temperature": profile.temperature,
                        }
                    if binding.is_clone and binding.ref_audio_path:
                        frame_payload["ref_audio"] = binding.ref_audio_path
                        frame_payload["ref_text"] = binding.ref_text or ""
                    await self._transport.send(frame_payload)
                    expected_chunk_index = 0
                    completed = False
                    try:
                        while True:
                            frame = await self._receive_profile_frame()
                            if frame.get("request_id") != response_id:
                                raise TtsBackendError(
                                    "worker_response_id_mismatch",
                                    stage="deliver",
                                    public_code="tts_transport_failed",
                                    retryable=False,
                                    request_id=response_id,
                                    worker_attempt_id=self._worker_attempt_id,
                                )
                            if frame.get("type") == "completed":
                                self._record_completion_stats(frame)
                                if request.timing_mode == "chunk":
                                    self._store_timing_sidecar(response_id, frame)
                                completed = True
                                return
                            if frame.get("type") == "error":
                                if frame.get("code") == "voice_store_unavailable":
                                    raise VoiceStoreUnavailableError(
                                        "custom voice storage is unavailable"
                                    )
                                raise from_worker_frame(
                                    frame,
                                    fallback_code="worker_inference_error",
                                    stage="infer",
                                    request_id=response_id,
                                    worker_attempt_id=self._worker_attempt_id,
                                )
                            if frame.get("type") != "audio":
                                raise TtsBackendError(
                                    "worker_frame_invalid",
                                    stage="deliver",
                                    public_code="tts_transport_failed",
                                    retryable=False,
                                    request_id=response_id,
                                    worker_attempt_id=self._worker_attempt_id,
                                )
                            chunk_index = frame.get("chunk_index")
                            raw_binary = frame.get("_binary")
                            encoded = frame.get("pcm_b64")
                            audio: bytes
                            if isinstance(raw_binary, bytes) and raw_binary:
                                audio = raw_binary
                            elif isinstance(encoded, str):
                                try:
                                    audio = base64.b64decode(encoded, validate=True)
                                except (ValueError, TypeError) as exc:
                                    raise TtsBackendError(
                                        "worker_audio_frame_invalid",
                                        stage="decode",
                                        public_code="output_invalid",
                                        retryable=False,
                                        request_id=response_id,
                                        worker_attempt_id=self._worker_attempt_id,
                                    ) from exc
                            else:
                                raise TtsBackendError(
                                    "worker_audio_frame_invalid",
                                    stage="decode",
                                    public_code="output_invalid",
                                    retryable=False,
                                    request_id=response_id,
                                    worker_attempt_id=self._worker_attempt_id,
                                )
                            if (
                                chunk_index != expected_chunk_index
                                or not audio
                                or len(audio) % 2
                            ):
                                raise TtsBackendError(
                                    "worker_audio_frame_invalid",
                                    stage="decode",
                                    public_code="output_invalid",
                                    retryable=False,
                                    request_id=response_id,
                                    worker_attempt_id=self._worker_attempt_id,
                                )
                            self.last_active = time.monotonic()
                            yield AudioChunk(
                                response_id=response_id,
                                chunk_index=expected_chunk_index,
                                audio=audio,
                            )
                            expected_chunk_index += 1
                    finally:
                        self.last_active = time.monotonic()
                        if not completed and self._epoch == epoch:
                            self._started = False
                            self._runtime_revision = None
                            self._fallback_abort_count += 1
                            self._record_delivery_event("abort_fallback")
                            await self._transport.abort()

        return stream()

    async def open_incremental_stream(
        self,
        options: TtsStreamOptions,
    ) -> IncrementalSpeechSession:
        """Open one append-only utterance while holding its worker and voice lease.

        The exclusive incremental slot is held for the whole utterance, so a
        complete-text synthesis either finishes before this call or waits until
        the stream reaches its single terminal outcome.  The voice lease keeps a
        clone reference alive and rejects a revision change that happened after
        the caller captured ``expected_voice_revision``.
        """

        from speechrail.backends.qwen3_voice_binding import resolve_binding
        from speechrail.domain.tts import get_voice_registry

        await self._incremental_slot.acquire()
        inner: Qwen3TtsIncrementalSession | None = None
        epoch: int | None = None
        stack = contextlib.ExitStack()
        try:
            profile = stack.enter_context(
                get_voice_registry().lease_profile(
                    options.voice,
                    expected_revision=options.expected_voice_revision,
                )
            )
            binding = resolve_binding(self.model_variant, options.voice, profile=profile)
            if not binding.supports_incremental_stream:
                raise TtsStreamError(
                    "tts_streaming_unsupported",
                    "the resolved voice binding has no verified incremental path",
                )
            if binding.is_clone and (
                not binding.ref_audio_path or not (binding.ref_text or "").strip()
            ):
                raise TtsStreamError(
                    "tts_backend_failed",
                    "the clone voice has no usable reference audio and text",
                )
            validated = validate_tts_parameters(
                model_variant=cast(TtsModelVariant, self.model_variant),
                is_clone=binding.is_clone,
                speed=options.speed,
                language=options.language,
                instruction=None,
                seed=None,
            )
            start_fields = self._incremental_start_fields(
                binding,
                profile,
                speed=validated.speed,
                language=validated.language,
            )
            async with self._lock:
                if not self._started:
                    await self._start_locked()
                if not self.supports_incremental_stream:
                    raise TtsStreamError(
                        "tts_streaming_unsupported",
                        "the TTS worker did not negotiate the incremental stream protocol",
                    )
                epoch = self._epoch
                synthesizer = Qwen3TtsIncrementalSynthesizer(
                    self._transport,
                    stream_protocol=self._stream_protocol,
                )
                stale_request_ids = self._remember_stream_id(options.request_id)
                inner = await synthesizer.open_stream(
                    options,
                    start_fields=start_fields,
                    stale_request_ids=stale_request_ids,
                )
                session = _LeasedTtsStreamSession(self, inner, stack, epoch=epoch)
                self.last_active = time.monotonic()
                return session
        except BaseException:
            if inner is not None:
                with contextlib.suppress(Exception):
                    await inner.close()
            stack.close()
            self._release_incremental_slot()
            if epoch is not None and not self._transport.alive:
                # A failed open can reap the child through the client's abort
                # fallback.  Leaving the worker marked started would make every
                # later request write into a dead pipe, so invalidate it the way
                # the batch path does and let the next request restart it.
                await self._invalidate_after_abort(epoch)
            raise

    def _incremental_start_fields(
        self,
        binding: VoiceBinding,
        profile: VoiceProfile,
        *,
        speed: float,
        language: str,
    ) -> dict[str, object]:
        """Freeze the child-side conditioning for one incremental utterance."""

        fields: dict[str, object] = {"speed": speed, "language": language}
        if binding.is_clone:
            fields["ref_audio"] = binding.ref_audio_path
            fields["ref_text"] = binding.ref_text or ""
        elif self._supports_profile_snapshot:
            # The child must not re-resolve a mutable instruction profile after
            # this lease or between acoustic text chunks.
            fields["voice_profile"] = {
                "id": profile.id,
                "mode": profile.mode,
                "instruction": profile.instruction,
                "seed": profile.seed,
                "temperature": profile.temperature,
            }
        return fields

    async def _invalidate_after_abort(self, epoch: int) -> None:
        """Mark a forcibly reaped worker not-ready, mirroring the batch path."""

        async with self._lock:
            if self._epoch != epoch:
                return
            self._started = False
            self._runtime_revision = None
            self._fallback_abort_count += 1
            self._record_delivery_event("abort_fallback")

    def _remember_stream_id(self, request_id: str) -> frozenset[str]:
        """Record one utterance and return every other one already seen here."""

        stale = frozenset(
            identifier for identifier in self._known_stream_ids if identifier != request_id
        )
        while request_id in self._known_stream_ids:
            self._known_stream_ids.remove(request_id)
        self._known_stream_ids.append(request_id)
        return stale

    def _release_incremental_slot(self) -> None:
        """Return the single incremental slot; exactly one holder releases it."""

        if self._incremental_slot.locked():
            self._incremental_slot.release()

    def _store_timing_sidecar(
        self,
        response_id: str,
        frame: dict[str, object],
    ) -> None:
        raw = frame.get("timing_sidecar")
        if not isinstance(raw, dict):
            return
        try:
            sidecar = TtsTimingSidecar.model_validate(raw)
        except ValueError:
            return
        self._timing_sidecars[response_id] = sidecar
        while len(self._timing_sidecars) > 64:
            self._timing_sidecars.pop(next(iter(self._timing_sidecars)))

    def take_timing_sidecar(self, response_id: str) -> TtsTimingSidecar | None:
        """Consume one completed timing result without affecting audio delivery."""

        return self._timing_sidecars.pop(response_id, None)

    def _record_completion_stats(self, frame: dict[str, object]) -> None:
        raw = frame.get("delivery_stats")
        if not isinstance(raw, dict):
            return
        names = {
            "planner_chunks": "planner_chunk",
            "reference_cache_hits": "reference_cache_hit",
            "reference_cache_misses": "reference_cache_miss",
            "reference_cache_evictions": "reference_cache_eviction",
            "clone_loudness_requests": "clone_loudness_request",
            "clone_loudness_calibrated": "clone_loudness_calibrated",
            "clone_loudness_peak_ceiling": "clone_loudness_peak_ceiling",
            "float_overrange_chunks": "float_overrange",
        }
        for field, event in names.items():
            amount = raw.get(field)
            if isinstance(amount, int) and not isinstance(amount, bool) and 0 < amount <= 10_000:
                self._record_delivery_event(event, amount)

    def _record_delivery_event(self, event: str, amount: int = 1) -> None:
        callback = self._on_delivery_event
        if callback is not None:
            callback(event, amount)

    async def _receive_profile_frame(self) -> dict[str, object]:
        try:
            return await self._transport.receive()
        except ProtocolError as exc:
            raise TtsBackendError(
                "worker_frame_invalid",
                stage="deliver",
                public_code="tts_transport_failed",
                retryable=False,
                worker_attempt_id=self._worker_attempt_id,
            ) from exc

    async def trim_memory(self) -> None:
        # A trim frame arriving mid-utterance would be misread as a stream
        # control frame by the model thread; skip it until the stream closes.
        if self.alive and not self._incremental_slot.locked():
            with contextlib.suppress(Exception):
                await self._transport.send({"version": PROTOCOL_VERSION, "type": "trim_memory"})

    async def close(self) -> None:
        """Terminate the worker, waiting for any active stream to finish first."""
        async with self._lock:
            self._started = False
            self._runtime_revision = None
            self._epoch += 1
            await self._transport.abort()


class _LeasedTtsStreamSession:
    """One parent-side incremental utterance plus its worker and voice lease.

    Releasing the exclusive worker slot and the voice lease is idempotent and
    happens exactly once, on the terminal event, cancel or close whichever comes
    first.  A worker that had to be aborted is marked not-ready so the next
    request restarts it through the existing controlled path.
    """

    def __init__(
        self,
        worker: Qwen3TtsWorker,
        inner: Qwen3TtsIncrementalSession,
        lease: ExitStack,
        *,
        epoch: int,
    ) -> None:
        self._worker = worker
        self._inner = inner
        self._lease = lease
        self._epoch = epoch
        self._released = False

    @property
    def options(self) -> TtsStreamOptions:
        return self._inner.options

    @property
    def used_abort_fallback(self) -> bool:
        """Whether this utterance had to reap its worker instead of stopping it."""

        return self._inner.used_abort_fallback

    async def append_text(self, sequence: int, text: str) -> None:
        await self._inner.append_text(sequence, text)

    async def finish_text(self, last_sequence: int) -> None:
        await self._inner.finish_text(last_sequence)

    async def events(self) -> AsyncIterator[TtsStreamEvent]:
        async for event in self._inner.events():
            if event.terminal is not None:
                await self._release()
            yield event
            if event.terminal is not None:
                return

    async def cancel(self) -> None:
        try:
            await self._inner.cancel()
        finally:
            await self._release()

    async def close(self) -> None:
        await self._release()

    async def _release(self) -> None:
        if self._released:
            return
        self._released = True
        try:
            await self._inner.close()
        finally:
            try:
                if self._inner.used_abort_fallback:
                    await self._worker._invalidate_after_abort(self._epoch)
            finally:
                self._worker._release_incremental_slot()
                self._lease.__exit__(None, None, None)


class Qwen3TtsCapabilityRouter:
    """Route TTS by plan role through independent, lifecycle-owned workers.

    Workers are keyed by the plan role they serve (``tts_custom_voice`` or
    ``tts_base``); a worker whose vendor variant does not match its role is
    rejected at construction so a role can never silently serve another model's
    weights.  VoiceDesign is deliberately absent from the runtime routes: the
    design studio owns that model on a separate path, and ordinary synthesis
    and the incremental stream must never reach it.  Each worker owns its
    request lock, so the roles may stay resident and synthesize concurrently
    while lifecycle operations stay serialized.
    """

    def __init__(self, workers: Mapping[str, Qwen3TtsWorker]) -> None:
        resolved: dict[str, Qwen3TtsWorker] = {}
        for role, worker in workers.items():
            try:
                expected_variant = engine_variant_for_role(cast("ModelRole", role))
            except ValueError as exc:
                raise ValueError(f"unsupported TTS plan role: {role}") from exc
            if worker.model_variant != expected_variant:
                raise ValueError(
                    "backend_identity_mismatch: plan role "
                    f"{role} requires the {expected_variant} TTS variant, "
                    f"got {worker.model_variant}"
                )
            resolved[role] = worker
        self._workers = resolved
        self._capability_lock = asyncio.Lock()

    @property
    def _worker_list(self) -> tuple[Qwen3TtsWorker, ...]:
        return tuple(self._workers.values())

    @property
    def resident_worker_count(self) -> int:
        """Return the maximum number of TTS workers this router may keep warm."""

        return len(self._workers)

    @property
    def active_incremental_streams(self) -> int:
        """Return how many utterances currently hold a worker, waiting text included."""

        return sum(
            1
            for worker in self._worker_list
            if getattr(worker, "active_incremental_stream", False)
        )

    @property
    def alive(self) -> bool:
        return any(worker.alive for worker in self._worker_list)

    @property
    def ready(self) -> bool:
        return any(worker.ready for worker in self._worker_list)

    @property
    def last_active(self) -> float:
        if not self._workers:
            return 0.0
        return max(worker.last_active for worker in self._worker_list)

    @property
    def model_variant(self) -> str | None:
        for role in TTS_RUNTIME_ROLES:
            worker = self._workers.get(role)
            if worker is not None and worker.ready:
                return worker.model_variant
        return None

    @property
    def warm_roles(self) -> tuple[str, ...]:
        """Return the plan roles whose workers are resident and ready."""

        return tuple(
            role for role, worker in self._workers.items() if worker.ready
        )

    @property
    def warm_capabilities(self) -> tuple[str, ...]:
        """Return resident plan roles without loading any model."""

        return self.warm_roles

    @property
    def warm_capability(self) -> str | None:
        """Return a compact resident-capability summary for health diagnostics."""

        capabilities = self.warm_roles
        if len(capabilities) > 1:
            return "both"
        return capabilities[0] if capabilities else None

    @property
    def lifecycle_stats(self) -> dict[str, object]:
        stats = [worker.lifecycle_stats for worker in self._worker_list]
        return {
            "cooperative_cancel_supported": bool(
                stats
                and all(item["cooperative_cancel_supported"] for item in stats)
            ),
            "fallback_abort_count": sum(
                int(item["fallback_abort_count"]) for item in stats
            ),
            "reload_count": sum(int(item["reload_count"]) for item in stats),
            "warm_capability": self.warm_capability,
            "warm_capabilities": list(self.warm_capabilities),
        }

    async def start(self) -> None:
        """Start ordinary runtime roles; VoiceDesign stays lazy for design jobs."""
        async with self._capability_lock:
            workers = tuple(
                self._workers[role]
                for role in TTS_RUNTIME_ROLES
                if role in self._workers
            )
            if all(worker.ready for worker in workers):
                return
            try:
                for worker in workers:
                    if not worker.ready:
                        await worker.start()
            except BaseException:
                # Do not leave a partially initialized Quality router with one
                # model warm and the other unavailable.
                for worker in reversed(workers):
                    with contextlib.suppress(BaseException):
                        if worker.alive or worker.ready:
                            await worker.close()
                raise

    @property
    def design_ready(self) -> bool:
        """Return whether the lazy VoiceDesign worker is already resident."""

        worker = self._workers.get(VOICE_DESIGN_ROLE)
        return worker is not None and worker.ready

    def resource_key_for_voice(self, voice: str) -> str:
        """Map a validated public voice to the plan-role lane that serves it.

        A design-only voice has no runtime lane; it keeps the conservative
        wildcard ``tts`` key because the request itself is rejected before it
        reaches a worker.
        """

        from speechrail.domain.tts import get_voice_registry

        profile = get_voice_registry().get_profile(voice)
        if profile.mode == "clone":
            return "tts_base"
        if profile.mode == "system":
            return "tts_custom_voice"
        return "tts"

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        """Return the ready worker identity for the voice's selected lane."""
        from speechrail.domain.tts import get_voice_registry

        profile = get_voice_registry().get_profile(voice)
        role = profile.runtime_role
        if role is None:
            return None
        worker = self._workers.get(role)
        return worker.runtime_revision if worker is not None else None

    def _require_runtime_worker(self, voice: str) -> tuple[str, Qwen3TtsWorker]:
        """Resolve one voice to its plan role and resident worker, or fail closed."""

        from speechrail.domain.tts import get_voice_registry
        from speechrail.domain.tts_routing import TtsRouteError, route_role_for_voice

        profile = get_voice_registry().get_profile(voice)
        try:
            role = route_role_for_voice(profile)
        except TtsRouteError as exc:
            raise RuntimeError(exc.code) from None
        worker = self._workers.get(role)
        if worker is None:
            if role == "tts_base":
                raise RuntimeError("voice_clone_base_model_unavailable")
            raise RuntimeError("tts_custom_voice_model_unavailable")
        return role, worker

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def stream() -> AsyncIterator[AudioChunk]:
            _, worker = self._require_runtime_worker(request.voice)
            # Closing the router's iterator must also close the owning worker's
            # iterator, so the worker slot is released by the caller's teardown
            # instead of waiting for garbage collection.
            async with aclosing(worker.synthesize(request)) as source:
                async for chunk in source:
                    yield chunk

        return stream()

    def synthesize_design(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        """Run one VoiceDesign candidate task; never used by normal synthesis."""

        async def stream() -> AsyncIterator[AudioChunk]:
            worker = self._workers.get(VOICE_DESIGN_ROLE)
            if worker is None:
                raise RuntimeError("voice_design_model_unavailable")
            async with aclosing(worker.synthesize(request)) as source:
                async for chunk in source:
                    yield chunk

        return stream()

    async def open_incremental_stream(
        self,
        options: TtsStreamOptions,
    ) -> IncrementalSpeechSession:
        """Route one incremental utterance to the lane that owns its voice."""

        try:
            _, worker = self._require_runtime_worker(options.voice)
        except RuntimeError as exc:
            raise TtsStreamError("tts_streaming_unsupported", str(exc)) from None
        return await worker.open_incremental_stream(options)

    def take_timing_sidecar(self, response_id: str) -> TtsTimingSidecar | None:
        """Consume timing metadata from whichever worker served the response."""

        for worker in self._worker_list:
            sidecar = worker.take_timing_sidecar(response_id)
            if sidecar is not None:
                return sidecar
        return None

    async def evict_warm_capability(self) -> None:
        """Release all TTS workers before a heavyweight validation phase or idle eviction.

        An active incremental utterance owns its worker until its single terminal
        outcome, so a group-level eviction reports busy instead of cutting the
        session off mid-sentence.
        """
        if self.active_incremental_streams:
            raise TtsWorkerBusyError("an incremental TTS utterance still owns a worker")
        async with self._capability_lock:
            for worker in self._worker_list:
                if worker.alive or worker.ready:
                    await worker.close()

    async def trim_memory(self) -> None:
        for worker in self._worker_list:
            await worker.trim_memory()

    async def close(self) -> None:
        async with self._capability_lock:
            first_error: BaseException | None = None
            for worker in self._worker_list:
                try:
                    await worker.close()
                except BaseException as exc:
                    if first_error is None:
                        first_error = exc
            if first_error is not None:
                raise first_error
