"""Private, bounded IPC for the single CoreML diarization worker.

This module is deliberately transport-private.  Public clients only use the
OpenAI HTTP/WebSocket surfaces; the Swift process is addressed through a
length-prefixed local pipe and never binds a socket.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import struct
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from speechrail.runtime.cleanup import join_cleanup

MAX_IPC_PAYLOAD_BYTES = 4 * 1024 * 1024
_MAX_HEADER_BYTES = 64 * 1024
_PROTOCOL_VERSION = 1
_STDERR_TAIL_BYTES = 8 * 1024
_STDERR_READ_CHUNK_BYTES = 1_024
MEETING_DYNAMIC_SDK_REVISION = "5c19d5e12320e22bbfb7a1877b089d2665a69add"
MEETING_DYNAMIC_MODEL_REVISION = "7eab74f3463c736418d0eb10296261ae581146c9"


def encode_message(header: Mapping[str, object], audio: bytes = b"") -> bytes:
    """Encode one local IPC packet; PCM remains binary after the JSON header."""

    if len(audio) > MAX_IPC_PAYLOAD_BYTES:
        raise ValueError("diarization IPC payload exceeds limit")
    encoded_header = json.dumps(dict(header), separators=(",", ":")).encode("utf-8")
    if len(encoded_header) > _MAX_HEADER_BYTES:
        raise ValueError("diarization IPC header exceeds limit")
    return struct.pack(">II", len(encoded_header), len(audio)) + encoded_header + audio


def decode_message(packet: bytes) -> tuple[dict[str, object], bytes]:
    """Validate and decode exactly one IPC packet."""

    if len(packet) < 8:
        raise ValueError("diarization IPC packet is truncated")
    header_size, payload_size = struct.unpack(">II", packet[:8])
    if header_size > _MAX_HEADER_BYTES or payload_size > MAX_IPC_PAYLOAD_BYTES:
        raise ValueError("diarization IPC packet exceeds header or payload limit")
    expected = 8 + header_size + payload_size
    if len(packet) != expected:
        raise ValueError("diarization IPC packet length is invalid")
    try:
        raw_header = json.loads(packet[8 : 8 + header_size])
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("diarization IPC header is not valid JSON") from exc
    if not isinstance(raw_header, dict):
        raise ValueError("diarization IPC header must be an object")
    return raw_header, packet[8 + header_size :]


async def _read_packet(reader: asyncio.StreamReader) -> tuple[dict[str, object], bytes]:
    prefix = await reader.readexactly(8)
    header_size, payload_size = struct.unpack(">II", prefix)
    if header_size > _MAX_HEADER_BYTES or payload_size > MAX_IPC_PAYLOAD_BYTES:
        raise ValueError("diarization worker returned an oversized packet")
    body = await reader.readexactly(header_size + payload_size)
    return decode_message(prefix + body)


@dataclass(slots=True)
class CoreMLWorkerProcess:
    """One supervised, single-session Swift worker process."""

    executable: Path
    model_path: Path
    protocol_version: int = _PROTOCOL_VERSION
    backend: str = "sortformer"
    policy_path: Path | None = None
    calibration_candidates_path: Path | None = None
    zero_vote_reembed: bool = False
    process: asyncio.subprocess.Process | None = None
    _reader: asyncio.StreamReader | None = None
    _writer: asyncio.StreamWriter | None = None
    _lock: asyncio.Lock | None = None
    _stderr_tail: bytearray = field(default_factory=bytearray)
    _stderr_task: asyncio.Task[None] | None = None
    _close_task: asyncio.Task[None] | None = None

    async def start(self) -> None:
        if self.process is not None and self.process.returncode is None:
            return
        if self.process is not None:
            await self.close()
        if not self.executable.is_file() or not self.model_path.is_dir():
            raise RuntimeError("CoreML diarization worker or compiled model is unavailable")
        if self.zero_vote_reembed and (
            self.backend != "meeting_dynamic" or self.calibration_candidates_path is None
        ):
            raise RuntimeError(
                "zero-vote re-embedding is restricted to meeting-diarization calibration"
            )
        self._close_task = None
        extra: list[str] = []
        if self.calibration_candidates_path is not None and self.backend != "meeting_dynamic":
            raise RuntimeError("calibration candidates are restricted to meeting diarization")
        if self.backend == "meeting_dynamic":
            if self.protocol_version != 2 or self.policy_path is None:
                raise RuntimeError("dynamic diarization requires explicit protocol and policy")
            extra = ["--backend", self.backend, "--policy", str(self.policy_path)]
            if self.calibration_candidates_path is not None:
                extra += ["--calibration-candidates", str(self.calibration_candidates_path)]
            if self.zero_vote_reembed:
                extra.append("--zero-vote-reembed")
        # Cancellation may interrupt preflight, but cannot leave an OS child
        # created later without assigning it to this transport first.
        await join_cleanup(
            asyncio.create_task(self._launch(extra), name="diarization-worker-launch")
        )
        response, _ = await self.request({"operation": "preflight"})
        if response.get("ok") is not True or (
            self.backend == "meeting_dynamic"
            and (
                response.get("backend") != self.backend
                or response.get("sdk_revision") != MEETING_DYNAMIC_SDK_REVISION
                or response.get("model_revision") != MEETING_DYNAMIC_MODEL_REVISION
                or response.get("zero_vote_reembed", False) is not self.zero_vote_reembed
            )
        ):
            await self.close()
            raise RuntimeError("CoreML diarization worker preflight failed")

    async def _launch(self, extra: list[str]) -> None:
        process = await asyncio.create_subprocess_exec(
            str(self.executable),
            "--model",
            str(self.model_path),
            "--protocol-version",
            str(self.protocol_version),
            *extra,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        assert (
            process.stdin is not None and process.stdout is not None and process.stderr is not None
        )
        self.process = process
        self._writer = process.stdin
        self._reader = process.stdout
        self._lock = asyncio.Lock()
        self._stderr_tail.clear()
        self._stderr_task = asyncio.create_task(
            self._drain_stderr(process.stderr), name="coreml-diarization-stderr-drain"
        )
    async def request(
        self, header: Mapping[str, object], audio: bytes = b""
    ) -> tuple[dict[str, object], bytes]:
        if self._writer is None or self._reader is None or self._lock is None:
            raise RuntimeError("CoreML diarization worker is not running")
        packet_header = {**header, "protocol_version": self.protocol_version}
        packet = encode_message(packet_header, audio)
        try:
            async with self._lock:
                self._writer.write(packet)
                await self._writer.drain()
                response, payload = await _read_packet(self._reader)
        except (
            BrokenPipeError,
            ConnectionError,
            asyncio.IncompleteReadError,
            OSError,
            ValueError,
        ) as exc:
            await self._yield_stderr_drain()
            raise RuntimeError(self._failure_summary()) from exc
        if (
            type(response.get("protocol_version")) is not int
            or response.get("protocol_version") != self.protocol_version
        ):
            raise RuntimeError("CoreML diarization IPC protocol mismatch")
        return response, payload

    async def _drain_stderr(self, reader: asyncio.StreamReader) -> None:
        """Drain child stderr into a fixed-size private tail to prevent pipe backpressure."""

        try:
            while chunk := await reader.read(_STDERR_READ_CHUNK_BYTES):
                self._stderr_tail.extend(chunk)
                if len(self._stderr_tail) > _STDERR_TAIL_BYTES:
                    del self._stderr_tail[: len(self._stderr_tail) - _STDERR_TAIL_BYTES]
        except asyncio.CancelledError, ValueError:
            pass

    async def _yield_stderr_drain(self) -> None:
        task = self._stderr_task
        if task is not None and not task.done():
            await asyncio.sleep(0)

    def _failure_summary(self) -> str:
        """Expose only process state and bounded stderr size, never child output."""

        process = self.process
        exit_code = (
            "unknown" if process is None or process.returncode is None else str(process.returncode)
        )
        return (
            "CoreML diarization worker transport failed "
            f"(exit_code={exit_code}, stderr_bytes={len(self._stderr_tail)})"
        )

    async def close(self) -> None:
        if self._close_task is None or (
            self._close_task.done() and self._close_task.exception() is not None
        ):
            self._close_task = asyncio.create_task(
                self._close_once(), name="diarization-worker-close"
            )
        await join_cleanup(self._close_task)

    async def _close_once(self) -> None:
        process = self.process
        writer = self._writer
        stderr_task = self._stderr_task
        if process is None:
            return
        try:
            if writer is not None and process.returncode is None:
                with contextlib.suppress(Exception):
                    writer.write(
                        encode_message(
                            {"protocol_version": self.protocol_version, "operation": "cancel"}
                        )
                    )
                    async with asyncio.timeout(0.5):
                        await writer.drain()
                writer.close()
            if process.returncode is None:
                try:
                    await asyncio.wait_for(process.wait(), timeout=2)
                except TimeoutError:
                    process.terminate()
                    try:
                        await asyncio.wait_for(process.wait(), timeout=2)
                    except TimeoutError:
                        process.kill()
                        await asyncio.wait_for(process.wait(), timeout=10)
            if writer is not None:
                with contextlib.suppress(Exception):
                    async with asyncio.timeout(2):
                        await writer.wait_closed()
            if stderr_task is not None:
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    async with asyncio.timeout(2):
                        await stderr_task
        finally:
            # The supervisor keeps ownership until the exact child has exited.
            # Only then can a new session acquire a worker lease.
            if process.returncode is not None:
                self.process = None
                self._writer = None
                self._reader = None
                self._lock = None
                self._stderr_task = None
