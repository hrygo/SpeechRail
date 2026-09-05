"""Regression tests for bounded ffmpeg I/O and subprocess cleanup."""

from __future__ import annotations

import asyncio
import contextlib
import os
import shutil
from pathlib import Path

import pytest

import speechrail.http.routes.audio as audio_module
from speechrail.http.routes.audio import _decode_pcm, _encode_container

_CHUNK_BYTES = 64 * 1024


@pytest.fixture
def captured_processes(monkeypatch: pytest.MonkeyPatch):
    processes = []
    create_subprocess_exec = audio_module.asyncio.create_subprocess_exec

    async def create_process(*args: object, **kwargs: object):
        process = await create_subprocess_exec(*args, **kwargs)
        processes.append(process)
        return process

    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)
    return processes


class _FakeStdin:
    def __init__(self) -> None:
        self.writes: list[bytes] = []
        self.closed = False

    def write(self, data: bytes) -> None:
        self.writes.append(bytes(data))

    async def drain(self) -> None:
        await asyncio.sleep(0)

    def close(self) -> None:
        self.closed = True


class _FakeStdout:
    def __init__(self, data: bytes) -> None:
        self._data = bytearray(data)
        self.read_requests: list[int] = []
        self.bounded_read_bytes = 0

    async def read(self, size: int = -1) -> bytes:
        self.read_requests.append(size)
        await asyncio.sleep(0)
        if not self._data:
            return b""
        if size < 0:
            size = len(self._data)
        chunk = bytes(self._data[:size])
        del self._data[:size]
        self.bounded_read_bytes += len(chunk)
        return chunk

    def discard_all(self) -> bytes:
        remaining = bytes(self._data)
        self._data.clear()
        return remaining


class _FakeProcess:
    def __init__(self, stdout: bytes) -> None:
        self.stdin = _FakeStdin()
        self.stdout = _FakeStdout(stdout)
        self.returncode: int | None = None
        self.killed = False
        self.waited = False
        self.communicate_calls = 0
        self.communicate_returncodes: list[int | None] = []

    def kill(self) -> None:
        self.killed = True
        self.returncode = -9

    async def wait(self) -> int:
        self.waited = True
        if self.returncode is None:
            self.returncode = 0
        return self.returncode

    async def communicate(self, input_data: bytes | None = None) -> tuple[bytes, bytes]:
        del input_data
        self.communicate_calls += 1
        self.communicate_returncodes.append(self.returncode)
        output = self.stdout.discard_all()
        if self.returncode is None:
            self.returncode = 0
        self.waited = True
        return output, b""


@pytest.fixture
def fake_process_factory(monkeypatch: pytest.MonkeyPatch):
    processes: list[_FakeProcess] = []

    async def create_process(*_: object, **__: object) -> _FakeProcess:
        process = _FakeProcess(b"\x00" * (1024 * 1024))
        processes.append(process)
        return process

    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: "/fake/ffmpeg")
    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)
    return processes


@pytest.mark.anyio
async def test_decode_limit_kills_child_after_bounded_probe(
    fake_process_factory: list[_FakeProcess],
) -> None:
    with pytest.raises(OverflowError, match="audio_too_large"):
        await _decode_pcm(b"not-a-wav", max_decompressed_bytes=8)

    process = fake_process_factory[0]
    assert process.killed is True
    assert process.waited is True
    assert process.communicate_calls == 1
    assert process.communicate_returncodes == [-9]
    assert process.stdout.bounded_read_bytes <= 9
    assert max(process.stdout.read_requests) <= _CHUNK_BYTES


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("output_size", "max_bytes", "expected_error"),
    [(8, 8, None), (9, 8, OverflowError)],
)
async def test_decode_accepts_exact_output_limit_and_rejects_limit_plus_one(
    monkeypatch: pytest.MonkeyPatch,
    output_size: int,
    max_bytes: int,
    expected_error: type[Exception] | None,
) -> None:
    process = _FakeProcess(b"\x00" * output_size)

    async def create_process(*_: object, **__: object) -> _FakeProcess:
        return process

    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: "/fake/ffmpeg")
    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)

    if expected_error is None:
        assert await _decode_pcm(b"not-a-wav", max_decompressed_bytes=max_bytes) == b"\x00" * 8
        assert process.killed is False
    else:
        with pytest.raises(expected_error, match="audio_too_large"):
            await _decode_pcm(b"not-a-wav", max_decompressed_bytes=max_bytes)
        assert process.killed is True
        assert process.waited is True


@pytest.mark.anyio
async def test_decode_reports_duration_when_duration_limit_is_first(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    process = _FakeProcess(b"\x00" * (32_000 + 1))

    async def create_process(*_: object, **__: object) -> _FakeProcess:
        return process

    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: "/fake/ffmpeg")
    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)

    with pytest.raises(ValueError, match="audio_too_long"):
        await _decode_pcm(
            b"not-a-wav",
            max_decompressed_bytes=100_000,
            max_audio_seconds=1,
        )
    assert process.killed is True
    assert process.waited is True


@pytest.mark.anyio
async def test_ffmpeg_stdin_is_written_in_bounded_chunks(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    process = _FakeProcess(b"\x00" * 2)

    async def create_process(*_: object, **__: object) -> _FakeProcess:
        return process

    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: "/fake/ffmpeg")
    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)
    payload = b"x" * (_CHUNK_BYTES * 2 + 1)
    assert await _decode_pcm(payload, max_decompressed_bytes=8) == b"\x00" * 2

    assert process.stdin.closed is True
    assert max(map(len, process.stdin.writes)) <= _CHUNK_BYTES
    assert b"".join(process.stdin.writes) == payload


def _write_fake_ffmpeg(tmp_path: Path) -> Path:
    script = tmp_path / "fake-ffmpeg"
    script.write_text(
        """#!/usr/bin/env python3
import os
import sys
import time

mode = os.environ.get("SPEECHRAIL_TEST_MODE")
if mode == "burst":
    sys.stdin.buffer.read()
    remaining = int(os.environ["SPEECHRAIL_TEST_OUTPUT_BYTES"])
    while remaining:
        chunk = b"\\x00" * min(65536, remaining)
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        remaining -= len(chunk)
elif mode == "infinite":
    sys.stdin.buffer.read()
    while True:
        sys.stdout.buffer.write(b"\\x00" * 65536)
        sys.stdout.buffer.flush()
else:
    while True:
        time.sleep(0.05)
""",
        encoding="utf-8",
    )
    script.chmod(0o755)
    return script


async def _wait_for_process(
    processes: list[asyncio.subprocess.Process],
) -> asyncio.subprocess.Process:
    deadline = asyncio.get_running_loop().time() + 2
    while asyncio.get_running_loop().time() < deadline:
        if processes:
            return processes[0]
        await asyncio.sleep(0.01)
    raise AssertionError("fake ffmpeg subprocess was not created")


def _assert_process_reaped(process: asyncio.subprocess.Process) -> None:
    assert process.returncode is not None
    with pytest.raises(ProcessLookupError):
        os.kill(process.pid, 0)


async def _cleanup_test_process(process: asyncio.subprocess.Process) -> None:
    if process.returncode is None:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
    with contextlib.suppress(BaseException):
        await process.communicate()


@pytest.mark.anyio
async def test_decode_cancellation_kills_and_reaps_real_child(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    captured_processes: list[asyncio.subprocess.Process],
) -> None:
    script = _write_fake_ffmpeg(tmp_path)
    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: str(script))

    task = asyncio.create_task(_decode_pcm(b"not-a-wav"))
    process: asyncio.subprocess.Process | None = None
    try:
        process = await _wait_for_process(captured_processes)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        _assert_process_reaped(process)
    finally:
        if not task.done():
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        for captured_process in captured_processes:
            await _cleanup_test_process(captured_process)


@pytest.mark.anyio
async def test_decode_timeout_kills_and_reaps_real_child(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    captured_processes: list[asyncio.subprocess.Process],
) -> None:
    script = _write_fake_ffmpeg(tmp_path)
    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: str(script))
    monkeypatch.setattr(audio_module, "_FFMPEG_TIMEOUT_SECONDS", 0.2)

    task = asyncio.create_task(_decode_pcm(b"not-a-wav"))
    process: asyncio.subprocess.Process | None = None
    try:
        process = await _wait_for_process(captured_processes)
        with pytest.raises(ValueError, match="audio_decode_timeout"):
            await asyncio.wait_for(task, timeout=1.0)
        _assert_process_reaped(process)
    finally:
        if not task.done():
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        for captured_process in captured_processes:
            await _cleanup_test_process(captured_process)


@pytest.mark.anyio
async def test_encode_timeout_uses_encode_error_and_reaps_real_child(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    captured_processes: list[asyncio.subprocess.Process],
) -> None:
    script = _write_fake_ffmpeg(tmp_path)
    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: str(script))
    monkeypatch.setattr(audio_module, "_FFMPEG_TIMEOUT_SECONDS", 0.2)

    task = asyncio.create_task(
        _encode_container(b"\x00\x00" * 100, sample_rate=16_000, response_format="mp3")
    )
    process: asyncio.subprocess.Process | None = None
    try:
        process = await _wait_for_process(captured_processes)
        with pytest.raises(ValueError, match="audio_encode_failed"):
            await asyncio.wait_for(task, timeout=1.0)
        _assert_process_reaped(process)
    finally:
        if not task.done():
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        for captured_process in captured_processes:
            await _cleanup_test_process(captured_process)


@pytest.mark.anyio
async def test_encode_cancellation_kills_and_reaps_real_child(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    captured_processes: list[asyncio.subprocess.Process],
) -> None:
    script = _write_fake_ffmpeg(tmp_path)
    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: str(script))

    task = asyncio.create_task(
        _encode_container(b"\x00\x00" * 100, sample_rate=16_000, response_format="mp3")
    )
    process: asyncio.subprocess.Process | None = None
    try:
        process = await _wait_for_process(captured_processes)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        _assert_process_reaped(process)
    finally:
        if not task.done():
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        for captured_process in captured_processes:
            await _cleanup_test_process(captured_process)


@pytest.mark.anyio
async def test_decode_limit_reaps_real_child_with_continuous_stdout(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    captured_processes: list[asyncio.subprocess.Process],
) -> None:
    script = _write_fake_ffmpeg(tmp_path)
    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: str(script))
    monkeypatch.setenv("SPEECHRAIL_TEST_MODE", "infinite")

    task = asyncio.create_task(_decode_pcm(b"not-a-wav", max_decompressed_bytes=_CHUNK_BYTES))
    process: asyncio.subprocess.Process | None = None
    try:
        process = await _wait_for_process(captured_processes)
        with pytest.raises(OverflowError, match="audio_too_large"):
            await asyncio.wait_for(task, timeout=1.0)
        _assert_process_reaped(process)
    finally:
        if not task.done():
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        if process is not None:
            await _cleanup_test_process(process)


@pytest.mark.anyio
async def test_encode_output_limit_is_bounded_and_reaped(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    process = _FakeProcess(b"\x00" * 9)

    async def create_process(*_: object, **__: object) -> _FakeProcess:
        return process

    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: "/fake/ffmpeg")
    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)
    monkeypatch.setattr(audio_module, "_MAX_ENCODED_AUDIO_BYTES", 8)

    with pytest.raises(ValueError, match="audio_encode_failed"):
        await _encode_container(b"\x00\x00", sample_rate=16_000, response_format="mp3")
    assert process.killed is True
    assert process.waited is True
    assert process.communicate_calls == 1


@pytest.mark.anyio
@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg is unavailable")
async def test_real_ffmpeg_encode_decode_roundtrip() -> None:
    pcm = b"\x00\x00" * 1_600
    encoded = await _encode_container(pcm, sample_rate=16_000, response_format="mp3")
    decoded = await _decode_pcm(encoded, max_decompressed_bytes=32_000)
    assert encoded
    assert decoded
    assert len(decoded) % 2 == 0
