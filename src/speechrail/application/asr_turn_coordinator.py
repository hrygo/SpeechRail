"""Bounded input ownership around one serial ASR lane.

Queued segments do not create model sessions or acquire additional mode leases.
The producer only admits PCM; the lane owns IPC, preview and final inference.
"""

from __future__ import annotations

import asyncio
import contextlib
from collections import deque
from collections.abc import AsyncIterator, Awaitable, Callable

from speechrail.domain.ports import (
    RealtimeAsrFactory,
    RealtimeAsrSession,
    RealtimeTranscriptionOptions,
    StreamingAsrEvent,
)


async def _nothing() -> None:
    pass


def _failure_code(exc: Exception) -> str:
    if isinstance(exc, TimeoutError):
        return "backend_timeout"
    code = getattr(exc, "code", None)
    if isinstance(code, str) and code in {
        "backend_busy", "backend_timeout", "queue_full",
        "language_not_supported", "asr_buffer_overflow",
    }:
        return code
    if str(exc).startswith("language_not_supported:"):
        return "language_not_supported"
    return "backend_error"


class AsrTurnCoordinator:
    """Own current + at most two pending segments and their actual operations."""

    def __init__(
        self,
        factory: RealtimeAsrFactory,
        *,
        capacity_bytes: int,
        max_segments: int = 3,
        acquire: Callable[[], Awaitable[None]] = _nothing,
        release: Callable[[], Awaitable[None]] = _nothing,
    ) -> None:
        if capacity_bytes < 2 or max_segments < 1:
            raise ValueError("ASR capacity must be positive")
        self._factory = factory
        self._capacity = capacity_bytes
        self._max_segments = max_segments
        self._acquire = acquire
        self._release = release
        self._segments: deque[CoordinatedAsrSession] = deque()
        self._driver: asyncio.Task[None] | None = None
        self._close_task: asyncio.Task[None] | None = None
        self._retained_bytes = 0
        self._closed = False
        self._quarantined: list[
            tuple[RealtimeAsrSession, CoordinatedAsrSession, bool]
        ] = []

    @property
    def retained_bytes(self) -> int:
        """PCM reservation includes the worker's PCM and one snapshot copy."""
        return self._retained_bytes

    @property
    def busy(self) -> bool:
        return bool(self._segments)

    def create(
        self, *, language: str | None, prompt: str, options: RealtimeTranscriptionOptions
    ) -> CoordinatedAsrSession:
        if self._closed:
            raise RuntimeError("ASR coordinator is closed")
        if len(self._segments) >= self._max_segments:
            raise RuntimeError("asr_buffer_overflow: pending segment capacity exhausted")
        segment = CoordinatedAsrSession(self, language, prompt, options)
        self._segments.append(segment)
        return segment

    def _start(self) -> None:
        if self._driver is None or self._driver.done():
            self._driver = asyncio.create_task(self._run(), name="asr-serial-lane")

    def _admit(self, segment: CoordinatedAsrSession, audio: bytes) -> None:
        if self._closed or segment._sealed or segment._result.done():
            raise RuntimeError("ASR segment no longer accepts PCM")
        # Main pending bytes are transferred to the worker, not copied into a
        # second unbounded history. Charge two complete spans conservatively:
        # retained worker PCM plus its immutable inference snapshot.
        charge = 2 * len(audio)
        if self._retained_bytes + charge > self._capacity:
            raise RuntimeError("asr_buffer_overflow: retained PCM capacity exhausted")
        policy = segment._options.asr_policy
        effective = segment._options.effective_max_segment_ms or policy.max_segment_ms
        if segment._accepted_bytes + len(audio) > effective * 32:
            raise RuntimeError("asr_buffer_overflow: segment PCM capacity exhausted")
        self._retained_bytes += charge
        segment._accepted_bytes += len(audio)
        segment._pending.append(audio)
        segment._changed.set()

    async def _run(self) -> None:
        try:
            while self._segments and not self._closed:
                segment = self._segments[0]
                runtime: RealtimeAsrSession | None = None
                forward: asyncio.Task[None] | None = None
                acquired = False
                try:
                    await segment._connected.wait()
                    if (
                        segment._deadline is not None
                        and asyncio.get_running_loop().time() >= segment._deadline
                    ):
                        raise TimeoutError("ASR final deadline expired in the pending lane")
                    runtime = self._factory.create(
                        language=segment._language,
                        prompt=segment._prompt,
                        options=segment._options,
                    )
                    # The absolute final deadline includes admission, connect
                    # and an already-running preview, not just commit().
                    async with asyncio.timeout_at(segment._deadline) as timeout:
                        segment._timeout = timeout
                        await self._acquire()
                        acquired = True
                        await runtime.connect()
                        forward = asyncio.create_task(segment._forward(runtime))
                        forward.add_done_callback(segment._forward_finished)
                        while True:
                            segment._changed.clear()
                            while segment._pending:
                                await runtime.append_audio(segment._pending.popleft())
                            if segment._sealed:
                                await runtime.commit(want_segments=segment._want_segments)
                                await forward
                                if not segment._terminal:
                                    raise RuntimeError(
                                        "streaming ASR ended without a transcription terminal"
                                    )
                                break
                            if forward.done():
                                await forward
                                raise RuntimeError("streaming ASR reader ended before commit")
                            if segment._preview_requested:
                                segment._preview_requested = False
                                await runtime.flush()
                                continue
                            await segment._changed.wait()
                except asyncio.CancelledError:
                    segment._result.cancel()
                    raise
                except Exception as exc:
                    if not segment._terminal:
                        code = _failure_code(exc)
                        segment._publish(StreamingAsrEvent(kind="error", error_code=code))
                    segment._failure = exc
                finally:
                    segment._timeout = None
                    if forward is not None and not forward.done():
                        forward.cancel()
                        with contextlib.suppress(asyncio.CancelledError):
                            await forward
                    # A canceled await is not a canceled MLX operation. The
                    # port must reap/acknowledge its exact worker before close
                    # returns, and only then may admission be returned.
                    cleanup_succeeded = False
                    try:
                        if runtime is not None:
                            await runtime.close()
                            self._factory.release(runtime)
                        if acquired:
                            await self._release()
                        cleanup_succeeded = True
                    except Exception as exc:
                        # No successor may reuse an uncertain model owner.
                        # Keep its reservation and lease until close retries
                        # the actual teardown successfully.
                        self._closed = True
                        segment._failure = exc
                        if runtime is not None:
                            self._quarantined.append((runtime, segment, acquired))
                        if not segment._terminal:
                            segment._publish(
                                StreamingAsrEvent(kind="error", error_code="backend_error")
                            )
                    finally:
                        if cleanup_succeeded:
                            self._retained_bytes -= segment._accepted_bytes * 2
                        segment._pending.clear()
                        if self._segments and self._segments[0] is segment:
                            self._segments.popleft()
                        segment._end()
        finally:
            if self._closed:
                for pending in self._segments:
                    pending._failure = RuntimeError("ASR lane closed before finalization")
                    pending._publish(
                        StreamingAsrEvent(kind="error", error_code="backend_error")
                    )
                    self._retained_bytes -= pending._accepted_bytes * 2
                    pending._pending.clear()
                    pending._end()
                self._segments.clear()

    async def close(self) -> None:
        """Cancel input and wait for the actual active operation's teardown."""
        self._closed = True
        task = self._close_task
        if task is None or (
            task.done() and (task.cancelled() or task.exception() is not None)
        ):
            task = asyncio.create_task(self._close_owned_operations())
            self._close_task = task
        # Multiple clear/disconnect callers share one cleanup operation.
        # Canceling a waiter must not cancel worker reap or release its PCM.
        await asyncio.shield(task)

    async def _close_owned_operations(self) -> None:
        driver = self._driver
        if driver is not None and not driver.done():
            driver.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await driver
        for runtime, segment, acquired in tuple(self._quarantined):
            await runtime.close()
            self._factory.release(runtime)
            if acquired:
                await self._release()
            self._retained_bytes -= segment._accepted_bytes * 2
            self._quarantined.remove((runtime, segment, acquired))
        for pending in self._segments:
            pending._result.cancel()
            pending._pending.clear()
            pending._end()
        self._segments.clear()
        self._retained_bytes = sum(
            segment._accepted_bytes * 2 for _, segment, _ in self._quarantined
        )

    async def abort(self, error_code: str) -> None:
        """Fail every retained item before tearing down the sole model owner."""
        for segment in self._segments:
            segment._failure = RuntimeError(error_code)
            segment._publish(StreamingAsrEvent(kind="error", error_code=error_code))
        await self.close()


class CoordinatedAsrSession:
    """A segment handle whose lifecycle belongs to its coordinator."""

    def __init__(
        self,
        owner: AsrTurnCoordinator,
        language: str | None,
        prompt: str,
        options: RealtimeTranscriptionOptions,
    ) -> None:
        self._owner = owner
        self._language = language
        self._prompt = prompt
        self._options = options
        self._pending: deque[bytes] = deque()
        self._accepted_bytes = 0
        self._connected = asyncio.Event()
        self._changed = asyncio.Event()
        self._sealed = False
        self._preview_requested = False
        self._want_segments = False
        self._deadline: float | None = None
        self._timeout: asyncio.Timeout | None = None
        self._terminal = False
        self._ended = False
        self._failure: Exception | None = None
        self._result: asyncio.Future[None] = asyncio.get_running_loop().create_future()
        self._events: asyncio.Queue[StreamingAsrEvent | None] = asyncio.Queue(maxsize=64)

    async def connect(self) -> None:
        self._connected.set()
        self._owner._start()

    async def append_audio(self, audio: bytes) -> None:
        if not audio or len(audio) % 2:
            raise ValueError("requires non-empty whole PCM16 samples")
        self._owner._admit(self, audio)

    async def flush(self) -> None:
        if not self._sealed:
            self._preview_requested = True
            self._changed.set()

    async def commit(self, want_segments: bool = False) -> None:
        if not self._sealed:
            self._sealed = True
            self._want_segments = want_segments
            deadline_ms = self._options.asr_policy.final_deadline_ms
            self._deadline = (
                asyncio.get_running_loop().time() + deadline_ms / 1000
                if deadline_ms is not None else None
            )
            if self._timeout is not None:
                self._timeout.reschedule(self._deadline)
            self._changed.set()
        await asyncio.shield(self._result)
        if self._failure is not None:
            raise self._failure

    async def close(self) -> None:
        if not self._result.done():
            await self._owner.close()

    async def _forward(self, runtime: RealtimeAsrSession) -> None:
        async for event in runtime.events():
            self._publish(event)

    def _forward_finished(self, task: asyncio.Task[None]) -> None:
        self._changed.set()

    def _publish(self, event: StreamingAsrEvent) -> None:
        if self._terminal:
            return
        if event.kind in {"completed", "error"}:
            self._terminal = True
        if self._events.qsize() >= 62:
            # Previews are snapshots and may coalesce. Preserve the unique
            # terminal and its end marker even under a slow display consumer.
            while not self._events.empty():
                self._events.get_nowait()
        self._events.put_nowait(event)

    def _end(self) -> None:
        if self._ended:
            return
        self._ended = True
        self._events.put_nowait(None)
        if not self._result.done():
            self._result.set_result(None)

    def events(self) -> AsyncIterator[StreamingAsrEvent]:
        async def iterate() -> AsyncIterator[StreamingAsrEvent]:
            while (event := await self._events.get()) is not None:
                yield event
        return iterate()
