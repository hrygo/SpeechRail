"""Tests for the native Qwen3 causal-streaming ASR backend adapter."""

from __future__ import annotations

import asyncio
from collections.abc import Mapping
from pathlib import Path
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from speechrail.backends.qwen3_streaming import (
    NativeRealtimeFactory,
    Qwen3StreamingBackendConfig,
    Qwen3StreamingSession,
    Qwen3StreamingWorker,
    RealtimeSessionLimitError,
)
from speechrail.config import Settings
from speechrail.domain.ports import RealtimeTranscriptionOptions, StreamingAsrEvent
from speechrail.runtime.asr_mode import AsrModeGate, AsrModeScheduler
from speechrail.runtime.busy import BusyReason


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
        self.session_registered = asyncio.Event()
        self.commit_sent = asyncio.Event()
        self.close_started = asyncio.Event()
        self.close_attempted = asyncio.Event()
        self.close_gate: asyncio.Event | None = None
        self.close_error: BaseException | None = None
        self.close_calls = 0
        self._ready = False
        self._alive = False
        self._closed = False
        self.mode_gate = AsrModeGate()
        self.mode_scheduler = AsrModeScheduler(
            self.mode_gate,
            batch_aging_seconds=0.05,
        )
        self.identity: tuple[str, str] | None = None
        self._configured_identity = identity
        self._start_error = start_error
        self.send_error: BaseException | None = None
        self.unregister_calls: list[str] = []
        self.unregister_failures_remaining = 0
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
        if frame.get("type") == "commit":
            self.commit_sent.set()
        elif frame.get("type") == "flush":
            session_id = frame.get("session_id")
            if isinstance(session_id, str):
                self.push(
                    session_id,
                    {"type": "flushed", "session_id": session_id},
                )
        if self.send_error is not None and frame.get("type") == "cancel":
            raise self.send_error

    async def trim_memory(self) -> None:
        self.last_active += 1

    def register_session(self, session_id: str) -> asyncio.Queue[dict[str, object]]:
        queue: asyncio.Queue[dict[str, object]] = asyncio.Queue(maxsize=64)
        self._queues[session_id] = queue
        self.session_registered.set()
        return queue

    def unregister_session(self, session_id: str) -> None:
        self.unregister_calls.append(session_id)
        if self.unregister_failures_remaining:
            self.unregister_failures_remaining -= 1
            raise RuntimeError("fake unregister failure")
        self._queues.pop(session_id, None)

    async def close(self) -> None:
        self.close_calls += 1
        self.close_started.set()
        self.close_attempted.set()
        if self.close_gate is not None:
            await self.close_gate.wait()
        if self.close_error is not None:
            raise self.close_error
        self._closed = True
        self._ready = False
        self._alive = False
        self.identity = None

    def push(self, session_id: str, frame: dict[str, object]) -> None:
        self._queues[session_id].put_nowait(frame)
        self.last_active += 1


class FailOnceStreamingContext:
    def __init__(self, gate: AsrModeGate, *, fail_exit_once: bool = False) -> None:
        self._gate = gate
        self._fail_exit_once = fail_exit_once
        self._lease = None
        self.exit_calls = 0

    async def __aenter__(self) -> None:
        self._lease = self._gate.acquire("streaming")

    async def __aexit__(self, *_: object) -> bool:
        self.exit_calls += 1
        if self._fail_exit_once and self.exit_calls == 1:
            raise RuntimeError("fake context exit failure")
        assert self._lease is not None
        self._gate.release(self._lease)
        return False


class FixedStreamingScheduler:
    def __init__(self, context: FailOnceStreamingContext) -> None:
        self._context = context

    def streaming(self) -> FailOnceStreamingContext:
        return self._context


class FailOnceModeGate:
    def __init__(self) -> None:
        self._gate = AsrModeGate()
        self.release_calls = 0

    @property
    def active_mode(self) -> str | None:
        return self._gate.active_mode

    def acquire(self, mode: str) -> object:
        return self._gate.acquire(mode)  # type: ignore[arg-type]

    def release(self, lease: object) -> None:
        self.release_calls += 1
        if self.release_calls == 1:
            raise RuntimeError("fake mode gate release failure")
        self._gate.release(lease)  # type: ignore[arg-type]


def _factory_session(
    worker: FakeStreamingWorker, session_id: str
) -> tuple[NativeRealtimeFactory, Qwen3StreamingSession]:
    factory = NativeRealtimeFactory(
        worker=worker,  # type: ignore[arg-type]
        next_session_id=lambda: session_id,
        max_sessions=1,
    )
    session = factory.create(
        language="zh",
        prompt="",
        options=RealtimeTranscriptionOptions(),
    )
    return factory, session


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


def test_session_open_forwards_task_streaming_policy() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        session = Qwen3StreamingSession(
            worker=worker,  # type: ignore[arg-type]
            language="zh",
            prompt="prompt",
            session_id="sess_test",
            chunk_duration_ms=500,
            max_context_sec=8.82,
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
        assert opened["chunk_duration_ms"] == 500
        assert opened["max_context_sec"] == 8.82
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


def test_backend_config_rejects_non_positive_max_context(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="max_context_sec"):
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=Path("/usr/bin/python3"),
            model_dir=tmp_path,
            device="mps",
            max_context_sec=0.0,
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


def test_settings_defaults_to_disabled_with_one_second_chunks() -> None:
    settings = Settings()
    assert settings.realtime_asr_backend == "disabled"
    assert settings.qwen3_streaming_chunk_duration_ms == 1_000
    assert settings.realtime_max_sessions == 3


def test_settings_rejects_unevaluated_chunk_duration() -> None:
    with pytest.raises(ValidationError, match="qwen3_streaming_chunk_duration_ms"):
        Settings(qwen3_streaming_chunk_duration_ms=750, _env_file=None)  # type: ignore[call-arg]


def test_settings_rejects_out_of_range_max_sessions() -> None:
    with pytest.raises(ValidationError, match="realtime_max_sessions"):
        Settings(realtime_max_sessions=0, _env_file=None)  # type: ignore[call-arg]
    with pytest.raises(ValidationError, match="realtime_max_sessions"):
        Settings(realtime_max_sessions=9, _env_file=None)  # type: ignore[call-arg]


def test_factory_applies_per_session_chunk_duration() -> None:
    factory = NativeRealtimeFactory(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        next_session_id=lambda: "sess_test",
    )
    session = factory.create(
        language="zh",
        prompt="",
        options=RealtimeTranscriptionOptions(partial_mode="snapshot", chunk_duration_ms=500),
    )
    assert session._chunk_duration_ms == 500  # type: ignore[attr-defined]
    factory.release(session)


def test_factory_applies_owner_max_context() -> None:
    worker = FakeStreamingWorker()
    worker.config = SimpleNamespace(max_context_sec=6.5, max_new_tokens=96)  # type: ignore[attr-defined]
    factory = NativeRealtimeFactory(
        worker=worker,  # type: ignore[arg-type]
        next_session_id=lambda: "sess_test",
    )
    session = factory.create(language="zh", prompt="", options=RealtimeTranscriptionOptions())
    assert session._max_context_sec == 6.5  # type: ignore[attr-defined]
    assert session._max_new_tokens == 96  # type: ignore[attr-defined]
    factory.release(session)


def test_factory_accepts_any_supported_language() -> None:
    factory = NativeRealtimeFactory(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        next_session_id=lambda: "sess_test",
    )
    assert (
        factory.create(language="zh", prompt="", options=RealtimeTranscriptionOptions())
        is not None
    )


def test_factory_rejects_unsupported_language() -> None:
    factory = NativeRealtimeFactory(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        next_session_id=lambda: "sess_test",
    )
    with pytest.raises(RuntimeError, match="language_not_supported"):
        factory.create(language="sw", prompt="", options=RealtimeTranscriptionOptions())


def test_factory_enforces_max_sessions_cap() -> None:
    worker = FakeStreamingWorker()
    factory = NativeRealtimeFactory(
        worker=worker,  # type: ignore[arg-type]
        next_session_id=iter(["s1", "s2", "s3"]).__next__,
        max_sessions=2,
    )
    first = factory.create(language="zh", prompt="", options=RealtimeTranscriptionOptions())
    second = factory.create(language="en", prompt="", options=RealtimeTranscriptionOptions())
    with pytest.raises(RealtimeSessionLimitError) as caught:
        factory.create(language="en", prompt="", options=RealtimeTranscriptionOptions())
    assert caught.value.busy_reason == BusyReason.REALTIME_SESSION_LIMIT
    factory.release(first)
    third = factory.create(language="en", prompt="", options=RealtimeTranscriptionOptions())
    assert third is not first and third is not second
    factory.release(second)
    factory.release(third)


def test_factory_generates_distinct_sessions_by_session_id() -> None:
    factory = NativeRealtimeFactory(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        next_session_id=iter(["s1", "s2"]).__next__,
        max_sessions=2,
    )
    first = factory.create(language="zh", prompt="", options=RealtimeTranscriptionOptions())
    second = factory.create(language="zh", prompt="", options=RealtimeTranscriptionOptions())
    assert first.session_id == "s1"
    assert second.session_id == "s2"
    factory.release(first)
    factory.release(second)


def test_factory_session_limit_has_stable_busy_reason() -> None:
    factory = NativeRealtimeFactory(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        next_session_id=iter(["s1", "s2"]).__next__,
        max_sessions=1,
    )
    first = factory.create(language="zh", prompt="", options=RealtimeTranscriptionOptions())
    with pytest.raises(RealtimeSessionLimitError) as caught:
        factory.create(language="zh", prompt="", options=RealtimeTranscriptionOptions())
    assert caught.value.busy_reason == BusyReason.REALTIME_SESSION_LIMIT
    assert caught.value.retryable is True
    factory.release(first)


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


def test_session_flush_waits_until_worker_acknowledges() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        session = Qwen3StreamingSession(
            worker=worker,  # type: ignore[arg-type]
            language="zh",
            prompt="",
            session_id="flush-ack",
        )
        connect = asyncio.create_task(session.connect())
        await worker.session_registered.wait()
        worker.push(
            "flush-ack",
            {"type": "session.opened", "session_id": "flush-ack", "language": "zh"},
        )
        await connect

        await session.flush()

        assert any(frame.get("type") == "flush" for frame in worker.sent)
        await session.close()

    asyncio.run(scenario())


@pytest.mark.parametrize("transcript", ["", "   "])
def test_empty_completed_is_success_and_finished_only_releases_reader(
    transcript: str,
) -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        session = Qwen3StreamingSession(
            worker=worker,  # type: ignore[arg-type]
            language="zh",
            prompt="",
            session_id="empty-final",
        )
        connect = asyncio.create_task(session.connect())
        await worker.session_registered.wait()
        worker.push(
            "empty-final",
            {"type": "session.opened", "session_id": "empty-final", "language": "zh"},
        )
        await connect

        events = session.events()
        next_event = asyncio.create_task(anext(events))
        worker.push(
            "empty-final",
            {
                "type": "event",
                "session_id": "empty-final",
                "kind": "completed",
                "text": transcript,
            },
        )
        completed = await asyncio.wait_for(next_event, timeout=1)
        assert completed.kind == "completed"
        assert completed.text == transcript

        finalizer_started = asyncio.Event()

        async def wait_for_finalized() -> None:
            finalizer_started.set()
            await session.wait_finalized()

        finalizer = asyncio.create_task(wait_for_finalized())
        await finalizer_started.wait()
        assert not finalizer.done()
        assert worker.mode_gate.active_mode == "streaming"

        next_event = asyncio.create_task(anext(events))
        worker.push("empty-final", {"type": "finished", "session_id": "empty-final"})
        with pytest.raises(StopAsyncIteration):
            await asyncio.wait_for(next_event, timeout=1)
        await asyncio.wait_for(finalizer, timeout=1)
        assert worker.unregister_calls == ["empty-final"]
        assert worker.mode_gate.active_mode is None
        await session.close()

    asyncio.run(scenario())


def test_reader_eof_error_does_not_create_success_terminal_and_releases_lease() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        worker.close_gate = asyncio.Event()
        session = Qwen3StreamingSession(
            worker=worker,  # type: ignore[arg-type],
            language="zh",
            prompt="",
            session_id="eof-final",
        )
        connect = asyncio.create_task(session.connect())
        await worker.session_registered.wait()
        worker.push(
            "eof-final",
            {"type": "session.opened", "session_id": "eof-final", "language": "zh"},
        )
        await connect

        events: list[StreamingAsrEvent] = []
        collect = asyncio.create_task(_collect(session, events, until=1))
        commit = asyncio.create_task(session.commit())
        await worker.commit_sent.wait()
        # Qwen3SharedWorker maps a transport EOF to this terminal error frame.
        worker.push(
            "eof-final",
            {"type": "error", "session_id": "eof-final", "code": "worker_unavailable"},
        )

        await asyncio.wait_for(worker.close_started.wait(), timeout=1)
        assert not commit.done()
        assert worker.unregister_calls == []
        assert worker.mode_gate.active_mode == "streaming"
        await asyncio.wait_for(collect, timeout=1)
        assert len(events) == 1
        assert events[0].kind == "error"
        assert events[0].error_code == "worker_unavailable"
        worker.close_gate.set()
        await asyncio.wait_for(commit, timeout=1)
        assert worker.close_calls == 1
        assert worker.unregister_calls == ["eof-final"]
        assert worker.mode_gate.active_mode is None
        await session.close()
        assert worker.close_calls == 1
        assert worker.unregister_calls == ["eof-final"]

    asyncio.run(scenario())


def test_failed_worker_reap_keeps_streaming_lease_until_retry_succeeds() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        worker.close_error = RuntimeError("fake reap failure")
        session = Qwen3StreamingSession(
            worker=worker,  # type: ignore[arg-type]
            language="zh",
            prompt="",
            session_id="reap-retry",
        )
        connect = asyncio.create_task(session.connect())
        await worker.session_registered.wait()
        worker.push(
            "reap-retry",
            {"type": "session.opened", "session_id": "reap-retry", "language": "zh"},
        )
        await connect

        events = session.events()
        next_event = asyncio.create_task(anext(events))
        worker.push(
            "reap-retry",
            {"type": "error", "session_id": "reap-retry", "code": "worker_unavailable"},
        )
        event = await asyncio.wait_for(next_event, timeout=1)
        assert event.kind == "error"

        while worker.close_calls < 2:
            worker.close_attempted.clear()
            if worker.close_calls < 2:
                await asyncio.wait_for(worker.close_attempted.wait(), timeout=1)
        assert worker.unregister_calls == []
        assert worker.mode_gate.active_mode == "streaming"

        worker.close_error = None
        await session.close()

        assert worker.close_calls == 3
        assert worker.unregister_calls == ["reap-retry"]
        assert worker.mode_gate.active_mode is None

    asyncio.run(scenario())


def test_finalize_retries_unregister_failure_without_repeating_reap() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        worker.unregister_failures_remaining = 1
        context = FailOnceStreamingContext(worker.mode_gate)
        worker.mode_scheduler = FixedStreamingScheduler(context)  # type: ignore[assignment]
        factory, session = _factory_session(worker, "unregister-retry")
        connect = asyncio.create_task(session.connect())
        await worker.session_registered.wait()
        worker.push(
            "unregister-retry",
            {"type": "session.opened", "session_id": "unregister-retry", "language": "zh"},
        )
        await connect

        with pytest.raises(RuntimeError, match="fake unregister failure"):
            await session.close()

        assert not session._finalized
        assert not session._finished.is_set()
        assert session._queue is not None
        assert "unregister-retry" in worker._queues
        assert context.exit_calls == 0
        assert worker.close_calls == 1
        assert worker.unregister_calls == ["unregister-retry"]
        assert worker.mode_gate.active_mode == "streaming"
        with pytest.raises(RealtimeSessionLimitError):
            factory.create(
                language="zh",
                prompt="",
                options=RealtimeTranscriptionOptions(),
            )

        await session.close()

        assert session._finalized
        assert session._finished.is_set()
        assert "unregister-retry" not in worker._queues
        assert context.exit_calls == 1
        assert worker.close_calls == 1
        assert worker.unregister_calls == ["unregister-retry", "unregister-retry"]
        assert worker.mode_gate.active_mode is None
        factory.release(session)
        replacement = factory.create(
            language="zh",
            prompt="",
            options=RealtimeTranscriptionOptions(),
        )
        factory.release(replacement)

    asyncio.run(scenario())


def test_finalize_retries_context_exit_failure_without_repeating_unregister() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        context = FailOnceStreamingContext(worker.mode_gate, fail_exit_once=True)
        worker.mode_scheduler = FixedStreamingScheduler(context)  # type: ignore[assignment]
        factory, session = _factory_session(worker, "context-retry")
        connect = asyncio.create_task(session.connect())
        await worker.session_registered.wait()
        worker.push(
            "context-retry",
            {"type": "session.opened", "session_id": "context-retry", "language": "zh"},
        )
        await connect

        with pytest.raises(RuntimeError, match="fake context exit failure"):
            await session.close()

        assert not session._finalized
        assert not session._finished.is_set()
        assert session._mode_context is context
        assert "context-retry" not in worker._queues
        assert context.exit_calls == 1
        assert worker.close_calls == 1
        assert worker.unregister_calls == ["context-retry"]
        assert worker.mode_gate.active_mode == "streaming"
        with pytest.raises(RealtimeSessionLimitError):
            factory.create(
                language="zh",
                prompt="",
                options=RealtimeTranscriptionOptions(),
            )

        await session.close()

        assert session._finalized
        assert session._finished.is_set()
        assert context.exit_calls == 2
        assert worker.close_calls == 1
        assert worker.unregister_calls == ["context-retry"]
        assert worker.mode_gate.active_mode is None
        factory.release(session)
        replacement = factory.create(
            language="zh",
            prompt="",
            options=RealtimeTranscriptionOptions(),
        )
        factory.release(replacement)

    asyncio.run(scenario())


def test_finalize_retries_mode_gate_release_failure_without_repeating_unregister() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        gate = FailOnceModeGate()
        worker.mode_gate = gate  # type: ignore[assignment]
        worker.mode_scheduler = None
        factory, session = _factory_session(worker, "mode-release-retry")
        connect = asyncio.create_task(session.connect())
        await worker.session_registered.wait()
        worker.push(
            "mode-release-retry",
            {
                "type": "session.opened",
                "session_id": "mode-release-retry",
                "language": "zh",
            },
        )
        await connect

        with pytest.raises(RuntimeError, match="fake mode gate release failure"):
            await session.close()

        assert not session._finalized
        assert not session._finished.is_set()
        assert session._mode_lease is not None
        assert "mode-release-retry" not in worker._queues
        assert gate.release_calls == 1
        assert worker.close_calls == 1
        assert worker.unregister_calls == ["mode-release-retry"]
        assert gate.active_mode == "streaming"
        with pytest.raises(RealtimeSessionLimitError):
            factory.create(
                language="zh",
                prompt="",
                options=RealtimeTranscriptionOptions(),
            )

        await session.close()

        assert session._finalized
        assert session._finished.is_set()
        assert gate.release_calls == 2
        assert worker.close_calls == 1
        assert worker.unregister_calls == ["mode-release-retry"]
        assert gate.active_mode is None
        factory.release(session)
        replacement = factory.create(
            language="zh",
            prompt="",
            options=RealtimeTranscriptionOptions(),
        )
        factory.release(replacement)

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


def test_wait_finalized_waits_for_terminal_cleanup_and_releases_streaming_lease() -> None:
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
            {
                "type": "event",
                "session_id": "sess_test",
                "kind": "completed",
                "text": "你好",
            },
        )
        await asyncio.sleep(0)
        waiter = asyncio.create_task(session.wait_finalized())
        await asyncio.sleep(0)
        assert not waiter.done()
        assert worker.mode_gate.active_mode == "streaming"

        worker.push("sess_test", {"type": "finished", "session_id": "sess_test"})
        await asyncio.wait_for(waiter, timeout=1)
        assert worker.mode_gate.active_mode is None
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


def test_session_logs_worker_stderr_tail_without_widening_the_error_code(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """The Realtime ``error.code`` stays a short stable code, but the operator
    log must carry the worker stderr tail that explains the failure."""

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
            {
                "type": "error",
                "session_id": "sess_test",
                "code": "worker_inference_error",
                "stderr_tail": "LocalEntryNotFoundError: no cached snapshot",
            },
        )
        events: list[StreamingAsrEvent] = []
        task = asyncio.create_task(_collect(session, events, until=1))
        await task
        assert events[0].kind == "error"
        assert events[0].error_code == "worker_inference_error"
        await session.close()

    with caplog.at_level("ERROR", logger="speechrail.backends.qwen3_streaming"):
        asyncio.run(scenario())

    assert "LocalEntryNotFoundError: no cached snapshot" in caplog.text
    assert "worker_inference_error" in caplog.text


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
        worker.close_gate = asyncio.Event()
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

        close = asyncio.create_task(session.close())
        await asyncio.wait_for(worker.close_started.wait(), timeout=1)
        assert not close.done()
        assert worker.unregister_calls == []
        assert worker.mode_gate.active_mode == "streaming"
        worker.close_gate.set()
        await asyncio.wait_for(close, timeout=1)
        assert worker.close_calls == 1
        assert worker.unregister_calls == ["sess_test"]
        assert worker.mode_gate.active_mode is None

    asyncio.run(scenario())


@pytest.mark.parametrize("queued", [0, 62, 63, 64])
def test_worker_error_always_delivers_its_cause_and_ends_iterator(queued: int) -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        session = Qwen3StreamingSession(
            worker=worker, language="zh", prompt="", session_id="error-boundary"
        )
        connect = asyncio.create_task(session.connect())
        await asyncio.sleep(0)
        worker.push(session.session_id, {"type": "session.opened"})
        await connect
        for _ in range(queued):
            session._events_queue.put_nowait(StreamingAsrEvent(kind="partial", text="x"))
        worker.push(session.session_id, {"type": "error", "code": "worker_inference_error"})
        await asyncio.wait_for(session.wait_finalized(), 1)
        events = [event async for event in session.events()]
        assert events[-1].error_code == "worker_inference_error"
        assert sum(event.kind == "error" for event in events) == 1
        assert worker.mode_gate.active_mode is None
        await session.close()
        assert worker.unregister_calls == [session.session_id]

    asyncio.run(scenario())


def test_reader_validation_failure_waits_for_actual_reap_before_finalized() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        worker.close_gate = asyncio.Event()
        session = Qwen3StreamingSession(
            worker=worker, language="zh", prompt="", session_id="invalid-watermark"
        )
        connect = asyncio.create_task(session.connect())
        await asyncio.wait_for(worker.session_registered.wait(), 1)
        worker.push(session.session_id, {"type": "session.opened"})
        await connect
        worker.push(session.session_id, {
            "type": "event", "kind": "partial", "sample_watermark": -1,
        })
        await asyncio.wait_for(worker.close_started.wait(), 1)
        waiter = asyncio.create_task(session.wait_finalized())
        try:
            events = [event async for event in session.events()]
            assert len(events) == 1
            assert events[0].error_code == "worker_unavailable"
            assert worker.mode_gate.active_mode == "streaming"
            assert worker.unregister_calls == []
            with pytest.raises(TimeoutError):
                await asyncio.wait_for(asyncio.shield(waiter), 0.05)
        finally:
            worker.close_gate.set()
            await session.close()
            await asyncio.wait_for(waiter, 1)
        assert worker._closed
        assert worker.mode_gate.active_mode is None
        assert worker.unregister_calls == [session.session_id]

    asyncio.run(scenario())


@pytest.mark.parametrize("cancel_error", [False, True])
def test_close_ends_parked_event_consumer_even_when_cancel_send_fails(cancel_error: bool) -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        session = Qwen3StreamingSession(
            worker=worker, language="zh", prompt="", session_id="close-boundary"
        )
        connect = asyncio.create_task(session.connect())
        await asyncio.sleep(0)
        worker.push(session.session_id, {"type": "session.opened"})
        await connect
        async def collect() -> list[StreamingAsrEvent]:
            return [event async for event in session.events()]
        consumer = asyncio.create_task(collect())
        await asyncio.sleep(0)
        if cancel_error:
            worker.send_error = RuntimeError("cancel failed")
        await session.close()
        await session.wait_finalized()
        assert await asyncio.wait_for(consumer, 0.2) == []
        assert worker.mode_gate.active_mode is None
        assert worker.unregister_calls == [session.session_id]
        assert worker.close_calls == 1
        assert worker._closed

    asyncio.run(scenario())


def test_failed_reap_propagates_and_keeps_lease_until_retry_succeeds() -> None:
    async def scenario() -> None:
        worker = FakeStreamingWorker()
        worker.send_error = RuntimeError("cancel failed")
        worker.close_error = RuntimeError("reap failed")
        session = Qwen3StreamingSession(
            worker=worker, language="zh", prompt="", session_id="reap-required"
        )
        connect = asyncio.create_task(session.connect())
        await asyncio.sleep(0)
        worker.push(session.session_id, {"type": "session.opened"})
        await connect

        async def collect() -> list[StreamingAsrEvent]:
            return [event async for event in session.events()]

        consumer = asyncio.create_task(collect())
        await asyncio.sleep(0)

        with pytest.raises(RuntimeError, match="reap failed"):
            await session.close()

        assert await asyncio.wait_for(consumer, 0.2) == []
        assert worker.mode_gate.active_mode == "streaming"
        assert worker.unregister_calls == []
        assert not session._finished.is_set()

        worker.close_error = None
        await session.close()
        await session.wait_finalized()

        assert worker.close_calls == 2
        assert worker.unregister_calls == [session.session_id]
        assert worker.mode_gate.active_mode is None
        assert worker._closed

    asyncio.run(scenario())
