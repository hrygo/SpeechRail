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

from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.ports import RealtimeAsrFactory, RealtimeAsrSession, StreamingAsrEvent
from speechrail.runtime.worker_process import (
    AsyncFramedWorkerProcess,
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
    """Narrow interface required by streaming sessions from an ASR worker."""

    @property
    def alive(self) -> bool: ...

    async def start(self) -> None: ...

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None: ...

    async def receive(self) -> dict[str, object]: ...


@dataclass(frozen=True, slots=True)
class Qwen3StreamingBackendConfig:
    repository_root: Path
    python_executable: Path
    model_dir: Path
    device: Literal["mps", "cpu"]
    mode: Literal["windowed", "causal"] = "windowed"
    chunk_sec: float = 2.0
    left_context_sec: float = 12.0
    right_context_ms: int = 640
    hold_back_words: int = 6
    stable_iterations: int = 2
    max_new_tokens: int = 256
    timeout_seconds: float = 120.0

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
        object.__setattr__(self, "repository_root", root)
        object.__setattr__(self, "python_executable", python)
        object.__setattr__(self, "model_dir", resolved_model)

    def command(self) -> list[str]:
        return [
            str(self.python_executable),
            "-m",
            "speechrail.backends.qwen3_worker",
            "--model-dir",
            str(self.model_dir),
            "--device",
            self.device,
            "--max-new-tokens",
            str(self.max_new_tokens),
        ]

    def worker_spec(self) -> WorkerProcessSpec:
        return WorkerProcessSpec(
            command=tuple(self.command()),
            cwd=self.repository_root,
            env=offline_environment(self.repository_root),
            io_timeout_seconds=self.timeout_seconds,
        )


class Qwen3StreamingWorker:
    """One supervised, offline streaming worker shared by sequential sessions."""

    def __init__(self, config: Qwen3StreamingBackendConfig) -> None:
        self.config = config
        self._transport = AsyncFramedWorkerProcess(config.worker_spec())
        self._write_lock = asyncio.Lock()
        self._ready = False
        self._active_session: Qwen3StreamingSession | None = None

    @property
    def alive(self) -> bool:
        return self._transport.alive

    async def start(self) -> None:
        if self._ready:
            return
        await self._transport.start()
        await self._transport.send(
            {
                "version": PROTOCOL_VERSION,
                "type": "start",
                "model_dir": str(self.config.model_dir),
                "device": self.config.device,
            }
        )
        ready = await self._transport.receive()
        if ready.get("type") != "ready" or ready.get("model_loaded") is not True:
            raise RuntimeError("streaming worker failed to become ready")
        self._ready = True

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        async with self._write_lock:
            await self._transport.send(payload, binary_payload=binary_payload)

    async def receive(self) -> dict[str, object]:
        return await self._transport.receive()

    async def close(self) -> None:
        await self._transport.close()
        self._ready = False


class Qwen3StreamingSession(RealtimeAsrSession):
    """One bounded realtime session proxying PCM to the shared worker."""

    def __init__(
        self,
        *,
        worker: StreamingWorkerProtocol,
        language: str,
        prompt: str,
        session_id: str,
    ) -> None:
        self._worker = worker
        self._language = language
        self._prompt = prompt
        self._session_id = session_id
        self._events_queue: asyncio.Queue[StreamingAsrEvent | None] = asyncio.Queue()
        self._reader: asyncio.Task[None] | None = None
        self._connected = False
        self._finished = asyncio.Event()

    async def connect(self) -> None:
        if self._connected:
            return
        await self._worker.start()
        await self._worker.send(
            {
                "version": PROTOCOL_VERSION,
                "type": "session.open",
                "session_id": self._session_id,
                "language": self._language,
                "context": self._prompt,
            }
        )
        opened = await self._worker.receive()
        if opened.get("type") != "session.opened":
            raise RuntimeError("streaming session.open failed")
        self._connected = True
        self._reader = asyncio.create_task(self._read_loop())

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

    async def commit(self) -> None:
        await self._worker.send(
            {"version": PROTOCOL_VERSION, "type": "commit", "session_id": self._session_id}
        )
        await self._finished.wait()

    def events(self) -> AsyncIterator[StreamingAsrEvent]:
        async def iterator() -> AsyncIterator[StreamingAsrEvent]:
            while True:
                event = await self._events_queue.get()
                if event is None:
                    return
                yield event

        return iterator()

    async def close(self) -> None:
        if self._reader is not None:
            self._reader.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._reader
            self._reader = None
        if self._connected:
            await self._worker.send(
                {"version": PROTOCOL_VERSION, "type": "cancel", "session_id": self._session_id}
            )
            self._connected = False

    async def _read_loop(self) -> None:
        try:
            while True:
                frame = await self._worker.receive()
                kind = frame.get("type")
                if kind == "event":
                    await self._events_queue.put(_to_event(frame))
                elif kind == "finished":
                    self._finished.set()
                    await self._events_queue.put(None)
                    return
                elif kind == "error":
                    code = frame.get("code")
                    await self._events_queue.put(
                        StreamingAsrEvent(
                            kind="error",
                            error_code=str(code or "backend_error"),
                        )
                    )
                    self._finished.set()
                    await self._events_queue.put(None)
                    return
        except asyncio.CancelledError:
            raise
        except Exception:
            self._finished.set()
            await self._events_queue.put(None)


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
                id=f"seg_{index}",
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
    """Creates one streaming session at a time on the shared native worker."""

    def __init__(
        self,
        *,
        worker: StreamingWorkerProtocol,
        mode: Literal["windowed", "causal"],
        next_session_id: Callable[[], str],
    ) -> None:
        self._worker = worker
        self._mode = mode
        self._next_session_id = next_session_id
        self._active: Qwen3StreamingSession | None = None

    def create(self, *, language: str | None, prompt: str) -> Qwen3StreamingSession:
        resolved = (language or "auto").strip().lower()
        if self._mode == "causal" and resolved not in {"en", "english"}:
            raise _unsupported_language(resolved)
        if resolved not in _SUPPORTED_LANGUAGES and resolved != "auto":
            raise _unsupported_language(resolved)
        if self._active is not None:
            raise RuntimeError("realtime streaming backend busy")
        session = Qwen3StreamingSession(
            worker=self._worker,
            language=resolved,
            prompt=prompt,
            session_id=self._next_session_id(),
        )
        self._active = session
        return session

    def release(self, session: RealtimeAsrSession) -> None:
        if self._active is session:
            self._active = None


def _unsupported_language(language: str) -> RuntimeError:
    return RuntimeError(f"language_not_supported: {language}")


__all__ = [
    "NativeRealtimeFactory",
    "Qwen3StreamingBackendConfig",
    "Qwen3StreamingSession",
    "Qwen3StreamingWorker",
    "StreamingWorkerProtocol",
]
