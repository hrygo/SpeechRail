from io import BytesIO
from pathlib import Path

import pytest

from speechrail.backends.qwen3_worker import WorkerIdentity, serve
from speechrail.runtime.worker_protocol import ProtocolError, read_frame, write_frame


class _FakeEngine:
    identity = WorkerIdentity(device="mps", dtype="float16")

    def transcribe(self, audio: bytes, *, language: str, prompt: str) -> tuple[str, str]:
        assert audio == b"\x00\x00"
        assert prompt == "names"
        return "hello", language


def test_framed_protocol_round_trips_versioned_request() -> None:
    stream = BytesIO()
    write_frame(stream, {"version": 1, "type": "transcribe", "request_id": "req_1"})
    stream.seek(0)

    assert read_frame(stream) == {"version": 1, "type": "transcribe", "request_id": "req_1"}


def test_framed_protocol_rejects_bad_length_and_eof() -> None:
    with pytest.raises(ProtocolError, match="truncated"):
        read_frame(BytesIO(b"\x00\x00"))
    with pytest.raises(ProtocolError, match="size"):
        read_frame(BytesIO(b"\xff\xff\xff\xff"))


def test_worker_reuses_one_loaded_engine_for_framed_requests() -> None:
    incoming = BytesIO()
    write_frame(
        incoming, {"version": 1, "type": "start", "model_dir": "/external/model", "device": "mps"}
    )
    write_frame(
        incoming,
        {
            "version": 1,
            "type": "transcribe",
            "request_id": "req_1",
            "sample_rate": 16000,
            "channels": 1,
            "sample_width_bytes": 2,
            "language": "en",
            "prompt": "names",
            "pcm_b64": "AAA=",
        },
    )
    incoming.seek(0)
    outgoing = BytesIO()
    serve(
        incoming,
        outgoing,
        model_dir=Path("/external/model"),
        device="mps",
        max_new_tokens=64,
        engine_factory=lambda *_: _FakeEngine(),
    )
    outgoing.seek(0)
    assert read_frame(outgoing)["type"] == "ready"
    assert read_frame(outgoing) == {
        "version": 1,
        "type": "result",
        "request_id": "req_1",
        "text": "hello",
        "language": "en",
        "device": "mps",
        "dtype": "float16",
    }
