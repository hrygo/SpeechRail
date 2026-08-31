from __future__ import annotations

import base64
from io import BytesIO
from pathlib import Path

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
