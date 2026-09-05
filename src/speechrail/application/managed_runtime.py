"""Stable, generation-aware delegation for inference backends.

The composition root owns the physical workers.  HTTP and WebSocket routes keep
one ``ManagedRuntime`` object instead, so a future bundle switch cannot leave a
route holding a stale worker adapter.  A bundle is immutable and remains pinned
for the lifetime of each piece of work.
"""

from __future__ import annotations

import asyncio
import inspect
import math
import threading
import time
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


class RuntimeDrainError(ManagedRuntimeError):
    """Base error for the managed runtime drain lifecycle."""

    code = "runtime_drain_error"


class RuntimeDrainTokenError(RuntimeDrainError, ValueError):
    """Raised for foreign, expired, or already-consumed drain tokens."""

    code: ClassVar[str] = "runtime_drain_token_invalid"

    def __init__(self, message: str | None = None) -> None:
        resolved = message or self.code
        super().__init__(resolved)
        self.message = resolved


class RuntimeDrainBusyError(RuntimeDrainError, RuntimeBusyError):
    """Raised when another drain owner already controls the runtime."""

    code = "runtime_drain_busy"


class RuntimeDrainActivationError(RuntimeDrainTokenError):
    """Raised when a token has already crossed into activation."""

    code = "runtime_drain_activation_claimed"


class DrainState:
    """Thread-safe single-owner state machine for a runtime drain.

    ``begin`` changes admission synchronously.  An unclaimed token expires at
    its deadline and reopens admission when ``expire`` is called.  Production
    callers use the injected monotonic clock; tests may provide a deterministic
    clock and explicit ``now`` values.
    """

    DEFAULT_TTL_SECONDS: ClassVar[float] = 120.0

    def __init__(self, *, clock: Callable[[], float] | None = None) -> None:
        self._clock = time.monotonic if clock is None else clock
        self._lock = threading.RLock()
        self._accepting = True
        self._token: str | None = None
        self._deadline: float | None = None
        self._activation_claimed = False

    @property
    def accepting(self) -> bool:
        """Whether new work may be admitted."""
        with self._lock:
            return self._accepting

    @property
    def draining(self) -> bool:
        """Whether a drain owner currently blocks new work."""
        return not self.accepting

    @property
    def token(self) -> str | None:
        """Return the current owner token for lifecycle inspection."""
        with self._lock:
            return self._token

    @property
    def deadline(self) -> float | None:
        """Return the monotonic deadline of the current unexpired token."""
        with self._lock:
            return self._deadline

    @property
    def activation_claimed(self) -> bool:
        """Whether the current token has entered the activation phase."""
        with self._lock:
            return self._activation_claimed

    def begin(
        self,
        now: float | None = None,
        ttl_seconds: float = DEFAULT_TTL_SECONDS,
    ) -> str:
        """Claim the only drain owner and immediately stop admission."""
        ttl_value = self._validate_ttl(ttl_seconds)
        current = self._current_time(now)
        with self._lock:
            self._expire_locked(current)
            if self._token is not None or not self._accepting:
                raise RuntimeDrainBusyError()
            token = uuid4().hex
            self._token = token
            self._deadline = current + ttl_value
            self._activation_claimed = False
            self._accepting = False
            return token

    def expire(self, now: float | None = None) -> bool:
        """Expire an unclaimed token and reopen admission when its TTL ends."""
        current = self._current_time(now)
        with self._lock:
            return self._expire_locked(current)

    def resume(self, token: str) -> None:
        """Resume admission for the matching unclaimed token exactly once."""
        current = self._current_time()
        with self._lock:
            self._expire_locked(current)
            self._require_token_locked(token)
            if self._activation_claimed:
                raise RuntimeDrainActivationError()
            self._clear_locked()

    def claim_activation(self, token: str) -> None:
        """Mark a valid token as owned by the later activation phase."""
        current = self._current_time()
        with self._lock:
            self._expire_locked(current)
            self._require_token_locked(token)
            if self._activation_claimed:
                raise RuntimeDrainActivationError()
            self._activation_claimed = True

    def abort(self, token: str) -> bool:
        """Cancel an unclaimed drain owned by ``token`` and reopen admission."""
        with self._lock:
            if token != self._token or self._activation_claimed:
                return False
            self._clear_locked()
            return True

    def owns(self, token: str) -> bool:
        """Return whether ``token`` is still a live owner."""
        current = self._current_time()
        with self._lock:
            self._expire_locked(current)
            return token == self._token

    def _expire_locked(self, now: float) -> bool:
        if (
            self._token is None
            or self._activation_claimed
            or self._deadline is None
            or now < self._deadline
        ):
            return False
        self._clear_locked()
        return True

    def _require_token_locked(self, token: str) -> None:
        if self._token is None or token != self._token:
            raise RuntimeDrainTokenError()

    def _clear_locked(self) -> None:
        self._accepting = True
        self._token = None
        self._deadline = None
        self._activation_claimed = False

    @staticmethod
    def _validate_ttl(ttl_seconds: float) -> float:
        if (
            isinstance(ttl_seconds, bool)
            or not isinstance(ttl_seconds, (int, float))
            or not math.isfinite(ttl_seconds)
        ):
            raise ValueError("drain deadline must be finite")
        if ttl_seconds <= 0:
            raise ValueError("drain deadline must be positive")
        return float(ttl_seconds)

    def _current_time(self, value: float | None = None) -> float:
        current = self._clock() if value is None else value
        if (
            isinstance(current, bool)
            or not isinstance(current, (int, float))
            or not math.isfinite(current)
        ):
            raise ValueError("drain clock must be finite")
        return float(current)


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
        self._zero_event: asyncio.Event | None = None
        self._zero_loop: asyncio.AbstractEventLoop | None = None

    @property
    def count(self) -> int:
        """Return the number of unreleased work tokens."""
        with self._lock:
            return self._count

    def acquire(self, *, generation: int | str = 0) -> ActiveWorkLease:
        """Acquire one generation token, returning an idempotent release handle."""
        with self._lock:
            self._count += 1
            if self._count == 1 and self._zero_event is not None:
                self._zero_event.clear()
        return ActiveWorkLease(self, generation)

    def release(self, token: ActiveWorkLease) -> None:
        """Release one token without allowing an underflow."""
        event: asyncio.Event | None = None
        loop: asyncio.AbstractEventLoop | None = None
        with self._lock:
            if not isinstance(token, ActiveWorkLease) or token._owner is not self:
                raise ValueError("foreign ActiveWork lease")
            if token._released:
                return
            token._released = True
            if self._count:
                self._count -= 1
            if self._count == 0:
                event = self._zero_event
                loop = self._zero_loop
        if event is not None:
            self._notify_zero(event, loop)

    async def wait_for_zero(self) -> None:
        """Wait asynchronously until every active-work token is released."""
        loop = asyncio.get_running_loop()
        with self._lock:
            if self._count == 0:
                return
            if self._zero_event is None or self._zero_loop is not loop:
                self._zero_event = asyncio.Event()
                self._zero_loop = loop
            event = self._zero_event
        while True:
            await event.wait()
            with self._lock:
                if self._count == 0:
                    return
                event.clear()

    @staticmethod
    def _notify_zero(
        event: asyncio.Event,
        loop: asyncio.AbstractEventLoop | None,
    ) -> None:
        if loop is None:
            event.set()
            return
        try:
            current = asyncio.get_running_loop()
        except RuntimeError:
            current = None
        if current is loop:
            event.set()
        elif loop.is_closed():
            return
        else:
            loop.call_soon_threadsafe(event.set)

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
        clock: Callable[[], float] | None = None,
        drain_state: DrainState | None = None,
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
        self._drain_state = drain_state or DrainState(clock=clock)

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
        self._drain_state.expire()
        return self._drain_state.draining

    @property
    def drain_state(self) -> DrainState:
        """Return the drain state for lifecycle orchestration and inspection."""
        return self._drain_state

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
            self._drain_state.expire()
            if not self._drain_state.accepting:
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

    def begin_draining(self) -> str:
        """Synchronously reject new work and return the sole owner token."""
        with self._state_lock:
            self._drain_state.expire()
            return self._drain_state.begin()

    async def drain(self, deadline_seconds: float = DrainState.DEFAULT_TTL_SECONDS) -> str:
        """Stop admission and wait for active work, with cancellation-safe cleanup.

        A timeout or cancellation only resumes admission.  Existing leases are
        left untouched, so their batch, TTS, or realtime operation may finish.
        On success the returned token remains the sole owner until ``resume``
        or ``claim_activation`` is called.
        """
        with self._state_lock:
            token = self._drain_state.begin(ttl_seconds=deadline_seconds)
            if self._active_work.count == 0:
                return token
        try:
            async with asyncio.timeout(deadline_seconds):
                await self._active_work.wait_for_zero()
        except BaseException:
            self._drain_state.abort(token)
            raise
        if not self._drain_state.owns(token):
            raise RuntimeDrainTokenError("drain token expired")
        return token

    async def resume(self, token: str) -> None:
        """Resume admission for the matching unclaimed drain owner."""
        self._drain_state.resume(token)

    def expire(self, now: float | None = None) -> bool:
        """Apply the drain TTL and report whether it reopened admission."""
        return self._drain_state.expire(now=now)

    def claim_activation(self, token: str) -> None:
        """Transfer a drained token to the later activation phase."""
        self._drain_state.claim_activation(token)

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
    "DrainState",
    "ManagedRuntime",
    "ManagedRuntimeError",
    "RuntimeBundle",
    "RuntimeBusyError",
    "RuntimeDrainActivationError",
    "RuntimeDrainBusyError",
    "RuntimeDrainError",
    "RuntimeDrainTokenError",
    "RuntimeDrainingError",
    "RuntimeLease",
    "RuntimeNotReadyError",
]
