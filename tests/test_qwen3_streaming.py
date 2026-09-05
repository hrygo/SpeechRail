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
from speechrail.runtime.asr_mode import AsrModeGate


class FakeStreamingWorker:
    """In-memory worker stand-in that speaks the same multiplexed framed dialect."""

    def __init__(
        self,
        *,
        start_error: BaseException | None = None,
        identity: tuple[str, str] = ("mps", "float16"),
    ) -> None:
        self.sent: list[Mapping[str, object]] = []
        self._queues: dict[str, asyncio.Queue[dict[str, object]]] = {}
        self._ready = False
        self._alive = False
        self._closed = False
        self.mode_gate = AsrModeGate()
        self.identity: tuple[str, str] | None = None
        self._configured_identity = identity
        self._start_error = start_error
        self.send_error: BaseException | None = None
        self.unregister_calls: list[str] = []
        self.timeout_seconds = 5.0
        self.last_active = 0.0

    async def start(self) -> None:
        if self._start_error is not None:
            raise self._start_error
        self._ready = True
        self._alive = True
        self.identity = self._configured_identity

    @property
    def alive(self) -> bool:
        return self._alive

    @property
    def ready(self) -> bool:
        return self._ready

    async def send(
        self,
        payload: Mapping[str, object],
        binary_payload: bytes | None = None,
    ) -> None:
        frame = dict(payload)
        if binary_payload is not None:
            frame["_binary"] = binary_payload
        self.sent.append(frame)
        self.last_active += 1
        if self.send_error is not None and frame.get("type") == "cancel":
            raise self.send_error

    async def trim_memory(self) -> None:
        self.last_active += 1

    def register_session(self, session_id: str) -> asyncio.Queue[dict[str, object]]:
        queue: asyncio.Queue[dict[str, object]] = asyncio.Queue(maxsize=64)
        self._queues[session_id] = queue
        return queue

    def unregister_session(self, session_id: str) -> None:
        self.unregister_calls.append(session_id)
        self._queues.pop(session_id, None)

    async def close(self) -> None:
        self._closed = True
        self._ready = False
        self._alive = False
        self.identity = None

    def push(self, session_id: str, frame: dict[str, object]) -> None:
        self._queues[session_id].put_nowait(frame)
        self.last_active += 1


def test_streaming_facade_delegates_start_failure_to_shared_owner() -> None:
    fake = FakeStreamingWorker(
        start_error=RuntimeError(
            "worker_load_error; worker stderr tail:\n"
            "mlx.core: [Metal] failed to allocate model weights"
        )
    )
    worker = Qwen3StreamingWorker(object(), shared_owner=fake)  # type: ignore[arg-type]

    async def scenario() -> None:
        with pytest.raises(RuntimeError, match="worker_load_error") as exc_info:
            await worker.start()
        assert "failed to allocate" in str(exc_info.value)

    asyncio.run(scenario())


def test_streaming_facade_accepts_an_injected_shared_owner(tmp_path: Path) -> None:
    snapshot = tmp_path / "external-qwen3-streaming-snapshot"
    snapshot.mkdir()
    config = Qwen3StreamingBackendConfig(
        repository_root=tmp_path,
        python_executable=Path("/usr/bin/python3"),
        model_dir=snapshot,
        device="mps",
    )
    owner = object()

    facade = Qwen3StreamingWorker(config, shared_owner=owner)  # type: ignore[arg-type]

    assert facade.shared_owner is owner


def test_session_events_queue_is_bounded() -> None:
    session = Qwen3StreamingSession(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        language="zh",
        prompt="",
        session_id="sess_test",
    )

    assert session._events_queue.maxsize == 64  # type: ignore[attr-defined]


def test_session_open_forwards_window_and_generation_limits() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        session = Qwen3StreamingSession(
            worker=worker,  # type: ignore[arg-type]
            language="zh",
            prompt="prompt",
            session_id="sess_test",
            chunk_sec=1.25,
            left_context_sec=8.5,
            right_context_ms=320,
            max_new_tokens=128,
        )
        connect = asyncio.create_task(session.connect())
        await asyncio.sleep(0)
        worker.push(
            "sess_test",
            {"type": "session.opened", "session_id": "sess_test", "language": "zh"},
        )
        await connect
        opened = next(frame for frame in worker.sent if frame.get("type") == "session.open")
        assert opened["chunk_sec"] == 1.25
        assert opened["left_context_sec"] == 8.5
        assert opened["right_context_ms"] == 320
        assert opened["max_new_tokens"] == 128
        await session.close()

    asyncio.run(scenario())


def test_streaming_facade_delegates_session_routing_to_owner() -> None:
    async def scenario() -> None:
        owner = FakeStreamingWorker()
        worker = Qwen3StreamingWorker(object(), shared_owner=owner)  # type: ignore[arg-type]
        await worker.start()
        queue = worker.register_session("sess_a")
        before = worker.last_active
        owner.push(
            "sess_a",
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
        assert worker.shared_owner is owner
        await worker.close()

    asyncio.run(scenario())


def test_streaming_facade_exposes_owner_state() -> None:
    async def scenario() -> None:
        owner = FakeStreamingWorker()
        worker = Qwen3StreamingWorker(object(), shared_owner=owner)  # type: ignore[arg-type]
        await worker.start()
        assert worker.ready is True
        assert worker.alive is True
        assert worker.identity == ("mps", "float16")
        assert worker.mode_gate is owner.mode_gate
        await worker.trim_memory()
        await worker.close()
        assert worker.ready is False

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


def test_session_commit_propagates_want_segments_true() -> None:
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
        worker.push("sess_test", {"type": "finished", "session_id": "sess_test", "final": True})
        await asyncio.sleep(0)
        await session.commit(want_segments=True)
        commits = [f for f in worker.sent if f.get("type") == "commit"]
        assert commits and commits[-1].get("want_segments") is True
        await session.close()

    asyncio.run(scenario())


def test_session_commit_defaults_want_segments_false() -> None:
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
        worker.push("sess_test", {"type": "finished", "session_id": "sess_test", "final": True})
        await asyncio.sleep(0)
        await session.commit()
        commits = [f for f in worker.sent if f.get("type") == "commit"]
        assert commits and commits[-1].get("want_segments") is False
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
    assert "--worker-role" in cmd and cmd[cmd.index("--worker-role") + 1] == "streaming"


def test_backend_config_rejects_invalid_dtype_for_device(tmp_path: Path) -> None:
    """MPS must not silently accept float32, and CPU must reject float16."""
    snapshot = tmp_path / "external-qwen3-streaming-snapshot"
    snapshot.mkdir()

    with pytest.raises(ValueError, match="MPS requires"):
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=Path("/usr/bin/python3"),
            model_dir=snapshot,
            device="mps",
            dtype="float32",
        )
    with pytest.raises(ValueError, match="CPU requires"):
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=Path("/usr/bin/python3"),
            model_dir=snapshot,
            device="cpu",
            dtype="float16",
        )


def test_streaming_worker_rejects_ready_identity_mismatch(tmp_path: Path) -> None:
    """The worker must abort when the ready frame disagrees on device/dtype.

    Matches the batch worker's identity discipline: a streaming worker that loads
    a different backend than the config resolved must fail closed instead of
    silently running at the wrong precision.
    """
    snapshot = tmp_path.parent / "external-qwen3-streaming-identity-snapshot"
    snapshot.mkdir()
    fake = FakeStreamingWorker(start_error=RuntimeError("backend_identity_mismatch"))
    worker = Qwen3StreamingWorker(
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=Path("/usr/bin/python3"),
            model_dir=snapshot,
            device="mps",
            dtype="int8",
        ),
        shared_owner=fake,  # type: ignore[arg-type]
    )

    async def scenario() -> None:
        with pytest.raises(RuntimeError, match="backend_identity_mismatch"):
            await worker.start()

    asyncio.run(scenario())


def test_session_commit_times_out_when_worker_never_finishes() -> None:
    """A hung worker (no EOF, no error frame) must not park commit forever."""

    async def scenario() -> None:
        worker = FakeStreamingWorker()
        worker.timeout_seconds = 0.05
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

        with pytest.raises(TimeoutError):
            await session.commit()

        await session.close()

    asyncio.run(scenario())
