from __future__ import annotations

import base64
from io import BytesIO
from pathlib import Path

import speechrail.backends.qwen3_tts_worker as worker_module
from speechrail.backends.qwen3_tts_worker import TtsWorkerIdentity, serve
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, read_frame, write_frame


class FakeEngine:
    identity = TtsWorkerIdentity(device="mps", dtype="float16", sample_rate=24_000)

    def synthesize(self, text: str, *, voice: str, speed: float):
        assert (text, voice, speed) == ("你好。", "default", 1.0)
        yield b"\x00\x00"
        yield b"\x01\x00"


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
        "device": "mps",
        "dtype": "float16",
        "sample_rate": 24_000,
        "model_loaded": True,
    }
    assert base64.b64decode(str(first["pcm_b64"])) == b"\x00\x00"
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
