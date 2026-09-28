"""Bounded async ffmpeg process protocol shared by audio decode and clone transcode."""

from __future__ import annotations

import asyncio

import pytest

import speechrail.application.ffmpeg as ffmpeg_module
from speechrail.application.ffmpeg import (
    FFMPEG_IO_CHUNK_BYTES,
    FFMPEG_TIMEOUT_SECONDS,
    FFmpegOutputLimitError,
    run_ffmpeg_subprocess,
)


class _FakeStdin:
    def __init__(self, *, fail: bool = False) -> None:
        self.writes: list[bytes] = []
        self.closed = False
        self._fail = fail
        self.closed_event = asyncio.Event()

    def write(self, data: bytes) -> None:
        if self._fail:
            raise BrokenPipeError("ffmpeg stdin closed")
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


class _HangingStdout(_FakeStdout):
    """A child that never closes stdout until it is killed."""

    def __init__(self, released: asyncio.Event) -> None:
        super().__init__(b"")
        self._released = released
        self.read_requests.append(-1)

    async def read(self, size: int = -1) -> bytes:
        del size
        self.read_requests.append(-1)
        await self._released.wait()
        return b""


class _FakeProcess:
    def __init__(self, stdout: bytes, *, exit_code: int = 0, hang: bool = False) -> None:
        self.stdin = _FakeStdin()
        self._released = asyncio.Event()
        self.stdout = _HangingStdout(self._released) if hang else _FakeStdout(stdout)
        self.returncode: int | None = None
        self.killed = False
        self.communicate_calls = 0
        self._exit_code = exit_code

    def kill(self) -> None:
        self.killed = True
        self.returncode = -9
        self._released.set()

    async def wait(self) -> int:
        if self.returncode is None:
            self.returncode = self._exit_code
        return self.returncode

    async def communicate(self, input_data: bytes | None = None) -> tuple[bytes, bytes]:
        del input_data
        self.communicate_calls += 1
        output = self.stdout.discard_all()
        if self.returncode is None:
            self.returncode = self._exit_code
        return output, b""


class _BrokenPipeProcess(_FakeProcess):
    def __init__(self) -> None:
        super().__init__(b"")
        self.stdin = _FakeStdin(fail=True)
        self.returncode = -1


@pytest.fixture
def fake_processes(monkeypatch: pytest.MonkeyPatch):
    created: list[_FakeProcess] = []

    def install(process: _FakeProcess) -> None:
        async def create_process(*_: object, **__: object) -> _FakeProcess:
            created.append(process)
            return process

        monkeypatch.setattr(ffmpeg_module.asyncio, "create_subprocess_exec", create_process)

    return created, install


async def _run(
    payload: bytes = b"raw-audio",
    *,
    max_output_bytes: int = 1024,
    timeout_seconds: float = 5.0,
) -> bytes:
    return await run_ffmpeg_subprocess(
        ("ffmpeg", "-i", "pipe:0", "pipe:1"),
        payload,
        max_output_bytes=max_output_bytes,
        output_limit_error=OverflowError("audio_too_large"),
        timeout_error=ValueError("audio_decode_timeout"),
        failure_error=ValueError("audio_decode_failed"),
        timeout_seconds=timeout_seconds,
    )


@pytest.mark.anyio
async def test_default_timeout_matches_shared_constant() -> None:
    assert FFMPEG_TIMEOUT_SECONDS == 15.0
    assert FFMPEG_IO_CHUNK_BYTES == 64 * 1024


@pytest.mark.anyio
async def test_stdin_is_chunked_and_closed(fake_processes) -> None:
    created, install = fake_processes
    install(_FakeProcess(b"decoded-pcm"))

    payload = b"x" * (FFMPEG_IO_CHUNK_BYTES * 2 + 17)
    output = await _run(payload, max_output_bytes=4096)

    process = created[0]
    assert output == b"decoded-pcm"
    assert sum(len(chunk) for chunk in process.stdin.writes) == len(payload)
    assert all(len(chunk) <= FFMPEG_IO_CHUNK_BYTES for chunk in process.stdin.writes)
    assert process.stdin.closed is True
    assert process.killed is False


@pytest.mark.anyio
async def test_output_limit_reads_one_probe_byte_and_kills(fake_processes) -> None:
    created, install = fake_processes
    install(_FakeProcess(b"a" * 64))

    with pytest.raises(OverflowError, match="audio_too_large"):
        await _run(b"raw-audio", max_output_bytes=10)

    process = created[0]
    assert process.killed is True
    assert process.communicate_calls == 1
    assert process.stdout.bounded_read_bytes <= 11
    assert max(process.stdout.read_requests) <= FFMPEG_IO_CHUNK_BYTES


@pytest.mark.anyio
async def test_broken_pipe_is_mapped_to_failure_error(fake_processes) -> None:
    _, install = fake_processes
    install(_BrokenPipeProcess())

    with pytest.raises(ValueError, match="audio_decode_failed"):
        await _run(b"raw-audio")


@pytest.mark.anyio
async def test_timeout_reaps_the_process(fake_processes) -> None:
    created, install = fake_processes
    install(_FakeProcess(b"", hang=True))

    with pytest.raises(ValueError, match="audio_decode_timeout"):
        await _run(b"raw-audio", timeout_seconds=0.05)

    process = created[0]
    assert process.killed is True
    assert process.communicate_calls == 1


@pytest.mark.anyio
async def test_cancellation_reaps_the_process(fake_processes) -> None:
    created, install = fake_processes
    install(_FakeProcess(b"", hang=True))

    task = asyncio.create_task(_run(b"raw-audio", timeout_seconds=5.0))
    await asyncio.sleep(0.01)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    process = created[0]
    assert process.killed is True
    assert process.communicate_calls == 1


@pytest.mark.anyio
async def test_nonzero_exit_is_a_failure(fake_processes) -> None:
    _, install = fake_processes
    install(_FakeProcess(b"partial", exit_code=1))

    with pytest.raises(ValueError, match="audio_decode_failed"):
        await _run(b"raw-audio")


@pytest.mark.anyio
async def test_event_loop_keeps_ticking_while_transcode_waits(fake_processes) -> None:
    _, install = fake_processes
    install(_FakeProcess(b"decoded", hang=False))

    ticks = 0

    async def _ticker() -> None:
        nonlocal ticks
        while True:
            ticks += 1
            await asyncio.sleep(0)

    ticker = asyncio.create_task(_ticker())
    try:
        await _run(b"raw-audio")
    finally:
        ticker.cancel()
        await asyncio.gather(ticker, return_exceptions=True)
    assert ticks > 0


def test_output_limit_error_carries_public_error() -> None:
    marker = FFmpegOutputLimitError(OverflowError("audio_too_large"))
    assert isinstance(marker.error, OverflowError)
    assert str(marker) == "audio_too_large"
