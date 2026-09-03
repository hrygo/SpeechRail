"""Unit tests for the unified Qwen3-ASR worker's local IPC boundary."""

from __future__ import annotations

from io import BytesIO
from pathlib import Path

import pytest

from speechrail.backends.qwen3_worker import serve
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, read_frame, write_frame


def test_serve_reports_worker_load_error_with_traceback_on_stderr(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A failing model load emits worker_load_error AND the real traceback on stderr."""

    def failing_factory(
        model_dir: Path, device: str, dtype: str, max_new_tokens: int
    ) -> object:
        del model_dir, device, dtype, max_new_tokens
        raise RuntimeError("boom-model-load")

    source = BytesIO()
    target = BytesIO()
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": "mps",
            "dtype": "float16",
        },
    )
    source.seek(0)

    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        dtype="float16",
        max_new_tokens=512,
        engine_factory=failing_factory,
    )

    target.seek(0)
    assert read_frame(target) == {
        "version": PROTOCOL_VERSION,
        "type": "error",
        "code": "worker_load_error",
    }
    assert "boom-model-load" in capsys.readouterr().err


class _FakeEngine:
    """Multi-session-capable engine stand-in for worker protocol contract tests."""

    def __init__(self, model_dir: Path, device: str, dtype: str, max_new_tokens: int) -> None:
        del model_dir, dtype, max_new_tokens
        self.identity = type("Identity", (), {"device": device, "dtype": "float16"})()
        self.sessions: dict[str, list[bytes]] = {}

    def transcribe(
        self,
        audio: bytes,
        *,
        language: str,
        prompt: str,
        include_timestamps: bool = False,
    ) -> tuple[str, str, list[dict[str, object]]]:
        del audio, language, prompt, include_timestamps
        return "ok", "zh", []

    def open_session(
        self,
        *,
        session_id: str,
        language: str,
        context: str,
        chunk_sec: float = 2.0,
        left_context_sec: float = 12.0,
        right_context_ms: int = 640,
        max_new_tokens: int = 256,
    ) -> None:
        del language, context, chunk_sec, left_context_sec, right_context_ms, max_new_tokens
        if session_id in self.sessions:
            raise RuntimeError(f"session already open: {session_id}")
        self.sessions[session_id] = []

    def append_audio(self, session_id: str, audio: bytes) -> str:
        if session_id not in self.sessions:
            raise RuntimeError(f"no active session: {session_id}")
        self.sessions[session_id].append(audio)
        return f"partial:{sum(len(x) for x in self.sessions[session_id])}"

    def partial_text(self, session_id: str) -> str:
        if session_id not in self.sessions:
            raise RuntimeError(f"no active session: {session_id}")
        return f"partial:{len(self.sessions[session_id])}"

    def finish_streaming(self, session_id: str) -> tuple[str, str]:
        if session_id not in self.sessions:
            raise RuntimeError(f"no active session: {session_id}")
        chunks = self.sessions.pop(session_id)
        return f"text:{len(chunks)}", "zh"

    def close_session(self, session_id: str) -> None:
        self.sessions.pop(session_id, None)

    def active_session_count(self) -> int:
        return len(self.sessions)

    def has_session(self, session_id: str) -> bool:
        return session_id in self.sessions


def _run_serve(
    frames: list[dict[str, object]],
    *,
    engine: _FakeEngine,
) -> list[dict[str, object]]:
    source = BytesIO()
    target = BytesIO()
    for frame in frames:
        write_frame(source, frame)
    source.seek(0)
    serve(
        source,
        target,
        model_dir=Path("/tmp"),
        device="mps",
        dtype="float16",
        max_new_tokens=512,
        engine_factory=lambda *args, **kwargs: engine,
    )
    target.seek(0)
    out: list[dict[str, object]] = []
    while True:
        frame = read_frame(target)
        if frame is None:
            return out
        out.append(frame)


def _start_frame() -> dict[str, object]:
    return {
        "version": PROTOCOL_VERSION,
        "type": "start",
        "model_dir": "/tmp",
        "device": "mps",
        "dtype": "float16",
    }


def test_worker_routes_and_isolates_concurrent_sessions() -> None:
    engine = _FakeEngine(Path("/tmp"), "mps", "float16", 512)
    frames = [
        _start_frame(),
        {"version": PROTOCOL_VERSION, "type": "session.open", "session_id": "a", "language": "zh"},
        {"version": PROTOCOL_VERSION, "type": "session.open", "session_id": "b", "language": "en"},
        {"version": PROTOCOL_VERSION, "type": "audio.append", "session_id": "a", "pcm_b64": "AAA="},
        {
            "version": PROTOCOL_VERSION,
            "type": "audio.append",
            "session_id": "b",
            "pcm_b64": "AAAAAA==",
        },
        {"version": PROTOCOL_VERSION, "type": "commit", "session_id": "a"},
        {"version": PROTOCOL_VERSION, "type": "commit", "session_id": "b"},
    ]
    responses = _run_serve(frames, engine=engine)
    opened = [f for f in responses if f.get("type") == "session.opened"]
    assert {f.get("session_id") for f in opened} == {"a", "b"}
    acked = [f for f in responses if f.get("type") == "audio.acked"]
    assert [f.get("session_id") for f in acked] == ["a", "b"]
    completed = [f for f in responses if f.get("type") == "event" and f.get("kind") == "completed"]
    assert [f.get("session_id") for f in completed] == ["a", "b"]
    assert [f.get("text") for f in completed] == ["text:1", "text:1"]
    finished = [f for f in responses if f.get("type") == "finished"]
    assert [f.get("session_id") for f in finished] == ["a", "b"]


def test_worker_commit_uses_only_that_sessions_audio() -> None:
    engine = _FakeEngine(Path("/tmp"), "mps", "float16", 512)
    frames = [
        _start_frame(),
        {"version": PROTOCOL_VERSION, "type": "session.open", "session_id": "a", "language": "zh"},
        {"version": PROTOCOL_VERSION, "type": "session.open", "session_id": "b", "language": "zh"},
        {
            "version": PROTOCOL_VERSION,
            "type": "audio.append",
            "session_id": "a",
            "pcm_b64": "AAA=",
        },
        {
            "version": PROTOCOL_VERSION,
            "type": "audio.append",
            "session_id": "a",
            "pcm_b64": "AAAAAA==",
        },
        {"version": PROTOCOL_VERSION, "type": "commit", "session_id": "a"},
    ]
    responses = _run_serve(frames, engine=engine)
    completed = [f for f in responses if f.get("type") == "event" and f.get("kind") == "completed"]
    assert completed and completed[0]["session_id"] == "a"
    assert completed[0]["text"] == "text:2"
    assert engine.active_session_count() == 1
    assert list(engine.sessions) == ["b"]


def test_worker_cancel_closes_only_that_session() -> None:
    engine = _FakeEngine(Path("/tmp"), "mps", "float16", 512)
    frames = [
        _start_frame(),
        {"version": PROTOCOL_VERSION, "type": "session.open", "session_id": "a", "language": "zh"},
        {"version": PROTOCOL_VERSION, "type": "session.open", "session_id": "b", "language": "zh"},
        {"version": PROTOCOL_VERSION, "type": "cancel", "session_id": "a"},
    ]
    responses = _run_serve(frames, engine=engine)
    assert not [f for f in responses if f.get("type") == "error"]
    assert engine.active_session_count() == 1
    assert list(engine.sessions) == ["b"]


def test_worker_errors_carry_session_id_when_known() -> None:
    engine = _FakeEngine(Path("/tmp"), "mps", "float16", 512)
    frames = [
        _start_frame(),
        {"version": PROTOCOL_VERSION, "type": "session.open", "session_id": "a", "language": "zh"},
        {"version": PROTOCOL_VERSION, "type": "flush", "session_id": "ghost"},
        {"version": PROTOCOL_VERSION, "type": "commit", "session_id": "ghost"},
    ]
    responses = _run_serve(frames, engine=engine)
    errors = [f for f in responses if f.get("type") == "error"]
    assert len(errors) == 2
    assert {f.get("code") for f in errors} == {"session_invalid"}
    assert {f.get("session_id") for f in errors} == {"ghost"}


def test_worker_rejects_unknown_session_audio() -> None:
    engine = _FakeEngine(Path("/tmp"), "mps", "float16", 512)
    frames = [
        _start_frame(),
        {
            "version": PROTOCOL_VERSION,
            "type": "audio.append",
            "session_id": "ghost",
            "pcm_b64": "AAA=",
        },
    ]
    responses = _run_serve(frames, engine=engine)
    errors = [f for f in responses if f.get("type") == "error"]
    assert errors and errors[0]["code"] == "session_invalid"
    assert errors[0]["session_id"] == "ghost"


def test_worker_trim_memory_does_not_emit_confirmation_frame() -> None:
    engine = _FakeEngine(Path("/tmp"), "mps", "float16", 512)
    transcribe = {
        "version": PROTOCOL_VERSION,
        "type": "transcribe",
        "request_id": "req_t1",
        "sample_rate": 16000,
        "channels": 1,
        "sample_width_bytes": 2,
        "language": "zh",
        "prompt": "",
        "include_timestamps": False,
        "pcm_b64": "AAA=",
    }
    frames = [
        _start_frame(),
        {"version": PROTOCOL_VERSION, "type": "trim_memory"},
        transcribe,
    ]
    responses = _run_serve(frames, engine=engine)

    # A fire-and-forget trim_memory must not write a confirmation frame, so the
    # next request reads back exactly its own result frame.
    assert not any(f.get("type") == "memory_trimmed" for f in responses)
    results = [f for f in responses if f.get("type") == "result"]
    assert len(results) == 1
    assert results[0]["request_id"] == "req_t1"
