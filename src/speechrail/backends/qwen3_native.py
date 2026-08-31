"""Qwen3-ASR subprocess preflight and persistent-worker configuration."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from uuid import uuid4

from speechrail.domain.contracts import TranscriptResult
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION

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


class Qwen3Worker:  # pragma: no cover - exercised against an external isolated Qwen runtime.
    """One supervised, offline worker process shared by sequential batch requests."""

    def __init__(self, config: Qwen3BackendConfig) -> None:
        self.config = config
        self._process: asyncio.subprocess.Process | None = None
        self._lock = asyncio.Lock()
        self._identity: tuple[str, str] | None = None

    async def start(self) -> None:
        async with self._lock:
            if self._identity is not None:
                return
            environment = {
                key: value
                for key, value in os.environ.items()
                if key in {"PATH", "TMPDIR", "LANG", "LC_ALL"}
            }
            environment.update(
                {
                    "PYTHONPATH": str(self.config.repository_root / "src"),
                    "HF_HUB_OFFLINE": "1",
                    "TRANSFORMERS_OFFLINE": "1",
                    "HF_DATASETS_OFFLINE": "1",
                    "PYTORCH_ENABLE_MPS_FALLBACK": "0",
                    "TOKENIZERS_PARALLELISM": "false",
                }
            )
            self._process = await asyncio.create_subprocess_exec(
                *self.config.command(),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
                cwd=self.config.repository_root,
                env=environment,
            )
            try:
                await self._write(
                    {
                        "version": PROTOCOL_VERSION,
                        "type": "start",
                        "model_dir": str(self.config.model_dir),
                        "device": self.config.device,
                    }
                )
                ready = await self._read()
                if ready.get("type") != "ready" or ready.get("model_loaded") is not True:
                    raise RuntimeError(str(ready.get("code", "worker_start_failed")))
                device, dtype = ready.get("device"), ready.get("dtype")
                if device != self.config.device or dtype != self.config.dtype:
                    raise RuntimeError("backend_identity_mismatch")
                self._identity = (str(device), str(dtype))
            except BaseException:
                await self.close()
                raise

    async def transcribe(self, pcm: bytes, language: str | None, prompt: str) -> TranscriptResult:
        await self.start()
        async with self._lock:
            request_id = f"req_{uuid4().hex}"
            await self._write(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "transcribe",
                    "request_id": request_id,
                    "sample_rate": 16000,
                    "channels": 1,
                    "sample_width_bytes": 2,
                    "language": language or "auto",
                    "prompt": prompt,
                    "pcm_b64": base64.b64encode(pcm).decode("ascii"),
                }
            )
            result = await self._read()
        if result.get("type") != "result" or result.get("request_id") != request_id:
            raise RuntimeError(str(result.get("code", "worker_request_failed")))
        text, detected = result.get("text"), result.get("language")
        if not isinstance(text, str) or not isinstance(detected, str):
            raise RuntimeError("worker_result_invalid")
        return TranscriptResult(
            request_id=request_id,
            model_id="speechrail/qwen3-asr-1.7b",
            text=text,
            language=detected,
            duration_ms=round(len(pcm) * 1000 / 32000),
        )

    async def _write(self, frame: dict[str, object]) -> None:
        if self._process is None or self._process.stdin is None:
            raise RuntimeError("worker_not_started")
        body = json.dumps(frame, separators=(",", ":")).encode()
        self._process.stdin.write(struct.pack(">I", len(body)) + body)
        async with asyncio.timeout(self.config.timeout_seconds):
            await self._process.stdin.drain()

    async def _read(self) -> dict[str, object]:
        if self._process is None or self._process.stdout is None:
            raise RuntimeError("worker_not_started")
        async with asyncio.timeout(self.config.timeout_seconds):
            length = struct.unpack(">I", await self._process.stdout.readexactly(4))[0]
            if not 0 < length <= 64 * 1024 * 1024:
                raise RuntimeError("worker_frame_invalid")
            payload = json.loads((await self._process.stdout.readexactly(length)).decode())
        if not isinstance(payload, dict):
            raise RuntimeError("worker_frame_invalid")
        return {str(key): value for key, value in payload.items()}

    async def close(self) -> None:
        process, self._process, self._identity = self._process, None, None
        if process is None:
            return
        if process.stdin is not None:
            process.stdin.close()
        if process.returncode is None:
            process.terminate()
        try:
            async with asyncio.timeout(2):
                await process.wait()
        except TimeoutError:
            process.kill()
            await process.wait()
