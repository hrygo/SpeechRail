"""Bounded, cancellable ffmpeg subprocess execution.

A single ASGI worker must never block its event loop on an external process, and
must never buffer an unbounded child stdout in memory. Every caller therefore
feeds a fixed argv through the same bounded stdin/stdout protocol and maps the
child outcome onto its own public errors.
"""

from __future__ import annotations

import asyncio
import contextlib

__all__ = [
    "FFMPEG_IO_CHUNK_BYTES",
    "FFMPEG_TIMEOUT_SECONDS",
    "FFmpegOutputLimitError",
    "cleanup_ffmpeg_process",
    "run_ffmpeg_subprocess",
]

FFMPEG_IO_CHUNK_BYTES = 64 * 1024
FFMPEG_TIMEOUT_SECONDS = 15.0


class FFmpegOutputLimitError(Exception):
    """Internal marker carrying the public error for a bounded stdout overflow."""

    def __init__(self, error: ValueError | OverflowError) -> None:
        super().__init__(str(error))
        self.error = error


async def _write_ffmpeg_stdin(stdin: asyncio.StreamWriter, payload: bytes) -> None:
    """Feed ffmpeg in bounded chunks and close stdin so it can finish."""
    try:
        for offset in range(0, len(payload), FFMPEG_IO_CHUNK_BYTES):
            stdin.write(payload[offset : offset + FFMPEG_IO_CHUNK_BYTES])
            await stdin.drain()
    finally:
        stdin.close()


async def _read_ffmpeg_stdout(
    stdout: asyncio.StreamReader,
    *,
    max_bytes: int,
    limit_error: ValueError | OverflowError,
) -> bytes:
    """Read at most max_bytes plus one probe byte from ffmpeg stdout."""
    output = bytearray()
    max_bytes = max(0, max_bytes)
    while True:
        read_size = min(FFMPEG_IO_CHUNK_BYTES, max_bytes + 1 - len(output))
        chunk = await stdout.read(read_size)
        if not chunk:
            return bytes(output)
        if len(output) + len(chunk) > max_bytes:
            raise FFmpegOutputLimitError(limit_error)
        output.extend(chunk)


async def cleanup_ffmpeg_process(
    process: asyncio.subprocess.Process,
    tasks: tuple[asyncio.Task[object], ...],
) -> None:
    """Stop ffmpeg and drain its pipes so cancellation cannot leak a child."""
    if process.stdin is not None:
        with contextlib.suppress(Exception):
            process.stdin.close()
    for task in tasks:
        if not task.done():
            task.cancel()
    if tasks:
        with contextlib.suppress(BaseException):
            await asyncio.gather(*tasks, return_exceptions=True)
    if process.returncode is None:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
    # communicate() is used only after termination to drain/discard buffered output and reap.
    with contextlib.suppress(BaseException):
        await process.communicate()


async def run_ffmpeg_subprocess(
    command: tuple[str, ...],
    payload: bytes,
    *,
    max_output_bytes: int,
    output_limit_error: ValueError | OverflowError,
    timeout_error: ValueError,
    failure_error: ValueError,
    timeout_seconds: float = FFMPEG_TIMEOUT_SECONDS,
) -> bytes:
    """Run fixed-argv ffmpeg with bounded concurrent stdin/stdout tasks."""
    process = await asyncio.create_subprocess_exec(
        *command,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    if process.stdin is None or process.stdout is None:
        await cleanup_ffmpeg_process(process, ())
        raise failure_error

    writer_task = asyncio.create_task(_write_ffmpeg_stdin(process.stdin, payload))
    reader_task = asyncio.create_task(
        _read_ffmpeg_stdout(
            process.stdout,
            max_bytes=max_output_bytes,
            limit_error=output_limit_error,
        )
    )
    tasks: tuple[asyncio.Task[object], ...] = (writer_task, reader_task)
    try:
        async with asyncio.timeout(timeout_seconds):
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
            # FIRST_EXCEPTION returns all tasks when neither task raises. When a task
            # fails, inspect the reader first so the earliest output limit wins over
            # a simultaneous BrokenPipeError from the input writer.
            for task in (reader_task, writer_task):
                if task in done:
                    task.result()
            await process.wait()
            output = reader_task.result()
            if process.returncode != 0 or not output:
                raise RuntimeError("ffmpeg exited without a valid output")
    except FFmpegOutputLimitError as exc:
        await cleanup_ffmpeg_process(process, tasks)
        raise exc.error from None
    except TimeoutError:
        await cleanup_ffmpeg_process(process, tasks)
        raise timeout_error from None
    except asyncio.CancelledError:
        await cleanup_ffmpeg_process(process, tasks)
        raise
    except Exception as exc:
        await cleanup_ffmpeg_process(process, tasks)
        raise failure_error from exc
    return output
