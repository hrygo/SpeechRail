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
from collections.abc import AsyncIterator
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from uuid import uuid4

from speechrail.backends.qwen3_tts_worker import TTS_BACKEND_ID
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.runtime.worker_process import (
    AsyncFramedWorkerProcess,
    WorkerProcessSpec,
    error_frame_message,
    offline_environment,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, ProtocolError


@dataclass(frozen=True, slots=True)
class Qwen3TtsBackendConfig:
    repository_root: Path
    python_executable: Path
    model_dir: Path
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

    def __init__(self, config: Qwen3TtsBackendConfig) -> None:
        self.config = config
        self._transport = AsyncFramedWorkerProcess(config.worker_spec())
        self._lock = asyncio.Lock()
        self._started = False
        self._epoch: int = 0
        self.last_active: float = time.monotonic()

    @property
    def alive(self) -> bool:
        return self._transport.alive

    @property
    def ready(self) -> bool:
        """Return whether the supervised worker can accept another request."""
        return self._started and self._transport.alive

    async def start(self) -> None:
        async with self._lock:
            await self._start_locked()

    async def _start_locked(self) -> None:
        if self._started:
            return
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
                or ready.get("dtype") not in {self.config.dtype, "float16", "float32"}
                or ready.get("sample_rate") != self.config.sample_rate
            ):
                raise RuntimeError("backend_identity_mismatch")
            self._started = True
            self._epoch += 1
            self.last_active = time.monotonic()
        except BaseException:
            await self._transport.abort()
            raise

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        """Yield ordered public PCM chunks while serializing private worker access."""

        async def stream() -> AsyncIterator[AudioChunk]:
            async with self._lock:
                if not self._started:
                    await self._start_locked()
                epoch = self._epoch
                self.last_active = time.monotonic()
                response_id = f"resp_{uuid4().hex}"
                await self._transport.send(
                    {
                        "version": PROTOCOL_VERSION,
                        "type": "synthesize",
                        "request_id": response_id,
                        "text": request.text,
                        "voice": request.voice,
                        "speed": request.speed,
                        "language": request.language,
                    }
                )
                expected_chunk_index = 0
                completed = False
                try:
                    while True:
                        frame = await self._receive_profile_frame()
                        if frame.get("request_id") != response_id:
                            raise RuntimeError("worker_response_id_mismatch")
                        if frame.get("type") == "completed":
                            completed = True
                            return
                        if frame.get("type") == "error":
                            raise RuntimeError(error_frame_message(frame, "worker_inference_error"))
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
                        if chunk_index != expected_chunk_index or not audio or len(audio) % 2:
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
                        await self._transport.abort()

        return stream()

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
