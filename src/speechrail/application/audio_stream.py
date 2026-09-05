"""对上传音频执行有界、流式的 PCM 解码。

该模块只负责应用层的上传读取和 ffmpeg 管道生命周期, 不依赖 HTTP route。
输入文件会先进行一次有界大小校验, 再从头流入 ffmpeg; 解码后的 PCM16
通过有界队列交给调用方, 避免把上传或输出正文全部保存在内存中。
"""

from __future__ import annotations

import asyncio
import contextlib
import math
import shutil
from collections.abc import AsyncGenerator, Awaitable
from dataclasses import dataclass
from typing import Protocol, cast

from fastapi import UploadFile

_PCM_BLOCK_BYTES = 64 * 1024
_PCM_SAMPLE_BYTES = 2
_PCM_SAMPLE_RATE = 16_000
_DEFAULT_TIMEOUT_SECONDS = 60.0
_OUTPUT_QUEUE_SIZE = 2


class _PipeReader(Protocol):
    async def read(self, size: int = -1) -> bytes: ...


class _PipeWriter(Protocol):
    def write(self, data: bytes) -> None: ...

    async def drain(self) -> None: ...

    def close(self) -> None: ...


class _Process(Protocol):
    stdin: _PipeWriter | None
    stdout: _PipeReader | None
    returncode: int | None

    def kill(self) -> None: ...

    async def wait(self) -> int: ...


@dataclass(slots=True)
class PcmByteCounter:
    """在接受 PCM 字节前检查 16 kHz、16-bit 音频的时长上限。"""

    max_samples: int
    accepted_bytes: int = 0

    def __post_init__(self) -> None:
        if (
            isinstance(self.max_samples, bool)
            or not isinstance(self.max_samples, int)
            or self.max_samples < 0
        ):
            raise ValueError("invalid_audio_limit")
        if (
            isinstance(self.accepted_bytes, bool)
            or not isinstance(self.accepted_bytes, int)
            or self.accepted_bytes < 0
        ):
            raise ValueError("invalid_audio_bytes")
        if self.accepted_bytes % _PCM_SAMPLE_BYTES:
            raise ValueError("pcm_bytes_odd")
        if self.accepted_bytes > self.max_bytes:
            raise ValueError("audio_too_long")

    @property
    def max_bytes(self) -> int:
        return self.max_samples * _PCM_SAMPLE_BYTES

    @property
    def total_bytes(self) -> int:
        """兼容调用方读取当前已接受字节数的别名。"""

        return self.accepted_bytes

    def accept(self, byte_count: int) -> None:
        """在更新计数前拒绝会超过时长上限的字节数。"""

        if isinstance(byte_count, bool) or not isinstance(byte_count, int) or byte_count < 0:
            raise ValueError("invalid_audio_bytes")
        if byte_count % _PCM_SAMPLE_BYTES:
            raise ValueError("pcm_bytes_odd")
        next_bytes = self.accepted_bytes + byte_count
        if next_bytes > self.max_bytes:
            raise ValueError("audio_too_long")
        self.accepted_bytes = next_bytes


@dataclass(frozen=True, slots=True)
class PcmBlock:
    """一个有界 PCM 窗及其在源音频中的唯一 core 范围。"""

    start_sample: int
    pcm: bytes
    core_start_sample: int
    core_end_sample: int

    def __post_init__(self) -> None:
        sample_fields = (
            self.start_sample,
            self.core_start_sample,
            self.core_end_sample,
        )
        if any(
            isinstance(value, bool) or not isinstance(value, int) or value < 0
            for value in sample_fields
        ):
            raise ValueError("invalid_pcm_block")
        if not isinstance(self.pcm, bytes):
            raise ValueError("invalid_pcm_block")
        if len(self.pcm) % _PCM_SAMPLE_BYTES:
            raise ValueError("pcm_bytes_odd")
        end_sample = self.start_sample + len(self.pcm) // _PCM_SAMPLE_BYTES
        if not (
            self.start_sample <= self.core_start_sample <= self.core_end_sample <= end_sample
        ):
            raise ValueError("invalid_pcm_block")


class PcmWindowBuffer:
    """以固定窗口和前导 overlap 滚动缓存 PCM16。"""

    __slots__ = (
        "_buffer",
        "_buffer_start_sample",
        "_emitted_any",
        "_finish_result",
        "_finished",
        "_overlap_samples",
        "_source_samples",
        "_step_samples",
        "_window_samples",
    )

    def __init__(
        self,
        window_samples: int = _PCM_SAMPLE_RATE * 30,
        overlap_samples: int = _PCM_SAMPLE_RATE,
    ) -> None:
        if (
            isinstance(window_samples, bool)
            or not isinstance(window_samples, int)
            or window_samples <= 0
            or isinstance(overlap_samples, bool)
            or not isinstance(overlap_samples, int)
            or overlap_samples < 0
            or overlap_samples >= window_samples
        ):
            raise ValueError("invalid_window")
        self._window_samples = window_samples
        self._overlap_samples = overlap_samples
        self._step_samples = window_samples - overlap_samples
        self._buffer = bytearray()
        self._buffer_start_sample = 0
        self._source_samples = 0
        self._emitted_any = False
        self._finished = False
        self._finish_result: tuple[PcmBlock, ...] | None = None

    @property
    def window_samples(self) -> int:
        return self._window_samples

    @property
    def overlap_samples(self) -> int:
        return self._overlap_samples

    @property
    def buffered_samples(self) -> int:
        """返回当前内部缓存大小, 仅用于有界性诊断。"""

        return len(self._buffer) // _PCM_SAMPLE_BYTES

    @property
    def _window_bytes(self) -> int:
        return self._window_samples * _PCM_SAMPLE_BYTES

    @property
    def _max_buffer_bytes(self) -> int:
        return (self._window_samples + self._overlap_samples) * _PCM_SAMPLE_BYTES

    def _emit_full_window(self) -> PcmBlock:
        window_bytes = self._window_bytes
        start_sample = self._buffer_start_sample
        core_start_sample = (
            0
            if not self._emitted_any
            else start_sample + self._overlap_samples
        )
        core_end_sample = start_sample + self._window_samples
        block = PcmBlock(
            start_sample=start_sample,
            pcm=bytes(self._buffer[:window_bytes]),
            core_start_sample=core_start_sample,
            core_end_sample=core_end_sample,
        )
        del self._buffer[: self._step_samples * _PCM_SAMPLE_BYTES]
        self._buffer_start_sample += self._step_samples
        self._emitted_any = True
        return block

    def feed(self, pcm: bytes) -> tuple[PcmBlock, ...]:
        """接受任意偶数字节并返回当前已满窗口, 内部缓存保持有界。"""

        if self._finished:
            raise ValueError("window_buffer_finished")
        if not isinstance(pcm, bytes):
            raise ValueError("invalid_pcm")
        if len(pcm) % _PCM_SAMPLE_BYTES:
            raise ValueError("pcm_bytes_odd")
        if not pcm:
            return ()

        emitted: list[PcmBlock] = []
        view = memoryview(pcm)
        offset = 0
        self._source_samples += len(pcm) // _PCM_SAMPLE_BYTES
        try:
            while offset < len(view):
                while len(self._buffer) >= self._window_bytes:
                    emitted.append(self._emit_full_window())
                capacity = self._max_buffer_bytes - len(self._buffer)
                if capacity <= 0:
                    raise RuntimeError("window_buffer_internal_limit")
                take = min(capacity, len(view) - offset)
                self._buffer.extend(view[offset : offset + take])
                offset += take
            while len(self._buffer) >= self._window_bytes:
                emitted.append(self._emit_full_window())
        finally:
            view.release()
        return tuple(emitted)

    def finish(self) -> tuple[PcmBlock, ...]:
        """返回尾窗并关闭 buffer; 重复调用返回相同结果。"""

        if self._finished:
            assert self._finish_result is not None
            return self._finish_result
        self._finished = True

        if not self._buffer:
            result: tuple[PcmBlock, ...] = ()
        elif not self._emitted_any:
            result = (
                PcmBlock(
                    start_sample=0,
                    pcm=bytes(self._buffer),
                    core_start_sample=0,
                    core_end_sample=self._source_samples,
                ),
            )
        else:
            core_start_sample = self._buffer_start_sample + self._overlap_samples
            if core_start_sample >= self._source_samples:
                result = ()
            else:
                result = (
                    PcmBlock(
                        start_sample=self._buffer_start_sample,
                        pcm=bytes(self._buffer),
                        core_start_sample=core_start_sample,
                        core_end_sample=self._source_samples,
                    ),
                )
        self._buffer.clear()
        self._finish_result = result
        return result


def split_pcm(
    pcm: bytes,
    *,
    window_samples: int,
    overlap_samples: int,
) -> tuple[PcmBlock, ...]:
    """对小型 PCM fixture 应用与生产 buffer 相同的窗口规则。"""

    buffer = PcmWindowBuffer(window_samples, overlap_samples)
    return buffer.feed(pcm) + buffer.finish()


@dataclass(frozen=True, slots=True)
class _StreamFailure:
    error: ValueError | OverflowError


class _StreamEnd:
    pass


_STREAM_END = _StreamEnd()


def _resolve_ffmpeg() -> str:
    """使用固定的本机 ffmpeg resolver, 不读取客户端提供的路径。"""

    executable = shutil.which("ffmpeg")
    if executable is None:
        raise ValueError("audio_decode_failed")
    return executable


def _stable_error(error: Exception) -> ValueError | OverflowError:
    if isinstance(error, OverflowError) and str(error) == "audio_too_large":
        return error
    if isinstance(error, ValueError) and str(error) in {
        "audio_decode_failed",
        "audio_decode_timeout",
        "audio_too_long",
        "empty_audio",
        "pcm_bytes_odd",
    }:
        return error
    return ValueError("audio_decode_failed")


def _validate_limits(max_upload_bytes: int, max_audio_seconds: int) -> None:
    for value in (max_upload_bytes, max_audio_seconds):
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError("invalid_audio_limit")


async def _wait_with_timeout[T](
    awaitable: Awaitable[T],
    wait_budget_seconds: float,
) -> T:
    """对单次异步等待设上限, 不把调用方处理已产出块的时间算入。"""

    try:
        return await asyncio.wait_for(awaitable, timeout=wait_budget_seconds)
    except asyncio.CancelledError:
        raise
    except TimeoutError as error:
        raise ValueError("audio_decode_timeout") from error


async def _validate_upload_size(
    file: UploadFile,
    max_upload_bytes: int,
    wait_budget_seconds: float,
) -> None:
    """用固定小块完成大小校验, 并将文件指针复位供第二遍读取。"""

    try:
        await _wait_with_timeout(file.seek(0), wait_budget_seconds)
        total_bytes = 0
        while True:
            chunk = await _wait_with_timeout(
                file.read(_PCM_BLOCK_BYTES),
                wait_budget_seconds,
            )
            if not isinstance(chunk, bytes):
                raise ValueError("audio_decode_failed")
            if not chunk:
                break
            total_bytes += len(chunk)
            if total_bytes > max_upload_bytes:
                raise OverflowError("audio_too_large")
        if total_bytes == 0:
            raise ValueError("empty_audio")
        await _wait_with_timeout(file.seek(0), wait_budget_seconds)
    except (ValueError, OverflowError) as error:
        if (
            isinstance(error, OverflowError)
            and str(error) == "audio_too_large"
        ) or (isinstance(error, ValueError) and str(error) in {
            "audio_decode_failed",
            "empty_audio",
        }):
            raise
        raise _stable_error(error) from error
    except Exception as error:
        raise _stable_error(error) from error


def _ffmpeg_command(executable: str) -> tuple[str, ...]:
    return (
        executable,
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
        str(_PCM_SAMPLE_RATE),
        "-ac",
        "1",
        "pipe:1",
    )


async def _start_ffmpeg(executable: str) -> _Process:
    try:
        process = await asyncio.create_subprocess_exec(
            *_ffmpeg_command(executable),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
    except asyncio.CancelledError:
        raise
    except Exception as error:
        raise ValueError("audio_decode_failed") from error

    typed_process = process
    if typed_process.stdin is None or typed_process.stdout is None:
        if typed_process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                typed_process.kill()
        with contextlib.suppress(Exception):
            await typed_process.wait()
        raise ValueError("audio_decode_failed")
    return cast(_Process, typed_process)


async def _feed_upload(
    file: UploadFile,
    process: _Process,
    queue: asyncio.Queue[bytes | _StreamFailure | _StreamEnd],
    max_upload_bytes: int,
) -> None:
    """从第二遍上传读取并有背压地写入 ffmpeg stdin。"""

    stdin = process.stdin
    sent_bytes = 0
    try:
        if stdin is None:
            raise ValueError("audio_decode_failed")
        while True:
            chunk = await file.read(_PCM_BLOCK_BYTES)
            if not isinstance(chunk, bytes):
                raise ValueError("audio_decode_failed")
            if not chunk:
                break
            for offset in range(0, len(chunk), _PCM_BLOCK_BYTES):
                block_length = min(_PCM_BLOCK_BYTES, len(chunk) - offset)
                sent_bytes += block_length
                if sent_bytes > max_upload_bytes:
                    raise OverflowError("audio_too_large")
                block = chunk[offset : offset + block_length]
                stdin.write(block)
                await stdin.drain()
    except asyncio.CancelledError:
        raise
    except Exception as error:
        stable_error = _stable_error(error)
        await queue.put(_StreamFailure(stable_error))
        raise stable_error from error
    finally:
        if stdin is not None:
            with contextlib.suppress(Exception):
                stdin.close()


async def _drain_output(
    process: _Process,
    counter: PcmByteCounter,
    queue: asyncio.Queue[bytes | _StreamFailure | _StreamEnd],
) -> None:
    """读取 stdout, 跨块处理奇数字节并按 PCM 边界产出有界块。"""

    stdout = process.stdout
    if stdout is None:
        raise ValueError("audio_decode_failed")
    pending = b""
    emitted = False
    try:
        while True:
            raw = await stdout.read(_PCM_BLOCK_BYTES)
            if not isinstance(raw, bytes):
                raise ValueError("audio_decode_failed")
            if not raw:
                break
            data = pending + raw
            pending = b""
            if len(data) % _PCM_SAMPLE_BYTES:
                pending = data[-1:]
                data = data[:-1]
            for offset in range(0, len(data), _PCM_BLOCK_BYTES):
                block_length = min(_PCM_BLOCK_BYTES, len(data) - offset)
                counter.accept(block_length)
                emitted = True
                block = data[offset : offset + block_length]
                await queue.put(block)
        if pending:
            raise ValueError("audio_decode_failed")
        if not emitted:
            raise ValueError("audio_decode_failed")
    except asyncio.CancelledError:
        raise
    except Exception as error:
        await queue.put(_StreamFailure(_stable_error(error)))
        return
    await queue.put(_STREAM_END)


async def _cleanup_process(
    process: _Process,
    tasks: list[asyncio.Task[None]],
) -> None:
    for task in tasks:
        if not task.done():
            task.cancel()
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)

    if process.stdin is not None:
        with contextlib.suppress(Exception):
            process.stdin.close()
    if process.returncode is None:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
    with contextlib.suppress(Exception):
        await process.wait()


async def decode_upload(
    file: UploadFile,
    *,
    max_upload_bytes: int,
    max_audio_seconds: int,
    ffmpeg_executable: str | None = None,
    timeout_seconds: float | None = None,
) -> AsyncGenerator[bytes, None]:
    """将上传音频解码为 16 kHz mono PCM16, 并按块异步返回。

    ``ffmpeg_executable`` 和 ``timeout_seconds`` 仅用于确定性测试或受控调用方;
    默认 executable 由固定 resolver 取得, 绝不采用上传内容中的路径或 URL。
    """

    _validate_limits(max_upload_bytes, max_audio_seconds)
    timeout = _DEFAULT_TIMEOUT_SECONDS if timeout_seconds is None else timeout_seconds
    if (
        isinstance(timeout, bool)
        or not isinstance(timeout, (int, float))
        or not math.isfinite(timeout)
        or timeout < 0
    ):
        raise ValueError("invalid_audio_timeout")

    process: _Process | None = None
    tasks: list[asyncio.Task[None]] = []
    try:
        await _validate_upload_size(file, max_upload_bytes, timeout)
        executable = ffmpeg_executable if ffmpeg_executable is not None else _resolve_ffmpeg()
        process = await _wait_with_timeout(_start_ffmpeg(executable), timeout)
        counter = PcmByteCounter(max_samples=max_audio_seconds * _PCM_SAMPLE_RATE)
        queue: asyncio.Queue[bytes | _StreamFailure | _StreamEnd] = asyncio.Queue(
            maxsize=_OUTPUT_QUEUE_SIZE
        )
        tasks = [
            asyncio.create_task(_feed_upload(file, process, queue, max_upload_bytes)),
            asyncio.create_task(_drain_output(process, counter, queue)),
        ]

        while True:
            event = await _wait_with_timeout(queue.get(), timeout)
            if isinstance(event, bytes):
                # 计时器只包住 queue.get; 调用方消费当前块的时间不计入。
                yield event
            elif isinstance(event, _StreamFailure):
                raise event.error
            else:
                break
        try:
            await _wait_with_timeout(tasks[0], timeout)
            await _wait_with_timeout(tasks[1], timeout)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            raise _stable_error(error) from error
        try:
            returncode = await _wait_with_timeout(process.wait(), timeout)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            raise _stable_error(error) from error
        if returncode != 0:
            raise ValueError("audio_decode_failed")
    finally:
        try:
            if process is not None:
                await _cleanup_process(process, tasks)
        finally:
            with contextlib.suppress(Exception):
                await file.close()
