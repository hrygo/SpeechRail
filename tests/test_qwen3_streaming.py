"""Tests for the native Qwen3 causal-streaming ASR backend adapter."""

from __future__ import annotations

import asyncio
from collections.abc import Mapping
from pathlib import Path

import pytest
from pydantic import ValidationError

from speechrail.backends.qwen3_streaming import (
    NativeRealtimeFactory,
    Qwen3StreamingBackendConfig,
    Qwen3StreamingSession,
    Qwen3StreamingWorker,
)
from speechrail.config import Settings
from speechrail.domain.ports import StreamingAsrEvent


class FakeStreamingWorker:
    """In-memory worker stand-in that speaks the same multiplexed framed dialect."""

    def __init__(self) -> None:
        self.sent: list[Mapping[str, object]] = []
        self._queues: dict[str, asyncio.Queue[dict[str, object]]] = {}
        self._ready = False
        self._closed = False
        self.timeout_seconds = 5.0

    async def start(self) -> None:
        self._ready = True

    async def send(self, payload: Mapping[str, object]) -> None:
        self.sent.append(payload)

    def register_session(self, session_id: str) -> asyncio.Queue[dict[str, object]]:
        queue: asyncio.Queue[dict[str, object]] = asyncio.Queue()
        self._queues[session_id] = queue
        return queue

    def unregister_session(self, session_id: str) -> None:
        self._queues.pop(session_id, None)

    async def close(self) -> None:
        self._closed = True

    def push(self, session_id: str, frame: dict[str, object]) -> None:
        self._queues[session_id].put_nowait(frame)


class _FakeTransport:
    """Transport stand-in that replays a single canned handshake frame."""

    def __init__(self, response: dict[str, object]) -> None:
        self.response = response

    async def start(self) -> None:
        return None

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        del payload, binary_payload

    async def receive(self) -> dict[str, object]:
        return self.response

    async def exchange(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> dict[str, object]:
        del payload, binary_payload
        return self.response

    async def close(self) -> None:
        return None


class _ScriptedTransport:
    """Transport that replays a scripted frame queue, blocking when drained."""

    def __init__(self) -> None:
        self._frames: asyncio.Queue[dict[str, object]] = asyncio.Queue()

    async def start(self) -> None:
        return None

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        del payload, binary_payload

    async def receive(self) -> dict[str, object]:
        return await self._frames.get()

    async def exchange(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> dict[str, object]:
        del payload, binary_payload
        return await self.receive()

    async def close(self) -> None:
        return None

    def push(self, frame: dict[str, object]) -> None:
        self._frames.put_nowait(frame)


class _IdleTimeoutThenScriptedTransport:
    """Raises one idle-read TimeoutError, then behaves like a scripted transport.

    A shared streaming worker legitimately emits no frames while no session is
    active. The dispatcher's read must treat that silence as normal and keep
    routing later frames instead of dying permanently (which strands every
    subsequent session waiting for ``session.opened``).
    """

    def __init__(self) -> None:
        self._frames: asyncio.Queue[dict[str, object]] = asyncio.Queue()
        self._idle_fired = False

    async def start(self) -> None:
        return None

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        del payload, binary_payload

    async def receive(self) -> dict[str, object]:
        if not self._idle_fired:
            self._idle_fired = True
            raise TimeoutError("idle receive timeout")
        return await self._frames.get()

    async def exchange(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> dict[str, object]:
        # The start handshake consumes the ready frame without idle simulation.
        del payload, binary_payload
        return await self._frames.get()

    async def close(self) -> None:
        return None

    def push(self, frame: dict[str, object]) -> None:
        self._frames.put_nowait(frame)


def test_streaming_worker_start_failure_embeds_worker_stderr_tail(tmp_path: Path) -> None:
    snapshot = tmp_path.parent / "external-qwen3-streaming-snapshot"
    snapshot.mkdir()
    worker = Qwen3StreamingWorker(
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=Path("/usr/bin/python3"),
            model_dir=snapshot,
            device="mps",
        )
    )
    fake = _FakeTransport(
        {
            "type": "error",
            "code": "worker_load_error",
            "stderr_tail": "mlx.core: [Metal] failed to allocate model weights",
        }
    )
    worker._transport = fake  # type: ignore[assignment]

    async def scenario() -> None:
        with pytest.raises(RuntimeError, match="worker_load_error") as exc_info:
            await worker.start()
        assert "failed to allocate" in str(exc_info.value)

    asyncio.run(scenario())


def test_streaming_worker_dispatches_frames_by_session_id(tmp_path: Path) -> None:
    """The single dispatcher routes each frame into the queue registered for its
    session_id and refreshes last_active so active sessions defeat eviction."""

    worker = Qwen3StreamingWorker(
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=Path("/usr/bin/python3"),
            model_dir=tmp_path,
            device="mps",
        )
    )
    transport = _ScriptedTransport()
    worker._transport = transport  # type: ignore[assignment]

    async def scenario() -> None:
        transport.push(
            {"type": "ready", "model_loaded": True, "device": "mps", "dtype": "float16"}
        )
        await worker.start()
        queue = worker.register_session("sess_a")
        await asyncio.sleep(0.01)
        before = worker.last_active
        transport.push(
            {
                "type": "event",
                "session_id": "sess_a",
                "kind": "partial",
                "text": "你好",
            }
        )
        frame = await asyncio.wait_for(queue.get(), timeout=1.0)
        assert frame.get("kind") == "partial"
        assert frame.get("session_id") == "sess_a"
        assert worker.last_active > before
        await worker.close()

    asyncio.run(scenario())


def test_streaming_worker_dispatcher_survives_idle_receive_timeout(tmp_path: Path) -> None:
    """An idle read timeout must not kill the dispatcher: a shared streaming
    worker legitimately emits no frames between sessions, and dispatcher death
    would strand every later session in connect() waiting for session.opened."""

    worker = Qwen3StreamingWorker(
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=Path("/usr/bin/python3"),
            model_dir=tmp_path,
            device="mps",
        )
    )
    transport = _IdleTimeoutThenScriptedTransport()
    worker._transport = transport  # type: ignore[assignment]

    async def scenario() -> None:
        transport.push(
            {"type": "ready", "model_loaded": True, "device": "mps", "dtype": "float16"}
        )
        await worker.start()
        queue = worker.register_session("sess_a")
        await asyncio.sleep(0.01)
        transport.push(
            {
                "type": "event",
                "session_id": "sess_a",
                "kind": "partial",
                "text": "你好",
            }
        )
        frame = await asyncio.wait_for(queue.get(), timeout=1.0)
        assert frame.get("kind") == "partial"
        assert frame.get("session_id") == "sess_a"
        assert worker._dispatcher is not None
        assert not worker._dispatcher.done()
        await worker.close()

    asyncio.run(scenario())


def test_session_connect_cancellation_unregisters_its_queue() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        session = Qwen3StreamingSession(
            worker=worker,  # type: ignore[arg-type]
            language="zh",
            prompt="",
            session_id="sess_test",
        )
        connect = asyncio.create_task(session.connect())
        await asyncio.sleep(0)
        assert session.session_id in worker._queues  # type: ignore[attr-defined]
        connect.cancel()
        with pytest.raises(asyncio.CancelledError):
            await connect
        assert session.session_id not in worker._queues  # type: ignore[attr-defined]

    asyncio.run(scenario())


def test_backend_config_requires_absolute_existing_paths(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="python_executable"):
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=tmp_path / "missing" / "python",
            model_dir=tmp_path,
            device="mps",
        )
    with pytest.raises(ValueError, match="model_dir"):
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=Path("/usr/bin/python3"),
            model_dir=tmp_path / "missing" / "model",
            device="mps",
        )


def test_backend_config_rejects_unknown_mode(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="invalid streaming mode"):
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=Path("/usr/bin/python3"),
            model_dir=tmp_path,
            device="mps",
            mode="unknown",  # type: ignore[arg-type]
        )


def test_settings_native_backend_fails_closed_without_python_or_model() -> None:
    with pytest.raises(ValidationError, match="qwen3_python"):
        Settings(realtime_asr_backend="native", _env_file=None)  # type: ignore[call-arg]
    with pytest.raises(ValidationError, match="qwen3_model_dir"):
        Settings(  # type: ignore[call-arg]
            realtime_asr_backend="native",
            qwen3_python=Path("/usr/bin/python3"),
            qwen3_model_dir=None,
            _env_file=None,
        )


def test_settings_defaults_to_disabled_windowed() -> None:
    settings = Settings()
    assert settings.realtime_asr_backend == "disabled"
    assert settings.qwen3_streaming_mode == "windowed"
    assert settings.realtime_max_sessions == 3


def test_settings_rejects_out_of_range_max_sessions() -> None:
    with pytest.raises(ValidationError, match="realtime_max_sessions"):
        Settings(realtime_max_sessions=0, _env_file=None)  # type: ignore[call-arg]
    with pytest.raises(ValidationError, match="realtime_max_sessions"):
        Settings(realtime_max_sessions=9, _env_file=None)  # type: ignore[call-arg]


def test_factory_rejects_causal_mode_for_non_english() -> None:
    factory = NativeRealtimeFactory(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        mode="causal",
        next_session_id=lambda: "sess_test",
    )
    for language in ("zh", "auto", None):
        with pytest.raises(RuntimeError, match="language_not_supported"):
            factory.create(language=language, prompt="")


def test_factory_accepts_english_for_causal_mode() -> None:
    factory = NativeRealtimeFactory(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        mode="causal",
        next_session_id=lambda: "sess_test",
    )
    session = factory.create(language="en", prompt="")
    assert session is not None
    factory.release(session)


def test_factory_rejects_unknown_language_in_windowed_mode() -> None:
    factory = NativeRealtimeFactory(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        mode="windowed",
        next_session_id=lambda: "sess_test",
    )
    with pytest.raises(RuntimeError, match="language_not_supported"):
        factory.create(language="sw", prompt="")


def test_factory_enforces_max_sessions_cap() -> None:
    worker = FakeStreamingWorker()
    factory = NativeRealtimeFactory(
        worker=worker,  # type: ignore[arg-type]
        mode="windowed",
        next_session_id=iter(["s1", "s2", "s3"]).__next__,
        max_sessions=2,
    )
    first = factory.create(language="zh", prompt="")
    second = factory.create(language="en", prompt="")
    with pytest.raises(RuntimeError, match="busy"):
        factory.create(language="en", prompt="")
    factory.release(first)
    third = factory.create(language="en", prompt="")
    assert third is not first and third is not second
    factory.release(second)
    factory.release(third)


def test_factory_generates_distinct_sessions_by_session_id() -> None:
    factory = NativeRealtimeFactory(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        mode="windowed",
        next_session_id=iter(["s1", "s2"]).__next__,
        max_sessions=2,
    )
    first = factory.create(language="zh", prompt="")
    second = factory.create(language="zh", prompt="")
    assert first.session_id == "s1"
    assert second.session_id == "s2"
    factory.release(first)
    factory.release(second)


def test_session_proxies_open_and_streams_events() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        session = Qwen3StreamingSession(
            worker=worker,  # type: ignore[arg-type]
            language="zh",
            prompt="",
            session_id="sess_test",
        )
        connect = asyncio.create_task(session.connect())
        await asyncio.sleep(0)
        worker.push(
            "sess_test",
            {"type": "session.opened", "session_id": "sess_test", "language": "zh"},
        )
        await connect
        assert any(frame.get("type") == "session.open" for frame in worker.sent)

        worker.push(
            "sess_test",
            {
                "type": "event",
                "session_id": "sess_test",
                "kind": "completed",
                "text": "你好 世界",
                "segments": [
                    {"text": "你好", "start_ms": 0, "end_ms": 500},
                    {"text": "世界", "start_ms": 500, "end_ms": 1000},
                ],
            },
        )
        events: list[StreamingAsrEvent] = []
        task = asyncio.create_task(_collect(session, events, until=1))
        worker.push(
            "sess_test",
            {"type": "finished", "session_id": "sess_test", "final": True},
        )
        await task
        assert len(events) == 1
        assert events[0].kind == "completed"
        assert events[0].text == "你好 世界"
        assert len(events[0].segments) == 2
        assert events[0].segments[0].text == "你好"
        assert events[0].segments[0].start_ms == 0
        assert events[0].segments[0].end_ms == 500
        await session.close()

    asyncio.run(scenario())


async def _collect(
    session: Qwen3StreamingSession,
    out: list[StreamingAsrEvent],
    *,
    until: int,
) -> None:
    async for event in session.events():
        out.append(event)
        if len(out) >= until:
            return


def test_session_maps_worker_error_to_error_event() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        session = Qwen3StreamingSession(
            worker=worker,  # type: ignore[arg-type]
            language="zh",
            prompt="",
            session_id="sess_test",
        )
        connect = asyncio.create_task(session.connect())
        await asyncio.sleep(0)
        worker.push(
            "sess_test",
            {"type": "session.opened", "session_id": "sess_test", "language": "zh"},
        )
        await connect
        worker.push(
            "sess_test",
            {"type": "error", "session_id": "sess_test", "code": "worker_inference_error"},
        )
        events: list[StreamingAsrEvent] = []
        task = asyncio.create_task(_collect(session, events, until=1))
        await task
        assert events[0].kind == "error"
        assert events[0].error_code == "worker_inference_error"
        await session.close()

    asyncio.run(scenario())


def test_session_close_unregisters_its_queue() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        session = Qwen3StreamingSession(
            worker=worker,  # type: ignore[arg-type]
            language="zh",
            prompt="",
            session_id="sess_test",
        )
        connect = asyncio.create_task(session.connect())
        await asyncio.sleep(0)
        worker.push(
            "sess_test",
            {"type": "session.opened", "session_id": "sess_test", "language": "zh"},
        )
        await connect
        assert session.session_id in worker._queues  # type: ignore[attr-defined]
        await session.close()
        assert session.session_id not in worker._queues  # type: ignore[attr-defined]
        cancel_frames = [
            f
            for f in worker.sent
            if f.get("type") == "cancel" and f.get("session_id") == "sess_test"
        ]
        assert len(cancel_frames) == 1

    asyncio.run(scenario())


def test_streaming_command_passes_dtype_and_metal_limits(tmp_path: Path) -> None:
    """Regression: the streaming worker command must forward dtype and Metal
    cache/memory limits so native realtime inherits the configured int8 backend
    instead of silently falling back to float16 with an unbounded Metal cache."""
    snapshot = tmp_path / "external-qwen3-streaming-snapshot"
    snapshot.mkdir()
    cfg = Qwen3StreamingBackendConfig(
        repository_root=tmp_path,
        python_executable=Path("/usr/bin/python3"),
        model_dir=snapshot,
        device="mps",
        dtype="int8",
        cache_limit_mb=256,
        memory_limit_mb=0,
    )
    cmd = cfg.command()

    assert "--dtype" in cmd
    assert cmd[cmd.index("--dtype") + 1] == "int8"
    assert "--cache-limit-mb" in cmd
    assert cmd[cmd.index("--cache-limit-mb") + 1] == "256"
    assert "--memory-limit-mb" not in cmd  # only added when memory_limit_mb > 0
