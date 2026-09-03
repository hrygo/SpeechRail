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


def test_clear_metal_cache_prefers_new_mlx_api(monkeypatch: pytest.MonkeyPatch) -> None:
    """Regression: ``_clear_metal_cache`` must call the non-deprecated ``mx.clear_cache``.

    When both ``mx.metal.clear_cache`` (deprecated) and ``mx.clear_cache`` exist,
    the cleanup must prefer the modern module-level API. The previous ordering
    checked ``mx.metal.clear_cache`` first, so on MLX versions where that symbol
    still exists (but is deprecated) the effective ``mx.clear_cache`` was never
    reached and the Metal cache stayed resident.
    """
    import sys
    from types import ModuleType, SimpleNamespace

    from speechrail.backends.qwen3_worker import _clear_metal_cache

    calls: list[str] = []
    metal = SimpleNamespace(clear_cache=lambda: calls.append("metal.clear_cache"))
    mx = SimpleNamespace(
        metal=metal,
        clear_cache=lambda: calls.append("mx.clear_cache"),
    )
    # Register both the top-level ``mlx`` package and ``mlx.core`` so that the
    # function's ``import mlx.core`` resolves to the fake (the project venv has
    # no real MLX installed for these regression unit tests).
    mlx_pkg = ModuleType("mlx")
    mlx_pkg.core = mx
    monkeypatch.setitem(sys.modules, "mlx", mlx_pkg)
    monkeypatch.setitem(sys.modules, "mlx.core", mx)

    _clear_metal_cache()

    assert "mx.clear_cache" in calls
    assert "metal.clear_cache" not in calls


def test_dynamic_budget_grows_sublinearly_and_is_bounded() -> None:
    """The batch decode budget must grow sub-linearly with audio length.

    A per-second linear multiplier (``* 8``) pushes the budget toward the hard cap
    on very long inputs, letting the decoder run away for a large tail that adds
    little transcription value. The helper must keep a floor for short audio,
    grow conservatively, and respect the configured ``max_new_tokens`` cap.
    """
    from speechrail.backends.qwen3_worker import _dynamic_budget

    # Floor: short audio stays transcribable.
    assert _dynamic_budget(3.3, 512) >= 32
    assert _dynamic_budget(0.0, 512) >= 32

    # Mid audio: no runaway, but strictly less than the linear legacy budget.
    assert _dynamic_budget(8.5, 512) < 128
    assert _dynamic_budget(8.5, 512) < int(8.5 * 8) + 16

    # Long audio: sub-linear (not ~8x seconds), yet with headroom for the text.
    assert _dynamic_budget(31.4, 512) < int(31.4 * 8) + 16
    assert _dynamic_budget(31.4, 512) >= 120
    assert _dynamic_budget(31.4, 512) > _dynamic_budget(8.5, 512)

    # Monotonic growth and hard cap honored.
    assert _dynamic_budget(60.0, 512) >= _dynamic_budget(31.4, 512)
    assert _dynamic_budget(999999.0, 256) == 256
    assert _dynamic_budget(999999.0, 512) == 512

    # A falsy cap falls back to the default ceiling.
    assert _dynamic_budget(999999.0, 0) == 512


def test_snapshot_is_quantized_detects_config_quantization(tmp_path: Path) -> None:
    from speechrail.backends.qwen3_native import snapshot_is_quantized

    snapshot = tmp_path / "quantized"
    snapshot.mkdir()
    (snapshot / "config.json").write_text(
        '{"quantization": {"bits": 8, "group_size": 64, "mode": "affine"}}',
        encoding="utf-8",
    )
    assert snapshot_is_quantized(snapshot) is True

    (snapshot / "config.json").write_text("{}", encoding="utf-8")
    assert snapshot_is_quantized(snapshot) is False

    malformed = tmp_path / "malformed"
    malformed.mkdir()
    (malformed / "config.json").write_text("{not json", encoding="utf-8")
    assert snapshot_is_quantized(malformed) is False
