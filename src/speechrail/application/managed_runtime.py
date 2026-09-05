"""Stable, generation-aware delegation for inference backends.

The composition root owns the physical workers.  HTTP and WebSocket routes keep
one ``ManagedRuntime`` object instead, so a future bundle switch cannot leave a
route holding a stale worker adapter.  A bundle is immutable and remains pinned
for the lifetime of each piece of work.
"""

from __future__ import annotations

import inspect
import threading
from collections.abc import AsyncIterator, Awaitable, Callable, Iterator, Mapping
from contextlib import contextmanager, suppress
from dataclasses import dataclass
from types import MappingProxyType
from typing import ClassVar, cast, overload
from uuid import uuid4

from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import (
    AudioChunk,
    BatchTranscriber,
    RealtimeAsrFactory,
    RealtimeAsrSession,
    SpeechRequest,
    SpeechSynthesizer,
    StreamingAsrEvent,
    TranscriptionRequest,
)


class ManagedRuntimeError(RuntimeError):
    """Base error for a public runtime lifecycle failure."""

    code: ClassVar[str] = "runtime_error"

    def __init__(self, message: str | None = None) -> None:
        resolved = message or self.code
        super().__init__(resolved)
        self.message = resolved


class RuntimeNotReadyError(ManagedRuntimeError):
    """Raised when a requested port is absent from the current bundle."""

    code = "backend_not_ready"


class RuntimeDrainingError(ManagedRuntimeError):
    """Raised when new work is attempted while a runtime is draining."""

    code = "runtime_draining"


class RuntimeBusyError(ManagedRuntimeError):
    """Raised when a bundle switch is attempted with active work."""

    code = "runtime_busy"


def _freeze_snapshot(value: object) -> object:
    """Recursively copy the small public snapshot values used by a bundle."""
    if isinstance(value, Mapping):
        return MappingProxyType(
            {key: _freeze_snapshot(item) for key, item in value.items()}
        )
    if isinstance(value, (list, tuple)):
        return tuple(_freeze_snapshot(item) for item in value)
    if isinstance(value, (set, frozenset)):
        return frozenset(_freeze_snapshot(item) for item in value)
    return value


@dataclass(frozen=True, slots=True)
class RuntimeBundle:
    """Immutable set of backends and public identity for one generation."""

    asr: BatchTranscriber | Callable[..., Awaitable[TranscriptResult]] | None
    tts: SpeechSynthesizer | None
    realtime_factory: RealtimeAsrFactory | None
    artifact_identity: object
    voice_catalog: object
    generation: int | str = 0

    def __post_init__(self) -> None:
        """Freeze identity and voice snapshots so callers cannot mutate them."""
        object.__setattr__(self, "artifact_identity", _freeze_snapshot(self.artifact_identity))
        object.__setattr__(self, "voice_catalog", _freeze_snapshot(self.voice_catalog))

    @property
    def capabilities(self) -> Mapping[str, bool]:
        """Return the capability view belonging to this exact generation."""
        return MappingProxyType(
            {
                "asr": self.asr is not None,
                "tts": self.tts is not None,
                "realtime_asr": self.realtime_factory is not None,
            }
        )


class ActiveWork:
    """Thread-safe count of work that pins a runtime generation."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._count = 0

    @property
    def count(self) -> int:
        """Return the number of unreleased work tokens."""
        with self._lock:
            return self._count

    def acquire(self, *, generation: int | str = 0) -> ActiveWorkLease:
        """Acquire one generation token, returning an idempotent release handle."""
        with self._lock:
            self._count += 1
        return ActiveWorkLease(self, generation)

    def release(self, token: ActiveWorkLease) -> None:
        """Release one token without allowing an underflow."""
        with self._lock:
            if not isinstance(token, ActiveWorkLease) or token._owner is not self:
                raise ValueError("foreign ActiveWork lease")
            if token._released:
                return
            token._released = True
            if self._count:
                self._count -= 1

    @contextmanager
    def lease(self, *, generation: int | str = 0) -> Iterator[ActiveWorkLease]:
        """Synchronously scope one active-work token."""
        token = self.acquire(generation=generation)
        try:
            yield token
        finally:
            token.release()


class ActiveWorkLease:
    """Idempotent token returned by :meth:`ActiveWork.acquire`."""

    def __init__(self, owner: ActiveWork, generation: int | str) -> None:
        self._owner = owner
        self.generation = generation
        self._released = False

    def release(self) -> None:
        """Return this token to its owner once."""
        if self._released:
            return
        self._owner.release(self)

    @property
    def released(self) -> bool:
        """Whether this token has already been returned."""
        return self._released

    def __enter__(self) -> ActiveWorkLease:
        return self

    def __exit__(self, *_: object) -> None:
        self.release()


class RuntimeLease:
    """A generation-pinned lease returned by :meth:`ManagedRuntime.acquire`."""

    def __init__(self, bundle: RuntimeBundle, token: ActiveWorkLease) -> None:
        self.bundle = bundle
        self._token = token

    @property
    def generation(self) -> int | str:
        """Return the pinned bundle generation."""
        return self.bundle.generation

    @property
    def artifact_identity(self) -> object:
        """Return the pinned artifact identity."""
        return self.bundle.artifact_identity

    @property
    def voice_catalog(self) -> object:
        """Return the pinned voice catalog."""
        return self.bundle.voice_catalog

    @property
    def capabilities(self) -> Mapping[str, bool]:
        """Return capabilities for the pinned generation."""
        return self.bundle.capabilities

    def release(self) -> None:
        """Release the pinned generation token."""
        self._token.release()

    @property
    def released(self) -> bool:
        """Whether this generation lease has already been returned."""
        return self._token.released

    def __enter__(self) -> RuntimeLease:
        return self

    def __exit__(self, *_: object) -> None:
        self.release()

    async def __aenter__(self) -> RuntimeLease:
        return self

    async def __aexit__(self, *_: object) -> None:
        self.release()


async def _close_async_iterator(value: object) -> None:
    """Close an optional async iterator without assuming a concrete backend."""
    close = getattr(value, "aclose", None)
    if not callable(close):
        return
    result = close()
    if inspect.isawaitable(result):
        await cast(Awaitable[object], result)


class _ManagedRealtimeSession:
    """Delegate one backend session while retaining its bundle lease."""

    def __init__(
        self,
        inner: RealtimeAsrSession,
        factory: RealtimeAsrFactory,
        lease: RuntimeLease,
    ) -> None:
        self._inner = inner
        self._factory = factory
        self._lease = lease
        self._closed = False
        self._close_lock = threading.Lock()
        self._factory_released = False
        self._factory_release_lock = threading.Lock()

    @property
    def session_id(self) -> str | None:
        """Preserve a backend session identifier when the adapter exposes one."""
        value = getattr(self._inner, "session_id", None)
        return value if isinstance(value, str) else None

    async def connect(self) -> None:
        try:
            await self._inner.connect()
        except BaseException:
            with suppress(BaseException):
                await self.close()
            raise

    async def append_audio(self, audio: bytes) -> None:
        await self._inner.append_audio(audio)

    async def flush(self) -> None:
        await self._inner.flush()

    async def commit(self, want_segments: bool = False) -> None:
        await self._inner.commit(want_segments=want_segments)

    def events(self) -> AsyncIterator[StreamingAsrEvent]:
        async def stream() -> AsyncIterator[StreamingAsrEvent]:
            source = self._inner.events()
            try:
                async for event in source:
                    yield event
            finally:
                with suppress(Exception):
                    await _close_async_iterator(source)
                # A backend event stream ending is terminal for this session.
                await self.close()

        return stream()

    async def close(self) -> None:
        """Close the backend and release its generation lease exactly once."""
        with self._close_lock:
            if self._closed:
                return
            self._closed = True
        try:
            await self._inner.close()
        finally:
            try:
                self._release_factory()
            finally:
                self._lease.release()

    def _release_factory(self) -> None:
        """Return the inner session to its original factory at most once."""
        with self._factory_release_lock:
            if self._factory_released:
                return
            self._factory_released = True
        self._factory.release(self._inner)


class ManagedRuntime(BatchTranscriber, SpeechSynthesizer, RealtimeAsrFactory):
    """Stable facade over one replaceable :class:`RuntimeBundle`.

    Bundle replacement is synchronous and only succeeds after all port work has
    released its generation lease.  ``begin_draining`` blocks new leases while
    allowing existing work to finish, which gives a future activation workflow a
    small, deterministic hand-off primitive without implementing the drain
    policy itself here.
    """

    def __init__(
        self,
        bundle: RuntimeBundle | None = None,
        *,
        active_work: ActiveWork | None = None,
    ) -> None:
        self._state_lock = threading.RLock()
        self._bundle = bundle or RuntimeBundle(
            asr=None,
            tts=None,
            realtime_factory=None,
            artifact_identity=None,
            voice_catalog=(),
            generation=0,
        )
        self._active_work = active_work or ActiveWork()
        self._draining = False

    @property
    def active_work(self) -> ActiveWork:
        """Return the counter used by this facade's generation leases."""
        return self._active_work

    @property
    def active_count(self) -> int:
        """Return the current number of active generation-pinned operations."""
        return self._active_work.count

    @property
    def is_draining(self) -> bool:
        """Whether new work is currently rejected."""
        with self._state_lock:
            return self._draining

    @property
    def bundle(self) -> RuntimeBundle:
        """Return the current immutable bundle snapshot."""
        with self._state_lock:
            return self._bundle

    @property
    def asr(self) -> object | None:
        """Return the current ASR port for read-only composition inspection."""
        return self.bundle.asr

    @property
    def tts(self) -> object | None:
        """Return the current TTS port for read-only composition inspection."""
        return self.bundle.tts

    @property
    def realtime_factory(self) -> RealtimeAsrFactory | None:
        """Return the current Realtime factory for read-only inspection."""
        return self.bundle.realtime_factory

    def snapshot(self) -> RuntimeBundle:
        """Return the current bundle snapshot for read-only inspection."""
        return self.bundle

    @property
    def generation(self) -> int | str:
        """Return the current bundle generation."""
        return self.bundle.generation

    @property
    def artifact_identity(self) -> object:
        """Return the current generation's public artifact identity."""
        return self.bundle.artifact_identity

    @property
    def voice_catalog(self) -> object:
        """Return the current generation's immutable voice catalog."""
        return self.bundle.voice_catalog

    @property
    def capabilities(self) -> Mapping[str, bool]:
        """Return the current generation's capability snapshot."""
        return self.bundle.capabilities

    @property
    def _worker(self) -> object | None:
        """Expose the legacy streaming worker inspection seam during migration."""
        factory = self.bundle.realtime_factory
        return getattr(factory, "_worker", None) if factory is not None else None

    def acquire(self) -> RuntimeLease:
        """Pin the current generation for one operation.

        The state lock serializes acquisition with replacement, so a lease can
        never observe a partially switched bundle.
        """
        with self._state_lock:
            if self._draining:
                raise RuntimeDrainingError()
            bundle = self._bundle
            token = self._active_work.acquire(generation=bundle.generation)
        return RuntimeLease(bundle, token)

    def replace_bundle(self, bundle: RuntimeBundle) -> None:
        """Install a new immutable bundle after all old work has completed."""
        with self._state_lock:
            if self._active_work.count:
                raise RuntimeBusyError("runtime bundle has active work")
            self._bundle = bundle

    def begin_draining(self) -> None:
        """Reject new work while existing leases continue to drain."""
        with self._state_lock:
            self._draining = True

    def end_draining(self) -> None:
        """Allow new work after an activation hand-off has completed."""
        with self._state_lock:
            self._draining = False

    def _acquire_component(
        self, lease: RuntimeLease, component: object | None, name: str
    ) -> object:
        if component is None:
            lease.release()
            raise RuntimeNotReadyError(f"{name} backend is not ready")
        return component

    @overload
    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult: ...

    @overload
    async def transcribe(
        self,
        request: bytes,
        language: str | None,
        prompt: str,
        include_timestamps: bool = False,
    ) -> TranscriptResult: ...

    async def transcribe(
        self,
        request: TranscriptionRequest | bytes,
        language: str | None = None,
        prompt: str = "",
        include_timestamps: bool = False,
    ) -> TranscriptResult:
        """Transcribe a typed request or preserve the legacy callable signature."""
        if isinstance(request, bytes):
            request = TranscriptionRequest(
                request_id=f"req_{uuid4().hex}",
                audio=request,
                language=language,
                prompt=prompt,
                include_timestamps=include_timestamps,
            )
        if not isinstance(request, TranscriptionRequest):
            raise TypeError("transcribe requires a TranscriptionRequest or bytes")
        lease = self.acquire()
        try:
            backend = self._acquire_component(lease, lease.bundle.asr, "ASR")
            method = getattr(backend, "transcribe", None)
            if callable(backend):
                if callable(method):
                    transcribe = cast(
                        Callable[[TranscriptionRequest], Awaitable[TranscriptResult]], method
                    )
                    return await transcribe(request)
                legacy_transcribe = cast(Callable[..., Awaitable[TranscriptResult]], backend)
                return await legacy_transcribe(
                    request.audio, request.language, request.prompt, request.include_timestamps
                )
            if not callable(method):
                raise RuntimeNotReadyError("ASR backend does not expose transcribe")
            transcribe = cast(
                Callable[[TranscriptionRequest], Awaitable[TranscriptResult]], method
            )
            return await transcribe(request)
        finally:
            lease.release()

    async def __call__(
        self,
        audio: bytes,
        language: str | None,
        prompt: str,
        include_timestamps: bool = False,
    ) -> TranscriptResult:
        """Preserve the legacy callable batch seam used by older route clients."""
        return await self.transcribe(audio, language, prompt, include_timestamps)

    async def transcribe_stream(
        self,
        request_id: str,
        audio: AsyncIterator[bytes],
        language: str | None = None,
        prompt: str | None = None,
        include_timestamps: bool = True,
    ) -> TranscriptResult:
        """Run the optional bounded streaming-batch port under one lease."""
        lease = self.acquire()
        try:
            backend = self._acquire_component(lease, lease.bundle.asr, "ASR")
            method = getattr(backend, "transcribe_stream", None)
            if callable(method):
                transcribe_stream = cast(
                    Callable[..., Awaitable[TranscriptResult]],
                    method,
                )
                return await transcribe_stream(
                    request_id,
                    audio,
                    language=language,
                    prompt=prompt or "",
                    include_timestamps=include_timestamps,
                )
            raise RuntimeNotReadyError("ASR backend does not expose transcribe_stream")
        finally:
            lease.release()

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        """Return a lazy stream that pins its generation until it is closed."""

        if self.is_draining:
            raise RuntimeDrainingError()

        async def stream() -> AsyncIterator[AudioChunk]:
            lease: RuntimeLease | None = None
            source: object | None = None
            try:
                lease = self.acquire()
                backend = self._acquire_component(lease, lease.bundle.tts, "TTS")
                method = getattr(backend, "synthesize", None)
                if not callable(method):
                    raise RuntimeNotReadyError("TTS backend does not expose synthesize")
                source = cast(Callable[[SpeechRequest], AsyncIterator[AudioChunk]], method)(request)
                async for chunk in source:
                    yield chunk
            finally:
                if source is not None:
                    with suppress(Exception):
                        await _close_async_iterator(source)
                if lease is not None:
                    lease.release()

        return stream()

    def create(self, *, language: str | None, prompt: str) -> RealtimeAsrSession:
        """Create a session pinned to the generation that created it."""
        lease = self.acquire()
        factory = lease.bundle.realtime_factory
        if factory is None:
            lease.release()
            raise RuntimeNotReadyError("realtime ASR backend is not ready")
        try:
            session = factory.create(language=language, prompt=prompt)
        except BaseException:
            lease.release()
            raise
        return _ManagedRealtimeSession(session, factory, lease)

    def release(self, session: RealtimeAsrSession) -> None:
        """Release a created session through its original factory generation."""
        if isinstance(session, _ManagedRealtimeSession):
            try:
                session._release_factory()
            finally:
                # The normal caller closes first; this fallback prevents a
                # release-only legacy caller from leaking the generation lease.
                session._lease.release()
            return
        factory = self.bundle.realtime_factory
        if factory is not None:
            factory.release(session)


__all__ = [
    "ActiveWork",
    "ActiveWorkLease",
    "ManagedRuntime",
    "ManagedRuntimeError",
    "RuntimeBundle",
    "RuntimeBusyError",
    "RuntimeDrainingError",
    "RuntimeLease",
    "RuntimeNotReadyError",
]
