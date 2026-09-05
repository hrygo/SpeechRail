"""有界上传解码器的确定性回归测试。"""

from __future__ import annotations

import asyncio
import io
import shutil
import struct
import subprocess
import wave
from collections.abc import AsyncIterator
from pathlib import Path
from typing import cast

import pytest
from fastapi import UploadFile

import speechrail.application.audio_stream as audio_stream
from speechrail.application.audio_stream import PcmByteCounter, decode_upload

_CHUNK_BYTES = 64 * 1024


class _FakeUpload:
    """模拟临时 UploadFile, 并记录是否发生了两遍有界读取。"""

    def __init__(self, payload: bytes, *, blocked: bool = False) -> None:
        self._payload = payload
        self._position = 0
        self._blocked = blocked
        self._released = asyncio.Event()
        self.read_sizes: list[int] = []
        self.seek_offsets: list[int] = []
        self.closed = False

    async def read(self, size: int = -1) -> bytes:
        self.read_sizes.append(size)
        if self._blocked:
            await self._released.wait()
        await asyncio.sleep(0)
        if self._position >= len(self._payload):
            return b""
        end = len(self._payload)
        if size >= 0:
            end = min(end, self._position + size)
        chunk = self._payload[self._position : end]
        self._position = end
        return chunk

    async def seek(self, offset: int) -> int:
        self.seek_offsets.append(offset)
        await asyncio.sleep(0)
        self._position = offset
        return self._position

    async def close(self) -> None:
        self.closed = True
        self._released.set()


class _FakeStdin:
    def __init__(self, *, blocked: bool = False) -> None:
        self.writes: list[bytes] = []
        self.closed = False
        self._blocked = blocked
        self._released = asyncio.Event()

    def write(self, data: bytes) -> None:
        self.writes.append(bytes(data))

    async def drain(self) -> None:
        if self._blocked:
            await self._released.wait()
        await asyncio.sleep(0)

    def close(self) -> None:
        self.closed = True
        self._released.set()


class _FakeStdout:
    def __init__(
        self,
        chunks: list[bytes],
        *,
        blocked: bool = False,
        continuous: bool = False,
    ) -> None:
        self._chunks = list(chunks)
        self._blocked = blocked
        self._continuous = continuous
        self._released = asyncio.Event()
        self.read_sizes: list[int] = []

    async def read(self, size: int = -1) -> bytes:
        self.read_sizes.append(size)
        if self._blocked:
            await self._released.wait()
        await asyncio.sleep(0)
        if not self._chunks:
            if self._continuous:
                return b"\x00" * min(_CHUNK_BYTES, max(size, 0))
            return b""
        chunk = self._chunks.pop(0)
        if size >= 0 and len(chunk) > size:
            self._chunks.insert(0, chunk[size:])
            return chunk[:size]
        return chunk

    def release(self) -> None:
        self._released.set()


class _FakeProcess:
    def __init__(
        self,
        chunks: list[bytes],
        *,
        returncode: int = 0,
        blocked_stdin: bool = False,
        blocked_stdout: bool = False,
        continuous_stdout: bool = False,
    ) -> None:
        self.stdin = _FakeStdin(blocked=blocked_stdin)
        self.stdout = _FakeStdout(
            chunks,
            blocked=blocked_stdout,
            continuous=continuous_stdout,
        )
        self.returncode: int | None = None
        self._expected_returncode = returncode
        self.killed = False
        self.waited = False

    def kill(self) -> None:
        self.killed = True
        self.returncode = -9
        self.stdin.close()
        self.stdout.release()

    async def wait(self) -> int:
        self.waited = True
        await asyncio.sleep(0)
        if self.returncode is None:
            self.returncode = self._expected_returncode
        return self.returncode


def _patch_process(
    monkeypatch: pytest.MonkeyPatch,
    process: _FakeProcess,
) -> list[tuple[tuple[object, ...], dict[str, object]]]:
    calls: list[tuple[tuple[object, ...], dict[str, object]]] = []

    async def create_process(
        *args: object,
        **kwargs: object,
    ) -> _FakeProcess:
        calls.append((args, kwargs))
        return process

    monkeypatch.setattr(audio_stream.asyncio, "create_subprocess_exec", create_process)
    return calls


def _as_upload(payload: bytes) -> tuple[UploadFile, _FakeUpload]:
    fake = _FakeUpload(payload)
    return cast(UploadFile, fake), fake


def _blocked_upload(payload: bytes) -> tuple[UploadFile, _FakeUpload]:
    fake = _FakeUpload(payload, blocked=True)
    return cast(UploadFile, fake), fake


async def _collect(stream: AsyncIterator[bytes]) -> bytes:
    return b"".join([chunk async for chunk in stream])


def test_pcm_byte_counter_rejects_before_accepting() -> None:
    counter = PcmByteCounter(max_samples=16_000)

    counter.accept(32_000)

    with pytest.raises(ValueError, match="audio_too_long"):
        counter.accept(2)

    assert counter.accepted_bytes == 32_000


def test_pcm_byte_counter_rejects_odd_or_over_limit_initial_state() -> None:
    with pytest.raises(ValueError, match="pcm_bytes_odd"):
        PcmByteCounter(max_samples=16_000, accepted_bytes=1)
    with pytest.raises(ValueError, match="audio_too_long"):
        PcmByteCounter(max_samples=16_000, accepted_bytes=32_002)

    counter = PcmByteCounter(max_samples=16_000)
    with pytest.raises(ValueError, match="pcm_bytes_odd"):
        counter.accept(1)
    assert counter.accepted_bytes == 0


@pytest.mark.anyio
async def test_decode_streams_even_pcm_and_fixed_ffmpeg_command(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload = b"x" * (_CHUNK_BYTES * 2 + 3)
    upload, fake_upload = _as_upload(payload)
    process = _FakeProcess([b"\x01", b"\x02\x03", b"\x04\x05\x06"])
    calls = _patch_process(monkeypatch, process)

    decoded = await _collect(
        decode_upload(
            upload,
            max_upload_bytes=len(payload),
            max_audio_seconds=1,
            ffmpeg_executable="/fake/ffmpeg",
        )
    )

    assert decoded == b"\x01\x02\x03\x04\x05\x06"
    assert len(decoded) % 2 == 0
    assert process.stdin.closed is True
    assert process.waited is True
    assert fake_upload.closed is True
    assert len(fake_upload.seek_offsets) == 2
    assert max(fake_upload.read_sizes) <= _CHUNK_BYTES
    assert max(map(len, process.stdin.writes)) <= _CHUNK_BYTES
    assert b"".join(process.stdin.writes) == payload

    command, kwargs = calls[0]
    assert command == (
        "/fake/ffmpeg",
        "-nostdin",
        "-threads",
        "1",
        "-v",
        "error",
        "-i",
        "pipe:0",
        "-f",
        "s16le",
        "-ar",
        "16000",
        "-ac",
        "1",
        "pipe:1",
    )
    assert kwargs["stdin"] is audio_stream.asyncio.subprocess.PIPE
    assert kwargs["stdout"] is audio_stream.asyncio.subprocess.PIPE
    assert kwargs["stderr"] is audio_stream.asyncio.subprocess.DEVNULL


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
    configured = current / target.name
    upload, _ = _as_upload(b"input")
    process = _FakeProcess([b"\x00\x00"])
    calls = _patch_process(monkeypatch, process)
    monkeypatch.setattr(audio_stream.shutil, "which", lambda _: None)

    assert await _collect(
        decode_upload(
            upload,
            max_upload_bytes=100,
            max_audio_seconds=1,
            ffmpeg_path=configured,
        )
    ) == b"\x00\x00"

    assert calls[0][0][0] == str(target.resolve())


@pytest.mark.anyio
async def test_consumer_pause_does_not_consume_decoder_timeout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    upload, fake_upload = _as_upload(b"input")
    process = _FakeProcess([b"\x00\x00", b"\x02\x02"])
    _patch_process(monkeypatch, process)
    stream = decode_upload(
        upload,
        max_upload_bytes=100,
        max_audio_seconds=1,
        ffmpeg_executable="/fake/ffmpeg",
        timeout_seconds=0.01,
    )

    iterator = stream.__aiter__()
    assert await iterator.__anext__() == b"\x00\x00"
    await asyncio.sleep(0.03)
    assert await iterator.__anext__() == b"\x02\x02"
    with pytest.raises(StopAsyncIteration):
        await iterator.__anext__()
    assert process.killed is False
    assert process.waited is True
    assert fake_upload.closed is True


@pytest.mark.anyio
async def test_decode_splits_oversized_fake_reads_into_bounded_blocks(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    upload, _ = _as_upload(b"input")
    process = _FakeProcess([b"\x00" * (_CHUNK_BYTES + 2)])
    _patch_process(monkeypatch, process)

    chunks = [
        chunk
        async for chunk in decode_upload(
            upload,
            max_upload_bytes=100,
            max_audio_seconds=3,
            ffmpeg_executable="/fake/ffmpeg",
        )
    ]

    assert b"".join(chunks) == b"\x00" * (_CHUNK_BYTES + 2)
    assert max(map(len, chunks)) <= _CHUNK_BYTES
    assert all(len(chunk) % 2 == 0 for chunk in chunks)


@pytest.mark.anyio
async def test_upload_limit_is_rejected_before_starting_ffmpeg(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    upload, fake_upload = _as_upload(b"12345")
    process = _FakeProcess([b"\x00\x00"])
    calls = _patch_process(monkeypatch, process)

    with pytest.raises(OverflowError, match="audio_too_large"):
        await _collect(
            decode_upload(
                upload,
                max_upload_bytes=4,
                max_audio_seconds=1,
                ffmpeg_executable="/fake/ffmpeg",
            )
        )

    assert calls == []
    assert fake_upload.closed is True


@pytest.mark.anyio
async def test_upload_probe_timeout_is_bounded_before_starting_ffmpeg(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    upload, fake_upload = _blocked_upload(b"input")
    process = _FakeProcess([b"\x00\x00"])
    calls = _patch_process(monkeypatch, process)

    with pytest.raises(ValueError, match="audio_decode_timeout"):
        await _collect(
            decode_upload(
                upload,
                max_upload_bytes=100,
                max_audio_seconds=1,
                ffmpeg_executable="/fake/ffmpeg",
                timeout_seconds=0.01,
            )
        )

    assert calls == []
    assert fake_upload.closed is True


@pytest.mark.anyio
async def test_duration_limit_kills_child_and_reaps_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    upload, fake_upload = _as_upload(b"input")
    process = _FakeProcess([b"\x00" * (32_000 + 2)])
    _patch_process(monkeypatch, process)

    with pytest.raises(ValueError, match="audio_too_long"):
        await _collect(
            decode_upload(
                upload,
                max_upload_bytes=100,
                max_audio_seconds=1,
                ffmpeg_executable="/fake/ffmpeg",
            )
        )

    assert process.killed is True
    assert process.waited is True
    assert fake_upload.closed is True


@pytest.mark.anyio
async def test_continuous_stdout_is_cut_off_at_duration_limit(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    upload, fake_upload = _as_upload(b"input")
    process = _FakeProcess([], continuous_stdout=True)
    _patch_process(monkeypatch, process)

    with pytest.raises(ValueError, match="audio_too_long"):
        await _collect(
            decode_upload(
                upload,
                max_upload_bytes=100,
                max_audio_seconds=1,
                ffmpeg_executable="/fake/ffmpeg",
            )
        )

    assert process.killed is True
    assert process.waited is True
    assert fake_upload.closed is True


@pytest.mark.anyio
async def test_final_odd_pcm_byte_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    upload, fake_upload = _as_upload(b"input")
    process = _FakeProcess([b"\x00"])
    _patch_process(monkeypatch, process)

    with pytest.raises(ValueError, match="audio_decode_failed"):
        await _collect(
            decode_upload(
                upload,
                max_upload_bytes=100,
                max_audio_seconds=1,
                ffmpeg_executable="/fake/ffmpeg",
            )
        )

    assert process.killed is True
    assert process.waited is True
    assert fake_upload.closed is True


@pytest.mark.anyio
@pytest.mark.parametrize(
    ("chunks", "returncode", "message"),
    [([], 0, "audio_decode_failed"), ([b"\x00\x00"], 1, "audio_decode_failed")],
)
async def test_decode_reports_empty_or_ffmpeg_error_stably(
    monkeypatch: pytest.MonkeyPatch,
    chunks: list[bytes],
    returncode: int,
    message: str,
) -> None:
    upload, fake_upload = _as_upload(b"input")
    process = _FakeProcess(chunks, returncode=returncode)
    _patch_process(monkeypatch, process)

    with pytest.raises(ValueError, match=message):
        await _collect(
            decode_upload(
                upload,
                max_upload_bytes=100,
                max_audio_seconds=1,
                ffmpeg_executable="/fake/ffmpeg",
            )
        )

    assert process.waited is True
    assert fake_upload.closed is True


@pytest.mark.anyio
async def test_timeout_cleans_up_blocked_pumps(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    upload, fake_upload = _as_upload(b"input")
    process = _FakeProcess([], blocked_stdin=True, blocked_stdout=True)
    _patch_process(monkeypatch, process)

    with pytest.raises(ValueError, match="audio_decode_timeout"):
        await _collect(
            decode_upload(
                upload,
                max_upload_bytes=100,
                max_audio_seconds=1,
                ffmpeg_executable="/fake/ffmpeg",
                timeout_seconds=0.01,
            )
        )

    assert process.killed is True
    assert process.waited is True
    assert fake_upload.closed is True


@pytest.mark.anyio
async def test_cancellation_kills_child_reaps_it_and_closes_upload(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    upload, fake_upload = _as_upload(b"input")
    process = _FakeProcess([], blocked_stdin=True, blocked_stdout=True)
    started = asyncio.Event()
    calls: list[tuple[tuple[object, ...], dict[str, object]]] = []

    async def create_process(
        *args: object,
        **kwargs: object,
    ) -> _FakeProcess:
        calls.append((args, kwargs))
        started.set()
        return process

    monkeypatch.setattr(audio_stream.asyncio, "create_subprocess_exec", create_process)
    task = asyncio.create_task(
        _collect(
            decode_upload(
                upload,
                max_upload_bytes=100,
                max_audio_seconds=1,
                ffmpeg_executable="/fake/ffmpeg",
            )
        )
    )
    await started.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    assert calls
    assert process.killed is True
    assert process.waited is True
    assert fake_upload.closed is True


def _make_wav() -> bytes:
    pcm = struct.pack("<" + "h" * 1_600, *([0] * 1_600))
    output = io.BytesIO()
    with wave.open(output, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(16_000)
        wav_file.writeframes(pcm)
    return output.getvalue()


@pytest.mark.anyio
@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg is unavailable")
async def test_real_ffmpeg_decodes_webm_even_with_wrong_mime_hint() -> None:
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        pytest.skip("ffmpeg is unavailable")
    completed = await asyncio.to_thread(
        subprocess.run,
        [
            ffmpeg,
            "-nostdin",
            "-v",
            "error",
            "-i",
            "pipe:0",
            "-c:a",
            "libopus",
            "-f",
            "webm",
            "pipe:1",
        ],
        input=_make_wav(),
        capture_output=True,
        check=True,
    )
    encoded = completed.stdout
    upload, fake_upload = _as_upload(encoded)

    decoded = await _collect(
        decode_upload(
            upload,
            max_upload_bytes=len(encoded),
            max_audio_seconds=2,
            ffmpeg_executable=ffmpeg,
        )
    )

    assert encoded
    assert decoded
    assert len(decoded) % 2 == 0
    assert fake_upload.closed is True
