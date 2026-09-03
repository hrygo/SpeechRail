"""Native Qwen3-ASR backend adapter (main-process side of the worker boundary)."""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import os
import time
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol
from uuid import uuid4

from speechrail.domain.contracts import TranscriptResult, TranscriptSegment, TranscriptWord
from speechrail.domain.ports import BatchTranscriber, TranscriptionRequest
from speechrail.runtime.worker_process import (
    AsyncFramedWorkerProcess,
    WorkerProcessSpec,
    error_frame_message,
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
)
# Accepted weight-file layouts. Exactly one must be present:
#   - single-file pre-quantized MLX snapshot (mlx-community ...-8bit),
#   - the two-shard Qwen original.
WEIGHT_FILE_SETS = (
    ("model.safetensors",),
    ("model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"),
)


def weight_files(model_dir: Path) -> tuple[str, ...]:
    """Return the weight-file names for the supported layout present in ``model_dir``."""
    for layout in WEIGHT_FILE_SETS:
        if all((model_dir / name).is_file() for name in layout):
            return layout
    raise ValueError(
        "model snapshot weights are missing (need model.safetensors or the two-shard pair)"
    )


def snapshot_is_quantized(model_dir: Path) -> bool:
    """True when ``config.json`` declares pre-quantized weights (e.g. an ``-8bit`` MLX snapshot).

    Shared by the ASR/TTS worker identity reporting and the backend config wiring so a
    pre-quantized snapshot resolves to an int8 identity no matter which layer reads it.
    """
    try:
        config = json.loads((model_dir / "config.json").read_text(encoding="utf-8"))
    except Exception:
        return False
    return bool(config.get("quantization") or config.get("quantization_config"))


def resolve_backend_dtype(
    model_dir: Path, configured_dtype: Literal["float16", "float32", "int8"]
) -> Literal["float16", "float32", "int8"]:
    """Resolve the driver dtype for a backend from its snapshot state.

    A pre-quantized ``-8bit`` snapshot already carries int8 weights and is loaded
    directly: it is never re-quantized at load time, which would re-quantize
    already-quantized weights and trigger a transient ``bf16 -> fp16 -> int8`` peak
    for no benefit. A non-quantized snapshot honors ``configured_dtype``, which may
    request in-memory int8 quantization.

    Shared by the ASR/TTS/streaming wiring so a pre-quantized snapshot resolves to
    an int8 identity consistently, independent of the configured default.
    """
    if snapshot_is_quantized(model_dir):
        return "int8"
    return configured_dtype


def _build_timed_result(
    raw: object,
) -> tuple[tuple[TranscriptSegment, ...], tuple[TranscriptWord, ...]]:
    if not isinstance(raw, list):
        return (), ()
    segments: list[TranscriptSegment] = []
    words: list[TranscriptWord] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            continue
        text = item.get("text")
        start = item.get("start")
        end = item.get("end")
        if (
            not isinstance(text, str)
            or not isinstance(start, (int, float))
            or not isinstance(end, (int, float))
        ):
            continue
        start_ms = round(float(start) * 1000)
        end_ms = round(float(end) * 1000)
        cleaned = text.strip()
        if not cleaned:
            continue
        segments.append(
            TranscriptSegment(
                id=index,
                start_ms=start_ms,
                end_ms=end_ms,
                text=cleaned,
            )
        )
        words.append(
            TranscriptWord(
                word=cleaned,
                start_ms=start_ms,
                end_ms=end_ms,
            )
        )
    return tuple(segments), tuple(words)


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
    weight_files(resolved_model)  # raises if no supported weight layout is present
    return resolved_model


def snapshot_fingerprint(model_dir: Path) -> str:
    """Produce a stable manifest fingerprint without reading audio or model weights."""

    digest = hashlib.sha256()
    for name in (*MODEL_FILES, *weight_files(model_dir)):
        stat = (model_dir / name).stat()
        digest.update(f"{name}:{stat.st_size}".encode())
    return digest.hexdigest()


@dataclass(frozen=True, slots=True)
class Qwen3BackendConfig:
    repository_root: Path
    python_executable: Path
    model_dir: Path
    device: Literal["mps", "cpu"]
    dtype: Literal["float16", "float32", "int8"] = "float16"
    cache_limit_mb: int = 256
    memory_limit_mb: int = 0
    timeout_seconds: float = 120.0
    max_new_tokens: int = 512

    def __post_init__(self) -> None:
        repository_root = self.repository_root.resolve(strict=True)
        python_executable = self.python_executable.absolute()
        if not python_executable.is_file() or not os.access(python_executable, os.X_OK):
            raise ValueError("python_executable must be an executable local file")
        if self.device == "mps" and self.dtype not in {"float16", "int8"}:
            raise ValueError("MPS requires float16 or int8; CPU fallback is not allowed")
        if self.device == "cpu" and self.dtype not in {"float32", "int8"}:
            raise ValueError("CPU requires float32 or int8")
        if self.timeout_seconds <= 0 or not 32 <= self.max_new_tokens <= 2048:
            raise ValueError("invalid worker timeout or token limit")
        if self.cache_limit_mb < 0 or self.memory_limit_mb < 0:
            raise ValueError("memory and cache limits must be non-negative")
        object.__setattr__(self, "repository_root", repository_root)
        object.__setattr__(self, "python_executable", python_executable)
        object.__setattr__(
            self, "model_dir", validate_snapshot(self.model_dir, repository_root=repository_root)
        )

    def command(self) -> list[str]:
        cmd = [
            str(self.python_executable),
            "-m",
            "speechrail.backends.qwen3_worker",
            "--model-dir",
            str(self.model_dir),
            "--device",
            self.device,
            "--dtype",
            self.dtype,
            "--max-new-tokens",
            str(self.max_new_tokens),
            "--cache-limit-mb",
            str(self.cache_limit_mb),
        ]
        if self.memory_limit_mb > 0:
            cmd.extend(["--memory-limit-mb", str(self.memory_limit_mb)])
        return cmd

    def worker_spec(self) -> WorkerProcessSpec:
        return WorkerProcessSpec(
            command=tuple(self.command()),
            cwd=self.repository_root,
            env=offline_environment(self.repository_root),
            io_timeout_seconds=self.timeout_seconds,
        )


class Qwen3Worker:  # pragma: no cover - exercised against an external isolated Qwen runtime.
    """One supervised, offline worker process shared by batch and streaming requests."""

    def __init__(self, config: Qwen3BackendConfig) -> None:
        self.config = config
        self._transport = AsyncFramedWorkerProcess(config.worker_spec())
        self._lock = asyncio.Lock()
        self._identity: tuple[str, str] | None = None
        self.last_active: float = time.monotonic()

    @property
    def alive(self) -> bool:
        return self._transport.alive

    async def start(self) -> None:
        async with self._lock:
            if self._identity is not None:
                return
            try:
                await self._transport.start()
                ready = await self.exchange(
                    {
                        "version": PROTOCOL_VERSION,
                        "type": "start",
                        "model_dir": str(self.config.model_dir),
                        "device": self.config.device,
                    }
                )
                if ready.get("type") != "ready" or ready.get("model_loaded") is not True:
                    raise RuntimeError(error_frame_message(ready, "worker_start_failed"))
                device, dtype = ready.get("device"), ready.get("dtype")
                if device != self.config.device or dtype != self.config.dtype:
                    raise RuntimeError("backend_identity_mismatch")
                self._identity = (str(device), str(dtype))
            except BaseException:
                await self._transport.abort()
                raise

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        await self._transport.send(payload, binary_payload=binary_payload)
        self.last_active = time.monotonic()

    async def receive(self) -> dict[str, object]:
        frame = await self._transport.receive()
        self.last_active = time.monotonic()
        return frame

    async def exchange(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> dict[str, object]:
        """Send one request and read its response atomically on the shared transport."""
        try:
            frame = await self._transport.exchange(payload, binary_payload=binary_payload)
        except ProtocolError as exc:
            raise RuntimeError("worker_frame_invalid") from exc
        self.last_active = time.monotonic()
        return frame

    async def transcribe(
        self,
        pcm: bytes,
        language: str | None,
        prompt: str,
        include_timestamps: bool = False,
        *,
        request_id: str | None = None,
    ) -> TranscriptResult:
        await self.start()
        async with self._lock:
            resolved_request_id = request_id or f"req_{uuid4().hex}"
            result = await self.exchange(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "transcribe",
                    "request_id": resolved_request_id,
                    "sample_rate": 16000,
                    "channels": 1,
                    "sample_width_bytes": 2,
                    "language": language or "auto",
                    "prompt": prompt,
                    "include_timestamps": include_timestamps,
                },
                binary_payload=pcm,
            )
        if result.get("type") != "result" or result.get("request_id") != resolved_request_id:
            raise RuntimeError(error_frame_message(result, "worker_request_failed"))
        text, detected = result.get("text"), result.get("language")
        if not isinstance(text, str) or not isinstance(detected, str):
            raise RuntimeError("worker_result_invalid")
        segments, words = _build_timed_result(result.get("segments"))
        return TranscriptResult(
            request_id=resolved_request_id,
            model_id="speechrail/qwen3-asr-1.7b",
            text=text,
            language=detected,
            duration_ms=round(len(pcm) * 1000 / 32000),
            segments=segments,
            words=words,
        )

    async def trim_memory(self) -> None:
        if self.alive:
            with contextlib.suppress(Exception):
                await self._transport.send({"version": PROTOCOL_VERSION, "type": "trim_memory"})

    async def close(self) -> None:
        async with self._lock:
            self._identity = None
            await self._transport.close()


class _Qwen3TranscriptionWorker(Protocol):
    async def transcribe(
        self,
        pcm: bytes,
        language: str | None,
        prompt: str,
        include_timestamps: bool = False,
        *,
        request_id: str | None = None,
    ) -> TranscriptResult: ...


class Qwen3BatchTranscriber(BatchTranscriber):
    """Normalize the isolated Qwen worker behind the public batch ASR port."""

    def __init__(self, *, worker: _Qwen3TranscriptionWorker, model_id: str) -> None:
        self._worker = worker
        self._model_id = model_id

    async def trim_memory(self) -> None:
        trim_fn = getattr(self._worker, "trim_memory", None)
        if callable(trim_fn):
            await trim_fn()

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        result = await self._worker.transcribe(
            request.audio,
            request.language,
            request.prompt,
            request_id=request.request_id,
            include_timestamps=request.include_timestamps,
        )
        return result.model_copy(
            update={"request_id": request.request_id, "model_id": self._model_id}
        )
