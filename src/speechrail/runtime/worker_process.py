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
_STDERR_RING_LINES: int = 64  # keep last N lines of stderr


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
            maxlen=_STDERR_RING_LINES,
        )
        self._stderr_task: asyncio.Task[None] | None = None
        self._read_lock = asyncio.Lock()
        self._write_lock = asyncio.Lock()

    @property
    def alive(self) -> bool:
        process = self._process
        return process is not None and process.returncode is None

    async def start(self) -> None:
        if self.alive:
            return
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
        """Read *proc.stderr* line-by-line into the bounded ring buffer."""
        assert proc.stderr is not None
        try:
            async for line in proc.stderr:
                self._stderr_ring.append(line)
        except (asyncio.CancelledError, ValueError):
            pass

    def _format_stderr_tail(self) -> str:
        """Return the last captured stderr content as a decoded string."""
        if not self._stderr_ring:
            return "(no stderr captured)"
        return b"".join(self._stderr_ring).decode("utf-8", errors="replace").rstrip()

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        async with self._write_lock:
            await self._send_unlocked(payload, binary_payload=binary_payload)

    async def exchange(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> dict[str, object]:
        """Send one request frame and read its response atomically.

        The write lock and read lock are both held for the pair so a competing
        reader can never steal this caller's response frame.  A parked streaming
        ``receive()`` reader holds only the read lock, so a concurrent batch
        ``send()`` can still write; the single-lock variant deadlocked the
        dedicated streaming worker because its read loop parks on ``readexactly``
        while append/commit tries to write on the same lock.
        """
        async with self._write_lock:
            await self._send_unlocked(payload, binary_payload=binary_payload)
            async with self._read_lock:
                return await self._receive_unlocked()

    async def _send_unlocked(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        process = self._require_process()
        if process.stdin is None:
            raise RuntimeError("worker_transport_invalid")
        frame = encode_frame(payload, binary_payload=binary_payload)
        async with asyncio.timeout(self._spec.io_timeout_seconds):
            process.stdin.write(frame)
            await process.stdin.drain()

    async def _drain_stderr_tail(self) -> None:
        """Briefly yield control to let the stderr drain task capture trailing lines on exit."""
        if self._stderr_task is not None and not self._stderr_task.done():
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await asyncio.sleep(0.01)

    async def receive(self) -> dict[str, object]:
        async with self._read_lock:
            return await self._receive_unlocked()

    async def _receive_unlocked(self) -> dict[str, object]:
        process = self._require_process()
        if process.stdout is None:
            raise RuntimeError("worker_transport_invalid")
        async with asyncio.timeout(self._spec.io_timeout_seconds):
            try:
                header = await process.stdout.readexactly(4)
            except IncompleteReadError as exc:
                await self._drain_stderr_tail()
                stderr_tail = self._format_stderr_tail()
                raise ProtocolError(
                    f"truncated worker frame (read {len(exc.partial)} of "
                    f"4 header bytes); worker stderr tail:\n{stderr_tail}"
                ) from exc
        size = struct.unpack(">I", header)[0]
        if not 0 < size <= MAX_FRAME_BYTES:
            raise ProtocolError("invalid worker frame size")
        async with asyncio.timeout(self._spec.io_timeout_seconds):
            try:
                body = await process.stdout.readexactly(size)
            except IncompleteReadError as exc:
                await self._drain_stderr_tail()
                stderr_tail = self._format_stderr_tail()
                raise ProtocolError(
                    f"truncated worker frame payload (read {len(exc.partial)} of "
                    f"{size} bytes); worker stderr tail:\n{stderr_tail}"
                ) from exc
        frame = decode_frame_body(body)
        if frame.get("type") == "error":
            await self._drain_stderr_tail()
            frame["stderr_tail"] = self._format_stderr_tail()
            logger.warning(
                "worker reported error frame %s; worker stderr tail:\n%s",
                frame.get("code", "unknown"),
                frame["stderr_tail"],
            )
        return frame

    async def abort(self) -> None:
        """Drop the reference first, then terminate so stale frames cannot leak."""
        process, self._process = self._process, None
        if self._stderr_task is not None:
            self._stderr_task.cancel()
            self._stderr_task = None
        if process is not None:
            await self._terminate(process)

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
