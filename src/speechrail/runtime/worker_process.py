"""Profile-neutral async framed subprocess transport for local workers.

The shared layer owns process lifecycle, offline environment, length-prefixed
frames, bounded IO/terminate behavior and bounded stderr capture only.  It does
not understand ASR or TTS request schemas, ready identities, streaming policies
or public IDs.
"""

from __future__ import annotations

import asyncio
import collections
import contextlib
import logging
import os
import struct
from asyncio import IncompleteReadError
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from speechrail.runtime.worker_protocol import (
    MAX_FRAME_BYTES,
    ProtocolError,
    decode_frame_body,
    encode_frame,
)

logger = logging.getLogger(__name__)

_TERMINATE_GRACE_SECONDS = 2.0
_STDERR_CHUNK_BYTES = 1024
_STDERR_RING_CHUNKS = 16  # at most 16 KiB, including a single unbroken vendor line
_EXCEPTION_TYPES = frozenset(
    {
        "ModuleNotFoundError", "ImportError", "FileNotFoundError", "PermissionError",
        "MemoryError", "ValueError", "RuntimeError", "OSError", "TypeError",
    }
)


class WorkerTransportError(ProtocolError):
    """A protocol failure with safe attribution separate from its private message."""

    def __init__(
        self,
        message: str,
        *,
        diagnostic_class: str,
        exit_code: int | None = None,
        exception_type: str | None = None,
    ) -> None:
        super().__init__(message)
        self.diagnostic_class = diagnostic_class
        self.exit_code = exit_code
        self.exception_type = exception_type


def _stderr_exception_type(tail: str) -> str | None:
    """Recognize a bounded exception name; never return the exception's text."""
    for line in reversed(tail.splitlines()):
        name, separator, _ = line.partition(":")
        if separator and name.strip() in _EXCEPTION_TYPES:
            return name.strip()
    return None


def error_frame_message(frame: Mapping[str, object], fallback: str) -> str:
    """Format an error frame for an exception message, embedding the stderr tail.

    The transport injects ``stderr_tail`` into every error frame it decodes, so
    client exceptions no longer hide the underlying model/load failure.
    """

    code = str(frame.get("code") or fallback)
    tail = frame.get("stderr_tail")
    if isinstance(tail, str) and tail:
        return f"{code}; worker stderr tail:\n{tail}"
    return code


@dataclass(frozen=True, slots=True)
class WorkerProcessSpec:
    """Explicit, bounded subprocess launch parameters without request data."""

    command: tuple[str, ...]
    cwd: Path
    env: Mapping[str, str]
    io_timeout_seconds: float
    shutdown_timeout_seconds: float = _TERMINATE_GRACE_SECONDS
    handshake_timeout_seconds: float | None = None


def offline_environment(repository_root: Path) -> dict[str, str]:
    """Build the controlled offline env; only allowlisted keys are inherited."""

    import_root = repository_root / "src"
    if not import_root.is_dir():
        import_root = repository_root
    environment = {
        key: value
        for key, value in os.environ.items()
        if key in {"PATH", "TMPDIR", "LANG", "LC_ALL"}
    }
    environment.update(
        {
            "PYTHONPATH": str(import_root),
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_DATASETS_OFFLINE": "1",
            "PYTORCH_ENABLE_MPS_FALLBACK": "0",
            "TOKENIZERS_PARALLELISM": "false",
        }
    )
    return environment


class AsyncFramedWorkerProcess:
    """Start one explicit subprocess and speak length-prefixed JSON frames.

    Read and write directions have separate locks so a reader parked on
    ``receive()`` (the realtime read loop) cannot starve a writer sending an
    ``append``/``commit`` frame on the same transport; ``exchange`` briefly
    holds both to keep one request/response pair atomic.  Multiple callers can
    therefore not interleave frames or run concurrent ``readexactly`` calls on
    the same ``StreamReader``.
    """

    def __init__(self, spec: WorkerProcessSpec) -> None:
        self._spec = spec
        self._process: asyncio.subprocess.Process | None = None
        self._stderr_ring: collections.deque[bytes] = collections.deque(
            maxlen=_STDERR_RING_CHUNKS,
        )
        self._stderr_task: asyncio.Task[None] | None = None
        self._read_lock = asyncio.Lock()
        self._write_lock = asyncio.Lock()
        self._lifecycle_lock = asyncio.Lock()

    @property
    def alive(self) -> bool:
        process = self._process
        return process is not None and process.returncode is None

    @property
    def handshake_timeout_seconds(self) -> float:
        """Return the startup handshake deadline, defaulting to the frame deadline."""
        return self._spec.handshake_timeout_seconds or self._spec.io_timeout_seconds

    async def start(self) -> None:
        async with self._lifecycle_lock:
            if self.alive:
                return
            await self._abort_unlocked()
            self._stderr_ring.clear()
            self._process = await asyncio.create_subprocess_exec(
                *self._spec.command,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=self._spec.cwd,
                env=dict(self._spec.env),
            )
            self._stderr_task = asyncio.create_task(
                self._drain_stderr(self._process),
                name="worker-stderr-drain",
            )

    async def _drain_stderr(self, proc: asyncio.subprocess.Process) -> None:
        """Drain even very long lines without blocking a noisy vendor process."""
        assert proc.stderr is not None
        try:
            while chunk := await proc.stderr.read(_STDERR_CHUNK_BYTES):
                self._stderr_ring.append(chunk)
        except (asyncio.CancelledError, ValueError):
            pass

    def _format_stderr_tail(self) -> str:
        """Return the last captured stderr content as a decoded string."""
        if not self._stderr_ring:
            return "(no stderr captured)"
        return b"".join(self._stderr_ring).decode("utf-8", errors="replace").rstrip()

    def _protocol_error(
        self, message: str, diagnostic_class: str
    ) -> WorkerTransportError:
        process = self._process
        return WorkerTransportError(
            message,
            diagnostic_class=diagnostic_class,
            exit_code=process.returncode if process is not None else None,
            exception_type=_stderr_exception_type(self._format_stderr_tail()),
        )

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        async with self._write_lock:
            await self._send_unlocked(
                payload,
                binary_payload=binary_payload,
                deadline=self._spec.io_timeout_seconds,
            )

    async def exchange(
        self,
        payload: Mapping[str, object],
        binary_payload: bytes | None = None,
        *,
        handshake: bool = False,
    ) -> dict[str, object]:
        """Send one request frame and read its response atomically.

        The write lock and read lock are both held for the pair so a competing
        reader can never steal this caller's response frame.  A parked streaming
        ``receive()`` reader holds only the read lock, so a concurrent batch
        ``send()`` can still write; the single-lock variant deadlocked the
        dedicated streaming worker because its read loop parks on ``readexactly``
        while append/commit tries to write on the same lock.
        """
        deadline = (
            self.handshake_timeout_seconds
            if handshake
            else self._spec.io_timeout_seconds
        )
        async with self._write_lock:
            await self._send_unlocked(
                payload, binary_payload=binary_payload, deadline=deadline
            )
            async with self._read_lock:
                return await self._receive_unlocked(deadline=deadline)

    async def _send_unlocked(
        self,
        payload: Mapping[str, object],
        binary_payload: bytes | None = None,
        *,
        deadline: float,
    ) -> None:
        process = self._require_process()
        if process.stdin is None:
            raise RuntimeError("worker_transport_invalid")
        frame = encode_frame(payload, binary_payload=binary_payload)
        try:
            async with asyncio.timeout(deadline):
                process.stdin.write(frame)
                await process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError) as exc:
            await self._drain_stderr_tail()
            raise self._protocol_error("worker pipe closed", "worker_pipe_closed") from exc

    async def _drain_stderr_tail(self) -> None:
        """Briefly yield control to let the stderr drain task capture trailing lines on exit."""
        if self._stderr_task is not None and not self._stderr_task.done():
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await asyncio.sleep(0.01)

    async def receive(self, *, wait_for_frame: bool = False) -> dict[str, object]:
        """dispatcher 可等待空闲首字节。开始接收后仍强制完整帧期限。"""
        async with self._read_lock:
            return await self._receive_unlocked(wait_for_frame=wait_for_frame)

    async def _receive_unlocked(
        self, *, wait_for_frame: bool = False, deadline: float | None = None
    ) -> dict[str, object]:
        process = self._require_process()
        if process.stdout is None:
            raise RuntimeError("worker_transport_invalid")
        effective_timeout = (
            self._spec.io_timeout_seconds if deadline is None else deadline
        )
        first = b""
        try:
            if wait_for_frame:
                first = await process.stdout.readexactly(1)
            async with asyncio.timeout(effective_timeout):
                header = first + await process.stdout.readexactly(4 - len(first))
        except TimeoutError as exc:
            if wait_for_frame:
                raise self._protocol_error(
                    "incomplete worker frame timed out", "worker_frame_timeout"
                ) from exc
            raise
        except IncompleteReadError as exc:
            await self._drain_stderr_tail()
            stderr_tail = self._format_stderr_tail()
            raise self._protocol_error(
                f"truncated worker frame (read {len(first) + len(exc.partial)} of "
                f"4 header bytes); worker stderr tail:\n{stderr_tail}",
                "worker_eof",
            ) from exc
        size = struct.unpack(">I", header)[0]
        if not 0 < size <= MAX_FRAME_BYTES:
            raise self._protocol_error("invalid worker frame size", "worker_frame_size_invalid")
        try:
            async with asyncio.timeout(effective_timeout):
                body = await process.stdout.readexactly(size)
        except TimeoutError as exc:
            if wait_for_frame:
                raise self._protocol_error(
                    "incomplete worker frame timed out", "worker_frame_timeout"
                ) from exc
            raise
        except IncompleteReadError as exc:
            await self._drain_stderr_tail()
            stderr_tail = self._format_stderr_tail()
            raise self._protocol_error(
                f"truncated worker frame payload (read {len(exc.partial)} of "
                f"{size} bytes); worker stderr tail:\n{stderr_tail}",
                "worker_frame_incomplete",
            ) from exc
        try:
            frame = decode_frame_body(body)
        except ProtocolError as exc:
            raise self._protocol_error(
                "invalid worker frame body", "worker_frame_decode_invalid"
            ) from exc
        if frame.get("type") == "error":
            await self._drain_stderr_tail()
            frame["stderr_tail"] = self._format_stderr_tail()
            frame["worker_exception_type"] = _stderr_exception_type(str(frame["stderr_tail"]))
            logger.warning(
                "worker error frame received: exception_type=%s exit_code=%s",
                frame["worker_exception_type"],
                process.returncode,
            )
        return frame

    async def abort(self) -> None:
        """隔离旧管道并等待回收完成。调用方取消也不能提前启动下一进程。"""
        async with self._lifecycle_lock:
            await self._abort_unlocked()

    async def _abort_unlocked(self) -> None:
        process, self._process = self._process, None
        stderr_task, self._stderr_task = self._stderr_task, None
        if stderr_task is not None:
            stderr_task.cancel()
        if process is None and stderr_task is None:
            return
        cleanup = asyncio.create_task(self._reap(process, stderr_task))
        cancelled = False
        while not cleanup.done():
            try:
                await asyncio.shield(cleanup)
            except asyncio.CancelledError:
                cancelled = True
        cleanup.result()
        if cancelled:
            raise asyncio.CancelledError

    async def _reap(
        self, process: asyncio.subprocess.Process | None, stderr_task: asyncio.Task[None] | None
    ) -> None:
        if process is not None:
            await self._terminate(process)
        if stderr_task is not None:
            await asyncio.gather(stderr_task, return_exceptions=True)

    async def close(self) -> None:
        await self.abort()

    def _require_process(self) -> asyncio.subprocess.Process:
        process = self._process
        if process is None:
            raise RuntimeError("worker_not_started")
        return process

    async def _terminate(self, process: asyncio.subprocess.Process) -> None:
        if process.stdin is not None:
            process.stdin.close()
        if process.returncode is None:
            process.terminate()
        try:
            async with asyncio.timeout(self._spec.shutdown_timeout_seconds):
                await process.wait()
        except TimeoutError:
            process.kill()
            await process.wait()
