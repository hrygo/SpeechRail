"""Independent fixed-text alignment client and aligner process lifecycle.

One aligner owner exists per service.  It owns a bounded request queue, a
transport lock, and the child process; it never borrows ASR state and it never
performs recognition.
"""

from __future__ import annotations

import asyncio
import os
import time
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from speechrail.backends.qwen3_native import validate_forced_aligner_snapshot
from speechrail.runtime.worker_process import (
    AsyncFramedWorkerProcess,
    WorkerProcessSpec,
    error_frame_message,
    offline_environment,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION

ALIGNMENT_SAMPLE_RATE = 16_000


class AlignmentQueueFullError(RuntimeError):
    """The bounded aligner queue is saturated; callers must fail fast."""


@dataclass(frozen=True, slots=True)
class Qwen3AlignmentConfig:
    """Explicit launch parameters for the isolated aligner process."""

    repository_root: Path
    python_executable: Path
    model_dir: Path
    device: Literal["mps", "cpu"]
    dtype: Literal["float16", "float32", "bfloat16", "int8"] = "float16"
    cache_limit_mb: int = 256
    memory_limit_mb: int = 0
    timeout_seconds: float = 120.0

    def __post_init__(self) -> None:
        repository_root = self.repository_root.resolve(strict=True)
        python_executable = self.python_executable.absolute()
        if not python_executable.is_file() or not os.access(python_executable, os.X_OK):
            raise ValueError("python_executable must be an executable local file")
        if self.device == "mps" and self.dtype not in {"float16", "bfloat16", "int8"}:
            raise ValueError("MPS aligner requires float16, bfloat16 or int8 weights")
        if self.device == "cpu" and self.dtype not in {"float32", "int8"}:
            raise ValueError("CPU aligner requires float32 or int8 weights")
        if self.timeout_seconds <= 0:
            raise ValueError("aligner timeout must be positive")
        if self.cache_limit_mb < 0 or self.memory_limit_mb < 0:
            raise ValueError("memory and cache limits must be non-negative")
        object.__setattr__(self, "repository_root", repository_root)
        object.__setattr__(self, "python_executable", python_executable)
        object.__setattr__(
            self,
            "model_dir",
            validate_forced_aligner_snapshot(self.model_dir, repository_root=repository_root),
        )

    def command(self) -> list[str]:
        cmd = [
            str(self.python_executable),
            "-m",
            "speechrail.backends.qwen3_alignment_worker",
            "--model-dir",
            str(self.model_dir),
            "--device",
            self.device,
            "--dtype",
            self.dtype,
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


class Qwen3AlignmentWorker:
    """One supervised aligner process with a bounded, fail-fast request queue."""

    def __init__(
        self,
        config: Qwen3AlignmentConfig,
        *,
        max_pending_requests: int = 3,
        process: AsyncFramedWorkerProcess | None = None,
    ) -> None:
        if max_pending_requests < 1:
            raise ValueError("alignment queue limit must be positive")
        self.config = config
        self._max_pending_requests = max_pending_requests
        self._process = process or AsyncFramedWorkerProcess(config.worker_spec())
        self._ready: dict[str, object] | None = None
        self._queue = asyncio.Semaphore(max_pending_requests)
        self._inflight = 0
        self._last_active = time.monotonic()

    @property
    def alive(self) -> bool:
        return self._process.alive

    @property
    def ready(self) -> bool:
        return self._ready is not None

    @property
    def identity(self) -> Mapping[str, object] | None:
        return self._ready

    @property
    def last_active(self) -> float:
        return self._last_active

    @property
    def pending_requests(self) -> int:
        return self._inflight

    async def start(self) -> None:
        if self._ready is not None:
            return
        await self._process.start()
        ready = await self._process.exchange(
            {
                "version": PROTOCOL_VERSION,
                "type": "start",
                "model_dir": str(self.config.model_dir),
                "device": self.config.device,
                "dtype": self.config.dtype,
            },
            handshake=True,
        )
        if ready.get("type") != "ready" or ready.get("model_loaded") is not True:
            await self._process.abort()
            raise RuntimeError(error_frame_message(ready, "alignment_worker_unavailable"))
        if ready.get("dtype") != self.config.dtype or ready.get("device") != self.config.device:
            await self._process.abort()
            raise RuntimeError("alignment_backend_identity_mismatch")
        self._ready = dict(ready)

    async def close(self) -> None:
        self._ready = None
        await self._process.close()

    async def align_text(
        self, pcm: bytes, *, text: str, language: str | None
    ) -> tuple[tuple[str, float, float], ...]:
        """Ask the isolated aligner for raw fixed-text tokens."""

        if not pcm or len(pcm) % 2 or not text:
            raise ValueError("fixed-text alignment requires non-empty PCM16 and text")
        if self._queue.locked():
            # All slots are held; queueing further would grow unboundedly.
            raise AlignmentQueueFullError("alignment queue is full")
        await self._queue.acquire()
        self._inflight += 1
        try:
            await self.start()
            request_id = f"align_{os.urandom(8).hex()}"
            result = await self._process.exchange(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "align_text",
                    "request_id": request_id,
                    "sample_rate": ALIGNMENT_SAMPLE_RATE,
                    "channels": 1,
                    "sample_width_bytes": 2,
                    "language": language or "auto",
                    "text": text,
                },
                binary_payload=pcm,
            )
            self._last_active = time.monotonic()
            if result.get("type") != "align_result" or result.get("request_id") != request_id:
                raise RuntimeError(error_frame_message(result, "alignment_worker_failed"))
            raw_tokens = result.get("tokens")
            if not isinstance(raw_tokens, list):
                raise RuntimeError("alignment_worker_invalid")
            tokens: list[tuple[str, float, float]] = []
            for item in raw_tokens:
                if not isinstance(item, Mapping):
                    raise RuntimeError("alignment_worker_invalid")
                token, start, end = item.get("text"), item.get("start"), item.get("end")
                if (
                    not isinstance(token, str)
                    or isinstance(start, bool)
                    or not isinstance(start, (int, float))
                    or isinstance(end, bool)
                    or not isinstance(end, (int, float))
                ):
                    raise RuntimeError("alignment_worker_invalid")
                tokens.append((token, float(start), float(end)))
            return tuple(tokens)
        except (RuntimeError, TimeoutError, OSError):
            # A crashed or timed-out aligner must not poison the next request.
            await self._reset_transport()
            raise
        finally:
            self._inflight -= 1
            self._queue.release()

    async def _reset_transport(self) -> None:
        self._ready = None
        await self._process.abort()


__all__ = [
    "AlignmentQueueFullError",
    "Qwen3AlignmentConfig",
    "Qwen3AlignmentWorker",
]
