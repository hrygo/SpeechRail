"""Regression tests for Qwen3 worker session and startup error isolation."""

from __future__ import annotations

from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import pytest

from speechrail.backends.qwen3_worker import serve
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, read_frame, write_frame


class _IsolationEngine:
    """Small in-memory engine that keeps session resources visible to tests."""

    def __init__(
        self,
        model_dir: Path,
        device: str,
        dtype: str,
        max_new_tokens: int,
        *,
        fail_finish: set[str] | None = None,
        fail_align: set[str] | None = None,
        empty_text: set[str] | None = None,
    ) -> None:
        del model_dir, max_new_tokens
        self.identity = SimpleNamespace(device=device, dtype=dtype)
        self.sessions: dict[str, list[bytes]] = {}
        self.align_buffers: dict[str, bytearray] = {}
        self.open_args: dict[str, tuple[float, float, int, int]] = {}
        self.close_calls: list[str] = []
        self.fail_finish = fail_finish or set()
        self.fail_align = fail_align or set()
        self.empty_text = empty_text or set()

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
        del language, context
        if session_id in self.sessions:
            raise RuntimeError(f"session already open: {session_id}")
        self.sessions[session_id] = []
        self.align_buffers[session_id] = bytearray()
        self.open_args[session_id] = (
            chunk_sec,
            left_context_sec,
            right_context_ms,
            max_new_tokens,
        )

    def append_audio(self, session_id: str, audio: bytes) -> str:
        if session_id not in self.sessions:
            raise RuntimeError(f"no active session: {session_id}")
        self.sessions[session_id].append(audio)
        self.align_buffers[session_id].extend(audio)
        return f"partial:{len(self.sessions[session_id])}"

    def partial_text(self, session_id: str) -> str:
        if session_id not in self.sessions:
            raise RuntimeError(f"no active session: {session_id}")
        return f"partial:{len(self.sessions[session_id])}"

    def finish_streaming(self, session_id: str) -> tuple[str, str]:
        if session_id not in self.sessions:
            raise RuntimeError(f"no active session: {session_id}")
        if session_id in self.fail_finish:
            raise RuntimeError(f"finish failed: {session_id}")
        if session_id in self.empty_text:
            return "", "zh"
        return f"text:{len(self.sessions[session_id])}", "zh"

    def align_session_audio(self, session_id: str) -> list[dict[str, object]]:
        if session_id in self.fail_align:
            raise RuntimeError(f"alignment failed: {session_id}")
        return [{"text": "aligned", "start_ms": 0, "end_ms": 20}]

    def close_session(self, session_id: str) -> None:
        self.close_calls.append(session_id)
        self.sessions.pop(session_id, None)
        self.align_buffers.pop(session_id, None)

    def active_session_count(self) -> int:
        return len(self.sessions)

    def has_session(self, session_id: str) -> bool:
        return session_id in self.sessions


def _start_frame() -> dict[str, object]:
    return {
        "version": PROTOCOL_VERSION,
        "type": "start",
        "model_dir": "/tmp",
        "device": "mps",
        "dtype": "float16",
    }


def _run_serve(
    frames: list[dict[str, object]], engine: _IsolationEngine
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
    responses: list[dict[str, object]] = []
    while True:
        frame = read_frame(target)
        if frame is None:
            return responses
        responses.append(frame)


def _open_frame(session_id: str, **options: object) -> dict[str, object]:
    return {
        "version": PROTOCOL_VERSION,
        "type": "session.open",
        "session_id": session_id,
        "language": "zh",
        **options,
    }


def _append_frame(session_id: str) -> dict[str, object]:
    return {
        "version": PROTOCOL_VERSION,
        "type": "audio.append",
        "session_id": session_id,
        "pcm_b64": "AAA=",
    }


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("chunk_sec", 0),
        ("chunk_sec", -1),
        ("chunk_sec", "bad"),
        ("chunk_sec", float("inf")),
        ("chunk_sec", True),
        ("left_context_sec", -1),
        ("left_context_sec", float("nan")),
        ("left_context_sec", []),
        ("left_context_sec", False),
        ("right_context_ms", -1),
        ("right_context_ms", -0.5),
        ("right_context_ms", 1.5),
        ("right_context_ms", float("inf")),
        ("right_context_ms", "bad"),
        ("right_context_ms", False),
        ("max_new_tokens", 0),
        ("max_new_tokens", -1),
        ("max_new_tokens", 1.5),
        ("max_new_tokens", "bad"),
        ("max_new_tokens", float("nan")),
        ("max_new_tokens", True),
    ],
)
def test_invalid_session_options_are_reported_and_do_not_poison_next_session(
    field: str, value: object
) -> None:
    engine = _IsolationEngine(Path("/tmp"), "mps", "float16", 512)
    responses = _run_serve(
        [_start_frame(), _open_frame("bad", **{field: value}), _open_frame("good")],
        engine,
    )

    errors = [frame for frame in responses if frame.get("type") == "error"]
    assert errors == [
        {
            "version": PROTOCOL_VERSION,
            "type": "error",
            "code": "session_open_failed",
            "session_id": "bad",
        }
    ]
    assert [frame for frame in responses if frame.get("type") == "session.opened"] == [
        {
            "version": PROTOCOL_VERSION,
            "type": "session.opened",
            "session_id": "good",
            "language": "zh",
        }
    ]
    assert list(engine.sessions) == ["good"]


def test_session_open_preserves_defaults_and_accepts_numeric_strings() -> None:
    engine = _IsolationEngine(Path("/tmp"), "mps", "float16", 512)
    responses = _run_serve(
        [
            _start_frame(),
            _open_frame("defaults"),
            _open_frame(
                "strings",
                chunk_sec="1.5",
                left_context_sec="0",
                right_context_ms="320",
                max_new_tokens="64",
            ),
        ],
        engine,
    )

    assert not [frame for frame in responses if frame.get("type") == "error"]
    assert engine.open_args == {
        "defaults": (2.0, 12.0, 640, 256),
        "strings": (1.5, 0.0, 320, 64),
    }


def test_commit_finish_failure_closes_only_failed_session_and_allows_next_commit() -> None:
    engine = _IsolationEngine(Path("/tmp"), "mps", "float16", 512, fail_finish={"a"})
    responses = _run_serve(
        [
            _start_frame(),
            _open_frame("a"),
            _open_frame("b"),
            _append_frame("a"),
            _append_frame("b"),
            {"version": PROTOCOL_VERSION, "type": "commit", "session_id": "a"},
            {"version": PROTOCOL_VERSION, "type": "commit", "session_id": "b"},
        ],
        engine,
    )

    assert [
        frame
        for frame in responses
        if frame.get("type") == "error" and frame.get("session_id") == "a"
    ] == [
        {
            "version": PROTOCOL_VERSION,
            "type": "error",
            "code": "worker_inference_error",
            "session_id": "a",
        }
    ]
    assert not [
        frame
        for frame in responses
        if frame.get("type") == "finished" and frame.get("session_id") == "a"
    ]
    assert [
        frame
        for frame in responses
        if frame.get("type") == "finished" and frame.get("session_id") == "b"
    ]
    assert engine.active_session_count() == 0
    assert engine.align_buffers == {}
    assert engine.close_calls == ["a", "b"]


def test_commit_alignment_failure_closes_session_without_pseudo_success() -> None:
    engine = _IsolationEngine(Path("/tmp"), "mps", "float16", 512, fail_align={"a"})
    responses = _run_serve(
        [
            _start_frame(),
            _open_frame("a"),
            _open_frame("b"),
            _append_frame("a"),
            _append_frame("b"),
            {
                "version": PROTOCOL_VERSION,
                "type": "commit",
                "session_id": "a",
                "want_segments": True,
            },
            {"version": PROTOCOL_VERSION, "type": "commit", "session_id": "b"},
        ],
        engine,
    )

    assert [
        frame
        for frame in responses
        if frame.get("type") == "error" and frame.get("session_id") == "a"
    ] == [
        {
            "version": PROTOCOL_VERSION,
            "type": "error",
            "code": "worker_inference_error",
            "session_id": "a",
        }
    ]
    assert not [
        frame
        for frame in responses
        if frame.get("session_id") == "a" and frame.get("type") == "finished"
    ]
    assert engine.active_session_count() == 0
    assert engine.align_buffers == {}
    assert engine.close_calls == ["a", "b"]


def test_empty_commit_finishes_and_releases_alignment_buffer() -> None:
    engine = _IsolationEngine(Path("/tmp"), "mps", "float16", 512, empty_text={"a"})
    responses = _run_serve(
        [
            _start_frame(),
            _open_frame("a"),
            _append_frame("a"),
            {
                "version": PROTOCOL_VERSION,
                "type": "commit",
                "session_id": "a",
                "want_segments": True,
            },
        ],
        engine,
    )

    assert not [frame for frame in responses if frame.get("type") == "error"]
    assert not [frame for frame in responses if frame.get("kind") == "completed"]
    assert [
        frame
        for frame in responses
        if frame.get("type") == "finished" and frame.get("session_id") == "a"
    ] == [
        {
            "version": PROTOCOL_VERSION,
            "type": "finished",
            "session_id": "a",
            "final": True,
        }
    ]
    assert engine.active_session_count() == 0
    assert engine.align_buffers == {}


def test_commit_without_segments_releases_alignment_buffer() -> None:
    engine = _IsolationEngine(Path("/tmp"), "mps", "float16", 512)
    responses = _run_serve(
        [
            _start_frame(),
            _open_frame("a"),
            _append_frame("a"),
            {"version": PROTOCOL_VERSION, "type": "commit", "session_id": "a"},
        ],
        engine,
    )

    assert not [frame for frame in responses if frame.get("type") == "error"]
    assert engine.active_session_count() == 0
    assert engine.align_buffers == {}


def test_malformed_start_returns_invalid_start_without_constructing_engine() -> None:
    source = BytesIO(b"\x00\x00\x00\x05abc")
    target = BytesIO()
    constructed = False

    def factory(*args: object, **kwargs: object) -> _IsolationEngine:
        nonlocal constructed
        constructed = True
        raise AssertionError("invalid start must not construct an engine")

    serve(
        source,
        target,
        model_dir=Path("/tmp"),
        device="mps",
        dtype="float16",
        max_new_tokens=512,
        engine_factory=factory,
    )

    target.seek(0)
    assert read_frame(target) == {
        "version": PROTOCOL_VERSION,
        "type": "error",
        "code": "worker_invalid_start",
    }
    assert constructed is False
