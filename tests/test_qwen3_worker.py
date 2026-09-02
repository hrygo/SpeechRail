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
