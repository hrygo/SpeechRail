"""Native Qwen3 causal-streaming ASR backend (main-process adapter).

The main process never imports qwen3_asr_causal.  It proxies framed PCM/events
to and from the isolated worker process and implements the existing
``RealtimeAsrSession`` port.
"""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import AsyncIterator, Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Protocol

from speechrail.backends.qwen3_shared import Qwen3SharedWorker
from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.ports import RealtimeAsrFactory, RealtimeAsrSession, StreamingAsrEvent
from speechrail.runtime.asr_mode import AsrModeGate, AsrModeLease
from speechrail.runtime.worker_process import (
    WorkerProcessSpec,
    offline_environment,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION

_MODE_NAMES = ("windowed", "causal")
_SUPPORTED_LANGUAGES = {
    "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko",
    "ru", "th", "vi", "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi",
    "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
    "chinese", "english", "cantonese", "arabic", "german", "french",
    "spanish", "portuguese", "indonesian", "italian", "korean", "russian",
    "thai", "vietnamese", "japanese", "turkish", "hindi", "malay", "dutch",
    "swedish", "danish", "finnish", "polish", "czech", "filipino", "persian",
    "greek", "romanian", "hungarian", "macedonian",
}


class StreamingWorkerProtocol(Protocol):
    """Narrow multiplexed interface required by streaming sessions from an ASR worker."""

    @property
    def mode_gate(self) -> AsrModeGate: ...

    @property
    def alive(self) -> bool: ...

    @property
    def timeout_seconds(self) -> float: ...

    async def start(self) -> None: ...

    def register_session(self, session_id: str) -> asyncio.Queue[dict[str, object]]: ...

    def unregister_session(self, session_id: str) -> None: ...

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None: ...

    async def close(self) -> None: ...


@dataclass(frozen=True, slots=True)
class Qwen3StreamingBackendConfig:
    repository_root: Path
    python_executable: Path
    model_dir: Path
    device: Literal["mps", "cpu"]
    dtype: Literal["float16", "float32", "int8"] = "float16"
    cache_limit_mb: int = 256
    memory_limit_mb: int = 0
    mode: Literal["windowed", "causal"] = "windowed"
    chunk_sec: float = 2.0
    left_context_sec: float = 12.0
    right_context_ms: int = 640
    hold_back_words: int = 6
    stable_iterations: int = 2
    max_new_tokens: int = 256
    timeout_seconds: float = 120.0
    worker_role: str = "streaming"

    def __post_init__(self) -> None:
        if self.mode not in _MODE_NAMES:
            raise ValueError("invalid streaming mode")
        root = self.repository_root.resolve(strict=True)
        python = self.python_executable.absolute()
        if not python.is_file():
            raise ValueError("python_executable must be an executable local file")
        model = self.model_dir
        if not model.is_absolute():
            raise ValueError("model_dir must be an absolute path")
        try:
            resolved_model = model.resolve(strict=True)
        except OSError as exc:
            raise ValueError("model_dir must be an existing local directory") from exc
        if not resolved_model.is_dir():
            raise ValueError("model_dir must be an existing local directory")
        if self.device == "mps" and self.dtype not in {"float16", "int8"}:
            raise ValueError("MPS requires float16 or int8")
        if self.device == "cpu" and self.dtype not in {"float32", "int8"}:
            raise ValueError("CPU requires float32 or int8")
        object.__setattr__(self, "repository_root", root)
        object.__setattr__(self, "python_executable", python)
        object.__setattr__(self, "model_dir", resolved_model)

    def command(self) -> list[str]:
        cmd = [
            str(self.python_executable),
            "-m",
            "speechrail.backends.qwen3_worker",
            "--model-dir",
            str(self.model_dir),
            "--device",
            self.device,
            "--dtype",
            self.dtype,
            "--max-new-tokens",
            str(self.max_new_tokens),
            "--cache-limit-mb",
            str(self.cache_limit_mb),
            "--worker-role",
            self.worker_role,
        ]
        if self.memory_limit_mb > 0:
            cmd.extend(["--memory-limit-mb", str(self.memory_limit_mb)])
        return cmd

    def worker_spec(self) -> WorkerProcessSpec:
        return WorkerProcessSpec(
            command=tuple(self.command()),
            cwd=self.repository_root,
            env=offline_environment(self.repository_root),
            io_timeout_seconds=self.timeout_seconds,
        )


class Qwen3StreamingWorker:
    """One supervised offline streaming worker shared by concurrent sessions.

    A single dispatcher task owns the transport's read side and routes every
    frame to the per-session queue registered for its ``session_id``, so N
    sessions can multiplex one pipe without stealing each other's frames.
    """

    def __init__(
        self,
        config: Qwen3StreamingBackendConfig,
        *,
        shared_owner: Qwen3SharedWorker | None = None,
    ) -> None:
        self.config = config
        self._shared_owner = shared_owner or Qwen3SharedWorker(config)

    @property
    def shared_owner(self) -> Qwen3SharedWorker:
        """Return the sole IPC owner used by this streaming facade."""

        return self._shared_owner

    @property
    def mode_gate(self) -> AsrModeGate:
        return self._shared_owner.mode_gate

    @property
    def alive(self) -> bool:
        return self._shared_owner.alive

    @property
    def ready(self) -> bool:
        return self._shared_owner.ready

    @property
    def identity(self) -> tuple[str, str] | None:
        return self._shared_owner.identity

    @property
    def timeout_seconds(self) -> float:
        return self._shared_owner.timeout_seconds

    @property
    def last_active(self) -> float:
        return self._shared_owner.last_active

    def register_session(self, session_id: str) -> asyncio.Queue[dict[str, object]]:
        return self._shared_owner.register_session(session_id)

    def unregister_session(self, session_id: str) -> None:
        self._shared_owner.unregister_session(session_id)

    async def start(self) -> None:
        await self._shared_owner.start()

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        await self._shared_owner.send(payload, binary_payload=binary_payload)

    async def trim_memory(self) -> None:
        await self._shared_owner.trim_memory()

    async def close(self) -> None:
        await self._shared_owner.close()


class Qwen3StreamingSession(RealtimeAsrSession):
    """One bounded realtime session proxying PCM to the shared worker."""

    EVENT_QUEUE_MAXSIZE = 64

    def __init__(
        self,
        *,
        worker: StreamingWorkerProtocol,
        language: str,
        prompt: str,
        session_id: str,
        chunk_sec: float = 2.0,
        left_context_sec: float = 12.0,
        right_context_ms: int = 640,
        max_new_tokens: int = 256,
    ) -> None:
        self._worker = worker
        self._language = language
        self._prompt = prompt
        self._session_id = session_id
        self._chunk_sec = chunk_sec
        self._left_context_sec = left_context_sec
        self._right_context_ms = right_context_ms
        self._max_new_tokens = max_new_tokens
        self._queue: asyncio.Queue[dict[str, object]] | None = None
        self._events_queue: asyncio.Queue[StreamingAsrEvent | None] = asyncio.Queue(
            maxsize=self.EVENT_QUEUE_MAXSIZE
        )
        self._reader: asyncio.Task[None] | None = None
        self._connected = False
        self._finished = asyncio.Event()
        self._mode_lease: AsrModeLease | None = None
        self._cleanup_lock = asyncio.Lock()
        self._finalized = False

    @property
    def session_id(self) -> str:
        return self._session_id

    async def connect(self) -> None:
        if self._connected:
            return
        self._finalized = False
        self._finished = asyncio.Event()
        self._mode_lease = self._worker.mode_gate.acquire("streaming")
        registered = False
        try:
            await self._worker.start()
            self._queue = self._worker.register_session(self._session_id)
            registered = True
            await self._worker.send(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "session.open",
                    "session_id": self._session_id,
                    "language": self._language,
                    "context": self._prompt,
                    "chunk_sec": self._chunk_sec,
                    "left_context_sec": self._left_context_sec,
                    "right_context_ms": self._right_context_ms,
                    "max_new_tokens": self._max_new_tokens,
                }
            )
            assert self._queue is not None
            opened = await asyncio.wait_for(
                self._queue.get(),
                timeout=max(self._worker.timeout_seconds, 1.0),
            )
            if opened.get("type") != "session.opened":
                raise RuntimeError("streaming session.open failed")
            self._connected = True
            self._reader = asyncio.create_task(
                self._read_loop(), name=f"qwen3-stream-session-{self._session_id}"
            )
        except BaseException:
            # CancelledError 或握手失败也必须释放 session queue 与 mode token。
            with contextlib.suppress(BaseException):
                await self._finalize(cancel=registered)
            raise

    async def append_audio(self, audio: bytes) -> None:
        if not audio or len(audio) % 2:
            raise ValueError("requires non-empty PCM16 audio")
        await self._worker.send(
            {
                "version": PROTOCOL_VERSION,
                "type": "audio.append",
                "session_id": self._session_id,
            },
            binary_payload=audio,
        )

    async def flush(self) -> None:
        await self._worker.send(
            {"version": PROTOCOL_VERSION, "type": "flush", "session_id": self._session_id}
        )

    async def commit(self, want_segments: bool = False) -> None:
        await self._worker.send(
            {
                "version": PROTOCOL_VERSION,
                "type": "commit",
                "session_id": self._session_id,
                "want_segments": want_segments,
            }
        )
        # A worker that stops producing without EOF (hang) would otherwise park
        # this await forever and leak the shared streaming slot; the caller
        # tears the session down on TimeoutError.
        await asyncio.wait_for(
            self._finished.wait(), timeout=max(self._worker.timeout_seconds, 1.0)
        )

    def events(self) -> AsyncIterator[StreamingAsrEvent]:
        async def iterator() -> AsyncIterator[StreamingAsrEvent]:
            while True:
                event = await self._events_queue.get()
                if event is None:
                    return
                yield event

        return iterator()

    async def close(self) -> None:
        reader = self._reader
        if reader is not None and reader is not asyncio.current_task() and not reader.done():
            reader.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await reader
        self._reader = None
        await self._finalize(cancel=True)

    async def _read_loop(self) -> None:
        try:
            while True:
                if self._queue is None:
                    return
                frame = await self._queue.get()
                kind = frame.get("type")
                if kind == "event":
                    if not self._put_event(_to_event(frame)):
                        self._replace_events_with_error("session_queue_full")
                        with contextlib.suppress(BaseException):
                            await self._finalize(cancel=True)
                        return
                elif kind == "finished":
                    self._finished.set()
                    queue_full = not self._put_terminal()
                    if queue_full:
                        with contextlib.suppress(BaseException):
                            await self._finalize(cancel=True)
                    else:
                        await self._finalize(cancel=False)
                    return
                elif kind == "error":
                    code = frame.get("code")
                    self._finished.set()
                    queue_full = self._events_queue.full()
                    if queue_full:
                        self._replace_events_with_error("session_queue_full")
                    else:
                        self._events_queue.put_nowait(
                            StreamingAsrEvent(
                                kind="error",
                                error_code=str(code or "backend_error"),
                            )
                        )
                        self._events_queue.put_nowait(None)
                    if queue_full:
                        with contextlib.suppress(BaseException):
                            await self._finalize(cancel=True)
                    else:
                        await self._finalize(cancel=False)
                    return
        except asyncio.CancelledError:
            raise
        except Exception:
            self._finished.set()
            self._replace_events_with_error("worker_unavailable")
            with contextlib.suppress(BaseException):
                await self._finalize(cancel=True)

    def _put_event(self, event: StreamingAsrEvent) -> bool:
        try:
            self._events_queue.put_nowait(event)
        except asyncio.QueueFull:
            return False
        return True

    def _put_terminal(self) -> bool:
        if self._events_queue.full():
            self._replace_events_with_error("session_queue_full")
            return False
        self._events_queue.put_nowait(None)
        return True

    def _replace_events_with_error(self, code: str) -> None:
        _clear_event_queue(self._events_queue)
        self._events_queue.put_nowait(StreamingAsrEvent(kind="error", error_code=code))
        self._events_queue.put_nowait(None)

    async def _finalize(self, *, cancel: bool) -> None:
        async with self._cleanup_lock:
            if self._finalized:
                return
            self._finalized = True
            cleanup_error: BaseException | None = None
            try:
                if cancel and self._queue is not None:
                    try:
                        await self._worker.send(
                            {
                                "version": PROTOCOL_VERSION,
                                "type": "cancel",
                                "session_id": self._session_id,
                            }
                        )
                    except BaseException as exc:
                        cleanup_error = exc
            finally:
                self._connected = False
                queue = self._queue
                self._queue = None
                if queue is not None:
                    try:
                        self._worker.unregister_session(self._session_id)
                    except BaseException as exc:
                        if cleanup_error is None:
                            cleanup_error = exc
                lease = self._mode_lease
                self._mode_lease = None
                if lease is not None:
                    try:
                        self._worker.mode_gate.release(lease)
                    except BaseException as exc:
                        if cleanup_error is None:
                            cleanup_error = exc
                self._finished.set()
            if cleanup_error is not None:
                raise cleanup_error


def _clear_event_queue(queue: asyncio.Queue[StreamingAsrEvent | None]) -> None:
    while True:
        try:
            queue.get_nowait()
        except asyncio.QueueEmpty:
            return


def _to_event(frame: Mapping[str, object]) -> StreamingAsrEvent:
    kind = frame.get("kind")
    if kind == "completed":
        segments = _segments(frame.get("segments"))
        return StreamingAsrEvent(
            kind="completed",
            text=str(frame.get("text") or ""),
            language=_language(frame.get("language")),
            segments=segments,
        )
    return StreamingAsrEvent(kind="partial", text=str(frame.get("text") or ""))


def _segments(value: object) -> tuple[TranscriptSegment, ...]:
    if not isinstance(value, list):
        return ()
    result: list[TranscriptSegment] = []
    for index, raw in enumerate(value):
        if not isinstance(raw, dict):
            continue
        text = str(raw.get("text") or "").strip()
        if not text:
            continue
        result.append(
            TranscriptSegment(
                id=index,
                start_ms=int(raw.get("start_ms") or 0),
                end_ms=int(raw.get("end_ms") or 0),
                text=text,
            )
        )
    return tuple(result)


def _language(value: object) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    return value


class NativeRealtimeFactory(RealtimeAsrFactory):
    """Creates bounded concurrent streaming sessions on one shared native worker."""

    def __init__(
        self,
        *,
        worker: StreamingWorkerProtocol,
        mode: Literal["windowed", "causal"],
        next_session_id: Callable[[], str],
        max_sessions: int = 2,
    ) -> None:
        self._worker = worker
        self._mode = mode
        self._next_session_id = next_session_id
        self._max_sessions = max_sessions
        self._sessions: dict[str, Qwen3StreamingSession] = {}

    def create(self, *, language: str | None, prompt: str) -> Qwen3StreamingSession:
        resolved = (language or "auto").strip().lower()
        if self._mode == "causal" and resolved not in {"en", "english"}:
            raise _unsupported_language(resolved)
        if resolved not in _SUPPORTED_LANGUAGES and resolved != "auto":
            raise _unsupported_language(resolved)
        if len(self._sessions) >= self._max_sessions:
            raise RuntimeError("realtime streaming backend busy")
        config = getattr(self._worker, "config", None)
        session = Qwen3StreamingSession(
            worker=self._worker,
            language=resolved,
            prompt=prompt,
            session_id=self._next_session_id(),
            chunk_sec=getattr(config, "chunk_sec", 2.0),
            left_context_sec=getattr(config, "left_context_sec", 12.0),
            right_context_ms=getattr(config, "right_context_ms", 640),
            max_new_tokens=getattr(config, "max_new_tokens", 256),
        )
        self._sessions[session.session_id] = session
        return session

    def release(self, session: RealtimeAsrSession) -> None:
        if isinstance(session, Qwen3StreamingSession):
            self._sessions.pop(session.session_id, None)


def _unsupported_language(language: str) -> RuntimeError:
    return RuntimeError(f"language_not_supported: {language}")


__all__ = [
    "NativeRealtimeFactory",
    "Qwen3StreamingBackendConfig",
    "Qwen3StreamingSession",
    "Qwen3StreamingWorker",
    "StreamingWorkerProtocol",
]
