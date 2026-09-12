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
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from uuid import uuid4

from speechrail.backends.qwen3_tts_worker import TTS_BACKEND_ID
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import VoiceStoreUnavailableError
from speechrail.runtime.worker_process import (
    AsyncFramedWorkerProcess,
    WorkerProcessSpec,
    error_frame_message,
    offline_environment,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, ProtocolError

DeliveryEventRecorder = Callable[[str, int], None]
TtsModelVariant = Literal["voice_design", "custom_voice", "base"]


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
    speaks only the private framed protocol and never passes a model ID, URL,
    instruction, or arbitrary voice description across that boundary.  The
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
        self._epoch: int = 0
        self._fallback_abort_count = 0
        self._reload_count = 0
        self._on_delivery_event = on_delivery_event
        self.last_active: float = time.monotonic()
        self.model_variant: str = config.model_variant

    @property
    def alive(self) -> bool:
        return self._transport.alive

    @property
    def ready(self) -> bool:
        """Return whether the supervised worker can accept another request."""
        return self._started and self._transport.alive

    @property
    def lifecycle_stats(self) -> dict[str, int | bool]:
        """Expose path-free cancellation evidence for local diagnostics.

        The current vendor worker serves one synchronous generation at a time
        and has no verified cooperative cancellation checkpoint.  A cancelled
        incomplete stream therefore uses the bounded abort fallback.  Keep the
        counters explicit so a future vendor capability change can be measured
        instead of being assumed from a successful cancellation response.
        """

        return {
            "cooperative_cancel_supported": False,
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
                raise RuntimeError(error_frame_message(ready, "worker_start_failed"))
            if (
                ready.get("backend") != TTS_BACKEND_ID
                or ready.get("device") != self.config.device
                or ready.get("dtype") != self.config.dtype
                or ready.get("sample_rate") != self.config.sample_rate
                or ready.get("model_variant") != self.config.model_variant
            ):
                raise RuntimeError("backend_identity_mismatch")
            self._started = True
            self._epoch += 1
            if is_reload:
                self._reload_count += 1
                self._record_delivery_event("reload")
            self.last_active = time.monotonic()
        except BaseException:
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
            with get_voice_registry().lease_profile(request.voice) as profile:
                async with self._lock:
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
                    binding = resolve_binding(
                        self.model_variant,
                        request.voice,
                        profile=profile,
                    )
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
                                raise RuntimeError("worker_response_id_mismatch")
                            if frame.get("type") == "completed":
                                self._record_completion_stats(frame)
                                completed = True
                                return
                            if frame.get("type") == "error":
                                if frame.get("code") == "voice_store_unavailable":
                                    raise VoiceStoreUnavailableError(
                                        "custom voice storage is unavailable"
                                    )
                                raise RuntimeError(
                                    error_frame_message(frame, "worker_inference_error")
                                )
                            if frame.get("type") != "audio":
                                raise RuntimeError("worker_frame_invalid")
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
                                    raise RuntimeError("worker_audio_frame_invalid") from exc
                            else:
                                raise RuntimeError("worker_audio_frame_invalid")
                            if (
                                chunk_index != expected_chunk_index
                                or not audio
                                or len(audio) % 2
                            ):
                                raise RuntimeError("worker_audio_frame_invalid")
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
                            self._fallback_abort_count += 1
                            self._record_delivery_event("abort_fallback")
                            await self._transport.abort()

        return stream()

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
            raise RuntimeError("worker_frame_invalid") from exc

    async def trim_memory(self) -> None:
        if self.alive:
            with contextlib.suppress(Exception):
                await self._transport.send({"version": PROTOCOL_VERSION, "type": "trim_memory"})

    async def close(self) -> None:
        """Terminate the worker, waiting for any active stream to finish first."""
        async with self._lock:
            self._started = False
            self._epoch += 1
            await self._transport.abort()

class Qwen3TtsCapabilityRouter:
    """Route TTS capabilities through one mutually-exclusive model slot.

    Normal synthesis uses the preset's primary VoiceDesign/CustomVoice worker.
    Registered clone voices use the Quality-only Base worker.  The router keeps
    Base lazy and swaps workers on capability changes so both large TTS models
    are never intentionally resident at the same time.
    """

    def __init__(
        self,
        primary: Qwen3TtsWorker,
        *,
        clone: Qwen3TtsWorker | None = None,
    ) -> None:
        self.primary = primary
        self.clone = clone
        self._capability_lock = asyncio.Lock()

    @property
    def alive(self) -> bool:
        return self.primary.alive or bool(self.clone is not None and self.clone.alive)

    @property
    def ready(self) -> bool:
        return self.primary.ready or bool(self.clone is not None and self.clone.ready)

    @property
    def last_active(self) -> float:
        values = [self.primary.last_active]
        if self.clone is not None:
            values.append(self.clone.last_active)
        return max(values)

    @property
    def model_variant(self) -> str | None:
        return self.primary.model_variant

    @property
    def warm_capability(self) -> str | None:
        """Return the currently resident TTS capability without loading a model."""
        primary_ready = self.primary.ready
        clone_ready = bool(self.clone is not None and self.clone.ready)
        if primary_ready and clone_ready:
            # This should be unreachable under the capability lock, but exposing
            # it makes an invariant violation visible to health diagnostics.
            return "conflict"
        if clone_ready:
            return "voice_clone"
        if primary_ready:
            return "voice_design" if self.primary.model_variant == "voice_design" else "tts"
        return None

    @property
    def lifecycle_stats(self) -> dict[str, int | bool | str | None]:
        primary = self.primary.lifecycle_stats
        clone = self.clone.lifecycle_stats if self.clone is not None else None
        return {
            "cooperative_cancel_supported": bool(
                primary["cooperative_cancel_supported"]
                and (clone is None or clone["cooperative_cancel_supported"])
            ),
            "fallback_abort_count": int(primary["fallback_abort_count"])
            + (int(clone["fallback_abort_count"]) if clone is not None else 0),
            "reload_count": int(primary["reload_count"])
            + (int(clone["reload_count"]) if clone is not None else 0),
            "warm_capability": self.warm_capability,
        }

    async def start(self) -> None:
        # Start is idempotent for either warm capability, including a concurrent
        # clone request. Never start primary outside the mutually-exclusive slot.
        async with self._capability_lock:
            if self.ready:
                return
            if self.clone is not None and self.clone.alive:
                await self.clone.close()
            await self.primary.start()

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        from speechrail.domain.tts import get_voice_registry

        profile = get_voice_registry().get_profile(request.voice)
        clone_worker = self.clone
        selected: Qwen3TtsWorker
        other: Qwen3TtsWorker | None
        if profile.mode == "clone":
            if clone_worker is None:

                async def unavailable() -> AsyncIterator[AudioChunk]:
                    raise RuntimeError("voice_clone_base_model_unavailable")
                    yield  # pragma: no cover

                return unavailable()
            selected = clone_worker
            other = self.primary
        else:
            selected = self.primary
            other = clone_worker

        async def stream() -> AsyncIterator[AudioChunk]:
            # Hold the capability lock for the stream lifetime.  This makes a
            # model swap atomic with respect to another synthesis request and
            # prevents primary/Base workers from becoming resident together.
            async with self._capability_lock:
                if other is not None and other.alive:
                    await other.close()
                source = selected.synthesize(request)
                try:
                    async for chunk in source:
                        yield chunk
                finally:
                    # Closing the outer generator does not automatically close
                    # an async-for child. Finish abort/reap and reference leases
                    # before another request can acquire the model slot.
                    close = getattr(source, "aclose", None)
                    if close is not None:
                        await close()

        return stream()

    async def evict_warm_capability(self) -> None:
        """Release the current TTS model slot before a heavyweight validation phase."""
        async with self._capability_lock:
            if self.clone is not None and self.clone.alive:
                await self.clone.close()
            if self.primary.alive:
                await self.primary.close()

    async def trim_memory(self) -> None:
        await self.primary.trim_memory()
        if self.clone is not None:
            await self.clone.trim_memory()

    async def close(self) -> None:
        primary_error: BaseException | None = None
        try:
            await self.primary.close()
        except BaseException as exc:
            primary_error = exc
        finally:
            if self.clone is not None:
                await self.clone.close()
        if primary_error is not None:
            raise primary_error
