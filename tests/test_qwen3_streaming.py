"""Tests for the native Qwen3 causal-streaming ASR backend adapter."""

from __future__ import annotations

import asyncio
from collections.abc import Mapping
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from speechrail.app import create_app
from speechrail.backends.qwen3_streaming import (
    NativeRealtimeFactory,
    Qwen3StreamingBackendConfig,
    Qwen3StreamingSession,
)
from speechrail.config import Settings
from speechrail.domain.ports import StreamingAsrEvent
from speechrail.realtime.v2_session import PCM16


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

    async def close(self) -> None:
        self._closed = True

    def push(self, frame: dict[str, object]) -> None:
        self._responses.append(frame)


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
        factory.create(language="fr", prompt="")


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


def test_v2_route_streams_native_completed_events_without_shape_change() -> None:
    """The v2 route consumes the native session exactly like the WLK one."""

    class SequencingWorker(FakeStreamingWorker):
        def __init__(self) -> None:
            super().__init__()
            self.opened = False
            self._wake = asyncio.Event()

        async def receive(self) -> dict[str, object]:
            if not self.opened:
                self.opened = True
                return {"type": "session.opened", "language": "zh"}
            while not self._responses:
                self._wake.clear()
                await self._wake.wait()
            return self._responses.pop(0)

        def push(self, frame: dict[str, object]) -> None:
            self._responses.append(frame)
            self._wake.set()

    worker = SequencingWorker()
    factory = NativeRealtimeFactory(
        worker=worker,  # type: ignore[arg-type]
        mode="windowed",
        next_session_id=lambda: "sess_test",
    )
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            realtime_asr_factory=factory,
        )
    )
    with client.websocket_connect("/v2/realtime") as socket:
        socket.send_json(
            {
                "type": "session.update",
                "session": {
                    "type": "transcription",
                    "language": "zh",
                    "audio_format": PCM16,
                    "endpointing": {"mode": "manual"},
                },
            }
        )
        assert socket.receive_json()["type"] == "session.created"
        socket.send_json(
            {
                "type": "input_audio_buffer.append",
                "audio": _pcm16(b"\x00\x00"),
            }
        )
        assert socket.receive_json()["type"] == "input_audio_buffer.ack"
        worker.push(
            {
                "type": "event",
                "kind": "completed",
                "text": "正在 讲话",
                "segments": [
                    {"text": "正在", "start_ms": 0, "end_ms": 500},
                    {"text": "讲话", "start_ms": 500, "end_ms": 1000},
                ],
            }
        )
        worker.push({"type": "finished", "final": True})
        socket.send_json({"type": "input_audio_buffer.commit"})
        completed = socket.receive_json()
        terminal = socket.receive_json()
        assert completed["type"] == "transcription.completed"
        assert completed["text"] == "正在 讲话"
        assert completed["segments"][0]["text"] == "正在"
        assert terminal["type"] == "session.completed"


def _pcm16(value: bytes) -> str:
    import base64

    return base64.b64encode(value).decode("ascii")
