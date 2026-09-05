"""Regression tests for bounded ffmpeg I/O and subprocess cleanup."""

from __future__ import annotations

import asyncio
import contextlib
import os
import shutil
from collections.abc import AsyncIterator
from pathlib import Path

import pytest

import speechrail.http.routes.audio as audio_module
from speechrail.application.tts_delivery import TTSDeliveryError
from speechrail.http.routes.audio import (
    _decode_pcm,
    _encode_container,
    _stream_encode_container,
)

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
        self.closed_event = asyncio.Event()

    def write(self, data: bytes) -> None:
        self.writes.append(bytes(data))

    async def drain(self) -> None:
        await asyncio.sleep(0)

    def close(self) -> None:
        self.closed = True
        self.closed_event.set()


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


class _CloseAwareStdout(_FakeStdout):
    def __init__(self, data: bytes, stdin: _FakeStdin) -> None:
        super().__init__(data)
        self._stdin = stdin

    async def read(self, size: int = -1) -> bytes:
        if self._data:
            return await super().read(size)
        await self._stdin.closed_event.wait()
        return b""


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


class _FailingStdin(_FakeStdin):
    def __init__(self) -> None:
        super().__init__()
        self.write_attempted = False

    def write(self, data: bytes) -> None:
        del data
        self.write_attempted = True
        raise BrokenPipeError("ffmpeg stdin closed")


class _EarlyEofProcess(_FakeProcess):
    def __init__(self) -> None:
        super().__init__(b"")
        self.stdin = _FailingStdin()
        self.returncode = -1


class _ContinuousPcmSource:
    def __init__(self) -> None:
        self.closed = False

    def __aiter__(self) -> _ContinuousPcmSource:
        return self

    async def __anext__(self) -> bytes:
        await asyncio.sleep(0)
        return b"\x00\x00"

    async def aclose(self) -> None:
        self.closed = True


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
async def test_decode_uses_configured_ffmpeg_path_when_path_is_empty(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    target = tmp_path / "vendor" / "releases" / "ffmpeg"
    target.parent.mkdir(parents=True)
    target.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    target.chmod(0o755)
    current = tmp_path / "vendor" / "current"
    current.symlink_to(target.parent, target_is_directory=True)
    process = _FakeProcess(b"\x00\x00")
    calls: list[tuple[tuple[object, ...], dict[str, object]]] = []

    async def create_process(*args: object, **kwargs: object) -> _FakeProcess:
        calls.append((args, kwargs))
        return process

    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)
    monkeypatch.setattr(audio_module.shutil, "which", lambda _: None)
    monkeypatch.setattr(audio_module, "_FFMPEG_FALLBACKS", ())

    assert await _decode_pcm(
        b"not-a-wav",
        max_decompressed_bytes=8,
        ffmpeg_path=current / target.name,
    ) == b"\x00\x00"
    assert calls[0][0][0] == str(target.resolve())


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


async def _pcm_source(chunks: list[bytes]) -> AsyncIterator[bytes]:
    for chunk in chunks:
        await asyncio.sleep(0)
        yield chunk


@pytest.mark.anyio
async def test_stream_encode_feeds_pcm_incrementally_and_uses_fixed_24k_mono_command(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    process = _FakeProcess(b"encoded-output")
    process.stdout = _CloseAwareStdout(b"encoded-output", process.stdin)
    calls: list[tuple[tuple[object, ...], dict[str, object]]] = []

    async def create_process(*args: object, **kwargs: object) -> _FakeProcess:
        calls.append((args, kwargs))
        return process

    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: "/fake/ffmpeg")
    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)
    pcm_chunks = [b"\x00\x00" * 3, b"\x01\x00" * 5]

    encoded = [
        chunk
        async for chunk in _stream_encode_container(
            _pcm_source(pcm_chunks), sample_rate=24_000, response_format="mp3"
        )
    ]

    assert b"".join(encoded) == b"encoded-output"
    assert b"".join(process.stdin.writes) == b"".join(pcm_chunks)
    assert process.stdin.closed is True
    command = calls[0][0]
    assert command[:1] == ("/fake/ffmpeg",)
    assert command[command.index("-ar") + 1 : command.index("-ar") + 2] == ("24000",)
    assert command[command.index("-ac") + 1 : command.index("-ac") + 2] == ("1",)
    assert command[-1:] == ("pipe:1",)


@pytest.mark.anyio
async def test_stream_encode_uses_configured_ffmpeg_path_when_path_is_empty(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    target = tmp_path / "vendor" / "releases" / "ffmpeg"
    target.parent.mkdir(parents=True)
    target.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    target.chmod(0o755)
    current = tmp_path / "vendor" / "current"
    current.symlink_to(target.parent, target_is_directory=True)
    process = _FakeProcess(b"encoded-output")
    process.stdout = _CloseAwareStdout(b"encoded-output", process.stdin)
    calls: list[tuple[tuple[object, ...], dict[str, object]]] = []

    async def create_process(*args: object, **kwargs: object) -> _FakeProcess:
        calls.append((args, kwargs))
        return process

    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)
    monkeypatch.setattr(audio_module.shutil, "which", lambda _: None)
    monkeypatch.setattr(audio_module, "_FFMPEG_FALLBACKS", ())

    encoded = [
        chunk
        async for chunk in _stream_encode_container(
            _pcm_source([b"\x00\x00"]),
            sample_rate=24_000,
            response_format="mp3",
            ffmpeg_path=current / target.name,
        )
    ]

    assert b"".join(encoded) == b"encoded-output"
    assert calls[0][0][0] == str(target.resolve())


@pytest.mark.anyio
async def test_stream_encode_rejects_odd_pcm_and_empty_audio(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    processes: list[_FakeProcess] = []

    async def create_process(*_: object, **__: object) -> _FakeProcess:
        process = _FakeProcess(b"")
        processes.append(process)
        return process

    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: "/fake/ffmpeg")
    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)

    with pytest.raises(TTSDeliveryError, match="tts_audio_invalid"):
        _ = [
            chunk
            async for chunk in _stream_encode_container(
                _pcm_source([b"\x00"]), sample_rate=24_000, response_format="flac"
            )
        ]
    with pytest.raises(ValueError, match="audio_encode_failed"):
        _ = [
            chunk
            async for chunk in _stream_encode_container(
                _pcm_source([]), sample_rate=24_000, response_format="flac"
            )
        ]
    assert all(process.waited for process in processes)


@pytest.mark.anyio
async def test_stream_encode_output_limit_reaps_child(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    process = _FakeProcess(b"123456789")

    async def create_process(*_: object, **__: object) -> _FakeProcess:
        return process

    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: "/fake/ffmpeg")
    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)
    monkeypatch.setattr(audio_module, "_MAX_ENCODED_AUDIO_BYTES", 8)

    with pytest.raises(ValueError, match="audio_encode_failed"):
        _ = [
            chunk
            async for chunk in _stream_encode_container(
                _pcm_source([b"\x00\x00"]), sample_rate=24_000, response_format="mp3"
            )
        ]

    assert process.killed is True
    assert process.waited is True


@pytest.mark.anyio
async def test_stream_encode_early_stdout_eof_cancels_continuous_input(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    process = _EarlyEofProcess()

    async def create_process(*_: object, **__: object) -> _EarlyEofProcess:
        return process

    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: "/fake/ffmpeg")
    monkeypatch.setattr(audio_module.asyncio, "create_subprocess_exec", create_process)
    source = _ContinuousPcmSource()

    async def consume() -> None:
        async for _chunk in _stream_encode_container(
            source, sample_rate=24_000, response_format="mp3"
        ):
            pass

    with pytest.raises(ValueError, match="audio_encode_failed"):
        await asyncio.wait_for(consume(), timeout=1)

    assert process.stdin.write_attempted is True
    assert process.stdin.closed is True
    assert process.waited is True
    assert process.communicate_calls == 1
    assert source.closed is True


@pytest.mark.anyio
async def test_stream_encode_cancellation_kills_and_reaps_real_child(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    captured_processes: list[asyncio.subprocess.Process],
) -> None:
    script = _write_fake_ffmpeg(tmp_path)
    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", lambda: str(script))

    async def consume() -> None:
        async for _chunk in _stream_encode_container(
            _pcm_source([b"\x00\x00"]), sample_rate=24_000, response_format="mp3"
        ):
            pass

    task = asyncio.create_task(consume())
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
@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg is unavailable")
@pytest.mark.parametrize("response_format", ["mp3", "opus", "aac", "flac"])
async def test_real_ffmpeg_stream_encode_decode_roundtrip(response_format: str) -> None:
    pcm = b"\x00\x00" * 2_400
    encoded = b"".join(
        [
            chunk
            async for chunk in _stream_encode_container(
                _pcm_source([pcm[:1_024], pcm[1_024:3_072], pcm[3_072:]]),
                sample_rate=24_000,
                response_format=response_format,
            )
        ]
    )

    decoded = await _decode_pcm(encoded, max_decompressed_bytes=128_000)

    assert encoded
    assert decoded
    assert len(decoded) % 2 == 0


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
