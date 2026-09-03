from __future__ import annotations

import json
from io import BytesIO
from pathlib import Path

import pytest

import speechrail.backends.qwen3_tts_worker as worker_module
from speechrail.backends.qwen3_native import snapshot_is_quantized
from speechrail.backends.qwen3_tts_worker import TtsWorkerIdentity, serve
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, read_frame, write_frame


class FakeEngine:
    identity = TtsWorkerIdentity(device="mps", dtype="float16", sample_rate=24_000)

    def synthesize(self, text: str, *, voice: str, speed: float, language: str):
        assert (text, voice, speed, language) == ("你好。", "default", 1.0, "auto")
        yield b"\x00\x00"
        yield b"\x01\x00"


def test_tts_snapshot_is_quantized_detects_config_quantization(tmp_path: Path) -> None:
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    assert snapshot_is_quantized(model_dir) is False
    quantized = {"tts_model_type": "voice_design", "quantization": {"bits": 8, "group_size": 64}}
    (model_dir / "config.json").write_text(json.dumps(quantized), encoding="utf-8")
    assert snapshot_is_quantized(model_dir) is True
    (model_dir / "config.json").write_text(
        json.dumps({"quantization_config": {"bits": 8}}), encoding="utf-8"
    )
    assert snapshot_is_quantized(model_dir) is True


def test_serve_accepts_int8_identity_for_quantized_snapshot(tmp_path: Path) -> None:
    """A pre-quantized TTS snapshot reports int8 identity and must pass the gate."""
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    quantized = {"tts_model_type": "voice_design", "quantization": {"bits": 8, "group_size": 64}}
    (model_dir / "config.json").write_text(json.dumps(quantized), encoding="utf-8")
    source = BytesIO()
    target = BytesIO()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    source.seek(0)

    class Int8Engine(FakeEngine):
        identity = TtsWorkerIdentity(device="mps", dtype="int8", sample_rate=24_000)

    serve(source, target, model_dir=model_dir, device="mps", sample_rate=24_000,
          engine_factory=lambda _: Int8Engine())

    target.seek(0)
    ready = read_frame(target)
    assert ready["type"] == "ready"
    assert ready["dtype"] == "int8"
    assert ready["model_loaded"] is True


def test_tts_worker_emits_ordered_pcm_frames_without_vendor_runtime(tmp_path: Path) -> None:
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
            "sample_rate": 24_000,
        },
    )
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "synthesize",
            "request_id": "req-1",
            "text": "你好。",
            "voice": "default",
            "speed": 1.0,
        },
    )
    source.seek(0)

    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
        engine_factory=lambda _: FakeEngine(),
    )

    target.seek(0)
    ready = read_frame(target)
    first = read_frame(target)
    second = read_frame(target)
    completed = read_frame(target)

    assert ready == {
        "version": PROTOCOL_VERSION,
        "type": "ready",
        "backend": "mlx-qwen3-tts-voice-design",
        "device": "mps",
        "dtype": "float16",
        "sample_rate": 24_000,
        "model_loaded": True,
    }
    assert first.get("_binary") == b"\x00\x00"
    assert first["chunk_index"] == 0
    assert second["chunk_index"] == 1
    assert completed == {"version": PROTOCOL_VERSION, "type": "completed", "request_id": "req-1"}


def test_worker_main_passes_explicit_local_runtime_arguments_to_private_server(
    monkeypatch, tmp_path: Path
) -> None:
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    captured: dict[str, object] = {}

    def fake_serve(
        input_stream: object,
        output_stream: object,
        *,
        model_dir: Path,
        device: str,
        sample_rate: int,
        engine_factory: object,
    ) -> None:
        captured.update(
            {
                "input_stream": input_stream,
                "output_stream": output_stream,
                "model_dir": model_dir,
                "device": device,
                "sample_rate": sample_rate,
                "engine_factory": engine_factory,
            }
        )

    monkeypatch.setattr(worker_module, "serve", fake_serve)
    def engine_factory(_: Path) -> FakeEngine:
        return FakeEngine()

    worker_module.main(
        ["--model-dir", str(model_dir), "--device", "mps", "--sample-rate", "24000"],
        engine_factory=engine_factory,
    )

    assert captured["model_dir"] == model_dir.resolve()
    assert captured["device"] == "mps"
    assert captured["sample_rate"] == 24_000
    assert captured["engine_factory"] is engine_factory


def test_serve_reports_worker_load_error_with_traceback_on_stderr(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A failing model load emits worker_load_error AND the real traceback on stderr."""

    def failing_factory(_: Path) -> FakeEngine:
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
            "sample_rate": 24_000,
        },
    )
    source.seek(0)

    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
        engine_factory=failing_factory,
    )

    target.seek(0)
    assert read_frame(target) == {
        "version": PROTOCOL_VERSION,
        "type": "error",
        "code": "worker_load_error",
    }
    assert "boom-model-load" in capsys.readouterr().err
