"""Qwen3-ASR subprocess preflight and persistent-worker configuration."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol
from uuid import uuid4

from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import BatchTranscriber, TranscriptionRequest
from speechrail.runtime.worker_process import (
    AsyncFramedWorkerProcess,
    WorkerProcessSpec,
    offline_environment,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, ProtocolError

MODEL_FILES = (
    "config.json",
    "generation_config.json",
    "preprocessor_config.json",
    "tokenizer_config.json",
    "chat_template.json",
    "merges.txt",
    "vocab.json",
    "model.safetensors.index.json",
    "model-00001-of-00002.safetensors",
    "model-00002-of-00002.safetensors",
)


def validate_snapshot(model_dir: Path, *, repository_root: Path) -> Path:
    """Require a complete external local snapshot; requests never download one."""

    if not model_dir.is_absolute():
        raise ValueError("model snapshot must be an absolute path")
    resolved_model = model_dir.resolve(strict=True)
    resolved_root = repository_root.resolve(strict=True)
    if resolved_model.is_relative_to(resolved_root):
        raise ValueError("model snapshot must be outside repository")
    if not resolved_model.is_dir() or any(
        not (resolved_model / name).is_file() for name in MODEL_FILES
    ):
        raise ValueError("model snapshot is incomplete")
    return resolved_model


def snapshot_fingerprint(model_dir: Path) -> str:
    """Produce a stable manifest fingerprint without reading audio or model weights."""

    digest = hashlib.sha256()
    for name in MODEL_FILES:
        stat = (model_dir / name).stat()
        digest.update(f"{name}:{stat.st_size}".encode())
    return digest.hexdigest()


@dataclass(frozen=True, slots=True)
class Qwen3BackendConfig:
    repository_root: Path
    python_executable: Path
    model_dir: Path
    device: Literal["mps", "cpu"]
    dtype: Literal["float16", "float32"]
    timeout_seconds: float = 120.0
    max_new_tokens: int = 512

    def __post_init__(self) -> None:
        repository_root = self.repository_root.resolve(strict=True)
        python_executable = self.python_executable.absolute()
        if not python_executable.is_file() or not os.access(python_executable, os.X_OK):
            raise ValueError("python_executable must be an executable local file")
        if self.device == "mps" and self.dtype != "float16":
            raise ValueError("MPS requires float16; CPU fallback is not allowed")
        if self.device == "cpu" and self.dtype != "float32":
            raise ValueError("CPU requires float32")
        if self.timeout_seconds <= 0 or not 32 <= self.max_new_tokens <= 2048:
            raise ValueError("invalid worker timeout or token limit")
        object.__setattr__(self, "repository_root", repository_root)
        object.__setattr__(self, "python_executable", python_executable)
        object.__setattr__(
            self, "model_dir", validate_snapshot(self.model_dir, repository_root=repository_root)
        )

    def command(self) -> list[str]:
        return [
            str(self.python_executable),
            "-m",
            "speechrail.backends.qwen3_worker",
            "--model-dir",
            str(self.model_dir),
            "--device",
            self.device,
            "--max-new-tokens",
            str(self.max_new_tokens),
        ]

    def worker_spec(self) -> WorkerProcessSpec:
        return WorkerProcessSpec(
            command=tuple(self.command()),
            cwd=self.repository_root,
            env=offline_environment(self.repository_root),
            io_timeout_seconds=self.timeout_seconds,
        )


class Qwen3Worker:  # pragma: no cover - exercised against an external isolated Qwen runtime.
    """One supervised, offline worker process shared by sequential batch requests.

    The profile policy lives here: one ready handshake with device/dtype
    identity and exactly one result frame per transcribe request.  Process
    transport, framing and termination are delegated to the shared layer.
    """

    def __init__(self, config: Qwen3BackendConfig) -> None:
        self.config = config
        self._transport = AsyncFramedWorkerProcess(config.worker_spec())
        self._lock = asyncio.Lock()
        self._identity: tuple[str, str] | None = None

    async def start(self) -> None:
        async with self._lock:
            if self._identity is not None:
                return
            try:
                await self._transport.start()
                await self._transport.send(
                    {
                        "version": PROTOCOL_VERSION,
                        "type": "start",
                        "model_dir": str(self.config.model_dir),
                        "device": self.config.device,
                    }
                )
                ready = await self._receive_profile_frame()
                if ready.get("type") != "ready" or ready.get("model_loaded") is not True:
                    raise RuntimeError(str(ready.get("code", "worker_start_failed")))
                device, dtype = ready.get("device"), ready.get("dtype")
                if device != self.config.device or dtype != self.config.dtype:
                    raise RuntimeError("backend_identity_mismatch")
                self._identity = (str(device), str(dtype))
            except BaseException:
                await self._transport.abort()
                raise

    async def transcribe(
        self, pcm: bytes, language: str | None, prompt: str, *, request_id: str | None = None
    ) -> TranscriptResult:
        await self.start()
        async with self._lock:
            resolved_request_id = request_id or f"req_{uuid4().hex}"
            await self._transport.send(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "transcribe",
                    "request_id": resolved_request_id,
                    "sample_rate": 16000,
                    "channels": 1,
                    "sample_width_bytes": 2,
                    "language": language or "auto",
                    "prompt": prompt,
                    "pcm_b64": base64.b64encode(pcm).decode("ascii"),
                }
            )
            result = await self._receive_profile_frame()
        if result.get("type") != "result" or result.get("request_id") != resolved_request_id:
            raise RuntimeError(str(result.get("code", "worker_request_failed")))
        text, detected = result.get("text"), result.get("language")
        if not isinstance(text, str) or not isinstance(detected, str):
            raise RuntimeError("worker_result_invalid")
        return TranscriptResult(
            request_id=resolved_request_id,
            model_id="speechrail/qwen3-asr-1.7b",
            text=text,
            language=detected,
            duration_ms=round(len(pcm) * 1000 / 32000),
        )

    async def _receive_profile_frame(self) -> dict[str, object]:
        try:
            return await self._transport.receive()
        except ProtocolError as exc:
            raise RuntimeError("worker_frame_invalid") from exc

    async def close(self) -> None:
        async with self._lock:
            self._identity = None
            await self._transport.close()


class _Qwen3TranscriptionWorker(Protocol):
    async def transcribe(
        self, pcm: bytes, language: str | None, prompt: str, *, request_id: str | None = None
    ) -> TranscriptResult: ...


class Qwen3BatchTranscriber(BatchTranscriber):
    """Normalize the isolated Qwen worker behind the public batch ASR port."""

    def __init__(self, *, worker: _Qwen3TranscriptionWorker, model_id: str) -> None:
        self._worker = worker
        self._model_id = model_id

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        result = await self._worker.transcribe(
            request.audio, request.language, request.prompt, request_id=request.request_id
        )
        return result.model_copy(
            update={"request_id": request.request_id, "model_id": self._model_id}
        )
