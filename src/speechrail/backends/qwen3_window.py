"""Nonterminal window RPCs on the exclusively owned, existing ASR worker."""

from __future__ import annotations

import asyncio
from collections.abc import Callable, Mapping
from contextlib import AsyncExitStack, suppress
from dataclasses import asdict
from uuid import uuid4

from speechrail.backends.qwen3_shared import Qwen3SharedWorker
from speechrail.domain.asr_window import WindowDecodeRequest, WindowDecodeResult, WindowIdentity
from speechrail.runtime.asr_mode import AsrModeBusy, AsrModeLease
from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass, WorkPurpose
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION


class NativeWindowAsrFactory:
    def __init__(self, worker: Qwen3SharedWorker, governor: ResourceGovernor) -> None:
        self._worker = worker
        self._governor = governor
        self._session: Qwen3WindowSession | None = None

    async def prepare(self) -> None:
        await self._worker.start()

    @property
    def ready(self) -> bool:
        return self._worker.ready and self._worker.supports_window_decode

    @property
    def runtime_revision(self) -> str | None:
        return self._worker.runtime_revision

    def create(self, *, identity: WindowIdentity) -> Qwen3WindowSession:
        if self._session is not None:
            raise AsrModeBusy("revision window ASR owner is busy")
        owner = self._worker.reserve_window_owner()
        try:
            lease = self._worker.mode_gate.acquire("streaming")
        except BaseException:
            self._worker.release_window_owner(owner)
            raise
        session = Qwen3WindowSession(
            self._worker, self._governor, identity, owner, lease, self._released
        )
        self._session = session
        return session

    def _released(self, session: Qwen3WindowSession) -> None:
        if self._session is session:
            self._session = None


class Qwen3WindowSession:
    def __init__(
        self,
        worker: Qwen3SharedWorker,
        governor: ResourceGovernor,
        identity: WindowIdentity,
        owner: object,
        lease: AsrModeLease,
        on_closed: Callable[[Qwen3WindowSession], None],
    ) -> None:
        self.identity = identity
        self._worker = worker
        self._governor = governor
        self._owner = owner
        self._lease = lease
        self._on_closed = on_closed
        self._lock = asyncio.Lock()
        self._inflight: asyncio.Task[WindowDecodeResult] | None = None
        self._cleanup_task: asyncio.Task[None] | None = None
        self._resources: AsyncExitStack | None = None
        self._generation: int | None = None
        self._opened = False
        self._closing = False
        self._closed = False

    async def decode(self, request: WindowDecodeRequest) -> WindowDecodeResult:
        if request.identity != self.identity:
            raise ValueError("stale window decode identity")
        if self._closed or self._closing:
            raise RuntimeError("window session is closed")
        if self._inflight is not None and not self._inflight.done():
            raise AsrModeBusy("a window decode is already running")
        task = asyncio.create_task(self._decode(request), name="asr-window-decode")
        self._inflight = task
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            with suppress(Exception):
                await join_cleanup(task)
            raise

    async def _release_resources(self) -> None:
        if self._resources is not None:
            await self._resources.aclose()
            self._resources = None

    async def _decode(self, request: WindowDecodeRequest) -> WindowDecodeResult:
        async with self._lock:
            if self._resources is not None:
                raise RuntimeError("ASR reclamation is unconfirmed")
            self._resources = AsyncExitStack()
            quarantined = False
            try:
                await self._resources.enter_async_context(
                    self._governor.reserve(
                        WorkClass.REALTIME_ASR,
                        deadline=self._worker.timeout_seconds,
                        purpose=WorkPurpose.INTERACTIVE,
                    )
                )
                await self._worker.start()
                if self._generation is not None and self._generation != self._worker.generation:
                    raise RuntimeError("stale window worker generation")
                self._generation = self._worker.generation
                if not self._worker.supports_window_decode:
                    raise RuntimeError("window_decode_v1 is not supported by the worker")
                frame: dict[str, object] = {
                    "version": PROTOCOL_VERSION,
                    "type": "window.decode",
                    "request_id": "window_" + uuid4().hex,
                    **asdict(request.identity),
                    "attempt_id": request.attempt_id,
                    "kind": request.kind,
                    "start_sample": request.input_span.start,
                    "end_sample": request.input_span.end,
                    "sample_rate": 16000,
                    "channels": 1,
                    "sample_width_bytes": 2,
                    "language": request.language or "auto",
                    "context": request.context,
                }
                self._opened = True
                response = await self._worker.request(frame, request.pcm16)
                if response.get("type") == "error":
                    raise RuntimeError(str(response.get("code") or "window_decode_failed"))
                try:
                    self._validate_identity(response, "window.result")
                    if (
                        response.get("request_id") != frame["request_id"]
                        or response.get("attempt_id") != request.attempt_id
                        or response.get("start_sample") != request.input_span.start
                        or response.get("end_sample") != request.input_span.end
                        or type(response.get("start_sample")) is not int
                        or type(response.get("end_sample")) is not int
                    ):
                        raise ValueError("window result did not match the frozen attempt")
                    text = response.get("text")
                    language = response.get("language")
                    complete = response.get("complete")
                    if (
                        not isinstance(text, str)
                        or type(complete) is not bool
                        or (language is not None and not isinstance(language, str))
                    ):
                        raise ValueError("invalid window result values")
                    return WindowDecodeResult(
                        self.identity,
                        request.attempt_id,
                        request.input_span,
                        text,
                        language,
                        complete,
                    )
                except (KeyError, TypeError, ValueError) as exc:
                    await self._worker.close()
                    raise RuntimeError("window_result_invalid") from exc
            except BaseException:
                quarantined = self._worker.alive and not self._worker.ready
                raise
            finally:
                if not quarantined:
                    await self._release_resources()

    def _validate_identity(self, frame: Mapping[str, object], expected_type: str) -> None:
        if (
            frame.get("type") != expected_type
            or frame.get("version") != PROTOCOL_VERSION
            or type(frame.get("version")) is not int
            or any(frame.get(key) != value for key, value in asdict(self.identity).items())
            or type(frame.get("input_epoch")) is not int
            or self._worker.generation != self._generation
        ):
            raise ValueError("invalid window worker response identity")

    async def close(self) -> None:
        if self._closed:
            return
        self._closing = True
        if self._cleanup_task is None or self._cleanup_task.done():
            self._cleanup_task = asyncio.create_task(self._close(), name="asr-window-close")
        await join_cleanup(self._cleanup_task)

    async def _close(self) -> None:
        async with self._lock:
            if self._closed:
                return
            if self._opened and self._worker.ready and self._worker.generation == self._generation:
                frame = {
                    "version": PROTOCOL_VERSION,
                    "type": "window.close",
                    "request_id": "window_close_" + uuid4().hex,
                    **asdict(self.identity),
                }
                try:
                    response = await self._worker.request(frame)
                    self._validate_identity(response, "window.closed")
                    if response.get("request_id") != frame["request_id"]:
                        raise ValueError("window close confirmation mismatch")
                except BaseException:
                    await self._worker.close()
            elif self._worker.alive and (self._opened or self._resources is not None):
                await self._worker.close()
            await self._release_resources()
            self._worker.mode_gate.release(self._lease)
            self._worker.release_window_owner(self._owner)
            self._closed = True
            self._on_closed(self)
