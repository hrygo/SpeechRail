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
    """In-memory worker stand-in that speaks the same framed dialect."""

    def __init__(self) -> None:
        self.sent: list[Mapping[str, object]] = []
        self._responses: list[dict[str, object]] = []
        self._ready = False
        self._closed = False

    async def start(self) -> None:
        self._ready = True

    async def send(self, payload: Mapping[str, object]) -> None:
        self.sent.append(payload)

    async def receive(self) -> dict[str, object]:
        if self._responses:
            return self._responses.pop(0)
        await asyncio.Event().wait()  # pragma: no cover - never reached
        return {"type": "never"}

    async def exchange(self, payload: Mapping[str, object]) -> dict[str, object]:
        self.sent.append(payload)
        return await self.receive()

    async def close(self) -> None:
        self._closed = True

    def push(self, frame: dict[str, object]) -> None:
        self._responses.append(frame)


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


def test_streaming_worker_refreshes_last_active_on_io(tmp_path: Path) -> None:
    """Active sessions must keep the worker out of the idle evictor: every
    frame received by the session's read loop refreshes last_active."""

    worker = Qwen3StreamingWorker(
        Qwen3StreamingBackendConfig(
            repository_root=tmp_path,
            python_executable=Path("/usr/bin/python3"),
            model_dir=tmp_path,
            device="mps",
        )
    )
    fake = _FakeTransport({"type": "session.opened"})
    worker._transport = fake  # type: ignore[assignment]

    async def scenario() -> None:
        before = worker.last_active
        await asyncio.sleep(0.01)
        await worker.receive()
        assert worker.last_active > before

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


def test_factory_enforces_single_active_session() -> None:
    factory = NativeRealtimeFactory(
        worker=FakeStreamingWorker(),  # type: ignore[arg-type]
        mode="windowed",
        next_session_id=lambda: "sess_test",
    )
    first = factory.create(language="zh", prompt="")
    with pytest.raises(RuntimeError, match="busy"):
        factory.create(language="en", prompt="")
    factory.release(first)
    second = factory.create(language="en", prompt="")
    assert second is not first
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
        worker.push({"type": "session.opened", "language": "zh"})
        await session.connect()
        assert any(frame.get("type") == "session.open" for frame in worker.sent)

        worker.push(
            {
                "type": "event",
                "kind": "completed",
                "text": "你好 世界",
                "segments": [
                    {"text": "你好", "start_ms": 0, "end_ms": 500},
                    {"text": "世界", "start_ms": 500, "end_ms": 1000},
                ],
            }
        )
        events: list[StreamingAsrEvent] = []
        task = asyncio.create_task(_collect(session, events, until=1))
        worker.push({"type": "finished", "final": True})
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
        worker.push({"type": "session.opened", "language": "zh"})
        await session.connect()
        worker.push({"type": "error", "code": "worker_inference_error"})
        events: list[StreamingAsrEvent] = []
        task = asyncio.create_task(_collect(session, events, until=1))
        await task
        assert events[0].kind == "error"
        assert events[0].error_code == "worker_inference_error"
        await session.close()

    asyncio.run(scenario())

